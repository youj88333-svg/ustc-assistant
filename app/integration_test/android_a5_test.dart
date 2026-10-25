// A5: architecture 10/12, quality13, approved migration contract. Independent
// QA owner, synthetic C3 data and actual Android scheduling; no school/model IO.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/core/settings_contract.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';
import 'package:ustc_assistant_m0/platform/android_directory.dart';
import 'package:ustc_assistant_m0/platform/android_notifications.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/runtime_platform_factory.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android C3 task/calendar changes reconcile and maintenance revokes alarms',
    (tester) async {
      await tester.runAsync(() async {
        const channel = MethodChannel('ustc_assistant/platform_v1');
        final root = await channel.invokeMethod<String>('privateDataRoot');
        if (root == null ||
            !root.contains('/cn.ustcassistant.mobile.qa/') ||
            !root.endsWith('/no_backup/ustc_assistant_v1')) {
          throw StateError('A5 requires the isolated QA identity');
        }
        final fixture = await Directory(root).createTemp('a5_runtime_');
        final network = _NoNetwork();
        final previous = HttpOverrides.current;
        HttpOverrides.global = network;
        final clock = FixedClock(DateTime.now().toUtc());
        RuntimeBootstrap? bootstrap;
        final platform = _FixturePlatform(fixture.path);
        try {
          bootstrap = await RuntimeBootstrap.open(
            platformFactory: platform,
            clock: clock,
          );
          var runtime = bootstrap.runtime!;
          final settings = await runtime.jwStore.features.inspectReminders();
          await runtime.jwStore.features.saveReminderPreferences(
            settings,
            settings.preferences.copyWith(enabled: true),
          );
          final context =
              (await runtime.jwStore.localCalendar.readPlanContext()).$1;
          final created = await runtime.jwStore.localCalendar.commit(
            await runtime.jwStore.localCalendar.prepare(
              context,
              CreatePersonalEvent(
                PersonalEventDraft(
                  title: 'A5合成实验',
                  location: 'QA-201',
                  start: clock.nowUtc.add(const Duration(hours: 2)),
                  end: clock.nowUtc.add(const Duration(hours: 3)),
                ),
              ),
            ),
          );
          await runtime.reminders.refresh();
          await _idle(runtime);
          expect(runtime.reminders.view.failure, isNull);
          expect(runtime.reminders.view.accepted, 1);
          expect(
            runtime.reminders.view.capability!.queueEvidence,
            NotificationQueueEvidence.localRegistration,
          );
          expect(
            (await platform.notifications.pending()).single.location,
            'QA-201',
          );
          await bootstrap.close();
          bootstrap = null;
          bootstrap = await RuntimeBootstrap.open(
            platformFactory: platform,
            clock: clock,
          );
          runtime = bootstrap.runtime!;
          await runtime.reminders.refresh();
          await _idle(runtime);
          expect(
            (await platform.notifications.pending()).length,
            1,
            reason: 'ordinary close retains native registration',
          );
          await runtime.jwStore.localCalendar.commit(
            await runtime.jwStore.localCalendar.prepare(
              context,
              SetPersonalOccurrenceState(created.target!, completed: true),
            ),
          );
          await runtime.reminders.refresh();
          await _idle(runtime);
          expect(await platform.notifications.pending(), isEmpty);
          await runtime.jwStore.localCalendar.commit(
            await runtime.jwStore.localCalendar.prepare(
              context,
              CreateTask(
                TaskDraft(
                  title: 'A5合成截止任务',
                  deadlineAtUtc: clock.nowUtc.add(const Duration(hours: 4)),
                ),
              ),
            ),
          );
          await runtime.reminders.refresh();
          await _idle(runtime);
          expect(
            (await platform.notifications.pending()).single.title,
            contains('A5合成截止任务'),
          );
          final appSettings = await runtime.jwStore.applicationSettings
              .inspectSettings();
          await runtime.maintenance.start(
            appSettings.context,
            MaintenanceKind.agenda,
            confirmed: true,
          );
          expect(runtime.maintenance.view.blocksProduct, isFalse);
          await _idle(runtime);
          expect(await platform.notifications.pending(), isEmpty);
          expect(network.attempts, 0);
          binding.reportData = {
            'kind': 'android-a5-runtime-v1',
            'calendar': true,
            'task': true,
            'reopen': true,
            'maintenance': true,
            'networkAttempts': network.attempts,
            'realDevice': false,
          };
        } finally {
          if (bootstrap != null) await bootstrap.close();
          // Fixed QA mirror only; fixtures were never under a production identity.
          final cleanup = AndroidNotifications();
          await cleanup.blockDelivery();
          await cleanup.clearOwn();
          await cleanup.close();
          HttpOverrides.global = previous;
          if (await fixture.exists()) await fixture.delete(recursive: true);
        }
      });
    },
    skip: !Platform.isAndroid,
  );
}

Future<void> _idle(DemoRuntime runtime) async {
  for (var i = 0; i < 80; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!runtime.reminders.view.busy && i >= 5) return;
  }
  throw StateError('A5 reminder reconciliation did not drain');
}

final class _FixturePlatform implements RuntimePlatformFactory {
  _FixturePlatform(this.path);
  final String path;
  late AndroidNotifications notifications;
  static const _delegate = AndroidRuntimePlatformFactory();
  @override
  Future<RuntimeDirectories> acquireDirectories({
    String? directoryPath,
    String? jwDirectoryPath,
  }) async {
    final dirs = await AndroidDirectories.acquire(path);
    return RuntimeDirectories(demo: dirs.demo, formal: dirs.formal);
  }

  @override
  JwCredentialProtector get schoolCredentials => _delegate.schoolCredentials;
  @override
  ModelCredentialProtector get modelCredentials => _delegate.modelCredentials;
  @override
  NativeObservationBrowser createBrowser() => _delegate.createBrowser();
  @override
  NotificationPlatformPort createNotifications() =>
      notifications = AndroidNotifications();
  @override
  SpeechInputPort createSpeech(DiagnosticsPort diagnostics) =>
      _delegate.createSpeech(diagnostics);
}

final class _NoNetwork extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('A5 synthetic runtime cannot access school/model');
  }
}
