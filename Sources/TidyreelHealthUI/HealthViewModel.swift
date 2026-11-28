import Foundation
import Observation
import TidyreelDesign
import TidyreelModels
import TidyreelServices

// MARK: - Confirmation Value Types

struct DuplicateDeletePayload: Identifiable, Equatable, Sendable {
    let id = UUID()
    let connection: ConnectionId
    let scannedAt: Date
    let copies: [DuplicateMediaCopy]
    let keepers: [DuplicateMediaCopy]

    var totalBytes: Int64 {
        copies.reduce(0) { $0 + max(0, $1.fileSize) }
    }
}

struct CleanupConfirmPayload: Identifiable, Equatable, Sendable {
    let id = UUID()
    let connection: ConnectionId
    let scannedAt: Date
    let items: [CleanupIssue]

    var junkFiles: [CleanupIssue] {
        items.filter { $0.kind == .junkFile }
    }

    var emptyDirs: [CleanupIssue] {
        items.filter { $0.kind == .emptyDir }
    }

    var totalJunkBytes: Int64 {
        junkFiles.reduce(0) { $0 + max(0, $1.size) }
    }
}

// MARK: - Weak Per-Store Session Cache (Preserves Scan & Report Across Tab Switches)

@MainActor
public final class HealthSessionRegistry {
    public static let shared = HealthSessionRegistry()

    private final class Entry {
        weak var store: AppStore?
        let controller: HealthSessionController

        init(store: AppStore, controller: HealthSessionController) {
            self.store = store
            self.controller = controller
        }
    }

    private var entries: [Entry] = []

    private init() {}

    public func controller(for store: AppStore) -> HealthSessionController {
        entries.removeAll { $0.store == nil }
        if let hit = entries.first(where: { $0.store === store }) {
            hit.controller.syncConnectionsIfNeeded(store: store)
            return hit.controller
        }
        let created = HealthSessionController(initialStore: store)
        entries.append(Entry(store: store, controller: created))
        return created
    }

    public func releaseIdleReports() {
        entries.removeAll { $0.store == nil }
        for entry in entries {
            entry.controller.releaseReportIfIdle()
        }
    }
}

// MARK: - Observable Health Session Controller

@Observable
@MainActor
public final class HealthSessionController {
    var selectedConnectionId: ConnectionId?
    var targetPath: String = "/"
    var isScanning: Bool = false
    var progress: HealthScanProgress?
    var report: HealthReport?
    var errorMessage: String?

    var selectedCategory: HealthCategory = .duplicates
    var selectedMissingFolders: Set<String> = []
    var selectedCleanupPaths: Set<String> = []

    // Precomputed report aggregations & incremental selection total
    private(set) var sortedDuplicateIssues: [DuplicateMediaIssue] = []
    private(set) var totalReclaimableBytes: Int64 = 0
    private(set) var junkCount: Int = 0
    private(set) var emptyDirCount: Int = 0
    private(set) var selectedCleanupBytes: Int64 = 0

    var isBusyAction: Bool = false
    var isFolderPickerPresented: Bool = false
    var pendingDuplicateDelete: DuplicateDeletePayload?
    var pendingCleanupDelete: CleanupConfirmPayload?

    @ObservationIgnored private var cleanupItemSizes: [String: Int64] = [:]
    @ObservationIgnored private var junkPathsCache: [String] = []
    @ObservationIgnored private var emptyDirPathsCache: [String] = []
    @ObservationIgnored private var totalJunkBytesCache: Int64 = 0

    private var scanGeneration: Int = 0
    private var currentScanner: HealthScannerActor?
    private var scanTask: Task<Void, Never>?

    init(initialStore: AppStore) {
        if let preferred = Self.preferredInitialConnection(in: initialStore) {
            self.selectedConnectionId = preferred.id
            self.targetPath = Self.defaultHealthRoot(for: preferred)
        }
    }

    static func defaultHealthRoot(for conn: ConnectionConfig) -> String {
        if let root = conn.libraryRoot?.trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty {
            return normalizeDir(root)
        }
        return normalizeDir(conn.startDir)
    }

    private static func preferredInitialConnection(in store: AppStore) -> ConnectionConfig? {
        if let openId = store.openConnectionId,
           let match = store.connections.first(where: { $0.id == openId }) {
            return match
        }
        return store.connections.first
    }

