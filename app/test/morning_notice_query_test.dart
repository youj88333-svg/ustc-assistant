import 'package:flutter_test/flutter_test.dart';

import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/morning_notice_contract.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/jobs/morning_notice_query.dart';

void main() {
  group('parseMorningPublishedDay', () {
    test('accepts only complete supported dates and date-times', () {
      expect(
        parseMorningPublishedDay('2026-10-14'),
        DateTime.utc(2026, 10, 14),
      );
      expect(
        parseMorningPublishedDay('2026/10/14'),
        DateTime.utc(2026, 10, 14),
      );
      expect(parseMorningPublishedDay('2026年10月4日'), DateTime.utc(2026, 10, 4));
      expect(
        parseMorningPublishedDay('2026-10-14 23:59:59'),
        DateTime.utc(2026, 10, 14),
      );
      expect(
        parseMorningPublishedDay('2026/10/14T08:05Z'),
        DateTime.utc(2026, 10, 14),
      );
      expect(
        parseMorningPublishedDay('2026年10月14日 08:05:01+08:00'),
        DateTime.utc(2026, 10, 14),
      );
    });

    test('rejects missing, partial, invalid, and embedded dates', () {
      for (final input in <String?>[
        null,
        '',
        '10-14',
        '2026-2-14',
        '2026/2/14',
        '2026-02-29',
        '2026/13/01',
        '2026年2月30日',
        '2026-10-14 24:00',
        '发布日期：2026-10-14',
        '2026-10-14 通知',
      ]) {
        expect(parseMorningPublishedDay(input), isNull, reason: input);
      }
    });
  });

  group('MorningNoticeQuery', () {
    final day = DateTime.utc(2026, 10, 14);

    test(
      'keeps only the requested day and marks unknown dates incomplete',
      () async {
        final source =
            _FakePublicPort(
              clock: FixedClock(DateTime.utc(2026, 10, 15, 1)),
            )..setPages(CampusColumn.teachNotice, [
              [
                _candidate('match', PublicProvider.teach, '2026-10-14'),
                _candidate('other-day', PublicProvider.teach, '2026-10-13'),
                _candidate('missing-date', PublicProvider.teach, null),
                _candidate('invalid-date', PublicProvider.teach, '2026-02-30'),
              ],
            ]);

        final batch = await MorningNoticeQuery(
          source: source,
          clock: source.clock,
        ).collect(day);

        expect(batch.day, DateTime.utc(2026, 10, 14));
        expect(batch.notices.map((notice) => notice.title), ['match']);
        expect(batch.notices.single.publishedDay, DateTime.utc(2026, 10, 14));
        expect(batch.notices.single.excerpt, '正文-match');
        expect(batch.coverage[0].provider, PublicProvider.teach);
        expect(batch.coverage[0].pages, 1);
        expect(batch.coverage[0].matched, 1);
        expect(batch.coverage[0].unknownDates, 2);
        expect(batch.coverage[0].complete, isFalse);
        expect(batch.coverage[1].provider, PublicProvider.finance);
        expect(batch.coverage[1].complete, isTrue);
        expect(source.browseCalls.map((call) => call.$1), [
          CampusColumn.teachNotice,
          CampusColumn.financeNotice,
        ]);
      },
    );

    test(
      'deduplicates repeated pinned rows and stops after five pages',
      () async {
        final pinned = _candidate('pinned', PublicProvider.teach, '2026-10-14');
        final source =
            _FakePublicPort(
              clock: FixedClock(DateTime.utc(2026, 10, 15, 1)),
            )..setPages(CampusColumn.teachNotice, [
              [_candidate('first', PublicProvider.teach, '2026-10-14'), pinned],
              [
                pinned,
                _candidate('second', PublicProvider.teach, '2026-10-14'),
              ],
              [_candidate('third', PublicProvider.teach, '2026-10-14')],
              [_candidate('fourth', PublicProvider.teach, '2026-10-14')],
              [_candidate('fifth', PublicProvider.teach, '2026-10-14')],
              [
                _candidate(
                  'sixth-after-limit',
                  PublicProvider.teach,
                  '2026-10-14',
                ),
              ],
            ]);

        final batch = await MorningNoticeQuery(
          source: source,
          clock: source.clock,
        ).collect(day);

        expect(batch.notices, hasLength(6));
        expect(batch.notices.map((notice) => notice.title), [
          'first',
          'pinned',
          'second',
          'third',
          'fourth',
          'fifth',
        ]);
        expect(batch.coverage[0].pages, 5);
        expect(batch.coverage[0].matched, 6);
        expect(batch.coverage[0].failure, PublicFailureCode.resourceLimit);
        expect(batch.coverage[0].complete, isFalse);
        expect(source.browseCalls.map((call) => call.$3?.value), [
          null,
          '1',
          '2',
          '3',
          '4',
          null,
        ]);
        expect(source.articleCalls, hasLength(6));
        expect(source.articleCalls.every((call) => call.$2 <= 1000), isTrue);
      },
    );

    test(
      'retains titles after body failure and preserves another source',
      () async {
        final teach = _candidate(
          'teach-body-fails',
          PublicProvider.teach,
          '2026-10-14',
        );
        final finance = _candidate(
          'finance-body-works',
          PublicProvider.finance,
          '2026-10-14',
        );
        final source =
            _FakePublicPort(clock: FixedClock(DateTime.utc(2026, 10, 15, 1)))
              ..setPages(CampusColumn.teachNotice, [
                [teach],
              ])
              ..setPages(CampusColumn.financeNotice, [
                [finance],
              ])
              ..articleFailures[teach.reference.value] = const PublicFailure(
                PublicFailureCode.networkFailed,
              );

        final batch = await MorningNoticeQuery(
          source: source,
          clock: source.clock,
        ).collect(day);

        expect(batch.notices, hasLength(2));
        expect(batch.notices[0].title, 'teach-body-fails');
        expect(batch.notices[0].articleUrl, teach.evidence.articleUrl);
        expect(batch.notices[0].excerpt, isEmpty);
        expect(batch.notices[1].title, 'finance-body-works');
        expect(batch.notices[1].excerpt, '正文-finance-body-works');
        expect(batch.coverage[0].failure, PublicFailureCode.networkFailed);
        expect(batch.coverage[0].complete, isFalse);
        expect(batch.coverage[1].failure, isNull);
        expect(batch.coverage[1].complete, isTrue);
      },
    );

    test(
      'busy source is reported as partial instead of an empty success',
      () async {
        final finance = _candidate(
          'finance-result',
          PublicProvider.finance,
          '2026-10-14',
        );
        final source =
            _FakePublicPort(clock: FixedClock(DateTime.utc(2026, 10, 15, 1)))
              ..browseFailures[CampusColumn.teachNotice] = const PublicFailure(
                PublicFailureCode.busy,
              )
              ..setPages(CampusColumn.financeNotice, [
                [finance],
              ]);

        final batch = await MorningNoticeQuery(
          source: source,
          clock: source.clock,
        ).collect(day);

        expect(batch.notices.map((notice) => notice.title), ['finance-result']);
        expect(batch.coverage[0].failure, PublicFailureCode.busy);
        expect(batch.coverage[0].complete, isFalse);
        expect(batch.coverage[1].matched, 1);
        expect(batch.coverage[1].complete, isTrue);
      },
    );

    test(
      'checks caller cancellation before and after each port call',
      () async {
        final beforeCall = _FakePublicPort(
          clock: FixedClock(DateTime.utc(2026, 10, 15, 1)),
        );
        await expectLater(
          MorningNoticeQuery(
            source: beforeCall,
            clock: beforeCall.clock,
          ).collect(day, isCancelled: () => true),
          throwsA(_failure(PublicFailureCode.cancelled)),
        );
        expect(beforeCall.browseCalls, isEmpty);

        var cancelled = false;
        final afterCall =
            _FakePublicPort(clock: FixedClock(DateTime.utc(2026, 10, 15, 1)))
              ..beforeBrowseReturn = (_, _) async {
                cancelled = true;
              };
        await expectLater(
          MorningNoticeQuery(
            source: afterCall,
            clock: afterCall.clock,
          ).collect(day, isCancelled: () => cancelled),
          throwsA(_failure(PublicFailureCode.cancelled)),
        );
        expect(afterCall.browseCalls, hasLength(1));
        expect(afterCall.cancelCalls, 0);
      },
    );

    test('rejects delivery at the exact 60 second boundary', () async {
      final clock = _MutableClock(DateTime.utc(2026, 10, 15, 1));
      final source = _FakePublicPort(clock: clock)
        ..setPages(CampusColumn.teachNotice, [
          [_candidate('too-late', PublicProvider.teach, '2026-10-14')],
        ])
        ..beforeBrowseReturn = (_, _) async {
          clock.advance(const Duration(seconds: 60));
        };

      await expectLater(
        MorningNoticeQuery(source: source, clock: clock).collect(day),
        throwsA(_failure(PublicFailureCode.resourceLimit)),
      );
      expect(source.browseCalls, hasLength(1));
      expect(source.articleCalls, isEmpty);
    });

    test(
      'keeps port operations and article fragments within their caps',
      () async {
        final source = _FakePublicPort(
          clock: FixedClock(DateTime.utc(2026, 10, 15, 1)),
        );
        for (final column in [
          CampusColumn.teachNotice,
          CampusColumn.financeNotice,
        ]) {
          final provider = column.provider;
          source.setPages(column, [
            for (var page = 0; page < 5; page++)
              [
                for (var item = 0; item < 20; item++)
                  _candidate(
                    '${column.name}-$page-$item',
                    provider,
                    '2026-10-14',
                  ),
              ],
          ]);
        }

        final batch = await MorningNoticeQuery(
          source: source,
          clock: source.clock,
        ).collect(day);

        expect(batch.notices, hasLength(200));
        expect(batch.operations, 16);
        expect(batch.operations, lessThanOrEqualTo(20));
        expect(source.browseCalls, hasLength(10));
        expect(source.articleCalls, hasLength(6));
        expect(source.articleCalls.every((call) => call.$2 <= 1000), isTrue);
      },
    );
  });
}

