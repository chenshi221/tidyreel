import Dispatch
import Foundation
import Observation
import TidyreelExecution
import TidyreelFakes
import TidyreelMetadata
import TidyreelModels
import TidyreelParser
import TidyreelPersistence
import TidyreelPlanner
import TidyreelProbe
import TidyreelStorage

public enum AppTab: String, CaseIterable, Hashable, Sendable {
    case sources
    case tasks
    case health
    case naming
    case settings
}

public enum TasksRoute: Equatable, Hashable, Sendable {
    case detail(TaskId)
    case review(TaskId)
}

public enum ConnectionPingState: Equatable, Sendable {
    case unknown
    case checking
    case online
    case unauthorized(String)
    case offline(String)
}

public struct BrowserJumpRequest: Equatable, Sendable {
    public let id: UUID
    public let connectionId: ConnectionId
    public let path: String

    public init(id: UUID = UUID(), connectionId: ConnectionId, path: String) {
        self.id = id
        self.connectionId = connectionId
        self.path = path
    }
}

public struct ToastNotice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var message: String
    public var actionLabel: String?
    public var destinationTab: AppTab?
    public var tasksRoute: TasksRoute?
    public var onAction: (@MainActor @Sendable () -> Void)?

    public init(
        id: UUID = UUID(),
        message: String,
        actionLabel: String? = nil,
        destinationTab: AppTab? = nil,
        tasksRoute: TasksRoute? = nil,
        onAction: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.id = id
        self.message = message
        self.actionLabel = actionLabel
        self.destinationTab = destinationTab
        self.tasksRoute = tasksRoute
        self.onAction = onAction
    }

    public static func == (lhs: ToastNotice, rhs: ToastNotice) -> Bool {
        lhs.id == rhs.id &&
            lhs.message == rhs.message &&
            lhs.actionLabel == rhs.actionLabel &&
            lhs.destinationTab == rhs.destinationTab &&
            lhs.tasksRoute == rhs.tasksRoute
    }
}

/// Thread-safe snapshot box shared with background engine closures so `@MainActor` `AppStore`
/// mutations immediately propagate to background `DefaultTaskManager`, `AnchorRecognizer`,
/// `DefaultExecutor`, and `ThrottledBackend` without actor hops in synchronous callbacks.
public final class EngineRuntimeConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _settings: AppSettings
    private var _connections: [ConnectionConfig]
    private var _namingProfile: NamingProfile
    private var _titleRules: TitleRules
    private let _secrets: FileSecretStore
    private let _builtInTmdbToken: String
    private var _backendPool: [String: CachedBackend] = [:]
    private var _tmdbKeyCache: (key: String, baseUrl: String, lang: String, provider: TmdbProvider)?

    init(
        settings: AppSettings,
        connections: [ConnectionConfig],
        namingProfile: NamingProfile,
        titleRules: TitleRules,
        secrets: FileSecretStore,
        builtInTmdbToken: String
    ) {
        self._settings = settings
        self._connections = connections
        self._namingProfile = namingProfile
        self._titleRules = titleRules
        self._secrets = secrets
        self._builtInTmdbToken = builtInTmdbToken
    }

    public var settings: AppSettings {
        lock.lock(); defer { lock.unlock() }
        return _settings
    }

    public var connections: [ConnectionConfig] {
        lock.lock(); defer { lock.unlock() }
        return _connections
    }

    public var namingProfile: NamingProfile {
        lock.lock(); defer { lock.unlock() }
        return _namingProfile
    }

    public var titleRules: TitleRules {
        lock.lock(); defer { lock.unlock() }
        return _titleRules
    }

    func update(
        settings: AppSettings? = nil,
        connections: [ConnectionConfig]? = nil,
        namingProfile: NamingProfile? = nil,
        titleRules: TitleRules? = nil
    ) {
        var staleBackends: [CachedBackend] = []
        lock.lock()
        if let settings { _settings = settings }
        if let connections {
            _connections = connections
            let activeKeys = Set(connections.map { Self.poolKey(config: $0, creds: _secrets.readCredentials(for: $0.id)) })
            for (k, be) in _backendPool where !activeKeys.contains(k) {
                staleBackends.append(be)
                _backendPool.removeValue(forKey: k)
            }
        }
        if let namingProfile { _namingProfile = namingProfile }
        if let titleRules { _titleRules = titleRules }
        lock.unlock()
        if !staleBackends.isEmpty {
            Task {
                for be in staleBackends { await be.close() }
            }
        }
    }

    func invalidateBackend(for id: ConnectionId) {
        var stale: [CachedBackend] = []
        lock.lock()
        let prefix = "\(id.value)#"
        for (k, be) in _backendPool where k.hasPrefix(prefix) {
            stale.append(be)
            _backendPool.removeValue(forKey: k)
        }
        lock.unlock()
        if !stale.isEmpty {
            Task {
                for be in stale { await be.close() }
            }
        }
    }

    private static func poolKey(config: ConnectionConfig, creds: Credentials) -> String {
        let dirs = creds.dirPasswords.keys.sorted().map { "\($0)=\(creds.dirPasswords[$0] ?? "")" }.joined(separator: "&")
        return "\(config.id.value)#\(config.type.rawValue)#\(config.endpoint)#\(config.username ?? "")#\(creds.password ?? "")#\(dirs)"
    }

    func backend(for id: ConnectionId, demoBackend: (any StorageBackend)?) throws -> any StorageBackend {
        lock.lock()
        guard let config = _connections.first(where: { $0.id == id }) else {
            lock.unlock()
            throw StorageError(.notFound, "连接不存在：\(id.value)")
        }
        if let demoBackend {
            lock.unlock()
            return demoBackend
        }
        let creds = _secrets.readCredentials(for: id)
        let key = Self.poolKey(config: config, creds: creds)
        if let existing = _backendPool[key] {
            lock.unlock()
            return existing
        }
        let raw = createStorageBackend(config: config, credentials: creds)
        let paced: any StorageBackend
        if config.type == .local {
            paced = raw
        } else {
            paced = ThrottledBackend(raw, minIntervalMs: { [weak self] in
                let rps = max(1, self?.settings.requestsPerSecond ?? 5)
                return 1000 / rps
            })
        }
        let cached = CachedBackend(paced)
        _backendPool[key] = cached
        lock.unlock()
        return cached
    }

    func metadataProvider(tmdbCache: (any TmdbResponseCache)?, isDemo: Bool) -> any MetadataProvider {
        if isDemo { return FakeMetadataProvider.demo() }
        lock.lock()
        let s = _settings
        let userKey = s.tmdbApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveKey = userKey.isEmpty ? _builtInTmdbToken : userKey
        if effectiveKey.isEmpty {
            lock.unlock()
            return MissingKeyMetadataProvider()
        }
        let rawBase = s.tmdbBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseUrl = rawBase.isEmpty ? "https://api.themoviedb.org/3" : rawBase
        let lang = s.tmdbLanguage.isEmpty ? "zh-CN" : s.tmdbLanguage
        if let cached = _tmdbKeyCache,
           cached.key == effectiveKey,
           cached.baseUrl == baseUrl,
           cached.lang == lang {
            lock.unlock()
            return cached.provider
        }
        let oldProvider = _tmdbKeyCache?.provider
        let provider = TmdbProvider(
            config: TmdbConfig(
                apiKey: effectiveKey,
                baseUrl: baseUrl,
                language: lang,
                fallbackLanguage: lang == "en-US" ? "zh-CN" : "en-US"
            ),
            cache: tmdbCache
        )
        _tmdbKeyCache = (effectiveKey, baseUrl, lang, provider)
        lock.unlock()
        if let oldProvider {
            Task { await oldProvider.close() }
        }
        return provider
    }

    func clearMetadataAndBackendCaches() async {
        let (provider, backends): (TmdbProvider?, [CachedBackend]) = lock.withLock {
            (_tmdbKeyCache?.provider, Array(_backendPool.values))
        }
        if let provider {
            await provider.clearMemoryCache()
        }
        for backend in backends {
            await backend.clear()
        }
    }
}

