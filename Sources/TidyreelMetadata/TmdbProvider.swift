import Foundation
import TidyreelModels

public final class TmdbProvider: MetadataProvider, ExternalIdLookup, Sendable {
    public let config: TmdbConfig
    public let client: TmdbClient

    private static let maxPages = 3
    private static let maxAliasLookups = 10
    private static let minYearMatchScore = 0.7

    public init(
        config: TmdbConfig,
        transport: (any HTTPTransport)? = nil,
        cache: (any TmdbResponseCache)? = nil,
        minIntervalMs: Int = 50,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { try await MetadataURLHelpers.sleepSeconds($0) }
    ) {
        self.config = config
        self.client = TmdbClient(
            apiKey: config.apiKey,
            baseUrl: config.baseUrl,
            transport: transport,
            cache: cache,
            minIntervalMs: minIntervalMs,
            sleeper: sleeper
        )
    }

    public convenience init(
        _ config: TmdbConfig,
        transport: (any HTTPTransport)? = nil,
        cache: (any TmdbResponseCache)? = nil,
        minIntervalMs: Int = 50,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { try await MetadataURLHelpers.sleepSeconds($0) }
    ) {
        self.init(
            config: config,
            transport: transport,
            cache: cache,
            minIntervalMs: minIntervalMs,
            sleeper: sleeper
        )
    }

    public func clearMemoryCache() async {
        await client.clearMemoryCache()
    }

    public func close() async {
        await client.close()
    }

    private var primaryLang: String {
        config.language.split(separator: "-").first.map { $0.lowercased() } ?? ""
    }

    private var fallbackLang: String {
        config.fallbackLanguage.split(separator: "-").first.map { $0.lowercased() } ?? ""
    }

    // MARK: - ExternalIdLookup

    private func tryMovie(_ tmdbId: Int) async throws -> Candidate? {
        do {
            return try await movie(tmdbId).info
        } catch let e as TmdbError where e.statusCode == 404 {
            return nil
        }
    }

    private func tryShow(_ tmdbId: Int) async throws -> Candidate? {
        do {
            return try await show(tmdbId).info
        } catch let e as TmdbError where e.statusCode == 404 {
            return nil
        }
    }

    public func findByExternalId(
        source: String,
        id: String,
        kind: MediaKind? = nil
    ) async throws -> Candidate? {
        let src = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanId.isEmpty { return nil }

        if src == "tmdb" {
            guard let tmdbId = Int(cleanId), tmdbId > 0 else { return nil }
            if kind == .movie {
                return try await tryMovie(tmdbId)
            }
            if kind == .episode || kind == .special {
                return try await tryShow(tmdbId)
            }
            if let m = try await tryMovie(tmdbId) {
                return m
            }
            return try await tryShow(tmdbId)
        }

        if src == "imdb" || src == "tvdb" {
            if src == "tvdb", Int(cleanId) == nil { return nil }
            let externalSource = (src == "imdb") ? "imdb_id" : "tvdb_id"
            let encodedId = MetadataURLHelpers.encodeURIComponent(cleanId)
            let res: [String: JSONValue]
            do {
                res = try await client.get(
                    "/find/\(encodedId)",
                    query: [
                        "external_source": externalSource,
                        "language": config.language,
                    ]
                )
            } catch let e as TmdbError where e.statusCode == 404 || e.statusCode == 400 {
                return nil
            }

            let movies = Self.list(res["movie_results"])
            let tv = Self.list(res["tv_results"])
            var hit: [String: JSONValue]?
            var hitKind: MediaKind?
            let wantTv = (kind == .episode || kind == .special)

            if kind == .movie {
                if let firstMovie = movies.first {
                    hit = firstMovie
                    hitKind = .movie
                } else if let firstTv = tv.first {
                    hit = firstTv
                    hitKind = .episode
                }
            } else if wantTv {
                if let firstTv = tv.first {
                    hit = firstTv
                    hitKind = .episode
                } else if let firstMovie = movies.first {
                    hit = firstMovie
                    hitKind = .movie
                }
            } else {
                if let firstMovie = movies.first {
                    hit = firstMovie
                    hitKind = .movie
                } else if let firstTv = tv.first {
                    hit = firstTv
                    hitKind = .episode
                }
            }

            guard let hit, let hitKind, let hitId = hit["id"]?.intValue else {
                return nil
            }
            do {
                return hitKind == .movie
                    ? try await movie(hitId).info
                    : try await show(hitId).info
            } catch is TmdbError {
                return Self.makeCandidate(hit, kind: hitKind, primaryLang: primaryLang)
            }
        }

        return nil
    }

