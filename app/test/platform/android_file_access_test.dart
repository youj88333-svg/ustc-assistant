import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/platform/android_file_access.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ustc_assistant/files_v1');
  const files = AndroidFileAccess();
  tearDown(
    () =>
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );

  test(
    'picker uses only the fixed method and bounded bytes, including cancel',
    () async {
      var cancelled = false;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'pickImages');
        expect(call.arguments, {'maximumCount': 3});
        return cancelled
            ? []
            : [
                Uint8List.fromList([1, 2, 3]),
              ];
      });
      expect((await files.pickImages()).single, [1, 2, 3]);
      cancelled = true;
      expect(await files.pickImages(), isEmpty);
    },
  );

  test(
    'unexpected URI, count, type, size and native errors are closed failures',
    () async {
      for (final response in <Object?>[
        'content://synthetic/path',
        [1],
        [Uint8List(0)],
        List.generate(4, (_) => Uint8List(1)),
        [Uint8List(AndroidFileAccess.maximumOriginalBytes + 1)],
      ]) {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (_) async => response,
        );
        await expectLater(files.pickImages(), throwsA(isA<AgentFailure>()));
      }
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        _,
      ) async {
        throw PlatformException(
          code: 'io_failed',
          message: 'synthetic private provider detail',
        );
      });
      await expectLater(
        files.pickImages(),
        throwsA(
          isA<AgentFailure>().having(
            (error) => error.toString(),
            'safe error',
            isNot(contains('private')),
          ),
        ),
      );
    },
  );

  test(
    'SAF receives only a reconstructed diagnostic bundle; cancellation is false',
    () async {
      var saved = true;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'saveDiagnosticLog');
        final args = call.arguments as Map;
        expect(args.keys, ['contents']);
        expect(jsonDecode(args['contents'] as String), _bundle());
        return saved;
      });
      expect(await files.saveDiagnosticLog(jsonEncode(_bundle())), isTrue);
      saved = false;
      expect(await files.saveDiagnosticLog(jsonEncode(_bundle())), isFalse);
    },
  );

  test(
    'private fields and malformed diagnostic envelopes never reach native',
    () async {
      var calls = 0;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        _,
      ) async {
        calls++;
        return true;
      });
      final unsafe = [
        {..._bundle(), 'account': 'synthetic-account'},
        {
          ..._bundle(),
          'versions': {
            ...const DiagnosticVersions().toSafeMap(),
            'revision': 'private-name',
          },
        },
        {
          ..._bundle(),
          'records': [
            {'message': 'synthetic secret'},
          ],
        },
        {..._bundle(), 'retentionDays': 365},
        {..._bundle(), 'dropped': -1},
      ];
      for (final bundle in unsafe) {
        await expectLater(
          files.saveDiagnosticLog(jsonEncode(bundle)),
          throwsA(isA<DiagnosticsFailure>()),
        );
      }
      await expectLater(
        files.saveDiagnosticLog(
          'x' * (AndroidFileAccess.maximumExportBytes + 1),
        ),
        throwsA(isA<DiagnosticsFailure>()),
      );
      expect(calls, 0);
    },
  );

  test(
    'startup-only diagnostics retain their limited coverage during export',
    () {
      final bundle = {
        ..._bundle(),
        'coverage': 'startup_error_only',
        'complete': false,
      };
      final saved =
          jsonDecode(validateDiagnosticExport(jsonEncode(bundle))) as Map;
      expect(saved['coverage'], 'startup_error_only');
      expect(saved['complete'], false);
    },
  );
}

Map<String, Object?> _bundle() => {
  'kind': 'ustc-diagnostics-export-v1',
  'exportedAtUtc': '2026-10-16T00:00:00.000Z',
  'retentionDays': 7,
  'versions': const DiagnosticVersions().toSafeMap(),
  'coverage': 'retained_recent_events',
  'selectionTruncated': false,
  'complete': true,
  'dropped': 0,
  'invalid': 0,
  'records': [
    DiagnosticRecord(
      atUtc: DateTime.utc(2026, 10, 16),
      event: const DiagnosticEvent(name: DiagnosticEventName.applicationStart),
    ).toMap(),
  ],
};
