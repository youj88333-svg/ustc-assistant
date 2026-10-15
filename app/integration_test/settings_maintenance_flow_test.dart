import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/app/young_sync_panel.dart';
import 'package:ustc_assistant_m0/m0_entry.dart';
import 'package:ustc_assistant_m0/app/calendar_workspace_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_work_contract.dart';
import 'package:ustc_assistant_m0/core/settings_contract.dart';
import 'package:ustc_assistant_m0/core/young_work_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/platform/observation_assets.dart';

import 'support/diagnostic_cleanup.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets(
    'settings preserve display choices, agenda clearing retains knowledge, and reset returns to defaults',
    (tester) async {
      final workspace = await _createWorkspace();
      final bootstraps = <RuntimeBootstrap>[];
      try {
        final first = await _openBootstrap(tester, workspace);
        bootstraps.add(first);
        expect(first.runtime, isNotNull);
        expect(first.directory.isHeld, isTrue);
        expect(first.jwDirectory.isHeld, isTrue);

        await tester.pumpWidget(_application(first));
        await tester.pumpAndSettle();
        await _openSettings(tester);
        await _tapKey(tester, 'source-settings-young');
        final dailyPanel = find.byKey(const ValueKey('young-daily-sync-panel'));
        expect(
          tester.getRect(dailyPanel).bottom,
          lessThanOrEqualTo(tester.getRect(find.byType(YoungSyncPanel)).top),
          reason: 'The full daily panel must precede the manual form.',
        );
        await tester.ensureVisible(dailyPanel);
        await tester.pumpAndSettle();
        final toggle = find.byKey(const ValueKey('young-daily-sync-toggle'));
        expect(toggle.hitTestable(), findsOneWidget);
        expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
        await _captureSyntheticUi(tester, 'daily-sync-controls');
        // This test never enables school synchronization. Inspect only the
        // local controls in this TEMP runtime and scroll to the manual form.
        final password = find.byKey(const ValueKey('young-sync-password'));
        await tester.ensureVisible(password);
        await tester.pumpAndSettle();
        expect(password.hitTestable(), findsOneWidget);
        await _captureSyntheticUi(tester, 'source-manual-form');
        await _tapKey(tester, 'settings-section-display');
        await _tapKey(tester, 'settings-calendar-view-day');
        await _waitSettled(tester, first);
        await _tapKey(tester, 'settings-include-inactive');
        await _waitSettled(tester, first);

        var saved = await _inspectSettings(tester, first);
        expect(saved.preferences.calendarView, DefaultCalendarView.day);
        expect(saved.preferences.includeInactive, isTrue);
        expect(first.runtime!.calendar.view.mode, CalendarViewMode.day);
        expect(first.runtime!.calendar.view.includeInactive, isTrue);
        await _captureSyntheticUi(tester, 'display');

        await _openDataPrivacy(tester);
        await _tapKey(tester, 'settings-load-knowledge');
        await _waitSettled(tester, first);
        await tester.pumpAndSettle();
        var knowledge = await _runNative(
          tester,
          first.knowledge.inspectKnowledge,
        );
        expect(knowledge.materialCount, 7);
        expect(knowledge.loading, isFalse);
        expect((await _inspectSettings(tester, first)).counts.materials, 7);

        await _unmountAndClose(tester, first);
        final reopened = await _openBootstrap(tester, workspace);
        bootstraps.add(reopened);
        expect(reopened.runtime, isNotNull);
        expect(reopened.directory.isHeld, isTrue);
        expect(reopened.jwDirectory.isHeld, isTrue);
        saved = await _inspectSettings(tester, reopened);
        expect(saved.preferences.calendarView, DefaultCalendarView.day);
        expect(saved.preferences.includeInactive, isTrue);
        expect(reopened.runtime!.calendar.view.mode, CalendarViewMode.day);
        expect(reopened.runtime!.calendar.view.includeInactive, isTrue);
        knowledge = await _runNative(
          tester,
          reopened.knowledge.inspectKnowledge,
        );
        expect(knowledge.materialCount, 7);

        await tester.pumpWidget(_application(reopened));
        await tester.pumpAndSettle();
        await _seedSyntheticAgendaTask(tester, reopened.runtime!);
        var agenda = await _querySyntheticDay(tester, reopened.runtime!);
        expect(agenda.items.map((item) => item.title), contains('M44 合成个人安排'));
        var tasks = await _queryTasks(tester, reopened.runtime!);
        expect(
          tasks.items.map((task) => task.draft.title),
          contains('M44 合成任务'),
        );
        final task = tasks.items.single;
        final detail = await _runNative(
          tester,
          () => reopened.runtime!.jwStore.localCalendar.taskDetail(
            task.reference,
          ),
        );
        expect(detail.blocks, hasLength(1));

        final beforeAgendaClear = saved.context;
        await _openSettings(tester);
        await _openDataPrivacy(tester);
        await _captureSyntheticUi(tester, 'data-privacy');
        await tester.ensureVisible(
          find.byKey(const ValueKey('settings-clear-agenda')),
        );
        await _captureSyntheticUi(tester, 'maintenance');
        await _confirmMaintenance(
          tester,
          buttonKey: 'settings-clear-agenda',
          finalAction: '确认清空日程与任务',
        );
        await _waitSettled(tester, reopened);
        saved = await _inspectSettings(tester, reopened);
        expect(saved.context.resetEpoch, beforeAgendaClear.resetEpoch);
        expect(saved.context.agendaEpoch, beforeAgendaClear.agendaEpoch + 1);
        expect(saved.preferences.calendarView, DefaultCalendarView.day);
        expect(saved.preferences.includeInactive, isTrue);
        expect(saved.counts.materials, 7);
        agenda = await _querySyntheticDay(tester, reopened.runtime!);
        expect(agenda.items, isEmpty);
        tasks = await _queryTasks(tester, reopened.runtime!);
        expect(tasks.items, isEmpty);

        await _openSettings(tester);
        await _openDataPrivacy(tester);
        await _confirmMaintenance(
          tester,
          buttonKey: 'settings-reset',
          finalAction: '确认完全重置',
        );
        await _waitSettled(tester, reopened);
        saved = await _inspectSettings(tester, reopened);
        expect(saved.context.resetEpoch, beforeAgendaClear.resetEpoch + 1);
        expect(saved.preferences.calendarView, DefaultCalendarView.week);
        expect(saved.preferences.includeInactive, isFalse);
        expect(saved.counts.materials, 0);
        expect(saved.counts.personal, 0);
        expect(saved.counts.tasks, 0);
        expect(saved.counts.blocks, 0);
        expect(reopened.runtime!.calendar.view.mode, CalendarViewMode.week);
        expect(reopened.runtime!.calendar.view.includeInactive, isFalse);

        final currentWindow = reopened.runtime!.calendar.view.window!;
        await _runNative(
          tester,
          () => reopened.runtime!.calendar.execute(
            CreatePersonalEvent(
              PersonalEventDraft(
                title: 'M44 重置后新安排',
                start: DateTime.utc(2026, 10, 12, 5),
                end: DateTime.utc(2026, 10, 12, 5, 30),
              ),
            ),
            expectedContext: currentWindow.context,
          ),
        );
        agenda = await _querySyntheticDay(tester, reopened.runtime!);
        expect(agenda.items.map((item) => item.title), contains('M44 重置后新安排'));
      } finally {
        await _disposeAndClean(tester, workspace, bootstraps);
      }
    },
  );

  testWidgets(
    'confirmed full reset drains only registered provisional and observation profiles',
    (tester) async {
      final workspace = await _createWorkspace();
      final bootstraps = <RuntimeBootstrap>[];
      try {
        final bootstrap = await _openBootstrap(tester, workspace);
        bootstraps.add(bootstrap);
        expect(bootstrap.runtime, isNotNull);

        final jwAuthority = await _runNative(
          tester,
          bootstrap.jwStore.readAuthority,
        );
        final jwRef = await _runNative(
          tester,
          () => bootstrap.jwRegistry.createProvisional(
            ownerId: jwAuthority.ownerId,
            purpose: JwPartitionPurpose.initial,
            attempt: 'jw-0-1',
            resetEpoch: jwAuthority.resetEpoch,
          ),
        );
        final youngAuthority = await _runNative(
          tester,
          bootstrap.jwStore.readYoungAuthority,
        );
        final youngRef = await _runNative(
          tester,
          () => bootstrap.youngRegistry.createProvisional(
            ownerId: youngAuthority.ownerId,
            purpose: YoungPartitionPurpose.initial,
            attempt: 'young-0-1',
            resetEpoch: youngAuthority.resetEpoch,
          ),
        );
        final jwProfile = bootstrap.jwRegistry.profilePath(jwRef);
        final youngProfile = bootstrap.youngRegistry.profilePath(youngRef);
        final jwObservation = await _runNative(
          tester,
          () => ObservationAssets(bootstrap.directory).register(),
        );
        final youngObservation = await _runNative(
          tester,
          () => ObservationAssets.young(bootstrap.directory).register(),
        );
        for (final path in [
          jwProfile,
          youngProfile,
          jwObservation,
          youngObservation,
        ]) {
          expect(
            await _runNative(
              tester,
              () => FileSystemEntity.type(path, followLinks: false),
            ),
            FileSystemEntityType.directory,
          );
        }

        await tester.pumpWidget(_application(bootstrap));
        await tester.pumpAndSettle();
        await _openSettings(tester);
        await _openDataPrivacy(tester);
        await _confirmMaintenance(
          tester,
          buttonKey: 'settings-reset',
          finalAction: '确认完全重置',
        );
        await _waitSettled(tester, bootstrap);

        final resetSettings = await _inspectSettings(tester, bootstrap);
        expect(resetSettings.context.resetEpoch, jwAuthority.resetEpoch + 1);
        expect(resetSettings.accountBound, isFalse);
        expect(resetSettings.credentialSaved, isFalse);
        expect(
          await _runNative(tester, bootstrap.jwStore.readCommittedPermits),
          isEmpty,
        );
        expect(
          await _runNative(tester, bootstrap.jwStore.readYoungPermits),
          isEmpty,
        );
        for (final path in [
          jwProfile,
          youngProfile,
          jwObservation,
          youngObservation,
        ]) {
          expect(
            await _runNative(
              tester,
              () => FileSystemEntity.type(path, followLinks: false),
            ),
            FileSystemEntityType.notFound,
          );
        }
        await _assertEmptyOrMissingDirectory(
          tester,
          p.windows.join(bootstrap.jwDirectory.path, 'jw_partitions_v1'),
        );
        await _assertEmptyOrMissingDirectory(
          tester,
          p.windows.join(bootstrap.jwDirectory.path, 'young_partitions_v1'),
        );
        await _assertEmptyOrMissingDirectory(
          tester,
          p.windows.join(bootstrap.directory.path, 'observation_v1'),
        );
        await _assertEmptyOrMissingDirectory(
          tester,
          p.windows.join(bootstrap.directory.path, 'young_observation_v1'),
        );
      } finally {
        await _disposeAndClean(tester, workspace, bootstraps);
      }
    },
  );

  testWidgets(
    'startup resumes a persisted agenda intent after one activation checkpoint failure',
    (tester) async {
      final workspace = await _createWorkspace();
      final bootstraps = <RuntimeBootstrap>[];
      try {
        final first = await _openBootstrap(tester, workspace);
        bootstraps.add(first);
        expect(first.runtime, isNotNull);
        await _seedSyntheticPersonalEvent(tester, first.runtime!);
        final original = await _inspectSettings(tester, first);
        final request = await _runNative(
          tester,
          () => first.jwStore.applicationSettings.prepareMaintenance(
            original.context,
            MaintenanceKind.agenda,
            confirmed: true,
          ),
        );
        final intent = await _runNative(
          tester,
          () => first.jwStore.applicationSettings.beginMaintenance(request),
        );
        expect(intent.kind, MaintenanceKind.agenda);
        expect(
          intent.targetContext.agendaEpoch,
          original.context.agendaEpoch + 1,
        );

        await _unmountAndClose(tester, first);
        var checkpointCalls = 0;
        Future<void> failOnceAtActivationCheckpoint() async {
          checkpointCalls += 1;
          if (checkpointCalls == 1) {
            throw StateError('synthetic activation checkpoint failure');
          }
        }

        final recovered = await _openBootstrap(
          tester,
          workspace,
          onActivationCheckpoint: failOnceAtActivationCheckpoint,
        );
        bootstraps.add(recovered);
        expect(recovered.runtime, isNull);
        expect(recovered.settings.settingsView.maintenance.activating, isTrue);
        expect(checkpointCalls, 1);
        expect(recovered.directory.isHeld, isTrue);
        expect(recovered.jwDirectory.isHeld, isTrue);
        expect(
          recovered.maintenance.view.phase,
          MaintenancePhase.idle,
          reason:
              'The persisted intent is already settled before assembly retry.',
        );
        final restoredBeforeRetry = await _inspectSettings(tester, recovered);
        expect(
          restoredBeforeRetry.context.resetEpoch,
          original.context.resetEpoch,
        );
        expect(
          restoredBeforeRetry.context.agendaEpoch,
          original.context.agendaEpoch + 1,
        );
        expect(
          (await _querySyntheticDayFromBootstrap(tester, recovered)).items,
          isEmpty,
        );

        await tester.pumpWidget(_application(recovered));
        await tester.pumpAndSettle();
        expect(find.text('正在恢复本机数据'), findsOneWidget);
        expect(
          find.text('如果需要关闭应用，请使用系统窗口关闭按钮。下次启动会继续检查并恢复本地数据。'),
          findsOneWidget,
        );
        expect(find.textContaining('synthetic activation'), findsNothing);
        expect(find.textContaining(workspace.demoPath), findsNothing);
        expect(find.textContaining(workspace.formalPath), findsNothing);
        expect(
          find.byKey(const ValueKey('maintenance-recovery-retry')),
          findsOneWidget,
        );
        await _captureSyntheticUi(tester, 'recovery');

        await _tapKey(tester, 'maintenance-recovery-retry');
        await _waitSettled(tester, recovered);
        expect(recovered.runtime, isNotNull);
        expect(checkpointCalls, 2);
        expect(recovered.directory.isHeld, isTrue);
        expect(recovered.jwDirectory.isHeld, isTrue);
        final restoredAfterRetry = await _inspectSettings(tester, recovered);
        expect(restoredAfterRetry.context, restoredBeforeRetry.context);
        expect(
          (await _querySyntheticDayFromBootstrap(tester, recovered)).items,
          isEmpty,
        );
      } finally {
        await _disposeAndClean(tester, workspace, bootstraps);
      }
    },
  );
}

