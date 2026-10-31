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

/// Status plus the backend's error text, so the card can say *why* it failed.
final connectionStatusProvider =
    FutureProvider.family<({ConnStatus status, String? detail}), ConnectionId>((
      ref,
      id,
    ) async {
      try {
        await ref.watch(backendForProvider)(id).ping();
        return (status: ConnStatus.connected, detail: null);
      } on StorageException catch (e) {
        if (e.code == StorageErrorCode.unauthorized) {
          return (
            status: ConnStatus.authFailed,
            detail: '用户名或密码错误（区分大小写）：${e.message}',
          );
        }
        final c = ref
            .watch(connectionsProvider)
            .where((c) => c.id == id)
            .firstOrNull;
        final noDav =
            c?.type == ConnectionType.webdav &&
            !c!.endpoint.replaceAll(RegExp(r'/+$'), '').endsWith('/dav');
        return (
          status: ConnStatus.offline,
          detail: noDav
              ? '${e.message}\n提示：Alist/OpenList 的 WebDAV 地址要以 /dav 结尾，或把类型改成 Alist'
              : e.message,
        );
      } catch (e) {
        return (status: ConnStatus.offline, detail: '$e');
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
  final q = ref.watch(browserSearchProvider).trim().toLowerCase();
  final sort = ref.watch(browserSortProvider);
  final onlyNew = ref.watch(onlyUnorganizedProvider);
  final conn = ref.watch(openConnectionProvider);
  if (conn == null) return const [];
  var list = await ref.watch(backendForProvider)(conn.id).list(dir);
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
