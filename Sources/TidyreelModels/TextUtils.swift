import CoreFoundation
import Foundation

// MARK: - Extensions & Generic Folder Patterns

public let videoExtensions: Set<String> = [
    "mkv", "mp4", "avi", "ts", "m2ts", "mts", "rmvb", "rm", "wmv", "mov", "flv",
    "webm", "iso", "m4v", "mpg", "mpeg", "vob", "3gp", "asf", "divx", "ogm",
    "strm", "bdmv", "f4v",
]

public let subtitleExtensions: Set<String> = [
    "srt", "ass", "ssa", "sub", "idx", "sup", "vtt", "smi", "lrc",
]

public let sidecarExtensions: Set<String> = [
    "nfo", "jpg", "jpeg", "png", "webp", "gif", "bmp", "tbn", "xml", "svg",
    "mka", "ac3", "eac3", "dts", "dtshd", "truehd",
]

public let junkExtensions: Set<String> = [
    "txt", "url", "html", "htm", "lnk", "exe", "bat", "chm", "ini", "db", "apk",
    "website", "webloc", "torrent!",
]

private let genericDirRegex = try! NSRegularExpression(
    pattern: #"^(?:tv|tv ?shows?|series|movies?|films?|anime|animations?|downloads?|videos?|media|电视剧|电影|动漫|动画|番剧|综艺|纪录片|剧集|影视|新番|国产剧|美剧|日剧|韩剧|欧美剧|港剧|电视|下载|视频)$"#,
    options: [.caseInsensitive]
)

public func isGenericContainerDir(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
    return genericDirRegex.firstMatch(in: trimmed, range: range) != nil
}

// MARK: - Path Helpers

public func dirOf(_ path: String) -> String {
    guard let idx = path.lastIndex(of: "/") else { return "/" }
    if idx == path.startIndex { return "/" }
    return String(path[..<idx])
}

public func baseOf(_ path: String) -> String {
    guard let idx = path.lastIndex(of: "/") else { return path }
    return String(path[path.index(after: idx)...])
}

public func stem(_ name: String) -> String {
    guard let idx = name.lastIndex(of: "."), idx > name.startIndex else { return name }
    return String(name[..<idx])
}

public func extOf(_ name: String) -> String {
    guard let idx = name.lastIndex(of: "."), idx > name.startIndex else { return "" }
    return String(name[name.index(after: idx)...])
}

public func joinPath(_ dir: String, _ name: String) -> String {
    dir.hasSuffix("/") ? "\(dir)\(name)" : "\(dir)/\(name)"
}

// MARK: - CJK & Title Normalization

