import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'bootstrap.dart';
import 'providers.dart';

/// App-level settings. [tmdbApiKey] lives in secrets.json, the rest in prefs.json.
class AppSettings {
  final String tmdbApiKey;
  final String tmdbBaseUrl;
  final OrganizeMode defaultMode;
  final bool autoDeleteJunk;
  final ThemeMode themeMode;

  /// Ops in flight while executing; applies from the next app start.
  final int concurrency;

  /// Storage request starts per second (Alist rate limit); next app start.
  final int requestsPerSecond;
  final bool confirmBeforeExecute;

  /// Quick scan + warnings before a task is submitted.
  final bool scanPreview;

  /// TMDB `language` for titles and overviews (zh-CN / zh-TW / en-US).
  final String tmdbLanguage;

  /// Match score 立即执行 needs to touch a work.
  final double confidenceThreshold;
  final AccentChoice accent;
  final bool sidebarCollapsed;
  final bool reduceMotion;
  final bool notifyRecognized;
  final bool notifyFinished;

  const AppSettings({
    this.tmdbApiKey = '',
    this.tmdbBaseUrl = 'https://api.themoviedb.org/3',
    this.defaultMode = OrganizeMode.inPlace,
    this.autoDeleteJunk = false,
    this.themeMode = ThemeMode.light,
    this.concurrency = 4,
    this.requestsPerSecond = 5,
    this.confirmBeforeExecute = true,
    this.scanPreview = true,
    this.tmdbLanguage = 'zh-CN',
    this.confidenceThreshold = 0.7,
    this.accent = AccentChoice.terracotta,
    this.sidebarCollapsed = false,
    this.reduceMotion = false,
    this.notifyRecognized = true,
    this.notifyFinished = true,
  });

  AppSettings copyWith({
    String? tmdbApiKey,
    String? tmdbBaseUrl,
    OrganizeMode? defaultMode,
    bool? autoDeleteJunk,
    ThemeMode? themeMode,
    int? concurrency,
    int? requestsPerSecond,
    bool? confirmBeforeExecute,
    bool? scanPreview,
    String? tmdbLanguage,
    double? confidenceThreshold,
    AccentChoice? accent,
    bool? sidebarCollapsed,
    bool? reduceMotion,
    bool? notifyRecognized,
    bool? notifyFinished,
  }) => AppSettings(
    tmdbApiKey: tmdbApiKey ?? this.tmdbApiKey,
    tmdbBaseUrl: tmdbBaseUrl ?? this.tmdbBaseUrl,
    defaultMode: defaultMode ?? this.defaultMode,
    autoDeleteJunk: autoDeleteJunk ?? this.autoDeleteJunk,
    themeMode: themeMode ?? this.themeMode,
    concurrency: concurrency ?? this.concurrency,
    requestsPerSecond: requestsPerSecond ?? this.requestsPerSecond,
    confirmBeforeExecute: confirmBeforeExecute ?? this.confirmBeforeExecute,
    scanPreview: scanPreview ?? this.scanPreview,
    tmdbLanguage: tmdbLanguage ?? this.tmdbLanguage,
    confidenceThreshold: confidenceThreshold ?? this.confidenceThreshold,
    accent: accent ?? this.accent,
    sidebarCollapsed: sidebarCollapsed ?? this.sidebarCollapsed,
    reduceMotion: reduceMotion ?? this.reduceMotion,
    notifyRecognized: notifyRecognized ?? this.notifyRecognized,
    notifyFinished: notifyFinished ?? this.notifyFinished,
  );
}

/// Accent colour: (light, dark).
enum AccentChoice {
  terracotta('陶土橙', Color(0xFFC96442), Color(0xFFDB7A59)),
  blue('蓝', Color(0xFF3E7CB1), Color(0xFF5B9BD5)),
  green('绿', Color(0xFF3F8A55), Color(0xFF6BB07F)),
  purple('紫', Color(0xFF8B5FBF), Color(0xFFA889D6));

  final String label;
  final Color light;
  final Color dark;

  const AccentChoice(this.label, this.light, this.dark);
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
      concurrency: ((j?['concurrency'] as num?)?.toInt() ?? d.concurrency)
          .clamp(1, 8),
      requestsPerSecond:
          ((j?['requestsPerSecond'] as num?)?.toInt() ?? d.requestsPerSecond)
              .clamp(1, 20),
      confirmBeforeExecute:
          j?['confirmBeforeExecute'] as bool? ?? d.confirmBeforeExecute,
      scanPreview: j?['scanPreview'] as bool? ?? d.scanPreview,
      tmdbLanguage: j?['tmdbLanguage'] as String? ?? d.tmdbLanguage,
      confidenceThreshold:
          (j?['confidenceThreshold'] as num?)?.toDouble() ??
          d.confidenceThreshold,
      accent: pick(AccentChoice.values, 'accent', d.accent),
      sidebarCollapsed: j?['sidebarCollapsed'] as bool? ?? d.sidebarCollapsed,
      reduceMotion: j?['reduceMotion'] as bool? ?? d.reduceMotion,
      notifyRecognized: j?['notifyRecognized'] as bool? ?? d.notifyRecognized,
      notifyFinished: j?['notifyFinished'] as bool? ?? d.notifyFinished,
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
      'concurrency': state.concurrency,
      'requestsPerSecond': state.requestsPerSecond,
      'confirmBeforeExecute': state.confirmBeforeExecute,
      'scanPreview': state.scanPreview,
      'tmdbLanguage': state.tmdbLanguage,
      'confidenceThreshold': state.confidenceThreshold,
      'accent': state.accent.name,
      'sidebarCollapsed': state.sidebarCollapsed,
      'reduceMotion': state.reduceMotion,
      'notifyRecognized': state.notifyRecognized,
      'notifyFinished': state.notifyFinished,
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
