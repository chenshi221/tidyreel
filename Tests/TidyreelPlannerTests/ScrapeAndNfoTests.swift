import Foundation
import Testing
import TidyreelModels
import TidyreelPlanner

@Suite("Scrape & NFO Tests")
struct ScrapeAndNfoTests {
    @Test("movieNfo writes uniqueids, mpaa, set, studios, crew, actors, tags, streamdetails, and escapes XML")
    func movieNfoXml() {
        let movie = Candidate(
            tmdbId: 27205,
            kind: .movie,
            title: "盗梦空间 & 梦境",
            originalTitle: "Inception",
            year: 2010,
            voteAverage: 8.4,
            voteCount: 36000,
            overview: #"Dream <within> a "dream""#,
            genres: ["动作", "科幻"],
            imdbId: "tt1375666",
            tvdbId: 12345,
            collectionName: "梦境 & 幻想系列",
            certification: "PG-13",
            studios: ["Legendary Pictures", "Syncopy & Co"],
            actors: [
                PersonCredit(name: "Leonardo DiCaprio", role: #"Dom "Cobb" & Thief"#, profilePath: "/leo.jpg"),
                PersonCredit(name: "Ken Watanabe"),
            ],
            directors: ["Christopher Nolan"],
            writers: ["Christopher Nolan", "Jonathan <Nolan>"],
            tags: ["dream", "sci-fi & heist"]
        )
        let probe = MediaProbeInfo(
            width: 3840,
            height: 2160,
            videoCodec: "HEVC",
            hdr: "DV",
            audioCodec: "Atmos",
            audioChannels: 8,
            durationMs: 8_880_000
        )

        let xml = movieNfo(movie, probe: probe)
        #expect(xml.contains("<movie>"))
        #expect(xml.contains("<title>盗梦空间 &amp; 梦境</title>"))
        #expect(xml.contains("<plot>Dream &lt;within&gt; a &quot;dream&quot;</plot>"))
        #expect(xml.contains("<mpaa>PG-13</mpaa>"))
        #expect(xml.contains(#"<uniqueid type="tmdb" default="true">27205</uniqueid>"#))
        #expect(xml.contains(#"<uniqueid type="imdb">tt1375666</uniqueid>"#))
        #expect(xml.contains(#"<uniqueid type="tvdb">12345</uniqueid>"#))
        #expect(xml.contains("<tmdbid>27205</tmdbid>"))
        #expect(xml.contains("<imdbid>tt1375666</imdbid>"))
        #expect(xml.contains("<votes>36000</votes>"))
        #expect(xml.contains("<set><name>梦境 &amp; 幻想系列</name></set>"))
        #expect(xml.contains("<studio>Legendary Pictures</studio>"))
        #expect(xml.contains("<studio>Syncopy &amp; Co</studio>"))
        #expect(xml.contains("<director>Christopher Nolan</director>"))
        #expect(xml.contains("<credits>Christopher Nolan</credits>"))
        #expect(xml.contains("<credits>Jonathan &lt;Nolan&gt;</credits>"))
        #expect(xml.contains("<tag>dream</tag>"))
        #expect(xml.contains("<tag>sci-fi &amp; heist</tag>"))
        #expect(xml.contains(
            "  <actor>\n" +
            "    <name>Leonardo DiCaprio</name>\n" +
            "    <role>Dom &quot;Cobb&quot; &amp; Thief</role>\n" +
            "    <thumb>https://image.tmdb.org/t/p/w185/leo.jpg</thumb>\n" +
            "  </actor>"
        ))
        #expect(xml.contains("  <actor>\n    <name>Ken Watanabe</name>\n  </actor>"))
        #expect(xml.contains("<fileinfo>"))
        #expect(xml.contains("<streamdetails>"))
        #expect(xml.contains("<codec>hevc</codec>"))
        #expect(xml.contains("<width>3840</width>"))
        #expect(xml.contains("<height>2160</height>"))
        #expect(xml.contains("<durationinseconds>8880</durationinseconds>"))
        #expect(xml.contains("<hdrtype>dolbyvision</hdrtype>"))
        #expect(xml.contains("<codec>atmos</codec>"))
        #expect(xml.contains("<channels>8</channels>"))
    }

    @Test("tvshowNfo and episodedetailsNfo XML generation")
    func tvAndEpisodeNfoXml() {
        let show = ShowDetail(
            info: Candidate(
                tmdbId: 1668,
                kind: .episode,
                title: "老友记",
                originalTitle: "Friends",
                year: 1994,
                imdbId: "tt0108778",
                tvdbId: 79168,
                certification: "TV-14",
                studios: ["NBC"],
                actors: [PersonCredit(name: "Jennifer Aniston", role: "Rachel Green", profilePath: "/jen.jpg")],
                directors: ["David Crane"],
                writers: ["Marta Kauffman"],
                tags: ["sitcom"]
            ),
            seasons: [
                SeasonInfo(number: 1, episodeCount: 24, airDate: utcDate(1994, 9, 22)),
            ]
        )

        let xml = tvshowNfo(show)
        #expect(xml.contains("<tvshow>"))
        #expect(xml.contains(#"<uniqueid type="tmdb" default="true">1668</uniqueid>"#))
        #expect(xml.contains(#"<uniqueid type="imdb">tt0108778</uniqueid>"#))
        #expect(xml.contains(#"<uniqueid type="tvdb">79168</uniqueid>"#))
        #expect(xml.contains("<mpaa>TV-14</mpaa>"))
        #expect(xml.contains("<studio>NBC</studio>"))
        #expect(xml.contains("<premiered>1994-09-22</premiered>"))
        #expect(!xml.contains("<set>"))

        let showCand = Candidate(tmdbId: 1, kind: .episode, title: "异兽魔都")
        let epWithRuntime = episodedetailsNfo(
            show: showCand,
            season: 1,
            episode: 1,
            info: Episode(season: 1, number: 1, title: "洞窟", airDate: utcDate(2020, 1, 12), runtimeMinutes: 24)
        )
        #expect(epWithRuntime.contains("<title>洞窟</title>"))
        #expect(epWithRuntime.contains("<aired>2020-01-12</aired>"))
        #expect(epWithRuntime.contains("<runtime>24</runtime>"))
        #expect(!epWithRuntime.contains("<fileinfo>"))

        let epWithoutRuntime = episodedetailsNfo(show: showCand, season: 1, episode: 2)
        #expect(!epWithoutRuntime.contains("<runtime>"))
    }

    @Test("AnchorRecognizer extracts TMDB id from existing tvshow.nfo and movie.nfo and ignores episodedetails")
    func recognizerNfoExtraction() async throws {
        actor CountingNoSearchMeta: MetadataProvider {
            let inner = TestMetadataProvider()
            private var showCalls = 0
            func getShowCalls() -> Int { showCalls }

            func search(_ query: String, kind: MediaKind?, year: Int?) async throws -> [Candidate] { [] }
            func show(_ tmdbId: Int) async throws -> ShowDetail {
                showCalls += 1
                return try await inner.show(tmdbId)
            }
            func season(_ tmdbId: Int, season: Int) async throws -> [Episode] {
                try await inner.season(tmdbId, season: season)
            }
            func episodeGroups(_ tmdbId: Int) async throws -> [EpisodeGroup] {
                try await inner.episodeGroups(tmdbId)
            }
            func movie(_ tmdbId: Int) async throws -> MovieDetail {
                try await inner.movie(tmdbId)
            }
        }

        func runNfo(_ files: [String: String], root: String = "/库") async throws -> (MediaGroup, Int) {
            let meta = CountingNoSearchMeta()
            let rec = AnchorRecognizer(parser: TestFilenameParser(), metadata: meta)
            let scan = try await rec.recognize(
                connection: "c",
                roots: [root],
                files: entriesOf(Array(files.keys)),
                read: { path in Data((files[path] ?? "").utf8) }
            )
            let calls = await meta.getShowCalls()
            return (scan.groups[0], calls)
        }

        let (g1, _) = try await runNfo([
            "/库/乱七八糟/S01E01.mkv": "",
            "/库/乱七八糟/tvshow.nfo":
                #"<?xml version="1.0"?><tvshow><title>x</title><uniqueid type="tmdb" default="true">\#(TestDemo.dorohedoro.tmdbId)</uniqueid></tvshow>"#,
        ])
        #expect(g1.match?.tmdbId == TestDemo.dorohedoro.tmdbId)
        #expect(g1.matchScore == 1.0)

        let (g2, _) = try await runNfo([
            "/库/盗梦/x.mkv": "",
            "/库/盗梦/x.nfo": "<movie><tmdbid>\(TestDemo.inception.tmdbId)</tmdbid></movie>",
        ])
        #expect(g2.match?.tmdbId == TestDemo.inception.tmdbId)
        #expect(g2.kind == .movie)

        let (g3, _) = try await runNfo([
            "/库/乱七八糟/S01E01.mkv": "",
            "/库/乱七八糟/S01E01.nfo": #"<episodedetails><uniqueid type="tmdb">999</uniqueid></episodedetails>"#,
            "/库/乱七八糟/tvshow.nfo": "<tvshow><title>没有 id</title></tvshow>",
        ])
        #expect(g3.match == nil)

        // Promoted root still reads tvshow.nfo from inner dir and fetches show() once
        let (g4, showCalls) = try await runNfo([
            "/库/我的番剧/内层目录/S01E01.mkv": "",
            "/库/我的番剧/内层目录/tvshow.nfo": "<tvshow><tmdbid>\(TestDemo.dorohedoro.tmdbId)</tmdbid></tvshow>",
        ], root: "/库/我的番剧")
        #expect(g4.rootDir == "/库/我的番剧")
        #expect(g4.match?.tmdbId == TestDemo.dorohedoro.tmdbId)
        #expect(showCalls == 1)

        // RangeReadableBackend caps NFO read to 512 KiB instead of calling full read()
        actor RangeRecordingBackend: RangeReadableBackend {
            let files: [String: Data]
            var rangeCalls: [(path: String, start: Int64, length: Int)] = []
            var fullReadCalls = 0

            init(_ files: [String: Data]) { self.files = files }

            func list(_ dir: String, refresh: Bool) async throws -> [RemoteEntry] { [] }
            func mkdirs(_ dir: String) async throws {}
            func rename(_ path: String, newName: String) async throws {}
            func renameMany(_ dir: String, names: [String: String]) async throws {}
            func move(srcDir: String, dstDir: String, names: [String]) async throws {}
            func remove(dir: String, names: [String]) async throws {}
            func exists(_ path: String) async throws -> Bool { files[path] != nil }
            func read(_ path: String) async throws -> Data {
                fullReadCalls += 1
                return files[path] ?? Data()
            }
            func write(_ path: String, bytes: Data) async throws {}
            func ping() async throws {}
            func close() async {}
            func readRange(path: String, start: Int64, length: Int) async throws -> Data {
                rangeCalls.append((path, start, length))
                guard let d = files[path] else { throw StorageError(.notFound, "missing") }
                let s = Int(start)
                let e = min(d.count, s + length)
                return s < e ? d.subdata(in: s..<e) : Data()
            }
        }

        let nfoXml = "<tvshow><tmdbid>\(TestDemo.dorohedoro.tmdbId)</tmdbid></tvshow>"
        let rangeBe = RangeRecordingBackend(["/库/大文件/tvshow.nfo": Data(nfoXml.utf8)])
        let rangeMeta = CountingNoSearchMeta()
        let rangeScan = try await AnchorRecognizer(parser: TestFilenameParser(), metadata: rangeMeta).recognize(
            connection: "c",
            roots: ["/库"],
            files: [
                RemoteEntry(path: "/库/大文件/S01E01.mkv", name: "S01E01.mkv", isDir: false, size: 100),
                RemoteEntry(path: "/库/大文件/tvshow.nfo", name: "tvshow.nfo", isDir: false, size: 5 * 1024 * 1024),
            ],
            read: { try await rangeBe.read($0) },
            backend: rangeBe
        )
        #expect(rangeScan.groups[0].match?.tmdbId == TestDemo.dorohedoro.tmdbId)
        let recordedRanges = await rangeBe.rangeCalls
        let recordedFullReads = await rangeBe.fullReadCalls
        #expect(recordedRanges.count == 1)
        #expect(recordedRanges[0].start == 0)
        #expect(recordedRanges[0].length == 512 * 1024)
        #expect(recordedFullReads == 0)

        // Non-range-readable fallback skips oversized (>2 MiB) NFO files without calling read()
        actor ReadCounter {
            var count = 0
            func bump() { count += 1 }
        }
        let oversizedReads = ReadCounter()
        let oversizedScan = try await AnchorRecognizer(parser: TestFilenameParser(), metadata: CountingNoSearchMeta()).recognize(
            connection: "c",
            roots: ["/库"],
            files: [
                RemoteEntry(path: "/库/损坏/S01E01.mkv", name: "S01E01.mkv", isDir: false, size: 100),
                RemoteEntry(path: "/库/损坏/tvshow.nfo", name: "tvshow.nfo", isDir: false, size: 3 * 1024 * 1024),
            ],
            read: { _ in
                await oversizedReads.bump()
                return Data(nfoXml.utf8)
            }
        )
        #expect(oversizedScan.groups[0].match == nil)
        let oversizedReadCount = await oversizedReads.count
        #expect(oversizedReadCount == 0)
    }
}
