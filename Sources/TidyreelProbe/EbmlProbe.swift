import Foundation
import TidyreelModels

/// EBML / Matroska (MKV) / WebM binary container header prober.
public enum EbmlProbe {
    // EBML / Matroska element IDs (with VINT marker bits retained).
    private static let idEbml: UInt32 = 0x1A45_DFA3
    private static let idDocType: UInt32 = 0x4282
    private static let idSegment: UInt32 = 0x1853_8067
    private static let idSeekHead: UInt32 = 0x114D_9B74
    private static let idSeek: UInt32 = 0x4DBB
    private static let idSeekId: UInt32 = 0x53AB
    private static let idSeekPosition: UInt32 = 0x53AC
    private static let idInfo: UInt32 = 0x1549_A966
    private static let idTimestampScale: UInt32 = 0x2AD7B1
    private static let idDuration: UInt32 = 0x4489
    private static let idTracks: UInt32 = 0x1654_AE6B
    private static let idTrackEntry: UInt32 = 0xAE
    private static let idTrackType: UInt32 = 0x83
    private static let idCodecId: UInt32 = 0x86
    private static let idCodecPrivate: UInt32 = 0x63A2
    private static let idTrackName: UInt32 = 0x536E
    private static let idVideo: UInt32 = 0xE0
    private static let idPixelWidth: UInt32 = 0xB0
    private static let idPixelHeight: UInt32 = 0xBA
    private static let idDisplayWidth: UInt32 = 0x54B0
    private static let idDisplayHeight: UInt32 = 0x54BA
    private static let idDisplayUnit: UInt32 = 0x54B2
    private static let idColour: UInt32 = 0x55B0
    private static let idTransferCharacteristics: UInt32 = 0x55BA
    private static let idPrimaries: UInt32 = 0x55BB
    private static let idMaxCLL: UInt32 = 0x55BC
    private static let idMaxFALL: UInt32 = 0x55BD
    private static let idMasteringMetadata: UInt32 = 0x55D0
    private static let idBlockAdditionMapping: UInt32 = 0x41E4
    private static let idBlockAddIdType: UInt32 = 0x41E7
    private static let idAudio: UInt32 = 0xE1
    private static let idChannels: UInt32 = 0x9F
    private static let idCluster: UInt32 = 0x1F43_B675
    private static let idVoid: UInt32 = 0xEC
    private static let idCrc32: UInt32 = 0xBF

    private static let dvccType: UInt64 = 0x6476_6343 // 'dvcC'
    private static let dvvcType: UInt64 = 0x6476_7643 // 'dvvC'
    private static let dvwcType: UInt64 = 0x6476_7743 // 'dvwC'

    private static let maxTopElements = 64
    private static let maxSeekHeadSize = 64 * 1024
    private static let maxInfoSize = 64 * 1024
    private static let maxTracksSize = 256 * 1024
    private static let maxSafeSize: Int64 = 0x00FF_FFFF_FFFF_FF00

    private static let dtsXRegex = try! NSRegularExpression(
        pattern: #"dts[\s:_-]*x(?![a-z0-9])"#,
        options: [.caseInsensitive]
    )
    private static let dtsHdRegex = try! NSRegularExpression(
        pattern: #"dts[\s:_-]*hd|\bma\b|master\s*audio"#,
        options: [.caseInsensitive]
    )
    private static let hdr10PlusRegex = try! NSRegularExpression(
        pattern: #"hdr\s*10\s*\+|hdr10plus|smpte\s*2094"#,
        options: [.caseInsensitive]
    )

