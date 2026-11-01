import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'tokens.dart';

/// Inset-grouped container: white, hairline border, barely-there shadow.
class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;

  const Panel({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: color ?? p.panel,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: p.line, width: hairline),
        boxShadow: panelShadow(),
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
              ? p.accent.withValues(alpha: 0.10)
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
        color: background ?? p.sidebar,
        borderRadius: BorderRadius.circular(size * 0.24),
        border: Border.all(color: p.line, width: hairline),
      ),
      child: Icon(icon, size: size * 0.52, color: color ?? p.textMuted),
    );
  }
}

/// Dot + label, e.g. 已连接 / 认证失败.
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
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (busy)
          SizedBox(
            width: 8,
            height: 8,
            child: CircularProgressIndicator(strokeWidth: 1.4, color: color),
          )
        else if (icon != null)
          Icon(icon, size: 11, color: color)
        else
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
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
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      p.accent.withValues(alpha: 0.22),
                      p.accent.withValues(alpha: 0.04),
                    ],
                  ),
                  border: Border.all(
                    color: p.accent.withValues(alpha: 0.25),
                    width: hairline,
                  ),
                ),
                child: Icon(icon, size: 32, color: p.accent),
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
      activeTrackColor: Palette.of(context).accent,
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
          fontWeight: FontWeight.w600,
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

/// Thick rounded progress bar with a gradient fill that animates between
/// values.
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
    final hsl = HSLColor.fromColor(color);
    final light = hsl
        .withLightness((hsl.lightness + 0.14).clamp(0.0, 1.0))
        .toColor();
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: Container(
        height: height,
        color: color.withValues(alpha: 0.14),
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
                gradient: LinearGradient(colors: [light, color]),
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
