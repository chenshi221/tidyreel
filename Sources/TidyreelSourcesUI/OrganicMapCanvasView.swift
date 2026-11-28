import AppKit
import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

// MARK: - Constants

private let screenPebbleGap: Double = 12.0

// MARK: - OrganicMapView (`organic_map.dart` — Constant Screen-Space Gap & Viewport Re-Rounding)

struct OrganicMapView: View {
    let store: AppStore
    let blocks: [MapBlockItem]
    let selectedPaths: Set<String>
    let isScanning: Bool
    let favorites: Set<String>
    let manualOrganizedMarks: [String: Bool]
    let onToggleSelect: (String) -> Void
    let onOpenDir: (String) -> Void
    let onSwitchToList: () -> Void
    let onSubmitSingle: (String, OrganizeMode?, Bool, Bool) -> Void
    let onToggleFavorite: (String) -> Void
    let onMarkOrganized: (String, Bool) -> Void

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @Environment(\.tidyreelReduceMotion) private var reduceMotion

    // Viewport & Raw Canvas Voronoi Cells (`inset: 0`)
    @State private var viewportSize: CGSize = .zero
    @State private var canvasSize: CGSize = .zero
    @State private var minCameraScale: CGFloat = 1.0
    @State private var baseCells: [OrganicMapCell] = []
    @State private var lastBaseLayoutKey: String = ""
    @State private var pendingBaseLayoutKey: String = ""
    @State private var baseLayoutTask: Task<Void, Never>?

    // Zoom Style 1: Camera (`缩放` / `.camera`)
    @State private var cameraScale: CGFloat = 1.0
    @State private var cameraOffset: CGSize = .zero
    @State private var cameraGoalScale: CGFloat = 1.0
    @State private var cameraGoalOffset: CGSize = .zero
    @State private var cameraAnimTask: Task<Void, Never>?
    @State private var isCameraInteracting: Bool = false
    @State private var cameraSettleTask: Task<Void, Never>?
    @State private var lastFittedCanvasSize: CGSize = .zero

    // Zoom Style 2: Semantic (`展开` / `.semantic`)
    @State private var semanticFocus: CGRect?
    @State private var semanticRestPolys: [String: [CGPoint]]?
    @State private var semanticRestGen: Int = 0
    @State private var semanticLayoutTask: Task<Void, Never>?
    @State private var morphFromRadials: [String: [CGPoint]] = [:]
    @State private var morphToRadials: [String: [CGPoint]] = [:]
    @State private var morphProgress: Double = 1.0
    @State private var morphTask: Task<Void, Never>?
    @State private var liveGestureScale: CGFloat = 1.0
    @State private var liveGestureFocal: CGPoint = .zero
    @State private var liveGestureTranslation: CGSize = .zero
    @State private var semanticScrollAccumulator: CGFloat = 0

    // Isolated Hover State & Non-Observable Frame Cache
    @State private var hoverState = MapHoverState()
    @State private var frameCache = MapFrameCache()

    private let maxZoomScale: CGFloat = 6.0

    private var zoomStyle: MapZoomStyle {
        store.settings.mapZoomStyle
    }

    private var isMorphing: Bool {
        morphProgress < 1.0 && !morphToRadials.isEmpty
    }

    private struct MapRenderFrameInfo {
        var renderVersion: Int
        var transform: MapRenderTransform
        var isMorphing: Bool
    }

