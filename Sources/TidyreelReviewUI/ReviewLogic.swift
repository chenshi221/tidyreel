import Foundation
import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelPlanner

// MARK: - Navigation & Filter Enums

enum LeftPaneTab: String, Hashable, Sendable {
    case matched
    case unmatched
}

enum ReviewFilter: String, CaseIterable, Hashable, Sendable {
    case all
    case conflict
    case incomplete
    case lowConfidence
}

enum DetailTab: Hashable, Sendable {
    case allFiles
    case season(Int)
    case extras
    case folders
}

enum RowBucket: Hashable, Sendable {
    case movie
    case season(Int)
    case extras
}

// MARK: - Regex Helpers

private enum ReviewRegex {
    static let sxxeyy = try! NSRegularExpression(
        pattern: #"S(\d{1,2})\.?E(\d{1,4})"#,
        options: [.caseInsensitive]
    )
    static let crossEp = try! NSRegularExpression(
        pattern: #"(?<!\d)(\d{1,2})x(\d{2,4})(?!\d)"#,
        options: [.caseInsensitive]
    )
    static let seasonDir = try! NSRegularExpression(
        pattern: #"^(?:Season\s*(\d{1,2})|Specials)$"#,
        options: [.caseInsensitive]
    )
    static let ext = try! NSRegularExpression(
        pattern: #"^\.[A-Za-z0-9]{1,5}$"#
    )
    static let diffChunk = try! NSRegularExpression(
        pattern: #"S\d{1,2}\.?E\d{1,4}(?:-E?\d{1,4})?|(?<!\d)\d{1,2}x\d{2,4}(?:-\d{2,4})?(?!\d)|[\s._\-\[\]()（）【】{}]+|[^\s._\-\[\]()（）【】{}]+"#,
        options: [.caseInsensitive]
    )
    static let epTagFull = try! NSRegularExpression(
        pattern: #"^(?:S\d{1,2}\.?E\d{1,4}(?:-E?\d{1,4})?|\d{1,2}x\d{2,4}(?:-\d{2,4})?)$"#,
        options: [.caseInsensitive]
    )
}

private let sepCharSet = CharacterSet(charactersIn: " \t._-[]()（）【】{}")
private let extraSplitSet = CharacterSet(charactersIn: " \t._")
private let audioExtensions: Set<String> = ["mka", "ac3", "eac3", "dts", "dtshd", "truehd"]
private let subDotExtensions: Set<String> = [".srt", ".ass", ".ssa", ".vtt", ".sub", ".idx", ".sup"]
private let subSuffixTags: Set<String> = [
    "forced", "sdh", "default", "bilingual", "hi", "cc",
    "zh", "zh-cn", "zh-tw", "zh-hk", "zh-hans", "zh-hant",
    "chs", "cht", "sc", "tc", "en", "eng", "ja", "jpn", "ko", "kor",
    "chi", "zho", "chs-eng", "cht-eng", "zh-en",
]

// MARK: - Group & Match Helpers

func effectiveMatch(_ group: MediaGroup, _ decision: GroupDecision?) -> Candidate? {
    decision?.match ?? group.match
}

func isGroupMatched(_ group: MediaGroup, _ decision: GroupDecision?) -> Bool {
    effectiveMatch(group, decision) != nil
}

func effectiveGroup(
    _ group: MediaGroup,
    _ decision: GroupDecision?,
    fetchedShows: [Int: ShowDetail] = [:]
) -> MediaGroup {
    let match = effectiveMatch(group, decision)
    let sameMatch = decision?.match == nil || decision?.match?.tmdbId == group.match?.tmdbId
    let resolvedKind = match?.kind ?? group.kind

    var resolvedShow: ShowDetail? = sameMatch ? group.show : nil
    if resolvedKind == .episode, let tmdbId = match?.tmdbId {
        if resolvedShow?.info.tmdbId != tmdbId, let cached = fetchedShows[tmdbId] {
            resolvedShow = cached
        }
    }

    var suggestedStrategy = sameMatch ? group.suggestedStrategy : nil
    var suggestedReason = sameMatch ? group.suggestedStrategyReason : nil
    if suggestedStrategy == nil, resolvedKind == .episode, let resolvedShow {
        let suggestion = suggestSeasonStrategy(files: group.files, show: resolvedShow)
        suggestedStrategy = suggestion.strategy
        suggestedReason = suggestion.reason
    }

    if match == nil
        || (resolvedKind == group.kind
            && resolvedShow == group.show
            && suggestedStrategy == group.suggestedStrategy
            && suggestedReason == group.suggestedStrategyReason) {
        return group
    }

    return MediaGroup(
        id: group.id,
        kind: resolvedKind,
        anchorTitle: group.anchorTitle,
        anchorYear: group.anchorYear,
        rootDir: group.rootDir,
        files: group.files,
        match: group.match,
        matchScore: group.matchScore,
        show: resolvedShow,
        suggestedStrategy: suggestedStrategy,
        suggestedStrategyReason: suggestedReason
    )
}

func matchesSearchQuery(_ query: String, group: MediaGroup, decision: GroupDecision?) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return true }
    let normQ = normTitle(trimmed)
    let lowerQ = trimmed.lowercased()
    let m = effectiveMatch(group, decision)
    let fields: [String?] = [
        group.anchorTitle,
        group.rootDir,
        m?.title,
        m?.originalTitle,
        m?.englishTitle,
        m.map { "\($0.tmdbId)" },
    ]
    for raw in fields {
        guard let raw, !raw.isEmpty else { continue }
        if raw.lowercased().contains(lowerQ) { return true }
        if !normQ.isEmpty && normTitle(raw).contains(normQ) { return true }
    }
    return false
}

// MARK: - Episode & Completeness Helpers

func episodeOf(_ file: ScanFile, _ override: FileOverride?) -> Int? {
    override?.episode ?? file.parsed?.episodes.first ?? file.parsed?.absolute
}

func isExtraFile(_ file: ScanFile, _ override: FileOverride?) -> Bool {
    (override?.kind ?? file.parsed?.kind) == .extra
}

