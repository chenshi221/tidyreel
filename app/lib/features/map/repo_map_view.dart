import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../../widgets/common.dart';
import 'map_providers.dart';
import 'organic_map.dart';
import 'size_scanner.dart';

/// More blocks than this can't be laid out smoothly: the smallest go into
/// 「其余 N 项」.
const _maxBlocks = 150;
const restId = '__rest__';

String _blockTooltip(String name, FolderStats st) {
  final size = fmtSize(st.total);
  final header = size.isEmpty ? name : '$name · $size';
  final String progress;
  if (st.video == 0) {
    progress = '非视频文件';
  } else if (st.unorganized == 0) {
    progress = '全部已整理';
  } else if (st.organized == 0) {
    progress = '全部未整理';
  } else {
    final pct = (st.organized * 100 / st.video).round().clamp(1, 99);
    progress = '已整理 $pct% · 未整理 ${fmtSize(st.unorganized)}';
  }
  return '$header\n$progress\n共 ${st.files} 个文件';
}

/// Folder [dir] as blocks: one per child, area = recursive size, tone =
/// organize state; only past [_maxBlocks] does the tail fold into 「其余」.
List<MapBlock> mapBlocksFor(SizeScanner s, String dir) {
  final entries = s.entriesOf(dir);
  final stats = [for (final e in entries) (e, s.statsOf(e))]
    ..removeWhere((x) => x.$2.total <= 0)
    ..sort((a, b) => b.$2.total.compareTo(a.$2.total));
  final keep = <MapBlock>[];
  var rest = FolderStats.zero;
  var restCount = 0;
  for (final (e, st) in stats) {
    if (keep.length < _maxBlocks) {
      keep.add(
        MapBlock(
          id: e.path,
          label: e.name,
          bytes: st.total,
          state: blockStateOf(st),
          caption: fmtSize(st.total),
          tooltip: _blockTooltip(e.name, st),
        ),
      );
    } else {
      rest += st;
      restCount++;
    }
  }
  if (restCount > 0) {
    final restLabel = '其余 $restCount 项';
    keep.add(
      MapBlock(
        id: restId,
        label: restLabel,
        bytes: rest.total,
        state: blockStateOf(rest),
        caption: fmtSize(rest.total),
        tooltip: _blockTooltip(restLabel, rest),
      ),
    );
  }
  return keep;
}

/// 地图 mode of the file browser: the size map of the open folder.
class RepoMapView extends ConsumerStatefulWidget {
  final ConnectionId connection;
  final String dir;
  final void Function(String dir) onOpen;

  /// Right-click menu for a block's entry (same as the list's).
  final List<MenuAction?> Function(RemoteEntry) menuFor;

  /// 「其余 N 项」 was clicked: show the list instead.
  final VoidCallback onShowList;

  /// Selected paths, shared with the list.
  final Set<String> selected;
  final void Function(String path) onToggleSelect;

  const RepoMapView({
    super.key,
    required this.connection,
    required this.dir,
    required this.onOpen,
    required this.menuFor,
    required this.onShowList,
    this.selected = const {},
    required this.onToggleSelect,
  });

  @override
  ConsumerState<RepoMapView> createState() => _RepoMapViewState();
}

class _RepoMapViewState extends ConsumerState<RepoMapView> {
  SizeScanner? _scanner;
  Timer? _throttle;
  var _dirty = false;

  SizeScanner get _s => ref.read(sizeScannerProvider(widget.connection));

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(RepoMapView old) {
    super.didUpdateWidget(old);
    if (old.connection != widget.connection) _attach();
    if (old.dir != widget.dir) _start();
  }

  void _attach() {
    _scanner?.removeListener(_changed);
    _scanner = _s..addListener(_changed);
    _start();
  }

  /// Counts [RepoMapView.dir] unless a count above it is already running.
  void _start() {
    final s = _s;
    final dir = widget.dir;
    final r = s.running;
    final covered =
        r != null && (r == '/' || r == dir || dir.startsWith('$r/'));
    if (!covered && !s.isComplete(dir)) unawaited(s.scan(dir));
  }

