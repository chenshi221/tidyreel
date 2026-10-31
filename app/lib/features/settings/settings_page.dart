import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../widgets/common.dart';
import 'settings_providers.dart';

const appVersion = '1.0.0';

/// 设置页（PLAN §5）.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final _key = TextEditingController(
    text: ref.read(settingsProvider).tmdbApiKey,
  );
  late final _url = TextEditingController(
    text: ref.read(settingsProvider).tmdbBaseUrl,
  );

  @override
  void dispose() {
    _key.dispose();
    _url.dispose();
    super.dispose();
  }

  void _set(AppSettings Function(AppSettings) f) =>
      ref.read(settingsProvider.notifier).update(f);

  Future<void> _testConnection() async {
    final messenger = ScaffoldMessenger.of(context);
    String msg;
    if (_key.text.trim().isEmpty) {
      msg = '请先填写 TMDB API Key';
    } else {
      try {
        final hits = await ref.read(metadataProvider).search('Inception');
        msg = hits.isEmpty ? '已连接，但没有搜到结果' : '连接成功：找到「${hits.first.title}」';
      } catch (e) {
        msg = '连接失败：$e';
      }
    }
    messenger.showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final theme = Theme.of(context);
    return PageScaffold(
      title: '设置',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        children: [
          Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _title(theme, 'TMDB'),
                  TextField(
                    controller: _key,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'API Key / Read Token',
                      helperText: '支持 v3 key 和 v4 read token',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => _set((o) => o.copyWith(tmdbApiKey: v)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _url,
                    decoration: const InputDecoration(
                      labelText: 'Base URL（代理地址）',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => _set((o) => o.copyWith(tmdbBaseUrl: v)),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _testConnection,
                    icon: const Icon(Icons.wifi_tethering),
                    label: const Text('测试连接'),
                  ),
                  const SizedBox(height: 24),
                  _title(theme, '整理'),
                  const Text('默认整理模式'),
                  const SizedBox(height: 8),
                  SegmentedButton<OrganizeMode>(
                    segments: const [
                      ButtonSegment(
                        value: OrganizeMode.inPlace,
                        label: Text('原地整理'),
                      ),
                      ButtonSegment(
                        value: OrganizeMode.moveToLibrary,
                        label: Text('移动到媒体库'),
                      ),
                    ],
                    selected: {s.defaultMode},
                    onSelectionChanged: (v) =>
                        _set((o) => o.copyWith(defaultMode: v.first)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动删除垃圾文件'),
                    subtitle: const Text('默认关闭；开启后垃圾文件的删除操作默认勾选，执行前仍需确认'),
                    value: s.autoDeleteJunk,
                    onChanged: (v) =>
                        _set((o) => o.copyWith(autoDeleteJunk: v)),
                  ),
                  const SizedBox(height: 16),
                  _title(theme, '外观'),
                  SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        icon: Icon(Icons.brightness_auto),
                        label: Text('跟随系统'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        icon: Icon(Icons.light_mode),
                        label: Text('浅色'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        icon: Icon(Icons.dark_mode),
                        label: Text('深色'),
                      ),
                    ],
                    selected: {s.themeMode},
                    onSelectionChanged: (v) =>
                        _set((o) => o.copyWith(themeMode: v.first)),
                  ),
                  const SizedBox(height: 24),
                  _title(theme, '关于'),
                  const Text('理片 Tidyreel  v$appVersion'),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Text('基于 mnamer (MIT) 的思路'),
                      TextButton(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('开源许可'),
                            content: const SelectableText(
                              '命名与解析思路参考 mnamer（MIT License）。\n'
                              '原版权声明见项目 LICENSES/mnamer-MIT.txt。',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text('关闭'),
                              ),
                            ],
                          ),
                        ),
                        child: const Text('查看 LICENSES'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _title(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(text, style: theme.textTheme.titleMedium),
  );
}
