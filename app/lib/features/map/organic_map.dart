import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import 'organic_layout.dart';
import 'size_scanner.dart';

/// Smallest area a block is drawn with (logical px²): room for its label.
const minBlockArea = 14000.0;

/// Each block's drawn area on a map shown in [viewport]: its share of the
/// viewport, or [minBlockArea] for the long tail.
List<MapItem> mapItems(List<MapBlock> blocks, Size viewport) {
  final total = blocks.fold(0, (t, b) => t + b.bytes);
  final perByte = total == 0 ? 0.0 : viewport.width * viewport.height / total;
  return [
    for (final b in blocks)
      MapItem(b.id, math.max(b.bytes * perByte, minBlockArea)),
  ];
}

/// The canvas [items] need: the viewport, or as much larger (same shape) as
/// their areas add up to. What doesn't fit is reached by dragging.
Size mapCanvas(List<MapItem> items, Size viewport) {
  final need = items.fold(0.0, (t, i) => t + i.value);
  final have = viewport.width * viewport.height;
  // A little over still fits: not worth making anyone drag.
  return need <= have * 1.25 ? viewport : viewport * math.sqrt(need / have);
}

/// One block on the map.
@immutable
class MapBlock {
  final String id;
  final String label;
  final int bytes;
  final BlockState state;

  /// Second line; defaults to nothing.
  final String? caption;

  const MapBlock({
    required this.id,
    required this.label,
    required this.bytes,
    required this.state,
    this.caption,
  });
}

/// The repository map: blocks as soft convex pebbles, area by size, tone by
/// organize state, the still-to-organize ones drawn as contour lines.
class OrganicMap extends StatefulWidget {
  final List<MapBlock> blocks;
  final void Function(MapBlock)? onTap;
  final void Function(MapBlock, Offset globalPosition)? onSecondaryTap;

  /// Ids drawn as selected.
  final Set<String> selected;

  /// Sizes are still streaming in: lay a crowded map out roughly (each round
  /// costs n² clips on the UI thread), then properly once this turns false.
  final bool counting;

  /// Space between pebbles.
  final double gap;

  const OrganicMap({
    super.key,
    required this.blocks,
    this.onTap,
    this.onSecondaryTap,
    this.selected = const {},
    this.counting = false,
    this.gap = 12,
  });

  @override
  State<OrganicMap> createState() => _OrganicMapState();
}

class _PlacedBlock {
  final MapBlock block;
  final List<Offset> polygon;

  const _PlacedBlock(this.block, this.polygon);
}

class _OrganicMapState extends State<OrganicMap> {
  final _view = TransformationController();
  String? _hover;
  List<_PlacedBlock> _placed = const [];
  Size? _size;
  String? _laidOut;
  var _fitted = false;

  @override
  void dispose() {
    _view.dispose();
    super.dispose();
  }

  /// Relayout only when sizes really change: hover, repaints and rebuilds
  /// with an equal block list reuse the last (costly) Voronoi layout.
  List<_PlacedBlock> _layout(List<MapItem> items, Size size) {
    final rough = widget.counting && items.length > 60;
    final key = [
      rough,
      for (final b in widget.blocks) '${b.id}\u0000${b.bytes}',
    ].join('\u0001');
    if (size == _size && key == _laidOut) {
      // Same shapes; labels/states may still differ.
      final byId = {for (final b in widget.blocks) b.id: b};
      return _placed = [
        for (final x in _placed)
          _PlacedBlock(byId[x.block.id] ?? x.block, x.polygon),
      ];
    }
    _size = size;
    _laidOut = key;
    final byId = {for (final b in widget.blocks) b.id: b};
    final cells = layoutOrganic(
      items,
      Offset.zero & size,
      iterations: rough ? 30 : 120,
    );
    // Each pebble shrinks by its own amount, so the gaps between neighbours
    // vary like stones laid by hand; bigger stones get a little more air.
    final scale = math.sqrt(size.width * size.height);
    return _placed = [
      for (final c in cells)
        if (insetConvex(
              c.polygon,
              widget.gap / 2 * (0.8 + 0.4 * hashUnit(c.id)) +
                  math.sqrt(c.area) / scale * widget.gap * 0.15,
            )
            case final poly when poly.isNotEmpty)
          _PlacedBlock(byId[c.id]!, poly),
    ];
  }

