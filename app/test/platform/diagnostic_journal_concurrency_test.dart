import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/platform/diagnostic_journal.dart';

void main() {
  test(
    'sequence selects the newest segment after cleaning a bad tail, then rotates the oldest',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final base = harness.clock.nowUtc;

      await harness.writeSegment(0, <String>[
        _row(0, base, DiagnosticEventName.applicationStart),
      ]);
      await harness.writeSegment(1, <String>[
        _row(1, base, DiagnosticEventName.applicationReady),
      ]);
      await harness.writeSegment(2, <String>[
        _row(2, base, DiagnosticEventName.applicationClosing),
      ], unterminatedTail: '{"untrusted":"TAIL_SENTINEL"');

      final rows = <String>[];
      var sequence = 3;
      var byteCount = 0;
      while (true) {
        final line = _row(sequence, base, DiagnosticEventName.logsExported);
        final lineBytes = utf8.encode('$line\n').length;
        if (byteCount + lineBytes > diagnosticSegmentBytes) break;
        rows.add(line);
        byteCount += lineBytes;
        sequence++;
      }
      expect(rows.length, greaterThan(diagnosticMaximumExportRecords));
      await harness.writeSegment(3, rows);

      // Give the oldest low-sequence segment the newest mtime. Sequence must
      // still select segment 3 as the append target.
      await File(
        harness.segmentPath(0),
      ).setLastModified(DateTime.now().add(const Duration(days: 2)));
      final journal = await harness.open();
      addTearDown(journal.close);
      expect(journal.diagnosticsView.invalid, 1);

      journal.record(
        const DiagnosticEvent(name: DiagnosticEventName.logsExported),
      );
      await journal.flush();

      final segment0 = await _readRecords(harness.segmentPath(0));
      final segment2 = await _readRecords(harness.segmentPath(2));
      final segment3 = await _readRecords(harness.segmentPath(3));
      expect(segment0.map((record) => record.sequence), [sequence]);
      expect(segment2.map((record) => record.sequence), [2]);
      expect(segment3.last.sequence, sequence - 1);
      expect(
        await File(harness.segmentPath(2)).readAsString(),
        isNot(contains('TAIL_SENTINEL')),
      );
      expect(journal.diagnosticsView.invalid, 1);
    },
  );

  test(
    'export and clear serialize, so old rows cannot be sanitized back',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final journal = await harness.open();
      addTearDown(journal.close);
      journal.record(
        const DiagnosticEvent(name: DiagnosticEventName.applicationStart),
      );
      await journal.flush();
      harness.checkedNames.clear();

      final exportFuture = journal.exportRecent();
      final clearFuture = journal.clear();
      final exportedBeforeClear = jsonDecode(await exportFuture) as Map;
      await clearFuture;

      expect(harness.checkedNames, <String>[
        '0',
        '1',
        '2',
        '3',
        '0',
        '1',
        '2',
        '3',
        '0',
      ]);
      final afterClear = jsonDecode(await journal.exportRecent()) as Map;
      expect(
        (exportedBeforeClear['records'] as List).map((row) => row['event']),
        ['applicationStart'],
      );
      expect((afterClear['records'] as List).map((row) => row['event']), [
        'logsCleared',
      ]);
    },
  );

  test(
    'close waits for a same-tick export and blocks later file access',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final journal = await harness.open();
      addTearDown(journal.close);
      harness.checkedNames.clear();

      final exporting = journal.exportRecent();
      final closing = journal.close();
      await Future.wait<Object?>(<Future<Object?>>[exporting, closing]);
      final countAfterClose = harness.checkedNames.length;
      expect(countAfterClose, 4);

      harness.ownershipHeld = false;
      await expectLater(
        journal.exportRecent(),
        throwsA(
          isA<DiagnosticsFailure>().having(
            (failure) => failure.code,
            'code',
            DiagnosticsFailureCode.closed,
          ),
        ),
      );
      await expectLater(
        journal.clear(),
        throwsA(
          isA<DiagnosticsFailure>().having(
            (failure) => failure.code,
            'code',
            DiagnosticsFailureCode.closed,
          ),
        ),
      );
      expect(harness.checkedNames.length, countAfterClose);
    },
  );

  test(
    'immediate close drains records before the owner can be released',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final first = await harness.open();
      first.record(
        const DiagnosticEvent(name: DiagnosticEventName.applicationReady),
      );
      await first.close();
      final checkedAfterClose = harness.checkedNames.length;
      harness.ownershipHeld = false;
      expect(harness.checkedNames.length, checkedAfterClose);

      harness.ownershipHeld = true;
      final restarted = await harness.open();
      addTearDown(restarted.close);
      final bundle = jsonDecode(await restarted.exportRecent()) as Map;
      final records = bundle['records'] as List;
      expect(records, hasLength(1));
      expect(records.single['event'], 'applicationReady');
      expect(records.single['sequence'], 0);
    },
  );

  test(
    'selection truncation is explicit and tool statuses map to safe outcomes',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final journal = await harness.open();
      addTearDown(journal.close);

      for (var start = 0; start < 1001; start += 100) {
        final end = (start + 100).clamp(0, 1001);
        for (var index = start; index < end; index++) {
          final status = index.isEven ? 'success' : 'partial';
          journal.record(
            DiagnosticEvent(
              name: DiagnosticEventName.toolFinished,
              tool: DiagnosticTool.query_agenda,
              outcome: diagnosticOutcome(status),
            ),
          );
        }
        await journal.flush();
      }

      expect(diagnosticOutcome('success'), DiagnosticOutcome.complete);
      expect(diagnosticOutcome('partial'), DiagnosticOutcome.truncated);
      final bundle = jsonDecode(await journal.exportRecent()) as Map;
      expect(bundle['selectionTruncated'], isTrue);
      expect(bundle['complete'], isFalse);
      final records = bundle['records'] as List;
      expect(records, hasLength(diagnosticMaximumExportRecords));
      expect(records.first['sequence'], 1);
      expect(records.last['sequence'], 1000);
      expect(records.map((row) => row['outcome']).toSet(), <String>{
        'complete',
        'truncated',
      });
      expect(records.map((row) => row['outcome']), isNot(contains('failure')));
    },
  );

  test(
    'retention across a clock rollback preserves persistent sequence order',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);
      final base = harness.clock.nowUtc;
      final boundary = base.subtract(const Duration(days: 7));

      await harness.writeSegment(0, <String>[
        _row(12, base, DiagnosticEventName.applicationReady),
      ]);
      await harness.writeSegment(1, <String>[
        _row(10, boundary, DiagnosticEventName.applicationStart),
      ]);
      await harness.writeSegment(3, <String>[
        _row(11, boundary, DiagnosticEventName.agentRunStarted),
      ]);
      await File(
        harness.segmentPath(0),
      ).setLastModified(DateTime.now().subtract(const Duration(days: 2)));
      await File(
        harness.segmentPath(1),
      ).setLastModified(DateTime.now().add(const Duration(days: 2)));
      await File(
        harness.segmentPath(3),
      ).setLastModified(DateTime.now().subtract(const Duration(days: 1)));

      harness.clock.set(base.subtract(const Duration(minutes: 1)));
      final journal = await harness.open();
      addTearDown(journal.close);
      journal.record(
        const DiagnosticEvent(name: DiagnosticEventName.applicationClosed),
      );
      await journal.flush();

      final bundle = jsonDecode(await journal.exportRecent()) as Map;
      final records = bundle['records'] as List;
      expect(records.map((row) => row['sequence']), [10, 11, 12, 13]);
      expect(records.map((row) => row['event']), [
        'applicationStart',
        'agentRunStarted',
        'applicationReady',
        'applicationClosed',
      ]);
      expect(bundle['invalid'], 0);
      expect(
        (await _readRecords(
          harness.segmentPath(0),
        )).map((record) => record.sequence),
        [12, 13],
      );
    },
  );
}

