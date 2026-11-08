import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app/agent_settings_panel.dart';
import 'app/app_design.dart';
import 'app/calendar_workspace_page.dart';
import 'app/demo_runtime.dart';
import 'app/diagnostic_error_hooks.dart';
import 'app/diagnostics_panel.dart';
import 'app/jw_sync_panel.dart';
import 'app/maintenance_recovery_page.dart';
import 'app/m6_settings_panel.dart';
import 'app/morning_brief_card.dart';
import 'app/product_app.dart';
import 'app/young_daily_sync_panel.dart';
import 'app/young_sync_panel.dart';
import 'core/agenda_contract.dart';
import 'core/calendar_contract.dart';
import 'core/contracts.dart';
import 'core/diagnostics_contract.dart';
import 'core/morning_brief_contract.dart';
import 'core/reminder_contract.dart';
import 'core/settings_contract.dart';
import 'platform/ios_runtime_platform_factory.dart';
import 'platform/transient_diagnostics.dart';

const _revision = String.fromEnvironment(
  'USTC_BUILD_REVISION',
  defaultValue: 'unknown',
);
const _platformChannel = MethodChannel('ustc_assistant/platform_v1');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IOSI3App());
}

typedef IOSI3BootstrapOpener =
    Future<RuntimeBootstrap> Function(IOSRuntimePlatformFactory platform);

/// A private iOS surface for schedule, school sources and reminders.
/// The bootstrap remains the single owner of all runtime resources.
final class IOSI3App extends StatefulWidget {
  const IOSI3App({super.key, this.openBootstrap});

  @visibleForTesting
  final IOSI3BootstrapOpener? openBootstrap;

  @override
  State<IOSI3App> createState() => _IOSI3AppState();
}

final class _IOSI3AppState extends State<IOSI3App> {
  final _screenKey = GlobalKey<_IOSI3ScreenState>();
  late final _routeObserver = _IOSI3RouteObserver(
    () => _screenKey.currentState?._routeChanged(),
  );

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    navigatorObservers: [_routeObserver],
    theme: productTheme,
    home: _IOSI3Screen(key: _screenKey, openBootstrap: widget.openBootstrap),
  );
}

final class _IOSI3RouteObserver extends NavigatorObserver {
  _IOSI3RouteObserver(this.onChanged);

  final VoidCallback onChanged;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    onChanged();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    onChanged();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    onChanged();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    onChanged();
  }
}

final class _IOSI3Screen extends StatefulWidget {
  const _IOSI3Screen({super.key, this.openBootstrap});

  final IOSI3BootstrapOpener? openBootstrap;

  @override
  State<_IOSI3Screen> createState() => _IOSI3ScreenState();
}

final class _IOSI3ScreenState extends State<_IOSI3Screen> {
  RuntimeBootstrap? _bootstrap;
  DemoRuntime? _boundRuntime;
  StreamSubscription<ReminderTarget>? _reminderNavigation;
  StreamSubscription<MorningRuntimeView>? _morningChanges;
  late final AppLifecycleListener _lifecycle;
  final _startupDiagnostics = TransientDiagnostics(
    versions: const DiagnosticVersions(revision: _revision),
  );
  DiagnosticErrorHooks? _diagnosticErrors;
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  String? _failure;
  String _nativeRevision = 'unknown';
  String _bundleId = 'unknown';
  bool? _revisionMatches;
  MorningRuntimeView _morningView = const MorningRuntimeView();
  DateTime? _hiddenMorningDay;
  bool _busy = true;
  bool _modelConfigRouteOpen = false;
  bool _modelConfigBusy = false;
  bool _sourceYoungSelected = false;
  bool _evidenceTasks = false;
  CalendarReference? _evidenceSelection;
  int _selectedTab = 0;
  int _runtimeGeneration = 0;
  int _routeGeneration = 0;

  DiagnosticsPort get _diagnostics =>
      _bootstrap?.diagnostics ?? _startupDiagnostics;

  void _bindDiagnosticErrors() {
    _diagnosticErrors?.dispose();
    _diagnosticErrors = DiagnosticErrorHooks(_diagnostics);
  }

