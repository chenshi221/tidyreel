import CoreGraphics
import Foundation

public struct OrganicMapItem: Equatable, Hashable, Sendable {
    public var id: String
    public var value: Double

    public init(_ id: String, _ value: Double) {
        self.id = id
        self.value = value
    }
}

public struct OrganicMapCell: Equatable, Sendable, Identifiable {
    public var id: String
    public var value: Double
    /// Raw convex Voronoi polygon (un-inset canvas coordinates).
    public var polygon: [CGPoint]
    public var centroid: CGPoint
    public var bounds: CGRect
    public var area: Double
    public var inset: Double
    public var radialCount: Int

    private var effectivePolygon: [CGPoint] {
        guard inset > 0 else { return polygon }
        let insetPoly = OrganicGeometry.insetConvex(polygon, by: inset)
        return insetPoly.count >= 3 ? insetPoly : polygon
    }

    /// Lazily smoothed pebble vertices (inset when `inset > 0`).
    public var smoothed: [CGPoint] {
        OrganicGeometry.smoothPolygon(effectivePolygon)
    }

    /// Lazily resampled radial vertices.
    public var radial: [CGPoint] {
        OrganicGeometry.resampleRadial(effectivePolygon, count: radialCount)
    }

    public init(id: String, value: Double, polygon: [CGPoint], inset: Double = 0, radialCount: Int = 64) {
        self.id = id
        self.value = value
        self.polygon = polygon
        self.area = OrganicGeometry.polygonArea(polygon)
        self.centroid = OrganicGeometry.polygonCentroid(polygon)
        self.bounds = OrganicGeometry.polygonBounds(polygon)
        self.inset = inset
        self.radialCount = radialCount
    }
}

