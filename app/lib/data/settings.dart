import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'bootstrap.dart';
import 'providers.dart';

/// App-level settings. [tmdbApiKey] lives in the keychain, the rest in prefs.json.
class AppSettings {
  final String tmdbApiKey;
  final String tmdbBaseUrl;
  final OrganizeMode defaultMode;
  final bool autoDeleteJunk;
  final ThemeMode themeMode;

  const AppSettings({
    this.tmdbApiKey = '',
    this.tmdbBaseUrl = 'https://api.themoviedb.org/3',
    this.defaultMode = OrganizeMode.inPlace,
    this.autoDeleteJunk = false,
    this.themeMode = ThemeMode.system,
  });

  AppSettings copyWith({
    String? tmdbApiKey,
    String? tmdbBaseUrl,
    OrganizeMode? defaultMode,
    bool? autoDeleteJunk,
    ThemeMode? themeMode,
  }) => AppSettings(
    tmdbApiKey: tmdbApiKey ?? this.tmdbApiKey,
    tmdbBaseUrl: tmdbBaseUrl ?? this.tmdbBaseUrl,
    defaultMode: defaultMode ?? this.defaultMode,
    autoDeleteJunk: autoDeleteJunk ?? this.autoDeleteJunk,
    themeMode: themeMode ?? this.themeMode,
  );
}

const _prefsKey = 'settings';
const _tmdbSecret = 'tmdb_api_key';

class SettingsNotifier extends Notifier<AppSettings> {
  Bootstrap get _boot => ref.read(bootstrapProvider);

  @override
  AppSettings build() {
    const d = AppSettings();
    final j = (_boot.prefs.read(_prefsKey) as Map?)?.cast<String, Object?>();
    T pick<T extends Enum>(List<T> values, String key, T fallback) =>
        values.where((v) => v.name == j?[key]).firstOrNull ?? fallback;
    return AppSettings(
      tmdbApiKey: _boot.secrets.read(_tmdbSecret) ?? '',
      tmdbBaseUrl: j?['tmdbBaseUrl'] as String? ?? d.tmdbBaseUrl,
      defaultMode: pick(OrganizeMode.values, 'defaultMode', d.defaultMode),
      autoDeleteJunk: j?['autoDeleteJunk'] as bool? ?? d.autoDeleteJunk,
      themeMode: pick(ThemeMode.values, 'themeMode', d.themeMode),
    );
  }

  void update(AppSettings Function(AppSettings) f) {
    final old = state;
    state = f(state);
    _boot.prefs.write(_prefsKey, {
      'tmdbBaseUrl': state.tmdbBaseUrl,
      'defaultMode': state.defaultMode.name,
      'autoDeleteJunk': state.autoDeleteJunk,
      'themeMode': state.themeMode.name,
    });
    if (old.tmdbApiKey != state.tmdbApiKey) {
      _boot.secrets.write(_tmdbSecret, state.tmdbApiKey.trim());
    }
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

final themeModeProvider = Provider<ThemeMode>(
  (ref) => ref.watch(settingsProvider.select((s) => s.themeMode)),
);