Future<RuntimeBootstrap> _openBootstrap(
  WidgetTester tester,
  _OwnedWorkspace workspace, {
  Future<void> Function()? onActivationCheckpoint,
}) => _runNative(
  tester,
  () => RuntimeBootstrap.open(
    directoryPath: workspace.demoPath,
    jwDirectoryPath: workspace.formalPath,
    clock: FixedClock(DateTime.utc(2026, 10, 12, 4)),
    onActivationCheckpoint: onActivationCheckpoint,
  ),
);

Future<SettingsSnapshot> _inspectSettings(
  WidgetTester tester,
  RuntimeBootstrap bootstrap,
) => _runNative(tester, bootstrap.jwStore.applicationSettings.inspectSettings);

Future<CalendarWindow> _querySyntheticDay(
  WidgetTester tester,
  DemoRuntime runtime,
) => _runNative(
  tester,
  () => runtime.jwStore.localCalendar.query(
    CalendarQuery(
      firstDay: DateTime.utc(2026, 10, 12),
      endDayExclusive: DateTime.utc(2026, 10, 13),
      includeHidden: true,
      includeSkipped: true,
    ),
  ),
);

Future<CalendarWindow> _querySyntheticDayFromBootstrap(
  WidgetTester tester,
  RuntimeBootstrap bootstrap,
) => _runNative(
  tester,
  () => bootstrap.jwStore.localCalendar.query(
    CalendarQuery(
      firstDay: DateTime.utc(2026, 10, 12),
      endDayExclusive: DateTime.utc(2026, 10, 13),
      includeHidden: true,
      includeSkipped: true,
    ),
  ),
);

