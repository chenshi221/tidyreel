import Foundation
import Testing
import TidyreelFakes
import TidyreelModels
@testable import TidyreelProbe

// MARK: - Binary EBML (MKV / WebM) Fixture Builders

private func ebmlIdBytes(_ id: UInt32) -> Data {
    if id <= 0xFF {
        return Data([UInt8(id)])
    }
    if id <= 0xFFFF {
        return Data([UInt8((id >> 8) & 0xFF), UInt8(id & 0xFF)])
    }
    if id <= 0xFF_FFFF {
        return Data([
            UInt8((id >> 16) & 0xFF),
            UInt8((id >> 8) & 0xFF),
            UInt8(id & 0xFF),
        ])
    }
    return Data([
        UInt8((id >> 24) & 0xFF),
        UInt8((id >> 16) & 0xFF),
        UInt8((id >> 8) & 0xFF),
        UInt8(id & 0xFF),
    ])
}

private func ebmlSizeBytes(_ size: Int) -> Data {
    if size < 0x7F {
        return Data([UInt8(0x80 | size)])
    }
    if size < 0x3FFF {
        return Data([UInt8(0x40 | (size >> 8)), UInt8(size & 0xFF)])
    }
    if size < 0x1F_FFFF {
        return Data([
            UInt8(0x20 | (size >> 16)),
            UInt8((size >> 8) & 0xFF),
            UInt8(size & 0xFF),
        ])
    }
    return Data([
        UInt8(0x10 | (size >> 24)),
        UInt8((size >> 16) & 0xFF),
        UInt8((size >> 8) & 0xFF),
        UInt8(size & 0xFF),
    ])
}

