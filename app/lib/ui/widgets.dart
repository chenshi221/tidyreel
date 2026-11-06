import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'tokens.dart';

/// A section of a page: a slightly lighter sheet on the paper. No shadow;
/// [framed] adds a hairline for scrolling lists that need a visible edge.
class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final bool framed;

  const Panel({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.color,
    this.framed = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: color ?? p.panel,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: framed ? Border.all(color: p.line, width: hairline) : null,
      ),
      padding: padding,
      child: child,
    );
  }
}

/// Children separated by inset hairlines, for use inside a [Panel].
class Rows extends StatelessWidget {
  final List<Widget> children;
  final double indent;

  const Rows({super.key, required this.children, this.indent = 0});

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) Divider(indent: indent),
        children[i],
      ],
    ],
  );
}

/// Hover tracking without the Material ink machinery.
class Hoverable extends StatefulWidget {
  final Widget Function(BuildContext, bool hover) builder;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;

  const Hoverable({
    super.key,
    required this.builder,
    this.onTap,
    this.onDoubleTap,
  });

  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  var _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onDoubleTap: widget.onDoubleTap,
      child: widget.builder(context, _hover),
    ),
  );
}

/// A list row that tints on hover. [hoverTrailing] only shows on hover (and
/// when [selected]); [trailing] is always shown.
class HoverRow extends StatelessWidget {
  final Widget? leading;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final Widget? hoverTrailing;
  final VoidCallback? onTap;
  final bool selected;
  final EdgeInsetsGeometry padding;
  final BorderRadius? borderRadius;

  const HoverRow({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.hoverTrailing,
    this.onTap,
    this.selected = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final theme = Theme.of(context);
    return Hoverable(
      onTap: onTap,
      builder: (context, hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: selected
              ? p.selected
              : (hover && onTap != null ? p.hover : Colors.transparent),
          borderRadius: borderRadius,
        ),
        padding: padding,
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 12)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  DefaultTextStyle.merge(
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    child: title,
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    DefaultTextStyle.merge(
                      style: theme.textTheme.bodySmall,
                      child: subtitle!,
                    ),
                  ],
                ],
              ),
            ),
            if (hoverTrailing != null)
              AnimatedOpacity(
                duration: const Duration(milliseconds: 120),
                opacity: hover || selected ? 1 : 0,
                child: hoverTrailing,
              ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          ],
        ),
      ),
    );
  }
}

/// Rounded square holding an icon (connection type, file kind…).
class IconTile extends StatelessWidget {
  final IconData icon;
  final double size;
  final Color? color;
  final Color? background;

  const IconTile(
    this.icon, {
    super.key,
    this.size = 30,
    this.color,
    this.background,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background ?? p.selected,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(icon, size: size * 0.52, color: color ?? p.textMuted),
    );
  }
}

/// Dot + label, e.g. 已连接 / 认证失败. No fill: the colour lives in the dot,
/// the label stays quiet.
class StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final bool busy;
  final IconData? icon;

  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.busy = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (busy)
          Spinner(size: 11, color: color)
        else if (icon != null)
          Icon(icon, size: 11, color: color)
        else
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(color: color, fontSize: 12)),
      ],
    ),
  );
}

/// Group heading above a panel (macOS settings style).
class SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const SectionLabel(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 22, 4, 7),
    child: Row(
      children: [
        Text(
          text,
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(color: Palette.of(context).textMuted),
        ),
        const Spacer(),
        ?trailing,
      ],
    ),
  );
}

