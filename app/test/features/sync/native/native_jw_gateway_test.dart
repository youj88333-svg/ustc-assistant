// M7: `NativeJwGateway` unit tests against a fake controller seam.
//
// The gateway implements the `BridgeGateway` surface over the native
// WebView2 JW collector. These tests drive a fake `JwWebviewController`
// (production would use the plugin) and assert the Bridge-compatible poll
// shape: capabilities (fixed semester), start → poll events, resume/cancel,
// and terminal result / error code mapping.
//
// No real WebView, no network, no platform plugins.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/sync/data/bridge_client.dart';
import 'package:ustc_assistant_app/features/sync/domain/sync_state.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_web_session.dart';
import 'package:ustc_assistant_app/features/sync/native/native_jw_gateway.dart';

const _homeUrl = 'https://jw.ustc.edu.cn/home';
const _fixturesRoot = 'test/fixtures/jw';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, dynamic> courseDatum;
  late String examHtml;

  setUpAll(() {
    courseDatum =
        jsonDecode(File('$_fixturesRoot/course-datum.json').readAsStringSync())
            as Map<String, dynamic>;
    examHtml = File('$_fixturesRoot/exam-page.html').readAsStringSync();
  });

  group('NativeJwGateway fake-controller tests', () {
    test('capabilities returns the fixed configured semester', () async {
      final gateway = NativeJwGateway(
        controllerFactory: () async => FakeJwWebviewController(),
      );
      final capabilities = await gateway.capabilities();
      expect(capabilities.jwSemester.semesterId, kDefaultJwSemester.semesterId);
      expect(
        capabilities.jwSemester.semesterKey,
        kDefaultJwSemester.semesterKey,
      );
      expect(
        capabilities.jwSemester.displayName,
        kDefaultJwSemester.displayName,
      );
      await gateway.shutdown();
    });

    test(
      'startCollection emits starting/complete and a terminal result',
      () async {
        final controller = FakeJwWebviewController()
          ..authenticatedSession = true
          ..courseDatum = courseDatum
          ..examHtml = examHtml;
        final gateway = NativeJwGateway(
          controllerFactory: () async => controller,
        );

        final job = await gateway.startCollection(
          source: SyncSource.jw,
          accountId: 'acct_1',
          expectedUsername: 'ustc.student',
          jwSemester: kDefaultJwSemester,
        );
        expect(job.phase, 'starting');

        // Drain: poll until terminal.
        final poll = await _pollUntilTerminal(gateway, job.id);
        expect(poll.terminal, isTrue);
        expect(poll.result, isNotNull);
        expect(poll.result!['source'], 'ustc_jw');
        await gateway.shutdown();
      },
    );

    test(
      'startCollection reuse-session (goRoot redirects /home) completes',
      () async {
        final controller = FakeJwWebviewController()
          ..authenticatedSession = true
          ..courseDatum = courseDatum
          ..examHtml = examHtml;
        final gateway = NativeJwGateway(
          controllerFactory: () async => controller,
        );

        final job = await gateway.startCollection(
          source: SyncSource.jw,
          accountId: 'acct_1',
          expectedUsername: 'ustc.student',
          jwSemester: kDefaultJwSemester,
        );
        final poll = await _pollUntilTerminal(gateway, job.id);
        expect(poll.terminal, isTrue);
        expect(poll.errorCode, isNull);
        await gateway.shutdown();
      },
    );

    test('needs-login path pauses and resumeLogin lets it complete', () async {
      final controller = FakeJwWebviewController()
        ..authenticatedSession = false
        ..identityAuthenticated = true
        ..courseDatum = courseDatum
        ..examHtml = examHtml;
      final gateway = NativeJwGateway(
        controllerFactory: () async => controller,
      );

      final job = await gateway.startCollection(
        source: SyncSource.jw,
        accountId: 'acct_1',
        expectedUsername: 'ustc.student',
        jwSemester: kDefaultJwSemester,
      );

      // Wait until needs_user_login (the stream pauses for the user).
      final poll = await _pollForPhase(gateway, job.id, 'needs_user_login');
      expect(poll.lastPhase, 'needs_user_login');

      await gateway.resumeLogin(job.id, password: 'pw');
      final terminal = await _pollUntilTerminal(gateway, job.id);
      expect(terminal.terminal, isTrue);
      expect(terminal.result, isNotNull);
      await gateway.shutdown();
    });

    test('account mismatch maps to errorCode account_mismatch', () async {
      final controller = FakeJwWebviewController()
        ..authenticatedSession = false
        ..identityAuthenticated = false
        ..identityConflict = true;
      final gateway = NativeJwGateway(
        controllerFactory: () async => controller,
      );

      final job = await gateway.startCollection(
        source: SyncSource.jw,
        accountId: 'acct_1',
        expectedUsername: 'ustc.student',
        jwSemester: kDefaultJwSemester,
      );
      await _pollForPhase(gateway, job.id, 'needs_user_login');
      await gateway.resumeLogin(job.id, password: 'pw');
      final poll = await _pollUntilTerminal(gateway, job.id);
      expect(poll.terminal, isTrue);
      expect(poll.errorCode, 'account_mismatch');
      await gateway.shutdown();
    });

    test('cancel maps to errorCode cancelled', () async {
      final controller = FakeJwWebviewController()
        ..authenticatedSession = false;
      final gateway = NativeJwGateway(
        controllerFactory: () async => controller,
      );

      final job = await gateway.startCollection(
        source: SyncSource.jw,
        accountId: 'acct_1',
        expectedUsername: 'ustc.student',
        jwSemester: kDefaultJwSemester,
      );
      await _pollForPhase(gateway, job.id, 'needs_user_login');
      // Cancel unblocks the paused stream; the collector exits as cancelled.
      await gateway.cancel(job.id);
      final poll = await _pollUntilTerminal(gateway, job.id);
      expect(poll.terminal, isTrue);
      expect(poll.errorCode, 'cancelled');
      await gateway.shutdown();
    });

    test('unknown jobId makes poll/resume fail closed', () async {
      final gateway = NativeJwGateway(
        controllerFactory: () async => FakeJwWebviewController(),
      );
      await expectLater(gateway.poll('nope', 0), throwsA(anything));
      await expectLater(
        gateway.resumeLogin('nope', password: 'x'),
        throwsA(anything),
      );
      await gateway.shutdown();
    });

    test('diagnostics stream forwards privacy-safe adapter stages', () async {
      final collected = <String>[];
      final controller = FakeJwWebviewController()
        ..authenticatedSession = true
        ..courseDatum = courseDatum
        ..examHtml = examHtml;
      final gateway = NativeJwGateway(
        controllerFactory: () async => controller,
        safeDiagnostic: collected.add,
      );
      final streamSubscription = gateway.diagnostics.listen((event) {
        // Diagnostics never leak URL/account/query/DOM: stage names only.
        expect(event.contains('//'), isFalse, reason: 'no path leakage');
        expect(event.contains('http'), isFalse, reason: 'no URL leakage');
        expect(event.contains('PB'), isFalse, reason: 'no account leakage');
      });

      final job = await gateway.startCollection(
        source: SyncSource.jw,
        accountId: 'acct_1',
        expectedUsername: 'ustc.student',
        jwSemester: kDefaultJwSemester,
      );
      await _pollUntilTerminal(gateway, job.id);
      await streamSubscription.cancel();

      await gateway.shutdown();
      expect(collected, isNotEmpty);
      // Reuse-session path: the entry navigation stage is not emitted (the
      // page lands straight on /home), but the course/exam convergence and
      // fetch stages must be observable for debug acceptance.
      expect(
        collected
            .where((e) => e.startsWith('course_') || e.contains('fetched'))
            .toList(),
        isNotEmpty,
        reason: 'collection stages must be observable',
      );
      expect(
        collected.where((e) => e.contains('jw.course.home')).toList(),
        isNotEmpty,
        reason: 'course home convergence must be observable',
      );
    });

    testWidgets(
      'shutdown detaches mounted surface before controller disposal',
      (tester) async {
        final calls = <String>[];
        final controller = FakeJwWebviewController(calls: calls)
          ..authenticatedSession = true
          ..courseDatum = courseDatum
          ..examHtml = examHtml;
        final gateway = NativeJwGateway(
          controllerFactory: () async => controller,
        );
        await tester.pumpWidget(MaterialApp(home: gateway.surfaceHost.widget));
        final job = await gateway.startCollection(
          source: SyncSource.jw,
          accountId: 'opaque-account-a',
          expectedUsername: 'PB00000000',
          jwSemester: kDefaultJwSemester,
        );
        await _pollUntilTerminalWithPump(tester, gateway, job.id);
        final shutdown = gateway.shutdown();
        var shutdownSettled = false;
        // Observe settlement without consuming the original future's error;
        // the final await below must still surface any shutdown failure.
        unawaited(
          shutdown.then<void>(
            (_) {
              shutdownSettled = true;
            },
            onError: (Object _, StackTrace _) {
              shutdownSettled = true;
            },
          ),
        );
        await Future<void>.microtask(() {});
        expect(calls, isNot(contains('dispose')));
        await tester.pump();
        const maxAdditionalPumps = 8;
        var additionalPumps = 0;
        while (!shutdownSettled && additionalPumps < maxAdditionalPumps) {
          additionalPumps++;
          await tester.pump();
          // The async* collector cancellation schedules a root event that
          // fake-async pump does not service; this zero-duration event turn
          // advances it without introducing a wall-clock delay.
          await tester.runAsync(() => Future<void>(() {}));
        }
        expect(
          shutdownSettled,
          isTrue,
          reason:
              'shutdown did not settle after the detach acknowledgement '
              'and $maxAdditionalPumps additional fake-clock pumps',
        );
        await shutdown;
        expect(calls, <String>['stop', 'stop', 'clear', 'dispose']);
      },
    );

    testWidgets(
      'late controller creation after shutdown is disposed without attachment',
      (tester) async {
        final creation = Completer<FakeJwWebviewController>();
        final calls = <String>[];
        var factoryCalls = 0;
        final gateway = NativeJwGateway(
          controllerFactory: () {
            factoryCalls++;
            return creation.future;
          },
          controllerCreationTimeout: const Duration(milliseconds: 1),
        );

        await gateway.startCollection(
          source: SyncSource.jw,
          accountId: 'opaque-account-a',
          expectedUsername: 'PB00000000',
          jwSemester: kDefaultJwSemester,
        );
        await Future<void>.microtask(() {});
        expect(factoryCalls, 1);

        final shutdown = gateway.shutdown();
        Object? shutdownError;
        final shutdownFutureSettled = shutdown.then<void>(
          (_) {},
          onError: (Object error, StackTrace _) {
            shutdownError = error;
          },
        );
        // Elapse the gateway's bounded in-flight creation wait without using
        // wall-clock time. The factory completes only after that boundary.
        await tester.pump(const Duration(milliseconds: 1));

        final lateController = FakeJwWebviewController(calls: calls);
        creation.complete(lateController);
        for (var i = 0; i < 8; i++) {
          await tester.pump();
          await tester.runAsync(() => Future<void>(() {}));
        }

        await shutdownFutureSettled;
        expect(shutdownError, isA<TimeoutException>());
        expect(gateway.surfaceHost.isAttached, isFalse);
        expect(calls, <String>['stop', 'clear', 'dispose']);
      },
    );

    test(
      'controller factory receives one account partition per lifecycle',
      () async {
        final requestedAccounts = <String>[];
        var productionFactoryCalls = 0;
        final gateway = NativeJwGateway(
          userDataPathForAccount: (accountId) async {
            requestedAccounts.add(accountId);
            return 'test-udf/$accountId';
          },
          productionControllerFactory:
              ({required userDataPath, required safeDiagnostic}) async {
                productionFactoryCalls++;
                return FakeJwWebviewController()
                  ..authenticatedSession = true
                  ..courseDatum = courseDatum
                  ..examHtml = examHtml;
              },
        );
        final job = await gateway.startCollection(
          source: SyncSource.jw,
          accountId: 'opaque-account-a',
          expectedUsername: 'PB00000000',
          jwSemester: kDefaultJwSemester,
        );
        await _pollUntilTerminal(gateway, job.id);
        expect(requestedAccounts, ['opaque-account-a']);
        expect(productionFactoryCalls, 1);
        await expectLater(
          gateway.startCollection(
            source: SyncSource.jw,
            accountId: 'opaque-account-b',
            expectedUsername: 'PB00000001',
            jwSemester: kDefaultJwSemester,
          ),
          throwsA(isA<StateError>()),
        );
        expect(productionFactoryCalls, 1);
        expect(requestedAccounts, ['opaque-account-a']);
        await gateway.shutdown();
      },
    );
  });
}