private struct MissingKeyMetadataProvider: MetadataProvider, ExternalIdLookup, Sendable {
    private func fail() throws -> Never {
        throw TmdbError(statusCode: 401, message: "请先在「设置」里填写 TMDB API key")
    }
    func search(_ query: String, kind: MediaKind?, year: Int?) async throws -> [Candidate] { try fail() }
    func show(_ tmdbId: Int) async throws -> ShowDetail { try fail() }
    func season(_ tmdbId: Int, season: Int) async throws -> [Episode] { try fail() }
    func episodeGroups(_ tmdbId: Int) async throws -> [EpisodeGroup] { try fail() }
    func movie(_ tmdbId: Int) async throws -> MovieDetail { try fail() }
    func findByExternalId(source: String, id: String, kind: MediaKind?) async throws -> Candidate? { try fail() }
}

private final class DynamicMetadataProxy: MetadataProvider, ExternalIdLookup, Sendable {
    private let resolve: @Sendable () -> any MetadataProvider
    init(_ resolve: @escaping @Sendable () -> any MetadataProvider) { self.resolve = resolve }

    func search(_ query: String, kind: MediaKind?, year: Int?) async throws -> [Candidate] {
        try await resolve().search(query, kind: kind, year: year)
    }
    func show(_ tmdbId: Int) async throws -> ShowDetail { try await resolve().show(tmdbId) }
    func season(_ tmdbId: Int, season: Int) async throws -> [Episode] { try await resolve().season(tmdbId, season: season) }
    func episodeGroups(_ tmdbId: Int) async throws -> [EpisodeGroup] { try await resolve().episodeGroups(tmdbId) }
    func movie(_ tmdbId: Int) async throws -> MovieDetail { try await resolve().movie(tmdbId) }
    func findByExternalId(source: String, id: String, kind: MediaKind?) async throws -> Candidate? {
        guard let lookup = resolve() as? any ExternalIdLookup else { return nil }
        return try await lookup.findByExternalId(source: source, id: id, kind: kind)
    }
}

private final class DynamicAltTitleProxy: AltTitleSource, Sendable {
    private let bangumi: BangumiTitles
    private let anilist: AniListTitles
    private let enableBangumi: @Sendable () -> Bool

