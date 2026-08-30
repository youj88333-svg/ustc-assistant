// M7: `JwWebViewAdapter` unit tests against a fake controller seam.
//
// No real WebView, no network, no platform plugins — the fake controller
// simulates the WebView2 events (url changes, loading state, web messages) and
// script execution. Covers the adapter-specific behaviors:
//   - three-signal convergence (any order) for the CAS form / home / course /
//     exam targets
//   - CAS login activation (click), fill username/password, submit, natural
//     home return, identity proof
//   - identity verification maps conflicts to `account_mismatch`, and only
//     returns booleans (never account plaintext)
//   - course get-data/datum fetch maps to the same request shape as Python
//   - error mapping (JwLoginTimeoutException / JwAccountMismatchException /
//     JwCollectionException)
//   - URL allowlist defense (reject non-allowlisted navigation)
//   - close() disposes controller + clears browsing data
// See `docs/plan-webview-minimal-m7-webview2.md` §Task3.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_web_page.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_web_session.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_webview_adapter.dart';

const _casUrl = 'https://id.ustc.edu.cn/cas/login';
const _homeUrl = 'https://jw.ustc.edu.cn/home';
const _loginEntryUrl = 'https://jw.ustc.edu.cn/login';
const _courseTableUrl = 'https://jw.ustc.edu.cn/for-std/course-table';
const _examUrl = 'https://jw.ustc.edu.cn/for-std/exam-arrange';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('JwWebViewAdapter fake-controller tests', () {
    late FakeJwWebviewController controller;
    late JwWebViewAdapter adapter;
    late List<String> diagnostics;
    late int factoryCalls;

    setUp(() {
      controller = FakeJwWebviewController();
      diagnostics = <String>[];
      factoryCalls = 0;
      adapter = JwWebViewAdapter(
        controllerFactory: () async {
          factoryCalls++;
          return controller;
        },
        loginTimeout: const Duration(seconds: 5),
        responseTimeout: const Duration(seconds: 3),
        safeDiagnostic: diagnostics.add,
      );
    });

    test(
      'gotoRoot loads the allowlisted root and reports navigation complete',
      () async {
        controller.setCurrent('https://jw.ustc.edu.cn/');
        await adapter.gotoRoot();
        expect(controller.lastLoadedUrl, jwRootUrl);
        expect(controller.disposed, isFalse);
      },
    );

    test('isAuthenticatedHome reflects currentUrl', () async {
      controller.setCurrent(_homeUrl);
      expect(await adapter.isAuthenticatedHome, isTrue);
      controller.setCurrent(_loginEntryUrl);
      expect(await adapter.isAuthenticatedHome, isFalse);
    });

    test(
      'reused authenticated home requires strict readiness and identity proof',
      () async {
        controller
          ..setCurrent(_homeUrl)
          ..sessionHealthy = true
          ..identityAuthenticated = true;

        expect(
          await adapter.verifyAuthenticatedHome(
            expectedUsername: 'ustc.student',
            timeout: const Duration(seconds: 2),
          ),
          isTrue,
        );

        controller.identityAuthenticated = false;
        controller.identityConflict = true;
        await expectLater(
          adapter.verifyAuthenticatedHome(
            expectedUsername: 'other.student',
            timeout: const Duration(seconds: 2),
          ),
          throwsA(isA<JwAccountMismatchException>()),
        );
      },
    );

    group('CAS login fill', () {
      test(
        'fills username + password, submits, awaits home, verifies identity',
        () async {
          controller.setCurrent(_loginEntryUrl);
          controller
            ..identityAuthenticated = true
            ..sessionHealthy = true;

          await adapter.fillLogin(
            const LoginCredentials(
              username: 'ustc.student',
              password: 'pw-secret',
            ),
          );
          await adapter.waitForAuthenticatedHome(const Duration(seconds: 2));

          expect(controller.usernameFilled, 'ustc.student');
          expect(controller.passwordFilled, 'pw-secret');
          expect(controller.submitted, isTrue);
          expect(controller.visitedCas, isTrue);
          expect(controller.visitedHome, isTrue);
          expect(controller.secretTouchedAsPlaintext, isFalse);
        },
      );

      test(
        'account mismatch on identity conflict maps to JwAccountMismatchException',
        () async {
          controller.setCurrent(_loginEntryUrl);
          controller.identityAuthenticated = false;
          controller.identityConflict = true;
          controller.sessionHealthy = true;

          await adapter.fillLogin(
            const LoginCredentials(username: 'other.user', password: 'pw'),
          );
          await expectLater(
            adapter.waitForAuthenticatedHome(const Duration(seconds: 2)),
            throwsA(isA<JwAccountMismatchException>()),
          );
        },
      );

      test(
        'empty password fills username and leaves visible manual submit',
        () async {
          controller.setCurrent(_loginEntryUrl);

          await adapter.fillLogin(
            const LoginCredentials(username: 'ustc.student'),
          );
          expect(controller.usernameFilled, 'ustc.student');
          expect(controller.passwordFilled, isNull);
          expect(controller.submitted, isFalse);
          expect(controller.submitCalls, 0);

          // Simulate the user entering the password and pressing the visible
          // CAS submit button. The adapter must still verify the resulting
          // authenticated session and identity.
          controller
            ..identityAuthenticated = true
            ..sessionHealthy = true
            ..setCurrent(_homeUrl);
          await adapter.waitForAuthenticatedHome(const Duration(seconds: 2));
        },
      );

      test(
        'a failed portal attempt resets the guard and permits retry',
        () async {
          controller
            ..setCurrent(_loginEntryUrl)
            ..portalLoginMatched = false;
          await expectLater(
            adapter.fillLogin(
              const LoginCredentials(username: 'PB00000000', password: 'pw'),
            ),
            throwsA(isA<JwCollectionException>()),
          );

          controller
            ..portalLoginMatched = true
            ..setCurrent(_loginEntryUrl);
          await adapter.fillLogin(
            const LoginCredentials(username: 'PB00000000', password: 'pw'),
          );
          expect(controller.primaryClicks, 1);
          expect(controller.submitCalls, 1);
        },
      );

      test(
        'an unacknowledged submit resets the guard and permits retry',
        () async {
          controller
            ..setCurrent(_loginEntryUrl)
            ..submitAcknowledged = false;
          await expectLater(
            adapter.fillLogin(
              const LoginCredentials(username: 'PB00000000', password: 'pw'),
            ),
            throwsA(isA<JwCollectionException>()),
          );

          controller
            ..submitAcknowledged = true
            ..visitedCas = false
            ..setCurrent(_loginEntryUrl);
          await adapter.fillLogin(
            const LoginCredentials(username: 'PB00000000', password: 'pw'),
          );
          expect(controller.primaryClicks, 2);
          expect(controller.submitCalls, 2);
        },
      );

      test(
        'a canceled fill before wait resets the guard and permits retry',
        () async {
          controller
            ..setCurrent(_loginEntryUrl)
            ..cancelScriptId = 'jw.cas.fillUsername';
          await expectLater(
            adapter.fillLogin(
              const LoginCredentials(username: 'PB00000000', password: 'pw'),
            ),
            throwsA(isA<JwCollectionException>()),
          );

          controller
            ..cancelScriptId = null
            ..visitedCas = false
            ..setCurrent(_loginEntryUrl);
          await adapter.fillLogin(
            const LoginCredentials(username: 'PB00000000', password: 'pw'),
          );
          expect(controller.primaryClicks, 2);
          expect(controller.submitCalls, 1);
        },
      );
    });

    group('waitForAuthenticatedHome', () {
      test(
        'throws JwLoginTimeoutException when home never converges',
        () async {
          await expectLater(
            adapter.waitForAuthenticatedHome(const Duration(milliseconds: 200)),
            throwsA(isA<JwLoginTimeoutException>()),
          );
        },
      );

      test('succeeds when home URL + inspect handshake converge', () async {
        controller
          ..setCurrent(_loginEntryUrl)
          ..identityAuthenticated = true
          ..sessionHealthy = true;
        await adapter.fillLogin(
          const LoginCredentials(username: 'ustc.student', password: 'pw'),
        );
        await adapter.waitForAuthenticatedHome(const Duration(seconds: 2));
      });

      test(
        'home readiness fails when registered handshake is missing',
        () async {
          controller
            ..setCurrent(_homeUrl)
            ..suppressWebMessage = true;
          await expectLater(
            adapter.waitForAuthenticatedHome(const Duration(milliseconds: 150)),
            throwsA(isA<JwLoginTimeoutException>()),
          );
        },
      );

      test('home readiness fails when URL signal is missing', () async {
        controller
          ..suppressUrl = true
          ..setCurrent(_homeUrl);
        await expectLater(
          adapter.waitForAuthenticatedHome(const Duration(milliseconds: 150)),
          throwsA(isA<JwLoginTimeoutException>()),
        );
      });

      test('home readiness fails when required DOM is missing', () async {
        controller
          ..setCurrent(_homeUrl)
          ..selectorPresent = false;
        await expectLater(
          adapter.waitForAuthenticatedHome(const Duration(milliseconds: 150)),
          throwsA(isA<JwLoginTimeoutException>()),
        );
      });

      test('home convergence rejects a sibling prefix URL', () async {
        controller
          ..setCurrent('https://jw.ustc.edu.cn/homeevil')
          ..sessionHealthy = true;
        await expectLater(
          adapter.waitForAuthenticatedHome(const Duration(milliseconds: 150)),
          throwsA(isA<JwLoginTimeoutException>()),
        );
      });

      test(
        'home readiness rejects a stale CAS document on a home URL event',
        () async {
          controller
            ..setCurrent(_casUrl)
            ..emitUrlOnly(_homeUrl)
            ..sessionHealthy = true;
          await expectLater(
            adapter.waitForAuthenticatedHome(const Duration(milliseconds: 150)),
            throwsA(anything),
          );
        },
      );

      test('home readiness rejects a false authenticated handshake', () async {
        controller
          ..setCurrent(_homeUrl)
          ..sessionHealthy = false;
        await expectLater(
          adapter.waitForAuthenticatedHome(const Duration(seconds: 2)),
          throwsA(isA<JwCollectionException>()),
        );
      });

      test(
        'home handshake waits for loading completion after an interactive DOM',
        () async {
          controller
            ..setCurrent(_homeUrl)
            ..sessionHealthy = true
            ..documentReadyState = 'interactive';
          final wait = adapter.waitForAuthenticatedHome(
            const Duration(seconds: 1),
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(controller.handshakeCalls, 0);

          controller.documentReadyState = 'complete';
          await expectLater(wait, throwsA(isA<JwCollectionException>()));
          expect(controller.handshakeCalls, 1);
        },
      );

      test(
        'home readiness propagates a non-timeout handshake failure',
        () async {
          controller
            ..setCurrent(_homeUrl)
            ..sessionHealthy = true
            ..handshakeFailureReason = 'script_failed';
          await expectLater(
            adapter.waitForAuthenticatedHome(const Duration(seconds: 2)),
            throwsA(isA<JwCollectionException>()),
          );
        },
      );

      test('late selector signal from an old attempt is ignored', () async {
        controller
          ..setCurrent(_homeUrl)
          ..sessionHealthy = true
          ..selectorProbeDelay = const Duration(milliseconds: 100);
        await expectLater(
          adapter.waitForAuthenticatedHome(const Duration(milliseconds: 25)),
          throwsA(isA<JwLoginTimeoutException>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 125));
        expect(diagnostics, isNot(contains('ready:jw.portal.home')));
      });

      test(
        'a late home handshake after document switch fails closed',
        () async {
          controller
            ..setCurrent(_loginEntryUrl)
            ..identityAuthenticated = true
            ..sessionHealthy = true
            ..switchDocumentAfterHandshakeReply = true;
          await adapter.fillLogin(
            const LoginCredentials(username: 'PB00000000', password: 'pw'),
          );
          await expectLater(
            adapter.waitForAuthenticatedHome(const Duration(seconds: 2)),
            throwsA(isA<JwCollectionException>()),
          );
        },
      );
    });

    group('strict identity proof', () {
      test('missing authoritative identity fails closed', () async {
        controller
          ..setCurrent(_loginEntryUrl)
          ..authoritativeMatched = false
          ..domMatched = true
          ..storageMatched = true
          ..sessionHealthy = true;
        await adapter.fillLogin(
          const LoginCredentials(username: 'PB00000000', password: 'pw'),
        );
        await expectLater(
          adapter.waitForAuthenticatedHome(const Duration(seconds: 2)),
          throwsA(isA<JwAccountMismatchException>()),
        );
      });

      test('authoritative identity conflict fails closed', () async {
        controller
          ..setCurrent(_loginEntryUrl)
          ..authoritativeMatched = true
          ..authoritativeConflicted = true
          ..domMatched = true
          ..storageMatched = true
          ..sessionHealthy = true;
        await adapter.fillLogin(
          const LoginCredentials(username: 'PB00000000', password: 'pw'),
        );
        await expectLater(
          adapter.waitForAuthenticatedHome(const Duration(seconds: 2)),
          throwsA(isA<JwAccountMismatchException>()),
        );
      });

      test('DOM identity conflict fails closed', () async {
        controller
          ..setCurrent(_loginEntryUrl)
          ..authoritativeMatched = true
          ..domMatched = true
          ..domConflicted = true
          ..storageMatched = true
          ..sessionHealthy = true;
        await adapter.fillLogin(
          const LoginCredentials(username: 'PB00000000', password: 'pw'),
        );
        await expectLater(
          adapter.waitForAuthenticatedHome(const Duration(seconds: 2)),
          throwsA(isA<JwAccountMismatchException>()),
        );
      });

      test('storage identity conflict fails closed', () async {
        controller
          ..setCurrent(_loginEntryUrl)
          ..authoritativeMatched = true
          ..domMatched = true
          ..storageMatched = true
          ..storageConflicted = true
          ..sessionHealthy = true;
        await adapter.fillLogin(
          const LoginCredentials(username: 'PB00000000', password: 'pw'),
        );
        await expectLater(
          adapter.waitForAuthenticatedHome(const Duration(seconds: 2)),
          throwsA(isA<JwAccountMismatchException>()),
        );
      });

      test('final identity failure clears the pending login attempt', () async {
        controller
          ..setCurrent(_loginEntryUrl)
          ..identityAuthenticated = false
          ..identityConflict = true
          ..sessionHealthy = true;
        await adapter.fillLogin(
          const LoginCredentials(username: 'PB00000000', password: 'pw'),
        );
        await expectLater(
          adapter.waitForAuthenticatedHome(const Duration(seconds: 2)),
          throwsA(isA<JwAccountMismatchException>()),
        );

        controller
          ..setCurrent(_loginEntryUrl)
          ..identityAuthenticated = true
          ..identityConflict = false
          ..visitedCas = false;
        await adapter.fillLogin(
          const LoginCredentials(username: 'PB00000000', password: 'pw'),
        );
        expect(controller.primaryClicks, 2);
      });
    });

    test('login activates exact trusted portal target once', () async {
      controller
        ..setCurrent(_loginEntryUrl)
        ..authoritativeMatched = true
        ..portalLoginMatched = true;
      await adapter.fillLogin(
        const LoginCredentials(username: 'PB00000000', password: 'pw'),
      );
      expect(controller.primaryClicks, 1);
      expect(controller.submitCalls, 1);
      expect(controller.selectorProbes, contains('#login-unified-wrapper'));
    });

    test('login does not select another login-like element', () async {
      controller
        ..setCurrent(_loginEntryUrl)
        ..portalLoginMatched = true
        ..clickProbeMatchesExactWrapper = false;
      await expectLater(
        adapter.fillLogin(
          const LoginCredentials(username: 'PB00000000', password: 'pw'),
        ),
        throwsA(isA<JwCollectionException>()),
      );
      expect(controller.primaryClicks, 0);
      expect(controller.selectorProbes, contains('#login-unified-wrapper'));
    });

    test(
      'geometry completing after convergence timeout cannot click',
      () async {
        final shortAdapter = JwWebViewAdapter(
          controllerFactory: () async => controller,
          loginTimeout: const Duration(seconds: 1),
          casFormWaitTimeout: const Duration(milliseconds: 40),
          responseTimeout: const Duration(seconds: 1),
          safeDiagnostic: diagnostics.add,
        );
        controller
          ..setCurrent(_loginEntryUrl)
          ..geometryDelay = const Duration(milliseconds: 140);
        await expectLater(
          shortAdapter.fillLogin(
            const LoginCredentials(username: 'PB00000000', password: 'pw'),
          ),
          throwsA(isA<JwCollectionException>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 170));
        expect(controller.primaryClicks, 0);

        controller
          ..geometryDelay = Duration.zero
          ..setCurrent(_loginEntryUrl);
        await shortAdapter.fillLogin(
          const LoginCredentials(username: 'PB00000000', password: 'pw'),
        );
        expect(controller.primaryClicks, 1);
      },
    );

    group('CAS form proof', () {
      test('hidden password input fails CAS readiness closed', () async {
        controller
          ..setCurrent(_loginEntryUrl)
          ..casFormMatched = false
          ..passwordVisible = false;
        await expectLater(
          adapter.fillLogin(
            const LoginCredentials(username: 'PB00000000', password: 'pw'),
          ),
          throwsA(isA<JwCollectionException>()),
        );
        expect(controller.primaryClicks, 1);
        expect(controller.submitCalls, 0);
      });

      test(
        'username and password in different forms fail CAS readiness',
        () async {
          controller
            ..setCurrent(_loginEntryUrl)
            ..casFormMatched = false
            ..fieldsInSameForm = false;
          await expectLater(
            adapter.fillLogin(
              const LoginCredentials(username: 'PB00000000', password: 'pw'),
            ),
            throwsA(isA<JwCollectionException>()),
          );
          expect(controller.primaryClicks, 1);
          expect(controller.submitCalls, 0);
        },
      );

      test('credential scripts remain scoped to the proven form', () {
        expect(
          jwRegisteredScripts['jw.cas.fillUsername'],
          allOf(contains('querySelectorAll(\'form\')'), contains('form.')),
        );
        expect(
          jwRegisteredScripts['jw.cas.fillPassword'],
          allOf(contains('querySelectorAll(\'form\')'), contains('form.')),
        );
        expect(
          jwRegisteredScripts['jw.cas.submit'],
          allOf(contains('querySelectorAll(\'form\')'), contains('form.')),
        );
      });
    });

    group('course datum', () {
      test('resolveCourseDataId reads dataId from the page context', () async {
        controller
          ..setCurrent(_courseTableUrl)
          ..dataId = 'data-ctx-1';
        final id = await adapter.resolveCourseDataId(
          const Duration(seconds: 2),
        );
        expect(id, 'data-ctx-1');
      });

      test('resolveCourseDataId rejects a wrong bizTypeId context', () async {
        controller
          ..setCurrent(_courseTableUrl)
          ..dataId = 'data-ctx-1'
          ..dataContextBizTypeId = '1';
        await expectLater(
          adapter.resolveCourseDataId(const Duration(seconds: 2)),
          throwsA(isA<JwCollectionException>()),
        );
      });

      test(
        'fetchCourseDatum runs get-data + datum with the right args',
        () async {
          controller
            ..setCurrent(_courseTableUrl)
            ..datumText =
                '{"result":{"lesson":[{"name":"x"}],'
                '"lessonList":[],"scheduleGroupList":[],"scheduleList":[]}}';
          final datum = await adapter.fetchCourseDatum(
            semesterId: 461,
            dataId: 'data-ctx-1',
            referer: _courseTableUrl,
          );
          expect(
            (datum['result'] as Map<String, dynamic>)['lesson'],
            isNotEmpty,
          );
          expect(controller.lastGetDataArgs, <String, Object?>{
            'semesterId': 461,
            'dataId': 'data-ctx-1',
          });
          expect(controller.lastDatumLessonIds, <Object?>[101, 102]);
        },
      );

      test('fetchCourseDatum forwards a non-default semester', () async {
        controller.setCurrent(_courseTableUrl);
        await adapter.fetchCourseDatum(
          semesterId: 462,
          dataId: 'data-ctx-1',
          referer: _courseTableUrl,
        );
        expect(controller.lastGetDataArgs, <String, Object?>{
          'semesterId': 462,
          'dataId': 'data-ctx-1',
        });
      });

      test('invalid lessonIds fail before the datum script runs', () async {
        final invalidLessonIds = <List<Object?>>[
          <Object?>[],
          <Object?>[0],
          <Object?>[1, 1],
          <Object?>['1'],
          List<Object?>.generate(20001, (index) => index + 1),
        ];

        for (final lessonIds in invalidLessonIds) {
          controller
            ..getDataText = jsonEncode(<String, Object?>{
              'lessonIds': lessonIds,
            })
            ..datumScriptRuns = 0
            ..lastDatumLessonIds = null;

          await expectLater(
            adapter.fetchCourseDatum(
              semesterId: 461,
              dataId: 'data-ctx-1',
              referer: _courseTableUrl,
            ),
            throwsA(isA<JwCollectionException>()),
          );
          expect(controller.datumScriptRuns, 0);
        }
      });

      test('missing lessonIds maps to JwCollectionException', () async {
        controller
          ..setCurrent(_courseTableUrl)
          ..getDataText = '{"result":"no ids"}';
        await expectLater(
          adapter.fetchCourseDatum(
            semesterId: 461,
            dataId: 'data-ctx-1',
            referer: _courseTableUrl,
          ),
          throwsA(isA<JwCollectionException>()),
        );
      });

      test('incomplete datum result maps to JwCollectionException', () async {
        controller
          ..setCurrent(_courseTableUrl)
          ..datumText = '{"result":{}}';
        await expectLater(
          adapter.fetchCourseDatum(
            semesterId: 461,
            dataId: 'data-ctx-1',
            referer: _courseTableUrl,
          ),
          throwsA(isA<JwCollectionException>()),
        );
      });

      test('course readiness rejects a false target handshake', () async {
        controller
          ..setCurrent(_courseTableUrl)
          ..dataId = 'data-ctx-1'
          ..courseMatched = false;
        await expectLater(
          adapter.resolveCourseDataId(const Duration(seconds: 2)),
          throwsA(isA<JwCollectionException>()),
        );
      });

      test('get-data network failure maps to JwCollectionException', () async {
        controller
          ..setCurrent(_courseTableUrl)
          ..getDataFailureReason = 'request_failed';
        await expectLater(
          adapter.fetchCourseDatum(
            semesterId: 461,
            dataId: 'data-ctx-1',
            referer: _courseTableUrl,
          ),
          throwsA(isA<JwCollectionException>()),
        );
      });
    });

    test('fetchExamHtml returns the exam table marker', () async {
      controller
        ..setCurrent(_examUrl)
        ..examHtml = '<table id="exams"></table>';
      final html = await adapter.fetchExamHtml(const Duration(seconds: 2));
      expect(html, contains('table id="exams"'));
    });

    test('fetchExamHtml rejects multiple exam tables', () async {
      controller
        ..setCurrent(_examUrl)
        ..examHtml = '<table id="exams"></table><table id="exams"></table>';
      await expectLater(
        adapter.fetchExamHtml(const Duration(seconds: 2)),
        throwsA(isA<JwCollectionException>()),
      );
    });

    test('exam readiness rejects a false target handshake', () async {
      controller
        ..setCurrent(_examUrl)
        ..examMatched = false;
      await expectLater(
        adapter.fetchExamHtml(const Duration(seconds: 2)),
        throwsA(isA<JwCollectionException>()),
      );
    });

    test('close disposes the controller and clears browsing data', () async {
      await adapter.gotoRoot();
      controller.setCurrent('https://jw.ustc.edu.cn/');
      await adapter.close();
      expect(controller.disposed, isTrue);
      expect(controller.browsingCleared, isTrue);
    });

    test(
      'session lifecycle splits subscriptions from the release barrier',
      () async {
        await adapter.gotoRoot();
        await adapter.beginSubscriptions();
        await adapter.disposeSubscriptions();
        await adapter.disposeControllerAndAwaitRelease();

        expect(controller.subscriptionsDisposed, isTrue);
        expect(controller.releaseBarrierAwaited, isTrue);
      },
    );

    test(
      'native release invalidates the page and never recreates the controller',
      () async {
        await adapter.gotoRoot();
        expect(adapter.controller, same(controller));

        await adapter.disposeControllerAndAwaitRelease();

        expect(adapter.isDisposed, isTrue);
        expect(adapter.controller, isNull);
        await expectLater(
          adapter.gotoRoot(),
          throwsA(isA<JwCollectionException>()),
        );
        expect(controller.disposed, isTrue);
      },
    );

    test(
      'early cleanup failure after release permanently closes the adapter',
      () async {
        await adapter.gotoRoot();
        controller.failStop = true;
        final callsBeforeClose = factoryCalls;

        await expectLater(adapter.close(), throwsA(isA<StateError>()));

        expect(adapter.isDisposed, isTrue);
        expect(adapter.controller, isNull);
        expect(controller.releaseCalls, 1);
        await expectLater(
          adapter.gotoRoot(),
          throwsA(isA<JwCollectionException>()),
        );
        expect(factoryCalls, callsBeforeClose);
      },
    );

    test(
      'release failure retains the controller for a retrying close',
      () async {
        await adapter.gotoRoot();
        controller.failReleaseAttempts = 1;

        await expectLater(adapter.close(), throwsA(isA<StateError>()));
        expect(adapter.isDisposed, isFalse);
        expect(adapter.controller, same(controller));
        expect(controller.releaseCalls, 1);

        await adapter.close();
        expect(adapter.isDisposed, isTrue);
        expect(adapter.controller, isNull);
        expect(controller.releaseCalls, 2);
      },
    );
  });

  group('isJwNavigationAllowed allowlist', () {
    test('accepts allowed origins + path prefixes', () {
      expect(isJwNavigationAllowed('https://jw.ustc.edu.cn/home'), isTrue);
      expect(
        isJwNavigationAllowed(
          'https://jw.ustc.edu.cn/for-std/course-table?x=1',
        ),
        isTrue,
      );
      expect(
        isJwNavigationAllowed('https://jw.ustc.edu.cn/for-std/exam-arrange'),
        isTrue,
      );
      expect(isJwNavigationAllowed('https://id.ustc.edu.cn/cas/login'), isTrue);
      expect(
        isJwNavigationAllowed('https://analytics.ustc.edu.cn/.isg/gateway/a'),
        isTrue,
      );
    });

    test('fails closed on unknown hosts, non-HTTPS, and unknown paths', () {
      expect(isJwNavigationAllowed('https://evil.com/login'), isFalse);
      expect(isJwNavigationAllowed('http://jw.ustc.edu.cn/login'), isFalse);
      expect(
        isJwNavigationAllowed('https://jw.ustc.edu.cn/for-std/other'),
        isFalse,
      );
      expect(isJwNavigationAllowed('https://jw.ustc.edu.cn/admin'), isFalse);
    });
  });

  group('JwReadyTarget URL pattern boundaries', () {
    test(
      'accepts exact query/hash/subpath suffixes but rejects sibling prefixes',
      () {
        expect(portalHomeTarget.urlMatches(_homeUrl), isTrue);
        expect(portalHomeTarget.urlMatches('$_homeUrl?tab=1'), isTrue);
        expect(portalHomeTarget.urlMatches('$_homeUrl#summary'), isTrue);
        expect(portalHomeTarget.urlMatches('$_homeUrl/settings'), isTrue);
        expect(
          portalHomeTarget.urlMatches('https://jw.ustc.edu.cn/homeevil'),
          isFalse,
        );
        expect(
          productionJwWebRuntimePolicy.isAuthenticatedHomeUrl(
            'https://jw.ustc.edu.cn/homeevil',
          ),
          isFalse,
        );

        expect(
          portalLoginTarget.urlMatches('$_loginEntryUrl?next=cas'),
          isTrue,
        );
        expect(
          portalLoginTarget.urlMatches('https://jw.ustc.edu.cn/loginOther'),
          isFalse,
        );
        expect(casLoginTarget.urlMatches('$_casUrl?ticket=fixture'), isTrue);
        expect(courseHomeTarget.urlMatches('$_courseTableUrl/461'), isTrue);
        expect(
          courseHomeTarget.urlMatches(
            'https://jw.ustc.edu.cn/for-std/course-table-old',
          ),
          isFalse,
        );
        expect(examListTarget.urlMatches('$_examUrl/print'), isTrue);
      },
    );

    test(
      'live document probes reject sibling prefixes for every trailing target',
      () async {
        final probeController = FakeJwWebviewController();
        final siblingUrls = <JwReadyTarget, String>{
          portalLoginTarget: 'https://jw.ustc.edu.cn/loginOther',
          casLoginTarget: 'https://id.ustc.edu.cn/cas/loginOther',
          portalHomeTarget: 'https://jw.ustc.edu.cn/homeevil',
          courseHomeTarget: 'https://jw.ustc.edu.cn/for-std/course-table-old',
          examListTarget: 'https://jw.ustc.edu.cn/for-std/exam-arrange-old',
        };
        for (final entry in siblingUrls.entries) {
          probeController.documentProbeSources.clear();
          probeController.setCurrent(entry.value);
          // Keep the URL signal on the trusted target while the live document
          // remains on the sibling path. This isolates the JS probe gate from
          // the already-tested Dart URL signal.
          probeController.emitUrlOnly(entry.key.url);

          await expectLater(
            convergeTarget(
              probeController,
              entry.key,
              timeout: const Duration(milliseconds: 100),
            ),
            throwsA(isA<TimeoutException>()),
            reason: entry.key.id,
          );
          expect(
            probeController.documentProbeSources,
            isNotEmpty,
            reason: entry.key.id,
          );
          expect(
            probeController.documentProbeSources,
            everyElement(
              allOf(
                contains('const prefix = expected.slice(0, -1);'),
                contains('current.charAt(prefix.length)'),
                contains("next === '/"),
                contains("next === '?"),
                contains("next === '#"),
              ),
            ),
            reason: entry.key.id,
          );
        }

        final validUrls = <JwReadyTarget, String>{
          portalLoginTarget: '$_loginEntryUrl?next=cas',
          casLoginTarget: '$_casUrl#form',
          portalHomeTarget: _homeUrl,
          courseHomeTarget: '$_courseTableUrl/section',
          examListTarget: '$_examUrl/print',
        };
        probeController.sessionHealthy = true;
        for (final entry in validUrls.entries) {
          probeController.documentProbeSources.clear();
          probeController.setCurrent(entry.value);
          await convergeTarget(
            probeController,
            entry.key,
            timeout: const Duration(milliseconds: 500),
          );
          expect(
            probeController.documentProbeSources,
            isNotEmpty,
            reason: entry.key.id,
          );
          expect(
            probeController.documentProbeSources,
            everyElement(
              allOf(
                contains('const prefix = expected.slice(0, -1);'),
                contains('current.charAt(prefix.length)'),
                contains("next === '/"),
                contains("next === '?"),
                contains("next === '#"),
              ),
            ),
            reason: entry.key.id,
          );
        }
      },
    );

    test('registered handshakes use the same path boundary contract', () {
      const handshakeIds = <String>[
        'jw.portal.login.inspect',
        'jw.cas.inspect',
        'jw.cas.form.inspect',
        'jw.cas.fillUsername',
        'jw.cas.fillPassword',
        'jw.cas.submit',
        'jw.course.inspect',
        'jw.exam.inspect',
      ];
      for (final id in handshakeIds) {
        final source = jwRegisteredScripts[id]!;
        expect(source, contains('const pathMatches ='));
        expect(
          source,
          contains(r'location.pathname.startsWith(`${prefix}/`)'),
          reason: id,
        );
      }
    });
  });
}

