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
    'picker records only fixed outcomes and a bounded selected count',
    () async {
      final diagnostics = _RecordingDiagnostics();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'pickImages');
        return [
          Uint8List.fromList([1, 2, 3]),
        ];
      });

      final images = await AndroidFileAccess(
        diagnostics: diagnostics,
      ).pickImages();
      expect(images.single, [1, 2, 3]);
      expect(diagnostics.events.map((event) => event.outcome), [
        DiagnosticOutcome.started,
        DiagnosticOutcome.complete,
      ]);
      expect(diagnostics.events.last.name, DiagnosticEventName.imageInputStage);
      expect(diagnostics.events.last.stage, DiagnosticStage.imagePicker);
      expect(diagnostics.events.last.count, 1);

      diagnostics.events.clear();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => <Uint8List>[],
      );
      expect(
        await AndroidFileAccess(diagnostics: diagnostics).pickImages(),
        isEmpty,
      );
      expect(diagnostics.events.map((event) => event.outcome), [
        DiagnosticOutcome.started,
        DiagnosticOutcome.cancelled,
      ]);
      expect(diagnostics.events.last.count, 0);

      diagnostics.events.clear();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        _,
      ) async {
        return List.generate(
          AgentImage.maximumCount + 1,
          (_) => Uint8List.fromList([1]),
        );
      });
      await expectLater(
        AndroidFileAccess(diagnostics: diagnostics).pickImages(),
        throwsA(isA<AgentFailure>()),
      );
      expect(diagnostics.events.last.outcome, DiagnosticOutcome.failure);
      expect(diagnostics.events.last.count, AgentImage.maximumCount);
    },
  );

  test(
    'native picker codes map through a closed diagnostic vocabulary',
    () async {
      const cases =
          <(String, AgentFailureCode, DiagnosticOutcome, DiagnosticCode)>[
            (
              'cancelled',
              AgentFailureCode.cancelled,
              DiagnosticOutcome.cancelled,
              DiagnosticCode.cancelled,
            ),
            (
              'timeout',
              AgentFailureCode.timeout,
              DiagnosticOutcome.failure,
              DiagnosticCode.timeout,
            ),
            (
              'busy',
              AgentFailureCode.busy,
              DiagnosticOutcome.failure,
              DiagnosticCode.busy,
            ),
            (
              'unavailable',
              AgentFailureCode.toolUnavailable,
              DiagnosticOutcome.failure,
              DiagnosticCode.toolUnavailable,
            ),
            (
              'resource_limit',
              AgentFailureCode.resourceLimit,
              DiagnosticOutcome.failure,
              DiagnosticCode.resourceLimit,
            ),
            (
              'image_rejected',
              AgentFailureCode.invalidInput,
              DiagnosticOutcome.failure,
              DiagnosticCode.invalidInput,
            ),
            (
              'read_failed',
              AgentFailureCode.imageRejected,
              DiagnosticOutcome.failure,
              DiagnosticCode.imageReadFailed,
            ),
            (
              'io_failed',
              AgentFailureCode.imageRejected,
              DiagnosticOutcome.failure,
              DiagnosticCode.imageReadFailed,
            ),
            (
              'private-provider-code',
              AgentFailureCode.imageRejected,
              DiagnosticOutcome.failure,
              DiagnosticCode.unknown,
            ),
          ];

      for (final (platformCode, failureCode, outcome, diagnosticCode)
          in cases) {
        final diagnostics = _RecordingDiagnostics();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          _,
        ) async {
          throw PlatformException(
            code: platformCode,
            message: 'content://private/personal-photo.png',
            details: {'path': r'E:\private\personal-photo.png'},
          );
        });

        await expectLater(
          AndroidFileAccess(diagnostics: diagnostics).pickImages(),
          throwsA(
            isA<AgentFailure>().having(
              (failure) => failure.code,
              'closed failure code',
              failureCode,
            ),
          ),
        );
        final event = diagnostics.events.last;
        expect(event.name, DiagnosticEventName.imageInputStage);
        expect(event.stage, DiagnosticStage.imagePicker);
        expect(event.outcome, outcome);
        expect(event.code, diagnosticCode);
        final safeRecord = DiagnosticRecord(
          atUtc: DateTime.utc(2026, 10, 21),
          event: event,
        ).encode();
        if (diagnosticCode == DiagnosticCode.unknown) {
          expect(safeRecord, isNot(contains(platformCode)));
        }
        expect(safeRecord, isNot(contains('content://private')));
        expect(safeRecord, isNot(contains('personal-photo')));
        expect(safeRecord, isNot(contains(r'E:\private')));
      }
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

final class _RecordingDiagnostics implements DiagnosticsPort {
  final events = <DiagnosticEvent>[];

  @override
  DiagnosticsView get diagnosticsView => const DiagnosticsView(available: true);

  @override
  DiagnosticTrace newTrace() =>
      DiagnosticTrace('00000000000000000000000000000000');

  @override
  void record(DiagnosticEvent event) => events.add(event);

  @override
  Future<void> flush() async {}

  @override
  Future<String> exportRecent() async => '';

  @override
  Future<void> clear() async => events.clear();

  @override
  Future<void> close() async {}
}