    func selectedConnection(in store: AppStore) -> ConnectionConfig? {
        guard let id = selectedConnectionId else { return nil }
        return store.connections.first(where: { $0.id == id })
    }

    func syncConnectionsIfNeeded(store: AppStore) {
        let conns = store.connections
        if let cur = selectedConnectionId {
            if !conns.contains(where: { $0.id == cur }) {
                cancelScan()
                let fallback = Self.preferredInitialConnection(in: store)
                selectedConnectionId = fallback?.id
                targetPath = fallback.map(Self.defaultHealthRoot(for:)) ?? "/"
                resetReportState()
            }
        } else if let first = Self.preferredInitialConnection(in: store) {
            selectedConnectionId = first.id
            targetPath = Self.defaultHealthRoot(for: first)
        }
    }

    func selectConnection(_ id: ConnectionId, store: AppStore) {
        guard !isBusyAction, selectedConnectionId != id else { return }
        guard let conn = store.connections.first(where: { $0.id == id }) else { return }
        cancelScan()
        selectedConnectionId = conn.id
        targetPath = Self.defaultHealthRoot(for: conn)
        resetReportState()
    }

    func setTargetPath(_ rawPath: String) {
        guard !isBusyAction, !isScanning else { return }
        let norm = normalizeDir(rawPath)
        guard targetPath != norm else { return }
        targetPath = norm
        resetReportState()
    }

    func setCategory(_ category: HealthCategory) {
        guard selectedCategory != category else { return }
        selectedCategory = category
    }

    public func releaseReportIfIdle() {
        guard !isScanning, !isBusyAction else { return }
        resetReportState()
    }

    private func resetReportState() {
        applyReport(nil)
        errorMessage = nil
        progress = nil
        selectedCategory = .duplicates
        selectedMissingFolders = []
        selectedCleanupPaths = []
        selectedCleanupBytes = 0
        pendingDuplicateDelete = nil
        pendingCleanupDelete = nil
    }

    private func applyReport(_ nextReport: HealthReport?) {
        if report?.connection != nextReport?.connection || report?.scannedAt != nextReport?.scannedAt {
            pendingCleanupDelete = nil
            pendingDuplicateDelete = nil
        }
        report = nextReport
        guard let nextReport else {
            sortedDuplicateIssues = []
            totalReclaimableBytes = 0
            junkCount = 0
            emptyDirCount = 0
            cleanupItemSizes = [:]
            junkPathsCache = []
            emptyDirPathsCache = []
            totalJunkBytesCache = 0
            return
        }

        var dupBytes: Int64 = 0
        let keyedDups: [(issue: DuplicateMediaIssue, reclaimable: Int64)] = nextReport.duplicates.map { issue in
            let bytes = issue.reclaimableBytes
            dupBytes += bytes
            return (issue, bytes)
        }
        sortedDuplicateIssues = keyedDups
            .sorted { a, b in
                if a.reclaimable != b.reclaimable {
                    return a.reclaimable > b.reclaimable
                }
                return a.issue.title < b.issue.title
            }
            .map(\.issue)

        var rawJunkBytes: Int64 = 0
        var clampedJunkBytes: Int64 = 0
        var jCount = 0
        var eCount = 0
        var sizeMap: [String: Int64] = [:]
        sizeMap.reserveCapacity(nextReport.cleanupItems.count)
        var jPaths: [String] = []
        var ePaths: [String] = []

        for item in nextReport.cleanupItems {
            switch item.kind {
            case .junkFile:
                jCount += 1
                rawJunkBytes += item.size
                let clamped = max(Int64(0), item.size)
                clampedJunkBytes += clamped
                sizeMap[item.path] = clamped
                jPaths.append(item.path)
            case .emptyDir:
                eCount += 1
                sizeMap[item.path] = 0
                ePaths.append(item.path)
            }
        }

        totalReclaimableBytes = dupBytes + rawJunkBytes
        junkCount = jCount
        emptyDirCount = eCount
        cleanupItemSizes = sizeMap
        junkPathsCache = jPaths
        emptyDirPathsCache = ePaths
        totalJunkBytesCache = clampedJunkBytes
    }

