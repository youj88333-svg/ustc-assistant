import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/data/jw_candidate_identity.dart';
import 'package:ustc_assistant_m0/jobs/jw_probe_port.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';

void main() {
  test('decodes a bounded projection and keeps its collections immutable', () {
    final reply = _decode(_projection());

    expect(reply.operation, 17);
    expect(reply.phase, JwProbePhase.done);
    expect(reply.code, JwProbeCode.ok);
    expect(reply.stage, 'exams');
    expect(reply.identityCandidateCount, 1);
    expect(reply.summary!.identityLabels, 1);
    expect(reply.summary!.semesterOptions, 2);
    expect(reply.summary!.semesterVariables['semesterId'], isTrue);
    expect(reply.summary!.stageResults['exams'], JwProbeCode.ok);
    expect(reply.semesters, hasLength(2));
    expect(reply.semesters!.first.name, '2026 秋季');
    expect(reply.semesters!.first.selected, isTrue);
    expect(
      () => reply.semesters!.add(
        const JwSemesterOption(id: 3, name: 'new', selected: false),
      ),
      throwsUnsupportedError,
    );
    expect(
      () => reply.summary!.semesterVariables['semesterId'] = false,
      throwsUnsupportedError,
    );
    expect(
      () => reply.summary!.stageResults['course'] = JwProbeCode.pending,
      throwsUnsupportedError,
    );
    expect(JwProbePhase.cancelled.wire, 'cancelled');
    expect(JwProbePhase.decode('failed'), JwProbePhase.failed);
    expect(JwProbeCode.networkFailed.wire, 'network_failed');
    expect(JwProbeCode.decode('stale_result'), JwProbeCode.staleResult);
  });

  test('rejects unknown fields, missing fields, and invalid enum values', () {
    final unknownEnvelope = _projection()..['debug'] = 'untrusted text';
    _expectInvalid(unknownEnvelope);

    final unknownSummary = _projection();
    (unknownSummary['summary']! as Map<String, Object?>)['extra'] = true;
    _expectInvalid(unknownSummary);

    final missingSummaryField = _projection();
    (missingSummaryField['summary']! as Map<String, Object?>).remove(
      'examRows',
    );
    _expectInvalid(missingSummaryField);

    final missingSemesterField = _projection();
    ((missingSemesterField['semesters']! as List<Object?>).first!
            as Map<String, Object?>)
        .remove('selected');
    _expectInvalid(missingSemesterField);

    _expectInvalid(_projection(phase: 'idle'));
    _expectInvalid(_projection(phase: 'unknown_phase'));
    _expectInvalid(_projection(code: 'unknown_code'));
    _expectInvalid(_projection()..['stage'] = 'closed');
    final missingVariable = _projection();
    ((missingVariable['summary']! as Map<String, Object?>)['semesterVariables']!
            as Map<String, Object?>)
        .remove('semesterId');
    _expectInvalid(missingVariable);

    for (final results in [
      {'identity': 'ok', 'course': 'ok'},
      {'identity': 'ok', 'course': 'ok', 'exams': 'ok', 'other': 'ok'},
      {'identity': 'ok', 'course': 'exams_schema', 'exams': 'ok'},
      {'identity': 'ok', 'course': 'raw text', 'exams': 'ok'},
      {'identity': 'ok', 'course': true, 'exams': 'ok'},
    ]) {
      final invalid = _projection();
      (invalid['summary']! as Map<String, Object?>)['stageResults'] = results;
      _expectInvalid(invalid);
    }
  });

  test('reports each check without exposing candidate or semester values', () {
    final projection = _projection(phase: 'failed', code: 'course_schema');
    projection['stage'] = 'course';
    final summary = projection['summary']! as Map<String, Object?>;
    summary['stageResults'] = {
      'identity': 'ok',
      'course': 'course_schema',
      'exams': 'ok',
    };
    summary['semesterSelect'] = false;
    summary['semesterOptions'] = 0;
    summary['examRows'] = 0;
    projection.remove('semesters');
    final reply = _decode(projection);
    final view = JwProbeView(
      phase: reply.phase,
      code: reply.code,
      identity: JwCandidateIdentity.candidateMatches,
      summary: reply.summary,
      stage: reply.stage,
    );
    final shared = jsonDecode(view.safeSummary) as Map<String, dynamic>;
    expect(shared['kind'], 'jw-candidate-contract-v3');
    expect(shared['stage'], 'course');
    expect(shared['checks'], {
      'identity': 'ok',
      'course': 'course_schema',
      'exams': 'ok',
    });
    expect(shared['sourceAvailable'], isFalse);
    expect(view.safeSummary, isNot(contains('A12345')));
    expect(view.safeSummary, isNot(contains('2026 秋季')));
  });

  test('rejects unexpected diagnostic keys, values, and bounds', () {
    for (final diagnostic in [
      {...const JwCourseDiagnostics().safeProjection, 'script': 'PRIVATE123'},
      {...const JwCourseDiagnostics().safeProjection}..remove('reason'),
      {...const JwCourseDiagnostics().safeProjection, 'reason': 'PRIVATE123'},
      {...const JwCourseDiagnostics().safeProjection, 'source': 'PRIVATE123'},
      {...const JwCourseDiagnostics().safeProjection, 'literalParsed': 'true'},
      {...const JwCourseDiagnostics().safeProjection, 'serverOptions': -1},
      {...const JwCourseDiagnostics().safeProjection, 'liveOptions': 10001},
      {
        ...const JwCourseDiagnostics().safeProjection,
        'literalAssignments': 1.5,
      },
      {...const JwCourseDiagnostics().safeProjection, 'literalItems': '2'},
    ]) {
      final projection = _projection();
      (projection['summary']! as Map<String, Object?>)['courseDiagnostics'] =
          diagnostic;
      final error = _failure(() => _decode(projection));
      expect(error, isA<AppFailure>());
      expect(error.toString(), isNot(contains('PRIVATE123')));
    }
  });

  test('exports only closed diagnostic fields and saturated counts', () {
    final projection = _projection();
    (projection['summary']! as Map<String, Object?>)['courseDiagnostics'] =
        const JwCourseDiagnostics(
          source: 'serverJson',
          liveOptions: 2,
          literalAssignments: 2,
          literalItems: 2,
          literalParsed: true,
        ).safeProjection;
    final reply = _decode(projection);
    expect(reply.summary!.courseDiagnostics.source, 'serverJson');
    final view = JwProbeView(
      phase: reply.phase,
      code: reply.code,
      identity: JwCandidateIdentity.candidateMatches,
      summary: reply.summary,
    );
    final structure =
        (jsonDecode(view.safeSummary) as Map<String, dynamic>)['structure']
            as Map<String, dynamic>;
    expect(structure['courseDiagnostics'], {
      'reason': 'none',
      'source': 'serverJson',
      'serverOptions': 0,
      'liveOptions': 2,
      'literalAssignments': 2,
      'literalItems': 2,
      'literalParsed': true,
    });
    expect(
      const JwCourseDiagnostics(
        reason: 'PRIVATE123',
        source: 'PRIVATE123',
        serverOptions: -1,
        liveOptions: 10001,
      ).safeProjection,
      {
        'reason': 'literal_invalid',
        'source': 'none',
        'serverOptions': 0,
        'liveOptions': 10000,
        'literalAssignments': 0,
        'literalItems': 0,
        'literalParsed': false,
      },
    );
    expect(reply.summary!.courseDiagnostics.toString(), 'JwCourseDiagnostics');
    expect(view.safeSummary, isNot(contains('A12345')));
    expect(view.safeSummary, isNot(contains('2026 秋季')));
  });

  test(
    'rejects operation mismatches, oversized input, and out-of-range values',
    () {
      expect(
        () => JwProbeReply.decode(jsonEncode(_projection()), operation: 18),
        throwsA(isA<AppFailure>()),
      );
      expect(
        () => JwProbeReply.decode(' ' * (256 * 1024 + 1), operation: 17),
        throwsA(isA<AppFailure>()),
      );

      final tooManyLabels = _projection();
      (tooManyLabels['summary']! as Map<String, Object?>)['examRows'] = 10001;
      _expectInvalid(tooManyLabels);

      final tooManyCandidates = _projection();
      (tooManyCandidates['identity']!
              as Map<String, Object?>)['candidateCount'] =
          10001;
      _expectInvalid(tooManyCandidates);

      final tooManyOptions = _projection();
      (tooManyOptions['summary']! as Map<String, Object?>)['semesterOptions'] =
          257;
      _expectInvalid(tooManyOptions);

      final tooManyTables = _projection();
      (tooManyTables['summary']! as Map<String, Object?>)['examTables'] = 11;
      _expectInvalid(tooManyTables);

      final invalidOperation = _projection()..['operation'] = 0;
      _expectInvalid(invalidOperation);
    },
  );

  test('keeps historical and boundary catalogs complete across projection', () {
    final escapedLabel = 'PRIVATE_LABEL${String.fromCharCode(92) * 107}';
    for (final count in [81, 256]) {
      final projection = _projection();
      (projection['summary']! as Map<String, Object?>)['semesterOptions'] =
          count;
      projection['semesters'] = [
        for (var i = 0; i < count; i++)
          {'id': i + 1, 'name': escapedLabel, 'selected': i == 0},
      ];
      final encoded = jsonEncode(projection);
      if (count == 256) expect(encoded.length, greaterThan(64 * 1024));
      final reply = JwProbeReply.decode(encoded, operation: 17);
      expect(reply.summary!.semesterOptions, count);
      expect(reply.semesters, hasLength(count));
      expect(reply.semesters!.last.id, count);
      expect(reply.semesters!.last.name, escapedLabel);
      expect(reply.semesters!.where((item) => item.selected), hasLength(1));
      final safeSummary = JwProbeView(
        phase: reply.phase,
        code: reply.code,
        identity: JwCandidateIdentity.candidateMatches,
        summary: reply.summary,
      ).safeSummary;
      expect(safeSummary, isNot(contains('PRIVATE_LABEL')));
      expect(safeSummary, isNot(contains('A12345')));
    }

    final oversized = _projection();
    // Keep the summary inside the boundary to independently check list length.
    (oversized['summary']! as Map<String, Object?>)['semesterOptions'] = 256;
    oversized['semesters'] = [
      for (var i = 0; i < 257; i++)
        {'id': i + 1, 'name': 'synthetic', 'selected': false},
    ];
    _expectInvalid(oversized);
  });

  test(
    'does not retain account codes in decoder failures or string output',
    () {
      const studentValue = 'STUDENT123';
      final projection = _projection(
        identity: {
          'candidateCount': 1,
          'accountCode': studentValue,
          'method': 'table',
        },
      );
      final reply = _decode(projection);
      expect(reply.toString(), 'JwProbeReply');
      expect(reply.toString(), isNot(contains(studentValue)));
      expect(
        JwCandidateIdentityVerifier('OTHER123').toString(),
        'JwCandidateIdentityVerifier',
      );

      final invalid = _projection()..['stage'] = studentValue;
      final error = _failure(() => _decode(invalid));
      expect(error, isA<AppFailure>());
      expect(error.toString(), isNot(contains(studentValue)));

      final invalidExpected = _failure(
        () => JwCandidateIdentityVerifier('student123'),
      );
      expect(invalidExpected.toString(), isNot(contains('student123')));
    },
  );

  test(
    'compares only the unique projected candidate against the login code',
    () {
      final verifier = JwCandidateIdentityVerifier('A12345');

      expect(
        verifier.evaluate(
          _decode(_projection(includeIdentity: false, identityLabels: 0)),
        ),
        JwCandidateIdentity.unavailable,
      );
      expect(
        verifier.evaluate(
          _decode(
            _projection(identity: {'candidateCount': 1, 'method': 'label'}),
          ),
        ),
        JwCandidateIdentity.unavailable,
      );
      expect(
        verifier.evaluate(
          _decode(
            _projection(
              identity: {
                'candidateCount': 1,
                'accountCode': 'A12345',
                'method': 'table',
              },
            ),
          ),
        ),
        JwCandidateIdentity.candidateMatches,
      );
      expect(
        verifier.evaluate(
          _decode(
            _projection(
              identity: {
                'candidateCount': 1,
                'accountCode': 'B54321',
                'method': 'definitionList',
              },
            ),
          ),
        ),
        JwCandidateIdentity.candidateMismatch,
      );
      expect(
        verifier.evaluate(
          _decode(
            _projection(
              identity: {'candidateCount': 2, 'method': 'mixed'},
              identityLabels: 2,
            ),
          ),
        ),
        JwCandidateIdentity.candidateConflict,
      );
    },
  );

  test('rejects duplicate semesters and multiple selected options', () {
    final duplicateIds = _projection();
    final duplicateOptions = duplicateIds['semesters']! as List<Object?>;
    duplicateOptions[1] = {'id': 1, 'name': '2025 秋季', 'selected': false};
    _expectInvalid(duplicateIds);

    final multipleSelected = _projection();
    final options = multipleSelected['semesters']! as List<Object?>;
    (options[1]! as Map<String, Object?>)['selected'] = true;
    _expectInvalid(multipleSelected);

    final unsafeName = _projection();
    (unsafeName['semesters']! as List<Object?>).first = {
      'id': 1,
      'name': '<script>',
      'selected': true,
    };
    _expectInvalid(unsafeName);
  });
}

