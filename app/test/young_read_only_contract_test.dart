import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/source/young_read_only_contract.dart';

const _session = 41;
const _document = 8;
const _operation = 19;

Map<String, Object?> _profile({
  Object? observations = 0,
  Object? success = 'unobserved',
  Object? code = 'absent',
  Object? result = 'absent',
  Object? loginCode = 'absent',
  Object? username = 'absent',
}) => <String, Object?>{
  'observations': observations,
  'success': success,
  'code': code,
  'result': result,
  'loginCode': loginCode,
  'username': username,
};

Map<String, Object?> _list({
  Object? observations = 0,
  Object? success = 'unobserved',
  Object? code = 'absent',
  Object? result = 'absent',
  Object? records = 'absent',
  Object? count = 0,
  Object? total = 'absent',
  Object? id = 'absent',
  Object? title = 'absent',
  Object? date = 'absent',
  Object? startTime = 'absent',
  Object? endTime = 'absent',
}) => <String, Object?>{
  'observations': observations,
  'success': success,
  'code': code,
  'result': result,
  'records': records,
  'count': count,
  'total': total,
  'id': id,
  'title': title,
  'date': date,
  'startTime': startTime,
  'endTime': endTime,
};

Map<String, Object?> _snapshot({
  Object? session = _session,
  Object? document = _document,
  Object? operation = _operation,
  Object? listening = true,
  Object? accepted = 0,
  Object? rejected = 0,
  Object? lastRejection = 'none',
  Object? profile,
  Object? schedule,
  Object? activities,
}) => <String, Object?>{
  'session': session,
  'document': document,
  'operation': operation,
  'listening': listening,
  'accepted': accepted,
  'rejected': rejected,
  'lastRejection': lastRejection,
  'profile': profile ?? _profile(),
  'schedule': schedule ?? _list(),
  'activities': activities ?? _list(),
};

YoungReadOnlyInspection _decode(Object? value) =>
    YoungReadOnlyInspection.decode(
      value,
      session: _session,
      document: _document,
      operation: _operation,
    );

void _expectFailure(
  Object? value,
  FailureCode expected, {
  int session = _session,
  int document = _document,
  int operation = _operation,
}) {
  try {
    YoungReadOnlyInspection.decode(
      value,
      session: session,
      document: document,
      operation: operation,
    );
    fail('Expected AppFailure(${expected.name})');
  } on AppFailure catch (failure) {
    expect(failure.code, expected);
  }
}

Map<String, Object?> _observedProfile({
  Object? observations = 1,
  Object? success = 'true',
  Object? code = 'number',
  Object? result = 'object',
  Object? loginCode = 'string',
  Object? username = 'string',
}) => _profile(
  observations: observations,
  success: success,
  code: code,
  result: result,
  loginCode: loginCode,
  username: username,
);

Map<String, Object?> _observedList({
  Object? observations = 1,
  Object? success = 'true',
  Object? code = 'number',
  Object? result = 'object',
  Object? records = 'array',
  Object? count = 2,
  Object? total = 'number',
  Object? id = 'string',
  Object? title = 'string',
  Object? date = 'string',
  Object? startTime = 'string',
  Object? endTime = 'string',
}) => _list(
  observations: observations,
  success: success,
  code: code,
  result: result,
  records: records,
  count: count,
  total: total,
  id: id,
  title: title,
  date: date,
  startTime: startTime,
  endTime: endTime,
);

final class _BrowserPort implements YoungReadOnlyBrowserPort {
  _BrowserPort(this.response);

  final YoungReadOnlyInspection response;

  @override
  Future<YoungReadOnlyInspection> startYoungReadOnly({
    required int session,
    required int document,
    required int operation,
  }) async => response;

  @override
  Future<YoungReadOnlyInspection> readYoungReadOnly({
    required int session,
    required int document,
    required int operation,
  }) async => response;

  @override
  Future<void> stopYoungReadOnly({
    required int session,
    required int document,
    required int operation,
  }) async {}
}

