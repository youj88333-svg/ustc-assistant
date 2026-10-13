import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/contracts.dart';
import '../core/work_lease.dart';
import '../core/settings_contract.dart';
import '../data/demo_store.dart';
import '../data/jw_store.dart';
import '../data/knowledge_service.dart';
import '../jobs/job_coordinator.dart';
import '../jobs/observation_coordinator.dart';
import '../jobs/observation_port.dart';
import '../jobs/jw_sync_coordinator.dart';
import '../jobs/young_sync_coordinator.dart';
import '../jobs/public_query_coordinator.dart';
import '../jobs/application_maintenance_coordinator.dart';
import '../jobs/application_profile_cleanup.dart';
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
import 'calendar_workspace_contract.dart';
import 'application_settings_controller.dart';

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
    this.settings,
    this.maintenance,
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
  final ApplicationSettingsController settings;
  final ApplicationMaintenanceCoordinator maintenance;
  Future<void>? _closeFuture;
  bool _controllerDisposed = false;

  static Future<DemoRuntime> open({
    String? directoryPath,
    String? jwDirectoryPath,
    AppClock clock = const SystemClock(),
    Duration collectionDelay = const Duration(milliseconds: 450),
  }) async {
    final bootstrap = await RuntimeBootstrap.open(
      directoryPath: directoryPath,
      jwDirectoryPath: jwDirectoryPath,
      clock: clock,
      collectionDelay: collectionDelay,
    );
    final runtime = bootstrap.runtime;
    if (runtime != null) {
      return runtime;
    }
    await bootstrap.close();
    throw const AppFailure(FailureCode.cleanupPending);
  }

  static Future<DemoRuntime> _activate(RuntimeBootstrap bootstrap) async {
    return bootstrap._assembly.assemble();
  }

  Future<void> close() => _closeFuture ??= _close().catchError((Object error) {
    settings.resumeAfterFailedExit(shell: shell);
    _closeFuture = null;
    throw error;
  });

  Future<void> _close() async {
    final preservingMaintenance = maintenance.view.blocksProduct;
    await settings.shutdown();
    await maintenance.close();
    await calendar.shutdown();
    await coordinator.close();
    await publicQueries.close();
    await knowledge.close();
    await youngObservation.shutdown();
    await observation.shutdown();
    if (preservingMaintenance) {
      await jwSync.shutdownForMaintenanceExit();
      await youngSync.shutdownForMaintenanceExit();
    } else {
      await jwSync.shutdown();
      // Young may have deferred startup reconciliation while an earlier source
      // retained the shared lease. Finish that recovery before its shutdown.
      await youngSync.shutdown();
    }
    await browser.dispose();
    if (!_controllerDisposed) {
      calendar.dispose();
      shell.dispose();
      controller.dispose();
      settings.dispose();
      _controllerDisposed = true;
    }
    await store.close();
    await jwStore.close();
    await jwDirectory.release();
    await directory.release();
  }

  Future<void> _refreshAfterMaintenance(MaintenanceKind kind) async {
    publicQueries.refreshAfterMaintenance();
    await jwSync.refreshAfterMaintenance();
    await youngSync.refreshAfterMaintenance();
    final preferences =
        (await jwStore.applicationSettings.inspectSettings()).preferences;
    await calendar.resetAfterMaintenance(
      preferences,
      resetDay: kind == MaintenanceKind.reset,
    );
    await settings.refreshSettings();
  }
}

/// Owns a retryable foundation before exposing any normal source/page. Recovery
/// failure returns this handle; it does not throw away native drain helpers.
final class RuntimeBootstrap extends ChangeNotifier {
  RuntimeBootstrap._({
    required this.directory,
    required this.jwDirectory,
    required this.store,
    required this.jwStore,
    required this.leases,
    required this.browser,
    required this.jwRegistry,
    required this.youngRegistry,
    required this.publicQueries,
    required this.knowledge,
    required this.profiles,
    required this.maintenance,
    required this.settings,
    required this.clock,
    required this.collectionDelay,
    this.onActivationCheckpoint,
  });
  final DemoDirectory directory, jwDirectory;
  final DemoStore store;
  final JwStore jwStore;
  final WorkLeasePool leases;
  final NativeObservationBrowser browser;
  final JwPartitionRegistry jwRegistry;
  final YoungPartitionRegistry youngRegistry;
  final PublicQueryCoordinator publicQueries;
  final KnowledgeService knowledge;
  final ApplicationProfileCleanup profiles;
  final ApplicationMaintenanceCoordinator maintenance;
  final ApplicationSettingsController settings;
  final AppClock clock;
  final Duration collectionDelay;
  @visibleForTesting
  final Future<void> Function()? onActivationCheckpoint;
  DemoRuntime? _runtime;
  DemoRuntime? get runtime => _runtime;
  Future<void>? _activating, _closing;
  late final _RuntimeAssembly _assembly = _RuntimeAssembly(this);

