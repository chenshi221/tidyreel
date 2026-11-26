import SwiftUI
import TidyreelDesign
import TidyreelModels

// MARK: - Vertically Centered Wrapping Flow Layout (`Wrap(crossAxisAlignment: .center)`)

struct FlowHStack: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 4

    init(horizontalSpacing: CGFloat = 6, verticalSpacing: CGFloat = 4) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        for (index, placement) in result.placements.enumerated() where index < subviews.count {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private struct Arrangement {
        var size: CGSize
        var placements: [CGRect]
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> Arrangement {
        let maxWidth = proposal.width ?? .infinity
        var placements = [CGRect](repeating: .zero, count: subviews.count)

        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var lineStart = 0

        func alignLine(upTo endExclusive: Int) {
            guard endExclusive > lineStart else { return }
            for idx in lineStart..<endExclusive {
                placements[idx].origin.y = cursorY + (lineHeight - placements[idx].height) * 0.5
            }
        }

        for (idx, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth.isFinite ? maxWidth : nil, height: nil))
            if cursorX > 0 && cursorX + size.width > maxWidth {
                alignLine(upTo: idx)
                cursorX = 0
                cursorY += lineHeight + verticalSpacing
                lineHeight = 0
                lineStart = idx
            }
            placements[idx] = CGRect(origin: CGPoint(x: cursorX, y: cursorY), size: size)
            lineHeight = max(lineHeight, size.height)
            usedWidth = max(usedWidth, cursorX + size.width)
            cursorX += size.width + horizontalSpacing
        }
        alignLine(upTo: subviews.count)

        let totalHeight = subviews.isEmpty ? 0 : cursorY + lineHeight
        return Arrangement(size: CGSize(width: usedWidth, height: totalHeight), placements: placements)
    }
}

// MARK: - Shrink-to-Fit Box Capped at `maxWidth` (`BoxConstraints(maxWidth:)` in Flutter)

struct MaxWidthLayout: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        let cappedWidth = min(proposal.width ?? maxWidth, maxWidth)
        return first.sizeThatFits(ProposedViewSize(width: cappedWidth, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        first.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

// MARK: - Animated Wrapper for `DashedSpinner` (`Spinner` in `ui/widgets.dart`)

struct AnimatedDashedSpinner: View {
    @Environment(\.tidyreelReduceMotion) private var reduceMotion
    let size: CGFloat
    var color: Color? = nil

    var body: some View {
        if reduceMotion {
            DashedSpinner(size: size, color: color)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let angle = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.1) / 1.1 * 360.0
                DashedSpinner(size: size, color: color)
                    .rotationEffect(.degrees(angle))
            }
        }
    }
}

// MARK: - Connection Type Icon (`connectionTypeIcon` in `connection_dialog.dart`)

func connectionSymbol(for type: ConnectionType) -> String {
    switch type {
    case .alist: return "server.rack"
    case .webdav: return "globe"
    case .smb: return "externaldrive.connected.to.line.below"
    case .local: return "folder"
    }
}
