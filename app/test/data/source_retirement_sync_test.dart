import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agent_action_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_academic_details.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/core/jw_work_contract.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/core/young_work_contract.dart';
import 'package:ustc_assistant_m0/data/agent_plan_preview.dart';
import 'package:ustc_assistant_m0/data/jw_import_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/data/young_import_contract.dart';
import 'package:ustc_assistant_m0/source/jw_collection_contract.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';
import 'package:ustc_assistant_m0/source/young_business_contract.dart';
import 'package:ustc_assistant_m0/source/young_collection_contract.dart';

const _account = 'AB12345';
final _nowUtc = DateTime.utc(2026, 9, 30);
int _sequence = 0;

void main() {
  test(
    'JW retirement follows one semester, leaves other semesters intact, and restores overlays',
    () async {
      final store = await _open();
      await _preferences(store, reminders: true);

      await _importJw(
        store,
        semesterId: 202520,
        courses: [_course(901, 1901, '2025-10-01', 'Older semester course')],
      );
      await _importJw(
        store,
        semesterId: 202610,
        courses: [
          _course(101, 1101, '2026-10-01', 'Old course with annotation'),
          _course(
            102,
            1102,
            '2026-10-02',
            'Old course with reminder',
            startMinute: 660,
          ),
        ],
      );

      final monthStart = DateTime.utc(2026, 10, 1);
      final monthEnd = DateTime.utc(2026, 10, 11);
      final annotated = await _findOccurrence(
        store,
        title: 'Old course with annotation',
        firstDay: monthStart,
        endDayExclusive: monthEnd,
        includeHidden: true,
        includeRetired: true,
      );
      await _annotate(store, annotated, note: 'keep this note', hidden: true);

      final reminderCourse = await _findOccurrence(
        store,
        title: 'Old course with reminder',
        firstDay: monthStart,
        endDayExclusive: monthEnd,
      );
      const reminderPair = ReminderPair(
        ReminderRule.before(15),
        ReminderRule.none(),
      );
      await store.features.saveReminderPair(
        ReminderTarget.calendar(reminderCourse.reference),
        reminderPair,
      );
      var publication = await store.features.prepareReminderPublication();
      final oldReminder = publication.desired.singleWhere(
        (mapping) =>
            mapping.target.localId == reminderCourse.reference.identity.localId,
      );
      await _accept(store, publication);

      // The same complete semester now returns a different course set.
      await _importJw(
        store,
        semesterId: 202610,
        courses: [
          _course(201, 1201, '2026-10-10', 'New course', startMinute: 780),
        ],
      );

      var stored = await store.readView();
      final retiredNote = stored.events.singleWhere(
        (event) => event.title == 'Old course with annotation',
      );
      final retiredReminder = stored.events.singleWhere(
        (event) => event.title == 'Old course with reminder',
      );
      expect(retiredNote.sourceRetired, isTrue);
      expect(retiredReminder.sourceRetired, isTrue);
      expect(retiredNote.presence, JwPresence.missingWithinScope);

      final defaultWindow = await _query(
        store,
        firstDay: monthStart,
        endDayExclusive: monthEnd,
        includeHidden: true,
      );
      expect(defaultWindow.items.map((item) => item.title).toList(), [
        'New course',
      ]);
      final historyWindow = await _query(
        store,
        firstDay: monthStart,
        endDayExclusive: monthEnd,
        includeHidden: true,
        includeRetired: true,
      );
      expect(historyWindow.items.map((item) => item.title).toSet(), {
        'Old course with annotation',
        'Old course with reminder',
        'New course',
      });

      final morning = await store.briefs.morningFacts(
        DateTime.utc(2026, 10, 2),
      );
      expect(
        morning.agenda.map((item) => item.title),
        isNot(contains('Old course with reminder')),
      );

      // Planning receives a history-inclusive snapshot here on purpose; its
      // own default projection must still ignore the retired unhidden course.
      final planningWindow = await _query(
        store,
        firstDay: DateTime.utc(2026, 9, 30),
        endDayExclusive: DateTime.utc(2026, 10, 31),
        includeHidden: true,
        includeRetired: true,
      );
      final preview = previewAgentPlan(
        CalendarSnapshot(
          context: planningWindow.context,
          revision: planningWindow.revision,
          school: planningWindow.items,
          personal: const [],
          overrides: const [],
          relations: const [],
        ),
        [
          AgentCalendarChange(
            CreatePersonalEvent(
              PersonalEventDraft(
                title: 'Synthetic study block',
                start: DateTime.utc(2026, 10, 2, 3),
                end: DateTime.utc(2026, 10, 2, 3, 30),
              ),
            ),
          ),
        ],
        _nowUtc,
      );
      expect(preview.complete, isTrue);
      expect(preview.freeConstraintViolated, isFalse);

      publication = await store.features.prepareReminderPublication();
      expect(publication.invalidPriorIds, contains(oldReminder.request.id));
      final currentCourse = (await store.readView()).events.singleWhere(
        (event) => event.title == 'New course',
      );
      expect(
        publication.desired.any(
          (mapping) => mapping.target.localId == currentCourse.localId,
        ),
        isTrue,
      );
      expect(
        await store.features.resolveNotification(_activation(oldReminder)),
        isNull,
      );
      await store.features.recordReminderCancelled(oldReminder.request.id);
      await _accept(store, publication);

      // A complete import for a different semester may update presence, but
      // it must neither retire ordinary older courses nor revive this one.
      await _importJw(
        store,
        semesterId: 202620,
        courses: [_course(301, 1301, '2026-12-15', 'Other semester course')],
      );
      stored = await store.readView();
      expect(
        stored.events
            .singleWhere((event) => event.localId == retiredNote.localId)
            .sourceRetired,
        isTrue,
      );
      final olderSemester = stored.events.singleWhere(
        (event) => event.title == 'Older semester course',
      );
      expect(olderSemester.sourceRetired, isFalse);
      expect(olderSemester.presence, JwPresence.outsideScope);
      final olderCourseWindow = await _query(
        store,
        firstDay: DateTime.utc(2025, 10, 1),
        endDayExclusive: DateTime.utc(2025, 10, 2),
      );
      expect(olderCourseWindow.items.map((item) => item.title).toList(), [
        'Older semester course',
      ]);

      // Reappearance under the same stable key restores source validity while
      // preserving the user's local identity, note, visibility and reminder.
      await _importJw(
        store,
        semesterId: 202610,
        courses: [
          _course(101, 1101, '2026-10-01', 'Old course with annotation'),
          _course(
            102,
            1102,
            '2026-10-02',
            'Old course with reminder',
            startMinute: 660,
          ),
          _course(201, 1201, '2026-10-10', 'New course', startMinute: 780),
        ],
      );
      stored = await store.readView();
      final restored = stored.events.singleWhere(
        (event) => event.title == 'Old course with annotation',
      );
      expect(restored.localId, retiredNote.localId);
      expect(restored.sourceRetired, isFalse);
      expect(restored.hidden, isTrue);
      final restoredOccurrence = await _findOccurrence(
        store,
        title: 'Old course with annotation',
        firstDay: monthStart,
        endDayExclusive: monthEnd,
        includeHidden: true,
        includeRetired: true,
      );
      expect(restoredOccurrence.note, 'keep this note');
      final restoredReminder = await _findOccurrence(
        store,
        title: 'Old course with reminder',
        firstDay: monthStart,
        endDayExclusive: monthEnd,
      );
      expect(
        (await store.features.readReminderPair(
          ReminderTarget.calendar(restoredReminder.reference),
        ))?.canonical,
        reminderPair.canonical,
      );
    },
  );

  test(
    'Young retirement follows the selected date range and restores the same-key overlay',
    () async {
      final store = await _open();
      final first = DateTime.utc(2026, 10, 1);
      final last = DateTime.utc(2026, 10, 10);
      final target = _youngEvent('synthetic-young-01', 'Young target', 3, 10);
      final outside = _youngEvent(
        'synthetic-young-02',
        'Young outside range',
        8,
        11,
      );
      await _importYoung(
        store,
        firstDay: first,
        lastDay: last,
        entries: [target, outside],
      );

      final targetOccurrence = await _findOccurrence(
        store,
        title: 'Young target',
        firstDay: first,
        endDayExclusive: DateTime.utc(2026, 10, 11),
        includeHidden: true,
        includeRetired: true,
      );
      await _annotate(
        store,
        targetOccurrence,
        note: 'Young note',
        hidden: true,
      );
      final localId = (await store.readYoungView()).events
          .singleWhere((event) => event.title == 'Young target')
          .localId;

      // Missing inside the complete selected range retires; the Oct 8 event
      // lies outside this import's range and remains an ordinary old entry.
      await _importYoung(
        store,
        firstDay: first,
        lastDay: DateTime.utc(2026, 10, 5),
        entries: const [],
      );
      var view = await store.readYoungView();
      final retired = view.events.singleWhere(
        (event) => event.localId == localId,
      );
      expect(retired.sourceRetired, isTrue);
      expect(retired.presence, YoungPresence.missingWithinScope);
      final outsideRange = view.events.singleWhere(
        (event) => event.title == 'Young outside range',
      );
      expect(outsideRange.sourceRetired, isFalse);
      expect(outsideRange.presence, YoungPresence.outsideScope);

      // A later, different date range changes the old observation label but
      // cannot clear an already established retirement.
      await _importYoung(
        store,
        firstDay: DateTime.utc(2026, 10, 8),
        lastDay: DateTime.utc(2026, 10, 8),
        entries: [outside],
      );
      view = await store.readYoungView();
      final afterOtherRange = view.events.singleWhere(
        (event) => event.localId == localId,
      );
      expect(afterOtherRange.sourceRetired, isTrue);
      expect(afterOtherRange.presence, YoungPresence.outsideScope);
      expect(
        view.events
            .singleWhere((event) => event.title == 'Young outside range')
            .sourceRetired,
        isFalse,
      );
      final beforeRestore = await _query(
        store,
        firstDay: first,
        endDayExclusive: DateTime.utc(2026, 10, 11),
        includeHidden: true,
      );
      expect(beforeRestore.items.map((item) => item.title).toList(), [
        'Young outside range',
      ]);

      await _importYoung(
        store,
        firstDay: first,
        lastDay: DateTime.utc(2026, 10, 5),
        entries: [target],
      );
      view = await store.readYoungView();
      final restored = view.events.singleWhere(
        (event) => event.localId == localId,
      );
      expect(restored.sourceRetired, isFalse);
      expect(restored.presence, YoungPresence.observed);
      expect(restored.hidden, isTrue);
      final restoredOccurrence = await _findOccurrence(
        store,
        title: 'Young target',
        firstDay: first,
        endDayExclusive: DateTime.utc(2026, 10, 6),
        includeHidden: true,
        includeRetired: true,
      );
      expect(restoredOccurrence.note, 'Young note');
      expect(restoredOccurrence.sourceRetired, isFalse);
    },
  );

  test(
    'failed and cancelled full imports leave existing source validity untouched',
    () async {
      var failJw = false;
      var failYoung = false;
      final store = await _open(
        onJw: (checkpoint) async {
          if (failJw && checkpoint == JwImportCheckpoint.beforeCommit) {
            throw const AppFailure(FailureCode.storageFailed);
          }
        },
        onYoung: (checkpoint) async {
          if (failYoung && checkpoint == YoungStoreCheckpoint.beforeCommit) {
            throw const AppFailure(FailureCode.storageFailed);
          }
        },
      );
      final jw = _course(501, 1501, '2026-10-03', 'JW remains active');
      final first = DateTime.utc(2026, 10, 1);
      final last = DateTime.utc(2026, 10, 5);
      final young = _youngEvent(
        'synthetic-young-failure',
        'Young remains active',
        3,
        12,
      );
      await _importJw(store, semesterId: 202610, courses: [jw]);
      await _importYoung(
        store,
        firstDay: first,
        lastDay: last,
        entries: [young],
      );

      failJw = true;
      await expectLater(
        _importJw(store, semesterId: 202610, courses: const []),
        throwsA(isA<AppFailure>()),
      );
      failJw = false;
      var jwRow = (await store.readView()).events.singleWhere(
        (event) => event.title == 'JW remains active',
      );
      expect(jwRow.sourceRetired, isFalse);
      expect(jwRow.presence, JwPresence.observed);

      await _cancelJwImport(store, semesterId: 202610);
      jwRow = (await store.readView()).events.singleWhere(
        (event) => event.title == 'JW remains active',
      );
      expect(jwRow.sourceRetired, isFalse);
      expect(jwRow.presence, JwPresence.observed);

      failYoung = true;
      await expectLater(
        _importYoung(store, firstDay: first, lastDay: last, entries: const []),
        throwsA(isA<AppFailure>()),
      );
      failYoung = false;
      var youngRow = (await store.readYoungView()).events.singleWhere(
        (event) => event.title == 'Young remains active',
      );
      expect(youngRow.sourceRetired, isFalse);
      expect(youngRow.presence, YoungPresence.observed);

      await _cancelYoungImport(store, firstDay: first, lastDay: last);
      youngRow = (await store.readYoungView()).events.singleWhere(
        (event) => event.title == 'Young remains active',
      );
      expect(youngRow.sourceRetired, isFalse);
      expect(youngRow.presence, YoungPresence.observed);
    },
  );
}

