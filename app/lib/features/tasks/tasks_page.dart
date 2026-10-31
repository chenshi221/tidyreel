import 'package:flutter/material.dart';

import '../../widgets/placeholder_page.dart';

/// Owner: Agent F. 进行中 / 已完成，阶段进度、去确认、立即执行、取消、撤销（PLAN §5）
class TasksPage extends StatelessWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context) => const PlaceholderPage(
    title: '任务',
    description: '进行中 / 已完成，阶段进度、去确认、立即执行、取消、撤销（PLAN §5）',
  );
}
