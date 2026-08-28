import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/database/app_database.dart';
import '../../../core/security/credential_protector_factory.dart';
import '../../accounts/application/account_service.dart';
import '../../import/application/import_service.dart';
import '../../import/application/reminder_reconciler.dart';
import '../../import/data/source_bundle_decoder.dart';
import '../../import/presentation/file_import_action.dart';
import '../../settings/application/settings_service.dart';
import '../application/sync_coordinator.dart';
import '../data/bridge_client.dart';
import '../data/python_locator.dart';
import '../domain/sync_state.dart';
import '../native/native_jw_gateway.dart';

String _sanitizeOpaqueAccountId(String accountId) {
  final sanitized = accountId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return sanitized.isEmpty ? 'account' : sanitized;
}

NativeJwGateway _createNativeJwGateway() {
  return NativeJwGateway(
    userDataPathForAccount: (accountId) async {
      final support = await getApplicationSupportDirectory();
      return p.join(
        support.path,
        'webview',
        _sanitizeOpaqueAccountId(accountId),
      );
    },
  );
}

Future<void> runStartupAutomaticSync(
  AppDatabase database, {
  ReminderReconciler reminderReconciler = const NoopReminderReconciler(),
}) async {
  // M7 (native channel): the startup automatic sync no longer creates its own
  // gateway. A second NativeJwGateway would race the sync page's gateway for
  // the same WebView2 UDF (profile lock) and drive an invisible collection
  // (its surface is never mounted), so its result could never surface to the
  // user. Automatic sync now belongs to the page's coordinator (the UI owns
  // the one visible WebView). The Python Bridge fallback keeps its original
  // headless startup behavior.
  if (!kUsePythonBridgeFallback) {
    return;
  }
  BridgeGateway? bridge;
  try {
    final accounts = AccountService(
      database: database,
      protector: defaultCredentialProtector(),
    );
    final account = await accounts.activeAccount();
    if (account == null) return;
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
    final coordinator = SyncCoordinator(
      database: database,
      accounts: accounts,
      bridgeFactory: () async {
        final current = bridge;
        if (current != null) return current;
        if (!kUsePythonBridgeFallback) {
          return bridge = NativeJwGateway(
            userDataPathForAccount: (accountId) async {
              final support = await getApplicationSupportDirectory();
              return p.join(
                support.path,
                'webview',
                _sanitizeOpaqueAccountId(accountId),
              );
            },
          );
        }
        final executable = await PythonLocator().locate(
          savedExecutable: await SettingsService(
            database: database,
            accounts: accounts,
            accountId: account.id,
          ).pythonPath(),
        );
        return bridge = await BridgeClient.start(pythonExecutable: executable);
      },
      importBundle: importer.importBytes,
    );
    await coordinator.recoverInterruptedRuns();
    await coordinator.syncAll(
      trigger: SyncTrigger.automatic,
      accountId: account.id,
      resolveUserAction: (_) async => false,
    );
  } on Object {
    // Startup synchronization is best-effort and must not block local data.
  } finally {
    await bridge?.shutdown();
  }
}

class SyncPageLoader extends StatefulWidget {
  const SyncPageLoader({
    required this.database,
    this.reminderReconciler = const NoopReminderReconciler(),
    this.reauthenticateAccountId,
    this.onReauthenticated,
    this.onReauthenticationRequired,
    this.onExit,
    this.nativeGateway,
    this.nativeGatewayFactory,
    super.key,
  });

  final AppDatabase database;
  final ReminderReconciler reminderReconciler;
  final String? reauthenticateAccountId;
  final VoidCallback? onReauthenticated;
  final ValueChanged<String>? onReauthenticationRequired;
  final VoidCallback? onExit;

  /// Optional gateway seam for tests and hosts that already own the native
  /// gateway. The loader still owns the supplied gateway for its lifetime.
  final NativeJwGateway? nativeGateway;

  /// Optional asynchronous gateway seam for lifecycle tests and hosts that
  /// defer gateway creation. The loader owns the resolved gateway.
  final Future<NativeJwGateway> Function()? nativeGatewayFactory;

  @override
  State<SyncPageLoader> createState() => _SyncPageLoaderState();
}

class _SyncPageLoaderState extends State<SyncPageLoader> {
  late final Future<_SyncDependencies> dependencies;
  BridgeGateway? bridge;
  NativeJwGateway? nativeGateway;
  Future<NativeJwGateway>? _nativeGatewayCreation;
  StreamSubscription<String>? _diagnosticSub;
  bool _disposed = false;
  final Set<BridgeGateway> _shutdownGateways = Set<BridgeGateway>.identity();

  /// Privacy-safe stage-log buffer for the debug diagnostics panel. Only
  /// allocated in debug/profile builds; in release it stays null so the panel
  /// and its overhead never ship. Cap keeps the UI bounded.
  final ValueNotifier<List<String>>? diagnostics = kDebugMode
      ? ValueNotifier<List<String>>(const <String>[])
      : null;

