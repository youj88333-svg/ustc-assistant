import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/jobs/reminder_coordinator.dart';

const _context = CalendarContext(
  owner: 'synthetic-owner',
  resetEpoch: 3,
  agendaEpoch: 7,
);
const _target = ReminderTarget(_context, ReminderKind.personal, 18, 0, 4);
const _digest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _token = 'bbbbbbbbbbbbbbbb';

void main() {
  test(
    'explicit test notification needs opt-in and contains no business fields',
    () async {
      final data = _FakeReminderData(
        publication: _publication(desired: const []),
      );
      final platform = _FakeNotifications();
      final coordinator = ReminderCoordinator(data: data, platform: platform);
      await coordinator.testNotification();
      expect(platform.pendingItems.single.id, 'm6-check');
      expect(platform.pendingItems.single.title, 'USTC Assistant 测试提醒');
      expect(platform.pendingItems.single.location, isEmpty);
      data.publications[0] = _publication(desired: const [], enabled: false);
      await expectLater(
        coordinator.testNotification(),
        throwsA(_failure(ReminderFailureCode.disabledBySystem)),
      );
      expect(platform.scheduleCalls, 1);
      await coordinator.close();
      expect(platform.clearCalls, 0);
      await data._changes.close();
    },
  );
  test('unavailable native platform is an honest failure', () async {
    final data = _FakeReminderData(
      publication: _publication(desired: [_mapping(_request())]),
    );
    final platform = _FakeNotifications(
      capability: const NotificationCapability(
        available: false,
        enabledBySystem: false,
        schedulesAfterExit: false,
        activationAvailable: false,
      ),
    );
    final coordinator = ReminderCoordinator(data: data, platform: platform);
    await coordinator.refresh();
    expect(coordinator.view.failure, ReminderFailureCode.platformUnavailable);
    expect(platform.scheduleCalls, 0);
    await coordinator.close();
    await data._changes.close();
  });
  test(
    'OS success with lost C3 acknowledgement replays from complete readback',
    () async {
      final request = _request();
      final publication = _publication(desired: [_mapping(request)]);
      final data = _FakeReminderData(publication: publication)
        ..ackFailuresRemaining = 1;
      final platform = _FakeNotifications();
      final coordinator = ReminderCoordinator(data: data, platform: platform);

      await coordinator.refresh();
      expect(platform.scheduleCalls, 1);
      expect(data.acceptedIds, isEmpty);
      expect(coordinator.view.failure, ReminderFailureCode.storageFailed);

      await coordinator.refresh();
      expect(platform.scheduleCalls, 1);
      expect(data.acceptedIds, ['notice_18_0']);
      expect(coordinator.view.accepted, 1);
      expect(coordinator.view.complete, isTrue);
      await coordinator.close();
    },
  );

  test('refresh rechecks current system capability', () async {
    final request = _request();
    final data = _FakeReminderData(
      publication: _publication(desired: [_mapping(request)]),
    );
    final platform = _FakeNotifications();
    final coordinator = ReminderCoordinator(data: data, platform: platform);

    await coordinator.refresh();
    platform.capability = const NotificationCapability(
      available: true,
      enabledBySystem: false,
      schedulesAfterExit: true,
      activationAvailable: true,
    );
    await coordinator.refresh();

    expect(platform.initializeCalls, 2);
    expect(platform.scheduleCalls, 1);
    expect(coordinator.view.capability?.enabledBySystem, isFalse);
    await coordinator.close();
  });

  test(
    'readback must include all notification content before C3 accepts it',
    () async {
      final request = _request();
      final data = _FakeReminderData(
        publication: _publication(desired: [_mapping(request)]),
      );
      final platform = _FakeNotifications()..omitReadbackDetail = true;
      final coordinator = ReminderCoordinator(data: data, platform: platform);

      await coordinator.refresh();

      expect(platform.scheduleCalls, 1);
      expect(data.acceptedIds, isEmpty);
      expect(coordinator.view.failure, ReminderFailureCode.publishFailed);
      await coordinator.close();
    },
  );

  test(
    'a changed schedule is canceled before the replacement is published',
    () async {
      final oldRequest = _request(
        deliveryAtUtc: DateTime.utc(2026, 10, 15, 9),
        title: 'synthetic old title',
      );
      final newRequest = _request(
        deliveryAtUtc: DateTime.utc(2026, 10, 15, 10),
        title: 'synthetic new title',
      );
      final data = _FakeReminderData(
        publication: _publication(
          desired: [_mapping(newRequest)],
          prior: [_mapping(oldRequest, accepted: true)],
        ),
      );
      final platform = _FakeNotifications()
        ..pendingItems.add(_pending(oldRequest));
      final coordinator = ReminderCoordinator(data: data, platform: platform);

      await coordinator.refresh();

      expect(
        platform.calls.indexOf('cancel:${oldRequest.id}'),
        greaterThanOrEqualTo(0),
      );
      expect(
        platform.calls.indexOf('cancel:${oldRequest.id}'),
        lessThan(platform.calls.indexOf('schedule:${newRequest.id}')),
      );
      expect(data.cancelledIds, [oldRequest.id]);
      expect(data.acceptedIds, [newRequest.id]);
      expect(platform.pendingItems.single.title, 'synthetic new title');
      await coordinator.close();
    },
  );

  test(
    'a version invalidated during publication is compensated and not accepted',
    () async {
      final staleRequest = _request(id: 'stale_notice');
      final stalePublication = _publication(desired: [_mapping(staleRequest)]);
      final nextPublication = _publication(desired: []);
      final data = _FakeReminderData(
        publication: stalePublication,
        nextPublication: nextPublication,
      )..invalidateAfterThreeChecks = stalePublication;
      final platform = _FakeNotifications();
      final coordinator = ReminderCoordinator(data: data, platform: platform);

      await coordinator.refresh();

      expect(platform.calls, contains('schedule:${staleRequest.id}'));
      expect(platform.calls, contains('cancel:${staleRequest.id}'));
      expect(platform.pendingItems, isEmpty);
      expect(data.acceptedIds, isEmpty);
      expect(data.cancelledIds, [staleRequest.id]);
      await coordinator.close();
    },
  );

  test(
    'system-disabled publishing is rejected with a stable failure',
    () async {
      final request = _request();
      final data = _FakeReminderData(
        publication: _publication(desired: [_mapping(request)]),
      );
      final platform = _FakeNotifications()
        ..capability = const NotificationCapability(
          available: true,
          enabledBySystem: false,
          schedulesAfterExit: true,
          activationAvailable: true,
        );
      final coordinator = ReminderCoordinator(data: data, platform: platform);

      await coordinator.refresh();

      expect(platform.scheduleCalls, 0);
      expect(coordinator.view.failure, ReminderFailureCode.disabledBySystem);
      await coordinator.close();
    },
  );

  test(
    'failed maintenance cleanup remains pending and can be retried',
    () async {
      final request = _request();
      final data = _FakeReminderData(
        publication: _publication(
          enabled: false,
          prior: [_mapping(request, accepted: true)],
        ),
      );
      final platform = _FakeNotifications()
        ..pendingItems.add(_pending(request))
        ..retainOnClear = true;
      final coordinator = ReminderCoordinator(data: data, platform: platform);

      await expectLater(
        coordinator.clearForMaintenance(),
        throwsA(_failure(ReminderFailureCode.cleanupPending)),
      );
      expect(platform.pendingItems, hasLength(1));
      expect(coordinator.view.complete, isFalse);

      platform.retainOnClear = false;
      await coordinator.clearForMaintenance();
      expect(platform.pendingItems, isEmpty);
      expect(platform.clearCalls, 2);
      expect(coordinator.view.complete, isTrue);
      await coordinator.close();
    },
  );

  test('normal close preserves OS schedules and never clears them', () async {
    final request = _request();
    final platform = _FakeNotifications()..pendingItems.add(_pending(request));
    final coordinator = ReminderCoordinator(
      data: _FakeReminderData(publication: _publication(desired: [])),
      platform: platform,
    );

    await coordinator.close();

    expect(platform.pendingItems, hasLength(1));
    expect(platform.clearCalls, 0);
    expect(platform.cancelCalls, 0);
    expect(platform.closeCalls, 1);
  });

  test(
    'normal close waits for an in-flight publish without compensating cancel',
    () async {
      final request = _request();
      final platform = _FakeNotifications()
        ..scheduleStarted = Completer<void>()
        ..scheduleGate = Completer<void>();
      final data = _FakeReminderData(
        publication: _publication(desired: [_mapping(request)]),
      );
      final coordinator = ReminderCoordinator(data: data, platform: platform);

      final refreshing = coordinator.refresh();
      await platform.scheduleStarted!.future;
      final closing = coordinator.close();
      platform.scheduleGate!.complete();
      await Future.wait<void>([refreshing, closing]);

      expect(platform.pendingItems.single.id, request.id);
      expect(platform.cancelCalls, 0);
      expect(data.acceptedIds, [request.id]);
      expect(platform.closeCalls, 1);
    },
  );

  test(
    'maintenance skips native registration when cleanup is not required',
    () async {
      final platform = _FakeNotifications();
      final data = _FakeReminderData(publication: _publication(enabled: false));
      final coordinator = ReminderCoordinator(data: data, platform: platform);

      await coordinator.clearForMaintenance(nativeCleanupRequired: false);

      expect(platform.initializeCalls, 0);
      expect(platform.clearCalls, 0);
      expect(coordinator.view.complete, isTrue);
      await coordinator.close();
    },
  );

  test('forged and stale-context activations do not navigate', () async {
    const currentContext = CalendarContext(
      owner: 'synthetic-owner',
      resetEpoch: 4,
      agendaEpoch: 7,
    );
    const currentTarget = ReminderTarget(
      currentContext,
      ReminderKind.personal,
      18,
      0,
      5,
    );
    final forged = NotificationActivation(
      'notice_18_0',
      _digest,
      'wrong_token_000',
    );
    final staleContextActivation = NotificationActivation(
      'stale_notice',
      _digest,
      _token,
    );
    final valid = NotificationActivation('notice_18_0', _digest, _token);
    final data =
        _FakeReminderData(
            publication: _publication(desired: [], context: currentContext),
            currentContext: currentContext,
          )
          ..activationTargets['stale_notice|$_digest|$_token'] = _target
          ..activationTargets['notice_18_0|$_digest|$_token'] = currentTarget;
    final platform = _FakeNotifications();
    final coordinator = ReminderCoordinator(data: data, platform: platform);
    final navigated = <ReminderTarget>[];
    final navigation = coordinator.navigation.listen(navigated.add);
    coordinator.start();

    platform.emit(forged);
    platform.emit(staleContextActivation);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(navigated, isEmpty);

    final arrived = coordinator.navigation.first;
    platform.emit(valid);
    expect(await arrived.timeout(const Duration(seconds: 1)), currentTarget);
    expect(navigated, [currentTarget]);
    await navigation.cancel();
    await coordinator.close();
  });
}

