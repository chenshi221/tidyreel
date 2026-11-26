import Foundation

// MARK: - Health Models

public enum HealthCategory: String, CaseIterable, Sendable {
    case duplicates
    case missingAssets
    case cleanup

    public func localizedLabel(_ l10n: AppL10n) -> String {
        switch self {
        case .duplicates: return l10n.tr("重复", "Duplicates")
        case .missingAssets: return l10n.tr("缺元数据", "Missing Metadata")
        case .cleanup: return l10n.tr("待清理", "Cleanup")
        }
    }
}

public enum HealthScanPhase: String, CaseIterable, Sendable {
    case walking
    case probingDuplicates
    case checkingAssets
    case checkingCleanup
    case done

    public func localizedLabel(_ l10n: AppL10n) -> String {
        switch self {
        case .walking: return l10n.tr("正在扫描目录", "Scanning folders")
        case .probingDuplicates: return l10n.tr("正在比对重复片源", "Comparing duplicate files")
        case .checkingAssets: return l10n.tr("正在检查 NFO 与海报", "Checking NFO and artwork")
        case .checkingCleanup: return l10n.tr("正在扫描垃圾与空目录", "Checking junk files & empty folders")
        case .done: return l10n.tr("体检完成", "Health check complete")
        }
    }
}

public struct HealthScanProgress: Equatable, Sendable {
    public var phase: HealthScanPhase
    public var message: String
    public var dirsVisited: Int
    public var filesFound: Int
    public var fraction: Double?

    public init(
        phase: HealthScanPhase,
        message: String,
        dirsVisited: Int = 0,
        filesFound: Int = 0,
        fraction: Double? = nil
    ) {
        self.phase = phase
        self.message = message
        self.dirsVisited = dirsVisited
        self.filesFound = filesFound
        self.fraction = fraction
    }
}

public struct DuplicateMediaCopy: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var fileSize: Int64
    public var probe: MediaProbeInfo?
    public var parsedResolution: String?
    public var parsedExtraInfo: String?
    public var isDiscDir: Bool
    public var qualityRank: Int

    public init(
        path: String,
        name: String,
        fileSize: Int64,
        probe: MediaProbeInfo? = nil,
        parsedResolution: String? = nil,
        parsedExtraInfo: String? = nil,
        isDiscDir: Bool = false,
        qualityRank: Int
    ) {
        self.path = path
        self.name = name
        self.fileSize = fileSize
        self.probe = probe
        self.parsedResolution = parsedResolution
        self.parsedExtraInfo = parsedExtraInfo
        self.isDiscDir = isDiscDir
        self.qualityRank = qualityRank
    }

    public var qualityBadges: [String] {
        var badges: [String] = []
        var seen: Set<String> = []
        func add(_ raw: String?) {
            guard let raw else { return }
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            if seen.insert(t.lowercased()).inserted {
                badges.append(t)
            }
        }
        if isDiscDir { add("原盘") }
        add(probe?.resolution ?? parsedResolution)
        if let probe {
            add(probe.hdr)
            add(probe.audioCodec)
            if let ch = probe.audioChannels, ch > 0 {
                switch ch {
                case 8: add("7.1")
                case 6: add("5.1")
                case 2: add("2.0")
                default: add("\(ch)ch")
                }
            }
            add(probe.videoCodec)
        }
        if let extra = parsedExtraInfo, !extra.isEmpty {
            let parts = extra.components(separatedBy: CharacterSet(charactersIn: " ._"))
            for token in parts { add(token) }
        }
        return badges
    }

    public func localizedQualityBadges(_ l10n: AppL10n) -> [String] {
        qualityBadges.map { $0 == "原盘" ? l10n.tr("原盘", "Disc") : $0 }
    }

    public func localizedQualitySummary(_ l10n: AppL10n) -> String {
        let b = localizedQualityBadges(l10n)
        return b.isEmpty ? l10n.tr("未知画质", "Unknown quality") : b.joined(separator: " · ")
    }
}

