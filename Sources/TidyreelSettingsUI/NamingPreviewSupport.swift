import Foundation
import TidyreelModels
import TidyreelPlanner

// MARK: - Target Player & Naming Enum Helpers

extension TargetPlayer {
    var displayName: String {
        switch self {
        case .vidhub: return "VidHub"
        case .infuse: return "Infuse"
        case .plex: return "Plex"
        case .jellyfin: return "Emby / Jellyfin"
        }
    }
}

extension EpisodeStyle {
    var exampleLabel: String {
        switch self {
        case .upperPadded: return "S01E02"
        case .lowerPadded: return "s01e02"
        case .lowerShort: return "s1e2"
        case .cross: return "1x02"
        case .lowerDotted: return "s01.e02"
        }
    }
}

extension NameField {
    func localizedLabel(_ l10n: AppL10n) -> String {
        switch self {
        case .title: return l10n.tr("标题", "Title")
        case .year: return l10n.tr("年份", "Year")
        case .episode: return l10n.tr("季集", "Season & Ep")
        case .episodeTitle: return l10n.tr("分集标题", "Episode Title")
        case .extraInfo: return l10n.tr("附加信息", "Extra Info")
        }
    }
}

// MARK: - Rendered Naming Value (With Empty-Template Validation)

struct RenderedNamingText: Equatable {
    let text: String?

    var isError: Bool { text == nil }

    func localizedDisplay(_ l10n: AppL10n) -> String {
        if let text { return text }
        return l10n.tr("（结果为空，请检查模板或替换规则）", "(Empty result — check template or rewrite rules)")
    }
}

// MARK: - Live Naming Samples & Scenarios (`naming_preview.dart`)

struct NamingSampleData: Equatable {
    let id: String
    let zhLabel: String
    let enLabel: String
    let originalFilename: String
    let ext: String
    let vars: [String: String]
    let firstSeasonYear: String
    let seasonAirYear: String
    let rawExtraInfo: String
    let isSingleSeasonShow: Bool
    let partLabel: String?

    func localizedLabel(_ l10n: AppL10n) -> String {
        l10n.isEn ? enLabel : zhLabel
    }

    static let tvScenarios: [NamingSampleData] = [
        NamingSampleData(
            id: "standard",
            zhLabel: "常规剧集",
            enLabel: "Standard",
            originalFilename: "老友记.1994.S02E03.2160p.Dolby.BluRay.x265.mp4",
            ext: "mp4",
            vars: [
                "title": "老友记",
                "original_title": "Friends",
                "en_title": "Friends",
                "season": "2",
                "episode": "3",
                "episode_title": "The One Where Phoebe Hates PBS",
                "tmdbid": "1668",
                "tmdb_tag": "{tmdb-1668}",
                "resolution": "2160p",
                "group": "EVO",
                "ext": "mp4",
            ],
            firstSeasonYear: "1994",
            seasonAirYear: "1995",
            rawExtraInfo: "2160p.Dolby",
            isSingleSeasonShow: false,
            partLabel: nil
        ),
        NamingSampleData(
            id: "multi-ep",
            zhLabel: "连集",
            enLabel: "Multi-Ep",
            originalFilename: "Severance.S01E01-E02.2160p.ATVP.WEB-DL.DDP5.1.DV-NTb.mkv",
            ext: "mkv",
            vars: [
                "title": "人生切割术",
                "original_title": "Severance",
                "en_title": "Severance",
                "season": "1",
                "episode": "1",
                "episode_end": "2",
                "episode_title": "Good News About Hell",
                "tmdbid": "95396",
                "tmdb_tag": "{tmdb-95396}",
                "resolution": "2160p",
                "group": "NTb",
                "ext": "mkv",
            ],
            firstSeasonYear: "2022",
            seasonAirYear: "2022",
            rawExtraInfo: "2160p.DV",
            isSingleSeasonShow: false,
            partLabel: nil
        ),
        NamingSampleData(
            id: "anime",
            zhLabel: "日漫单季",
            enLabel: "Anime",
            originalFilename: "[VCB-Studio] Sousou no Frieren [01][Ma10p_1080p][x265_flac].mkv",
            ext: "mkv",
            vars: [
                "title": "葬送的芙莉莲",
                "original_title": "葬送のフリーレン",
                "en_title": "Frieren",
                "season": "1",
                "episode": "1",
                "episode_title": "冒险的终点",
                "tmdbid": "209867",
                "tmdb_tag": "{tmdb-209867}",
                "resolution": "1080p",
                "group": "VCB-Studio",
                "ext": "mkv",
            ],
            firstSeasonYear: "2023",
            seasonAirYear: "2023",
            rawExtraInfo: "1080p",
            isSingleSeasonShow: true,
            partLabel: nil
        ),
        NamingSampleData(
            id: "donghua",
            zhLabel: "纯中文片名",
            enLabel: "Chinese Only",
            originalFilename: "漫长的季节.S01E01.2023.2160p.WEB-DL.H265-HHWEB.mp4",
            ext: "mp4",
            vars: [
                "title": "漫长的季节",
                "original_title": "漫长的季节",
                "en_title": "The Long Season",
                "season": "1",
                "episode": "1",
                "episode_title": "第一集",
                "tmdbid": "224938",
                "tmdb_tag": "{tmdb-224938}",
                "resolution": "2160p",
                "group": "HHWEB",
                "ext": "mp4",
            ],
            firstSeasonYear: "2023",
            seasonAirYear: "2023",
            rawExtraInfo: "2160p",
            isSingleSeasonShow: true,
            partLabel: nil
        ),
    ]

