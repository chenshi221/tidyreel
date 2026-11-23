import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../l10n/l10n.dart';
import 'bootstrap.dart';
import 'drift_history_store.dart';
import 'drift_task_store.dart';
import 'folder_stats_store.dart';
import 'settings.dart';
import 'settings_codec.dart';

// Every engine dependency the UI uses goes through these providers.
// main() overrides [bootstrapProvider] with the real stores; without an override
// (tests) everything runs in demo mode: memory backend + fake TMDB.

final bootstrapProvider = Provider<Bootstrap>((ref) {
  final boot = Bootstrap.demo();
  ref.onDispose(() {
    boot.tmdbCache?.flushSync();
    unawaited(boot.db.close());
  });
  return boot;
});

// ---- connections ---------------------------------------------------------

const _connectionsKey = 'connections';

const _demoConnections = [
  ConnectionConfig(
    id: ConnectionId('demo-alist'),
    name: '演示 Alist',
    type: ConnectionType.alist,
    endpoint: 'http://nas.local:5244',
    username: 'admin',
    libraryRoot: '/影视库',
    favorites: ['/下载/完成'],
  ),
  ConnectionConfig(
    id: ConnectionId('demo-local'),
    name: '演示本地',
    type: ConnectionType.local,
    endpoint: '/Users/me/Downloads',
  ),
];

class ConnectionsNotifier extends Notifier<List<ConnectionConfig>> {
  Bootstrap get _boot => ref.read(bootstrapProvider);

  @override
  List<ConnectionConfig> build() {
    final saved = _boot.prefs.read(_connectionsKey) as List?;
    if (saved == null) return _boot.demo ? _demoConnections : const [];
    return [
      for (final j in saved)
        connectionFromJson((j as Map).cast<String, Object?>()),
    ];
  }

  void _save(List<ConnectionConfig> list) {
    state = list;
    _boot.prefs.write(_connectionsKey, [
      for (final c in list) connectionToJson(c),
    ]);
  }

  void upsert(ConnectionConfig c) {
    final i = state.indexWhere((e) => e.id == c.id);
    _save(
      i < 0 ? [...state, c] : [for (final e in state) e.id == c.id ? c : e],
    );
  }

  void remove(ConnectionId id) {
    _save([
      for (final e in state)
        if (e.id != id) e,
    ]);
    ref
        .read(connectionPasswordsProvider.notifier)
        .set({...ref.read(connectionPasswordsProvider)}..remove(id));
    ref.read(connectionDirPasswordsProvider.notifier).setFor(id, const {});
    unawaited(ref.read(folderStatsStoreProvider).clearFor(id));
  }

  void toggleFavorite(ConnectionId id, String path) {
    final c = state.firstWhere((e) => e.id == id);
    upsert(
      c.copyWith(
        favorites: c.favorites.contains(path)
            ? [
                for (final f in c.favorites)
                  if (f != path) f,
              ]
            : [...c.favorites, path],
      ),
    );
  }
}

final connectionsProvider =
    NotifierProvider<ConnectionsNotifier, List<ConnectionConfig>>(
      ConnectionsNotifier.new,
    );

/// Connection passwords, kept in secrets.json under `conn:<id>`.
class PasswordsNotifier extends Notifier<Map<ConnectionId, String>> {
  Bootstrap get _boot => ref.read(bootstrapProvider);

  @override
  Map<ConnectionId, String> build() => {
    for (final c in ref.read(connectionsProvider))
      c.id: ?_boot.secrets.read('conn:${c.id.value}'),
  };

  void set(Map<ConnectionId, String> value) {
    for (final id in {...state.keys, ...value.keys}) {
      if (state[id] != value[id]) {
        _boot.secrets.write('conn:${id.value}', value[id]);
      }
    }
    state = value;
  }
}

final connectionPasswordsProvider =
    NotifierProvider<PasswordsNotifier, Map<ConnectionId, String>>(
      PasswordsNotifier.new,
    );

