// Explicit JSON for the task data that drift stores as text columns. Kept here
// (not in core models) so core stays free of serialization concerns.
import 'dart:convert';

import 'package:tidyreel_core/tidyreel_core.dart';

typedef Json = Map<String, dynamic>;

/// Safe enum decoder: unknown names fall back instead of crashing startup.
T enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  if (name is String) {
    for (final v in values) {
      if (v.name == name) return v;
    }
  }
  return fallback;
}

T? enumByNameOrNull<T extends Enum>(List<T> values, Object? name) {
  if (name is String) {
    for (final v in values) {
      if (v.name == name) return v;
    }
  }
  return null;
}

Json _probeToJson(MediaProbeInfo p) => {
  if (p.width != null) 'width': p.width,
  if (p.height != null) 'height': p.height,
  if (p.videoCodec != null) 'videoCodec': p.videoCodec,
  if (p.hdr != null) 'hdr': p.hdr,
  if (p.audioCodec != null) 'audioCodec': p.audioCodec,
  if (p.audioChannels != null) 'audioChannels': p.audioChannels,
  if (p.duration != null) 'durationMs': p.duration!.inMilliseconds,
  if (p.container != null) 'container': p.container,
};

MediaProbeInfo _probeFromJson(Json j) => MediaProbeInfo(
  width: j['width'] as int?,
  height: j['height'] as int?,
  videoCodec: j['videoCodec'] as String?,
  hdr: j['hdr'] as String?,
  audioCodec: j['audioCodec'] as String?,
  audioChannels: j['audioChannels'] as int?,
  duration: j['durationMs'] is num
      ? Duration(milliseconds: (j['durationMs'] as num).toInt())
      : null,
  container: j['container'] as String?,
);

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
  if (c.voteCount != null) 'voteCount': c.voteCount,
  if (c.popularity != null) 'popularity': c.popularity,
  'genres': c.genres,
  if (c.imdbId != null) 'imdbId': c.imdbId,
  if (c.tvdbId != null) 'tvdbId': c.tvdbId,
  if (c.collectionName != null) 'collectionName': c.collectionName,
  if (c.collectionId != null) 'collectionId': c.collectionId,
  if (c.clearLogoPath != null) 'clearLogoPath': c.clearLogoPath,
  if (c.landscapePath != null) 'landscapePath': c.landscapePath,
  if (c.certification != null) 'certification': c.certification,
  if (c.studios.isNotEmpty) 'studios': c.studios,
  if (c.actors.isNotEmpty)
    'actors': [
      for (final a in c.actors)
        {
          'name': a.name,
          if (a.role != null) 'role': a.role,
          if (a.profilePath != null) 'profilePath': a.profilePath,
        },
    ],
  if (c.directors.isNotEmpty) 'directors': c.directors,
  if (c.writers.isNotEmpty) 'writers': c.writers,
  if (c.tags.isNotEmpty) 'tags': c.tags,
};

Candidate candidateFromJson(Json j) => Candidate(
  tmdbId: j['tmdbId'] as int,
  kind: enumByName(MediaKind.values, j['kind'], MediaKind.unknown),
  title: j['title'] as String,
  englishTitle: j['englishTitle'] as String?,
  originalTitle: j['originalTitle'] as String?,
  year: j['year'] as int?,
  overview: j['overview'] as String?,
  posterPath: j['posterPath'] as String?,
  backdropPath: j['backdropPath'] as String?,
  originCountry: j['originCountry'] as String?,
  voteAverage: (j['voteAverage'] as num?)?.toDouble(),
  voteCount: (j['voteCount'] as num?)?.toInt(),
  popularity: (j['popularity'] as num?)?.toDouble(),
  genres: (j['genres'] as List?)?.cast<String>() ?? const [],
  imdbId: j['imdbId'] as String?,
  tvdbId: (j['tvdbId'] as num?)?.toInt(),
  collectionName: j['collectionName'] as String?,
  collectionId: (j['collectionId'] as num?)?.toInt(),
  clearLogoPath: j['clearLogoPath'] as String?,
  landscapePath: j['landscapePath'] as String?,
  certification: j['certification'] as String?,
  studios: (j['studios'] as List?)?.cast<String>() ?? const [],
  actors: [
    for (final a in (j['actors'] as List?)?.cast<Json>() ?? const <Json>[])
      PersonCredit(
        name: a['name'] as String,
        role: a['role'] as String?,
        profilePath: a['profilePath'] as String?,
      ),
  ],
  directors: (j['directors'] as List?)?.cast<String>() ?? const [],
  writers: (j['writers'] as List?)?.cast<String>() ?? const [],
  tags: (j['tags'] as List?)?.cast<String>() ?? const [],
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
  if (p.edition != null) 'edition': p.edition,
  if (p.part != null) 'part': p.part,
  if (p.partLabel != null) 'partLabel': p.partLabel,
  if (p.subFlags.isNotEmpty) 'subFlags': p.subFlags,
  if (p.externalId != null)
    'externalId': {'source': p.externalId!.source, 'id': p.externalId!.id},
  if (p.isDisc) 'isDisc': true,
  if (p.probe != null) 'probe': _probeToJson(p.probe!),
};

