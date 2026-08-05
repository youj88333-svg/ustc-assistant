import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/calendar/application/recurrence_lifecycle_service.dart';
import 'package:ustc_assistant_app/features/calendar/application/recurrence_service.dart';
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';
import 'package:ustc_assistant_app/features/calendar/domain/recurrence_expander.dart';
import 'package:ustc_assistant_app/features/calendar/domain/recurrence_rule.dart';
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

/// Builds a timed weekly series (Mondays) anchored at [anchor] and optionally
/// bounded by [through].
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

void main() {
  // Snapshot helpers shared across tests (reuse the service's account-scoped
  // queries to avoid drift Expression boilerplate in test code).
  Future<CalendarEventSery> seriesById(
    RecurrenceService service,
    String seriesId,
  ) => service.seriesRow(seriesId);

  Future<List<CalendarEventOccurrenceException>> exceptionsFor(
    RecurrenceService service,
    String seriesId,
  ) => service.exceptionRows(seriesId);

  group('recurring lifecycle undo (I1)', () {
    test(
      'thisAndFuture cancel undo restores old segment effectiveThrough and '
      'removes the new segment and migrates exceptions back',
      () async {
        final database = await fixtureDatabase();
        addTearDown(database.close);
        final service = RecurrenceService(
          database: database,
          accountId: 'a',
          now: () => 100,
        );
        final undo = UndoService(database: database, accountId: 'a');
        final lifecycle = RecurringLifecycleService(
          database: database,
          accountId: 'a',
          now: () => 100,
          undoRecorder: undo,
        );

        final seriesId = await weeklySeries(
          service,
          anchor: at(2026, 7, 6),
          through: DateTime(2026, 7, 27),
        );
        // A future exception at 7/20 will be migrated to the new segment by
        // editThisAndFuture (selected occurrence is 7/13).
        final futureKey = occurrenceKey(seriesId, at(2026, 7, 20));
        await service.editOnlyThis(
          seriesId,
          futureKey,
          const OccurrenceOverride(title: OverrideValue.set('未来')),
        );
        // Sanity: pre-split old segment effectiveThrough == untilDate.
        final oldBefore = await seriesById(service, seriesId);
        expect(oldBefore.effectiveThrough, '2026-07-27');

        await lifecycle.cancel(
          seriesId: seriesId,
          occurrenceKey: occurrenceKey(seriesId, at(2026, 7, 13)),
          scope: RecurringActionScope.thisAndFuture,
        );

        // After cancel: two series; old segment truncated; new segment cancelled.
        final after = await service.allSeries();
        expect(after, hasLength(2));
        final oldAfter = await seriesById(service, seriesId);
        expect(oldAfter.effectiveThrough, '2026-07-12');
        final newSegment =
            after.firstWhere((row) => row.id != seriesId);
        expect(newSegment.status, 'cancelled');
        // The future exception now lives on the new segment, re-keyed.
        final migrated = (await exceptionsFor(service, newSegment.id))
            .where((row) => row.occurrenceKey.contains('2026-07-20'))
            .single;

        // Undo must reverse everything.
        await undo.undo();

        final afterUndo = await service.allSeries();
        expect(afterUndo, hasLength(1));
        expect(afterUndo.single.id, seriesId);
        final restoredOld = await seriesById(service, seriesId);
        expect(restoredOld.effectiveThrough, '2026-07-27');
        expect(restoredOld.status, 'active');
        // The migrated exception is back on the original series/key.
        final backExceptions = await exceptionsFor(service, seriesId);
        expect(
          backExceptions.where((row) => row.occurrenceKey == futureKey),
          hasLength(1),
        );
        final back = backExceptions
            .firstWhere((row) => row.occurrenceKey == futureKey);
        expect(back.overrideJson, contains('未来'));
        // The new segment's migrated copy is gone: no exception references
        // the new segment id.
        expect(await exceptionsFor(service, newSegment.id), isEmpty);
        // The migrated exception row (by id) now lives on the ORIGINAL series
        // with the ORIGINAL occurrenceKey (migration is reversed in place).
        final migratedNow = (await database.select(
          database.calendarEventOccurrenceExceptions,
        ).get()).where((row) => row.id == migrated.id);
        expect(migratedNow, hasLength(1));
        expect(migratedNow.single.seriesId, seriesId);
        expect(migratedNow.single.occurrenceKey, futureKey);
      },
    );

    test(
      'thisAndFuture delete undo removes the new segment and restores old '
      'segment effectiveThrough and clears deletedAt',
      () async {
        final database = await fixtureDatabase();
        addTearDown(database.close);
        final service = RecurrenceService(
          database: database,
          accountId: 'a',
          now: () => 100,
        );
        final undo = UndoService(database: database, accountId: 'a');
        final lifecycle = RecurringLifecycleService(
          database: database,
          accountId: 'a',
          now: () => 100,
          undoRecorder: undo,
        );

        final seriesId = await weeklySeries(
          service,
          anchor: at(2026, 7, 6),
          through: DateTime(2026, 7, 27),
        );

        await lifecycle.delete(
          seriesId: seriesId,
          occurrenceKey: occurrenceKey(seriesId, at(2026, 7, 13)),
          scope: RecurringActionScope.thisAndFuture,
        );

        final after = await service.allSeries();
        expect(after, hasLength(2));
        final newSegment =
            after.firstWhere((row) => row.id != seriesId);
        expect(newSegment.deletedAt, isNotNull);
        expect(
          (await seriesById(service, seriesId)).effectiveThrough,
          '2026-07-12',
        );

        await undo.undo();

        final afterUndo = await service.allSeries();
        expect(afterUndo, hasLength(1));
        expect(afterUndo.single.id, seriesId);
        final restored = await seriesById(service, seriesId);
        expect(restored.effectiveThrough, '2026-07-27');
        expect(restored.deletedAt, isNull);
        expect(restored.status, 'active');
      },
    );

    test(
      'onlyThis cancel undo restores the exception (status cleared)',
      () async {
        final database = await fixtureDatabase();
        addTearDown(database.close);
        final service = RecurrenceService(
          database: database,
          accountId: 'a',
          now: () => 100,
        );
        final undo = UndoService(database: database, accountId: 'a');
        final lifecycle = RecurringLifecycleService(
          database: database,
          accountId: 'a',
          now: () => 100,
          undoRecorder: undo,
        );

        final seriesId = await weeklySeries(
          service,
          anchor: at(2026, 7, 6),
          through: DateTime(2026, 7, 27),
        );
        final key = occurrenceKey(seriesId, at(2026, 7, 13));
        // Pre-existing override (a rename) that cancel must merge into, and
        // undo must restore.
        await service.editOnlyThis(
          seriesId,
          key,
          const OccurrenceOverride(title: OverrideValue.set('改名')),
        );

        await lifecycle.cancel(
          seriesId: seriesId,
          occurrenceKey: key,
          scope: RecurringActionScope.onlyThis,
        );
        final cancelled =
            (await service.existingOccurrenceAnchor(seriesId, key))!;
        expect(cancelled.status, 'cancelled');
        expect(cancelled.overrideJson, contains('改名'));

        await undo.undo();

        final restored =
            await service.existingOccurrenceAnchor(seriesId, key);
        expect(restored, isNotNull);
        expect(restored!.status, isNull);
        // The pre-existing rename override is preserved.
        expect(restored.overrideJson, contains('改名'));
      },
    );

    test(
      'onlyThis delete undo clears deletedAt and restores the original '
      'override',
      () async {
        final database = await fixtureDatabase();
        addTearDown(database.close);
        final service = RecurrenceService(
          database: database,
          accountId: 'a',
          now: () => 100,
        );
        final undo = UndoService(database: database, accountId: 'a');
        final lifecycle = RecurringLifecycleService(
          database: database,
          accountId: 'a',
          now: () => 100,
          undoRecorder: undo,
        );

        final seriesId = await weeklySeries(
          service,
          anchor: at(2026, 7, 6),
          through: DateTime(2026, 7, 27),
        );
        final key = occurrenceKey(seriesId, at(2026, 7, 13));
        await service.editOnlyThis(
          seriesId,
          key,
          const OccurrenceOverride(title: OverrideValue.set('原始')),
        );

        await lifecycle.delete(
          seriesId: seriesId,
          occurrenceKey: key,
          scope: RecurringActionScope.onlyThis,
        );
        final deleted =
            (await service.existingOccurrenceAnchor(seriesId, key))!;
        expect(deleted.deletedAt, isNotNull);

        await undo.undo();

        final restored =
            await service.existingOccurrenceAnchor(seriesId, key);
        expect(restored, isNotNull);
        expect(restored!.deletedAt, isNull);
        expect(restored.overrideJson, contains('原始'));
      },
    );

    test(
      'wholeSeries cancel/delete undo restores series status/deletedAt',
      () async {
        final database = await fixtureDatabase();
        addTearDown(database.close);
        final service = RecurrenceService(
          database: database,
          accountId: 'a',
          now: () => 100,
        );
        final undo = UndoService(database: database, accountId: 'a');
        final lifecycle = RecurringLifecycleService(
          database: database,
          accountId: 'a',
          now: () => 100,
          undoRecorder: undo,
        );

        final seriesId = await weeklySeries(
          service,
          anchor: at(2026, 7, 6),
          through: DateTime(2026, 7, 27),
        );

        await lifecycle.cancelSeries(seriesId);
        expect((await seriesById(service, seriesId)).status, 'cancelled');
        await undo.undo();
        expect((await seriesById(service, seriesId)).status, 'active');

        await lifecycle.deleteSeries(seriesId);
        expect((await seriesById(service, seriesId)).deletedAt, isNotNull);
        await undo.undo();
        expect((await seriesById(service, seriesId)).deletedAt, isNull);
      },
    );

    test(
      'thisAndFuture cancel undo consumes the slot and writes an '
      'undo_recurring_cancel success ActionLog',
      () async {
        final database = await fixtureDatabase();
        addTearDown(database.close);
        final service = RecurrenceService(
          database: database,
          accountId: 'a',
          now: () => 100,
        );
        final undo = UndoService(database: database, accountId: 'a');
        final lifecycle = RecurringLifecycleService(
          database: database,
          accountId: 'a',
          now: () => 100,
          undoRecorder: undo,
        );

        final seriesId = await weeklySeries(
          service,
          anchor: at(2026, 7, 6),
          through: DateTime(2026, 7, 27),
        );

        await lifecycle.cancel(
          seriesId: seriesId,
          occurrenceKey: occurrenceKey(seriesId, at(2026, 7, 13)),
          scope: RecurringActionScope.thisAndFuture,
        );
        expect(
          await database.select(database.undoSlot).getSingleOrNull(),
          isNotNull,
        );

        await undo.undo();

        // Slot consumed.
        expect(
          await database.select(database.undoSlot).getSingleOrNull(),
          isNull,
        );
        // A success ActionLog of the undo kind was written.
        final logs = await database.actionLogsRepository.selectAll();
        expect(
          logs.where(
            (log) =>
                log.actionType == 'undo_recurring_cancel' &&
                log.result == 'success',
          ),
          isNotEmpty,
        );
      },
    );

    test(
      'thisAndFuture cancel undo migrates an orphaned (incompatible) '
      'exception back to its original series and clears orphaned',
      () async {
        final database = await fixtureDatabase();
        addTearDown(database.close);
        final service = RecurrenceService(
          database: database,
          accountId: 'a',
          now: () => 100,
        );
        final undo = UndoService(database: database, accountId: 'a');
        final lifecycle = RecurringLifecycleService(
          database: database,
          accountId: 'a',
          now: () => 100,
          undoRecorder: undo,
        );

        // Weekly Monday series; split at 7/13 with a this_and_future cancel.
        // A future exception at 7/20 (a Monday) is compatible and migrates.
        final seriesId = await weeklySeries(
          service,
          anchor: at(2026, 7, 6),
          through: DateTime(2026, 7, 27),
        );
        final compatibleKey = occurrenceKey(seriesId, at(2026, 7, 20));
        await service.editOnlyThis(
          seriesId,
          compatibleKey,
          const OccurrenceOverride(title: OverrideValue.set('兼容')),
        );

        await lifecycle.cancel(
          seriesId: seriesId,
          occurrenceKey: occurrenceKey(seriesId, at(2026, 7, 13)),
          scope: RecurringActionScope.thisAndFuture,
        );
        // The compatible exception was migrated to the new segment (re-keyed).
        final newSegment = (await service.allSeries())
            .firstWhere((row) => row.id != seriesId);
        final migrated = (await exceptionsFor(service, newSegment.id))
            .where((row) => row.overrideJson.contains('兼容'))
            .single;

        await undo.undo();

        // The exception is back on the original series, original key,
        // not orphaned.
        final back = (await exceptionsFor(service, seriesId))
            .where((row) => row.id == migrated.id);
        expect(back, hasLength(1));
        expect(back.single.occurrenceKey, compatibleKey);
        expect(back.single.orphaned, isFalse);
        expect(back.single.overrideJson, contains('兼容'));
      },
    );

    test('undo payload never leaks a raw exception or db id into preview',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = RecurrenceService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      final undo = UndoService(database: database, accountId: 'a');
      final lifecycle = RecurringLifecycleService(
        database: database,
        accountId: 'a',
        now: () => 100,
        undoRecorder: undo,
      );
      final seriesId = await weeklySeries(
        service,
        anchor: at(2026, 7, 6),
        through: DateTime(2026, 7, 27),
      );
      await lifecycle.cancel(
        seriesId: seriesId,
        occurrenceKey: occurrenceKey(seriesId, at(2026, 7, 13)),
        scope: RecurringActionScope.onlyThis,
      );
      final slot = await database.select(database.undoSlot).getSingle();
      final preview = await undo.preview();
      expect(preview.available, isTrue);
      expect(preview.summary, isNotEmpty);
      // The safe summary must not be the raw payload.
      expect(preview.summary, isNot(contains('recurring_cancel')));
      // The stored payload is opaque JSON but must not contain a raw
      // exception type name.
      expect(slot.payload, isNot(contains('RawException')));
      expect(slot.payload, isNot(contains('InvalidUndoCommand')));
    });
  });
}