/// Per-directory access passwords (e.g. Alist/OpenList protected folders),
/// stored in secrets.json under `conn_dirs:<id>` as JSON.
class DirPasswordsNotifier
    extends Notifier<Map<ConnectionId, Map<String, String>>> {
  Bootstrap get _boot => ref.read(bootstrapProvider);

  @override
  Map<ConnectionId, Map<String, String>> build() {
    final out = <ConnectionId, Map<String, String>>{};
    for (final c in ref.read(connectionsProvider)) {
      final raw = _boot.secrets.read('conn_dirs:${c.id.value}');
      if (raw == null || raw.isEmpty) continue;
      try {
        final decoded = (jsonDecode(raw) as Map).cast<String, Object?>();
        final map = <String, String>{
          for (final e in decoded.entries)
            if (e.value is String && (e.value as String).isNotEmpty)
              normalizeDir(e.key): e.value as String,
        };
        if (map.isNotEmpty) out[c.id] = map;
      } on Object {
        // Ignore corrupt dir passwords JSON.
      }
    }
    return out;
  }

  void setFor(ConnectionId id, Map<String, String> dirs) {
    final clean = <String, String>{
      for (final e in dirs.entries)
        if (e.key.trim().isNotEmpty && e.value.isNotEmpty)
          normalizeDir(e.key): e.value,
    };
    final next = {...state};
    if (clean.isEmpty) {
      next.remove(id);
      _boot.secrets.write('conn_dirs:${id.value}', null);
    } else {
      next[id] = clean;
      _boot.secrets.write('conn_dirs:${id.value}', jsonEncode(clean));
    }
    state = next;
  }
}

final connectionDirPasswordsProvider =
    NotifierProvider<
      DirPasswordsNotifier,
      Map<ConnectionId, Map<String, String>>
    >(DirPasswordsNotifier.new);

// ---- engine --------------------------------------------------------------

/// Sample files every demo connection browses.
final demoBackendProvider = Provider<StorageBackend>(
  (ref) => MemoryStorageBackend({
    '/下载/完成/异兽魔都 2020 1080p/[Sub] Dorohedoro S01E01 [1080p].mkv': 1 << 30,
    '/下载/完成/异兽魔都 2020 1080p/[Sub] Dorohedoro S01E01 [1080p].chs.ass': 40000,
    '/下载/完成/异兽魔都 2020 1080p/[Sub] Dorohedoro S01E02 [1080p].mkv': 1 << 30,
    '/下载/完成/Inception.2010.2160p.BluRay.x265.mkv': 20 << 30,
    '/下载/完成/更多资源请访问 www.example.com.txt': 120,
  }),
);

String _backendKey(
  ConnectionConfig c,
  String? password,
  Map<String, String> dirPasswords,
) {
  final dirEntries = dirPasswords.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  final dirs = [for (final e in dirEntries) '${e.key}=${e.value}'].join('&');
  return [c.type.name, c.endpoint, c.username, password, dirs].join('\n');
}

class _BackendPool {
  final _entries = <String, CachedBackend>{};

  CachedBackend getOrCreate(
    String key,
    ConnectionConfig config,
    String? password,
    Map<String, String> dirPasswords,
    Duration Function() minIntervalProvider,
  ) => _entries.putIfAbsent(
    key,
    () => CachedBackend(
      ThrottledBackend(
        createBackend(
          config,
          Credentials(password: password, dirPasswords: dirPasswords),
        ),
        minInterval: config.type == ConnectionType.local
            ? Duration.zero
            : minIntervalProvider(),
        minIntervalProvider: config.type == ConnectionType.local
            ? null
            : minIntervalProvider,
      ),
    ),
  );

  void prune(Set<String> activeKeys) {
    final stale = [
      for (final k in _entries.keys)
        if (!activeKeys.contains(k)) k,
    ];
    for (final k in stale) {
      final be = _entries.remove(k);
      if (be != null) unawaited(be.close());
    }
  }

  void dispose() {
    for (final be in _entries.values) {
      unawaited(be.close());
    }
    _entries.clear();
  }
}

/// Live backends by server + account. Outlives [connectionBackendProvider] so
/// editing favorites doesn't log in again or drop cached listings, and
/// connections to the same server share both rate limiting and cache.
final _backendPoolProvider = Provider<_BackendPool>((ref) {
  final pool = _BackendPool();
  void prune() {
    final conns = ref.read(connectionsProvider);
    final passwords = ref.read(connectionPasswordsProvider);
    final dirPasswords = ref.read(connectionDirPasswordsProvider);
    pool.prune({
      for (final c in conns)
        _backendKey(c, passwords[c.id], dirPasswords[c.id] ?? const {}),
    });
  }

  ref.listen(connectionsProvider, (_, _) => prune());
  ref.listen(connectionPasswordsProvider, (_, _) => prune());
  ref.listen(connectionDirPasswordsProvider, (_, _) => prune());
  ref.onDispose(pool.dispose);
  return pool;
});

