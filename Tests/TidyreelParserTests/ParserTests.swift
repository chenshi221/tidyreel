import Foundation
import Testing
import TidyreelModels
import TidyreelParser

private let parser = RuleBasedParser()

private let noneInt = -1
private let noStr = "∅"

private struct ParseFixture {
    let name: String
    let dirs: [String]
    let t: String?
    let y: Int?
    let s: Int?
    let e: [Int]?
    let a: Int?
    let k: MediaKind?
    let r: String?
    let g: String?
    let l: String?
    let x: String?
    let hi: Bool
    let lo: Bool

    init(
        _ name: String,
        dirs: [String] = [],
        t: String? = nil,
        y: Int? = nil,
        s: Int? = nil,
        e: [Int]? = nil,
        a: Int? = nil,
        k: MediaKind? = nil,
        r: String? = nil,
        g: String? = nil,
        l: String? = nil,
        x: String? = nil,
        hi: Bool = false,
        lo: Bool = false
    ) {
        self.name = name
        self.dirs = dirs
        self.t = t
        self.y = y
        self.s = s
        self.e = e
        self.a = a
        self.k = k
        self.r = r
        self.g = g
        self.l = l
        self.x = x
        self.hi = hi
        self.lo = lo
    }
}

private func checkFixture(_ c: ParseFixture) -> [String] {
    let r = parser.parse(c.name, parentDirs: c.dirs)
    var bad: [String] = []

    func checkStr(_ field: String, _ want: String?, _ got: String?) {
        guard let want else { return }
        let expected: String? = (want == noStr) ? nil : want
        if expected != got {
            bad.append("\(field): want \(String(describing: expected)), got \(String(describing: got))")
        }
    }

    func checkInt(_ field: String, _ want: Int?, _ got: Int?) {
        guard let want else { return }
        let expected: Int? = (want == noneInt) ? nil : want
        if expected != got {
            bad.append("\(field): want \(String(describing: expected)), got \(String(describing: got))")
        }
    }

    checkStr("title", c.t, r.title)
    checkInt("year", c.y, r.year)
    checkInt("season", c.s, r.season)
    checkInt("absolute", c.a, r.absolute)
    if let wantKind = c.k, r.kind != wantKind {
        bad.append("kind: want \(wantKind), got \(r.kind)")
    }
    checkStr("resolution", c.r, r.resolution)
    checkStr("group", c.g, r.group)
    checkStr("lang", c.l, r.lang)
    checkStr("extraInfo", c.x, r.extraInfo)
    if let wantEps = c.e, r.episodes != wantEps {
        bad.append("episodes: want \(wantEps), got \(r.episodes)")
    }
    if c.hi && r.confidence < 0.9 {
        bad.append("confidence \(r.confidence) < 0.9")
    }
    if c.lo && r.confidence >= 0.5 {
        bad.append("confidence \(r.confidence) >= 0.5")
    }
    return bad
}

private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    return cal.date(from: DateComponents(year: year, month: month, day: day))!
}

// MARK: - Full Fixture Corpus (Western, Chinese, Anime, Folders, Noise, Movies, Subtitles, Extras)