    private func applyReportAfterDeletion(
        _ nextReport: HealthReport,
        deletedFiles: Set<String>,
        deletedDirs: Set<String> = []
    ) {
        var removedBytes: Int64 = 0
        for path in deletedFiles {
            if selectedCleanupPaths.remove(path) != nil {
                removedBytes += cleanupItemSizes[path] ?? 0
            }
        }
        for path in deletedDirs {
            if selectedCleanupPaths.remove(path) != nil {
                removedBytes += cleanupItemSizes[path] ?? 0
            }
        }
        applyReport(nextReport)
        selectedCleanupBytes = max(0, selectedCleanupBytes - removedBytes)
    }

    // MARK: - Audit Scan Lifecycle

    func startScan(fresh: Bool, store: AppStore) {
        guard let connId = selectedConnectionId, !isBusyAction else { return }

        let previousScanner = currentScanner
        if let previousScanner {
            Task { await previousScanner.cancel() }
        }
        scanTask?.cancel()

        scanGeneration += 1
        let gen = scanGeneration
        let scanRoot = normalizeDir(targetPath)
        targetPath = scanRoot
        isScanning = true
        errorMessage = nil
        progress = HealthScanProgress(
            phase: .walking,
            message: "正在加载目录列表…",
            dirsVisited: 0,
            filesFound: 0,
            fraction: 0.08
        )

        let scanner: HealthScannerActor
        do {
            scanner = try store.makeHealthScanner(for: connId)
        } catch {
            isScanning = false
            progress = nil
            errorMessage = Self.friendlyError(error)
            return
        }
        currentScanner = scanner

        scanTask = Task { @MainActor [weak self] in
            do {
                let result = try await scanner.scan(
                    rootDir: scanRoot,
                    fresh: fresh,
                    onProgress: { [weak self] prog in
                        await self?.applyProgress(prog, gen: gen)
                    }
                )
                guard let self, self.scanGeneration == gen else { return }
                self.finishScanWithReport(result, store: store)
            } catch is HealthScanCancelledError {
                guard let self, self.scanGeneration == gen else { return }
                self.isScanning = false
                self.progress = nil
                self.currentScanner = nil
            } catch is CancellationError {
                guard let self, self.scanGeneration == gen else { return }
                self.isScanning = false
                self.progress = nil
                self.currentScanner = nil
            } catch {
                guard let self, self.scanGeneration == gen else { return }
                self.isScanning = false
                self.progress = nil
                self.currentScanner = nil
                self.errorMessage = Self.friendlyError(error)
            }
        }
    }

    func cancelScan() {
        guard isScanning else { return }
        scanGeneration += 1
        if let scanner = currentScanner {
            Task { await scanner.cancel() }
        }
        currentScanner = nil
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        progress = nil
    }

    private func applyProgress(_ prog: HealthScanProgress, gen: Int) {
        guard scanGeneration == gen, isScanning else { return }
        progress = prog
    }

    private func finishScanWithReport(_ result: HealthReport, store: AppStore) {
        isScanning = false
        progress = nil
        currentScanner = nil
        errorMessage = nil
        applyReport(result)
        selectedCategory = result.firstNonEmptyCategory ?? .duplicates
        selectedMissingFolders = Set(result.missingAssets.map(\.folderPath))
        if store.settings.autoDeleteJunk {
            var chosen: Set<String> = []
            var bytes: Int64 = 0
            for item in result.cleanupItems where item.kind == .junkFile && item.reason == "系统隐藏垃圾" {
                if chosen.insert(item.path).inserted {
                    bytes += max(Int64(0), item.size)
                }
            }
            selectedCleanupPaths = chosen
            selectedCleanupBytes = bytes
        } else {
            selectedCleanupPaths = Set(result.cleanupItems.map(\.path))
            selectedCleanupBytes = totalJunkBytesCache
        }
    }

    // MARK: - 1. Duplicates Deletion

    func requestDeleteIssueRedundant(_ issue: DuplicateMediaIssue) {
        let copies = issue.redundantCopies.filter { $0.path != issue.recommendedKeepPath && !$0.isDiscDir }
        prepareDuplicateDeletion(issue: issue, copies: copies)
    }

    func requestDeleteSingleCopy(_ copy: DuplicateMediaCopy) {
        guard let issue = report?.duplicates.first(where: { $0.copies.contains(copy) }), !copy.isDiscDir else { return }
        prepareDuplicateDeletion(issue: issue, copies: [copy])
    }

