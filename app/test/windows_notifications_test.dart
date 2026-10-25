import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/platform/windows_notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('synthetic/ustc_assistant/notifications');
  const productionChannel = MethodChannel('ustc_assistant/notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final adapters = <WindowsNotifications>[];

  WindowsNotifications createAdapter() {
    final adapter = WindowsNotifications.forTesting(channel);
    adapters.add(adapter);
    return adapter;
  }

  tearDown(() async {
    for (final adapter in adapters.reversed) {
      await adapter.close();
    }
    adapters.clear();
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(productionChannel, null);
  });

  test('production constructor uses the fixed application channel', () async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(productionChannel, (call) async {
      calls.add(call);
      if (call.method == 'initialize') {
        return _capability(activationAvailable: false);
      }
      return null;
    });
    final adapter = WindowsNotifications();
    adapters.add(adapter);
    try {
      await adapter.initialize();
      await adapter.close();
      expect(calls.map((call) => call.method), <String>['initialize', 'close']);
      expect(calls.every((call) => call.arguments == null), isTrue);
    } finally {
      await adapter.close();
      debugDefaultTargetPlatformOverride = previousPlatform;
    }
  });

  test(
    'uses fixed protocol shapes for initialize and notification writes',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'initialize' => _capability(),
          'pending' => <Object?>[_pending()],
          'schedule' || 'cancel' || 'clear' || 'close' => null,
          _ => throw StateError('unexpected method'),
        };
      });
      final adapter = createAdapter();

      final capability = await adapter.initialize();
      expect(capability.available, isTrue);
      final pending = await adapter.pending();
      expect(pending, hasLength(1));
      expect(pending.single.title, '课程提醒');
      expect(pending.single.detail, '教学楼 A');
      expect(pending.single.location, '东区');
      await adapter.schedule(_request());
      await adapter.cancel('notice_1');
      await adapter.clearOwn();
      await adapter.close();

      expect(calls.map((call) => call.method), <String>[
        'initialize',
        'pending',
        'schedule',
        'cancel',
        'clear',
        'close',
      ]);
      expect(calls[0].arguments, isNull);
      expect(calls[1].arguments, isNull);
      expect(calls[2].arguments, <String, Object>{
        'id': 'notice_1',
        'deliveryAtUnixMs': DateTime.utc(
          2026,
          10,
          15,
          8,
        ).millisecondsSinceEpoch,
        'digest': _digest,
        'token': _token,
        'title': '课程提醒',
        'detail': '教学楼 A',
        'location': '东区',
      });
      expect((calls[2].arguments as Map).keys.toSet(), <String>{
        'id',
        'deliveryAtUnixMs',
        'digest',
        'token',
        'title',
        'detail',
        'location',
      });
      expect(calls[3].arguments, <String, Object>{'id': 'notice_1'});
      expect(calls[4].arguments, isNull);
      expect(calls[5].arguments, isNull);
    },
  );

  test(
    'rejects invalid request fields before calling the native bridge',
    () async {
      var scheduleCalls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'initialize') return _capability();
        if (call.method == 'schedule') scheduleCalls++;
        return null;
      });
      final adapter = createAdapter();
      await adapter.initialize();

      final invalidRequests = <NotificationRequest>[
        _request(id: 'id longer than sixteen'),
        _request(digest: _repeat('a', 63)),
        _request(token: 'short'),
        _request(title: ''),
        _request(title: _repeat('x', 161)),
        _request(detail: _repeat('x', 241)),
        _request(location: 'x\nroom'),
        _request(deliveryAtUtc: DateTime(2026, 10, 15, 8)),
      ];

      for (final request in invalidRequests) {
        await expectLater(
          adapter.schedule(request),
          throwsA(_failure(ReminderFailureCode.invalidInput)),
        );
      }
      await expectLater(
        adapter.cancel('bad/id'),
        throwsA(_failure(ReminderFailureCode.invalidInput)),
      );
      expect(scheduleCalls, 0);
    },
  );

  test(
    'malformed pending values fail closed instead of becoming an empty list',
    () async {
      final malformed = <Object?>[
        null,
        <Object?>[_pending(extra: true)],
        <Object?>[_pending(omitTitle: true)],
        <Object?>[_pending(id: 'bad/id')],
        <Object?>[_pending(timestamp: 1.5)],
        <Object?>[_pending(timestamp: 999999999999999999)],
        <Object?>[_pending(title: '')],
        <Object?>[_pending(title: '   ')],
        <Object?>[_pending(title: _repeat('x', 161))],
        <Object?>[_pending(title: 'bad\ntitle')],
        <Object?>[_pending(detail: _repeat('x', 241))],
        <Object?>[_pending(detail: 'bad\ndetail')],
        <Object?>[_pending(location: _repeat('x', 161))],
        <Object?>[_pending(location: 'bad\nlocation')],
        <Object?>[_pending(detail: 1)],
        List<Object?>.filled(1025, _pending()),
      ];
      Object? result;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'initialize') return _capability();
        if (call.method == 'pending') return result;
        return null;
      });
      final adapter = createAdapter();
      await adapter.initialize();

      for (final value in malformed) {
        result = value;
        await expectLater(
          adapter.pending(),
          throwsA(_failure(ReminderFailureCode.platformUnavailable)),
        );
      }
    },
  );

  test(
    'duplicate initialize and activation polling are single-flight',
    () async {
      var initializeCalls = 0;
      var activationCalls = 0;
      final heldActivationPoll = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'initialize') {
          initializeCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return _capability();
        }
        if (call.method == 'activations') {
          activationCalls++;
          return heldActivationPoll.future;
        }
        return null;
      });
      final adapter = createAdapter();
      final received = adapter.activations.first;
      final firstInitialize = adapter.initialize();
      final secondInitialize = adapter.initialize();
      await Future.wait([firstInitialize, secondInitialize]);

      await Future<void>.delayed(const Duration(milliseconds: 850));
      expect(initializeCalls, 1);
      expect(activationCalls, 1);

      heldActivationPoll.complete(<Object?>[_activation()]);
      expect(
        await received.timeout(const Duration(seconds: 1)),
        isA<NotificationActivation>(),
      );
      await adapter.close();
    },
  );

  test(
    'close drains its poll, preserves schedules, and drops late activations',
    () async {
      final calls = <String>[];
      final heldActivationPoll = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'initialize') return _capability();
        if (call.method == 'activations') return heldActivationPoll.future;
        return null;
      });
      final adapter = createAdapter();
      final events = <NotificationActivation>[];
      final subscription = adapter.activations.listen(events.add);
      await adapter.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 430));
      expect(calls.where((method) => method == 'activations'), hasLength(1));

      final closing = adapter.close();
      heldActivationPoll.complete(<Object?>[_activation()]);
      await closing;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await subscription.cancel();

      expect(events, isEmpty);
      expect(calls, contains('close'));
      expect(calls, isNot(contains('clear')));
      expect(calls, isNot(contains('cancel')));
    },
  );

  test('native failures are mapped to safe fixed codes', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'initialize') return _capability();
      if (call.method == 'schedule') {
        throw PlatformException(
          code: 'publish_failed',
          message: 'synthetic-private-marker',
          details: <String, Object>{'path': 'synthetic-private-path'},
        );
      }
      return null;
    });
    final adapter = createAdapter();
    await adapter.initialize();

    await expectLater(
      adapter.schedule(_request()),
      throwsA(
        isA<ReminderFailure>()
            .having(
              (failure) => failure.code,
              'code',
              ReminderFailureCode.publishFailed,
            )
            .having(
              (failure) => failure.toString(),
              'safe error',
              'ReminderFailure(publishFailed)',
            )
            .having(
              (failure) => failure.toString(),
              'does not expose native details',
              isNot(contains('synthetic-private-marker')),
            ),
      ),
    );
  });

  test('malformed activations become a safe failure event', () async {
    var activationCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'initialize') return _capability();
      if (call.method == 'activations') {
        activationCalls++;
        return List<Object?>.filled(33, _activation());
      }
      return null;
    });
    final adapter = createAdapter();
    final failure = adapter.activationFailures.first;
    await adapter.initialize();

    final event = await failure.timeout(const Duration(seconds: 1));
    expect(event.code, ReminderFailureCode.platformUnavailable);
    await Future<void>.delayed(const Duration(milliseconds: 430));
    expect(activationCalls, 1);
    await adapter.close();
  });

  test(
    'non-Windows initialization is unavailable without native calls',
    () async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      var nativeCalls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        nativeCalls++;
        return null;
      });
      final adapter = WindowsNotifications();
      adapters.add(adapter);
      try {
        final capability = await adapter.initialize();
        expect(capability.available, isFalse);
        expect(capability.enabledBySystem, isFalse);
        await expectLater(
          adapter.pending(),
          throwsA(_failure(ReminderFailureCode.platformUnavailable)),
        );
        await expectLater(
          adapter.schedule(_request()),
          throwsA(_failure(ReminderFailureCode.platformUnavailable)),
        );
        await expectLater(
          adapter.cancel('notice_1'),
          throwsA(_failure(ReminderFailureCode.platformUnavailable)),
        );
        await expectLater(
          adapter.clearOwn(),
          throwsA(_failure(ReminderFailureCode.platformUnavailable)),
        );
        expect(nativeCalls, 0);
      } finally {
        await adapter.close();
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    },
  );
}

const _digest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _token = 'bbbbbbbbbbbbbbbb';

Map<String, Object> _capability({
  bool available = true,
  bool enabledBySystem = true,
  bool schedulesAfterExit = true,
  bool activationAvailable = true,
}) => <String, Object>{
  'available': available,
  'enabledBySystem': enabledBySystem,
  'schedulesAfterExit': schedulesAfterExit,
  'activationAvailable': activationAvailable,
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
}) => <String, Object?>{
  'id': id,
  'deliveryAtUnixMs': timestamp,
  'digest': digest,
  'token': token,
  if (!omitTitle) 'title': title,
  'detail': detail,
  'location': location,
  if (extra) 'unexpected': 'field',
};

Map<String, Object> _activation() => <String, Object>{
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

String _repeat(String value, int count) =>
    List<String>.filled(count, value).join();

Matcher _failure(ReminderFailureCode code) =>
    isA<ReminderFailure>().having((failure) => failure.code, 'code', code);
