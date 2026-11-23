import 'package:test/test.dart';
import 'package:tidyreel_core/testing.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

class _NonRangeBackend implements StorageBackend {
  @override
  Future<List<RemoteEntry>> list(String dir, {bool refresh = false}) async =>
      const [];
  @override
  Future<void> mkdirs(String dir) async {}
  @override
  Future<void> rename(String path, String newName) async {}
  @override
  Future<void> renameMany(String dir, Map<String, String> names) async {}
  @override
  Future<void> move(String srcDir, String dstDir, List<String> names) async {}
  @override
  Future<void> remove(String dir, List<String> names) async {}
  @override
  Future<bool> exists(String path) async => true;
  @override
  Future<List<int>> read(String path) async => const [];
  @override
  Future<void> write(String path, List<int> bytes) async {}
  @override
  Future<void> ping() async {}
  @override
  Future<void> close() async {}
}

class _FlakyRangeBackend extends MemoryStorageBackend {
  int attempts = 0;
  final List<StorageErrorCode> failCodes;

  _FlakyRangeBackend(this.failCodes);

  @override
  Future<List<int>> readRange(String path, int start, int length) async {
    final idx = attempts++;
    if (idx < failCodes.length) {
      throw StorageException(failCodes[idx], 'fail #$idx');
    }
    return super.readRange(path, start, length);
  }
}

void main() {
  group('ThrottledBackend', () {
    test(
      'dynamic minIntervalProvider takes effect immediately on every request',
      () async {
        final fs = MemoryStorageBackend();
        await fs.write('/a.bin', [0, 1, 2, 3, 4, 5, 6, 7]);

        final clock = DateTime(2026, 1, 1, 12, 0, 0);
        var interval = const Duration(milliseconds: 200);
        final delays = <Duration>[];

        final be = ThrottledBackend(
          fs,
          minInterval: const Duration(milliseconds: 999),
          minIntervalProvider: () => interval,
          delay: (d) async => delays.add(d),
          now: () => clock,
        );

        // First call starts immediately at t=0.
        await be.exists('/a.bin');
        expect(delays, isEmpty);

        // Second call waits 200ms (slot at t+200ms).
        await be.exists('/a.bin');
        expect(delays, const [Duration(milliseconds: 200)]);

        // Increase interval dynamically to 500ms: next slot is t+200ms + 500ms = t+700ms.
        interval = const Duration(milliseconds: 500);
        await be.exists('/a.bin');
        expect(delays.last, const Duration(milliseconds: 700));

        // Drop interval to zero: bypasses waiting completely.
        interval = Duration.zero;
        await be.exists('/a.bin');
        expect(delays, hasLength(2));

        // Negative duration is treated safely as zero.
        interval = const Duration(milliseconds: -50);
        await be.exists('/a.bin');
        expect(delays, hasLength(2));
      },
    );

    test('readRange paces requests and retries transient errors', () async {
      final flaky = _FlakyRangeBackend([
        StorageErrorCode.rateLimited,
        StorageErrorCode.network,
      ]);
      await flaky.write('/video.mkv', [10, 20, 30, 40, 50]);

      final delays = <Duration>[];
      var clock = DateTime(2026, 1, 1, 12, 0, 0);
      final be = ThrottledBackend(
        flaky,
        minInterval: const Duration(milliseconds: 100),
        backoff: const [
          Duration(seconds: 1),
          Duration(seconds: 2),
          Duration(seconds: 4),
        ],
        delay: (d) async {
          delays.add(d);
          clock = clock.add(d);
        },
        now: () => clock,
      );

      final bytes = await be.readRange('/video.mkv', 1, 3);
      expect(bytes, [20, 30, 40]);
      expect(flaky.attempts, 3);
      // Two retries produced the 1s and 2s backoff delays.
      expect(delays, const [Duration(seconds: 1), Duration(seconds: 2)]);
    });

    test(
      'readRange fails immediately without retry on non-range inner backend',
      () async {
        final delays = <Duration>[];
        final be = ThrottledBackend(
          _NonRangeBackend(),
          minInterval: const Duration(milliseconds: 100),
          delay: (d) async => delays.add(d),
        );

        await expectLater(
          be.readRange('/a.mkv', 0, 16),
          throwsA(
            isA<StorageException>().having(
              (e) => e.code,
              'code',
              StorageErrorCode.other,
            ),
          ),
        );
        expect(delays, isEmpty);
      },
    );
  });
}
