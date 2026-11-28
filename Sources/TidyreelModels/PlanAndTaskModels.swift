import Foundation

// MARK: - Naming & Title Rules

public enum TargetPlayer: String, CaseIterable, Sendable {
    case vidhub
    case infuse
    case plex
    case jellyfin
}

public enum TitleLanguage: String, CaseIterable, Sendable {
    case chineseFirst
    case englishFirst
}

public enum ShowYearSource: String, CaseIterable, Sendable {
    case firstSeason
    case seasonAir
}

public enum EpisodeStyle: String, CaseIterable, Sendable {
    case upperPadded
    case lowerPadded
    case lowerShort
    case cross
    case lowerDotted
}

public enum NameField: String, CaseIterable, Sendable {
    case title
    case year
    case episode
    case episodeTitle
    case extraInfo
}

public struct NameRewrite: Equatable, Hashable, Sendable {
    public var pattern: String
    public var replacement: String

    public init(_ pattern: String, _ replacement: String) {
        self.pattern = pattern
        self.replacement = replacement
    }
}

public struct NamingOptions: Equatable, Hashable, Sendable {
    public var titleLanguage: TitleLanguage
    public var bilingual: Bool
    public var includeYear: Bool
    public var yearInParens: Bool
    public var showYear: ShowYearSource
    public var episodeStyle: EpisodeStyle
    public var episodeTitle: Bool
    public var extraInfo: Bool
    public var separator: String
    public var releaseGroup: Bool
    public var tmdbIdTag: Bool
    public var order: [NameField]
    public var folderTemplate: String
    public var seasonFolderTemplate: String
    public var singleSeasonFolder: Bool
    public var customTemplate: String?
    public var rewrites: [NameRewrite]

    public static let defaultOrder: [NameField] = [
        .title, .year, .episode, .episodeTitle, .extraInfo,
    ]

    public init(
        titleLanguage: TitleLanguage = .chineseFirst,
        bilingual: Bool = true,
        includeYear: Bool = true,
        yearInParens: Bool = false,
        showYear: ShowYearSource = .firstSeason,
        episodeStyle: EpisodeStyle = .upperPadded,
        episodeTitle: Bool = false,
        extraInfo: Bool = false,
        separator: String = ".",
        releaseGroup: Bool = false,
        tmdbIdTag: Bool = false,
        order: [NameField] = NamingOptions.defaultOrder,
        folderTemplate: String = "{title} ({year})",
        seasonFolderTemplate: String = "Season {season:02}",
        singleSeasonFolder: Bool = true,
        customTemplate: String? = nil,
        rewrites: [NameRewrite] = []
    ) {
        self.titleLanguage = titleLanguage
        self.bilingual = bilingual
        self.includeYear = includeYear
        self.yearInParens = yearInParens
        self.showYear = showYear
        self.episodeStyle = episodeStyle
        self.episodeTitle = episodeTitle
        self.extraInfo = extraInfo
        self.separator = separator
        self.releaseGroup = releaseGroup
        self.tmdbIdTag = tmdbIdTag
        self.order = order
        self.folderTemplate = folderTemplate
        self.seasonFolderTemplate = seasonFolderTemplate
        self.singleSeasonFolder = singleSeasonFolder
        self.customTemplate = customTemplate
        self.rewrites = rewrites
    }
}

public struct NamingProfile: Equatable, Hashable, Sendable {
    public var player: TargetPlayer
    public var movie: NamingOptions
    public var tv: NamingOptions
    public var movieDir: String
    public var tvDir: String

    public init(
        player: TargetPlayer = .vidhub,
        movie: NamingOptions = NamingOptions(),
        tv: NamingOptions = NamingOptions(),
        movieDir: String = "电影",
        tvDir: String = "剧集"
    ) {
        self.player = player
        self.movie = movie
        self.tv = tv
        self.movieDir = movieDir
        self.tvDir = tvDir
    }

    public static let vidhub = NamingProfile()

