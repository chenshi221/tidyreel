import Foundation
import TidyreelFakes
import TidyreelModels
import TidyreelPlanner

enum TestDemo {
    static let dorohedoro = Candidate(
        tmdbId: 94954,
        kind: .episode,
        title: "异兽魔都",
        englishTitle: "Dorohedoro",
        originalTitle: "ドロヘドロ",
        year: 2020,
        originCountry: "JP",
        voteAverage: 8.2
    )

    static let dorohedoroShow = ShowDetail(
        info: dorohedoro,
        seasons: [
            SeasonInfo(number: 1, episodeCount: 12, name: "Season 1", airDate: utcDate(2020, 1, 12)),
            SeasonInfo(number: 2, episodeCount: 11, name: "Season 2", airDate: utcDate(2021, 1, 10)),
        ]
    )

    static let inception = Candidate(
        tmdbId: 27205,
        kind: .movie,
        title: "盗梦空间",
        englishTitle: "Inception",
        originalTitle: "Inception",
        year: 2010,
        originCountry: "US",
        voteAverage: 8.4
    )

    static let friends = Candidate(
        tmdbId: 1668,
        kind: .episode,
        title: "老友记",
        englishTitle: "Friends",
        originalTitle: "Friends",
        year: 1994,
        originCountry: "US",
        voteAverage: 8.6
    )

    static let friendsShow = ShowDetail(
        info: friends,
        seasons: [
            SeasonInfo(number: 1, episodeCount: 24, name: "Season 1", airDate: utcDate(1994, 9, 22)),
        ]
    )

    static let onePiece = Candidate(
        tmdbId: 37854,
        kind: .episode,
        title: "海贼王",
        englishTitle: "One Piece",
        originalTitle: "ワンピース",
        year: 1999,
        originCountry: "JP",
        voteAverage: 8.7
    )

    static let onePieceShow = ShowDetail(
        info: onePiece,
        seasons: [
            SeasonInfo(number: 1, episodeCount: 61, name: "Season 1", airDate: utcDate(1999, 10, 20)),
        ]
    )

    static let frieren = Candidate(
        tmdbId: 209867,
        kind: .episode,
        title: "葬送的芙莉莲",
        englishTitle: "Beyond Journey's End",
        originalTitle: "葬送のフリーレン",
        year: 2023,
        originCountry: "JP",
        voteAverage: 8.9
    )

    static let frierenShow = ShowDetail(
        info: frieren,
        seasons: [
            SeasonInfo(number: 1, episodeCount: 28, name: "Season 1", airDate: utcDate(2023, 9, 29)),
        ]
    )
}

func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    return cal.date(from: DateComponents(year: year, month: month, day: day))!
}

/// Test metadata provider backed by `FakeMetadataProvider` with rich demo fixtures.
struct TestMetadataProvider: MetadataProvider, ExternalIdLookup, Sendable {
    var base: FakeMetadataProvider

    init(
        showsById: [Int: ShowDetail]? = nil,
        moviesById: [Int: MovieDetail]? = nil,
        seasonsByShow: [Int: [Int: [Episode]]]? = nil,
        groupsByShow: [Int: [EpisodeGroup]] = [:]
    ) {
        let defaultShows: [Int: ShowDetail] = [
            TestDemo.dorohedoro.tmdbId: TestDemo.dorohedoroShow,
            TestDemo.friends.tmdbId: TestDemo.friendsShow,
            TestDemo.onePiece.tmdbId: TestDemo.onePieceShow,
            TestDemo.frieren.tmdbId: TestDemo.frierenShow,
        ]
        let defaultMovies: [Int: MovieDetail] = [
            TestDemo.inception.tmdbId: MovieDetail(info: TestDemo.inception),
        ]
        let s1Episodes: [Episode] = (1...12).map { ep in
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(secondsFromGMT: 0)!
            let air = cal.date(byAdding: .day, value: (ep - 1) * 7, to: utcDate(2020, 1, 12))
            return Episode(season: 1, number: ep, title: "第 \(ep) 话", airDate: air)
        }
        let s2Episodes: [Episode] = (1...11).map { ep in
            Episode(season: 2, number: ep, title: "S2 第 \(ep) 话")
        }
        let defaultSeasons: [Int: [Int: [Episode]]] = [
            TestDemo.dorohedoro.tmdbId: [1: s1Episodes, 2: s2Episodes],
            TestDemo.friends.tmdbId: [1: (1...24).map { Episode(season: 1, number: $0, title: "Episode \($0)") }],
            TestDemo.onePiece.tmdbId: [1: (1...61).map { Episode(season: 1, number: $0, title: "第 \($0) 话") }],
        ]
        self.base = FakeMetadataProvider(
            showsById: showsById ?? defaultShows,
            moviesById: moviesById ?? defaultMovies,
            seasonsByShow: seasonsByShow ?? defaultSeasons,
            groupsByShow: groupsByShow
        )
    }