func isSpecialFile(_ file: ScanFile, _ override: FileOverride?) -> Bool {
    let kind = override?.kind ?? file.parsed?.kind
    if kind == .special { return true }
    if let s = override?.season { return s == 0 }
    return file.parsed?.season == 0
}

func isAudioCompanion(_ file: ScanFile) -> Bool {
    audioExtensions.contains(extOf(file.name).lowercased())
}

func parseEpisodeRefFromFilename(_ name: String) -> EpisodeRef? {
    guard !name.isEmpty else { return nil }
    let nsRange = NSRange(name.startIndex..<name.endIndex, in: name)
    if let m = ReviewRegex.sxxeyy.firstMatch(in: name, range: nsRange),
       let rS = Range(m.range(at: 1), in: name),
       let rE = Range(m.range(at: 2), in: name),
       let s = Int(name[rS]),
       let e = Int(name[rE]) {
        return EpisodeRef(s, e)
    }
    if let m = ReviewRegex.crossEp.firstMatch(in: name, range: nsRange),
       let rS = Range(m.range(at: 1), in: name),
       let rE = Range(m.range(at: 2), in: name),
       let s = Int(name[rS]),
       let e = Int(name[rE]) {
        return EpisodeRef(s, e)
    }
    return nil
}

struct Completeness: Equatable, Sendable {
    let localSeasons: Int
    let localEpisodes: Int
    let tmdbSeasons: Int?
    let tmdbEpisodes: Int?

    var incomplete: Bool {
        guard let tmdbEpisodes else { return false }
        return localEpisodes < tmdbEpisodes
    }

    var progressFraction: Double? {
        guard let tmdbEpisodes, tmdbEpisodes > 0 else { return nil }
        return min(1.0, max(0.0, Double(localEpisodes) / Double(tmdbEpisodes)))
    }

    func localizedLabel(_ l10n: AppL10n) -> String {
        if l10n.isEn {
            let local = "Local \(localSeasons)S \(localEpisodes)E"
            guard let ts = tmdbSeasons, let te = tmdbEpisodes else { return local }
            return "\(local) / TMDB \(ts)S \(te)E"
        } else {
            let local = "本地 \(localSeasons) 季 \(localEpisodes) 集"
            guard let ts = tmdbSeasons, let te = tmdbEpisodes else { return local }
            return "\(local) / TMDB \(ts) 季 \(te) 集"
        }
    }
}

func completeness(
    _ group: MediaGroup,
    _ decision: GroupDecision?,
    opsBySrc: [String: RenameOp]? = nil
) -> Completeness {
    var eps: Set<EpisodeRef> = []
    let tmdbCounts = seasonEpisodeCounts(show: group.show)
    let strategy = decision?.strategy ?? .asParsed
    let offset = decision?.episodeOffset ?? 0

    for f in group.files where f.role == .video {
        let ov = decision?.overrides[f.path]
        if ov?.ignore == true || isExtraFile(f, ov) { continue }

        if let op = opsBySrc?[f.path], !op.dst.isEmpty,
           let parsed = parseEpisodeRefFromFilename(baseOf(op.dst)) {
            if parsed.season > 0 {
                eps.insert(parsed)
            }
            continue
        }

        guard let rawEp = episodeOf(f, ov) else { continue }
        let rawSeason = ov?.season ?? (isSpecialFile(f, ov) ? 0 : (f.parsed?.season ?? 1))
        if rawSeason <= 0 { continue }
        if ov != nil {
            eps.insert(EpisodeRef(rawSeason, rawEp))
        } else {
            let resolved = applyStrategy(
                strategy,
                input: [EpisodeRef(rawSeason, rawEp)],
                seasonEpisodeCounts: tmdbCounts,
                episodeOffset: offset
            )
            if let first = resolved.first, first.season > 0 {
                eps.insert(first)
            }
        }
    }

    let realSeasons = group.show?.seasons.filter { $0.number > 0 }
    let tmdbSeasonCount = realSeasons?.count
    let tmdbEpisodeCount = realSeasons?.reduce(0) { $0 + $1.episodeCount }
    let localSeasonCount = Set(eps.map(\.season)).count

    return Completeness(
        localSeasons: localSeasonCount,
        localEpisodes: eps.count,
        tmdbSeasons: tmdbSeasonCount,
        tmdbEpisodes: tmdbEpisodeCount
    )
}

// MARK: - Precomputed Review Index

struct ReviewIndex: Sendable {
    let opsBySrc: [String: RenameOp]
    let conflictByOp: [OpId: PlanConflict]
    let conflictGroups: Set<GroupId>
    let mergesByGroup: [GroupId: PlanMerge]
    let folderTabOpsByGroup: [GroupId: [RenameOp]]
    let plannedUnassignedDeletes: Set<String>
    let selectedOpsCount: Int
    let deleteOpsPaths: [String]

    static func build(from review: TaskReview) -> ReviewIndex {
        var opsBySrc: [String: RenameOp] = [:]
        opsBySrc.reserveCapacity(review.preview.ops.count)

        var folderTabOpsByGroup: [GroupId: [RenameOp]] = [:]
        var selectedCount = 0
        var deleteOpsPaths: [String] = []
        var deleteOpIds: Set<OpId> = []
        var deleteSrcSet: Set<String> = []

        for op in review.preview.ops {
            if !op.src.isEmpty && op.kind != .write && op.phase != .folders {
                opsBySrc[op.src] = op
            }
            if op.selected {
                selectedCount += 1
                if op.kind == .delete {
                    deleteOpsPaths.append(op.src)
                    deleteOpIds.insert(op.id)
                    deleteSrcSet.insert(op.src)
                }
            }
            if let gid = op.group {
                if op.phase == .folders || op.kind == .mkdir || op.kind == .write || op.kind == .delete {
                    folderTabOpsByGroup[gid, default: []].append(op)
                }
            }
        }

        var conflictByOp: [OpId: PlanConflict] = [:]
        for c in review.preview.conflicts {
            for opId in c.ops {
                conflictByOp[opId] = c
            }
        }

        var conflictGroups: Set<GroupId> = []
        if !conflictByOp.isEmpty {
            var groupByPath: [String: GroupId] = [:]
            for g in review.scan.groups {
                for f in g.files {
                    groupByPath[f.path] = g.id
                }
            }
            for op in review.preview.ops where conflictByOp[op.id] != nil {
                if let gid = op.group ?? groupByPath[op.src] {
                    conflictGroups.insert(gid)
                }
            }
        }

        var mergesByGroup: [GroupId: PlanMerge] = [:]
        for m in review.preview.merges {
            mergesByGroup[m.group] = m
        }

        var unassignedDeletes: Set<String> = []
        for f in review.scan.unassigned {
            if deleteSrcSet.contains(f.path) || deleteOpIds.contains(OpId("d-\(stableHash(f.path))")) {
                unassignedDeletes.insert(f.path)
            }
        }

        return ReviewIndex(
            opsBySrc: opsBySrc,
            conflictByOp: conflictByOp,
            conflictGroups: conflictGroups,
            mergesByGroup: mergesByGroup,
            folderTabOpsByGroup: folderTabOpsByGroup,
            plannedUnassignedDeletes: unassignedDeletes,
            selectedOpsCount: selectedCount,
            deleteOpsPaths: deleteOpsPaths
        )
    }
}

