import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/calendar/application/recurrence_lifecycle_service.dart';
import 'package:ustc_assistant_app/features/calendar/application/recurrence_service.dart';
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';
import 'package:ustc_assistant_app/features/calendar/domain/recurrence_expander.dart';
import 'package:ustc_assistant_app/features/calendar/domain/recurrence_rule.dart';
import 'package:ustc_assistant_app/features/calendar/presentation/recurrence_editor.dart';
import 'package:ustc_assistant_app/features/tasks/application/undo_service.dart';

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

  test('occurrences() performs no inserts', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = RecurrenceService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );
    final seriesId = await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '每日',
        startAt: at(2026, 7, 6),
        endAt: at(2026, 7, 6, 10),
      ),
      rule: RecurrenceRule.daily(anchor: at(2026, 7, 6)),
    );

    final before = await service.exceptionRows(seriesId);
    final values = await service.occurrences(
      seriesId,
      from: DateTime(2026, 7, 6),
      through: DateTime(2026, 7, 8, 23),
    );
    expect(values, hasLength(3));
    final after = await service.exceptionRows(seriesId);
    expect(after, hasLength(before.length));
  });

  test('ensureOccurrenceAnchor creates an empty override anchor', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = RecurrenceService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );
    final seriesId = await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '早晚',
        startAt: at(2026, 7, 6, 20),
        endAt: at(2026, 7, 6, 22),
      ),
      rule: RecurrenceRule.weekly(
        anchor: at(2026, 7, 6, 20),
        weekdays: {DateTime.monday},
      ),
    );
    final key = occurrenceKey(seriesId, at(2026, 7, 13, 20));

    final anchor = await service.ensureOccurrenceAnchor(seriesId, key);
    expect(anchor.kind, 'override');
    expect(anchor.overriddenFieldsJson, '[]');
    expect(anchor.overrideJson, '{}');
    expect(anchor.originalStartAt, at(2026, 7, 13, 20).millisecondsSinceEpoch);
    expect(anchor.originalStartDate, isNull);
    expect(anchor.deletedAt, isNull);
  });

  test('ensureOccurrenceAnchor is idempotent', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = RecurrenceService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );
    final seriesId = await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '每日',
        startAt: at(2026, 7, 6),
        endAt: at(2026, 7, 6, 10),
      ),
      rule: RecurrenceRule.daily(anchor: at(2026, 7, 6)),
    );
    final key = occurrenceKey(seriesId, at(2026, 7, 7));

    final first = await service.ensureOccurrenceAnchor(seriesId, key);
    final second = await service.ensureOccurrenceAnchor(seriesId, key);
    expect(second.id, first.id);
    expect(await service.exceptionRows(seriesId), hasLength(1));
  });

  test('anchor for unknown series, wrong account, bad key, and out-of-rule key fails without writes',
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
    final rowsBefore = await database
        .select(database.calendarEventOccurrenceExceptions)
        .get();

    await expectLater(
      service.ensureOccurrenceAnchor('no-such-series', 'no-such-series@2026-07-07T09:00:00.000'),
      throwsA(isA<OccurrenceNotFoundError>()),
    );
    // A service bound to a different account must not see account 'a''s series.
    final otherService = RecurrenceService(
      database: database,
      accountId: 'b',
      now: () => 100,
    );
    await expectLater(
      otherService.ensureOccurrenceAnchor(
        seriesId,
        occurrenceKey(seriesId, at(2026, 7, 13)),
      ),
      throwsA(isA<OccurrenceNotFoundError>()),
    );
    await expectLater(
      service.ensureOccurrenceAnchor(seriesId, 'malformed-key'),
      throwsA(isA<OccurrenceNotFoundError>()),
    );
    await expectLater(
      service.ensureOccurrenceAnchor(
        seriesId,
        occurrenceKey(seriesId, at(2026, 7, 8)),
      ),
      throwsA(isA<OccurrenceNotFoundError>()),
    );

    final rowsAfter = await database
        .select(database.calendarEventOccurrenceExceptions)
        .get();
    expect(rowsAfter, hasLength(rowsBefore.length));
  });

  test('existing real override is returned unchanged by anchor', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = RecurrenceService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );
    final seriesId = await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '会',
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
      OccurrenceOverride(
        title: const OverrideValue.set('真实例外'),
        startAt: OverrideValue.set(at(2026, 7, 13, 11)),
      ),
    );

    final anchor = await service.ensureOccurrenceAnchor(seriesId, key);
    final exception = (await service.exceptionRows(seriesId)).single;
    expect(anchor.id, exception.id);
    expect(exception.overrideJson.contains('真实例外'), isTrue);
    expect(exception.overriddenFieldsJson, contains('title'));
  });

  test('timed series defaults reminder offsets to [15] and all-day to []', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = RecurrenceService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );
    final timedId = await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '定时',
        startAt: at(2026, 7, 6),
        endAt: at(2026, 7, 6, 10),
      ),
      rule: RecurrenceRule.daily(anchor: at(2026, 7, 6)),
    );
    final allDayId = await service.createSeries(
      anchor: PersonalEvent.allDay(
        title: '全天',
        startDate: DateTime(2026, 7, 6),
        endDateExclusive: DateTime(2026, 7, 7),
      ),
      rule: RecurrenceRule.daily(anchor: DateTime(2026, 7, 6)),
    );
    expect((await service.seriesRow(timedId)).reminderOffsetsJson, '[15]');
    expect((await service.seriesRow(allDayId)).reminderOffsetsJson, '[]');
  });

  test('custom reminder offsets are persisted on the series', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = RecurrenceService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );
    final seriesId = await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '定时',
        startAt: at(2026, 7, 6),
        endAt: at(2026, 7, 6, 10),
      ),
      rule: RecurrenceRule.daily(anchor: at(2026, 7, 6)),
      reminderOffsetsMinutes: [5, 15],
    );
    final rec = await service.occurrence(
      seriesId,
      occurrenceKey(seriesId, at(2026, 7, 7)),
    );
    expect(rec.reminderOffsetsMinutes, [5, 15]);
  });

  test('occurrence override can replace reminder offsets including empty list', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = RecurrenceService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );
    final seriesId = await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '定时',
        startAt: at(2026, 7, 6),
        endAt: at(2026, 7, 6, 10),
      ),
      rule: RecurrenceRule.daily(anchor: at(2026, 7, 6)),
    );
    final key = occurrenceKey(seriesId, at(2026, 7, 7));
    await service.editOnlyThis(
      seriesId,
      key,
      const OccurrenceOverride(
        reminderOffsetsMinutes: OverrideValue.set([]),
      ),
    );
    final rec = await service.occurrence(seriesId, key);
    expect(rec.reminderOffsetsMinutes, isEmpty);
  });

  test('override with invalid reminder offsets is rejected without writes', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = RecurrenceService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );
    final seriesId = await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '定时',
        startAt: at(2026, 7, 6),
        endAt: at(2026, 7, 6, 10),
      ),
      rule: RecurrenceRule.daily(anchor: at(2026, 7, 6)),
    );
    final key = occurrenceKey(seriesId, at(2026, 7, 7));

    await expectLater(
      service.editOnlyThis(
        seriesId,
        key,
        const OccurrenceOverride(
          reminderOffsetsMinutes: OverrideValue.set([-5, 5, 5]),
        ),
      ),
      throwsA(isA<RecurrenceValidationError>()),
    );
    expect(await service.exceptionRows(seriesId), isEmpty);
  });

  test('override normalizes valid unsorted unique reminder offsets', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = RecurrenceService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );
    final seriesId = await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '定时',
        startAt: at(2026, 7, 6),
        endAt: at(2026, 7, 6, 10),
      ),
      rule: RecurrenceRule.daily(anchor: at(2026, 7, 6)),
    );
    final key = occurrenceKey(seriesId, at(2026, 7, 7));
    await service.editOnlyThis(
      seriesId,
      key,
      const OccurrenceOverride(
        reminderOffsetsMinutes: OverrideValue.set([30, 5]),
      ),
    );
    final rec = await service.occurrence(seriesId, key);
    expect(rec.reminderOffsetsMinutes, [5, 30]);
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

  group('recurring lifecycle (three scopes)', () {
    RecurringLifecycleService lifecycle(AppDatabase database) =>
        RecurringLifecycleService(
          database: database,
          accountId: 'a',
          now: () => 100,
        );

    Future<String> weeklySeries(
      RecurrenceService service, {
      required DateTime anchor,
      DateTime? through,
    }) => service.createSeries(
      anchor: PersonalEvent.timed(
        title: '例会',
        startAt: anchor,
        endAt: anchor.add(const Duration(hours: 1)),
      ),
      rule: RecurrenceRule.weekly(
        anchor: anchor,
        weekdays: {anchor.weekday},
        untilDate: through,
      ),
    );

    test('unscoped infinite repeat action surface scope_required via preview',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = RecurrenceService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      final seriesId =
          await weeklySeries(service, anchor: at(2026, 7, 6)); // infinite
      final key = occurrenceKey(seriesId, at(2026, 7, 13));

      final preview = await lifecycle(database).previewImpact(
        seriesId: seriesId,
        occurrenceKey: key,
        action: RecurringLifecycleAction.delete,
      );
      expect(preview.requiresScope, isTrue);
      expect(preview.scopeRequired, isTrue);

      final scoped = await lifecycle(database).previewImpact(
        seriesId: seriesId,
        occurrenceKey: key,
        scope: RecurringActionScope.onlyThis,
        action: RecurringLifecycleAction.delete,
      );
      expect(scoped.scopeRequired, isFalse);
    });

    test('preview of an infinite weekly series marks infinite and over366',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = RecurrenceService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      final seriesId =
          await weeklySeries(service, anchor: at(2026, 7, 6)); // infinite
      final key = occurrenceKey(seriesId, at(2026, 7, 13));

      // scope_required must be surfaced for an unscoped delete/restore.
      final ambiguous = await lifecycle(database).previewImpact(
        seriesId: seriesId,
        occurrenceKey: key,
        action: RecurringLifecycleAction.delete,
      );
      expect(ambiguous.scopeRequired, isTrue);
      expect(ambiguous.requiresScope, isTrue);

      final scoped = await lifecycle(database).previewImpact(
        seriesId: seriesId,
        occurrenceKey: key,
        scope: RecurringActionScope.thisAndFuture,
        action: RecurringLifecycleAction.delete,
      );
      expect(scoped.infinite, isTrue);
      expect(scoped.over366Days, isTrue);
      expect(scoped.availableScopes, [
        'only_this',
        'this_and_future',
        'whole_series',
      ]);
    });

    test('only_this cancel writes a status override and reopen reverts it',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = RecurrenceService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      final seriesId =
          await weeklySeries(
            service,
            anchor: at(2026, 7, 6),
            through: DateTime(2026, 7, 27),
          );
      final key = occurrenceKey(seriesId, at(2026, 7, 13));

      await lifecycle(database).cancel(
        seriesId: seriesId,
        occurrenceKey: key,
        scope: RecurringActionScope.onlyThis,
      );

      final occurrence = await service.occurrence(seriesId, key);
      expect(occurrence.status, EventStatus.cancelled);
      final exception = await service.existingOccurrenceAnchor(seriesId, key);
      expect(exception!.status, 'cancelled');
      expect(exception.deletedAt, isNull);

      // Reopen restores the series' own status.
      await lifecycle(database).reopen(
        seriesId: seriesId,
        occurrenceKey: key,
        scope: RecurringActionScope.onlyThis,
      );
      final reopened = await service.occurrence(seriesId, key);
      expect(reopened.status, EventStatus.active);
      // Reopen reverted the cancel by removing the status-only override row.
      final after = await service.existingOccurrenceAnchor(seriesId, key);
      expect(after, isNull);
    });

    test('only_this delete creates a tombstone and restore clears it', () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = RecurrenceService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      final seriesId =
          await weeklySeries(
            service,
            anchor: at(2026, 7, 6),
            through: DateTime(2026, 7, 27),
          );
      final key = occurrenceKey(seriesId, at(2026, 7, 13));

      await lifecycle(database).delete(
        seriesId: seriesId,
        occurrenceKey: key,
        scope: RecurringActionScope.onlyThis,
      );

      final exception = await service.existingOccurrenceAnchor(seriesId, key);
      expect(exception, isNotNull);
      expect(exception!.deletedAt, isNotNull);

      await lifecycle(database).restore(
        seriesId: seriesId,
        occurrenceKey: key,
        scope: RecurringActionScope.onlyThis,
      );
      final restored = await service.existingOccurrenceAnchor(seriesId, key);
      expect(restored!.deletedAt, isNull);
    });

    test('only_this delete on a real override keeps the override and sets deletedAt',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = RecurrenceService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      final seriesId =
          await weeklySeries(
            service,
            anchor: at(2026, 7, 6),
            through: DateTime(2026, 7, 27),
          );
      final key = occurrenceKey(seriesId, at(2026, 7, 13));
      await service.editOnlyThis(
        seriesId,
        key,
        const OccurrenceOverride(title: OverrideValue.set('改名')),
      );

      await lifecycle(database).delete(
        seriesId: seriesId,
        occurrenceKey: key,
        scope: RecurringActionScope.onlyThis,
      );
      final exception = await service.existingOccurrenceAnchor(seriesId, key);
      expect(exception!.deletedAt, isNotNull);
      expect(exception.overrideJson.contains('改名'), isTrue);
    });

    test('whole_series cancel/deactivate/restore never materializes occurrences',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = RecurrenceService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      final seriesId =
          await weeklySeries(
            service,
            anchor: at(2026, 7, 6),
            through: DateTime(2026, 7, 27),
          );
      final before = await database
          .select(database.calendarEvents)
          .get();

      await lifecycle(database).cancelSeries(seriesId);
      expect((await service.seriesRow(seriesId)).status, 'cancelled');
      expect((await service.seriesRow(seriesId)).deletedAt, isNull);

      await lifecycle(database).reopenSeries(seriesId);
      expect((await service.seriesRow(seriesId)).status, 'active');
      final after = await database.select(database.calendarEvents).get();
      expect(after, hasLength(before.length));
    });

    test('whole_series delete sets deletedAt and restore clears it', () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = RecurrenceService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      final seriesId =
          await weeklySeries(
            service,
            anchor: at(2026, 7, 6),
            through: DateTime(2026, 7, 27),
          );

      await lifecycle(database).deleteSeries(seriesId);
      expect((await service.seriesRow(seriesId)).deletedAt, 100);

      await lifecycle(database).restoreSeries(seriesId);
      expect((await service.seriesRow(seriesId)).deletedAt, isNull);
    });

    test('this_and_future delete splits, hits the new segment, keeps history',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = RecurrenceService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      final seriesId = await weeklySeries(
        service,
        anchor: at(2026, 7, 6),
        through: DateTime(2026, 7, 27),
      );
      // A history-only exception before the split stays on the old segment.
      final beforeKey = occurrenceKey(seriesId, at(2026, 7, 6));
      await service.editOnlyThis(
        seriesId,
        beforeKey,
        const OccurrenceOverride(title: OverrideValue.set('历史')),
      );

      await lifecycle(database).delete(
        seriesId: seriesId,
        occurrenceKey: occurrenceKey(seriesId, at(2026, 7, 13)),
        scope: RecurringActionScope.thisAndFuture,
      );

      // The old segment no longer contains the deleted future occurrence.
      final oldSeries = await service.seriesRow(seriesId);
      expect(oldSeries.effectiveThrough, '2026-07-12');
      final oldException = await service.existingOccurrenceAnchor(
        seriesId,
        occurrenceKey(seriesId, at(2026, 7, 6)),
      );
      expect(oldException!.overrideJson.contains('历史'), isTrue);
      expect(oldException.deletedAt, isNull);

      // A NEW segment exists and is soft-deleted.
      final allSeries = await service.allSeries();
      expect(allSeries, hasLength(2));
      final newSeries = allSeries.firstWhere((row) => row.deletedAt != null);
      expect(newSeries.deletedAt, isNotNull);
      expect(newSeries.id, isNot(seriesId));
    });

    test('this_and_future cancel + reopen acts only on the new segment', () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = RecurrenceService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      final seriesId = await weeklySeries(
        service,
        anchor: at(2026, 7, 6),
        through: DateTime(2026, 7, 27),
      );

      await lifecycle(database).cancel(
        seriesId: seriesId,
        occurrenceKey: occurrenceKey(seriesId, at(2026, 7, 13)),
        scope: RecurringActionScope.thisAndFuture,
      );
      final cancelled = await service.allSeries();
      expect(cancelled, hasLength(2));
      final cancelledNew =
          cancelled.firstWhere((row) => row.id != seriesId);
      expect(cancelledNew.status, 'cancelled');
      // Old segment untouched.
      expect((await service.seriesRow(seriesId)).status, 'active');

      // Reopen must target the NEW segment that owns the 7/13 occurrence after
// the split (the original series was truncated to end 7/12).
final reopenedSeriesId = cancelledNew.id;
      await lifecycle(database).reopen(
        seriesId: reopenedSeriesId,
        occurrenceKey: occurrenceKey(reopenedSeriesId, at(2026, 7, 13)),
        scope: RecurringActionScope.thisAndFuture,
      );
      final afterReopen = await service.allSeries();
      expect(afterReopen, hasLength(2));
      final reopenedNew =
          afterReopen.firstWhere((row) => row.id == reopenedSeriesId);
      expect(reopenedNew.status, 'active');
      expect((await service.seriesRow(seriesId)).status, 'active');
    });

    test('finite series beyond the 366-day horizon is flagged', () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = RecurrenceService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      // Weekly for ~2 years -> untilDate well beyond a 366-day horizon.
      final seriesId = await service.createSeries(
        anchor: PersonalEvent.timed(
          title: '长线例会',
          startAt: at(2026, 7, 6),
          endAt: at(2026, 7, 6, 10),
        ),
        rule: RecurrenceRule.weekly(
          anchor: at(2026, 7, 6),
          weekdays: {DateTime.monday},
          untilDate: DateTime(2028, 7, 31),
        ),
      );
      final key = occurrenceKey(seriesId, at(2026, 7, 13));

      final preview = await lifecycle(database).previewImpact(
        seriesId: seriesId,
        occurrenceKey: key,
        scope: RecurringActionScope.thisAndFuture,
        action: RecurringLifecycleAction.delete,
      );
      expect(preview.infinite, isFalse);
      expect(preview.over366Days, isTrue);
      expect(preview.requiresScope, isTrue);
      expect(preview.availableScopes, [
        'only_this',
        'this_and_future',
        'whole_series',
      ]);
    });

    test('version recheck rejects a stale series', () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = RecurrenceService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      final seriesId =
          await weeklySeries(
            service,
            anchor: at(2026, 7, 6),
            through: DateTime(2026, 7, 27),
          );
      final key = occurrenceKey(seriesId, at(2026, 7, 13));
      final series = await service.seriesRow(seriesId);

      await expectLater(
        lifecycle(database).delete(
          seriesId: seriesId,
          occurrenceKey: key,
          scope: RecurringActionScope.onlyThis,
          expectedSeriesUpdatedAt: series.updatedAt - 1,
        ),
        throwsA(isA<StaleRecurringTarget>()),
      );
    });

    test('lifecycle action records an Undo snapshot in the same transaction',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = RecurrenceService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      final seriesId = await weeklySeries(
        service,
        anchor: at(2026, 7, 6),
        through: DateTime(2026, 7, 27),
      );
      final key = occurrenceKey(seriesId, at(2026, 7, 13));

      // Use a real UndoService so the lifecycle's undoRecorder writes the slot
      // inside the same Drift transaction as the mutation.
      final undo = UndoService(database: database, accountId: 'a');
      final lifecycle = RecurringLifecycleService(
        database: database,
        accountId: 'a',
        now: () => 100,
        undoRecorder: undo,
      );

      await lifecycle.cancel(
        seriesId: seriesId,
        occurrenceKey: key,
        scope: RecurringActionScope.onlyThis,
      );

      final slot = await database.select(database.undoSlot).getSingle();
      expect(slot.payload, contains('recurring_cancel'));
      expect(slot.payload, isNot(contains('RawException')));
    });

    test('a wrong account cannot act on another account series', () async {
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
      final service = RecurrenceService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      final seriesId =
          await weeklySeries(
            service,
            anchor: at(2026, 7, 6),
            through: DateTime(2026, 7, 27),
          );
      final key = occurrenceKey(seriesId, at(2026, 7, 13));

      final other = RecurringLifecycleService(
        database: database,
        accountId: 'b',
        now: () => 100,
      );
      await expectLater(
        other.delete(
          seriesId: seriesId,
          occurrenceKey: key,
          scope: RecurringActionScope.onlyThis,
        ),
        throwsA(isA<OccurrenceNotFoundError>()),
      );
      final exception = await service.existingOccurrenceAnchor(seriesId, key);
      expect(exception, isNull);
    });
  });
}
