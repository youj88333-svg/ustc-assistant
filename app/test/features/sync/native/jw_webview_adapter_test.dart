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

    setUp(() {
      controller = FakeJwWebviewController();
      adapter = JwWebViewAdapter(
        controllerFactory: () async => controller,
        loginTimeout: const Duration(seconds: 5),
        responseTimeout: const Duration(seconds: 3),
        safeDiagnostic: (event) {},
      );
    });

    test('gotoRoot loads the allowlisted root and reports navigation complete',
        () async {
      controller.setCurrent('https://jw.ustc.edu.cn/');
      await adapter.gotoRoot();
      expect(controller.lastLoadedUrl, jwRootUrl);
      expect(controller.disposed, isFalse);
    });

    test('isAuthenticatedHome reflects currentUrl', () async {
      controller.setCurrent(_homeUrl);
      expect(await adapter.isAuthenticatedHome, isTrue);
      controller.setCurrent(_loginEntryUrl);
      expect(await adapter.isAuthenticatedHome, isFalse);
    });

    group('CAS login fill', () {
      test('fills username + password, submits, awaits home, verifies identity',
          () async {
        controller.setCurrent(_loginEntryUrl);
        controller.identityAuthenticated = true;

        await adapter.fillLogin(const LoginCredentials(
          username: 'ustc.student',
          password: 'pw-secret',
        ));

        expect(controller.usernameFilled, 'ustc.student');
        expect(controller.passwordFilled, 'pw-secret');
        expect(controller.submitted, isTrue);
        expect(controller.visitedCas, isTrue);
        expect(controller.visitedHome, isTrue);
        expect(controller.secretTouchedAsPlaintext, isFalse);
      });

      test('account mismatch on identity conflict maps to JwAccountMismatchException',
          () async {
        controller.setCurrent(_loginEntryUrl);
        controller.identityAuthenticated = false;
        controller.identityConflict = true;

        await expectLater(
          adapter.fillLogin(const LoginCredentials(username: 'other.user')),
          throwsA(isA<JwAccountMismatchException>()),
        );
      });

      test('missing password fills username and submits', () async {
        controller.setCurrent(_loginEntryUrl);
        controller.identityAuthenticated = true;

        await adapter.fillLogin(
          const LoginCredentials(username: 'ustc.student'),
        );
        expect(controller.usernameFilled, 'ustc.student');
        expect(controller.passwordFilled, isNull);
        expect(controller.submitted, isTrue);
      });
    });

    group('waitForAuthenticatedHome', () {
      test('throws JwLoginTimeoutException when home never converges',
          () async {
        await expectLater(
          adapter.waitForAuthenticatedHome(const Duration(milliseconds: 200)),
          throwsA(isA<JwLoginTimeoutException>()),
        );
      });

      test('succeeds when home URL + inspect handshake converge', () async {
        controller
          ..setCurrent(_homeUrl)
          ..sessionHealthy = true;
        await adapter.waitForAuthenticatedHome(const Duration(seconds: 2));
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

      test('fetchCourseDatum runs get-data + datum with the right args',
          () async {
        controller
          ..setCurrent(_courseTableUrl)
          ..datumText = '{"result":{"lesson":[{"name":"x"}]}}';
        final datum = await adapter.fetchCourseDatum(
          semesterId: 461,
          dataId: 'data-ctx-1',
          referer: _courseTableUrl,
        );
        expect((datum['result'] as Map<String, dynamic>)['lesson'], isNotEmpty);
        expect(controller.lastGetDataSemester, 461);
        expect(controller.lastDatumLessonIds, <Object?>[101, 102]);
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

    test('close disposes the controller and clears browsing data', () async {
      await adapter.gotoRoot();
      controller.setCurrent('https://jw.ustc.edu.cn/');
      await adapter.close();
      expect(controller.disposed, isTrue);
      expect(controller.browsingCleared, isTrue);
    });
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
      expect(
        isJwNavigationAllowed('https://jw.ustc.edu.cn/admin'),
        isFalse,
      );
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
class FakeJwWebviewController implements JwWebviewController {
  final _urlController = StreamController<String>.broadcast();
  final _loadingController = StreamController<JwLoadingState>.broadcast();
  final _webMessageController = StreamController<Object?>.broadcast();

  String? _currentUrl;
  String? _lastSource;
  bool disposed = false;
  bool browsingCleared = false;

  // Scripted scenario state.
  String? dataId;
  String getDataText = '{"lessonIds":[101,102]}';
  String datumText = '{"result":{"lesson":[]}}';
  String? getDataFailureReason;
  String examHtml = '<table id="exams"></table>';

  String? lastLoadedUrl;
  int? lastGetDataSemester;
  List<Object?>? lastDatumLessonIds;
  String? usernameFilled;
  String? passwordFilled;
  bool submitted = false;
  bool visitedCas = false;
  bool visitedHome = false;
  bool secretTouchedAsPlaintext = false;

  bool identityAuthenticated = false;
  bool identityConflict = false;
  bool sessionHealthy = false;
  bool rejectUnknownNavigation = false;

  void setCurrent(String url) {
    _currentUrl = url;
    _urlController.add(url);
  }

  void _navigateTo(String url) {
    _currentUrl = url;
    _urlController.add(url);
    _loadingController.add(JwLoadingState.loading);
    _loadingController.add(JwLoadingState.navigationCompleted);
  }

  @override
  Stream<String> get urlChanges => _urlController.stream;

  @override
  String? get currentUrlSnapshot => _currentUrl;

  @override
  Stream<JwLoadingState> get loadingStateChanges =>
      _loadingController.stream;

  @override
  Stream<Object?> get webMessages => _webMessageController.stream;

  @override
  Widget get surface => const SizedBox();

  @override
  Future<void> awaitEventStreamReady() async {}

  @override
  Future<void> loadUrl(String url) async {
    if (rejectUnknownNavigation &&
        !isJwNavigationAllowed(url)) {
      rejectUnknownNavigation = false;
      throw const JwCollectionException('navigation policy rejected');
    }
    lastLoadedUrl = url;
    _navigateTo(url);
  }

  @override
  Future<Object?> executeScript(String source) async {
    _lastSource = source;
    if (source.startsWith('Boolean(document.querySelector')) {
      // DOM-ready presence probe: scripted as present.
      return true;
    }
    if (source.contains('input[name=username]') &&
        source.contains('||{value:""}).value')) {
      // CAS preselected-account read returns empty (no preset conflict).
      return '';
    }
    if (source.contains('scrollIntoView')) {
      // SSO-entry geometry probe: visible + unobscured at a point.
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
    if (entry == null) {
      throw const JwCollectionException('unregistered script');
    }
    return _handleScript(entry, _decodeArgs(source));
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
    final body = source
        .substring(openStart + open.length, closeStart)
        .trim();
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

  Object? _handleScript(MapEntry<String, String> entry, Map<String, Object?> args) {
    final scriptId = entry.key;
    final reply = _replyFor(scriptId, args);
    _echoReply(reply, scriptId);
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
        submitted = true;
        // The natural post-submit redirect lands on the JW home page.
        _navigateTo(_homeUrl);
        visitedHome = true;
        return {'submitted': true};
      case 'jw.cas.inspect':
        return {
          'sessionHealthy': sessionHealthy,
          'needsUserLogin': !sessionHealthy,
        };
      case 'jw.identity.verifyExpected':
        return {
          'authoritativeMatched': identityAuthenticated,
          'authoritativeConflicted': identityConflict,
          'domMatched': identityAuthenticated,
          'domConflicted': identityConflict,
          'storageMatched': identityAuthenticated,
          'storageConflicted': identityConflict,
        };
      case 'jw.course.readContext':
        if (dataId == null) {
          _echoError('missing_course_data_context');
          return null;
        }
        return {'dataId': dataId};
      case 'jw.course.fetchGetData':
        lastGetDataSemester = args['semesterId'] as int?;
        if (getDataFailureReason != null) {
          _echoError(getDataFailureReason!);
          return null;
        }
        return {'text': getDataText};
      case 'jw.course.fetchDatum':
        lastDatumLessonIds = (args['lessonIds'] as List?)?.cast<Object?>();
        return {'text': datumText};
      case 'jw.exam.readTable':
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
    if (result == null) return;
    final requestId = _capturedRequestId;
    if (requestId == null) return;
    _webMessageController.add(<String, Object?>{
      'kind': 'registeredScriptResult',
      'requestId': requestId,
      'result': result,
    });
  }

  void _echoError(String reason) {
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
    // Clicking the SSO entry navigates to the CAS login page.
    if (!visitedCas) {
      visitedCas = true;
      _navigateTo(_casUrl);
    }
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> clearBrowsingDataAll() async {
    browsingCleared = true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
