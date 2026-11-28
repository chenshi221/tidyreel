import Foundation
import TidyreelModels

// MARK: - Parser Discovery & Lightweight Fallback

internal func extractFilenameParser(from recognizer: any Recognizer, depth: Int = 0) -> any FilenameParser {
    if depth <= 2 {
        for child in Mirror(reflecting: recognizer).children {
            if let parser = child.value as? any FilenameParser {
                return parser
            }
            if let nested = child.value as? any Recognizer {
                return extractFilenameParser(from: nested, depth: depth + 1)
            }
        }
    }
    return FallbackFilenameParser()
}

private let adKeywordRegex = try! NSRegularExpression(
    pattern: #"更多资源|更多精彩|更多电影|最新地址|最新网址|获取更多|公众号|扫码|发布页|永久地址|永久网址|免费下载|点击进入|关注微信"#
)
private let fallbackSeRegex = try! NSRegularExpression(
    pattern: #"(?<![A-Za-z0-9])S(\d{1,2})[\s._-]?E(\d{1,4})(?:[\s._-]*[-~][\s._-]*(?:S\d{1,2}[\s._-]?)?E?(\d{1,4}))?(?![A-Za-z0-9])"#,
    options: [.caseInsensitive]
)
private let fallbackXRegex = try! NSRegularExpression(
    pattern: #"(?<![A-Za-z0-9])(\d{1,2})x(\d{2,3})(?![A-Za-z0-9])"#,
    options: [.caseInsensitive]
)
private let fallbackEpRegex = try! NSRegularExpression(
    pattern: #"(?<![A-Za-z0-9])(?:EP|Episode[\s._-]?|E)(\d{1,4})(?![A-Za-z0-9])"#,
    options: [.caseInsensitive]
)
private let fallbackCnEpRegex = try! NSRegularExpression(pattern: #"第\s*(\d{1,4})\s*[集话話期回]"#)
private let fallbackSeasonDirRegex = try! NSRegularExpression(
    pattern: #"(?:^(?:season|series)[\s._-]*(\d{1,2})$|^s(\d{1,2})$|第\s*(\d{1,2})\s*季)"#,
    options: [.caseInsensitive]
)
private let fallbackYearRegex = try! NSRegularExpression(
    pattern: #"(?<![A-Za-z0-9\u3400-\u9fff])((?:19|20)\d\d)(?![A-Za-z0-9])"#
)
private let fallbackResRegex = try! NSRegularExpression(
    pattern: #"(?<![A-Za-z0-9])(2160p|1080p|720p|480p|4k)(?![A-Za-z0-9])"#,
    options: [.caseInsensitive]
)

private let fallbackTitleTrimChars = CharacterSet(charactersIn: " -[]()（）【】")
private let followerRemSep = CharacterSet(charactersIn: ". \t\n[]()（）【】")
private let followerPartSep = CharacterSet(charactersIn: "&+/,")
private let followerEdgeDash = CharacterSet(charactersIn: "-_")
private let utcCalendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    return cal
}()

internal struct FallbackFilenameParser: FilenameParser, Sendable {
    func classify(_ fileName: String) -> FileRole {
        let base = baseOf(fileName)
        let ext = extOf(base).lowercased()
        if videoExtensions.contains(ext) { return .video }
        if subtitleExtensions.contains(ext) { return .subtitle }
        let rBase = NSRange(base.startIndex..<base.endIndex, in: base)
        if adKeywordRegex.firstMatch(in: base, range: rBase) != nil { return .junk }
        if sidecarExtensions.contains(ext) { return .sidecar }
        if junkExtensions.contains(ext) { return .junk }
        return .other
    }

