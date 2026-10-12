import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/young_work_contract.dart';
import 'package:ustc_assistant_m0/source/young_business_contract.dart';
import 'package:ustc_assistant_m0/source/young_collection_contract.dart';

const String _syntheticAccount = 'SYNTHETIC_USER_01';
const String _ownerId = 'jw-owner-00000000000000000000000000000001';

YoungProfileCandidate _profile([String username = _syntheticAccount]) =>
    decodeYoungProfile(<String, Object?>{
      'success': true,
      'code': 200,
      'result': <String, Object?>{'username': username},
    });

YoungWorkStamp _stamp(YoungJobKind kind) => YoungWorkStamp(
  jobId: 'young-2-1',
  ownerId: _ownerId,
  generation: 1,
  resetEpoch: 2,
  kind: kind,
);

YoungPartitionRef _partition() => YoungPartitionRef(
  id: 'yp-00000000000000000000000000000001',
  ownerId: _ownerId,
  purpose: YoungPartitionPurpose.initial,
  attempt: 'young-2-1',
  resetEpoch: 2,
);

Map<String, Object?> _activityRecord(String id) => <String, Object?>{
  'id': id,
  'itemName': 'Synthetic activity $id',
  'st': '2026-10-12 09:00:00',
  'et': '2026-10-12 10:00:00',
  'applySt': '2026-10-10 08:00:00',
  'applyEt': '2026-10-11 18:00:00',
  'placeInfo': 'Synthetic venue',
};

YoungActivity _activity(String id) => decodeYoungActivityPage(<String, Object?>{
  'success': true,
  'code': 200,
  'result': <String, Object?>{
    'records': <Object?>[_activityRecord(id)],
    'total': 1,
  },
}).records.single;

Map<String, Object?> _calendarRecord({
  required String id,
  String itemId = 'SYNTHETIC_ACTIVITY_001',
  String start = '2026-10-12 09:00:00',
  String end = '2026-10-12 10:00:00',
}) => <String, Object?>{
  'id': id,
  'title': 'Synthetic calendar entry $id',
  'place': 'Synthetic room',
  'startTime': start,
  'endTime': end,
  'itemId': itemId,
};

YoungCalendarEntry _entry({
  required String id,
  String itemId = 'SYNTHETIC_ACTIVITY_001',
  String start = '2026-10-12 09:00:00',
  String end = '2026-10-12 10:00:00',
}) => decodeYoungCalendarPage(<String, Object?>{
  'success': true,
  'code': 200,
  'result': <String, Object?>{
    'records': <Object?>[
      _calendarRecord(id: id, itemId: itemId, start: start, end: end),
    ],
    'total': 1,
  },
}).records.single;

YoungCollectedArtifact _sealActivities({
  List<YoungActivity> activities = const <YoungActivity>[],
  int? activityPages,
  List<YoungCalendarEntry> entries = const <YoungCalendarEntry>[],
  YoungProfileCandidate? before,
  YoungProfileCandidate? after,
  YoungWorkStamp? stamp,
  YoungPartitionRef? partition,
}) => YoungCollectedArtifact.seal(
  profileBefore: before ?? _profile(),
  profileAfter: after ?? _profile(),
  stamp: stamp ?? _stamp(YoungJobKind.activities),
  partition: partition ?? _partition(),
  session: 1,
  document: 1,
  operation: 1,
  collectedAtUtc: DateTime.utc(2026, 10, 12, 3),
  activities: activities,
  entries: entries,
  activityPages:
      activityPages ?? (activities.isEmpty ? 1 : (activities.length + 9) ~/ 10),
  calendarPages: 0,
  calendarRows: 0,
  excludedSchedules: 0,
  days: 0,
  firstDay: null,
  lastDay: null,
);