    var body: some View {
        GeometryReader { geo in
            let vp = geo.size
            let sig = frameCache.signature(for: blocks)
            let frame = ensureRenderFrame(viewport: vp, blocksSignature: sig)

            ZStack {
                MapBaseCanvasView(
                    renderVersion: frame.renderVersion,
                    transform: frame.transform,
                    isMorphing: frame.isMorphing,
                    selectedPaths: selectedPaths,
                    blocksSignature: sig,
                    palette: palette,
                    frameCache: frameCache
                )
                .equatable()

                MapHoverOverlayView(
                    hoverState: hoverState,
                    frameCache: frameCache,
                    renderVersion: frame.renderVersion,
                    transform: frame.transform,
                    isMorphing: frame.isMorphing,
                    viewportWidth: vp.width,
                    selectedPaths: selectedPaths,
                    blocksSignature: sig,
                    palette: palette
                )
                .allowsHitTesting(false)

                MapInteractionOverlay(
                    frameCache: frameCache,
                    onHoverMove: { pt in
                        frameCache.lastPointerLocation = pt
                        return updateHover(at: pt)
                    },
                    onHoverExit: {
                        frameCache.lastPointerLocation = nil
                        if hoverState.hoveredBlockId != nil {
                            hoverState.hoveredBlockId = nil
                        }
                    },
                    onClick: { pt, modifiers in
                        handleMapClick(at: pt, modifiers: modifiers)
                    },
                    onRightClick: { pt, view in
                        handleMapRightClick(at: pt, in: view)
                    },
                    onDragStart: {
                        stopCameraAnimation()
                        if zoomStyle == .camera {
                            beginCameraInteraction()
                        } else {
                            settleSemanticMorph()
                        }
                    },
                    onDragChanged: { delta in
                        handlePanDelta(delta)
                    },
                    onDragEnded: {
                        if zoomStyle == .camera {
                            endCameraInteractionImmediately()
                        } else {
                            commitSemanticLiveGesture()
                        }
                    },
                    onScrollWheel: { dy, hasPreciseDeltas, anchor in
                        handleScrollWheel(dy: dy, hasPreciseDeltas: hasPreciseDeltas, anchor: anchor)
                    },
                    onMagnifyStart: { anchor in
                        stopCameraAnimation()
                        if zoomStyle == .camera {
                            beginCameraInteraction()
                        } else {
                            settleSemanticMorph()
                            liveGestureFocal = anchor
                        }
                    },
                    onMagnifyChanged: { factor, anchor in
                        handleMagnifyChanged(factor: factor, anchor: anchor)
                    },
                    onMagnifyEnded: {
                        if zoomStyle == .camera {
                            endCameraInteractionImmediately()
                        } else {
                            commitSemanticLiveGesture()
                        }
                    }
                )

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        OrganicMapControlsView(
                            zoomStyle: zoomStyle,
                            onSelectZoomStyle: { next in
                                store.updateSettings { $0.mapZoomStyle = next }
                            },
                            onZoomOut: {
                                zoomByButton(factor: 1.0 / 1.5)
                            },
                            onZoomIn: {
                                zoomByButton(factor: 1.5)
                            },
                            onFitAll: {
                                fitAllView()
                            }
                        )
                    }
                }
            }
            .onAppear {
                updateViewport(vp)
            }
            .onChange(of: vp) { _, newSize in
                updateViewport(newSize)
            }
            .onChange(of: blocks) { _, _ in
                scheduleBaseVoronoiLayout()
            }
            .onChange(of: isScanning) { oldVal, newVal in
                if oldVal && !newVal {
                    scheduleBaseVoronoiLayout()
                }
            }
            .onChange(of: zoomStyle) { _, nextStyle in
                resetForStyleChange(nextStyle)
            }
        }
        .onDisappear {
            baseLayoutTask?.cancel()
            cameraAnimTask?.cancel()
            cameraSettleTask?.cancel()
            semanticLayoutTask?.cancel()
            morphTask?.cancel()
        }
    }

    // MARK: - Screen-Space Finishing, World Cache & Frame Cache (`_ensurePicture` & `_finish`)

    @discardableResult
    private func ensureRenderFrame(viewport: CGSize, blocksSignature sig: String) -> MapRenderFrameInfo {
        guard viewport.width >= 16, viewport.height >= 16, !baseCells.isEmpty else {
            if !frameCache.activeRenderBlocks.isEmpty || !frameCache.activeSourceKey.isEmpty {
                frameCache.activeSourceKey = ""
                frameCache.activeRenderBlocks = []
                frameCache.activeRenderBlocksById = [:]
                frameCache.activeRenderTransform = .identity
                frameCache.activeIsMorphing = false
                frameCache.renderVersion &+= 1
            }
            return MapRenderFrameInfo(
                renderVersion: frameCache.renderVersion,
                transform: .identity,
                isMorphing: false
            )
        }

        switch zoomStyle {
        case .camera:
            if isCameraInteracting {
                let worldSig = "\(lastBaseLayoutKey)|\(sig)"
                if frameCache.worldLayoutSignature != worldSig || frameCache.worldBlocks.isEmpty {
                    let refScale = max(0.05, cameraScale)
                    let built = buildWorldPlacedBlocks(
                        baseCells: baseCells,
                        blocks: blocks,
                        refScale: refScale,
                        gap: screenPebbleGap
                    )
                    frameCache.worldLayoutSignature = worldSig
                    frameCache.worldRefScale = refScale
                    frameCache.worldBlocks = built
                    frameCache.worldBlocksById = Dictionary(
                        built.map { ($0.block.id, $0) },
                        uniquingKeysWith: { _, latest in latest }
                    )
                }

                let sourceKey = "world|\(worldSig)|\(frameCache.worldRefScale)"
                if frameCache.activeSourceKey != sourceKey {
                    frameCache.activeSourceKey = sourceKey
                    frameCache.activeRenderBlocks = frameCache.worldBlocks
                    frameCache.activeRenderBlocksById = frameCache.worldBlocksById
                    frameCache.renderVersion &+= 1
                }

                let relScale = cameraScale / max(1e-4, frameCache.worldRefScale)
                let transform = MapRenderTransform(offset: cameraOffset, scale: relScale)
                frameCache.activeRenderTransform = transform
                frameCache.activeIsMorphing = false
                return MapRenderFrameInfo(
                    renderVersion: frameCache.renderVersion,
                    transform: transform,
                    isMorphing: false
                )
            } else {
                let key = "cam|\(viewport.width)x\(viewport.height)|\(lastBaseLayoutKey)|\(sig)|\(cameraScale)|\(cameraOffset.width),\(cameraOffset.height)"
                if frameCache.pictureKey != key {
                    let computed = buildCameraPlacedBlocks(
                        baseCells: baseCells,
                        blocks: blocks,
                        scale: cameraScale,
                        offset: cameraOffset,
                        viewport: viewport,
                        gap: screenPebbleGap
                    )
                    frameCache.pictureKey = key
                    frameCache.placedBlocks = computed
                    frameCache.placedBlocksById = Dictionary(
                        computed.map { ($0.block.id, $0) },
                        uniquingKeysWith: { _, latest in latest }
                    )

                    if !frameCache.worldBlocks.isEmpty {
                        let ratio = cameraScale / max(1e-4, frameCache.worldRefScale)
                        if ratio < 0.65 || ratio > 1.55 {
                            frameCache.worldLayoutSignature = ""
                        }
                    }
                }

                if frameCache.activeSourceKey != key {
                    frameCache.activeSourceKey = key
                    frameCache.activeRenderBlocks = frameCache.placedBlocks
                    frameCache.activeRenderBlocksById = frameCache.placedBlocksById
                    frameCache.renderVersion &+= 1
                }
                frameCache.activeRenderTransform = .identity
                frameCache.activeIsMorphing = false
                return MapRenderFrameInfo(
                    renderVersion: frameCache.renderVersion,
                    transform: .identity,
                    isMorphing: false
                )
            }

        case .semantic:
            if isMorphing {
                let key = "sem-morph|\(viewport.width)x\(viewport.height)|\(lastBaseLayoutKey)|\(sig)|\(semanticRestGen)|\(morphProgress)"
                if frameCache.pictureKey != key {
                    let morphed = buildMorphedPlacedBlocks(
                        blocks: blocks,
                        fromRadials: morphFromRadials,
                        toRadials: morphToRadials,
                        progress: morphProgress
                    )
                    frameCache.pictureKey = key
                    frameCache.placedBlocks = morphed
                    frameCache.placedBlocksById = Dictionary(
                        morphed.map { ($0.block.id, $0) },
                        uniquingKeysWith: { _, latest in latest }
                    )
                }

                if frameCache.activeSourceKey != key {
                    frameCache.activeSourceKey = key
                    frameCache.activeRenderBlocks = frameCache.placedBlocks
                    frameCache.activeRenderBlocksById = frameCache.placedBlocksById
                    frameCache.renderVersion &+= 1
                }
                frameCache.activeRenderTransform = .identity
                frameCache.activeIsMorphing = true
                return MapRenderFrameInfo(
                    renderVersion: frameCache.renderVersion,
                    transform: .identity,
                    isMorphing: true
                )
            } else {
                let restKey = "sem-rest|\(viewport.width)x\(viewport.height)|\(lastBaseLayoutKey)|\(sig)|\(semanticRestGen)"
                if frameCache.pictureKey != restKey {
                    let rest = currentSemanticRestPolys(viewport: viewport)
                    let computed = buildSemanticRestPlacedBlocks(
                        blocks: blocks,
                        restPolys: rest,
                        viewport: viewport,
                        gap: screenPebbleGap
                    )
                    frameCache.pictureKey = restKey
                    frameCache.placedBlocks = computed
                    frameCache.placedBlocksById = Dictionary(
                        computed.map { ($0.block.id, $0) },
                        uniquingKeysWith: { _, latest in latest }
                    )
                }

                if frameCache.activeSourceKey != restKey {
                    frameCache.activeSourceKey = restKey
                    frameCache.activeRenderBlocks = frameCache.placedBlocks
                    frameCache.activeRenderBlocksById = frameCache.placedBlocksById
                    frameCache.renderVersion &+= 1
                }

                let hasGesture = abs(liveGestureScale - 1.0) > 1e-4
                    || abs(liveGestureTranslation.width) > 0.1
                    || abs(liveGestureTranslation.height) > 0.1
                let transform: MapRenderTransform
                if hasGesture {
                    let s = liveGestureScale
                    let c = liveGestureFocal
                    transform = MapRenderTransform(
                        offset: CGSize(
                            width: c.x * (1.0 - s) + liveGestureTranslation.width,
                            height: c.y * (1.0 - s) + liveGestureTranslation.height
                        ),
                        scale: s
                    )
                } else {
                    transform = .identity
                }
                frameCache.activeRenderTransform = transform
                frameCache.activeIsMorphing = false
                return MapRenderFrameInfo(
                    renderVersion: frameCache.renderVersion,
                    transform: transform,
                    isMorphing: false
                )
            }
        }
    }

    // MARK: - Off-Main-Thread Base Voronoi Layout (`inset: 0`)

    private func updateViewport(_ newSize: CGSize) {
        guard newSize.width >= 16, newSize.height >= 16 else { return }
        let changed = abs(newSize.width - viewportSize.width) > 0.5
            || abs(newSize.height - viewportSize.height) > 0.5
        viewportSize = newSize
        if changed || baseCells.isEmpty {
            scheduleBaseVoronoiLayout()
        }
    }

    private func scheduleBaseVoronoiLayout() {
        let vp = viewportSize
        let currentBlocks = blocks
        guard vp.width >= 16, vp.height >= 16, !currentBlocks.isEmpty else {
            baseLayoutTask?.cancel()
            baseCells = []
            lastBaseLayoutKey = ""
            pendingBaseLayoutKey = ""
            return
        }

        let items = computeMapItems(blocks: currentBlocks, viewport: vp)
        let targetCanvas = computeMapCanvas(items: items, viewport: vp)
        let rough = isScanning && items.count > 60
        let key = "\(rough)|\(Int(targetCanvas.width.rounded()))x\(Int(targetCanvas.height.rounded()))|"
            + items.map { "\($0.id):\($0.value.rounded())" }.joined(separator: ",")

        if key == lastBaseLayoutKey {
            pendingBaseLayoutKey = ""
            return
        }
        if key == pendingBaseLayoutKey {
            return
        }

        baseLayoutTask?.cancel()
        pendingBaseLayoutKey = key
        let iterations = rough ? 30 : 120
        let bounds = CGRect(origin: .zero, size: targetCanvas)
        let fit = min(1.0, min(vp.width / max(1, targetCanvas.width), vp.height / max(1, targetCanvas.height)))

        baseLayoutTask = Task {
            let cells = await OrganicGeometry.layoutAsync(
                items: items,
                bounds: bounds,
                iterations: iterations,
                seeds: nil,
                inset: 0
            )
            guard !Task.isCancelled, !cells.isEmpty else { return }

            await MainActor.run {
                guard pendingBaseLayoutKey == key else { return }
                pendingBaseLayoutKey = ""
                lastBaseLayoutKey = key
                canvasSize = targetCanvas
                minCameraScale = fit
                baseCells = cells
                frameCache.worldLayoutSignature = ""
                semanticRestPolys = nil
                semanticRestGen &+= 1

                if lastFittedCanvasSize != targetCanvas {
                    lastFittedCanvasSize = targetCanvas
                    stopCameraAnimation()
                    cameraSettleTask?.cancel()
                    cameraSettleTask = nil
                    isCameraInteracting = false
                    let fittedOffset = CGSize(
                        width: (vp.width - targetCanvas.width * fit) * 0.5,
                        height: (vp.height - targetCanvas.height * fit) * 0.5
                    )
                    cameraScale = fit
                    cameraOffset = fittedOffset
                    cameraGoalScale = fit
                    cameraGoalOffset = fittedOffset
                    semanticFocus = nil
                    settleSemanticMorph()
                } else {
                    cameraScale = max(minCameraScale, min(maxZoomScale, cameraScale))
                    clampCameraOffset()
                    cameraGoalScale = cameraScale
                    cameraGoalOffset = cameraOffset
                }

                if zoomStyle == .semantic, let existingFocus = semanticFocus {
                    let full = CGRect(origin: .zero, size: targetCanvas)
                    let shown = defaultFullSemanticScreenPolys(viewport: vp, canvas: targetCanvas, cells: cells)
                    triggerSemanticReflow(to: existingFocus, shown: shown, was: full, animated: false)
                }
            }
        }
    }

    // MARK: - Hit Testing & Click / Context Menu (`repo_map_view.dart:322-343`)

    private func hitTest(at screenPt: CGPoint) -> PlacedMapBlock? {
        let pt = frameCache.activeRenderTransform.screenToRender(screenPt)
        for b in frameCache.activeRenderBlocks {
            if b.bounds.contains(pt) && OrganicGeometry.polygonContains(b.polygon, point: pt) {
                return b
            }
        }
        return nil
    }

    @discardableResult
    private func updateHover(at pt: CGPoint) -> Bool {
        let next = hitTest(at: pt)?.block.id
        if hoverState.hoveredBlockId != next {
            hoverState.hoveredBlockId = next
        }
        return next != nil
    }

    private func handleMapClick(
        at pt: CGPoint,
        modifiers: NSEvent.ModifierFlags
    ) {
        guard let hit = hitTest(at: pt) else { return }
        if hit.block.id == mapRestBlockId {
            onSwitchToList()
            return
        }
        guard let entry = hit.block.entry else { return }

        let adding = modifiers.contains(.command)
            || modifiers.contains(.shift)
            || modifiers.contains(.control)

        if entry.isDir && !adding {
            onOpenDir(entry.path)
        } else {
            onToggleSelect(entry.path)
        }
    }

    private func handleMapRightClick(
        at pt: CGPoint,
        in view: NSView
    ) {
        guard let hit = hitTest(at: pt),
              let entry = hit.block.entry else { return }

        presentMapEntryContextMenu(
            for: entry,
            at: pt,
            in: view,
            store: store,
            l10n: l10n,
            selectedPaths: selectedPaths,
            favorites: favorites,
            manualOrganizedMarks: manualOrganizedMarks,
            onOpenDir: onOpenDir,
            onSubmitSingle: onSubmitSingle,
            onToggleSelect: onToggleSelect,
            onToggleFavorite: onToggleFavorite,
            onMarkOrganized: onMarkOrganized
        )
    }

    // MARK: - Camera & Semantic Zoom / Pan Mechanics

    private func beginCameraInteraction() {
        cameraSettleTask?.cancel()
        cameraSettleTask = nil
        if !isCameraInteracting {
            isCameraInteracting = true
        }
    }

    private func scheduleCameraSettle() {
        cameraSettleTask?.cancel()
        cameraSettleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            cameraSettleTask = nil
            isCameraInteracting = false
            refreshHoverAtLastPointer()
        }
    }

    private func endCameraInteractionImmediately() {
        cameraSettleTask?.cancel()
        cameraSettleTask = nil
        if isCameraInteracting {
            isCameraInteracting = false
        }
        refreshHoverAtLastPointer()
    }

    private func stopCameraAnimation() {
        cameraAnimTask?.cancel()
        cameraAnimTask = nil
        cameraGoalScale = cameraScale
        cameraGoalOffset = cameraOffset
    }

    private func animateCamera(toScale targetScale: CGFloat, toOffset targetOffset: CGSize) {
        cameraAnimTask?.cancel()
        let clampedScale = min(maxZoomScale, max(minCameraScale, targetScale))
        let clampedOffset = clampOffset(targetOffset, forScale: clampedScale)
        cameraGoalScale = clampedScale
        cameraGoalOffset = clampedOffset

        if reduceMotion {
            cameraSettleTask?.cancel()
            cameraSettleTask = nil
            isCameraInteracting = false
            cameraScale = clampedScale
            cameraOffset = clampedOffset
            refreshHoverAtLastPointer()
            return
        }

        beginCameraInteraction()
        let startScale = cameraScale
        let startOffset = cameraOffset
        cameraAnimTask = Task { @MainActor in
            let start = ContinuousClock.now
            let durationMs = 260.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(12))
                guard !Task.isCancelled else { return }
                let elapsed = start.duration(to: ContinuousClock.now)
                let ms = Double(elapsed.components.seconds) * 1000.0
                    + Double(elapsed.components.attoseconds) / 1e15
                let rawT = min(1.0, max(0.0, ms / durationMs))
                let t = CGFloat(easeOutCubic(rawT))
                cameraScale = startScale + (clampedScale - startScale) * t
                cameraOffset = CGSize(
                    width: startOffset.width + (clampedOffset.width - startOffset.width) * t,
                    height: startOffset.height + (clampedOffset.height - startOffset.height) * t
                )
                if rawT >= 1.0 {
                    cameraAnimTask = nil
                    isCameraInteracting = false
                    refreshHoverAtLastPointer()
                    break
                } else {
                    refreshHoverAtLastPointer()
                }
            }
        }
    }

    private func handlePanDelta(_ delta: CGSize) {
        switch zoomStyle {
        case .camera:
            stopCameraAnimation()
            beginCameraInteraction()
            cameraOffset = CGSize(
                width: cameraOffset.width + delta.width,
                height: cameraOffset.height + delta.height
            )
            clampCameraOffset()
            cameraGoalOffset = cameraOffset
        case .semantic:
            liveGestureTranslation = CGSize(
                width: liveGestureTranslation.width + delta.width,
                height: liveGestureTranslation.height + delta.height
            )
        }
        refreshHoverAtLastPointer()
    }

    private func handleScrollWheel(dy: CGFloat, hasPreciseDeltas: Bool, anchor: CGPoint) {
        guard abs(dy) > 0.05 else { return }
        switch zoomStyle {
        case .camera:
            stopCameraAnimation()
            beginCameraInteraction()
            let sensitivity: CGFloat = hasPreciseDeltas ? 0.008 : 0.08
            let factor = exp(min(0.45, max(-0.45, dy * sensitivity)))
            applyImmediateCameraZoom(factor: factor, anchor: anchor)
            scheduleCameraSettle()

        case .semantic:
            guard !isMorphing, semanticLayoutTask == nil else { return }
            if hasPreciseDeltas {
                semanticScrollAccumulator += dy
                let threshold: CGFloat = 18.0
                guard abs(semanticScrollAccumulator) >= threshold else { return }
                let zoomIn = semanticScrollAccumulator > 0
                semanticScrollAccumulator = 0
                semanticZoom(by: zoomIn ? 1.5 : (1.0 / 1.5), around: anchor)
            } else {
                guard abs(dy) >= 0.4 else { return }
                semanticZoom(by: dy > 0 ? 1.5 : (1.0 / 1.5), around: anchor)
            }
        }
    }

    private func handleMagnifyChanged(factor: CGFloat, anchor: CGPoint) {
        guard factor.isFinite, factor > 0.01 else { return }
        switch zoomStyle {
        case .camera:
            beginCameraInteraction()
            applyImmediateCameraZoom(factor: factor, anchor: anchor)
        case .semantic:
            liveGestureFocal = anchor
            liveGestureScale = min(4.0, max(0.35, liveGestureScale * factor))
            refreshHoverAtLastPointer()
        }
    }

    private func applyImmediateCameraZoom(factor: CGFloat, anchor: CGPoint) {
        let nextScale = min(maxZoomScale, max(minCameraScale, cameraScale * factor))
        let actualFactor = nextScale / max(1e-4, cameraScale)
        let rawOffset = CGSize(
            width: anchor.x - (anchor.x - cameraOffset.width) * actualFactor,
            height: anchor.y - (anchor.y - cameraOffset.height) * actualFactor
        )
        cameraScale = nextScale
        cameraOffset = clampOffset(rawOffset, forScale: nextScale)
        cameraGoalScale = cameraScale
        cameraGoalOffset = cameraOffset
        refreshHoverAtLastPointer()
    }

    private func zoomByButton(factor: CGFloat) {
        let center = CGPoint(x: viewportSize.width * 0.5, y: viewportSize.height * 0.5)
        switch zoomStyle {
        case .camera:
            let baseScale = cameraAnimTask != nil ? cameraGoalScale : cameraScale
            let baseOffset = cameraAnimTask != nil ? cameraGoalOffset : cameraOffset
            let targetScale = min(maxZoomScale, max(minCameraScale, baseScale * factor))
            let actualFactor = targetScale / max(1e-4, baseScale)
            let targetOffset = CGSize(
                width: center.x - (center.x - baseOffset.width) * actualFactor,
                height: center.y - (center.y - baseOffset.height) * actualFactor
            )
            animateCamera(toScale: targetScale, toOffset: targetOffset)

        case .semantic:
            semanticZoom(by: factor, around: center)
        }
    }

    private func fitAllView() {
        switch zoomStyle {
        case .camera:
            let fittedOffset = CGSize(
                width: (viewportSize.width - canvasSize.width * minCameraScale) * 0.5,
                height: (viewportSize.height - canvasSize.height * minCameraScale) * 0.5
            )
            animateCamera(toScale: minCameraScale, toOffset: fittedOffset)

        case .semantic:
            settleSemanticMorph()
            let full = CGRect(origin: .zero, size: canvasSize)
            let shown = currentSemanticRestPolys(viewport: viewportSize)
            let was = semanticFocus ?? full
            triggerSemanticReflow(to: full, shown: shown, was: was, animated: true)
        }
    }

    private func resetForStyleChange(_ nextStyle: MapZoomStyle) {
        stopCameraAnimation()
        cameraSettleTask?.cancel()
        cameraSettleTask = nil
        isCameraInteracting = false
        semanticLayoutTask?.cancel()
        semanticLayoutTask = nil
        settleSemanticMorph()
        semanticFocus = nil
        semanticRestPolys = nil
        semanticRestGen &+= 1
        liveGestureScale = 1.0
        liveGestureTranslation = .zero
        semanticScrollAccumulator = 0

        let fittedOffset = CGSize(
            width: (viewportSize.width - canvasSize.width * minCameraScale) * 0.5,
            height: (viewportSize.height - canvasSize.height * minCameraScale) * 0.5
        )
        cameraScale = minCameraScale
        cameraOffset = fittedOffset
        cameraGoalScale = minCameraScale
        cameraGoalOffset = fittedOffset
        refreshHoverAtLastPointer()
    }

    // MARK: - Semantic Zoom Reflow & 0.34s Morph (`organic_map.dart:1100-1208`)

    private func currentSemanticRestPolys(viewport: CGSize) -> [String: [CGPoint]] {
        if let existing = semanticRestPolys {
            return existing
        }
        return defaultFullSemanticScreenPolys(viewport: viewport, canvas: canvasSize, cells: baseCells)
    }

    private func settleSemanticMorph() {
        morphTask?.cancel()
        morphTask = nil
        morphProgress = 1.0
        morphFromRadials = [:]
        morphToRadials = [:]
    }

    private func semanticZoom(by factor: CGFloat, around screenPoint: CGPoint) {
        settleSemanticMorph()
        let full = CGRect(origin: .zero, size: canvasSize)
        guard !full.isEmpty, viewportSize.width > 1, viewportSize.height > 1 else { return }
        let cur = semanticFocus ?? full
        let c = mapFocusToCanvas(focus: cur, screenPt: screenPoint, viewport: viewportSize)
        let nextW = cur.width / factor
        let nextH = cur.height / factor
        let rx = (c.x - cur.minX) / cur.width
        let ry = (c.y - cur.minY) / cur.height
        let rawFocus = CGRect(
            x: c.x - nextW * rx,
            y: c.y - nextH * ry,
            width: nextW,
            height: nextH
        )
        let shown = currentSemanticRestPolys(viewport: viewportSize)
        triggerSemanticReflow(to: rawFocus, shown: shown, was: cur, animated: true)
    }

    private func commitSemanticLiveGesture() {
        let s = liveGestureScale
        let tx = liveGestureTranslation.width
        let ty = liveGestureTranslation.height
        guard abs(s - 1.0) > 0.01 || hypot(tx, ty) > 2.0 else {
            liveGestureScale = 1.0
            liveGestureTranslation = .zero
            return
        }
        let full = CGRect(origin: .zero, size: canvasSize)
        guard !full.isEmpty, viewportSize.width > 1, viewportSize.height > 1 else { return }
        let cur = semanticFocus ?? full

        let tlScreen = inverseTransformSemanticGesturePoint(.zero)
        let brScreen = inverseTransformSemanticGesturePoint(
            CGPoint(x: viewportSize.width, y: viewportSize.height)
        )
        let tlCanvas = mapFocusToCanvas(focus: cur, screenPt: tlScreen, viewport: viewportSize)
        let brCanvas = mapFocusToCanvas(focus: cur, screenPt: brScreen, viewport: viewportSize)
        let was = CGRect(
            x: min(tlCanvas.x, brCanvas.x),
            y: min(tlCanvas.y, brCanvas.y),
            width: max(8, abs(brCanvas.x - tlCanvas.x)),
            height: max(8, abs(brCanvas.y - tlCanvas.y))
        )

        let rest = currentSemanticRestPolys(viewport: viewportSize)
        var shown: [String: [CGPoint]] = [:]
        shown.reserveCapacity(rest.count)
        for (id, poly) in rest {
            shown[id] = poly.map { transformSemanticGesturePoint($0) }
        }
        triggerSemanticReflow(to: was, shown: shown, was: was, animated: true)
    }

    private func triggerSemanticReflow(
        to rawFocus: CGRect,
        shown: [String: [CGPoint]],
        was: CGRect,
        animated: Bool
    ) {
        semanticLayoutTask?.cancel()
        let vp = viewportSize
        let full = CGRect(origin: .zero, size: canvasSize)
        let sourceCells = baseCells
        guard vp.width >= 16, vp.height >= 16, !full.isEmpty, !sourceCells.isEmpty else { return }

        let nextFocus = clampSemanticFocus(rawFocus, in: full)
        let isFull = abs(nextFocus.width - full.width) < 0.5 && abs(nextFocus.height - full.height) < 0.5
        let shouldAnimate = animated && !reduceMotion && !shown.isEmpty

        if isFull {
            let nextPolys = defaultFullSemanticScreenPolys(viewport: vp, canvas: canvasSize, cells: sourceCells)
            guard shouldAnimate else {
                semanticLayoutTask = nil
                applySemanticTransition(
                    nextFocus: nil,
                    nextPolys: nextPolys,
                    precomputedMorph: nil
                )
                return
            }

            semanticLayoutTask = Task {
                let radialWorker = Task.detached(priority: .userInitiated) {
                    computeMorphRadials(
                        baseCells: sourceCells,
                        nextPolys: nextPolys,
                        shown: shown,
                        was: was,
                        effectiveFocus: full,
                        viewport: vp,
                        gap: screenPebbleGap
                    )
                }
                let radials = await withTaskCancellationHandler {
                    await radialWorker.value
                } onCancel: {
                    radialWorker.cancel()
                }
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    semanticLayoutTask = nil
                    applySemanticTransition(
                        nextFocus: nil,
                        nextPolys: nextPolys,
                        precomputedMorph: radials
                    )
                }
            }
            return
        }

        let vpRect = CGRect(origin: .zero, size: vp)
        semanticLayoutTask = Task {
            let prepWorker = Task.detached(priority: .userInitiated) {
                computeSemanticVisibleItems(
                    sourceCells: sourceCells,
                    nextFocus: nextFocus,
                    viewport: vp
                )
            }
            let (visibleItems, seeds) = await withTaskCancellationHandler {
                await prepWorker.value
            } onCancel: {
                prepWorker.cancel()
            }

            guard !Task.isCancelled else { return }
            guard !visibleItems.isEmpty else {
                await MainActor.run {
                    if !Task.isCancelled { semanticLayoutTask = nil }
                }
                return
            }

            let iterations = visibleItems.count > 60 ? 40 : 80
            let cells = await OrganicGeometry.layoutAsync(
                items: visibleItems,
                bounds: vpRect,
                iterations: iterations,
                seeds: seeds,
                inset: 0
            )
            guard !Task.isCancelled else { return }
            guard !cells.isEmpty else {
                await MainActor.run {
                    if !Task.isCancelled { semanticLayoutTask = nil }
                }
                return
            }

            let nextPolys = Dictionary(
                cells.map { ($0.id, $0.polygon) },
                uniquingKeysWith: { _, latest in latest }
            )

            let precomputedMorph: (from: [String: [CGPoint]], to: [String: [CGPoint]])?
            if shouldAnimate {
                let radialWorker = Task.detached(priority: .userInitiated) {
                    computeMorphRadials(
                        baseCells: sourceCells,
                        nextPolys: nextPolys,
                        shown: shown,
                        was: was,
                        effectiveFocus: nextFocus,
                        viewport: vp,
                        gap: screenPebbleGap
                    )
                }
                let radials = await withTaskCancellationHandler {
                    await radialWorker.value
                } onCancel: {
                    radialWorker.cancel()
                }
                guard !Task.isCancelled else { return }
                precomputedMorph = radials
            } else {
                precomputedMorph = nil
            }

            await MainActor.run {
                guard !Task.isCancelled else { return }
                semanticLayoutTask = nil
                applySemanticTransition(
                    nextFocus: nextFocus,
                    nextPolys: nextPolys,
                    precomputedMorph: precomputedMorph
                )
            }
        }
    }

    private func applySemanticTransition(
        nextFocus: CGRect?,
        nextPolys: [String: [CGPoint]],
        precomputedMorph: (from: [String: [CGPoint]], to: [String: [CGPoint]])?
    ) {
        semanticFocus = nextFocus
        semanticRestPolys = nextPolys
        semanticRestGen &+= 1
        liveGestureScale = 1.0
        liveGestureTranslation = .zero

        guard let (fromMap, toMap) = precomputedMorph, !toMap.isEmpty else {
            settleSemanticMorph()
            refreshHoverAtLastPointer()
            return
        }

        morphTask?.cancel()
        morphFromRadials = fromMap
        morphToRadials = toMap
        morphProgress = 0.0

        morphTask = Task { @MainActor in
            let start = ContinuousClock.now
            let durationMs = 340.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(12))
                guard !Task.isCancelled else { return }
                let elapsed = start.duration(to: ContinuousClock.now)
                let ms = Double(elapsed.components.seconds) * 1000.0
                    + Double(elapsed.components.attoseconds) / 1e15
                let t = min(1.0, max(0.0, ms / durationMs))
                morphProgress = t
                if t >= 1.0 {
                    settleSemanticMorph()
                    refreshHoverAtLastPointer()
                    break
                }
            }
        }
    }

    // MARK: - Coordinate & Clamping Helpers

    private func refreshHoverAtLastPointer() {
        guard let ptr = frameCache.lastPointerLocation else { return }
        ensureRenderFrame(viewport: viewportSize, blocksSignature: frameCache.signature(for: blocks))
        let hasHit = updateHover(at: ptr)
        frameCache.interactionView?.hasHoveredPebble = hasHit
    }

    private func clampCameraOffset() {
        cameraOffset = clampOffset(cameraOffset, forScale: cameraScale)
    }

    private func clampOffset(_ raw: CGSize, forScale scale: CGFloat) -> CGSize {
        let scaledW = canvasSize.width * scale
        let scaledH = canvasSize.height * scale
        let vpW = viewportSize.width
        let vpH = viewportSize.height

        let x: CGFloat = scaledW <= vpW
            ? (vpW - scaledW) * 0.5
            : min(0, max(vpW - scaledW, raw.width))
        let y: CGFloat = scaledH <= vpH
            ? (vpH - scaledH) * 0.5
            : min(0, max(vpH - scaledH, raw.height))
        return CGSize(width: x, height: y)
    }

    private func clampSemanticFocus(_ raw: CGRect, in full: CGRect) -> CGRect {
        guard full.width > 1, full.height > 1 else { return full }
        let minW = full.width / maxZoomScale
        let w = min(full.width, max(minW, raw.width))
        let h = w * (full.height / full.width)
        let x = min(max(full.minX, raw.midX - w * 0.5), full.maxX - w)
        let y = min(max(full.minY, raw.midY - h * 0.5), full.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func transformSemanticGesturePoint(_ pt: CGPoint) -> CGPoint {
        let s = liveGestureScale
        let c = liveGestureFocal
        return CGPoint(
            x: c.x + (pt.x - c.x) * s + liveGestureTranslation.width,
            y: c.y + (pt.y - c.y) * s + liveGestureTranslation.height
        )
    }

    private func inverseTransformSemanticGesturePoint(_ screenPt: CGPoint) -> CGPoint {
        let s = max(1e-4, liveGestureScale)
        let c = liveGestureFocal
        return CGPoint(
            x: c.x + (screenPt.x - liveGestureTranslation.width - c.x) / s,
            y: c.y + (screenPt.y - liveGestureTranslation.height - c.y) / s
        )
    }
}

// MARK: - Layered Base Canvas & Lightweight Hover Overlay

private struct MapBaseCanvasView: View, Equatable {
    let renderVersion: Int
    let transform: MapRenderTransform
    let isMorphing: Bool
    let selectedPaths: Set<String>
    let blocksSignature: String
    let palette: TidyreelPalette
    let frameCache: MapFrameCache

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.renderVersion == rhs.renderVersion
            && lhs.transform == rhs.transform
            && lhs.isMorphing == rhs.isMorphing
            && lhs.selectedPaths == rhs.selectedPaths
            && lhs.blocksSignature == rhs.blocksSignature
            && lhs.palette == rhs.palette
    }

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            MapCanvasRenderer.drawBaseCanvas(
                context: &context,
                size: size,
                blocks: frameCache.activeRenderBlocks,
                transform: transform,
                isMorphing: isMorphing,
                selectedPaths: selectedPaths,
                blocksSignature: blocksSignature,
                palette: palette,
                frameCache: frameCache
            )
        }
    }
}

