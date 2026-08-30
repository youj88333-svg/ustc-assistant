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
import '../features/settings/presentation/official_websites_page.dart';
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
    this.runtimeDiagnosticSink,
    super.key,
  });

  final OfficialWebsiteLauncher websiteLauncher;
  final AppDatabase? database;
  final AppDatabase Function()? databaseFactory;
  final Future<void> Function()? clearBrowserSession;
  final Future<MinimalJwRuntime> Function()? runtimeLoader;
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
  late final AppLifecycleListener _exitListener;
  Future<void>? _exitFuture;

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
    final clearBrowser =
        widget.clearBrowserSession ?? clearNativeJwBrowserSessions;
    router = buildRouter(
      widget.websiteLauncher,
      database,
      reminderReconciler,
      null,
      clearBrowser,
      runtimeOwner,
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
    final admin = _LazyWindowsJwBrowserSessionAdmin(
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
      safeDiagnostic: widget.runtimeDiagnosticSink,
    );
  }

  /// Awaitable process-exit/pre-dispose boundary. Runtime teardown must settle
  /// before the owned database closes so an active cancellation/import cannot
  /// continue using a closed executor. Repeated callers share one Future.
  Future<void> prepareForExit() {
    final existing = _exitFuture;
    if (existing != null) return existing;
    final operation = _prepareForExit();
    _exitFuture = operation;
    return operation;
  }

  Future<void> _prepareForExit() async {
    Object? firstError;
    StackTrace? firstStack;
    try {
      await runtimeOwner.beginShutdown();
    } on Object catch (_, stack) {
      firstError = StateError('runtime_shutdown_failed');
      firstStack = stack;
    }
    try {
      await reminderReconciler.dispose();
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
  _LazyWindowsJwBrowserSessionAdmin({this.safeDiagnostic});

  final void Function(String)? safeDiagnostic;
  final JwWebViewSurfaceHost _surfaceHost = JwWebViewSurfaceHost();
  Future<WindowsJwBrowserSessionAdmin>? _adminFuture;
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
      final support = await getApplicationSupportDirectory();
      final admin = WindowsJwBrowserSessionAdmin(
        udfStore: WindowsJwUdfStore(privateRoot: Directory(support.path)),
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

  @override
  Future<JwBrowserSessionHandle> open(String accountId) async =>
      (await _resolve()).open(accountId);

  @override
  Future<void> clearAllPartitions() async {
    final existing = _adminFuture;
    if (existing == null && _shutdown) return;
    await (existing ?? _resolve()).then((admin) => admin.clearAllPartitions());
  }

  @override
  Future<void> shutdown() async {
    _shutdown = true;
    final existing = _adminFuture;
    if (existing == null) return;
    await existing.then((admin) => admin.shutdown());
  }
}
