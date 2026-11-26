import AppKit
import CryptoKit
import Foundation
import ImageIO
import SwiftUI

private actor ConcurrencyGate {
    private enum AcquireAttempt: Sendable {
        case acquired
        case cancelled
        case wait(UInt64)
    }

    private let limit: Int
    private var active: Int = 0
    private var nextID: UInt64 = 0
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    private func beginAcquire() -> AcquireAttempt {
        if Task.isCancelled { return .cancelled }
        if active < limit {
            active += 1
            return .acquired
        }
        nextID &+= 1
        return .wait(nextID)
    }

    private func enqueueWaiter(id: UInt64) async -> Bool {
        if Task.isCancelled { return false }
        if active < limit {
            active += 1
            return true
        }
        return await withCheckedContinuation { continuation in
            waiters.append((id: id, continuation: continuation))
        }
    }

    private func cancelWaiter(id: UInt64) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let entry = waiters.remove(at: idx)
            entry.continuation.resume(returning: false)
        }
    }

    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume(returning: true)
        } else {
            active = max(0, active - 1)
        }
    }

    nonisolated func acquire() async -> Bool {
        if Task.isCancelled { return false }
        switch await beginAcquire() {
        case .acquired:
            return true
        case .cancelled:
            return false
        case .wait(let waiterID):
            return await withTaskCancellationHandler {
                await self.enqueueWaiter(id: waiterID)
            } onCancel: {
                Task { await self.cancelWaiter(id: waiterID) }
            }
        }
    }
}

