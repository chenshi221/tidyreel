import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
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

/// 命名规则页（PLAN §3.2）.
class NamingPage extends ConsumerStatefulWidget {
  const NamingPage({super.key});

  @override
  ConsumerState<NamingPage> createState() => _NamingPageState();
}

class _NamingPageState extends ConsumerState<NamingPage>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(namingProfileProvider);
    return PageScaffold(
      title: '命名规则',
      actions: [
        const Text('目标播放器  '),
        DropdownButton<TargetPlayer>(
          key: const ValueKey('player'),
          value: profile.player,
          underline: const SizedBox.shrink(),
          items: [
            for (final p in TargetPlayer.values)
              DropdownMenuItem(value: p, child: Text(_playerNames[p]!)),
          ],
          // Switching preset resets both option sets to that player's defaults.
          onChanged: (p) => ref
              .read(namingProfileProvider.notifier)
              .set(
                p == TargetPlayer.vidhub
                    ? NamingProfile.vidhub
                    : NamingProfile(player: p!),
              ),
        ),
      ],
      child: Column(
        children: [
          TabBar(
            controller: _tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: const [
              Tab(text: '电影'),
              Tab(text: '剧集'),
            ],
          ),
          AnimatedBuilder(
            animation: _tabs,
            builder: (_, _) => _ExampleCard(isTv: _tabs.index == 1),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: const [
                _OptionsPanel(isTv: false),
                _OptionsPanel(isTv: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

NamingOptions _optionsOf(NamingProfile p, bool tv) => tv ? p.tv : p.movie;

class _ExampleCard extends ConsumerWidget {
  final bool isTv;

  const _ExampleCard({required this.isTv});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final o = _optionsOf(ref.watch(namingProfileProvider), isTv);
    final sample = isTv ? NamingSample.tv : NamingSample.movie;
    final kind = isTv ? MediaKind.episode : MediaKind.movie;
    final name = renderNaming(o, kind, sample);
    final folder = renderFolder(o.folderTemplate, sample);
    final season = isTv ? renderFolder(o.seasonFolderTemplate, sample) : null;
    final scheme = Theme.of(context).colorScheme;
    final dir = ref.watch(namingProfileProvider);
    final path = name.text == null || folder.text == null
        ? null
        : '${isTv ? dir.tvDir : dir.movieDir}/${folder.text}/'
              '${season?.text != null ? '${season!.text}/' : ''}${name.text}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      child: Card(
        color: scheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('示例', style: TextStyle(color: scheme.onPrimaryContainer)),
              const SizedBox(height: 4),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  Text(
                    sample.original,
                    style: TextStyle(
                      color: scheme.onPrimaryContainer.withAlpha(180),
                    ),
                  ),
                  Icon(
                    Icons.arrow_forward,
                    size: 18,
                    color: scheme.onPrimaryContainer,
                  ),
                  SelectableText(
                    name.display,
                    key: const ValueKey('example-name'),
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(color: scheme.onPrimaryContainer),
                  ),
                ],
              ),
              if (path != null)
                Text(
                  '移动到媒体库：$path',
                  style: TextStyle(
                    color: scheme.onPrimaryContainer.withAlpha(180),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OptionsPanel extends ConsumerWidget {
  final bool isTv;

  const _OptionsPanel({required this.isTv});

  void _edit(WidgetRef ref, NamingOptions Function(NamingOptions) f) {
    final p = ref.read(namingProfileProvider);
    ref
        .read(namingProfileProvider.notifier)
        .set(isTv ? p.copyWith(tv: f(p.tv)) : p.copyWith(movie: f(p.movie)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final o = _optionsOf(ref.watch(namingProfileProvider), isTv);
    final kind = isTv ? MediaKind.episode : MediaKind.movie;
    final advanced = o.customTemplate != null;
    final order = [
      for (final f in o.order)
        if (isTv || (f != NameField.episode && f != NameField.episodeTitle)) f,
    ];

    Widget row(String label, Widget child, {String? hint}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(label),
            ),
          ),
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: child),
          ),
        ],
      ),
    );

    Widget sw(String key, bool v, ValueChanged<bool> f) => Switch(
      key: ValueKey('$key-${isTv ? 'tv' : 'movie'}'),
      value: v,
      onChanged: f,
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Advanced editor: when on, the option controls below go read-only.
                row(
                  '高级：直接编辑模板',
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      sw(
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
                      if (advanced)
                        SizedBox(
                          width: 520,
                          child: _TextOption(
                            key: ValueKey('custom-${isTv ? 'tv' : 'movie'}'),
                            value: o.customTemplate!,
                            label: '文件名模板（不含扩展名）',
                            onChanged: (v) => _edit(
                              ref,
                              (o) => o.copyWith(customTemplate: () => v),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const Divider(),
                Opacity(
                  opacity: advanced ? 0.45 : 1,
                  child: AbsorbPointer(
                    absorbing: advanced,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        row(
                          '标题语言',
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SegmentedButton<TitleLanguage>(
                                segments: const [
                                  ButtonSegment(
                                    value: TitleLanguage.chineseFirst,
                                    label: Text('中文优先'),
                                  ),
                                  ButtonSegment(
                                    value: TitleLanguage.englishFirst,
                                    label: Text('英文（原名）优先'),
                                  ),
                                ],
                                selected: {o.titleLanguage},
                                onSelectionChanged: (v) => _edit(
                                  ref,
                                  (o) => o.copyWith(titleLanguage: v.first),
                                ),
                              ),
                              CheckboxListTile(
                                key: ValueKey(
                                  'bilingual-${isTv ? 'tv' : 'movie'}',
                                ),
                                contentPadding: EdgeInsets.zero,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: const Text('同时用两种语言'),
                                value: o.bilingual,
                                onChanged: (v) =>
                                    _edit(ref, (o) => o.copyWith(bilingual: v)),
                              ),
                            ],
                          ),
                        ),
                        row(
                          '年份',
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              sw(
                                'year',
                                o.includeYear,
                                (v) => _edit(
                                  ref,
                                  (o) => o.copyWith(includeYear: v),
                                ),
                              ),
                              const SizedBox(width: 16),
                              SegmentedButton<bool>(
                                segments: const [
                                  ButtonSegment(
                                    value: false,
                                    label: Text('1999'),
                                  ),
                                  ButtonSegment(
                                    value: true,
                                    label: Text('(1999)'),
                                  ),
                                ],
                                selected: {o.yearInParens},
                                onSelectionChanged: o.includeYear
                                    ? (v) => _edit(
                                        ref,
                                        (o) =>
                                            o.copyWith(yearInParens: v.first),
                                      )
                                    : null,
                              ),
                            ],
                          ),
                        ),
                        if (isTv) ...[
                          row(
                            '剧集年份取哪个',
                            SegmentedButton<ShowYearSource>(
                              segments: const [
                                ButtonSegment(
                                  value: ShowYearSource.firstSeason,
                                  label: Text('首季年份'),
                                ),
                                ButtonSegment(
                                  value: ShowYearSource.seasonAir,
                                  label: Text('当季首播年份'),
                                ),
                              ],
                              selected: {o.showYear},
                              onSelectionChanged: (v) => _edit(
                                ref,
                                (o) => o.copyWith(showYear: v.first),
                              ),
                            ),
                          ),
                          row(
                            '季集格式',
                            SizedBox(
                              width: 260,
                              child: RadioGroup<EpisodeStyle>(
                                groupValue: o.episodeStyle,
                                onChanged: (v) => _edit(
                                  ref,
                                  (o) => o.copyWith(episodeStyle: v),
                                ),
                                child: Column(
                                  children: [
                                    for (final s in EpisodeStyle.values)
                                      RadioListTile<EpisodeStyle>(
                                        key: ValueKey('style-${s.name}'),
                                        contentPadding: EdgeInsets.zero,
                                        title: Text(_episodeStyleExamples[s]!),
                                        value: s,
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          row(
                            '分集标题',
                            sw(
                              'episode-title',
                              o.episodeTitle,
                              (v) => _edit(
                                ref,
                                (o) => o.copyWith(episodeTitle: v),
                              ),
                            ),
                          ),
                        ],
                        row(
                          '附加信息',
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              sw(
                                'extra',
                                o.extraInfo,
                                (v) =>
                                    _edit(ref, (o) => o.copyWith(extraInfo: v)),
                              ),
                              const SizedBox(width: 12),
                              const Text('保留分辨率、HDR、音轨，如 2160p.DV'),
                            ],
                          ),
                        ),
                        row(
                          '分隔符',
                          SegmentedButton<String>(
                            segments: const [
                              ButtonSegment(value: '.', label: Text('.')),
                              ButtonSegment(value: '_', label: Text('_')),
                              ButtonSegment(value: ' ', label: Text('空格')),
                              ButtonSegment(value: '-', label: Text('-')),
                            ],
                            selected: {o.separator},
                            onSelectionChanged: (v) => _edit(
                              ref,
                              (o) => o.copyWith(separator: v.first),
                            ),
                          ),
                        ),
                        row(
                          '发布组',
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              sw(
                                'group',
                                o.releaseGroup,
                                (v) => _edit(
                                  ref,
                                  (o) => o.copyWith(releaseGroup: v),
                                ),
                              ),
                              const SizedBox(width: 12),
                              const Text('在末尾加 -GRP'),
                            ],
                          ),
                        ),
                        row(
                          'TMDB ID 标签',
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              sw(
                                'tmdbid',
                                o.tmdbIdTag,
                                (v) =>
                                    _edit(ref, (o) => o.copyWith(tmdbIdTag: v)),
                              ),
                              const SizedBox(width: 12),
                              const Text('{tmdb-12345}'),
                            ],
                          ),
                        ),
                        row(
                          '字段顺序',
                          SizedBox(
                            width: 260,
                            child: ReorderableListView(
                              key: ValueKey('order-${isTv ? 'tv' : 'movie'}'),
                              shrinkWrap: true,
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
                                for (final f in order)
                                  ListTile(
                                    key: ValueKey(f),
                                    dense: false,
                                    title: Text(_fieldNames[f]!),
                                    leading: const Icon(Icons.drag_indicator),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        row(
                          '文件夹命名',
                          SizedBox(
                            width: 360,
                            child: _TextOption(
                              key: ValueKey('folder-${isTv ? 'tv' : 'movie'}'),
                              value: o.folderTemplate,
                              label: '作品文件夹',
                              onChanged: (v) => _edit(
                                ref,
                                (o) => o.copyWith(folderTemplate: v),
                              ),
                            ),
                          ),
                        ),
                        if (isTv)
                          row(
                            '季文件夹',
                            SizedBox(
                              width: 360,
                              child: _TextOption(
                                key: const ValueKey('season-folder'),
                                value: o.seasonFolderTemplate,
                                label: '季文件夹',
                                onChanged: (v) => _edit(
                                  ref,
                                  (o) => o.copyWith(seasonFolderTemplate: v),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Text field that edits a provider-backed string.
class _TextOption extends StatefulWidget {
  final String value;
  final String label;
  final ValueChanged<String> onChanged;

  const _TextOption({
    super.key,
    required this.value,
    required this.label,
    required this.onChanged,
  });

  @override
  State<_TextOption> createState() => _TextOptionState();
}

class _TextOptionState extends State<_TextOption> {
  late final _c = TextEditingController(text: widget.value);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _c,
    decoration: InputDecoration(
      labelText: widget.label,
      border: const OutlineInputBorder(),
    ),
    onChanged: widget.onChanged,
  );
}
