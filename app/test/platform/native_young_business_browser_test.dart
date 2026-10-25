import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/source/jw_authentication_contract.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';
import 'package:ustc_assistant_m0/source/young_active_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ustc_assistant/observation_v1');
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
      if (call.method == 'pollYoungBusinessStep') {
        return reply ??
            _stepReply(session: 7, document: 3, operation: 29, step: 11);
      }
      if (call.method == 'prepareYoungBusinessPage' ||
          call.method == 'advanceYoungLogin' ||
          call.method == 'submitYoungLogin') {
        return reply;
      }
      return null;
    });
  });

  tearDown(() async {
    await browser.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<MethodCall> openYoung() async {
    await browser.open(
      session: 7,
      profilePath: r'C:\synthetic-profile',
      target: ObservationTarget.young(),
    );
    final call = calls.single;
    calls.clear();
    return call;
  }

  Matcher failure(FailureCode code) =>
      throwsA(isA<AppFailure>().having((error) => error.code, 'code', code));

  test(
    'shared CAS actions remain Young-bound and wipe the one-use secret',
    () async {
      await openYoung();
      reply = 'formReady';
      expect(
        await browser.advanceYoungLogin(session: 7, document: 3, operation: 1),
        JwLoginState.formReady,
      );
      final bytes = Uint8List.fromList(utf8.encode('SYNTHETIC_SECRET'));
      final lease = JwSecretLease(bytes);
      reply = 'submitted';
      expect(
        await browser.submitYoungLogin(
          session: 7,
          document: 3,
          operation: 1,
          credentials: lease,
        ),
        JwLoginState.submitted,
      );
      expect(bytes.every((b) => b == 0), isTrue);
      expect(() => lease.take(), throwsA(isA<JwCredentialException>()));
      expect(calls.map((c) => c.method), [
        'advanceYoungLogin',
        'submitYoungLogin',
      ]);
      await expectLater(
        browser.advanceJwLogin(session: 7, document: 3, operation: 2),
        failure(FailureCode.invalidSnapshot),
      );
      await browser.open(
        session: 8,
        profilePath: r'C:\synthetic-jw',
        target: ObservationTarget.jw(),
      );
      final rejected = Uint8List.fromList([1, 2, 3]);
      await expectLater(
        browser.submitYoungLogin(
          session: 8,
          document: 3,
          operation: 2,
          credentials: JwSecretLease(rejected),
        ),
        failure(FailureCode.invalidSnapshot),
      );
      expect(rejected.every((b) => b == 0), isTrue);
    },
  );

  test(
    'fixed preparation and failure diagnostics accept only closed metadata',
    () async {
      await openYoung();
      reply = true;
      expect(
        await browser.prepareYoungBusinessPage(
          session: 7,
          document: 3,
          page: YoungBusinessPage.activities,
        ),
        isTrue,
      );
      expect(calls.single.arguments, {
        'session': 7,
        'document': 3,
        'page': 'activities',
      });
      platformFailure = PlatformException(
        code: 'app_failure',
        details: {'code': 'staleResult', 'reason': 'compiledScript'},
      );
      await expectLater(
        browser.startYoungBusiness(session: 7, document: 3, operation: 1),
        throwsA(
          isA<YoungBusinessException>().having(
            (e) => e.reason,
            'reason',
            YoungBusinessRejection.compiledScript,
          ),
        ),
      );
      platformFailure = PlatformException(
        code: 'app_failure',
        details: {
          'code': 'staleResult',
          'reason': 'compiledScript',
          'raw': 'PRIVATE_SENTINEL',
        },
      );
      await expectLater(
        browser.startYoungBusiness(session: 7, document: 3, operation: 1),
        failure(FailureCode.invalidSnapshot),
      );
    },
  );

  test(
    'sends fixed Young source and exact method bindings and enum labels',
    () async {
      final openCall = await openYoung();
      expect(openCall.method, 'open');
      expect(
        (openCall.arguments as Map)['source'],
        ObservationSource.young.name,
      );
      expect((openCall.arguments as Map)['session'], 7);

      await browser.startYoungBusiness(session: 7, document: 3, operation: 29);
      await browser.dispatchYoungBusinessStep(
        session: 7,
        document: 3,
        operation: 29,
        step: 9,
        endpoint: YoungBusinessEndpoint.profile,
      );
      await browser.dispatchYoungBusinessStep(
        session: 7,
        document: 3,
        operation: 29,
        step: 10,
        endpoint: YoungBusinessEndpoint.activities,
        page: 1,
      );
      await browser.dispatchYoungBusinessStep(
        session: 7,
        document: 3,
        operation: 29,
        step: 11,
        endpoint: YoungBusinessEndpoint.schedule,
        page: 2,
        day: '2026-10-11',
      );
      final projected = await browser.pollYoungBusinessStep(
        session: 7,
        document: 3,
        operation: 29,
        step: 11,
      );
      await browser.finishYoungBusiness(session: 7, document: 3, operation: 29);
      await browser.navigateYoungBusinessPage(
        session: 7,
        document: 3,
        page: YoungBusinessPage.activities,
      );
      await browser.navigateYoungBusinessPage(
        session: 7,
        document: 3,
        page: YoungBusinessPage.calendar,
      );

      expect(projected.complete, isTrue);
      expect(projected.projectedJson, '{}');
      expect(calls.map((call) => call.method), [
        'startYoungBusiness',
        'dispatchYoungBusinessStep',
        'dispatchYoungBusinessStep',
        'dispatchYoungBusinessStep',
        'pollYoungBusinessStep',
        'finishYoungBusiness',
        'navigateYoungBusinessPage',
        'navigateYoungBusinessPage',
      ]);
      expect(calls[0].arguments, {
        'session': 7,
        'document': 3,
        'operation': 29,
      });
      expect(calls[1].arguments, {
        'session': 7,
        'document': 3,
        'operation': 29,
        'step': 9,
        'endpoint': 'profile',
        'page': 0,
      });
      expect(calls[2].arguments, {
        'session': 7,
        'document': 3,
        'operation': 29,
        'step': 10,
        'endpoint': 'activities',
        'page': 1,
      });
      expect(calls[3].arguments, {
        'session': 7,
        'document': 3,
        'operation': 29,
        'step': 11,
        'endpoint': 'schedule',
        'page': 2,
        'day': '2026-10-11',
      });
      expect(calls[4].arguments, {
        'session': 7,
        'document': 3,
        'operation': 29,
        'step': 11,
      });
      expect(calls[5].arguments, {
        'session': 7,
        'document': 3,
        'operation': 29,
      });
      expect(calls[6].arguments, {
        'session': 7,
        'document': 3,
        'page': 'activities',
      });
      expect(calls[7].arguments, {
        'session': 7,
        'document': 3,
        'page': 'calendar',
      });
      for (final call in calls) {
        final encoded = jsonEncode(call.arguments);
        expect(encoded, isNot(contains('https://')));
        expect(encoded, isNot(contains('account')));
        expect(encoded, isNot(contains('response')));
      }
    },
  );

  test(
    'rejects Young RPCs on JW and invalid associations before native calls',
    () async {
      await browser.open(
        session: 7,
        profilePath: r'C:\synthetic-profile',
        target: ObservationTarget.jw(),
      );
      calls.clear();
      await expectLater(
        browser.startYoungBusiness(session: 7, document: 3, operation: 29),
        failure(FailureCode.invalidSnapshot),
      );
      expect(calls, isEmpty);

      await openYoung();
      for (final invalid in <({int session, int document, int operation})>[
        (session: 8, document: 3, operation: 29),
        (session: 7, document: -1, operation: 29),
        (session: 7, document: 3, operation: 0),
      ]) {
        await expectLater(
          browser.startYoungBusiness(
            session: invalid.session,
            document: invalid.document,
            operation: invalid.operation,
          ),
          failure(FailureCode.staleResult),
        );
      }
      await expectLater(
        browser.dispatchYoungBusinessStep(
          session: 7,
          document: 3,
          operation: 29,
          step: 0,
          endpoint: YoungBusinessEndpoint.activities,
          page: 1,
        ),
        failure(FailureCode.invalidSnapshot),
      );
      expect(calls, isEmpty);
    },
  );

  test('rejects unknown DTO fields and mismatched step bindings', () async {
    await openYoung();
    reply = <String, Object?>{
      ..._stepReply(session: 7, document: 3, operation: 29, step: 11),
      'username': 'SYNTHETIC_ACCOUNT_92814',
    };
    await expectLater(
      browser.pollYoungBusinessStep(
        session: 7,
        document: 3,
        operation: 29,
        step: 11,
      ),
      failure(FailureCode.invalidSnapshot),
    );

    reply = _stepReply(session: 7, document: 3, operation: 29, step: 12);
    await expectLater(
      browser.pollYoungBusinessStep(
        session: 7,
        document: 3,
        operation: 29,
        step: 11,
      ),
      failure(FailureCode.staleResult),
    );
    expect(calls.map((call) => call.method), [
      'pollYoungBusinessStep',
      'pollYoungBusinessStep',
    ]);
  });

  test('maps platform failure without exposing native details', () async {
    await openYoung();
    platformFailure = PlatformException(
      code: 'app_failure',
      details: 'sourceFailed',
      message: 'SYNTHETIC_PRIVATE_NATIVE_DETAIL',
    );
    await expectLater(
      browser.dispatchYoungBusinessStep(
        session: 7,
        document: 3,
        operation: 29,
        step: 11,
        endpoint: YoungBusinessEndpoint.activities,
        page: 1,
      ),
      failure(FailureCode.sourceFailed),
    );
  });
}

Map<String, Object?> _stepReply({
  required int session,
  required int document,
  required int operation,
  required int step,
}) => <String, Object?>{
  'session': session,
  'document': document,
  'operation': operation,
  'step': step,
  'complete': true,
  'projectedJson': '{}',
};
