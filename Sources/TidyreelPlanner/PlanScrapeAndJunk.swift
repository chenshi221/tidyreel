import Foundation
import TidyreelModels

extension PlanBuilder {
    // MARK: - Precomputed Indices

    func buildStaticIndices() {
        if let dirs = existingDirsLower {
            knownDirs.formUnion(dirs)
        } else {
            for p in sortedExisting where !regexMatches(PlannerRegex.fileLike, baseOf(p)) {
                knownDirs.insert(p.lowercased())
            }
        }
        for r in scan.roots {
            knownDirs.insert(r.lowercased())
        }
        for g in scan.groups {
            for f in g.files {
                scanFilePathsLower.insert(f.path.lowercased())
                var d = dirOf(f.path)
                while d != "/" && knownDirs.insert(d.lowercased()).inserted {
                    d = dirOf(d)
                }
            }
        }
        for f in scan.unassigned {
            scanFilePathsLower.insert(f.path.lowercased())
            var d = dirOf(f.path)
            while d != "/" && knownDirs.insert(d.lowercased()).inserted {
                d = dirOf(d)
            }
        }

        // Precompute existing directory lookups preserving sortedExisting order.
        for p in sortedExisting where isExistingDir(p) {
            let pLower = p.lowercased()
            if existingDirByLower[pLower] == nil {
                existingDirByLower[pLower] = p
            }
            existingDirsByParentLower[dirOf(p).lowercased(), default: []].append(p)
        }

        // Precompute strict ancestor directory set of knownDirs for O(1) reuseSeasonFolders checks.
        for dir in knownDirs where dir != "/" {
            var parent = dirOf(dir)
            while parent != "/" && knownDirParentsLower.insert(parent).inserted {
                parent = dirOf(parent)
            }
        }

        // Precompute group ownership across rootDirs and file ancestor directories (-1 = shared).
        for (groupIdx, g) in scan.groups.enumerated() {
            if let existing = rootDirOwnerGroup[g.rootDir] {
                if existing != groupIdx {
                    rootDirOwnerGroup[g.rootDir] = -1
                }
            } else {
                rootDirOwnerGroup[g.rootDir] = groupIdx
            }

            for f in g.files {
                var d = dirOf(f.path)
                while d != "/" {
                    if let existing = fileOwnerGroupByDir[d] {
                        if existing == groupIdx || existing == -1 { break }
                        fileOwnerGroupByDir[d] = -1
                    } else {
                        fileOwnerGroupByDir[d] = groupIdx
                    }
                    d = dirOf(d)
                }
            }
        }

        for f in scan.unassigned where f.role != .junk {
            var d = dirOf(f.path)
            while d != "/" && nonJunkUnassignedAncestors.insert(d).inserted {
                d = dirOf(d)
            }
        }
    }

    func isExistingDir(_ path: String) -> Bool {
        let key = path.lowercased()
        if let dirs = existingDirsLower {
            return dirs.contains(key)
        }
        return existingLower.contains(key) && !regexMatches(PlannerRegex.fileLike, baseOf(path))
    }

    // MARK: - Scraping (.nfo & Artwork)

    private func rewriteByDstAncestors(
        _ path: String,
        using map: [String: (src: String, dst: String, order: Int)]
    ) -> String? {
        if map.isEmpty { return nil }
        let pathLower = path.lowercased()
        var best: (src: String, dst: String, order: Int)?
        var cur = pathLower
        while cur != "/" {
            if let entry = map[cur], best == nil || entry.order < best!.order {
                best = entry
            }
            cur = dirOf(cur)
        }
        guard let best else { return nil }
        if pathLower == best.dst.lowercased() {
            return best.src
        }
        return "\(best.src)\(path.dropFirst(best.dst.count))"
    }

    private func preRenamePath(_ dst: String) -> String? {
        let cur = rewriteByDstAncestors(dst, using: renamedRootByDstLower)
        let base = cur ?? dst
        if let seasonHit = rewriteByDstAncestors(base, using: renamedSeasonByDstLower) {
            return seasonHit
        }
        return cur
    }

