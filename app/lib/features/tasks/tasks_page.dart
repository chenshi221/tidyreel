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
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(28, 14, 28, 28),
                itemCount: shown.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, i) => FadeIn(
                  index: i,
                  child: TaskCard(task: shown[i]),
                ),
              ),
      ),
    );
  }
}

const _steps = ['导入', '识别', '待确认', '文件', '文件夹'];

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
    final (statusColor, statusIcon) = switch (t.stage) {
      TaskStage.awaitingReview => (p.accent, CupertinoIcons.eye),
      TaskStage.done => (p.success, CupertinoIcons.checkmark_circle_fill),
      TaskStage.partiallyFailed => (
        p.warning,
        CupertinoIcons.exclamationmark_triangle_fill,
      ),
      TaskStage.cancelled ||
      TaskStage.undone => (p.textFaint, CupertinoIcons.arrow_uturn_left_circle),
      _ => (p.textMuted, CupertinoIcons.hourglass),
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
        MenuAction(
          '重试失败项',
          () => tm.retryFailed(t.id),
          icon: CupertinoIcons.arrow_clockwise,
        ),
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
    final body = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PosterStack(works: works, stage: t.stage),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 10),
                  StatusPill(
                    label: stageLabel(t.stage),
                    color: statusColor,
                    busy: running,
                    icon: running ? null : statusIcon,
                  ),
                  const Spacer(),
                  MoreButton(items: menu),
                ],
              ),
              const SizedBox(height: 3),
              Row(
                children: [
                  Tooltip(
                    message: '点击复制任务 ID',
                    child: Hoverable(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: t.id.value));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制任务 ID')),
                        );
                      },
                      builder: (context, hover) => Text(
                        t.id.value,
                        style: TextStyle(
                          fontFamily: monoFamily,
                          fontFamilyFallback: monoFallback,
                          fontSize: 11.5,
                          color: hover ? p.accent : p.textMuted,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tag(t.mode == OrganizeMode.inPlace ? '原地整理' : '移动到媒体库'),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Tooltip(
                      message: t.paths.join('\n'),
                      child: Text(
                        '${connName ?? t.connection.value} · $where',
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
              if (works.length > 1) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [for (final w in works) _WorkChip(work: w)],
                ),
              ],
              const SizedBox(height: 12),
              _Stepper(stage: t.stage, progress: t.progress),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (t.message.isNotEmpty)
                          Text(
                            t.message,
                            style: TextStyle(fontSize: 12.5, color: p.text),
                          ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 14,
                          children: [
                            _Count(
                              CupertinoIcons.tray_arrow_down,
                              '导入',
                              t.importedCount,
                            ),
                            _Count(CupertinoIcons.film, '视频', t.videoCount),
                            _Count(CupertinoIcons.folder, '文件夹', t.folderCount),
                            _Count(
                              CupertinoIcons.captions_bubble,
                              '字幕',
                              t.subtitleCount,
                            ),
                            if (unassigned > 0)
                              _Count(CupertinoIcons.tray, '未归类', unassigned),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (t.stage.isActive)
                    TextButton(
                      onPressed: () => tm.cancel(t.id),
                      child: const Text('取消'),
                    ),
                  if (t.stage == TaskStage.awaitingReview) ...[
                    const SizedBox(width: 4),
                    OutlinedButton(
                      onPressed: runConfident,
                      child: const Text('立即执行'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () =>
                          context.go('/tasks/${t.id.value}/review'),
                      child: const Text('去确认'),
                    ),
                  ],
                  if (t.stage == TaskStage.done ||
                      t.stage == TaskStage.partiallyFailed)
                    OutlinedButton.icon(
                      onPressed: undo,
                      icon: const Icon(
                        CupertinoIcons.arrow_uturn_left,
                        size: 13,
                      ),
                      label: const Text('撤销'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );

    final backdrop = works.map((w) => w.backdropPath).nonNulls.firstOrNull;
    // Cards that want attention get a coloured edge.
    final edge = switch (t.stage) {
      TaskStage.awaitingReview => p.accent,
      TaskStage.partiallyFailed => p.warning,
      _ => null,
    };

    return ContextMenuArea(
      items: menu,
      child: Hoverable(
        key: ValueKey('task ${t.id.value}'),
        onTap: () => context.go(target),
        builder: (context, hover) => AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          transform: Matrix4.translationValues(0, hover ? -2 : 0, 0),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: p.panel,
            borderRadius: BorderRadius.circular(Radii.xl),
            border: Border.all(
              color: edge?.withValues(alpha: 0.55) ?? p.line,
              width: edge == null ? hairline : 1,
            ),
            boxShadow: hover ? floatShadow(0.6) : panelShadow(),
          ),
          child: Stack(
            children: [
              if (backdrop != null) ...[
                Positioned.fill(
                  child: Image.network(
                    tmdbImage(backdrop, 'w780'),
                    fit: BoxFit.cover,
                    alignment: Alignment.centerRight,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        stops: const [0, 0.55, 1],
                        colors: [
                          p.panel,
                          p.panel.withValues(alpha: 0.95),
                          p.panel.withValues(alpha: 0.72),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              Padding(padding: const EdgeInsets.all(16), child: body),
            ],
          ),
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
  if (ok) await ref.read(taskManagerProvider).undo(id);
}

/// Up to three posters fanned out; an icon tile before recognition.
class _PosterStack extends StatelessWidget {
  final List<Candidate> works;
  final TaskStage stage;

  const _PosterStack({required this.works, required this.stage});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    if (works.isEmpty) {
      return Container(
        width: 56,
        height: 84,
        decoration: BoxDecoration(
          color: p.sidebar,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: p.line, width: hairline),
        ),
        child: Center(
          child: stage.isActive && stage != TaskStage.awaitingReview
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                )
              : Icon(CupertinoIcons.folder, size: 20, color: p.textFaint),
        ),
      );
    }
    final shown = works.take(3).toList();
    return SizedBox(
      width: 56 + 10.0 * (shown.length - 1),
      height: 84,
      child: Stack(
        children: [
          for (var i = shown.length - 1; i >= 0; i--)
            Positioned(
              left: 10.0 * i,
              top: 3.0 * i,
              child: Opacity(
                opacity: i == 0 ? 1 : 0.85,
                child: Poster(
                  posterPath: shown[i].posterPath,
                  icon: shown[i].kind == MediaKind.movie
                      ? CupertinoIcons.film
                      : CupertinoIcons.tv,
                  width: 56 - 4.0 * i,
                  height: 84 - 6.0 * i,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Count extends StatelessWidget {
  final IconData icon;
  final String label;
  final int value;

  const _Count(this.icon, this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: p.textFaint),
        const SizedBox(width: 4),
        Text(
          '$label $value',
          style: TextStyle(fontSize: 11.5, color: p.textMuted),
        ),
      ],
    );
  }
}

/// 导入 → 识别 → 待确认 → 文件 → 文件夹 as a segmented track.
class _Stepper extends StatelessWidget {
  final TaskStage stage;
  final double? progress;

  const _Stepper({required this.stage, this.progress});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final cur = _currentStep(stage);
    final dim = cur < 0;
    return Row(
      children: [
        for (var i = 0; i < _steps.length; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: SizedBox(
                    height: 5,
                    width: double.infinity,
                    child: i == cur && i != 2 && progress != null
                        ? GradientProgress(
                            value: progress!,
                            color: p.accent,
                            height: 5,
                          )
                        : i == cur && i != 2
                        ? LinearProgressIndicator(
                            minHeight: 5,
                            color: p.accent,
                            backgroundColor: p.accent.withValues(alpha: 0.18),
                          )
                        : ColoredBox(
                            color: dim
                                ? p.selected
                                : cur == _steps.length
                                ? p.success.withValues(alpha: 0.8)
                                : i < cur
                                ? p.accent.withValues(alpha: 0.75)
                                : i == cur
                                ? p.accent
                                : p.selected,
                          ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _steps[i],
                  style: TextStyle(
                    fontSize: 11,
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

/// Small poster + title, one per recognized work on multi-work tasks.
class _WorkChip extends StatelessWidget {
  final Candidate work;

  const _WorkChip({required this.work});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.fromLTRB(3, 3, 9, 3),
      decoration: BoxDecoration(
        color: p.sidebar,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: p.line, width: hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Poster(
            posterPath: work.posterPath,
            width: 16,
            height: 24,
            radius: 3,
            icon: work.kind == MediaKind.movie
                ? CupertinoIcons.film
                : CupertinoIcons.tv,
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              [work.title, if (work.year != null) '${work.year}'].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: p.text),
            ),
          ),
        ],
      ),
    );
  }
}
