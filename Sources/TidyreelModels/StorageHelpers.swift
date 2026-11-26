import Foundation

public let ignorableEmptyDirFiles: Set<String> = [".ds_store", "thumbs.db", "desktop.ini"]

/// Visits folders `parallel` at a time starting from `roots` using structured Swift `TaskGroup`.
public func walkDirs(
    roots: [String],
    parallel: Int = 6,
    stop: (@Sendable () -> Bool)? = nil,
    visit: @escaping @Sendable (String) async throws -> [String]
) async throws {
    let limit = max(1, parallel)
    var visited: Set<String> = []
    var queue: [String] = []
    for r in roots where visited.insert(r).inserted {
        queue.append(r)
    }

    try await withThrowingTaskGroup(of: [String].self) { group in
        var active = 0
        var queueHead = 0
        func enqueueAvailable() {
            if stop?() == true || Task.isCancelled {
                queue.removeAll()
                queueHead = 0
                return
            }
            while active < limit && queueHead < queue.count {
                let dir = queue[queueHead]
                queueHead += 1
                active += 1
                group.addTask {
                    try await visit(dir)
                }
            }
            if queueHead >= queue.count {
                queue.removeAll(keepingCapacity: true)
                queueHead = 0
            } else if queueHead >= 1024 && queueHead * 2 >= queue.count {
                queue.removeFirst(queueHead)
                queueHead = 0
            }
        }

        enqueueAvailable()
        while active > 0 {
            guard let subs = try await group.next() else { break }
            active -= 1
            if stop?() != true && !Task.isCancelled {
                for s in subs where visited.insert(s).inserted {
                    queue.append(s)
                }
                enqueueAvailable()
            }
        }
    }
}

private func trimDirPath(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
    return s
}

private func slashDepth(_ p: String) -> Int {
    var count = 0
    for b in p.utf8 where b == 47 {
        count += 1
    }
    return count
}

private func isDirEmpty(
    _ dir: String,
    backend: any StorageBackend,
    knownEmpty: Set<String>
) async throws -> Bool {
    let children: [RemoteEntry]
    do {
        children = try await backend.list(dir, refresh: true)
    } catch let e as StorageError where e.code == .notFound {
        return false
    }
    return children.allSatisfy { e in
        if e.isDir { return knownEmpty.contains(trimDirPath(e.path)) }
        return ignorableEmptyDirFiles.contains(e.name.lowercased())
    }
}

/// Finds directories in `candidateDirs` (deepest first) that are empty or contain only OS metadata junk.
public func findEmptySourceDirs(
    backend: any StorageBackend,
    candidateDirs: [String],
    protectedRoots: Set<String> = [],
    isCancelled: (@Sendable () -> Bool)? = nil
) async throws -> [String] {
    var protected: Set<String> = ["/"]
    for p in protectedRoots where !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        protected.insert(trimDirPath(p))
    }

    var seen: Set<String> = []
    var byDepth: [Int: [String]] = [:]
    for raw in candidateDirs {
        let dir = trimDirPath(raw)
        guard !dir.isEmpty, dir != "/", !protected.contains(dir), seen.insert(dir).inserted else {
            continue
        }
        byDepth[slashDepth(dir), default: []].append(dir)
    }

    let depthsDesc = byDepth.keys.sorted(by: >)
    let maxConcurrency = 6
    var willBeEmpty: Set<String> = []
    var result: [String] = []

    for depth in depthsDesc {
        if isCancelled?() == true || Task.isCancelled { break }
        let levelDirs = (byDepth[depth] ?? []).sorted()
        if levelDirs.isEmpty { continue }

        let knownEmpty = willBeEmpty
        let levelEmpty: [String]
        if levelDirs.count == 1 {
            let dir = levelDirs[0]
            let empty = try await isDirEmpty(dir, backend: backend, knownEmpty: knownEmpty)
            levelEmpty = empty ? [dir] : []
        } else {
            levelEmpty = try await withThrowingTaskGroup(of: (Int, String?).self) { group in
                var nextIndex = 0
                var inFlight = 0
                var hits: [(Int, String)] = []

                func enqueue() {
                    while inFlight < maxConcurrency && nextIndex < levelDirs.count {
                        if isCancelled?() == true || Task.isCancelled { return }
                        let idx = nextIndex
                        let dir = levelDirs[idx]
                        nextIndex += 1
                        inFlight += 1
                        group.addTask {
                            let empty = try await isDirEmpty(dir, backend: backend, knownEmpty: knownEmpty)
                            return (idx, empty ? dir : nil)
                        }
                    }
                }

                enqueue()
                while inFlight > 0 {
                    guard let (idx, hit) = try await group.next() else { break }
                    inFlight -= 1
                    if let hit { hits.append((idx, hit)) }
                    enqueue()
                }

                hits.sort { $0.0 < $1.0 }
                return hits.map(\.1)
            }
        }

        for dir in levelEmpty {
            willBeEmpty.insert(dir)
            result.append(dir)
        }
    }
    return result
}

/// Computes destination collisions and existing-path conflicts (case-insensitively).
public func detectPlanConflicts(ops: [RenameOp], existing: Set<String>) -> [PlanConflict] {
    let moves = ops.filter { $0.kind == .relocate && $0.selected }
    let existingLower = Set(existing.map { $0.lowercased() })
    let sourcesLower = Set(moves.map { $0.src.lowercased() })

    var orderKeys: [String] = []
    var byDst: [String: [RenameOp]] = [:]
    for o in moves {
        let key = o.dst.lowercased()
        if byDst[key] == nil { orderKeys.append(key) }
        byDst[key, default: []].append(o)
    }

    var conflicts: [PlanConflict] = []
    for key in orderKeys {
        guard let list = byDst[key], let first = list.first else { continue }
        if list.count > 1 {
            conflicts.append(PlanConflict(
                ops: list.map(\.id),
                path: first.dst,
                reason: "有 \(list.count) 个文件会被命名为同一个路径"
            ))
        } else if existingLower.contains(key) && !sourcesLower.contains(key) {
            conflicts.append(PlanConflict(
                ops: [first.id],
                path: first.dst,
                reason: "目标位置已存在同名文件或文件夹"
            ))
        }
    }
    return conflicts
}
