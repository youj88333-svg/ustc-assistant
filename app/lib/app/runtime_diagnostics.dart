import 'dart:async';

import '../core/diagnostics_contract.dart';
import '../core/settings_contract.dart';
import '../core/young_work_contract.dart';
import '../jobs/jw_sync_port.dart';
import '../jobs/young_sync_port.dart';

/// Composition-root observers receive only typed, value-free projections.
/// They cannot read a source response, business database or credential.
final class RuntimeDiagnosticBindings {
  RuntimeDiagnosticBindings(this.port);
  final DiagnosticsPort port;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  void bindJw(
    Stream<JwSyncView> changes, {
    DiagnosticTrace? Function()? parentTrace,
  }) {
    DiagnosticTrace? trace;
    String? previous;
    JwSyncPhase? previousPhase;
    _subscriptions.add(
      changes.listen((view) {
        final key =
            '${view.phase.name}/${view.automation.name}/${view.failure?.name}/${view.identityFailure?.name}/${view.credentialFailure?.name}/${view.sourceFailure?.name}/${view.loginPauseReason?.name}/${view.collectionValidation?.reason.name}/${view.importCommitted}';
        if (key == previous) return;
        previous = key;
        if (view.phase == JwSyncPhase.opening && previousPhase != view.phase) {
          trace = _trace(parentTrace);
        }
        previousPhase = view.phase;
        final failure =
            view.collectionValidation?.reason.name ??
            view.identityFailure?.name ??
            view.credentialFailure?.name ??
            view.sourceFailure?.name ??
            view.failure?.name;
        recordDiagnostic(
          port,
          DiagnosticEvent(
            name: DiagnosticEventName.sourceStage,
            trace: trace,
            stage: DiagnosticStage.jw,
            phase: diagnosticPhase(view.phase.name),
            outcome: view.importCommitted
                ? DiagnosticOutcome.committed
                : failure != null
                ? DiagnosticOutcome.failure
                : view.loginPauseReason != null
                ? DiagnosticOutcome.waitingForSchool
                : view.phase == JwSyncPhase.idle
                ? DiagnosticOutcome.closed
                : DiagnosticOutcome.started,
            code: failure != null
                ? diagnosticCode(failure)
                : view.loginPauseReason == null
                ? null
                : diagnosticCode(view.loginPauseReason!.name),
            count: view.importCommitted
                ? view.courseCount + view.examCount
                : null,
          ),
        );
      }),
    );
  }

  void bindYoung(
    Stream<YoungSyncView> changes, {
    DiagnosticTrace? Function()? parentTrace,
  }) {
    DiagnosticTrace? trace;
    String? previous;
    YoungSyncPhase? previousPhase;
    _subscriptions.add(
      changes.listen((view) {
        final key =
            '${view.phase.name}/${view.automation.name}/${view.failure?.name}/${view.identityFailure?.name}/${view.credentialFailure?.name}/${view.loginPauseReason?.name}/${view.collectionReason?.name}/${view.committed}';
        if (key == previous) return;
        previous = key;
        if (view.phase == YoungSyncPhase.opening &&
            previousPhase != view.phase) {
          trace = _trace(parentTrace);
        }
        previousPhase = view.phase;
        final failure =
            view.collectionReason?.name ??
            view.identityFailure?.name ??
            view.credentialFailure?.name ??
            view.failure?.name;
        recordDiagnostic(
          port,
          DiagnosticEvent(
            name: DiagnosticEventName.sourceStage,
            trace: trace,
            stage: DiagnosticStage.young,
            phase: diagnosticPhase(view.phase.name),
            outcome: view.committed
                ? DiagnosticOutcome.committed
                : failure != null
                ? DiagnosticOutcome.failure
                : view.loginPauseReason != null
                ? DiagnosticOutcome.waitingForSchool
                : view.phase == YoungSyncPhase.idle
                ? DiagnosticOutcome.closed
                : DiagnosticOutcome.started,
            code: failure != null
                ? diagnosticCode(failure)
                : view.loginPauseReason == null
                ? null
                : diagnosticCode(view.loginPauseReason!.name),
            count: view.committed
                ? view.kind == YoungJobKind.activities
                      ? view.normalization?.activities
                      : view.normalization?.events
                : null,
          ),
        );
      }),
    );
  }

  void bindMaintenance(Stream<MaintenanceProgress> changes) {
    DiagnosticTrace? trace;
    String? previous;
    _subscriptions.add(
      changes.listen((view) {
        final key =
            '${view.phase.name}/${view.failure?.name}/${view.committed}';
        if (key == previous) return;
        previous = key;
        if (view.phase == MaintenancePhase.preparing) trace = _trace();
        recordDiagnostic(
          port,
          DiagnosticEvent(
            name: view.failure != null
                ? DiagnosticEventName.maintenanceFailed
                : view.phase == MaintenancePhase.idle
                ? DiagnosticEventName.maintenanceFinished
                : DiagnosticEventName.maintenanceStarted,
            trace: trace,
            stage: DiagnosticStage.maintenance,
            phase: diagnosticPhase(view.phase.name),
            outcome: view.committed
                ? DiagnosticOutcome.committed
                : view.failure != null
                ? DiagnosticOutcome.failure
                : view.phase == MaintenancePhase.idle
                ? DiagnosticOutcome.complete
                : DiagnosticOutcome.started,
            code: view.failure == null
                ? null
                : diagnosticCode(view.failure!.name),
          ),
        );
      }),
    );
  }

  DiagnosticTrace? _trace([DiagnosticTrace? Function()? parent]) {
    try {
      return parent?.call() ?? port.newTrace();
    } catch (_) {
      return null;
    }
  }

  Future<void> close() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }
}

void recordDiagnostic(DiagnosticsPort port, DiagnosticEvent event) {
  try {
    port.record(event);
  } catch (_) {
    /* Best-effort, no business result changes. */
  }
}