Future<TaskWindow> _queryTasks(WidgetTester tester, DemoRuntime runtime) =>
    _runNative(
      tester,
      () => runtime.jwStore.localCalendar.queryTasks(
        const TaskQuery(filter: TaskFilter.all),
      ),
    );

Future<void> _seedSyntheticAgendaTask(
  WidgetTester tester,
  DemoRuntime runtime,
) async {
  final calendarContext = runtime.calendar.view.window!.context;
  await _runNative(
    tester,
    () => runtime.calendar.execute(
      CreatePersonalEvent(
        PersonalEventDraft(
          title: 'M44 合成个人安排',
          start: DateTime.utc(2026, 10, 12, 1),
          end: DateTime.utc(2026, 10, 12, 1, 30),
          note: '仅供本机集成场景',
        ),
      ),
      expectedContext: calendarContext,
    ),
  );
  final taskContext = runtime.calendar.taskView.window!.context;
  await _runNative(
    tester,
    () => runtime.calendar.executeTask(
      const CreateTask(
        TaskDraft(
          title: 'M44 合成任务',
          description: '仅供本机集成场景',
          estimatedMinutes: 30,
        ),
      ),
      expectedContext: taskContext,
    ),
  );
  final tasks = await _queryTasks(tester, runtime);
  final task = tasks.items.single;
  final refreshedTaskContext = runtime.calendar.taskView.window!.context;
  await _runNative(
    tester,
    () => runtime.calendar.executeTask(
      CreatePlanBlock(
        task.reference,
        PlanBlockDraft(
          startsAtUtc: DateTime.utc(2026, 10, 12, 3),
          endsAtUtc: DateTime.utc(2026, 10, 12, 3, 30),
          note: '仅供本机集成场景',
        ),
      ),
      expectedContext: refreshedTaskContext,
    ),
  );
}

