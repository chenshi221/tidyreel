import Foundation
import TidyreelModels

/// Rule-based media filename and folder parser with pre-compiled regular expressions,
/// zero network calls, and stateless `Sendable` safety.
public struct RuleBasedParser: FilenameParser, Sendable {
    public init() {}

    public func classify(_ fileName: String) -> FileRole {
        classifyFile(fileName)
    }

    public func parse(_ fileName: String, parentDirs: [String] = []) -> ParsedName {
        let leaf: String = {
            let slashSplit = fileName.replacingOccurrences(of: "\\", with: "/")
            if let idx = slashSplit.lastIndex(of: "/") {
                return String(slashSplit[slashSplit.index(after: idx)...])
            }
            return slashSplit
        }()
        let a = analyzeName(leaf, isFile: true)

        // Folder info: nearest folder with a title wins; season/special/extra folders
        // contribute flags; explicit external IDs and edition tags inherit too.
        var dTitle: String?
        var dYear: Int?
        var dSeason: Int?
        var dEdition: String?
        var dExternalId: ExternalId?
        var dSpecial = false
        var dExtra = false
        var dirsSeen = false

        for raw in parentDirs {
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let d = analyzeDirNameCached(raw)
            if dExternalId == nil { dExternalId = d.externalId }
            if dEdition == nil { dEdition = d.edition }
            if d.title.isEmpty {
                if d.extraKw { dExtra = true }
                if d.specialKw { dSpecial = true }
                if let ds = d.season {
                    if dSeason == nil { dSeason = ds }
                    dirsSeen = true
                }
                continue
            }
            if isGenericContainerDir(d.title) { continue }
            if !dirsSeen && d.season == nil {
                if d.extraKw { dExtra = true }
                if d.specialKw { dSpecial = true }
            }
            dirsSeen = true
            if dTitle == nil { dTitle = d.title }
            if dYear == nil { dYear = d.year }
            if dSeason == nil { dSeason = d.season }
        }

        // Leading "01 Pilot.mkv" and bare 4-digit "海贼王/1080.mkv" only count as
        // episodes when parent folders provide show/season context.
        var episodes = a.episodes
        var bare = a.bare
        var bareFrom = a.bareFrom
        var fileTitle = a.title
        if bare == nil && episodes.isEmpty && dirsSeen {
            if let lead = a.leadNum {
                bare = lead
                bareFrom = "lead"
                fileTitle = ""
            } else if let lone4 = a.loneFourDigit {
                bare = lone4
                bareFrom = "lone"
                fileTitle = ""
            }
        }
        let title = !fileTitle.isEmpty ? fileTitle : (dTitle ?? "")
        let titleFromDir = fileTitle.isEmpty && !title.isEmpty

        var season = a.season ?? dSeason
        if season == nil && dSpecial { season = 0 }
        let year = a.year ?? dYear

        var absolute: Int?
        if episodes.isEmpty, let bareVal = bare {
            if season != nil {
                episodes = [bareVal]
            } else {
                absolute = bareVal
            }
        }

        let isSpecial = a.specialKw || dSpecial || season == 0
        let isExtra = a.extraKw || dExtra
        let edition = a.edition ?? dEdition
        let externalId = a.externalId ?? dExternalId

        let kind: MediaKind
        if isExtra {
            kind = .extra
        } else if isSpecial {
            kind = .special
            season = 0
        } else if a.movieKw && !a.explicitEp {
            kind = .movie
            episodes = []
            absolute = nil
        } else if !episodes.isEmpty
            || absolute != nil
            || season != nil
            || a.batch
            || (a.airDate != nil && !title.isEmpty) {
            kind = .episode // season-only = season pack, low confidence
        } else if year != nil || a.hasTech || a.part != nil || edition != nil {
            kind = .movie
        } else {
            kind = .unknown
        }
        if kind == .extra {
            episodes = []
            absolute = nil
        }
        let effectiveYear = year ?? (kind == .movie ? a.airDateYear : nil)

        let hasTitle = !title.isEmpty
        var conf: Double
        switch kind {
        case .extra:
            conf = hasTitle ? 0.8 : 0.55
        case .special:
            conf = hasTitle ? 0.8 : 0.5
        case .movie:
            if a.movieKw {
                conf = hasTitle ? 0.75 : 0.4
            } else if effectiveYear != nil && hasTitle {
                conf = 0.92
            } else if hasTitle {
                conf = 0.55
            } else {
                conf = 0.3
            }
        case .episode where episodes.isEmpty && absolute == nil && a.airDate != nil:
            conf = 0.85
        case .episode:
            conf = episodeConfidence(
                a,
                bareFrom: bareFrom,
                hasTitle: hasTitle,
                titleFromDir: titleFromDir,
                seasonKnown: season != nil
            )
        case .unknown:
            conf = hasTitle ? 0.25 : 0.1
        }
        if hasTitle && title.utf16.count == 1 {
            conf -= 0.2
        }
        conf = min(1.0, max(0.0, conf))
        let roundedConf = (conf * 100.0).rounded() / 100.0

        return ParsedName(
            title: hasTitle ? title : nil,
            year: effectiveYear,
            season: season,
            episodes: episodes,
            absolute: absolute,
            kind: kind,
            resolution: a.res,
            group: a.group,
            lang: a.lang,
            extraInfo: a.extra,
            confidence: roundedConf,
            airDate: kind == .episode ? a.airDate : nil,
            edition: edition,
            part: a.part,
            partLabel: a.partLabel,
            subFlags: a.subFlags,
            externalId: externalId
        )
    }

    private func episodeConfidence(
        _ a: AnalyzedInfo,
        bareFrom: String,
        hasTitle: Bool,
        titleFromDir: Bool,
        seasonKnown: Bool
    ) -> Double {
        if a.explicitEp {
            let base = (a.season != nil || (!a.episodes.isEmpty && a.sxe)) ? 0.95 : 0.92
            if !hasTitle { return 0.55 }
            return titleFromDir ? base - 0.1 : base
        }
        switch bareFrom {
        case "dash":
            if !hasTitle { return 0.4 }
            return titleFromDir ? 0.7 : (seasonKnown ? 0.85 : 0.8)
        case "lead", "lone":
            if !hasTitle { return 0.3 }
            return seasonKnown ? 0.8 : 0.65
        case "trail":
            return 0.45
        default:
            return 0.3
        }
    }
}
