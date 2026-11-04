import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../data/settings.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../../widgets/common.dart';
import '../tasks/task_detail_page.dart' show taskDetailProvider;
import '../tasks/tasks_page.dart' show taskWorksProvider;
import 'review_logic.dart';
import 'review_panes.dart';

/// 识别结果三栏页（PLAN §5）.
class ReviewPage extends ConsumerStatefulWidget {
  final String taskId;

  const ReviewPage({super.key, required this.taskId});

  @override
  ConsumerState<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends ConsumerState<ReviewPage> {
  /// 0 = 可整理, 1 = 待手动识别.
  var _tab = 0;

  /// Main area shows the files no work claimed instead of a work.
  var _showUnassigned = false;

  /// Right pane (作品操作) can be hidden to give file names more room.
  var _showActions = true;
  final _searchFocus = FocusNode();
  final _search = TextEditingController();
  TaskReview? _review;
  Object? _error;
  GroupId? _selected;
  int _detailTab =
      folderTab - 1; // "unset": DetailPane falls back to first season
  var _updateSeq = 0;
  var _executing = false;

  TaskId get _id => TaskId(widget.taskId);
  TaskManager get _tm => ref.read(taskManagerProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ReviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.taskId != widget.taskId) {
      _review = null;
      _error = null;
      _selected = null;
      _showUnassigned = false;
      _detailTab = folderTab - 1;
      _executing = false;
      _load();
    }
  }

  @override
  void dispose() {
    _searchFocus.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await _tm.review(_id);
      if (!mounted) return;
      setState(() {
        _review = r;
        _selectFirstVisible();
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  // ---- derived lists

  List<MediaGroup> _groups({required bool matched}) {
    final r = _review;
    if (r == null) return const [];
    final q = _search.text.trim().toLowerCase();
    return [
      for (final g in r.scan.groups)
        if (isMatched(g, r.decisions[g.id]) == matched &&
            (q.isEmpty ||
                [
                  g.anchorTitle,
                  effectiveMatch(g, r.decisions[g.id])?.title,
                  effectiveMatch(g, r.decisions[g.id])?.originalTitle,
                ].any((t) => t != null && t.toLowerCase().contains(q))))
          g,
    ];
  }

  List<MediaGroup> get _visible => _groups(matched: _tab == 0);

  void _selectFirstVisible() {
    final v = _visible;
    if (!v.any((g) => g.id == _selected)) _selected = v.firstOrNull?.id;
  }

  MediaGroup? get _selectedGroup => _withMatchedShow(
    _review?.scan.groups.where((g) => g.id == _selected).firstOrNull,
  );

  /// group.show only holds the recognizer's match; fill in a hand-picked one.
  MediaGroup? _withMatchedShow(MediaGroup? g) {
    final id = _fetchShowFor(g);
    if (g == null || id == null) return g;
    final show = ref.read(showDetailProvider(id)).value;
    if (show == null) return g;
    return MediaGroup(
      id: g.id,
      kind: g.kind,
      anchorTitle: g.anchorTitle,
      anchorYear: g.anchorYear,
      rootDir: g.rootDir,
      files: g.files,
      match: g.match,
      matchScore: g.matchScore,
      show: show,
    );
  }

  /// TMDB id whose show [g] is missing, if any.
  int? _fetchShowFor(MediaGroup? g) {
    if (g == null || g.kind != MediaKind.episode) return null;
    final id = effectiveMatch(g, _decisionOf(g.id))?.tmdbId;
    return id == null || g.show?.info.tmdbId == id ? null : id;
  }

  // ---- mutations

  Future<void> _update(GroupId id, GroupDecision d) async {
    final seq = ++_updateSeq;
    final cur = _review;
    if (cur != null) {
      setState(() {
        _review = TaskReview(
          id: cur.id,
          scan: cur.scan,
          decisions: {...cur.decisions, id: d},
          preview: cur.preview,
        );
        _selectFirstVisible();
      });
    }
    final r = await _tm.updateDecision(_id, id, d);
    if (!mounted) return;
    ref.invalidate(taskWorksProvider(_id));
    ref.invalidate(taskDetailProvider(_id));
    if (seq != _updateSeq) return;
    setState(() {
      _review = r;
      _selectFirstVisible();
    });
  }

  GroupDecision _decisionOf(GroupId id) =>
      _review!.decisions[id] ?? const GroupDecision();

  Future<void> _editRow(MediaGroup g, ReviewRow row) async {
    final d = _decisionOf(g.id);
    final rows = rowsOf(g, d, _review!);
    final o = await showEditRowDialog(context, g, row, decision: d, rows: rows);
    if (o == null) return;
    final to = o.season != null && o.episode != null
        ? EpisodeRef(o.season!, o.episode!)
        : null;
    final main =
        !o.ignore && o.kind != MediaKind.special && o.kind != MediaKind.extra;
    // Moving one episode moves the ones after it too (12 -> S02E01, 13 -> S02E02 …).
    if (g.kind == MediaKind.episode &&
        main &&
        to != null &&
        to != targetRef(row)) {
      return _shift(g, row, to, kind: o.kind);
    }
    await _update(
      g.id,
      d.copyWith(overrides: {...d.overrides, row.file.path: o}),
    );
  }

  Future<void> _shift(
    MediaGroup g,
    ReviewRow row,
    EpisodeRef to, {
    MediaKind? kind,
  }) async {
    final before = _decisionOf(g.id);
    final set = shiftFrom(
      g,
      before,
      rowsOf(g, before, _review!),
      row,
      to,
      kind: kind ?? row.override?.kind,
    );
    await _update(
      g.id,
      before.copyWith(overrides: {...before.overrides, ...set}),
    );
    if (!mounted || set.length < 2) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('后面 ${set.length - 1} 个文件已依次顺延'),
          persist: false,
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () => _update(g.id, before),
          ),
        ),
      );
  }