    public static func forPlayer(_ player: TargetPlayer) -> NamingProfile {
        switch player {
        case .vidhub:
            return .vidhub
        case .infuse:
            return NamingProfile(
                player: .infuse,
                movie: NamingOptions(bilingual: false, yearInParens: false, separator: "."),
                tv: NamingOptions(bilingual: false, yearInParens: false, separator: "."),
                movieDir: "电影",
                tvDir: "剧集"
            )
        case .plex:
            return NamingProfile(
                player: .plex,
                movie: NamingOptions(
                    bilingual: false,
                    yearInParens: true,
                    separator: " ",
                    tmdbIdTag: true,
                    folderTemplate: "{title} ({year})"
                ),
                tv: NamingOptions(
                    bilingual: false,
                    yearInParens: true,
                    episodeTitle: true,
                    separator: " ",
                    tmdbIdTag: true,
                    folderTemplate: "{title} ({year})",
                    seasonFolderTemplate: "Season {season:02}"
                ),
                movieDir: "Movies",
                tvDir: "TV Shows"
            )
        case .jellyfin:
            return NamingProfile(
                player: .jellyfin,
                movie: NamingOptions(
                    bilingual: false,
                    yearInParens: true,
                    separator: " ",
                    tmdbIdTag: true,
                    folderTemplate: "{title} ({year})"
                ),
                tv: NamingOptions(
                    bilingual: false,
                    yearInParens: true,
                    separator: " ",
                    tmdbIdTag: true,
                    folderTemplate: "{title} ({year})",
                    seasonFolderTemplate: "Season {season:02}"
                ),
                movieDir: "Movies",
                tvDir: "Shows"
            )
        }
    }
}

public struct TitlePin: Equatable, Hashable, Sendable {
    public var keyword: String
    public var match: Candidate

    public init(_ keyword: String, _ match: Candidate) {
        self.keyword = keyword
        self.match = match
    }
}

public struct TitleRules: Equatable, Hashable, Sendable {
    public var cleanups: [NameRewrite]
    public var pins: [TitlePin]

    public init(cleanups: [NameRewrite] = [], pins: [TitlePin] = []) {
        self.cleanups = cleanups
        self.pins = pins
    }
}

// MARK: - Scan, Plan, History & Tasks

public struct RemoteEntry: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var isDir: Bool
    public var size: Int64
    public var modified: Date?
    public var deleteIdentity: String?

    public init(
        path: String,
        name: String,
        isDir: Bool,
        size: Int64 = 0,
        modified: Date? = nil,
        deleteIdentity: String? = nil
    ) {
        self.path = path
        self.name = name
        self.isDir = isDir
        self.size = size
        self.modified = modified
        self.deleteIdentity = deleteIdentity
    }
}

public struct ScanFile: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var size: Int64
    public var role: FileRole
    public var parsed: ParsedName?
    public var isDiscDir: Bool
    public var deleteIdentity: String?

    public init(
        path: String,
        name: String,
        size: Int64,
        role: FileRole,
        parsed: ParsedName? = nil,
        isDiscDir: Bool = false,
        deleteIdentity: String? = nil
    ) {
        self.path = path
        self.name = name
        self.size = size
        self.role = role
        self.parsed = parsed
        self.isDiscDir = isDiscDir
        self.deleteIdentity = deleteIdentity
    }
}

public enum SeasonStrategy: String, CaseIterable, Sendable {
    case asParsed
    case splitSequential
    case splitKeepEpisode
    case mergeIntoOne
}

public enum OrganizeMode: String, CaseIterable, Sendable {
    case inPlace
    case moveToLibrary
}

public struct MediaGroup: Equatable, Hashable, Sendable, Identifiable {
    public var id: GroupId
    public var kind: MediaKind
    public var anchorTitle: String
    public var anchorYear: Int?
    public var rootDir: String
    public var files: [ScanFile]
    public var match: Candidate?
    public var matchScore: Double
    public var show: ShowDetail?
    public var suggestedStrategy: SeasonStrategy?
    public var suggestedStrategyReason: String?

