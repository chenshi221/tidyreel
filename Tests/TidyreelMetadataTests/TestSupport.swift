import Foundation
import TidyreelMetadata
import TidyreelModels

// MARK: - Mock HTTP Transport

final class MockHTTPTransport: HTTPTransport, Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private actor Recorder {
        var requests: [URLRequest] = []
        var overrides: [(status: Int, headers: [String: String], body: String)] = []

        func record(_ request: URLRequest) {
            requests.append(request)
        }

        func popOverride() -> (status: Int, headers: [String: String], body: String)? {
            guard !overrides.isEmpty else { return nil }
            return overrides.removeFirst()
        }

        func addOverride(status: Int, headers: [String: String] = [:], body: String = #"{"status_message":"Too many requests"}"#) {
            overrides.append((status, headers, body))
        }

        func allRequests() -> [URLRequest] {
            requests
        }

        func clearRequests() {
            requests.removeAll()
        }

        func count(path: String) -> Int {
            requests.filter { $0.url?.path == path }.count
        }
    }

    private let recorder = Recorder()
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await recorder.record(request)
        if let ov = await recorder.popOverride() {
            return Self.makeResponse(for: request, status: ov.status, headers: ov.headers, body: ov.body)
        }
        return try await handler(request)
    }

    func addOverride(status: Int, headers: [String: String] = [:], body: String = #"{"status_message":"Too many requests"}"#) async {
        await recorder.addOverride(status: status, headers: headers, body: body)
    }

    func requests() async -> [URLRequest] {
        await recorder.allRequests()
    }

    func clearRequests() async {
        await recorder.clearRequests()
    }

    func count(path: String) async -> Int {
        await recorder.count(path: path)
    }

    static func makeResponse(
        for request: URLRequest,
        status: Int = 200,
        headers: [String: String] = [:],
        body: String
    ) -> (Data, HTTPURLResponse) {
        var allHeaders = ["Content-Type": "application/json"]
        for (k, v) in headers {
            allHeaders[k] = v
        }
        let url = request.url ?? URL(string: "https://example.com")!
        let http = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: allHeaders
        )!
        return (Data(body.utf8), http)
    }

    static func makeJSONResponse(
        for request: URLRequest,
        status: Int = 200,
        headers: [String: String] = [:],
        jsonObject: Any
    ) -> (Data, HTTPURLResponse) {
        let data = (try? JSONSerialization.data(withJSONObject: jsonObject)) ?? Data("{}".utf8)
        let body = String(decoding: data, as: UTF8.self)
        return makeResponse(for: request, status: status, headers: headers, body: body)
    }
}

extension URLRequest {
    var queryMap: [String: String] {
        guard let url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return [:]
        }
        var out: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            out[item.name] = item.value ?? ""
        }
        return out
    }
}

// MARK: - Recording Sleeper

actor RecordingSleeper {
    private var durations: [TimeInterval] = []

    func record(_ seconds: TimeInterval) {
        durations.append(seconds)
    }

    func recorded() -> [TimeInterval] {
        durations
    }

    func reset() {
        durations.removeAll()
    }

    nonisolated var sleep: @Sendable (TimeInterval) async throws -> Void {
        { [self] seconds in
            try Task.checkCancellation()
            await self.record(seconds)
        }
    }
}

// MARK: - In-Memory Cache Doubles

actor MapTmdbCache: TmdbResponseCache {
    private var storage: [String: String] = [:]

    func get(_ key: String) async -> String? {
        storage[key]
    }

    func put(_ key: String, json: String) async {
        storage[key] = json
    }

    func rawValue(for key: String) -> String? {
        storage[key]
    }

    func clear() {
        storage.removeAll()
    }

    func keys() -> [String] {
        Array(storage.keys)
    }
}

// MARK: - Recorded TMDB Fixtures

