import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app/demo_runtime.dart';
import 'app/product_app.dart';
import 'app/app_shell_contract.dart';
import 'app/app_settings_page.dart';
import 'app/maintenance_recovery_page.dart';
import 'app/calendar_workspace_page.dart';
import 'app/agent_workspace_page.dart';
import 'app/agent_settings_panel.dart';
import 'platform/agent_image_picker.dart';
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

// This temporary panel is absent from normal product navigation.
const m3ValidationEnabled = bool.fromEnvironment('USTC_M3_VALIDATION');
const developmentDiagnosticsEnabled = bool.fromEnvironment('USTC_DIAGNOSTICS');

Future<void> launchM0() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final bootstrap = await RuntimeBootstrap.open();
    runApp(OwnedApplication(bootstrap: bootstrap));
  } catch (error) {
    runApp(
      M0StartupFailureApp(
        code: error is AppFailure ? error.code : FailureCode.storageFailed,
      ),
    );
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
  var _destination = ValueNotifier<ShellDestination>(ShellDestination.agent);
  int? _navigationResetEpoch;
  CalendarReference? _evidenceSelection;
  bool _evidenceTasks = false;
  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
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
    _lifecycle.dispose();
    _destination.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.bootstrap, widget.bootstrap.settings]),
    builder: (context, _) {
      final bootstrap = widget.bootstrap;
      final runtime = bootstrap.runtime;
      final view = bootstrap.settings.settingsView;
      if (runtime == null || view.maintenance.blocksProduct) {
        // The product subtree and its routes are withdrawn during maintenance;
        // old forms cannot remain attached to the next agenda/reset epoch.
        return MaterialApp(
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
        key: ValueKey(view.snapshot?.context.resetEpoch),
        controller: runtime.shell,
        destination: _destination,
        onDestinationChanged: (next) {
          if (_destination.value != next) _destination.value = next;
        },
        agentBuilder: (context) => AgentWorkspacePage(
          controller: runtime.agent,
          pickImages: pickAgentImages,
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
          settings: runtime.settings,
          controller: runtime.shell,
          agentBuilder: (context) =>
              AgentSettingsPanel(controller: runtime.agent),
          diagnosticsBuilder:
              developmentDiagnosticsEnabled || m3ValidationEnabled
              ? _buildDiagnostics
              : null,
        ),
      );
    },
  );

  DemoRuntime get _runtime => widget.bootstrap.runtime!;

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
