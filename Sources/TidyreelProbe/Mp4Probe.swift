import Foundation
import TidyreelModels

/// ISO-BMFF (MP4 / MOV / M4V) binary container header prober.
public enum Mp4Probe {
    private static let maxTopBoxes = 64
    private static let topBoxStepRead = 64 * 1024
    private static let maxTailRead = 256 * 1024
    private static let maxSafeSize: Int64 = 0x00FF_FFFF_FFFF_FF00

    private static let validTopLevelTypes: Set<String> = [
        "ftyp",
        "moov",
        "mdat",
        "free",
        "skip",
        "wide",
        "pnot",
        "moof",
        "meta",
        "styp",
        "pdin",
    ]

    private static let moovChildTypes: Set<String> = [
        "mvhd",
        "trak",
        "udta",
        "iods",
        "mvex",
        "meta",
        "pssh",
        "cmov",
    ]

    /// Whether `head` looks like an ISO-BMFF (MP4 / MOV / M4V) container.
    public static func isLikelyMp4(_ head: Data, ext: String?) -> Bool {
        guard head.count >= 8, let type = head.probeFourCC(at: 4) else {
            return false
        }
        if type == "ftyp" { return true }
        // Older QuickTime MOV files may start with wide/mdat/moov/free without ftyp.
        if ext == "mov" || ext == "mp4" || ext == "m4v" {
            return validTopLevelTypes.contains(type)
        }
        return false
    }

    /// Probes an MP4 / MOV / M4V (ISO-BMFF) container using `reader`.
    public static func probe(
        reader: inout ProbeRangeReader,
        head: Data,
        ext: String?,
        fileSize: Int64?
    ) async -> MediaProbeInfo? {
        reader.seed(start: 0, bytes: head)

        var majorBrand: String?
        var moovBytes: Data?

        var pos: Int64 = 0
        for _ in 0..<maxTopBoxes {
            if let fileSize, pos >= fileSize { break }
            guard let win = await reader.window(
                offset: pos,
                minLength: 16,
                preferredLength: topBoxStepRead
            ), win.count >= 8 else {
                break
            }

            guard let hdr = readBoxHeader(
                win,
                offset: 0,
                end: win.count,
                absOffset: pos,
                totalEnd: fileSize
            ) else {
                break
            }

            guard pos <= Int64.max - Int64(hdr.headerSize) else { break }
            let payloadStart = pos + Int64(hdr.headerSize)

            if hdr.type == "ftyp" && majorBrand == nil && win.count >= hdr.headerSize + 4 {
                majorBrand = win.probeFourCC(at: hdr.headerSize)
            }

            if hdr.type == "moov" {
                let alreadyHave = max(0, win.count - hdr.headerSize)
                let maxPossible = Int64(alreadyHave) + Int64(reader.remaining)
                let remainingBox: Int64
                if let boxSize = hdr.boxSize {
                    remainingBox = boxSize - Int64(hdr.headerSize)
                } else if let fileSize {
                    remainingBox = fileSize - payloadStart
                } else {
                    remainingBox = maxPossible
                }
                if remainingBox <= 0 { break }
                let want64 = min(remainingBox, maxPossible)
                if want64 <= 0 || want64 > Int64(Int.max) { break }
                let want = Int(want64)

                if let moovWin = await reader.window(
                    offset: payloadStart,
                    minLength: want,
                    preferredLength: want
                ), !moovWin.isEmpty {
                    let len = min(want, moovWin.count)
                    moovBytes = moovWin.probeSlice(offset: 0, end: len)
                }
                break
            }

            guard let boxSize = hdr.boxSize,
                  boxSize > 0,
                  boxSize <= maxSafeSize,
                  pos <= Int64.max - boxSize else {
                break
            }
            let nextPos = pos + boxSize
            if nextPos <= pos { break }
            pos = nextPos
        }

        // Fallback for trailing moov when top-level walking could not reach it
        // (e.g. mdat had size == 0 or malformed box sizes) and fileSize is known.
        if moovBytes == nil, let fileSize, fileSize > 16 {
            let tailWant = min(fileSize, Int64(maxTailRead))
            let tailCap = min(Int(tailWant), reader.remaining)
            if tailCap >= 16 {
                let tailStart = fileSize - Int64(tailCap)
                if let tail = await reader.readRaw(start: tailStart, length: tailCap),
                   tail.count >= 16 {
                    moovBytes = scanForMoov(tail)
                }
            }
        }

        guard let moovBytes, !moovBytes.isEmpty else { return nil }

        var parsed = Mp4Result()
        parseMoov(moovBytes, start: 0, end: moovBytes.count, out: &parsed)
        guard parsed.hasAnyMetadata else { return nil }

        let container: String
        switch ext {
        case "mov":
            container = "mov"
        case "mp4", "m4v":
            container = "mp4"
        default:
            container = (majorBrand == "qt  ") ? "mov" : "mp4"
        }

        return MediaProbeInfo(
            width: parsed.width,
            height: parsed.height,
            videoCodec: parsed.videoCodec,
            hdr: parsed.hdr,
            audioCodec: parsed.audioCodec,
            audioChannels: parsed.audioChannels,
            durationMs: parsed.durationMs,
            container: container
        )
    }

