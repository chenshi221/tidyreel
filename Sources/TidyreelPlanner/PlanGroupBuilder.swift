import Foundation
import TidyreelModels

private struct PrecomputedSubMeta {
    let lang: String?
    let hasBilingual: Bool
    let stdFlags: [String]
    let baseKey: String
}

extension PlanBuilder {
    private static let orderedSubFlags = ["forced", "default", "sdh"]

    // MARK: - Group Planning Orchestrator (Thin Async Shell)

    func planGroup(
        _ g: MediaGroup,
        groupIndex: Int,
        decision d: GroupDecision,
        match: Candidate
    ) async throws {
        let isTv = (match.kind == .episode)
        let naming = isTv ? opts.naming.tv : opts.naming.movie
        let template = compileTemplate(naming, isMovie: !isTv)
        let lowMatch = (d.match == nil && g.matchScore < opts.confidenceThreshold)

        var show: ShowDetail?
        var epGroup: EpisodeGroup?
        var tmdbCounts: [Int] = []
        if isTv {
            if let existingShow = g.show, g.match?.tmdbId == match.tmdbId {
                show = existingShow
            } else {
                show = try await fetchShow(match.tmdbId)
            }
            if let egId = d.episodeGroupId {
                let groups = try await fetchEpisodeGroups(match.tmdbId)
                epGroup = groups.first { $0.id == egId }
            }
            tmdbCounts = seasonEpisodeCounts(show: show, episodeGroup: epGroup)
        }

        let items: [PlanItem]
        let companions: [PlanCompanion]
        if let cachedResolved = prefetchedResolved.removeValue(forKey: groupIndex) {
            items = cachedResolved.items
            companions = cachedResolved.companions
        } else {
            let allVideos = g.files.filter { $0.role == .video }
            let videos = allVideos.filter { !(d.overrides[$0.path]?.ignore ?? false) }
            let byDate: [AirDayKey: EpisodeRef]
            if isTv, let show, videos.contains(where: { $0.parsed?.airDate != nil }) {
                let regular = show.seasons.filter { $0.number > 0 }.map(\.number)
                if !allSeasonsCached(tmdbId: match.tmdbId, seasons: regular) {
                    await ensureSeasonsCached(tmdbId: match.tmdbId, seasons: regular)
                }
                byDate = buildEpisodesByDateSync(tmdbId: match.tmdbId, show: show)
            } else {
                byDate = [:]
            }
            items = resolveVideoItems(
                videos: videos,
                decision: d,
                isTv: isTv,
                lowMatch: lowMatch,
                tmdbCounts: tmdbCounts,
                epGroup: epGroup,
                byDate: byDate
            )
            companions = resolveCompanions(
                group: g,
                decision: d,
                isTv: isTv,
                lowMatch: lowMatch,
                tmdbCounts: tmdbCounts,
                allVideos: allVideos,
                items: items
            )
        }

        let wantScrape = opts.scrape || opts.scrapeOnly
        let wantTitles = isTv && (
            naming.episodeTitle
            || (naming.customTemplate?.contains("episode_title") ?? false)
            || (wantScrape && epGroup != nil)
        )
        let titles: [EpisodeRef: String]
        if wantTitles {
            let targetRefs = items.compactMap(\.ref) + companions.compactMap(\.ref)
            let titlePlan = seasonsNeededForRefs(
                targetRefs,
                strategy: d.strategy,
                tmdbCounts: tmdbCounts,
                epGroup: epGroup
            )
            if !allSeasonsCached(tmdbId: match.tmdbId, seasons: titlePlan.seasons) {
                await ensureSeasonsCached(tmdbId: match.tmdbId, seasons: titlePlan.seasons)
            }
            titles = buildEpisodeTitlesSync(
                tmdbId: match.tmdbId,
                uniqueRefs: titlePlan.uniqueRefs,
                mapped: titlePlan.mapped,
                seasons: titlePlan.seasons,
                strategy: d.strategy,
                epGroup: epGroup
            )
        } else {
            titles = [:]
        }

        // Scrape-only mode: write .nfo and artwork beside existing files; zero moves/mkdirs/deletes.
        if opts.scrapeOnly {
            prepareScrapeOnlyItems(items)
            try await scrapeGroup(
                g,
                match: match,
                show: show,
                epGroup: epGroup,
                strategy: d.strategy,
                tmdbCounts: tmdbCounts,
                titles: titles,
                items: items,
                showDir: g.rootDir,
                finalDir: { $0 }
            )
            return
        }

        var movieInfo: Candidate?
        if !isTv && !hasHan(match.title) {
            movieInfo = (await fetchMovie(match.tmdbId))?.info
        }

        let outcome = try planGroupOpsSync(
            group: g,
            groupIndex: groupIndex,
            decision: d,
            match: match,
            show: show,
            movieInfo: movieInfo,
            naming: naming,
            template: template,
            isTv: isTv,
            tmdbCounts: tmdbCounts,
            titles: titles,
            items: items,
            companions: companions
        )

        if wantScrape {
            let showDir = outcome.showDir
            let curBase = outcome.curBase
            let hasRegularWork = outcome.hasRegularWork
            let groupRenamedSeasons = outcome.groupRenamedSeasons

            func finalDir(_ dir: String) -> String {
                if !hasRegularWork { return dir }
                let resolved = groupRenamedSeasons[dir] ?? renamedSeasons[dir] ?? dir
                if resolved == curBase { return showDir }
                if resolved.hasPrefix("\(curBase)/") {
                    return "\(showDir)\(resolved.dropFirst(curBase.count))"
                }
                return resolved
            }

            recordPlannedFinalDsts(from: outcome.groupFileOpsStart, finalDir: finalDir)
            try await scrapeGroup(
                g,
                match: match,
                show: show,
                epGroup: epGroup,
                strategy: d.strategy,
                tmdbCounts: tmdbCounts,
                titles: titles,
                items: items,
                showDir: showDir,
                finalDir: finalDir
            )
        }
    }

