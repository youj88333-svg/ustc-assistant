import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/platform/android_notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channelName = 'synthetic/ustc_assistant/android_notifications';
  const channel = MethodChannel(channelName);
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final adapters = <AndroidNotifications>[];

  AndroidNotifications createAdapter() {
    final adapter = AndroidNotifications.forTesting(channel);
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
    'reads the fixed capability shape and requests system access explicitly',
    () async {
      final calls = <MethodCall>[];
      Object? capabilityReply = _capability();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'initialize' ||
          'requestNotifications' ||
          'requestExactAlarms' => capabilityReply,
          'takeActivations' || 'openSystemSettings' => null,
          _ => throw StateError('unexpected method'),
        };
      });
      final adapter = createAdapter();

      final capability = await adapter.initialize();
      expect(capability.available, isTrue);
      expect(capability.enabledBySystem, isFalse);
      expect(capability.exactScheduling, isFalse);
      expect(
        capability.queueEvidence,
        NotificationQueueEvidence.localRegistration,
      );
      expect(capability.maximumPending, 480);
      expect(
        calls.where(
          (call) =>
              call.method == 'requestNotifications' ||
              call.method == 'requestExactAlarms' ||
              call.method == 'openSystemSettings',
        ),
        isEmpty,
      );

      await adapter.requestNotifications();
      await adapter.requestExactAlarms();
      await adapter.openSystemSettings();
      expect(
        calls
            .map((call) => call.method)
            .where(
              (method) =>
                  method == 'requestNotifications' ||
                  method == 'requestExactAlarms' ||
                  method == 'openSystemSettings',
            ),
        ['requestNotifications', 'requestExactAlarms', 'openSystemSettings'],
      );
      expect(
        calls.where((call) => call.method == 'initialize').single.arguments,
        isNull,
      );

      capabilityReply = _capability()..remove('queueEvidence');
      await expectLater(
        adapter.initialize(),
        _failure(ReminderFailureCode.invalidInput),
      );
      capabilityReply = {..._capability(), 'unexpected': true};
      await expectLater(
        adapter.initialize(),
        _failure(ReminderFailureCode.invalidInput),
      );
      await adapter.close();
    },
  );

  test(
    'pending uses the strict seven-key shape and rejects duplicate ids',
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

      final pending = await adapter.pending();
      expect(pending, hasLength(2));
      expect(pending.first.id, 'notice_1');
      expect(pending.first.title, '课程提醒');
      expect(pending.first.deliveryAtUtc.isUtc, isTrue);
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
      pendingReply = <Object?>[_pending(extra: true)];
      await expectLater(
        adapter.pending(),
        _failure(ReminderFailureCode.invalidInput),
      );
      pendingReply = <Object?>[_pending(omitTitle: true)];
      await expectLater(
        adapter.pending(),
        _failure(ReminderFailureCode.invalidInput),
      );
      await adapter.close();
    },
  );

  test(
    'C3 publication binds valid prior and desired identities only',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'bindPublication') return null;
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
          desired: [_mapping('desired_1')],
          prior: [_mapping('prior_keep'), _mapping('prior_invalid')],
          invalidPriorIds: ['prior_invalid'],
        ),
      );
      final enabledArgs =
          calls
                  .singleWhere((call) => call.method == 'bindPublication')
                  .arguments
              as Map;
      expect(enabledArgs.keys.toSet(), {'authority', 'allowed'});
      expect((enabledArgs['authority'] as Map), {
        'owner': 'synthetic-owner',
        'resetEpoch': 3,
        'agendaEpoch': 5,
        'revision': 9,
        'enabled': true,
      });
      final allowed = enabledArgs['allowed'] as List;
      expect(allowed.map((item) => (item as Map)['id']).toSet(), {
        'prior_keep',
        'desired_1',
      });
      expect((allowed.first as Map).keys.toSet(), {
        'id',
        'deliveryAtUnixMs',
        'digest',
        'token',
      });

      await adapter.bindPublication(
        _publication(
          enabled: false,
          desired: [_mapping('disabled_current')],
          prior: [_mapping('disabled_prior')],
        ),
      );
      final disabledArgs =
          calls.where((call) => call.method == 'bindPublication').last.arguments
              as Map;
      expect((disabledArgs['authority'] as Map)['enabled'], isFalse);
      expect(disabledArgs['allowed'], isEmpty);
      await adapter.close();
    },
  );

  test(
    'cold activation is not consumed before initialization and a listener',
    () async {
      var drained = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'initialize') return _capability();
        if (call.method == 'takeActivations') {
          drained++;
          return [_activation()];
        }
        return null;
      });
      final adapter = createAdapter();
      await signalActivation();
      await adapter.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(drained, 0);
      final delivered = adapter.activations.first;
      expect(
        (await delivered.timeout(const Duration(seconds: 1))).id,
        'notice_1',
      );
      expect(drained, 1);
      await adapter.close();
    },
  );

  test(
    'activation records require three keys, deduplicate, and fail closed',
    () async {
      final started = List.generate(4, (_) => Completer<void>());
      final replies = List.generate(4, (_) => Completer<Object?>());
      var pollCount = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'initialize') return _capability();
        if (call.method == 'takeActivations') {
          final index = pollCount++;
          started[index].complete();
          return replies[index].future;
        }
        return null;
      });
      final adapter = createAdapter();
      final events = <NotificationActivation>[];
      final subscription = adapter.activations.listen(events.add);
      final firstEvent = adapter.activations.first;
      final firstFailure = adapter.activationFailures.first;
      await adapter.initialize();

      await started[0].future;
      await signalActivation();
      replies[0].complete(<Object?>[]);
      await started[1].future;
      replies[1].complete(<Object?>[_activation()]);
      final received = await firstEvent.timeout(const Duration(seconds: 1));
      expect(received.id, 'notice_1');
      expect(events, hasLength(1));

      await signalActivation();
      await started[2].future;
      await signalActivation();
      replies[2].complete(<Object?>[_activation()]);
      await started[3].future;
      replies[3].complete(<Object?>[_activation(extra: true)]);
      final failure = await firstFailure.timeout(const Duration(seconds: 1));
      expect(failure.code, ReminderFailureCode.invalidInput);
      expect(events, hasLength(1));

      await subscription.cancel();
      await adapter.close();
    },
  );

  test(
    'ordinary close does not clear or block registered notifications',
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
      await adapter.close();

      expect(methods, isNot(contains('clear')));
      expect(methods, isNot(contains('blockDelivery')));
    },
  );

  test(
    'a queued request that times out can never mutate after its predecessor drains',
    () async {
      final held = Completer<Object?>();
      final entered = Completer<void>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'pending') {
          entered.complete();
          return held.future;
        }
        return null;
      });
      final adapter = createAdapter();
      final first = expectLater(
        adapter.pending(),
        _failure(ReminderFailureCode.platformUnavailable),
      );
      await entered.future;
      final queued = expectLater(
        adapter.schedule(_request()),
        _failure(ReminderFailureCode.platformUnavailable),
      );
      await first;
      await queued;
      held.complete(<Object?>[]);
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['pending']);
      await adapter.close();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'late method results serialize writes and activation drains',
    () async {
      final calls = <String>[];
      final pendingStarted = Completer<void>();
      final pendingReply = Completer<Object?>();
      final scheduleStarted = Completer<void>();
      final scheduleReply = Completer<Object?>();
      final drainStarted = List.generate(2, (_) => Completer<void>());
      var drainCount = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return switch (call.method) {
          'initialize' => _capability(),
          'pending' => _hold(pendingStarted, pendingReply),
          'schedule' => _hold(scheduleStarted, scheduleReply),
          'takeActivations' => _emptyDrain(drainStarted, () => drainCount++),
          _ => null,
        };
      });
      final adapter = createAdapter();
      final activationSubscription = adapter.activations.listen((_) {});
      await adapter.initialize();
      await drainStarted[0].future;

      final firstPending = adapter.pending();
      final timedOut = expectLater(
        firstPending,
        _failure(ReminderFailureCode.platformUnavailable),
      );
      await pendingStarted.future;
      final laterSchedule = adapter.schedule(_request(id: 'later_1'));
      await signalActivation();
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((method) => method == 'schedule'), isEmpty);
      expect(drainCount, 1);

      await timedOut;
      expect(calls.where((method) => method == 'schedule'), isEmpty);
      expect(drainCount, 1);

      pendingReply.complete(<Object?>[]);
      await scheduleStarted.future.timeout(const Duration(seconds: 1));
      expect(drainCount, 1);
      scheduleReply.complete(null);
      await laterSchedule;
      await drainStarted[1].future.timeout(const Duration(seconds: 1));
      expect(calls.indexOf('pending'), lessThan(calls.indexOf('schedule')));
      expect(
        calls.indexOf('schedule'),
        lessThan(calls.lastIndexOf('takeActivations')),
      );

      await activationSubscription.cancel();
      await adapter.close();
      expect(calls, isNot(contains('clear')));
      expect(calls, isNot(contains('blockDelivery')));
    },
    timeout: const Timeout(Duration(seconds: 25)),
  );
}

