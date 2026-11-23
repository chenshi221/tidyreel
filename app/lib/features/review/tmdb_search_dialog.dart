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

String countryLabel(String? code, [AppL10n l10n = AppL10n.zh]) =>
    switch (code) {
      null => '',
      'CN' => l10n.tr('中国大陆', 'China'),
      'HK' => l10n.tr('中国香港', 'Hong Kong'),
      'TW' => l10n.tr('中国台湾', 'Taiwan'),
      'JP' => l10n.tr('日本', 'Japan'),
      'KR' => l10n.tr('韩国', 'South Korea'),
      'US' => l10n.tr('美国', 'USA'),
      'GB' => l10n.tr('英国', 'UK'),
      'FR' => l10n.tr('法国', 'France'),
      'DE' => l10n.tr('德国', 'Germany'),
      'TH' => l10n.tr('泰国', 'Thailand'),
      'IN' => l10n.tr('印度', 'India'),
      _ => code,
    };

class RatingBadge extends StatelessWidget {
  final double value;

  const RatingBadge(this.value, {super.key});

  @override
  Widget build(BuildContext context) {
    // Neutral star: the page's only colour stays the accent.
    final c = Palette.of(context).textMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(CupertinoIcons.star_fill, size: 11, color: c),
        const SizedBox(width: 3),
        Text(
          value.toStringAsFixed(1),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Palette.of(context).text,
          ),
        ),
      ],
    );
  }
}

class CandidateTile extends StatelessWidget {
  final Candidate candidate;
  final VoidCallback onTap;

  const CandidateTile({
    super.key,
    required this.candidate,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = candidate;
    final p = Palette.of(context);
    return HoverRow(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      borderRadius: BorderRadius.circular(Radii.sm),
      leading: Poster(posterPath: c.posterPath, width: 34, height: 51),
      title: Text(c.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              if (c.originalTitle != null && c.originalTitle != c.title)
                c.originalTitle!,
              if (c.year != null) '${c.year}',
              c.kind == MediaKind.movie
                  ? context.l10n.movie
                  : context.l10n.tvShow,
              if (c.originCountry != null)
                countryLabel(c.originCountry, context.l10n),
            ].join(' · '),
          ),
          if (c.overview != null)
            Text(
              c.overview!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.textFaint),
            ),
        ],
      ),
      trailing: c.voteAverage == null || c.voteAverage == 0
          ? null
          : RatingBadge(c.voteAverage!),
      onTap: onTap,
    );
  }
}

/// Search box + type / year filters + result list; shared by the 纠错 dialog
/// and the inline box on unmatched groups.
class TmdbSearchBox extends ConsumerStatefulWidget {
  final String initial;
  final ValueChanged<Candidate> onPick;
  final bool autoSearch;

  const TmdbSearchBox({
    super.key,
    required this.initial,
    required this.onPick,
    this.autoSearch = false,
  });

  @override
  ConsumerState<TmdbSearchBox> createState() => _TmdbSearchBoxState();
}

