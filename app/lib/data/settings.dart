import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../l10n/l10n.dart';
import 'bootstrap.dart';
import 'providers.dart';

/// App-level settings. [tmdbApiKey] lives in secrets.json, the rest in prefs.json.
class AppSettings {
  final String tmdbApiKey;
  final String tmdbBaseUrl;
  final OrganizeMode defaultMode;
  final bool autoDeleteJunk;
  final ThemeMode themeMode;

  /// UI display language; defaults to [AppLanguage.system] (OS locale).
  final AppLanguage appLanguage;

  /// Ops in flight while executing; takes effect immediately for new runs.
  final int concurrency;

  /// Storage request starts per second (Alist rate limit); takes effect immediately.
  final int requestsPerSecond;

  /// Quick scan + warnings before a task is submitted.
  final bool scanPreview;

  /// TMDB `language` for titles and overviews (zh-CN / zh-TW / en-US).
  final String tmdbLanguage;

  /// Match score 立即执行 needs to touch a work.
  final double confidenceThreshold;

  /// What scans usually contain; 混合 decides per folder.
  final MediaHint mediaHint;

  /// Probe MKV/MP4 container headers on demand when filenames miss quality/HDR.
  final bool probeMedia;

  /// Allow scraping to replace existing `.nfo` files instead of skipping them.
  final bool overwriteNfo;

  /// Use Bangumi (bgm.tv) alongside AniList for anime Chinese/Japanese aliases.
  final bool enableBangumi;

  /// Persisted pane widths on ReviewPage.
  final double reviewLeftWidth;
  final double reviewRightWidth;

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
    this.appLanguage = AppLanguage.system,
    this.concurrency = 4,
    this.requestsPerSecond = 5,
    this.scanPreview = true,
    this.tmdbLanguage = 'zh-CN',
    this.confidenceThreshold = 0.7,
    this.mediaHint = MediaHint.mixed,
    this.probeMedia = true,
    this.overwriteNfo = false,
    this.enableBangumi = true,
    this.reviewLeftWidth = 312.0,
    this.reviewRightWidth = 276.0,
    this.accent = AccentChoice.rouge,
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
    AppLanguage? appLanguage,
    int? concurrency,
    int? requestsPerSecond,
    bool? scanPreview,
    String? tmdbLanguage,
    double? confidenceThreshold,
    MediaHint? mediaHint,
    bool? probeMedia,
    bool? overwriteNfo,
    bool? enableBangumi,
    double? reviewLeftWidth,
    double? reviewRightWidth,
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
    appLanguage: appLanguage ?? this.appLanguage,
    concurrency: concurrency ?? this.concurrency,
    requestsPerSecond: requestsPerSecond ?? this.requestsPerSecond,
    scanPreview: scanPreview ?? this.scanPreview,
    tmdbLanguage: tmdbLanguage ?? this.tmdbLanguage,
    confidenceThreshold: confidenceThreshold ?? this.confidenceThreshold,
    mediaHint: mediaHint ?? this.mediaHint,
    probeMedia: probeMedia ?? this.probeMedia,
    overwriteNfo: overwriteNfo ?? this.overwriteNfo,
    enableBangumi: enableBangumi ?? this.enableBangumi,
    reviewLeftWidth: reviewLeftWidth ?? this.reviewLeftWidth,
    reviewRightWidth: reviewRightWidth ?? this.reviewRightWidth,
    accent: accent ?? this.accent,
    sidebarCollapsed: sidebarCollapsed ?? this.sidebarCollapsed,
    reduceMotion: reduceMotion ?? this.reduceMotion,
    notifyRecognized: notifyRecognized ?? this.notifyRecognized,
    notifyFinished: notifyFinished ?? this.notifyFinished,
  );
}

/// Labels for [MediaHint], in menu order (Chinese fallback).
const mediaHintLabels = {
  MediaHint.mixed: '混合',
  MediaHint.anime: '动漫',
  MediaHint.tv: '电视剧',
  MediaHint.movie: '电影',
};

/// Accent colour: (light, dark).
/// 中国传统色; older saved names fall back to the default.
enum AccentChoice {
  rouge('胭脂', 'Rouge', Color(0xFF9D2933), Color(0xFFD0646C)),
  indigo('黛蓝', 'Indigo', Color(0xFF425066), Color(0xFF8E9DB8)),
  azurite('石青', 'Azurite', Color(0xFF2E6F78), Color(0xFF6FB1B9)),
  bamboo('竹青', 'Bamboo', Color(0xFF4F7D5B), Color(0xFF8DBB98)),
  ink('墨', 'Ink', Color(0xFF221F1C), Color(0xFFE7E4DF));

