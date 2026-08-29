// M3: `JwCollector` state-machine tests against a scripted `FakeJwWebPage`.
//
// Covers all 10 scenarios in `docs/plan-webview-minimal-m3.md` §5. No real
// WebView, no network, no platform plugins — the fake is injected and
// scripted per case. The bundle-parity test (scenario 10) is the hard gate:
// the complete-event bundle's canonical digest must equal the M2 oracle
// digest `f858a385...`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/sync/native/_jw_identity.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_collector.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_web_page.dart';
import 'package:ustc_assistant_app/features/sync/native/source_collection_gateway.dart';

const _fixturesRoot = 'test/fixtures/jw';

// Fixed identity fields matching the Python oracle fixture exactly (same as
// the M2 oracle-equality test).
const _bundleId = '00000000-0000-0000-0000-000000000000';
// 2026-08-22T12:00:00+08:00 == 2026-08-22T04:00:00Z.
final _collectedAt = DateTime.utc(2026, 8, 22, 4, 0, 0);
const _accountId = 'acct_fixture';
const _producer = <String, String>{
  'name': 'ustc_assistant_python',
  'version': '0.1.0',
  'platform': 'windows',
};
const _jobId = 'job-test-0001';

final _semester = JwSemesterConfig(
  semesterId: 461,
  semesterKey: '2026fall',
  displayName: '2026 秋季学期',
);

const _homeUrl = 'https://jw.ustc.edu.cn/home';
const _nonHomeUrl = 'https://jw.ustc.edu.cn/login';
const _casNonHomeUrl = 'https://id.ustc.edu.cn/login';
const _courseTableUrl = 'https://jw.ustc.edu.cn/for-std/course-table';
const _dataId = 'data-ctx-123';

/// Collect all events from [stream] until it closes (terminal event).
Future<List<SourceCollectionEvent>> collectEvents(
  Stream<SourceCollectionEvent> stream,
) {
  return stream.toList();
}

/// Canonical SHA-256 digest of a bundle (reuses `canonicalJsonEncode`).
String canonicalDigest(Map<String, dynamic> bundle) {
  return sha256.convert(utf8.encode(canonicalJsonEncode(bundle))).toString();
}

/// The full event phase sequence (for asserting event order).
List<String> phases(List<SourceCollectionEvent> events) =>
    events.map((e) => e.phase).toList();

/// Assert the event sequence is monotonic and gap-free starting at 0.
void expectMonotonicSequence(List<SourceCollectionEvent> events) {
  for (var i = 0; i < events.length; i++) {
    expect(events[i].sequence, i, reason: 'sequence not monotonic at index $i');
    expect(events[i].jobId, _jobId, reason: 'jobId mismatch at index $i');
  }
}

