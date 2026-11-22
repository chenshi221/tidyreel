import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/widgets.dart';
import '../../widgets/common.dart';

/// 轻量化追更监控页（Implemented by Wave 2 Worker D: `app-health-watch`）.
class WatchPage extends ConsumerWidget {
  const WatchPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => const PageScaffold(
    title: '追更',
    child: EmptyState(
      icon: CupertinoIcons.dot_radiowaves_left_right,
      title: '轻量化追更监控',
      message: '监控常用下载目录，自动检测稳定新文件并提交识别',
    ),
  );
}