    // MARK: - Search

    public func search(
        _ query: String,
        kind: MediaKind? = nil,
        year: Int? = nil
    ) async throws -> [Candidate] {
        let q = normalizeQuery(query, extractYear: year == nil)
        let y = year ?? q.year
        if q.text.isEmpty { return [] }

        let kinds: [MediaKind] = switch kind {
        case .movie:
            [.movie]
        case .episode, .special:
            [.episode]
        case nil, .unknown, .extra:
            [.movie, .episode]
        }

        let preparedQuery = PreparedScoringQuery(normalized: q)

        struct RankedHit {
            let index: Int
            let score: Double
            let popBonus: Double
            let candidate: Candidate
        }

        func rank(_ hits: [Candidate]) -> [RankedHit] {
            var ranked: [RankedHit] = []
            ranked.reserveCapacity(hits.count)
            for (idx, hit) in hits.enumerated() {
                ranked.append(
                    RankedHit(
                        index: idx,
                        score: scoreNormalized(hit, prepared: preparedQuery, year: y, kind: kind),
                        popBonus: popularityBonus(hit),
                        candidate: hit
                    )
                )
            }
            ranked.sort { a, b in
                if b.score != a.score { return a.score > b.score }
                if a.score >= 0.5 && b.popBonus != a.popBonus { return a.popBonus > b.popBonus }
                return a.index < b.index
            }
            return ranked
        }

        func run(_ searchYear: Int?) async throws -> [Candidate] {
            if kinds.count == 1 {
                return try await searchKind(kinds[0], text: q.text, lang: config.language, year: searchYear)
            }
            return try await withThrowingTaskGroup(of: (Int, [Candidate]).self) { group in
                for (idx, k) in kinds.enumerated() {
                    group.addTask {
                        let res = try await self.searchKind(k, text: q.text, lang: self.config.language, year: searchYear)
                        return (idx, res)
                    }
                }
                var pairs: [(Int, [Candidate])] = []
                for try await pair in group {
                    pairs.append(pair)
                }
                pairs.sort { $0.0 < $1.0 }
                return pairs.flatMap(\.1)
            }
        }

        if let y {
            let withYear = rank(try await run(y))
            if let best = withYear.first, best.score >= Self.minYearMatchScore {
                return withYear.map(\.candidate)
            }
            let withoutYear = try await run(nil)
            if withoutYear.isEmpty {
                return withYear.map(\.candidate)
            }
            struct MergeKey: Hashable {
                let kind: MediaKind
                let id: Int
            }
            var orderedKeys: [MergeKey] = []
            var byKey: [MergeKey: Candidate] = [:]
            for s in withYear {
                let mk = MergeKey(kind: s.candidate.kind, id: s.candidate.tmdbId)
                if byKey[mk] == nil { orderedKeys.append(mk) }
                byKey[mk] = s.candidate
            }
            for c in withoutYear {
                let mk = MergeKey(kind: c.kind, id: c.tmdbId)
                if byKey[mk] == nil {
                    orderedKeys.append(mk)
                    byKey[mk] = c
                }
            }
            let mergedList = orderedKeys.compactMap { byKey[$0] }
            return rank(mergedList).map(\.candidate)
        }

        let hits = try await run(nil)
        return rank(hits).map(\.candidate)
    }

