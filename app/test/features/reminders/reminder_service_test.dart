import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/calendar/application/recurrence_service.dart';
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';
import 'package:ustc_assistant_app/features/calendar/domain/recurrence_rule.dart';
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
      'cancel/delete only cancel future desired reminders and preserve history',
      () async {
        final start = now + const Duration(days: 3).inMilliseconds;
        void seed(String id, String status) async {
          await database
              .into(database.tasks)
              .insert(
                TasksCompanion.insert(
                  id: id,
                  accountId: accountId,
                  title: id,
                  state: 'active',
                  importance: 'normal',
                  deadlineAt: Value(start),
                  tagsJson: '[]',
                  createdAt: now,
                  updatedAt: now,
                ),
              );
          await database
              .into(database.reminders)
              .insert(
                RemindersCompanion.insert(
                  id: 'reminder:task:$id:1',
                  accountId: accountId,
                  targetType: 'task',
                  targetId: id,
                  taskId: Value(id),
                  offsetMinutes: const Value(10),
                  triggerAt: start,
                  state: status,
                  createdAt: now,
                  updatedAt: now,
                ),
              );
        }

        // A future-desired reminder that reconcile must cancel.
        seed('future', 'desired');
        // A delivered historical reminder that must be preserved.
        seed('done-hist', 'delivered');
        // A missed already-triggered reminder that must be preserved.
        seed('missed-hist', 'missed');
        final service = ReminderService(database: database, now: () => now);

        // All three owning tasks become terminal (cancelled / soft-deleted), so
        // reconcile suppresses them and must never recreate default reminders.
        await (database.update(
          database.tasks,
        )..where((r) => r.id.equals('future'))).write(
          TasksCompanion(
            state: const Value('cancelled'),
            cancelledAt: Value(now),
          ),
        );
        for (final id in ['done-hist', 'missed-hist']) {
          await (database.update(
            database.tasks,
          )..where((r) => r.id.equals(id))).write(
            TasksCompanion(deletedAt: Value(now + 1)),
          );
        }
        await service.reconcileAll(accountId);

        final rows = await database.select(database.reminders).get();
        // Future desired is cancelled (row preserved, never recreated).
        final future = rows.singleWhere((r) => r.targetId == 'future');
        expect(future.state, 'cancelled');
        // Delivered + missed history preserved exactly.
        final delivered = rows.singleWhere((r) => r.targetId == 'done-hist');
        expect(delivered.state, 'delivered');
        final missed = rows.singleWhere((r) => r.targetId == 'missed-hist');
        expect(missed.state, 'missed');
        // Ensure no new desired reminders were created for terminal tasks.
        expect(
          rows.where((r) => r.taskId != null && r.state == 'desired'),
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

  group('recurring series reminder reconciliation', () {
    late AppDatabase database;
    const accountId = 'account';
    var now = DateTime.utc(2026, 8, 4, 0).millisecondsSinceEpoch;

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

    test('timed recurring series defaults schedule bounded desired reminders '
        'via one reused anchor per occurrence', () async {
      // A daily series anchored today at 09:00 Beijing. today (UTC0) = 08-04.
      // Reconcile projects today..+31 days.
      final service = RecurrenceService(
        database: database,
        accountId: accountId,
        now: () => now,
      );
      await service.createSeries(
        anchor: PersonalEvent.timed(
          title: '每日站会',
          startAt: DateTime(2026, 8, 4, 9, 0),
          endAt: DateTime(2026, 8, 4, 9, 30),
        ),
        rule: RecurrenceRule.daily(anchor: DateTime(2026, 8, 4, 9, 0)),
      );

      await ReminderService(
        database: database,
        now: () => now,
      ).reconcileAll(accountId);
      await ReminderService(
        database: database,
        now: () => now,
      ).reconcileAll(accountId);

      final reminderRows = await database.select(database.reminders).get();
      // 31 occurrence days starting today, each one 15-min offset reminder,
      // triggered after 'now' (which is 00:00 UTC on 08-04; first trigger
      // 09:00 - 15m > now).
      expect(reminderRows, hasLength(31));
      expect(reminderRows.every((r) => r.state == 'desired'), isTrue);
      expect(reminderRows.every((r) => r.targetType == 'event'), isTrue);
      expect(reminderRows.every((r) => r.eventId == null), isTrue,
          reason: 'recurring reminders never populate the stored event FK');
      // Every reminder points to a reused occurrence-exception anchor, and a
      // second reconcile run must not duplicate anchors.
      final anchors =
          await database.select(database.calendarEventOccurrenceExceptions).get();
      expect(anchors, hasLength(31));
      final anchorIds = anchors.map((a) => a.id).toSet();
      expect(reminderRows.every((r) => anchorIds.contains(r.occurrenceExceptionId)),
          isTrue);
      // All anchors are the sparse no-op kind.
      expect(anchors.every((a) => a.kind == 'override' && a.overriddenFieldsJson == '[]'),
          isTrue);
      // Triggers are distinct (no duplicate identical triggers).
      expect(
        reminderRows.map((r) => r.triggerAt).toSet(),
        reminderRows.map((r) => r.triggerAt).toSet(),
      );
    });

    test('all-day series with an empty default creates no reminder rows', () async {
      final service = RecurrenceService(
        database: database,
        accountId: accountId,
        now: () => now,
      );
      await service.createSeries(
        anchor: PersonalEvent.allDay(
          title: '每天复盘',
          startDate: DateTime(2026, 8, 4),
          endDateExclusive: DateTime(2026, 8, 5),
        ),
        rule: RecurrenceRule.daily(anchor: DateTime(2026, 8, 4)),
      );
      await ReminderService(
        database: database,
        now: () => now,
      ).reconcileAll(accountId);
      expect(await database.select(database.reminders).get(), isEmpty);
      expect(
        await database.select(database.calendarEventOccurrenceExceptions).get(),
        isEmpty,
      );
    });

    test('reconcile cancels desired reminders when the owning occurrence is '
        'cancelled/deleted and preserves delivered/missed/failed history', () async {
      final service = RecurrenceService(
        database: database,
        accountId: accountId,
        now: () => now,
      );
      await service.createSeries(
        anchor: PersonalEvent.timed(
          title: '每日站会',
          startAt: DateTime(2026, 8, 4, 9, 0),
          endAt: DateTime(2026, 8, 4, 9, 30),
        ),
        rule: RecurrenceRule.daily(anchor: DateTime(2026, 8, 4, 9, 0)),
      );
      await ReminderService(
        database: database,
        now: () => now,
      ).reconcileAll(accountId);
      final anchors =
          await database.select(database.calendarEventOccurrenceExceptions).get();

      // Simulate a persisted delivered + missed history row attached to the
      // first occurrence's anchor (must be preserved through reconcile).
      final firstAnchor = anchors.first;
      await database.into(database.reminders).insert(
            RemindersCompanion.insert(
              id: 'hist-delivered',
              accountId: accountId,
              targetType: 'event',
              targetId: 'locator',
              occurrenceExceptionId: Value(firstAnchor.id),
              offsetMinutes: const Value(15),
              triggerAt: 1,
              state: 'delivered',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await database.into(database.reminders).insert(
            RemindersCompanion.insert(
              id: 'hist-missed',
              accountId: accountId,
              targetType: 'event',
              targetId: 'locator',
              occurrenceExceptionId: Value(firstAnchor.id),
              offsetMinutes: const Value(15),
              triggerAt: 2,
              state: 'missed',
              createdAt: now,
              updatedAt: now,
            ),
          );

      // Cancel the first occurrence's anchor (as a lifecycle cancel would).
      await (database.update(
        database.calendarEventOccurrenceExceptions,
      )..where((r) => r.id.equals(firstAnchor.id))).write(
        CalendarEventOccurrenceExceptionsCompanion(
          status: const Value('cancelled'),
          deletedAt: Value(now),
        ),
      );

      await ReminderService(
        database: database,
        now: () => now,
      ).reconcileAll(accountId);

      final rows = await database.select(database.reminders).get();
      // The cancelled occurrence's future desired reminder is cancelled (not
      // deleted, never recreated).
      final cancelledTargetRows =
          rows.where((r) => r.occurrenceExceptionId == firstAnchor.id).toList();
      expect(cancelledTargetRows.any((r) => r.state == 'desired'), isFalse);
      // History preserved.
      expect(
        rows.singleWhere((r) => r.id == 'hist-delivered').state,
        'delivered',
      );
      expect(
        rows.singleWhere((r) => r.id == 'hist-missed').state,
        'missed',
      );
      // The remaining 30 occurrences still hold their desired reminders.
      expect(
        rows.where((r) => r.state == 'desired' &&
            r.occurrenceExceptionId != firstAnchor.id),
        hasLength(30),
      );
    });

    test('reconcile never expands beyond a 31-day bounded lookahead', () async {
      final service = RecurrenceService(
        database: database,
        accountId: accountId,
        now: () => now,
      );
      await service.createSeries(
        anchor: PersonalEvent.timed(
          title: '每日站会',
          startAt: DateTime(2026, 8, 4, 9, 0),
          endAt: DateTime(2026, 8, 4, 9, 30),
        ),
        rule: RecurrenceRule.daily(anchor: DateTime(2026, 8, 4, 9, 0)),
      );
      await ReminderService(
        database: database,
        now: () => now,
      ).reconcileAll(accountId);
      // Exactly 31 occurrence days (today through today+30), none beyond.
      final rows = await database.select(database.reminders).get();
      expect(rows, hasLength(31));
      final anchors =
          await database.select(database.calendarEventOccurrenceExceptions).get();
      expect(anchors, hasLength(31));
    });
  });
}