private struct MapHoverOverlayView: View {
    let hoverState: MapHoverState
    let frameCache: MapFrameCache
    let renderVersion: Int
    let transform: MapRenderTransform
    let isMorphing: Bool
    let viewportWidth: CGFloat
    let selectedPaths: Set<String>
    let blocksSignature: String
    let palette: TidyreelPalette

    var body: some View {
        let _ = renderVersion
        if let hoveredId = hoverState.hoveredBlockId,
           let hoveredBlock = frameCache.activeRenderBlocksById[hoveredId] {
            ZStack {
                Canvas(rendersAsynchronously: false) { context, size in
                    MapCanvasRenderer.drawHoverOverlay(
                        context: &context,
                        size: size,
                        hoveredBlock: hoveredBlock,
                        transform: transform,
                        isMorphing: isMorphing,
                        isSelected: selectedPaths.contains(hoveredBlock.block.id),
                        blocksSignature: blocksSignature,
                        palette: palette,
                        frameCache: frameCache
                    )
                }

                VStack {
                    Spacer()
                    HStack {
                        MapHoverCard(
                            item: hoveredBlock.block,
                            maxWidth: min(viewportWidth * 0.55, 340)
                        )
                        Spacer()
                    }
                }
            }
        }
    }
}

// MARK: - Native AppKit Interaction Overlay

