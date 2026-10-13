import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/jobs/public_query_coordinator.dart';
import 'package:ustc_assistant_m0/source/public_http.dart';
import 'package:ustc_assistant_m0/source/public_source_contract.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('PublicQueryCoordinator internal public-query-v1', () {
    test(
      'delivery accepts only issued results and revocation invalidates an already read page',
      () async {
        final harness = await _openHarness();
        await harness.coordinator.setIcourseConsent(true);
        final result = await harness.coordinator.searchCourses(
          '合成课程',
          pageSize: 1,
        );
        await harness.coordinator.ensurePublicResult(result);
        await expectLater(
          harness.coordinator.ensurePublicResult(
            PublicQueryResult(
              coverage: result.coverage,
              candidates: result.candidates,
              next: result.next,
            ),
          ),
          throwsA(_publicFailure(PublicFailureCode.staleReference)),
        );
        await harness.coordinator.setIcourseConsent(false);
        await expectLater(
          harness.coordinator.ensurePublicResult(result),
          throwsA(_publicFailure(PublicFailureCode.staleReference)),
        );
      },
    );

    test(
      'review slices preserve character positions and reject a changed text budget',
      () async {
        final text = List<String>.filled(5001, '评').join();
        final harness = await _openHarness(
          parser: _SyntheticParser(reviewText: text),
        );
        await harness.coordinator.setIcourseConsent(true);
        final listing = await harness.coordinator.searchCourses(
          '合成点评',
          pageSize: 1,
        );
        final ref = listing.candidates.single.reference;
        var page = await harness.coordinator.readCourseSlice(ref, pageSize: 1);
        final parts = <String>[page.document!.reviews.single.text];
        expect(parts.single.runes.length, 2400);
        await expectLater(
          harness.coordinator.readCourseSlice(
            ref,
            pageSize: 1,
            maxCharacters: 2399,
            cursor: page.next,
          ),
          throwsA(_publicFailure(PublicFailureCode.staleReference)),
        );
        final fresh = await harness.coordinator.searchCourses(
          '合成点评',
          pageSize: 1,
        );
        final freshRef = fresh.candidates.single.reference;
        page = await harness.coordinator.readCourseSlice(freshRef, pageSize: 1);
        parts.clear();
        parts.add(page.document!.reviews.single.text);
        while (page.next != null) {
          page = await harness.coordinator.readCourseSlice(
            freshRef,
            pageSize: 1,
            cursor: page.next,
          );
          parts.add(page.document!.reviews.single.text);
        }
        expect(parts.join(), text);
        expect(parts.map((part) => part.runes.length), [2400, 2400, 201]);
        await harness.coordinator.ensurePublicResult(page);
      },
    );
    test(
      'a shared JW lease blocks online lookup while local knowledge stays available',
      () async {
        final harness = await _openHarness();
        await harness.coordinator.setIcourseConsent(true);

        final jwLease = harness.leases.acquire();
        await expectLater(
          harness.coordinator.searchCourses('synthetic'),
          throwsA(_publicFailure(PublicFailureCode.busy)),
        );
        final local = await harness.store.publicStore.searchKnowledge('没有匹配材料');

        expect(local.candidates, isEmpty);
        expect(harness.sessions.requests, isEmpty);
        expect(harness.leases.isBusy, isTrue);
        jwLease.release();
      },
    );

    test(
      'iCourse consent is checked before a session or request is created',
      () async {
        final harness = await _openHarness();

        await expectLater(
          harness.coordinator.searchCourses('synthetic'),
          throwsA(_publicFailure(PublicFailureCode.consentRequired)),
        );

        expect(harness.sessions.sessions, isEmpty);
        expect(harness.sessions.requests, isEmpty);
        expect(harness.leases.isBusy, isFalse);
      },
    );

    test(
      'a candidate reference reads its course using the requested term and sort',
      () async {
        final harness = await _openHarness();
        await harness.coordinator.setIcourseConsent(true);

        final listing = await harness.coordinator.searchCourses(
          '线性代数',
          pageSize: 1,
        );
        final result = await harness.coordinator.readCourse(
          listing.candidates.single.reference,
          term: '20251',
          sort: CourseReviewSort.newest,
        );
        final courseRequests = harness.sessions.requests
            .where((uri) => uri.path.startsWith('/course/'))
            .toList();

        expect(result.document, isNotNull);
        expect(courseRequests, hasLength(2));
        expect(courseRequests[0].queryParameters, {'sort_by': 'pubtime_desc'});
        expect(courseRequests[1].queryParameters, {
          'sort_by': 'pubtime_desc',
          'term': '20251',
        });
        expect(harness.sessions.requests.first.path, '/search/');
      },
    );

    test(
      'final response URIs reject changed query intent and accept harmless normalization',
      () async {
        final queryHarness = await _openHarness();
        await queryHarness.coordinator.setIcourseConsent(true);
        queryHarness.sessions.rewriteResponseUri = (uri) => uri.replace(
          queryParameters: {...uri.queryParameters, 'q': '改写后的查询'},
        );

        await expectLater(
          queryHarness.coordinator.searchCourses('原查询'),
          throwsA(_publicFailure(PublicFailureCode.unsafeTarget)),
        );
        expect(queryHarness.sessions.requests, hasLength(1));
        expect(queryHarness.coordinator.view.returned, 0);
        expect(queryHarness.leases.isBusy, isFalse);

        final termHarness = await _openHarness();
        await termHarness.coordinator.setIcourseConsent(true);
        final listing = await termHarness.coordinator.searchCourses(
          '学期课程',
          pageSize: 1,
        );
        termHarness.sessions.rewriteResponseUri = (uri) {
          if (uri.path.startsWith('/course/') &&
              uri.queryParameters.containsKey('term')) {
            final parameters = Map<String, String>.from(uri.queryParameters)
              ..remove('term');
            return uri.replace(queryParameters: parameters);
          }
          return uri;
        };

        await expectLater(
          termHarness.coordinator.readCourse(
            listing.candidates.single.reference,
            term: '20251',
          ),
          throwsA(_publicFailure(PublicFailureCode.unsafeTarget)),
        );
        expect(
          termHarness.sessions.requests.last.queryParameters['term'],
          '20251',
        );
        expect(termHarness.coordinator.view.returned, 0);
        expect(termHarness.leases.isBusy, isFalse);

        final normalizedHarness = await _openHarness();
        await normalizedHarness.coordinator.setIcourseConsent(true);
        normalizedHarness.sessions.rewriteResponseUri = (uri) => uri.replace(
          path: '${uri.path}/',
          queryParameters: {...uri.queryParameters, 's': ''},
        );
        final campus = await normalizedHarness.coordinator.browseCampus(
          CampusColumn.teachNotice,
          pageSize: 1,
        );
        expect(campus.candidates, hasLength(1));
        normalizedHarness.sessions.rewriteResponseUri = null;
        final courseListing = await normalizedHarness.coordinator.searchCourses(
          '默认排序',
          pageSize: 1,
        );
        normalizedHarness.sessions.rewriteResponseUri = (uri) {
          if (!uri.path.startsWith('/course/')) return uri;
          final parameters = Map<String, String>.from(uri.queryParameters)
            ..remove('sort_by')
            ..['page'] = '1'
            ..['term'] = '';
          return uri.replace(queryParameters: parameters);
        };
        final normalizedCourse = await normalizedHarness.coordinator.readCourse(
          courseListing.candidates.single.reference,
          sort: CourseReviewSort.upvote,
          pageSize: 1,
        );
        expect(normalizedCourse.document, isNotNull);
        expect(normalizedHarness.leases.isBusy, isFalse);
      },
    );

    test(
      'small listing pages consume cached upstream items before requesting the next page',
      () async {
        final harness = await _openHarness();
        await harness.coordinator.setIcourseConsent(true);

        final titles = <String>[];
        var page = await harness.coordinator.searchCourses('合成课程', pageSize: 3);
        titles.addAll(page.candidates.map((item) => item.title));
        expect(page.next, isNotNull);
        expect(harness.sessions.requests, hasLength(1));

        page = await harness.coordinator.searchCourses(
          '合成课程',
          pageSize: 3,
          cursor: page.next,
        );
        titles.addAll(page.candidates.map((item) => item.title));
        expect(page.coverage.cached, isTrue);
        expect(harness.sessions.requests, hasLength(1));

        page = await harness.coordinator.searchCourses(
          '合成课程',
          pageSize: 3,
          cursor: page.next,
        );
        titles.addAll(page.candidates.map((item) => item.title));
        expect(page.coverage.cached, isTrue);
        expect(harness.sessions.requests, hasLength(1));

        page = await harness.coordinator.searchCourses(
          '合成课程',
          pageSize: 3,
          cursor: page.next,
        );
        titles.addAll(page.candidates.map((item) => item.title));
        expect(page.candidates, hasLength(1));
        expect(page.coverage.cached, isTrue);
        expect(harness.sessions.requests, hasLength(1));

        page = await harness.coordinator.searchCourses(
          '合成课程',
          pageSize: 3,
          cursor: page.next,
        );
        titles.addAll(page.candidates.map((item) => item.title));

        expect(harness.sessions.requests, hasLength(2));
        expect(titles, [
          for (var index = 0; index < 13; index++) '课程-${13486 + index}',
        ]);
      },
    );

    test(
      'cursors reject changed keywords, page size, reference, and sort',
      () async {
        final harness = await _openHarness();
        await harness.coordinator.setIcourseConsent(true);

        final listing = await harness.coordinator.searchCourses(
          '课程甲',
          pageSize: 1,
        );
        final listingCursor = listing.next!;
        await expectLater(
          harness.coordinator.searchCourses(
            '课程乙',
            pageSize: 1,
            cursor: listingCursor,
          ),
          throwsA(_publicFailure(PublicFailureCode.staleReference)),
        );
        final refreshedListing = await harness.coordinator.searchCourses(
          '课程甲',
          pageSize: 1,
        );
        await expectLater(
          harness.coordinator.searchCourses(
            '课程甲',
            pageSize: 2,
            cursor: refreshedListing.next,
          ),
          throwsA(_publicFailure(PublicFailureCode.staleReference)),
        );

        Future<(PublicReference, PublicReference, PublicCursor)>
        freshReviewCursor() async {
          final candidates = await harness.coordinator.searchCourses(
            '课程甲',
            pageSize: 2,
          );
          final firstReference = candidates.candidates[0].reference;
          final otherReference = candidates.candidates[1].reference;
          final reviewPage = await harness.coordinator.readCourse(
            firstReference,
            sort: CourseReviewSort.newest,
            pageSize: 1,
          );
          return (firstReference, otherReference, reviewPage.next!);
        }

        var review = await freshReviewCursor();
        final continuation = await harness.coordinator.readCourse(
          review.$1,
          sort: CourseReviewSort.newest,
          pageSize: 1,
          cursor: review.$3,
        );
        expect(continuation.coverage.cached, isTrue);

        review = await freshReviewCursor();
        await expectLater(
          harness.coordinator.readCourse(
            review.$1,
            sort: CourseReviewSort.oldest,
            pageSize: 1,
            cursor: review.$3,
          ),
          throwsA(_publicFailure(PublicFailureCode.staleReference)),
        );

        review = await freshReviewCursor();
        await expectLater(
          harness.coordinator.readCourse(
            review.$1,
            sort: CourseReviewSort.newest,
            pageSize: 2,
            cursor: review.$3,
          ),
          throwsA(_publicFailure(PublicFailureCode.staleReference)),
        );

        review = await freshReviewCursor();
        await expectLater(
          harness.coordinator.readCourse(
            review.$2,
            sort: CourseReviewSort.newest,
            pageSize: 1,
            cursor: review.$3,
          ),
          throwsA(_publicFailure(PublicFailureCode.staleReference)),
        );
      },
    );

    test(
      'long single reviews and campus articles continue without truncating content',
      () async {
        final parser = _SyntheticParser(
          reviewText: List<String>.filled(25010, '评').join(),
          articleText: List<String>.filled(25020, '文').join(),
        );
        final harness = await _openHarness(parser: parser);
        await harness.coordinator.setIcourseConsent(true);

        final courseListing = await harness.coordinator.searchCourses(
          '长点评',
          pageSize: 1,
        );
        var coursePage = await harness.coordinator.readCourse(
          courseListing.candidates.single.reference,
          pageSize: 1,
        );
        final reviewParts = <String>[coursePage.document!.reviews.single.text];
        expect(reviewParts.single.runes.length, 12000);
        expect(coursePage.next, isNotNull);
        coursePage = await harness.coordinator.readCourse(
          courseListing.candidates.single.reference,
          pageSize: 1,
          cursor: coursePage.next,
        );
        reviewParts.add(coursePage.document!.reviews.single.text);
        expect(coursePage.next, isNotNull);
        coursePage = await harness.coordinator.readCourse(
          courseListing.candidates.single.reference,
          pageSize: 1,
          cursor: coursePage.next,
        );
        reviewParts.add(coursePage.document!.reviews.single.text);
        expect(coursePage.next, isNull);
        expect(reviewParts.join(), parser.reviewText);

        final campusListing = await harness.coordinator.browseCampus(
          CampusColumn.teachNotice,
          pageSize: 1,
        );
        var articlePage = await harness.coordinator.readCampusArticle(
          campusListing.candidates.single.reference,
        );
        final articleParts = <String>[articlePage.document!.markdown];
        expect(articlePage.next, isNotNull);
        articlePage = await harness.coordinator.readCampusArticle(
          campusListing.candidates.single.reference,
          cursor: articlePage.next,
        );
        articleParts.add(articlePage.document!.markdown);
        expect(articlePage.next, isNotNull);
        articlePage = await harness.coordinator.readCampusArticle(
          campusListing.candidates.single.reference,
          cursor: articlePage.next,
        );
        articleParts.add(articlePage.document!.markdown);
        expect(articlePage.next, isNull);
        expect(articleParts.join(), parser.articleMarkdown);
      },
    );

    test(
      'the final 8000 characters of one long review retain locator and incomplete coverage',
      () async {
        final parser = _SyntheticParser(
          reviewText: List<String>.filled(20000, '评').join(),
        );
        final harness = await _openHarness(parser: parser);
        await harness.coordinator.setIcourseConsent(true);

        final listing = await harness.coordinator.searchCourses(
          '两万字点评',
          pageSize: 1,
        );
        final first = await harness.coordinator.readCourse(
          listing.candidates.single.reference,
          pageSize: 1,
        );
        final tail = await harness.coordinator.readCourse(
          listing.candidates.single.reference,
          pageSize: 1,
          cursor: first.next,
        );

        expect(
          tail.document!.reviews.single.text,
          List<String>.filled(8000, '评').join(),
        );
        expect(tail.document!.reviews.single.locator, contains('合成点评'));
        expect(tail.document!.reviews.single.locator, contains('12000–20000'));
        expect(tail.coverage.complete, isFalse);
        expect(tail.coverage.truncated, isTrue);
      },
    );

    test(
      'cancel during a pending response discards its late result and releases the lease',
      () async {
        final harness = await _openHarness();
        final responseGate = Completer<void>();
        final entered = Completer<void>();
        harness.sessions.gateNextGet = responseGate;
        harness.sessions.enteredNextGet = entered;

        final pending = harness.coordinator.browseCampus(
          CampusColumn.teachNotice,
        );
        final cancelled = expectLater(
          pending,
          throwsA(_publicFailure(PublicFailureCode.cancelled)),
        );
        await entered.future;
        expect(harness.leases.isBusy, isTrue);

        final local = await harness.store.publicStore.searchKnowledge(
          '本地知识未命中',
        );
        expect(local.candidates, isEmpty);

        final cancelling = harness.coordinator.cancel();
        await harness.sessions.sessions.single.closed.future;
        responseGate.complete();
        await cancelling;
        await cancelled;

        expect(harness.coordinator.view.phase, PublicJobPhase.idle);
        expect(harness.coordinator.view.returned, 0);
        expect(harness.leases.isBusy, isFalse);
        final next = await harness.coordinator.browseCampus(
          CampusColumn.teachNotice,
        );
        expect(next.candidates, hasLength(3));
      },
    );

    test(
      'failed drain enters recovery with its lease held until retry succeeds',
      () async {
        final harness = await _openHarness();
        harness.sessions.closeFailuresForNext = 2;

        await expectLater(
          harness.coordinator.browseCampus(CampusColumn.teachNotice),
          throwsA(_publicFailure(PublicFailureCode.cleanupPending)),
        );
        expect(harness.coordinator.view.phase, PublicJobPhase.recovery);
        expect(
          harness.coordinator.view.failure,
          PublicFailureCode.cleanupPending,
        );
        expect(harness.leases.isBusy, isTrue);

        await harness.coordinator.retryRecovery();

        expect(harness.coordinator.view.phase, PublicJobPhase.idle);
        expect(harness.leases.isBusy, isFalse);
        final next = await harness.coordinator.browseCampus(
          CampusColumn.teachNotice,
        );
        expect(next.candidates, hasLength(3));
      },
    );

    test(
      'concurrent recovery retries are mutually exclusive and block admission until drain ends',
      () async {
        final harness = await _openHarness();
        harness.sessions.closeFailuresForNext = 2;
        await expectLater(
          harness.coordinator.browseCampus(CampusColumn.teachNotice),
          throwsA(_publicFailure(PublicFailureCode.cleanupPending)),
        );
        expect(harness.coordinator.view.phase, PublicJobPhase.recovery);
        expect(harness.leases.isBusy, isTrue);

        final closeGate = Completer<void>();
        final closeEntered = Completer<void>();
        harness.sessions.closeGateOnce = closeGate;
        harness.sessions.closeEnteredOnce = closeEntered;
        final firstRetry = harness.coordinator.retryRecovery();
        await closeEntered.future;

        await expectLater(
          harness.coordinator.retryRecovery(),
          throwsA(_publicFailure(PublicFailureCode.busy)),
        );
        await expectLater(
          harness.coordinator.browseCampus(CampusColumn.teachNotice),
          throwsA(_publicFailure(PublicFailureCode.busy)),
        );
        expect(harness.sessions.sessions, hasLength(1));
        expect(harness.leases.isBusy, isTrue);

        closeGate.complete();
        await firstRetry;
        expect(harness.coordinator.view.phase, PublicJobPhase.idle);
        expect(harness.leases.isBusy, isFalse);
        final next = await harness.coordinator.browseCampus(
          CampusColumn.teachNotice,
        );
        expect(next.candidates, hasLength(3));
      },
    );

    test(
      'finance keyword search and FAQ report unavailable rather than empty results',
      () async {
        final harness = await _openHarness();

        await expectLater(
          harness.coordinator.browseCampus(CampusColumn.financeFaq),
          throwsA(_publicFailure(PublicFailureCode.unavailable)),
        );
        await expectLater(
          harness.coordinator.browseCampus(
            CampusColumn.financeNotice,
            keywords: '奖学金',
          ),
          throwsA(_publicFailure(PublicFailureCode.unavailable)),
        );

        expect(harness.sessions.sessions, isEmpty);
        expect(harness.sessions.requests, isEmpty);
      },
    );

    test(
      'references and cursors expire and consent revocation invalidates iCourse state',
      () async {
        final clock = _MutableClock(DateTime.utc(2026, 10, 12));
        final harness = await _openHarness(clock: clock);
        await harness.coordinator.setIcourseConsent(true);

        final listing = await harness.coordinator.searchCourses(
          '时效',
          pageSize: 1,
        );
        final reference = listing.candidates.single.reference;
        clock.advance(const Duration(minutes: 11));
        await expectLater(
          harness.coordinator.readCourse(reference),
          throwsA(_publicFailure(PublicFailureCode.staleReference)),
        );

        final cursorListing = await harness.coordinator.searchCourses(
          '游标时效',
          pageSize: 1,
        );
        final cursorAfterExpiry = cursorListing.next!;
        clock.advance(const Duration(minutes: 11));
        await expectLater(
          harness.coordinator.searchCourses(
            '游标时效',
            pageSize: 1,
            cursor: cursorAfterExpiry,
          ),
          throwsA(_publicFailure(PublicFailureCode.staleReference)),
        );

        final fresh = await harness.coordinator.searchCourses(
          '撤销同意',
          pageSize: 1,
        );
        final requestsBeforeRevoke = harness.sessions.requests.length;
        await harness.coordinator.setIcourseConsent(false);
        await expectLater(
          harness.coordinator.readCourse(fresh.candidates.single.reference),
          throwsA(_publicFailure(PublicFailureCode.consentRequired)),
        );
        await harness.coordinator.setIcourseConsent(true);
        await expectLater(
          harness.coordinator.readCourse(fresh.candidates.single.reference),
          throwsA(_publicFailure(PublicFailureCode.staleReference)),
        );
        expect(harness.sessions.requests, hasLength(requestsBeforeRevoke));
      },
    );

    test(
      'owner and source generation changes invalidate previously issued references',
      () async {
        final harness = await _openHarness();
        final listing = await harness.coordinator.browseCampus(
          CampusColumn.teachNotice,
          pageSize: 2,
        );
        final generationBound = listing.candidates[0].reference;
        expect(listing.candidates, hasLength(2));

        await harness.store.customStatement(
          "UPDATE public_sources SET generation=generation+1 WHERE source='campus'",
        );
        await expectLater(
          harness.coordinator.readCampusArticle(generationBound),
          throwsA(_publicFailure(PublicFailureCode.staleReference)),
        );

        final afterGeneration = await harness.coordinator.browseCampus(
          CampusColumn.teachNotice,
          pageSize: 2,
        );
        final ownerBound = afterGeneration.candidates[1].reference;

        await harness.store.customStatement(
          'UPDATE jw_state SET owner_id=? WHERE singleton=1',
          ['jw-owner-${List<String>.filled(32, "a").join()}'],
        );
        await expectLater(
          harness.coordinator.readCampusArticle(ownerBound),
          throwsA(_publicFailure(PublicFailureCode.staleReference)),
        );
        expect(harness.sessions.requests, hasLength(2));
      },
    );
  });
}