  @override
  void initState() {
    super.initState();
    // Register the gateway synchronously, before _build can cross its first
    // await. This makes dispose() the owner even when dependency loading is
    // still in flight. A deferred factory is joined below and handled with
    // the same disposed/once-only ownership path.
    if (!kUsePythonBridgeFallback) {
      final supplied = widget.nativeGateway;
      if (supplied != null) {
        nativeGateway = supplied;
      } else {
        final factory = widget.nativeGatewayFactory;
        if (factory != null) {
          final creation = Future<NativeJwGateway>.sync(factory);
          _nativeGatewayCreation = creation;
          // _build may still be waiting on an unrelated dependency when the
          // State is unmounted. Observe this future independently so a
          // gateway returned later is still closed, even if _build never
          // reaches its await site again.
          unawaited(
            creation.then<void>((gateway) {
              if (_disposed) _shutdownOnce(gateway);
            }, onError: (Object error, StackTrace stack) {}),
          );
        } else {
          nativeGateway = _createNativeJwGateway();
        }
      }
    }
    dependencies = _build();
  }

  void _ensureAlive() {
    if (_disposed) {
      throw StateError('sync page loader is disposed');
    }
  }

  void _shutdownOnce(BridgeGateway gateway) {
    if (!_shutdownGateways.add(gateway)) return;
    unawaited(gateway.shutdown());
  }

  Future<_SyncDependencies> _build() async {
    final schemaText = await rootBundle.loadString(
      'assets/schemas/source-bundle-1.0.draft7.schema.json',
    );
    final accounts = AccountService(
      database: widget.database,
      protector: defaultCredentialProtector(),
    );
    final importer = ImportService(
      database: widget.database,
      decoder: SourceBundleDecoder(
        jsonDecode(schemaText) as Map<String, dynamic>,
      ),
      reminderReconciler: widget.reminderReconciler,
    );
    // M7: native WebView2 is the default channel; the Python Bridge remains
    // reachable via the kUsePythonBridgeFallback switch (one-source-one-
    // channel — never both at once, per red line). The gateway owns exactly
    // one WebView2 environment and receives an account-bound UDF resolver;
    // multiple gateways would multiply initializeEnvironment calls — the
    // known AppHang trigger.
    final fallback = kUsePythonBridgeFallback;
    NativeJwGateway? gw;
    if (!fallback) {
      gw = nativeGateway;
      if (gw == null) {
        final creation = _nativeGatewayCreation;
        if (creation != null) {
          gw = await creation;
          // A factory may complete after the State has unmounted. Do not
          // assign or use that gateway through the disposed State; it is
          // still ours to shut down exactly once.
          if (_disposed) {
            _shutdownOnce(gw);
            throw StateError('sync page loader is disposed');
          }
          nativeGateway = gw;
        } else {
          // This is defensive for an unexpected re-entry; initState normally
          // registers the default gateway before _build starts.
          _ensureAlive();
          gw = _createNativeJwGateway();
          nativeGateway = gw;
        }
      }
      _ensureAlive();
    }
    final activeNativeGateway = gw;
    if (activeNativeGateway != null && diagnostics != null) {
      _diagnosticSub = activeNativeGateway.diagnostics.listen((event) {
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
        if (!fallback) {
          final native = activeNativeGateway;
          if (native == null) {
            throw StateError('native gateway is unavailable');
          }
          _ensureAlive();
          bridge = native;
          return native;
        }
        final account = await accounts.activeAccount();
        _ensureAlive();
        final executable = await PythonLocator().locate(
          savedExecutable: account == null
              ? null
              : await SettingsService(
                  database: widget.database,
                  accounts: accounts,
                  accountId: account.id,
                ).pythonPath(),
        );
        _ensureAlive();
        final started = await BridgeClient.start(pythonExecutable: executable);
        if (_disposed) {
          _shutdownOnce(started);
          throw StateError('sync page loader is disposed');
        }
        bridge = started;
        return started;
      },
      importBundle: importer.importBytes,
    );
    await coordinator.recoverInterruptedRuns();
    _ensureAlive();
    return _SyncDependencies(
      accounts: accounts,
      coordinator: coordinator,
      nativeGateway: fallback ? null : activeNativeGateway,
      diagnostics: fallback ? null : diagnostics,
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
    final ownedGateway = nativeGateway ?? bridge;
    if (ownedGateway != null) {
      _shutdownOnce(ownedGateway);
    }
    super.dispose();
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
          nativeGateway: value.nativeGateway,
          diagnostics: value.diagnostics,
          reauthenticateAccountId: widget.reauthenticateAccountId,
          onReauthenticated: widget.onReauthenticated,
          onReauthenticationRequired: widget.onReauthenticationRequired,
          onExit: widget.onExit,
        );
      },
    );
  }
}

