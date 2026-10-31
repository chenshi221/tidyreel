import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Minimal settable state holder: `NotifierProvider<Val<T>, T>(() => Val(x))`.
class Val<T> extends Notifier<T> {
  final T initial;

  Val(this.initial);

  @override
  T build() => initial;

  void set(T value) => state = value;
}

String fmtSize(int bytes) {
  if (bytes <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

String fmtDate(DateTime? d) => d == null
    ? ''
    : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Page frame: serif title (+ optional subtitle and actions) over the body.
/// Switches to standard visual density so every tap target is at least 40px
/// (the app theme is compact). With [maxWidth] the whole page is centered.
class PageScaffold extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;
  final Widget child;
  final double? maxWidth;

  const PageScaffold({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const [],
    this.maxWidth,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget page = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 12),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 8)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      key: const ValueKey('page-title'),
                      style: theme.textTheme.headlineSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: theme.textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              for (final a in actions) ...[const SizedBox(width: 8), a],
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
    if (maxWidth != null) {
      page = Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth!),
          child: page,
        ),
      );
    }
    return Theme(
      data: theme.copyWith(visualDensity: VisualDensity.standard),
      child: page,
    );
  }
}

/// TMDB poster, or an icon when there is none.
class Poster extends StatelessWidget {
  final String? posterPath;
  final IconData icon;
  final double width;
  final double height;

  const Poster({
    super.key,
    this.posterPath,
    this.icon = Icons.movie_outlined,
    this.width = 46,
    this.height = 69,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(icon, color: scheme.onSurfaceVariant),
    );
    if (posterPath == null) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        'https://image.tmdb.org/t/p/w185$posterPath',
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required Widget content,
  String confirmLabel = '确定',
  bool destructive = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: content,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error,
                  )
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ) ??
    false;

const warningColor = Color(0xFFB26A00);
