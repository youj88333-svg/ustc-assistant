import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app/demo_runtime.dart';
import 'app/product_app.dart';
import 'app/app_shell_contract.dart';
import 'app/app_settings_page.dart';
import 'app/maintenance_recovery_page.dart';
import 'app/calendar_workspace_page.dart';
import 'app/agent_workspace_page.dart';
import 'app/agent_behavior_validation_panel.dart';
import 'app/agent_settings_panel.dart';
import 'app/diagnostics_panel.dart';
import 'app/diagnostic_error_hooks.dart';
import 'platform/agent_image_picker.dart';
import 'platform/transient_diagnostics.dart';
import 'core/diagnostics_contract.dart';
import 'agent/agent_tool_contract.dart';
import 'agent/agent_system_prompt.dart';
import 'app/jw_data_probe_panel.dart';
import 'app/jw_probe_panel.dart';
import 'app/jw_sync_panel.dart';
import 'app/m0_app.dart';
import 'app/observation_panel.dart';
import 'app/young_observation_panel.dart';
import 'app/young_read_only_panel.dart';
import 'app/young_business_probe_panel.dart';
import 'app/young_sync_panel.dart';
import 'app/public_validation_panel.dart';
import 'core/contracts.dart';
import 'core/calendar_contract.dart';
import 'core/agenda_contract.dart';
import 'core/reminder_contract.dart';
import 'app/m6_settings_panel.dart';

// This temporary panel is absent from normal product navigation.
const m3ValidationEnabled = bool.fromEnvironment('USTC_M3_VALIDATION');
const developmentDiagnosticsEnabled = bool.fromEnvironment('USTC_DIAGNOSTICS');

Future<void> launchM0() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final bootstrap = await RuntimeBootstrap.open();
    runApp(OwnedApplication(bootstrap: bootstrap));
  } catch (error) {
    final code = error is AppFailure ? error.code : FailureCode.storageFailed;
    final diagnostics = TransientDiagnostics(
      versions: const DiagnosticVersions(
        application: '0.0.1+0',
        schema: 16,
        tools: agentToolRegistryVersion,
        prompt: agentPromptVersion,
        revision: String.fromEnvironment(
          'USTC_BUILD_REVISION',
          defaultValue: 'unknown',
        ),
      ),
    );
    diagnostics.record(
      DiagnosticEvent(
        name: DiagnosticEventName.applicationFailed,
        stage: DiagnosticStage.startup,
        outcome: DiagnosticOutcome.failure,
        code: diagnosticCode(code.name),
      ),
    );
    runApp(M0StartupFailureApp(code: code, diagnostics: diagnostics));
  }
}

final class OwnedApplication extends StatefulWidget {
  const OwnedApplication({super.key, required this.bootstrap});
  final RuntimeBootstrap bootstrap;
  @override
  State<OwnedApplication> createState() => _OwnedAppState();
}

final class _OwnedAppState extends State<OwnedApplication> {
  late final AppLifecycleListener _lifecycle;
  late DiagnosticErrorHooks _diagnosticErrors;
  var _destination = ValueNotifier<ShellDestination>(ShellDestination.agent);
  int? _navigationResetEpoch;
  CalendarReference? _evidenceSelection;
  bool _evidenceTasks = false;
  DemoRuntime? _boundRuntime;
  StreamSubscription<ReminderTarget>? _reminderNavigation;
  int _runtimeGeneration = 0;
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  @override
  void initState() {
    super.initState();
    _diagnosticErrors = DiagnosticErrorHooks(widget.bootstrap.diagnostics);
    _lifecycle = AppLifecycleListener(
      onStateChange: _onLifecycleStateChanged,
      onExitRequested: () async {
        try {
          await widget.bootstrap.close();
          return AppExitResponse.exit;
        } catch (_) {
          return AppExitResponse.cancel;
        }
      },
    );
  }