    // MARK: - Box Walking & Track Parsing

    private struct Mp4Result {
        var width: Int?
        var height: Int?
        var videoCodec: String?
        var hdr: String?
        var audioCodec: String?
        var audioChannels: Int?
        var durationMs: Int64?

        var videoFound = false
        var bestAudioRank = -1

        var hasAnyMetadata: Bool {
            width != nil
                || height != nil
                || videoCodec != nil
                || hdr != nil
                || audioCodec != nil
                || audioChannels != nil
                || durationMs != nil
        }
    }

    private struct BoxHeader {
        let type: String
        let headerSize: Int
        let boxSize: Int64?
    }

    private struct TrackContext {
        var tkhdWidth: Int?
        var tkhdHeight: Int?
        var handlerType: String?
        var stsdRanges: [(start: Int, end: Int)] = []
    }

    private static func readBoxHeader(
        _ data: Data,
        offset: Int,
        end: Int,
        absOffset: Int64,
        totalEnd: Int64?
    ) -> BoxHeader? {
        guard offset >= 0, end <= data.count, end - offset >= 8 else { return nil }
        guard let size32 = data.probeUInt32BE(at: offset),
              let type = data.probeFourCC(at: offset + 4) else {
            return nil
        }

        var headerSize = 8
        let boxSize: Int64?
        if size32 == 1 {
            guard end - offset >= 16,
                  let hi = data.probeUInt32BE(at: offset + 8),
                  let lo = data.probeUInt32BE(at: offset + 12),
                  hi <= 0x7FFF_FFFF else {
                return nil
            }
            let sz = (Int64(hi) << 32) | Int64(lo)
            guard sz >= 16 else { return nil }
            boxSize = sz
            headerSize = 16
        } else if size32 == 0 {
            if let totalEnd {
                guard totalEnd >= absOffset else { return nil }
                let sz = totalEnd - absOffset
                guard sz >= 8 else { return nil }
                boxSize = sz
            } else {
                boxSize = nil
            }
        } else if size32 >= 8 {
            boxSize = Int64(size32)
        } else {
            return nil
        }

        if type == "uuid" {
            if let boxSize, boxSize < Int64(headerSize + 16) {
                return nil
            }
            headerSize += 16
        }
        return BoxHeader(type: type, headerSize: headerSize, boxSize: boxSize)
    }

