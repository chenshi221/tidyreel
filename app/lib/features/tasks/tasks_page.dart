import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../l10n/l10n.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../../widgets/common.dart';
import '../sources/sources_providers.dart';

/// Shared review summary (works + unassigned count) so [taskWorksProvider] and
/// [taskUnassignedProvider] never call `review()` twice for the same task.
final _taskReviewMetaProvider = FutureProvider.autoDispose
    .family<({List<Candidate> works, int unassigned}), TaskId>((ref, id) async {
      ref.watch(
        tasksProvider.select(
          (a) => a.value?.where((t) => t.id == id).firstOrNull?.stage,
        ),
      );
      final review = await ref.watch(taskManagerProvider).review(id);
      final seen = <int>{};
      final works = [
        for (final g in review.scan.groups)
          if ((review.decisions[g.id]?.match ?? g.match) case final m?)
            if (seen.add(m.tmdbId)) m,
      ];
      return (works: works, unassigned: review.scan.unassigned.length);
    });

/// Works recognized in a task (poster + title), once recognition is done.
final taskWorksProvider = FutureProvider.autoDispose
    .family<List<Candidate>, TaskId>(
      (ref, id) async =>
          (await ref.watch(_taskReviewMetaProvider(id).future)).works,
    );

/// Files of a recognized task that joined no work (shown as 未归类).
final taskUnassignedProvider = FutureProvider.autoDispose.family<int, TaskId>(
  (ref, id) async =>
      (await ref.watch(_taskReviewMetaProvider(id).future)).unassigned,
);

/// Whether an error message indicates a missing or invalid TMDB API key.
bool isTmdbKeyError(String message) {
  final low = message.toLowerCase();
  return low.contains('tmdb') &&
      (low.contains('api') || low.contains('key') || low.contains('密钥'));
}

/// 任务中心（PLAN §5）.
class TasksPage extends ConsumerStatefulWidget {
  const TasksPage({super.key});

  @override
  ConsumerState<TasksPage> createState() => _TasksPageState();
}

enum _Filter { all, active, finished }

class _TasksPageState extends ConsumerState<TasksPage> {
  var _filter = _Filter.all;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tasks = ref.watch(tasksProvider);
    final all = tasks.value ?? const <TaskSummary>[];
    final active = all.where((t) => t.stage.isActive).toList();
    final finished = all.where((t) => !t.stage.isActive).toList();
    final waiting = active
        .where((t) => t.stage == TaskStage.awaitingReview)
        .length;

    Widget section(String? title, List<TaskSummary> list) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null) SectionLabel(title),
        Panel(
          child: Rows(
            indent: 70,
            children: [
              for (final (i, t) in list.indexed)
                FadeIn(
                  index: i,
                  child: TaskCard(task: t),
                ),
            ],
          ),
        ),
      ],
    );

    final showActive = _filter != _Filter.finished && active.isNotEmpty;
    final showFinished = _filter != _Filter.active && finished.isNotEmpty;
    return PageScaffold(
      title: l10n.tr('任务', 'Tasks'),
      actions: [
        if (showFinished)
          TextButton.icon(
            key: const ValueKey('clear-finished'),
            onPressed: () => confirmDeleteTask(context, ref, finished),
            icon: const Icon(CupertinoIcons.trash, size: 13),
            label: Text(l10n.tr('清空已完成', 'Clear Finished')),
          ),
        Segmented<_Filter>(
          options: {
            _Filter.all: l10n.tr('全部 ${all.length}', 'All ${all.length}'),
            _Filter.active: l10n.tr(
              '进行中 ${active.length}',
              'Active ${active.length}',
            ),
            _Filter.finished: l10n.tr(
              '已完成 ${finished.length}',
              'Done ${finished.length}',
            ),
          },
          value: _filter,
          onChanged: (v) => setState(() => _filter = v),
        ),
      ],
      child: tasks.when(
        loading: () => const Center(child: Spinner(size: 20)),
        error: (e, _) => EmptyState(
          icon: CupertinoIcons.exclamationmark_triangle,
          title: l10n.tr('无法读取任务', 'Unable to Load Tasks'),
          message: l10n.coreMessage('$e'),
        ),
        data: (_) => !showActive && !showFinished
            ? EmptyState(
                icon: _filter == _Filter.finished
                    ? CupertinoIcons.checkmark_seal
                    : CupertinoIcons.tray,
                title: switch (_filter) {
                  _Filter.all => l10n.tr('还没有任务', 'No Tasks Yet'),
                  _Filter.active => l10n.tr('没有进行中的任务', 'No Active Tasks'),
                  _Filter.finished => l10n.tr(
                    '还没有已完成的任务',
                    'No Completed Tasks',
                  ),
                },
                message: _filter == _Filter.finished
                    ? null
                    : l10n.tr(
                        '去「来源」选一个文件夹开始整理',
                        'Pick a folder in Sources to start organizing',
                      ),
                action: _filter == _Filter.finished
                    ? null
                    : OutlinedButton(
                        onPressed: () => context.go('/sources'),
                        child: Text(
                          l10n.tr('去「来源」选择文件夹', 'Choose Folder in Sources'),
                        ),
                      ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(48, 0, 40, 28),
                children: [
                  if (waiting > 0 && _filter != _Filter.finished)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 6),
                      child: BigNumber(
                        '$waiting',
                        captions: [
                          Text(
                            l10n.tr(
                              '个待确认',
                              waiting == 1
                                  ? 'awaiting review'
                                  : 'awaiting review',
                            ),
                          ),
                        ],
                      ),
                    ),
                  // Sections only when both are on screen.
                  if (showActive)
                    section(
                      showFinished ? l10n.tr('进行中', 'Active') : null,
                      active,
                    ),
                  if (showFinished)
                    section(
                      showActive ? l10n.tr('已完成', 'Completed') : null,
                      finished,
                    ),
                ],
              ),
      ),
    );
  }
}

