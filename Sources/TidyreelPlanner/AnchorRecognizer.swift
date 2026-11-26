import Foundation
import TidyreelModels

/// Below this score, a TMDB search hit is rejected and left for manual matching.
public let matchAcceptScore: Double = 0.6

private enum RecognizerRegex {
    static let structural = try! NSRegularExpression(
        pattern: #"^(season|series)[\s._\-]*\d+.*$|^s\d{1,2}$|^第\s*[0-9一二三四五六七八九十百]+\s*[季部].*$|^(specials?|sp|ova|oad|extras?|featurettes?|behind the scenes|bonus|特别篇|特典|花絮|番外|subs?|subtitles?|字幕)$|^(\d{3,4}[pi]|[248]k|uhd|fhd|hdr(10)?\+?|dv|dolby[\s._-]?vision|杜比视界|blu-?ray|web-?dl|remux|高清|超清|蓝光|原盘|国语|粤语|国配|中字|普通话)$"#,
        options: [.caseInsensitive]
    )
    static let bare3to4Digits = try! NSRegularExpression(pattern: #"^\d{3,4}$"#)
    static let digitsOnly1to4 = try! NSRegularExpression(pattern: #"^\d{1,4}$"#)
    static let unitSuffix = try! NSRegularExpression(
        pattern: #"^(?:[pi](?:$|[^A-Za-z])|[kK](?:$|[^A-Za-z])|fps\b|bit\b)"#,
        options: [.caseInsensitive]
    )
    static let extraDir = try! NSRegularExpression(
        pattern: #"^(?:specials?|sp|ova|oad|extras?|featurettes?|behind the scenes|bonus|特别篇|特典|花絮|番外)$"#,
        options: [.caseInsensitive]
    )
    static let strictExtraStem = try! NSRegularExpression(
        pattern: #"^(?:ncop|nced|pv|cm|trailer|teaser|making|featurette|bonus|花絮|特典|预告)"#,
        options: [.caseInsensitive]
    )
    static let trimPrefixEdge = try! NSRegularExpression(pattern: #"^[\s._\-]+|[\s._\-]+$"#)
    static let externalId = try! NSRegularExpression(
        pattern: #"[\{\[]\s*(tmdb|imdb|tvdb)(?:id)?\s*[-=:]\s*(tt\d+|\d+)\s*[\}\]]"#,
        options: [.caseInsensitive]
    )
    static let explicitSxe = try! NSRegularExpression(
        pattern: #"S\d{1,2}\s*E\d{1,3}"#,
        options: [.caseInsensitive]
    )
    static let nfoRoot = try! NSRegularExpression(
        pattern: #"<(tvshow|movie)\b"#,
        options: [.caseInsensitive]
    )
    static let nfoTmdb = try! NSRegularExpression(
        pattern: #"<uniqueid\b[^>]*type=["']tmdb["'][^>]*>\s*(\d+)\s*<|<tmdbid>\s*(\d+)\s*<"#,
        options: [.caseInsensitive]
    )
}

/// Classifies files, infers directory episode sequences, groups by anchor folders/titles,
/// and matches metadata via TitlePin, ExternalIdLookup, existing NFOs, TMDB search, and AltTitleSource.
public final class AnchorRecognizer: Recognizer, Sendable {
    public let parser: any FilenameParser
    public let metadata: any MetadataProvider
    public let altTitles: (any AltTitleSource)?
    public let hint: @Sendable () -> MediaHint
    public let titleRules: @Sendable () -> TitleRules
    public let mediaProbe: (any MediaProbe)?
    public let probeMedia: (@Sendable () -> Bool)?

    public init(
        parser: any FilenameParser,
        metadata: any MetadataProvider,
        altTitles: (any AltTitleSource)? = nil,
        hint: @escaping @Sendable () -> MediaHint = { .mixed },
        titleRules: @escaping @Sendable () -> TitleRules = { TitleRules() },
        mediaProbe: (any MediaProbe)? = nil,
        probeMedia: (@Sendable () -> Bool)? = nil
    ) {
        self.parser = parser
        self.metadata = metadata
        self.altTitles = altTitles
        self.hint = hint
        self.titleRules = titleRules
        self.mediaProbe = mediaProbe
        self.probeMedia = probeMedia
    }

    private static let maxNfoRangeReadBytes = 512 * 1024
    private static let maxNfoFullReadBytes: Int64 = 2 * 1024 * 1024

    public func recognize(
        connection: ConnectionId,
        roots: [String],
        files: [RemoteEntry],
        read: (@Sendable (String) async throws -> Data)? = nil,
        backend: (any StorageBackend)? = nil
    ) async throws -> ScanResult {
        let rootDirs = roots.map(trimTrailingSlash)
        var nfosByLower: [String: NfoEntry] = [:]
        for e in files where !e.isDir && e.name.lowercased().hasSuffix(".nfo") {
            nfosByLower[e.path.lowercased()] = NfoEntry(path: e.path, size: e.size)
        }

        // Detect Blu-ray (BDMV) and DVD (VIDEO_TS) disc folders so their inner stream files
        // are never touched and each disc is treated as one atomic movie unit.
        var discDirsSet: Set<String> = []
        for e in files {
            let upper = e.name.uppercased()
            if e.isDir && (upper == "BDMV" || upper == "VIDEO_TS") {
                let parent = dirOf(e.path)
                if isWithinRoots(parent, rootDirs: rootDirs) {
                    discDirsSet.insert(parent)
                }
                continue
            }
            var cur = dirOf(e.path)
            while cur != "/" {
                let seg = baseOf(cur).uppercased()
                if seg == "BDMV" || seg == "VIDEO_TS" {
                    let parent = dirOf(cur)
                    if isWithinRoots(parent, rootDirs: rootDirs) {
                        discDirsSet.insert(parent)
                    }
                    break
                }
                cur = dirOf(cur)
            }
        }

        let sortedDiscDirs = discDirsSet.sorted()
        var discSizes: [String: Int64] = [:]
        for d in sortedDiscDirs { discSizes[d] = 0 }

        func enclosingDiscDir(_ path: String) -> String? {
            if discDirsSet.isEmpty { return nil }
            var cur = dirOf(path)
            var matched: String?
            while cur != "/" {
                if discDirsSet.contains(cur) {
                    matched = cur
                }
                cur = dirOf(cur)
            }
            return matched
        }

        var entries: [RemoteEntry] = []
        entries.reserveCapacity(files.count)
        for e in files where !e.isDir {
            if let disc = enclosingDiscDir(e.path) {
                discSizes[disc, default: 0] += e.size
            } else {
                entries.append(e)
            }
        }
        entries.sort { $0.path < $1.path }

        var chainCache: [String: [String]] = [:]
        var parentNamesCache: [String: [String]] = [:]
        func cachedChain(forDir dir: String) -> [String] {
            if let hit = chainCache[dir] { return hit }
            let computed = directoryChainForDir(dir, roots: rootDirs)
            chainCache[dir] = computed
            return computed
        }
        func cachedParentNames(forDir dir: String) -> [String] {
            if let hit = parentNamesCache[dir] { return hit }
            let names = cachedChain(forDir: dir).map(baseOf)
            parentNamesCache[dir] = names
            return names
        }

        var videos: [RecognizerEntry] = []
        var followers: [RecognizerEntry] = []
        var unassigned: [ScanFile] = []

        for d in sortedDiscDirs {
            let parentDirs = parentDirsInRoots(d, rootDirs: rootDirs)
            var parsed = parser.parse(baseOf(d), parentDirs: parentDirs)
            parsed.isDisc = true
            parsed.kind = .movie
            let discFile = ScanFile(
                path: d,
                name: baseOf(d),
                size: discSizes[d] ?? 0,
                role: .video,
                parsed: parsed,
                isDiscDir: true
            )
            let chain = rootDirs.contains(d) ? [d] : ([d] + cachedChain(forDir: dirOf(d)))
            videos.append(RecognizerEntry(file: discFile, chain: chain, modified: nil))
        }

        for e in entries {
            let role = parser.classify(e.name)
            let dir = dirOf(e.path)
            let chain = cachedChain(forDir: dir)
            let wantsParse = (role == .video || role == .subtitle || role == .sidecar)
            let parsed = wantsParse
                ? parser.parse(e.name, parentDirs: cachedParentNames(forDir: dir))
                : nil
            let file = ScanFile(
                path: e.path,
                name: e.name,
                size: e.size,
                role: role,
                parsed: parsed
            )
            switch role {
            case .video:
                videos.append(RecognizerEntry(file: file, chain: chain, modified: e.modified))
            case .subtitle, .sidecar:
                followers.append(RecognizerEntry(file: file, chain: chain, modified: e.modified))
            case .junk, .other:
                unassigned.append(file)
            }
        }

        if let backend, let mediaProbe, probeMedia?() == true {
            videos = await probeVideos(videos, probe: mediaProbe, backend: backend, connection: connection)
        }

        let currentHint = hint()
        inferDirectoryContext(&videos, hint: currentHint, rootDirs: rootDirs)

        var drafts = promoteToRoots(draftGroups(videos, rootDirs: rootDirs), rootDirs: rootDirs)
        let draftIndex = FollowerDraftIndex(drafts: drafts)

        for f in followers {
            if let draftIdx = homeOf(f, drafts: drafts, index: draftIndex) {
                drafts[draftIdx].followers.append(f.file)
            } else {
                unassigned.append(f.file)
            }
        }

        let cache = SearchCache(metadata: metadata)
        let rules = titleRules()
        let finalDrafts = drafts
        let nfosSnapshot = nfosByLower

        let lookupResults = try await runBoundedLookupWorkers(
            drafts: finalDrafts,
            concurrency: 4
        ) { draft in
            try await self.lookup(
                draft: draft,
                cache: cache,
                hint: currentHint,
                rules: rules,
                nfosByLower: nfosSnapshot,
                read: read,
                backend: backend
            )
        }

        var usedIds: Set<String> = []
        var groups = lookupResults.map { toGroup($0, usedIds: &usedIds) }
        groups.sort { a, b in
            a.rootDir != b.rootDir ? a.rootDir < b.rootDir : a.anchorTitle < b.anchorTitle
        }
        unassigned.sort { $0.path < $1.path }

        return ScanResult(
            connection: connection,
            roots: roots,
            groups: groups,
            unassigned: unassigned
        )
    }

    // MARK: - Media Probing & Directory Context Inference

    private func probeVideos(
        _ videos: [RecognizerEntry],
        probe: any MediaProbe,
        backend: any StorageBackend,
        connection: ConnectionId
    ) async -> [RecognizerEntry] {
        var targetIndices: [Int] = []
        for (i, v) in videos.enumerated() {
            let f = v.file
            if f.isDiscDir { continue }
            let p = f.parsed
            let needsProbe = p == nil
                || (p?.resolution ?? "").isEmpty
                || (p?.extraInfo ?? "").isEmpty
                || (p?.confidence ?? 0) < 0.7
            if needsProbe {
                targetIndices.append(i)
            }
        }
        if targetIndices.isEmpty { return videos }

        let queue = IndexQueue(count: targetIndices.count)
        let snapshot = videos
        let workerCount = min(4, targetIndices.count)

        let updates = await withTaskGroup(of: [(Int, ScanFile)].self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    var local: [(Int, ScanFile)] = []
                    while let qIdx = await queue.next() {
                        let idx = targetIndices[qIdx]
                        let entry = snapshot[idx]
                        let file = entry.file
                        guard let info = await probe.probe(
                            backend: backend,
                            connection: connection,
                            path: file.path,
                            fileSize: file.size,
                            modifiedAt: entry.modified
                        ) else {
                            continue
                        }
                        var p = file.parsed ?? ParsedName()
                        if (p.resolution ?? "").isEmpty {
                            p.resolution = info.resolution
                        }
                        if (p.extraInfo ?? "").isEmpty {
                            p.extraInfo = info.extraInfoSummary
                        }
                        var kind = p.kind
                        var confidence = p.confidence
                        if let durSec = info.durationSeconds {
                            if durSec < 60.0 {
                                confidence = min(confidence, 0.35)
                            } else if durSec >= 65.0 * 60.0
                                && p.episodes.isEmpty
                                && p.absolute == nil
                                && kind == .unknown {
                                kind = .movie
                                confidence = min(1.0, confidence + 0.2)
                            }
                        }
                        p.probe = info
                        p.kind = kind
                        p.confidence = (confidence * 100.0).rounded() / 100.0

                        var updated = file
                        updated.parsed = p
                        local.append((idx, updated))
                    }
                    return local
                }
            }

            var merged: [(Int, ScanFile)] = []
            for await chunk in group {
                merged.append(contentsOf: chunk)
            }
            return merged
        }

        var result = videos
        for (idx, updatedFile) in updates {
            let prev = result[idx]
            result[idx] = RecognizerEntry(file: updatedFile, chain: prev.chain, modified: prev.modified)
        }
        return result
    }

    private func inferDirectoryContext(
        _ videos: inout [RecognizerEntry],
        hint: MediaHint,
        rootDirs: [String]
    ) {
        if hint == .movie { return }

        var dirOrder: [String] = []
        var allByDir: [String: [Int]] = [:]
        var regularByDir: [String: [Int]] = [:]

        for (i, v) in videos.enumerated() {
            let f = v.file
            if f.isDiscDir { continue }
            let dir = dirOf(f.path)
            if regexMatches(RecognizerRegex.extraDir, baseOf(dir)) { continue }
            if allByDir[dir] == nil { dirOrder.append(dir) }
            allByDir[dir, default: []].append(i)
            let kind = f.parsed?.kind
            if kind != .extra && kind != .special {
                regularByDir[dir, default: []].append(i)
            }
        }

        for dir in dirOrder {
            let allIndices = allByDir[dir] ?? []
            let reg = regularByDir[dir] ?? []
            let indices: [Int]
            if reg.count >= 2 {
                indices = reg
            } else if reg.isEmpty && allIndices.count >= 2 && allIndices.allSatisfy({ idx in
                let f = videos[idx].file
                let p = f.parsed
                return (p == nil || (p!.episodes.isEmpty && p!.absolute == nil))
                    && !regexMatches(RecognizerRegex.strictExtraStem, stem(f.name))
            }) {
                indices = allIndices
            } else {
                continue
            }

            let needsCount = indices.filter { idx in
                let f = videos[idx].file
                let p = f.parsed
                return p == nil
                    || (p!.episodes.isEmpty && p!.absolute == nil)
                    || p!.confidence < 0.7
                    || regexMatches(RecognizerRegex.bare3to4Digits, stem(f.name))
            }.count
            if needsCount < 2 { continue }

            let stemCharsList = indices.map { Array(stem(videos[$0].file.name)) }
            var prefixChars = commonPrefixChars(stemCharsList)
            while let last = prefixChars.last, isAsciiDigitChar(last) {
                prefixChars.removeLast()
            }
            let prefixLen = prefixChars.count
            let tails = stemCharsList.map { Array($0.dropFirst(prefixLen)) }
            var suffixChars = commonSuffixChars(tails)
            while let first = suffixChars.first, isAsciiDigitChar(first) {
                suffixChars.removeFirst()
            }
            let suffix = String(suffixChars)
            if !suffix.isEmpty && regexMatches(RecognizerRegex.unitSuffix, suffix) {
                continue
            }

            let prefix = String(prefixChars)
            let suffixLen = suffixChars.count
            var nums: [Int] = []
            nums.reserveCapacity(stemCharsList.count)
            var valid = true
            for chars in stemCharsList {
                guard prefixLen + suffixLen <= chars.count else {
                    valid = false
                    break
                }
                let mid = String(chars[prefixLen..<(chars.count - suffixLen)])
                guard regexMatches(RecognizerRegex.digitsOnly1to4, mid),
                      let n = Int(mid),
                      n >= 1, n <= 2500 else {
                    valid = false
                    break
                }
                nums.append(n)
            }
            if !valid { continue }
            if Set(nums).count != nums.count { continue }

            let pureNumeric = prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !pureNumeric && nums.allSatisfy({ $0 >= 1900 && $0 <= 2099 }) {
                continue
            }
            if !pureNumeric && indices.allSatisfy({ idx in
                guard let p = videos[idx].file.parsed else { return false }
                return p.kind == .movie && p.year != nil && p.confidence >= 0.7
            }) {
                continue
            }

            let sorted = nums.sorted()
            if sorted.count == 2 {
                if sorted[1] - sorted[0] > 5 { continue }
            } else {
                let avgStep = Double(sorted.last! - sorted.first!) / Double(sorted.count - 1)
                var minGap = sorted[1] - sorted[0]
                var maxGap = minGap
                for j in 2..<sorted.count {
                    let g = sorted[j] - sorted[j - 1]
                    if g < minGap { minGap = g }
                    if g > maxGap { maxGap = g }
                }
                if avgStep > 5.0 || minGap > 3 || maxGap > 25 { continue }
            }

            let maxNum = sorted.last!
            let sampleChain = videos[indices[0]].chain
            let titleDir = sampleChain.first { d in
                d != "/" && !regexMatches(RecognizerRegex.structural, baseOf(d))
            }
            var dirTitle: String?
            if let titleDir {
                let parsedDir = parser.parse(
                    baseOf(titleDir),
                    parentDirs: parentDirsInRoots(titleDir, rootDirs: rootDirs)
                )
                if let t = parsedDir.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    dirTitle = t
                } else if pureNumeric {
                    dirTitle = baseOf(titleDir)
                }
            }
            let prefixTitle = regexReplaceAll(RecognizerRegex.trimPrefixEdge, in: prefix, with: "")

            for (k, idx) in indices.enumerated() {
                let n = nums[k]
                let entry = videos[idx]
                let file = entry.file
                var p = file.parsed ?? ParsedName()
                let useAbsolute = p.season == nil && (maxNum > 30 || hint == .anime)
                let nextTitle: String?
                if pureNumeric, let dirTitle {
                    nextTitle = dirTitle
                } else if let existingTitle = p.title, !existingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    nextTitle = existingTitle
                } else {
                    nextTitle = dirTitle ?? (prefixTitle.isEmpty ? nil : prefixTitle)
                }
                let nextConf = max(p.confidence, 0.8)
                p.title = nextTitle
                p.kind = .episode
                p.episodes = useAbsolute ? [] : [n]
                p.absolute = useAbsolute ? n : nil
                p.confidence = (nextConf * 100.0).rounded() / 100.0

                var updated = file
                updated.parsed = p
                videos[idx] = RecognizerEntry(file: updated, chain: entry.chain, modified: entry.modified)
            }
        }
    }

    // MARK: - Grouping & Root Promotion

    private func draftGroups(_ videos: [RecognizerEntry], rootDirs: [String]) -> [DraftGroup] {
        var drafts: [DraftGroup] = []
        var bucketOrder: [String] = []
        var buckets: [String: [RecognizerEntry]] = [:]
        var titled: [String: Bool] = [:]
        var nextId = 0

        for v in videos {
            if v.file.isDiscDir {
                let dir = v.file.path
                drafts.append(DraftGroup(
                    id: nextId,
                    dir: dir,
                    videos: [v],
                    folderTitle: v.file.parsed?.title,
                    isRoot: rootDirs.contains(dir)
                ))
                nextId += 1
                continue
            }
            let titleDirs = v.chain.filter { !regexMatches(RecognizerRegex.structural, baseOf($0)) }
            let dir = titleDirs.first ?? v.chain[0]
            if buckets[dir] == nil { bucketOrder.append(dir) }
            buckets[dir, default: []].append(v)
            titled[dir] = !titleDirs.isEmpty
        }

        for dir in bucketOrder {
            guard let vs = buckets[dir] else { continue }
            let folderTitle: String? = (titled[dir] == true)
                ? parser.parse(baseOf(dir), parentDirs: parentDirsInRoots(dir, rootDirs: rootDirs)).title
                : nil
            let isRoot = rootDirs.contains(dir)

            var keyOrder: [String] = []
            var byKey: [String: [RecognizerEntry]] = [:]
            for v in vs {
                let k = normTitle(v.file.parsed?.title ?? "")
                if byKey[k] == nil { keyOrder.append(k) }
                byKey[k, default: []].append(v)
            }
            // Stable sort descending by count:
            var keys = keyOrder.filter { !$0.isEmpty }
            let keyRank = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
            keys.sort { a, b in
                let ca = byKey[a]?.count ?? 0
                let cb = byKey[b]?.count ?? 0
                if ca != cb { return ca > cb }
                return (keyRank[a] ?? 0) < (keyRank[b] ?? 0)
            }

            var split = false
            if keys.count >= 2 {
                let explained = folderTitle != nil
                    && keys.contains { titleSimilarity(folderTitle!, $0) >= 0.6 }
                let dominant = Double(byKey[keys[0]]?.count ?? 0) / Double(vs.count) > 0.6
                split = folderTitle == nil || !(explained || dominant)
            }

            if !split {
                drafts.append(DraftGroup(
                    id: nextId,
                    dir: dir,
                    videos: vs,
                    folderTitle: folderTitle,
                    isRoot: isRoot
                ))
                nextId += 1
            } else {
                let untitled = byKey[""] ?? []
                for (i, k) in keys.enumerated() {
                    var groupVideos = byKey[k] ?? []
                    if i == 0 {
                        groupVideos.append(contentsOf: untitled)
                    }
                    drafts.append(DraftGroup(
                        id: nextId,
                        dir: dir,
                        videos: groupVideos,
                        folderTitle: nil,
                        isRoot: isRoot
                    ))
                    nextId += 1
                }
            }
        }

        return drafts
    }

    private func promoteToRoots(_ drafts: [DraftGroup], rootDirs: [String]) -> [DraftGroup] {
        var out = drafts
        for root in rootDirs {
            let rootName = baseOf(root)
            let hasParentSlash = root.lastIndex(of: "/").map { $0 > root.startIndex } ?? false
            if !hasParentSlash
                || regexMatches(RecognizerRegex.structural, rootName)
                || isGenericContainerDir(rootName) {
                continue
            }
            let insideIndices = out.indices.filter { idx in
                let d = out[idx]
                return d.dir == root || d.dir.hasPrefix("\(root)/")
            }
            guard insideIndices.count == 1 else { continue }
            let idx = insideIndices[0]
            let d = out[idx]
            guard d.dir != root, dirOf(d.dir) == root else { continue }
            if d.videos.contains(where: { $0.file.isDiscDir }) { continue }
            out[idx] = DraftGroup(
                id: d.id,
                dir: root,
                videos: d.videos,
                folderTitle: d.folderTitle,
                isRoot: true,
                originalDir: d.dir
            )
        }
        return out
    }

    private func homeOf(
        _ f: RecognizerEntry,
        drafts: [DraftGroup],
        index: FollowerDraftIndex
    ) -> Int? {
        let fdir = dirOf(f.file.path)
        var checked: Set<Int> = []
        var best: Int?

        // 1. Check drafts that already have a video in the follower's exact directory.
        for idx in index.byVideoDir[fdir] ?? [] {
            checked.insert(idx)
            guard let m = drafts[idx].videoIndex.match(f.file) else { continue }
            if dirOf(m.video.path) == fdir { return idx }
            if best == nil { best = idx }
        }

        // 2. Check enclosing drafts along the follower's directory chain.
        var deepestEnclosing: [Int]?
        for anc in f.chain {
            guard let list = index.byDir[anc] else { continue }
            if deepestEnclosing == nil { deepestEnclosing = list }
            for idx in list {
                guard checked.insert(idx).inserted else { continue }
                guard let m = drafts[idx].videoIndex.match(f.file) else { continue }
                if dirOf(m.video.path) == fdir { return idx }
                if best == nil { best = idx }
            }
        }
        if let best { return best }

        // 3. Fall back to the unambiguous enclosing group folder.
        if let deepestEnclosing {
            return deepestEnclosing.count == 1 ? deepestEnclosing[0] : nil
        }

        // 4. Follower sits outside all group folders (e.g. a sibling Subs/ dir).
        // Indexed lookup avoids O(F * G) scans while preserving drafts.indices priority.
        var candidates: [Int] = []
        var seenCandidates: Set<Int> = []
        func collect(_ list: [Int]?) {
            guard let list else { return }
            for idx in list where !checked.contains(idx) && seenCandidates.insert(idx).inserted {
                candidates.append(idx)
            }
        }

        let fbl = stem(f.file.name).lowercased()
        if !fbl.isEmpty {
            collect(index.byStemLower[fbl])
            var pos = fbl.endIndex
            while pos > fbl.startIndex {
                pos = fbl.index(before: pos)
                if pos == fbl.startIndex { break }
                if !isAfterBaseDelimiter(fbl[pos]) { continue }
                collect(index.byStemLower[String(fbl[..<pos])])
            }
        }

        if let pf = f.file.parsed, let n = pf.episodes.first ?? pf.absolute {
            if let s = pf.season {
                collect(index.bySeasonEpisode[EpisodeRef(s, n)])
                collect(index.byNilSeasonEpisode[n])
            } else {
                collect(index.byEpisode[n])
            }
        }

        if candidates.count > 1 {
            candidates.sort()
        }
        for idx in candidates {
            if drafts[idx].videoIndex.match(f.file) != nil {
                return idx
            }
        }
        return nil
    }

    // MARK: - Metadata Lookup & Scoring

    private func lookup(
        draft d: DraftGroup,
        cache: SearchCache,
        hint: MediaHint,
        rules: TitleRules,
        nfosByLower: [String: NfoEntry],
        read: (@Sendable (String) async throws -> Data)?,
        backend: (any StorageBackend)?
    ) async throws -> LookupResult {
        let vids = d.videoFiles
        let main = vids.filter { $0.parsed?.kind != .extra }
        let tvVotes = main.filter { looksTv($0.parsed) }.count
        let isTvLikely = !main.isEmpty && tvVotes * 2 > main.count

        var kind: MediaKind
        switch hint {
        case .movie:
            kind = .movie
        case .tv:
            kind = main.isEmpty ? .movie : .episode
        case .anime:
            kind = (isTvLikely || main.count > 1) ? .episode : .movie
        case .mixed:
            kind = isTvLikely ? .episode : .movie
        }

        let fileTitle = mostCommonString(vids.compactMap { v -> String? in
            guard let t = v.parsed?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
                return nil
            }
            return t
        })

        let year = mostCommonInt(vids.compactMap { $0.parsed?.year })
            ?? (d.folderTitle == nil ? nil : parser.parse(baseOf(d.dir)).year)

        let rawQueries: [String]
        if d.isRoot {
            rawQueries = [fileTitle, d.folderTitle].compactMap { $0 }
        } else {
            rawQueries = [d.folderTitle, fileTitle].compactMap { $0 }
        }

        var seenQueryExact: Set<String> = []
        var queries: [String] = []
        for rq in rawQueries {
            let cleaned = applyRewrites(rq, rewrites: rules.cleanups)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !normTitle(cleaned).isEmpty && seenQueryExact.insert(cleaned).inserted {
                queries.append(cleaned)
            }
        }

        var match: Candidate?
        var score = 0.0
        var anchor = queries.first

        func tryQuery(
            _ q: String,
            scoreAs: [String]? = nil,
            searchKind: MediaKind? = nil,
            acceptScore: Double = matchAcceptScore,
            recordScore: Bool = true
        ) async throws -> Bool {
            let k: MediaKind = ((searchKind ?? kind) == .movie) ? .movie : .episode
            let yearTries: [Int?] = year != nil ? [year, nil] : [nil]
            for y in yearTries {
                let results = try await cache.search(query: q, kind: k, year: y)
                var best: Candidate?
                var bestScore = 0.0
                for c in results.prefix(5) {
                    let baseSim = (scoreAs ?? [q]).reduce(0.0) { acc, t in
                        max(acc, scoreCandidate(query: t, year: year, candidate: c))
                    }
                    let bonus = (hint == .anime && c.originCountry == "JP") ? 0.05 : 0.0
                    let s = baseSim + bonus
                    if s > bestScore {
                        best = c
                        bestScore = s
                    }
                }
                if recordScore {
                    score = max(score, min(bestScore, 1.0))
                }
                if let best, bestScore >= acceptScore {
                    match = best
                    score = min(bestScore, 1.0)
                    return true
                }
            }
            return false
        }

        // 1. TitlePin wins over any search.
        let lowerNames = [baseOf(d.dir), d.folderTitle, fileTitle]
            .compactMap { $0?.lowercased() }
        let pin = rules.pins.first { p in
            let kw = p.keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !kw.isEmpty && lowerNames.contains(where: { $0.contains(kw) })
        }

        // 2. ExternalIdLookup ({tmdb-...}, {imdb-...}, {tvdb-...}).
        let extId = (pin == nil) ? externalIdOf(draft: d, vids: vids) : nil
        var extMatch: Candidate?
        if let extId, let extLookup = metadata as? any ExternalIdLookup {
            extMatch = try await lookupExternalId(
                extLookup,
                ext: extId,
                preferredKind: kind,
                hint: hint
            )
        }

        // 3. Existing scraped .nfo (`tvshow.nfo` / `movie.nfo` / `<video>.nfo`).
        let scraped = (pin == nil && extMatch == nil && read != nil)
            ? try await fromNfo(
                draft: d,
                vids: vids,
                nfosByLower: nfosByLower,
                read: read!,
                backend: backend
            )
            : nil

        if pin != nil || extMatch != nil || scraped != nil {
            let resolved = pin?.match ?? extMatch ?? scraped!.match
            match = resolved
            score = 1.0
            kind = (resolved.kind == .movie) ? .movie : .episode
        } else {
            for q in queries {
                if try await tryQuery(q) {
                    anchor = q
                    break
                }
            }
        }

        // 4. AltTitleSource (Bangumi / AniList) romaji fallback.
        if match == nil, let altTitles, (hint == .mixed || hint == .anime) {
            outerAlt: for q in queries where !hasCjk(q) {
                let alts = await altTitles.altTitles(q)
                if alts.isEmpty { continue }
                let scoreNames = [q] + alts
                for a in alts.prefix(4) {
                    if try await tryQuery(a, scoreAs: scoreNames) {
                        anchor = q
                        break outerAlt
                    }
                }
            }
        }

        // 5. Relaxed queries (strip sort letter, brackets, single-language script).
        if match == nil {
            var tried = Set(queries.map(normTitle))
            outerRelaxed: for q in queries {
                for r in relaxedQueries(q, rawName: baseOf(d.dir)) {
                    guard tried.insert(normTitle(r)).inserted else { continue }
                    if try await tryQuery(r) {
                        anchor = r
                        break outerRelaxed
                    }
                }
            }
        }

        // 6. Cross-kind fallback in mixed mode.
        if match == nil && hint == .mixed {
            let fallbackKind: MediaKind?
            switch kind {
            case .movie where main.count <= 1 || main.contains(where: { $0.parsed?.kind == .unknown }):
                fallbackKind = .episode
            case .episode where main.count == 1 && !hasExplicitSxe(main[0]):
                fallbackKind = .movie
            default:
                fallbackKind = nil
            }
            if let fallbackKind {
                var triedFallback: Set<String> = []
                var fallbackQueries = queries
                for q in queries {
                    fallbackQueries.append(contentsOf: relaxedQueries(q, rawName: baseOf(d.dir)))
                }
                for q in fallbackQueries {
                    guard triedFallback.insert(normTitle(q)).inserted else { continue }
                    if try await tryQuery(
                        q,
                        searchKind: fallbackKind,
                        acceptScore: 0.72,
                        recordScore: false
                    ) {
                        kind = fallbackKind
                        anchor = q
                        break
                    }
                }
            }
        }

        let finalAnchor = anchor
            ?? match?.title
            ?? (vids.first.map { stem($0.name) } ?? baseOf(d.dir))

        let showDetail: ShowDetail?
        if let scrapedShow = scraped?.show {
            showDetail = scrapedShow
        } else if let m = match, kind == .episode {
            showDetail = try await metadata.show(m.tmdbId)
        } else {
            showDetail = nil
        }

        // Enrich with Chinese title from show() / movie() detail when search returned non-Han title.
        if let m = match, !hasHan(m.title) {
            var detail: Candidate? = showDetail?.info ?? scraped?.movie?.info
            if detail == nil && m.kind == .movie {
                detail = (try? await metadata.movie(m.tmdbId))?.info
            }
            match = chineseNamed(m, detail: detail)
        }

        let (suggestedStrategy, suggestedReason) = (kind == .episode)
            ? suggestSeasonStrategy(files: vids, show: showDetail)
            : (nil, nil)

        return LookupResult(
            draft: d,
            vids: vids,
            kind: kind,
            anchor: finalAnchor,
            year: year,
            match: match,
            score: score,
            show: showDetail,
            suggestedStrategy: suggestedStrategy,
            suggestedStrategyReason: suggestedReason
        )
    }

    private func externalIdOf(draft d: DraftGroup, vids: [ScanFile]) -> ExternalId? {
        for v in vids {
            if let ext = v.parsed?.externalId { return ext }
        }
        var candidates: [String] = [baseOf(d.dir)]
        if let orig = d.originalDir {
            candidates.append(baseOf(orig))
        }
        candidates.append(contentsOf: vids.map(\.name))
        for text in candidates {
            if let parsed = Self.parseExternalId(text) {
                return parsed
            }
        }
        return nil
    }

    private static func parseExternalId(_ text: String) -> ExternalId? {
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = RecognizerRegex.externalId.firstMatch(in: text, range: full),
              let r1 = Range(m.range(at: 1), in: text),
              let r2 = Range(m.range(at: 2), in: text) else {
            return nil
        }
        let source = text[r1].lowercased()
        let id = text[r2].lowercased()
        if source == "imdb" && !id.hasPrefix("tt") { return nil }
        if source != "imdb" && id.hasPrefix("tt") { return nil }
        return ExternalId(source, id)
    }

    private func lookupExternalId(
        _ lookup: any ExternalIdLookup,
        ext: ExternalId,
        preferredKind: MediaKind,
        hint: MediaHint
    ) async throws -> Candidate? {
        let preferred: MediaKind = (preferredKind == .movie) ? .movie : .episode
        do {
            if let first = try await lookup.findByExternalId(
                source: ext.source,
                id: ext.id,
                kind: preferred
            ) {
                return first
            }
            if hint == .mixed {
                let altKind: MediaKind = (preferred == .movie) ? .episode : .movie
                return try await lookup.findByExternalId(
                    source: ext.source,
                    id: ext.id,
                    kind: altKind
                )
            }
        } catch {
            if isFatalLookupError(error) { throw error }
            return nil
        }
        return nil
    }

    private func hasExplicitSxe(_ v: ScanFile) -> Bool {
        if let p = v.parsed, p.season != nil, !p.episodes.isEmpty {
            return true
        }
        return regexMatches(RecognizerRegex.explicitSxe, v.name)
    }

    private func fromNfo(
        draft d: DraftGroup,
        vids: [ScanFile],
        nfosByLower: [String: NfoEntry],
        read: @Sendable (String) async throws -> Data,
        backend: (any StorageBackend)?
    ) async throws -> (match: Candidate, show: ShowDetail?, movie: MovieDetail?)? {
        var dirs = [d.dir]
        if let orig = d.originalDir, orig != d.dir {
            dirs.append(orig)
        }
        var candidatePaths: [String] = []
        var seen: Set<String> = []
        func addCandidate(_ p: String) {
            if seen.insert(p.lowercased()).inserted {
                candidatePaths.append(p)
            }
        }
        for dir in dirs {
            addCandidate(joinPath(dir, "tvshow.nfo"))
            addCandidate(joinPath(dir, "movie.nfo"))
        }
        if vids.count == 1 {
            let v = vids[0]
            addCandidate(joinPath(dirOf(v.path), "\(stem(v.name)).nfo"))
        }

        for candidatePath in candidatePaths {
            guard let nfoEntry = nfosByLower[candidatePath.lowercased()] else { continue }
            let actualPath = nfoEntry.path
            do {
                let data: Data
                if let be = backend,
                   let ranged = try await readRangeIfSupported(
                       backend: be,
                       path: actualPath,
                       start: 0,
                       length: Self.maxNfoRangeReadBytes
                   ) {
                    data = ranged
                } else {
                    if nfoEntry.size > Self.maxNfoFullReadBytes {
                        continue
                    }
                    data = try await read(actualPath)
                }
                let text = String(decoding: data, as: UTF8.self)
                let full = NSRange(text.startIndex..<text.endIndex, in: text)
                guard let rootMatch = RecognizerRegex.nfoRoot.firstMatch(in: text, range: full),
                      let rootRange = Range(rootMatch.range(at: 1), in: text) else {
                    continue
                }
                let rootTag = text[rootRange].lowercased()
                guard let idMatch = RecognizerRegex.nfoTmdb.firstMatch(in: text, range: full) else {
                    continue
                }
                let idStr: String?
                if idMatch.range(at: 1).location != NSNotFound,
                   let r1 = Range(idMatch.range(at: 1), in: text) {
                    idStr = String(text[r1])
                } else if idMatch.range(at: 2).location != NSNotFound,
                          let r2 = Range(idMatch.range(at: 2), in: text) {
                    idStr = String(text[r2])
                } else {
                    idStr = nil
                }
                guard let idStr, let tmdbId = Int(idStr) else { continue }
                if rootTag == "movie" {
                    let detail = try await metadata.movie(tmdbId)
                    return (match: detail.info, show: nil, movie: detail)
                } else {
                    let detail = try await metadata.show(tmdbId)
                    return (match: detail.info, show: detail, movie: nil)
                }
            } catch {
                if isFatalLookupError(error) { throw error }
                continue
            }
        }
        return nil
    }

    private func toGroup(_ l: LookupResult, usedIds: inout Set<String>) -> MediaGroup {
        let key = "\(l.draft.dir)|\(l.kind.rawValue)|\(normTitle(l.anchor))"
        var id = "g-\(stableHash(key))"
        var n = 2
        while !usedIds.insert(id).inserted {
            id = "g-\(stableHash("\(key)|\(n)"))"
            n += 1
        }
        var all = l.vids + l.draft.followers
        all.sort { $0.path < $1.path }
        return MediaGroup(
            id: GroupId(id),
            kind: l.kind,
            anchorTitle: l.anchor,
            anchorYear: l.year,
            rootDir: l.draft.dir,
            files: all,
            match: l.match,
            matchScore: l.score,
            show: l.show,
            suggestedStrategy: l.suggestedStrategy,
            suggestedStrategyReason: l.suggestedStrategyReason
        )
    }

    private func scoreCandidate(query: String, year: Int?, candidate c: Candidate) -> Double {
        let names = ([c.title, c.englishTitle, c.originalTitle].compactMap { $0 }) + c.aliases
        let titleSim = names.reduce(0.0) { max($0, titleSimilarity(query, $1)) }
        let yearScore: Double
        if let year, let cy = c.year {
            switch abs(year - cy) {
            case 0: yearScore = 1.0
            case 1: yearScore = 0.7
            default: yearScore = 0.0
            }
        } else {
            yearScore = 0.5
        }
        return 0.75 * titleSim + 0.25 * yearScore
    }

    private func looksTv(_ p: ParsedName?) -> Bool {
        guard let p else { return false }
        return p.kind == .episode
            || p.kind == .special
            || p.season != nil
            || !p.episodes.isEmpty
            || p.absolute != nil
    }
}