    // MARK: - Synchronous Planning Helpers

    func resolveVideoItems(
        videos: [ScanFile],
        decision d: GroupDecision,
        isTv: Bool,
        lowMatch: Bool,
        tmdbCounts: [Int],
        epGroup: EpisodeGroup?,
        byDate: [AirDayKey: EpisodeRef]
    ) -> [PlanItem] {
        let bare = videos.compactMap { v -> Int? in
            guard let p = v.parsed, p.episodes.isEmpty, let absEp = p.absolute else { return nil }
            return absEp
        }
        let bareRun = isTv && bare.count >= 2 && Set(bare).count == bare.count

        var items: [PlanItem] = []
        var pending: [PlanItem] = []
        var inputs: [EpisodeRef] = []
        let isSplit = (d.strategy == .splitSequential || d.strategy == .splitKeepEpisode)

        for v in videos {
            let ov = d.overrides[v.path]
            let p = v.parsed
            let kind = ov?.kind ?? p?.kind ?? .unknown
            let it = PlanItem(v)
            let lowParse = d.match == nil
                && (p == nil || p!.confidence < opts.confidenceThreshold)
                && !(bareRun && p != nil && p!.episodes.isEmpty && p!.absolute != nil)

            if kind == .extra {
                it.extra = true
                items.append(it)
                continue
            }
            if !isTv || v.isDiscDir {
                items.append(it)
                if lowParse { it.warnings.append("识别置信度较低") }
                continue
            }

            let n = p?.episodes.first ?? p?.absolute
            let isSpecial = (kind == .special || p?.season == 0)
            if ov?.season != nil || ov?.episode != nil {
                guard let ep = ov?.episode ?? n else { continue }
                it.ref = EpisodeRef(ov?.season ?? (isSpecial ? 0 : (p?.season ?? 1)), ep)
                it.manual = true
            } else if n == nil, let day = AirDayKey(utcDate: p?.airDate), let airRef = byDate[day] {
                it.ref = airRef
            } else if n == nil {
                continue
            } else if isSpecial {
                it.ref = EpisodeRef(0, n!)
            } else {
                inputs.append(isSplit ? EpisodeRef(1, n!) : EpisodeRef(p?.season ?? 1, n!))
                pending.append(it)
            }

            if lowParse && !it.manual {
                it.warnings.append("识别置信度较低")
            }
            items.append(it)
        }

        if isTv {
            var counts = tmdbCounts
            if counts.isEmpty && d.strategy == .mergeIntoOne {
                var localMax: [Int: Int] = [:]
                for i in 0..<pending.count {
                    let s = inputs[i].season
                    let ep = inputs[i].episode
                    localMax[s] = max(localMax[s] ?? 0, ep)
                }
                counts = denseSeasonCounts(localMax)
            }

            var refs = applyStrategy(
                d.strategy,
                inputs,
                counts,
                episodeOffset: d.episodeOffset
            )
            if let epGroup, d.strategy == .asParsed {
                refs = remapEpisodeGroupAsParsed(refs, episodeGroup: epGroup)
            }
            for i in 0..<pending.count {
                pending[i].ref = refs[i]
            }

            for it in items {
                guard !it.extra, let r = it.ref else { continue }
                if r.season < 0 { it.warnings.append("季号无效") }
                if r.episode < 1 {
                    it.warnings.append("集号无效")
                } else if r.season >= 0 && isEpisodeOverflow(
                    strategy: d.strategy,
                    ref: r,
                    seasonEpisodeCounts: tmdbCounts
                ) {
                    it.warnings.append(episodeOverflowWarning)
                }
            }
        }

        for it in items {
            let confirmed = d.overrides[it.file.path] != nil
            it.selected = (!lowMatch || confirmed) && it.warnings.allSatisfy { w in
                w == episodeOverflowWarning || (confirmed && w == "识别置信度较低")
            }
            if lowMatch {
                it.warnings.append("片名匹配置信度较低")
            }
        }

        return items
    }