public struct DuplicateMediaIssue: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var kind: MediaKind
    public var tmdbId: Int?
    public var season: Int?
    public var episode: Int?
    public var copies: [DuplicateMediaCopy]
    public var recommendedKeepPath: String

    public init(
        id: String,
        title: String,
        kind: MediaKind,
        tmdbId: Int? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        copies: [DuplicateMediaCopy],
        recommendedKeepPath: String
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.tmdbId = tmdbId
        self.season = season
        self.episode = episode
        self.copies = copies
        self.recommendedKeepPath = recommendedKeepPath
    }

    public var redundantCopies: [DuplicateMediaCopy] {
        copies.filter { $0.path != recommendedKeepPath && !$0.isDiscDir }
    }

    public var reclaimableBytes: Int64 {
        redundantCopies.reduce(0) { $0 + $1.fileSize }
    }
}

public struct MissingAssetIssue: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { folderPath }
    public var workTitle: String
    public var kind: MediaKind
    public var folderPath: String
    public var explicitTargetPaths: [String]
    public var missingNfo: Bool
    public var missingPoster: Bool

    public init(
        workTitle: String,
        kind: MediaKind,
        folderPath: String,
        targetPaths: [String] = [],
        missingNfo: Bool = false,
        missingPoster: Bool = false
    ) {
        self.workTitle = workTitle
        self.kind = kind
        self.folderPath = folderPath
        self.explicitTargetPaths = targetPaths
        self.missingNfo = missingNfo
        self.missingPoster = missingPoster
    }

    public var targetPaths: [String] {
        explicitTargetPaths.isEmpty ? [folderPath] : explicitTargetPaths
    }

    public var targetPath: String { targetPaths[0] }
}

public enum CleanupKind: String, CaseIterable, Sendable {
    case junkFile
    case emptyDir
}

public struct CleanupIssue: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var kind: CleanupKind
    public var size: Int64
    public var reason: String

    public init(path: String, name: String, kind: CleanupKind, size: Int64 = 0, reason: String) {
        self.path = path
        self.name = name
        self.kind = kind
        self.size = size
        self.reason = reason
    }
}

public struct HealthReport: Equatable, Sendable {
    public var connection: ConnectionId
    public var rootDir: String
    public var scannedAt: Date
    public var scannedDirs: Int
    public var scannedFiles: Int
    public var totalWorks: Int
    public var duplicates: [DuplicateMediaIssue]
    public var missingAssets: [MissingAssetIssue]
    public var cleanupItems: [CleanupIssue]
    public var skippedDirs: [String: String]

    public init(
        connection: ConnectionId,
        rootDir: String,
        scannedAt: Date,
        scannedDirs: Int,
        scannedFiles: Int,
        totalWorks: Int,
        duplicates: [DuplicateMediaIssue] = [],
        missingAssets: [MissingAssetIssue] = [],
        cleanupItems: [CleanupIssue] = [],
        skippedDirs: [String: String] = [:]
    ) {
        self.connection = connection
        self.rootDir = rootDir
        self.scannedAt = scannedAt
        self.scannedDirs = scannedDirs
        self.scannedFiles = scannedFiles
        self.totalWorks = totalWorks
        self.duplicates = duplicates
        self.missingAssets = missingAssets
        self.cleanupItems = cleanupItems
        self.skippedDirs = skippedDirs
    }

    public var duplicateReclaimableBytes: Int64 {
        duplicates.reduce(0) { $0 + $1.reclaimableBytes }
    }

    public var junkBytes: Int64 {
        cleanupItems.filter { $0.kind == .junkFile }.reduce(0) { $0 + $1.size }
    }

    public var totalReclaimableBytes: Int64 { duplicateReclaimableBytes + junkBytes }
    public var junkCount: Int { cleanupItems.filter { $0.kind == .junkFile }.count }
    public var emptyDirCount: Int { cleanupItems.filter { $0.kind == .emptyDir }.count }
    public var totalIssues: Int { duplicates.count + missingAssets.count + cleanupItems.count }