// MARK: - Internal Concurrency & Data Structures

private struct NfoEntry: Sendable {
    let path: String
    let size: Int64
}

private struct RecognizerEntry: Sendable {
    var file: ScanFile
    let chain: [String]
    let modified: Date?
}

private struct FollowerDraftIndex {
    let byDir: [String: [Int]]
    let byVideoDir: [String: [Int]]
    let byStemLower: [String: [Int]]
    let byEpisode: [Int: [Int]]
    let bySeasonEpisode: [EpisodeRef: [Int]]
    let byNilSeasonEpisode: [Int: [Int]]

    init(drafts: [DraftGroup]) {
        var byDir: [String: [Int]] = [:]
        var byVideoDir: [String: [Int]] = [:]
        var byStemLower: [String: [Int]] = [:]
        var byEpisode: [Int: [Int]] = [:]
        var bySeasonEpisode: [EpisodeRef: [Int]] = [:]
        var byNilSeasonEpisode: [Int: [Int]] = [:]

        for (idx, d) in drafts.enumerated() {
            byDir[d.dir, default: []].append(idx)
            var seenDirs: Set<String> = []
            var seenStems: Set<String> = []
            var seenEps: Set<Int> = []
            var seenSeasonEps: Set<EpisodeRef> = []
            var seenNilSeasonEps: Set<Int> = []

            for v in d.videoFiles {
                let vd = dirOf(v.path)
                if seenDirs.insert(vd).inserted {
                    byVideoDir[vd, default: []].append(idx)
                }
                let sl = stem(v.name).lowercased()
                if !sl.isEmpty && seenStems.insert(sl).inserted {
                    byStemLower[sl, default: []].append(idx)
                }
                if let ep = v.parsed?.episodes.first ?? v.parsed?.absolute {
                    if seenEps.insert(ep).inserted {
                        byEpisode[ep, default: []].append(idx)
                    }
                    if let s = v.parsed?.season {
                        let ref = EpisodeRef(s, ep)
                        if seenSeasonEps.insert(ref).inserted {
                            bySeasonEpisode[ref, default: []].append(idx)
                        }
                    } else if seenNilSeasonEps.insert(ep).inserted {
                        byNilSeasonEpisode[ep, default: []].append(idx)
                    }
                }
            }
        }

        self.byDir = byDir
        self.byVideoDir = byVideoDir
        self.byStemLower = byStemLower
        self.byEpisode = byEpisode
        self.bySeasonEpisode = bySeasonEpisode
        self.byNilSeasonEpisode = byNilSeasonEpisode
    }
}

