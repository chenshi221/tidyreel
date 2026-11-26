import AppKit
import Observation
import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

// MARK: - Constants & Map Block Domain Models

let mapRestBlockId = "__rest__"

private let minMapBlockArea: Double = 2500.0
private let minPebbleThickness: CGFloat = 16.0
private let contourRingStep: Double = 7.0
private let morphRadialPoints: Int = 96

private let labelAspectBoxes: [(CGFloat, CGFloat)] = [
    (0.90, 0.40),
    (0.85, 0.55),
    (0.75, 0.65),
    (0.65, 0.75),
    (0.70, 0.45),
    (0.60, 0.55),
    (0.50, 0.50),
    (0.55, 0.35),
    (0.40, 0.40),
]

struct MapBlockItem: Equatable, Sendable, Identifiable {
    var id: String
    var entry: RemoteEntry?
    var label: String
    var shortLabel: String
    var bytes: Int64
    var caption: String?
    var state: MapBlockState
    var stats: FolderStats
    var tooltipLines: [String]
}

// MARK: - Screen-Space Placed Pebble (`_PlacedBlock` in `organic_map.dart:768-804`)

final class PlacedMapBlock {
    let block: MapBlockItem
    let polygon: [CGPoint]
    let isAlreadySmooth: Bool
    let outline: [CGPoint]
    let centroid: CGPoint
    let bounds: CGRect
    let fillPath: Path
    let inscribedBox: CGRect?

    private var cachedContourKeep: CGRect?
    private var hasBuiltContour: Bool = false
    private var cachedContourPath: Path = Path()

    init(block: MapBlockItem, polygon: [CGPoint], isAlreadySmooth: Bool = false) {
        self.block = block
        self.polygon = polygon
        self.isAlreadySmooth = isAlreadySmooth
        let smoothed = isAlreadySmooth ? polygon : OrganicGeometry.smoothPolygon(polygon)
        self.outline = smoothed
        let c = OrganicGeometry.polygonCentroid(polygon)
        self.centroid = c
        self.bounds = OrganicGeometry.polygonBounds(polygon)
        if isAlreadySmooth {
            self.fillPath = OrganicGeometry.closedPath(vertices: polygon)
            self.inscribedBox = nil
        } else {
            self.fillPath = OrganicGeometry.closedPath(vertices: smoothed)
            self.inscribedBox = Self.computeInscribedBox(outline: smoothed, centroid: c)
        }
    }

    func contoursFor(keep: CGRect?) -> Path {
        if hasBuiltContour && cachedContourKeep == keep {
            return cachedContourPath
        }
        hasBuiltContour = true
        cachedContourKeep = keep
        var path = Path()
        for ring in OrganicGeometry.contourRings(polygon, step: contourRingStep, keep: keep) {
            path.addPath(OrganicGeometry.pebblePath(ring))
        }
        cachedContourPath = path
        return path
    }

    private static func computeInscribedBox(outline: [CGPoint], centroid c: CGPoint) -> CGRect? {
        let cw = OrganicGeometry.chordWidth(outline, y: c.y)
        let ch = OrganicGeometry.chordHeight(outline, x: c.x)
        guard cw >= 40, ch >= 18 else { return nil }

        var bestW: CGFloat = 0
        var bestH: CGFloat = 0
        for (fw, fh) in labelAspectBoxes {
            let w = cw * fw
            let h = ch * fh
            if w * h <= bestW * bestH { continue }
            let candidate = CGRect(x: c.x - w * 0.5, y: c.y - h * 0.5, width: w, height: h)
            if rectInsideOutline(candidate.insetBy(dx: -4, dy: -4), outline: outline) {
                bestW = w
                bestH = h
            }
        }
        guard bestW >= 40, bestH >= 18 else { return nil }
        return CGRect(x: c.x - bestW * 0.5, y: c.y - bestH * 0.5, width: bestW, height: bestH)
    }
}

private func rectInsideOutline(_ r: CGRect, outline: [CGPoint]) -> Bool {
    OrganicGeometry.polygonContains(outline, point: CGPoint(x: r.minX, y: r.minY))
        && OrganicGeometry.polygonContains(outline, point: CGPoint(x: r.maxX, y: r.minY))
        && OrganicGeometry.polygonContains(outline, point: CGPoint(x: r.minX, y: r.maxY))
        && OrganicGeometry.polygonContains(outline, point: CGPoint(x: r.maxX, y: r.maxY))
}

// MARK: - Canvas Render Transform, Isolated Hover State, Frame Cache & Snapshot Throttle

struct MapRenderTransform: Equatable, Sendable {
    var offset: CGSize = .zero
    var scale: CGFloat = 1.0

    static let identity = MapRenderTransform()

    var isIdentity: Bool {
        abs(scale - 1.0) <= 1e-4 && abs(offset.width) <= 1e-3 && abs(offset.height) <= 1e-3
    }

    func screenToRender(_ pt: CGPoint) -> CGPoint {
        guard !isIdentity else { return pt }
        let inv = 1.0 / max(1e-4, scale)
        return CGPoint(
            x: (pt.x - offset.width) * inv,
            y: (pt.y - offset.height) * inv
        )
    }