Matcher _failure(PublicFailureCode code) =>
    isA<PublicFailure>().having((failure) => failure.code, 'code', code);

PublicCandidate _candidate(
  String id,
  PublicProvider provider,
  String? publishedOn,
) {
  final articleUrl = provider == PublicProvider.teach
      ? Uri.https('www.teach.ustc.edu.cn', '/notice/test/$id.html')
      : Uri.https('finance.ustc.edu.cn', '/2026/1014/c21813a$id/page.psp');
  return PublicCandidate(
    reference: PublicReference(id),
    title: id,
    evidence: PublicEvidence(
      provider: provider,
      title: id,
      articleUrl: articleUrl,
      observedAtUtc: DateTime.utc(2026, 10, 15, 1),
      origin: EvidenceOrigin.online,
      publishedOn: publishedOn,
    ),
  );
}

PublicQueryResult _articleResult(
  PublicCandidate candidate,
  DateTime observedAtUtc,
  String markdown,
) => PublicQueryResult(
  coverage: const PublicCoverage(
    scope: 'syntheticArticle',
    returned: 1,
    complete: true,
  ),
  document: PublicDocument(
    evidence: PublicEvidence(
      provider: candidate.evidence.provider,
      title: candidate.title,
      articleUrl: candidate.evidence.articleUrl,
      observedAtUtc: observedAtUtc,
      origin: EvidenceOrigin.online,
      publishedOn: candidate.evidence.publishedOn,
    ),
    markdown: markdown,
  ),
);

