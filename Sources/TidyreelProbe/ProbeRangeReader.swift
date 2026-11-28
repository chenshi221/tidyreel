import Foundation
import TidyreelModels

/// Budgeted sliding-window byte reader over `RangeReadableBackend`.
///
/// Guarantees that total bytes fetched across all range reads never exceed `maxBytes`,
/// and reuses already-buffered bytes when advancing sequentially.
public struct ProbeRangeReader: Sendable {
    public let backend: any StorageBackend
    public let path: String
    public let maxBytes: Int
    public let fileSize: Int64?

    public private(set) var bytesRead: Int = 0
    private var bufStart: Int64 = 0
    private var buf: Data = Data()

    public init(
        backend: any StorageBackend,
        path: String,
        maxBytes: Int,
        fileSize: Int64? = nil
    ) {
        self.backend = backend
        self.path = path
        self.maxBytes = max(0, maxBytes)
        self.fileSize = fileSize
    }

    public var remaining: Int {
        bytesRead >= maxBytes ? 0 : maxBytes - bytesRead
    }

    /// Seeds the buffer with an already-read chunk (e.g. initial probe head).
    public mutating func seed(start: Int64, bytes: Data) {
        guard start >= 0 else { return }
        bufStart = start
        buf = bytes
    }

    /// Raw range read capped by `remaining` budget and optional `fileSize`.
    public mutating func readRaw(start: Int64, length: Int) async -> Data? {
        let rem = remaining
        guard start >= 0, length > 0, rem > 0 else { return nil }
        if let fileSize, start >= fileSize {
            return Data()
        }

        var capped = min(length, rem)
        if let fileSize {
            let avail64 = fileSize - start
            if avail64 < Int64(capped) {
                capped = Int(avail64)
            }
        }
        if Int64(capped) > Int64.max - start {
            capped = Int(Int64.max - start)
        }
        if capped <= 0 {
            return Data()
        }

        let fetched: Data?
        do {
            fetched = try await readRangeIfSupported(
                backend: backend,
                path: path,
                start: start,
                length: capped
            )
        } catch {
            return nil
        }
        guard let raw = fetched else { return nil }

        let normalized: Data
        if raw.count > capped {
            normalized = raw[raw.startIndex..<(raw.startIndex + capped)]
        } else {
            normalized = raw
        }

        if normalized.count >= maxBytes - bytesRead {
            bytesRead = maxBytes
        } else {
            bytesRead += normalized.count
        }
        return normalized
    }

    /// Ensures a window starting at `offset` with at least `minLength` bytes
    /// (fetching up to `preferredLength` when a new read is needed).
    ///
    /// Returns a zero-copy `Data` slice starting at `offset` (index relative to
    /// `data.startIndex`), which may be shorter than `minLength` if EOF or the byte
    /// budget is reached, or `nil` if no bytes can be read at `offset`.
    public mutating func window(
        offset: Int64,
        minLength: Int,
        preferredLength: Int = 64 * 1024
    ) async -> Data? {
        guard offset >= 0, minLength > 0 else { return nil }
        if let fileSize, offset >= fileSize { return nil }

        let bufLen64 = Int64(buf.count)
        guard bufStart <= Int64.max - bufLen64 else { return nil }
        let bufEnd = bufStart + bufLen64

        // Fast path: fully satisfied by current buffer (zero-copy slice; subtraction avoids signed overflow).
        if offset >= bufStart && offset <= bufEnd {
            let availInBuf = Int(bufEnd - offset)
            if minLength <= availInBuf {
                let rel = Int(offset - bufStart)
                return buf[(buf.startIndex + rel)..<buf.endIndex]
            }
        }

        // Overlap path: keep buffered prefix and only fetch the missing tail.
        if offset >= bufStart && offset < bufEnd {
            let prefixOffset = Int(offset - bufStart)
            let prefixStart = buf.startIndex + prefixOffset
            let prefixLen = Int(bufEnd - offset)
            let wantTotal = max(preferredLength, minLength)
            let toFetch = wantTotal > prefixLen ? (wantTotal - prefixLen) : 0
            if toFetch <= 0 {
                return buf[prefixStart..<buf.endIndex]
            }
            let tail = await readRaw(start: bufEnd, length: toFetch)
            guard let tail, !tail.isEmpty else {
                return buf[prefixStart..<buf.endIndex]
            }
            var combined = Data(capacity: prefixLen + tail.count)
            combined.append(buf[prefixStart..<buf.endIndex])
            combined.append(tail)
            bufStart = offset
            buf = combined
            return combined
        }

        // Disjoint jump: fetch fresh window at `offset`.
        let fetchLen = max(preferredLength, minLength)
        guard let chunk = await readRaw(start: offset, length: fetchLen),
              !chunk.isEmpty else {
            return nil
        }
        bufStart = offset
        buf = chunk
        return chunk
    }
}

