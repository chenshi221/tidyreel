// The SMB backend against a real share. Skipped unless
// SMB_TEST=smb://host[:port]/share,user,password points at a scratch share.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/data/smb_backend.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

Matcher throwsStorage(StorageErrorCode code) =>
    throwsA(isA<StorageException>().having((e) => e.code, 'code', code));

void main() {
  final env = Platform.environment['SMB_TEST'];
  SmbBackend backend(String endpoint, String user, String password) =>
      SmbBackend(
        ConnectionConfig(
          id: const ConnectionId('smb'),
          name: 'smb',
          type: ConnectionType.smb,
          endpoint: endpoint,
          username: user,
        ),
        Credentials(password: password),
      );

  test('SMB backend: the storage contract essentials', () async {
    final [url, user, password] = env!.split(',');
    final dir = 'tidyreel-test-$pid';
    final root = backend(url, user, password);
    await root.mkdirs('/$dir');
    addTearDown(() => root.remove('/', [dir]));
    final be = backend('$url/$dir', user, password);

    await be.write('/下载/示例 [1080p]/第01集.mkv', utf8.encode('video'));
    await be.write('/下载/示例 [1080p]/RARBG.txt', [1]);
    expect(
      {for (final e in await be.list('/下载/示例 [1080p]')) e.name: e.size},
      {'第01集.mkv': 5, 'RARBG.txt': 1},
    );
    await expectLater(
      be.write('/下载/示例 [1080p]/RARBG.txt', [2]),
      throwsStorage(StorageErrorCode.alreadyExists),
    );
    await be.mkdirs('/库/示例 (2024)/Season 01');
    await be.mkdirs('/库/示例 (2024)/Season 01');
    await be.rename('/下载/示例 [1080p]/第01集.mkv', '示例.S01E01.mkv');
    await expectLater(
      be.rename('/下载/示例 [1080p]/示例.S01E01.mkv', 'RARBG.txt'),
      throwsStorage(StorageErrorCode.alreadyExists),
    );
    await be.move('/下载/示例 [1080p]', '/库/示例 (2024)/Season 01', [
      '示例.S01E01.mkv',
    ]);
    expect(
      utf8.decode(await be.read('/库/示例 (2024)/Season 01/示例.S01E01.mkv')),
      'video',
    );
    await be.remove('/', ['下载']);
    expect(await be.exists('/下载'), isFalse);
    await expectLater(
      be.list('/nope'),
      throwsStorage(StorageErrorCode.notFound),
    );
    await be.ping();
    await expectLater(
      backend(url, user, 'wrong').ping(),
      throwsStorage(StorageErrorCode.unauthorized),
    );
  }, skip: env == null ? 'set SMB_TEST to run against a real share' : false);
}