  @override
  void initState() {
    super.initState();
    _bindDiagnosticErrors();
    _lifecycle = AppLifecycleListener(
      onStateChange: _onLifecycleStateChanged,
      onExitRequested: () async {
        try {
          await _bootstrap?.close();
          return AppExitResponse.exit;
        } on Object {
          return AppExitResponse.cancel;
        }
      },
    );
    unawaited(_openOwnedRuntime());
  }

  @override
  void dispose() {
    _runtimeGeneration++;
    _routeGeneration++;
    _reminderNavigation?.cancel();
    _morningChanges?.cancel();
    _lifecycle.dispose();
    _diagnosticErrors?.dispose();
    unawaited(_startupDiagnostics.close());
    final bootstrap = _bootstrap;
    if (bootstrap != null) unawaited(bootstrap.close());
    super.dispose();
  }

  Future<void> _openOwnedRuntime() async {
    RuntimeBootstrap? opened;
    try {
      final platform = IOSRuntimePlatformFactory();
      final buildInfo = await _platformChannel
          .invokeMapMethod<String, Object?>('i3BuildInfo')
          .timeout(const Duration(seconds: 5));
      if (buildInfo == null ||
          buildInfo.length != 4 ||
          buildInfo.keys.toSet().difference(const {
            'revision',
            'bundleId',
            'authentication',
            'notificationBackend',
          }).isNotEmpty ||
          buildInfo['revision'] is! String ||
          buildInfo['bundleId'] is! String ||
          (buildInfo['bundleId'] as String).isEmpty ||
          buildInfo['authentication'] != 'manual' ||
          buildInfo['notificationBackend'] != 'user-notifications-v1') {
        throw const AppFailure(FailureCode.invalidSnapshot);
      }
      _nativeRevision = buildInfo['revision'] as String;
      _bundleId = buildInfo['bundleId'] as String;
      _revisionMatches = _isRevision(_revision) && _isRevision(_nativeRevision)
          ? _nativeRevision == _revision
          : null;
      opened =
          await (widget.openBootstrap?.call(platform) ??
              // This is the iOS acceptance entry: only its native factory may own
              // production directories, credentials and browser resources.
              // ignore: invalid_use_of_visible_for_testing_member
              RuntimeBootstrap.open(platformFactory: platform));
      if (!mounted) {
        await opened.close();
        return;
      }
      _bootstrap = opened;
      _bindDiagnosticErrors();
      final runtime = opened.runtime;
      final maintenanceBlocksProduct =
          opened.settings.settingsView.maintenance.blocksProduct;
      _syncRuntime(
        runtime == null || maintenanceBlocksProduct ? null : runtime,
      );
      setState(() {
        _failure = runtime == null && !maintenanceBlocksProduct
            ? opened!.settings.settingsView.failure?.name ??
                  'runtime_unavailable'
            : null;
        _busy = false;
      });
    } on Object catch (error) {
      if (opened != null && !identical(_bootstrap, opened)) {
        // A partially assembled owner remains available for a safe retry.
        _bootstrap = opened;
        _bindDiagnosticErrors();
      }
      _recordFailure(error);
    }
  }

  Future<void> _retry() async {
    if (_busy) return;
    final current = _bootstrap;
    if (current == null) {
      setState(() {
        _busy = true;
        _failure = null;
      });
      await _openOwnedRuntime();
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      // Reuse the retained owner. Reopening could acquire a second owner while
      // recovery or an unfinished close still holds the original resources.
      await current.settings.retryMaintenance();
      final runtime = current.runtime;
      if (runtime == null) {
        throw const AppFailure(FailureCode.cleanupPending);
      }
      if (!mounted) return;
      _syncRuntime(
        current.settings.settingsView.maintenance.blocksProduct
            ? null
            : runtime,
      );
      setState(() {
        _failure = null;
        _busy = false;
      });
    } on Object catch (error) {
      _recordFailure(error);
    }
  }