    static let movieScenarios: [NamingSampleData] = [
        NamingSampleData(
            id: "standard",
            zhLabel: "常规电影",
            enLabel: "Standard",
            originalFilename: "Inception.2010.2160p.BluRay.x265-EVO.mkv",
            ext: "mkv",
            vars: [
                "title": "盗梦空间",
                "original_title": "Inception",
                "en_title": "Inception",
                "year": "2010",
                "tmdbid": "27205",
                "tmdb_tag": "{tmdb-27205}",
                "resolution": "2160p",
                "group": "EVO",
                "ext": "mkv",
            ],
            firstSeasonYear: "2010",
            seasonAirYear: "2010",
            rawExtraInfo: "2160p.DV",
            isSingleSeasonShow: false,
            partLabel: nil
        ),
        NamingSampleData(
            id: "uhd",
            zhLabel: "4K 杜比视界",
            enLabel: "4K DV",
            originalFilename: "Dune.Part.Two.2024.2160p.UHD.BluRay.DV.HDR10+.Atmos-WiKi.mkv",
            ext: "mkv",
            vars: [
                "title": "沙丘2",
                "original_title": "Dune: Part Two",
                "en_title": "Dune Part Two",
                "year": "2024",
                "tmdbid": "693134",
                "tmdb_tag": "{tmdb-693134}",
                "resolution": "2160p",
                "group": "WiKi",
                "ext": "mkv",
            ],
            firstSeasonYear: "2024",
            seasonAirYear: "2024",
            rawExtraInfo: "2160p.DV.HDR10+.Atmos",
            isSingleSeasonShow: false,
            partLabel: nil
        ),
        NamingSampleData(
            id: "non-en",
            zhLabel: "非英语原名",
            enLabel: "Non-English",
            originalFilename: "Parasite.2019.2160p.UHD.BluRay.x265-FraMeSToR.mkv",
            ext: "mkv",
            vars: [
                "title": "寄生虫",
                "original_title": "기생충",
                "en_title": "Parasite",
                "year": "2019",
                "tmdbid": "496243",
                "tmdb_tag": "{tmdb-496243}",
                "resolution": "2160p",
                "group": "FraMeSToR",
                "ext": "mkv",
            ],
            firstSeasonYear: "2019",
            seasonAirYear: "2019",
            rawExtraInfo: "2160p.HDR",
            isSingleSeasonShow: false,
            partLabel: nil
        ),
        NamingSampleData(
            id: "edition",
            zhLabel: "导剪 / 分盘",
            enLabel: "Edition / Disc",
            originalFilename: "Inception.2010.Director's.Cut.CD1.1080p.BluRay.x264-CHD.mkv",
            ext: "mkv",
            vars: [
                "title": "盗梦空间",
                "original_title": "Inception",
                "en_title": "Inception",
                "year": "2010",
                "tmdbid": "27205",
                "tmdb_tag": "{tmdb-27205}",
                "resolution": "1080p",
                "version": "Director's Cut",
                "group": "CHD",
                "ext": "mkv",
            ],
            firstSeasonYear: "2010",
            seasonAirYear: "2010",
            rawExtraInfo: "1080p.Director's.Cut",
            isSingleSeasonShow: false,
            partLabel: "cd1"
        ),
    ]
}

