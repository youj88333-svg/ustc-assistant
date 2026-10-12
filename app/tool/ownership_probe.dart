import 'dart:convert';
import 'dart:io';

import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/platform/demo_directory.dart';

/// Local process-boundary experiment. Output is a fixed, non-sensitive protocol.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 2 ||
      !const ['hold', 'try'].contains(arguments.first)) {
    stdout.writeln('invalid');
    exitCode = 2;
    return;
  }
  DemoDirectory? directory;
  try {
    directory = await DemoDirectory.acquire(arguments[1]);
    stdout.writeln('ready');
    if (arguments.first == 'hold') {
      await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
    }
    await directory.release();
    stdout.writeln('released');
  } on AppFailure catch (failure) {
    stdout.writeln(switch (failure.code) {
      FailureCode.ownerConflict => 'conflict',
      FailureCode.unsafeDirectory => 'unsafe',
      FailureCode.ownershipLost => 'lost',
      _ => 'failed',
    });
    exitCode = 1;
  } catch (_) {
    stdout.writeln('failed');
    exitCode = 1;
  } finally {
    try {
      await directory?.release();
    } catch (_) {
      stderr.writeln('release_failed');
      exitCode = 1;
    }
  }
}