private struct DraftGroup: Sendable {
    let id: Int
    let dir: String
    let originalDir: String?
    let videos: [RecognizerEntry]
    let videoFiles: [ScanFile]
    let videoIndex: VideoMatchIndex
    let folderTitle: String?
    let isRoot: Bool
    var followers: [ScanFile] = []

    init(
        id: Int,
        dir: String,
        videos: [RecognizerEntry],
        folderTitle: String?,
        isRoot: Bool,
        originalDir: String? = nil
    ) {
        self.id = id
        self.dir = dir
        self.originalDir = originalDir
        self.videos = videos
        let vFiles = videos.map(\.file)
        self.videoFiles = vFiles
        self.videoIndex = VideoMatchIndex(vFiles)
        self.folderTitle = folderTitle
        self.isRoot = isRoot
    }
}

private struct LookupResult: Sendable {
    let draft: DraftGroup
    let vids: [ScanFile]
    let kind: MediaKind
    let anchor: String
    let year: Int?
    let match: Candidate?
    let score: Double
    let show: ShowDetail?
    let suggestedStrategy: SeasonStrategy?
    let suggestedStrategyReason: String?
}

private actor IndexQueue {
    private var current = 0
    private let count: Int

    init(count: Int) {
        self.count = count
    }

    func next() -> Int? {
        guard current < count else { return nil }
        defer { current += 1 }
        return current
    }
}

