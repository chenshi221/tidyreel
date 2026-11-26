import Foundation
import TidyreelModels

// MARK: - Kodi / VidHub / Infuse / Jellyfin NFO XML Generation & Artwork

/// Generates `tvshow.nfo` XML for a TV show folder.
public func tvshowNfo(_ show: ShowDetail) -> String {
    let firstAirDate = show.seasons
        .filter { $0.number > 0 && $0.airDate != nil }
        .compactMap(\.airDate)
        .min()
    var fields = commonNfoFields(show.info)
    fields.append(.tag("premiered", formatNfoDate(firstAirDate)))
    return buildNfoDocument(root: "tvshow", fields: fields)
}

/// Alias of `tvshowNfo` matching Dart `tvShowNfo` casing.
public func tvShowNfo(_ show: ShowDetail) -> String {
    tvshowNfo(show)
}

/// Generates `<video>.nfo` / `movie.nfo` XML for a movie, including optional `fileinfo`/`streamdetails`.
public func movieNfo(_ movie: Candidate, probe: MediaProbeInfo? = nil) -> String {
    var fields = commonNfoFields(movie)
    if let col = movie.collectionName, !col.isEmpty {
        fields.append(.raw("  <set><name>\(xmlEscape(col))</name></set>"))
    }
    if let fileInfo = formatFileInfoXml(probe) {
        fields.append(.raw(fileInfo))
    }
    return buildNfoDocument(root: "movie", fields: fields)
}

/// Generates `<episode>.nfo` (`<episodedetails>`) XML for a TV episode, including optional `fileinfo`/`streamdetails`.
public func episodedetailsNfo(
    show: Candidate,
    season: Int,
    episode: Int,
    info: Episode? = nil,
    title: String? = nil,
    probe: MediaProbeInfo? = nil
) -> String {
    var fields: [NfoField] = [
        .tag("title", info?.title ?? title ?? "Episode \(episode)"),
        .tag("showtitle", show.title),
        .tag("season", "\(season)"),
        .tag("episode", "\(episode)"),
        .tag("plot", info?.overview),
        .tag("aired", formatNfoDate(info?.airDate)),
        .tag("runtime", info?.runtimeMinutes.map(String.init)),
    ]
    if let fileInfo = formatFileInfoXml(probe) {
        fields.append(.raw(fileInfo))
    }
    return buildNfoDocument(root: "episodedetails", fields: fields)
}

/// Alias of `episodedetailsNfo` matching Dart `episodeNfo`.
public func episodeNfo(
    show: Candidate,
    season: Int,
    episode: Int,
    info: Episode? = nil,
    title: String? = nil,
    probe: MediaProbeInfo? = nil
) -> String {
    episodedetailsNfo(
        show: show,
        season: season,
        episode: episode,
        info: info,
        title: title,
        probe: probe
    )
}

/// Builds a TMDB image URL for a given size (`w185`, `w780`, `w1280`, `original`).
public func tmdbImageUrl(path: String, size: String) -> String {
    if path.hasPrefix("http://") || path.hasPrefix("https://") {
        return path
    }
    let normalized = path.hasPrefix("/") ? path : "/\(path)"
    return "https://image.tmdb.org/t/p/\(size)\(normalized)"
}

/// Builds `(fileName, imageUrl)` pairs for folder-level TMDB artwork (`poster.jpg`, `fanart.jpg`,
/// `clearlogo.png`, `landscape.jpg`), falling back to `fallback` when `candidate.tmdbId == fallback.tmdbId`.
public func artworkFiles(for candidate: Candidate, fallback: Candidate) -> [(fileName: String, url: String)] {
    let same = fallback.tmdbId == candidate.tmdbId
    let poster = candidate.posterPath ?? (same ? fallback.posterPath : nil)
    let backdrop = candidate.backdropPath ?? (same ? fallback.backdropPath : nil)
    let clearLogo = candidate.clearLogoPath ?? (same ? fallback.clearLogoPath : nil)
    let landscape = candidate.landscapePath ?? (same ? fallback.landscapePath : nil)

    var out: [(fileName: String, url: String)] = []
    if let poster, !poster.isEmpty {
        out.append(("poster.jpg", tmdbImageUrl(path: poster, size: "w780")))
    }
    if let backdrop, !backdrop.isEmpty {
        out.append(("fanart.jpg", tmdbImageUrl(path: backdrop, size: "w1280")))
    }
    if let clearLogo, !clearLogo.isEmpty {
        out.append(("clearlogo.png", tmdbImageUrl(path: clearLogo, size: "original")))
    }
    if let landscape, !landscape.isEmpty {
        out.append(("landscape.jpg", tmdbImageUrl(path: landscape, size: "w1280")))
    }
    return out
}

/// Builds the season poster filename (`season-specials-poster.jpg` for season 0, `season01-poster.jpg` otherwise).
public func seasonPosterFileName(season: Int) -> String {
    season == 0
        ? "season-specials-poster.jpg"
        : String(format: "season%02d-poster.jpg", season)
}

// MARK: - Private XML Helpers

private enum NfoField {
    case tag(String, String?)
    case raw(String)
}

private func xmlEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        default: out.append(ch)
        }
    }
    return out
}

private func buildNfoDocument(root: String, fields: [NfoField]) -> String {
    var out = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<\(root)>\n"
    for field in fields {
        switch field {
        case let .tag(name, value):
            guard let value, !value.isEmpty else { continue }
            out += "  <\(name)>\(xmlEscape(value))</\(name)>\n"
        case let .raw(rawXml):
            guard !rawXml.isEmpty else { continue }
            out += "\(rawXml)\n"
        }
    }
    out += "</\(root)>\n"
    return out
}

