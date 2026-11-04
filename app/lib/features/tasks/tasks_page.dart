import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../../widgets/common.dart';
import '../sources/sources_providers.dart';

/// Works recognized in a task (poster + title), once recognition is done.
final taskWorksProvider = FutureProvider.autoDispose
    .family<List<Candidate>, TaskId>((ref, id) async {
      final review = await ref.watch(taskManagerProvider).review(id);
      final seen = <int>{};
      return [
        for (final g in review.scan.groups)
          if ((review.decisions[g.id]?.match ?? g.match) case final m?)
            if (seen.add(m.tmdbId)) m,
      ];
    });

/// Files of a recognized task that joined no work (shown as 未归类).
final taskUnassignedProvider = FutureProvider.autoDispose.family<int, TaskId>(
  (ref, id) async =>
      (await ref.watch(taskManagerProvider).review(id)).scan.unassigned.length,
);

/// 任务中心（PLAN §5）.
class TasksPage extends ConsumerStatefulWidget {
  const TasksPage({super.key});

  @override
  ConsumerState<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends ConsumerState<TasksPage> {
  var _finished = false;

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(tasksProvider);
    final all = tasks.value ?? const <TaskSummary>[];
    final active = all.where((t) => t.stage.isActive).toList();
    final finished = all.where((t) => !t.stage.isActive).toList();
    final shown = _finished ? finished : active;
    return PageScaffold(
      title: '任务',
      subtitle: '扫描和识别在后台进行，识别完成后在这里确认和执行',
      maxWidth: 1000,
      actions: [
        if (_finished && finished.isNotEmpty)
          TextButton.icon(
            key: const ValueKey('clear-finished'),
            onPressed: () => confirmDeleteTask(context, ref, finished),
            icon: const Icon(CupertinoIcons.trash, size: 13),
            label: const Text('清空'),
          ),
        Segmented<bool>(
          options: {
            false: '进行中 (${active.length})',
            true: '已完成 (${finished.length})',
          },
          value: _finished,
          onChanged: (v) => setState(() => _finished = v),
        ),
      ],
      child: tasks.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: CupertinoIcons.exclamationmark_triangle,
          title: '无法读取任务',
          message: '$e',
        ),
        data: (_) => shown.isEmpty
            ? EmptyState(
                icon: _finished
                    ? CupertinoIcons.checkmark_seal
                    : CupertinoIcons.tray,
                title: _finished ? '还没有已完成的任务' : '没有进行中的任务',
                message: _finished ? null : '去「来源」选择文件夹，提交一个整理任务',
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(48, 14, 40, 28),
                children: [
                  if (!_finished) ...[
                    BigNumber(
                      '${active.where((t) => t.stage == TaskStage.awaitingReview).length}',
                      captions: const [Text('个待确认')],
                    ),
                    const SizedBox(height: 28),
                  ],
                  for (final (i, t) in shown.indexed)
                    FadeIn(
                      index: i,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 26),
                        child: TaskCard(task: t),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

const _steps = ['导入', '识别', '待确认', '文件', '文件夹'];

/// One line of progress while a stage runs.
String _runningLabel(TaskStage s, double? progress) {
  final what = switch (s) {
    TaskStage.importing => '正在导入',
    TaskStage.recognizing => '正在识别',
    TaskStage.renamingFiles => '正在改名文件',
    TaskStage.renamingFolders => '正在改名文件夹',
    _ => stageLabel(s),
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

String stageLabel(TaskStage s) => switch (s) {
  TaskStage.done => '已完成',
  TaskStage.partiallyFailed => '部分失败',
  TaskStage.cancelled => '已取消',
  TaskStage.undone => '已撤销',
  _ => _steps[_currentStep(s)],
};

class TaskCard extends ConsumerWidget {
  final TaskSummary task;

  const TaskCard({super.key, required this.task});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = task;
    final p = Palette.of(context);
    final theme = Theme.of(context);
    final tm = ref.read(taskManagerProvider);
    final connName = ref
        .watch(connectionsEditorProvider)
        .where((c) => c.id == t.connection)
        .map((c) => c.name)
        .firstOrNull;
    final recognized =
        t.stage.index >= TaskStage.awaitingReview.index &&
        t.stage != TaskStage.cancelled;
    final works = recognized
        ? ref.watch(taskWorksProvider(t.id)).value ?? const <Candidate>[]
        : const <Candidate>[];
    final unassigned = recognized
        ? ref.watch(taskUnassignedProvider(t.id)).value ?? 0
        : 0;
    final folder =
        t.paths.firstOrNull?.split('/').where((s) => s.isNotEmpty).lastOrNull ??
        '根目录';
    final title = works.isEmpty
        ? (t.paths.length > 1 ? '$folder 等 ${t.paths.length} 项' : folder)
        : works.length == 1
        ? works.single.title
        : '${works.first.title} 等 ${works.length} 部';
    final where = t.paths.length == 1
        ? t.paths.single
        : '${t.paths.length} 个文件夹';
    final statusColor = switch (t.stage) {
      TaskStage.awaitingReview => p.accent,
      TaskStage.done => p.success,
      TaskStage.partiallyFailed => p.warning,
      TaskStage.cancelled || TaskStage.undone => p.textFaint,
      _ => p.textMuted,
    };

    Future<void> runConfident() async {
      final ok = await confirmDialog(
        context,
        title: '立即执行',
        content: const Text('将只执行高置信、没有冲突的项，其余保持不动。确定执行吗？'),
        confirmLabel: '执行',
      );
      if (!ok) return;
      try {
        await tm.run(t.id, onlyConfident: true);
      } on StateError catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(e.message)));
        }
      }
    }

    Future<void> undo() => confirmUndo(context, ref, t.id);

    List<MenuAction?> menu() => [
      MenuAction(
        '打开详情',
        () => context.go('/tasks/${t.id.value}'),
        icon: CupertinoIcons.doc_text,
      ),
      if (t.stage == TaskStage.awaitingReview) ...[
        MenuAction(
          '去确认',
          () => context.go('/tasks/${t.id.value}/review'),
          icon: CupertinoIcons.eye,
        ),
        MenuAction('立即执行', runConfident, icon: CupertinoIcons.play),
      ],
      if (t.stage == TaskStage.partiallyFailed)
        MenuAction('重试失败项', () async {
          try {
            await tm.retryFailed(t.id);
          } on StateError catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(content: Text(e.message)));
            }
          }
        }, icon: CupertinoIcons.arrow_clockwise),
      if (t.stage == TaskStage.done || t.stage == TaskStage.partiallyFailed)
        MenuAction('撤销', undo, icon: CupertinoIcons.arrow_uturn_left),
      if (t.stage.isActive)
        MenuAction('取消', () => tm.cancel(t.id), icon: CupertinoIcons.stop),
      null,
      MenuAction('复制任务 ID', () {
        Clipboard.setData(ClipboardData(text: t.id.value));
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已复制任务 ID')));
      }, icon: CupertinoIcons.doc_on_clipboard),
      if (canDeleteTask(t))
        MenuAction(
          '删除记录',
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
      '导入 ${t.importedCount}',
      '视频 ${t.videoCount}',
      '文件夹 ${t.folderCount}',
      '字幕 ${t.subtitleCount}',
      if (unassigned > 0) '未归类 $unassigned',
    ].join(' · ');