/// Targeted backend for one connection. Watches ONLY the target connection's
/// `(type, endpoint, username)` and credentials so toggling favorites or editing
/// other connections never invalidates this backend, its status, or its
/// [SizeScanner].
final connectionBackendProvider = Provider.family<StorageBackend, ConnectionId>(
  (ref, id) {
    if (ref.watch(bootstrapProvider).demo) {
      return ref.watch(demoBackendProvider);
    }
    final keyParts = ref.watch(
      connectionsProvider.select((list) {
        final c = list.where((e) => e.id == id).firstOrNull;
        return c == null ? null : (c.type, c.endpoint, c.username);
      }),
    );
    if (keyParts == null) {
      throw StateError('连接不存在：${id.value}');
    }
    final password = ref.watch(
      connectionPasswordsProvider.select((m) => m[id]),
    );
    final dirPasswords = ref.watch(
      connectionDirPasswordsProvider.select((m) => m[id] ?? const {}),
    );
    final pool = ref.watch(_backendPoolProvider);
    final c = ref.read(connectionsProvider).firstWhere((e) => e.id == id);
    Duration minInterval() {
      final rps = ref.read(settingsProvider).requestsPerSecond;
      return rps <= 0 ? Duration.zero : Duration(milliseconds: 1000 ~/ rps);
    }

    return pool.getOrCreate(
      _backendKey(c, password, dirPasswords),
      c,
      password,
      dirPasswords,
      minInterval,
    );
  },
);

/// Backend lookup by connection id, backed by [connectionBackendProvider].
final backendForProvider = Provider<StorageBackend Function(ConnectionId)>(
  (ref) =>
      (id) => ref.read(connectionBackendProvider(id)),
);

/// TMDB token compiled in with `--dart-define-from-file=tmdb.local.json`
/// (see tool/build_macos.sh); empty in source builds without that file.
final builtInTmdbTokenProvider = Provider<String>(
  (ref) => const String.fromEnvironment('TMDB_TOKEN'),
);

final metadataProvider = Provider<MetadataProvider>((ref) {
  if (ref.watch(bootstrapProvider).demo) return FakeMetadataProvider();
  // Only the TMDB fields: other settings changes must not drop the cache.
  final (apiKey, baseUrl, language) = ref.watch(
    settingsProvider.select(
      (s) => (s.tmdbApiKey.trim(), s.tmdbBaseUrl.trim(), s.tmdbLanguage),
    ),
  );
  // The user's own key wins over the built-in one.
  final key = apiKey.isNotEmpty ? apiKey : ref.watch(builtInTmdbTokenProvider);
  if (key.isEmpty) return const _MissingKeyMetadata();
  return TmdbProvider(
    TmdbConfig(
      apiKey: key,
      baseUrl: baseUrl,
      language: language,
      fallbackLanguage: language == 'en-US' ? 'zh-CN' : 'en-US',
    ),
    cache: ref.watch(bootstrapProvider).tmdbCache,
  );
});

final historyProvider = Provider<HistoryStore>(
  (ref) => DriftHistoryStore(ref.watch(bootstrapProvider).db),
);

final folderStatsStoreProvider = Provider<FolderStatsStore>(
  (ref) => FolderStatsStore(ref.watch(bootstrapProvider).db),
);

final taskManagerProvider = Provider<TaskManager>((ref) {
  // Long-lived: reads backends, metadata and options at call time, so settings
  // changes apply to the next step without rebuilding the manager.
  final metadata = _LiveMetadata(() => ref.read(metadataProvider));
  final history = ref.watch(historyProvider);
  final demo = ref.read(bootstrapProvider).demo;
  final bangumi = demo ? null : BangumiTitles();
  final anilist = demo ? null : AniListTitles();
  final altTitles = demo
      ? null
      : _LiveAltTitleSource(
          bangumi: bangumi!,
          anilist: anilist!,
          enableBangumi: () => ref.read(settingsProvider).enableBangumi,
        );
  final tm = DefaultTaskManager(
    backendFor: (id) => ref.read(backendForProvider)(id),
    recognizer: AnchorRecognizer(
      const RuleBasedParser(),
      metadata,
      altTitles: altTitles,
      hint: () => ref.read(settingsProvider).mediaHint,
      titleRules: () => ref.read(titleRulesProvider),
      mediaProbe: const ContainerMediaProbe(),
      probeMedia: () => ref.read(settingsProvider).probeMedia,
    ),
    planner: DefaultPlanner(metadata),
    executor: DefaultExecutor(
      history,
      concurrency: ref.read(settingsProvider).concurrency,
      concurrencyProvider: () => ref.read(settingsProvider).concurrency,
      // Real backends are already rate-limited inside _backendPoolProvider's
      // ThrottledBackend so all operations share one pacing window.
      minInterval: Duration.zero,
    ),
    history: history,
    store: DriftTaskStore(ref.watch(bootstrapProvider).db),
    options: (id, mode) {
      final s = ref.read(settingsProvider);
      return PlanOptions(
        mode: mode,
        libraryRoot: ref
            .read(connectionsProvider)
            .where((c) => c.id == id)
            .firstOrNull
            ?.libraryRoot,
        naming: ref.read(namingProfileProvider),
        deleteJunk: s.autoDeleteJunk,
        confidenceThreshold: s.confidenceThreshold,
        overwriteNfo: s.overwriteNfo,
        probeMedia: s.probeMedia,
      );
    },
  );
  tm.resumeInterrupted();
  ref.onDispose(() {
    tm.dispose();
    bangumi?.close();
    anilist?.close();
  });
  return tm;
});

