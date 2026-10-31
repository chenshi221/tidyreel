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
                itemBuilder: (_, i) => TaskCard(task: shown[i]),
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
      if (ok) await tm.run(t.id, onlyConfident: true);
    }

    Future<void> undo() async {
      final ok = await confirmDialog(
        context,
        title: '撤销整批',
        content: const Text('将把这个任务改过的文件恢复成原来的名字和位置。确定撤销吗？'),
        confirmLabel: '撤销',
        destructive: true,
      );
      if (ok) await tm.undo(t.id);
    }

    return Panel(
      padding: const EdgeInsets.all(14),
      child: Row(
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
                    const SizedBox(width: 8),
                    Icon(statusIcon, size: 13, color: statusColor),
                    const SizedBox(width: 4),
                    Text(
                      stageLabel(t.stage),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: statusColor,
                      ),
                    ),
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
                              _Count(
                                CupertinoIcons.folder,
                                '文件夹',
                                t.folderCount,
                              ),
                              _Count(
                                CupertinoIcons.captions_bubble,
                                '字幕',
                                t.subtitleCount,
                              ),
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
      ),
    );
  }
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
                    height: 4,
                    width: double.infinity,
                    child: i == cur && i != 2
                        ? LinearProgressIndicator(
                            value: progress,
                            minHeight: 4,
                            color: p.accent,
                            backgroundColor: p.accent.withValues(alpha: 0.18),
                          )
                        : ColoredBox(
                            color: dim
                                ? p.selected
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
