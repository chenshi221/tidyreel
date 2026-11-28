import Foundation
import Testing
import TidyreelFakes
import TidyreelModels
import TidyreelPlanner

@Suite("AnchorRecognizer Tests")
struct RecognizerTests {
    private let conn = ConnectionId("c")
    private let showDir = "/下载/异兽魔都 2020 1080p"
    private let ep1 = "[Sub] Dorohedoro S01E01 [1080p]"

    private func makeRecognizer(metadata: (any MetadataProvider)? = nil) -> AnchorRecognizer {
        AnchorRecognizer(parser: TestFilenameParser(), metadata: metadata ?? TestMetadataProvider())
    }

    @Test("Cancelling recognition stops scheduling additional probes")
    func cancellingProbeQueue() async throws {
        actor BlockingProbe: MediaProbe {
            let started: AsyncStream<Void>.Continuation
            private(set) var count = 0
            init(_ started: AsyncStream<Void>.Continuation) { self.started = started }
            func probe(backend: any StorageBackend, path: String, fileSize: Int64?) async -> MediaProbeInfo? {
                count += 1
                started.finish()
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
        }
        let started = AsyncStream<Void>.makeStream()
        let probe = BlockingProbe(started.continuation)
        let recognizer = AnchorRecognizer(
            parser: TestFilenameParser(), metadata: TestMetadataProvider(),
            mediaProbe: probe, probeMedia: { true }
        )
        let files = (1...20).map { n in
            RemoteEntry(path: "/dl/Movie \(n).mkv", name: "Movie \(n).mkv", isDir: false, size: 1234)
        }
        let task = Task {
            try await recognizer.recognize(connection: conn, roots: ["/dl"], files: files, backend: MemoryStorageBackend())
        }
        for await _ in started.stream {}
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await probe.count <= 4)
    }

    @Test("groups by title folder and loose files, deterministic IDs, and alias matching")
    func groupingAndDeterminism() async throws {
        let files = [
            "\(showDir)/Season 1/\(ep1).mkv",
            "\(showDir)/Season 1/\(ep1).chs.ass",
            "\(showDir)/Season 1/[Sub] Dorohedoro S01E02 [1080p].mkv",
            "\(showDir)/Season 2/[Sub] Dorohedoro S02E01 [1080p].mkv",
            "\(showDir)/Season 2/[Sub] Dorohedoro S02E01 [1080p].nfo",
            "\(showDir)/Extras/花絮 PV.mkv",
            "\(showDir)/RARBG.txt",
            "/下载/Inception.2010.1080p.mkv",
            "/下载/Unknown Thing 2001.mkv",
        ]

        let r = try await makeRecognizer().recognize(
            connection: conn,
            roots: ["/下载"],
            files: entriesOf(files)
        )
        #expect(r.groups.count == 3)
        #expect(r.groups.map(\.rootDir) == ["/下载", "/下载", showDir])
        #expect(r.groups.map { $0.match?.title } == ["盗梦空间", nil, "异兽魔都"])

        let doro = r.groups[2]
        #expect(doro.kind == .episode)
        #expect(doro.anchorTitle == "异兽魔都")
        #expect(doro.anchorYear == 2020)
        #expect(doro.matchScore > 0.9)
        #expect(doro.show?.seasons.count == 2)
        #expect(doro.files.count == 6)
        #expect(doro.files[0].parsed?.kind == .extra)

        let inc = r.groups[0]
        #expect(inc.kind == .movie)
        #expect(inc.anchorYear == 2010)
        #expect(inc.show == nil)

        #expect(r.unassigned.map(\.name) == ["RARBG.txt"])

        // Deterministic IDs independent of file listing order
        let reversed = try await makeRecognizer().recognize(
            connection: conn,
            roots: ["/下载"],
            files: entriesOf(Array(files.reversed()))
        )
        #expect(r.groups.map(\.id) == reversed.groups.map(\.id))
        #expect(Set(r.groups.map(\.id)).count == 3)
    }