    func parse(_ fileName: String, parentDirs: [String]) -> ParsedName {
        let base = baseOf(fileName)
        let rawStem = stem(base)
        let nsStem = NSRange(rawStem.startIndex..<rawStem.endIndex, in: rawStem)

        var season: Int?
        var episodes: [Int] = []
        var cutIndex = rawStem.endIndex

        if let m = fallbackSeRegex.firstMatch(in: rawStem, range: nsStem) {
            if let r1 = Range(m.range(at: 1), in: rawStem) { season = Int(rawStem[r1]) }
            if let r2 = Range(m.range(at: 2), in: rawStem), let e1 = Int(rawStem[r2]) {
                if m.range(at: 3).location != NSNotFound,
                   let r3 = Range(m.range(at: 3), in: rawStem),
                   let e2 = Int(rawStem[r3]),
                   e2 >= e1 && e2 - e1 <= 20
                {
                    episodes = Array(e1...e2)
                } else {
                    episodes = [e1]
                }
            }
            if let full = Range(m.range, in: rawStem), full.lowerBound < cutIndex {
                cutIndex = full.lowerBound
            }
        } else if let m = fallbackXRegex.firstMatch(in: rawStem, range: nsStem) {
            if let r1 = Range(m.range(at: 1), in: rawStem) { season = Int(rawStem[r1]) }
            if let r2 = Range(m.range(at: 2), in: rawStem), let ep = Int(rawStem[r2]) { episodes = [ep] }
            if let full = Range(m.range, in: rawStem), full.lowerBound < cutIndex {
                cutIndex = full.lowerBound
            }
        } else if let m = fallbackEpRegex.firstMatch(in: rawStem, range: nsStem) {
            if let r1 = Range(m.range(at: 1), in: rawStem), let ep = Int(rawStem[r1]) { episodes = [ep] }
            if let full = Range(m.range, in: rawStem), full.lowerBound < cutIndex {
                cutIndex = full.lowerBound
            }
        } else if let m = fallbackCnEpRegex.firstMatch(in: rawStem, range: nsStem) {
            if let r1 = Range(m.range(at: 1), in: rawStem), let ep = Int(rawStem[r1]) { episodes = [ep] }
            if let full = Range(m.range, in: rawStem), full.lowerBound < cutIndex {
                cutIndex = full.lowerBound
            }
        }

        var year: Int?
        for m in fallbackYearRegex.matches(in: rawStem, range: nsStem) {
            guard let full = Range(m.range, in: rawStem), full.lowerBound > rawStem.startIndex,
                  let ry = Range(m.range(at: 1), in: rawStem), let y = Int(rawStem[ry])
            else { continue }
            year = y
            if full.lowerBound < cutIndex { cutIndex = full.lowerBound }
        }

        var dTitle: String?
        var dYear: Int?
        var dSeason: Int?
        for dir in parentDirs {
            let trimmed = dir.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || isGenericContainerDir(trimmed) { continue }
            let rDir = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let sm = fallbackSeasonDirRegex.firstMatch(in: trimmed, range: rDir) {
                for g in 1...3 where sm.range(at: g).location != NSNotFound {
                    if let rg = Range(sm.range(at: g), in: trimmed), let sn = Int(trimmed[rg]) {
                        dSeason = dSeason ?? sn
                    }
                }
                continue
            }
            if dTitle == nil {
                var dirCut = trimmed.endIndex
                for m in fallbackYearRegex.matches(in: trimmed, range: rDir) {
                    if let full = Range(m.range, in: trimmed), full.lowerBound > trimmed.startIndex,
                       let ry = Range(m.range(at: 1), in: trimmed), let y = Int(trimmed[ry])
                    {
                        dYear = dYear ?? y
                        if full.lowerBound < dirCut { dirCut = full.lowerBound }
                    }
                }
                let cleanedDir = String(trimmed[..<dirCut])
                    .replacingOccurrences(of: ".", with: " ")
                    .replacingOccurrences(of: "_", with: " ")
                    .trimmingCharacters(in: fallbackTitleTrimChars)
                if !cleanedDir.isEmpty { dTitle = cleanedDir }
            }
        }

        season = season ?? dSeason
        year = year ?? dYear

        let rawTitlePart = String(rawStem[..<cutIndex])
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: fallbackTitleTrimChars)
        let finalTitle = !rawTitlePart.isEmpty ? rawTitlePart : dTitle

