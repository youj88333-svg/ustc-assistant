import 'dart:async';
import 'dart:io';

import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/data/demo_store.dart';
import 'package:ustc_assistant_m0/data/import_contract.dart';
import 'package:ustc_assistant_m0/platform/demo_directory.dart';
import 'package:ustc_assistant_m0/platform/native_database.dart';

/// Test child: the parent kills this exact executable at a transaction boundary.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 2 || !['before', 'after'].contains(arguments.first)) {
    exitCode = 2;
    return;
  }
  try {
    final owner = await DemoDirectory.acquire(arguments[1]);
    final clock = FixedClock(DateTime.utc(2026, 10, 9));
    final store = DemoStore(
      openDemoDatabase(owner),
      ownership: owner,
      clock: clock,
      onCheckpoint: (point) async {
        if (arguments.first == 'before' &&
            point == ImportCheckpoint.afterFirstWrite) {
          stdout.writeln('ready');
          await stdout.flush();
          // Deliberately neither commit/rollback nor orderly close here.
          await Completer<void>().future;
        }
      },
    );
    await store.initialize();
    final stamp = await store.beginJob();
    final start = DateTime.utc(2026, 10, 5);
    final events = [
      EventDraft(
        externalId: 'process-fake',
        title: '合成进程测试',
        startsAtUtc: start.add(const Duration(hours: 1)),
        endsAtUtc: start.add(const Duration(hours: 2)),
      ),
    ];
    final request = ImportRequest(
      stamp: stamp,
      operationId: stamp.jobId,
      rangeStartUtc: start,
      rangeEndUtc: start.add(const Duration(days: 7)),
      collectedAtUtc: clock.nowUtc,
      contentFingerprint: '',
      events: events,
    );
    await store.importSnapshot(
      ImportRequest(
        stamp: stamp,
        operationId: stamp.jobId,
        rangeStartUtc: request.rangeStartUtc,
        rangeEndUtc: request.rangeEndUtc,
        collectedAtUtc: request.collectedAtUtc,
        contentFingerprint: request.calculatedFingerprint,
        events: events,
      ),
    );
    if (arguments.first == 'after') {
      stdout.writeln('ready');
      await stdout.flush();
      await Completer<void>().future;
    }
    await store.close();
    await owner.release();
  } catch (_) {
    stdout.writeln('failed');
    exitCode = 1;
  }
}