    private func alreadyThere(_ dst: String) -> Bool {
        func has(_ path: String) -> Bool {
            let key = path.lowercased()
            return existingLower.contains(key)
                || (scanFilePathsLower.contains(key) && !movedSrcsLower.contains(key))
        }

        if has(dst) || plannedFinalDstsLower.contains(dst.lowercased()) {
            return true
        }
        if let pre = preRenamePath(dst), has(pre) {
            return true
        }
        return false
    }

    private func addWriteOp(dst: String, source: String, group: GroupId, selected: Bool) {
        let key = dst.lowercased()
        let there = alreadyThere(dst)
        let isNfo = key.hasSuffix(".nfo")
        let canOverwrite = there && isNfo && opts.overwriteNfo
        let effectiveSelected = selected && (!there || canOverwrite)

        if let existingIdx = scraped[key] {
            let prev = deleteOps[existingIdx]
            if !prev.selected && effectiveSelected {
                deleteOps[existingIdx] = RenameOp(
                    id: prev.id,
                    kind: prev.kind,
                    phase: prev.phase,
                    src: source,
                    dst: dst,
                    group: group,
                    selected: true,
                    warning: nil,
                    overwrite: isNfo && opts.overwriteNfo
                )
            }
            return
        }

        scraped[key] = deleteOps.count
        deleteOps.append(RenameOp(
            id: OpId("w-\(stableHash(dst))"),
            kind: .write,
            phase: .cleanup,
            src: source,
            dst: dst,
            group: group,
            selected: effectiveSelected,
            warning: (there && !canOverwrite) ? "已存在，保留原文件" : nil,
            overwrite: isNfo && opts.overwriteNfo
        ))
    }

    func scrapeGroup(
        _ g: MediaGroup,
        match: Candidate,
        show: ShowDetail?,
        epGroup: EpisodeGroup?,
        strategy: SeasonStrategy,
        tmdbCounts: [Int],
        titles: [EpisodeRef: String],
        items: [PlanItem],
        showDir: String,
        finalDir: (String) -> String
    ) async throws {
        if match.kind == .movie {
            let info = (await fetchMovie(match.tmdbId))?.info ?? match
            scrapeMovieGroupSync(g, match: match, info: info, items: items, finalDir: finalDir)
            return
        }

        let s: ShowDetail
        if let show {
            s = show
        } else {
            s = try await fetchShow(match.tmdbId)
        }

        let episodeItems = items.filter { !$0.extra && $0.ref != nil }
        let scrapePlan = seasonsNeededForRefs(
            episodeItems.compactMap(\.ref),
            strategy: strategy,
            tmdbCounts: tmdbCounts,
            epGroup: epGroup
        )
        if !allSeasonsCached(tmdbId: match.tmdbId, seasons: scrapePlan.seasons) {
            await ensureSeasonsCached(tmdbId: match.tmdbId, seasons: scrapePlan.seasons)
        }

        scrapeTvGroupSync(
            g,
            match: match,
            show: s,
            epGroup: epGroup,
            strategy: strategy,
            tmdbRefs: scrapePlan.mapped,
            seasons: scrapePlan.seasons,
            titles: titles,
            items: items,
            episodeItems: episodeItems,
            showDir: showDir,
            finalDir: finalDir
        )
    }

    private func emitArtwork(dir: String, candidate: Candidate, fallback: Candidate, groupId: GroupId, selected: Bool) {
        for (fileName, url) in artworkFiles(for: candidate, fallback: fallback) {
            addWriteOp(dst: "\(dir)/\(fileName)", source: url, group: groupId, selected: selected)
        }
    }

    private func scrapeMovieGroupSync(
        _ g: MediaGroup,
        match: Candidate,
        info: Candidate,
        items: [PlanItem],
        finalDir: (String) -> String
    ) {
        let on = items.contains(where: \.selected)
        let main = items.filter { !$0.extra }
        if main.isEmpty { return }
        let dir = finalDir(main[0].dstDir)
        for it in main {
            let nfoPath = it.file.isDiscDir
                ? "\(finalDir(it.dstDir))/movie.nfo"
                : "\(finalDir(it.dstDir))/\(stem(it.outName)).nfo"
            let xml = movieNfo(info, probe: it.file.parsed?.probe)
            addWriteOp(
                dst: nfoPath,
                source: "\(writeTextPrefix)\(xml)",
                group: g.id,
                selected: it.selected
            )
        }
        emitArtwork(dir: dir, candidate: info, fallback: match, groupId: g.id, selected: on)
    }

