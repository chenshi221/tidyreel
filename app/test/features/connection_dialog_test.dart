import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/data/providers.dart';
import 'package:tidyreel/features/sources/connection_dialog.dart';
import 'package:tidyreel/features/sources/sources_page.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import 'helpers.dart';

void main() {
  group('EndpointParts', () {
    test('splits a full URL', () {
      final p = EndpointParts.parse('https://192.168.1.10:5244/dav/');
      expect(p.scheme, 'https');
      expect(p.host, '192.168.1.10');
      expect(p.port, '5244');
      expect(p.path, '/dav');
    });

    test('accepts bare host and host:port', () {
      expect(EndpointParts.parse('nas.local').host, 'nas.local');
      expect(EndpointParts.parse('nas.local').scheme, 'http');
      expect(EndpointParts.parse('nas.local:8080').port, '8080');
    });

    test('compose normalizes slashes and omits empty parts', () {
      expect(
        const EndpointParts(host: 'nas', port: '5244', path: 'dav/').compose(),
        'http://nas:5244/dav',
      );
      expect(const EndpointParts(host: 'nas').compose(), 'http://nas');
      expect(
        const EndpointParts(
          scheme: 'https',
          host: ' a.b ',
          path: '//x//y/',
        ).compose(),
        'https://a.b/x/y',
      );
    });

    test('round-trips', () {
      for (final url in [
        'http://127.0.0.1:5244',
        'https://nas.example.com/dav',
        'http://10.0.0.2:8080/remote.php/dav',
      ]) {
        expect(EndpointParts.parse(url).compose(), url);
      }
    });
  });

  testWidgets('editing prefills the saved password and keeps it', (
    tester,
  ) async {
    final (_, c) = await pumpPage(tester, const SourcesPage());
    const id = ConnectionId('demo-alist');
    c.read(connectionPasswordsProvider.notifier).set({id: 's3cret'});
    await tester.pump();

    await tester.tap(find.byTooltip('更多').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    String field(String label) => tester
        .widget<TextField>(find.widgetWithText(TextField, label))
        .controller!
        .text;
    expect(field('主机 / IP'), 'nas.local');
    expect(field('端口'), '5244');
    final pw = tester.widget<TextField>(find.widgetWithText(TextField, '密码'));
    expect(pw.controller!.text, 's3cret');
    expect(pw.obscureText, isTrue);
    await tester.tap(find.byTooltip('显示密码'));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '密码'))
          .obscureText,
      isFalse,
    );

    await tester.enterText(find.widgetWithText(TextField, '名称'), '新名字');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('新名字'), findsWidgets); // row + favorite
    expect(c.read(connectionPasswordsProvider)[id], 's3cret');
    expect(
      c.read(connectionsProvider).firstWhere((e) => e.id == id).endpoint,
      'http://nas.local:5244',
    );
  });

  testWidgets('WebDAV gets /dav, pasted URL is split, test connection', (
    tester,
  ) async {
    await pumpPage(tester, const SourcesPage());
    await tester.tap(find.text('添加连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('WebDAV'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '路径'))
          .controller!
          .text,
      '/dav',
    );

    await tester.enterText(
      find.widgetWithText(TextField, '主机 / IP'),
      'https://10.0.0.5:5245/dav',
    );
    await tester.pump();
    expect(find.text('https://10.0.0.5:5245/dav'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, '名称'), 'D');
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.text('连接成功'), findsOneWidget); // demo backend
  });

  testWidgets('bad port is rejected', (tester) async {
    await pumpPage(tester, const SourcesPage());
    await tester.tap(find.text('添加连接'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '名称'), 'X');
    await tester.enterText(find.widgetWithText(TextField, '主机 / IP'), 'nas');
    await tester.enterText(find.widgetWithText(TextField, '端口'), '99999');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('端口应为 1–65535'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('delete asks for confirmation', (tester) async {
    final (_, c) = await pumpPage(tester, const SourcesPage());
    await tester.tap(find.byTooltip('更多').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除连接'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(c.read(connectionsProvider), hasLength(2));

    await tester.tap(find.byTooltip('更多').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(c.read(connectionsProvider), hasLength(1));
  });
}