NotificationRequest _request({
  String id = 'notice_18_0',
  DateTime? deliveryAtUtc,
  String digest = _digest,
  String token = _token,
  String title = 'synthetic reminder title',
  String detail = 'synthetic reminder detail',
  String location = 'synthetic location',
}) => NotificationRequest(
  id: id,
  deliveryAtUtc: deliveryAtUtc ?? DateTime.utc(2026, 10, 15, 9),
  digest: digest,
  token: token,
  title: title,
  detail: detail,
  location: location,
);

NotificationPending _pending(NotificationRequest request) =>
    NotificationPending(
      id: request.id,
      deliveryAtUtc: request.deliveryAtUtc,
      digest: request.digest,
      token: request.token,
      title: request.title,
      detail: request.detail,
      location: request.location,
    );

ReminderMapping _mapping(
  NotificationRequest request, {
  ReminderTarget target = _target,
  bool accepted = false,
}) => ReminderMapping(
  logicalKey: 'synthetic-logical-key',
  target: target,
  slot: 0,
  request: request,
  accepted: accepted,
);

ReminderPublication _publication({
  CalendarContext context = _context,
  bool enabled = true,
  List<ReminderMapping> desired = const [],
  List<ReminderMapping> prior = const [],
  List<String> invalidPriorIds = const [],
}) => ReminderPublication(
  context: context,
  revision: 20,
  enabled: enabled,
  desired: desired,
  prior: prior,
  invalidPriorIds: invalidPriorIds,
  complete: true,
  throughDay: DateTime.utc(2026, 10, 15),
);

