import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/calendar/application/calendar_event_service.dart';
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';

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
}
