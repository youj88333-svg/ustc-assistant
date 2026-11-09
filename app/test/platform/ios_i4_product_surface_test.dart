import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/app/calendar_workspace_page.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_page.dart';
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/app/diagnostics_panel.dart';
import 'package:ustc_assistant_m0/app/onboarding_page.dart';
import 'package:ustc_assistant_m0/app/task_workspace_page.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';
import 'package:ustc_assistant_m0/m0_entry.dart';
import 'package:ustc_assistant_m0/platform/demo_directory.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/owned_directory.dart';
import 'package:ustc_assistant_m0/platform/runtime_platform_factory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'iOS private assembly keeps Agent, logs, settings, agenda and reminders reachable on a phone',
    (tester) async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        tester.view.devicePixelRatio = 1;
        await _setPhoneViewport(tester, const Size(375, 812));
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.view.resetViewInsets();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });

        final imageChannelCalls = <String>[];
        const imageChannel = MethodChannel('ustc_assistant/images_v1');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(imageChannel, (call) async {
              imageChannelCalls.add(call.method);
              // Runtime teardown may cancel an idle native selection. No picker
              // method is invoked by this surface test.
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(imageChannel, null),
        );
        const hostChannel = MethodChannel(
          'ustc_assistant/ios_host_lifecycle_v1',
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(hostChannel, (_) async => null);
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(hostChannel, null),
        );

        final temporaryRoot = (await tester.runAsync(() async {
          final buildDirectory = Directory(
            p.join(Directory.current.path, 'build'),
          );
          await buildDirectory.create(recursive: true);
          return buildDirectory.createTemp('ios-i4-product-surface-');
        }))!;
        final notifications = _SyntheticNotifications();
        final factory = _SyntheticPlatformFactory(
          root: temporaryRoot.path,
          notifications: notifications,
        );
        final agentGateway = _NoNetworkModelGateway();
        final morningGateway = _NoNetworkModelGateway();
        RuntimeBootstrap? bootstrap;
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          if (bootstrap != null) await _drainTestRuntime(tester, bootstrap);
          await notifications.close();
          await tester.runAsync(() async {
            if (await temporaryRoot.exists()) {
              await temporaryRoot.delete(recursive: true);
            }
          });
        });

        final openedBootstrap = await tester.runAsync(
          () => RuntimeBootstrap.open(
            clock: FixedClock(DateTime.utc(2026, 11, 9, 8)),
            collectionDelay: Duration.zero,
            modelGateway: agentGateway,
            morningGateway: morningGateway,
            notificationPlatform: notifications,
            platformFactory: factory,
          ).timeout(const Duration(seconds: 20)),
        );
        bootstrap = openedBootstrap;
        final runtime = openedBootstrap!.runtime!;

        await tester.pumpWidget(
          OwnedApplication(
            bootstrap: openedBootstrap,
            enableOnboarding: false,
            privateBuildInformation: 'i4 surface synthetic build',
          ),
        );
        await _pumpFrames(tester);

        expect(find.byType(OnboardingPage), findsNothing);
        expect(find.byType(AgentWorkspacePage), findsOneWidget);
        expect(find.byKey(const ValueKey('agent-page-title')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('shell-phone-navigation')),
          findsOneWidget,
        );
        expect(find.byType(NavigationDestination), findsNWidgets(2));
        expect(find.byType(Drawer), findsNothing);
        expect(find.byIcon(Icons.mic_none_rounded), findsNothing);
        expect(runtime.agent.view.conversationId, isNotNull);
        expect(runtime.agent.view.conversations, hasLength(1));
        expect(
          runtime.agent.view.conversations.single.id,
          runtime.agent.view.conversationId,
        );

        final topBarLogs = find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(DiagnosticsExportButton),
        );
        expect(topBarLogs, findsOneWidget);
        expect(
          identical(
            tester.widget<DiagnosticsExportButton>(topBarLogs).diagnostics,
            openedBootstrap.diagnostics,
          ),
          isTrue,
        );

        // A larger 393-point viewport with 2x text and a keyboard-sized inset
        // keeps the real product composer usable without exercising a model.
        await _setPhoneViewport(tester, const Size(393, 852));
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        await _pumpFrames(tester);
        final composer = find.byKey(const ValueKey('agent-composer'));
        await tester.ensureVisible(composer);
        await tester.tap(composer);
        await tester.pump();
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await _pumpFrames(tester);
        await tester.enterText(composer, '合成草稿，不发送');
        await tester.pump();
        expect(tester.widget<TextField>(composer).controller!.text, '合成草稿，不发送');
        expect(
          tester.getRect(composer).bottom,
          lessThanOrEqualTo(tester.view.physicalSize.height - 299),
          reason: 'composer stays above the keyboard-sized view inset',
        );
        expect(
          find.byKey(const ValueKey('shell-phone-navigation')),
          findsNothing,
        );
        expect(find.byType(Drawer), findsNothing);
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        FocusManager.instance.primaryFocus?.unfocus();
        await _pumpFrames(tester);

        // The phone has Agent and agenda destinations; task work remains a
        // section within agenda instead of becoming a third navigation root.
        await tester.tap(find.byKey(const ValueKey('shell-nav-agenda')));
        await _pumpFrames(tester);
        final scheduleTab = find.byKey(
          const ValueKey('calendar-workspace-tab-schedule'),
        );
        final tasksTab = find.byKey(
          const ValueKey('calendar-workspace-tab-tasks'),
        );
        expect(find.byType(CalendarWorkspacePage), findsOneWidget);
        expect(scheduleTab, findsOneWidget);
        expect(tasksTab, findsOneWidget);
        await tester.ensureVisible(tasksTab);
        await tester.tap(tasksTab);
        await _pumpFrames(tester);
        expect(find.byType(TaskWorkspacePage), findsOneWidget);
        await tester.tap(scheduleTab);
        await _pumpFrames(tester);
        expect(find.byType(CalendarWorkspacePage), findsOneWidget);

        // Settings opens from the phone toolbar. Model configuration and the
        // existing per-category permission section are local reads only.
        await tester.tap(find.byKey(const ValueKey('shell-nav-settings')));
        await _pumpFrames(tester);
        final modelSection = find.byKey(
          const ValueKey('settings-section-agent'),
        );
        await tester.ensureVisible(modelSection);
        await tester.tap(modelSection);
        await _pumpFrames(tester);
        final modelProvider = find.byKey(
          const ValueKey('agent-settings-provider-school'),
        );
        await tester.ensureVisible(modelProvider);
        expect(modelProvider, findsOneWidget);
        expect(
          tester
              .widget<DropdownButtonFormField<ModelProvider>>(modelProvider)
              .onChanged,
          isNotNull,
        );
        final permissionHeading = find.text('已记住的操作授权');
        await tester.scrollUntilVisible(
          permissionHeading,
          300,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('agent-settings-panel')),
                matching: find.byType(Scrollable),
              )
              .first,
          maxScrolls: 45,
        );
        await _pumpFrames(tester);
        expect(permissionHeading, findsOneWidget);
        expect(find.text('尚未记住任何操作授权。'), findsOneWidget);

        final aboutSection = find.byKey(
          const ValueKey('settings-section-about'),
        );
        await tester.ensureVisible(aboutSection);
        await tester.tap(aboutSection);
        await _pumpFrames(tester);
        expect(find.text('i4 surface synthetic build'), findsOneWidget);

        final remindersSection = find.byKey(
          const ValueKey('settings-section-reminders'),
        );
        await tester.ensureVisible(remindersSection);
        await tester.tap(remindersSection);
        await _pumpFrames(tester);
        final reminderControl = find.byKey(
          const ValueKey('m6-system-reminders-enabled'),
        );
        await tester.ensureVisible(reminderControl);
        expect(reminderControl, findsOneWidget);
        expect(find.byType(Drawer), findsNothing);

        expect(agentGateway.generateCalls, 0);
        expect(agentGateway.modelListCalls, 0);
        expect(morningGateway.generateCalls, 0);
        expect(imageChannelCalls, isNot(contains('pickImages')));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await _drainTestRuntime(tester, openedBootstrap);
        bootstrap = null;
      } finally {
        // Flutter verifies this debug global before addTearDown callbacks.
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

Future<void> _setPhoneViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.viewInsets = const FakeViewPadding();
  await tester.pump();
}