// MARK: - Review Rows & Virtualized Detail Entries

struct ReviewRow: Identifiable, Equatable, Sendable {
    var id: String { file.path }
    let file: ScanFile
    let op: RenameOp?
    let override: FileOverride?
    let bucket: RowBucket
    let targetRef: EpisodeRef?
    let conflict: Bool
    let conflictReason: String?
    let sizeText: String
    let techBadgesZh: [TechBadgeItem]
    let techBadgesEn: [TechBadgeItem]

    var ignored: Bool { override?.ignore ?? false }
    var selected: Bool { !ignored && (op?.selected ?? false) }

    var newName: String? {
        guard let op, !op.dst.isEmpty else { return nil }
        return baseOf(op.dst)
    }

    func techBadges(for l10n: AppL10n) -> [TechBadgeItem] {
        l10n.isEn ? techBadgesEn : techBadgesZh
    }

    func localizedNewLabel(_ l10n: AppL10n) -> String {
        if ignored {
            return l10n.tr("已忽略", "Ignored")
        }
        if let op, op.src == op.dst {
            return l10n.tr("（名称不变）", "(Unchanged)")
        }
        return newName ?? l10n.tr("（无改动）", "(No change)")
    }
}

struct AssignGroupTarget: Identifiable, Equatable, Sendable {
    let id: GroupId
    let label: String
}

enum UnassignedListItem: Identifiable, Equatable, Sendable {
    case header(dir: String)
    case file(file: ScanFile, isFirstInSection: Bool, isLastInSection: Bool)

    var id: String {
        switch self {
        case .header(let dir): return "dir:\(dir)"
        case .file(let file, _, _): return "file:\(file.path)"
        }
    }
}

func hasMultipleVideos(_ group: MediaGroup) -> Bool {
    var count = 0
    for file in group.files where file.role == .video {
        count += 1
        if count >= 2 { return true }
    }
    return false
}

enum DetailListItem: Identifiable, Equatable, Sendable {
    case video(row: ReviewRow, companions: [ReviewRow], showsBottomDivider: Bool)
    case companionToggle(videoPath: String, summary: String, isOpen: Bool, showsBottomDivider: Bool)
    case companion(row: ReviewRow, parentPath: String, showsBottomDivider: Bool)
    case looseSidecar(row: ReviewRow, showsBottomDivider: Bool)
    case missingEpisode(season: Int, episode: Int, showsBottomDivider: Bool)

    var id: String {
        switch self {
        case .video(let row, _, _): return "v:\(row.id)"
        case .companionToggle(let path, _, _, _): return "ct:\(path)"
        case .companion(let row, _, _): return "c:\(row.id)"
        case .looseSidecar(let row, _): return "s:\(row.id)"
        case .missingEpisode(let s, let e, _): return "m:\(s):\(e)"
        }
    }
}

func buildRows(
    for group: MediaGroup,
    decision: GroupDecision?,
    index: ReviewIndex
) -> [ReviewRow] {
    let isTv = group.kind == .episode
    let tmdbCounts = seasonEpisodeCounts(show: group.show)
    let strategy = decision?.strategy ?? .asParsed
    let offset = decision?.episodeOffset ?? 0

    var out: [ReviewRow] = []
    out.reserveCapacity(group.files.count)

    for f in group.files {
        let ov = decision?.overrides[f.path]
        let op = index.opsBySrc[f.path]
        let conflictInfo = op.flatMap { index.conflictByOp[$0.id] }

        let extra = isExtraFile(f, ov) || (op?.dst.contains("/Extras/") == true)
        let resolvedRef: EpisodeRef?
        let bucket: RowBucket

        if extra {
            resolvedRef = nil
            bucket = .extras
        } else if isTv {
            if let op, !op.dst.isEmpty, let parsed = parseEpisodeRefFromFilename(baseOf(op.dst)) {
                resolvedRef = parsed
                bucket = .season(parsed.season)
            } else {
                let rawSeason = ov?.season ?? (isSpecialFile(f, ov) ? 0 : (f.parsed?.season ?? 1))
                if let rawEp = episodeOf(f, ov) {
                    if ov != nil || rawSeason <= 0 {
                        let ref = EpisodeRef(rawSeason, rawEp)
                        resolvedRef = ref
                        bucket = .season(ref.season)
                    } else {
                        let applied = applyStrategy(
                            strategy,
                            input: [EpisodeRef(rawSeason, rawEp)],
                            seasonEpisodeCounts: tmdbCounts,
                            episodeOffset: offset
                        ).first ?? EpisodeRef(rawSeason, rawEp)
                        resolvedRef = applied
                        bucket = .season(applied.season)
                    }
                } else {
                    resolvedRef = nil
                    bucket = .season(rawSeason)
                }
            }
        } else {
            resolvedRef = nil
            bucket = .movie
        }

        let badgesZh = fileTechBadges(f, l10n: .zh)
        let needsEnVariant = f.isDiscDir
            || (f.parsed?.isDisc == true)
            || (f.parsed?.subFlags.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "bilingual"
            } ?? false)
        let badgesEn = needsEnVariant ? fileTechBadges(f, l10n: .en) : badgesZh

        out.append(ReviewRow(
            file: f,
            op: op,
            override: ov,
            bucket: bucket,
            targetRef: resolvedRef,
            conflict: conflictInfo != nil,
            conflictReason: conflictInfo?.reason,
            sizeText: formatBytesOrEmpty(f.size),
            techBadgesZh: badgesZh,
            techBadgesEn: badgesEn
        ))
    }
    return out
}

