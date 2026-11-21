import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tidyreel_core/tidyreel_core.dart' show smbBackend;
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'data/bootstrap.dart';
import 'data/providers.dart';
import 'data/smb_backend.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  smbBackend = SmbBackend.new;
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      title: '理片 Tidyreel',
      size: const Size(1280, 800),
      minimumSize: const Size(1100, 700),
      center: true,
      // macOS: content runs under the title bar and the traffic lights sit on
      // the sidebar, like Finder / Notes. Windows keeps its native frame.
      titleBarStyle: Platform.isMacOS ? TitleBarStyle.hidden : null,
      windowButtonVisibility: Platform.isMacOS ? true : null,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  final boot = await Bootstrap.open();
  var closed = false;
  Future<void> shutdown() async {
    if (closed) return;
    closed = true;
    boot.tmdbCache?.flushSync();
    await boot.db.close();
  }

  AppLifecycleListener(
    onExitRequested: () async {
      await shutdown();
      return AppExitResponse.exit;
    },
    onDetach: () => unawaited(shutdown()),
  );
  runApp(
    ProviderScope(
      overrides: [
        bootstrapProvider.overrideWith((ref) {
          ref.onDispose(() => unawaited(shutdown()));
          return boot;
        }),
      ],
      child: const TidyreelApp(),
    ),
  );
}