    private static func scanForMoov(_ tail: Data) -> Data? {
        guard tail.count >= 16 else { return nil }
        let base = tail.startIndex
        for i in 4...(tail.count - 12) {
            if tail[base + i] == 0x6D
                && tail[base + i + 1] == 0x6F
                && tail[base + i + 2] == 0x6F
                && tail[base + i + 3] == 0x76 {
                let boxStart = i - 4
                guard let hdr = readBoxHeader(
                    tail,
                    offset: boxStart,
                    end: tail.count,
                    absOffset: Int64(boxStart),
                    totalEnd: Int64(tail.count)
                ),
                let boxSize = hdr.boxSize,
                boxSize <= Int64(tail.count - boxStart) else {
                    continue
                }
                let payloadStart = boxStart + hdr.headerSize
                let boxEnd = boxStart + Int(boxSize)
                guard payloadStart <= boxEnd - 8 else { continue }
                if let firstChildType = tail.probeFourCC(at: payloadStart + 4),
                   moovChildTypes.contains(firstChildType) {
                    return tail.probeSlice(offset: payloadStart, end: boxEnd)
                }
            }
        }
        return nil
    }

    private static func walkBoxes(
        _ data: Data,
        start: Int,
        end: Int,
        allowTruncatedContainer: Bool = false,
        _ onBox: (String, Int, Int) -> Void
    ) {
        var pos = start
        var count = 0
        while pos <= end - 8 && count < 512 {
            count += 1
            guard let hdr = readBoxHeader(
                data,
                offset: pos,
                end: end,
                absOffset: Int64(pos),
                totalEnd: Int64(end)
            ) else {
                break
            }
            guard hdr.headerSize <= end - pos else { break }
            let payloadStart = pos + hdr.headerSize

            let boxEnd: Int
            if let bs = hdr.boxSize {
                if bs > Int64(end - pos) {
                    if allowTruncatedContainer && payloadStart < end {
                        onBox(hdr.type, payloadStart, end)
                    }
                    break
                }
                boxEnd = pos + Int(bs)
            } else {
                boxEnd = end
            }
            guard boxEnd >= payloadStart else { break }
            onBox(hdr.type, payloadStart, boxEnd)
            pos = boxEnd
        }
    }

    private static func parseMoov(_ data: Data, start: Int, end: Int, out: inout Mp4Result) {
        walkBoxes(data, start: start, end: end, allowTruncatedContainer: true) { type, pStart, pEnd in
            if type == "mvhd" {
                parseMvhd(data, start: pStart, end: pEnd, out: &out)
            } else if type == "trak" {
                parseTrak(data, start: pStart, end: pEnd, out: &out)
            }
        }
    }

    private static func parseMvhd(_ data: Data, start: Int, end: Int, out: inout Mp4Result) {
        let len = end - start
        guard len >= 20, let version = data.probeUInt8(at: start) else { return }
        let timescale: UInt64
        let durationUnits: UInt64
        if version == 0 {
            guard let ts = data.probeUInt32BE(at: start + 12),
                  let dur = data.probeUInt32BE(at: start + 16),
                  dur != 0xFFFF_FFFF else {
                return
            }
            timescale = UInt64(ts)
            durationUnits = UInt64(dur)
        } else if version == 1 {
            guard len >= 32,
                  let ts = data.probeUInt32BE(at: start + 20),
                  let hi = data.probeUInt32BE(at: start + 24),
                  let lo = data.probeUInt32BE(at: start + 28) else {
                return
            }
            if hi == 0xFFFF_FFFF && lo == 0xFFFF_FFFF { return }
            if hi > 0x7FFF_FFFF { return }
            timescale = UInt64(ts)
            durationUnits = (UInt64(hi) << 32) | UInt64(lo)
        } else {
            return
        }

        guard timescale > 0, durationUnits > 0 else { return }
        let msDouble = (Double(durationUnits) * 1000.0) / Double(timescale)
        if msDouble.isFinite && msDouble > 0 && msDouble < 1e12 {
            let ms = Int64(msDouble.rounded())
            if ms > 0 {
                out.durationMs = ms
            }
        }
    }

