import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/app/application_settings_controller.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/settings_contract.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/data/knowledge_service.dart';
import 'package:ustc_assistant_m0/jobs/application_maintenance_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/public_query_coordinator.dart';

void main() {
  test(
    'failed native exit resumes settings progress and same-intent recovery',
    () async {
      final store = JwStore(
        NativeDatabase.memory(),
        ownership: _Owner(),
        clock: FixedClock(DateTime.utc(2026, 10, 12, 4)),
      );
      await store.initialize();
      final leases = WorkLeasePool();
      var cleanCalls = 0, exitCalls = 0;
      var failExit = false;
      final maintenance = ApplicationMaintenanceCoordinator(
        data: store.applicationSettings,
        leases: leases,
        cleanProfiles: (lease) async {
          expect(lease.isHeld, isTrue);
          if (++cleanCalls == 1) {
            throw const AppFailure(FailureCode.cleanupPending);
          }
        },
        drainForExit: () async {
          exitCalls++;
          if (failExit) {
            failExit = false;
            throw const AppFailure(FailureCode.cleanupPending);
          }
        },
      );
      final knowledge = KnowledgeService(
        store: store.publicStore,
        loader: () async =>
            throw StateError('No asset loader should run in this scenario.'),
      );
      final queries = PublicQueryCoordinator(
        store: store.publicStore,
        leases: leases,
      );
      final delayed = _DelayedData(store.applicationSettings);
      final controller = ApplicationSettingsController(
        data: delayed,
        maintenance: maintenance,
        knowledge: knowledge,
        queries: queries,
        leases: leases,
        applyPreferences: (_) async {},
      );
      maintenance.onRefresh = (_) => controller.refreshSettings();
      try {
        await controller.refreshSettings();
        final initial = controller.settingsView.snapshot!.context;
        await controller.runMaintenance(
          initial,
          MaintenanceKind.reset,
          confirmed: true,
        );
        expect(
          controller.settingsView.maintenance.phase,
          MaintenancePhase.recovery,
        );
        final target = controller.settingsView.snapshot!.context;
        expect(target.resetEpoch, initial.resetEpoch + 1);
        final gate = Completer<void>();
        delayed.gate = gate;
        final lateRead = controller.refreshSettings();
        await delayed.entered.future;
        expect(controller.settingsView.loading, isTrue);
        await controller.shutdown();
        expect(controller.settingsView.progressUnavailable, isTrue);
        failExit = true;
        await expectLater(maintenance.close(), throwsA(isA<AppFailure>()));
        expect(exitCalls, 1);
        expect(leases.isBusy, isTrue);
        controller.resumeAfterFailedExit();
        expect(controller.settingsView.progressUnavailable, isFalse);
        expect(controller.settingsView.loading, isFalse);
        gate.complete();
        await lateRead;
        expect(controller.settingsView.loading, isFalse);
        var notifications = 0;
        controller.addListener(() => notifications++);
        await controller.retryMaintenance();
        expect(notifications, greaterThan(0));
        expect(
          controller.settingsView.maintenance.phase,
          MaintenancePhase.idle,
        );
        expect(
          controller.settingsView.snapshot!.context.resetEpoch,
          target.resetEpoch,
        );
        expect(
          controller.settingsView.snapshot!.context.agendaEpoch,
          target.agendaEpoch,
        );
        expect(cleanCalls, 2);
        expect(leases.isBusy, isFalse);
        final current = controller.settingsView.snapshot!.context;
        await controller.saveDisplayPreferences(
          current,
          const DisplayPreferences(calendarView: DefaultCalendarView.day),
        );
        expect(
          controller.settingsView.snapshot!.preferences.calendarView,
          DefaultCalendarView.day,
        );
      } finally {
        failExit = false;
        await controller.shutdown();
        await maintenance.close();
        await queries.close();
        await knowledge.close();
        controller.dispose();
        await store.close();
      }
    },
  );
}

final class _DelayedData implements ApplicationSettingsDataPort {
  _DelayedData(this.delegate);
  final ApplicationSettingsDataPort delegate;
  final entered = Completer<void>();
  Completer<void>? gate;
  @override
  Stream<int> get changes => delegate.changes;
  @override
  Future<SettingsSnapshot> inspectSettings() async {
    final pending = gate;
    gate = null;
    final snapshot = await delegate.inspectSettings();
    if (pending != null) {
      entered.complete();
      await pending.future;
    }
    return snapshot;
  }

  @override
  Future<MaintenanceIntent?> bootstrapMaintenance() =>
      delegate.bootstrapMaintenance();
  @override
  Future<SettingsWriteReceipt> savePreferences(PreferencesWrite write) =>
      delegate.savePreferences(write);
  @override
  Future<MaintenanceRequest> prepareMaintenance(
    SettingsContext context,
    MaintenanceKind kind, {
    required bool confirmed,
  }) => delegate.prepareMaintenance(context, kind, confirmed: confirmed);
  @override
  Future<MaintenanceIntent> beginMaintenance(MaintenanceRequest request) =>
      delegate.beginMaintenance(request);
  @override
  Future<SettingsWriteReceipt> completeMaintenance(MaintenanceIntent intent) =>
      delegate.completeMaintenance(intent);
}

final class _Owner implements AssetOwnership {
  @override
  bool get isHeld => true;
  @override
  void ensureHeld() {}
}
