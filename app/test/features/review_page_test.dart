import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/features/review/review_page.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'helpers.dart';

const _g1 = GroupId('g1');
const _file = '/下载/完成/异兽魔都 2020 1080p/[Sub] Dorohedoro S01E01 [1080p].mkv';

Future<void> tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  Future<(dynamic, TaskId)> open(WidgetTester tester) async {
    final (tm, _) = await pumpPage(tester, const SizedBox());
    final id = await submitAndWait(tester, tm);
    await pumpPage(tester, ReviewPage(taskId: id.value), tm: tm);
    return (tm, id);
  }

  testWidgets('shows groups, tabs, seasons and new names', (tester) async {
    await open(tester);
    expect(find.text('可整理 (2)'), findsOneWidget);
    expect(find.text('待手动识别 (1)'), findsOneWidget);
    expect(find.text('异兽魔都'), findsWidgets);
    expect(find.text('本地 2 季 23 集 / TMDB 2 季 23 集'), findsOneWidget);
    expect(find.text('第 1 季 (12/12)'), findsOneWidget);
    expect(find.text('第 2 季 (11/11)'), findsOneWidget);
    // new name on top, original below
    expect(find.text('异兽魔都.Dorohedoro.2020.S01E01.mkv'), findsOneWidget);
    expect(find.text('[Sub] Dorohedoro S01E01 [1080p].mkv'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('folder-tab')));
    await tester.pumpAndSettle();
    expect(find.text('/下载/完成/异兽魔都 (2020)'), findsOneWidget);

    await tester.tap(find.text('待手动识别 (1)'));
    await tester.pumpAndSettle();
    expect(find.text('未知视频'), findsWidgets);
    expect(find.byKey(const ValueKey('inline-search-g3')), findsOneWidget);
  });

  testWidgets('editing a row calls updateDecision with a FileOverride', (
    tester,
  ) async {
    final (tm, id) = await open(tester);
    await tester.tap(find.text('[Sub] Dorohedoro S01E01 [1080p].mkv'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('edit-episode')), '5');
    await tester.tap(find.text('花絮'));
    await tester.tap(find.byKey(const ValueKey('edit-save')));
    await tester.pumpAndSettle();

    final o =
        (await tm.review(id) as TaskReview).decisions[_g1]!.overrides[_file]!;
    expect(o.episode, 5);
    expect(o.season, 1);
    expect(o.kind, MediaKind.extra);
    expect(o.ignore, isFalse);
  });

  testWidgets('right pane: strategy, offset, manual match', (tester) async {
    final (tm, id) = await open(tester);
    await tapKey(tester, 'strategy-mergeIntoOne');
    await tapKey(tester, 'offset-plus');
    await tapKey(tester, 'offset-plus');
    await tester.pumpAndSettle();
    var d = (await tm.review(id) as TaskReview).decisions[_g1]!;
    expect(d.strategy, SeasonStrategy.mergeIntoOne);
    expect(d.episodeOffset, 2);
    expect(find.text('TMDB 上没有剧集组'), findsOneWidget);

    // unmatched group: inline search moves it to 可整理
    await tester.tap(find.text('待手动识别 (1)'));
    await tester.pumpAndSettle();
    final box = find.descendant(
      of: find.byKey(const ValueKey('inline-search-g3')),
      matching: find.byType(TextField),
    );
    await tester.enterText(box, '盗梦');
    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('inline-search-g3')),
        matching: find.text('盗梦空间'),
      ),
    );
    await tester.pumpAndSettle();
    d = (await tm.review(id) as TaskReview).decisions[const GroupId('g3')]!;
    expect(d.match?.tmdbId, 27205);
    expect(find.text('可整理 (3)'), findsOneWidget);
  });

  testWidgets('keyboard: arrows move, space toggles; execute goes to tasks', (
    tester,
  ) async {
    final (tm, id) = await open(tester);
    expect(
      (await tm.review(id) as TaskReview).decisions[_g1]!.selected,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(
      (await tm.review(id) as TaskReview).decisions[_g1]!.selected,
      isFalse,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(
      (await tm.review(
        id,
      ) as TaskReview).decisions[const GroupId('g2')]!.selected,
      isFalse,
    );

    await tester.tap(find.byKey(const ValueKey('execute-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('重命名/移动文件'), findsOneWidget);
    await tester.tap(find.text('执行'));
    await tester.pumpAndSettle();
    expect(find.text('ROUTE /tasks'), findsOneWidget);
  });
}
