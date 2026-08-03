import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_permission_policy_service.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_agent_write_gateway.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_permission_policy.dart';
import 'package:ustc_assistant_app/features/calendar/application/recurrence_service.dart';
import 'package:ustc_assistant_app/features/calendar/domain/calendar_event_locator.dart';
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';
import 'package:ustc_assistant_app/features/calendar/domain/recurrence_rule.dart';
import 'package:ustc_assistant_app/features/schedule/application/effective_event_repository.dart';
import 'package:ustc_assistant_app/features/schedule/application/overlay_service.dart';
import 'package:ustc_assistant_app/features/schedule/domain/jw_day_move.dart';
import 'package:ustc_assistant_app/features/tasks/domain/plan_block.dart';

class _FixedClock implements BeijingClock {
  @override
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
}

/// Beijing wall clock -> the app's UTC epoch-ms storage encoding.
int _beijingEpoch(int year, int month, int day, int hour, [int minute = 0]) =>
    DateTime.utc(year, month, day, hour, minute).millisecondsSinceEpoch -
    const Duration(hours: 8).inMilliseconds;

/// Seeds a `ustc_jw/course` timed event on the source day with a source record.
Future<void> _seedJwCourse(
  AppDatabase db,
  String accountId,
  String id, {
  required int startAt,
  required int endAt,
}) async {
  await db.into(db.calendarEvents).insert(
        CalendarEventsCompanion.insert(
          id: id,
          accountId: accountId,
          source: 'ustc_jw',
          externalId: Value(id),
          title: '课程 $id',
          type: 'course',
          startAt: Value(startAt),
          endAt: Value(endAt),
          allDay: false,
          timezone: 'Asia/Shanghai',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
  await db.into(db.sourceRecords).insert(
        SourceRecordsCompanion.insert(
          id: 'sr-$id',
          accountId: accountId,
          source: 'ustc_jw',
          entityType: 'calendar_event',
          externalId: id,
          localEntityId: id,
          sourceStatus: 'active',
          presence: 'present',
          scopeKey: 'scope',
          firstObservedAt: 1,
          lastObservedAt: 1,
        ),
      );
}

void main() {
  late AppDatabase db;
  late AgentPermissionPolicyService policy;
  late DriftAgentWriteGateway gateway;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.customStatement('PRAGMA foreign_keys = OFF');
    policy = AgentPermissionPolicyService(database: db, clock: _FixedClock());
    gateway = DriftAgentWriteGateway(
      database: db,
      accountId: 'acc-1',
      policy: policy,
      now: () => 1_700_000_000_000,
    );
  });

  tearDown(() => db.close());

  test('createEvent inserts a personal event', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    final row = await (db.select(db.calendarEvents)..where((r) => r.id.equals('ev-1'))).getSingle();
    expect(row.title, '健身');
    expect(row.source, 'user');
  });

  test('createTask and planTask insert rows', () async {
    final taskId = await gateway.createTask(title: '写作业', estimatedMinutes: 60);
    expect(await gateway.taskById(taskId).then((t) => t.title), '写作业');
    final blockId = await gateway.planTask(
      taskId: taskId,
      startAt: DateTime(2026, 8, 2, 20),
      endAt: DateTime(2026, 8, 2, 21),
      status: PlanBlockStatus.accepted,
    );
    expect((await gateway.planBlockById(blockId)).taskId, taskId);
  });

  test('editPersonalEvent updates and cancel/softDelete transition', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    await gateway.editPersonalEvent('ev-1', PersonalEvent.timed(
      id: 'ev-1',
      title: '健身改五点',
      startAt: DateTime(2026, 8, 1, 17),
      endAt: DateTime(2026, 8, 1, 18),
    ));
    var row = await (db.select(db.calendarEvents)..where((r) => r.id.equals('ev-1'))).getSingle();
    expect(row.title, '健身改五点');

    await gateway.cancelEvent('ev-1');
    row = await (db.select(db.calendarEvents)..where((r) => r.id.equals('ev-1'))).getSingle();
    expect(row.status, 'cancelled');

    await gateway.softDeleteEvent('ev-1');
    row = await (db.select(db.calendarEvents)..where((r) => r.id.equals('ev-1'))).getSingle();
    expect(row.deletedAt, isNotNull);
  });

  test('eventSnapshot reports personal/recurring', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    final snapshot = await gateway.eventSnapshot('ev-1');
    expect(snapshot.isPersonal, isTrue);
    expect(snapshot.isRecurring, isFalse);
    expect(snapshot.title, '健身');
    expect(snapshot.startAt, DateTime(2026, 8, 1, 15));
    expect(snapshot.endAt, DateTime(2026, 8, 1, 16));
  });

  test('recordAttendanceDecision and setEventOverlay write overlays', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    await gateway.recordAttendanceDecision('ev-1', AttendanceDecision.go);
    await gateway.setEventOverlay('ev-1', const OverlayMutation(
      attendancePolicy: AttendancePolicy.mustGo,
      listeningNote: '去占座补作业',
    ));
    final overlay = await db.select(db.userOverlays).getSingle();
    expect(overlay.attendanceDecision, 'go');
    expect(overlay.attendancePolicy, 'must_go');
  });

  test('createConflictRelation writes a conflict relation row', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '课程A',
      startAt: DateTime(2026, 8, 1, 9),
      endAt: DateTime(2026, 8, 1, 10),
    ));
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-2',
      title: '课程B',
      startAt: DateTime(2026, 8, 1, 9),
      endAt: DateTime(2026, 8, 1, 10),
    ));
    await gateway.createConflictRelation(
      leftKind: 'event',
      leftId: 'ev-1',
      rightKind: 'event',
      rightId: 'ev-2',
      conflictState: 'no_conflict',
      reason: '二选一，用户已决定',
    );
    final relation = await db.select(db.scheduleRelations).getSingle();
    expect(relation.relationType, 'conflict');
    expect(relation.conflictState, 'no_conflict');
  });

  test('createConflictRelation canonicalizes reverse insertions to one row',
      () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '课程A',
      startAt: DateTime(2026, 8, 1, 9),
      endAt: DateTime(2026, 8, 1, 10),
    ));
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-2',
      title: '课程B',
      startAt: DateTime(2026, 8, 1, 9),
      endAt: DateTime(2026, 8, 1, 10),
    ));
    await gateway.createConflictRelation(
      leftKind: 'event',
      leftId: 'ev-1',
      rightKind: 'event',
      rightId: 'ev-2',
      conflictState: 'conflict',
    );
    // Reverse insertion must land on the same canonical row.
    await gateway.createConflictRelation(
      leftKind: 'event',
      leftId: 'ev-2',
      rightKind: 'event',
      rightId: 'ev-1',
      conflictState: 'no_conflict',
    );
    final rows = await db.select(db.scheduleRelations).get();
    expect(rows, hasLength(1));
    final row = rows.single;
    expect(row.leftId, 'ev-1');
    expect(row.rightId, 'ev-2');
    expect(row.conflictState, 'no_conflict');
    expect(row.leftEventId, 'ev-1');
    expect(row.rightEventId, 'ev-2');
    expect(row.leftPlanBlockId, isNull);
    expect(row.rightPlanBlockId, isNull);
  });

  test('createConflictRelation writes plan_block with plan block FK columns',
      () async {
    // FK enforcement is off in this fixture, so targets need not exist.
    await gateway.createConflictRelation(
      leftKind: 'event',
      leftId: 'ev-1',
      rightKind: 'plan_block',
      rightId: 'pb-1',
      conflictState: 'conflict',
    );
    final row = await db.select(db.scheduleRelations).getSingle();
    expect(row.leftKind, 'event');
    expect(row.leftId, 'ev-1');
    expect(row.rightKind, 'plan_block');
    expect(row.rightId, 'pb-1');
    expect(row.leftEventId, 'ev-1');
    expect(row.leftPlanBlockId, isNull);
    expect(row.rightEventId, isNull);
    expect(row.rightPlanBlockId, 'pb-1');
  });

  test('setReminder writes reminder rows via override service', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    await gateway.setReminder('ev-1', const [15]);
    final reminders = await db.select(db.reminders).get();
    expect(reminders.single.eventId, 'ev-1');
    expect(reminders.single.offsetMinutes, 15);
  });

  test('eventSnapshot reads own account event with identity + course series', () async {
    // Two accounts' local account rows so foreign keys are satisfiable.
    await db.into(db.localAccounts).insert(LocalAccountsCompanion.insert(
      id: 'acc-2', maskedHint: 'PB****0000',
      isActive: const Value(true), createdAt: 1, updatedAt: 1,
    ));
    // Account A: a source (ustc_jw) course event belonging to a course series.
    await db.into(db.courseSeries).insert(CourseSeriesCompanion.insert(
      id: 'cs-1', accountId: 'acc-1', source: 'ustc_jw', externalId: 'lesson-phys',
      title: '大学物理', semesterKey: '2026spring', participantsJson: const Value('[]'),
      sourceDetailsJson: '{}', createdAt: 1, updatedAt: 1,
    ));
    await db.into(db.calendarEvents).insert(CalendarEventsCompanion.insert(
      id: 'event-a', accountId: 'acc-1', source: 'ustc_jw',
      sourceSeriesExternalId: const Value('lesson-phys'),
      title: '量子物理 B', type: 'course',
      startAt: Value(DateTime(2026, 3, 17, 9, 45).toUtc().millisecondsSinceEpoch),
      endAt: Value(DateTime(2026, 3, 17, 11, 20).toUtc().millisecondsSinceEpoch),
      allDay: false, timezone: 'Asia/Shanghai', locationName: Value('5101'),
      createdAt: 1, updatedAt: 1,
    ));
    await db.into(db.sourceRecords).insert(SourceRecordsCompanion.insert(
      id: 'sr-a', accountId: 'acc-1', source: 'ustc_jw', entityType: 'calendar_event',
      externalId: 'ph-evt-a', localEntityId: 'event-a', sourceStatus: 'active',
      presence: 'present', scopeKey: 'scope', firstObservedAt: 1, lastObservedAt: 1,
    ));
    // Account B: a distinct event that must NOT be readable from account A.
    await db.into(db.calendarEvents).insert(CalendarEventsCompanion.insert(
      id: 'event-b', accountId: 'acc-2', source: 'user',
      title: 'B 的健身', type: 'personal',
      startAt: Value(DateTime(2026, 3, 18, 9, 0).toUtc().millisecondsSinceEpoch),
      endAt: Value(DateTime(2026, 3, 18, 10, 0).toUtc().millisecondsSinceEpoch),
      allDay: false, timezone: 'Asia/Shanghai', locationName: Value('健身房'),
      createdAt: 1, updatedAt: 1,
    ));

    final snapshot = await gateway.eventSnapshot('event-a');
    expect(snapshot.title, '量子物理 B');
    expect(snapshot.location, '5101');
    expect(snapshot.source, 'ustc_jw');
    expect(snapshot.type, 'course');
    expect(snapshot.isPersonal, isFalse);
    expect(snapshot.courseSeriesId, 'cs-1');
    expect(snapshot.startAt, DateTime(2026, 3, 17, 9, 45));
    expect(snapshot.endAt, DateTime(2026, 3, 17, 11, 20));

    await expectLater(gateway.eventSnapshot('event-b'), throwsStateError);
  });

  test('eventSnapshot decodes startAt/endAt as Beijing wall time from UTC epoch', () async {
    // Real UTC instant: 2026-03-17 01:45 UTC == 09:45 Beijing.
    final utcStart = DateTime.utc(2026, 3, 17, 1, 45).millisecondsSinceEpoch;
    final utcEnd = DateTime.utc(2026, 3, 17, 3, 20).millisecondsSinceEpoch;
    await db.into(db.calendarEvents).insert(CalendarEventsCompanion.insert(
      id: 'ev-utc', accountId: 'acc-1', source: 'user',
      title: 'UTC存储的个人事件', type: 'personal',
      startAt: Value(utcStart), endAt: Value(utcEnd),
      allDay: false, timezone: 'Asia/Shanghai',
      createdAt: 1, updatedAt: 1,
    ));
    final snapshot = await gateway.eventSnapshot('ev-utc');
    // Preview times must be the Beijing wall clock, not the raw UTC wall clock.
    expect(snapshot.startAt, DateTime(2026, 3, 17, 9, 45));
    expect(snapshot.endAt, DateTime(2026, 3, 17, 11, 20));
  });

  test('updatePermissionPolicy delegates to policy service', () async {
    await gateway.updatePermissionPolicy(
      actionType: 'create_event',
      targetType: 'event',
      mode: ConfirmationMode.alwaysAllow,
      riskLevel: RiskLevel.medium,
      enabled: true,
      updatedBy: 'user',
    );
    expect(await policy.resolve(accountId: 'acc-1', actionType: 'create_event',
        targetType: 'event', riskLevel: RiskLevel.medium), PermissionDecision.allow);
  });

  test('jwDayMovePreview lists only eligible course titles on the source date', () async {
    await _seedJwCourse(db, 'acc-1', 'course-1',
        startAt: _beijingEpoch(2026, 8, 3, 9),
        endAt: _beijingEpoch(2026, 8, 3, 10));
    await _seedJwCourse(db, 'acc-1', 'course-2',
        startAt: _beijingEpoch(2026, 8, 3, 14),
        endAt: _beijingEpoch(2026, 8, 3, 16));
    // 考试来源与个人事件不可移动。
    await db.into(db.calendarEvents).insert(CalendarEventsCompanion.insert(
      id: 'exam-1', accountId: 'acc-1', source: 'ustc_jw',
      externalId: const Value('exam-1'), title: '期中考试', type: 'exam',
      startAt: Value(_beijingEpoch(2026, 8, 3, 9)),
      endAt: Value(_beijingEpoch(2026, 8, 3, 10)),
      allDay: false, timezone: 'Asia/Shanghai', createdAt: 1, updatedAt: 1,
    ));
    await db.into(db.calendarEvents).insert(CalendarEventsCompanion.insert(
      id: 'ev-1', accountId: 'acc-1', source: 'user',
      title: '健身', type: 'personal',
      startAt: Value(_beijingEpoch(2026, 8, 3, 9)),
      endAt: Value(_beijingEpoch(2026, 8, 3, 10)),
      allDay: false, timezone: 'Asia/Shanghai', createdAt: 1, updatedAt: 1,
    ));
    await db.into(db.sourceRecords).insert(SourceRecordsCompanion.insert(
      id: 'sr-exam', accountId: 'acc-1', source: 'ustc_jw',
      entityType: 'calendar_event', externalId: 'exam-1',
      localEntityId: 'exam-1', sourceStatus: 'active', presence: 'present',
      scopeKey: 'scope', firstObservedAt: 1, lastObservedAt: 1,
    ));

    final preview = await gateway.jwDayMovePreview('2026-08-03');
    expect(preview.courses, ['课程 course-1', '课程 course-2'],
        reason: '只有 ustc_jw/course 定时事件可移动，考试/个人事件排除');
    expect(preview.targetDate, isNull);
  });

  test('jwDayMove persists the record, retargets on a second move, and clear restores', () async {
    await _seedJwCourse(db, 'acc-1', 'course-1',
        startAt: _beijingEpoch(2026, 8, 3, 9),
        endAt: _beijingEpoch(2026, 8, 3, 10));
    final first = await gateway.jwDayMove('2026-08-03', '2026-08-09');
    expect(first, isFalse, reason: '首次移动创建记录');
    var preview = await gateway.jwDayMovePreview('2026-08-03');
    expect(preview.targetDate, '2026-08-09');
    expect(preview.courses, hasLength(1));

    final second = await gateway.jwDayMove('2026-08-03', '2026-08-10');
    expect(second, isTrue, reason: '同一源日期的第二次移动是重定向');
    preview = await gateway.jwDayMovePreview('2026-08-03');
    expect(preview.targetDate, '2026-08-10');

    await gateway.jwDayMoveClear('2026-08-03');
    preview = await gateway.jwDayMovePreview('2026-08-03');
    expect(preview.targetDate, isNull, reason: '清除后恢复原日期');
  });

  test('jwDayMove throws NoEligibleJwCourses without courses; clear throws MissingJwDayMove', () async {
    await expectLater(
      gateway.jwDayMove('2026-08-05', '2026-08-09'),
      throwsA(isA<NoEligibleJwCourses>()),
    );
    await expectLater(
      gateway.jwDayMoveClear('2026-08-03'),
      throwsA(isA<MissingJwDayMove>()),
    );
  });

  // ===========================================================================
  // Step 5: locator-aware write preflight (read-only; no DB mutation).
  // ===========================================================================

  test('eventSnapshotByLocator resolves a stored event locator via CalendarEventService', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-pre',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    final locator = encodeCalendarEventLocator(
      StoredEventLocator(eventId: 'ev-pre'),
    );
    final snapshot = await gateway.eventSnapshotByLocator(locator);
    expect(snapshot.title, '健身');
    expect(snapshot.isPersonal, isTrue);
    expect(snapshot.isRecurring, isFalse);
    // The stored path uses the DB row directly.
    expect(snapshot.id, 'ev-pre');
  });

  test('eventSnapshotByLocator resolves an occurrence locator from RecurrenceService', () async {
    final anchor = DateTime(2026, 8, 3, 10, 0);
    final service = RecurrenceService(
      database: db,
      accountId: 'acc-1',
      now: () => anchor.millisecondsSinceEpoch,
    );
    final seriesId = await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '每周例会',
        startAt: anchor,
        endAt: anchor.add(const Duration(hours: 1)),
      ),
      rule: RecurrenceRule.weekly(
        anchor: anchor,
        weekdays: {DateTime.monday},
        untilDate: DateTime(2026, 8, 31),
      ),
    );
    // Resolve the occurrence via RecurrenceService to get its real occurrence key.
    final occ = (await service.occurrences(seriesId,
        from: anchor, through: anchor)).single;
    final locator = encodeCalendarEventLocator(RecurringOccurrenceLocator(
      seriesId: seriesId,
      occurrenceKey: occ.occurrenceKey,
    ));
    final snapshot = await gateway.eventSnapshotByLocator(locator);
    expect(snapshot.title, '每周例会');
    expect(snapshot.isRecurring, isTrue);
    expect(snapshot.personalSeriesId, seriesId);
    expect(snapshot.occurrenceKey, occ.occurrenceKey);
    // No stored calendar_events row is ever created by the projection/preflight.
    final storedRows = await db.select(db.calendarEvents).get();
    expect(storedRows, isEmpty);
  });

  test('eventSnapshotByLocator resolves a series locator for whole-series preflight', () async {
    final anchor = DateTime(2026, 8, 3, 10, 0);
    final service = RecurrenceService(
      database: db,
      accountId: 'acc-1',
      now: () => anchor.millisecondsSinceEpoch,
    );
    final seriesId = await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '每周例会',
        startAt: anchor,
        endAt: anchor.add(const Duration(hours: 1)),
      ),
      rule: RecurrenceRule.weekly(
        anchor: anchor,
        weekdays: {DateTime.monday},
      ),
    );
    final locator = encodeCalendarEventLocator(
      RecurringSeriesLocator(seriesId: seriesId),
    );
    final snapshot = await gateway.eventSnapshotByLocator(locator);
    expect(snapshot.personalSeriesId, seriesId);
    // Whole-series preflight carries no occurrence key.
    expect(snapshot.occurrenceKey, isNull);
    expect(snapshot.isRecurring, isFalse);
    expect(snapshot.id, locator);
  });

  test('eventSnapshotByLocator throws for a malformed locator', () async {
    await expectLater(
      gateway.eventSnapshotByLocator('event_v1.%%%not-base64'),
      throwsA(isA<FormatException>()),
    );
  });

  test('eventSnapshotByLocator throws OccurrenceNotFoundError for an unknown occurrence', () async {
    // A plausible series id + occurrence key that no series owns.
    final locator = encodeCalendarEventLocator(RecurringOccurrenceLocator(
      seriesId: 'series-missing',
      occurrenceKey: 'series-missing@2026-08-03T10:00:00',
    ));
    await expectLater(
      gateway.eventSnapshotByLocator(locator),
      throwsA(isA<OccurrenceNotFoundError>()),
    );
  });

  test('eventSnapshot and personalEvent accept a recurring occurrence locator directly', () async {
    final anchor = DateTime(2026, 8, 3, 10, 0);
    final service = RecurrenceService(
      database: db,
      accountId: 'acc-1',
      now: () => anchor.millisecondsSinceEpoch,
    );
    final seriesId = await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '每周例会',
        startAt: anchor,
        endAt: anchor.add(const Duration(hours: 1)),
      ),
      rule: RecurrenceRule.weekly(
        anchor: anchor,
        weekdays: {DateTime.monday},
      ),
    );
    final occ = (await service.occurrences(seriesId,
        from: anchor, through: anchor)).single;
    final locator = encodeCalendarEventLocator(RecurringOccurrenceLocator(
      seriesId: seriesId,
      occurrenceKey: occ.occurrenceKey,
    ));
    // The existing tool-facing entry points route to the locator-aware path.
    final snapshot = await gateway.eventSnapshot(locator);
    expect(snapshot.personalSeriesId, seriesId);
    final event = await gateway.personalEventByLocator(locator);
    expect(event.title, '每周例会');
    expect(event.startAt, anchor);
    expect(event.startAt!.isAfter(anchor), isFalse);
  });

  test('eventSnapshotByLocator all-day series preflight carries an endDateExclusive', () async {
    final anchor = DateTime(2026, 8, 3);
    final service = RecurrenceService(
      database: db,
      accountId: 'acc-1',
      now: () => anchor.millisecondsSinceEpoch,
    );
    final seriesId = await service.createSeries(
      anchor: PersonalEvent.allDay(
        title: '全天系列',
        startDate: anchor,
        endDateExclusive: anchor.add(const Duration(days: 1)),
      ),
      rule: RecurrenceRule.daily(
        anchor: anchor,
        interval: 1,
        untilDate: DateTime(2026, 8, 31),
      ),
    );
    final locator = encodeCalendarEventLocator(
      RecurringSeriesLocator(seriesId: seriesId),
    );
    final snapshot = await gateway.eventSnapshotByLocator(locator);
    expect(snapshot.allDay, isTrue);
    expect(snapshot.startDate, anchor);
    // Whole-series preflight must not crash on the allDay end exclusive used by
    // _eventTargetLines; it is derived from the series anchor + default day count.
    expect(snapshot.endDateExclusive, isNotNull);
    expect(snapshot.endDateExclusive, anchor.add(const Duration(days: 1)));
    expect(snapshot.personalSeriesId, seriesId);
    expect(snapshot.occurrenceKey, isNull);
  });
}
