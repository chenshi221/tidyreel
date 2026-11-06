// Explicit JSON for the task data that drift stores as text columns. Kept here
// (not in core models) so core stays free of serialization concerns.
import 'dart:convert';

import 'package:tidyreel_core/tidyreel_core.dart';

typedef Json = Map<String, dynamic>;

Json candidateToJson(Candidate c) => {
  'tmdbId': c.tmdbId,
  'kind': c.kind.name,
  'title': c.title,
  'englishTitle': c.englishTitle,
  'originalTitle': c.originalTitle,
  'year': c.year,
  'overview': c.overview,
  'posterPath': c.posterPath,
  'backdropPath': c.backdropPath,
  'originCountry': c.originCountry,
  'voteAverage': c.voteAverage,
  'genres': c.genres,
};

Candidate candidateFromJson(Json j) => Candidate(
  tmdbId: j['tmdbId'] as int,
  kind: MediaKind.values.byName(j['kind'] as String),
  title: j['title'] as String,
  englishTitle: j['englishTitle'] as String?,
  originalTitle: j['originalTitle'] as String?,
  year: j['year'] as int?,
  overview: j['overview'] as String?,
  posterPath: j['posterPath'] as String?,
  backdropPath: j['backdropPath'] as String?,
  originCountry: j['originCountry'] as String?,
  voteAverage: (j['voteAverage'] as num?)?.toDouble(),
  genres: (j['genres'] as List?)?.cast<String>() ?? const [],
);

Json _parsedToJson(ParsedName p) => {
  'title': p.title,
  'year': p.year,
  'season': p.season,
  'episodes': p.episodes,
  'absolute': p.absolute,
  'airDate': p.airDate?.toIso8601String(),
  'kind': p.kind.name,
  'resolution': p.resolution,
  'group': p.group,
  'lang': p.lang,
  'extraInfo': p.extraInfo,
  'confidence': p.confidence,
};

ParsedName _parsedFromJson(Json j) => ParsedName(
  title: j['title'] as String?,
  year: j['year'] as int?,
  season: j['season'] as int?,
  episodes: List<int>.of((j['episodes'] as List).cast<int>()),
  absolute: j['absolute'] as int?,
  airDate: j['airDate'] == null
      ? null
      : DateTime.tryParse(j['airDate'] as String),
  kind: MediaKind.values.byName(j['kind'] as String),
  resolution: j['resolution'] as String?,
  group: j['group'] as String?,
  lang: j['lang'] as String?,
  extraInfo: j['extraInfo'] as String?,
  confidence: (j['confidence'] as num).toDouble(),
);

Json _fileToJson(ScanFile f) => {
  'path': f.path,
  'name': f.name,
  'size': f.size,
  'role': f.role.name,
  'parsed': f.parsed == null ? null : _parsedToJson(f.parsed!),
};

ScanFile _fileFromJson(Json j) => ScanFile(
  path: j['path'] as String,
  name: j['name'] as String,
  size: j['size'] as int,
  role: FileRole.values.byName(j['role'] as String),
  parsed: j['parsed'] == null ? null : _parsedFromJson(j['parsed'] as Json),
);

Json _showToJson(ShowDetail s) => {
  'info': candidateToJson(s.info),
  'seasons': [
    for (final x in s.seasons)
      {
        'number': x.number,
        'episodeCount': x.episodeCount,
        'name': x.name,
        'airDate': x.airDate?.toIso8601String(),
        'posterPath': x.posterPath,
      },
  ],
};

ShowDetail _showFromJson(Json j) => ShowDetail(
  info: candidateFromJson(j['info'] as Json),
  seasons: [
    for (final x in (j['seasons'] as List).cast<Json>())
      SeasonInfo(
        number: x['number'] as int,
        episodeCount: x['episodeCount'] as int,
        name: x['name'] as String?,
        airDate: x['airDate'] == null
            ? null
            : DateTime.parse(x['airDate'] as String),
        posterPath: x['posterPath'] as String?,
      ),
  ],
);

Json _groupToJson(MediaGroup g) => {
  'id': g.id.value,
  'kind': g.kind.name,
  'anchorTitle': g.anchorTitle,
  'anchorYear': g.anchorYear,
  'rootDir': g.rootDir,
  'files': [for (final f in g.files) _fileToJson(f)],
  'match': g.match == null ? null : candidateToJson(g.match!),
  'matchScore': g.matchScore,
  'show': g.show == null ? null : _showToJson(g.show!),
};

MediaGroup _groupFromJson(Json j) => MediaGroup(
  id: GroupId(j['id'] as String),
  kind: MediaKind.values.byName(j['kind'] as String),
  anchorTitle: j['anchorTitle'] as String,
  anchorYear: j['anchorYear'] as int?,
  rootDir: j['rootDir'] as String,
  files: [for (final f in (j['files'] as List).cast<Json>()) _fileFromJson(f)],
  match: j['match'] == null ? null : candidateFromJson(j['match'] as Json),
  matchScore: (j['matchScore'] as num).toDouble(),
  show: j['show'] == null ? null : _showFromJson(j['show'] as Json),
);

String scanToJson(ScanResult s) => jsonEncode({
  'connection': s.connection.value,
  'roots': s.roots,
  'groups': [for (final g in s.groups) _groupToJson(g)],
  'unassigned': [for (final f in s.unassigned) _fileToJson(f)],
});

ScanResult scanFromJson(String text) {
  final j = jsonDecode(text) as Json;
  return ScanResult(
    connection: ConnectionId(j['connection'] as String),
    roots: (j['roots'] as List).cast<String>(),
    groups: [
      for (final g in (j['groups'] as List).cast<Json>()) _groupFromJson(g),
    ],
    unassigned: [
      for (final f in (j['unassigned'] as List).cast<Json>()) _fileFromJson(f),
    ],
  );
}

String decisionsToJson(Map<GroupId, GroupDecision> decisions) => jsonEncode({
  for (final MapEntry(key: id, value: d) in decisions.entries)
    id.value: {
      'match': d.match == null ? null : candidateToJson(d.match!),
      'strategy': d.strategy.name,
      'episodeOffset': d.episodeOffset,
      'episodeGroupId': d.episodeGroupId,
      'selected': d.selected,
      if (d.separate) 'separate': true,
      'overrides': {
        for (final MapEntry(key: path, value: o) in d.overrides.entries)
          path: {
            'season': o.season,
            'episode': o.episode,
            'kind': o.kind?.name,
            'ignore': o.ignore,
          },
      },
    },
});

Map<GroupId, GroupDecision> decisionsFromJson(String text) {
  final j = jsonDecode(text) as Json;
  return {
    for (final MapEntry(key: id, value: v) in j.entries)
      GroupId(id): _decisionFromJson(v as Json),
  };
}

GroupDecision _decisionFromJson(Json j) => GroupDecision(
  match: j['match'] == null ? null : candidateFromJson(j['match'] as Json),
  strategy: SeasonStrategy.values.byName(j['strategy'] as String),
  episodeOffset: j['episodeOffset'] as int,
  episodeGroupId: j['episodeGroupId'] as String?,
  selected: j['selected'] as bool,
  separate: j['separate'] as bool? ?? false,
  overrides: {
    for (final MapEntry(key: path, value: o)
        in (j['overrides'] as Json).entries)
      path: FileOverride(
        season: (o as Json)['season'] as int?,
        episode: o['episode'] as int?,
        kind: o['kind'] == null
            ? null
            : MediaKind.values.byName(o['kind'] as String),
        ignore: o['ignore'] as bool,
      ),
  },
);