Future<_Harness> _openHarness({
  _MutableClock? clock,
  _SyntheticParser? parser,
}) async {
  final actualClock = clock ?? _MutableClock(DateTime.utc(2026, 10, 12));
  final leases = WorkLeasePool();
  final sessions = _SyntheticSessions();
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _SyntheticOwnership(),
    clock: actualClock,
  );
  await store.initialize();
  final coordinator = PublicQueryCoordinator(
    store: store.publicStore,
    leases: leases,
    clock: actualClock,
    parser: parser ?? _SyntheticParser(),
    sessionFactory: sessions.open,
    jobTimeout: const Duration(seconds: 3),
    drainTimeout: const Duration(seconds: 1),
  );
  addTearDown(() async {
    if (coordinator.view.phase != PublicJobPhase.closed) {
      await coordinator.close();
    }
    await store.close();
  });
  return _Harness(
    store: store,
    leases: leases,
    coordinator: coordinator,
    sessions: sessions,
  );
}

Matcher _publicFailure(PublicFailureCode code) => isA<PublicFailure>().having(
  (failure) => failure.code,
  'failure code',
  code,
);

final class _Harness {
  const _Harness({
    required this.store,
    required this.leases,
    required this.coordinator,
    required this.sessions,
  });

  final JwStore store;
  final WorkLeasePool leases;
  final PublicQueryCoordinator coordinator;
  final _SyntheticSessions sessions;
}

