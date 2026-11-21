import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../../widgets/common.dart';
import '../sources/sources_providers.dart';
import 'tasks_page.dart';

/// What a finished or executing task did: its review (works) plus the executed
/// ops and their status from history. Watches progress/message while renaming
/// so op statuses update live.
final taskDetailProvider = FutureProvider.autoDispose
    .family<({TaskReview? review, List<HistoryRecord> records}), TaskId>((
      ref,
      id,
    ) async {
      final (_, batch, _, _) = ref.watch(
        tasksProvider.select((v) {
          final t = v.value?.where((t) => t.id == id).firstOrNull;
          final renaming =
              t != null &&
              (t.stage == TaskStage.renamingFiles ||
                  t.stage == TaskStage.renamingFolders);
          return (
            t?.stage,
            t?.batch,
            renaming ? t.progress : null,
            t != null && (renaming || !t.stage.isActive) ? t.message : null,
          );
        }),
      );
      TaskReview? review;
      try {
        review = await ref.read(taskManagerProvider).review(id);
      } catch (_) {
        // Not recognized (failed / cancelled early): show the history alone.
      }
      final records = batch == null
          ? const <HistoryRecord>[]
          : await ref.read(historyProvider).records(batch);
      return (review: review, records: records);
    });

/// 任务详情: per work, every file's 原名 → 新名 and whether it went through.
class TaskDetailPage extends ConsumerWidget {
  final String taskId;