func buildDetailItems(
    rows: [ReviewRow],
    bucket: RowBucket,
    missing: [Int],
    expandedVideoPaths: Set<String>,
    highlightedPath: String?,
    l10n: AppL10n
) -> [DetailListItem] {
    let bucketRows = rows.filter { $0.bucket == bucket }
    var videos = bucketRows.filter { $0.file.role == .video }
    let others = bucketRows.filter { $0.file.role != .video }

    videos.sort { a, b in
        let ea = a.targetRef?.episode ?? (1 << 20)
        let eb = b.targetRef?.episode ?? (1 << 20)
        if ea != eb { return ea < eb }
        return a.file.name < b.file.name
    }

    var videoByBase: [String: String] = [:]
    var firstVideoByRef: [EpisodeRef: String] = [:]
    var owned: [String: [ReviewRow]] = [:]

    for v in videos {
        owned[v.file.path] = []
        let b = stem(v.file.name)
        if videoByBase[b] == nil {
            videoByBase[b] = v.file.path
        }
        if let ref = v.targetRef, firstVideoByRef[ref] == nil {
            firstVideoByRef[ref] = v.file.path
        }
    }

    var loose: [ReviewRow] = []
    for o in others {
        var matchedPath: String?
        let name = o.file.name
        var searchEnd = name.endIndex
        while let dot = name[..<searchEnd].lastIndex(of: "."), dot > name.startIndex {
            let candidateStem = String(name[..<dot])
            if let hit = videoByBase[candidateStem] {
                matchedPath = hit
                break
            }
            searchEnd = dot
        }
        if matchedPath == nil, let ref = o.targetRef {
            matchedPath = firstVideoByRef[ref]
        }
        if matchedPath == nil, videos.count == 1, o.file.role == .subtitle {
            matchedPath = videos[0].file.path
        }
        if let matchedPath {
            owned[matchedPath, default: []].append(o)
        } else {
            loose.append(o)
        }
    }

    enum Block {
        case video(ReviewRow, [ReviewRow])
        case missing(Int)
        case looseSidecar(ReviewRow)
    }

    var slots: [(ep: Int, order: Int, block: Block)] = []
    slots.reserveCapacity(videos.count + missing.count)

    for (idx, v) in videos.enumerated() {
        let comps = owned[v.file.path] ?? []
        slots.append((v.targetRef?.episode ?? (1 << 20), idx, .video(v, comps)))
    }
    if case .season = bucket {
        for m in missing {
            slots.append((m, -1, .missing(m)))
        }
    }
    slots.sort { a, b in
        if a.ep != b.ep { return a.ep < b.ep }
        return a.order < b.order
    }

    var blocks: [Block] = slots.map(\.block)
    for l in loose {
        blocks.append(.looseSidecar(l))
    }

    let seasonNumber: Int
    if case .season(let s) = bucket {
        seasonNumber = s
    } else {
        seasonNumber = 1
    }

    var items: [DetailListItem] = []
    items.reserveCapacity(blocks.count * 2)

    for (blockIdx, block) in blocks.enumerated() {
        let isLastBlock = (blockIdx == blocks.count - 1)
        switch block {
        case .video(let v, let comps):
            if comps.isEmpty {
                items.append(.video(row: v, companions: [], showsBottomDivider: !isLastBlock))
            } else {
                let autoOpen = v.ignored || comps.contains { c in
                    c.file.path == highlightedPath
                        || c.conflict
                        || c.ignored
                        || c.override != nil
                        || c.op?.warning != nil
                }
                let isOpen = autoOpen || expandedVideoPaths.contains(v.file.path)
                items.append(.video(row: v, companions: comps, showsBottomDivider: false))
                items.append(.companionToggle(
                    videoPath: v.file.path,
                    summary: companionSummaryLabel(comps, l10n: l10n),
                    isOpen: isOpen,
                    showsBottomDivider: !isOpen && !isLastBlock
                ))
                if isOpen {
                    for (cIdx, c) in comps.enumerated() {
                        let isLastComp = (cIdx == comps.count - 1)
                        items.append(.companion(
                            row: c,
                            parentPath: v.file.path,
                            showsBottomDivider: isLastComp && !isLastBlock
                        ))
                    }
                }
            }
        case .missing(let ep):
            items.append(.missingEpisode(season: seasonNumber, episode: ep, showsBottomDivider: !isLastBlock))
        case .looseSidecar(let l):
            items.append(.looseSidecar(row: l, showsBottomDivider: !isLastBlock))
        }
    }

    return items
}

func companionSummaryLabel(_ companions: [ReviewRow], l10n: AppL10n) -> String {
    var subs = 0
    var audio = 0
    var other = 0
    for r in companions {
        if r.file.role == .subtitle {
            subs += 1
        } else if isAudioCompanion(r.file) {
            audio += 1
        } else {
            other += 1
        }
    }
    var parts: [String] = []
    if subs > 0 {
        parts.append(l10n.tr("\(subs) 个字幕", l10n.plural(subs, "subtitle")))
    }
    if audio > 0 {
        parts.append(l10n.tr("\(audio) 条音轨", l10n.plural(audio, "audio track")))
    }
    if other > 0 {
        parts.append(l10n.tr("\(other) 个其他文件", l10n.plural(other, "other file")))
    }
    return parts.joined(separator: l10n.isEn ? ", " : "，")
}

