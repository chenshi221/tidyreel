import Testing
import TidyreelModels
import TidyreelPlanner

@Suite("Follow Matcher Tests")
struct FollowTests {
    private func sub(
        _ path: String,
        season: Int? = nil,
        episode: Int? = nil,
        absolute: Int? = nil,
        year: Int? = nil,
        lang: String? = nil
    ) -> ScanFile {
        ScanFile(
            path: path,
            name: baseOf(path),
            size: 1,
            role: .subtitle,
            parsed: ParsedName(
                year: year,
                season: season,
                episodes: episode.map { [$0] } ?? [],
                absolute: absolute,
                lang: lang,
                confidence: 0.9
            )
        )
    }

    private func movie(_ path: String, year: Int? = nil, title: String? = nil) -> ScanFile {
        ScanFile(
            path: path,
            name: baseOf(path),
            size: 1,
            role: .video,
            parsed: ParsedName(title: title, year: year, kind: .movie, confidence: 0.9)
        )
    }

    @Test("langFromRemainder handles underscore and hyphen locale tags")
    func langFromRemainderCases() {
        #expect(langFromRemainder(".zh_CN") == "zh-Hans")
        #expect(langFromRemainder(".zh_TW") == "zh-Hant")
        #expect(langFromRemainder(".zh_TW.forced") == "zh-Hant")
        #expect(langFromRemainder("_zh_TW_forced") == "zh-Hant")
        #expect(langFromRemainder(".zh_Hant.sdh") == "zh-Hant")
        #expect(langFromRemainder(".zh_Hans.default") == "zh-Hans")
        #expect(langFromRemainder(".en_US.sdh") == "en")
        #expect(langFromRemainder(".en_GB.forced") == "en")
        #expect(langFromRemainder("-zh-TW-forced") == "zh-Hant")
        #expect(langFromRemainder(".chs&eng") == "zh-Hans")
        #expect(langFromRemainder("-chs") == "zh-Hans")
        #expect(langFromRemainder("-poster") == nil)
        #expect(langFromRemainder("") == nil)
    }