    func resolveCompanions(
        group g: MediaGroup,
        decision d: GroupDecision,
        isTv: Bool,
        lowMatch: Bool,
        tmdbCounts: [Int],
        allVideos: [ScanFile],
        items: [PlanItem]
    ) -> [PlanCompanion] {
        var byPath: [String: PlanItem] = [:]
        byPath.reserveCapacity(items.count)
        for it in items { byPath[it.file.path] = it }
        let itemFiles = items.map(\.file)
        let itemIndex = VideoMatchIndex(itemFiles)
        let allVideoIndex = VideoMatchIndex(allVideos)
        var companions: [PlanCompanion] = []
        var nextCompanionId = 0

        for f in g.files where f.role == .subtitle || f.role == .sidecar {
            let ov = d.overrides[f.path]
            if ov?.ignore == true { continue }
            let hasExplicit = ov != nil && (
                ov!.season != nil
                || ov!.episode != nil
                || ov!.kind == .extra
                || ov!.kind == .special
            )

            var mItem = itemIndex.match(f)
            if mItem == nil
                && itemFiles.count == 1
                && f.role == .subtitle
                && !followConflicts(f, itemFiles[0]) {
                mItem = FollowMatch(
                    itemFiles[0],
                    extractSubRemainder(stem(f.name), stem(itemFiles[0].name))
                )
            }

            var mAll = mItem ?? allVideoIndex.match(f)
            if mAll == nil
                && allVideos.count == 1
                && f.role == .subtitle
                && !followConflicts(f, allVideos[0]) {
                mAll = FollowMatch(
                    allVideos[0],
                    extractSubRemainder(stem(f.name), stem(allVideos[0].name))
                )
            }

            let followedItem = mItem.flatMap { byPath[$0.video.path] }
            if !hasExplicit, let it = followedItem, let mItem {
                let c = PlanCompanion(
                    id: nextCompanionId,
                    file: f,
                    override: ov,
                    followed: it,
                    remainder: mItem.remainder
                )
                nextCompanionId += 1
                c.selected = it.selected || (
                    ov != nil && it.warnings.allSatisfy { w in
                        w == episodeOverflowWarning || w == "识别置信度较低" || w == "片名匹配置信度较低"
                    }
                )
                companions.append(c)
                continue
            }

            guard hasExplicit || ov != nil, let ov else { continue }
            let c = PlanCompanion(
                id: nextCompanionId,
                file: f,
                override: ov,
                followed: nil,
                remainder: mAll?.remainder ?? "",
                fallbackVideo: mAll?.video
            )
            nextCompanionId += 1

            let kind = ov.kind ?? (mAll?.video.parsed?.kind == .extra ? .extra : .unknown)
            if kind == .extra {
                c.extra = true
                c.selected = true
                companions.append(c)
                continue
            }
            if !isTv {
                c.selected = true
                if lowMatch { c.warnings.append("片名匹配置信度较低") }
                companions.append(c)
                continue
            }

            let pf = f.parsed
            let pv = mAll?.video.parsed
            let n = pf?.episodes.first ?? pf?.absolute ?? pv?.episodes.first ?? pv?.absolute
            guard let ep = ov.episode ?? n else { continue }
            let isSpecial = kind == .special
                || ov.season == 0
                || (ov.season == nil && pf?.season == 0)
            let season = ov.season ?? (isSpecial ? 0 : (pf?.season ?? pv?.season ?? 1))
            let r = EpisodeRef(season, ep)
            c.ref = r
            if r.season < 0 { c.warnings.append("季号无效") }
            if r.episode < 1 {
                c.warnings.append("集号无效")
            } else if r.season >= 0 && isEpisodeOverflow(
                strategy: d.strategy,
                ref: r,
                seasonEpisodeCounts: tmdbCounts
            ) {
                c.warnings.append(episodeOverflowWarning)
            }
            c.selected = c.warnings.allSatisfy { w in
                w == episodeOverflowWarning || w == "识别置信度较低"
            }
            if lowMatch { c.warnings.append("片名匹配置信度较低") }
            companions.append(c)
        }

        return companions
    }

    private func prepareScrapeOnlyItems(_ items: [PlanItem]) {
        for it in items {
            if it.file.isDiscDir {
                it.dstDir = it.file.path
                it.outName = "movie"
            } else {
                it.dstDir = dirOf(it.file.path)
                it.outName = it.file.name
            }
        }
    }

    private func computeFolderName(
        group g: MediaGroup,
        match: Candidate,
        naming: NamingOptions,
        titleVars: [String: String]
    ) -> String {
        var folderVars = titleVars
        if naming.titleLanguage == .englishFirst, let en = titleVars["en_title"] {
            folderVars["title"] = en
        }
        if let y = match.year {
            folderVars["year"] = "\(y)"
        }
        let rawFolderName = sanitizeName(
            applyRewrites(renderTemplate(naming.folderTemplate, vars: folderVars), rewrites: naming.rewrites)
        )
        if !rawFolderName.isEmpty {
            return rawFolderName
        }
        let fallbackSource = !match.title.isEmpty
            ? match.title
            : (!g.anchorTitle.isEmpty ? g.anchorTitle : baseOf(g.rootDir))
        let fallback = sanitizeName(fallbackSource)
        return fallback.isEmpty ? "tmdb-\(match.tmdbId)" : fallback
    }

    private func planDiscUnits(
        group g: MediaGroup,
        discItems: [PlanItem],
        isTv: Bool,
        folderName: String
    ) throws {
        var libTypeBase: String?
        if opts.mode == .moveToLibrary {
            guard let lib = opts.libraryRoot else {
                throw PlannerError.missingLibraryRoot
            }
            let typeDir = sanitizeName(isTv ? opts.naming.tvDir : opts.naming.movieDir)
            var base = (lib == "/") ? "" : regexReplaceFirst(PlannerRegex.trailingSlashes, in: lib, with: "")
            if !typeDir.isEmpty {
                base = "\(base)/\(typeDir)"
                addMkdir(base, group: g.id, selected: discItems.contains(where: \.selected))
            }
            libTypeBase = base.isEmpty ? "/" : base
        }
        for it in discItems {
            it.dstDir = (opts.mode == .inPlace) ? dirOf(it.file.path) : libTypeBase!
            it.newBase = folderName
        }
        disambiguateVersions(discItems, isDisc: true)
        for it in discItems {
            if let part = it.file.parsed?.partLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
               !part.isEmpty {
                let cleanPart = sanitizeName(part)
                if !cleanPart.isEmpty {
                    it.newBase = "\(it.newBase)-\(cleanPart)"
                }
            }
            let discDst = joinPath(it.dstDir, it.newBase)
            if it.selected && it.file.path != discDst {
                recordRenamedRoot(src: it.file.path, dst: discDst)
                movedSrcsLower.insert(it.file.path.lowercased())
            }
            folderOps.append(RenameOp(
                id: OpId("f-\(stableHash(it.file.path))"),
                kind: .relocate,
                phase: .folders,
                src: it.file.path,
                dst: discDst,
                group: g.id,
                selected: it.selected,
                warning: it.warnings.isEmpty ? nil : it.warnings.joined(separator: "；")
            ))
            it.dstDir = discDst
            it.outName = "movie"
        }
    }