private let nonWordRegex = try! NSRegularExpression(pattern: #"[^\p{L}\p{N}]"#)
private let letterPrefixRegex = try! NSRegularExpression(pattern: #"^[A-Z](?=[\u3400-\u9fff])"#)
private let bracketedRegex = try! NSRegularExpression(pattern: #"[（(【\[《][^）)】\]》]*[）)】\]》]"#)
private let cjkCharRegex = try! NSRegularExpression(pattern: #"[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]"#)
private let hanCharRegex = try! NSRegularExpression(pattern: #"[\u4e00-\u9fff]"#)
private let latinRunRegex = try! NSRegularExpression(
    pattern: #"[A-Za-z][A-Za-z']*(?![A-Za-z'0-9])(?: +[A-Za-z][A-Za-z']*(?![A-Za-z'0-9]))*"#
)

private let releaseWords: Set<String> = [
    "web", "dl", "webrip", "bluray", "bdrip", "hdtv", "hevc", "avc", "aac", "ddp",
    "flac", "complete", "season", "chs", "cht", "chi", "eng", "mkv", "mp4",
    "remux", "hdr", "dv", "atmos", "proper", "repack", "uhd",
]

public func stripPunct(_ s: String) -> String {
    let range = NSRange(s.startIndex..<s.endIndex, in: s)
    return nonWordRegex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
}

/// Converts Traditional Chinese characters to Simplified Chinese via macOS ICU transliteration.
public func toSimplified(_ s: String) -> String {
    guard !s.isEmpty else { return s }
    guard s.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) else { return s }
    let mutable = NSMutableString(string: s) as CFMutableString
    CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, false)
    return mutable as String
}

public func normTitle(_ s: String) -> String {
    toSimplified(stripPunct(s.lowercased()))
}

public func hasCjk(_ s: String) -> Bool {
    let range = NSRange(s.startIndex..<s.endIndex, in: s)
    return cjkCharRegex.firstMatch(in: s, range: range) != nil
}

public func hasHan(_ s: String) -> Bool {
    let range = NSRange(s.startIndex..<s.endIndex, in: s)
    return hanCharRegex.firstMatch(in: s, range: range) != nil
}

public func titleSimilarity(_ a: String, _ b: String) -> Double {
    let na = normTitle(a)
    let nb = normTitle(b)
    if na.isEmpty || nb.isEmpty { return 0 }
    if na == nb { return 1 }
    let sa = Array(na.unicodeScalars)
    let sb = Array(nb.unicodeScalars)
    let contain: Double = (na.contains(nb) || nb.contains(na))
        ? Double(min(sa.count, sb.count)) / Double(max(sa.count, sb.count))
        : 0.0
    return max(contain, bigramDice(sa, sb))
}

private func bigramDice(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Double {
    guard a.count >= 2, b.count >= 2 else { return 0 }
    let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
    var counts = [UInt64: Int](minimumCapacity: shorter.count - 1)
    for i in 0..<(shorter.count - 1) {
        let key = (UInt64(shorter[i].value) << 32) | UInt64(shorter[i + 1].value)
        counts[key, default: 0] += 1
    }
    var inter = 0
    for i in 0..<(longer.count - 1) {
        let key = (UInt64(longer[i].value) << 32) | UInt64(longer[i + 1].value)
        if let remaining = counts[key], remaining > 0 {
            inter += 1
            counts[key] = remaining - 1
        }
    }
    return Double(2 * inter) / Double(a.count + b.count - 2)
}

/// Deterministic hex hash (two FNV-1a 32-bit runs) matching Dart `stableHash`.
public func stableHash(_ s: String) -> String {
    var h1: UInt32 = 0x811c9dc5
    var h2: UInt32 = 0x01000193
    for c in s.utf16 {
        h1 = (h1 ^ UInt32(c)) &* 16_777_619
        h2 = (h2 ^ UInt32(c)) &* 2_166_136_261
    }
    return String(format: "%08x%08x", h1, h2)
}

public func relaxedQueries(_ title: String, rawName: String) -> [String] {
    let rTitle = NSRange(title.startIndex..<title.endIndex, in: title)
    let noPrefix = letterPrefixRegex.stringByReplacingMatches(in: title, range: rTitle, withTemplate: "")
    let rNoPrefix = NSRange(noPrefix.startIndex..<noPrefix.endIndex, in: noPrefix)
    let noBrackets = bracketedRegex
        .stringByReplacingMatches(in: noPrefix, range: rNoPrefix, withTemplate: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let cjkRaw = noBrackets
        .split(separator: " ")
        .map(String.init)
        .filter { hasCjk($0) }
        .joined(separator: " ")
    let rCjk = NSRange(cjkRaw.startIndex..<cjkRaw.endIndex, in: cjkRaw)
    let cjk = letterPrefixRegex.stringByReplacingMatches(in: cjkRaw, range: rCjk, withTemplate: "")

    var latin: String?
    let rRaw = NSRange(rawName.startIndex..<rawName.endIndex, in: rawName)
    let cleanedRaw = bracketedRegex
        .stringByReplacingMatches(in: rawName, range: rRaw, withTemplate: " ")
        .replacingOccurrences(of: ".", with: " ")
        .replacingOccurrences(of: "_", with: " ")
    let rCleaned = NSRange(cleanedRaw.startIndex..<cleanedRaw.endIndex, in: cleanedRaw)
    for m in latinRunRegex.matches(in: cleanedRaw, range: rCleaned) {
        guard let swiftRange = Range(m.range, in: cleanedRaw) else { continue }
        let words = cleanedRaw[swiftRange]
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty && !releaseWords.contains($0.lowercased()) }
        if words.contains(where: { $0.count >= 3 }) {
            latin = words.joined(separator: " ")
            break
        }
    }

    var seen: Set<String> = [normTitle(title)]
    var out: [String] = []
    var candidates = [noPrefix, noBrackets, cjk]
    if let latin { candidates.append(latin) }
    for q in candidates {
        let n = normTitle(q)
        if !n.isEmpty && seen.insert(n).inserted {
            out.append(q)
        }
    }
    return out
}

public func chineseNamed(_ c: Candidate, detail: Candidate?) -> Candidate {
    guard let detail, detail.tmdbId == c.tmdbId else { return c }
    let t = detail.title
    if t == c.title || hasHan(c.title) || !hasHan(t) { return c }
    return Candidate(
        tmdbId: c.tmdbId,
        kind: c.kind,
        title: t,
        englishTitle: c.englishTitle ?? detail.englishTitle ?? c.title,
        originalTitle: c.originalTitle ?? detail.originalTitle,
        year: c.year ?? detail.year,
        posterPath: c.posterPath ?? detail.posterPath,
        originCountry: c.originCountry ?? detail.originCountry,
        voteAverage: c.voteAverage ?? detail.voteAverage,
        voteCount: c.voteCount ?? detail.voteCount,
        popularity: c.popularity ?? detail.popularity,
        overview: c.overview ?? detail.overview,
        backdropPath: c.backdropPath ?? detail.backdropPath,
        genres: c.genres.isEmpty ? detail.genres : c.genres,
        aliases: c.aliases.isEmpty ? detail.aliases : c.aliases,
        imdbId: c.imdbId ?? detail.imdbId,
        tvdbId: c.tvdbId ?? detail.tvdbId,
        collectionName: c.collectionName ?? detail.collectionName,
        collectionId: c.collectionId ?? detail.collectionId,
        clearLogoPath: c.clearLogoPath ?? detail.clearLogoPath,
        landscapePath: c.landscapePath ?? detail.landscapePath,
        certification: c.certification ?? detail.certification,
        studios: c.studios.isEmpty ? detail.studios : c.studios,
        actors: c.actors.isEmpty ? detail.actors : c.actors,
        directors: c.directors.isEmpty ? detail.directors : c.directors,
        writers: c.writers.isEmpty ? detail.writers : c.writers,
        tags: c.tags.isEmpty ? detail.tags : c.tags
    )
}

// MARK: - Subtitle Language & Trait Flags

private let zhHansTokens: Set<String> = [
    "chs", "sc", "gb", "zh-cn", "zh-hans", "zh-sg", "cn", "chi", "zho", "zh",
    "简体", "简中", "中字", "中文", "简日", "简英",
]
private let zhHantTokens: Set<String> = [
    "cht", "tc", "big5", "zh-tw", "zh-hk", "zh-hant", "zh-mo", "tw", "hk",
    "繁体", "繁體", "繁中", "繁日", "繁英",
]
private let enTokens: Set<String> = ["en", "eng", "english", "en-us", "en-gb", "英文", "英语", "英語"]
private let jaTokens: Set<String> = ["ja", "jp", "jpn", "ja-jp", "japanese", "日文", "日语", "日語"]
private let koTokens: Set<String> = ["ko", "kr", "kor", "ko-kr", "korean", "韩文", "韓文", "韩语", "韓語"]
private let bilingualTokens: Set<String> = [
    "bilingual", "chs&eng", "cht&eng", "sc&en", "tc&en", "zhongying",
    "双语", "雙語", "中英", "简英", "繁英", "簡英", "简日", "繁日", "簡日", "简繁", "簡繁",
]

private let cjkBilingualRegex = try! NSRegularExpression(pattern: #"双语|雙語|中英|简英|繁英|簡英|简日|繁日|簡日|简繁|簡繁"#)
private let cjkSdhRegex = try! NSRegularExpression(pattern: #"听障|聽障"#)
private let cjkForcedRegex = try! NSRegularExpression(pattern: #"强制|強制"#)
private let cjkDefaultRegex = try! NSRegularExpression(pattern: #"默认|默認"#)

public func singleSubtitleLang(_ normalizedLower: String) -> String? {
    if zhHansTokens.contains(normalizedLower) { return "zh-Hans" }
    if zhHantTokens.contains(normalizedLower) { return "zh-Hant" }
    if enTokens.contains(normalizedLower) { return "en" }
    if jaTokens.contains(normalizedLower) { return "ja" }
    if koTokens.contains(normalizedLower) { return "ko" }
    return nil
}

private enum SubtitleSeparators {
    static let remainder = CharacterSet(charactersIn: ". \t\n[]()（）【】")
    static let part = CharacterSet(charactersIn: "&+/,")
    static let edgeDash = CharacterSet(charactersIn: "-_")
}

public func normalizeLang(_ token: String) -> String? {
    let parts = token.lowercased().components(separatedBy: SubtitleSeparators.part)
    for part in parts {
        let t = part.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
        if let lang = singleSubtitleLang(t) { return lang }
    }
    return nil
}

public func subFlagsFromRemainder(_ remainder: String) -> [String] {
    let trimmed = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return [] }
    var bilingual = false
    var sdh = false
    var forced = false
    var isDefault = false
    var langs: Set<String> = []
    var flatTokens: [String] = []

    for chunk in remainder.components(separatedBy: SubtitleSeparators.remainder) where !chunk.isEmpty {
        for raw in chunk.components(separatedBy: SubtitleSeparators.part) {
            let seg = raw.trimmingCharacters(in: SubtitleSeparators.edgeDash).trimmingCharacters(in: .whitespacesAndNewlines)
            if seg.isEmpty { continue }
            let rSeg = NSRange(seg.startIndex..<seg.endIndex, in: seg)
            if cjkBilingualRegex.firstMatch(in: seg, range: rSeg) != nil { bilingual = true }
            if cjkSdhRegex.firstMatch(in: seg, range: rSeg) != nil { sdh = true }
            if cjkForcedRegex.firstMatch(in: seg, range: rSeg) != nil { forced = true }
            if cjkDefaultRegex.firstMatch(in: seg, range: rSeg) != nil { isDefault = true }

            let parts = seg.lowercased().components(separatedBy: SubtitleSeparators.edgeDash).filter { !$0.isEmpty }
            var i = 0
            while i < parts.count {
                if i + 1 < parts.count {
                    let pair = "\(parts[i])-\(parts[i + 1])"
                    if let pairLang = singleSubtitleLang(pair) {
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
        } else if bilingualTokens.contains(p) {
            bilingual = true
        }
        if let lang = singleSubtitleLang(p) {
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
