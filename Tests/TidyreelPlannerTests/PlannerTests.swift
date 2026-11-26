import Foundation
import Testing
import TidyreelFakes
import TidyreelModels
import TidyreelPlanner

@Suite("DefaultPlanner Tests")
struct PlannerTests {
    private let conn = ConnectionId("c")
    private let root = "/d/异兽魔都 2020"
    private let season1Dir = "/d/异兽魔都 2020/Season 01"
    private let name = "异兽魔都.Dorohedoro.2020"

    private func buildPlan(
        _ scan: ScanResult,
        decisions: [GroupId: GroupDecision] = [:],
        options: PlanOptions = PlanOptions(),
        existing: Set<String> = [],
        existingDirs: Set<String>? = nil,
        metadata: (any MetadataProvider)? = nil
    ) async throws -> RenamePlan {
        try await DefaultPlanner(metadata: metadata ?? TestMetadataProvider()).build(
            scan: scan,
            decisions: decisions,
            options: options,
            existing: existing,
            existingDirs: existingDirs
        )
    }

    @Test("end-to-end inPlace TV show with subtitles, Extras, and junk")
    func endToEndInPlaceTv() async throws {
        let show = "/下载/异兽魔都 2020 1080p"
        let e1 = "[Sub] Dorohedoro S01E01 [1080p]"
        let paths = [
            "\(show)/Season 1/\(e1).mkv",
            "\(show)/Season 1/\(e1).chs.ass",
            "\(show)/Season 1/\(e1).eng.srt",
            "\(show)/Season 1/[Sub] Dorohedoro S01E02 [1080p].mkv",
            "\(show)/Season 2/[Sub] Dorohedoro S02E01 [1080p].mkv",
            "\(show)/Season 2/[Sub] Dorohedoro S02E01 [1080p].cht.ass",
            "\(show)/Extras/花絮 PV.mkv",
            "\(show)/RARBG.txt",
            "/下载/其他/readme.pdf",
        ]
        let meta = TestMetadataProvider()
        let scan = try await AnchorRecognizer(parser: TestFilenameParser(), metadata: meta).recognize(
            connection: conn,
            roots: ["/下载"],
            files: entriesOf(paths)
        )
        let backend = MemoryStorageBackend(initialSizes: Dictionary(uniqueKeysWithValues: paths.map { ($0, 1) }))
        let p = try await buildPlan(scan, existing: Set(paths), metadata: meta)
        #expect(p.canExecute == true)

        try await applyPlan(p, to: backend)
        let out = "/下载/异兽魔都 (2020)"
        let finalFiles = try await allBackendFiles(backend)
        #expect(finalFiles == [
            "/下载/其他/readme.pdf",
            "\(out)/Extras/花絮 PV.mkv",
            "\(out)/RARBG.txt",
            "\(out)/Season 01/\(name).S01E01.en.srt",
            "\(out)/Season 01/\(name).S01E01.mkv",
            "\(out)/Season 01/\(name).S01E01.zh-Hans.ass",
            "\(out)/Season 01/\(name).S01E02.mkv",
            "\(out)/Season 02/\(name).S02E01.mkv",
            "\(out)/Season 02/\(name).S02E01.zh-Hant.ass",
        ].sorted())

        // deleteJunk: true deletes junk after folder rename
        let delPlan = try await buildPlan(scan, options: PlanOptions(deleteJunk: true), metadata: meta)
        let delOp = delPlan.ops.first { $0.kind == .delete }!
        #expect(delOp.phase == .cleanup)
        #expect(delOp.src == "\(out)/RARBG.txt")
        #expect(delOp.selected == true)
    }

    @Test("end-to-end moveToLibrary movie and missing libraryRoot error")
    func endToEndMoveToLibraryMovie() async throws {
        let src = "/下载/Inception.2010.1080p.BluRay"
        let paths = [
            "\(src)/Inception.2010.1080p.BluRay.mkv",
            "\(src)/Inception.2010.1080p.BluRay.chs.srt",
            "\(src)/Inception.2010.1080p.BluRay.nfo",
            "\(src)/Extras/花絮.mkv",
            "\(src)/www.site.url",
        ]
        let meta = TestMetadataProvider()
        let scan = try await AnchorRecognizer(parser: TestFilenameParser(), metadata: meta).recognize(
            connection: conn,
            roots: ["/下载"],
            files: entriesOf(paths)
        )
        let backend = MemoryStorageBackend(initialSizes: Dictionary(uniqueKeysWithValues: paths.map { ($0, 1) }))
        let p = try await buildPlan(
            scan,
            options: PlanOptions(mode: .moveToLibrary, libraryRoot: "/影视库"),
            metadata: meta
        )
        #expect(p.canExecute == true)
        #expect(p.ops.filter { $0.kind == .mkdir }.map(\.dst) == [
            "/影视库/电影",
            "/影视库/电影/盗梦空间 (2010)",
            "/影视库/电影/盗梦空间 (2010)/Extras",
        ])
        try await applyPlan(p, to: backend)
        let lib = "/影视库/电影/盗梦空间 (2010)"
        #expect(try await allBackendFiles(backend) == [
            "\(lib)/Extras/花絮.mkv",
            "\(lib)/盗梦空间.Inception.2010.mkv",
            "\(lib)/盗梦空间.Inception.2010.nfo",
            "\(lib)/盗梦空间.Inception.2010.zh-Hans.srt",
            "\(src)/www.site.url",
        ].sorted())

        await #expect(throws: PlannerError.self) {
            try await buildPlan(
                makeScan([makeTvGroup([makeVideo("\(root)/a.mkv", season: 1, episode: 1)])]),
                options: PlanOptions(mode: .moveToLibrary)
            )
        }
    }

    @Test("conflict detection, shifting renames, case-insensitivity, and punctuation-preserving title")
    func conflictRules() async throws {
        let files = [
            makeVideo("\(season1Dir)/\(name).S01E01.mkv", season: 1, episode: 1),
            makeVideo("\(season1Dir)/\(name).S01E02.mkv", season: 1, episode: 2),
        ]

        // Shifting into each other is NOT a conflict
        let shifted = try await buildPlan(
            makeScan([makeTvGroup(files)]),
            decisions: ["g1": GroupDecision(episodeOffset: 1)],
            existing: Set(files.map(\.path) + [root])
        )
        #expect(shifted.canExecute == true)
        #expect(movesMap(shifted) == [
            files[0].path: "\(season1Dir)/\(name).S01E02.mkv",
            files[1].path: "\(season1Dir)/\(name).S01E03.mkv",
        ])

        // Existing stationary target conflicts (case-insensitively)
        let existingConflict = try await buildPlan(
            makeScan([makeTvGroup([makeVideo("\(root)/a.mkv", season: 1, episode: 1)])]),
            existing: ["\(season1Dir)/\(name).S01E01.MKV"]
        )
        #expect(existingConflict.canExecute == false)
        #expect(existingConflict.conflicts.count == 1)

        // Two files renaming to paths differing only in extension case collide
        let caseCollide = try await buildPlan(
            makeScan([makeTvGroup([
                makeVideo("\(root)/a.mkv", season: 1, episode: 1),
                makeVideo("\(root)/b.MKV", season: 1, episode: 1),
            ])])
        )
        #expect(caseCollide.canExecute == false)
        #expect(caseCollide.conflicts[0].ops.count == 2)

        // Punctuation-only TMDB difference keeps local title
        let punctMatch = Candidate(
            tmdbId: TestDemo.dorohedoro.tmdbId,
            kind: .episode,
            title: "异兽魔都！",
            englishTitle: TestDemo.dorohedoro.englishTitle,
            originalTitle: TestDemo.dorohedoro.originalTitle,
            year: TestDemo.dorohedoro.year
        )
        let samePunct = try await buildPlan(
            makeScan([makeTvGroup(
                [makeVideo("/d/异兽魔都 (2020)/Season 01/\(name).S01E01.mkv", season: 1, episode: 1)],
                rootDir: "/d/异兽魔都 (2020)",
                match: punctMatch
            )])
        )
        #expect(samePunct.ops.allSatisfy { $0.src == $0.dst })
    }

    @Test("season strategies, EpisodeGroup layouts, overflow warnings, and overrides")
    func strategiesEpisodeGroupsAndOverrides() async throws {
        let absFiles = [
            makeVideo("\(root)/a.mkv", absolute: 1),
            makeVideo("\(root)/b.mkv", absolute: 12),
            makeVideo("\(root)/c.mkv", absolute: 13),
            makeVideo("\(root)/d.mkv", absolute: 23),
        ]
        func expectedPath(_ s: Int, _ e: Int) -> String {
            String(format: "\(root)/Season %02d/\(name).S%02dE%02d.mkv", s, s, e)
        }

        let seqPlan = try await buildPlan(
            makeScan([makeTvGroup(absFiles)]),
            decisions: ["g1": GroupDecision(strategy: .splitSequential)]
        )
        #expect(["a", "b", "c", "d"].map { opFor(seqPlan, "\(root)/\($0).mkv").dst } == [
            expectedPath(1, 1), expectedPath(1, 12), expectedPath(2, 1), expectedPath(2, 11),
        ])

        // Overflow goes to last season, selected, with warning
        let overPlan = try await buildPlan(
            makeScan([makeTvGroup([
                makeVideo("\(root)/a.mkv", absolute: 23),
                makeVideo("\(root)/b.mkv", absolute: 25),
            ])]),
            decisions: ["g1": GroupDecision(strategy: .splitSequential)]
        )
        let overOp = opFor(overPlan, "\(root)/b.mkv")
        #expect(overOp.dst == expectedPath(2, 13))
        #expect(overOp.selected == true)
        #expect(overOp.warning?.contains("超出 TMDB 总集数") == true)

        // EpisodeGroup custom layout remaps asParsed S02E01 -> S01E13
        let eg = EpisodeGroup(
            id: "abs",
            name: "绝对顺序",
            type: 2,
            seasons: [
                EpisodeGroupSeason(
                    order: 1,
                    name: "All",
                    episodes: (1...12).map { EpisodeRef(1, $0) } + (1...11).map { EpisodeRef(2, $0) }
                ),
            ]
        )
        let egMeta = TestMetadataProvider(groupsByShow: [TestDemo.dorohedoro.tmdbId: [eg]])
        let egPlan = try await buildPlan(
            makeScan([makeTvGroup([
                makeVideo("\(root)/x.mkv", season: 2, episode: 1),
                makeVideo("\(root)/y.mkv", season: 1, episode: 3),
            ])]),
            decisions: ["g1": GroupDecision(strategy: .asParsed, episodeGroupId: "abs")],
            metadata: egMeta
        )
        #expect(opFor(egPlan, "\(root)/x.mkv").dst == expectedPath(1, 13))
        #expect(opFor(egPlan, "\(root)/y.mkv").dst == expectedPath(1, 3))

        // Per-file overrides & companion override when video is ignored
        let ovPlan = try await buildPlan(
            makeScan([makeTvGroup([
                makeVideo("\(root)/a.mkv", season: 1, episode: 1),
                makeOther("\(root)/a.srt", .subtitle),
                makeVideo("\(root)/c.mkv", season: 1, episode: 2),
                makeVideo("\(root)/d.mkv", season: 1, episode: 3),
            ])]),
            decisions: ["g1": GroupDecision(overrides: [
                "\(root)/a.mkv": FileOverride(ignore: true),
                "\(root)/a.srt": FileOverride(season: 2, episode: 3),
                "\(root)/c.mkv": FileOverride(kind: .extra),
                "\(root)/d.mkv": FileOverride(kind: .special),
            ])]
        )
        #expect(!ovPlan.ops.contains(where: { $0.src == "\(root)/a.mkv" && $0.selected }))
        #expect(opFor(ovPlan, "\(root)/a.srt").dst == "\(root)/Season 02/\(name).S02E03.srt")
        #expect(opFor(ovPlan, "\(root)/c.mkv").dst == "\(root)/Extras/c.mkv")
        #expect(opFor(ovPlan, "\(root)/d.mkv").dst == "\(root)/Season 00/\(name).S00E03.mkv")
    }

    @Test("season folder reuse, variety-show airDate, multi-episode, multi-part, and multi-version")
    func advancedNamingAndVersions() async throws {
        // 1. 4K subfolder reused as Season 01 + airDate matching
        let meta = TestMetadataProvider()
        let reuseScan = try await AnchorRecognizer(parser: TestFilenameParser(), metadata: meta).recognize(
            connection: conn,
            roots: ["/下载"],
            files: entriesOf(["/下载/异兽魔都/4K/01.mkv", "/下载/异兽魔都/4K/02.mkv", "/下载/异兽魔都/4K/03.mkv"])
        )
        let reusePlan = try await buildPlan(reuseScan, metadata: meta)
        #expect(opFor(reusePlan, "/下载/异兽魔都/4K/01.mkv").dst == "/下载/异兽魔都/4K/\(name).S01E01.mkv")
        #expect(opFor(reusePlan, "/下载/异兽魔都/4K").dst == "/下载/异兽魔都/Season 01")

        let varietyScan = try await AnchorRecognizer(parser: TestFilenameParser(), metadata: meta).recognize(
            connection: conn,
            roots: ["/下载"],
            files: entriesOf(["/下载/异兽魔都/异兽魔都.20200119.mkv"])
        )
        let varietyPlan = try await buildPlan(varietyScan, metadata: meta)
        #expect(opFor(varietyPlan, "/下载/异兽魔都/异兽魔都.20200119.mkv").dst.hasSuffix("S01E02.mkv"))

        // 2. Multi-episode range & duplicate subtitles
        let rangePlan = try await buildPlan(makeScan([makeTvGroup([
            ScanFile(
                path: "\(root)/ep1-2.mkv",
                name: "ep1-2.mkv",
                size: 1,
                role: .video,
                parsed: ParsedName(season: 1, episodes: [1, 2], lang: "chs", extraInfo: "1080p.HDR", confidence: 0.9)
            ),
            makeOther("\(root)/ep1-2.chs.srt", .subtitle),
            makeOther("\(root)/ep1-2.sc.srt", .subtitle),
        ])]))
        #expect(opFor(rangePlan, "\(root)/ep1-2.mkv").dst == "\(season1Dir)/\(name).S01E01-E02.mkv")
        #expect(opFor(rangePlan, "\(root)/ep1-2.chs.srt").dst == "\(season1Dir)/\(name).S01E01-E02.zh-Hans.srt")
        #expect(opFor(rangePlan, "\(root)/ep1-2.sc.srt").dst == "\(season1Dir)/\(name).S01E01-E02.zh-Hans.2.srt")

        // 3. Multi-part (-cd1 / -cd2) and multi-version editions
        let mpPlan = try await buildPlan(makeScan([MediaGroup(
            id: "g-mp",
            kind: .movie,
            anchorTitle: "Inception",
            anchorYear: 2010,
            rootDir: "/dl/Inception",
            files: [
                ScanFile(
                    path: "/dl/Inception/Inception.2010.CD1.mkv",
                    name: "Inception.2010.CD1.mkv",
                    size: 100,
                    role: .video,
                    parsed: ParsedName(title: "Inception", year: 2010, kind: .movie, confidence: 0.92, part: 1, partLabel: "cd1")
                ),
                ScanFile(
                    path: "/dl/Inception/Inception.2010.CD2.mkv",
                    name: "Inception.2010.CD2.mkv",
                    size: 100,
                    role: .video,
                    parsed: ParsedName(title: "Inception", year: 2010, kind: .movie, confidence: 0.92, part: 2, partLabel: "cd2")
                ),
                ScanFile(
                    path: "/dl/Inception/Inception.2010.CD1.chs.srt",
                    name: "Inception.2010.CD1.chs.srt",
                    size: 10,
                    role: .subtitle,
                    parsed: ParsedName(lang: "chs", confidence: 0.9)
                ),
            ],
            match: TestDemo.inception,
            matchScore: 0.95
        )]))
        #expect(mpPlan.canExecute == true)
        #expect(opFor(mpPlan, "/dl/Inception/Inception.2010.CD1.mkv").dst == "/dl/Inception/盗梦空间.Inception.2010-cd1.mkv")
        #expect(opFor(mpPlan, "/dl/Inception/Inception.2010.CD2.mkv").dst == "/dl/Inception/盗梦空间.Inception.2010-cd2.mkv")
        #expect(opFor(mpPlan, "/dl/Inception/Inception.2010.CD1.chs.srt").dst == "/dl/Inception/盗梦空间.Inception.2010-cd1.zh-Hans.srt")

        let edPlan = try await buildPlan(makeScan([MediaGroup(
            id: "g-ed",
            kind: .movie,
            anchorTitle: "Inception",
            anchorYear: 2010,
            rootDir: "/dl/Inception",
            files: [
                ScanFile(
                    path: "/dl/Inception/Inception.DC.mkv",
                    name: "Inception.DC.mkv",
                    size: 100,
                    role: .video,
                    parsed: ParsedName(title: "Inception", year: 2010, kind: .movie, confidence: 0.92, edition: "Director's Cut")
                ),
                ScanFile(
                    path: "/dl/Inception/Inception.Theatrical.mkv",
                    name: "Inception.Theatrical.mkv",
                    size: 100,
                    role: .video,
                    parsed: ParsedName(title: "Inception", year: 2010, kind: .movie, confidence: 0.92, edition: "Theatrical")
                ),
            ],
            match: TestDemo.inception,
            matchScore: 0.95
        )]))
        #expect(edPlan.canExecute == true)
        #expect(opFor(edPlan, "/dl/Inception/Inception.DC.mkv").dst == "/dl/Inception/盗梦空间.Inception.2010 - Director's Cut.mkv")
        #expect(opFor(edPlan, "/dl/Inception/Inception.Theatrical.mkv").dst == "/dl/Inception/盗梦空间.Inception.2010 - Theatrical.mkv")
    }

    @Test("subtitle flags, BDMV disc relocation, scrapeOnly, overwriteNfo, unassignedDeletes, and PlanMerge")
    func v1UpgradesAndMerges() async throws {
        // 1. Subtitle flags + bilingual disambiguation
        let subPlan = try await buildPlan(makeScan([makeTvGroup([
            makeVideo("\(root)/ep1.mkv", season: 1, episode: 1),
            ScanFile(path: "\(root)/ep1.chs.forced.srt", name: "ep1.chs.forced.srt", size: 1, role: .subtitle, parsed: ParsedName(lang: "chs", confidence: 0.9, subFlags: ["forced"])),
            ScanFile(path: "\(root)/ep1.chs.srt", name: "ep1.chs.srt", size: 1, role: .subtitle, parsed: ParsedName(lang: "chs", confidence: 0.9)),
            ScanFile(path: "\(root)/ep1.chs-eng.srt", name: "ep1.chs-eng.srt", size: 1, role: .subtitle, parsed: ParsedName(lang: "chs", confidence: 0.9, subFlags: ["bilingual"])),
        ])]))
        let base = "\(season1Dir)/\(name).S01E01"
        #expect(opFor(subPlan, "\(root)/ep1.chs.forced.srt").dst == "\(base).zh-Hans.forced.srt")
        #expect(opFor(subPlan, "\(root)/ep1.chs.srt").dst == "\(base).zh-Hans.srt")
        #expect(opFor(subPlan, "\(root)/ep1.chs-eng.srt").dst == "\(base).zh-Hans.bilingual.srt")

        // 2. Rich scrape, scrapeOnly, and overwriteNfo
        let richShow = ShowDetail(
            info: Candidate(
                tmdbId: 94954,
                kind: .episode,
                title: "异兽魔都",
                englishTitle: "Dorohedoro",
                year: 2020,
                posterPath: "/p.jpg",
                backdropPath: "/b.jpg",
                clearLogoPath: "/logo.png",
                landscapePath: "/land.jpg"
            ),
            seasons: [SeasonInfo(number: 1, episodeCount: 12, posterPath: "/s1.jpg")]
        )
        let richMeta = TestMetadataProvider(
            showsById: [94954: richShow],
            seasonsByShow: [94954: [1: [Episode(season: 1, number: 1, title: "洞窟", stillPath: "/e1.jpg")]]]
        )
        let scrapeOnlyPlan = try await buildPlan(
            makeScan(
                [makeTvGroup([makeVideo("\(root)/raw_ep01.mkv", season: 1, episode: 1)], rootDir: root, show: nil)],
                unassigned: [makeOther("\(root)/ad.txt", .junk)]
            ),
            options: PlanOptions(deleteJunk: true, scrape: false, scrapeOnly: true),
            metadata: richMeta
        )
        #expect(!scrapeOnlyPlan.ops.isEmpty)
        #expect(scrapeOnlyPlan.ops.allSatisfy { $0.kind == .write })
        let scrapeDsts = Set(scrapeOnlyPlan.ops.map(\.dst))
        #expect(scrapeDsts.isSuperset(of: [
            "\(root)/tvshow.nfo", "\(root)/poster.jpg", "\(root)/fanart.jpg",
            "\(root)/clearlogo.png", "\(root)/landscape.jpg",
            "\(root)/raw_ep01.nfo", "\(root)/raw_ep01-thumb.jpg",
        ]))

        let out = "/d/异兽魔都 (2020)"
        let overPlan = try await buildPlan(
            makeScan([makeTvGroup([makeVideo("\(root)/E01.mkv", season: 1, episode: 1)], rootDir: root, show: nil)]),
            options: PlanOptions(scrape: true, overwriteNfo: true),
            existing: ["\(out)/tvshow.nfo", "\(out)/poster.jpg"],
            metadata: richMeta
        )
        let nfoWrite = overPlan.ops.first { $0.dst == "\(out)/tvshow.nfo" }!
        #expect(nfoWrite.selected == true && nfoWrite.overwrite == true && nfoWrite.warning == nil)
        let posterWrite = overPlan.ops.first { $0.dst == "\(out)/poster.jpg" }!
        #expect(posterWrite.selected == false && posterWrite.overwrite == false && posterWrite.warning == "已存在，保留原文件")

        // 3. BDMV disc folder relocation
        let discScan = makeScan([MediaGroup(
            id: "g-disc",
            kind: .movie,
            anchorTitle: "Inception",
            anchorYear: 2010,
            rootDir: "/dl/Inception.2010.BluRay",
            files: [ScanFile(
                path: "/dl/Inception.2010.BluRay",
                name: "Inception.2010.BluRay",
                size: 40000,
                role: .video,
                parsed: ParsedName(title: "Inception", year: 2010, kind: .movie, confidence: 0.92, isDisc: true),
                isDiscDir: true
            )],
            match: TestDemo.inception,
            matchScore: 0.98
        )], roots: ["/dl"])
        let discPlan = try await buildPlan(
            discScan,
            options: PlanOptions(mode: .moveToLibrary, libraryRoot: "/lib", scrape: true),
            metadata: richMeta
        )
        let discReloc = discPlan.ops.first { $0.kind == .relocate }!
        #expect(discReloc.phase == .folders)
        #expect(discReloc.dst == "/lib/电影/盗梦空间 (2010)")
        #expect(discPlan.ops.contains(where: { $0.kind == .write && $0.dst == "/lib/电影/盗梦空间 (2010)/movie.nfo" }))

        // 4. PlanMerge & GroupDecision(separate: true) & existingDirs
        let mergeScan = makeScan([
            makeTvGroup([makeVideo("/d/异兽魔都 S01/E01.mkv", season: 1, episode: 1)], rootDir: "/d/异兽魔都 S01", id: "g1"),
            makeTvGroup([makeVideo("/d/异兽魔都 S02/E01.mkv", season: 2, episode: 1)], rootDir: "/d/异兽魔都 S02", id: "g2"),
        ])
        let merged = try await buildPlan(mergeScan)
        #expect(merged.merges.count == 1)
        #expect(merged.merges[0].group == "g2")
        #expect(merged.merges[0].withGroup == "g1")
        #expect(merged.merges[0].seasons == [2])

        let separated = try await buildPlan(mergeScan, decisions: ["g2": GroupDecision(separate: true)])
        #expect(separated.merges.isEmpty)

        // Dotted folder Dr.Who (2005) recognized via existingDirs vs extensionless file
        let drWho = Candidate(tmdbId: 57243, kind: .episode, title: "Dr.Who", year: 2005)
        let drScan = makeScan([MediaGroup(
            id: "g-dr",
            kind: .episode,
            anchorTitle: "Dr.Who",
            rootDir: "/in/Dr.Who",
            files: [makeVideo("/in/Dr.Who/S01E01.mkv", season: 1, episode: 1)],
            match: drWho,
            matchScore: 0.95,
            show: ShowDetail(info: drWho, seasons: [SeasonInfo(number: 1, episodeCount: 13)])
        )], roots: ["/in"])
        let drOpts = PlanOptions(mode: .moveToLibrary, libraryRoot: "/lib", naming: NamingProfile(tvDir: "TV"))
        let drDirPlan = try await buildPlan(
            drScan,
            options: drOpts,
            existing: ["/lib/TV/Dr.Who (2005)"],
            existingDirs: ["/lib/TV", "/lib/TV/Dr.Who (2005)"]
        )
        #expect(drDirPlan.merges.count == 1)

        let drFilePlan = try await buildPlan(
            drScan,
            options: drOpts,
            existing: ["/lib/TV/Dr.Who (2005)"],
            existingDirs: ["/lib/TV"]
        )
        #expect(drFilePlan.merges.isEmpty)

        // 5. unassignedDeletes per-file overrides
        let junkPlan = try await buildPlan(
            makeScan(
                [makeTvGroup([makeVideo("\(root)/a.mkv", season: 1, episode: 1)])],
                unassigned: [
                    makeOther("\(root)/ad.txt", .junk),
                    makeOther("\(root)/keep.txt", .junk),
                    makeOther("/d/notes.pdf", .other),
                ]
            ),
            options: PlanOptions(
                deleteJunk: true,
                unassignedDeletes: ["\(root)/keep.txt": false, "/d/notes.pdf": true]
            )
        )
        let dels = Dictionary(uniqueKeysWithValues: junkPlan.ops.filter { $0.kind == .delete }.map { ($0.src, $0.selected) })
        #expect(dels["\(out)/ad.txt"] == true)
        #expect(dels["\(out)/keep.txt"] == false)
        #expect(dels["/d/notes.pdf"] == true)
    }

    @Test("concurrent bounded metadata prefetch deduplicates fetches and preserves deterministic plan order")
    func concurrentBoundedPrefetchAndIndices() async throws {
        actor ConcurrentTrackingMeta: MetadataProvider {
            let inner: TestMetadataProvider
            var active = 0
            var maxActive = 0
            var showCalls: [Int: Int] = [:]
            var seasonCalls: [String: Int] = [:]

            init(showsById: [Int: ShowDetail], seasonsByShow: [Int: [Int: [Episode]]]) {
                self.inner = TestMetadataProvider(showsById: showsById, seasonsByShow: seasonsByShow)
            }

            private func enter() {
                active += 1
                if active > maxActive { maxActive = active }
            }
            private func leave() {
                active -= 1
            }

            func search(_ query: String, kind: MediaKind?, year: Int?) async throws -> [Candidate] {
                try await inner.search(query, kind: kind, year: year)
            }

            func show(_ tmdbId: Int) async throws -> ShowDetail {
                enter()
                defer { leave() }
                showCalls[tmdbId, default: 0] += 1
                try? await Task.sleep(nanoseconds: 15_000_000)
                return try await inner.show(tmdbId)
            }

            func season(_ tmdbId: Int, season: Int) async throws -> [Episode] {
                enter()
                defer { leave() }
                seasonCalls["\(tmdbId):\(season)", default: 0] += 1
                try? await Task.sleep(nanoseconds: 15_000_000)
                return try await inner.season(tmdbId, season: season)
            }

            func episodeGroups(_ tmdbId: Int) async throws -> [EpisodeGroup] {
                try await inner.episodeGroups(tmdbId)
            }

            func movie(_ tmdbId: Int) async throws -> MovieDetail {
                enter()
                defer { leave() }
                try? await Task.sleep(nanoseconds: 15_000_000)
                return try await inner.movie(tmdbId)
            }
        }

        var showsById: [Int: ShowDetail] = [:]
        var seasonsByShow: [Int: [Int: [Episode]]] = [:]
        var groups: [MediaGroup] = []
        for i in 1...8 {
            let tmdbId = 1000 + i
            let cand = Candidate(tmdbId: tmdbId, kind: .episode, title: "剧集\(i)", year: 2020)
            showsById[tmdbId] = ShowDetail(info: cand, seasons: [SeasonInfo(number: 1, episodeCount: 10)])
            seasonsByShow[tmdbId] = [1: [Episode(season: 1, number: 1, title: "Ep1-\(i)")]]
            groups.append(MediaGroup(
                id: GroupId("g-\(i)"),
                kind: .episode,
                anchorTitle: "剧集\(i)",
                anchorYear: 2020,
                rootDir: "/d/Show\(i)",
                files: [makeVideo("/d/Show\(i)/4K/S01E01.mkv", season: 1, episode: 1, title: "Show\(i)")],
                match: cand,
                matchScore: 0.95,
                show: nil
            ))
        }
        // Add a second group sharing Show 1's tmdbId to verify deduplication & merge ordering
        let cand1 = showsById[1001]!.info
        groups.append(MediaGroup(
            id: GroupId("g-1-extra"),
            kind: .episode,
            anchorTitle: "剧集1",
            anchorYear: 2020,
            rootDir: "/d/Show1_Extra",
            files: [makeVideo("/d/Show1_Extra/S01E02.mkv", season: 1, episode: 2, title: "Show1")],
            match: cand1,
            matchScore: 0.95,
            show: nil
        ))

        let trackingMeta = ConcurrentTrackingMeta(showsById: showsById, seasonsByShow: seasonsByShow)
        let plan = try await buildPlan(
            makeScan(
                groups,
                unassigned: [makeOther("/d/Show1/4K/ad.txt", .junk)]
            ),
            options: PlanOptions(deleteJunk: true, scrape: true),
            existing: [
                "/d/Show1/tvshow.nfo",
                "/d/Show1/4K/剧集1.2020.S01E01.nfo",
            ],
            metadata: trackingMeta
        )

        #expect(plan.canExecute == true)
        #expect(plan.merges.count == 1)
        #expect(plan.merges[0].group == GroupId("g-1-extra"))
        #expect(plan.merges[0].withGroup == GroupId("g-1"))

        let maxConc = await trackingMeta.maxActive
        let show1Calls = await trackingMeta.showCalls[1001]
        let season1Calls = await trackingMeta.seasonCalls["1001:1"]
        #expect(maxConc >= 2)
        #expect(maxConc <= 6)
        #expect(show1Calls == 1)
        #expect(season1Calls == 1)

        // preRenamePath detects existing NFOs across both renamed root and reused season folder
        let show1Nfo = plan.ops.first { $0.kind == .write && $0.dst == "/d/剧集1 (2020)/tvshow.nfo" }!
        #expect(show1Nfo.selected == false && show1Nfo.warning == "已存在，保留原文件")
        let ep1Nfo = plan.ops.first { $0.kind == .write && $0.dst == "/d/剧集1 (2020)/Season 01/剧集1.2020.S01E01.nfo" }!
        #expect(ep1Nfo.selected == false && ep1Nfo.warning == "已存在，保留原文件")

        // Junk under both renamed root and reused season folder resolves to final path
        let delOp = plan.ops.first { $0.kind == .delete }!
        #expect(delOp.src == "/d/剧集1 (2020)/Season 01/ad.txt")
    }
}
