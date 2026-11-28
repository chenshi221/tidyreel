import Foundation

// MARK: - Connections

public enum ConnectionType: String, CaseIterable, Sendable {
    case alist
    case webdav
    case smb
    case local
}

public struct ConnectionConfig: Equatable, Hashable, Sendable, Identifiable {
    public var id: ConnectionId
    public var name: String
    public var type: ConnectionType
    public var endpoint: String
    public var username: String?
    public var libraryRoot: String?
    public var favorites: [String]
    public var startDir: String

    public init(
        id: ConnectionId,
        name: String,
        type: ConnectionType,
        endpoint: String,
        username: String? = nil,
        libraryRoot: String? = nil,
        favorites: [String] = [],
        startDir: String = "/"
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.endpoint = endpoint
        self.username = username
        self.libraryRoot = libraryRoot
        self.favorites = favorites
        self.startDir = startDir
    }
}

public func normalizeDir(_ path: String) -> String {
    let segs = path.split(separator: "/").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    return segs.isEmpty ? "/" : "/" + segs.joined(separator: "/")
}

public func isWithinDir(_ path: String, root: String) -> Bool {
    root == "/" || path == root || path.hasPrefix(root + "/")
}

public struct Credentials: Equatable, Sendable {
    public var password: String?
    public var token: String?
    public var dirPasswords: [String: String]

    public init(
        password: String? = nil,
        token: String? = nil,
        dirPasswords: [String: String] = [:]
    ) {
        self.password = password
        self.token = token
        self.dirPasswords = dirPasswords
    }

    public func passwordForPath(_ path: String) -> String {
        if dirPasswords.isEmpty { return "" }
        let target = normalizeDir(path)
        var bestDir: String?
        var bestPw = ""
        for (rawDir, pw) in dirPasswords where !pw.isEmpty {
            let dir = normalizeDir(rawDir)
            if isWithinDir(target, root: dir), (bestDir == nil || dir.count > bestDir!.count) {
                bestDir = dir
                bestPw = pw
            }
        }
        return bestPw
    }
}

// MARK: - Media & Probe

public enum MediaKind: String, CaseIterable, Sendable {
    case movie
    case episode
    case special
    case extra
    case unknown
}

public enum FileRole: String, CaseIterable, Sendable {
    case video
    case subtitle
    case sidecar
    case junk
    case other
}

public enum MediaHint: String, CaseIterable, Sendable {
    case mixed
    case anime
    case tv
    case movie
}

public struct ExternalId: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var source: String
    public var id: String

    public init(_ source: String, _ id: String) {
        self.source = source
        self.id = id
    }

    public var description: String { "\(source):\(id)" }
}

public struct EpisodeRef: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var season: Int
    public var episode: Int

    public init(_ season: Int, _ episode: Int) {
        self.season = season
        self.episode = episode
    }

    public var description: String { "S\(season)E\(episode)" }
}

public struct MediaProbeInfo: Equatable, Hashable, Sendable {
    public var width: Int?
    public var height: Int?
    public var videoCodec: String?
    public var hdr: String?
    public var audioCodec: String?
    public var audioChannels: Int?
    public var durationMs: Int64?
    public var container: String?

    public init(
        width: Int? = nil,
        height: Int? = nil,
        videoCodec: String? = nil,
        hdr: String? = nil,
        audioCodec: String? = nil,
        audioChannels: Int? = nil,
        durationMs: Int64? = nil,
        container: String? = nil
    ) {
        self.width = width
        self.height = height
        self.videoCodec = videoCodec
        self.hdr = hdr
        self.audioCodec = audioCodec
        self.audioChannels = audioChannels
        self.durationMs = durationMs
        self.container = container
    }

    public var durationSeconds: Double? {
        guard let ms = durationMs else { return nil }
        return Double(ms) / 1000.0
    }

    public var resolution: String? {
        let w = width ?? 0
        let h = height ?? 0
        if w <= 0 && h <= 0 { return nil }
        if w >= 7000 || h >= 4000 { return "4320p" }
        if w >= 3200 || h >= 2000 { return "2160p" }
        if w >= 2400 || h >= 1350 { return "1440p" }
        if w >= 1700 || h >= 960 { return "1080p" }
        if w >= 1100 || h >= 650 { return "720p" }
        if h >= 520 { return "576p" }
        if h >= 400 || w >= 600 { return "480p" }
        return h > 0 ? "\(h)p" : nil
    }

