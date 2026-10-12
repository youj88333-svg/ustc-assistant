// Manual, explicitly opted-in public research. Never part of the test suite.
// Uses a new in-memory public context; no formal directory or browser assets.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/jobs/public_query_coordinator.dart';
import 'package:ustc_assistant_m0/source/public_http.dart';

final class _EphemeralOwner implements AssetOwnership {
  @override
  bool get isHeld => true;
  @override
  void ensureHeld() {}
}

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty ||
      arguments.first != '--public-only' ||
      arguments.length > 2 ||
      arguments.length == 2 &&
          !{'--icourse-only', '--campus-only'}.contains(arguments.last)) {
    throw ArgumentError('manual public-only opt-in required');
  }
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _EphemeralOwner(),
    clock: const SystemClock(),
  );
  await store.initialize();
  final queries = PublicQueryCoordinator(
    store: store.publicStore,
    leases: WorkLeasePool(),
  );
  var unexpectedFailures = 0;
  Future<PublicQueryResult?> probe(
    String name,
    Future<PublicQueryResult> Function() operation, {
    PublicFailureCode? expectedFailure,
  }) async {
    try {
      final result = await operation();
      stdout.writeln(
        jsonEncode({
          'probe': name,
          'code': 'ok',
          'version': result.version,
          'candidates': result.candidates.length,
          'hasNext': result.next != null,
          'returned': result.coverage.returned,
          'observed': result.coverage.observed,
          'reported': result.coverage.totalReported,
          'complete': result.coverage.complete,
          'excluded': result.coverage.excluded,
          'cached': result.coverage.cached,
          if (result.document != null) ...{
            'textCharacters': result.document!.markdown.runes.length,
            'reviews': result.document!.reviews.length,
            'terms': result.document!.course?.terms.length,
            'ratings': result.document!.course?.ratingCount,
            'reviewCount': result.document!.course?.reviewCount,
            'publishedKnown': result.document!.evidence.publishedOn != null,
            'updatedKnown': result.document!.evidence.updatedOn != null,
            'attachments': result.document!.attachmentLinks.length,
          },
        }),
      );
      return result;
    } on PublicFailure catch (error) {
      if (error.code != expectedFailure) unexpectedFailures++;
      stdout.writeln(
        jsonEncode({
          'probe': name,
          'code': error.code.name,
          'phase': queries.view.phase.name,
        }),
      );
      return null;
    }
  }

  try {
    if (arguments.last != '--campus-only') {
      await queries.setIcourseConsent(true);
      final courses = await probe(
        'courseKeyword',
        () => queries.searchCourses('数学分析', pageSize: 20),
      );
      if (courses != null && courses.candidates.isNotEmpty) {
        final ref = courses.candidates.first.reference;
        final detail = await probe(
          'courseDetail',
          () => queries.readCourse(ref, pageSize: 3),
        );
        if (detail?.document?.course?.terms.isNotEmpty == true) {
          await probe(
            'courseTermAndSort',
            () => queries.readCourse(
              ref,
              term: detail!.document!.course!.terms.length > 1
                  ? detail.document!.course!.terms[1].code
                  : detail.document!.course!.terms.first.code,
              sort: CourseReviewSort.newest,
              pageSize: 3,
            ),
          );
        }
      }
      if (courses?.next != null && queries.view.failure == null) {
        await probe(
          'courseUpstreamPage2',
          () => queries.searchCourses(
            '数学分析',
            pageSize: 20,
            cursor: courses!.next,
          ),
        );
      }
      await probe(
        'teacherKeyword',
        () => queries.searchCourses('程艺', pageSize: 3),
      );
      await probe(
        'courseLegalEmpty',
        () => queries.searchCourses('m3-no-match-847164291'),
      );
    }
    if (arguments.last == '--icourse-only') {
      if (unexpectedFailures > 0) exitCode = 1;
      return;
    }
    for (final column in [
      CampusColumn.teachNotice,
      CampusColumn.teachStudentService,
      CampusColumn.financeNotice,
      CampusColumn.financeBusiness,
      CampusColumn.financeProcess,
      CampusColumn.financeOperation,
    ]) {
      final page = await probe(
        column.name,
        () => queries.browseCampus(column, pageSize: 20),
      );
      if (page != null && page.candidates.isNotEmpty) {
        await probe(
          '${column.name}Article',
          () => queries.readCampusArticle(page.candidates.first.reference),
        );
      }
      if (page != null && page.next != null) {
        var continued = await probe(
          '${column.name}Next',
          () => queries.browseCampus(column, pageSize: 20, cursor: page.next),
        );
        // Student services are one finite topic page. Consume its cached
        // candidates too, so a later out-of-scope link cannot hide the tail.
        if (column == CampusColumn.teachStudentService) {
          for (var part = 3; part <= 5 && continued?.next != null; part++) {
            final cursor = continued!.next;
            continued = await probe(
              '${column.name}Part$part',
              () => queries.browseCampus(column, pageSize: 20, cursor: cursor),
            );
          }
        }
      }
    }
    await probe(
      'teachNativeKeyword',
      () => queries.browseCampus(
        CampusColumn.teachNotice,
        keywords: '选课',
        pageSize: 3,
      ),
    );
    await probe(
      'teachLegalEmpty',
      () => queries.browseCampus(
        CampusColumn.teachNotice,
        keywords: 'm3-no-match-847164291',
      ),
    );
    final serviceKeyword = await probe(
      'teachStudentKeyword',
      () => queries.browseCampus(
        CampusColumn.teachStudentService,
        keywords: '课程',
        pageSize: 20,
      ),
    );
    if (serviceKeyword?.next != null) {
      await probe(
        'teachStudentKeywordPage2',
        () => queries.browseCampus(
          CampusColumn.teachStudentService,
          keywords: '课程',
          pageSize: 20,
          cursor: serviceKeyword!.next,
        ),
      );
    }
    await probe(
      'teachStudentLegalEmpty',
      () => queries.browseCampus(
        CampusColumn.teachStudentService,
        keywords: 'm3-no-match-847164291',
      ),
    );
    await probe(
      'financeKeywordUnavailable',
      () => queries.browseCampus(CampusColumn.financeNotice, keywords: '缴费'),
      expectedFailure: PublicFailureCode.unavailable,
    );
    await probe(
      'financeFaqUnavailable',
      () => queries.browseCampus(CampusColumn.financeFaq),
      expectedFailure: PublicFailureCode.unavailable,
    );
    final campus = IoPublicHttpSession(
      targets: PublicHttpTargets(),
      source: PublicSource.campus,
    );
    try {
      await campus.get(
        Uri.parse(
          'https://finance.ustc.edu.cn/2012/0902/c21820a440895/page.htm',
        ),
      );
      stdout.writeln(
        jsonEncode({
          'probe': 'campusRestrictedRoute',
          'code': 'ok',
          'directRetried': campus.campusDirectRetried,
        }),
      );
    } on PublicFailure catch (error) {
      unexpectedFailures++;
      stdout.writeln(
        jsonEncode({
          'probe': 'campusRestrictedRoute',
          'code': error.code.name,
          'directRetried': campus.campusDirectRetried,
        }),
      );
    } finally {
      await campus.close();
    }
  } finally {
    await queries.close();
    await store.close();
  }
  if (unexpectedFailures > 0) exitCode = 1;
}
