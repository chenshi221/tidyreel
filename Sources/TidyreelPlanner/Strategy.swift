import Foundation
import TidyreelModels

public let episodeOverflowWarning = "超出 TMDB 总集数"

/// Applies a `SeasonStrategy` to `input` episode references using `seasonEpisodeCounts`
/// (index 0 = season 1; specials excluded).
///
/// - For split strategies (`splitSequential`, `splitKeepEpisode`), each input's
///   `episode` is treated as the absolute episode number (its input season is ignored).
/// - For `mergeIntoOne`, inputs are per-season and accumulated into season 1
///   (season 0 specials remain untouched, and seasons beyond `seasonEpisodeCounts`
///   accumulate without colliding).
/// - `episodeOffset` is added to every episode number before the strategy runs.
/// - Numbers beyond the last season's total keep counting in the last season.
/// - An empty `seasonEpisodeCounts` leaves seasons/episodes as they are (only offset applies).
public func applyStrategy(
    _ strategy: SeasonStrategy,
    _ input: [EpisodeRef],
    _ seasonEpisodeCounts: [Int],
    episodeOffset: Int = 0
) -> [EpisodeRef] {
    let shifted = input.map { EpisodeRef($0.season, $0.episode + episodeOffset) }
    if seasonEpisodeCounts.isEmpty || strategy == .asParsed {
        return shifted
    }

    // cum[i] = total episodes in seasons 1..i
    var cum: [Int] = [0]
    cum.reserveCapacity(seasonEpisodeCounts.count + 1)
    for c in seasonEpisodeCounts {
        cum.append(cum[cum.count - 1] + c)
    }
    let last = seasonEpisodeCounts.count

    func split(_ r: EpisodeRef) -> EpisodeRef {
        let n = r.episode
        var s = 1
        while s < last && n > cum[s] {
            s += 1
        }
        let ep = (strategy == .splitSequential) ? (n - cum[s - 1]) : n
        return EpisodeRef(s, ep)
    }

    if strategy == .mergeIntoOne {
        var extraMax: [Int: Int] = [:]
        for r in shifted where r.season > last {
            let ep = r.episode > 0 ? r.episode : 0
            if let existing = extraMax[r.season] {
                if ep > existing { extraMax[r.season] = ep }
            } else {
                extraMax[r.season] = ep
            }
        }
        var overflowOffset: [Int: Int] = [:]
        if !extraMax.isEmpty {
            var acc = cum[last]
            for s in extraMax.keys.sorted() {
                overflowOffset[s] = acc
                acc += extraMax[s] ?? 0
            }
        }
        return shifted.map { r in
            if r.season < 1 {
                return r
            }
            let base = r.season <= last
                ? cum[r.season - 1]
                : (overflowOffset[r.season] ?? cum[last])
            return EpisodeRef(1, base + r.episode)
        }
    }

    return shifted.map(split)
}

/// Labeled convenience overload of `applyStrategy`.
public func applyStrategy(
    _ strategy: SeasonStrategy,
    input: [EpisodeRef],
    seasonEpisodeCounts: [Int],
    episodeOffset: Int = 0
) -> [EpisodeRef] {
    applyStrategy(strategy, input, seasonEpisodeCounts, episodeOffset: episodeOffset)
}

/// Converts a `[seasonNumber: episodeCount]` dictionary into a dense 1-based array
/// (index 0 = season 1; season 0 and negative keys are ignored; missing seasons = 0).
public func denseSeasonCounts(_ bySeason: [Int: Int]) -> [Int] {
    let maxSeason = bySeason.keys.reduce(0) { max($0, $1) }
    guard maxSeason >= 1 else { return [] }
    return (1...maxSeason).map { bySeason[$0] ?? 0 }
}

/// Builds dense 1-based season episode counts from an optional `EpisodeGroup` or `ShowDetail`.
public func seasonEpisodeCounts(show: ShowDetail?, episodeGroup: EpisodeGroup? = nil) -> [Int] {
    if let episodeGroup {
        var map: [Int: Int] = [:]
        for s in episodeGroup.seasons {
            map[s.order] = s.episodes.count
        }
        return denseSeasonCounts(map)
    }
    guard let show else { return [] }
    var map: [Int: Int] = [:]
    for s in show.seasons {
        map[s.number] = s.episodeCount
    }
    return denseSeasonCounts(map)
}

/// Remaps `asParsed` episode references into their positions within a custom `EpisodeGroup`.
public func remapEpisodeGroupAsParsed(_ refs: [EpisodeRef], episodeGroup: EpisodeGroup) -> [EpisodeRef] {
    var inverse: [EpisodeRef: EpisodeRef] = [:]
    for s in episodeGroup.seasons {
        for (i, ep) in s.episodes.enumerated() {
            inverse[ep] = EpisodeRef(s.order, i + 1)
        }
    }
    return refs.map { inverse[$0] ?? $0 }
}

/// Returns true when a resolved TV `EpisodeRef` exceeds the TMDB season/total count.
public func isEpisodeOverflow(
    strategy: SeasonStrategy,
    ref: EpisodeRef,
    seasonEpisodeCounts counts: [Int]
) -> Bool {
    guard !counts.isEmpty, ref.season >= 1 else { return false }
    let total = counts.reduce(0, +)
    switch strategy {
    case .mergeIntoOne, .splitKeepEpisode:
        return ref.episode > total
    case .asParsed, .splitSequential:
        return ref.season > counts.count || ref.episode > counts[ref.season - 1]
    }
}

/// Suggests `.splitSequential` when local video files use continuous unseasoned / S1
/// episode numbers that exceed TMDB Season 1 on a multi-season show.
public func suggestSeasonStrategy(
    files: [ScanFile],
    show: ShowDetail?
) -> (strategy: SeasonStrategy?, reason: String?) {
    guard let show else { return (nil, nil) }
    let regular = show.seasons
        .filter { $0.number > 0 && $0.episodeCount > 0 }
        .sorted { $0.number < $1.number }
    guard regular.count >= 2 else { return (nil, nil) }
    let season1 = regular.first(where: { $0.number == 1 }) ?? regular[0]
    guard season1.episodeCount > 0 else { return (nil, nil) }

    var total = 0
    var unseasonedOrS1 = 0
    var multiSeason = 0
    var maxEp = 0

    for v in files where v.role == .video {
        guard let p = v.parsed else { continue }
        if p.kind == .extra || p.kind == .special || p.season == 0 {
            continue
        }
        guard let ep = p.episodes.first ?? p.absolute else { continue }
        total += 1
        if p.season == nil || p.season == 1 {
            unseasonedOrS1 += 1
            if ep > maxEp { maxEp = ep }
        } else if let s = p.season, s > 1 {
            multiSeason += 1
        }
    }

    if total == 0 || multiSeason > 0 || unseasonedOrS1 * 2 <= total {
        return (nil, nil)
    }

    let totalRegularEps = regular.reduce(0) { $0 + $1.episodeCount }
    if maxEp > season1.episodeCount && maxEp <= totalRegularEps + 5 {
        return (
            .splitSequential,
            "本地为连续绝对集数（最大第 \(maxEp) 集），超出 TMDB 第 1 季（\(season1.episodeCount) 集），建议按 TMDB 季结构顺序拆多季"
        )
    }
    return (nil, nil)
}