private actor SearchCache {
    private struct Entry {
        let id: UInt64
        let task: Task<[Candidate], Error>
    }

    private let metadata: any MetadataProvider
    private var entries: [String: Entry] = [:]
    private var nextId: UInt64 = 1

    init(metadata: any MetadataProvider) {
        self.metadata = metadata
    }

    func search(query: String, kind: MediaKind, year: Int?) async throws -> [Candidate] {
        let key = "\(kind.rawValue)|\(query)|\(year.map(String.init) ?? "null")"
        let entry: Entry
        if let existing = entries[key] {
            entry = existing
        } else {
            let id = nextId
            nextId += 1
            let meta = metadata
            let task = Task {
                try await meta.search(query, kind: kind, year: year)
            }
            let created = Entry(id: id, task: task)
            entries[key] = created
            entry = created
        }

        do {
            return try await entry.task.value
        } catch {
            evictIfSame(key: key, id: entry.id)
            throw error
        }
    }

    private func evictIfSame(key: String, id: UInt64) {
        if entries[key]?.id == id {
            entries.removeValue(forKey: key)
        }
    }
}

private actor LookupQueue {
    private var current = 0
    private let count: Int
    private var abortedError: Error?

    init(count: Int) {
        self.count = count
    }

    func next() -> Int? {
        if abortedError != nil || Task.isCancelled { return nil }
        guard current < count else { return nil }
        defer { current += 1 }
        return current
    }

    func recordFatal(_ error: Error) {
        if abortedError == nil {
            abortedError = error
        }
    }

    func firstFatalError() -> Error? {
        abortedError
    }
}

