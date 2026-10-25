// A8: four-step local navigation, production runtime and private synthetic DBs.
// No real school, model, credentials, notifications or production records.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/app/onboarding_page.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/core/onboarding_contract.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/core/settings_contract.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';
import 'package:ustc_assistant_m0/m0_entry.dart';
import 'package:ustc_assistant_m0/platform/android_directory.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/runtime_platform_factory.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  testWidgets(
    'fresh guide skips without consent, resumes and reopens after reset',
    (tester) async {
      final fixture = await tester.runAsync(_createFixture);
      final network = _NoNetwork();
      final previousNetwork = HttpOverrides.current;
      HttpOverrides.global = network;
      RuntimeBootstrap? bootstrap;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 900);
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      try {
        Future<RuntimeBootstrap> open() => RuntimeBootstrap.open(
          platformFactory: _FixturePlatform(fixture!.path),
          clock: FixedClock(DateTime.utc(2026, 10, 25, 1)),
          notificationPlatform: _NoNotifications(),
        );
        debugPrint('Onboarding QA: opening owned fixture');
        bootstrap = await tester.runAsync(open);
        debugPrint('Onboarding QA: mounting fresh application');
        await tester.pumpWidget(_application(bootstrap!));
        await _settle(tester);
        debugPrint('Onboarding QA: fresh application ready');
        expect(find.text('先连上你的学校账号'), findsOneWidget);
        await _capture(tester, 'account');
        await tester.tap(find.byKey(const ValueKey('setup-skip')));
        await _settle(tester);
        expect(find.text('把课表和二课带进来'), findsOneWidget);
        await _capture(tester, 'sources');
        await tester.tap(find.byKey(const ValueKey('setup-defer')));
        await _settle(tester);
        expect(find.byKey(const ValueKey('agent-composer')), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(bootstrap.close);
        bootstrap = await tester.runAsync(open);
        await tester.pumpWidget(_application(bootstrap!));
        await _settle(tester);
        expect(find.byKey(const ValueKey('agent-composer')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('shell-nav-settings')));
        await _settle(tester);
        await tester.tap(find.byKey(const ValueKey('settings-open-setup')));
        await _settle(tester);
        expect(find.text('把课表和二课带进来'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('setup-skip')));
        await _settle(tester);
        expect(find.text('选一个模型来帮忙'), findsOneWidget);
        await _capture(tester, 'model');
        debugPrint('Onboarding QA: leaving model step');
        await tester.tap(find.byKey(const ValueKey('setup-skip')));
        debugPrint('Onboarding QA: settling permission step');
        await _settle(tester);
        debugPrint('Onboarding QA: permission step settled');
        expect(find.text('决定它能帮你做什么'), findsOneWidget);
        await _capture(tester, 'permissions');
        final data = bootstrap.jwStore;
        final before = await tester.runAsync(
          data.applicationSettings.inspectSettings,
        );
        expect(before!.icourseConsent, isFalse);
        final reminders = await tester.runAsync(data.features.inspectReminders);
        expect(reminders!.preferences.enabled, isFalse);
        expect(reminders.preferences.morningEnabled, isFalse);
        expect(bootstrap.runtime!.agent.view.personalContentAllowed, isFalse);
        expect(bootstrap.runtime!.agent.view.dailyOperationsAllowed, isFalse);
        await tester.tap(find.byKey(const ValueKey('setup-next')));
        await _settle(tester);
        expect(find.byKey(const ValueKey('agent-composer')), findsOneWidget);
        expect(
          (await tester.runAsync(data.onboarding.inspect))!.status,
          OnboardingStatus.done,
        );
        expect(network.attempts, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(bootstrap.close);
        bootstrap = await tester.runAsync(open);
        await tester.pumpWidget(_application(bootstrap!));
        await _settle(tester);
        expect(find.byKey(const ValueKey('agent-composer')), findsOneWidget);
        // Use the same production maintenance command as Settings, on this
        // isolated fixture. Reset must withdraw the old tree and its drafts.
        await tester.runAsync(() async {
          final snapshot = await bootstrap!.jwStore.applicationSettings
              .inspectSettings();
          await bootstrap.settings.runMaintenance(
            snapshot.context,
            MaintenanceKind.reset,
            confirmed: true,
          );
        });
        await _settle(tester);
        expect(find.text('先连上你的学校账号'), findsOneWidget);
        expect(network.attempts, 0);
        expect(tester.takeException(), isNull);
        binding.reportData = {
          'kind': 'onboarding-runtime-validation-v1',
          'platform': Platform.operatingSystem,
          'networkAttempts': network.attempts,
          'fresh': true,
          'deferredRestart': true,
          'finishRestart': true,
          'reset': true,
          'permissionsGranted': false,
          'realServices': false,
        };
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await bootstrap?.close();
          if (fixture != null && await fixture.exists()) {
            await fixture.delete(recursive: true);
          }
        });
        HttpOverrides.global = previousNetwork;
      }
    },
  );
  testWidgets(
    'enabled morning waits for guide exit before any public network work',
    (tester) async {
      final fixture = await tester.runAsync(_createFixture);
      final previousNetwork = HttpOverrides.current;
      final network = _NoNetwork();
      HttpOverrides.global = network;
      RuntimeBootstrap? bootstrap;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1100, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      try {
        bootstrap = await tester.runAsync(
          () => RuntimeBootstrap.open(
            platformFactory: _FixturePlatform(fixture!.path),
            clock: FixedClock(DateTime.utc(2026, 10, 25, 1)),
            notificationPlatform: _NoNotifications(),
          ),
        );
        await tester.runAsync(() async {
          final preferences = await bootstrap!.jwStore.features
              .inspectReminders();
          await bootstrap.jwStore.features.saveReminderPreferences(
            preferences,
            preferences.preferences.copyWith(morningEnabled: true),
          );
        });
        await tester.pumpWidget(_application(bootstrap!));
        await _settle(tester);
        await _capture(tester, 'account-wide');
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)),
          );
          await tester.pump();
        }
        expect(
          network.attempts,
          0,
          reason: 'Active guide blocks automatic morning admission',
        );
        await tester.tap(find.byKey(const ValueKey('setup-defer')));
        final watch = Stopwatch()..start();
        while (network.attempts == 0 &&
            watch.elapsed < const Duration(seconds: 15)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)),
          );
          await tester.pump();
        }
        expect(
          network.attempts,
          greaterThan(0),
          reason: 'Existing opt-in resumes only after explicit guide exit',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await bootstrap?.close();
          if (fixture != null && await fixture.exists()) {
            await fixture.delete(recursive: true);
          }
        });
        HttpOverrides.global = previousNetwork;
      }
    },
  );
}