    return ContextMenuArea(
      items: menu,
      child: Hoverable(
        key: ValueKey('task ${t.id.value}'),
        onTap: () => context.go(target),
        builder: (context, hover) => Column(
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
                      fontSize: 16,
                      color: p.text,
                      decoration: hover ? TextDecoration.underline : null,
                      decorationColor: p.textFaint,
                    ),
                  ),
                ),
                const Spacer(),
                MoreButton(items: menu),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Flexible(
                  child: Tooltip(
                    message: t.paths.join('\n'),
                    child: Text(
                      [
                        connName ?? t.connection.value,
                        where,
                        t.mode == OrganizeMode.inPlace ? '原地整理' : '移动到媒体库',
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Tooltip(
                  message: '点击复制任务 ID',
                  child: Hoverable(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: t.id.value));
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('已复制任务 ID')));
                    },
                    builder: (context, hover) => Text(
                      t.id.value,
                      style: TextStyle(
                        fontFamily: monoFamily,
                        fontFamilyFallback: monoFallback,
                        fontSize: 11.5,
                        color: hover ? p.text : p.textMuted,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (works.length > 1) ...[
              const SizedBox(height: 2),
              Text(
                works.map((w) => w.title).join('、'),
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                if (running) ...[
                  const Spinner(size: 12),
                  const SizedBox(width: 6),
                ],
                Text(
                  running
                      ? _runningLabel(t.stage, t.progress)
                      : stageLabel(t.stage),
                  style: TextStyle(fontSize: 12.5, color: statusColor),
                ),
                if (t.message.isNotEmpty) ...[
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      t.message,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: p.textMuted),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 2),
            Text(counts, style: TextStyle(fontSize: 11.5, color: p.textMuted)),
            if (running ||
                t.stage == TaskStage.awaitingReview ||
                t.stage == TaskStage.done ||
                t.stage == TaskStage.partiallyFailed) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  if (t.stage == TaskStage.awaitingReview) ...[
                    OutlinedButton(
                      onPressed: () =>
                          context.go('/tasks/${t.id.value}/review'),
                      child: const Text('去确认'),
                    ),
                    const SizedBox(width: 4),
                    TextButton(
                      onPressed: runConfident,
                      child: const Text('立即执行'),
                    ),
                  ],
                  if (running)
                    TextButton(
                      onPressed: () => tm.cancel(t.id),
                      child: const Text('取消'),
                    ),
                  if (t.stage == TaskStage.done ||
                      t.stage == TaskStage.partiallyFailed)
                    TextButton(onPressed: undo, child: const Text('撤销')),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Not importing, recognizing or executing (those must be cancelled first).
bool canDeleteTask(TaskSummary t) =>
    !t.stage.isActive || t.stage == TaskStage.awaitingReview;

/// Deletes task records after confirmation. Returns whether it did.
Future<bool> confirmDeleteTask(
  BuildContext context,
  WidgetRef ref,
  List<TaskSummary> tasks,
) async {
  final undoable = tasks.any(
    (t) => t.stage == TaskStage.done || t.stage == TaskStage.partiallyFailed,
  );
  final ok = await confirmDialog(
    context,
    title: tasks.length == 1 ? '删除任务记录' : '清空 ${tasks.length} 条任务记录',
    content: Text(
      '只删除理片里的记录，不会动网盘或磁盘上的文件。'
      '${undoable ? '\n删除后就不能再撤销这些任务做过的改名了。' : ''}',
    ),
    confirmLabel: '删除',
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
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
    return false;
  }
  return true;
}

/// Undo a whole task after confirmation.
Future<void> confirmUndo(BuildContext context, WidgetRef ref, TaskId id) async {
  final ok = await confirmDialog(
    context,
    title: '撤销整批',
    content: const Text('将把这个任务改过的文件恢复成原来的名字和位置。确定撤销吗？'),
    confirmLabel: '撤销',
    destructive: true,
  );
  if (!ok || !context.mounted) return;
  try {
    await ref.read(taskManagerProvider).undo(id);
  } on StateError catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}