public enum OrganicGeometry {
    private static let trailingBracketsRegex = try! NSRegularExpression(pattern: #"\s*[\[{][^\]}]*[\]}]\s*$"#)
    private static let trailingYearRegex = try! NSRegularExpression(pattern: #"[\s.]*[(（]?(?:19|20)\d{2}[)）]?\s*$"#)

    /// Strips trailing `{tmdb-...}` / `[...]` tags and `(2024)` year so pebble labels stay clean:
    /// 「死神 (2004) {tmdb-30984}」 → 「死神」.
    public static func shortMapLabel(_ name: String) -> String {
        var s = name
        let r1 = NSRange(s.startIndex..<s.endIndex, in: s)
        s = trailingBracketsRegex.stringByReplacingMatches(in: s, range: r1, withTemplate: "")
        let r2 = NSRange(s.startIndex..<s.endIndex, in: s)
        s = trailingYearRegex.stringByReplacingMatches(in: s, range: r2, withTemplate: "")
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? name : trimmed
    }

    /// Each pebble's screen-space share of `gap`, so gaps vary organically like hand-laid river stones
    /// AND stay constant in screen pixels at every zoom level!
    public static func pebbleInset(for id: String, gap: Double = 12.0) -> Double {
        gap * 0.5 * (0.8 + 0.4 * hashUnit(id))
    }

    /// Nocaj & Brandes weighted Voronoi power diagram treemap.
    public static func layoutOrganic(
        items: [OrganicMapItem],
        bounds: CGRect,
        iterations: Int = 120,
        seeds: [String: CGPoint]? = nil,
        inset: Double = 0
    ) -> [OrganicMapCell] {
        let live = items.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        guard !live.isEmpty, !bounds.isEmpty, min(bounds.width, bounds.height) >= 2 else {
            return []
        }
        let frame: [CGPoint] = [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.maxY),
            CGPoint(x: bounds.minX, y: bounds.maxY),
        ]
        if live.count == 1 {
            return [OrganicMapCell(id: live[0].id, value: live[0].value, polygon: frame, inset: inset)]
        }

        let n = live.count
        let total = live.reduce(0.0) { $0 + $1.value }
        let totalArea = Double(bounds.width * bounds.height)
        let target = live.map { totalArea * $0.value / total }

        var sites: [CGPoint] = live.map { item in
            if let s = seeds?[item.id] {
                let cx = min(max(Double(s.x), Double(bounds.minX) + 1), Double(bounds.maxX) - 1) + hashUnit("x\(item.id)")
                let cy = min(max(Double(s.y), Double(bounds.minY) + 1), Double(bounds.maxY) - 1) + hashUnit("y\(item.id)")
                return CGPoint(x: cx, y: cy)
            }
            return CGPoint(
                x: Double(bounds.minX) + Double(bounds.width) * (0.08 + 0.84 * hashUnit("x\(item.id)")),
                y: Double(bounds.minY) + Double(bounds.height) * (0.08 + 0.84 * hashUnit("y\(item.id)"))
            )
        }

        let w0 = totalArea / Double(n) * 0.1
        var weights = [Double](repeating: w0, count: n)
        var cells = [[CGPoint]](repeating: [], count: n)
        var areas = [Double](repeating: 0, count: n)
        var converged = false

        for round in 0..<iterations {
            if Task.isCancelled { return [] }
            cells = powerCells(frame: frame, sites: sites, weights: weights)
            var maxRelErr = 0.0
            for i in 0..<n {
                let a = polygonArea(cells[i])
                areas[i] = a
                let err = abs(a - target[i]) / max(target[i], 1.0)
                if err > maxRelErr { maxRelErr = err }
            }
            if round >= 25 && maxRelErr < 0.015 {
                converged = true
                break
            }
            for i in 0..<n {
                let a = areas[i]
                if a > 1e-6 {
                    sites[i] = polygonCentroid(cells[i])
                }
                weights[i] += (target[i] - a) / .pi * 0.7
            }
            for j in 0..<n {
                for i in 0..<n where i != j {
                    let dx = Double(sites[i].x - sites[j].x)
                    let dy = Double(sites[i].y - sites[j].y)
                    let limit = weights[i] + (dx * dx + dy * dy)
                    if weights[j] > limit {
                        weights[j] = limit * 0.999
                    }
                }
            }
        }
        if Task.isCancelled { return [] }
        if !converged {
            cells = powerCells(frame: frame, sites: sites, weights: weights)
        }
        var out: [OrganicMapCell] = []
        out.reserveCapacity(n)
        for i in 0..<n where cells[i].count >= 3 {
            out.append(OrganicMapCell(id: live[i].id, value: live[i].value, polygon: cells[i], inset: inset))
        }
        return out
    }

    /// Computes Voronoi power cells off `@MainActor` (zero main-thread blocking).
    public static func layoutAsync(
        items: [OrganicMapItem],
        bounds: CGRect,
        iterations: Int = 120,
        seeds: [String: CGPoint]? = nil,
        inset: Double = 0
    ) async -> [OrganicMapCell] {
        if Task.isCancelled { return [] }
        let worker = Task.detached(priority: .userInitiated) {
            layoutOrganic(items: items, bounds: bounds, iterations: iterations, seeds: seeds, inset: inset)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func powerCells(
        frame: [CGPoint],
        sites: [CGPoint],
        weights: [Double]
    ) -> [[CGPoint]] {
        let n = sites.count
        var result: [[CGPoint]] = []
        result.reserveCapacity(n)
        for i in 0..<n {
            var cell = frame
            let pi = sites[i]
            let piLenSq = Double(pi.x * pi.x + pi.y * pi.y)
            for j in 0..<n where i != j && cell.count >= 3 {
                let pj = sites[j]
                let nx = Double(pj.x - pi.x)
                let ny = Double(pj.y - pi.y)
                if nx * nx + ny * ny < 1e-12 { continue }
                let pjLenSq = Double(pj.x * pj.x + pj.y * pj.y)
                let c = (pjLenSq - piLenSq - weights[j] + weights[i]) * 0.5
                cell = cutBelow(cell, nx: nx, ny: ny, t: c)
            }
            result.append(cell)
        }
        return result
    }

    private static func cutBelow(_ poly: [CGPoint], nx: Double, ny: Double, t: Double) -> [CGPoint] {
        var below: [CGPoint] = []
        below.reserveCapacity(poly.count + 2)
        let count = poly.count
        for i in 0..<count {
            let p = poly[i]
            let q = poly[(i + 1) % count]
            let dp = Double(p.x) * nx + Double(p.y) * ny - t
            let dq = Double(q.x) * nx + Double(q.y) * ny - t
            if dp < 0 { below.append(p) }
            if (dp < 0) != (dq < 0) {
                let frac = dp / (dp - dq)
                below.append(CGPoint(
                    x: Double(p.x) + Double(q.x - p.x) * frac,
                    y: Double(p.y) + Double(q.y - p.y) * frac
                ))
            }
        }
        return below
    }

    private static func cutAbove(_ poly: [CGPoint], nx: Double, ny: Double, t: Double) -> [CGPoint] {
        var above: [CGPoint] = []
        above.reserveCapacity(poly.count + 2)
        let count = poly.count
        for i in 0..<count {
            let p = poly[i]
            let q = poly[(i + 1) % count]
            let dp = Double(p.x) * nx + Double(p.y) * ny - t
            let dq = Double(q.x) * nx + Double(q.y) * ny - t
            if dp >= 0 { above.append(p) }
            if (dp < 0) != (dq < 0) {
                let frac = dp / (dp - dq)
                above.append(CGPoint(
                    x: Double(p.x) + Double(q.x - p.x) * frac,
                    y: Double(p.y) + Double(q.y - p.y) * frac
                ))
            }
        }
        return above
    }

    /// Clips convex `poly` to `rect` using Sutherland–Hodgman half-plane clipping.
    /// Combined with screen-space `insetConvex` + `smoothPolygon`, pebbles crossing the viewport
    /// border are smoothly re-rounded along the frame instead of being hard-clipped!
    public static func clipToRect(_ poly: [CGPoint], rect: CGRect) -> [CGPoint] {
        var cur = poly
        let planes: [(nx: Double, ny: Double, t: Double)] = [
            (1, 0, Double(rect.minX)),
            (-1, 0, -Double(rect.maxX)),
            (0, 1, Double(rect.minY)),
            (0, -1, -Double(rect.maxY)),
        ]
        for plane in planes {
            if cur.count < 3 { return [] }
            cur = cutAbove(cur, nx: plane.nx, ny: plane.ny, t: plane.t)
        }
        return cur.count >= 3 ? cur : []
    }

    public static func insetConvex(_ poly: [CGPoint], by d: Double) -> [CGPoint] {
        guard poly.count >= 3 else { return [] }
        let c = polygonCentroid(poly)
        var cur = poly
        let count = poly.count
        for i in 0..<count where cur.count >= 3 {
            let p = poly[i]
            let q = poly[(i + 1) % count]
            let ex = Double(q.x - p.x)
            let ey = Double(q.y - p.y)
            let len = hypot(ex, ey)
            if len < 1e-9 { continue }
            var nx = -ey / len
            var ny = ex / len
            if (Double(c.x - p.x) * nx + Double(c.y - p.y) * ny) < 0 {
                nx = -nx
                ny = -ny
            }
            let t = Double(p.x) * nx + Double(p.y) * ny + d
            cur = cutAbove(cur, nx: nx, ny: ny, t: t)
        }
        return cur.count >= 3 && polygonArea(cur) > 1e-6 ? cur : []
    }

    public static func smoothPolygon(
        _ poly: [CGPoint],
        rounds: Int = 4,
        ratio: Double = 0.2,
        maxCut: Double = 60,
        minEdge: Double = 10
    ) -> [CGPoint] {
        var cur: [CGPoint] = []
        for p in poly {
            if let last = cur.last {
                if hypot(Double(p.x - last.x), Double(p.y - last.y)) >= minEdge {
                    cur.append(p)
                }
            } else {
                cur.append(p)
            }
        }
        if cur.count > 3, let first = cur.first, let last = cur.last,
           hypot(Double(first.x - last.x), Double(first.y - last.y)) < minEdge {
            cur.removeLast()
        }
        if cur.count < 3 { cur = poly }
        var cap = maxCut
        for _ in 0..<rounds where cur.count >= 3 {
            var next: [CGPoint] = []
            next.reserveCapacity(cur.count * 2)
            let count = cur.count
            for i in 0..<count {
                let a = cur[i]
                let b = cur[(i + 1) % count]
                let len = hypot(Double(b.x - a.x), Double(b.y - a.y))
                if len < 1e-9 { continue }
                let t = min(ratio, cap / len)
                next.append(CGPoint(
                    x: Double(a.x) + Double(b.x - a.x) * t,
                    y: Double(a.y) + Double(b.y - a.y) * t
                ))
                next.append(CGPoint(
                    x: Double(a.x) + Double(b.x - a.x) * (1.0 - t),
                    y: Double(a.y) + Double(b.y - a.y) * (1.0 - t)
                ))
            }
            cur = next
            cap *= 0.5
        }
        return cur
    }

    public static func resampleRadial(_ poly: [CGPoint], count n: Int = 96) -> [CGPoint] {
        guard poly.count >= 3, n >= 3 else { return poly }
        let c = polygonCentroid(poly)
        return (0..<n).map { k in
            let angle = 2.0 * .pi * Double(k) / Double(n)
            let dx = cos(angle)
            let dy = sin(angle)
            var best = 0.0
            let cnt = poly.count
            for i in 0..<cnt {
                let px = Double(poly[i].x - c.x)
                let py = Double(poly[i].y - c.y)
                let qx = Double(poly[(i + 1) % cnt].x - c.x)
                let qy = Double(poly[(i + 1) % cnt].y - c.y)
                let ex = qx - px
                let ey = qy - py
                let den = dx * ey - dy * ex
                if abs(den) < 1e-12 { continue }
                let t = (px * ey - py * ex) / den
                let s = (px * dy - py * dx) / den
                if t > best && s >= -1e-9 && s <= 1.0 + 1e-9 {
                    best = t
                }
            }
            return CGPoint(x: Double(c.x) + dx * best, y: Double(c.y) + dy * best)
        }
    }

    public static func lerpPolygon(_ a: [CGPoint], _ b: [CGPoint], t: Double) -> [CGPoint] {
        let count = min(a.count, b.count)
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            CGPoint(
                x: Double(a[i].x) + Double(b[i].x - a[i].x) * t,
                y: Double(a[i].y) + Double(b[i].y - a[i].y) * t
            )
        }
    }

    public static func contourRings(_ poly: [CGPoint], step: Double, keep: CGRect? = nil) -> [[CGPoint]] {
        var rings: [[CGPoint]] = []
        var d = step
        while rings.count < 80 {
            let r = insetConvex(poly, by: d)
            if r.isEmpty || polygonArea(r) < step * step * 2 { break }
            if let keep {
                let corners = [
                    CGPoint(x: keep.minX, y: keep.minY),
                    CGPoint(x: keep.maxX, y: keep.minY),
                    CGPoint(x: keep.minX, y: keep.maxY),
                    CGPoint(x: keep.maxX, y: keep.maxY),
                ]
                if !corners.allSatisfy({ polygonContains(r, point: $0) }) { break }
            }
            rings.append(r)
            d += step
        }
        return rings
    }

    public static func polygonContains(_ poly: [CGPoint], point pt: CGPoint) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if ((a.y > pt.y) != (b.y > pt.y)) &&
                (pt.x < (b.x - a.x) * (pt.y - a.y) / (b.y - a.y) + a.x) {
                inside = !inside
            }
            j = i
        }
        return inside
    }