struct RenderedNamingPreview: Equatable {
    let originalFilename: String
    let fileName: RenderedNamingText
    let typeDirectory: String
    let workFolder: RenderedNamingText
    /// Present when this scenario places files inside a season subfolder.
    let seasonFolder: RenderedNamingText?
    /// Rendered season folder name regardless of `singleSeasonFolder`, for helper captions.
    let seasonFolderSample: String?
    let compiledTemplate: String
}

enum NamingPreviewEngine {
    private static let sepRegex = try! NSRegularExpression(pattern: #"[._ ]+"#)

    private static func formatExtra(_ raw: String, separator: String) -> String {
        guard !raw.isEmpty else { return "" }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        return sepRegex.stringByReplacingMatches(in: raw, range: range, withTemplate: separator)
    }

    static func renderScenario(
        profile: NamingProfile,
        isMovie: Bool,
        scenario: NamingSampleData
    ) -> RenderedNamingPreview {
        let options = isMovie ? profile.movie : profile.tv
        var vars = scenario.vars

        // Ensure fallback to original_title when en_title is absent, and avoid duplicate bilingual titles
        // when Chinese and English titles are identical (e.g. pure English titles).
        let zh = vars["title"] ?? ""
        let en = vars["en_title"] ?? ""
        let orig = vars["original_title"] ?? ""
        let effectiveEn = !en.isEmpty ? en : orig
        if options.bilingual {
            if options.titleLanguage == .englishFirst {
                vars["en_title"] = effectiveEn
                vars["title"] = (zh != effectiveEn) ? zh : ((orig != effectiveEn) ? orig : "")
            } else {
                vars["title"] = !zh.isEmpty ? zh : effectiveEn
                let sec = (effectiveEn != vars["title"]) ? effectiveEn : ((orig != vars["title"]) ? orig : "")
                vars["en_title"] = sec
            }
        } else {
            vars["title"] = !zh.isEmpty ? zh : effectiveEn
            vars["en_title"] = !effectiveEn.isEmpty ? effectiveEn : zh
        }

        let formattedExtra = formatExtra(scenario.rawExtraInfo, separator: options.separator)
        vars["extra_info"] = formattedExtra
        if vars["version"] == nil {
            vars["version"] = formattedExtra
        }
        vars["year"] = isMovie
            ? scenario.firstSeasonYear
            : (options.showYear == .seasonAir ? scenario.seasonAirYear : scenario.firstSeasonYear)

        var folderVars = scenario.vars
        if options.titleLanguage == .englishFirst {
            if !en.isEmpty {
                folderVars["title"] = en
            } else if !orig.isEmpty {
                folderVars["title"] = orig
            }
        }
        folderVars["year"] = scenario.firstSeasonYear

        let tpl = compileTemplate(options, isMovie: isMovie)
        var rawBase = sanitizeName(
            applyRewrites(renderTemplate(tpl, vars: vars), rewrites: options.rewrites)
        )
        let renderedFile: RenderedNamingText
        if rawBase.isEmpty {
            renderedFile = RenderedNamingText(text: nil)
        } else {
            if let part = scenario.partLabel, !part.isEmpty {
                rawBase += "-\(sanitizeName(part))"
            }
            let suffix = ".\(scenario.ext.lowercased())"
            let finalFile = rawBase.lowercased().hasSuffix(suffix) ? rawBase : "\(rawBase).\(scenario.ext)"
            renderedFile = RenderedNamingText(text: finalFile)
        }

        let rawFolder = sanitizeName(
            applyRewrites(renderTemplate(options.folderTemplate, vars: folderVars), rewrites: options.rewrites)
        )
        let renderedFolder = RenderedNamingText(text: rawFolder.isEmpty ? nil : rawFolder)

        let rawTypeDir = sanitizeName(isMovie ? profile.movieDir : profile.tvDir)
        let typeDir = rawTypeDir.isEmpty ? (isMovie ? "Movies" : "TV Shows") : rawTypeDir

        let renderedSeason: RenderedNamingText?
        let seasonSample: String?
        if isMovie {
            renderedSeason = nil
            seasonSample = nil
        } else {
            let seasonNum = scenario.vars["season"] ?? "1"
            let rawSeason = sanitizeName(
                applyRewrites(
                    renderTemplate(options.seasonFolderTemplate, vars: ["season": seasonNum]),
                    rewrites: options.rewrites
                )
            )
            seasonSample = rawSeason.isEmpty ? nil : rawSeason
            if scenario.isSingleSeasonShow && !options.singleSeasonFolder {
                renderedSeason = nil
            } else {
                renderedSeason = RenderedNamingText(text: seasonSample)
            }
        }

        return RenderedNamingPreview(
            originalFilename: scenario.originalFilename,
            fileName: renderedFile,
            typeDirectory: typeDir,
            workFolder: renderedFolder,
            seasonFolder: renderedSeason,
            seasonFolderSample: seasonSample,
            compiledTemplate: tpl
        )
    }

    struct CustomTesterResult: Equatable {
        let parsed: ParsedName
        let isTv: Bool
        let renderedName: RenderedNamingText
    }

    static func previewCustomInput(
        rawInput: String,
        profile: NamingProfile,
        parser: any FilenameParser,
        fallbackIsTv: Bool
    ) -> CustomTesterResult? {
        let normalized = rawInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty else { return nil }

        let segments = normalized.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        let fileName = segments.last ?? normalized
        let parentDirs = segments.count > 1 ? Array(segments.dropLast().reversed()) : []
        let parsed = parser.parse(fileName, parentDirs: parentDirs)

        let isTv: Bool
        switch parsed.kind {
        case .episode, .special:
            isTv = true
        case .movie:
            isTv = false
        case .extra, .unknown:
            isTv = fallbackIsTv
        }

        let options = isTv ? profile.tv : profile.movie
        let rawExt = extOf(fileName)
        let ext = rawExt.isEmpty ? "mkv" : rawExt
        let rawTitle: String = {
            if let t = parsed.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                return t
            }
            return stem(fileName)
        }()

        var vars: [String: String] = [
            "original_title": rawTitle,
            "ext": ext,
        ]
        if options.bilingual {
            if options.titleLanguage == .englishFirst {
                vars["en_title"] = rawTitle
            } else {
                vars["title"] = rawTitle
            }
        } else {
            vars["title"] = rawTitle
            vars["en_title"] = rawTitle
        }

        if let y = parsed.year {
            vars["year"] = String(y)
        } else if let airDate = parsed.airDate {
            let yr = Calendar(identifier: .gregorian).component(.year, from: airDate)
            vars["year"] = String(yr)
        }

        let resolvedSeason: Int? = parsed.season ?? (isTv ? (parsed.kind == .special ? 0 : 1) : nil)
        if let resolvedSeason {
            vars["season"] = String(resolvedSeason)
        }
        if let ep = parsed.episodes.first ?? parsed.absolute {
            vars["episode"] = String(ep)
        }
        if parsed.episodes.count > 1,
           let firstEp = parsed.episodes.first,
           let lastEp = parsed.episodes.last,
           lastEp > firstEp {
            vars["episode_end"] = String(lastEp)
        }
        if let extId = parsed.externalId, extId.source.lowercased() == "tmdb" {
            vars["tmdbid"] = extId.id
            vars["tmdb_tag"] = "{tmdb-\(extId.id)}"
        }
        if let res = parsed.resolution {
            vars["resolution"] = res
        }
        if let extraRaw = parsed.extraInfo ?? parsed.resolution {
            let formatted = formatExtra(extraRaw, separator: options.separator)
            vars["extra_info"] = formatted
            vars["version"] = parsed.edition ?? formatted
        } else if let ed = parsed.edition {
            vars["version"] = ed
        }
        if let grp = parsed.group {
            vars["group"] = grp
        }
        if let lang = parsed.lang {
            vars["lang"] = lang
        }

        let tpl = compileTemplate(options, isMovie: !isTv)
        var base = sanitizeName(applyRewrites(renderTemplate(tpl, vars: vars), rewrites: options.rewrites))
        let rendered: RenderedNamingText
        if base.isEmpty {
            rendered = RenderedNamingText(text: nil)
        } else {
            if let part = parsed.partLabel, !part.isEmpty {
                base += "-\(sanitizeName(part))"
            }
            let targetFile = base.lowercased().hasSuffix(".\(ext.lowercased())") ? base : "\(base).\(ext)"
            rendered = RenderedNamingText(text: targetFile)
        }

        return CustomTesterResult(
            parsed: parsed,
            isTv: isTv,
            renderedName: rendered
        )
    }
}

