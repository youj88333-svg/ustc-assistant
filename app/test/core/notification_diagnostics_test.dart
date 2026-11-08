import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/platform/android_file_access.dart';
import 'package:ustc_assistant_m0/platform/transient_diagnostics.dart';

void main() {
  test(
    'notification diagnostic export preserves only closed counts and OS code',
    () async {
      final diagnostics = TransientDiagnostics();
      diagnostics.record(
        const DiagnosticEvent(
          name: DiagnosticEventName.reminderTestFailed,
          stage: DiagnosticStage.notifications,
          outcome: DiagnosticOutcome.failure,
          code: DiagnosticCode.publishFailed,
          notification: DiagnosticNotificationMetadata(
            operation: DiagnosticNotificationOperation.test,
            step: DiagnosticNotificationStep.registering,
            desired: 61,
            accepted: 59,
            pending: 59,
            capacity: 60,
            errorDomain: NotificationErrorDomain.notifications,
            errorCode: 1,
          ),
        ),
      );
      final safe = validateDiagnosticExport(await diagnostics.exportRecent());
      final record = (jsonDecode(safe)['records'] as List).single;
      expect(record['notification'], {
        'operation': 'test',
        'step': 'registering',
        'desired': 61,
        'accepted': 59,
        'pending': 59,
        'capacity': 60,
        'errorDomain': 'notifications',
        'errorCode': 1,
      });
      final oldRecord = DiagnosticRecord(
        atUtc: DateTime.utc(2026, 11, 8),
        event: const DiagnosticEvent(
          name: DiagnosticEventName.applicationReady,
        ),
      );
      expect(
        DiagnosticRecord.decode(oldRecord.encode()).event.notification,
        isNull,
      );
      await diagnostics.close();
    },
  );

  test(
    'notification metadata rejects private fields, open enums and wrong numeric types',
    () {
      const metadata = {'operation': 'test', 'step': 'registering'};
      for (final extra in <Map<String, dynamic>>[
        {'title': 'synthetic course'},
        {'id': 'opaque-notice'},
        {'rawMessage': 'synthetic OS text'},
        {'path': '/private/synthetic'},
        {'operation': 'arbitraryTool'},
        {'step': 'raw NSError'},
        {'errorDomain': 'student.example'},
        {'errorCode': true},
        {'errorCode': 32768},
        {'pending': -1},
        {'capacity': 1.5},
      ]) {
        expect(
          () => DiagnosticNotificationMetadata.fromSafeMap({
            ...metadata,
            ...extra,
          }),
          throwsFormatException,
        );
      }
    },
  );
}