  @override
  void dispose() {
    _runtimeGeneration++;
    _reminderNavigation?.cancel();
    _diagnosticErrors.dispose();
    _lifecycle.dispose();
    _destination.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant OwnedApplication oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bootstrap, widget.bootstrap)) {
      _diagnosticErrors.dispose();
      _diagnosticErrors = DiagnosticErrorHooks(widget.bootstrap.diagnostics);
      final runtime = widget.bootstrap.runtime;
      final maintenanceBlocksProduct =
          widget.bootstrap.settings.settingsView.maintenance.blocksProduct;
      _bindRuntime(
        runtime == null || maintenanceBlocksProduct ? null : runtime,
      );
    }
  }

  void _onLifecycleStateChanged(AppLifecycleState state) {
    final runtime = _boundRuntime;
    if (runtime == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        runtime.morning.onForeground(true);
        runtime.youngDaily.onForeground(true);
        runtime.reminders.onForeground();
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        runtime.morning.onForeground(false);
        runtime.youngDaily.onForeground(false);
        break;
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _bindRuntime(DemoRuntime? runtime) {
    if (identical(_boundRuntime, runtime)) return;
    _runtimeGeneration++;
    _reminderNavigation?.cancel();
    _reminderNavigation = null;
    _boundRuntime = runtime;
    if (runtime == null) return;

    final generation = _runtimeGeneration;
    _reminderNavigation = runtime.reminders.navigation.listen(
      (target) => unawaited(_openReminderTarget(runtime, target, generation)),
      onError: (Object _) {
        if (mounted) {
          _messengerKey.currentState?.showSnackBar(
            const SnackBar(content: Text('无法打开这条系统提醒，请从日程中重新选择。')),
          );
        }
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _runtimeGeneration ||
          !identical(widget.bootstrap.runtime, runtime)) {
        return;
      }
      final state = WidgetsBinding.instance.lifecycleState;
      if (state == null || state == AppLifecycleState.resumed) {
        runtime.morning.onForeground(true);
        runtime.youngDaily.onForeground(true);
      }
    });
  }

  bool _isCurrentRuntime(DemoRuntime runtime, int generation) =>
      mounted &&
      generation == _runtimeGeneration &&
      identical(_boundRuntime, runtime) &&
      identical(widget.bootstrap.runtime, runtime);

  Future<void> _openReminderTarget(
    DemoRuntime runtime,
    ReminderTarget target,
    int generation,
  ) async {
    try {
      final localCalendar = runtime.jwStore.localCalendar;
      await localCalendar.ensureCalendarContext(target.context);
      if (!_isCurrentRuntime(runtime, generation)) return;

      if (target.kind == ReminderKind.taskDeadline) {
        final reference = TaskReference(
          target.context,
          target.localId,
          target.version,
        );
        final detail = await localCalendar.taskDetail(reference);
        await runtime.calendar.loadTasks();
        await runtime.calendar.selectTask(detail.task.reference);
        await localCalendar.ensureCalendarContext(target.context);
        if (!_isCurrentRuntime(runtime, generation) ||
            runtime.calendar.taskView.window?.context != target.context ||
            runtime.calendar.taskView.detail?.task.reference.localId !=
                target.localId) {
          return;
        }
        setState(() {
          _evidenceSelection = null;
          _evidenceTasks = true;
        });
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
        await runtime.calendar.load(
          day: beijingDay(detail.occurrence.startsAtUtc),
          filter: CalendarFilter.all,
          includeInactive: true,
        );
        await localCalendar.ensureCalendarContext(target.context);
        final currentDetail = await localCalendar.detail(
          detail.occurrence.reference,
        );
        if (!_isCurrentRuntime(runtime, generation) ||
            runtime.calendar.view.window?.context != target.context ||
            currentDetail.occurrence.reference.identity !=
                detail.occurrence.reference.identity) {
          return;
        }
        setState(() {
          _evidenceSelection = currentDetail.occurrence.reference;
          _evidenceTasks = false;
        });
      }
      if (_destination.value != ShellDestination.agenda) {
        _destination.value = ShellDestination.agenda;
      }
    } on Object {
      if (mounted && _isCurrentRuntime(runtime, generation)) {
        _messengerKey.currentState?.showSnackBar(
          const SnackBar(content: Text('这条提醒已失效，请从当前日程或任务中重新选择。')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.bootstrap, widget.bootstrap.settings]),
    builder: (context, _) {
      final bootstrap = widget.bootstrap;
      final runtime = bootstrap.runtime;
      final view = bootstrap.settings.settingsView;
      _bindRuntime(
        runtime == null || view.maintenance.blocksProduct ? null : runtime,
      );
      if (runtime == null || view.maintenance.blocksProduct) {
        // The product subtree and its routes are withdrawn during maintenance;
        // old forms cannot remain attached to the next agenda/reset epoch.
        return MaterialApp(
          scaffoldMessengerKey: _messengerKey,
          debugShowCheckedModeBanner: false,
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: productTheme,
          home: MaintenanceRecoveryPage(settings: bootstrap.settings),
        );
      }
      final resetEpoch = view.snapshot?.context.resetEpoch;
      if (_navigationResetEpoch != null &&
          resetEpoch != _navigationResetEpoch) {
        _destination.dispose();
        _destination = ValueNotifier<ShellDestination>(ShellDestination.agent);
        _evidenceSelection = null;
        _evidenceTasks = false;
      }
      _navigationResetEpoch = resetEpoch;
      return ProductApp(
        scaffoldMessengerKey: _messengerKey,
        key: ValueKey(view.snapshot?.context.resetEpoch),
        controller: runtime.shell,
        destination: _destination,
        onDestinationChanged: (next) {
          if (_destination.value != next) _destination.value = next;
        },
        agentBuilder: (context) => AgentWorkspacePage(
          controller: runtime.agent,
          diagnostics: runtime.diagnostics,
          speechInput: runtime.speechInput,
          morningView: runtime.morning.view,
          morningChanges: runtime.morning.changes,
          morningNowUtc: () => runtime.clock.nowUtc,
          onMorningRetry: () => runtime.morning.check(manual: true),
          openMorningSource: (uri) => _openRestrictedExternalLink(context, uri),
          pickImages: pickAgentImages,
          onModelValidation: () async {
            try {
              final runner = await runtime.agent.openBehaviorValidation();
              if (!context.mounted) return;
              await showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) =>
                    Dialog(child: AgentBehaviorValidationPanel(runner: runner)),
              );
            } on Object {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('暂时无法打开核验面板，请稍后重试。')),
                );
              }
            }
          },
          onOpenLocalEvidence: (evidence) async {
            final navigationEpoch = _navigationResetEpoch;
            try {
              if (evidence.eventReference != null) {
                final detail = await runtime.jwStore.localCalendar.detail(
                  evidence.eventReference!,
                );
                await runtime.calendar.load(
                  day: beijingDay(detail.occurrence.startsAtUtc),
                  filter: CalendarFilter.all,
                  includeInactive: true,
                );
                if (mounted && _navigationResetEpoch == navigationEpoch) {
                  _evidenceSelection = detail.occurrence.reference;
                  _evidenceTasks = false;
                }
              } else if (evidence.taskReference != null) {
                final detail = await runtime.jwStore.localCalendar.taskDetail(
                  evidence.taskReference!,
                );
                await runtime.calendar.loadTasks();
                await runtime.calendar.selectTask(detail.task.reference);
                if (mounted && _navigationResetEpoch == navigationEpoch) {
                  _evidenceSelection = null;
                  _evidenceTasks = true;
                }
              }
              if (mounted && _navigationResetEpoch == navigationEpoch) {
                _destination.value = ShellDestination.agenda;
              }
            } catch (_) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('这条历史引用已变化，请重新查询当前日程或任务。')),
                );
              }
            }
          },
          onSettings: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                appBar: AppBar(title: const Text('Agent 设置')),
                body: Padding(
                  padding: const EdgeInsets.all(24),
                  child: AgentSettingsPanel(controller: runtime.agent),
                ),
              ),
            ),
          ),
        ),
        agendaBuilder: (context) => CalendarWorkspacePage(
          key: ValueKey(view.snapshot?.context.agendaEpoch),
          controller: runtime.calendar,
          tasks: runtime.calendar,
          reminders: runtime.jwStore.features,
          initialTasks: _evidenceTasks,
          initialSelection: _evidenceSelection,
          onInitialNavigationConsumed: () {
            _evidenceSelection = null;
            _evidenceTasks = false;
          },
          onDiscuss: (selection) async {
            await runtime.agent.prepareDiscussion(selection);
            if (mounted) _destination.value = ShellDestination.agent;
          },
        ),
        settingsBuilder: (context) => ApplicationSettingsPage(
          dailySync: runtime.youngDaily,
          settings: runtime.settings,
          controller: runtime.shell,
          agentBuilder: (context) =>
              AgentSettingsPanel(controller: runtime.agent),
          logsBuilder: (context) =>
              DiagnosticsPanel(diagnostics: runtime.diagnostics),
          remindersBuilder: (context) => M6SettingsPanel(
            data: runtime.jwStore.features,
            briefs: runtime.jwStore.briefs,
            reminderChanges: runtime.reminders.changes,
            initialReminderView: runtime.reminders.view,
            retryReminders: runtime.reminders.refresh,
            testNotification: runtime.reminders.testNotification,
            regenerateMorning: () => runtime.morning.check(manual: true),
          ),
          diagnosticsBuilder:
              developmentDiagnosticsEnabled || m3ValidationEnabled
              ? _buildDiagnostics
              : null,
        ),
      );
    },
  );

  DemoRuntime get _runtime => widget.bootstrap.runtime!;

  bool _isSafeHttpsSource(Uri uri) =>
      uri.scheme.toLowerCase() == 'https' &&
      uri.hasAuthority &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(uri.toString());

  Future<void> _openRestrictedExternalLink(
    BuildContext sourceContext,
    Uri uri,
  ) async {
    if (!sourceContext.mounted) return;
    if (!_isSafeHttpsSource(uri)) {
      ScaffoldMessenger.of(
        sourceContext,
      ).showSnackBar(const SnackBar(content: Text('该链接不是可复制的 HTTPS 出处。')));
      return;
    }
    await showDialog<void>(
      context: sourceContext,
      builder: (dialogContext) => AlertDialog(
        title: const Text('公开出处链接'),
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
                  ScaffoldMessenger.of(sourceContext).showSnackBar(
                    const SnackBar(content: Text('已复制 HTTPS 出处链接。')),
                  );
                }
              } on Object {
                if (dialogContext.mounted) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(content: Text('复制 HTTPS 出处链接失败。')),
                  );
                }
              }
            },
            child: const Text('复制链接'),
          ),
        ],
      ),
    );
  }

  Widget _buildDiagnostics(BuildContext context) => SizedBox(
    height: 600,
    child: ListView(
      children: [
        if (m3ValidationEnabled) ...[
          SizedBox(
            height: 720,
            child: PublicValidationPanel(
              queries: _runtime.publicQueries,
              knowledge: _runtime.knowledge,
            ),
          ),
          const SizedBox(height: 12),
        ],
        SizedBox(height: 600, child: JwSyncPanel(controller: _runtime.jwSync)),
        const SizedBox(height: 12),
        SizedBox(
          height: 600,
          child: YoungSyncPanel(controller: _runtime.youngSync),
        ),
        const SizedBox(height: 12),
        ExpansionTile(
          title: const Text('二课观测与契约诊断'),
          children: [
            SizedBox(
              height: 560,
              child: YoungObservationPanel(
                controller: _runtime.youngObservation,
              ),
            ),
            SizedBox(
              height: 560,
              child: YoungReadOnlyPanel(observation: _runtime.youngObservation),
            ),
            SizedBox(
              height: 560,
              child: YoungBusinessProbePanel(
                observation: _runtime.youngObservation,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ExpansionTile(
          title: const Text('教务观测与契约诊断'),
          children: [
            SizedBox(
              height: 560,
              child: ObservationPanel(controller: _runtime.observation),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 560,
              child: JwProbePanel(controller: _runtime.observation),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 560,
              child: JwDataProbePanel(
                probeController: _runtime.observation,
                controller: _runtime.observation,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(height: 640, child: M0App(controller: _runtime.controller)),
      ],
    ),
  );
}
