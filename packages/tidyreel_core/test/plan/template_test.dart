import 'package:test/test.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

void main() {
  const friends = {
    'title': '老友记',
    'en_title': 'Friends',
    'year': 1994,
    'season': 2,
    'episode': 3,
    'episode_title': 'The One With the Lesbian Wedding',
    'extra_info': '2160p.DV',
    'group': 'GRP',
    'tmdb_tag': '{tmdb-1668}',
  };
  const inception = {
    'title': '盗梦空间',
    'en_title': 'Inception',
    'year': 2010,
    'tmdb_tag': '{tmdb-27205}',
  };

  String tv(NamingOptions o, [Map<String, Object?> v = friends]) =>
      renderTemplate(compileTemplate(o, MediaKind.episode), v);
  String movie(NamingOptions o, [Map<String, Object?> v = inception]) =>
      renderTemplate(compileTemplate(o, MediaKind.movie), v);

  group('renderTemplate', () {
    test('variables and zero padding', () {
      expect(
        renderTemplate('{title} S{season:02}E{episode:02}', friends),
        '老友记 S02E03',
      );
      expect(renderTemplate('{season:03}', {'season': 12}), '012');
      expect(renderTemplate('{title:02}', {'title': 'ab'}), 'ab');
    });
    test('optional segments vanish when a variable is missing or empty', () {
      expect(
        renderTemplate('{title}[ - {episode_title}]', {'title': 'A'}),
        'A',
      );
      expect(
        renderTemplate('{title}[ - {episode_title}]', {
          'title': 'A',
          'episode_title': '',
        }),
        'A',
      );
      expect(
        renderTemplate('{title}[ - {episode_title}]', {
          'title': 'A',
          'episode_title': 'B',
        }),
        'A - B',
      );
    });
    test('a zero value is not empty', () {
      expect(renderTemplate('S{season:02}', {'season': 0}), 'S00');
    });
    test('nested optional segments decide on their own', () {
      expect(renderTemplate('{a}[.{b}[.{c}]]', {'a': 'A', 'b': 'B'}), 'A.B');
      expect(renderTemplate('{a}[.{b}[.{c}]]', {'a': 'A', 'c': 'C'}), 'A');
    });
    test('collapses repeated separators and trims the ends', () {
      expect(renderTemplate('.{a}..{b}.', {'a': 'A', 'b': 'B'}), 'A.B');
      expect(renderTemplate('{a}  {b}', {'a': 'A', 'b': 'B'}), 'A B');
      expect(renderTemplate('-{a}__', {'a': 'A'}), 'A');
    });
    test('empty parentheses disappear', () {
      expect(renderTemplate('{title} ({year})', {'title': 'A'}), 'A');
      expect(
        renderTemplate('{title} ({year})', {'title': 'A', 'year': 2000}),
        'A (2000)',
      );
    });
    test('unknown variable is empty; escapes keep literals', () {
      expect(renderTemplate('{nope}x', {}), 'x');
      expect(renderTemplate(r'a\[b\]', {}), 'a[b]');
    });
  });

  group('compileTemplate + render: VidHub defaults', () {
    test('movie', () {
      expect(movie(const NamingOptions()), '盗梦空间.Inception.2010');
    });
    test('tv', () {
      expect(tv(const NamingOptions()), '老友记.Friends.1994.S02E03');
    });
    test('folders', () {
      const o = NamingOptions();
      expect(renderTemplate(o.folderTemplate, inception), '盗梦空间 (2010)');
      expect(
        renderTemplate(o.seasonFolderTemplate, {'season': 2}),
        'Season 02',
      );
    });
  });

  group('compileTemplate options', () {
    test('english first', () {
      const o = NamingOptions(titleLanguage: TitleLanguage.englishFirst);
      expect(tv(o), 'Friends.老友记.1994.S02E03');
    });
    test('single language', () {
      expect(movie(const NamingOptions(bilingual: false)), '盗梦空间.2010');
      expect(
        movie(
          const NamingOptions(
            bilingual: false,
            titleLanguage: TitleLanguage.englishFirst,
          ),
        ),
        'Inception.2010',
      );
    });
    test('missing English title is written once', () {
      expect(
        movie(const NamingOptions(), {'title': '盗梦空间', 'year': 2010}),
        '盗梦空间.2010',
      );
      expect(
        movie(const NamingOptions(titleLanguage: TitleLanguage.englishFirst), {
          'title': '盗梦空间',
          'year': 2010,
        }),
        '盗梦空间.2010',
      );
    });
    test('year off, year in parentheses', () {
      expect(movie(const NamingOptions(includeYear: false)), '盗梦空间.Inception');
      expect(
        movie(const NamingOptions(yearInParens: true)),
        '盗梦空间.Inception.(2010)',
      );
      expect(movie(const NamingOptions(), {'title': 'A'}), 'A');
    });
    test('episode styles', () {
      String s(EpisodeStyle st) => tv(NamingOptions(episodeStyle: st));
      expect(s(EpisodeStyle.upperPadded), '老友记.Friends.1994.S02E03');
      expect(s(EpisodeStyle.lowerPadded), '老友记.Friends.1994.s02e03');
      expect(s(EpisodeStyle.lowerShort), '老友记.Friends.1994.s2e3');
      expect(s(EpisodeStyle.cross), '老友记.Friends.1994.2x03');
      expect(s(EpisodeStyle.lowerDotted), '老友记.Friends.1994.s02.e03');
    });
    test('s01.e02 survives every separator', () {
      for (final sep in ['.', '_', ' ', '-']) {
        final out = tv(
          NamingOptions(episodeStyle: EpisodeStyle.lowerDotted, separator: sep),
        );
        expect(out, contains('s02.e03'), reason: 'sep "$sep"');
      }
    });
    test('separators', () {
      expect(
        tv(const NamingOptions(separator: '_')),
        '老友记_Friends_1994_S02E03',
      );
      expect(
        tv(const NamingOptions(separator: ' ')),
        '老友记 Friends 1994 S02E03',
      );
      expect(
        tv(const NamingOptions(separator: '-')),
        '老友记-Friends-1994-S02E03',
      );
    });
    test('episode title, extra info, tmdb tag, release group', () {
      expect(
        tv(
          const NamingOptions(
            episodeTitle: true,
            extraInfo: true,
            tmdbIdTag: true,
            releaseGroup: true,
          ),
        ),
        '老友记.Friends.1994.S02E03.The One With the Lesbian Wedding.2160p.DV.{tmdb-1668}-GRP',
      );
    });
    test('optional fields vanish without data', () {
      expect(
        tv(
          const NamingOptions(
            episodeTitle: true,
            extraInfo: true,
            releaseGroup: true,
            tmdbIdTag: true,
          ),
          {'title': 'A', 'year': 2000, 'season': 1, 'episode': 1},
        ),
        'A.2000.S01E01',
      );
    });
    test('movies ignore episode fields', () {
      expect(
        movie(const NamingOptions(episodeTitle: true), friends),
        '老友记.Friends.1994',
      );
    });
    test('field order', () {
      const o = NamingOptions(
        order: [NameField.year, NameField.title, NameField.episode],
      );
      expect(tv(o), '1994.老友记.Friends.S02E03');
      const o2 = NamingOptions(order: [NameField.episode, NameField.title]);
      expect(tv(o2), 'S02E03.老友记.Friends');
    });
    test('customTemplate wins', () {
      const o = NamingOptions(
        customTemplate: '{en_title} - S{season:02}E{episode:02}',
      );
      expect(tv(o), 'Friends - S02E03');
      expect(
        compileTemplate(o, MediaKind.movie),
        '{en_title} - S{season:02}E{episode:02}',
      );
    });
  });

  group('sanitizeName', () {
    test('replaces illegal characters', () {
      expect(sanitizeName(r'a\b/c'), 'abc');
      expect(sanitizeName('a:b?c*d"e<f>g|h'), 'a：b？c＊d＂e＜f＞g｜h');
    });
    test('trims trailing dots and spaces, collapses whitespace', () {
      expect(sanitizeName('  Dr.  Strange   Movie. . '), 'Dr. Strange Movie');
      expect(sanitizeName('a\t\n b'), 'a b');
    });
    test('leaves normal names alone', () {
      expect(sanitizeName('盗梦空间.Inception.2010'), '盗梦空间.Inception.2010');
    });
  });
}