    func visibleRenderRect(viewportSize: CGSize) -> CGRect {
        guard !isIdentity else { return CGRect(origin: .zero, size: viewportSize) }
        let inv = 1.0 / max(1e-4, scale)
        return CGRect(
            x: -offset.width * inv,
            y: -offset.height * inv,
            width: viewportSize.width * inv,
            height: viewportSize.height * inv
        )
    }
}

@Observable
@MainActor
final class MapHoverState {
    var hoveredBlockId: String?
}

@MainActor
final class MapFrameCache {
    struct CachedLabelSpec {
        var nameLines: [(text: String, size: CGSize)]
        var captionLine: (text: String, size: CGSize)?
        var nameFontSize: CGFloat
        var captionFontSize: CGFloat
        var maxLineWidth: CGFloat
        var totalHeight: CGFloat
    }

    // Non-observable pointer location & interaction view reference (zero body diffs on mouse move)
    var lastPointerLocation: CGPoint?
    weak var interactionView: InteractiveMapCanvasNSView?

    // Active render frame shared between Base Canvas, Hover Overlay, and Hit Testing
    var renderVersion: Int = 0
    var activeSourceKey: String = ""
    var activeRenderBlocks: [PlacedMapBlock] = []
    var activeRenderBlocksById: [String: PlacedMapBlock] = [:]
    var activeRenderTransform: MapRenderTransform = .identity
    var activeIsMorphing: Bool = false

    // Settled screen-space frame cache
    var pictureKey: String = ""
    var placedBlocks: [PlacedMapBlock] = []
    var placedBlocksById: [String: PlacedMapBlock] = [:]

    // World-space cache for 60fps active camera pan/zoom (no viewport clip, built once per layout/scale band)
    var worldLayoutSignature: String = ""
    var worldRefScale: CGFloat = 1.0
    var worldBlocks: [PlacedMapBlock] = []
    var worldBlocksById: [String: PlacedMapBlock] = [:]

    // Label measurement cache (capped at 512 entries)
    var labelSpecsKey: String = ""
    var labelSpecs: [String: CachedLabelSpec?] = [:]

    // Memoized signature for current blocks array
    private var lastSignatureBlocks: [MapBlockItem] = []
    private var cachedBlocksSignature: String = ""

    func signature(for blocks: [MapBlockItem]) -> String {
        if lastSignatureBlocks == blocks && (!blocks.isEmpty || cachedBlocksSignature.isEmpty) {
            return cachedBlocksSignature
        }
        lastSignatureBlocks = blocks
        cachedBlocksSignature = blocks
            .map { "\($0.id)\u{0}\($0.label)\u{0}\($0.bytes)\u{0}\($0.state.rawValue)" }
            .joined(separator: "\u{1}")
        return cachedBlocksSignature
    }
}

actor SnapshotEmitThrottle {
    private var lastDelivered: ContinuousClock.Instant?

    func shouldDeliver(isComplete: Bool, isRunning: Bool) -> Bool {
        if isComplete || !isRunning {
            lastDelivered = ContinuousClock.now
            return true
        }
        let now = ContinuousClock.now
        if let last = lastDelivered, now - last < .milliseconds(250) {
            return false
        }
        lastDelivered = now
        return true
    }
}

// MARK: - Floating Hover Card (`organic_map.dart:1585-1695`)