Future<JwStore> _open({
  Future<void> Function(JwImportCheckpoint)? onJw,
  Future<void> Function(YoungStoreCheckpoint)? onYoung,
}) async {
  final protector = _SyntheticProtector();
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _SyntheticOwnership(),
    clock: _MutableClock(_nowUtc),
    credentialProtector: protector,
    modelCredentialProtector: protector,
    onCheckpoint: onJw,
    onYoungCheckpoint: onYoung,
  );
  addTearDown(store.close);
  await store.initialize();
  await store.agent.initializeAgent();
  await store.features.initialize();
  return store;
}

Future<void> _preferences(JwStore store, {bool? reminders}) async {
  final current = await store.features.inspectReminders();
  await store.features.saveReminderPreferences(
    current,
    current.preferences.copyWith(enabled: reminders),
  );
}

Future<void> _importJw(
  JwStore store, {
  required int semesterId,
  required List<_CourseFixture> courses,
}) async {
  final (ticket, artifact) = await _prepareJw(
    store,
    semesterId: semesterId,
    courses: courses,
  );
  await store.importSnapshot(ticket, artifact);
}

Future<(JwJobTicket, JwCollectedArtifact)> _prepareJw(
  JwStore store, {
  required int semesterId,
  required List<_CourseFixture> courses,
}) async {
  final ticket = await store.beginJob(expectedAccountCode: _account);
  final partition = JwPartitionRef(
    id: _newId('jwp-'),
    ownerId: ticket.stamp.ownerId,
    purpose: JwPartitionPurpose.initial,
    attempt: ticket.stamp.jobId,
    resetEpoch: ticket.stamp.resetEpoch,
  );
  await store.stagePartition(ticket, partition);
  await store.stageSemesterCatalog(ticket, const [
    JwSemesterOption(
      id: 202520,
      name: 'Synthetic earlier semester',
      selected: false,
    ),
    JwSemesterOption(
      id: 202610,
      name: 'Synthetic current semester',
      selected: false,
    ),
    JwSemesterOption(
      id: 202620,
      name: 'Synthetic later semester',
      selected: false,
    ),
  ]);
  final rows = [
    for (final course in courses)
      {
        'lessonId': course.lessonId,
        'groupId': course.groupId,
        'date': course.date,
        'startMinute': course.startMinute,
        'endMinute': course.startMinute + 60,
        'title': course.title,
        'academicDetails': JwAcademicDetails(
          lessonId: course.lessonId,
          groupId: course.groupId,
        ).toMap(),
      },
  ];
  final count = rows.length;
  final reply = JwCollectionReply.decode(
    jsonEncode({
      'operation': 31,
      'phase': 'done',
      'code': 'ok',
      'identity': {
        'candidateCount': 1,
        'method': 'table',
        'accountCode': _account,
      },
      'diagnostics': {
        'checks': {
          'identityBefore': 'ok',
          'course': 'ok',
          'index': 'ok',
          'datum': count == 0 ? 'skipped' : 'ok',
          'exams': 'ok',
          'identityAfter': 'ok',
        },
        'reason': 'none',
        'identityReads': 2,
        'lessonIds': count,
        'lessons': count,
        'groups': count,
        'schedules': count,
        'datedSchedules': count,
        'timedSchedules': count,
        'linkedSchedules': count,
        'examRows': 0,
        'datedExams': 0,
        'semesterAccepted': true,
        'selfRouteBound': true,
        'identityStable': true,
        'emptyCourse': count == 0,
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
      },
      'snapshot': {
        'version': jwContractVersion,
        'semesterId': semesterId,
        'courses': rows,
        'exams': <Object>[],
      },
    }),
    operation: 31,
  );
  return (
    ticket,
    JwCollectedArtifact.seal(
      reply: reply,
      stamp: ticket.stamp,
      partition: partition,
      session: 1,
      document: 2,
      semesterId: semesterId,
      collectedAtUtc: _nowUtc,
    ),
  );
}