YoungCollectedArtifact _sealCalendar({
  List<YoungCalendarEntry> entries = const <YoungCalendarEntry>[],
  int calendarRows = 0,
  int excludedSchedules = 0,
  int days = 1,
  int calendarPages = 1,
  DateTime? firstDay,
  DateTime? lastDay,
  List<YoungActivity> activities = const <YoungActivity>[],
  YoungProfileCandidate? before,
  YoungProfileCandidate? after,
}) => YoungCollectedArtifact.seal(
  profileBefore: before ?? _profile(),
  profileAfter: after ?? _profile(),
  stamp: _stamp(YoungJobKind.calendar),
  partition: _partition(),
  session: 1,
  document: 1,
  operation: 1,
  collectedAtUtc: DateTime.utc(2026, 10, 12, 3),
  activities: activities,
  entries: entries,
  activityPages: 0,
  calendarPages: calendarPages,
  calendarRows: calendarRows,
  excludedSchedules: excludedSchedules,
  days: days,
  firstDay: firstDay ?? DateTime.utc(2026, 10, 12),
  lastDay: lastDay ?? DateTime.utc(2026, 10, 12),
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

void main() {
  group('Young collected artifact', () {
    test(
      'seals activity and linked calendar kinds with fixed source versions',
      () {
        final activity = _sealActivities(
          activities: <YoungActivity>[_activity('SYNTHETIC_ACTIVITY_001')],
        );
        expect(activity.sourceKey, 'young_activities');
        expect(activity.contractVersion, 'young-activities-v1');
        expect(activity.activities, hasLength(1));
        expect(activity.stats.activityPages, 1);
        expect(activity.stats.activities, 1);
        expect(activity.entries, isEmpty);
        expect(activity.rangeStartUtc, isNull);
        expect(activity.toString(), 'YoungCollectedArtifact');
        expect(
          () => jsonEncode(activity),
          throwsA(isA<JsonUnsupportedObjectError>()),
        );

        final calendar = _sealCalendar(
          entries: <YoungCalendarEntry>[_entry(id: 'SYNTHETIC_ENTRY_001')],
          calendarRows: 3,
          excludedSchedules: 1,
        );
        expect(calendar.sourceKey, 'young_calendar');
        expect(calendar.contractVersion, 'young-linked-calendar-v1');
        expect(calendar.days, 1);
        expect(calendar.firstDay, DateTime.utc(2026, 10, 12));
        expect(calendar.rangeStartUtc, DateTime.utc(2026, 10, 11, 16));
        expect(calendar.rangeEndUtc, DateTime.utc(2026, 10, 12, 16));
        expect(calendar.stats.events, 1);
        expect(calendar.stats.calendarRows, 3);
        expect(calendar.stats.excludedSchedules, 1);
        expect(calendar.stats.duplicateSchedules, 1);
      },
    );

    test('copies record lists and exposes only closed counters', () {
      final activities = <YoungActivity>[_activity('SYNTHETIC_ACTIVITY_001')];
      final artifact = _sealActivities(activities: activities);
      activities.clear();
      expect(artifact.activities, hasLength(1));
      expect(
        () => artifact.activities.add(_activity('SYNTHETIC_ACTIVITY_002')),
        throwsA(isA<UnsupportedError>()),
      );
      expect(artifact.stats.safeProjection.keys.toSet(), <String>{
        'calendarRows',
        'events',
        'excludedSchedules',
        'duplicateSchedules',
        'days',
        'calendarPages',
        'activityPages',
        'activities',
      });
      expect(
        () => artifact.stats.safeProjection['account'] = _syntheticAccount,
        throwsA(isA<UnsupportedError>()),
      );
      expect(artifact.stats.toString(), 'YoungCollectionStats');
    });

    test('keeps profile usernames private and compares the C3 expectation', () {
      final artifact = _sealActivities();
      expect(artifact.matchesExpected(_syntheticAccount), isTrue);
      expect(artifact.matchesExpected('SYNTHETIC_OTHER_USER'), isFalse);
      expect(artifact.toString(), isNot(contains(_syntheticAccount)));
    });

    test('reports changed before and after identity evidence specifically', () {
      expect(
        () => _sealActivities(
          before: _profile(),
          after: _profile('SYNTHETIC_OTHER_USER'),
        ),
        throwsA(
          isA<YoungIdentityException>().having(
            (YoungIdentityException error) => error.code,
            'code',
            YoungIdentityFailure.evidenceConflict,
          ),
        ),
      );
    });

    test(
      'rejects cross-kind fields, mismatched partition stamps, and page counts',
      () {
        _expectInvalid(
          () => _sealActivities(
            entries: <YoungCalendarEntry>[_entry(id: 'SYNTHETIC_ENTRY_001')],
          ),
        );
        _expectInvalid(
          () => _sealCalendar(
            activities: <YoungActivity>[_activity('SYNTHETIC_ACTIVITY_001')],
          ),
        );
        _expectInvalid(
          () => _sealActivities(
            activities: <YoungActivity>[
              _activity('SYNTHETIC_ACTIVITY_001'),
              _activity('SYNTHETIC_ACTIVITY_002'),
            ],
            activityPages: 2,
          ),
        );
        _expectInvalid(
          () => _sealActivities(
            stamp: YoungWorkStamp(
              jobId: 'young-2-1',
              ownerId: _ownerId,
              generation: 1,
              resetEpoch: 2,
              kind: YoungJobKind.calendar,
            ),
          ),
        );
        _expectInvalid(
          () => _sealActivities(
            partition: YoungPartitionRef(
              id: 'yp-00000000000000000000000000000001',
              ownerId: _ownerId,
              purpose: YoungPartitionPurpose.initial,
              attempt: 'young-1-1',
              resetEpoch: 3,
            ),
          ),
        );
      },
    );

    test('requires unique IDs and activity-linked calendar records only', () {
      _expectInvalid(
        () => _sealActivities(
          activities: <YoungActivity>[
            _activity('SYNTHETIC_ACTIVITY_001'),
            _activity('SYNTHETIC_ACTIVITY_001'),
          ],
        ),
      );
      _expectInvalid(
        () => _sealCalendar(
          entries: <YoungCalendarEntry>[
            _entry(id: 'SYNTHETIC_ENTRY_001'),
            _entry(id: 'SYNTHETIC_ENTRY_001'),
          ],
          calendarRows: 2,
        ),
      );
      _expectInvalid(
        () => _sealCalendar(
          entries: <YoungCalendarEntry>[
            _entry(id: 'SYNTHETIC_ENTRY_001', itemId: ''),
          ],
          calendarRows: 1,
        ),
      );
    });

    test(
      'allows a valid already-claimed partition from an earlier job attempt',
      () {
        final artifact = YoungCollectedArtifact.seal(
          profileBefore: _profile(),
          profileAfter: _profile(),
          stamp: YoungWorkStamp(
            jobId: 'young-2-2',
            ownerId: _ownerId,
            generation: 2,
            resetEpoch: 2,
            kind: YoungJobKind.activities,
          ),
          partition: YoungPartitionRef(
            id: 'yp-00000000000000000000000000000001',
            ownerId: _ownerId,
            purpose: YoungPartitionPurpose.initial,
            attempt: 'young-2-1',
            resetEpoch: 2,
          ),
          session: 1,
          document: 1,
          operation: 1,
          collectedAtUtc: DateTime.utc(2026, 10, 12, 3),
          activities: const <YoungActivity>[],
          entries: const <YoungCalendarEntry>[],
          activityPages: 1,
          calendarPages: 0,
          calendarRows: 0,
          excludedSchedules: 0,
          days: 0,
          firstDay: null,
          lastDay: null,
        );

        expect(artifact.stamp.jobId, 'young-2-2');
        expect(artifact.partition.attempt, 'young-2-1');
      },
    );

    test('validates Beijing date scope and interval intersection', () {
      _expectInvalid(
        () => _sealCalendar(
          entries: <YoungCalendarEntry>[
            _entry(
              id: 'SYNTHETIC_OUTSIDE_ENTRY',
              start: '2026-10-11 14:00:00',
              end: '2026-10-11 15:00:00',
            ),
          ],
          calendarRows: 1,
        ),
      );
      _expectInvalid(
        () => _sealCalendar(
          entries: <YoungCalendarEntry>[_entry(id: 'SYNTHETIC_ENTRY_001')],
          calendarRows: 1,
          days: 2,
        ),
      );
      _expectInvalid(
        () => _sealCalendar(
          entries: <YoungCalendarEntry>[_entry(id: 'SYNTHETIC_ENTRY_001')],
          calendarRows: 1,
          firstDay: DateTime(2026, 10, 12),
        ),
      );
      _expectInvalid(
        () => _sealCalendar(
          entries: <YoungCalendarEntry>[_entry(id: 'SYNTHETIC_ENTRY_001')],
          calendarRows: 10001,
        ),
      );
      _expectInvalid(
        () => _sealCalendar(
          entries: <YoungCalendarEntry>[_entry(id: 'SYNTHETIC_ENTRY_001')],
          calendarRows: 1,
          excludedSchedules: 1,
        ),
      );
    });

    test(
      'fingerprint is order-independent but follows necessary data and account',
      () {
        final first = _sealActivities(
          activities: <YoungActivity>[
            _activity('SYNTHETIC_ACTIVITY_001'),
            _activity('SYNTHETIC_ACTIVITY_002'),
          ],
        );
        final reordered = _sealActivities(
          activities: <YoungActivity>[
            _activity('SYNTHETIC_ACTIVITY_002'),
            _activity('SYNTHETIC_ACTIVITY_001'),
          ],
        );
        final otherAccount = _sealActivities(
          before: _profile('SYNTHETIC_OTHER_USER'),
          after: _profile('SYNTHETIC_OTHER_USER'),
          activities: <YoungActivity>[
            _activity('SYNTHETIC_ACTIVITY_001'),
            _activity('SYNTHETIC_ACTIVITY_002'),
          ],
        );
        expect(first.contentFingerprint, reordered.contentFingerprint);
        expect(
          first.contentFingerprint,
          isNot(otherAccount.contentFingerprint),
        );
        expect(first.contentFingerprint, hasLength(64));
      },
    );
  });
}
