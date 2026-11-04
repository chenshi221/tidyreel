import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/data/providers.dart';
import 'package:tidyreel/features/map/map_providers.dart';
import 'package:tidyreel/features/map/organic_layout.dart';
import 'package:tidyreel/features/map/organic_map.dart';
import 'package:tidyreel/features/map/repo_map_view.dart';
import 'package:tidyreel/features/sources/sources_page.dart';
import 'package:tidyreel/features/sources/sources_providers.dart';
import 'package:tidyreel/ui/widgets.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'fake_library.dart';

const _id = ConnectionId('demo-alist');

Future<ProviderContainer> _pump(WidgetTester tester) async {
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
          MemoryStorageBackend(fakeLibrary),
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

/// Where block [label] is drawn, by laying the map out the same way.
Offset _centerOf(WidgetTester tester, ProviderContainer c, String label) {
  final map = tester.widget<OrganicMap>(find.byType(OrganicMap));
  final box = tester.renderObject<RenderBox>(find.byType(OrganicMap));
  final total = map.blocks.fold(0, (t, b) => t + b.bytes);
  final cells = layoutOrganic([
    for (final b in map.blocks)
      MapItem(
        b.id,
        b.bytes.toDouble() < total * minShareDrawn
            ? total * minShareDrawn
            : b.bytes.toDouble(),
      ),
  ], Offset.zero & box.size);
  final id = map.blocks.firstWhere((b) => b.label == label).id;
  return box.localToGlobal(cells.firstWhere((x) => x.id == id).centroid);
}

void main() {
  testWidgets('a missing library root says so and stops spinning', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tm = FakeTaskManager(step: Duration.zero);
    addTearDown(tm.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          taskManagerProvider.overrideWithValue(tm),
          demoBackendProvider.overrideWithValue(MemoryStorageBackend()),
        ],
        child: const MaterialApp(home: Scaffold(body: SourcesPage())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('找不到这个文件夹'), findsOneWidget);
    expect(find.byType(Spinner), findsNothing);
  });

  testWidgets('地图 counts the folder and clicking a block opens it', (
    tester,
  ) async {
    final c = await _pump(tester);
    expect(find.byType(RepoMapView), findsNothing);
    await tester.tap(find.text('地图'));
    await tester.pumpAndSettle();
    expect(find.byType(RepoMapView), findsOneWidget);
    expect(find.textContaining('个文件 · 未整理'), findsOneWidget);
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
}