final class _FakePublicPort implements PublicQueryPort {
  _FakePublicPort({required this.clock});

  final AppClock clock;
  final Map<CampusColumn, List<List<PublicCandidate>>> _pages = {};
  final Map<CampusColumn, PublicFailure> browseFailures = {};
  final Map<String, PublicFailure> articleFailures = {};
  final Map<String, String> articleBodies = {};
  final Set<String> truncatedPages = {};
  final List<(CampusColumn, int, PublicCursor?)> browseCalls = [];
  final List<(PublicReference, int)> articleCalls = [];
  Future<void> Function(CampusColumn, int)? beforeBrowseReturn;
  Future<void> Function(PublicReference)? beforeArticleReturn;
  int cancelCalls = 0;

  void setPages(CampusColumn column, List<List<PublicCandidate>> pages) {
    _pages[column] = pages;
  }

  @override
  PublicJobView get view => const PublicJobView(phase: PublicJobPhase.idle);

  @override
  Stream<PublicJobView> get changes => const Stream<PublicJobView>.empty();

  @override
  Future<bool> hasIcourseConsent() async => false;

  @override
  Future<void> setIcourseConsent(bool allowed) async {}

  @override
  Future<PublicQueryResult> searchCourses(
    String keywords, {
    int pageSize = 20,
    PublicCursor? cursor,
  }) async => throw UnimplementedError();