    public var firstNonEmptyCategory: HealthCategory? {
        if !duplicates.isEmpty { return .duplicates }
        if !missingAssets.isEmpty { return .missingAssets }
        if !cleanupItems.isEmpty { return .cleanup }
        return nil
    }

    public func withoutDeletedPaths(deletedFiles: Set<String> = [], deletedDirs: Set<String> = []) -> HealthReport {
        var nextDuplicates: [DuplicateMediaIssue] = []
        for d in duplicates {
            let remaining = d.copies.filter { !deletedFiles.contains($0.path) && !deletedDirs.contains($0.path) }
            if remaining.count >= 2 {
                let keep = remaining.contains(where: { $0.path == d.recommendedKeepPath })
                    ? d.recommendedKeepPath
                    : remaining[0].path
                var updated = d
                updated.copies = remaining
                updated.recommendedKeepPath = keep
                nextDuplicates.append(updated)
            }
        }
        let nextCleanup = cleanupItems.filter { !deletedFiles.contains($0.path) && !deletedDirs.contains($0.path) }
        var out = self
        out.scannedFiles = max(0, scannedFiles - deletedFiles.count)
        out.duplicates = nextDuplicates
        out.cleanupItems = nextCleanup
        return out
    }
}

// MARK: - App Settings & Map Models

public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case zh
    case en
}

public enum AppThemeMode: String, CaseIterable, Sendable {
    case system
    case light
    case dark
}

public enum AccentChoice: String, CaseIterable, Sendable {
    case rouge
    case indigo
    case azurite
    case bamboo
    case ink

    public var zhLabel: String {
        switch self {
        case .rouge: return "胭脂"
        case .indigo: return "黛蓝"
        case .azurite: return "石青"
        case .bamboo: return "竹青"
        case .ink: return "墨"
        }
    }

    public var enLabel: String {
        switch self {
        case .rouge: return "Rouge"
        case .indigo: return "Indigo"
        case .azurite: return "Azurite"
        case .bamboo: return "Bamboo"
        case .ink: return "Ink"
        }
    }

    public var lightHex: UInt32 {
        switch self {
        case .rouge: return 0xFF9D2933
        case .indigo: return 0xFF425066
        case .azurite: return 0xFF2E6F78
        case .bamboo: return 0xFF4F7D5B
        case .ink: return 0xFF221F1C
        }
    }

    public var darkHex: UInt32 {
        switch self {
        case .rouge: return 0xFFD0646C
        case .indigo: return 0xFF8E9DB8
        case .azurite: return 0xFF6FB1B9
        case .bamboo: return 0xFF8DBB98
        case .ink: return 0xFFE7E4DF
        }
    }

    public func localizedLabel(_ l10n: AppL10n) -> String {
        l10n.isEn ? enLabel : zhLabel
    }
}

public struct AppSettings: Equatable, Sendable {
    public var tmdbApiKey: String
    public var tmdbBaseUrl: String
    public var defaultMode: OrganizeMode
    public var autoDeleteJunk: Bool
    public var themeMode: AppThemeMode
    public var appLanguage: AppLanguage
    public var concurrency: Int
    public var requestsPerSecond: Int
    public var scanPreview: Bool
    public var tmdbLanguage: String
    public var confidenceThreshold: Double
    public var mediaHint: MediaHint
    public var probeMedia: Bool
    public var overwriteNfo: Bool
    public var enableBangumi: Bool
    public var reviewLeftWidth: Double
    public var reviewRightWidth: Double
    public var accent: AccentChoice
    public var sidebarCollapsed: Bool
    public var reduceMotion: Bool
    public var notifyRecognized: Bool
    public var notifyFinished: Bool
    public var mapZoomStyle: MapZoomStyle

