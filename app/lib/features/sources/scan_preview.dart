import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/settings.dart' show mediaHintLabels;
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../../widgets/common.dart';

const videoExt = videoExtensions;
const subtitleExt = subtitleExtensions;

String _ext(String name) =>
    name.contains('.') ? name.split('.').last.toLowerCase() : '';

/// What a submit would pick up, from a bounded walk (so previewing a whole
/// drive stays quick). [truncated] means the numbers are a lower bound.
class ScanPreview {
  var dirs = 0, videos = 0, subtitles = 0, others = 0, bytes = 0;
  var truncated = false;

  /// Full paths of folders directly inside the selection: roughly one per work.
  final topDirs = <String>[];
}

/// Walks [paths] a few folders at a time, at most [maxDepth] levels below each and
/// [maxDirs] listings overall. Paths present in [fileSizes] or whose names have
/// a media extension are counted as files without listing them.
Future<ScanPreview> previewScan(
  StorageBackend backend,
  List<String> paths, {
  int maxDepth = 3,
  int maxDirs = 200,
  bool Function()? cancelled,
  Map<String, int> fileSizes = const {},
}) async {
  final r = ScanPreview();
  void count(String name, int size) {
    final e = _ext(name);
    if (videoExt.contains(e)) {
      r.videos++;
    } else if (subtitleExt.contains(e)) {
      r.subtitles++;
    } else {
      r.others++;
    }
    r.bytes += size;
  }

  final depth = <String, int>{};
  for (final p in paths) {
    final name = p.split('/').last;
    final e = _ext(name);
    if (fileSizes.containsKey(p) ||
        videoExt.contains(e) ||
        subtitleExt.contains(e)) {
      count(name, fileSizes[p] ?? 0);
    } else {
      depth[p] = 0;
    }
  }
  var listed = 0;
  await walkDirs(depth.keys.toList(), (dir) async {
    if (listed >= maxDirs) {
      r.truncated = true;
      return const [];
    }
    listed++;
    final d = depth[dir]!;
    final List<RemoteEntry> entries;
    try {
      entries = await backend.list(dir);
    } on StorageException {
      return const []; // unreadable folder: the real scan will report it
    }
    final subs = <String>[];
    for (final e in entries) {
      if (e.isDir) {
        r.dirs++;
        if (d == 0) r.topDirs.add(e.path);
        if (d + 1 < maxDepth) {
          depth[e.path] = d + 1;
          subs.add(e.path);
        } else {
          r.truncated = true;
        }
      } else {
        count(e.name, e.size);
      }
    }
    return subs;
  }, stop: cancelled);
  r.topDirs.sort();
  return r;
}

/// Warnings worth a second look before submitting.
List<String> previewWarnings(
  List<String> paths,
  ScanPreview r, {
  int organized = 0,
}) => [
  if (paths.any((p) => p.split('/').where((s) => s.isNotEmpty).length <= 1))
    '选中的是根目录或一级目录，里面可能混着很多不相关的内容',
  if (r.videos >= 300) '视频${r.truncated ? '至少' : ''}有 ${r.videos} 个，识别和确认会比较久',
  if (r.topDirs.length > 30) '包含 ${r.topDirs.length} 个文件夹，可能是很多部作品',
  if (organized > 0) '其中 $organized 个文件夹已经整理过',
  if (r.videos == 0 && !r.truncated) '没有找到视频文件',
];

