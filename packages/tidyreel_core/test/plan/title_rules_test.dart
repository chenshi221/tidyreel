import 'package:test/test.dart';
import 'package:tidyreel_core/src/plan/text.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'helpers.dart';

/// TMDB that only answers its exact titles.
class _Exact extends FakeMetadataProvider {
  final asked = <String>[];
  static const known = {'谜探路德维希', '我的有罪之人', '幸福伽菜子的快乐杀手生活', 'Dark Matter'};

  @override
  Future<ShowDetail> show(int tmdbId) async => ShowDetail(
    info: Candidate(tmdbId: tmdbId, kind: MediaKind.episode, title: ''),
    seasons: const [SeasonInfo(number: 1, episodeCount: 10)],
  );

  @override
  Future<List<Candidate>> search(
    String query, {
    MediaKind? kind,
    int? year,
  }) async {
    asked.add(query);
    return known.contains(query)
        ? [
            Candidate(
              tmdbId: query.hashCode,
              kind: MediaKind.episode,
              title: query,
            ),
          ]
        : [];
  }
}

const conn = ConnectionId('c');

Future<String?> matchOf(
  String folder, {
  TitleRules rules = const TitleRules(),
}) async {
  final r = await AnchorRecognizer(
    const RuleBasedParser(),
    _Exact(),
    titleRules: () => rules,
  ).recognize(conn, ['/下载'], entriesOf(['/下载/$folder/S01E01.mkv']));
  return r.groups.single.match?.title;
}

void main() {
  test('dotted CJK, sort letters, tag brackets and English names', () async {
    expect(await matchOf('谜.探.路.德.维.希（2026）'), '谜探路德维希');
    expect(await matchOf('W我的有罪之人'), '我的有罪之人');
    expect(await matchOf('【日剧】幸福伽菜子的快乐杀手生活'), '幸福伽菜子的快乐杀手生活');
    expect(await matchOf('R人生复本 Dark Matter'), 'Dark Matter');
  });

  test('relaxedQueries drops release words from the English part', () {
    expect(relaxedQueries('R人生复本', 'R人生复本.Dark.Matter.S01.2160p.WEB-DL'), [
      '人生复本',
      'Dark Matter',
    ]);
    expect(relaxedQueries('老友记', '老友记'), isEmpty);
  });

  test('cleanup rules run before searching', () async {
    expect(await matchOf('我的有罪之人 抢先版'), isNull);
    expect(
      await matchOf(
        '我的有罪之人 抢先版',
        rules: const TitleRules(cleanups: [NameRewrite(r'\s*抢先版', '')]),
      ),
      '我的有罪之人',
    );
  });

  test('a pin matches without searching', () async {
    const pinned = Candidate(tmdbId: 7, kind: MediaKind.episode, title: '人生复本');
    expect(
      await matchOf(
        'X 复本 第一季',
        rules: const TitleRules(pins: [TitlePin('复本', pinned)]),
      ),
      '人生复本',
    );
  });
}