private struct MapInteractionOverlay: NSViewRepresentable {
    var frameCache: MapFrameCache
    var onHoverMove: (CGPoint) -> Bool
    var onHoverExit: () -> Void
    var onClick: (CGPoint, NSEvent.ModifierFlags) -> Void
    var onRightClick: (CGPoint, NSView) -> Void
    var onDragStart: () -> Void
    var onDragChanged: (CGSize) -> Void
    var onDragEnded: () -> Void
    var onScrollWheel: (CGFloat, Bool, CGPoint) -> Void
    var onMagnifyStart: (CGPoint) -> Void
    var onMagnifyChanged: (CGFloat, CGPoint) -> Void
    var onMagnifyEnded: () -> Void

    func makeNSView(context: Context) -> InteractiveMapCanvasNSView {
        let v = InteractiveMapCanvasNSView()
        assignCallbacks(to: v)
        frameCache.interactionView = v
        return v
    }

    func updateNSView(_ nsView: InteractiveMapCanvasNSView, context: Context) {
        assignCallbacks(to: nsView)
        frameCache.interactionView = nsView
    }

    private func assignCallbacks(to v: InteractiveMapCanvasNSView) {
        v.onHoverMove = onHoverMove
        v.onHoverExit = onHoverExit
        v.onClick = onClick
        v.onRightClick = onRightClick
        v.onDragStart = onDragStart
        v.onDragChanged = onDragChanged
        v.onDragEnded = onDragEnded
        v.onScrollWheel = onScrollWheel
        v.onMagnifyStart = onMagnifyStart
        v.onMagnifyChanged = onMagnifyChanged
        v.onMagnifyEnded = onMagnifyEnded
    }
}