  final String label;
  final String englishLabel;
  final Color light;
  final Color dark;

  const AccentChoice(this.label, this.englishLabel, this.light, this.dark);

  String localizedLabel(AppL10n l10n) => l10n.isEn ? englishLabel : label;
}

const _prefsKey = 'settings';
const _tmdbSecret = 'tmdb_api_key';

/// Reads the initial UI [Locale] before `runApp` (saved choice or OS locale).
Locale initialLocaleFromBootstrap(Bootstrap boot) {
  final j = (boot.prefs.read(_prefsKey) as Map?)?.cast<String, Object?>();
  final lang =
      AppLanguage.values
          .where((v) => v.name == j?['appLanguage'])
          .firstOrNull ??
      AppLanguage.system;
  return effectiveAppLocale(lang, boot.systemLocale);
}

class SettingsNotifier extends Notifier<AppSettings> {
  Bootstrap get _boot => ref.read(bootstrapProvider);

  @override
  AppSettings build() {
    const d = AppSettings();
    final j = (_boot.prefs.read(_prefsKey) as Map?)?.cast<String, Object?>();
    T pick<T extends Enum>(List<T> values, String key, T fallback) =>
        values.where((v) => v.name == j?[key]).firstOrNull ?? fallback;
    final defaultTmdbLang = defaultTmdbLanguageFor(_boot.systemLocale);
    return AppSettings(
      tmdbApiKey: _boot.secrets.read(_tmdbSecret) ?? '',
      tmdbBaseUrl: j?['tmdbBaseUrl'] as String? ?? d.tmdbBaseUrl,
      defaultMode: pick(OrganizeMode.values, 'defaultMode', d.defaultMode),
      autoDeleteJunk: j?['autoDeleteJunk'] as bool? ?? d.autoDeleteJunk,
      themeMode: pick(ThemeMode.values, 'themeMode', d.themeMode),
      appLanguage: pick(AppLanguage.values, 'appLanguage', d.appLanguage),
      concurrency: ((j?['concurrency'] as num?)?.toInt() ?? d.concurrency)
          .clamp(1, 8),
      requestsPerSecond:
          ((j?['requestsPerSecond'] as num?)?.toInt() ?? d.requestsPerSecond)
              .clamp(1, 20),
      scanPreview: j?['scanPreview'] as bool? ?? d.scanPreview,
      tmdbLanguage: j?['tmdbLanguage'] as String? ?? defaultTmdbLang,
      confidenceThreshold:
          (j?['confidenceThreshold'] as num?)?.toDouble() ??
          d.confidenceThreshold,
      mediaHint: pick(MediaHint.values, 'mediaHint', d.mediaHint),
      probeMedia: j?['probeMedia'] as bool? ?? d.probeMedia,
      overwriteNfo: j?['overwriteNfo'] as bool? ?? d.overwriteNfo,
      enableBangumi: j?['enableBangumi'] as bool? ?? d.enableBangumi,
      reviewLeftWidth:
          ((j?['reviewLeftWidth'] as num?)?.toDouble() ?? d.reviewLeftWidth)
              .clamp(240.0, 460.0),
      reviewRightWidth:
          ((j?['reviewRightWidth'] as num?)?.toDouble() ?? d.reviewRightWidth)
              .clamp(220.0, 420.0),
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
      'appLanguage': state.appLanguage.name,
      'concurrency': state.concurrency,
      'requestsPerSecond': state.requestsPerSecond,
      'scanPreview': state.scanPreview,
      'tmdbLanguage': state.tmdbLanguage,
      'confidenceThreshold': state.confidenceThreshold,
      'mediaHint': state.mediaHint.name,
      'probeMedia': state.probeMedia,
      'overwriteNfo': state.overwriteNfo,
      'enableBangumi': state.enableBangumi,
      'reviewLeftWidth': state.reviewLeftWidth,
      'reviewRightWidth': state.reviewRightWidth,
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

final resolvedLocaleProvider = Provider<Locale>((ref) {
  final choice = ref.watch(settingsProvider.select((s) => s.appLanguage));
  final systemLocale = ref.watch(
    bootstrapProvider.select((b) => b.systemLocale),
  );
  return effectiveAppLocale(choice, systemLocale);
});

final appL10nProvider = Provider<AppL10n>(
  (ref) => AppL10n.forLocale(ref.watch(resolvedLocaleProvider)),
);