  Future<void> _closeBootstrap() async {
    if (_busy) return;
    final current = _bootstrap;
    if (current == null) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await current.close();
      if (!mounted) return;
      _syncRuntime(null);
      setState(() {
        _bootstrap = null;
        _failure = 'closed';
        _busy = false;
      });
      _bindDiagnosticErrors();
    } on Object catch (error) {
      _recordFailure(error);
    }
  }

  void _recordFailure(Object error) {
    if (!mounted) return;
    setState(() {
      _failure = switch (error) {
        AppFailure(:final code) => code.name,
        SettingsFailure(:final code) => code.name,
        PlatformException(:final code)
            when const {
              'unsafe_directory',
              'storage_failed',
              'unavailable',
              'unsupported_platform',
            }.contains(code) =>
          code,
        _ => 'platform_or_storage_failed',
      };
      _busy = false;
    });
    try {
      _diagnostics.record(
        DiagnosticEvent(
          name: DiagnosticEventName.applicationFailed,
          stage: DiagnosticStage.startup,
          outcome: DiagnosticOutcome.failure,
          code: diagnosticCode(_failure),
        ),
      );
    } on Object {
      // The startup result remains usable if diagnostics are unavailable.
    }
  }

  bool _isResumed() {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  bool _automaticWorkAllowed() {
    final bootstrap = _bootstrap;
    return _boundRuntime != null &&
        _isResumed() &&
        !_modelConfigRouteOpen &&
        !_modelConfigBusy &&
        bootstrap != null &&
        !bootstrap.settings.settingsView.maintenance.blocksProduct;
  }

  void _syncAutomaticForeground() {
    final runtime = _boundRuntime;
    if (runtime == null) return;
    final allowed = _automaticWorkAllowed();
    runtime.morning.onForeground(allowed);
    runtime.youngDaily.onForeground(allowed);
  }

  void _onLifecycleStateChanged(AppLifecycleState state) {
    final runtime = _boundRuntime;
    if (runtime == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _syncAutomaticForeground();
        runtime.reminders.onForeground();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        runtime.morning.onForeground(false);
        runtime.youngDaily.onForeground(false);
        break;
    }
  }

  void _syncRuntime(DemoRuntime? runtime) {
    if (identical(_boundRuntime, runtime)) return;
    _boundRuntime?.morning.onForeground(false);
    _boundRuntime?.youngDaily.onForeground(false);
    _reminderNavigation?.cancel();
    _morningChanges?.cancel();
    _runtimeGeneration++;
    _routeGeneration++;
    _reminderNavigation = null;
    _morningChanges = null;
    _boundRuntime = runtime;
    _morningView = runtime?.morning.view ?? const MorningRuntimeView();
    _hiddenMorningDay = null;
    _modelConfigRouteOpen = false;
    _modelConfigBusy = false;
    if (runtime == null) return;

    final generation = _runtimeGeneration;
    _morningChanges = runtime.morning.changes.listen((next) {
      if (!_isCurrentRuntime(runtime, generation)) return;
      setState(() => _morningView = next);
    }, onError: (Object _) {});
    _reminderNavigation = runtime.reminders.navigation.listen(
      (target) => unawaited(
        _openReminderTarget(runtime, target, generation, _routeGeneration),
      ),
      onError: (Object _) {
        if (mounted && _isCurrentRuntime(runtime, generation)) {
          _messengerKey.currentState?.showSnackBar(
            const SnackBar(content: Text('无法打开这条系统提醒，请从日程中重新选择。')),
          );
        }
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isCurrentRuntime(runtime, generation)) return;
      _syncAutomaticForeground();
    });
  }

  bool _isCurrentRuntime(DemoRuntime runtime, int generation) =>
      mounted &&
      generation == _runtimeGeneration &&
      identical(_boundRuntime, runtime) &&
      identical(_bootstrap?.runtime, runtime) &&
      _bootstrap != null &&
      !_bootstrap!.settings.settingsView.maintenance.blocksProduct;

  Future<void> _openReminderTarget(
    DemoRuntime runtime,
    ReminderTarget target,
    int runtimeGeneration,
    int routeGeneration,
  ) async {
    bool isCurrent() =>
        _isCurrentRuntime(runtime, runtimeGeneration) &&
        routeGeneration == _routeGeneration;

    try {
      final localCalendar = runtime.jwStore.localCalendar;
      await localCalendar.ensureCalendarContext(target.context);
      if (!isCurrent()) return;

      if (target.kind == ReminderKind.taskDeadline) {
        final reference = TaskReference(
          target.context,
          target.localId,
          target.version,
        );
        final detail = await localCalendar.taskDetail(reference);
        bool matchesTask(TaskReference candidate) =>
            candidate.context == reference.context &&
            candidate.localId == reference.localId &&
            candidate.version == reference.version;
        if (!isCurrent() || !matchesTask(detail.task.reference)) return;
        await runtime.calendar.loadTasks();
        await runtime.calendar.selectTask(detail.task.reference);
        await localCalendar.ensureCalendarContext(target.context);
        if (!isCurrent() ||
            runtime.calendar.taskView.window?.context != target.context ||
            runtime.calendar.taskView.detail == null ||
            !matchesTask(runtime.calendar.taskView.detail!.task.reference)) {
          return;
        }
        _evidenceSelection = null;
        _evidenceTasks = true;
      } else {
        final kind = switch (target.kind) {
          ReminderKind.course => CalendarKind.course,
          ReminderKind.exam => CalendarKind.exam,
          ReminderKind.young => CalendarKind.young,
          ReminderKind.personal => CalendarKind.personal,
          ReminderKind.planBlock => CalendarKind.planBlock,
          ReminderKind.taskDeadline => throw StateError(
            'invalid calendar target',
          ),
        };
        final reference = CalendarReference(
          target.context,
          CalendarIdentity(kind, target.localId, ordinal: target.ordinal),
          target.version,
        );
        final detail = await localCalendar.detail(reference);
        if (!isCurrent() ||
            detail.occurrence.reference != reference ||
            detail.occurrence.reference.context != target.context) {
          return;
        }
        await runtime.calendar.load(
          day: beijingDay(detail.occurrence.startsAtUtc),
          filter: CalendarFilter.all,
          includeInactive: true,
        );
        await localCalendar.ensureCalendarContext(target.context);
        final currentDetail = await localCalendar.detail(
          detail.occurrence.reference,
        );
        if (!isCurrent() ||
            runtime.calendar.view.window?.context != target.context ||
            currentDetail.occurrence.reference != detail.occurrence.reference) {
          return;
        }
        _evidenceSelection = currentDetail.occurrence.reference;
        _evidenceTasks = false;
      }
      if (!mounted || !isCurrent()) return;
      setState(() {
        _selectedTab = 0;
        _routeGeneration++;
      });
    } on Object {
      if (mounted && isCurrent()) {
        _messengerKey.currentState?.showSnackBar(
          const SnackBar(content: Text('这条提醒已失效，请从当前日程或任务中重新选择。')),
        );
      }
    }
  }

  void _selectTab(int index) {
    if (_selectedTab == index) return;
    setState(() {
      _selectedTab = index;
      _routeGeneration++;
    });
  }

  void _routeChanged() {
    _routeGeneration++;
  }

  void _consumeInitialNavigation() {
    _evidenceSelection = null;
    _evidenceTasks = false;
  }

  Future<void> _openModelConfiguration(DemoRuntime runtime) async {
    final generation = _runtimeGeneration;
    _routeGeneration++;
    setState(() => _modelConfigRouteOpen = true);
    _syncAutomaticForeground();
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('配置晨报模型')),
            body: SafeArea(
              top: false,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: AppUi.formWidth),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: AgentSettingsPanel(
                      controller: runtime.agent,
                      setupMode: true,
                      onBusyChanged: (busy) =>
                          _onModelConfigurationBusy(runtime, generation, busy),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    } on Object {
      if (mounted && _isCurrentRuntime(runtime, generation)) {
        _messengerKey.currentState?.showSnackBar(
          const SnackBar(content: Text('暂时无法打开晨报模型配置。')),
        );
      }
    } finally {
      if (mounted && _isCurrentRuntime(runtime, generation)) {
        _routeGeneration++;
        setState(() {
          _modelConfigRouteOpen = false;
          _modelConfigBusy = false;
        });
        _syncAutomaticForeground();
      }
    }
  }

  void _onModelConfigurationBusy(
    DemoRuntime runtime,
    int generation,
    bool busy,
  ) {
    if (!_isCurrentRuntime(runtime, generation) || _modelConfigBusy == busy) {
      return;
    }
    setState(() => _modelConfigBusy = busy);
    _syncAutomaticForeground();
  }

  Future<void> _openRestrictedSource(
    BuildContext sourceContext,
    Uri uri,
  ) async {
    final host = uri.host.toLowerCase();
    final safe =
        uri.scheme.toLowerCase() == 'https' &&
        uri.hasAuthority &&
        uri.userInfo.isEmpty &&
        (uri.port == 443) &&
        const {
          'teach.ustc.edu.cn',
          'www.teach.ustc.edu.cn',
          'finance.ustc.edu.cn',
        }.contains(host) &&
        !RegExp(r'[\x00-\x1f\x7f]').hasMatch(uri.toString());
    if (!sourceContext.mounted) return;
    if (!safe) {
      ScaffoldMessenger.of(
        sourceContext,
      ).showSnackBar(const SnackBar(content: Text('该出处不是允许的 HTTPS 学校公开来源。')));
      return;
    }
    await showDialog<void>(
      context: sourceContext,
      builder: (dialogContext) => AlertDialog(
        title: const Text('学校公开出处'),
        content: SelectableText(uri.toString()),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () async {
              try {
                await Clipboard.setData(ClipboardData(text: uri.toString()));
                if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                if (sourceContext.mounted) {
                  ScaffoldMessenger.of(
                    sourceContext,
                  ).showSnackBar(const SnackBar(content: Text('已复制学校公开出处。')));
                }
              } on Object {
                if (dialogContext.mounted) {
                  ScaffoldMessenger.of(
                    dialogContext,
                  ).showSnackBar(const SnackBar(content: Text('复制学校公开出处失败。')));
                }
              }
            },
            child: const Text('复制链接'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _bootstrap == null
        ? const _NoopListenable()
        : Listenable.merge([_bootstrap!, _bootstrap!.settings]),
    builder: (context, _) {
      final bootstrap = _bootstrap;
      final runtime = bootstrap?.runtime;
      final maintenanceBlocksProduct =
          bootstrap?.settings.settingsView.maintenance.blocksProduct ?? false;
      _syncRuntime(
        runtime == null || maintenanceBlocksProduct ? null : runtime,
      );

      if (bootstrap != null && maintenanceBlocksProduct) {
        return MaintenanceRecoveryPage(settings: bootstrap.settings);
      }
      if (_busy) {
        return _startupScaffold(
          const Center(
            child: CircularProgressIndicator(key: ValueKey('ios-i3-opening')),
          ),
        );
      }
      if (bootstrap == null || runtime == null) {
        return _startupScaffold(_failureView());
      }

      final today = beijingDay(runtime.clock.nowUtc);
      final showMorning =
          _morningView.enabled &&
          (_hiddenMorningDay == null || !_sameDay(_hiddenMorningDay!, today));
      return ScaffoldMessenger(
        key: _messengerKey,
        child: Scaffold(
          appBar: AppBar(
            title: Text(const ['日程', '来源', '提醒'][_selectedTab]),
            actions: [
              DiagnosticsExportButton(diagnostics: _diagnostics),
              if (_revisionMatches == false)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Tooltip(
                    message: '构建修订与应用修订不一致',
                    child: Icon(
                      Icons.warning_amber_rounded,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              IconButton(
                tooltip: '应用版本信息',
                icon: const Icon(Icons.info_outline_rounded),
                onPressed: _showBuildInfo,
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                if (_selectedTab == 0 && showMorning)
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: AppUi.readingWidth,
                      ),
                      child: MorningBriefCard(
                        view: _morningView,
                        nowUtc: runtime.clock.nowUtc,
                        changes: runtime.morning.changes,
                        onRetry: () => runtime.morning.check(manual: true),
                        onHideToday: () =>
                            setState(() => _hiddenMorningDay = today),
                        openSource: (uri) =>
                            _openRestrictedSource(context, uri),
                      ),
                    ),
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth > AppUi.readingWidth
                          ? AppUi.readingWidth
                          : constraints.maxWidth;
                      return Center(
                        child: SizedBox(
                          width: width,
                          height: constraints.maxHeight,
                          child: IndexedStack(
                            index: _selectedTab,
                            children: [
                              _schedulePage(runtime),
                              _sourcesPage(runtime),
                              _remindersPage(runtime),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: NavigationBar(
            key: const ValueKey('ios-i3-bottom-navigation'),
            selectedIndex: _selectedTab,
            onDestinationSelected: _selectTab,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.calendar_month_outlined),
                selectedIcon: Icon(Icons.calendar_month),
                label: '日程',
              ),
              NavigationDestination(
                icon: Icon(Icons.school_outlined),
                selectedIcon: Icon(Icons.school),
                label: '来源',
              ),
              NavigationDestination(
                icon: Icon(Icons.notifications_none_outlined),
                selectedIcon: Icon(Icons.notifications),
                label: '提醒',
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _startupScaffold(Widget body) => ScaffoldMessenger(
    key: _messengerKey,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('日程'),
        actions: [DiagnosticsExportButton(diagnostics: _diagnostics)],
      ),
      body: SafeArea(child: body),
    ),
  );

  Widget _failureView() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sync_problem_outlined, size: 42),
            const SizedBox(height: 12),
            const Text('应用暂时无法安全打开。'),
            const SizedBox(height: 8),
            SelectableText(
              '安全错误码：${_failure ?? 'platform_or_storage_failed'}',
              key: const ValueKey('ios-i3-failure-code'),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('ios-i3-retry'),
              onPressed: _busy ? null : _retry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试'),
            ),
            if (_bootstrap != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const ValueKey('ios-i3-close-bootstrap'),
                onPressed: _busy ? null : _closeBootstrap,
                icon: const Icon(Icons.close_rounded),
                label: const Text('关闭并释放本次运行'),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  void _showBuildInfo() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('应用版本信息'),
        content: SelectableText(
          '修订：$_nativeRevision（${switch (_revisionMatches) {
            true => '一致',
            false => '不一致',
            null => '待确认',
          }}）\n应用身份：$_bundleId\n登录方式：手动登录\n系统通知：UserNotifications',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _schedulePage(DemoRuntime runtime) => CalendarWorkspacePage(
    key: const ValueKey('ios-i3-schedule-page'),
    controller: runtime.calendar,
    tasks: runtime.calendar,
    calendarTaskNowUtc: runtime.clock.nowUtc,
    reminders: runtime.jwStore.features,
    initialTasks: _evidenceTasks,
    initialSelection: _evidenceSelection,
    onInitialNavigationConsumed: _consumeInitialNavigation,
  );

  Widget _sourcesPage(DemoRuntime runtime) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: WorkspaceSection(
          title: '学校来源',
          description: '选择教务或二课来源，查看本机保存的检查状态并按需手动同步。',
          child: Row(
            children: [
              Expanded(
                child: _sourceChoice(
                  label: '教务',
                  selected: !_sourceYoungSelected,
                  onPressed: () => setState(() => _sourceYoungSelected = false),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _sourceChoice(
                  label: '二课',
                  selected: _sourceYoungSelected,
                  onPressed: () => setState(() => _sourceYoungSelected = true),
                ),
              ),
            ],
          ),
        ),
      ),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: _sourceYoungSelected
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    YoungSyncPanel(
                      controller: runtime.youngSync,
                      productMode: true,
                      embedded: true,
                      clock: () => runtime.clock.nowUtc,
                    ),
                    const SizedBox(height: 8),
                    YoungDailySyncPanel(controller: runtime.youngDaily),
                  ],
                )
              : JwSyncPanel(
                  controller: runtime.jwSync,
                  productMode: true,
                  embedded: true,
                ),
        ),
      ),
    ],
  );

  Widget _sourceChoice({
    required String label,
    required bool selected,
    required VoidCallback onPressed,
  }) => selected
      ? FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: onPressed,
          child: Text(label),
        )
      : OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: onPressed,
          child: Text(label),
        );

  Widget _remindersPage(DemoRuntime runtime) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey('ios-i3-configure-morning-model'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: () => _openModelConfiguration(runtime),
            icon: const Icon(Icons.tune_rounded),
            label: const Text('配置晨报模型'),
          ),
        ),
      ),
      Expanded(
        child: M6SettingsPanel(
          data: runtime.jwStore.features,
          briefs: runtime.jwStore.briefs,
          reminderChanges: runtime.reminders.changes,
          initialReminderView: runtime.reminders.view,
          retryReminders: runtime.reminders.refresh,
          testNotification: runtime.reminders.testNotification,
          configureSystemAccess: runtime.reminders.supportsSystemAccess
              ? runtime.reminders.configureSystemAccess
              : null,
          regenerateMorning: () => runtime.morning.check(manual: true),
        ),
      ),
    ],
  );
}

final class _NoopListenable implements Listenable {
  const _NoopListenable();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

bool _isRevision(String value) => RegExp(r'^[0-9a-f]{7,64}$').hasMatch(value);

bool _sameDay(DateTime first, DateTime second) =>
    first.year == second.year &&
    first.month == second.month &&
    first.day == second.day;