void main() {
  test('decodes only the closed candidate summary fields', () {
    final inspection = _decode(
      _snapshot(
        accepted: 2,
        rejected: 3,
        lastRejection: 'target',
        profile: _observedProfile(),
        schedule: _observedList(),
      ),
    );

    expect(inspection.session, _session);
    expect(inspection.document, _document);
    expect(inspection.operation, _operation);
    expect(inspection.profile.username, 'string');
    expect(inspection.schedule.count, 2);
    expect(inspection.safeSummary(), <String, Object?>{
      'kind': 'young-readonly-observation-v1',
      'listening': true,
      'accepted': 2,
      'rejected': 3,
      'lastRejection': 'target',
      'profile': <String, Object?>{
        'observations': 1,
        'success': 'true',
        'code': 'number',
        'result': 'object',
        'loginCode': 'string',
        'username': 'string',
      },
      'schedule': <String, Object?>{
        'observations': 1,
        'success': 'true',
        'code': 'number',
        'result': 'object',
        'records': 'array',
        'count': 2,
        'total': 'number',
        'id': 'string',
        'title': 'string',
        'date': 'string',
        'startTime': 'string',
        'endTime': 'string',
      },
      'activities': _list(),
      'identity': 'notValidated',
      'sourceAvailable': false,
    });
  });

  test('accepts inclusive observation, counter, and record count limits', () {
    final acceptedLimit = _decode(
      _snapshot(
        accepted: 1024,
        rejected: 4096,
        profile: _observedProfile(
          observations: 1024,
          success: 'other',
          code: 'mixed',
          result: 'null',
          loginCode: 'boolean',
          username: 'array',
        ),
      ),
    );
    expect(acceptedLimit.accepted, 1024);
    expect(acceptedLimit.rejected, 4096);

    final recordCountLimit = _decode(
      _snapshot(accepted: 1, schedule: _observedList(count: 5000)),
    );
    expect(recordCountLimit.schedule.count, 5000);
  });

  test('rejects malformed root fields and out-of-range numbers', () {
    _expectFailure(
      _snapshot()..remove('activities'),
      FailureCode.invalidSnapshot,
    );
    _expectFailure(
      _snapshot()..['url'] = 'https://private.example/?token=sentinel',
      FailureCode.invalidSnapshot,
    );

    for (final value in <Object?>[0, -1, true, '41', 41.0]) {
      _expectFailure(_snapshot(session: value), FailureCode.invalidSnapshot);
      _expectFailure(_snapshot(operation: value), FailureCode.invalidSnapshot);
    }
    for (final value in <Object?>[-1, true, '8', 8.0]) {
      _expectFailure(_snapshot(document: value), FailureCode.invalidSnapshot);
    }
    for (final value in <Object?>[0, -1, 1.0, 'true']) {
      _expectFailure(_snapshot(listening: value), FailureCode.invalidSnapshot);
    }
    for (final value in <Object?>[-1, 1025, true, 1.0]) {
      _expectFailure(_snapshot(accepted: value), FailureCode.invalidSnapshot);
    }
    for (final value in <Object?>[-1, 4097, true, 1.0]) {
      _expectFailure(_snapshot(rejected: value), FailureCode.invalidSnapshot);
    }
    _expectFailure(
      _snapshot(schedule: _observedList(count: 5001), accepted: 1),
      FailureCode.invalidSnapshot,
    );
  });

  test('rejects unknown rejection, success, and value-kind labels', () {
    _expectFailure(
      _snapshot(lastRejection: 'private rejection detail'),
      FailureCode.invalidSnapshot,
    );
    _expectFailure(
      _snapshot(profile: _observedProfile(success: 'maybe')),
      FailureCode.invalidSnapshot,
    );
    _expectFailure(
      _snapshot(profile: _observedProfile(username: 'alice@example.test')),
      FailureCode.invalidSnapshot,
    );
  });

  test('rejects unknown and secret fields at each nested level', () {
    final extraProfileField = _observedProfile()
      ..['account'] = 'private-account-sentinel';
    _expectFailure(
      _snapshot(profile: extraProfileField, accepted: 1),
      FailureCode.invalidSnapshot,
    );

    final extraScheduleField = _observedList()
      ..['titleValue'] = 'private-title-sentinel';
    _expectFailure(
      _snapshot(schedule: extraScheduleField, accepted: 1),
      FailureCode.invalidSnapshot,
    );

    final nonStringKey = <Object?, Object?>{..._profile(), 23: 'private'};
    _expectFailure(
      _snapshot(profile: nonStringKey),
      FailureCode.invalidSnapshot,
    );
  });

  test(
    'uses staleResult only for a valid snapshot with a binding mismatch',
    () {
      final valid = _snapshot(accepted: 1, activities: _observedList());
      _expectFailure(
        _snapshot(
          session: _session + 1,
          accepted: 1,
          activities: _observedList(),
        ),
        FailureCode.staleResult,
      );
      _expectFailure(
        _snapshot(
          document: _document + 1,
          accepted: 1,
          activities: _observedList(),
        ),
        FailureCode.staleResult,
      );
      _expectFailure(
        _snapshot(
          operation: _operation + 1,
          accepted: 1,
          activities: _observedList(),
        ),
        FailureCode.staleResult,
      );
      _expectFailure(
        <String, Object?>{...valid, 'accepted': 2},
        FailureCode.invalidSnapshot,
        session: _session + 1,
      );
    },
  );

  test('requires accepted to equal observations across all three targets', () {
    _expectFailure(
      _snapshot(
        accepted: 1,
        profile: _observedProfile(),
        schedule: _observedList(),
      ),
      FailureCode.invalidSnapshot,
    );
  });

  test('enforces unobserved defaults and observed success status', () {
    _expectFailure(
      _snapshot(profile: _profile(success: 'true')),
      FailureCode.invalidSnapshot,
    );
    _expectFailure(
      _snapshot(profile: _profile(code: 'string')),
      FailureCode.invalidSnapshot,
    );
    _expectFailure(
      _snapshot(schedule: _list(count: 1)),
      FailureCode.invalidSnapshot,
    );
    _expectFailure(
      _snapshot(activities: _list(observations: 1)),
      FailureCode.invalidSnapshot,
    );
  });

  test('safe summary hides bindings and carries no input map references', () {
    final profile = _observedProfile();
    final source = _snapshot(
      session: 987654321,
      document: 123456789,
      operation: 765432198,
      accepted: 1,
      profile: profile,
    );
    final inspection = YoungReadOnlyInspection.decode(
      source,
      session: 987654321,
      document: 123456789,
      operation: 765432198,
    );
    profile['username'] = 'changed after decode';
    source['rejected'] = 4096;

    final summary = inspection.safeSummary();
    final encoded = jsonEncode(summary);
    expect(encoded, isNot(contains('987654321')));
    expect(encoded, isNot(contains('123456789')));
    expect(encoded, isNot(contains('765432198')));
    expect(encoded, isNot(contains('session')));
    expect(encoded, isNot(contains('document')));
    expect(encoded, isNot(contains('operation')));
    expect(encoded, isNot(contains('changed after decode')));
    expect(summary['rejected'], 0);
    expect((summary['profile']! as Map)['username'], 'string');

    expect(() => summary['listening'] = false, throwsUnsupportedError);
    expect(
      () => (summary['profile']! as Map)['username'] = 'raw value',
      throwsUnsupportedError,
    );
  });

  test('withListening copies a snapshot without changing its bindings', () {
    final inspection = _decode(_snapshot());
    final stopped = inspection.withListening(false);

    expect(stopped.listening, isFalse);
    expect(inspection.listening, isTrue);
    expect(stopped.session, _session);
    expect(stopped.document, _document);
    expect(stopped.operation, _operation);
    expect(stopped.safeSummary()['listening'], isFalse);
  });

  test(
    'browser port exposes start, read, and stop with all binding values',
    () async {
      final response = _decode(_snapshot());
      final port = _BrowserPort(response);

      expect(
        await port.startYoungReadOnly(
          session: _session,
          document: _document,
          operation: _operation,
        ),
        same(response),
      );
      expect(
        await port.readYoungReadOnly(
          session: _session,
          document: _document,
          operation: _operation,
        ),
        same(response),
      );
      await port.stopYoungReadOnly(
        session: _session,
        document: _document,
        operation: _operation,
      );
    },
  );
}