    private func prepareDuplicateDeletion(issue: DuplicateMediaIssue, copies: [DuplicateMediaCopy]) {
        guard let report, report.duplicates.contains(issue), !copies.isEmpty, !isBusyAction else { return }
        let selected = Set(copies.map(\.path))
        pendingDuplicateDelete = DuplicateDeletePayload(
            connection: report.connection, scannedAt: report.scannedAt, copies: copies,
            keepers: issue.copies.filter { !selected.contains($0.path) }
        )
    }

    func confirmDeleteDuplicates(_ payload: DuplicateDeletePayload, store: AppStore) async {
        guard let currentReport = report, pendingDuplicateDelete?.id == payload.id,
              currentReport.connection == payload.connection, currentReport.scannedAt == payload.scannedAt,
              !payload.copies.isEmpty, !isBusyAction else { return }
        let reportSnapshot = currentReport
        pendingDuplicateDelete = nil
        isBusyAction = true
        let l10n = store.l10n

        var deletedPaths: Set<String> = []
        var removedCount = 0
        var affectedDirs: Set<String> = []

        do {
            let backend = try store.backend(for: reportSnapshot.connection)
            try await HealthDeletion.run(
                confirmation: payload.id, connection: reportSnapshot.connection, root: reportSnapshot.rootDir,
                files: payload.copies.map { ($0.path, $0.deleteIdentity) }, keepers: payload.keepers,
                history: store.historyStore, backend: backend,
                willAttempt: { affectedDirs.insert(normalizeDir(dirOf($0.src))) },
                didRemove: { op in
                    deletedPaths.insert(op.src)
                    removedCount += 1
                }
            )

            if !affectedDirs.isEmpty {
                await store.invalidateFolderStats(
                    connection: reportSnapshot.connection,
                    dirs: Array(affectedDirs)
                )
            }
            await invalidateSizeScannerIfNeeded(connection: reportSnapshot.connection, store: store)

            if report?.scannedAt == reportSnapshot.scannedAt && report?.connection == reportSnapshot.connection {
                let updated = reportSnapshot.withoutDeletedPaths(deletedFiles: deletedPaths)
                applyReportAfterDeletion(updated, deletedFiles: deletedPaths)
            }
            isBusyAction = false

            store.showToast(
                l10n.tr(
                    "已删除 \(removedCount) 个冗余副本",
                    "Deleted \(l10n.plural(removedCount, "redundant copy", "redundant copies"))"
                )
            )
        } catch {
            if !affectedDirs.isEmpty {
                await store.invalidateFolderStats(
                    connection: reportSnapshot.connection,
                    dirs: Array(affectedDirs)
                )
                await invalidateSizeScannerIfNeeded(connection: reportSnapshot.connection, store: store)
            }
            if !deletedPaths.isEmpty,
               report?.scannedAt == reportSnapshot.scannedAt,
               report?.connection == reportSnapshot.connection {
                let updated = reportSnapshot.withoutDeletedPaths(deletedFiles: deletedPaths)
                applyReportAfterDeletion(updated, deletedFiles: deletedPaths)
            }
            isBusyAction = false
            let msg = Self.localizedError(error, l10n: l10n)
            store.showToast(l10n.tr("删除失败：\(msg)", "Delete failed: \(msg)"))
        }
    }

    // MARK: - 2. Missing Metadata Selection & Scrape-Only Submission

    func toggleMissingFolder(_ folderPath: String) {
        guard !isBusyAction else { return }
        if !selectedMissingFolders.insert(folderPath).inserted {
            selectedMissingFolders.remove(folderPath)
        }
    }

    func selectAllMissingFolders() {
        guard !isBusyAction, let report else { return }
        selectedMissingFolders = Set(report.missingAssets.map(\.folderPath))
    }

    func clearMissingFolders() {
        guard !isBusyAction else { return }
        selectedMissingFolders = []
    }

    func scrapeSelectedMissing(store: AppStore) async {
        guard let currentReport = report,
              !selectedMissingFolders.isEmpty,
              !isBusyAction else { return }

        var orderedPaths: [String] = []
        var seen: Set<String> = []
        for item in currentReport.missingAssets where selectedMissingFolders.contains(item.folderPath) {
            for target in item.targetPaths where seen.insert(target).inserted {
                orderedPaths.append(target)
            }
        }
        await submitScrapeOnly(paths: orderedPaths, connection: currentReport.connection, store: store)
    }