    private func planRegularFolders(
        group g: MediaGroup,
        groupIndex: Int,
        decision d: GroupDecision,
        match: Candidate,
        isTv: Bool,
        folderName: String,
        groupSelected: Bool,
        plannedRefs: [EpisodeRef],
        discItems: [PlanItem],
        initialCurBase: String
    ) throws -> (curBase: String, groupShowDir: String) {
        var curBase = initialCurBase
        var mergeInto: String?
        var groupShowDir = curBase

        let discOwnsRoot = discItems.contains { $0.file.path.lowercased() == g.rootDir.lowercased() }
        if opts.mode == .inPlace {
            if !discOwnsRoot && ownsFolder(g, groupIndex: groupIndex, match: match) {
                curBase = g.rootDir
                let there = onDiskShow(dir: dirOf(g.rootDir), folderName: folderName, match: match)
                let finalBase = (there != nil && there!.lowercased() != g.rootDir.lowercased())
                    ? there!
                    : joinPath(dirOf(g.rootDir), folderName)
                let finalKey = finalBase.lowercased()
                let claimed = showFolders[finalKey]
                let onDisk = (finalKey != g.rootDir.lowercased()) && isExistingDir(finalBase)

                if (claimed != nil || onDisk) && !d.separate {
                    curBase = claimed?.base ?? finalBase
                    mergeInto = finalBase
                    groupShowDir = finalBase
                    noteMerge(g, into: finalBase, withGroup: claimed?.group, exists: onDisk, refs: plannedRefs)
                } else if claimed != nil || onDisk {
                    groupShowDir = curBase
                } else {
                    groupShowDir = finalBase
                    if groupSelected {
                        showFolders[finalKey] = (group: g.id, base: g.rootDir)
                    }
                    if finalBase != g.rootDir {
                        if groupSelected {
                            recordRenamedRoot(src: g.rootDir, dst: finalBase)
                        }
                        folderOps.append(RenameOp(
                            id: OpId("f-\(stableHash(g.rootDir))"),
                            kind: .relocate,
                            phase: .folders,
                            src: g.rootDir,
                            dst: finalBase,
                            group: g.id,
                            selected: groupSelected
                        ))
                    }
                }
            } else {
                let targetDir = onDiskShow(dir: g.rootDir, folderName: folderName, match: match)
                    ?? joinPath(g.rootDir, folderName)
                let targetKey = targetDir.lowercased()
                let claimed = showFolders[targetKey]
                let onDisk = isExistingDir(targetDir)

                if (claimed != nil || onDisk) && d.separate {
                    var n = 2
                    while true {
                        let candKey = joinPath(g.rootDir, "\(folderName) (\(n))").lowercased()
                        if showFolders[candKey] == nil && !existingLower.contains(candKey) {
                            break
                        }
                        n += 1
                    }
                    curBase = joinPath(g.rootDir, "\(folderName) (\(n))")
                    groupShowDir = curBase
                } else if claimed != nil || onDisk {
                    curBase = claimed?.base ?? targetDir
                    mergeInto = targetDir
                    groupShowDir = targetDir
                    noteMerge(g, into: targetDir, withGroup: claimed?.group, exists: onDisk, refs: plannedRefs)
                } else {
                    curBase = targetDir
                    groupShowDir = curBase
                }
                if groupSelected {
                    let claimKey = (mergeInto ?? curBase).lowercased()
                    if showFolders[claimKey] == nil {
                        showFolders[claimKey] = (group: g.id, base: curBase)
                    }
                }
                addMkdir(curBase, group: g.id, selected: groupSelected)
            }
        } else {
            guard let lib = opts.libraryRoot else {
                throw PlannerError.missingLibraryRoot
            }
            let typeDir = sanitizeName(isTv ? opts.naming.tvDir : opts.naming.movieDir)
            var base = (lib == "/") ? "" : regexReplaceFirst(PlannerRegex.trailingSlashes, in: lib, with: "")
            if !typeDir.isEmpty {
                base = "\(base)/\(typeDir)"
                addMkdir(base, group: g.id, selected: groupSelected)
            }
            curBase = onDiskShow(dir: base.isEmpty ? "/" : base, folderName: folderName, match: match)
                ?? "\(base)/\(folderName)"
            let curKey = curBase.lowercased()
            let claimed = showFolders[curKey]
            let onDisk = isExistingDir(curBase)

            if (claimed != nil || onDisk) && d.separate {
                var n = 2
                while true {
                    let candKey = "\(base)/\(folderName) (\(n))".lowercased()
                    if showFolders[candKey] == nil && !existingLower.contains(candKey) {
                        break
                    }
                    n += 1
                }
                curBase = "\(base)/\(folderName) (\(n))"
            } else if claimed != nil || onDisk {
                mergeInto = curBase
                noteMerge(g, into: curBase, withGroup: claimed?.group, exists: onDisk, refs: plannedRefs)
            }
            groupShowDir = mergeInto ?? curBase
            if groupSelected {
                let claimKey = curBase.lowercased()
                if showFolders[claimKey] == nil {
                    showFolders[claimKey] = (group: g.id, base: curBase)
                }
            }
            addMkdir(curBase, group: g.id, selected: groupSelected)
        }
        if let mergeInto, curBase != mergeInto {
            addMkdir(curBase, group: g.id, selected: groupSelected)
        }
        return (curBase: curBase, groupShowDir: groupShowDir)
    }

