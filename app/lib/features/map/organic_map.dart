import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ui/tokens.dart';
import 'organic_layout.dart';
import 'size_scanner.dart';

/// Smallest share of the map a block is drawn with.
const minShareDrawn = 0.025;

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

  /// Space between pebbles.
  final double gap;

  const OrganicMap({
    super.key,
    required this.blocks,
    this.onTap,
    this.onSecondaryTap,
    this.gap = 9,
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
  String? _hover;
  List<_PlacedBlock> _placed = const [];
  Size? _size;
  List<MapBlock>? _laidOut;

  List<_PlacedBlock> _layout(Size size) {
    if (size == _size && identical(widget.blocks, _laidOut)) return _placed;
    _size = size;
    _laidOut = widget.blocks;
    final byId = {for (final b in widget.blocks) b.id: b};
    // A floor on the drawn area keeps the long tail visible and clickable;
    // labels still show real sizes.
    final total = widget.blocks.fold(0, (t, b) => t + b.bytes);
    final cells = layoutOrganic(
      [
        for (final b in widget.blocks)
          MapItem(b.id, math.max(b.bytes.toDouble(), total * minShareDrawn)),
      ],
      Offset.zero & size,
      maxTilt: 0.3,
    );
    return _placed = [
      for (final c in cells)
        if (insetConvex(c.polygon, widget.gap / 2) case final poly
            when poly.isNotEmpty)
          _PlacedBlock(byId[c.id]!, poly),
    ];
  }

  _PlacedBlock? _hit(Offset local) {
    for (final b in _placed) {
      if (polygonContains(b.polygon, local)) return b;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, box) {
        final placed = _layout(box.biggest);
        return MouseRegion(
          cursor: _hover == null ? MouseCursor.defer : SystemMouseCursors.click,
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
            child: CustomPaint(
              size: box.biggest,
              painter: _MapPainter(
                placed: placed,
                palette: p,
                dark: dark,
                hover: _hover,
                textScaler: MediaQuery.textScalerOf(context),
                baseStyle: DefaultTextStyle.of(context).style,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Fill for a block state. Organized reads solid and calm, mixed in between,
/// non-media recedes toward the paper; unorganized has no fill (contours).
Color? blockFill(BlockState s, Palette p, {required bool dark}) {
  final t = p.tones;
  return switch (s) {
    BlockState.organized => dark ? t[1] : t[3],
    BlockState.mixed => t[2],
    BlockState.other => dark ? t[3] : t[0],
    BlockState.unorganized => null,
  };
}

class _MapPainter extends CustomPainter {
  final List<_PlacedBlock> placed;
  final Palette palette;
  final bool dark;
  final String? hover;
  final TextScaler textScaler;
  final TextStyle baseStyle;

  _MapPainter({
    required this.baseStyle,
    required this.placed,
    required this.palette,
    required this.dark,
    required this.hover,
    required this.textScaler,
  });

  static const _radius = Radii.pebble;
  static const _contourStep = 9.0;

  @override
  void paint(Canvas canvas, Size size) {
    final p = palette;
    for (final b in placed) {
      final hovered = b.block.id == hover;
      final fill = blockFill(b.block.state, p, dark: dark);
      final outline = roundedPolygon(b.polygon, _radius);
      if (fill == null) {
        final line = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = hovered ? 0.9 : 0.6
          ..color = hovered
              ? p.text.withValues(alpha: p.contour.a * 1.5)
              : p.contour;
        canvas.drawPath(outline, line);
        for (final ring in contourRings(b.polygon, _contourStep)) {
          canvas.drawPath(roundedPolygon(ring, _radius), line);
        }
      } else {
        final c = hovered
            ? Color.lerp(fill, dark ? Colors.white : Colors.black, 0.07)!
            : fill;
        canvas.drawPath(outline, Paint()..color = c);
      }
      _label(canvas, b, fill);
    }
  }

  void _label(Canvas canvas, _PlacedBlock b, Color? fill) {
    final p = palette;
    final ink = fill == null
        ? p.text
        : fill.computeLuminance() > 0.33
        ? const Color(0xFF1D1C1A)
        : const Color(0xFFF1EFE7);
    // Unorganized contours sit behind the text; give the label a calm patch.
    final c = polygonCentroid(b.polygon);
    // Rounded corners only eat into the chord near the ends.
    final width = chordWidth(b.polygon, c.dy) - 1.2 * _radius;
    final height = chordHeight(b.polygon, c.dx) - 1.2 * _radius;
    if (width < 36 || height < 22) return;
    final big = math.min(width, height) > 150;
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
          height: 1.25,
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
    final name = line(b.block.label, big ? 16 : 13, FontWeight.w400, 1);
    final caption = b.block.caption == null
        ? null
        : line(
            b.block.caption!,
            big ? 16 : 12,
            FontWeight.w300,
            0.75,
            maxLines: 1,
          );
    // A cut-off number says nothing: drop the size rather than show "35.4…".
    final size = caption == null || caption.didExceedMaxLines ? null : caption;
    final lines = [
      if (name.height + (size?.height ?? 0) + 2 <= height) name,
      ?size,
    ];
    final total = lines.fold(0.0, (s, l) => s + l.height) + 2;
    if (lines.isEmpty || total > height) return;
    if (fill == null) {
      final w = lines.map((l) => l.width).reduce(math.max) + 24;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: c, width: w, height: total + 14),
          const Radius.circular(10),
        ),
        Paint()..color = p.canvas,
      );
    }
    var y = c.dy - total / 2;
    for (final l in lines) {
      l.paint(canvas, Offset(c.dx - l.width / 2, y));
      y += l.height + 2;
    }
  }

  @override
  bool shouldRepaint(_MapPainter old) =>
      !identical(old.placed, placed) ||
      old.hover != hover ||
      old.palette != palette ||
      old.dark != dark;
}
