import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
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

const _fieldNames = {
  NameField.title: '标题',
  NameField.year: '年份',
  NameField.episode: '季集',
  NameField.episodeTitle: '分集标题',
  NameField.extraInfo: '附加信息',
};

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

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(namingProfileProvider);
    return PageScaffold(
      title: '命名规则',
      subtitle: '电影和剧集分开设置，每一项改动都会实时显示在右侧示例里',
      actions: [
        Segmented<bool>(
          options: const {false: '电影', true: '剧集'},
          value: _tv,
          onChanged: (v) => setState(() => _tv = v),
        ),
        const SizedBox(width: 6),
        _PlayerMenu(
          value: profile.player,
          // Switching preset resets both option sets to that player's defaults.
          onChanged: (p) => ref
              .read(namingProfileProvider.notifier)
              .set(
                p == TargetPlayer.vidhub
                    ? NamingProfile.vidhub
                    : NamingProfile(player: p),
              ),
        ),
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
    final p = Palette.of(context);
    return PopupMenuButton<TargetPlayer>(
      key: const ValueKey('player'),
      tooltip: '目标播放器',
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
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: p.lineStrong, width: hairline),
          boxShadow: panelShadow(),
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

NamingOptions _optionsOf(NamingProfile p, bool tv) => tv ? p.tv : p.movie;

/// Before → after, plus the library path drawn as a small tree.
class _Preview extends ConsumerWidget {
  final bool isTv;

  const _Preview({required this.isTv});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = Palette.of(context);
    final theme = Theme.of(context);
    final profile = ref.watch(namingProfileProvider);
    final o = _optionsOf(profile, isTv);
    final sample = isTv ? NamingSample.tv : NamingSample.movie;
    final kind = isTv ? MediaKind.episode : MediaKind.movie;
    final name = renderNaming(o, kind, sample);
    final folder = renderFolder(o.folderTemplate, sample, o.rewrites);
    final season = isTv
        ? renderFolder(o.seasonFolderTemplate, sample, o.rewrites)
        : null;
    final tree = [
      isTv ? profile.tvDir : profile.movieDir,
      if (folder.text != null) folder.text!,
      if (season?.text != null) season!.text!,
    ];
    final mono = TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: [...monoFallback, ...sansFallback],
      fontSize: 12.5,
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

    return Panel(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('实时示例', style: theme.textTheme.titleSmall),
              const Spacer(),
              Tag(_playerNames[profile.player]!, color: p.accent),
            ],
          ),
          const SizedBox(height: 14),
          Text('原文件名', style: theme.textTheme.labelSmall),
          const SizedBox(height: 4),
          fileLine(CupertinoIcons.doc, sample.original, p.textFaint),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Icon(CupertinoIcons.arrow_down, size: 14, color: p.accent),
          ),
          Text('整理后', style: theme.textTheme.labelSmall),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(Radii.md),
              border: Border.all(
                color: p.accent.withValues(alpha: 0.25),
                width: hairline,
              ),
            ),
            child: fileLine(
              CupertinoIcons.film,
              name.display,
              name.text == null ? p.danger : p.text,
              key: const ValueKey('example-name'),
            ),
          ),
          const SizedBox(height: 18),
          Text('移动到媒体库时', style: theme.textTheme.labelSmall),
          const SizedBox(height: 6),
          for (var i = 0; i < tree.length; i++)
            Padding(
              padding: EdgeInsets.only(left: 16.0 * i, bottom: 2),
              child: fileLine(CupertinoIcons.folder_fill, tree[i], p.textMuted),
            ),
          if (name.text != null)
            Padding(
              padding: EdgeInsets.only(left: 16.0 * tree.length),
              child: fileLine(CupertinoIcons.film, name.text!, p.text),
            ),
        ],
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

    final options = <Widget>[
      const SectionLabel('标题'),
      Panel(
        child: Rows(
          children: [
            SettingRow(
              title: '标题语言',
              control: Segmented<TitleLanguage>(
                options: const {
                  TitleLanguage.chineseFirst: '中文优先',
                  TitleLanguage.englishFirst: '英文（原名）优先',
                },
                value: o.titleLanguage,
                onChanged: (v) =>
                    _edit(ref, (o) => o.copyWith(titleLanguage: v)),
              ),
            ),
            SettingRow(
              title: '同时用两种语言',
              caption: '如：老友记.Friends',
              control: sw(
                'bilingual',
                o.bilingual,
                (v) => _edit(ref, (o) => o.copyWith(bilingual: v)),
              ),
            ),
            SettingRow(
              title: '年份',
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
                title: '剧集年份取哪个',
                control: Segmented<ShowYearSource>(
                  options: const {
                    ShowYearSource.firstSeason: '首季年份',
                    ShowYearSource.seasonAir: '当季首播年份',
                  },
                  value: o.showYear,
                  onChanged: (v) => _edit(ref, (o) => o.copyWith(showYear: v)),
                ),
              ),
          ],
        ),
      ),
      if (isTv) ...[
        const SectionLabel('季集'),
        Panel(
          child: Rows(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Row(
                  children: [
                    const Expanded(child: Text('季集格式')),
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
                title: '分集标题',
                caption: '从 TMDB 取每集的名字加在文件名里',
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
      const SectionLabel('附加内容'),
      Panel(
        child: Rows(
          children: [
            SettingRow(
              title: '附加信息',
              caption: '保留分辨率、HDR、音轨，如 2160p.DV',
              control: sw(
                'extra',
                o.extraInfo,
                (v) => _edit(ref, (o) => o.copyWith(extraInfo: v)),
              ),
            ),
            SettingRow(
              title: '发布组',
              caption: '在末尾加 -GRP',
              control: sw(
                'group',
                o.releaseGroup,
                (v) => _edit(ref, (o) => o.copyWith(releaseGroup: v)),
              ),
            ),
            SettingRow(
              title: 'TMDB ID 标签',
              caption: '{tmdb-12345}',
              control: sw(
                'tmdbid',
                o.tmdbIdTag,
                (v) => _edit(ref, (o) => o.copyWith(tmdbIdTag: v)),
              ),
            ),
            SettingRow(
              title: '分隔符',
              control: Segmented<String>(
                options: const {'.': ' . ', '_': ' _ ', ' ': '空格', '-': ' - '},
                value: o.separator,
                onChanged: (v) => _edit(ref, (o) => o.copyWith(separator: v)),
              ),
            ),
          ],
        ),
      ),
      const SectionLabel('字段顺序'),
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
              ReorderableDragStartListener(
                key: ValueKey(order[i]),
                index: i,
                child: Container(
                  decoration: BoxDecoration(
                    color: p.panel,
                    border: i == 0
                        ? null
                        : Border(
                            top: BorderSide(color: p.line, width: hairline),
                          ),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  child: Row(
                    children: [
                      Text(
                        '${i + 1}',
                        style: TextStyle(fontSize: 12, color: p.textFaint),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(_fieldNames[order[i]]!)),
                      Icon(
                        CupertinoIcons.line_horizontal_3,
                        size: 14,
                        color: p.textFaint,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      const SectionLabel('文件夹'),
      Panel(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          children: [
            FormRow(
              label: '作品文件夹',
              child: _TextOption(
                key: ValueKey('folder-$suffix'),
                value: o.folderTemplate,
                vars: const ['{title}', '{en_title}', '{year}'],
                onChanged: (v) =>
                    _edit(ref, (o) => o.copyWith(folderTemplate: v)),
              ),
            ),
            if (isTv)
              FormRow(
                label: '季文件夹',
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
                              (o) => o.copyWith(seasonFolderTemplate: template),
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
                label: '单季剧',
                help: '打开：只有一季的剧也放进季文件夹。多季剧总是分季文件夹',
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: sw(
                    'single-season-folder',
                    o.singleSeasonFolder,
                    (v) => _edit(ref, (o) => o.copyWith(singleSeasonFolder: v)),
                  ),
                ),
              ),
          ],
        ),
      ),
    ];

    return ListView(
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        const SectionLabel('高级'),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingRow(
                title: '直接编辑模板',
                caption: '开启后下面的选项变为只读',
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
                    vars: const [
                      '{title}',
                      '{en_title}',
                      '{year}',
                      '{season:02}',
                      '{episode:02}',
                      '{episode_title}',
                      '{extra_info}',
                      '{group}',
                    ],
                    onChanged: (v) =>
                        _edit(ref, (o) => o.copyWith(customTemplate: () => v)),
                  ),
                ),
            ],
          ),
        ),
        AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: advanced ? 0.45 : 1,
          child: AbsorbPointer(
            absorbing: advanced,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: options,
            ),
          ),
        ),
        SectionLabel(
          '替换规则',
          trailing: TextButton.icon(
            key: const ValueKey('add-rewrite'),
            onPressed: () => _edit(
              ref,
              (o) => o.copyWith(
                rewrites: [...o.rewrites, const NameRewrite('', '')],
              ),
            ),
            icon: const Icon(CupertinoIcons.plus, size: 12),
            label: const Text('添加'),
          ),
        ),
        Panel(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: o.rewrites.isEmpty
              ? Text(
                  '生成名称后再按正则查找替换，文件和文件夹都生效。'
                  r'比如把 Season (\d+) 换成 S$1',
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
              fontSize: 12.5,
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
              _StyleChip(label: v, selected: false, onTap: () => _insert(v)),
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
      setState(() => _error = '正则有误：${e.message}');
      return;
    }
    setState(() => _error = null);
    widget.onChanged(NameRewrite(_find.text, _to.text));
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    const mono = TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: [...monoFallback, ...sansFallback],
      fontSize: 12.5,
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
                  decoration: const InputDecoration(hintText: '查找（正则）'),
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
                  decoration: const InputDecoration(hintText: r'替换为，$1 是分组'),
                  onChanged: (_) => _changed(),
                ),
              ),
              IconButton(
                tooltip: '删除规则',
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
                _error!,
                style: TextStyle(fontSize: 12, color: p.danger),
              ),
            ),
        ],
      ),
    );
  }
}