class _SyncDependencies {
  const _SyncDependencies({
    required this.accounts,
    required this.coordinator,
    this.nativeGateway,
    this.diagnostics,
  });

  final AccountService accounts;
  final SyncCoordinator coordinator;
  final NativeJwGateway? nativeGateway;
  final ValueNotifier<List<String>>? diagnostics;
}

class SyncPage extends StatefulWidget {
  const SyncPage({
    required this.accounts,
    required this.coordinator,
    this.nativeGateway,
    this.diagnostics,
    this.filePicker = const SystemImportFilePicker(),
    this.reauthenticateAccountId,
    this.onReauthenticated,
    this.onReauthenticationRequired,
    this.onExit,
    super.key,
  });

  final AccountService accounts;
  final SyncCoordinator coordinator;
  final NativeJwGateway? nativeGateway;
  final ValueNotifier<List<String>>? diagnostics;
  final ImportFilePicker filePicker;
  final String? reauthenticateAccountId;
  final VoidCallback? onReauthenticated;
  final ValueChanged<String>? onReauthenticationRequired;
  final VoidCallback? onExit;

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
    _loadAndAutoSync();
  }

  @override
  void dispose() {
    usernameController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> _loadAndAutoSync() async {
    final reauthenticateId = widget.reauthenticateAccountId;
    if (reauthenticateId != null) {
      accountId = reauthenticateId;
      final summaries = await widget.accounts.summaries();
      for (final summary in summaries) {
        if (summary.id == reauthenticateId) {
          reauthenticationHint = summary.maskedHint;
          break;
        }
      }
      if (!mounted) return;
      await _refresh();
      return;
    }
    final account = await widget.accounts.activeAccount();
    if (!mounted) return;
    accountId = account?.id;
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
      loaded[source] = await widget.coordinator.stateFor(source, id);
    }
    if (mounted) setState(() => states = loaded);
  }

  Future<void> _run(SyncSource source, SyncTrigger trigger) async {
    final id = accountId;
    if (id == null || busy) return;
    setState(() => busy = true);
    final outcome = await widget.coordinator.sync(
      source,
      trigger: trigger,
      accountId: id,
    );
    await _handle(outcome);
    if (mounted) setState(() => busy = false);
    await _refresh();
  }

  Future<void> _runAll(SyncTrigger trigger) async {
    final id = accountId;
    if (id == null || busy) return;
    setState(() => busy = true);
    await widget.coordinator.syncAll(
      trigger: trigger,
      accountId: id,
      resolveUserAction: trigger == SyncTrigger.automatic
          ? (_) async => false
          : _confirmInteractiveLogin,
    );
    if (mounted) setState(() => busy = false);
    await _refresh();
  }

  Future<SyncOutcome> _handle(SyncOutcome outcome) async {
    if (outcome is! SyncNeedsUserAction || !mounted) return outcome;
    final confirmed = await _confirmInteractiveLogin(outcome);
    return widget.coordinator.resumeInteractive(
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
    var outcome = await widget.coordinator.firstLoginSync(
      SyncSource.jw,
      username: username,
      password: passwordController.text.isEmpty
          ? null
          : passwordController.text,
      savePassword: savePassword,
    );
    outcome = await _handle(outcome);
    passwordController.clear();
    if (!mounted) return;
    if (outcome is SyncSucceeded) {
      accountId = (await widget.accounts.activeAccount())?.id;
      await _refresh();
    }
    if (mounted) {
      setState(() => busy = false);
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
    final username = usernameController.text.trim();
    if (id == null || username.isEmpty || busy) return;
    setState(() => busy = true);
    var outcome = await widget.coordinator.reauthenticate(
      SyncSource.jw,
      accountId: id,
      username: username,
      password: passwordController.text.isEmpty
          ? null
          : passwordController.text,
      savePassword: savePassword,
    );
    outcome = await _handle(outcome);
    passwordController.clear();
    if (!mounted) return;
    setState(() => busy = false);
    if (outcome is SyncSucceeded) {
      widget.onReauthenticated?.call();
    }
    final message = switch (outcome) {
      SyncSucceeded() => '重新登录成功，教务同步完成',
      SyncCancelled() => '已取消重新登录',
      SyncFailed(:final code) => '重新登录失败：$code',
      _ => '重新登录未完成',
    };
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _importFile() async {
    final action = FileImportAction(
      accounts: widget.accounts,
      picker: widget.filePicker,
      confirmTarget: _confirmTarget,
      importBundle: widget.coordinator.importBundle,
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
          if (widget.nativeGateway != null)
            Offstage(
              key: const Key('jw-webview-surface-visibility'),
              offstage: !busy,
              child: KeyedSubtree(
                key: const Key('jw-webview-surface-host'),
                child: _buildWebViewSurface(
                  widget.nativeGateway!.surfaceHost.widget,
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