struct MapHoverCard: View {
    let item: MapBlockItem
    let maxWidth: CGFloat

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 2.5) {
            ForEach(Array(item.tooltipLines.enumerated()), id: \.offset) { idx, line in
                Text(line)
                    .font(.system(size: TidyreelTypeScale.small, weight: idx == 0 ? .medium : .regular))
                    .foregroundStyle(idx == 0 ? palette.text : palette.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .fill(palette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .strokeBorder(palette.line, lineWidth: hairlineWidth)
        )
    }
}

// MARK: - Canvas Renderer & Label Wrapping Helpers

@MainActor
enum MapCanvasRenderer {
    static func drawBaseCanvas(
        context: inout GraphicsContext,
        size: CGSize,
        blocks: [PlacedMapBlock],
        transform: MapRenderTransform,
        isMorphing: Bool,
        selectedPaths: Set<String>,
        blocksSignature: String,
        palette: TidyreelPalette,
        frameCache: MapFrameCache
    ) {
        syncLabelSpecsGroup(blocksSignature: blocksSignature, palette: palette, frameCache: frameCache)

        let visibleRect = transform.visibleRenderRect(viewportSize: size)
        let invScale: CGFloat = transform.isIdentity ? 1.0 : (1.0 / max(1e-4, transform.scale))

        if !transform.isIdentity {
            context.translateBy(x: transform.offset.width, y: transform.offset.height)
            context.scaleBy(x: transform.scale, y: transform.scale)
        }

        let contourWidth: CGFloat = 0.5 * invScale
        let selectionWidth: CGFloat = 2.0 * invScale

        for p in blocks {
            if !p.bounds.intersects(visibleRect) { continue }

            let isSelected = selectedPaths.contains(p.block.id)
            let fill = mapBlockFill(state: p.block.state, palette: palette, id: p.block.id)
            let ink = mapLabelInk(state: p.block.state, palette: palette, id: p.block.id)

            let placedLabel: (spec: MapFrameCache.CachedLabelSpec, rect: CGRect)?
            if isMorphing {
                placedLabel = nil
            } else {
                placedLabel = resolvePlacedLabel(for: p, ink: ink, frameCache: frameCache, in: &context)
            }

            if let fill {
                context.fill(p.fillPath, with: .color(fill))
            } else {
                context.stroke(p.fillPath, with: .color(palette.contour), lineWidth: contourWidth)

                if !isMorphing {
                    let keep = placedLabel?.rect.insetBy(dx: -6, dy: -6)
                    context.stroke(p.contoursFor(keep: keep), with: .color(palette.contour), lineWidth: contourWidth)
                }
            }

            if isSelected {
                context.fill(p.fillPath, with: .color(palette.accent.opacity(0.14)))
                context.stroke(p.fillPath, with: .color(palette.accent), lineWidth: selectionWidth)
            }

            if let (spec, labelRect) = placedLabel {
                drawResolvedLabel(spec: spec, at: labelRect, ink: ink, in: &context)
            }
        }
    }

    static func drawHoverOverlay(
        context: inout GraphicsContext,
        size: CGSize,
        hoveredBlock p: PlacedMapBlock,
        transform: MapRenderTransform,
        isMorphing: Bool,
        isSelected: Bool,
        blocksSignature: String,
        palette: TidyreelPalette,
        frameCache: MapFrameCache
    ) {
        let visibleRect = transform.visibleRenderRect(viewportSize: size)
        guard p.bounds.intersects(visibleRect) else { return }

        syncLabelSpecsGroup(blocksSignature: blocksSignature, palette: palette, frameCache: frameCache)

        let invScale: CGFloat = transform.isIdentity ? 1.0 : (1.0 / max(1e-4, transform.scale))

        if !transform.isIdentity {
            context.translateBy(x: transform.offset.width, y: transform.offset.height)
            context.scaleBy(x: transform.scale, y: transform.scale)
        }

        let fill = mapBlockFill(state: p.block.state, palette: palette, id: p.block.id)
        let ink = mapLabelInk(state: p.block.state, palette: palette, id: p.block.id)
        let placedLabel: (spec: MapFrameCache.CachedLabelSpec, rect: CGRect)?
        if isMorphing {
            placedLabel = nil
        } else {
            placedLabel = resolvePlacedLabel(for: p, ink: ink, frameCache: frameCache, in: &context)
        }

        if fill != nil {
            let hoverFill = mapHoverFill(state: p.block.state, palette: palette, id: p.block.id)
            context.fill(p.fillPath, with: .color(hoverFill))

            if isSelected {
                context.fill(p.fillPath, with: .color(palette.accent.opacity(0.14)))
                context.stroke(p.fillPath, with: .color(palette.accent), lineWidth: 2.0 * invScale)
            }

            if let (spec, labelRect) = placedLabel {
                drawResolvedLabel(spec: spec, at: labelRect, ink: ink, in: &context)
            }
        } else {
            let baseContourAlpha = palette.isDark ? 0.40 : 0.38
            let strokeColor = palette.text.opacity(min(1.0, baseContourAlpha * 1.6))
            let strokeWidth: CGFloat = 0.8 * invScale

            context.stroke(p.fillPath, with: .color(strokeColor), lineWidth: strokeWidth)

            if !isMorphing {
                let keep = placedLabel?.rect.insetBy(dx: -6, dy: -6)
                context.stroke(p.contoursFor(keep: keep), with: .color(strokeColor), lineWidth: strokeWidth)
            }

            if isSelected {
                context.stroke(p.fillPath, with: .color(palette.accent), lineWidth: 2.0 * invScale)
            }
        }
    }

    private static func syncLabelSpecsGroup(
        blocksSignature: String,
        palette: TidyreelPalette,
        frameCache: MapFrameCache
    ) {
        let specsGroupKey = "\(blocksSignature)|\(palette.isDark)"
        if frameCache.labelSpecsKey != specsGroupKey {
            frameCache.labelSpecs.removeAll(keepingCapacity: true)
            frameCache.labelSpecsKey = specsGroupKey
        }
    }

    private static func resolvePlacedLabel(
        for placed: PlacedMapBlock,
        ink: Color,
        frameCache: MapFrameCache,
        in context: inout GraphicsContext
    ) -> (spec: MapFrameCache.CachedLabelSpec, rect: CGRect)? {
        guard let box = placed.inscribedBox, box.width >= 40, box.height >= 18 else {
            return nil
        }

        let bucketW = max(40, floor(box.width / 8.0) * 8.0)
        let bucketH = max(18, floor(box.height / 6.0) * 6.0)
        let side = min(bucketW, bucketH)
        let isBig = side > 140
        let nameFontSize: CGFloat = isBig ? 17 : (side > 80 ? 13 : 11)
        let captionFontSize: CGFloat = isBig ? 17 : 12

        let cacheKey = "\(placed.block.id)#\(Int(nameFontSize))#\(Int(bucketW))x\(Int(bucketH))"
        let spec: MapFrameCache.CachedLabelSpec?
        if let hit = frameCache.labelSpecs[cacheKey] {
            spec = hit
        } else {
            let computed = buildLabelSpec(
                shortLabel: placed.block.shortLabel,
                caption: placed.block.caption,
                maxWidth: bucketW,
                maxHeight: bucketH,
                nameFontSize: nameFontSize,
                captionFontSize: captionFontSize,
                ink: ink,
                in: &context
            )
            if frameCache.labelSpecs.count > 512 {
                frameCache.labelSpecs.removeAll(keepingCapacity: true)
            }
            frameCache.labelSpecs[cacheKey] = computed
            spec = computed
        }

        guard let spec else { return nil }
        let c = placed.centroid
        let at = CGRect(
            x: c.x - spec.maxLineWidth * 0.5,
            y: c.y - spec.totalHeight * 0.5,
            width: spec.maxLineWidth,
            height: spec.totalHeight
        )
        guard rectInsideOutline(at.insetBy(dx: -4, dy: -4), outline: placed.outline) else {
            return nil
        }
        return (spec, at)
    }

    private static func buildLabelSpec(
        shortLabel: String,
        caption: String?,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        nameFontSize: CGFloat,
        captionFontSize: CGFloat,
        ink: Color,
        in context: inout GraphicsContext
    ) -> MapFrameCache.CachedLabelSpec? {
        let nameFont = Font.system(size: nameFontSize, weight: .regular).monospacedDigit()

        func measureName(_ str: String) -> CGSize {
            context.resolve(Text(str).font(nameFont).foregroundStyle(ink))
                .measure(in: CGSize(width: 10_000, height: 200))
        }

        let singleSize = measureName(shortLabel)
        let lineH = max(1, singleSize.height)
        guard lineH <= maxHeight else { return nil }

        var chosenNameLines: [(text: String, size: CGSize)]?
        if singleSize.width <= maxWidth {
            chosenNameLines = [(shortLabel, singleSize)]
        } else {
            for maxLines in stride(from: 3, through: 1, by: -1) {
                let wrapped = wrapTextLines(
                    shortLabel,
                    maxWidth: maxWidth,
                    maxLines: maxLines,
                    measure: measureName
                )
                let totalNameH = wrapped.reduce(CGFloat(0)) { $0 + $1.size.height }
                    + CGFloat(max(0, wrapped.count - 1)) * 1.5
                if !wrapped.isEmpty && totalNameH <= maxHeight {
                    chosenNameLines = wrapped
                    break
                }
            }
        }

        guard let nameLines = chosenNameLines, !nameLines.isEmpty else { return nil }
        let nameHeight = nameLines.reduce(CGFloat(0)) { $0 + $1.size.height }
            + CGFloat(max(0, nameLines.count - 1)) * 1.5
        guard nameHeight <= maxHeight else { return nil }

        var validCaption: (text: String, size: CGSize)?
        if let caption, !caption.isEmpty {
            let capFont = Font.system(size: captionFontSize, weight: .light).monospacedDigit()
            let capSize = context.resolve(Text(caption).font(capFont).foregroundStyle(ink.opacity(0.72)))
                .measure(in: CGSize(width: 10_000, height: 200))
            if capSize.width <= maxWidth && (nameHeight + 2 + capSize.height) <= maxHeight {
                validCaption = (caption, capSize)
            }
        }

        let totalH = nameHeight + (validCaption.map { 2 + $0.size.height } ?? 0)
        guard totalH <= maxHeight else { return nil }
        let maxW = max(
            nameLines.map(\.size.width).max() ?? 0,
            validCaption?.size.width ?? 0
        )

        return MapFrameCache.CachedLabelSpec(
            nameLines: nameLines,
            captionLine: validCaption,
            nameFontSize: nameFontSize,
            captionFontSize: captionFontSize,
            maxLineWidth: maxW,
            totalHeight: totalH
        )
    }

    private static func wrapTextLines(
        _ text: String,
        maxWidth: CGFloat,
        maxLines: Int,
        measure: (String) -> CGSize
    ) -> [(text: String, size: CGSize)] {
        let chars = Array(text)
        guard !chars.isEmpty, maxLines >= 1 else { return [] }

        if maxLines == 1 {
            return [truncateSingleLineWithEllipsis(chars: chars, start: 0, maxWidth: maxWidth, measure: measure)]
        }

        var lines: [(text: String, size: CGSize)] = []
        var idx = 0

        while idx < chars.count && lines.count < maxLines {
            if lines.count == maxLines - 1 {
                let remainingStr = String(chars[idx...]).trimmingCharacters(in: .whitespaces)
                let remSize = measure(remainingStr)
                if remSize.width <= maxWidth {
                    lines.append((remainingStr, remSize))
                } else {
                    lines.append(
                        truncateSingleLineWithEllipsis(
                            chars: chars,
                            start: idx,
                            maxWidth: maxWidth,
                            measure: measure
                        )
                    )
                }
                break
            }

            // Binary search longest prefix from `idx` that fits `maxWidth`
            var low = 1
            var high = chars.count - idx
            var bestLen = 1
            while low <= high {
                let mid = (low + high) / 2
                let candidate = String(chars[idx..<(idx + mid)])
                if measure(candidate).width <= maxWidth {
                    bestLen = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }

            // Prefer breaking at nearby whitespace/punctuation if within last 35% of line
            var breakLen = bestLen
            if idx + bestLen < chars.count && bestLen >= 4 {
                let minSearch = max(1, Int(Double(bestLen) * 0.65))
                for back in stride(from: bestLen, through: minSearch, by: -1) {
                    let ch = chars[idx + back - 1]
                    if ch == " " || ch == "·" || ch == "-" || ch == "_" || ch == "." || ch == "/" {
                        breakLen = back
                        break
                    }
                }
            }

            let slice = String(chars[idx..<(idx + breakLen)]).trimmingCharacters(in: .whitespaces)
            if !slice.isEmpty {
                lines.append((slice, measure(slice)))
            }
            idx += breakLen
            while idx < chars.count && chars[idx] == " " {
                idx += 1
            }
        }
        return lines
    }

    private static func truncateSingleLineWithEllipsis(
        chars: [Character],
        start: Int,
        maxWidth: CGFloat,
        measure: (String) -> CGSize
    ) -> (text: String, size: CGSize) {
        let count = chars.count - start
        guard count > 0 else {
            let s = measure("…")
            return ("…", s)
        }
        var low = 1
        var high = count
        var bestStr = String(chars[start]) + "…"
        var bestSize = measure(bestStr)

        while low <= high {
            let mid = (low + high) / 2
            let candidate = String(chars[start..<(start + mid)]).trimmingCharacters(in: .whitespaces) + "…"
            let sz = measure(candidate)
            if sz.width <= maxWidth {
                bestStr = candidate
                bestSize = sz
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return (bestStr, bestSize)
    }

    private static func drawResolvedLabel(
        spec: MapFrameCache.CachedLabelSpec,
        at rect: CGRect,
        ink: Color,
        in context: inout GraphicsContext
    ) {
        let nameFont = Font.system(size: spec.nameFontSize, weight: .regular).monospacedDigit()
        var y = rect.minY
        for (idx, line) in spec.nameLines.enumerated() {
            let resolved = context.resolve(Text(line.text).font(nameFont).foregroundStyle(ink))
            let lineRect = CGRect(
                x: rect.midX - line.size.width * 0.5,
                y: y,
                width: line.size.width,
                height: line.size.height
            )
            context.draw(resolved, in: lineRect)
            y += line.size.height + (idx < spec.nameLines.count - 1 ? 1.5 : 0)
        }

        if let cap = spec.captionLine {
            y += 2
            let capFont = Font.system(size: spec.captionFontSize, weight: .light).monospacedDigit()
            let resolvedCap = context.resolve(Text(cap.text).font(capFont).foregroundStyle(ink.opacity(0.72)))
            let capRect = CGRect(
                x: rect.midX - cap.size.width * 0.5,
                y: y,
                width: cap.size.width,
                height: cap.size.height
            )
            context.draw(resolvedCap, in: capRect)
        }
    }
}

// MARK: - Pure Geometry, Finishing & Off-MainActor Morph Helpers

/// Builds unclipped world-space `PlacedMapBlock`s scaled by `refScale` once so active
/// pan/zoom frames can composite via `GraphicsContext` transforms at 60+ fps.
func buildWorldPlacedBlocks(
    baseCells: [OrganicMapCell],
    blocks: [MapBlockItem],
    refScale: CGFloat,
    gap: Double
) -> [PlacedMapBlock] {
    let byId = Dictionary(
        blocks.map { ($0.id, $0) },
        uniquingKeysWith: { _, latest in latest }
    )
    var result: [PlacedMapBlock] = []
    result.reserveCapacity(baseCells.count)

    for cell in baseCells {
        guard let block = byId[cell.id], cell.polygon.count >= 3 else { continue }
        let scaledPoly = cell.polygon.map {
            CGPoint(x: $0.x * refScale, y: $0.y * refScale)
        }
        let insetDist = OrganicGeometry.pebbleInset(for: block.id, gap: gap)
        let insetPoly = OrganicGeometry.insetConvex(scaledPoly, by: insetDist)
        guard insetPoly.count >= 3 else { continue }

        let b = OrganicGeometry.polygonBounds(insetPoly)
        guard min(b.width, b.height) >= minPebbleThickness else { continue }

        result.append(PlacedMapBlock(block: block, polygon: insetPoly, isAlreadySmooth: false))
    }
    return result
}

func buildCameraPlacedBlocks(
    baseCells: [OrganicMapCell],
    blocks: [MapBlockItem],
    scale: CGFloat,
    offset: CGSize,
    viewport: CGSize,
    gap: Double
) -> [PlacedMapBlock] {
    let byId = Dictionary(
        blocks.map { ($0.id, $0) },
        uniquingKeysWith: { _, latest in latest }
    )
    let ox = offset.width
    let oy = offset.height
    var raw: [(MapBlockItem, [CGPoint])] = []
    raw.reserveCapacity(baseCells.count)
    for cell in baseCells {
        guard let block = byId[cell.id] else { continue }
        let screenPoly = cell.polygon.map {
            CGPoint(x: $0.x * scale + ox, y: $0.y * scale + oy)
        }
        raw.append((block, screenPoly))
    }
    return finishPlacedBlocks(rawPolygons: raw, viewport: viewport, gap: gap)
}

func buildMorphedPlacedBlocks(
    blocks: [MapBlockItem],
    fromRadials: [String: [CGPoint]],
    toRadials: [String: [CGPoint]],
    progress: Double
) -> [PlacedMapBlock] {
    let t = easeInOutCubic(progress)
    var morphed: [PlacedMapBlock] = []
    morphed.reserveCapacity(toRadials.count)
    for block in blocks {
        guard let fromPoly = fromRadials[block.id],
              let toPoly = toRadials[block.id] else { continue }
        let blended = OrganicGeometry.lerpPolygon(fromPoly, toPoly, t: t)
        if blended.count >= 3 && OrganicGeometry.polygonArea(blended) > 1.0 {
            morphed.append(PlacedMapBlock(block: block, polygon: blended, isAlreadySmooth: true))
        }
    }
    return morphed
}

func buildSemanticRestPlacedBlocks(
    blocks: [MapBlockItem],
    restPolys: [String: [CGPoint]],
    viewport: CGSize,
    gap: Double
) -> [PlacedMapBlock] {
    var raw: [(MapBlockItem, [CGPoint])] = []
    raw.reserveCapacity(restPolys.count)
    for block in blocks {
        guard let poly = restPolys[block.id] else { continue }
        raw.append((block, poly))
    }
    return finishPlacedBlocks(rawPolygons: raw, viewport: viewport, gap: gap)
}

/// `_finish` in `organic_map.dart:1008-1021`:
/// 1. Raw polygon already in screen coordinates (`0..<viewport.width`, `0..<viewport.height`)
/// 2. Check bounding-box overlap with `viewportRect`
/// 3. Clip to `viewportRect` (`clipToRect`)
/// 4. Inset in screen pixels (`insetConvex(..., by: pebbleInset(for: id, gap: 12.0))`)
/// 5. Drop slivers thinner than `16px`
/// 6. Smooth into rounded river-stone (`PlacedMapBlock` runs `smoothPolygon`)
private func finishPlacedBlocks(
    rawPolygons: [(MapBlockItem, [CGPoint])],
    viewport: CGSize,
    gap: Double
) -> [PlacedMapBlock] {
    let viewportRect = CGRect(origin: .zero, size: viewport)
    guard !viewportRect.isEmpty else { return [] }

    var result: [PlacedMapBlock] = []
    result.reserveCapacity(rawPolygons.count)

    for (block, rawScreenPoly) in rawPolygons {
        guard rawScreenPoly.count >= 3 else { continue }
        guard OrganicGeometry.polygonBounds(rawScreenPoly).intersects(viewportRect) else { continue }

        let clipped = OrganicGeometry.clipToRect(rawScreenPoly, rect: viewportRect)
        guard clipped.count >= 3 else { continue }

        let insetDist = OrganicGeometry.pebbleInset(for: block.id, gap: gap)
        let insetPoly = OrganicGeometry.insetConvex(clipped, by: insetDist)
        guard insetPoly.count >= 3 else { continue }

        let b = OrganicGeometry.polygonBounds(insetPoly)
        guard min(b.width, b.height) >= minPebbleThickness else { continue }

        result.append(PlacedMapBlock(block: block, polygon: insetPoly, isAlreadySmooth: false))
    }
    return result
}

private func drawnRadialOutline(
    id: String,
    rawScreenPoly: [CGPoint],
    viewport: CGSize,
    gap: Double
) -> [CGPoint] {
    let frame = CGRect(origin: .zero, size: viewport)
    let clipped = OrganicGeometry.clipToRect(rawScreenPoly, rect: frame)
    let insetPoly = clipped.count >= 3
        ? OrganicGeometry.insetConvex(clipped, by: OrganicGeometry.pebbleInset(for: id, gap: gap))
        : []
    if insetPoly.isEmpty {
        let c = OrganicGeometry.polygonCentroid(rawScreenPoly)
        let at = CGPoint(
            x: min(max(c.x, 0), viewport.width),
            y: min(max(c.y, 0), viewport.height)
        )
        return Array(repeating: at, count: morphRadialPoints)
    }
    return OrganicGeometry.resampleRadial(
        OrganicGeometry.smoothPolygon(insetPoly),
        count: morphRadialPoints
    )
}

func computeMorphRadials(
    baseCells: [OrganicMapCell],
    nextPolys: [String: [CGPoint]],
    shown: [String: [CGPoint]],
    was: CGRect,
    effectiveFocus: CGRect,
    viewport: CGSize,
    gap: Double
) -> (from: [String: [CGPoint]], to: [String: [CGPoint]]) {
    var cellPolyById: [String: [CGPoint]] = [:]
    cellPolyById.reserveCapacity(baseCells.count)
    for cell in baseCells {
        cellPolyById[cell.id] = cell.polygon
    }
    let allIds = Set(shown.keys).union(nextPolys.keys)

    var fromMap: [String: [CGPoint]] = [:]
    var toMap: [String: [CGPoint]] = [:]
    fromMap.reserveCapacity(allIds.count)
    toMap.reserveCapacity(allIds.count)

    for id in allIds {
        if Task.isCancelled { return ([:], [:]) }
        guard let a: [CGPoint] = shown[id]
            ?? cellPolyById[id]?.map({ mapFocusToScreen(focus: was, canvasPt: $0, viewport: viewport) })
        else { continue }

        let b: [CGPoint] = nextPolys[id] ?? a.map { pt in
            let canvasPt = mapFocusToCanvas(focus: was, screenPt: pt, viewport: viewport)
            return mapFocusToScreen(focus: effectiveFocus, canvasPt: canvasPt, viewport: viewport)
        }

        fromMap[id] = drawnRadialOutline(id: id, rawScreenPoly: a, viewport: viewport, gap: gap)
        toMap[id] = drawnRadialOutline(id: id, rawScreenPoly: b, viewport: viewport, gap: gap)
    }
    return (fromMap, toMap)
}

func computeSemanticVisibleItems(
    sourceCells: [OrganicMapCell],
    nextFocus: CGRect,
    viewport: CGSize
) -> ([OrganicMapItem], [String: CGPoint]) {
    var items: [OrganicMapItem] = []
    var seedMap: [String: CGPoint] = [:]
    let kx = nextFocus.width / viewport.width
    let ky = nextFocus.height / viewport.height
    for cell in sourceCells where cell.area > 1e-6 {
        if Task.isCancelled { return ([], [:]) }
        let part = OrganicGeometry.clipToRect(cell.polygon, rect: nextFocus)
        let partArea = OrganicGeometry.polygonArea(part)
        guard part.count >= 3, partArea > 1e-6 else { continue }
        let weight = cell.value * partArea / cell.area
        let c = OrganicGeometry.polygonCentroid(part)
        items.append(OrganicMapItem(cell.id, weight))
        seedMap[cell.id] = CGPoint(
            x: (c.x - nextFocus.minX) / kx,
            y: (c.y - nextFocus.minY) / ky
        )
    }
    return (items, seedMap)
}

func defaultFullSemanticScreenPolys(
    viewport: CGSize,
    canvas: CGSize,
    cells: [OrganicMapCell]
) -> [String: [CGPoint]] {
    guard canvas.width > 1, canvas.height > 1, viewport.width > 1, viewport.height > 1 else {
        return [:]
    }
    let sx = viewport.width / canvas.width
    let sy = viewport.height / canvas.height
    var dict: [String: [CGPoint]] = [:]
    dict.reserveCapacity(cells.count)
    for cell in cells {
        dict[cell.id] = cell.polygon.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
    }
    return dict
}

func mapFocusToCanvas(focus: CGRect, screenPt: CGPoint, viewport: CGSize) -> CGPoint {
    let kx = focus.width / max(1, viewport.width)
    let ky = focus.height / max(1, viewport.height)
    return CGPoint(
        x: focus.minX + screenPt.x * kx,
        y: focus.minY + screenPt.y * ky
    )
}

private func mapFocusToScreen(focus: CGRect, canvasPt: CGPoint, viewport: CGSize) -> CGPoint {
    let kx = focus.width / max(1, viewport.width)
    let ky = focus.height / max(1, viewport.height)
    return CGPoint(
        x: (canvasPt.x - focus.minX) / max(1e-6, kx),
        y: (canvasPt.y - focus.minY) / max(1e-6, ky)
    )
}

func computeMapItems(blocks: [MapBlockItem], viewport: CGSize) -> [OrganicMapItem] {
    let totalBytes = blocks.reduce(Int64(0)) { $0 + $1.bytes }
    let viewportArea = Double(viewport.width * viewport.height)
    let perByte = totalBytes > 0 ? viewportArea / Double(totalBytes) : 0.0
    return blocks.map { b in
        OrganicMapItem(b.id, max(Double(b.bytes) * perByte, minMapBlockArea))
    }
}

func computeMapCanvas(items: [OrganicMapItem], viewport: CGSize) -> CGSize {
    guard viewport.width > 1, viewport.height > 1 else { return .zero }
    let need = items.reduce(0.0) { $0 + $1.value }
    let have = Double(viewport.width * viewport.height)
    if need <= have * 1.25 {
        return viewport
    }
    let factor = CGFloat(sqrt(need / have))
    return CGSize(width: viewport.width * factor, height: viewport.height * factor)
}

func easeOutCubic(_ t: Double) -> Double {
    let inv = 1.0 - min(1.0, max(0.0, t))
    return 1.0 - inv * inv * inv
}

private func easeInOutCubic(_ t: Double) -> Double {
    let clamped = min(1.0, max(0.0, t))
    if clamped < 0.5 {
        return 4.0 * clamped * clamped * clamped
    } else {
        let f = -2.0 * clamped + 2.0
        return 1.0 - (f * f * f) * 0.5
    }
}

// MARK: - Exact Tone Hex, HSL ±3.5% Lightness Nudge & WCAG Luminance (`organic_map.dart:1701-1713, 1855-1859`)

private func baseToneRGB(state: MapBlockState, isDark: Bool) -> (r: Double, g: Double, b: Double)? {
    let hex: UInt32
    switch state {
    case .organized:
        hex = isDark ? 0xFFE7E4DF : 0xFF2E2A27 // dark: tones[0], light: tones[4]
    case .mixed:
        hex = isDark ? 0xFF948E88 : 0xFFA19A92 // dark: tones[1], light: tones[2]
    case .other:
        hex = isDark ? 0xFF383532 : 0xFFE7E4DF // dark: tones[3], light: tones[0]
    case .unorganized:
        return nil
    }
    return (
        Double((hex >> 16) & 0xFF) / 255.0,
        Double((hex >> 8) & 0xFF) / 255.0,
        Double(hex & 0xFF) / 255.0
    )
}

private func nudgedToneRGB(state: MapBlockState, isDark: Bool, id: String?) -> (r: Double, g: Double, b: Double)? {
    guard let base = baseToneRGB(state: state, isDark: isDark) else { return nil }
    guard let id else { return base }
    let (h, s, l) = rgbToHSL(r: base.r, g: base.g, b: base.b)
    let nudge = (OrganicGeometry.hashUnit(id) - 0.5) * 0.07 // ±3.5% lightness
    let nextL = min(1.0, max(0.0, l + nudge))
    return hslToRGB(h: h, s: s, l: nextL)
}

func mapBlockFill(state: MapBlockState, palette: TidyreelPalette, id: String?) -> Color? {
    guard let rgb = nudgedToneRGB(state: state, isDark: palette.isDark, id: id) else { return nil }
    return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1.0)
}

private func mapHoverFill(state: MapBlockState, palette: TidyreelPalette, id: String) -> Color {
    guard let rgb = nudgedToneRGB(state: state, isDark: palette.isDark, id: id) else { return .clear }
    let target = palette.isDark ? 1.0 : 0.0
    let t = 0.08
    return Color(
        .sRGB,
        red: rgb.r + (target - rgb.r) * t,
        green: rgb.g + (target - rgb.g) * t,
        blue: rgb.b + (target - rgb.b) * t,
        opacity: 1.0
    )
}

private func mapLabelInk(state: MapBlockState, palette: TidyreelPalette, id: String) -> Color {
    guard let rgb = nudgedToneRGB(state: state, isDark: palette.isDark, id: id) else {
        return palette.text
    }
    let lum = relativeLuminance(r: rgb.r, g: rgb.g, b: rgb.b)
    return lum > 0.33
        ? TidyreelPalette.color(argb: 0xFF221F1C)
        : TidyreelPalette.color(argb: 0xFFF6F5F2)
}

private func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
    func lin(_ c: Double) -> Double {
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
}

private func rgbToHSL(r: Double, g: Double, b: Double) -> (h: Double, s: Double, l: Double) {
    let maxC = max(r, max(g, b))
    let minC = min(r, min(g, b))
    let l = (maxC + minC) * 0.5
    let d = maxC - minC
    guard d > 1e-9 else { return (0, 0, l) }
    let s = l > 0.5 ? d / (2.0 - maxC - minC) : d / (maxC + minC)
    let h: Double
    if maxC == r {
        h = ((g - b) / d + (g < b ? 6.0 : 0.0)) / 6.0
    } else if maxC == g {
        h = ((b - r) / d + 2.0) / 6.0
    } else {
        h = ((r - g) / d + 4.0) / 6.0
    }
    return (h, s, l)
}

private func hslToRGB(h: Double, s: Double, l: Double) -> (r: Double, g: Double, b: Double) {
    guard s > 1e-9 else { return (l, l, l) }
    let q = l < 0.5 ? l * (1.0 + s) : (l + s - l * s)
    let p = 2.0 * l - q
    func hueToChannel(_ tRaw: Double) -> Double {
        var t = tRaw
        if t < 0 { t += 1.0 }
        if t > 1 { t -= 1.0 }
        if t < 1.0 / 6.0 { return p + (q - p) * 6.0 * t }
        if t < 0.5 { return q }
        if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6.0 }
        return p
    }
    return (
        hueToChannel(h + 1.0 / 3.0),
        hueToChannel(h),
        hueToChannel(h - 1.0 / 3.0)
    )
}
