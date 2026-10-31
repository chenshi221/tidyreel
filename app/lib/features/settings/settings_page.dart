import 'package:flutter/material.dart';

import '../../widgets/placeholder_page.dart';

/// Owner: Agent F. TMDB key 与代理地址、默认整理模式、深色模式
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) => const PlaceholderPage(
    title: '设置',
    description: 'TMDB key 与代理地址、默认整理模式、深色模式',
  );
}