private func ebmlElem(_ id: UInt32, _ payload: Data, unknownSize: Bool = false) -> Data {
    var out = Data()
    out.append(ebmlIdBytes(id))
    if unknownSize {
        out.append(contentsOf: [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    } else {
        out.append(ebmlSizeBytes(payload.count))
    }
    out.append(payload)
    return out
}

private func ebmlUintPayload(_ value: UInt64) -> Data {
    if value == 0 { return Data([0]) }
    var bytes: [UInt8] = []
    var v = value
    while v > 0 {
        bytes.insert(UInt8(v & 0xFF), at: 0)
        v >>= 8
    }
    return Data(bytes)
}

private func ebmlUint(_ id: UInt32, _ value: UInt64) -> Data {
    ebmlElem(id, ebmlUintPayload(value))
}

private func ebmlStr(_ id: UInt32, _ value: String) -> Data {
    ebmlElem(id, Data(value.utf8))
}

private func uint16BE(_ v: UInt16) -> [UInt8] {
    [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
}

private func uint32BE(_ v: UInt32) -> [UInt8] {
    [
        UInt8((v >> 24) & 0xFF),
        UInt8((v >> 16) & 0xFF),
        UInt8((v >> 8) & 0xFF),
        UInt8(v & 0xFF),
    ]
}

private func uint64BE(_ v: UInt64) -> [UInt8] {
    uint32BE(UInt32((v >> 32) & 0xFFFF_FFFF)) + uint32BE(UInt32(v & 0xFFFF_FFFF))
}

private func ebmlFloat32(_ id: UInt32, _ value: Float) -> Data {
    ebmlElem(id, Data(uint32BE(value.bitPattern)))
}

private func ebmlFloat64(_ id: UInt32, _ value: Double) -> Data {
    ebmlElem(id, Data(uint64BE(value.bitPattern)))
}

private func concat(_ parts: [Data]) -> Data {
    var out = Data()
    for p in parts { out.append(p) }
    return out
}

private func ebmlHeader(docType: String = "matroska") -> Data {
    ebmlElem(
        0x1A45_DFA3,
        concat([
            ebmlUint(0x4286, 1),
            ebmlStr(0x4282, docType),
        ])
    )
}

private func mkvInfo(
    timestampScale: UInt64 = 1_000_000,
    duration: Double,
    float32: Bool = false
) -> Data {
    ebmlElem(
        0x1549_A966,
        concat([
            ebmlUint(0x2AD7B1, timestampScale),
            float32 ? ebmlFloat32(0x4489, Float(duration)) : ebmlFloat64(0x4489, duration),
        ])
    )
}

private func mkvVideoTrack(
    codecId: String,
    width: UInt64? = nil,
    height: UInt64? = nil,
    displayWidth: UInt64? = nil,
    displayHeight: UInt64? = nil,
    displayUnit: UInt64? = nil,
    transferCharacteristics: UInt64? = nil,
    colourPrimaries: UInt64? = nil,
    blockAddIdType: UInt64? = nil,
    name: String? = nil,
    codecPrivate: Data? = nil
) -> Data {
    var videoChildren: [Data] = []
    if let width { videoChildren.append(ebmlUint(0xB0, width)) }
    if let height { videoChildren.append(ebmlUint(0xBA, height)) }
    if let displayWidth { videoChildren.append(ebmlUint(0x54B0, displayWidth)) }
    if let displayHeight { videoChildren.append(ebmlUint(0x54BA, displayHeight)) }
    if let displayUnit { videoChildren.append(ebmlUint(0x54B2, displayUnit)) }
    if transferCharacteristics != nil || colourPrimaries != nil {
        var colourChildren: [Data] = []
        if let tc = transferCharacteristics { colourChildren.append(ebmlUint(0x55BA, tc)) }
        if let cp = colourPrimaries { colourChildren.append(ebmlUint(0x55BB, cp)) }
        videoChildren.append(ebmlElem(0x55B0, concat(colourChildren)))
    }

    var trackChildren: [Data] = [
        ebmlUint(0xD7, 1),
        ebmlUint(0x83, 1),
        ebmlStr(0x86, codecId),
    ]
    if let name { trackChildren.append(ebmlStr(0x536E, name)) }
    if let codecPrivate { trackChildren.append(ebmlElem(0x63A2, codecPrivate)) }
    trackChildren.append(ebmlElem(0xE0, concat(videoChildren)))
    if let blockAddIdType {
        trackChildren.append(ebmlElem(0x41E4, ebmlUint(0x41E7, blockAddIdType)))
    }
    return ebmlElem(0xAE, concat(trackChildren))
}

private func mkvAudioTrack(
    codecId: String,
    channels: UInt64,
    name: String? = nil,
    trackNumber: UInt64 = 2
) -> Data {
    var children: [Data] = [
        ebmlUint(0xD7, trackNumber),
        ebmlUint(0x83, 2),
        ebmlStr(0x86, codecId),
    ]
    if let name { children.append(ebmlStr(0x536E, name)) }
    children.append(ebmlElem(0xE1, ebmlUint(0x9F, channels)))
    return ebmlElem(0xAE, concat(children))
}

private func mkvSeekEntry(targetId: UInt32, positionInSegment: UInt64) -> Data {
    ebmlElem(
        0x4DBB,
        concat([
            ebmlElem(0x53AB, ebmlIdBytes(targetId)),
            ebmlUint(0x53AC, positionInSegment),
        ])
    )
}

// MARK: - Binary MP4 / MOV (ISO-BMFF) Fixture Builders

private func box(_ type: String, _ payload: Data, largeSize: Bool = false) -> Data {
    let typeBytes = Array(type.utf8)
    precondition(typeBytes.count == 4)
    if largeSize {
        let total = UInt64(16 + payload.count)
        var hdr = Data()
        hdr.append(contentsOf: uint32BE(1))
        hdr.append(contentsOf: typeBytes)
        hdr.append(contentsOf: uint64BE(total))
        hdr.append(payload)
        return hdr
    }
    let total = UInt32(8 + payload.count)
    var hdr = Data()
    hdr.append(contentsOf: uint32BE(total))
    hdr.append(contentsOf: typeBytes)
    hdr.append(payload)
    return hdr
}

private func fullBox(_ type: String, version: UInt8, flags: UInt32, _ body: Data) -> Data {
    var vf = Data([
        version,
        UInt8((flags >> 16) & 0xFF),
        UInt8((flags >> 8) & 0xFF),
        UInt8(flags & 0xFF),
    ])
    vf.append(body)
    return box(type, vf)
}

private func ftypBox(_ majorBrand: String = "isom") -> Data {
    box(
        "ftyp",
        concat([
            Data(majorBrand.utf8),
            Data([0, 0, 2, 0]),
            Data(majorBrand.utf8),
            Data("mp41".utf8),
        ])
    )
}

private func mvhdV0(timescale: UInt32, duration: UInt32) -> Data {
    var body = Data()
    body.append(contentsOf: uint32BE(0))
    body.append(contentsOf: uint32BE(0))
    body.append(contentsOf: uint32BE(timescale))
    body.append(contentsOf: uint32BE(duration))
    return fullBox("mvhd", version: 0, flags: 0, body)
}

private func mvhdV1(timescale: UInt32, duration: UInt64) -> Data {
    var body = Data(count: 16) // creation_time(8) + modification_time(8)
    body.append(contentsOf: uint32BE(timescale))
    body.append(contentsOf: uint64BE(duration))
    return fullBox("mvhd", version: 1, flags: 0, body)
}

private func colrBox(
    colourType: String = "nclx",
    primaries: UInt16 = 9,
    transfer: UInt16,
    matrix: UInt16 = 9
) -> Data {
    var body = Data(colourType.utf8)
    body.append(contentsOf: uint16BE(primaries))
    body.append(contentsOf: uint16BE(transfer))
    body.append(contentsOf: uint16BE(matrix))
    if colourType == "nclx" {
        body.append(0)
    }
    return box("colr", body)
}

private func dvccBox() -> Data {
    box("dvcC", Data(count: 24))
}

private func mdcvBox() -> Data {
    box("mdcv", Data(count: 24))
}

private func dec3Box(atmosJoc: Bool, acmod: UInt8 = 7, lfeon: UInt8 = 1) -> Data {
    let sub1 = ((acmod & 0x07) << 1) | (lfeon & 0x01)
    var bytes: [UInt8] = [0x00, 0x00, 0x00, sub1, 0x00]
    if atmosJoc {
        bytes.append(contentsOf: [0x01, 0x10])
    }
    return box("dec3", Data(bytes))
}

private func videoSampleEntry(
    _ fourcc: String,
    width: UInt16,
    height: UInt16,
    children: [Data] = []
) -> Data {
    var payload = Data(count: 78)
    payload.replaceSubrange(6..<8, with: uint16BE(1))
    payload.replaceSubrange(24..<26, with: uint16BE(width))
    payload.replaceSubrange(26..<28, with: uint16BE(height))
    payload.replaceSubrange(28..<32, with: uint32BE(0x0048_0000))
    payload.replaceSubrange(32..<36, with: uint32BE(0x0048_0000))
    payload.replaceSubrange(40..<42, with: uint16BE(1))
    payload.replaceSubrange(74..<76, with: uint16BE(0x0018))
    payload.replaceSubrange(76..<78, with: [0xFF, 0xFF])
    return box(fourcc, concat([payload] + children))
}

private func audioSampleEntry(
    _ fourcc: String,
    channels: UInt16,
    children: [Data] = []
) -> Data {
    var payload = Data(count: 28)
    payload.replaceSubrange(6..<8, with: uint16BE(1))
    payload.replaceSubrange(16..<18, with: uint16BE(channels))
    payload.replaceSubrange(18..<20, with: uint16BE(16))
    payload.replaceSubrange(24..<28, with: uint32BE(48000 << 16))
    return box(fourcc, concat([payload] + children))
}

private func trakBox(
    _ sampleEntries: [Data],
    handlerType: String? = nil,
    tkhdSize: (width: UInt16, height: UInt16)? = nil
) -> Data {
    let stsd = fullBox(
        "stsd",
        version: 0,
        flags: 0,
        concat([Data(uint32BE(UInt32(sampleEntries.count)))] + sampleEntries)
    )
    var mdiaChildren: [Data] = []
    if let handlerType {
        var hdlrBody = Data(count: 4)
        hdlrBody.append(Data(handlerType.utf8))
        hdlrBody.append(Data(count: 12))
        mdiaChildren.append(fullBox("hdlr", version: 0, flags: 0, hdlrBody))
    }
    mdiaChildren.append(box("minf", box("stbl", stsd)))

    var trakChildren: [Data] = []
    if let tkhdSize {
        var tkhdBody = Data(count: 80)
        tkhdBody.replaceSubrange(72..<76, with: uint32BE(UInt32(tkhdSize.width) << 16))
        tkhdBody.replaceSubrange(76..<80, with: uint32BE(UInt32(tkhdSize.height) << 16))
        trakChildren.append(fullBox("tkhd", version: 0, flags: 1, tkhdBody))
    }
    trakChildren.append(box("mdia", concat(mdiaChildren)))
    return box("trak", concat(trakChildren))
}

/// Builds a synthetic `hvcC` (`HEVCDecoderConfigurationRecord`) containing a `PREFIX_SEI_NUT`
/// with SMPTE ST 2094-40 HDR10+ dynamic metadata (including an emulation-prevention `0x00 0x00 0x03` sequence).
private func hvccHdr10PlusRecord() -> Data {
    // NAL header for PREFIX_SEI_NUT (nal_unit_type = 39 -> (39 << 1) = 0x4E, 0x01)
    // SEI payloadType = 4 (ITU-T T.35), payloadSize = 7:
    // B5 00 3C 00 00 01 04 -> wait: oriented_code is 0x0001, so let's place 0x00 0x00 0x03 0x01 AFTER app_id
    // Raw SEI payload (8 bytes): B5 00 3C 00 01 04 00 00 01 -> escaped with emulation prevention:
    // B5 00 3C 00 01 04 00 00 03 01 (payloadSize = 9 raw bytes)
    let seiEscaped: [UInt8] = [
        0x4E, 0x01, // PREFIX_SEI_NUT header
        0x04, // payloadType = 4
        0x09, // payloadSize = 9 (unescaped bytes)
        0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04, 0x00, 0x00, 0x03, 0x01,
        0x80, // rbsp_trailing_bits
    ]
    var rec = Data(count: 23)
    rec[0] = 1 // configurationVersion = 1
    rec[21] = 0xFF // lengthSizeMinusOne = 3
    rec[22] = 1 // numOfArrays = 1
    rec.append(39) // NAL_unit_type = 39 (PREFIX_SEI_NUT)
    rec.append(contentsOf: uint16BE(1)) // numNalus = 1
    rec.append(contentsOf: uint16BE(UInt16(seiEscaped.count)))
    rec.append(contentsOf: seiEscaped)
    return rec
}

/// Builds a synthetic `av1C` (`AV1CodecConfigurationRecord`) with an `OBU_METADATA` ITU-T T.35 HDR10+ payload.
private func av1cHdr10PlusRecord() -> Data {
    // OBU_METADATA (type 5 -> (5 << 3) | 0x02 (has_size) = 0x2A), size = 8:
    // metadata_type = 4 (leb128: 0x04), T.35 ST 2094-40: B5 00 3C 00 01 04 01
    let bytes: [UInt8] = [
        0x81, 0x08, 0x0C, 0x00, // 4-byte av1C header (marker=1, version=1)
        0x2A, 0x08, // OBU_METADATA with size=8
        0x04, // METADATA_TYPE_ITUT_T35
        0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04, 0x01,
    ]
    return Data(bytes)
}

// MARK: - Test Storage Backends

private actor SparseRangeBackend: RangeReadableBackend {
    let virtualSize: Int64
    let segments: [Int64: Data]
    private(set) var totalBytesRead: Int = 0
    private(set) var readCalls: Int = 0

    init(virtualSize: Int64, segments: [Int64: Data]) {
        self.virtualSize = virtualSize
        self.segments = segments
    }

    func readRange(path: String, start: Int64, length: Int) async throws -> Data {
        readCalls += 1
        guard start >= 0, length > 0, start < virtualSize else { return Data() }
        let maxAvail = virtualSize - start
        let actualLen = Int(min(Int64(length), maxAvail))
        var out = Data(count: actualLen)
        let reqEnd = start + Int64(actualLen)

        for (segStart, segData) in segments {
            let segEnd = segStart + Int64(segData.count)
            let overlapStart = max(start, segStart)
            let overlapEnd = min(reqEnd, segEnd)
            if overlapStart < overlapEnd {
                let dstLo = Int(overlapStart - start)
                let dstHi = Int(overlapEnd - start)
                let srcLo = segData.startIndex + Int(overlapStart - segStart)
                let srcHi = segData.startIndex + Int(overlapEnd - segStart)
                out.replaceSubrange(dstLo..<dstHi, with: segData[srcLo..<srcHi])
            }
        }
        totalBytesRead += out.count
        return out
    }

    func list(_ dir: String, refresh: Bool) async throws -> [RemoteEntry] { [] }
    func mkdirs(_ dir: String) async throws {}
    func rename(_ path: String, newName: String) async throws {}
    func renameMany(_ dir: String, names: [String: String]) async throws {}
    func move(srcDir: String, dstDir: String, names: [String]) async throws {}
    func remove(dir: String, names: [String]) async throws {}
    func exists(_ path: String) async throws -> Bool { true }
    func read(_ path: String) async throws -> Data { Data() }
    func write(_ path: String, bytes: Data) async throws {}
    func ping() async throws {}
    func close() async {}
}

private struct NonRangeBackend: StorageBackend {
    func list(_ dir: String, refresh: Bool) async throws -> [RemoteEntry] { [] }
    func mkdirs(_ dir: String) async throws {}
    func rename(_ path: String, newName: String) async throws {}
    func renameMany(_ dir: String, names: [String: String]) async throws {}
    func move(srcDir: String, dstDir: String, names: [String]) async throws {}
    func remove(dir: String, names: [String]) async throws {}
    func exists(_ path: String) async throws -> Bool { true }
    func read(_ path: String) async throws -> Data { Data() }
    func write(_ path: String, bytes: Data) async throws {}
    func ping() async throws {}
    func close() async {}
}

private struct TestProbeFailure: Error {}

private struct ThrowingRangeBackend: RangeReadableBackend {
    func readRange(path: String, start: Int64, length: Int) async throws -> Data {
        throw TestProbeFailure()
    }
    func list(_ dir: String, refresh: Bool) async throws -> [RemoteEntry] { [] }
    func mkdirs(_ dir: String) async throws {}
    func rename(_ path: String, newName: String) async throws {}
    func renameMany(_ dir: String, names: [String: String]) async throws {}
    func move(srcDir: String, dstDir: String, names: [String]) async throws {}
    func remove(dir: String, names: [String]) async throws {}
    func exists(_ path: String) async throws -> Bool { true }
    func read(_ path: String) async throws -> Data { Data() }
    func write(_ path: String, bytes: Data) async throws {}
    func ping() async throws {}
    func close() async {}
}

// MARK: - Unit Tests

@Suite("ContainerMediaProbe Tests")
struct MediaProbeTests {
    let probe = ContainerMediaProbe()

    // MARK: MKV / WebM (EBML)

    @Test("Parses 4K HEVC + Dolby Vision (dvcC) + TrueHD Atmos (8ch) + duration")
    func mkv4kHevcDolbyVisionAtmos() async throws {
        let info = mkvInfo(timestampScale: 1_000_000, duration: 7_542_500.0)
        let tracks = ebmlElem(
            0x1654_AE6B,
            concat([
                mkvVideoTrack(
                    codecId: "V_MPEGH/ISO/HEVC",
                    width: 3840,
                    height: 2160,
                    transferCharacteristics: 16, // PQ (HDR10) - DV must override this
                    blockAddIdType: 0x6476_6343 // dvcC -> DV
                ),
                mkvAudioTrack(
                    codecId: "A_AAC",
                    channels: 2,
                    name: "Commentary",
                    trackNumber: 2
                ),
                mkvAudioTrack(
                    codecId: "A_TRUEHD",
                    channels: 8,
                    name: "English TrueHD Atmos 7.1",
                    trackNumber: 3
                ),
            ])
        )
        let mkv = concat([
            ebmlHeader(),
            ebmlElem(
                0x1853_8067,
                concat([info, tracks, ebmlElem(0x1F43_B675, Data(count: 32))])
            ),
        ])

        let fs = MemoryStorageBackend()
        try await fs.write("/movies/Dune.mkv", bytes: mkv)

        let result = await probe.probe(
            backend: fs,
            path: "/movies/Dune.mkv",
            fileSize: Int64(mkv.count)
        )
        let r = try #require(result)
        #expect(r.width == 3840)
        #expect(r.height == 2160)
        #expect(r.resolution == "2160p")
        #expect(r.videoCodec == "HEVC")
        #expect(r.hdr == "DV")
        #expect(r.audioCodec == "Atmos")
        #expect(r.audioChannels == 8)
        #expect(r.extraInfoSummary == "2160p.DV.Atmos")
        #expect(r.container == "mkv")
        #expect(r.durationMs == 7_542_500)
    }

    @Test("Parses 1080p H.264 + HDR10 + EAC3 (6ch) with float32 duration and unknown Segment size")
    func mkv1080pH264Hdr10Eac3Float32() async throws {
        let info = mkvInfo(timestampScale: 1_000_000, duration: 2_700_000.0, float32: true)
        let tracks = ebmlElem(
            0x1654_AE6B,
            concat([
                mkvVideoTrack(
                    codecId: "V_MPEG4/ISO/AVC",
                    width: 1920,
                    height: 1080,
                    transferCharacteristics: 16
                ),
                mkvAudioTrack(codecId: "A_EAC3", channels: 6),
            ])
        )
        let mkv = concat([
            ebmlHeader(),
            ebmlElem(0x1853_8067, concat([info, tracks]), unknownSize: true),
        ])

        let fs = MemoryStorageBackend()
        try await fs.write("/tv/S01E01.mkv", bytes: mkv)

        let result = await probe.probe(backend: fs, path: "/tv/S01E01.mkv")
        let r = try #require(result)
        #expect(r.width == 1920)
        #expect(r.height == 1080)
        #expect(r.resolution == "1080p")
        #expect(r.videoCodec == "H.264")
        #expect(r.hdr == "HDR10")
        #expect(r.audioCodec == "EAC3")
        #expect(r.audioChannels == 6)
        #expect(r.extraInfoSummary == "1080p.HDR10")
        #expect(r.container == "mkv")
        #expect(r.durationMs == 2_700_000)
    }

    @Test("Parses WebM VP9 + Opus + HLG")
    func webmVp9OpusHlg() async throws {
        let info = mkvInfo(timestampScale: 1_000_000, duration: 120_000.0)
        let tracks = ebmlElem(
            0x1654_AE6B,
            concat([
                mkvVideoTrack(
                    codecId: "V_VP9",
                    width: 2560,
                    height: 1440,
                    transferCharacteristics: 18
                ),
                mkvAudioTrack(codecId: "A_OPUS", channels: 2),
            ])
        )
        let webm = concat([
            ebmlHeader(docType: "webm"),
            ebmlElem(0x1853_8067, concat([info, tracks])),
        ])

        let fs = MemoryStorageBackend()
        try await fs.write("/clips/sample.webm", bytes: webm)

        let result = await probe.probe(backend: fs, path: "/clips/sample.webm")
        let r = try #require(result)
        #expect(r.width == 2560)
        #expect(r.height == 1440)
        #expect(r.resolution == "1440p")
        #expect(r.videoCodec == "VP9")
        #expect(r.hdr == "HLG")
        #expect(r.audioCodec == "Opus")
        #expect(r.audioChannels == 2)
        #expect(r.container == "webm")
        #expect(r.durationMs == 120_000)
    }

    @Test("Follows SeekHead past Cluster in huge 2 GiB MKV within 512 KiB budget and detects HDR10+ & DTS-X")
    func mkvSeekHeadJumpAndHdr10PlusDtsX() async throws {
        let virtualSize: Int64 = 2 * 1024 * 1024 * 1024 // 2 GiB
        let ebml = ebmlHeader()
        let segHeader = concat([
            ebmlIdBytes(0x1853_8067),
            Data([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
        ])
        let segDataStart = Int64(ebml.count + segHeader.count)

        let info = mkvInfo(duration: 3_600_000.0)
        let tracks = ebmlElem(
            0x1654_AE6B,
            concat([
                mkvVideoTrack(
                    codecId: "V_AV1",
                    width: 3840,
                    height: 2160,
                    transferCharacteristics: 16,
                    codecPrivate: Data("meta:HDR10+".utf8)
                ),
                mkvAudioTrack(
                    codecId: "A_DTS",
                    channels: 8,
                    name: "DTS:X Master Audio"
                ),
            ])
        )

        let tailOffsetInFile = virtualSize - Int64(info.count + tracks.count)
        let infoRelPos = UInt64(tailOffsetInFile - segDataStart)
        let tracksRelPos = infoRelPos + UInt64(info.count)

        let seekHead = ebmlElem(
            0x114D_9B74,
            concat([
                mkvSeekEntry(targetId: 0x1549_A966, positionInSegment: infoRelPos),
                mkvSeekEntry(targetId: 0x1654_AE6B, positionInSegment: tracksRelPos),
            ])
        )
        let clusterHeader = concat([
            ebmlIdBytes(0x1F43_B675),
            Data([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
        ])

        let headBlock = concat([ebml, segHeader, seekHead, clusterHeader])
        let tailBlock = concat([info, tracks])

        let be = SparseRangeBackend(
            virtualSize: virtualSize,
            segments: [
                0: headBlock,
                tailOffsetInFile: tailBlock,
            ]
        )

        let result = await probe.probe(backend: be, path: "/big.mkv", fileSize: virtualSize)
        let r = try #require(result)
        #expect(r.videoCodec == "AV1")
        #expect(r.hdr == "HDR10+")
        #expect(r.audioCodec == "DTS-X")
        #expect(r.audioChannels == 8)
        #expect(r.extraInfoSummary == "2160p.HDR10+.DTS-X")
        #expect(r.durationMs == 3_600_000)
        #expect(await be.totalBytesRead <= 512 * 1024)
    }

    @Test("Detects MKV by magic bytes without extension and supports DisplayWidth/Height & binary SEI/OBU HDR10+")
    func mkvMagicDisplayDimensionsAndBinarySei() async throws {
        let mkv = concat([
            ebmlHeader(),
            ebmlElem(0xEC, Data(count: 16)), // Void before Segment
            ebmlElem(
                0x1853_8067,
                ebmlElem(
                    0x1654_AE6B,
                    mkvVideoTrack(
                        codecId: "V_MPEG2",
                        displayWidth: 1280,
                        displayHeight: 720,
                        displayUnit: 0
                    )
                )
            ),
        ])
        let fs = MemoryStorageBackend()
        try await fs.write("/extensionless_video", bytes: mkv)

        let r1 = try #require(await probe.probe(backend: fs, path: "/extensionless_video"))
        #expect(r1.videoCodec == "MPEG-2")
        #expect(r1.resolution == "720p")
        #expect(r1.container == "mkv")

        // Binary HEVC hvcC SEI SMPTE ST 2094-40 HDR10+ + EAC3 Atmos
        let hevcHdr10PlusMkv = concat([
            ebmlHeader(),
            ebmlElem(
                0x1853_8067,
                ebmlElem(
                    0x1654_AE6B,
                    concat([
                        mkvVideoTrack(
                            codecId: "V_MPEGH/ISO/HEVC",
                            width: 3840,
                            height: 2160,
                            transferCharacteristics: 16,
                            codecPrivate: hvccHdr10PlusRecord()
                        ),
                        mkvAudioTrack(codecId: "A_EAC3", channels: 6, name: "DD+ Atmos"),
                    ])
                )
            ),
        ])
        try await fs.write("/hevc_sei.mkv", bytes: hevcHdr10PlusMkv)
        let r2 = try #require(await probe.probe(backend: fs, path: "/hevc_sei.mkv"))
        #expect(r2.videoCodec == "HEVC")
        #expect(r2.hdr == "HDR10+")
        #expect(r2.audioCodec == "Atmos")
        #expect(r2.audioChannels == 6)

        // Binary AV1 av1C OBU_METADATA T.35 HDR10+ + A_DTS/LOSSLESS
        let av1Hdr10PlusMkv = concat([
            ebmlHeader(),
            ebmlElem(
                0x1853_8067,
                ebmlElem(
                    0x1654_AE6B,
                    concat([
                        mkvVideoTrack(
                            codecId: "V_AV1",
                            width: 3840,
                            height: 2160,
                            transferCharacteristics: 16,
                            codecPrivate: av1cHdr10PlusRecord()
                        ),
                        mkvAudioTrack(codecId: "A_DTS/LOSSLESS", channels: 8),
                    ])
                )
            ),
        ])
        try await fs.write("/av1_obu.mkv", bytes: av1Hdr10PlusMkv)
        let r3 = try #require(await probe.probe(backend: fs, path: "/av1_obu.mkv"))
        #expect(r3.videoCodec == "AV1")
        #expect(r3.hdr == "HDR10+")
        #expect(r3.audioCodec == "DTS-HD")
        #expect(r3.audioChannels == 8)

        // Secondary SeekHead chaining
        let ebml = ebmlHeader()
        let segHdr = concat([
            ebmlIdBytes(0x1853_8067),
            Data([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
        ])
        let segStart = Int64(ebml.count + segHdr.count)
        let secTracks = ebmlElem(
            0x1654_AE6B,
            concat([
                mkvVideoTrack(codecId: "V_VP8", width: 1280, height: 720),
                mkvAudioTrack(codecId: "A_FLAC", channels: 2),
            ])
        )
        let secondarySeekOffset: Int64 = 1024
        let tracksOffset: Int64 = 2048
        let primarySeek = ebmlElem(
            0x114D_9B74,
            mkvSeekEntry(targetId: 0x114D_9B74, positionInSegment: UInt64(secondarySeekOffset - segStart))
        )
        let secondarySeek = ebmlElem(
            0x114D_9B74,
            mkvSeekEntry(targetId: 0x1654_AE6B, positionInSegment: UInt64(tracksOffset - segStart))
        )
        let clusterHdr = concat([
            ebmlIdBytes(0x1F43_B675),
            Data([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
        ])
        let secBackend = SparseRangeBackend(
            virtualSize: 4096,
            segments: [
                0: concat([ebml, segHdr, primarySeek, clusterHdr]),
                secondarySeekOffset: secondarySeek,
                tracksOffset: secTracks,
            ]
        )
        let r4 = try #require(await probe.probe(backend: secBackend, path: "/sec_seek.mkv", fileSize: 4096))
        #expect(r4.videoCodec == "VP8")
        #expect(r4.audioCodec == "FLAC")
        #expect(r4.audioChannels == 2)
    }

    @Test("EbmlProbe visits out-of-order SeekHead targets in ascending offset order to avoid redundant range reads")
    func mkvSeekHeadAscendingOrderSingleTailRead() async throws {
        let virtualSize: Int64 = 2 * 1024 * 1024 * 1024
        let ebml = ebmlHeader()
        let segHeader = concat([
            ebmlIdBytes(0x1853_8067),
            Data([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
        ])
        let segDataStart = Int64(ebml.count + segHeader.count)

        let info = mkvInfo(duration: 1_800_000.0)
        let tracks = ebmlElem(
            0x1654_AE6B,
            concat([
                mkvVideoTrack(codecId: "V_MPEGH/ISO/HEVC", width: 1920, height: 1080),
                mkvAudioTrack(codecId: "A_AAC", channels: 2),
            ])
        )

        // Place Tracks BEFORE Info at the end of the file.
        let tailOffsetInFile = virtualSize - Int64(tracks.count + info.count)
        let tracksRelPos = UInt64(tailOffsetInFile - segDataStart)
        let infoRelPos = tracksRelPos + UInt64(tracks.count)

        let seekHead = ebmlElem(
            0x114D_9B74,
            concat([
                mkvSeekEntry(targetId: 0x1549_A966, positionInSegment: infoRelPos),
                mkvSeekEntry(targetId: 0x1654_AE6B, positionInSegment: tracksRelPos),
            ])
        )
        let clusterHeader = concat([
            ebmlIdBytes(0x1F43_B675),
            Data([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
        ])

        let be = SparseRangeBackend(
            virtualSize: virtualSize,
            segments: [
                0: concat([ebml, segHeader, seekHead, clusterHeader]),
                tailOffsetInFile: concat([tracks, info]),
            ]
        )

        let r = try #require(await probe.probe(backend: be, path: "/tracks_first.mkv", fileSize: virtualSize))
        #expect(r.videoCodec == "HEVC")
        #expect(r.width == 1920)
        #expect(r.height == 1080)
        #expect(r.audioCodec == "AAC")
        #expect(r.durationMs == 1_800_000)
        // 1 head read + 1 single tail read covering both Tracks and Info.
        #expect(await be.readCalls == 2)
        #expect(await be.totalBytesRead <= 128 * 1024)
    }

    // MARK: MP4 / MOV / M4V (ISO-BMFF)

    @Test("Parses fast-start MP4 with cinema aspect 3840x1600, colr PQ (HDR10), ec-3 6ch, mvhd v0")
    func mp4FastStartCinemaHdr10Eac3() async throws {
        let moov = box(
            "moov",
            concat([
                mvhdV0(timescale: 1000, duration: 5_400_000), // 90 min
                trakBox([
                    videoSampleEntry(
                        "hvc1",
                        width: 3840,
                        height: 1600,
                        children: [colrBox(transfer: 16)]
                    ),
                ]),
                trakBox([audioSampleEntry("ec-3", channels: 6)]),
            ])
        )
        let mp4 = concat([ftypBox(), moov, box("mdat", Data(count: 64))])

        let fs = MemoryStorageBackend()
        try await fs.write("/movies/Blade.Runner.mp4", bytes: mp4)

        let result = await probe.probe(
            backend: fs,
            path: "/movies/Blade.Runner.mp4",
            fileSize: Int64(mp4.count)
        )
        let r = try #require(result)
        #expect(r.width == 3840)
        #expect(r.height == 1600)
        #expect(r.resolution == "2160p")
        #expect(r.videoCodec == "HEVC")
        #expect(r.hdr == "HDR10")
        #expect(r.audioCodec == "EAC3")
        #expect(r.audioChannels == 6)
        #expect(r.extraInfoSummary == "2160p.HDR10")
        #expect(r.durationMs == 5_400_000)
        #expect(r.container == "mp4")
    }

    @Test("Parses trailing-moov 4 GiB MP4 within 512 KiB budget with mvhd v1 and dec3 Atmos JOC")
    func mp4TrailingMoov4GiBAtmosJoc() async throws {
        let mdatSize: Int64 = 4 * 1024 * 1024 * 1024 // 4 GiB simulated mdat
        let ftyp = ftypBox()

        var mdatHdrBytes = Data()
        mdatHdrBytes.append(contentsOf: uint32BE(1))
        mdatHdrBytes.append(Data("mdat".utf8))
        mdatHdrBytes.append(contentsOf: uint64BE(UInt64(mdatSize)))

        let moov = box(
            "moov",
            concat([
                mvhdV1(timescale: 90_000, duration: 90_000 * 6000), // 100 min
                trakBox([
                    videoSampleEntry(
                        "hvc1",
                        width: 3840,
                        height: 2160,
                        children: [colrBox(transfer: 16), dvccBox()]
                    ),
                ]),
                trakBox([audioSampleEntry("mp4a", channels: 2)]),
                trakBox([
                    audioSampleEntry(
                        "ec-3",
                        channels: 6,
                        children: [dec3Box(atmosJoc: true)]
                    ),
                ]),
            ])
        )

        let moovOffset = Int64(ftyp.count) + mdatSize
        let totalSize = moovOffset + Int64(moov.count)
        let be = SparseRangeBackend(
            virtualSize: totalSize,
            segments: [
                0: concat([ftyp, mdatHdrBytes]),
                moovOffset: moov,
            ]
        )

        let result = await probe.probe(backend: be, path: "/4k_tail.mp4", fileSize: totalSize)
        let r = try #require(result)
        #expect(r.width == 3840)
        #expect(r.height == 2160)
        #expect(r.resolution == "2160p")
        #expect(r.videoCodec == "HEVC")
        #expect(r.hdr == "DV")
        #expect(r.audioCodec == "Atmos")
        #expect(r.audioChannels == 6)
        #expect(r.extraInfoSummary == "2160p.DV.Atmos")
        #expect(r.durationMs == 6_000_000)
        #expect(r.container == "mp4")
        #expect(await be.totalBytesRead <= 512 * 1024)
        #expect(await be.readCalls <= 3)
    }

    @Test("Parses Dolby Vision dvh1 M4V + TrueHD and QuickTime MOV with HLG + FLAC")
    func mp4DolbyVisionM4vAndMovHlg() async throws {
        let dvMoov = box(
            "moov",
            concat([
                mvhdV0(timescale: 1000, duration: 60_000),
                trakBox([videoSampleEntry("dvh1", width: 3840, height: 2160)]),
                trakBox([audioSampleEntry("mlpa", channels: 8)]),
            ])
        )
        let dvMp4 = concat([ftypBox(), dvMoov])
        let fs = MemoryStorageBackend()
        try await fs.write("/dv.m4v", bytes: dvMp4)

        let dvRes = try #require(await probe.probe(backend: fs, path: "/dv.m4v"))
        #expect(dvRes.videoCodec == "HEVC")
        #expect(dvRes.hdr == "DV")
        #expect(dvRes.audioCodec == "TrueHD")
        #expect(dvRes.audioChannels == 8)
        #expect(dvRes.container == "mp4")

        let movMoov = box(
            "moov",
            concat([
                mvhdV0(timescale: 600, duration: 600 * 30),
                trakBox([
                    videoSampleEntry(
                        "avc1",
                        width: 1920,
                        height: 1080,
                        children: [colrBox(colourType: "nclc", transfer: 18)]
                    ),
                ]),
                trakBox([audioSampleEntry("fLaC", channels: 2)]),
            ])
        )
        let mov = concat([ftypBox("qt  "), movMoov])
        try await fs.write("/iphone.mov", bytes: mov)

        let movRes = try #require(await probe.probe(backend: fs, path: "/iphone.mov"))
        #expect(movRes.videoCodec == "H.264")
        #expect(movRes.hdr == "HLG")
        #expect(movRes.audioCodec == "FLAC")
        #expect(movRes.durationMs == 30_000)
        #expect(movRes.container == "mov")
    }

    @Test("Falls back to tail chunk scan when mdat has size == 0")
    func mp4TailScanWhenMdatZeroSize() async throws {
        let ftyp = ftypBox()
        let badMdatHdr = Data([0, 0, 0, 0, 0x6D, 0x64, 0x61, 0x74])
        let moov = box(
            "moov",
            concat([
                mvhdV0(timescale: 1000, duration: 15_000),
                trakBox([videoSampleEntry("av01", width: 1920, height: 1080)]),
            ])
        )
        let virtualSize: Int64 = 10 * 1024 * 1024
        let moovOffset = virtualSize - Int64(moov.count)
        let be = SparseRangeBackend(
            virtualSize: virtualSize,
            segments: [
                0: concat([ftyp, badMdatHdr]),
                moovOffset: moov,
            ]
        )

        let res = try #require(
            await probe.probe(backend: be, path: "/tail_fallback.mp4", fileSize: virtualSize)
        )
        #expect(res.videoCodec == "AV1")
        #expect(res.resolution == "1080p")
        #expect(res.durationMs == 15_000)
        #expect(await be.totalBytesRead <= 512 * 1024)
    }

    @Test("Maps dvav, dva1, dav1 Dolby Vision sample entries and mdcv/tkhd/hdlr boxes")
    func mp4DolbyVisionVariantsAndMdcvTkhdHdlr() async throws {
        let fs = MemoryStorageBackend()
        for (fourcc, expectedCodec) in [("dvav", "H.264"), ("dva1", "H.264"), ("dav1", "AV1")] {
            let moov = box(
                "moov",
                concat([
                    mvhdV0(timescale: 1000, duration: 10_000),
                    trakBox([videoSampleEntry(fourcc, width: 1920, height: 1080)]),
                ])
            )
            let mp4 = concat([ftypBox(), moov])
            try await fs.write("/\(fourcc).mp4", bytes: mp4)
            let res = try #require(
                await probe.probe(backend: fs, path: "/\(fourcc).mp4", fileSize: Int64(mp4.count))
            )
            #expect(res.videoCodec == expectedCodec)
            #expect(res.hdr == "DV")
        }

        // Cover-art track ('pict') is ignored via hdlr; real 'vide' track uses tkhd fallback + mdcv HDR10
        let moovWithHdlr = box(
            "moov",
            concat([
                mvhdV0(timescale: 1000, duration: 20_000),
                trakBox(
                    [videoSampleEntry("avc1", width: 600, height: 900)],
                    handlerType: "pict"
                ),
                trakBox(
                    [videoSampleEntry("hev1", width: 0, height: 0, children: [mdcvBox()])],
                    handlerType: "vide",
                    tkhdSize: (3840, 2160)
                ),
                trakBox(
                    [audioSampleEntry("dtsx", channels: 8)],
                    handlerType: "soun"
                ),
            ])
        )
        let mp4 = concat([ftypBox(), moovWithHdlr])
        try await fs.write("/hdlr_mdcv.mp4", bytes: mp4)
        let res = try #require(await probe.probe(backend: fs, path: "/hdlr_mdcv.mp4"))
        #expect(res.videoCodec == "HEVC")
        #expect(res.width == 3840)
        #expect(res.height == 2160)
        #expect(res.hdr == "HDR10")
        #expect(res.audioCodec == "DTS-X")
        #expect(res.audioChannels == 8)

        // Additional MP4 audio codecs: ac-3, dtsc, dtsh, dtsl, Opus
        for (fourcc, expectedAudio) in [
            ("ac-3", "AC3"),
            ("dtsc", "DTS"),
            ("dtsh", "DTS-HD"),
            ("dtsl", "DTS-HD"),
            ("Opus", "Opus"),
        ] {
            let m = box(
                "moov",
                concat([
                    mvhdV0(timescale: 1000, duration: 5000),
                    trakBox([videoSampleEntry("avc1", width: 1280, height: 720)]),
                    trakBox([audioSampleEntry(fourcc, channels: 6)]),
                ])
            )
            let data = concat([ftypBox(), m])
            try await fs.write("/audio_\(fourcc).mp4", bytes: data)
            let ar = try #require(await probe.probe(backend: fs, path: "/audio_\(fourcc).mp4"))
            #expect(ar.audioCodec == expectedAudio)
            #expect(ar.audioChannels == 6)
        }
    }

    @Test("Reads QuickTime SoundDescription v2 numAudioChannels at offset 40")
    func mp4QuickTimeSoundDescriptionV2() async throws {
        var payload = Data(count: 64)
        payload.replaceSubrange(6..<8, with: uint16BE(1))
        payload.replaceSubrange(8..<10, with: uint16BE(2)) // version = 2
        payload.replaceSubrange(32..<40, with: uint64BE(48000.0.bitPattern))
        payload.replaceSubrange(40..<44, with: uint32BE(8)) // numAudioChannels = 8
        let audioV2 = box("mp4a", payload)

        let moov = box(
            "moov",
            concat([
                mvhdV0(timescale: 1000, duration: 10_000),
                trakBox([videoSampleEntry("avc1", width: 1920, height: 1080)]),
                trakBox([audioV2]),
            ])
        )
        let mov = concat([ftypBox("qt  "), moov])
        let fs = MemoryStorageBackend()
        try await fs.write("/qt_v2.mov", bytes: mov)

        let res = try #require(
            await probe.probe(backend: fs, path: "/qt_v2.mov", fileSize: Int64(mov.count))
        )
        #expect(res.audioCodec == "AAC")
        #expect(res.audioChannels == 8)
    }

    @Test("Tail fallback finds moov box with size == 0 at non-zero offset in tail")
    func mp4TailZeroSizeMoov() async throws {
        let ftyp = ftypBox()
        let badMdatHdr = Data([0, 0, 0, 0, 0x6D, 0x64, 0x61, 0x74])
        let moovPayload = concat([
            mvhdV0(timescale: 1000, duration: 25_000),
            trakBox([videoSampleEntry("hvc1", width: 3840, height: 2160)]),
        ])
        let moovZeroSize = concat([
            Data([0, 0, 0, 0]),
            Data("moov".utf8),
            moovPayload,
        ])
        let virtualSize: Int64 = 10 * 1024 * 1024
        let moovOffset = virtualSize - Int64(moovZeroSize.count)
        let be = SparseRangeBackend(
            virtualSize: virtualSize,
            segments: [
                0: concat([ftyp, badMdatHdr]),
                moovOffset: moovZeroSize,
            ]
        )

        let res = try #require(
            await probe.probe(backend: be, path: "/tail_zero_moov.mp4", fileSize: virtualSize)
        )
        #expect(res.videoCodec == "HEVC")
        #expect(res.resolution == "2160p")
        #expect(res.durationMs == 25_000)
    }

    @Test("Stops cleanly on oversized 64-bit box size without overflow")
    func mp4OversizedBoxSize() async throws {
        let ftyp = ftypBox()
        var hugeBytes = Data()
        hugeBytes.append(contentsOf: uint32BE(1))
        hugeBytes.append(Data("free".utf8))
        hugeBytes.append(contentsOf: uint32BE(0x7FFF_FFFF))
        hugeBytes.append(contentsOf: uint32BE(0xFFFF_FF00))
        let mp4 = concat([ftyp, hugeBytes])

        let fs = MemoryStorageBackend()
        try await fs.write("/huge_box.mp4", bytes: mp4)
        #expect(await probe.probe(backend: fs, path: "/huge_box.mp4") == nil)
    }

    // MARK: ProbeRangeReader Overflow & Budget Safety

    @Test("ProbeRangeReader handles huge lengths without signed 64-bit overflow and enforces maxBytes")
    func probeRangeReaderOverflowAndBudget() async throws {
        let fs = MemoryStorageBackend()
        try await fs.write("/small.bin", bytes: Data([1, 2, 3, 4, 5, 6, 7, 8]))

        var reader = ProbeRangeReader(
            backend: fs,
            path: "/small.bin",
            maxBytes: 64,
            fileSize: 8
        )
        reader.seed(start: 0, bytes: Data([1, 2, 3, 4]))
        let w = await reader.window(
            offset: 2,
            minLength: 0x7FFF_FFFF_FFFF_FFF0,
            preferredLength: 8
        )
        #expect(w == Data([3, 4, 5, 6, 7, 8]))

        var reader2 = ProbeRangeReader(
            backend: fs,
            path: "/small.bin",
            maxBytes: 0x7FFF_FFFF_FFFF_FFF0,
            fileSize: 8
        )
        let raw = await reader2.readRaw(start: 4, length: 0x7FFF_FFFF_FFFF_FFF0)
        #expect(raw == Data([5, 6, 7, 8]))

        // Strict budget cap test
        try await fs.write("/budget.bin", bytes: Data(repeating: 0xAA, count: 1024))
        var cappedReader = ProbeRangeReader(
            backend: fs,
            path: "/budget.bin",
            maxBytes: 100,
            fileSize: 1024
        )
        let first = await cappedReader.readRaw(start: 0, length: 80)
        #expect(first?.count == 80)
        #expect(cappedReader.remaining == 20)
        let second = await cappedReader.readRaw(start: 80, length: 80)
        #expect(second?.count == 20)
        #expect(cappedReader.remaining == 0)
        #expect(cappedReader.bytesRead == 100)
        let third = await cappedReader.readRaw(start: 100, length: 10)
        #expect(third == nil)

        // Zero-copy fast-path slice retains relative indexing via probe* helpers.
        var sliceReader = ProbeRangeReader(backend: fs, path: "/small.bin", maxBytes: 64, fileSize: 8)
        sliceReader.seed(start: 0, bytes: Data([10, 20, 30, 40, 50, 60, 70, 80]))
        let sliced = try #require(await sliceReader.window(offset: 3, minLength: 2))
        #expect(sliced.startIndex == 3)
        #expect(sliced == Data([40, 50, 60, 70, 80]))
        #expect(sliced.probeUInt8(at: 0) == 40)
        #expect(sliced.probeUInt16BE(at: 1) == 0x323C)
    }

    // MARK: Graceful Failure & Truncation Safety

    @Test("Returns nil on corrupt, truncated, empty, non-video, non-range, and throwing backends without crashing")
    func gracefulFailureAndTruncationSafety() async throws {
        let fs = MemoryStorageBackend()
        try await fs.write("/corrupt.mkv", bytes: Data([0x1A, 0x45, 0xDF, 0xA3, 0xFF, 0xFF]))
        try await fs.write("/truncated.mp4", bytes: Data([0, 0, 0, 32, 0x66, 0x74, 0x79, 0x70]))
        try await fs.write("/garbage.mp4", bytes: Data("not a video file at all!".utf8))
        try await fs.write("/empty.mkv", bytes: Data())
        try await fs.write("/notes.txt", bytes: Data("hello world".utf8))
        try await fs.write("/legacy.avi", bytes: Data("RIFF....AVI ".utf8))

        #expect(await probe.probe(backend: fs, path: "/corrupt.mkv") == nil)
        #expect(await probe.probe(backend: fs, path: "/truncated.mp4") == nil)
        #expect(await probe.probe(backend: fs, path: "/garbage.mp4") == nil)
        #expect(await probe.probe(backend: fs, path: "/empty.mkv") == nil)
        #expect(await probe.probe(backend: fs, path: "/notes.txt") == nil)
        #expect(await probe.probe(backend: fs, path: "/legacy.avi") == nil)
        #expect(await probe.probe(backend: fs, path: "/missing.mkv") == nil)

        #expect(await probe.probe(backend: NonRangeBackend(), path: "/movie.mkv") == nil)
        #expect(await probe.probe(backend: ThrowingRangeBackend(), path: "/movie.mkv") == nil)

        // Exhaustive byte-by-byte truncation sweep on both MKV and MP4 fixtures
        let validMkv = concat([
            ebmlHeader(),
            ebmlElem(
                0x1853_8067,
                concat([
                    mkvInfo(duration: 1000.0),
                    ebmlElem(
                        0x1654_AE6B,
                        concat([
                            mkvVideoTrack(
                                codecId: "V_MPEGH/ISO/HEVC",
                                width: 3840,
                                height: 2160,
                                transferCharacteristics: 16,
                                blockAddIdType: 0x6476_6343,
                                codecPrivate: hvccHdr10PlusRecord()
                            ),
                            mkvAudioTrack(codecId: "A_TRUEHD", channels: 8, name: "Atmos"),
                        ])
                    ),
                ])
            ),
        ])
        for cut in stride(from: 0, to: validMkv.count, by: 3) {
            let slice = validMkv.subdata(in: 0..<cut)
            let p = "/trunc_mkv_\(cut).mkv"
            try await fs.write(p, bytes: slice)
            _ = await probe.probe(backend: fs, path: p, fileSize: Int64(slice.count))
        }

        let validMp4 = concat([
            ftypBox(),
            box(
                "moov",
                concat([
                    mvhdV0(timescale: 1000, duration: 42_000),
                    trakBox([
                        videoSampleEntry(
                            "vp09",
                            width: 1280,
                            height: 720,
                            children: [colrBox(transfer: 16), dvccBox()]
                        ),
                    ]),
                    trakBox([
                        audioSampleEntry(
                            "ec-3",
                            channels: 6,
                            children: [dec3Box(atmosJoc: true)]
                        ),
                    ]),
                ])
            ),
        ])
        for cut in stride(from: 0, to: validMp4.count, by: 3) {
            let slice = validMp4.subdata(in: 0..<cut)
            let p = "/trunc_mp4_\(cut).mp4"
            try await fs.write(p, bytes: slice)
            _ = await probe.probe(backend: fs, path: p, fileSize: Int64(slice.count))
        }
    }
}