    private func searchKind(
        _ kind: MediaKind,
        text: String,
        lang: String,
        year: Int?
    ) async throws -> [Candidate] {
        let isMovie = (kind == .movie)
        func makeParams(_ l: String) -> [String: String] {
            var p: [String: String] = [
                "query": text,
                "language": l,
                "include_adult": "false",
            ]
            if let year {
                p[isMovie ? "year" : "first_air_date_year"] = String(year)
            }
            return p
        }

        let path = isMovie ? "/search/movie" : "/search/tv"
        let fallback = config.fallbackLanguage
        let langParams = makeParams(lang)
        let enParams = makeParams(fallback)

        let res: [String: JSONValue]
        let en: [String: JSONValue]
        if lang == fallback {
            res = try await client.get(path, query: langParams)
            en = res
        } else {
            async let primaryReq = client.get(path, query: langParams)
            async let fallbackReq = client.get(path, query: enParams)
            (res, en) = try await (primaryReq, fallbackReq)
        }

        var results = Self.list(res["results"])
        var enResults = (lang == fallback) ? results : Self.list(en["results"])
        if results.isEmpty && enResults.isEmpty { return [] }

        func original(_ r: [String: JSONValue]) -> String? {
            r[isMovie ? "original_title" : "original_name"]?.nonEmptyString
        }

        let foldedText = foldTitle(text)
        let exact = (results + enResults).contains { r in
            foldTitle(Self.title(r, movie: isMovie)) == foldedText ||
                foldTitle(original(r) ?? "") == foldedText
        }

        if !exact {
            if lang == fallback {
                let more = try await laterPages(path: path, params: langParams, first: res)
                results.append(contentsOf: more)
                enResults = results
            } else {
                async let morePrimary = laterPages(path: path, params: langParams, first: res)
                async let moreEn = laterPages(path: path, params: enParams, first: en)
                let (mp, me) = try await (morePrimary, moreEn)
                results.append(contentsOf: mp)
                enResults.append(contentsOf: me)
            }
        }

        var enTitles: [Int: String] = [:]
        for r in enResults {
            if let id = r["id"]?.intValue {
                enTitles[id] = Self.title(r, movie: isMovie)
            }
        }

        var orderedIds: [Int] = []
        var hitsById: [Int: [String: JSONValue]] = [:]
        for r in results {
            if let id = r["id"]?.intValue {
                if hitsById[id] == nil { orderedIds.append(id) }
                hitsById[id] = r
            }
        }
        for r in enResults {
            if let id = r["id"]?.intValue, hitsById[id] == nil {
                orderedIds.append(id)
                hitsById[id] = r
            }
        }

        var aliasesById: [Int: [String]] = [:]
        if !exact {
            let queryTokens = PreparedQueryTokens(text)
            let unexplainedIds = orderedIds.filter { id in
                guard let hit = hitsById[id] else { return false }
                if queryTokens.matches(Self.title(hit, movie: isMovie)) { return false }
                if let orig = original(hit), queryTokens.matches(orig) { return false }
                if let enTitle = enTitles[id], queryTokens.matches(enTitle) { return false }
                return true
            }.prefix(Self.maxAliasLookups)

            await withTaskGroup(of: (Int, [String]).self) { group in
                for id in unexplainedIds {
                    group.addTask {
                        let list = await self.fetchAliases(id: id, movie: isMovie)
                        return (id, list)
                    }
                }
                for await (id, list) in group {
                    aliasesById[id] = list
                }
            }
        }

        return orderedIds.compactMap { id -> Candidate? in
            guard let hit = hitsById[id] else { return nil }
            return Self.makeCandidate(
                hit,
                kind: kind,
                englishTitle: enTitles[id],
                aliases: aliasesById[id] ?? [],
                primaryLang: primaryLang
            )
        }
    }

    private func laterPages(
        path: String,
        params: [String: String],
        first: [String: JSONValue]
    ) async throws -> [[String: JSONValue]] {
        let total = first["total_pages"]?.intValue ?? 1
        let maxPage = min(total, Self.maxPages)
        guard maxPage >= 2 else { return [] }

        return try await withThrowingTaskGroup(of: (Int, [[String: JSONValue]]).self) { group in
            for p in 2...maxPage {
                var pageParams = params
                pageParams["page"] = String(p)
                group.addTask {
                    let res = try await self.client.get(path, query: pageParams)
                    return (p, Self.list(res["results"]))
                }
            }
            var pages: [(Int, [[String: JSONValue]])] = []
            for try await item in group {
                pages.append(item)
            }
            pages.sort { $0.0 < $1.0 }
            return pages.flatMap(\.1)
        }
    }