func seasonCountLabel(group: MediaGroup, rows: [ReviewRow], season: Int) -> String {
    var localEps: Set<Int> = []
    for r in rows where r.bucket == .season(season) && r.file.role == .video && !r.ignored {
        if let ep = r.targetRef?.episode ?? episodeOf(r.file, r.override) {
            localEps.insert(ep)
        }
    }
    if let tmdbSeason = group.show?.seasons.first(where: { $0.number == season }),
       tmdbSeason.episodeCount > 0 {
        return "\(localEps.count)/\(tmdbSeason.episodeCount)"
    }
    return "\(localEps.count)"
}

func seasonTabTitle(_ season: Int, l10n: AppL10n) -> String {
    if season <= 0 {
        return l10n.specials
    }
    return l10n.tr("第 \(season) 季", "Season \(season)")
}

func missingEpisodes(
    group: MediaGroup,
    decision: GroupDecision?,
    rows: [ReviewRow],
    season: Int
) -> [Int] {
    guard season >= 1 else { return [] }
    if let decision, decision.episodeGroupId != nil {
        return []
    }
    guard let total = group.show?.seasons.first(where: { $0.number == season })?.episodeCount,
          total > 0, total <= 500 else {
        return []
    }
    var have: Set<Int> = []
    for r in rows where r.bucket == .season(season) && r.file.role == .video && !r.ignored {
        if let ep = r.targetRef?.episode ?? episodeOf(r.file, r.override) {
            have.insert(ep)
        }
    }
    guard !have.isEmpty else { return [] }
    return (1...total).filter { !have.contains($0) }
}

// MARK: - Filter Evaluation & Conflict Helpers

func isGroupIncomplete(
    _ group: MediaGroup,
    _ decision: GroupDecision?,
    opsBySrc: [String: RenameOp]? = nil,
    fetchedShows: [Int: ShowDetail] = [:]
) -> Bool {
    let eg = effectiveGroup(group, decision, fetchedShows: fetchedShows)
    guard eg.kind == .episode else { return false }
    return completeness(eg, decision, opsBySrc: opsBySrc).incomplete
}

func isGroupLowConfidence(
    _ group: MediaGroup,
    _ decision: GroupDecision?,
    index: ReviewIndex,
    threshold: Double
) -> Bool {
    if decision?.match == nil, group.match != nil, group.matchScore < threshold {
        return true
    }
    for f in group.files {
        let ov = decision?.overrides[f.path]
        if ov?.ignore == true { continue }
        if let warning = index.opsBySrc[f.path]?.warning, warning.contains("置信度") {
            return true
        }
        if decision?.match == nil,
           f.role == .video,
           ov == nil,
           let parsed = f.parsed,
           parsed.confidence < threshold {
            return true
        }
    }
    return false
}

func matchesReviewFilter(
    _ group: MediaGroup,
    decision: GroupDecision?,
    index: ReviewIndex,
    filter: ReviewFilter,
    threshold: Double,
    fetchedShows: [Int: ShowDetail]
) -> Bool {
    switch filter {
    case .all:
        return true
    case .conflict:
        return index.conflictGroups.contains(group.id)
    case .incomplete:
        return isGroupIncomplete(group, decision, opsBySrc: index.opsBySrc, fetchedShows: fetchedShows)
    case .lowConfidence:
        return isGroupLowConfidence(group, decision, index: index, threshold: threshold)
    }
}

struct FirstConflictTarget: Equatable, Sendable {
    let groupId: GroupId
    let tab: DetailTab
    let filePath: String?
}

func firstConflictLocation(
    in review: TaskReview,
    index: ReviewIndex,
    fetchedShows: [Int: ShowDetail]
) -> FirstConflictTarget? {
    guard !index.conflictGroups.isEmpty else { return nil }
    for rawGroup in review.scan.groups where index.conflictGroups.contains(rawGroup.id) {
        let d = review.decisions[rawGroup.id]
        let eg = effectiveGroup(rawGroup, d, fetchedShows: fetchedShows)
        let rows = buildRows(for: eg, decision: d, index: index)
        if let badRow = rows.first(where: \.conflict) {
            let tab: DetailTab
            switch badRow.bucket {
            case .movie: tab = .allFiles
            case .season(let s): tab = .season(s)
            case .extras: tab = .extras
            }
            return FirstConflictTarget(groupId: rawGroup.id, tab: tab, filePath: badRow.file.path)
        }
        return FirstConflictTarget(groupId: rawGroup.id, tab: .folders, filePath: nil)
    }
    return nil
}

// MARK: - Duplicate Conflict Resolution & Shift Helpers

struct GroupDuplicateConflict: Equatable, Sendable {
    let targetPath: String
    let reason: String
    let rows: [ReviewRow]

    var largest: ReviewRow { rows[0] }
    var smaller: ArraySlice<ReviewRow> { rows.dropFirst() }
}

func groupDuplicateConflicts(rows: [ReviewRow], conflicts: [PlanConflict]) -> [GroupDuplicateConflict] {
    guard !conflicts.isEmpty else { return [] }
    var byOpId: [OpId: ReviewRow] = [:]
    for r in rows where !r.ignored {
        if let opId = r.op?.id {
            byOpId[opId] = r
        }
    }
    var out: [GroupDuplicateConflict] = []
    for c in conflicts {
        var matched = c.ops.compactMap { byOpId[$0] }
        guard matched.count >= 2 else { continue }
        matched.sort { a, b in
            if a.file.size != b.file.size { return a.file.size > b.file.size }
            return a.file.path < b.file.path
        }
        out.append(GroupDuplicateConflict(targetPath: c.path, reason: c.reason, rows: matched))
    }
    return out
}

func resolveKeepLargestOverrides(
    current: GroupDecision,
    conflicts: [GroupDuplicateConflict]
) -> [String: FileOverride] {
    var next = current.overrides
    for c in conflicts {
        for row in c.smaller {
            let old = next[row.file.path] ?? row.override
            next[row.file.path] = FileOverride(
                season: old?.season,
                episode: old?.episode,
                kind: old?.kind,
                ignore: true
            )
        }
    }
    return next
}