/// Priority score for selecting the primary audio track when multiple tracks exist.
public func audioCodecRank(_ codec: String?) -> Int {
    guard let codec, !codec.isEmpty else { return 0 }
    switch codec {
    case "Atmos": return 50
    case "DTS-X": return 45
    case "TrueHD": return 40
    case "DTS-HD": return 35
    case "FLAC": return 25
    case "EAC3": return 20
    case "DTS": return 18
    case "AC3": return 15
    case "Opus": return 12
    case "AAC": return 10
    default: return 5
    }
}

// MARK: - Bounds-Checked Alignment-Safe Binary Helpers

enum DetectedHdr: Equatable, Sendable {
    case dv
    case hdr10Plus
    case hdr10
    case hlg
}

enum CodecPrivateHdrInspector {
    /// Inspects an ISO/IEC 14496-15 `HEVCDecoderConfigurationRecord` (`hvcC`) for
    /// Dolby Vision RPU NALs (`UNSPEC62`) and SEI HDR10+ (SMPTE ST 2094-40) / HDR10 / HLG metadata.
    static func inspectHevcConfigurationRecord(_ data: Data) -> DetectedHdr? {
        guard data.count >= 23, data.probeUInt8(at: 0) == 1 else { return nil }
        let numArrays = min(Int(data.probeUInt8(at: 22) ?? 0), 32)
        var pos = 23

        var foundDv = false
        var foundHdr10Plus = false
        var foundHlg = false
        var foundHdr10Meta = false

        for _ in 0..<numArrays {
            guard data.hasRange(offset: pos, length: 3) else { break }
            let nalType = (data.probeUInt8(at: pos) ?? 0) & 0x3F
            let numNalus = min(Int(data.probeUInt16BE(at: pos + 1) ?? 0), 64)
            pos += 3

            for _ in 0..<numNalus {
                guard let nalLen16 = data.probeUInt16BE(at: pos) else {
                    pos = data.count
                    break
                }
                let nalLen = Int(nalLen16)
                pos += 2
                guard data.hasRange(offset: pos, length: nalLen) else {
                    pos = data.count
                    break
                }

                if nalType == 62 {
                    foundDv = true
                } else if (nalType == 39 || nalType == 40) && nalLen > 2 {
                    let rbsp = unescapeRbsp(data, offset: pos + 2, length: nalLen - 2, maxBytes: 4096)
                    inspectHevcSeiRbsp(
                        rbsp,
                        foundHdr10Plus: &foundHdr10Plus,
                        foundHlg: &foundHlg,
                        foundHdr10Meta: &foundHdr10Meta
                    )
                }
                pos += nalLen
            }
        }

        if foundDv { return .dv }
        if foundHdr10Plus { return .hdr10Plus }
        if foundHlg { return .hlg }
        if foundHdr10Meta { return .hdr10 }
        return nil
    }

