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

/// Lays [items] out in [bounds] as convex "pebbles".
///
/// Balanced binary partition: items (largest first) are split into two
/// groups of near-equal total, and the current polygon is cut by a slightly
/// tilted line placed so each side's area matches its group's share; of the
/// two cut directions, the one giving squarer halves wins. Tilts come from the items' ids, so the same folder
/// always gets the same shapes. Items with a non-positive value are dropped.
List<MapCell> layoutOrganic(
  List<MapItem> items,
  Rect bounds, {
  double maxTilt = 0.15,
}) {
  final live = items.where((i) => i.value > 0).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  if (live.isEmpty || bounds.isEmpty) return const [];
  final out = <MapCell>[];
  _split(
    live,
    [bounds.topLeft, bounds.topRight, bounds.bottomRight, bounds.bottomLeft],
    maxTilt,
    out,
  );
  return out;
}

void _split(
  List<MapItem> items,
  List<Offset> poly,
  double maxTilt,
  List<MapCell> out,
) {
  if (items.length == 1) {
    out.add(MapCell(items.single.id, items.single.value, poly));
    return;
  }
  // Greedy balance: walk largest-first, give each item to the lighter side.
  final a = <MapItem>[], b = <MapItem>[];
  var sa = 0.0, sb = 0.0;
  for (final i in items) {
    if (sa <= sb) {
      a.add(i);
      sa += i.value;
    } else {
      b.add(i);
      sb += i.value;
    }
  }
  final fraction = sa / (sa + sb);

  final tilt = (_unit(items.first.id + items.last.id) * 2 - 1) * maxTilt;
  // Try both directions; keep the one whose halves are closest to square.
  (List<Offset>, List<Offset>)? best;
  var bestScore = double.infinity;
  for (final base in [0.0, math.pi / 2]) {
    final parts = _cutAt(poly, base + tilt, fraction);
    final score = math.max(_aspect(parts.$1), _aspect(parts.$2));
    if (score < bestScore) {
      bestScore = score;
      best = parts;
    }
  }
  final (first, second) = best!;
  _split(a, first, maxTilt, out);
  _split(b, second, maxTilt, out);
}

/// Cuts [poly] with a line at [angle] so the first part holds [fraction] of
/// its area (bisection on the line's offset).
(List<Offset>, List<Offset>) _cutAt(
  List<Offset> poly,
  double angle,
  double fraction,
) {
  final normal = Offset(-math.sin(angle), math.cos(angle));
  final projections = [for (final p in poly) _dot(p, normal)];
  var lo = projections.reduce(math.min), hi = projections.reduce(math.max);
  final total = polygonArea(poly);
  var parts = (poly, poly);
  for (var k = 0; k < 40; k++) {
    final t = (lo + hi) / 2;
    parts = _cut(poly, normal, t);
    if (polygonArea(parts.$1) / total < fraction) {
      lo = t;
    } else {
      hi = t;
    }
  }
  return parts;
}

/// Long side over short side of the bounding box (1 = square).
double _aspect(List<Offset> poly) {
  if (poly.length < 3) return double.infinity;
  final b = _bbox(poly);
  final s = math.min(b.width, b.height);
  return s <= 0 ? double.infinity : math.max(b.width, b.height) / s;
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

/// A closed path through [poly] with each corner rounded by up to [radius]
/// (less where the adjacent edges are short).
Path roundedPolygon(List<Offset> poly, double radius) {
  final path = Path();
  final n = poly.length;
  if (n < 3) return path;
  for (var i = 0; i < n; i++) {
    final prev = poly[(i - 1 + n) % n], v = poly[i], next = poly[(i + 1) % n];
    final inLen = (v - prev).distance, outLen = (next - v).distance;
    final r = math.min(radius, 0.5 * math.min(inLen, outLen));
    final a = inLen == 0 ? v : v + (prev - v) * (r / inLen);
    final b = outLen == 0 ? v : v + (next - v) * (r / outLen);
    if (i == 0) {
      path.moveTo(a.dx, a.dy);
    } else {
      path.lineTo(a.dx, a.dy);
    }
    // A conic with weight < 1 bulges less than a circle arc: soft, pebble-like.
    path.conicTo(v.dx, v.dy, b.dx, b.dy, 0.75);
  }
  path.close();
  return path;
}

/// Ever smaller insets of [poly], [step] apart, for the contour fill.
List<List<Offset>> contourRings(List<Offset> poly, double step) {
  final rings = <List<Offset>>[];
  var d = step;
  while (rings.length < 60) {
    final r = insetConvex(poly, d);
    if (r.isEmpty || polygonArea(r) < step * step * 2) break;
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

Rect _bbox(List<Offset> poly) {
  var l = double.infinity, t = double.infinity;
  var r = -double.infinity, b = -double.infinity;
  for (final p in poly) {
    l = math.min(l, p.dx);
    t = math.min(t, p.dy);
    r = math.max(r, p.dx);
    b = math.max(b, p.dy);
  }
  return Rect.fromLTRB(l, t, r, b);
}

double _dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;

/// Stable 0..1 from a string (FNV-1a), independent of Dart's hashCode.
double _unit(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h / 0xffffffff;
}