private func isFatalLookupError(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let tmdb = error as? TmdbError, tmdb.statusCode == 401 { return true }
    return false
}

private func runBoundedLookupWorkers(
    drafts: [DraftGroup],
    concurrency: Int,
    work: @escaping @Sendable (DraftGroup) async throws -> LookupResult
) async throws -> [LookupResult] {
    if drafts.isEmpty { return [] }
    try Task.checkCancellation()
    let queue = LookupQueue(count: drafts.count)
    let workerCount = min(max(1, concurrency), drafts.count)

    let indexedOutcomes = try await withThrowingTaskGroup(of: [(Int, Result<LookupResult, Error>)].self) { group in
        for _ in 0..<workerCount {
            group.addTask {
                var out: [(Int, Result<LookupResult, Error>)] = []
                while let idx = await queue.next() {
                    try Task.checkCancellation()
                    do {
                        let res = try await work(drafts[idx])
                        out.append((idx, .success(res)))
                    } catch {
                        if isFatalLookupError(error) {
                            await queue.recordFatal(error)
                            throw error
                        }
                        out.append((idx, .failure(error)))
                    }
                }
                return out
            }
        }

        do {
            var collected: [(Int, Result<LookupResult, Error>)] = []
            collected.reserveCapacity(drafts.count)
            for try await batch in group {
                collected.append(contentsOf: batch)
            }
            return collected
        } catch {
            group.cancelAll()
            if let fatal = await queue.firstFatalError() {
                throw fatal
            }
            throw error
        }
    }

    try Task.checkCancellation()
    let sorted = indexedOutcomes.sorted { $0.0 < $1.0 }
    return try sorted.map { try $0.1.get() }
}