Future<void> _cancelJwImport(JwStore store, {required int semesterId}) async {
  final (ticket, artifact) = await _prepareJw(
    store,
    semesterId: semesterId,
    courses: const [],
  );
  expect(await store.cancelJob(ticket), isTrue);
  await expectLater(
    store.importSnapshot(ticket, artifact),
    throwsA(isA<AppFailure>()),
  );
}

Future<void> _importYoung(
  JwStore store, {
  required DateTime firstDay,
  required DateTime lastDay,
  required List<_YoungFixture> entries,
}) async {
  final (ticket, artifact) = await _prepareYoung(
    store,
    firstDay: firstDay,
    lastDay: lastDay,
    entries: entries,
  );
  await store.importYoungCalendar(ticket, artifact);
}

Future<(YoungJobTicket, YoungCollectedArtifact)> _prepareYoung(
  JwStore store, {
  required DateTime firstDay,
  required DateTime lastDay,
  required List<_YoungFixture> entries,
}) async {
  final ticket = await store.beginYoungJob(
    kind: YoungJobKind.calendar,
    expectedAccountCode: _account,
    firstDay: firstDay,
    lastDay: lastDay,
  );
  final partition = YoungPartitionRef(
    id: _newId('yp-'),
    ownerId: ticket.stamp.ownerId,
    purpose: ticket.stamp.accountId == null
        ? YoungPartitionPurpose.initial
        : YoungPartitionPurpose.recovery,
    attempt: ticket.stamp.jobId,
    resetEpoch: ticket.stamp.resetEpoch,
  );
  await store.stageYoungPartition(ticket, partition);
  final records = [
    for (final entry in entries)
      {
        'id': entry.id,
        'itemId': 'synthetic-activity-${entry.id}',
        'title': entry.title,
        'place': 'Synthetic room',
        'startTime':
            '${entry.day} ${entry.hour.toString().padLeft(2, '0')}:00:00',
        'endTime':
            '${entry.day} ${(entry.hour + 1).toString().padLeft(2, '0')}:00:00',
      },
  ];
  final decoded = decodeYoungCalendarPage({
    'success': true,
    'code': 200,
    'result': {'records': records, 'total': records.length},
  });
  final profile = decodeYoungProfile({
    'success': true,
    'code': 200,
    'result': {'username': _account},
  });
  return (
    ticket,
    YoungCollectedArtifact.seal(
      profileBefore: profile,
      profileAfter: profile,
      stamp: ticket.stamp,
      partition: partition,
      session: 1,
      document: 2,
      operation: 3,
      collectedAtUtc: _nowUtc,
      activities: const [],
      entries: decoded.records,
      activityPages: 0,
      calendarPages: lastDay.difference(firstDay).inDays + 1,
      calendarRows: records.length,
      excludedSchedules: 0,
      days: lastDay.difference(firstDay).inDays + 1,
      firstDay: firstDay,
      lastDay: lastDay,
    ),
  );
}

