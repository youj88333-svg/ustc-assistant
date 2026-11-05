import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/platform/ios_notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channelName = 'ustc_assistant/ios_notifications_v1';
  const channel = MethodChannel(channelName);
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final adapters = <IOSNotifications>[];

  IOSNotifications createAdapter({
    Duration callTimeout = const Duration(seconds: 8),
    Duration startTimeout = const Duration(seconds: 16),
  }) {
    final adapter = IOSNotifications.forTesting(
      channel,
      callTimeout: callTimeout,
      startTimeout: startTimeout,
    );
    adapters.add(adapter);
    return adapter;
  }

  tearDown(() async {
    for (final adapter in adapters.reversed) {
      await adapter.close();
    }
    adapters.clear();
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> signalActivation() async {
    await messenger.handlePlatformMessage(
      channelName,
      codec.encodeMethodCall(const MethodCall('activationsChanged')),
      (_) {},
    );
  }

  test(
    'strict capability has twelve fields and consent stays explicit',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'initialize' ||
          'requestNotifications' ||
          'requestExactAlarms' => _capability(
            authorizationStatus: 'provisional',
            scheduledSummaryEnabled: null,
          ),
          'takeActivations' || 'openSystemSettings' => null,
          _ => throw StateError('unexpected method'),
        };
      });
      final adapter = createAdapter();

      final capability = await adapter.initialize();
      expect(
        capability.authorizationStatus,
        NotificationAuthorizationStatus.provisional,
      );
      expect(capability.exactScheduling, isNull);
      expect(
        capability.queueEvidence,
        NotificationQueueEvidence.operatingSystem,
      );
      expect(capability.maximumPending, 60);
      expect(capability.scheduledSummaryEnabled, isNull);
      expect(_capability().keys, hasLength(12));
      expect(
        calls.map((call) => call.method),
        ['initialize'],
        reason: 'initialize must only read authorization state',
      );
      expect(calls.single.arguments, isNull);

      await adapter.requestNotifications();
      await adapter.requestExactAlarms();
      await adapter.openSystemSettings();
      expect(calls.map((call) => call.method), [
        'initialize',
        'requestNotifications',
        'requestExactAlarms',
        'openSystemSettings',
      ]);
      expect(
        (await adapter.requestExactAlarms()).exactScheduling,
        isNull,
        reason: 'iOS has no exact-alarm permission surface',
      );
      await adapter.close();
    },
  );

  test(
    'capability rejects open enums, wrong fixed values, and fake nullables',
    () async {
      Object? response = _capability();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'initialize') return response;
        if (call.method == 'takeActivations') return <Object?>[];
        return null;
      });
      final adapter = createAdapter();

      expect(
        (await adapter.initialize()).authorizationStatus,
        NotificationAuthorizationStatus.notDetermined,
      );
      response = _capability(authorizationStatus: 'futureUnknownValue');
      await expectLater(
        adapter.initialize(),
        _failure(ReminderFailureCode.invalidInput),
      );
      response = _capability(exactScheduling: false);
      await expectLater(
        adapter.initialize(),
        _failure(ReminderFailureCode.invalidInput),
      );
      response = _capability(maximumPending: 59);
      await expectLater(
        adapter.initialize(),
        _failure(ReminderFailureCode.invalidInput),
      );
      response = _capability(alertsEnabled: 1);
      await expectLater(
        adapter.initialize(),
        _failure(ReminderFailureCode.invalidInput),
      );
      response = {..._capability(), 'deliveryFailures': 0};
      await expectLater(
        adapter.initialize(),
        _failure(ReminderFailureCode.invalidInput),
      );
      await adapter.close();
    },
  );

  test(
    'pending strictly validates native records and unique opaque ids',
    () async {
      Object? pendingReply = <Object?>[_pending(), _pending(id: 'notice_2')];
      messenger.setMockMethodCallHandler(channel, (call) async {
        return switch (call.method) {
          'initialize' => _capability(),
          'takeActivations' => <Object?>[],
          'pending' => pendingReply,
          _ => null,
        };
      });
      final adapter = createAdapter();
      await adapter.initialize();

      final actual = await adapter.pending();
      expect(actual, hasLength(2));
      expect(actual.first.deliveryAtUtc.isUtc, isTrue);
      expect(actual.first.title, '课程提醒');
      expect(actual.first.location, '东区');
      expect(_pending().keys.toSet(), {
        'id',
        'deliveryAtUnixMs',
        'digest',
        'token',
        'title',
        'detail',
        'location',
      });

      pendingReply = <Object?>[_pending(), _pending(id: 'notice_1')];
      await expectLater(
        adapter.pending(),
        _failure(ReminderFailureCode.invalidInput),
      );
      pendingReply = <Object?>[_pending(id: 'https://example.invalid/item')];
      await expectLater(
        adapter.pending(),
        _failure(ReminderFailureCode.invalidInput),
      );
      pendingReply = <Object?>[_pending(timestamp: 1.5)];
      await expectLater(
        adapter.pending(),
        _failure(ReminderFailureCode.invalidInput),
      );
      pendingReply = <Object?>[_pending(title: 17)];
      await expectLater(
        adapter.pending(),
        _failure(ReminderFailureCode.invalidInput),
      );
      pendingReply = <Object?>[_pending(extra: true)];
      await expectLater(
        adapter.pending(),
        _failure(ReminderFailureCode.invalidInput),
      );
      await adapter.close();
    },
  );

  test(
    'schedule reconstructs the seven-field wire object and rejects bad input',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'initialize' => _capability(),
          'takeActivations' => <Object?>[],
          _ => null,
        };
      });
      final adapter = createAdapter();
      await adapter.initialize();
      await adapter.schedule(_request());

      final args =
          calls.singleWhere((call) => call.method == 'schedule').arguments
              as Map;
      expect(args.keys.toSet(), {
        'id',
        'deliveryAtUnixMs',
        'digest',
        'token',
        'title',
        'detail',
        'location',
      });
      expect(args['deliveryAtUnixMs'], isA<int>());
      expect(args['title'], '课程提醒');
      await expectLater(
        adapter.schedule(_request(id: 'https://example.invalid')),
        _failure(ReminderFailureCode.invalidInput),
      );
      await expectLater(
        adapter.schedule(_request(title: '提醒\u0000伪造')),
        _failure(ReminderFailureCode.invalidInput),
      );
      await adapter.close();
    },
  );

  test(
    'publication binds deduplicated current identities and excludes invalid prior',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'initialize' => _capability(),
          'takeActivations' => <Object?>[],
          _ => null,
        };
      });
      final adapter = createAdapter();
      await adapter.initialize();
      await adapter.bindPublication(
        _publication(
          enabled: true,
          prior: [_mapping('prior_keep'), _mapping('prior_invalid')],
          desired: [_mapping('prior_keep'), _mapping('current_1')],
          invalidPriorIds: ['prior_invalid'],
        ),
      );

      final args =
          calls
                  .singleWhere((call) => call.method == 'bindPublication')
                  .arguments
              as Map;
      expect(args.keys.toSet(), {'authority', 'allowed'});
      expect(args['authority'], {
        'owner': 'synthetic-owner',
        'resetEpoch': 3,
        'agendaEpoch': 5,
        'revision': 9,
        'enabled': true,
      });
      final allowed = args['allowed'] as List;
      expect(allowed.map((item) => (item as Map)['id']).toSet(), {
        'prior_keep',
        'current_1',
      });
      expect(allowed, hasLength(2));
      expect((allowed.first as Map).keys.toSet(), {
        'id',
        'deliveryAtUnixMs',
        'digest',
        'token',
      });
      await adapter.close();
    },
  );

  test(
    'cold activation waits for a listener, retains late delivery, and deduplicates',
    () async {
      var takeCount = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'initialize') return _capability();
        if (call.method == 'takeActivations') {
          takeCount++;
          return <Object?>[_activation(), _activation()];
        }
        return null;
      });
      final adapter = createAdapter();
      await signalActivation();
      await adapter.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(takeCount, 0);

      final events = <NotificationActivation>[];
      final delivered = Completer<void>();
      final subscription = adapter.activations.listen((activation) {
        events.add(activation);
        if (!delivered.isCompleted) delivered.complete();
      });
      await delivered.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      expect(takeCount, 1);
      expect(events, hasLength(1));
      expect(events.single.id, 'notice_1');

      await subscription.cancel();
      await adapter.close();
    },
  );

  test(
    'activation received during a disappearing listener remains queued',
    () async {
      final started = Completer<void>();
      final reply = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'initialize') return _capability();
        if (call.method == 'takeActivations') {
          started.complete();
          return reply.future;
        }
        return null;
      });
      final adapter = createAdapter();
      final subscription = adapter.activations.listen((_) {});
      await adapter.initialize();
      await started.future;
      await subscription.cancel();
      reply.complete(<Object?>[_activation()]);
      await Future<void>.delayed(Duration.zero);

      final received = adapter.activations.first;
      expect(
        (await received.timeout(const Duration(seconds: 1))).id,
        'notice_1',
      );
      await adapter.close();
    },
  );

  test(
    'a permission reread alone does not authorize activation consumption',
    () async {
      var takeCount = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'initialize' ||
            call.method == 'requestNotifications') {
          return _capability();
        }
        if (call.method == 'takeActivations') {
          takeCount++;
          return <Object?>[_activation()];
        }
        return null;
      });
      final adapter = createAdapter();
      final delivered = adapter.activations.first;

      await adapter.requestNotifications();
      await Future<void>.delayed(Duration.zero);
      expect(takeCount, 0);
      await adapter.initialize();
      expect(
        (await delivered.timeout(const Duration(seconds: 1))).id,
        'notice_1',
      );
      expect(takeCount, 1);
      await adapter.close();
    },
  );

  test('timed out native call keeps ownership until it drains', () async {
    final pendingStarted = Completer<void>();
    final pendingReply = Completer<Object?>();
    final scheduleStarted = Completer<void>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'pending') {
        pendingStarted.complete();
        return pendingReply.future;
      }
      if (call.method == 'schedule') scheduleStarted.complete();
      return switch (call.method) {
        'initialize' => _capability(),
        'takeActivations' => <Object?>[],
        _ => null,
      };
    });
    final adapter = createAdapter(
      callTimeout: const Duration(milliseconds: 20),
      startTimeout: const Duration(milliseconds: 250),
    );
    await adapter.initialize();

    final pendingCall = expectLater(
      adapter.pending(),
      _failure(ReminderFailureCode.platformUnavailable),
    );
    await pendingStarted.future;
    final scheduleCall = adapter.schedule(_request(id: 'after_pending'));
    await pendingCall;
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(calls.where((method) => method == 'schedule'), isEmpty);

    pendingReply.complete(<Object?>[]);
    await scheduleStarted.future.timeout(const Duration(seconds: 1));
    await scheduleCall;
    expect(calls.indexOf('pending'), lessThan(calls.indexOf('schedule')));
    await adapter.close();
  });

  test(
    'late take result after timeout is buffered once and keeps call ownership',
    () async {
      final takeStarted = Completer<void>();
      final takeReply = Completer<Object?>();
      final pendingStarted = Completer<void>();
      final calls = <String>[];
      var nativeInFlight = 0;
      var maximumNativeInFlight = 0;

      Future<Object?> track(Future<Object?> response) {
        nativeInFlight++;
        if (nativeInFlight > maximumNativeInFlight) {
          maximumNativeInFlight = nativeInFlight;
        }
        return response.whenComplete(() => nativeInFlight--);
      }

      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'initialize') return _capability();
        if (call.method == 'takeActivations') {
          takeStarted.complete();
          return track(takeReply.future);
        }
        if (call.method == 'pending') {
          pendingStarted.complete();
          return track(Future<Object?>.value(<Object?>[]));
        }
        return null;
      });
      final adapter = createAdapter(
        callTimeout: const Duration(milliseconds: 25),
        startTimeout: const Duration(milliseconds: 500),
      );
      final discardedListener = adapter.activations.listen((_) {});
      final timeoutFailure = adapter.activationFailures.first;
      await adapter.initialize();
      await takeStarted.future;

      final failure = await timeoutFailure.timeout(const Duration(seconds: 1));
      expect(failure.code, ReminderFailureCode.platformUnavailable);
      await discardedListener.cancel();

      final laterCall = adapter.pending();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, ['initialize', 'takeActivations']);
      takeReply.complete(<Object?>[_activation(), _activation()]);
      await pendingStarted.future.timeout(const Duration(seconds: 1));
      await laterCall;

      expect(calls, ['initialize', 'takeActivations', 'pending']);
      expect(maximumNativeInFlight, 1);
      expect(nativeInFlight, 0);

      final lateEvents = <NotificationActivation>[];
      final listener = adapter.activations.listen(lateEvents.add);
      await Future<void>.delayed(Duration.zero);
      expect(lateEvents, hasLength(1));
      expect(lateEvents.single.id, 'notice_1');
      await listener.cancel();
      await adapter.close();
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );

  test('a queued timeout never starts a late native mutation', () async {
    final pendingStarted = Completer<void>();
    final pendingReply = Completer<Object?>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'pending') {
        pendingStarted.complete();
        return pendingReply.future;
      }
      return switch (call.method) {
        'initialize' => _capability(),
        'takeActivations' => <Object?>[],
        _ => null,
      };
    });
    final adapter = createAdapter(
      callTimeout: const Duration(milliseconds: 150),
      startTimeout: const Duration(milliseconds: 25),
    );
    await adapter.initialize();
    final pendingCall = adapter.pending();
    await pendingStarted.future;
    final queuedCall = expectLater(
      adapter.schedule(_request(id: 'expired_queued')),
      _failure(ReminderFailureCode.platformUnavailable),
    );
    await queuedCall;
    expect(calls.where((method) => method == 'schedule'), isEmpty);

    pendingReply.complete(<Object?>[]);
    await pendingCall;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, ['initialize', 'pending']);
    await adapter.close();
  });

  test(
    'ordinary close preserves OS plans and performs no native cleanup',
    () async {
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        return switch (call.method) {
          'initialize' => _capability(),
          'takeActivations' => <Object?>[],
          _ => null,
        };
      });
      final adapter = createAdapter();
      await adapter.initialize();
      await adapter.schedule(_request());
      await adapter.close();

      expect(methods, contains('schedule'));
      expect(methods, isNot(contains('clear')));
      expect(methods, isNot(contains('blockDelivery')));
      expect(methods, isNot(contains('close')));
    },
  );
}