void main() {
  group('JwCollector state machine', () {
    late Map<String, dynamic> courseDatum;
    late String examHtml;
    late String oracleDigest;

    setUpAll(() {
      courseDatum =
          jsonDecode(
                File('$_fixturesRoot/course-datum.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      examHtml = File('$_fixturesRoot/exam-page.html').readAsStringSync();
      final oracleBundle =
          jsonDecode(
                File('$_fixturesRoot/oracle-bundle.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      oracleDigest = canonicalDigest(oracleBundle);
    });

    JwCollector buildCollector(FakeJwWebPage Function() pageFactory) {
      return JwCollector(
        pageFactory: pageFactory,
        producer: _producer,
        bundleId: _bundleId,
        collectedAt: _collectedAt,
        jobId: _jobId,
      );
    }

    test('1. reuse-session: gotoRoot already /home -> complete', () async {
      final fake = FakeJwWebPage(
        rootUrl: _homeUrl,
        casUrl: _homeUrl,
        courseDatum: courseDatum,
        examHtml: examHtml,
      );
      final collector = buildCollector(() => fake);
      final events = await collectEvents(
        collector.startJwCollection(accountId: _accountId, semester: _semester),
      );
      expectMonotonicSequence(events);
      expect(phases(events).last, 'complete');
      expect(phases(events), contains('collecting'));
      // Reuse-session emits the JW-session-reuse status.
      expect(
        events.whereType<CollectionStatus>().map((e) => e.message).toList(),
        contains('Reused the existing USTC JW browser session.'),
      );
      expect(fake.wentToCas, isFalse, reason: 'should not visit CAS on reuse');
    });

    test('2. cas-reuse: root non-home -> cas /home -> complete', () async {
      final fake = FakeJwWebPage(
        rootUrl: _nonHomeUrl,
        casUrl: _homeUrl,
        courseDatum: courseDatum,
        examHtml: examHtml,
      );
      final collector = buildCollector(() => fake);
      final events = await collectEvents(
        collector.startJwCollection(accountId: _accountId, semester: _semester),
      );
      expectMonotonicSequence(events);
      expect(phases(events).last, 'complete');
      expect(fake.wentToCas, isTrue);
      expect(
        events.whereType<CollectionStatus>().map((e) => e.message).toList(),
        contains('Reused the existing USTC CAS session.'),
      );
    });

    test(
      '3. needs-login-then-resume: non-home -> cas non-home -> resume -> complete',
      () async {
        final fake = FakeJwWebPage(
          rootUrl: _nonHomeUrl,
          casUrl: _casNonHomeUrl,
          postLoginUrl: _homeUrl,
          courseDatum: courseDatum,
          examHtml: examHtml,
        );
        final collector = buildCollector(() => fake);
        final events = <SourceCollectionEvent>[];
        final sub = collector
            .startJwCollection(accountId: _accountId, semester: _semester)
            .listen(events.add);
        // Wait for the needs_user_login event before resuming.
        await _waitForPhase(events, 'needs_user_login');
        expect(fake.fillLoginCalled, isFalse);
        await collector.resumeLogin(_jobId, password: 'pw');
        await sub.asFuture(); // stream closes on terminal
        expectMonotonicSequence(events);
        expect(phases(events).last, 'complete');
        expect(fake.fillLoginCalled, isTrue);
        // Sequence must contain needs_user_login then complete.
        final phaseList = phases(events);
        expect(phaseList, contains('needs_user_login'));
        expect(
          phaseList.indexOf('needs_user_login'),
          lessThan(phaseList.indexOf('complete')),
        );
      },
    );

    test(
      '4. login-timeout: needs-login -> resume -> waitForHome throws -> failed',
      () async {
        final fake = FakeJwWebPage(
          rootUrl: _nonHomeUrl,
          casUrl: _casNonHomeUrl,
          postLoginUrl: _homeUrl,
          waitForHomeThrows: const JwLoginTimeoutException('timed out'),
          courseDatum: courseDatum,
          examHtml: examHtml,
        );
        final collector = buildCollector(() => fake);
        final events = <SourceCollectionEvent>[];
        final sub = collector
            .startJwCollection(accountId: _accountId, semester: _semester)
            .listen(events.add);
        await _waitForPhase(events, 'needs_user_login');
        await collector.resumeLogin(_jobId, password: 'pw');
        await sub.asFuture();
        expectMonotonicSequence(events);
        expect(phases(events).last, 'failed');
        expect(
          events.whereType<CollectionFailed>().single.errorCode,
          'login_timeout',
        );
      },
    );

    test(
      '5. account-mismatch: verify username mismatch -> failed account_mismatch',
      () async {
        final fake = FakeJwWebPage(
          rootUrl: _nonHomeUrl,
          casUrl: _casNonHomeUrl,
          postLoginUrl: _homeUrl,
          fillLoginThrows: const JwAccountMismatchException('wrong account'),
          courseDatum: courseDatum,
          examHtml: examHtml,
        );
        final collector = buildCollector(() => fake);
        final events = <SourceCollectionEvent>[];
        final sub = collector
            .startJwCollection(accountId: _accountId, semester: _semester)
            .listen(events.add);
        await _waitForPhase(events, 'needs_user_login');
        await collector.resumeLogin(_jobId, password: 'pw');
        await sub.asFuture();
        expectMonotonicSequence(events);
        expect(phases(events).last, 'failed');
        expect(
          events.whereType<CollectionFailed>().single.errorCode,
          'account_mismatch',
        );
      },
    );

    test(
      '6. course-fetch-fail: fetchCourseDatum missing lessonIds -> failed',
      () async {
        final fake = FakeJwWebPage(
          rootUrl: _homeUrl,
          casUrl: _homeUrl,
          courseDatumFetchThrows: const JwCollectionException(
            'no lessons found',
          ),
          courseDatum: courseDatum,
          examHtml: examHtml,
        );
        final collector = buildCollector(() => fake);
        final events = await collectEvents(
          collector.startJwCollection(
            accountId: _accountId,
            semester: _semester,
          ),
        );
        expectMonotonicSequence(events);
        expect(phases(events).last, 'failed');
        expect(
          events.whereType<CollectionFailed>().single.errorCode,
          'collection_failed',
        );
      },
    );

    test('7. exam-missing: fetchExamHtml throws -> failed', () async {
      final fake = FakeJwWebPage(
        rootUrl: _homeUrl,
        casUrl: _homeUrl,
        courseDatum: courseDatum,
        examHtml: examHtml,
        examHtmlFetchThrows: const JwCollectionException('table#exams missing'),
      );
      final collector = buildCollector(() => fake);
      final events = await collectEvents(
        collector.startJwCollection(accountId: _accountId, semester: _semester),
      );
      expectMonotonicSequence(events);
      expect(phases(events).last, 'failed');
      expect(
        events.whereType<CollectionFailed>().single.errorCode,
        'collection_failed',
      );
    });

    test('8. cancel-during-collect: cancel mid-collect -> cancelled', () async {
      final fake = FakeJwWebPage(
        rootUrl: _homeUrl,
        casUrl: _homeUrl,
        courseDatum: courseDatum,
        examHtml: examHtml,
      );
      final collector = buildCollector(() => fake);
      final events = <SourceCollectionEvent>[];
      final completer = Completer<void>();
      final sub = collector
          .startJwCollection(accountId: _accountId, semester: _semester)
          .listen(events.add, onDone: completer.complete);
      // Cancel once the collector reaches the "Collecting course data" status
      // (mid-collect checkpoint), then let the state machine observe it.
      await _waitForPhaseMessage(
        events,
        'Collecting course data for configured semester',
      );
      await collector.cancel(_jobId);
      await completer.future;
      await sub.cancel();
      expectMonotonicSequence(events);
      expect(phases(events).last, 'cancelled');
      expect(events.whereType<CollectionCancelled>(), isNotEmpty);
    });

    test(
      'cancel during page failure emits cancelled instead of failed',
      () async {
        final page = FakeJwWebPage(
          rootUrl: _homeUrl,
          casUrl: _homeUrl,
          courseDatum: courseDatum,
          examHtml: examHtml,
          blockCourseFailure: true,
        );
        final collector = buildCollector(() => page);
        final events = <SourceCollectionEvent>[];
        final subscription = collector
            .startJwCollection(
              accountId: 'account',
              expectedUsername: 'PB00000000',
              semester: _semester,
            )
            .listen(events.add);

        await page.courseStarted.future;
        await collector.cancel(collector.activeJobId!);
        page.failCourse();
        await subscription.asFuture<void>();

        expect(events.last, isA<CollectionCancelled>());
        expect(events.whereType<CollectionFailed>(), isEmpty);
        expect(events.whereType<CollectionComplete>(), isEmpty);
      },
    );

    test(
      '9. single-active-job: second concurrent start rejected (bridge_busy)',
      () async {
        // First job pauses at needs_user_login (stays active).
        final fake1 = FakeJwWebPage(
          rootUrl: _nonHomeUrl,
          casUrl: _casNonHomeUrl,
          postLoginUrl: _homeUrl,
          courseDatum: courseDatum,
          examHtml: examHtml,
        );
        final collector = buildCollector(() => fake1);
        final events1 = <SourceCollectionEvent>[];
        final sub1 = collector
            .startJwCollection(accountId: _accountId, semester: _semester)
            .listen(events1.add);
        await _waitForPhase(events1, 'needs_user_login');

        // Second concurrent start must be rejected synchronously (the page
        // factory is never even invoked — the busy gate returns early).
        final events2 = await collectEvents(
          collector.startJwCollection(
            accountId: _accountId,
            semester: _semester,
          ),
        );
        expect(events2, hasLength(1));
        expect(events2.single, isA<CollectionFailed>());
        expect((events2.single as CollectionFailed).errorCode, bridgeBusyCode);

        // Clean up the first job.
        await collector.cancel(_jobId);
        await sub1.asFuture();
      },
    );

    test(
      '10. bundle-parity: complete bundle canonical digest == oracle digest',
      () async {
        final fake = FakeJwWebPage(
          rootUrl: _homeUrl,
          casUrl: _homeUrl,
          courseDatum: courseDatum,
          examHtml: examHtml,
        );
        final collector = buildCollector(() => fake);
        final events = await collectEvents(
          collector.startJwCollection(
            accountId: _accountId,
            semester: _semester,
          ),
        );
        expectMonotonicSequence(events);
        expect(phases(events).last, 'complete');
        final complete = events.whereType<CollectionComplete>().single;
        final digest = canonicalDigest(complete.bundle);
        expect(
          digest,
          equals(oracleDigest),
          reason:
              'bundle digest must match the M2 oracle digest '
              '$oracleDigest but was $digest',
        );
        // Sanity: the oracle digest begins with f858a385 (per plan §5 #10).
        expect(oracleDigest, startsWith('f858a385'));
      },
    );
  });

  group('URL helpers parity', () {
    test('buildGetDataUrl matches the Python layout', () {
      final url = buildGetDataUrl(461, 'ctx-1');
      final parsed = Uri.parse(url);
      expect(parsed.host, jwHost);
      expect(parsed.path, courseGetDataPath);
      expect(parsed.queryParameters['bizTypeId'], '2');
      expect(parsed.queryParameters['semesterId'], '461');
      expect(parsed.queryParameters['dataId'], 'ctx-1');
    });

    test('extractDataId round-trips through buildGetDataUrl', () {
      final url = buildGetDataUrl(461, 'ctx-xyz');
      expect(extractDataId(url), 'ctx-xyz');
    });

    test('extractDataId rejects non-get-data URLs', () {
      expect(
        () => extractDataId('https://jw.ustc.edu.cn/home'),
        throwsArgumentError,
      );
    });

    test('extractDataId rejects missing dataId', () {
      final url = Uri.https(jwHost, courseGetDataPath).toString();
      expect(() => extractDataId(url), throwsArgumentError);
    });

    test('isAuthenticatedHomeUrl matches /home and variants', () {
      expect(isAuthenticatedHomeUrl('https://jw.ustc.edu.cn/home'), isTrue);
      expect(isAuthenticatedHomeUrl('https://jw.ustc.edu.cn/home?x=1'), isTrue);
      expect(isAuthenticatedHomeUrl('https://jw.ustc.edu.cn/home/'), isTrue);
      expect(isAuthenticatedHomeUrl('https://jw.ustc.edu.cn/login'), isFalse);
    });

    test('buildGetDataUrl rejects empty dataId', () {
      expect(() => buildGetDataUrl(461, ''), throwsArgumentError);
    });

    test('isGetDataUrl recognizes a built get-data URL', () {
      expect(isGetDataUrl(buildGetDataUrl(461, 'x')), isTrue);
      expect(isGetDataUrl('https://jw.ustc.edu.cn/home'), isFalse);
    });
  });
}

/// Wait (polling the events list) until a [phase] event appears, with a
/// timeout. The collector's fake methods are synchronous-ish, so events
/// arrive on microtasks; we yield to let them drain.
Future<void> _waitForPhase(
  List<SourceCollectionEvent> events,
  String phase,
) async {
  const maxIterations = 10000;
  for (var i = 0; i < maxIterations; i++) {
    if (events.any((e) => e.phase == phase)) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('phase "$phase" never appeared; events so far: ${phases(events)}');
}

/// Wait (polling the events list) until a [CollectionStatus] with a message
/// containing [substring] appears, with a timeout.
Future<void> _waitForPhaseMessage(
  List<SourceCollectionEvent> events,
  String substring,
) async {
  const maxIterations = 10000;
  for (var i = 0; i < maxIterations; i++) {
    if (events.whereType<CollectionStatus>().any(
      (e) => e.message.contains(substring),
    )) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
  }
  fail(
    'status message containing "$substring" never appeared; '
    'events so far: ${phases(events)}',
  );
}

/// A scripted [JwWebPage] used to drive the collector's state machine in
/// tests. Each navigation step sets [currentUrl] to a preset value; the
/// success path returns the real fixtures.
class FakeJwWebPage implements JwWebPage {
  FakeJwWebPage({
    required this.rootUrl,
    required this.casUrl,
    this.postLoginUrl,
    required this.courseDatum,
    required this.examHtml,
    this.fillLoginThrows,
    this.waitForHomeThrows,
    this.courseDatumFetchThrows,
    this.examHtmlFetchThrows,
    this.blockCourseFailure = false,
  });

  /// URL reported after [gotoRoot].
  final String rootUrl;

  /// URL reported after [gotoCasEntry].
  final String casUrl;

  /// URL reported after a successful login wait (the post-login home). If
  /// null, the page stays at [casUrl] after login (login did not reach home).
  final String? postLoginUrl;

  /// Full course datum returned by [fetchCourseDatum] on the success path.
  final Map<String, dynamic> courseDatum;

  /// Exam HTML returned by [fetchExamHtml] on the success path.
  final String examHtml;

  /// If set, [fillLogin] throws this (e.g. account mismatch).
  final Object? fillLoginThrows;

  /// If set, [waitForAuthenticatedHome] throws this (e.g. login timeout).
  final Object? waitForHomeThrows;

  /// If set, [fetchCourseDatum] throws this (e.g. missing lessonIds).
  final Object? courseDatumFetchThrows;

  /// If set, [fetchExamHtml] throws this (e.g. table#exams missing).
  final Object? examHtmlFetchThrows;

  /// If true, [fetchCourseDatum] waits until [failCourse] completes with a
  /// collection error, allowing cancellation to race the page failure.
  final bool blockCourseFailure;

  String _currentUrl = '';
  bool wentToCas = false;
  bool fillLoginCalled = false;
  final courseStarted = Completer<void>();
  final _courseFailure = Completer<void>();

  void failCourse() {
    if (!_courseFailure.isCompleted) {
      _courseFailure.completeError(
        const JwCollectionException('course page failed'),
      );
    }
  }

  @override
  Future<String> get currentUrl async => _currentUrl;

  @override
  Future<void> gotoRoot() async {
    _currentUrl = rootUrl;
  }

  @override
  Future<void> gotoCasEntry() async {
    wentToCas = true;
    _currentUrl = casUrl;
  }

  @override
  Future<void> gotoCourseTable() async {
    _currentUrl = _courseTableUrl;
  }

  @override
  Future<void> gotoExamArrange() async {
    _currentUrl = examEntryUrl;
  }

  @override
  Future<bool> get isAuthenticatedHome async =>
      isAuthenticatedHomeUrl(_currentUrl);

  @override
  Future<void> fillLogin(LoginCredentials credentials) async {
    fillLoginCalled = true;
    // Simulate navigating to the CAS login page form first.
    if (fillLoginThrows != null) {
      throw fillLoginThrows!;
    }
  }

  @override
  Future<void> waitForAuthenticatedHome(Duration timeout) async {
    if (waitForHomeThrows != null) {
      throw waitForHomeThrows!;
    }
    if (postLoginUrl != null) {
      _currentUrl = postLoginUrl!;
    }
  }

  @override
  Future<String> resolveCourseDataId(Duration timeout) async {
    // Mirror the Python expect_response: the page navigates to the course
    // table and a get-data request is intercepted. We return a fixed dataId.
    _currentUrl = _courseTableUrl;
    return _dataId;
  }

  @override
  Future<Map<String, dynamic>> fetchCourseDatum({
    required int semesterId,
    required String dataId,
    required String referer,
  }) async {
    if (blockCourseFailure) {
      if (!courseStarted.isCompleted) courseStarted.complete();
      await _courseFailure.future;
    }
    // Yield so an external cancel() can interleave before the next checkpoint.
    await Future<void>.delayed(Duration.zero);
    if (courseDatumFetchThrows != null) {
      throw courseDatumFetchThrows!;
    }
    // Return a deep copy so the caller cannot mutate the shared fixture.
    return jsonDecode(jsonEncode(courseDatum)) as Map<String, dynamic>;
  }

  @override
  Future<String> fetchExamHtml(Duration timeout) async {
    // Yield so an external cancel() can interleave before the next checkpoint.
    await Future<void>.delayed(Duration.zero);
    _currentUrl = examEntryUrl;
    if (examHtmlFetchThrows != null) {
      throw examHtmlFetchThrows!;
    }
    return examHtml;
  }

  @override
  Future<void> close() async {}
}