    private func emitFileOps(
        group g: MediaGroup,
        groupIndex: Int,
        match: Candidate,
        show: ShowDetail?,
        naming: NamingOptions,
        template: String,
        isTv: Bool,
        titleVars: [String: String],
        folderName: String,
        tmdbCounts: [Int],
        titles: [EpisodeRef: String],
        regularItems: [PlanItem],
        companions: [PlanCompanion],
        plannedRefs: [EpisodeRef],
        curBase: String
    ) -> (groupRenamedSeasons: [String: String], groupFileOpsStart: Int) {
        let flat = isTv
            && !naming.singleSeasonFolder
            && tmdbCounts.filter({ $0 > 0 }).count <= 1
            && plannedRefs.allSatisfy({ $0.season == 1 })

        var seasonAirYears: [Int: Int] = [:]
        if isTv && naming.showYear == .seasonAir, let show {
            var seenSeasonNums: Set<Int> = []
            for s in show.seasons where seenSeasonNums.insert(s.number).inserted {
                if let y = AirDayKey(utcDate: s.airDate)?.year {
                    seasonAirYears[s.number] = y
                }
            }
        }

        var seasonDirCache: [Int: String] = [:]
        func renderedSeasonDstDir(_ season: Int) -> String {
            if flat { return curBase }
            if let cached = seasonDirCache[season] { return cached }
            let rawSeasonDir = sanitizeName(
                applyRewrites(
                    renderTemplate(naming.seasonFolderTemplate, vars: ["season": "\(season)"]),
                    rewrites: naming.rewrites
                )
            )
            let seasonDir = !rawSeasonDir.isEmpty
                ? rawSeasonDir
                : String(format: "Season %02d", season)
            let full = joinPath(curBase, seasonDir)
            seasonDirCache[season] = full
            return full
        }

        func renderName(
            file: ScanFile,
            ref: EpisodeRef?,
            manual: Bool,
            metaSource: ScanFile? = nil
        ) -> (dstDir: String, newBase: String) {
            let srcFile = metaSource ?? file
            let p = srcFile.parsed
            let ext = extOf(file.name)
            let extraInfo = formatExtraInfo(p?.extraInfo, separator: naming.separator)

            var vars = titleVars
            if let y = match.year { vars["year"] = "\(y)" }
            if let res = p?.resolution { vars["resolution"] = res }
            if let grp = p?.group { vars["group"] = grp }
            if let extraInfo {
                vars["extra_info"] = extraInfo
                vars["version"] = extraInfo
            }
            if let lang = parsedLang(srcFile) { vars["lang"] = lang }
            if !ext.isEmpty { vars["ext"] = ext }

            let dstDir: String
            if isTv {
                let r = ref!
                let span = (!manual && p != nil && p!.episodes.count > 1 && p!.episodes.last! > p!.episodes.first!)
                    ? (p!.episodes.last! - p!.episodes.first!)
                    : 0
                vars["season"] = "\(r.season)"
                vars["episode"] = "\(r.episode)"
                if span > 0 { vars["episode_end"] = "\(r.episode + span)" }
                if let epTitle = titles[r] { vars["episode_title"] = epTitle }
                if naming.showYear == .seasonAir {
                    if let y = seasonAirYears[r.season] ?? match.year {
                        vars["year"] = "\(y)"
                    }
                }
                dstDir = renderedSeasonDstDir(r.season)
            } else {
                dstDir = curBase
            }

            let rawNewBase = sanitizeName(
                applyRewrites(renderTemplate(template, vars: vars), rewrites: naming.rewrites)
            )
            let newBase: String
            if !rawNewBase.isEmpty {
                newBase = rawNewBase
            } else {
                let fallback = sanitizeName(stem(file.name))
                if !fallback.isEmpty {
                    newBase = fallback
                } else if isTv, let r = ref {
                    newBase = String(format: "S%02dE%02d", r.season, r.episode)
                } else {
                    newBase = folderName
                }
            }
            return (dstDir: dstDir, newBase: newBase)
        }

        for it in regularItems {
            if it.extra {
                it.dstDir = joinPath(curBase, "Extras")
                it.newBase = stem(it.file.name)
                continue
            }
            let rendered = renderName(file: it.file, ref: it.ref, manual: it.manual)
            it.dstDir = rendered.dstDir
            it.newBase = rendered.newBase
        }

        disambiguateVersions(regularItems, isDisc: false)

        for it in regularItems where !it.extra {
            if let part = it.file.parsed?.partLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
               !part.isEmpty {
                let cleanPart = sanitizeName(part)
                if !cleanPart.isEmpty {
                    let ext = extOf(it.file.name)
                    it.newBase = "\(Self.stripTrailingExt(it.newBase, ext: ext))-\(cleanPart)"
                }
            }
        }

        let groupRenamedSeasons = (isTv && opts.mode == .inPlace)
            ? reuseSeasonFolders(g, groupIndex: groupIndex, items: regularItems, curBase: curBase)
            : [:]
        let groupFileOpsStart = fileOps.count

        for it in regularItems {
            addMkdir(it.dstDir, group: g.id, selected: it.selected)
            let ext = extOf(it.file.name)
            let hasExt = !ext.isEmpty && it.newBase.lowercased().hasSuffix(".\(ext.lowercased())")
            if it.extra {
                it.outName = it.file.name
            } else if ext.isEmpty || hasExt {
                it.outName = it.newBase
            } else {
                it.outName = "\(it.newBase).\(ext)"
            }
            emitFileOp(it, name: it.outName, groupId: g.id)
        }

        // Emit subtitles and sidecars
        var groupSeasonByDst: [String: String] = [:]
        for (src, dst) in groupRenamedSeasons { groupSeasonByDst[dst] = src }

        var renderedCompanion: [Int: (dstDir: String, newBase: String)] = [:]
        var subMetaById: [Int: PrecomputedSubMeta] = [:]
        var subBaseCounts: [String: Int] = [:]

        for c in companions {
            let f = c.file
            let dstDir: String
            let base: String
            if let followed = c.followed {
                dstDir = followed.file.isDiscDir ? dirOf(followed.dstDir) : followed.dstDir
                base = followed.newBase
            } else if c.extra {
                dstDir = joinPath(curBase, "Extras")
                base = stem(f.name)
            } else {
                let rendered = renderName(
                    file: f,
                    ref: c.ref,
                    manual: true,
                    metaSource: c.fallbackVideo
                )
                dstDir = groupSeasonByDst[rendered.dstDir]
                    ?? renamedSeasonByDst[rendered.dstDir]
                    ?? rendered.dstDir
                base = rendered.newBase
                renderedCompanion[c.id] = (dstDir: dstDir, newBase: base)
            }

            if f.role == .subtitle && !(c.followed?.extra ?? c.extra) {
                let ext = extOf(f.name)
                let extSuffix = ext.isEmpty ? "" : ".\(ext)"
                let lang = langFromRemainder(c.remainder) ?? parsedLang(f)
                let flags = Self.mergedSubFlags(f, remainder: c.remainder)
                let std = Self.canonicalSubFlags(flags)
                let cleanBase = (c.followed != nil && c.followed!.file.isDiscDir)
                    ? base
                    : Self.stripTrailingExt(base, ext: extOf(c.followed?.file.name ?? ""))
                let langPart = lang.map { ".\($0)" } ?? ""
                let stdPart = std.isEmpty ? "" : ".\(std.joined(separator: "."))"
                let baseKey = "\(dstDir)/\(cleanBase)\(langPart)\(stdPart)\(extSuffix)".lowercased()
                subBaseCounts[baseKey, default: 0] += 1
                subMetaById[c.id] = PrecomputedSubMeta(
                    lang: lang,
                    hasBilingual: flags.contains("bilingual"),
                    stdFlags: std,
                    baseKey: baseKey
                )
            }
        }

        var subTargets: [String: Int] = [:]
        func formatSubName(
            meta: PrecomputedSubMeta,
            dstDir: String,
            base: String,
            ext: String
        ) -> String {
            let extSuffix = ext.isEmpty ? "" : ".\(ext)"
            let addBilingual = meta.hasBilingual && (subBaseCounts[meta.baseKey] ?? 0) > 1

            var suffixParts: [String] = []
            if let lang = meta.lang { suffixParts.append(lang) }
            if addBilingual { suffixParts.append("bilingual") }
            suffixParts.append(contentsOf: meta.stdFlags)

            let prefix = suffixParts.isEmpty ? base : "\(base).\(suffixParts.joined(separator: "."))"
            let key = "\(dstDir)/\(prefix)\(extSuffix)".lowercased()
            let n = (subTargets[key] ?? 0) + 1
            subTargets[key] = n
            return n == 1 ? "\(prefix)\(extSuffix)" : "\(prefix).\(n)\(extSuffix)"
        }

        for c in companions {
            let f = c.file
            let ext = extOf(f.name)
            if let followed = c.followed {
                let followedDstDir = followed.file.isDiscDir ? dirOf(followed.dstDir) : followed.dstDir
                let followedBase = followed.file.isDiscDir
                    ? followed.newBase
                    : Self.stripTrailingExt(followed.newBase, ext: extOf(followed.file.name))
                let name: String
                if followed.extra {
                    name = f.name
                } else if f.role == .subtitle, let subMeta = subMetaById[c.id] {
                    name = formatSubName(
                        meta: subMeta,
                        dstDir: followedDstDir,
                        base: followedBase,
                        ext: ext
                    )
                } else {
                    name = ext.isEmpty
                        ? "\(followedBase)\(c.remainder)"
                        : "\(followedBase)\(c.remainder).\(ext)"
                }
                addMkdir(followedDstDir, group: g.id, selected: c.selected)
                emitFileOp(
                    followed,
                    name: name,
                    groupId: g.id,
                    source: f,
                    selected: c.selected,
                    dstDirOverride: followedDstDir
                )
                continue
            }

            let dstDir: String
            let name: String
            if c.extra {
                dstDir = joinPath(curBase, "Extras")
                name = f.name
            } else {
                let r = renderedCompanion[c.id]!
                dstDir = r.dstDir
                if f.role == .subtitle, let subMeta = subMetaById[c.id] {
                    name = formatSubName(
                        meta: subMeta,
                        dstDir: dstDir,
                        base: r.newBase,
                        ext: ext
                    )
                } else {
                    name = ext.isEmpty
                        ? "\(r.newBase)\(c.remainder)"
                        : "\(r.newBase)\(c.remainder).\(ext)"
                }
            }
            addMkdir(dstDir, group: g.id, selected: c.selected)
            let dst = joinPath(dstDir, name)
            if c.selected && f.path != dst {
                movedSrcsLower.insert(f.path.lowercased())
            }
            fileOps.append(RenameOp(
                id: OpId("r-\(stableHash(f.path))"),
                kind: .relocate,
                phase: .files,
                src: f.path,
                dst: dst,
                group: g.id,
                selected: c.selected,
                warning: c.warnings.isEmpty ? nil : c.warnings.joined(separator: "；")
            ))
        }

        return (groupRenamedSeasons: groupRenamedSeasons, groupFileOpsStart: groupFileOpsStart)
    }