/// High-efficiency artwork loader that decodes & downsamples TMDB images off the main thread
/// using `CGImageSourceCreateThumbnailAtIndex` to exact pixel bounds — eliminating oversized
/// `w1280` / `w342` GPU texture bloat while keeping disk-cached artwork instant across launches.
public actor ArtworkCache {
    public static let shared = ArtworkCache()

    private static let pixelBuckets = [64, 128, 256, 384, 512, 768, 1280, 1600]
    private static let maxConcurrentOperations = 8
    private static let negativeCacheTTL: TimeInterval = 10 * 60
    private static let diskMaxBytes: Int64 = 250 * 1024 * 1024
    private static let diskTargetBytes: Int64 = 200 * 1024 * 1024
    private static let diskMaxAge: TimeInterval = 30 * 24 * 60 * 60
    private static let diskPruneWriteInterval = 100
    private static let diskTouchInterval: TimeInterval = 60 * 60

    private struct WaiterState {
        let taskID: UInt64
        var waiters: Set<UInt64>
    }

    nonisolated(unsafe) private let memoryCache = NSCache<NSString, NSImage>()
    private var inFlightDownloads: [URL: Task<Data?, Never>] = [:]
    private var downloadWaiters: [URL: WaiterState] = [:]
    private var inFlightDecodes: [String: Task<NSImage?, Never>] = [:]
    private var decodeWaiters: [String: WaiterState] = [:]
    private var negativeCache: [URL: Date] = [:]
    private let downloadGate: ConcurrencyGate
    private let decodeGate: ConcurrencyGate
    private var nextID: UInt64 = 0
    private var cacheGeneration: UInt64 = 0
    private var hasScheduledInitialPrune = false
    private var diskWritesSincePrune = 0
    private var pruneTask: Task<Void, Never>?
    private var activePruneID: UInt64?
    private let diskDir: URL
    private let session: URLSession

    public init() {
        memoryCache.countLimit = 240
        memoryCache.totalCostLimit = 32 * 1024 * 1024 // 32 MB strict RAM cap for decoded thumbnails
        self.downloadGate = ConcurrencyGate(limit: Self.maxConcurrentOperations)
        self.decodeGate = ConcurrencyGate(limit: Self.maxConcurrentOperations)

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.diskDir = caches.appendingPathComponent("tmdb_images", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.urlCache = nil
        self.session = URLSession(configuration: cfg)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public static func tmdbImageURL(path: String?, size: String = "w185", baseURL: String? = nil) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        let clean = path.hasPrefix("/") ? path : "/\(path)"
        let rawHost = (baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var host = rawHost.isEmpty ? "https://image.tmdb.org/t/p" : rawHost
        while host.hasSuffix("/") { host.removeLast() }
        return URL(string: "\(host)/\(size)\(clean)")
    }

    public static func preferredPosterBucket(forWidth width: CGFloat) -> String {
        if width <= 60 { return "w92" }
        if width <= 120 { return "w185" }
        return "w342"
    }

    public static func quantizedPixelDimension(_ raw: Int) -> Int {
        let clamped = max(64, min(1600, raw))
        for bucket in pixelBuckets where bucket >= clamped {
            return bucket
        }
        return 1600
    }

    public nonisolated func cachedThumbnailIfAvailable(url: URL, maxPixelDimension: Int) -> NSImage? {
        let bucketPx = Self.quantizedPixelDimension(maxPixelDimension)
        let memKey = "\(url.absoluteString)#\(bucketPx)" as NSString
        return memoryCache.object(forKey: memKey)
    }

    /// Fetches raw artwork bytes using the shared disk cache and per-URL in-flight download singleflight.
    public func fetchRawBytes(url: URL) async -> Data? {
        if Task.isCancelled { return nil }
        if isNegativelyCached(url) { return nil }
        scheduleDiskPruneIfNeeded(didWrite: false)

        let task: Task<Data?, Never>
        let taskID: UInt64
        let waiterID = allocateID()

        if let existingTask = inFlightDownloads[url], var state = downloadWaiters[url] {
            task = existingTask
            taskID = state.taskID
            state.waiters.insert(waiterID)
            downloadWaiters[url] = state
        } else {
            let newTaskID = allocateID()
            taskID = newTaskID
            let diskURL = diskFileURL(for: url)
            let session = self.session
            let downloadGate = self.downloadGate
            let generation = self.cacheGeneration

            let newTask = Task.detached(priority: .utility) { [weak self] () -> Data? in
                let result: Data?
                if Task.isCancelled {
                    result = nil
                } else if let diskData = try? Data(contentsOf: diskURL), !diskData.isEmpty {
                    Self.touchDiskAccessDateIfNeeded(at: diskURL)
                    result = diskData
                } else if await downloadGate.acquire() {
                    result = await Self.performNetworkDownload(
                        url: url,
                        diskURL: diskURL,
                        session: session,
                        cache: self,
                        generation: generation
                    )
                    await downloadGate.release()
                } else {
                    result = nil
                }
                await self?.finishDownloadTask(url: url, taskID: newTaskID)
                return result
            }
            inFlightDownloads[url] = newTask
            downloadWaiters[url] = WaiterState(taskID: newTaskID, waiters: [waiterID])
            task = newTask
        }

        let data = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task {
                await self.releaseDownloadWaiter(
                    url: url,
                    taskID: taskID,
                    waiterID: waiterID,
                    cancelIfEmpty: true
                )
            }
        }
        releaseDownloadWaiter(
            url: url,
            taskID: taskID,
            waiterID: waiterID,
            cancelIfEmpty: false
        )
        return Task.isCancelled ? nil : data
    }

    public func loadThumbnail(url: URL, maxPixelDimension: Int) async -> NSImage? {
        if Task.isCancelled { return nil }
        let bucketPx = Self.quantizedPixelDimension(maxPixelDimension)
        let decodeKey = "\(url.absoluteString)#\(bucketPx)"
        if let cached = memoryCache.object(forKey: decodeKey as NSString) {
            return cached
        }
        if isNegativelyCached(url) { return nil }

        let task: Task<NSImage?, Never>
        let taskID: UInt64
        let waiterID = allocateID()

        if let existingTask = inFlightDecodes[decodeKey], var state = decodeWaiters[decodeKey] {
            task = existingTask
            taskID = state.taskID
            state.waiters.insert(waiterID)
            decodeWaiters[decodeKey] = state
        } else {
            let newTaskID = allocateID()
            taskID = newTaskID
            let decodeGate = self.decodeGate
            let generation = self.cacheGeneration

            let newTask = Task.detached(priority: .utility) { [weak self] () -> NSImage? in
                guard let self else { return nil }
                var decodedImage: NSImage?
                if !Task.isCancelled,
                   let data = await self.fetchRawBytes(url: url),
                   !data.isEmpty,
                   !Task.isCancelled,
                   await decodeGate.acquire() {
                    let decoded: (NSImage, Int)?
                    if Task.isCancelled {
                        decoded = nil
                    } else {
                        decoded = Self.downsample(data: data, maxPixelSize: bucketPx)
                    }
                    await decodeGate.release()
                    if let (image, cost) = decoded,
                       !Task.isCancelled,
                       await self.isCurrentGeneration(generation),
                       !Task.isCancelled {
                        self.memoryCache.setObject(
                            image,
                            forKey: decodeKey as NSString,
                            cost: max(1024, cost)
                        )
                        decodedImage = image
                    }
                }
                await self.finishDecodeTask(key: decodeKey, taskID: newTaskID)
                return decodedImage
            }
            inFlightDecodes[decodeKey] = newTask
            decodeWaiters[decodeKey] = WaiterState(taskID: newTaskID, waiters: [waiterID])
            task = newTask
        }

        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task {
                await self.releaseDecodeWaiter(
                    key: decodeKey,
                    taskID: taskID,
                    waiterID: waiterID,
                    cancelIfEmpty: true
                )
            }
        }
        releaseDecodeWaiter(
            key: decodeKey,
            taskID: taskID,
            waiterID: waiterID,
            cancelIfEmpty: false
        )
        return Task.isCancelled ? nil : image
    }

    public func clearAll() {
        cacheGeneration &+= 1
        for task in inFlightDownloads.values {
            task.cancel()
        }
        inFlightDownloads.removeAll()
        downloadWaiters.removeAll()
        for task in inFlightDecodes.values {
            task.cancel()
        }
        inFlightDecodes.removeAll()
        decodeWaiters.removeAll()
        negativeCache.removeAll()
        pruneTask?.cancel()
        pruneTask = nil
        activePruneID = nil
        diskWritesSincePrune = 0
        hasScheduledInitialPrune = true
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: diskDir)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    private func allocateID() -> UInt64 {
        nextID &+= 1
        return nextID
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        generation == cacheGeneration
    }

    private func isNegativelyCached(_ url: URL) -> Bool {
        guard let failedAt = negativeCache[url] else { return false }
        if Date().timeIntervalSince(failedAt) < Self.negativeCacheTTL {
            return true
        }
        negativeCache.removeValue(forKey: url)
        return false
    }

    private func recordNegativeResult(for url: URL, generation: UInt64) {
        guard generation == cacheGeneration else { return }
        let now = Date()
        negativeCache[url] = now
        if negativeCache.count > 1024 {
            negativeCache = negativeCache.filter { now.timeIntervalSince($0.value) < Self.negativeCacheTTL }
        }
    }

    private func finishDownloadTask(url: URL, taskID: UInt64) {
        guard downloadWaiters[url]?.taskID == taskID else { return }
        downloadWaiters.removeValue(forKey: url)
        inFlightDownloads.removeValue(forKey: url)
    }

    private func releaseDownloadWaiter(url: URL, taskID: UInt64, waiterID: UInt64, cancelIfEmpty: Bool) {
        guard var state = downloadWaiters[url], state.taskID == taskID else { return }
        guard state.waiters.remove(waiterID) != nil else { return }
        if state.waiters.isEmpty {
            downloadWaiters.removeValue(forKey: url)
            let task = inFlightDownloads.removeValue(forKey: url)
            if cancelIfEmpty {
                task?.cancel()
            }
        } else {
            downloadWaiters[url] = state
        }
    }

    private func finishDecodeTask(key: String, taskID: UInt64) {
        guard decodeWaiters[key]?.taskID == taskID else { return }
        decodeWaiters.removeValue(forKey: key)
        inFlightDecodes.removeValue(forKey: key)
    }

    private func releaseDecodeWaiter(key: String, taskID: UInt64, waiterID: UInt64, cancelIfEmpty: Bool) {
        guard var state = decodeWaiters[key], state.taskID == taskID else { return }
        guard state.waiters.remove(waiterID) != nil else { return }
        if state.waiters.isEmpty {
            decodeWaiters.removeValue(forKey: key)
            let task = inFlightDecodes.removeValue(forKey: key)
            if cancelIfEmpty {
                task?.cancel()
            }
        } else {
            decodeWaiters[key] = state
        }
    }

    private func recordDiskWrite() {
        scheduleDiskPruneIfNeeded(didWrite: true)
    }

    private func scheduleDiskPruneIfNeeded(didWrite: Bool) {
        if didWrite {
            diskWritesSincePrune += 1
        }
        let shouldPrune: Bool
        if !hasScheduledInitialPrune {
            hasScheduledInitialPrune = true
            shouldPrune = true
        } else if didWrite && diskWritesSincePrune >= Self.diskPruneWriteInterval {
            shouldPrune = true
        } else {
            shouldPrune = false
        }
        guard shouldPrune, pruneTask == nil else { return }
        diskWritesSincePrune = 0
        let dir = self.diskDir
        let pruneID = allocateID()
        activePruneID = pruneID
        pruneTask = Task.detached(priority: .background) { [weak self] in
            Self.pruneDiskCache(in: dir)
            await self?.finishDiskPrune(id: pruneID)
        }
    }

    private func finishDiskPrune(id: UInt64) {
        guard activePruneID == id else { return }
        activePruneID = nil
        pruneTask = nil
    }

    private func diskFileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent(hex)
    }

    private nonisolated static func performNetworkDownload(
        url: URL,
        diskURL: URL,
        session: URLSession,
        cache: ArtworkCache?,
        generation: UInt64
    ) async -> Data? {
        if Task.isCancelled { return nil }
        if let diskData = try? Data(contentsOf: diskURL), !diskData.isEmpty {
            touchDiskAccessDateIfNeeded(at: diskURL)
            return diskData
        }
        guard let (fetched, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse else {
            return nil
        }
        if http.statusCode == 404 || http.statusCode == 410 {
            await cache?.recordNegativeResult(for: url, generation: generation)
            return nil
        }
        guard (200..<300).contains(http.statusCode), !fetched.isEmpty else {
            return nil
        }
        if Task.isCancelled { return nil }
        if let cache, await cache.isCurrentGeneration(generation) {
            do {
                try fetched.write(to: diskURL, options: .atomic)
                await cache.recordDiskWrite()
            } catch {
                // Best-effort disk cache write; still return fetched bytes for in-memory use.
            }
        }
        return fetched
    }

    private nonisolated static func touchDiskAccessDateIfNeeded(at url: URL) {
        let now = Date()
        if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
           let modDate = values.contentModificationDate,
           now.timeIntervalSince(modDate) < diskTouchInterval {
            return
        }
        var mutableURL = url
        var values = URLResourceValues()
        values.contentModificationDate = now
        try? mutableURL.setResourceValues(values)
    }

    private nonisolated static func pruneDiskCache(in diskDir: URL) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .contentAccessDateKey,
        ]
        guard let urls = try? fm.contentsOfDirectory(
            at: diskDir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let keySet = Set(keys)
        let now = Date()
        var entries: [(url: URL, size: Int64, lastUsed: Date)] = []
        entries.reserveCapacity(urls.count)
        var totalBytes: Int64 = 0

        for fileURL in urls {
            if Task.isCancelled { return }
            guard let values = try? fileURL.resourceValues(forKeys: keySet),
                  values.isRegularFile == true else {
                continue
            }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            let modDate = values.contentModificationDate ?? .distantPast
            let accessDate = values.contentAccessDate ?? .distantPast
            let lastUsed = max(modDate, accessDate)

            if now.timeIntervalSince(lastUsed) > diskMaxAge {
                try? fm.removeItem(at: fileURL)
                continue
            }
            totalBytes += size
            entries.append((url: fileURL, size: size, lastUsed: lastUsed))
        }

        guard totalBytes > diskMaxBytes else { return }
        entries.sort { $0.lastUsed < $1.lastUsed }

        for entry in entries {
            if Task.isCancelled || totalBytes <= diskTargetBytes { break }
            do {
                try fm.removeItem(at: entry.url)
                totalBytes -= entry.size
            } catch {
                // Ignore entries removed concurrently.
            }
        }
    }

    private nonisolated static func downsample(data: Data, maxPixelSize: Int) -> (NSImage, Int)? {
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts as CFDictionary) else {
            return nil
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else {
            return nil
        }
        let cost = cgImg.bytesPerRow * cgImg.height
        let image = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
        return (image, max(1024, cost))
    }
}