    private func fetchOptional(_ path: String) async -> [String: JSONValue]? {
        do {
            return try await client.get(path)
        } catch is TmdbError {
            return nil
        } catch {
            return nil
        }
    }

    private static func extractAltTitles(
        _ res: [String: JSONValue]?,
        movie: Bool
    ) -> [(region: String?, title: String)] {
        guard let res else { return [] }
        return list(res[movie ? "titles" : "results"]).compactMap { item in
            guard let t = item["title"]?.nonEmptyString else { return nil }
            return (region: item["iso_3166_1"]?.nonEmptyString, title: t)
        }
    }

    private func chineseAlias(
        id: Int,
        movie: Bool,
        title: String,
        detail: [String: JSONValue]?
    ) async -> String? {
        if hasHan(title) { return nil }
        let kindSegment = movie ? "movie" : "tv"
        let nameKey = movie ? "title" : "name"
        let embeddedTrans = detail?["translations"]?.objectValue
        let embeddedAlt = detail?["alternative_titles"]?.objectValue

        async let transTask: [String: JSONValue]? = if let embeddedTrans {
            embeddedTrans
        } else {
            await fetchOptional("/\(kindSegment)/\(id)/translations")
        }
        async let altTask: [String: JSONValue]? = if let embeddedAlt {
            embeddedAlt
        } else {
            await fetchOptional("/\(kindSegment)/\(id)/alternative_titles")
        }
        let (transRes, altRes) = await (transTask, altTask)

        var namesByRegion: [String: String] = [:]
        for item in Self.list(transRes?["translations"]) {
            guard item["iso_639_1"]?.stringValue == "zh" else { continue }
            if let region = item["iso_3166_1"]?.nonEmptyString,
               let name = item["data"]?.objectValue?[nameKey]?.nonEmptyString {
                namesByRegion[region] = name
            }
        }

        let hanAliases = Self.extractAltTitles(altRes, movie: movie).filter { hasHan($0.title) }
        func firstAlias(region: String?) -> String? {
            hanAliases.first { region == nil || $0.region == region }?.title
        }

        let candidates: [String?] = [
            namesByRegion["CN"],
            namesByRegion["SG"],
            firstAlias(region: "CN"),
            namesByRegion["TW"],
            namesByRegion["HK"],
            firstAlias(region: nil),
        ]
        for cand in candidates {
            if let cand, hasHan(cand) {
                return cand
            }
        }
        return nil
    }

    private func fetchAliases(id: Int, movie: Bool) async -> [String] {
        let res = await fetchOptional("/\(movie ? "movie" : "tv")/\(id)/alternative_titles")
        return Self.extractAltTitles(res, movie: movie).map(\.title)
    }

    // MARK: - Detail Endpoints

    private func fetchDetail(
        _ path: String,
        movie: Bool
    ) async throws -> ([String: JSONValue], [String: JSONValue]) {
        let wantZh = config.language.hasPrefix("zh")
        var appendItems = [
            "credits",
            "external_ids",
            "images",
            movie ? "release_dates" : "content_ratings",
            "keywords",
        ]
        if wantZh {
            appendItems.append(contentsOf: ["translations", "alternative_titles"])
        }

        let pLang = primaryLang
        let fLang = fallbackLang
        var imgLangs: [String] = []
        if !pLang.isEmpty { imgLangs.append(pLang) }
        if !fLang.isEmpty && fLang != pLang { imgLangs.append(fLang) }
        imgLangs.append("null")

        let primaryParams: [String: String] = [
            "language": config.language,
            "append_to_response": appendItems.joined(separator: ","),
            "include_image_language": imgLangs.joined(separator: ","),
        ]

        if config.language == config.fallbackLanguage {
            let r = try await client.get(path, query: primaryParams)
            return (r, r)
        }

        async let primaryReq = client.get(path, query: primaryParams)
        async let fallbackReq = client.get(path, query: ["language": config.fallbackLanguage])
        return try await (primaryReq, fallbackReq)
    }