Matcher _failure(ReminderFailureCode code) =>
    isA<ReminderFailure>().having((failure) => failure.code, 'code', code);

final class _FakeReminderData implements ReminderDataPort {
  _FakeReminderData({
    required ReminderPublication publication,
    ReminderPublication? nextPublication,
    this.currentContext = _context,
  }) : publications = [publication] {
    if (nextPublication != null) publications.add(nextPublication);
  }

  final StreamController<int> _changes = StreamController<int>.broadcast();
  final List<ReminderPublication> publications;
  final CalendarContext currentContext;
  final List<String> acceptedIds = [];
  final List<String> cancelledIds = [];
  final Map<String, ReminderTarget?> activationTargets = {};

  int ackFailuresRemaining = 0;
  int _prepareCount = 0;
  int _staleCheckCount = 0;
  ReminderPublication? invalidateAfterThreeChecks;

  @override
  Stream<int> get changes => _changes.stream;

  @override
  Future<ReminderSettings> inspectReminders() async {
    final publication = publications.first;
    return ReminderSettings(
      context: publication.context,
      revision: publication.revision,
      briefEpoch: publication.context.resetEpoch,
      preferences: ReminderPreferences(enabled: publication.enabled),
    );
  }

  @override
  Future<ReminderPublication> prepareReminderPublication() async {
    final index = _prepareCount++;
    return publications[index < publications.length
        ? index
        : publications.length - 1];
  }