  const TaskDetailPage({super.key, required this.taskId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = TaskId(taskId);
    final task = ref
        .watch(tasksProvider)
        .value
        ?.where((t) => t.id == id)
        .firstOrNull;
    final detail = ref.watch(taskDetailProvider(id));
    // Submitted tasks land here: open the review as soon as it is ready.
    ref.listen(
      tasksProvider.select(
        (v) => v.value?.where((t) => t.id == id).firstOrNull?.stage,
      ),
      (prev, next) {
        if (prev != TaskStage.awaitingReview &&
            next == TaskStage.awaitingReview) {
          context.go('/tasks/$taskId/review');
        }
      },
    );
    final undoable = task != null && canUndo(task);
    final running =
        task != null &&
        task.stage.isActive &&
        task.stage != TaskStage.awaitingReview;
    return PageScaffold(
      title: '任务详情',
      subtitle: task == null ? null : stageLabel(task.stage),
      leading: Builder(
        builder: (context) {
          // Opened from 最近整理 (?from=sources): back goes back there.
          final fromSources =
              GoRouterState.of(context).uri.queryParameters['from'] ==
              'sources';
          return IconButton(
            tooltip: fromSources ? '返回来源' : '返回任务',
            icon: const Icon(CupertinoIcons.chevron_left),
            onPressed: () => context.go(fromSources ? '/sources' : '/tasks'),
          );
        },
      ),
      actions: [
        if (running)
          OutlinedButton(
            onPressed: () => ref.read(taskManagerProvider).cancel(id),
            child: const Text('取消'),
          ),
        if (task?.stage == TaskStage.partiallyFailed)
          FilledButton.icon(
            key: const ValueKey('retry-failed'),
            onPressed: () => retryFailedTask(context, ref, id),
            icon: const Icon(CupertinoIcons.arrow_clockwise, size: 13),
            label: const Text('重试失败项'),
          ),
        if (task != null && canRetry(task))
          OutlinedButton.icon(
            key: const ValueKey('retry-task'),
            onPressed: () => retryTask(context, ref, id),
            icon: const Icon(CupertinoIcons.arrow_clockwise, size: 13),
            label: const Text('重新识别'),
          ),
        if (undoable)
          OutlinedButton.icon(
            onPressed: () => undoTask(context, ref, id),
            icon: const Icon(CupertinoIcons.arrow_uturn_left, size: 13),
            label: const Text('撤销'),
          ),
        if (task != null && canDeleteTask(task))
          IconButton(
            key: const ValueKey('delete-task'),
            tooltip: '删除记录',
            icon: const Icon(CupertinoIcons.trash),
            onPressed: () async {
              final router = GoRouter.of(context);
              if (await confirmDeleteTask(context, ref, [task])) {
                router.go('/tasks');
              }
            },
          ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (task != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(48, 0, 40, 12),
              child: Panel(child: _TaskSummaryHeader(task: task)),
            ),
          Expanded(
            child: detail.when(
              loading: () => const Center(child: Spinner(size: 20)),
              error: (e, _) => EmptyState(
                icon: CupertinoIcons.exclamationmark_triangle,
                title: '无法读取任务详情',
                message: '$e',
              ),
              data: (d) => _Body(
                task: task,
                review: d.review,
                records: d.records,
                busy:
                    task != null &&
                    task.stage.index < TaskStage.awaitingReview.index,
                awaiting: task?.stage == TaskStage.awaitingReview ? id : null,
                onRetry: task != null && canRetry(task)
                    ? () => retryTask(context, ref, id)
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Non-interactive summary header for [TaskDetailPage]: shows work/folder info,
/// status, full error message (when records also exist), and active stepper
/// without duplicating header action buttons or self-navigation taps.
class _TaskSummaryHeader extends ConsumerWidget {
  final TaskSummary task;

  const _TaskSummaryHeader({required this.task});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = task;
    final p = Palette.of(context);
    final theme = Theme.of(context);
    final connName = ref
        .watch(connectionsEditorProvider)
        .where((c) => c.id == t.connection)
        .map((c) => c.name)
        .firstOrNull;
    final recognized = isTaskRecognized(t);
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
    final running = t.stage.isActive && t.stage != TaskStage.awaitingReview;
    final counts = [
      '${t.videoCount} 个视频',
      if (t.subtitleCount > 0) '${t.subtitleCount} 个字幕',
      if (t.folderCount > 0) '${t.folderCount} 个文件夹',
      if (unassigned > 0) '$unassigned 个未归类',
    ].join('，');
    final showMessage =
        t.message.isNotEmpty &&
        t.stage != TaskStage.failed &&
        t.stage != TaskStage.cancelled;
    final isWarningMsg =
        t.stage == TaskStage.partiallyFailed || t.message.startsWith('已撤销部分操作');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Poster(
            posterPath: works.firstOrNull?.posterPath,
            icon: CupertinoIcons.folder,
            width: 56,
            height: 84,
            radius: Radii.sm,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
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
                    const SizedBox(width: 12),
                    StatusPill(
                      label: running && t.progress != null
                          ? '${stageLabel(t.stage)} ${(t.progress! * 100).round()}%'
                          : stageLabel(t.stage),
                      color: taskStatusColor(t.stage, p),
                      busy: running,
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Tooltip(
                  message: t.paths.join('\n'),
                  child: Text(
                    [
                      connName ?? t.connection.value,
                      t.mode == OrganizeMode.inPlace ? '原地整理' : '移动到媒体库',
                      if (t.scrape) '刮削',
                      if (recognized) counts else where,
                    ].join('，'),
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (showMessage) ...[
                  const SizedBox(height: 4),
                  SelectableText(
                    t.message,
                    style: TextStyle(
                      fontSize: TypeScale.small,
                      color: isWarningMsg ? p.warning : p.textMuted,
                    ),
                  ),
                ],
                if (works.length > 1) ...[
                  const SizedBox(height: 3),
                  Text(
                    works.map((w) => w.title).join('、'),
                    style: TextStyle(fontSize: 12, color: p.textFaint),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (t.stage.isActive) ...[
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
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final TaskSummary? task;
  final TaskReview? review;
  final List<HistoryRecord> records;
  final bool busy;

  /// Set while the task waits for review.
  final TaskId? awaiting;
  final VoidCallback? onRetry;

  const _Body({
    required this.task,
    required this.review,
    required this.records,
    required this.busy,
    required this.awaiting,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final theme = Theme.of(context);
    if (busy) {
      return const EmptyState(
        icon: CupertinoIcons.hourglass,
        title: '正在识别',
        message: '识别完成后会自动打开识别结果',
      );
    }
    if (awaiting != null) {
      return Center(
        child: FilledButton(
          onPressed: () => context.go('/tasks/${awaiting!.value}/review'),
          child: const Text('查看识别结果'),
        ),
      );
    }
    if (records.isEmpty) {
      final t = task;
      if (t != null &&
          (t.stage == TaskStage.failed || t.stage == TaskStage.cancelled)) {
        final failed = t.stage == TaskStage.failed;
        final needsKey = failed && isTmdbKeyError(t.message);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(48, 8, 40, 24),
          child: Panel(
            key: const ValueKey('task-stop-card'),
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      failed
                          ? CupertinoIcons.exclamationmark_circle_fill
                          : CupertinoIcons.xmark_circle,
                      size: 18,
                      color: failed ? p.danger : p.textMuted,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      failed ? '识别失败' : '任务已取消',
                      style: theme.textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SelectableText(
                  t.message.isNotEmpty
                      ? t.message
                      : (failed ? '识别过程中出错，没有改动任何文件。' : '任务在修改文件前已取消。'),
                  style: TextStyle(
                    fontSize: TypeScale.body,
                    color: failed ? p.danger : p.textMuted,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (needsKey)
                      FilledButton(
                        onPressed: () => context.go('/settings'),
                        child: const Text('去设置'),
                      ),
                    if (onRetry != null)
                      needsKey
                          ? OutlinedButton(
                              onPressed: onRetry,
                              child: const Text('重新识别'),
                            )
                          : FilledButton(
                              onPressed: onRetry,
                              child: const Text('重新识别'),
                            ),
                  ],
                ),
              ],
            ),
          ),
        );
      }
      return const EmptyState(
        icon: CupertinoIcons.doc_text,
        title: '还没有整理记录',
        message: '这个任务还没有改动任何文件',
      );
    }
    final groups = {
      for (final g in review?.scan.groups ?? <MediaGroup>[]) g.id: g,
    };
    final byGroup = <GroupId?, List<HistoryRecord>>{};
    for (final r in records) {
      final g = groups.containsKey(r.op.group) ? r.op.group : null;
      (byGroup[g] ??= []).add(r);
    }
    final sections = [
      for (final e in byGroup.entries)
        if (e.key != null) (groups[e.key]!, e.value),
    ];
    final other = byGroup[null];
    return ListView(
      padding: const EdgeInsets.fromLTRB(48, 0, 40, 24),
      children: [
        for (final (g, rs) in sections) ...[
          _WorkSection(
            match: review!.decisions[g.id]?.match ?? g.match,
            fallbackTitle: g.anchorTitle,
            records: rs,
          ),
          const SizedBox(height: 12),
        ],
        if (other != null)
          _WorkSection(match: null, fallbackTitle: '文件夹和其他', records: other),
      ],
    );
  }
}

class _WorkSection extends StatelessWidget {
  final Candidate? match;
  final String fallbackTitle;
  final List<HistoryRecord> records;

  const _WorkSection({
    required this.match,
    required this.fallbackTitle,
    required this.records,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = match;
    final failed = records.where((r) => r.status == OpStatus.failed).length;
    return Panel(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Poster(
                posterPath: m?.posterPath,
                icon: m?.kind == MediaKind.movie
                    ? CupertinoIcons.film
                    : m == null
                    ? CupertinoIcons.folder
                    : CupertinoIcons.tv,
                width: 44,
                height: 66,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m == null
                          ? fallbackTitle
                          : m.year == null
                          ? m.title
                          : '${m.title}（${m.year}）',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${records.length} 项${failed > 0 ? '，$failed 项失败' : ''}',
                      style: theme.textTheme.bodySmall,
                    ),
                    if (m?.overview case final o? when o.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        o,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final r in records) _OpRow(record: r),
        ],
      ),
    );
  }
}

/// Plain-language cause for errors people can fix themselves.
String _explain(String error) =>
    error.contains('StorageErrorCode.busy') ||
        error.toLowerCase().contains('access is denied')
    ? '文件夹被占用：服务器上有程序正打开里面的文件（如下载软件正在做种、播放器或资源管理器开着）。'
          '关掉后点右上角「重试失败项」。\n$error'
    : error;

String _name(String path) =>
    path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path;

class _OpRow extends StatelessWidget {
  final HistoryRecord record;

  const _OpRow({required this.record});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final op = record.op;
    final (label, color) = switch (record.status) {
      OpStatus.done => ('完成', p.success),
      OpStatus.failed => ('失败', p.danger),
      OpStatus.undone => ('已撤销', p.textMuted),
      OpStatus.skipped => ('跳过', p.textMuted),
      OpStatus.pending => ('未处理', p.textMuted),
    };
    final (from, to) = switch (op.kind) {
      OpKind.mkdir => ('新建文件夹', op.dst),
      OpKind.delete => (op.src, '删除'),
      _ => (op.src, op.dst),
    };
    return Tooltip(
      message: [
        '$from\n→ $to',
        if (record.error != null) record.error!,
      ].join('\n'),
      waitDuration: const Duration(milliseconds: 500),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 52, child: Tag(label, color: color)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _name(from),
                    style: TextStyle(
                      fontSize: TypeScale.small,
                      color: p.textMuted,
                    ),
                  ),
                  Text(
                    '→ ${_name(to)}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (record.error != null)
                    Text(
                      _explain(record.error!),
                      style: TextStyle(
                        fontSize: TypeScale.small,
                        color: p.danger,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