    @Test("fallback to file title, poor match rejection, year mismatch score, and subtitle home")
    func matchingHeuristics() async throws {
        let pack = try await makeRecognizer().recognize(
            connection: conn,
            roots: ["/dl"],
            files: entriesOf([
                "/dl/Pack/\(ep1).mkv",
                "/dl/Pack/[Sub] Dorohedoro S01E02 [1080p].mkv",
                "/dl/Pack/[Sub] Dorohedoro S01E03 [1080p].mkv",
            ])
        )
        #expect(pack.groups[0].anchorTitle == "Dorohedoro")
        #expect(pack.groups[0].match?.title == "异兽魔都")
        #expect(pack.groups[0].rootDir == "/dl/Pack")

        // Poor match rejected
        struct WrongMeta: MetadataProvider {
            func search(_ query: String, kind: MediaKind?, year: Int?) async throws -> [Candidate] { [TestDemo.friends] }
            func show(_ tmdbId: Int) async throws -> ShowDetail { TestDemo.friendsShow }
            func season(_ tmdbId: Int, season: Int) async throws -> [Episode] { [] }
            func episodeGroups(_ tmdbId: Int) async throws -> [EpisodeGroup] { [] }
            func movie(_ tmdbId: Int) async throws -> MovieDetail { MovieDetail(info: TestDemo.inception) }
        }
        let poor = try await makeRecognizer(metadata: WrongMeta()).recognize(
            connection: conn,
            roots: ["/下载"],
            files: entriesOf(["\(showDir)/\(ep1).mkv"])
        )
        #expect(poor.groups[0].match == nil)
        #expect(poor.groups[0].matchScore < 0.6)

        // Year mismatch lowers score
        let exactYear = try await makeRecognizer().recognize(
            connection: conn,
            roots: ["/x"],
            files: entriesOf(["/x/Inception.2010.mkv"])
        )
        let offYear = try await makeRecognizer().recognize(
            connection: conn,
            roots: ["/x"],
            files: entriesOf(["/x/Inception.2011.mkv"])
        )
        #expect(exactYear.groups[0].matchScore == 1.0)
        #expect(offYear.groups[0].match?.title == "盗梦空间")
        #expect(offYear.groups[0].matchScore < exactYear.groups[0].matchScore)

        // Subtitles in Subs/ join enclosing show group
        let subsScan = try await makeRecognizer().recognize(
            connection: conn,
            roots: ["/下载"],
            files: entriesOf([
                "\(showDir)/\(ep1).mkv",
                "\(showDir)/Subs/Dorohedoro.S01E01.zh-CN.ass",
                "\(showDir)/Subs/stray.ass",
            ])
        )
        let subNames = subsScan.groups[0].files.map(\.name)
        #expect(subNames.contains("Dorohedoro.S01E01.zh-CN.ass"))
        #expect(subNames.contains("stray.ass"))
    }