private let parseFixtures: [ParseFixture] = [
    // Western scene / PT names
    ParseFixture("The.Show.S01E01.1080p.WEB-DL.x264-GRP.mkv", t: "The Show", s: 1, e: [1], k: .episode, r: "1080p", g: "GRP", hi: true),
    ParseFixture("Game.of.Thrones.S06E05.1080p.BluRay.x264-DEMAND.mkv", t: "Game of Thrones", s: 6, e: [5], r: "1080p", g: "DEMAND", hi: true),
    ParseFixture("Breaking.Bad.S05E16.720p.HDTV.x264-IMMERSE.mkv", t: "Breaking Bad", s: 5, e: [16], r: "720p", g: "IMMERSE", hi: true),
    ParseFixture("The.Office.US.S02E03.720p.WEB-DL.mkv", t: "The Office US", s: 2, e: [3], hi: true),
    ParseFixture("Friends.S10E17.E18.1080p.BluRay.x265-RARBG.mp4", t: "Friends", s: 10, e: [17, 18], g: "RARBG"),
    ParseFixture("Show.Name.S01E01-E02.720p.HDTV.mkv", t: "Show Name", s: 1, e: [1, 2], hi: true),
    ParseFixture("Show.Name.S01E01E02.mkv", t: "Show Name", s: 1, e: [1, 2]),
    ParseFixture("Show.Name.S01E01-02.mkv", t: "Show Name", s: 1, e: [1, 2]),
    ParseFixture("Show.Name.S03E10-E12.mkv", t: "Show Name", s: 3, e: [10, 11, 12]),
    ParseFixture("show name 1x02.avi", t: "show name", s: 1, e: [2], k: .episode, hi: true),
    ParseFixture("Show.Name.01x02.HDTV.avi", t: "Show Name", s: 1, e: [2], hi: true),
    ParseFixture("Show.Name.10x15.mkv", t: "Show Name", s: 10, e: [15]),
    ParseFixture("Show.Name.S01.1080p.BluRay.x264-GRP.mkv", t: "Show Name", s: 1, e: [], k: .episode, lo: true),
    ParseFixture("Stranger.Things.S04E01.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.H.265-FLUX.mkv", t: "Stranger Things", s: 4, e: [1], r: "2160p", g: "FLUX", x: "2160p.DV.Atmos"),
    ParseFixture("The.Mandalorian.S02E08.2160p.WEB-DL.DDP5.1.Atmos.HDR10+.HEVC-GRP.mkv", t: "The Mandalorian", s: 2, e: [8], g: "GRP", x: "2160p.HDR10+.Atmos"),
    ParseFixture("House.of.the.Dragon.S01E01.1080p.WEB-DL.DD5.1.H.264-GRP.mkv", t: "House of the Dragon", s: 1, e: [1], g: "GRP", x: "1080p"),
    ParseFixture("Chernobyl.2019.S01E02.1080p.WEBRip.x264-GRP.mkv", t: "Chernobyl", y: 2019, s: 1, e: [2]),
    ParseFixture("Doctor.Who.2005.S10E01.720p.HDTV.mkv", t: "Doctor Who", y: 2005, s: 10, e: [1]),
    ParseFixture("The.Walking.Dead.S11E24.Rest.in.Peace.1080p.AMZN.WEB-DL.mkv", t: "The Walking Dead", s: 11, e: [24], r: "1080p"),
    ParseFixture("Seinfeld - S03E05 - The Parking Garage.avi", t: "Seinfeld", s: 3, e: [5], hi: true),
    ParseFixture("Seinfeld - 3x05 - The Parking Garage.avi", t: "Seinfeld", s: 3, e: [5], hi: true),
    ParseFixture("Lost.S01E01.Pilot.Part.1.DVDRip.XviD-GRP.avi", t: "Lost", s: 1, e: [1], g: "GRP"),
    ParseFixture("Better.Call.Saul.S06E13.Saul.Gone.1080p.NF.WEB-DL.mkv", t: "Better Call Saul", s: 6, e: [13]),
    ParseFixture("Succession.S04E10.With.Open.Eyes.2160p.WEB-DL.mkv", t: "Succession", s: 4, e: [10], r: "2160p"),
    ParseFixture("the.big.bang.theory.s12e24.720p.hdtv.x264-avs.mkv", t: "the big bang theory", s: 12, e: [24], g: "avs"),
    ParseFixture("Peaky Blinders S06E01 1080p.mkv", t: "Peaky Blinders", s: 6, e: [1], r: "1080p"),
    ParseFixture("Peaky.Blinders.Season.6.Episode.1.mkv", t: "Peaky Blinders", s: 6, e: [1]),
    ParseFixture("Show Name - Season 2 Episode 5.mkv", t: "Show Name", s: 2, e: [5]),
    ParseFixture("Show.Name.S02.Complete.1080p.mkv", t: "Show Name", s: 2, e: [], lo: true),
    ParseFixture("Show.Name.Season.3.1080p.mkv", t: "Show Name", s: 3, e: [], lo: true),
    ParseFixture("Westworld.S04E08.1080p.WEB.H264-GLHF.mkv", t: "Westworld", s: 4, e: [8], g: "GLHF"),
    ParseFixture("Ted.Lasso.S03E12.2160p.ATVP.WEB-DL.DDP5.1.DV.HEVC-GRP.mkv", t: "Ted Lasso", s: 3, e: [12], x: "2160p.DV"),
    ParseFixture("Dark.S03E08.German.1080p.NF.WEB-DL.mkv", t: "Dark", s: 3, e: [8]),
    ParseFixture("Money.Heist.S05E10.MULTi.1080p.WEB.x264-GRP.mkv", t: "Money Heist", s: 5, e: [10], g: "GRP"),
    ParseFixture("Sherlock.S04E03.The.Final.Problem.1080p.BluRay.x264.mkv", t: "Sherlock", s: 4, e: [3]),
    ParseFixture("Fargo.US.S05E10.1080p.WEB.h264-ETHEL.mkv", t: "Fargo US", s: 5, e: [10], g: "ETHEL"),
    ParseFixture("The.Boys.S04E01.1080p.AMZN.WEB-DL.DDP5.1.H.264-NTb.mkv", t: "The Boys", s: 4, e: [1], g: "NTb"),
    ParseFixture("shameless.us.s11e12.720p.web.x264-tbs.mkv", t: "shameless us", s: 11, e: [12], g: "tbs"),
    ParseFixture("Show.Name.S01E01.mkv", t: "Show Name", s: 1, e: [1], hi: true),
    ParseFixture("Show_Name_S01E01_720p.mkv", t: "Show Name", s: 1, e: [1], r: "720p"),
    ParseFixture("Show Name S01E01.mp4", t: "Show Name", s: 1, e: [1], hi: true),
    ParseFixture("S01E05.mkv", t: noStr, s: 1, e: [5], k: .episode),
    ParseFixture("Show.Name.s1e1.mkv", t: "Show Name", s: 1, e: [1]),
    ParseFixture("Show.Name.S1E1.mkv", t: "Show Name", s: 1, e: [1]),
    ParseFixture("Show.Name.S01E100.mkv", t: "Show Name", s: 1, e: [100]),
    ParseFixture("Show.Name.E05.mkv", t: "Show Name", s: noneInt, e: [5], a: noneInt),
    ParseFixture("Show.Name.Ep05.mkv", t: "Show Name", s: noneInt, e: [5]),
    ParseFixture("Show.Name.Episode.5.mkv", t: "Show Name", s: noneInt, e: [5]),
    ParseFixture("Show.Name.2010.S01E01.mkv", t: "Show Name", y: 2010, s: 1, e: [1], hi: true),
    ParseFixture("Show (2010) - S01E01 - Pilot.mkv", t: "Show", y: 2010, s: 1, e: [1], hi: true),
    ParseFixture("Show.Name.(2010).S01E01.mkv", t: "Show Name", y: 2010, s: 1, e: [1]),
    ParseFixture("Show Name [2010] S01E01.mkv", t: "Show Name", y: 2010, s: 1, e: [1]),
    ParseFixture("Spider-Man.The.Animated.Series.S01E01.mkv", t: "Spider-Man The Animated Series", s: 1, e: [1], g: noStr),
    ParseFixture("Grey's.Anatomy.S19E05.720p.HDTV.x264-SYNCOPY.mkv", t: "Grey's Anatomy", s: 19, e: [5], g: "SYNCOPY"),
    ParseFixture("Show.S01E01.REPACK.1080p.mkv", t: "Show", s: 1, e: [1]),
    ParseFixture("Show.S01E01.PROPER.720p.HDTV.x264-DIMENSION.mkv", t: "Show", s: 1, e: [1], g: "DIMENSION"),
    ParseFixture("Show.Name.S01E01.1080p.BluRay.REMUX.AVC.DTS-HD.MA.5.1-GRP.mkv", t: "Show Name", s: 1, e: [1], g: "GRP", x: "1080p.DTS-HD"),
    ParseFixture("Show.Name.S01E01.1080p.WEB-DL.AAC2.0.H.264-GRP.mkv", t: "Show Name", s: 1, e: [1], r: "1080p", g: "GRP"),
    ParseFixture("The.Daily.Show.2023.05.12.720p.WEB.mkv", t: "The Daily Show", y: noneInt),
    ParseFixture("Show 2023-05-12 S01E01.mkv", t: "Show", y: noneInt, s: 1, e: [1]),
    ParseFixture("Euphoria.US.S02E03.2160p.MAX.WEB-DL.DDP5.1.HDR.H.265-GRP.mkv", t: "Euphoria US", s: 2, e: [3], x: "2160p.HDR"),
    ParseFixture("Severance.S02E01.2160p.ATVP.WEB-DL.DDP5.1.Atmos.DV.H.265-GRP.mkv", t: "Severance", s: 2, e: [1], x: "2160p.DV.Atmos"),
    ParseFixture("Planet.Earth.II.S01E01.Islands.2160p.BluRay.mkv", t: "Planet Earth II", s: 1, e: [1], r: "2160p"),
    ParseFixture("24.S01E01.720p.BluRay.mkv", t: "24", s: 1, e: [1]),
    ParseFixture("9-1-1.S06E01.1080p.WEB.mkv", t: "9-1-1", s: 6, e: [1]),

    // Chinese-language names
    ParseFixture("[字幕组] 繁花 第01集 1080p.mp4", t: "繁花", s: noneInt, e: [1], k: .episode, r: "1080p", g: "字幕组", hi: true),
    ParseFixture("繁花.第十二集.mkv", t: "繁花", e: [12], k: .episode, hi: true),
    ParseFixture("【高清】狂飙 EP05.mp4", t: "狂飙", e: [5], g: noStr, hi: true),
    ParseFixture("狂飙.第5集.mkv", t: "狂飙", e: [5], hi: true),
    ParseFixture("狂飙.EP05.1080p.WEB-DL.mkv", t: "狂飙", e: [5], r: "1080p", hi: true),
    ParseFixture("漫长的季节 第2季 第3集.mkv", t: "漫长的季节", s: 2, e: [3], hi: true),
    ParseFixture("庆余年.第二季.第12集.2160p.mkv", t: "庆余年", s: 2, e: [12], r: "2160p", hi: true),
    ParseFixture("庆余年 第二季 第十二集.mp4", t: "庆余年", s: 2, e: [12], hi: true),
    ParseFixture("去有风的地方.第20集.4K.mp4", t: "去有风的地方", e: [20], r: "2160p"),
    ParseFixture("某剧.第一百零五集.mkv", t: "某剧", e: [105]),
    ParseFixture("某剧.第二十集.mkv", t: "某剧", e: [20]),
    ParseFixture("某剧.第十集.mkv", t: "某剧", e: [10]),
    ParseFixture("某剧.第一百集.mkv", t: "某剧", e: [100]),
    ParseFixture("某剧.第二十三集.mkv", t: "某剧", e: [23]),
    ParseFixture("某剧.第一千零八十话.mkv", t: "某剧", e: [1080]),
    ParseFixture("某剧 第3话.mkv", t: "某剧", e: [3]),
    ParseFixture("某剧 第03話.mkv", t: "某剧", e: [3]),
    ParseFixture("某剧 第5期.mp4", t: "某剧", e: [5]),
    ParseFixture("【更多资源】繁花 第08集.mkv", t: "繁花", e: [8], g: noStr),
    ParseFixture("[www.xxx.com] 繁花 第08集.mkv", t: "繁花", e: [8], g: noStr),
    ParseFixture("www.yyds.com 繁花 第08集.mkv", t: "繁花", e: [8]),
    ParseFixture("繁花.2023.EP08.1080p.WEB-DL.H265.AAC-GRP.mp4", t: "繁花", y: 2023, e: [8], g: "GRP", hi: true),
    ParseFixture("【4K】狂飙 EP05.mp4", t: "狂飙", e: [5], r: "2160p", g: noStr),
    ParseFixture("三国演义.1994.第01集.1080p.mkv", t: "三国演义", y: 1994, e: [1], hi: true),
    ParseFixture("老友记.Friends.1994.S02E03.1080p.BluRay.mkv", t: "老友记", y: 1994, s: 2, e: [3], hi: true),
    ParseFixture("Friends.老友记.S02E03.mkv", t: "老友记", s: 2, e: [3]),
    ParseFixture("权力的游戏.Game.of.Thrones.S06E05.mkv", t: "权力的游戏", s: 6, e: [5]),
    ParseFixture("生活大爆炸.The.Big.Bang.Theory.S12E24.mkv", t: "生活大爆炸", s: 12, e: [24]),
    ParseFixture("绝命毒师 Breaking Bad S05E16.mkv", t: "绝命毒师", s: 5, e: [16]),
    ParseFixture("龙珠 Z.第10集.mkv", t: "龙珠 Z", e: [10]),
    ParseFixture("破产姐妹.2 Broke Girls.S01E01.mkv", t: "破产姐妹", s: 1, e: [1]),
    ParseFixture("第01集.mkv", t: noStr, e: [1], k: .episode),
    ParseFixture("甄嬛传.01.mkv", t: "甄嬛传", a: 1, k: .episode, lo: true),
    ParseFixture("请回答1988.第01集.mkv", t: "请回答1988", y: noneInt, e: [1]),
    ParseFixture("大宅门.[第01集].mkv", t: "大宅门", e: [1]),
    ParseFixture("庆余年第二季.第12集.mkv", t: "庆余年", s: 2, e: [12]),
    ParseFixture("庆余年2.第12集.mkv", t: "庆余年2", e: [12]),
    ParseFixture("[字幕组] 繁花 第01集 [简体].mp4", t: "繁花", e: [1], g: "字幕组"),
    ParseFixture("[字幕组] 繁花 第01集 [CRC32 ABCD1234].mp4", t: "繁花", e: [1], g: "字幕组"),
    ParseFixture("《繁花》第01集.mkv", t: "繁花", e: [1]),
    ParseFixture("「繁花」 第01集.mkv", t: "繁花", e: [1]),
    ParseFixture("狂飙.2023.全39集.4K.mkv", t: "狂飙", y: 2023, e: [], k: .episode, lo: true),
    ParseFixture("S06E05 权力的游戏.mkv", t: noStr, s: 6, e: [5]),
    ParseFixture("(2023)繁花 第01集.mp4", t: "繁花", e: [1]),
    ParseFixture("繁花 EP01-EP02.mkv", t: "繁花", e: [1, 2]),
    ParseFixture("繁花 第01-03集.mp4", t: "繁花", e: [1, 2, 3]),
    ParseFixture("Show.E01-E02.1080p.mkv", t: "Show", e: [1, 2]),
    ParseFixture("Show.EP05-06.mkv", t: "Show", e: [5, 6]),
    ParseFixture("向往的生活.20240503.mp4", t: "向往的生活", e: [], k: .episode),
    ParseFixture("向往的生活 2024-05-03 1080p.mp4", t: "向往的生活", k: .episode),
    ParseFixture("20240503.mp4", dirs: ["奔跑吧"], t: "奔跑吧", k: .episode),
    ParseFixture("Mini.Series.1of6.720p.mkv", t: "Mini Series", s: noneInt, e: [1]),
    ParseFixture("Show - 03 of 12.mkv", t: "Show", e: [3]),
    ParseFixture("01.mkv", dirs: ["4K", "嫁金钗"], t: "嫁金钗", s: noneInt, a: 1),
    ParseFixture("12.mkv", dirs: ["2160p", "jiajinchai"], t: "jiajinchai", a: 12),
    ParseFixture("谜.探.路.德.维.希.S01E01.mkv", t: "谜探路德维希", s: 1, e: [1]),

    // Anime / fansub names
    ParseFixture("[Nekomoe] 海贼王 - 1080 [1080p].mkv", t: "海贼王", s: noneInt, e: [], a: 1080, k: .episode, r: "1080p", g: "Nekomoe"),
    ParseFixture("[Nekomoe kissaten] Frieren - 12 [1080p].mkv", t: "Frieren", s: noneInt, a: 12, r: "1080p", g: "Nekomoe kissaten"),
    ParseFixture("[SubsPlease] Spy x Family - 05 (1080p) [ABCD1234].mkv", t: "Spy x Family", a: 5, r: "1080p", g: "SubsPlease"),
    ParseFixture("[Erai-raws] Jujutsu Kaisen 2nd Season - 05 [1080p][Multiple Subtitle].mkv", t: "Jujutsu Kaisen", s: 2, e: [5], g: "Erai-raws"),
    ParseFixture("[Lilith-Raws] Kaiju No.8 - 03 [Baha][WEB-DL][1080p][AVC AAC][CHT][MP4].mp4", t: "Kaiju No 8", a: 3, r: "1080p", g: "Lilith-Raws"),
    ParseFixture("[ANi] 葬送的芙莉莲 - 12 [1080P][Baha][WEB-DL][AAC AVC][CHT].mp4", t: "葬送的芙莉莲", a: 12, r: "1080p", g: "ANi"),
    ParseFixture("[LoliHouse] 进击的巨人 最终季 - 05 [WebRip 1080p HEVC-10bit AAC].mkv", t: "进击的巨人 最终季", a: 5, r: "1080p", g: "LoliHouse"),
    ParseFixture("[Group] Title - 01v2 [ABCD1234].mkv", t: "Title", s: noneInt, a: 1, g: "Group"),
    ParseFixture("[Group] Title [01][1080p].mkv", t: "Title", a: 1, r: "1080p", g: "Group"),
    ParseFixture("[Group] Title [01v2][BDRip][1080p].mkv", t: "Title", a: 1, r: "1080p"),
    ParseFixture("[Group] Title 01 [1080p].mkv", t: "Title", a: 1, lo: true),
    ParseFixture("[Group] Title S2 - 05 [1080p].mkv", t: "Title", s: 2, e: [5]),
    ParseFixture("[Group] Title Season 2 - 05 [1080p].mkv", t: "Title", s: 2, e: [5]),
    ParseFixture("[Group] Title 2nd Season - 05.mkv", t: "Title", s: 2, e: [5]),
    ParseFixture("[Group] 标题 第二季 - 05.mkv", t: "标题", s: 2, e: [5]),
    ParseFixture("[Group] Title - OVA [BD 1080p].mkv", t: "Title", s: 0, e: [], k: .special),
    ParseFixture("[Group] Title - OVA1 [BD 1080p].mkv", t: "Title", s: 0, e: [1], k: .special),
    ParseFixture("[Group] Title OVA 02.mkv", t: "Title", s: 0, e: [2], k: .special),
    ParseFixture("[Group] Title - SP01 [BD 1080p].mkv", t: "Title", s: 0, e: [1], k: .special),
    ParseFixture("[Group] 标题 特别篇 01.mkv", t: "标题", s: 0, e: [1], k: .special),
    ParseFixture("[Group] 剧场版 名侦探柯南 绯色的子弹 [1080p].mkv", t: "名侦探柯南 绯色的子弹", k: .movie, r: "1080p"),
    ParseFixture("海贼王 剧场版 红发歌姬 2022.mkv", t: "海贼王 红发歌姬", y: 2022, k: .movie),
    ParseFixture("[喵萌奶茶屋&LoliHouse] 标题 - 05 [WebRip 1080p HEVC-10bit AAC][简繁内封字幕].mkv", t: "标题", a: 5, g: "喵萌奶茶屋&LoliHouse"),
    ParseFixture("[Group] Title - 12 (BD 1920x1080 x264 FLAC).mkv", t: "Title", a: 12, r: "1080p"),
    ParseFixture("[Group] Title - NCOP1 [BD 1080p].mkv", t: "Title", k: .extra),
    ParseFixture("[Group] Title NCED.mkv", t: "Title", k: .extra),
    ParseFixture("[Group] Title - Creditless Opening.mkv", t: "Title", k: .extra),
    ParseFixture("Title - PV1.mkv", t: "Title", k: .extra),
    ParseFixture("Title - CM01.mkv", t: "Title", k: .extra),
    ParseFixture("[Group] Title - 花絮 01.mkv", t: "Title", k: .extra),
    ParseFixture("[Group] Title [Menu].mkv", t: "Title", k: .extra),
    ParseFixture("[Group] Title - OP1.mkv", t: "Title", k: .extra),
    ParseFixture("[Group] Title - ED2.mkv", t: "Title", k: .extra),
    ParseFixture("[Group] Title vol.1 [1080p].mkv", t: "Title", e: [1]),
    ParseFixture("[BeanSub&FZSD][Detective_Conan][1100][GB][1080P][x264_AAC].mp4", t: "Detective Conan", a: 1100, r: "1080p", g: "BeanSub&FZSD"),
    ParseFixture("[字幕组&字幕组2][繁花][第01集].mp4", t: "繁花", e: [1], g: "字幕组&字幕组2"),
    ParseFixture("[Group] Re:Zero - 05v2 [1080p].mkv", t: "Re:Zero", a: 5),
    ParseFixture("[01] Title [1080p].mkv", t: "Title", a: 1),

    // Folder context
    ParseFixture("05.mkv", dirs: ["Season 6", "权力的游戏"], t: "权力的游戏", s: 6, e: [5], a: noneInt, k: .episode),
    ParseFixture("05.mkv", dirs: ["S06", "Game of Thrones"], t: "Game of Thrones", s: 6, e: [5]),
    ParseFixture("01.Pilot.mkv", dirs: ["Season 1", "Lost"], t: "Lost", s: 1, e: [1]),
    ParseFixture("291.mp4", dirs: ["龙珠Z"], t: "龙珠Z", s: noneInt, e: [], a: 291, k: .episode),
    ParseFixture("291.mp4", dirs: ["Dragon Ball Z (1989)"], t: "Dragon Ball Z", y: 1989, a: 291),
    ParseFixture("Inception.1080p.BluRay.mkv", dirs: ["Inception (2010)"], t: "Inception", y: 2010, k: .movie),
    ParseFixture("01.mkv", dirs: ["Specials", "Show"], t: "Show", s: 0, e: [1], k: .special),
    ParseFixture("01.mkv", dirs: ["Season 0", "Show"], t: "Show", s: 0, e: [1], k: .special),
    ParseFixture("01.mkv", dirs: ["Extras", "Show"], t: "Show", k: .extra),
    ParseFixture("Trailer.mkv", dirs: ["Movie Name (2019)"], t: "Movie Name", y: 2019, k: .extra),
    ParseFixture("05.mkv", dirs: ["Season 6"], t: noStr, s: 6, e: [5], lo: true),
    ParseFixture("05.mkv", t: noStr, a: 5, lo: true),
    ParseFixture("2012.mkv", t: "2012", k: .unknown, lo: true),
    ParseFixture("05.mkv", dirs: ["Season 1", "Show Name", "电视剧"], t: "Show Name", s: 1, e: [5]),
    ParseFixture("12.mkv", dirs: ["Season 3 [1080p]", "Show Name"], t: "Show Name", s: 3, e: [12]),
    ParseFixture("1080.mkv", dirs: ["海贼王"], t: "海贼王", a: 1080, k: .episode),
    ParseFixture("The Movie 2019.mkv", dirs: ["Season 1", "Show"], t: "The Movie", y: 2019),

    // Noise, resolutions, extraInfo, numeric titles
    ParseFixture("[www.xxx.com] The.Show.S01E01.720p.mkv", t: "The Show", s: 1, e: [1], g: noStr, hi: true),
    ParseFixture("www.xxx.com - The.Show.S01E01.mkv", t: "The Show", s: 1, e: [1]),
    ParseFixture("www.xxx.com@The.Show.S01E01.mkv", t: "The Show", s: 1, e: [1]),
    ParseFixture("[BBS.XXX.COM]The.Show.S01E01.mkv", t: "The Show", s: 1, e: [1], g: noStr),
    ParseFixture("【xxx论坛 bbs.xxx.com】The.Show.S01E01.mkv", t: "The Show", s: 1, e: [1], g: noStr),
    ParseFixture("[ABCD1234] Title - 01.mkv", t: "Title", a: 1, g: noStr),
    ParseFixture("Show.S01E01.1080i.HDTV.mkv", e: [1], r: "1080i"),
    ParseFixture("Show.S01E01.2160p.DoVi.mkv", x: "2160p.DV"),
    ParseFixture("Show.S01E01.2160p.HDR10+.mkv", x: "2160p.HDR10+"),
    ParseFixture("Show.S01E01.1080p.TrueHD.7.1.Atmos.mkv", x: "1080p.TrueHD.Atmos"),
    ParseFixture("Show.S01E01.2160p.DV.HDR10.Atmos.mkv", x: "2160p.DV.HDR10.Atmos"),
    ParseFixture("Show.S01E01.mkv", r: noStr, x: noStr),
    ParseFixture("Spider-Man.2002.1080p.BluRay.mkv", t: "Spider-Man", y: 2002, g: noStr),
    ParseFixture("Spider-Man.mkv", t: "Spider-Man", g: noStr),
    ParseFixture("2012.2009.1080p.BluRay.mkv", t: "2012", y: 2009, k: .movie, hi: true),
    ParseFixture("2012.1080p.BluRay.mkv", t: "2012", y: noneInt, k: .movie),
    ParseFixture("1917.2019.1080p.BluRay.x264.mkv", t: "1917", y: 2019, k: .movie, hi: true),
    ParseFixture("2001.A.Space.Odyssey.1968.mkv", t: "2001 A Space Odyssey", y: 1968),
    ParseFixture("Blade.Runner.2049.2017.mkv", t: "Blade Runner 2049", y: 2017),
    ParseFixture("Blade.Runner.2049.mkv", t: "Blade Runner 2049", y: noneInt),
    ParseFixture("9.2009.mkv", t: "9", y: 2009),
    ParseFixture("Ｓｈｏｗ　第０１集.mkv", t: "Show", e: [1]),
    ParseFixture("电影.2019.BD1080P.国粤双语.中字.mkv", t: "电影", y: 2019, r: "1080p"),

    // Movies
    ParseFixture("Inception.2010.1080p.BluRay.x264-SPARKS.mkv", t: "Inception", y: 2010, k: .movie, g: "SPARKS", hi: true),
    ParseFixture("Interstellar (2014).mkv", t: "Interstellar", y: 2014, k: .movie, hi: true),
    ParseFixture("Oppenheimer.2023.2160p.UHD.BluRay.REMUX.HDR.HEVC.Atmos-GRP.mkv", t: "Oppenheimer", y: 2023, g: "GRP", x: "2160p.HDR.Atmos"),
    ParseFixture("Avatar.The.Way.of.Water.2022.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-GRP.mkv", t: "Avatar The Way of Water", y: 2022, g: "GRP", x: "2160p.DV.HDR.Atmos"),
    ParseFixture("肖申克的救赎.The.Shawshank.Redemption.1994.1080p.BluRay.mkv", t: "肖申克的救赎", y: 1994, k: .movie, hi: true),
    ParseFixture("盗梦空间 Inception 2010 1080p.mkv", t: "盗梦空间", y: 2010),
    ParseFixture("Star.Wars.Episode.IV.A.New.Hope.1977.mkv", t: "Star Wars Episode IV A New Hope", y: 1977, k: .movie),
    ParseFixture("Mission.Impossible.3.2006.mkv", t: "Mission Impossible 3", y: 2006, e: [], k: .movie),
    ParseFixture("Harry.Potter.and.the.Deathly.Hallows.Part.2.2011.mkv", t: "Harry Potter and the Deathly Hallows Part 2", y: 2011),
    ParseFixture("你好，李焕英.2021.1080p.mkv", t: "你好,李焕英", y: 2021),
    ParseFixture("Dune.Part.Two.2024.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR10+.H.265-GRP.mkv", t: "Dune Part Two", y: 2024, g: "GRP", x: "2160p.DV.HDR10+.Atmos"),
    ParseFixture("流浪地球2.The.Wandering.Earth.II.2023.2160p.WEB-DL.mkv", t: "流浪地球2", y: 2023),
    ParseFixture("Mr.&.Mrs.Smith.2005.mkv", t: "Mr & Mrs Smith", y: 2005),

    // Subtitles
    ParseFixture("Show.S01E01.zh-CN.srt", t: "Show", s: 1, e: [1], l: "zh-CN"),
    ParseFixture("Show.S01E01.chs.ass", t: "Show", s: 1, e: [1], l: "chs"),
    ParseFixture("Show.S01E01.chs.eng.ass", s: 1, e: [1], l: "chs"),
    ParseFixture("Show.S01E01.简体.ass", t: "Show", s: 1, e: [1], l: "简体"),
    ParseFixture("繁花.第01集.简体&英文.ass", t: "繁花", e: [1], l: "简体"),
    ParseFixture("[Group] Title - 05.jpsc.ass", t: "Title", a: 5, l: "jpsc"),
    ParseFixture("05.chs.ass", dirs: ["Season 1", "Show"], t: "Show", s: 1, e: [5], l: "chs"),
    ParseFixture("chs.srt", t: noStr, l: "chs"),
    ParseFixture("Show.S01E01.chs.mkv", t: "Show", l: noStr),
    ParseFixture("Show.S01E01.zh_CN.srt", t: "Show", s: 1, e: [1], l: "zh_CN"),

    // Extras and title guards
    ParseFixture("Show.S00E01.Special.mkv", t: "Show", s: 0, e: [1], k: .special),
    ParseFixture("Show.S00E05.mkv", t: "Show", s: 0, e: [5], k: .special),
    ParseFixture("卫宫家今天的饭.Today's Menu for the Emiya Family.2018.S01E01.mkv", t: "卫宫家今天的饭", s: 1, e: [1], k: .episode),
    ParseFixture("Today's Menu for the Emiya Family - 03 [1080p].mkv", t: "Today's Menu for the Emiya Family", a: 3, k: .episode),
    ParseFixture("Show.S01.Menu.01.mkv", t: "Show", k: .extra),
    ParseFixture("[LoliHouse] Futsutsuka na Akujo dewa Gozaimasu ga - 09 [WebRip 1080p HEVC-10bit AAC ASSx2].mkv", t: "Futsutsuka na Akujo dewa Gozaimasu ga", a: 9, k: .episode, g: "LoliHouse"),
]

