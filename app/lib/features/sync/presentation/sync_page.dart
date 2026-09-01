import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/minimal_app_state.dart';
import '../../../core/database/app_database.dart';
import '../../../core/security/credential_protector_factory.dart';
import '../../accounts/application/account_service.dart';
import '../../import/application/import_service.dart';
import '../../import/application/reminder_reconciler.dart';
import '../../import/data/source_bundle_decoder.dart';
import '../../import/presentation/file_import_action.dart';
import '../../settings/application/settings_service.dart';
import '../../settings/presentation/settings_page.dart';
import '../application/sync_coordinator.dart';
import '../data/bridge_client.dart';
import '../domain/sync_state.dart';
import '../native/jw_webview_surface_host.dart';
import '../runtime/minimal_jw_runtime.dart';
import '../runtime/source_job_gateway.dart';

Future<void> runStartupAutomaticSync(
  AppDatabase database, {
  ReminderReconciler reminderReconciler = const NoopReminderReconciler(),
  SourceJobGateway? gateway,
}) async {
  // Startup work borrows the app-owned gateway. A missing gateway is a
  // side-effect-free no-op for direct/embedded hosts; production composition
  // always supplies the selected native-or-fallback gateway.
  // Native WebView2 collection requires the mounted SyncPage surface for CAS
  // interaction; startup must not launch an invisible native job. The
  // explicit Python fallback remains eligible for headless startup work.
  if (gateway == null || !kUsePythonBridgeFallback) return;
  try {
    final accounts = AccountService(
      database: database,
      protector: defaultCredentialProtector(),
    );
    final account = await accounts.activeAccount();
    if (account == null) return;
    await gateway.sync(accountId: account.id, trigger: SyncTrigger.automatic);
  } on Object {
    // Startup synchronization is best-effort and must not block local data.
  }
}

class SyncPageLoader extends StatefulWidget {
  const SyncPageLoader({
    required this.database,
    this.reminderReconciler = const NoopReminderReconciler(),
    this.reauthenticateAccountId,
    this.onReauthenticated,
    this.coordinatedReset,
    this.onReauthenticationRequired,
    this.onExit,
    this.clearBrowserSession,
    this.runtime,
    this.appStateController,
    this.nativeGateway,
    this.nativeGatewayFactory,
    this.createNativeGateway = true,
    this.schemaLoader,
    super.key,
  });

  final AppDatabase database;
  final ReminderReconciler reminderReconciler;
  final String? reauthenticateAccountId;
  final VoidCallback? onReauthenticated;

  /// App-owned complete reset boundary used by re-login. Legacy direct hosts
  /// leave this null and retain the service-local compatibility path below.
  final Future<void> Function()? coordinatedReset;
  final ValueChanged<String>? onReauthenticationRequired;
  final VoidCallback? onExit;
  final Future<void> Function()? clearBrowserSession;

  /// The app-owned runtime. When present, this loader borrows its gateway and
  /// surface and does not create or dispose any browser resource.
  final MinimalJwRuntime? runtime;

  /// App-root state bridge for explicit login and collection phases. This
  /// page never owns the runtime or reset coordinator.
  final MinimalAppStateController? appStateController;

  /// Optional gateway seam for tests and hosts that already own the native
  /// gateway. The loader still owns the supplied gateway for its lifetime.
  final BridgeGateway? nativeGateway;

  /// Optional asynchronous gateway seam for lifecycle tests and hosts that
  /// defer gateway creation. The loader owns the resolved gateway.
  final Future<BridgeGateway> Function()? nativeGatewayFactory;

  /// Legacy compatibility flag. App routes pass [runtime] and therefore do
  /// not create a native environment here; hosts using this loader directly
  /// must inject [nativeGateway] or [nativeGatewayFactory].
  final bool createNativeGateway;

  /// Optional schema-loading seam for lifecycle tests that need dependency
  /// initialization to remain pending after gateway creation.
  final Future<String> Function()? schemaLoader;

  @override
  State<SyncPageLoader> createState() => _SyncPageLoaderState();
}

