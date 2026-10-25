// Design: approved A4 contract; architecture 07-12, quality 13, review 14,
// workflow 15. Only an independent Android QA owner and synthetic local data.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/app/calendar_workspace_contract.dart';
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/core/settings_contract.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';
import 'package:ustc_assistant_m0/m0_entry.dart';
import 'package:ustc_assistant_m0/platform/android_directory.dart';
import 'package:ustc_assistant_m0/platform/android_file_access.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/runtime_platform_factory.dart';
import 'support/onboarding_fixture.dart';

const _platform = MethodChannel('ustc_assistant/platform_v1');
final _clock = FixedClock(DateTime.utc(2026, 10, 16, 1));

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'phone shell and local calendar/task/settings share the owned Android runtime',
    (tester) async {
      final previousErrorHandler = FlutterError.onError;
      FlutterError.onError = (details) {
        // Keep render-object diagnostics for cross-version layout failures.
        debugPrint(details.toString());
        previousErrorHandler?.call(details);
      };
      addTearDown(() => FlutterError.onError = previousErrorHandler);
      final fixture = await tester.runAsync(_fixture);
      RuntimeBootstrap? bootstrap;
      final network = _NoNetwork();
      final previousNetwork = HttpOverrides.current;
      HttpOverrides.global = network;
      debugPrint(
        'A4 native insets: top=${tester.view.padding.top}, '
        'bottom=${tester.view.padding.bottom}, '
        'viewBottom=${tester.view.viewPadding.bottom}',
      );
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      // Own every viewport metric. Otherwise an API34 physical navigation
      // inset from a 1080px/DPR2.625 display survives a synthetic DPR1 resize.
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      try {
        bootstrap = await tester.runAsync(
          () => RuntimeBootstrap.open(
            platformFactory: _FixturePlatform(fixture!.path),
            clock: _clock,
          ),
        );
        final runtime = bootstrap!.runtime!;
        await tester.runAsync(() => finishSyntheticSetup(bootstrap!));
        expect(runtime.calendar.view.mode, CalendarViewMode.day);
        await tester.runAsync(() async {
          final calendar = runtime.jwStore.localCalendar;
          final context = (await calendar.readPlanContext()).$1;
          await calendar.commit(
            await calendar.prepare(
              context,
              CreatePersonalEvent(
                PersonalEventDraft(
                  title: 'A4合成实验',
                  location: 'QA-201',
                  start: DateTime.utc(2026, 10, 16, 6),
                  end: DateTime.utc(2026, 10, 16, 7),
                ),
              ),
            ),
          );
          await calendar.commit(
            await calendar.prepare(
              context,
              CreateTask(
                TaskDraft(
                  title: 'A4合成截止任务',
                  deadlineAtUtc: DateTime.utc(2026, 10, 16, 15),
                ),
              ),
            ),
          );
          await runtime.calendar.load();
          await runtime.calendar.loadTasks();
        });
        await tester.pumpWidget(OwnedApplication(bootstrap: bootstrap));
        await _settle(tester);
        final composer = find.byKey(const ValueKey('agent-composer'));
        await tester.enterText(composer, 'A4未发送草稿');
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('shell-nav-agenda')));
        await _settle(tester);
        expect(find.text('A4合成实验'), findsWidgets);
        expect(find.text('A4合成截止任务'), findsWidgets);
        await tester.tap(
          find.byKey(const ValueKey('calendar-workspace-tab-tasks')),
        );
        await _settle(tester);
        expect(find.text('A4合成截止任务'), findsWidgets);
        tester.view.physicalSize = const Size(800, 360);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        tester.view.padding = const FakeViewPadding(top: 24);
        tester.view.viewInsets = const FakeViewPadding(bottom: 180);
        await _settle(tester);
        expect(tester.takeException(), isNull);
        tester.view.viewInsets = const FakeViewPadding();
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
        tester.platformDispatcher.textScaleFactorTestValue = 1;
        tester.view.physicalSize = const Size(360, 780);
        await _settle(tester);
        await tester.tap(find.byKey(const ValueKey('shell-nav-settings')));
        await _settle(tester);
        final logsAction = find.byKey(
          const ValueKey('diagnostics-export-button'),
        );
        expect(logsAction.hitTestable(), findsOneWidget);
        final logsRect = tester.getRect(logsAction);
        expect(logsRect.left, greaterThanOrEqualTo(0));
        expect(logsRect.right, lessThanOrEqualTo(360));
        expect(tester.takeException(), isNull);
        await tester.binding.handlePopRoute();
        await _settle(tester);
        await tester.binding.handlePopRoute();
        await _settle(tester);
        expect(tester.widget<TextField>(composer).controller!.text, 'A4未发送草稿');
        final bytes = await tester.runAsync(() async {
          await runtime.diagnostics.flush();
          return validateDiagnosticExport(
            await runtime.diagnostics.exportRecent(),
          );
        });
        expect(bytes, contains('ustc-diagnostics-export-v1'));
        expect(bytes, isNot(contains('A4未发送草稿')));
        expect(bytes, isNot(contains('A4合成实验')));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          final snapshot = await runtime.jwStore.applicationSettings
              .inspectSettings();
          await runtime.settings.saveDisplayPreferences(
            snapshot.context,
            const DisplayPreferences(calendarView: DefaultCalendarView.week),
          );
          await bootstrap!.close();
          bootstrap = await RuntimeBootstrap.open(
            platformFactory: _FixturePlatform(fixture!.path),
            clock: _clock,
          );
          expect(bootstrap!.runtime!.calendar.view.mode, CalendarViewMode.week);
          final tasks = await bootstrap!.runtime!.jwStore.localCalendar
              .queryTasks(const TaskQuery());
          expect(tasks.items.single.draft.title, 'A4合成截止任务');
        });
        expect(network.attempts, 0);
        expect(tester.takeException(), isNull);
        binding.reportData = {
          'kind': 'android-a4-validation-v1',
          'realDevice': false,
          'phoneNavigation': true,
          'draftRetained': true,
          'localCalendarTasks': true,
          'savedViewRetained': true,
          'diagnosticWhitelist': true,
          'networkAttempts': network.attempts,
          'realPickerAcceptance': false,
        };
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await bootstrap?.close();
          if (fixture != null) {
            final root = await _qaRoot();
            if (!p.posix.isWithin(root, fixture.path) ||
                !p.posix.basename(fixture.path).startsWith('a4_phone_')) {
              throw StateError('Unexpected A4 fixture');
            }
            await fixture.delete(recursive: true);
          }
        });
        HttpOverrides.global = previousNetwork;
      }
    },
    skip: !Platform.isAndroid,
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Future<String> _qaRoot() async {
  final root = await _platform.invokeMethod<String>('privateDataRoot');
  if (root == null ||
      !root.contains('/cn.ustcassistant.mobile.qa/') ||
      !root.endsWith('/no_backup/ustc_assistant_v1')) {
    throw StateError('A4 requires the isolated Android QA sandbox');
  }
  return root;
}

Future<Directory> _fixture() async =>
    Directory(await _qaRoot()).createTemp('a4_phone_');

final class _FixturePlatform implements RuntimePlatformFactory {
  const _FixturePlatform(this.path);
  final String path;
  static const _delegate = AndroidRuntimePlatformFactory();
  @override
  Future<RuntimeDirectories> acquireDirectories({
    String? directoryPath,
    String? jwDirectoryPath,
  }) async {
    final roots = await AndroidDirectories.acquire(path);
    return RuntimeDirectories(demo: roots.demo, formal: roots.formal);
  }

  @override
  JwCredentialProtector get schoolCredentials => _delegate.schoolCredentials;
  @override
  ModelCredentialProtector get modelCredentials => _delegate.modelCredentials;
  @override
  NativeObservationBrowser createBrowser() => _delegate.createBrowser();
  @override
  NotificationPlatformPort createNotifications() =>
      _delegate.createNotifications();
  @override
  SpeechInputPort createSpeech(DiagnosticsPort diagnostics) =>
      _delegate.createSpeech(diagnostics);
}

final class _NoNetwork extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('A4 local UI must not contact a source or model');
  }
}
