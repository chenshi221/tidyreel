import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import 'organic_layout.dart';
import 'size_scanner.dart';

/// Smallest area a block is drawn with (logical px²): big enough to hover
/// and click, small enough that areas still read as sizes.
const minBlockArea = 2500.0;

/// A folder name without the trailing year and id tags, for a block's label:
/// 「死神 (2004) {tmdb-30984}」 → 「死神」.
String shortName(String name) {
  final s = name
      .replaceAll(RegExp(r'\s*[\[{][^\]}]*[\]}]\s*$'), '')
      .replaceAll(RegExp(r'[\s.]*[(（]?(?:19|20)\d{2}[)）]?\s*$'), '')
      .trim();
  return s.isEmpty ? name : s;
}

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

/// How the map zooms; picked with the switch beside the zoom buttons.
enum MapZoomStyle {
  /// Geometric zoom; pebbles past the edge are clipped by the frame and
  /// re-rounded, so every one on screen looks whole.
  frame('缩放'),

  /// Zooming re-lays out the pebbles in view to fill the frame, morphing
  /// from the old picture to the new.
  semantic('展开');

  final String label;

  const MapZoomStyle(this.label);
}

/// Shared by every map so it survives folder changes.
final mapZoomStyle = ValueNotifier(MapZoomStyle.frame);

/// Pebbles over 200×200 px that got no name in the last paint (debug only).
@visibleForTesting
final debugUnlabeled = <String>{};

/// Points per outline while morphing: enough that big pebbles show no facets.
const _morphPoints = 96;

/// Pebbles thinner than this (px) at the frame are dropped, not drawn as
/// slivers.
const _minThickness = 16.0;

/// Label boxes tried, as shares of a pebble's width and height through its
/// middle: wide and short first, as text likes.
const _boxes = [
  (0.9, 0.4),
  (0.85, 0.55),
  (0.75, 0.65),
  (0.65, 0.75),
  (0.7, 0.45),
  (0.6, 0.55),
  (0.5, 0.5),
  (0.55, 0.35),
  (0.4, 0.4),
];

class _PlacedBlock {
  final MapBlock block;
  final List<Offset> polygon;

  /// [polygon] is already a rounded outline: draw it as is.
  final bool smooth;

  const _PlacedBlock(this.block, this.polygon, {this.smooth = false});
}

/// How a painter gets its labels: laid out once on [source] for [zoom],
/// cached in [cache], drawn [scale] times larger at the pebble's middle.
class _LabelPlan {
  final List<Offset>? Function(String id) source;
  final double zoom;
  final double scale;
  final Map<String, _Label?> cache;

  const _LabelPlan(
    this.source, {
    required this.zoom,
    required this.scale,
    required this.cache,
  });
}

class _OrganicMapState extends State<OrganicMap> with TickerProviderStateMixin {
  final _view = TransformationController();

  /// Eases button zooms and 显示全部 (style A).
  late final _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..addListener(_step);
  Matrix4Tween? _tween;

  String? _hover;

  /// What was drawn last, in screen space: hit testing uses it.
  List<_PlacedBlock> _placed = const [];

  /// Last layout and what it was for: a rebuild with equal sizes reuses it.
  List<MapCell> _cells = const [];
  String? _laidOut;

  /// Canvas the view was last fitted to: a new canvas starts fitted again.
  Size? _fittedFor;
  double _minScale = 1;
  Size _viewport = Size.zero;
  Size _canvas = Size.zero;

  static const _maxScale = 6.0;

  String _blockIds = '';

  // ---- C: semantic
  /// The part of the full map (canvas space) in view; null = all of it.
  Rect? _focus;

  /// Raw (unclipped) screen polygons of the picture at rest; null = the
  /// full map.
  Map<String, List<Offset>>? _rest;

  /// A morph in progress: drawn (clipped, inset, rounded) outlines blended
  /// point by point, so corners stay round all the way.
  Map<String, List<Offset>> _from = const {}, _to = const {};