class _SyncPageLoaderState extends State<SyncPageLoader> {
  late final Future<_SyncDependencies> dependencies;
  BridgeGateway? bridge;
  BridgeGateway? nativeGateway;
  BridgeGateway? _resolvedNativeGateway;
  Future<BridgeGateway>? _nativeGatewayCreation;
  StreamSubscription<String>? _diagnosticSub;
  bool _disposed = false;
  final Map<BridgeGateway, Future<void>> _shutdownFutures =
      Map<BridgeGateway, Future<void>>.identity();
  Future<void>? _ownedShutdown;
  bool _replacementRequested = false;

  /// Privacy-safe stage-log buffer for the debug diagnostics panel. Only
  /// allocated in debug/profile builds; in release it stays null so the panel
  /// and its overhead never ship. Cap keeps the UI bounded.
  final ValueNotifier<List<String>>? diagnostics = kDebugMode
      ? ValueNotifier<List<String>>(const <String>[])
      : null;

  @override
  void initState() {
    super.initState();
    if (widget.runtime != null) {
      // Runtime resources belong to the app composition owner. This page only
      // borrows the already-selected source gateway and visible surface.
      dependencies = _build();
      return;
    }
    // Register the gateway synchronously, before _build can cross its first
    // await. This makes dispose() the owner even when dependency loading is
    // still in flight. A deferred factory is joined below and handled with
    // the same disposed/once-only ownership path.
    final supplied = widget.nativeGateway;
    if (supplied != null) {
      nativeGateway = supplied;
    } else if (widget.createNativeGateway) {
      final factory = widget.nativeGatewayFactory;
      if (factory != null) {
        final creation = Future<BridgeGateway>.sync(factory);
        _nativeGatewayCreation = creation;
        // _build may still be waiting on an unrelated dependency when the
        // State is unmounted. Observe this future independently so a
        // gateway returned later is still closed, even if _build never
        // reaches its await site again.
        unawaited(
          creation.then<void>((gateway) {
            if (_disposed) {
              _observeShutdown(_shutdownOnce(gateway));
              return;
            }
            // Claim the result immediately, even if _build is awaiting a
            // later dependency. Dispose must see this ownership window.
            _resolvedNativeGateway = gateway;
            nativeGateway ??= gateway;
          }, onError: (Object error, StackTrace stack) {}),
        );
      } else {
        // A page without an app-owned runtime must receive an explicit
        // gateway from its host; route composition never creates one here.
      }
    }
    dependencies = _build();
  }

  void _ensureAlive() {
    if (_disposed) {
      throw StateError('sync page loader is disposed');
    }
  }

  Future<void> _shutdownOnce(BridgeGateway gateway) {
    final existing = _shutdownFutures[gateway];
    if (existing != null) return existing;
    final future = Future<void>.sync(gateway.shutdown);
    _shutdownFutures[gateway] = future;
    return future;
  }

