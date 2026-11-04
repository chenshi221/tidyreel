import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/data/providers.dart';
import 'package:tidyreel/features/naming/naming_page.dart';
import 'package:tidyreel/features/settings/settings_page.dart';
import 'package:tidyreel/features/settings/settings_providers.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'helpers.dart';

void main() {
  testWidgets('naming page: toggles update the profile, preview degrades', (
    tester,
  ) async {
    final (_, c) = await pumpPage(tester, const NamingPage());
    // Engine is a stub or real: either way the example card renders something.
    expect(find.byKey(const ValueKey('example-name')), findsOneWidget);
    expect(c.read(namingProfileProvider).movie.includeYear, isTrue);

    await tester.tap(find.byKey(const ValueKey('year-movie')));
    await tester.pumpAndSettle();
    expect(c.read(namingProfileProvider).movie.includeYear, isFalse);
    expect(c.read(namingProfileProvider).tv.includeYear, isTrue);

    await tester.tap(find.byKey(const ValueKey('extra-movie')));
    await tester.pumpAndSettle();
    expect(c.read(namingProfileProvider).movie.extraInfo, isTrue);

    // TV tab: episode style radio
    await tester.tap(find.text('剧集'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('style-cross')));
    await tester.pumpAndSettle();
    expect(c.read(namingProfileProvider).tv.episodeStyle, EpisodeStyle.cross);

    // advanced template editor makes the option controls read-only
    await tester.tap(find.byKey(const ValueKey('advanced-tv')));
    await tester.pumpAndSettle();
    expect(c.read(namingProfileProvider).tv.customTemplate, isNotNull);
    await tester.tap(
      find.byKey(const ValueKey('extra-tv')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(c.read(namingProfileProvider).tv.extraInfo, isFalse);
    await tester.enterText(
      find.byKey(const ValueKey('custom-tv')).last,
      '{title}',
    );
    await tester.pumpAndSettle();
    expect(c.read(namingProfileProvider).tv.customTemplate, '{title}');

    // switching player resets everything
    await tester.tap(find.byKey(const ValueKey('player')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Infuse').last);
    await tester.pumpAndSettle();
    final p = c.read(namingProfileProvider);
    expect(p.player, TargetPlayer.infuse);
    expect(p.movie.includeYear, isTrue);
    expect(p.tv.customTemplate, isNull);
  });

  testWidgets('season presets and regex rules reach the profile', (
    tester,
  ) async {
    final (_, c) = await pumpPage(tester, const NamingPage());
    await tester.tap(find.text('剧集'));
    await tester.pumpAndSettle();

    final list = find
        .ancestor(of: find.text('高级'), matching: find.byType(Scrollable))
        .first;
    final preset = find.byKey(const ValueKey('season-preset-S01'));
    await tester.scrollUntilVisible(preset, 200, scrollable: list);
    await tester.pumpAndSettle();
    await tester.tap(preset);
    await tester.pumpAndSettle();
    expect(
      c.read(namingProfileProvider).tv.seasonFolderTemplate,
      'S{season:02}',
    );

    final add = find.byKey(const ValueKey('add-rewrite'));
    await tester.scrollUntilVisible(
      add,
      200,
      scrollable: find
          .ancestor(of: preset, matching: find.byType(Scrollable))
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byKey(const ValueKey('rewrite-tv-0')),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.first, '(');
    await tester.pump();
    expect(find.textContaining('正则有误'), findsOneWidget);
    expect(c.read(namingProfileProvider).tv.rewrites.single.pattern, '');

    await tester.enterText(fields.first, r'S(\d+)');
    await tester.enterText(fields.last, r'第$1季');
    await tester.pumpAndSettle();
    expect(find.textContaining('正则有误'), findsNothing);
    final r = c.read(namingProfileProvider).tv.rewrites.single;
    expect(applyRewrites('S01', [r]), '第01季');
  });

  testWidgets('settings fields bind to the settings provider', (tester) async {
    final (_, c) = await pumpPage(tester, const SettingsPage());
    await tester.enterText(find.byKey(const ValueKey('tmdb-key')), 'abc123');
    await tester.enterText(
      find.byKey(const ValueKey('tmdb-url')),
      'https://tmdb.example.com/3',
    );
    // The page is a lazy list: scroll each control into view before tapping.
    Future<void> tap(Finder f) async {
      await tester.scrollUntilVisible(
        f,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    await tap(find.text('测试连接'));
    expect(find.textContaining('连接成功：找到「盗梦空间」'), findsOneWidget);

    await tap(find.text('移动到媒体库'));
    await tap(find.byKey(const ValueKey('auto-junk')));
    await tap(find.byKey(const ValueKey('scan-preview')));
    await tap(find.text('繁体'));
    await tap(find.text('严格'));
    await tap(find.text('深色'));
    await tap(find.byKey(const ValueKey('accent-blue')));
    await tap(find.byKey(const ValueKey('notify-finished')));
    final s = c.read(settingsProvider);
    expect(s.tmdbApiKey, 'abc123');
    expect(s.tmdbBaseUrl, 'https://tmdb.example.com/3');
    expect(s.defaultMode, OrganizeMode.moveToLibrary);
    expect(s.autoDeleteJunk, isTrue);
    expect(s.scanPreview, isFalse);
    expect(s.tmdbLanguage, 'zh-TW');
    expect(s.confidenceThreshold, 0.85);
    expect(s.accent, AccentChoice.blue);
    expect(s.notifyFinished, isFalse);
    expect(c.read(themeModeProvider), ThemeMode.dark);

    await tester.scrollUntilVisible(
      find.textContaining('基于 mnamer (MIT)'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('基于 mnamer (MIT)'), findsOneWidget);
  });
}
