import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../../widgets/common.dart';
import 'tasks_page.dart';

/// What a finished task did: its review (works) plus the executed ops and
/// their status from history.
final taskDetailProvider = FutureProvider.autoDispose
    .family<({TaskReview? review, List<HistoryRecord> records}), TaskId>((
      ref,
      id,
    ) async {
      final (_, batch, _) = ref.watch(
        tasksProvider.select((v) {
          final t = v.value?.where((t) => t.id == id).firstOrNull;
          return (
            t?.stage,
            t?.batch,
            t == null || t.stage.isActive ? null : t.message,
          );
        }),
      );
      TaskReview? review;
      try {
        review = await ref.read(taskManagerProvider).review(id);
      } catch (_) {
        // Not recognized (cancelled early): show the history alone.
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
    final canUndo =
        task != null &&
        task.batch != null &&
        (task.stage == TaskStage.done ||
            task.stage == TaskStage.partiallyFailed);
    return PageScaffold(
      title: '任务详情',
      subtitle: [
        taskId,
        if (task != null) stageLabel(task.stage),
        if (task != null && task.message.isNotEmpty) task.message,
      ].join('  ·  '),
      leading: IconButton(
        tooltip: '返回任务',
        icon: const Icon(CupertinoIcons.chevron_left),
        onPressed: () => context.go('/tasks'),
      ),
      actions: [
        if (task?.stage == TaskStage.partiallyFailed)
          FilledButton.icon(
            key: const ValueKey('retry-failed'),
            onPressed: () async {
              try {
                await ref.read(taskManagerProvider).retryFailed(id);
              } on StateError catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(SnackBar(content: Text(e.message)));
                }
              }
            },
            icon: const Icon(CupertinoIcons.arrow_clockwise, size: 13),
            label: const Text('重试失败项'),
          ),
        if (canUndo)
          OutlinedButton.icon(
            onPressed: () => confirmUndo(context, ref, id),
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
      maxWidth: 1000,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Progress steps (导入 → 识别 → … → 文件夹) while it runs.
          if (task != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(48, 0, 40, 12),
              child: TaskCard(task: task),
            ),
          Expanded(
            child: detail.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => EmptyState(
                icon: CupertinoIcons.exclamationmark_triangle,
                title: '无法读取任务详情',
                message: '$e',
              ),
              data: (d) => _Body(
                review: d.review,
                records: d.records,
                busy:
                    task != null &&
                    task.stage.index < TaskStage.awaitingReview.index,
                awaiting: task?.stage == TaskStage.awaitingReview ? id : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final TaskReview? review;
  final List<HistoryRecord> records;
  final bool busy;

  /// Set while the task waits for review.
  final TaskId? awaiting;

  const _Body({
    required this.review,
    required this.records,
    required this.busy,
    required this.awaiting,
  });

  @override
  Widget build(BuildContext context) {
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
      return const EmptyState(
        icon: CupertinoIcons.doc_text,
        title: '没有执行记录',
        message: '这个任务还没有改动过任何文件',
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
                          : [
                              m.title,
                              if (m.year != null) '${m.year}',
                            ].join(' · '),
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
      OpStatus.pending => ('未执行', p.textMuted),
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
                    style: TextStyle(fontSize: 11.5, color: p.textMuted),
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
                      style: TextStyle(fontSize: 11.5, color: p.danger),
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