  void _observeShutdown(Future<void> future) {
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          // Disposal is best-effort because State.dispose cannot be async;
          // replacement routing awaits the same future and therefore still
          // fails closed when teardown is unsuccessful.
          debugPrint('[jw-native] shutdown_failed');
        },
      ),
    );
  }

  Future<void> _shutdownOwnedForReplacement() {
    if (widget.runtime != null) return Future<void>.value();
    final existing = _ownedShutdown;
    if (existing != null) return existing;
    _disposed = true;
    final future = _shutdownOwnedImpl();
    _ownedShutdown = future;
    return future;
  }

  Future<void> _shutdownOwnedImpl() async {
    final gateways = Set<BridgeGateway>.identity();
    final currentNative = nativeGateway ?? _resolvedNativeGateway;
    if (currentNative != null) gateways.add(currentNative);
    final currentBridge = bridge;
    if (currentBridge != null) gateways.add(currentBridge);

    // A factory can still be resolving while schema/coordinator setup is in
    // flight. Await it before routing so its environment cannot overlap the
    // replacement loader's fresh environment.
    final creation = _nativeGatewayCreation;
    if (creation != null) {
      try {
        gateways.add(await creation);
      } on Object {
        // The factory owns no gateway when it fails; preserve the failure only
        // through the loader's dependency future and continue known cleanup.
      }
    }
    for (final gateway in gateways) {
      await _shutdownOnce(gateway);
    }
  }

  Future<_SyncDependencies> _build() async {
    final runtime = widget.runtime;
    if (runtime != null) {
      _ensureAlive();
      final accounts = AccountService(
        database: widget.database,
        protector: defaultCredentialProtector(),
        clearBrowserSession: widget.clearBrowserSession,
      );
      final sourceGateway = runtime.gateway;
      final diagnosticReader = sourceGateway is SourceJobDiagnosticReader
          ? sourceGateway as SourceJobDiagnosticReader
          : null;
      if (diagnosticReader != null && diagnostics != null) {
        _diagnosticSub = diagnosticReader.diagnostics.listen((event) {
          debugPrint('[jw-source] $event');
          final notifier = diagnostics;
          if (notifier == null || !mounted) return;
          final current = notifier.value;
          final next = <String>[...current, event];
          if (next.length > 80) {
            next.removeRange(0, next.length - 80);
          }
          notifier.value = next;
        });
      }
      final importReader = sourceGateway is SourceJobImportReader
          ? sourceGateway as SourceJobImportReader
          : null;
      final importer = importReader?.importBundle;
      if (importer == null) {
        throw StateError('source gateway import is unavailable');
      }
      return _SyncDependencies(
        accounts: accounts,
        gateway: sourceGateway,
        importBundle: importer,
        surfaceHost: runtime.surfaceHost,
        diagnostics: diagnostics,
      );
    }
    final schemaLoader = widget.schemaLoader;
    final schemaText = schemaLoader == null
        ? await rootBundle.loadString(
            'assets/schemas/source-bundle-1.0.draft7.schema.json',
          )
        : await schemaLoader();
    // Do not inspect or wire any gateway after dependency loading if the
    // loader was unmounted while the await was pending.
    _ensureAlive();
    final accounts = AccountService(
      database: widget.database,
      protector: defaultCredentialProtector(),
      clearBrowserSession: widget.clearBrowserSession,
    );
    final importer = ImportService(
      database: widget.database,
      decoder: SourceBundleDecoder(
        jsonDecode(schemaText) as Map<String, dynamic>,
      ),
      reminderReconciler: widget.reminderReconciler,
    );
    // Direct/legacy hosts may still inject one already-selected bridge or
    // defer that same gateway through [nativeGatewayFactory]. Production
    // routes provide [runtime]; bridge selection (including the explicit
    // Python fallback) lives only in app composition and is never started by
    // this presentation layer.
    BridgeGateway? gw = nativeGateway ?? _resolvedNativeGateway;
    if (gw == null && widget.createNativeGateway) {
      final creation = _nativeGatewayCreation;
      if (creation != null) {
        gw = await creation;
        // A factory may complete after the State has unmounted. Do not
        // assign or use that gateway through the disposed State; it is
        // still ours to shut down exactly once.
        if (_disposed) {
          _observeShutdown(_shutdownOnce(gw));
          throw StateError('sync page loader is disposed');
        }
        nativeGateway = gw;
      } else {
        // This is defensive for an unexpected re-entry; initState normally
        // registers the default gateway before _build starts.
        _ensureAlive();
        // No page-owned default exists. A direct legacy host must supply a
        // gateway/factory; app routes always provide [runtime].
      }
    }
    _ensureAlive();
    final activeNativeGateway = gw;
    final diagnosticReader = activeNativeGateway is SourceJobDiagnosticReader
        ? activeNativeGateway as SourceJobDiagnosticReader
        : null;
    if (diagnosticReader != null && diagnostics != null) {
      _diagnosticSub = diagnosticReader.diagnostics.listen((event) {
        debugPrint('[jw-native] $event');
        final notifier = diagnostics;
        if (notifier == null || !mounted) return;
        final current = notifier.value;
        final next = <String>[...current, event];
        if (next.length > 80) {
          next.removeRange(0, next.length - 80);
        }
        notifier.value = next;
      });
    }
    final coordinator = SyncCoordinator(
      database: widget.database,
      accounts: accounts,
      bridgeFactory: () async {
        final current = bridge;
        if (current != null) {
          _ensureAlive();
          return current;
        }
        final native = activeNativeGateway;
        if (native == null) {
          throw StateError('source gateway is unavailable');
        }
        _ensureAlive();
        bridge = native;
        return native;
      },
      importBundle: importer.importBytes,
    );
    await coordinator.recoverInterruptedRuns();
    _ensureAlive();
    return _SyncDependencies(
      accounts: accounts,
      coordinator: coordinator,
      importBundle: importer.importBytes,
      nativeGateway: activeNativeGateway,
      surfaceHost: activeNativeGateway is JwWebViewSurfaceProvider
          ? (activeNativeGateway as JwWebViewSurfaceProvider).surfaceHost
          : null,
      diagnostics: diagnostics,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    final diagnosticSub = _diagnosticSub;
    _diagnosticSub = null;
    if (diagnosticSub != null) {
      unawaited(diagnosticSub.cancel());
    }
    diagnostics?.dispose();
    _observeShutdown(_shutdownOwnedForReplacement());
    super.dispose();
  }

  void _requestReauthentication(String accountId) {
    if (_replacementRequested || _disposed) return;
    _replacementRequested = true;
    if (widget.runtime != null) {
      // The app-owned runtime is intentionally reused by the reauth route;
      // the reauth page shuts it down only after its confirmed destructive
      // reset, immediately before the owner installs a replacement.
      widget.onReauthenticationRequired?.call(accountId);
      return;
    }
    unawaited(_shutdownAndRouteForReauthentication(accountId));
  }

  Future<void> _shutdownAndRouteForReauthentication(String accountId) async {
    try {
      await _shutdownOwnedForReplacement();
    } on Object {
      // Never create a second loader while the old environment may still be
      // alive. The existing page remains visible, and the route callback is
      // intentionally not invoked on teardown failure.
      return;
    }
    if (!mounted) return;
    widget.onReauthenticationRequired?.call(accountId);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_SyncDependencies>(
      future: dependencies,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Scaffold(body: Center(child: Text('同步组件初始化失败')));
        }
        final value = snapshot.data;
        if (value == null) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return SyncPage(
          accounts: value.accounts,
          coordinator: value.coordinator,
          gateway: value.gateway,
          nativeGateway: value.nativeGateway,
          surfaceHost: value.surfaceHost,
          importBundle: value.importBundle,
          diagnostics: value.diagnostics,
          reauthenticateAccountId: widget.reauthenticateAccountId,
          appStateController: widget.appStateController,
          onReauthenticated: widget.onReauthenticated,
          coordinatedReset: widget.coordinatedReset,
          onReauthenticationRequired: widget.onReauthenticationRequired == null
              ? null
              : _requestReauthentication,
          onExit: widget.onExit,
        );
      },
    );
  }
}

