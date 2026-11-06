import 'package:test/test.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

void main() {
  test('isPrivateHost: LAN, Tailscale and local names skip the proxy', () {
    for (final h in [
      '100.95.147.79', // Tailscale
      '192.168.1.10',
      '10.0.0.5',
      '172.20.1.1',
      '127.0.0.1',
      'nas',
      'nas.local',
      'box.tail1234.ts.net',
      '[fd7a:115c:a1e0::1]',
    ]) {
      expect(isPrivateHost(h), isTrue, reason: h);
    }
    for (final h in [
      'api.themoviedb.org',
      '8.8.8.8',
      '100.200.1.1',
      '172.32.0.1',
    ]) {
      expect(isPrivateHost(h), isFalse, reason: h);
    }
  });
}
