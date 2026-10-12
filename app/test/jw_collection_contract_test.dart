import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/jw_work_contract.dart';
import 'package:ustc_assistant_m0/source/jw_collection_contract.dart';
import 'package:ustc_assistant_m0/source/jw_collection_failure.dart';
import 'package:ustc_assistant_m0/source/jw_data_probe_contract.dart';

Matcher rejection(
  JwCollectionRejectionReason reason, {
  bool? duplicateIdentical,
}) => throwsA(
  isA<JwCollectionValidationFailure>()
      .having((failure) => failure.reason, 'reason', reason)
      .having(
        (failure) => failure.duplicateIdentical,
        'duplicateIdentical',
        duplicateIdentical,
      ),
);

Map<String, Object?> sample({bool empty = false}) => {
  'operation': 7,
  'phase': 'done',
  'code': 'ok',
  'identity': {
    'candidateCount': 1,
    'method': 'definitionList',
    'accountCode': 'TEST0001',
  },
  'diagnostics': JwDataDiagnostics(
    checks: {
      'identityBefore': 'ok',
      'course': 'ok',
      'index': 'ok',
      'datum': empty ? 'skipped' : 'ok',
      'exams': 'ok',
      'identityAfter': 'ok',
    },
    identityReads: 2,
    lessonIds: empty ? 0 : 1,
    lessons: empty ? 0 : 1,
    groups: empty ? 0 : 1,
    schedules: empty ? 0 : 1,
    datedSchedules: empty ? 0 : 1,
    timedSchedules: empty ? 0 : 1,
    linkedSchedules: empty ? 0 : 1,
    semesterAccepted: true,
    selfRouteBound: true,
    identityStable: true,
    emptyCourse: empty,
    emptyExams: true,
  ).safeProjection,
  'snapshot': {
    'semesterId': 20261,
    'courses': empty
        ? []
        : [
            {
              'lessonId': 11,
              'groupId': 21,
              'date': '2026-10-12',
              'startMinute': 480,
              'endMinute': 590,
              'title': '合成课程',
            },
          ],
    'exams': [],
  },
};

Map<String, Object?> sampleWithExams({int count = 1}) {
  final root = sample(empty: true);
  const exam = <String, Object>{
    'courseCode': 'SYN101',
    'examType': 'final',
    'date': '2026-12-20',
    'startMinute': 540,
    'endMinute': 660,
    'title': '合成考试',
  };
  ((root['snapshot'] as Map)['exams'] as List).addAll(
    List<Map<String, Object>>.generate(
      count,
      (_) => Map<String, Object>.from(exam),
    ),
  );
  final diagnostics = root['diagnostics'] as Map;
  diagnostics['examRows'] = count;
  diagnostics['datedExams'] = count;
  diagnostics['emptyExams'] = count == 0;
  return root;
}

void duplicateCourse(Map<String, Object?> root, {int? duplicateEndMinute}) {
  final courses = (root['snapshot'] as Map)['courses'] as List;
  final duplicate = Map<String, Object>.from(courses.single as Map);
  if (duplicateEndMinute != null) {
    duplicate['endMinute'] = duplicateEndMinute;
  }
  courses.add(duplicate);
  final diagnostics = root['diagnostics'] as Map;
  for (final key in [
    'schedules',
    'datedSchedules',
    'timedSchedules',
    'linkedSchedules',
  ]) {
    diagnostics[key] = 2;
  }
}

void setCourseCount(Map<String, Object?> root, int count) {
  final diagnostics = root['diagnostics'] as Map;
  for (final key in [
    'schedules',
    'datedSchedules',
    'timedSchedules',
    'linkedSchedules',
  ]) {
    diagnostics[key] = count;
  }
}

void setExamCount(Map<String, Object?> root, int count) {
  final diagnostics = root['diagnostics'] as Map;
  diagnostics['examRows'] = count;
  diagnostics['datedExams'] = count;
  diagnostics['emptyExams'] = count == 0;
}

