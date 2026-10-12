import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/data/demo_store.dart';
import 'package:ustc_assistant_m0/platform/demo_directory.dart';
import 'package:ustc_assistant_m0/platform/native_database.dart';

void main() {
  group('real Windows process interruption', () {
    final executable = p.join(
      Directory.current.path,
      'build',
      'transaction_probe_bundle',
      'bundle',
      'bin',
      'transaction_probe.exe',
    );
    setUpAll(() async {
      final compilerTemp = await Directory(
        p.join(Directory.current.path, 'build', 'compiler_temp'),
      ).create(recursive: true);
      final config =
          jsonDecode(
                await File('.dart_tool/package_config.json').readAsString(),
              )
              as Map<String, dynamic>;
      final flutter = Directory.fromUri(
        Uri.parse(config['flutterRoot'] as String),
      );
      final dart = p.join(
        flutter.path,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        'dart.exe',
      );
      // Dart AOT compiler currently fails to find its intermediate dill under
      // a non-ASCII TEMP path. Scope the workaround to this compiler process.
      final result = await Process.run(
        dart,
        [
          'build',
          'cli',
          '-t',
          'bin/transaction_probe.dart',
          '-o',
          'build/transaction_probe_bundle',
        ],
        environment: {'TEMP': compilerTemp.path, 'TMP': compilerTemp.path},
      ).timeout(const Duration(seconds: 60));
      expect(
        result.exitCode,
        0,
        reason: 'independent transaction child compilation',
      );
    });

    for (final mode in ['before', 'after']) {
      test('kill $mode commit and reopen the actual SQLite file', () async {
        final root = await Directory.systemTemp.createTemp('ustc_m0_tx_test_');
        final target = p.join(root.path, 'demo');
        Process? child;
        StreamIterator<String>? lines;
        DemoDirectory? owner;
        DemoStore? store;
        try {
          child = await Process.start(executable, [mode, target]);
          final errors = child.stderr.transform(utf8.decoder).join();
          lines = StreamIterator(
            child.stdout
                .transform(utf8.decoder)
                .transform(const LineSplitter()),
          );
          expect(
            await lines.moveNext().timeout(const Duration(seconds: 20)),
            isTrue,
          );
          expect(lines.current, 'ready');
          expect(child.kill(ProcessSignal.sigkill), isTrue);
          expect(
            await child.exitCode.timeout(const Duration(seconds: 10)),
            isNot(0),
          );
          expect(await errors, isEmpty);
          await lines.cancel();
          lines = null;

          owner = await DemoDirectory.acquire(target);
          store = DemoStore(
            openDemoDatabase(owner),
            ownership: owner,
            clock: FixedClock(DateTime.utc(2026, 10, 9)),
          );
          await store.initialize();
          final view = await store.readView();
          final expected = mode == 'before' ? 0 : 1;
          expect(view.events.length, expected);
          expect(view.importCount, expected);
          expect(view.auditCount, expected);
          expect(view.pendingFollowUps, expected);
          if (mode == 'after') {
            // The durable receipt replays without another audit or write.
            final replay = await store.replayLatest(await store.beginJob());
            expect(replay.replayed, isTrue);
            expect(replay.followUpPending, isTrue);
            await store.completePendingFollowUps();
            final retried = await store.readView();
            expect(retried.events.length, 1);
            expect(retried.importCount, 1);
            expect(retried.auditCount, 1);
            expect(retried.pendingFollowUps, 0);
          }
        } finally {
          if (child != null) {
            child.kill(ProcessSignal.sigkill);
            await child.exitCode.timeout(const Duration(seconds: 10));
          }
          await lines?.cancel();
          await store?.close();
          await owner?.release();
          final resolved = p.windows.normalize(
            await root.resolveSymbolicLinks(),
          );
          final temp = p.windows.normalize(
            await Directory.systemTemp.resolveSymbolicLinks(),
          );
          expect(p.windows.isWithin(temp, resolved), isTrue);
          expect(p.windows.basename(resolved), startsWith('ustc_m0_tx_test_'));
          await Directory(resolved).delete(recursive: true);
        }
      });
    }
  }, skip: !Platform.isWindows);
}