    private func scrapeTvGroupSync(
        _ g: MediaGroup,
        match: Candidate,
        show s: ShowDetail,
        epGroup: EpisodeGroup?,
        strategy: SeasonStrategy,
        tmdbRefs: [EpisodeRef: EpisodeRef],
        seasons: [Int],
        titles: [EpisodeRef: String],
        items: [PlanItem],
        episodeItems: [PlanItem],
        showDir: String,
        finalDir: (String) -> String
    ) {
        let on = items.contains(where: \.selected)
        addWriteOp(
            dst: "\(showDir)/tvshow.nfo",
            source: "\(writeTextPrefix)\(tvshowNfo(s))",
            group: g.id,
            selected: on
        )
        emitArtwork(dir: showDir, candidate: s.info, fallback: match, groupId: g.id, selected: on)

        let episodesBySeason = buildEpisodesBySeasonSync(tmdbId: match.tmdbId, seasons: seasons)

        var seasonOrder: [Int] = []
        var seenSeasons: Set<Int> = []
        for it in episodeItems {
            let r = it.ref!
            if seenSeasons.insert(r.season).inserted {
                seasonOrder.append(r.season)
            }
            let dir = finalDir(it.dstDir)
            let ep = lookupEpisode(
                bySeason: episodesBySeason,
                ref: r,
                orig: tmdbRefs[r],
                strategy: strategy,
                epGroup: epGroup
            )
            let base = stem(it.outName)
            let xml = episodedetailsNfo(
                show: s.info,
                season: r.season,
                episode: r.episode,
                info: ep,
                title: titles[r],
                probe: it.file.parsed?.probe
            )
            addWriteOp(
                dst: "\(dir)/\(base).nfo",
                source: "\(writeTextPrefix)\(xml)",
                group: g.id,
                selected: it.selected
            )
            if let still = ep?.stillPath, !still.isEmpty {
                addWriteOp(
                    dst: "\(dir)/\(base)-thumb.jpg",
                    source: tmdbImageUrl(path: still, size: "w780"),
                    group: g.id,
                    selected: it.selected
                )
            }
        }

        for n in seasonOrder {
            guard let poster = s.seasons.first(where: { $0.number == n })?.posterPath,
                  !poster.isEmpty else {
                continue
            }
            let fileName = seasonPosterFileName(season: n)
            addWriteOp(
                dst: "\(showDir)/\(fileName)",
                source: tmdbImageUrl(path: poster, size: "w780"),
                group: g.id,
                selected: on
            )
        }
    }

    // MARK: - Folders & Season Reuse

    func recordRenamedRoot(src: String, dst: String) {
        if renamedRoots[src] == nil {
            let order = nextRenamedRootOrder
            nextRenamedRootOrder += 1
            renamedRootBySrc[src] = (dst: dst, order: order)
            let dstLower = dst.lowercased()
            if renamedRootByDstLower[dstLower] == nil {
                renamedRootByDstLower[dstLower] = (src: src, dst: dst, order: order)
            }
        }
        renamedRoots[src] = dst
    }

    private func recordRenamedSeason(src: String, dst: String) {
        if renamedSeasons[src] == nil {
            let order = nextRenamedSeasonOrder
            nextRenamedSeasonOrder += 1
            renamedSeasonBySrc[src] = (dst: dst, order: order)
            renamedSeasonByDst[dst] = src
            let dstLower = dst.lowercased()
            if renamedSeasonByDstLower[dstLower] == nil {
                renamedSeasonByDstLower[dstLower] = (src: src, dst: dst, order: order)
            }
        }
        renamedSeasons[src] = dst
    }

