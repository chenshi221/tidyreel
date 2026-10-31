import 'package:flutter/material.dart';

import 'tokens.dart';

/// Bordered container that groups rows (replaces shadowed cards).
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
        border: Border.all(color: p.line),
      ),
      padding: padding,
      child: child,
    );
  }
}

/// Children separated by hairlines, for use inside a [Panel].
class Rows extends StatelessWidget {
  final List<Widget> children;

  const Rows({super.key, required this.children});

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const Divider(),
        children[i],
      ],
    ],
  );
}

/// A row that tints on hover. [trailing] is always shown; [hoverTrailing] only
/// while the pointer is over the row (and always when [selected]).
class HoverRow extends StatefulWidget {
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
    this.padding = const EdgeInsets.symmetric(
      horizontal: Space.lg,
      vertical: Space.md,
    ),
    this.borderRadius,
  });

  @override
  State<HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<HoverRow> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final theme = Theme.of(context);
    final w = widget;
    final bg = w.selected
        ? p.selected
        : (_hover && w.onTap != null ? p.hover : Colors.transparent);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: w.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: w.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          decoration: BoxDecoration(color: bg, borderRadius: w.borderRadius),
          padding: w.padding,
          child: Row(
            children: [
              if (w.leading != null) ...[
                w.leading!,
                const SizedBox(width: Space.md),
              ],
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
                      child: w.title,
                    ),
                    if (w.subtitle != null) ...[
                      const SizedBox(height: 2),
                      DefaultTextStyle.merge(
                        style: theme.textTheme.bodySmall,
                        child: w.subtitle!,
                      ),
                    ],
                  ],
                ),
              ),
              if (w.hoverTrailing != null)
                Visibility.maintain(
                  visible: _hover || w.selected,
                  child: w.hoverTrailing!,
                ),
              if (w.trailing != null) ...[
                const SizedBox(width: Space.sm),
                w.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Small rounded square holding an icon (connection type, file kind…).
class IconTile extends StatelessWidget {
  final IconData icon;
  final double size;
  final Color? color;
  final Color? background;

  const IconTile(
    this.icon, {
    super.key,
    this.size = 32,
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
        color: background ?? p.hover,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Icon(icon, size: size * 0.55, color: color ?? p.textMuted),
    );
  }
}

/// Dot + label, e.g. 已连接 / 认证失败.
class StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final bool busy;

  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (busy)
        SizedBox(
          width: 10,
          height: 10,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
        )
      else
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      const SizedBox(width: 6),
      Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
        ),
      ),
    ],
  );
}

/// Small uppercase-ish heading above a panel.
class SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const SectionLabel(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(2, Space.xl, 2, Space.sm),
    child: Row(
      children: [
        Text(text, style: Theme.of(context).textTheme.titleSmall),
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
        padding: const EdgeInsets.all(Space.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconTile(icon, size: 48, color: p.accent, background: p.accentSoft),
            const SizedBox(height: Space.lg),
            Text(title, style: theme.textTheme.titleMedium),
            if (message != null) ...[
              const SizedBox(height: Space.xs),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (action != null) ...[const SizedBox(height: Space.lg), action!],
          ],
        ),
      ),
    );
  }
}

/// Constrains page content to a readable width, left-aligned with the title.
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
