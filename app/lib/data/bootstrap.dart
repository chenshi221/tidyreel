import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'database.dart';
import 'tmdb_cache.dart';

/// Everything opened before `runApp`: database, non-secret settings (JSON file)
/// and secrets (secrets.json). [Bootstrap.demo] is fully in-memory, used by tests and
/// when the real stores can't be opened.
class Bootstrap {
  final AppDatabase db;
  final JsonStore prefs;
  final SecretStore secrets;

  /// TMDB replies kept across runs; null in demo mode.
  final FileTmdbCache? tmdbCache;

  /// Demo mode: memory backend with sample files and fake TMDB.
  final bool demo;

  Bootstrap._(
    this.db,
    this.prefs,
    this.secrets, {
    required this.demo,
    this.tmdbCache,
  });

  static Future<Bootstrap> open() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return Bootstrap._(
      await AppDatabase.openDefault(),
      JsonStore.load(File('${dir.path}${Platform.pathSeparator}prefs.json')),
      await SecretStore.open(
        File('${dir.path}${Platform.pathSeparator}secrets.json'),
      ),
      demo: false,
      tmdbCache: FileTmdbCache.load(
        File('${dir.path}${Platform.pathSeparator}tmdb_cache.json'),
      ),
    );
  }

  factory Bootstrap.demo() => Bootstrap._(
    AppDatabase(NativeDatabase.memory()),
    JsonStore.memory(),
    SecretStore.memory(),
    demo: true,
  );
}

/// Small JSON document; each [write] rewrites the file (it's a few KB at most).
class JsonStore {
  final File? _file;
  final Map<String, Object?> _data;

  JsonStore._(this._file, this._data);

  factory JsonStore.memory() => JsonStore._(null, {});

  factory JsonStore.load(File file) {
    try {
      return JsonStore._(
        file,
        file.existsSync()
            ? Map<String, Object?>.of(
                jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
              )
            : {},
      );
    } on Object {
      // A corrupt prefs file must not brick the app; keep it aside for inspection.
      try {
        if (file.existsSync()) file.renameSync('${file.path}.broken');
      } on Object {
        // Ignore rename failure if locked or missing.
      }
      return JsonStore._(file, {});
    }
  }

  Object? read(String key) => _data[key];

  void write(String key, Object? value) {
    _data[key] = value;
    _file?.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_data));
  }
}

/// Passwords and API keys, in secrets.json inside the app's own (sandboxed)
/// support directory. Not the keychain: unsigned builds get a new code
/// signature on every build/update and lose access to their keychain items.
/// shortcut: plain JSON readable by this macOS user; move back to the keychain
/// once releases are signed with a stable Developer ID.
class SecretStore {
  final JsonStore _store;

  SecretStore._(this._store);

  factory SecretStore.memory() => SecretStore._(JsonStore.memory());

  static Future<SecretStore> open(File file) async {
    final fresh = !file.existsSync();
    final s = SecretStore._(JsonStore.load(file));
    if (fresh) {
      // One-time import of what earlier versions kept in the keychain.
      try {
        final old = await const FlutterSecureStorage().readAll();
        old.forEach(s._store.write);
      } catch (_) {}
    }
    if (!file.existsSync()) file.writeAsStringSync('{}');
    if (!Platform.isWindows) {
      try {
        Process.runSync('chmod', ['600', file.path]);
      } catch (_) {}
    }
    return s;
  }

  String? read(String key) => _store.read(key) as String?;

  Future<void> write(String key, String? value) async =>
      _store.write(key, value == null || value.isEmpty ? null : value);
}
