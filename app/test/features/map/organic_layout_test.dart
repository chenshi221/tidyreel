import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/features/map/organic_layout.dart';

bool _convex(List<Offset> poly) {
  var sign = 0;
  for (var i = 0; i < poly.length; i++) {
    final a = poly[i];
    final b = poly[(i + 1) % poly.length];
    final c = poly[(i + 2) % poly.length];
    final cross = (b.dx - a.dx) * (c.dy - b.dy) - (b.dy - a.dy) * (c.dx - b.dx);
    if (cross.abs() < 1e-6) continue;
    final s = cross.sign.toInt();
    if (sign == 0) sign = s;
    if (s != sign) return false;
  }
  return true;
}

void main() {
  const bounds = Rect.fromLTWH(0, 0, 800, 500);
  final items = [
    for (final (i, v) in [400, 220, 130, 90, 60, 40, 25, 12].indexed)
      MapItem('item$i', v.toDouble()),
  ];

  test('areas are proportional to values', () {
    final cells = layoutOrganic(items, bounds);
    expect(cells, hasLength(items.length));
    final total = items.fold(0.0, (s, i) => s + i.value);
    for (final c in cells) {
      final want = bounds.width * bounds.height * c.value / total;
      expect((c.area - want).abs() / want, lessThan(0.01), reason: c.id);
    }
  });

  test('cells are convex, inside the bounds and tile it', () {
    final cells = layoutOrganic(items, bounds);
    var sum = 0.0;
    for (final c in cells) {
      expect(_convex(c.polygon), isTrue, reason: c.id);
      for (final p in c.polygon) {
        expect(bounds.inflate(1e-6).contains(p), isTrue);
      }
      sum += c.area;
    }
    expect(sum, closeTo(bounds.width * bounds.height, 1));
  });

  test('same input gives the same shapes', () {
    final a = layoutOrganic(items, bounds);
    final b = layoutOrganic(items.reversed.toList(), bounds);
    for (var i = 0; i < a.length; i++) {
      expect(a[i].id, b[i].id);
      expect(a[i].polygon, b[i].polygon);
    }
  });

  test('cuts are tilted, not axis-aligned', () {
    final cells = layoutOrganic(items, bounds);
    final slanted = cells.any(
      (c) => c.polygon.indexed.any((e) {
        final q = c.polygon[(e.$1 + 1) % c.polygon.length];
        final d = q - e.$2;
        return d.dx.abs() > 1 && d.dy.abs() > 1;
      }),
    );
    expect(slanted, isTrue);
  });

  test('drops non-positive values; empty input gives nothing', () {
    expect(layoutOrganic([const MapItem('z', 0)], bounds), isEmpty);
    final one = layoutOrganic([const MapItem('a', 5)], bounds);
    expect(one.single.area, closeTo(400000, 1e-6));
  });

  test('insetConvex shrinks every edge by d and stays convex', () {
    const square = [
      Offset(0, 0),
      Offset(100, 0),
      Offset(100, 100),
      Offset(0, 100),
    ];
    final inner = insetConvex(square, 10);
    expect(polygonArea(inner), closeTo(80 * 80, 1e-6));
    expect(_convex(inner), isTrue);
    expect(insetConvex(square, 60), isEmpty);
  });

  test('contour rings nest and stop before vanishing', () {
    final cells = layoutOrganic(items, bounds);
    final rings = contourRings(cells.first.polygon, 10);
    expect(rings, isNotEmpty);
    for (var i = 1; i < rings.length; i++) {
      expect(polygonArea(rings[i]), lessThan(polygonArea(rings[i - 1])));
      expect(polygonContains(rings[i - 1], polygonCentroid(rings[i])), isTrue);
    }
  });

  test('hit testing and chord width', () {
    const tri = [Offset(0, 0), Offset(100, 0), Offset(0, 100)];
    expect(polygonContains(tri, const Offset(10, 10)), isTrue);
    expect(polygonContains(tri, const Offset(90, 90)), isFalse);
    expect(chordWidth(tri, 50), closeTo(50, 1e-9));
  });

  test('rounded path stays within the polygon bounds', () {
    final cells = layoutOrganic(items, bounds);
    for (final c in cells) {
      final path = roundedPolygon(c.polygon, 22);
      final box = path.getBounds();
      final xs = c.polygon.map((p) => p.dx);
      final ys = c.polygon.map((p) => p.dy);
      expect(box.left, greaterThanOrEqualTo(xs.reduce(math.min) - 1e-3));
      expect(box.bottom, lessThanOrEqualTo(ys.reduce(math.max) + 1e-3));
    }
  });
}