/// Downsampled TMDB poster / backdrop view with zero main-thread image decoding.
/// Matches `Poster` in `widgets/common.dart` (2:3 proportion, `p.sidebar` placeholder, `p.line` hairline frame, gentle fade-in).
public struct DownsampledArtworkView: View {
    public let tmdbPath: String?
    public let sizeBucket: String
    public let width: CGFloat
    public let height: CGFloat
    public let cornerRadius: CGFloat
    public let fallbackSystemImage: String
    public let alignment: Alignment
    public let showsBorder: Bool

    @Environment(\.palette) private var palette
    @Environment(\.displayScale) private var displayScale
    @Environment(\.tidyreelReduceMotion) private var reduceMotion
    @State private var image: NSImage?
    @State private var loadedKey: String = ""

    public init(
        tmdbPath: String?,
        sizeBucket: String? = nil,
        width: CGFloat = 46,
        height: CGFloat = 69,
        cornerRadius: CGFloat = TidyreelRadii.sm,
        fallbackSystemImage: String = "film",
        alignment: Alignment = .center,
        showsBorder: Bool = true
    ) {
        self.tmdbPath = tmdbPath
        self.sizeBucket = sizeBucket ?? ArtworkCache.preferredPosterBucket(forWidth: width)
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.fallbackSystemImage = fallbackSystemImage
        self.alignment = alignment
        self.showsBorder = showsBorder
    }