JwProbeReply _decode(Map<String, Object?> projection) =>
    JwProbeReply.decode(jsonEncode(projection), operation: 17);

Map<String, Object?> _projection({
  String phase = 'done',
  String code = 'ok',
  Map<String, Object?>? identity,
  bool includeIdentity = true,
  bool includeSummary = true,
  int identityLabels = 1,
}) {
  final projection = <String, Object?>{
    'operation': 17,
    'phase': phase,
    'code': code,
    'stage': 'exams',
  };
  if (includeIdentity) {
    projection['identity'] =
        identity ??
        {'candidateCount': 1, 'accountCode': 'A12345', 'method': 'table'};
  }
  if (includeSummary) {
    projection['summary'] = {
      'identityLabels': identityLabels,
      'semesterOptions': 2,
      'examTables': 1,
      'examRows': 4,
      'semesterSelect': true,
      'examHeader': true,
      'pagination': false,
      'stageResults': {'identity': 'ok', 'course': 'ok', 'exams': 'ok'},
      'courseDiagnostics': const JwCourseDiagnostics().safeProjection,
      'semesterVariables': {
        'allSemesters': false,
        'semesters': false,
        'semesterId': true,
        'bizTypeId': false,
      },
    };
    projection['semesters'] = [
      {'id': 1, 'name': '2026 秋季', 'selected': true},
      {'id': 2, 'name': '2025 春季', 'selected': false},
    ];
  }
  return projection;
}

void _expectInvalid(Map<String, Object?> projection) {
  expect(
    () => _decode(projection),
    throwsA(
      isA<AppFailure>().having(
        (failure) => failure.code,
        'code',
        FailureCode.invalidSnapshot,
      ),
    ),
  );
}

Object _failure(void Function() action) {
  try {
    action();
  } on Object catch (error) {
    return error;
  }
  throw StateError('Expected a sanitized failure');
}