Future<void> _seedSyntheticPersonalEvent(
  WidgetTester tester,
  DemoRuntime runtime,
) async {
  final context = runtime.calendar.view.window!.context;
  await _runNative(
    tester,
    () => runtime.calendar.execute(
      CreatePersonalEvent(
        PersonalEventDraft(
          title: 'M44 恢复演练安排',
          start: DateTime.utc(2026, 10, 12, 2),
          end: DateTime.utc(2026, 10, 12, 2, 30),
          note: '仅供本机集成场景',
        ),
      ),
      expectedContext: context,
    ),
  );
}

Future<void> _openSettings(WidgetTester tester) async {
  await _tapKey(tester, 'shell-nav-settings');
}

Future<void> _openDataPrivacy(WidgetTester tester) async {
  await _tapKey(tester, 'settings-section-dataPrivacy');
}

Future<void> _confirmMaintenance(
  WidgetTester tester, {
  required String buttonKey,
  required String finalAction,
}) async {
  await _tapKey(tester, buttonKey);
  await _tapText(tester, '继续确认');
  expect(find.text(finalAction), findsOneWidget);
  await _tapText(tester, finalAction);
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey<String>(key));
  expect(finder, findsOneWidget, reason: 'Missing UI key: $key');
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
  await tester.pumpAndSettle();
}

