import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/platform/diagnostic_journal.dart';

void main() {
  test(
    'validated records survive restart and export in the fixed envelope',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final first = await harness.open();
      final trace = first.newTrace();
      expect(trace.value, matches(RegExp(r'^[a-f0-9]{32}$')));
      first.record(
        DiagnosticEvent(
          name: DiagnosticEventName.agentRunFinished,
          trace: trace,
          outcome: DiagnosticOutcome.complete,
          toolCalls: 2,
        ),
      );
      await first.flush();
      await first.close();

      final restarted = await harness.open();
      addTearDown(restarted.close);
      final bundle =
          jsonDecode(await restarted.exportRecent()) as Map<String, dynamic>;
      expect(bundle.keys.toSet(), {
        'kind',
        'exportedAtUtc',
        'retentionDays',
        'versions',
        'coverage',
        'selectionTruncated',
        'complete',
        'dropped',
        'invalid',
        'records',
      });
      expect(bundle['kind'], 'ustc-diagnostics-export-v1');
      expect(bundle['complete'], isTrue);
      expect((bundle['records'] as List).single['trace'], trace.value);
      expect((bundle['records'] as List).single['toolCalls'], 2);
    },
  );

  test(
    'rotates fixed bounded segments and reports overwritten coverage',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final seed = DiagnosticRecord(
        atUtc: harness.clock.nowUtc,
        event: const DiagnosticEvent(name: DiagnosticEventName.logsExported),
      ).encode();
      final rowBytes = utf8.encode('$seed\n').length;
      final rowsPerSegment = diagnosticSegmentBytes ~/ rowBytes;
      final fullSegment =
          '${List<String>.filled(rowsPerSegment, seed).join('\n')}\n';
      for (final name in DiagnosticJournal.segmentNames) {
        await File(
          p.join(harness.directory.path, name),
        ).writeAsString(fullSegment, flush: true);
      }

      final journal = await harness.open();
      addTearDown(journal.close);
      expect(journal.diagnosticsView.available, isTrue);
      journal.record(
        const DiagnosticEvent(name: DiagnosticEventName.logsExported),
      );
      await journal.flush();

      final bundle =
          jsonDecode(await journal.exportRecent()) as Map<String, dynamic>;
      expect(bundle['complete'], isFalse);
      expect(
        (bundle['records'] as List),
        hasLength(diagnosticMaximumExportRecords),
      );
      final segmentLengths = await Future.wait(
        DiagnosticJournal.segmentNames.map(
          (name) => File(p.join(harness.directory.path, name)).length(),
        ),
      );
      expect(segmentLengths.any((length) => length < 500), isTrue);
      expect(
        segmentLengths.every((length) => length <= diagnosticSegmentBytes),
        isTrue,
      );
    },
  );

  test(
    'expires old rows and drops malformed, extra-field, and unterminated rows',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final recent = DiagnosticRecord(
        atUtc: harness.clock.nowUtc.subtract(const Duration(hours: 1)),
        event: const DiagnosticEvent(
          name: DiagnosticEventName.applicationStart,
        ),
      ).encode();
      final expired = DiagnosticRecord(
        atUtc: harness.clock.nowUtc.subtract(const Duration(days: 8)),
        event: const DiagnosticEvent(
          name: DiagnosticEventName.applicationClosed,
        ),
      ).encode();
      final extra = jsonEncode(<String, Object?>{
        ...DiagnosticRecord(
          atUtc: harness.clock.nowUtc,
          event: const DiagnosticEvent(
            name: DiagnosticEventName.applicationReady,
          ),
        ).toMap(),
        'private': 'PRIVATE_SENTINEL',
      });
      await File(
        p.join(harness.directory.path, DiagnosticJournal.segmentNames.first),
      ).writeAsString('$expired\n$recent\n$extra\n{"private":"TAIL_SENTINEL"');

      final journal = await harness.open();
      addTearDown(journal.close);
      final exported = await journal.exportRecent();
      final bundle = jsonDecode(exported) as Map<String, dynamic>;
      expect(bundle['invalid'], 2);
      expect(exported, isNot(contains('PRIVATE_SENTINEL')));
      expect(exported, isNot(contains('TAIL_SENTINEL')));
      final records = bundle['records'] as List;
      expect(records, hasLength(1));
      expect(records.single['event'], 'applicationStart');
      final sanitized = await File(
        p.join(harness.directory.path, DiagnosticJournal.segmentNames.first),
      ).readAsString();
      expect(sanitized, contains('applicationStart'));
      expect(sanitized, isNot(contains('PRIVATE_SENTINEL')));
    },
  );

  test('retention is rechecked on a later write', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final old = DiagnosticRecord(
      atUtc: harness.clock.nowUtc,
      event: const DiagnosticEvent(name: DiagnosticEventName.applicationStart),
    ).encode();
    await File(
      p.join(harness.directory.path, DiagnosticJournal.segmentNames.first),
    ).writeAsString('$old\n');
    final journal = await harness.open();
    addTearDown(journal.close);
    harness.clock.advance(const Duration(days: 8));
    journal.record(
      const DiagnosticEvent(name: DiagnosticEventName.applicationReady),
    );
    await journal.flush();
    final bundle =
        jsonDecode(await journal.exportRecent()) as Map<String, dynamic>;
    expect((bundle['records'] as List).map((row) => row['event']), [
      'applicationReady',
    ]);
  });

  test(
    'queue is bounded and dropped entries make the export incomplete',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final journal = await harness.open();
      addTearDown(journal.close);
      for (var index = 0; index < diagnosticQueueLimit + 7; index++) {
        journal.record(
          const DiagnosticEvent(name: DiagnosticEventName.toolStarted),
        );
      }
      await journal.flush();
      final bundle =
          jsonDecode(await journal.exportRecent()) as Map<String, dynamic>;
      expect(bundle['dropped'], greaterThan(0));
      expect(bundle['complete'], isFalse);
      expect(
        (bundle['records'] as List).length,
        lessThanOrEqualTo(diagnosticQueueLimit),
      );
    },
  );

  test(
    'write failure and lost ownership stay local and never expose exception text',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final journal = await harness.open();
      harness.failPath = true;
      journal.record(
        const DiagnosticEvent(name: DiagnosticEventName.applicationStart),
      );
      await journal.flush();
      expect(journal.diagnosticsView.available, isFalse);
      expect(journal.diagnosticsView.dropped, greaterThan(0));
      await expectLater(
        journal.exportRecent(),
        throwsA(
          isA<DiagnosticsFailure>().having(
            (failure) => failure.code,
            'code',
            DiagnosticsFailureCode.unavailable,
          ),
        ),
      );

      harness.ownershipHeld = false;
      final refused = await harness.open();
      addTearDown(refused.close);
      expect(refused.diagnosticsView.available, isFalse);
      refused.record(
        const DiagnosticEvent(name: DiagnosticEventName.applicationStart),
      );
      expect(refused.diagnosticsView.dropped, 1);
    },
  );

  test(
    'clear removes the fixed segments, resets counters, and records its event',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final journal = await harness.open();
      addTearDown(journal.close);
      journal.record(
        const DiagnosticEvent(name: DiagnosticEventName.applicationStart),
      );
      await journal.flush();
      await journal.clear();
      final bundle =
          jsonDecode(await journal.exportRecent()) as Map<String, dynamic>;
      expect(bundle['dropped'], 0);
      expect(bundle['invalid'], 0);
      expect((bundle['records'] as List).map((row) => row['event']), [
        'logsCleared',
      ]);
    },
  );

  test(
    'close is idempotent and record after close only increments dropped',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final journal = await harness.open();
      journal.record(
        const DiagnosticEvent(name: DiagnosticEventName.applicationStart),
      );
      await journal.close();
      await journal.close();
      journal.record(
        const DiagnosticEvent(name: DiagnosticEventName.applicationClosed),
      );
      expect(journal.diagnosticsView.available, isFalse);
      expect(journal.diagnosticsView.dropped, 1);
      await expectLater(
        journal.exportRecent(),
        throwsA(isA<DiagnosticsFailure>()),
      );
    },
  );
}