const CalendarContext _context = CalendarContext(
  owner: 'synthetic-owner',
  resetEpoch: 3,
  agendaEpoch: 5,
);
const String _digest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _token = 'bbbbbbbbbbbbbbbb';

Map<String, Object?> _capability({
  bool available = true,
  bool enabledBySystem = true,
  bool schedulesAfterExit = true,
  bool activationAvailable = true,
  Object? exactScheduling,
  String authorizationStatus = 'notDetermined',
  Object? alertsEnabled = true,
  Object? soundsEnabled = true,
  Object? lockScreenEnabled = true,
  Object? scheduledSummaryEnabled = false,
  Object? maximumPending = 60,
  Object? queueEvidence = 'operatingSystem',
}) => {
  'available': available,
  'enabledBySystem': enabledBySystem,
  'schedulesAfterExit': schedulesAfterExit,
  'activationAvailable': activationAvailable,
  'exactScheduling': exactScheduling,
  'queueEvidence': queueEvidence,
  'maximumPending': maximumPending,
  'authorizationStatus': authorizationStatus,
  'alertsEnabled': alertsEnabled,
  'soundsEnabled': soundsEnabled,
  'lockScreenEnabled': lockScreenEnabled,
  'scheduledSummaryEnabled': scheduledSummaryEnabled,
};

