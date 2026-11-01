import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../ui/tokens.dart';

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

/// True in the real macOS app (not tests): the native title bar is hidden and
/// page headers double as the window's drag area.
bool get isMacDesktop => !kIsWeb && Platform.isMacOS;

/// Page frame: bold title (+ optional subtitle, leading and actions) over the
/// body. On macOS the header is the window's drag area. With [maxWidth] the
/// whole page is centered.
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
    Widget header = Padding(
      padding: const EdgeInsets.fromLTRB(28, 22, 24, 10),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 6)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  key: const ValueKey('page-title'),
                  style: theme.textTheme.headlineSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          for (final a in actions) ...[const SizedBox(width: 6), a],
        ],
      ),
    );
    // Not DragToMoveArea: its double-tap handler holds every click on the
    // header's buttons for the double-tap timeout (and never resolves in tests).
    if (isMacDesktop) {
      header = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (_) => windowManager.startDragging(),
        child: header,
      );
    }
    Widget page = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
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
    return page;
  }
}

/// TMDB image URL; [size] is a TMDB size bucket (w92, w185, w342, w780, original).
String tmdbImage(String path, [String size = 'w185']) =>
    'https://image.tmdb.org/t/p/$size$path';

/// TMDB poster (2:3) with a hairline border and soft shadow, or an icon when
/// there is none. Picks the image size from the rendered width.
class Poster extends StatelessWidget {
  final String? posterPath;
  final IconData icon;
  final double width;
  final double height;
  final double radius;

  const Poster({
    super.key,
    this.posterPath,
    this.icon = CupertinoIcons.film,
    this.width = 46,
    this.height = 69,
    this.radius = 6,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final placeholder = Container(
      width: width,
      height: height,
      color: p.sidebar,
      child: Icon(icon, color: p.textFaint, size: width * 0.4),
    );
    final size = width <= 60 ? 'w92' : (width <= 120 ? 'w185' : 'w342');
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: p.line, width: hairline),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: width > 80 ? 14 : 4,
            offset: Offset(0, width > 80 ? 5 : 1),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: posterPath == null
            ? placeholder
            : Image.network(
                tmdbImage(posterPath!, size),
                width: width,
                height: height,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder,
                frameBuilder: (_, child, frame, sync) => sync
                    ? child
                    : AnimatedOpacity(
                        opacity: frame == null ? 0 : 1,
                        duration: const Duration(milliseconds: 220),
                        child: frame == null ? placeholder : child,
                      ),
              ),
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

const warningColor = Color(0xFFB7791F);