final class InteractiveMapCanvasNSView: NSView {
    var hasHoveredPebble: Bool = false {
        didSet {
            if !isDragging && oldValue != hasHoveredPebble {
                window?.invalidateCursorRects(for: self)
            }
        }
    }
    var onHoverMove: ((CGPoint) -> Bool)?
    var onHoverExit: (() -> Void)?
    var onClick: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    var onRightClick: ((CGPoint, NSView) -> Void)?
    var onDragStart: (() -> Void)?
    var onDragChanged: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?
    var onScrollWheel: ((CGFloat, Bool, CGPoint) -> Void)?
    var onMagnifyStart: ((CGPoint) -> Void)?
    var onMagnifyChanged: ((CGFloat, CGPoint) -> Void)?
    var onMagnifyEnded: (() -> Void)?

    private var trackingAreaRef: NSTrackingArea?
    private var mouseDownPoint: CGPoint?
    private var lastDragPoint: CGPoint?
    private var isDragging: Bool = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isDragging {
            addCursorRect(bounds, cursor: .closedHand)
        } else if hasHoveredPebble {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        hasHoveredPebble = onHoverMove?(convert(event.locationInWindow, from: nil)) ?? false
    }

    override func mouseEntered(with event: NSEvent) {
        hasHoveredPebble = onHoverMove?(convert(event.locationInWindow, from: nil)) ?? false
    }

