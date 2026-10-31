import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../widgets/common.dart';
import '../settings/settings_providers.dart';

/// Editable copy of [connectionsProvider] (add / edit / delete / favorites).
/// TODO(integration): persist in the app database.
class ConnectionsEditor extends Notifier<List<ConnectionConfig>> {
  @override
  List<ConnectionConfig> build() => ref.read(connectionsProvider);

  void upsert(ConnectionConfig c) {
    final i = state.indexWhere((e) => e.id == c.id);
    state = i < 0
        ? [...state, c]
        : [for (final e in state) e.id == c.id ? c : e];
  }

  void remove(ConnectionId id) => state = [
    for (final e in state)
      if (e.id != id) e,
  ];

  void toggleFavorite(ConnectionId id, String path) {
    final c = state.firstWhere((e) => e.id == id);
    final favs = c.favorites.contains(path)
        ? [
            for (final f in c.favorites)
              if (f != path) f,
          ]
        : [...c.favorites, path];
    upsert(
      ConnectionConfig(
        id: c.id,
        name: c.name,
        type: c.type,
        endpoint: c.endpoint,
        username: c.username,
        libraryRoot: c.libraryRoot,
        favorites: favs,
      ),
    );
  }
}

final connectionsEditorProvider =
    NotifierProvider<ConnectionsEditor, List<ConnectionConfig>>(
      ConnectionsEditor.new,
    );

/// Passwords live in memory only.
/// TODO(integration): move to flutter_secure_storage.
final connectionPasswordsProvider =
    NotifierProvider<Val<Map<ConnectionId, String>>, Map<ConnectionId, String>>(
      () => Val(const {}),
    );

enum ConnStatus { connected, authFailed, offline }

/// TODO(integration): build the backend from the connection's own config.
/// For now every connection pings the shared demo backend.
final connectionStatusProvider =
    FutureProvider.family<ConnStatus, ConnectionId>((ref, id) async {
      try {
        await ref.watch(demoBackendProvider).ping();
        return ConnStatus.connected;
      } on StorageException catch (e) {
        return e.code == StorageErrorCode.unauthorized
            ? ConnStatus.authFailed
            : ConnStatus.offline;
      } catch (_) {
        return ConnStatus.offline;
      }
    });

// ---- file browser state ----

enum BrowserSort { name, time, size }

/// The connection whose browser is open; null shows the connection list.
final openConnectionProvider =
    NotifierProvider<Val<ConnectionConfig?>, ConnectionConfig?>(
      () => Val(null),
    );
final browserDirProvider = NotifierProvider<Val<String>, String>(
  () => Val('/'),
);
final browserSearchProvider = NotifierProvider<Val<String>, String>(
  () => Val(''),
);
final browserSortProvider = NotifierProvider<Val<BrowserSort>, BrowserSort>(
  () => Val(BrowserSort.name),
);
final onlyUnorganizedProvider = NotifierProvider<Val<bool>, bool>(
  () => Val(false),
);
final selectModeProvider = NotifierProvider<Val<bool>, bool>(() => Val(false));

class BrowserSelection extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};

  void toggle(String path) => state = state.contains(path)
      ? ({...state}..remove(path))
      : {...state, path};

  void setAll(Iterable<String> paths) => state = {...paths};

  void clear() => state = {};
}

final browserSelectionProvider =
    NotifierProvider<BrowserSelection, Set<String>>(BrowserSelection.new);

class _ModeNotifier extends Notifier<OrganizeMode> {
  @override
  OrganizeMode build() => ref.read(settingsProvider).defaultMode;

  void set(OrganizeMode m) => state = m;
}

final browserModeProvider = NotifierProvider<_ModeNotifier, OrganizeMode>(
  _ModeNotifier.new,
);

/// Hook for the 只看未整理的 filter. TODO(integration): call
/// `HistoryStore.isOrganized(connection, path)` (and the "name already matches
/// the naming rules" check). Until then nothing counts as organized.
final isOrganizedProvider = Provider<Future<bool> Function(String path)>(
  (ref) =>
      (path) async => false,
);

/// Entries of the current folder after search / filter / sort.
final browserEntriesProvider = FutureProvider.autoDispose<List<RemoteEntry>>((
  ref,
) async {
  final dir = ref.watch(browserDirProvider);
  final q = ref.watch(browserSearchProvider).trim().toLowerCase();
  final sort = ref.watch(browserSortProvider);
  final onlyNew = ref.watch(onlyUnorganizedProvider);
  var list = await ref.watch(demoBackendProvider).list(dir);
  if (q.isNotEmpty) {
    list = list.where((e) => e.name.toLowerCase().contains(q)).toList();
  }
  if (onlyNew) {
    final isOrganized = ref.read(isOrganizedProvider);
    final keep = <RemoteEntry>[];
    for (final e in list) {
      if (!await isOrganized(e.path)) keep.add(e);
    }
    list = keep;
  }
  int cmp(RemoteEntry a, RemoteEntry b) => switch (sort) {
    BrowserSort.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    BrowserSort.time => (b.modified ?? DateTime(0)).compareTo(
      a.modified ?? DateTime(0),
    ),
    BrowserSort.size => b.size.compareTo(a.size),
  };
  return list..sort((a, b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    return cmp(a, b);
  });
});
