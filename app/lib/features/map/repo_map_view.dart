import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../../widgets/common.dart';
import 'map_providers.dart';
import 'organic_map.dart';
import 'size_scanner.dart';

/// Blocks smaller than this share of the folder go into 「其余 N 项」.
const _minShare = 0.012;
const _maxBlocks = 36;
const restId = '__rest__';

/// Folder [dir] as blocks: one per child, area = recursive size, tone =
/// organize state; the long tail folds into one 「其余」 block.
List<MapBlock> mapBlocksFor(SizeScanner s, String dir) {
  final entries = s.entriesOf(dir);
  final stats = [for (final e in entries) (e, s.statsOf(e))]
    ..removeWhere((x) => x.$2.total <= 0)
    ..sort((a, b) => b.$2.total.compareTo(a.$2.total));
  final total = stats.fold(0, (t, x) => t + x.$2.total);
  final keep = <MapBlock>[];
  var rest = FolderStats.zero;
  var restCount = 0;
  for (final (e, st) in stats) {
    if (keep.length < _maxBlocks && st.total >= total * _minShare) {
      keep.add(
        MapBlock(
          id: e.path,
          label: e.name,
          bytes: st.total,
          state: blockStateOf(st),
          caption: fmtSize(st.total),
        ),
      );
    } else {
      rest += st;
      restCount++;
    }
  }
  if (restCount > 0) {
    keep.add(
      MapBlock(
        id: restId,
        label: '其余 $restCount 项',
        bytes: rest.total,
        state: blockStateOf(rest),
        caption: fmtSize(rest.total),
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

  /// Big number + legend above the map. Off when the page shows a
  /// [RepoMapSummary] elsewhere (来源页 puts it in the left column).
  final bool showHeader;

  const RepoMapView({
    super.key,
    required this.connection,
    required this.dir,
    required this.onOpen,
    required this.menuFor,
    required this.onShowList,
    this.showHeader = true,
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
    final s = ref.watch(sizeScannerProvider(widget.connection));
    final dir = widget.dir;
    final blocks = mapBlocksFor(s, dir);
    final busy = s.running != null;
    final byPath = {for (final e in s.entriesOf(dir)) e.path: e};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showHeader)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                RepoMapSummary(scanner: s, dir: dir),
                const Spacer(),
                const MapLegend(),
              ],
            ),
          ),
        Expanded(
          child: blocks.isEmpty
              ? (busy || !s.isListed(dir)
                    ? const Center(child: Spinner(size: 22))
                    : const EmptyState(
                        icon: CupertinoIcons.folder,
                        title: '这里没有文件',
                      ))
              : AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  child: OrganicMap(
                    key: ValueKey(dir),
                    blocks: blocks,
                    onTap: (b) {
                      if (b.id == restId) return widget.onShowList();
                      final e = byPath[b.id];
                      if (e != null && e.isDir) widget.onOpen(e.path);
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

/// Big size number with file count, 未整理 total and count progress.
class RepoMapSummary extends StatelessWidget {
  final SizeScanner scanner;
  final String dir;

  /// Extra first caption line, e.g. 「演示 Alist · /影视库」.
  final String? title;

  const RepoMapSummary({
    super.key,
    required this.scanner,
    required this.dir,
    this.title,
  });

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
              Text('正在统计 · 已读 ${s.dirsListed} 个文件夹'),
              LinkText('停止', onTap: s.cancel),
            ],
          )
        : s.error != null
        ? Text('统计出错：${s.error}', style: TextStyle(color: p.danger))
        : s.isComplete(dir)
        ? Text(
            [
              '${stats.files} 个文件',
              if (stats.unorganized > 0) '未整理 ${fmtSize(stats.unorganized)}',
            ].join(' · '),
            style: TextStyle(color: p.textMuted),
          )
        : Wrap(
            spacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('已停止，结果不完整', style: TextStyle(color: p.textMuted)),
              LinkText('继续统计', onTap: () => unawaited(s.scan(dir))),
            ],
          );
    return BigNumber(
      value,
      unit: unit,
      captions: [?(title == null ? null : Text(title!)), status],
    );
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
