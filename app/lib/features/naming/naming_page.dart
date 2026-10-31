import 'package:flutter/material.dart';

import '../../widgets/placeholder_page.dart';

/// Owner: Agent F. 电影 / 剧集命名选项与实时示例预览（PLAN §3.2）
class NamingPage extends StatelessWidget {
  const NamingPage({super.key});

  @override
  Widget build(BuildContext context) => const PlaceholderPage(
    title: '命名规则',
    description: '电影 / 剧集命名选项与实时示例预览（PLAN §3.2）',
  );
}
