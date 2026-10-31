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

  testWidgets('settings fields bind to the settings provider', (tester) async {
    final (_, c) = await pumpPage(tester, const SettingsPage());
    await tester.enterText(
      find.widgetWithText(TextField, 'API Key / Read Token'),
      'abc123',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Base URL（代理地址）'),
      'https://tmdb.example.com/3',
    );
    await tester.tap(find.text('移动到媒体库'));
    await tester.tap(find.byType(Switch));
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    final s = c.read(settingsProvider);
    expect(s.tmdbApiKey, 'abc123');
    expect(s.tmdbBaseUrl, 'https://tmdb.example.com/3');
    expect(s.defaultMode, OrganizeMode.moveToLibrary);
    expect(s.autoDeleteJunk, isTrue);
    expect(c.read(themeModeProvider), ThemeMode.dark);

    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.textContaining('连接成功：找到「盗梦空间」'), findsOneWidget);
    expect(find.textContaining('基于 mnamer (MIT)'), findsOneWidget);
  });
}
