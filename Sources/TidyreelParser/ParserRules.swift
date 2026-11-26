import Foundation
import TidyreelModels

// MARK: - Pre-compiled Static Regular Expressions & Constants

private let knownExtensions: Set<String> = videoExtensions
    .union(subtitleExtensions)
    .union(sidecarExtensions)
    .union(junkExtensions)

private let cjkQuotes: Set<UInt32> = [
    0x300A, // 《
    0x300B, // 》
    0x300C, // 「
    0x300D, // 」
    0x300E, // 『
    0x300F, // 』
    0x3008, // 〈
    0x3009, // 〉
    0x201C, // “
    0x201D, // ”
]

private let nonGroupTrailerTags: Set<String> = [
    "3d", "dc", "sbs", "ou", "hsbs", "hou", "criterion", "theatrical",
]

private let premiumAudioSet: Set<String> = [
    "Atmos", "TrueHD", "DTS-HD", "DTS-X",
]

private let sequelWordMap: [String: Int] = [
    "i": 1, "ii": 2, "iii": 3, "iv": 4, "v": 5,
    "vi": 6, "vii": 7, "viii": 8, "ix": 9, "x": 10,
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
]

enum ParserRegexes {
    private static let bareTld = "com|net|org|cn|cc|xyz|vip|pw|site"
    private static let bareDomainPat =
        #"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.(?:"# + bareTld + #")(?:\.(?:cn|uk|jp|tw|hk))?(?![A-Za-z0-9])"#
    private static let schemeOrWwwPat =
        #"https?://\S+|www\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*(?![A-Za-z0-9])"#