Future<void> _drainTestRuntime(
  WidgetTester tester,
  RuntimeBootstrap bootstrap,
) async {
  var done = false;
  Object? failure;
  await tester.runAsync(() async {
    unawaited(
      bootstrap.close().then<void>(
        (_) => done = true,
        onError: (Object error) {
          failure = error;
          done = true;
        },
      ),
    );
  });
  final elapsed = Stopwatch()..start();
  while (!done && elapsed.elapsed < const Duration(seconds: 12)) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(done, isTrue, reason: 'synthetic RuntimeBootstrap must close');
  expect(failure, isNull, reason: 'synthetic RuntimeBootstrap shutdown');
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 8}) async {
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 40));
    // SQLite uses real isolate/file I/O. Give those callbacks a real async
    // turn before pumping the widget continuation, rather than advancing ten
    // fake minutes while a progress indicator waits for real I/O.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}

final class _SyntheticPlatformFactory implements RuntimePlatformFactory {
  _SyntheticPlatformFactory({required this.root, required this.notifications});

  final String root;
  final _SyntheticNotifications notifications;
  final _SyntheticProtector _protector = _SyntheticProtector();
  final _SilentSpeechInput _speech = _SilentSpeechInput();

  @override
  Future<RuntimeDirectories> acquireDirectories({
    String? directoryPath,
    String? jwDirectoryPath,
  }) async {
    Future<OwnedDirectory> acquire(String child) async {
      final path = p.join(root, child);
      if (Platform.isWindows) return DemoDirectory.acquire(path);
      await Directory(path).create();
      return _WidgetFixtureDirectory(path);
    }

    final demo = await acquire('demo');
    try {
      final formal = await acquire('formal');
      return RuntimeDirectories(demo: demo, formal: formal);
    } on Object {
      await demo.release();
      rethrow;
    }
  }