  static Future<RuntimeBootstrap> open({
    String? directoryPath,
    String? jwDirectoryPath,
    AppClock clock = const SystemClock(),
    Duration collectionDelay = const Duration(milliseconds: 450),
    Future<void> Function()? onActivationCheckpoint,
  }) async {
    final directory = await DemoDirectory.acquire(directoryPath);
    DemoDirectory? formal;
    JwStore? database;
    DemoStore? demo;
    NativeObservationBrowser? browser;
    try {
      formal = await DemoDirectory.acquire(
        jwDirectoryPath ??
            (directoryPath == null
                ? defaultJwDirectoryPath(Platform.environment)
                : '${directoryPath}_jw'),
      );
      database = JwStore(
        openJwDatabase(formal),
        ownership: formal,
        clock: clock,
        credentialProtector: const WindowsJwCredentialProtector(),
      );
      demo = DemoStore(
        openDemoDatabase(directory),
        ownership: directory,
        clock: clock,
      );
      await demo.initialize();
      final leases = WorkLeasePool();
      browser = NativeObservationBrowser();
      final jwRegistry = JwPartitionRegistry(formal);
      final youngRegistry = YoungPartitionRegistry(formal);
      final queries = PublicQueryCoordinator(
        store: database.publicStore,
        leases: leases,
        clock: clock,
      );
      final knowledge = KnowledgeService(
        store: database.publicStore,
        loader: BundledKnowledgeLoader().load,
      );
      final profiles = ApplicationProfileCleanup(
        store: database,
        leases: leases,
        browser: browser,
        jwRegistry: jwRegistry,
        youngRegistry: youngRegistry,
        observationDirectory: directory,
      );
      final maintenance = ApplicationMaintenanceCoordinator(
        data: database.applicationSettings,
        leases: leases,
        cleanProfiles: profiles.clean,
        drainForExit: profiles.drainForExit,
      );
      RuntimeBootstrap? ready;
      final settings = ApplicationSettingsController(
        data: database.applicationSettings,
        maintenance: maintenance,
        knowledge: knowledge,
        queries: queries,
        leases: leases,
        applyPreferences: (preferences) async {
          final calendar = ready?.runtime?.calendar;
          if (calendar != null) {
            await calendar.load(
              mode: preferences.calendarView == DefaultCalendarView.week
                  ? CalendarViewMode.week
                  : CalendarViewMode.day,
              includeInactive: preferences.includeInactive,
            );
          }
        },
      );
      final bootstrap = RuntimeBootstrap._(
        directory: directory,
        jwDirectory: formal,
        store: demo,
        jwStore: database,
        leases: leases,
        browser: browser,
        jwRegistry: jwRegistry,
        youngRegistry: youngRegistry,
        publicQueries: queries,
        knowledge: knowledge,
        profiles: profiles,
        maintenance: maintenance,
        settings: settings,
        clock: clock,
        collectionDelay: collectionDelay,
        onActivationCheckpoint: onActivationCheckpoint,
      );
      ready = bootstrap;
      settings.onRecovered = bootstrap._activate;
      await maintenance.restorePending();
      try {
        await settings.refreshSettings();
      } catch (_) {
        /* Recovery remains gated. */
      }
      if (!maintenance.view.blocksProduct) {
        await bootstrap._activate();
      }
      return bootstrap;
    } catch (error) {
      await browser?.dispose();
      await demo?.close();
      await database?.close();
      await formal?.release();
      await directory.release();
      throw error is AppFailure
          ? error
          : const AppFailure(FailureCode.storageFailed);
    }
  }

  Future<void> _activate() => _activating ??= () async {
    if (_closing != null) {
      return;
    }
    if (_runtime != null) {
      return;
    }
    if (maintenance.view.blocksProduct) {
      return;
    }
    try {
      settings.setReadiness(busy: true);
      _runtime = await DemoRuntime._activate(this);
      settings.setReadiness();
      notifyListeners();
    } catch (error) {
      // Retain partial sources/helpers and their native ownership for retry.
      settings.setReadiness(
        failure: ApplicationMaintenanceCoordinator.failureCode(error),
      );
      notifyListeners();
    } finally {
      _activating = null;
    }
  }();

  Future<void> close() => _closing ??= () async {
    try {
      await _activating;
      final runtime = _runtime;
      if (runtime != null) {
        await runtime.close();
        return;
      }
      await settings.shutdown();
      await maintenance.close();
      await _assembly.close();
      await publicQueries.close();
      await knowledge.close();
      await jwRegistry.closeForMaintenanceExit();
      await youngRegistry.closeForMaintenanceExit();
      await browser.dispose();
      settings.dispose();
      await store.close();
      await jwStore.close();
      await jwDirectory.release();
      await directory.release();
    } catch (_) {
      settings.resumeAfterFailedExit();
      _closing = null;
      rethrow;
    }
  }();
}