Future<void> _cancelYoungImport(
  JwStore store, {
  required DateTime firstDay,
  required DateTime lastDay,
}) async {
  final (ticket, artifact) = await _prepareYoung(
    store,
    firstDay: firstDay,
    lastDay: lastDay,
    entries: const [],
  );
  expect(await store.cancelYoungJob(ticket), isTrue);
  await expectLater(
    store.importYoungCalendar(ticket, artifact),
    throwsA(isA<AppFailure>()),
  );
}

Future<CalendarWindow> _query(
  JwStore store, {
  required DateTime firstDay,
  required DateTime endDayExclusive,
  bool includeHidden = false,
  bool includeRetired = false,
}) => store.localCalendar.query(
  CalendarQuery(
    firstDay: firstDay,
    endDayExclusive: endDayExclusive,
    includeHidden: includeHidden,
    includeSkipped: true,
    includeRetired: includeRetired,
  ),
);

Future<CalendarOccurrence> _findOccurrence(
  JwStore store, {
  required String title,
  required DateTime firstDay,
  required DateTime endDayExclusive,
  bool includeHidden = false,
  bool includeRetired = false,
}) async {
  final window = await _query(
    store,
    firstDay: firstDay,
    endDayExclusive: endDayExclusive,
    includeHidden: includeHidden,
    includeRetired: includeRetired,
  );
  return window.items.singleWhere((item) => item.title == title);
}

