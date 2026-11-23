import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/data/providers.dart';
import 'package:tidyreel/features/map/map_providers.dart';
import 'package:tidyreel/features/map/organic_layout.dart';
import 'package:tidyreel/features/map/organic_map.dart';
import 'package:tidyreel/features/map/repo_map_view.dart';
import 'package:tidyreel/features/map/size_scanner.dart';
import 'package:tidyreel/features/sources/sources_page.dart';
import 'package:tidyreel/features/sources/sources_providers.dart';
import 'package:tidyreel/ui/widgets.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'fake_library.dart';

const _id = ConnectionId('demo-alist');

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  StorageBackend? backend,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final tm = FakeTaskManager(step: Duration.zero);
  addTearDown(tm.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        taskManagerProvider.overrideWithValue(tm),
        demoBackendProvider.overrideWithValue(
          backend ?? MemoryStorageBackend(fakeLibrary),
        ),
        mapOrganizedOfProvider.overrideWith(
          (ref, id) =>
              (paths) async => paths.where(fakeOrganized.contains).toSet(),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: SourcesPage())),
    ),
  );
  await tester.pumpAndSettle();
  final c = ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
  final conn = c.read(connectionsProvider).firstWhere((e) => e.id == _id);
  c.read(openConnectionProvider.notifier).set(conn);
  c.read(browserDirProvider.notifier).set(root);
  await tester.pumpAndSettle();
  return c;
}

