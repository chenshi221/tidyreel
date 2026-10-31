import 'package:flutter/material.dart';

import '../../widgets/placeholder_page.dart';

/// Owner: Agent F. 识别结果三栏页（PLAN §5）.
class ReviewPage extends StatelessWidget {
  final String taskId;

  const ReviewPage({super.key, required this.taskId});

  @override
  Widget build(BuildContext context) => PlaceholderPage(
    title: '识别结果 $taskId',
    description: '作品列表（可整理 / 待手动识别）、按季明细、纠错 / 策略 / 剧集组（PLAN §5）',
  );
}
