import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/source/jw_data_probe_contract.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';

void main() {
  test('decodes the closed data contract and keeps identity private', () {
    const privateAccountCode = 'AB12345';
    final reply = JwDataProbeReply.decode(
      jsonEncode(
        _envelope(
          identity: {
            'candidateCount': 1,
            'method': 'table',
            'accountCode': privateAccountCode,
          },
          diagnostics: _diagnostics(),
        ),
      ),
      operation: 17,
    );

    expect(reply.phase, JwProbePhase.done);
    expect(reply.code, JwDataProbeCode.ok);
    expect(reply.operation, 17);
    expect(reply.stage, isNull);
    expect(reply.identityCandidateCount, 1);
    expect(reply.accountCode, privateAccountCode);
    expect(reply.diagnostics!.checks['identityBefore'], 'ok');
    expect(reply.toString(), 'JwDataProbeReply');
    expect(reply.toString(), isNot(contains(privateAccountCode)));
  });

  test('round-trips every fixed wire code', () {
    for (final code in JwDataProbeCode.values) {
      expect(JwDataProbeCode.decode(code.wire), code);
    }
  });

  test('rejects unknown envelope keys, codes, stages and diagnostics', () {
    final unknownKey = _envelope()..['raw'] = 'private source response';
    _expectInvalid(unknownKey);

    _expectInvalid(_envelope()..['code'] = 'new_private_code');
    _expectInvalid(_envelope()..['stage'] = 'identity');

    final badReason = _diagnostics()..['reason'] = 'response snippet';
    _expectInvalid(_envelope(diagnostics: badReason));

    final badType = _diagnostics();
    (badType['types']! as Map<String, Object?>)['date'] = 'raw-date-value';
    _expectInvalid(_envelope(diagnostics: badType));

    final badCheck = _diagnostics();
    (badCheck['checks']! as Map<String, Object?>)['datum'] = 'request body';
    _expectInvalid(_envelope(diagnostics: badCheck));
  });

  test('checks account candidate shape and phase/code pairing strictly', () {
    _expectInvalid(
      _envelope(identity: {'candidateCount': 1, 'method': 'table'}),
    );
    _expectInvalid(
      _envelope(
        identity: {
          'candidateCount': 1,
          'method': 'table',
          'accountCode': 'student-123',
        },
      ),
    );
    _expectInvalid(
      _envelope(
        identity: {
          'candidateCount': 2,
          'method': 'mixed',
          'accountCode': 'AB12345',
        },
      ),
    );
    _expectInvalid(_envelope(phase: 'failed', code: 'ok'));
    _expectInvalid(_envelope(phase: 'done', code: 'identity_changed'));
  });

  test('rejects oversize, stale and non-safe operation numbers', () {
    const operation = 17;
    _expectInvalid(
      '{}${List<String>.filled(256 * 1024, ' ').join()}',
      operation: operation,
    );
    _expectInvalid(_envelope(), operation: operation + 1);
    _expectInvalid(_envelope(operation: 9007199254740992));
    _expectInvalid(_envelope(), operation: 9007199254740992);
  });

  test('safe diagnostics close manual values and clamp counts', () {
    final diagnostics = JwDataDiagnostics(
      checks: const {'identityBefore': 'alien-status', 'raw': 'secret'},
      reason: 'secret response text',
      identityReads: 12000,
      lessonIds: -1,
      types: const {'date': '2026-10-11', 'raw': 'credential'},
    );
    final safe = diagnostics.safeProjection;
    final encoded = jsonEncode(safe);

    expect(
      safe.keys,
      containsAll([
        'checks',
        'reason',
        'identityReads',
        'lessonIds',
        'lessons',
        'groups',
        'schedules',
        'datedSchedules',
        'timedSchedules',
        'linkedSchedules',
        'examRows',
        'datedExams',
        'semesterAccepted',
        'selfRouteBound',
        'identityStable',
        'emptyCourse',
        'emptyExams',
        'pagination',
        'types',
      ]),
    );
    expect((safe['checks']! as Map<String, String>).keys, {
      'identityBefore',
      'course',
      'index',
      'datum',
      'exams',
      'identityAfter',
    });
    expect((safe['checks']! as Map<String, String>)['identityBefore'], 'error');
    expect(safe['reason'], 'field_conflict');
    expect(safe['identityReads'], 10000);
    expect(safe['lessonIds'], 0);
    expect((safe['types']! as Map<String, String>)['date'], 'mixed');
    expect(encoded, isNot(contains('secret')));
    expect(encoded, isNot(contains('credential')));
    expect(encoded, isNot(contains('2026-10-11')));
    expect(diagnostics.toString(), 'JwDataDiagnostics');
  });

  test('diagnostic maps are immutable and constructor maps are exact', () {
    final diagnostics = JwDataDiagnostics(
      checks: const {'course': 'ok', 'unrecognized': 'error'},
      types: const {'date': 'string', 'unrecognized': 'string'},
    );
    expect(diagnostics.checks.keys, {
      'identityBefore',
      'course',
      'index',
      'datum',
      'exams',
      'identityAfter',
    });
    expect(diagnostics.types.keys, {
      'lessonIds',
      'lessonList',
      'scheduleGroupList',
      'scheduleList',
      'date',
      'startTime',
      'endTime',
    });
    expect(
      () => diagnostics.checks['course'] = 'error',
      throwsUnsupportedError,
    );
    expect(() => diagnostics.types['date'] = 'mixed', throwsUnsupportedError);
  });
}

Map<String, Object?> _envelope({
  int operation = 17,
  String phase = 'done',
  String code = 'ok',
  Map<String, Object?>? identity,
  Object? diagnostics,
}) => {
  'operation': operation,
  'phase': phase,
  'code': code,
  'identity': ?identity,
  'diagnostics': ?diagnostics,
};

Map<String, Object?> _diagnostics() => {
  'checks': {
    'identityBefore': 'ok',
    'course': 'ok',
    'index': 'ok',
    'datum': 'ok',
    'exams': 'ok',
    'identityAfter': 'ok',
  },
  'reason': 'none',
  'identityReads': 2,
  'lessonIds': 1,
  'lessons': 1,
  'groups': 1,
  'schedules': 1,
  'datedSchedules': 1,
  'timedSchedules': 1,
  'linkedSchedules': 1,
  'examRows': 0,
  'datedExams': 0,
  'semesterAccepted': true,
  'selfRouteBound': true,
  'identityStable': true,
  'emptyCourse': false,
  'emptyExams': true,
  'pagination': false,
  'types': {
    'lessonIds': 'array',
    'lessonList': 'array',
    'scheduleGroupList': 'array',
    'scheduleList': 'array',
    'date': 'string',
    'startTime': 'string',
    'endTime': 'string',
  },
};

void _expectInvalid(Object input, {int operation = 17}) {
  final text = input is String ? input : jsonEncode(input);
  expect(
    () => JwDataProbeReply.decode(text, operation: operation),
    throwsA(
      isA<AppFailure>().having(
        (failure) => failure.code,
        'code',
        FailureCode.invalidSnapshot,
      ),
    ),
  );
}
