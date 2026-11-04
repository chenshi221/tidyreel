import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/features/map/size_scanner.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

class _Denied extends MemoryStorageBackend {
  final StorageErrorCode code;
  _Denied(this.code) : super({'/G/书籍/a.mkv': 5, '/G/System/b.mkv': 7});

  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) async {
    if (dir == '/G/System') throw StorageException(code, 'denied');
    return super.list(dir, refresh: refresh);
  }
}

SizeScanner _scanner(StorageBackend b) =>
    SizeScanner(backend: b, organizedOf: (paths) async => <String>{});

void main() {
  test('an unreadable folder is skipped, the rest still counts', () async {
    final s = _scanner(_Denied(StorageErrorCode.busy));
    await s.scan('/G');
    expect(s.error, isNull);
    expect(s.isComplete('/G'), isTrue);
    expect(s.skipped.keys, ['/G/System']);
    expect(s.statsOfDir('/G').total, 5);
  });

  test('a lost connection still stops the count', () async {
    final s = _scanner(_Denied(StorageErrorCode.network));
    await s.scan('/G');
    expect(s.error, isNotNull);
    expect(s.isComplete('/G'), isFalse);
  });
}