// MARK: - Naming + TitleRules JSON Bundle (v1 Compatible with Flutter)

struct NamingExportBundle: Equatable {
    let naming: NamingProfile?
    let titleRules: TitleRules?

    static func encode(profile: NamingProfile, rules: TitleRules) -> String {
        let obj: [String: Any] = [
            "version": 1,
            "naming": TidyreelCodecs.namingProfileToDict(profile),
            "titleRules": TidyreelCodecs.titleRulesToDict(rules),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ raw: String, l10n: AppL10n) -> Result<NamingExportBundle, NamingBundleError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return .failure(NamingBundleError(l10n.tr("请先粘贴或选择 JSON 配置", "Paste or load a JSON configuration first")))
        }
        let parsedObj: Any
        do {
            parsedObj = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .failure(NamingBundleError(l10n.tr("JSON 语法有误：\(error.localizedDescription)", "Invalid JSON syntax: \(error.localizedDescription)")))
        }
        guard let map = parsedObj as? [String: Any] else {
            return .failure(NamingBundleError(l10n.tr("JSON 顶层必须是对象（{ ... }）", "Top-level JSON value must be an object ({ ... })")))
        }
        if let v = map["version"], !(v is NSNull) {
            guard let versionInt = (v as? NSNumber)?.intValue, versionInt == 1 else {
                return .failure(NamingBundleError(l10n.tr("不支持的配置版本（仅支持 version: 1）", "Unsupported config version (only version: 1 is supported)")))
            }
        }