/// Centered icon + title + description + optional action.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Concentric rings, the same contour motif as the map.
              SizedBox.square(
                dimension: 88,
                child: CustomPaint(
                  painter: _RingsPainter(p.contour),
                  child: Icon(icon, size: 26, color: p.textMuted),
                ),
              ),
              const SizedBox(height: 16),
              Text(title, style: theme.textTheme.titleMedium),
              if (message != null) ...[
                const SizedBox(height: 4),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ],
              if (action != null) ...[const SizedBox(height: 16), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// macOS sliding segmented control.
class Segmented<T extends Object> extends StatelessWidget {
  final Map<T, String> options;
  final T value;
  final ValueChanged<T> onChanged;

  const Segmented({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return CupertinoSlidingSegmentedControl<T>(
      groupValue: value,
      backgroundColor: p.selected,
      thumbColor: p.panel,
      padding: const EdgeInsets.all(2),
      onValueChanged: (v) {
        if (v != null) onChanged(v);
      },
      children: {
        for (final e in options.entries)
          e.key: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            child: Text(
              e.value,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: e.key == value ? FontWeight.w600 : FontWeight.w400,
                color: p.text,
                fontFamilyFallback: sansFallback,
              ),
            ),
          ),
      },
    );
  }
}

/// macOS form row: right-aligned label column, control on the right.
class FormRow extends StatelessWidget {
  final String label;
  final Widget child;
  final String? help;
  final double labelWidth;

