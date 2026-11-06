// Renders key screens to PNG for design review. Skipped unless SHOTS_DIR is set:
//   SHOTS_DIR=/tmp/shots FONTS_DIR=/path/to/fonts flutter test test/screenshots_test.dart
// FONTS_DIR should hold NotoSansSC-{Regular,Medium,Bold}.otf and
// NotoSerifSC-{Regular,SemiBold}.otf (tests otherwise draw every glyph as a box).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel/app.dart';
import 'package:tidyreel/shell/sidebar.dart';
import 'package:tidyreel/data/providers.dart';
import 'package:tidyreel/data/settings.dart';
import 'package:tidyreel/features/map/map_providers.dart';
import 'package:tidyreel/features/sources/sources_providers.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'features/map/fake_library.dart';

final _out = Platform.environment['SHOTS_DIR'];
final _fonts = Platform.environment['FONTS_DIR'];

Future<void> _load(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    final file = File(f);
    if (!file.existsSync()) continue;
    loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  }
  await loader.load();
}

Future<void> _loadFonts() async {
  final sans = [
    for (final w in ['Regular', 'Medium', 'Bold']) '$_fonts/NotoSansSC-$w.otf',
  ];
  for (final family in [
    'Roboto',
    '.AppleSystemUIFont',
    'CupertinoSystemText',
    'CupertinoSystemDisplay',
    'PingFang SC',
    'FlutterTest', // test-only default; otherwise unresolved text draws boxes
  ]) {
    await _load(family, sans);
  }
  await _load('Georgia', [
    '/usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf',
    '/usr/share/fonts/truetype/liberation/LiberationSerif-Bold.ttf',
  ]);
  await _load('Songti SC', [
    for (final w in ['Regular', 'SemiBold']) '$_fonts/NotoSerifSC-$w.otf',
  ]);
  await _load('Menlo', ['/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf']);
  final pubCache =
      Platform.environment['PUB_CACHE'] ??
      '${Platform.environment['HOME']}/.pub-cache';
  final cupertino = Directory('$pubCache/hosted/pub.dev')
      .listSync()
      .whereType<Directory>()
      .where((d) => d.path.contains('cupertino_icons-'))
      .map((d) => '${d.path}/assets/CupertinoIcons.ttf')
      .toList();
  await _load('packages/cupertino_icons/CupertinoIcons', cupertino);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter';
  await _load('MaterialIcons', [
    '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]);
}

Future<void> _shot(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('shot-root')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$_out/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<ProviderContainer> _pumpApp(
  WidgetTester tester, {
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('shot-root'),
      child: ProviderScope(overrides: overrides, child: const TidyreelApp()),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(AppShell)));
}

Future<void> _settleTasks(WidgetTester tester) async {
  for (var i = 0; i < 50; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(() async {
    if (_out != null) await _loadFonts();
  });
  testWidgets('screens', skip: _out == null, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final c = await _pumpApp(tester);
    final taskId = await tester.runAsync(
      () => c.read(taskManagerProvider).submit(
        const ConnectionId('demo-alist'),
        ['/下载/完成'],
        OrganizeMode.inPlace,
      ),
    );
    await _settleTasks(tester);
    await _shot(tester, '01-sources');

    await tester.tap(find.byKey(const ValueKey('fav demo-alist /下载/完成')));
    await tester.pumpAndSettle();
    await _shot(tester, '02-browser');

    await tester.tap(find.byKey(const ValueKey('check 异兽魔都 2020 1080p')));
    await tester.tap(
      find.byKey(const ValueKey('check Inception.2010.2160p.BluRay.x265.mkv')),
    );
    await _shot(tester, '03-browser-select');

    await tester.tap(find.byKey(const ValueKey('nav-来源')));
    await tester.pumpAndSettle();
    c.read(connectionPasswordsProvider.notifier).set({
      const ConnectionId('demo-alist'): 'password123',
    });
    await tester.tap(find.byTooltip('更多').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await _shot(tester, '04-connection-edit');
    await tester.tap(find.byKey(const ValueKey('dav-template')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('template-alistDav')).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试连接'));
    await _shot(tester, '05-connection-webdav');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    c
        .read(settingsProvider.notifier)
        .update((s) => s.copyWith(themeMode: ThemeMode.dark));
    await _shot(tester, '06-sources-dark');

    c
        .read(settingsProvider.notifier)
        .update((s) => s.copyWith(themeMode: ThemeMode.light));
    await tester.tap(find.byKey(const ValueKey('nav-任务')));
    await _shot(tester, '07-tasks');
    await tester.tap(find.byKey(const ValueKey('nav-设置')));
    await _shot(tester, '08-settings');
    await tester.tap(find.byKey(const ValueKey('nav-命名规则')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('剧集'));
    await _shot(tester, '11-naming-tv');

    final router = GoRouter.of(tester.element(find.byType(Sidebar)));
    router.go('/tasks/${taskId!.value}/review');
    await _settleTasks(tester);
    await _shot(tester, '09-review');
    await tester.tap(find.text('异兽魔都').first);
    await _settleTasks(tester);
    await _shot(tester, '10-review-show');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('map screens', skip: _out == null, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final c = await _pumpApp(
      tester,
      overrides: [
        demoBackendProvider.overrideWithValue(
          MemoryStorageBackend(fakeLibrary),
        ),
        mapOrganizedOfProvider.overrideWith(
          (ref, id) =>
              (paths) async => paths.where(fakeOrganized.contains).toSet(),
        ),
      ],
    );
    // The app's router is global: the first test left it on a review page.
    GoRouter.of(tester.element(find.byType(Sidebar))).go('/sources');
    await tester.pumpAndSettle();
    final conn = c
        .read(connectionsProvider)
        .firstWhere((e) => e.id == const ConnectionId('demo-alist'));
    c.read(openConnectionProvider.notifier).set(conn);
    c.read(browserDirProvider.notifier).set(root);
    c.read(browserMapModeProvider.notifier).set(true);
    await _settleTasks(tester);
    await _shot(tester, '12-map');
    c.read(browserDirProvider.notifier).set('$root/动漫');
    await _settleTasks(tester);
    await _shot(tester, '13-map-anime');
    c.read(browserDirProvider.notifier).set('$root/字幕包');
    await _settleTasks(tester);
    await _shot(tester, '15-map-crowded');
    c.read(sidebarCollapsedProvider.notifier).set(true);
    await _settleTasks(tester);
    await _shot(tester, '16-sidebar-collapsed');
    c.read(sidebarCollapsedProvider.notifier).set(false);
    c.read(browserDirProvider.notifier).set(root);
    c
        .read(settingsProvider.notifier)
        .update((s) => s.copyWith(themeMode: ThemeMode.dark));
    await _settleTasks(tester);
    await _shot(tester, '14-map-dark');
    debugDefaultTargetPlatformOverride = null;
  });
}