  Future<void> _checkRow(MediaGroup g, ReviewRow row, bool on) {
    final d = _decisionOf(g.id);
    final old = row.override;
    return _update(
      g.id,
      d.copyWith(
        overrides: {
          ...d.overrides,
          row.file.path: FileOverride(
            season: old?.season,
            episode: old?.episode,
            kind: old?.kind,
            ignore: !on,
          ),
        },
      ),
    );
  }

  Future<void> _correct(MediaGroup g) async {
    final c = await showTmdbSearchDialog(
      context,
      initial: effectiveMatch(g, _decisionOf(g.id))?.title ?? g.anchorTitle,
      kind: g.kind == MediaKind.unknown ? null : g.kind,
      year: effectiveMatch(g, _decisionOf(g.id))?.year ?? g.anchorYear,
    );
    // Picking a match means "organize this": an unmatched group starts unchecked.
    if (c != null) {
      await _update(g.id, _decisionOf(g.id).copyWith(match: c, selected: true));
    }
  }

  Future<void> _execute() async {
    if (_executing) return;
    final r = _review;
    if (r == null || r.preview.conflicts.isNotEmpty) return;
    final ops = r.preview.ops.where((o) => o.selected).toList();
    if (ops.isEmpty) return;
    int n(ExecPhase p) => ops.where((o) => o.phase == p).length;
    final groups = r.decisions.values.where((d) => d.selected).length;
    final ok =
        !ref.read(settingsProvider).confirmBeforeExecute ||
        await confirmDialog(
          context,
          title: '执行任务',
          content: Text(
            '将处理 $groups 个作品：\n'
            '· 重命名/移动文件 ${n(ExecPhase.files)} 项\n'
            '· 整理文件夹 ${n(ExecPhase.folders)} 项\n'
            '· 清理 ${n(ExecPhase.cleanup)} 项\n'
            '执行后可在任务页撤销。',
          ),
          confirmLabel: '执行',
        );
    if (!ok || !mounted || _executing) return;
    setState(() => _executing = true);
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _tm.run(_id);
      if (mounted) router.go('/tasks/${_id.value}');
    } on Object catch (e) {
      if (mounted) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _executing = false);
    }
  }

  // ---- keyboard: ↑↓ groups, ←→ seasons, space toggles, ⌘F search, ⌘↩ execute

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final cmd =
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;
    if (cmd && k == LogicalKeyboardKey.keyF) {
      _searchFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (cmd &&
        (k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.numpadEnter)) {
      _execute();
      return KeyEventResult.handled;
    }
    final typing =
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>() !=
        null;
    if (typing) return KeyEventResult.ignored;
    final v = _visible;
    final i = v.indexWhere((g) => g.id == _selected);
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowUp) {
      final next = i + (k == LogicalKeyboardKey.arrowDown ? 1 : -1);
      if (next >= 0 && next < v.length) {
        setState(() {
          _selected = v[next].id;
          _showUnassigned = false;
          _detailTab = folderTab - 1;
        });
      }
      return KeyEventResult.handled;
    }
    final g = _selectedGroup;
    if (g != null &&
        (k == LogicalKeyboardKey.arrowLeft ||
            k == LogicalKeyboardKey.arrowRight)) {
      // Same tab order as DetailPane: seasons ascending, then 文件夹.
      final tabs = [
        ...({
          for (final row in rowsOf(g, _decisionOf(g.id), _review!)) row.season,
        }.toList()..sort()),
        folderTab,
      ];
      final at = tabs.indexOf(_detailTab);
      final next =
          (at < 0 ? 0 : at) + (k == LogicalKeyboardKey.arrowRight ? 1 : -1);
      if (next >= 0 && next < tabs.length) {
        setState(() => _detailTab = tabs[next]);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.space && i >= 0) {
      final d = _decisionOf(v[i].id);
      _update(v[i].id, d.copyWith(selected: !d.selected));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final missingShow = _fetchShowFor(
      _review?.scan.groups.where((g) => g.id == _selected).firstOrNull,
    );
    if (missingShow != null) ref.watch(showDetailProvider(missingShow));
    final r = _review;
    ref.listen(
      tasksProvider.select(
        (v) => v.value?.where((t) => t.id == _id).firstOrNull?.stage,
      ),
      (prev, next) {
        if (prev == TaskStage.awaitingReview &&
            next != null &&
            next != TaskStage.awaitingReview) {
          context.go('/tasks/${_id.value}');
        }
      },
    );
    final paths = ref
        .watch(tasksProvider)
        .asData
        ?.value
        .where((t) => t.id == _id)
        .firstOrNull
        ?.paths;
    return PageScaffold(
      title: '识别结果',
      subtitle: [
        widget.taskId,
        if (paths != null && paths.length == 1) paths.single,
        if (paths != null && paths.length > 1) '${paths.length} 个文件夹',
      ].join('  ·  '),
      actions: [
        if (paths != null && paths.length > 1)
          Tooltip(
            message: paths.join('\n'),
            child: Icon(
              CupertinoIcons.folder,
              size: 16,
              color: Palette.of(context).textMuted,
            ),
          ),
        const Tooltip(
          message:
              '快捷键\n↑ ↓  切换作品\n← →  切换季 / 文件夹\n空格  勾选或取消作品\n⌘F  搜索\n⌘↩  执行',
          child: Padding(
            padding: EdgeInsets.all(8),
            child: Icon(CupertinoIcons.keyboard, size: 16),
          ),
        ),
        IconButton(
          key: const ValueKey('toggle-actions'),
          tooltip: _showActions ? '隐藏作品操作' : '显示作品操作',
          icon: const Icon(CupertinoIcons.sidebar_right),
          onPressed: () => setState(() => _showActions = !_showActions),
        ),
      ],
      leading: IconButton(
        tooltip: '返回任务',
        icon: const Icon(CupertinoIcons.chevron_left),
        onPressed: () => context.go('/tasks'),
      ),
      child: _error != null
          ? EmptyState(
              icon: CupertinoIcons.exclamationmark_triangle,
              title: '无法读取识别结果',
              message: '$_error',
            )
          : r == null
          ? const Center(child: CircularProgressIndicator())
          : Focus(
              autofocus: true,
              onKeyEvent: _onKey,
              child: Stack(
                children: [
                  Positioned.fill(child: _body(r)),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 18,
                    child: Center(child: _bottomBar(r)),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _body(TaskReview r) {
    final g = _selectedGroup;
    final p = Palette.of(context);
    final hairlineSide = BorderSide(color: p.line, width: hairline);
    return DecoratedBox(
      decoration: BoxDecoration(border: Border(top: hairlineSide)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 312,
            decoration: BoxDecoration(
              color: p.sidebar.withValues(alpha: 0.5),
              border: Border(right: hairlineSide),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: TextField(
                    key: const ValueKey('review-search'),
                    controller: _search,
                    focusNode: _searchFocus,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(CupertinoIcons.search, size: 14),
                      hintText: '搜索作品  ⌘F',
                    ),
                    onChanged: (_) => setState(_selectFirstVisible),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Segmented<int>(
                    options: {
                      0: '可整理 (${_groups(matched: true).length})',
                      1: '待手动识别 (${_groups(matched: false).length})',
                    },
                    value: _tab,
                    onChanged: (v) => setState(() {
                      _tab = v;
                      _selectFirstVisible();
                    }),
                  ),
                ),
                Expanded(
                  child: GroupList(
                    groups: _visible,
                    review: r,
                    selected: _selected,
                    onSelect: (id) => setState(() {
                      _selected = id;
                      _showUnassigned = false;
                      _detailTab = folderTab - 1;
                    }),
                    onCheck: (id, v) =>
                        _update(id, _decisionOf(id).copyWith(selected: v)),
                    onPick: (grp, c) => _update(
                      grp.id,
                      _decisionOf(grp.id).copyWith(match: c, selected: true),
                    ),
                  ),
                ),
                if (r.scan.unassigned.isNotEmpty)
                  Material(
                    type: MaterialType.transparency,
                    child: ListTile(
                      key: const ValueKey('unassigned-link'),
                      dense: true,
                      selected: _showUnassigned,
                      leading: const Icon(CupertinoIcons.tray, size: 16),
                      title: Text('未归类 ${r.scan.unassigned.length} 个文件'),
                      subtitle: const Text('没归进任何作品，不会被整理'),
                      trailing: const Icon(
                        CupertinoIcons.chevron_right,
                        size: 12,
                      ),
                      onTap: () => setState(() => _showUnassigned = true),
                    ),
                  ),
                const SizedBox(height: 64),
              ],
            ),
          ),
          Expanded(
            child: _showUnassigned
                ? Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 64),
                    child: UnassignedPane(files: r.scan.unassigned),
                  )
                : g == null
                ? const EmptyState(
                    icon: CupertinoIcons.rectangle_stack,
                    title: '选择左侧的作品查看明细',
                  )
                : Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 64),
                    child: DetailPane(
                      group: g,
                      decision: r.decisions[g.id],
                      review: r,
                      tab: _detailTab,
                      onTab: (t) => setState(() => _detailTab = t),
                      onEdit: (row) => _editRow(g, row),
                      onCheck: (row, v) => _checkRow(g, row, v),
                      onShift: (row, to) => _shift(g, row, to),
                    ),
                  ),
          ),
          if (_showActions && !_showUnassigned)
            Container(
              width: 284,
              decoration: BoxDecoration(border: Border(left: hairlineSide)),
              padding: const EdgeInsets.only(bottom: 64),
              child: g == null
                  ? const SizedBox.shrink()
                  // Own layer: stale strips were seen here while scrolling.
                  : RepaintBoundary(
                      child: ActionPane(
                        key: ValueKey(g.id),
                        group: g,
                        decision: _decisionOf(g.id),
                        onChange: (d) => _update(g.id, d),
                        onCorrect: () => _correct(g),
                      ),
                    ),
            ),
        ],
      ),
    );
  }

  Widget _bottomBar(TaskReview r) {
    final p = Palette.of(context);
    final conflicts = r.preview.conflicts.length;
    final mode = ref
        .watch(tasksProvider)
        .asData
        ?.value
        .where((t) => t.id == _id)
        .map((t) => t.mode)
        .firstOrNull;
    final ops = r.preview.ops.where((o) => o.selected).length;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(Radii.xl),
        border: Border.all(color: p.line, width: hairline),
        boxShadow: floatShadow(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Segmented<OrganizeMode>(
            options: const {
              OrganizeMode.inPlace: '原地整理',
              OrganizeMode.moveToLibrary: '移动到媒体库',
            },
            value: mode ?? OrganizeMode.inPlace,
            onChanged: (v) async {
              try {
                final nr = await _tm.setMode(_id, v);
                if (mounted) setState(() => _review = nr);
              } on Object catch (e) {
                if (!mounted) return;
                final msg = '$e'.contains('libraryRoot')
                    ? '请先在「来源」连接设置中配置媒体库目录'
                    : '切换整理模式失败：$e';
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(content: Text(msg)));
              }
            },
          ),
          const SizedBox(width: 16),
          Icon(
            conflicts == 0
                ? CupertinoIcons.checkmark_seal_fill
                : CupertinoIcons.exclamationmark_triangle_fill,
            size: 14,
            color: conflicts == 0 ? p.success : p.danger,
          ),
          const SizedBox(width: 6),
          Text(
            conflicts == 0 ? '没有冲突' : '$conflicts 处冲突，需处理后才能执行',
            key: const ValueKey('conflict-count'),
            style: TextStyle(
              fontSize: 12.5,
              color: conflicts == 0 ? p.textMuted : p.danger,
              fontWeight: conflicts == 0 ? null : FontWeight.w600,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '· $ops 项操作',
            style: TextStyle(fontSize: 12.5, color: p.textFaint),
          ),
          const SizedBox(width: 18),
          FilledButton.icon(
            key: const ValueKey('execute-button'),
            onPressed: conflicts == 0 && ops > 0 ? _execute : null,
            icon: const Icon(CupertinoIcons.play_fill, size: 12),
            label: const Text('执行任务  ⌘↩'),
          ),
        ],
      ),
    );
  }
}
