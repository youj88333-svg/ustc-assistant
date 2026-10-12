import 'dart:io';

import '../core/contracts.dart';
import '../core/work_lease.dart';
import '../data/demo_store.dart';
import '../data/jw_store.dart';
import '../data/knowledge_service.dart';
import '../jobs/job_coordinator.dart';
import '../jobs/observation_coordinator.dart';
import '../jobs/jw_sync_coordinator.dart';
import '../jobs/young_sync_coordinator.dart';
import '../jobs/public_query_coordinator.dart';
import '../platform/demo_directory.dart';
import '../platform/jw_directory_path.dart';
import '../platform/native_database.dart';
import '../platform/bundled_knowledge_loader.dart';
import '../platform/native_observation_browser.dart';
import '../platform/observation_assets.dart';
import '../platform/jw_partition_registry.dart';
import '../platform/young_partition_registry.dart';
import '../platform/windows_jw_credential_protector.dart';
import '../source/synthetic_source.dart';
import '../source/observation_contract.dart';
import 'demo_controller.dart';
import 'app_shell_controller.dart';
import 'calendar_workspace_controller.dart';

/// Owns the separate demonstration and formal directories. No old asset opens.
final class DemoRuntime {
  DemoRuntime._(
    this.directory,
    this.store,
    this.coordinator,
    this.controller,
    this.observation,
    this.browser,
    this.jwDirectory,
    this.jwStore,
    this.jwSync,
    this.youngObservation,
    this.youngSync,
    this.publicQueries,
    this.knowledge,
    this.shell,
    this.calendar,
  );

  final DemoDirectory directory;
  final DemoStore store;
  final JobCoordinator coordinator;
  final DemoController controller;
  final ObservationCoordinator observation;
  final NativeObservationBrowser browser;
  final DemoDirectory jwDirectory;
  final JwStore jwStore;
  final JwSyncCoordinator jwSync;
  final ObservationCoordinator youngObservation;
  final YoungSyncCoordinator youngSync;
  final PublicQueryCoordinator publicQueries;
  final KnowledgeService knowledge;
  final AppShellController shell;
  final CalendarWorkspaceController calendar;
  Future<void>? _closeFuture;
  bool _controllerDisposed = false;

  static Future<DemoRuntime> open({
    String? directoryPath,
    String? jwDirectoryPath,
    AppClock clock = const SystemClock(),
    Duration collectionDelay = const Duration(milliseconds: 450),
  }) async {
    final directory = await DemoDirectory.acquire(directoryPath);
    DemoDirectory? jwDirectory;
    JwStore? jwStore;
    JwSyncCoordinator? jwSync;
    YoungSyncCoordinator? youngSync;
    PublicQueryCoordinator? publicQueries;
    KnowledgeService? knowledge;
    DemoStore? store;
    JobCoordinator? coordinator;
    DemoController? controller;
    ObservationCoordinator? observation;
    ObservationCoordinator? youngObservation;
    NativeObservationBrowser? browser;
    AppShellController? shell;
    CalendarWorkspaceController? calendar;
    try {
      jwDirectory = await DemoDirectory.acquire(
        jwDirectoryPath ??
            (directoryPath == null
                ? defaultJwDirectoryPath(Platform.environment)
                : '${directoryPath}_jw'),
      );
      jwStore = JwStore(
        openJwDatabase(jwDirectory),
        ownership: jwDirectory,
        clock: clock,
        credentialProtector: const WindowsJwCredentialProtector(),
      );
      await jwStore.initialize();
      store = DemoStore(
        openDemoDatabase(directory),
        ownership: directory,
        clock: clock,
      );
      await store.initialize();
      final leases = WorkLeasePool();
      publicQueries = PublicQueryCoordinator(
        store: jwStore.publicStore,
        leases: leases,
        clock: clock,
      );
      knowledge = KnowledgeService(
        store: jwStore.publicStore,
        loader: BundledKnowledgeLoader().load,
      );
      coordinator = JobCoordinator(
        store: store,
        source: SyntheticSource(clock: clock, delay: collectionDelay),
        leases: leases,
      );
      controller = DemoController(coordinator: coordinator, data: store);
      await controller.initialize();
      if (controller.error != null) throw AppFailure(controller.error!);
      browser = NativeObservationBrowser();
      observation = ObservationCoordinator(
        browser: browser,
        assets: ObservationAssets(directory),
        leases: leases,
      );
      await observation.initialize();
      youngObservation = ObservationCoordinator(
        browser: browser,
        assets: ObservationAssets.young(directory),
        leases: leases,
        target: ObservationTarget.young(),
      );
      await youngObservation.initialize();
      jwSync = JwSyncCoordinator(
        store: jwStore,
        registry: JwPartitionRegistry(jwDirectory),
        browser: browser,
        leases: leases,
        clock: clock,
      );
      await jwSync.initialize();
      youngSync = YoungSyncCoordinator(
        store: jwStore,
        registry: YoungPartitionRegistry(jwDirectory),
        browser: browser,
        leases: leases,
        clock: clock,
      );
      await youngSync.initialize();
      shell = AppShellController(
        jw: jwSync,
        young: youngSync,
        clock: clock,
        isGloballyBusy: () => leases.isBusy,
        extraChanges: [
          coordinator.changes,
          observation.changes,
          youngObservation.changes,
          publicQueries.changes,
        ],
      );
      calendar = CalendarWorkspaceController(
        calendar: jwStore.localCalendar,
        shell: shell,
        clock: clock,
      );
      await calendar.load();
      await calendar.loadTasks();
      return DemoRuntime._(
        directory,
        store,
        coordinator,
        controller,
        observation,
        browser,
        jwDirectory,
        jwStore,
        jwSync,
        youngObservation,
        youngSync,
        publicQueries,
        knowledge,
        shell,
        calendar,
      );
    } catch (error) {
      await calendar?.shutdown();
      calendar?.dispose();
      shell?.dispose();
      // Do not release an owner if database/session drain itself fails.
      await coordinator?.close();
      await publicQueries?.close();
      await knowledge?.close();
      await youngObservation?.shutdown();
      await observation?.shutdown();
      await jwSync?.shutdown();
      await youngSync?.shutdown();
      await browser?.dispose();
      controller?.dispose();
      await store?.close();
      await jwStore?.close();
      await jwDirectory?.release();
      await directory.release();
      throw error is AppFailure
          ? error
          : const AppFailure(FailureCode.storageFailed);
    }
  }

  Future<void> close() => _closeFuture ??= _close().catchError((Object error) {
    _closeFuture = null;
    throw error;
  });

  Future<void> _close() async {
    await calendar.shutdown();
    await coordinator.close();
    await publicQueries.close();
    await knowledge.close();
    await youngObservation.shutdown();
    await observation.shutdown();
    await jwSync.shutdown();
    // Young may have deferred startup reconciliation while an earlier source
    // retained the shared lease. Finish that recovery before its shutdown.
    await youngSync.shutdown();
    await browser.dispose();
    if (!_controllerDisposed) {
      calendar.dispose();
      shell.dispose();
      controller.dispose();
      _controllerDisposed = true;
    }
    await store.close();
    await jwStore.close();
    await jwDirectory.release();
    await directory.release();
  }
}
