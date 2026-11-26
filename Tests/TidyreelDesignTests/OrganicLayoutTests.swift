import CoreGraphics
import Foundation
import Testing
@testable import TidyreelDesign

@Suite("OrganicLayout Tests")
struct OrganicLayoutTests {
    @Test("OrganicGeometry.layoutAsync computes valid non-empty smoothed & radial cells off MainActor")
    func backgroundOrganicVoronoiLayout() async {
        let items = (1...60).map { OrganicMapItem("dir-\($0)", Double($0 * 100)) }
        let cells = await OrganicGeometry.layoutAsync(
            items: items,
            bounds: CGRect(x: 0, y: 0, width: 960, height: 640)
        )
        #expect(cells.count == 60)
        let totalArea = cells.reduce(0.0) { $0 + OrganicGeometry.polygonArea($1.polygon) }
        #expect(abs(totalArea - 960.0 * 640.0) < 5000.0)
        #expect(cells.allSatisfy { $0.smoothed.count >= 3 && $0.radial.count == 64 })
    }
}