    init(
        cache: (any TmdbResponseCache)? = nil,
        enableBangumi: @escaping @Sendable () -> Bool
    ) {
        self.bangumi = BangumiTitles(cache: cache)
        self.anilist = AniListTitles(cache: cache)
        self.enableBangumi = enableBangumi
    }

    func altTitles(_ query: String) async -> [String] {
        if enableBangumi() {
            return await CompositeAltTitleSource([bangumi, anilist]).altTitles(query)
        }
        return await anilist.altTitles(query)
    }

    func clearCache() async {
        await bangumi.clearCache()
        await anilist.clearCache()
    }
}

private enum ExecutorArtworkFetcher {
    private static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static func isTmdbArtworkURL(_ url: URL, tmdbBaseUrl: String) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "image.tmdb.org" { return true }
        let trimmedBase = tmdbBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBase.isEmpty,
           let baseHost = URL(string: trimmedBase)?.host?.lowercased(),
           baseHost == host {
            let path = url.path.lowercased()
            if path.contains("/t/p/")
                || path.hasSuffix(".jpg")
                || path.hasSuffix(".jpeg")
                || path.hasSuffix(".png")
                || path.hasSuffix(".webp") {
                return true
            }
        }
        return false
    }

    static func fetch(
        url: URL,
        tmdbBaseUrl: String,
        fetchArtworkBytes: (@Sendable (URL) async -> Data?)? = nil
    ) async throws -> Data {
        if isTmdbArtworkURL(url, tmdbBaseUrl: tmdbBaseUrl),
           let fetchArtworkBytes,
           let cached = await fetchArtworkBytes(url),
           !cached.isEmpty {
            return cached
        }
        return try await ArtworkDownload.fetchBytes(url, session: downloadSession)
    }
}

@MainActor
private final class WeakAppStoreBox {
    weak var store: AppStore?
}

/// Central `@Observable @MainActor` coordinator for the pure-Swift macOS Tidyreel app.
/// Uses fine-grained `@Observable` property tracking so views only re-render on fields they read.
@Observable
@MainActor
public final class AppStore {
    public static let appVersion = "1.0.0"
    public static let appBuild = 10

    // Navigation & UI Chrome
    public var selectedTab: AppTab = .sources
    public var tasksRoute: TasksRoute? = nil
    public var taskDetailOpenedFromSources: Bool = false
    public var openConnectionId: ConnectionId? = nil {
        didSet {
            if let old = oldValue, old != openConnectionId, let scanner = sizeScanners[old] {
                Task {
                    await scanner.cancel()
                    await scanner.releaseMemoryCache()
                }
            }
        }
    }
    public var browserJumpRequest: BrowserJumpRequest? = nil
    /// Ephemeral session sidebar collapsed toggle (seeded from `settings.sidebarCollapsed`, matching `sidebar.dart`).
    public var isSidebarCollapsed: Bool
    public var isCommandPalettePresented: Bool = false
    public var activeToast: ToastNotice? = nil
    /// Incremented whenever `clearCaches()` finishes so feature controllers (e.g. Health) can drop stale reports.
    public var cacheClearEpoch: Int = 0

    // Persisted Domain State
    public private(set) var settings: AppSettings
    public private(set) var connections: [ConnectionConfig]
    public private(set) var namingProfile: NamingProfile
    public private(set) var titleRules: TitleRules

    // Live Engine State
    public private(set) var tasks: [TaskSummary] = []
    /// Derived sidebar counters stored separately so progress ticks don't invalidate `SidebarView`.
    public private(set) var pendingReviewCount: Int = 0
    public private(set) var hasRunningTasks: Bool = false
    /// Lightweight per-task poster & work-title metadata decoded off the main thread.
    public private(set) var taskCardMeta: [TaskId: TaskCardMeta] = [:]
    public private(set) var connectionStatuses: [ConnectionId: ConnectionPingState] = [:]

    // Underlying Stores & Engine
    public let isDemoMode: Bool
    public let builtInTmdbToken: String
    public let parser = RuleBasedParser()
    public let mediaProbe: any MediaProbe
    public let mediaProbeCache: SQLiteMediaProbeCache?
    public let database: SQLiteDatabase
    public let prefsStore: JsonPrefsStore
    public let secretStore: FileSecretStore
    public let historyStore: any HistoryStore
    public let taskStore: any TaskStore
    public let sqliteTaskStore: SQLiteTaskStore
    public let folderStatsStore: SQLiteFolderStatsStore?
    public let tmdbCache: SQLiteTmdbCache?
    public let taskManager: any TaskManager

    private let configBox: EngineRuntimeConfigBox
    private let altTitleProxy: DynamicAltTitleProxy?
    private let demoBackend: (any StorageBackend)?
    private let clearArtworkCache: (@Sendable () async -> Void)?
    private var sizeScanners: [ConnectionId: SizeScannerActor] = [:]
    private var watchTasksHandle: Task<Void, Never>?
    private var previousTaskStages: [TaskId: TaskStage] = [:]
    private var loadingCardMetaIds: Set<TaskId> = []
    private var isShutDown: Bool = false

    public var l10n: AppL10n {
        AppL10n.resolve(choice: settings.appLanguage)
    }