    func scrapeSingleMissing(_ item: MissingAssetIssue, store: AppStore) async {
        guard let currentReport = report, !isBusyAction else { return }
        var orderedPaths: [String] = []
        var seen: Set<String> = []
        for target in item.targetPaths where seen.insert(target).inserted {
            orderedPaths.append(target)
        }
        await submitScrapeOnly(paths: orderedPaths, connection: currentReport.connection, store: store)
    }

    private func submitScrapeOnly(paths: [String], connection: ConnectionId, store: AppStore) async {
        guard !paths.isEmpty, !isBusyAction else { return }
        isBusyAction = true
        let l10n = store.l10n
        do {
            let taskId = try await store.submitTask(
                connection: connection,
                paths: paths,
                mode: .inPlace,
                scrape: true,
                scrapeOnly: true
            )
            isBusyAction = false
            store.openTaskDetail(taskId)
        } catch {
            isBusyAction = false
            let msg = Self.localizedError(error, l10n: l10n)
            store.showToast(l10n.tr("提交刮削任务失败：\(msg)", "Failed to submit scrape task: \(msg)"))
        }
    }

    // MARK: - 3. Cleanup Selection & Execution (Files First -> Empty Dirs Deepest-First)

    func toggleCleanupPath(_ path: String) {
        guard !isBusyAction else { return }
        let itemBytes = cleanupItemSizes[path] ?? 0
        if selectedCleanupPaths.insert(path).inserted {
            selectedCleanupBytes += itemBytes
        } else {
            selectedCleanupPaths.remove(path)
            selectedCleanupBytes = max(0, selectedCleanupBytes - itemBytes)
        }
    }

    func selectAllCleanup() {
        guard !isBusyAction, let report else { return }
        selectedCleanupPaths = Set(report.cleanupItems.map(\.path))
        selectedCleanupBytes = totalJunkBytesCache
    }

    func selectAllJunkFiles() {
        guard !isBusyAction, report != nil else { return }
        selectedCleanupPaths.formUnion(junkPathsCache)
        selectedCleanupBytes = totalJunkBytesCache
    }

    func selectAllEmptyDirs() {
        guard !isBusyAction, report != nil else { return }
        selectedCleanupPaths.formUnion(emptyDirPathsCache)
    }

    func clearCleanupSelection() {
        guard !isBusyAction else { return }
        selectedCleanupPaths = []
        selectedCleanupBytes = 0
    }

    func requestCleanupSelected() {
        guard let report, !selectedCleanupPaths.isEmpty, !isBusyAction else { return }
        let chosen = report.cleanupItems.filter { selectedCleanupPaths.contains($0.path) }
        guard !chosen.isEmpty else { return }
        pendingCleanupDelete = CleanupConfirmPayload(connection: report.connection, scannedAt: report.scannedAt, items: chosen)
    }