void main() {
  JwCollectionReply decode(Map<String, Object?> root) =>
      JwCollectionReply.decode(jsonEncode(root), operation: 7);
  JwCollectionValidationFailure failureFrom(void Function() action) {
    try {
      action();
    } on JwCollectionValidationFailure catch (failure) {
      return failure;
    }
    throw StateError('Expected collection validation failure');
  }

  final partition = JwPartitionRef(
    id: 'jwp-${'a' * 32}',
    ownerId: 'jw-owner-${'b' * 32}',
    purpose: JwPartitionPurpose.initial,
    attempt: 'jw-0-1',
    resetEpoch: 0,
  );
  final stamp = JwWorkStamp(
    jobId: 'jw-0-1',
    ownerId: partition.ownerId,
    generation: 1,
    resetEpoch: 0,
  );
  JwCollectedArtifact seal(
    JwCollectionReply reply, {
    int document = 3,
    int semester = 20261,
  }) => JwCollectedArtifact.seal(
    reply: reply,
    stamp: stamp,
    partition: partition,
    session: 2,
    document: document,
    semesterId: semester,
    collectedAtUtc: DateTime.utc(2026, 10, 10),
  );

  test(
    'sealed data uses Beijing time and private identity, without exposing raw evidence',
    () {
      final artifact = seal(decode(sample()));
      expect(artifact.events.single.startsAtUtc, DateTime.utc(2026, 10, 12));
      expect(
        artifact.events.single.endsAtUtc,
        DateTime.utc(2026, 10, 12, 1, 50),
      );
      expect(artifact.matchesExpected('TEST0001'), isTrue);
      expect(artifact.matchesExpected('TEST0002'), isFalse);
      expect(artifact.courseCount, 1);
      expect(artifact.examCount, 0);
      expect(artifact.toString(), 'JwCollectedArtifact');
      expect(() => artifact.events.clear(), throwsUnsupportedError);
    },
  );

  test(
    'source names and end time update natural identity; date or start time creates another key',
    () {
      final original = seal(decode(sample()));
      final update = sample();
      final row =
          ((update['snapshot'] as Map)['courses'] as List).single as Map;
      row['title'] = '修订课程';
      row['endMinute'] = 600;
      final changed = seal(decode(update));
      expect(
        changed.events.single.externalId,
        original.events.single.externalId,
      );
      expect(changed.contentFingerprint, isNot(original.contentFingerprint));
      row['startMinute'] = 481;
      expect(
        seal(decode(update)).events.single.externalId,
        isNot(original.events.single.externalId),
      );
    },
  );

  test(
    'complete empty course scope is explicit, and exam absence remains observed-row scope',
    () {
      final artifact = seal(decode(sample(empty: true)));
      expect(artifact.events, isEmpty);
      expect(artifact.semesterId, 20261);
      expect(artifact.contentFingerprint, hasLength(64));
    },
  );

  test('document and selected scope cannot change while sealing', () {
    final reply = decode(sample());
    expect(
      () => seal(reply, document: 0),
      rejection(JwCollectionRejectionReason.sealMetadataMismatch),
    );
    expect(
      () => seal(reply, semester: 20262),
      rejection(JwCollectionRejectionReason.sealMetadataMismatch),
    );
  });

  test('failed/running replies cannot smuggle business payload', () {
    expect(
      () => decode({
        'operation': 7,
        'phase': 'running',
        'code': 'pending',
        'snapshot': {'semesterId': 20261, 'courses': [], 'exams': []},
      }),
      rejection(JwCollectionRejectionReason.projectionInvalid),
    );
    final running = decode({
      'operation': 7,
      'phase': 'running',
      'code': 'pending',
    });
    expect(running.events, isEmpty);
    expect(running.normalization, isNull);
    expect(
      () => seal(running),
      rejection(JwCollectionRejectionReason.sealMetadataMismatch),
    );
  });

  test('malformed nested probe projection has a safe typed rejection', () {
    final root = sample();
    root['extraProbeField'] = 'synthetic account data';

    expect(
      () => decode(root),
      rejection(JwCollectionRejectionReason.projectionInvalid),
    );
  });

  test(
    'unknown fields and invalid probe counters reject the whole snapshot',
    () {
      final extra = sample();
      (extra['snapshot'] as Map)['rawResponse'] = 'not allowed';
      expect(
        () => decode(extra),
        rejection(JwCollectionRejectionReason.snapshotShape),
      );
      final wrong = sample();
      (wrong['diagnostics'] as Map)['datedSchedules'] = 0;
      expect(
        () => decode(wrong),
        rejection(JwCollectionRejectionReason.proofInvalid),
      );
    },
  );

  test(
    'stable identity, self route and every required stage are mandatory',
    () {
      for (final key in ['identityStable', 'semesterAccepted']) {
        final root = sample();
        (root['diagnostics'] as Map)[key] = false;
        expect(
          () => decode(root),
          rejection(JwCollectionRejectionReason.proofInvalid),
        );
      }
      final unbound = sample();
      (unbound['diagnostics'] as Map)['selfRouteBound'] = false;
      expect(
        () => decode(unbound),
        rejection(JwCollectionRejectionReason.selfRouteUnbound),
      );
      final missingDiagnostics = sample();
      missingDiagnostics.remove('diagnostics');
      expect(
        () => decode(missingDiagnostics),
        rejection(JwCollectionRejectionReason.proofInvalid),
      );
      final skipped = sample();
      ((skipped['diagnostics'] as Map)['checks'] as Map)['datum'] = 'skipped';
      expect(
        () => decode(skipped),
        rejection(JwCollectionRejectionReason.proofInvalid),
      );
    },
  );

  test('self-route rejection carries only the validated safe diagnostics', () {
    final unbound = sample();
    (unbound['diagnostics'] as Map)['selfRouteBound'] = false;
    unbound.remove('snapshot');

    final failure = failureFrom(() => decode(unbound));
    expect(failure.reason, JwCollectionRejectionReason.selfRouteUnbound);
    expect(failure.diagnostics, isNotNull);
    expect(failure.safeProjection.containsKey('dataChecks'), isTrue);
    expect(failure.safeProjection.containsKey('snapshot'), isFalse);
  });

  test('same course key reports whether canonical fields are identical', () {
    final conflict = sample();
    duplicateCourse(conflict, duplicateEndMinute: 600);

    final failure = failureFrom(() => decode(conflict));
    expect(failure.reason, JwCollectionRejectionReason.duplicateCourseKey);
    expect(failure.duplicateIdentical, isFalse);
    expect(failure.diagnostics, isNotNull);
  });

  test('same course key with a different title is a content conflict', () {
    final conflict = sample();
    duplicateCourse(conflict);
    final duplicate =
        ((conflict['snapshot'] as Map)['courses'] as List)[1] as Map;
    duplicate['title'] = '同一自然键的另一名称';

    expect(
      () => decode(conflict),
      rejection(
        JwCollectionRejectionReason.duplicateCourseKey,
        duplicateIdentical: false,
      ),
    );
  });

  test(
    'identical course rows merge, while invalid duplicates still reject',
    () {
      final identical = sample();
      duplicateCourse(identical);
      final reply = decode(identical);
      expect(reply.events, hasLength(1));
      expect(reply.normalization!.courseRows, 2);
      expect(reply.normalization!.courseEvents, 1);
      expect(reply.normalization!.duplicateCourses, 1);

      final invalid = sample();
      duplicateCourse(invalid);
      final duplicate =
          ((invalid['snapshot'] as Map)['courses'] as List)[1] as Map;
      duplicate['title'] = '';
      expect(
        () => decode(invalid),
        rejection(JwCollectionRejectionReason.courseFields),
      );
    },
  );

  test(
    'duplicate count and source order do not change the unique fingerprint',
    () {
      final base = sample();
      final baseSnapshot = base['snapshot'] as Map;
      final first = Map<String, Object>.from(
        (baseSnapshot['courses'] as List).single as Map,
      );
      final second = Map<String, Object>.from(first)
        ..['lessonId'] = 12
        ..['groupId'] = 22
        ..['date'] = '2026-10-13'
        ..['startMinute'] = 540
        ..['endMinute'] = 600
        ..['title'] = '另一门合成课程';
      (baseSnapshot['courses'] as List).add(second);
      setCourseCount(base, 2);

      final repeated = sample();
      final repeatedSnapshot = repeated['snapshot'] as Map;
      final repeatedFirst = Map<String, Object>.from(
        (repeatedSnapshot['courses'] as List).single as Map,
      );
      final repeatedSecond = Map<String, Object>.from(repeatedFirst)
        ..['lessonId'] = 12
        ..['groupId'] = 22
        ..['date'] = '2026-10-13'
        ..['startMinute'] = 540
        ..['endMinute'] = 600
        ..['title'] = '另一门合成课程';
      repeatedSnapshot['courses'] = [
        repeatedSecond,
        repeatedFirst,
        Map<String, Object>.from(repeatedFirst),
        Map<String, Object>.from(repeatedSecond),
        Map<String, Object>.from(repeatedFirst),
      ];
      setCourseCount(repeated, 5);

      final baseArtifact = seal(decode(base));
      final repeatedArtifact = seal(decode(repeated));
      expect(
        repeatedArtifact.contentFingerprint,
        baseArtifact.contentFingerprint,
      );
      expect(repeatedArtifact.events, hasLength(2));
      expect(repeatedArtifact.normalization.courseRows, 5);
      expect(repeatedArtifact.normalization.courseEvents, 2);
      expect(repeatedArtifact.normalization.duplicateCourses, 3);
    },
  );

  test('a duplicate followed by a conflicting row rejects the whole reply', () {
    final mixed = sample();
    duplicateCourse(mixed);
    final rows = (mixed['snapshot'] as Map)['courses'] as List;
    final conflict = Map<String, Object>.from(rows.first as Map)
      ..['endMinute'] = 600;
    rows.add(conflict);
    setCourseCount(mixed, 3);

    expect(
      () => decode(mixed),
      rejection(
        JwCollectionRejectionReason.duplicateCourseKey,
        duplicateIdentical: false,
      ),
    );
  });

  test('raw rows are counted before merge and before the 10000-row limit', () {
    final mismatched = sample();
    duplicateCourse(mismatched);
    setCourseCount(mismatched, 1);
    expect(
      () => decode(mismatched),
      rejection(JwCollectionRejectionReason.eventCount),
    );

    final tooMany = sample();
    final tooManySnapshot = tooMany['snapshot'] as Map;
    final course = Map<String, Object>.from(
      (tooManySnapshot['courses'] as List).single as Map,
    );
    const exam = <String, Object>{
      'courseCode': 'SYN101',
      'examType': 'final',
      'date': '2026-12-20',
      'startMinute': 540,
      'endMinute': 660,
      'title': '合成考试',
    };
    tooManySnapshot['courses'] = List<Map<String, Object>>.generate(
      5001,
      (_) => Map<String, Object>.from(course),
    );
    tooManySnapshot['exams'] = List<Map<String, Object>>.generate(
      5000,
      (_) => Map<String, Object>.from(exam),
    );
    setCourseCount(tooMany, 5001);
    setExamCount(tooMany, 5000);

    expect(
      () => decode(tooMany),
      rejection(JwCollectionRejectionReason.eventCount),
    );
  });

  test('exam duplicates merge only when every event field matches', () {
    final duplicateExam = sampleWithExams(count: 2);
    final reply = decode(duplicateExam);
    expect(reply.events, hasLength(1));
    expect(reply.normalization!.examRows, 2);
    expect(reply.normalization!.examEvents, 1);
    expect(reply.normalization!.duplicateExams, 1);
    expect(
      seal(reply).contentFingerprint,
      seal(decode(sampleWithExams())).contentFingerprint,
    );

    final conflict = sampleWithExams(count: 2);
    final duplicate =
        ((conflict['snapshot'] as Map)['exams'] as List)[1] as Map;
    duplicate['endMinute'] = 661;
    expect(
      () => decode(conflict),
      rejection(
        JwCollectionRejectionReason.duplicateExamKey,
        duplicateIdentical: false,
      ),
    );

    final malformedExam = sampleWithExams();
    final exam =
        ((malformedExam['snapshot'] as Map)['exams'] as List).single as Map;
    exam['title'] = '';
    expect(
      () => decode(malformedExam),
      rejection(JwCollectionRejectionReason.examFields),
    );
    final invalidDuplicate = sampleWithExams(count: 2);
    final duplicateRow =
        ((invalidDuplicate['snapshot'] as Map)['exams'] as List)[1] as Map;
    duplicateRow['title'] = '';
    expect(
      () => decode(invalidDuplicate),
      rejection(JwCollectionRejectionReason.examFields),
    );
  });

  test('seal metadata rejection includes safe diagnostics', () {
    final reply = decode(sample());

    final failure = failureFrom(() => seal(reply, document: 0));
    expect(failure.reason, JwCollectionRejectionReason.sealMetadataMismatch);
    expect(failure.diagnostics, same(reply.probe.diagnostics));
    expect(failure.safeProjection.containsKey('dataChecks'), isTrue);
  });

  test('normalization exposes six safe counts with consistent identities', () {
    const syntheticStudent = 'SYNTHETICSTUDENT12345';
    const syntheticCourseTitle = 'SYNTHETIC_COURSE_TITLE';
    const syntheticExamTitle = 'SYNTHETIC_EXAM_TITLE';
    const syntheticExamCode = 'SYNTHETIC101';
    const syntheticDate = '2099-11-29';
    const syntheticLessonId = 123456789;
    const syntheticGroupId = 987654321;
    final root = sample();
    (root['identity'] as Map)['accountCode'] = syntheticStudent;
    final snapshot = root['snapshot'] as Map;
    final course = (snapshot['courses'] as List).single as Map;
    course
      ..['lessonId'] = syntheticLessonId
      ..['groupId'] = syntheticGroupId
      ..['date'] = syntheticDate
      ..['title'] = syntheticCourseTitle;
    duplicateCourse(root);
    snapshot['exams'] = [
      {
        'courseCode': syntheticExamCode,
        'examType': 'SYNTHETIC_FINAL',
        'date': syntheticDate,
        'startMinute': 540,
        'endMinute': 660,
        'title': syntheticExamTitle,
      },
      {
        'courseCode': syntheticExamCode,
        'examType': 'SYNTHETIC_FINAL',
        'date': syntheticDate,
        'startMinute': 540,
        'endMinute': 660,
        'title': syntheticExamTitle,
      },
    ];
    setExamCount(root, 2);

    final reply = decode(root);
    final artifact = seal(reply);
    final normalization = artifact.normalization;
    final expected = {
      'courseRows': 2,
      'courseEvents': 1,
      'duplicateCourses': 1,
      'examRows': 2,
      'examEvents': 1,
      'duplicateExams': 1,
    };
    expect(reply.normalization!.safeProjection, equals(expected));
    expect(normalization.safeProjection, equals(expected));
    expect(identical(reply.normalization, normalization), isTrue);
    expect(
      normalization.courseRows,
      normalization.courseEvents + normalization.duplicateCourses,
    );
    expect(
      normalization.examRows,
      normalization.examEvents + normalization.duplicateExams,
    );
    expect(normalization.safeProjection.keys.toSet(), expected.keys.toSet());

    final safeText =
        '${jsonEncode(normalization.safeProjection)} $normalization';
    for (final sensitiveValue in [
      syntheticStudent,
      syntheticCourseTitle,
      syntheticExamTitle,
      syntheticExamCode,
      'SYNTHETIC_FINAL',
      syntheticDate,
      '$syntheticLessonId',
      '$syntheticGroupId',
      'course-',
      'exam-',
    ]) {
      expect(safeText, isNot(contains(sensitiveValue)));
    }
  });

  test(
    'collection rejection never exposes account, event values or row IDs',
    () {
      const syntheticStudent = 'SYNTHETICSTUDENT12345';
      const syntheticTitle = 'SYNTHETIC_TITLE_PRIVATE';
      const syntheticDate = '2099-11-29';
      const syntheticLessonId = 123456789;
      const syntheticGroupId = 987654321;
      final root = sample();
      (root['identity'] as Map)['accountCode'] = syntheticStudent;
      final row = ((root['snapshot'] as Map)['courses'] as List).single as Map;
      row
        ..['lessonId'] = syntheticLessonId
        ..['groupId'] = syntheticGroupId
        ..['date'] = syntheticDate
        ..['title'] = syntheticTitle;
      duplicateCourse(root, duplicateEndMinute: 600);

      final failure = failureFrom(() => decode(root));
      expect(failure.duplicateIdentical, isFalse);
      final safeText = '${jsonEncode(failure.safeProjection)} $failure';
      for (final sensitiveValue in [
        syntheticStudent,
        syntheticTitle,
        syntheticDate,
        '$syntheticLessonId',
        '$syntheticGroupId',
        'course-',
      ]) {
        expect(safeText, isNot(contains(sensitiveValue)));
      }
    },
  );

  test(
    'Gregorian date, minute bounds and titles are checked without truncation',
    () {
      for (final bad in [
        {'date': '2026-02-29'},
        {'startMinute': -1},
        {'endMinute': 480},
        {'endMinute': 1440},
        {'title': ''},
        {'title': 'x' * 301},
      ]) {
        final root = sample();
        (((root['snapshot'] as Map)['courses'] as List).single as Map).addAll(
          bad,
        );
        expect(
          () => decode(root),
          rejection(JwCollectionRejectionReason.courseFields),
        );
      }
    },
  );
}
