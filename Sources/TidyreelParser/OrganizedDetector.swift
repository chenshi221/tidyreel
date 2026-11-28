import Foundation
import TidyreelModels

// MARK: - Pre-compiled Static Patterns for Organized Layout Detection

private enum OrganizedRegexes {
    /// Default show / movie folder: 「名称 (2011)」, maybe with a `{tmdb-1}` / `[tmdb-1]` tag.
    static let movieFolder = CompiledRegex(
        #"^(.*\S) \(((?:19|20)\d{2})\)(?: [\[\{][^\]\}]*[\]\}])?$"#
    )

    /// Default season folder: 「Season 01」 (or 「Specials」 for season 0).
    static let seasonFolder = CompiledRegex(#"^(?:Season (\d{1,2})|Specials)$"#)

    static let episodeTag = CompiledRegex(
        #"(?:^|[^a-z0-9])s(\d{2})e\d{2,3}(?:$|[^0-9])"#,
        caseSensitive: false
    )
    static let episodeLowerShort = CompiledRegex(
        #"(?:^|[^a-z0-9])s(\d{1,2})e\d{1,4}(?:$|[^0-9])"#,
        caseSensitive: false
    )
    static let episodeCross = CompiledRegex(
        #"(?:^|[^a-z0-9])(\d{1,2})x\d{2,3}(?:$|[^0-9])"#,
        caseSensitive: false
    )
    static let episodeLowerDotted = CompiledRegex(
        #"(?:^|[^a-z0-9])s(\d{1,2})\.e\d{1,4}(?:$|[^0-9])"#,
        caseSensitive: false
    )

    static let seasonPlaceholder = CompiledRegex(#"\{season(?::\d+)?\}"#)
    static let folderToken = CompiledRegex(#"\{([a-z_]+)(?::\d+)?\}"#)
    static let nonAscii = CompiledRegex(#"[^\x00-\x7F]"#)
    static let trailingTag = CompiledRegex(#"\s*[\[\{][^\]\}]*[\]\}]\s*$"#)
    static let escapeSpaces = CompiledRegex(#"(?:\\\s|\s)+"#)

    static let genericContainerDir = CompiledRegex(
        #"^(?:tv|tv ?shows?|shows?|series|movies?|films?|anime|animations?|downloads?|"# +
        #"videos?|media|unsorted|incoming|temp|tmp|extras?|specials?|bdmv|video_ts|"# +
        #"电视剧|电影|动漫|动画|番剧|综艺|纪录片|剧集|影视|影视库|新番|国产剧|美剧|日剧|"# +
        #"韩剧|欧美剧|港剧|电视|下载|视频|待分类|待整理|字幕|字幕包|原声音乐|音乐)$"#,
        caseSensitive: false
    )

    static let rawReleaseNoise = CompiledRegex(
        #"^\s*[\[【]|"# +
        #"(?:^|[^a-z0-9])(?:480|576|720|1080|2160)[pi](?:$|[^a-z0-9])|"# +
        #"(?:^|[^a-z0-9])(?:web[-. ]?dl|webrip|bluray|bdrip|remux|hdtv|dvdrip|x26[45]|h\.?26[45]|hevc|avc|10bit|atvp|amzn|dsnp|hmax|uhd)(?:$|[^a-z0-9])|"# +
        #"(?:^|[^a-z0-9])s\d{1,2}(?:e\d{1,3})?(?:$|[^a-z0-9])|"# +
        #"(?:^|[^a-z0-9])\d{1,2}-\d{1,2}(?:$|[^a-z0-9])|"# +
        #"全\d+集"#,
        caseSensitive: false
    )
    static let dotYearRelease = CompiledRegex(#"\.(?:19|20)\d{2}(?:$|\.)"#)

    // Template preview & rewrite helpers
    static let emptyParens = CompiledRegex(#"\(\s*\)|（\s*）"#)
    static let sepRun = CompiledRegex(#"([._\- ])\1+"#)
    static let leadingSep = CompiledRegex(#"^[._\- ]+"#)
    static let trailingSep = CompiledRegex(#"[._\- ]+$"#)
    static let captureRef = CompiledRegex(#"\$(\d)"#)
    static let illegalPathChars = CompiledRegex(#"[\\/\x00-\x1f\x7f]"#)
    static let fullWidthChars = CompiledRegex(#"[:?*"<>|]"#)
    static let multiSpace = CompiledRegex(#"\s+"#)
    static let trailingDotSpace = CompiledRegex(#"[. ]+$"#)
    static let windowsReserved = CompiledRegex(
        #"^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?=\.|$)"#,
        caseSensitive: false
    )
}

private struct FolderMatchResult {
    let title: String
    let year: String?
}

private struct CompiledFolderPattern: Sendable {
    let regex: CompiledRegex
    let hasTitleGroup: Bool
    let hasYearGroup: Bool
}

private enum ExtraEpisodeKind: Hashable, Sendable {
    case lowerShort
    case cross
    case lowerDotted

    var regex: CompiledRegex {
        switch self {
        case .lowerShort: return OrganizedRegexes.episodeLowerShort
        case .cross: return OrganizedRegexes.episodeCross
        case .lowerDotted: return OrganizedRegexes.episodeLowerDotted
        }
    }
}

// MARK: - Cached ProfileMatcher

private final class ProfileMatcher: Sendable {
    let profile: NamingProfile
    let seasonRegexes: [CompiledRegex]
    let extraEpisodeKinds: [ExtraEpisodeKind]
    let movieFolderPatterns: [CompiledFolderPattern]
    let tvFolderPatterns: [CompiledFolderPattern]
    let movieAllowsNoYear: Bool
    let tvAllowsNoYear: Bool
    let genericLower: Set<String>

    init(_ profile: NamingProfile) {
        self.profile = profile
        self.seasonRegexes = Self.buildSeasonRegexes(profile.tv)
        self.extraEpisodeKinds = Self.buildEpisodeKinds(profile.tv)
        self.movieFolderPatterns = Self.buildFolderPatterns(profile.movie)
        self.tvFolderPatterns = Self.buildFolderPatterns(profile.tv)
        self.movieAllowsNoYear = !profile.movie.includeYear || !profile.movie.folderTemplate.contains("{year}")
        self.tvAllowsNoYear = !profile.tv.includeYear || !profile.tv.folderTemplate.contains("{year}")
        var gl: Set<String> = [
            profile.movieDir.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            profile.tvDir.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        ]
        gl.remove("")
        self.genericLower = gl
    }

    private static func buildSeasonRegexes(_ tv: NamingOptions) -> [CompiledRegex] {
        var out: [CompiledRegex] = []
        if let direct = compileSeasonTemplate(tv.seasonFolderTemplate) {
            out.append(direct)
        }
        if !tv.rewrites.isEmpty {
            let rendered = renderPreviewTemplate(tv.seasonFolderTemplate, vars: ["season": "77"])
            let rewritten = applyPreviewRewrites(rendered, rewrites: tv.rewrites)
            if rewritten != rendered && rewritten.contains("77") {
                if let re = compileSeasonTemplate(rewritten.replacingOccurrences(of: "77", with: "{season}")) {
                    out.append(re)
                }
            }
        }
        return out
    }

    private static func compileSeasonTemplate(_ template: String) -> CompiledRegex? {
        let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || !OrganizedRegexes.seasonPlaceholder.hasMatch(t) { return nil }
        let flexibleSpace = OrganizedRegexes.nonAscii.hasMatch(t)
        let total = utf16Count(t)
        var buf = "^"
        var pos = 0
        for m in OrganizedRegexes.seasonPlaceholder.allMatches(t) {
            if m.start > pos {
                buf += escapeLiteral(utf16Sub(t, pos, m.start), flexibleSpace: flexibleSpace)
            }
            buf += #"(\d{1,2})"#
            pos = m.end
        }
        if pos < total {
            buf += escapeLiteral(utf16Sub(t, pos, total), flexibleSpace: flexibleSpace)
        }
        buf += "$"
        return CompiledRegex(dynamic: buf)
    }

    private static func escapeLiteral(_ literal: String, flexibleSpace: Bool) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: literal)
        return OrganizedRegexes.escapeSpaces.replaceAll(escaped, with: flexibleSpace ? #"\s*"# : #"\s+"#)
    }

    private static func buildEpisodeKinds(_ tv: NamingOptions) -> [ExtraEpisodeKind] {
        var out: [ExtraEpisodeKind] = []
        func add(_ kind: ExtraEpisodeKind) {
            if !out.contains(kind) { out.append(kind) }
        }
        switch tv.episodeStyle {
        case .upperPadded, .lowerPadded:
            break
        case .lowerShort:
            add(.lowerShort)
        case .cross:
            add(.cross)
        case .lowerDotted:
            add(.lowerDotted)
        }
        if let custom = tv.customTemplate, !custom.isEmpty {
            let lower = custom.lowercased()
            if lower.contains("x{episode") { add(.cross) }
            if lower.contains(".e{episode") { add(.lowerDotted) }
            if lower.contains("s{season}e{episode") { add(.lowerShort) }
        }
        return out
    }

    private static func buildFolderPatterns(_ opts: NamingOptions) -> [CompiledFolderPattern] {
        guard let pat = compileFolderTemplate(opts.folderTemplate) else { return [] }
        return [pat]
    }

    private static func compileFolderTemplate(_ template: String) -> CompiledFolderPattern? {
        let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == "{title} ({year})" { return nil }
        let hasAnchor = t.contains("{year}") || t.contains("{tmdb_tag}") || t.contains("{tmdbid}")
        let hasTitle = t.contains("{title}") || t.contains("{en_title}") || t.contains("{original_title}")
        if !hasAnchor || !hasTitle { return nil }

        let chars = Array(t)
        var depth = 0
        var balanced = true
        var idx = 0
        while idx < chars.count {
            if chars[idx] == "\\" && idx + 1 < chars.count {
                idx += 2
                continue
            }
            if chars[idx] == "[" {
                depth += 1
            } else if chars[idx] == "]" {
                depth -= 1
                if depth < 0 { balanced = false }
            }
            idx += 1
        }
        if depth != 0 { balanced = false }

        var buf = "^"
        var hasNamedTitle = false
        var hasNamedYear = false
        let totalUtf16 = utf16Count(t)
        var uPos = 0
        while uPos < totalUtf16 {
            let ch = utf16Sub(t, uPos, uPos + 1)
            if ch == "\\" && uPos + 1 < totalUtf16 {
                let nextCh = utf16Sub(t, uPos + 1, uPos + 2)
                buf += NSRegularExpression.escapedPattern(for: nextCh)
                uPos += 2
            } else if balanced && ch == "[" {
                buf += "(?:"
                uPos += 1
            } else if balanced && ch == "]" {
                buf += ")?"
                uPos += 1
            } else if ch == "{" {
                if let m = OrganizedRegexes.folderToken.matchAtPrefix(t, utf16Pos: uPos, totalUtf16Len: totalUtf16),
                   let tokenName = m[1] {
                    switch tokenName {
                    case "title", "en_title", "original_title":
                        if !hasNamedTitle {
                            buf += "(?<title>.+?)"
                            hasNamedTitle = true
                        } else {
                            buf += ".+?"
                        }
                    case "year":
                        if !hasNamedYear {
                            buf += #"(?<year>(?:19|20)\d{2})"#
                            hasNamedYear = true
                        } else {
                            buf += #"(?:19|20)\d{2}"#
                        }
                    case "tmdb_tag":
                        buf += #"[\[\{](?:tmdb|tmdbid)[-=:]\d+[\]\}]"#
                    case "tmdbid":
                        buf += #"\d+"#
                    default:
                        buf += ".+?"
                    }
                    uPos = m.end
                } else {
                    buf += NSRegularExpression.escapedPattern(for: ch)
                    uPos += 1
                }
            } else if ch == " " {
                buf += #"\s+"#
                uPos += 1
            } else {
                buf += NSRegularExpression.escapedPattern(for: ch)
                uPos += 1
            }
        }
        buf += #"(?:\s*[\[\{][^\]\}]*[\]\}])?$"#
        guard let regex = CompiledRegex(dynamic: buf) else { return nil }
        return CompiledFolderPattern(regex: regex, hasTitleGroup: hasNamedTitle, hasYearGroup: hasNamedYear)
    }

    func matchSeason(_ name: String) -> Int? {
        if name.lowercased() == "specials" { return 0 }
        for re in seasonRegexes {
            if let m = re.firstMatch(name), let n = m[1].flatMap(Int.init) {
                return n
            }
        }
        return nil
    }

    func matchEpisodeSeason(_ fileName: String) -> Int? {
        for kind in extraEpisodeKinds {
            if let m = kind.regex.firstMatch(fileName), let n = m[1].flatMap(Int.init) {
                return n
            }
        }
        return nil
    }

    private func isCleanNoYearFolder(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if genericLower.contains(trimmed.lowercased()) { return false }
        if OrganizedRegexes.genericContainerDir.hasMatch(trimmed) { return false }
        if OrganizedRegexes.seasonFolder.hasMatch(trimmed) || matchSeason(trimmed) != nil {
            return false
        }
        if OrganizedRegexes.rawReleaseNoise.hasMatch(trimmed) { return false }
        if OrganizedRegexes.dotYearRelease.hasMatch(trimmed) { return false }
        return true
    }

    func matchFolder(
        _ name: String,
        allowMovie: Bool,
        allowTv: Bool,
        allowUnanchoredNoYear: Bool = true
    ) -> FolderMatchResult? {
        var patterns: [CompiledFolderPattern] = []
        if allowMovie { patterns.append(contentsOf: movieFolderPatterns) }
        if allowTv { patterns.append(contentsOf: tvFolderPatterns) }

        for pat in patterns {
            guard let m = pat.regex.firstMatch(name) else { continue }
            let title = (pat.hasTitleGroup ? m.named("title") : nil)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if title.isEmpty
                || OrganizedRegexes.rawReleaseNoise.hasMatch(title)
                || OrganizedRegexes.genericContainerDir.hasMatch(title) {
                continue
            }
            let year = pat.hasYearGroup ? m.named("year") : nil
            return FolderMatchResult(title: title, year: year)
        }

        let allowsNoYear = allowUnanchoredNoYear
            && ((allowMovie && movieAllowsNoYear) || (allowTv && tvAllowsNoYear))
        if allowsNoYear && isCleanNoYearFolder(name) {
            let title = OrganizedRegexes.trailingTag.replaceAll(name, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return FolderMatchResult(title: title, year: nil)
            }
        }
        return nil
    }
}

private enum MatcherCache {
    static let vidhubMatcher = ProfileMatcher(.vidhub)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [NamingProfile: ProfileMatcher] = [:]

    static func matcher(for profile: NamingProfile) -> ProfileMatcher {
        if profile == .vidhub { return vidhubMatcher }
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[profile] { return hit }
        let built = ProfileMatcher(profile)
        if cache.count >= 32 { cache.removeAll(keepingCapacity: true) }
        cache[profile] = built
        return built
    }
}

// MARK: - Minimal Template Preview & Rewrite Support for Season Folder Rewrites

private let fullWidthSanitizeMap: [String: String] = [
    ":": "：", "?": "？", "*": "＊", "\"": "＂", "<": "＜", ">": "＞", "|": "｜",
]

private func sanitizePreviewName(_ name: String) -> String {
    var cleaned = OrganizedRegexes.illegalPathChars.replaceAll(name, with: "")
    cleaned = OrganizedRegexes.fullWidthChars.replaceAllMapped(cleaned) { m in
        fullWidthSanitizeMap[m[0] ?? ""] ?? ""
    }
    cleaned = OrganizedRegexes.multiSpace.replaceAll(cleaned, with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    cleaned = OrganizedRegexes.trailingDotSpace.replaceAll(cleaned, with: "")
    if cleaned.isEmpty { return "" }
    return OrganizedRegexes.windowsReserved.replaceFirstMapped(cleaned) { m in
        "\(m[1] ?? "")_"
    }
}

private func renderPreviewTemplate(_ template: String, vars: [String: String]) -> String {
    let chars = Array(template)
    var i = 0

    func evalSpec(_ spec: String) -> String? {
        let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = vars[key], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if parts.count > 1, let width = Int(parts[1]), Int(raw) != nil, raw.count < width {
            return String(repeating: "0", count: width - raw.count) + raw
        }
        return raw
    }

    func sequence(inOptional: Bool) -> ([(String, Bool)], Bool) {
        var out: [(String, Bool)] = []
        var lit = ""
        func flushLit() {
            if !lit.isEmpty {
                out.append((lit, false))
                lit = ""
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
                if i < chars.count && chars[i] == "]" { i += 1 }
                if !m && !sub.isEmpty {
                    flushLit()
                    out.append(contentsOf: sub)
                }
            } else if c == "]" && inOptional {
                flushLit()
                return (out, missing)
            } else if c == "{", let endIdx = chars[(i + 1)...].firstIndex(of: "}") {
                let spec = String(chars[(i + 1)..<endIdx])
                i = endIdx + 1
                if let val = evalSpec(spec) {
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

    let (raw, _) = sequence(inOptional: false)
    var chunks: [(String, Bool)] = []
    for (text, isValue) in raw where !text.isEmpty {
        if !isValue, let last = chunks.last, !last.1 {
            chunks[chunks.count - 1] = (last.0 + text, false)
        } else {
            chunks.append((text, isValue))
        }
    }

    var cleaned: [(String, Bool)] = []
    for (text, isValue) in chunks {
        if isValue {
            cleaned.append((text, true))
        } else {
            var s = OrganizedRegexes.emptyParens.replaceAll(text, with: "")
            s = OrganizedRegexes.sepRun.replaceAllMapped(s) { m in m[1] ?? "" }
            if !s.isEmpty { cleaned.append((s, false)) }
        }
    }
    while let first = cleaned.first, !first.1 {
        let s = OrganizedRegexes.leadingSep.replaceFirst(first.0, with: "")
        if s.isEmpty {
            cleaned.removeFirst()
        } else {
            cleaned[0] = (s, false)
            break
        }
    }
    while let last = cleaned.last, !last.1 {
        let s = OrganizedRegexes.trailingSep.replaceFirst(last.0, with: "")
        if s.isEmpty {
            cleaned.removeLast()
        } else {
            cleaned[cleaned.count - 1] = (s, false)
            break
        }
    }
    return cleaned.map(\.0).joined()
}

private func applyPreviewRewrites(_ name: String, rewrites: [NameRewrite]) -> String {
    var out = name
    for r in rewrites where !r.pattern.isEmpty {
        guard let re = CompiledRegex(dynamic: r.pattern) else { continue }
        let next = re.replaceAllMapped(out) { m in
            OrganizedRegexes.captureRef.replaceAllMapped(r.replacement) { g in
                guard let idx = g[1].flatMap(Int.init) else { return g[0] ?? "" }
                return idx <= m.groupCount ? (m[idx] ?? "") : (g[0] ?? "")
            }
        }
        if !sanitizePreviewName(next).isEmpty {
            out = next
        }
    }
    return out
}

// MARK: - Core Organized Layout Logic

private func matchSeasonNumber(_ name: String, _ matcher: ProfileMatcher) -> Int? {
    if let def = OrganizedRegexes.seasonFolder.firstMatch(name) {
        return Int(def[1] ?? "0")
    }
    return matcher.matchSeason(name)
}

private func matchEpisodeSeason(_ fileName: String, _ matcher: ProfileMatcher) -> Int? {
    if let def = OrganizedRegexes.episodeTag.firstMatch(fileName), let s = def[1].flatMap(Int.init) {
        return s
    }
    return matcher.matchEpisodeSeason(fileName)
}

private func matchMediaFolder(
    _ name: String,
    _ matcher: ProfileMatcher,
    allowMovie: Bool,
    allowTv: Bool,
    allowUnanchoredNoYear: Bool = true
) -> FolderMatchResult? {
    if let def = OrganizedRegexes.movieFolder.firstMatch(name), let title = def[1], let year = def[2] {
        return FolderMatchResult(title: title, year: year)
    }
    return matcher.matchFolder(
        name,
        allowMovie: allowMovie,
        allowTv: allowTv,
        allowUnanchoredNoYear: allowUnanchoredNoYear
    )
}

private func isDiscEntry(_ segs: [String], isDir: Bool, _ matcher: ProfileMatcher) -> Bool {
    let maxIdx = isDir ? segs.count - 1 : segs.count - 2
    guard maxIdx >= 1 else { return false }
    for i in 1...maxIdx {
        let upper = segs[i].uppercased()
        if upper == "BDMV" || upper == "VIDEO_TS" {
            return matchMediaFolder(segs[i - 1], matcher, allowMovie: true, allowTv: false) != nil
        }
    }
    return false
}

private func checkOrganized(
    segs: [String],
    isDir: Bool,
    naming: NamingProfile,
    allowUnanchoredNoYearDir: Bool = true
) -> Bool {
    guard !segs.isEmpty else { return false }
    let matcher = MatcherCache.matcher(for: naming)
    if isDiscEntry(segs, isDir: isDir, matcher) { return true }

    if isDir {
        let last = segs[segs.count - 1]
        if matchMediaFolder(
            last,
            matcher,
            allowMovie: true,
            allowTv: true,
            allowUnanchoredNoYear: allowUnanchoredNoYearDir
        ) != nil {
            return true
        }
        if segs.count >= 2,
           matchSeasonNumber(last, matcher) != nil,
           matchMediaFolder(segs[segs.count - 2], matcher, allowMovie: false, allowTv: true) != nil {
            return true
        }
        return false
    }

    guard segs.count >= 2 else { return false }
    let name = segs[segs.count - 1]
    let parent = segs[segs.count - 2]

    if let epSeason = matchEpisodeSeason(name, matcher) {
        if matchMediaFolder(parent, matcher, allowMovie: false, allowTv: true) != nil {
            return true
        }
        guard let season = matchSeasonNumber(parent, matcher), segs.count >= 3 else {
            return false
        }
        guard matchMediaFolder(segs[segs.count - 3], matcher, allowMovie: false, allowTv: true) != nil else {
            return false
        }
        return epSeason == season
    }

    // Movie: named after its folder, e.g. 「盗梦空间.Inception.2010.mkv」 in 「盗梦空间 (2010)」.
    guard let movie = matchMediaFolder(parent, matcher, allowMovie: true, allowTv: false),
          name.hasPrefix(movie.title) else {
        return false
    }
    let requireYear = movie.year != nil && naming.movie.includeYear
    return !requireYear || name.contains(movie.year!)
}

/// Checks whether a `RemoteEntry` (file or folder) already follows an organized library layout
/// under `naming` (or default Tidyreel / Filmix layout).
public func looksOrganized(_ entry: RemoteEntry, naming: NamingProfile = .vidhub) -> Bool {
    let segs = entry.path
        .replacingOccurrences(of: "\\", with: "/")
        .split(separator: "/")
        .map(String.init)
        .filter { !$0.isEmpty }
    return checkOrganized(segs: segs, isDir: entry.isDir, naming: naming, allowUnanchoredNoYearDir: true)
}

/// Checks whether `fileName` inside `parentDirs` (nearest-to-farthest, matching `FilenameParser.parse`)
/// already follows an organized library layout under `naming`.
public func looksOrganized(
    fileName: String,
    parentDirs: [String],
    naming: NamingProfile = .vidhub
) -> Bool {
    let cleanFile = fileName.replacingOccurrences(of: "\\", with: "/")
    let fileSegs = cleanFile.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    let cleanParents = parentDirs
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    let segs: [String]
    if cleanParents.isEmpty && fileSegs.count > 1 {
        segs = fileSegs
    } else if let leaf = fileSegs.last {
        segs = Array(cleanParents.reversed()) + [leaf]
    } else {
        // Empty fileName with non-empty parentDirs checks the directory chain itself.
        guard !cleanParents.isEmpty else { return false }
        return checkOrganized(
            segs: Array(cleanParents.reversed()),
            isDir: true,
            naming: naming,
            allowUnanchoredNoYearDir: true
        )
    }

    if checkOrganized(segs: segs, isDir: false, naming: naming) {
        return true
    }

    // If `fileName` has no file extension at all (e.g. a folder name like `Season 01`, `BDMV`,
    // or `三体 (2023)` passed directly), also allow explicit structured folder patterns.
    if let leaf = segs.last, fileExtOf(leaf) == nil {
        return checkOrganized(
            segs: segs,
            isDir: true,
            naming: naming,
            allowUnanchoredNoYearDir: false
        )
    }
    return false
}
