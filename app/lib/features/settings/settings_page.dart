import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../version.dart';
import '../tasks/tasks_page.dart' show confirmDeleteTask;
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../../widgets/common.dart';
import 'settings_providers.dart';

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

  Future<void> _openDataDir() async {
    final dir = await getApplicationSupportDirectory();
    await Process.run(Platform.isWindows ? 'explorer' : 'open', [dir.path]);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final naming = ref.watch(namingProfileProvider);
    final finished = [
      for (final t in ref.watch(tasksProvider).value ?? const <TaskSummary>[])
        if (!t.stage.isActive) t,
    ];
    Widget toggle(String key, bool value, AppSettings Function(bool) f) =>
        MacSwitch(
          key: ValueKey(key),
          value: value,
          onChanged: (v) => _set((_) => f(v)),
        );
    final p = Palette.of(context);
    final builtIn = ref.watch(builtInTmdbTokenProvider).isNotEmpty;
    return PageScaffold(
      title: '设置',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(48, 0, 40, 28),
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
                SettingRow(
                  title: '提交前预览',
                  caption: '先快速扫一遍，显示文件数量和风险提示，再决定是否提交',
                  control: toggle(
                    'scan-preview',
                    s.scanPreview,
                    (v) => s.copyWith(scanPreview: v),
                  ),
                ),
                SettingRow(
                  title: '执行前确认',
                  caption: '在确认页点「执行」时，再弹一次汇总确认',
                  control: toggle(
                    'confirm-execute',
                    s.confirmBeforeExecute,
                    (v) => s.copyWith(confirmBeforeExecute: v),
                  ),
                ),
                SettingRow(
                  title: '单季剧也建 Season 文件夹',
                  caption: '关闭后只有一季的剧集直接放在剧集文件夹里；多季剧总会建',
                  control: MacSwitch(
                    key: const ValueKey('settings-single-season'),
                    value: naming.tv.singleSeasonFolder,
                    onChanged: (v) => ref
                        .read(namingProfileProvider.notifier)
                        .set(
                          naming.copyWith(
                            tv: naming.tv.copyWith(singleSeasonFolder: v),
                          ),
                        ),
                  ),
                ),
                SettingRow(
                  title: '同时处理的文件数',
                  caption: '越大越快，但网盘更容易限流。重启理片后生效',
                  control: Segmented<int>(
                    options: const {1: '1', 2: '2', 4: '4', 8: '8'},
                    value: s.concurrency,
                    onChanged: (v) => _set((o) => o.copyWith(concurrency: v)),
                  ),
                ),
                SettingRow(
                  title: '每秒请求上限',
                  caption: 'Alist 默认会限流，频繁报错时调小。重启理片后生效',
                  control: Segmented<int>(
                    options: const {2: '2', 5: '5', 10: '10'},
                    value: s.requestsPerSecond,
                    onChanged: (v) =>
                        _set((o) => o.copyWith(requestsPerSecond: v)),
                  ),
                ),
              ],
            ),
          ),
          const SectionLabel('识别'),
          Panel(
            child: Rows(
              children: [
                SettingRow(
                  title: '内容类型',
                  caption: '混合：按文件名逐个判断；动漫会用罗马音查别名、优先日本作品；选电视剧或电影则全部按该类型识别',
                  control: Segmented<MediaHint>(
                    options: mediaHintLabels,
                    value: s.mediaHint,
                    onChanged: (v) => _set((o) => o.copyWith(mediaHint: v)),
                  ),
                ),
                SettingRow(
                  title: 'TMDB 语言',
                  caption: '片名、简介和集标题用哪种语言，找不到时退回英文',
                  control: Segmented<String>(
                    options: const {
                      'zh-CN': '简体',
                      'zh-TW': '繁体',
                      'en-US': 'English',
                    },
                    value: s.tmdbLanguage,
                    onChanged: (v) => _set((o) => o.copyWith(tmdbLanguage: v)),
                  ),
                ),
                SettingRow(
                  title: '「立即执行」的门槛',
                  caption: '识别分数达到多少，任务卡片上的「立即执行」才会处理它',
                  control: Segmented<double>(
                    options: {0.6: '宽松', 0.7: '标准', 0.85: '严格'},
                    value:
                        const [0.6, 0.7, 0.85].contains(s.confidenceThreshold)
                        ? s.confidenceThreshold
                        : 0.7,
                    onChanged: (v) =>
                        _set((o) => o.copyWith(confidenceThreshold: v)),
                  ),
                ),
                SettingRow(
                  title: '清除 TMDB 缓存',
                  caption: 'TMDB 上刚更新的信息没显示出来时用',
                  control: OutlinedButton(
                    onPressed: () {
                      ref.read(bootstrapProvider).tmdbCache?.clear();
                      ref.invalidate(metadataProvider);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已清除 TMDB 缓存')),
                      );
                    },
                    child: const Text('清除'),
                  ),
                ),
              ],
            ),
          ),
          const SectionLabel('外观'),
          Panel(
            child: Rows(
              children: [
                SettingRow(
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
                SettingRow(
                  title: '强调色',
                  control: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final a in AccentChoice.values)
                        Tooltip(
                          message: a.label,
                          child: Hoverable(
                            key: ValueKey('accent-${a.name}'),
                            onTap: () => _set((o) => o.copyWith(accent: a)),
                            builder: (context, hover) => Container(
                              width: 22,
                              height: 22,
                              margin: const EdgeInsets.only(left: 8),
                              decoration: BoxDecoration(
                                color:
                                    Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? a.dark
                                    : a.light,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: s.accent == a
                                      ? p.text
                                      : Colors.transparent,
                                  width: 2,
                                ),
                              ),
                              child: s.accent == a
                                  ? const Icon(
                                      CupertinoIcons.checkmark,
                                      size: 12,
                                      color: Colors.white,
                                    )
                                  : null,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                SettingRow(
                  title: '启动时收起侧栏',
                  control: toggle(
                    'sidebar-collapsed',
                    s.sidebarCollapsed,
                    (v) => s.copyWith(sidebarCollapsed: v),
                  ),
                ),
                SettingRow(
                  title: '减少动画',
                  caption: '关闭页面切换和列表浮现动画',
                  control: toggle(
                    'reduce-motion',
                    s.reduceMotion,
                    (v) => s.copyWith(reduceMotion: v),
                  ),
                ),
              ],
            ),
          ),
          const SectionLabel('通知'),
          Panel(
            child: Rows(
              children: [
                SettingRow(
                  title: '识别完成时提示',
                  control: toggle(
                    'notify-recognized',
                    s.notifyRecognized,
                    (v) => s.copyWith(notifyRecognized: v),
                  ),
                ),
                SettingRow(
                  title: '执行完成时提示',
                  control: toggle(
                    'notify-finished',
                    s.notifyFinished,
                    (v) => s.copyWith(notifyFinished: v),
                  ),
                ),
              ],
            ),
          ),
          const SectionLabel('数据'),
          Panel(
            child: Rows(
              children: [
                SettingRow(
                  title: '清空已结束的任务',
                  caption: finished.isEmpty
                      ? '没有已结束的任务'
                      : '共 ${finished.length} 条。不动文件，但删除后无法再撤销',
                  control: OutlinedButton(
                    key: const ValueKey('settings-clear-tasks'),
                    onPressed: finished.isEmpty
                        ? null
                        : () => confirmDeleteTask(context, ref, finished),
                    child: const Text('清空'),
                  ),
                ),
                SettingRow(
                  title: '数据目录',
                  caption: '设置、连接、任务记录和撤销日志都保存在这里',
                  control: OutlinedButton(
                    onPressed: _openDataDir,
                    child: Text(
                      Platform.isWindows ? '在资源管理器中打开' : '在 Finder 中打开',
                    ),
                  ),
                ),
              ],
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
                      const AppLogo(),
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
                          '原版权声明见项目 LICENSES/mnamer-MIT.txt。\n\n'
                          'SMB 连接使用 dart_smb2（BSD-3-Clause）和 libsmb2'
                          '（GNU LGPL 2.1 或更新版本，动态加载，'
                          'Copyright (C) Ronnie Sahlberg 及贡献者）。\n'
                          '源码：https://github.com/sahlberg/libsmb2 ，'
                          '说明见项目 LICENSES/libsmb2-NOTICE.txt。',
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