    public func show(_ tmdbId: Int) async throws -> ShowDetail {
        let (primary, en) = try await fetchDetail("/tv/\(tmdbId)", movie: false)
        let alias = config.language.hasPrefix("zh")
            ? await chineseAlias(id: tmdbId, movie: false, title: Self.title(primary, movie: false), detail: primary)
            : nil
        var infoPayload = primary
        if let alias {
            infoPayload["name"] = .string(alias)
        }
        let seasons: [SeasonInfo] = Self.list(primary["seasons"]).compactMap { s in
            guard let number = s["season_number"]?.intValue else { return nil }
            return SeasonInfo(
                number: number,
                episodeCount: s["episode_count"]?.intValue ?? 0,
                name: s["name"]?.nonEmptyString,
                airDate: Self.parseDate(s["air_date"]),
                posterPath: s["poster_path"]?.nonEmptyString
            )
        }
        return ShowDetail(
            info: Self.makeCandidate(
                infoPayload,
                kind: .episode,
                englishTitle: Self.title(en, movie: false),
                primaryLang: primaryLang
            ),
            seasons: seasons
        )
    }

    public func season(_ tmdbId: Int, season: Int) async throws -> [Episode] {
        let res = try await client.get(
            "/tv/\(tmdbId)/season/\(season)",
            query: ["language": config.language]
        )
        return Self.list(res["episodes"]).compactMap { e in
            guard let number = e["episode_number"]?.intValue else { return nil }
            return Episode(
                season: e["season_number"]?.intValue ?? season,
                number: number,
                title: e["name"]?.nonEmptyString,
                airDate: Self.parseDate(e["air_date"]),
                stillPath: e["still_path"]?.nonEmptyString,
                overview: e["overview"]?.nonEmptyString,
                runtimeMinutes: e["runtime"]?.intValue
            )
        }
    }

    public func episodeGroups(_ tmdbId: Int) async throws -> [EpisodeGroup] {
        let langQuery = ["language": config.language]
        let listRes = try await client.get("/tv/\(tmdbId)/episode_groups", query: langQuery)
        let ids = Self.list(listRes["results"]).compactMap { $0["id"]?.nonEmptyString }
        if ids.isEmpty { return [] }

        let details: [[String: JSONValue]] = try await withThrowingTaskGroup(of: (Int, [String: JSONValue]).self) { group in
            for (idx, id) in ids.enumerated() {
                group.addTask {
                    let encoded = MetadataURLHelpers.encodeURIComponent(id)
                    let detail = try await self.client.get("/tv/episode_group/\(encoded)", query: langQuery)
                    return (idx, detail)
                }
            }
            var pairs: [(Int, [String: JSONValue])] = []
            for try await pair in group {
                pairs.append(pair)
            }
            pairs.sort { $0.0 < $1.0 }
            return pairs.map(\.1)
        }

        return details.compactMap { d -> EpisodeGroup? in
            guard let groupId = d["id"]?.nonEmptyString else { return nil }
            let sortedGroups = Self.sortByOrder(Self.list(d["groups"]))
            let groupSeasons: [EpisodeGroupSeason] = sortedGroups.map { g in
                let sortedEps = Self.sortByOrder(Self.list(g["episodes"]))
                let epRefs: [EpisodeRef] = sortedEps.compactMap { e in
                    guard let sn = e["season_number"]?.intValue,
                          let en = e["episode_number"]?.intValue else {
                        return nil
                    }
                    return EpisodeRef(sn, en)
                }
                return EpisodeGroupSeason(
                    order: g["order"]?.intValue ?? 0,
                    name: g["name"]?.nonEmptyString ?? "",
                    episodes: epRefs
                )
            }
            return EpisodeGroup(
                id: groupId,
                name: d["name"]?.nonEmptyString ?? "",
                type: d["type"]?.intValue ?? 0,
                seasons: groupSeasons
            )
        }
    }

