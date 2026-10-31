import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../widgets/common.dart';
import '../sources/sources_providers.dart';

/// 任务中心（PLAN §5）. NavigationRail badge for 待确认 lives in frozen app.dart.
class TasksPage extends ConsumerWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(tasksProvider);
    return PageScaffold(
      title: '任务',
      child: tasks.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('无法读取任务：$e')),
        data: (all) {
          final active = all.where((t) => t.stage.isActive).toList();
          final finished = all.where((t) => !t.stage.isActive).toList();
          return DefaultTabController(
            length: 2,
            child: Column(
              children: [
                TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [
                    Tab(text: '进行中 (${active.length})'),
                    Tab(text: '已完成 (${finished.length})'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _TaskList(tasks: active, empty: '没有进行中的任务，去「来源」选择文件夹提交'),
                      _TaskList(tasks: finished, empty: '还没有已完成的任务'),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _TaskList extends StatelessWidget {
  final List<TaskSummary> tasks;
  final String empty;

  const _TaskList({required this.tasks, required this.empty});

  @override
  Widget build(BuildContext context) => tasks.isEmpty
      ? Center(child: Text(empty))
      : ListView.separated(
          padding: const EdgeInsets.all(24),
          itemCount: tasks.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (_, i) => TaskCard(task: tasks[i]),
        );
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
    final tm = ref.read(taskManagerProvider);
    final theme = Theme.of(context);
    final connName = ref
        .watch(connectionsEditorProvider)
        .where((c) => c.id == t.connection)
        .map((c) => c.name)
        .firstOrNull;

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
      );
      if (ok) await tm.undo(t.id);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SelectableText(
                  t.id.value,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
                IconButton(
                  tooltip: '复制任务 ID',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: t.id.value));
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('已复制任务 ID')));
                  },
                ),
                Chip(
                  label: Text(
                    t.mode == OrganizeMode.inPlace ? '原地整理' : '移动到媒体库',
                  ),
                  visualDensity: VisualDensity.compact,
                ),
                const Spacer(),
                Text(
                  stageLabel(t.stage),
                  style: TextStyle(color: theme.colorScheme.primary),
                ),
              ],
            ),
            Text(
              '${connName ?? t.connection.value} · ${t.paths.join('，')}',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            _Stepper(stage: t.stage),
            const SizedBox(height: 8),
            if (t.message.isNotEmpty) Text(t.message),
            if (t.progress != null) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: t.progress),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              children: [
                _Count(Icons.download_done, '已导入', t.importedCount),
                _Count(Icons.movie_outlined, '视频', t.videoCount),
                _Count(Icons.folder_outlined, '文件夹', t.folderCount),
                _Count(Icons.subtitles_outlined, '字幕', t.subtitleCount),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (t.stage.isActive)
                  TextButton(
                    onPressed: () => tm.cancel(t.id),
                    child: const Text('取消'),
                  ),
                if (t.stage == TaskStage.awaitingReview) ...[
                  OutlinedButton(
                    onPressed: runConfident,
                    child: const Text('立即执行'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => context.go('/tasks/${t.id.value}/review'),
                    child: const Text('去确认'),
                  ),
                ],
                if (t.stage == TaskStage.done ||
                    t.stage == TaskStage.partiallyFailed)
                  OutlinedButton(onPressed: undo, child: const Text('撤销')),
              ],
            ),
          ],
        ),
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
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 16),
      const SizedBox(width: 4),
      Text('$label $value'),
    ],
  );
}

class _Stepper extends StatelessWidget {
  final TaskStage stage;

  const _Stepper({required this.stage});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cur = _currentStep(stage);
    return Row(
      children: [
        for (var i = 0; i < _steps.length; i++) ...[
          if (i > 0)
            Expanded(
              child: Divider(
                thickness: 2,
                color: i <= cur ? scheme.primary : scheme.outlineVariant,
              ),
            ),
          Icon(
            i < cur
                ? Icons.check_circle
                : i == cur
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            size: 18,
            color: i <= cur ? scheme.primary : scheme.outline,
          ),
          const SizedBox(width: 4),
          Text(
            _steps[i],
            style: TextStyle(
              fontWeight: i == cur ? FontWeight.bold : FontWeight.normal,
              color: i <= cur ? scheme.onSurface : scheme.outline,
            ),
          ),
        ],
      ],
    );
  }
}
