import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/providers.dart';
import '../../data/settings.dart';
import '../../widgets/common.dart';
import '../map/map_providers.dart';
import '../map/size_scanner.dart';

export '../../data/providers.dart'
    show
        connectionsProvider,
        connectionPasswordsProvider,
        connectionDirPasswordsProvider;

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
/// Selects only the target connection's endpoint/auth/startDir so starring or
/// editing other connections never re-pings this one.
final connectionStatusProvider = FutureProvider.family<ConnCheck, ConnectionId>(
  (ref, id) async {
    final watched = ref.watch(
      connectionsProvider.select((list) {
        final c = list.where((e) => e.id == id).firstOrNull;
        return c == null ? null : (c.type, c.endpoint, c.username, c.startDir);
      }),
    );
    ref.watch(connectionPasswordsProvider.select((m) => m[id]));
    final be = ref.watch(connectionBackendProvider(id));
    final c = ref
        .read(connectionsProvider)
        .where((e) => e.id == id)
        .firstOrNull;
    try {
      // Listing the start folder checks the login too, and leaves it cached so
      // opening the connection is instant.
      try {
        await be.list(normalizeDir(watched?.$4 ?? c?.startDir ?? '/'));
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

typedef ConnectionTester = Future<ConnCheck> Function(
  ConnectionConfig config,
  String password, {
  Map<String, String> dirPasswords,
});

/// Pings an unsaved connection from the dialog (测试连接), and verifies
/// non-root startDir and libraryRoot exist on the server.
final connectionTesterProvider = Provider<ConnectionTester>((ref) {
  final demo = ref.watch(bootstrapProvider).demo;
  return (c, password, {dirPasswords = const {}}) async {
    final backend = demo
        ? ref.read(demoBackendProvider)
        : createBackend(
            c,
            Credentials(password: password, dirPasswords: dirPasswords),
          );
    try {
      await backend.ping();
      final start = normalizeDir(c.startDir);
      if (start != '/' && !await backend.exists(start)) {
        return (status: ConnStatus.offline, detail: '服务器连接正常，但连接路径「$start」不存在');
      }
      final root = c.libraryRoot;
      if (root != null &&
          root.isNotEmpty &&
          !await backend.exists(normalizeDir(root))) {
        return (
          status: ConnStatus.offline,
          detail: '服务器连接正常，但媒体库路径「${normalizeDir(root)}」不存在',
        );
      }
      return (status: ConnStatus.connected, detail: null);
    } catch (e) {
      return describeConnectionError(c, e);
    } finally {
      if (!demo) await backend.close();
    }
  };
});

typedef FolderLister = Future<List<RemoteEntry>> Function(
  ConnectionConfig config,
  String password,
  String dir, {
  Map<String, String> dirPasswords,
});

/// A temporary backend session for the folder picker dialog, closed once the
/// dialog finishes so browsing multiple folders never leaks backends.
class FolderPickerSession {
  final Future<List<RemoteEntry>> Function(String dir) list;
  final Future<void> Function() close;

  const FolderPickerSession({required this.list, required this.close});
}

typedef FolderSessionOpener = FolderPickerSession Function(
  ConnectionConfig config,
  String password, {
  Map<String, String> dirPasswords,
});

/// Opens one cached backend session for a folder picker dialog.
final connectionListerSessionProvider = Provider<FolderSessionOpener>((ref) {
  final demo = ref.watch(bootstrapProvider).demo;
  return (c, password, {dirPasswords = const {}}) {
    if (demo) {
      final be = ref.read(demoBackendProvider);
      return FolderPickerSession(
        list: (dir) => be.list(dir),
        close: () async {},
      );
    }
    final be = CachedBackend(
      createBackend(
        c,
        Credentials(password: password, dirPasswords: dirPasswords),
      ),
    );
    return FolderPickerSession(list: (dir) => be.list(dir), close: be.close);
  };
});

/// Lists folders of an unsaved connection (one-shot helper; prefer
/// [connectionListerSessionProvider] for interactive pickers).
final connectionListerProvider = Provider<FolderLister>((ref) {
  final open = ref.watch(connectionListerSessionProvider);
  return (c, password, dir, {dirPasswords = const {}}) async {
    final session = open(c, password, dirPasswords: dirPasswords);
    try {
      return await session.list(dir);
    } finally {
      await session.close();
    }
  };
});

// ---- file browser state ----

enum BrowserSort { name, time, size }

/// Keeps the open connection in sync when the connection is edited or deleted
/// in [connectionsProvider], while still allowing tests to call `set(...)`.
class OpenConnectionNotifier extends Notifier<ConnectionConfig?> {
  @override
  ConnectionConfig? build() {
    ref.listen<List<ConnectionConfig>>(connectionsProvider, (_, next) {
      final cur = state;
      if (cur == null) return;
      final updated = next.where((e) => e.id == cur.id).firstOrNull;
      if (updated == null) {
        state = null;
      } else if (updated != cur) {
        state = updated;
      }
    });
    return null;
  }

  void set(ConnectionConfig? value) => state = value;
}

/// The connection whose browser is open; null shows the connection list.
final openConnectionProvider =
    NotifierProvider<OpenConnectionNotifier, ConnectionConfig?>(
      OpenConnectionNotifier.new,
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

class _RefreshTracker {
  int seen = 0;
}

final _refreshTrackerProvider = Provider<_RefreshTracker>(
  (ref) => _RefreshTracker(),
);

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

/// Raw directory listing for the open folder (only re-runs on dir/conn/refresh).
final rawBrowserEntriesProvider = FutureProvider.autoDispose<List<RemoteEntry>>(
  (ref) async {
    final dir = ref.watch(browserDirProvider);
    final connId = ref.watch(openConnectionProvider.select((c) => c?.id));
    final tick = ref.watch(browserRefreshProvider);
    final tracker = ref.watch(_refreshTrackerProvider);
    final refresh = tick != tracker.seen;
    tracker.seen = tick;
    if (connId == null) return const [];
    return ref
        .watch(connectionBackendProvider(connId))
        .list(dir, refresh: refresh);
  },
);

/// SQLite organized check for the current raw listing when 只看未整理的 is on.
final _browserOrganizedProvider = FutureProvider.autoDispose<Set<String>>((
  ref,
) async {
  final onlyNew = ref.watch(onlyUnorganizedProvider);
  if (!onlyNew) return const {};
  final connId = ref.watch(openConnectionProvider.select((c) => c?.id));
  if (connId == null) return const {};
  final raw = await ref.watch(rawBrowserEntriesProvider.future);
  if (raw.isEmpty) return const {};
  final history = ref.watch(historyProvider);
  return history.areOrganized(connId, raw.map((e) => e.path));
});

/// Entries of the current folder after synchronous search / filter / sort.
/// Typing in search or changing sort never re-queries SQLite or mutates the
/// cached listing.
final browserEntriesProvider =
    Provider.autoDispose<AsyncValue<List<RemoteEntry>>>((ref) {
      final rawAsync = ref.watch(rawBrowserEntriesProvider);
      final q = ref.watch(browserSearchProvider).trim();
      final sort = ref.watch(browserSortProvider);
      final onlyNew = ref.watch(onlyUnorganizedProvider);
      final connId = ref.watch(openConnectionProvider.select((c) => c?.id));
      final organizedAsync = onlyNew
          ? ref.watch(_browserOrganizedProvider)
          : const AsyncData(<String>{});
      final marks = onlyNew && connId != null
          ? ref.watch(organizedMarksProvider(connId))
          : const <String, bool>{};

      return rawAsync.whenData((raw) {
        var list = q.isEmpty
            ? [...raw]
            : raw.where((e) => fuzzyMatch(q, e.name)).toList();
        if (onlyNew) {
          final organized = organizedAsync.asData?.value ?? const <String>{};
          list = list
              .where(
                (e) =>
                    !(markFor(marks, e.path) ??
                        (organized.contains(e.path) || looksOrganized(e))),
              )
              .toList();
        }
        int cmp(RemoteEntry a, RemoteEntry b) => switch (sort) {
          BrowserSort.name => a.name.toLowerCase().compareTo(
            b.name.toLowerCase(),
          ),
          BrowserSort.time => (b.modified ?? DateTime(0)).compareTo(
            a.modified ?? DateTime(0),
          ),
          BrowserSort.size => b.size.compareTo(a.size),
        };
        list.sort((a, b) {
          if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
          return cmp(a, b);
        });
        return list;
      });
    });