  _PlacedBlock? _hit(Offset local) {
    for (final b in _placed) {
      if (polygonContains(b.polygon, local)) return b;
    }
    return null;
  }

  void _toggleFit(double fit) {
    _fitted = !_fitted;
    _view.value = _fitted
        ? (Matrix4.identity()..scaleByDouble(fit, fit, fit, 1))
        : Matrix4.identity();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, box) {
        final viewport = box.biggest;
        final items = mapItems(widget.blocks, viewport);
        final canvas = mapCanvas(items, viewport);
        final placed = _layout(items, canvas);
        final fit = viewport.width / canvas.width;
        final hovered = placed
            .where((b) => b.block.id == _hover)
            .firstOrNull
            ?.block;
        _MapPainter painter({String? only}) => _MapPainter(
          placed: placed,
          palette: p,
          dark: dark,
          hover: only,
          selected: widget.selected,
          textScaler: MediaQuery.textScalerOf(context),
          baseStyle: DefaultTextStyle.of(context).style,
        );
        return Stack(
          children: [
            InteractiveViewer(
              key: const ValueKey('map-viewer'),
              transformationController: _view,
              constrained: false,
              minScale: fit,
              maxScale: 4,
              child: MouseRegion(
                cursor: _hover == null
                    ? MouseCursor.defer
                    : SystemMouseCursors.click,
                onHover: (e) {
                  final id = _hit(e.localPosition)?.block.id;
                  if (id != _hover) setState(() => _hover = id);
                },
                onExit: (_) => setState(() => _hover = null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) {
                    final b = _hit(d.localPosition);
                    if (b != null) widget.onTap?.call(b.block);
                  },
                  onSecondaryTapUp: (d) {
                    final b = _hit(d.localPosition);
                    if (b != null) {
                      widget.onSecondaryTap?.call(b.block, d.globalPosition);
                    }
                  },
                  // The pebbles are one cached layer; hovering repaints only
                  // the hovered one on top.
                  child: RepaintBoundary(
                    child: CustomPaint(
                      size: canvas,
                      painter: painter(),
                      foregroundPainter: _hover == null
                          ? null
                          : painter(only: _hover),
                    ),
                  ),
                ),
              ),
            ),
            if (hovered != null)
              Positioned(
                left: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: _MapPill(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: viewport.width * 0.6,
                      ),
                      child: Text(
                        [hovered.label, ?hovered.caption].join('  ·  '),
                        key: const ValueKey('map-hover'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: p.text),
                      ),
                    ),
                  ),
                ),
              ),
            if (fit < 1)
              Positioned(
                right: 0,
                bottom: 0,
                child: _MapPill(
                  child: LinkText(
                    _fitted ? '放大查看' : '看全部',
                    key: const ValueKey('map-fit'),
                    onTap: () => _toggleFit(fit),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// A small floating label over the map.
class _MapPill extends StatelessWidget {
  final Widget child;

  const _MapPill({required this.child});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: p.line, width: hairline),
      ),
      child: child,
    );
  }
}

/// Fill for a block state, at full contrast: organized is the solid ink
/// (near-black on paper, cream in the dark), non-media recedes toward the
/// paper, mixed sits between; unorganized has no fill (contours). [id] nudges
/// the lightness a little so neighbours of one state don't merge.
Color? blockFill(BlockState s, Palette p, {required bool dark, String? id}) {
  final t = p.tones;
  final base = switch (s) {
    BlockState.organized => dark ? t[0] : t[4],
    BlockState.mixed => dark ? t[1] : t[2],
    BlockState.other => dark ? t[3] : t[0],
    BlockState.unorganized => null,
  };
  if (base == null || id == null) return base;
  final hsl = HSLColor.fromColor(base);
  final nudge = (hashUnit(id) - 0.5) * 0.07;
  return hsl.withLightness((hsl.lightness + nudge).clamp(0.0, 1.0)).toColor();
}

class _MapPainter extends CustomPainter {
  final List<_PlacedBlock> placed;
  final Palette palette;
  final bool dark;