    private func planGroupOpsSync(
        group g: MediaGroup,
        groupIndex: Int,
        decision d: GroupDecision,
        match: Candidate,
        show: ShowDetail?,
        movieInfo: Candidate?,
        naming: NamingOptions,
        template: String,
        isTv: Bool,
        tmdbCounts: [Int],
        titles: [EpisodeRef: String],
        items: [PlanItem],
        companions: [PlanCompanion]
    ) throws -> (
        showDir: String,
        curBase: String,
        hasRegularWork: Bool,
        groupRenamedSeasons: [String: String],
        groupFileOpsStart: Int
    ) {
        let groupSelected = items.contains(where: \.selected) || companions.contains(where: \.selected)
        let plannedRefs = items.compactMap { !$0.extra ? $0.ref : nil }
            + companions.compactMap { ($0.followed == nil && !$0.extra) ? $0.ref : nil }

        let titleVars = buildTitleVars(
            chineseNamed(match, detail: show?.info ?? movieInfo),
            options: naming,
            local: g.anchorTitle
        )
        let folderName = computeFolderName(group: g, match: match, naming: naming, titleVars: titleVars)

        let discItems = items.filter { $0.file.isDiscDir }
        let regularItems = items.filter { !$0.file.isDiscDir }
        let hasRegularWork = !regularItems.isEmpty || companions.contains { $0.followed == nil }

        if !discItems.isEmpty {
            try planDiscUnits(group: g, discItems: discItems, isTv: isTv, folderName: folderName)
        }

        let initialCurBase = discItems.first?.dstDir ?? g.rootDir
        let curBase: String
        let groupShowDir: String
        if hasRegularWork {
            let folderPlan = try planRegularFolders(
                group: g,
                groupIndex: groupIndex,
                decision: d,
                match: match,
                isTv: isTv,
                folderName: folderName,
                groupSelected: groupSelected,
                plannedRefs: plannedRefs,
                discItems: discItems,
                initialCurBase: initialCurBase
            )
            curBase = folderPlan.curBase
            groupShowDir = folderPlan.groupShowDir
        } else {
            curBase = initialCurBase
            groupShowDir = initialCurBase
        }

        let fileOutcome = emitFileOps(
            group: g,
            groupIndex: groupIndex,
            match: match,
            show: show,
            naming: naming,
            template: template,
            isTv: isTv,
            titleVars: titleVars,
            folderName: folderName,
            tmdbCounts: tmdbCounts,
            titles: titles,
            regularItems: regularItems,
            companions: companions,
            plannedRefs: plannedRefs,
            curBase: curBase
        )

        let showDir = hasRegularWork ? groupShowDir : (discItems.first?.dstDir ?? g.rootDir)
        return (
            showDir: showDir,
            curBase: curBase,
            hasRegularWork: hasRegularWork,
            groupRenamedSeasons: fileOutcome.groupRenamedSeasons,
            groupFileOpsStart: fileOutcome.groupFileOpsStart
        )
    }

