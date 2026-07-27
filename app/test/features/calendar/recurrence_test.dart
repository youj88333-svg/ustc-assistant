import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/calendar/application/recurrence_service.dart';
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';
import 'package:ustc_assistant_app/features/calendar/domain/recurrence_expander.dart';
import 'package:ustc_assistant_app/features/calendar/domain/recurrence_rule.dart';
import 'package:ustc_assistant_app/features/calendar/presentation/recurrence_editor.dart';

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

void main() {
  test('monthly day 31 clamps and returns to original anchor', () {
    final dates = expandRecurrence(
      RecurrenceRule.monthly(anchor: at(2026, 1, 31)),
      from: at(2026, 1, 1),
      through: at(2026, 3, 31, 23),
    );
    expect(dates, [at(2026, 1, 31), at(2026, 2, 28), at(2026, 3, 31)]);
  });

  test('daily interval and inclusive until date are honored', () {
    final dates = expandRecurrence(
      RecurrenceRule.daily(
        anchor: at(2026, 7, 1),
        interval: 2,
        untilDate: DateTime(2026, 7, 5),
      ),
      from: at(2026, 7, 1),
      through: at(2026, 7, 10),
    );
    expect(dates, [at(2026, 7, 1), at(2026, 7, 3), at(2026, 7, 5)]);
  });

  test('weekly recurrence supports multiple weekdays and interval', () {
    final dates = expandRecurrence(
      RecurrenceRule.weekly(
        anchor: at(2026, 7, 6),
        weekdays: {DateTime.monday, DateTime.thursday},
        interval: 2,
      ),
      from: at(2026, 7, 6),
      through: at(2026, 7, 23, 23),
    );
    expect(dates, [
      at(2026, 7, 6),
      at(2026, 7, 9),
      at(2026, 7, 20),
      at(2026, 7, 23),
    ]);
  });

  test('expansion is bounded to 366 days', () {
    expect(
      () => expandRecurrence(
        RecurrenceRule.daily(anchor: at(2026, 1, 1)),
        from: at(2026, 1, 1),
        through: at(2027, 1, 3),
      ),
      throwsA(isA<RecurrenceLimitError>()),
    );
  });

  test('occurrence identity is deterministic', () {
    expect(
      occurrenceKey('series', at(2026, 7, 6, 20)),
      occurrenceKey('series', at(2026, 7, 6, 20)),
    );
    expect(
      occurrenceKey('series', at(2026, 7, 6, 20)),
      isNot(occurrenceKey('series', at(2026, 7, 13, 20))),
    );
  });

  test(
    'moving one occurrence keeps its key and explicit null override',
    () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = RecurrenceService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      final seriesId = await service.createSeries(
        anchor: PersonalEvent.timed(
          title: '晚自习',
          startAt: at(2026, 7, 6, 20),
          endAt: at(2026, 7, 6, 22),
          locationName: '图书馆',
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
        OccurrenceOverride(
          startAt: OverrideValue.set(at(2026, 7, 13, 19)),
          locationName: const OverrideValue.set(null),
        ),
      );

      final occurrence = await service.occurrence(seriesId, key);
      expect(occurrence.occurrenceKey, key);
      expect(occurrence.startAt, at(2026, 7, 13, 19));
      expect(occurrence.locationName, isNull);
      expect(occurrence.overriddenFields, contains('locationName'));
    },
  );

  test('this-and-future split migrates compatible future exceptions', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = RecurrenceService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );
    final seriesId = await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '每周安排',
        startAt: at(2026, 7, 6),
        endAt: at(2026, 7, 6, 10),
      ),
      rule: RecurrenceRule.weekly(
        anchor: at(2026, 7, 6),
        weekdays: {DateTime.monday},
      ),
    );
    final futureKey = occurrenceKey(seriesId, at(2026, 7, 20));
    await service.editOnlyThis(
      seriesId,
      futureKey,
      const OccurrenceOverride(title: OverrideValue.set('未来例外')),
    );

    final newSeriesId = await service.editThisAndFuture(
      seriesId,
      occurrenceKey(seriesId, at(2026, 7, 13)),
      anchor: PersonalEvent.timed(
        title: '调整后安排',
        startAt: at(2026, 7, 13),
        endAt: at(2026, 7, 13, 10),
      ),
      rule: RecurrenceRule.weekly(
        anchor: at(2026, 7, 13),
        weekdays: {DateTime.monday},
      ),
    );

    final oldSeries = await service.seriesRow(seriesId);
    expect(oldSeries.effectiveThrough, '2026-07-12');
    final migrated = await service.occurrence(
      newSeriesId,
      occurrenceKey(newSeriesId, at(2026, 7, 20)),
    );
    expect(migrated.title, '未来例外');
  });

  test('whole-series edit retains but orphans removed positions', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = RecurrenceService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );
    final seriesId = await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '每周一',
        startAt: at(2026, 7, 6),
        endAt: at(2026, 7, 6, 10),
      ),
      rule: RecurrenceRule.weekly(
        anchor: at(2026, 7, 6),
        weekdays: {DateTime.monday},
      ),
    );
    final key = occurrenceKey(seriesId, at(2026, 7, 13));
    await service.editOnlyThis(
      seriesId,
      key,
      const OccurrenceOverride(title: OverrideValue.set('保留历史')),
    );

    final impact = await service.editWholeSeries(
      seriesId,
      anchor: PersonalEvent.timed(
        title: '改为每周二',
        startAt: at(2026, 7, 7),
        endAt: at(2026, 7, 7, 10),
      ),
      rule: RecurrenceRule.weekly(
        anchor: at(2026, 7, 7),
        weekdays: {DateTime.tuesday},
      ),
    );

    expect(impact.newlyOrphaned, 1);
    final exceptions = await service.exceptionRows(seriesId);
    expect(exceptions.single.orphaned, isTrue);
    expect(
      service.occurrence(seriesId, key),
      throwsA(isA<OccurrenceNotFoundError>()),
    );
  });

  test('failed split rolls back old series boundary', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = RecurrenceService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );
    final seriesId = await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '系列',
        startAt: at(2026, 7, 6),
        endAt: at(2026, 7, 6, 10),
      ),
      rule: RecurrenceRule.daily(anchor: at(2026, 7, 6)),
    );

    expect(
      service.editThisAndFuture(
        seriesId,
        'missing-key',
        anchor: PersonalEvent.timed(
          title: '无效',
          startAt: at(2026, 7, 10),
          endAt: at(2026, 7, 10, 10),
        ),
        rule: RecurrenceRule.daily(anchor: at(2026, 7, 10)),
      ),
      throwsA(isA<OccurrenceNotFoundError>()),
    );
    expect((await service.seriesRow(seriesId)).effectiveThrough, isNull);
  });

  test('all-day recurrence keeps exclusive date duration', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = RecurrenceService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );
    final seriesId = await service.createSeries(
      anchor: PersonalEvent.allDay(
        title: '全天系列',
        startDate: DateTime(2026, 7, 6),
        endDateExclusive: DateTime(2026, 7, 8),
      ),
      rule: RecurrenceRule.weekly(
        anchor: DateTime(2026, 7, 6),
        weekdays: {DateTime.monday},
      ),
    );

    final values = await service.occurrences(
      seriesId,
      from: DateTime(2026, 7, 6),
      through: DateTime(2026, 7, 13, 23),
    );
    expect(values, hasLength(2));
    expect(values.last.endDateExclusive, DateTime(2026, 7, 15));
  });

  testWidgets('recurrence editor emits weekly multi-day rules', (tester) async {
    RecurrenceRule? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecurrenceEditor(
            anchor: at(2026, 7, 6),
            onChanged: (value) => changed = value,
          ),
        ),
      ),
    );

    await tester.tap(find.text('每周'));
    await tester.pump();
    await tester.tap(find.text('三'));
    await tester.pump();
    expect(changed?.frequency, RecurrenceFrequency.weekly);
    expect(changed?.weekdays, {DateTime.monday, DateTime.wednesday});
  });
}