enum TmdbFixtures {
    static let routes: [String: String] = [
        "/search/movie|zh-CN|Inception": searchMovieInceptionZh,
        "/search/movie|en-US|Inception": searchMovieInceptionEn,
        "/search/tv|zh-CN|老友记": searchTvFriendsZh,
        "/search/tv|en-US|老友记": searchTvFriendsEn,
        "/search/tv|en-US|Dorohedoro": searchTvDorohedoroEn,
        "/tv/1668|zh-CN|": tv1668Zh,
        "/tv/1668|en-US|": tv1668En,
        "/tv/1668/season/1|zh-CN|": tv1668Season1Zh,
        "/tv/37854/episode_groups|zh-CN|": tv37854EpisodeGroupsZh,
        "/tv/episode_group/5acf93e50e0a26080e0006ad|zh-CN|": episodeGroupArcsZh,
        "/tv/episode_group/6bd0a4f61f1b37191f1117be|zh-CN|": episodeGroupAbsoluteZh,
        "/movie/27205|zh-CN|": movie27205Zh,
        "/movie/27205|en-US|": movie27205En,
    ]

    static func makeTransport() -> MockHTTPTransport {
        MockHTTPTransport { req in
            let path = req.url?.path ?? ""
            let q = req.queryMap
            let routeKey = "\(path)|\(q["language"] ?? "")|\(q["query"] ?? "")"
            if let body = routes[routeKey] {
                return MockHTTPTransport.makeResponse(for: req, status: 200, body: body)
            }
            // Strip base path prefix (/tmdb/3 or /3) so route keys match relative TMDB v3 paths
            let strippedPath: String = if let range = path.range(of: "/tmdb/3") {
                String(path[range.upperBound...])
            } else if path.hasPrefix("/3/") {
                String(path.dropFirst(2))
            } else {
                path
            }
            let altKey = "\(strippedPath)|\(q["language"] ?? "")|\(q["query"] ?? "")"
            if let body = routes[altKey] {
                return MockHTTPTransport.makeResponse(for: req, status: 200, body: body)
            }
            if strippedPath.hasPrefix("/search/") {
                return MockHTTPTransport.makeResponse(for: req, status: 200, body: #"{"page":1,"results":[]}"#)
            }
            return MockHTTPTransport.makeResponse(
                for: req,
                status: 404,
                body: #"{"status_code":34,"status_message":"not found"}"#
            )
        }
    }

    static let searchMovieInceptionZh = """
    {
      "page": 1,
      "results": [
        {
          "adult": false,
          "backdrop_path": null,
          "genre_ids": [99],
          "id": 64956,
          "original_language": "en",
          "original_title": "Inception: The Cobol Job",
          "overview": "",
          "popularity": 4.1,
          "poster_path": "/cobol.jpg",
          "release_date": "2010-12-07",
          "title": "盗梦空间：Cobol 行动",
          "video": false,
          "vote_average": 6.9,
          "vote_count": 120
        },
        {
          "adult": false,
          "backdrop_path": "/8ZTVqvKDQ8emSGUEMjsS4yHAwrp.jpg",
          "genre_ids": [28, 878, 12],
          "id": 27205,
          "original_language": "en",
          "original_title": "Inception",
          "overview": "道姆·柯布是一名经验老到的窃贼……",
          "popularity": 83.9,
          "poster_path": "/xlaY2zyzMfkhk0HSC5VUwzoZPU1.jpg",
          "release_date": "2010-07-15",
          "title": "盗梦空间",
          "video": false,
          "vote_average": 8.369,
          "vote_count": 36000
        },
        {
          "adult": false,
          "backdrop_path": null,
          "genre_ids": [99],
          "id": 700001,
          "original_language": "en",
          "original_title": "Inception Point",
          "overview": "",
          "popularity": 0.6,
          "poster_path": null,
          "release_date": "2017-03-02",
          "title": "起始点",
          "video": false,
          "vote_average": 5.0,
          "vote_count": 3
        }
      ],
      "total_pages": 1,
      "total_results": 3
    }
    """

    static let searchMovieInceptionEn = """
    {
      "page": 1,
      "results": [
        {
          "adult": false,
          "id": 64956,
          "original_language": "en",
          "original_title": "Inception: The Cobol Job",
          "poster_path": "/cobol.jpg",
          "release_date": "2010-12-07",
          "title": "Inception: The Cobol Job",
          "vote_average": 6.9
        },
        {
          "adult": false,
          "id": 27205,
          "original_language": "en",
          "original_title": "Inception",
          "poster_path": "/xlaY2zyzMfkhk0HSC5VUwzoZPU1.jpg",
          "release_date": "2010-07-15",
          "title": "Inception",
          "vote_average": 8.369
        },
        {
          "adult": false,
          "id": 700001,
          "original_language": "en",
          "original_title": "Inception Point",
          "poster_path": null,
          "release_date": "2017-03-02",
          "title": "Inception Point",
          "vote_average": 5.0
        }
      ],
      "total_pages": 1,
      "total_results": 3
    }
    """

    static let searchTvFriendsZh = """
    {
      "page": 1,
      "results": [
        {
          "adult": false,
          "backdrop_path": null,
          "genre_ids": [35],
          "id": 800001,
          "origin_country": ["CN"],
          "original_language": "zh",
          "original_name": "老友鬼鬼",
          "overview": "",
          "popularity": 2.0,
          "poster_path": null,
          "first_air_date": "2003-01-01",
          "name": "老友鬼鬼",
          "vote_average": 6.0,
          "vote_count": 10
        },
        {
          "adult": false,
          "backdrop_path": "/l0qVZIpXtIo7km9u5Yqh0nKPOr5.jpg",
          "genre_ids": [35],
          "id": 1668,
          "origin_country": ["US"],
          "original_language": "en",
          "original_name": "Friends",
          "overview": "六个好朋友在纽约的生活……",
          "popularity": 145.2,
          "poster_path": "/f496cm9enuEsZkSPzCwnTESEK5s.jpg",
          "first_air_date": "1994-09-22",
          "name": "老友记",
          "vote_average": 8.4,
          "vote_count": 8000
        },
        {
          "adult": false,
          "backdrop_path": null,
          "genre_ids": [35],
          "id": 800002,
          "origin_country": ["HK"],
          "original_language": "zh",
          "original_name": "老友記之老友",
          "overview": "",
          "popularity": 1.0,
          "poster_path": null,
          "first_air_date": "1998-05-01",
          "name": "老友记之老友",
          "vote_average": 5.5,
          "vote_count": 4
        }
      ],
      "total_pages": 1,
      "total_results": 3
    }
    """

    static let searchTvFriendsEn = """
    {
      "page": 1,
      "results": [
        {"id": 800001, "origin_country": ["CN"], "original_name": "老友鬼鬼", "first_air_date": "2003-01-01", "name": "Old Friend Ghost", "vote_average": 6.0},
        {"id": 1668, "origin_country": ["US"], "original_name": "Friends", "first_air_date": "1994-09-22", "name": "Friends", "vote_average": 8.4},
        {"id": 800002, "origin_country": ["HK"], "original_name": "老友記之老友", "first_air_date": "1998-05-01", "name": "Old Friends", "vote_average": 5.5}
      ],
      "total_pages": 1,
      "total_results": 3
    }
    """

    static let searchTvDorohedoroEn = """
    {
      "page": 1,
      "results": [
        {
          "id": 85937,
          "origin_country": ["JP"],
          "original_name": "ドロヘドロ",
          "first_air_date": "2020-01-12",
          "name": "Dorohedoro",
          "poster_path": "/dorohedoro.jpg",
          "vote_average": 8.0
        }
      ],
      "total_pages": 1,
      "total_results": 1
    }
    """

    static let tv1668Zh = """
    {
      "id": 1668,
      "name": "老友记",
      "original_name": "Friends",
      "first_air_date": "1994-09-22",
      "origin_country": ["US"],
      "poster_path": "/f496cm9enuEsZkSPzCwnTESEK5s.jpg",
      "vote_average": 8.4,
      "number_of_seasons": 10,
      "seasons": [
        {"air_date": "1993-01-01", "episode_count": 3, "id": 1, "name": "特别篇", "poster_path": null, "season_number": 0},
        {"air_date": "1994-09-22", "episode_count": 24, "id": 2, "name": "第 1 季", "poster_path": "/s1.jpg", "season_number": 1},
        {"air_date": "1995-09-21", "episode_count": 24, "id": 3, "name": "第 2 季", "poster_path": "/s2.jpg", "season_number": 2}
      ]
    }
    """

    static let tv1668En = """
    {
      "id": 1668,
      "name": "Friends",
      "original_name": "Friends",
      "first_air_date": "1994-09-22",
      "origin_country": ["US"],
      "poster_path": "/f496cm9enuEsZkSPzCwnTESEK5s.jpg",
      "vote_average": 8.4
    }
    """

    static let tv1668Season1Zh = """
    {
      "_id": "5256c8c219c2956ff604858a",
      "air_date": "1994-09-22",
      "name": "第 1 季",
      "season_number": 1,
      "episodes": [
        {"air_date": "1994-09-22", "episode_number": 1, "id": 85987, "name": "六人行", "season_number": 1},
        {"air_date": "1994-09-29", "episode_number": 2, "id": 85988, "name": "", "season_number": 1}
      ]
    }
    """

    static let tv37854EpisodeGroupsZh = """
    {
      "id": 37854,
      "results": [
        {"description": "", "episode_count": 4, "group_count": 2, "id": "5acf93e50e0a26080e0006ad", "name": "按故事篇章", "network": null, "type": 6},
        {"description": "", "episode_count": 3, "group_count": 1, "id": "6bd0a4f61f1b37191f1117be", "name": "绝对顺序", "network": null, "type": 2}
      ]
    }
    """

    static let episodeGroupArcsZh = """
    {
      "id": "5acf93e50e0a26080e0006ad",
      "name": "按故事篇章",
      "type": 6,
      "description": "",
      "episode_count": 4,
      "group_count": 2,
      "groups": [
        {
          "id": "g2",
          "name": "第二篇",
          "order": 2,
          "episodes": [
            {"episode_number": 2, "season_number": 2, "order": 1, "name": "d"},
            {"episode_number": 1, "season_number": 2, "order": 0, "name": "c"}
          ]
        },
        {
          "id": "g1",
          "name": "第一篇",
          "order": 1,
          "episodes": [
            {"episode_number": 1, "season_number": 1, "order": 0, "name": "a"},
            {"episode_number": 2, "season_number": 1, "order": 1, "name": "b"}
          ]
        }
      ]
    }
    """

    static let episodeGroupAbsoluteZh = """
    {
      "id": "6bd0a4f61f1b37191f1117be",
      "name": "绝对顺序",
      "type": 2,
      "episode_count": 3,
      "group_count": 1,
      "groups": [
        {
          "id": "abs",
          "name": "绝对集数",
          "order": 1,
          "episodes": [
            {"episode_number": 1, "season_number": 1, "order": 0},
            {"episode_number": 2, "season_number": 1, "order": 1},
            {"episode_number": 1, "season_number": 2, "order": 2}
          ]
        }
      ]
    }
    """

    static let movie27205Zh = """
    {
      "id": 27205,
      "title": "盗梦空间",
      "original_title": "Inception",
      "release_date": "2010-07-15",
      "poster_path": "/xlaY2zyzMfkhk0HSC5VUwzoZPU1.jpg",
      "vote_average": 8.369,
      "production_countries": [{"iso_3166_1": "US", "name": "United States of America"}]
    }
    """

    static let movie27205En = """
    {
      "id": 27205,
      "title": "Inception",
      "original_title": "Inception",
      "release_date": "2010-07-15",
      "poster_path": "/xlaY2zyzMfkhk0HSC5VUwzoZPU1.jpg",
      "vote_average": 8.369
    }
    """
}