  /// When set, paints only this block, hovered, over the cached layer.
  final String? hover;
  final Set<String> selected;
  final TextScaler textScaler;
  final TextStyle baseStyle;

  _MapPainter({
    required this.placed,
    required this.palette,
    required this.dark,
    required this.hover,
    required this.selected,
    required this.textScaler,
    required this.baseStyle,
  });

  static const _contourStep = 7.0;

  @override
  void paint(Canvas canvas, Size size) {
    final p = palette;
    for (final b in placed) {
      final hovered = b.block.id == hover;
      if (hover != null && !hovered) continue;
      final fill = blockFill(b.block.state, p, dark: dark, id: b.block.id);
      final label = _labelFor(b, fill);
      if (fill == null) {
        final line = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = hovered ? 0.8 : 0.5
          ..isAntiAlias = true
          ..color = hovered
              ? p.text.withValues(alpha: math.min(1, p.contour.a * 1.6))
              : p.contour;
        canvas.drawPath(pebblePath(b.polygon), line);
        final keep = label?.rect.inflate(6);
        for (final ring in contourRings(b.polygon, _contourStep, keep: keep)) {
          canvas.drawPath(pebblePath(ring), line);
        }
      } else {
        final c = hovered
            ? Color.lerp(fill, dark ? Colors.white : Colors.black, 0.08)!
            : fill;
        canvas.drawPath(pebblePath(b.polygon), Paint()..color = c);
      }
      if (selected.contains(b.block.id)) {
        final path = pebblePath(b.polygon);
        canvas.drawPath(
          path,
          Paint()..color = p.accent.withValues(alpha: 0.14),
        );
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = p.accent,
        );
      }
      label?.paint(canvas);
    }
  }

  _Label? _labelFor(_PlacedBlock b, Color? fill) {
    final p = palette;
    final ink = fill == null
        ? p.text
        : fill.computeLuminance() > 0.33
        ? const Color(0xFF1D1C1A)
        : const Color(0xFFF1EFE7);
    final c = polygonCentroid(b.polygon);
    // Smoothing eats the corners; the middle of each chord is what's left.
    final width = chordWidth(b.polygon, c.dy) * 0.78;
    final height = chordHeight(b.polygon, c.dx) * 0.72;
    if (width < 36 || height < 22) return null;
    final big = math.min(width, height) > 140;
    TextPainter line(
      String text,
      double size,
      FontWeight w,
      double alpha, {
      int maxLines = 2,
    }) => TextPainter(
      text: TextSpan(
        text: text,
        style: baseStyle.copyWith(
          fontSize: size,
          fontWeight: w,
          color: ink.withValues(alpha: alpha),
          height: 1.3,
          decoration: TextDecoration.none,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: maxLines,
      ellipsis: '…',
      textScaler: textScaler,
    )..layout(maxWidth: width);
    final name = line(b.block.label, big ? 17 : 13, FontWeight.w400, 1);
    final caption = b.block.caption == null
        ? null
        : line(
            b.block.caption!,
            big ? 17 : 12,
            FontWeight.w300,
            0.72,
            maxLines: 1,
          );
    // A cut-off number says nothing: drop the size rather than show "35.4…".
    final size = caption == null || caption.didExceedMaxLines ? null : caption;
    final lines = [
      if (name.height + (size?.height ?? 0) + 2 <= height) name,
      ?size,
    ];
    if (lines.isEmpty) return null;
    final total = lines.fold(0.0, (s, l) => s + l.height) + 2;
    if (total > height) return null;
    final w = lines.map((l) => l.width).reduce(math.max);
    return _Label(lines, Rect.fromCenter(center: c, width: w, height: total));
  }

  @override
  bool shouldRepaint(_MapPainter old) =>
      !identical(old.placed, placed) ||
      old.hover != hover ||
      !identical(old.selected, selected) ||
      old.palette != palette ||
      old.dark != dark;
}

class _Label {
  final List<TextPainter> lines;
  final Rect rect;

  const _Label(this.lines, this.rect);

  void paint(Canvas canvas) {
    var y = rect.top;
    for (final l in lines) {
      l.paint(canvas, Offset(rect.center.dx - l.width / 2, y));
      y += l.height + 2;
    }
  }
}
