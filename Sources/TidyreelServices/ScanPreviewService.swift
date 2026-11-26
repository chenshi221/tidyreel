import Foundation
import TidyreelModels

public struct ScanPreviewSummary: Equatable, Sendable {
    public var dirs: Int = 0
    public var videos: Int = 0
    public var subtitles: Int = 0
    public var others: Int = 0
    public var bytes: Int64 = 0
    public var truncated: Bool = false
    public var topDirs: [String] = []

    public init() {}
}

public enum ScanPreviewService {
    public static func preview(
        backend: any StorageBackend,
        paths: [String],
        maxDepth: Int = 3,
        maxDirs: Int = 200,
        fileSizes: [String: Int64] = [:],
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async -> ScanPreviewSummary {
        actor Collector {
            var summary = ScanPreviewSummary()
            var depthByDir: [String: Int] = [:]
            var listed = 0

            func setInitialDepth(_ p: String, _ d: Int) { depthByDir[p] = d }
            func depth(of dir: String) -> Int { depthByDir[dir] ?? 0 }

            func countFile(name: String, size: Int64) {
                let ext = extOf(name).lowercased()
                if videoExtensions.contains(ext) {
                    summary.videos += 1
                } else if subtitleExtensions.contains(ext) {
                    summary.subtitles += 1
                } else {
                    summary.others += 1
                }
                summary.bytes += size
            }

            func nextBatch(dir: String, entries: [RemoteEntry], maxDepth: Int, maxDirs: Int) -> [String] {
                if listed >= maxDirs {
                    summary.truncated = true
                    return []
                }
                listed += 1
                let d = depthByDir[dir] ?? 0
                var subs: [String] = []
                for e in entries {
                    if e.isDir {
                        summary.dirs += 1
                        if d == 0 { summary.topDirs.append(e.path) }
                        if d + 1 < maxDepth {
                            depthByDir[e.path] = d + 1
                            subs.append(e.path)
                        } else {
                            summary.truncated = true
                        }
                    } else {
                        countFile(name: e.name, size: e.size)
                    }
                }
                return subs
            }

            func canListMore(maxDirs: Int) -> Bool {
                if listed >= maxDirs {
                    summary.truncated = true
                    return false
                }
                return true
            }

            func finalize() -> ScanPreviewSummary {
                var out = summary
                out.topDirs.sort()
                return out
            }
        }

        let collector = Collector()
        var initialDirs: [String] = []
        for p in paths {
            let name = baseOf(p)
            let ext = extOf(name).lowercased()
            if let sz = fileSizes[p] {
                await collector.countFile(name: name, size: sz)
            } else if videoExtensions.contains(ext) || subtitleExtensions.contains(ext) {
                await collector.countFile(name: name, size: 0)
            } else {
                await collector.setInitialDepth(p, 0)
                initialDirs.append(p)
            }
        }

        if !initialDirs.isEmpty {
            try? await walkDirs(roots: initialDirs, parallel: 4, stop: isCancelled) { dir in
                guard await collector.canListMore(maxDirs: maxDirs) else { return [] }
                guard let entries = try? await backend.list(dir, refresh: false) else { return [] }
                return await collector.nextBatch(dir: dir, entries: entries, maxDepth: maxDepth, maxDirs: maxDirs)
            }
        }
        return await collector.finalize()
    }

    public static func warnings(
        paths: [String],
        preview r: ScanPreviewSummary,
        organizedCount: Int = 0,
        l10n: AppL10n = .zh
    ) -> [String] {
        var out: [String] = []
        if paths.contains(where: { $0.split(separator: "/").count <= 1 }) {
            out.append(l10n.tr(
                "选中的是根目录或一级目录，里面可能混着很多不相关的内容",
                "Root or top-level folder selected; it may contain unrelated files"
            ))
        }
        if r.videos >= 300 {
            out.append(l10n.tr(
                "视频\(r.truncated ? "至少" : "")有 \(r.videos) 个，识别和确认会比较久",
                "\(r.truncated ? "At least " : "")\(r.videos) videos found; matching and review may take a while"
            ))
        }
        if r.topDirs.count > 30 {
            out.append(l10n.tr(
                "包含 \(r.topDirs.count) 个文件夹，可能是很多部作品",
                "Contains \(r.topDirs.count) folders, which may span many titles"
            ))
        }
        if organizedCount > 0 {
            out.append(l10n.tr(
                "其中 \(organizedCount) 个文件夹已经整理过",
                "\(l10n.plural(organizedCount, "folder")) already organized"
            ))
        }
        if r.videos == 0 && !r.truncated {
            out.append(l10n.tr("没有找到视频文件", "No video files found"))
        }
        return out
    }
}
