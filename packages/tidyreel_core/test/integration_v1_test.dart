import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tidyreel_core/src/plan/text.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

String _baseName(String path) =>
    path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '';

class _StubMetadata implements MetadataProvider, ExternalIdLookup {
  final List<Candidate> movies;
  final List<ShowDetail> shows;

  const _StubMetadata({this.movies = const [], this.shows = const []});

  List<Candidate> get _all => [...movies, for (final s in shows) s.info];

  @override
  Future<Candidate?> findByExternalId(
    String source,
    String id, {
    MediaKind? kind,
  }) async {
    for (final c in _all) {
      if (kind != null && c.kind != kind) continue;
      if (source == 'tmdb' && c.tmdbId.toString() == id) return c;
      if (source == 'imdb' && c.imdbId == id) return c;
      if (source == 'tvdb' && c.tvdbId?.toString() == id) return c;
    }
    return null;
  }

  @override
  Future<List<Candidate>> search(
    String query, {
    MediaKind? kind,
    int? year,
  }) async {
    final q = normTitle(query);
    return [
      for (final c in _all)
        if (kind == null || c.kind == kind)
          if ([c.title, c.englishTitle, c.originalTitle].any(
            (t) =>
                t != null &&
                (normTitle(t) == q ||
                    normTitle(t).contains(q) ||
                    q.contains(normTitle(t))),
          ))
            c,
    ];
  }

  @override
  Future<MovieDetail> movie(int tmdbId) async =>
      MovieDetail(info: movies.firstWhere((m) => m.tmdbId == tmdbId));

  @override
  Future<ShowDetail> show(int tmdbId) async =>
      shows.firstWhere((s) => s.info.tmdbId == tmdbId);

  @override
  Future<List<Episode>> season(int tmdbId, int season) async => const [];

  @override
  Future<List<EpisodeGroup>> episodeGroups(int tmdbId) async => const [];
}

Uint8List _ebmlId(int id) {
  if (id <= 0xFF) return Uint8List.fromList([id]);
  if (id <= 0xFFFF) return Uint8List.fromList([(id >> 8) & 0xFF, id & 0xFF]);
  if (id <= 0xFFFFFF) {
    return Uint8List.fromList([(id >> 16) & 0xFF, (id >> 8) & 0xFF, id & 0xFF]);
  }
  return Uint8List.fromList([
    (id >> 24) & 0xFF,
    (id >> 16) & 0xFF,
    (id >> 8) & 0xFF,
    id & 0xFF,
  ]);
}

Uint8List _ebmlSize(int size) {
  if (size < 0x7F) return Uint8List.fromList([0x80 | size]);
  if (size < 0x3FFF) {
    return Uint8List.fromList([0x40 | (size >> 8), size & 0xFF]);
  }
  return Uint8List.fromList([
    0x20 | (size >> 16),
    (size >> 8) & 0xFF,
    size & 0xFF,
  ]);
}

Uint8List _ebmlElem(int id, List<int> payload) {
  final b = BytesBuilder(copy: false)
    ..add(_ebmlId(id))
    ..add(_ebmlSize(payload.length))
    ..add(payload);
  return b.takeBytes();
}

Uint8List _ebmlUint(int id, int value) {
  if (value == 0) return _ebmlElem(id, const [0]);
  final bytes = <int>[];
  var v = value;
  while (v > 0) {
    bytes.insert(0, v & 0xFF);
    v >>= 8;
  }
  return _ebmlElem(id, bytes);
}

Uint8List _ebmlStr(int id, String s) => _ebmlElem(id, utf8.encode(s));

Uint8List _ebmlFloat64(int id, double value) {
  final bd = ByteData(8)..setFloat64(0, value, Endian.big);
  return _ebmlElem(id, bd.buffer.asUint8List());
}

Uint8List _concat(List<List<int>> parts) {
  final b = BytesBuilder(copy: false);
  for (final p in parts) {
    b.add(p);
  }
  return b.takeBytes();
}