Widget _application(RuntimeBootstrap bootstrap) => RepaintBoundary(
  key: const ValueKey('m44-synthetic-capture'),
  child: OwnedApplication(bootstrap: bootstrap),
);

Future<void> _captureSyntheticUi(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('USTC_M4_QA')) {
    return;
  }
  const destination = String.fromEnvironment('USTC_M4_QA_DIR');
  if (destination.isEmpty || !p.windows.isAbsolute(destination)) {
    throw StateError(
      'A dedicated absolute synthetic QA directory is required.',
    );
  }
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('m44-synthetic-capture')),
  );
  final picture = await boundary.toImage(pixelRatio: 1);
  try {
    final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) {
      throw StateError('Synthetic UI capture is empty.');
    }
    await _runNative(tester, () async {
      final folder = Directory(destination);
      await folder.create(recursive: true);
      await File(
        p.windows.join(destination, '$name.png'),
      ).writeAsBytes(bytes.buffer.asUint8List());
    });
  } finally {
    picture.dispose();
  }
}

Future<void> _waitSettled(
  WidgetTester tester,
  RuntimeBootstrap bootstrap,
) async {
  final watch = Stopwatch()..start();
  while (bootstrap.settings.settingsView.actionPending ||
      bootstrap.settings.settingsView.loading ||
      bootstrap.settings.settingsView.maintenance.blocksProduct) {
    if (watch.elapsed > const Duration(seconds: 50)) {
      throw StateError(
        'Synthetic settings did not settle: ${bootstrap.settings.settingsView.maintenance.phase.name}',
      );
    }
    if (bootstrap.settings.settingsView.maintenance.phase ==
            MaintenancePhase.recovery &&
        !bootstrap.settings.settingsView.actionPending) {
      throw StateError(
        'Synthetic maintenance recovery: ${bootstrap.settings.settingsView.maintenance.failure?.name}',
      );
    }
    await _runNative(
      tester,
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Future<void> _tapText(WidgetTester tester, String label) async {
  final finder = find.text(label);
  expect(finder, findsOneWidget, reason: 'Missing UI label: $label');
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pump();
  await tester.pumpAndSettle();
}

Future<T> _runNative<T>(
  WidgetTester tester,
  Future<T> Function() action,
) async {
  late T result;
  Object? failure;
  StackTrace? failureStack;
  await tester.runAsync(() async {
    try {
      result = await action();
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    }
  });
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  return result;
}

Future<void> _unmountAndClose(
  WidgetTester tester,
  RuntimeBootstrap bootstrap,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await _closeBootstrap(tester, bootstrap);
}

Future<void> _closeBootstrap(
  WidgetTester tester,
  RuntimeBootstrap bootstrap,
) async {
  await _runNative(tester, bootstrap.close);
  expect(bootstrap.directory.isHeld, isFalse);
  expect(bootstrap.jwDirectory.isHeld, isFalse);
}

Future<void> _disposeAndClean(
  WidgetTester tester,
  _OwnedWorkspace workspace,
  List<RuntimeBootstrap> bootstraps,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  for (final bootstrap in bootstraps.reversed) {
    await _closeBootstrap(tester, bootstrap);
  }
  await _deleteOwnedWorkspace(workspace);
}

Future<_OwnedWorkspace> _createWorkspace() async {
  const prefix = 'ustc_m44_settings_';
  final root = await Directory.systemTemp.createTemp(prefix);
  final rootPath = _normal(root.path);
  final tempPath = _normal(await Directory.systemTemp.resolveSymbolicLinks());
  final rootName = p.windows.basename(rootPath);
  if (!p.windows.equals(p.windows.dirname(rootPath), tempPath) ||
      !rootName.startsWith(prefix) ||
      rootName.length == prefix.length ||
      !RegExp(
        r'^[A-Za-z0-9_-]+$',
      ).hasMatch(rootName.substring(prefix.length)) ||
      !p.windows.equals(rootPath, _normal(await root.resolveSymbolicLinks())) ||
      await FileSystemEntity.type(rootPath, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw StateError('Refusing a TEMP root without a plain nonce directory.');
  }
  final nonce = _nonce();
  final markerName = '.m44-owner-$nonce.marker';
  final marker = File(p.windows.join(rootPath, markerName));
  final handle = await marker.open(mode: FileMode.writeOnly);
  try {
    await handle.writeString('$nonce\n');
    await handle.flush();
  } finally {
    await handle.close();
  }
  return _OwnedWorkspace(
    root: root,
    prefix: prefix,
    nonce: nonce,
    markerName: markerName,
    demoPath: p.windows.join(rootPath, 'demo-$nonce'),
    formalPath: p.windows.join(rootPath, 'formal-$nonce'),
  );
}

Future<void> _deleteOwnedWorkspace(_OwnedWorkspace workspace) async {
  final tempPath = _normal(await Directory.systemTemp.resolveSymbolicLinks());
  final rootPath = _normal(workspace.root.path);
  final rootName = p.windows.basename(rootPath);
  if (!p.windows.equals(p.windows.dirname(rootPath), tempPath) ||
      !rootName.startsWith(workspace.prefix) ||
      rootName.length == workspace.prefix.length ||
      !RegExp(
        r'^[A-Za-z0-9_-]+$',
      ).hasMatch(rootName.substring(workspace.prefix.length)) ||
      !p.windows.equals(
        rootPath,
        _normal(await workspace.root.resolveSymbolicLinks()),
      ) ||
      await FileSystemEntity.type(rootPath, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw StateError('Refusing to remove a path outside the nonce TEMP root.');
  }

  final markerPath = p.windows.join(rootPath, workspace.markerName);
  if (await FileSystemEntity.type(markerPath, followLinks: false) !=
      FileSystemEntityType.file) {
    throw StateError(
      'Refusing to remove a TEMP root without its owner marker.',
    );
  }
  if (await File(markerPath).readAsString() != '${workspace.nonce}\n') {
    throw StateError(
      'Refusing to remove a TEMP root with a mismatched marker.',
    );
  }

  final expectedDemo = _normal(workspace.demoPath);
  final expectedFormal = _normal(workspace.formalPath);
  if (!p.windows.equals(p.windows.dirname(expectedDemo), rootPath) ||
      !p.windows.equals(p.windows.dirname(expectedFormal), rootPath) ||
      p.windows.basename(expectedDemo) != 'demo-${workspace.nonce}' ||
      p.windows.basename(expectedFormal) != 'formal-${workspace.nonce}') {
    throw StateError('Refusing an unrecognized TEMP child path.');
  }

  await _assertNoLinks(workspace.root, rootPath);
  final children = await workspace.root.list(followLinks: false).toList();
  final expectedNames = {
    workspace.markerName,
    p.windows.basename(expectedDemo),
    p.windows.basename(expectedFormal),
  };
  if (children.isEmpty ||
      children.map((entry) => p.windows.basename(entry.path)).toSet().length !=
          children.length ||
      children.any(
        (entry) => !expectedNames.contains(p.windows.basename(entry.path)),
      )) {
    throw StateError('Refusing to remove an unknown TEMP child.');
  }
  for (final child in children) {
    final path = _normal(child.path);
    if (p.windows.equals(path, markerPath)) {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw StateError('The owner marker changed during cleanup.');
      }
      continue;
    }
    final formal = p.windows.equals(path, expectedFormal);
    if (!formal && !p.windows.equals(path, expectedDemo)) {
      throw StateError('Refusing to remove an unrecognized TEMP child.');
    }
    if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.directory ||
        !p.windows.equals(
          path,
          _normal(await Directory(path).resolveSymbolicLinks()),
        )) {
      throw StateError('A known TEMP child is not a plain owned directory.');
    }
    await _assertKnownDatabaseFiles(Directory(path), formal: formal);
  }
  await _assertNoLinks(workspace.root, rootPath);
  if (!p.windows.equals(
        rootPath,
        _normal(await workspace.root.resolveSymbolicLinks()),
      ) ||
      await FileSystemEntity.type(rootPath, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw StateError('TEMP root changed during ownership validation.');
  }
  await workspace.root.delete(recursive: true);
}

Future<void> _assertKnownDatabaseFiles(
  Directory directory, {
  required bool formal,
}) async {
  final directoryPath = _normal(directory.path);
  final name = p.windows.basename(directoryPath);
  final expectedBase = name.startsWith('demo-')
      ? 'm0_demo.sqlite'
      : 'jw.sqlite';
  final allowedFiles = {
    expectedBase,
    '$expectedBase-wal',
    '$expectedBase-shm',
    '$expectedBase-journal',
  };
  final emptyRoots = formal
      ? {'jw_partitions_v1', 'young_partitions_v1'}
      : {'observation_v1', 'young_observation_v1'};
  await for (final entry in directory.list(followLinks: false)) {
    final path = _normal(entry.path);
    if (!p.windows.isWithin(directoryPath, path)) {
      throw StateError('Refusing an entry outside the nonce-owned directory.');
    }
    final entryName = p.windows.basename(path);
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (allowedFiles.contains(entryName) && type == FileSystemEntityType.file) {
      continue;
    }
    if (formal &&
        entryName == 'diagnostics' &&
        type == FileSystemEntityType.directory) {
      await assertKnownFormalDiagnosticsDirectory(directory);
      continue;
    }
    if (emptyRoots.contains(entryName) &&
        type == FileSystemEntityType.directory) {
      final root = Directory(path);
      if (!p.windows.equals(path, _normal(await root.resolveSymbolicLinks())) ||
          (await root.list(followLinks: false).take(1).toList()).isNotEmpty) {
        throw StateError(
          'Refusing to remove a populated or linked source root.',
        );
      }
      continue;
    }
    throw StateError('Refusing to remove an unknown native database entry.');
  }
}

Future<void> _assertEmptyOrMissingDirectory(
  WidgetTester tester,
  String path,
) async {
  final type = await _runNative(
    tester,
    () => FileSystemEntity.type(path, followLinks: false),
  );
  if (type == FileSystemEntityType.notFound) return;
  expect(type, FileSystemEntityType.directory);
  final directory = Directory(path);
  expect(
    _normal(await _runNative(tester, directory.resolveSymbolicLinks)),
    _normal(path),
  );
  expect(
    await _runNative(tester, () => directory.list(followLinks: false).toList()),
    isEmpty,
  );
}

Future<void> _assertNoLinks(Directory root, String rootPath) async {
  final pending = <Directory>[root];
  while (pending.isNotEmpty) {
    final directory = pending.removeLast();
    await for (final entity in directory.list(followLinks: false)) {
      final path = _normal(entity.path);
      if (!p.windows.isWithin(rootPath, path)) {
        throw StateError('Refusing to remove an entry outside TEMP ownership.');
      }
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.link ||
          type == FileSystemEntityType.notFound) {
        throw StateError('Refusing to remove a link or changing TEMP entry.');
      }
      if (type == FileSystemEntityType.directory) {
        pending.add(Directory(path));
      } else if (type != FileSystemEntityType.file) {
        throw StateError('Refusing to remove an unknown TEMP entry type.');
      }
    }
  }
}

String _normal(String path) => p.windows.normalize(p.windows.absolute(path));

String _nonce() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

final class _OwnedWorkspace {
  const _OwnedWorkspace({
    required this.root,
    required this.prefix,
    required this.nonce,
    required this.markerName,
    required this.demoPath,
    required this.formalPath,
  });

  final Directory root;
  final String prefix;
  final String nonce;
  final String markerName;
  final String demoPath;
  final String formalPath;
}