private let classifyFixtures: [(String, FileRole)] = [
    ("a.mkv", .video),
    ("a.mp4", .video),
    ("a.avi", .video),
    ("a.ts", .video),
    ("a.m2ts", .video),
    ("a.rmvb", .video),
    ("a.wmv", .video),
    ("a.mov", .video),
    ("a.flv", .video),
    ("a.webm", .video),
    ("a.iso", .video),
    ("A.MKV", .video),
    ("The.Show.S01E01.1080p.WEB-DL.x264-GRP.MKV", .video),
    ("a.srt", .subtitle),
    ("a.ass", .subtitle),
    ("a.ssa", .subtitle),
    ("a.sub", .subtitle),
    ("a.idx", .subtitle),
    ("a.sup", .subtitle),
    ("a.vtt", .subtitle),
    ("Show.S01E01.zh-CN.srt", .subtitle),
    ("a.nfo", .sidecar),
    ("tvshow.nfo", .sidecar),
    ("poster.jpg", .sidecar),
    ("fanart.jpg", .sidecar),
    ("folder.jpg", .sidecar),
    ("cover.png", .sidecar),
    ("Show.S01E01-thumb.jpg", .sidecar),
    ("a.mka", .sidecar),
    ("a.txt", .junk),
    ("a.url", .junk),
    ("a.html", .junk),
    ("a.lnk", .junk),
    ("更多资源.txt", .junk),
    ("www.xxx.com.url", .junk),
    ("Thumbs.db", .junk),
    (".DS_Store", .junk),
    ("desktop.ini", .junk),
    ("._Show.S01E01.mkv", .junk),
    ("sample.mkv", .junk),
    ("Sample.mp4", .junk),
    ("SAMPLE.MKV", .junk),
    ("Movie.2019-sample.mkv", .junk),
    ("Movie.2019.sample.mkv", .junk),
    ("sample-Movie.mkv", .junk),
    ("更多资源 www.xxx.com.mp4", .junk),
    ("【更多资源】.mp4", .junk),
    ("www.xxx.com.mp4", .junk),
    ("www.xxx.com.jpg", .junk),
    ("最新地址.jpg", .junk),
    ("更多资源请访问www.xxx.com.png", .junk),
    ("[www.xxx.com] 繁花 第01集.mkv", .video),
    ("【更多资源】繁花 第01集.mp4", .video),
    ("Show - [最新地址 www.a.com].mkv", .video),
    ("Sampler.mkv", .video),
    ("Show.zip", .other),
    ("Show.torrent", .other),
    ("noextension", .other),
    ("Show.S01E01.1080p", .other),
    ("Show.part1.rar", .other),
]

