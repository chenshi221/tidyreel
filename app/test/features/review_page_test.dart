import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/features/review/review_page.dart';
import 'package:tidyreel/ui/widgets.dart';
import 'package:tidyreel_core/testing.dart';
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
    expect(
      find.text('本地 2 季 23 集 / TMDB 2 季 23 集'),
      findsWidgets,
    ); // list card + header
    expect(find.text('第 1 季 (12/12)'), findsOneWidget);
    expect(find.text('第 2 季 (11/11)'), findsOneWidget);
    // new name on top, original below
    expect(find.text('异兽魔都.Dorohedoro.2020.S01E01.mkv'), findsOneWidget);
    expect(find.text('[Sub] Dorohedoro S01E01 [1080p].mkv'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('folder-tab')));
    await tester.pumpAndSettle();
    expect(find.text('→ /下载/完成/异兽魔都 (2020)'), findsOneWidget);

    await tester.tap(find.text('待手动识别 (1)'));
    await tester.pumpAndSettle();
    expect(find.text('未知视频'), findsWidgets);
    expect(find.byKey(const ValueKey('inline-search-g3')), findsOneWidget);
  });

  testWidgets('subtitles fold under their episode until opened', (
    tester,
  ) async {
    await open(tester);
    const sub = '[Sub] Dorohedoro S01E01.chs.ass';
    expect(find.text(sub), findsNothing);
    expect(find.text('1 个字幕'), findsWidgets);
    await tester.tap(find.text('1 个字幕').first);
    await tester.pumpAndSettle();
    expect(find.text(sub), findsOneWidget);
  });

  testWidgets('未归类 lists files no work claimed, with a reason', (tester) async {
    await open(tester);
    await tapKey(tester, 'unassigned-link');
    expect(find.text('未归类 1 个文件'), findsWidgets);
    expect(find.textContaining('广告或垃圾文件'), findsOneWidget);
    // Back to a work.
    await tester.tap(find.text('异兽魔都').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('广告或垃圾文件'), findsNothing);
  });

  testWidgets('editing a row: pick a TMDB episode, later files follow', (
    tester,
  ) async {
    final (tm, id) = await open(tester);
    Future<GroupDecision> decision() async =>
        (await tm.review(id) as TaskReview).decisions[_g1]!;

    await tester.tap(find.text('[Sub] Dorohedoro S01E01 [1080p].mkv'));
    await tester.pumpAndSettle();
    // TMDB episode list; picking E03 moves this file and renumbers the rest.
    await tester.tap(find.byKey(const ValueKey('pick-ep-1-3')));
    await tester.pumpAndSettle();
    expect((await decision()).overrides, isEmpty); // only selected so far
    await tester.tap(find.byKey(const ValueKey('pick-confirm')));
    await tester.pumpAndSettle();
    var d = await decision();
    expect(d.overrides[_file]!.episode, 3);
    expect(d.overrides[_file]!.season, 1);
    // 11 later season-1 files: E04…E12, then season 1 is full -> S02E01, S02E02.
    expect(d.overrides, hasLength(12));
    final refs = {
      for (final o in d.overrides.values) EpisodeRef(o.season!, o.episode!),
    };
    expect(
      refs,
      containsAll([const EpisodeRef(1, 12), const EpisodeRef(2, 2)]),
    );
    expect(find.text('后面 11 个文件已依次顺延'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect((await decision()).overrides, isEmpty);

    // Manual entry is the fallback; 花絮 needs no episode.
    await tester.tap(find.text('[Sub] Dorohedoro S01E01 [1080p].mkv'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('edit-manual')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('edit-episode')), findsOneWidget);
    await tester.tap(find.text('花絮'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('edit-save')));
    await tester.pumpAndSettle();
    d = await decision();
    expect(d.overrides[_file]!.kind, MediaKind.extra);
    expect(d.overrides, hasLength(1));
  });

  testWidgets('a show matched by hand still offers its seasons and episodes', (
    tester,
  ) async {
    final (tm, id) = await open(tester);
    await tm.updateDecision(
      id,
      _g1,
      const GroupDecision(match: Demo.friends, selected: true),
    );
    await pumpPage(tester, ReviewPage(taskId: id.value), tm: tm);

    await tester.tap(find.text('[Sub] Dorohedoro S01E01 [1080p].mkv'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('edit-episode')), findsNothing);
    expect(find.byKey(const ValueKey('pick-season-1')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('pick-confirm')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('pick-ep-1-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pick-confirm')));
    await tester.pumpAndSettle();
    final d = (await tm.review(id) as TaskReview).decisions[_g1]!;
    expect(d.overrides[_file]!.episode, 2);
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
    final box = find
        .descendant(
          of: find.byKey(const ValueKey('inline-search-g3')),
          matching: find.byType(TextField),
        )
        .first;
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
    expect(d.selected, isTrue); // picking a match checks the group
    expect(find.text('可整理 (3)'), findsOneWidget);
  });

  testWidgets('keyboard: arrows move, space toggles; execute opens the task', (
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
    expect(find.text('ROUTE detail ${id.value}'), findsOneWidget);
  });

  testWidgets('left/right arrows step through seasons and 文件夹', (tester) async {
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight); // 第 2 季
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight); // 文件夹
    await tester.pumpAndSettle();
    expect(find.text('→ /下载/完成/异兽魔都 (2020)'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('→ /下载/完成/异兽魔都 (2020)'), findsNothing);
  });

  testWidgets('header, TMDB episode titles and missing-episode rows', (
    tester,
  ) async {
    final (tm, id) = await open(tester);
    expect(find.byKey(const ValueKey('work-header')), findsOneWidget);
    expect(find.textContaining('开曼'), findsOneWidget); // synopsis
    expect(find.text('8.1'), findsWidgets); // rating
    expect(find.text('第 1 话'), findsOneWidget); // episode title from TMDB
    expect(find.byKey(const ValueKey('missing-1-1')), findsNothing);

    // Unticking E01 leaves a hole TMDB knows about.
    final row = find.ancestor(
      of: find.text('[Sub] Dorohedoro S01E01 [1080p].mkv'),
      matching: find.byType(Hoverable),
    );
    await tester.tap(
      find.descendant(of: row.first, matching: find.byType(Checkbox)).first,
    );
    await tester.pumpAndSettle();
    expect(
      (await tm.review(
        id,
      ) as TaskReview).decisions[_g1]!.overrides[_file]!.ignore,
      isTrue,
    );
    expect(find.byKey(const ValueKey('missing-1-1')), findsOneWidget);
    expect(find.text('本地缺失'), findsOneWidget);
  });

  testWidgets('作品操作 pane can be hidden', (tester) async {
    await open(tester);
    expect(find.byKey(const ValueKey('strategy-asParsed')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('toggle-actions')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('strategy-asParsed')), findsNothing);
  });
}
