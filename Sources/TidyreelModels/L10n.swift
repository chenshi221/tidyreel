import Foundation

public struct AppL10n: Equatable, Sendable {
    public let isEn: Bool

    public init(isEn: Bool) {
        self.isEn = isEn
    }

    public static let zh = AppL10n(isEn: false)
    public static let en = AppL10n(isEn: true)

    public var appTitle: String { tr("理片 Tidyreel", "Tidyreel") }
    public var rootDir: String { tr("根目录", "Root") }
    public var undo: String { tr("撤销", "Undo") }
    public var delete: String { tr("删除", "Delete") }
    public var cancel: String { tr("取消", "Cancel") }
    public var retry: String { tr("重试", "Retry") }
    public var close: String { tr("关闭", "Close") }
    public var edit: String { tr("编辑", "Edit") }
    public var refresh: String { tr("刷新", "Refresh") }
    public var more: String { tr("更多", "More") }
    public var ok: String { tr("确定", "OK") }
    public var clear: String { tr("清空", "Clear") }
    public var movie: String { tr("电影", "Movie") }
    public var tvShow: String { tr("剧集", "TV Show") }
    public var specials: String { tr("特典", "Specials") }

    public func tr(_ zhText: String, _ enText: String) -> String {
        isEn ? enText : zhText
    }

    public func coreMessage(_ raw: String) -> String {
        localizeCoreMessage(self, raw)
    }

    public func stageLabel(_ stage: TaskStage) -> String {
        switch stage {
        case .importing: return tr("导入", "Import")
        case .recognizing: return tr("识别", "Match")
        case .awaitingReview: return tr("待确认", "Review")
        case .renamingFiles: return tr("正在重命名文件", "Renaming files")
        case .renamingFolders: return tr("正在整理文件夹", "Organizing folders")
        case .done: return tr("已完成", "Done")
        case .partiallyFailed: return tr("部分失败", "Partial")
        case .cancelled: return tr("已取消", "Cancelled")
        case .undone: return tr("已撤销", "Undone")
        case .failed: return tr("失败", "Failed")
        }
    }

    public func organizeModeLabel(_ mode: OrganizeMode) -> String {
        switch mode {
        case .inPlace: return tr("原地整理", "In-place")
        case .moveToLibrary: return tr("移入媒体库", "Move to Library")
        }
    }

    public func connectionTypeLabel(_ type: ConnectionType) -> String {
        switch type {
        case .alist: return "Alist"
        case .webdav: return "WebDAV"
        case .smb: return "SMB"
        case .local: return tr("本地文件夹", "Local")
        }
    }

    public func mediaHintLabel(_ hint: MediaHint) -> String {
        switch hint {
        case .mixed: return tr("混合", "Mixed")
        case .anime: return tr("动漫", "Anime")
        case .tv: return tr("电视剧", "TV")
        case .movie: return tr("电影", "Movies")
        }
    }

    public func plural(_ count: Int, _ singular: String, _ pluralForm: String? = nil) -> String {
        let p = pluralForm ?? "\(singular)s"
        return count == 1 ? "1 \(singular)" : "\(count) \(p)"
    }

    public static func resolve(choice: AppLanguage, systemLanguageCode: String? = Locale.preferredLanguages.first) -> AppL10n {
        switch choice {
        case .zh: return .zh
        case .en: return .en
        case .system:
            let code = (systemLanguageCode ?? "zh").lowercased()
            return code.hasPrefix("zh") ? .zh : .en
        }
    }

    public static func defaultTmdbLanguage(systemLanguageTag: String? = Locale.preferredLanguages.first) -> String {
        let tag = (systemLanguageTag ?? "zh-Hans").lowercased()
        guard tag.hasPrefix("zh") else { return "en-US" }
        if tag.contains("hant") || tag.contains("tw") || tag.contains("hk") || tag.contains("mo") {
            return "zh-TW"
        }
        return "zh-CN"
    }

    public static func localizedPlayerPreset(_ player: TargetPlayer, isEn: Bool) -> NamingProfile {
        var base = NamingProfile.forPlayer(player)
        guard isEn else { return base }
        base.movie.titleLanguage = .englishFirst
        base.movie.bilingual = false
        base.tv.titleLanguage = .englishFirst
        base.tv.bilingual = false
        if base.movieDir == "电影" { base.movieDir = "Movies" }
        if base.tvDir == "剧集" { base.tvDir = "TV Shows" }
        return base
    }
}

private let exactCoreMessages: [String: String] = [
    "正在等待开始": "Waiting to start",
    "正在导入文件": "Importing files",
    "正在识别": "Matching metadata",
    "识别完成，请确认": "Ready for review",
    "正在重命名文件": "Renaming files",
    "正在重命名文件夹": "Renaming folders",
    "正在清理垃圾文件": "Cleaning junk files",
    "已完成": "Completed",
    "已取消": "Cancelled",
    "已撤销": "Undone",
    "没有选中的操作": "No operations selected",
    "存在命名冲突，请先处理冲突项": "Resolve naming conflicts before running",
    "请先在「设置」里填写 TMDB API key": "Please enter your TMDB API key in Settings first",
    "超出 TMDB 总集数": "Exceeds TMDB total episode count",
    "目标位置已存在同名文件或文件夹": "A file or folder already exists at the destination",
]

public func localizeCoreMessage(_ l10n: AppL10n, _ raw: String) -> String {
    guard !raw.isEmpty, l10n.isEn else { return raw }
    if let exact = exactCoreMessages[raw] { return exact }
    if raw.hasPrefix("正在导入文件（已导入 "), raw.hasSuffix(" 个）") {
        let n = raw.replacingOccurrences(of: "正在导入文件（已导入 ", with: "").replacingOccurrences(of: " 个）", with: "")
        return "Importing files (\(n) imported)"
    }
    if raw.hasPrefix("正在识别（共 "), raw.hasSuffix(" 个文件）") {
        let n = Int(raw.replacingOccurrences(of: "正在识别（共 ", with: "").replacingOccurrences(of: " 个文件）", with: "")) ?? 0
        return "Matching (\(l10n.plural(n, "file")))"
    }
    if raw.hasPrefix("有 "), raw.hasSuffix(" 个文件会被命名为同一个路径") {
        let n = raw.replacingOccurrences(of: "有 ", with: "").replacingOccurrences(of: " 个文件会被命名为同一个路径", with: "")
        return "\(n) files would be renamed to the same path"
    }
    return raw
}

public func isTmdbKeyError(_ msg: String) -> Bool {
    msg.contains("TMDB API key") || msg.contains("HTTP 401") || msg.contains("Invalid API key")
}
