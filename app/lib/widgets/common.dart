import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import '../ui/tokens.dart';
import '../ui/widgets.dart';

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
  // Decimal units, as Finder shows them (macOS is the primary platform).
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

final _fuzzyStrip = RegExp(r'[^\p{L}\p{N}]', unicode: true);

/// Search-box matching that forgives case, spaces, dots and brackets: every
/// word of [query] appears in [text], or (3+ characters) its letters appear
/// in order ("卫宫饭" finds "卫宫家今天的饭", "akujodewa" finds "Akujo de wa").
bool fuzzyMatch(String query, String text) {
  String norm(String s) => s.toLowerCase().replaceAll(_fuzzyStrip, '');
  final t = norm(text);
  final words = query
      .split(RegExp(r'\s+'))
      .map(norm)
      .where((w) => w.isNotEmpty);
  if (words.isEmpty || words.every(t.contains)) return true;
  final q = norm(query).runes.toList();
  if (q.length < 3) return false;
  var i = 0;
  for (final c in t.runes) {
    if (i < q.length && c == q[i]) i++;
  }
  return i == q.length;
}

String fmtDate(DateTime? d) => d == null
    ? ''
    : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Last path segment, or [empty] for root / empty paths.
String pathBasename(String path, {String empty = '根目录'}) {
  final trimmed = path.replaceAll(RegExp(r'[/\\]+$'), '');
  if (trimmed.isEmpty) return empty;
  final i = trimmed.lastIndexOf(RegExp(r'[/\\]'));
  final name = i < 0 ? trimmed : trimmed.substring(i + 1);
  return name.isEmpty ? empty : name;
}

/// True in the real macOS app (not tests): the native title bar is hidden and
/// page headers double as the window's drag area.
bool get isMacDesktop => !kIsWeb && Platform.isMacOS;

/// Page frame: bold title (+ optional subtitle, leading and actions) over the
/// body. On macOS the header is the window's drag area. With [maxWidth] the
/// whole page is constrained to that width and aligned top-left.
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
      padding: EdgeInsets.fromLTRB(leading == null ? 48 : 34, 30, 40, 18),
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
                  style: theme.textTheme.displaySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 6),
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
        alignment: Alignment.topLeft,
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
/// Pass [baseUrl] to override the image host (e.g. a reverse proxy).
String tmdbImage(String path, [String size = 'w185', String? baseUrl]) {
  final base =
      (baseUrl == null || baseUrl.trim().isEmpty
              ? 'https://image.tmdb.org/t/p'
              : baseUrl.trim())
          .replaceAll(RegExp(r'/+$'), '');
  return '$base/$size$path';
}

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
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: posterPath == null
            ? placeholder
            : Image(
                image: CachedImage(tmdbImage(posterPath!, size)),
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
      builder: (ctx) => MacSheet(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 320, maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: 10),
                DefaultTextStyle.merge(
                  style: Theme.of(ctx).textTheme.bodyMedium,
                  child: content,
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    // Destructive: a red word, not a red slab.
                    destructive
                        ? OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Theme.of(ctx).colorScheme.error,
                            ),
                            onPressed: () => Navigator.pop(ctx, true),
                            child: Text(confirmLabel),
                          )
                        : FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: Text(confirmLabel),
                          ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ) ??
    false;

/// The one confirmation before running: deleting files can't be undone.
Future<bool> confirmPermanentDelete(
  BuildContext context,
  int count, {
  List<String> paths = const [],
}) {
  const maxShown = 50;
  final shown = paths.take(maxShown).toList();
  final more = paths.length - shown.length;
  return confirmDialog(
    context,
    title: '永久删除 $count 个文件？',
    content: Builder(
      builder: (ctx) {
        final p = Palette.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('这些是广告和垃圾文件，删除后无法撤销。改名和移动仍可在任务页撤销。'),
            if (shown.isNotEmpty) ...[
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: Panel(
                  framed: true,
                  color: p.sidebar,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final path in shown)
                          Tooltip(
                            message: path,
                            waitDuration: const Duration(milliseconds: 500),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Text(
                                pathBasename(path, empty: path),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: TypeScale.small,
                                  color: p.textMuted,
                                ),
                              ),
                            ),
                          ),
                        if (more > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '+$more 个更多文件',
                              style: TextStyle(
                                fontSize: TypeScale.small,
                                color: p.textFaint,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    ),
    confirmLabel: '删除并整理',
    destructive: true,
  );
}

/// A network image also kept on disk (app cache dir), so posters show at once
/// after a restart instead of downloading again. TMDB image URLs never change.
class CachedImage extends ImageProvider<CachedImage> {
  final String url;

  const CachedImage(this.url);

  static Future<Directory>? _dir;
  static var _tmpSeq = 0;
  static final _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  /// Removes all cached TMDB images from disk.
  static Future<void> clearDiskCache() async {
    try {
      final dir =
          await (_dir ??
              getApplicationCacheDirectory().then(
                (d) => Directory('${d.path}/tmdb_images'),
              ));
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } on Object {
      // Ignore cache cleanup errors (e.g. missing path_provider in tests).
    } finally {
      _dir = null;
    }
  }

  @override
  Future<CachedImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    CachedImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final dir = await (_dir ??= getApplicationCacheDirectory().then(
      (d) => Directory('${d.path}/tmdb_images').create(recursive: true),
    ));
    final file = File(
      '${dir.path}/${url.replaceAll(RegExp(r'[^A-Za-z0-9.]+'), '_')}',
    );
    Uint8List bytes;
    if (await file.exists()) {
      bytes = await file.readAsBytes();
    } else {
      final res = await (await _http.getUrl(Uri.parse(url))).close();
      if (res.statusCode != HttpStatus.ok) {
        throw NetworkImageLoadException(
          statusCode: res.statusCode,
          uri: Uri.parse(url),
        );
      }
      bytes = await consolidateHttpClientResponseBytes(res);
      // Unique temp file then rename: concurrent loads never collide and a
      // crash mid-write never leaves a broken image.
      final tmp = File(
        '${file.path}.${DateTime.now().microsecondsSinceEpoch}.${_tmpSeq++}.part',
      );
      try {
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(file.path);
      } catch (_) {
        if (await tmp.exists()) {
          try {
            await tmp.delete();
          } on Object {
            // Ignore cleanup failure.
          }
        }
        rethrow;
      }
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) => other is CachedImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
