import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'database.dart';

/// Everything opened before `runApp`: database, non-secret settings (JSON file)
/// and secrets (keychain). [Bootstrap.demo] is fully in-memory, used by tests and
/// when the real stores can't be opened.
class Bootstrap {
  final AppDatabase db;
  final JsonStore prefs;
  final SecretStore secrets;

  /// Demo mode: memory backend with sample files and fake TMDB.
  final bool demo;

  Bootstrap._(this.db, this.prefs, this.secrets, {required this.demo});

  static Future<Bootstrap> open() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return Bootstrap._(
      await AppDatabase.openDefault(),
      JsonStore.load(File('${dir.path}${Platform.pathSeparator}prefs.json')),
      await SecretStore.keychain(),
      demo: false,
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
            ? (jsonDecode(file.readAsStringSync()) as Map<String, Object?>)
            : {},
      );
    } on FormatException {
      // A corrupt prefs file must not brick the app; keep it aside for inspection.
      file.renameSync('${file.path}.broken');
      return JsonStore._(file, {});
    }
  }

  Object? read(String key) => _data[key];

  void write(String key, Object? value) {
    _data[key] = value;
    _file?.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_data));
  }
}

/// Passwords and API keys. Values are loaded once at startup so reads are sync.
class SecretStore {
  final FlutterSecureStorage? _storage;
  final Map<String, String> _cache;

  SecretStore._(this._storage, this._cache);

  factory SecretStore.memory() => SecretStore._(null, {});

  static Future<SecretStore> keychain() async {
    const storage = FlutterSecureStorage();
    return SecretStore._(storage, await storage.readAll());
  }

  String? read(String key) => _cache[key];

  Future<void> write(String key, String? value) async {
    if (value == null || value.isEmpty) {
      _cache.remove(key);
      await _storage?.delete(key: key);
    } else {
      _cache[key] = value;
      await _storage?.write(key: key, value: value);
    }
  }
}
