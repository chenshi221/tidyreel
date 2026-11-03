import 'dart:math' as math;
import 'dart:ui';

/// One thing to place on the map. [value] decides its area.
class MapItem {
  final String id;
  final double value;

  const MapItem(this.id, this.value);
}

/// A placed item: a convex polygon whose area is proportional to its value.
class MapCell {
  final String id;
  final double value;

  /// Convex, counter-clockwise in screen space is not guaranteed; callers
  /// shouldn't depend on winding.
  final List<Offset> polygon;

  const MapCell(this.id, this.value, this.polygon);

  double get area => polygonArea(polygon);
  Offset get centroid => polygonCentroid(polygon);
}

/// Lays [items] out in [bounds] as convex "pebbles" whose areas follow the
/// items' values: a Voronoi treemap (weighted power diagram, Nocaj & Brandes).
///
/// Sites start at positions hashed from the ids, so a folder always gets the
/// same picture. Each round computes every power cell by half-plane clipping,
/// moves each site to its cell's centroid (rounder, evenly spread cells) and
/// scales its weight by target/actual area. Cells come out with 3–7 sides at
/// varied angles: the hand-cut look, not a grid. Non-positive values drop out.
List<MapCell> layoutOrganic(
  List<MapItem> items,
  Rect bounds, {
  int iterations = 120,
}) {
  final live = items.where((i) => i.value > 0).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  if (live.isEmpty || bounds.isEmpty) return const [];
  final frame = [
    bounds.topLeft,
    bounds.topRight,
    bounds.bottomRight,
    bounds.bottomLeft,
  ];
  if (live.length == 1) {
    return [MapCell(live.single.id, live.single.value, frame)];
  }

  final n = live.length;
  final total = live.fold(0.0, (s, i) => s + i.value);
  final area = bounds.width * bounds.height;
  final target = [for (final i in live) area * i.value / total];
  final sites = [
    for (final i in live)
      Offset(
        bounds.left + bounds.width * (0.08 + 0.84 * _unit('x${i.id}')),
        bounds.top + bounds.height * (0.08 + 0.84 * _unit('y${i.id}')),
      ),
  ];
  // Start from equal weights: a plain Voronoi diagram.
  final w0 = area / n * 0.1;
  final weights = List.filled(n, w0);
  var cells = List<List<Offset>>.filled(n, const []);

  for (var round = 0; round < iterations; round++) {
    cells = _powerCells(frame, sites, weights);
    for (var i = 0; i < n; i++) {
      final a = polygonArea(cells[i]);
      if (a > 1e-6) sites[i] = polygonCentroid(cells[i]);
      final ratio = a <= 1e-6 ? 1.5 : target[i] / a;
      weights[i] = math.max(weights[i] * ratio, 1e-6);
    }
    // Site j stays inside its own cell iff w_j - w_i <= |p_i - p_j|² for
    // every i; trim weights that break it (the overgrown neighbour gives
    // way, so no cell vanishes and the big ones still reach their size).
    for (var j = 0; j < n; j++) {
      for (var i = 0; i < n; i++) {
        if (i == j) continue;
        final limit = weights[i] + (sites[i] - sites[j]).distanceSquared;
        if (weights[j] > limit) weights[j] = limit * 0.999;
      }
    }
  }
  cells = _powerCells(frame, sites, weights);
  return [
    for (var i = 0; i < n; i++)
      if (cells[i].length >= 3) MapCell(live[i].id, live[i].value, cells[i]),
  ];
}

/// The power-diagram cell of every site, clipped to [frame].
List<List<Offset>> _powerCells(
  List<Offset> frame,
  List<Offset> sites,
  List<double> weights,
) {
  final n = sites.length;
  return [
    for (var i = 0; i < n; i++)
      () {
        var cell = frame;
        final pi = sites[i];
        for (var j = 0; j < n && cell.length >= 3; j++) {
          if (i == j) continue;
          final pj = sites[j];
          // |x-pi|² - wi <= |x-pj|² - wj  <=>  x·(pj-pi) <= c
          final normal = pj - pi;
          if (normal.distanceSquared < 1e-12) continue;
          final c =
              (pj.distanceSquared -
                  pi.distanceSquared -
                  weights[j] +
                  weights[i]) /
              2;
          cell = _cut(cell, normal, c).$1;
        }
        return cell;
      }(),
  ];
}

/// Splits a convex polygon by the line `dot(p, n) == t` into the part with
/// `dot < t` and the part with `dot >= t`.
(List<Offset>, List<Offset>) _cut(List<Offset> poly, Offset n, double t) {
  final below = <Offset>[], above = <Offset>[];
  for (var i = 0; i < poly.length; i++) {
    final p = poly[i], q = poly[(i + 1) % poly.length];
    final dp = _dot(p, n) - t, dq = _dot(q, n) - t;
    (dp < 0 ? below : above).add(p);
    if ((dp < 0) != (dq < 0)) {
      final x = p + (q - p) * (dp / (dp - dq));
      below.add(x);
      above.add(x);
    }
  }
  return (below, above);
}