    public init(
        id: GroupId,
        kind: MediaKind,
        anchorTitle: String,
        anchorYear: Int? = nil,
        rootDir: String,
        files: [ScanFile],
        match: Candidate? = nil,
        matchScore: Double = 0,
        show: ShowDetail? = nil,
        suggestedStrategy: SeasonStrategy? = nil,
        suggestedStrategyReason: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.anchorTitle = anchorTitle
        self.anchorYear = anchorYear
        self.rootDir = rootDir
        self.files = files
        self.match = match
        self.matchScore = matchScore
        self.show = show
        self.suggestedStrategy = suggestedStrategy
        self.suggestedStrategyReason = suggestedStrategyReason
    }
}

public struct ScanResult: Equatable, Sendable {
    public var connection: ConnectionId
    public var roots: [String]
    public var groups: [MediaGroup]
    public var unassigned: [ScanFile]

    public init(
        connection: ConnectionId,
        roots: [String],
        groups: [MediaGroup],
        unassigned: [ScanFile] = []
    ) {
        self.connection = connection
        self.roots = roots
        self.groups = groups
        self.unassigned = unassigned
    }
}

public struct FileOverride: Equatable, Hashable, Sendable {
    public var season: Int?
    public var episode: Int?
    public var kind: MediaKind?
    public var ignore: Bool

    public init(season: Int? = nil, episode: Int? = nil, kind: MediaKind? = nil, ignore: Bool = false) {
        self.season = season
        self.episode = episode
        self.kind = kind
        self.ignore = ignore
    }
}

public struct GroupDecision: Equatable, Sendable {
    public var match: Candidate?
    public var strategy: SeasonStrategy
    public var episodeOffset: Int
    public var episodeGroupId: String?
    public var overrides: [String: FileOverride]
    public var selected: Bool
    public var separate: Bool

    public init(
        match: Candidate? = nil,
        strategy: SeasonStrategy = .asParsed,
        episodeOffset: Int = 0,
        episodeGroupId: String? = nil,
        overrides: [String: FileOverride] = [:],
        selected: Bool = true,
        separate: Bool = false
    ) {
        self.match = match
        self.strategy = strategy
        self.episodeOffset = episodeOffset
        self.episodeGroupId = episodeGroupId
        self.overrides = overrides
        self.selected = selected
        self.separate = separate
    }
}

public struct PlanOptions: Equatable, Sendable {
    public var mode: OrganizeMode
    public var libraryRoot: String?
    public var naming: NamingProfile
    public var deleteJunk: Bool
    public var confidenceThreshold: Double
    public var scrape: Bool
    public var scrapeOnly: Bool
    public var overwriteNfo: Bool
    public var probeMedia: Bool
    public var unassignedDeletes: [String: Bool]

    public init(
        mode: OrganizeMode = .inPlace,
        libraryRoot: String? = nil,
        naming: NamingProfile = .vidhub,
        deleteJunk: Bool = false,
        confidenceThreshold: Double = 0.7,
        scrape: Bool = false,
        scrapeOnly: Bool = false,
        overwriteNfo: Bool = false,
        probeMedia: Bool = false,
        unassignedDeletes: [String: Bool] = [:]
    ) {
        self.mode = mode
        self.libraryRoot = libraryRoot
        self.naming = naming
        self.deleteJunk = deleteJunk
        self.confidenceThreshold = confidenceThreshold
        self.scrape = scrape
        self.scrapeOnly = scrapeOnly
        self.overwriteNfo = overwriteNfo
        self.probeMedia = probeMedia
        self.unassignedDeletes = unassignedDeletes
    }
}

public enum ExecPhase: String, CaseIterable, Sendable {
    case files
    case folders
    case cleanup
}

public enum OpKind: String, CaseIterable, Sendable {
    case mkdir
    case relocate
    case delete
    case healthDeleteFile
    case healthDeleteEmptyDirectory
    case write
}

public let writeTextPrefix = "text:"

public struct RenameOp: Equatable, Hashable, Sendable, Identifiable {
    public var id: OpId
    public var kind: OpKind
    public var phase: ExecPhase
    public var src: String
    public var dst: String
    public var group: GroupId?
    public var selected: Bool
    public var warning: String?
    public var overwrite: Bool
    public var deleteIdentity: String?

