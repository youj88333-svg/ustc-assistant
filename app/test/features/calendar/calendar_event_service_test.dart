import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/calendar/application/calendar_event_service.dart';
import 'package:ustc_assistant_app/features/calendar/application/recurrence_service.dart';
import 'package:ustc_assistant_app/features/calendar/domain/calendar_event_locator.dart';
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';
import 'package:ustc_assistant_app/features/calendar/domain/recurrence_rule.dart';
import 'package:ustc_assistant_app/features/tasks/application/undo_recorder.dart';
import 'package:ustc_assistant_app/features/tasks/application/undo_service.dart';

class _FakeUndoRecorder implements UndoRecorder {
  final commands = <UndoCommand>[];

  @override
  Future<void> record(UndoCommand command) async => commands.add(command);
}

DateTime instant(int hour, {int day = 27}) => DateTime(2026, 7, day, hour);

Future<AppDatabase> fixtureDatabase() async {
  final database = AppDatabase(NativeDatabase.memory());
  await database
      .into(database.localAccounts)
      .insert(
        LocalAccountsCompanion.insert(
          id: 'a',
          maskedHint: 'PB****0000',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
  return database;
}

void main() {
  test('timed event requires end after start', () {
    expect(
      () => PersonalEvent.timed(
        title: 'x',
        startAt: instant(10),
        endAt: instant(9),
      ),
      throwsA(isA<CalendarValidationError>()),
    );
  });

  test('all-day end is exclusive and must follow start', () {
    expect(
      () => PersonalEvent.allDay(
        title: 'x',
        startDate: DateTime(2026, 7, 27),
        endDateExclusive: DateTime(2026, 7, 27),
      ),
      throwsA(isA<CalendarValidationError>()),
    );
    final event = PersonalEvent.allDay(
      title: 'x',
      startDate: DateTime(2026, 7, 27),
      endDateExclusive: DateTime(2026, 7, 28),
    );
    expect(event.allDay, isTrue);
    expect(event.startAt, isNull);
  });

  test('timed event may cross midnight', () {
    final event = PersonalEvent.timed(
      title: '夜间安排',
      startAt: instant(23),
      endAt: instant(1, day: 28),
    );
    expect(event.endAt!.isAfter(event.startAt!), isTrue);
  });

  test('manual event derives awaiting completion after end', () {
    final event = PersonalEvent.timed(
      title: '手动确认',
      startAt: instant(9),
      endAt: instant(10),
      completionPolicy: CompletionPolicy.manualConfirmation,
    );
    final state = event.effectiveState(instant(11));
    expect(state.awaitingCompletion, isTrue);
    expect(state.status, EventStatus.active);
  });

  test('automatic completion is derived without changing stored status', () {
    final event = PersonalEvent.allDay(
      title: '全天安排',
      startDate: DateTime(2026, 7, 27),
      endDateExclusive: DateTime(2026, 7, 28),
    );
    final state = event.effectiveState(DateTime(2026, 7, 28, 0, 1));
    expect(state.status, EventStatus.completed);
    expect(event.status, EventStatus.active);
  });

  test('create stores personal event and default timed reminder', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = CalendarEventService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );

    final id = await service.create(
      PersonalEvent.timed(
        title: '写报告',
        startAt: instant(14),
        endAt: instant(15),
      ),
    );

    final stored = await service.byId(id);
    expect(stored.completionPolicy, CompletionPolicy.autoAfterEnd);
    final reminder = (await database.select(database.reminders).get()).single;
    expect(reminder.offsetMinutes, 15);
    expect(
      reminder.triggerAt,
      instant(14).subtract(const Duration(minutes: 15)).millisecondsSinceEpoch,
    );
  });

  test('all-day event has no default reminder', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = CalendarEventService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );

    await service.create(
      PersonalEvent.allDay(
        title: '校庆日',
        startDate: DateTime(2026, 9, 20),
        endDateExclusive: DateTime(2026, 9, 21),
      ),
    );
    expect(await database.select(database.reminders).get(), isEmpty);
  });

  test('source-owned event rejects direct edit', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    await database
        .into(database.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: 'source-event',
            accountId: 'a',
            source: 'ustc_jw',
            title: '课程',
            type: 'course',
            startAt: Value(instant(9).millisecondsSinceEpoch),
            endAt: Value(instant(10).millisecondsSinceEpoch),
            allDay: false,
            timezone: 'Asia/Shanghai',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    final service = CalendarEventService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );

    expect(
      service.edit(
        'source-event',
        PersonalEvent.timed(
          title: '改名',
          startAt: instant(9),
          endAt: instant(10),
        ),
      ),
      throwsA(isA<SourceOwnedEventError>()),
    );
  });

  test(
    'status changes, soft deletion and restore are durable and logged',
    () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = CalendarEventService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      final id = await service.create(
        PersonalEvent.timed(
          title: '打游戏',
          startAt: instant(20),
          endAt: instant(22),
          completionPolicy: CompletionPolicy.manualConfirmation,
        ),
      );

      await service.hide(id);
      expect((await service.byId(id)).status, EventStatus.hidden);
      await service.softDelete(id);
      expect((await service.byId(id, includeDeleted: true)).deletedAt, 100);
      await service.restore(id);
      final restored = await service.byId(id);
      expect(restored.deletedAt, isNull);
      expect(restored.status, EventStatus.active);
      await service.skip(id);
      expect((await service.byId(id)).status, EventStatus.skipped);

      final logs = await database.actionLogsRepository.selectAll();
      expect(
        logs.map((log) => log.actionType),
        contains('calendar_event_skip'),
      );
      expect(logs.every((log) => !log.safeSummary.contains('打游戏')), isTrue);
    },
  );

  test('personal event edit uses the global one-step undo slot', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    var clock = 200;
    final undo = UndoService(
      database: database,
      accountId: 'a',
      now: () => ++clock,
    );
    final service = CalendarEventService(
      database: database,
      accountId: 'a',
      now: () => ++clock,
      undoRecorder: undo,
    );
    final id = await service.create(
      PersonalEvent.timed(
        title: 'Before',
        startAt: instant(9),
        endAt: instant(10),
      ),
    );
    await service.edit(
      id,
      PersonalEvent.timed(
        title: 'After',
        startAt: instant(9),
        endAt: instant(10),
      ),
    );

    await undo.undo();

    expect((await service.byId(id)).title, 'Before');
    expect(await undo.canUndo(), isFalse);
  });

  test('managementEvents returns only user-source lifecycle-state events', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = CalendarEventService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );
    // Active (normal) event.
    final activeId = await service.create(
      PersonalEvent.timed(title: '正常', startAt: instant(9), endAt: instant(10)),
    );
    // Lifecycle-state user events.
    await service.create(
      PersonalEvent.timed(
        title: '取消',
        startAt: instant(11),
        endAt: instant(12),
        status: EventStatus.cancelled,
      ),
    );
    final deletedId = await service.create(
      PersonalEvent.timed(title: '删除', startAt: instant(13), endAt: instant(14)),
    );
    await service.softDelete(deletedId);
    // A source-owned course that must not be surfaced as user management.
    await database.into(database.calendarEvents).insert(
          CalendarEventsCompanion.insert(
            id: 'course-hidden',
            accountId: 'a',
            source: 'ustc_jw',
            title: '课程',
            type: 'course',
            startAt: Value(instant(8).millisecondsSinceEpoch),
            endAt: Value(instant(9).millisecondsSinceEpoch),
            allDay: false,
            timezone: 'Asia/Shanghai',
            status: Value('cancelled'),
            createdAt: 1,
            updatedAt: 1,
          ),
        );

    final management = await service.managementEvents();
    final titles = management.map((e) => e.title).toList();
    expect(titles, isNot(contains('正常')));
    expect(titles, containsAll(['取消', '删除']));
    // The source-owned course is excluded (source=user filter).
    expect(titles, isNot(contains('课程')));
    // The normal event is still visible through the normal read.
    expect((await service.byId(activeId)).title, '正常');
  });

  group('deterministic lifecycle state machine', () {
    test('reopen returns an already_active error when the event is active',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = CalendarEventService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      final id = await service.create(
        PersonalEvent.timed(
          title: 'x',
          startAt: instant(9),
          endAt: instant(10),
          completionPolicy: CompletionPolicy.manualConfirmation,
        ),
      );

      expect(service.reopen(id), throwsA(isA<InvalidLifecycleTransition>()));
    });

    test('skip on a cancelled event returns invalid_lifecycle_transition',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = CalendarEventService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      final id = await service.create(
        PersonalEvent.timed(
          title: 'x',
          startAt: instant(9),
          endAt: instant(10),
          completionPolicy: CompletionPolicy.manualConfirmation,
        ),
      );
      await service.cancel(id);

      expect(service.skip(id), throwsA(isA<InvalidLifecycleTransition>()));
    });

    test('cancelled event can be reopened to active with reminders intact',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      var clock = 100;
      final service = CalendarEventService(
        database: database,
        accountId: 'a',
        now: () => ++clock,
      );
      final id = await service.create(
        PersonalEvent.timed(
          title: 'x',
          startAt: instant(9),
          endAt: instant(10),
          completionPolicy: CompletionPolicy.manualConfirmation,
        ),
      );
      await service.cancel(id);
      // Reopen is NOT undone by a reminder restore: state returns to active.
      await service.reopen(id);
      expect((await service.byId(id)).status, EventStatus.active);
      expect((await service.byId(id)).deletedAt, isNull);
    });

    test('delete on a deleted event returns already_deleted', () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = CalendarEventService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      final id = await service.create(
        PersonalEvent.timed(title: 'x', startAt: instant(9), endAt: instant(10)),
      );
      await service.softDelete(id);

      expect(service.softDelete(id), throwsA(isA<AlreadyDeletedError>()));
    });

    test('lifecycle actions on a deleted event return already_deleted',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = CalendarEventService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      final id = await service.create(
        PersonalEvent.timed(
          title: 'x',
          startAt: instant(9),
          endAt: instant(10),
          completionPolicy: CompletionPolicy.manualConfirmation,
        ),
      );
      await service.softDelete(id);

      // Every non-restore lifecycle action on a soft-deleted event must map to
      // a deterministic already_deleted error, never a bare StateError.
      expect(service.complete(id), throwsA(isA<AlreadyDeletedError>()));
      expect(service.skip(id), throwsA(isA<AlreadyDeletedError>()));
      expect(service.cancel(id), throwsA(isA<AlreadyDeletedError>()));
      expect(service.reopen(id), throwsA(isA<AlreadyDeletedError>()));
    });

    test('cancel only cancels future desired reminders and preserves history',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      var clock = 100;
      final service = CalendarEventService(
        database: database,
        accountId: 'a',
        now: () => ++clock,
      );
      final id = await service.create(
        PersonalEvent.timed(
          title: 'x',
          startAt: instant(9),
          endAt: instant(10),
          completionPolicy: CompletionPolicy.manualConfirmation,
        ),
      );
      // A delivered reminder from the past history must survive cancelling.
      await (database.update(
        database.reminders,
      )..where((row) => row.eventId.equals(id))).write(
        const RemindersCompanion(
          state: Value('delivered'),
          deliveredAt: Value(50),
        ),
      );
      // A missed already-triggered history reminder with a distinct trigger.
      final timestamp = nowAt(8).millisecondsSinceEpoch;
      await database.into(database.reminders).insert(
            RemindersCompanion.insert(
              id: 'reminder:event:$id:1',
              accountId: 'a',
              targetType: 'event',
              targetId: id,
              eventId: Value(id),
              offsetMinutes: const Value(15),
              triggerAt: timestamp,
              state: 'missed',
              createdAt: 1,
              updatedAt: 1,
            ),
          );

      await service.cancel(id);

      final rows = await database.select(database.reminders).get();
      expect(rows.any((r) => r.state == 'delivered'), isTrue);
      // Missed (already-triggered) history is also preserved.
      expect(rows.any((r) => r.state == 'missed'), isTrue);
      // No desired reminder remains.
      expect(rows.any((r) => r.state == 'desired'), isFalse);
    });

    test('lifecycle writes an Undo snapshot and an user action log', () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      var clock = 100;
      final undo = _FakeUndoRecorder();
      final service = CalendarEventService(
        database: database,
        accountId: 'a',
        now: () => ++clock,
        undoRecorder: undo,
      );
      final id = await service.create(
        PersonalEvent.timed(
          title: 'x',
          startAt: instant(9),
          endAt: instant(10),
          completionPolicy: CompletionPolicy.manualConfirmation,
        ),
      );
      final before = undo.commands.length;

      await service.complete(id);

      expect(undo.commands.length, before + 1);
      expect(
        undo.commands.last.kind,
        'calendar_event_complete',
      );
      final logs = await database.actionLogsRepository.selectAll();
      expect(
        logs.map((log) => log.actionType),
        contains('calendar_event_complete'),
      );
    });
  });

  group('recurring occurrence task links', () {
    test('linking a task to a recurring occurrence creates one no-op anchor '
        'and a single occurrence-backed link row; repeated link is idempotent',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final recurrence = RecurrenceService(
        database: database,
        accountId: 'a',
        now: () => 1,
      );
      final seriesId = await recurrence.createSeries(
        anchor: PersonalEvent.timed(
          title: '每周例会',
          startAt: DateTime(2026, 7, 27, 15),
          endAt: DateTime(2026, 7, 27, 16),
        ),
        rule: RecurrenceRule.weekly(
          anchor: DateTime(2026, 7, 27, 15),
          weekdays: {DateTime.monday},
        ),
      );
      final occ = (await recurrence.occurrences(
        seriesId,
        from: DateTime(2026, 7, 27, 15),
        through: DateTime(2026, 7, 27, 15),
      )).single;
      final locator = encodeCalendarEventLocator(
        RecurringOccurrenceLocator(
          seriesId: seriesId,
          occurrenceKey: occ.occurrenceKey,
        ),
      );
      await database.into(database.tasks).insert(
            TasksCompanion.insert(
              id: 'task-1',
              accountId: 'a',
              title: '准备材料',
              state: 'active',
              importance: 'normal',
              tagsJson: '[]',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      final service = CalendarEventService(database: database, accountId: 'a');

      await service.linkTaskToEvent('task-1', locator);
      await service.linkTaskToEvent('task-1', locator);

      final links = await database.select(database.taskEventLinks).get();
      final anchors =
          await database.select(database.calendarEventOccurrenceExceptions).get();
      // Exactly one reusable no-op anchor and one canonical link row.
      expect(anchors, hasLength(1));
      expect(anchors.single.kind, 'override');
      expect(anchors.single.overriddenFieldsJson, '[]');
      expect(links, hasLength(1));
      final link = links.single;
      expect(link.taskId, 'task-1');
      expect(link.targetId, locator);
      expect(link.eventId, isNull);
      expect(link.occurrenceExceptionId, anchors.single.id);
      expect(link.relationType, 'related');
    });

    test('linking a task to a stored event keeps event-backed link and no '
        'anchor is created', () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      await database.into(database.tasks).insert(
            TasksCompanion.insert(
              id: 'task-1',
              accountId: 'a',
              title: '准备材料',
              state: 'active',
              importance: 'normal',
              tagsJson: '[]',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      final service = CalendarEventService(database: database, accountId: 'a');
      final id = await service.create(
        PersonalEvent.timed(
          title: '一对一',
          startAt: instant(14),
          endAt: instant(15),
        ),
      );
      await service.linkTaskToEvent('task-1', id);

      final link = (await database.select(database.taskEventLinks).get()).single;
      expect(link.targetId, id);
      expect(link.eventId, id);
      expect(link.occurrenceExceptionId, isNull);
      expect(
        await database.select(database.calendarEventOccurrenceExceptions).get(),
        isEmpty,
      );
    });
  });
}

DateTime nowAt(int hour) => DateTime(2026, 7, 27, hour);
