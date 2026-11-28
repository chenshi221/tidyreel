import Foundation
import TidyreelModels

/// Subtitles and sidecars that follow a video (shared by the recognizer and the planner).
public struct FollowMatch: Equatable, Hashable, Sendable {
    public var video: ScanFile
    /// Text between the video's base name and the extension, e.g. `.chs` or `-poster`.
    public var remainder: String

    public init(_ video: ScanFile, _ remainder: String) {
        self.video = video
        self.remainder = remainder
    }

    public init(video: ScanFile, remainder: String) {
        self.video = video
        self.remainder = remainder
    }
}

private enum FollowRegex {
    static let subSe = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])S(\d{1,2})[\s._-]?E(\d{1,4})(?![A-Za-z0-9])"#,
        options: [.caseInsensitive]
    )
    static let subX = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])(\d{1,2})x(\d{2,3})(?![A-Za-z0-9])"#,
        options: [.caseInsensitive]
    )
    static let subEp = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])(?:EP|Episode[\s._-]?|E)(\d{1,4})(?![A-Za-z0-9])"#,
        options: [.caseInsensitive]
    )
    static let subCnEp = try! NSRegularExpression(
        pattern: #"第\s*(\d{1,4})\s*[集话話期回]"#
    )
    static let subYear = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9\u3400-\u9fff])((?:19|20)\d\d)(?![A-Za-z0-9])"#
    )
    static let cjkBilingual = try! NSRegularExpression(
        pattern: #"双语|雙語|中英|简英|繁英|簡英|简日|繁日|簡日|简繁|簡繁"#
    )
    static let cjkSdh = try! NSRegularExpression(pattern: #"听障|聽障"#)
    static let cjkForced = try! NSRegularExpression(pattern: #"强制|強制"#)
    static let cjkDefault = try! NSRegularExpression(pattern: #"默认|默認"#)
    static let digitsOnly = try! NSRegularExpression(pattern: #"^\d+$"#)
    static let resNoise = try! NSRegularExpression(
        pattern: #"^(?:\d{3,4}[pi]|\d{3,4}x\d{3,4}|[248]k)$"#
    )
    static let fuzzySplit = try! NSRegularExpression(pattern: #"[^\p{L}\p{N}]+"#)
    static let cjkRun = try! NSRegularExpression(
        pattern: #"[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]+"#
    )
    static let latinWord = try! NSRegularExpression(pattern: #"[a-z0-9]+"#)
}

private let zhHansSet: Set<String> = [
    "chs", "sc", "gb", "gbk", "gb2312", "jpsc", "cn", "简体", "简中", "简", "简体中文",
    "简日", "简英", "简繁", "中英", "中英双语", "中英雙語", "中字双语", "中字", "双语", "雙語",
    "zh-cn", "zh-hans", "zh-sg", "zhs", "zh", "chi", "zho", "chinese", "中文",
]

private let zhHantSet: Set<String> = [
    "cht", "tc", "big5", "jptc", "繁体", "繁體", "繁中", "繁", "繁体中文", "繁體中文",
    "繁日", "繁英", "zh-tw", "zh-hk", "zh-hant", "zh-mo", "tw", "hk", "zht",
]

private let enSet: Set<String> = [
    "eng", "en", "english", "en-us", "en-gb", "英文", "英语", "英語",
]

private let jaSet: Set<String> = [
    "jpn", "jap", "ja", "jp", "ja-jp", "japanese", "日文", "日语", "日語",
]

private let koSet: Set<String> = [
    "kor", "ko", "kr", "ko-kr", "korean", "韩文", "韓文", "韩语", "韓語",
]

private let bilingualFollowTokens: Set<String> = [
    "bilingual", "jpsc", "jptc", "scjp", "tcjp", "chseng", "chteng",
    "sceng", "tceng", "chsjp", "chtjp", "zhongying",
]

private let ambiguousFlagWords: Set<String> = ["force", "hi", "cc", "dual"]

private let fuzzyNoise: Set<String> = [
    "web", "dl", "webdl", "webrip", "webhd", "bluray", "bdrip", "brrip",
    "bdremux", "remux", "hdtv", "pdtv", "dvdrip", "dvd", "hdrip", "bd",
    "uhd", "fhd", "hdr", "hdr10", "hdr10plus", "dv", "dovi", "hlg", "sdr",
    "imax", "x264", "x265", "h264", "h265", "hevc", "avc", "av1", "xvid",
    "divx", "10bit", "8bit", "hi10p", "aac", "ac3", "eac3", "ddp", "dd",
    "dts", "dtshd", "dtsx", "truehd", "atmos", "flac", "opus", "lpcm", "mp3",
    "proper", "repack", "rerip", "multi", "dual", "audio", "sub", "subs",
    "subtitle", "subtitles", "forced", "force", "default", "sdh", "hi", "cc",
    "bilingual", "mkv", "mp4", "avi", "srt", "ass", "ssa", "vtt",
    "the", "and", "of", "in", "on", "to", "for", "with", "at", "by", "from",
]

private let sidecarVideoNoise: Set<String> = [
    "web", "dl", "webdl", "webrip", "webhd", "bluray", "bdrip", "brrip",
    "bdremux", "remux", "hdtv", "pdtv", "dvdrip", "dvd", "hdrip", "bd",
    "uhd", "fhd", "hdr", "hdr10", "hdr10plus", "dv", "dovi", "hlg", "sdr",
    "imax", "x264", "x265", "h264", "h265", "hevc", "avc", "av1", "xvid",
    "divx", "10bit", "8bit", "hi10p", "proper", "repack", "rerip",
    "mkv", "mp4", "avi",
]

private let langPartSepSet = CharacterSet(charactersIn: "&+/,")
private let remSepSet = CharacterSet(charactersIn: ". \t\n\r[]()（）【】")
private let dashUnderscoreSet = CharacterSet(charactersIn: "-_")

/// Pre-indexed video collection for fast repeated follower matching.
///
/// Eliminates O(S*V*L) rescanning by indexing stems, episode numbers,
/// directories, and lazily memoizing meaningful token sets per video.
public final class VideoMatchIndex: Sendable {
    private let byStemLower: [String: [IndexedVideo]]
    private let byEpisode: [Int: [IndexedVideo]]
    private let byDir: [String: [IndexedVideo]]

    public init<S: Sequence>(_ videos: S) where S.Element == ScanFile {
        var stemMap: [String: [IndexedVideo]] = [:]
        var epMap: [Int: [IndexedVideo]] = [:]
        var dirMap: [String: [IndexedVideo]] = [:]
        for v in videos {
            let iv = IndexedVideo(v)
            if !iv.stemLower.isEmpty {
                stemMap[iv.stemLower, default: []].append(iv)
            }
            if let ep = iv.episode {
                epMap[ep, default: []].append(iv)
            }
            dirMap[iv.dir, default: []].append(iv)
        }
        self.byStemLower = stemMap
        self.byEpisode = epMap
        self.byDir = dirMap
    }

    /// Finds the video `f` belongs to:
    /// 1. Longest base-name prefix (same folder wins ties),
    /// 2. Same episode number (preserving differentiating remainder and avoiding ambiguous ties),
    /// 3. Safe fuzzy fallback for subtitles in the same folder (single video in folder or
    ///    unambiguous meaningful-token overlap, never cross-matching conflicting episodes/years).
    public func match(_ f: ScanFile) -> FollowMatch? {
        let fb = stem(f.name)
        let fbl = fb.lowercased()
        let fdir = dirOf(f.path)

        // Step 1: longest base-name prefix lookup via delimiter positions (O(L)).
        if !fbl.isEmpty {
            if let exact = byStemLower[fbl] {
                let picked = Self.preferSameDir(exact, fdir: fdir)
                return FollowMatch(picked.file, "")
            }
            var idx = fbl.endIndex
            while idx > fbl.startIndex {
                idx = fbl.index(before: idx)
                if idx == fbl.startIndex { break }
                if !isAfterBaseDelimiter(fbl[idx]) { continue }
                let prefixKey = String(fbl[..<idx])
                if let hits = byStemLower[prefixKey] {
                    let picked = Self.preferSameDir(hits, fdir: fdir)
                    let rem = Self.originalRemainder(fb: fb, fbl: fbl, matchIndex: idx, prefixKey: prefixKey)
                    return FollowMatch(picked.file, rem)
                }
            }
        }

        // Step 2: same episode number (O(1) lookup by episode number).
        if let pf = f.parsed, let n = pf.episodes.first ?? pf.absolute {
            if let epHits = byEpisode[n] {
                let cands = epHits.filter { v in
                    pf.season == nil || v.season == nil || pf.season == v.season
                }
                if !cands.isEmpty {
                    let same = cands.filter { $0.dir == fdir }
                    let pool = same.isEmpty ? cands : same
                    if let picked = Self.pickUnambiguousEpCandidate(pool, pf: pf) {
                        let rem = f.role == .subtitle
                            ? extractSubRemainder(fb, picked.stemName)
                            : extractSidecarRemainder(fb, picked.stemName)
                        return FollowMatch(picked.file, rem)
                    }
                    return nil
                }
            }
        }

        // Step 3: safe fuzzy fallback for third-party subtitles in the same folder.
        guard f.role == .subtitle else { return nil }
        guard let sameDirVideos = byDir[fdir], !sameDirVideos.isEmpty else { return nil }

        if sameDirVideos.count == 1 {
            let v = sameDirVideos[0]
            if episodesConflictKeys(episodeKey(f), v.epKey) || yearsConflict(extractYear(f), v.year) {
                return nil
            }
            return FollowMatch(v.file, extractSubRemainder(fb, v.stemName))
        }

        // Multiple videos in the same folder: require unambiguous meaningful token overlap.
        let fTokens = meaningfulTokens(fb)
        if fTokens.isEmpty { return nil }

        var topVideo: IndexedVideo?
        var topScore = 0.0
        var topShared = 0
        var secondScore = 0.0
        let fEpKey = episodeKey(f)

        for v in sameDirVideos {
            if episodesConflictKeys(fEpKey, v.epKey) { continue }
            let vTokens = v.tokens
            if vTokens.isEmpty { continue }
            let shared = fTokens.intersection(vTokens)
            if shared.isEmpty { continue }
            // Never match solely on a shared year/number.
            if !shared.contains(where: { !matchesRegex(FollowRegex.digitsOnly, $0) }) { continue }
            let unionLen = fTokens.count + vTokens.count - shared.count
            let score = unionLen == 0 ? 0.0 : Double(shared.count) / Double(unionLen)
            let qualified = (shared.count >= 2 && score >= 0.35)
                || (shared.count == 1 && (shared.first?.count ?? 0) >= 4 && score >= 0.5)
            if !qualified { continue }

            if score > topScore || (score == topScore && shared.count > topShared) {
                secondScore = topScore
                topScore = score
                topShared = shared.count
                topVideo = v
            } else if score > secondScore {
                secondScore = score
            }
        }

        guard let topVideo else { return nil }
        if secondScore > 0 && topScore - secondScore < 0.2 { return nil }
        return FollowMatch(topVideo.file, extractSubRemainder(fb, topVideo.stemName))
    }

    private static func originalRemainder(
        fb: String,
        fbl: String,
        matchIndex idx: String.Index,
        prefixKey: String
    ) -> String {
        let suffixLen = fbl.distance(from: idx, to: fbl.endIndex)
        if let oIdx = fb.index(fb.endIndex, offsetBy: -suffixLen, limitedBy: fb.startIndex),
           fb[oIdx...].lowercased() == fbl[idx...] {
            return String(fb[oIdx...])
        }
        var oi = fb.endIndex
        while oi > fb.startIndex {
            oi = fb.index(before: oi)
            if oi == fb.startIndex { break }
            if isAfterBaseDelimiter(fb[oi]) && String(fb[..<oi]).lowercased() == prefixKey {
                return String(fb[oi...])
            }
        }
        return String(fbl[idx...])
    }

    private static func preferSameDir(_ hits: [IndexedVideo], fdir: String) -> IndexedVideo {
        for v in hits where v.dir == fdir {
            return v
        }
        return hits[0]
    }

    private static func pickUnambiguousEpCandidate(_ pool: [IndexedVideo], pf: ParsedName) -> IndexedVideo? {
        if pool.count == 1 { return pool[0] }
        if pf.season == nil {
            let regular = pool.filter { $0.season != 0 && $0.file.parsed?.kind != .special }
            if regular.count == 1 { return regular[0] }
        }
        return nil
    }
}

/// Convenience helper matching a single follower against `videos`.
public func matchVideo(_ f: ScanFile, _ videos: [ScanFile]) -> FollowMatch? {
    VideoMatchIndex(videos).match(f)
}

/// Returns true when `sub` carries an episode/season or year that conflicts with `video`.
public func followConflicts(_ sub: ScanFile, _ video: ScanFile) -> Bool {
    episodesConflictKeys(episodeKey(sub), episodeKey(video))
        || yearsConflict(extractYear(sub), extractYear(video))
}

/// First known language among the dot / underscore / hyphen separated tokens of `remainder`.
public func langFromRemainder(_ remainder: String) -> String? {
    for chunk in remainder.components(separatedBy: remSepSet) where !chunk.isEmpty {
        for raw in chunk.components(separatedBy: langPartSepSet) {
            let t = raw.trimmingCharacters(in: dashUnderscoreSet).trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if let direct = followNormalizeLang(t) {
                return direct
            }
            if t.contains("-") || t.contains("_") {
                let parts = t.lowercased()
                    .components(separatedBy: dashUnderscoreSet)
                    .filter { !$0.isEmpty }
                var i = 0
                while i < parts.count {
                    if i + 1 < parts.count {
                        if let pair = singleFollowLang("\(parts[i])-\(parts[i + 1])") {
                            return pair
                        }
                    }
                    if let single = singleFollowLang(parts[i]) {
                        return single
                    }
                    i += 1
                }
            }
        }
    }
    return nil
}

/// Extracts language and subtitle-flag tokens from a third-party subtitle stem `subStem`
/// matched fuzzily (or by episode) to `videoStem`, returning a dot-prefixed remainder
/// (or `""` if none are present). Ambiguous title words (`force`, `hi`, `cc`, `dual`)
/// that also appear in `videoStem` are skipped.
public func extractSubRemainder(_ subStem: String, _ videoStem: String) -> String {
    let videoWords = Set(splitByRegex(FollowRegex.fuzzySplit, videoStem.lowercased()).filter { !$0.isEmpty })
    var kept: [String] = []
    let chunks = subStem.components(separatedBy: remSepSet).filter { !$0.isEmpty }

    for ci in 0..<chunks.count {
        let chunk = chunks[ci]
        let nextLower: String? = (ci + 1 < chunks.count) ? chunks[ci + 1].lowercased() : nil
        let subParts = chunk.components(separatedBy: langPartSepSet)
        var chunkKept: [String] = []

        for raw in subParts {
            let seg = raw.trimmingCharacters(in: dashUnderscoreSet).trimmingCharacters(in: .whitespacesAndNewlines)
            if seg.isEmpty { continue }
            if matchesRegex(FollowRegex.cjkBilingual, seg)
                || matchesRegex(FollowRegex.cjkSdh, seg)
                || matchesRegex(FollowRegex.cjkForced, seg)
                || matchesRegex(FollowRegex.cjkDefault, seg)
                || followNormalizeLang(seg) != nil {
                chunkKept.append(seg)
                continue
            }

            let parts = seg.components(separatedBy: dashUnderscoreSet).filter { !$0.isEmpty }
            var keptParts: [String] = []
            var i = 0
            while i < parts.count {
                let low = parts[i].lowercased()
                if i + 1 < parts.count {
                    let pair = "\(low)-\(parts[i + 1].lowercased())"
                    if singleFollowLang(pair) != nil {
                        keptParts.append("\(parts[i])_\(parts[i + 1])")
                        i += 2
                        continue
                    }
                }
                let isAudioDual = low == "dual"
                    && ((i + 1 < parts.count && parts[i + 1].lowercased() == "audio")
                        || (i + 1 == parts.count && nextLower == "audio"))
                if isAudioDual {
                    i += 1
                    continue
                }
                if ambiguousFlagWords.contains(low) && videoWords.contains(low) {
                    i += 1
                    continue
                }
                if singleFollowLang(low) != nil
                    || low == "forced"
                    || low == "force"
                    || low == "default"
                    || low == "sdh"
                    || low == "hi"
                    || low == "cc"
                    || low == "dual"
                    || bilingualFollowTokens.contains(low) {
                    keptParts.append(parts[i])
                }
                i += 1
            }
            if !keptParts.isEmpty {
                chunkKept.append(keptParts.joined(separator: "."))
            }
        }

        if !chunkKept.isEmpty {
            let joined = (subParts.count > 1 && chunkKept.count > 1)
                ? chunkKept.joined(separator: "&")
                : chunkKept.joined(separator: ".")
            kept.append(joined)
        }
    }

    return kept.isEmpty ? "" : ".\(kept.joined(separator: "."))"
}

// MARK: - Internal Language & Flag Superset Helpers

func singleFollowLang(_ normalizedLower: String) -> String? {
    if zhHansSet.contains(normalizedLower) { return "zh-Hans" }
    if zhHantSet.contains(normalizedLower) { return "zh-Hant" }
    if enSet.contains(normalizedLower) { return "en" }
    if jaSet.contains(normalizedLower) { return "ja" }
    if koSet.contains(normalizedLower) { return "ko" }
    return singleSubtitleLang(normalizedLower)
}

func followNormalizeLang(_ token: String) -> String? {
    for part in token.lowercased().components(separatedBy: langPartSepSet) {
        let t = part.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
        if let lang = singleFollowLang(t) {
            return lang
        }
    }
    return normalizeLang(token)
}

func followSubFlagsFromRemainder(_ remainder: String) -> [String] {
    let trimmed = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return [] }

    var bilingual = false
    var sdh = false
    var forced = false
    var isDefault = false
    var langs: Set<String> = []
    var flatTokens: [String] = []

    for chunk in remainder.components(separatedBy: remSepSet) where !chunk.isEmpty {
        for raw in chunk.components(separatedBy: langPartSepSet) {
            let seg = raw.trimmingCharacters(in: dashUnderscoreSet).trimmingCharacters(in: .whitespacesAndNewlines)
            if seg.isEmpty { continue }
            if matchesRegex(FollowRegex.cjkBilingual, seg) { bilingual = true }
            if matchesRegex(FollowRegex.cjkSdh, seg) { sdh = true }
            if matchesRegex(FollowRegex.cjkForced, seg) { forced = true }
            if matchesRegex(FollowRegex.cjkDefault, seg) { isDefault = true }

            let parts = seg.lowercased().components(separatedBy: dashUnderscoreSet).filter { !$0.isEmpty }
            var i = 0
            while i < parts.count {
                if i + 1 < parts.count {
                    let pair = "\(parts[i])-\(parts[i + 1])"
                    if let pairLang = singleFollowLang(pair) {
                        langs.insert(pairLang)
                        flatTokens.append(pair)
                        i += 2
                        continue
                    }
                }
                flatTokens.append(parts[i])
                i += 1
            }
        }
    }

    for i in 0..<flatTokens.count {
        let p = flatTokens[i]
        if p == "forced" || p == "force" {
            forced = true
        } else if p == "default" {
            isDefault = true
        } else if p == "sdh" || p == "hi" || p == "cc" {
            sdh = true
        } else if p == "dual" {
            let nextIsAudio = i + 1 < flatTokens.count && flatTokens[i + 1] == "audio"
            if !nextIsAudio { bilingual = true }
        } else if bilingualFollowTokens.contains(p) {
            bilingual = true
        }
        if let lang = singleFollowLang(p) {
            langs.insert(lang)
        }
    }

    var out: [String] = []
    if bilingual || langs.count >= 2 { out.append("bilingual") }
    if sdh { out.append("sdh") }
    if forced { out.append("forced") }
    if isDefault { out.append("default") }
    return out
}

// MARK: - Indexed Video & Private Match Helpers

private final class IndexedVideo: @unchecked Sendable {
    let file: ScanFile
    let stemName: String
    let stemLower: String
    let dir: String
    let episode: Int?
    let season: Int?

    private let lock = NSLock()
    private var cachedEpKey: (season: Int?, episode: Int?)?
    private var cachedYear: Int?
    private var yearComputed = false
    private var cachedTokens: Set<String>?

    init(_ file: ScanFile) {
        self.file = file
        let s = stem(file.name)
        self.stemName = s
        self.stemLower = s.lowercased()
        self.dir = dirOf(file.path)
        self.episode = file.parsed?.episodes.first ?? file.parsed?.absolute
        self.season = file.parsed?.season
    }

    var epKey: (season: Int?, episode: Int?) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = cachedEpKey { return existing }
        let computed = episodeKey(file)
        cachedEpKey = computed
        return computed
    }

    var year: Int? {
        lock.lock()
        defer { lock.unlock() }
        if !yearComputed {
            yearComputed = true
            cachedYear = extractYear(file)
        }
        return cachedYear
    }

    var tokens: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = cachedTokens { return existing }
        let computed = meaningfulTokens(stemName)
        cachedTokens = computed
        return computed
    }
}

func isAfterBaseDelimiter(_ c: Character) -> Bool {
    c == "." || c == "_" || c == "-" || c == "[" || c == "(" || c.isWhitespace
}

private func episodeKey(_ file: ScanFile) -> (season: Int?, episode: Int?) {
    let p = file.parsed
    if let ep = p?.episodes.first ?? p?.absolute {
        return (season: p?.season, episode: ep)
    }
    let s = stem(file.name)
    let full = NSRange(s.startIndex..<s.endIndex, in: s)
    if let m = FollowRegex.subSe.firstMatch(in: s, range: full),
       let r1 = Range(m.range(at: 1), in: s),
       let r2 = Range(m.range(at: 2), in: s),
       let sn = Int(s[r1]), let ep = Int(s[r2]) {
        return (season: sn, episode: ep)
    }
    if let m = FollowRegex.subX.firstMatch(in: s, range: full),
       let r1 = Range(m.range(at: 1), in: s),
       let r2 = Range(m.range(at: 2), in: s),
       let sn = Int(s[r1]), let ep = Int(s[r2]) {
        return (season: sn, episode: ep)
    }
    if let m = FollowRegex.subEp.firstMatch(in: s, range: full),
       let r1 = Range(m.range(at: 1), in: s),
       let ep = Int(s[r1]) {
        return (season: p?.season, episode: ep)
    }
    if let m = FollowRegex.subCnEp.firstMatch(in: s, range: full),
       let r1 = Range(m.range(at: 1), in: s),
       let ep = Int(s[r1]) {
        return (season: p?.season, episode: ep)
    }
    return (season: p?.season, episode: nil)
}

private func episodesConflictKeys(
    _ ks: (season: Int?, episode: Int?),
    _ kv: (season: Int?, episode: Int?)
) -> Bool {
    if let es = ks.episode, let ev = kv.episode, es != ev {
        return true
    }
    if ks.episode != nil && kv.episode == nil {
        return true
    }
    if let ss = ks.season, let sv = kv.season, ss != sv {
        return true
    }
    return false
}

private let utcGregorianCalendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    return cal
}()

private func extractYear(_ file: ScanFile) -> Int? {
    if let y = file.parsed?.year { return y }
    let s = stem(file.name)
    let full = NSRange(s.startIndex..<s.endIndex, in: s)
    let maxYear = utcGregorianCalendar.component(.year, from: Date()) + 2
    var year: Int?
    for m in FollowRegex.subYear.matches(in: s, range: full) {
        if m.range.location == 0 { continue }
        if let r1 = Range(m.range(at: 1), in: s), let y = Int(s[r1]), y <= maxYear {
            year = y
        }
    }
    return year
}

private func yearsConflict(_ ys: Int?, _ yv: Int?) -> Bool {
    guard let ys, let yv else { return false }
    return abs(ys - yv) > 1
}

private func extractSidecarRemainder(_ sidecarStem: String, _ videoStem: String) -> String {
    let full = NSRange(sidecarStem.startIndex..<sidecarStem.endIndex, in: sidecarStem)
    let m = FollowRegex.subSe.firstMatch(in: sidecarStem, range: full)
        ?? FollowRegex.subX.firstMatch(in: sidecarStem, range: full)
        ?? FollowRegex.subEp.firstMatch(in: sidecarStem, range: full)
        ?? FollowRegex.subCnEp.firstMatch(in: sidecarStem, range: full)

    if let m, let matchRange = Range(m.range, in: sidecarStem), matchRange.upperBound < sidecarStem.endIndex {
        let tail = String(sidecarStem[matchRange.upperBound...])
        let leadingDash = tail.hasPrefix("-")
        var tokens: [String] = []
        for chunk in tail.components(separatedBy: remSepSet) {
            let seg = chunk.trimmingCharacters(in: dashUnderscoreSet).trimmingCharacters(in: .whitespacesAndNewlines)
            if seg.isEmpty { continue }
            let low = seg.lowercased()
            if sidecarVideoNoise.contains(low) || matchesRegex(FollowRegex.resNoise, low) {
                continue
            }
            if seg.contains("-") && !seg.hasPrefix("-") && singleFollowLang(low) == nil {
                let parts = seg.split(separator: "-").map(String.init).filter { p in
                    let pl = p.lowercased()
                    return !p.isEmpty && !sidecarVideoNoise.contains(pl) && !matchesRegex(FollowRegex.resNoise, pl)
                }
                if !parts.isEmpty {
                    tokens.append(parts.joined(separator: "-"))
                }
            } else {
                tokens.append(seg)
            }
        }
        if !tokens.isEmpty {
            if leadingDash && tokens.count == 1 {
                return "-\(tokens[0])"
            }
            return ".\(tokens.joined(separator: "."))"
        }
    }
    return extractSubRemainder(sidecarStem, videoStem)
}

private func meaningfulTokens(_ rawStem: String) -> Set<String> {
    let folded = toSimplified(rawStem).lowercased()
    let full = NSRange(folded.startIndex..<folded.endIndex, in: folded)
    var out: Set<String> = []

    for m in FollowRegex.cjkRun.matches(in: folded, range: full) {
        guard let r = Range(m.range, in: folded) else { continue }
        let run = String(folded[r])
        if singleFollowLang(run) != nil
            || matchesRegex(FollowRegex.cjkBilingual, run)
            || matchesRegex(FollowRegex.cjkForced, run)
            || matchesRegex(FollowRegex.cjkDefault, run)
            || matchesRegex(FollowRegex.cjkSdh, run) {
            continue
        }
        let chars = Array(run)
        if chars.count == 1 {
            out.insert(String(chars[0]))
        } else {
            for i in 0..<(chars.count - 1) {
                out.insert(String([chars[i], chars[i + 1]]))
            }
        }
    }

    for m in FollowRegex.latinWord.matches(in: folded, range: full) {
        guard let r = Range(m.range, in: folded) else { continue }
        let w = String(folded[r])
        if w.count < 2 { continue }
        if fuzzyNoise.contains(w)
            || matchesRegex(FollowRegex.resNoise, w)
            || singleFollowLang(w) != nil
            || bilingualFollowTokens.contains(w) {
            continue
        }
        if matchesRegex(FollowRegex.digitsOnly, w) && w.count != 4 { continue }
        out.insert(w)
    }

    return out
}

private func matchesRegex(_ regex: NSRegularExpression, _ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.firstMatch(in: text, range: range) != nil
}

private func splitByRegex(_ regex: NSRegularExpression, _ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    let full = NSRange(text.startIndex..<text.endIndex, in: text)
    let matches = regex.matches(in: text, range: full)
    if matches.isEmpty { return [text] }
    var parts: [String] = []
    var cursor = text.startIndex
    for m in matches {
        guard let r = Range(m.range, in: text) else { continue }
        parts.append(String(text[cursor..<r.lowerBound]))
        cursor = r.upperBound
    }
    parts.append(String(text[cursor..<text.endIndex]))
    return parts
}