  /// Repaints at most every 250 ms while a count streams in.
  void _changed() {
    final s = _scanner;
    if (s != null &&
        !s.isListed(widget.dir) &&
        s.running == null &&
        s.error == null) {
      _start();
    }
    if (_throttle != null) {
      _dirty = true;
      return;
    }
    if (mounted) setState(() {});
    _throttle = Timer(const Duration(milliseconds: 250), () {
      _throttle = null;
      if (_dirty && mounted) {
        _dirty = false;
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _throttle?.cancel();
    _scanner?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final s = ref.watch(sizeScannerProvider(widget.connection));
    if (!identical(s, _scanner)) {
      _scanner?.removeListener(_changed);
      _scanner = s..addListener(_changed);
      _start();
    }
    final dir = widget.dir;
    final blocks = mapBlocksFor(s, dir);
    final busy = s.running != null;
    final entries = s.entriesOf(dir);
    final byPath = {for (final e in entries) e.path: e};
    final unorganizedPaths = <String>[
      for (final e in entries)
        if (switch (blockStateOf(s.statsOf(e))) {
          BlockState.unorganized || BlockState.mixed => true,
          BlockState.organized || BlockState.other => false,
        })
          e.path,
    ];
    final allUnorganizedSelected =
        unorganizedPaths.isNotEmpty &&
        unorganizedPaths.every(widget.selected.contains);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: RepoMapSummary(scanner: s, dir: dir),
              ),
              if (unorganizedPaths.isNotEmpty) ...[
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  key: const ValueKey('map-select-unorganized'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    textStyle: const TextStyle(fontSize: TypeScale.small),
                  ),
                  onPressed: () {
                    if (allUnorganizedSelected) {
                      for (final path in unorganizedPaths) {
                        if (widget.selected.contains(path)) {
                          widget.onToggleSelect(path);
                        }
                      }
                    } else {
                      for (final path in unorganizedPaths) {
                        if (!widget.selected.contains(path)) {
                          widget.onToggleSelect(path);
                        }
                      }
                    }
                  },
                  icon: Icon(
                    allUnorganizedSelected
                        ? CupertinoIcons.checkmark_square_fill
                        : CupertinoIcons.checkmark_square,
                    size: 13,
                  ),
                  label: Text(
                    allUnorganizedSelected
                        ? '取消选中未整理'
                        : '选中未整理 (${unorganizedPaths.length})',
                  ),
                ),
                const SizedBox(width: 14),
              ],
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const MapLegend(),
                  Text(
                    '点击进入 · ⌘/⇧ 点选多选 · 右键更多',
                    style: TextStyle(
                      fontSize: TypeScale.small,
                      color: p.textFaint,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: blocks.isEmpty
              ? (!busy && s.error != null
                    ? EmptyState(
                        icon: CupertinoIcons.exclamationmark_triangle,
                        title: '这里统计不了', // the summary says why
                        action: OutlinedButton(
                          onPressed: () => unawaited(s.scan(dir, fresh: true)),
                          child: const Text('重试'),
                        ),
                      )
                    : busy || !s.isListed(dir)
                    ? const Center(child: Spinner(size: 22))
                    : EmptyState(
                        icon: CupertinoIcons.folder,
                        title: '这里没有文件',
                        action: OutlinedButton(
                          onPressed: widget.onShowList,
                          child: const Text('切回列表视图'),
                        ),
                      ))
              : AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  child: OrganicMap(
                    key: ValueKey(dir),
                    blocks: blocks,
                    selected: widget.selected,
                    counting: busy,
                    onTap: (b) {
                      if (b.id == restId) return widget.onShowList();
                      final e = byPath[b.id];
                      if (e == null) return;
                      final k = HardwareKeyboard.instance;
                      final adding =
                          k.isMetaPressed ||
                          k.isControlPressed ||
                          k.isShiftPressed;
                      if (e.isDir && !adding) {
                        widget.onOpen(e.path);
                      } else {
                        widget.onToggleSelect(e.path);
                      }
                    },
                    onSecondaryTap: (b, at) {
                      final e = byPath[b.id];
                      if (e != null) {
                        showActionMenu(context, at, widget.menuFor(e));
                      }
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

String scanErrorText(Object e) =>
    e is StorageException && e.code == StorageErrorCode.notFound
    ? '统计出错：找不到这个文件夹，可能已被移动或删除'
    : '统计出错：${e is StorageException ? e.message : e}';

/// Big size number with file count, 未整理 total and count progress.
class RepoMapSummary extends StatelessWidget {
  final SizeScanner scanner;
  final String dir;

  const RepoMapSummary({super.key, required this.scanner, required this.dir});

  Future<void> _showSkipped(BuildContext context) {
    final entries = scanner.skipped.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return showDialog<void>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final p = Palette.of(ctx);
        return MacSheet(
          child: SizedBox(
            width: 520,
            height: 400,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '跳过 ${entries.length} 个读不了的文件夹',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Panel(
                      framed: true,
                      child: ListView.separated(
                        padding: const EdgeInsets.all(8),
                        itemCount: entries.length,
                        separatorBuilder: (_, _) => const Divider(),
                        itemBuilder: (_, i) {
                          final e = entries[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 6,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SelectableText(
                                  e.key,
                                  style: TextStyle(
                                    fontSize: TypeScale.small,
                                    fontWeight: FontWeight.w500,
                                    color: p.text,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                SelectableText(
                                  e.value,
                                  style: TextStyle(
                                    fontSize: TypeScale.small,
                                    color: p.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final s = scanner;
    final stats = s.statsOfDir(dir);
    final size = fmtSize(stats.total);
    final (value, unit) = size.isEmpty
        ? ('0', null)
        : (size.split(' ').first, size.split(' ').last);
    final status = s.running != null
        ? Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Spinner(size: 13),
              Text('正在统计，已读 ${s.dirsListed} 个文件夹'),
              LinkText('停止', onTap: s.cancel),
            ],
          )
        : s.error != null
        ? Wrap(
            spacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Tooltip(
                message: '${s.error}',
                child: Text(
                  scanErrorText(s.error!),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.danger),
                ),
              ),
              LinkText('重试', onTap: () => unawaited(s.scan(dir, fresh: true))),
            ],
          )
        : s.isComplete(dir)
        ? Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                [
                  '${stats.files} 个文件',
                  if (stats.unorganized > 0)
                    '未整理 ${fmtSize(stats.unorganized)}',
                ].join('，'),
                style: TextStyle(color: p.textMuted),
              ),
              if (s.skipped.isNotEmpty)
                LinkText(
                  '跳过 ${s.skipped.length} 个读不了的文件夹',
                  onTap: () => _showSkipped(context),
                ),
            ],
          )
        : Wrap(
            spacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('已停止，结果不完整', style: TextStyle(color: p.textMuted)),
              LinkText('继续统计', onTap: () => unawaited(s.scan(dir))),
            ],
          );
    return BigNumber(value, unit: unit, captions: [status]);
  }
}

/// 未整理 / 部分整理 / 已整理 / 非视频 swatches.
class MapLegend extends StatelessWidget {
  const MapLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget item(BlockState st, String label) {
      final fill = blockFill(st, p, dark: dark);
      return Padding(
        padding: const EdgeInsets.only(left: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(4),
                border: fill == null
                    ? Border.all(color: p.text.withValues(alpha: 0.6))
                    : null,
              ),
              child: fill == null
                  ? Center(
                      child: Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(1.5),
                          border: Border.all(
                            color: p.text.withValues(alpha: 0.6),
                            width: 0.8,
                          ),
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12, color: p.textMuted)),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          item(BlockState.unorganized, '未整理'),
          item(BlockState.mixed, '部分整理'),
          item(BlockState.organized, '已整理'),
          item(BlockState.other, '非视频'),
        ],
      ),
    );
  }
}