        var resolution: String?
        if let rm = fallbackResRegex.firstMatch(in: rawStem, range: nsStem),
           let rr = Range(rm.range(at: 1), in: rawStem)
        {
            let tok = rawStem[rr].lowercased()
            resolution = tok == "4k" ? "2160p" : tok
        }

        let role = classify(base)
        let lang = role == .subtitle ? langFromSubtitleRemainder(rawStem) : nil
        let subFlags = role == .subtitle ? subFlagsFromRemainder(rawStem) : []

        let kind: MediaKind
        if season == 0 {
            kind = .special
        } else if !episodes.isEmpty || season != nil {
            kind = .episode
        } else if year != nil || finalTitle != nil {
            kind = .movie
        } else {
            kind = .unknown
        }

        return ParsedName(
            title: finalTitle,
            year: year,
            season: season,
            episodes: episodes,
            kind: kind,
            resolution: resolution,
            lang: lang,
            confidence: finalTitle != nil || !episodes.isEmpty ? 0.8 : 0.3,
            subFlags: subFlags
        )
    }
}

// MARK: - Subtitle & Sidecar Follower Matching (Port of follow.dart)

internal struct FollowMatch: Sendable {
    let video: ScanFile
    let remainder: String
}

private let afterBaseChars: Set<Character> = [" ", ".", "_", "-", "[", "("]
private let digitsOnlyRegex = try! NSRegularExpression(pattern: #"^\d+$"#)
private let resNoiseRegex = try! NSRegularExpression(pattern: #"^(?:\d{3,4}[pi]|\d{3,4}x\d{3,4}|[248]k)$"#)
private let cjkBilingualRegex = try! NSRegularExpression(pattern: #"双语|雙語|中英|简英|繁英|簡英|简日|繁日|簡日|简繁|簡繁"#)
private let cjkSdhRegex = try! NSRegularExpression(pattern: #"听障|聽障"#)
private let cjkForcedRegex = try! NSRegularExpression(pattern: #"强制|強制"#)
private let cjkDefaultRegex = try! NSRegularExpression(pattern: #"默认|默認"#)
private let cjkRunRegex = try! NSRegularExpression(pattern: #"[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]+"#)
private let latinWordRegex = try! NSRegularExpression(pattern: #"[a-z0-9]+"#)
private let fuzzySplitRegex = try! NSRegularExpression(pattern: #"[^\p{L}\p{N}]+"#)

private let bilingualExtraTokens: Set<String> = [
    "bilingual", "jpsc", "jptc", "scjp", "tcjp", "chseng", "chteng", "sceng", "tceng", "chsjp", "chtjp",
]
private let ambiguousFlagWords: Set<String> = ["force", "hi", "cc", "dual"]
private let sidecarVideoNoise: Set<String> = [
    "web", "dl", "webdl", "webrip", "webhd", "bluray", "bdrip", "brrip", "bdremux", "remux",
    "hdtv", "pdtv", "dvdrip", "dvd", "hdrip", "bd", "uhd", "fhd", "hdr", "hdr10", "hdr10plus",
    "dv", "dovi", "hlg", "sdr", "imax", "x264", "x265", "h264", "h265", "hevc", "avc", "av1",
    "xvid", "divx", "10bit", "8bit", "hi10p", "proper", "repack", "rerip", "mkv", "mp4", "avi",
]
private let fuzzyNoise: Set<String> = sidecarVideoNoise.union([
    "aac", "ac3", "eac3", "ddp", "dd", "dts", "dtshd", "dtsx", "truehd", "atmos", "flac",
    "opus", "lpcm", "mp3", "multi", "dual", "audio", "sub", "subs", "subtitle", "subtitles",
    "forced", "force", "default", "sdh", "hi", "cc", "bilingual", "srt", "ass", "ssa", "vtt",
    "the", "and", "of", "in", "on", "to", "for", "with", "at", "by", "from",
])

private func matchesFull(_ regex: NSRegularExpression, _ s: String) -> Bool {
    let r = NSRange(s.startIndex..<s.endIndex, in: s)
    return regex.firstMatch(in: s, range: r) != nil
}

private func langFromSubtitleRemainder(_ remainder: String) -> String? {
    for chunk in remainder.components(separatedBy: followerRemSep) where !chunk.isEmpty {
        for raw in chunk.components(separatedBy: followerPartSep) {
            let t = raw.trimmingCharacters(in: followerEdgeDash).trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if let direct = normalizeLang(t) { return direct }
            if t.contains("-") || t.contains("_") {
                let parts = t.lowercased().components(separatedBy: followerEdgeDash).filter { !$0.isEmpty }
                for i in 0..<parts.count {
                    if i + 1 < parts.count, let pair = singleSubtitleLang("\(parts[i])-\(parts[i + 1])") {
                        return pair
                    }
                    if let single = singleSubtitleLang(parts[i]) {
                        return single
                    }
                }
            }
        }
    }
    return nil
}

internal func extractSubRemainder(_ subStem: String, _ videoStem: String) -> String {
    let lowerVideo = videoStem.lowercased()
    let rVideo = NSRange(lowerVideo.startIndex..<lowerVideo.endIndex, in: lowerVideo)
    let splitVideo = fuzzySplitRegex.stringByReplacingMatches(in: lowerVideo, range: rVideo, withTemplate: " ")
    let videoWords = Set(splitVideo.split(separator: " ").map(String.init))

    let chunks = subStem.components(separatedBy: followerRemSep).filter { !$0.isEmpty }
    var kept: [String] = []

    for ci in 0..<chunks.count {
        let chunk = chunks[ci]
        let nextLower = ci + 1 < chunks.count ? chunks[ci + 1].lowercased() : nil
        let subParts = chunk.components(separatedBy: followerPartSep)
        var chunkKept: [String] = []

        for raw in subParts {
            let seg = raw.trimmingCharacters(in: followerEdgeDash).trimmingCharacters(in: .whitespacesAndNewlines)
            if seg.isEmpty { continue }
            if matchesFull(cjkBilingualRegex, seg) ||
                matchesFull(cjkSdhRegex, seg) ||
                matchesFull(cjkForcedRegex, seg) ||
                matchesFull(cjkDefaultRegex, seg) ||
                normalizeLang(seg) != nil
            {
                chunkKept.append(seg)
                continue
            }
            let parts = seg.components(separatedBy: followerEdgeDash).filter { !$0.isEmpty }
            var keptParts: [String] = []
            var i = 0
            while i < parts.count {
                let low = parts[i].lowercased()
                if i + 1 < parts.count {
                    let pair = "\(low)-\(parts[i + 1].lowercased())"
                    if singleSubtitleLang(pair) != nil {
                        keptParts.append("\(parts[i])_\(parts[i + 1])")
                        i += 2
                        continue
                    }
                }
                let isAudioDual = low == "dual" && (
                    (i + 1 < parts.count && parts[i + 1].lowercased() == "audio") ||
                    (i + 1 == parts.count && nextLower == "audio")
                )
                if isAudioDual {
                    i += 1
                    continue
                }
                if ambiguousFlagWords.contains(low) && videoWords.contains(low) {
                    i += 1
                    continue
                }
                if singleSubtitleLang(low) != nil ||
                    low == "forced" || low == "force" || low == "default" ||
                    low == "sdh" || low == "hi" || low == "cc" || low == "dual" ||
                    bilingualExtraTokens.contains(low)
                {
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

private func extractSidecarRemainder(_ sidecarStem: String, _ videoStem: String) -> String {
    let ns = NSRange(sidecarStem.startIndex..<sidecarStem.endIndex, in: sidecarStem)
    let match = fallbackSeRegex.firstMatch(in: sidecarStem, range: ns)
        ?? fallbackXRegex.firstMatch(in: sidecarStem, range: ns)
        ?? fallbackEpRegex.firstMatch(in: sidecarStem, range: ns)
        ?? fallbackCnEpRegex.firstMatch(in: sidecarStem, range: ns)

    if let m = match, let r = Range(m.range, in: sidecarStem), r.upperBound < sidecarStem.endIndex {
        let tail = String(sidecarStem[r.upperBound...])
        let leadingDash = tail.hasPrefix("-")
        var tokens: [String] = []
        for chunk in tail.components(separatedBy: followerRemSep) {
            let seg = chunk.trimmingCharacters(in: followerEdgeDash).trimmingCharacters(in: .whitespacesAndNewlines)
            if seg.isEmpty { continue }
            let low = seg.lowercased()
            if sidecarVideoNoise.contains(low) || matchesFull(resNoiseRegex, low) { continue }
            if seg.contains("-") && !seg.hasPrefix("-") && singleSubtitleLang(low) == nil {
                let parts = seg.split(separator: "-").map(String.init).filter { p in
                    let pl = p.lowercased()
                    return !p.isEmpty && !sidecarVideoNoise.contains(pl) && !matchesFull(resNoiseRegex, pl)
                }
                if !parts.isEmpty { tokens.append(parts.joined(separator: "-")) }
            } else {
                tokens.append(seg)
            }
        }
        if !tokens.isEmpty {
            if leadingDash && tokens.count == 1 { return "-\(tokens[0])" }
            return ".\(tokens.joined(separator: "."))"
        }
    }
    return extractSubRemainder(sidecarStem, videoStem)
}

private func episodeKey(_ file: ScanFile) -> (season: Int?, episode: Int?) {
    let p = file.parsed
    if let ep = p?.episodes.first ?? p?.absolute {
        return (p?.season, ep)
    }
    let s = stem(file.name)
    let ns = NSRange(s.startIndex..<s.endIndex, in: s)
    if let m = fallbackSeRegex.firstMatch(in: s, range: ns),
       let r1 = Range(m.range(at: 1), in: s),
       let r2 = Range(m.range(at: 2), in: s),
       let sn = Int(s[r1]), let ep = Int(s[r2])
    {
        return (sn, ep)
    }
    if let m = fallbackXRegex.firstMatch(in: s, range: ns),
       let r1 = Range(m.range(at: 1), in: s),
       let r2 = Range(m.range(at: 2), in: s),
       let sn = Int(s[r1]), let ep = Int(s[r2])
    {
        return (sn, ep)
    }
    if let m = fallbackEpRegex.firstMatch(in: s, range: ns),
       let r1 = Range(m.range(at: 1), in: s),
       let ep = Int(s[r1])
    {
        return (p?.season, ep)
    }
    if let m = fallbackCnEpRegex.firstMatch(in: s, range: ns),
       let r1 = Range(m.range(at: 1), in: s),
       let ep = Int(s[r1])
    {
        return (p?.season, ep)
    }
    return (p?.season, nil)
}

private func episodesConflictKeys(
    _ ks: (season: Int?, episode: Int?),
    _ kv: (season: Int?, episode: Int?)
) -> Bool {
    if let se = ks.episode, let ve = kv.episode, se != ve { return true }
    if ks.episode != nil && kv.episode == nil { return true }
    if let ss = ks.season, let vs = kv.season, ss != vs { return true }
    return false
}

private func extractYear(_ file: ScanFile) -> Int? {
    if let y = file.parsed?.year { return y }
    let s = stem(file.name)
    let ns = NSRange(s.startIndex..<s.endIndex, in: s)
    let maxYear = utcCalendar.component(.year, from: Date()) + 2
    var year: Int?
    for m in fallbackYearRegex.matches(in: s, range: ns) {
        guard let full = Range(m.range, in: s), full.lowerBound > s.startIndex,
              let ry = Range(m.range(at: 1), in: s), let y = Int(s[ry])
        else { continue }
        if y <= maxYear { year = y }
    }
    return year
}

internal func followConflicts(_ sub: ScanFile, _ video: ScanFile) -> Bool {
    if episodesConflictKeys(episodeKey(sub), episodeKey(video)) { return true }
    if let ys = extractYear(sub), let yv = extractYear(video), abs(ys - yv) > 1 { return true }
    return false
}

private func meaningfulTokens(_ rawStem: String) -> Set<String> {
    let folded = toSimplified(rawStem).lowercased()
    let ns = NSRange(folded.startIndex..<folded.endIndex, in: folded)
    var out: Set<String> = []

    for m in cjkRunRegex.matches(in: folded, range: ns) {
        guard let r = Range(m.range, in: folded) else { continue }
        let run = String(folded[r])
        if singleSubtitleLang(run) != nil ||
            matchesFull(cjkBilingualRegex, run) ||
            matchesFull(cjkForcedRegex, run) ||
            matchesFull(cjkDefaultRegex, run) ||
            matchesFull(cjkSdhRegex, run)
        {
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

    for m in latinWordRegex.matches(in: folded, range: ns) {
        guard let r = Range(m.range, in: folded) else { continue }
        let w = String(folded[r])
        if w.count < 2 { continue }
        if fuzzyNoise.contains(w) ||
            matchesFull(resNoiseRegex, w) ||
            singleSubtitleLang(w) != nil ||
            bilingualExtraTokens.contains(w)
        {
            continue
        }
        if matchesFull(digitsOnlyRegex, w) && w.count != 4 { continue }
        out.insert(w)
    }
    return out
}

internal struct VideoMatchIndex: Sendable {
    private final class IndexedVideo: @unchecked Sendable {
        let file: ScanFile
        let stemName: String
        let stemLower: String
        let dir: String
        let episode: Int?
        let season: Int?

        private let lock = NSLock()
        private var cachedEpKey: (season: Int?, episode: Int?)?
        private var computedYear = false
        private var cachedYear: Int?
        private var cachedTokens: Set<String>?

        init(_ file: ScanFile) {
            self.file = file
            let sn = stem(file.name)
            self.stemName = sn
            self.stemLower = sn.lowercased()
            self.dir = dirOf(file.path)
            self.episode = file.parsed?.episodes.first ?? file.parsed?.absolute
            self.season = file.parsed?.season
        }

        var epKey: (season: Int?, episode: Int?) {
            lock.withLock {
                if let cachedEpKey { return cachedEpKey }
                let val = episodeKey(file)
                cachedEpKey = val
                return val
            }
        }

        var year: Int? {
            lock.withLock {
                if computedYear { return cachedYear }
                let val = extractYear(file)
                cachedYear = val
                computedYear = true
                return val
            }
        }

        var tokens: Set<String> {
            lock.withLock {
                if let cachedTokens { return cachedTokens }
                let val = meaningfulTokens(stemName)
                cachedTokens = val
                return val
            }
        }
    }

    private let byStemLower: [String: [IndexedVideo]]
    private let byEpisode: [Int: [IndexedVideo]]
    private let byDir: [String: [IndexedVideo]]

    init(_ videos: [ScanFile]) {
        var stems: [String: [IndexedVideo]] = [:]
        var eps: [Int: [IndexedVideo]] = [:]
        var dirs: [String: [IndexedVideo]] = [:]
        for v in videos {
            let iv = IndexedVideo(v)
            if !iv.stemLower.isEmpty {
                stems[iv.stemLower, default: []].append(iv)
            }
            if let ep = iv.episode {
                eps[ep, default: []].append(iv)
            }
            dirs[iv.dir, default: []].append(iv)
        }
        self.byStemLower = stems
        self.byEpisode = eps
        self.byDir = dirs
    }

    func match(_ f: ScanFile) -> FollowMatch? {
        let fb = stem(f.name)
        let fbl = fb.lowercased()
        let fdir = dirOf(f.path)

        // Step 1: longest base-name prefix
        if !fbl.isEmpty {
            if let exact = byStemLower[fbl] {
                let picked = Self.preferSameDir(exact, fdir)
                return FollowMatch(video: picked.file, remainder: "")
            }
            let fbChars = Array(fb)
            let fblChars = Array(fbl)
            if fblChars.count == fbChars.count && fblChars.count > 1 {
                for i in stride(from: fblChars.count - 1, through: 1, by: -1) {
                    if !afterBaseChars.contains(fblChars[i]) { continue }
                    let prefixKey = String(fblChars[0..<i])
                    if let hits = byStemLower[prefixKey] {
                        let picked = Self.preferSameDir(hits, fdir)
                        let rem = String(fbChars[i...])
                        return FollowMatch(video: picked.file, remainder: rem)
                    }
                }
            }
        }

        // Step 2: same episode number
        if let pf = f.parsed, let n = pf.episodes.first ?? pf.absolute, let epHits = byEpisode[n] {
            let cands = epHits.filter { v in
                pf.season == nil || v.season == nil || pf.season == v.season
            }
            if !cands.isEmpty {
                let same = cands.filter { $0.dir == fdir }
                let pool = same.isEmpty ? cands : same
                if let picked = Self.pickUnambiguousEpCandidate(pool, pf) {
                    let rem = f.role == .subtitle
                        ? extractSubRemainder(fb, picked.stemName)
                        : extractSidecarRemainder(fb, picked.stemName)
                    return FollowMatch(video: picked.file, remainder: rem)
                }
                return nil
            }
        }

        // Step 3: safe fuzzy fallback for subtitles in the same folder
        guard f.role == .subtitle, let sameDirVideos = byDir[fdir], !sameDirVideos.isEmpty else {
            return nil
        }
        let subEpKey = episodeKey(f)
        let subYear = extractYear(f)

        if sameDirVideos.count == 1 {
            let v = sameDirVideos[0]
            if episodesConflictKeys(subEpKey, v.epKey) { return nil }
            if let sy = subYear, let vy = v.year, abs(sy - vy) > 1 { return nil }
            return FollowMatch(video: v.file, remainder: extractSubRemainder(fb, v.stemName))
        }

        let fTokens = meaningfulTokens(fb)
        if fTokens.isEmpty { return nil }
        var topVideo: IndexedVideo?
        var topScore = 0.0
        var topShared = 0
        var secondScore = 0.0

        for v in sameDirVideos {
            if episodesConflictKeys(subEpKey, v.epKey) { continue }
            if v.tokens.isEmpty { continue }
            let shared = fTokens.intersection(v.tokens)
            if shared.isEmpty { continue }
            if !shared.contains(where: { !matchesFull(digitsOnlyRegex, $0) }) { continue }
            let unionLen = fTokens.count + v.tokens.count - shared.count
            let score = unionLen == 0 ? 0.0 : Double(shared.count) / Double(unionLen)
            let qualified = (shared.count >= 2 && score >= 0.35) ||
                (shared.count == 1 && (shared.first?.count ?? 0) >= 4 && score >= 0.5)
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

        guard let best = topVideo else { return nil }
        if secondScore > 0 && topScore - secondScore < 0.2 { return nil }
        return FollowMatch(video: best.file, remainder: extractSubRemainder(fb, best.stemName))
    }

    private static func preferSameDir(_ hits: [IndexedVideo], _ fdir: String) -> IndexedVideo {
        hits.first { $0.dir == fdir } ?? hits[0]
    }

    private static func pickUnambiguousEpCandidate(_ pool: [IndexedVideo], _ pf: ParsedName) -> IndexedVideo? {
        if pool.count == 1 { return pool[0] }
        if pf.season == nil {
            let regular = pool.filter { $0.season != 0 && $0.file.parsed?.kind != .special }
            if regular.count == 1 { return regular[0] }
        }
        return nil
    }
}