  const FormRow({
    super.key,
    required this.label,
    required this.child,
    this.help,
    this.labelWidth = 96,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: labelWidth,
            child: Padding(
              padding: const EdgeInsets.only(top: 8, right: 12),
              child: Text(
                label,
                textAlign: TextAlign.right,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                child,
                if (help != null) ...[
                  const SizedBox(height: 4),
                  Text(help!, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Settings-style row inside a [Panel]: title (+ caption) left, control right.
class SettingRow extends StatelessWidget {
  final String title;
  final String? caption;
  final Widget control;

  const SettingRow({
    super.key,
    required this.title,
    this.caption,
    required this.control,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyMedium),
                if (caption != null) ...[
                  const SizedBox(height: 2),
                  Text(caption!, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          control,
        ],
      ),
    );
  }
}

/// Small macOS-style switch.
class MacSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const MacSwitch({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Transform.scale(
    scale: 0.72,
    child: CupertinoSwitch(
      value: value,
      activeTrackColor: Palette.of(context).text,
      onChanged: onChanged,
    ),
  );
}

/// Constrains page content to a readable width.
class ContentWidth extends StatelessWidget {
  final double maxWidth;
  final Widget child;

  const ContentWidth({super.key, this.maxWidth = 960, required this.child});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}

/// Pill-shaped count/label, e.g. 第 1 季 12/12.
class Tag extends StatelessWidget {
  final String text;
  final Color? color;

  const Tag(this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final c = color ?? p.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: c,
          fontFamilyFallback: sansFallback,
        ),
      ),
    );
  }
}

/// Dialog with a soft macOS sheet shadow. The sheet paints its own panel
/// colour so the shadow sits *under* it (a BoxShadow on an unfilled box would
/// tint the dialog grey).
class MacSheet extends StatelessWidget {
  final Widget child;

  const MacSheet({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: p.panel,
          borderRadius: BorderRadius.circular(Radii.xl),
          border: Border.all(color: p.line, width: hairline),
          boxShadow: floatShadow(1.2),
        ),
        child: child,
      ),
    );
  }
}

/// Fades in and rises a few pixels when first built. [index] staggers items
/// in a list (capped so long lists don't wait).
class FadeIn extends StatefulWidget {
  final Widget child;
  final int index;

  const FadeIn({super.key, required this.child, this.index = 0});

  @override
  State<FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<FadeIn> with SingleTickerProviderStateMixin {
  static const _step = 40, _base = 260, _maxSteps = 8;
  late final AnimationController _c;
  late final Animation<double> _a;

  @override
  void initState() {
    super.initState();
    final delay = _step * widget.index.clamp(0, _maxSteps);
    final total = _base + delay;
    _c = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: total),
    )..forward();
    _a = CurvedAnimation(
      parent: _c,
      curve: Interval(delay / total, 1, curve: Curves.easeOutCubic),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
      ? widget.child
      : FadeTransition(
          opacity: _a,
          child: AnimatedBuilder(
            animation: _a,
            builder: (_, c) => Transform.translate(
              offset: Offset(0, 8 * (1 - _a.value)),
              child: c,
            ),
            child: widget.child,
          ),
        );
}

/// Rounded progress bar with a flat fill that animates between values.
class GradientProgress extends StatelessWidget {
  final double value;
  final Color color;
  final double height;

  const GradientProgress({
    super.key,
    required this.value,
    required this.color,
    this.height = 6,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: Container(
        height: height,
        color: color.withValues(alpha: 0.12),
        alignment: Alignment.centerLeft,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: value.clamp(0.0, 1.0)),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          builder: (_, v, _) => FractionallySizedBox(
            widthFactor: v,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(height),
                color: color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A stable hue per season number so 第 1 季 / 第 2 季 read apart at a glance.
Color seasonColor(int season) {
  const hues = [
    Color(0xFF8A8780), // 0: specials, neutral
    Color(0xFFC96442),
    Color(0xFF3E7CB1),
    Color(0xFF5A9A5E),
    Color(0xFF8B5FBF),
    Color(0xFFC08A2B),
    Color(0xFF2F9A9A),
    Color(0xFFB8527A),
  ];
  if (season <= 0) return hues[0];
  return hues[1 + (season - 1) % (hues.length - 1)];
}

/// One entry of a right-click / ⋯ menu.
class MenuAction {
  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  final bool destructive;

  const MenuAction(
    this.label,
    this.onTap, {
    this.icon,
    this.destructive = false,
  });
}

/// Pops a native-looking menu at [position] (global). `null` items are dividers.
Future<void> showActionMenu(
  BuildContext context,
  Offset position,
  List<MenuAction?> items,
) async {
  final p = Palette.of(context);
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final local = overlay.globalToLocal(position);
  final picked = await showMenu<MenuAction>(
    context: context,
    position: RelativeRect.fromLTRB(
      local.dx,
      local.dy,
      overlay.size.width - local.dx,
      overlay.size.height - local.dy,
    ),
    items: [
      for (final a in items)
        if (a == null)
          const PopupMenuDivider(height: 9)
        else
          PopupMenuItem<MenuAction>(
            value: a,
            height: 30,
            child: Row(
              children: [
                if (a.icon != null) ...[
                  Icon(
                    a.icon,
                    size: 14,
                    color: a.destructive ? p.danger : p.textMuted,
                  ),
                  const SizedBox(width: 9),
                ],
                Text(
                  a.label,
                  style: TextStyle(color: a.destructive ? p.danger : null),
                ),
              ],
            ),
          ),
    ],
  );
  picked?.onTap();
}

/// Right-click (or two-finger click) on [child] opens [items].
class ContextMenuArea extends StatelessWidget {
  final Widget child;
  final List<MenuAction?> Function() items;

  const ContextMenuArea({super.key, required this.child, required this.items});

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onSecondaryTapUp: (d) => showActionMenu(context, d.globalPosition, items()),
    child: child,
  );
}

/// ⋯ button that opens the same menu as right-click.
class MoreButton extends StatelessWidget {
  final List<MenuAction?> Function() items;

  const MoreButton({super.key, required this.items});

  @override
  Widget build(BuildContext context) => Builder(
    builder: (context) => IconButton(
      tooltip: '更多',
      icon: const Icon(CupertinoIcons.ellipsis, size: 16),
      onPressed: () {
        final box = context.findRenderObject()! as RenderBox;
        showActionMenu(
          context,
          box.localToGlobal(box.size.bottomLeft(Offset.zero)),
          items(),
        );
      },
    ),
  );
}

class _RingsPainter extends CustomPainter {
  final Color color;

  const _RingsPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = color;
    final c = size.center(Offset.zero);
    for (var r = size.shortestSide / 2; r > 22; r -= 7) {
      canvas.drawCircle(c, r, paint);
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) => old.color != color;
}

/// Dashed ring meaning "working on it". Deliberately still: it reads as a
/// state, not a distraction (and keeps pumpAndSettle in tests finite).
class Spinner extends StatelessWidget {
  final double size;
  final Color? color;

  const Spinner({super.key, this.size = 14, this.color});

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _DashedRingPainter(color ?? Palette.of(context).textMuted),
    ),
  );
}

class _DashedRingPainter extends CustomPainter {
  final Color color;

  const _DashedRingPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    const dashes = 8;
    const sweep = 3.14159265 * 2 / dashes;
    final stroke = size.shortestSide / 9;
    final rect = (Offset.zero & size).deflate(stroke);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;
    for (var i = 0; i < dashes; i++) {
      canvas.drawArc(rect, i * sweep, sweep * 0.45, false, paint);
    }
  }

  @override
  bool shouldRepaint(_DashedRingPainter old) => old.color != color;
}

/// Hero number with a small unit and an optional caption block beside it:
/// `247 G  可用空间 / ◌ 正在扫描`.
class BigNumber extends StatelessWidget {
  final String value;
  final String? unit;
  final List<Widget> captions;
  final double? fontSize;

  const BigNumber(
    this.value, {
    super.key,
    this.unit,
    this.captions = const [],
    this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final big = Theme.of(context).textTheme.displayLarge!.copyWith(
      fontSize: fontSize,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(value, style: big),
        if (unit != null)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 2),
            child: Text(
              unit!,
              style: TextStyle(
                fontSize: (big.fontSize ?? TypeScale.display) * 0.34,
                fontWeight: FontWeight.w300,
                color: p.textMuted,
              ),
            ),
          ),
        if (captions.isNotEmpty) ...[
          const SizedBox(width: 18),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: DefaultTextStyle.merge(
                style: TextStyle(fontSize: 13, color: p.text, height: 1.6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: captions,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Underlined text action, for secondary actions inside prose
/// (立即检查, 在列表中显示).
class LinkText extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;

  const LinkText(this.text, {super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Hoverable(
      onTap: onTap,
      builder: (_, hover) => Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          color: hover ? p.text : p.textMuted,
          decoration: TextDecoration.underline,
          decorationColor: hover ? p.text : p.textFaint,
          decorationThickness: 1,
        ),
      ),
    );
  }
}

/// The app icon (assets/app_icon.png, drawn by tool/make_icon.py), cropped to
/// its tile: the macOS artwork keeps ~10% margin around it.
class AppLogo extends StatelessWidget {
  final double size;

  const AppLogo({super.key, this.size = 40});

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: OverflowBox(
        maxWidth: size * 1.24,
        maxHeight: size * 1.24,
        child: Image.asset(
          'assets/app_icon.png',
          width: size * 1.24,
          height: size * 1.24,
          filterQuality: FilterQuality.medium,
        ),
      ),
    ),
  );
}

/// One line of text that, while [active] and too long to fit, scrolls left to
/// show the rest, pauses, and comes back. Otherwise it's an ellipsized line.
class HoverMarquee extends StatefulWidget {
  final String text;
  final bool active;
  final TextStyle? style;

  const HoverMarquee({
    super.key,
    required this.text,
    required this.active,
    this.style,
  });

  @override
  State<HoverMarquee> createState() => _HoverMarqueeState();
}

class _HoverMarqueeState extends State<HoverMarquee> {
  final _scroll = ScrollController();
  var _run = 0;

  @override
  void didUpdateWidget(HoverMarquee old) {
    super.didUpdateWidget(old);
    if (widget.active != old.active) {
      _run++;
      if (widget.active) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _loop(_run));
      } else if (_scroll.hasClients) {
        _scroll.jumpTo(0);
      }
    }
  }

  Future<void> _loop(int run) async {
    while (mounted && run == _run && _scroll.hasClients) {
      final max = _scroll.position.maxScrollExtent;
      if (max <= 0) return;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!mounted || run != _run) return;
      await _scroll.animateTo(
        max,
        duration: Duration(milliseconds: (max * 28).round()),
        curve: Curves.linear,
      );
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (!mounted || run != _run) return;
      _scroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _run++;
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.active
      ? SingleChildScrollView(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          child: Text(widget.text, maxLines: 1, style: widget.style),
        )
      : Text(
          widget.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: widget.style,
        );
}