  @override
  JwCredentialProtector get schoolCredentials => _protector;

  @override
  ModelCredentialProtector get modelCredentials => _protector;

  @override
  NativeObservationBrowser createBrowser() =>
      NativeObservationBrowser(requiresAvailabilityCheck: false);

  @override
  NotificationPlatformPort createNotifications() => notifications;

  @override
  SpeechInputPort createSpeech(DiagnosticsPort diagnostics) => _speech;
}

final class _WidgetFixtureDirectory implements OwnedDirectory {
  _WidgetFixtureDirectory(this.path);

  @override
  final String path;
  bool _released = false;

  @override
  p.Context get paths => p.context;

  @override
  bool get isHeld => !_released;

  @override
  void ensureHeld() {
    if (_released) throw const AppFailure(FailureCode.ownershipLost);
  }

  @override
  String checkedChildPath(String relative, {required bool directory}) {
    ensureHeld();
    final target = p.normalize(p.join(path, relative));
    if (p.isAbsolute(relative) || !p.isWithin(path, target)) {
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
    final type = FileSystemEntity.typeSync(target, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type !=
            (directory
                ? FileSystemEntityType.directory
                : FileSystemEntityType.file)) {
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
    return target;
  }

  @override
  String createPlainChildDirectory(String relative) {
    final target = checkedChildPath(relative, directory: true);
    Directory(target).createSync();
    return checkedChildPath(relative, directory: true);
  }

  @override
  void ensureDatabaseFilesSafe({String filename = 'm0_demo.sqlite'}) {
    for (final suffix in ['', '-wal', '-shm']) {
      checkedChildPath('$filename$suffix', directory: false);
    }
  }

  @override
  Future<void> release() async => _released = true;
}

final class _SyntheticProtector
    implements JwCredentialProtector, ModelCredentialProtector {
  @override
  String get mechanism => 'ios-i4-product-surface-test-only/v1';

  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async => Uint8List.fromList(plaintext);

  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) async => Uint8List.fromList(ciphertext);
}

final class _SilentSpeechInput implements SpeechInputPort {
  @override
  SpeechInputView get view => const SpeechInputView();

  @override
  Stream<SpeechInputView> get changes => const Stream.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> finish() async {}

  @override
  Future<void> cancel() async {}

  @override
  Future<void> close() async {}
}

final class _NoNetworkModelGateway implements ModelGatewayPort {
  int modelListCalls = 0;
  int generateCalls = 0;

  @override
  Future<List<String>> listModels(ModelSecretLease secret) async {
    modelListCalls++;
    return const [];
  }

  @override
  Stream<ModelEvent> generate(ModelRequest request, ModelSecretLease secret) {
    generateCalls++;
    return Stream<ModelEvent>.error(
      StateError('network disabled in iOS I4 product surface test'),
    );
  }

  @override
  Future<void> cancelAndDrain() async {}

  @override
  Future<void> close() async {}
}

final class _SyntheticNotifications implements NotificationPlatformPort {
  final _activations = StreamController<NotificationActivation>.broadcast();
  final Map<String, NotificationPending> _pending = {};

  @override
  Stream<NotificationActivation> get activations => _activations.stream;

  @override
  Future<NotificationCapability> initialize() async =>
      const NotificationCapability(
        available: true,
        enabledBySystem: false,
        schedulesAfterExit: true,
        activationAvailable: true,
        exactScheduling: true,
        queueEvidence: NotificationQueueEvidence.localRegistration,
        maximumPending: 60,
        authorizationStatus: NotificationAuthorizationStatus.notDetermined,
      );

  @override
  Future<List<NotificationPending>> pending() async =>
      List.unmodifiable(_pending.values);

  @override
  Future<void> schedule(NotificationRequest request) async {
    _pending[request.id] = NotificationPending(
      id: request.id,
      deliveryAtUtc: request.deliveryAtUtc,
      digest: request.digest,
      token: request.token,
      title: request.title,
      detail: request.detail,
      location: request.location,
    );
  }

  @override
  Future<void> cancel(String id) async {
    _pending.remove(id);
  }

  @override
  Future<void> clearOwn() async => _pending.clear();

  @override
  Future<void> close() async {
    await _activations.close();
  }
}
