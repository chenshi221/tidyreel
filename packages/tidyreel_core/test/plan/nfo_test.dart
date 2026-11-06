import 'dart:convert';

import 'package:test/test.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'helpers.dart';

/// Search finds nothing: only the nfo can name the work.
class _NoSearch extends FakeMetadataProvider {
  @override
  Future<List<Candidate>> search(
    String query, {
    MediaKind? kind,
    int? year,
  }) async => const [];
}

Future<MediaGroup> recognize(Map<String, String> files) async {
  final r = await AnchorRecognizer(const RuleBasedParser(), _NoSearch())
      .recognize(
        const ConnectionId('c'),
        ['/库'],
        entriesOf(files.keys),
        read: (path) async => utf8.encode(files[path] ?? ''),
      );
  return r.groups.single;
}

void main() {
  test('tvshow.nfo names the show by its TMDB id', () async {
    final g = await recognize({
      '/库/乱七八糟/S01E01.mkv': '',
      '/库/乱七八糟/tvshow.nfo':
          '<?xml version="1.0"?><tvshow><title>x</title>'
          '<uniqueid type="tmdb" default="true">${Demo.dorohedoro.tmdbId}</uniqueid></tvshow>',
    });
    expect(g.match?.tmdbId, Demo.dorohedoro.tmdbId);
    expect(g.matchScore, 1);
  });

  test('a movie nfo next to its video, <tmdbid> form', () async {
    final g = await recognize({
      '/库/盗梦/x.mkv': '',
      '/库/盗梦/x.nfo': '<movie><tmdbid>${Demo.inception.tmdbId}</tmdbid></movie>',
    });
    expect(g.match?.tmdbId, Demo.inception.tmdbId);
    expect(g.kind, MediaKind.movie);
  });

  test('an episode nfo or a broken one is ignored', () async {
    final g = await recognize({
      '/库/乱七八糟/S01E01.mkv': '',
      '/库/乱七八糟/S01E01.nfo': '<episodedetails><uniqueid type="tmdb">999</uniqueid></episodedetails>',
      '/库/乱七八糟/tvshow.nfo': '<tvshow><title>没有 id</title></tvshow>',
    });
    expect(g.match, isNull);
  });
}
