import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/l10n.dart';
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

  /// OS locale detected on startup (used for install-time language defaults).
  final Locale systemLocale;

  Bootstrap._(
    this.db,
    this.prefs,
    this.secrets, {
    required this.demo,
    required this.systemLocale,
    this.tmdbCache,
  });

  static Future<Bootstrap> open({Locale? systemLocale}) async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return Bootstrap._(
      await AppDatabase.openDefault(),
      JsonStore.load(File('${dir.path}${Platform.pathSeparator}prefs.json')),
      await SecretStore.open(
        File('${dir.path}${Platform.pathSeparator}secrets.json'),
      ),
      demo: false,
      systemLocale: systemLocale ?? detectSystemLocale(),
      tmdbCache: FileTmdbCache.load(
        File('${dir.path}${Platform.pathSeparator}tmdb_cache.json'),
      ),
    );
  }

  factory Bootstrap.demo({Locale systemLocale = const Locale('zh', 'CN')}) =>
      Bootstrap._(
        AppDatabase(NativeDatabase.memory()),
        JsonStore.memory(),
        SecretStore.memory(),
        demo: true,
        systemLocale: systemLocale,
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
    _flush();
  }

  void writeAll(Map<String, Object?> entries) {
    if (entries.isEmpty) return;
    _data.addAll(entries);
    _flush();
  }

  void _flush() {
    final file = _file;
    if (file == null) return;
    final encoded = const JsonEncoder.withIndent('  ').convert(_data);
    final tmp = File('${file.path}.tmp');
    try {
      tmp.writeAsStringSync(encoded, flush: true);
      tmp.renameSync(file.path);
    } on Object {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } on Object {
        // Ignore cleanup failure if locked or missing.
      }
      file.writeAsStringSync(encoded, flush: true);
    }
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
        s._store.writeAll(old);
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