class _TmdbSearchBoxState extends ConsumerState<TmdbSearchBox> {
  late final _c = TextEditingController(text: widget.initial);
  // Both filters start open: the guess being corrected may be what's wrong
  // (a year taken from a wrong match hides the right one). MediaKind.unknown = 全部.
  final _yearC = TextEditingController();
  var _kind = MediaKind.unknown;
  List<Candidate>? _results;
  var _busy = false;
  var _searchSeq = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.autoSearch) _search();
  }

  @override
  void didUpdateWidget(TmdbSearchBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initial != widget.initial) {
      _c.text = widget.initial;
      _yearC.text = '';
      _kind = MediaKind.unknown;
      _results = null;
      _error = null;
      if (widget.autoSearch) _search();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _yearC.dispose();
    super.dispose();
  }

  int? get _year {
    final y = int.tryParse(_yearC.text.trim());
    return y != null && y >= 1870 && y <= 2100 ? y : null;
  }

  void _setYear(int? y) {
    _yearC.text = y?.toString() ?? '';
    _search();
  }

  Future<void> _search() async {
    final q = _c.text.trim();
    if (q.isEmpty) return;
    final seq = ++_searchSeq;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ref
          .read(metadataProvider)
          .search(
            q,
            kind: _kind == MediaKind.unknown ? null : _kind,
            year: _year,
          );
      if (mounted && seq == _searchSeq) setState(() => _results = r);
    } catch (e) {
      if (mounted && seq == _searchSeq) {
        final l10n = context.l10n;
        setState(
          () => _error = l10n.tr(
            '搜索失败：$e',
            'Search failed: ${l10n.coreMessage('$e')}',
          ),
        );
      }
    } finally {
      if (mounted && seq == _searchSeq) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _c,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: l10n.tr('搜索 TMDB', 'Search TMDB'),
            prefixIcon: const Icon(CupertinoIcons.search, size: 14),
            suffixIcon: _busy
                ? const Padding(
                    padding: EdgeInsets.all(8),
                    child: Spinner(size: 14),
                  )
                : IconButton(
                    tooltip: l10n.tr('搜索', 'Search'),
                    iconSize: 15,
                    icon: const Icon(CupertinoIcons.arrow_right_circle_fill),
                    onPressed: _search,
                  ),
          ),
          onSubmitted: (_) => _search(),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Segmented<MediaKind>(
              key: const ValueKey('search-kind'),
              options: {
                MediaKind.unknown: l10n.tr('全部', 'All'),
                MediaKind.episode: l10n.tvShow,
                MediaKind.movie: l10n.movie,
              },
              value: _kind,
              onChanged: (k) {
                setState(() => _kind = k);
                _search();
              },
            ),
            SizedBox(
              width: 120,
              child: TextField(
                key: const ValueKey('search-year'),
                controller: _yearC,
                style: const TextStyle(fontSize: 13),
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(4),
                ],
                decoration: InputDecoration(
                  hintText: l10n.tr('年份', 'Year'),
                  suffixIcon: PopupMenuButton<int>(
                    tooltip: l10n.tr('选择年份', 'Choose year'),
                    iconSize: 14,
                    icon: const Icon(CupertinoIcons.calendar),
                    onSelected: (y) => _setYear(y == 0 ? null : y),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 0,
                        height: 28,
                        child: Text(l10n.tr('不限', 'Any')),
                      ),
                      for (var y = DateTime.now().year + 1; y >= 1950; y--)
                        PopupMenuItem(value: y, height: 28, child: Text('$y')),
                    ],
                  ),
                ),
                onSubmitted: (_) => _search(),
              ),
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _error!,
              style: TextStyle(color: p.danger, fontSize: 12),
            ),
          ),
        if (_results != null && _results!.isEmpty)
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text(
              l10n.tr('没有找到结果', 'No results found'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (_results != null && _results!.isNotEmpty) const SizedBox(height: 4),
        for (final c in _results ?? const <Candidate>[])
          CandidateTile(candidate: c, onTap: () => widget.onPick(c)),
      ],
    );
  }
}

/// Search TMDB and pick a work. With [pinKeyword], also offers
/// 「以后都这样匹配」: the returned `pin` is the keyword to remember (片名规则).
Future<({Candidate match, String? pin})?> showTmdbSearchDialog(
  BuildContext context, {
  required String initial,
  String? pinKeyword,
}) {
  var pin = false;
  final keyword = TextEditingController(text: pinKeyword);
  return showDialog<({Candidate match, String? pin})>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final l10n = ctx.l10n;
        return MacSheet(
          child: SizedBox(
            width: 520,
            height: 520,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.tr('重新搜索 TMDB', 'Search TMDB'),
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: SingleChildScrollView(
                      child: TmdbSearchBox(
                        initial: initial,
                        autoSearch: true,
                        onPick: (c) => Navigator.pop(ctx, (
                          match: c,
                          pin: pin && keyword.text.trim().isNotEmpty
                              ? keyword.text.trim()
                              : null,
                        )),
                      ),
                    ),
                  ),
                  if (pinKeyword != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Checkbox(
                          key: const ValueKey('pin-match'),
                          value: pin,
                          onChanged: (v) => setState(() => pin = v ?? false),
                        ),
                        Text(
                          l10n.tr('以后文件夹名包含', 'Always match folders with'),
                          style: const TextStyle(fontSize: 13),
                        ),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 140,
                          child: TextField(
                            key: const ValueKey('pin-keyword'),
                            controller: keyword,
                            enabled: pin,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            l10n.tr('时都匹配到选中的作品', 'to the selected title'),
                            style: const TextStyle(fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text(l10n.cancel),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  ).whenComplete(keyword.dispose);
}