List<String> _stepsFor(AppL10n l10n) => [
  l10n.tr('导入', 'Import'),
  l10n.tr('识别', 'Match'),
  l10n.tr('确认', 'Review'),
  l10n.tr('重命名', 'Rename'),
  l10n.tr('整理文件夹', 'Folders'),
];

/// One line of progress while a stage runs.
String _runningLabel(TaskStage s, double? progress, AppL10n l10n) {
  final what = switch (s) {
    TaskStage.importing => l10n.tr('正在导入', 'Importing'),
    TaskStage.recognizing => l10n.tr('正在识别', 'Matching'),
    TaskStage.renamingFiles => l10n.tr('正在重命名文件', 'Renaming files'),
    TaskStage.renamingFolders => l10n.tr('正在整理文件夹', 'Organizing folders'),
    _ => stageLabel(s, l10n),
  };
  return progress == null ? what : '$what ${(progress * 100).round()}%';
}

/// Index of the step currently running; 5 = all complete; -1 = none (stopped).
int _currentStep(TaskStage s) => switch (s) {
  TaskStage.importing => 0,
  TaskStage.recognizing => 1,
  TaskStage.awaitingReview => 2,
  TaskStage.renamingFiles => 3,
  TaskStage.renamingFolders => 4,
  TaskStage.done || TaskStage.partiallyFailed => 5,
  _ => -1,
};

String stageLabel(TaskStage s, [AppL10n l10n = AppL10n.zh]) => switch (s) {
  TaskStage.done => l10n.tr('已完成', 'Done'),
  TaskStage.partiallyFailed => l10n.tr('部分失败', 'Partial'),
  TaskStage.cancelled => l10n.tr('已取消', 'Cancelled'),
  TaskStage.undone => l10n.tr('已撤销', 'Undone'),
  TaskStage.failed => l10n.tr('失败', 'Failed'),
  TaskStage.awaitingReview => l10n.tr('待确认', 'Review'),
  TaskStage.renamingFiles => l10n.tr('正在重命名文件', 'Renaming files'),
  TaskStage.renamingFolders => l10n.tr('正在整理文件夹', 'Organizing folders'),
  _ => _stepsFor(l10n)[_currentStep(s)],
};

/// Color for a task's status pill.
Color taskStatusColor(TaskStage stage, Palette p) => switch (stage) {
  TaskStage.awaitingReview => p.accent,
  TaskStage.done => p.success,
  TaskStage.partiallyFailed => p.warning,
  TaskStage.failed => p.danger,
  TaskStage.cancelled || TaskStage.undone => p.textFaint,
  _ => p.textMuted,
};

/// Whether recognition produced works that can be read via [taskWorksProvider].
bool isTaskRecognized(TaskSummary t) =>
    t.stage.index >= TaskStage.awaitingReview.index &&
    t.stage != TaskStage.cancelled &&
    t.stage != TaskStage.failed;

/// Tracks task IDs with an in-flight user action (undo / retry / runConfident)
/// so rapid double-clicks don't fire duplicate operations.
final _busyTasks = <TaskId>{};