    public init(
        id: OpId,
        kind: OpKind,
        phase: ExecPhase,
        src: String,
        dst: String,
        group: GroupId? = nil,
        selected: Bool = true,
        warning: String? = nil,
        overwrite: Bool = false,
        deleteIdentity: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.phase = phase
        self.src = src
        self.dst = dst
        self.group = group
        self.selected = selected
        self.warning = warning
        self.overwrite = overwrite
        self.deleteIdentity = deleteIdentity
    }
}

public struct PlanConflict: Equatable, Hashable, Sendable {
    public var ops: [OpId]
    public var path: String
    public var reason: String

    public init(ops: [OpId], path: String, reason: String) {
        self.ops = ops
        self.path = path
        self.reason = reason
    }
}

public struct PlanMerge: Equatable, Hashable, Sendable {
    public var group: GroupId
    public var into: String
    public var exists: Bool
    public var withGroup: GroupId?
    public var seasons: [Int]

    public init(
        group: GroupId,
        into: String,
        exists: Bool,
        withGroup: GroupId? = nil,
        seasons: [Int] = []
    ) {
        self.group = group
        self.into = into
        self.exists = exists
        self.withGroup = withGroup
        self.seasons = seasons
    }
}

public struct RenamePlan: Equatable, Sendable {
    public var ops: [RenameOp]
    public var conflicts: [PlanConflict]
    public var merges: [PlanMerge]

    public init(
        ops: [RenameOp],
        conflicts: [PlanConflict] = [],
        merges: [PlanMerge] = []
    ) {
        self.ops = ops
        self.conflicts = conflicts
        self.merges = merges
    }

    public var canExecute: Bool { conflicts.isEmpty }
}

public enum OpStatus: String, CaseIterable, Sendable {
    case pending
    case done
    case failed
    case skipped
    case undone
}

public struct ExecProgress: Equatable, Sendable {
    public var phase: ExecPhase
    public var done: Int
    public var total: Int
    public var current: OpId?
    public var error: String?

    public init(
        phase: ExecPhase,
        done: Int,
        total: Int,
        current: OpId? = nil,
        error: String? = nil
    ) {
        self.phase = phase
        self.done = done
        self.total = total
        self.current = current
        self.error = error
    }
}

public enum RelocationCyclePhase: Int, Sendable {
    case parking = 1
    case landing
    case undoParking
    case undoLanding
    case planned
}

public struct HistoryRecord: Equatable, Sendable, Identifiable {
    public var id: String { "\(batch.value):\(op.id.value)" }
    public var batch: BatchId
    public var op: RenameOp
    public var status: OpStatus
    public var cyclePhase: RelocationCyclePhase?
    public var writtenDigest: String? = nil
    public var error: String?
    public var updatedAt: Date

    public init(
        batch: BatchId,
        op: RenameOp,
        status: OpStatus,
        cyclePhase: RelocationCyclePhase? = nil,
        writtenDigest: String? = nil,
        error: String? = nil,
        updatedAt: Date
    ) {
        self.batch = batch
        self.op = op
        self.status = status
        self.cyclePhase = cyclePhase
        self.writtenDigest = writtenDigest
        self.error = error
        self.updatedAt = updatedAt
    }
}

/// Completed operations in forward journal order, plus folder moves needed to locate their current paths.
public struct UndoSnapshot: Sendable {
    public let selected: [HistoryRecord]
    public let folderMoves: [RenameOp]

    public init(selected: [HistoryRecord], folderMoves: [RenameOp]) {
        self.selected = selected
        self.folderMoves = folderMoves
    }
}

public struct BatchSummary: Equatable, Sendable, Identifiable {
    public var id: BatchId
    public var task: TaskId
    public var connection: ConnectionId
    public var createdAt: Date
    public var total: Int
    public var done: Int
    public var failed: Int
    public var undone: Bool

    public init(
        id: BatchId,
        task: TaskId,
        connection: ConnectionId,
        createdAt: Date,
        total: Int,
        done: Int,
        failed: Int,
        undone: Bool = false
    ) {
        self.id = id
        self.task = task
        self.connection = connection
        self.createdAt = createdAt
        self.total = total
        self.done = done
        self.failed = failed
        self.undone = undone
    }
}