final class _Harness {
  _Harness(this.root, this.directory)
    : clock = _MutableClock(DateTime.utc(2026, 10, 14, 10));

  final Directory root;
  final Directory directory;
  final _MutableClock clock;
  bool ownershipHeld = true;
  bool failPath = false;

  static Future<_Harness> create() async {
    final root = await Directory.systemTemp.createTemp('diagnostic-journal-');
    final directory = Directory(p.join(root.path, 'diagnostics'));
    await directory.create();
    return _Harness(root, directory);
  }

  Future<DiagnosticJournal> open() => DiagnosticJournal.open(
    directoryPath: directory.path,
    ensureOwnership: () {
      if (!ownershipHeld) throw StateError('PRIVATE_OWNERSHIP_ERROR');
    },
    checkedPath: (filename) {
      if (failPath) throw StateError('PRIVATE_PATH_ERROR');
      if (!DiagnosticJournal.segmentNames.contains(filename)) {
        throw StateError('PRIVATE_FILENAME_ERROR');
      }
      return p.join(directory.path, filename);
    },
    clock: clock,
  );

  Future<void> dispose() async {
    if (await root.exists()) await root.delete(recursive: true);
  }
}

final class _MutableClock implements AppClock {
  _MutableClock(this._nowUtc);
  DateTime _nowUtc;

  @override
  DateTime get nowUtc => _nowUtc;

  void advance(Duration duration) => _nowUtc = _nowUtc.add(duration);
}
