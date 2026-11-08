import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/platform/android_file_access.dart'
    show validateDiagnosticExport;
import 'package:ustc_assistant_m0/platform/ios_diagnostic_export.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ustc_assistant/diagnostics_v1');

  tearDown(
    () =>
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );

  test(
    'sends only the rebuilt JSON and preserves explicit success or cancel',
    () async {
      final calls = <MethodCall>[];
      var reply = true;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return reply;
      });
      final exporter = IOSDiagnosticExport(channel: channel);
      final source = JsonEncoder.withIndent('  ').convert(_bundle());

      expect(await exporter.saveDiagnosticLog(source), isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'saveDiagnosticLog');
      expect(calls.single.arguments, {
        'contents': validateDiagnosticExport(source),
      });
      expect(
        (jsonDecode(calls.single.arguments['contents'] as String) as Map).keys,
        unorderedEquals({
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
        }),
      );

      reply = false;
      expect(await exporter.saveDiagnosticLog(source), isFalse);
    },
  );

  test('rejects unsafe input before invoking the native bridge', () async {
    var calls = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls++;
      return true;
    });
    final exporter = IOSDiagnosticExport(channel: channel);
    final unsafe = _bundle()
      ..['records'] = [
        {
          ...DiagnosticRecord(
            atUtc: DateTime.utc(2026, 11, 8),
            event: const DiagnosticEvent(
              name: DiagnosticEventName.applicationStart,
            ),
          ).toMap(),
          'message': 'synthetic secret',
        },
      ];

    await expectLater(
      exporter.saveDiagnosticLog(jsonEncode(unsafe)),
      throwsA(
        isA<DiagnosticsFailure>().having(
          (error) => error.code,
          'code',
          DiagnosticsFailureCode.exportFailed,
        ),
      ),
    );
    expect(calls, 0);
  });

  test('normalizes bridge failures and rejects non-boolean replies', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      return 'unexpected';
    });
    final exporter = IOSDiagnosticExport(channel: channel);
    final source = jsonEncode(_bundle());

    await expectLater(
      exporter.saveDiagnosticLog(source),
      throwsA(
        isA<DiagnosticsFailure>().having(
          (error) => error.code,
          'code',
          DiagnosticsFailureCode.exportFailed,
        ),
      ),
    );

    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      throw PlatformException(
        code: 'closed',
        message: 'private temporary path must not escape',
      );
    });
    await expectLater(
      exporter.saveDiagnosticLog(source),
      throwsA(isA<DiagnosticsFailure>()),
    );
  });
}

Map<String, Object?> _bundle() => {
  'kind': 'ustc-diagnostics-export-v1',
  'exportedAtUtc': '2026-11-08T00:00:00.000Z',
  'retentionDays': 7,
  'versions': const DiagnosticVersions().toSafeMap(),
  'coverage': 'retained_recent_events',
  'selectionTruncated': false,
  'complete': true,
  'dropped': 0,
  'invalid': 0,
  'records': [
    DiagnosticRecord(
      atUtc: DateTime.utc(2026, 11, 8),
      event: const DiagnosticEvent(name: DiagnosticEventName.applicationStart),
    ).toMap(),
  ],
};
