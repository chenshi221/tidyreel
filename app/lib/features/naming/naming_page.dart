import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../l10n/l10n.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../../widgets/common.dart';
import 'naming_preview.dart';

const _playerNames = {
  TargetPlayer.vidhub: 'VidHub',
  TargetPlayer.infuse: 'Infuse',
  TargetPlayer.plex: 'Plex',
  TargetPlayer.jellyfin: 'Emby / Jellyfin',
};

const _episodeStyleExamples = {
  EpisodeStyle.upperPadded: 'S01E02',
  EpisodeStyle.lowerPadded: 's01e02',
  EpisodeStyle.lowerShort: 's1e2',
  EpisodeStyle.cross: '1x02',
  EpisodeStyle.lowerDotted: 's01.e02',
};

String _fieldLabel(NameField field, AppL10n l10n) => switch (field) {
  NameField.title => l10n.tr('标题', 'Title'),
  NameField.year => l10n.tr('年份', 'Year'),
  NameField.episode => l10n.tr('季集', 'Season & Ep'),
  NameField.episodeTitle => l10n.tr('分集标题', 'Episode Title'),
  NameField.extraInfo => l10n.tr('附加信息', 'Extra Info'),
};

String _varTooltip(String variable, AppL10n l10n) => switch (variable) {
  '{title}' => l10n.tr('中文或首选标题', 'Localized or preferred title'),
  '{en_title}' => l10n.tr('英文标题', 'English title'),
  '{original_title}' => l10n.tr('原语言标题', 'Original-language title'),
  '{year}' => l10n.tr('发行或首播年份', 'Release or first-air year'),
  '{season}' => l10n.tr('季号（不补零，如 1）', 'Season number (unpadded, e.g. 1)'),
  '{season:02}' => l10n.tr('两位季号（如 01）', 'Two-digit season number (e.g. 01)'),
  '{episode:02}' => l10n.tr('两位集号（如 02）', 'Two-digit episode number (e.g. 02)'),
  '{episode_title}' => l10n.tr('分集标题（来自 TMDB）', 'Episode title (from TMDB)'),
  '{extra_info}' => l10n.tr(
    '附加信息（分辨率、HDR 等）',
    'Extra tags (resolution, HDR, etc.)',
  ),
  '{group}' => l10n.tr('发布组名称', 'Release group name'),
  '{tmdbid}' => l10n.tr('TMDB 数字 ID', 'Numeric TMDB ID'),
  '{tmdb_tag}' => l10n.tr(
    'TMDB ID 标签（如 {tmdb-1668}）',
    'TMDB ID tag (e.g. {tmdb-1668})',
  ),
  _ => variable,
};

const _folderVars = [
  '{title}',
  '{en_title}',
  '{original_title}',
  '{year}',
  '{tmdbid}',
  '{tmdb_tag}',
];

const _movieCustomVars = [
  '{title}',
  '{en_title}',
  '{original_title}',
  '{year}',
  '{extra_info}',
  '{group}',
  '{tmdbid}',
  '{tmdb_tag}',
];

const _tvCustomVars = [
  '{title}',
  '{en_title}',
  '{original_title}',
  '{year}',
  '{season:02}',
  '{episode:02}',
  '{episode_title}',
  '{extra_info}',
  '{group}',
  '{tmdbid}',
  '{tmdb_tag}',
];

/// 命名规则页（PLAN §3.2）: options on the left, a pinned live preview right.
class NamingPage extends ConsumerStatefulWidget {
  const NamingPage({super.key});

  @override
  ConsumerState<NamingPage> createState() => _NamingPageState();
}

/// 季文件夹 presets: (what it looks like, template).
const _seasonPresets = [
  ('Season 01', 'Season {season:02}'),
  ('Season 1', 'Season {season}'),
  ('season 01', 'season {season:02}'),
  ('S01', 'S{season:02}'),
  ('第 1 季', '第 {season} 季'),
];

class _NamingPageState extends ConsumerState<NamingPage> {
  var _tv = false;

  Future<void> _selectPlayer(TargetPlayer next) async {
    final l10n = context.l10n;
    final current = ref.read(namingProfileProvider);
    final preset = localizedPlayerPreset(current.player, isEn: l10n.isEn);
    final customized =
        current != preset && current != NamingProfile.forPlayer(current.player);
    if (next == current.player && !customized) return;
    if (customized) {
      final ok = await confirmDialog(
        context,
        title: l10n.tr(
          '切换到 ${_playerNames[next]!} 预设？',
          'Switch to ${_playerNames[next]!} preset?',
        ),
        content: Text(
          l10n.tr(
            '切换播放器预设会重置电影和剧集的命名选项、自定义模板以及替换规则。',
            'Switching player presets resets movie and TV naming options, custom templates, and rewrite rules.',
          ),
        ),
        confirmLabel: l10n.tr('切换并重置', 'Switch & Reset'),
      );
      if (!ok || !mounted) return;
    }
    ref
        .read(namingProfileProvider.notifier)
        .set(localizedPlayerPreset(next, isEn: l10n.isEn));
  }

