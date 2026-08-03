import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/calendar/application/recurrence_service.dart';
import 'package:ustc_assistant_app/features/calendar/application/recurring_event_projection.dart';
import 'package:ustc_assistant_app/features/calendar/domain/calendar_event_locator.dart';
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';
import 'package:ustc_assistant_app/features/calendar/domain/recurrence_expander.dart';
import 'package:ustc_assistant_app/features/calendar/domain/recurrence_rule.dart';

DateTime at(int year, int month, int day, [int hour = 9]) =>
    DateTime(year, month, day, hour);

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

Future<RecurrenceService> serviceFor(AppDatabase database, String accountId) =>
    Future.value(
      RecurrenceService(database: database, accountId: accountId, now: () => 100),
    );

void main() {
  test('projects timed and all-day daily series in display mode', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = await serviceFor(database, 'a');
    final projector = RecurringEventProjector(service: service);

    await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '每日练习',
        startAt: at(2026, 7, 6, 8),
        endAt: at(2026, 7, 6, 9),
      ),
      rule: RecurrenceRule.daily(anchor: at(2026, 7, 6, 8)),
    );
    await service.createSeries(
      anchor: PersonalEvent.allDay(
        title: '全天值日',
        startDate: DateTime(2026, 7, 6),
        endDateExclusive: DateTime(2026, 7, 7),
      ),
      rule: RecurrenceRule.daily(anchor: DateTime(2026, 7, 6)),
    );

    final projected = await projector.projectRange(
      from: DateTime(2026, 7, 6),
      through: at(2026, 7, 8, 23),
      mode: RecurringProjectionMode.display,
    );
    // 3 timed + 3 all-day occurrences over the inclusive range.
    expect(projected, hasLength(6));
    final times = projected
        .where((p) => !p.occurrence.allDay)
        .map((p) => p.occurrence.originalStart)
        .toList();
    expect(times, [at(2026, 7, 6, 8), at(2026, 7, 7, 8), at(2026, 7, 8, 8)]);
    final allDayCount = projected.where((p) => p.occurrence.allDay).length;
    expect(allDayCount, 3);
    // All targets are occurrences bound to a `occ_v1...` locator.
    for (final p in projected) {
      expect(p.locator, isA<RecurringOccurrenceLocator>());
      expect(p.availableScopes, ['only_this', 'this_and_future', 'whole_series']);
      expect(p.isOccurrence, isTrue);
    }
  });

  test('projects weekly multi-weekday occurrences in range', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = await serviceFor(database, 'a');
    final projector = RecurringEventProjector(service: service);

    await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '班委会',
        startAt: at(2026, 7, 6, 20),
        endAt: at(2026, 7, 6, 21),
      ),
      rule: RecurrenceRule.weekly(
        anchor: at(2026, 7, 6, 20),
        weekdays: {DateTime.monday, DateTime.thursday},
      ),
    );

    final projected = await projector.projectRange(
      from: at(2026, 7, 6),
      through: at(2026, 7, 13, 23),
      mode: RecurringProjectionMode.display,
    );
    final originals = projected
        .map((p) => p.occurrence.originalStart)
        .toList();
    expect(originals, [at(2026, 7, 6, 20), at(2026, 7, 9, 20), at(2026, 7, 13, 20)]);
  });

  test('projects monthly month-end including day-31 clamping', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = await serviceFor(database, 'a');
    final projector = RecurringEventProjector(service: service);

    await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '月末结算',
        startAt: at(2026, 1, 31, 10),
        endAt: at(2026, 1, 31, 11),
      ),
      rule: RecurrenceRule.monthly(anchor: at(2026, 1, 31, 10)),
    );

    final projected = await projector.projectRange(
      from: at(2026, 1, 1),
      through: at(2026, 3, 31, 23),
      mode: RecurringProjectionMode.display,
    );
    final originals = projected
        .map((p) => p.occurrence.originalStart)
        .toList();
    expect(originals, [at(2026, 1, 31, 10), at(2026, 2, 28, 10), at(2026, 3, 31, 10)]);
  });

  test('moved override keeps original occurrence identity', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = await serviceFor(database, 'a');
    final projector = RecurringEventProjector(service: service);

    final seriesId = await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '晚自习',
        startAt: at(2026, 7, 6, 20),
        endAt: at(2026, 7, 6, 22),
      ),
      rule: RecurrenceRule.weekly(
        anchor: at(2026, 7, 6, 20),
        weekdays: {DateTime.monday},
      ),
    );
    final key = occurrenceKey(seriesId, at(2026, 7, 13, 20));
    await service.editOnlyThis(
      seriesId,
      key,
      OccurrenceOverride(startAt: OverrideValue.set(at(2026, 7, 13, 19))),
    );

    final projected = await projector.projectRange(
      from: at(2026, 7, 13),
      through: at(2026, 7, 13, 23),
      mode: RecurringProjectionMode.display,
    );
    expect(projected, hasLength(1));
    final p = projected.single;
    // Identity (key + originalStart) is retained even though the time moved.
    expect(p.occurrence.occurrenceKey, key);
    expect(p.occurrence.originalStart, at(2026, 7, 13, 20));
    expect(p.occurrence.startAt, at(2026, 7, 13, 19));
    final loc = p.locator as RecurringOccurrenceLocator;
    expect(loc.seriesId, seriesId);
    expect(loc.occurrenceKey, key);
    expect(encodeCalendarEventLocator(loc), startsWith('occ_v1.'));
  });

  test('cancelled exception is hidden in display but visible in management',
      () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = await serviceFor(database, 'a');
    final projector = RecurringEventProjector(service: service);

    final seriesId = await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '专项',
        startAt: at(2026, 7, 6, 10),
        endAt: at(2026, 7, 6, 11),
      ),
      rule: RecurrenceRule.weekly(
        anchor: at(2026, 7, 6, 10),
        weekdays: {DateTime.monday},
      ),
    );
    final key = occurrenceKey(seriesId, at(2026, 7, 13, 10));
    await service.editOnlyThis(
      seriesId,
      key,
      const OccurrenceOverride(status: OverrideValue.set(EventStatus.cancelled)),
    );

    final display = await projector.projectRange(
      from: at(2026, 7, 6),
      through: at(2026, 7, 14, 23),
      mode: RecurringProjectionMode.display,
    );
    expect(display, hasLength(1));
    expect(display.single.occurrence.originalStart, at(2026, 7, 6, 10));

    final management = await projector.projectRange(
      from: at(2026, 7, 6),
      through: at(2026, 7, 14, 23),
      mode: RecurringProjectionMode.management,
      lifecycleStates: const {'cancelled'},
    );
    expect(management, hasLength(1));
    expect(management.single.lifecycleState, 'cancelled');
    expect(management.single.occurrence.originalStart, at(2026, 7, 13, 10));
  });

  test('deleted exception is hidden in display but visible in management',
      () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = await serviceFor(database, 'a');
    final projector = RecurringEventProjector(service: service);

    final seriesId = await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '值班',
        startAt: at(2026, 7, 6, 10),
        endAt: at(2026, 7, 6, 11),
      ),
      rule: RecurrenceRule.weekly(
        anchor: at(2026, 7, 6, 10),
        weekdays: {DateTime.monday},
      ),
    );
    final key = occurrenceKey(seriesId, at(2026, 7, 13, 10));
    await service.editOnlyThis(
      seriesId,
      key,
      const OccurrenceOverride(title: OverrideValue.set('待删')),
    );
    // Soft-delete the exception row directly.
    await (database.update(database.calendarEventOccurrenceExceptions)
          ..where((row) => row.occurrenceKey.equals(key)))
        .write(
          CalendarEventOccurrenceExceptionsCompanion(deletedAt: Value(200)),
        );

    final display = await projector.projectRange(
      from: at(2026, 7, 6),
      through: at(2026, 7, 14, 23),
      mode: RecurringProjectionMode.display,
    );
    expect(display, hasLength(1));

    final management = await projector.projectRange(
      from: at(2026, 7, 6),
      through: at(2026, 7, 14, 23),
      mode: RecurringProjectionMode.management,
      lifecycleStates: const {'deleted'},
    );
    expect(management, hasLength(1));
    expect(management.single.lifecycleState, 'deleted');
    expect(management.single.deletedAt, 200);
  });

  test('cancelled whole series hidden in display but visible in management',
      () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = await serviceFor(database, 'a');
    final projector = RecurringEventProjector(service: service);

    final seriesId = await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '整系列取消',
        startAt: at(2026, 7, 6, 10),
        endAt: at(2026, 7, 6, 11),
      ),
      rule: RecurrenceRule.daily(anchor: at(2026, 7, 6, 10)),
    );
    await (database.update(database.calendarEventSeries)
          ..where((row) => row.id.equals(seriesId)))
        .write(
          CalendarEventSeriesCompanion(
            status: const Value('cancelled'),
            updatedAt: Value(200),
          ),
        );

    final display = await projector.projectRange(
      from: at(2026, 7, 6),
      through: at(2026, 7, 8, 23),
      mode: RecurringProjectionMode.display,
    );
    expect(display, isEmpty);

    final management = await projector.projectRange(
      from: at(2026, 7, 6),
      through: at(2026, 7, 8, 23),
      mode: RecurringProjectionMode.management,
      lifecycleStates: const {'cancelled'},
    );
    expect(management, hasLength(3));
    expect(management.every((p) => p.lifecycleState == 'cancelled'), isTrue);
  });

  test('deleted whole series hidden in display but visible in management',
      () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = await serviceFor(database, 'a');
    final projector = RecurringEventProjector(service: service);

    final seriesId = await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '整系列删除',
        startAt: at(2026, 7, 6, 10),
        endAt: at(2026, 7, 6, 11),
      ),
      rule: RecurrenceRule.daily(anchor: at(2026, 7, 6, 10)),
    );
    await (database.update(database.calendarEventSeries)
          ..where((row) => row.id.equals(seriesId)))
        .write(
          CalendarEventSeriesCompanion(
            deletedAt: Value(200),
            updatedAt: Value(200),
          ),
        );

    final display = await projector.projectRange(
      from: at(2026, 7, 6),
      through: at(2026, 7, 8, 23),
      mode: RecurringProjectionMode.display,
    );
    expect(display, isEmpty);

    final management = await projector.projectRange(
      from: at(2026, 7, 6),
      through: at(2026, 7, 8, 23),
      mode: RecurringProjectionMode.management,
      lifecycleStates: const {'deleted'},
    );
    expect(management, hasLength(3));
    expect(management.every((p) => p.lifecycleState == 'deleted'), isTrue);
  });

  test('honors series effective bounds (until date)', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = await serviceFor(database, 'a');
    final projector = RecurringEventProjector(service: service);

    await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '有期限',
        startAt: at(2026, 7, 6, 10),
        endAt: at(2026, 7, 6, 11),
      ),
      rule: RecurrenceRule.daily(
        anchor: at(2026, 7, 6, 10),
        untilDate: DateTime(2026, 7, 8),
      ),
    );

    final projected = await projector.projectRange(
      from: at(2026, 7, 6),
      through: at(2026, 7, 20, 23),
      mode: RecurringProjectionMode.display,
    );
    final originals = projected
        .map((p) => p.occurrence.originalStart)
        .toList();
    expect(originals, [at(2026, 7, 6, 10), at(2026, 7, 7, 10), at(2026, 7, 8, 10)]);
  });

  test('isolation: projector bound to account a ignores account b series',
      () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    await database.into(database.localAccounts).insert(
          LocalAccountsCompanion.insert(
            id: 'b',
            maskedHint: 'PB****0001',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    final serviceA = await serviceFor(database, 'a');
    final serviceB = await serviceFor(database, 'b');
    await serviceB.createSeries(
      anchor: PersonalEvent.timed(
        title: '别的账号',
        startAt: at(2026, 7, 6, 10),
        endAt: at(2026, 7, 6, 11),
      ),
      rule: RecurrenceRule.daily(anchor: at(2026, 7, 6, 10)),
    );

    final projector = RecurringEventProjector(service: serviceA);
    final projected = await projector.projectRange(
      from: at(2026, 7, 6),
      through: at(2026, 7, 8, 23),
      mode: RecurringProjectionMode.display,
    );
    expect(projected, isEmpty);
  });

  test('projection performs zero writes to schedule tables', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = await serviceFor(database, 'a');
    final projector = RecurringEventProjector(service: service);

    final seriesId = await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '只读',
        startAt: at(2026, 7, 6, 10),
        endAt: at(2026, 7, 6, 11),
      ),
      rule: RecurrenceRule.daily(anchor: at(2026, 7, 6, 10)),
    );
    final key = occurrenceKey(seriesId, at(2026, 7, 7, 10));
    await service.editOnlyThis(
      seriesId,
      key,
      const OccurrenceOverride(title: OverrideValue.set('唯一例外')),
    );

    final seriesBefore = await database.select(database.calendarEventSeries).get();
    final excBefore = await database
        .select(database.calendarEventOccurrenceExceptions)
        .get();
    final eventsBefore = await database.select(database.calendarEvents).get();

    await projector.projectRange(
      from: at(2026, 7, 6),
      through: at(2026, 7, 20, 23),
      mode: RecurringProjectionMode.management,
    );
    await projector.searchSeries(query: '只读');

    final seriesAfter = await database.select(database.calendarEventSeries).get();
    final excAfter = await database
        .select(database.calendarEventOccurrenceExceptions)
        .get();
    final eventsAfter = await database.select(database.calendarEvents).get();
    expect(seriesAfter.length, seriesBefore.length);
    expect(excAfter.length, excBefore.length);
    expect(eventsAfter.length, eventsBefore.length);
    expect(eventsBefore, isEmpty);
  });

  group('bounds', () {
    test('reversed range throws even with no series at all', () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = await serviceFor(database, 'a');
      final projector = RecurringEventProjector(service: service);
      // No series exist in the account. The reversed range must still throw.
      expect(
        projector.projectRange(
          from: at(2026, 7, 10),
          through: at(2026, 7, 6),
          mode: RecurringProjectionMode.display,
        ),
        throwsA(isA<RecurrenceLimitError>()),
      );
    });

    test('reversed range throws RecurrenceLimitError', () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = await serviceFor(database, 'a');
      final projector = RecurringEventProjector(service: service);
      await service.createSeries(
        anchor: PersonalEvent.timed(
          title: 'x',
          startAt: at(2026, 7, 6, 10),
          endAt: at(2026, 7, 6, 11),
        ),
        rule: RecurrenceRule.daily(anchor: at(2026, 7, 6, 10)),
      );
      expect(
        projector.projectRange(
          from: at(2026, 7, 10),
          through: at(2026, 7, 6),
          mode: RecurringProjectionMode.display,
        ),
        throwsA(isA<RecurrenceLimitError>()),
      );
    });

    test('367 inclusive days throw RecurrenceLimitError', () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = await serviceFor(database, 'a');
      final projector = RecurringEventProjector(service: service);
      await service.createSeries(
        anchor: PersonalEvent.timed(
          title: 'x',
          startAt: at(2025, 12, 1, 10),
          endAt: at(2025, 12, 1, 11),
        ),
        rule: RecurrenceRule.daily(anchor: at(2025, 12, 1, 10)),
      );
      expect(
        projector.projectRange(
          from: at(2026, 1, 1),
          through: at(2027, 1, 2),
          mode: RecurringProjectionMode.display,
        ),
        throwsA(isA<RecurrenceLimitError>()),
      );
    });

    test('more than 1000 generated occurrences fail, not partial list', () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = await serviceFor(database, 'a');
      final projector = RecurringEventProjector(service: service);
      // 3 daily series over a full 366-day range = 3*366 = 1098 targets > 1000.
      for (var i = 0; i < 3; i++) {
        await service.createSeries(
          anchor: PersonalEvent.timed(
            title: '海量$i',
            startAt: at(2025, 12, 1, 10),
            endAt: at(2025, 12, 1, 11),
          ),
          rule: RecurrenceRule.daily(anchor: at(2025, 12, 1, 10)),
        );
      }
      expect(
        projector.projectRange(
          from: at(2026, 1, 1),
          through: at(2027, 1, 1),
          mode: RecurringProjectionMode.display,
        ),
        throwsA(isA<RecurrenceLimitError>()),
      );
    });
  });

  group('searchSeries', () {
    test('returns one series per matching title with whole_series scope',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = await serviceFor(database, 'a');
      final projector = RecurringEventProjector(service: service);

      await service.createSeries(
        anchor: PersonalEvent.timed(
          title: '高等数学复习',
          startAt: at(2026, 7, 6, 10),
          endAt: at(2026, 7, 6, 11),
        ),
        rule: RecurrenceRule.weekly(
          anchor: at(2026, 7, 6, 10),
          weekdays: {DateTime.monday},
        ),
      );
      await service.createSeries(
        anchor: PersonalEvent.timed(
          title: '线性代数复习',
          startAt: at(2026, 7, 7, 10),
          endAt: at(2026, 7, 7, 11),
        ),
        rule: RecurrenceRule.weekly(
          anchor: at(2026, 7, 7, 10),
          weekdays: {DateTime.tuesday},
        ),
      );

      final results = await projector.searchSeries(query: '复习');
      expect(results, hasLength(2));
      expect(
        results.map((r) => r.title).toSet(),
        {'高等数学复习', '线性代数复习'},
      );
      for (final r in results) {
        expect(r, isA<ProjectedRecurringSeries>());
        expect(r.isSeries, isTrue);
        expect(r.availableScopes, ['whole_series']);
        expect(r.locator, isA<RecurringSeriesLocator>());
        expect(encodeCalendarEventLocator(r.locator), startsWith('series_v1.'));
      }
    });

    test('search never fabricates an occurrence when no date given', () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = await serviceFor(database, 'a');
      final projector = RecurringEventProjector(service: service);

      await service.createSeries(
        anchor: PersonalEvent.timed(
          title: '每周例会',
          startAt: at(2026, 7, 6, 10),
          endAt: at(2026, 7, 6, 11),
        ),
        rule: RecurrenceRule.weekly(
          anchor: at(2026, 7, 6, 10),
          weekdays: {DateTime.monday},
        ),
      );

      final results = await projector.searchSeries(query: '例会');
      expect(results, hasLength(1));
      final series = results.single;
      // The series target carries no occurrence time / date.
      expect(series.series.allDay, isFalse);
      expect(series.locator, isA<RecurringSeriesLocator>());
      expect((series.locator as RecurringSeriesLocator).seriesId, isNotEmpty);
    });

    test('search respects lifecycleStates for cancelled series', () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = await serviceFor(database, 'a');
      final projector = RecurringEventProjector(service: service);

      final seriesId = await service.createSeries(
        anchor: PersonalEvent.timed(
          title: '已取消系列',
          startAt: at(2026, 7, 6, 10),
          endAt: at(2026, 7, 6, 11),
        ),
        rule: RecurrenceRule.daily(anchor: at(2026, 7, 6, 10)),
      );
      await (database.update(database.calendarEventSeries)
            ..where((row) => row.id.equals(seriesId)))
          .write(
            CalendarEventSeriesCompanion(
              status: const Value('cancelled'),
              updatedAt: Value(200),
            ),
          );

      // An active-only filter excludes the cancelled series.
      final activeOnly = await projector.searchSeries(
        query: '取消',
        lifecycleStates: const {'active'},
      );
      expect(activeOnly, isEmpty);
      // The cancelled filter surfaces it.
      final cancelled = await projector.searchSeries(
        query: '取消',
        lifecycleStates: const {'cancelled'},
      );
      expect(cancelled, hasLength(1));
      expect(cancelled.single.lifecycleState, 'cancelled');
    });
  });
}