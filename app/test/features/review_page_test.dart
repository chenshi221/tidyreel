import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tidyreel/data/providers.dart';
import 'package:tidyreel/features/review/review_page.dart';
import 'package:tidyreel/ui/widgets.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'helpers.dart';

const _g1 = GroupId('g1');
const _file = '/下载/完成/异兽魔都 2020 1080p/[Sub] Dorohedoro S01E01 [1080p].mkv';

/// Uses the real planner so checkbox/override changes must affect executable operations.
class _PlanningTaskManager extends FakeTaskManager {
  final ScanResult scan;
  final PlanOptions planOptions;
  Completer<void>? updateGate;
  Completer<void>? reviewGate;
  var runCalls = 0;

  _PlanningTaskManager(this.scan, {this.planOptions = const PlanOptions()})
    : super(step: Duration.zero);

  @override
  Future<TaskReview> review(TaskId id) async {
    await reviewGate?.future;
    final r = await super.review(id);
    return TaskReview(
      id: id,
      scan: scan,
      decisions: r.decisions,
      preview: await DefaultPlanner(FakeMetadataProvider())
          .build(scan, r.decisions, planOptions),
    );
  }

  @override
  Future<TaskReview> updateDecision(
    TaskId id,
    GroupId group,
    GroupDecision decision,
  ) async {
    await updateGate?.future;
    await super.updateDecision(id, group, decision);
    return review(id);
  }

  @override
  Future<void> run(TaskId id, {bool onlyConfident = false}) async {
    runCalls++;
    await super.run(id, onlyConfident: onlyConfident);
  }
}