// MARK: - Pure Path & Sequence Helpers

private func trimTrailingSlash(_ p: String) -> String {
    var s = p
    while s.count > 1 && s.hasSuffix("/") {
        s.removeLast()
    }
    return s
}

private func isWithinRoots(_ dir: String, rootDirs: [String]) -> Bool {
    if dir == "/" { return false }
    for r in rootDirs {
        if r == "/" || dir == r || dir.hasPrefix("\(r)/") {
            return true
        }
    }
    return false
}

private func parentDirsInRoots(_ dir: String, rootDirs: [String]) -> [String] {
    let parent = dirOf(dir)
    if parent == "/" || parent == dir { return [] }
    if !isWithinRoots(parent, rootDirs: rootDirs) { return [] }
    return directoryChain(dir, roots: rootDirs)
        .filter { $0 != "/" }
        .map(baseOf)
}

private func directoryChain(_ path: String, roots: [String]) -> [String] {
    directoryChainForDir(dirOf(path), roots: roots)
}

private func directoryChainForDir(_ dir: String, roots: [String]) -> [String] {
    var bestRoot: String?
    for r in roots {
        let matches = (dir == r) || dir.hasPrefix(r == "/" ? "/" : "\(r)/")
        if matches && (bestRoot == nil || r.count > bestRoot!.count) {
            bestRoot = r
        }
    }
    var chain: [String] = []
    var cur = dir
    while true {
        chain.append(cur)
        if bestRoot == nil || cur == bestRoot || cur == "/" { break }
        cur = dirOf(cur)
    }
    return chain
}

