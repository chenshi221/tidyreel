import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'data/bootstrap.dart';
import 'data/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: '理片 Tidyreel',
      size: Size(1280, 800),
      minimumSize: Size(1100, 700),
      center: true,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  final boot = await Bootstrap.open();
  runApp(
    ProviderScope(
      overrides: [bootstrapProvider.overrideWithValue(boot)],
      child: const TidyreelApp(),
    ),
  );
}