/// Moves every edge of a convex polygon inward by [d] (Sutherland–Hodgman
/// against each offset edge). Returns an empty list when nothing is left.
List<Offset> insetConvex(List<Offset> poly, double d) {
  if (poly.length < 3) return const [];
  final c = polygonCentroid(poly);
  var cur = poly;
  for (var i = 0; i < poly.length && cur.length >= 3; i++) {
    final p = poly[i], q = poly[(i + 1) % poly.length];
    final e = q - p;
    if (e.distance < 1e-9) continue;
    var n = Offset(-e.dy, e.dx) / e.distance;
    // Point n toward the inside.
    if (_dot(c - p, n) < 0) n = -n;
    final t = _dot(p, n) + d;
    cur = _cut(cur, n, t).$2;
  }
  return cur.length >= 3 && polygonArea(cur) > 1e-6 ? cur : const [];
}

/// Chaikin corner cutting: each round replaces every corner by two points
/// [ratio] of the way along its edges (at most [maxCut] px), converging on a
/// curve with continuous curvature. Large cells keep long straight runs with
/// big soft corners; small ones become nearly round, like river stones.
List<Offset> smoothPolygon(
  List<Offset> poly, {
  int rounds = 4,
  double ratio = 0.2,
  double maxCut = 60,
  double minEdge = 10,
}) {
  // Very short edges would leave a sharp tip after smoothing: merge them.
  var cur = <Offset>[];
  for (final p in poly) {
    if (cur.isEmpty || (p - cur.last).distance >= minEdge) cur.add(p);
  }
  if (cur.length > 3 && (cur.first - cur.last).distance < minEdge) {
    cur.removeLast();
  }
  if (cur.length < 3) cur = poly;
  var cap = maxCut;
  for (var r = 0; r < rounds && cur.length >= 3; r++) {
    final next = <Offset>[];
    for (var i = 0; i < cur.length; i++) {
      final a = cur[i], b = cur[(i + 1) % cur.length];
      final len = (b - a).distance;
      if (len < 1e-9) continue;
      final t = math.min(ratio, cap / len);
      next
        ..add(Offset.lerp(a, b, t)!)
        ..add(Offset.lerp(a, b, 1 - t)!);
    }
    cur = next;
    cap /= 2;
  }
  return cur;
}

/// Closed path through [poly] after [smoothPolygon].
Path pebblePath(List<Offset> poly) {
  final pts = smoothPolygon(poly);
  final path = Path();
  if (pts.length < 3) return path;
  path.addPolygon(pts, true);
  return path;
}

/// Ever smaller insets of [poly], [step] apart, for the contour fill. With
/// [keep] the rings stop before they would cut into that rect (the label).
List<List<Offset>> contourRings(List<Offset> poly, double step, {Rect? keep}) {
  final rings = <List<Offset>>[];
  var d = step;
  while (rings.length < 80) {
    final r = insetConvex(poly, d);
    if (r.isEmpty || polygonArea(r) < step * step * 2) break;
    if (keep != null &&
        !(polygonContains(r, keep.topLeft) &&
            polygonContains(r, keep.topRight) &&
            polygonContains(r, keep.bottomLeft) &&
            polygonContains(r, keep.bottomRight))) {
      break;
    }
    rings.add(r);
    d += step;
  }
  return rings;
}

bool polygonContains(List<Offset> poly, Offset pt) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.dy > pt.dy) != (b.dy > pt.dy) &&
        pt.dx < (b.dx - a.dx) * (pt.dy - a.dy) / (b.dy - a.dy) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
}

double polygonArea(List<Offset> poly) {
  var s = 0.0;
  for (var i = 0; i < poly.length; i++) {
    final p = poly[i], q = poly[(i + 1) % poly.length];
    s += p.dx * q.dy - q.dx * p.dy;
  }
  return s.abs() / 2;
}

Offset polygonCentroid(List<Offset> poly) {
  var a = 0.0, cx = 0.0, cy = 0.0;
  for (var i = 0; i < poly.length; i++) {
    final p = poly[i], q = poly[(i + 1) % poly.length];
    final cross = p.dx * q.dy - q.dx * p.dy;
    a += cross;
    cx += (p.dx + q.dx) * cross;
    cy += (p.dy + q.dy) * cross;
  }
  if (a.abs() < 1e-9) {
    final sx = poly.fold(0.0, (s, p) => s + p.dx);
    final sy = poly.fold(0.0, (s, p) => s + p.dy);
    return Offset(sx / poly.length, sy / poly.length);
  }
  return Offset(cx / (3 * a), cy / (3 * a));
}

/// Width of [poly] along the horizontal line through [y].
double chordWidth(List<Offset> poly, double y) {
  final xs = <double>[];
  for (var i = 0; i < poly.length; i++) {
    final p = poly[i], q = poly[(i + 1) % poly.length];
    if ((p.dy <= y) != (q.dy <= y)) {
      xs.add(p.dx + (q.dx - p.dx) * (y - p.dy) / (q.dy - p.dy));
    }
  }
  if (xs.length < 2) return 0;
  return xs.reduce(math.max) - xs.reduce(math.min);
}

/// Height of [poly] along the vertical line through [x].
double chordHeight(List<Offset> poly, double x) =>
    chordWidth([for (final p in poly) Offset(p.dy, p.dx)], x);

double _dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;

/// Stable 0..1 from a string (FNV-1a), independent of Dart's hashCode.
double hashUnit(String s) => _unit(s);

double _unit(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h / 0xffffffff;
}
