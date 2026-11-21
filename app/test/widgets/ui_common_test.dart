import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/ui/theme.dart';
import 'package:tidyreel/ui/tokens.dart';
import 'package:tidyreel/ui/widgets.dart';
import 'package:tidyreel/widgets/common.dart';

void main() {
  test('Palette.copyWith copies overridden fields and keeps the rest', () {
    final p = Palette.light.copyWith(
      accent: const Color(0xFF112233),
      canvas: const Color(0xFF445566),
    );
    expect(p.accent, const Color(0xFF112233));
    expect(p.canvas, const Color(0xFF445566));
    expect(p.panel, Palette.light.panel);
    expect(p.text, Palette.light.text);
  });

  test('seasonColor uses lighter high-contrast hues in dark mode', () {
    for (var s = 0; s <= 7; s++) {
      final light = seasonColor(s, Brightness.light);
      final dark = seasonColor(s, Brightness.dark);
      expect(dark, isNot(light));
      expect(dark.computeLuminance(), greaterThan(light.computeLuminance()));
    }
    // Backward-compatible 1-arg call defaults to light.
    expect(seasonColor(1), seasonColor(1, Brightness.light));
  });

  test('pathBasename extracts last segment and handles root/empty', () {
    expect(pathBasename('/a/b/file.mkv'), 'file.mkv');
    expect(pathBasename('/a/b/folder/'), 'folder');
    expect(pathBasename('/'), '根目录');
    expect(pathBasename(''), '根目录');
    expect(pathBasename('', empty: 'fallback'), 'fallback');
    expect(pathBasename(r'C:\Media\Movie.mkv'), 'Movie.mkv');
  });

  test('tmdbImage supports optional custom baseUrl', () {
    expect(tmdbImage('/abc.jpg'), 'https://image.tmdb.org/t/p/w185/abc.jpg');
    expect(
      tmdbImage('/abc.jpg', 'w342'),
      'https://image.tmdb.org/t/p/w342/abc.jpg',
    );
    expect(
      tmdbImage('/abc.jpg', 'w780', 'https://img.example.com/t/p/'),
      'https://img.example.com/t/p/w780/abc.jpg',
    );
  });

  testWidgets('MacSwitch uses canvas thumbColor for dark mode contrast', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(body: MacSwitch(value: true, onChanged: (_) {})),
      ),
    );
    final sw = tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch));
    expect(sw.activeTrackColor, Palette.dark.text);
    expect(sw.thumbColor, Palette.dark.canvas);
  });

  testWidgets(
    'confirmPermanentDelete lists paths in MacSheet and truncates >50',
    (tester) async {
      final paths = [for (var i = 1; i <= 55; i++) '/下载/ad_$i.txt'];
      bool? confirmed;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () async => confirmed = await confirmPermanentDelete(
                  ctx,
                  paths.length,
                  paths: paths,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(MacSheet), findsOneWidget);
      expect(find.text('永久删除 55 个文件？'), findsOneWidget);
      expect(find.text('ad_1.txt'), findsOneWidget);
      expect(find.text('+5 个更多文件'), findsOneWidget);
      await tester.tap(find.text('删除并整理'));
      await tester.pumpAndSettle();
      expect(confirmed, isTrue);
    },
  );
}
