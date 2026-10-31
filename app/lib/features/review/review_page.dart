import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../widgets/common.dart';
import 'review_logic.dart';
import 'review_panes.dart';

/// 识别结果三栏页（PLAN §5）.
class ReviewPage extends ConsumerStatefulWidget {
  final String taskId;

  const ReviewPage({super.key, required this.taskId});

  @override
  ConsumerState<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends ConsumerState<ReviewPage>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 2, vsync: this);
  final _searchFocus = FocusNode();
  final _search = TextEditingController();
  TaskReview? _review;
  Object? _error;
  GroupId? _selected;
  int _detailTab =
      folderTab - 1; // "unset": DetailPane falls back to first season

  TaskId get _id => TaskId(widget.taskId);
  TaskManager get _tm => ref.read(taskManagerProvider);

  @override
  void initState() {
    super.initState();
    _tabs.addListener(() => setState(() => _selectFirstVisible()));
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
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

  List<MediaGroup> get _visible => _groups(matched: _tabs.index == 0);

  void _selectFirstVisible() {
    final v = _visible;
    if (!v.any((g) => g.id == _selected)) _selected = v.firstOrNull?.id;
  }

  MediaGroup? get _selectedGroup =>
      _review?.scan.groups.where((g) => g.id == _selected).firstOrNull;

  // ---- mutations

  Future<void> _update(GroupId id, GroupDecision d) async {
    final r = await _tm.updateDecision(_id, id, d);
    if (!mounted) return;
    setState(() {
      _review = r;
      _selectFirstVisible();
    });
  }

  GroupDecision _decisionOf(GroupId id) =>
      _review!.decisions[id] ?? const GroupDecision();

  Future<void> _editRow(MediaGroup g, ReviewRow row) async {
    final o = await showEditRowDialog(context, g, row);
    if (o == null) return;
    final d = _decisionOf(g.id);
    await _update(
      g.id,
      d.copyWith(overrides: {...d.overrides, row.file.path: o}),
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
    );
    if (c != null) await _update(g.id, _decisionOf(g.id).copyWith(match: c));
  }

  Future<void> _execute() async {
    final r = _review;
    if (r == null || r.preview.conflicts.isNotEmpty) return;
    final ops = r.preview.ops.where((o) => o.selected).toList();
    int n(ExecPhase p) => ops.where((o) => o.phase == p).length;
    final groups = r.decisions.values.where((d) => d.selected).length;
    final ok = await confirmDialog(
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
    if (!ok || !mounted) return;
    final router = GoRouter.of(context);
    await _tm.run(_id);
    router.go('/tasks');
  }

  // ---- keyboard: ↑↓ groups, space toggles, ⌘F search, ⌘↩ execute

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
    if (cmd && k == LogicalKeyboardKey.enter) {
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
        setState(() => _selected = v[next].id);
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
    final r = _review;
    return PageScaffold(
      title: '识别结果 · ${widget.taskId}',
      leading: IconButton(
        tooltip: '返回任务',
        icon: const Icon(Icons.arrow_back),
        onPressed: () => context.go('/tasks'),
      ),
      child: _error != null
          ? Center(child: Text('无法读取识别结果：$_error'))
          : r == null
          ? const Center(child: CircularProgressIndicator())
          : Focus(
              autofocus: true,
              onKeyEvent: _onKey,
              child: Column(
                children: [
                  const Divider(height: 1),
                  Expanded(child: _body(r)),
                  _bottomBar(r),
                ],
              ),
            ),
    );
  }

  Widget _body(TaskReview r) {
    final g = _selectedGroup;
    return Row(
      children: [
        SizedBox(
          width: 360,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: TextField(
                  key: const ValueKey('review-search'),
                  controller: _search,
                  focusNode: _searchFocus,
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜索作品 (⌘F)',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(_selectFirstVisible),
                ),
              ),
              TabBar(
                controller: _tabs,
                tabs: [
                  Tab(text: '可整理 (${_groups(matched: true).length})'),
                  Tab(text: '待手动识别 (${_groups(matched: false).length})'),
                ],
              ),
              Expanded(
                child: GroupList(
                  groups: _visible,
                  review: r,
                  selected: _selected,
                  onSelect: (id) => setState(() {
                    _selected = id;
                    _detailTab = folderTab - 1;
                  }),
                  onCheck: (id, v) =>
                      _update(id, _decisionOf(id).copyWith(selected: v)),
                  onPick: (grp, c) =>
                      _update(grp.id, _decisionOf(grp.id).copyWith(match: c)),
                ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: g == null
              ? const Center(child: Text('选择左侧的作品查看明细'))
              : DetailPane(
                  group: g,
                  decision: r.decisions[g.id],
                  review: r,
                  tab: _detailTab,
                  onTab: (t) => setState(() => _detailTab = t),
                  onEdit: (row) => _editRow(g, row),
                  onCheck: (row, v) => _checkRow(g, row, v),
                ),
        ),
        const VerticalDivider(width: 1),
        SizedBox(
          width: 300,
          child: g == null
              ? const SizedBox.shrink()
              : ActionPane(
                  key: ValueKey(g.id),
                  group: g,
                  decision: _decisionOf(g.id),
                  onChange: (d) => _update(g.id, d),
                  onCorrect: () => _correct(g),
                ),
        ),
      ],
    );
  }

  Widget _bottomBar(TaskReview r) {
    final scheme = Theme.of(context).colorScheme;
    final conflicts = r.preview.conflicts.length;
    final mode = ref
        .watch(tasksProvider)
        .asData
        ?.value
        .where((t) => t.id == _id)
        .map((t) => t.mode)
        .firstOrNull;
    return Material(
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Row(
          children: [
            SegmentedButton<OrganizeMode>(
              segments: const [
                ButtonSegment(value: OrganizeMode.inPlace, label: Text('原地整理')),
                ButtonSegment(
                  value: OrganizeMode.moveToLibrary,
                  label: Text('移动到媒体库'),
                ),
              ],
              selected: {mode ?? OrganizeMode.inPlace},
              onSelectionChanged: (v) async {
                final nr = await _tm.setMode(_id, v.first);
                if (mounted) setState(() => _review = nr);
              },
            ),
            const SizedBox(width: 24),
            Text(
              conflicts == 0 ? '没有冲突' : '$conflicts 处冲突，需处理后才能执行',
              key: const ValueKey('conflict-count'),
              style: TextStyle(
                color: conflicts == 0 ? scheme.onSurfaceVariant : scheme.error,
                fontWeight: conflicts == 0 ? null : FontWeight.bold,
              ),
            ),
            const Spacer(),
            FilledButton.icon(
              key: const ValueKey('execute-button'),
              onPressed: conflicts == 0 ? _execute : null,
              icon: const Icon(Icons.play_arrow),
              label: const Text('执行任务 (⌘↩)'),
            ),
          ],
        ),
      ),
    );
  }
}