    private func recordPlannedFinalDsts(from startIndex: Int, finalDir: (String) -> String) {
        for i in startIndex..<fileOps.count {
            let o = fileOps[i]
            if o.selected {
                plannedFinalDstsLower.insert(
                    joinPath(finalDir(dirOf(o.dst)), baseOf(o.dst)).lowercased()
                )
            }
        }
    }

    // MARK: - Merge, Op & Title Helpers

    private func noteMerge(
        _ g: MediaGroup,
        into: String,
        withGroup: GroupId?,
        exists: Bool,
        refs: [EpisodeRef]
    ) {
        let seasons = Set(refs.map(\.season)).sorted()
        merges.append(PlanMerge(
            group: g.id,
            into: into,
            exists: exists,
            withGroup: withGroup,
            seasons: seasons
        ))
    }

    private func emitFileOp(
        _ it: PlanItem,
        name: String,
        groupId: GroupId,
        source: ScanFile? = nil,
        selected: Bool? = nil,
        dstDirOverride: String? = nil
    ) {
        let src = source ?? it.file
        let dst = joinPath(dstDirOverride ?? it.dstDir, name)
        let sel = selected ?? it.selected
        if sel && src.path != dst {
            movedSrcsLower.insert(src.path.lowercased())
        }
        fileOps.append(RenameOp(
            id: OpId("r-\(stableHash(src.path))"),
            kind: .relocate,
            phase: .files,
            src: src.path,
            dst: dst,
            group: groupId,
            selected: sel,
            warning: (source == nil && !it.warnings.isEmpty) ? it.warnings.joined(separator: "；") : nil
        ))
    }

    private func addMkdir(_ dir: String, group: GroupId, selected: Bool = true) {
        let key = dir.lowercased()
        guard !knownDirs.contains(key) else { return }
        let canonical: String
        if let existingPath = mkdirKeyToPath[key] {
            canonical = existingPath
        } else {
            mkdirKeyToPath[key] = dir
            canonical = dir
        }
        if mkdirs[canonical] == nil {
            mkdirs[canonical] = group
        }
        if selected {
            selectedMkdirs.insert(canonical)
        }
    }

