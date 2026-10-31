import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

// Every engine dependency the UI uses goes through these providers.
// M0-M1: fakes. M2 integration swaps them for the real implementations here only.

final taskManagerProvider = Provider<TaskManager>((ref) {
  final tm = FakeTaskManager();
  ref.onDispose(tm.dispose);
  return tm;
});

final tasksProvider = StreamProvider<List<TaskSummary>>(
  (ref) => ref.watch(taskManagerProvider).watchAll(),
);

final metadataProvider = Provider<MetadataProvider>(
  (ref) => FakeMetadataProvider(),
);

final connectionsProvider = Provider<List<ConnectionConfig>>(
  (ref) => const [
    ConnectionConfig(
      id: ConnectionId('demo-alist'),
      name: '我的 Alist',
      type: ConnectionType.alist,
      endpoint: 'http://nas.local:5244',
      username: 'admin',
      libraryRoot: '/影视库',
      favorites: ['/下载/完成'],
    ),
    ConnectionConfig(
      id: ConnectionId('demo-local'),
      name: '本地下载',
      type: ConnectionType.local,
      endpoint: '/Users/me/Downloads',
    ),
  ],
);

/// Shared backend for demo connections, pre-filled with messy names.
final demoBackendProvider = Provider<StorageBackend>(
  (ref) => MemoryStorageBackend({
    '/下载/完成/异兽魔都 2020 1080p/[Sub] Dorohedoro S01E01 [1080p].mkv': 1 << 30,
    '/下载/完成/异兽魔都 2020 1080p/[Sub] Dorohedoro S01E02 [1080p].mkv': 1 << 30,
    '/下载/完成/Inception.2010.2160p.BluRay.x265.mkv': 20 << 30,
    '/下载/完成/更多资源请访问 www.example.com.txt': 120,
  }),
);

class NamingProfileNotifier extends Notifier<NamingProfile> {
  @override
  NamingProfile build() => NamingProfile.vidhub;

  void set(NamingProfile profile) => state = profile;
}

final namingProfileProvider =
    NotifierProvider<NamingProfileNotifier, NamingProfile>(
      NamingProfileNotifier.new,
    );
