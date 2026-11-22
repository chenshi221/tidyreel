import 'dart:math' as math;

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

  /// Left-pane quick filter on the matched tab.
  var _filter = ReviewFilter.all;

  /// Live local pane widths while dragging split dividers.
  double? _dragLeftWidth;
  double? _dragRightWidth;

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
  var _pendingUpdates = 0;
  var _executing = false;

  TaskId get _id => TaskId(widget.taskId);
  TaskManager get _tm => ref.read(taskManagerProvider);

  @override
  void initState() {
    super.initState();
    _load();
    // A "识别完成，等你确认" toast for this task is stale once you're here.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    });
  }

  @override
  void didUpdateWidget(ReviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.taskId != widget.taskId) {
      _review = null;
      _error = null;
      _selected = null;
      _filter = ReviewFilter.all;
      _showUnassigned = false;
      _detailTab = folderTab - 1;
      _pendingUpdates = 0;
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
    final task = _id;
    final seq = ++_updateSeq;
    setState(() => _pendingUpdates++);
    try {
      final r = await _tm.review(task);
      if (!mounted || task != _id || seq != _updateSeq) return;
      setState(() {
        _review = r;
        _error = null;
        _selectFirstVisible();
      });
    } catch (e) {
      if (mounted && task == _id && seq == _updateSeq) {
        setState(() => _error = e);
      }
    } finally {
      if (mounted && task == _id) setState(() => _pendingUpdates--);
    }
  }

  void _reloadIfReviewing() {
    if (!mounted) return;
    final stage = ref
        .read(tasksProvider)
        .asData
        ?.value
        .where((t) => t.id == _id)
        .firstOrNull
        ?.stage;
    if (stage == null || stage == TaskStage.awaitingReview) {
      _load();
    }
  }

  // ---- derived lists

  List<MediaGroup> _baseGroups({required bool matched}) {
    final r = _review;
    if (r == null) return const [];
    final q = _search.text.trim();
    return [
      for (final g in r.scan.groups)
        if (isMatched(g, r.decisions[g.id]) == matched &&
            (q.isEmpty ||
                [
                  g.anchorTitle,
                  effectiveMatch(g, r.decisions[g.id])?.title,
                  effectiveMatch(g, r.decisions[g.id])?.originalTitle,
                ].any((t) => t != null && fuzzyMatch(q, t))))
          effectiveGroup(g, r.decisions[g.id]),
    ];
  }

  List<MediaGroup> _groups({required bool matched}) {
    final base = _baseGroups(matched: matched);
    if (!matched || _filter == ReviewFilter.all) return base;
    final r = _review;
    if (r == null) return base;
    final conflicts = conflictGroups(r);
    final threshold = ref.read(settingsProvider).confidenceThreshold;
    return [
      for (final g in base)
        if (matchesReviewFilter(
          g,
          r.decisions[g.id],
          r,
          _filter,
          conflicts: conflicts,
          threshold: threshold,
        ))
          g,
    ];
  }

  List<MediaGroup> get _visible => _groups(matched: _tab == 0);

  void _selectFirstVisible() {
    final v = _visible;
    if (!v.any((g) => g.id == _selected)) {
      _selected = v.firstOrNull?.id;
      _detailTab = folderTab - 1;
    }
  }

  void _changeTab(int tab) {
    _tab = tab;
    _filter = ReviewFilter.all;
    _showUnassigned = false;
    _selectFirstVisible();
  }

  void _returnToWorks() {
    if (_visible.isEmpty && _baseGroups(matched: _tab != 0).isNotEmpty) {
      _changeTab(1 - _tab);
    } else {
      _showUnassigned = false;
      _selectFirstVisible();
    }
  }

  void _jumpToFirstConflict(TaskReview r) {
    final loc = firstConflictLocation(r);
    if (loc == null) return;
    final g = r.scan.groups.where((x) => x.id == loc.group).firstOrNull;
    if (g == null) return;
    final matched = isMatched(g, r.decisions[g.id]);
    setState(() {
      if (_search.text.isNotEmpty) _search.clear();
      _tab = matched ? 0 : 1;
      if (_filter != ReviewFilter.all && _filter != ReviewFilter.conflict) {
        _filter = ReviewFilter.all;
      }
      _showUnassigned = false;
      _selected = loc.group;
      _detailTab = loc.season ?? folderTab;
    });
  }

  /// The selected group as its current match makes it.
  MediaGroup? get _rawSelected {
    final g = _review?.scan.groups.where((g) => g.id == _selected).firstOrNull;
    return g == null ? null : effectiveGroup(g, _review!.decisions[g.id]);
  }

  MediaGroup? get _selectedGroup => _withMatchedShow(_rawSelected);

  /// group.show only holds the recognizer's match; fill in a hand-picked one.
  MediaGroup? _withMatchedShow(MediaGroup? g) {
    final id = _fetchShowFor(g);
    if (g == null || id == null) return g;
    final show = ref.read(showDetailProvider(id)).value;
    if (show == null) return g;
    final sameMatch = g.match?.tmdbId == show.info.tmdbId;
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
      suggestedStrategy: sameMatch ? g.suggestedStrategy : null,
      suggestedStrategyReason: sameMatch ? g.suggestedStrategyReason : null,
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
    setState(() {
      _pendingUpdates++;
      if (cur != null) {
        _review = TaskReview(
          id: cur.id,
          scan: cur.scan,
          decisions: {...cur.decisions, id: d},
          preview: cur.preview,
        );
        // The last unmatched work got matched: nothing left on this tab, and
        // what's next is organizing it.
        if (_tab == 1 && _baseGroups(matched: false).isEmpty) _tab = 0;
        _selectFirstVisible();
      }
    });
    try {
      final r = await _tm.updateDecision(_id, id, d);
      if (!mounted) return;
      ref.invalidate(taskWorksProvider(_id));
      ref.invalidate(taskDetailProvider(_id));
      if (seq != _updateSeq) return;
      setState(() {
        _review = r;
        _selectFirstVisible();
      });
    } finally {
      if (mounted) setState(() => _pendingUpdates--);
    }
  }

  Future<void> _updateMany(Map<GroupId, GroupDecision> updates) async {
    if (updates.isEmpty) return;
    final seq = ++_updateSeq;
    final cur = _review;
    setState(() {
      _pendingUpdates++;
      if (cur != null) {
        _review = TaskReview(
          id: cur.id,
          scan: cur.scan,
          decisions: {...cur.decisions, ...updates},
          preview: cur.preview,
        );
      }
    });
    try {
      TaskReview? latest;
      for (final e in updates.entries) {
        latest = await _tm.updateDecision(_id, e.key, e.value);
      }
      if (!mounted) return;
      ref.invalidate(taskWorksProvider(_id));
      ref.invalidate(taskDetailProvider(_id));
      if (seq != _updateSeq || latest == null) return;
      setState(() {
        _review = latest;
        _selectFirstVisible();
      });
    } finally {
      if (mounted) setState(() => _pendingUpdates--);
    }
  }

  Future<TaskReview?> _mutateReview(
    Future<TaskReview> Function() action, {
    void Function(TaskReview r)? after,
  }) async {
    final seq = ++_updateSeq;
    setState(() => _pendingUpdates++);
    try {
      final r = await action();
      if (!mounted) return null;
      ref.invalidate(taskWorksProvider(_id));
      ref.invalidate(taskDetailProvider(_id));
      if (seq != _updateSeq) return r;
      setState(() {
        _review = r;
        after?.call(r);
        _selectFirstVisible();
      });
      return r;
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('$e')));
      }
      return null;
    } finally {
      if (mounted) setState(() => _pendingUpdates--);
    }
  }

  Future<void> _setUnassignedDelete(String filePath, bool delete) =>
      _mutateReview(() => _tm.setUnassignedDelete(_id, filePath, delete));

  Future<void> _assignUnassigned(String filePath, GroupId targetGroup) async {
    final cur = _review;
    final target = cur?.scan.groups
        .where((g) => g.id == targetGroup)
        .firstOrNull;
    final targetTitle = target == null
        ? ''
        : (effectiveMatch(target, cur!.decisions[target.id])?.title ??
              target.anchorTitle);
    final r = await _mutateReview(
      () => _tm.assignUnassigned(_id, filePath, targetGroup),
      after: (next) {
        if (next.scan.unassigned.isEmpty) {
          _showUnassigned = false;
          final g = next.scan.groups
              .where((x) => x.id == targetGroup)
              .firstOrNull;
          if (g != null) {
            _tab = isMatched(g, next.decisions[g.id]) ? 0 : 1;
            _filter = ReviewFilter.all;
            _selected = targetGroup;
            _detailTab = folderTab - 1;
          }
        }
      },
    );
    if (r != null && mounted && targetTitle.isNotEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('已归入「$targetTitle」')));
    }
  }

  Future<void> _mergeGroup(MediaGroup source) async {
    final cur = _review;
    if (cur == null) return;
    final others = [
      for (final g in cur.scan.groups)
        if (g.id != source.id) g,
    ];
    if (others.isEmpty) return;
    final keepId = await showMergeGroupPicker(
      context,
      source: source,
      candidates: others,
      decisions: cur.decisions,
    );
    if (keepId == null || !mounted) return;
    final target = others.where((g) => g.id == keepId).firstOrNull;
    final targetTitle = target == null
        ? ''
        : (effectiveMatch(target, cur.decisions[target.id])?.title ??
              target.anchorTitle);
    final r = await _mutateReview(
      () => _tm.mergeGroups(_id, keepId, source.id),
      after: (next) {
        final kept = next.scan.groups.where((x) => x.id == keepId).firstOrNull;
        if (kept != null) {
          _tab = isMatched(kept, next.decisions[kept.id]) ? 0 : 1;
          _filter = ReviewFilter.all;
          _showUnassigned = false;
          _selected = keepId;
          _detailTab = folderTab - 1;
        }
      },
    );
    if (r != null && mounted && targetTitle.isNotEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('已合并到「$targetTitle」')));
    }
  }

  Future<void> _splitGroup(MediaGroup source) async {
    final cur = _review;
    if (cur == null) return;
    final picked = await showSplitGroupDialog(context, group: source);
    if (picked == null || picked.isEmpty || !mounted) return;
    final beforeIds = {for (final g in cur.scan.groups) g.id};
    final r = await _mutateReview(() => _tm.splitGroup(_id, source.id, picked));
    if (r == null || !mounted) return;
    final created = r.scan.groups
        .where((g) => !beforeIds.contains(g.id))
        .firstOrNull;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('已拆分为新作品'),
          action: created == null
              ? null
              : SnackBarAction(
                  label: '去查看',
                  onPressed: () {
                    if (!mounted) return;
                    setState(() {
                      _tab = isMatched(created, r.decisions[created.id])
                          ? 0
                          : 1;
                      _filter = ReviewFilter.all;
                      _showUnassigned = false;
                      _selected = created.id;
                      _detailTab = folderTab - 1;
                    });
                  },
                ),
        ),
      );
  }

  GroupDecision _decisionOf(GroupId id) =>
      _review!.decisions[id] ?? const GroupDecision();

  Future<void> _editRow(MediaGroup g, ReviewRow row) async {
    final d = _decisionOf(g.id);
    final rows = rowsOf(g, d, _review!);
    final res = await showEditRowDialog(
      context,
      g,
      row,
      decision: d,
      rows: rows,
    );
    if (res == null) return;
    final o = res.override;
    final to = o.season != null && o.episode != null
        ? EpisodeRef(o.season!, o.episode!)
        : null;
    final main =
        row.file.role == FileRole.video &&
        !o.ignore &&
        o.kind != MediaKind.special &&
        o.kind != MediaKind.extra;
    // Moving one episode moves the ones after it when shiftFollowing is checked.
    if (res.shiftFollowing &&
        g.kind == MediaKind.episode &&
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
    final r = await showTmdbSearchDialog(
      context,
      initial: effectiveMatch(g, _decisionOf(g.id))?.title ?? g.anchorTitle,
      pinKeyword: g.anchorTitle,
    );
    if (r == null) return;
    if (r.pin != null) {
      ref.read(titleRulesProvider.notifier).pin(r.pin!, r.match);
    }
    // Picking a match means "organize this": an unmatched group starts unchecked.
    await _update(
      g.id,
      _decisionOf(g.id).copyWith(match: r.match, selected: true),
    );
  }

  void _showShortcutsSheet() {
    const shortcuts = [
      ('↑ / ↓', '切换左侧作品'),
      ('← / →', '切换季标签 / 文件夹'),
      ('空格', '勾选或取消当前作品'),
      ('⌘F / Ctrl+F', '聚焦作品搜索框'),
      ('⌘↩ / Ctrl+↩', '开始整理'),
    ];
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final p = Palette.of(ctx);
        return MacSheet(
          child: SizedBox(
            width: 340,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('快捷键', style: Theme.of(ctx).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Panel(
                    framed: true,
                    child: Rows(
                      children: [
                        for (final (keys, desc) in shortcuts)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    desc,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: p.sidebar,
                                    borderRadius: BorderRadius.circular(
                                      Radii.sm,
                                    ),
                                    border: Border.all(
                                      color: p.lineStrong,
                                      width: hairline,
                                    ),
                                  ),
                                  child: Text(
                                    keys,
                                    style: TextStyle(
                                      fontFamily: monoFamily,
                                      fontFamilyFallback: monoFallback,
                                      fontSize: 11.5,
                                      color: p.text,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('关闭'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _execute() async {
    if (_executing || _pendingUpdates > 0) return;
    var r = _review;
    if (r == null) return;
    // Shows landing in a folder that's already there (or filled twice by
    // this task): ask every time, and say where.
    final merges = [
      for (final m in r.preview.merges)
        if (r.decisions[m.group]?.selected ?? true) m,
    ];
    if (r.preview.conflicts.isNotEmpty && merges.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('仍有 ${r.preview.conflicts.length} 处冲突，请先处理')),
        );
      return;
    }
    if (merges.isNotEmpty) {
      final mode = ref
          .read(tasksProvider)
          .asData
          ?.value
          .where((t) => t.id == _id)
          .map((t) => t.mode)
          .firstOrNull;
      final separate = await showMergeDialog(
        context,
        review: r,
        merges: merges,
        backend: ref.read(backendForProvider)(r.scan.connection),
        mode: mode,
      );
      if (separate == null || !mounted) return;
      for (final id in separate) {
        await _update(id, _decisionOf(id).copyWith(separate: true));
      }
      if (!mounted) return;
      r = _review;
      if (r == null) return;
      if (r.preview.conflicts.isNotEmpty) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                '仍有 ${r.preview.conflicts.length} 处冲突，可在弹窗中选择「分开保留」或先修改集号',
              ),
            ),
          );
        return;
      }
    }
    final ops = r.preview.ops.where((o) => o.selected).toList();
    if (ops.isEmpty) return;
    // Only deleting can't be undone, so that is the one thing we ask about.
    final deletePaths = [
      for (final o in ops)
        if (o.kind == OpKind.delete) o.src,
    ];
    final ok =
        deletePaths.isEmpty ||
        await confirmPermanentDelete(
          context,
          deletePaths.length,
          paths: deletePaths,
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
    final missingShow = _fetchShowFor(_rawSelected);
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
    ref.listen(namingProfileProvider, (_, _) => _reloadIfReviewing());
    ref.listen(
      settingsProvider.select((s) => (s.autoDeleteJunk, s.confidenceThreshold)),
      (_, _) => _reloadIfReviewing(),
    );
    ref.listen(connectionsProvider, (_, _) => _reloadIfReviewing());
    final taskSummary = ref
        .watch(tasksProvider)
        .asData
        ?.value
        .where((t) => t.id == _id)
        .firstOrNull;
    final paths = taskSummary?.paths;
    final scrapeOnly = taskSummary?.scrapeOnly ?? false;
    return PageScaffold(
      title: '识别结果',
      subtitle: [
        if (paths != null && paths.length == 1) paths.single,
        if (paths != null && paths.length > 1) '${paths.length} 个文件夹',
      ].join('  ·  '),
      actions: [
        if (scrapeOnly)
          Tag(
            '仅刮削',
            key: const ValueKey('scrape-only-tag'),
            color: Palette.of(context).accent,
          ),
        if (paths != null && paths.length > 1)
          Tooltip(
            message: paths.join('\n'),
            child: Icon(
              CupertinoIcons.folder,
              size: 16,
              color: Palette.of(context).textMuted,
            ),
          ),
        IconButton(
          key: const ValueKey('shortcuts-button'),
          tooltip: '快捷键（点击查看）\n↑ ↓  切换作品\n← →  切换季 / 文件夹\n空格  勾选或取消作品\n⌘F  搜索\n⌘↩  开始整理',
          icon: const Icon(CupertinoIcons.keyboard, size: 16),
          onPressed: _showShortcutsSheet,
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
          ? const Center(child: Spinner(size: 20))
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
    final matchedBase = _baseGroups(matched: true);
    final unmatchedBase = _baseGroups(matched: false);
    final visible = _visible;
    final otherGroups = _tab == 0 ? unmatchedBase : matchedBase;
    final p = Palette.of(context);
    final theme = Theme.of(context);
    final hairlineSide = BorderSide(color: p.line, width: hairline);
    final unassignedDeletes = plannedUnassignedDeletes(
      r.scan.unassigned,
      r.preview,
    ).length;

    final (savedLeft, savedRight, threshold) = ref.watch(
      settingsProvider.select(
        (s) => (s.reviewLeftWidth, s.reviewRightWidth, s.confidenceThreshold),
      ),
    );
    final conflicts = conflictGroups(r);
    final conflictCount = matchedBase
        .where((x) => conflicts.contains(x.id))
        .length;
    final incompleteCount = matchedBase
        .where((x) => isGroupIncomplete(x, r.decisions[x.id]))
        .length;
    final lowConfCount = matchedBase
        .where(
          (x) => isGroupLowConfidence(
            x,
            r.decisions[x.id],
            r,
            threshold: threshold,
          ),
        )
        .length;
    final showRight = _showActions && !_showUnassigned && g != null;
    final canMerge = r.scan.groups.length >= 2;
    final selectedVisibleCount = visible
        .where((x) => _decisionOf(x.id).selected)
        .length;

    return DecoratedBox(
      decoration: BoxDecoration(border: Border(top: hairlineSide)),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const minCenterWidth = 320.0;
          final totalWidth = constraints.maxWidth;
          final dividerTotal = showRight ? 12.0 : 6.0;
          final rawLeft = (_dragLeftWidth ?? savedLeft).clamp(240.0, 460.0);
          final rawRight = (_dragRightWidth ?? savedRight).clamp(220.0, 420.0);

          var effectiveLeft = rawLeft;
          var effectiveRight = showRight ? rawRight : 0.0;
          if (totalWidth.isFinite) {
            final availableForSides = math.max(
              0.0,
              totalWidth - dividerTotal - minCenterWidth,
            );
            if (effectiveLeft + effectiveRight > availableForSides) {
              if (!showRight) {
                effectiveLeft = math.min(effectiveLeft, availableForSides);
                if (effectiveLeft < 180 && totalWidth > dividerTotal + 180) {
                  effectiveLeft = math.min(
                    180.0,
                    totalWidth - dividerTotal - 160.0,
                  );
                }
              } else {
                final excess =
                    effectiveLeft + effectiveRight - availableForSides;
                final leftRoom = math.max(0.0, effectiveLeft - 240.0);
                final rightRoom = math.max(0.0, effectiveRight - 220.0);
                if (leftRoom + rightRoom >= excess &&
                    leftRoom + rightRoom > 0) {
                  final takeRight = math.min(
                    rightRoom,
                    excess * (rightRoom / (leftRoom + rightRoom)),
                  );
                  final takeLeft = math.min(leftRoom, excess - takeRight);
                  effectiveRight -= takeRight;
                  effectiveLeft -= takeLeft;
                } else {
                  final maxSides = math.max(
                    0.0,
                    totalWidth - dividerTotal - 200.0,
                  );
                  final sum = effectiveLeft + effectiveRight;
                  if (sum > 0 && sum > maxSides) {
                    final scale = maxSides / sum;
                    effectiveLeft *= scale;
                    effectiveRight *= scale;
                  }
                }
              }
            }
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                key: const ValueKey('review-left-pane'),
                width: effectiveLeft,
                color: p.sidebar.withValues(alpha: 0.5),
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
                        decoration: InputDecoration(
                          prefixIcon: const Icon(
                            CupertinoIcons.search,
                            size: 14,
                          ),
                          hintText: '搜索作品  ⌘F',
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(
                                  key: const ValueKey('review-search-clear'),
                                  tooltip: '清空搜索',
                                  iconSize: 14,
                                  icon: const Icon(
                                    CupertinoIcons.xmark_circle_fill,
                                  ),
                                  onPressed: () {
                                    _search.clear();
                                    setState(_selectFirstVisible);
                                  },
                                ),
                        ),
                        onChanged: (_) => setState(_selectFirstVisible),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: Segmented<int>(
                        options: {
                          0: '可整理 ${matchedBase.length}',
                          1: '需手动匹配 ${unmatchedBase.length}',
                        },
                        value: _tab,
                        onChanged: (v) => setState(() => _changeTab(v)),
                      ),
                    ),
                    if (_tab == 0 && matchedBase.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Wrap(
                              spacing: 5,
                              runSpacing: 5,
                              children: [
                                ReviewFilterChip(
                                  key: const ValueKey('filter-all'),
                                  label: '全部',
                                  selected: _filter == ReviewFilter.all,
                                  onTap: () => setState(() {
                                    _filter = ReviewFilter.all;
                                    _selectFirstVisible();
                                  }),
                                ),
                                if (conflictCount > 0 ||
                                    _filter == ReviewFilter.conflict)
                                  ReviewFilterChip(
                                    key: const ValueKey('filter-conflict'),
                                    label: '冲突 $conflictCount',
                                    color: p.danger,
                                    selected: _filter == ReviewFilter.conflict,
                                    onTap: () => setState(() {
                                      _filter = ReviewFilter.conflict;
                                      _selectFirstVisible();
                                    }),
                                  ),
                                if (incompleteCount > 0 ||
                                    _filter == ReviewFilter.incomplete)
                                  ReviewFilterChip(
                                    key: const ValueKey('filter-incomplete'),
                                    label: '缺集 $incompleteCount',
                                    color: p.warning,
                                    selected:
                                        _filter == ReviewFilter.incomplete,
                                    onTap: () => setState(() {
                                      _filter = ReviewFilter.incomplete;
                                      _selectFirstVisible();
                                    }),
                                  ),
                                if (lowConfCount > 0 ||
                                    _filter == ReviewFilter.lowConfidence)
                                  ReviewFilterChip(
                                    key: const ValueKey('filter-lowConfidence'),
                                    label: '低置信 $lowConfCount',
                                    color: p.warning,
                                    selected:
                                        _filter == ReviewFilter.lowConfidence,
                                    onTap: () => setState(() {
                                      _filter = ReviewFilter.lowConfidence;
                                      _selectFirstVisible();
                                    }),
                                  ),
                              ],
                            ),
                            if (visible.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Text(
                                    '已选 $selectedVisibleCount/${visible.length}',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: p.textFaint,
                                    ),
                                  ),
                                  const Spacer(),
                                  Hoverable(
                                    key: const ValueKey('select-all-visible'),
                                    onTap: () => _updateMany({
                                      for (final x in visible)
                                        if (!_decisionOf(x.id).selected)
                                          x.id: _decisionOf(x.id)
                                              .copyWith(selected: true),
                                    }),
                                    builder: (_, hover) => Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 5,
                                        vertical: 2,
                                      ),
                                      child: Text(
                                        '全选',
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: hover ? p.text : p.textMuted,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Hoverable(
                                    key: const ValueKey(
                                      'invert-select-visible',
                                    ),
                                    onTap: () => _updateMany({
                                      for (final x in visible)
                                        x.id: _decisionOf(x.id).copyWith(
                                          selected: !_decisionOf(x.id).selected,
                                        ),
                                    }),
                                    builder: (_, hover) => Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 5,
                                        vertical: 2,
                                      ),
                                      child: Text(
                                        '反选',
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: hover ? p.text : p.textMuted,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    Expanded(
                      child: visible.isEmpty
                          ? EmptyState(
                              icon: CupertinoIcons.tray,
                              title: _search.text.trim().isNotEmpty
                                  ? '没有符合搜索条件的作品'
                                  : _tab == 0 && _filter != ReviewFilter.all
                                  ? '没有符合筛选条件的作品'
                                  : _tab == 0
                                  ? '没有可整理的作品'
                                  : '没有需要手动匹配的作品',
                              action: _tab == 0 && _filter != ReviewFilter.all
                                  ? TextButton(
                                      onPressed: () => setState(() {
                                        _filter = ReviewFilter.all;
                                        _selectFirstVisible();
                                      }),
                                      child: const Text('显示全部作品'),
                                    )
                                  : otherGroups.isEmpty
                                  ? null
                                  : TextButton(
                                      onPressed: () =>
                                          setState(() => _changeTab(1 - _tab)),
                                      child: Text(
                                        _tab == 1
                                            ? '查看可整理的 ${otherGroups.length} 个作品'
                                            : '查看需手动匹配的 ${otherGroups.length} 个作品',
                                      ),
                                    ),
                            )
                          : GroupList(
                              groups: visible,
                              review: r,
                              selected: _showUnassigned ? null : _selected,
                              canMerge: canMerge,
                              onSelect: (id) => setState(() {
                                if (_selected != id) _detailTab = folderTab - 1;
                                _selected = id;
                                _showUnassigned = false;
                              }),
                              onCheck: (id, v) => _update(
                                id,
                                _decisionOf(id).copyWith(selected: v),
                              ),
                              onPick: (grp, c) => _update(
                                grp.id,
                                _decisionOf(grp.id)
                                    .copyWith(match: c, selected: true),
                              ),
                              onCorrect: _correct,
                              onMergeGroup: _mergeGroup,
                              onSplitGroup: _splitGroup,
                            ),
                    ),
                    if (r.scan.unassigned.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                        child: Hoverable(
                          key: const ValueKey('unassigned-link'),
                          onTap: () => setState(() => _showUnassigned = true),
                          builder: (context, hover) => AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: _showUnassigned
                                  ? p.selected
                                  : (hover ? p.hover : Colors.transparent),
                              borderRadius: BorderRadius.circular(Radii.lg),
                              border: Border.all(
                                color: _showUnassigned
                                    ? p.text.withValues(alpha: 0.35)
                                    : Colors.transparent,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  CupertinoIcons.tray,
                                  size: 16,
                                  color: _showUnassigned ? p.text : p.textMuted,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '未归类 ${r.scan.unassigned.length} 个文件',
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w500,
                                            ),
                                      ),
                                      const SizedBox(height: 1),
                                      Text(
                                        unassignedDeletes > 0
                                            ? '其中 $unassignedDeletes 个垃圾文件将被永久删除'
                                            : '没归进任何作品，不会被整理',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: unassignedDeletes > 0
                                                  ? p.danger
                                                  : p.textMuted,
                                            ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Icon(
                                  CupertinoIcons.chevron_right,
                                  size: 12,
                                  color: p.textFaint,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 104),
                  ],
                ),
              ),
              SplitDivider(
                key: const ValueKey('split-divider-left'),
                onDragStart: () => _dragLeftWidth = effectiveLeft,
                onDragUpdate: (dx) {
                  final maxLeft = totalWidth.isFinite
                      ? math.min(
                          460.0,
                          math.max(
                            240.0,
                            totalWidth -
                                dividerTotal -
                                minCenterWidth -
                                effectiveRight,
                          ),
                        )
                      : 460.0;
                  setState(() {
                    _dragLeftWidth = ((_dragLeftWidth ?? effectiveLeft) + dx)
                        .clamp(240.0, maxLeft);
                  });
                },
                onDragEnd: () {
                  final committed = _dragLeftWidth;
                  if (committed != null) {
                    final clamped = committed.clamp(240.0, 460.0);
                    ref
                        .read(settingsProvider.notifier)
                        .update((s) => s.copyWith(reviewLeftWidth: clamped));
                  }
                  setState(() => _dragLeftWidth = null);
                },
              ),
              Expanded(
                child: _showUnassigned
                    ? Padding(
                        padding: const EdgeInsets.only(top: 12, bottom: 104),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                key: const ValueKey('return-to-works'),
                                onPressed: () => setState(_returnToWorks),
                                icon: const Icon(
                                  CupertinoIcons.chevron_left,
                                  size: 14,
                                ),
                                label: const Text('返回作品'),
                              ),
                            ),
                            Expanded(
                              child: UnassignedPane(
                                files: r.scan.unassigned,
                                plan: r.preview,
                                groups: r.scan.groups,
                                decisions: r.decisions,
                                onToggleDelete: _setUnassignedDelete,
                                onAssign: _assignUnassigned,
                              ),
                            ),
                          ],
                        ),
                      )
                    : g == null
                    ? const EmptyState(
                        icon: CupertinoIcons.rectangle_stack,
                        title: '选择左侧的作品查看明细',
                      )
                    : Padding(
                        padding: const EdgeInsets.only(top: 12, bottom: 104),
                        child: DetailPane(
                          group: g,
                          decision: r.decisions[g.id],
                          review: r,
                          tab: _detailTab,
                          onTab: (t) => setState(() => _detailTab = t),
                          onEdit: (row) => _editRow(g, row),
                          onCheck: (row, v) => _checkRow(g, row, v),
                          onShift: (row, to) => _shift(g, row, to),
                          showActions: _showActions,
                          onShowActions: () =>
                              setState(() => _showActions = true),
                          onCorrect: () => _correct(g),
                          onApplySuggestedStrategy: (strategy) => _update(
                            g.id,
                            _decisionOf(g.id).copyWith(strategy: strategy),
                          ),
                          onResolveKeepLargest: (dupConflicts) {
                            final d = _decisionOf(g.id);
                            _update(
                              g.id,
                              d.copyWith(
                                overrides: resolveKeepLargestOverrides(
                                  d,
                                  dupConflicts,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
              ),
              if (showRight) ...[
                SplitDivider(
                  key: const ValueKey('split-divider-right'),
                  onDragStart: () => _dragRightWidth = effectiveRight,
                  onDragUpdate: (dx) {
                    final maxRight = totalWidth.isFinite
                        ? math.min(
                            420.0,
                            math.max(
                              220.0,
                              totalWidth -
                                  dividerTotal -
                                  minCenterWidth -
                                  effectiveLeft,
                            ),
                          )
                        : 420.0;
                    setState(() {
                      _dragRightWidth =
                          ((_dragRightWidth ?? effectiveRight) - dx).clamp(
                            220.0,
                            maxRight,
                          );
                    });
                  },
                  onDragEnd: () {
                    final committed = _dragRightWidth;
                    if (committed != null) {
                      final clamped = committed.clamp(220.0, 420.0);
                      ref
                          .read(settingsProvider.notifier)
                          .update((s) => s.copyWith(reviewRightWidth: clamped));
                    }
                    setState(() => _dragRightWidth = null);
                  },
                ),
                Container(
                  key: const ValueKey('review-right-pane'),
                  width: effectiveRight,
                  padding: const EdgeInsets.only(bottom: 104),
                  // Own layer: stale strips were seen here while scrolling.
                  child: RepaintBoundary(
                    child: ActionPane(
                      key: ValueKey(g.id),
                      group: g,
                      decision: _decisionOf(g.id),
                      onChange: (d) => _update(g.id, d),
                      onCorrect: () => _correct(g),
                      onMergeGroup: canMerge ? () => _mergeGroup(g) : null,
                      onSplitGroup:
                          g.files
                                  .where((f) => f.role == FileRole.video)
                                  .length >=
                              2
                          ? () => _splitGroup(g)
                          : null,
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _bottomBar(TaskReview r) {
    final p = Palette.of(context);
    final conflicts = r.preview.conflicts.length;
    final merges = [
      for (final m in r.preview.merges)
        if (r.decisions[m.group]?.selected ?? true) m,
    ];
    final task = ref
        .watch(tasksProvider)
        .asData
        ?.value
        .where((t) => t.id == _id)
        .firstOrNull;
    final mode = task?.mode;
    final scrapeOnly = task?.scrapeOnly ?? false;
    final ops = r.preview.ops.where((o) => o.selected).length;
    String? blockedReason;
    if (_executing) {
      blockedReason = scrapeOnly ? '正在刮削，请稍候' : '正在整理，请稍候';
    } else if (_pendingUpdates > 0) {
      blockedReason = '正在更新整理计划，请稍候';
    } else if (conflicts > 0 && merges.isEmpty) {
      blockedReason = '存在冲突，请先处理';
    } else if (ops == 0) {
      final matched = r.scan.groups
          .where((g) => isMatched(g, r.decisions[g.id]))
          .toList();
      final selected = matched
          .where((g) => r.decisions[g.id]?.selected ?? true)
          .toList();
      if (matched.isEmpty) {
        blockedReason = '没有可整理的作品，请先手动匹配';
      } else if (selected.isEmpty) {
        blockedReason = '未勾选作品，请在左侧勾选';
      } else if (r.preview.ops.any((o) => o.warning != null)) {
        blockedReason = '有文件需要确认，请勾选文件或修正对应关系';
      } else if (selected.any(
        (g) => g.files.any(
          (f) =>
              f.role == FileRole.video &&
              !(r.decisions[g.id]?.overrides[f.path]?.ignore ?? false),
        ),
      )) {
        blockedReason = '没有可执行的改动，请检查文件对应关系';
      } else {
        blockedReason = '未选择可整理的文件，请勾选文件';
      }
    }
    final canStart = blockedReason == null;
    final conflictLabel = conflicts == 0
        ? '没有冲突'
        : merges.isNotEmpty
        ? '$conflicts 处冲突，点「开始整理」可分开保留'
        : '$conflicts 处冲突，处理后才能整理';
    final conflictWidget = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          conflicts == 0
              ? CupertinoIcons.checkmark_seal_fill
              : CupertinoIcons.exclamationmark_triangle_fill,
          size: 14,
          color: conflicts == 0 ? p.textFaint : p.danger,
        ),
        const SizedBox(width: 6),
        Text(
          conflictLabel,
          key: const ValueKey('conflict-count'),
          style: TextStyle(
            fontSize: TypeScale.small,
            color: conflicts == 0 ? p.textMuted : p.danger,
            fontWeight: conflicts == 0 ? null : FontWeight.w600,
            decoration: conflicts > 0 ? TextDecoration.underline : null,
            decorationColor: conflicts > 0 ? p.danger : null,
          ),
        ),
      ],
    );

    final bar = Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(Radii.bar),
        border: Border.all(color: p.line, width: hairline),
        boxShadow: floatShadow(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (scrapeOnly)
            Tag('仅刮削 · 保留原文件名', color: p.accent)
          else
            Segmented<OrganizeMode>(
              options: const {
                OrganizeMode.inPlace: '原地整理',
                OrganizeMode.moveToLibrary: '移动到媒体库',
              },
              value: mode ?? OrganizeMode.inPlace,
              onChanged: (v) async {
                setState(() => _pendingUpdates++);
                try {
                  final nr = await _tm.setMode(_id, v);
                  if (mounted) setState(() => _review = nr);
                } on Object catch (e) {
                  if (!mounted) return;
                  final msg = '$e'.contains('libraryRoot')
                      ? '这个连接还没设置媒体库，去「来源」编辑连接后再选'
                      : '没能切换整理方式，请重试';
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(SnackBar(content: Text(msg)));
                } finally {
                  if (mounted) setState(() => _pendingUpdates--);
                }
              },
            ),
          const SizedBox(width: 16),
          if (conflicts > 0)
            Tooltip(
              message: '点击定位到冲突文件',
              child: Hoverable(
                key: const ValueKey('conflict-jump'),
                onTap: () => _jumpToFirstConflict(r),
                builder: (_, hover) => Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: conflictWidget,
                ),
              ),
            )
          else
            conflictWidget,
          const SizedBox(width: 12),
          Text(
            '$ops 处改动',
            style: TextStyle(fontSize: TypeScale.small, color: p.textMuted),
          ),
          const SizedBox(width: 18),
          Tooltip(
            message: blockedReason ?? '⌘↩',
            child: FilledButton(
              key: const ValueKey('execute-button'),
              onPressed: canStart ? _execute : null,
              child: Text(scrapeOnly ? '开始刮削' : '开始整理'),
            ),
          ),
        ],
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        bar,
        if (blockedReason != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              blockedReason,
              key: const ValueKey('execute-disabled-reason'),
              style: TextStyle(fontSize: TypeScale.small, color: p.textMuted),
            ),
          ),
      ],
    );
  }
}