public enum TaskStage: String, CaseIterable, Sendable {
    case importing
    case recognizing
    case awaitingReview
    case renamingFiles
    case renamingFolders
    case done
    case partiallyFailed
    case cancelled
    case undone
    case failed

    public var isActive: Bool {
        switch self {
        case .importing, .recognizing, .awaitingReview, .renamingFiles, .renamingFolders:
            return true
        case .done, .partiallyFailed, .cancelled, .undone, .failed:
            return false
        }
    }
}

public func canRetry(_ t: TaskSummary) -> Bool {
    t.stage == .undone || ((t.stage == .cancelled || t.stage == .failed) && t.batch == nil)
}

public func canUndo(_ t: TaskSummary) -> Bool {
    t.batch != nil && !t.stage.isActive && t.stage != .undone
}

public struct TaskSummary: Equatable, Sendable, Identifiable {
    public var id: TaskId
    public var connection: ConnectionId
    public var paths: [String]
    public var mode: OrganizeMode
    public var scrape: Bool
    public var scrapeOnly: Bool
    public var stage: TaskStage
    public var message: String
    public var importedCount: Int
    public var videoCount: Int
    public var folderCount: Int
    public var subtitleCount: Int
    public var progress: Double?
    public var batch: BatchId?
    public var createdAt: Date

    public init(
        id: TaskId,
        connection: ConnectionId,
        paths: [String],
        mode: OrganizeMode,
        scrape: Bool = false,
        scrapeOnly: Bool = false,
        stage: TaskStage,
        message: String = "",
        importedCount: Int = 0,
        videoCount: Int = 0,
        folderCount: Int = 0,
        subtitleCount: Int = 0,
        progress: Double? = nil,
        batch: BatchId? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.connection = connection
        self.paths = paths
        self.mode = mode
        self.scrape = scrape
        self.scrapeOnly = scrapeOnly
        self.stage = stage
        self.message = message
        self.importedCount = importedCount
        self.videoCount = videoCount
        self.folderCount = folderCount
        self.subtitleCount = subtitleCount
        self.progress = progress
        self.batch = batch
        self.createdAt = createdAt
    }
}

public struct TaskReview: Equatable, Sendable {
    public var id: TaskId
    public var scan: ScanResult
    public var decisions: [GroupId: GroupDecision]
    public var preview: RenamePlan

    public init(
        id: TaskId,
        scan: ScanResult,
        decisions: [GroupId: GroupDecision],
        preview: RenamePlan
    ) {
        self.id = id
        self.scan = scan
        self.decisions = decisions
        self.preview = preview
    }
}

public struct StoredTaskReview: Equatable, Sendable {
    public var scan: ScanResult
    public var decisions: [GroupId: GroupDecision]
    public var unassignedDeletes: [String: Bool]

    public init(
        scan: ScanResult,
        decisions: [GroupId: GroupDecision] = [:],
        unassignedDeletes: [String: Bool] = [:]
    ) {
        self.scan = scan
        self.decisions = decisions
        self.unassignedDeletes = unassignedDeletes
    }
}

public struct StoredTask: Equatable, Sendable {
    public var summary: TaskSummary
    public var scan: ScanResult?
    public var decisions: [GroupId: GroupDecision]
    public var unassignedDeletes: [String: Bool]

    public init(
        summary: TaskSummary,
        scan: ScanResult? = nil,
        decisions: [GroupId: GroupDecision] = [:],
        unassignedDeletes: [String: Bool] = [:]
    ) {
        self.summary = summary
        self.scan = scan
        self.decisions = decisions
        self.unassignedDeletes = unassignedDeletes
    }
}

// MARK: - Storage Error

public enum StorageErrorCode: String, CaseIterable, Sendable {
    case notFound
    case alreadyExists
    case unauthorized
    case rateLimited
    case network
    case busy
    case other
}

public struct StorageError: Error, LocalizedError, Equatable, Sendable {
    public var code: StorageErrorCode
    public var message: String

    public init(_ code: StorageErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}