    private func buildTitleVars(
        _ c: Candidate,
        options o: NamingOptions,
        local: String? = nil
    ) -> [String: String] {
        var en = c.englishTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if en?.isEmpty == true { en = nil }

        let englishOnly = (o.titleLanguage == .englishFirst && !o.bilingual)
        if englishOnly {
            if en == nil { en = c.title }
        } else if o.customTemplate == nil, let enVal = en, normTitle(enVal) == normTitle(c.title) {
            en = nil
        }

        let keepLocal = local != nil
            && local != c.title
            && stripPunct(local!) == stripPunct(c.title)

        var vars: [String: String] = [
            "title": keepLocal ? local! : c.title,
            "tmdbid": "\(c.tmdbId)",
            "tmdb_tag": "{tmdb-\(c.tmdbId)}",
        ]
        if let en { vars["en_title"] = en }
        if let orig = c.originalTitle { vars["original_title"] = orig }
        return vars
    }

    // MARK: - Multi-Version Disambiguation & Subtitle Helpers

    private func parsedLang(_ f: ScanFile) -> String? {
        guard let raw = f.parsed?.lang, !raw.isEmpty else { return nil }
        return followNormalizeLang(raw) ?? raw
    }

    private static func stripTrailingExt(_ base: String, ext: String) -> String {
        guard !ext.isEmpty else { return base }
        let suffix = ".\(ext.lowercased())"
        if base.lowercased().hasSuffix(suffix), base.count >= suffix.count {
            return String(base.dropLast(suffix.count))
        }
        return base
    }

    private static func mergedSubFlags(_ f: ScanFile, remainder: String) -> Set<String> {
        var out: Set<String> = []
        for flag in f.parsed?.subFlags ?? [] {
            let norm = flag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !norm.isEmpty { out.insert(norm) }
        }
        for flag in followSubFlagsFromRemainder(remainder) {
            let norm = flag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !norm.isEmpty { out.insert(norm) }
        }
        return out
    }

    private static func canonicalSubFlags(_ flags: Set<String>) -> [String] {
        orderedSubFlags.filter { flags.contains($0) }
    }

    private static func editionTag(_ p: ParsedName?) -> String? {
        guard let raw = p?.edition?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private static func techTag(_ p: ParsedName?) -> String? {
        guard let p else { return nil }
        for candidate in [p.extraInfo, p.probe?.extraInfoSummary, p.resolution, p.probe?.resolution] {
            if let s = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return s
            }
        }
        return nil
    }

    private func disambiguateVersions(_ items: [PlanItem], isDisc: Bool) {
        var bucketOrder: [String] = []
        var buckets: [String: [PlanItem]] = [:]

        for it in items {
            if it.extra { continue }
            if !isDisc && it.file.isDiscDir { continue }
            let ext = isDisc ? "" : extOf(it.file.name)
            let cleanBase = isDisc ? it.newBase : Self.stripTrailingExt(it.newBase, ext: ext)
            let part = it.file.parsed?.partLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            let partSuffix = (part == nil || part!.isEmpty) ? "" : "-\(sanitizeName(part!))"
            let key = isDisc
                ? "\(it.dstDir)/\(cleanBase)\(partSuffix)".lowercased()
                : "\(it.dstDir)/\(cleanBase)\(partSuffix).\(ext)".lowercased()
            if buckets[key] == nil { bucketOrder.append(key) }
            buckets[key, default: []].append(it)
        }

        func allDistinct(_ tags: [String?]) -> Bool {
            guard tags.contains(where: { $0 != nil && !$0!.isEmpty }) else { return false }
            var seen: Set<String> = []
            for t in tags {
                if !seen.insert((t ?? "").lowercased()).inserted {
                    return false
                }
            }
            return true
        }

        for key in bucketOrder {
            guard let bucket = buckets[key], bucket.count >= 2 else { continue }
            let editions = bucket.map { Self.editionTag($0.file.parsed) }
            let techs = bucket.map { Self.techTag($0.file.parsed) }
            let combined: [String?] = (0..<bucket.count).map { i in
                let parts = [editions[i], techs[i]].compactMap { $0 }
                return parts.isEmpty ? nil : parts.joined(separator: " ")
            }

            let chosen: [String?]?
            if allDistinct(editions) {
                chosen = editions
            } else if allDistinct(techs) {
                chosen = techs
            } else if allDistinct(combined) {
                chosen = combined
            } else {
                let sigs = Set(combined.map { ($0 ?? "").lowercased() })
                chosen = sigs.count >= 2 ? combined : nil
            }
            guard let chosen else { continue }

            for i in 0..<bucket.count {
                guard let tag = chosen[i], !tag.isEmpty else { continue }
                let cleanTag = sanitizeName(tag)
                if cleanTag.isEmpty { continue }
                let it = bucket[i]
                let ext = isDisc ? "" : extOf(it.file.name)
                let cleanBase = isDisc ? it.newBase : Self.stripTrailingExt(it.newBase, ext: ext)
                it.newBase = "\(cleanBase) - \(cleanTag)"
            }
        }
    }
}

// MARK: - Private Regex Utilities

private func regexReplaceFirst(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
    guard !text.isEmpty else { return text }
    let full = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: full),
          let swiftRange = Range(match.range, in: text) else {
        return text
    }
    let replacement = regex.replacementString(for: match, in: text, offset: 0, template: template)
    var out = text
    out.replaceSubrange(swiftRange, with: replacement)
    return out
}