    /// Probes an MKV / WebM (EBML) container using `reader`.
    ///
    /// `head` must already start with the EBML magic bytes `1A 45 DF A3`.
    public static func probe(
        reader: inout ProbeRangeReader,
        head: Data,
        ext: String?,
        fileSize: Int64?
    ) async -> MediaProbeInfo? {
        reader.seed(start: 0, bytes: head)

        guard let ebmlHeader = readElementHeader(head, offset: 0, end: head.count),
              ebmlHeader.id == idEbml,
              let ebmlSize64 = ebmlHeader.size,
              ebmlSize64 >= 0,
              ebmlSize64 <= Int64(maxInfoSize) else {
            return nil
        }
        let ebmlSize = Int(ebmlSize64)
        let ebmlDataStart = ebmlHeader.headerLen

        let docType: String?
        if ebmlSize == 0 {
            docType = nil
        } else {
            guard let ebmlData = await reader.window(
                offset: Int64(ebmlDataStart),
                minLength: ebmlSize
            ) else {
                return nil
            }
            docType = parseDocType(
                ebmlData,
                start: 0,
                end: min(ebmlSize, ebmlData.count)
            )
        }

        // Locate the Segment element (skipping optional Void / CRC-32 elements).
        var pos = Int64(ebmlDataStart + ebmlSize)
        var segmentDataStart: Int64?
        var segmentEnd: Int64?
        for _ in 0..<16 {
            guard let win = await reader.window(offset: pos, minLength: 16),
                  win.count >= 2,
                  let hdr = readElementHeader(win, offset: 0, end: win.count) else {
                return nil
            }
            if hdr.id == idSegment {
                let sStart = pos + Int64(hdr.headerLen)
                segmentDataStart = sStart
                if let segSize = hdr.size,
                   segSize >= 0,
                   segSize <= maxSafeSize,
                   sStart <= Int64.max - segSize {
                    segmentEnd = sStart + segSize
                }
                break
            }
            if (hdr.id == idVoid || hdr.id == idCrc32),
               let skipSize = hdr.size,
               skipSize >= 0,
               skipSize <= maxSafeSize,
               pos <= Int64.max - Int64(hdr.headerLen) - skipSize {
                let next = pos + Int64(hdr.headerLen) + skipSize
                guard next > pos else { return nil }
                pos = next
                continue
            }
            return nil
        }
        guard let segStart = segmentDataStart else { return nil }

        var parsed = EbmlResult()
        var seekTargets: [UInt32: Int64] = [:]
        var secondarySeekHeads: [Int64] = []

        // Sequential scan from Segment start until both Info and Tracks are parsed
        // or the first Cluster is encountered.
        var cursor = segStart
        for _ in 0..<maxTopElements {
            if let segmentEnd, cursor >= segmentEnd { break }
            if let fileSize, cursor >= fileSize { break }
            guard let win = await reader.window(offset: cursor, minLength: 16),
                  win.count >= 2,
                  let hdr = readElementHeader(win, offset: 0, end: win.count) else {
                break
            }
            if hdr.id == idCluster { break }

            let dataStart = cursor + Int64(hdr.headerLen)
            if hdr.id == idSeekHead,
               let sz = hdr.size,
               sz > 0,
               sz <= Int64(maxSeekHeadSize) {
                let want = Int(sz)
                if let payload = await reader.window(offset: dataStart, minLength: want) {
                    parseSeekHead(
                        payload,
                        start: 0,
                        end: min(want, payload.count),
                        segmentDataStart: segStart,
                        targets: &seekTargets,
                        secondarySeekHeads: &secondarySeekHeads
                    )
                }
            } else if hdr.id == idInfo && !parsed.infoSeen {
                let want = cappedWant(hdr.size, maxCap: maxInfoSize)
                if want > 0, let payload = await reader.window(offset: dataStart, minLength: want) {
                    parseInfo(payload, start: 0, end: min(want, payload.count), out: &parsed)
                    parsed.infoSeen = true
                }
            } else if hdr.id == idTracks && !parsed.tracksSeen {
                let want = cappedWant(hdr.size, maxCap: maxTracksSize)
                if want > 0,
                   let payload = await reader.window(
                       offset: dataStart,
                       minLength: want,
                       preferredLength: max(want, 64 * 1024)
                   ) {
                    parseTracks(payload, start: 0, end: min(want, payload.count), out: &parsed)
                    parsed.tracksSeen = true
                }
            }

            if parsed.infoSeen && parsed.tracksSeen { break }
            guard let sz = hdr.size,
                  sz >= 0,
                  sz <= maxSafeSize,
                  dataStart <= Int64.max - sz else {
                break
            }
            let nextCursor = dataStart + sz
            if nextCursor <= cursor { break }

            // If SeekHead already gave offsets for all missing sections and the next sequential
            // element lies beyond our buffered chunk, jump directly via SeekHead.
            let haveNeededTargets =
                (parsed.infoSeen || seekTargets[idInfo] != nil)
                && (parsed.tracksSeen || seekTargets[idTracks] != nil)
            if haveNeededTargets && nextCursor > cursor + Int64(win.count) {
                break
            }

            cursor = nextCursor
        }

        // Follow secondary SeekHead once if Info or Tracks is still missing.
        if (!parsed.infoSeen && seekTargets[idInfo] == nil)
            || (!parsed.tracksSeen && seekTargets[idTracks] == nil) {
            if let secondaryOffset = secondarySeekHeads.first {
                await parseElementAt(
                    reader: &reader,
                    fileOffset: secondaryOffset,
                    expectedId: idSeekHead,
                    segmentDataStart: segStart,
                    seekTargets: &seekTargets,
                    secondarySeekHeads: &secondarySeekHeads,
                    parsed: &parsed
                )
            }
        }

        // Visit missing SeekHead targets in ascending file-offset order so a single
        // forward window fetch can satisfy adjacent Info + Tracks sections without re-fetching.
        var pendingTargets: [(offset: Int64, id: UInt32)] = []
        if !parsed.infoSeen, let infoOffset = seekTargets[idInfo] {
            pendingTargets.append((infoOffset, idInfo))
        }
        if !parsed.tracksSeen, let tracksOffset = seekTargets[idTracks] {
            pendingTargets.append((tracksOffset, idTracks))
        }
        if pendingTargets.count > 1 && pendingTargets[0].offset > pendingTargets[1].offset {
            pendingTargets.swapAt(0, 1)
        }
        for target in pendingTargets {
            await parseElementAt(
                reader: &reader,
                fileOffset: target.offset,
                expectedId: target.id,
                segmentDataStart: segStart,
                seekTargets: &seekTargets,
                secondarySeekHeads: &secondarySeekHeads,
                parsed: &parsed
            )
        }

        guard parsed.hasAnyMetadata else { return nil }

        let container = (ext == "webm" || (ext == nil && docType == "webm")) ? "webm" : "mkv"
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

    // MARK: - Element Parsing

    private struct EbmlResult {
        var infoSeen = false
        var tracksSeen = false

        var width: Int?
        var height: Int?
        var videoCodec: String?
        var hdr: String?
        var audioCodec: String?
        var audioChannels: Int?
        var durationMs: Int64?

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

    private struct EbmlHeader {
        let id: UInt32
        let size: Int64? // nil means EBML unknown size
        let headerLen: Int
    }

    private struct TrackInfo {
        var trackType: UInt64?
        var codecId: String?
        var name: String?
        var codecPrivate: Data?
        var pixelWidth: Int?
        var pixelHeight: Int?
        var displayWidth: Int?
        var displayHeight: Int?
        var displayUnit: UInt64 = 0 // 0 = pixels
        var transferCharacteristics: UInt64?
        var colourPrimaries: UInt64?
        var hasMasteringOrLightMetadata = false
        var hasDolbyVision = false
        var channels: Int?

        var resolvedWidth: Int? {
            if let pixelWidth, pixelWidth > 0 { return pixelWidth }
            if displayUnit == 0, let displayWidth, displayWidth > 0 { return displayWidth }
            return nil
        }

        var resolvedHeight: Int? {
            if let pixelHeight, pixelHeight > 0 { return pixelHeight }
            if displayUnit == 0, let displayHeight, displayHeight > 0 { return displayHeight }
            return nil
        }
    }

    private static func cappedWant(_ size: Int64?, maxCap: Int) -> Int {
        guard let size else { return maxCap }
        if size <= 0 { return 0 }
        return size > Int64(maxCap) ? maxCap : Int(size)
    }

    private static func parseElementAt(
        reader: inout ProbeRangeReader,
        fileOffset: Int64,
        expectedId: UInt32?,
        segmentDataStart: Int64,
        seekTargets: inout [UInt32: Int64],
        secondarySeekHeads: inout [Int64],
        parsed: inout EbmlResult
    ) async {
        guard fileOffset >= 0,
              let hdrWin = await reader.window(offset: fileOffset, minLength: 16),
              hdrWin.count >= 2,
              let hdr = readElementHeader(hdrWin, offset: 0, end: hdrWin.count) else {
            return
        }
        if let expectedId, hdr.id != expectedId { return }
        guard fileOffset <= Int64.max - Int64(hdr.headerLen) else { return }
        let dataStart = fileOffset + Int64(hdr.headerLen)

        let maxCap: Int
        switch hdr.id {
        case idSeekHead: maxCap = maxSeekHeadSize
        case idInfo: maxCap = maxInfoSize
        case idTracks: maxCap = maxTracksSize
        default: maxCap = maxInfoSize
        }

        let wantLen = cappedWant(hdr.size, maxCap: maxCap)
        guard wantLen > 0,
              let payload = await reader.window(
                  offset: dataStart,
                  minLength: wantLen,
                  preferredLength: max(wantLen, 64 * 1024)
              ),
              !payload.isEmpty else {
            return
        }

        let avail = min(wantLen, payload.count)
        switch hdr.id {
        case idSeekHead:
            parseSeekHead(
                payload,
                start: 0,
                end: avail,
                segmentDataStart: segmentDataStart,
                targets: &seekTargets,
                secondarySeekHeads: &secondarySeekHeads
            )
        case idInfo:
            parseInfo(payload, start: 0, end: avail, out: &parsed)
            parsed.infoSeen = true
        case idTracks:
            parseTracks(payload, start: 0, end: avail, out: &parsed)
            parsed.tracksSeen = true
        default:
            break
        }
    }

    private static func readElementHeader(_ data: Data, offset: Int, end: Int) -> EbmlHeader? {
        guard offset >= 0, end <= data.count, offset < end else { return nil }

        // Element ID: 1..4 octets, VINT marker bit is retained as part of the ID.
        guard let b0 = data.probeUInt8(at: offset), b0 != 0 else { return nil }
        let idLen: Int
        if (b0 & 0x80) != 0 {
            idLen = 1
        } else if (b0 & 0x40) != 0 {
            idLen = 2
        } else if (b0 & 0x20) != 0 {
            idLen = 3
        } else if (b0 & 0x10) != 0 {
            idLen = 4
        } else {
            return nil
        }
        guard idLen <= end - offset else { return nil }
        var id: UInt32 = 0
        for i in 0..<idLen {
            guard let b = data.probeUInt8(at: offset + i) else { return nil }
            id = (id << 8) | UInt32(b)
        }

        // Element Data Size: 1..8 octets, VINT marker bit is stripped.
        let sizeOff = offset + idLen
        guard sizeOff < end, let s0 = data.probeUInt8(at: sizeOff), s0 != 0 else { return nil }
        var sizeLen = 0
        for i in 0..<8 {
            if (s0 & (UInt8(0x80) >> i)) != 0 {
                sizeLen = i + 1
                break
            }
        }
        guard sizeLen > 0, sizeLen <= end - sizeOff else { return nil }

        let mask = (UInt64(1) << (8 - sizeLen)) - 1
        var size = UInt64(s0) & mask
        for i in 1..<sizeLen {
            guard let b = data.probeUInt8(at: sizeOff + i) else { return nil }
            size = (size << 8) | UInt64(b)
        }

        let unknownSentinel = (UInt64(1) << (7 * sizeLen)) - 1
        let resolvedSize: Int64?
        if size == unknownSentinel || size > UInt64(Int64.max) {
            resolvedSize = nil
        } else {
            resolvedSize = Int64(size)
        }
        return EbmlHeader(id: id, size: resolvedSize, headerLen: idLen + sizeLen)
    }

    private static func parseDocType(_ data: Data, start: Int, end: Int) -> String? {
        var pos = start
        while pos < end {
            guard let hdr = readElementHeader(data, offset: pos, end: end),
                  let elemSize = hdr.size,
                  elemSize >= 0 else {
                break
            }
            let dataStart = pos + hdr.headerLen
            guard elemSize <= Int64(end - dataStart) else { break }
            let len = Int(elemSize)
            if hdr.id == idDocType {
                return data.probeUTF8TrimmingNulls(at: dataStart, length: len)?.lowercased()
            }
            pos = dataStart + len
        }
        return nil
    }

    private static func parseSeekHead(
        _ data: Data,
        start: Int,
        end: Int,
        segmentDataStart: Int64,
        targets: inout [UInt32: Int64],
        secondarySeekHeads: inout [Int64]
    ) {
        var pos = start
        while pos < end {
            guard let hdr = readElementHeader(data, offset: pos, end: end),
                  let elemSize = hdr.size,
                  elemSize >= 0 else {
                break
            }
            let dataStart = pos + hdr.headerLen
            guard elemSize <= Int64(end - dataStart) else { break }
            let dataEnd = dataStart + Int(elemSize)

            if hdr.id == idSeek {
                var seekId: UInt32?
                var seekPos: UInt64?
                var inner = dataStart
                while inner < dataEnd {
                    guard let ih = readElementHeader(data, offset: inner, end: dataEnd),
                          let iSize = ih.size,
                          iSize >= 0 else {
                        break
                    }
                    let iStart = inner + ih.headerLen
                    guard iSize <= Int64(dataEnd - iStart) else { break }
                    let iLen = Int(iSize)
                    if ih.id == idSeekId && iLen >= 1 && iLen <= 4 {
                        if let v = data.probeVarUIntBE(at: iStart, length: iLen) {
                            seekId = UInt32(v)
                        }
                    } else if ih.id == idSeekPosition && iLen <= 8 {
                        seekPos = data.probeVarUIntBE(at: iStart, length: iLen)
                    }
                    inner = iStart + iLen
                }
                if let seekId,
                   let seekPos,
                   seekPos <= UInt64(maxSafeSize),
                   segmentDataStart <= Int64.max - Int64(seekPos) {
                    let absPos = segmentDataStart + Int64(seekPos)
                    if seekId == idSeekHead {
                        secondarySeekHeads.append(absPos)
                    } else if targets[seekId] == nil {
                        targets[seekId] = absPos
                    }
                }
            }
            pos = dataEnd
        }
    }

    private static func parseInfo(_ data: Data, start: Int, end: Int, out: inout EbmlResult) {
        var timestampScale: UInt64 = 1_000_000
        var rawDuration: Double?
        var pos = start
        while pos < end {
            guard let hdr = readElementHeader(data, offset: pos, end: end),
                  let elemSize = hdr.size,
                  elemSize >= 0 else {
                break
            }
            let dataStart = pos + hdr.headerLen
            guard elemSize <= Int64(end - dataStart) else { break }
            let len = Int(elemSize)
            if hdr.id == idTimestampScale && len <= 8 {
                if let scale = data.probeVarUIntBE(at: dataStart, length: len), scale > 0 {
                    timestampScale = scale
                }
            } else if hdr.id == idDuration {
                rawDuration = data.probeFloatBE(at: dataStart, length: len)
            }
            pos = dataStart + len
        }
        if let rawDuration, rawDuration.isFinite, rawDuration > 0 {
            let msDouble = (rawDuration * Double(timestampScale)) / 1_000_000.0
            if msDouble.isFinite && msDouble > 0 && msDouble < 1e12 {
                let ms = Int64(msDouble.rounded())
                if ms > 0 {
                    out.durationMs = ms
                }
            }
        }
    }

    private static func parseTracks(_ data: Data, start: Int, end: Int, out: inout EbmlResult) {
        var pos = start
        var videoFound = false
        var bestAudioRank = -1

        while pos < end {
            guard let hdr = readElementHeader(data, offset: pos, end: end),
                  let elemSize = hdr.size,
                  elemSize >= 0 else {
                break
            }
            let dataStart = pos + hdr.headerLen
            let remainingInSlice = Int64(end - dataStart)
            let clampedEnd = elemSize > remainingInSlice ? end : (dataStart + Int(elemSize))

            if hdr.id == idTrackEntry && clampedEnd > dataStart {
                let track = parseTrackEntry(data, start: dataStart, end: clampedEnd)
                if track.trackType == 1 && !videoFound {
                    let codec = mapVideoCodec(track.codecId)
                    let width = track.resolvedWidth
                    let height = track.resolvedHeight
                    if codec != nil || width != nil || height != nil {
                        videoFound = true
                        out.width = width
                        out.height = height
                        out.videoCodec = codec
                        out.hdr = resolveVideoHdr(track, mappedCodec: codec)
                    }
                } else if track.trackType == 2 {
                    let codec = mapAudioCodec(track.codecId, name: track.name)
                    let rank = audioCodecRank(codec)
                    if codec != nil || track.channels != nil {
                        if bestAudioRank < 0 || rank > bestAudioRank {
                            bestAudioRank = rank
                            out.audioCodec = codec
                            out.audioChannels = track.channels
                        }
                    }
                }
            }

            if elemSize > remainingInSlice { break }
            pos = dataStart + Int(elemSize)
        }
    }

    private static func parseTrackEntry(_ data: Data, start: Int, end: Int) -> TrackInfo {
        var info = TrackInfo()
        var pos = start
        while pos < end {
            guard let hdr = readElementHeader(data, offset: pos, end: end),
                  let elemSize = hdr.size,
                  elemSize >= 0 else {
                break
            }
            let dataStart = pos + hdr.headerLen
            guard elemSize <= Int64(end - dataStart) else { break }
            let len = Int(elemSize)
            let dataEnd = dataStart + len

            switch hdr.id {
            case idTrackType where len <= 8:
                info.trackType = data.probeVarUIntBE(at: dataStart, length: len)
            case idCodecId:
                info.codecId = data.probeUTF8TrimmingNulls(at: dataStart, length: len)
            case idTrackName:
                info.name = data.probeUTF8TrimmingNulls(at: dataStart, length: len)
            case idCodecPrivate:
                info.codecPrivate = data.probeSlice(offset: dataStart, end: dataEnd)
            case idVideo:
                parseVideoElement(data, start: dataStart, end: dataEnd, info: &info)
            case idAudio:
                parseAudioElement(data, start: dataStart, end: dataEnd, info: &info)
            case idBlockAdditionMapping:
                if hasDolbyVisionMapping(data, start: dataStart, end: dataEnd) {
                    info.hasDolbyVision = true
                }
            default:
                break
            }
            pos = dataEnd
        }
        return info
    }

    private static func parseVideoElement(
        _ data: Data,
        start: Int,
        end: Int,
        info: inout TrackInfo
    ) {
        var pos = start
        while pos < end {
            guard let hdr = readElementHeader(data, offset: pos, end: end),
                  let elemSize = hdr.size,
                  elemSize >= 0 else {
                break
            }
            let dataStart = pos + hdr.headerLen
            guard elemSize <= Int64(end - dataStart) else { break }
            let len = Int(elemSize)
            let dataEnd = dataStart + len

            switch hdr.id {
            case idPixelWidth where len <= 8:
                if let w = data.probeVarUIntBE(at: dataStart, length: len), w > 0, w <= UInt64(Int.max) {
                    info.pixelWidth = Int(w)
                }
            case idPixelHeight where len <= 8:
                if let h = data.probeVarUIntBE(at: dataStart, length: len), h > 0, h <= UInt64(Int.max) {
                    info.pixelHeight = Int(h)
                }
            case idDisplayWidth where len <= 8:
                if let dw = data.probeVarUIntBE(at: dataStart, length: len), dw > 0, dw <= UInt64(Int.max) {
                    info.displayWidth = Int(dw)
                }
            case idDisplayHeight where len <= 8:
                if let dh = data.probeVarUIntBE(at: dataStart, length: len), dh > 0, dh <= UInt64(Int.max) {
                    info.displayHeight = Int(dh)
                }
            case idDisplayUnit where len <= 8:
                if let du = data.probeVarUIntBE(at: dataStart, length: len) {
                    info.displayUnit = du
                }
            case idColour:
                parseColourElement(data, start: dataStart, end: dataEnd, info: &info)
            default:
                break
            }
            pos = dataEnd
        }
    }

    private static func parseColourElement(
        _ data: Data,
        start: Int,
        end: Int,
        info: inout TrackInfo
    ) {
        var pos = start
        while pos < end {
            guard let hdr = readElementHeader(data, offset: pos, end: end),
                  let elemSize = hdr.size,
                  elemSize >= 0 else {
                break
            }
            let dataStart = pos + hdr.headerLen
            guard elemSize <= Int64(end - dataStart) else { break }
            let len = Int(elemSize)
            switch hdr.id {
            case idTransferCharacteristics where len <= 8:
                info.transferCharacteristics = data.probeVarUIntBE(at: dataStart, length: len)
            case idPrimaries where len <= 8:
                info.colourPrimaries = data.probeVarUIntBE(at: dataStart, length: len)
            case idMasteringMetadata where len > 0:
                info.hasMasteringOrLightMetadata = true
            case idMaxCLL where len <= 8:
                if let cll = data.probeVarUIntBE(at: dataStart, length: len), cll > 0 {
                    info.hasMasteringOrLightMetadata = true
                }
            case idMaxFALL where len <= 8:
                if let fall = data.probeVarUIntBE(at: dataStart, length: len), fall > 0 {
                    info.hasMasteringOrLightMetadata = true
                }
            default:
                break
            }
            pos = dataStart + len
        }
    }

    private static func hasDolbyVisionMapping(_ data: Data, start: Int, end: Int) -> Bool {
        var pos = start
        while pos < end {
            guard let hdr = readElementHeader(data, offset: pos, end: end),
                  let elemSize = hdr.size,
                  elemSize >= 0 else {
                break
            }
            let dataStart = pos + hdr.headerLen
            guard elemSize <= Int64(end - dataStart) else { break }
            let len = Int(elemSize)
            if hdr.id == idBlockAddIdType && len <= 8 {
                if let type = data.probeVarUIntBE(at: dataStart, length: len),
                   type == dvccType || type == dvvcType || type == dvwcType {
                    return true
                }
            }
            pos = dataStart + len
        }
        return false
    }

    private static func parseAudioElement(
        _ data: Data,
        start: Int,
        end: Int,
        info: inout TrackInfo
    ) {
        var pos = start
        while pos < end {
            guard let hdr = readElementHeader(data, offset: pos, end: end),
                  let elemSize = hdr.size,
                  elemSize >= 0 else {
                break
            }
            let dataStart = pos + hdr.headerLen
            guard elemSize <= Int64(end - dataStart) else { break }
            let len = Int(elemSize)
            if hdr.id == idChannels && len <= 8 {
                if let ch = data.probeVarUIntBE(at: dataStart, length: len),
                   ch > 0,
                   ch <= UInt64(Int.max) {
                    info.channels = Int(ch)
                }
            }
            pos = dataStart + len
        }
    }

    private static func resolveVideoHdr(_ track: TrackInfo, mappedCodec: String?) -> String? {
        if track.hasDolbyVision { return "DV" }

        var codecPrivHdr: DetectedHdr?
        if let priv = track.codecPrivate, !priv.isEmpty {
            if mappedCodec == "HEVC" {
                codecPrivHdr = CodecPrivateHdrInspector.inspectHevcConfigurationRecord(priv)
            } else if mappedCodec == "AV1" {
                codecPrivHdr = CodecPrivateHdrInspector.inspectAv1ConfigurationRecord(priv)
            }
        }
        if codecPrivHdr == .dv { return "DV" }

        if let name = track.name, regexMatches(hdr10PlusRegex, in: name) {
            return "HDR10+"
        }
        if codecPrivHdr == .hdr10Plus {
            return "HDR10+"
        }
        if let priv = track.codecPrivate, !priv.isEmpty {
            let text = String(decoding: priv, as: UTF8.self)
            if regexMatches(hdr10PlusRegex, in: text) {
                return "HDR10+"
            }
        }

        switch track.transferCharacteristics {
        case 16: return "HDR10"
        case 18: return "HLG"
        default: break
        }

        if codecPrivHdr == .hlg { return "HLG" }
        if codecPrivHdr == .hdr10 { return "HDR10" }
        if track.transferCharacteristics == nil
            && track.hasMasteringOrLightMetadata
            && (track.colourPrimaries == nil || track.colourPrimaries == 9) {
            return "HDR10"
        }
        return nil
    }

    private static func mapVideoCodec(_ codecId: String?) -> String? {
        guard let codecId, !codecId.isEmpty else { return nil }
        if codecId == "V_MPEG4/ISO/AVC" || codecId.hasPrefix("V_MPEG4/ISO/AVC/") {
            return "H.264"
        }
        if codecId == "V_MPEGH/ISO/HEVC" || codecId.hasPrefix("V_MPEGH/ISO/HEVC/") {
            return "HEVC"
        }
        if codecId == "V_AV1" || codecId.hasPrefix("V_AV1/") {
            return "AV1"
        }
        if codecId == "V_VP9" || codecId.hasPrefix("V_VP9/") {
            return "VP9"
        }
        if codecId == "V_VP8" || codecId.hasPrefix("V_VP8/") {
            return "VP8"
        }
        if codecId == "V_MPEG2" {
            return "MPEG-2"
        }
        return nil
    }

    private static func mapAudioCodec(_ codecId: String?, name: String?) -> String? {
        guard let codecId, !codecId.isEmpty else { return nil }
        let hasAtmos = (name?.lowercased().contains("atmos") == true)
            || codecId.uppercased().contains("ATMOS")
        if codecId == "A_TRUEHD" || codecId.hasPrefix("A_TRUEHD/") {
            return hasAtmos ? "Atmos" : "TrueHD"
        }
        if codecId == "A_EAC3" || codecId.hasPrefix("A_EAC3/") {
            return hasAtmos ? "Atmos" : "EAC3"
        }
        if codecId == "A_AC3" || codecId.hasPrefix("A_AC3/") {
            return "AC3"
        }
        if codecId == "A_DTS" || codecId.hasPrefix("A_DTS/") {
            if let name, regexMatches(dtsXRegex, in: name) {
                return "DTS-X"
            }
            if codecId == "A_DTS/LOSSLESS" || (name != nil && regexMatches(dtsHdRegex, in: name!)) {
                return "DTS-HD"
            }
            return "DTS"
        }
        if codecId == "A_AAC" || codecId.hasPrefix("A_AAC/") {
            return "AAC"
        }
        if codecId == "A_FLAC" {
            return "FLAC"
        }
        if codecId == "A_OPUS" {
            return "Opus"
        }
        return nil
    }

    private static func regexMatches(_ regex: NSRegularExpression, in text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