ParsedName _parsedFromJson(Json j) => ParsedName(
  title: j['title'] as String?,
  year: j['year'] as int?,
  season: j['season'] as int?,
  episodes: List<int>.of((j['episodes'] as List).cast<int>()),
  absolute: j['absolute'] as int?,
  airDate: j['airDate'] is String
      ? DateTime.tryParse(j['airDate'] as String)
      : null,
  kind: enumByName(MediaKind.values, j['kind'], MediaKind.unknown),
  resolution: j['resolution'] as String?,
  group: j['group'] as String?,
  lang: j['lang'] as String?,
  extraInfo: j['extraInfo'] as String?,
  confidence: (j['confidence'] as num).toDouble(),
  edition: j['edition'] as String?,
  part: (j['part'] as num?)?.toInt(),
  partLabel: j['partLabel'] as String?,
  subFlags: (j['subFlags'] as List?)?.cast<String>() ?? const [],
  externalId: j['externalId'] is Map
      ? ExternalId(
          (j['externalId'] as Map)['source'] as String,
          (j['externalId'] as Map)['id'] as String,
        )
      : null,
  isDisc: j['isDisc'] as bool? ?? false,
  probe: j['probe'] is Map
      ? _probeFromJson((j['probe'] as Map).cast<String, dynamic>())
      : null,
);

Json _fileToJson(ScanFile f) => {
  'path': f.path,
  'name': f.name,
  'size': f.size,
  'role': f.role.name,
  'parsed': f.parsed == null ? null : _parsedToJson(f.parsed!),
  if (f.isDiscDir) 'isDiscDir': true,
};

ScanFile _fileFromJson(Json j) => ScanFile(
  path: j['path'] as String,
  name: j['name'] as String,
  size: j['size'] as int,
  role: enumByName(FileRole.values, j['role'], FileRole.other),
  parsed: j['parsed'] == null ? null : _parsedFromJson(j['parsed'] as Json),
  isDiscDir: j['isDiscDir'] as bool? ?? false,
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
        airDate: x['airDate'] is String
            ? DateTime.tryParse(x['airDate'] as String)
            : null,
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
  if (g.suggestedStrategy != null)
    'suggestedStrategy': g.suggestedStrategy!.name,
  if (g.suggestedStrategyReason != null)
    'suggestedStrategyReason': g.suggestedStrategyReason,
};

MediaGroup _groupFromJson(Json j) => MediaGroup(
  id: GroupId(j['id'] as String),
  kind: enumByName(MediaKind.values, j['kind'], MediaKind.unknown),
  anchorTitle: j['anchorTitle'] as String,
  anchorYear: j['anchorYear'] as int?,
  rootDir: j['rootDir'] as String,
  files: [for (final f in (j['files'] as List).cast<Json>()) _fileFromJson(f)],
  match: j['match'] == null ? null : candidateFromJson(j['match'] as Json),
  matchScore: (j['matchScore'] as num).toDouble(),
  show: j['show'] == null ? null : _showFromJson(j['show'] as Json),
  suggestedStrategy: enumByNameOrNull(
    SeasonStrategy.values,
    j['suggestedStrategy'],
  ),
  suggestedStrategyReason: j['suggestedStrategyReason'] as String?,
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
  strategy: enumByName(
    SeasonStrategy.values,
    j['strategy'],
    SeasonStrategy.asParsed,
  ),
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
        kind: enumByNameOrNull(MediaKind.values, o['kind']),
        ignore: o['ignore'] as bool,
      ),
  },
);
