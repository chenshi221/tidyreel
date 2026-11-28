import Foundation
import TidyreelModels

// MARK: - NormalizedQuery

public struct NormalizedQuery: Equatable, Hashable, Sendable {
    public var text: String
    public var year: Int?

    public init(text: String, year: Int? = nil) {
        self.text = text
        self.year = year
    }
}

// MARK: - Regex Constants

// Not glued directly after CJK characters ("请回答1988" keeps its number in the title).
private let yearRegex = try! NSRegularExpression(
    pattern: #"(?<![0-9\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af])(19|20)[0-9]{2}(?![0-9])"#
)

private let resRegex = try! NSRegularExpression(
    pattern: #"(?<![a-z0-9])([0-9]{3,4}[pi]|[248]k|uhd|hdr|web-?dl|blu-?ray|bdrip|x26[45]|hevc)(?![a-z0-9])"#,
    options: [.caseInsensitive]
)

private let punctRegex = try! NSRegularExpression(
    pattern: #"[\s._\-\[\]()【】（）「」『』《》:：,，;；!！?？~·・|/\\'"‘’“”\&—–―。、×\+…]+"#
)

// Same as punctRegex except apostrophes and '+' stay intact inside words when building
// TMDB search queries ("Schindler's List"), while leading/trailing quotes are stripped.
private let queryPunctRegex = try! NSRegularExpression(
    pattern: #"[\s._\-\[\]()【】（）「」『』《》:：,，;；!！?？~·・|/\\"“”\&—–―。、×…]+"#
)

private let edgeQuotesRegex = try! NSRegularExpression(
    pattern: #"^['‘’]+|['‘’]+$"#
)

private let utcGregorianCalendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    return cal
}()

// MARK: - Query Normalization

/// Strips resolution/source leftovers, punctuation, and a trailing/embedded year from a raw query,
/// returning the cleaned query text.
public func normalizeQuery(_ query: String) -> String {
    normalizeQuery(query, extractYear: true).text
}