/// Minimal valid MKV header: 3840x2160 HEVC + Dolby Vision (dvcC) + TrueHD Atmos 8ch + 148m.
Uint8List _sample4kDvAtmosMkv() {
  final ebmlHeader = _ebmlElem(
    0x1A45DFA3,
    _concat([_ebmlStr(0x4282, 'matroska'), _ebmlUint(0x4287, 4)]),
  );
  final info = _ebmlElem(
    0x1549A966,
    _concat([
      _ebmlUint(0x2AD7B1, 1000000),
      _ebmlFloat64(0x4489, 148 * 60 * 1000.0),
    ]),
  );
  final videoTrack = _ebmlElem(
    0xAE,
    _concat([
      _ebmlUint(0xD7, 1),
      _ebmlUint(0x83, 1),
      _ebmlStr(0x86, 'V_MPEGH/ISO/HEVC'),
      _ebmlElem(0xE0, _concat([_ebmlUint(0xB0, 3840), _ebmlUint(0xBA, 2160)])),
      _ebmlElem(0x41E4, _ebmlUint(0x41E7, 0x64766343)), // dvcC -> DV
    ]),
  );
  final audioTrack = _ebmlElem(
    0xAE,
    _concat([
      _ebmlUint(0xD7, 2),
      _ebmlUint(0x83, 2),
      _ebmlStr(0x86, 'A_TRUEHD'),
      _ebmlStr(0x536E, 'English TrueHD Atmos 7.1'),
      _ebmlElem(0xE1, _ebmlUint(0x9F, 8)),
    ]),
  );
  final tracks = _ebmlElem(0x1654AE6B, _concat([videoTrack, audioTrack]));
  final segment = _ebmlElem(0x18538067, _concat([info, tracks]));
  return _concat([ebmlHeader, segment]);
}

