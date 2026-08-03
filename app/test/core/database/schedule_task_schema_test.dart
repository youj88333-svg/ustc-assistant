import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';

AppDatabase testDatabase() => AppDatabase(NativeDatabase.memory());

Future<void> seedAccount(AppDatabase db, String id) => db
    .into(db.localAccounts)
    .insert(
      LocalAccountsCompanion.insert(
        id: id,
        maskedHint: 'PB****0000',
        createdAt: 1,
        updatedAt: 1,
      ),
    );

CalendarEventsCompanion timedEvent(String id, {String accountId = 'a'}) =>
    CalendarEventsCompanion.insert(
      id: id,
      accountId: accountId,
      source: 'user',
      title: 'Event',
      type: 'personal',
      status: const Value('active'),
      startAt: const Value(1000),
      endAt: const Value(2000),
      allDay: false,
      timezone: 'Asia/Shanghai',
      importance: const Value('normal'),
      completionPolicy: const Value('auto_complete'),
      createdAt: 1,
      updatedAt: 1,
    );

TasksCompanion task(String id, {String accountId = 'a'}) =>
    TasksCompanion.insert(
      id: id,
      accountId: accountId,
      title: 'Task',
      state: 'active',
      importance: 'normal',
      tagsJson: '[]',
      createdAt: 1,
      updatedAt: 1,
    );