private func mostCommonString(_ xs: [String]) -> String? {
    var order: [String] = []
    var counts: [String: Int] = [:]
    var firstOriginal: [String: String] = [:]
    for x in xs {
        let k = normTitle(x)
        if counts[k] == nil {
            order.append(k)
            firstOriginal[k] = x
        }
        counts[k, default: 0] += 1
    }
    guard !order.isEmpty else { return nil }
    var bestKey = order[0]
    var bestCount = counts[bestKey] ?? 0
    for k in order.dropFirst() {
        let c = counts[k] ?? 0
        if c > bestCount {
            bestKey = k
            bestCount = c
        }
    }
    return firstOriginal[bestKey]
}

private func mostCommonInt(_ xs: [Int]) -> Int? {
    var order: [Int] = []
    var counts: [Int: Int] = [:]
    for x in xs {
        if counts[x] == nil { order.append(x) }
        counts[x, default: 0] += 1
    }
    guard !order.isEmpty else { return nil }
    var best = order[0]
    var bestCount = counts[best] ?? 0
    for k in order.dropFirst() {
        let c = counts[k] ?? 0
        if c > bestCount {
            best = k
            bestCount = c
        }
    }
    return best
}

private func isAsciiDigitChar(_ c: Character) -> Bool {
    guard let s = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
    return s.value >= 0x30 && s.value <= 0x39
}

private func commonPrefixChars(_ lists: [[Character]]) -> [Character] {
    guard var prefix = lists.first else { return [] }
    for s in lists.dropFirst() {
        let limit = min(prefix.count, s.count)
        var i = 0
        while i < limit && prefix[i] == s[i] {
            i += 1
        }
        if i < prefix.count {
            prefix.removeSubrange(i..<prefix.count)
        }
        if prefix.isEmpty { break }
    }
    return prefix
}

private func commonSuffixChars(_ lists: [[Character]]) -> [Character] {
    guard var suffix = lists.first else { return [] }
    for s in lists.dropFirst() {
        let limit = min(suffix.count, s.count)
        var i = 0
        while i < limit && suffix[suffix.count - 1 - i] == s[s.count - 1 - i] {
            i += 1
        }
        if i < suffix.count {
            suffix = Array(suffix[(suffix.count - i)..<suffix.count])
        }
        if suffix.isEmpty { break }
    }
    return suffix
}

private func regexMatches(_ regex: NSRegularExpression, _ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.firstMatch(in: text, range: range) != nil
}

private func regexReplaceAll(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
    guard !text.isEmpty else { return text }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
}