        let hasNaming = map["naming"] != nil && !(map["naming"] is NSNull)
        let hasRules = map["titleRules"] != nil && !(map["titleRules"] is NSNull)
        guard hasNaming || hasRules else {
            return .failure(NamingBundleError(l10n.tr("缺少 \"naming\" 或 \"titleRules\" 配置字段", "Missing \"naming\" or \"titleRules\" field")))
        }

        var decodedNaming: NamingProfile?
        if hasNaming {
            guard let namingDict = map["naming"] as? [String: Any] else {
                return .failure(NamingBundleError(l10n.tr("字段 \"naming\" 必须为对象", "Field \"naming\" must be a JSON object")))
            }
            decodedNaming = TidyreelCodecs.namingProfileFromDict(namingDict)
        }

        var decodedRules: TitleRules?
        if hasRules {
            guard let rulesDict = map["titleRules"] as? [String: Any] else {
                return .failure(NamingBundleError(l10n.tr("字段 \"titleRules\" 必须为对象", "Field \"titleRules\" must be a JSON object")))
            }
            decodedRules = TidyreelCodecs.titleRulesFromDict(rulesDict)
        }

        return .success(NamingExportBundle(naming: decodedNaming, titleRules: decodedRules))
    }
}

struct NamingBundleError: Error, LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
