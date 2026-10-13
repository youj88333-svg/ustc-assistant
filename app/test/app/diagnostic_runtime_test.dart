import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/diagnostic_error_hooks.dart';
import 'package:ustc_assistant_m0/app/runtime_diagnostics.dart';
import 'package:ustc_assistant_m0/core/agent_parameter_issue.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/diagnostics_analysis.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/core/jw_work_contract.dart';
import 'package:ustc_assistant_m0/core/settings_contract.dart';
import 'package:ustc_assistant_m0/core/young_work_contract.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_port.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';
import 'package:ustc_assistant_m0/source/jw_collection_failure.dart';
import 'package:ustc_assistant_m0/source/jw_data_probe_contract.dart';
import 'package:ustc_assistant_m0/source/young_active_contract.dart';
import 'package:ustc_assistant_m0/source/young_collection_contract.dart';

const _secretSentinel = 'private-secret-stack-sentinel';

void main() {
  group('RuntimeDiagnosticBindings', () {
    test(
      'source stages share one run trace and activities use activity count',
      () async {
        final diagnostics = _FakeDiagnostics();
        final bindings = RuntimeDiagnosticBindings(diagnostics);
        final jwTrace = DiagnosticTrace('1' * 32);
        final youngTrace = DiagnosticTrace('2' * 32);
        final jw = StreamController<JwSyncView>(sync: true);
        final young = StreamController<YoungSyncView>(sync: true);

        bindings.bindJw(jw.stream, parentTrace: () => jwTrace);
        bindings.bindYoung(young.stream, parentTrace: () => youngTrace);

        jw
          ..add(JwSyncView(phase: JwSyncPhase.opening))
          ..add(JwSyncView(phase: JwSyncPhase.collecting))
          ..add(JwSyncView(phase: JwSyncPhase.idle));
        young
          ..add(
            YoungSyncView(
              phase: YoungSyncPhase.opening,
              kind: YoungJobKind.activities,
            ),
          )
          ..add(
            YoungSyncView(
              phase: YoungSyncPhase.collecting,
              kind: YoungJobKind.activities,
            ),
          )
          ..add(
            YoungSyncView(
              phase: YoungSyncPhase.committing,
              kind: YoungJobKind.activities,
              committed: true,
              normalization: _stats(events: 0, activities: 7),
            ),
          );

        final jwEvents = diagnostics.records
            .where((event) => event.stage == DiagnosticStage.jw)
            .toList();
        final youngEvents = diagnostics.records
            .where((event) => event.stage == DiagnosticStage.young)
            .toList();
        expect(jwEvents, hasLength(3));
        expect(
          jwEvents.every(
            (event) => event.name == DiagnosticEventName.sourceStage,
          ),
          isTrue,
        );
        expect(jwEvents.every((event) => event.trace == jwTrace), isTrue);
        expect(jwEvents.map((event) => event.phase).toSet(), {
          DiagnosticPhase.opening,
          DiagnosticPhase.collecting,
          DiagnosticPhase.idle,
        });
        expect(youngEvents, hasLength(3));
        expect(youngEvents.every((event) => event.trace == youngTrace), isTrue);
        expect(youngEvents.last.outcome, DiagnosticOutcome.committed);
        expect(youngEvents.last.count, 7);
        expect(youngEvents.last.count, isNot(0));

        await bindings.close();
        await jw.close();
        await young.close();
      },
    );

    test(
      'JW and Young cleanup failure retains committed outcome and stable code',
      () async {
        final diagnostics = _FakeDiagnostics();
        final bindings = RuntimeDiagnosticBindings(diagnostics);
        final jw = StreamController<JwSyncView>(sync: true);
        final young = StreamController<YoungSyncView>(sync: true);
        bindings.bindJw(jw.stream);
        bindings.bindYoung(young.stream);

        jw.add(
          JwSyncView(
            phase: JwSyncPhase.recovery,
            importCommitted: true,
            failure: FailureCode.cleanupPending,
            courseCount: 2,
            examCount: 1,
          ),
        );
        young.add(
          YoungSyncView(
            phase: YoungSyncPhase.recovery,
            kind: YoungJobKind.calendar,
            committed: true,
            failure: FailureCode.cleanupPending,
            normalization: _stats(events: 4, activities: 0),
          ),
        );

        final jwEvent = diagnostics.records.singleWhere(
          (event) => event.stage == DiagnosticStage.jw,
        );
        final youngEvent = diagnostics.records.singleWhere(
          (event) => event.stage == DiagnosticStage.young,
        );
        for (final event in [jwEvent, youngEvent]) {
          expect(event.outcome, DiagnosticOutcome.committed);
          expect(event.code, DiagnosticCode.cleanupPending);
        }
        expect(jwEvent.count, 3);
        expect(youngEvent.count, 4);

        await bindings.close();
        await jw.close();
        await young.close();
      },
    );

    test(
      'same-stage JW identity failure is recorded after a clean stage',
      () async {
        final diagnostics = _FakeDiagnostics();
        final bindings = RuntimeDiagnosticBindings(diagnostics);
        final changes = StreamController<JwSyncView>(sync: true);
        bindings.bindJw(changes.stream);

        changes
          ..add(JwSyncView(phase: JwSyncPhase.closing))
          ..add(
            JwSyncView(
              phase: JwSyncPhase.closing,
              identityFailure: JwIdentityFailure.identityUnverified,
            ),
          )
          ..add(
            JwSyncView(
              phase: JwSyncPhase.idle,
              identityFailure: JwIdentityFailure.identityUnverified,
            ),
          );

        expect(diagnostics.records, hasLength(3));
        expect(diagnostics.records[1].phase, DiagnosticPhase.closing);
        _expectSourceFailure(
          diagnostics.records[1],
          JwIdentityFailure.identityUnverified.name,
        );
        _expectSourceFailure(
          diagnostics.records.last,
          JwIdentityFailure.identityUnverified.name,
        );

        await bindings.close();
        await changes.close();
      },
    );

    test('JW credential failure has a fixed failure code', () async {
      final diagnostics = _FakeDiagnostics();
      final bindings = RuntimeDiagnosticBindings(diagnostics);
      final changes = StreamController<JwSyncView>(sync: true);
      bindings.bindJw(changes.stream);

      changes.add(
        JwSyncView(
          phase: JwSyncPhase.login,
          credentialFailure: JwCredentialFailure.protectionFailed,
        ),
      );

      expect(diagnostics.records, hasLength(1));
      _expectSourceFailure(
        diagnostics.records.single,
        JwCredentialFailure.protectionFailed.name,
      );

      await bindings.close();
      await changes.close();
    });

    test('JW source failure has a fixed failure code', () async {
      final diagnostics = _FakeDiagnostics();
      final bindings = RuntimeDiagnosticBindings(diagnostics);
      final changes = StreamController<JwSyncView>(sync: true);
      bindings.bindJw(changes.stream);

      changes.add(
        JwSyncView(
          phase: JwSyncPhase.collecting,
          sourceFailure: JwDataProbeCode.networkFailed,
        ),
      );

      expect(diagnostics.records, hasLength(1));
      _expectSourceFailure(
        diagnostics.records.single,
        JwDataProbeCode.networkFailed.name,
      );

      await bindings.close();
      await changes.close();
    });

    test('JW collection rejection is recorded as a fixed failure', () async {
      final diagnostics = _FakeDiagnostics();
      final bindings = RuntimeDiagnosticBindings(diagnostics);
      final changes = StreamController<JwSyncView>(sync: true);
      bindings.bindJw(changes.stream);

      changes.add(
        JwSyncView(
          phase: JwSyncPhase.collecting,
          collectionValidation: JwCollectionValidationFailure(
            JwCollectionRejectionReason.proofInvalid,
          ),
        ),
      );

      expect(diagnostics.records, hasLength(1));
      _expectSourceFailure(
        diagnostics.records.single,
        JwCollectionRejectionReason.proofInvalid.name,
      );

      await bindings.close();
      await changes.close();
    });

    test(
      'same-stage Young identity failure is recorded after a clean stage',
      () async {
        final diagnostics = _FakeDiagnostics();
        final bindings = RuntimeDiagnosticBindings(diagnostics);
        final changes = StreamController<YoungSyncView>(sync: true);
        bindings.bindYoung(changes.stream);

        changes
          ..add(YoungSyncView(phase: YoungSyncPhase.closing))
          ..add(
            YoungSyncView(
              phase: YoungSyncPhase.closing,
              identityFailure: YoungIdentityFailure.identityUnverified,
            ),
          )
          ..add(
            YoungSyncView(
              phase: YoungSyncPhase.idle,
              identityFailure: YoungIdentityFailure.identityUnverified,
            ),
          );

        expect(diagnostics.records, hasLength(3));
        expect(diagnostics.records[1].phase, DiagnosticPhase.closing);
        _expectSourceFailure(
          diagnostics.records[1],
          YoungIdentityFailure.identityUnverified.name,
        );
        _expectSourceFailure(
          diagnostics.records.last,
          YoungIdentityFailure.identityUnverified.name,
        );

        await bindings.close();
        await changes.close();
      },
    );

    test('Young credential failure has a fixed failure code', () async {
      final diagnostics = _FakeDiagnostics();
      final bindings = RuntimeDiagnosticBindings(diagnostics);
      final changes = StreamController<YoungSyncView>(sync: true);
      bindings.bindYoung(changes.stream);

      changes.add(
        YoungSyncView(
          phase: YoungSyncPhase.login,
          credentialFailure: JwCredentialFailure.protectionFailed,
        ),
      );

      expect(diagnostics.records, hasLength(1));
      _expectSourceFailure(
        diagnostics.records.single,
        JwCredentialFailure.protectionFailed.name,
      );

      await bindings.close();
      await changes.close();
    });

    test('Young collection rejection is recorded as a fixed failure', () async {
      final diagnostics = _FakeDiagnostics();
      final bindings = RuntimeDiagnosticBindings(diagnostics);
      final changes = StreamController<YoungSyncView>(sync: true);
      bindings.bindYoung(changes.stream);

      changes.add(
        YoungSyncView(
          phase: YoungSyncPhase.collecting,
          collectionReason: YoungBusinessRejection.mainRoute,
        ),
      );

      expect(diagnostics.records, hasLength(1));
      _expectSourceFailure(
        diagnostics.records.single,
        YoungBusinessRejection.mainRoute.name,
      );

      await bindings.close();
      await changes.close();
    });

    test(
      'closing to idle does not claim an uncommitted source is complete',
      () async {
        final diagnostics = _FakeDiagnostics();
        final bindings = RuntimeDiagnosticBindings(diagnostics);
        final jw = StreamController<JwSyncView>(sync: true);
        final young = StreamController<YoungSyncView>(sync: true);
        bindings.bindJw(jw.stream);
        bindings.bindYoung(young.stream);

        jw
          ..add(JwSyncView(phase: JwSyncPhase.closing))
          ..add(JwSyncView(phase: JwSyncPhase.idle));
        young
          ..add(YoungSyncView(phase: YoungSyncPhase.closing))
          ..add(YoungSyncView(phase: YoungSyncPhase.idle));

        final idleEvents = diagnostics.records
            .where((event) => event.phase == DiagnosticPhase.idle)
            .toList();
        expect(idleEvents, hasLength(2));
        expect(
          idleEvents.every(
            (event) => event.outcome != DiagnosticOutcome.complete,
          ),
          isTrue,
        );

        await bindings.close();
        await jw.close();
        await young.close();
      },
    );

    test(
      'maintenance recovery keeps its committed result and cleanup code',
      () async {
        final diagnostics = _FakeDiagnostics();
        final bindings = RuntimeDiagnosticBindings(diagnostics);
        final changes = StreamController<MaintenanceProgress>(sync: true);
        bindings.bindMaintenance(changes.stream);

        changes
          ..add(
            const MaintenanceProgress(
              phase: MaintenancePhase.preparing,
              kind: MaintenanceKind.reset,
            ),
          )
          ..add(
            const MaintenanceProgress(
              phase: MaintenancePhase.recovery,
              kind: MaintenanceKind.reset,
              committed: true,
              failure: SettingsFailureCode.cleanupPending,
            ),
          );

        expect(diagnostics.records, hasLength(2));
        final recovery = diagnostics.records.last;
        expect(recovery.name, DiagnosticEventName.maintenanceFailed);
        expect(recovery.stage, DiagnosticStage.maintenance);
        expect(recovery.outcome, DiagnosticOutcome.committed);
        expect(recovery.code, DiagnosticCode.cleanupPending);
        expect(recovery.trace, diagnostics.records.first.trace);

        await bindings.close();
        await changes.close();
      },
    );

    test(
      'close detaches source streams before later events reach the port',
      () async {
        final diagnostics = _FakeDiagnostics();
        final bindings = RuntimeDiagnosticBindings(diagnostics);
        final changes = StreamController<JwSyncView>(sync: true);
        bindings.bindJw(changes.stream);

        changes.add(JwSyncView(phase: JwSyncPhase.opening));
        expect(diagnostics.recordCalls, 1);
        expect(diagnostics.newTraceCalls, 1);
        await bindings.close();
        changes.add(JwSyncView(phase: JwSyncPhase.collecting));

        expect(diagnostics.recordCalls, 1);
        expect(diagnostics.newTraceCalls, 1);
        await changes.close();
      },
    );

    test(
      'diagnostic port failures do not leak or interrupt source and error events',
      () async {
        final diagnostics = _FakeDiagnostics()
          ..throwOnRecord = true
          ..throwOnNewTrace = true
          ..throwOnFlush = true;
        final bindings = RuntimeDiagnosticBindings(diagnostics);
        final changes = StreamController<JwSyncView>(sync: true);
        bindings.bindJw(changes.stream);

        changes
          ..add(JwSyncView(phase: JwSyncPhase.opening))
          ..add(JwSyncView(phase: JwSyncPhase.collecting));
        expect(diagnostics.newTraceCalls, 1);
        expect(diagnostics.recordCalls, 2);

        final hooks = DiagnosticErrorHooks(diagnostics, forwardErrors: false);
        try {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: StateError(_secretSentinel),
              stack: StackTrace.fromString(_secretSentinel),
            ),
          );
          final handled = PlatformDispatcher.instance.onError!(
            StateError(_secretSentinel),
            StackTrace.fromString(_secretSentinel),
          );
          await Future<void>.delayed(Duration.zero);

          expect(handled, isTrue);
          expect(diagnostics.recordCalls, 4);
          expect(diagnostics.flushCalls, 2);
          expect(
            _encodeEvents(diagnostics.attemptedEvents),
            isNot(contains(_secretSentinel)),
          );
        } finally {
          hooks.dispose();
          await bindings.close();
          await changes.close();
        }
      },
    );
  });

  group('DiagnosticErrorHooks', () {
    test(
      'records fixed UI failures and dispose restores both prior handlers',
      () async {
        final diagnostics = _FakeDiagnostics();
        final previousFlutter = FlutterError.onError;
        final previousPlatform = PlatformDispatcher.instance.onError;
        final hooks = DiagnosticErrorHooks(diagnostics, forwardErrors: false);
        try {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: StateError(_secretSentinel),
              stack: StackTrace.fromString(_secretSentinel),
            ),
          );
          final handled = PlatformDispatcher.instance.onError!(
            StateError(_secretSentinel),
            StackTrace.fromString(_secretSentinel),
          );
          await Future<void>.delayed(Duration.zero);

          expect(handled, isTrue);
          expect(diagnostics.records, hasLength(2));
          expect(
            diagnostics.records.every(
              (event) =>
                  event.name == DiagnosticEventName.unexpectedFailure &&
                  event.stage == DiagnosticStage.ui &&
                  event.outcome == DiagnosticOutcome.failure &&
                  event.code == DiagnosticCode.unknown,
            ),
            isTrue,
          );
          expect(
            _encodeEvents(diagnostics.records),
            isNot(contains(_secretSentinel)),
          );
        } finally {
          hooks.dispose();
        }

        expect(identical(FlutterError.onError, previousFlutter), isTrue);
        expect(
          identical(PlatformDispatcher.instance.onError, previousPlatform),
          isTrue,
        );
      },
    );

    test(
      'forwardErrors preserves existing Flutter and platform handlers',
      () async {
        final diagnostics = _FakeDiagnostics();
        final previousFlutter = FlutterError.onError;
        final previousPlatform = PlatformDispatcher.instance.onError;
        var flutterCalls = 0;
        var platformCalls = 0;
        FlutterError.onError = (_) => flutterCalls++;
        PlatformDispatcher.instance.onError = (_, _) {
          platformCalls++;
          return false;
        };
        final testFlutterHandler = FlutterError.onError;
        final testPlatformHandler = PlatformDispatcher.instance.onError;
        final hooks = DiagnosticErrorHooks(diagnostics, forwardErrors: true);
        try {
          FlutterError.reportError(
            FlutterErrorDetails(exception: StateError(_secretSentinel)),
          );
          final handled = PlatformDispatcher.instance.onError!(
            StateError(_secretSentinel),
            StackTrace.fromString(_secretSentinel),
          );
          await Future<void>.delayed(Duration.zero);

          expect(flutterCalls, 1);
          expect(platformCalls, 1);
          expect(handled, isFalse);
          expect(diagnostics.records, hasLength(2));
        } finally {
          hooks.dispose();
        }

        expect(identical(FlutterError.onError, testFlutterHandler), isTrue);
        expect(
          identical(PlatformDispatcher.instance.onError, testPlatformHandler),
          isTrue,
        );
        FlutterError.onError = previousFlutter;
        PlatformDispatcher.instance.onError = previousPlatform;
      },
    );
  });

  test(
    'analysis keeps typed issues and commits, sanitizes versions, and rejects unsafe protocol data',
    () {
      final trace = DiagnosticTrace('a' * 32);
      final records = [
        _record(
          sequence: 1,
          name: DiagnosticEventName.toolRejected,
          trace: trace,
          stage: DiagnosticStage.tools,
          tool: DiagnosticTool.propose_local_changes,
          outcome: DiagnosticOutcome.invalidRequest,
          code: DiagnosticCode.invalidRequest,
          issue: const AgentParameterIssue(
            reason: AgentParameterReason.unknownField,
            field: AgentParameterField.additionalField,
            action: AgentChangeType.create_task,
            changeIndex: 2,
          ),
        ).toMap(),
        _record(
          sequence: 2,
          name: DiagnosticEventName.toolFinished,
          trace: trace,
          stage: DiagnosticStage.tools,
          tool: DiagnosticTool.propose_local_changes,
          outcome: DiagnosticOutcome.committed,
        ).toMap(),
        _record(
          sequence: 3,
          name: DiagnosticEventName.toolFinished,
          trace: trace,
          stage: DiagnosticStage.tools,
          tool: DiagnosticTool.propose_local_changes,
          outcome: DiagnosticOutcome.failure,
          code: DiagnosticCode.cleanupPending,
        ).toMap(),
      ];
      final bundle = _bundle(records);

      final analysis = analyzeDiagnosticExport(jsonEncode(bundle));
      final versions = analysis['versions']! as Map<String, Object?>;
      expect(versions['application'], 'unknown');
      expect(versions['tools'], 'unknown');
      expect(versions['prompt'], 'unknown');
      expect(versions['revision'], 'unknown');
      final summaryText = jsonEncode(analysis);
      expect(summaryText, isNot(contains(_secretSentinel)));

      final traceSummary =
          (analysis['traces']! as List).single as Map<String, Object?>;
      expect(traceSummary['committedTools'], contains('propose_local_changes'));
      final problems = (traceSummary['problems']! as List)
          .cast<Map<String, Object?>>();
      final validationProblem = problems.firstWhere(
        (item) => item.containsKey('validation'),
      );
      expect(validationProblem['validation'], {
        'reason': 'unknownField',
        'field': 'additionalField',
        'action': 'create_task',
        'changeIndex': 2,
      });
      expect(
        problems.any(
          (item) =>
              item['outcome'] == 'failure' && item['code'] == 'cleanupPending',
        ),
        isTrue,
      );
      expect(traceSummary, isNot(contains('zeroWrites')));

      final extra = Map<String, Object?>.from(bundle)
        ..['private'] = _secretSentinel;
      final wrongKind = Map<String, Object?>.from(bundle)
        ..['kind'] = 'private-version-$_secretSentinel';
      final badRecordVersion = Map<String, Object?>.from(bundle)
        ..['records'] = [
          Map<String, Object?>.from(records.first)
            ..['version'] = 'private-version-$_secretSentinel',
        ];
      final unknownEnum = Map<String, Object?>.from(bundle)
        ..['records'] = [
          Map<String, Object?>.from(records.first)
            ..['phase'] = 'private-phase-$_secretSentinel',
        ];
      for (final invalid in [extra, wrongKind, badRecordVersion, unknownEnum]) {
        final contents = jsonEncode(invalid);
        Object? error;
        try {
          analyzeDiagnosticExport(contents);
        } on Object catch (caught) {
          error = caught;
        }
        expect(error, isA<FormatException>());
        expect(error.toString(), isNot(contains(_secretSentinel)));
      }
    },
  );
}

