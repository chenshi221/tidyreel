import Foundation

/// Backward-compatible JSON codecs matching existing `tidyreel.sqlite` and `prefs.json` formats.
public enum TidyreelCodecs {
    // MARK: - Zero-Allocation Thread-Safe ISO-8601 Formatting & Parsing

    /// Howard Hinnant civil-from-days: converts days since 1970-01-01 to `(year, month, day)`.
    @inline(__always)
    private static func civilFromDays(_ days: Int64) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let yBase = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = Int(doy - (153 * mp + 2) / 5 + 1)
        let month = Int(mp + (mp < 10 ? 3 : -9))
        let year = Int(yBase + (month <= 2 ? 1 : 0))
        return (year, month, day)
    }

    /// Howard Hinnant days-from-civil: converts `(year, month, day)` to days since 1970-01-01.
    @inline(__always)
    private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int64 {
        let yr = Int64(year - (month <= 2 ? 1 : 0))
        let era = (yr >= 0 ? yr : yr - 399) / 400
        let yoe = yr - era * 400
        let doy = Int64((153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1)
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    @inline(__always)
    private static func daysInMonth(_ year: Int, _ month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2:
            return ((year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)) ? 29 : 28
        default:
            return 0
        }
    }

    @inline(__always)
    private static func asciiDigit(_ b: UInt8) -> Int? {
        guard b >= 48 && b <= 57 else { return nil }
        return Int(b - 48)
    }

    @inline(__always)
    private static func parse2Digits(_ bytes: UnsafeBufferPointer<UInt8>, _ offset: Int) -> Int? {
        guard offset + 2 <= bytes.count,
              let d0 = asciiDigit(bytes[offset]),
              let d1 = asciiDigit(bytes[offset + 1]) else { return nil }
        return d0 * 10 + d1
    }

    @inline(__always)
    private static func parse4Digits(_ bytes: UnsafeBufferPointer<UInt8>, _ offset: Int) -> Int? {
        guard offset + 4 <= bytes.count,
              let d0 = asciiDigit(bytes[offset]),
              let d1 = asciiDigit(bytes[offset + 1]),
              let d2 = asciiDigit(bytes[offset + 2]),
              let d3 = asciiDigit(bytes[offset + 3]) else { return nil }
        return d0 * 1000 + d1 * 100 + d2 * 10 + d3
    }

    public static func formatISO(_ date: Date) -> String {
        let ti = date.timeIntervalSince1970
        guard ti.isFinite, ti >= -62_167_219_200.0, ti < 253_402_300_799.9994 else {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: date)
        }
        let totalMs = Int64((ti * 1000.0).rounded())
        var totalSec = totalMs / 1000
        var ms = Int(totalMs % 1000)
        if ms < 0 {
            ms += 1000
            totalSec -= 1
        }
        var days = totalSec / 86_400
        var secOfDay = Int(totalSec % 86_400)
        if secOfDay < 0 {
            secOfDay += 86_400
            days -= 1
        }
        let (year, month, day) = civilFromDays(days)
        let hour = secOfDay / 3600
        let rem = secOfDay % 3600
        let minute = rem / 60
        let second = rem % 60

        return String(unsafeUninitializedCapacity: 24) { buf in
            let zero: UInt8 = 48 // '0'
            buf[0] = zero + UInt8(year / 1000)
            buf[1] = zero + UInt8((year / 100) % 10)
            buf[2] = zero + UInt8((year / 10) % 10)
            buf[3] = zero + UInt8(year % 10)
            buf[4] = 45 // '-'
            buf[5] = zero + UInt8(month / 10)
            buf[6] = zero + UInt8(month % 10)
            buf[7] = 45 // '-'
            buf[8] = zero + UInt8(day / 10)
            buf[9] = zero + UInt8(day % 10)
            buf[10] = 84 // 'T'
            buf[11] = zero + UInt8(hour / 10)
            buf[12] = zero + UInt8(hour % 10)
            buf[13] = 58 // ':'
            buf[14] = zero + UInt8(minute / 10)
            buf[15] = zero + UInt8(minute % 10)
            buf[16] = 58 // ':'
            buf[17] = zero + UInt8(second / 10)
            buf[18] = zero + UInt8(second % 10)
            buf[19] = 46 // '.'
            buf[20] = zero + UInt8(ms / 100)
            buf[21] = zero + UInt8((ms / 10) % 10)
            buf[22] = zero + UInt8(ms % 10)
            buf[23] = 90 // 'Z'
            return 24
        }
    }

    public static func parseISO(_ raw: String?) -> Date? {
        guard var s = raw, !s.isEmpty else { return nil }
        return s.withUTF8 { bytes in
            let n = bytes.count
            guard n >= 10,
                  let year = parse4Digits(bytes, 0),
                  bytes[4] == 45, // '-'
                  let month = parse2Digits(bytes, 5),
                  bytes[7] == 45, // '-'
                  let day = parse2Digits(bytes, 8),
                  (1...12).contains(month),
                  day >= 1,
                  day <= daysInMonth(year, month) else {
                return nil
            }

            let days = daysFromCivil(year, month, day)
            if n == 10 {
                return Date(timeIntervalSince1970: Double(days * 86_400))
            }

            let sep = bytes[10]
            guard sep == 84 || sep == 116 || sep == 32 else { return nil } // 'T', 't', ' '
            guard n >= 19,
                  let hour = parse2Digits(bytes, 11),
                  bytes[13] == 58, // ':'
                  let minute = parse2Digits(bytes, 14),
                  bytes[16] == 58, // ':'
                  let second = parse2Digits(bytes, 17),
                  hour <= 23, minute <= 59, second <= 59 else {
                return nil
            }

            var i = 19
            var fracNanos: Int64 = 0
            if i < n && (bytes[i] == 46 || bytes[i] == 44) { // '.' or ','
                i += 1
                var scale: Int64 = 100_000_000
                var fracDigits = 0
                while i < n, let d = asciiDigit(bytes[i]) {
                    if scale > 0 {
                        fracNanos += Int64(d) * scale
                        scale /= 10
                    }
                    fracDigits += 1
                    i += 1
                }
                guard fracDigits > 0 else { return nil }
            }

            var tzOffsetSeconds = 0
            if i < n {
                let tz = bytes[i]
                if tz == 90 || tz == 122 { // 'Z' or 'z'
                    i += 1
                } else if tz == 43 || tz == 45 { // '+' or '-'
                    let sign = tz == 43 ? 1 : -1
                    i += 1
                    guard let tzHour = parse2Digits(bytes, i), tzHour <= 23 else { return nil }
                    i += 2
                    var tzMinute = 0
                    if i < n {
                        if bytes[i] == 58 { // ':'
                            i += 1
                        }
                        guard let m = parse2Digits(bytes, i), m <= 59 else { return nil }
                        tzMinute = m
                        i += 2
                    }
                    tzOffsetSeconds = sign * (tzHour * 3600 + tzMinute * 60)
                } else {
                    return nil
                }
            }
            guard i == n else { return nil }

            let totalSeconds = days * 86_400 + Int64(hour * 3600 + minute * 60 + second - tzOffsetSeconds)
            return Date(timeIntervalSince1970: Double(totalSeconds) + Double(fracNanos) / 1_000_000_000.0)
        }
    }

    // MARK: - Candidate & ScanResult (SQLite scan_json / decisions_json)

    public static func probeToDict(_ p: MediaProbeInfo) -> [String: Any] {
        var d: [String: Any] = [:]
        if let v = p.width { d["width"] = v }
        if let v = p.height { d["height"] = v }
        if let v = p.videoCodec { d["videoCodec"] = v }
        if let v = p.hdr { d["hdr"] = v }
        if let v = p.audioCodec { d["audioCodec"] = v }
        if let v = p.audioChannels { d["audioChannels"] = v }
        if let v = p.durationMs { d["durationMs"] = v }
        if let v = p.container { d["container"] = v }
        return d
    }

    public static func probeFromDict(_ j: [String: Any]) -> MediaProbeInfo {
        MediaProbeInfo(
            width: (j["width"] as? NSNumber)?.intValue,
            height: (j["height"] as? NSNumber)?.intValue,
            videoCodec: j["videoCodec"] as? String,
            hdr: j["hdr"] as? String,
            audioCodec: j["audioCodec"] as? String,
            audioChannels: (j["audioChannels"] as? NSNumber)?.intValue,
            durationMs: (j["durationMs"] as? NSNumber)?.int64Value,
            container: j["container"] as? String
        )
    }

    public static func candidateToDict(_ c: Candidate) -> [String: Any] {
        var d: [String: Any] = [
            "tmdbId": c.tmdbId,
            "kind": c.kind.rawValue,
            "title": c.title,
            "genres": c.genres,
        ]
        if let v = c.englishTitle { d["englishTitle"] = v }
        if let v = c.originalTitle { d["originalTitle"] = v }
        if let v = c.year { d["year"] = v }
        if let v = c.overview { d["overview"] = v }
        if let v = c.posterPath { d["posterPath"] = v }
        if let v = c.backdropPath { d["backdropPath"] = v }
        if let v = c.originCountry { d["originCountry"] = v }
        if let v = c.voteAverage { d["voteAverage"] = v }
        if let v = c.voteCount { d["voteCount"] = v }
        if let v = c.popularity { d["popularity"] = v }
        if !c.aliases.isEmpty { d["aliases"] = c.aliases }
        if let v = c.imdbId { d["imdbId"] = v }
        if let v = c.tvdbId { d["tvdbId"] = v }
        if let v = c.collectionName { d["collectionName"] = v }
        if let v = c.collectionId { d["collectionId"] = v }
        if let v = c.clearLogoPath { d["clearLogoPath"] = v }
        if let v = c.landscapePath { d["landscapePath"] = v }
        if let v = c.certification { d["certification"] = v }
        if !c.studios.isEmpty { d["studios"] = c.studios }
        if !c.actors.isEmpty {
            d["actors"] = c.actors.map { a -> [String: Any] in
                var ad: [String: Any] = ["name": a.name]
                if let r = a.role { ad["role"] = r }
                if let p = a.profilePath { ad["profilePath"] = p }
                return ad
            }
        }
        if !c.directors.isEmpty { d["directors"] = c.directors }
        if !c.writers.isEmpty { d["writers"] = c.writers }
        if !c.tags.isEmpty { d["tags"] = c.tags }
        return d
    }

    public static func candidateFromDict(_ j: [String: Any]) -> Candidate? {
        guard let tmdbId = (j["tmdbId"] as? NSNumber)?.intValue,
              let title = j["title"] as? String else { return nil }
        let kind = (j["kind"] as? String).flatMap(MediaKind.init(rawValue:)) ?? .unknown
        let actors = ((j["actors"] as? [[String: Any]]) ?? []).compactMap { a -> PersonCredit? in
            guard let name = a["name"] as? String else { return nil }
            return PersonCredit(name: name, role: a["role"] as? String, profilePath: a["profilePath"] as? String)
        }
        return Candidate(
            tmdbId: tmdbId,
            kind: kind,
            title: title,
            englishTitle: j["englishTitle"] as? String,
            originalTitle: j["originalTitle"] as? String,
            year: (j["year"] as? NSNumber)?.intValue,
            posterPath: j["posterPath"] as? String,
            originCountry: j["originCountry"] as? String,
            voteAverage: (j["voteAverage"] as? NSNumber)?.doubleValue,
            voteCount: (j["voteCount"] as? NSNumber)?.intValue,
            popularity: (j["popularity"] as? NSNumber)?.doubleValue,
            overview: j["overview"] as? String,
            backdropPath: j["backdropPath"] as? String,
            genres: (j["genres"] as? [Any])?.compactMap { $0 as? String } ?? [],
            aliases: (j["aliases"] as? [Any])?.compactMap { $0 as? String } ?? [],
            imdbId: j["imdbId"] as? String,
            tvdbId: (j["tvdbId"] as? NSNumber)?.intValue,
            collectionName: j["collectionName"] as? String,
            collectionId: (j["collectionId"] as? NSNumber)?.intValue,
            clearLogoPath: j["clearLogoPath"] as? String,
            landscapePath: j["landscapePath"] as? String,
            certification: j["certification"] as? String,
            studios: (j["studios"] as? [Any])?.compactMap { $0 as? String } ?? [],
            actors: actors,
            directors: (j["directors"] as? [Any])?.compactMap { $0 as? String } ?? [],
            writers: (j["writers"] as? [Any])?.compactMap { $0 as? String } ?? [],
            tags: (j["tags"] as? [Any])?.compactMap { $0 as? String } ?? []
        )
    }

    public static func parsedToDict(_ p: ParsedName) -> [String: Any] {
        var d: [String: Any] = [
            "episodes": p.episodes,
            "kind": p.kind.rawValue,
            "confidence": p.confidence,
        ]
        if let v = p.title { d["title"] = v }
        if let v = p.year { d["year"] = v }
        if let v = p.season { d["season"] = v }
        if let v = p.absolute { d["absolute"] = v }
        if let v = p.airDate { d["airDate"] = formatISO(v) }
        if let v = p.resolution { d["resolution"] = v }
        if let v = p.group { d["group"] = v }
        if let v = p.lang { d["lang"] = v }
        if let v = p.extraInfo { d["extraInfo"] = v }
        if let v = p.edition { d["edition"] = v }
        if let v = p.part { d["part"] = v }
        if let v = p.partLabel { d["partLabel"] = v }
        if !p.subFlags.isEmpty { d["subFlags"] = p.subFlags }
        if let ext = p.externalId { d["externalId"] = ["source": ext.source, "id": ext.id] }
        if p.isDisc { d["isDisc"] = true }
        if let probe = p.probe { d["probe"] = probeToDict(probe) }
        return d
    }

    public static func parsedFromDict(_ j: [String: Any]) -> ParsedName {
        var externalId: ExternalId?
        if let extMap = j["externalId"] as? [String: Any],
           let src = extMap["source"] as? String,
           let id = extMap["id"] as? String {
            externalId = ExternalId(src, id)
        }
        let episodes = (j["episodes"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
        return ParsedName(
            title: j["title"] as? String,
            year: (j["year"] as? NSNumber)?.intValue,
            season: (j["season"] as? NSNumber)?.intValue,
            episodes: episodes,
            absolute: (j["absolute"] as? NSNumber)?.intValue,
            kind: (j["kind"] as? String).flatMap(MediaKind.init(rawValue:)) ?? .unknown,
            resolution: j["resolution"] as? String,
            group: j["group"] as? String,
            lang: j["lang"] as? String,
            extraInfo: j["extraInfo"] as? String,
            confidence: (j["confidence"] as? NSNumber)?.doubleValue ?? 0,
            airDate: parseISO(j["airDate"] as? String),
            edition: j["edition"] as? String,
            part: (j["part"] as? NSNumber)?.intValue,
            partLabel: j["partLabel"] as? String,
            subFlags: (j["subFlags"] as? [Any])?.compactMap { $0 as? String } ?? [],
            externalId: externalId,
            isDisc: (j["isDisc"] as? Bool) ?? false,
            probe: (j["probe"] as? [String: Any]).map(probeFromDict)
        )
    }

    public static func scanFileToDict(_ f: ScanFile) -> [String: Any] {
        var d: [String: Any] = [
            "path": f.path,
            "name": f.name,
            "size": f.size,
            "role": f.role.rawValue,
        ]
        if let p = f.parsed { d["parsed"] = parsedToDict(p) } else { d["parsed"] = NSNull() }
        if f.isDiscDir { d["isDiscDir"] = true }
        return d
    }

    public static func scanFileFromDict(_ j: [String: Any]) -> ScanFile? {
        guard let path = j["path"] as? String,
              let name = j["name"] as? String else { return nil }
        let size = (j["size"] as? NSNumber)?.int64Value ?? 0
        let role = (j["role"] as? String).flatMap(FileRole.init(rawValue:)) ?? .other
        let parsed = (j["parsed"] as? [String: Any]).map(parsedFromDict)
        return ScanFile(
            path: path,
            name: name,
            size: size,
            role: role,
            parsed: parsed,
            isDiscDir: (j["isDiscDir"] as? Bool) ?? false
        )
    }

    public static func showToDict(_ s: ShowDetail) -> [String: Any] {
        [
            "info": candidateToDict(s.info),
            "seasons": s.seasons.map { x -> [String: Any] in
                var sd: [String: Any] = [
                    "number": x.number,
                    "episodeCount": x.episodeCount,
                ]
                if let n = x.name { sd["name"] = n }
                if let a = x.airDate { sd["airDate"] = formatISO(a) }
                if let p = x.posterPath { sd["posterPath"] = p }
                return sd
            },
        ]
    }

    public static func showFromDict(_ j: [String: Any]) -> ShowDetail? {
        guard let infoMap = j["info"] as? [String: Any],
              let info = candidateFromDict(infoMap) else { return nil }
        let seasons = ((j["seasons"] as? [[String: Any]]) ?? []).compactMap { x -> SeasonInfo? in
            guard let num = (x["number"] as? NSNumber)?.intValue,
                  let count = (x["episodeCount"] as? NSNumber)?.intValue else { return nil }
            return SeasonInfo(
                number: num,
                episodeCount: count,
                name: x["name"] as? String,
                airDate: parseISO(x["airDate"] as? String),
                posterPath: x["posterPath"] as? String
            )
        }
        return ShowDetail(info: info, seasons: seasons)
    }

    public static func scanToJson(_ s: ScanResult) throws -> String {
        try autoreleasepool {
            let obj: [String: Any] = [
                "connection": s.connection.value,
                "roots": s.roots,
                "groups": s.groups.map { g -> [String: Any] in
                    var gd: [String: Any] = [
                        "id": g.id.value,
                        "kind": g.kind.rawValue,
                        "anchorTitle": g.anchorTitle,
                        "rootDir": g.rootDir,
                        "files": g.files.map(scanFileToDict),
                        "matchScore": g.matchScore,
                    ]
                    if let y = g.anchorYear { gd["anchorYear"] = y }
                    if let m = g.match { gd["match"] = candidateToDict(m) } else { gd["match"] = NSNull() }
                    if let sh = g.show { gd["show"] = showToDict(sh) } else { gd["show"] = NSNull() }
                    if let st = g.suggestedStrategy { gd["suggestedStrategy"] = st.rawValue }
                    if let r = g.suggestedStrategyReason { gd["suggestedStrategyReason"] = r }
                    return gd
                },
                "unassigned": s.unassigned.map(scanFileToDict),
            ]
            let data = try JSONSerialization.data(withJSONObject: obj)
            return String(decoding: data, as: UTF8.self)
        }
    }

    public static func scanFromJson(_ text: String) throws -> ScanResult {
        try autoreleasepool {
            guard let data = text.data(using: .utf8),
                  let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let conn = j["connection"] as? String else {
                throw CocoaError(.coderReadCorrupt)
            }
            let roots = (j["roots"] as? [Any])?.compactMap { $0 as? String } ?? []
            let groups = ((j["groups"] as? [[String: Any]]) ?? []).compactMap { g -> MediaGroup? in
                guard let id = g["id"] as? String,
                      let anchorTitle = g["anchorTitle"] as? String,
                      let rootDir = g["rootDir"] as? String else { return nil }
                let kind = (g["kind"] as? String).flatMap(MediaKind.init(rawValue:)) ?? .unknown
                let files = ((g["files"] as? [[String: Any]]) ?? []).compactMap(scanFileFromDict)
                let match = (g["match"] as? [String: Any]).flatMap(candidateFromDict)
                let show = (g["show"] as? [String: Any]).flatMap(showFromDict)
                return MediaGroup(
                    id: GroupId(id),
                    kind: kind,
                    anchorTitle: anchorTitle,
                    anchorYear: (g["anchorYear"] as? NSNumber)?.intValue,
                    rootDir: rootDir,
                    files: files,
                    match: match,
                    matchScore: (g["matchScore"] as? NSNumber)?.doubleValue ?? 0,
                    show: show,
                    suggestedStrategy: (g["suggestedStrategy"] as? String).flatMap(SeasonStrategy.init(rawValue:)),
                    suggestedStrategyReason: g["suggestedStrategyReason"] as? String
                )
            }
            let unassigned = ((j["unassigned"] as? [[String: Any]]) ?? []).compactMap(scanFileFromDict)
            return ScanResult(connection: ConnectionId(conn), roots: roots, groups: groups, unassigned: unassigned)
        }
    }

    public static func decisionsToJson(_ decisions: [GroupId: GroupDecision]) throws -> String {
        try autoreleasepool {
            var obj: [String: Any] = [:]
            for (id, d) in decisions {
                var overridesObj: [String: Any] = [:]
                for (path, o) in d.overrides {
                    var od: [String: Any] = ["ignore": o.ignore]
                    if let s = o.season { od["season"] = s } else { od["season"] = NSNull() }
                    if let e = o.episode { od["episode"] = e } else { od["episode"] = NSNull() }
                    if let k = o.kind { od["kind"] = k.rawValue } else { od["kind"] = NSNull() }
                    overridesObj[path] = od
                }
                var dd: [String: Any] = [
                    "strategy": d.strategy.rawValue,
                    "episodeOffset": d.episodeOffset,
                    "selected": d.selected,
                    "overrides": overridesObj,
                ]
                if let m = d.match { dd["match"] = candidateToDict(m) } else { dd["match"] = NSNull() }
                if let eg = d.episodeGroupId { dd["episodeGroupId"] = eg } else { dd["episodeGroupId"] = NSNull() }
                if d.separate { dd["separate"] = true }
                obj[id.value] = dd
            }
            let data = try JSONSerialization.data(withJSONObject: obj)
            return String(decoding: data, as: UTF8.self)
        }
    }

    public static func decisionsFromJson(_ text: String) throws -> [GroupId: GroupDecision] {
        try autoreleasepool {
            guard let data = text.data(using: .utf8),
                  let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [:]
            }
            var out: [GroupId: GroupDecision] = [:]
            for (id, rawVal) in j {
                guard let dm = rawVal as? [String: Any] else { continue }
                var overrides: [String: FileOverride] = [:]
                if let om = dm["overrides"] as? [String: Any] {
                    for (path, rawOv) in om {
                        guard let ov = rawOv as? [String: Any] else { continue }
                        overrides[path] = FileOverride(
                            season: (ov["season"] as? NSNumber)?.intValue,
                            episode: (ov["episode"] as? NSNumber)?.intValue,
                            kind: (ov["kind"] as? String).flatMap(MediaKind.init(rawValue:)),
                            ignore: (ov["ignore"] as? Bool) ?? false
                        )
                    }
                }
                out[GroupId(id)] = GroupDecision(
                    match: (dm["match"] as? [String: Any]).flatMap(candidateFromDict),
                    strategy: (dm["strategy"] as? String).flatMap(SeasonStrategy.init(rawValue:)) ?? .asParsed,
                    episodeOffset: (dm["episodeOffset"] as? NSNumber)?.intValue ?? 0,
                    episodeGroupId: dm["episodeGroupId"] as? String,
                    overrides: overrides,
                    selected: (dm["selected"] as? Bool) ?? true,
                    separate: (dm["separate"] as? Bool) ?? false
                )
            }
            return out
        }
    }

    // MARK: - Compact Folder Stats Entries ({p, n, d, s, m})

    public static func entriesToCompactJson(_ entries: [RemoteEntry]) throws -> String {
        try autoreleasepool {
            let arr: [[String: Any]] = entries.map { e in
                var d: [String: Any] = [
                    "p": e.path,
                    "n": e.name,
                    "d": e.isDir,
                    "s": e.size,
                ]
                if let m = e.modified { d["m"] = Int64((m.timeIntervalSince1970 * 1000.0).rounded()) }
                return d
            }
            let data = try JSONSerialization.data(withJSONObject: arr)
            return String(decoding: data, as: UTF8.self)
        }
    }

    public static func entriesFromCompactJson(_ text: String) -> [RemoteEntry] {
        autoreleasepool {
            guard let data = text.data(using: .utf8),
                  let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                return []
            }
            return arr.compactMap { m in
                guard let p = m["p"] as? String, let n = m["n"] as? String else { return nil }
                let isDir = (m["d"] as? Bool) ?? ((m["d"] as? NSNumber)?.boolValue ?? false)
                let size = (m["s"] as? NSNumber)?.int64Value ?? 0
                let mod: Date?
                if let ms = m["m"] as? NSNumber {
                    mod = Date(timeIntervalSince1970: ms.doubleValue / 1000.0)
                } else if let str = m["m"] as? String {
                    mod = parseISO(str)
                } else {
                    mod = nil
                }
                return RemoteEntry(path: p, name: n, isDir: isDir, size: size, modified: mod)
            }
        }
    }

    // MARK: - Settings, Connections, Naming & TitleRules (prefs.json compatible)

    public static func connectionToDict(_ c: ConnectionConfig) -> [String: Any] {
        var d: [String: Any] = [
            "id": c.id.value,
            "name": c.name,
            "type": c.type.rawValue,
            "endpoint": c.endpoint,
            "favorites": c.favorites,
            "startDir": c.startDir,
        ]
        if let u = c.username { d["username"] = u } else { d["username"] = NSNull() }
        if let lr = c.libraryRoot { d["libraryRoot"] = lr } else { d["libraryRoot"] = NSNull() }
        return d
    }

    public static func connectionFromDict(_ j: [String: Any]) -> ConnectionConfig? {
        guard let id = j["id"] as? String,
              let name = j["name"] as? String,
              let endpoint = j["endpoint"] as? String else { return nil }
        return ConnectionConfig(
            id: ConnectionId(id),
            name: name,
            type: (j["type"] as? String).flatMap(ConnectionType.init(rawValue:)) ?? .webdav,
            endpoint: endpoint,
            username: j["username"] as? String,
            libraryRoot: j["libraryRoot"] as? String,
            favorites: (j["favorites"] as? [Any])?.compactMap { $0 as? String } ?? [],
            startDir: (j["startDir"] as? String) ?? "/"
        )
    }

    public static func namingOptionsToDict(_ o: NamingOptions) -> [String: Any] {
        var d: [String: Any] = [
            "titleLanguage": o.titleLanguage.rawValue,
            "bilingual": o.bilingual,
            "includeYear": o.includeYear,
            "yearInParens": o.yearInParens,
            "showYear": o.showYear.rawValue,
            "episodeStyle": o.episodeStyle.rawValue,
            "episodeTitle": o.episodeTitle,
            "extraInfo": o.extraInfo,
            "separator": o.separator,
            "releaseGroup": o.releaseGroup,
            "tmdbIdTag": o.tmdbIdTag,
            "order": o.order.map(\.rawValue),
            "folderTemplate": o.folderTemplate,
            "seasonFolderTemplate": o.seasonFolderTemplate,
            "singleSeasonFolder": o.singleSeasonFolder,
            "rewrites": o.rewrites.map { ["p": $0.pattern, "r": $0.replacement] },
        ]
        if let ct = o.customTemplate { d["customTemplate"] = ct } else { d["customTemplate"] = NSNull() }
        return d
    }

    public static func namingOptionsFromDict(_ j: [String: Any]) -> NamingOptions {
        let d = NamingOptions()
        let order = ((j["order"] as? [Any]) ?? []).compactMap { ($0 as? String).flatMap(NameField.init(rawValue:)) }
        let rewrites = ((j["rewrites"] as? [[String: Any]]) ?? []).compactMap { r -> NameRewrite? in
            guard let p = r["p"] as? String else { return nil }
            return NameRewrite(p, (r["r"] as? String) ?? "")
        }
        return NamingOptions(
            titleLanguage: (j["titleLanguage"] as? String).flatMap(TitleLanguage.init(rawValue:)) ?? d.titleLanguage,
            bilingual: (j["bilingual"] as? Bool) ?? d.bilingual,
            includeYear: (j["includeYear"] as? Bool) ?? d.includeYear,
            yearInParens: (j["yearInParens"] as? Bool) ?? d.yearInParens,
            showYear: (j["showYear"] as? String).flatMap(ShowYearSource.init(rawValue:)) ?? d.showYear,
            episodeStyle: (j["episodeStyle"] as? String).flatMap(EpisodeStyle.init(rawValue:)) ?? d.episodeStyle,
            episodeTitle: (j["episodeTitle"] as? Bool) ?? d.episodeTitle,
            extraInfo: (j["extraInfo"] as? Bool) ?? d.extraInfo,
            separator: (j["separator"] as? String) ?? d.separator,
            releaseGroup: (j["releaseGroup"] as? Bool) ?? d.releaseGroup,
            tmdbIdTag: (j["tmdbIdTag"] as? Bool) ?? d.tmdbIdTag,
            order: order.isEmpty ? d.order : order,
            folderTemplate: (j["folderTemplate"] as? String) ?? d.folderTemplate,
            seasonFolderTemplate: (j["seasonFolderTemplate"] as? String) ?? d.seasonFolderTemplate,
            singleSeasonFolder: (j["singleSeasonFolder"] as? Bool) ?? d.singleSeasonFolder,
            customTemplate: j["customTemplate"] as? String,
            rewrites: rewrites
        )
    }

    public static func namingProfileToDict(_ p: NamingProfile) -> [String: Any] {
        [
            "player": p.player.rawValue,
            "movie": namingOptionsToDict(p.movie),
            "tv": namingOptionsToDict(p.tv),
            "movieDir": p.movieDir,
            "tvDir": p.tvDir,
        ]
    }

    public static func namingProfileFromDict(_ j: [String: Any]) -> NamingProfile {
        let d = NamingProfile.vidhub
        return NamingProfile(
            player: (j["player"] as? String).flatMap(TargetPlayer.init(rawValue:)) ?? d.player,
            movie: (j["movie"] as? [String: Any]).map(namingOptionsFromDict) ?? d.movie,
            tv: (j["tv"] as? [String: Any]).map(namingOptionsFromDict) ?? d.tv,
            movieDir: (j["movieDir"] as? String) ?? d.movieDir,
            tvDir: (j["tvDir"] as? String) ?? d.tvDir
        )
    }

    public static func titleRulesToDict(_ r: TitleRules) -> [String: Any] {
        [
            "cleanups": r.cleanups.map { ["p": $0.pattern, "r": $0.replacement] },
            "pins": r.pins.map { ["k": $0.keyword, "m": candidateToDict($0.match)] },
        ]
    }

    public static func titleRulesFromDict(_ j: [String: Any]) -> TitleRules {
        let cleanups = ((j["cleanups"] as? [[String: Any]]) ?? []).compactMap { r -> NameRewrite? in
            guard let p = r["p"] as? String else { return nil }
            return NameRewrite(p, (r["r"] as? String) ?? "")
        }
        let pins = ((j["pins"] as? [[String: Any]]) ?? []).compactMap { p -> TitlePin? in
            guard let k = p["k"] as? String,
                  let mMap = p["m"] as? [String: Any],
                  let cand = candidateFromDict(mMap) else { return nil }
            return TitlePin(k, cand)
        }
        return TitleRules(cleanups: cleanups, pins: pins)
    }

    public static func settingsToDict(_ s: AppSettings) -> [String: Any] {
        [
            "tmdbBaseUrl": s.tmdbBaseUrl,
            "defaultMode": s.defaultMode.rawValue,
            "autoDeleteJunk": s.autoDeleteJunk,
            "themeMode": s.themeMode.rawValue,
            "appLanguage": s.appLanguage.rawValue,
            "concurrency": s.concurrency,
            "requestsPerSecond": s.requestsPerSecond,
            "scanPreview": s.scanPreview,
            "tmdbLanguage": s.tmdbLanguage,
            "confidenceThreshold": s.confidenceThreshold,
            "mediaHint": s.mediaHint.rawValue,
            "probeMedia": s.probeMedia,
            "overwriteNfo": s.overwriteNfo,
            "enableBangumi": s.enableBangumi,
            "reviewLeftWidth": s.reviewLeftWidth,
            "reviewRightWidth": s.reviewRightWidth,
            "accent": s.accent.rawValue,
            "sidebarCollapsed": s.sidebarCollapsed,
            "reduceMotion": s.reduceMotion,
            "notifyRecognized": s.notifyRecognized,
            "notifyFinished": s.notifyFinished,
            "mapZoomStyle": s.mapZoomStyle.rawValue,
        ]
    }

    public static func settingsFromDict(_ j: [String: Any], tmdbApiKey: String = "", defaultTmdbLang: String = "zh-CN") -> AppSettings {
        let d = AppSettings()
        let rawConf = (j["confidenceThreshold"] as? NSNumber)?.doubleValue
        let conf = (rawConf != nil && rawConf!.isFinite) ? rawConf! : d.confidenceThreshold
        let concurrency = min(8, max(1, (j["concurrency"] as? NSNumber)?.intValue ?? d.concurrency))
        let rps = min(20, max(1, (j["requestsPerSecond"] as? NSNumber)?.intValue ?? d.requestsPerSecond))
        let lw = min(460.0, max(240.0, (j["reviewLeftWidth"] as? NSNumber)?.doubleValue ?? d.reviewLeftWidth))
        let rw = min(420.0, max(220.0, (j["reviewRightWidth"] as? NSNumber)?.doubleValue ?? d.reviewRightWidth))
        return AppSettings(
            tmdbApiKey: tmdbApiKey,
            tmdbBaseUrl: (j["tmdbBaseUrl"] as? String) ?? d.tmdbBaseUrl,
            defaultMode: (j["defaultMode"] as? String).flatMap(OrganizeMode.init(rawValue:)) ?? d.defaultMode,
            autoDeleteJunk: (j["autoDeleteJunk"] as? Bool) ?? d.autoDeleteJunk,
            themeMode: (j["themeMode"] as? String).flatMap(AppThemeMode.init(rawValue:)) ?? d.themeMode,
            appLanguage: (j["appLanguage"] as? String).flatMap(AppLanguage.init(rawValue:)) ?? d.appLanguage,
            concurrency: concurrency,
            requestsPerSecond: rps,
            scanPreview: (j["scanPreview"] as? Bool) ?? d.scanPreview,
            tmdbLanguage: (j["tmdbLanguage"] as? String) ?? defaultTmdbLang,
            confidenceThreshold: conf,
            mediaHint: (j["mediaHint"] as? String).flatMap(MediaHint.init(rawValue:)) ?? d.mediaHint,
            probeMedia: (j["probeMedia"] as? Bool) ?? d.probeMedia,
            overwriteNfo: (j["overwriteNfo"] as? Bool) ?? d.overwriteNfo,
            enableBangumi: (j["enableBangumi"] as? Bool) ?? d.enableBangumi,
            reviewLeftWidth: lw,
            reviewRightWidth: rw,
            accent: (j["accent"] as? String).flatMap(AccentChoice.init(rawValue:)) ?? d.accent,
            sidebarCollapsed: (j["sidebarCollapsed"] as? Bool) ?? d.sidebarCollapsed,
            reduceMotion: (j["reduceMotion"] as? Bool) ?? d.reduceMotion,
            notifyRecognized: (j["notifyRecognized"] as? Bool) ?? d.notifyRecognized,
            notifyFinished: (j["notifyFinished"] as? Bool) ?? d.notifyFinished,
            mapZoomStyle: (j["mapZoomStyle"] as? String).flatMap(MapZoomStyle.init(rawValue:)) ?? d.mapZoomStyle
        )
    }
}
