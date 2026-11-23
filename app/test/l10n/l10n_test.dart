import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/app.dart';
import 'package:tidyreel/data/bootstrap.dart';
import 'package:tidyreel/data/providers.dart';
import 'package:tidyreel/data/settings.dart';
import 'package:tidyreel/features/review/review_logic.dart';
import 'package:tidyreel/features/settings/settings_page.dart';
import 'package:tidyreel/l10n/core_messages.dart';
import 'package:tidyreel/l10n/l10n.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

void main() {
  group('locale detection & defaults', () {
    test('parseLocaleTag handles POSIX, BCP-47, and empty inputs', () {
      expect(parseLocaleTag('en_US.UTF-8'), const Locale('en', 'US'));
      expect(
        parseLocaleTag('zh-Hans_CN'),
        const Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hans',
          countryCode: 'CN',
        ),
      );
      expect(parseLocaleTag('zh_TW.UTF-8'), const Locale('zh', 'TW'));
      expect(parseLocaleTag('ja_JP@euro'), const Locale('ja', 'JP'));
      expect(parseLocaleTag('C'), isNull);
      expect(parseLocaleTag('POSIX'), isNull);
      expect(parseLocaleTag(''), isNull);
      expect(parseLocaleTag(null), isNull);
    });

    test('resolveUiLocale maps Chinese to zh and all other locales to en', () {
      expect(resolveUiLocale(const Locale('zh')), const Locale('zh'));
      expect(resolveUiLocale(const Locale('zh', 'CN')), const Locale('zh'));
      expect(resolveUiLocale(const Locale('zh', 'TW')), const Locale('zh'));
      expect(
        resolveUiLocale(
          const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        ),
        const Locale('zh'),
      );
      expect(resolveUiLocale(const Locale('en', 'US')), const Locale('en'));
      expect(resolveUiLocale(const Locale('en', 'GB')), const Locale('en'));
      expect(resolveUiLocale(const Locale('ja', 'JP')), const Locale('en'));
      expect(resolveUiLocale(const Locale('de', 'DE')), const Locale('en'));
    });

    test('effectiveAppLocale respects explicit preference over OS locale', () {
      const enOs = Locale('en', 'US');
      const zhOs = Locale('zh', 'CN');
      expect(effectiveAppLocale(AppLanguage.system, enOs), const Locale('en'));
      expect(effectiveAppLocale(AppLanguage.system, zhOs), const Locale('zh'));
      expect(effectiveAppLocale(AppLanguage.zh, enOs), const Locale('zh'));
      expect(effectiveAppLocale(AppLanguage.en, zhOs), const Locale('en'));
    });

    test('defaultTmdbLanguageFor adapts to OS locale', () {
      expect(defaultTmdbLanguageFor(const Locale('zh', 'CN')), 'zh-CN');
      expect(defaultTmdbLanguageFor(const Locale('zh')), 'zh-CN');
      expect(defaultTmdbLanguageFor(const Locale('zh', 'TW')), 'zh-TW');
      expect(defaultTmdbLanguageFor(const Locale('zh', 'HK')), 'zh-TW');
      expect(
        defaultTmdbLanguageFor(
          const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        ),
        'zh-TW',
      );
      expect(defaultTmdbLanguageFor(const Locale('en', 'US')), 'en-US');
      expect(defaultTmdbLanguageFor(const Locale('fr', 'FR')), 'en-US');
    });

    test(
      'defaultNamingProfileFor and localizedPlayerPreset adapt to locale',
      () {
        final zh = defaultNamingProfileFor(const Locale('zh', 'CN'));
        expect(zh, NamingProfile.vidhub);
        expect(zh.movieDir, '电影');
        expect(zh.tvDir, '剧集');
        expect(zh.movie.titleLanguage, TitleLanguage.chineseFirst);
        expect(zh.movie.bilingual, isTrue);

        final en = defaultNamingProfileFor(const Locale('en', 'US'));
        expect(en.movieDir, 'Movies');
        expect(en.tvDir, 'TV Shows');
        expect(en.movie.titleLanguage, TitleLanguage.englishFirst);
        expect(en.movie.bilingual, isFalse);
        expect(en.tv.titleLanguage, TitleLanguage.englishFirst);
        expect(en.tv.bilingual, isFalse);

        final plexEn = localizedPlayerPreset(TargetPlayer.plex, isEn: true);
        expect(plexEn.player, TargetPlayer.plex);
        expect(plexEn.movieDir, 'Movies');
        expect(plexEn.tvDir, 'TV Shows');
        expect(plexEn.movie.titleLanguage, TitleLanguage.englishFirst);
        expect(plexEn.movie.bilingual, isFalse);

        expect(
          localizedPlayerPreset(TargetPlayer.plex, isEn: false),
          NamingProfile.forPlayer(TargetPlayer.plex),
        );
      },
    );

    test(
      'initialLocaleFromBootstrap respects saved preference or OS locale',
      () {
        final enFresh = Bootstrap.demo(systemLocale: const Locale('en', 'US'));
        addTearDown(enFresh.db.close);
        expect(initialLocaleFromBootstrap(enFresh), const Locale('en'));

        final zhFresh = Bootstrap.demo(systemLocale: const Locale('zh', 'CN'));
        addTearDown(zhFresh.db.close);
        expect(initialLocaleFromBootstrap(zhFresh), const Locale('zh'));

        enFresh.prefs.write('settings', {'appLanguage': 'zh'});
        expect(initialLocaleFromBootstrap(enFresh), const Locale('zh'));
      },
    );
  });

  group('core message and review helper localization', () {
    test(
      'localizeCoreMessage translates canonical core strings in English',
      () {
        expect(localizeCoreMessage(AppL10n.zh, '整理完成'), '整理完成');
        expect(
          localizeCoreMessage(AppL10n.en, '整理完成'),
          'Organization complete',
        );
        expect(
          localizeCoreMessage(AppL10n.en, '正在导入文件（已导入 12 个）'),
          'Importing files (12 imported)',
        );
        expect(
          localizeCoreMessage(AppL10n.en, '正在识别（共 1 个文件）'),
          'Matching (1 file)',
        );
        expect(
          localizeCoreMessage(AppL10n.en, '有 2 个文件会被命名为同一个路径'),
          '2 files would be renamed to the same path',
        );
        expect(
          localizeCoreMessage(AppL10n.en, '识别失败：连接超时'),
          'Matching failed: Connection timed out',
        );
        expect(
          localizeCoreMessage(AppL10n.en, '已撤销部分操作（2 项失败，1 项已跳过）'),
          'Partially undone (2 failed, 1 skipped)',
        );
        expect(
          localizeCoreMessage(AppL10n.en, '已扫描 3 个目录 · 1 个文件'),
          'Scanned 3 folders · 1 file',
        );
        expect(
          localizeCoreMessage(AppL10n.en, '服务器连接正常，但媒体库路径「/Movies」不存在'),
          'Server connected, but media library path "/Movies" does not exist',
        );
        expect(
          localizeCoreMessage(
            AppL10n.en,
            '本地为连续绝对集数（最大第 48 集），超出 TMDB 第 1 季（24 集），建议按 TMDB 季结构顺序拆多季',
          ),
          contains('splitting across TMDB seasons is recommended'),
        );
      },
    );

    test('review helpers format labels cleanly in English and Chinese', () {
      const comp = Completeness(2, 24, 2, 24);
      expect(comp.localizedLabel(isEn: false), '本地 2 季 24 集 / TMDB 2 季 24 集');
      expect(comp.localizedLabel(isEn: true), 'Local 2S 24E / TMDB 2S 24E');

      const file = ScanFile(
        path: '/BDMV',
        name: 'BDMV',
        size: 1000,
        role: FileRole.video,
        isDiscDir: true,
        parsed: ParsedName(
          kind: MediaKind.movie,
          confidence: 0.9,
          subFlags: ['bilingual'],
        ),
      );
      expect(fileTechBadges(file, isEn: false), containsAll(['原盘', '双语']));
      expect(
        fileTechBadges(file, isEn: true),
        containsAll(['Disc', 'Bilingual']),
      );

      const ignoredRow = ReviewRow(
        file,
        null,
        FileOverride(ignore: true),
        noSeason,
        false,
      );
      expect(ignoredRow.localizedNewLabel(isEn: false), '已忽略');
      expect(ignoredRow.localizedNewLabel(isEn: true), 'Ignored');
      expect(
        diffFilenameTokens('a.mkv', 'Ignored').single.kind,
        DiffTokenKind.unchanged,
      );
      expect(
        diffFilenameTokens('a.mkv', '(Unchanged)').single.kind,
        DiffTokenKind.unchanged,
      );
    });
  });

  group('auto-detection & live switching in TidyreelApp', () {
    testWidgets('launches in English on English OS and navigates all pages', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final boot = Bootstrap.demo(systemLocale: const Locale('en', 'US'));
      addTearDown(boot.db.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [bootstrapProvider.overrideWithValue(boot)],
          child: const TidyreelApp(),
        ),
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(AppShell)),
      );
      expect(container.read(settingsProvider).appLanguage, AppLanguage.system);
      expect(container.read(settingsProvider).tmdbLanguage, 'en-US');
      expect(container.read(namingProfileProvider).movieDir, 'Movies');
      expect(container.read(namingProfileProvider).tvDir, 'TV Shows');
      expect(
        container.read(namingProfileProvider).movie.titleLanguage,
        TitleLanguage.englishFirst,
      );
      expect(container.read(namingProfileProvider).movie.bilingual, isFalse);

      expect(
        tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data,
        'Sources',
      );

      final expectedTitles = <(String nav, String title)>[
        ('Tasks', 'Tasks'),
        ('Health', 'Health'),
        ('Naming', 'Naming Rules'),
        ('Settings', 'Settings'),
        ('Sources', 'Sources'),
      ];
      for (final (nav, title) in expectedTitles) {
        await tester.tap(find.byKey(ValueKey('nav-$nav')));
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data,
          title,
        );
        if (nav == 'Naming') {
          await tester.tap(find.text('TV Show'));
          await tester.pumpAndSettle();
        }
      }
    });

    testWidgets(
      'non-Chinese OS (ja_JP) defaults to English UI and en-US TMDB',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final boot = Bootstrap.demo(systemLocale: const Locale('ja', 'JP'));
        addTearDown(boot.db.close);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [bootstrapProvider.overrideWithValue(boot)],
            child: const TidyreelApp(),
          ),
        );
        await tester.pumpAndSettle();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(AppShell)),
        );
        expect(container.read(settingsProvider).tmdbLanguage, 'en-US');
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data,
          'Sources',
        );
      },
    );

    testWidgets(
      'Traditional Chinese OS (zh_TW) uses Chinese UI and zh-TW TMDB',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final boot = Bootstrap.demo(systemLocale: const Locale('zh', 'TW'));
        addTearDown(boot.db.close);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [bootstrapProvider.overrideWithValue(boot)],
            child: const TidyreelApp(),
          ),
        );
        await tester.pumpAndSettle();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(AppShell)),
        );
        expect(container.read(settingsProvider).tmdbLanguage, 'zh-TW');
        expect(container.read(namingProfileProvider).movieDir, '电影');
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data,
          '来源',
        );
      },
    );

    testWidgets('switching language in Settings updates UI live and persists', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final boot = Bootstrap.demo(systemLocale: const Locale('en', 'US'));
      addTearDown(boot.db.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [bootstrapProvider.overrideWithValue(boot)],
          child: const TidyreelApp(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('nav-Settings')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data,
        'Settings',
      );

      final langControl = find.byKey(const ValueKey('app-language'));
      final settingsScroll = find
          .descendant(
            of: find.byType(SettingsPage),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        langControl,
        300,
        scrollable: settingsScroll,
      );
      await tester.pumpAndSettle();

      // Switch to Simplified Chinese
      await tester.tap(
        find.descendant(of: langControl, matching: find.text('简体中文')),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data,
        '设置',
      );
      expect(find.byKey(const ValueKey('nav-来源')), findsOneWidget);
      final saved = (boot.prefs.read('settings') as Map)['appLanguage'];
      expect(saved, 'zh');

      // Switch back to System (English OS -> English UI)
      await tester.ensureVisible(langControl);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: langControl, matching: find.text('跟随系统')),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const ValueKey('page-title'))).data,
        'Settings',
      );
      expect(find.byKey(const ValueKey('nav-Sources')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('nav-Sources')));
      await tester.pumpAndSettle();
    });
  });
}