String _row(int sequence, DateTime atUtc, DiagnosticEventName eventName) =>
    DiagnosticRecord(
      atUtc: atUtc,
      sequence: sequence,
      event: DiagnosticEvent(name: eventName),
    ).encode();

Future<List<DiagnosticRecord>> _readRecords(String path) async {
  final lines = (await File(
    path,
  ).readAsString()).split('\n').where((line) => line.isNotEmpty);
  return lines.map(DiagnosticRecord.decode).toList();
}

final class _Harness {
  _Harness(this.root, this.directory)
    : clock = _MutableClock(DateTime.utc(2026, 10, 14, 10));

  final Directory root;
  final Directory directory;
  final _MutableClock clock;
  final List<String> checkedNames = <String>[];
  bool ownershipHeld = true;

  static Future<_Harness> create() async {
    final root = await Directory.systemTemp.createTemp(
      'diagnostic-journal-concurrency-',
    );
    final directory = Directory(p.join(root.path, 'diagnostics'));
    await directory.create();
    return _Harness(root, directory);
  }

  String segmentPath(int index) =>
      p.join(directory.path, DiagnosticJournal.segmentNames[index]);

  Future<void> writeSegment(
    int index,
    List<String> lines, {
    String? unterminatedTail,
  }) async {
    final text = lines.isEmpty ? '' : '${lines.join('\n')}\n';
    await File(segmentPath(index)).writeAsString(
      unterminatedTail == null ? text : '$text$unterminatedTail',
      flush: true,
    );
  }

  Future<DiagnosticJournal> open() => DiagnosticJournal.open(
    directoryPath: directory.path,
    ensureOwnership: () {
      if (!ownershipHeld) throw StateError('OWNER_RELEASED');
    },
    checkedPath: (filename) {
      checkedNames.add(
        filename.substring(
          'diagnostic-'.length,
          filename.length - '.jsonl'.length,
        ),
      );
      if (!DiagnosticJournal.segmentNames.contains(filename)) {
        throw StateError('UNEXPECTED_SEGMENT');
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

  void set(DateTime value) => _nowUtc = value.toUtc();
}