    /// Inspects an `AV1CodecConfigurationRecord` (`av1C`) for OBU_METADATA ITU-T T.35
    /// SMPTE ST 2094-40 (HDR10+) or HDR MDCV/CLL metadata.
    static func inspectAv1ConfigurationRecord(_ data: Data) -> DetectedHdr? {
        guard data.count > 4, let b0 = data.probeUInt8(at: 0) else { return nil }
        // marker (1 bit == 1) and version (7 bits == 1)
        guard (b0 & 0x80) != 0, (b0 & 0x7F) == 1 else { return nil }

        var foundHdr10Plus = false
        var foundHdr10Meta = false
        var pos = 4
        var obuCount = 0

        while pos < data.count && obuCount < 32 {
            obuCount += 1
            guard let hdr = data.probeUInt8(at: pos) else { break }
            let obuType = (hdr >> 3) & 0x0F
            let hasExtension = (hdr & 0x04) != 0
            let hasSizeField = (hdr & 0x02) != 0
            let headerBytes = 1 + (hasExtension ? 1 : 0)
            guard data.hasRange(offset: pos, length: headerBytes) else { break }
            pos += headerBytes

            let obuSize: Int
            if hasSizeField {
                guard let (sz, lebLen) = readLeb128(data, at: pos) else { break }
                pos += lebLen
                obuSize = sz
            } else {
                obuSize = data.count - pos
            }
            guard data.hasRange(offset: pos, length: obuSize) else { break }

            if obuType == 5 && obuSize > 0 {
                if let (metaType, metaLen) = readLeb128(data, at: pos), metaLen <= obuSize {
                    let payloadOff = pos + metaLen
                    let payloadLen = obuSize - metaLen
                    if metaType == 4 && isSmpte2094_40(data, offset: payloadOff, length: payloadLen) {
                        foundHdr10Plus = true
                    } else if metaType == 1 || metaType == 2 {
                        foundHdr10Meta = true
                    }
                }
            }
            pos += obuSize
        }

        if foundHdr10Plus { return .hdr10Plus }
        if foundHdr10Meta { return .hdr10 }
        return nil
    }

    private static func unescapeRbsp(_ data: Data, offset: Int, length: Int, maxBytes: Int) -> [UInt8] {
        guard data.hasRange(offset: offset, length: length) else { return [] }
        let cap = min(length, maxBytes)
        var out: [UInt8] = []
        out.reserveCapacity(cap)
        let base = data.startIndex + offset
        var zeroRun = 0
        for i in 0..<cap {
            let b = data[base + i]
            if zeroRun >= 2 && b == 0x03 {
                zeroRun = 0
                continue
            }
            out.append(b)
            if b == 0 {
                zeroRun += 1
            } else {
                zeroRun = 0
            }
        }
        return out
    }

    private static func inspectHevcSeiRbsp(
        _ rbsp: [UInt8],
        foundHdr10Plus: inout Bool,
        foundHlg: inout Bool,
        foundHdr10Meta: inout Bool
    ) {
        var pos = 0
        var msgCount = 0
        while pos < rbsp.count && msgCount < 32 {
            msgCount += 1
            if rbsp[pos] == 0x80 && pos == rbsp.count - 1 { break } // rbsp_trailing_bits

            var payloadType = 0
            while pos < rbsp.count && rbsp[pos] == 0xFF {
                payloadType += 255
                pos += 1
                if payloadType > 65535 { return }
            }
            guard pos < rbsp.count else { break }
            payloadType += Int(rbsp[pos])
            pos += 1

            var payloadSize = 0
            while pos < rbsp.count && rbsp[pos] == 0xFF {
                payloadSize += 255
                pos += 1
                if payloadSize > rbsp.count { return }
            }
            guard pos < rbsp.count else { break }
            payloadSize += Int(rbsp[pos])
            pos += 1

            guard payloadSize >= 0, payloadSize <= rbsp.count - pos else { break }

            if payloadType == 4 && isSmpte2094_40(rbsp, offset: pos, length: payloadSize) {
                foundHdr10Plus = true
            } else if payloadType == 137 || payloadType == 144 {
                foundHdr10Meta = true
            } else if payloadType == 147 && payloadSize >= 1 && rbsp[pos] == 18 {
                foundHlg = true
            }

            pos += payloadSize
        }
    }

    private static func isSmpte2094_40(_ bytes: [UInt8], offset: Int, length: Int) -> Bool {
        guard offset >= 0, length >= 6, length <= bytes.count - offset else { return false }
        // ITU-T T.35: country_code=0xB5 (USA), provider=0x003C, oriented=0x0001, app_id=0x04
        return bytes[offset] == 0xB5
            && bytes[offset + 1] == 0x00
            && bytes[offset + 2] == 0x3C
            && bytes[offset + 3] == 0x00
            && bytes[offset + 4] == 0x01
            && bytes[offset + 5] == 0x04
    }