final class _MutableClock implements AppClock {
  _MutableClock(this.nowUtc);

  @override
  DateTime nowUtc;

  void advance(Duration duration) {
    nowUtc = nowUtc.add(duration);
  }
}

final class _SyntheticOwnership implements AssetOwnership {
  @override
  bool get isHeld => true;

  @override
  void ensureHeld() {}
}

final class _SyntheticParser implements PublicSourceParser {
  _SyntheticParser({String? reviewText, String? articleText})
    : reviewText = reviewText ?? List<String>.filled(24010, '评').join(),
      articleText = articleText ?? List<String>.filled(24020, '文').join();

  final String reviewText;
  final String articleText;
  String get articleMarkdown => '# 合成文章\n\n$articleText';

  @override
  SourcePublicPage courses(String html, Uri uri) {
    final upstreamPage = int.tryParse(uri.queryParameters['page'] ?? '1') ?? 1;
    final first = (upstreamPage - 1) * 10;
    final items = List<SourcePublicItem>.generate(10, (offset) {
      final id = 13486 + first + offset;
      final teacher = '合成教师$id';
      return SourcePublicItem(
        key: '$id:$teacher',
        title: '课程-$id',
        uri: Uri.parse('https://icourse.club/course/$id/'),
        provider: PublicProvider.icourse,
        course: PublicCourseInfo(
          courseKey: '$id',
          title: '课程-$id',
          teacher: teacher,
          terms: const [PublicTerm(code: '20251', label: '合成学期')],
        ),
      );
    });
    final next = upstreamPage == 1
        ? uri.replace(queryParameters: {...uri.queryParameters, 'page': '2'})
        : null;
    return SourcePublicPage(items: items, nextPage: next, totalReported: 20);
  }