/// Strips resolution/source leftovers, punctuation, and (when `extractYear` is true) a year from `raw`.
/// A query whose year is at index 0 ("2001: A Space Odyssey", "2012") or beyond `currentYear + 2`
/// ("Blade Runner 2049") is kept as title text.
public func normalizeQuery(_ raw: String, extractYear: Bool) -> NormalizedQuery {
    let rawRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
    let withoutRes = resRegex.stringByReplacingMatches(in: raw, range: rawRange, withTemplate: " ")
    var s = String(withoutRes.drop(while: { $0.isWhitespace }))

    var extractedYear: Int?
    if extractYear {
        let currentYear = utcGregorianCalendar.component(.year, from: Date())
        let maxYear = currentYear + 2
        var candidateMatch: NSTextCheckingResult?
        var candidateValue: Int?
        let sRange = NSRange(s.startIndex..<s.endIndex, in: s)
        for match in yearRegex.matches(in: s, range: sRange) {
            guard let swiftRange = Range(match.range, in: s),
                  let val = Int(s[swiftRange]) else { continue }
            if match.range.location > 0 && val <= maxYear {
                candidateMatch = match
                candidateValue = val
            }
        }
        if let match = candidateMatch,
           let val = candidateValue,
           let swiftRange = Range(match.range, in: s) {
            var without = s
            without.replaceSubrange(swiftRange, with: " ")
            let withoutRange = NSRange(without.startIndex..<without.endIndex, in: without)
            let stripped = punctRegex.stringByReplacingMatches(in: without, range: withoutRange, withTemplate: "")
            if !stripped.isEmpty {
                extractedYear = val
                s = without
            }
        }
    }

    let sRange = NSRange(s.startIndex..<s.endIndex, in: s)
    let cleaned = queryPunctRegex
        .stringByReplacingMatches(in: s, range: sRange, withTemplate: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanedRange = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
    let text = edgeQuotesRegex
        .stringByReplacingMatches(in: cleaned, range: cleanedRange, withTemplate: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    return NormalizedQuery(text: text, year: extractedYear)
}

// MARK: - Title Comparison & Token Overlap

/// Same title once case, punctuation, and Traditional/Simplified Chinese differences are ignored.
public func sameTitle(_ a: String, _ b: String) -> Bool {
    foldTitle(a) == foldTitle(b)
}

/// Whether `b` (`title`) shares meaningful tokens with `a` (`query`): whole word for Latin,
/// and for multi-character CJK words at least two distinct characters (or exact containment)
/// so single common characters like "的" or "人" don't falsely match.
public func sharesToken(_ a: String, _ b: String) -> Bool {
    PreparedQueryTokens(a).matches(b)
}

/// Pre-folded query tokens reusable across multiple candidate title comparisons.
struct PreparedQueryTokens: Sendable {
    private struct Token: Sendable {
        let folded: String
        let isAscii: Bool
        let scalarSet: Set<Unicode.Scalar>
    }

    private let tokens: [Token]

    init(_ query: String) {
        var list: [Token] = []
        for word in query.split(separator: " ", omittingEmptySubsequences: true) {
            let w = foldTitle(String(word))
            if w.isEmpty { continue }
            let isAscii = w.unicodeScalars.allSatisfy { $0.value < 0x80 }
            let scalarSet: Set<Unicode.Scalar> = isAscii ? [] : Set(w.unicodeScalars)
            list.append(Token(folded: w, isAscii: isAscii, scalarSet: scalarSet))
        }
        self.tokens = list
    }

    func matches(_ candidateTitle: String) -> Bool {
        if tokens.isEmpty { return false }
        let t = foldTitle(candidateTitle)
        if t.isEmpty { return false }

        var tLen: Int?
        var tScalarSet: Set<Unicode.Scalar>?

        for token in tokens {
            if t.contains(token.folded) { return true }
            if !token.isAscii {
                let len: Int
                let set: Set<Unicode.Scalar>
                if let cachedLen = tLen, let cachedSet = tScalarSet {
                    len = cachedLen
                    set = cachedSet
                } else {
                    let scalars = Array(t.unicodeScalars)
                    len = scalars.count
                    set = Set(scalars)
                    tLen = len
                    tScalarSet = set
                }
                let need = (token.scalarSet.count >= 2 && len >= 2) ? 2 : 1
                var matched = 0
                for ch in token.scalarSet where set.contains(ch) {
                    matched += 1
                    if matched >= need { return true }
                }
            }
        }
        return false
    }
}

/// Pre-folded normalized query and packed bigram frequencies for repeated candidate scoring.
struct PreparedScoringQuery: Sendable {
    let folded: String
    let year: Int?
    let scalarCount: Int
    let bigrams: [UInt64: Int]
    let bigramTotal: Int

    init(normalized: NormalizedQuery) {
        let qs = foldTitle(normalized.text)
        self.folded = qs
        self.year = normalized.year
        let scalars = Array(qs.unicodeScalars)
        self.scalarCount = scalars.count
        if scalars.count >= 2 {
            var m: [UInt64: Int] = [:]
            m.reserveCapacity(scalars.count - 1)
            for i in 0..<(scalars.count - 1) {
                let key = (UInt64(scalars[i].value) << 32) | UInt64(scalars[i + 1].value)
                m[key, default: 0] += 1
            }
            self.bigrams = m
            self.bigramTotal = scalars.count - 1
        } else {
            self.bigrams = [:]
            self.bigramTotal = 0
        }
    }
}

// MARK: - Candidate & Episode Fit Scoring

/// Subtle bounded tie-breaker (`0.0..0.03`) derived from TMDB `voteCount` and `popularity`.
public func popularityBonus(_ c: Candidate) -> Double {
    let vc = c.voteCount
    let pop = c.popularity
    if vc == nil && pop == nil { return 0.0 }
    let vcBonus: Double = if let vc, vc > 0 {
        min(0.02, (log10(Double(vc) + 1.0)) / 4.0 * 0.02)
    } else {
        0.0
    }
    let popBonus: Double = if let pop, pop > 0, pop.isFinite {
        min(0.01, (log10(pop + 1.0)) / 3.0 * 0.01)
    } else {
        0.0
    }
    return min(0.03, vcBonus + popBonus)
}

/// Scores how well `c` matches an already-normalized query `normalized`, clamped to `0.0...1.0`.
public func scoreNormalized(
    _ c: Candidate,
    normalized: NormalizedQuery,
    year: Int? = nil,
    kind: MediaKind? = nil
) -> Double {
    scoreNormalized(
        c,
        prepared: PreparedScoringQuery(normalized: normalized),
        year: year,
        kind: kind
    )
}

func scoreNormalized(
    _ c: Candidate,
    prepared: PreparedScoringQuery,
    year: Int? = nil,
    kind: MediaKind? = nil
) -> Double {
    let y = year ?? prepared.year
    var sim = 0.0
    if !prepared.folded.isEmpty {
        let v0 = candidateSimilarity(prepared: prepared, candidateFolded: foldTitle(c.title))
        if v0 > sim { sim = v0 }
        if sim < 1.0, let orig = c.originalTitle {
            let v = candidateSimilarity(prepared: prepared, candidateFolded: foldTitle(orig))
            if v > sim { sim = v }
        }
        if sim < 1.0, let eng = c.englishTitle {
            let v = candidateSimilarity(prepared: prepared, candidateFolded: foldTitle(eng))
            if v > sim { sim = v }
        }
        if sim < 1.0 {
            for alias in c.aliases {
                let v = candidateSimilarity(prepared: prepared, candidateFolded: foldTitle(alias))
                if v > sim { sim = v }
                if sim >= 1.0 { break }
            }
        }
    }

    var score = 0.7 * sim
    if let y, let cy = c.year {
        let d = abs(y - cy)
        if d == 0 { score += 0.2 }
        if d == 1 { score += 0.1 }
    }
    let isTv = (kind == .episode || kind == .special)
    if (kind == .movie && c.kind == .movie) || (isTv && c.kind == .episode) {
        score += 0.1
    }
    if sim >= 0.5 {
        score += popularityBonus(c)
    }
    return min(1.0, max(0.0, score))
}

/// Scores how well `c` matches a user/parsed `query` in `0.0...1.0` (higher is better).
public func scoreCandidate(
    _ c: Candidate,
    query: String,
    year: Int? = nil,
    kind: MediaKind? = nil
) -> Double {
    scoreNormalized(
        c,
        normalized: normalizeQuery(query, extractYear: year == nil),
        year: year,
        kind: kind
    )
}

/// Scores how well a candidate TV show's TMDB season/episode structure matches local files,
/// returning a bonus or penalty in `-0.12 ... +0.10`.
public func scoreEpisodeFit(
    localSeasons: [Int: Int],
    tmdbSeasons: [SeasonInfo],
    maxAbsolute: Int? = nil
) -> Double {
    let regularLocal = localSeasons.filter { $0.key > 0 && $0.value > 0 }
    let maxSeasonLocal = regularLocal.values.max() ?? 0
    let localMaxEp = max(maxSeasonLocal, maxAbsolute ?? 0)
    let localSeasonCount: Int = if !regularLocal.isEmpty {
        regularLocal.count
    } else if let maxAbsolute, maxAbsolute > 0 {
        1
    } else {
        0
    }
    return computeEpisodeFit(
        localMaxEp: localMaxEp,
        localSeasonCount: localSeasonCount,
        tmdbSeasons: tmdbSeasons
    )
}

/// Dart-equivalent overload scoring `localMaxEp` and `localSeasonCount` against `show`.
public func scoreEpisodeFit(
    localMaxEp: Int,
    localSeasonCount: Int,
    show: ShowDetail
) -> Double {
    computeEpisodeFit(
        localMaxEp: localMaxEp,
        localSeasonCount: localSeasonCount,
        tmdbSeasons: show.seasons
    )
}

private func computeEpisodeFit(
    localMaxEp: Int,
    localSeasonCount: Int,
    tmdbSeasons: [SeasonInfo]
) -> Double {
    let regular = tmdbSeasons.filter { $0.number > 0 && $0.episodeCount > 0 }
    guard localMaxEp > 0, !regular.isEmpty else { return 0.0 }

    let totalRegularEps = regular.reduce(0) { $0 + $1.episodeCount }
    let maxSeasonEps = regular.reduce(0) { max($0, $1.episodeCount) }
    let tmdbSeasonCount = regular.count

    var score = 0.0
    if localMaxEp <= maxSeasonEps {
        score += 0.06
        if localMaxEp >= 2 && regular.contains(where: { $0.episodeCount == localMaxEp }) {
            score += 0.02
        }
    } else if localMaxEp <= totalRegularEps {
        score += 0.06
        if localMaxEp >= 2 && localMaxEp == totalRegularEps {
            score += 0.02
        }
    } else {
        let excess = localMaxEp - totalRegularEps
        let ratio = Double(localMaxEp) / Double(totalRegularEps)
        if excess <= 2 && ratio <= 1.25 {
            score -= 0.02
        } else if ratio <= 2.0 && excess < 10 {
            score -= 0.06
        } else if ratio < 3.0 && excess < 15 {
            score -= 0.09
        } else {
            score -= 0.12
        }
    }

    if localSeasonCount > 0 {
        if localSeasonCount <= tmdbSeasonCount {
            if score >= 0 {
                score += (tmdbSeasonCount - localSeasonCount) <= 1 ? 0.02 : 0.01
            }
        } else {
            let extraSeasons = localSeasonCount - tmdbSeasonCount
            if extraSeasons == 1 {
                score -= 0.02
            } else if extraSeasons == 2 {
                score -= 0.06
            } else {
                score -= 0.10
            }
        }
    }

    return min(0.10, max(-0.12, score))
}

// MARK: - Internal Helpers

func foldTitle(_ s: String) -> String {
    normTitle(s)
}

private func candidateSimilarity(prepared: PreparedScoringQuery, candidateFolded b: String) -> Double {
    let a = prepared.folded
    if a.isEmpty || b.isEmpty { return 0.0 }
    if a == b { return 1.0 }
    let sb = Array(b.unicodeScalars)
    if a.contains(b) || b.contains(a) {
        let short = min(prepared.scalarCount, sb.count)
        let long = max(prepared.scalarCount, sb.count)
        return 0.7 + 0.3 * Double(short) / Double(long)
    }
    guard prepared.bigramTotal > 0, sb.count >= 2 else { return 0.0 }

    var gb: [UInt64: Int] = [:]
    gb.reserveCapacity(sb.count - 1)
    for i in 0..<(sb.count - 1) {
        let key = (UInt64(sb[i].value) << 32) | UInt64(sb[i + 1].value)
        gb[key, default: 0] += 1
    }

    var common = 0
    if prepared.bigrams.count <= gb.count {
        for (k, v) in prepared.bigrams {
            if let o = gb[k] {
                common += min(v, o)
            }
        }
    } else {
        for (k, v) in gb {
            if let o = prepared.bigrams[k] {
                common += min(v, o)
            }
        }
    }
    let total = prepared.bigramTotal + (sb.count - 1)
    guard total > 0 else { return 0.0 }
    return 0.7 * 2.0 * Double(common) / Double(total)
}
