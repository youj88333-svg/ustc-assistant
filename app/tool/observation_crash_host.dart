import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/platform/demo_directory.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/observation_assets.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';

/// Test-only entrypoint, compiled separately from lib/main.dart. No navigation.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final requested = Platform.environment['USTC_M1_CRASH_HOST_PATH'];
  final temp = p.windows.normalize(
    await Directory.systemTemp.resolveSymbolicLinks(),
  );
  if (requested == null ||
      !p.windows.isAbsolute(requested) ||
      !p.windows.isWithin(temp, requested) ||
      p.basename(requested) != 'crash-owned' ||
      !p.basename(p.dirname(requested)).startsWith('ustc_m1_native_test_')) {
    exit(2);
  }
  runApp(const MaterialApp(home: Scaffold(body: Text('M1 blank crash probe'))));
  final owner = await DemoDirectory.acquire(requested);
  final assets = ObservationAssets(owner);
  final path = await assets.register();
  final browser = NativeObservationBrowser();
  // Production policy is supplied only to configure retained controls. The
  // recoveryOnly native path stays about:blank and never navigates this target.
  await browser.open(
    session: 1,
    profilePath: path,
    target: ObservationTarget.jw(),
    recoveryOnly: true,
  );
  await File(
    p.join(owner.path, 'probe-ready'),
  ).writeAsString('ready', flush: true);
  await Completer<void>().future;
}