    public func movie(_ tmdbId: Int) async throws -> MovieDetail {
        let (primary, en) = try await fetchDetail("/movie/\(tmdbId)", movie: true)
        let alias = config.language.hasPrefix("zh")
            ? await chineseAlias(id: tmdbId, movie: true, title: Self.title(primary, movie: true), detail: primary)
            : nil
        var infoPayload = primary
        if let alias {
            infoPayload["title"] = .string(alias)
        }
        return MovieDetail(
            info: Self.makeCandidate(
                infoPayload,
                kind: .movie,
                englishTitle: Self.title(en, movie: true),
                primaryLang: primaryLang
            )
        )
    }

    // MARK: - Candidate Mapping & Extractors

    private static func list(_ value: JSONValue?) -> [[String: JSONValue]] {
        value?.objectArray ?? []
    }

    private static func title(_ r: [String: JSONValue], movie: Bool) -> String {
        r[movie ? "title" : "name"]?.nonEmptyString ?? ""
    }

    private static func sortByOrder(_ items: [[String: JSONValue]]) -> [[String: JSONValue]] {
        items.enumerated().sorted { a, b in
            let oa = a.element["order"]?.intValue ?? 0
            let ob = b.element["order"]?.intValue ?? 0
            return oa != ob ? oa < ob : a.offset < b.offset
        }.map(\.element)
    }

    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    private static func parseYMD(_ raw: String) -> (year: Int, month: Int, day: Int)? {
        let utf8 = raw.utf8
        guard utf8.count == 10 else { return nil }
        var iter = utf8.makeIterator()
        func nextDigit() -> Int? {
            guard let b = iter.next(), b >= 0x30, b <= 0x39 else { return nil }
            return Int(b - 0x30)
        }
        guard let y0 = nextDigit(), let y1 = nextDigit(), let y2 = nextDigit(), let y3 = nextDigit(),
              iter.next() == 0x2D,
              let m0 = nextDigit(), let m1 = nextDigit(),
              iter.next() == 0x2D,
              let d0 = nextDigit(), let d1 = nextDigit() else {
            return nil
        }
        let year = y0 * 1000 + y1 * 100 + y2 * 10 + y3
        let month = m0 * 10 + m1
        let day = d0 * 10 + d1
        guard year > 0, (1...12).contains(month), day >= 1 else { return nil }
        let maxDay: Int
        switch month {
        case 1, 3, 5, 7, 8, 10, 12:
            maxDay = 31
        case 4, 6, 9, 11:
            maxDay = 30
        case 2:
            let isLeap = (year % 4 == 0) && (year % 100 != 0 || year % 400 == 0)
            maxDay = isLeap ? 29 : 28
        default:
            return nil
        }
        guard day <= maxDay else { return nil }
        return (year, month, day)
    }

    private static func dateFromUTCYMD(year: Int, month: Int, day: Int) -> Date {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mPrime = month + (month > 2 ? -3 : 9)
        let doy = (153 * mPrime + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return Date(timeIntervalSince1970: Double(days) * 86_400.0)
    }

    static func parseDate(_ value: JSONValue?) -> Date? {
        guard let raw = value?.nonEmptyString else { return nil }
        if let ymd = parseYMD(raw), ymd.year >= 1600 {
            return dateFromUTCYMD(year: ymd.year, month: ymd.month, day: ymd.day)
        }
        return TidyreelCodecs.parseISO(raw)
    }

    static func parseYear(_ value: JSONValue?) -> Int? {
        guard let raw = value?.nonEmptyString else { return nil }
        if let ymd = parseYMD(raw) {
            return ymd.year
        }
        return yearOf(TidyreelCodecs.parseISO(raw))
    }

    private static func yearOf(_ date: Date?) -> Int? {
        guard let date else { return nil }
        return utcCalendar.component(.year, from: date)
    }

    private static func dedupe(_ items: [String?], limit: Int? = nil) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        for raw in items {
            guard let raw else { continue }
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            if seen.insert(s.lowercased()).inserted {
                out.append(s)
                if let limit, out.count >= limit { break }
            }
        }
        return out
    }

