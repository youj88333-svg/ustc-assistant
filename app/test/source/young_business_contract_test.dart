import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/source/young_business_contract.dart';

const String _syntheticAccount = 'SYNTHETIC_USER_01';

Map<String, Object?> _profileResponse({
  Object? success = true,
  Object? code = 200,
  Object? username = _syntheticAccount,
}) => <String, Object?>{
  'success': success,
  'code': code,
  'result': <String, Object?>{
    'username': username,
    'displayOnlySynthetic': 'SYNTHETIC_DISPLAY_VALUE',
  },
  'unknownSyntheticField': 'SYNTHETIC_IGNORED',
};

Map<String, Object?> _activityRecord({
  Object? id = 'SYNTHETIC_ACTIVITY_001',
  Object? itemName = 'Synthetic activity',
  Object? st = '2026-10-12 09:00:00',
  Object? et = '2026-10-12 10:00:00',
  Object? applySt = '2026-10-10 08:00:00',
  Object? applyEt = '2026-10-11 18:00:00',
  Object? placeInfo = 'Synthetic venue',
}) => <String, Object?>{
  'id': id,
  'itemName': itemName,
  'st': st,
  'et': et,
  'applySt': applySt,
  'applyEt': applyEt,
  'placeInfo': placeInfo,
  'unknownSyntheticField': 'SYNTHETIC_IGNORED',
};

Map<String, Object?> _calendarRecord({
  Object? id = 'SYNTHETIC_CALENDAR_001',
  Object? title = 'Synthetic calendar entry',
  Object? place = 'Synthetic room',
  Object? startTime = '2026-10-12 09:00:00',
  Object? endTime = '2026-10-12 10:00:00',
  Object? itemId = 'SYNTHETIC_ACTIVITY_001',
}) => <String, Object?>{
  'id': id,
  'title': title,
  'place': place,
  'startTime': startTime,
  'endTime': endTime,
  'itemId': itemId,
  'unknownSyntheticField': 'SYNTHETIC_IGNORED',
};

Map<String, Object?> _activityResponse({
  List<Object?>? records,
  Object? total = 1,
  Object? success = true,
  Object? code = 200,
  Object? current = 1,
  Object? size = 10,
  Object? pages = 1,
}) => <String, Object?>{
  'success': success,
  'code': code,
  'result': <String, Object?>{
    'records': records ?? <Object?>[_activityRecord()],
    'total': total,
    'current': current,
    'size': size,
    'pages': pages,
    'unknownSyntheticField': 'SYNTHETIC_IGNORED',
  },
  'unknownSyntheticField': 'SYNTHETIC_IGNORED',
};

Map<String, Object?> _calendarResponse({
  List<Object?>? records,
  Object? total = 1,
}) => <String, Object?>{
  'success': true,
  'code': 200,
  'result': <String, Object?>{
    'records': records ?? <Object?>[_calendarRecord()],
    'total': total,
    'current': 1,
    'size': 10,
    'pages': 1,
  },
};

List<Map<String, Object?>> _activities(int count, {int first = 1}) =>
    List<Map<String, Object?>>.generate(
      count,
      (int index) => _activityRecord(
        id: 'SYNTHETIC_ACTIVITY_${(first + index).toString().padLeft(3, '0')}',
      ),
    );

YoungPageAccumulator<YoungActivity> _activityAccumulator() =>
    YoungPageAccumulator<YoungActivity>(
      decodePage: decodeYoungActivityPage,
      idOf: (YoungActivity record) => record.id,
    );

void _expectInvalid(void Function() action) {
  expect(
    action,
    throwsA(
      isA<AppFailure>().having(
        (AppFailure failure) => failure.code,
        'code',
        FailureCode.invalidSnapshot,
      ),
    ),
  );
}

void _expectIncomplete(void Function() action) {
  expect(
    action,
    throwsA(
      isA<AppFailure>().having(
        (AppFailure failure) => failure.code,
        'code',
        FailureCode.incompleteSnapshot,
      ),
    ),
  );
}

