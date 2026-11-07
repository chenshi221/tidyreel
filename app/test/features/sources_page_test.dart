import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/features/sources/sources_page.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'helpers.dart';

void main() {
  testWidgets('shows connections with status and favorites', (tester) async {
    await pumpPage(tester, const SourcesPage());
    expect(find.text('演示 Alist'), findsWidgets); // row + favorite
    expect(find.text('演示本地'), findsOneWidget);
    expect(find.text('已连接'), findsNWidgets(2));
    // favorite row: path + connection name
    expect(find.byKey(const ValueKey('fav demo-alist /下载/完成')), findsOneWidget);
  });

  testWidgets('add connection dialog creates a card', (tester) async {
    await pumpPage(tester, const SourcesPage());
    await tester.tap(find.text('添加连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('必填'), findsOneWidget); // host; 名称 is optional

    await tester.enterText(find.byKey(const ValueKey('field-名称')), '公司 NAS');
    await tester.enterText(find.byKey(const ValueKey('field-主机')), 'nas');
    await tester.pump();
    expect(find.text('http://nas:5244'), findsOneWidget); // live preview
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('公司 NAS'), findsOneWidget);
  });

  testWidgets('browse, multi-select and submit creates a task', (tester) async {
    final (tm, _) = await pumpPage(tester, const SourcesPage());
    await tester.tap(find.byKey(const ValueKey('fav demo-alist /下载/完成')));
    await tester.pumpAndSettle();
    expect(find.text('异兽魔都 2020 1080p'), findsOneWidget);
    expect(find.text('Inception.2010.2160p.BluRay.x265.mkv'), findsOneWidget);

    // search narrows the list
    await tester.enterText(find.byType(TextField).first, 'incep');
    await tester.pumpAndSettle();
    expect(find.text('异兽魔都 2020 1080p'), findsNothing);
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle();

    // No mode switch: ticking a checkbox selects and brings up the bar.
    expect(find.byKey(const ValueKey('organize')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('check 异兽魔都 2020 1080p')));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 3 项'), findsOneWidget);
    // 已选 opens the list; removing one updates the count.
    await tester.tap(find.byKey(const ValueKey('show-selected')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(
          const ValueKey('selected /下载/完成/更多资源请访问 www.example.com.txt'),
        ),
        matching: find.byTooltip('移出选择'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '完成').last);
    await tester.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 3 项'), findsOneWidget);
    // fuzzy search: words in any order, punctuation ignored
    await tester.enterText(find.byType(TextField).first, '2160p inception');
    await tester.pumpAndSettle();
    expect(find.text('Inception.2010.2160p.BluRay.x265.mkv'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle();
    await tester.tap(find.text('移动到媒体库'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('organize')));
    await tester.pumpAndSettle();
    // The preview comes first; 取消 leaves nothing behind.
    expect(find.text('识别前预览'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(await tm.watchAll().first, isEmpty);
    await tester.tap(find.byKey(const ValueKey('scrape')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('preview-submit')));
    await tester.pumpAndSettle();

    final tasks = await tm.watchAll().first;
    expect(tasks, hasLength(1));
    expect(tasks.single.paths, hasLength(3));
    expect(tasks.single.mode, OrganizeMode.moveToLibrary);
    expect(tasks.single.scrape, isTrue);
    // Lands on the new task's detail page.
    expect(find.text('ROUTE detail ${tasks.single.id.value}'), findsOneWidget);
  });

  testWidgets('hover 整理 submits one item and opens its detail', (tester) async {
    final (tm, _) = await pumpPage(tester, const SourcesPage());
    await tester.tap(find.byKey(const ValueKey('fav demo-alist /下载/完成')));
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(
      tester.getCenter(find.text('Inception.2010.2160p.BluRay.x265.mkv')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey('organize Inception.2010.2160p.BluRay.x265.mkv'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1'), findsWidgets); // one video in the preview
    await tester.tap(find.byKey(const ValueKey('preview-submit')));
    await tester.pumpAndSettle();

    final tasks = await tm.watchAll().first;
    expect(tasks.single.paths, ['/下载/完成/Inception.2010.2160p.BluRay.x265.mkv']);
    expect(find.text('ROUTE detail ${tasks.single.id.value}'), findsOneWidget);
  });

  testWidgets('clicking a folder opens it', (tester) async {
    await pumpPage(tester, const SourcesPage());
    await tester.tap(find.byKey(const ValueKey('fav demo-alist /下载/完成')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('异兽魔都 2020 1080p'));
    await tester.pumpAndSettle();
    expect(find.text('[Sub] Dorohedoro S01E01 [1080p].mkv'), findsOneWidget);
    expect(find.text('已选 1 项'), findsNothing);
  });

  testWidgets('right-click a folder: 收藏, then 整理（原地） previews', (tester) async {
    final (tm, _) = await pumpPage(tester, const SourcesPage());
    await tester.tap(find.byKey(const ValueKey('fav demo-alist /下载/完成')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('异兽魔都 2020 1080p'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(await tm.watchAll().first, isEmpty); // 收藏 submits nothing

    await tester.tap(find.text('异兽魔都 2020 1080p'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('取消收藏'), findsOneWidget);
    await tester.tap(find.text('整理（原地）'));
    await tester.pumpAndSettle();
    expect(find.text('识别前预览'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('preview-submit')));
    await tester.pumpAndSettle();
    final tasks = await tm.watchAll().first;
    expect(tasks.single.mode, OrganizeMode.inPlace);
    expect(tasks.single.paths.single, endsWith('异兽魔都 2020 1080p'));
  });
}