  @override
  SourcePublicPage campus(String html, Uri uri, CampusColumn column) {
    return SourcePublicPage(
      items: List<SourcePublicItem>.generate(3, (index) {
        final id = 23001 + index;
        return SourcePublicItem(
          key: 'notice:$id',
          title: '合成公告$id',
          uri: Uri.parse(
            'https://www.teach.ustc.edu.cn/notice/synthetic/$id.html',
          ),
          provider: PublicProvider.teach,
          snippet: '合成公告摘要',
        );
      }),
    );
  }

  @override
  SourcePublicDocument course(String html, Uri uri) {
    final id = RegExp(r'^/course/([0-9]+)/$').firstMatch(uri.path)!.group(1)!;
    return SourcePublicDocument(
      provider: PublicProvider.icourse,
      title: '课程-$id',
      uri: uri,
      markdown: '# 课程-$id',
      course: PublicCourseInfo(
        courseKey: id,
        title: '课程-$id',
        teacher: '合成教师$id',
        terms: const [PublicTerm(code: '20251', label: '合成学期')],
        reviewCount: 1,
      ),
      reviews: [PublicReview(text: reviewText, locator: '合成点评', term: '20251')],
    );
  }

  @override
  SourcePublicDocument article(String html, Uri uri, PublicProvider provider) =>
      SourcePublicDocument(
        provider: provider,
        title: '合成文章',
        uri: uri,
        markdown: articleMarkdown,
      );
}