YoungCollectionStats _stats({required int events, required int activities}) =>
    YoungCollectionStats(
      calendarRows: events,
      events: events,
      excludedSchedules: 0,
      duplicateSchedules: 0,
      days: 1,
      calendarPages: 1,
      activityPages: activities == 0 ? 0 : 1,
      activities: activities,
    );

DiagnosticRecord _record({
  required int sequence,
  required DiagnosticEventName name,
  DiagnosticTrace? trace,
  DiagnosticStage? stage,
  DiagnosticTool? tool,
  DiagnosticOutcome? outcome,
  DiagnosticCode? code,
  AgentParameterIssue? issue,
}) => DiagnosticRecord(
  atUtc: DateTime.utc(2026, 10, 14, 8, 0, sequence),
  sequence: sequence,
  event: DiagnosticEvent(
    name: name,
    trace: trace,
    stage: stage,
    tool: tool,
    outcome: outcome,
    code: code,
    issue: issue,
  ),
);

Map<String, Object?> _bundle(List<Map<String, Object?>> records) => {
  'kind': 'ustc-diagnostics-export-v1',
  'exportedAtUtc': '2026-10-14T08:30:00.000Z',
  'retentionDays': diagnosticRetentionDays,
  'versions': {
    'application': 'private-app-$_secretSentinel',
    'schema': 12,
    'tools': 'private-tools-$_secretSentinel',
    'prompt': 'private-prompt-$_secretSentinel',
    'revision': 'private-revision-$_secretSentinel',
  },
  'coverage': 'retained_recent_events',
  'selectionTruncated': false,
  'complete': true,
  'dropped': 0,
  'invalid': 0,
  'records': records,
};