    private static func isSmpte2094_40(_ data: Data, offset: Int, length: Int) -> Bool {
        guard data.hasRange(offset: offset, length: length), length >= 6 else { return false }
        let s = data.startIndex + offset
        return data[s] == 0xB5
            && data[s + 1] == 0x00
            && data[s + 2] == 0x3C
            && data[s + 3] == 0x00
            && data[s + 4] == 0x01
            && data[s + 5] == 0x04
    }

    private static func readLeb128(_ data: Data, at offset: Int) -> (Int, Int)? {
        var value: UInt64 = 0
        for i in 0..<8 {
            guard let b = data.probeUInt8(at: offset + i) else { return nil }
            value |= UInt64(b & 0x7F) << (i * 7)
            if (b & 0x80) == 0 {
                guard value <= UInt64(Int.max) else { return nil }
                return (Int(value), i + 1)
            }
        }
        return nil
    }
}

extension Data {
    @inline(__always)
    func hasRange(offset: Int, length: Int) -> Bool {
        offset >= 0 && length >= 0 && length <= count && offset <= count - length
    }

    @inline(__always)
    func probeUInt8(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else { return nil }
        return self[startIndex + offset]
    }

    @inline(__always)
    func probeUInt16BE(at offset: Int) -> UInt16? {
        guard hasRange(offset: offset, length: 2) else { return nil }
        let s = startIndex + offset
        return (UInt16(self[s]) << 8) | UInt16(self[s + 1])
    }

    @inline(__always)
    func probeUInt32BE(at offset: Int) -> UInt32? {
        guard hasRange(offset: offset, length: 4) else { return nil }
        let s = startIndex + offset
        return (UInt32(self[s]) << 24)
            | (UInt32(self[s + 1]) << 16)
            | (UInt32(self[s + 2]) << 8)
            | UInt32(self[s + 3])
    }

    @inline(__always)
    func probeUInt64BE(at offset: Int) -> UInt64? {
        guard let hi = probeUInt32BE(at: offset),
              let lo = probeUInt32BE(at: offset + 4) else { return nil }
        return (UInt64(hi) << 32) | UInt64(lo)
    }

    func probeVarUIntBE(at offset: Int, length: Int) -> UInt64? {
        guard hasRange(offset: offset, length: length), length <= 8 else { return nil }
        let s = startIndex + offset
        var v: UInt64 = 0
        for i in 0..<length {
            v = (v << 8) | UInt64(self[s + i])
        }
        return v
    }

    func probeFloatBE(at offset: Int, length: Int) -> Double? {
        if length == 0 { return 0.0 }
        if length == 4 {
            guard let bits = probeUInt32BE(at: offset) else { return nil }
            return Double(Float(bitPattern: bits))
        }
        if length == 8 {
            guard let bits = probeUInt64BE(at: offset) else { return nil }
            return Double(bitPattern: bits)
        }
        return nil
    }

    func probeUTF8TrimmingNulls(at offset: Int, length: Int) -> String? {
        guard hasRange(offset: offset, length: length) else { return nil }
        let s = startIndex + offset
        var e = s + length
        while e > s && self[e - 1] == 0 {
            e -= 1
        }
        return String(decoding: self[s..<e], as: UTF8.self)
    }

    func probeFourCC(at offset: Int) -> String? {
        guard hasRange(offset: offset, length: 4) else { return nil }
        let s = startIndex + offset
        let b0 = self[s]
        let b1 = self[s + 1]
        let b2 = self[s + 2]
        let b3 = self[s + 3]
        guard (0x20...0x7E).contains(b0),
              (0x20...0x7E).contains(b1),
              (0x20...0x7E).contains(b2),
              (0x20...0x7E).contains(b3) else {
            return nil
        }
        return String(bytes: [b0, b1, b2, b3], encoding: .ascii)
    }

    func probeSlice(offset: Int, end: Int) -> Data? {
        guard offset >= 0, end >= offset, end <= count else { return nil }
        return self[(startIndex + offset)..<(startIndex + end)]
    }
}