  Future<void> _handleExportImport(_ExportImportAction action) async {
    final l10n = context.l10n;
    final profile = ref.read(namingProfileProvider);
    final rules = ref.read(titleRulesProvider);
    switch (action) {
      case _ExportImportAction.copyJson:
        final jsonStr = encodeNamingBundle(profile, rules);
        await Clipboard.setData(ClipboardData(text: jsonStr));
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                l10n.tr(
                  '已复制命名与片名规则 JSON 到剪贴板',
                  'Copied naming & title rules JSON to clipboard',
                ),
              ),
            ),
          );
      case _ExportImportAction.saveFile:
        final jsonStr = encodeNamingBundle(profile, rules);
        try {
          final location = await getSaveLocation(
            suggestedName: 'tidyreel-naming.json',
            acceptedTypeGroups: const [
              XTypeGroup(label: 'JSON', extensions: ['json']),
            ],
          );
          if (location == null || !mounted) return;
          await File(location.path).writeAsString(jsonStr);
          if (!mounted) return;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  l10n.tr(
                    '已导出到 ${location.path}',
                    'Exported to ${location.path}',
                  ),
                ),
              ),
            );
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(content: Text(l10n.tr('导出失败：$e', 'Export failed: $e'))),
            );
        }
      case _ExportImportAction.importJson:
        final bundle = await showDialog<NamingBundle>(
          context: context,
          builder: (_) => const _ImportNamingDialog(),
        );
        if (bundle == null || !mounted) return;
        if (bundle.naming != null) {
          ref.read(namingProfileProvider.notifier).set(bundle.naming!);
        }
        if (bundle.titleRules != null) {
          ref.read(titleRulesProvider.notifier).set(bundle.titleRules!);
        }
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                l10n.tr('已导入命名与片名规则', 'Imported naming & title rules'),
              ),
            ),
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final profile = ref.watch(namingProfileProvider);
    return PageScaffold(
      title: l10n.tr('命名规则', 'Naming Rules'),
      actions: [
        Segmented<bool>(
          options: {false: l10n.movie, true: l10n.tvShow},
          value: _tv,
          onChanged: (v) => setState(() => _tv = v),
        ),
        const SizedBox(width: 6),
        _PlayerMenu(value: profile.player, onChanged: _selectPlayer),
        const SizedBox(width: 6),
        _ExportImportMenu(onSelected: _handleExportImport),
      ],
      child: Padding(
        padding: const EdgeInsets.fromLTRB(48, 0, 40, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 11,
              child: _OptionsPanel(key: ValueKey(_tv), isTv: _tv),
            ),
            const SizedBox(width: 24),
            Expanded(
              flex: 9,
              child: Padding(
                padding: const EdgeInsets.only(top: 22),
                child: _Preview(isTv: _tv),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayerMenu extends StatelessWidget {
  final TargetPlayer value;
  final ValueChanged<TargetPlayer> onChanged;

  const _PlayerMenu({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = Palette.of(context);
    return PopupMenuButton<TargetPlayer>(
      key: const ValueKey('player'),
      tooltip: l10n.tr('目标播放器', 'Target player'),
      initialValue: value,
      position: PopupMenuPosition.under,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final t in TargetPlayer.values)
          PopupMenuItem(value: t, height: 30, child: Text(_playerNames[t]!)),
      ],
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: p.panel,
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: p.lineStrong, width: hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.play_rectangle, size: 14, color: p.textMuted),
            const SizedBox(width: 6),
            Text(
              _playerNames[value]!,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
            const SizedBox(width: 4),
            Icon(
              CupertinoIcons.chevron_up_chevron_down,
              size: 11,
              color: p.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

enum _ExportImportAction { copyJson, saveFile, importJson }

class _ExportImportMenu extends StatelessWidget {
  final ValueChanged<_ExportImportAction> onSelected;

  const _ExportImportMenu({required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = Palette.of(context);
    return PopupMenuButton<_ExportImportAction>(
      key: const ValueKey('naming-export-import'),
      tooltip: l10n.tr('导出或导入命名与片名规则', 'Export or import naming & title rules'),
      position: PopupMenuPosition.under,
      onSelected: onSelected,
      itemBuilder: (_) => [
        PopupMenuItem(
          key: const ValueKey('naming-export-clipboard'),
          value: _ExportImportAction.copyJson,
          height: 30,
          child: Row(
            children: [
              const Icon(CupertinoIcons.doc_on_clipboard, size: 14),
              const SizedBox(width: 8),
              Text(l10n.tr('导出到剪贴板', 'Copy JSON to Clipboard')),
            ],
          ),
        ),
        PopupMenuItem(
          key: const ValueKey('naming-export-file'),
          value: _ExportImportAction.saveFile,
          height: 30,
          child: Row(
            children: [
              const Icon(CupertinoIcons.square_arrow_up, size: 14),
              const SizedBox(width: 8),
              Text(l10n.tr('导出为 JSON 文件', 'Export to JSON File')),
            ],
          ),
        ),
        const PopupMenuDivider(height: 9),
        PopupMenuItem(
          key: const ValueKey('naming-import-json'),
          value: _ExportImportAction.importJson,
          height: 30,
          child: Row(
            children: [
              const Icon(CupertinoIcons.square_arrow_down, size: 14),
              const SizedBox(width: 8),
              Text(l10n.tr('导入 JSON…', 'Import JSON…')),
            ],
          ),
        ),
      ],
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: p.panel,
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: p.lineStrong, width: hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              CupertinoIcons.arrow_up_arrow_down,
              size: 13,
              color: p.textMuted,
            ),
            const SizedBox(width: 6),
            Text(
              l10n.tr('导出 / 导入', 'Export / Import'),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImportNamingDialog extends StatefulWidget {
  const _ImportNamingDialog();

  @override
  State<_ImportNamingDialog> createState() => _ImportNamingDialogState();
}

class _ImportNamingDialogState extends State<_ImportNamingDialog> {
  final _controller = TextEditingController();
  Object? _fileError;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'JSON', extensions: ['json']),
        ],
      );
      if (file == null || !mounted) return;
      final content = await file.readAsString();
      if (!mounted) return;
      setState(() {
        _fileError = null;
        _controller.text = content;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _fileError = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = Palette.of(context);
    final theme = Theme.of(context);
    final raw = _controller.text;
    final parsed = raw.trim().isEmpty
        ? null
        : decodeNamingBundle(raw, l10n: l10n);
    final bundle = parsed?.bundle;
    final error = _fileError != null
        ? l10n.tr('读取文件失败：$_fileError', 'Failed to read file: $_fileError')
        : parsed?.error;

    return MacSheet(
      key: const ValueKey('naming-import-dialog'),
      child: SizedBox(
        width: 540,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.tr('导入命名与片名规则', 'Import Naming & Title Rules'),
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('naming-import-pick-file'),
                    onPressed: _pickFile,
                    icon: const Icon(CupertinoIcons.folder, size: 13),
                    label: Text(l10n.tr('从文件选择…', 'Choose File…')),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                l10n.tr(
                  '粘贴导出的 JSON 内容，或点击右上角从本地文件读取。确认后会覆盖当前命名规则与片名规则。',
                  'Paste exported JSON below or load from a local file. Importing will overwrite your current naming and title rules.',
                ),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('naming-import-input'),
                controller: _controller,
                maxLines: 8,
                minLines: 5,
                style: const TextStyle(
                  fontFamily: monoFamily,
                  fontFamilyFallback: [...monoFallback, ...sansFallback],
                  fontSize: TypeScale.small,
                ),
                decoration: const InputDecoration(
                  hintText: '{\n  "version": 1,\n  "naming": { ... },\n  "titleRules": { ... }\n}',
                  alignLabelWithHint: true,
                ),
                onChanged: (_) => setState(() => _fileError = null),
              ),
              if (error != null) ...[
                const SizedBox(height: 10),
                Container(
                  key: const ValueKey('naming-import-error'),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: p.danger.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(Radii.sm),
                    border: Border.all(
                      color: p.danger.withValues(alpha: 0.35),
                      width: hairline,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        CupertinoIcons.exclamationmark_circle_fill,
                        size: 15,
                        color: p.danger,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          error,
                          style: TextStyle(
                            fontSize: TypeScale.small,
                            color: p.danger,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (bundle != null) ...[
                const SizedBox(height: 10),
                Container(
                  key: const ValueKey('naming-import-preview'),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: p.success.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(Radii.sm),
                    border: Border.all(
                      color: p.success.withValues(alpha: 0.30),
                      width: hairline,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            CupertinoIcons.checkmark_circle_fill,
                            size: 14,
                            color: p.success,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            l10n.tr(
                              '校验通过，将应用以下配置',
                              'Valid configuration ready to apply',
                            ),
                            style: TextStyle(
                              fontSize: TypeScale.small,
                              fontWeight: FontWeight.w600,
                              color: p.text,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        l10n.tr(
                          '播放器预设：${bundle.naming != null ? _playerNames[bundle.naming!.player]! : '保持现有'}',
                          'Player preset: ${bundle.naming != null ? _playerNames[bundle.naming!.player]! : 'Keep current'}',
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: p.text,
                        ),
                      ),
                      if (bundle.naming != null)
                        Text(
                          l10n.tr(
                            '替换规则：共 ${bundle.naming!.movie.rewrites.length + bundle.naming!.tv.rewrites.length} 条'
                                '（电影 ${bundle.naming!.movie.rewrites.length} 条 · 剧集 ${bundle.naming!.tv.rewrites.length} 条）',
                            'Rewrite rules: ${bundle.naming!.movie.rewrites.length + bundle.naming!.tv.rewrites.length} total '
                                '(Movies ${bundle.naming!.movie.rewrites.length} · TV ${bundle.naming!.tv.rewrites.length})',
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: p.text,
                          ),
                        ),
                      Text(
                        bundle.titleRules != null
                            ? l10n.tr(
                                '片名规则：清洗 ${bundle.titleRules!.cleanups.length} 条 · 指定匹配 ${bundle.titleRules!.pins.length} 条',
                                'Title rules: ${bundle.titleRules!.cleanups.length} cleanups · ${bundle.titleRules!.pins.length} pinned matches',
                              )
                            : l10n.tr('片名规则：保持现有', 'Title rules: Keep current'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: p.text,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(l10n.cancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('naming-import-confirm'),
                    onPressed: bundle == null
                        ? null
                        : () => Navigator.pop(context, bundle),
                    child: Text(l10n.tr('导入并应用', 'Import & Apply')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

NamingOptions _optionsOf(NamingProfile p, bool tv) => tv ? p.tv : p.movie;

/// Before → after, plus the library path drawn as a small tree, scenario
/// presets, and a custom filename live tester.
class _Preview extends ConsumerStatefulWidget {
  final bool isTv;

  const _Preview({required this.isTv});

  @override
  ConsumerState<_Preview> createState() => _PreviewState();
}

class _PreviewState extends ConsumerState<_Preview> {
  var _movieScenarioId = 'standard';
  var _tvScenarioId = 'standard';
  final _customInput = TextEditingController();

  @override
  void dispose() {
    _customInput.dispose();
    super.dispose();
  }

  String _kindLabel(MediaKind k, AppL10n l10n) => switch (k) {
    MediaKind.movie => l10n.movie,
    MediaKind.episode => l10n.tvShow,
    MediaKind.special => l10n.specials,
    MediaKind.extra => l10n.tr('花絮', 'Extras'),
    MediaKind.unknown => l10n.tr('未知', 'Unknown'),
  };

  String _episodeSummary(ParsedName p, AppL10n l10n) {
    if (p.episodes.isNotEmpty) {
      final s = p.season != null
          ? 'S${p.season!.toString().padLeft(2, '0')}'
          : '';
      final eStart = 'E${p.episodes.first.toString().padLeft(2, '0')}';
      final eEnd = p.episodes.length > 1 && p.episodes.last > p.episodes.first
          ? '-E${p.episodes.last.toString().padLeft(2, '0')}'
          : '';
      return '$s$eStart$eEnd';
    }
    if (p.absolute != null) {
      return l10n.tr('第 ${p.absolute} 集（绝对集）', 'Ep ${p.absolute} (absolute)');
    }
    if (p.airDate != null) {
      return l10n.tr('日期 ${fmtDate(p.airDate)}', 'Date ${fmtDate(p.airDate)}');
    }
    if (p.season != null) {
      return 'S${p.season!.toString().padLeft(2, '0')}';
    }
    return '—';
  }

  String _versionSummary(ParsedName p) {
    final parts = <String>[
      if (p.edition != null && p.edition!.isNotEmpty) p.edition!,
      if (p.partLabel != null && p.partLabel!.isNotEmpty) p.partLabel!,
    ];
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  String _extraSummary(ParsedName p, AppL10n l10n) {
    final parts = <String>[
      if (p.extraInfo != null && p.extraInfo!.isNotEmpty)
        p.extraInfo!
      else if (p.resolution != null && p.resolution!.isNotEmpty)
        p.resolution!,
      if (p.group != null && p.group!.isNotEmpty)
        l10n.tr('发布组 ${p.group}', 'Group ${p.group}'),
    ];
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isTv = widget.isTv;
    final p = Palette.of(context);
    final theme = Theme.of(context);
    final profile = ref.watch(namingProfileProvider);
    final o = _optionsOf(profile, isTv);
    final scenarios = isTv ? tvNamingScenarios : movieNamingScenarios;
    final selectedId = isTv ? _tvScenarioId : _movieScenarioId;
    final scenario = scenarios.firstWhere(
      (s) => s.id == selectedId,
      orElse: () => scenarios.first,
    );
    final sample = scenario.buildSample(o);
    final kind = isTv ? MediaKind.episode : MediaKind.movie;
    final name = renderNaming(o, kind, sample);
    final folder = renderFolder(o.folderTemplate, sample, o.rewrites);
    final season = isTv
        ? renderFolder(o.seasonFolderTemplate, sample, o.rewrites)
        : null;
    final tree = <(String text, bool isError)>[
      (isTv ? profile.tvDir : profile.movieDir, false),
      (folder.text ?? folder.localizedDisplay(l10n), folder.text == null),
      if (season != null)
        (season.text ?? season.localizedDisplay(l10n), season.text == null),
    ];
    final mono = TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: [...monoFallback, ...sansFallback],
      fontSize: TypeScale.small,
      height: 1.5,
    );

    Widget fileLine(IconData icon, String text, Color color, {Key? key}) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 14, color: color),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SelectableText(
            text,
            key: key,
            style: mono.copyWith(color: color),
          ),
        ),
      ],
    );

    final customText = _customInput.text.trim();
    final customPreview = customText.isEmpty
        ? null
        : previewCustomFilename(customText, profile, fallbackIsTv: isTv);

    Widget fieldChip(String label, String value, {Color? valueColor}) =>
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: p.sidebar,
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(color: p.line, width: hairline),
          ),
          child: RichText(
            text: TextSpan(
              style: TextStyle(
                fontSize: TypeScale.small,
                color: p.textFaint,
                fontFamilyFallback: sansFallback,
              ),
              children: [
                TextSpan(text: '$label '),
                TextSpan(
                  text: value,
                  style: TextStyle(
                    color: valueColor ?? p.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        );

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 28),
      child: Panel(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  l10n.tr('实时示例', 'Live Preview'),
                  style: theme.textTheme.titleSmall,
                ),
                const Spacer(),
                Tag(_playerNames[profile.player]!),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final s in scenarios)
                  _StyleChip(
                    key: ValueKey('sample-${s.id}'),
                    label: s.localizedLabel(l10n),
                    selected: scenario.id == s.id,
                    onTap: () => setState(() {
                      if (isTv) {
                        _tvScenarioId = s.id;
                      } else {
                        _movieScenarioId = s.id;
                      }
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              l10n.tr('原文件名', 'Original filename'),
              style: theme.textTheme.labelSmall,
            ),
            const SizedBox(height: 4),
            fileLine(CupertinoIcons.doc, sample.original, p.textFaint),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Icon(
                CupertinoIcons.arrow_down,
                size: 14,
                color: p.textMuted,
              ),
            ),
            Text(l10n.tr('整理后', 'Renamed'), style: theme.textTheme.labelSmall),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: name.text == null
                    ? p.danger.withValues(alpha: 0.06)
                    : p.sidebar,
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(
                  color: name.text == null
                      ? p.danger.withValues(alpha: 0.4)
                      : p.line,
                  width: hairline,
                ),
              ),
              child: fileLine(
                CupertinoIcons.film,
                name.localizedDisplay(l10n),
                name.text == null ? p.danger : p.text,
                key: const ValueKey('example-name'),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              l10n.tr('移动到媒体库时', 'Library path'),
              style: theme.textTheme.labelSmall,
            ),
            const SizedBox(height: 6),
            for (var i = 0; i < tree.length; i++)
              Padding(
                padding: EdgeInsets.only(left: 16.0 * i, bottom: 2),
                child: fileLine(
                  tree[i].$2
                      ? CupertinoIcons.exclamationmark_triangle
                      : CupertinoIcons.folder_fill,
                  tree[i].$1,
                  tree[i].$2 ? p.danger : p.textMuted,
                ),
              ),
            if (name.text != null)
              Padding(
                padding: EdgeInsets.only(left: 16.0 * tree.length),
                child: fileLine(CupertinoIcons.film, name.text!, p.text),
              ),
            if (isTv) ...[
              const SizedBox(height: 10),
              Text(
                o.singleSeasonFolder
                    ? l10n.tr(
                        '单季剧也会建季文件夹（${season?.text ?? o.seasonFolderTemplate}）',
                        'Single-season shows also use a season folder (${season?.text ?? o.seasonFolderTemplate})',
                      )
                    : l10n.tr(
                        '单季剧省略季文件夹：${profile.tvDir}/${folder.text ?? '…'}/${name.text ?? '…'}',
                        'Single-season shows skip season folder: ${profile.tvDir}/${folder.text ?? '…'}/${name.text ?? '…'}',
                      ),
                key: const ValueKey('single-season-preview'),
                style: theme.textTheme.bodySmall?.copyWith(color: p.textFaint),
              ),
            ],
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Divider(),
            ),
            Text(
              l10n.tr('自定义测试', 'Custom Filename Tester'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              l10n.tr(
                '粘贴任意真实文件名（或带目录路径），实时查看解析字段与目标文件名',
                'Paste any filename (or path) to inspect parsed fields and the rendered target name',
              ),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('custom-filename-tester'),
              controller: _customInput,
              style: mono,
              decoration: InputDecoration(
                hintText: l10n.tr(
                  '如 [VCB-Studio] Frieren [01][Ma10p_1080p].mkv',
                  'e.g. [VCB-Studio] Frieren [01][Ma10p_1080p].mkv',
                ),
                prefixIcon: const Icon(CupertinoIcons.lab_flask, size: 14),
                suffixIcon: customText.isEmpty
                    ? null
                    : IconButton(
                        tooltip: l10n.clear,
                        iconSize: 13,
                        icon: const Icon(CupertinoIcons.xmark_circle_fill),
                        onPressed: () => setState(() => _customInput.clear()),
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (customPreview != null) ...[
              const SizedBox(height: 10),
              Wrap(
                key: const ValueKey('custom-parsed-fields'),
                spacing: 6,
                runSpacing: 6,
                children: [
                  fieldChip(
                    l10n.tr('类型', 'Kind'),
                    _kindLabel(customPreview.parsed.kind, l10n),
                  ),
                  fieldChip(
                    l10n.tr('标题', 'Title'),
                    customPreview.parsed.title ?? '—',
                  ),
                  fieldChip(
                    l10n.tr('年份', 'Year'),
                    customPreview.parsed.year?.toString() ?? '—',
                  ),
                  fieldChip(
                    l10n.tr('季集', 'Episode'),
                    _episodeSummary(customPreview.parsed, l10n),
                  ),
                  fieldChip(
                    l10n.tr('版本', 'Edition'),
                    _versionSummary(customPreview.parsed),
                  ),
                  fieldChip(
                    l10n.tr('附加信息', 'Extra'),
                    _extraSummary(customPreview.parsed, l10n),
                  ),
                  fieldChip(
                    l10n.tr('外部ID', 'External ID'),
                    customPreview.parsed.externalId?.toString() ?? '—',
                  ),
                  fieldChip(
                    l10n.tr('置信度', 'Confidence'),
                    '${(customPreview.parsed.confidence * 100).round()}%',
                    valueColor: customPreview.parsed.confidence >= 0.8
                        ? p.success
                        : customPreview.parsed.confidence >= 0.5
                        ? p.warning
                        : p.danger,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                l10n.tr(
                  '当前规则目标文件名（按${customPreview.isTv ? '剧集' : '电影'}规则）',
                  'Target filename (${customPreview.isTv ? 'TV' : 'Movie'} rules)',
                ),
                style: theme.textTheme.labelSmall,
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: customPreview.renderedName.text == null
                      ? p.danger.withValues(alpha: 0.06)
                      : p.sidebar,
                  borderRadius: BorderRadius.circular(Radii.sm),
                  border: Border.all(
                    color: customPreview.renderedName.text == null
                        ? p.danger.withValues(alpha: 0.4)
                        : p.line,
                    width: hairline,
                  ),
                ),
                child: fileLine(
                  CupertinoIcons.film,
                  customPreview.renderedName.localizedDisplay(l10n),
                  customPreview.renderedName.text == null ? p.danger : p.text,
                  key: const ValueKey('custom-rendered-name'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OptionsPanel extends ConsumerWidget {
  final bool isTv;

  const _OptionsPanel({super.key, required this.isTv});

  void _edit(WidgetRef ref, NamingOptions Function(NamingOptions) f) {
    final p = ref.read(namingProfileProvider);
    ref
        .read(namingProfileProvider.notifier)
        .set(isTv ? p.copyWith(tv: f(p.tv)) : p.copyWith(movie: f(p.movie)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final p = Palette.of(context);
    final o = _optionsOf(ref.watch(namingProfileProvider), isTv);
    final kind = isTv ? MediaKind.episode : MediaKind.movie;
    final advanced = o.customTemplate != null;
    final suffix = isTv ? 'tv' : 'movie';
    final order = [
      for (final f in o.order)
        if (isTv || (f != NameField.episode && f != NameField.episodeTitle)) f,
    ];

    Widget sw(String key, bool v, ValueChanged<bool> f) =>
        MacSwitch(key: ValueKey('$key-$suffix'), value: v, onChanged: f);

    final fileNameOptions = <Widget>[
      SectionLabel(l10n.tr('标题', 'Title')),
      Panel(
        child: Rows(
          children: [
            SettingRow(
              title: l10n.tr('标题语言', 'Title language'),
              caption: l10n.isEn
                  ? 'Falls back to original title when no English title exists'
                  : null,
              control: Segmented<TitleLanguage>(
                options: {
                  TitleLanguage.chineseFirst: l10n.tr('中文优先', 'Chinese'),
                  TitleLanguage.englishFirst: l10n.tr('英文（原名）优先', 'English'),
                },
                value: o.titleLanguage,
                onChanged: (v) =>
                    _edit(ref, (o) => o.copyWith(titleLanguage: v)),
              ),
            ),
            SettingRow(
              title: l10n.tr('同时用两种语言', 'Bilingual titles'),
              caption: l10n.tr('如：老友记.Friends', 'e.g. Friends.老友记'),
              control: sw(
                'bilingual',
                o.bilingual,
                (v) => _edit(ref, (o) => o.copyWith(bilingual: v)),
              ),
            ),
            SettingRow(
              title: l10n.tr('年份', 'Year'),
              control: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (o.includeYear) ...[
                    Segmented<bool>(
                      options: const {false: '1999', true: '(1999)'},
                      value: o.yearInParens,
                      onChanged: (v) =>
                          _edit(ref, (o) => o.copyWith(yearInParens: v)),
                    ),
                    const SizedBox(width: 8),
                  ],
                  sw(
                    'year',
                    o.includeYear,
                    (v) => _edit(ref, (o) => o.copyWith(includeYear: v)),
                  ),
                ],
              ),
            ),
            if (isTv)
              SettingRow(
                title: l10n.tr('剧集年份取哪个', 'Series year'),
                control: Segmented<ShowYearSource>(
                  options: {
                    ShowYearSource.firstSeason: l10n.tr('首季年份', 'First season'),
                    ShowYearSource.seasonAir: l10n.tr('当季首播年份', 'This season'),
                  },
                  value: o.showYear,
                  onChanged: (v) => _edit(ref, (o) => o.copyWith(showYear: v)),
                ),
              ),
          ],
        ),
      ),
      if (isTv) ...[
        SectionLabel(l10n.tr('季集', 'Episodes')),
        Panel(
          child: Rows(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Row(
                  children: [
                    Expanded(child: Text(l10n.tr('季集格式', 'Episode format'))),
                    Wrap(
                      spacing: 4,
                      children: [
                        for (final s in EpisodeStyle.values)
                          _StyleChip(
                            key: ValueKey('style-${s.name}'),
                            label: _episodeStyleExamples[s]!,
                            selected: o.episodeStyle == s,
                            onTap: () =>
                                _edit(ref, (o) => o.copyWith(episodeStyle: s)),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              SettingRow(
                title: l10n.tr('分集标题', 'Episode title'),
                caption: l10n.tr(
                  '从 TMDB 取每集的名字加在文件名里',
                  'Include each episode title from TMDB in the filename',
                ),
                control: sw(
                  'episode-title',
                  o.episodeTitle,
                  (v) => _edit(ref, (o) => o.copyWith(episodeTitle: v)),
                ),
              ),
            ],
          ),
        ),
      ],
      SectionLabel(l10n.tr('附加内容', 'Additional Tags')),
      Panel(
        child: Rows(
          children: [
            SettingRow(
              title: l10n.tr('附加信息', 'Extra info'),
              caption: l10n.tr(
                '保留分辨率、HDR、音轨，如 2160p.DV',
                'Keep resolution, HDR, and audio tags, e.g. 2160p.DV',
              ),
              control: sw(
                'extra',
                o.extraInfo,
                (v) => _edit(ref, (o) => o.copyWith(extraInfo: v)),
              ),
            ),
            SettingRow(
              title: l10n.tr('发布组', 'Release group'),
              caption: l10n.tr('在末尾加 -GRP', 'Append -GRP at the end'),
              control: sw(
                'group',
                o.releaseGroup,
                (v) => _edit(ref, (o) => o.copyWith(releaseGroup: v)),
              ),
            ),
            SettingRow(
              title: l10n.tr('TMDB ID 标签', 'TMDB ID tag'),
              caption: '{tmdb-12345}',
              control: sw(
                'tmdbid',
                o.tmdbIdTag,
                (v) => _edit(ref, (o) => o.copyWith(tmdbIdTag: v)),
              ),
            ),
            SettingRow(
              title: l10n.tr('分隔符', 'Separator'),
              control: Segmented<String>(
                options: {
                  '.': ' . ',
                  '_': ' _ ',
                  ' ': l10n.tr('空格', 'Space'),
                  '-': ' - ',
                },
                value: o.separator,
                onChanged: (v) => _edit(ref, (o) => o.copyWith(separator: v)),
              ),
            ),
          ],
        ),
      ),
      SectionLabel(l10n.tr('字段顺序', 'Field Order')),
      Panel(
        child: ReorderableListView(
          key: ValueKey('order-$suffix'),
          shrinkWrap: true,
          buildDefaultDragHandles: false,
          physics: const NeverScrollableScrollPhysics(),
          onReorderItem: (from, to) {
            final next = [...order];
            next.insert(to, next.removeAt(from));
            // Fields that don't apply here keep their relative place at the end.
            _edit(
              ref,
              (o) => o.copyWith(
                order: [
                  ...next,
                  for (final f in o.order)
                    if (!next.contains(f)) f,
                ],
              ),
            );
          },
          children: [
            for (var i = 0; i < order.length; i++)
              Container(
                key: ValueKey(order[i]),
                decoration: BoxDecoration(
                  color: p.panel,
                  border: i == 0
                      ? null
                      : Border(
                          top: BorderSide(color: p.line, width: hairline),
                        ),
                ),
                padding: const EdgeInsets.fromLTRB(14, 5, 6, 5),
                child: Row(
                  children: [
                    Text(
                      '${i + 1}',
                      style: TextStyle(fontSize: 12, color: p.textFaint),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(_fieldLabel(order[i], l10n))),
                    ReorderableDragStartListener(
                      index: i,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          child: Icon(
                            CupertinoIcons.line_horizontal_3,
                            size: 14,
                            color: p.textFaint,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ];

    return ListView(
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: advanced ? 0.45 : 1,
          child: AbsorbPointer(
            absorbing: advanced,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: fileNameOptions,
            ),
          ),
        ),
        SectionLabel(l10n.tr('文件夹', 'Folders')),
        Panel(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            children: [
              FormRow(
                label: l10n.tr('作品文件夹', 'Title folder'),
                child: _TextOption(
                  key: ValueKey('folder-$suffix'),
                  value: o.folderTemplate,
                  vars: _folderVars,
                  onChanged: (v) =>
                      _edit(ref, (o) => o.copyWith(folderTemplate: v)),
                ),
              ),
              if (isTv)
                FormRow(
                  label: l10n.tr('季文件夹', 'Season folder'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final (label, template) in _seasonPresets)
                            _StyleChip(
                              key: ValueKey('season-preset-$label'),
                              label: label,
                              selected: o.seasonFolderTemplate == template,
                              onTap: () => _edit(
                                ref,
                                (o) =>
                                    o.copyWith(seasonFolderTemplate: template),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _TextOption(
                        key: const ValueKey('season-folder'),
                        value: o.seasonFolderTemplate,
                        vars: const ['{season}', '{season:02}'],
                        onChanged: (v) => _edit(
                          ref,
                          (o) => o.copyWith(seasonFolderTemplate: v),
                        ),
                      ),
                    ],
                  ),
                ),
              if (isTv)
                FormRow(
                  label: l10n.tr('单季剧', 'Single season'),
                  help: l10n.tr(
                    '打开：只有一季的剧也放进季文件夹。多季剧总是分季文件夹',
                    'When on, single-season shows also get a season folder. Multi-season shows always use season folders.',
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: sw(
                      'single-season-folder',
                      o.singleSeasonFolder,
                      (v) =>
                          _edit(ref, (o) => o.copyWith(singleSeasonFolder: v)),
                    ),
                  ),
                ),
            ],
          ),
        ),
        SectionLabel(l10n.tr('高级', 'Advanced')),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingRow(
                title: l10n.tr('直接编辑模板', 'Custom filename template'),
                caption: l10n.tr(
                  '开启后上面的文件名选项变为只读，文件夹设置仍可修改',
                  'Locks the filename options above; folder settings remain editable',
                ),
                control: sw(
                  'advanced',
                  advanced,
                  (v) => _edit(
                    ref,
                    (o) => o.copyWith(
                      customTemplate: () =>
                          v ? compiledOrDefault(o, kind) : null,
                    ),
                  ),
                ),
              ),
              if (advanced)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                  child: _TextOption(
                    key: ValueKey('custom-$suffix'),
                    value: o.customTemplate!,
                    mono: true,
                    vars: isTv ? _tvCustomVars : _movieCustomVars,
                    onChanged: (v) =>
                        _edit(ref, (o) => o.copyWith(customTemplate: () => v)),
                  ),
                ),
            ],
          ),
        ),
        SectionLabel(
          l10n.tr('替换规则', 'Rewrite Rules'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Tag(
                isTv
                    ? l10n.tr('仅剧集', 'TV only')
                    : l10n.tr('仅电影', 'Movies only'),
              ),
              const SizedBox(width: 6),
              TextButton.icon(
                key: const ValueKey('add-rewrite'),
                onPressed: () => _edit(
                  ref,
                  (o) => o.copyWith(
                    rewrites: [...o.rewrites, const NameRewrite('', '')],
                  ),
                ),
                icon: const Icon(CupertinoIcons.plus, size: 12),
                label: Text(l10n.tr('添加', 'Add')),
              ),
            ],
          ),
        ),
        Panel(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: o.rewrites.isEmpty
              ? Text(
                  l10n.tr(
                    '生成名称后再按正则查找替换，文件和文件夹都生效。'
                        r'比如把 Season (\d+) 换成 S$1',
                    'Apply regex find-and-replace to generated file and folder names. '
                        r'For example, replace Season (\d+) with S$1',
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                )
              : Column(
                  children: [
                    for (final (i, r) in o.rewrites.indexed)
                      _RewriteRow(
                        key: ValueKey('rewrite-$suffix-$i'),
                        value: r,
                        onChanged: (v) => _edit(
                          ref,
                          (o) => o.copyWith(rewrites: [...o.rewrites]..[i] = v),
                        ),
                        onRemove: () => _edit(
                          ref,
                          (o) => o.copyWith(
                            rewrites: [...o.rewrites]..removeAt(i),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        const Padding(padding: EdgeInsets.only(top: 22), child: Divider()),
        const _TitleRulesSection(),
      ],
    );
  }
}

/// 片名规则: how folder names become TMDB searches. Shared by 电影 and 剧集.
class _TitleRulesSection extends ConsumerStatefulWidget {
  const _TitleRulesSection();

  @override
  ConsumerState<_TitleRulesSection> createState() => _TitleRulesSectionState();
}

class _TitleRulesSectionState extends ConsumerState<_TitleRulesSection> {
  final _sample = TextEditingController(text: 'R人生复本 Dark Matter');

  @override
  void dispose() {
    _sample.dispose();
    super.dispose();
  }

  void _set(TitleRules r) => ref.read(titleRulesProvider.notifier).set(r);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = Palette.of(context);
    final rules = ref.watch(titleRulesProvider);
    final small = Theme.of(context).textTheme.bodySmall;
    // What a folder with this name would search for, in order.
    final name = _sample.text.trim();
    final parsed = name.isEmpty
        ? ''
        : const RuleBasedParser()
                  .parse('S01E01.mkv', parentDirs: [name])
                  .title ??
              '';
    final first = applyRewrites(parsed, rules.cleanups).trim();
    final pinned = rules.pins
        .where(
          (x) =>
              x.keyword.trim().isNotEmpty &&
              name.toLowerCase().contains(x.keyword.trim().toLowerCase()),
        )
        .firstOrNull;
    final searches = [
      if (first.isNotEmpty) first,
      ...relaxedQueries(first, name),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(
          l10n.tr('片名规则（电影与剧集共用）', 'Title Rules (Shared by Movies & TV)'),
          trailing: TextButton.icon(
            key: const ValueKey('add-title-cleanup'),
            onPressed: () => _set(
              TitleRules(
                cleanups: [...rules.cleanups, const NameRewrite('', '')],
                pins: rules.pins,
              ),
            ),
            icon: const Icon(CupertinoIcons.plus, size: 12),
            label: Text(l10n.tr('添加', 'Add')),
          ),
        ),
        Panel(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (rules.cleanups.isEmpty)
                Text(
                  l10n.tr(
                    '识别前先按正则清洗文件夹名，再去 TMDB 搜索。'
                        '比如把 ^【.*?】 换成空，去掉「【日剧】」这类前缀。'
                        '内置规则已经会去掉排序字母、分隔点和括号，搜不到时再只用中文名或英文名搜。',
                    'Clean folder names with regex before searching TMDB (e.g. replace ^\\[.*?\\] with empty to strip release prefixes). '
                        'Built-in rules already strip sort letters, dots, and brackets, and fall back to Chinese or English titles when needed.',
                  ),
                  style: small,
                )
              else
                for (final (i, r) in rules.cleanups.indexed)
                  _RewriteRow(
                    key: ValueKey('title-cleanup-$i'),
                    value: r,
                    onChanged: (v) => _set(
                      TitleRules(
                        cleanups: [...rules.cleanups]..[i] = v,
                        pins: rules.pins,
                      ),
                    ),
                    onRemove: () => _set(
                      TitleRules(
                        cleanups: [...rules.cleanups]..removeAt(i),
                        pins: rules.pins,
                      ),
                    ),
                  ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('title-sample'),
                controller: _sample,
                decoration: InputDecoration(
                  hintText: l10n.tr('输入一个文件夹名试试', 'Type a folder name to test'),
                  prefixIcon: const Icon(CupertinoIcons.search, size: 14),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              Text(
                key: const ValueKey('title-searches'),
                pinned != null
                    ? l10n.tr(
                        '指定匹配 →《${pinned.match.title}》，不搜索',
                        'Pinned match → "${pinned.match.title}" (skips search)',
                      )
                    : searches.isEmpty
                    ? l10n.tr('没有可搜索的片名', 'No searchable title')
                    : l10n.tr(
                        '依次搜索：${searches.join('  →  ')}',
                        'Search order: ${searches.join('  →  ')}',
                      ),
                style: small?.copyWith(color: p.textMuted),
              ),
            ],
          ),
        ),
        SectionLabel(l10n.tr('指定匹配', 'Pinned Matches')),
        Panel(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: rules.pins.isEmpty
              ? Text(
                  l10n.tr(
                    '总是搜不准的片名，在识别结果里点「重新搜索 TMDB」并勾选'
                        '「以后文件夹名包含 … 时都匹配到选中的作品」，就会记在这里：文件夹名包含关键词时直接用这部作品。',
                    'For titles that often mismatch, click "Search TMDB" in Review and check "Always match folders containing …" to pin them here.',
                  ),
                  style: small,
                )
              : Column(
                  children: [
                    for (final pin in rules.pins)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Poster(
                              posterPath: pin.match.posterPath,
                              width: 24,
                              height: 36,
                              radius: 3,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                l10n.tr(
                                  '包含「${pin.keyword}」→《${pin.match.title}》'
                                      '${pin.match.year == null ? '' : ' ${pin.match.year}'}',
                                  'Contains "${pin.keyword}" → ${pin.match.title}'
                                      '${pin.match.year == null ? '' : ' (${pin.match.year})'}',
                                ),
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            IconButton(
                              key: ValueKey('remove-pin-${pin.keyword}'),
                              tooltip: l10n.delete,
                              iconSize: 14,
                              icon: const Icon(CupertinoIcons.xmark),
                              onPressed: () => _set(
                                TitleRules(
                                  cleanups: rules.cleanups,
                                  pins: [
                                    for (final x in rules.pins)
                                      if (x != pin) x,
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _StyleChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _StyleChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Hoverable(
      onTap: onTap,
      builder: (context, hover) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? p.text : (hover ? p.hover : p.panel),
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(
            color: selected ? p.text : p.lineStrong,
            width: hairline,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: monoFamily,
            fontFamilyFallback: monoFallback,
            fontSize: 12,
            color: selected ? p.canvas : p.text,
          ),
        ),
      ),
    );
  }
}

/// Insert-action chip for template variables, visually distinct from toggleable
/// [_StyleChip] presets.
class _VarChip extends StatelessWidget {
  final String variable;
  final VoidCallback onTap;

  const _VarChip({required this.variable, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = Palette.of(context);
    return Tooltip(
      message: _varTooltip(variable, l10n),
      waitDuration: const Duration(milliseconds: 400),
      child: Hoverable(
        onTap: onTap,
        builder: (context, hover) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: hover ? p.selected : p.sidebar,
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(
              color: hover ? p.lineStrong : p.line,
              width: hairline,
            ),
          ),
          child: Text(
            '+ $variable',
            style: TextStyle(
              fontFamily: monoFamily,
              fontFamilyFallback: monoFallback,
              fontSize: 11.5,
              color: hover ? p.text : p.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

/// Text field that edits a provider-backed string; [vars] become buttons that
/// insert a template variable at the cursor.
class _TextOption extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final bool mono;
  final List<String> vars;

  const _TextOption({
    super.key,
    required this.value,
    required this.onChanged,
    this.mono = false,
    this.vars = const [],
  });

  @override
  State<_TextOption> createState() => _TextOptionState();
}

class _TextOptionState extends State<_TextOption> {
  late final _c = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_TextOption oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _c.text) {
      _c.value = _c.value.copyWith(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
        composing: TextRange.empty,
      );
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _insert(String v) {
    final sel = _c.selection;
    final text = sel.isValid
        ? _c.text.replaceRange(sel.start, sel.end, v)
        : _c.text + v;
    _c.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: (sel.isValid ? sel.start : _c.text.length) + v.length,
      ),
    );
    widget.onChanged(text);
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: _c,
      style: widget.mono
          ? const TextStyle(
              fontFamily: monoFamily,
              fontFamilyFallback: [...monoFallback, ...sansFallback],
              fontSize: TypeScale.small,
            )
          : const TextStyle(fontSize: 13),
      onChanged: widget.onChanged,
    );
    if (widget.vars.isEmpty) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field,
        const SizedBox(height: 6),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final v in widget.vars)
              _VarChip(variable: v, onTap: () => _insert(v)),
          ],
        ),
      ],
    );
  }
}

/// One 查找 → 替换 rule. A pattern that doesn't compile is flagged and not saved.
class _RewriteRow extends StatefulWidget {
  final NameRewrite value;
  final ValueChanged<NameRewrite> onChanged;
  final VoidCallback onRemove;

  const _RewriteRow({
    super.key,
    required this.value,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  State<_RewriteRow> createState() => _RewriteRowState();
}

class _RewriteRowState extends State<_RewriteRow> {
  late final _find = TextEditingController(text: widget.value.pattern);
  late final _to = TextEditingController(text: widget.value.replacement);
  String? _error;

  @override
  void didUpdateWidget(_RewriteRow old) {
    super.didUpdateWidget(old);
    // Removing a row above shifts this one's value in.
    if (old.value.pattern != widget.value.pattern ||
        old.value.replacement != widget.value.replacement) {
      if (_find.text != widget.value.pattern) {
        _find.text = widget.value.pattern;
        _error = null;
      }
      if (_to.text != widget.value.replacement) {
        _to.text = widget.value.replacement;
      }
    }
  }

  @override
  void dispose() {
    _find.dispose();
    _to.dispose();
    super.dispose();
  }

  void _changed() {
    try {
      RegExp(_find.text);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    setState(() => _error = null);
    widget.onChanged(NameRewrite(_find.text, _to.text));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = Palette.of(context);
    const mono = TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: [...monoFallback, ...sansFallback],
      fontSize: TypeScale.small,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _find,
                  style: mono,
                  decoration: InputDecoration(
                    hintText: l10n.tr('查找（正则）', 'Find (regex)'),
                  ),
                  onChanged: (_) => _changed(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Icon(
                  CupertinoIcons.arrow_right,
                  size: 13,
                  color: p.textFaint,
                ),
              ),
              Expanded(
                child: TextField(
                  controller: _to,
                  style: mono,
                  decoration: InputDecoration(
                    hintText: l10n.tr(
                      r'替换为，$1 是分组',
                      r'Replace with ($1 for group)',
                    ),
                  ),
                  onChanged: (_) => _changed(),
                ),
              ),
              IconButton(
                tooltip: l10n.tr('删除规则', 'Remove rule'),
                iconSize: 14,
                icon: const Icon(CupertinoIcons.xmark),
                onPressed: widget.onRemove,
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                l10n.tr('正则有误：$_error', 'Invalid regex: $_error'),
                style: TextStyle(fontSize: 12, color: p.danger),
              ),
            ),
        ],
      ),
    );
  }
}