    func onDiskShow(dir: String, folderName: String, match: Candidate) -> String? {
        let exact = joinPath(dir, folderName)
        let exactLower = exact.lowercased()
        if let hit = existingDirByLower[exactLower] {
            return hit
        }

        let dirLower = dir.lowercased()
        guard let siblings = existingDirsByParentLower[dirLower], !siblings.isEmpty else {
            return nil
        }

        var names: Set<String> = [normTitle(untagged(folderName))]
        if let y = match.year {
            for t in [match.title, match.englishTitle, match.originalTitle].compactMap({ $0 }) where !t.isEmpty {
                names.insert(normTitle("\(t) (\(y))"))
            }
        }

        let targetTmdbId = "\(match.tmdbId)"
        for p in siblings {
            if p.lowercased() == exactLower { continue }
            let name = baseOf(p)
            if matchesTmdbTagId(in: name, expectedId: targetTmdbId) {
                return p
            }
            let clean = untagged(name)
            if regexMatches(PlannerRegex.titleYear, clean) && names.contains(normTitle(clean)) {
                return p
            }
        }
        return nil
    }

    private func hasOtherGroupFileUnder(_ dir: String, excluding groupIndex: Int) -> Bool {
        guard let owner = fileOwnerGroupByDir[dir] else { return false }
        return owner != groupIndex
    }

    func reuseSeasonFolders(
        _ g: MediaGroup,
        groupIndex: Int,
        items: [PlanItem],
        curBase: String
    ) -> [String: String] {
        var localRenamed: [String: String] = [:]
        var seasonOrder: [String] = []
        var bySeason: [String: [PlanItem]] = [:]

        for it in items where !it.extra && it.dstDir != curBase {
            if bySeason[it.dstDir] == nil { seasonOrder.append(it.dstDir) }
            bySeason[it.dstDir, default: []].append(it)
        }
        if seasonOrder.isEmpty { return localRenamed }

        var groupVideoPathsByDir: [String: Set<String>] = [:]
        for f in g.files where f.role == .video {
            groupVideoPathsByDir[dirOf(f.path), default: []].insert(f.path)
        }

        var taken: Set<String> = []
        for season in seasonOrder {
            guard let its = bySeason[season] else { continue }
            let dirs = Set(its.map { dirOf($0.file.path) })
            guard dirs.count == 1, let src = dirs.first else { continue }
            let srcLower = src.lowercased()
            let seasonLower = season.lowercased()
            let itPaths = Set(its.map { $0.file.path })

            let ok = dirOf(src) == curBase
                && src.hasPrefix("\(g.rootDir)/")
                && src != season
                && !taken.contains(src)
                && !knownDirs.contains(seasonLower)
                && mkdirKeyToPath[seasonLower] == nil
                && !knownDirParentsLower.contains(srcLower)
                && (groupVideoPathsByDir[src]?.isSubset(of: itPaths) ?? true)
                && !nonJunkUnassignedAncestors.contains(src)
                && !hasOtherGroupFileUnder(src, excluding: groupIndex)

            guard ok else { continue }
            taken.insert(src)
            for it in its {
                it.dstDir = src
            }
            let seasonSelected = its.contains(where: \.selected)
            localRenamed[src] = season
            if seasonSelected {
                recordRenamedSeason(src: src, dst: season)
            }
            seasonOps.append(RenameOp(
                id: OpId("s-\(stableHash(src))"),
                kind: .relocate,
                phase: .folders,
                src: src,
                dst: season,
                group: g.id,
                selected: seasonSelected
            ))
        }
        return localRenamed
    }

    func ownsFolder(_ g: MediaGroup, groupIndex: Int, match: Candidate) -> Bool {
        if g.rootDir == "/" { return false }
        let sharedRoot = rootDirOwnerGroup[g.rootDir].map { $0 != groupIndex } ?? false
        if sharedRoot || hasOtherGroupFileUnder(g.rootDir, excluding: groupIndex) {
            return false
        }
        if nonJunkUnassignedAncestors.contains(g.rootDir) {
            return false
        }
        let baseName = baseOf(g.rootDir)
        if isGenericContainerDir(baseName) { return false }

        let hasParentSlash = g.rootDir.lastIndex(of: "/").map { $0 > g.rootDir.startIndex } ?? false
        let imported = hasParentSlash && scan.roots.contains { r in
            r == "/" || r == g.rootDir || g.rootDir.hasPrefix("\(r)/")
        }
        if imported { return true }

        let folder = normTitle(baseName)
        let candidateTitles = [g.anchorTitle, match.title, match.englishTitle, match.originalTitle]
            .compactMap { $0 }
            .map(normTitle)
        return candidateTitles.contains { !$0.isEmpty && folder.contains($0) }
    }