Widget _application(RuntimeBootstrap bootstrap) => RepaintBoundary(
  key: const ValueKey('onboarding-capture'),
  child: OwnedApplication(bootstrap: bootstrap),
);

Future<void> _settle(WidgetTester tester) async {
  final watch = Stopwatch()..start();
  while (true) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump();
    final pages = find.byType(OnboardingPage);
    if (pages.evaluate().isEmpty) {
      final application = tester.widget<OwnedApplication>(
        find.byType(OwnedApplication),
      );
      final settings = application.bootstrap.settings.settingsView;
      if (!settings.loading && !settings.maintenance.blocksProduct) break;
    } else {
      final page = tester.widget<OnboardingPage>(pages);
      final next = find.byKey(const ValueKey('setup-next'));
      if (!page.progress.loading &&
          !page.progress.pending &&
          !page.progress.failure &&
          next.evaluate().isNotEmpty &&
          tester.widget<FilledButton>(next).onPressed != null) {
        break;
      }
      if (page.progress.failure) {
        throw StateError('Synthetic guide progress failed');
      }
    }
    if (watch.elapsed > const Duration(seconds: 30)) {
      throw StateError('Synthetic setup command did not finish');
    }
  }
  await tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 5),
  );
}

Future<Directory> _createFixture() async {
  if (!Platform.isAndroid) {
    return Directory.systemTemp.createTemp('onboarding-qa-');
  }
  final root = await const MethodChannel(
    'ustc_assistant/platform_v1',
  ).invokeMethod<String>('privateDataRoot');
  if (root == null ||
      !root.contains('/cn.ustcassistant.mobile.qa/') ||
      !root.endsWith('/no_backup/ustc_assistant_v1')) {
    throw StateError('Requires owned QA sandbox');
  }
  return Directory(root).createTemp('onboarding_qa_');
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!Platform.isWindows) return;
  debugPrint('Onboarding QA: capture $name');
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('onboarding-capture')),
  );
  await tester.runAsync(() async {
    final picture = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('Empty synthetic capture');
      final directory = await Directory(
        'build/android-onboarding/screenshots',
      ).create(recursive: true);
      await File(
        '${directory.path}/$name.png',
      ).writeAsBytes(bytes.buffer.asUint8List());
    } finally {
      picture.dispose();
    }
  });
  debugPrint('Onboarding QA: capture $name saved');
}

final class _FixturePlatform implements RuntimePlatformFactory {
  _FixturePlatform(this.path);
  final String path;
  RuntimePlatformFactory get delegate => runtimePlatformFactory();
  @override
  Future<RuntimeDirectories> acquireDirectories({
    String? directoryPath,
    String? jwDirectoryPath,
  }) async {
    if (Platform.isAndroid) {
      final roots = await AndroidDirectories.acquire(path);
      return RuntimeDirectories(demo: roots.demo, formal: roots.formal);
    }
    return delegate.acquireDirectories(
      directoryPath: '$path/demo',
      jwDirectoryPath: '$path/formal',
    );
  }

  @override
  JwCredentialProtector get schoolCredentials => delegate.schoolCredentials;
  @override
  ModelCredentialProtector get modelCredentials => delegate.modelCredentials;
  @override
  NativeObservationBrowser createBrowser() => delegate.createBrowser();
  @override
  NotificationPlatformPort createNotifications() => _NoNotifications();
  @override
  SpeechInputPort createSpeech(DiagnosticsPort diagnostics) =>
      delegate.createSpeech(diagnostics);
}

final class _NoNetwork extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError(
      'Onboarding must wait for an explicit source or model action',
    );
  }
}

final class _NoNotifications implements NotificationPlatformPort {
  @override
  Stream<NotificationActivation> get activations => const Stream.empty();
  @override
  Future<NotificationCapability> initialize() async =>
      const NotificationCapability(
        available: false,
        enabledBySystem: false,
        schedulesAfterExit: false,
        activationAvailable: false,
      );
  @override
  Future<List<NotificationPending>> pending() async => [];
  @override
  Future<void> schedule(NotificationRequest request) async =>
      throw StateError('No OS scheduling in setup test');
  @override
  Future<void> cancel(String id) async {}
  @override
  Future<void> clearOwn() async {}
  @override
  Future<void> close() async {}
}