func seasonSizes(_ group: MediaGroup, _ decision: GroupDecision?) -> [Int: Int] {
    guard let show = group.show,
          decision?.episodeGroupId == nil,
          show.info.tmdbId == effectiveMatch(group, decision)?.tmdbId else {
        return [:]
    }
    var map: [Int: Int] = [:]
    for s in show.seasons where s.number > 0 {
        map[s.number] = s.episodeCount
    }
    return map
}

private func localRawEpisode(_ file: ScanFile) -> Int? {
    file.parsed?.episodes.first ?? file.parsed?.absolute
}

private func isMainVideoRow(_ row: ReviewRow) -> Bool {
    guard row.file.role == .video, !row.ignored else { return false }
    if isExtraFile(row.file, row.override) || isSpecialFile(row.file, row.override) {
        return false
    }
    return true
}

func shiftFollowingCount(rows: [ReviewRow], from: ReviewRow) -> Int {
    guard let start = localRawEpisode(from.file) else { return 0 }
    let localSeason = from.file.parsed?.season ?? 1
    var count = 0
    for r in rows {
        if isMainVideoRow(r),
           r.file.path != from.file.path,
           (r.file.parsed?.season ?? 1) == localSeason,
           (localRawEpisode(r.file) ?? 0) > start {
            count += 1
        }
    }
    return count
}

func shiftFrom(
    group: MediaGroup,
    decision: GroupDecision?,
    rows: [ReviewRow],
    from: ReviewRow,
    to: EpisodeRef,
    kind: MediaKind?
) -> [String: FileOverride] {
    var out: [String: FileOverride] = [
        from.file.path: FileOverride(season: to.season, episode: to.episode, kind: kind, ignore: false),
    ]
    guard let start = localRawEpisode(from.file), to.season >= 1 else { return out }
    let localSeason = from.file.parsed?.season ?? 1
    let later = rows.filter { r in
        isMainVideoRow(r)
            && r.file.path != from.file.path
            && (r.file.parsed?.season ?? 1) == localSeason
            && (localRawEpisode(r.file) ?? 0) > start
    }.sorted { a, b in
        (localRawEpisode(a.file) ?? 0) < (localRawEpisode(b.file) ?? 0)
    }

    let sizes = seasonSizes(group, decision)
    var prevLocal = start
    var s = to.season
    var e = to.episode

    for r in later {
        guard let curLocal = localRawEpisode(r.file) else { continue }
        let delta = curLocal - prevLocal
        if delta > 0 {
            for _ in 0..<delta {
                e += 1
                if let maxEp = sizes[s], e > maxEp, sizes[s + 1] != nil {
                    s += 1
                    e = 1
                }
            }
        }
        prevLocal = curLocal
        out[r.file.path] = FileOverride(season: s, episode: e, kind: r.override?.kind, ignore: false)
    }
    return out
}

struct SeasonOverflowHint: Equatable, Sendable {
    let row: ReviewRow
    let target: EpisodeRef
    let seasonMax: Int
}

func detectSeasonOverflow(
    group: MediaGroup,
    decision: GroupDecision?,
    rows: [ReviewRow]
) -> SeasonOverflowHint? {
    let sizes = seasonSizes(group, decision)
    guard !sizes.isEmpty else { return nil }
    var best: SeasonOverflowHint?
    for r in rows where isMainVideoRow(r) && r.op != nil {
        guard let t = r.targetRef,
              let size = sizes[t.season],
              t.episode > size,
              sizes[t.season + 1] != nil else {
            continue
        }
        if let cur = best {
            if t.season < cur.target.season
                || (t.season == cur.target.season && t.episode < cur.target.episode) {
                best = SeasonOverflowHint(row: r, target: t, seasonMax: size)
            }
        } else {
            best = SeasonOverflowHint(row: r, target: t, seasonMax: size)
        }
    }
    return best
}

// MARK: - MediaProbeInfo & Technical Badges

enum TechBadgeTone: Equatable, Sendable {
    case accent
    case success
    case neutral
}

struct TechBadgeItem: Equatable, Hashable, Sendable {
    let text: String
    let tone: TechBadgeTone
}

func fileTechBadges(_ file: ScanFile, l10n: AppL10n) -> [TechBadgeItem] {
    var out: [TechBadgeItem] = []
    var seen: Set<String> = []

    func appendBadge(_ raw: String?, tone: TechBadgeTone = .neutral) {
        guard let raw else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normKey: String
        switch trimmed.uppercased() {
        case "H265", "H.265", "X265", "HEVC": normKey = "hevc"
        case "H264", "H.264", "X264", "AVC": normKey = "avc"
        case "DOLBYVISION", "DOVI", "DV": normKey = "dv"
        default: normKey = trimmed.lowercased()
        }
        if seen.insert(normKey).inserted {
            out.append(TechBadgeItem(text: trimmed, tone: tone))
        }
    }

    let p = file.parsed
    if file.isDiscDir || (p?.isDisc == true) {
        appendBadge(l10n.tr("原盘", "Disc"), tone: .accent)
    }

    if let probe = p?.probe {
        appendBadge(probe.resolution ?? p?.resolution)
        appendBadge(probe.hdr)
        appendBadge(probe.audioCodec)
        if let ch = probe.audioChannels, ch > 0 {
            switch ch {
            case 8: appendBadge("7.1")
            case 6: appendBadge("5.1")
            default: break
            }
        }
        appendBadge(probe.videoCodec)
    } else if let res = p?.resolution {
        appendBadge(res)
    }

    if let extra = p?.extraInfo, !extra.isEmpty {
        for part in extra.components(separatedBy: extraSplitSet) where !part.isEmpty {
            appendBadge(part)
        }
    }

    appendBadge(p?.edition)
    appendBadge(p?.partLabel)

    if let flags = p?.subFlags {
        for raw in flags {
            let norm = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !norm.isEmpty else { continue }
            let label = (norm == "bilingual") ? l10n.tr("双语", "Bilingual") : norm
            appendBadge(label, tone: .success)
        }
    }

    return out
}

// MARK: - Structured Filename Diff Highlighting