Future<void> retryFailedTask(
  BuildContext context,
  WidgetRef ref,
  TaskId id,
) async {
  if (!_busyTasks.add(id)) return;
  try {
    await ref.read(taskManagerProvider).retryFailed(id);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(context.tr('已重试失败项', 'Retrying failed operations')),
          ),
        );
    }
  } on StateError catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(context.trCore(e.message))));
    }
  } finally {
    _busyTasks.remove(id);
  }
}

class TaskCard extends ConsumerWidget {
  final TaskSummary task;

  const TaskCard({super.key, required this.task});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = task;
    final p = Palette.of(context);
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final tm = ref.read(taskManagerProvider);
    final connName = ref
        .watch(connectionsEditorProvider)
        .where((c) => c.id == t.connection)
        .map((c) => c.name)
        .firstOrNull;
    final recognized = isTaskRecognized(t);
    final meta = recognized
        ? ref.watch(_taskReviewMetaProvider(t.id)).value
        : null;
    final works = meta?.works ?? const <Candidate>[];
    final unassigned = meta?.unassigned ?? 0;
    final folder =
        t.paths.firstOrNull?.split('/').where((s) => s.isNotEmpty).lastOrNull ??
        l10n.rootDir;
    final title = works.isEmpty
        ? (t.paths.length > 1
              ? l10n.tr(
                  '$folder 等 ${t.paths.length} 项',
                  '$folder + ${t.paths.length - 1} more',
                )
              : folder)
        : works.length == 1
        ? works.single.title
        : l10n.tr(
            '${works.first.title} 等 ${works.length} 部',
            '${works.first.title} + ${works.length - 1} more',
          );
    final where = t.paths.length == 1
        ? t.paths.single
        : l10n.tr(
            '${t.paths.length} 个文件夹',
            l10n.plural(t.paths.length, 'folder'),
          );
    final statusColor = taskStatusColor(t.stage, p);

