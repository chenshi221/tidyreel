import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'bootstrap.dart';
import 'drift_history_store.dart';
import 'drift_task_store.dart';
import 'settings.dart';
import 'settings_codec.dart';

// Every engine dependency the UI uses goes through these providers.
// main() overrides [bootstrapProvider] with the real stores; without an override
// (tests) everything runs in demo mode: memory backend + fake TMDB.

final bootstrapProvider = Provider<Bootstrap>((ref) {
  final boot = Bootstrap.demo();
  ref.onDispose(boot.db.close);
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

/// Live backends by server + account. Outlives [backendForProvider] so editing
/// favorites doesn't log in again or drop cached listings, and connections to
/// the same server share both.
final _backendPoolProvider = Provider<Map<String, CachedBackend>>((_) => {});

/// Backend for a connection id, with listings cached (see [CachedBackend]).
final backendForProvider = Provider<StorageBackend Function(ConnectionId)>((
  ref,
) {
  if (ref.watch(bootstrapProvider).demo) {
    final demo = ref.watch(demoBackendProvider);
    return (_) => demo;
  }
  final conns = ref.watch(connectionsProvider);
  final passwords = ref.watch(connectionPasswordsProvider);
  final pool = ref.watch(_backendPoolProvider);
  return (id) {
    final c = conns.firstWhere(
      (c) => c.id == id,
      orElse: () => throw StateError('连接不存在：${id.value}'),
    );
    final key = [c.type.name, c.endpoint, c.username, passwords[id]].join('\n');
    return pool.putIfAbsent(
      key,
      () =>
          CachedBackend(createBackend(c, Credentials(password: passwords[id]))),
    );
  };
});

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

final taskManagerProvider = Provider<TaskManager>((ref) {
  // Long-lived: reads backends, metadata and options at call time, so settings
  // changes apply to the next step without rebuilding the manager.
  final metadata = _LiveMetadata(() => ref.read(metadataProvider));
  final history = ref.watch(historyProvider);
  // Read once: changing these takes effect from the next app start.
  final s = ref.read(settingsProvider);
  final tm = DefaultTaskManager(
    backendFor: (id) => ref.read(backendForProvider)(id),
    recognizer: AnchorRecognizer(
      const RuleBasedParser(),
      metadata,
      altTitles: ref.read(bootstrapProvider).demo ? null : AniListTitles(),
      hint: () => ref.read(settingsProvider).mediaHint,
      titleRules: () => ref.read(titleRulesProvider),
    ),
    planner: DefaultPlanner(metadata),
    executor: DefaultExecutor(
      history,
      concurrency: s.concurrency,
      minInterval: s.requestsPerSecond <= 0
          ? Duration.zero
          : Duration(milliseconds: 1000 ~/ s.requestsPerSecond),
    ),
    history: history,
    store: DriftTaskStore(ref.watch(bootstrapProvider).db),
    options: (id, mode) => PlanOptions(
      mode: mode,
      libraryRoot: ref
          .read(connectionsProvider)
          .where((c) => c.id == id)
          .firstOrNull
          ?.libraryRoot,
      naming: ref.read(namingProfileProvider),
      deleteJunk: ref.read(settingsProvider).autoDeleteJunk,
      confidenceThreshold: ref.read(settingsProvider).confidenceThreshold,
    ),
  );
  tm.resumeInterrupted();
  ref.onDispose(tm.dispose);
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
    final j = ref.read(bootstrapProvider).prefs.read(_namingKey);
    return j is Map
        ? namingProfileFromJson(j.cast<String, Object?>())
        : NamingProfile.vidhub;
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
class _LiveMetadata implements MetadataProvider {
  final MetadataProvider Function() _current;

  _LiveMetadata(this._current);

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