    public var extraInfoSummary: String? {
        let premiumAudio: Set<String> = ["Atmos", "TrueHD", "DTS-HD", "DTS-X"]
        var parts: [String] = []
        if let res = resolution { parts.append(res) }
        if let h = hdr, !h.isEmpty { parts.append(h) }
        if let a = audioCodec, premiumAudio.contains(a) { parts.append(a) }
        return parts.isEmpty ? nil : parts.joined(separator: ".")
    }
}

public struct ParsedName: Equatable, Hashable, Sendable {
    public var title: String?
    public var year: Int?
    public var season: Int?
    public var episodes: [Int]
    public var absolute: Int?
    public var kind: MediaKind
    public var resolution: String?
    public var group: String?
    public var lang: String?
    public var extraInfo: String?
    public var confidence: Double
    public var airDate: Date?
    public var edition: String?
    public var part: Int?
    public var partLabel: String?
    public var subFlags: [String]
    public var externalId: ExternalId?
    public var isDisc: Bool
    public var probe: MediaProbeInfo?

    public init(
        title: String? = nil,
        year: Int? = nil,
        season: Int? = nil,
        episodes: [Int] = [],
        absolute: Int? = nil,
        kind: MediaKind = .unknown,
        resolution: String? = nil,
        group: String? = nil,
        lang: String? = nil,
        extraInfo: String? = nil,
        confidence: Double = 0,
        airDate: Date? = nil,
        edition: String? = nil,
        part: Int? = nil,
        partLabel: String? = nil,
        subFlags: [String] = [],
        externalId: ExternalId? = nil,
        isDisc: Bool = false,
        probe: MediaProbeInfo? = nil
    ) {
        self.title = title
        self.year = year
        self.season = season
        self.episodes = episodes
        self.absolute = absolute
        self.kind = kind
        self.resolution = resolution
        self.group = group
        self.lang = lang
        self.extraInfo = extraInfo
        self.confidence = confidence
        self.airDate = airDate
        self.edition = edition
        self.part = part
        self.partLabel = partLabel
        self.subFlags = subFlags
        self.externalId = externalId
        self.isDisc = isDisc
        self.probe = probe
    }
}

// MARK: - Metadata (TMDB / Bangumi / AniList)

public struct PersonCredit: Equatable, Hashable, Sendable {
    public var name: String
    public var role: String?
    public var profilePath: String?

    public init(name: String, role: String? = nil, profilePath: String? = nil) {
        self.name = name
        self.role = role
        self.profilePath = profilePath
    }
}

public struct Candidate: Equatable, Hashable, Sendable {
    public var tmdbId: Int
    public var kind: MediaKind
    public var title: String
    public var englishTitle: String?
    public var originalTitle: String?
    public var year: Int?
    public var posterPath: String?
    public var originCountry: String?
    public var voteAverage: Double?
    public var voteCount: Int?
    public var popularity: Double?
    public var overview: String?
    public var backdropPath: String?
    public var genres: [String]
    public var aliases: [String]
    public var imdbId: String?
    public var tvdbId: Int?
    public var collectionName: String?
    public var collectionId: Int?
    public var clearLogoPath: String?
    public var landscapePath: String?
    public var certification: String?
    public var studios: [String]
    public var actors: [PersonCredit]
    public var directors: [String]
    public var writers: [String]
    public var tags: [String]

