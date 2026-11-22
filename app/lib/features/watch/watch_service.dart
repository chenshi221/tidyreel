import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/watch_rules_store.dart';

/// Lightweight watch mode service (local Directory.watch + remote polling; no
/// webhook). Implemented in full by Wave 2 Worker D (`app-health-watch`).
class WatchService {
  void syncRules(List<WatchRule> rules) {}

  Future<void> triggerNow(String ruleId) async {}

  void dispose() {}
}

final watchServiceProvider = Provider<WatchService>((ref) {
  final svc = WatchService();
  ref.onDispose(svc.dispose);
  return svc;
});