Future<Object?> _hold(Completer<void> started, Completer<Object?> reply) {
  started.complete();
  return reply.future;
}

Future<Object?> _emptyDrain(
  List<Completer<void>> started,
  void Function() onCall,
) {
  onCall();
  final index = started.indexWhere((item) => !item.isCompleted);
  if (index >= 0) started[index].complete();
  return Future<Object?>.value(<Object?>[]);
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

Map<String, Object> _capability({
  bool available = true,
  bool enabledBySystem = false,
  bool schedulesAfterExit = true,
  bool activationAvailable = true,
  bool exactScheduling = false,
  int maximumPending = 480,
  int deliveryFailures = 0,
}) => {
  'available': available,
  'enabledBySystem': enabledBySystem,
  'schedulesAfterExit': schedulesAfterExit,
  'activationAvailable': activationAvailable,
  'exactScheduling': exactScheduling,
  'queueEvidence': 'localRegistration',
  'maximumPending': maximumPending,
  'deliveryFailures': deliveryFailures,
};

Map<String, Object?> _pending({
  String id = 'notice_1',
  Object timestamp = 1792051200000,
  String digest = _digest,
  String token = _token,
  Object? title = '课程提醒',
  Object? detail = '教学楼 A',
  Object? location = '东区',
  bool omitTitle = false,
  bool extra = false,
}) => {
  'id': id,
  'deliveryAtUnixMs': timestamp,
  'digest': digest,
  'token': token,
  if (!omitTitle) 'title': title,
  'detail': detail,
  'location': location,
  if (extra) 'unexpected': 'field',
};

Map<String, Object?> _activation({bool extra = false}) => {
  'id': 'notice_1',
  'digest': _digest,
  'token': _token,
  if (extra) 'unexpected': 'field',
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