    private static func pickLogo(_ r: [String: JSONValue], primaryLang: String) -> String? {
        let logos = list(r["images"]?.objectValue?["logos"])
        if logos.isEmpty { return nil }
        let lang = primaryLang.lowercased()

        func langRank(_ iso: String?) -> Int {
            guard let iso else { return 1 }
            let l = iso.lowercased()
            if l == lang { return 3 }
            if l == "en" { return 2 }
            return 0
        }

        var bestPath: String?
        var bestTier = -1
        var bestAvg = -1.0
        var bestCount = -1

        for item in logos {
            guard let path = item["file_path"]?.nonEmptyString else { continue }
            let tier = langRank(item["iso_639_1"]?.nonEmptyString)
            let avg = item["vote_average"]?.doubleValue ?? 0.0
            let count = item["vote_count"]?.intValue ?? 0
            if tier > bestTier ||
                (tier == bestTier && (avg > bestAvg || (avg == bestAvg && count > bestCount))) {
                bestPath = path
                bestTier = tier
                bestAvg = avg
                bestCount = count
            }
        }
        return bestPath
    }

    private static func pickLandscape(_ r: [String: JSONValue], primaryLang: String) -> String? {
        let backdrops = list(r["images"]?.objectValue?["backdrops"])
        if backdrops.isEmpty { return nil }
        let lang = primaryLang.lowercased()

        func langRank(_ iso: String?) -> Int {
            guard let iso else { return -1 }
            let l = iso.lowercased()
            if l == lang { return 2 }
            if l == "en" { return 1 }
            return -1
        }

        var bestPath: String?
        var bestTier = -1
        var bestAvg = -1.0
        var bestCount = -1

        for item in backdrops {
            guard let path = item["file_path"]?.nonEmptyString else { continue }
            if let aspect = item["aspect_ratio"]?.doubleValue, aspect < 1.5 {
                continue
            }
            let tier = langRank(item["iso_639_1"]?.nonEmptyString)
            if tier < 0 { continue }
            let avg = item["vote_average"]?.doubleValue ?? 0.0
            let count = item["vote_count"]?.intValue ?? 0
            if tier > bestTier ||
                (tier == bestTier && (avg > bestAvg || (avg == bestAvg && count > bestCount))) {
                bestPath = path
                bestTier = tier
                bestAvg = avg
                bestCount = count
            }
        }
        return bestPath
    }

    private static func certification(_ r: [String: JSONValue], movie: Bool) -> String? {
        if movie {
            var byRegion: [String: String] = [:]
            var firstAny: String?
            for entry in list(r["release_dates"]?.objectValue?["results"]) {
                let region = entry["iso_3166_1"]?.trimmedString?.uppercased()
                var cert: String?
                for rd in list(entry["release_dates"]) {
                    if let c = rd["certification"]?.trimmedString {
                        cert = c
                        break
                    }
                }
                guard let cert else { continue }
                if firstAny == nil { firstAny = cert }
                if let region, byRegion[region] == nil {
                    byRegion[region] = cert
                }
            }
            for pref in ["CN", "HK", "TW", "US"] {
                if let c = byRegion[pref] { return c }
            }
            return firstAny
        } else {
            var byRegion: [String: String] = [:]
            var firstAny: String?
            for entry in list(r["content_ratings"]?.objectValue?["results"]) {
                let region = entry["iso_3166_1"]?.trimmedString?.uppercased()
                guard let rating = entry["rating"]?.trimmedString else { continue }
                if firstAny == nil { firstAny = rating }
                if let region, byRegion[region] == nil {
                    byRegion[region] = rating
                }
            }
            for pref in ["CN", "US"] {
                if let c = byRegion[pref] { return c }
            }
            return firstAny
        }
    }

    private static func studios(_ r: [String: JSONValue], movie: Bool) -> [String] {
        var names: [String?] = []
        if !movie {
            for n in list(r["networks"]) {
                names.append(n["name"]?.trimmedString)
            }
        }
        for c in list(r["production_companies"]) {
            names.append(c["name"]?.trimmedString)
        }
        return dedupe(names, limit: 5)
    }

