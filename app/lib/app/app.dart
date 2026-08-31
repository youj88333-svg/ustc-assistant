import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../core/database/app_database.dart';
import '../core/database/connection.dart';
import '../core/security/credential_protector_factory.dart';
import '../features/accounts/application/account_service.dart';
import '../features/accounts/application/first_login_commit_service.dart';
import '../features/agent/application/agent_composition.dart';
import '../features/settings/presentation/official_websites_page.dart';
import '../features/settings/application/minimal_reset_coordinator.dart';
import '../features/reminders/application/reminder_service.dart';
import '../features/reminders/application/windows_reminder_reconciler.dart';
import '../features/reminders/data/foreground_notification_adapter.dart';
import '../features/import/application/import_service.dart';
import '../features/import/data/source_bundle_decoder.dart';
import '../features/sync/presentation/sync_page.dart';
import '../features/sync/application/sync_coordinator.dart';
import '../features/sync/data/bridge_client.dart';
import '../features/sync/data/python_locator.dart';
import '../features/sync/native/jw_browser_session_admin.dart';
import '../features/sync/native/native_jw_gateway.dart';
import '../features/sync/native/jw_webview_surface_host.dart';
import '../features/sync/native/windows_jw_browser_session_admin.dart';
import '../features/sync/native/windows_jw_udf_store.dart';
import '../features/sync/runtime/jw_job_arbiter.dart';
import '../features/sync/runtime/jw_browser_session_cleanup.dart';
import '../features/sync/runtime/minimal_jw_runtime.dart';
import '../features/sync/runtime/source_job_gateway.dart';
import '../features/settings/application/settings_service.dart';
import 'router.dart';
import 'theme.dart';

export '../features/schedule/presentation/schedule_page.dart'
    show ScheduleSection;

class UstcAssistantApp extends StatefulWidget {
  const UstcAssistantApp({
    this.websiteLauncher = const UrlLauncherOfficialWebsiteLauncher(),
    this.database,
    this.databaseFactory,
    this.clearBrowserSession,
    this.runtimeLoader,
    this.resetCoordinatorLoader,
    this.runtimeDiagnosticSink,
    super.key,
  });

  final OfficialWebsiteLauncher websiteLauncher;
  final AppDatabase? database;
  final AppDatabase Function()? databaseFactory;
  final Future<void> Function()? clearBrowserSession;
  final Future<MinimalJwRuntime> Function()? runtimeLoader;
  /// Optional lifecycle-test seam. Production composition uses the fixed
  /// loader below; injecting a coordinator never creates a registry or moves
  /// ownership out of this app state.
  final Future<MinimalResetCoordinator> Function()? resetCoordinatorLoader;
  final void Function(String)? runtimeDiagnosticSink;

  @override
  UstcAssistantAppState createState() => UstcAssistantAppState();
}

class UstcAssistantAppState extends State<UstcAssistantApp> {
  late final bool ownsDatabase;
  late final AppDatabase database;
  late final GoRouter router;
  late final WindowsReminderReconciler reminderReconciler;
  late final MinimalJwRuntimeOwner runtimeOwner;
  late final AgentCompositionOwner agentCompositionOwner;
  late final AppLifecycleListener _exitListener;
  Future<void>? _exitFuture;
  bool _exitRequested = false;
  MinimalResetCoordinator? _resetCoordinator;
  Future<MinimalResetCoordinator>? _resetCoordinatorFuture;