Future<void> _annotate(
  JwStore store,
  CalendarOccurrence occurrence, {
  required String note,
  required bool hidden,
}) async {
  final intent = UpdateSchoolAnnotation(
    occurrence.reference,
    note: note,
    hidden: hidden,
  );
  final command = await store.localCalendar.prepare(
    occurrence.reference.context,
    intent,
  );
  await store.localCalendar.commit(command);
}

Future<void> _accept(JwStore store, ReminderPublication publication) async {
  for (final mapping in publication.desired) {
    await store.features.recordReminderAccepted(
      publication,
      mapping.request.id,
    );
  }
}

NotificationActivation _activation(ReminderMapping mapping) =>
    NotificationActivation(
      mapping.request.id,
      mapping.request.digest,
      mapping.request.token,
    );

_CourseFixture _course(
  int lessonId,
  int groupId,
  String date,
  String title, {
  int startMinute = 600,
}) => _CourseFixture(lessonId, groupId, date, title, startMinute);

_YoungFixture _youngEvent(String id, String title, int day, int hour) =>
    _YoungFixture(id, title, '2026-10-${day.toString().padLeft(2, '0')}', hour);

String _newId(String prefix) =>
    '$prefix${(++_sequence).toRadixString(16).padLeft(32, '0')}';

final class _CourseFixture {
  const _CourseFixture(
    this.lessonId,
    this.groupId,
    this.date,
    this.title,
    this.startMinute,
  );
  final int lessonId, groupId, startMinute;
  final String date, title;
}

final class _YoungFixture {
  const _YoungFixture(this.id, this.title, this.day, this.hour);
  final String id, title, day;
  final int hour;
}

final class _MutableClock implements AppClock {
  _MutableClock(this.nowUtc);
  @override
  DateTime nowUtc;
}

final class _SyntheticOwnership implements AssetOwnership {
  @override
  bool get isHeld => true;
  @override
  void ensureHeld() {}
}

final class _SyntheticProtector
    implements JwCredentialProtector, ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-source-retirement-test/v1';

  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async => Uint8List.fromList(plaintext.map((byte) => byte ^ 0x5A).toList());

  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) async =>
      Uint8List.fromList(ciphertext.map((byte) => byte ^ 0x5A).toList());
}