    private static func actors(_ r: [String: JSONValue]) -> [PersonCredit] {
        let cast = list(r["credits"]?.objectValue?["cast"])
        if cast.isEmpty { return [] }
        let sorted = cast.enumerated().sorted { a, b in
            let oa = a.element["order"]?.intValue ?? (1 << 30)
            let ob = b.element["order"]?.intValue ?? (1 << 30)
            return oa != ob ? oa < ob : a.offset < b.offset
        }
        var out: [PersonCredit] = []
        for entry in sorted {
            guard let name = entry.element["name"]?.trimmedString else { continue }
            out.append(
                PersonCredit(
                    name: name,
                    role: entry.element["character"]?.trimmedString,
                    profilePath: entry.element["profile_path"]?.nonEmptyString
                )
            )
            if out.count >= 12 { break }
        }
        return out
    }

    private static func directors(_ r: [String: JSONValue], movie: Bool) -> [String] {
        var names: [String?] = []
        if !movie {
            for c in list(r["created_by"]) {
                names.append(c["name"]?.trimmedString)
            }
        }
        for c in list(r["credits"]?.objectValue?["crew"]) {
            if c["job"]?.trimmedString == "Director" {
                names.append(c["name"]?.trimmedString)
            }
        }
        return dedupe(names)
    }

    private static let writerJobs: Set<String> = ["Writer", "Screenplay", "Story"]

    private static func writers(_ r: [String: JSONValue]) -> [String] {
        var names: [String?] = []
        for c in list(r["credits"]?.objectValue?["crew"]) {
            let dept = c["department"]?.trimmedString
            let job = c["job"]?.trimmedString
            if dept == "Writing" || (job != nil && writerJobs.contains(job!)) {
                names.append(c["name"]?.trimmedString)
            }
        }
        return dedupe(names, limit: 6)
    }

    private static func tags(_ r: [String: JSONValue], movie: Bool) -> [String] {
        let kw = r["keywords"]?.objectValue
        let items = list(kw?[movie ? "keywords" : "results"]).map { $0["name"]?.trimmedString }
        return dedupe(items, limit: 10)
    }

    private static func makeCandidate(
        _ r: [String: JSONValue],
        kind: MediaKind,
        englishTitle: String? = nil,
        aliases: [String] = [],
        primaryLang: String = "zh"
    ) -> Candidate {
        let isMovie = (kind == .movie)
        let year = parseYear(r[isMovie ? "release_date" : "first_air_date"])
        let country: String? = if let oc = r["origin_country"]?.arrayValue, !oc.isEmpty {
            oc[0].nonEmptyString
        } else if let pc = r["production_countries"]?.arrayValue, !pc.isEmpty {
            pc[0].objectValue?["iso_3166_1"]?.nonEmptyString
        } else {
            nil
        }
        let extIds = r["external_ids"]?.objectValue
        let collection = r["belongs_to_collection"]?.objectValue
        let cleanEnglish = (englishTitle?.isEmpty == false) ? englishTitle : nil

        return Candidate(
            tmdbId: r["id"]?.intValue ?? 0,
            kind: kind,
            title: title(r, movie: isMovie),
            englishTitle: cleanEnglish,
            originalTitle: r[isMovie ? "original_title" : "original_name"]?.nonEmptyString,
            year: year,
            posterPath: r["poster_path"]?.nonEmptyString,
            originCountry: country,
            voteAverage: r["vote_average"]?.doubleValue,
            voteCount: r["vote_count"]?.intValue,
            popularity: r["popularity"]?.doubleValue,
            overview: r["overview"]?.nonEmptyString,
            backdropPath: r["backdrop_path"]?.nonEmptyString,
            genres: list(r["genres"]).compactMap { $0["name"]?.nonEmptyString },
            aliases: aliases,
            imdbId: r["imdb_id"]?.trimmedString ?? extIds?["imdb_id"]?.trimmedString,
            tvdbId: extIds?["tvdb_id"]?.intOrParsed,
            collectionName: collection?["name"]?.trimmedString,
            collectionId: collection?["id"]?.intValue,
            clearLogoPath: pickLogo(r, primaryLang: primaryLang),
            landscapePath: pickLandscape(r, primaryLang: primaryLang),
            certification: certification(r, movie: isMovie),
            studios: studios(r, movie: isMovie),
            actors: actors(r),
            directors: directors(r, movie: isMovie),
            writers: writers(r),
            tags: tags(r, movie: isMovie)
        )
    }
}