  @override
  Future<PublicQueryResult> readCourse(
    PublicReference reference, {
    String? term,
    CourseReviewSort sort = CourseReviewSort.upvote,
    int pageSize = 10,
    PublicCursor? cursor,
  }) async => throw UnimplementedError();

  @override
  Future<PublicQueryResult> browseCampus(
    CampusColumn column, {
    String? keywords,
    int pageSize = 20,
    PublicCursor? cursor,
  }) async {
    final pageIndex = cursor == null ? 0 : int.parse(cursor.value);
    browseCalls.add((column, pageSize, cursor));
    await beforeBrowseReturn?.call(column, pageIndex);
    final failure = browseFailures[column];
    if (failure != null) throw failure;

    final pages = _pages[column] ?? const <List<PublicCandidate>>[];
    final candidates = pageIndex < pages.length
        ? pages[pageIndex]
        : const <PublicCandidate>[];
    final hasNext = pageIndex + 1 < pages.length;
    final next = hasNext ? PublicCursor('${pageIndex + 1}') : null;
    final truncated = truncatedPages.contains('${column.name}:$pageIndex');
    return PublicQueryResult(
      candidates: candidates,
      next: next,
      coverage: PublicCoverage(
        scope: 'syntheticCampusNotice',
        returned: candidates.length,
        truncated: truncated,
        complete: next == null && !truncated,
      ),
    );
  }

  @override
  Future<PublicQueryResult> readCampusArticle(
    PublicReference reference, {
    int sectionStart = 0,
    int maxCharacters = 12000,
    PublicCursor? cursor,
  }) async {
    articleCalls.add((reference, maxCharacters));
    await beforeArticleReturn?.call(reference);
    final failure = articleFailures[reference.value];
    if (failure != null) throw failure;

    final candidate = _pages.values
        .expand((pages) => pages)
        .expand((page) => page)
        .firstWhere(
          (item) => item.reference.value == reference.value,
          orElse: () =>
              throw const PublicFailure(PublicFailureCode.staleReference),
        );
    return _articleResult(
      candidate,
      clock.nowUtc,
      articleBodies[reference.value] ?? '正文-${candidate.title}',
    );
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  Future<void> retryRecovery() async {}

  @override
  Future<void> close() async {}
}

final class _MutableClock implements AppClock {
  _MutableClock(this.nowUtc);

  @override
  DateTime nowUtc;

  void advance(Duration duration) {
    nowUtc = nowUtc.add(duration);
  }
}
