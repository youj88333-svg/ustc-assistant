import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_permission_policy_service.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_agent_write_gateway.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_permission_policy.dart';
import 'package:ustc_assistant_app/features/calendar/application/calendar_event_service.dart';
import 'package:ustc_assistant_app/features/calendar/application/recurrence_lifecycle_service.dart';
import 'package:ustc_assistant_app/features/calendar/application/recurrence_service.dart';
import 'package:ustc_assistant_app/features/calendar/domain/calendar_event_locator.dart';
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';
import 'package:ustc_assistant_app/features/calendar/domain/recurrence_rule.dart';
import 'package:ustc_assistant_app/features/schedule/application/conflict_service.dart';
import 'package:ustc_assistant_app/features/schedule/application/effective_event_repository.dart';
import 'package:ustc_assistant_app/features/schedule/application/overlay_service.dart';
import 'package:ustc_assistant_app/features/schedule/domain/jw_day_move.dart';
import 'package:ustc_assistant_app/features/reminders/application/reminder_override_service.dart';
import 'package:ustc_assistant_app/features/tasks/application/plan_block_service.dart';
import 'package:ustc_assistant_app/features/tasks/application/task_event_link_service.dart';
import 'package:ustc_assistant_app/features/tasks/application/task_lifecycle_service.dart';
import 'package:ustc_assistant_app/features/tasks/application/undo_service.dart';
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

  test('createRecurringEvent delegates to RecurrenceService.createSeries', () async {
    final anchor = DateTime(2026, 8, 3, 10, 0);
    final seriesId = await gateway.createRecurringEvent(
      PersonalEvent.timed(
        title: '每周例会',
        startAt: anchor,
        endAt: anchor.add(const Duration(hours: 1)),
      ),
      RecurrenceRule.weekly(
        anchor: anchor,
        weekdays: {DateTime.monday, DateTime.wednesday},
        untilDate: DateTime(2026, 8, 31),
      ),
    );
    // 恰 1 条 series 行，且不发生任何 calendar_events 单次 occurrence 行。
    final series = await db.select(db.calendarEventSeries).get();
    expect(series, hasLength(1));
    expect(series.single.id, seriesId);
    expect(await db.select(db.calendarEvents).get(), isEmpty);
    final rule = RecurrenceRule.decode(series.single.recurrenceJson);
    expect(rule.frequency, RecurrenceFrequency.weekly);
    expect(rule.weekdays, {DateTime.monday, DateTime.wednesday});
  });

  test('createRecurringEvent default all-day reminder is empty, timed default is [15]', () async {
    // 全天：缺省 reminder → []
    final allDayAnchor = DateTime(2026, 8, 3);
    await gateway.createRecurringEvent(
      PersonalEvent.allDay(
        title: '每周复盘',
        startDate: allDayAnchor,
        endDateExclusive: allDayAnchor.add(const Duration(days: 1)),
      ),
      RecurrenceRule.weekly(
        anchor: allDayAnchor,
        weekdays: {DateTime.sunday},
      ),
    );
    final allDaySeries = await db.select(db.calendarEventSeries).getSingle();
    expect(jsonDecode(allDaySeries.reminderOffsetsJson).cast<int>(), isEmpty);
    expect(await db.select(db.calendarEvents).get(), isEmpty);

    // 定时：缺省 reminder → [15]
    final timedAnchor = DateTime(2026, 8, 4, 9, 0);
    await gateway.createRecurringEvent(
      PersonalEvent.timed(
        title: '每日站会',
        startAt: timedAnchor,
        endAt: timedAnchor.add(const Duration(minutes: 30)),
      ),
      RecurrenceRule.daily(anchor: timedAnchor),
    );
    final rows = await db.select(db.calendarEventSeries).get();
    final timedSeries = rows.firstWhere((r) => r.title == '每日站会');
    expect(jsonDecode(timedSeries.reminderOffsetsJson).cast<int>(), [15]);
    expect(await db.select(db.calendarEvents).get(), isEmpty);
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

  test('createConflictRelation resolves a recurring occurrence locator to its '
      'no-op anchor and keeps event kind + locator ids', () async {
    final anchor = DateTime(2026, 8, 3, 9, 0);
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
    final occ = (await service.occurrences(
      seriesId,
      from: anchor,
      through: anchor,
    )).single;
    final locator = encodeCalendarEventLocator(
      RecurringOccurrenceLocator(
        seriesId: seriesId,
        occurrenceKey: occ.occurrenceKey,
      ),
    );
    await gateway.createConflictRelation(
      leftKind: 'event',
      leftId: locator,
      rightKind: 'event',
      rightId: 'ev-1',
      conflictState: 'no_conflict',
    );
    final relation = await db.select(db.scheduleRelations).getSingle();
    // The occurrence endpoint keeps kind event + locator id and points to a
    // created no-op anchor; the stored event carries the event FK.
    final occIsLeft = relation.leftId == locator;
    final anchors =
        await db.select(db.calendarEventOccurrenceExceptions).get();
    expect(anchors, hasLength(1));
    expect(anchors.single.kind, 'override');
    expect(
      occIsLeft ? relation.leftOccurrenceExceptionId
          : relation.rightOccurrenceExceptionId,
      anchors.single.id,
    );
    expect(
      occIsLeft ? relation.leftEventId : relation.rightEventId,
      isNull,
    );
    expect(
      occIsLeft ? relation.rightEventId : relation.leftEventId,
      'ev-1',
    );
  });

  test('setReminder on a recurring occurrence creates one anchor and '
      'occurrence-backed reminders', () async {
    final anchor = DateTime(2026, 8, 3, 9, 0);
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
    final occ = (await service.occurrences(
      seriesId,
      from: anchor,
      through: anchor,
    )).single;
    final locator = encodeCalendarEventLocator(
      RecurringOccurrenceLocator(
        seriesId: seriesId,
        occurrenceKey: occ.occurrenceKey,
      ),
    );
    await gateway.setReminder(locator, const [15]);

    final anchors =
        await db.select(db.calendarEventOccurrenceExceptions).get();
    expect(anchors, hasLength(1));
    final reminders = await db.select(db.reminders).get();
    expect(reminders, hasLength(1));
    expect(reminders.single.targetType, 'event');
    expect(reminders.single.targetId, locator);
    expect(reminders.single.eventId, isNull);
    expect(reminders.single.occurrenceExceptionId, anchors.single.id);
    expect(
      reminders.single.triggerAt,
      anchor.subtract(const Duration(minutes: 15)).millisecondsSinceEpoch,
    );
  });

  test('recurringLifecycle delete only_this writes a tombstone, account-scoped', () async {
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
    final occurrence = (await service.occurrences(
      seriesId,
      from: DateTime(2026, 8, 10),
      through: DateTime(2026, 8, 10, 23),
    )).single;

    await gateway.recurringLifecycle(
      seriesId,
      occurrenceKey: occurrence.occurrenceKey,
      scope: RecurringActionScope.onlyThis,
      action: RecurringLifecycleAction.delete,
    );

    final exception = await service.existingOccurrenceAnchor(
      seriesId,
      occurrence.occurrenceKey,
    );
    expect(exception, isNotNull);
    expect(exception!.deletedAt, isNotNull);
    // Whole-series still active; no occurrence materialized.
    expect((await service.seriesRow(seriesId)).deletedAt, isNull);
    expect(await db.select(db.calendarEvents).get(), isEmpty);
  });

  test('recurringLifecycle delete whole_series sets deletedAt only', () async {
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

    await gateway.recurringLifecycle(
      seriesId,
      occurrenceKey: null,
      scope: RecurringActionScope.wholeSeries,
      action: RecurringLifecycleAction.delete,
    );

    expect((await service.seriesRow(seriesId)).deletedAt, isNotNull);
    expect(await db.select(db.calendarEvents).get(), isEmpty);
  });

  // =========================================================================
  // Task 9: drift gateway delegation for the 16 new lifecycle/clear/unlink/
  // reset/undo methods. Real Drift memory DB, real services — no fakes.
  // =========================================================================

  Future<void> seedTask(String id, {String state = 'active'}) async {
    await db.into(db.tasks).insert(TasksCompanion.insert(
          id: id,
          accountId: 'acc-1',
          title: 'Task $id',
          state: state,
          importance: 'normal',
          tagsJson: '[]',
          createdAt: 1,
          updatedAt: 1,
          cancelledAt: Value(state == 'cancelled' ? 1 : null),
          completedAt: Value(state == 'completed' ? 1 : null),
        ));
  }

  Future<void> seedPlanBlock(String id, String taskId,
      {String status = 'accepted', int? deletedAt}) async {
    await db.into(db.planBlocks).insert(PlanBlocksCompanion.insert(
          id: id,
          accountId: 'acc-1',
          taskId: taskId,
          startAt: 1000,
          endAt: 2000,
          status: status,
          createdAt: 1,
          updatedAt: 1,
          deletedAt: Value(deletedAt),
        ));
  }

  test('reopenTask delegates to TaskLifecycleService.reopen', () async {
    await seedTask('t1', state: 'cancelled');
    await gateway.reopenTask('t1', expectedUpdatedAt: 1);
    final row = await (db.select(db.tasks)
          ..where((r) => r.id.equals('t1')))
        .getSingle();
    expect(row.state, 'active');
    expect(row.updatedAt, 1_700_000_000_000);
  });

  test('restoreTask delegates to TaskLifecycleService.restore', () async {
    await seedTask('t1');
    await db.customStatement(
        "UPDATE tasks SET deleted_at = 1 WHERE id = 't1'");
    await gateway.restoreTask('t1', expectedUpdatedAt: 1);
    final row = await (db.select(db.tasks)
          ..where((r) => r.id.equals('t1')))
        .getSingle();
    expect(row.deletedAt, isNull);
  });

  test('markPlanBlockDone delegates to PlanBlockService.markDone with note',
      () async {
    await seedTask('t1');
    await seedPlanBlock('pb1', 't1');
    await gateway.markPlanBlockDone('pb1',
        expectedUpdatedAt: 1, note: '完成了');
    final row = await (db.select(db.planBlocks)
          ..where((r) => r.id.equals('pb1')))
        .getSingle();
    expect(row.status, 'done');
    expect(row.reviewNote, '完成了');
  });

  test('markPlanBlockSkipped delegates to PlanBlockService.markSkipped',
      () async {
    await seedTask('t1');
    await seedPlanBlock('pb1', 't1');
    await gateway.markPlanBlockSkipped('pb1', expectedUpdatedAt: 1);
    final row = await (db.select(db.planBlocks)
          ..where((r) => r.id.equals('pb1')))
        .getSingle();
    expect(row.status, 'skipped');
  });

  test('cancelPlanBlock delegates to PlanBlockService.cancel', () async {
    await seedTask('t1');
    await seedPlanBlock('pb1', 't1');
    await gateway.cancelPlanBlock('pb1', expectedUpdatedAt: 1);
    final row = await (db.select(db.planBlocks)
          ..where((r) => r.id.equals('pb1')))
        .getSingle();
    expect(row.status, 'cancelled');
  });

  test('softDeletePlanBlock delegates to PlanBlockService.softDelete', () async {
    await seedTask('t1');
    await seedPlanBlock('pb1', 't1');
    await gateway.softDeletePlanBlock('pb1', expectedUpdatedAt: 1);
    final row = await (db.select(db.planBlocks)
          ..where((r) => r.id.equals('pb1')))
        .getSingle();
    expect(row.deletedAt, isNotNull);
  });

  test('restorePlanBlock delegates to PlanBlockService.restore', () async {
    await seedTask('t1');
    await seedPlanBlock('pb1', 't1', deletedAt: 5);
    await gateway.restorePlanBlock('pb1', expectedUpdatedAt: 1);
    final row = await (db.select(db.planBlocks)
          ..where((r) => r.id.equals('pb1')))
        .getSingle();
    expect(row.deletedAt, isNull);
  });

  test('reopenEvent delegates to CalendarEventService.reopen', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    await gateway.cancelEvent('ev-1');
    await gateway.reopenEvent('ev-1');
    final row = await (db.select(db.calendarEvents)
          ..where((r) => r.id.equals('ev-1')))
        .getSingle();
    expect(row.status, 'active');
  });

  test('restoreEvent delegates to CalendarEventService.restore', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    await gateway.softDeleteEvent('ev-1');
    await gateway.restoreEvent('ev-1');
    final row = await (db.select(db.calendarEvents)
          ..where((r) => r.id.equals('ev-1')))
        .getSingle();
    expect(row.deletedAt, isNull);
  });

  // =========================================================================
  // I4: deleted-inclusive lookups for restore proposes. `taskById` /
  // `planBlockById` filter soft-deleted rows (so a restore propose on a
  // soft-deleted target used to die with TaskNotFoundError/PlanBlockNotFoundError
  // before the proposal could even form). The *IncludeDeleted variants read
  // the soft-deleted row so UpdateTaskTool/UpdatePlanBlockTool can form a
  // restore proposal; the commit still re-checks expectedUpdatedAt + state.
  // =========================================================================

  test('taskById throws TaskNotFoundError for a soft-deleted task', () async {
    await seedTask('t1');
    await db.customStatement(
        "UPDATE tasks SET deleted_at = 1 WHERE id = 't1'");
    await expectLater(gateway.taskById('t1'), throwsA(isA<TaskNotFoundError>()));
  });

  test('taskByIdIncludeDeleted returns a soft-deleted task', () async {
    await seedTask('t1');
    await db.customStatement(
        "UPDATE tasks SET deleted_at = 1, updated_at = 5 WHERE id = 't1'");
    final task = await gateway.taskByIdIncludeDeleted('t1');
    expect(task.id, 't1');
    expect(task.title, 'Task t1');
    expect(task.updatedAt, 5);
    // The deletedAt timestamp is visible through the inclusive lookup so the
    // restore preview can surface "当前状态：已删除".
    final row = await (db.select(db.tasks)..where((r) => r.id.equals('t1')))
        .getSingle();
    expect(row.deletedAt, isNotNull);
  });

  test('taskByIdIncludeDeleted throws TaskNotFoundError for a foreign account',
      () async {
    await seedTask('t1');
    final foreign = DriftAgentWriteGateway(
      database: db,
      accountId: 'acc-other',
      policy: policy,
      now: () => 1_700_000_000_000,
    );
    await expectLater(
        foreign.taskByIdIncludeDeleted('t1'), throwsA(isA<TaskNotFoundError>()));
  });

  test('planBlockById throws PlanBlockNotFoundError for a soft-deleted block',
      () async {
    await seedTask('t1');
    await seedPlanBlock('pb1', 't1', deletedAt: 5);
    await expectLater(
        gateway.planBlockById('pb1'), throwsA(isA<PlanBlockNotFoundError>()));
  });

  test('planBlockByIdIncludeDeleted returns a soft-deleted block', () async {
    await seedTask('t1');
    await seedPlanBlock('pb1', 't1', deletedAt: 5);
    final block = await gateway.planBlockByIdIncludeDeleted('pb1');
    expect(block.id, 'pb1');
    expect(block.taskId, 't1');
    expect(block.updatedAt, 1);
  });

  test('planBlockByIdIncludeDeleted throws PlanBlockNotFoundError for a foreign account',
      () async {
    await seedTask('t1');
    await seedPlanBlock('pb1', 't1', deletedAt: 5);
    final foreign = DriftAgentWriteGateway(
      database: db,
      accountId: 'acc-other',
      policy: policy,
      now: () => 1_700_000_000_000,
    );
    await expectLater(foreign.planBlockByIdIncludeDeleted('pb1'),
        throwsA(isA<PlanBlockNotFoundError>()));
  });

  // =========================================================================
  // C3: TOCTOU version re-check on single-event lifecycle commits. The 6
  // lifecycle methods take an optional `expectedUpdatedAt` that must match the
  // row's current `updatedAt`; a stale value throws StaleEventCommand.
  // =========================================================================

  test('cancelEvent with stale expectedUpdatedAt throws StaleEventCommand',
      () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    final current = await (db.select(db.calendarEvents)
          ..where((r) => r.id.equals('ev-1')))
        .getSingle();
    expect(
      () => gateway.cancelEvent('ev-1', expectedUpdatedAt: current.updatedAt - 1),
      throwsA(isA<StaleEventCommand>()),
    );
  });

  test('cancelEvent with current expectedUpdatedAt succeeds', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    final current = await (db.select(db.calendarEvents)
          ..where((r) => r.id.equals('ev-1')))
        .getSingle();
    await gateway.cancelEvent('ev-1', expectedUpdatedAt: current.updatedAt);
    final row = await (db.select(db.calendarEvents)
          ..where((r) => r.id.equals('ev-1')))
        .getSingle();
    expect(row.status, 'cancelled');
  });

  test('softDeleteEvent with stale expectedUpdatedAt throws StaleEventCommand',
      () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    final current = await (db.select(db.calendarEvents)
          ..where((r) => r.id.equals('ev-1')))
        .getSingle();
    expect(
      () => gateway.softDeleteEvent('ev-1',
          expectedUpdatedAt: current.updatedAt - 1),
      throwsA(isA<StaleEventCommand>()),
    );
  });

  test(
      'recurringLifecycle whole_series delete with stale expectedSeriesUpdatedAt '
      'throws StaleRecurringTarget', () async {
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
    final series = await service.seriesRow(seriesId);
    expect(
      () => gateway.recurringLifecycle(
        seriesId,
        occurrenceKey: null,
        scope: RecurringActionScope.wholeSeries,
        action: RecurringLifecycleAction.delete,
        expectedSeriesUpdatedAt: series.updatedAt - 1,
      ),
      throwsA(isA<StaleRecurringTarget>()),
    );
  });

  test(
      'recurringLifecycle whole_series delete with current '
      'expectedSeriesUpdatedAt succeeds', () async {
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
    final series = await service.seriesRow(seriesId);
    await gateway.recurringLifecycle(
      seriesId,
      occurrenceKey: null,
      scope: RecurringActionScope.wholeSeries,
      action: RecurringLifecycleAction.delete,
      expectedSeriesUpdatedAt: series.updatedAt,
    );
    expect((await service.seriesRow(seriesId)).deletedAt, isNotNull);
  });

  test('eventSnapshot exposes the stored row updatedAt', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    final row = await (db.select(db.calendarEvents)
          ..where((r) => r.id.equals('ev-1')))
        .getSingle();
    final snapshot = await gateway.eventSnapshot('ev-1');
    expect(snapshot.updatedAt, row.updatedAt);
  });

  // =========================================================================
  // I2: TOCTOU content/version snapshot re-check on unlink/reminder/overlay
  // commits. The 3 commit paths must re-read and compare a propose-time
  // snapshot (target updatedAt + content), not just check existence. A
  // version/content mismatch throws a Stale* exception (maps to stale_target),
  // distinct from a foreign/missing target (target_not_found).
  // =========================================================================

  test('unlinkTaskEvent with stale expectedTaskUpdatedAt throws StaleTaskEventLinkCommand',
      () async {
    await seedTask('t1');
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    await db.into(db.taskEventLinks).insert(TaskEventLinksCompanion.insert(
          accountId: 'acc-1',
          taskId: 't1',
          targetId: 'ev-1',
          eventId: const Value('ev-1'),
          relationType: 'related',
          createdAt: 1,
        ));
    final taskRow = await (db.select(db.tasks)..where((r) => r.id.equals('t1')))
        .getSingle();
    // Mutate the task title between propose and commit, bumping updatedAt.
    await db.customStatement(
        "UPDATE tasks SET title = '改过', updated_at = ${taskRow.updatedAt + 1} "
        "WHERE id = 't1'");
    await expectLater(
      gateway.unlinkTaskEvent(
          taskId: 't1',
          eventId: 'ev-1',
          expectedTaskUpdatedAt: taskRow.updatedAt,
          expectedEventUpdatedAt: 1),
      throwsA(isA<StaleTaskEventLinkCommand>()),
    );
    // The link row must remain (nothing written on stale).
    expect(await db.select(db.taskEventLinks).get(), hasLength(1));
  });

  test('unlinkTaskEvent with current expectedTaskUpdatedAt succeeds', () async {
    await seedTask('t1');
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    await db.into(db.taskEventLinks).insert(TaskEventLinksCompanion.insert(
          accountId: 'acc-1',
          taskId: 't1',
          targetId: 'ev-1',
          eventId: const Value('ev-1'),
          relationType: 'related',
          createdAt: 1,
        ));
    final taskRow = await (db.select(db.tasks)..where((r) => r.id.equals('t1')))
        .getSingle();
    final eventRow =
        await (db.select(db.calendarEvents)..where((r) => r.id.equals('ev-1')))
            .getSingle();
    await gateway.unlinkTaskEvent(
        taskId: 't1',
        eventId: 'ev-1',
        expectedTaskUpdatedAt: taskRow.updatedAt,
        expectedEventUpdatedAt: eventRow.updatedAt);
    expect(await db.select(db.taskEventLinks).get(), isEmpty);
  });

  test(
      'clearReminders all with stale desired-offset snapshot throws '
      'StaleReminderTargetCommand', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    await gateway.setReminder('ev-1', const [15, 30]);
    final eventRow =
        await (db.select(db.calendarEvents)..where((r) => r.id.equals('ev-1')))
            .getSingle();
    // Between propose and commit, the user adds a new desired offset 60.
    await gateway.setReminder('ev-1', const [15, 30, 60]);
    await expectLater(
      gateway.clearReminders(
          targetType: 'event',
          targetId: 'ev-1',
          scope: 'all',
          expectedTargetUpdatedAt: eventRow.updatedAt,
          expectedOffsetsSnapshot: const [15, 30]),
      throwsA(isA<StaleReminderTargetCommand>()),
    );
    // The newly added 60 offset must still be a future desired row.
    final desired = await (db.select(db.reminders)
          ..where((r) =>
              r.eventId.equals('ev-1') & r.state.equals('desired')))
        .get();
    expect(desired.map((r) => r.offsetMinutes).toSet(), contains(60));
  });

  test(
      'clearReminders selected_offsets with stale desired-offset snapshot throws '
      'StaleReminderTargetCommand', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    await gateway.setReminder('ev-1', const [15, 30]);
    final eventRow =
        await (db.select(db.calendarEvents)..where((r) => r.id.equals('ev-1')))
            .getSingle();
    // Between propose and commit, the 15-row is removed (e.g. user cleared it
    // via another path), leaving only 30.
    await gateway.clearReminders(
        targetType: 'event', targetId: 'ev-1', scope: 'selected_offsets', offsets: const [15]);
    await expectLater(
      gateway.clearReminders(
          targetType: 'event',
          targetId: 'ev-1',
          scope: 'selected_offsets',
          offsets: const [15],
          expectedTargetUpdatedAt: eventRow.updatedAt,
          expectedOffsetsSnapshot: const [15, 30]),
      throwsA(isA<StaleReminderTargetCommand>()),
    );
  });

  test(
      'clearOverlayFields with stale expectedOverlayUpdatedAt throws '
      'StaleOverlayCommand', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    await gateway.setEventOverlay(
        'ev-1',
        const OverlayMutation(displayTitle: '健身改', importance: 'high'));
    final overlayRow = await (db.select(db.userOverlays)
          ..where((r) => r.eventId.equals('ev-1')))
        .getSingle();
    // Between propose and commit, the field being cleared is changed (bumping
    // the overlay row's updatedAt). The gateway uses a fixed clock, so bump
    // updated_at explicitly via raw SQL to simulate a concurrent mutation.
    await db.customStatement(
        "UPDATE user_overlays SET display_title = '又改了', "
        "updated_at = ${overlayRow.updatedAt + 1} WHERE event_id = 'ev-1'");
    await expectLater(
      gateway.clearOverlayFields(
          eventId: 'ev-1',
          fields: const ['display_title'],
          expectedOverlayUpdatedAt: overlayRow.updatedAt),
      throwsA(isA<StaleOverlayCommand>()),
    );
    // The new value must survive (nothing cleared on stale).
    final after = await (db.select(db.userOverlays)
          ..where((r) => r.eventId.equals('ev-1')))
        .getSingle();
    expect(after.displayTitle, '又改了');
  });

  test('clearReminders all delegates to ReminderOverrideService.clearReminders',
      () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    await gateway.setReminder('ev-1', const [15, 30]);
    await gateway.clearReminders(
        targetType: 'event', targetId: 'ev-1', scope: 'all');
    final desired = await (db.select(db.reminders)
          ..where((r) =>
              r.eventId.equals('ev-1') & r.state.equals('desired')))
        .get();
    expect(desired, isEmpty);
  });

  test('clearReminders selected_offsets removes only listed offset', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    await gateway.setReminder('ev-1', const [15, 30]);
    await gateway.clearReminders(
        targetType: 'event',
        targetId: 'ev-1',
        scope: 'selected_offsets',
        offsets: const [15]);
    final remaining = await (db.select(db.reminders)
          ..where((r) =>
              r.eventId.equals('ev-1') & r.state.equals('desired')))
        .get();
    expect(remaining.single.offsetMinutes, 30);
  });

  test('clearOverlayFields delegates to OverlayService.clearOverlayFields',
      () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    await gateway.setEventOverlay(
        'ev-1',
        const OverlayMutation(
            displayTitle: '健身改', importance: 'high'));
    await gateway.clearOverlayFields(
        eventId: 'ev-1', fields: const ['display_title']);
    final row = await (db.select(db.userOverlays)
          ..where((r) => r.eventId.equals('ev-1')))
        .getSingle();
    expect(row.displayTitle, isNull);
    expect(row.importance, 'high'); // 未清除的字段保留
  });

  test('deleteConflictRelation removes a user conflict row', () async {
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: 'A',
      startAt: DateTime(2026, 8, 1, 9),
      endAt: DateTime(2026, 8, 1, 10),
    ));
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-2',
      title: 'B',
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
    final rel = (await db.select(db.scheduleRelations).get()).single;
    await gateway.deleteConflictRelation(rel.id);
    expect(await db.select(db.scheduleRelations).get(), isEmpty);
  });

  test('deleteConflictRelation throws ConflictRelationNotFoundError for missing',
      () async {
    await expectLater(
      gateway.deleteConflictRelation('nope'),
      throwsA(isA<ConflictRelationNotFoundError>()),
    );
  });

  test('deleteConflictRule removes a series rule row', () async {
    await db.into(db.scheduleRelationRules).insert(
          ScheduleRelationRulesCompanion.insert(
            id: 'rule-1',
            accountId: 'acc-1',
            leftSeriesType: 'calendar_event_series',
            leftSeriesId: 'ser-1',
            rightSeriesType: 'calendar_event_series',
            rightSeriesId: 'ser-2',
            conflictState: 'conflict',
            effectiveFrom: '2026-08-01',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await gateway.deleteConflictRule('rule-1');
    expect(await db.select(db.scheduleRelationRules).get(), isEmpty);
  });

  test('conflictRuleRemovalImpact returns day count and flags', () async {
    // Fixed clock (1_700_000_000_000 ms) is 2023-11-15 Beijing; the 366-day
    // horizon ends 2024-11-15. Use dates inside that window so over366=false.
    await db.into(db.scheduleRelationRules).insert(
          ScheduleRelationRulesCompanion.insert(
            id: 'rule-1',
            accountId: 'acc-1',
            leftSeriesType: 'calendar_event_series',
            leftSeriesId: 'ser-1',
            rightSeriesType: 'calendar_event_series',
            rightSeriesId: 'ser-2',
            conflictState: 'conflict',
            effectiveFrom: '2023-11-15',
            effectiveThrough: const Value('2023-11-20'),
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    final impact = await gateway.conflictRuleRemovalImpact('rule-1');
    expect(impact.infinite, isFalse);
    expect(impact.over366Days, isFalse);
    expect(impact.affectedDays, greaterThan(0));
  });

  test('unlinkTaskEvent removes the link row', () async {
    await seedTask('t1');
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    await db.into(db.taskEventLinks).insert(TaskEventLinksCompanion.insert(
          accountId: 'acc-1',
          taskId: 't1',
          targetId: 'ev-1',
          eventId: const Value('ev-1'),
          relationType: 'related',
          createdAt: 1,
        ));
    await gateway.unlinkTaskEvent(taskId: 't1', eventId: 'ev-1');
    expect(await db.select(db.taskEventLinks).get(), isEmpty);
  });

  test('unlinkTaskEvent throws TaskEventLinkNotFoundError for missing link',
      () async {
    await seedTask('t1');
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    await expectLater(
      gateway.unlinkTaskEvent(taskId: 't1', eventId: 'ev-1'),
      throwsA(isA<TaskEventLinkNotFoundError>()),
    );
  });

  test('resetPermissionPolicy returns false when no override exists',
      () async {
    final removed = await gateway.resetPermissionPolicy(
        actionType: 'event_delete', targetType: 'event');
    expect(removed, isFalse);
  });

  test('resetPermissionPolicy removes an override and returns true', () async {
    await db.into(db.agentPermissionPolicies).insert(
          AgentPermissionPoliciesCompanion.insert(
            id: 'p1',
            accountId: 'acc-1',
            actionType: 'event_delete',
            targetType: const Value('event'),
            confirmationMode: 'always_allow',
            riskLevel: const Value('high'),
            scope: const Value('user_default'),
            enabled: const Value(true),
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    final removed = await gateway.resetPermissionPolicy(
        actionType: 'event_delete', targetType: 'event');
    expect(removed, isTrue);
    expect(await db.select(db.agentPermissionPolicies).get(), isEmpty);
  });

  test('undoLastAction throws InvalidUndoCommand when slot is empty', () async {
    await expectLater(
      gateway.undoLastAction(),
      throwsA(isA<InvalidUndoCommand>()),
    );
  });

  test('undoLastAction consumes a populated slot', () async {
    // Seed an undo slot via a real write (createEvent records an undo command).
    await gateway.createEvent(PersonalEvent.timed(
      id: 'ev-1',
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    // The createEvent path uses the gateway's NoopUndoRecorder, so seed a slot
    // directly via UndoService to test undoLastAction delegation.
    final undo = UndoService(database: db, accountId: 'acc-1', now: () => 1);
    await db.customStatement(
        "DELETE FROM undo_slot");
    await db.into(db.undoSlot).insert(UndoSlotCompanion.insert(
          commandId: 'cmd-1',
          payload: jsonEncode({
            'version': 1,
            'kind': 'calendar_event_create',
            'accountId': 'acc-1',
            'safeSummary': '新建日程 健身',
            'payload': {
              'entity': 'calendar_event',
              'id': 'ev-1',
            },
          }),
          createdAt: 1,
        ));
    await gateway.undoLastAction();
    expect(await db.select(db.undoSlot).get(), isEmpty);
    // The undo restored the event -> soft-deleted then recreated? Actually the
    // create undo deletes the event. Assert the slot was consumed (above) and
    // no exception thrown.
    await undo.clearAtStartup();
  });

  test('undoPreview returns available:false when slot is empty', () async {
    final preview = await gateway.undoPreview();
    expect(preview.available, isFalse);
  });

  test('undoPreview returns available:true with safe summary for own slot',
      () async {
    await db.into(db.undoSlot).insert(UndoSlotCompanion.insert(
          commandId: 'cmd-1',
          payload: jsonEncode({
            'version': 1,
            'kind': 'calendar_event_delete',
            'accountId': 'acc-1',
            'safeSummary': '删除日程 健身',
            'payload': {},
          }),
          createdAt: 1,
        ));
    final preview = await gateway.undoPreview();
    expect(preview.available, isTrue);
    expect(preview.summary, '删除日程 健身');
    expect(preview.kind, 'calendar_event_delete');
  });

  // =========================================================================
  // C4: Agent lifecycle/clear/unlink writes must NOT produce a duplicate
  // `source='user'` ActionLog from the inner service. The outer
  // `commitAgentWriteAtomically` owns the single authoritative
  // `source='agent'` business log. The gateway constructs its services with
  // `logToActionLog: false`; UI-direct services keep the default `true`.
  // =========================================================================

  /// Counts ActionLog rows for the account matching [source] and (optionally)
  /// [actionType].
  Future<int> countLogs(String source, {String? actionType}) async {
    final q = db.select(db.actionLogs)
      ..where((r) =>
          r.accountId.equals('acc-1') & r.source.equals(source));
    if (actionType != null) {
      q.where((r) => r.actionType.equals(actionType));
    }
    return (await q.get()).length;
  }

  /// The authoritative outer Agent commit log (mirrors what
  /// `commitAgentWriteAtomically` writes via `policy.logAgentWrite`).
  Future<void> writeAgentCommitLog(String actionType) => policy.logAgentWrite(
        accountId: 'acc-1',
        actionType: actionType,
        riskLevel: 'medium',
        result: 'success',
        safeSummary: 'Agent write',
      );

  Future<String> seedEvent(String id) async {
    await gateway.createEvent(PersonalEvent.timed(
      id: id,
      title: '健身',
      startAt: DateTime(2026, 8, 1, 15),
      endAt: DateTime(2026, 8, 1, 16),
    ));
    // createEvent itself goes through the gateway; clear its inner
    // `calendar_event_create` user log so it does not pollute the assertions
    // about the lifecycle action that follows.
    await db.customStatement(
        "DELETE FROM action_logs WHERE source='user' AND action_type='calendar_event_create'");
    return id;
  }

  test(
      'C4: gateway.cancelEvent suppresses the inner source=user '
      'calendar_event_cancel log', () async {
    await seedEvent('ev-1');
    await gateway.cancelEvent('ev-1');
    expect(await countLogs('user', actionType: 'calendar_event_cancel'), 0);
  });

  test(
      'C4: gateway.softDeleteEvent suppresses the inner source=user '
      'calendar_event_delete log', () async {
    await seedEvent('ev-1');
    await gateway.softDeleteEvent('ev-1');
    expect(await countLogs('user', actionType: 'calendar_event_delete'), 0);
  });

  test(
      'C4: gateway.restoreEvent suppresses the inner source=user '
      'calendar_event_restore log', () async {
    await seedEvent('ev-1');
    await gateway.softDeleteEvent('ev-1');
    await gateway.restoreEvent('ev-1');
    expect(await countLogs('user', actionType: 'calendar_event_restore'), 0);
  });

  test(
      'C4: a full Agent lifecycle commit produces exactly one source=agent '
      'row and zero inner source=user business rows', () async {
    await seedEvent('ev-1');
    await gateway.cancelEvent('ev-1');
    await writeAgentCommitLog('event_cancel');
    expect(await countLogs('user', actionType: 'calendar_event_cancel'), 0);
    expect(await countLogs('agent', actionType: 'event_cancel'), 1);
  });

  test(
      'C4: UI-direct CalendarEventService.cancel (default logToActionLog=true) '
      'still writes the source=user calendar_event_cancel row', () async {
    final id = await seedEvent('ev-ui');
    final service = CalendarEventService(
      database: db,
      accountId: 'acc-1',
      now: () => 1_700_000_000_000,
    );
    await service.cancel(id);
    expect(await countLogs('user', actionType: 'calendar_event_cancel'), 1);
  });

  test(
      'C4: gateway recurringLifecycle cancel whole_series suppresses the inner '
      'source=user calendar_recurring_cancel log', () async {
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
    await db.customStatement(
        "DELETE FROM action_logs WHERE source='user' AND action_type='calendar_series_create'");
    await gateway.recurringLifecycle(
      seriesId,
      occurrenceKey: null,
      scope: RecurringActionScope.wholeSeries,
      action: RecurringLifecycleAction.cancel,
    );
    expect(await countLogs('user', actionType: 'calendar_recurring_cancel'), 0);
  });

  test(
      'C4: gateway recurringLifecycle delete only_this suppresses the inner '
      'source=user calendar_recurring_delete log', () async {
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
    await db.customStatement(
        "DELETE FROM action_logs WHERE source='user' AND action_type='calendar_series_create'");
    final occurrence = (await service.occurrences(
      seriesId,
      from: DateTime(2026, 8, 10),
      through: DateTime(2026, 8, 10, 23),
    )).single;
    await gateway.recurringLifecycle(
      seriesId,
      occurrenceKey: occurrence.occurrenceKey,
      scope: RecurringActionScope.onlyThis,
      action: RecurringLifecycleAction.delete,
    );
    expect(await countLogs('user', actionType: 'calendar_recurring_delete'), 0);
  });

  test(
      'C4: gateway recurringLifecycle restore whole_series suppresses the inner '
      'source=user calendar_recurring_restore log + one source=agent', () async {
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
    await db.customStatement(
        "DELETE FROM action_logs WHERE source='user' AND action_type='calendar_series_create'");
    await gateway.recurringLifecycle(
      seriesId,
      occurrenceKey: null,
      scope: RecurringActionScope.wholeSeries,
      action: RecurringLifecycleAction.delete,
    );
    await gateway.recurringLifecycle(
      seriesId,
      occurrenceKey: null,
      scope: RecurringActionScope.wholeSeries,
      action: RecurringLifecycleAction.restore,
    );
    await writeAgentCommitLog('recurring_restore');
    expect(await countLogs('user', actionType: 'calendar_recurring_restore'), 0);
    expect(await countLogs('agent', actionType: 'recurring_restore'), 1);
  });

  test(
      'C4: UI-direct RecurringLifecycleService cancel (default logToActionLog) '
      'still writes the source=user calendar_recurring_cancel row', () async {
    final anchor = DateTime(2026, 8, 3, 10, 0);
    final createService = RecurrenceService(
      database: db,
      accountId: 'acc-1',
      now: () => anchor.millisecondsSinceEpoch,
    );
    final seriesId = await createService.createSeries(
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
    await db.customStatement(
        "DELETE FROM action_logs WHERE source='user' AND action_type='calendar_series_create'");
    final lifecycle = RecurringLifecycleService(
      database: db,
      accountId: 'acc-1',
      now: () => anchor.millisecondsSinceEpoch,
    );
    await lifecycle.cancelSeries(seriesId);
    expect(await countLogs('user', actionType: 'calendar_recurring_cancel'), 1);
  });

  test(
      'C4: gateway.clearReminders suppresses no inner source=user log '
      '(ReminderOverrideService writes none) + one source=agent', () async {
    await seedEvent('ev-1');
    await gateway.setReminder('ev-1', const [15, 30]);
    await db.customStatement("DELETE FROM action_logs");
    await gateway.clearReminders(
        targetType: 'event', targetId: 'ev-1', scope: 'all');
    await writeAgentCommitLog('clear_reminders');
    expect(await countLogs('user'), 0);
    expect(await countLogs('agent', actionType: 'clear_reminders'), 1);
  });

  test(
      'C4: gateway.clearOverlayFields suppresses the inner source=user '
      'user_overlay_update log + one source=agent', () async {
    await seedEvent('ev-1');
    await gateway.setEventOverlay(
      'ev-1',
      const OverlayMutation(displayTitle: '健身改', importance: 'high'),
    );
    await db.customStatement("DELETE FROM action_logs");
    await gateway.clearOverlayFields(
        eventId: 'ev-1', fields: const ['display_title']);
    await writeAgentCommitLog('clear_overlay_fields');
    expect(await countLogs('user', actionType: 'user_overlay_update'), 0);
    expect(await countLogs('agent', actionType: 'clear_overlay_fields'), 1);
  });

  test(
      'C4: gateway.deleteConflictRelation suppresses the inner source=user '
      'delete_schedule_relation log', () async {
    await seedEvent('ev-1');
    await seedEvent('ev-2');
    await gateway.createConflictRelation(
      leftKind: 'event',
      leftId: 'ev-1',
      rightKind: 'event',
      rightId: 'ev-2',
      conflictState: 'conflict',
    );
    await db.customStatement("DELETE FROM action_logs");
    final rel = (await db.select(db.scheduleRelations).get()).single;
    await gateway.deleteConflictRelation(rel.id);
    await writeAgentCommitLog('delete_conflict_relation');
    expect(await countLogs('user', actionType: 'delete_schedule_relation'), 0);
    expect(await countLogs('agent', actionType: 'delete_conflict_relation'), 1);
  });

  test(
      'C4: gateway.deleteConflictRule suppresses the inner source=user '
      'delete_schedule_relation_rule log', () async {
    await db.into(db.scheduleRelationRules).insert(
          ScheduleRelationRulesCompanion.insert(
            id: 'rule-1',
            accountId: 'acc-1',
            leftSeriesType: 'calendar_event_series',
            leftSeriesId: 'ser-1',
            rightSeriesType: 'calendar_event_series',
            rightSeriesId: 'ser-2',
            conflictState: 'conflict',
            effectiveFrom: '2026-08-01',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await db.customStatement("DELETE FROM action_logs");
    await gateway.deleteConflictRule('rule-1');
    await writeAgentCommitLog('delete_conflict_rule');
    expect(
        await countLogs('user', actionType: 'delete_schedule_relation_rule'), 0);
    expect(await countLogs('agent', actionType: 'delete_conflict_rule'), 1);
  });

  test(
      'C4: gateway.unlinkTaskEvent suppresses the inner source=user '
      'unlink_task_event log', () async {
    await seedTask('t1');
    await seedEvent('ev-1');
    await db.into(db.taskEventLinks).insert(TaskEventLinksCompanion.insert(
          accountId: 'acc-1',
          taskId: 't1',
          targetId: 'ev-1',
          eventId: const Value('ev-1'),
          relationType: 'related',
          createdAt: 1,
        ));
    await db.customStatement("DELETE FROM action_logs");
    await gateway.unlinkTaskEvent(taskId: 't1', eventId: 'ev-1');
    await writeAgentCommitLog('unlink_task_event');
    expect(await countLogs('user', actionType: 'unlink_task_event'), 0);
    expect(await countLogs('agent', actionType: 'unlink_task_event'), 1);
  });

  test(
      'C4: gateway.jwDayMove suppresses the inner source=user jw_day_move log '
      '+ one source=agent', () async {
    await _seedJwCourse(db, 'acc-1', 'course-1',
        startAt: _beijingEpoch(2026, 8, 3, 9),
        endAt: _beijingEpoch(2026, 8, 3, 10));
    await db.customStatement("DELETE FROM action_logs");
    await gateway.jwDayMove('2026-08-03', '2026-08-09');
    await writeAgentCommitLog('jw_day_move');
    expect(await countLogs('user', actionType: 'jw_day_move'), 0);
    expect(await countLogs('agent', actionType: 'jw_day_move'), 1);
  });

  test(
      'C4: gateway.jwDayMoveClear suppresses the inner source=user '
      'jw_day_move_clear log', () async {
    await _seedJwCourse(db, 'acc-1', 'course-1',
        startAt: _beijingEpoch(2026, 8, 3, 9),
        endAt: _beijingEpoch(2026, 8, 3, 10));
    await gateway.jwDayMove('2026-08-03', '2026-08-09');
    await db.customStatement("DELETE FROM action_logs");
    await gateway.jwDayMoveClear('2026-08-03');
    await writeAgentCommitLog('jw_day_move_clear');
    expect(await countLogs('user', actionType: 'jw_day_move_clear'), 0);
    expect(await countLogs('agent', actionType: 'jw_day_move_clear'), 1);
  });
}