    public static func polygonArea(_ poly: [CGPoint]) -> Double {
        guard poly.count >= 3 else { return 0 }
        var s = 0.0
        let count = poly.count
        for i in 0..<count {
            let p = poly[i]
            let q = poly[(i + 1) % count]
            s += Double(p.x * q.y - q.x * p.y)
        }
        return abs(s) * 0.5
    }

    public static func polygonCentroid(_ poly: [CGPoint]) -> CGPoint {
        guard !poly.isEmpty else { return .zero }
        var a = 0.0, cx = 0.0, cy = 0.0
        let count = poly.count
        for i in 0..<count {
            let p = poly[i]
            let q = poly[(i + 1) % count]
            let cross = Double(p.x * q.y - q.x * p.y)
            a += cross
            cx += Double(p.x + q.x) * cross
            cy += Double(p.y + q.y) * cross
        }
        if abs(a) < 1e-9 {
            let sx = poly.reduce(0.0) { $0 + Double($1.x) }
            let sy = poly.reduce(0.0) { $0 + Double($1.y) }
            return CGPoint(x: sx / Double(count), y: sy / Double(count))
        }
        return CGPoint(x: cx / (3.0 * a), y: cy / (3.0 * a))
    }

    public static func polygonBounds(_ poly: [CGPoint]) -> CGRect {
        guard let first = poly.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in poly.dropFirst() {
            if p.x < minX { minX = p.x }
            if p.y < minY { minY = p.y }
            if p.x > maxX { maxX = p.x }
            if p.y > maxY { maxY = p.y }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public static func chordWidth(_ poly: [CGPoint], y: CGFloat) -> CGFloat {
        var xs: [CGFloat] = []
        let count = poly.count
        for i in 0..<count {
            let p = poly[i], q = poly[(i + 1) % count]
            if (p.y <= y) != (q.y <= y) {
                xs.append(p.x + (q.x - p.x) * (y - p.y) / (q.y - p.y))
            }
        }
        guard let minVal = xs.min(), let maxVal = xs.max(), xs.count >= 2 else { return 0 }
        return maxVal - minVal
    }

    public static func chordHeight(_ poly: [CGPoint], x: CGFloat) -> CGFloat {
        var ys: [CGFloat] = []
        let count = poly.count
        for i in 0..<count {
            let p = poly[i], q = poly[(i + 1) % count]
            if (p.x <= x) != (q.x <= x) {
                ys.append(p.y + (q.y - p.y) * (x - p.x) / (q.x - p.x))
            }
        }
        guard let minVal = ys.min(), let maxVal = ys.max(), ys.count >= 2 else { return 0 }
        return maxVal - minVal
    }

    public static func hashUnit(_ s: String) -> Double {
        var h: UInt32 = 0x811c9dc5
        for c in s.utf16 {
            h = (h ^ UInt32(c)) &* 0x01000193
        }
        return Double(h) / Double(UInt32.max)
    }
}
