import 'dart:io';
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/contracts.dart';
import '../core/application_version.dart';
import '../core/work_lease.dart';
import '../core/settings_contract.dart';
import '../core/agent_contract.dart';
import '../core/diagnostics_contract.dart';
import '../core/speech_input_contract.dart';
import '../agent/agent_tool_contract.dart';
import '../agent/agent_system_prompt.dart';
import '../agent/agent_coordinator.dart';
import '../agent/agent_read_tools.dart';
import '../agent/agent_action_tools.dart';
import '../jobs/agent_source_coordinator.dart';
import '../agent/model_gateway_contract.dart';
import '../agent/ustc_model_gateway.dart';
import '../data/demo_store.dart';
import '../data/jw_store.dart';
import '../data/knowledge_service.dart';
import '../jobs/job_coordinator.dart';
import '../jobs/observation_coordinator.dart';
import '../jobs/observation_port.dart';
import '../jobs/jw_sync_coordinator.dart';
import '../jobs/young_sync_coordinator.dart';
import '../jobs/young_daily_sync_coordinator.dart';
import '../jobs/public_query_coordinator.dart';
import '../jobs/application_maintenance_coordinator.dart';
import '../jobs/application_profile_cleanup.dart';
import '../jobs/reminder_coordinator.dart';
import '../jobs/morning_brief_coordinator.dart';
import '../jobs/morning_notice_query.dart';
import '../core/reminder_contract.dart';
import '../platform/windows_notifications.dart';
import '../source/public_http.dart';
import '../platform/demo_directory.dart';
import '../platform/diagnostic_journal.dart';
import '../platform/jw_directory_path.dart';
import '../platform/native_database.dart';
import '../platform/bundled_knowledge_loader.dart';
import '../platform/native_observation_browser.dart';
import '../platform/observation_assets.dart';
import '../platform/jw_partition_registry.dart';
import '../platform/young_partition_registry.dart';
import '../platform/windows_jw_credential_protector.dart';
import '../platform/windows_model_credential_protector.dart';
import '../platform/offline_speech_input.dart';
import '../platform/speech_audio_recorder.dart';
import '../platform/sense_voice_recognizer.dart';
import '../source/synthetic_source.dart';
import '../source/observation_contract.dart';
import 'demo_controller.dart';
import 'app_shell_controller.dart';
import 'calendar_workspace_controller.dart';
import 'calendar_workspace_contract.dart';
import 'application_settings_controller.dart';
import 'agent_workspace_controller.dart';
import 'runtime_diagnostics.dart';

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
    this.agentCoordinator,
    this.agent,
    this.diagnostics,
    this.diagnosticBindings,
    this.speechInput,
    this.reminders,
    this.morning,
    this.youngDaily,
    this.clock,
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
  final AgentCoordinator agentCoordinator;
  final AgentWorkspaceController agent;
  final DiagnosticsPort diagnostics;
  final RuntimeDiagnosticBindings diagnosticBindings;
  final SpeechInputPort speechInput;
  final ReminderCoordinator reminders;
  final MorningBriefCoordinator morning;
  final YoungDailySyncCoordinator youngDaily;
  final AppClock clock;
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

  Future<void> close() =>
      _closeFuture ??= _close().catchError((Object error) async {
        recordDiagnostic(
          diagnostics,
          const DiagnosticEvent(
            name: DiagnosticEventName.applicationFailed,
            stage: DiagnosticStage.shutdown,
            outcome: DiagnosticOutcome.recovery,
            code: DiagnosticCode.cleanupPending,
          ),
        );
        await diagnostics.flush();
        await agentCoordinator.resumeAfterFailedExit();
        morning.resumeAfterMaintenance();
        youngDaily.resumeAfterMaintenance();
        reminders.resumeAfterMaintenance();
        settings.resumeAfterFailedExit(shell: shell);
        _closeFuture = null;
        throw error;
      });

  Future<void> _close() async {
    recordDiagnostic(
      diagnostics,
      const DiagnosticEvent(
        name: DiagnosticEventName.applicationClosing,
        stage: DiagnosticStage.shutdown,
        outcome: DiagnosticOutcome.started,
      ),
    );
    final preservingMaintenance = maintenance.view.blocksProduct;
    await youngDaily.quiesceForMaintenance();
    await settings.shutdown();
    await morning.quiesceForMaintenance();
    await speechInput.close();
    await agent.drainBehaviorValidation();
    await agentCoordinator.quiesceForMaintenance();
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
    await morning.close();
    await youngDaily.close();
    await reminders.close();
    await agentCoordinator.close();
    await agent.closeBehaviorValidation();
    if (!_controllerDisposed) {
      calendar.dispose();
      shell.dispose();
      controller.dispose();
      settings.dispose();
      agent.dispose();
      _controllerDisposed = true;
    }
    await store.close();
    await jwStore.close();
    await diagnosticBindings.close();
    recordDiagnostic(
      diagnostics,
      const DiagnosticEvent(
        name: DiagnosticEventName.applicationClosed,
        stage: DiagnosticStage.shutdown,
        outcome: DiagnosticOutcome.complete,
      ),
    );
    await diagnostics.close();
    await jwDirectory.release();
    await directory.release();
  }

  Future<void> _refreshAfterMaintenance(MaintenanceKind kind) async {
    await agentCoordinator.refreshAfterMaintenance();
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
    reminders.resumeAfterMaintenance();
    morning.resumeAfterMaintenance();
    youngDaily.resumeAfterMaintenance();
    await _clearResetDiagnostics(diagnostics, kind);
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
    required this.agentCoordinator,
    required this.agent,
    required this.diagnostics,
    required this.diagnosticBindings,
    required this.speechInput,
    required this.reminders,
    required this.morning,
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
  final AgentCoordinator agentCoordinator;
  final AgentWorkspaceController agent;
  final DiagnosticsPort diagnostics;
  final RuntimeDiagnosticBindings diagnosticBindings;
  final SpeechInputPort speechInput;
  final ReminderCoordinator reminders;
  final MorningBriefCoordinator morning;
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
    @visibleForTesting ModelGatewayPort? modelGateway,
    @visibleForTesting ModelCredentialProtector? modelCredentialProtector,
    @visibleForTesting SpeechInputPort? speechInput,
    @visibleForTesting NotificationPlatformPort? notificationPlatform,
    @visibleForTesting ModelGatewayPort? morningGateway,
  }) async {
    final directory = await DemoDirectory.acquire(directoryPath);
    DemoDirectory? formal;
    JwStore? database;
    DemoStore? demo;
    NativeObservationBrowser? browser;
    AgentCoordinator? agentCoordinator;
    AgentWorkspaceController? agent;
    DiagnosticsPort? diagnostics;
    RuntimeDiagnosticBindings? diagnosticBindings;
    ReminderCoordinator? reminders;
    MorningBriefCoordinator? morning;
    try {
      formal = await DemoDirectory.acquire(
        jwDirectoryPath ??
            (directoryPath == null
                ? defaultJwDirectoryPath(Platform.environment)
                : '${directoryPath}_jw'),
      );
      final ownedFormal = formal;
      String diagnosticPath = '${ownedFormal.path}\\diagnostics';
      try {
        diagnosticPath = ownedFormal.createPlainChildDirectory('diagnostics');
      } catch (_) {
        /* Isolated diagnostic failure. */
      }
      diagnostics = await DiagnosticJournal.open(
        directoryPath: diagnosticPath,
        ensureOwnership: () {
          ownedFormal.ensureHeld();
          ownedFormal.checkedChildPath('diagnostics', directory: true);
        },
        checkedPath: (filename) {
          if (!DiagnosticJournal.segmentNames.contains(filename)) {
            throw const AppFailure(FailureCode.unsafeDirectory);
          }
          return ownedFormal.checkedChildPath(
            'diagnostics\\$filename',
            directory: false,
          );
        },
        clock: clock,
        versions: const DiagnosticVersions(
          application: applicationVersion,
          schema: JwStore.currentSchemaVersion,
          tools: agentToolRegistryVersion,
          prompt: agentPromptVersion,
          revision: String.fromEnvironment(
            'USTC_BUILD_REVISION',
            defaultValue: 'unknown',
          ),
        ),
      );
      recordDiagnostic(
        diagnostics,
        const DiagnosticEvent(
          name: DiagnosticEventName.applicationStart,
          stage: DiagnosticStage.startup,
          outcome: DiagnosticOutcome.started,
        ),
      );
      diagnosticBindings = RuntimeDiagnosticBindings(diagnostics);
      speechInput ??= OfflineSpeechInput(
        recorder: SpeechAudioRecorder(),
        recognizer: SenseVoiceRecognizer(),
        diagnostics: diagnostics,
      );
      database = JwStore(
        openJwDatabase(formal),
        ownership: formal,
        clock: clock,
        credentialProtector: const WindowsJwCredentialProtector(),
        modelCredentialProtector:
            modelCredentialProtector ?? const WindowsModelCredentialProtector(),
      );
      demo = DemoStore(
        openDemoDatabase(directory),
        ownership: directory,
        clock: clock,
      );
      await demo.initialize();
      final leases = WorkLeasePool();
      final agentQueries = PublicQueryCoordinator(
        store: database.publicStore,
        leases: leases,
        clock: clock,
      );
      browser = NativeObservationBrowser();
      final jwRegistry = JwPartitionRegistry(formal);
      final youngRegistry = YoungPartitionRegistry(formal);
      late final AgentSourceCoordinator agentSources;
      final agentJw = JwSyncCoordinator(
        store: database,
        registry: JwPartitionRegistry(formal),
        browser: browser,
        leases: leases,
        clock: clock,
        onJobAdmitted: (ticket) => agentSources.bindAdmittedJob(ticket),
      );
      final agentYoung = YoungSyncCoordinator(
        store: database,
        registry: YoungPartitionRegistry(formal),
        browser: browser,
        leases: leases,
        clock: clock,
        onJobAdmitted: (ticket) => agentSources.bindAdmittedJob(ticket),
      );
      diagnosticBindings.bindJw(
        agentJw.syncChanges,
        parentTrace: () => agentCoordinator?.diagnosticTrace,
      );
      diagnosticBindings.bindYoung(
        agentYoung.syncChanges,
        parentTrace: () => agentCoordinator?.diagnosticTrace,
      );
      agentSources = AgentSourceCoordinator(
        store: database,
        jw: agentJw,
        young: agentYoung,
        clock: clock,
        shutdownSources: () async {
          await agentJw.shutdownForMaintenanceExit();
          await agentYoung.shutdownForMaintenanceExit();
        },
      );
      agentCoordinator = AgentCoordinator(
        data: database.agent,
        gateway: modelGateway ?? UstcModelGateway(),
        clock: clock,
        diagnostics: diagnostics,
        readTools: AgentActionTools(
          plans: database.localCalendar,
          calendar: database.localCalendar,
          tasks: database.localCalendar,
          preferences: database.agent,
          preferenceProposals: database.agent,
          sources: agentSources,
          actionRecords: database.agent,
          reminders: database.features,
          reminderRuntime: () => reminders!.view,
          clock: clock,
          readTools: AgentReadTools(
            calendar: database.localCalendar,
            tasks: database.localCalendar,
            calendarGuard: database.localCalendar,
            knowledge: database.publicStore,
            knowledgeGuard: database.publicStore,
            publicQueries: agentQueries,
            publicGuard: agentQueries,
            clock: clock,
          ),
        ),
      );
      agent = AgentWorkspaceController(agentCoordinator);
      reminders = ReminderCoordinator(
        clock: clock,
        data: database.features,
        platform: notificationPlatform ?? WindowsNotifications(),
        diagnostics: diagnostics,
      );
      final morningBudget = MorningHttpBudget();
      final morningTargets = PublicHttpTargets();
      final morningQueries = PublicQueryCoordinator(
        store: database.publicStore,
        leases: leases,
        clock: clock,
        drainTimeout: const Duration(seconds: 1),
        targets: morningTargets,
        sessionFactory: (source) => IoPublicHttpSession(
          targets: morningTargets,
          source: source,
          beforeRequest: morningBudget.consume,
        ),
      );
      morning = MorningBriefCoordinator(
        data: database.briefs,
        settings: database.features,
        agentData: database.agent,
        gateway:
            morningGateway ??
            UstcModelGateway(requestTimeout: const Duration(seconds: 240)),
        notices: MorningNoticeQuery(source: morningQueries, clock: clock),
        clock: clock,
        diagnostics: diagnostics,
        cancelQueries: morningQueries.cancel,
        closeQueries: morningQueries.close,
        resetNetworkBudget: morningBudget.reset,
        isForegroundBusy: () => agentCoordinator!.view.busy || leases.isBusy,
      );
      agentCoordinator.onForegroundWork = morning.yieldToForeground;
      final ownedMorning = morning;
      // This subscription is owned until the Agent stream closes at shutdown.
      agentCoordinator.changes.listen(
        (_) => ownedMorning.onAgentStateChanged(),
      );
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
      final ownedSpeech = speechInput;
      maintenance.drainAgent = () async {
        await ownedMorning.quiesceForMaintenance();
        await ownedSpeech.cancel();
        await agent!.drainBehaviorValidation();
        await agentCoordinator!.quiesceForMaintenance();
      };
      final ownedReminders = reminders;
      final ownedDatabase = database;
      maintenance.drainReminders = () async =>
          ownedReminders.clearForMaintenance(
            nativeCleanupRequired: await ownedDatabase.features
                .requiresNativeCleanup(),
          );
      // Pending startup reset settles before product assembly installs the
      // richer refresh callback. It must clear diagnostics on that path too.
      maintenance.onRefresh = (kind) =>
          _clearResetDiagnostics(diagnostics!, kind);
      diagnosticBindings.bindMaintenance(maintenance.changes);
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
        agentCoordinator: agentCoordinator,
        agent: agent,
        diagnostics: diagnostics,
        diagnosticBindings: diagnosticBindings,
        speechInput: speechInput,
        reminders: reminders,
        morning: morning,
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
      if (diagnostics != null) {
        recordDiagnostic(
          diagnostics,
          DiagnosticEvent(
            name: DiagnosticEventName.applicationFailed,
            stage: DiagnosticStage.startup,
            outcome: DiagnosticOutcome.failure,
            code: error is AppFailure
                ? diagnosticCode(error.code.name)
                : DiagnosticCode.unknown,
          ),
        );
      }
      await speechInput?.close();
      await morning?.close();
      await reminders?.close();
      await agent?.closeBehaviorValidation();
      await agentCoordinator?.close();
      agent?.dispose();
      await browser?.dispose();
      await demo?.close();
      await database?.close();
      await diagnosticBindings?.close();
      await diagnostics?.close();
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
      await morning.quiesceForMaintenance();
      await speechInput.close();
      await agent.drainBehaviorValidation();
      await agentCoordinator.quiesceForMaintenance();
      await maintenance.close();
      await _assembly.close();
      await publicQueries.close();
      await knowledge.close();
      await jwRegistry.closeForMaintenanceExit();
      await youngRegistry.closeForMaintenanceExit();
      await browser.dispose();
      await morning.close();
      await reminders.close();
      await agentCoordinator.close();
      await agent.closeBehaviorValidation();
      settings.dispose();
      agent.dispose();
      await store.close();
      await jwStore.close();
      await diagnosticBindings.close();
      recordDiagnostic(
        diagnostics,
        const DiagnosticEvent(
          name: DiagnosticEventName.applicationClosed,
          stage: DiagnosticStage.shutdown,
          outcome: DiagnosticOutcome.complete,
        ),
      );
      await diagnostics.close();
      await jwDirectory.release();
      await directory.release();
    } catch (_) {
      recordDiagnostic(
        diagnostics,
        const DiagnosticEvent(
          name: DiagnosticEventName.applicationFailed,
          stage: DiagnosticStage.shutdown,
          outcome: DiagnosticOutcome.recovery,
          code: DiagnosticCode.cleanupPending,
        ),
      );
      await agentCoordinator.resumeAfterFailedExit();
      morning.resumeAfterMaintenance();
      reminders.resumeAfterMaintenance();
      settings.resumeAfterFailedExit();
      _closing = null;
      rethrow;
    }
  }();
}