  @override
  Future<bool> reminderPublicationCurrent(
    ReminderPublication publication,
  ) async {
    if (identical(publication, invalidateAfterThreeChecks)) {
      _staleCheckCount++;
      return _staleCheckCount < 3;
    }
    return true;
  }

  @override
  Future<void> recordReminderAccepted(
    ReminderPublication publication,
    String id,
  ) async {
    if (ackFailuresRemaining > 0) {
      ackFailuresRemaining--;
      throw const ReminderFailure(ReminderFailureCode.storageFailed);
    }
    acceptedIds.add(id);
  }

  @override
  Future<void> recordReminderCancelled(String id) async {
    cancelledIds.add(id);
  }

  @override
  Future<ReminderTarget?> resolveNotification(
    NotificationActivation activation,
  ) async {
    final key = '${activation.id}|${activation.digest}|${activation.token}';
    final target = activationTargets[key];
    return target?.context == currentContext ? target : null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected ReminderDataPort call');
}

final class _FakeNotifications implements NotificationPlatformPort {
  _FakeNotifications({
    this.capability = const NotificationCapability(
      available: true,
      enabledBySystem: true,
      schedulesAfterExit: true,
      activationAvailable: true,
    ),
  });

  final StreamController<NotificationActivation> _activations =
      StreamController<NotificationActivation>.broadcast();
  final List<NotificationPending> pendingItems = [];
  final List<String> calls = [];
  NotificationCapability capability;
  Completer<void>? scheduleGate, scheduleStarted;
  int scheduleCalls = 0, cancelCalls = 0, clearCalls = 0, closeCalls = 0;
  int initializeCalls = 0;
  bool omitReadbackDetail = false, retainOnClear = false;

  @override
  Stream<NotificationActivation> get activations => _activations.stream;

  @override
  Future<NotificationCapability> initialize() async {
    initializeCalls++;
    return capability;
  }

  @override
  Future<List<NotificationPending>> pending() async => pendingItems.map((item) {
    if (!omitReadbackDetail) return item;
    return NotificationPending(
      id: item.id,
      deliveryAtUtc: item.deliveryAtUtc,
      digest: item.digest,
      token: item.token,
      title: item.title,
      detail: null,
      location: item.location,
    );
  }).toList();

  @override
  Future<void> schedule(NotificationRequest request) async {
    scheduleCalls++;
    calls.add('schedule:${request.id}');
    final started = scheduleStarted;
    if (started != null && !started.isCompleted) started.complete();
    final gate = scheduleGate;
    if (gate != null) await gate.future;
    pendingItems.removeWhere((item) => item.id == request.id);
    pendingItems.add(_pending(request));
  }

  @override
  Future<void> cancel(String id) async {
    cancelCalls++;
    calls.add('cancel:$id');
    pendingItems.removeWhere((item) => item.id == id);
  }

  @override
  Future<void> clearOwn() async {
    clearCalls++;
    calls.add('clear');
    if (!retainOnClear) pendingItems.clear();
  }

  void emit(NotificationActivation activation) => _activations.add(activation);

  @override
  Future<void> close() async {
    closeCalls++;
    calls.add('close');
    await _activations.close();
  }
}
