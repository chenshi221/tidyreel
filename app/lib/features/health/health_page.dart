import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/widgets.dart';
import '../../widgets/common.dart';

/// 媒体库体检中心（Implemented by Wave 2 Worker D: `app-health-watch`）.
class HealthPage extends ConsumerWidget {
  const HealthPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => const PageScaffold(
    title: '体检',
    child: EmptyState(
      icon: CupertinoIcons.checkmark_shield,
      title: '媒体库体检中心',
      message: '即将在此检查缺集、同片重复、缺失 NFO/海报/中文字幕以及垃圾文件',
    ),
  );
}
