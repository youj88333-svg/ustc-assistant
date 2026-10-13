import '../core/contracts.dart';
import '../core/observation_assets.dart';
import '../core/work_lease.dart';
import '../data/jw_store.dart';
import '../platform/demo_directory.dart';
import '../platform/jw_partition_registry.dart';
import '../platform/young_partition_registry.dart';
import '../platform/observation_assets.dart';
import '../source/observation_contract.dart';
import 'observation_coordinator.dart';

/// Only registry-produced paths reach the native recovery-only browser. No
/// browser storage is read and no school navigation or arbitrary deletion runs.
final class ApplicationProfileCleanup {
  ApplicationProfileCleanup({
    required this.store,
    required this.leases,
    required this.browser,
    required this.jwRegistry,
    required this.youngRegistry,
    required this.observationDirectory,
  });
  final JwStore store;
  final WorkLeasePool leases;
  final ObservationBrowserPort browser;
  final JwPartitionRegistry jwRegistry;
  final YoungPartitionRegistry youngRegistry;
  final DemoDirectory observationDirectory;
  ObservationCoordinator? _helper;

  Future<void> _drain(
    String path,
    ObservationTarget target,
    WorkLease lease,
  ) async {
    // Keep and retry a failed environment before creating another helper.
    await drainForExit();
    _helper = ObservationCoordinator(
      browser: browser,
      assets: const _MaintenanceAssets(),
      leases: leases,
      borrowedLease: lease,
      target: target,
    );
    await _helper!.drainRegisteredProfile(path);
    await drainForExit();
  }

  Future<void> clean(WorkLease lease) async {
    if (!lease.belongsTo(leases) || !lease.isHeld) {
      throw const AppFailure(FailureCode.busy);
    }
    final authority = await store.readAuthority();
    // C3 has already durably revoked permits for the confirmed reset.
    if ((await store.readCommittedPermits()).isNotEmpty ||
        (await store.readYoungPermits()).isNotEmpty) {
      throw const AppFailure(FailureCode.staleResult);
    }
    await jwRegistry.reconcile(
      const [],
      ownerId: authority.ownerId,
      resetEpoch: authority.resetEpoch,
      drain: (path) => _drain(path, ObservationTarget.jw(), lease),
    );
    await youngRegistry.reconcile(
      const [],
      ownerId: authority.ownerId,
      resetEpoch: authority.resetEpoch,
      drain: (path) => _drain(path, ObservationTarget.young(), lease),
    );
    final jwObservation = ObservationAssets(observationDirectory);
    final youngObservation = ObservationAssets.young(observationDirectory);
    await jwObservation.recoverPending(
      (path) => _drain(path, ObservationTarget.jw(), lease),
    );
    await youngObservation.recoverPending(
      (path) => _drain(path, ObservationTarget.young(), lease),
    );
    await jwObservation.close();
    await youngObservation.close();
  }

  Future<void> drainForExit() async {
    final helper = _helper;
    if (helper == null) {
      return;
    }
    await helper.shutdown();
    _helper = null;
  }
}

final class _MaintenanceAssets implements ObservationAssetsPort {
  const _MaintenanceAssets();
  @override
  Future<String> register() async =>
      throw const AppFailure(FailureCode.invalidSnapshot);
  @override
  Future<void> recoverPending(Future<void> Function(String) drain) async {}
  @override
  Future<void> cleanup() async {}
  @override
  Future<void> close() async {}
}