    @Test("subFlagsFromRemainder extracts flags in canonical order")
    func subFlagsCases() {
        #expect(subFlagsFromRemainder(".forced") == ["forced"])
        #expect(subFlagsFromRemainder(".force") == ["forced"])
        #expect(subFlagsFromRemainder(".强制") == ["forced"])
        #expect(subFlagsFromRemainder(".default") == ["default"])
        #expect(subFlagsFromRemainder(".默认") == ["default"])
        #expect(subFlagsFromRemainder(".sdh") == ["sdh"])
        #expect(subFlagsFromRemainder(".hi") == ["sdh"])
        #expect(subFlagsFromRemainder(".cc") == ["sdh"])
        #expect(subFlagsFromRemainder(".听障") == ["sdh"])
        #expect(subFlagsFromRemainder(".bilingual") == ["bilingual"])
        #expect(subFlagsFromRemainder(".dual") == ["bilingual"])
        #expect(subFlagsFromRemainder(".双语") == ["bilingual"])
        #expect(subFlagsFromRemainder(".中英双语") == ["bilingual"])

        for rem in [".chs&eng", ".cht&eng", ".chs+jpn", ".sc&jp", ".tc+en", ".zh&en", ".chs.eng", ".zh_CN.en_US", ".chs.cht"] {
            #expect(subFlagsFromRemainder(rem) == ["bilingual"])
        }

        #expect(subFlagsFromRemainder(".zh_CN.chs").isEmpty)
        #expect(subFlagsFromRemainder(".en.eng").isEmpty)
        #expect(subFlagsFromRemainder(".zh_TW").isEmpty)
        #expect(subFlagsFromRemainder(".Dual.Audio.en").isEmpty)

        #expect(subFlagsFromRemainder(".default.forced.hi.cc.chs&eng.双语.force") == [
            "bilingual", "sdh", "forced", "default",
        ])
    }

    @Test("Step 1: exact prefix match prefers longest match, same folder, and respects E1 vs E10 boundary")
    func step1PrefixMatch() {
        let v1 = makeVideo("/a/Show.S01E01.mkv", season: 1, episode: 1)
        let vOther = makeVideo("/b/Show.S01E01.mkv", season: 1, episode: 1)
        let s = sub("/a/Show.S01E01.zh_CN.forced.srt")
        let m = matchVideo(s, [vOther, v1])
        #expect(m?.video.path == "/a/Show.S01E01.mkv")
        #expect(m?.remainder == ".zh_CN.forced")

        let e1 = makeVideo("/a/Show E1.mkv", episode: 1)
        let e10 = makeVideo("/a/Show E10.mkv", episode: 10)
        let sub10 = makeOther("/a/Show E10.chs.ass", .subtitle)
        #expect(matchVideo(sub10, [e1, e10])?.video.name == "Show E10.mkv")
        #expect(matchVideo(sub10, [e1]) == nil)
    }

    @Test("Step 2: episode number fallback, multi-track sidecar remainder, and ambiguity guards")
    func step2EpisodeFallback() {
        let v1 = makeVideo("/show/Show.S01E01.mkv", season: 1, episode: 1)
        let v2 = makeVideo("/show/Show.S01E02.mkv", season: 1, episode: 2)
        let s2 = sub("/show/Subs/Different.S01E02.chs.ass", season: 1, episode: 2)
        #expect(matchVideo(s2, [v1, v2])?.video.path == "/show/Show.S01E02.mkv")

        let s1 = sub("/show/Subs/Other.S01E01.zh_TW.forced.ass", season: 1, episode: 1)
        let sm = matchVideo(s1, [v1])
        #expect(sm?.video.path == v1.path)
        #expect(langFromRemainder(sm!.remainder) == "zh-Hant")
        #expect(subFlagsFromRemainder(sm!.remainder) == ["forced"])

        let mkaJpn = ScanFile(
            path: "/show/Audio/Other.S01E01.jpn.dts.mka",
            name: "Other.S01E01.jpn.dts.mka",
            size: 1,
            role: .sidecar,
            parsed: ParsedName(season: 1, episodes: [1], confidence: 0.9)
        )
        let mkaChs = ScanFile(
            path: "/show/Audio/Other.S01E01.chs.flac.mka",
            name: "Other.S01E01.chs.flac.mka",
            size: 1,
            role: .sidecar,
            parsed: ParsedName(season: 1, episodes: [1], confidence: 0.9)
        )
        #expect(matchVideo(mkaJpn, [v1])?.remainder == ".jpn.dts")
        #expect(matchVideo(mkaChs, [v1])?.remainder == ".chs.flac")

        let thumb = ScanFile(
            path: "/show/Art/Other.S01E01-thumb.jpg",
            name: "Other.S01E01-thumb.jpg",
            size: 1,
            role: .sidecar,
            parsed: ParsedName(season: 1, episodes: [1], confidence: 0.9)
        )
        #expect(matchVideo(thumb, [v1])?.remainder == "-thumb")

        // Unambiguous non-special vs ambiguous ties
        let s0e1 = makeVideo("/show/Show.S00E01.mkv", season: 0, episode: 1)
        let s1e1 = makeVideo("/show/Show.S01E01.mkv", season: 1, episode: 1)
        let s2e1 = makeVideo("/show/Show.S02E01.mkv", season: 2, episode: 1)
        let v1080 = makeVideo("/show/Show.S01E01.1080p.mkv", season: 1, episode: 1)
        let v2160 = makeVideo("/show/Show.S01E01.2160p.mkv", season: 1, episode: 1)

        let ep1Sub = sub("/show/Other.EP01.chs.srt", episode: 1)
        #expect(matchVideo(ep1Sub, [s0e1, s1e1])?.video.path == s1e1.path)
        #expect(matchVideo(ep1Sub, [s1e1, s2e1]) == nil)

        let s1Sub = sub("/show/Other.S01E01.chs.srt", season: 1, episode: 1)
        #expect(matchVideo(s1Sub, [v1080, v2160]) == nil)
    }

    @Test("Step 3: fuzzy same-folder fallback, Force Awakens guard, CJK bigrams, and conflict guards")
    func step3FuzzyFallback() {
        let v = movie("/movies/Inception/Inception.2010.2160p.UHD.BluRay.REMUX.mkv", year: 2010, title: "Inception")
        let s = sub("/movies/Inception/shooter_sub_9912.chs&eng.forced.srt")
        let m = matchVideo(s, [v])
        #expect(m?.video.path == v.path)
        #expect(langFromRemainder(m!.remainder) == "zh-Hans")
        #expect(subFlagsFromRemainder(m!.remainder) == ["bilingual", "forced"])

        // Sidecar and other-dir subtitles do not use Step 3a
        #expect(matchVideo(makeOther("/movies/Inception/poster.jpg", .sidecar), [v]) == nil)
        #expect(matchVideo(sub("/other/shooter_sub_9912.chs.srt"), [v]) == nil)

        // Force Awakens title word must not trigger forced flag
        let forceV = movie("/movies/Force/The.Force.Awakens.2015.2160p.mkv", year: 2015, title: "The Force Awakens")
        let forceSub = sub("/movies/Force/Force.Awakens.2015.chs.srt")
        let fm = matchVideo(forceSub, [forceV])
        #expect(fm?.video.path == forceV.path)
        #expect(langFromRemainder(fm!.remainder) == "zh-Hans")
        #expect(subFlagsFromRemainder(fm!.remainder).isEmpty)

        // Step 3b: multi-video token overlap
        let m1 = movie("/movies/The.Matrix.1999.2160p.UHD.BluRay.REMUX.mkv", year: 1999, title: "The Matrix")
        let m2 = movie("/movies/The.Matrix.Reloaded.2003.2160p.UHD.BluRay.REMUX.mkv", year: 2003, title: "The Matrix Reloaded")
        let subReloaded = sub("/movies/The.Matrix.Reloaded.2003.1080p.WEB-DL.zh_TW.sdh.srt")
        let res = matchVideo(subReloaded, [m1, m2])
        #expect(res?.video.path == m2.path)
        #expect(langFromRemainder(res!.remainder) == "zh-Hant")
        #expect(subFlagsFromRemainder(res!.remainder) == ["sdh"])

        // Traditional Chinese subtitle matches Simplified Chinese video
        let cn1 = movie("/movies/盗梦空间.2010.BluRay.mkv", year: 2010, title: "盗梦空间")
        let cn2 = movie("/movies/星际穿越.2014.BluRay.mkv", year: 2014, title: "星际穿越")
        let cnSub = sub("/movies/盜夢空間.WEB-DL.中英双语.ass")
        let cnRes = matchVideo(cnSub, [cn1, cn2])
        #expect(cnRes?.video.path == cn1.path)
        #expect(subFlagsFromRemainder(cnRes!.remainder) == ["bilingual"])

        // Conflict guards
        let ep1 = makeVideo("/tv/Show.S01E01.mkv", season: 1, episode: 1)
        let ep2 = makeVideo("/tv/Show.S01E02.mkv", season: 1, episode: 2)
        let ep3Sub = sub("/tv/Show.S01E03.chs.srt")
        #expect(matchVideo(ep3Sub, [ep1]) == nil)
        #expect(matchVideo(ep3Sub, [ep1, ep2]) == nil)
        #expect(matchVideo(sub("/mixed/Show.S01E01.chs.srt"), [movie("/mixed/Inception.2010.mkv", year: 2010, title: "Inception")]) == nil)
        #expect(matchVideo(sub("/tv/Show.chs.srt"), [ep1, ep2]) == nil)

        let f1 = movie("/m/Tenet.2020.1080p.BluRay.mkv", year: 2020, title: "Tenet")
        let f2 = movie("/m/Soul.2020.1080p.BluRay.mkv", year: 2020, title: "Soul")
        #expect(matchVideo(sub("/m/Mulan.2020.1080p.BluRay.chs.srt"), [f1, f2]) == nil)

        // followConflicts & VideoMatchIndex reuse
        #expect(followConflicts(sub("/tv/Other.S01E02.srt"), ep1) == true)
        #expect(followConflicts(sub("/m/Matrix.1999.srt", year: 1999), v) == true)
        #expect(followConflicts(sub("/m/shooter.chs.srt"), v) == false)

        let index = VideoMatchIndex([ep1, ep2, v])
        #expect(index.match(sub("/tv/Show.S01E02.chs.srt"))?.video.path == ep2.path)
        #expect(index.match(sub("/tv/Subs/Other.S01E01.chs.srt", season: 1, episode: 1))?.video.path == ep1.path)
    }
}