    // MARK: - Junk Deletion

    private func rewriteBySrcAncestors(
        _ path: String,
        using map: [String: (dst: String, order: Int)]
    ) -> String {
        if map.isEmpty { return path }
        var bestSrc: String?
        var bestEntry: (dst: String, order: Int)?
        var cur = dirOf(path)
        while cur != "/" {
            if let entry = map[cur], bestEntry == nil || entry.order < bestEntry!.order {
                bestSrc = cur
                bestEntry = entry
            }
            cur = dirOf(cur)
        }
        guard let bestSrc, let bestEntry else { return path }
        return "\(bestEntry.dst)\(path.dropFirst(bestSrc.count))"
    }

    func planJunk(processed: [MediaGroup], skipped: [MediaGroup]) {
        let skippedRoots = Set(skipped.map(\.rootDir).filter { $0 != "/" })
        let processedRoots = Set(processed.map(\.rootDir).filter { $0 != "/" })

        func under(_ path: String, roots: Set<String>) -> Bool {
            if roots.isEmpty { return false }
            var cur = dirOf(path)
            while cur != "/" {
                if roots.contains(cur) { return true }
                cur = dirOf(cur)
            }
            return false
        }

        for f in scan.unassigned {
            let override = opts.unassignedDeletes[f.path]
            if override == nil || override == false {
                if f.role != .junk { continue }
                if under(f.path, roots: skippedRoots) && !under(f.path, roots: processedRoots) { continue }
            }

            var path = f.path
            path = rewriteBySrcAncestors(path, using: renamedSeasonBySrc)
            path = rewriteBySrcAncestors(path, using: renamedRootBySrc)

            deleteOps.append(RenameOp(
                id: OpId("d-\(stableHash(f.path))"),
                kind: .delete,
                phase: .cleanup,
                src: path,
                dst: "",
                selected: override ?? opts.deleteJunk
            ))
        }
    }

    // MARK: - Episode & Season Lookup Helpers

    func buildEpisodesByDateSync(tmdbId: Int, show: ShowDetail) -> [AirDayKey: EpisodeRef] {
        let regular = show.seasons.filter { $0.number > 0 }.map(\.number)
        var out: [AirDayKey: EpisodeRef] = [:]
        for s in regular {
            for e in seasonCache[SeasonKey(tmdbId: tmdbId, season: s)] ?? [] {
                guard let day = AirDayKey(utcDate: e.airDate) else { continue }
                if out[day] == nil {
                    out[day] = EpisodeRef(s, e.number)
                }
            }
        }
        return out
    }

    private func resolveTmdbRef(
        _ r: EpisodeRef,
        strategy: SeasonStrategy,
        tmdbCounts: [Int],
        epGroup: EpisodeGroup?
    ) -> EpisodeRef? {
        if let epGroup {
            if strategy == .mergeIntoOne && r.season == 1 {
                let regular = epGroup.seasons.filter { $0.order > 0 }.sorted { $0.order < $1.order }
                var rem = r.episode
                for s in regular {
                    if rem <= s.episodes.count {
                        return rem >= 1 ? s.episodes[rem - 1] : nil
                    }
                    rem -= s.episodes.count
                }
                return nil
            }
            guard let s = epGroup.seasons.first(where: { $0.order == r.season }) else { return nil }
            var idx = r.episode - 1
            if strategy == .splitKeepEpisode && r.season > 0 {
                for prev in epGroup.seasons where prev.order > 0 && prev.order < r.season {
                    idx -= prev.episodes.count
                }
            }
            guard idx >= 0, idx < s.episodes.count else { return nil }
            return s.episodes[idx]
        }

        if strategy == .mergeIntoOne && r.season == 1 && !tmdbCounts.isEmpty {
            var rem = r.episode
            if rem < 1 { return nil }
            for s in 1...tmdbCounts.count {
                let c = tmdbCounts[s - 1]
                if rem <= c { return EpisodeRef(s, rem) }
                rem -= c
            }
            return nil
        }

        if strategy == .splitKeepEpisode && r.season > 1 && r.season <= tmdbCounts.count {
            var prev = 0
            for i in 0..<(r.season - 1) {
                prev += tmdbCounts[i]
            }
            let rel = r.episode - prev
            if rel >= 1 && rel <= tmdbCounts[r.season - 1] {
                return EpisodeRef(r.season, rel)
            }
        }
        return r
    }

