import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../../widgets/common.dart';

const videoExt = {
  'mkv',
  'mp4',
  'avi',
  'mov',
  'ts',
  'm2ts',
  'wmv',
  'flv',
  'rmvb',
  'webm',
  'iso',
};
const subtitleExt = {'ass', 'ssa', 'srt', 'sub', 'idx', 'vtt', 'sup'};

String _ext(String name) =>
    name.contains('.') ? name.split('.').last.toLowerCase() : '';

/// What a submit would pick up, from a bounded walk (so previewing a whole
/// drive stays quick). [truncated] means the numbers are a lower bound.
class ScanPreview {
  var dirs = 0, videos = 0, subtitles = 0, others = 0, bytes = 0;
  var truncated = false;

  /// Folders directly inside the selection: roughly one per work.
  final topDirs = <String>[];
}

/// Walks [paths] breadth-first, at most [maxDepth] levels below each and
/// [maxDirs] listings overall. A path whose name has a media extension is
/// counted as a file without listing it.
Future<ScanPreview> previewScan(
  StorageBackend backend,
  List<String> paths, {
  int maxDepth = 3,
  int maxDirs = 200,
  bool Function()? cancelled,
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

  final queue = <(String, int)>[];
  for (final p in paths) {
    final name = p.split('/').last;
    final e = _ext(name);
    if (videoExt.contains(e) || subtitleExt.contains(e)) {
      count(name, 0);
    } else {
      queue.add((p, 0));
    }
  }
  var listed = 0;
  while (queue.isNotEmpty) {
    if (cancelled?.call() ?? false) break;
    if (listed >= maxDirs) {
      r.truncated = true;
      break;
    }
    final (dir, depth) = queue.removeAt(0);
    listed++;
    final List<RemoteEntry> entries;
    try {
      entries = await backend.list(dir);
    } on StorageException {
      continue; // unreadable folder: the real scan will report it
    }
    for (final e in entries) {
      if (e.isDir) {
        r.dirs++;
        if (depth == 0) r.topDirs.add(e.name);
        if (depth + 1 < maxDepth) {
          queue.add((e.path, depth + 1));
        } else {
          r.truncated = true;
        }
      } else {
        count(e.name, e.size);
      }
    }
  }
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
/// user confirmed. [organizedCount] checks how many top folders were already
/// organized.
Future<bool> showScanPreview(
  BuildContext context, {
  required StorageBackend backend,
  required List<String> paths,
  Future<int> Function(List<String> dirs)? organizedCount,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _PreviewSheet(
        backend: backend,
        paths: paths,
        organizedCount: organizedCount,
      ),
    ) ??
    false;

class _PreviewSheet extends StatefulWidget {
  final StorageBackend backend;
  final List<String> paths;
  final Future<int> Function(List<String> dirs)? organizedCount;

  const _PreviewSheet({
    required this.backend,
    required this.paths,
    this.organizedCount,
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
    );
    var organized = 0;
    if (widget.organizedCount != null && !_closed) {
      final dirs = [
        for (final p in widget.paths)
          for (final d in r.topDirs) '$p/$d'.replaceAll('//', '/'),
      ];
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
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: p.text,
                  ),
                ),
                Text(label, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        );

    return MacSheet(
      child: SizedBox(
        width: 520,
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('提交前预览', style: theme.textTheme.titleLarge),
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
              const SizedBox(height: 16),
              if (r == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Column(
                    children: [
                      CupertinoActivityIndicator(),
                      SizedBox(height: 10),
                      Text('正在快速扫描…', style: TextStyle(fontSize: 12.5)),
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
                      p.accent,
                    ),
                    const SizedBox(width: 8),
                    stat(
                      CupertinoIcons.film,
                      '视频',
                      '${r.videos}',
                      seasonColor(2),
                    ),
                    const SizedBox(width: 8),
                    stat(
                      CupertinoIcons.captions_bubble,
                      '字幕',
                      '${r.subtitles}',
                      seasonColor(3),
                    ),
                    const SizedBox(width: 8),
                    stat(
                      CupertinoIcons.archivebox,
                      '大小',
                      fmtSize(r.bytes).isEmpty ? '—' : fmtSize(r.bytes),
                      seasonColor(4),
                    ),
                  ],
                ),
                if (r.topDirs.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    '包含：${r.topDirs.take(8).join('、')}'
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
                      borderRadius: BorderRadius.circular(Radii.md),
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
                            style: const TextStyle(fontSize: 12.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  '提交后只扫描和识别，不会改任何文件；在确认页点「执行」才会改名，执行后也能撤销。',
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
                    child: Text(warnings.isEmpty ? '提交为任务' : '仍然提交'),
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
