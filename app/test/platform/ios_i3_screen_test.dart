import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_page.dart';
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/app/diagnostics_panel.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';
import 'package:ustc_assistant_m0/ios_i3_entry.dart';
import 'package:ustc_assistant_m0/platform/demo_directory.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/owned_directory.dart';
import 'package:ustc_assistant_m0/platform/runtime_platform_factory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'narrow schedule entry, foreground lifecycle and resolved reminder navigation',
    (tester) async {
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });

      const platformChannel = MethodChannel('ustc_assistant/platform_v1');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platformChannel, (call) async {
            if (call.method != 'i3BuildInfo') return null;
            return <String, Object?>{
              'revision': 'unknown',
              'bundleId': 'cn.ustcassistant.ios.private',
              'authentication': 'manual',
              'notificationBackend': 'user-notifications-v1',
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(platformChannel, null),
      );

      final temporaryRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('ios-i3-screen-'),
      ))!;
      addTearDown(() async {
        await tester.runAsync(() async {
          if (await temporaryRoot.exists()) {
            await temporaryRoot.delete(recursive: true);
          }
        });
      });

      final notifications = _SyntheticNotifications();
      final factory = _SyntheticPlatformFactory(
        root: temporaryRoot.path,
        notifications: notifications,
      );
      RuntimeBootstrap? bootstrap;
      addTearDown(() async {
        if (bootstrap != null) await _drainTestRuntime(tester, bootstrap);
        await notifications.close();
      });
      var openCount = 0;
      bootstrap = await tester.runAsync(
        () => RuntimeBootstrap.open(
          clock: FixedClock(DateTime.utc(2026, 11, 4, 8)),
          modelGateway: _NoNetworkModelGateway(),
          morningGateway: _NoNetworkModelGateway(),
          notificationPlatform: notifications,
          platformFactory: factory,
        ).timeout(const Duration(seconds: 15)),
      );

      // Seed while no widget-owned reads are queued in the fake async zone.
      // Awaiting those reads from runAsync after mounting would deadlock their
      // continuation until the tester pumps again.
      await tester.runAsync(() async {
        final runtime = bootstrap!.runtime!;
        final context = runtime.calendar.view.window!.context;
        final command = await runtime.jwStore.localCalendar.prepare(
          context,
          CreatePersonalEvent(
            PersonalEventDraft(
              title: '合成提醒导航安排',
              start: DateTime.utc(2026, 11, 4, 10),
              end: DateTime.utc(2026, 11, 4, 11),
            ),
          ),
        );
        await runtime.jwStore.localCalendar.commit(command);
        final reminderSettings = await runtime.jwStore.features
            .inspectReminders();
        await runtime.jwStore.features.saveReminderPreferences(
          reminderSettings,
          reminderSettings.preferences.copyWith(enabled: true),
        );
        await runtime.reminders.refresh();
      });
      expect(notifications.scheduled, isNotEmpty);

      await tester.pumpWidget(
        IOSI3App(
          openBootstrap: (_) async {
            openCount++;
            return bootstrap!;
          },
        ),
      );
      await _pumpFrames(tester);
      final runtime = bootstrap!.runtime!;

      expect(openCount, 1);
      expect(
        tester
            .widget<NavigationBar>(
              find.byKey(const ValueKey('ios-i3-bottom-navigation')),
            )
            .selectedIndex,
        0,
      );
      expect(
        find.byKey(const ValueKey('calendar-personal-create')),
        findsOneWidget,
      );
      expect(find.byType(AgentWorkspacePage), findsNothing);
      expect(find.byIcon(Icons.mic_none_rounded), findsNothing);
      expect(find.byType(DiagnosticsExportButton), findsOneWidget);
      expect(
        identical(
          tester
              .widget<DiagnosticsExportButton>(
                find.byType(DiagnosticsExportButton),
              )
              .diagnostics,
          bootstrap.diagnostics,
        ),
        isTrue,
      );
      expect(find.text('配置晨报模型'), findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _pumpFrames(tester);
      expect(
        openCount,
        1,
        reason: 'widget rebuilds and lifecycle do not reopen ownership',
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      expect(runtime.calendar.view.window, isNotNull);

      await tester.tap(find.text('提醒').last);
      await _pumpFrames(tester, count: 3);
      final pending = notifications.scheduled.first;
      notifications.activate(
        NotificationActivation(pending.id, pending.digest, pending.token),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await _pumpFrames(tester);

      expect(
        tester
            .widget<NavigationBar>(
              find.byKey(const ValueKey('ios-i3-bottom-navigation')),
            )
            .selectedIndex,
        0,
      );
      expect(runtime.calendar.view.detail?.occurrence.title, '合成提醒导航安排');
      expect(openCount, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await _drainTestRuntime(tester, bootstrap);
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  testWidgets('startup failure keeps a safe diagnostic export available', (
    tester,
  ) async {
    const channel = MethodChannel('ustc_assistant/platform_v1');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => <String, Object?>{
            'revision': 'unknown',
            'bundleId': 'cn.ustcassistant.ios.private',
            'authentication': 'manual',
            'notificationBackend': 'user-notifications-v1',
          },
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await tester.pumpWidget(
      IOSI3App(
        openBootstrap: (_) async {
          throw const AppFailure(FailureCode.unsafeDirectory);
        },
      ),
    );
    await _pumpFrames(tester);
    expect(find.byType(DiagnosticsExportButton), findsOneWidget);
    final export = tester.widget<DiagnosticsExportButton>(
      find.byType(DiagnosticsExportButton),
    );
    final contents = await export.diagnostics.exportRecent();
    final payload = jsonDecode(contents) as Map<String, Object?>;
    expect(payload['coverage'], 'startup_error_only');
    expect(payload['complete'], isFalse);
    expect(payload['records'], isNotEmpty);
    expect(contents, contains('applicationFailed'));
    expect(contents, isNot(contains('cn.ustcassistant.ios.private')));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}

Future<void> _drainTestRuntime(
  WidgetTester tester,
  RuntimeBootstrap bootstrap,
) async {
  var done = false;
  Object? failure;
  unawaited(
    bootstrap.close().then<void>(
      (_) => done = true,
      onError: (Object error) {
        failure = error;
        done = true;
      },
    ),
  );
  final elapsed = Stopwatch()..start();
  while (!done && elapsed.elapsed < const Duration(seconds: 10)) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(
    done,
    isTrue,
    reason: 'synthetic runtime must drain before timer verification',
  );
  expect(failure, isNull, reason: 'synthetic runtime shutdown must succeed');
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 8}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
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
      // The host widget test exercises composition, not Darwin ownership.
      // The Simulator suite separately acquires the actual iOS native lease.
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
  String get mechanism => 'ios-i3-test-only/v1';

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
  @override
  Future<List<String>> listModels(ModelSecretLease secret) async => const [];

  @override
  Stream<ModelEvent> generate(ModelRequest request, ModelSecretLease secret) =>
      Stream<ModelEvent>.error(StateError('network is disabled in this test'));

  @override
  Future<void> cancelAndDrain() async {}

  @override
  Future<void> close() async {}
}

final class _SyntheticNotifications implements NotificationPlatformPort {
  final _activations = StreamController<NotificationActivation>.broadcast();
  final Map<String, NotificationPending> _pending = {};

  List<NotificationPending> get scheduled => List.unmodifiable(_pending.values);

  @override
  Stream<NotificationActivation> get activations => _activations.stream;

  @override
  Future<NotificationCapability> initialize() async =>
      const NotificationCapability(
        available: true,
        enabledBySystem: true,
        schedulesAfterExit: true,
        activationAvailable: true,
        exactScheduling: true,
        queueEvidence: NotificationQueueEvidence.localRegistration,
        maximumPending: 60,
        authorizationStatus: NotificationAuthorizationStatus.authorized,
      );

  @override
  Future<List<NotificationPending>> pending() async => scheduled;

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
  Future<void> clearOwn() async {
    _pending.clear();
  }

  void activate(NotificationActivation activation) =>
      _activations.add(activation);

  @override
  Future<void> close() async {
    if (!_activations.isClosed) await _activations.close();
  }
}