/// Scans [paths], shows the counts and warnings, and returns whether the
/// user confirmed. [organizedCount] checks how many selected/top folders were
/// already organized.
Future<bool> showScanPreview(
  BuildContext context, {
  required StorageBackend backend,
  required List<String> paths,
  Future<int> Function(List<String> dirs)? organizedCount,
  Map<String, int> fileSizes = const {},
  OrganizeMode? mode,
  bool scrape = false,
  bool scrapeOnly = false,
  MediaHint? mediaHint,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _PreviewSheet(
        backend: backend,
        paths: paths,
        organizedCount: organizedCount,
        fileSizes: fileSizes,
        mode: mode,
        scrape: scrape,
        scrapeOnly: scrapeOnly,
        mediaHint: mediaHint,
      ),
    ) ??
    false;

class _PreviewSheet extends StatefulWidget {
  final StorageBackend backend;
  final List<String> paths;
  final Future<int> Function(List<String> dirs)? organizedCount;
  final Map<String, int> fileSizes;
  final OrganizeMode? mode;
  final bool scrape;
  final bool scrapeOnly;
  final MediaHint? mediaHint;

  const _PreviewSheet({
    required this.backend,
    required this.paths,
    this.organizedCount,
    this.fileSizes = const {},
    this.mode,
    this.scrape = false,
    this.scrapeOnly = false,
    this.mediaHint,
  });

  @override
  State<_PreviewSheet> createState() => _PreviewSheetState();
}

class _PreviewSheetState extends State<_PreviewSheet> {
  ScanPreview? _r;
  var _organized = 0;
  var _closed = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }

  Future<void> _run() async {
    final r = await previewScan(
      widget.backend,
      widget.paths,
      cancelled: () => _closed,
      fileSizes: widget.fileSizes,
    );
    var organized = 0;
    if (widget.organizedCount != null && !_closed) {
      final dirs = {...widget.paths, ...r.topDirs}.toList();
      organized = await widget.organizedCount!(dirs.take(100).toList());
    }
    if (mounted) {
      setState(() {
        _r = r;
        _organized = organized;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final theme = Theme.of(context);
    final r = _r;
    final atLeast = r?.truncated ?? false ? '≥ ' : '';
    final warnings = r == null
        ? const <String>[]
        : previewWarnings(widget.paths, r, organized: _organized);

    Widget stat(IconData icon, String label, String value, Color color) =>
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(Radii.lg),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(height: 6),
                Text(
                  '$atLeast$value',
                  style: TextStyle(
                    fontSize: TypeScale.headline,
                    fontWeight: FontWeight.w700,
                    color: p.text,
                  ),
                ),
                Text(label, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        );

    final topNames = r == null
        ? const <String>[]
        : [
            for (final d in r.topDirs.take(8))
              d.split('/').where((s) => s.isNotEmpty).lastOrNull ?? d,
          ];

    return MacSheet(
      child: SizedBox(
        width: 520,
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('识别前预览', style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                widget.paths.length == 1
                    ? widget.paths.single
                    : '${widget.paths.length} 项：${widget.paths.take(3).join('、')}'
                          '${widget.paths.length > 3 ? ' …' : ''}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
              if (widget.mode != null ||
                  widget.scrape ||
                  widget.scrapeOnly ||
                  widget.mediaHint != null) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (widget.scrapeOnly)
                      Tag('仅刮削', color: p.accent)
                    else ...[
                      if (widget.mode != null)
                        Tag(
                          widget.mode == OrganizeMode.inPlace
                              ? '原地整理'
                              : '移动到媒体库',
                        ),
                      if (widget.scrape) Tag('刮削', color: p.accent),
                    ],
                    if (widget.mediaHint != null)
                      Tag('类型：${mediaHintLabels[widget.mediaHint]}'),
                  ],
                ),
              ],
              if (widget.scrapeOnly) ...[
                const SizedBox(height: 10),
                Container(
                  key: const ValueKey('scrape-only-note'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: p.accentSoft,
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                  child: Row(
                    children: [
                      Icon(CupertinoIcons.sparkles, size: 13, color: p.accent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '仅刮削模式：不移动、不重命名文件，仅在原位补全 NFO 与海报',
                          style: TextStyle(
                            fontSize: TypeScale.small,
                            color: p.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (r == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Column(
                    children: [
                      Spinner(size: 18),
                      SizedBox(height: 10),
                      Text(
                        '正在快速扫描…',
                        style: TextStyle(fontSize: TypeScale.small),
                      ),
                    ],
                  ),
                )
              else ...[
                Row(
                  children: [
                    stat(
                      CupertinoIcons.folder_fill,
                      '文件夹',
                      '${r.dirs}',
                      p.textMuted,
                    ),
                    const SizedBox(width: 8),
                    stat(CupertinoIcons.film, '视频', '${r.videos}', p.textMuted),
                    const SizedBox(width: 8),
                    stat(
                      CupertinoIcons.captions_bubble,
                      '字幕',
                      '${r.subtitles}',
                      p.textMuted,
                    ),
                    const SizedBox(width: 8),
                    stat(
                      CupertinoIcons.archivebox,
                      '大小',
                      fmtSize(r.bytes).isEmpty ? '—' : fmtSize(r.bytes),
                      p.textMuted,
                    ),
                  ],
                ),
                if (r.topDirs.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    '包含：${topNames.join('、')}'
                    '${r.topDirs.length > 8 ? ' 等 ${r.topDirs.length} 个' : ''}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                for (final w in warnings) ...[
                  const SizedBox(height: 8),
                  Container(
                    key: const ValueKey('preview-warning'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: p.warning.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(Radii.sm),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          CupertinoIcons.exclamationmark_triangle_fill,
                          size: 13,
                          color: p.warning,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            w,
                            style: const TextStyle(fontSize: TypeScale.small),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  widget.scrapeOnly
                      ? '这一步只识别，确认结果后才会写入 NFO 与海报，且不会修改任何现有文件名。'
                      : '这一步只识别，不改任何文件。确认结果后点「开始整理」才会改名，之后也能撤销。',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('preview-submit'),
                    onPressed: r == null
                        ? null
                        : () => Navigator.pop(context, true),
                    child: Text(warnings.isEmpty ? '开始识别' : '仍然开始'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