func diffFilenameAttributedString(
    oldName: String,
    newName: String,
    prefix: String = "",
    baseFontSize: CGFloat = TidyreelTypeScale.body,
    baseColor: Color? = nil,
    ignored: Bool,
    conflict: Bool,
    hasWarning: Bool,
    episodeColor: Color? = nil,
    palette: TidyreelPalette
) -> AttributedString {
    let defaultFg = baseColor ?? (ignored ? palette.textFaint : palette.textMuted)
    if ignored
        || newName.isEmpty
        || newName == oldName
        || newName.hasPrefix("（")
        || newName.hasPrefix("(")
        || newName == "已忽略"
        || newName == "Ignored" {
        var plain = AttributedString(prefix + newName)
        plain.foregroundColor = ignored ? palette.textFaint : defaultFg
        plain.font = .system(size: baseFontSize)
        return plain
    }

    var body = newName
    var ext = ""
    if let dot = newName.lastIndex(of: "."), dot > newName.startIndex {
        let maybeExt = String(newName[dot...])
        let nsRange = NSRange(maybeExt.startIndex..<maybeExt.endIndex, in: maybeExt)
        if ReviewRegex.ext.firstMatch(in: maybeExt, range: nsRange) != nil {
            body = String(newName[..<dot])
            ext = maybeExt
        }
    }

    let isSub = subDotExtensions.contains(ext.lowercased())
    var subTokens: [String] = []
    if isSub {
        while let dot = body.lastIndex(of: "."), dot > body.startIndex {
            let seg = String(body[body.index(after: dot)...])
            if !subSuffixTags.contains(seg.lowercased()) { break }
            subTokens.insert(String(body[dot...]), at: 0)
            body = String(body[..<dot])
        }
    }

    let oldStem: String
    if let oldDot = oldName.lastIndex(of: "."), oldDot > oldName.startIndex {
        let maybeExt = String(oldName[oldDot...])
        let nsRange = NSRange(maybeExt.startIndex..<maybeExt.endIndex, in: maybeExt)
        oldStem = ReviewRegex.ext.firstMatch(in: maybeExt, range: nsRange) != nil
            ? String(oldName[..<oldDot])
            : oldName
    } else {
        oldStem = oldName
    }
    let oldWords = Set(
        oldStem.components(separatedBy: sepCharSet)
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
    )

    let epColor = conflict ? palette.danger : (episodeColor ?? palette.accent)
    let changeColor = conflict ? palette.danger : (hasWarning ? palette.warning : palette.text)
    let changeBg = (conflict ? palette.danger : (hasWarning ? palette.warning : palette.accent)).opacity(0.09)

    var result = AttributedString()
    if !prefix.isEmpty {
        var pre = AttributedString(prefix)
        pre.foregroundColor = conflict ? palette.danger : palette.textFaint
        pre.font = .system(size: baseFontSize)
        result.append(pre)
    }

    let bodyNSRange = NSRange(body.startIndex..<body.endIndex, in: body)
    let matches = ReviewRegex.diffChunk.matches(in: body, range: bodyNSRange)

    for m in matches {
        guard let r = Range(m.range, in: body) else { continue }
        let chunk = String(body[r])
        var part = AttributedString(chunk)
        let chunkRange = NSRange(chunk.startIndex..<chunk.endIndex, in: chunk)

        if ReviewRegex.epTagFull.firstMatch(in: chunk, range: chunkRange) != nil {
            part.foregroundColor = epColor
            part.font = .system(size: baseFontSize, weight: .bold)
            part.backgroundColor = epColor.opacity(0.13)
        } else if chunk.trimmingCharacters(in: sepCharSet).isEmpty {
            part.foregroundColor = defaultFg
            part.font = .system(size: baseFontSize)
        } else if oldWords.contains(chunk.lowercased()) {
            part.foregroundColor = defaultFg
            part.font = .system(size: baseFontSize)
        } else {
            part.foregroundColor = changeColor
            part.font = .system(size: baseFontSize, weight: .semibold)
            part.backgroundColor = changeBg
        }
        result.append(part)
    }

    for st in subTokens {
        var part = AttributedString(st)
        part.foregroundColor = palette.success
        part.font = .system(size: baseFontSize, weight: .semibold)
        part.backgroundColor = palette.success.opacity(0.10)
        result.append(part)
    }

    if !ext.isEmpty {
        var part = AttributedString(ext)
        part.foregroundColor = palette.textFaint
        part.font = .system(size: baseFontSize)
        result.append(part)
    }

    return result
}

// MARK: - Formatting & Country / Strategy Labels

func countryLabel(_ code: String?, l10n: AppL10n) -> String {
    guard let code, !code.isEmpty else { return "" }
    switch code.uppercased() {
    case "CN": return l10n.tr("中国大陆", "China")
    case "HK": return l10n.tr("中国香港", "Hong Kong")
    case "TW": return l10n.tr("中国台湾", "Taiwan")
    case "JP": return l10n.tr("日本", "Japan")
    case "KR": return l10n.tr("韩国", "South Korea")
    case "US": return l10n.tr("美国", "USA")
    case "GB": return l10n.tr("英国", "UK")
    case "FR": return l10n.tr("法国", "France")
    case "DE": return l10n.tr("德国", "Germany")
    case "TH": return l10n.tr("泰国", "Thailand")
    case "IN": return l10n.tr("印度", "India")
    default: return code
    }
}

func localizedStrategyInfo(_ strategy: SeasonStrategy, l10n: AppL10n) -> (title: String, caption: String) {
    switch strategy {
    case .asParsed:
        return (
            l10n.tr("按解析季集", "As Parsed"),
            l10n.tr("使用文件名或文件夹里解析出的季号和集号", "Use season and episode numbers parsed from filenames and folders")
        )
    case .splitSequential:
        return (
            l10n.tr("顺序拆多季", "Split Across Seasons"),
            l10n.tr("一季到底的绝对集号按 TMDB 每季集数拆开，每季从第 1 集开始（如龙珠Z）", "Split continuous numbering by TMDB season counts, starting at E01 each season (e.g. Dragon Ball Z)")
        )
    case .splitKeepEpisode:
        return (
            l10n.tr("跳序拆多季", "Split, Keep Numbers"),
            l10n.tr("按 TMDB 每季集数分配季号，保留原始集号不变（如海贼王）", "Assign TMDB season numbers while keeping original episode numbers (e.g. One Piece)")
        )
    case .mergeIntoOne:
        return (
            l10n.tr("合并成一季", "Merge into Season 1"),
            l10n.tr("多季合并为 S01，集号按季依次累加（如名侦探柯南）", "Combine all seasons into S01 with sequential episode numbers (e.g. Detective Conan)")
        )
    }
}

