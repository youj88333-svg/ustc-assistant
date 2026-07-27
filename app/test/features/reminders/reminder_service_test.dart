import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/reminders/application/reminder_service.dart';
import 'package:ustc_assistant_app/features/reminders/domain/reminder_rule.dart';

void main() {
  test('default reminder offsets match the product contract', () {
    expect(ReminderDefaults.forEvent('exam'), [1440, 120]);
    expect(ReminderDefaults.forEvent('second_class'), [120]);
    expect(ReminderDefaults.forEvent('course'), [15]);
    expect(ReminderDefaults.forEvent('personal'), [15]);
    expect(ReminderDefaults.forEvent('personal', allDay: true), isEmpty);
    expect(ReminderDefaults.forTask(), [1440, 120]);
    expect(ReminderDefaults.forPlanBlock(), [10]);
  });

  group('deterministic reminder records', () {
    late AppDatabase database;
    const accountId = 'account';
    var now = DateTime.utc(2026, 7, 27, 0).millisecondsSinceEpoch;

    setUp(() async {
      database = AppDatabase(NativeDatabase.memory());
      await database
          .into(database.localAccounts)
          .insert(
            LocalAccountsCompanion.insert(
              id: accountId,
              maskedHint: 'PB****0000',
              createdAt: now,
              updatedAt: now,
            ),
          );
    });
    tearDown(() => database.close());

    test('event and plan block defaults are expanded exactly once', () async {
      final start = DateTime.utc(2026, 7, 30, 2).millisecondsSinceEpoch;
      for (final entry in const {
        'course': 'course',
        'exam': 'exam',
        'second': 'second_class',
        'personal': 'personal',
      }.entries) {
        await database
            .into(database.calendarEvents)
            .insert(
              CalendarEventsCompanion.insert(
                id: entry.key,
                accountId: accountId,
                source: 'user',
                title: entry.key,
                type: entry.value,
                startAt: Value(start),
                endAt: Value(start + 3600000),
                allDay: false,
                timezone: 'Asia/Shanghai',
                createdAt: now,
                updatedAt: now,
              ),
            );
      }
      await database
          .into(database.calendarEvents)
          .insert(
            CalendarEventsCompanion.insert(
              id: 'all-day',
              accountId: accountId,
              source: 'user',
              title: 'all-day',
              type: 'personal',
              allDay: true,
              startDate: const Value('2026-07-30'),
              endDateExclusive: const Value('2026-07-31'),
              timezone: 'Asia/Shanghai',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await database
          .into(database.tasks)
          .insert(
            TasksCompanion.insert(
              id: 'task',
              accountId: accountId,
              title: 'task',
              state: 'active',
              importance: 'normal',
              tagsJson: '[]',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await database
          .into(database.planBlocks)
          .insert(
            PlanBlocksCompanion.insert(
              id: 'block',
              accountId: accountId,
              taskId: 'task',
              startAt: start,
              endAt: start + 3600000,
              status: 'accepted',
              createdAt: now,
              updatedAt: now,
            ),
          );
      final service = ReminderService(database: database, now: () => now);

      await service.reconcileAll(accountId);
      await service.reconcileAll(accountId);

      final rows = await database.select(database.reminders).get();
      expect(
        rows.where((row) => row.eventId == 'course').single.offsetMinutes,
        15,
      );
      expect(
        rows
            .where((row) => row.eventId == 'exam')
            .map((row) => row.offsetMinutes)
            .toSet(),
        {1440, 120},
      );
      expect(
        rows.where((row) => row.eventId == 'second').single.offsetMinutes,
        120,
      );
      expect(
        rows.where((row) => row.eventId == 'personal').single.offsetMinutes,
        15,
      );
      expect(rows.where((row) => row.eventId == 'all-day'), isEmpty);
      expect(
        rows.where((row) => row.planBlockId == 'block').single.offsetMinutes,
        10,
      );
    });

    for (final deadline in [
      DateTime.utc(2026, 7, 28, 8),
      DateTime.utc(2026, 8, 1, 8),
      DateTime.utc(2027, 1, 1, 8),
    ]) {
      test(
        'task deadline has only 24-hour and 2-hour reminders at $deadline',
        () async {
          await database
              .into(database.tasks)
              .insert(
                TasksCompanion.insert(
                  id: 'task',
                  accountId: accountId,
                  title: 'task',
                  state: 'active',
                  importance: 'normal',
                  deadlineAt: Value(deadline.millisecondsSinceEpoch),
                  tagsJson: '[]',
                  createdAt: now,
                  updatedAt: now,
                ),
              );
          await ReminderService(
            database: database,
            now: () => now,
          ).reconcileAll(accountId);
          final triggers = (await database.select(database.reminders).get())
              .map((row) => row.triggerAt)
              .toSet();
          expect(triggers, {
            deadline.subtract(const Duration(hours: 24)).millisecondsSinceEpoch,
            deadline.subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
          });
        },
      );
    }

    test(
      'no deadline and terminal tasks never create daily reminders',
      () async {
        for (final entry in const {
          'none': 'active',
          'done': 'completed',
        }.entries) {
          await database
              .into(database.tasks)
              .insert(
                TasksCompanion.insert(
                  id: entry.key,
                  accountId: accountId,
                  title: entry.key,
                  state: entry.value,
                  importance: 'normal',
                  deadlineAt: Value(
                    entry.key == 'none' ? null : now + 86400000,
                  ),
                  tagsJson: '[]',
                  completedAt: Value(entry.value == 'completed' ? now : null),
                  createdAt: now,
                  updatedAt: now,
                ),
              );
        }
        await ReminderService(
          database: database,
          now: () => now,
        ).reconcileAll(accountId);
        expect(await database.select(database.reminders).get(), isEmpty);
      },
    );

    test(
      'reschedule keeps override offsets and hidden invalidates pending rows',
      () async {
        final start = now + const Duration(days: 3).inMilliseconds;
        await database
            .into(database.calendarEvents)
            .insert(
              CalendarEventsCompanion.insert(
                id: 'event',
                accountId: accountId,
                source: 'user',
                title: 'event',
                type: 'personal',
                startAt: Value(start),
                endAt: Value(start + 3600000),
                allDay: false,
                timezone: 'Asia/Shanghai',
                createdAt: now,
                updatedAt: now,
              ),
            );
        final service = ReminderService(database: database, now: () => now);
        await service.reconcileAll(accountId);
        await (database.update(database.reminders)
              ..where((row) => row.eventId.equals('event')))
            .write(const RemindersCompanion(offsetMinutes: Value(30)));
        final moved = start + 3600000;
        await (database.update(
          database.calendarEvents,
        )..where((row) => row.id.equals('event'))).write(
          CalendarEventsCompanion(
            startAt: Value(moved),
            endAt: Value(moved + 3600000),
          ),
        );
        await service.reconcileAll(accountId);
        var row = await (database.select(
          database.reminders,
        )..where((item) => item.state.equals('desired'))).getSingle();
        expect(row.offsetMinutes, 30);
        expect(
          row.triggerAt,
          moved - const Duration(minutes: 30).inMilliseconds,
        );

        await database
            .into(database.userOverlays)
            .insert(
              UserOverlaysCompanion.insert(
                id: 'overlay',
                accountId: accountId,
                eventId: const Value('event'),
                hidden: const Value(true),
                createdAt: now,
                updatedAt: now,
              ),
            );
        await service.reconcileAll(accountId);
        expect(
          (await database.select(database.reminders).get()).where(
            (item) => item.state == 'desired',
          ),
          isEmpty,
        );
      },
    );

    test(
      'startup marks elapsed desired reminders missed without delivery',
      () async {
        await database
            .into(database.tasks)
            .insert(
              TasksCompanion.insert(
                id: 'task',
                accountId: accountId,
                title: 'task',
                state: 'active',
                importance: 'normal',
                deadlineAt: Value(
                  now + const Duration(hours: 1).inMilliseconds,
                ),
                tagsJson: '[]',
                createdAt: now,
                updatedAt: now,
              ),
            );
        final service = ReminderService(database: database, now: () => now);
        await service.reconcileAll(accountId);
        expect(
          (await database.select(database.reminders).get())
              .where((row) => row.triggerAt <= now)
              .every((row) => row.state == 'missed'),
          isTrue,
        );
      },
    );
  });
}
