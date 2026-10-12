import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'app/demo_runtime.dart';
import 'app/product_app.dart';
import 'app/source_settings_page.dart';
import 'app/calendar_workspace_page.dart';
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

// This temporary panel is absent from normal product navigation.
const m3ValidationEnabled = bool.fromEnvironment('USTC_M3_VALIDATION');
const developmentDiagnosticsEnabled = bool.fromEnvironment('USTC_DIAGNOSTICS');

Future<void> launchM0() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final runtime = await DemoRuntime.open();
    runApp(_OwnedApp(runtime: runtime));
  } catch (error) {
    runApp(
      M0StartupFailureApp(
        code: error is AppFailure ? error.code : FailureCode.storageFailed,
      ),
    );
  }
}

final class _OwnedApp extends StatefulWidget {
  const _OwnedApp({required this.runtime});
  final DemoRuntime runtime;
  @override
  State<_OwnedApp> createState() => _OwnedAppState();
}

final class _OwnedAppState extends State<_OwnedApp> {
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        try {
          await widget.runtime.close();
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ProductApp(
    controller: widget.runtime.shell,
    agendaBuilder: (context) => CalendarWorkspacePage(
      controller: widget.runtime.calendar,
      tasks: widget.runtime.calendar,
    ),
    settingsBuilder: (context) => SourceSettingsPage(
      controller: widget.runtime.shell,
      diagnosticsBuilder: developmentDiagnosticsEnabled || m3ValidationEnabled
          ? _buildDiagnostics
          : null,
    ),
  );

  Widget _buildDiagnostics(BuildContext context) => SizedBox(
    height: 600,
    child: ListView(
      children: [
        if (m3ValidationEnabled) ...[
          SizedBox(
            height: 720,
            child: PublicValidationPanel(
              queries: widget.runtime.publicQueries,
              knowledge: widget.runtime.knowledge,
            ),
          ),
          const SizedBox(height: 12),
        ],
        SizedBox(
          height: 600,
          child: JwSyncPanel(controller: widget.runtime.jwSync),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 600,
          child: YoungSyncPanel(controller: widget.runtime.youngSync),
        ),
        const SizedBox(height: 12),
        ExpansionTile(
          title: const Text('二课观测与契约诊断'),
          children: [
            SizedBox(
              height: 560,
              child: YoungObservationPanel(
                controller: widget.runtime.youngObservation,
              ),
            ),
            SizedBox(
              height: 560,
              child: YoungReadOnlyPanel(
                observation: widget.runtime.youngObservation,
              ),
            ),
            SizedBox(
              height: 560,
              child: YoungBusinessProbePanel(
                observation: widget.runtime.youngObservation,
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
              child: ObservationPanel(controller: widget.runtime.observation),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 560,
              child: JwProbePanel(controller: widget.runtime.observation),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 560,
              child: JwDataProbePanel(
                probeController: widget.runtime.observation,
                controller: widget.runtime.observation,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 640,
          child: M0App(controller: widget.runtime.controller),
        ),
      ],
    ),
  );
}