final tasksProvider = StreamProvider<List<TaskSummary>>(
  (ref) => ref.watch(taskManagerProvider).watchAll(),
);

// ---- naming --------------------------------------------------------------

const _namingKey = 'naming';

class NamingProfileNotifier extends Notifier<NamingProfile> {
  @override
  NamingProfile build() {
    final boot = ref.read(bootstrapProvider);
    final j = boot.prefs.read(_namingKey);
    return j is Map
        ? namingProfileFromJson(j.cast<String, Object?>())
        : defaultNamingProfileFor(boot.systemLocale);
  }

  void set(NamingProfile profile) {
    state = profile;
    ref
        .read(bootstrapProvider)
        .prefs
        .write(_namingKey, namingProfileToJson(profile));
  }
}

final namingProfileProvider =
    NotifierProvider<NamingProfileNotifier, NamingProfile>(
      NamingProfileNotifier.new,
    );

const _titleRulesKey = 'titleRules';

/// 片名规则: cleanups and pins the recognizer applies before searching TMDB.
class TitleRulesNotifier extends Notifier<TitleRules> {
  @override
  TitleRules build() {
    final j = ref.read(bootstrapProvider).prefs.read(_titleRulesKey);
    return j is Map
        ? titleRulesFromJson(j.cast<String, Object?>())
        : const TitleRules();
  }

  void set(TitleRules rules) {
    state = rules;
    ref
        .read(bootstrapProvider)
        .prefs
        .write(_titleRulesKey, titleRulesToJson(rules));
  }

  /// Adds (or replaces) the pin for [keyword].
  void pin(String keyword, Candidate match) => set(
    TitleRules(
      cleanups: state.cleanups,
      pins: [
        for (final p in state.pins)
          if (p.keyword != keyword) p,
        TitlePin(keyword, match),
      ],
    ),
  );
}

final titleRulesProvider = NotifierProvider<TitleRulesNotifier, TitleRules>(
  TitleRulesNotifier.new,
);

// ---- helpers -------------------------------------------------------------

/// Forwards to whatever [metadataProvider] currently is (key / proxy edits).
class _LiveMetadata implements MetadataProvider, ExternalIdLookup {
  final MetadataProvider Function() _current;

  _LiveMetadata(this._current);

  @override
  Future<Candidate?> findByExternalId(
    String source,
    String id, {
    MediaKind? kind,
  }) async {
    final cur = _current();
    if (cur is ExternalIdLookup) {
      return (cur as ExternalIdLookup).findByExternalId(source, id, kind: kind);
    }
    return null;
  }

  @override
  Future<List<Candidate>> search(String query, {MediaKind? kind, int? year}) =>
      _current().search(query, kind: kind, year: year);

  @override
  Future<ShowDetail> show(int tmdbId) => _current().show(tmdbId);

  @override
  Future<List<Episode>> season(int tmdbId, int season) =>
      _current().season(tmdbId, season);

  @override
  Future<List<EpisodeGroup>> episodeGroups(int tmdbId) =>
      _current().episodeGroups(tmdbId);

  @override
  Future<MovieDetail> movie(int tmdbId) => _current().movie(tmdbId);
}

class _LiveAltTitleSource implements AltTitleSource {
  final BangumiTitles bangumi;
  final AniListTitles anilist;
  final bool Function() enableBangumi;

  const _LiveAltTitleSource({
    required this.bangumi,
    required this.anilist,
    required this.enableBangumi,
  });

  @override
  Future<List<String>> altTitles(String query) {
    final source = enableBangumi()
        ? CompositeAltTitleSource([bangumi, anilist])
        : anilist;
    return source.altTitles(query);
  }
}

class _MissingKeyMetadata implements MetadataProvider {
  const _MissingKeyMetadata();

  Never _fail() => throw StateError('请先在「设置」里填写 TMDB API key');

  @override
  Future<List<Candidate>> search(String query, {MediaKind? kind, int? year}) =>
      _fail();

  @override
  Future<ShowDetail> show(int tmdbId) => _fail();

  @override
  Future<List<Episode>> season(int tmdbId, int season) => _fail();

  @override
  Future<List<EpisodeGroup>> episodeGroups(int tmdbId) => _fail();

  @override
  Future<MovieDetail> movie(int tmdbId) => _fail();
}