/// Failed product assembly keeps each initialized resource. Retrying only
/// resumes unfinished steps, and checked exit drains partial native helpers.
final class _RuntimeAssembly {
  _RuntimeAssembly(this.bootstrap);
  final RuntimeBootstrap bootstrap;
  bool _databaseReady = false;
  bool _observationReady = false,
      _youngObservationReady = false,
      _jwReady = false,
      _youngReady = false;
  JobCoordinator? _coordinator;
  DemoController? _controller;
  ObservationCoordinator? _observation, _youngObservation;
  JwSyncCoordinator? _jw;
  YoungSyncCoordinator? _young;
  AppShellController? _shell;
  CalendarWorkspaceController? _calendar;
  bool _disposed = false;

  Future<void> _initializeObservation(
    ObservationCoordinator observation,
  ) async {
    if (observation.view.phase == ObservationPhase.recovery) {
      await observation.closeSession();
    }
    await observation.initialize();
    if (observation.view.phase != ObservationPhase.idle) {
      throw const AppFailure(FailureCode.cleanupPending);
    }
  }

  Future<DemoRuntime> assemble() async {
    final b = bootstrap;
    if (!_databaseReady) {
      await b.jwStore.initialize();
      _databaseReady = true;
    }
    final coordinator = _coordinator ??= JobCoordinator(
      store: b.store,
      source: SyntheticSource(clock: b.clock, delay: b.collectionDelay),
      leases: b.leases,
    );
    final controller = _controller ??= DemoController(
      coordinator: coordinator,
      data: b.store,
    );
    await controller.initialize();
    if (controller.error != null) {
      final error = controller.error!;
      controller.dispose();
      _controller = null;
      throw AppFailure(error);
    }
    final observation = _observation ??= ObservationCoordinator(
      browser: b.browser,
      assets: ObservationAssets(b.directory),
      leases: b.leases,
    );
    if (!_observationReady) {
      await _initializeObservation(observation);
      _observationReady = true;
    }
    final youngObservation = _youngObservation ??= ObservationCoordinator(
      browser: b.browser,
      assets: ObservationAssets.young(b.directory),
      leases: b.leases,
      target: ObservationTarget.young(),
    );
    if (!_youngObservationReady) {
      await _initializeObservation(youngObservation);
      _youngObservationReady = true;
    }
    final jw = _jw ??= JwSyncCoordinator(
      store: b.jwStore,
      registry: b.jwRegistry,
      browser: b.browser,
      leases: b.leases,
      clock: b.clock,
    );
    if (!_jwReady) {
      await jw.initialize();
      _jwReady = true;
    }
    final young = _young ??= YoungSyncCoordinator(
      store: b.jwStore,
      registry: b.youngRegistry,
      browser: b.browser,
      leases: b.leases,
      clock: b.clock,
    );
    if (!_youngReady) {
      await young.initialize();
      _youngReady = true;
    }
    final shell = _shell ??= AppShellController(
      jw: jw,
      young: young,
      clock: b.clock,
      isGloballyBusy: () => b.leases.isBusy || b.maintenance.view.blocksProduct,
      extraChanges: [
        coordinator.changes,
        observation.changes,
        youngObservation.changes,
        b.publicQueries.changes,
        b.maintenance.changes,
      ],
    );
    final calendar = _calendar ??= CalendarWorkspaceController(
      calendar: b.jwStore.localCalendar,
      shell: shell,
      clock: b.clock,
    );
    await b.onActivationCheckpoint?.call();
    final preferences =
        (await b.jwStore.applicationSettings.inspectSettings()).preferences;
    await calendar.load(
      mode: preferences.calendarView == DefaultCalendarView.week
          ? CalendarViewMode.week
          : CalendarViewMode.day,
      includeInactive: preferences.includeInactive,
    );
    await calendar.loadTasks();
    if (calendar.view.failure != null ||
        calendar.view.window == null ||
        calendar.taskView.failure != null ||
        calendar.taskView.window == null) {
      throw const SettingsFailure(SettingsFailureCode.storageFailed);
    }
    final runtime = DemoRuntime._(
      b.directory,
      b.store,
      coordinator,
      controller,
      observation,
      b.browser,
      b.jwDirectory,
      b.jwStore,
      jw,
      youngObservation,
      young,
      b.publicQueries,
      b.knowledge,
      shell,
      calendar,
      b.settings,
      b.maintenance,
    );
    b.settings.attachShell(shell);
    b.maintenance.onRefresh = runtime._refreshAfterMaintenance;
    return runtime;
  }

  Future<void> close() async {
    await _calendar?.shutdown();
    await _coordinator?.close();
    await _youngObservation?.shutdown();
    await _observation?.shutdown();
    await _jw?.shutdownForMaintenanceExit();
    await _young?.shutdownForMaintenanceExit();
    if (!_disposed) {
      _calendar?.dispose();
      _shell?.dispose();
      _controller?.dispose();
      _disposed = true;
    }
  }
}