    public init(
        tmdbApiKey: String = "",
        tmdbBaseUrl: String = "https://api.themoviedb.org/3",
        defaultMode: OrganizeMode = .inPlace,
        autoDeleteJunk: Bool = false,
        themeMode: AppThemeMode = .light,
        appLanguage: AppLanguage = .system,
        concurrency: Int = 4,
        requestsPerSecond: Int = 5,
        scanPreview: Bool = true,
        tmdbLanguage: String = "zh-CN",
        confidenceThreshold: Double = 0.7,
        mediaHint: MediaHint = .mixed,
        probeMedia: Bool = true,
        overwriteNfo: Bool = false,
        enableBangumi: Bool = true,
        reviewLeftWidth: Double = 312.0,
        reviewRightWidth: Double = 276.0,
        accent: AccentChoice = .rouge,
        sidebarCollapsed: Bool = false,
        reduceMotion: Bool = false,
        notifyRecognized: Bool = true,
        notifyFinished: Bool = true,
        mapZoomStyle: MapZoomStyle = .camera
    ) {
        self.tmdbApiKey = tmdbApiKey
        self.tmdbBaseUrl = tmdbBaseUrl
        self.defaultMode = defaultMode
        self.autoDeleteJunk = autoDeleteJunk
        self.themeMode = themeMode
        self.appLanguage = appLanguage
        self.concurrency = concurrency
        self.requestsPerSecond = requestsPerSecond
        self.scanPreview = scanPreview
        self.tmdbLanguage = tmdbLanguage
        self.confidenceThreshold = confidenceThreshold
        self.mediaHint = mediaHint
        self.probeMedia = probeMedia
        self.overwriteNfo = overwriteNfo
        self.enableBangumi = enableBangumi
        self.reviewLeftWidth = reviewLeftWidth
        self.reviewRightWidth = reviewRightWidth
        self.accent = accent
        self.sidebarCollapsed = sidebarCollapsed
        self.reduceMotion = reduceMotion
        self.notifyRecognized = notifyRecognized
        self.notifyFinished = notifyFinished
        self.mapZoomStyle = mapZoomStyle
    }
}

public enum MapZoomStyle: String, CaseIterable, Sendable {
    case camera
    case semantic
}

public struct CachedFolderRecord: Equatable, Sendable {
    public var dirPath: String
    public var entries: [RemoteEntry]
    public var complete: Bool
    public var scannedAt: Date

    public init(dirPath: String, entries: [RemoteEntry], complete: Bool, scannedAt: Date) {
        self.dirPath = dirPath
        self.entries = entries
        self.complete = complete
        self.scannedAt = scannedAt
    }
}

/// Lightweight per-task summary of recognized TMDB works and unassigned count,
/// decoded once off the main thread so task cards and recent posters render
/// synchronously with zero main-thread JSON decoding or retained `ScanResult` arrays.
public struct TaskCardMeta: Equatable, Sendable {
    public var works: [Candidate]
    public var unassignedCount: Int

    public init(works: [Candidate] = [], unassignedCount: Int = 0) {
        self.works = works
        self.unassignedCount = unassignedCount
    }

    public static func isRecognizedStage(_ stage: TaskStage) -> Bool {
        switch stage {
        case .importing, .recognizing, .cancelled, .failed:
            return false
        case .awaitingReview, .renamingFiles, .renamingFolders, .done, .partiallyFailed, .undone:
            return true
        }
    }

    public static func from(scan: ScanResult, decisions: [GroupId: GroupDecision]) -> TaskCardMeta {
        var seen = Set<Int>()
        var works: [Candidate] = []
        for group in scan.groups {
            if let match = decisions[group.id]?.match ?? group.match {
                if seen.insert(match.tmdbId).inserted {
                    works.append(
                        Candidate(
                            tmdbId: match.tmdbId,
                            kind: match.kind,
                            title: match.title,
                            year: match.year,
                            posterPath: match.posterPath
                        )
                    )
                }
            }
        }
        return TaskCardMeta(works: works, unassignedCount: scan.unassigned.count)
    }
}