    private static func parseTkhd(_ data: Data, start: Int, end: Int, ctx: inout TrackContext) {
        let len = end - start
        guard len >= 84, let version = data.probeUInt8(at: start) else { return }
        let widthOffset: Int
        let heightOffset: Int
        if version == 0 {
            widthOffset = start + 76
            heightOffset = start + 80
        } else if version == 1 {
            guard len >= 96 else { return }
            widthOffset = start + 88
            heightOffset = start + 92
        } else {
            return
        }
        if let wFixed = data.probeUInt32BE(at: widthOffset) {
            let w = Int(wFixed >> 16)
            if w > 0 { ctx.tkhdWidth = w }
        }
        if let hFixed = data.probeUInt32BE(at: heightOffset) {
            let h = Int(hFixed >> 16)
            if h > 0 { ctx.tkhdHeight = h }
        }
    }

    private static func parseTrak(_ data: Data, start: Int, end: Int, out: inout Mp4Result) {
        var ctx = TrackContext()
        walkBoxes(data, start: start, end: end, allowTruncatedContainer: true) { type, pStart, pEnd in
            if type == "tkhd" {
                parseTkhd(data, start: pStart, end: pEnd, ctx: &ctx)
            } else if type == "mdia" {
                walkBoxes(data, start: pStart, end: pEnd, allowTruncatedContainer: true) { mType, mStart, mEnd in
                    if mType == "hdlr" && mEnd - mStart >= 12 {
                        ctx.handlerType = data.probeFourCC(at: mStart + 8)
                    } else if mType == "minf" {
                        walkBoxes(data, start: mStart, end: mEnd, allowTruncatedContainer: true) { iType, iStart, iEnd in
                            if iType == "stbl" {
                                walkBoxes(data, start: iStart, end: iEnd, allowTruncatedContainer: true) { sType, sStart, sEnd in
                                    if sType == "stsd" {
                                        ctx.stsdRanges.append((sStart, sEnd))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if let ht = ctx.handlerType, ht != "vide" && ht != "soun" {
            return
        }
        for range in ctx.stsdRanges {
            parseStsd(data, start: range.start, end: range.end, ctx: ctx, out: &out)
        }
    }

    private static func parseStsd(
        _ data: Data,
        start: Int,
        end: Int,
        ctx: TrackContext,
        out: inout Mp4Result
    ) {
        guard end - start >= 8,
              let rawCount = data.probeUInt32BE(at: start + 4) else {
            return
        }
        let entryCount = Int(min(rawCount, 16))
        var pos = start + 8
        for _ in 0..<entryCount {
            guard pos <= end - 8,
                  let hdr = readBoxHeader(
                      data,
                      offset: pos,
                      end: end,
                      absOffset: Int64(pos),
                      totalEnd: Int64(end)
                  ),
                  let boxSize = hdr.boxSize,
                  boxSize <= Int64(end - pos),
                  hdr.headerSize <= Int(boxSize) else {
                break
            }
            let entryStart = pos + hdr.headerSize
            let entryEnd = pos + Int(boxSize)
            parseSampleEntry(
                type: hdr.type,
                data: data,
                start: entryStart,
                end: entryEnd,
                ctx: ctx,
                out: &out
            )
            pos = entryEnd
        }
    }

    private static func parseSampleEntry(
        type: String,
        data: Data,
        start: Int,
        end: Int,
        ctx: TrackContext,
        out: inout Mp4Result
    ) {
        let allowVideo = ctx.handlerType == nil || ctx.handlerType == "vide"
        let allowAudio = ctx.handlerType == nil || ctx.handlerType == "soun"

        if allowVideo, let video = mapVideoSampleType(type) {
            if out.videoFound { return }
            let len = end - start
            guard len >= 28,
                  let rawWidth = data.probeUInt16BE(at: start + 24),
                  let rawHeight = data.probeUInt16BE(at: start + 26) else {
                return
            }
            let width = rawWidth > 0 ? Int(rawWidth) : ctx.tkhdWidth
            let height = rawHeight > 0 ? Int(rawHeight) : ctx.tkhdHeight

            var hasDvBox = (video.hdr == "DV")
            var colrHdr: String?
            var hasMdcvOrClli = false
            var configHdr: DetectedHdr?

            if len > 78 {
                walkBoxes(data, start: start + 78, end: end) { childType, cStart, cEnd in
                    switch childType {
                    case "dvcC", "dvvC", "dvwC":
                        hasDvBox = true
                    case "colr":
                        if let parsedColr = parseColr(data, start: cStart, end: cEnd), colrHdr == nil {
                            colrHdr = parsedColr
                        }
                    case "mdcv":
                        if cEnd - cStart >= 24 {
                            hasMdcvOrClli = true
                        }
                    case "clli":
                        if cEnd - cStart >= 4, let maxCll = data.probeUInt16BE(at: cStart), maxCll > 0 {
                            hasMdcvOrClli = true
                        }
                    case "hvcC":
                        if let sub = data.probeSlice(offset: cStart, end: cEnd) {
                            configHdr = CodecPrivateHdrInspector.inspectHevcConfigurationRecord(sub)
                        }
                    case "av1C":
                        if let sub = data.probeSlice(offset: cStart, end: cEnd) {
                            configHdr = CodecPrivateHdrInspector.inspectAv1ConfigurationRecord(sub)
                        }
                    default:
                        break
                    }
                }
            }

            let resolvedHdr: String?
            if hasDvBox || configHdr == .dv {
                resolvedHdr = "DV"
            } else if configHdr == .hdr10Plus {
                resolvedHdr = "HDR10+"
            } else if let colrHdr {
                resolvedHdr = colrHdr
            } else if configHdr == .hlg {
                resolvedHdr = "HLG"
            } else if hasMdcvOrClli || configHdr == .hdr10 {
                resolvedHdr = "HDR10"
            } else {
                resolvedHdr = video.hdr
            }

            out.videoFound = true
            out.videoCodec = video.codec
            out.width = width
            out.height = height
            out.hdr = resolvedHdr
            return
        }

        if allowAudio, var audioCodec = mapAudioSampleType(type) {
            let len = end - start
            guard len >= 20, let version = data.probeUInt16BE(at: start + 8) else { return }

            var channels: Int?
            let childOffset: Int
            if version == 2 && len >= 64 {
                if let ch = data.probeUInt32BE(at: start + 40), ch > 0, ch <= 64 {
                    channels = Int(ch)
                }
                childOffset = 64
            } else if version == 1 && len >= 44 {
                if let ch = data.probeUInt16BE(at: start + 16), ch > 0 {
                    channels = Int(ch)
                }
                childOffset = 44
            } else {
                if let ch = data.probeUInt16BE(at: start + 16), ch > 0 {
                    channels = Int(ch)
                }
                childOffset = 28
            }

            if len > childOffset {
                walkBoxes(data, start: start + childOffset, end: end) { childType, cStart, cEnd in
                    if childType == "dec3" {
                        let dec3 = parseDec3(data, start: cStart, end: cEnd)
                        if dec3.isAtmos && (audioCodec == "EAC3" || audioCodec == "AC3") {
                            audioCodec = "Atmos"
                        }
                        if (channels == nil || channels == 0), let decCh = dec3.channels {
                            channels = decCh
                        }
                    } else if childType == "dac3" {
                        if (channels == nil || channels == 0), let dacCh = parseDac3Channels(data, start: cStart, end: cEnd) {
                            channels = dacCh
                        }
                    } else if childType == "dOps" {
                        if (channels == nil || channels == 0), cEnd - cStart >= 2, let opCh = data.probeUInt8(at: cStart + 1), opCh > 0 {
                            channels = Int(opCh)
                        }
                    }
                }
            }

            let rank = audioCodecRank(audioCodec)
            if out.bestAudioRank < 0 || rank > out.bestAudioRank {
                out.bestAudioRank = rank
                out.audioCodec = audioCodec
                out.audioChannels = channels
            }
        }
    }

    private static func parseColr(_ data: Data, start: Int, end: Int) -> String? {
        guard end - start >= 8,
              let colourType = data.probeFourCC(at: start),
              colourType == "nclx" || colourType == "nclc",
              let transfer = data.probeUInt16BE(at: start + 6) else {
            return nil
        }
        switch transfer {
        case 16: return "HDR10"
        case 18: return "HLG"
        default: return nil
        }
    }

    /// Parses an `EC3SpecificBox` (`dec3`) per ETSI TS 102 366 Annex F.6 and
    /// Dolby Digital Plus JOC (Atmos) signaling.
    private static func parseDec3(
        _ data: Data,
        start: Int,
        end: Int
    ) -> (isAtmos: Bool, channels: Int?) {
        let acmodChannels = [2, 1, 2, 3, 3, 4, 4, 5]
        guard end - start >= 5, let b1 = data.probeUInt8(at: start + 1) else {
            return (false, nil)
        }

        let numIndSub = Int(b1 & 0x07) + 1
        var p = start + 2
        var channels: Int?

        for i in 0..<numIndSub {
            guard p <= end - 3,
                  let sub1 = data.probeUInt8(at: p + 1),
                  let sub2 = data.probeUInt8(at: p + 2) else {
                return (false, channels)
            }
            if i == 0 {
                let acmod = Int((sub1 >> 1) & 0x07)
                let lfeon = Int(sub1 & 0x01)
                channels = acmodChannels[acmod] + lfeon
            }
            let numDepSub = (sub2 >> 1) & 0x0F
            p += numDepSub > 0 ? 4 : 3
        }

        let isAtmos: Bool
        if p < end, let extByte = data.probeUInt8(at: p) {
            isAtmos = (extByte & 0x01) != 0
        } else {
            isAtmos = false
        }
        return (isAtmos, channels)
    }

    private static func parseDac3Channels(_ data: Data, start: Int, end: Int) -> Int? {
        let acmodChannels = [2, 1, 2, 3, 3, 4, 4, 5]
        guard end - start >= 3, let b1 = data.probeUInt8(at: start + 1) else { return nil }
        // fscod(2) + bsid(5) + bsmod(3) = 10 bits -> acmod(3) at bits 10..12, lfeon(1) at bit 13
        let acmod = Int((b1 >> 3) & 0x07)
        let lfeon = Int((b1 >> 2) & 0x01)
        return acmodChannels[acmod] + lfeon
    }

    private static func mapVideoSampleType(_ type: String) -> (codec: String, hdr: String?)? {
        switch type {
        case "avc1", "avc3": return ("H.264", nil)
        case "hvc1", "hev1": return ("HEVC", nil)
        case "av01": return ("AV1", nil)
        case "vp09": return ("VP9", nil)
        case "vp08": return ("VP8", nil)
        case "dvh1", "dvhe": return ("HEVC", "DV")
        case "dvav", "dva1": return ("H.264", "DV")
        case "dav1": return ("AV1", "DV")
        case "m2v1": return ("MPEG-2", nil)
        default: return nil
        }
    }

    private static func mapAudioSampleType(_ type: String) -> String? {
        switch type {
        case "mp4a": return "AAC"
        case "ac-3": return "AC3"
        case "ec-3": return "EAC3"
        case "mlpa": return "TrueHD"
        case "Opus": return "Opus"
        case "fLaC": return "FLAC"
        case "dtsc", "dtse": return "DTS"
        case "dtsh", "dtsl": return "DTS-HD"
        case "dtsx": return "DTS-X"
        default: return nil
        }
    }
}
