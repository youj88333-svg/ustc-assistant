import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/source/young_observation_contract.dart';

const _session = 73;
const _document = 9;

Map<String, Object?> _snapshot({
  Object? session = _session,
  Object? document = _document,
  Object? ready = true,
  Object? surface = 'application',
  Object? tables = 2,
  Object? calendarRoots = 1,
  Object? paginationControls = 0,
  Object? passwordInputs = 1,
}) => <String, Object?>{
  'session': session,
  'document': document,
  'ready': ready,
  'surface': surface,
  'tables': tables,
  'calendarRoots': calendarRoots,
  'paginationControls': paginationControls,
  'passwordInputs': passwordInputs,
};

void _expectFailure(Object? value, FailureCode code) {
  try {
    YoungPageInspection.decode(value, session: _session, document: _document);
    fail('Expected AppFailure($code)');
  } on AppFailure catch (failure) {
    expect(failure.code, code);
  }
}

void main() {
  test('decodes a closed snapshot and returns the exact safe summary', () {
    final inspection = YoungPageInspection.decode(
      _snapshot(),
      session: _session,
      document: _document,
    );

    expect(inspection.session, _session);
    expect(inspection.document, _document);
    expect(inspection.surface, YoungSurface.application);
    expect(inspection.safeSummary(), <String, Object?>{
      'kind': 'young-observation-v1',
      'ready': true,
      'surface': 'application',
      'identity': 'notValidated',
      'sourceAvailable': false,
      'structure': <String, Object?>{
        'tables': 2,
        'calendarRoots': 1,
        'paginationControls': 0,
        'passwordInputs': 1,
      },
    });
  });

  test('accepts both inclusive boundaries for all four counts', () {
    const countFields = <String>[
      'tables',
      'calendarRoots',
      'paginationControls',
      'passwordInputs',
    ];

    for (final field in countFields) {
      for (final boundary in <int>[0, 4096]) {
        final snapshot = _snapshot()..[field] = boundary;
        final inspection = YoungPageInspection.decode(
          snapshot,
          session: _session,
          document: _document,
        );
        expect(
          inspection.safeSummary()['structure'],
          containsPair(field, boundary),
        );
      }
    }
  });

  test('accepts a positive session and zero document identity', () {
    final inspection = YoungPageInspection.decode(
      _snapshot(session: 1, document: 0),
      session: 1,
      document: 0,
    );

    expect(inspection.session, 1);
    expect(inspection.document, 0);
  });

  test('rejects a well-formed result bound to another session or document', () {
    _expectFailure(_snapshot(session: _session + 1), FailureCode.staleResult);
    _expectFailure(_snapshot(document: _document + 1), FailureCode.staleResult);
  });

  test('rejects missing, extra, and untrusted text fields', () {
    final missing = _snapshot()..remove('tables');
    _expectFailure(missing, FailureCode.invalidSnapshot);

    final extra = _snapshot()
      ..['url'] = 'https://secret.example/path?account=private'
      ..['title'] = 'Private page text';
    _expectFailure(extra, FailureCode.invalidSnapshot);

    final stringKeyPollution = <Object?, Object?>{
      ..._snapshot(),
      17: 'unexpected text',
    };
    _expectFailure(stringKeyPollution, FailureCode.invalidSnapshot);
  });

  test('requires exact scalar types and known surface names', () {
    for (final badValue in <Object?>[0, -1, true, '73', 73.0]) {
      _expectFailure(_snapshot(session: badValue), FailureCode.invalidSnapshot);
    }

    for (final badValue in <Object?>[-1, true, '9', 9.0]) {
      _expectFailure(
        _snapshot(document: badValue),
        FailureCode.invalidSnapshot,
      );
    }

    for (final badValue in <Object?>['true', 1]) {
      _expectFailure(_snapshot(ready: badValue), FailureCode.invalidSnapshot);
    }

    for (final badValue in <Object?>[true, '2', 2.0, -1, 4097]) {
      _expectFailure(_snapshot(tables: badValue), FailureCode.invalidSnapshot);
    }

    _expectFailure(
      _snapshot(surface: 'private page body'),
      FailureCode.invalidSnapshot,
    );
  });

  test('copied summary omits the internal session and document tokens', () {
    const sessionToken = 982731;
    const documentToken = 641205;
    final inspection = YoungPageInspection(
      session: sessionToken,
      document: documentToken,
      ready: true,
      surface: YoungSurface.portal,
      tables: 0,
      calendarRoots: 0,
      paginationControls: 0,
      passwordInputs: 0,
    );

    final copiedSummary = jsonEncode(inspection.safeSummary());

    expect(copiedSummary, isNot(contains('$sessionToken')));
    expect(copiedSummary, isNot(contains('$documentToken')));
    expect(copiedSummary, isNot(contains('"session"')));
    expect(copiedSummary, isNot(contains('"document"')));
    expect(copiedSummary, contains('"identity":"notValidated"'));
    expect(copiedSummary, contains('"sourceAvailable":false'));
  });
}