class _SyncDependencies {
  const _SyncDependencies({
    required this.accounts,
    this.coordinator,
    this.gateway,
    this.importBundle,
    this.nativeGateway,
    this.surfaceHost,
    this.diagnostics,
  });

  final AccountService accounts;
  final SyncCoordinator? coordinator;
  final SourceJobGateway? gateway;
  final BundleImport? importBundle;
  final BridgeGateway? nativeGateway;
  final JwWebViewSurfaceHost? surfaceHost;
  final ValueNotifier<List<String>>? diagnostics;
}

class SyncPage extends StatefulWidget {
  const SyncPage({
    required this.accounts,
    this.coordinator,
    this.gateway,
    this.nativeGateway,
    this.surfaceHost,
    this.importBundle,
    this.diagnostics,
    this.filePicker = const SystemImportFilePicker(),
    this.reauthenticateAccountId,
    this.onReauthenticated,
    this.coordinatedReset,
    this.onReauthenticationRequired,
    this.onExit,
    this.appStateController,
    super.key,
  });

  final AccountService accounts;

  /// Legacy coordinator seam retained for focused tests/embedded hosts. App
  /// routes pass [gateway] instead so presentation never owns a coordinator.
  final SyncCoordinator? coordinator;
  final SourceJobGateway? gateway;
  final BridgeGateway? nativeGateway;
  final JwWebViewSurfaceHost? surfaceHost;
  final BundleImport? importBundle;
  final ValueNotifier<List<String>>? diagnostics;
  final ImportFilePicker filePicker;
  final String? reauthenticateAccountId;
  final VoidCallback? onReauthenticated;
  final Future<void> Function()? coordinatedReset;
  final ValueChanged<String>? onReauthenticationRequired;
  final VoidCallback? onExit;
  final MinimalAppStateController? appStateController;

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  final usernameController = TextEditingController();
  final passwordController = TextEditingController();
  String? accountId;
  bool busy = false;
  bool savePassword = false;
  Map<SyncSource, SyncSourceState> states = const {};
  String? reauthenticationHint;

  @override
  void initState() {
    super.initState();
    if (widget.reauthenticateAccountId != null) {
      _publishAppState((state) => state.showLoginVisible());
    }
    _loadAndAutoSync();
  }