  /// Laid-out labels, kept across frames so text never reflows mid-motion;
  /// cleared when what they were laid out for changes.
  final _labels = <String, _Label?>{};
  Object? _labelsFor;
  late final _morph = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
  )..addListener(() => setState(() {}));

  /// A pinch or drag in progress, applied on top of the picture.
  Matrix4? _gesture;
  Offset _gestureFocal = Offset.zero;

  @override
  void initState() {
    super.initState();
    mapZoomStyle.addListener(_onStyle);
  }

  @override
  void didUpdateWidget(OrganicMap old) {
    super.didUpdateWidget(old);
    final ids = widget.blocks.map((b) => b.id).join('\u0000');
    if (ids != _blockIds) {
      _blockIds = ids;
      _focus = null;
      _rest = null;
      _from = _to = const {};
    }
  }

  void _onStyle() => setState(() {
    _focus = null;
    _rest = null;
    _from = _to = const {};
    _gesture = null;
    _anim.stop();
    _view.value = _fitted;
  });

  @override
  void dispose() {
    mapZoomStyle.removeListener(_onStyle);
    _anim.dispose();
    _morph.dispose();
    _view.dispose();
    super.dispose();
  }

  MapZoomStyle get _style => mapZoomStyle.value;

  /// Lays [items] out in [bounds]; the last result is reused when nothing
  /// changed (the Voronoi layout is costly).
  List<MapCell> _layout(
    List<MapItem> items,
    Rect bounds, {
    Map<String, Offset>? seeds,
  }) {
    final rough = widget.counting && items.length > 60;
    final key = [
      rough,
      bounds,
      seeds == null,
      for (final i in items) '${i.id}\u0000${i.value.round()}',
    ].join('\u0001');
    if (key == _laidOut) return _cells;
    _laidOut = key;
    return _cells = layoutOrganic(
      items,
      bounds,
      iterations: rough ? 30 : 120,
      seeds: seeds,
    );
  }

  /// Each pebble's own share of the gap, so gaps vary like stones laid by
  /// hand. In screen px: it stays the same at every zoom.
  double _insetOf(String id) => widget.gap / 2 * (0.8 + 0.4 * hashUnit(id));

  /// Raw screen polygons → what is drawn: clipped by the frame, then inset,
  /// so a pebble at the edge is whole and rounded, just flatter.
  List<_PlacedBlock> _finish(
    Iterable<(MapBlock, List<Offset>)> raw,
    Size viewport,
  ) {
    final frame = Offset.zero & viewport;
    return [
      for (final (b, poly) in raw)
        if (poly.length >= 3 && polygonBounds(poly).overlaps(frame))
          if (insetConvex(clipToRect(poly, frame), _insetOf(b.id)) case final p
              when p.isNotEmpty &&
                  polygonBounds(p).shortestSide >= _minThickness)
            _PlacedBlock(b, p),
    ];
  }

  /// What [_finish] would draw for [raw], rounded, as [resampleRadial]
  /// points; one that leaves the frame shrinks to a point on its edge.
  List<Offset> _drawn(String id, List<Offset> raw) {
    final frame = Offset.zero & _viewport;
    final p = insetConvex(clipToRect(raw, frame), _insetOf(id));
    if (p.isEmpty) {
      final c = polygonCentroid(raw);
      final at = Offset(
        c.dx.clamp(0, _viewport.width),
        c.dy.clamp(0, _viewport.height),
      );
      return List.filled(_morphPoints, at);
    }
    return resampleRadial(smoothPolygon(p), _morphPoints);
  }

  bool get _morphing => _from.isNotEmpty;

  /// Ends a morph at once (another zoom or a drag takes over).
  void _settleMorph() {
    _morph.stop();
    _from = _to = const {};
  }

  _PlacedBlock? _hit(Offset local) {
    for (final b in _placed) {
      if (polygonContains(b.polygon, local)) return b;
    }
    return null;
  }

  // ---- A: geometric zoom, eased

  void _step() => _view.value = _tween!.transform(
    Curves.easeOutCubic.transform(_anim.value),
  );

  void _animateTo(Matrix4 to) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _anim.stop();
      _view.value = to;
      return;
    }
    _tween = Matrix4Tween(begin: _view.value.clone(), end: to);
    _anim.forward(from: 0);
  }

  /// Where the view is heading: quick repeated clicks build on each other.
  Matrix4 get _goal => _anim.isAnimating ? _tween!.end! : _view.value;

  Matrix4 get _fitted =>
      Matrix4.identity()..scaleByDouble(_minScale, _minScale, _minScale, 1);

  void _zoomBy(double factor) {
    final goal = _goal;
    final now = goal.getMaxScaleOnAxis();
    final f = (now * factor).clamp(_minScale, _maxScale) / now;
    _animateTo(_about(_viewport.center(Offset.zero), f)..multiply(goal));
  }

  /// Scaling by [f] around screen point [c].
  static Matrix4 _about(Offset c, double f) => Matrix4.identity()
    ..translateByDouble(c.dx, c.dy, 0, 1)
    ..scaleByDouble(f, f, f, 1)
    ..translateByDouble(-c.dx, -c.dy, 0, 1);

  List<(MapBlock, List<Offset>)> _geometric(Matrix4 m) {
    final byId = {for (final b in widget.blocks) b.id: b};
    return [
      for (final c in _cells)
        if (byId[c.id] case final b?)
          (b, [for (final p in c.polygon) MatrixUtils.transformPoint(m, p)]),
    ];
  }

  // ---- C: semantic zoom

  Rect get _full => Offset.zero & _canvas;

  /// Screen → canvas for [focus] shown in the viewport, and back.
  double _k(Rect focus) => focus.width / _viewport.width;
  Offset _toCanvas(Rect f, Offset s) => f.topLeft + s * _k(f);
  Offset _toScreen(Rect f, Offset c) => (c - f.topLeft) / _k(f);

  /// The pebbles in [focus], laid out to fill the viewport, raw.
  Map<String, List<Offset>> _semanticLayout(Rect focus) {
    if (focus == _full) {
      return {
        for (final c in _cells)
          c.id: [for (final p in c.polygon) _toScreen(focus, p)],
      };
    }
    // Each pebble that shows, weighted by how much of it shows: the new
    // picture keeps the proportions plain zooming would have.
    final inView = [
      for (final c in _cells)
        if (clipToRect(c.polygon, focus) case final part
            when part.isNotEmpty && polygonArea(part) > 1e-6)
          (c.id, c.value * polygonArea(part) / c.area, polygonCentroid(part)),
    ];
    final cells = layoutOrganic(
      [for (final (id, v, _) in inView) MapItem(id, v)],
      Offset.zero & _viewport,
      iterations: inView.length > 60 ? 40 : 80,
      seeds: {for (final (id, _, at) in inView) id: _toScreen(focus, at)},
    );
    return {for (final c in cells) c.id: c.polygon};
  }

  /// Raw screen polygons of the picture at rest.
  Map<String, List<Offset>> get _current =>
      _rest ??= _semanticLayout(_focus ?? _full);

  /// Morphs from what is on screen ([shown], seen as [was]) to [focus].
  void _semanticGo(Rect focus, Map<String, List<Offset>> shown, Rect was) {
    focus = _clampFocus(focus);
    final next = _semanticLayout(focus);
    // Pebbles that leave slide off the way plain zooming would take them;
    // ones that arrive come in from where they'd have been.
    List<Offset> moved(List<Offset> poly, Rect a, Rect b) => [
      for (final p in poly) _toScreen(b, _toCanvas(a, p)),
    ];
    final cellOf = {for (final c in _cells) c.id: c.polygon};
    final from = <String, List<Offset>>{};
    final to = <String, List<Offset>>{};
    for (final id in {...shown.keys, ...next.keys}) {
      final a = shown[id] ?? [for (final p in cellOf[id]!) _toScreen(was, p)];
      final b = next[id] ?? moved(shown[id]!, was, focus);
      from[id] = _drawn(id, a);
      to[id] = _drawn(id, b);
    }
    _focus = focus;
    _gesture = null;
    _rest = next;
    if (MediaQuery.disableAnimationsOf(context)) {
      _settleMorph();
      setState(() {});
      return;
    }
    _from = from;
    _to = to;
    _morph.forward(from: 0).whenComplete(() {
      if (mounted && identical(_to, to)) setState(_settleMorph);
    });
  }

  /// Keeps [f] inside the full map, at the viewport's shape, and no deeper
  /// than [_maxScale].
  Rect _clampFocus(Rect f) {
    final full = _full;
    final w = f.width.clamp(full.width / _maxScale, full.width);
    final h = w * full.height / full.width;
    final l = (f.center.dx - w / 2).clamp(full.left, full.right - w);
    final t = (f.center.dy - h / 2).clamp(full.top, full.bottom - h);
    return Rect.fromLTWH(l, t, w, h);
  }

  /// Zooms by [factor] around screen point [at].
  void _semanticZoom(double factor, [Offset? at]) {
    _settleMorph();
    final f = _focus ?? _full;
    final c = _toCanvas(f, at ?? _viewport.center(Offset.zero));
    final w = f.width / factor, h = f.height / factor;
    final rx = (c.dx - f.left) / f.width, ry = (c.dy - f.top) / f.height;
    _semanticGo(Rect.fromLTWH(c.dx - w * rx, c.dy - h * ry, w, h), _current, f);
  }

  void _semanticEnd() {
    final g = _gesture;
    if (g == null) return;
    final f = _focus ?? _full;
    final inv = Matrix4.inverted(g);
    // The view the gesture left us looking at, in canvas space.
    final tl = _toCanvas(f, MatrixUtils.transformPoint(inv, Offset.zero));
    final br = _toCanvas(
      f,
      MatrixUtils.transformPoint(inv, _viewport.bottomRight(Offset.zero)),
    );
    final was = Rect.fromPoints(tl, br);
    final shown = {
      for (final e in _current.entries)
        e.key: [for (final p in e.value) MatrixUtils.transformPoint(g, p)],
    };
    _semanticGo(was, shown, was);
  }

  void _fitAll() => switch (_style) {
    MapZoomStyle.frame => _animateTo(_fitted),
    MapZoomStyle.semantic => () {
      _settleMorph();
      _semanticGo(_full, _current, _focus ?? _full);
    }(),
  };

  void _zoomButton(double factor) => switch (_style) {
    MapZoomStyle.frame => _zoomBy(factor),
    MapZoomStyle.semantic => _semanticZoom(factor),
  };

  // ---- build

  /// Labels laid out on [source] (local units, sized for [zoom]) and drawn
  /// [scale] times larger; [gen] says what the cached ones are valid for.
  _LabelPlan _plan(
    Object gen,
    List<Offset>? Function(String id) source, {
    double zoom = 1,
    double scale = 1,
  }) {
    if (gen != _labelsFor) {
      _labels.clear();
      _labelsFor = gen;
    }
    return _LabelPlan(source, zoom: zoom, scale: scale, cache: _labels);
  }

  (List<_PlacedBlock>, _LabelPlan) _picture(Size viewport) {
    switch (_style) {
      case MapZoomStyle.frame:
        final m = _view.value;
        final s = m.getMaxScaleOnAxis();
        // Text is laid out per quarter-octave of zoom, on the whole pebble:
        // it only scales a little in between, never reflows.
        final q = math
            .pow(2, (math.log(s) / math.ln2 * 4).round() / 4)
            .toDouble();
        final cellOf = {for (final c in _cells) c.id: c.polygon};
        return (
          _finish(_geometric(m), viewport),
          _plan(
            (_cells, widget.blocks, q),
            (id) => switch (cellOf[id]) {
              final c? => insetConvex(c, _insetOf(id) / q),
              null => null,
            },
            zoom: q,
            // Canvas units → screen: text sized for q shows at its size
            // within a few percent.
            scale: s,
          ),
        );
      case MapZoomStyle.semantic:
        final byId = {for (final b in widget.blocks) b.id: b};
        if (_morphing) {
          final t = Curves.easeInOutCubic.transform(_morph.value);
          return (
            [
              for (final id in _to.keys)
                if (byId[id] case final b?)
                  if (lerpPolygon(_from[id]!, _to[id]!, t) case final poly
                      when polygonArea(poly) > 1)
                    _PlacedBlock(b, poly, smooth: true),
            ],
            // No text while the picture changes shape.
            _plan(_to, (_) => null),
          );
        }
        final rest = _current;
        final still = _finish([
          for (final e in rest.entries)
            if (byId[e.key] case final b?) (b, e.value),
        ], viewport);
        final polyOf = {for (final b in still) b.block.id: b.polygon};
        final g = _gesture;
        final plan = _plan(
          (rest, widget.blocks),
          (id) => polyOf[id],
          scale: g?.getMaxScaleOnAxis() ?? 1,
        );
        if (g == null) return (still, plan);
        return (
          _finish([
            for (final e in rest.entries)
              if (byId[e.key] case final b?)
                (
                  b,
                  [for (final p in e.value) MatrixUtils.transformPoint(g, p)],
                ),
          ], viewport),
          plan,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, box) {
        final viewport = box.biggest;
        _viewport = viewport;
        final style = _style;
        final items = mapItems(widget.blocks, viewport);
        _canvas = mapCanvas(items, viewport);
        _layout(items, Offset.zero & _canvas);
        final fit = math.min(
          viewport.width / _canvas.width,
          viewport.height / _canvas.height,
        );
        _minScale = math.min(fit, 1);
        // Show everything first; zoom in from there.
        if (_fittedFor != _canvas) {
          _fittedFor = _canvas;
          _focus = null;
          _rest = null;
          _from = _to = const {};
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _view.value = _fitted;
          });
        }

        Widget paint(BuildContext context) {
          final (placed, labels) = _picture(viewport);
          _placed = placed;
          _MapPainter painter({String? only}) => _MapPainter(
            placed: placed,
            palette: p,
            dark: dark,
            hover: only,
            selected: widget.selected,
            textScaler: MediaQuery.textScalerOf(context),
            zoom: 1,
            labels: labels,
            baseStyle: DefaultTextStyle.of(context).style,
          );
          return CustomPaint(
            size: viewport,
            painter: painter(),
            foregroundPainter: _hover == null ? null : painter(only: _hover),
          );
        }

        final picture = IgnorePointer(
          child: style == MapZoomStyle.frame
              ? AnimatedBuilder(
                  animation: _view,
                  builder: (context, _) => paint(context),
                )
              : Builder(builder: paint),
        );

        // Gestures: A pans and pinches through InteractiveViewer; C turns a
        // pinch or drag into a new focus when it ends.
        final Widget input = switch (style) {
          MapZoomStyle.frame => InteractiveViewer(
            key: const ValueKey('map-viewer'),
            transformationController: _view,
            constrained: false,
            minScale: _minScale,
            maxScale: _maxScale,
            onInteractionStart: (_) => _anim.stop(),
            child: SizedBox.fromSize(size: _canvas),
          ),
          MapZoomStyle.semantic => Listener(
            onPointerSignal: (e) {
              if (e is PointerScrollEvent && !_morph.isAnimating) {
                if (e.scrollDelta.dy.abs() < 4) return;
                _semanticZoom(
                  e.scrollDelta.dy < 0 ? 1.5 : 1 / 1.5,
                  e.localPosition,
                );
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: (d) {
                _settleMorph();
                _gestureFocal = d.localFocalPoint;
              },
              onScaleUpdate: (d) => setState(() {
                _gesture = Matrix4.translationValues(
                  d.localFocalPoint.dx - _gestureFocal.dx,
                  d.localFocalPoint.dy - _gestureFocal.dy,
                  0,
                )..multiply(_about(_gestureFocal, d.scale));
              }),
              onScaleEnd: (_) => _semanticEnd(),
            ),
          ),
        };

        final hovered = _placed
            .where((b) => b.block.id == _hover)
            .firstOrNull
            ?.block;
        return Stack(
          children: [
            Positioned.fill(child: picture),
            Positioned.fill(
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
                  behavior: HitTestBehavior.translucent,
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
                  child: input,
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
                        style: TextStyle(
                          fontSize: TypeScale.small,
                          color: p.text,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              right: 0,
              bottom: 0,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Segmented<MapZoomStyle>(
                    key: const ValueKey('map-style'),
                    options: {for (final s in MapZoomStyle.values) s: s.label},
                    value: style,
                    onChanged: (s) => mapZoomStyle.value = s,
                  ),
                  const SizedBox(width: 8),
                  _MapPill(
                    padding: EdgeInsets.zero,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ZoomButton(
                          key: const ValueKey('map-zoom-out'),
                          icon: CupertinoIcons.minus,
                          tooltip: '缩小',
                          onTap: () => _zoomButton(1 / 1.5),
                        ),
                        _ZoomButton(
                          key: const ValueKey('map-zoom-in'),
                          icon: CupertinoIcons.plus,
                          tooltip: '放大，显示更多名字',
                          onTap: () => _zoomButton(1.5),
                        ),
                        _ZoomButton(
                          key: const ValueKey('map-fit'),
                          icon: CupertinoIcons.fullscreen_exit,
                          tooltip: '显示全部',
                          onTap: _fitAll,
                        ),
                      ],
                    ),
                  ),
                ],
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
  final EdgeInsetsGeometry padding;

  const _MapPill({
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: p.line, width: hairline),
      ),
      child: child,
    );
  }
}