    Future<void> runConfident() async {
      if (!_busyTasks.add(t.id)) return;
      try {
        // Deletes of uncertain works are dropped by the run, so this may
        // over-count; asking too often beats deleting unasked.
        final ops = (await tm.review(t.id)).preview.ops;
        final deletes = ops
            .where(
              (o) => o.selected && o.kind == OpKind.delete && o.warning == null,
            )
            .length;
        if (deletes > 0 && context.mounted) {
          if (!await confirmPermanentDelete(context, deletes)) return;
        }
        await tm.run(t.id, onlyConfident: true);
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  context.tr(
                    '已开始整理有把握的项目',
                    'Started organizing confident matches',
                  ),
                ),
              ),
            );
        }
      } on StateError catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(context.trCore(e.message))));
        }
      } finally {
        _busyTasks.remove(t.id);
      }
    }

    Future<void> undo() => undoTask(context, ref, t.id);

    List<MenuAction?> menu() => [
      MenuAction(
        l10n.tr('打开详情', 'Open Details'),
        () => context.go('/tasks/${t.id.value}'),
        icon: CupertinoIcons.doc_text,
      ),
      if (t.stage == TaskStage.awaitingReview) ...[
        MenuAction(
          l10n.tr('去确认', 'Review'),
          () => context.go('/tasks/${t.id.value}/review'),
          icon: CupertinoIcons.eye,
        ),
        MenuAction(
          l10n.tr('只整理有把握的', 'Organize Confident Only'),
          runConfident,
          icon: CupertinoIcons.play,
        ),
      ],
      if (t.stage == TaskStage.partiallyFailed)
        MenuAction(
          l10n.tr('重试失败项', 'Retry Failed'),
          () => retryFailedTask(context, ref, t.id),
          icon: CupertinoIcons.arrow_clockwise,
        ),
      if (canUndo(t))
        MenuAction(l10n.undo, undo, icon: CupertinoIcons.arrow_uturn_left),
      if (canRetry(t))
        MenuAction(
          l10n.tr('重新识别', 'Re-match'),
          () => retryTask(context, ref, t.id),
          icon: CupertinoIcons.arrow_clockwise,
        ),
      if (t.stage.isActive)
        MenuAction(
          l10n.cancel,
          () => tm.cancel(t.id),
          icon: CupertinoIcons.stop,
        ),
      null,
      MenuAction(l10n.tr('复制任务 ID', 'Copy Task ID'), () {
        Clipboard.setData(ClipboardData(text: t.id.value));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.tr('已复制任务 ID', 'Task ID copied'))),
        );
      }, icon: CupertinoIcons.doc_on_clipboard),
      if (canDeleteTask(t))
        MenuAction(
          l10n.tr('删除记录', 'Delete Record'),
          () => confirmDeleteTask(context, ref, [t]),
          icon: CupertinoIcons.trash,
          destructive: true,
        ),
    ];

    // Awaiting review opens the review page; anything else its details.
    final target = t.stage == TaskStage.awaitingReview
        ? '/tasks/${t.id.value}/review'
        : '/tasks/${t.id.value}';

    final running = t.stage.isActive && t.stage != TaskStage.awaitingReview;
    final counts = [
      l10n.tr('${t.videoCount} 个视频', l10n.plural(t.videoCount, 'video')),
      if (t.subtitleCount > 0)
        l10n.tr(
          '${t.subtitleCount} 个字幕',
          l10n.plural(t.subtitleCount, 'subtitle'),
        ),
      if (t.folderCount > 0)
        l10n.tr('${t.folderCount} 个文件夹', l10n.plural(t.folderCount, 'folder')),
      if (unassigned > 0) l10n.tr('$unassigned 个未归类', '$unassigned unassigned'),
    ].join(l10n.isEn ? ', ' : '，');
    // Why a task stopped short; progress messages are the stepper's job.
    final problem =
        t.message.isNotEmpty &&
            (t.stage == TaskStage.failed ||
                t.stage == TaskStage.cancelled ||
                t.stage == TaskStage.partiallyFailed ||
                t.message.startsWith('已撤销部分操作'))
        ? l10n.coreMessage(t.message)
        : null;
    final needsTmdbKey =
        t.stage == TaskStage.failed && isTmdbKeyError(t.message);

    return ContextMenuArea(
      items: menu,
      child: Hoverable(
        key: ValueKey('task ${t.id.value}'),
        onTap: () => context.go(target),
        builder: (context, hover) => Container(
          color: hover ? p.hover : Colors.transparent,
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            children: [
              Poster(
                posterPath: works.firstOrNull?.posterPath,
                icon: CupertinoIcons.folder,
                width: 64,
                height: 96,
                radius: Radii.sm,
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: p.text,
                            ),
                          ),
                        ),
                        if (t.scrapeOnly) ...[
                          const SizedBox(width: 8),
                          Tag(
                            l10n.tr('仅刮削', 'Scrape Only'),
                            key: ValueKey('scrape-only-${t.id.value}'),
                            color: p.accent,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Tooltip(
                      message: t.paths.join('\n'),
                      child: Text(
                        [
                          connName ?? t.connection.value,
                          if (!t.scrapeOnly) l10n.organizeModeLabel(t.mode),
                          if (t.scrape && !t.scrapeOnly)
                            l10n.tr('刮削', 'Scrape'),
                          if (recognized) counts else where,
                        ].join(l10n.isEn ? ' · ' : '，'),
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (problem != null) ...[
                      const SizedBox(height: 3),
                      Tooltip(
                        message: problem,
                        child: Text(
                          problem,
                          style: TextStyle(
                            fontSize: 12,
                            color: t.stage == TaskStage.failed
                                ? p.danger
                                : p.warning,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    if (works.length > 1) ...[
                      const SizedBox(height: 3),
                      Text(
                        works.map((w) => w.title).join(l10n.isEn ? ', ' : '、'),
                        style: TextStyle(fontSize: 12, color: p.textFaint),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    // Finished tasks need no track: the status says it.
                    if (t.stage.isActive && _currentStep(t.stage) >= 0) ...[
                      const SizedBox(height: 8),
                      TaskStepper(
                        stage: t.stage,
                        progress: t.progress,
                        running: running,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 16),
              StatusPill(
                label: running
                    ? _runningLabel(t.stage, t.progress, l10n)
                    : stageLabel(t.stage, l10n),
                color: statusColor,
                busy: running,
              ),
              const SizedBox(width: 12),
              if (t.stage == TaskStage.awaitingReview) ...[
                TextButton(
                  onPressed: runConfident,
                  child: Text(l10n.tr('只整理有把握的', 'Confident Only')),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  onPressed: () => context.go('/tasks/${t.id.value}/review'),
                  child: Text(l10n.tr('去确认', 'Review')),
                ),
              ],
              if (running)
                TextButton(
                  onPressed: () => tm.cancel(t.id),
                  child: Text(l10n.cancel),
                ),
              if (t.stage == TaskStage.partiallyFailed)
                TextButton(
                  key: ValueKey('retry-failed ${t.id.value}'),
                  onPressed: () => retryFailedTask(context, ref, t.id),
                  child: Text(l10n.tr('重试失败项', 'Retry Failed')),
                ),
              if (canUndo(t))
                TextButton(onPressed: undo, child: Text(l10n.undo)),
              if (needsTmdbKey)
                TextButton(
                  key: ValueKey('goto-settings ${t.id.value}'),
                  onPressed: () => context.go('/settings'),
                  child: Text(l10n.tr('去设置', 'Settings')),
                ),
              // A failed or cancelled recognition is the common retry case;
              // undone ones keep it in the menu.
              if ((t.stage == TaskStage.cancelled ||
                      t.stage == TaskStage.failed) &&
                  canRetry(t))
                TextButton(
                  key: ValueKey('retry ${t.id.value}'),
                  onPressed: () => retryTask(context, ref, t.id),
                  child: Text(l10n.tr('重新识别', 'Re-match')),
                ),
              const SizedBox(width: 2),
              MoreButton(items: menu),
            ],
          ),
        ),
      ),
    );
  }
}

/// 导入 → 识别 → 待确认 → 文件 → 文件夹 as a segmented track under a task:
/// done steps filled, the current one moving while it runs (by its progress
/// when it reports one); all filled once finished.
class TaskStepper extends StatelessWidget {
  final TaskStage stage;
  final double? progress;

  /// The current step is moving; otherwise it just stands highlighted.
  final bool running;

  const TaskStepper({
    super.key,
    required this.stage,
    this.progress,
    this.running = true,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final steps = _stepsFor(context.l10n);
    final cur = _currentStep(stage);
    return Row(
      children: [
        for (var i = 0; i < steps.length; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: SizedBox(
                    height: 3,
                    width: double.infinity,
                    child: i == cur && !running
                        ? ColoredBox(color: p.text)
                        : i == cur && progress != null
                        ? GradientProgress(
                            value: progress!,
                            color: p.text,
                            height: 3,
                          )
                        : i == cur
                        ? LinearProgressIndicator(
                            minHeight: 3,
                            color: p.text,
                            backgroundColor: p.text.withValues(alpha: 0.12),
                          )
                        : ColoredBox(
                            color: i < cur
                                ? p.text.withValues(alpha: 0.7)
                                : p.selected,
                          ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  steps[i],
                  style: TextStyle(
                    fontSize: TypeScale.small,
                    fontWeight: i == cur ? FontWeight.w600 : FontWeight.w400,
                    color: i == cur
                        ? p.text
                        : (i < cur ? p.textMuted : p.textFaint),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Not importing, recognizing or executing (those must be cancelled first).
/// [TaskManager.retry] with its error as a toast.
Future<void> retryTask(BuildContext context, WidgetRef ref, TaskId id) async {
  try {
    await ref.read(taskManagerProvider).retry(id);
  } on StateError catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(context.trCore(e.message))));
    }
  }
}

bool canDeleteTask(TaskSummary t) =>
    !t.stage.isActive || t.stage == TaskStage.awaitingReview;

/// Deletes task records after confirmation. Returns whether it did.
Future<bool> confirmDeleteTask(
  BuildContext context,
  WidgetRef ref,
  List<TaskSummary> tasks,
) async {
  final l10n = context.l10n;
  final undoable = tasks.any(canUndo);
  final ok = await confirmDialog(
    context,
    title: tasks.length == 1
        ? l10n.tr('删除任务记录', 'Delete Task Record')
        : l10n.tr(
            '清空 ${tasks.length} 条任务记录',
            'Clear ${l10n.plural(tasks.length, 'Task Record')}',
          ),
    content: Text(
      l10n.tr(
        '只删除理片里的记录，不会动网盘或磁盘上的文件。'
            '${undoable ? '删除后这些任务就不能再撤销了。' : ''}',
        'Only records inside Tidyreel are removed; your files stay untouched.'
            '${undoable ? ' Once deleted, these tasks can no longer be undone.' : ''}',
      ),
    ),
    confirmLabel: l10n.delete,
    destructive: true,
  );
  if (!ok) return false;
  final tm = ref.read(taskManagerProvider);
  try {
    for (final t in tasks) {
      await tm.delete(t.id);
    }
  } on StateError catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.trCore(e.message))));
    }
    return false;
  }
  return true;
}

/// Undo a whole task. No confirmation: undoing only restores names and
/// places, and the task can be recognized and run again afterwards.
Future<void> undoTask(BuildContext context, WidgetRef ref, TaskId id) async {
  if (!_busyTasks.add(id)) return;
  try {
    await ref.read(taskManagerProvider).undo(id);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(context.tr('已撤销', 'Undone'))));
    }
  } on StateError catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(context.trCore(e.message))));
    }
  } finally {
    _busyTasks.remove(id);
  }
}
