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

  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.busy = false,
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
              Icon(icon, size: 40, color: p.textFaint),
              const SizedBox(height: 14),
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

/// Dialog with a soft macOS sheet shadow.
class MacSheet extends StatelessWidget {
  final Widget child;

  const MacSheet({super.key, required this.child});

  @override
  Widget build(BuildContext context) => Dialog(
    child: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.xl),
        boxShadow: floatShadow(1.6),
      ),
      child: child,
    ),
  );
}
