import Foundation
import TidyreelModels

public actor CachedBackend: RangeReadableBackend {
    public nonisolated let inner: any StorageBackend
    public let ttl: TimeInterval
    public let maxEntries: Int
    public let maxTotalEntries: Int
    private let now: @Sendable () -> Date

    private final class LRUNode {
        let key: String
        let id: UUID
        let at: Date
        let task: Task<[RemoteEntry], Error>
        var resolvedNames: Set<String>?
        var resolvedLowerNames: Set<String>?
        var entryCount: Int = 0
        weak var prev: LRUNode?
        var next: LRUNode?

        init(key: String, id: UUID, at: Date, task: Task<[RemoteEntry], Error>) {
            self.key = key
            self.id = id
            self.at = at
            self.task = task
        }
    }

    private var cache: [String: LRUNode] = [:]
    private var lruHead: LRUNode?
    private var lruTail: LRUNode?
    private var totalCachedEntries: Int = 0

    public init(
        _ inner: any StorageBackend,
        ttl: TimeInterval = 600,
        maxEntries: Int = 500,
        maxTotalEntries: Int = 20_000,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inner = inner
        self.ttl = ttl
        self.maxEntries = maxEntries
        self.maxTotalEntries = maxTotalEntries
        self.now = now
    }

    private static func normKey(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "/" }
        let nfc = trimmed.precomposedStringWithCanonicalMapping
        let segs = nfc.split(separator: "/", omittingEmptySubsequences: true)
        if segs.isEmpty { return "/" }
        return "/" + segs.joined(separator: "/")
    }

    private static func hasUnsafePathSyntax(_ path: String) -> Bool {
        if path.contains("\\") { return true }
        for seg in path.split(separator: "/", omittingEmptySubsequences: true) {
            if seg == "." || seg == ".." {
                return true
            }
        }
        return false
    }

    private func appendToTail(_ node: LRUNode) {
        node.prev = lruTail
        node.next = nil
        if let tail = lruTail {
            tail.next = node
        } else {
            lruHead = node
        }
        lruTail = node
    }

    private func unlink(_ node: LRUNode) {
        let prev = node.prev
        let next = node.next
        if let prev {
            prev.next = next
        } else {
            lruHead = next
        }
        if let next {
            next.prev = prev
        } else {
            lruTail = prev
        }
        node.prev = nil
        node.next = nil
    }

    private func moveToTail(_ node: LRUNode) {
        guard lruTail !== node else { return }
        unlink(node)
        appendToTail(node)
    }

    private func removeNode(_ node: LRUNode, cancelTask: Bool = false) {
        cache.removeValue(forKey: node.key)
        unlink(node)
        totalCachedEntries = max(0, totalCachedEntries - node.entryCount)
        if cancelTask {
            node.task.cancel()
        }
    }

    private func removeKey(_ key: String, cancelTask: Bool = false) -> Bool {
        guard let node = cache[key] else { return false }
        removeNode(node, cancelTask: cancelTask)
        return true
    }

    private func pruneExpired() {
        let current = now()
        var cur = lruHead
        while let node = cur {
            let next = node.next
            if current.timeIntervalSince(node.at) >= ttl {
                removeNode(node)
            }
            cur = next
        }
    }

    private func pruneForInsert() {
        pruneExpired()
        while cache.count >= maxEntries, let oldest = lruHead {
            removeNode(oldest)
        }
    }

    private func enforceEntryBudget(preservingKey: String?) {
        guard maxTotalEntries > 0 else { return }
        if totalCachedEntries <= maxTotalEntries && cache.count <= maxEntries {
            return
        }
        pruneExpired()
        var cur = lruHead
        while (totalCachedEntries > maxTotalEntries || cache.count > maxEntries), let node = cur {
            let next = node.next
            if let preservingKey, node.key == preservingKey {
                cur = next
                continue
            }
            removeNode(node)
            cur = next
        }
        if totalCachedEntries > maxTotalEntries, let preservingKey, let node = cache[preservingKey] {
            removeNode(node)
        }
    }

    private func recordResolved(key: String, id: UUID, entries: [RemoteEntry]) {
        guard let node = cache[key], node.id == id, node.resolvedNames == nil else {
            return
        }
        var names = Set<String>()
        names.reserveCapacity(entries.count)
        for entry in entries {
            names.insert(entry.name.precomposedStringWithCanonicalMapping)
        }
        node.resolvedNames = names
        node.entryCount = entries.count
        totalCachedEntries += entries.count
        enforceEntryBudget(preservingKey: key)
    }

    private func evictIfMatching(key: String, id: UUID) {
        if let node = cache[key], node.id == id {
            removeNode(node)
        }
    }

    private func fetch(_ dir: String, refresh: Bool) -> (id: UUID, task: Task<[RemoteEntry], Error>) {
        let key = Self.normKey(dir)
        let entryId = UUID()
        let innerBackend = self.inner

        if let replaced = cache[key] {
            removeNode(replaced, cancelTask: true)
        }

        let task = Task<[RemoteEntry], Error> {
            try await innerBackend.list(key, refresh: refresh)
        }
        if maxEntries > 0 {
            if cache.count >= maxEntries {
                pruneForInsert()
            }
            if cache.count < maxEntries {
                let node = LRUNode(key: key, id: entryId, at: now(), task: task)
                cache[key] = node
                appendToTail(node)
            }
        }
        return (entryId, task)
    }

    private func hit(_ dir: String, maxAge: TimeInterval) -> (id: UUID, task: Task<[RemoteEntry], Error>)? {
        let key = Self.normKey(dir)
        guard let node = cache[key] else { return nil }
        if now().timeIntervalSince(node.at) >= maxAge {
            if maxAge >= ttl {
                removeNode(node)
            }
            return nil
        }
        moveToTail(node)
        return (node.id, node.task)
    }

    public func isCached(_ dir: String) -> Bool {
        let key = Self.normKey(dir)
        guard let node = cache[key] else { return false }
        if now().timeIntervalSince(node.at) >= ttl {
            removeNode(node)
            return false
        }
        return true
    }

    public func list(_ dir: String, refresh: Bool = false) async throws -> [RemoteEntry] {
        let key = Self.normKey(dir)
        if !refresh, let cached = hit(key, maxAge: ttl) {
            do {
                let entries = try await cached.task.value
                recordResolved(key: key, id: cached.id, entries: entries)
                return entries
            } catch {
                evictIfMatching(key: key, id: cached.id)
                throw error
            }
        }
        let fetched = fetch(key, refresh: refresh)
        do {
            let entries = try await fetched.task.value
            recordResolved(key: key, id: fetched.id, entries: entries)
            return entries
        } catch {
            evictIfMatching(key: key, id: fetched.id)
            throw error
        }
    }

    /// Returns a cached listing at most `maxAge` seconds old, or fetches a refreshed one.
    public func listRecent(_ dir: String, maxAge: TimeInterval) async throws -> [RemoteEntry] {
        let key = Self.normKey(dir)
        if let cached = hit(key, maxAge: maxAge) {
            do {
                let entries = try await cached.task.value
                recordResolved(key: key, id: cached.id, entries: entries)
                return entries
            } catch {
                evictIfMatching(key: key, id: cached.id)
                throw error
            }
        }
        let fetched = fetch(key, refresh: true)
        do {
            let entries = try await fetched.task.value
            recordResolved(key: key, id: fetched.id, entries: entries)
            return entries
        } catch {
            evictIfMatching(key: key, id: fetched.id)
            throw error
        }
    }

    private func invalidateBatch(dirsOnly: [String], subtrees: [String]) {
        if cache.isEmpty { return }

        var subtreeRoots = Set<String>()
        subtreeRoots.reserveCapacity(subtrees.count)
        for raw in subtrees {
            let norm = Self.normKey(raw)
            if norm == "/" {
                clear()
                return
            }
            subtreeRoots.insert(norm)
        }

        for dir in dirsOnly {
            _ = removeKey(Self.normKey(dir))
        }
        for root in subtreeRoots {
            _ = removeKey(root)
        }

        guard !subtreeRoots.isEmpty, !cache.isEmpty else { return }

        var cur = lruHead
        while let node = cur {
            let next = node.next
            if hasAncestor(in: subtreeRoots, forKey: node.key) {
                removeNode(node)
            }
            cur = next
        }
    }

    private func hasAncestor(in roots: Set<String>, forKey key: String) -> Bool {
        var ancestor = posixDirname(key)
        while ancestor != "/" {
            if roots.contains(ancestor) {
                return true
            }
            ancestor = posixDirname(ancestor)
        }
        return false
    }

    /// Drops `path`, its parent, and everything below it. Invalidating `"/"` clears the entire cache.
    public func invalidate(_ path: String) {
        let norm = Self.normKey(path)
        if norm == "/" {
            clear()
            return
        }
        let parent = Self.normKey(posixDirname(norm))
        invalidateBatch(dirsOnly: [parent], subtrees: [norm])
    }

    private func invalidateAncestors(_ dir: String) {
        var cur = Self.normKey(dir)
        while true {
            let wasCached = removeKey(cur)
            if wasCached || cur == "/" {
                break
            }
            cur = Self.normKey(posixDirname(cur))
        }
    }

    public func clear() {
        var cur = lruHead
        while let node = cur {
            let next = node.next
            node.task.cancel()
            node.prev = nil
            node.next = nil
            cur = next
        }
        cache.removeAll()
        lruHead = nil
        lruTail = nil
        totalCachedEntries = 0
    }

    public nonisolated var supportsServerBatching: Bool {
        inner.supportsServerBatching
    }

    public nonisolated var supportsAtomicRelocate: Bool {
        inner.supportsAtomicRelocate
    }

    public func atomicRelocate(from src: String, to dst: String) async throws {
        let normSrc = Self.normKey(src)
        let normDst = Self.normKey(dst)
        let srcParent = Self.normKey(posixDirname(normSrc))
        let dstParent = Self.normKey(posixDirname(normDst))
        defer {
            invalidateAncestors(dstParent)
            invalidateBatch(dirsOnly: [srcParent, dstParent], subtrees: [normSrc, normDst])
        }
        try await inner.atomicRelocate(from: src, to: dst)
    }

    public func mkdirs(_ dir: String) async throws {
        defer { invalidateAncestors(dir) }
        try await inner.mkdirs(dir)
    }

    public func rename(_ path: String, newName: String) async throws {
        let norm = Self.normKey(path)
        let dir = Self.normKey(posixDirname(norm))
        let target = Self.normKey(posixJoin(dir, newName))
        defer {
            invalidateBatch(dirsOnly: [dir], subtrees: [norm, target])
        }
        try await inner.rename(path, newName: newName)
    }

    public func renameMany(_ dir: String, names: [String: String]) async throws {
        let normDir = Self.normKey(dir)
        defer {
            var subtrees: [String] = []
            subtrees.reserveCapacity(names.count * 2)
            for (oldName, newName) in names {
                subtrees.append(posixJoin(normDir, oldName))
                subtrees.append(posixJoin(normDir, newName))
            }
            invalidateBatch(dirsOnly: [normDir], subtrees: subtrees)
        }
        try await inner.renameMany(dir, names: names)
    }

    public func move(srcDir: String, dstDir: String, names: [String]) async throws {
        let normSrc = Self.normKey(srcDir)
        let normDst = Self.normKey(dstDir)
        defer {
            var subtrees: [String] = []
            subtrees.reserveCapacity(names.count * 2)
            for name in names {
                subtrees.append(posixJoin(normSrc, name))
                subtrees.append(posixJoin(normDst, name))
            }
            invalidateBatch(dirsOnly: [normSrc, normDst], subtrees: subtrees)
        }
        try await inner.move(srcDir: srcDir, dstDir: dstDir, names: names)
    }

    public func remove(dir: String, names: [String]) async throws {
        let normDir = Self.normKey(dir)
        defer {
            var subtrees: [String] = []
            subtrees.reserveCapacity(names.count)
            for name in names {
                subtrees.append(posixJoin(normDir, name))
            }
            invalidateBatch(dirsOnly: [normDir], subtrees: subtrees)
        }
        try await inner.remove(dir: dir, names: names)
    }

    public func exists(_ path: String) async throws -> Bool {
        if !Self.hasUnsafePathSyntax(path) {
            let norm = Self.normKey(path)
            if norm == "/" {
                if let rootNode = cache["/"] {
                    if now().timeIntervalSince(rootNode.at) >= ttl {
                        removeNode(rootNode)
                    } else if rootNode.resolvedNames != nil {
                        moveToTail(rootNode)
                        return true
                    }
                }
            } else {
                let parentKey = Self.normKey(posixDirname(norm))
                if let parentNode = cache[parentKey] {
                    if now().timeIntervalSince(parentNode.at) >= ttl {
                        removeNode(parentNode)
                    } else if let names = parentNode.resolvedNames {
                        moveToTail(parentNode)
                        let childName = posixBasename(norm)
                        if names.contains(childName) {
                            return true
                        }
                        let lowerNames: Set<String>
                        if let existingLower = parentNode.resolvedLowerNames {
                            lowerNames = existingLower
                        } else {
                            var built = Set<String>()
                            built.reserveCapacity(names.count)
                            for name in names {
                                built.insert(name.lowercased())
                            }
                            parentNode.resolvedLowerNames = built
                            lowerNames = built
                        }
                        if !lowerNames.contains(childName.lowercased()) {
                            return false
                        }
                    }
                }
            }
        }
        return try await inner.exists(path)
    }

    public func read(_ path: String) async throws -> Data {
        try await inner.read(path)
    }

    public func readRange(path: String, start: Int64, length: Int) async throws -> Data {
        guard let data = try await readRangeIfSupported(
            backend: inner,
            path: path,
            start: start,
            length: length
        ) else {
            throw StorageError(.other, "不支持分段读取")
        }
        return data
    }

    public func write(_ path: String, bytes: Data) async throws {
        let normParent = posixDirname(Self.normKey(path))
        defer { invalidateAncestors(normParent) }
        try await inner.write(path, bytes: bytes)
    }

    public func ping() async throws {
        try await inner.ping()
    }

    public func close() async {
        clear()
        await inner.close()
    }
}

public func listFresh(
    _ backend: any StorageBackend,
    dir: String,
    maxAge: TimeInterval = 120
) async throws -> [RemoteEntry] {
    if let cached = backend as? CachedBackend {
        return try await cached.listRecent(dir, maxAge: maxAge)
    }
    return try await backend.list(dir, refresh: true)
}
