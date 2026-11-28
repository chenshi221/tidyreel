import Foundation
import TidyreelModels

/// Pure-Swift container header prober for MKV/WebM (EBML) and MP4/MOV/M4V (ISO-BMFF).
///
/// Reads technical metadata (resolution, video/audio codecs, HDR format, audio channels,
/// and duration) from container headers using bounded range requests with zero external
/// binary dependencies.
public struct ContainerMediaProbe: MediaProbe, Sendable {
    /// Default hard cap on total bytes read per file across all range requests (512 KiB).
    public static let defaultMaxReadBytes = 512 * 1024

    private static let initialChunkBytes = 64 * 1024

    private static let supportedExtensions: Set<String> = [
        "mkv",
        "mka",
        "mks",
        "webm",
        "mp4",
        "m4v",
        "mov",
    ]

    /// Maximum total bytes to read from storage per `probe` call.
    public let maxReadBytes: Int

    public init(maxReadBytes: Int = ContainerMediaProbe.defaultMaxReadBytes) {
        self.maxReadBytes = maxReadBytes
    }

    public func probe(
        backend: any StorageBackend,
        path: String,
        fileSize: Int64? = nil
    ) async -> MediaProbeInfo? {
        guard backend is any RangeReadableBackend else { return nil }
        guard maxReadBytes > 0 else { return nil }

        let ext = Self.extensionOf(path)
        if let ext, !Self.supportedExtensions.contains(ext) {
            return nil
        }

        var reader = ProbeRangeReader(
            backend: backend,
            path: path,
            maxBytes: maxReadBytes,
            fileSize: fileSize
        )

        let initialLen: Int
        if let fileSize, fileSize > 0, fileSize < Int64(Self.initialChunkBytes) {
            initialLen = Int(fileSize)
        } else {
            initialLen = Self.initialChunkBytes
        }

        guard let head = await reader.readRaw(start: 0, length: initialLen),
              head.count >= 8 else {
            return nil
        }

        if Self.isEbmlMagic(head) {
            return await EbmlProbe.probe(
                reader: &reader,
                head: head,
                ext: ext,
                fileSize: fileSize
            )
        }
        if Mp4Probe.isLikelyMp4(head, ext: ext) {
            return await Mp4Probe.probe(
                reader: &reader,
                head: head,
                ext: ext,
                fileSize: fileSize
            )
        }
        return nil
    }

    static func extensionOf(_ path: String) -> String? {
        let norm = path.replacingOccurrences(of: "\\", with: "/")
        let base: Substring
        if let slash = norm.lastIndex(of: "/") {
            base = norm[norm.index(after: slash)...]
        } else {
            base = norm[...]
        }
        guard let dot = base.lastIndex(of: "."),
              dot > base.startIndex else {
            return nil
        }
        let afterDot = base.index(after: dot)
        guard afterDot < base.endIndex else { return nil }
        return base[afterDot...].lowercased()
    }

    static func isEbmlMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let s = data.startIndex
        return data[s] == 0x1A
            && data[s + 1] == 0x45
            && data[s + 2] == 0xDF
            && data[s + 3] == 0xA3
    }
}