    func confirmCleanup(_ payload: CleanupConfirmPayload, store: AppStore) async {
        guard let currentReport = report, pendingCleanupDelete?.id == payload.id,
              currentReport.connection == payload.connection, currentReport.scannedAt == payload.scannedAt,
              !payload.items.isEmpty, !isBusyAction else { return }
        let reportSnapshot = currentReport
        pendingCleanupDelete = nil
        isBusyAction = true
        let l10n = store.l10n

        let files = payload.junkFiles
        let dirsDeepestFirst = payload.emptyDirs.sorted { a, b in
            let da = a.path.filter { $0 == "/" }.count
            let db = b.path.filter { $0 == "/" }.count
            return da != db ? da > db : a.path < b.path
        }

        var deletedFiles: Set<String> = []
        var deletedDirs: Set<String> = []
        var mutatedDirs: Set<String> = []
        var filesRemovedCount = 0
        var dirsRemovedCount = 0

        do {
            let backend = try store.backend(for: reportSnapshot.connection)

            try await HealthDeletion.run(
                confirmation: payload.id, connection: reportSnapshot.connection, root: reportSnapshot.rootDir,
                files: files.map { ($0.path, $0.deleteIdentity) }, directories: dirsDeepestFirst.map(\.path),
                history: store.historyStore, backend: backend,
                willAttempt: { mutatedDirs.insert(normalizeDir(dirOf($0.src))) },
                didRemove: { op in
                    if op.kind == .healthDeleteEmptyDirectory {
                        mutatedDirs.insert(normalizeDir(op.src))
                        deletedDirs.insert(op.src)
                        dirsRemovedCount += 1
                    } else {
                        deletedFiles.insert(op.src)
                        filesRemovedCount += 1
                    }
                }
            )

            if !mutatedDirs.isEmpty {
                await store.invalidateFolderStats(
                    connection: reportSnapshot.connection,
                    dirs: Array(mutatedDirs)
                )
                await invalidateSizeScannerIfNeeded(connection: reportSnapshot.connection, store: store)
            }

            if report?.scannedAt == reportSnapshot.scannedAt && report?.connection == reportSnapshot.connection {
                let updated = reportSnapshot.withoutDeletedPaths(
                    deletedFiles: deletedFiles,
                    deletedDirs: deletedDirs
                )
                applyReportAfterDeletion(
                    updated,
                    deletedFiles: deletedFiles,
                    deletedDirs: deletedDirs
                )
            }
            isBusyAction = false

            store.showToast(
                l10n.tr(
                    "已清理 \(filesRemovedCount) 个垃圾文件、\(dirsRemovedCount) 个空目录",
                    "Cleaned \(l10n.plural(filesRemovedCount, "junk file")) and \(l10n.plural(dirsRemovedCount, "empty folder"))"
                )
            )
        } catch {
            if !mutatedDirs.isEmpty {
                await store.invalidateFolderStats(
                    connection: reportSnapshot.connection,
                    dirs: Array(mutatedDirs)
                )
                await invalidateSizeScannerIfNeeded(connection: reportSnapshot.connection, store: store)
            }
            if !deletedFiles.isEmpty || !deletedDirs.isEmpty,
               report?.scannedAt == reportSnapshot.scannedAt,
               report?.connection == reportSnapshot.connection {
                let updated = reportSnapshot.withoutDeletedPaths(
                    deletedFiles: deletedFiles,
                    deletedDirs: deletedDirs
                )
                applyReportAfterDeletion(
                    updated,
                    deletedFiles: deletedFiles,
                    deletedDirs: deletedDirs
                )
            }
            isBusyAction = false
            let msg = Self.localizedError(error, l10n: l10n)
            store.showToast(l10n.tr("清理失败：\(msg)", "Cleanup failed: \(msg)"))
        }
    }

    private func invalidateSizeScannerIfNeeded(connection: ConnectionId, store: AppStore) async {
        if let scanner = try? store.sizeScanner(for: connection) {
            await scanner.releaseMemoryCache()
        }
    }

    // MARK: - Localization Helpers

    static func localizedProgressDetail(_ progress: HealthScanProgress, targetPath: String, l10n: AppL10n) -> String {
        switch progress.phase {
        case .walking:
            if progress.dirsVisited == 0 && progress.filesFound == 0 {
                return l10n.tr("正在扫描 \(targetPath)…", "Scanning \(targetPath)…")
            }
            return l10n.tr(
                "已扫描 \(progress.dirsVisited) 个目录 · \(progress.filesFound) 个文件",
                "Scanned \(l10n.plural(progress.dirsVisited, "folder")) · \(l10n.plural(progress.filesFound, "file"))"
            )
        case .probingDuplicates:
            return l10n.tr("正在比对重复片源…", "Comparing duplicate media copies…")
        case .checkingAssets:
            return l10n.tr("正在检查 NFO 与海报…", "Checking NFO and poster artwork…")
        case .checkingCleanup:
            return l10n.tr("正在扫描垃圾文件与空目录…", "Scanning junk files and empty folders…")
        case .done:
            return l10n.tr("体检完成", "Health check complete")
        }
    }

    static func localizedCleanupReason(_ raw: String, l10n: AppL10n) -> String {
        switch raw {
        case "系统隐藏垃圾":
            return l10n.tr("系统隐藏垃圾", "System Hidden Junk")
        case "样片文件":
            return l10n.tr("样片文件", "Sample Clip")
        case "广告 / 垃圾文件":
            return l10n.tr("广告 / 垃圾文件", "Ad / Junk File")
        case "空目录":
            return l10n.tr("空目录", "Empty Folder")
        default:
            return l10n.coreMessage(raw)
        }
    }

    static func friendlyError(_ error: Error) -> String {
        if let storageErr = error as? StorageError {
            return storageErr.message
        }
        if let tmdbErr = error as? TmdbError {
            return tmdbErr.message
        }
        return error.localizedDescription
    }

    static func localizedError(_ error: Error, l10n: AppL10n) -> String {
        l10n.coreMessage(friendlyError(error))
    }
}