Future<void> _clearResetDiagnostics(
  DiagnosticsPort diagnostics,
  MaintenanceKind kind,
) async {
  if (kind != MaintenanceKind.reset) return;
  try {
    await diagnostics.clear();
  } catch (_) {
    // The journal reports unavailable; C3 reset is already committed.
    recordDiagnostic(
      diagnostics,
      const DiagnosticEvent(
        name: DiagnosticEventName.unexpectedFailure,
        stage: DiagnosticStage.maintenance,
        outcome: DiagnosticOutcome.failure,
        code: DiagnosticCode.unavailable,
      ),
    );
  }
}

/// Failed product assembly keeps each initialized resource. Retrying only
/// resumes unfinished steps, and checked exit drains partial native helpers.
final class _RuntimeAssembly {
  _RuntimeAssembly(this.bootstrap);
  final RuntimeBootstrap bootstrap;
  bool _databaseReady = false;
  bool _agentReady = false;
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
  YoungDailySyncCoordinator? _daily;
  StreamSubscription<Object?>? _dailyAgentSubscription;
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
    if (!_agentReady) {
      // Reconcile history intent and interrupted runs before ordinary sources
      // or pages are opened. No saved action or model request resumes here.
      await b.jwStore.agent.initializeAgent();
      await b.agentCoordinator.initialize();
      _agentReady = true;
    }
    if (!_databaseReady) {
      await b.jwStore.initialize();
      await b.jwStore.features.initialize();
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
    if (_daily?.isClosed == true) {
      await _dailyAgentSubscription?.cancel();
      _daily = null;
    }
    if (_daily == null) {
      final daily = _daily = YoungDailySyncCoordinator(
        data: b.jwStore.youngDaily,
        source: young,
        startCalendar: (grant, {required bool background}) =>
            young.startDailyCalendar(grant, background: background),
        isForegroundBusy: () =>
            b.leases.isBusy ||
            b.agentCoordinator.view.busy ||
            b.morning.view.busy ||
            b.maintenance.view.blocksProduct,
        adviceOnly: () => b.agentCoordinator.view.adviceOnly,
        clock: b.clock,
      );
      _dailyAgentSubscription = b.agentCoordinator.changes.listen(
        (_) => daily.onAgentStateChanged(),
      );
      daily.onAgentStateChanged();
      b.agentCoordinator.onForegroundWork = () async {
        await daily.yieldToForeground();
        await b.morning.yieldToForeground();
      };
      final drain = b.maintenance.drainAgent;
      b.maintenance.drainAgent = () async {
        await daily.quiesceForMaintenance();
        await drain?.call();
      };
      b.diagnosticBindings.bindYoungDaily(daily.changes);
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
      b.agentCoordinator,
      b.agent,
      b.diagnostics,
      b.diagnosticBindings,
      b.speechInput,
      b.reminders,
      b.morning,
      _daily!,
      b.clock,
    );
    b.diagnosticBindings.bindJw(jw.syncChanges);
    b.diagnosticBindings.bindYoung(young.syncChanges);
    recordDiagnostic(
      b.diagnostics,
      const DiagnosticEvent(
        name: DiagnosticEventName.applicationReady,
        stage: DiagnosticStage.activation,
        outcome: DiagnosticOutcome.complete,
      ),
    );
    b.settings.attachShell(shell);
    b.maintenance.onRefresh = runtime._refreshAfterMaintenance;
    b.reminders.resumeAfterMaintenance();
    b.reminders.start();
    b.morning.resumeAfterMaintenance();
    b.morning.start();
    _daily!.resumeAfterMaintenance();
    _daily!.start();
    return runtime;
  }

  Future<void> close() async {
    await _daily?.close();
    await _dailyAgentSubscription?.cancel();
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