    public static func openLive(
        builtInTmdbToken: String = "",
        fetchArtworkBytes: (@Sendable (URL) async -> Data?)? = nil,
        clearArtworkCache: (@Sendable () async -> Void)? = nil
    ) throws -> AppStore {
        let supportDir = try AppSupportPaths.directoryURL(createIfMissing: true)
        let dbURL = try AppSupportPaths.databaseURL(in: supportDir, createDirectory: true)
        let prefsURL = try AppSupportPaths.prefsURL(in: supportDir, createDirectory: true)
        let secretsURL = try AppSupportPaths.secretsURL(in: supportDir, createDirectory: true)
        let legacyTmdbURL = try AppSupportPaths.legacyTmdbCacheURL(in: supportDir)

        let db = try SQLiteDatabase(url: dbURL)
        let prefs = JsonPrefsStore(fileURL: prefsURL, flushDebounceMs: 200)
        let secrets = FileSecretStore(fileURL: secretsURL, flushDebounceMs: 200)
        let tmdbCache = SQLiteTmdbCache(db: db)
        let mediaProbeCache = SQLiteMediaProbeCache(db: db)

        // Migrate legacy 1MB tmdb_cache.json in background without blocking cold start!
        Task.detached(priority: .utility) {
            await tmdbCache.importLegacyJsonFileIfNeeded(at: legacyTmdbURL)
        }

        return AppStore(
            db: db,
            prefs: prefs,
            secrets: secrets,
            tmdbCache: tmdbCache,
            mediaProbeCache: mediaProbeCache,
            builtInTmdbToken: builtInTmdbToken,
            isDemoMode: false,
            fetchArtworkBytes: fetchArtworkBytes,
            clearArtworkCache: clearArtworkCache
        )
    }

    public static func makeDemo() throws -> AppStore {
        let db = try SQLiteDatabase.inMemory()
        return AppStore(
            db: db,
            prefs: .memory(),
            secrets: .memory(),
            tmdbCache: nil,
            mediaProbeCache: nil,
            builtInTmdbToken: "",
            isDemoMode: true
        )
    }