class _ZoomButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _ZoomButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Tooltip(
      message: tooltip,
      child: Hoverable(
        onTap: onTap,
        builder: (context, hover) => Container(
          width: 30,
          height: 28,
          color: hover ? p.hover : Colors.transparent,
          child: Icon(icon, size: 14, color: p.textMuted),
        ),
      ),
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

  /// View scale: text and the room it needs are divided by it, so labels
  /// keep their on-screen size and more of them fit as you zoom in.
  final double zoom;

  /// Stable, cached labels; without it each paint lays labels out afresh.
  final _LabelPlan? labels;

  _MapPainter({
    this.labels,
    required this.placed,
    required this.palette,
    required this.dark,
    required this.hover,
    required this.selected,
    required this.textScaler,
    required this.baseStyle,
    required this.zoom,
  });

  static const _contourStep = 7.0;

  @override
  void paint(Canvas canvas, Size size) {
    final p = palette;
    assert(() {
      debugUnlabeled.clear();
      return true;
    }());
    for (final b in placed) {
      final hovered = b.block.id == hover;
      if (hover != null && !hovered) continue;
      final fill = blockFill(b.block.state, p, dark: dark, id: b.block.id);
      // A morphing outline is already round: a light pass hides the facets
      // between its sample points. Contour rings inset from it get the full
      // rounding, or their corners come out sharp.
      Path path(List<Offset> poly) => b.smooth
          ? (Path()
              ..addPolygon(smoothPolygon(poly, rounds: 2, minEdge: 0), true))
          : pebblePath(poly);
      final (label, at) = _place(b, fill);
      assert(() {
        if (label == null && polygonArea(b.polygon) > 200 * 200) {
          debugUnlabeled.add(b.block.label);
        }
        return true;
      }());
      if (fill == null) {
        final line = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = hovered ? 0.8 : 0.5
          ..isAntiAlias = true
          ..color = hovered
              ? p.text.withValues(alpha: math.min(1, p.contour.a * 1.6))
              : p.contour;
        canvas.drawPath(path(b.polygon), line);
        final keep = at?.inflate(6);
        for (final ring in contourRings(b.polygon, _contourStep, keep: keep)) {
          canvas.drawPath(pebblePath(ring), line);
        }
      } else {
        final c = hovered
            ? Color.lerp(fill, dark ? Colors.white : Colors.black, 0.08)!
            : fill;
        canvas.drawPath(path(b.polygon), Paint()..color = c);
      }
      if (selected.contains(b.block.id)) {
        final outline = path(b.polygon);
        canvas.drawPath(
          outline,
          Paint()..color = p.accent.withValues(alpha: 0.14),
        );
        canvas.drawPath(
          outline,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = p.accent,
        );
      }
      if (label != null && at != null) {
        final k = at.width / label.rect.width;
        canvas
          ..save()
          ..translate(at.center.dx, at.center.dy)
          ..scale(k);
        label.paint(canvas);
        canvas.restore();
      }
    }
  }

  /// [b]'s label and where it goes on screen; none when it wouldn't sit
  /// wholly inside the pebble as drawn.
  (_Label?, Rect?) _place(_PlacedBlock b, Color? fill) {
    final plan = labels;
    final label = plan == null
        ? _labelFor(b.block, b.polygon, fill, zoom)
        : plan.cache.putIfAbsent(
            '${b.block.id}\u0000${fill?.toARGB32()}\u0000${plan.zoom}',
            () => switch (plan.source(b.block.id)) {
              final src? when src.length >= 3 => _labelFor(
                b.block,
                src,
                fill,
                plan.zoom,
              ),
              _ => null,
            },
          );
    // Against the outline as drawn (rounding eats the corners), with air.
    final outline = b.smooth ? b.polygon : smoothPolygon(b.polygon);
    final c = polygonCentroid(b.polygon);
    (_Label, Rect)? fit(_Label? l, double k) {
      if (l == null) return null;
      final at = Rect.fromCenter(
        center: c,
        width: l.rect.width * k,
        height: l.rect.height * k,
      );
      return _inside(outline, at.inflate(4)) ? (l, at) : null;
    }

    if (fit(label, plan?.scale ?? 1) case final ok?) return ok;
    if (plan == null) return (null, null);
    // Cut by the frame, the pebble is smaller than the shape the text was
    // laid out on: lay it out again on what shows, per 24px of size so it
    // doesn't reflow every frame.
    final box = polygonBounds(b.polygon);
    final again = plan.cache.putIfAbsent(
      '${b.block.id}\u0000${fill?.toARGB32()}\u0000'
      '${(box.width / 24).round()}x${(box.height / 24).round()}',
      () => _labelFor(b.block, b.polygon, fill, 1),
    );
    return fit(again, 1) ?? (null, null);
  }

  static bool _inside(List<Offset> outline, Rect r) => [
    r.topLeft,
    r.topRight,
    r.bottomLeft,
    r.bottomRight,
  ].every((pt) => polygonContains(outline, pt));

  _Label? _labelFor(MapBlock block, List<Offset> poly, Color? fill, double z) {
    final p = palette;
    final ink = fill == null
        ? p.text
        : fill.computeLuminance() > 0.33
        ? Palette.light.text
        : Palette.light.canvas;
    final c = polygonCentroid(poly);
    // The biggest box around the middle that clears the rounded outline:
    // text laid out inside it is sure to fit where it is drawn.
    final outline = smoothPolygon(poly);
    final cw = chordWidth(outline, c.dy), ch = chordHeight(outline, c.dx);
    var width = 0.0, height = 0.0;
    for (final (fw, fh) in _boxes) {
      final w = cw * fw, h = ch * fh;
      if (w * h <= width * height) continue;
      final r = Rect.fromCenter(center: c, width: w, height: h);
      if (_inside(outline, r.inflate(4 / z))) (width, height) = (w, h);
    }
    if (width * z < 40 || height * z < 18) return null;
    final side = math.min(width, height) * z;
    final big = side > 140;
    // Smaller blocks get smaller text, so nearly every block carries its name.
    final nameSize = big ? 17.0 : (side > 80 ? 13.0 : 11.0);
    TextPainter line(
      String text,
      double size,
      FontWeight w,
      double alpha, {
      int maxLines = 3,
    }) => TextPainter(
      text: TextSpan(
        text: text,
        style: baseStyle.copyWith(
          fontSize: size / z,
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
    final label = shortName(block.label);
    var name = line(label, nameSize, FontWeight.w400, 1);
    // Fewer lines until the name fits the block's height.
    for (var n = 2; name.height > height && n >= 1; n--) {
      name = line(label, nameSize, FontWeight.w400, 1, maxLines: n);
    }
    if (name.height > height) return null;
    final caption = block.caption == null
        ? null
        : line(
            block.caption!,
            big ? 17 : 12,
            FontWeight.w300,
            0.72,
            maxLines: 1,
          );
    // The size only when it fits whole next to the name; a bare size or a
    // cut-off one ("35.4…") says nothing about which folder it is.
    final size =
        caption == null ||
            caption.didExceedMaxLines ||
            name.height + caption.height + 2 / z > height
        ? null
        : caption;
    final lines = [name, ?size];
    final total = lines.fold(0.0, (s, l) => s + l.height) + 2 / z;
    if (total > height) return null;
    final w = lines.map((l) => l.width).reduce(math.max);
    return _Label(
      lines,
      Rect.fromCenter(center: Offset.zero, width: w, height: total),
      gap: 2 / z,
    );
  }

  @override
  bool shouldRepaint(_MapPainter old) =>
      !identical(old.placed, placed) ||
      old.hover != hover ||
      !identical(old.selected, selected) ||
      old.palette != palette ||
      old.zoom != zoom ||
      old.labels?.scale != labels?.scale ||
      old.dark != dark;
}

class _Label {
  final List<TextPainter> lines;
  final Rect rect;
  final double gap;

  const _Label(this.lines, this.rect, {required this.gap});

  void paint(Canvas canvas) {
    var y = rect.top;
    for (final l in lines) {
      l.paint(canvas, Offset(rect.center.dx - l.width / 2, y));
      y += l.height + gap;
    }
  }
}
