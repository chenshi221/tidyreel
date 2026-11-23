import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'core_messages.dart';

/// User-facing UI language preference, persisted in `prefs.json`.
/// Defaults to [system] so a fresh install automatically matches the OS locale.
enum AppLanguage { system, zh, en }

/// Parses an OS locale string such as `zh_CN.UTF-8`, `zh-Hans_CN`, `en_US`.
Locale? parseLocaleTag(String? raw) {
  if (raw == null) return null;
  var cleaned = raw.trim();
  if (cleaned.isEmpty) return null;
  final dot = cleaned.indexOf('.');
  if (dot >= 0) cleaned = cleaned.substring(0, dot);
  final at = cleaned.indexOf('@');
  if (at >= 0) cleaned = cleaned.substring(0, at);
  final parts = cleaned
      .split(RegExp(r'[-_]'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return null;
  final lang = parts.first.toLowerCase();
  if (lang == 'c' || lang == 'posix') return null;
  String? script;
  String? country;
  for (final part in parts.skip(1)) {
    if (part.length == 4 && script == null) {
      script = '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}';
    } else if ((part.length == 2 || part.length == 3) && country == null) {
      country = part.toUpperCase();
    }
  }
  return Locale.fromSubtags(
    languageCode: lang,
    scriptCode: script,
    countryCode: country,
  );
}

/// Detects the current OS locale (preferred UI language first, falling back to
/// `Platform.localeName`, then English).
Locale detectSystemLocale() {
  final locales = PlatformDispatcher.instance.locales;
  if (locales.isNotEmpty) return locales.first;
  return parseLocaleTag(Platform.localeName) ?? const Locale('en', 'US');
}

/// Resolves the app UI locale (`zh` or `en`) from a raw system locale.
/// Chinese OS locales use Chinese; all other locales default to English.
Locale resolveUiLocale(Locale rawSystemLocale) =>
    rawSystemLocale.languageCode.toLowerCase() == 'zh'
    ? const Locale('zh')
    : const Locale('en');

/// Resolves the effective app UI locale given user preference [choice] and
/// detected [systemLocale].
Locale effectiveAppLocale(AppLanguage choice, Locale systemLocale) =>
    switch (choice) {
      AppLanguage.zh => const Locale('zh'),
      AppLanguage.en => const Locale('en'),
      AppLanguage.system => resolveUiLocale(systemLocale),
    };

/// Default TMDB metadata language for a fresh install based on OS locale.
String defaultTmdbLanguageFor(Locale rawSystemLocale) {
  if (rawSystemLocale.languageCode.toLowerCase() != 'zh') return 'en-US';
  final script = rawSystemLocale.scriptCode?.toLowerCase();
  final country = rawSystemLocale.countryCode?.toUpperCase();
  if (script == 'hant' ||
      country == 'TW' ||
      country == 'HK' ||
      country == 'MO') {
    return 'zh-TW';
  }
  return 'zh-CN';
}

/// Default naming profile for a fresh install based on OS locale.
NamingProfile defaultNamingProfileFor(Locale rawSystemLocale) {
  if (rawSystemLocale.languageCode.toLowerCase() == 'zh') {
    return NamingProfile.vidhub;
  }
  return const NamingProfile(
    player: TargetPlayer.vidhub,
    movie: NamingOptions(
      titleLanguage: TitleLanguage.englishFirst,
      bilingual: false,
    ),
    tv: NamingOptions(
      titleLanguage: TitleLanguage.englishFirst,
      bilingual: false,
    ),
    movieDir: 'Movies',
    tvDir: 'TV Shows',
  );
}

/// Player preset adapted to the current UI language when the user picks a
/// recommended preset in the Naming Rules page.
NamingProfile localizedPlayerPreset(TargetPlayer player, {required bool isEn}) {
  final base = NamingProfile.forPlayer(player);
  if (!isEn) return base;
  return base.copyWith(
    movie: base.movie.copyWith(
      titleLanguage: TitleLanguage.englishFirst,
      bilingual: false,
    ),
    tv: base.tv.copyWith(
      titleLanguage: TitleLanguage.englishFirst,
      bilingual: false,
    ),
    movieDir: base.movieDir == '电影' ? 'Movies' : base.movieDir,
    tvDir: base.tvDir == '剧集' ? 'TV Shows' : base.tvDir,
  );
}

/// Application localization helper exposed through Flutter's [Localizations].
class AppL10n {
  final Locale locale;

  const AppL10n(this.locale);

  static const zh = AppL10n(Locale('zh'));
  static const en = AppL10n(Locale('en'));

  static const supportedLocales = [Locale('zh'), Locale('en')];

  static const LocalizationsDelegate<AppL10n> delegate = _AppL10nDelegate();

  static const localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];

  static AppL10n forLocale(Locale locale) =>
      locale.languageCode.toLowerCase() == 'zh' ? zh : en;

  /// Returns the active [AppL10n], falling back to [zh] in bare widget tests
  /// that pump a `MaterialApp` without [localizationsDelegates].
  static AppL10n of(BuildContext context) =>
      Localizations.of<AppL10n>(context, AppL10n) ?? zh;

  bool get isEn => locale.languageCode.toLowerCase() != 'zh';

  String tr(String zh, String en) => isEn ? en : zh;

  /// English singular/plural formatter, e.g. `plural(1, 'file') -> '1 file'`.
  String plural(int count, String singular, [String? plural]) =>
      count == 1 ? '$count $singular' : '$count ${plural ?? '${singular}s'}';

  /// Translates runtime status/warning/error messages produced by `tidyreel_core`.
  String coreMessage(String message) => localizeCoreMessage(this, message);

  // ---- Shared brand & domain labels ---------------------------------------

  String get appTitle => isEn ? 'Tidyreel' : '理片 Tidyreel';

  String get rootDir => isEn ? 'Root' : '根目录';

  String get ok => isEn ? 'OK' : '确定';

  String get cancel => isEn ? 'Cancel' : '取消';

  String get close => isEn ? 'Close' : '关闭';

  String get delete => isEn ? 'Delete' : '删除';

  String get save => isEn ? 'Save' : '保存';

  String get more => isEn ? 'More' : '更多';

  String get undo => isEn ? 'Undo' : '撤销';

  String get retry => isEn ? 'Retry' : '重试';

  String get refresh => isEn ? 'Refresh' : '刷新';

  String get back => isEn ? 'Back' : '返回';

  String get clear => isEn ? 'Clear' : '清空';

  String get edit => isEn ? 'Edit' : '编辑';

  String get movie => isEn ? 'Movie' : '电影';

  String get tvShow => isEn ? 'TV Show' : '剧集';

  String get specials => isEn ? 'Specials' : '特别篇';

  String seasonTitle(int season) =>
      season == 0 ? specials : (isEn ? 'Season $season' : '第 $season 季');

  String mediaHintLabel(MediaHint h) => switch (h) {
    MediaHint.mixed => tr('混合', 'Mixed'),
    MediaHint.anime => tr('动漫', 'Anime'),
    MediaHint.tv => tr('电视剧', 'TV Shows'),
    MediaHint.movie => tr('电影', 'Movies'),
  };

  Map<MediaHint, String> get mediaHintOptions => {
    for (final h in MediaHint.values) h: mediaHintLabel(h),
  };

  String organizeModeLabel(OrganizeMode mode) => switch (mode) {
    OrganizeMode.inPlace => tr('原地整理', 'In-place'),
    OrganizeMode.moveToLibrary => tr('移动到媒体库', 'Move to library'),
  };

  String connectionTypeLabel(ConnectionType type) => switch (type) {
    ConnectionType.alist => 'Alist',
    ConnectionType.webdav => 'WebDAV',
    ConnectionType.smb => 'SMB',
    ConnectionType.local => tr('本地', 'Local'),
  };

  String stageLabel(TaskStage stage) => switch (stage) {
    TaskStage.importing => tr('导入中', 'Importing'),
    TaskStage.recognizing => tr('识别中', 'Matching'),
    TaskStage.awaitingReview => tr('待确认', 'Review'),
    TaskStage.renamingFiles => tr('重命名中', 'Renaming'),
    TaskStage.renamingFolders => tr('整理文件夹', 'Organizing'),
    TaskStage.done => tr('已完成', 'Done'),
    TaskStage.partiallyFailed => tr('部分失败', 'Partial'),
    TaskStage.cancelled => tr('已取消', 'Cancelled'),
    TaskStage.undone => tr('已撤销', 'Undone'),
    TaskStage.failed => tr('失败', 'Failed'),
  };

  String appLanguageLabel(AppLanguage lang) => switch (lang) {
    AppLanguage.system => tr('跟随系统', 'System'),
    AppLanguage.zh => '简体中文',
    AppLanguage.en => 'English',
  };
}

class _AppL10nDelegate extends LocalizationsDelegate<AppL10n> {
  const _AppL10nDelegate();

  @override
  bool isSupported(Locale locale) =>
      locale.languageCode == 'zh' || locale.languageCode == 'en';

  @override
  Future<AppL10n> load(Locale locale) =>
      SynchronousFuture<AppL10n>(AppL10n.forLocale(locale));

  @override
  bool shouldReload(_AppL10nDelegate old) => false;
}

extension AppL10nContext on BuildContext {
  AppL10n get l10n => AppL10n.of(this);

  String tr(String zh, String en) => l10n.tr(zh, en);

  String trCore(String msg) => l10n.coreMessage(msg);
}