    public init(
        db: SQLiteDatabase,
        prefs: JsonPrefsStore,
        secrets: FileSecretStore,
        tmdbCache: SQLiteTmdbCache?,
        mediaProbeCache: SQLiteMediaProbeCache? = nil,
        builtInTmdbToken: String = "",
        isDemoMode: Bool = false,
        fetchArtworkBytes: (@Sendable (URL) async -> Data?)? = nil,
        clearArtworkCache: (@Sendable () async -> Void)? = nil
    ) {
        self.database = db
        self.prefsStore = prefs
        self.secretStore = secrets
        self.tmdbCache = tmdbCache
        self.builtInTmdbToken = builtInTmdbToken
        self.isDemoMode = isDemoMode
        self.clearArtworkCache = clearArtworkCache

        let resolvedProbeCache = mediaProbeCache ?? (isDemoMode ? nil : SQLiteMediaProbeCache(db: db))
        self.mediaProbeCache = resolvedProbeCache
        let resolvedMediaProbe: any MediaProbe = if let resolvedProbeCache {
            CachingMediaProbe(inner: ContainerMediaProbe(), cache: resolvedProbeCache)
        } else {
            ContainerMediaProbe()
        }
        self.mediaProbe = resolvedMediaProbe

        let defaultLang = AppL10n.defaultTmdbLanguage()
        let savedKey = secrets.readTmdbApiKey() ?? ""
        let loadedSettings = prefs.loadSettings(tmdbApiKey: savedKey, defaultTmdbLang: defaultLang)
        let loadedConns: [ConnectionConfig]
        if isDemoMode {
            let savedConns = prefs.loadConnections()
            loadedConns = savedConns.isEmpty ? [
                ConnectionConfig(
                    id: "demo-alist",
                    name: "演示 Alist",
                    type: .alist,
                    endpoint: "http://nas.local:5244",
                    username: "admin",
                    libraryRoot: "/影视库",
                    favorites: ["/下载/完成"]
                ),
                ConnectionConfig(
                    id: "demo-local",
                    name: "演示本地",
                    type: .local,
                    endpoint: "/Users/me/Downloads"
                ),
            ] : savedConns
        } else {
            loadedConns = prefs.loadConnections()
        }
        let defaultNaming = AppL10n.resolve(choice: loadedSettings.appLanguage).isEn
            ? AppL10n.localizedPlayerPreset(.vidhub, isEn: true)
            : NamingProfile.vidhub
        let loadedNaming = prefs.loadNamingProfile(default: defaultNaming)
        let loadedRules = prefs.loadTitleRules()

        self.settings = loadedSettings
        self.isSidebarCollapsed = loadedSettings.sidebarCollapsed
        self.connections = loadedConns
        self.namingProfile = loadedNaming
        self.titleRules = loadedRules

        let demoBe: (any StorageBackend)? = isDemoMode ? MemoryStorageBackend(initialSizes: [
            "/下载/完成/异兽魔都 2020 1080p/[Sub] Dorohedoro S01E01 [1080p].mkv": 1 << 30,
            "/下载/完成/异兽魔都 2020 1080p/[Sub] Dorohedoro S01E01 [1080p].chs.ass": 40_000,
            "/下载/完成/异兽魔都 2020 1080p/[Sub] Dorohedoro S01E02 [1080p].mkv": 1 << 30,
            "/下载/完成/Inception.2010.2160p.BluRay.x265.mkv": 2 << 30,
            "/下载/完成/更多资源请访问 www.example.com.txt": 120,
        ]) : nil
        self.demoBackend = demoBe

        let box = EngineRuntimeConfigBox(
            settings: loadedSettings,
            connections: loadedConns,
            namingProfile: loadedNaming,
            titleRules: loadedRules,
            secrets: secrets,
            builtInTmdbToken: builtInTmdbToken
        )
        self.configBox = box

        let hist = SQLiteHistoryStore(db: db)
        let tStore = SQLiteTaskStore(db: db)
        let fStore = SQLiteFolderStatsStore(db: db)
        self.historyStore = hist
        self.taskStore = tStore
        self.sqliteTaskStore = tStore
        self.folderStatsStore = fStore

        let metaProxy = DynamicMetadataProxy { [box, tmdbCache, isDemoMode] in
            box.metadataProvider(tmdbCache: tmdbCache, isDemo: isDemoMode)
        }
        let altProxy: DynamicAltTitleProxy? = isDemoMode ? nil : DynamicAltTitleProxy(
            cache: tmdbCache,
            enableBangumi: { [box] in box.settings.enableBangumi }
        )
        self.altTitleProxy = altProxy

        let recognizer = AnchorRecognizer(
            parser: RuleBasedParser(),
            metadata: metaProxy,
            altTitles: altProxy,
            hint: { [box] in box.settings.mediaHint },
            titleRules: { [box] in box.titleRules },
            mediaProbe: resolvedMediaProbe,
            probeMedia: { [box] in box.settings.probeMedia }
        )
        let planner = DefaultPlanner(metadata: metaProxy)
        let executor = DefaultExecutor(
            history: hist,
            concurrencyProvider: { [box] in box.settings.concurrency },
            minIntervalMs: 0,
            fetchUrl: { [box] url in
                try await ExecutorArtworkFetcher.fetch(
                    url: url,
                    tmdbBaseUrl: box.settings.tmdbBaseUrl,
                    fetchArtworkBytes: fetchArtworkBytes
                )
            }
        )

        let weakStoreBox = WeakAppStoreBox()
        let tm = DefaultTaskManager(
            backendFor: { [box, demoBe] connId in
                try box.backend(for: connId, demoBackend: demoBe)
            },
            recognizer: recognizer,
            planner: planner,
            executor: executor,
            history: hist,
            store: tStore,
            options: { [box] connId, mode in
                let s = box.settings
                let libRoot = box.connections.first(where: { $0.id == connId })?.libraryRoot
                return PlanOptions(
                    mode: mode,
                    libraryRoot: libRoot,
                    naming: box.namingProfile,
                    deleteJunk: s.autoDeleteJunk,
                    confidenceThreshold: s.confidenceThreshold,
                    overwriteNfo: s.overwriteNfo,
                    probeMedia: s.probeMedia
                )
            },
            onPathsMutated: { [fStore, weakStoreBox] connId, dirs in
                guard !dirs.isEmpty else { return }
                try? await fStore.deleteDirs(connection: connId, dirs: dirs)
                let scanner = await MainActor.run {
                    weakStoreBox.store?.existingSizeScanner(for: connId)
                }
                if let scanner {
                    await scanner.invalidate(dirs: dirs)
                }
            }
        )
        self.taskManager = tm
        weakStoreBox.store = self

        startWatchingTasks()
        Task { [weak self] in
            try? await tm.resumeInterrupted()
            await self?.pingAllConnections()
        }
    }

    // MARK: - Navigation (0ms Instant Tab Switch)

    public func navigateToTab(_ tab: AppTab) {
        if tab == .sources && selectedTab == .sources {
            openConnectionId = nil
        }
        if tab == .tasks && selectedTab == .tasks {
            tasksRoute = nil
            taskDetailOpenedFromSources = false
        }
        selectedTab = tab
    }

    public func openBrowser(connection: ConnectionConfig, path: String? = nil) {
        let root = normalizeDir(connection.startDir)
        let target: String
        if let path {
            let norm = normalizeDir(path)
            target = isWithinDir(norm, root: root) ? norm : root
        } else {
            target = root
        }
        openConnectionId = connection.id
        browserJumpRequest = BrowserJumpRequest(connectionId: connection.id, path: target)
        selectedTab = .sources
    }

    public func openTaskReview(_ id: TaskId) {
        taskDetailOpenedFromSources = false
        selectedTab = .tasks
        tasksRoute = .review(id)
    }

    public func openTaskDetail(_ id: TaskId, fromSources: Bool = false) {
        taskDetailOpenedFromSources = fromSources
        selectedTab = .tasks
        tasksRoute = .detail(id)
    }

    public func closeTasksSubroute() {
        let returnToSources = taskDetailOpenedFromSources
        taskDetailOpenedFromSources = false
        tasksRoute = nil
        if returnToSources {
            selectedTab = .sources
        }
    }