    @Test("content hint, AltTitleSource romaji fallback, and transient search cache eviction")
    func hintsAltTitlesAndCacheEviction() async throws {
        actor AltRecorder: AltTitleSource {
            var asked: [String] = []
            func altTitles(_ query: String) async -> [String] {
                asked.append(query)
                return ["葬送のフリーレン"]
            }
        }

        let dir = "/下载/Sousou no Frieren"
        let romaji = [
            "\(dir)/[Sub] Sousou no Frieren - 01 [1080p].mkv",
            "\(dir)/[Sub] Sousou no Frieren - 02 [1080p].mkv",
        ]

        let alt = AltRecorder()
        let matched = try await AnchorRecognizer(
            parser: TestFilenameParser(),
            metadata: TestMetadataProvider(),
            altTitles: alt
        ).recognize(connection: conn, roots: ["/下载"], files: entriesOf(romaji))
        #expect(matched.groups[0].match?.tmdbId == TestDemo.frieren.tmdbId)
        #expect(matched.groups[0].anchorTitle == "Sousou no Frieren")
        let asked1 = await alt.asked
        #expect(!asked1.isEmpty)

        // TV mode never asks AltTitleSource
        let altTv = AltRecorder()
        let tvRes = try await AnchorRecognizer(
            parser: TestFilenameParser(),
            metadata: TestMetadataProvider(),
            altTitles: altTv,
            hint: { .tv }
        ).recognize(connection: conn, roots: ["/下载"], files: entriesOf(romaji))
        #expect(tvRes.groups[0].match == nil)
        let askedTv = await altTv.asked
        #expect(askedTv.isEmpty)

        // Movie mode treats episode-looking files as movies
        let movieRes = try await AnchorRecognizer(
            parser: TestFilenameParser(),
            metadata: TestMetadataProvider(),
            hint: { .movie }
        ).recognize(connection: conn, roots: ["/下载"], files: entriesOf(romaji))
        #expect(movieRes.groups[0].kind == .movie)

        // Transient failure is evicted from SearchCache
        actor FailOnceSearchMeta: MetadataProvider {
            let inner = TestMetadataProvider()
            var inceptionCalls = 0

            func search(_ query: String, kind: MediaKind?, year: Int?) async throws -> [Candidate] {
                if query == "B" {
                    try? await Task.sleep(nanoseconds: 25_000_000)
                    return []
                }
                if query == "A" { return [] }
                if query == "Inception" && year == 2010 {
                    inceptionCalls += 1
                    if inceptionCalls == 1 {
                        throw StorageError(.network, "transient")
                    }
                }
                return try await inner.search(query, kind: kind, year: year)
            }
            func show(_ tmdbId: Int) async throws -> ShowDetail { try await inner.show(tmdbId) }
            func season(_ tmdbId: Int, season: Int) async throws -> [Episode] { [] }
            func episodeGroups(_ tmdbId: Int) async throws -> [EpisodeGroup] { [] }
            func movie(_ tmdbId: Int) async throws -> MovieDetail { try await inner.movie(tmdbId) }
        }

        let failMeta = FailOnceSearchMeta()
        await #expect(throws: StorageError.self) {
            try await AnchorRecognizer(parser: TestFilenameParser(), metadata: failMeta).recognize(
                connection: conn,
                roots: ["/下载"],
                files: entriesOf(["/下载/A/Inception.2010.mkv", "/下载/B/Inception.2010.mkv"])
            )
        }
        let incCalls = await failMeta.inceptionCalls
        #expect(incCalls == 2)
    }

    @Test("BDMV and VIDEO_TS disc detection, root boundary protection, and MediaProbe")
    func discUnitsAndMediaProbe() async throws {
        // 1. Dir markers
        let fromMarkers = try await makeRecognizer().recognize(
            connection: conn,
            roots: ["/dl"],
            files: [
                RemoteEntry(path: "/dl/Inception.2010.BluRay", name: "Inception.2010.BluRay", isDir: true),
                RemoteEntry(path: "/dl/Inception.2010.BluRay/BDMV", name: "BDMV", isDir: true),
            ]
        )
        #expect(fromMarkers.groups.count == 1)
        #expect(fromMarkers.groups[0].kind == .movie)
        #expect(fromMarkers.groups[0].match?.tmdbId == TestDemo.inception.tmdbId)
        #expect(fromMarkers.groups[0].files[0].isDiscDir == true)
        #expect(fromMarkers.groups[0].files[0].parsed?.isDisc == true)

        // 2. Nested VIDEO_TS streams summed
        let fromStreams = try await makeRecognizer().recognize(
            connection: conn,
            roots: ["/dl"],
            files: [
                RemoteEntry(path: "/dl/Inception 2010/VIDEO_TS/VTS_01_1.VOB", name: "VTS_01_1.VOB", isDir: false, size: 4000),
                RemoteEntry(path: "/dl/Inception 2010/VIDEO_TS/VIDEO_TS.IFO", name: "VIDEO_TS.IFO", isDir: false, size: 200),
            ]
        )
        #expect(fromStreams.groups[0].files[0].isDiscDir == true)
        #expect(fromStreams.groups[0].files[0].size == 4200)
        #expect(fromStreams.unassigned.isEmpty)

        // 3. Disc parent never escapes outside selected roots
        let escaped = try await makeRecognizer().recognize(
            connection: conn,
            roots: ["/in/Inception.2010/BDMV"],
            files: [
                RemoteEntry(path: "/in/Inception.2010/BDMV", name: "BDMV", isDir: true),
                RemoteEntry(path: "/in/Inception.2010/BDMV/STREAM/00001.m2ts", name: "00001.m2ts", isDir: false, size: 1000),
            ]
        )
        #expect(!escaped.groups.contains(where: { $0.rootDir == "/in/Inception.2010" }))
        #expect(!escaped.groups.flatMap(\.files).contains(where: { $0.isDiscDir }))

        // 4. MediaProbe header probing
        actor FakeProbe: MediaProbe {
            let results: [String: MediaProbeInfo]
            var calls: [String] = []
            init(_ results: [String: MediaProbeInfo]) { self.results = results }
            func probe(backend: any StorageBackend, path: String, fileSize: Int64?) async -> MediaProbeInfo? {
                calls.append(path)
                return results[path]
            }
        }
        let probe = FakeProbe([
            "/dl/Inception.2010.mkv": MediaProbeInfo(
                width: 3840, height: 2160, videoCodec: "HEVC", hdr: "DV", audioCodec: "Atmos", durationMs: 148 * 60_000
            ),
            "/dl/ShortAd.2020.mkv": MediaProbeInfo(width: 1920, height: 1080, durationMs: 30_000),
            "/dl/MysteryFilm.mkv": MediaProbeInfo(width: 1920, height: 1080, durationMs: 95 * 60_000),
        ])
        let be = MemoryStorageBackend(initialSizes: [
            "/dl/Inception.2010.mkv": 1000,
            "/dl/ShortAd.2020.mkv": 100,
            "/dl/MysteryFilm.mkv": 900,
        ])
        let probed = try await AnchorRecognizer(
            parser: TestFilenameParser(),
            metadata: TestMetadataProvider(),
            mediaProbe: probe,
            probeMedia: { true }
        ).recognize(
            connection: conn,
            roots: ["/dl"],
            files: entriesOf(["/dl/Inception.2010.mkv", "/dl/ShortAd.2020.mkv", "/dl/MysteryFilm.mkv"]),
            backend: be
        )
        var byPath: [String: ScanFile] = [:]
        for g in probed.groups {
            for f in g.files { byPath[f.path] = f }
        }
        #expect(byPath["/dl/Inception.2010.mkv"]?.parsed?.resolution == "2160p")
        #expect(byPath["/dl/Inception.2010.mkv"]?.parsed?.extraInfo == "2160p.DV.Atmos")
        #expect((byPath["/dl/ShortAd.2020.mkv"]?.parsed?.confidence ?? 1.0) <= 0.35)
        #expect(byPath["/dl/MysteryFilm.mkv"]?.parsed?.kind == .movie)
    }

    @Test("directory context inference, ExternalIdLookup, cross-kind fallback, TitleRules, and root promotion")
    func advancedRecognizerFeatures() async throws {
        // 1. Bare 4-digit anime stems & prefixed sequence
        let opScan = try await makeRecognizer().recognize(
            connection: conn,
            roots: ["/dl"],
            files: entriesOf(["/dl/海贼王/1078.mkv", "/dl/海贼王/1079.mkv", "/dl/海贼王/1080.mkv"])
        )
        #expect(opScan.groups[0].kind == .episode)
        #expect(opScan.groups[0].match?.tmdbId == TestDemo.onePiece.tmdbId)
        #expect(opScan.groups[0].files.map { $0.parsed?.absolute } == [1078, 1079, 1080])

        let prefixed = try await makeRecognizer().recognize(
            connection: conn,
            roots: ["/dl"],
            files: entriesOf(["/dl/异兽魔都/OP_01.mkv", "/dl/异兽魔都/OP_02.mkv"])
        )
        #expect(prefixed.groups[0].kind == .episode)
        #expect(prefixed.groups[0].files.map { $0.parsed?.episodes } == [[1], [2]])

        // 2. ExternalIdLookup without text search
        actor ExternalOnlyMeta: MetadataProvider, ExternalIdLookup {
            let inner = TestMetadataProvider()
            var searchCalls = 0
            func search(_ query: String, kind: MediaKind?, year: Int?) async throws -> [Candidate] {
                searchCalls += 1
                return []
            }
            func show(_ tmdbId: Int) async throws -> ShowDetail { try await inner.show(tmdbId) }
            func season(_ tmdbId: Int, season: Int) async throws -> [Episode] { [] }
            func episodeGroups(_ tmdbId: Int) async throws -> [EpisodeGroup] { [] }
            func movie(_ tmdbId: Int) async throws -> MovieDetail { try await inner.movie(tmdbId) }
            func findByExternalId(source: String, id: String, kind: MediaKind?) async throws -> Candidate? {
                try await inner.findByExternalId(source: source, id: id, kind: kind)
            }
        }
        let extMeta = ExternalOnlyMeta()
        let extScan = try await AnchorRecognizer(parser: TestFilenameParser(), metadata: extMeta).recognize(
            connection: conn,
            roots: ["/dl"],
            files: entriesOf([
                "/dl/Random Name {tmdb-27205}/video.mkv",
                "/dl/Another Show {imdb-tt0108778}/S01E01.mkv",
            ])
        )
        let extCalls = await extMeta.searchCalls
        #expect(extCalls == 0)
        let extByDir = Dictionary(uniqueKeysWithValues: extScan.groups.map { ($0.rootDir, $0) })
        #expect(extByDir["/dl/Random Name {tmdb-27205}"]?.match?.tmdbId == TestDemo.inception.tmdbId)
        #expect(extByDir["/dl/Another Show {imdb-tt0108778}"]?.match?.tmdbId == TestDemo.friends.tmdbId)

        // 3. Cross-kind fallback in mixed mode
        struct CrossKindMeta: MetadataProvider {
            static let blade = Candidate(
                tmdbId: 335984, kind: .movie, title: "银翼杀手2049", englishTitle: "Blade Runner 2049", year: 2017
            )
            func search(_ query: String, kind: MediaKind?, year: Int?) async throws -> [Candidate] {
                if kind == .movie && query.lowercased().contains("blade runner") { return [Self.blade] }
                if kind == .episode && query.lowercased().contains("friends") { return [TestDemo.friends] }
                return []
            }
            func show(_ tmdbId: Int) async throws -> ShowDetail { TestDemo.friendsShow }
            func season(_ tmdbId: Int, season: Int) async throws -> [Episode] { [] }
            func episodeGroups(_ tmdbId: Int) async throws -> [EpisodeGroup] { [] }
            func movie(_ tmdbId: Int) async throws -> MovieDetail { MovieDetail(info: Self.blade) }
        }
        struct StrayNumberParser: FilenameParser {
            let inner = TestFilenameParser()
            func classify(_ fileName: String) -> FileRole { inner.classify(fileName) }
            func parse(_ fileName: String, parentDirs: [String]) -> ParsedName {
                if fileName.contains("Blade Runner 2049") {
                    return ParsedName(title: "Blade Runner 2049", absolute: 2049, kind: .episode, confidence: 0.6)
                }
                return inner.parse(fileName, parentDirs: parentDirs)
            }
        }
        let bladeScan = try await AnchorRecognizer(
            parser: StrayNumberParser(),
            metadata: CrossKindMeta()
        ).recognize(connection: conn, roots: ["/dl"], files: entriesOf(["/dl/Blade Runner 2049.mkv"]))
        #expect(bladeScan.groups[0].kind == .movie)
        #expect(bladeScan.groups[0].match?.title == "银翼杀手2049")

        let tvFallback = try await AnchorRecognizer(
            parser: TestFilenameParser(),
            metadata: CrossKindMeta()
        ).recognize(connection: conn, roots: ["/dl"], files: entriesOf(["/dl/Friends.1994.mkv"]))
        #expect(tvFallback.groups[0].kind == .episode)
        #expect(tvFallback.groups[0].match?.tmdbId == TestDemo.friends.tmdbId)

        // 4. TitleRules cleanups & TitlePin
        let pinned = Candidate(tmdbId: 7, kind: .episode, title: "人生复本")
        let pinScan = try await AnchorRecognizer(
            parser: TestFilenameParser(),
            metadata: CrossKindMeta(),
            titleRules: { TitleRules(pins: [TitlePin("复本", pinned)]) }
        ).recognize(connection: conn, roots: ["/下载"], files: entriesOf(["/下载/X 复本 第一季/S01E01.mkv"]))
        #expect(pinScan.groups[0].match?.title == "人生复本")

        // 5. Generic container dirs are not promoted while non-generic wrapper is promoted
        for generic in ["Movies", "TV", "Downloads", "电影", "剧集", "动漫"] {
            let gScan = try await makeRecognizer().recognize(
                connection: conn,
                roots: ["/vol/\(generic)"],
                files: entriesOf(["/vol/\(generic)/[Sub] Dorohedoro [01-02]/Dorohedoro S01E01.mkv"])
            )
            #expect(gScan.groups[0].rootDir == "/vol/\(generic)/[Sub] Dorohedoro [01-02]")
        }
        let promoted = try await makeRecognizer().recognize(
            connection: conn,
            roots: ["/vol/Dorohedoro_Pack"],
            files: entriesOf(["/vol/Dorohedoro_Pack/[Sub] Dorohedoro [01-02]/Dorohedoro S01E01.mkv"])
        )
        #expect(promoted.groups[0].rootDir == "/vol/Dorohedoro_Pack")
    }

    @Test("MediaProbe receives connection and modifiedAt, lookup fails fast on 401, and sibling Subs indexed matching preserves order")
    func probeContextFailFastAndSiblingSubs() async throws {
        // 1. MediaProbe receives connection and modifiedAt from RemoteEntry
        actor ContextRecordingProbe: MediaProbe {
            struct Call: Equatable, Sendable {
                let connection: ConnectionId
                let path: String
                let fileSize: Int64?
                let modifiedAt: Date?
            }
            var calls: [Call] = []

            func probe(backend: any StorageBackend, path: String, fileSize: Int64?) async -> MediaProbeInfo? {
                nil
            }

            func probe(
                backend: any StorageBackend,
                connection: ConnectionId,
                path: String,
                fileSize: Int64?,
                modifiedAt: Date?
            ) async -> MediaProbeInfo? {
                calls.append(Call(connection: connection, path: path, fileSize: fileSize, modifiedAt: modifiedAt))
                return MediaProbeInfo(width: 1920, height: 1080, videoCodec: "HEVC")
            }
        }

        let modDate = utcDate(2024, 5, 6)
        let recordingProbe = ContextRecordingProbe()
        let be = MemoryStorageBackend(initialSizes: ["/dl/Inception.2010.mkv": 1234])
        _ = try await AnchorRecognizer(
            parser: TestFilenameParser(),
            metadata: TestMetadataProvider(),
            mediaProbe: recordingProbe,
            probeMedia: { true }
        ).recognize(
            connection: ConnectionId("conn-probe"),
            roots: ["/dl"],
            files: [RemoteEntry(path: "/dl/Inception.2010.mkv", name: "Inception.2010.mkv", isDir: false, size: 1234, modified: modDate)],
            backend: be
        )
        let probeCalls = await recordingProbe.calls
        #expect(probeCalls.count == 1)
        #expect(probeCalls[0].connection == ConnectionId("conn-probe"))
        #expect(probeCalls[0].fileSize == 1234)
        #expect(probeCalls[0].modifiedAt == modDate)

        // 2. Fail-fast on TMDB HTTP 401 stops firing lookups for remaining drafts
        actor UnauthorizedMeta: MetadataProvider {
            var searchCalls = 0
            func search(_ query: String, kind: MediaKind?, year: Int?) async throws -> [Candidate] {
                searchCalls += 1
                try await Task.sleep(nanoseconds: 10_000_000)
                throw TmdbError(statusCode: 401, message: "Invalid API key")
            }
            func show(_ tmdbId: Int) async throws -> ShowDetail { TestDemo.dorohedoroShow }
            func season(_ tmdbId: Int, season: Int) async throws -> [Episode] { [] }
            func episodeGroups(_ tmdbId: Int) async throws -> [EpisodeGroup] { [] }
            func movie(_ tmdbId: Int) async throws -> MovieDetail { MovieDetail(info: TestDemo.inception) }
        }
        let unauthMeta = UnauthorizedMeta()
        let manyShows = (1...20).map { i in
            String(format: "/dl/Show%02d/Show%02d.S01E01.mkv", i, i)
        }
        do {
            _ = try await AnchorRecognizer(parser: TestFilenameParser(), metadata: unauthMeta).recognize(
                connection: conn,
                roots: ["/dl"],
                files: entriesOf(manyShows)
            )
            Issue.record("Expected TmdbError(401) to be thrown")
        } catch let err as TmdbError {
            #expect(err.statusCode == 401)
        }
        let callsAfter401 = await unauthMeta.searchCalls
        #expect(callsAfter401 <= 4)

        // 3. Sibling Subs/ outside group folders matches via indexed Step 4 deterministically
        let siblingSubs = try await makeRecognizer().recognize(
            connection: conn,
            roots: ["/dl"],
            files: entriesOf([
                "/dl/ShowA/Dorohedoro.S01E01.mkv",
                "/dl/ShowB/Friends.S02E01.mkv",
                "/dl/ShowC/OnePiece.S01E01.mkv",
                "/dl/Subs/Friends.S02E01.chs.ass",
                "/dl/Subs/Unrelated.S01E01.eng.srt",
            ])
        )
        let byRoot = Dictionary(uniqueKeysWithValues: siblingSubs.groups.map { ($0.rootDir, $0) })
        #expect(byRoot["/dl/ShowB"]?.files.map(\.name).contains("Friends.S02E01.chs.ass") == true)
        #expect(byRoot["/dl/ShowA"]?.files.map(\.name).contains("Unrelated.S01E01.eng.srt") == true)
    }
}