  @override
  void initState() {
    super.initState();
    ownsDatabase = widget.database == null;
    database =
        widget.database ??
        widget.databaseFactory?.call() ??
        AppDatabase(openAppDatabase());
    reminderReconciler = WindowsReminderReconciler(
      database: database,
      reminderService: ReminderService(database: database),
      notifications: ForegroundNotificationAdapter(),
    );
    runtimeOwner = MinimalJwRuntimeOwner(
      widget.runtimeLoader ?? _loadDefaultRuntime,
    );
    agentCompositionOwner = AgentCompositionOwner(
      loader: buildAgentComposition,
    );
    final clearBrowser =
        widget.clearBrowserSession ?? clearNativeJwBrowserSessions;
    router = buildRouter(
      widget.websiteLauncher,
      database,
      reminderReconciler,
      null,
      clearBrowser,
      runtimeOwner,
      agentCompositionOwner,
      _loadResetCoordinator,
    );
    _exitListener = AppLifecycleListener(onExitRequested: _handleExitRequested);
    if (ownsDatabase) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_startBackgroundWork());
      });
    }
  }

  Future<void> _startBackgroundWork() async {
    if (!mounted) return;
    final account = await (database.select(
      database.localAccounts,
    )..where((row) => row.isActive.equals(true))).getSingleOrNull();
    if (!mounted) return;
    if (account != null) await reminderReconciler.start(account.id);
    if (!mounted) return;
    await runStartupAutomaticSync(
      database,
      reminderReconciler: reminderReconciler,
      gateway: await runtimeOwner.current.then((runtime) => runtime.gateway),
    );
  }

  Future<MinimalResetCoordinator> _loadResetCoordinator() {
    if (_exitRequested) {
      return Future<MinimalResetCoordinator>.error(
        StateError('app_exit_requested'),
      );
    }
    final existing = _resetCoordinator;
    if (existing != null) {
      return Future<MinimalResetCoordinator>.value(existing);
    }
    final pending = _resetCoordinatorFuture;
    if (pending != null) return pending;
    final operation = _loadResetCoordinatorImpl();
    _resetCoordinatorFuture = operation;
    unawaited(
      operation.then<void>(
        (coordinator) {
          _resetCoordinator ??= coordinator;
          if (identical(_resetCoordinatorFuture, operation)) {
            _resetCoordinatorFuture = null;
          }
        },
        onError: (Object _, StackTrace _) {
          if (identical(_resetCoordinatorFuture, operation)) {
            _resetCoordinatorFuture = null;
          }
        },
      ),
    );
    return operation;
  }

  Future<MinimalResetCoordinator> _loadResetCoordinatorImpl() async {
    final injected = widget.resetCoordinatorLoader;
    if (injected != null) return injected();
    final runtime = await runtimeOwner.current;
    final sync = runtime.syncCoordinator;
    if (sync == null) {
      throw StateError('reset_composition_unavailable');
    }
    final udfStore = await runtime.resolveUdfStore();
    late final MinimalResetCoordinator coordinator;
    coordinator = MinimalResetCoordinator(
      runtime: runtime,
      sync: sync,
      agent: agentCompositionOwner,
      reminders: reminderReconciler,
      settings: SettingsService(
        database: database,
        accounts: AccountService(
          database: database,
          protector: defaultCredentialProtector(),
        ),
        // Reset is global in the one-account minimal product, including when
        // startup has no active account but stale rows remain.
        accountId: null,
      ),
      udfStore: udfStore,
      recomposeRuntime: () async {
        // Keep Agent and runtime admission closed until both have been
        // replaced. The coordinator calls writer.resume only afterwards.
        await agentCompositionOwner.recompose();
        await runtimeOwner.replaceAfterReset();
        final replacement = await runtimeOwner.current;
        final replacementSync = replacement.syncCoordinator;
        if (replacementSync == null) {
          throw StateError('reset_composition_unavailable');
        }
        // Keep this coordinator bound to the actual current runtime until
        // every resume stage succeeds. If a resume fails, its fail-closed
        // retry must quiesce this replacement rather than the retired one.
        coordinator.bindReplacementRuntime(
          runtime: replacement,
          sync: replacementSync,
        );
      },
    );
    _resetCoordinator = coordinator;
    return coordinator;
  }

  Future<MinimalJwRuntime> _loadDefaultRuntime() async {
    final accounts = AccountService(
      database: database,
      protector: defaultCredentialProtector(),
      clearBrowserSession:
          widget.clearBrowserSession ?? clearNativeJwBrowserSessions,
    );
    final schemaText = await rootBundle.loadString(
      'assets/schemas/source-bundle-1.0.draft7.schema.json',
    );
    final importer = ImportService(
      database: database,
      decoder: SourceBundleDecoder(
        jsonDecode(schemaText) as Map<String, dynamic>,
      ),
      reminderReconciler: reminderReconciler,
    );
    final firstLoginCommit = FirstLoginCommitService(
      accounts: accounts,
      persistPrepared: importer.persistPrepared,
      reminderReconciler: reminderReconciler,
    );
    Future<WindowsJwUdfStore>? udfStoreFuture;
    Future<WindowsJwUdfStore> loadUdfStore() {
      final existing = udfStoreFuture;
      if (existing != null) return existing;
      final operation = () async {
        final support = await getApplicationSupportDirectory();
        return WindowsJwUdfStore(privateRoot: Directory(support.path));
      }();
      udfStoreFuture = operation;
      unawaited(
        operation.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {
            if (identical(udfStoreFuture, operation)) udfStoreFuture = null;
          },
        ),
      );
      return operation;
    }

    final admin = _LazyWindowsJwBrowserSessionAdmin(
      udfStoreLoader: loadUdfStore,
      safeDiagnostic: widget.runtimeDiagnosticSink,
    );
    final native = NativeJwGateway(
      sessionAdmin: admin,
      safeDiagnostic: widget.runtimeDiagnosticSink,
    );
    final arbiter = JwJobArbiter();
    BridgeGateway? selectedBridge;
    late SourceJobGatewayAdapter gateway;
    Future<BridgeGateway> selectBridge() async {
      final existing = selectedBridge;
      if (existing != null) return existing;
      if (!kUsePythonBridgeFallback) {
        selectedBridge = native;
        return native;
      }
      final account = await accounts.activeAccount();
      final executable = await PythonLocator().locate(
        savedExecutable: account == null
            ? null
            : await SettingsService(
                database: database,
                accounts: accounts,
                accountId: account.id,
              ).pythonPath(),
      );
      final bridge = await BridgeClient.start(pythonExecutable: executable);
      selectedBridge ??= bridge;
      if (!identical(selectedBridge, bridge)) {
        await bridge.shutdown();
      }
      return selectedBridge!;
    }

    void invalidateBridge(BridgeGateway bridge) {
      if (identical(selectedBridge, bridge)) selectedBridge = null;
      gateway.invalidateCachedBridge(bridge);
    }

    final coordinator = SyncCoordinator(
      database: database,
      accounts: accounts,
      bridgeFactory: selectBridge,
      invalidateBridge: invalidateBridge,
      importBundle: importer.importBytes,
      prepareBundle: importer.prepare,
      firstLoginCommitService: firstLoginCommit,
      gatewayQuiesce: () => gateway.quiesce(),
      gatewayResume: () => gateway.resume(),
    );
    gateway = SourceJobGatewayAdapter(
      coordinator: coordinator,
      arbiter: arbiter,
      selectedKind: kUsePythonBridgeFallback
          ? JwJobKind.pythonFallback
          : JwJobKind.sync,
      bridgeFactory: selectBridge,
      invalidateBridge: invalidateBridge,
      ownsBrowserSessions: !kUsePythonBridgeFallback,
      safeDiagnostic: widget.runtimeDiagnosticSink,
    );
    return MinimalJwRuntime(
      gateway: gateway,
      browserSessions: admin,
      syncCoordinator: coordinator,
      udfStoreLoader: loadUdfStore,
      safeDiagnostic: widget.runtimeDiagnosticSink,
    );
  }

  /// Awaitable process-exit/pre-dispose boundary. Runtime teardown must settle
  /// before the owned database closes so an active cancellation/import cannot
  /// continue using a closed executor. Repeated callers share one Future.
  Future<void> prepareForExit() {
    final existing = _exitFuture;
    if (existing != null) return existing;
    // Close app-level reset-loader admission before _prepareForExit's first
    // await. A settings callback arriving during runtime teardown must not
    // compose a fresh coordinator after the terminal boundary.
    _exitRequested = true;
    final operation = _prepareForExit();
    _exitFuture = operation;
    return operation;
  }

  Future<void> _prepareForExit() async {
    Object? firstError;
    StackTrace? firstStack;
    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }

    // Capture a loader already in flight before the first await. Its result
    // may arrive while runtime shutdown is settling and still needs the same
    // terminal prepare/join boundary below.
    final loadingResetAtStart = _resetCoordinatorFuture;

    // Claim terminal runtime ownership synchronously. A reset that is
    // already running will observe this at replacement; a new reset cannot
    // install a runtime after this boundary begins.
    Future<void>? runtimeShutdown;
    try {
      runtimeShutdown = runtimeOwner.beginShutdown();
      unawaited(runtimeShutdown.catchError((_) {}));
    } on Object catch (error, stack) {
      firstError = StateError('runtime_shutdown_failed');
      firstStack = stack;
    }

    // If a reset coordinator is already composed, close its terminal gate
    // before the first await and retain the exact active reset Future. A
    // loader still in flight is joined below; runtime shutdown prevents it
    // from admitting a new browser operation in the meantime.
    Future<void>? resetSettlement;
    final composedReset = _resetCoordinator;
    if (composedReset != null) {
      try {
        resetSettlement = composedReset.prepareForExit();
        unawaited(resetSettlement.catchError((_) {}));
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }

    if (runtimeShutdown != null) {
      await attempt(() => runtimeShutdown!);
    }

    final loadingReset = _resetCoordinatorFuture ?? loadingResetAtStart;
    if (loadingReset != null) {
      try {
        final loaded = await loadingReset;
        if (resetSettlement == null) {
          resetSettlement = loaded.prepareForExit();
          unawaited(resetSettlement.catchError((_) {}));
        }
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    // The loader may have completed and published its coordinator while the
    // runtime shutdown await above was in flight. Re-read the fixed owner so
    // a reset begun from that coordinator cannot race database close.
    final loadedAfterShutdown = _resetCoordinator;
    if (resetSettlement == null && loadedAfterShutdown != null) {
      try {
        resetSettlement = loadedAfterShutdown.prepareForExit();
        unawaited(resetSettlement.catchError((_) {}));
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    if (resetSettlement != null) {
      await attempt(() => resetSettlement!);
    }
    try {
      await reminderReconciler.dispose();
    } on Object catch (error, stack) {
      firstError ??= error;
      firstStack ??= stack;
    }
    try {
      await agentCompositionOwner.dispose();
    } on Object catch (error, stack) {
      firstError ??= error;
      firstStack ??= stack;
    }
    if (ownsDatabase) {
      try {
        await database.close();
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    final error = firstError;
    if (error != null) {
      try {
        widget.runtimeDiagnosticSink?.call('runtime_shutdown_failed');
      } on Object {
        // A diagnostic observer cannot alter exit ordering.
      }
      Error.throwWithStackTrace(error, firstStack ?? StackTrace.current);
    }
  }

  Future<AppExitResponse> _handleExitRequested() async {
    try {
      await prepareForExit();
    } on Object {
      // A user-requested terminal exit must be acknowledged after all owned
      // cleanup stages have been attempted, even when one stage failed. The
      // boundary has already observed the fixed safe diagnostic.
    }
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    _exitListener.dispose();
    router.dispose();
    unawaited(prepareForExit().catchError((_) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'USTC Assistant',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      routerConfig: router,
    );
  }
}

/// Defers the platform path lookup and WebView2 construction until the first
/// native job. The runtime itself is still installed once at app scope, so
/// route entry remains synchronous for non-sync destinations and test hosts
/// without a path-provider plugin do not block the shell.
final class _LazyWindowsJwBrowserSessionAdmin implements JwBrowserSessionAdmin {
  _LazyWindowsJwBrowserSessionAdmin({
    required this.udfStoreLoader,
    this.safeDiagnostic,
  });

  final Future<WindowsJwUdfStore> Function() udfStoreLoader;
  final void Function(String)? safeDiagnostic;
  final JwWebViewSurfaceHost _surfaceHost = JwWebViewSurfaceHost();
  Future<WindowsJwBrowserSessionAdmin>? _adminFuture;
  Future<WindowsJwUdfStore>? _udfStoreFuture;
  bool _shutdown = false;

  @override
  JwWebViewSurfaceHost get surfaceHost => _surfaceHost;

  Future<WindowsJwBrowserSessionAdmin> _resolve() {
    final existing = _adminFuture;
    if (existing != null) return existing;
    if (_shutdown) {
      return Future<WindowsJwBrowserSessionAdmin>.error(
        StateError('browser session admin is shut down'),
      );
    }
    final future = () async {
      final udfStore = await _loadUdfStore();
      final admin = WindowsJwBrowserSessionAdmin(
        udfStore: udfStore,
        surfaceHost: _surfaceHost,
        safeDiagnostic: safeDiagnostic,
      );
      if (_shutdown) {
        await admin.shutdown();
        throw StateError('browser session admin is shut down');
      }
      return admin;
    }();
    _adminFuture = future;
    return future;
  }

  Future<WindowsJwUdfStore> _loadUdfStore() {
    final existing = _udfStoreFuture;
    if (existing != null) return existing;
    final operation = Future<WindowsJwUdfStore>.sync(udfStoreLoader);
    _udfStoreFuture = operation;
    unawaited(
      operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_udfStoreFuture, operation)) _udfStoreFuture = null;
        },
      ),
    );
    return operation;
  }

  @override
  Future<JwBrowserSessionHandle> open(String accountId) async =>
      (await _resolve()).open(accountId);

  @override
  Future<void> clearAllPartitions() async {
    final existing = _adminFuture;
    if (existing != null) {
      await existing.then((admin) => admin.clearAllPartitions());
      return;
    }
    // A never-resolved admin does not imply an empty store. Enumerate the
    // explicit UDF root so stale partitions from an earlier launch are also
    // cleared from an unconfigured startup.
    await _loadUdfStore().then((store) => store.clearAllPartitions());
  }

  @override
  Future<void> shutdown() async {
    _shutdown = true;
    final existing = _adminFuture;
    if (existing == null) return;
    await existing.then((admin) => admin.shutdown());
  }
}