/// Waits for any isolate-offloaded OrganicMap layout (> 24 blocks) to finish.
Future<void> _settleIsolateLayout(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 200 && debugPendingLayoutCount > 0; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// Where block [label] is drawn, by laying the map out the same way.
Offset _centerOf(WidgetTester tester, ProviderContainer c, String label) {
  final map = tester.widget<OrganicMap>(find.byType(OrganicMap));
  final box = tester.renderObject<RenderBox>(find.byType(OrganicMap));
  final items = mapItems(map.blocks, box.size);
  final cells = layoutOrganic(items, Offset.zero & mapCanvas(items, box.size));
  final id = map.blocks.firstWhere((b) => b.label == label).id;
  return box.localToGlobal(cells.firstWhere((x) => x.id == id).centroid);
}

void main() {
  testWidgets('a missing folder says so and stops spinning', (tester) async {
    await _pump(tester, backend: MemoryStorageBackend());
    await tester.tap(find.text('地图'));
    await tester.pumpAndSettle();
    expect(find.textContaining('找不到这个文件夹'), findsOneWidget);
    expect(find.byType(Spinner), findsNothing);
  });

  testWidgets('the sources page shows no map and counts nothing', (
    tester,
  ) async {
    final tm = FakeTaskManager(step: Duration.zero);
    addTearDown(tm.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [taskManagerProvider.overrideWithValue(tm)],
        child: const MaterialApp(home: Scaffold(body: SourcesPage())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RepoMapView), findsNothing);
    expect(find.byType(OrganicMap), findsNothing);
  });

  testWidgets('地图 counts the folder and clicking a block opens it', (
    tester,
  ) async {
    final c = await _pump(tester);
    expect(find.byType(RepoMapView), findsNothing);
    await tester.tap(find.text('地图'));
    await tester.pumpAndSettle();
    expect(find.byType(RepoMapView), findsOneWidget);
    expect(find.textContaining('个文件，未整理'), findsOneWidget);
    expect(find.text('TB'), findsOneWidget);
    // List-only controls step aside.
    expect(find.text('只看未整理的'), findsNothing);

    final labels = tester
        .widget<OrganicMap>(find.byType(OrganicMap))
        .blocks
        .map((b) => b.label);
    expect(labels, containsAll(['电影', '剧集', '下载', '动漫']));

    await tester.tapAt(_centerOf(tester, c, '动漫'));
    await tester.pumpAndSettle();
    expect(c.read(browserDirProvider), '$root/动漫');
    await tester.tap(find.byKey(const ValueKey('browser-up')));
    await tester.pumpAndSettle();
    expect(c.read(browserDirProvider), root);
    await tester.tapAt(_centerOf(tester, c, '动漫'));
    await tester.pumpAndSettle();
    final shows = tester.widget<OrganicMap>(find.byType(OrganicMap)).blocks;
    expect(shows.map((b) => b.label), contains('海贼王 (1999)'));

    // Right-click offers the same actions as the list.
    await tester.tapAt(
      _centerOf(tester, c, '海贼王 (1999)'),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('整理（原地）'), findsOneWidget);
    expect(find.text('复制路径'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await tester.tap(find.text('列表'));
    await tester.pumpAndSettle();
    expect(find.byType(RepoMapView), findsNothing);
    expect(find.text('海贼王 (1999)'), findsOneWidget);
  });

  testWidgets('⌘-click selects, plain click still opens', (tester) async {
    final c = await _pump(tester);
    await tester.tap(find.text('地图'));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.tapAt(_centerOf(tester, c, '动漫'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(c.read(browserSelectionProvider), {'$root/动漫'});
    expect(c.read(browserDirProvider), root);
    final map = tester.widget<OrganicMap>(find.byType(OrganicMap));
    expect(map.selected, {'$root/动漫'});

    await tester.tapAt(_centerOf(tester, c, '动漫'));
    await tester.pumpAndSettle();
    expect(c.read(browserDirProvider), '$root/动漫');
  });

  testWidgets('a crowded folder gets a bigger canvas, not a 其余 block', (
    tester,
  ) async {
    const viewport = Size(900, 450);
    final blocks = [
      const MapBlock(
        id: 'big',
        label: 'big',
        bytes: 1 << 40,
        state: BlockState.other,
      ),
      for (var i = 0; i < 100; i++)
        MapBlock(id: 'b$i', label: 'b$i', bytes: 1, state: BlockState.other),
    ];
    final items = mapItems(blocks, viewport);
    final canvas = mapCanvas(items, viewport);
    expect(canvas.width, greaterThan(viewport.width));
    expect(canvas.width / canvas.height, closeTo(2, 0.01));
    expect(items.last.value, minBlockArea);

    // Few blocks fit as they are.
    final few = blocks.take(3).toList();
    expect(mapCanvas(mapItems(few, viewport), viewport), viewport);
  });

  testWidgets('home and up stop at the connection path', (tester) async {
    final c = await _pump(tester);
    final conn = c.read(openConnectionProvider)!;
    c.read(openConnectionProvider.notifier).set(conn.copyWith(startDir: root));
    c.read(browserDirProvider.notifier).set('$root/动漫');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('browser-up')));
    await tester.pumpAndSettle();
    expect(c.read(browserDirProvider), root);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('browser-up')))
          .onPressed,
      isNull,
    );
    expect(find.text('根目录'), findsNothing);
  });

  testWidgets('dragging pans a crowded map and is not a click', (tester) async {
    tester.view.physicalSize = const Size(900, 450);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tapped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OrganicMap(
            blocks: [
              for (var i = 0; i < 250; i++)
                MapBlock(
                  id: 'b$i',
                  label: 'b$i',
                  bytes: 1,
                  state: BlockState.other,
                ),
            ],
            onTap: (b) => tapped.add(b.id),
          ),
        ),
      ),
    );
    await _settleIsolateLayout(tester);
    final viewer = tester.widget<InteractiveViewer>(
      find.byKey(const ValueKey('map-viewer')),
    );
    // A crowded map opens showing everything; zoom in to pan.
    expect(
      viewer.transformationController!.value.getMaxScaleOnAxis(),
      lessThan(1),
    );
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byKey(const ValueKey('map-zoom-in')));
    }
    await tester.pumpAndSettle();
    await tester.drag(find.byType(OrganicMap), const Offset(-200, -100));
    await tester.pumpAndSettle();
    final moved = viewer.transformationController!.value.getTranslation();
    expect(moved.x, lessThan(0));
    expect(moved.y, lessThan(0));
    expect(tapped, isEmpty);

    // A click after panning still lands on a block.
    // Zoomed in, a point may fall in a gap: try a few.
    for (final dx in <double>[400, 430, 460, 490, 520]) {
      if (tapped.isNotEmpty) break;
      await tester.tapAt(Offset(dx, 200));
    }
    expect(tapped, isNotEmpty);

    await tester.tap(find.byKey(const ValueKey('map-fit')));
    await tester.pumpAndSettle();
    expect(
      viewer.transformationController!.value.getMaxScaleOnAxis(),
      lessThan(1),
    );
  });

  testWidgets('zoom eases, and quick clicks build on each other', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OrganicMap(
            blocks: [
              for (var i = 0; i < 5; i++)
                MapBlock(
                  id: 'b$i',
                  label: 'b$i',
                  bytes: 1,
                  state: BlockState.other,
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final view = tester
        .widget<InteractiveViewer>(find.byKey(const ValueKey('map-viewer')))
        .transformationController!;
    final start = view.value.getMaxScaleOnAxis();
    await tester.tap(find.byKey(const ValueKey('map-zoom-in')));
    await tester.pump(); // the animation's first frame
    await tester.pump(const Duration(milliseconds: 60));
    final mid = view.value.getMaxScaleOnAxis();
    expect(mid, greaterThan(start));
    expect(mid, lessThan(start * 1.5));
    await tester.tap(find.byKey(const ValueKey('map-zoom-in')));
    await tester.pumpAndSettle();
    expect(view.value.getMaxScaleOnAxis(), closeTo(start * 2.25, 1e-6));
  });

  test('a pebble at the frame is clipped, then inset: whole and inside', () {
    const frame = Rect.fromLTWH(0, 0, 400, 300);
    final big = [
      const Offset(-100, -50),
      const Offset(250, -80),
      const Offset(300, 200),
      const Offset(-60, 260),
    ];
    final p = insetConvex(clipToRect(big, frame), 6);
    expect(p, isNotEmpty);
    for (final pt in p) {
      expect(frame.deflate(5.99).contains(pt), isTrue, reason: '$pt');
    }
    expect(clipToRect(big, const Rect.fromLTWH(500, 500, 10, 10)), isEmpty);
  });

  test('radial resampling keeps the shape and blends point by point', () {
    final square = [
      Offset.zero,
      const Offset(10, 0),
      const Offset(10, 10),
      const Offset(0, 10),
    ];
    final r = resampleRadial(square, 8);
    expect(r, hasLength(8));
    expect(r.first.dx, closeTo(10, 1e-9)); // angle 0 hits the right side
    expect(polygonArea(r), closeTo(100, 1e-6)); // corners are on the rays
    final moved = [for (final p in r) p + const Offset(20, 0)];
    expect(lerpPolygon(r, moved, 0.5).first.dx, closeTo(20, 1e-9));
  });

  testWidgets('big pebbles keep their names at every zoom', (tester) async {
    addTearDown(() => mapZoomStyle.value = MapZoomStyle.frame);
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Long names on big pebbles used to be laid out wider than the rounded
    // outline and then hidden.
    const sizes = [520, 410, 380, 300, 220, 160, 52, 35, 28, 20, 12, 6, 3];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OrganicMap(
            blocks: [
              for (final (i, gb) in sizes.indexed)
                MapBlock(
                  id: '/$i',
                  label: i.isEven
                      ? '[Nekomoe kissaten] Bocchi the Rock! [BDRip] $i'
                      : 'Fate/stay night Unlimited Blade Works $i',
                  bytes: gb * 1000000000,
                  state: BlockState.organized,
                  caption: '$gb GB',
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final style in MapZoomStyle.values) {
      mapZoomStyle.value = style;
      await tester.pumpAndSettle();
      for (var i = 0; i < 6; i++) {
        expect(debugUnlabeled, isEmpty, reason: '${style.name}, zoom $i');
        await tester.tap(find.byKey(const ValueKey('map-zoom-in')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('map-fit')));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('every style zooms and fits without errors', (tester) async {
    addTearDown(() => mapZoomStyle.value = MapZoomStyle.frame);
    tester.view.physicalSize = const Size(900, 450);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OrganicMap(
            blocks: [
              for (var i = 0; i < 250; i++)
                MapBlock(
                  id: 'b$i',
                  label: 'b$i',
                  bytes: 1,
                  state: BlockState.other,
                ),
            ],
          ),
        ),
      ),
    );
    await _settleIsolateLayout(tester);
    for (final style in MapZoomStyle.values) {
      await tester.tap(find.text(style.label));
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const ValueKey('map-zoom-in')));
        await tester.pumpAndSettle();
      }
      await tester.drag(find.byType(OrganicMap), const Offset(-150, -60));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('map-fit')));
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });

  test('block labels drop the year and id tags', () {
    expect(shortName('死神 (2004) {tmdb-30984}'), '死神');
    expect(shortName('The.Bear.2022'), 'The.Bear');
    expect(shortName('2046 (2004)'), '2046');
    expect(shortName('(2004)'), '(2004)');
    expect(shortName('超时空要塞Δ'), '超时空要塞Δ');
  });

  testWidgets('toggling a favorite in map mode keeps the same SizeScanner', (
    tester,
  ) async {
    final c = await _pump(tester);
    await tester.tap(find.text('地图'));
    await tester.pumpAndSettle();
    final before = c.read(sizeScannerProvider(_id));
    expect(before.isComplete(root), isTrue);

    await tester.tap(find.byTooltip('收藏此文件夹'));
    await tester.pumpAndSettle();
    final after = c.read(sizeScannerProvider(_id));
    expect(identical(before, after), isTrue);
    expect(find.byType(OrganicMap), findsOneWidget);
    expect(find.byType(Spinner), findsNothing);
  });

  testWidgets('一键选中未整理 button selects and deselects unorganized children', (
    tester,
  ) async {
    final c = await _pump(tester);
    await tester.tap(find.text('地图'));
    await tester.pumpAndSettle();

    final btn = find.byKey(const ValueKey('map-select-unorganized'));
    expect(btn, findsOneWidget);
    expect(find.text('选中未整理 (2)'), findsOneWidget);

    await tester.tap(btn);
    await tester.pumpAndSettle();
    expect(c.read(browserSelectionProvider), {'$root/下载', '$root/待分类'});
    expect(find.text('取消选中未整理'), findsOneWidget);

    await tester.tap(btn);
    await tester.pumpAndSettle();
    expect(c.read(browserSelectionProvider), isEmpty);
    expect(find.text('选中未整理 (2)'), findsOneWidget);

    // Inside an all-organized folder the button stays hidden.
    await tester.tapAt(_centerOf(tester, c, '电影'));
    await tester.pumpAndSettle();
    expect(c.read(browserDirProvider), '$root/电影');
    expect(btn, findsNothing);
  });

  test(
    'mapBlocksFor generates rich multi-line Chinese tooltip stats',
    () async {
      var marks = <String, bool>{};
      final s = SizeScanner(
        backend: MemoryStorageBackend(fakeLibrary),
        organizedOf: (paths) async =>
            paths.where(fakeOrganized.contains).toSet(),
        marks: () => marks,
      );
      addTearDown(s.dispose);
      await s.scan(root);

      final blocks = mapBlocksFor(s, root);
      MapBlock byLabel(String label) =>
          blocks.firstWhere((b) => b.label == label);

      final movieTip = byLabel('电影').tooltip!;
      expect(movieTip, contains('电影 ·'));
      expect(movieTip, contains('全部已整理'));
      expect(movieTip, contains('共 '));
      expect(movieTip, contains('个文件'));

      final dlTip = byLabel('下载').tooltip!;
      expect(dlTip, contains('下载 ·'));
      expect(dlTip, contains('全部未整理'));
      expect(dlTip, contains('个文件'));

      final subTip = byLabel('字幕包').tooltip!;
      expect(subTip, contains('字幕包 ·'));
      expect(subTip, contains('非视频文件'));
      expect(subTip, contains('共 120 个文件'));

      // Mixed folder shows percentage and unorganized byte size.
      marks = {'$root/动漫/海贼王 (1999)': false, '$root/动漫/咒术回战 (2020)': false};
      s.marksChanged();
      final mixedTip = mapBlocksFor(
        s,
        root,
      ).firstWhere((b) => b.label == '动漫').tooltip!;
      expect(mixedTip, contains('已整理 '));
      expect(mixedTip, contains('% · 未整理 '));
    },
  );

  testWidgets('OrganicMap hover card renders multi-line tooltip cleanly', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: OrganicMap(
            blocks: [
              MapBlock(
                id: '/a',
                label: '动漫',
                bytes: 1000,
                state: BlockState.mixed,
                caption: '42.3 GB',
                tooltip: '动漫 · 42.3 GB\n已整理 72% · 未整理 11.8 GB\n共 120 个文件',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(const Offset(450, 250));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('map-hover')), findsOneWidget);
    expect(find.text('动漫 · 42.3 GB'), findsOneWidget);
    expect(find.text('已整理 72% · 未整理 11.8 GB'), findsOneWidget);
    expect(find.text('共 120 个文件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('isolate layout handles updates and disposal cleanly', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    List<MapBlock> makeBlocks(int n, int scale) => [
      for (var i = 0; i < n; i++)
        MapBlock(
          id: '/b$i',
          label: 'item $i',
          bytes: (i + 1) * scale,
          state: BlockState.organized,
        ),
    ];

    final tapped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OrganicMap(
            blocks: makeBlocks(30, 1000),
            onTap: (b) => tapped.add(b.id),
          ),
        ),
      ),
    );
    expect(debugPendingLayoutCount, greaterThan(0));
    await _settleIsolateLayout(tester);
    expect(debugPendingLayoutCount, 0);

    // Trigger an update while another isolate layout is spawned, then dispose
    // immediately to confirm stale callbacks never call setState after dispose.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OrganicMap(
            blocks: makeBlocks(35, 2000),
            onTap: (b) => tapped.add(b.id),
          ),
        ),
      ),
    );
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await _settleIsolateLayout(tester);
    expect(tester.takeException(), isNull);
  });
}
