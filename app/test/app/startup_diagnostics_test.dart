import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/m0_app.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/diagnostics_analysis.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/platform/transient_diagnostics.dart';

void main() {
  testWidgets(
    'startup failure can export the current safe error without opening app assets',
    (tester) async {
      final diagnostics = TransientDiagnostics(
        clock: FixedClock(DateTime.utc(2026, 10, 14)),
        versions: const DiagnosticVersions(
          application: '0.0.1+0',
          schema: 13,
          prompt: 'ustc-student-agent-v3',
          tools: 'agent-tools-v2',
        ),
      );
      diagnostics.record(
        const DiagnosticEvent(
          name: DiagnosticEventName.applicationFailed,
          stage: DiagnosticStage.startup,
          outcome: DiagnosticOutcome.failure,
          code: DiagnosticCode.ownerConflict,
        ),
      );
      await tester.pumpWidget(
        M0StartupFailureApp(
          code: FailureCode.ownerConflict,
          diagnostics: diagnostics,
        ),
      );
      expect(
        find.byKey(const ValueKey('diagnostics-export-button')),
        findsOneWidget,
      );
      expect(find.text('导出只包含本次启动错误；已有日志未读取。'), findsOneWidget);
      final analysis = analyzeDiagnosticExport(
        await diagnostics.exportRecent(),
      );
      expect(analysis['coverage'], 'startup_error_only');
      expect(analysis['complete'], isFalse);
      expect(
        (analysis['untracedProblems'] as List).single['code'],
        'ownerConflict',
      );
      await diagnostics.close();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'retained event versions remain distinct from the current export build',
    () {
      const previous = DiagnosticVersions(
        application: '0.0.1+0',
        schema: 13,
        prompt: 'ustc-student-agent-v3',
        tools: 'agent-tools-v2',
        revision: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      const current = DiagnosticVersions(
        application: '0.0.1+0',
        schema: 13,
        prompt: 'ustc-student-agent-v4',
        tools: 'agent-tools-v2',
        revision: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      );
      final record = DiagnosticRecord(
        atUtc: DateTime.utc(2026, 10, 14),
        versions: previous,
        event: DiagnosticEvent(
          name: DiagnosticEventName.agentRunFailed,
          trace: DiagnosticTrace('0123456789abcdef0123456789abcdef'),
          code: DiagnosticCode.invalidInput,
        ),
      );
      final bundle = jsonEncode({
        'kind': 'ustc-diagnostics-export-v1',
        'exportedAtUtc': DateTime.utc(2026, 10, 14).toIso8601String(),
        'retentionDays': 7,
        'coverage': 'retained_recent_events',
        'versions': current.toSafeMap(),
        'selectionTruncated': false,
        'complete': true,
        'dropped': 0,
        'invalid': 0,
        'records': [record.toMap()],
      });
      final analysis = analyzeDiagnosticExport(bundle);
      expect((analysis['versions'] as Map)['prompt'], 'ustc-student-agent-v4');
      expect(
        ((analysis['traces'] as List).single['versions'] as Map)['prompt'],
        'ustc-student-agent-v3',
      );
      expect(
        DiagnosticRecord.decode(record.encode()).versions.revision,
        previous.revision,
      );
    },
  );
}
