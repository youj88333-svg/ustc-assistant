import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channelName = 'ustc_assistant/observation_v1';
  const channel = MethodChannel(channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late NativeObservationBrowser browser;
  late List<MethodCall> calls;
  Object? reply;
  PlatformException? platformFailure;

  setUp(() {
    calls = <MethodCall>[];
    reply = null;
    platformFailure = null;
    browser = NativeObservationBrowser(channel: channel);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final failure = platformFailure;
      if (failure != null) throw failure;
      if (call.method == 'startYoungReadOnly' ||
          call.method == 'readYoungReadOnly') {
        final supplied = reply;
        if (supplied != null) return supplied;
        final args = call.arguments as Map;
        return _reply(
          session: args['session'] as int,
          document: args['document'] as int,
          operation: args['operation'] as int,
        );
      }
      return null;
    });
  });

  tearDown(() async {
    await browser.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> openYoung({int session = 7}) async {
    await browser.open(
      session: session,
      profilePath: r'C:\synthetic-profile',
      target: ObservationTarget.young(),
    );
    calls.clear();
  }

  Future<void> openJw({int session = 7}) async {
    await browser.open(
      session: session,
      profilePath: r'C:\synthetic-profile',
      target: ObservationTarget.jw(),
    );
    calls.clear();
  }

  Matcher failure(FailureCode code) =>
      throwsA(isA<AppFailure>().having((error) => error.code, 'code', code));

  test('start, read, and stop send only the fixed current bindings', () async {
    await openYoung();
    const expected = <String, int>{
      'session': 7,
      'document': 3,
      'operation': 29,
    };

    final started = await browser.startYoungReadOnly(
      session: 7,
      document: 3,
      operation: 29,
    );
    expect(started.operation, 29);
    expect(
      (await browser.readYoungReadOnly(
        session: 7,
        document: 3,
        operation: 29,
      )).operation,
      29,
    );
    await browser.stopYoungReadOnly(session: 7, document: 3, operation: 29);

    expect(calls.map((call) => call.method), [
      'startYoungReadOnly',
      'readYoungReadOnly',
      'stopYoungReadOnly',
    ]);
    for (final call in calls) {
      expect(call.arguments, expected);
      expect((call.arguments as Map).keys.toSet(), {
        'session',
        'document',
        'operation',
      });
      final encoded = jsonEncode(call.arguments);
      expect(encoded, isNot(contains('https://')));
      expect(encoded, isNot(contains('synthetic-secret')));
      expect(encoded, isNot(contains('script')));
      expect(encoded, isNot(contains('url')));
    }
  });

  test(
    'Young operations are rejected for JW before any platform call',
    () async {
      await openJw();

      await expectLater(
        browser.startYoungReadOnly(session: 7, document: 3, operation: 29),
        failure(FailureCode.invalidSnapshot),
      );
      await expectLater(
        browser.readYoungReadOnly(session: 7, document: 3, operation: 29),
        failure(FailureCode.invalidSnapshot),
      );
      await expectLater(
        browser.stopYoungReadOnly(session: 7, document: 3, operation: 29),
        failure(FailureCode.invalidSnapshot),
      );
      expect(calls, isEmpty);
    },
  );

  test(
    'invalid command bindings do not reach native and response bindings are checked',
    () async {
      await openYoung();
      for (final args in <Map<String, int>>[
        {'session': 8, 'document': 3, 'operation': 29},
        {'session': 7, 'document': -1, 'operation': 29},
        {'session': 7, 'document': 3, 'operation': 0},
      ]) {
        await expectLater(
          browser.readYoungReadOnly(
            session: args['session']!,
            document: args['document']!,
            operation: args['operation']!,
          ),
          failure(FailureCode.staleResult),
        );
      }
      expect(calls, isEmpty);

      for (final mismatch in ['session', 'document', 'operation']) {
        reply = _reply(
          session: mismatch == 'session' ? 8 : 7,
          document: mismatch == 'document' ? 4 : 3,
          operation: mismatch == 'operation' ? 30 : 29,
        );
        await expectLater(
          browser.readYoungReadOnly(session: 7, document: 3, operation: 29),
          failure(FailureCode.staleResult),
        );
      }
      expect(calls, hasLength(3));
      for (final call in calls) {
        expect(call.arguments, {'session': 7, 'document': 3, 'operation': 29});
      }
    },
  );

  test(
    'closed DTO decoding rejects raw, unknown, and secret-bearing replies',
    () async {
      await openYoung();
      for (final invalid in <Object?>[
        '<html>synthetic-private-page</html>',
        <String, Object?>{
          ..._reply(session: 7, document: 3, operation: 29),
          'cookie': 'synthetic-secret',
        },
        <String, Object?>{
          ..._reply(session: 7, document: 3, operation: 29),
          'profile': <String, Object?>{
            ...(_reply(session: 7, document: 3, operation: 29)['profile']
                as Map),
            'usernameValue': 'synthetic-account',
          },
        },
      ]) {
        reply = invalid;
        await expectLater(
          browser.readYoungReadOnly(session: 7, document: 3, operation: 29),
          failure(FailureCode.invalidSnapshot),
        );
      }
      expect(calls, hasLength(3));
    },
  );

  test(
    'native exceptions map to closed app failures without raw details',
    () async {
      await openYoung();
      platformFailure = PlatformException(
        code: 'app_failure',
        details: 'staleResult',
        message: 'synthetic-private-detail',
      );
      await expectLater(
        browser.startYoungReadOnly(session: 7, document: 3, operation: 29),
        failure(FailureCode.staleResult),
      );

      platformFailure = PlatformException(
        code: 'private-native-code',
        message: 'synthetic-private-detail',
        details: 'synthetic-secret',
      );
      await expectLater(
        browser.readYoungReadOnly(session: 7, document: 3, operation: 29),
        failure(FailureCode.sourceFailed),
      );
    },
  );
}

Map<String, Object?> _reply({
  required int session,
  required int document,
  required int operation,
}) => <String, Object?>{
  'session': session,
  'document': document,
  'operation': operation,
  'listening': true,
  'accepted': 0,
  'rejected': 0,
  'lastRejection': 'none',
  'profile': <String, Object?>{
    'observations': 0,
    'success': 'unobserved',
    'code': 'absent',
    'result': 'absent',
    'loginCode': 'absent',
    'username': 'absent',
  },
  'schedule': _unobservedList(),
  'activities': _unobservedList(),
};

Map<String, Object?> _unobservedList() => <String, Object?>{
  'observations': 0,
  'success': 'unobserved',
  'code': 'absent',
  'result': 'absent',
  'records': 'absent',
  'count': 0,
  'total': 'absent',
  'id': 'absent',
  'title': 'absent',
  'date': 'absent',
  'startTime': 'absent',
  'endTime': 'absent',
};