private enum AirDateCalendar {
    private static let utcGregorianCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    static func formatShortAirDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        let comps = utcGregorianCalendar.dateComponents([.year, .month, .day], from: date)
        guard let y = comps.year, let m = comps.month, let d = comps.day else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}

func formatShortAirDate(_ date: Date?) -> String? {
    AirDateCalendar.formatShortAirDate(date)
}

func unassignedReasonLabel(_ file: ScanFile, l10n: AppL10n) -> String {
    switch file.role {
    case .junk:
        return l10n.tr("广告或垃圾文件", "Ad or junk file")
    case .video:
        return l10n.tr("没识别出所属作品", "Could not identify title")
    case .subtitle, .sidecar:
        return l10n.tr("没找到对应的视频", "No matching video found")
    case .other:
        return l10n.tr("不认识的文件类型", "Unrecognized file type")
    }
}

// MARK: - Merge Folder Inspection Helpers

func episodesInFolder(backend: any StorageBackend, dir: String) async throws -> [Int: Set<Int>] {
    var out: [Int: Set<Int>] = [:]

    func scan(_ currentDir: String, deeper: Bool) async throws {
        let entries = try await backend.list(currentDir)
        for entry in entries {
            if entry.isDir {
                guard deeper else { continue }
                let nsRange = NSRange(entry.name.startIndex..<entry.name.endIndex, in: entry.name)
                if let m = ReviewRegex.seasonDir.firstMatch(in: entry.name, range: nsRange) {
                    let sNum: Int
                    if m.range(at: 1).location != NSNotFound,
                       let r = Range(m.range(at: 1), in: entry.name),
                       let parsed = Int(entry.name[r]) {
                        sNum = parsed
                    } else {
                        sNum = 0
                    }
                    if out[sNum] == nil { out[sNum] = [] }
                }
                try await scan(entry.path, deeper: false)
            } else {
                let nsRange = NSRange(entry.name.startIndex..<entry.name.endIndex, in: entry.name)
                for m in ReviewRegex.sxxeyy.matches(in: entry.name, range: nsRange) {
                    if let rS = Range(m.range(at: 1), in: entry.name),
                       let rE = Range(m.range(at: 2), in: entry.name),
                       let s = Int(entry.name[rS]),
                       let e = Int(entry.name[rE]) {
                        out[s, default: []].insert(e)
                    }
                }
            }
        }
    }

    try await scan(dir, deeper: true)
    return out
}

func plannedAddingEpisodes(for merge: PlanMerge, in plan: RenamePlan) -> [Int: Set<Int>] {
    var out: [Int: Set<Int>] = [:]
    for op in plan.ops where op.group == merge.group && op.kind == .relocate && op.phase == .files {
        let name = baseOf(op.dst)
        let nsRange = NSRange(name.startIndex..<name.endIndex, in: name)
        for m in ReviewRegex.sxxeyy.matches(in: name, range: nsRange) {
            if let rS = Range(m.range(at: 1), in: name),
               let rE = Range(m.range(at: 2), in: name),
               let s = Int(name[rS]),
               let e = Int(name[rE]) {
                out[s, default: []].insert(e)
            }
        }
    }
    if out.isEmpty {
        for s in merge.seasons {
            out[s] = []
        }
    }
    return out
}

func plannedAddingEpisodesByGroup(
    merges: [PlanMerge],
    in plan: RenamePlan
) -> [GroupId: [Int: Set<Int>]] {
    var out: [GroupId: [Int: Set<Int>]] = [:]
    out.reserveCapacity(merges.count)
    let mergeGroupIds = Set(merges.map(\.group))
    for op in plan.ops where op.kind == .relocate && op.phase == .files {
        guard let gid = op.group, mergeGroupIds.contains(gid) else { continue }
        let name = baseOf(op.dst)
        let nsRange = NSRange(name.startIndex..<name.endIndex, in: name)
        for m in ReviewRegex.sxxeyy.matches(in: name, range: nsRange) {
            if let rS = Range(m.range(at: 1), in: name),
               let rE = Range(m.range(at: 2), in: name),
               let s = Int(name[rS]),
               let e = Int(name[rE]) {
                out[gid, default: [:]][s, default: []].insert(e)
            }
        }
    }
    for merge in merges {
        if out[merge.group]?.isEmpty ?? true {
            var fallback: [Int: Set<Int>] = [:]
            for s in merge.seasons {
                fallback[s] = []
            }
            out[merge.group] = fallback
        }
    }
    return out
}

func describeEpisodeMap(_ bySeason: [Int: Set<Int>], l10n: AppL10n) -> String {
    if bySeason.isEmpty {
        return l10n.tr("（没有识别到剧集）", "(no episodes detected)")
    }
    var parts: [String] = []
    for s in bySeason.keys.sorted() {
        let eps = (bySeason[s] ?? []).sorted()
        var runs: [String] = []
        var i = 0
        while i < eps.count {
            var j = i
            while j + 1 < eps.count && eps[j + 1] == eps[j] + 1 {
                j += 1
            }
            if j == i {
                runs.append(String(format: "E%02d", eps[i]))
            } else {
                runs.append(String(format: "E%02d–E%02d", eps[i], eps[j]))
            }
            i = j + 1
        }
        let seasonName = (s == 0) ? "Specials" : String(format: "Season %02d", s)
        let sep = l10n.isEn ? ", " : "、"
        parts.append(runs.isEmpty ? seasonName : "\(seasonName) \(runs.joined(separator: sep))")
    }
    return parts.joined(separator: l10n.isEn ? "; " : "；")
}