Map<String, Object?> _pending({
  String id = 'notice_1',
  Object timestamp = 1792051200000,
  Object? digest = _digest,
  Object? token = _token,
  Object? title = '课程提醒',
  Object? detail = '教学楼 A',
  Object? location = '东区',
  bool extra = false,
}) => {
  'id': id,
  'deliveryAtUnixMs': timestamp,
  'digest': digest,
  'token': token,
  'title': title,
  'detail': detail,
  'location': location,
  if (extra) 'unexpected': 'field',
};

Map<String, Object?> _activation() => {
  'id': 'notice_1',
  'digest': _digest,
  'token': _token,
};

NotificationRequest _request({
  String id = 'notice_1',
  DateTime? deliveryAtUtc,
  String digest = _digest,
  String token = _token,
  String title = '课程提醒',
  String detail = '教学楼 A',
  String location = '东区',
}) => NotificationRequest(
  id: id,
  deliveryAtUtc: deliveryAtUtc ?? DateTime.utc(2026, 10, 15, 8),
  digest: digest,
  token: token,
  title: title,
  detail: detail,
  location: location,
);

ReminderMapping _mapping(String id) => ReminderMapping(
  logicalKey: 'logical_$id',
  target: const ReminderTarget(_context, ReminderKind.personal, 7, 0, 1),
  slot: 0,
  request: _request(id: id),
  accepted: true,
);

ReminderPublication _publication({
  required bool enabled,
  required List<ReminderMapping> desired,
  required List<ReminderMapping> prior,
  List<String> invalidPriorIds = const [],
}) => ReminderPublication(
  context: _context,
  revision: 9,
  enabled: enabled,
  desired: desired,
  prior: prior,
  invalidPriorIds: invalidPriorIds,
  complete: true,
  throughDay: DateTime.utc(2026, 10, 20),
);

Matcher _failure(ReminderFailureCode code) => throwsA(
  isA<ReminderFailure>().having((failure) => failure.code, 'code', code),
);