    public init(
        tmdbId: Int,
        kind: MediaKind,
        title: String,
        englishTitle: String? = nil,
        originalTitle: String? = nil,
        year: Int? = nil,
        posterPath: String? = nil,
        originCountry: String? = nil,
        voteAverage: Double? = nil,
        voteCount: Int? = nil,
        popularity: Double? = nil,
        overview: String? = nil,
        backdropPath: String? = nil,
        genres: [String] = [],
        aliases: [String] = [],
        imdbId: String? = nil,
        tvdbId: Int? = nil,
        collectionName: String? = nil,
        collectionId: Int? = nil,
        clearLogoPath: String? = nil,
        landscapePath: String? = nil,
        certification: String? = nil,
        studios: [String] = [],
        actors: [PersonCredit] = [],
        directors: [String] = [],
        writers: [String] = [],
        tags: [String] = []
    ) {
        self.tmdbId = tmdbId
        self.kind = kind
        self.title = title
        self.englishTitle = englishTitle
        self.originalTitle = originalTitle
        self.year = year
        self.posterPath = posterPath
        self.originCountry = originCountry
        self.voteAverage = voteAverage
        self.voteCount = voteCount
        self.popularity = popularity
        self.overview = overview
        self.backdropPath = backdropPath
        self.genres = genres
        self.aliases = aliases
        self.imdbId = imdbId
        self.tvdbId = tvdbId
        self.collectionName = collectionName
        self.collectionId = collectionId
        self.clearLogoPath = clearLogoPath
        self.landscapePath = landscapePath
        self.certification = certification
        self.studios = studios
        self.actors = actors
        self.directors = directors
        self.writers = writers
        self.tags = tags
    }
}

public struct SeasonInfo: Equatable, Hashable, Sendable {
    public var number: Int
    public var episodeCount: Int
    public var name: String?
    public var airDate: Date?
    public var posterPath: String?

    public init(
        number: Int,
        episodeCount: Int,
        name: String? = nil,
        airDate: Date? = nil,
        posterPath: String? = nil
    ) {
        self.number = number
        self.episodeCount = episodeCount
        self.name = name
        self.airDate = airDate
        self.posterPath = posterPath
    }
}

public struct ShowDetail: Equatable, Hashable, Sendable {
    public var info: Candidate
    public var seasons: [SeasonInfo]

    public init(info: Candidate, seasons: [SeasonInfo]) {
        self.info = info
        self.seasons = seasons
    }
}

public struct MovieDetail: Equatable, Hashable, Sendable {
    public var info: Candidate

    public init(info: Candidate) {
        self.info = info
    }
}

public struct Episode: Equatable, Hashable, Sendable {
    public var season: Int
    public var number: Int
    public var title: String?
    public var airDate: Date?
    public var stillPath: String?
    public var overview: String?
    public var runtimeMinutes: Int?

    public init(
        season: Int,
        number: Int,
        title: String? = nil,
        airDate: Date? = nil,
        stillPath: String? = nil,
        overview: String? = nil,
        runtimeMinutes: Int? = nil
    ) {
        self.season = season
        self.number = number
        self.title = title
        self.airDate = airDate
        self.stillPath = stillPath
        self.overview = overview
        self.runtimeMinutes = runtimeMinutes
    }
}

public struct EpisodeGroupSeason: Equatable, Hashable, Sendable {
    public var order: Int
    public var name: String
    public var episodes: [EpisodeRef]

    public init(order: Int, name: String, episodes: [EpisodeRef]) {
        self.order = order
        self.name = name
        self.episodes = episodes
    }
}

public struct EpisodeGroup: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var type: Int
    public var seasons: [EpisodeGroupSeason]

    public init(id: String, name: String, type: Int, seasons: [EpisodeGroupSeason]) {
        self.id = id
        self.name = name
        self.type = type
        self.seasons = seasons
    }
}

public struct TmdbConfig: Equatable, Sendable {
    public var apiKey: String
    public var baseUrl: String
    public var language: String
    public var fallbackLanguage: String

    public init(
        apiKey: String,
        baseUrl: String = "https://api.themoviedb.org/3",
        language: String = "zh-CN",
        fallbackLanguage: String = "en-US"
    ) {
        self.apiKey = apiKey
        self.baseUrl = baseUrl
        self.language = language
        self.fallbackLanguage = fallbackLanguage
    }
}

public struct TmdbError: Error, LocalizedError, Equatable, Sendable {
    public var statusCode: Int?
    public var message: String

    public init(statusCode: Int? = nil, message: String) {
        self.statusCode = statusCode
        self.message = message
    }

    public var errorDescription: String? { message }
}
