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
      eventId: 'e1',
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
              reviewState: 'pending',
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
}