String _encodeEvents(List<DiagnosticEvent> events) => jsonEncode([
  for (var i = 0; i < events.length; i++)
    DiagnosticRecord(
      atUtc: DateTime.utc(2026, 10, 14),
      sequence: i + 1,
      event: events[i],
    ).toMap(),
]);

void _expectSourceFailure(DiagnosticEvent event, String codeName) {
  expect(event.outcome, DiagnosticOutcome.failure);
  expect(event.code, isNotNull);
  expect(event.code, diagnosticCode(codeName));
}

final class _FakeDiagnostics implements DiagnosticsPort {
  final List<DiagnosticEvent> records = [];
  final List<DiagnosticEvent> attemptedEvents = [];
  bool throwOnRecord = false;
  bool throwOnNewTrace = false;
  bool throwOnFlush = false;
  int recordCalls = 0;
  int newTraceCalls = 0;
  int flushCalls = 0;

  @override
  DiagnosticsView get diagnosticsView => const DiagnosticsView(available: true);

  @override
  Future<void> close() async {}

  @override
  Future<void> clear() async {}

  @override
  Future<void> flush() {
    flushCalls++;
    return throwOnFlush
        ? Future<void>.error(StateError(_secretSentinel))
        : Future<void>.value();
  }

  @override
  Future<String> exportRecent() async =>
      '{"kind":"ustc-diagnostics-export-v1","records":[]}';

  @override
  DiagnosticTrace newTrace() {
    newTraceCalls++;
    if (throwOnNewTrace) throw StateError(_secretSentinel);
    return DiagnosticTrace(newTraceCalls.toRadixString(16).padLeft(32, '0'));
  }

  @override
  void record(DiagnosticEvent event) {
    recordCalls++;
    attemptedEvents.add(event);
    if (throwOnRecord) throw StateError(_secretSentinel);
    records.add(event);
  }
}