void main() {
  group('profile candidate', () {
    test(
      'accepts only the required successful fields and retains username',
      () {
        final candidate = decodeYoungProfile(_profileResponse(code: 200.0));
        final minimal = decodeYoungProfile(<String, Object?>{
          'success': true,
          'code': 200,
          'result': <String, Object?>{'username': _syntheticAccount},
        });

        expect(candidate.username, _syntheticAccount);
        expect(minimal.username, _syntheticAccount);
        expect(candidate.toString(), 'YoungProfileCandidate');
        expect(
          () => jsonEncode(candidate),
          throwsA(isA<JsonUnsupportedObjectError>()),
        );
      },
    );

    test('rejects unsuccessful, textual-code, or incomplete envelopes', () {
      _expectInvalid(
        () => decodeYoungProfile(_profileResponse(success: false)),
      );
      _expectInvalid(
        () => decodeYoungProfile(_profileResponse(success: 'true')),
      );
      _expectInvalid(() => decodeYoungProfile(_profileResponse(code: '200')));
      _expectInvalid(() => decodeYoungProfile(_profileResponse(code: 201)));

      final missingResult = _profileResponse()..remove('result');
      _expectInvalid(() => decodeYoungProfile(missingResult));
      _expectInvalid(
        () => decodeYoungProfile(<String, Object?>{
          'success': true,
          'code': 200,
          'result': <String, Object?>{},
        }),
      );
    });

    test('bounds and validates the account candidate text', () {
      expect(
        decodeYoungProfile(
          _profileResponse(username: List<String>.filled(64, 'a').join()),
        ).username.length,
        64,
      );
      _expectInvalid(
        () => decodeYoungProfile(
          _profileResponse(username: List<String>.filled(65, 'a').join()),
        ),
      );
      _expectInvalid(() => decodeYoungProfile(_profileResponse(username: '')));
      _expectInvalid(
        () => decodeYoungProfile(_profileResponse(username: '   ')),
      );
      _expectInvalid(
        () => decodeYoungProfile(_profileResponse(username: 'SYNTHETIC\nUSER')),
      );
      _expectInvalid(() => decodeYoungProfile(_profileResponse(username: 42)));
    });

    test('does not retain the mutable response map', () {
      final response = _profileResponse();
      final result = response['result'] as Map<String, Object?>;
      final candidate = decodeYoungProfile(response);
      result['username'] = 'SYNTHETIC_MUTATED_USER';

      expect(candidate.username, _syntheticAccount);
    });
  });

  group('activity records', () {
    test('keeps event and registration intervals separate in UTC', () {
      final activity = decodeYoungActivityPage(
        _activityResponse(),
      ).records.single;

      expect(activity.startsAtUtc, DateTime.utc(2026, 10, 12, 1));
      expect(activity.endsAtUtc, DateTime.utc(2026, 10, 12, 2));
      expect(activity.registrationStartsAtUtc, DateTime.utc(2026, 10, 10));
      expect(activity.registrationEndsAtUtc, DateTime.utc(2026, 10, 11, 10));
      expect(activity.placeInfo, 'Synthetic venue');
      expect(activity.toString(), 'YoungActivity');
      expect(
        () => jsonEncode(activity),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
    });

    test('accepts missing or null optional fields and empty location', () {
      final record = _activityRecord()
        ..remove('applySt')
        ..remove('applyEt')
        ..remove('placeInfo');
      final activity = decodeYoungActivityPage(
        _activityResponse(records: <Object?>[record]),
      ).records.single;

      expect(activity.registrationStartsAtUtc, isNull);
      expect(activity.registrationEndsAtUtc, isNull);
      expect(activity.placeInfo, isNull);

      final emptyLocation = decodeYoungActivityPage(
        _activityResponse(
          records: <Object?>[
            _activityRecord(applySt: null, applyEt: null, placeInfo: ''),
          ],
        ),
      ).records.single;
      expect(emptyLocation.placeInfo, '');
    });

    test('rejects missing, mistyped, blank, or oversized required fields', () {
      for (final field in <String>['id', 'itemName', 'st', 'et']) {
        final record = _activityRecord()..remove(field);
        _expectInvalid(
          () => decodeYoungActivityPage(
            _activityResponse(records: <Object?>[record]),
          ),
        );
      }

      _expectInvalid(
        () => decodeYoungActivityPage(
          _activityResponse(records: <Object?>[_activityRecord(id: 17)]),
        ),
      );
      _expectInvalid(
        () => decodeYoungActivityPage(
          _activityResponse(
            records: <Object?>[_activityRecord(itemName: '  ')],
          ),
        ),
      );
      _expectInvalid(
        () => decodeYoungActivityPage(
          _activityResponse(
            records: <Object?>[
              _activityRecord(itemName: 'SYNTHETIC\u0000NAME'),
            ],
          ),
        ),
      );
      _expectInvalid(
        () => decodeYoungActivityPage(
          _activityResponse(
            records: <Object?>[
              _activityRecord(id: List<String>.filled(257, 'i').join()),
            ],
          ),
        ),
      );
      _expectInvalid(
        () => decodeYoungActivityPage(
          _activityResponse(
            records: <Object?>[
              _activityRecord(itemName: List<String>.filled(2049, 'n').join()),
            ],
          ),
        ),
      );
    });

    test(
      'rejects invalid optional-field types and reversed registration time',
      () {
        _expectInvalid(
          () => decodeYoungActivityPage(
            _activityResponse(records: <Object?>[_activityRecord(applySt: 7)]),
          ),
        );
        _expectInvalid(
          () => decodeYoungActivityPage(
            _activityResponse(
              records: <Object?>[_activityRecord(placeInfo: false)],
            ),
          ),
        );
        _expectInvalid(
          () => decodeYoungActivityPage(
            _activityResponse(
              records: <Object?>[
                _activityRecord(
                  applySt: '2026-10-11 12:00:00',
                  applyEt: '2026-10-11 11:59:59',
                ),
              ],
            ),
          ),
        );
      },
    );

    test('validates leap dates, clock bounds, and event ordering strictly', () {
      final leapDay = decodeYoungActivityPage(
        _activityResponse(
          records: <Object?>[
            _activityRecord(
              st: '2028-02-29 09:00:00',
              et: '2028-02-29 10:00:00',
            ),
          ],
        ),
      ).records.single;
      expect(leapDay.startsAtUtc, DateTime.utc(2028, 2, 29, 1));
      expect(leapDay.startsAtUtc.isUtc, isTrue);

      for (final invalid in <String>[
        '2026-13-01 09:00:00',
        '2026-02-29 09:00:00',
        '2028-02-30 09:00:00',
        '2026-10-12 24:00:00',
        '2026-10-12 09:60:00',
        '2026-10-12 09:00:60',
        '2026-10-12T09:00:00',
        '2026-10-12 09:00:00Z',
      ]) {
        _expectInvalid(
          () => decodeYoungActivityPage(
            _activityResponse(records: <Object?>[_activityRecord(st: invalid)]),
          ),
        );
      }

      _expectInvalid(
        () => decodeYoungActivityPage(
          _activityResponse(
            records: <Object?>[
              _activityRecord(
                st: '2026-10-12 10:00:00',
                et: '2026-10-12 10:00:00',
              ),
            ],
          ),
        ),
      );
    });
  });

  group('calendar records', () {
    test('decodes required fields and treats empty itemId as unlinked', () {
      final linked = decodeYoungCalendarPage(
        _calendarResponse(),
      ).records.single;
      expect(linked.id, 'SYNTHETIC_CALENDAR_001');
      expect(linked.title, 'Synthetic calendar entry');
      expect(linked.place, 'Synthetic room');
      expect(linked.startsAtUtc, DateTime.utc(2026, 10, 12, 1));
      expect(linked.endsAtUtc, DateTime.utc(2026, 10, 12, 2));
      expect(linked.itemId, 'SYNTHETIC_ACTIVITY_001');

      for (final itemId in <Object?>[null, '']) {
        final entry = decodeYoungCalendarPage(
          _calendarResponse(
            records: <Object?>[_calendarRecord(itemId: itemId)],
          ),
        ).records.single;
        expect(entry.itemId, isNull);
      }

      final absent = _calendarRecord()..remove('itemId');
      expect(
        decodeYoungCalendarPage(
          _calendarResponse(records: <Object?>[absent]),
        ).records.single.itemId,
        isNull,
      );
    });

    test('rejects missing or mistyped required fields and invalid itemId', () {
      for (final field in <String>[
        'id',
        'title',
        'place',
        'startTime',
        'endTime',
      ]) {
        final record = _calendarRecord()..remove(field);
        _expectInvalid(
          () => decodeYoungCalendarPage(
            _calendarResponse(records: <Object?>[record]),
          ),
        );
      }

      _expectInvalid(
        () => decodeYoungCalendarPage(
          _calendarResponse(records: <Object?>[_calendarRecord(id: 123)]),
        ),
      );
      _expectInvalid(
        () => decodeYoungCalendarPage(
          _calendarResponse(records: <Object?>[_calendarRecord(title: '')]),
        ),
      );
      _expectInvalid(
        () => decodeYoungCalendarPage(
          _calendarResponse(records: <Object?>[_calendarRecord(itemId: 123)]),
        ),
      );
      _expectInvalid(
        () => decodeYoungCalendarPage(
          _calendarResponse(records: <Object?>[_calendarRecord(itemId: '   ')]),
        ),
      );
      _expectInvalid(
        () => decodeYoungCalendarPage(
          _calendarResponse(records: <Object?>[_calendarRecord(place: false)]),
        ),
      );
    });

    test('allows an empty place but enforces its bound and time order', () {
      final emptyPlace = decodeYoungCalendarPage(
        _calendarResponse(records: <Object?>[_calendarRecord(place: '')]),
      ).records.single;
      expect(emptyPlace.place, '');

      _expectInvalid(
        () => decodeYoungCalendarPage(
          _calendarResponse(
            records: <Object?>[
              _calendarRecord(place: List<String>.filled(2049, 'p').join()),
            ],
          ),
        ),
      );
      _expectInvalid(
        () => decodeYoungCalendarPage(
          _calendarResponse(
            records: <Object?>[
              _calendarRecord(
                startTime: '2026-10-12 10:00:00',
                endTime: '2026-10-12 09:00:00',
              ),
            ],
          ),
        ),
      );
    });
  });

  group('list envelopes and pagination', () {
    test('requires numeric success envelope and bounded list fields', () {
      _expectInvalid(
        () => decodeYoungActivityPage(_activityResponse(success: false)),
      );
      _expectInvalid(
        () => decodeYoungActivityPage(_activityResponse(code: '200')),
      );
      _expectInvalid(
        () => decodeYoungActivityPage(_activityResponse(total: 1.0)),
      );
      _expectInvalid(
        () => decodeYoungActivityPage(_activityResponse(total: -1)),
      );
      _expectInvalid(
        () => decodeYoungActivityPage(_activityResponse(total: 10001)),
      );
      _expectInvalid(
        () => decodeYoungActivityPage(
          _activityResponse(records: _activities(11), total: 11),
        ),
      );
    });

    test('ignores echoed page metadata and copies decoded records', () {
      final rawRecords = _activities(1);
      final response = _activityResponse(
        records: rawRecords,
        total: 1,
        current: 99,
        size: 999,
        pages: -4,
      );
      final page = decodeYoungActivityPage(response);
      rawRecords.single['id'] = 'SYNTHETIC_MUTATED_ID';
      rawRecords.add(_activityRecord(id: 'SYNTHETIC_ADDED_AFTER_DECODE'));

      expect(page.total, 1);
      expect(page.records, hasLength(1));
      expect(page.records.single.id, 'SYNTHETIC_ACTIVITY_001');
      expect(
        () => page.records.add(page.records.single),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('holds records until consecutive pages prove the exact total', () {
      final firstRows = _activities(10);
      final accumulator = _activityAccumulator();
      accumulator.addResponse(
        requestedPage: 1,
        response: _activityResponse(
          records: firstRows,
          total: 12,
          current: 1,
          size: 10,
          pages: 8,
        ),
      );
      expect(accumulator.isComplete, isFalse);
      expect(accumulator.isFailed, isFalse);

      firstRows.first['id'] = 'SYNTHETIC_MUTATED_AFTER_PAGE_ONE';
      final lastRows = _activities(2, first: 11);
      accumulator.addResponse(
        requestedPage: 2,
        response: _activityResponse(
          records: lastRows,
          total: 12,
          current: 1,
          size: 10,
          pages: 8,
        ),
      );

      expect(accumulator.isComplete, isTrue);
      expect(accumulator.isFailed, isFalse);
      expect(accumulator.completedRecords, hasLength(12));
      expect(accumulator.completedRecords.first.id, 'SYNTHETIC_ACTIVITY_001');
      expect(
        () => accumulator.completedRecords.add(
          accumulator.completedRecords.first,
        ),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('an early result request fails the query terminally', () {
      final accumulator = _activityAccumulator();
      accumulator.addResponse(
        requestedPage: 1,
        response: _activityResponse(records: _activities(10), total: 12),
      );

      _expectIncomplete(() => accumulator.completedRecords);
      expect(accumulator.isFailed, isTrue);
      _expectInvalid(
        () => accumulator.addResponse(
          requestedPage: 2,
          response: _activityResponse(
            records: _activities(2, first: 11),
            total: 12,
          ),
        ),
      );
    });

    test('accepts only the first empty page for a zero total', () {
      final accumulator = _activityAccumulator();
      accumulator.addResponse(
        requestedPage: 1,
        response: _activityResponse(records: <Object?>[], total: 0),
      );

      expect(accumulator.isComplete, isTrue);
      expect(accumulator.completedRecords, isEmpty);
    });

    test('rejects early empty, short, or incorrectly sized final pages', () {
      final earlyEmpty = _activityAccumulator();
      _expectInvalid(
        () => earlyEmpty.addResponse(
          requestedPage: 1,
          response: _activityResponse(records: <Object?>[], total: 5),
        ),
      );

      final shortFirstPage = _activityAccumulator();
      _expectInvalid(
        () => shortFirstPage.addResponse(
          requestedPage: 1,
          response: _activityResponse(records: _activities(9), total: 15),
        ),
      );
      _expectInvalid(
        () => shortFirstPage.addResponse(
          requestedPage: 1,
          response: _activityResponse(records: _activities(10), total: 15),
        ),
      );

      final shortLastPage = _activityAccumulator();
      shortLastPage.addResponse(
        requestedPage: 1,
        response: _activityResponse(records: _activities(10), total: 11),
      );
      _expectInvalid(
        () => shortLastPage.addResponse(
          requestedPage: 2,
          response: _activityResponse(
            records: _activities(2, first: 11),
            total: 11,
          ),
        ),
      );
    });

    test('rejects duplicate IDs and changing totals', () {
      final duplicate = _activityAccumulator();
      duplicate.addResponse(
        requestedPage: 1,
        response: _activityResponse(records: _activities(10), total: 11),
      );
      _expectInvalid(
        () => duplicate.addResponse(
          requestedPage: 2,
          response: _activityResponse(
            records: <Object?>[_activityRecord(id: 'SYNTHETIC_ACTIVITY_001')],
            total: 11,
          ),
        ),
      );

      final changingTotal = _activityAccumulator();
      changingTotal.addResponse(
        requestedPage: 1,
        response: _activityResponse(records: _activities(10), total: 11),
      );
      _expectInvalid(
        () => changingTotal.addResponse(
          requestedPage: 2,
          response: _activityResponse(
            records: _activities(2, first: 11),
            total: 12,
          ),
        ),
      );
    });

    test('rejects out-of-order, duplicate, and post-completion pages', () {
      final outOfOrder = _activityAccumulator();
      _expectInvalid(
        () => outOfOrder.addResponse(
          requestedPage: 2,
          response: _activityResponse(records: _activities(1), total: 1),
        ),
      );
      expect(outOfOrder.isFailed, isTrue);
      _expectInvalid(
        () => outOfOrder.addResponse(
          requestedPage: 1,
          response: _activityResponse(records: _activities(1), total: 1),
        ),
      );

      final duplicatePage = _activityAccumulator();
      duplicatePage.addResponse(
        requestedPage: 1,
        response: _activityResponse(records: _activities(10), total: 12),
      );
      _expectInvalid(
        () => duplicatePage.addResponse(
          requestedPage: 1,
          response: _activityResponse(records: _activities(10), total: 12),
        ),
      );

      final complete = _activityAccumulator();
      complete.addResponse(
        requestedPage: 1,
        response: _activityResponse(records: _activities(1), total: 1),
      );
      expect(complete.isComplete, isTrue);
      _expectInvalid(
        () => complete.addResponse(
          requestedPage: 2,
          response: _activityResponse(records: <Object?>[], total: 1),
        ),
      );
      expect(complete.isFailed, isTrue);
      _expectInvalid(() => complete.completedRecords);
    });

    test(
      'a failed request is terminal and cannot be salvaged by later pages',
      () {
        final accumulator = _activityAccumulator();
        accumulator.fail();

        expect(accumulator.isFailed, isTrue);
        _expectInvalid(
          () => accumulator.addResponse(
            requestedPage: 1,
            response: _activityResponse(records: _activities(1), total: 1),
          ),
        );
        _expectInvalid(() => accumulator.completedRecords);
      },
    );
  });
}