final class _SyntheticSessions {
  final List<_SyntheticSession> sessions = [];
  final List<Uri> requests = [];
  int closeFailuresForNext = 0;
  Completer<void>? gateNextGet;
  Completer<void>? enteredNextGet;
  Completer<void>? closeGateOnce;
  Completer<void>? closeEnteredOnce;
  Uri Function(Uri uri)? rewriteResponseUri;

  PublicHttpSession open(PublicSource source) {
    final session = _SyntheticSession(
      this,
      closeFailures: closeFailuresForNext,
      gate: gateNextGet,
      entered: enteredNextGet,
    );
    closeFailuresForNext = 0;
    gateNextGet = null;
    enteredNextGet = null;
    sessions.add(session);
    return session;
  }
}

final class _SyntheticSession implements PublicHttpSession {
  _SyntheticSession(
    this.factory, {
    required int closeFailures,
    required this.gate,
    required this.entered,
    // Public fixture parameter intentionally differs from its private field.
    // ignore: prefer_initializing_formals
  }) : _closeFailures = closeFailures;

  final _SyntheticSessions factory;
  final Completer<void>? gate;
  final Completer<void>? entered;
  final Completer<void> closed = Completer<void>();
  int _closeFailures;
  bool _isClosed = false;

  @override
  Future<PublicHtmlPage> get(Uri uri) async {
    factory.requests.add(uri);
    if (entered != null && !entered!.isCompleted) entered!.complete();
    if (gate != null) await gate!.future;
    final responseUri = factory.rewriteResponseUri?.call(uri) ?? uri;
    return PublicHtmlPage(uri: responseUri, html: uri.toString());
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;
    final gate = factory.closeGateOnce;
    if (gate != null) {
      factory.closeGateOnce = null;
      final entered = factory.closeEnteredOnce;
      factory.closeEnteredOnce = null;
      if (entered != null && !entered.isCompleted) entered.complete();
      await gate.future;
    }
    if (_closeFailures > 0) {
      _closeFailures--;
      throw StateError('synthetic drain failure');
    }
    _isClosed = true;
    if (!closed.isCompleted) closed.complete();
  }
}
