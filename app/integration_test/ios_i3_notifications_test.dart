// I3 / 09 K-09: fresh job-owned Simulator only. Actual UN pending/readback and
// C3 transactions; no school, model, user account, or physical device is used.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/jobs/reminder_coordinator.dart';
import 'package:ustc_assistant_m0/platform/ios_notifications.dart';
import 'package:ustc_assistant_m0/platform/ios_runtime_platform_factory.dart';
import 'package:ustc_assistant_m0/platform/native_database.dart';

const _platform = MethodChannel('ustc_assistant/platform_v1');
const _native = MethodChannel('ustc_assistant/ios_notifications_v1');
const _operationTimeout = Duration(seconds: 30);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'I3 actual OS queue, capacity, C3 navigation, denial and maintenance',
    (tester) async {
      expect(kDebugMode, isTrue);
      final storage = await _platform.invokeMapMethod<String, Object?>(
        'storageProtectionStatus',
      );
      expect(storage?['isSimulator'], isTrue);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SafeArea(child: Center(child: Text('I3 合成系统提醒验证'))),
          ),
        ),
      );
      await tester.runAsync(() async {
        final reports = await _run();
        binding.reportData = reports;
      });
    },
    skip: !Platform.isIOS,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

Future<Map<String, Object>> _run() async {
  final factory = IOSRuntimePlatformFactory();
  final directories = await factory.acquireDirectories();
  final store = JwStore(
    openJwDatabase(directories.formal),
    ownership: directories.formal,
    clock: const SystemClock(),
    credentialProtector: factory.schoolCredentials,
    modelCredentialProtector: factory.modelCredentials,
  );
  IOSNotifications platform = IOSNotifications();
  ReminderCoordinator? coordinator;
  StreamSubscription<ReminderTarget>? navigation;
  final report = <String, Object>{};
  try {
    await store.initialize();
    await store.agent.initializeAgent();
    await store.features.initialize();
    final before = await platform.initialize();
    expect(
      before.authorizationStatus,
      NotificationAuthorizationStatus.notDetermined,
    );
    expect(before.maximumPending, 60);
    expect(before.exactScheduling, isNull);
    expect(before.queueEvidence, NotificationQueueEvidence.operatingSystem);
    expect(before.enabledBySystem, isFalse);
    // This is a real, quiet Simulator authorization; it does not click or
    // bypass a user's system permission prompt, and is absent from Release.
    await _fixture('provisional');
    expect((await platform.initialize()).enabledBySystem, isTrue);
    expect(await platform.pending(), isEmpty);
    report['readOnlyInitializationAndProvisionalSystemAuthorization'] = true;
    debugPrint('I3 phase: OS permissions and explicit synthetic authorization');

    final settings = await store.features.inspectReminders();
    await store.features.saveReminderPreferences(
      settings,
      settings.preferences.copyWith(enabled: true),
    );
    final now = DateTime.now().toUtc();
    final base = DateTime.fromMillisecondsSinceEpoch(
      now.add(const Duration(hours: 2)).millisecondsSinceEpoch ~/ 1000 * 1000 +
          123,
      isUtc: true,
    );
    Future<void> create(String title, DateTime start) async {
      final day = beijingDay(start);
      final window = await store.localCalendar.query(
        CalendarQuery(
          firstDay: day,
          endDayExclusive: day.add(const Duration(days: 1)),
        ),
      );
      await store.localCalendar.commit(
        await store.localCalendar.prepare(
          window.context,
          CreatePersonalEvent(
            PersonalEventDraft(
              title: title,
              start: start,
              end: start.add(const Duration(minutes: 30)),
              location: 'TEST-101',
              note: 'Synthetic note must never enter notifications',
            ),
          ),
        ),
      );
    }

    for (var index = 0; index < 65; index++) {
      await create(
        'Synthetic I3 $index',
        base.add(Duration(minutes: index * 2)),
      );
    }
    coordinator = ReminderCoordinator(data: store.features, platform: platform);
    await coordinator.refresh().timeout(const Duration(seconds: 90));
    expect(coordinator.view.failure, isNull);
    expect(coordinator.view.desired, 65);
    expect(coordinator.view.accepted, 60);
    expect(coordinator.view.unregistered, 5);
    expect(coordinator.view.complete, isFalse);
    var publication = await store.features.prepareReminderPublication();
    expect(publication.desired, hasLength(65));
    var queue = await platform.pending();
    expect(queue, hasLength(60));
    expect(
      queue.every((item) => !item.detail!.contains('Synthetic note')),
      isTrue,
    );
    expect(queue.every((item) => item.location == 'TEST-101'), isTrue);
    expect(
      queue.every((item) => item.deliveryAtUtc.millisecond == 123),
      isTrue,
    );
    _expectNearest(publication, queue);
    report['actualPendingRoundtripAndCapacityPreservesC3'] = true;
    debugPrint('I3 phase: real OS readback and 60 of 65 expectations');

    // Reproduce the phone's full-queue test failure against UserNotifications,
    // rather than only a synthetic notification adapter. A test borrows the
    // farthest planned slot, retains every business expectation, then refills.
    await coordinator.testNotification().timeout(_operationTimeout);
    queue = await platform.pending();
    expect(queue, hasLength(60));
    expect(queue.where((item) => item.id == 'm6-check'), hasLength(1));
    expect(
      (await store.features.prepareReminderPublication()).desired,
      hasLength(65),
    );
    await coordinator.refresh().timeout(_operationTimeout);
    expect(
      (await platform.pending()).where((item) => item.id == 'm6-check'),
      hasLength(1),
      reason: 'a foreground reconcile must preserve the accepted short test',
    );
    await Future<void>.delayed(const Duration(seconds: 7));
    await coordinator.refresh().timeout(_operationTimeout);
    queue = await platform.pending();
    expect(queue, hasLength(60));
    expect(queue.any((item) => item.id == 'm6-check'), isFalse);
    publication = await store.features.prepareReminderPublication();
    _expectNearest(publication, queue);
    report['fullQueueTestAcceptedThenBusinessSlotRefilled'] = true;
    debugPrint('I3 phase: full queue test accepted, expired and slot refilled');

    // Capture before the coordinator subscribes, then attach the UI listener
    // later. This is an injected delegate-path test, not a real system tap.
    final clicked = publication.desired.firstWhere(
      (item) => item.request.id == queue.first.id,
    );
    await _fixture('activate', id: clicked.request.id);
    coordinator.start();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final received = Completer<ReminderTarget>();
    var navigationCount = 0;
    navigation = coordinator.navigation.listen((target) {
      navigationCount++;
      if (!received.isCompleted) received.complete(target);
    });
    final target = await received.future.timeout(_operationTimeout);
    expect(target.canonical, clicked.target.canonical);
    await _fixture('activate', id: clicked.request.id);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(navigationCount, 1);
    report['coldBufferedActivationResolvedOnceByC3'] = true;
    await navigation.cancel();
    navigation = null;
    await coordinator.close();
    platform = IOSNotifications();
    coordinator = ReminderCoordinator(data: store.features, platform: platform);

    await create(
      'Synthetic nearer I3',
      base.subtract(const Duration(minutes: 20)),
    );
    await coordinator.refresh().timeout(const Duration(seconds: 90));
    publication = await store.features.prepareReminderPublication();
    queue = await platform.pending();
    expect(publication.desired, hasLength(66));
    expect(queue, hasLength(60));
    _expectNearest(publication, queue);
    final cancel = publication.desired.firstWhere(
      (item) => item.request.id == queue.first.id,
    );
    await store.features.saveReminderPair(
      cancel.target,
      const ReminderPair(ReminderRule.none(), ReminderRule.none()),
    );
    await coordinator.refresh().timeout(const Duration(seconds: 90));
    queue = await platform.pending();
    expect(queue.any((item) => item.id == cancel.request.id), isFalse);
    expect(queue, hasLength(60));
    publication = await store.features.prepareReminderPublication();
    _expectNearest(publication, queue);
    expect(
      await store.features.resolveNotification(
        NotificationActivation(
          cancel.request.id,
          cancel.request.digest,
          cancel.request.token,
        ),
      ),
      isNull,
    );
    report['nearerInsertionCancellationAndSlotRefill'] = true;
    debugPrint(
      'I3 phase: nearer request evicts distant and cancellation refills',
    );

    // Inject disabled status at the native boundary without changing the OS
    // privacy setting. OS denial/revocation on the phone remains a manual item.
    await _fixture('deny');
    await create(
      'Synthetic denied I3',
      base.subtract(const Duration(minutes: 25)),
    );
    await coordinator.refresh().timeout(_operationTimeout);
    expect(coordinator.view.failure, ReminderFailureCode.disabledBySystem);
    expect(
      (await store.features.prepareReminderPublication()).desired,
      hasLength(66),
    );
    await _fixture('restore');
    await coordinator.refresh().timeout(const Duration(seconds: 90));
    expect(coordinator.view.failure, isNull);
    expect(await platform.pending(), hasLength(60));
    report['injectedDenialPreservesFactsAndRecovers'] = true;

    await coordinator.close();
    coordinator = null;
    platform = IOSNotifications();
    await platform.initialize();
    expect(await platform.pending(), hasLength(60));
    report['ordinaryDartClosePreservesOSQueue'] = true;
    coordinator = ReminderCoordinator(data: store.features, platform: platform);
    await coordinator.refresh().timeout(const Duration(seconds: 90));
    await coordinator.prepareForMaintenance();
    expect(await platform.pending(), isEmpty);
    await coordinator.clearForMaintenance();
    expect(await platform.pending(), isEmpty);
    report['maintenanceBlockAndOSRemovalReadback'] = true;
    debugPrint(
      'I3 phase: ordinary close preserves and maintenance clears OS queue',
    );
    return report;
  } finally {
    await navigation?.cancel();
    await coordinator?.close();
    final cleanup = IOSNotifications();
    try {
      await cleanup.blockDelivery();
      expect(await cleanup.pending(), isEmpty);
    } finally {
      await cleanup.close();
      await platform.close();
      await store.close();
      await directories.formal.release();
      await directories.demo.release();
    }
  }
}

Future<void> _fixture(String action, {String? id}) => _native
    .invokeMethod<void>('i3Fixture', {'action': action, 'id': ?id})
    .timeout(_operationTimeout);

void _expectNearest(
  ReminderPublication publication,
  List<NotificationPending> queue,
) {
  final expected = publication.desired.toList()
    ..sort((left, right) {
      final time = left.request.deliveryAtUtc.compareTo(
        right.request.deliveryAtUtc,
      );
      return time == 0 ? left.request.id.compareTo(right.request.id) : time;
    });
  expect(
    queue.map((item) => item.id).toSet(),
    expected.take(60).map((item) => item.request.id).toSet(),
  );
  for (final actual in queue) {
    expect(
      actual.matches(
        expected.firstWhere((item) => item.request.id == actual.id).request,
      ),
      isTrue,
    );
  }
}