    private var targetPixelBucket: Int {
        let maxSide = max(width, height)
        guard maxSide.isFinite, maxSide > 0 else {
            return ArtworkCache.quantizedPixelDimension(64)
        }
        let scaledSide = maxSide * max(1.0, displayScale)
        let rawPx = scaledSide.isFinite ? Int(ceil(min(scaledSide, 1600))) : 1600
        return ArtworkCache.quantizedPixelDimension(rawPx)
    }

    public var body: some View {
        let assetKey = "\(tmdbPath ?? "")#\(sizeBucket)"
        let bucketPx = targetPixelBucket
        let taskID = "\(assetKey)#\(bucketPx)"

        ZStack {
            Rectangle()
                .fill(palette.sidebar)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: width, height: height, alignment: alignment)
                    .clipped()
                    .transition(.opacity)
            } else {
                Image(systemName: fallbackSystemImage)
                    .font(.system(size: min(width, height) * 0.40, weight: .regular))
                    .foregroundStyle(palette.textFaint)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            if showsBorder {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(palette.line, lineWidth: hairlineWidth)
            }
        }
        .task(id: taskID) {
            guard let url = ArtworkCache.tmdbImageURL(path: tmdbPath, size: sizeBucket) else {
                image = nil
                loadedKey = ""
                return
            }
            if let syncCached = ArtworkCache.shared.cachedThumbnailIfAvailable(url: url, maxPixelDimension: bucketPx) {
                image = syncCached
                loadedKey = assetKey
                return
            }
            let keepExisting = (loadedKey == assetKey && image != nil)
            if !keepExisting {
                image = nil
                loadedKey = ""
            }
            let fetched = await ArtworkCache.shared.loadThumbnail(url: url, maxPixelDimension: bucketPx)
            guard !Task.isCancelled else { return }
            if let fetched {
                if reduceMotion || keepExisting {
                    image = fetched
                } else {
                    withAnimation(.easeOut(duration: 0.20)) {
                        image = fetched
                    }
                }
                loadedKey = assetKey
            } else if !keepExisting {
                image = nil
                loadedKey = ""
            }
        }
    }
}
