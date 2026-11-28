import Foundation
import TidyreelModels

private enum TemplateRegex {
    static let emptyParens = try! NSRegularExpression(pattern: #"\(\s*\)|（\s*）"#)
    static let sepRun = try! NSRegularExpression(pattern: #"([._\- ])\1+"#)
    static let leadingSep = try! NSRegularExpression(pattern: #"^[._\- ]+"#)
    static let trailingSep = try! NSRegularExpression(pattern: #"[._\- ]+$"#)
    static let captureRef = try! NSRegularExpression(pattern: #"\$(\d)"#)
    static let illegalPathChars = try! NSRegularExpression(pattern: #"[\\/\x00-\x1f\x7f]"#)
    static let fullWidthChars = try! NSRegularExpression(pattern: #"[:?*"<>|]"#)
    static let multiSpace = try! NSRegularExpression(pattern: #"\s+"#)
    static let trailingDotSpace = try! NSRegularExpression(pattern: #"[. ]+$"#)
    static let windowsReserved = try! NSRegularExpression(
        pattern: #"^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?=\.|$)"#,
        options: [.caseInsensitive]
    )
    static let extraInfoSep = try! NSRegularExpression(pattern: #"[._ ]+"#)
}

private let fullWidthMap: [String: String] = [
    ":": "：",
    "?": "？",
    "*": "＊",
    "\"": "＂",
    "<": "＜",
    ">": "＞",
    "|": "｜",
]

/// Compiles `NamingOptions` into a filename template string (without file extension).
public func compileTemplate(_ options: NamingOptions, isMovie: Bool) -> String {
    if let custom = options.customTemplate, !custom.isEmpty {
        return custom
    }

    let sep = options.separator
    let isTv = !isMovie
    let episodePiece: String
    switch options.episodeStyle {
    case .upperPadded:
        episodePiece = #"S{season:02}E{episode:02}[-E{episode_end:02}]"#
    case .lowerPadded:
        episodePiece = #"s{season:02}e{episode:02}[-e{episode_end:02}]"#
    case .lowerShort:
        episodePiece = #"s{season}e{episode}[-e{episode_end}]"#
    case .cross:
        episodePiece = #"{season}x{episode:02}[-{episode_end:02}]"#
    case .lowerDotted:
        episodePiece = #"s{season:02}.e{episode:02}[-e{episode_end:02}]"#
    }

    var pieces: [(text: String, always: Bool)] = []
    for f in options.order {
        switch f {
        case .title:
            switch (options.titleLanguage, options.bilingual) {
            case (.chineseFirst, true):
                pieces.append(("{title}", true))
                pieces.append(("{en_title}", false))
            case (.chineseFirst, false):
                pieces.append(("{title}", true))
            case (.englishFirst, true):
                pieces.append(("{en_title}", false))
                pieces.append(("{title}", false))
            case (.englishFirst, false):
                pieces.append(("{en_title}", true))
            }
        case .year:
            if options.includeYear {
                pieces.append((options.yearInParens ? "({year})" : "{year}", false))
            }
        case .episode:
            if isTv {
                pieces.append((episodePiece, false))
            }
        case .episodeTitle:
            if isTv && options.episodeTitle {
                pieces.append(("{episode_title}", false))
            }
        case .extraInfo:
            if options.extraInfo {
                pieces.append(("{extra_info}", false))
            }
        }
    }
    if options.tmdbIdTag {
        pieces.append(("{tmdb_tag}", false))
    }

    var out = ""
    for (i, piece) in pieces.enumerated() {
        if i == 0 && piece.always {
            out += piece.text
        } else {
            out += "[\(i == 0 ? "" : sep)\(piece.text)]"
        }
    }
    if options.releaseGroup {
        out += "[-{group}]"
    }
    return out
}

/// Convenience overload taking `MediaKind`.
public func compileTemplate(_ options: NamingOptions, kind: MediaKind) -> String {
    compileTemplate(options, isMovie: kind == .movie)
}

/// Convenience unlabeled overload taking `MediaKind`.
public func compileTemplate(_ options: NamingOptions, _ kind: MediaKind) -> String {
    compileTemplate(options, isMovie: kind == .movie)
}

/// Renders `{var}`, `{var:02}` zero-padded integers, `[ ... ]` optional segments,
/// and `\x` escapes, collapsing repeated separators in template literals and trimming
/// leading/trailing separators without altering punctuation inside substituted values.
public func renderTemplate(_ template: String, vars: [String: String]) -> String {
    var renderer = TemplateRenderer(chars: Array(template), vars: vars)
    let (raw, _) = renderer.sequence(inOptional: false)

    var chunks: [(text: String, isValue: Bool)] = []
    chunks.reserveCapacity(raw.count)
    for (text, isValue) in raw where !text.isEmpty {
        if !isValue, let last = chunks.last, !last.isValue {
            chunks[chunks.count - 1] = (last.text + text, false)
        } else {
            chunks.append((text, isValue))
        }
    }

    var cleaned: [(text: String, isValue: Bool)] = []
    cleaned.reserveCapacity(chunks.count)
    for (text, isValue) in chunks {
        if isValue {
            cleaned.append((text, true))
        } else {
            let noParens = replaceAllRegex(TemplateRegex.emptyParens, in: text, with: "")
            let collapsed = replaceAllRegex(TemplateRegex.sepRun, in: noParens, with: "$1")
            if !collapsed.isEmpty {
                cleaned.append((collapsed, false))
            }
        }
    }

    while let first = cleaned.first, !first.isValue {
        let s = replaceFirstRegex(TemplateRegex.leadingSep, in: first.text, with: "")
        if s.isEmpty {
            cleaned.removeFirst()
        } else {
            cleaned[0] = (s, false)
            break
        }
    }

    while let last = cleaned.last, !last.isValue {
        let s = replaceFirstRegex(TemplateRegex.trailingSep, in: last.text, with: "")
        if s.isEmpty {
            cleaned.removeLast()
        } else {
            cleaned[cleaned.count - 1] = (s, false)
            break
        }
    }

    return cleaned.map(\.text).joined()
}

/// Replaces characters illegal on Windows / cloud drives, strips control characters
/// including DEL (`\x7f`), collapses whitespace, trims trailing dots/spaces, and
/// neutralizes Windows reserved device names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`, `LPT1`-`LPT9`).
public func sanitizeName(_ name: String) -> String {
    let noIllegal = replaceAllRegex(TemplateRegex.illegalPathChars, in: name, with: "")
    let fullWidthed = replaceAllMapped(TemplateRegex.fullWidthChars, in: noIllegal) { matchStr, _ in
        fullWidthMap[matchStr] ?? matchStr
    }
    let singleSpaced = replaceAllRegex(TemplateRegex.multiSpace, in: fullWidthed, with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let cleaned = replaceAllRegex(TemplateRegex.trailingDotSpace, in: singleSpaced, with: "")
    if cleaned.isEmpty { return "" }
    return replaceFirstRegex(TemplateRegex.windowsReserved, in: cleaned, with: "$1_")
}

private final class RewriteRegexCache: @unchecked Sendable {
    private enum Entry {
        case compiled(NSRegularExpression)
        case invalid
    }

    static let shared = RewriteRegexCache(capacity: 128)

    private let lock = NSLock()
    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    func regex(for pattern: String) -> NSRegularExpression? {
        lock.lock()
        if let cached = entries[pattern] {
            lock.unlock()
            switch cached {
            case .compiled(let re): return re
            case .invalid: return nil
            }
        }
        lock.unlock()

        let compiled = try? NSRegularExpression(pattern: pattern)
        let entry: Entry = compiled.map(Entry.compiled) ?? .invalid

        lock.lock()
        if let existing = entries[pattern] {
            lock.unlock()
            switch existing {
            case .compiled(let re): return re
            case .invalid: return nil
            }
        }
        if entries.count >= capacity, !insertionOrder.isEmpty {
            let evicted = insertionOrder.removeFirst()
            entries.removeValue(forKey: evicted)
        }
        entries[pattern] = entry
        insertionOrder.append(pattern)
        lock.unlock()
        return compiled
    }
}

/// Runs `rewrites` over `text` in order. A rule with an invalid regex pattern is skipped,
/// and any rewrite that would sanitize to an empty name is ignored.
public func applyRewrites(_ text: String, rewrites: [NameRewrite]) -> String {
    var out = text
    for r in rewrites {
        if r.pattern.isEmpty { continue }
        guard let re = RewriteRegexCache.shared.regex(for: r.pattern) else { continue }
        let next = replaceAllWithCaptureRefs(re, in: out, replacement: r.replacement)
        if !sanitizeName(next).isEmpty {
            out = next
        }
    }
    return out
}

/// Unlabeled convenience overload of `applyRewrites`.
public func applyRewrites(_ text: String, _ rewrites: [NameRewrite]) -> String {
    applyRewrites(text, rewrites: rewrites)
}

/// Generates a live preview path example for the Naming UI using `NamingProfile`
/// (e.g. `电影/盗梦空间 (2010)/盗梦空间.Inception.2010.mkv` or
/// `剧集/老友记 (1994)/Season 02/老友记.Friends.1994.S02E03.mp4`).
public func previewNamingExample(profile: NamingProfile, isMovie: Bool) -> String {
    let options = isMovie ? profile.movie : profile.tv
    let sep = options.separator

    if isMovie {
        let extra = replaceAllRegex(TemplateRegex.extraInfoSep, in: "2160p.DV", with: sep)
        let enTitle = (!options.bilingual && options.titleLanguage == .englishFirst)
            ? "Inception"
            : "Inception"
        let vars: [String: String] = [
            "title": "盗梦空间",
            "original_title": "Inception",
            "en_title": enTitle,
            "year": "2010",
            "tmdbid": "27205",
            "tmdb_tag": "{tmdb-27205}",
            "resolution": "2160p",
            "extra_info": extra,
            "version": extra,
            "group": "EVO",
            "ext": "mkv",
        ]
        var folderVars = vars
        if options.titleLanguage == .englishFirst, let en = vars["en_title"] {
            folderVars["title"] = en
        }
        let tpl = compileTemplate(options, isMovie: true)
        let rawBase = sanitizeName(applyRewrites(renderTemplate(tpl, vars: vars), rewrites: options.rewrites))
        let base = rawBase.isEmpty ? "盗梦空间.Inception.2010" : rawBase
        let fileName = base.lowercased().hasSuffix(".mkv") ? base : "\(base).mkv"

        let rawFolder = sanitizeName(
            applyRewrites(renderTemplate(options.folderTemplate, vars: folderVars), rewrites: options.rewrites)
        )
        let folder = rawFolder.isEmpty ? "盗梦空间 (2010)" : rawFolder
        let typeDir = sanitizeName(profile.movieDir)
        return typeDir.isEmpty ? "\(folder)/\(fileName)" : "\(typeDir)/\(folder)/\(fileName)"
    } else {
        let year = options.showYear == .seasonAir ? "1995" : "1994"
        let extra = replaceAllRegex(TemplateRegex.extraInfoSep, in: "2160p.Dolby", with: sep)
        let vars: [String: String] = [
            "title": "老友记",
            "original_title": "Friends",
            "en_title": "Friends",
            "year": year,
            "season": "2",
            "episode": "3",
            "episode_title": "The One Where Phoebe Hates PBS",
            "tmdbid": "1668",
            "tmdb_tag": "{tmdb-1668}",
            "resolution": "2160p",
            "extra_info": extra,
            "version": extra,
            "group": "EVO",
            "ext": "mp4",
        ]
        var folderVars = vars
        if options.titleLanguage == .englishFirst, let en = vars["en_title"] {
            folderVars["title"] = en
        }
        folderVars["year"] = "1994"

        let tpl = compileTemplate(options, isMovie: false)
        let rawBase = sanitizeName(applyRewrites(renderTemplate(tpl, vars: vars), rewrites: options.rewrites))
        let base = rawBase.isEmpty ? "老友记.Friends.1994.S02E03" : rawBase
        let fileName = base.lowercased().hasSuffix(".mp4") ? base : "\(base).mp4"

        let rawFolder = sanitizeName(
            applyRewrites(renderTemplate(options.folderTemplate, vars: folderVars), rewrites: options.rewrites)
        )
        let folder = rawFolder.isEmpty ? "老友记 (1994)" : rawFolder

        let rawSeason = sanitizeName(
            applyRewrites(
                renderTemplate(options.seasonFolderTemplate, vars: ["season": "2"]),
                rewrites: options.rewrites
            )
        )
        let seasonFolder = rawSeason.isEmpty ? "Season 02" : rawSeason
        let typeDir = sanitizeName(profile.tvDir)
        return typeDir.isEmpty
            ? "\(folder)/\(seasonFolder)/\(fileName)"
            : "\(typeDir)/\(folder)/\(seasonFolder)/\(fileName)"
    }
}

// MARK: - Internal Renderer & Regex Helpers

func formatExtraInfo(_ raw: String?, separator: String) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    return replaceAllRegex(TemplateRegex.extraInfoSep, in: raw, with: separator)
}

private struct TemplateRenderer {
    let chars: [Character]
    let vars: [String: String]
    var i: Int = 0

    mutating func sequence(inOptional: Bool) -> (chunks: [(text: String, isValue: Bool)], missing: Bool) {
        var out: [(text: String, isValue: Bool)] = []
        var lit = ""

        func flushLit() {
            if !lit.isEmpty {
                out.append((lit, false))
                lit.removeAll(keepingCapacity: true)
            }
        }

        var missing = false
        while i < chars.count {
            let c = chars[i]
            if c == "\\" && i + 1 < chars.count {
                lit.append(chars[i + 1])
                i += 2
            } else if c == "[" {
                i += 1
                let (sub, m) = sequence(inOptional: true)
                if i < chars.count && chars[i] == "]" {
                    i += 1
                }
                if !m && !sub.isEmpty {
                    flushLit()
                    out.append(contentsOf: sub)
                }
            } else if c == "]" && inOptional {
                flushLit()
                return (out, missing)
            } else if c == "{", let end = findClosingBrace(from: i + 1) {
                let spec = String(chars[(i + 1)..<end])
                i = end + 1
                if let val = resolveValue(spec) {
                    flushLit()
                    out.append((val, true))
                } else {
                    missing = true
                }
            } else {
                lit.append(c)
                i += 1
            }
        }
        flushLit()
        return (out, missing)
    }

    private func findClosingBrace(from start: Int) -> Int? {
        var idx = start
        while idx < chars.count {
            if chars[idx] == "}" { return idx }
            idx += 1
        }
        return nil
    }

    private func resolveValue(_ spec: String) -> String? {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = vars[key], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if parts.count > 1, let width = Int(parts[1]), width > 0, Int(raw) != nil {
            let padCount = width - raw.count
            return padCount > 0 ? String(repeating: "0", count: padCount) + raw : raw
        }
        return raw
    }
}

private func replaceAllRegex(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
    guard !text.isEmpty else { return text }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
}

private func replaceFirstRegex(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
    guard !text.isEmpty else { return text }
    let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: fullRange),
          let swiftRange = Range(match.range, in: text) else {
        return text
    }
    let replacement = regex.replacementString(for: match, in: text, offset: 0, template: template)
    var out = text
    out.replaceSubrange(swiftRange, with: replacement)
    return out
}

private func replaceAllMapped(
    _ regex: NSRegularExpression,
    in text: String,
    transform: (String, NSTextCheckingResult) -> String
) -> String {
    guard !text.isEmpty else { return text }
    let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
    let matches = regex.matches(in: text, range: fullRange)
    if matches.isEmpty { return text }

    var result = ""
    result.reserveCapacity(text.count)
    var cursor = text.startIndex
    for match in matches {
        guard let swiftRange = Range(match.range, in: text) else { continue }
        result += text[cursor..<swiftRange.lowerBound]
        result += transform(String(text[swiftRange]), match)
        cursor = swiftRange.upperBound
    }
    result += text[cursor..<text.endIndex]
    return result
}

private func replaceAllWithCaptureRefs(
    _ regex: NSRegularExpression,
    in text: String,
    replacement: String
) -> String {
    let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
    let matches = regex.matches(in: text, range: fullRange)
    if matches.isEmpty { return text }

    let hasCaptureRef = replacement.contains("$")
    var result = ""
    result.reserveCapacity(text.count)
    var cursor = text.startIndex

    for match in matches {
        guard let matchRange = Range(match.range, in: text) else { continue }
        result += text[cursor..<matchRange.lowerBound]
        if !hasCaptureRef {
            result += replacement
        } else {
            let expanded = replaceAllMapped(TemplateRegex.captureRef, in: replacement) { token, refMatch in
                guard refMatch.numberOfRanges > 1,
                      let digitRange = Range(refMatch.range(at: 1), in: replacement),
                      let groupIndex = Int(replacement[digitRange]) else {
                    return token
                }
                if groupIndex < match.numberOfRanges {
                    let groupNSRange = match.range(at: groupIndex)
                    if groupNSRange.location == NSNotFound {
                        return ""
                    }
                    if let groupSwiftRange = Range(groupNSRange, in: text) {
                        return String(text[groupSwiftRange])
                    }
                    return ""
                }
                return token
            }
            result += expanded
        }
        cursor = matchRange.upperBound
    }
    result += text[cursor..<text.endIndex]
    return result
}
