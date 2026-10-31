import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
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
  var _showKey = false;

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
    if (_key.text.trim().isEmpty &&
        ref.read(builtInTmdbTokenProvider).isEmpty) {
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
    final p = Palette.of(context);
    final builtIn = ref.watch(builtInTmdbTokenProvider).isNotEmpty;
    return PageScaffold(
      title: '设置',
      maxWidth: 760,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
        children: [
          const SectionLabel('TMDB 元数据'),
          Panel(
            padding: const EdgeInsets.fromLTRB(8, 8, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FormRow(
                  label: 'API Key',
                  labelWidth: 110,
                  help: builtIn
                      ? '已内置默认 key，可以留空；填了就优先用你的'
                      : '支持 v3 key 和 v4 Read Access Token',
                  child: TextField(
                    key: const ValueKey('tmdb-key'),
                    controller: _key,
                    obscureText: !_showKey,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: builtIn
                          ? '使用内置 key'
                          : '粘贴 API Key 或 Read Token',
                      suffixIcon: IconButton(
                        tooltip: _showKey ? '隐藏' : '显示',
                        iconSize: 15,
                        icon: Icon(
                          _showKey
                              ? CupertinoIcons.eye_slash
                              : CupertinoIcons.eye,
                        ),
                        onPressed: () => setState(() => _showKey = !_showKey),
                      ),
                    ),
                    onChanged: (v) => _set((o) => o.copyWith(tmdbApiKey: v)),
                  ),
                ),
                FormRow(
                  label: 'Base URL',
                  labelWidth: 110,
                  help: '访问不了 TMDB 时，填一个反向代理地址',
                  child: TextField(
                    key: const ValueKey('tmdb-url'),
                    controller: _url,
                    style: const TextStyle(fontSize: 13),
                    onChanged: (v) => _set((o) => o.copyWith(tmdbBaseUrl: v)),
                  ),
                ),
                FormRow(
                  label: '',
                  labelWidth: 110,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _testConnection,
                      icon: const Icon(
                        CupertinoIcons.bolt_horizontal,
                        size: 14,
                      ),
                      label: const Text('测试连接'),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SectionLabel('整理'),
          Panel(
            child: Rows(
              children: [
                SettingRow(
                  title: '默认整理模式',
                  caption: '提交任务时的默认选项，确认时还能改',
                  control: Segmented<OrganizeMode>(
                    options: const {
                      OrganizeMode.inPlace: '原地整理',
                      OrganizeMode.moveToLibrary: '移动到媒体库',
                    },
                    value: s.defaultMode,
                    onChanged: (v) => _set((o) => o.copyWith(defaultMode: v)),
                  ),
                ),
                SettingRow(
                  title: '自动删除垃圾文件',
                  caption: '开启后垃圾文件的删除默认勾选，执行前仍需确认',
                  control: MacSwitch(
                    key: const ValueKey('auto-junk'),
                    value: s.autoDeleteJunk,
                    onChanged: (v) =>
                        _set((o) => o.copyWith(autoDeleteJunk: v)),
                  ),
                ),
              ],
            ),
          ),
          const SectionLabel('外观'),
          Panel(
            child: SettingRow(
              title: '主题',
              control: Segmented<ThemeMode>(
                options: const {
                  ThemeMode.light: '浅色',
                  ThemeMode.dark: '深色',
                  ThemeMode.system: '跟随系统',
                },
                value: s.themeMode,
                onChanged: (v) => _set((o) => o.copyWith(themeMode: v)),
              ),
            ),
          ),
          const SectionLabel('关于'),
          Panel(
            child: Rows(
              children: [
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: p.accent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          CupertinoIcons.film_fill,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '理片 Tidyreel',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '版本 $appVersion',
                              style: TextStyle(
                                fontSize: 12,
                                color: p.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                SettingRow(
                  title: '基于 mnamer (MIT) 的思路',
                  caption: '影视元数据来自 TMDB，本产品使用 TMDB API 但未获得其认可或认证',
                  control: TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('开源许可'),
                        content: const SelectableText(
                          '命名与解析思路参考 mnamer（MIT License）。\n'
                          '原版权声明见项目 LICENSES/mnamer-MIT.txt。',
                        ),
                        actions: [
                          OutlinedButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    ),
                    child: const Text('查看许可'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