// MARK: - Test Suite

@Suite("TidyreelParser Tests")
struct ParserTests {
    @Test("All parse fixtures match expected fields")
    func allParseFixtures() {
        #expect(parseFixtures.count >= 160)
        var failures: [String] = []
        for f in parseFixtures {
            let bad = checkFixture(f)
            if !bad.isEmpty {
                let ctx = f.dirs.isEmpty ? "" : " dirs=\(f.dirs)"
                failures.append("\(f.name)\(ctx) -> \(bad.joined(separator: "; "))")
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    @Test("All classify fixtures match expected roles")
    func allClassifyFixtures() {
        var failures: [String] = []
        for (name, expected) in classifyFixtures {
            let got = parser.classify(name)
            if got != expected {
                failures.append("\(name): want \(expected), got \(got)")
            }
            #expect(classifyFile(name) == expected)
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    @Test("parseChineseInt handles numerals, positional digits, traditional forms, and rejects invalid inputs")
    func chineseIntConversion() {
        let valid: [(String, Int)] = [
            ("十", 10),
            ("十二", 12),
            ("二十", 20),
            ("二十三", 23),
            ("一百", 100),
            ("一百零五", 105),
            ("一百二十", 120),
            ("两", 2),
            ("兩", 2),
            ("兩百", 200),
            ("九", 9),
            ("二〇", 20),
            ("05", 5),
            ("一千零一", 1001),
            ("一千零八十", 1080),
        ]
        for (input, want) in valid {
            #expect(parseChineseInt(input) == want, Comment(rawValue: input))
        }
        for invalid in ["", "abc", "零十", "零百", "一百零十", "一二十", "二十三四", "十十"] {
            #expect(parseChineseInt(invalid) == nil, Comment(rawValue: invalid))
        }
    }

    @Test("classifyFile preserves English dot-titles (.in/.us/.me/.tv/.club/.top/.fun) while catching real ad URLs")
    func classifyDotTitleVsAdUrl() {
        for video in [
            "All.In.mkv",
            "About.Us.mkv",
            "Love.Me.mkv",
            "Apple.TV.mkv",
            "Fight.Club.mkv",
            "On.Top.mkv",
            "Have.Fun.mkv",
        ] {
            #expect(classifyFile(video) == .video, Comment(rawValue: video))
        }
        #expect(classifyFile("Stand.By.Me.srt") == .subtitle)
        for junk in [
            "www.example.com.mp4",
            "https://example.top.mp4",
            "dytt8.com.mp4",
            "最新地址.txt",
        ] {
            #expect(classifyFile(junk) == .junk, Comment(rawValue: junk))
        }
    }

    @Test("Confidence scores and anime absolute episode invariants")
    func confidenceAndAbsoluteInvariants() {
        let explicit = parser.parse("The.Show.S01E01.1080p.WEB-DL.x264-GRP.mkv")
        let guess = parser.parse("Title 05.mkv")
        #expect(explicit.confidence >= 0.9)
        #expect(guess.confidence < 0.5)

        let onePiece = parser.parse("[Nekomoe] 海贼王 - 1080 [1080p].mkv")
        #expect(onePiece.season == nil)
        #expect(onePiece.absolute == 1080)
        #expect(onePiece.kind == .episode)

        let range = parser.parse("Show.s01e01-e05.mkv")
        #expect(range.season == 1)
        #expect(range.episodes == [1, 2, 3, 4, 5])

        let upperX = parser.parse("Show.1X02.mkv")
        #expect(upperX.season == 1)
        #expect(upperX.episodes == [2])

        let trad = parser.parse("慶餘年 第兩季 第兩集.mkv")
        #expect(trad.season == 2)
        #expect(trad.episodes == [2])
    }

    @Test("Movie titles like The Menu / The Interview are not misclassified as extra")
    func menuAndInterviewTitleGuards() {
        let menu = parser.parse("The Menu (2022).mkv")
        #expect(menu.kind == .movie)
        #expect(menu.title == "The Menu")
        #expect(menu.year == 2022)

        let interview = parser.parse("The Interview (2014).mkv")
        #expect(interview.kind == .movie)
        #expect(interview.title == "The Interview")
        #expect(interview.year == 2014)
    }

    @Test("Calendar date validation and dated movie year fallback")
    func calendarDatesAndDatedMovie() {
        let invalid = parser.parse("Show.20240231.mkv")
        #expect(invalid.airDate == nil)

        let nonLeap = parser.parse("Show.20230229.mkv")
        #expect(nonLeap.airDate == nil)

        let leap = parser.parse("向往的生活.20240229.mp4")
        #expect(leap.airDate == utcDate(2024, 2, 29))

        let datedMovie = parser.parse("剧场版 柯南 2024-04-12.mkv")
        #expect(datedMovie.kind == .movie)
        #expect(datedMovie.year == 2024)
    }

    @Test("DTS-HD / DTS-X extraInfo, trailing -LANG subtitle, and Windows backslash paths")
    func dtsAndTrailingSubLangAndWindowsPaths() {
        let dtsHd = parser.parse("Movie.2020.1080p.BluRay.DTS.HD.MA.5.1.mkv")
        #expect(dtsHd.extraInfo == "1080p.DTS-HD")

        let dtsX = parser.parse("Movie.2020.2160p.BluRay.DTS.X.mkv")
        #expect(dtsX.extraInfo == "2160p.DTS-X")

        let subChs = parser.parse("Show.S01E01.1080p.WEB-DL-CHS.srt")
        #expect(subChs.lang == "CHS")
        #expect(subChs.group == nil)

        let subEng = parser.parse("Movie.2020.1080p.BluRay-ENG.ass")
        #expect(subEng.lang == "ENG")
        #expect(subEng.group == nil)

        let winPath = parser.parse(#"C:\Movies\Inception.2010.1080p.mkv"#)
        #expect(winPath.title == "Inception")
        #expect(winPath.year == 2010)
        #expect(winPath.kind == .movie)
    }

    @Test("External ID extraction, priority, and folder inheritance")
    func externalIdExtraction() {
        let cases: [(String, String, ExternalId)] = [
            ("Inception (2010) {tmdb-27205}.mkv", "Inception", ExternalId("tmdb", "27205")),
            ("Inception (2010) [tmdb-27205].mkv", "Inception", ExternalId("tmdb", "27205")),
            ("Inception (2010) [tmdbid=27205].mkv", "Inception", ExternalId("tmdb", "27205")),
            ("Inception (2010) {tmdbid=27205}.mkv", "Inception", ExternalId("tmdb", "27205")),
            ("Inception (2010) (tmdb-27205).mkv", "Inception", ExternalId("tmdb", "27205")),
            ("Inception (2010) {imdb-tt1375666}.mkv", "Inception", ExternalId("imdb", "tt1375666")),
            ("Inception (2010) [imdb-tt1375666].mkv", "Inception", ExternalId("imdb", "tt1375666")),
            ("Inception (2010) [imdbid=tt1375666].mkv", "Inception", ExternalId("imdb", "tt1375666")),
            ("Inception (2010) (tt1375666).mkv", "Inception", ExternalId("imdb", "tt1375666")),
            ("Inception.2010.tt1375666.1080p.mkv", "Inception", ExternalId("imdb", "tt1375666")),
            ("Breaking.Bad.{tvdb-81189}.S01E01.mkv", "Breaking Bad", ExternalId("tvdb", "81189")),
            ("Breaking Bad [tvdb-81189] S01E01.mkv", "Breaking Bad", ExternalId("tvdb", "81189")),
            ("[tvdbid=81189] Breaking Bad S01E01.mkv", "Breaking Bad", ExternalId("tvdb", "81189")),
            ("老友记 [tmdbid=1668] S01E01.mkv", "老友记", ExternalId("tmdb", "1668")),
        ]
        for (name, wantTitle, wantId) in cases {
            let r = parser.parse(name)
            #expect(r.title == wantTitle, Comment(rawValue: name))
            #expect(r.externalId == wantId, Comment(rawValue: name))
            #expect(r.group == nil, Comment(rawValue: name))
        }

        let fromDir = parser.parse("S01E01.mkv", parentDirs: ["Season 1", "Breaking Bad {tvdb-81189}"])
        #expect(fromDir.title == "Breaking Bad")
        #expect(fromDir.season == 1)
        #expect(fromDir.episodes == [1])
        #expect(fromDir.externalId == ExternalId("tvdb", "81189"))

        let fileWins = parser.parse("Inception (2010) {tmdb-27205}.mkv", parentDirs: ["Inception {imdb-tt1375666}"])
        #expect(fileWins.externalId == ExternalId("tmdb", "27205"))

        let multiInName = parser.parse("Inception (2010) {imdb-tt1375666} {tmdb-27205}.mkv")
        #expect(multiInName.title == "Inception")
        #expect(multiInName.externalId == ExternalId("tmdb", "27205"))

        let normalWord = parser.parse("Battlestar.Galactica.2004.mkv")
        #expect(normalWord.title == "Battlestar Galactica")
        #expect(normalWord.externalId == nil)

        let shortTt = parser.parse("Movie.2020.tt12345.mkv")
        #expect(shortTt.externalId == nil)
    }

    @Test("Release edition tags and title protection")
    func releaseEditions() {
        let cases: [(String, String, String)] = [
            ("Alien.1979.Director's.Cut.1080p.mkv", "Alien", "Director's Cut"),
            ("Alien.1979.Directors.Cut.1080p.mkv", "Alien", "Director's Cut"),
            ("Alien.1979.DC.1080p.BluRay.mkv", "Alien", "Director's Cut"),
            ("异形.1979.导演剪辑版.1080p.mkv", "异形", "Director's Cut"),
            ("Lord.of.the.Rings.2001.Extended.Edition.2160p.mkv", "Lord of the Rings", "Extended"),
            ("Fast.Five.2011.EXTENDED.1080p.BluRay.mkv", "Fast Five", "Extended"),
            ("指环王.2001.加长版.1080p.mkv", "指环王", "Extended"),
            ("Deadpool.2016.Unrated.1080p.mkv", "Deadpool", "Unrated"),
            ("死侍.2016.未分级版.1080p.mkv", "死侍", "Unrated"),
            ("Lord.of.the.Rings.2001.Theatrical.Cut.1080p.mkv", "Lord of the Rings", "Theatrical"),
            ("指环王.2001.剧场版.1080p.mkv", "指环王", "Theatrical"),
            ("Interstellar.2014.IMAX.Enhanced.2160p.mkv", "Interstellar", "IMAX"),
            ("Avatar.2009.3D.1080p.mkv", "Avatar", "3D"),
            ("Avatar.2009.HSBS.1080p.mkv", "Avatar", "3D"),
            ("Avatar.2009.1080p.Half-SBS.mkv", "Avatar", "3D"),
            ("Avatar.2009.1080p.Half-OU.mkv", "Avatar", "3D"),
            ("Oppenheimer.2023.2160p.UHD.BluRay.REMUX.HDR.HEVC.Atmos-GRP.mkv", "Oppenheimer", "Remux"),
            ("In.the.Mood.for.Love.2000.Criterion.Collection.1080p.mkv", "In the Mood for Love", "Criterion"),
            ("Blade.Runner.1982.Final.Cut.2160p.mkv", "Blade Runner", "Final Cut"),
            ("让子弹飞.2010.BD1080P.国粤双语.中字.mkv", "让子弹飞", "国粤双语"),
            ("千与千寻.2001.1080p.国语版.mkv", "千与千寻", "国语"),
            ("千与千寻.2001.1080p.国配.mkv", "千与千寻", "国语"),
            ("无间道.2002.1080p.粤语版.mkv", "无间道", "粤语"),
            ("无间道.2002.1080p.粤配.mkv", "无间道", "粤语"),
        ]
        for (name, wantTitle, wantEd) in cases {
            let r = parser.parse(name)
            #expect(r.title == wantTitle, Comment(rawValue: name))
            #expect(r.edition == wantEd, Comment(rawValue: name))
        }

        let dcComics = parser.parse("DC.Comics.2020.1080p.mkv")
        #expect(dcComics.title == "DC Comics")
        #expect(dcComics.edition == nil)

        let dcPets = parser.parse("DC.League.of.Super-Pets.2022.1080p.mkv")
        #expect(dcPets.title == "DC League of Super-Pets")
        #expect(dcPets.edition == nil)

        let theFinalCut = parser.parse("The.Final.Cut.2004.1080p.mkv")
        #expect(theFinalCut.title == "The Final Cut")
        #expect(theFinalCut.year == 2004)
        #expect(theFinalCut.edition == nil)

        let stepUp = parser.parse("Step.Up.3D.2010.1080p.mkv")
        #expect(stepUp.title == "Step Up 3D")
        #expect(stepUp.year == 2010)
        #expect(stepUp.edition == nil)

        let halfSbsNoGroup = parser.parse("Avatar.2009.1080p.Half-SBS.mkv")
        #expect(halfSbsNoGroup.group == nil)
        #expect(halfSbsNoGroup.edition == "3D")

        let animeMovie = parser.parse("海贼王 剧场版 红发歌姬 2022.mkv")
        #expect(animeMovie.title == "海贼王 红发歌姬")
        #expect(animeMovie.kind == .movie)
        #expect(animeMovie.edition == nil)

        let cutRemux = parser.parse("Alien.1979.Directors.Cut.1080p.BluRay.REMUX.mkv")
        #expect(cutRemux.edition == "Director's Cut")
    }

    @Test("Multi-part movie tags and title guards")
    func multiPartMovies() {
        let cases: [(String, String, Int, String)] = [
            ("Titanic.1997.CD1.1080p.mkv", "Titanic", 1, "cd1"),
            ("Titanic.1997.CD2.1080p.mkv", "Titanic", 2, "cd2"),
            ("Titanic.1997.Part.1.1080p.mkv", "Titanic", 1, "pt1"),
            ("Titanic.1997.Part 2.1080p.mkv", "Titanic", 2, "pt2"),
            ("Titanic.1997.Pt1.mkv", "Titanic", 1, "pt1"),
            ("Titanic.1997.Pt.2.mkv", "Titanic", 2, "pt2"),
            ("Lord.of.the.Rings.2001.Disc.1.BluRay.mkv", "Lord of the Rings", 1, "disc1"),
            ("Lord.of.the.Rings.2001.Disk.2.BluRay.mkv", "Lord of the Rings", 2, "disc2"),
            ("赤壁.2008.上集.1080p.mkv", "赤壁", 1, "pt1"),
            ("赤壁.2008.中集.1080p.mkv", "赤壁", 2, "pt2"),
            ("赤壁.2008.下集.1080p.mkv", "赤壁", 3, "pt3"),
            ("赤壁(上).2008.1080p.mkv", "赤壁", 1, "pt1"),
            ("赤壁(下).2008.1080p.mkv", "赤壁", 3, "pt3"),
            ("赤壁.2008.上.1080p.mkv", "赤壁", 1, "pt1"),
            ("赤壁.2008.下.1080p.mkv", "赤壁", 3, "pt3"),
            ("赤壁.中.mkv", "赤壁", 2, "pt2"),
        ]
        for (name, wantTitle, wantPart, wantLabel) in cases {
            let r = parser.parse(name)
            #expect(r.title == wantTitle, Comment(rawValue: name))
            #expect(r.part == wantPart, Comment(rawValue: name))
            #expect(r.partLabel == wantLabel, Comment(rawValue: name))
            #expect(r.kind == .movie, Comment(rawValue: name))
        }

        let hp = parser.parse("Harry.Potter.and.the.Deathly.Hallows.Part.2.2011.mkv")
        #expect(hp.title == "Harry Potter and the Deathly Hallows Part 2")
        #expect(hp.part == nil)

        #expect(parser.parse("华灯初上.2021.1080p.mkv").part == nil)
        #expect(parser.parse("海上钢琴师.1998.1080p.mkv").part == nil)
    }

    @Test("Chinese variety specials/extras/parts and anime .5 recap episodes")
    func varietyAndAnimeRecapSpecials() {
        let pilot = parser.parse("向往的生活 第7季 先导片.mp4")
        #expect(pilot.title == "向往的生活")
        #expect(pilot.kind == .special)
        #expect(pilot.season == 0)

        for extraName in [
            "向往的生活 第3期 加更版.mp4",
            "乘风破浪的姐姐.纯享版.1080p.mp4",
            "奔跑吧 衍生版 01.mp4",
            "奔跑吧.2024.未播花絮.mp4",
        ] {
            let r = parser.parse(extraName)
            #expect(r.kind == .extra, Comment(rawValue: extraName))
        }

        let partUp = parser.parse("向往的生活 第3期上.mp4")
        #expect(partUp.title == "向往的生活")
        #expect(partUp.episodes == [3])
        #expect(partUp.part == 1)
        #expect(partUp.partLabel == "pt1")

        let partParen = parser.parse("向往的生活 第10期(下).1080p.mp4")
        #expect(partParen.title == "向往的生活")
        #expect(partParen.episodes == [10])
        #expect(partParen.part == 3)
        #expect(partParen.partLabel == "pt3")

        let notPart = parser.parse("向往的生活 第3期 上山采蘑菇.mp4")
        #expect(notPart.episodes == [3])
        #expect(notPart.part == nil)

        let dashHalf = parser.parse("[Group] 鬼灭之刃 - 12.5 [1080p].mkv")
        #expect(dashHalf.title == "鬼灭之刃")
        #expect(dashHalf.kind == .special)
        #expect(dashHalf.season == 0)
        #expect(dashHalf.absolute == 12)

        let seHalf = parser.parse("Show.S01E12.5.1080p.mkv")
        #expect(seHalf.kind == .special)
        #expect(seHalf.season == 0)
        #expect(seHalf.episodes == [12])

        let cnHalf = parser.parse("鬼灭之刃 第12.5话.mkv")
        #expect(cnHalf.kind == .special)
        #expect(cnHalf.season == 0)
        #expect(cnHalf.episodes == [12])

        let bareHalf = parser.parse("12.5.mkv", parentDirs: ["鬼灭之刃"])
        #expect(bareHalf.title == "鬼灭之刃")
        #expect(bareHalf.kind == .special)
        #expect(bareHalf.season == 0)
        #expect(bareHalf.absolute == 12)
    }

    @Test("Subtitle flags, hardening guards, linear-time bracket check, and bilingual sequels")
    func subtitleFlagsAndHardening() {
        #expect(parser.parse("Show.S01E01.chs&eng.forced.srt").subFlags == ["bilingual", "forced"])
        #expect(parser.parse("Show.S01E01.en.sdh.default.ass").subFlags == ["sdh", "default"])
        #expect(parser.parse("Show.S01E01.中英双语.默认.vtt").subFlags == ["bilingual", "default"])
        #expect(parser.parse("[Group] Title - 05.jpsc.ass").subFlags == ["bilingual"])
        #expect(parser.parse("The.Force.Awakens.2015.chs.srt").title == "The Force Awakens")
        #expect(parser.parse("The.Force.Awakens.2015.chs.srt").subFlags.isEmpty)
        #expect(parser.parse("Show.S01E01.chs.eng.forced.mkv").subFlags.isEmpty)

        let zhTw = parser.parse("Show.S01E01.zh_TW.forced.srt")
        #expect(zhTw.lang == "zh_TW")
        #expect(zhTw.subFlags == ["forced"])

        let englishPatient = parser.parse("The.English.Patient.1996.chs.srt")
        #expect(englishPatient.title == "The English Patient")
        #expect(englishPatient.lang == "chs")

        let englishPatientNoYear = parser.parse("The.English.Patient.chs.srt")
        #expect(englishPatientNoYear.title == "The English Patient")
        #expect(englishPatientNoYear.lang == "chs")

        // Linear-time ReDoS check
        let start = ContinuousClock.now
        let payload = "[\(String(repeating: "1080p", count: 200))!] Show.S01E01.mkv"
        let redos = parser.parse(payload)
        let elapsed = ContinuousClock.now - start
        #expect(redos.title == "Show")
        #expect(redos.season == 1)
        #expect(redos.episodes == [1])
        #expect(elapsed < .milliseconds(500))

        // Dash episode skipping year token
        let dashYear = parser.parse("[Group] Show - 2024 - 05 [1080p].mkv")
        #expect(dashYear.title == "Show")
        #expect(dashYear.year == 2024)
        #expect(dashYear.absolute == 5)

        // Nested leading brackets & paren edition
        let nested = parser.parse("[Group (CHS)] Title - 01 [1080p].mkv")
        #expect(nested.group == "Group (CHS)")
        #expect(nested.title == "Title")
        #expect(nested.absolute == 1)

        let parenEd = parser.parse("(Director's Cut) Alien 1979.mkv")
        #expect(parenEd.title == "Alien")
        #expect(parenEd.edition == "Director's Cut")

        // Special / Movie title guards
        let lioness = parser.parse("Special.Ops.Lioness.S01E01.1080p.mkv")
        #expect(lioness.title == "Special Ops Lioness")
        #expect(lioness.kind == .episode)
        #expect(lioness.season == 1)

        let epSpecialTitle = parser.parse("Show.S01E05.The.Special.Guest.1080p.mkv")
        #expect(epSpecialTitle.title == "Show")
        #expect(epSpecialTitle.kind == .episode)

        let specialsMovie = parser.parse("The.Specials.2000.1080p.mkv")
        #expect(specialsMovie.title == "The Specials")
        #expect(specialsMovie.kind == .movie)

        let forcesMovie = parser.parse("Special.Forces.2011.1080p.mkv")
        #expect(forcesMovie.title == "Special Forces")
        #expect(forcesMovie.kind == .movie)

        // Folder OVA /花絮 propagation and Season barrier
        let ovaDir = parser.parse("01.mkv", parentDirs: ["Show OVA"])
        #expect(ovaDir.title == "Show")
        #expect(ovaDir.kind == .special)
        #expect(ovaDir.season == 0)
        #expect(ovaDir.episodes == [1])

        let seasonChild = parser.parse("01.mkv", parentDirs: ["Season 1", "Show OVA"])
        #expect(seasonChild.title == "Show")
        #expect(seasonChild.kind == .episode)
        #expect(seasonChild.season == 1)

        // Invalid Chinese season numeral
        let badCnSeason = parser.parse("某剧 第十十季.mkv")
        #expect(badCnSeason.season == nil)
        #expect(badCnSeason.kind != .special)

        // Bilingual CJK + pure-digit sequel
        #expect(parser.parse("流浪地球.2.The.Wandering.Earth.II.2023.2160p.mkv").title == "流浪地球 2")
        #expect(parser.parse("战狼.2.Wolf.Warrior.2.2017.1080p.mkv").title == "战狼 2")
        #expect(parser.parse("The.Wandering.Earth.II.流浪地球.2.2023.2160p.mkv").title == "流浪地球 2")
        #expect(parser.parse("破产姐妹.2 Broke Girls.S01E01.mkv").title == "破产姐妹")
    }

    @Test("looksOrganized accurately detects default, Filmix, custom profile, no-year, and disc layouts")
    func looksOrganizedLayouts() {
        func checkFilePath(_ path: String, naming: NamingProfile = .vidhub) -> Bool {
            let segs = path.split(separator: "/").map(String.init)
            let leaf = segs.last!
            let parents = Array(segs.dropLast().reversed())
            let byParts = looksOrganized(fileName: leaf, parentDirs: parents, naming: naming)
            let byEntry = looksOrganized(RemoteEntry(path: path, name: leaf, isDir: false, size: 1), naming: naming)
            #expect(byParts == byEntry, Comment(rawValue: "Mismatch for \(path)"))
            return byParts
        }

        func checkDirEntry(_ path: String, naming: NamingProfile = .vidhub) -> Bool {
            let leaf = String(path.split(separator: "/").last ?? "")
            return looksOrganized(RemoteEntry(path: path, name: leaf, isDir: true, size: 0), naming: naming)
        }

        for p in [
            "/日漫/未来日记 (2011)/Season 01/未来日记 - S01E02.mkv",
            "/日漫/未来日记 (2011) {tmdb-1}/Season 1/未来日记 S01E02 1080p.mkv",
            "/日漫/未来日记 (2011)/Specials/未来日记 - S00E01.mkv",
            "/电影/Inception (2010) {tmdb-27205}/Inception (2010).mkv",
            "/电影/盗梦空间 (2010)/盗梦空间 (2010) - 2160p.mkv",
            "/电影/盗梦空间 (2010)/盗梦空间.Inception.2010.mkv",
            "/日漫/死神 (2004)/Season 2/死神 - S02E03.mkv",
            "/日漫/未来日记 (2011)/未来日记 - S01E02.mkv",
        ] {
            #expect(checkFilePath(p) == true, Comment(rawValue: p))
        }

        for p in [
            "/下载/The.Bear.S03E02.2160p.mkv",
            "/下载/Dune.Part.Two.2024.2160p.mkv",
            "/下载/[Nekomoe] Dandadan/[Nekomoe] Dandadan - 01.mkv",
            "/电影/盗梦空间 (2010)/movie.mkv",
            "/合集2020/ep1.mkv",
            "/日漫/未来日记 (2011)/Season 02/未来日记 - S01E02.mkv",
            "/日漫/未来日记/Season 01/未来日记 - S01E02.mkv",
            "/日漫/未来日记 (2011)/Season 01/[Sub] 未来日记 - 02.mkv",
            "/剧/The.Bear.2022/Season 1/the.bear.s01e02.mkv",
            "/剧/老友记（1994）/老友记 1x02.mkv",
            "/电影/盗梦空间 (2010)/Inception.mkv",
        ] {
            #expect(checkFilePath(p) == false, Comment(rawValue: p))
        }

        // Folders
        #expect(checkDirEntry("/剧/三体 (2023)") == true)
        #expect(checkDirEntry("/剧/三体 (2023)/Season 01") == true)
        #expect(looksOrganized(fileName: "Season 01", parentDirs: ["三体 (2023)", "剧"]) == true)
        #expect(checkDirEntry("/剧/The.Bear.2022") == false)
        #expect(checkDirEntry("/下载/Season 01") == false)
        #expect(checkDirEntry("/下载/The.Bear.S03.2160p") == false)
        #expect(checkDirEntry("/下载") == false)

        // Custom seasonFolderTemplate
        let s01Profile = NamingProfile(tv: NamingOptions(seasonFolderTemplate: "S{season:02}"))
        #expect(checkFilePath("/剧/三体 (2023)/S01/三体 - S01E02.mkv", naming: s01Profile) == true)
        #expect(checkFilePath("/剧/三体 (2023)/S02/三体 - S01E02.mkv", naming: s01Profile) == false)
        #expect(checkDirEntry("/剧/三体 (2023)/S01", naming: s01Profile) == true)
        #expect(checkDirEntry("/下载/S01", naming: s01Profile) == false)
        #expect(checkFilePath("/剧/三体 (2023)/Season 01/三体 - S01E02.mkv", naming: s01Profile) == true)
        #expect(checkFilePath("/剧/三体 (2023)/Specials/三体 - S00E01.mkv", naming: s01Profile) == true)

        let cnSeasonProfile = NamingProfile(tv: NamingOptions(seasonFolderTemplate: "第 {season} 季"))
        #expect(checkFilePath("/剧/三体 (2023)/第 1 季/三体 - S01E02.mkv", naming: cnSeasonProfile) == true)
        #expect(checkFilePath("/剧/三体 (2023)/第 2 季/三体 - S01E02.mkv", naming: cnSeasonProfile) == false)
        #expect(checkDirEntry("/剧/三体 (2023)/第 1 季", naming: cnSeasonProfile) == true)

        // Custom episodeStyle
        let crossProfile = NamingProfile(tv: NamingOptions(episodeStyle: .cross))
        #expect(checkFilePath("/剧/老友记 (1994)/Season 01/老友记.1994.1x02.mkv", naming: crossProfile) == true)
        #expect(checkFilePath("/剧/老友记 (1994)/Season 02/老友记.1994.1x02.mkv", naming: crossProfile) == false)
        #expect(checkFilePath("/剧/老友记 (1994)/老友记.1x02.mkv", naming: crossProfile) == true)

        let shortProfile = NamingProfile(tv: NamingOptions(episodeStyle: .lowerShort))
        #expect(checkFilePath("/剧/老友记 (1994)/Season 01/老友记.s1e2.mkv", naming: shortProfile) == true)

        let dottedProfile = NamingProfile(tv: NamingOptions(episodeStyle: .lowerDotted))
        #expect(checkFilePath("/剧/老友记 (1994)/Season 01/老友记.s01.e02.mkv", naming: dottedProfile) == true)

        // No-year folderTemplate and includeYear == false
        let noYearTemplate = NamingProfile(
            movie: NamingOptions(folderTemplate: "{title}"),
            tv: NamingOptions(folderTemplate: "{title}")
        )
        #expect(checkFilePath("/日漫/未来日记/Season 01/未来日记 - S01E02.mkv", naming: noYearTemplate) == true)
        #expect(checkFilePath("/电影/盗梦空间/盗梦空间.mkv", naming: noYearTemplate) == true)
        #expect(checkDirEntry("/日漫/未来日记", naming: noYearTemplate) == true)
        #expect(checkFilePath("/下载/The.Bear.S03E02.2160p.mkv", naming: noYearTemplate) == false)
        #expect(checkFilePath("/电影/盗梦空间/movie.mkv", naming: noYearTemplate) == false)
        #expect(checkDirEntry("/下载", naming: noYearTemplate) == false)

        let includeYearFalse = NamingProfile(
            movie: NamingOptions(includeYear: false),
            tv: NamingOptions(includeYear: false)
        )
        #expect(checkFilePath("/电影/盗梦空间 (2010)/盗梦空间.mkv", naming: includeYearFalse) == true)
        #expect(checkFilePath("/电影/盗梦空间/盗梦空间.mkv", naming: includeYearFalse) == true)

        // tmdbIdTag folders & BDMV / VIDEO_TS disc folders
        let tmdbProfile = NamingProfile(
            movie: NamingOptions(tmdbIdTag: true, folderTemplate: "{title} ({year}) {tmdb_tag}")
        )
        #expect(checkFilePath("/电影/盗梦空间 (2010) {tmdb-27205}/盗梦空间 (2010) {tmdb-27205}.mkv", naming: tmdbProfile) == true)
        #expect(checkDirEntry("/电影/盗梦空间 (2010)/BDMV", naming: tmdbProfile) == true)
        #expect(looksOrganized(fileName: "BDMV", parentDirs: ["盗梦空间 (2010)", "电影"], naming: tmdbProfile) == true)
        #expect(checkFilePath("/电影/盗梦空间 (2010)/BDMV/STREAM/00001.m2ts", naming: tmdbProfile) == true)
        #expect(checkFilePath("/电影/盗梦空间 (2010)/VIDEO_TS/VTS_01_1.VOB", naming: tmdbProfile) == true)
        #expect(checkFilePath("/下载/Inception.2010.BluRay.REMUX/BDMV/STREAM/00001.m2ts", naming: tmdbProfile) == false)
    }

    @Test("Directory analysis cache preserves deterministic results under repeated and concurrent parsing")
    func directoryAnalysisCacheConsistencyAndConcurrency() async {
        let dirSamples = [
            "三体 (2023) {tmdb-197067}",
            "Season 01",
            "Show OVA",
            "The.Bear.S03.2160p.WEB-DL",
            "Inception.2010.Director's.Cut.BluRay",
        ]
        let expected = dirSamples.map { dir in
            parser.parse("01.mkv", parentDirs: [dir])
        }

        // Repeated sequential hits match first-pass results exactly
        for (dir, want) in zip(dirSamples, expected) {
            #expect(parser.parse("01.mkv", parentDirs: [dir]) == want)
        }

        // Concurrent hits across tasks return identical results with zero races
        let localParser = parser
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<64 {
                let idx = i % dirSamples.count
                let dir = dirSamples[idx]
                let want = expected[idx]
                group.addTask {
                    localParser.parse("01.mkv", parentDirs: [dir]) == want
                }
            }
            for await matched in group {
                #expect(matched)
            }
        }
    }
}
