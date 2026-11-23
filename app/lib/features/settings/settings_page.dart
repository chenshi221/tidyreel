import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../data/settings.dart';
import '../../l10n/l10n.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../../version.dart';
import '../../widgets/common.dart';
import '../tasks/tasks_page.dart' show confirmDeleteTask;

const _defaultTmdbBaseUrl = 'https://api.themoviedb.org/3';

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
  var _testing = false;
  String? _testMessage;
  bool? _testOk;

  @override
  void dispose() {
    _key.dispose();
    _url.dispose();
    super.dispose();
  }

  void _set(AppSettings Function(AppSettings) f) =>
      ref.read(settingsProvider.notifier).update(f);

  Future<void> _testConnection() async {
    if (_testing) return;
    final l10n = context.l10n;
    final customKey = _key.text.trim();
    final builtInKey = ref.read(builtInTmdbTokenProvider).trim();
    final effectiveKey = customKey.isNotEmpty ? customKey : builtInKey;
    if (effectiveKey.isEmpty) {
      setState(() {
        _testOk = false;
        _testMessage = l10n.tr(
          '请先填写 TMDB API Key',
          'Please enter a TMDB API key first',
        );
      });
      return;
    }
    final keySource = customKey.isNotEmpty
        ? l10n.tr('自定义 key', 'custom key')
        : l10n.tr('内置 key', 'built-in key');
    setState(() {
      _testing = true;
      _testMessage = null;
      _testOk = null;
    });
    try {
      final demo = ref.read(bootstrapProvider).demo;
      final baseUrl = _url.text.trim().isEmpty
          ? _defaultTmdbBaseUrl
          : _url.text.trim();
      final language = ref.read(settingsProvider).tmdbLanguage;
      // Bypass FileTmdbCache so broken keys or proxies never get a false green
      // from cached responses.
      final MetadataProvider provider = demo
          ? ref.read(metadataProvider)
          : TmdbProvider(
              TmdbConfig(
                apiKey: effectiveKey,
                baseUrl: baseUrl,
                language: language,
                fallbackLanguage: language == 'en-US' ? 'zh-CN' : 'en-US',
              ),
            );
      final hits = await provider.search('Inception');
      if (!mounted) return;
      final t = context.l10n;
      setState(() {
        _testOk = hits.isNotEmpty;
        _testMessage = hits.isEmpty
            ? t.tr(
                '已连接（$keySource），但没有搜到结果',
                'Connected ($keySource), but no results found',
              )
            : t.tr(
                '连接成功：找到「${hits.first.title}」（使用$keySource）',
                'Connected: found "${hits.first.title}" (using $keySource)',
              );
      });
    } catch (e) {
      if (!mounted) return;
      final t = context.l10n;
      setState(() {
        _testOk = false;
        _testMessage = t.tr(
          '连接失败（使用$keySource）：$e',
          'Connection failed (using $keySource): ${t.coreMessage('$e')}',
        );
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _openDataDir() async {
    final dir = await getApplicationSupportDirectory();
    await Process.run(Platform.isWindows ? 'explorer' : 'open', [dir.path]);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final s = ref.watch(settingsProvider);
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
    final urlNonDefault =
        _url.text.trim().isNotEmpty && _url.text.trim() != _defaultTmdbBaseUrl;

    return PageScaffold(
      title: l10n.tr('设置', 'Settings'),
      maxWidth: 820,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(48, 0, 40, 28),
        children: [
          SectionLabel(l10n.tr('TMDB 元数据', 'TMDB Metadata')),
          Panel(
            padding: const EdgeInsets.fromLTRB(8, 8, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FormRow(
                  label: 'API Key',
                  labelWidth: 110,
                  help: builtIn
                      ? l10n.tr(
                          '已内置默认 key，可以留空；填了就优先用你的',
                          'A default key is built in so you can leave this blank; your own key takes precedence',
                        )
                      : l10n.tr(
                          '支持 v3 key 和 v4 Read Access Token；可在 themoviedb.org → 设置 → API 免费申请',
                          'Supports v3 API key or v4 Read Access Token; free at themoviedb.org → Settings → API',
                        ),
                  child: TextField(
                    key: const ValueKey('tmdb-key'),
                    controller: _key,
                    obscureText: !_showKey,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: builtIn
                          ? l10n.tr('使用内置 key', 'Using built-in key')
                          : l10n.tr(
                              '粘贴 API Key 或 Read Token',
                              'Paste API key or Read Access Token',
                            ),
                      suffixIcon: IconButton(
                        tooltip: _showKey
                            ? l10n.tr('隐藏', 'Hide')
                            : l10n.tr('显示', 'Show'),
                        iconSize: 15,
                        icon: Icon(
                          _showKey
                              ? CupertinoIcons.eye_slash
                              : CupertinoIcons.eye,
                        ),
                        onPressed: () => setState(() => _showKey = !_showKey),
                      ),
                    ),
                    onChanged: (v) {
                      if (_testMessage != null) {
                        setState(() {
                          _testMessage = null;
                          _testOk = null;
                        });
                      }
                      _set((o) => o.copyWith(tmdbApiKey: v));
                    },
                  ),
                ),
                FormRow(
                  label: 'Base URL',
                  labelWidth: 110,
                  help: l10n.tr(
                    '访问不了 TMDB 时，填一个反向代理地址',
                    'Enter a reverse proxy URL if direct access to TMDB is blocked',
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('tmdb-url'),
                          controller: _url,
                          style: const TextStyle(fontSize: 13),
                          decoration: const InputDecoration(
                            hintText: _defaultTmdbBaseUrl,
                          ),
                          onChanged: (v) {
                            setState(() {
                              _testMessage = null;
                              _testOk = null;
                            });
                            _set((o) => o.copyWith(tmdbBaseUrl: v));
                          },
                        ),
                      ),
                      if (urlNonDefault) ...[
                        const SizedBox(width: 8),
                        TextButton(
                          key: const ValueKey('tmdb-url-reset'),
                          onPressed: () {
                            _url.text = _defaultTmdbBaseUrl;
                            setState(() {
                              _testMessage = null;
                              _testOk = null;
                            });
                            _set(
                              (o) =>
                                  o.copyWith(tmdbBaseUrl: _defaultTmdbBaseUrl),
                            );
                          },
                          child: Text(l10n.tr('恢复默认', 'Reset')),
                        ),
                      ],
                    ],
                  ),
                ),
                FormRow(
                  label: '',
                  labelWidth: 110,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      OutlinedButton.icon(
                        key: const ValueKey('tmdb-test'),
                        onPressed: _testing ? null : _testConnection,
                        icon: _testing
                            ? const Spinner(size: 14)
                            : const Icon(
                                CupertinoIcons.bolt_horizontal,
                                size: 14,
                              ),
                        label: Text(
                          _testing
                              ? l10n.tr('测试中…', 'Testing…')
                              : l10n.tr('测试连接', 'Test Connection'),
                        ),
                      ),
                      if (_testMessage != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          _testMessage!,
                          key: const ValueKey('tmdb-test-result'),
                          style: TextStyle(
                            fontSize: TypeScale.small,
                            color: _testOk == true ? p.success : p.danger,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          SectionLabel(l10n.tr('整理', 'Organize')),
          Panel(
            child: Rows(
              children: [
                SettingRow(
                  title: l10n.tr('默认整理模式', 'Default Organize Mode'),
                  caption: l10n.tr(
                    '确认识别结果时还能改',
                    'You can still change this while reviewing matches',
                  ),
                  control: Segmented<OrganizeMode>(
                    options: {
                      OrganizeMode.inPlace: l10n.organizeModeLabel(
                        OrganizeMode.inPlace,
                      ),
                      OrganizeMode.moveToLibrary: l10n.organizeModeLabel(
                        OrganizeMode.moveToLibrary,
                      ),
                    },
                    value: s.defaultMode,
                    onChanged: (v) => _set((o) => o.copyWith(defaultMode: v)),
                  ),
                ),
                SettingRow(
                  title: l10n.tr('自动删除垃圾文件', 'Auto-select Junk for Deletion'),
                  caption: l10n.tr(
                    '广告等垃圾文件默认勾选删除，删除前会再问一次',
                    'Pre-select ad and junk files for removal; you will still be asked before deleting',
                  ),
                  control: toggle(
                    'auto-junk',
                    s.autoDeleteJunk,
                    (v) => s.copyWith(autoDeleteJunk: v),
                  ),
                ),
                SettingRow(
                  title: l10n.tr('识别前预览', 'Scan Preview'),
                  caption: l10n.tr(
                    '先快速扫一遍文件数量和可能的问题，再决定是否开始',
                    'Quickly inspect file counts and potential issues before starting matching',
                  ),
                  control: toggle(
                    'scan-preview',
                    s.scanPreview,
                    (v) => s.copyWith(scanPreview: v),
                  ),
                ),
                SettingRow(
                  title: l10n.tr('刮削时覆盖已有 NFO', 'Overwrite Existing NFO'),
                  caption: l10n.tr(
                    '默认保留已存在的 .nfo 文件；开启后重新刮削会安全替换为最新完整元数据',
                    'Keep existing .nfo files by default; enable to safely replace them with fresh metadata when scraping',
                  ),
                  control: toggle(
                    'overwrite-nfo',
                    s.overwriteNfo,
                    (v) => s.copyWith(overwriteNfo: v),
                  ),
                ),
                SettingRow(
                  title: l10n.tr('同时处理的文件数', 'Concurrent Operations'),
                  caption: l10n.tr(
                    '越大越快，但网盘更容易限流。修改后对新任务立即生效',
                    'Higher is faster but more likely to trigger rate limits. Applies immediately to new runs',
                  ),
                  control: Segmented<int>(
                    options: const {1: '1', 2: '2', 4: '4', 8: '8'},
                    value: s.concurrency,
                    onChanged: (v) => _set((o) => o.copyWith(concurrency: v)),
                  ),
                ),
                SettingRow(
                  title: l10n.tr('每秒请求上限', 'Max Requests / Sec'),
                  caption: l10n.tr(
                    '仅影响网盘/远程连接。Alist 默认会限流，频繁报错时调小。修改后立即生效',
                    'Applies to remote connections only. Lower this if Alist rate-limits you. Takes effect immediately',
                  ),
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
          SectionLabel(l10n.tr('识别', 'Matching')),
          Panel(
            child: Rows(
              children: [
                SettingRow(
                  title: l10n.tr('内容类型', 'Content Hint'),
                  caption: l10n.tr(
                    '混合：按文件名逐个判断；动漫会用罗马音查别名、优先日本作品；选电视剧或电影则全部按该类型识别',
                    'Mixed detects per file; Anime looks up romanized aliases and prefers Japanese titles; TV or Movies forces that type',
                  ),
                  control: Segmented<MediaHint>(
                    options: l10n.mediaHintOptions,
                    value: s.mediaHint,
                    onChanged: (v) => _set((o) => o.copyWith(mediaHint: v)),
                  ),
                ),
                SettingRow(
                  title: l10n.tr('TMDB 语言', 'TMDB Language'),
                  caption: l10n.tr(
                    '片名、简介和集标题用哪种语言，找不到时退回英文',
                    'Language for titles, overviews, and episode names; falls back to English if unavailable',
                  ),
                  control: Segmented<String>(
                    options: {
                      'zh-CN': l10n.tr('简体', 'zh-CN'),
                      'zh-TW': l10n.tr('繁体', 'zh-TW'),
                      'en-US': 'English',
                    },
                    value: s.tmdbLanguage,
                    onChanged: (v) => _set((o) => o.copyWith(tmdbLanguage: v)),
                  ),
                ),
                SettingRow(
                  title: l10n.tr('「有把握」的标准', 'Confidence Threshold'),
                  caption: l10n.tr(
                    '任务页「只整理有把握的」按这个标准挑选作品',
                    'Used by "Organize confident only" on the Tasks page',
                  ),
                  control: Segmented<double>(
                    options: {
                      0.6: l10n.tr('宽松', 'Relaxed'),
                      0.7: l10n.tr('标准', 'Standard'),
                      0.85: l10n.tr('严格', 'Strict'),
                    },
                    value:
                        const [0.6, 0.7, 0.85].contains(s.confidenceThreshold)
                        ? s.confidenceThreshold
                        : 0.7,
                    onChanged: (v) =>
                        _set((o) => o.copyWith(confidenceThreshold: v)),
                  ),
                ),
                SettingRow(
                  title: l10n.tr('媒体头探测', 'Container Media Probe'),
                  caption: l10n.tr(
                    '仅读取 MKV/MP4 文件头（不下载整片），自动补全分辨率、杜比视界/HDR 与音轨信息',
                    'Reads only MKV/MP4 headers (never whole files) to fill in resolution, Dolby Vision/HDR, and audio tracks',
                  ),
                  control: toggle(
                    'probe-media',
                    s.probeMedia,
                    (v) => s.copyWith(probeMedia: v),
                  ),
                ),
                SettingRow(
                  title: l10n.tr('Bangumi 动漫译名', 'Bangumi Anime Aliases'),
                  caption: l10n.tr(
                    '结合 Bangumi 与 AniList 补全番剧中文译名和日文原名，提高动漫匹配率',
                    'Use Bangumi alongside AniList to improve anime alias matching',
                  ),
                  control: toggle(
                    'enable-bangumi',
                    s.enableBangumi,
                    (v) => s.copyWith(enableBangumi: v),
                  ),
                ),
                SettingRow(
                  title: l10n.tr('清除 TMDB 缓存', 'Clear TMDB Cache'),
                  caption: l10n.tr(
                    '清除元数据和海报缓存，TMDB 上刚更新的信息没显示出来时用',
                    'Clear cached metadata and posters when recent TMDB updates are not showing up',
                  ),
                  control: OutlinedButton(
                    onPressed: () async {
                      ref.read(bootstrapProvider).tmdbCache?.clear();
                      await CachedImage.clearDiskCache();
                      ref.invalidate(metadataProvider);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            context.tr('已清除 TMDB 缓存', 'TMDB cache cleared'),
                          ),
                        ),
                      );
                    },
                    child: Text(l10n.tr('清除', 'Clear')),
                  ),
                ),
              ],
            ),
          ),
          SectionLabel(l10n.tr('外观', 'Appearance')),
          Panel(
            child: Rows(
              children: [
                SettingRow(
                  title: l10n.tr('语言', 'Language'),
                  caption: l10n.tr(
                    '默认在安装时跟随系统语言，可随时切换',
                    'Follows your system language by default; switch anytime',
                  ),
                  control: Segmented<AppLanguage>(
                    key: const ValueKey('app-language'),
                    options: {
                      AppLanguage.system: l10n.appLanguageLabel(
                        AppLanguage.system,
                      ),
                      AppLanguage.zh: l10n.appLanguageLabel(AppLanguage.zh),
                      AppLanguage.en: l10n.appLanguageLabel(AppLanguage.en),
                    },
                    value: s.appLanguage,
                    onChanged: (v) => _set((o) => o.copyWith(appLanguage: v)),
                  ),
                ),
                SettingRow(
                  title: l10n.tr('主题', 'Theme'),
                  control: Segmented<ThemeMode>(
                    options: {
                      ThemeMode.light: l10n.tr('浅色', 'Light'),
                      ThemeMode.dark: l10n.tr('深色', 'Dark'),
                      ThemeMode.system: l10n.tr('跟随系统', 'System'),
                    },
                    value: s.themeMode,
                    onChanged: (v) => _set((o) => o.copyWith(themeMode: v)),
                  ),
                ),
                SettingRow(
                  title: l10n.tr('强调色', 'Accent Color'),
                  control: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final a in AccentChoice.values)
                        Tooltip(
                          message: a.localizedLabel(l10n),
                          child: Hoverable(
                            key: ValueKey('accent-${a.name}'),
                            onTap: () => _set((o) => o.copyWith(accent: a)),
                            builder: (context, hover) {
                              final c =
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? a.dark
                                  : a.light;
                              return Container(
                                width: 22,
                                height: 22,
                                margin: const EdgeInsets.only(left: 8),
                                decoration: BoxDecoration(
                                  color: c,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: s.accent == a
                                        ? p.text
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                ),
                                child: s.accent == a
                                    ? Icon(
                                        CupertinoIcons.checkmark,
                                        size: 12,
                                        color: c.computeLuminance() > 0.5
                                            ? Colors.black
                                            : Colors.white,
                                      )
                                    : null,
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                SettingRow(
                  title: l10n.tr('启动时收起侧栏', 'Collapse Sidebar on Launch'),
                  control: toggle(
                    'sidebar-collapsed',
                    s.sidebarCollapsed,
                    (v) => s.copyWith(sidebarCollapsed: v),
                  ),
                ),
                SettingRow(
                  title: l10n.tr('减少动画', 'Reduce Motion'),
                  caption: l10n.tr(
                    '关闭页面切换和列表浮现动画',
                    'Disable page transition and list reveal animations',
                  ),
                  control: toggle(
                    'reduce-motion',
                    s.reduceMotion,
                    (v) => s.copyWith(reduceMotion: v),
                  ),
                ),
              ],
            ),
          ),
          SectionLabel(l10n.tr('通知', 'Notifications')),
          Panel(
            child: Rows(
              children: [
                SettingRow(
                  title: l10n.tr('识别完成时提示', 'Notify When Matching Finishes'),
                  caption: l10n.tr(
                    '通过应用内底部提示条提醒',
                    'Show an in-app banner at the bottom',
                  ),
                  control: toggle(
                    'notify-recognized',
                    s.notifyRecognized,
                    (v) => s.copyWith(notifyRecognized: v),
                  ),
                ),
                SettingRow(
                  title: l10n.tr('整理完成时提示', 'Notify When Organizing Finishes'),
                  caption: l10n.tr(
                    '通过应用内底部提示条提醒',
                    'Show an in-app banner at the bottom',
                  ),
                  control: toggle(
                    'notify-finished',
                    s.notifyFinished,
                    (v) => s.copyWith(notifyFinished: v),
                  ),
                ),
              ],
            ),
          ),
          SectionLabel(l10n.tr('数据', 'Data')),
          Panel(
            child: Rows(
              children: [
                SettingRow(
                  title: l10n.tr('清空已完成的任务', 'Clear Completed Tasks'),
                  caption: finished.isEmpty
                      ? l10n.tr('没有已完成的任务', 'No completed tasks')
                      : l10n.tr(
                          '共 ${finished.length} 条。不会动文件，但清空后就不能再撤销',
                          '${l10n.plural(finished.length, 'task')}. Your files stay untouched, but cleared tasks can no longer be undone',
                        ),
                  control: OutlinedButton(
                    key: const ValueKey('settings-clear-tasks'),
                    style: OutlinedButton.styleFrom(foregroundColor: p.danger),
                    onPressed: finished.isEmpty
                        ? null
                        : () => confirmDeleteTask(context, ref, finished),
                    child: Text(l10n.clear),
                  ),
                ),
                SettingRow(
                  title: l10n.tr('数据目录', 'Data Directory'),
                  caption: l10n.tr(
                    '设置、连接、任务记录和撤销日志都保存在这里（含敏感凭据 secrets.json，备份/分享前请注意）',
                    'Stores settings, connections, task history, and undo logs (includes sensitive credentials in secrets.json)',
                  ),
                  control: OutlinedButton(
                    onPressed: _openDataDir,
                    child: Text(
                      Platform.isWindows
                          ? l10n.tr('在资源管理器中打开', 'Open in Explorer')
                          : l10n.tr('在 Finder 中打开', 'Show in Finder'),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SectionLabel(l10n.tr('关于', 'About')),
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
                            Text(
                              l10n.appTitle,
                              style: const TextStyle(
                                fontSize: TypeScale.body,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              l10n.tr('版本 $appVersion', 'Version $appVersion'),
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
                  title: l10n.tr(
                    '基于 mnamer (MIT) 的思路',
                    'Inspired by mnamer (MIT)',
                  ),
                  caption: l10n.tr(
                    '影视元数据来自 TMDB，本产品使用 TMDB API 但未获得其认可或认证',
                    'Metadata provided by TMDB. This product uses the TMDB API but is not endorsed or certified by TMDB',
                  ),
                  control: TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (ctx) {
                        final t = ctx.l10n;
                        return MacSheet(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 480),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                22,
                                20,
                                22,
                                16,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    t.tr('开源许可', 'Open Source Licenses'),
                                    style: Theme.of(ctx).textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 12),
                                  SelectableText(
                                    t.tr(
                                      '命名与解析思路参考 mnamer（MIT License）。\n'
                                          '原版权声明见项目 LICENSES/mnamer-MIT.txt。\n\n'
                                          'SMB 连接使用 dart_smb2（BSD-3-Clause）和 libsmb2'
                                          '（GNU LGPL 2.1 或更新版本，动态加载，'
                                          'Copyright (C) Ronnie Sahlberg 及贡献者）。\n'
                                          '源码：https://github.com/sahlberg/libsmb2 ，'
                                          '说明见项目 LICENSES/libsmb2-NOTICE.txt。',
                                      'Naming and parsing design inspired by mnamer (MIT License).\n'
                                          'See LICENSES/mnamer-MIT.txt for the original notice.\n\n'
                                          'SMB support uses dart_smb2 (BSD-3-Clause) and libsmb2 '
                                          '(GNU LGPL 2.1 or later, dynamically loaded, '
                                          'Copyright (C) Ronnie Sahlberg and contributors).\n'
                                          'Source: https://github.com/sahlberg/libsmb2 — '
                                          'see LICENSES/libsmb2-NOTICE.txt.',
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: OutlinedButton(
                                      onPressed: () => Navigator.pop(ctx),
                                      child: Text(t.close),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    child: Text(l10n.tr('查看许可', 'Licenses')),
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
