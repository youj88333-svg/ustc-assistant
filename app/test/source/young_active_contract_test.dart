import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/source/young_active_contract.dart';

const _session = 31;
const _document = 0;
const _operation = 73;
const _step = 9;

Map<String, Object?> _reply({
  Object? session = _session,
  Object? document = _document,
  Object? operation = _operation,
  Object? step = _step,
  Object? complete = true,
  Object? projectedJson = '{"rows":0}',
}) => <String, Object?>{
  'session': session,
  'document': document,
  'operation': operation,
  'step': step,
  'complete': complete,
  if (complete == true) 'projectedJson': projectedJson,
};

void _expectFailure(Object? value, FailureCode expected) {
  try {
    YoungBusinessStepReply.decode(
      value,
      session: _session,
      document: _document,
      operation: _operation,
      step: _step,
    );
    fail('Expected AppFailure(${expected.name})');
  } on AppFailure catch (failure) {
    expect(failure.code, expected);
  }
}

void main() {
  test('decodes only an exactly correlated completed projection', () {
    final reply = YoungBusinessStepReply.decode(
      _reply(),
      session: _session,
      document: _document,
      operation: _operation,
      step: _step,
    );

    expect(reply.session, _session);
    expect(reply.document, _document);
    expect(reply.operation, _operation);
    expect(reply.step, _step);
    expect(reply.complete, isTrue);
    expect(reply.projectedJson, '{"rows":0}');
    expect(reply.toString(), 'YoungBusinessStepReply');
  });

  test('accepts a pending reply only when projection is absent', () {
    final reply = YoungBusinessStepReply.decode(
      _reply(complete: false),
      session: _session,
      document: _document,
      operation: _operation,
      step: _step,
    );

    expect(reply.complete, isFalse);
    expect(reply.projectedJson, isNull);
  });

  test('rejects missing, extra, non-string-keyed and inconsistent fields', () {
    _expectFailure(
      <String, Object?>{..._reply()}..remove('operation'),
      FailureCode.invalidSnapshot,
    );
    _expectFailure(<String, Object?>{
      ..._reply(),
      'account': 'private-account',
    }, FailureCode.invalidSnapshot);
    _expectFailure(<Object?, Object?>{
      ..._reply(),
      17: 'private',
    }, FailureCode.invalidSnapshot);
    _expectFailure(<String, Object?>{
      ..._reply(complete: false),
      'projectedJson': 'unexpected',
    }, FailureCode.invalidSnapshot);
    _expectFailure(_reply(projectedJson: 17), FailureCode.invalidSnapshot);
  });

  test('rejects invalid associations and distinguishes stale results', () {
    for (final field in const ['session', 'operation', 'step']) {
      _expectFailure(<String, Object?>{
        ..._reply(),
        field: 0,
      }, FailureCode.invalidSnapshot);
    }
    _expectFailure(_reply(document: -1), FailureCode.invalidSnapshot);
    _expectFailure(_reply(session: _session + 1), FailureCode.staleResult);
    _expectFailure(_reply(document: _document + 1), FailureCode.staleResult);
    _expectFailure(_reply(operation: _operation + 1), FailureCode.staleResult);
    _expectFailure(_reply(step: _step + 1), FailureCode.staleResult);
  });

  test(
    'enforces the projection limit and keeps private JSON out of toString',
    () {
      final tooLarge = List<String>.filled(
        YoungBusinessStepReply.maximumProjectionLength + 1,
        'x',
      ).join();
      _expectFailure(
        _reply(projectedJson: tooLarge),
        FailureCode.invalidSnapshot,
      );

      const privateProjection = '{"username":"private-account"}';
      final reply = YoungBusinessStepReply.decode(
        _reply(projectedJson: privateProjection),
        session: _session,
        document: _document,
        operation: _operation,
        step: _step,
      );
      expect(reply.toString(), isNot(contains(privateProjection)));
      expect(reply.toString(), isNot(contains('private-account')));
    },
  );

  test('summary contains only fixed state and closed counts', () {
    const view = YoungBusinessView(
      phase: YoungBusinessPhase.failed,
      identity: YoungBusinessIdentity.candidateMatches,
      stage: YoungBusinessStage.profileAfter,
      failure: FailureCode.staleResult,
      busy: true,
      available: true,
      activities: 69,
      activityPages: 7,
      calendarRows: 4,
      linkedSchedules: 1,
      excludedSchedules: 3,
      days: 2,
      calendarPages: 2,
      identityReads: 2,
    );
    final summary = view.safeSummary();
    final json = jsonEncode(summary);

    expect(summary, <String, Object?>{
      'kind': 'young-active-contract-v1',
      'phase': 'failed',
      'identity': 'candidateMatches',
      'sourceAvailable': false,
      'stage': 'profileAfter',
      'failure': 'staleResult',
      'activities': 69,
      'activityPages': 7,
      'calendarRows': 4,
      'linkedSchedules': 1,
      'excludedSchedules': 3,
      'days': 2,
      'calendarPages': 2,
      'identityReads': 2,
    });
    expect(summary.containsKey('busy'), isFalse);
    expect(summary.containsKey('available'), isFalse);
    expect(json, isNot(contains('private-account')));
    expect(view.toString(), 'YoungBusinessView');
  });
}