void main() {
  test('timed and all-day representations are exclusive', () async {
    final db = testDatabase();
    addTearDown(db.close);
    await seedAccount(db, 'a');

    expect(
      db
          .into(db.calendarEvents)
          .insert(
            timedEvent('bad').copyWith(startDate: const Value('2026-07-27')),
          ),
      throwsA(isA<SqliteException>()),
    );
    expect(
      db
          .into(db.calendarEvents)
          .insert(
            CalendarEventsCompanion.insert(
              id: 'bad-all-day',
              accountId: 'a',
              source: 'user',
              title: 'Bad',
              type: 'personal',
              status: const Value('active'),
              allDay: true,
              startDate: const Value('2026-07-27'),
              endDateExclusive: const Value('2026-07-27'),
              timezone: 'Asia/Shanghai',
              importance: const Value('normal'),
              completionPolicy: const Value('auto_complete'),
              createdAt: 1,
              updatedAt: 1,
            ),
          ),
      throwsA(isA<SqliteException>()),
    );
  });

  test('task-event links enforce one relation row per pair', () async {
    final db = testDatabase();
    addTearDown(db.close);
    await seedAccount(db, 'a');
    await db.into(db.tasks).insert(task('t1'));
    await db.into(db.calendarEvents).insert(timedEvent('e1'));
    final link = TaskEventLinksCompanion.insert(
      accountId: 'a',
      taskId: 't1',
      targetId: 'e1',
      eventId: const Value('e1'),
      relationType: 'related',
      createdAt: 1,
    );
    await db.into(db.taskEventLinks).insert(link);

    expect(
      db.into(db.taskEventLinks).insert(link),
      throwsA(isA<SqliteException>()),
    );
  });

  test('plan block requires its parent task', () async {
    final db = testDatabase();
    addTearDown(db.close);
    await seedAccount(db, 'a');

    expect(
      db
          .into(db.planBlocks)
          .insert(
            PlanBlocksCompanion.insert(
              id: 'p1',
              accountId: 'a',
              taskId: 'missing',
              startAt: 1000,
              endAt: 2000,
              status: 'accepted',
              createdAt: 1,
              updatedAt: 1,
            ),
          ),
      throwsA(isA<SqliteException>()),
    );
  });

  test('terminal task requires a terminal timestamp', () async {
    final db = testDatabase();
    addTearDown(db.close);
    await seedAccount(db, 'a');

    expect(
      db
          .into(db.tasks)
          .insert(task('done').copyWith(state: const Value('completed'))),
      throwsA(isA<SqliteException>()),
    );
  });

  test('relation identities and rule effective range are unique', () async {
    final db = testDatabase();
    addTearDown(db.close);
    await seedAccount(db, 'a');
    await db.into(db.calendarEvents).insert(timedEvent('e1'));
    await db.into(db.calendarEvents).insert(timedEvent('e2'));
    final relation = ScheduleRelationsCompanion.insert(
      id: 'r1',
      accountId: 'a',
      leftKind: const Value('event'),
      leftId: const Value('e1'),
      leftEventId: const Value('e1'),
      rightKind: const Value('event'),
      rightId: const Value('e2'),
      rightEventId: const Value('e2'),
      conflictState: const Value('conflict'),
      createdAt: 1,
      updatedAt: 1,
    );
    await db.into(db.scheduleRelations).insert(relation);

    expect(
      db
          .into(db.scheduleRelations)
          .insert(relation.copyWith(id: const Value('r2'))),
      throwsA(isA<SqliteException>()),
    );

    final rule = ScheduleRelationRulesCompanion.insert(
      id: 'rule-1',
      accountId: 'a',
      leftSeriesType: 'course_series',
      leftSeriesId: 'left',
      rightSeriesType: 'calendar_event_series',
      rightSeriesId: 'right',
      conflictState: 'no_conflict',
      effectiveFrom: '2026-07-27',
      createdAt: 1,
      updatedAt: 1,
    );
    await db.into(db.scheduleRelationRules).insert(rule);
    expect(
      db
          .into(db.scheduleRelationRules)
          .insert(
            rule.copyWith(
              id: const Value('rule-2'),
              effectiveThrough: const Value('2026-07-26'),
            ),
          ),
      throwsA(isA<SqliteException>()),
    );
  });

  test('occurrence exceptions have stable unique identity', () async {
    final db = testDatabase();
    addTearDown(db.close);
    await seedAccount(db, 'a');
    await db
        .into(db.calendarEventSeries)
        .insert(
          CalendarEventSeriesCompanion.insert(
            id: 's1',
            accountId: 'a',
            title: 'Weekly',
            eventType: 'personal',
            timezone: 'Asia/Shanghai',
            startAt: const Value(1000),
            durationMinutes: const Value(60),
            recurrenceJson: '{"frequency":"weekly"}',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    final exception = CalendarEventOccurrenceExceptionsCompanion.insert(
      id: 'x1',
      accountId: 'a',
      seriesId: 's1',
      occurrenceKey: '2026-07-27T20:00:00+08:00',
      originalStartAt: const Value(1000),
      kind: 'override',
      overrideJson: '{"version":1,"fields":["title"],"title":"Changed"}',
      createdAt: 1,
      updatedAt: 1,
    );
    await db.into(db.calendarEventOccurrenceExceptions).insert(exception);
    expect(
      db
          .into(db.calendarEventOccurrenceExceptions)
          .insert(exception.copyWith(id: const Value('x2'))),
      throwsA(isA<SqliteException>()),
    );
  });

  test('reminder requires exactly one supported target', () async {
    final db = testDatabase();
    addTearDown(db.close);
    await seedAccount(db, 'a');
    await db.into(db.calendarEvents).insert(timedEvent('e1'));

    expect(
      db
          .into(db.reminders)
          .insert(
            RemindersCompanion.insert(
              id: 'bad',
              accountId: 'a',
              targetType: 'event',
              targetId: 'e1',
              eventId: const Value('e1'),
              triggerAt: 900,
              state: 'desired',
              createdAt: 1,
              updatedAt: 1,
            ).copyWith(planBlockId: const Value('p1')),
          ),
      throwsA(isA<SqliteException>()),
    );
  });

  test('undo slot contains at most one row', () async {
    final db = testDatabase();
    addTearDown(db.close);
    await db.replaceUndoSlot(commandId: 'one', payload: '{}');
    await db.replaceUndoSlot(commandId: 'two', payload: '{}');

    expect((await db.select(db.undoSlot).get()).single.commandId, 'two');
  });

  test('schedule rows remain partitioned by account', () async {
    final db = testDatabase();
    addTearDown(db.close);
    await seedAccount(db, 'a');
    await seedAccount(db, 'b');
    await db.into(db.calendarEvents).insert(timedEvent('same', accountId: 'a'));

    expect(
      db.into(db.calendarEvents).insert(timedEvent('same', accountId: 'b')),
      throwsA(isA<SqliteException>()),
    );
  });

  // --- Schema 7 target rules ------------------------------------------------

  test('series stores product reminder defaults', () async {
    final db = testDatabase();
    addTearDown(db.close);
    await seedAccount(db, 'a');

    // Timed series default: [15].
    await db
        .into(db.calendarEventSeries)
        .insert(
          CalendarEventSeriesCompanion.insert(
            id: 's-timed',
            accountId: 'a',
            title: 'Timed',
            eventType: 'personal',
            timezone: 'Asia/Shanghai',
            startAt: const Value(1000),
            durationMinutes: const Value(60),
            recurrenceJson: '{"frequency":"daily"}',
            reminderOffsetsJson: const Value('[15]'),
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    // All-day series default: [].
    await db
        .into(db.calendarEventSeries)
        .insert(
          CalendarEventSeriesCompanion.insert(
            id: 's-all-day',
            accountId: 'a',
            title: 'AllDay',
            eventType: 'personal',
            timezone: 'Asia/Shanghai',
            allDay: const Value(true),
            anchorStartDate: const Value('2026-07-27'),
            durationDays: const Value(1),
            recurrenceJson: '{"frequency":"daily"}',
            reminderOffsetsJson: const Value('[]'),
            createdAt: 1,
            updatedAt: 1,
          ),
        );

    final timed =
        await (db.select(db.calendarEventSeries)..where(
              (r) => r.id.equals('s-timed'),
            ))
            .getSingle();
    expect(timed.reminderOffsetsJson, '[15]');
    final allDay =
        await (db.select(db.calendarEventSeries)..where(
              (r) => r.id.equals('s-all-day'),
            ))
            .getSingle();
    expect(allDay.reminderOffsetsJson, '[]');
  });

  test('task event link requires target_id and exactly one backing event',
      () async {
    final db = testDatabase();
    addTearDown(db.close);
    await seedAccount(db, 'a');
    await db.into(db.tasks).insert(task('t1'));
    await db.into(db.calendarEvents).insert(timedEvent('e1'));

    // Valid: target_id set and event backing populated.
    await db.into(db.taskEventLinks).insert(
      TaskEventLinksCompanion.insert(
        accountId: 'a',
        taskId: 't1',
        targetId: 'e1',
        eventId: const Value('e1'),
        relationType: 'related',
        createdAt: 1,
      ),
    );

    // Unbacked: neither event nor occurrence exception.
    await expectLater(
      db.into(db.taskEventLinks).insert(
        TaskEventLinksCompanion.insert(
          accountId: 'a',
          taskId: 't1',
          targetId: 'unbacked',
          relationType: 'related',
          createdAt: 1,
        ),
      ),
      throwsA(isA<SqliteException>()),
    );

    // Dual-backed: both event and occurrence exception.
    await db
        .into(db.calendarEventSeries)
        .insert(
          CalendarEventSeriesCompanion.insert(
            id: 's1',
            accountId: 'a',
            title: 'Weekly',
            eventType: 'personal',
            timezone: 'Asia/Shanghai',
            startAt: const Value(1000),
            durationMinutes: const Value(60),
            recurrenceJson: '{"frequency":"weekly"}',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await db.into(db.calendarEventOccurrenceExceptions).insert(
      CalendarEventOccurrenceExceptionsCompanion.insert(
        id: 'x1',
        accountId: 'a',
        seriesId: 's1',
        occurrenceKey: '2026-07-27T20:00:00+08:00',
        originalStartAt: const Value(1000),
        kind: 'override',
        overrideJson: '{}',
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    await expectLater(
      db.into(db.taskEventLinks).insert(
        TaskEventLinksCompanion.insert(
          accountId: 'a',
          taskId: 't1',
          targetId: 'dual',
          eventId: const Value('e1'),
          occurrenceExceptionId: const Value('x1'),
          relationType: 'related',
          createdAt: 1,
        ),
      ),
      throwsA(isA<SqliteException>()),
    );
  });

  test('reminder target_type=event is exclusively event or occurrence backed',
      () async {
    final db = testDatabase();
    addTearDown(db.close);
    await seedAccount(db, 'a');
    await db.into(db.calendarEvents).insert(timedEvent('e1'));

    // Valid stored-event reminder.
    await db.into(db.reminders).insert(
      RemindersCompanion.insert(
        id: 'r-ok',
        accountId: 'a',
        targetType: 'event',
        targetId: 'e1',
        eventId: const Value('e1'),
        triggerAt: 900,
        state: 'desired',
        createdAt: 1,
        updatedAt: 1,
      ),
    );

    // Occurrence-backed reminder is allowed via occurrence_exception_id.
    await db
        .into(db.calendarEventSeries)
        .insert(
          CalendarEventSeriesCompanion.insert(
            id: 's1',
            accountId: 'a',
            title: 'Weekly',
            eventType: 'personal',
            timezone: 'Asia/Shanghai',
            startAt: const Value(1000),
            durationMinutes: const Value(60),
            recurrenceJson: '{"frequency":"weekly"}',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await db.into(db.calendarEventOccurrenceExceptions).insert(
      CalendarEventOccurrenceExceptionsCompanion.insert(
        id: 'x1',
        accountId: 'a',
        seriesId: 's1',
        occurrenceKey: '2026-07-27T20:00:00+08:00',
        originalStartAt: const Value(1000),
        kind: 'override',
        overrideJson: '{}',
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    await db.into(db.reminders).insert(
      RemindersCompanion.insert(
        id: 'r-occ',
        accountId: 'a',
        targetType: 'event',
        targetId: 'occ_v1.locator',
        occurrenceExceptionId: const Value('x1'),
        triggerAt: 900,
        state: 'desired',
        createdAt: 1,
        updatedAt: 1,
      ),
    );

    // Dual-backed event reminder is invalid.
    await expectLater(
      db.into(db.reminders).insert(
        RemindersCompanion.insert(
          id: 'r-dual',
          accountId: 'a',
          targetType: 'event',
          targetId: 'e1',
          eventId: const Value('e1'),
          occurrenceExceptionId: const Value('x1'),
          triggerAt: 900,
          state: 'desired',
          createdAt: 1,
          updatedAt: 1,
        ),
      ),
      throwsA(isA<SqliteException>()),
    );
  });

  test('schedule relation event endpoint takes exactly one backing FK', () async {
    final db = testDatabase();
    addTearDown(db.close);
    await seedAccount(db, 'a');
    await db.into(db.calendarEvents).insert(timedEvent('e1'));

    // Valid: event backing on both sides.
    await db.into(db.scheduleRelations).insert(
      ScheduleRelationsCompanion.insert(
        id: 'rel-event',
        accountId: 'a',
        leftKind: const Value('event'),
        leftId: const Value('e1'),
        leftEventId: const Value('e1'),
        rightKind: const Value('event'),
        rightId: const Value('e1'),
        rightEventId: const Value('e1'),
        conflictState: const Value('conflict'),
        createdAt: 1,
        updatedAt: 1,
      ),
    );

    // Unbacked event endpoint invalid.
    await expectLater(
      db.into(db.scheduleRelations).insert(
        ScheduleRelationsCompanion.insert(
          id: 'rel-unbacked',
          accountId: 'a',
          leftKind: const Value('event'),
          leftId: const Value('nope'),
          rightKind: const Value('event'),
          rightId: const Value('nope'),
          conflictState: const Value('conflict'),
          createdAt: 1,
          updatedAt: 1,
        ),
      ),
      throwsA(isA<SqliteException>()),
    );
  });

  test('imported exam_for_course rows keep every occurrence FK null', () async {
    final db = testDatabase();
    addTearDown(db.close);
    await seedAccount(db, 'a');
    // A valid exam_for_course row (imported) carries no participant FKs at all.
    await db.into(db.scheduleRelations).insert(
      ScheduleRelationsCompanion.insert(
        id: 'rel-exam',
        accountId: 'a',
        source: const Value('ustc_jw'),
        externalId: const Value('ext-1'),
        relationType: const Value('exam_for_course'),
        primaryEntityType: const Value('calendar_event'),
        relatedEntityType: const Value('course_series'),
        primaryEntityId: const Value('prim'),
        relatedEntityId: const Value('rel'),
        createdAt: 1,
        updatedAt: 1,
      ),
    );

    final row =
        await (db.select(db.scheduleRelations)..where(
              (r) => r.id.equals('rel-exam'),
            ))
            .getSingle();
    expect(row.leftOccurrenceExceptionId, isNull);
    expect(row.rightOccurrenceExceptionId, isNull);
  });
}