    public func showToast(
        _ message: String,
        actionLabel: String? = nil,
        tab: AppTab? = nil,
        route: TasksRoute? = nil,
        durationSeconds: Double = 4.0,
        onAction: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let notice = ToastNotice(
            message: message,
            actionLabel: actionLabel,
            destinationTab: tab,
            tasksRoute: route,
            onAction: onAction
        )
        activeToast = notice
        let id = notice.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(durationSeconds))
            if self?.activeToast?.id == id {
                self?.activeToast = nil
            }
        }
    }

    // MARK: - Lightweight Off-Main-Thread Task Card Metadata

    public func refreshTaskCardMeta(_ id: TaskId) {
        loadingCardMetaIds.insert(id)
        let store = sqliteTaskStore
        Task { [weak self] in
            let loaded = await store.loadCardMeta(ids: [id])
            guard let self else { return }
            self.loadingCardMetaIds.remove(id)
            if let meta = loaded[id] {
                self.taskCardMeta[id] = meta
            }
        }
    }

    public func updateTaskCardMeta(id: TaskId, review: TaskReview) {
        taskCardMeta[id] = TaskCardMeta.from(scan: review.scan, decisions: review.decisions)
    }

    private func syncTaskCardMeta(for list: [TaskSummary], previousStages: [TaskId: TaskStage]) {
        let liveIds = Set(list.map(\.id))
        for key in Array(taskCardMeta.keys) where !liveIds.contains(key) {
            taskCardMeta.removeValue(forKey: key)
        }

        var toLoad: [TaskId] = []
        for task in list {
            if !TaskCardMeta.isRecognizedStage(task.stage) {
                taskCardMeta.removeValue(forKey: task.id)
                continue
            }
            let prev = previousStages[task.id]
            let newlyRecognized = prev != nil && !TaskCardMeta.isRecognizedStage(prev!)
            let missing = taskCardMeta[task.id] == nil
            if (missing || newlyRecognized) && !loadingCardMetaIds.contains(task.id) {
                loadingCardMetaIds.insert(task.id)
                toLoad.append(task.id)
            }
        }

        guard !toLoad.isEmpty else { return }
        let store = sqliteTaskStore
        Task { [weak self] in
            let loaded = await store.loadCardMeta(ids: toLoad)
            guard let self else { return }
            for id in toLoad {
                self.loadingCardMetaIds.remove(id)
                if let meta = loaded[id] {
                    self.taskCardMeta[id] = meta
                }
            }
        }
    }

    // MARK: - Settings, Connections, Naming & TitleRules Mutations

    public func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        let oldKey = settings.tmdbApiKey
        var next = settings
        mutate(&next)
        settings = next
        configBox.update(settings: next)
        prefsStore.saveSettings(next)
        if oldKey != next.tmdbApiKey {
            secretStore.writeTmdbApiKey(next.tmdbApiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @discardableResult
    public func upsertConnection(
        _ draft: ConnectionConfig,
        password: String? = nil,
        dirPasswords: [String: String]? = nil
    ) -> ConnectionConfig {
        var config = draft
        if let old = connections.first(where: { $0.id == draft.id }),
           old.type != draft.type || old.endpoint != draft.endpoint || old.username != draft.username {
            // Task and batch records reference this ID for their entire lifetime.
            // Retire it when paths would resolve against a different storage namespace.
            config.id = ConnectionId(UUID().uuidString)
            removeConnection(old.id)
        }
        var next = connections
        if let idx = next.firstIndex(where: { $0.id == config.id }) {
            next[idx] = config
        } else {
            next.append(config)
        }
        connections = next
        if let password {
            secretStore.writeConnectionPassword(config.id, password: password)
        }
        if let dirPasswords {
            secretStore.writeConnectionDirPasswords(config.id, dirPasswords: dirPasswords)
        }
        configBox.invalidateBackend(for: config.id)
        configBox.update(connections: next)
        if let oldScanner = sizeScanners.removeValue(forKey: config.id) {
            Task {
                await oldScanner.cancel()
                await oldScanner.releaseMemoryCache()
            }
        }
        prefsStore.saveConnections(next)
        Task { [id = config.id] in await pingConnection(id) }
        return config
    }

    public func removeConnection(_ id: ConnectionId) {
        let next = connections.filter { $0.id != id }
        connections = next
        if openConnectionId == id { openConnectionId = nil }
        secretStore.writeConnectionPassword(id, password: nil)
        secretStore.writeConnectionDirPasswords(id, dirPasswords: [:])
        connectionStatuses.removeValue(forKey: id)
        if let oldScanner = sizeScanners.removeValue(forKey: id) {
            Task {
                await oldScanner.cancel()
                await oldScanner.releaseMemoryCache()
            }
        }
        configBox.invalidateBackend(for: id)
        configBox.update(connections: next)
        prefsStore.saveConnections(next)
        if let folderStatsStore {
            Task { try? await folderStatsStore.clearFor(id) }
        }
        if let mediaProbeCache {
            Task { await mediaProbeCache.clearFor(id) }
        }
    }

    /// Deletes a connection immediately without confirmation noise and shows an Undo toast (`sources_page.dart:248`).
    public func removeConnectionWithUndo(_ config: ConnectionConfig) {
        let savedPassword = secretStore.readConnectionPassword(config.id)
        let savedDirPasswords = secretStore.readConnectionDirPasswords(config.id)
        removeConnection(config.id)
        let t = l10n
        showToast(
            t.tr("已删除「\(config.name)」", "Deleted \"\(config.name)\""),
            actionLabel: t.tr("撤销", "Undo"),
            durationSeconds: 6.0
        ) { [weak self] in
            self?.upsertConnection(config, password: savedPassword, dirPasswords: savedDirPasswords)
        }
    }

    public func toggleFavorite(connectionId: ConnectionId, path: String) {
        guard var conn = connections.first(where: { $0.id == connectionId }) else { return }
        let norm = normalizeDir(path)
        if let idx = conn.favorites.firstIndex(of: norm) {
            conn.favorites.remove(at: idx)
        } else {
            conn.favorites.append(norm)
        }
        var next = connections
        if let i = next.firstIndex(where: { $0.id == connectionId }) {
            next[i] = conn
            connections = next
            configBox.update(connections: next)
            prefsStore.saveConnections(next)
        }
    }

    public func readConnectionPassword(_ id: ConnectionId) -> String {
        secretStore.readConnectionPassword(id) ?? ""
    }

    public func readConnectionDirPasswords(_ id: ConnectionId) -> [String: String] {
        secretStore.readConnectionDirPasswords(id)
    }

    public func setNamingProfile(_ profile: NamingProfile) {
        namingProfile = profile
        configBox.update(namingProfile: profile)
        prefsStore.saveNamingProfile(profile)
    }

    public func setTitleRules(_ rules: TitleRules) {
        titleRules = rules
        configBox.update(titleRules: rules)
        prefsStore.saveTitleRules(rules)
    }

    public func pinTitleRule(keyword: String, match: Candidate) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var pins = titleRules.pins.filter { $0.keyword != trimmed }
        pins.append(TitlePin(trimmed, match))
        setTitleRules(TitleRules(cleanups: titleRules.cleanups, pins: pins))
    }

    // MARK: - Backends, Scanners & Connectivity

    public func backend(for id: ConnectionId) throws -> any StorageBackend {
        try configBox.backend(for: id, demoBackend: demoBackend)
    }

    public func sizeScanner(for id: ConnectionId) throws -> SizeScannerActor {
        if let existing = sizeScanners[id] { return existing }
        let be = try backend(for: id)
        let scanner = SizeScannerActor(
            connectionId: id,
            backend: be,
            historyStore: historyStore,
            cacheStore: folderStatsStore,
            parser: parser
        )
        sizeScanners[id] = scanner
        return scanner
    }

    private func existingSizeScanner(for id: ConnectionId) -> SizeScannerActor? {
        sizeScanners[id]
    }

    public func makeHealthScanner(for id: ConnectionId) throws -> HealthScannerActor {
        let be = try backend(for: id)
        return HealthScannerActor(
            backend: be,
            connectionId: id,
            folderStatsStore: folderStatsStore,
            parser: parser,
            mediaProbe: mediaProbe,
            probeMedia: settings.probeMedia
        )
    }

    public func currentMetadataProvider() -> any MetadataProvider {
        configBox.metadataProvider(tmdbCache: tmdbCache, isDemo: isDemoMode)
    }

    public func pingConnection(_ id: ConnectionId) async {
        connectionStatuses[id] = .checking
        do {
            let be = try backend(for: id)
            try await be.ping()
            connectionStatuses[id] = .online
        } catch let e as StorageError {
            if e.code == .unauthorized {
                connectionStatuses[id] = .unauthorized(e.message)
            } else {
                connectionStatuses[id] = .offline(e.message)
            }
        } catch {
            connectionStatuses[id] = .offline(error.localizedDescription)
        }
    }

    public func pingAllConnections() async {
        let ids = connections.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { @MainActor [weak self] in
                    await self?.pingConnection(id)
                }
            }
        }
    }

    // MARK: - Task Submission & Helpers

    @discardableResult
    public func submitTask(
        connection: ConnectionId,
        paths: [String],
        mode: OrganizeMode,
        scrape: Bool = false,
        scrapeOnly: Bool = false
    ) async throws -> TaskId {
        try await taskManager.submit(
            connection: connection,
            paths: paths,
            mode: mode,
            scrape: scrape,
            scrapeOnly: scrapeOnly
        )
    }

    public func recordsForBatch(_ batch: BatchId) async throws -> [HistoryRecord] {
        try await historyStore.records(batch: batch)
    }

    public func arePathsOrganized(connection: ConnectionId, paths: [String]) async -> Set<String> {
        (try? await historyStore.areOrganized(connection: connection, paths: paths)) ?? []
    }

    public func invalidateFolderStats(connection: ConnectionId, dirs: [String]) async {
        guard !dirs.isEmpty else { return }
        try? await folderStatsStore?.deleteDirs(connection: connection, dirs: dirs)
    }

    public func clearCaches() async {
        await clearArtworkCache?()
        if let tmdbCache { await tmdbCache.clear() }
        if let mediaProbeCache { await mediaProbeCache.clear() }
        for conn in connections {
            try? await folderStatsStore?.clearFor(conn.id)
        }
        let scanners = Array(sizeScanners.values)
        sizeScanners.removeAll()
        for scanner in scanners {
            await scanner.cancel()
            await scanner.releaseMemoryCache()
        }
        await configBox.clearMetadataAndBackendCaches()
        await altTitleProxy?.clearCache()
        URLCache.shared.removeAllCachedResponses()
        cacheClearEpoch &+= 1
    }

    /// Flushes debounced JSON stores immediately and cleanly disposes the task manager and SQLite
    /// database (running `PRAGMA optimize`) on app termination without deadlocking `@MainActor`.
    public func shutdownSync() {
        guard !isShutDown else { return }
        isShutDown = true

        watchTasksHandle?.cancel()
        watchTasksHandle = nil

        prefsStore.flushSync()
        secretStore.flushSync()

        let scanners = Array(sizeScanners.values)
        sizeScanners.removeAll()
        let defaultTM = taskManager as? DefaultTaskManager
        let db = database

        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            for scanner in scanners {
                await scanner.cancel()
            }
            if let defaultTM {
                await defaultTM.dispose()
            }
            await db.close()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .milliseconds(500))
    }

    // MARK: - Task Stream Subscription & Toast Notifications

    private func startWatchingTasks() {
        watchTasksHandle?.cancel()
        let stream = taskManager.watchAll()
        watchTasksHandle = Task { @MainActor [weak self] in
            var initialized = false
            for await list in stream {
                guard let self else { break }
                self.applyTasksSnapshot(list, isInitial: !initialized)
                initialized = true
            }
        }
    }

    private func applyTasksSnapshot(_ list: [TaskSummary], isInitial: Bool) {
        let oldStages = previousTaskStages
        syncTaskCardMeta(for: list, previousStages: oldStages)
        if !isInitial {
            handleAutoRouteTransitions(nextList: list, previousStages: oldStages)
            emitStageTransitionToasts(nextList: list, previousStages: oldStages)
        }
        previousTaskStages = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.stage) })

        let nextPendingReviewCount = list.reduce(into: 0) { count, task in
            if task.stage == .awaitingReview { count += 1 }
        }
        if pendingReviewCount != nextPendingReviewCount {
            pendingReviewCount = nextPendingReviewCount
        }

        let nextHasRunningTasks = list.contains { $0.stage.isActive && $0.stage != .awaitingReview }
        if hasRunningTasks != nextHasRunningTasks {
            hasRunningTasks = nextHasRunningTasks
        }

        if tasks != list {
            tasks = list
        }
    }

    private func handleAutoRouteTransitions(nextList: [TaskSummary], previousStages: [TaskId: TaskStage]) {
        guard selectedTab == .tasks, let route = tasksRoute else { return }
        switch route {
        case .detail(let id):
            // Submitted tasks land on TaskDetailPage and automatically open ReviewPage once recognized (`task_detail_page.dart:70`).
            if let next = nextList.first(where: { $0.id == id }),
               let was = previousStages[id],
               was != .awaitingReview && next.stage == .awaitingReview {
                tasksRoute = .review(id)
            }
        case .review(let id):
            // Once execution starts from ReviewPage, follow the task on TaskDetailPage (`review_page.dart:856`).
            if let next = nextList.first(where: { $0.id == id }),
               let was = previousStages[id],
               was == .awaitingReview && next.stage != .awaitingReview {
                tasksRoute = .detail(id)
            }
        }
    }

    private func emitStageTransitionToasts(nextList: [TaskSummary], previousStages: [TaskId: TaskStage]) {
        let l10n = self.l10n
        for t in nextList {
            guard let was = previousStages[t.id], was != t.stage else { continue }
            let onThisTask = selectedTab == .tasks && (tasksRoute == .detail(t.id) || tasksRoute == .review(t.id))
            if onThisTask { continue }

            let name = taskCardMeta[t.id]?.works.first?.title
                ?? t.paths.first?.split(separator: "/").last.map(String.init)
                ?? t.id.value
            switch t.stage {
            case .awaitingReview where settings.notifyRecognized:
                let msg = l10n.isEn ? "\"\(name)\": Matching complete, ready for review" : "「\(name)」识别完成，等你确认"
                showToast(msg, actionLabel: l10n.tr("查看", "View"), tab: .tasks, route: .review(t.id))
            case .done where settings.notifyFinished:
                let msg = l10n.isEn ? "\"\(name)\": Organization complete" : "「\(name)」整理完成"
                showToast(msg, actionLabel: l10n.tr("查看", "View"), tab: .tasks, route: .detail(t.id))
            case .partiallyFailed where settings.notifyFinished:
                let msg = l10n.isEn ? "\"\(name)\": Finished with some failures" : "「\(name)」整理完成，但有失败项"
                showToast(msg, actionLabel: l10n.tr("查看", "View"), tab: .tasks, route: .detail(t.id))
            case .failed where settings.notifyFinished:
                if isTmdbKeyError(t.message) {
                    showToast(
                        l10n.tr("识别失败：请先填写 TMDB API key", "Matching failed: enter your TMDB API key first"),
                        actionLabel: l10n.tr("去设置", "Settings"),
                        tab: .settings
                    )
                } else {
                    let msg = l10n.isEn ? "\"\(name)\": Matching failed" : "「\(name)」识别失败"
                    showToast(msg, actionLabel: l10n.tr("查看", "View"), tab: .tasks, route: .detail(t.id))
                }
            default:
                break
            }
        }
    }
}