private let utcGregorianCalendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    return cal
}()

func formatNfoDate(_ date: Date?) -> String {
    guard let date else { return "" }
    let comps = utcGregorianCalendar.dateComponents([.year, .month, .day], from: date)
    guard let y = comps.year, let m = comps.month, let d = comps.day else { return "" }
    return String(format: "%04d-%02d-%02d", y, m, d)
}

private func formatActorXml(_ a: PersonCredit) -> String {
    var out = "  <actor>\n"
    out += "    <name>\(xmlEscape(a.name))</name>\n"
    if let role = a.role, !role.isEmpty {
        out += "    <role>\(xmlEscape(role))</role>\n"
    }
    if let profilePath = a.profilePath, !profilePath.isEmpty {
        let thumb = tmdbImageUrl(path: profilePath, size: "w185")
        out += "    <thumb>\(xmlEscape(thumb))</thumb>\n"
    }
    out += "  </actor>"
    return out
}

private func commonNfoFields(_ c: Candidate) -> [NfoField] {
    var fields: [NfoField] = [
        .tag("title", c.title),
        .tag("originaltitle", c.originalTitle ?? c.englishTitle),
        .tag("year", c.year.map(String.init)),
        .tag("mpaa", c.certification),
        .tag("plot", c.overview),
    ]
    for g in c.genres { fields.append(.tag("genre", g)) }
    for t in c.tags { fields.append(.tag("tag", t)) }
    for s in c.studios { fields.append(.tag("studio", s)) }
    for d in c.directors { fields.append(.tag("director", d)) }
    for w in c.writers { fields.append(.tag("credits", w)) }

    if let vote = c.voteAverage {
        let valStr = String(format: "%.1f", vote)
        let votesXml = c.voteCount.map { "<votes>\($0)</votes>" } ?? ""
        fields.append(.raw(
            "  <ratings><rating name=\"themoviedb\" max=\"10\" default=\"true\"><value>\(valStr)</value>\(votesXml)</rating></ratings>"
        ))
    }

    fields.append(.raw("  <uniqueid type=\"tmdb\" default=\"true\">\(c.tmdbId)</uniqueid>"))
    if let imdb = c.imdbId, !imdb.isEmpty {
        fields.append(.raw("  <uniqueid type=\"imdb\">\(xmlEscape(imdb))</uniqueid>"))
    }
    if let tvdb = c.tvdbId {
        fields.append(.raw("  <uniqueid type=\"tvdb\">\(tvdb)</uniqueid>"))
    }
    fields.append(.tag("tmdbid", "\(c.tmdbId)"))
    if let imdb = c.imdbId, !imdb.isEmpty {
        fields.append(.tag("imdbid", imdb))
    }
    for actor in c.actors where !actor.name.isEmpty {
        fields.append(.raw(formatActorXml(actor)))
    }
    return fields
}

private func kodiHdrType(_ hdr: String) -> String {
    switch hdr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "dv", "dovi", "dolby vision", "dolbyvision":
        return "dolbyvision"
    case "hdr10+", "hdr10plus":
        return "hdr10plus"
    case "hdr", "hdr10":
        return "hdr10"
    case "hlg":
        return "hlg"
    case let other:
        return other
    }
}

private func formatFileInfoXml(_ probe: MediaProbeInfo?) -> String? {
    guard let probe else { return nil }
    let hasVideo = (probe.videoCodec != nil && !probe.videoCodec!.isEmpty)
        || (probe.width ?? 0) > 0
        || (probe.height ?? 0) > 0
        || (probe.durationMs ?? 0) > 0
        || (probe.hdr != nil && !probe.hdr!.isEmpty)
    let hasAudio = (probe.audioCodec != nil && !probe.audioCodec!.isEmpty)
        || (probe.audioChannels ?? 0) > 0
    guard hasVideo || hasAudio else { return nil }

    var out = "  <fileinfo>\n    <streamdetails>\n"
    if hasVideo {
        out += "      <video>\n"
        if let vc = probe.videoCodec, !vc.isEmpty {
            out += "        <codec>\(xmlEscape(vc.lowercased()))</codec>\n"
        }
        if let w = probe.width, w > 0 {
            out += "        <width>\(w)</width>\n"
        }
        if let h = probe.height, h > 0 {
            out += "        <height>\(h)</height>\n"
        }
        if let w = probe.width, let h = probe.height, w > 0, h > 0 {
            let aspect = String(format: "%.2f", Double(w) / Double(h))
            out += "        <aspect>\(aspect)</aspect>\n"
        }
        if let ms = probe.durationMs, ms > 0 {
            let secs = Int((Double(ms) / 1000.0).rounded())
            if secs > 0 {
                out += "        <durationinseconds>\(secs)</durationinseconds>\n"
            }
        }
        if let hdr = probe.hdr, !hdr.isEmpty {
            out += "        <hdrtype>\(xmlEscape(kodiHdrType(hdr)))</hdrtype>\n"
        }
        out += "      </video>\n"
    }
    if hasAudio {
        out += "      <audio>\n"
        if let ac = probe.audioCodec, !ac.isEmpty {
            out += "        <codec>\(xmlEscape(ac.lowercased()))</codec>\n"
        }
        if let ch = probe.audioChannels, ch > 0 {
            out += "        <channels>\(ch)</channels>\n"
        }
        out += "      </audio>\n"
    }
    out += "    </streamdetails>\n  </fileinfo>"
    return out
}