Future<void> tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'settings reload disables execution until refreshed preview arrives',
    (tester) async {
      final scan = Demo.review(
        const TaskId('sample'),
        const ConnectionId('demo-alist'),
        '/d',
      ).scan;
      final tm = _PlanningTaskManager(scan);
      await pumpPage(tester, const SizedBox(), tm: tm);
      final id = await submitAndWait(tester, tm);
      final (_, container) = await pumpPage(
        tester,
        ReviewPage(taskId: id.value),
        tm: tm,
      );
      final gate = Completer<void>();
      tm.reviewGate = gate;
      final naming = container.read(namingProfileProvider);
      container
          .read(namingProfileProvider.notifier)
          .set(
            naming.copyWith(
              tv: naming.tv.copyWith(bilingual: !naming.tv.bilingual),
            ),
          );
      await tester.pump();
      final execute = find.byKey(const ValueKey('execute-button'));
      expect(tester.widget<FilledButton>(execute).onPressed, isNull);
      gate.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(execute).onPressed, isNotNull);
    },
  );

  Future<(dynamic, TaskId)> open(WidgetTester tester) async {
    final (tm, _) = await pumpPage(tester, const SizedBox());
    final id = await submitAndWait(tester, tm);
    await pumpPage(tester, ReviewPage(taskId: id.value), tm: tm);
    return (tm, id);
  }

  testWidgets(
    'low confidence defaults off but a user can select and deselect it',
    (tester) async {
      const path = '/下载/盗梦空间 (2010)/2010.1080p.mkv';
      final tm = _PlanningTaskManager(
        const ScanResult(
          connection: ConnectionId('demo-alist'),
          roots: ['/下载/盗梦空间 (2010)'],
          groups: [
            MediaGroup(
              id: _g1,
              kind: MediaKind.movie,
              anchorTitle: '盗梦空间',
              rootDir: '/下载/盗梦空间 (2010)',
              match: Demo.inception,
              matchScore: 0.3,
              files: [
                ScanFile(
                  path: path,
                  name: '2010.1080p.mkv',
                  size: 1,
                  role: FileRole.video,
                  parsed: ParsedName(kind: MediaKind.movie, confidence: 0.3),
                ),
              ],
            ),
          ],
        ),
      );
      await pumpPage(tester, const SizedBox(), tm: tm);
      final id = await submitAndWait(tester, tm);
      await pumpPage(tester, ReviewPage(taskId: id.value), tm: tm);
      final row = find
          .ancestor(
            of: find.text('2010.1080p.mkv'),
            matching: find.byType(Hoverable),
          )
          .first;
      final checkbox = find.descendant(
        of: row,
        matching: find.byType(Checkbox),
      );
      final execute = find.byKey(const ValueKey('execute-button'));

      expect(tester.widget<Checkbox>(checkbox).value, isFalse);
      expect(tester.widget<FilledButton>(execute).onPressed, isNull);
      expect(find.text('0 处改动'), findsOneWidget);
      expect(find.textContaining('识别置信度较低'), findsOneWidget);

      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(checkbox).value, isTrue);
      expect(tester.widget<FilledButton>(execute).onPressed, isNotNull);
      expect(find.text('1 处改动'), findsOneWidget);
      expect(find.textContaining('识别置信度较低'), findsOneWidget);
      expect((await tm.review(id)).preview.ops.single.selected, isTrue);

      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(checkbox).value, isFalse);
      expect(tester.widget<FilledButton>(execute).onPressed, isNull);
      expect(find.text('0 处改动'), findsOneWidget);
      expect(
        (await tm.review(id)).preview.ops.where((o) => o.selected),
        isEmpty,
      );
    },
  );

  testWidgets('shows groups, tabs, seasons and new names', (tester) async {
    await open(tester);
    expect(find.text('可整理 2'), findsOneWidget);
    expect(find.text('需手动匹配 1'), findsOneWidget);
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

    await tester.tap(find.text('需手动匹配 1'));
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

  testWidgets('重新搜索 does not filter by the match being corrected', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('异兽魔都').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('重新搜索 TMDB'));
    await tester.tap(find.text('重新搜索 TMDB'));
    await tester.pumpAndSettle();
    final year = tester.widget<TextField>(
      find.byKey(const ValueKey('search-year')),
    );
    expect(year.controller!.text, isEmpty);
    expect(find.text('全部'), findsWidgets);
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
    await tester.tap(find.text('需手动匹配 1'));
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
    expect(find.text('可整理 3'), findsOneWidget);
    // The manual tab just emptied: back to 可整理 by itself.
    expect(
      tester.widget<Segmented<int>>(find.byType(Segmented<int>).first).value,
      0,
    );
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

    // Nothing to delete, so no confirmation: it runs straight away.
    await tester.tap(find.byKey(const ValueKey('execute-button')));
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

  group('review regressions', () {
    testWidgets(
      'issue 6: pending updateDecision disables execute button and blocks shortcut',
      (tester) async {
        const root = '/d/异兽魔都 2020';
        final tm = _PlanningTaskManager(
          const ScanResult(
            connection: ConnectionId('demo-alist'),
            roots: ['/d'],
            groups: [
              MediaGroup(
                id: _g1,
                kind: MediaKind.episode,
                anchorTitle: '异兽魔都',
                rootDir: root,
                match: Demo.dorohedoro,
                matchScore: 0.9,
                files: [
                  ScanFile(
                    path: '$root/a.mkv',
                    name: 'a.mkv',
                    size: 1,
                    role: FileRole.video,
                    parsed: ParsedName(
                      season: 1,
                      episodes: [1],
                      confidence: 0.9,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
        await pumpPage(tester, const SizedBox(), tm: tm);
        final id = await submitAndWait(tester, tm);
        await pumpPage(tester, ReviewPage(taskId: id.value), tm: tm);

        final execute = find.byKey(const ValueKey('execute-button'));
        expect(tester.widget<FilledButton>(execute).onPressed, isNotNull);

        final gate = Completer<void>();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        tm.updateGate = gate;
        await tester.tap(find.byKey(const ValueKey('strategy-mergeIntoOne')));
        await tester.pump();

        expect(tester.widget<FilledButton>(execute).onPressed, isNull);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();
        expect(tm.runCalls, 0);

        gate.complete();
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(execute).onPressed, isNotNull);
        expect(find.textContaining('S01E01.mkv'), findsOneWidget);
      },
    );

    testWidgets(
      'issue 7: editing a subtitle updates only that subtitle and does not shift videos',
      (tester) async {
        const root = '/d/异兽魔都 2020';
        final tm = _PlanningTaskManager(
          const ScanResult(
            connection: ConnectionId('demo-alist'),
            roots: ['/d'],
            groups: [
              MediaGroup(
                id: _g1,
                kind: MediaKind.episode,
                anchorTitle: '异兽魔都',
                rootDir: root,
                match: Demo.dorohedoro,
                matchScore: 0.9,
                files: [
                  ScanFile(
                    path: '$root/ep1.mkv',
                    name: 'ep1.mkv',
                    size: 1,
                    role: FileRole.video,
                    parsed: ParsedName(
                      season: 1,
                      episodes: [1],
                      confidence: 0.9,
                    ),
                  ),
                  ScanFile(
                    path: '$root/ep1.srt',
                    name: 'ep1.srt',
                    size: 1,
                    role: FileRole.subtitle,
                  ),
                  ScanFile(
                    path: '$root/ep2.mkv',
                    name: 'ep2.mkv',
                    size: 1,
                    role: FileRole.video,
                    parsed: ParsedName(
                      season: 1,
                      episodes: [2],
                      confidence: 0.9,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
        await pumpPage(tester, const SizedBox(), tm: tm);
        final id = await submitAndWait(tester, tm);
        await pumpPage(tester, ReviewPage(taskId: id.value), tm: tm);

        await tester.tap(find.text('1 个字幕').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('ep1.srt'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('pick-ep-1-2')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('pick-confirm')));
        await tester.pumpAndSettle();

        final d = (await tm.review(id)).decisions[_g1]!;
        expect(d.overrides.keys, ['$root/ep1.srt']);
        expect(d.overrides['$root/ep1.srt']!.season, 1);
        expect(d.overrides['$root/ep1.srt']!.episode, 2);
        expect(find.textContaining('依次顺延'), findsNothing);
      },
    );

    testWidgets(
      'issue 8: ignoring video expands companions and companion warning tag is shown',
      (tester) async {
        const root = '/d/异兽魔都 2020';
        final tm = _PlanningTaskManager(
          const ScanResult(
            connection: ConnectionId('demo-alist'),
            roots: ['/d'],
            groups: [
              MediaGroup(
                id: _g1,
                kind: MediaKind.episode,
                anchorTitle: '异兽魔都',
                rootDir: root,
                match: Demo.dorohedoro,
                matchScore: 0.9,
                files: [
                  ScanFile(
                    path: '$root/ep1.mkv',
                    name: 'ep1.mkv',
                    size: 1,
                    role: FileRole.video,
                    parsed: ParsedName(
                      season: 1,
                      episodes: [1],
                      confidence: 0.9,
                    ),
                  ),
                  ScanFile(
                    path: '$root/ep1.srt',
                    name: 'ep1.srt',
                    size: 1,
                    role: FileRole.subtitle,
                  ),
                ],
              ),
            ],
          ),
        );
        await pumpPage(tester, const SizedBox(), tm: tm);
        final id = await submitAndWait(tester, tm);
        await pumpPage(tester, ReviewPage(taskId: id.value), tm: tm);

        expect(find.text('ep1.srt'), findsNothing);
        final row = find.ancestor(
          of: find.text('ep1.mkv'),
          matching: find.byType(Hoverable),
        );
        await tester.tap(
          find.descendant(of: row.first, matching: find.byType(Checkbox)).first,
        );
        await tester.pumpAndSettle();
        expect(find.text('ep1.srt'), findsOneWidget);

        // Explicit companion edit to an overflowing episode surfaces its warning tag.
        await tester.tap(find.text('ep1.srt'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('edit-manual')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('edit-season')), '1');
        await tester.enterText(
          find.byKey(const ValueKey('edit-episode')),
          '99',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('edit-save')));
        await tester.pumpAndSettle();
        expect(find.textContaining('超出 TMDB 总集数'), findsOneWidget);
      },
    );

    testWidgets(
      'issue 9: manual edit validates season/episode and accepts valid specials',
      (tester) async {
        const root = '/d/异兽魔都 2020';
        final tm = _PlanningTaskManager(
          const ScanResult(
            connection: ConnectionId('demo-alist'),
            roots: ['/d'],
            groups: [
              MediaGroup(
                id: _g1,
                kind: MediaKind.episode,
                anchorTitle: '异兽魔都',
                rootDir: root,
                match: Demo.dorohedoro,
                matchScore: 0.9,
                files: [
                  ScanFile(
                    path: '$root/ep1.mkv',
                    name: 'ep1.mkv',
                    size: 1,
                    role: FileRole.video,
                    parsed: ParsedName(
                      season: 1,
                      episodes: [1],
                      confidence: 0.9,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
        await pumpPage(tester, const SizedBox(), tm: tm);
        final id = await submitAndWait(tester, tm);
        await pumpPage(tester, ReviewPage(taskId: id.value), tm: tm);

        await tester.tap(find.text('ep1.mkv'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('edit-manual')));
        await tester.pumpAndSettle();

        final save = find.byKey(const ValueKey('edit-save'));
        await tester.enterText(find.byKey(const ValueKey('edit-episode')), '0');
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('edit-validation-error')),
          findsOneWidget,
        );
        expect(tester.widget<FilledButton>(save).onPressed, isNull);

        await tester.enterText(find.byKey(const ValueKey('edit-episode')), '1');
        await tester.enterText(find.byKey(const ValueKey('edit-season')), '-1');
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('edit-validation-error')),
          findsOneWidget,
        );
        expect(tester.widget<FilledButton>(save).onPressed, isNull);

        await tester.tap(find.text('特别篇'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('edit-season')), '0');
        await tester.enterText(find.byKey(const ValueKey('edit-episode')), '1');
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('edit-validation-error')),
          findsNothing,
        );
        expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
        await tester.tap(save);
        await tester.pumpAndSettle();

        final d = (await tm.review(id)).decisions[_g1]!;
        expect(d.overrides['$root/ep1.mkv']!.kind, MediaKind.special);
        expect(d.overrides['$root/ep1.mkv']!.season, 0);
        expect(d.overrides['$root/ep1.mkv']!.episode, 1);
      },
    );

    testWidgets(
      'issue 10: merge conflict opens dialog, warns if kept merged, and executes when separated',
      (tester) async {
        final tm = _PlanningTaskManager(
          const ScanResult(
            connection: ConnectionId('demo-alist'),
            roots: ['/d/one', '/d/two'],
            groups: [
              MediaGroup(
                id: _g1,
                kind: MediaKind.episode,
                anchorTitle: '异兽魔都',
                rootDir: '/d/one',
                match: Demo.dorohedoro,
                matchScore: 0.9,
                files: [
                  ScanFile(
                    path: '/d/one/a.mkv',
                    name: 'a.mkv',
                    size: 1,
                    role: FileRole.video,
                    parsed: ParsedName(
                      season: 1,
                      episodes: [1],
                      confidence: 0.9,
                    ),
                  ),
                ],
              ),
              MediaGroup(
                id: GroupId('g2'),
                kind: MediaKind.episode,
                anchorTitle: '异兽魔都',
                rootDir: '/d/two',
                match: Demo.dorohedoro,
                matchScore: 0.9,
                files: [
                  ScanFile(
                    path: '/d/two/a.mkv',
                    name: 'a.mkv',
                    size: 1,
                    role: FileRole.video,
                    parsed: ParsedName(
                      season: 1,
                      episodes: [1],
                      confidence: 0.9,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
        await pumpPage(tester, const SizedBox(), tm: tm);
        final id = await submitAndWait(tester, tm);
        await pumpPage(tester, ReviewPage(taskId: id.value), tm: tm);

        final execute = find.byKey(const ValueKey('execute-button'));
        expect(tester.widget<FilledButton>(execute).onPressed, isNotNull);
        expect(find.textContaining('点「开始整理」可分开保留'), findsOneWidget);

        // Keeping merged still leaves conflict, so snackbar warns and refuses run.
        await tester.tap(execute);
        await tester.pumpAndSettle();
        expect(find.text('合并到已有剧集文件夹？'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('merge-continue')));
        await tester.pumpAndSettle();
        expect(find.textContaining('仍有'), findsOneWidget);
        expect(tm.runCalls, 0);

        // Selecting 分开保留 clears conflict and executes.
        await tester.tap(execute);
        await tester.pumpAndSettle();
        await tester.tap(find.text('分开保留').first);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('merge-continue')));
        await tester.pumpAndSettle();
        expect(tm.runCalls, 1);
        expect(find.text('ROUTE detail ${id.value}'), findsOneWidget);
      },
    );

    testWidgets(
      'issue 13: changing namingProfileProvider reloads awaiting ReviewPage preview',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        const root = '/d/异兽魔都 2020';
        const tid = TaskId('T-naming');
        final store = MemoryTaskStore();
        final fs = MemoryStorageBackend({'$root/a.mkv': 1});
        await store.saveSummary(
          TaskSummary(
            id: tid,
            connection: const ConnectionId('demo-alist'),
            paths: const ['/d'],
            mode: OrganizeMode.inPlace,
            stage: TaskStage.awaitingReview,
            createdAt: DateTime(2026),
          ),
        );
        await store.saveReview(
          tid,
          const ScanResult(
            connection: ConnectionId('demo-alist'),
            roots: ['/d'],
            groups: [
              MediaGroup(
                id: _g1,
                kind: MediaKind.episode,
                anchorTitle: '异兽魔都',
                rootDir: root,
                match: Demo.dorohedoro,
                matchScore: 0.9,
                files: [
                  ScanFile(
                    path: '$root/a.mkv',
                    name: 'a.mkv',
                    size: 1,
                    role: FileRole.video,
                    parsed: ParsedName(
                      season: 1,
                      episodes: [1],
                      confidence: 0.9,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const {_g1: GroupDecision()},
        );

        final router = GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) =>
                  const Scaffold(body: ReviewPage(taskId: 'T-naming')),
            ),
          ],
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              taskManagerProvider.overrideWith((ref) {
                final h = MemoryHistoryStore();
                final tm = DefaultTaskManager(
                  backendFor: (_) => fs,
                  recognizer: AnchorRecognizer(
                    const RuleBasedParser(),
                    FakeMetadataProvider(),
                  ),
                  planner: DefaultPlanner(FakeMetadataProvider()),
                  executor: DefaultExecutor(h, minInterval: Duration.zero),
                  history: h,
                  store: store,
                  options: (_, mode) => PlanOptions(
                    mode: mode,
                    naming: ref.read(namingProfileProvider),
                  ),
                );
                addTearDown(tm.dispose);
                return tm;
              }),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('异兽魔都.Dorohedoro.2020.S01E01.mkv'), findsOneWidget);

        final container = ProviderScope.containerOf(
          tester.element(find.byType(ReviewPage)),
        );
        container
            .read(namingProfileProvider.notifier)
            .set(
              NamingProfile.vidhub.copyWith(
                tv: NamingProfile.vidhub.tv.copyWith(
                  customTemplate: () => 'CUSTOM.S{season:02}E{episode:02}',
                ),
              ),
            );
        await tester.pumpAndSettle();
        expect(find.text('CUSTOM.S01E01.mkv'), findsOneWidget);
      },
    );

    testWidgets(
      'issue 15: UnassignedPane and sidebar distinguish kept vs deleted junk files',
      (tester) async {
        const root = '/d/异兽魔都 2020';
        const scan = ScanResult(
          connection: ConnectionId('demo-alist'),
          roots: ['/d'],
          groups: [
            MediaGroup(
              id: _g1,
              kind: MediaKind.episode,
              anchorTitle: '异兽魔都',
              rootDir: root,
              match: Demo.dorohedoro,
              matchScore: 0.9,
              files: [
                ScanFile(
                  path: '$root/a.mkv',
                  name: 'a.mkv',
                  size: 1,
                  role: FileRole.video,
                  parsed: ParsedName(season: 1, episodes: [1], confidence: 0.9),
                ),
              ],
            ),
          ],
          unassigned: [
            ScanFile(
              path: '$root/ad.txt',
              name: 'ad.txt',
              size: 1,
              role: FileRole.junk,
            ),
            ScanFile(
              path: '/d/notes.pdf',
              name: 'notes.pdf',
              size: 1,
              role: FileRole.other,
            ),
          ],
        );

        final tmKeep = _PlanningTaskManager(
          scan,
          planOptions: const PlanOptions(deleteJunk: false),
        );
        await pumpPage(tester, const SizedBox(), tm: tmKeep);
        final id1 = await submitAndWait(tester, tmKeep);
        await pumpPage(tester, ReviewPage(taskId: id1.value), tm: tmKeep);
        expect(find.text('没归进任何作品，不会被整理'), findsOneWidget);
        await tapKey(tester, 'unassigned-link');
        expect(find.textContaining('整理时原样保留'), findsOneWidget);
        expect(find.text('将永久删除'), findsNothing);

        final tmDel = _PlanningTaskManager(
          scan,
          planOptions: const PlanOptions(deleteJunk: true),
        );
        await pumpPage(tester, const SizedBox(), tm: tmDel);
        final id2 = await submitAndWait(tester, tmDel);
        await pumpPage(tester, ReviewPage(taskId: id2.value), tm: tmDel);
        expect(find.text('其中 1 个垃圾文件将被永久删除'), findsOneWidget);
        await tapKey(tester, 'unassigned-link');
        expect(
          find.text('共 2 个未归类文件：其中 1 个已计划在整理时永久删除，其余原样保留。'),
          findsOneWidget,
        );
        expect(find.text('将永久删除'), findsOneWidget);
      },
    );
  });
}