    override func mouseExited(with event: NSEvent) {
        hasHoveredPebble = false
        onHoverExit?()
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.control) {
            onRightClick?(pt, self)
            return
        }
        mouseDownPoint = pt
        lastDragPoint = pt
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard let down = mouseDownPoint, let prev = lastDragPoint else { return }
        if !isDragging && hypot(pt.x - down.x, pt.y - down.y) >= 4.0 {
            isDragging = true
            onDragStart?()
            window?.invalidateCursorRects(for: self)
        }
        if isDragging {
            let delta = CGSize(width: pt.x - prev.x, height: pt.y - prev.y)
            lastDragPoint = pt
            onDragChanged?(delta)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let wasDragging = isDragging
        mouseDownPoint = nil
        lastDragPoint = nil
        isDragging = false
        window?.invalidateCursorRects(for: self)

        if wasDragging {
            onDragEnded?()
        } else {
            onClick?(pt, event.modifierFlags)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(convert(event.locationInWindow, from: nil), self)
    }

    override func scrollWheel(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        onScrollWheel?(event.scrollingDeltaY, event.hasPreciseScrollingDeltas, pt)
    }

    override func magnify(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if event.phase == .began {
            onMagnifyStart?(pt)
        }
        if event.phase == .ended || event.phase == .cancelled {
            onMagnifyEnded?()
        } else {
            let factor = max(0.5, min(2.0, 1.0 + event.magnification))
            onMagnifyChanged?(factor, pt)
        }
    }
}
