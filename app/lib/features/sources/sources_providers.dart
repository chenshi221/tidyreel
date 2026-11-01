import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../widgets/common.dart';
import '../settings/settings_providers.dart';

export '../../data/providers.dart'
    show connectionsProvider, connectionPasswordsProvider;

/// Single source of truth lives in the data layer (persisted).
final connectionsEditorProvider = connectionsProvider;

enum ConnStatus { connected, authFailed, offline }

typedef ConnCheck = ({ConnStatus status, String? detail});

/// Alist serves its web UI (not WebDAV) outside /dav, answering 404/405 there.
/// Only then is "use /dav" worth suggesting; other servers mount anywhere.
bool _looksLikeAlistWithoutDav(ConnectionConfig? c, StorageException e) {
  if (c?.type != ConnectionType.webdav) return false;
  final uri = Uri.tryParse(c!.endpoint);
  if (uri == null) return false;
  final path = uri.path.replaceAll(RegExp(r'/+$'), '');
  if (path.endsWith('/dav')) return false;
  // Network errors (no HTTP status) mean unreachable: /dav won't help.
  final status = RegExp(r'HTTP (\d+)').firstMatch(e.message)?.group(1);
  if (status == null) return false;
  return status == '405' || status == '404' || uri.port == 5244;
}

/// Turns a ping failure into a status plus a hint the user can act on.
ConnCheck describeConnectionError(ConnectionConfig? c, Object e) {
  if (e is StorageException) {
    if (e.code == StorageErrorCode.unauthorized) {
      return (
        status: ConnStatus.authFailed,
        detail: '用户名或密码错误（区分大小写）：${e.message}',
      );
    }
    return (
      status: ConnStatus.offline,
      detail: _looksLikeAlistWithoutDav(c, e)
          ? '${e.message}\n提示：这看起来是 Alist / OpenList，它的 WebDAV 路径是 /dav；也可以把类型改成 Alist'
          : e.message,
    );
  }
  return (status: ConnStatus.offline, detail: '$e');
}

/// Status plus the backend's error text, so the row can say *why* it failed.
/// `ref.invalidate(connectionStatusProvider(id))` re-checks.
final connectionStatusProvider = FutureProvider.family<ConnCheck, ConnectionId>(
  (ref, id) async {
    final c = ref
        .watch(connectionsProvider)
        .where((c) => c.id == id)
        .firstOrNull;
    final be = ref.watch(backendForProvider)(id);
    try {
      // Listing the start folder checks the login too, and leaves it cached so
      // opening the connection is instant.
      try {
        await be.list(normalizeDir(c?.startDir ?? '/'));
      } on StorageException catch (e) {
        if (e.code != StorageErrorCode.notFound) rethrow;
        await be.ping();
      }
      return (status: ConnStatus.connected, detail: null);
    } catch (e) {
      return describeConnectionError(c, e);
    }
  },
);

/// Pings an unsaved connection from the dialog (测试连接).
final connectionTesterProvider =
    Provider<Future<ConnCheck> Function(ConnectionConfig, String password)>((
      ref,
    ) {
      final demo = ref.watch(bootstrapProvider).demo;
      return (c, password) async {
        try {
          final backend = demo
              ? ref.read(demoBackendProvider)
              : createBackend(c, Credentials(password: password));
          await backend.ping();
          return (status: ConnStatus.connected, detail: null);
        } catch (e) {
          return describeConnectionError(c, e);
        }
      };
    });

typedef FolderLister = Future<List<RemoteEntry>> Function(
  ConnectionConfig config,
  String password,
  String dir,
);

/// Lists folders of an unsaved connection (the dialog's 浏览… pickers).
final connectionListerProvider = Provider<FolderLister>((ref) {
  final demo = ref.watch(bootstrapProvider).demo;
  return (c, password, dir) =>
      (demo
              ? ref.read(demoBackendProvider)
              : createBackend(c, Credentials(password: password)))
          .list(dir);
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

/// Bumped by the 刷新 button; the next listing bypasses server caches.
final browserRefreshProvider = NotifierProvider<Val<int>, int>(() => Val(0));
var _seenRefresh = 0;

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

/// 只看未整理的: a path counts as organized once a done op produced it.
/// shortcut: doesn't yet check "name already matches the naming rules"; add when
/// users report already-tidy folders showing up.
final isOrganizedProvider = Provider<Future<bool> Function(String path)>((ref) {
  final conn = ref.watch(openConnectionProvider);
  final history = ref.watch(historyProvider);
  return (path) async =>
      conn != null && await history.isOrganized(conn.id, path);
});

/// Entries of the current folder after search / filter / sort.
final browserEntriesProvider = FutureProvider.autoDispose<List<RemoteEntry>>((
  ref,
) async {
  final dir = ref.watch(browserDirProvider);
  final q = ref.watch(browserSearchProvider).trim();
  final sort = ref.watch(browserSortProvider);
  final onlyNew = ref.watch(onlyUnorganizedProvider);
  final conn = ref.watch(openConnectionProvider);
  final tick = ref.watch(browserRefreshProvider);
  final refresh = tick != _seenRefresh;
  _seenRefresh = tick;
  if (conn == null) return const [];
  var list = await ref
      .watch(backendForProvider)(conn.id)
      .list(dir, refresh: refresh);
  if (q.isNotEmpty) {
    list = list.where((e) => fuzzyMatch(q, e.name)).toList();
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