Future<BridgeJobPoll> _pollUntilTerminal(
  NativeJwGateway gateway,
  String id,
) async {
  for (var i = 0; i < 200; i++) {
    final poll = await gateway.poll(id, 0);
    if (poll.terminal) return poll;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('job never reached terminal');
}

Future<BridgeJobPoll> _pollUntilTerminalWithPump(
  WidgetTester tester,
  NativeJwGateway gateway,
  String id,
) async {
  for (var i = 0; i < 200; i++) {
    final poll = await gateway.poll(id, 0);
    if (poll.terminal) return poll;
    await tester.pump(const Duration(milliseconds: 5));
    await tester.runAsync(() => Future<void>(() {}));
  }
  fail('job never reached terminal');
}

Future<BridgeJobPoll> _pollForPhase(
  NativeJwGateway gateway,
  String id,
  String phase,
) async {
  for (var i = 0; i < 200; i++) {
    final poll = await gateway.poll(id, 0);
    if (poll.lastPhase == phase) return poll;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('job never reached phase "$phase"');
}

/// A scripted fake [JwWebviewController] (reuses the adapter test fake pattern).
class FakeJwWebviewController implements JwWebviewController {
  FakeJwWebviewController({this.calls});

  final List<String>? calls;
  final _urlController = StreamController<String>.broadcast();
  final _loadingController = StreamController<JwLoadingState>.broadcast();
  final _webMessageController = StreamController<Object?>.broadcast();

  String? _currentUrl;
  String? _documentUrl;
  String? _lastSource;
  String documentReadyState = 'complete';
  bool identityAuthenticated = false;
  bool identityConflict = false;
  bool authenticatedSession = false;
  Map<String, dynamic> courseDatum = const {};
  String examHtml = '<table id="exams"></table>';
  bool _disposed = false;

  void setCurrent(String url) {
    _currentUrl = url;
    _documentUrl = url;
    _urlController.add(url);
  }

  void _navigateTo(String url) {
    _currentUrl = url;
    _documentUrl = url;
    _urlController.add(url);
    _loadingController.add(JwLoadingState.loading);
    _loadingController.add(JwLoadingState.navigationCompleted);
  }

  @override
  Stream<String> get urlChanges => _urlController.stream;

  @override
  String? get currentUrlSnapshot => _currentUrl;

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
    // Model the real server behavior: an authenticated session's loaded root
    // (or CAS-entry) redirects to /home; an unauthenticated session stays on
    // the login entry.
    if ((url == 'https://jw.ustc.edu.cn/' ||
            url == 'https://jw.ustc.edu.cn/ucas-sso/login') &&
        authenticatedSession) {
      _navigateTo(_homeUrl);
      return;
    }
    _navigateTo(url);
  }

  @override
  Future<Object?> executeScript(String source) async {
    _lastSource = source;
    if (source.contains('jw.selectorProbe') ||
        source.contains('jw.documentCompleteProbe') ||
        source.contains('jw.finalTargetProbe')) {
      final matches = _documentMatchesExpected(source);
      if (source.contains('jw.documentCompleteProbe')) {
        return matches && documentReadyState == 'complete';
      }
      if (source.contains('jw.finalTargetProbe')) {
        return matches && documentReadyState == 'complete';
      }
      return matches;
    }
    if (source.startsWith('Boolean(document.querySelector')) return true;
    if (source.contains('input[name=username]') &&
        source.contains('||{value:""}).value')) {
      return '';
    }
    if (source.contains('scrollIntoView')) {
      return <Object?, Object?>{
        'x': 300.0,
        'y': 400.0,
        'width': 100.0,
        'height': 40.0,
        'visible': true,
        'unobscured': true,
      };
    }
    final entry = _matchRegisteredScript(source);
    if (entry == null) return null;
    return _handleScript(entry);
  }

  bool _documentMatchesExpected(String source) {
    final expectedMatch = RegExp(
      r'const expected = ("(?:\\.|[^"])*");',
    ).firstMatch(source);
    if (expectedMatch == null) return true;
    final expected = jsonDecode(expectedMatch.group(1)!);
    if (expected is! String) return false;
    final documentUrl = _documentUrl ?? '';
    return expected.endsWith('*')
        ? documentUrl.startsWith(expected.substring(0, expected.length - 1))
        : documentUrl == expected;
  }

  MapEntry<String, String>? _matchRegisteredScript(String source) {
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

  Object? _handleScript(MapEntry<String, String> entry) {
    final requestId = _capturedRequestId;
    final result = _resultFor(entry.key);
    if (result == null) {
      // Unknown scripts echo an error so the adapter surfaces a clean failure.
      _webMessageController.add(<String, Object?>{
        'kind': 'registeredScriptError',
        'requestId': requestId,
        'reason': 'script_failed',
      });
      return true;
    }
    _webMessageController.add(<String, Object?>{
      'kind': 'registeredScriptResult',
      'requestId': requestId,
      'result': result,
    });
    return true;
  }

  Map<String, Object?>? _resultFor(String scriptId) {
    switch (scriptId) {
      case 'jw.cas.fillUsername':
      case 'jw.cas.fillPassword':
        return <String, Object?>{'filled': true};
      case 'jw.cas.submit':
        _navigateTo('https://jw.ustc.edu.cn/home');
        return <String, Object?>{'submitted': true};
      case 'jw.cas.inspect':
        return <String, Object?>{
          'sessionHealthy': _documentUrl == _homeUrl,
          'needsUserLogin': _documentUrl != _homeUrl,
        };
      case 'jw.portal.login.inspect':
        return <String, Object?>{
          'matched': _documentUrl == 'https://jw.ustc.edu.cn/login',
        };
      case 'jw.cas.form.inspect':
        return <String, Object?>{
          'matched': _documentUrl == 'https://id.ustc.edu.cn/cas/login',
        };
      case 'jw.course.inspect':
        return <String, Object?>{
          'matched':
              _documentUrl == 'https://jw.ustc.edu.cn/for-std/course-table',
        };
      case 'jw.exam.inspect':
        return <String, Object?>{
          'matched':
              _documentUrl == 'https://jw.ustc.edu.cn/for-std/exam-arrange',
        };
      case 'jw.identity.verifyExpected':
        return <String, Object?>{
          'authoritativeMatched': identityAuthenticated,
          'authoritativeConflicted': identityConflict,
          'domMatched': identityAuthenticated,
          'domConflicted': identityConflict,
          'storageMatched': identityAuthenticated,
          'storageConflicted': identityConflict,
        };
      case 'jw.course.readContext':
        return <String, Object?>{'dataId': 'data-ctx-1'};
      case 'jw.course.fetchGetData':
        return <String, Object?>{
          'text': jsonEncode(<String, Object?>{
            'lessonIds': <Object?>[101, 102],
          }),
        };
      case 'jw.course.fetchDatum':
        return <String, Object?>{'text': jsonEncode(courseDatum)};
      case 'jw.exam.readTable':
        return <String, Object?>{'html': examHtml};
      default:
        return null;
    }
  }

  String? get _capturedRequestId {
    final source = _lastSource;
    if (source == null) return null;
    const marker = 'const requestId = "';
    final start = source.indexOf(marker);
    if (start < 0) return null;
    final valueStart = start + marker.length;
    final valueEnd = source.indexOf('"', valueStart);
    if (valueEnd < 0) return null;
    return source.substring(valueStart, valueEnd);
  }

  @override
  Future<void> dispatchPrimaryClick(Offset position) async {
    _navigateTo('https://id.ustc.edu.cn/cas/login');
  }

  @override
  Future<void> stop() async {
    calls?.add('stop');
  }

  @override
  Future<void> clearBrowsingDataAll() async {
    calls?.add('clear');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    calls?.add('dispose');
    await Future.wait<void>(<Future<void>>[
      _urlController.close(),
      _loadingController.close(),
      _webMessageController.close(),
    ]);
  }
}