  @override
  void dispose() {
    usernameController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  void _publishAppState(void Function(MinimalAppStateController state) update) {
    final appState = widget.appStateController;
    if (appState == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) update(appState);
    });
  }

  Future<void> _loadAndAutoSync() async {
    final reauthenticateId = widget.reauthenticateAccountId;
    if (reauthenticateId != null) {
      accountId = reauthenticateId;
      final summaries = await widget.accounts.summaries();
      if (!mounted) return;
      for (final summary in summaries) {
        if (summary.id == reauthenticateId) {
          reauthenticationHint = summary.maskedHint;
          break;
        }
      }
      _publishAppState((state) => state.showLoginVisible());
      await _refresh();
      return;
    }
    final account = await widget.accounts.activeAccount();
    if (!mounted) return;
    accountId = account?.id;
    if (account == null) {
      _publishAppState((state) => state.showLoginVisible());
    } else {
      _publishAppState((state) => state.showConfigured());
    }
    await _refresh();
    if (account != null) await _runAll(SyncTrigger.automatic);
  }

  Future<void> _refresh() async {
    final id = accountId;
    if (id == null) {
      if (mounted) setState(() {});
      return;
    }
    final loaded = <SyncSource, SyncSourceState>{};
    for (final source in SyncSource.values) {
      final gateway = widget.gateway;
      final stateReader = gateway is SourceJobStateReader
          ? gateway as SourceJobStateReader
          : null;
      loaded[source] = stateReader != null
          ? await stateReader.stateFor(id)
          : await widget.coordinator!.stateFor(source, id);
    }
    if (mounted) setState(() => states = loaded);
  }

  Future<void> _run(SyncSource source, SyncTrigger trigger) async {
    final id = accountId;
    if (id == null || busy) return;
    setState(() => busy = true);
    _publishAppState((state) => state.beginCollecting());
    try {
      final gateway = widget.gateway;
      final outcome = gateway != null
          ? await gateway.sync(accountId: id, trigger: trigger)
          : await widget.coordinator!.sync(
              source,
              trigger: trigger,
              accountId: id,
            );
      await _handle(outcome);
    } finally {
      if (mounted) {
        setState(() => busy = false);
        _publishAppState((state) => state.showConfigured());
        await _refresh();
      }
    }
  }

  Future<void> _runAll(SyncTrigger trigger) async {
    final id = accountId;
    if (id == null || busy) return;
    setState(() => busy = true);
    _publishAppState((state) => state.beginCollecting());
    try {
      final gateway = widget.gateway;
      if (gateway != null) {
        var outcome = await gateway.sync(accountId: id, trigger: trigger);
        if (outcome is SyncNeedsUserAction) {
          final confirmed = trigger == SyncTrigger.automatic
              ? false
              : await _confirmInteractiveLogin(outcome);
          final InteractiveSourceJobGateway? interactive =
              gateway is InteractiveSourceJobGateway
              ? gateway as InteractiveSourceJobGateway
              : null;
          outcome = interactive == null
              ? const SyncFailed(SyncSource.jw, code: 'sync_failed')
              : await interactive.resumeInteractive(
                  outcome.jobId,
                  userConfirmed: confirmed,
                );
        }
        // Keep the one-source page behavior identical to coordinator.syncAll;
        // the gateway is the only UI-facing job entry point.
        await _handle(outcome);
      } else {
        await widget.coordinator!.syncAll(
          trigger: trigger,
          accountId: id,
          resolveUserAction: trigger == SyncTrigger.automatic
              ? (_) async => false
              : _confirmInteractiveLogin,
        );
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
        _publishAppState((state) => state.showConfigured());
        await _refresh();
      }
    }
  }

  Future<SyncOutcome> _handle(SyncOutcome outcome) async {
    if (outcome is! SyncNeedsUserAction || !mounted) return outcome;
    final confirmed = await _confirmInteractiveLogin(outcome);
    if (!mounted) return outcome;
    final gateway = widget.gateway;
    if (gateway is InteractiveSourceJobGateway) {
      return (gateway as InteractiveSourceJobGateway).resumeInteractive(
        outcome.jobId,
        userConfirmed: confirmed,
      );
    }
    return widget.coordinator!.resumeInteractive(
      outcome.jobId,
      userConfirmed: confirmed,
    );
  }

  Future<bool> _confirmInteractiveLogin(SyncNeedsUserAction outcome) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('需要登录学校网站'),
            content: const Text(
              '内嵌浏览器窗口已打开并停留在登录页。点击"继续"后才会读取已保存的密码并自动填写；取消则中止本次同步。',
            ),
            actions: [
              TextButton(
                key: const Key('cancel-interactive-login'),
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const Key('continue-interactive-login'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('继续'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _firstLogin() async {
    final username = usernameController.text.trim();
    if (username.isEmpty || busy) return;
    setState(() => busy = true);
    _publishAppState((state) => state.beginCollecting());
    final gateway = widget.gateway;
    var outcome = gateway != null
        ? await gateway.firstLogin(
            FirstLoginCommand(
              username: username,
              password: passwordController.text.isEmpty
                  ? null
                  : passwordController.text,
              savePassword: savePassword,
            ),
          )
        : await widget.coordinator!.firstLoginSync(
            SyncSource.jw,
            username: username,
            password: passwordController.text.isEmpty
                ? null
                : passwordController.text,
            savePassword: savePassword,
          );
    outcome = await _handle(outcome);
    if (!mounted) return;
    passwordController.clear();
    if (outcome is SyncSucceeded) {
      accountId = (await widget.accounts.activeAccount())?.id;
      if (!mounted) return;
      await _refresh();
    }
    if (mounted) {
      setState(() => busy = false);
      if (outcome is SyncSucceeded) {
        _publishAppState((state) => state.showConfigured());
      } else {
        _publishAppState((state) => state.showLoginVisible());
      }
      final message = switch (outcome) {
        SyncSucceeded() => '账号已绑定，教务同步完成',
        SyncCancelled() => '已取消登录',
        SyncFailed(:final code) => '登录或同步失败：$code',
        _ => '登录未完成',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _reauthenticate() async {
    final id = widget.reauthenticateAccountId;
    if (id == null || busy) return;
    setState(() => busy = true);
    _publishAppState((state) => state.showLoginVisible());
    var accountCleared = false;
    var message = '重新登录未完成';
    try {
      final confirmed = await _confirmCompleteReset();
      if (!confirmed) {
        message = '已取消重新登录';
      } else {
        await _completeResetWithoutConfirmation();
        accountCleared = true;
        message = '本地数据已清除';
      }
    } on AccountVerificationError catch (error) {
      message = '重新登录失败：${error.code}';
    } on Object {
      // Keep native/plugin and database details out of the UI and diagnostics.
      message = '重新登录失败：reauthentication_failed';
    } finally {
      if (mounted) {
        passwordController.clear();
        setState(() => busy = false);
      }
    }
    if (!mounted) return;
    if (accountCleared) {
      _publishAppState((state) => state.showUnconfigured());
      widget.onReauthenticated?.call();
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirmCompleteReset() async {
    return confirmCompleteReset(context);
  }

  Future<void> _completeResetWithoutConfirmation() async {
    final coordinatedReset = widget.coordinatedReset;
    if (coordinatedReset != null) {
      // The app-owned coordinator closes every real writer, drains the
      // borrowed runtime, clears DB/UDF state, and installs the fresh runtime
      // before this route is allowed to continue.
      await coordinatedReset();
      return;
    }
    // Legacy direct hosts still own their supplied gateway locally. Keep
    // their compatibility path, but do not let it replace the app-owned
    // fixed reset boundary used by production routes.
    await widget.gateway?.shutdown();
    if (widget.gateway == null) await widget.nativeGateway?.shutdown();
    final settings = SettingsService(
      database: widget.accounts.database,
      accounts: widget.accounts,
      accountId: null,
    );
    try {
      await settings.completeReset(
        firstConfirmation: true,
        secondConfirmation: true,
      );
    } on BrowserSessionClearAfterResetError {
      // The database transaction has already removed the complete local
      // partition; a post-delete browser cleanup failure must not leave the
      // caller on a route that can reuse stale account data.
    }
  }

  Future<void> _importFile() async {
    final importBundle =
        widget.importBundle ??
        (widget.gateway is SourceJobImportReader
            ? (widget.gateway! as SourceJobImportReader).importBundle
            : widget.coordinator!.importBundle);
    final action = FileImportAction(
      accounts: widget.accounts,
      picker: widget.filePicker,
      confirmTarget: _confirmTarget,
      importBundle: importBundle,
    );
    try {
      final outcome = await action.run();
      if (!mounted) return;
      final message = switch (outcome) {
        FileImportCompleted() => '导入完成',
        FileImportCancelled() => '已取消导入',
        FileImportRejected(:final code) => '无法导入：$code',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('文件校验或导入失败')));
      }
    }
  }

  Future<String?> _confirmTarget(
    List<AccountSummary> accounts,
    String? preselected,
  ) async {
    var selected = preselected;
    return showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('确认导入账号'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final account in accounts)
                ListTile(
                  leading: Icon(
                    selected == account.id
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  selected: selected == account.id,
                  title: Text(account.maskedHint),
                  onTap: () => setDialogState(() => selected = account.id),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: selected == null
                  ? null
                  : () => Navigator.pop(context, selected),
              child: const Text('确认导入'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: widget.onExit == null
            ? null
            : IconButton(
                key: const Key('exit-sync'),
                tooltip: '退出同步',
                onPressed: widget.onExit,
                icon: const Icon(Icons.arrow_back),
              ),
        title: const Text('同步'),
      ),
      body: Column(
        children: [
          if (widget.surfaceHost != null ||
              widget.nativeGateway is JwWebViewSurfaceProvider)
            Offstage(
              key: const Key('jw-webview-surface-visibility'),
              offstage: !busy,
              child: KeyedSubtree(
                key: const Key('jw-webview-surface-host'),
                child: _buildWebViewSurface(
                  (widget.surfaceHost ??
                          (widget.nativeGateway! as JwWebViewSurfaceProvider)
                              .surfaceHost)
                      .widget,
                ),
              ),
            ),
          if (widget.diagnostics != null)
            ValueListenableBuilder<List<String>>(
              valueListenable: widget.diagnostics!,
              builder: (context, entries, _) {
                if (entries.isEmpty) return const SizedBox.shrink();
                return _DebugDiagnosticsPanel(entries: entries);
              },
            ),
          Expanded(
            child: widget.reauthenticateAccountId != null
                ? _ReauthenticationPanel(
                    maskedHint: reauthenticationHint ?? '本地账号',
                    usernameController: usernameController,
                    passwordController: passwordController,
                    savePassword: savePassword,
                    busy: busy,
                    onSavePasswordChanged: (value) {
                      setState(() => savePassword = value);
                    },
                    onSubmit: _reauthenticate,
                  )
                : accountId == null
                ? _FirstLoginPanel(
                    usernameController: usernameController,
                    passwordController: passwordController,
                    savePassword: savePassword,
                    busy: busy,
                    onSavePasswordChanged: (value) {
                      setState(() => savePassword = value);
                    },
                    onSubmit: _firstLogin,
                  )
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (states.values.any(
                        (state) =>
                            state.resultCode == 'reauthentication_required',
                      )) ...[
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.key_off_outlined),
                          title: const Text('请先重新登录'),
                          subtitle: const Text('安全凭据已删除，同步不会自动启动登录窗口。'),
                          trailing: FilledButton(
                            key: const Key('sync-reauthenticate'),
                            onPressed:
                                accountId == null ||
                                    widget.onReauthenticationRequired == null
                                ? null
                                : () => widget.onReauthenticationRequired!(
                                    accountId!,
                                  ),
                            child: const Text('重新登录'),
                          ),
                        ),
                        const Divider(),
                      ],
                      Row(
                        children: [
                          FilledButton.icon(
                            key: const Key('sync-all'),
                            onPressed: busy
                                ? null
                                : () => _runAll(SyncTrigger.manual),
                            icon: const Icon(Icons.sync),
                            label: const Text('同步全部'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: busy ? null : _importFile,
                            icon: const Icon(Icons.file_open),
                            label: const Text('导入文件'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      for (final source in SyncSource.values)
                        ListTile(
                          leading: const Icon(Icons.school),
                          title: const Text('教务系统'),
                          subtitle: Text(
                            _stateLabel(states[source]),
                            key: Key('sync-state-${source.name}'),
                          ),
                          trailing: IconButton(
                            tooltip: '同步',
                            onPressed: busy
                                ? null
                                : () => _run(source, SyncTrigger.manual),
                            icon: const Icon(Icons.refresh),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// A visible WebView2 surface shown while a native collection job is active
  /// so the user can complete CAS login / CAPTCHA in the actual page. Uses a
  /// fixed-height area so the page layout is stable while the controller mounts.
  Widget _buildWebViewSurface(Widget surface) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('登录学校网站（原生浏览器）', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          const Text(
            '请在下方浏览器窗口中完成登录（用户名/密码/验证码）。完成登录后将自动继续同步。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 360,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: surface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _stateLabel(SyncSourceState? state) {
    if (state == null) return '尚未同步';
    final label = switch (state.phase) {
      SyncPhase.idle => '已是最新',
      SyncPhase.due => '等待同步',
      SyncPhase.running => '同步中',
      SyncPhase.needsUserAction => '等待登录',
      SyncPhase.succeeded => '上次同步成功',
      SyncPhase.failed => '上次同步失败',
      SyncPhase.cancelled => '已取消',
    };
    return state.lastSuccessfulAt == null
        ? label
        : '$label · ${state.lastSuccessfulAt!.toLocal()}';
  }
}

/// Debug-only visible stage-log panel. Driven by the privacy-safe diagnostics
/// stream; shows recent stage names (never URL/account/query/DOM). Wired only
/// in debug/profile builds via [SyncPage.diagnostics]; release keeps it null.
class _DebugDiagnosticsPanel extends StatelessWidget {
  const _DebugDiagnosticsPanel({required this.entries});

  final List<String> entries;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('调试日志', style: Theme.of(context).textTheme.labelLarge),
                  const Spacer(),
                  Text('${entries.length} 条'),
                ],
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 140,
                child: ListView.builder(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  itemCount: entries.length,
                  itemBuilder: (context, index) => Text(
                    entries[index],
                    key: Key('diagnostic-$index'),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: Color(0xFFCDCDCD),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReauthenticationPanel extends StatelessWidget {
  const _ReauthenticationPanel({
    required this.maskedHint,
    required this.usernameController,
    required this.passwordController,
    required this.savePassword,
    required this.busy,
    required this.onSavePasswordChanged,
    required this.onSubmit,
  });

  final String maskedHint;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final bool savePassword;
  final bool busy;
  final ValueChanged<bool> onSavePasswordChanged;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('重新登录', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text('本地数据分区：$maskedHint'),
        const SizedBox(height: 16),
        TextField(
          key: const Key('reauth-username'),
          controller: usernameController,
          enabled: !busy,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: '完整学校账号',
            prefixIcon: Icon(Icons.badge_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('reauth-password'),
          controller: passwordController,
          enabled: !busy,
          obscureText: true,
          onSubmitted: (_) => onSubmit(),
          decoration: const InputDecoration(
            labelText: '密码（可选）',
            prefixIcon: Icon(Icons.password_outlined),
          ),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: savePassword,
          onChanged: busy
              ? null
              : (value) => onSavePasswordChanged(value ?? false),
          title: const Text('保存密码'),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const Key('submit-reauthentication'),
          onPressed: busy ? null : onSubmit,
          icon: busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.login),
          label: const Text('重新登录并同步教务'),
        ),
      ],
    );
  }
}

class _FirstLoginPanel extends StatelessWidget {
  const _FirstLoginPanel({
    required this.usernameController,
    required this.passwordController,
    required this.savePassword,
    required this.busy,
    required this.onSavePasswordChanged,
    required this.onSubmit,
  });

  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final bool savePassword;
  final bool busy;
  final ValueChanged<bool> onSavePasswordChanged;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('绑定学校账号', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        TextField(
          key: const Key('first-login-username'),
          controller: usernameController,
          enabled: !busy,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: '学校账号',
            prefixIcon: Icon(Icons.badge_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('first-login-password'),
          controller: passwordController,
          enabled: !busy,
          obscureText: true,
          onSubmitted: (_) => onSubmit(),
          decoration: const InputDecoration(
            labelText: '密码（可选）',
            prefixIcon: Icon(Icons.password_outlined),
          ),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: savePassword,
          onChanged: busy
              ? null
              : (value) => onSavePasswordChanged(value ?? false),
          title: const Text('保存密码'),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const Key('first-login-submit'),
          onPressed: busy ? null : onSubmit,
          icon: busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.login),
          label: const Text('登录并同步教务'),
        ),
      ],
    );
  }
}