    func search(_ query: String, kind: MediaKind?, year: Int?) async throws -> [Candidate] {
        let hits = try await base.search(query, kind: kind, year: year)
        if let year {
            return hits.filter { c in
                guard let cy = c.year else { return true }
                return abs(cy - year) <= 1
            }
        }
        return hits
    }

    func show(_ tmdbId: Int) async throws -> ShowDetail {
        try await base.show(tmdbId)
    }

    func season(_ tmdbId: Int, season: Int) async throws -> [Episode] {
        try await base.season(tmdbId, season: season)
    }

    func episodeGroups(_ tmdbId: Int) async throws -> [EpisodeGroup] {
        try await base.episodeGroups(tmdbId)
    }

    func movie(_ tmdbId: Int) async throws -> MovieDetail {
        try await base.movie(tmdbId)
    }

    func findByExternalId(source: String, id: String, kind: MediaKind?) async throws -> Candidate? {
        if source.lowercased() == "imdb" && id.lowercased() == "tt0108778" {
            return (kind == .movie) ? nil : TestDemo.friends
        }
        return try await base.findByExternalId(source: source, id: id, kind: kind)
    }
}

/// Lightweight rule-like parser used strictly inside `TidyreelPlannerTests`.
struct TestFilenameParser: FilenameParser, Sendable {
    private static let extraRe = try! NSRegularExpression(
        pattern: #"花絮|featurette|behind"#,
        options: [.caseInsensitive]
    )
    private static let extraDirRe = try! NSRegularExpression(
        pattern: #"^(?:extras?|花絮)$"#,
        options: [.caseInsensitive]
    )
    private static let langRe = try! NSRegularExpression(
        pattern: #"[. _\-](chs|cht|sc|tc|eng|zh-CN|zh-TW|zh_CN|zh_TW|简体|繁体)(?=[. _\-]|$)"#,
        options: [.caseInsensitive]
    )
    private static let seRangeRe = try! NSRegularExpression(
        pattern: #"[Ss](\d{1,2})[Ee](\d{1,3})(?:-[Ee]?(\d{1,3}))?"#
    )
    private static let cnEpRe = try! NSRegularExpression(
        pattern: #"第\s*(\d{1,4})\s*[集话話期回]"#
    )
    private static let airDateRe = try! NSRegularExpression(
        pattern: #"(?:^|[.\s_\-])((?:19|20)\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])(?=[.\s_\-]|$)"#
    )
    private static let pureDigitsRe = try! NSRegularExpression(pattern: #"^(\d{1,4})$"#)
    private static let dashNumRe = try! NSRegularExpression(
        pattern: #"[_\-\s]\s*(\d{1,4})\s*(?=\[|$)"#
    )
    private static let yearRe = try! NSRegularExpression(
        pattern: #"(?:^|[\s.(\[（])((?:19|20)\d\d)(?=[\s.)\]）]|$)"#
    )
    private static let resRe = try! NSRegularExpression(
        pattern: #"(?<!\d)(\d{3,4}p)(?![A-Za-z0-9])"#,
        options: [.caseInsensitive]
    )
    private static let extIdRe = try! NSRegularExpression(
        pattern: #"[\{\[]\s*(tmdb|imdb|tvdb)(?:id)?\s*[-=:]\s*(tt\d+|\d+)\s*[\}\]]"#,
        options: [.caseInsensitive]
    )
    private static let squareBracketRe = try! NSRegularExpression(pattern: #"\[[^\]]*\]"#)
    private static let curlyIdRe = try! NSRegularExpression(
        pattern: #"\{(?:tmdb|imdb|tvdb)[^}]*\}"#,
        options: [.caseInsensitive]
    )
    private static let cnSeasonSuffixRe = try! NSRegularExpression(
        pattern: #"\s*第\s*[0-9一二三四五六七八九十]+\s*[季部]\s*$"#
    )
    private static let trailingDashRe = try! NSRegularExpression(pattern: #"[\s._\-]+$"#)
    private static let multiSpaceRe = try! NSRegularExpression(pattern: #"\s+"#)
    private static let dottedCjkRe = try! NSRegularExpression(
        pattern: #"([\u4e00-\u9fff])[._ ]+(?=[\u4e00-\u9fff])"#
    )
    private static let groupRe = try! NSRegularExpression(pattern: #"^\[([^\]]+)\]"#)
    private static let parentSeasonRe = try! NSRegularExpression(
        pattern: #"^(?:Season|S)\s*(\d+)$"#,
        options: [.caseInsensitive]
    )
    private static let structuralDirRe = try! NSRegularExpression(
        pattern: #"^(?:season\s*\d+|s\d{1,2}|4k|1080p|2160p|subs?|extras?|花絮)$"#,
        options: [.caseInsensitive]
    )

    func classify(_ fileName: String) -> FileRole {
        let ext = extOf(fileName).lowercased()
        if videoExtensions.contains(ext) { return .video }
        if subtitleExtensions.contains(ext) { return .subtitle }
        if sidecarExtensions.contains(ext) { return .sidecar }
        if junkExtensions.contains(ext) || ext == "torrent" { return .junk }
        return .other
    }

    func parse(_ fileName: String, parentDirs: [String]) -> ParsedName {
        var s = fileName
        let ext = extOf(fileName).lowercased()
        let knownExt = videoExtensions.contains(ext)
            || subtitleExtensions.contains(ext)
            || sidecarExtensions.contains(ext)
            || junkExtensions.contains(ext)
        if knownExt, let dot = s.lastIndex(of: "."), dot > s.startIndex {
            s = String(s[..<dot])
        }

        let fullS = NSRange(s.startIndex..<s.endIndex, in: s)
        let isExtra = Self.extraRe.firstMatch(in: s, range: fullS) != nil
            || parentDirs.contains { d in
                let rd = NSRange(d.startIndex..<d.endIndex, in: d)
                return Self.extraDirRe.firstMatch(in: d, range: rd) != nil
            }

        var externalId: ExternalId?
        if let em = Self.extIdRe.firstMatch(in: s, range: fullS),
           let r1 = Range(em.range(at: 1), in: s),
           let r2 = Range(em.range(at: 2), in: s) {
            externalId = ExternalId(s[r1].lowercased(), s[r2].lowercased())
        }

        var lang: String?
        if let lm = Self.langRe.firstMatch(in: s, range: fullS),
           let r1 = Range(lm.range(at: 1), in: s) {
            lang = String(s[r1])
        }

        var season: Int?
        var absolute: Int?
        var episodes: [Int] = []
        var airDate: Date?
        var cut = s.endIndex
        var bareOnly = false

        if let se = Self.seRangeRe.firstMatch(in: s, range: fullS),
           let r1 = Range(se.range(at: 1), in: s),
           let r2 = Range(se.range(at: 2), in: s),
           let mRange = Range(se.range, in: s) {
            season = Int(s[r1])
            if let ep1 = Int(s[r2]) {
                episodes.append(ep1)
                if se.range(at: 3).location != NSNotFound,
                   let r3 = Range(se.range(at: 3), in: s),
                   let ep2 = Int(s[r3]), ep2 > ep1 {
                    episodes.append(ep2)
                }
            }
            cut = mRange.lowerBound
        } else if let ad = Self.airDateRe.firstMatch(in: s, range: fullS),
                  let ry = Range(ad.range(at: 1), in: s),
                  let rm = Range(ad.range(at: 2), in: s),
                  let rd = Range(ad.range(at: 3), in: s),
                  let mRange = Range(ad.range, in: s),
                  let y = Int(s[ry]), let m = Int(s[rm]), let d = Int(s[rd]) {
            airDate = utcDate(y, m, d)
            cut = mRange.lowerBound
        } else if let cn = Self.cnEpRe.firstMatch(in: s, range: fullS),
                  let r1 = Range(cn.range(at: 1), in: s),
                  let mRange = Range(cn.range, in: s) {
            absolute = Int(s[r1])
            cut = mRange.lowerBound
        } else if let pd = Self.pureDigitsRe.firstMatch(in: s, range: fullS),
                  let r1 = Range(pd.range(at: 1), in: s),
                  let num = Int(s[r1]) {
            absolute = num
            cut = s.startIndex
            bareOnly = true
        } else if let dn = Self.dashNumRe.firstMatch(in: s, range: fullS),
                  let r1 = Range(dn.range(at: 1), in: s),
                  let mRange = Range(dn.range, in: s) {
            absolute = Int(s[r1])
            cut = mRange.lowerBound
        }

        var year: Int?
        if let ym = Self.yearRe.firstMatch(in: s, range: fullS),
           let r1 = Range(ym.range(at: 1), in: s),
           let mRange = Range(ym.range, in: s) {
            year = Int(s[r1])
            if mRange.lowerBound < cut { cut = mRange.lowerBound }
        }

        var res: String?
        if let rm = Self.resRe.firstMatch(in: s, range: fullS),
           let r1 = Range(rm.range(at: 1), in: s),
           let mRange = Range(rm.range, in: s) {
            res = String(s[r1]).lowercased()
            if mRange.lowerBound < cut { cut = mRange.lowerBound }
        }

        var rawTitle = String(s[..<cut])
        rawTitle = Self.squareBracketRe.stringByReplacingMatches(
            in: rawTitle,
            range: NSRange(rawTitle.startIndex..<rawTitle.endIndex, in: rawTitle),
            withTemplate: " "
        )
        rawTitle = Self.curlyIdRe.stringByReplacingMatches(
            in: rawTitle,
            range: NSRange(rawTitle.startIndex..<rawTitle.endIndex, in: rawTitle),
            withTemplate: " "
        )
        rawTitle = rawTitle
            .replacingOccurrences(of: " BluRay", with: "")
            .replacingOccurrences(of: ".BluRay", with: "")
        rawTitle = Self.dottedCjkRe.stringByReplacingMatches(
            in: rawTitle,
            range: NSRange(rawTitle.startIndex..<rawTitle.endIndex, in: rawTitle),
            withTemplate: "$1"
        )
        rawTitle = rawTitle
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        rawTitle = Self.cnSeasonSuffixRe.stringByReplacingMatches(
            in: rawTitle,
            range: NSRange(rawTitle.startIndex..<rawTitle.endIndex, in: rawTitle),
            withTemplate: ""
        )
        rawTitle = Self.trailingDashRe.stringByReplacingMatches(
            in: rawTitle,
            range: NSRange(rawTitle.startIndex..<rawTitle.endIndex, in: rawTitle),
            withTemplate: ""
        )
        rawTitle = Self.multiSpaceRe.stringByReplacingMatches(
            in: rawTitle,
            range: NSRange(rawTitle.startIndex..<rawTitle.endIndex, in: rawTitle),
            withTemplate: " "
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        if rawTitle.isEmpty && !bareOnly {
            for d in parentDirs {
                let rd = NSRange(d.startIndex..<d.endIndex, in: d)
                if Self.structuralDirRe.firstMatch(in: d, range: rd) != nil || isGenericContainerDir(d) {
                    continue
                }
                let dp = parse(d, parentDirs: [])
                if let dt = dp.title, !dt.isEmpty {
                    rawTitle = dt
                    break
                }
            }
        }

        var group: String?
        if let gm = Self.groupRe.firstMatch(in: s, range: fullS),
           let r1 = Range(gm.range(at: 1), in: s) {
            let gText = String(s[r1])
            if !gText.hasPrefix("日剧") && !gText.hasPrefix("美剧") {
                group = gText
            }
        }

        let hasNum = !episodes.isEmpty || absolute != nil || airDate != nil
        if season == nil && hasNum && !bareOnly {
            for d in parentDirs {
                let rd = NSRange(d.startIndex..<d.endIndex, in: d)
                if let pm = Self.parentSeasonRe.firstMatch(in: d, range: rd),
                   let r1 = Range(pm.range(at: 1), in: d) {
                    season = Int(d[r1])
                    break
                }
            }
        }

        let kind: MediaKind
        if isExtra {
            kind = .extra
        } else if season == 0 {
            kind = .special
        } else if hasNum {
            kind = .episode
        } else if year != nil {
            kind = .movie
        } else {
            kind = .unknown
        }

        let confidence: Double
        if bareOnly {
            confidence = 0.45
        } else if rawTitle.isEmpty {
            confidence = 0.3
        } else if !episodes.isEmpty || year != nil || airDate != nil {
            confidence = 0.9
        } else if absolute != nil {
            confidence = s.contains("_") ? 0.55 : 0.85
        } else {
            confidence = 0.5
        }

        return ParsedName(
            title: rawTitle.isEmpty ? nil : rawTitle,
            year: year,
            season: season,
            episodes: episodes,
            absolute: absolute,
            kind: kind,
            resolution: res,
            group: group,
            lang: lang,
            confidence: confidence,
            airDate: airDate,
            externalId: externalId
        )
    }
}

// MARK: - Test Builders & Plan Execution Helper

func entriesOf(_ paths: [String]) -> [RemoteEntry] {
    paths.map { p in
        RemoteEntry(path: p, name: baseOf(p), isDir: false, size: 1)
    }
}

func makeVideo(
    _ path: String,
    season: Int? = nil,
    episode: Int? = nil,
    absolute: Int? = nil,
    kind: MediaKind = .episode,
    confidence: Double = 0.9,
    title: String? = "Dorohedoro"
) -> ScanFile {
    ScanFile(
        path: path,
        name: baseOf(path),
        size: 1,
        role: .video,
        parsed: ParsedName(
            title: title,
            season: season,
            episodes: episode.map { [$0] } ?? [],
            absolute: absolute,
            kind: kind,
            resolution: "1080p",
            confidence: confidence
        )
    )
}

func makeOther(_ path: String, _ role: FileRole, lang: String? = nil) -> ScanFile {
    ScanFile(
        path: path,
        name: baseOf(path),
        size: 1,
        role: role,
        parsed: role == .junk ? nil : ParsedName(lang: lang, confidence: 0.9)
    )
}

func makeTvGroup(
    _ files: [ScanFile],
    rootDir: String = "/d/异兽魔都 2020",
    match: Candidate? = TestDemo.dorohedoro,
    show: ShowDetail? = TestDemo.dorohedoroShow,
    score: Double = 0.95,
    id: String = "g1"
) -> MediaGroup {
    MediaGroup(
        id: GroupId(id),
        kind: .episode,
        anchorTitle: "异兽魔都",
        anchorYear: 2020,
        rootDir: rootDir,
        files: files,
        match: match,
        matchScore: score,
        show: show
    )
}

func makeScan(
    _ groups: [MediaGroup],
    unassigned: [ScanFile] = [],
    roots: [String] = ["/d"]
) -> ScanResult {
    ScanResult(
        connection: ConnectionId("c"),
        roots: roots,
        groups: groups,
        unassigned: unassigned
    )
}

func fileRelocateOps(_ plan: RenamePlan) -> [RenameOp] {
    plan.ops.filter { $0.kind == .relocate && $0.phase == .files }
}

func movesMap(_ plan: RenamePlan) -> [String: String] {
    var out: [String: String] = [:]
    for o in fileRelocateOps(plan) {
        out[o.src] = o.dst
    }
    return out
}

func opFor(_ plan: RenamePlan, _ src: String) -> RenameOp {
    plan.ops.first { $0.src == src }!
}

func applyPlan(_ plan: RenamePlan, to backend: MemoryStorageBackend) async throws {
    for op in plan.ops where op.selected {
        switch op.kind {
        case .mkdir:
            try await backend.mkdirs(op.dst)
        case .relocate:
            if op.src == op.dst { continue }
            let srcDir = dirOf(op.src)
            let dstDir = dirOf(op.dst)
            if srcDir == dstDir {
                try await backend.rename(op.src, newName: baseOf(op.dst))
            } else {
                let name = baseOf(op.dst)
                var cur = op.src
                if baseOf(op.src) != name {
                    try await backend.rename(op.src, newName: name)
                    cur = joinPath(srcDir, name)
                }
                try await backend.mkdirs(dstDir)
                try await backend.move(srcDir: dirOf(cur), dstDir: dstDir, names: [name])
            }
        case .delete:
            try await backend.remove(dir: dirOf(op.src), names: [baseOf(op.src)])
        case .write:
            let bytes: Data
            if op.src.hasPrefix(writeTextPrefix) {
                let xml = String(op.src.dropFirst(writeTextPrefix.count))
                bytes = Data(xml.utf8)
            } else {
                bytes = Data([0])
            }
            if op.overwrite, try await backend.exists(op.dst) {
                try await backend.remove(dir: dirOf(op.dst), names: [baseOf(op.dst)])
            }
            try await backend.write(op.dst, bytes: bytes)
        }
    }
}

func allBackendFiles(_ backend: MemoryStorageBackend) async throws -> [String] {
    var files: [String] = []
    var queue: [String] = ["/"]
    while !queue.isEmpty {
        let dir = queue.removeFirst()
        let children = try await backend.list(dir)
        for c in children {
            if c.isDir {
                queue.append(c.path)
            } else {
                files.append(c.path)
            }
        }
    }
    return files.sorted()
}
