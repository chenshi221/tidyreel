import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/data/bootstrap.dart';

void main() {
  test('secrets survive reopening (e.g. after reinstalling the app)', () async {
    final dir = Directory.systemTemp.createTempSync('tidyreel-secrets');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/secrets.json');

    final a = await SecretStore.open(file);
    await a.write('conn:c1', 'pw');
    await a.write('tmdb_api_key', 'k');
    await a.write('tmdb_api_key', '');

    final b = await SecretStore.open(file);
    expect(b.read('conn:c1'), 'pw');
    expect(b.read('tmdb_api_key'), isNull);
  });
}
