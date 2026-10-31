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
    expect(find.text('必填'), findsNWidgets(2)); // name + host

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

    await tester.tap(find.widgetWithText(FilterChip, '多选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('异兽魔都 2020 1080p'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 3 项'), findsOneWidget);
    await tester.tap(find.text('移动到媒体库'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('提交为任务'));
    await tester.pumpAndSettle();

    final tasks = await tm.watchAll().first;
    expect(tasks, hasLength(1));
    expect(tasks.single.paths, hasLength(3));
    expect(tasks.single.mode, OrganizeMode.moveToLibrary);
    expect(
      find.textContaining('已提交任务 ${tasks.single.id.value}'),
      findsOneWidget,
    );

    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();
    expect(find.text('ROUTE /tasks'), findsOneWidget);
  });
}
