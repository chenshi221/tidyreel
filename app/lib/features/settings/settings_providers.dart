import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

class AppSettings {
  /// TODO(integration): persist via flutter_secure_storage; memory only for now.
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

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => const AppSettings();

  void update(AppSettings Function(AppSettings) f) => state = f(state);
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

/// app.dart must pass this to `MaterialApp.router(themeMode: ...)`.
final themeModeProvider = Provider<ThemeMode>(
  (ref) => ref.watch(settingsProvider.select((s) => s.themeMode)),
);