void main() {
  const conn = ConnectionId('c-int');

  test('end-to-end: ContainerMediaProbe -> AnchorRecognizer -> DefaultPlanner rich scrape', () async {
    final mkvBytes = _sample4kDvAtmosMkv();
    final fs = MemoryStorageBackend({});
    await fs.write('/dl/Inception (2010).mkv', mkvBytes);

    const richInception = Candidate(
      tmdbId: 27205,
      kind: MediaKind.movie,
      title: '盗梦空间',
      englishTitle: 'Inception',
      year: 2010,
      posterPath: '/poster.jpg',
      backdropPath: '/backdrop.jpg',
      clearLogoPath: '/logo.png',
      landscapePath: '/land.jpg',
      imdbId: 'tt1375666',
      certification: 'PG-13',
      collectionName: '盗梦空间系列',
      studios: ['Warner Bros.'],
      directors: ['Christopher Nolan'],
      writers: ['Christopher Nolan'],
      actors: [
        PersonCredit(
          name: 'Leonardo DiCaprio',
          role: 'Cobb',
          profilePath: '/leo.jpg',
        ),
      ],
      tags: ['dream', 'heist'],
      voteAverage: 8.4,
      voteCount: 35000,
      popularity: 95.0,
    );
    const meta = _StubMetadata(movies: [richInception]);
    final recognizer = AnchorRecognizer(
      const RuleBasedParser(),
      meta,
      mediaProbe: const ContainerMediaProbe(),
      probeMedia: () => true,
    );

    final scan = await recognizer.recognize(
      conn,
      const ['/dl'],
      [
        RemoteEntry(
          path: '/dl/Inception (2010).mkv',
          name: 'Inception (2010).mkv',
          isDir: false,
          size: mkvBytes.length,
        ),
      ],
      backend: fs,
    );

    expect(scan.groups, hasLength(1));
    final video = scan.groups.single.files.single;
    expect(video.parsed?.probe, isNotNull);
    expect(video.parsed?.resolution, '2160p');
    expect(video.parsed?.extraInfo, '2160p.DV.Atmos');

    final profile = NamingProfile.vidhub.copyWith(
      movie: NamingProfile.vidhub.movie.copyWith(extraInfo: true),
    );
    final planner = DefaultPlanner(meta);
    final plan = await planner.build(
      scan,
      const {},
      PlanOptions(
        mode: OrganizeMode.moveToLibrary,
        libraryRoot: '/lib',
        naming: profile,
        scrape: true,
      ),
    );

    expect(plan.conflicts, isEmpty);
    final relocate = plan.ops.singleWhere((o) => o.kind == OpKind.relocate);
    expect(relocate.dst, contains('2160p.DV.Atmos'));

    final writes = {
      for (final o in plan.ops.where((o) => o.kind == OpKind.write))
        _baseName(o.dst): o.src,
    };
    expect(writes.keys, contains('clearlogo.png'));
    expect(writes.keys, contains('landscape.jpg'));
    final nfoEntry = writes.entries.firstWhere((e) => e.key.endsWith('.nfo'));
    expect(
      nfoEntry.value,
      contains('<uniqueid type="imdb">tt1375666</uniqueid>'),
    );
    expect(nfoEntry.value, contains('<mpaa>PG-13</mpaa>'));
    expect(nfoEntry.value, contains('<set><name>盗梦空间系列</name></set>'));
    expect(nfoEntry.value, contains('<director>Christopher Nolan</director>'));
    expect(nfoEntry.value, contains('<name>Leonardo DiCaprio</name>'));
  });

  test(
    'end-to-end: parser externalId -> ExternalIdLookup direct match',
    () async {
      const meta = _StubMetadata(
        movies: [
          Candidate(
            tmdbId: 27205,
            kind: MediaKind.movie,
            title: '盗梦空间',
            englishTitle: 'Inception',
            year: 2010,
          ),
        ],
      );
      final recognizer = AnchorRecognizer(const RuleBasedParser(), meta);
      final scan = await recognizer.recognize(
        conn,
        const ['/dl'],
        const [
          RemoteEntry(
            path: '/dl/完全无关片名 {tmdb-27205}/video.mkv',
            name: 'video.mkv',
            isDir: false,
            size: 4 << 30,
          ),
        ],
      );

      expect(scan.groups, hasLength(1));
      expect(scan.groups.single.match?.tmdbId, 27205);
      expect(scan.groups.single.matchScore, 1.0);
    },
  );

  test('end-to-end: parser + follow subFlags + planner preserve subtitle traits without collision', () async {
    const meta = _StubMetadata(
      shows: [
        ShowDetail(
          info: Candidate(
            tmdbId: 1668,
            kind: MediaKind.episode,
            title: '老友记',
            englishTitle: 'Friends',
            year: 1994,
          ),
          seasons: [SeasonInfo(number: 1, episodeCount: 24)],
        ),
      ],
    );
    final recognizer = AnchorRecognizer(const RuleBasedParser(), meta);
    final scan = await recognizer.recognize(
      conn,
      const ['/dl'],
      const [
        RemoteEntry(
          path: '/dl/Friends.S01E01.1080p.mkv',
          name: 'Friends.S01E01.1080p.mkv',
          isDir: false,
          size: 1 << 30,
        ),
        RemoteEntry(
          path: '/dl/Friends.S01E01.1080p.chs.srt',
          name: 'Friends.S01E01.1080p.chs.srt',
          isDir: false,
          size: 50000,
        ),
        RemoteEntry(
          path: '/dl/Friends.S01E01.1080p.chs&eng.forced.srt',
          name: 'Friends.S01E01.1080p.chs&eng.forced.srt',
          isDir: false,
          size: 52000,
        ),
        RemoteEntry(
          path: '/dl/Friends.S01E01.1080p.en.sdh.srt',
          name: 'Friends.S01E01.1080p.en.sdh.srt',
          isDir: false,
          size: 48000,
        ),
      ],
    );

    expect(scan.groups.single.match?.tmdbId, 1668);
    final planner = DefaultPlanner(meta);
    final plan = await planner.build(
      scan,
      const {},
      const PlanOptions(mode: OrganizeMode.inPlace),
    );

    expect(plan.conflicts, isEmpty);
    final subDsts = [
      for (final o in plan.ops)
        if (o.kind == OpKind.relocate && o.dst.endsWith('.srt'))
          _baseName(o.dst),
    ];
    expect(subDsts, hasLength(3));
    expect(subDsts.toSet(), hasLength(3));
    expect(subDsts.any((s) => s.endsWith('.zh-Hans.srt')), isTrue);
    expect(subDsts.any((s) => s.contains('.forced.srt')), isTrue);
    expect(subDsts.any((s) => s.endsWith('.en.sdh.srt')), isTrue);
  });

  test('end-to-end: parser editions & multi-part movies avoid conflicts in planner', () async {
    const meta = _StubMetadata(
      movies: [
        Candidate(
          tmdbId: 27205,
          kind: MediaKind.movie,
          title: '盗梦空间',
          englishTitle: 'Inception',
          year: 2010,
        ),
      ],
    );
    final recognizer = AnchorRecognizer(const RuleBasedParser(), meta);

    final edScan = await recognizer.recognize(
      conn,
      const ['/dl'],
      const [
        RemoteEntry(
          path: "/dl/Inception.2010.Director's.Cut.1080p.mkv",
          name: "Inception.2010.Director's.Cut.1080p.mkv",
          isDir: false,
          size: 10 << 30,
        ),
        RemoteEntry(
          path: '/dl/Inception.2010.IMAX.2160p.mkv',
          name: 'Inception.2010.IMAX.2160p.mkv',
          isDir: false,
          size: 20 << 30,
        ),
      ],
    );
    final planner = DefaultPlanner(meta);
    final edPlan = await planner.build(
      edScan,
      const {},
      const PlanOptions(mode: OrganizeMode.inPlace),
    );
    expect(edPlan.conflicts, isEmpty);
    final edDsts = [
      for (final o in edPlan.ops)
        if (o.kind == OpKind.relocate) _baseName(o.dst),
    ];
    expect(edDsts.any((d) => d.contains("Director's Cut")), isTrue);
    expect(edDsts.any((d) => d.contains('IMAX')), isTrue);

    final partScan = await recognizer.recognize(
      conn,
      const ['/dl'],
      const [
        RemoteEntry(
          path: '/dl/Inception.2010.CD1.mkv',
          name: 'Inception.2010.CD1.mkv',
          isDir: false,
          size: 4 << 30,
        ),
        RemoteEntry(
          path: '/dl/Inception.2010.CD2.mkv',
          name: 'Inception.2010.CD2.mkv',
          isDir: false,
          size: 4 << 30,
        ),
      ],
    );
    final partPlan = await planner.build(
      partScan,
      const {},
      const PlanOptions(mode: OrganizeMode.inPlace),
    );
    expect(partPlan.conflicts, isEmpty);
    final partDsts = [
      for (final o in partPlan.ops)
        if (o.kind == OpKind.relocate) _baseName(o.dst),
    ];
    expect(partDsts.any((d) => d.endsWith('-cd1.mkv')), isTrue);
    expect(partDsts.any((d) => d.endsWith('-cd2.mkv')), isTrue);
  });

  test('end-to-end: expanded Traditional Chinese title matches Simplified TMDB entry', () async {
    const meta = _StubMetadata(
      shows: [
        ShowDetail(
          info: Candidate(
            tmdbId: 1429,
            kind: MediaKind.episode,
            title: '进击的巨人',
            englishTitle: 'Attack on Titan',
            year: 2013,
          ),
          seasons: [SeasonInfo(number: 1, episodeCount: 25)],
        ),
      ],
    );
    final recognizer = AnchorRecognizer(const RuleBasedParser(), meta);
    final scan = await recognizer.recognize(
      conn,
      const ['/dl'],
      const [
        RemoteEntry(
          path: '/dl/進擊的巨人/進擊的巨人 S01E01.mkv',
          name: '進擊的巨人 S01E01.mkv',
          isDir: false,
          size: 1 << 30,
        ),
      ],
    );

    expect(scan.groups, hasLength(1));
    expect(scan.groups.single.match?.tmdbId, 1429);
    expect(scan.groups.single.matchScore, greaterThanOrEqualTo(0.8));
  });
}