/// A scripted fake of [JwWebviewController].
///
/// The fake models a WebView2 controller whose URL/loading stream is scripted
/// and whose `executeScript` runs the registered-script wrapper by extracting
/// the requestId embedded in the wrapper and echoing a `webMessage` reply.
/// Secrets travel as `secretBytes` Lists; the fake records the decoded value
/// only for assertions and never logs/keeps it as account plaintext.
class FakeJwWebviewController
    implements JwWebviewController, JwWebviewControllerLifecycle {
  final _urlController = StreamController<String>.broadcast();
  final _loadingController = StreamController<JwLoadingState>.broadcast();
  final _webMessageController = StreamController<Object?>.broadcast();

  String? _currentUrl;
  String? _lastSource;
  bool disposed = false;
  bool browsingCleared = false;
  bool subscriptionsDisposed = false;
  bool releaseBarrierAwaited = false;
  bool failStop = false;
  int failReleaseAttempts = 0;
  int stopCalls = 0;
  int releaseCalls = 0;

  // Scripted scenario state.
  String? dataId;
  String dataContextBizTypeId = '2';
  String getDataText = '{"lessonIds":[101,102]}';
  String datumText =
      '{"result":{"lesson":[],"lessonList":[],'
      '"scheduleGroupList":[],"scheduleList":[]}}';
  String? getDataFailureReason;
  String examHtml = '<table id="exams"></table>';

  String? lastLoadedUrl;
  Map<String, Object?>? lastGetDataArgs;
  List<Object?>? lastDatumLessonIds;
  int datumScriptRuns = 0;
  String? usernameFilled;
  String? passwordFilled;
  bool submitted = false;
  bool visitedCas = false;
  bool visitedHome = false;
  bool secretTouchedAsPlaintext = false;

  bool identityAuthenticated = false;
  bool identityConflict = false;
  bool? authoritativeMatched;
  bool? authoritativeConflicted;
  bool? domMatched;
  bool? domConflicted;
  bool? storageMatched;
  bool? storageConflicted;
  bool sessionHealthy = false;
  bool portalLoginMatched = true;
  bool casFormMatched = true;
  bool courseMatched = true;
  bool examMatched = true;
  bool passwordVisible = true;
  bool fieldsInSameForm = true;
  bool clickProbeMatchesExactWrapper = true;
  String? handshakeFailureReason;
  Duration selectorProbeDelay = Duration.zero;
  Duration geometryDelay = Duration.zero;
  String documentReadyState = 'complete';
  bool submitAcknowledged = true;
  bool switchDocumentAfterHandshakeReply = false;
  String? cancelScriptId;
  bool rejectUnknownNavigation = false;
  bool suppressUrl = false;
  bool selectorPresent = true;
  bool suppressWebMessage = false;
  int primaryClicks = 0;
  int submitCalls = 0;
  int handshakeCalls = 0;
  final List<String> selectorProbes = <String>[];
  final List<String> documentProbeSources = <String>[];
  String? _documentUrl;

  void setCurrent(String url) {
    _currentUrl = url;
    _documentUrl = url;
    if (!suppressUrl) _urlController.add(url);
  }

  /// Emits a URL event without replacing the document that script probes see.
  /// This models a stale navigation signal arriving before the WebView's
  /// current document has switched.
  void emitUrlOnly(String url) {
    _currentUrl = url;
    if (!suppressUrl) _urlController.add(url);
  }

  void _navigateTo(String url) {
    _currentUrl = url;
    _documentUrl = url;
    if (!suppressUrl) _urlController.add(url);
    _loadingController.add(JwLoadingState.loading);
    _loadingController.add(JwLoadingState.navigationCompleted);
  }

  @override
  Stream<String> get urlChanges => _urlController.stream;

  @override
  String? get currentUrlSnapshot => suppressUrl ? null : _currentUrl;

  @override
  Stream<JwLoadingState> get loadingStateChanges => _loadingController.stream;

  @override
  Stream<Object?> get webMessages => _webMessageController.stream;

  @override
  Widget get surface => const SizedBox();

  @override
  Future<void> awaitEventStreamReady() async {}

  @override
  Future<void> loadUrl(String url) async {
    if (rejectUnknownNavigation && !isJwNavigationAllowed(url)) {
      rejectUnknownNavigation = false;
      throw const JwCollectionException('navigation policy rejected');
    }
    lastLoadedUrl = url;
    _navigateTo(url);
  }

  @override
  Future<Object?> executeScript(String source) async {
    _lastSource = source;
    if (source.contains('jw.documentCompleteProbe') ||
        source.contains('jw.finalTargetProbe')) {
      documentProbeSources.add(source);
      var documentMatchesTarget = true;
      final expectedMatch = RegExp(
        r'const expected = ("(?:\\.|[^"])*");',
      ).firstMatch(source);
      if (expectedMatch != null) {
        final expected = jsonDecode(expectedMatch.group(1)!);
        if (expected is String) {
          final documentUrl = _documentUrl ?? '';
          documentMatchesTarget = _matchesGeneratedUrlPattern(
            source,
            expected,
            documentUrl,
          );
        }
      }
      final complete = documentReadyState == 'complete';
      if (source.contains('jw.documentCompleteProbe')) {
        return documentMatchesTarget && complete;
      }
      return documentMatchesTarget && complete && selectorPresent;
    }
    if (source.startsWith('Boolean(document.querySelector') ||
        source.contains('const urlMatches =') &&
            source.contains('document.querySelector(')) {
      if (selectorProbeDelay > Duration.zero) {
        await Future<void>.delayed(selectorProbeDelay);
      }
      final queryStart = source.indexOf('document.querySelector(');
      final open = queryStart + 'document.querySelector('.length;
      final close = source.indexOf(')', open);
      if (queryStart >= 0 && close > open) {
        try {
          final selector = jsonDecode(source.substring(open, close));
          if (selector is String) selectorProbes.add(selector);
        } on FormatException {
          // Keep the fake permissive for malformed probe source.
        }
      }
      var documentMatchesTarget = true;
      final expectedMatch = RegExp(
        r'const expected = ("(?:\\.|[^"])*");',
      ).firstMatch(source);
      if (expectedMatch != null) {
        final expected = jsonDecode(expectedMatch.group(1)!);
        if (expected is String) {
          final documentUrl = _documentUrl ?? '';
          documentMatchesTarget = _matchesGeneratedUrlPattern(
            source,
            expected,
            documentUrl,
          );
        }
      }
      return selectorPresent && documentMatchesTarget;
    }
    if (source.contains('input[name=username]') &&
        source.contains('||{value:""}).value')) {
      // CAS preselected-account read returns empty (no preset conflict).
      return '';
    }
    if (source.contains('scrollIntoView')) {
      if (geometryDelay > Duration.zero) {
        await Future<void>.delayed(geometryDelay);
      }
      if (!clickProbeMatchesExactWrapper ||
          !source.contains(
            "document.querySelector('#login-unified-wrapper')",
          )) {
        return null;
      }
      // SSO-entry geometry probe: visible + unobscured at a point.
      return <Object?, Object?>{
        'x': 300.0,
        'y': 400.0,
        'width': 100.0,
        'height': 40.0,
        'viewportWidth': 1024.0,
        'viewportHeight': 768.0,
        'visible': true,
        'unobscured': true,
      };
    }
    final entry = _matchRegisteredScript(source);
    if (entry == null) {
      throw const JwCollectionException('unregistered script');
    }
    return _handleScript(entry, _decodeArgs(source));
  }

  bool _matchesGeneratedUrlPattern(
    String source,
    String expected,
    String current,
  ) {
    if (!expected.endsWith('*')) return current == expected;
    final prefix = expected.substring(0, expected.length - 1);
    if (!source.contains('const prefix = expected.slice(0, -1);')) {
      // Keep the fake's pre-fix behavior so the source-level regression above
      // fails against a raw startsWith probe instead of masking the bug.
      return current.startsWith(prefix);
    }
    if (!current.startsWith(prefix)) return false;
    if (current.length == prefix.length) return true;
    final next = current.codeUnitAt(prefix.length);
    return next == 0x2f || next == 0x3f || next == 0x23;
  }

  MapEntry<String, String>? _matchRegisteredScript(String source) {
    // Extract the embedded script body between `(function(args) {` and
    // `})(payload)` so matching is unambiguous (the wrapper embeds the source
    // verbatim).
    const open = '(function(args) {';
    final openStart = source.indexOf(open);
    if (openStart < 0) return null;
    const close = '})(payload)';
    final closeStart = source.indexOf(close, openStart + open.length);
    if (closeStart < 0) return null;
    final body = source.substring(openStart + open.length, closeStart).trim();
    for (final entry in jwRegisteredScripts.entries) {
      if (body == entry.value.trim()) return entry;
    }
    return null;
  }

  Map<String, Object?> _decodeArgs(String source) {
    const marker = 'const payload = ';
    final start = source.indexOf(marker);
    if (start < 0) return <String, Object?>{};
    final valueStart = start + marker.length;
    // The JSON ends at the first `;` followed by a newline + `const send`.
    final end = source.indexOf(';', valueStart);
    if (end < 0) return <String, Object?>{};
    final json = source.substring(valueStart, end);
    try {
      final decoded = jsonDecode(json);
      return decoded is Map<String, Object?> ? decoded : <String, Object?>{};
    } on FormatException {
      return <String, Object?>{};
    }
  }

  Object? _handleScript(
    MapEntry<String, String> entry,
    Map<String, Object?> args,
  ) {
    final scriptId = entry.key;
    final reply = _replyFor(scriptId, args);
    _echoReply(reply, scriptId);
    if (scriptId == cancelScriptId) {
      cancelScriptId = null;
      throw const JwCollectionException('cancelled');
    }
    if (scriptId == 'jw.cas.inspect' && switchDocumentAfterHandshakeReply) {
      _documentUrl = _casUrl;
    }
    return true;
  }

  Map<String, Object?>? _replyFor(String scriptId, Map<String, Object?> args) {
    switch (scriptId) {
      case 'jw.cas.fillUsername':
        final text = _decodeSecret(args['secretBytes']);
        usernameFilled = text;
        return <String, Object?>{'filled': true};
      case 'jw.cas.fillPassword':
        final text = _decodeSecret(args['secretBytes']);
        passwordFilled = text;
        return {'filled': true};
      case 'jw.cas.submit':
        submitCalls++;
        if (!submitAcknowledged) {
          return {'submitted': false};
        }
        submitted = true;
        // The natural post-submit redirect lands on the JW home page.
        _navigateTo(_homeUrl);
        visitedHome = true;
        return {'submitted': true};
      case 'jw.cas.inspect':
        handshakeCalls++;
        if (handshakeFailureReason != null) {
          _echoError(handshakeFailureReason!);
          return null;
        }
        final isHomeDocument = _documentUrl == _homeUrl;
        return {
          'sessionHealthy': sessionHealthy && isHomeDocument,
          'needsUserLogin': !sessionHealthy || !isHomeDocument,
        };
      case 'jw.portal.login.inspect':
        if (handshakeFailureReason != null) {
          _echoError(handshakeFailureReason!);
          return null;
        }
        return {'matched': portalLoginMatched};
      case 'jw.cas.form.inspect':
        if (handshakeFailureReason != null) {
          _echoError(handshakeFailureReason!);
          return null;
        }
        return {
          'matched': casFormMatched && passwordVisible && fieldsInSameForm,
        };
      case 'jw.course.inspect':
        return {'matched': courseMatched};
      case 'jw.exam.inspect':
        return {'matched': examMatched};
      case 'jw.identity.verifyExpected':
        return {
          'authoritativeMatched': authoritativeMatched ?? identityAuthenticated,
          'authoritativeConflicted':
              authoritativeConflicted ?? identityConflict,
          'domMatched': domMatched ?? identityAuthenticated,
          'domConflicted': domConflicted ?? identityConflict,
          'storageMatched': storageMatched ?? identityAuthenticated,
          'storageConflicted': storageConflicted ?? identityConflict,
        };
      case 'jw.course.readContext':
        if (dataId == null || dataContextBizTypeId != '2') {
          _echoError('missing_course_data_context');
          return null;
        }
        return {'dataId': dataId};
      case 'jw.course.fetchGetData':
        lastGetDataArgs = Map<String, Object?>.from(args);
        if (getDataFailureReason != null) {
          _echoError(getDataFailureReason!);
          return null;
        }
        return {'text': getDataText};
      case 'jw.course.fetchDatum':
        datumScriptRuns++;
        lastDatumLessonIds = (args['lessonIds'] as List?)?.cast<Object?>();
        return {'text': datumText};
      case 'jw.exam.readTable':
        if (examHtml.split('<table id="exams">').length - 1 != 1) {
          _echoError('page_contract_changed');
          return null;
        }
        return {'html': examHtml};
      default:
        _echoError('script_failed');
        return null;
    }
  }

  String? _decodeSecret(Object? bytes) {
    if (bytes is! List) {
      secretTouchedAsPlaintext = true;
      return null;
    }
    return utf8.decode(List<int>.from(bytes), allowMalformed: false);
  }

  void _echoReply(Map<String, Object?>? result, String scriptId) {
    if (result == null || suppressWebMessage) return;
    final requestId = _capturedRequestId;
    if (requestId == null) return;
    _webMessageController.add(<String, Object?>{
      'kind': 'registeredScriptResult',
      'requestId': requestId,
      'result': result,
    });
  }

  void _echoError(String reason) {
    if (suppressWebMessage) return;
    final requestId = _capturedRequestId;
    if (requestId == null) return;
    _webMessageController.add(<String, Object?>{
      'kind': 'registeredScriptError',
      'requestId': requestId,
      'reason': reason,
    });
  }

  /// Extracts `const requestId = "<id>"` from the latest wrapper source.
  String? get _capturedRequestId {
    final source = _lastSource;
    if (source == null) return null;
    final marker = 'const requestId = "';
    final start = source.indexOf(marker);
    if (start < 0) return null;
    final valueStart = start + marker.length;
    final valueEnd = source.indexOf('"', valueStart);
    if (valueEnd < 0) return null;
    return source.substring(valueStart, valueEnd);
  }

  @override
  Future<void> dispatchPrimaryClick(Offset position) async {
    primaryClicks++;
    // Clicking the SSO entry navigates to the CAS login page.
    if (!visitedCas) {
      visitedCas = true;
      _navigateTo(_casUrl);
    }
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    if (failStop) throw StateError('stop failed');
  }

  @override
  Future<void> beginSubscriptions() async {}

  @override
  Future<void> disposeSubscriptions() async {
    subscriptionsDisposed = true;
  }

  @override
  Future<void> disposeControllerAndAwaitRelease() async {
    releaseCalls++;
    releaseBarrierAwaited = true;
    if (failReleaseAttempts > 0) {
      failReleaseAttempts--;
      throw StateError('release failed');
    }
    disposed = true;
  }

  @override
  Future<void> clearBrowsingDataAll() async {
    browsingCleared = true;
  }

  @override
  Future<void> dispose() async {
    await disposeControllerAndAwaitRelease();
  }
}