    static let adKw = CompiledRegex(
        "更多资源|更多精彩|更多电影|最新地址|最新网址|获取更多|公众号|扫码|发布页|永久地址|永久网址|免费下载|点击进入|关注微信"
    )
    static let url = CompiledRegex("(?:\(schemeOrWwwPat)|\(bareDomainPat))", caseSensitive: false)
    static let www = CompiledRegex("(?:\(schemeOrWwwPat))", caseSensitive: false)
    static let leadDomain = CompiledRegex(#"^\s*"# + bareDomainPat + #"[\s._-]*"#, caseSensitive: false)
    static let anyBracket = CompiledRegex(#"\[[^\]]*\]|\([^)]*\)"#)
    static let letterOrDigit = CompiledRegex(#"[\p{L}\p{N}]"#)
    static let sample = CompiledRegex(#"^sample$|[-._ \[(]sample[\])]?$|^sample[-._ ]"#)
    static let ext = CompiledRegex(#"^[a-z0-9!]+$"#)
    static let scheme = CompiledRegex(#"https?://"#, caseSensitive: false)

    private static let cnNum = #"[0-9]+|[零〇一二三四五六七八九十百千两兩]+"#

    static let extIdBracketed = CompiledRegex(
        #"[\{\[\(]\s*(?:(tmdb|tvdb)(?:id)?\s*[-=:]\s*(\d+)|(imdb)(?:id)?\s*[-=:]\s*(tt\d{7,9})|(tt\d{7,9}))\s*[\}\]\)]"#,
        caseSensitive: false
    )
    static let extIdBare = CompiledRegex(
        #"(?<![A-Za-z0-9])(?:(tmdb|tvdb)(?:id)?\s*[-=:]\s*(\d+)|(imdb)(?:id)?\s*[-=:]\s*(tt\d{7,9})|(tt\d{7,9}))(?![A-Za-z0-9])"#,
        caseSensitive: false
    )

    static let date = CompiledRegex(
        #"(?<![0-9])(?:(?:19|20)\d\d[-._ ](?:0[1-9]|1[0-2])[-._ ](?:0[1-9]|[12]\d|3[01])|(?:19|20)\d\d(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01]))(?![0-9])"#
    )
    static let leadBracket = CompiledRegex(#"^\s*(?:\[([^\]]*)\]|\(([^)]*)\))"#)
    static let midBracket = CompiledRegex(#"\[([^\]]*)\]|\(([^)]*)\)"#)
    static let crc = CompiledRegex(#"^[0-9A-Fa-f]{8}$"#)

    private static let techWords =
        #"webdl|webrip|webhd|bluray|bdremux|bdrip|brrip|remux|hdtv|pdtv|dvdrip|dvdscr|dvd|hdrip|hdcam|bd|"# +
        #"amzn|nf|dsnp|hmax|atvp|hulu|x26[45]|h26[45]|hevc|avc|xvid|divx|av1|vc1|10bits?|8bits?|hi10p?|"# +
        #"(?:ddplus|ddp|dd|aac|ac3|eac3|dtshd|dtsx|dts|flac|truehd|atmos|opus|lpcm|mp3)\d*|ch\d\d|"# +
        #"hdr10plus|hdr10|hdr|dovi|dv|hlg|sdr|imax|halfsbs|hsbs|halfou|hou|proper|repack|rerip|extended|unrated|remastered|"# +
        #"internal|multi|dual|dubbed|subbed|complete|batch|limited|hybrid|mkv|mp4|avi"#

    static let tech = CompiledRegex(
        #"(?<![A-Za-z0-9])(?:"# + techWords + #"|\d{3,4}x\d{3,4}|[248]k|uhd|fhd)(?![A-Za-z0-9])|(?<![0-9])\d{3,4}[pi](?![A-Za-z0-9])"#,
        caseSensitive: false
    )
    static let techToken = CompiledRegex(
        #"webdl|webrip|webhd|web|"# +
        #"bluray|bdremux|bdrip|brrip|remux|bd|"# +
        #"hdtv|pdtv|dvdrip|dvdscr|dvd|hdrip|hdcam|"# +
        #"amzn|nf|dsnp|hmax|atvp|hulu|"# +
        #"x26[45]|h26[45]|hevc|avc|xvid|divx|av1|vc1|10bits?|8bits?|hi10p?|"# +
        #"(?:ddplus|ddp|dd|aac|ac3|eac3|dtshd|dtsx|dts|flac|truehd|atmos|opus|lpcm|mp3)"# +
        #"(?:(?!\d{3,4}(?:[pi]|x\d{3,4})|(?:10|8)bits?|[248]k)\d{1,2})?|ch\d\d|"# +
        #"hdr10plus|hdr10|hdr|dovi|dv|hlg|sdr|imax|halfsbs|hsbs|sbs|halfou|hou|"# +
        #"proper|repack|rerip|extended|unrated|remastered|"# +
        #"internal|multi|dual|dubbed|subbed|complete|batch|limited|hybrid|mkv|mp4|avi|"# +
        #"\d{3,4}x\d{3,4}|\d{3,4}[pi]|[248]k|uhd|fhd|tv|big5|gb|chs|cht|sc|tc|"# +
        #"dc|3d|criterion|theatrical|forced|sdh|bilingual|default|"# +
        #"v\d|\d{1,3}[-~]\d{1,3}|\d{4}|[\s,&+/_.-]+"#,
        caseSensitive: false
    )

    static let cnNoise = CompiledRegex(
        "国粤双语|國粵雙語|国语版|國語版|粤语版|粵語版|国配|國配|粤配|粵配|" +
        "加长版|加長版|未分级版|未分級版|导演剪辑版?|導演剪輯版?|导剪版|導剪版|" +
        "国语|粤语|国粤|中字|中英|简繁|简体|繁体|繁體|高清|超清|蓝光|原盘|完整版|无删减|全集|合集|内封|内嵌|外挂|双语|字幕|修复版|珍藏版|新版|首发|重制版"
    )

    static let seHalf = CompiledRegex(#"(?<![A-Za-z0-9])S(\d{1,2}) ?E(\d{1,4})\.5(?![0-9])"#, caseSensitive: false)
    static let cnEpHalf = CompiledRegex(#"第 ?(\d{1,4})\.5 ?[集话話期回]"#)
    static let epHalf = CompiledRegex(#"(?<![A-Za-z0-9])(?:(?:EP|Episode) ?|E)(\d{1,4})\.5(?![0-9])"#, caseSensitive: false)
    static let dashHalf = CompiledRegex(#"(?:^| )- ?(\d{1,4})\.5(?:v\d{1,2})?(?![A-Za-z0-9])"#)
    static let bareHalf = CompiledRegex(#"(?<![A-Za-z0-9])(\d{1,4})\.5(?:v\d)?(?![A-Za-z0-9])"#)

    static let se = CompiledRegex(
        #"(?<![A-Za-z0-9])S(\d{1,2}) ?E(\d{1,4})((?: ?- ?E?\d{1,4}| ?~ ?E?\d{1,4}| ?E\d{1,4})*)(?![A-Za-z0-9])"#,
        caseSensitive: false
    )
    static let xEp = CompiledRegex(#"(?<![A-Za-z0-9])(\d{1,2})x(\d{2,3})(?![A-Za-z0-9])"#, caseSensitive: false)
    static let cnEp = CompiledRegex(
        "第 ?(\(cnNum))(?: ?[-~] ?(\(cnNum)))? ?[集话話期回](?: ?([上中下])(?:集|部)?(?![\\u4e00-\\u9fff]))?"
    )
    static let batch = CompiledRegex(#"[全共] ?\d+ ?[集话期]|更新?至 ?\d+ ?[集话期]"#)
    static let ep = CompiledRegex(
        #"(?<![A-Za-z0-9])(?:(?:EP|Episode) ?|E)(\d{1,4})(?: ?[-~] ?(?:(?:EP|Episode) ?|E)?(\d{1,4}))?(?![A-Za-z0-9])"#,
        caseSensitive: false
    )
    static let ofEp = CompiledRegex(#"(?<![A-Za-z0-9])(\d{1,2}) ?of ?(\d{1,2})(?![A-Za-z0-9])"#, caseSensitive: false)
    static let hashEp = CompiledRegex(#"#(\d{1,4})(?![0-9])"#)
    static let vol = CompiledRegex(#"(?<![A-Za-z0-9])Vol(?:ume)? ?(\d{1,3})(?![A-Za-z0-9])"#, caseSensitive: false)
    static let dash = CompiledRegex(#"(?:^| )- ?(\d{1,4})(?:v\d{1,2})?(?![A-Za-z0-9])"#)

    static let seasonRes: [CompiledRegex] = [
        CompiledRegex(#"(?<![A-Za-z0-9])S(\d{1,2})(?![A-Za-z0-9])"#, caseSensitive: false),
        CompiledRegex(#"(?<![A-Za-z])(?:Season|Saison|Series) ?(\d{1,2})(?![0-9]| ?of)"#, caseSensitive: false),
        CompiledRegex(#"(\d{1,2})(?:st|nd|rd|th) Season"#, caseSensitive: false),
        CompiledRegex("第 ?(\(cnNum)) ?季"),
    ]

    static let special = CompiledRegex(
        #"(?<![A-Za-z0-9])(?:OVA|OAD|SPs?|Specials?) ?(\d{1,3})?(?![A-Za-z0-9])|(?:特别篇|特別篇|番外篇?|先导片|先導片) ?(\d{1,3})?"#,
        caseSensitive: false
    )
    static let strictSpecial = CompiledRegex(
        #"^(?:(?:OVA|OAD|SPs?)(?![A-Za-z])|特别篇|特別篇|番外篇?|先导片|先導片)"#,
        caseSensitive: false
    )
    static let extraCs = CompiledRegex(
        #"(?<![A-Za-z0-9])(?:PV|CM) ?\d{0,2}(?![A-Za-z0-9])|(?<![A-Za-z0-9])(?:OP|ED) ?\d{1,2}(?![A-Za-z0-9])|"# +
        #"未播花絮|未播片段|加更版|纯享版|純享版|衍生版|花絮|幕后|特典|预告片?|宣传片|访谈|片头曲|片尾曲|特辑|彩蛋"#
    )
    static let extraCi = CompiledRegex(
        #"(?<![A-Za-z0-9])(?:NCOP|NCED|Creditless ?(?:Opening|Ending)|Trailers?|Teaser|Menu|Making(?: of)?|Featurettes?|Interviews?|Behind The Scenes|Deleted Scenes?|Extras?|Bonus) ?\d{0,2}(?![A-Za-z0-9])"#,
        caseSensitive: false
    )
    static let strictExtra = CompiledRegex(
        #"^(?:NCOP|NCED|PV|CM|OP|ED|未播花絮|未播片段|加更版|纯享版|純享版|衍生版|花絮|幕后|特典|预告|宣传片|访谈|片头曲|片尾曲|特辑|彩蛋)"#
    )

    static let theTitlePrefix = CompiledRegex(#"^\s*the\s+$"#, caseSensitive: false)
    static let cjkMovie = CompiledRegex(#"剧场版|劇場版|电影版|Gekijouban"#, caseSensitive: false)
    static let theMovie = CompiledRegex(#"(?<![A-Za-z])The Movie(?![A-Za-z])"#, caseSensitive: false)
    static let afterTheatricalTitle = CompiledRegex(#"[\u3400-\u9fff]{2,}|[A-Za-z]{3,}"#)

    // Release editions
    static let edDirectorsCut = CompiledRegex(
        #"(?<![A-Za-z0-9])Director'?s? Cut(?![A-Za-z0-9])|导演剪辑版?|導演剪輯版?|导剪版|導剪版"#,
        caseSensitive: false
    )
    static let edDcTag = CompiledRegex(#"(?<![A-Za-z0-9])DC(?![A-Za-z0-9])"#)
    static let edFinalCut = CompiledRegex(#"(?<![A-Za-z0-9])(?:The )?Final Cut(?![A-Za-z0-9])"#, caseSensitive: false)
    static let edExtended = CompiledRegex(
        #"(?<![A-Za-z0-9])Extended(?: (?:Edition|Cut|Version))?(?![A-Za-z0-9])|加长版|加長版"#,
        caseSensitive: false
    )
    static let edUnrated = CompiledRegex(
        #"(?<![A-Za-z0-9])Unrated(?: (?:Edition|Cut|Version))?(?![A-Za-z0-9])|未分级版|未分級版"#,
        caseSensitive: false
    )
    static let edTheatrical = CompiledRegex(
        #"(?<![A-Za-z0-9])Theatrical(?: (?:Edition|Cut|Version))?(?![A-Za-z0-9])"#,
        caseSensitive: false
    )
    static let edCriterion = CompiledRegex(
        #"(?<![A-Za-z0-9])Criterion(?: Collection)?(?![A-Za-z0-9])"#,
        caseSensitive: false
    )
    static let edImax = CompiledRegex(#"(?<![A-Za-z0-9])IMAX(?: Enhanced)?(?![A-Za-z0-9])"#, caseSensitive: false)
    static let ed3dExplicit = CompiledRegex(
        #"(?<![A-Za-z0-9])(?:H-?SBS|Half[- ]?SBS|HalfSBS|H-?OU|Half[- ]?OU|HalfOU)(?![A-Za-z0-9])"#,
        caseSensitive: false
    )
    static let ed3d = CompiledRegex(#"(?<![A-Za-z0-9])3D(?![A-Za-z0-9])"#, caseSensitive: false)
    static let edRemux = CompiledRegex(#"(?<![A-Za-z0-9])(?:BD)?REMUX(?![A-Za-z0-9])"#, caseSensitive: false)
    static let edCnDualDub = CompiledRegex(#"国粤双语|國粵雙語"#)
    static let edCnMandarin = CompiledRegex(#"国语版|國語版|国配|國配"#)
    static let edCnCantonese = CompiledRegex(#"粤语版|粵語版|粤配|粵配"#)

    // Multi-part movie / split tags
    static let partCd = CompiledRegex(#"(?<![A-Za-z0-9])CD ?([1-9])(?![A-Za-z0-9])"#, caseSensitive: false)
    static let partDisc = CompiledRegex(#"(?<![A-Za-z0-9])(?:Disc|Disk) ?([1-9])(?![A-Za-z0-9])"#, caseSensitive: false)
    static let partPt = CompiledRegex(#"(?<![A-Za-z0-9])Pt ?([1-9])(?![A-Za-z0-9])"#, caseSensitive: false)
    static let partWord = CompiledRegex(#"(?<![A-Za-z0-9])Part ?([1-9])(?![A-Za-z0-9])"#, caseSensitive: false)
    static let partCnJi = CompiledRegex(#"(?<=.)([上中下])集(?![\u4e00-\u9fff])"#)
    static let partCnBracketed = CompiledRegex(#"\u0001 ([上中下])(?:集|部)?(?=[\s\u0001]|$)"#)
    static let partCnLoose = CompiledRegex(
        #"(?<=[\s\u0001])([上中下])(?:\s*$|(?=\s*(?:\u0001|(?:19|20)\d\d|\d{3,4}[pi]|[248]k|BD|WEB|HD|UHD|BluRay|Remux|国|粤|中|简|繁|双语|字幕|高清|超清|蓝光|原盘)))"#,
        caseSensitive: false
    )

    static let year = CompiledRegex(#"(?<![A-Za-z0-9\u3400-\u9fff])((?:19|20)\d\d)(?![A-Za-z0-9])"#)
    static let cjk = CompiledRegex(#"[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]"#)
    static let lang = CompiledRegex(
        #"(?<![A-Za-z0-9])(zh[-_ ]?(?:cn|tw|hans|hant|hk|sg)|en[-_ ]?(?:us|gb)|chs|cht|zhs|zht|chi|zho|jpsc|jptc|sc|tc|gbk|gb2312|gb|big5|english|eng|en|japanese|jpn|jap|jp|ja|korean|kor|ko|zh|cn|chinese|"# +
        #"简体中文|繁體中文|繁体中文|简体|繁体|繁體|简中|繁中|简日|繁日|简繁|简英|繁英|中英|中文|双语|雙語|日语|日文|韩语|韩文|英文|英语)(?![A-Za-z0-9])"#,
        caseSensitive: false
    )
    static let subFlagTrailer = CompiledRegex(
        #"^(?:forced|force|default|sdh|hi|cc|bilingual|强制|強制|默认|默認|听障|聽障)$"#,
        caseSensitive: false
    )
    static let trailingSubFlag = CompiledRegex(
        #"(?:^|[\s\u0001])(forced|default|sdh|bilingual|强制|強制|默认|默認|听障|聽障)(?=(?:[\s\u0001]+(?:forced|force|default|sdh|hi|cc|bilingual|强制|強制|默认|默認|听障|聽障))*\s*$)"#,
        caseSensitive: false
    )

    static let fourDigitYear = CompiledRegex(#"^(?:19|20)\d\d$"#)
    static let loneFourDigit = CompiledRegex(#"^(\d{4})$"#)
    static let cnNoiseTag = CompiledRegex(#"[\u4e00-\u9fff]{0,2}(?:字幕|画质|版|语|字)(?![\u4e00-\u9fff])"#)
    static let splitNoise = CompiledRegex(#"[\s,&+/_.-]+"#)

    static let webdl = CompiledRegex(#"web[-. _]?dl"#, caseSensitive: false)
    static let bluray = CompiledRegex(#"blu[-. ]?ray"#, caseSensitive: false)
    static let half3d = CompiledRegex(#"(?<![A-Za-z0-9])(half|h)[-. _]?(sbs|ou)(?![A-Za-z0-9])"#, caseSensitive: false)
    static let h26x = CompiledRegex(#"(?<![A-Za-z0-9])h[. ]?26([45])(?![0-9])"#, caseSensitive: false)
    static let hdr10Plus = CompiledRegex(#"(hdr10|ddp?|eac3)\+"#, caseSensitive: false)
    static let audioCh = CompiledRegex(
        #"(?<![A-Za-z0-9])(dd|ddp|ddplus|aac|ac3|eac3|dts|flac|truehd|atmos|opus|lpcm)[ .]?(\d)\.(\d)"#,
        caseSensitive: false
    )
    static let chDigit = CompiledRegex(#"(?<![0-9.])([2567])\.([01])(?![0-9])"#)
    static let localeUnderscore = CompiledRegex(
        #"(?<![A-Za-z0-9])(zh)_(cn|tw|hk|sg|hans|hant)(?![A-Za-z0-9])|(?<![A-Za-z0-9])(en)_(us|gb)(?![A-Za-z0-9])"#,
        caseSensitive: false
    )
    static let halfDot = CompiledRegex(
        #"(?<![A-Za-z0-9])((?:S\d{1,2} ?E|EP?|Episode[ .]?|第 ?)?)(?!19\d\d|20\d\d)(\d{1,4})\.5(?![0-9])"#,
        caseSensitive: false
    )
    static let dotsUnderscores = CompiledRegex(#"[._]"#)
    static let whitespace = CompiledRegex(#"[ \t]+"#)

    static let dashDate = CompiledRegex(#"[-._ ]"#)
    static let numWithV = CompiledRegex(#"^\d{1,4}(?:\.5)?(?:v\d)?$"#)
    static let trailerGroup = CompiledRegex(#"-([A-Za-z0-9]{2,16}) *(?:\[[^\]]*\] *)*$"#)
    static let eNum = CompiledRegex(#"^E?\d+$"#, caseSensitive: false)
    static let multiSpace = CompiledRegex(#" {2,}"#)
    static let multiEp = CompiledRegex(#"( ?[-~] ?)?E?(\d+)"#, caseSensitive: false)
    static let leadLower = CompiledRegex(#"^ [a-z]"#)
    static let bareRegion = CompiledRegex(#"(?<![A-Za-z0-9])(\d{1,3})(?:v\d)?(?![A-Za-z0-9])"#)
    static let spaceDash = CompiledRegex(#"[\s-]"#)
    static let resPi = CompiledRegex(#"(?<![0-9])(\d{3,4})[pi](?![A-Za-z0-9])"#, caseSensitive: false)
    static let resX = CompiledRegex(#"(?<![A-Za-z0-9])\d{3,4}x(\d{3,4})(?![A-Za-z0-9])"#)
    static let resK = CompiledRegex(#"(?<![A-Za-z0-9])([248])k(?![A-Za-z0-9])"#, caseSensitive: false)
    static let hdrAudio = CompiledRegex(
        #"(?<![A-Za-z0-9])(hdr10plus|hdr10|hdr|dovi|dv|hlg|imax|atmos|truehd|dts[- ]?hd|dts[- ]?x)\d*(?![A-Za-z0-9])"#,
        caseSensitive: false
    )

    static let stripBrackets = CompiledRegex(#"[\[\]()]"#)
    static let anyWhitespace = CompiledRegex(#"\s+"#)
    static let edgePunct = CompiledRegex(#"^[\s\-_.~,;:|/&+@]+|[\s\-_.~,;:|/&+@]+$"#)
    static let latinThreeWord = CompiledRegex(#"[A-Za-z]{3,}"#)
    static let spacedCjk = CompiledRegex(#"(?<![^\s])[\u3400-\u9fff](?: [\u3400-\u9fff](?![^\s]))+"#)
    static let pureDigitSequel = CompiledRegex(#"^\d{1,2}$"#)

    static let cjkBilingual = CompiledRegex("双语|雙語|中英|简英|繁英|簡英|简日|繁日|簡日|简繁|簡繁")
    static let cjkSdh = CompiledRegex("听障|聽障")
    static let cjkForced = CompiledRegex("强制|強制")
    static let cjkDefault = CompiledRegex("默认|默認")
}

// MARK: - Complete Subtitle Trait Flags (matching Dart follow.dart)

private let parserZhHansTokens: Set<String> = [
    "chs", "sc", "gb", "gbk", "gb2312", "jpsc", "cn", "简体", "简中", "简", "简体中文",
    "简日", "简英", "简繁", "中英", "中英双语", "中英雙語", "中字双语", "中字", "双语", "雙語",
    "zh-cn", "zh-hans", "zh-sg", "zhs", "zh", "chi", "zho", "chinese", "中文",
]
private let parserZhHantTokens: Set<String> = [
    "cht", "tc", "big5", "jptc", "繁体", "繁體", "繁中", "繁", "繁体中文", "繁體中文",
    "繁日", "繁英", "zh-tw", "zh-hk", "zh-hant", "zh-mo", "tw", "hk", "zht",
]
private let parserEnTokens: Set<String> = ["eng", "en", "english", "en-us", "en-gb", "英文", "英语", "英語"]
private let parserJaTokens: Set<String> = ["jpn", "jap", "ja", "jp", "ja-jp", "japanese", "日文", "日语", "日語"]
private let parserKoTokens: Set<String> = ["kor", "ko", "kr", "ko-kr", "korean", "韩文", "韓文", "韩语", "韓語"]
private let parserBilingualTokens: Set<String> = [
    "bilingual", "jpsc", "jptc", "scjp", "tcjp",
    "chseng", "chteng", "sceng", "tceng", "chsjp", "chtjp",
    "chs&eng", "cht&eng", "sc&en", "tc&en", "zhongying",
    "双语", "雙語", "中英", "简英", "繁英", "簡英", "简日", "繁日", "簡日", "简繁", "簡繁",
]

private func parserSingleSubLang(_ normalizedLower: String) -> String? {
    if parserZhHansTokens.contains(normalizedLower) { return "zh-Hans" }
    if parserZhHantTokens.contains(normalizedLower) { return "zh-Hant" }
    if parserEnTokens.contains(normalizedLower) { return "en" }
    if parserJaTokens.contains(normalizedLower) { return "ja" }
    if parserKoTokens.contains(normalizedLower) { return "ko" }
    return nil
}

private let subRemSep = CharacterSet(charactersIn: ". \t\n[]()（）【】")
private let subPartSep = CharacterSet(charactersIn: "&+/,")
private let subEdgeDash = CharacterSet(charactersIn: "-_")

private func parserSubFlagsFromRemainder(_ remainder: String) -> [String] {
    if remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
    var bilingual = false
    var sdh = false
    var forced = false
    var isDefault = false
    var langs: Set<String> = []
    var flatTokens: [String] = []

    for chunk in remainder.components(separatedBy: subRemSep) where !chunk.isEmpty {
        for raw in chunk.components(separatedBy: subPartSep) {
            let seg = raw.trimmingCharacters(in: subEdgeDash).trimmingCharacters(in: .whitespacesAndNewlines)
            if seg.isEmpty { continue }
            if ParserRegexes.cjkBilingual.hasMatch(seg) { bilingual = true }
            if ParserRegexes.cjkSdh.hasMatch(seg) { sdh = true }
            if ParserRegexes.cjkForced.hasMatch(seg) { forced = true }
            if ParserRegexes.cjkDefault.hasMatch(seg) { isDefault = true }

            let parts = seg.lowercased().components(separatedBy: subEdgeDash).filter { !$0.isEmpty }
            var i = 0
            while i < parts.count {
                if i + 1 < parts.count {
                    let pair = "\(parts[i])-\(parts[i + 1])"
                    if let pairLang = parserSingleSubLang(pair) {
                        langs.insert(pairLang)
                        flatTokens.append(pair)
                        i += 2
                        continue
                    }
                }
                flatTokens.append(parts[i])
                i += 1
            }
        }
    }

    for i in 0..<flatTokens.count {
        let p = flatTokens[i]
        if p == "forced" || p == "force" {
            forced = true
        } else if p == "default" {
            isDefault = true
        } else if p == "sdh" || p == "hi" || p == "cc" {
            sdh = true
        } else if p == "dual" {
            let nextIsAudio = i + 1 < flatTokens.count && flatTokens[i + 1] == "audio"
            if !nextIsAudio { bilingual = true }
        } else if parserBilingualTokens.contains(p) {
            bilingual = true
        }
        if let lang = parserSingleSubLang(p) {
            langs.insert(lang)
        }
    }

    var out: [String] = []
    if bilingual || langs.count >= 2 { out.append("bilingual") }
    if sdh { out.append("sdh") }
    if forced { out.append("forced") }
    if isDefault { out.append("default") }
    return out
}

// MARK: - Classification

private func isAd(_ c: String) -> Bool {
    ParserRegexes.adKw.hasMatch(c) || ParserRegexes.url.hasMatch(c)
}

private func extractBasename(_ fileName: String) -> String {
    let s = fileName.replacingOccurrences(of: "\\", with: "/")
    if let m = ParserRegexes.scheme.firstMatch(s) {
        let prefix = utf16Sub(s, 0, m.start)
        guard let lastSlash = prefix.lastIndex(of: "/") else { return s }
        let afterSlashUtf16 = prefix[..<lastSlash].utf16.count + 1
        return utf16Sub(s, afterSlashUtf16, utf16Count(s))
    }
    if let lastSlash = s.lastIndex(of: "/") {
        return String(s[s.index(after: lastSlash)...])
    }
    return s
}

func fileExtOf(_ name: String) -> String? {
    guard let dotIdx = name.lastIndex(of: "."), dotIdx > name.startIndex else { return nil }
    let extSlice = name[name.index(after: dotIdx)...]
    let len = extSlice.utf16.count
    if len == 0 || len > 8 { return nil }
    let lower = extSlice.lowercased()
    return ParserRegexes.ext.hasMatch(lower) ? lower : nil
}

/// Classifies a filename by extension, OS metadata rules, sample tags, and ad/junk heuristics.
public func classifyFile(_ fileName: String) -> FileRole {
    let base = foldFilename(extractBasename(fileName))
    let lower = base.lowercased()
    if base.hasPrefix("._") || lower == ".ds_store" || lower == "thumbs.db" || lower == "desktop.ini" {
        return .junk
    }
    guard let ext = fileExtOf(base), knownExtensions.contains(ext) else {
        return .other
    }
    if junkExtensions.contains(ext) {
        return .junk
    }
    let stem = utf16Sub(base, 0, utf16Count(base) - utf16Count(ext) - 1)

    // Remove ad brackets, URLs and ad phrases; nothing meaningful left -> junk.
    var rest = ParserRegexes.anyBracket.replaceAllMapped(stem) { m in
        let matched = m[0] ?? ""
        return isAd(matched) ? " " : matched
    }
    let hadAd = ParserRegexes.url.hasMatch(rest) || ParserRegexes.adKw.hasMatch(rest) || rest != stem
    rest = ParserRegexes.url.replaceAll(rest, with: " ")
    rest = ParserRegexes.adKw.replaceAll(rest, with: " ")
    let empty = !ParserRegexes.letterOrDigit.hasMatch(rest)

    if videoExtensions.contains(ext) {
        let s = stem.lowercased()
        if ParserRegexes.sample.hasMatch(s) {
            return .junk
        }
        return empty ? .junk : .video
    }
    if subtitleExtensions.contains(ext) {
        return empty ? .junk : .subtitle
    }
    return (empty || hadAd) ? .junk : .sidecar
}

// MARK: - Folding & Analysis

/// Fullwidth -> ASCII, CJK brackets -> `[]`, CJK quotes -> space.
func foldFilename(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    out.reserveCapacity(s.unicodeScalars.count)
    for scalar in s.unicodeScalars {
        let v = scalar.value
        if v == 0x3000 {
            out.append(" ")
        } else if v == 0x3010 || v == 0xFF3B {
            out.append("[")
        } else if v == 0x3011 || v == 0xFF3D {
            out.append("]")
        } else if v >= 0xFF01 && v <= 0xFF5E, let mapped = UnicodeScalar(v - 0xFEE0) {
            out.append(mapped)
        } else if cjkQuotes.contains(v) {
            out.append(" ")
        } else {
            out.append(scalar)
        }
    }
    return String(out)
}

struct AnalyzedInfo: Sendable {
    var title: String = ""
    var year: Int?
    var season: Int?
    var episodes: [Int] = []
    var bare: Int?
    var bareFrom: String = ""
    var leadNum: Int?
    var loneFourDigit: Int?
    var explicitEp: Bool = false
    var sxe: Bool = false
    var batch: Bool = false
    var airDate: Date?
    var airDateYear: Int?
    var specialKw: Bool = false
    var extraKw: Bool = false
    var movieKw: Bool = false
    var hasTech: Bool = false
    var res: String?
    var group: String?
    var lang: String?
    var extra: String?
    var edition: String?
    var part: Int?
    var partLabel: String?
    var subFlags: [String] = []
    var externalId: ExternalId?
}

/// Fast zero-allocation current UTC Gregorian year via Howard Hinnant epoch-day math.
func currentGregorianYear(now: Date = Date()) -> Int {
    let totalSec = Int64(now.timeIntervalSince1970)
    var days = totalSec / 86_400
    if totalSec % 86_400 < 0 { days -= 1 }
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let yBase = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let month = mp + (mp < 10 ? 3 : -9)
    return Int(yBase + (month <= 2 ? 1 : 0))
}

private final class DirAnalyzeCache: @unchecked Sendable {
    static let shared = DirAnalyzeCache()
    private static let maxEntries = 4096

    private let lock = NSLock()
    private var cachedYear: Int = 0
    private var storage: [String: AnalyzedInfo] = [:]

    func analyze(_ raw: String) -> AnalyzedInfo {
        let year = currentGregorianYear()
        lock.lock()
        if cachedYear != year {
            storage.removeAll(keepingCapacity: true)
            cachedYear = year
        } else if let hit = storage[raw] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let result = analyzeName(raw, isFile: false, currentYear: year)

        lock.lock()
        if cachedYear != year {
            storage.removeAll(keepingCapacity: true)
            cachedYear = year
        } else if storage.count >= Self.maxEntries {
            storage.removeAll(keepingCapacity: true)
        }
        storage[raw] = result
        lock.unlock()
        return result
    }
}

func analyzeDirNameCached(_ raw: String) -> AnalyzedInfo {
    DirAnalyzeCache.shared.analyze(raw)
}

private func extIdPriority(_ source: String) -> Int {
    switch source {
    case "tmdb": return 3
    case "imdb": return 2
    case "tvdb": return 1
    default: return 0
    }
}

private func pickExtId(_ current: ExternalId?, _ candidate: ExternalId) -> ExternalId {
    guard let current else { return candidate }
    return extIdPriority(candidate.source) > extIdPriority(current.source) ? candidate : current
}

private func isTechOnly(_ s: String) -> Bool {
    let total = utf16Count(s)
    guard total > 0 else { return false }
    var pos = 0
    while pos < total {
        guard let end = ParserRegexes.techToken.matchEndAtPrefix(s, utf16Pos: pos, totalUtf16Len: total),
              end > pos else {
            return false
        }
        pos = end
    }
    return true
}

private func isNoiseBracket(_ c: String) -> Bool {
    if c.isEmpty { return true }
    if ParserRegexes.crc.hasMatch(c) { return true }
    if ParserRegexes.fourDigitYear.hasMatch(c) { return true }
    let s1 = ParserRegexes.cnNoise.replaceAll(c, with: " ")
    let stripped = ParserRegexes.cnNoiseTag.replaceAll(s1, with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if stripped.isEmpty { return true }
    // Split on noise delimiters
    let replaced = ParserRegexes.splitNoise.replaceAll(stripped, with: "\u{0000}")
    let toks = replaced.split(separator: "\u{0000}").map(String.init).filter { !$0.isEmpty }
    return toks.allSatisfy(isTechOnly)
}

private func hasExtraMarker(_ c: String) -> Bool {
    ParserRegexes.extraCs.hasMatch(c) || ParserRegexes.extraCi.hasMatch(c)
}

private func firstExtraMatch(_ s: String) -> RegexMatch? {
    let a = ParserRegexes.extraCs.firstMatch(s)
    let b = ParserRegexes.extraCi.firstMatch(s)
    guard let a else { return b }
    guard let b else { return a }
    return a.start <= b.start ? a : b
}

private func hasEpisodeMarker(_ c: String) -> Bool {
    ParserRegexes.se.hasMatch(c)
        || ParserRegexes.seHalf.hasMatch(c)
        || ParserRegexes.xEp.hasMatch(c)
        || ParserRegexes.cnEp.hasMatch(c)
        || ParserRegexes.cnEpHalf.hasMatch(c)
        || ParserRegexes.ep.hasMatch(c)
        || ParserRegexes.epHalf.hasMatch(c)
        || ParserRegexes.special.hasMatch(c)
        || hasExtraMarker(c)
        || ParserRegexes.seasonRes.contains(where: { $0.hasMatch(c) })
}

private func protectReleaseTokens(_ input: String) -> String {
    var s = ParserRegexes.webdl.replaceAll(input, with: "WEBDL")
    s = ParserRegexes.bluray.replaceAll(s, with: "BluRay")
    s = ParserRegexes.half3d.replaceAllMapped(s) { m in
        let prefix = (m[1] ?? "").lowercased() == "half" ? "Half" : "H"
        let suffix = (m[2] ?? "").uppercased()
        return prefix + suffix
    }
    return s
}

private func normalizeText(_ input: String) -> String {
    var s = protectReleaseTokens(input)
    s = ParserRegexes.h26x.replaceAllMapped(s) { m in "H26\(m[1] ?? "")" }
    s = ParserRegexes.hdr10Plus.replaceAllMapped(s) { m in "\(m[1] ?? "")plus" }
    s = ParserRegexes.audioCh.replaceAllMapped(s) { m in "\(m[1] ?? "")\(m[2] ?? "")\(m[3] ?? "")" }
    s = ParserRegexes.chDigit.replaceAllMapped(s) { m in "ch\(m[1] ?? "")\(m[2] ?? "")" }
    s = ParserRegexes.localeUnderscore.replaceAllMapped(s) { m in
        if let g1 = m[1], let g2 = m[2] {
            return "\(g1)\u{0002}\(g2)"
        }
        return "\(m[3] ?? "")\u{0002}\(m[4] ?? "")"
    }
    s = ParserRegexes.halfDot.replaceAllMapped(s) { m in
        "\(m[1] ?? "")\(m[2] ?? "")\u{0003}5"
    }
    s = ParserRegexes.dotsUnderscores.replaceAll(s, with: " ")
    s = s.replacingOccurrences(of: "\u{0002}", with: "_")
        .replacingOccurrences(of: "\u{0003}", with: ".")
    return ParserRegexes.whitespace.replaceAll(s, with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func makeRange(_ first: Int, _ last: Int?) -> [Int] {
    guard let last, last > first, last - first <= 200 else { return [first] }
    return Array(first...last)
}

/// Validates an 8-digit `YYYYMMDD` calendar date without rolling invalid days (e.g. `20240231`)
/// and returns `(UTC midnight Date, year)`.
private func tryParseCalendarDate(_ digits: String) -> (Date, Int)? {
    guard digits.utf16.count == 8,
          let y = Int(utf16Sub(digits, 0, 4)),
          let mo = Int(utf16Sub(digits, 4, 6)),
          let d = Int(utf16Sub(digits, 6, 8)),
          (1...12).contains(mo) else {
        return nil
    }
    let isLeap = (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)
    let daysInMonths = [0, 31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard d >= 1 && d <= daysInMonths[mo] else { return nil }

    // Civil date -> days since 1970-01-01 UTC (Howard Hinnant's algorithm)
    let yr = y - (mo <= 2 ? 1 : 0)
    let era = (yr >= 0 ? yr : yr - 399) / 400
    let yoe = yr - era * 400
    let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    let days = era * 146097 + doe - 719468
    let date = Date(timeIntervalSince1970: TimeInterval(days * 86_400))
    return (date, y)
}

private func cnPart(_ ch: String) -> (Int, String) {
    switch ch {
    case "上": return (1, "pt1")
    case "中": return (2, "pt2")
    default: return (3, "pt3")
    }
}

private func canonExtra(_ t: String) -> String {
    let lower = t.lowercased()
    switch lower {
    case "hdr10plus": return "HDR10+"
    case "hdr10": return "HDR10"
    case "hdr": return "HDR"
    case "dovi", "dv": return "DV"
    case "hlg": return "HLG"
    case "imax": return "IMAX"
    case "atmos": return "Atmos"
    case "truehd": return "TrueHD"
    default:
        if lower.hasPrefix("dts") && lower.hasSuffix("x") {
            return "DTS-X"
        }
        return "DTS-HD"
    }
}

private func sequelNum(_ tok: String) -> Int? {
    if let n = Int(tok), (1...20).contains(n) { return n }
    return sequelWordMap[tok.lowercased()]
}

private func pickTitle(_ region: String) -> String {
    var t = region.replacingOccurrences(of: "\u{0001}", with: " ")
    t = ParserRegexes.stripBrackets.replaceAll(t, with: " ")
    t = ParserRegexes.anyWhitespace.replaceAll(t, with: " ")
    t = ParserRegexes.edgePunct.replaceAll(t, with: "")
    // "谜.探.路.德.维.希" (dots between every character): join the run back up.
    t = ParserRegexes.spacedCjk.replaceAllMapped(t) { m in
        (m[0] ?? "").replacingOccurrences(of: " ", with: "")
    }
    // Bilingual: keep CJK block when a Latin block with a 3+ letter word is at one edge.
    let toks = t.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    if toks.count > 1 && toks.contains(where: { ParserRegexes.cjk.hasMatch($0) }) {
        let isLatin = toks.map { !ParserRegexes.cjk.hasMatch($0) }
        if let first = isLatin.firstIndex(of: false),
           let last = isLatin.lastIndex(of: false) {
            let contiguous = !isLatin[first...last].contains(true)
            var latin: [String] = []
            for i in 0..<toks.count where isLatin[i] {
                latin.append(toks[i])
            }
            if contiguous && !latin.isEmpty && latin.contains(where: { ParserRegexes.latinThreeWord.hasMatch($0) }) {
                var end = last
                if last + 1 < toks.count && ParserRegexes.pureDigitSequel.hasMatch(toks[last + 1]),
                   let seq = Int(toks[last + 1]) {
                    let afterSeq = Array(toks[(last + 2)...])
                    let isCjkSequel = afterSeq.isEmpty
                        || sequelNum(afterSeq.last!) == seq
                        || afterSeq.first!.lowercased() == "the"
                    if isCjkSequel {
                        end = last + 1
                    }
                }
                t = toks[first...end].joined(separator: " ")
            }
        }
    }
    return t
}

func analyzeName(_ raw: String, isFile: Bool, currentYear: Int = currentGregorianYear()) -> AnalyzedInfo {
    var a = AnalyzedInfo()
    var s = foldFilename(raw)
    var isSub = false
    if isFile, let e = fileExtOf(s), knownExtensions.contains(e) {
        s = utf16Sub(s, 0, utf16Count(s) - utf16Count(e) - 1)
        isSub = subtitleExtensions.contains(e)
    }
    s = ParserRegexes.www.replaceAll(s, with: " ")
    s = ParserRegexes.leadDomain.replaceFirst(s, with: "")

    // Strip external catalog IDs early so they never become release groups or pollute the title.
    func stripExtIds(_ input: String, _ re: CompiledRegex) -> String {
        re.replaceAllMapped(input) { m in
            let id: ExternalId
            if let src = m[1], let val = m[2] {
                id = ExternalId(src.lowercased(), val)
            } else if m[3] != nil, let val = m[4] {
                id = ExternalId("imdb", val.lowercased())
            } else {
                id = ExternalId("imdb", (m[5] ?? "").lowercased())
            }
            a.externalId = pickExtId(a.externalId, id)
            return " "
        }
    }
    s = stripExtIds(s, ParserRegexes.extIdBracketed)
    s = stripExtIds(s, ParserRegexes.extIdBare)

    s = ParserRegexes.date.replaceAllMapped(s) { dm in
        let rawDate = dm[0] ?? ""
        let digits = ParserRegexes.dashDate.replaceAll(rawDate, with: "")
        guard let (dt, yr) = tryParseCalendarDate(digits) else { return rawDate }
        if a.airDate == nil {
            a.airDate = dt
            a.airDateYear = yr
        }
        return " \u{0001} "
    }

    // Leading brackets: first non-noise square bracket is the group; second is altTitle.
    var tail = ""
    var altTitle: String?
    while let m = ParserRegexes.leadBracket.firstMatch(s) {
        let isSquare = m[1] != nil
        let c = (m[1] ?? m[2] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        s = utf16Sub(s, m.end, utf16Count(s))
        if isAd(c) || ParserRegexes.crc.hasMatch(c) { continue }
        if ParserRegexes.numWithV.hasMatch(c) && !ParserRegexes.fourDigitYear.hasMatch(c) {
            tail += " - \(c) "
            continue
        }
        if isNoiseBracket(c) || hasEpisodeMarker(c) {
            tail += " \(c)"
            continue
        }
        if isSquare {
            if a.group == nil {
                a.group = c
            } else if altTitle == nil {
                altTitle = c
            }
        } else {
            tail += " \(c)"
        }
    }

    // Protect release tokens before trailing "-GROUP" is looked for.
    s = protectReleaseTokens(s)
    if a.group == nil, let gm = ParserRegexes.trailerGroup.firstMatch(s), let cand = gm[1] {
        let before = normalizeText(utf16Sub(s, 0, gm.start))
        let isSubMeta = isSub && (ParserRegexes.lang.hasMatch(cand) || ParserRegexes.subFlagTrailer.hasMatch(cand))
        if ParserRegexes.tech.hasMatch(before)
            && !ParserRegexes.tech.hasMatch(cand)
            && !ParserRegexes.eNum.hasMatch(cand)
            && !nonGroupTrailerTags.contains(cand.lowercased())
            && !isSubMeta {
            a.group = cand
            s = utf16Sub(s, 0, gm.start) + utf16Sub(s, gm.start + 1 + utf16Count(cand), utf16Count(s))
        }
    }

    // Remaining brackets: ad -> drop; pure number -> " - N"; anything else ends the title.
    s = ParserRegexes.midBracket.replaceAllMapped(s) { m in
        let c = (m[1] ?? m[2] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if isAd(c) || ParserRegexes.crc.hasMatch(c) { return " " }
        if ParserRegexes.numWithV.hasMatch(c) && !ParserRegexes.fourDigitYear.hasMatch(c) {
            return " - \(c) "
        }
        return " \u{0001} \(c) "
    }
    s = normalizeText("\(s) \(tail)")

    // "剧场版 名侦探柯南 ..." — anime movie prefix/mid-title is stripped as a flag.
    if let cjkMovieM = ParserRegexes.cjkMovie.firstMatch(s) {
        a.movieKw = true
        let matched = cjkMovieM[0] ?? ""
        var after = utf16Sub(s, cjkMovieM.end, utf16Count(s))
        after = ParserRegexes.tech.replaceAll(after, with: " ")
        after = ParserRegexes.cnNoise.replaceAll(after, with: " ")
        after = ParserRegexes.year.replaceAll(after, with: " ")
        after = after.replacingOccurrences(of: "\u{0001}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cjkMovieM.start > 0
            && (matched == "剧场版" || matched == "劇場版")
            && !ParserRegexes.afterTheatricalTitle.hasMatch(after) {
            if a.edition == nil { a.edition = "Theatrical" }
        }
        s = utf16ReplaceRange(s, cjkMovieM.start, cjkMovieM.end, with: " ")
        s = ParserRegexes.multiSpace.replaceAll(s, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } else if let theMovieM = ParserRegexes.theMovie.firstMatch(s), theMovieM.start > 0 {
        a.movieKw = true
        s = utf16ReplaceRange(s, theMovieM.start, theMovieM.end, with: " ")
        s = ParserRegexes.multiSpace.replaceAll(s, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let sLen = utf16Count(s)
    var cut = sLen
    func mark(_ i: Int) {
        if i >= 0 && i < cut { cut = i }
    }

    // ---- season / episode (check .5 recap specials first so they don't collide)
    if let m = ParserRegexes.seHalf.firstMatch(s), let ep = m[2].flatMap(Int.init) {
        a.specialKw = true
        a.episodes = [ep]
        a.explicitEp = true
        a.sxe = true
        mark(m.start)
    }
    if a.episodes.isEmpty, let m = ParserRegexes.cnEpHalf.firstMatch(s), let ep = m[1].flatMap(Int.init) {
        a.specialKw = true
        a.episodes = [ep]
        a.explicitEp = true
        mark(m.start)
    }
    if a.episodes.isEmpty, let m = ParserRegexes.epHalf.firstMatch(s), let ep = m[1].flatMap(Int.init) {
        a.specialKw = true
        a.episodes = [ep]
        a.explicitEp = true
        mark(m.start)
    }
    if a.episodes.isEmpty, let m = ParserRegexes.se.firstMatch(s),
       let sn = m[1].flatMap(Int.init), let firstEp = m[2].flatMap(Int.init) {
        a.season = sn
        var nums = [firstEp]
        for t in ParserRegexes.multiEp.allMatches(m[3] ?? "") {
            guard let n = t[2].flatMap(Int.init) else { continue }
            if t[1] != nil, let lastNum = nums.last, n > lastNum, n - lastNum <= 200 {
                nums.append(contentsOf: (lastNum + 1)...n)
            } else {
                nums.append(n)
            }
        }
        a.episodes = nums
        a.explicitEp = true
        a.sxe = true
        mark(m.start)
    }
    if a.episodes.isEmpty, let m = ParserRegexes.xEp.firstMatch(s),
       let sn = m[1].flatMap(Int.init), let ep = m[2].flatMap(Int.init) {
        a.season = sn
        a.episodes = [ep]
        a.explicitEp = true
        mark(m.start)
    }
    if a.episodes.isEmpty, let m = ParserRegexes.cnEp.firstMatch(s) {
        if let n = m[1].flatMap(parseChineseInt) {
            let endEp = m[2].flatMap(parseChineseInt)
            a.episodes = makeRange(n, endEp)
            a.explicitEp = true
            if let partCh = m[3] {
                let (p, label) = cnPart(partCh)
                a.part = p
                a.partLabel = label
            }
            mark(m.start)
        }
    }
    if a.episodes.isEmpty, let m = ParserRegexes.ep.firstMatch(s),
       let firstEp = m[1].flatMap(Int.init) {
        let endEp = m[2].flatMap(Int.init)
        a.episodes = makeRange(firstEp, endEp)
        a.explicitEp = true
        mark(m.start)
    }
    if a.episodes.isEmpty, let m = ParserRegexes.ofEp.firstMatch(s),
       let n = m[1].flatMap(Int.init), let totalOf = m[2].flatMap(Int.init) {
        if n >= 1 && n <= totalOf {
            a.episodes = [n]
            a.explicitEp = true
            mark(m.start)
        }
    }
    if a.episodes.isEmpty, let m = ParserRegexes.hashEp.firstMatch(s),
       let n = m[1].flatMap(Int.init) {
        a.episodes = [n]
        a.explicitEp = true
        mark(m.start)
    }
    if let m = ParserRegexes.batch.firstMatch(s) {
        a.batch = true
        mark(m.start)
    }
    for re in ParserRegexes.seasonRes {
        if let sm = re.firstMatch(s), let sn = sm[1].flatMap(parseChineseInt) {
            if a.season == nil { a.season = sn }
            mark(sm.start)
            break
        }
    }

    // ---- year: last plausible release year (<= currentYear + 2) not at index 0
    let maxYear = currentYear + 2
    var ym: RegexMatch?
    for y in ParserRegexes.year.allMatches(s) {
        if let val = y[1].flatMap(Int.init), y.start > 0, val <= maxYear {
            ym = y
        }
    }

    // ---- volume marker ("vol.1" / "Volume 2"), unless inside a title before a year
    if let vm = ParserRegexes.vol.firstMatch(s), vm.start > 0, (ym == nil || vm.start > ym!.start) {
        mark(vm.start)
        if a.episodes.isEmpty && !ParserRegexes.dash.hasMatch(s) && !ParserRegexes.dashHalf.hasMatch(s),
           let vNum = vm[1].flatMap(Int.init) {
            a.episodes = [vNum]
            a.explicitEp = true
        }
    }

    // ---- special / extra / movie keywords
    if let em = firstExtraMatch(s) {
        let beforeEm = utf16Sub(s, 0, em.start)
        let afterEm = utf16Sub(s, em.end, sLen)
        let emText = em[0] ?? ""
        let inTitle = (a.explicitEp && em.start < cut)
            || ParserRegexes.leadLower.hasMatch(afterEm)
            || (ParserRegexes.theTitlePrefix.hasMatch(beforeEm) && !ParserRegexes.strictExtra.hasMatch(emText))
            || (ym != nil
                && em.start < ym!.start
                && !beforeEm.contains("\u{0001}")
                && !beforeEm.contains(" - ")
                && !ParserRegexes.strictExtra.hasMatch(emText))
        if !inTitle {
            a.extraKw = true
            mark(em.start)
        }
    }
    if let sp = ParserRegexes.special.firstMatch(s), !a.extraKw {
        let beforeSp = utf16Sub(s, 0, sp.start)
        let afterSp = utf16Sub(s, sp.end, sLen)
        let isStrictSp = ParserRegexes.strictSpecial.hasMatch(sp[0] ?? "")
        let nextRest = String(afterSp.drop(while: { $0.isWhitespace }))
        let nextTok = nextRest.isEmpty ? "" : String(nextRest.prefix(while: { $0 != " " }))
        let followedByTitle = !nextRest.isEmpty
            && !nextRest.hasPrefix("\u{0001}")
            && !nextRest.hasPrefix("-")
            && !isTechOnly(nextTok)
            && !ParserRegexes.cnNoise.hasMatch(nextTok)
            && !ParserRegexes.fourDigitYear.hasMatch(nextTok)
            && !ParserRegexes.lang.hasMatch(nextTok)
            && Int(nextTok) == nil
        let spInTitle = (a.explicitEp && a.season != 0)
            || (!isStrictSp
                && (ParserRegexes.leadLower.hasMatch(afterSp)
                    || ParserRegexes.theTitlePrefix.hasMatch(beforeSp)
                    || followedByTitle
                    || (ym != nil
                        && sp.start < ym!.start
                        && !beforeSp.contains("\u{0001}")
                        && !beforeSp.contains(" - "))))
        if !spInTitle {
            a.specialKw = true
            if let nStr = sp[1] ?? sp[2], let n = Int(nStr), a.episodes.isEmpty {
                a.episodes = [n]
            }
            mark(sp.start)
        }
    }

    if let ym, let yrVal = ym[1].flatMap(Int.init) {
        a.year = yrVal
        mark(ym.start)
    }

    // ---- release tokens
    if let tm = ParserRegexes.tech.firstMatch(s) {
        a.hasTech = true
        mark(tm.start)
    }
    if let nm = ParserRegexes.cnNoise.firstMatch(s) {
        mark(nm.start)
    }
    if let um = utf16IndexOf(s, 0x0001) {
        mark(um)
    }

    // ---- release editions (canonical priority; strips edition tags from title)
    func applyEdition(_ re: CompiledRegex, _ canonical: String, requireAfterCut: Bool = false) {
        guard let em2 = re.firstMatch(s) else { return }
        if requireAfterCut {
            if em2.start < cut { return }
        } else if em2.start == 0 {
            return
        }
        if a.edition == nil { a.edition = canonical }
        mark(em2.start)
    }

    applyEdition(ParserRegexes.edDirectorsCut, "Director's Cut")
    applyEdition(ParserRegexes.edDcTag, "Director's Cut", requireAfterCut: true)
    if let fc = ParserRegexes.edFinalCut.firstMatch(s),
       fc.start > 0,
       (ym == nil || fc.start > ym!.start),
       !ParserRegexes.theTitlePrefix.hasMatch(utf16Sub(s, 0, fc.start)) {
        if a.edition == nil { a.edition = "Final Cut" }
        mark(fc.start)
    }
    applyEdition(ParserRegexes.edExtended, "Extended")
    applyEdition(ParserRegexes.edUnrated, "Unrated")
    applyEdition(ParserRegexes.edTheatrical, "Theatrical")
    applyEdition(ParserRegexes.edCriterion, "Criterion")
    applyEdition(ParserRegexes.edImax, "IMAX")
    applyEdition(ParserRegexes.ed3dExplicit, "3D")
    if let m3d = ParserRegexes.ed3d.firstMatch(s),
       m3d.start > 0,
       (ym == nil || m3d.start > ym!.start) {
        if a.edition == nil { a.edition = "3D" }
        mark(m3d.start)
    }
    if let remuxM = ParserRegexes.edRemux.firstMatch(s) {
        if a.edition == nil { a.edition = "Remux" }
        mark(remuxM.start)
    }
    applyEdition(ParserRegexes.edCnDualDub, "国粤双语")
    applyEdition(ParserRegexes.edCnMandarin, "国语")
    applyEdition(ParserRegexes.edCnCantonese, "粤语")

    // ---- multi-part movie / split tags (CD1, Disc 1, Pt 1, Part 1, 上集/下集, (上)/(下))
    if a.part == nil, let cdM = ParserRegexes.partCd.firstMatch(s), cdM.start > 0,
       let n = cdM[1].flatMap(Int.init) {
        a.part = n
        a.partLabel = "cd\(n)"
        mark(cdM.start)
    }
    if a.part == nil, let discM = ParserRegexes.partDisc.firstMatch(s), discM.start > 0,
       let n = discM[1].flatMap(Int.init) {
        a.part = n
        a.partLabel = "disc\(n)"
        mark(discM.start)
    }
    if a.part == nil, let ptM = ParserRegexes.partPt.firstMatch(s), ptM.start > 0,
       let n = ptM[1].flatMap(Int.init) {
        a.part = n
        a.partLabel = "pt\(n)"
        mark(ptM.start)
    }
    if a.part == nil && a.episodes.isEmpty && !a.explicitEp {
        for partM in ParserRegexes.partWord.allMatches(s) {
            if partM.start > 0 && (ym == nil || partM.start > ym!.start),
               let n = partM[1].flatMap(Int.init) {
                a.part = n
                a.partLabel = "pt\(n)"
                mark(partM.start)
                break
            }
        }
    }
    if a.part == nil && (a.episodes.isEmpty || ParserRegexes.cnEp.hasMatch(s)) {
        let cnPartM = ParserRegexes.partCnJi.firstMatch(s)
            ?? ParserRegexes.partCnBracketed.firstMatch(s)
            ?? ParserRegexes.partCnLoose.firstMatch(s)
        if let cnPartM, cnPartM.start > 0, let ch = cnPartM[1] {
            let (p, label) = cnPart(ch)
            a.part = p
            a.partLabel = label
            mark(cnPartM.start)
        }
    }

    // ---- subtitle language and trait flags
    if isSub {
        var lm: RegexMatch?
        var lmOffset = 0
        if cut < sLen {
            lm = ParserRegexes.lang.firstMatch(utf16Sub(s, cut, sLen))
            lmOffset = cut
        }
        if lm == nil {
            let all = ParserRegexes.lang.allMatches(s)
            if !all.isEmpty {
                lm = all.last(where: { $0.start > 0 }) ?? all.last
                lmOffset = 0
            }
        }
        if let lm, let matchedLang = lm[1] {
            a.lang = matchedLang.replacingOccurrences(of: " ", with: "-")
            mark(lmOffset + lm.start)
        }
        if cut == sLen, let fm = ParserRegexes.trailingSubFlag.firstMatch(s) {
            mark(fm.start)
        }
        if cut < sLen {
            a.subFlags = parserSubFlagsFromRemainder(utf16Sub(s, cut, sLen))
        }
    }

    // ---- bare numbers (including .5 anime recap episodes and lone 4-digit stems)
    let noMarker = a.episodes.isEmpty && !a.specialKw && !a.extraKw && !a.movieKw
    if noMarker && isFile {
        if let dhm = ParserRegexes.dashHalf.firstMatch(s), let n = dhm[1].flatMap(Int.init) {
            a.specialKw = true
            a.bare = n
            a.bareFrom = "dash"
            mark(dhm.start)
        }
        if a.bare == nil {
            for dm in ParserRegexes.dash.allMatches(s) {
                guard let rawDigits = dm[1], let n = Int(rawDigits) else { continue }
                let isYear = rawDigits.utf16.count == 4 && n >= 1900 && n <= 2099
                if !isYear {
                    a.bare = n
                    a.bareFrom = "dash"
                    mark(dm.start)
                    break
                }
            }
        }
        if a.bare == nil && a.year == nil {
            let region = utf16Sub(s, 0, cut)
            let halfNums = ParserRegexes.bareHalf.allMatches(region)
            if let last = halfNums.last, let n = last[1].flatMap(Int.init) {
                let before = utf16Sub(region, 0, last.start).trimmingCharacters(in: .whitespacesAndNewlines)
                let after = ParserRegexes.spaceDash.replaceAll(utf16Sub(region, last.end, utf16Count(region)), with: "")
                if after.isEmpty {
                    a.specialKw = true
                    a.bare = n
                    a.bareFrom = before.isEmpty ? "lone" : "trail"
                    cut = last.start
                }
            }
        }
        if a.bare == nil && a.year == nil {
            let region = utf16Sub(s, 0, cut)
            let trimmedRegion = region.trimmingCharacters(in: .whitespacesAndNewlines)
            if let fourM = ParserRegexes.loneFourDigit.firstMatch(trimmedRegion),
               let n = fourM[1].flatMap(Int.init) {
                if n >= 1000 && n < 1900 {
                    a.loneFourDigit = n
                }
            } else {
                let nums = ParserRegexes.bareRegion.allMatches(region)
                if let last = nums.last, let n = last[1].flatMap(Int.init) {
                    let before = utf16Sub(region, 0, last.start).trimmingCharacters(in: .whitespacesAndNewlines)
                    let after = ParserRegexes.spaceDash.replaceAll(utf16Sub(region, last.end, utf16Count(region)), with: "")
                    if before.isEmpty && after.isEmpty {
                        a.bare = n
                        a.bareFrom = "lone"
                        cut = last.start
                    } else if after.isEmpty && !before.replacingOccurrences(of: "-", with: "").isEmpty {
                        a.bare = n
                        a.bareFrom = "trail"
                        cut = last.start
                    } else if before.isEmpty {
                        a.leadNum = n
                    }
                }
            }
        }
    }

    // Re-evaluate subFlags if a bare number or recap moved `cut` earlier.
    if isSub && cut < sLen && a.subFlags.isEmpty {
        a.subFlags = parserSubFlagsFromRemainder(utf16Sub(s, cut, sLen))
    }

    // ---- title
    a.title = pickTitle(utf16Sub(s, 0, cut))
    if a.title.isEmpty, let altTitle {
        a.title = pickTitle(normalizeText(altTitle))
    }

    // ---- resolution / extra info (whole string, so bracketed [1080p] counts)
    if let rm = ParserRegexes.resPi.firstMatch(s), let digits = rm[1] {
        let suffix = (rm[0] ?? "").lowercased().hasSuffix("i") ? "i" : "p"
        a.res = "\(digits)\(suffix)"
    } else {
        let xm = ParserRegexes.resX.firstMatch(s)
        let km = ParserRegexes.resK.firstMatch(s)
        if let xm, let h = xm[1] {
            a.res = "\(h)p"
        } else if let km, let kDigit = km[1] {
            switch kDigit {
            case "2": a.res = "1440p"
            case "4": a.res = "2160p"
            case "8": a.res = "4320p"
            default: break
            }
        }
    }

    // Preserve first-seen insertion order (matching Dart LinkedHashSet):
    // resolution, picture (DV/HDR), audio (Atmos/TrueHD/DTS-HD/DTS-X).
    var picture: [String] = []
    var audio: [String] = []
    for t in ParserRegexes.hdrAudio.allMatches(s) {
        guard let rawTok = t[1] else { continue }
        let k = canonExtra(rawTok)
        if premiumAudioSet.contains(k) {
            if !audio.contains(k) { audio.append(k) }
        } else {
            if !picture.contains(k) { picture.append(k) }
        }
    }
    var extras: [String] = []
    if let res = a.res { extras.append(res) }
    extras.append(contentsOf: picture)
    extras.append(contentsOf: audio)
    if !extras.isEmpty {
        a.extra = extras.joined(separator: ".")
    }
    return a
}