    private func lookupEpisode(
        bySeason: [Int: [Int: Episode]],
        ref r: EpisodeRef,
        orig: EpisodeRef?,
        strategy: SeasonStrategy,
        epGroup: EpisodeGroup?
    ) -> Episode? {
        if epGroup == nil && strategy == .splitKeepEpisode {
            if let seasonMap = bySeason[r.season],
               seasonMap[1] == nil,
               let contEp = seasonMap[r.episode] {
                return contEp
            }
        }
        guard let orig else { return nil }
        return bySeason[orig.season]?[orig.episode]
    }

    func seasonsNeededForRefs(
        _ refs: [EpisodeRef],
        strategy: SeasonStrategy,
        tmdbCounts: [Int],
        epGroup: EpisodeGroup?
    ) -> (uniqueRefs: [EpisodeRef], mapped: [EpisodeRef: EpisodeRef], seasons: [Int]) {
        var unique: [EpisodeRef] = []
        var seenRefs: Set<EpisodeRef> = []
        for r in refs where seenRefs.insert(r).inserted {
            unique.append(r)
        }

        var mapped: [EpisodeRef: EpisodeRef] = [:]
        var seasons: [Int] = []
        var seenSeasons: Set<Int> = []
        for r in unique {
            if let orig = resolveTmdbRef(r, strategy: strategy, tmdbCounts: tmdbCounts, epGroup: epGroup) {
                mapped[r] = orig
                if seenSeasons.insert(orig.season).inserted {
                    seasons.append(orig.season)
                }
            }
            if epGroup == nil && strategy == .splitKeepEpisode {
                if seenSeasons.insert(r.season).inserted {
                    seasons.append(r.season)
                }
            }
        }
        return (uniqueRefs: unique, mapped: mapped, seasons: seasons)
    }

    private func buildEpisodesBySeasonSync(tmdbId: Int, seasons: [Int]) -> [Int: [Int: Episode]] {
        var bySeason: [Int: [Int: Episode]] = [:]
        for sNum in seasons {
            let epList = seasonCache[SeasonKey(tmdbId: tmdbId, season: sNum)] ?? []
            var map: [Int: Episode] = [:]
            map.reserveCapacity(epList.count)
            for ep in epList { map[ep.number] = ep }
            bySeason[sNum] = map
        }
        return bySeason
    }

    func buildEpisodeTitlesSync(
        tmdbId: Int,
        uniqueRefs: [EpisodeRef],
        mapped: [EpisodeRef: EpisodeRef],
        seasons: [Int],
        strategy: SeasonStrategy,
        epGroup: EpisodeGroup?
    ) -> [EpisodeRef: String] {
        let bySeason = buildEpisodesBySeasonSync(tmdbId: tmdbId, seasons: seasons)
        var out: [EpisodeRef: String] = [:]
        for r in uniqueRefs {
            if let t = lookupEpisode(
                bySeason: bySeason,
                ref: r,
                orig: mapped[r],
                strategy: strategy,
                epGroup: epGroup
            )?.title, !t.isEmpty {
                out[r] = t
            }
        }
        return out
    }
}

// MARK: - Private Regex & String Utilities

private func untagged(_ name: String) -> String {
    guard !name.isEmpty else { return name }
    let range = NSRange(name.startIndex..<name.endIndex, in: name)
    return PlannerRegex.idTag.stringByReplacingMatches(in: name, range: range, withTemplate: "")
}

private func matchesTmdbTagId(in name: String, expectedId: String) -> Bool {
    guard !name.isEmpty else { return false }
    let full = NSRange(name.startIndex..<name.endIndex, in: name)
    for m in PlannerRegex.tmdbFolderTag.matches(in: name, range: full) {
        if let r = Range(m.range(at: 1), in: name), String(name[r]) == expectedId {
            return true
        }
    }
    return false
}

private func regexMatches(_ regex: NSRegularExpression, _ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.firstMatch(in: text, range: range) != nil
}
