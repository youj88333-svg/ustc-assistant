// I3 workspace acceptance on the existing synthetic iOS Simulator install.
// This reuses the app's one RuntimeBootstrap owner and never opens a school,
// model or system-permission flow.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_page.dart';
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/app/jw_sync_panel.dart';
import 'package:ustc_assistant_m0/app/young_daily_sync_panel.dart';
import 'package:ustc_assistant_m0/app/young_sync_panel.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/core/young_daily_sync_contract.dart';
import 'package:ustc_assistant_m0/ios_i3_entry.dart';
import 'package:ustc_assistant_m0/platform/ios_runtime_platform_factory.dart';

const _platformChannel = MethodChannel('ustc_assistant/platform_v1');
const _operationTimeout = Duration(seconds: 45);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'I3 workspace stays local and preserves one Simulator runtime owner',
    (tester) async {
      expect(Platform.isIOS, isTrue);
      expect(kDebugMode, isTrue);
      final storage = await _platformChannel
          .invokeMapMethod<String, Object?>('storageProtectionStatus')
          .timeout(const Duration(seconds: 20));
      expect(storage?['isSimulator'], isTrue);

      // The fixture job leaves only synthetic personal events, an enabled
      // system-reminder setting, and provisional Simulator authorization.
      // Reading that state here does not alter the store or invoke Settings.
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      final previousHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = _RejectHttpOverrides();

      RuntimeBootstrap? capturedBootstrap;
      var bootstrapOpenCount = 0;
      final captureKey = GlobalKey();
      try {
        final opened = (await tester.runAsync(
          () => HttpOverrides.runWithHttpOverrides(
            () => RuntimeBootstrap.open(
              platformFactory: const IOSRuntimePlatformFactory(),
            ),
            _RejectHttpOverrides(),
          ).timeout(_operationTimeout),
        ))!;
        capturedBootstrap = opened;
        debugPrint('I3 workspace: owned runtime opened');
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: IOSI3App(
              openBootstrap: (_) async {
                bootstrapOpenCount++;
                return opened;
              },
            ),
          ),
        );
        await _pumpUntil(
          tester,
          () => opened.runtime != null,
          timeout: const Duration(seconds: 90),
        );
        await _pumpFrames(tester);
        final bootstrap = opened;
        final runtime = bootstrap.runtime!;
        expect(bootstrapOpenCount, 1);
        expect(
          bootstrap.settings.settingsView.maintenance.blocksProduct,
          isFalse,
        );

        final logicalWidth =
            tester.view.physicalSize.width / tester.view.devicePixelRatio;
        expect(logicalWidth, inInclusiveRange(360, 430));
        expect(
          tester
              .widget<NavigationBar>(
                find.byKey(const ValueKey('ios-i3-bottom-navigation')),
              )
              .selectedIndex,
          0,
        );
        expect(find.text('日程'), findsWidgets);
        expect(
          find.byKey(const ValueKey('calendar-personal-create')),
          findsOneWidget,
        );
        expect(find.byType(AgentWorkspacePage), findsNothing);
        expect(find.byIcon(Icons.mic_none_rounded), findsNothing);
        expect(tester.takeException(), isNull);
        await _saveSyntheticScreen(
          tester,
          captureKey,
          runtime,
          'i3-workspace.png',
        );
        debugPrint('I3 workspace: schedule and task entry rendered');

        final reminderSettings = await tester.runAsync(
          runtime.jwStore.features.inspectReminders,
        );
        expect(reminderSettings, isNotNull);
        expect(reminderSettings!.preferences.enabled, isTrue);
        expect(reminderSettings.preferences.morningEnabled, isFalse);
        expect(runtime.youngDaily.view.automaticAvailable, isFalse);

        final initialJwPhase = runtime.jwSync.syncView.phase;
        final initialYoungPhase = runtime.youngSync.syncView.phase;
        expect(runtime.jwSync.syncView.busy, isFalse);
        expect(runtime.youngSync.syncView.busy, isFalse);

        await tester.tap(find.text('来源').last);
        await _pumpFrames(tester, count: 5);
        expect(find.byType(JwSyncPanel), findsOneWidget);
        expect(find.byType(YoungSyncPanel), findsNothing);

        await tester.tap(find.text('二课').first);
        await _pumpFrames(tester, count: 5);
        expect(find.byType(YoungSyncPanel), findsOneWidget);
        expect(find.byType(YoungDailySyncPanel), findsOneWidget);
        expect(runtime.jwSync.syncView.busy, isFalse);
        expect(runtime.youngSync.syncView.busy, isFalse);

        await tester.tap(find.text('教务').first);
        await _pumpFrames(tester, count: 5);
        expect(find.byType(JwSyncPanel), findsOneWidget);
        expect(runtime.jwSync.syncView.phase, initialJwPhase);
        expect(runtime.youngSync.syncView.phase, initialYoungPhase);
        expect(find.byType(AgentWorkspacePage), findsNothing);
        expect(find.byIcon(Icons.mic_none_rounded), findsNothing);
        expect(tester.takeException(), isNull);

        debugPrint('I3 workspace: manual source panels verified');
        await _waitForReminderReadback(tester, runtime);
        await tester.tap(find.text('提醒').last);
        await _pumpUntil(
          tester,
          () => find
              .byKey(const ValueKey('m6-system-reminders-enabled'))
              .evaluate()
              .isNotEmpty,
        );
        await _pumpFrames(tester);

        final remindersSwitch = tester.widget<SwitchListTile>(
          find.byKey(const ValueKey('m6-system-reminders-enabled')),
        );
        expect(remindersSwitch.value, isTrue);
        expect(
          find.byKey(const ValueKey('m6-test-notification')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('m6-system-notifications')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('m6-system-exact')), findsNothing);
        expect(runtime.reminders.view.capability?.available, isTrue);
        expect(runtime.reminders.view.capability?.enabledBySystem, isTrue);
        expect(
          runtime.reminders.view.capability?.authorizationStatus,
          NotificationAuthorizationStatus.provisional,
        );
        expect(runtime.reminders.view.capability?.maximumPending, 60);
        expect(
          runtime.reminders.view.capability?.queueEvidence,
          NotificationQueueEvidence.operatingSystem,
        );
        expect(runtime.reminders.view.accepted, 60);
        expect(runtime.reminders.view.desired, greaterThanOrEqualTo(60));
        expect(runtime.reminders.view.complete, isFalse);
        await tester.ensureVisible(
          find.byKey(const ValueKey('m6-system-notifications')),
        );
        await _pumpFrames(tester);
        await _saveSyntheticScreen(
          tester,
          captureKey,
          runtime,
          'i3-reminders.png',
        );
        expect(find.byType(AgentWorkspacePage), findsNothing);
        expect(find.byIcon(Icons.mic_none_rounded), findsNothing);
        expect(tester.takeException(), isNull);
        debugPrint('I3 workspace: system queue rendered at larger text size');

        // Exercise a valid iOS lifecycle sequence. It pauses foreground-only
        // automatic work and returns to the same owner without reopening it.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await _pumpFrames(tester, count: 2);
        _expectForegroundAutomaticWorkStopped(runtime);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        try {
          // A live binding's pump waits for an engine frame. The scheduler
          // disables those frames while hidden/paused; inspect state directly
          // and resume before requesting another frame.
          expect(tester.binding.framesEnabled, isFalse);
          _expectForegroundAutomaticWorkStopped(runtime);
        } finally {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
        await _pumpFrames(tester);
        expect(bootstrapOpenCount, 1);
        expect(identical(bootstrap.runtime, runtime), isTrue);
        expect(runtime.youngDaily.view.automaticAvailable, isFalse);
        expect(runtime.jwSync.syncView.busy, isFalse);
        expect(runtime.youngSync.syncView.busy, isFalse);
        expect(tester.takeException(), isNull);
        debugPrint('I3 workspace: resumed with the same owner');

        binding.reportData = <String, Object>{
          'i3WorkspaceNavigation': true,
          'i3ReminderReadback': true,
          'i3LifecycleSingleOwner': true,
          'phoneLogicalWidth': logicalWidth,
          'bootstrapOpenCount': bootstrapOpenCount,
          'reminderQueueAccepted': runtime.reminders.view.accepted,
          'reminderQueueDesired': runtime.reminders.view.desired,
        };
      } finally {
        try {
          await tester.pumpWidget(const SizedBox.shrink());
          final bootstrap = capturedBootstrap;
          if (bootstrap != null) {
            await tester.runAsync(
              () => bootstrap.close().timeout(_operationTimeout),
            );
          }
        } finally {
          tester.platformDispatcher.clearTextScaleFactorTestValue();
          HttpOverrides.global = previousHttpOverrides;
        }
      }
    },
    skip: !Platform.isIOS || !kDebugMode,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Future<void> _saveSyntheticScreen(
  WidgetTester tester,
  GlobalKey key,
  DemoRuntime runtime,
  String filename,
) async {
  expect(const {'i3-workspace.png', 'i3-reminders.png'}, contains(filename));
  await tester.pump();
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      return await image.toByteData(format: ui.ImageByteFormat.png);
    } finally {
      image.dispose();
    }
  });
  expect(bytes, isNotNull);
  await tester.runAsync(
    () => File(runtime.directory.checkedChildPath(filename, directory: false))
        .writeAsBytes(
          bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          flush: true,
        ),
  );
}

Future<void> _waitForReminderReadback(
  WidgetTester tester,
  DemoRuntime runtime,
) async {
  await _pumpUntil(
    tester,
    () =>
        runtime.reminders.view.capability?.enabledBySystem == true &&
        runtime.reminders.view.accepted >= 60 &&
        runtime.reminders.view.desired >= 60,
    timeout: const Duration(seconds: 90),
  );
}

void _expectForegroundAutomaticWorkStopped(DemoRuntime runtime) {
  expect(runtime.morning.view.busy, isFalse);
  expect(runtime.youngDaily.view.automaticAvailable, isFalse);
  expect(runtime.youngDaily.view.phase, isNot(YoungDailySyncPhase.syncing));
  expect(runtime.jwSync.syncView.busy, isFalse);
  expect(runtime.youngSync.syncView.busy, isFalse);
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!condition() && stopwatch.elapsed < timeout) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
  }
  expect(
    condition(),
    isTrue,
    reason: 'timed out waiting for I3 workspace state',
  );
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 6}) async {
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

final class _RejectHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw StateError('i3_simulator_http_disabled');
}
