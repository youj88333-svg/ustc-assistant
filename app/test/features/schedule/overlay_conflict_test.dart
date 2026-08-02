import 'dart:async';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/schedule/application/conflict_service.dart';
import 'package:ustc_assistant_app/features/schedule/application/effective_event_repository.dart';
import 'package:ustc_assistant_app/features/schedule/application/overlay_service.dart';
import 'package:ustc_assistant_app/features/schedule/application/schedule_conflict_projection.dart';
import 'package:ustc_assistant_app/features/schedule/domain/overlap_engine.dart';
import 'package:ustc_assistant_app/features/schedule/domain/schedule_grid_item.dart';
import 'package:ustc_assistant_app/features/schedule/presentation/conflict_editor.dart';
import 'package:ustc_assistant_app/features/tasks/application/undo_service.dart';
import 'package:ustc_assistant_app/features/tasks/domain/plan_block.dart';
import 'package:ustc_assistant_app/features/tasks/domain/task.dart';

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
  await database
      .into(database.courseSeries)
      .insert(
        CourseSeriesCompanion.insert(
          id: 'series-a',
          accountId: 'a',
          source: 'ustc_jw',
          externalId: 'lesson-a',
          title: '电路基本理论',
          semesterKey: '2026fall',
          sourceDetailsJson: '{}',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
  await database
      .into(database.courseSeries)
      .insert(
        CourseSeriesCompanion.insert(
          id: 'series-b',
          accountId: 'a',
          source: 'ustc_jw',
          externalId: 'lesson-b',
          title: '量子物理 B',
          semesterKey: '2026fall',
          sourceDetailsJson: '{}',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
  await _insertEvent(database, 'event-a', 'lesson-a', 10);
  await _insertEvent(database, 'event-a-next', 'lesson-a', 17);
  await _insertEvent(database, 'event-b', 'lesson-b', 10);
  return database;
}

Future<void> _insertEvent(
  AppDatabase database,
  String id,
  String seriesExternalId,
  int day,
) => database
    .into(database.calendarEvents)
    .insert(
      CalendarEventsCompanion.insert(
        id: id,
        accountId: 'a',
        source: 'ustc_jw',
        externalId: Value(id),
        sourceSeriesExternalId: Value(seriesExternalId),
        title: id,
        type: 'course',
        startAt: Value(DateTime(2026, 8, day, 9, 45).millisecondsSinceEpoch),
        endAt: Value(DateTime(2026, 8, day, 11, 20).millisecondsSinceEpoch),
        allDay: false,
        timezone: 'Asia/Shanghai',
        importance: const Value('normal'),
        createdAt: 1,
        updatedAt: 1,
      ),
    );

ScheduleConflictParticipant participant(
  String eventId,
  String seriesId, {
  DateTime? finiteSeriesEnd,
}) => ScheduleConflictParticipant(
  kind: 'event',
  id: eventId,
  title: eventId,
  occurrenceDate: DateTime(2026, 8, 10),
  seriesType: 'course_series',
  seriesId: seriesId,
  finiteSeriesEnd: finiteSeriesEnd,
);

/// An event-mode participant without any series identity (single instance).
ScheduleConflictParticipant eventParticipant(
  String eventId, {
  DateTime? occurrenceDate,
}) => ScheduleConflictParticipant(
  kind: 'event',
  id: eventId,
  title: eventId,
  occurrenceDate: occurrenceDate ?? DateTime(2026, 8, 10),
);

/// A plan-block participant with the given kind (invariant: no fake series).
ScheduleConflictParticipant planBlockParticipant(
  String blockId, {
  String? title,
  DateTime? occurrenceDate,
}) => ScheduleConflictParticipant(
  kind: 'plan_block',
  id: blockId,
  title: title ?? blockId,
  occurrenceDate: occurrenceDate ?? DateTime(2026, 8, 10),
);

/// A timed [ScheduleGridItem] event for the conflict-projection tests.
ScheduleGridItem eventItem(
  String id,
  DateTime start,
  DateTime end, {
  String? seriesId,
}) => ScheduleGridItem.fromEvent(
  EffectiveEvent.timed(
    id: id,
    title: id,
    startAt: start,
    endAt: end,
    courseSeriesId: seriesId,
  ),
);

/// An all-day [ScheduleGridItem] event for the conflict-projection tests.
ScheduleGridItem allDayItem(
  String id,
  DateTime startDate,
  DateTime endDateExclusive,
) => ScheduleGridItem.fromEvent(
  EffectiveEvent.allDay(
    id: id,
    title: id,
    startDate: startDate,
    endDateExclusive: endDateExclusive,
  ),
);

/// An approved plan-block grid item for the conflict-projection tests.
ScheduleGridItem planBlockItem(
  String id,
  String taskId,
  DateTime start,
  DateTime end,
) => ScheduleGridItem.fromPlanBlock(
  PlanBlockItem(
    id: id,
    taskId: taskId,
    startAt: start,
    endAt: end,
    status: PlanBlockStatus.accepted,
    locked: false,
    createdAt: 1,
    updatedAt: 1,
  ),
  TaskItem(
    id: taskId,
    title: taskId,
    state: TaskState.active,
    importance: TaskImportance.normal,
    createdAt: 1,
    updatedAt: 1,
  ),
);

void main() {
  test('effective event stream emits imports and overlay changes', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final repository = EffectiveEventRepository(database, accountId: 'a');
    final iterator = StreamIterator(repository.watchAll());
    addTearDown(iterator.cancel);

    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current, hasLength(3));
    await OverlayService(
      database: database,
      accountId: 'a',
      now: () => 100,
    ).setEventAttendance('event-a', AttendancePolicy.mustGo);
    expect(await iterator.moveNext(), isTrue);
    expect(
      iterator.current
          .singleWhere((record) => record.source.id == 'event-a')
          .attendance,
      AttendancePolicy.mustGo,
    );
  });

  test('event overlay wins over series and source defaults', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final overlays = OverlayService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );
    final repository = EffectiveEventRepository(database, accountId: 'a');

    await overlays.setSeriesAttendance('series-a', AttendancePolicy.skip);
    await overlays.setEventAttendance('event-a', AttendancePolicy.mustGo);

    expect(
      (await repository.byId('event-a')).attendance,
      AttendancePolicy.mustGo,
    );
    expect(
      (await repository.byId('event-a-next')).attendance,
      AttendancePolicy.skip,
    );
  });

  test('overlapping records exclude missing source events', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    for (final eventId in ['event-a', 'event-b']) {
      await database
          .into(database.sourceRecords)
          .insert(
            SourceRecordsCompanion.insert(
              id: 'source-$eventId',
              accountId: 'a',
              source: 'ustc_jw',
              entityType: 'calendar_event',
              externalId: eventId,
              localEntityId: eventId,
              sourceStatus: 'active',
              presence: eventId == 'event-b'
                  ? 'missing_within_scope'
                  : 'observed',
              scopeKey: 'semester',
              firstObservedAt: 1,
              lastObservedAt: 1,
            ),
          );
    }

    final records = await EffectiveEventRepository(
      database,
      accountId: 'a',
    ).overlappingRecords('event-a');

    expect(records.map((record) => record.source.id), ['event-a']);
  });

  test('attendance decisions remain occurrence-specific', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final overlays = OverlayService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );
    final repository = EffectiveEventRepository(database, accountId: 'a');

    await overlays.recordAttendanceDecision('event-a', AttendanceDecision.skip);

    expect(
      (await repository.byId('event-a')).attendanceDecision,
      AttendanceDecision.skip,
    );
    expect(
      (await repository.byId('event-a-next')).attendanceDecision,
      AttendanceDecision.undecided,
    );
  });

  test('overlay logs redact user notes', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final overlays = OverlayService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );

    await overlays.setEventOverlay(
      'event-a',
      const OverlayMutation(userNotes: '这是一条不应进入日志的私密备注'),
    );

    final log = (await database.actionLogsRepository.selectAll()).single;
    expect(log.safeSummary, isNot(contains('私密备注')));
    expect(log.safeSummary, 'Updated event preferences.');
  });

  test('timed overlap defaults to conflict and explicit relation overrides',
      () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = ConflictService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );
    final a = participant('event-a', 'series-a');
    final b = participant('event-b', 'series-b');

    // event-a and event-b occupy the same timed slot → derived conflict by
    // default (no explicit row required).
    expect(await service.stateForPair(a, b), ConflictState.conflict);
    await service.classifyPair(a, b, ConflictState.nonConflict);
    expect(await service.showConflictWarning(a, b), isFalse);
    await service.classifyPair(a, b, ConflictState.conflict);
    expect(await service.showConflictWarning(a, b), isTrue);
  });

  test(
    'display projection includes conflict and foreground preferences',
    () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      for (final eventId in ['event-a', 'event-b']) {
        await database
            .into(database.sourceRecords)
            .insert(
              SourceRecordsCompanion.insert(
                id: 'source-$eventId',
                accountId: 'a',
                source: 'ustc_jw',
                entityType: 'calendar_event',
                externalId: eventId,
                localEntityId: eventId,
                sourceStatus: 'active',
                presence: 'observed',
                scopeKey: 'semester',
                firstObservedAt: 1,
                lastObservedAt: 1,
              ),
            );
      }
      await OverlayService(
        database: database,
        accountId: 'a',
      ).setForegroundPreference('event-b', 100);
      await ConflictService(database: database, accountId: 'a').classifyPair(
        participant('event-a', 'series-a'),
        participant('event-b', 'series-b'),
        ConflictState.conflict,
      );

      final events = await EffectiveEventRepository(
        database,
        accountId: 'a',
      ).watchDisplayEvents().first;
      expect(
        events.singleWhere((event) => event.id == 'event-b').foregroundPriority,
        100,
      );
      // The loading stream no longer falls back to repository-wide conflict
      // projection; conflict state is bounded to the caller's range via
      // conflictsForItems(inclusive 2026-08-10 day).
      final repo = EffectiveEventRepository(database, accountId: 'a');
      final result = await repo.conflictsForItems(
        events,
        from: DateTime(2026, 8, 9),
        throughExclusive: DateTime(2026, 8, 11),
      );
      expect(result.isConflict('event', 'event-a'), isTrue);
      expect(result.isConflict('event', 'event-b'), isTrue);
    },
  );

  test(
    'current-and-future classification stores one structured rule',
    () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = ConflictService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      final a = participant(
        'event-a',
        'series-a',
        finiteSeriesEnd: DateTime(2026, 12, 31),
      );
      final b = participant(
        'event-b',
        'series-b',
        finiteSeriesEnd: DateTime(2026, 11, 30),
      );

      await service.classifyPair(
        a,
        b,
        ConflictState.nonConflict,
        scope: ConflictScope.currentAndFuture,
      );

      final rule =
          (await database.select(database.scheduleRelationRules).get()).single;
      expect(rule.leftSeriesId, 'series-a');
      expect(rule.rightSeriesId, 'series-b');
      expect(rule.effectiveFrom, '2026-08-10');
      expect(rule.effectiveThrough, '2026-11-30');
      expect(await database.select(database.scheduleRelations).get(), isEmpty);
    },
  );

  test(
    'unbounded series keeps null end and missing identity is rejected',
    () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = ConflictService(
        database: database,
        accountId: 'a',
        now: () => 100,
      );
      final a = participant('event-a', 'series-a');
      final b = participant('event-b', 'series-b');
      await service.classifyPair(
        a,
        b,
        ConflictState.conflict,
        scope: ConflictScope.currentAndFuture,
      );
      expect(
        (await database.select(database.scheduleRelationRules).get())
            .single
            .effectiveThrough,
        isNull,
      );

      expect(
        service.classifyPair(
          a,
          eventParticipant('event-b'),
          ConflictState.conflict,
          scope: ConflictScope.currentAndFuture,
        ),
        throwsA(isA<ConflictValidationError>()),
      );
      expect(
        await database.select(database.scheduleRelationRules).get(),
        hasLength(1),
      );
    },
  );

  testWidgets('conflict editor saves independent unclassified pairs', (
    tester,
  ) async {
    final saved = <String>[];
    final a = participant('event-a', 'series-a');
    final b = participant('event-b', 'series-b');
    final next = participant('event-a-next', 'series-a');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConflictEditor(
            pairs: [
              ConflictPairDraft(
                id: 'ab',
                left: a,
                right: b,
                leftTitle: 'A',
                rightTitle: 'B',
              ),
              ConflictPairDraft(
                id: 'bn',
                left: b,
                right: next,
                leftTitle: 'B',
                rightTitle: 'Next',
                state: ConflictState.nonConflict,
              ),
            ],
            onClassify: (left, right, state, {required scope, reason}) async {
              saved.add('${left.id}:${right.id}:${state.name}');
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('save-conflicts')));
    await tester.pumpAndSettle();
    expect(saved, [
      'event-a:event-b:unclassified',
      'event-b:event-a-next:nonConflict',
    ]);
  });

  test('overlay edit uses the global one-step undo slot', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final undo = UndoService(database: database, accountId: 'a');
    final overlays = OverlayService(
      database: database,
      accountId: 'a',
      undoRecorder: undo,
    );
    await overlays.setForegroundPreference('event-a', 1);
    await overlays.setForegroundPreference('event-a', 9);

    await undo.undo();

    expect(
      (await database.select(database.userOverlays).get())
          .single
          .foregroundPriority,
      1,
    );
  });

  test('conflict edit uses the global one-step undo slot', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final undo = UndoService(database: database, accountId: 'a');
    final service = ConflictService(
      database: database,
      accountId: 'a',
      undoRecorder: undo,
    );
    final a = participant('event-a', 'series-a');
    final b = participant('event-b', 'series-b');
    await service.classifyPair(a, b, ConflictState.nonConflict);
    await service.classifyPair(a, b, ConflictState.conflict);

    await undo.undo();

    expect(await service.stateForPair(a, b), ConflictState.nonConflict);
  });

  group('ScheduleConflictProjection', () {
    test('timed overlap with no relation derives conflict', () {
      final a = eventItem(
        'a',
        DateTime(2026, 8, 10, 9, 0),
        DateTime(2026, 8, 10, 10, 30),
      );
      final b = eventItem(
        'b',
        DateTime(2026, 8, 10, 9, 30),
        DateTime(2026, 8, 10, 11, 0),
      );

      final pairs = ScheduleConflictProjection.resolve(
        [a, b],
        const ScheduleConflictRelationSnapshot(),
      );
      expect(pairs, hasLength(1));
      final pair = pairs.single;
      expect(pair.state, ConflictPairState.conflict);
      expect(pair.origin, ConflictPairOrigin.derivedOverlap);
    });

    test('overlap suppressed by occurrence no_conflict', () {
      final a = eventItem(
        'a',
        DateTime(2026, 8, 10, 9, 0),
        DateTime(2026, 8, 10, 10, 30),
      );
      final b = eventItem(
        'b',
        DateTime(2026, 8, 10, 9, 30),
        DateTime(2026, 8, 10, 11, 0),
      );
      final snapshot = ScheduleConflictRelationSnapshot(
        occurrenceByPair: {
          ScheduleConflictProjection.occurrenceKey(
            'event',
            'a',
            'event',
            'b',
          ): ConflictPairState.noConflict,
        },
      );

      final pair = ScheduleConflictProjection.resolve([a, b], snapshot).single;
      expect(pair.state, ConflictPairState.noConflict);
      expect(pair.origin, ConflictPairOrigin.explicitOccurrence);
    });

    test('overlap suppressed by effective series no_conflict', () {
      final a = eventItem(
        'a',
        DateTime(2026, 8, 10, 9, 0),
        DateTime(2026, 8, 10, 10, 30),
        seriesId: 'series-a',
      );
      final b = eventItem(
        'b',
        DateTime(2026, 8, 10, 9, 30),
        DateTime(2026, 8, 10, 11, 0),
        seriesId: 'series-b',
      );
      final snapshot = ScheduleConflictRelationSnapshot(
        seriesByPair: {
          ScheduleConflictProjection.seriesKey(
            'course_series',
            'series-a',
            'course_series',
            'series-b',
          ): [
            SeriesConflictRule(
              effectiveFrom: '2026-08-01',
              state: ConflictPairState.noConflict,
            ),
          ],
        },
      );

      final pair = ScheduleConflictProjection.resolve([a, b], snapshot).single;
      expect(pair.state, ConflictPairState.noConflict);
      expect(pair.origin, ConflictPairOrigin.explicitSeries);
    });

    test('non-overlap with explicit conflict stays conflict', () {
      final a = eventItem(
        'a',
        DateTime(2026, 8, 10, 9, 0),
        DateTime(2026, 8, 10, 10, 0),
      );
      final b = eventItem(
        'b',
        DateTime(2026, 8, 10, 14, 0),
        DateTime(2026, 8, 10, 15, 0),
      );
      final snapshot = ScheduleConflictRelationSnapshot(
        occurrenceByPair: {
          ScheduleConflictProjection.occurrenceKey(
            'event',
            'a',
            'event',
            'b',
          ): ConflictPairState.conflict,
        },
      );

      final pair = ScheduleConflictProjection.resolve([a, b], snapshot).single;
      expect(pair.state, ConflictPairState.conflict);
      expect(pair.origin, ConflictPairOrigin.explicitOccurrence);
    });

    test('same-date all-day items do not auto-conflict', () {
      final a = allDayItem(
        'a',
        DateTime(2026, 8, 10),
        DateTime(2026, 8, 11),
      );
      final b = allDayItem(
        'b',
        DateTime(2026, 8, 10),
        DateTime(2026, 8, 11),
      );

      final pair = ScheduleConflictProjection.resolve(
        [a, b],
        const ScheduleConflictRelationSnapshot(),
      ).single;
      expect(pair.state, ConflictPairState.noConflict);
    });

    test('event and plan block overlap derives conflict', () {
      final a = eventItem(
        'a',
        DateTime(2026, 8, 10, 9, 0),
        DateTime(2026, 8, 10, 10, 30),
      );
      final b = planBlockItem(
        'pb',
        'task-1',
        DateTime(2026, 8, 10, 9, 30),
        DateTime(2026, 8, 10, 11, 0),
      );

      final pair = ScheduleConflictProjection.resolve(
        [a, b],
        const ScheduleConflictRelationSnapshot(),
      ).single;
      expect(pair.state, ConflictPairState.conflict);
      expect(pair.origin, ConflictPairOrigin.derivedOverlap);
    });

    test('three overlapping items with one suppressed pair yield two conflicts',
        () {
      final a = eventItem(
        'a',
        DateTime(2026, 8, 10, 9, 0),
        DateTime(2026, 8, 10, 10, 30),
      );
      final b = eventItem(
        'b',
        DateTime(2026, 8, 10, 9, 30),
        DateTime(2026, 8, 10, 11, 0),
      );
      final c = eventItem(
        'c',
        DateTime(2026, 8, 10, 10, 0),
        DateTime(2026, 8, 10, 11, 30),
      );
      final snapshot = ScheduleConflictRelationSnapshot(
        occurrenceByPair: {
          ScheduleConflictProjection.occurrenceKey(
            'event',
            'a',
            'event',
            'b',
          ): ConflictPairState.noConflict,
        },
      );

      final pairs = ScheduleConflictProjection.resolve([a, b, c], snapshot);
      final conflicts = pairs
          .where((p) => p.state == ConflictPairState.conflict)
          .toList();
      expect(conflicts, hasLength(2));
      final ab = pairs.singleWhere(
        (p) =>
            (p.left.id == 'a' && p.right.id == 'b') ||
            (p.left.id == 'b' && p.right.id == 'a'),
      );
      expect(ab.state, ConflictPairState.noConflict);
      expect(ab.origin, ConflictPairOrigin.explicitOccurrence);
    });
  });

  test('removing an explicit relation returns the pair to derived conflict',
      () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = ConflictService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );
    final a = participant('event-a', 'series-a');
    final b = participant('event-b', 'series-b');

    // event-a and event-b share the same timed slot → derived conflict with
    // no explicit row required.
    expect(await service.stateForPair(a, b), ConflictState.conflict);

    // An explicit no_conflict row suppresses the derived conflict.
    await service.classifyPair(a, b, ConflictState.nonConflict);
    expect(await service.stateForPair(a, b), ConflictState.nonConflict);
    expect(
      await database.select(database.scheduleRelations).get(),
      hasLength(1),
    );

    // Removing the explicit relation restores the derived conflict.
    await (database.delete(database.scheduleRelations)).go();
    expect(await service.stateForPair(a, b), ConflictState.conflict);
    expect(await database.select(database.scheduleRelations).get(), isEmpty);
  });

  group('unified event and plan block relation persistence', () {
    Future<void> insertPlanBlock(
      AppDatabase database, {
      required String id,
      String? taskId,
      String status = 'accepted',
      int? deletedAt,
    }) async {
      final tid = taskId ?? 'task-$id';
      await database.into(database.tasks).insert(
        TasksCompanion.insert(
          id: tid,
          accountId: 'a',
          title: '任务 $tid',
          state: 'active',
          importance: 'normal',
          tagsJson: '[]',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      await database.into(database.planBlocks).insert(
        PlanBlocksCompanion.insert(
          id: id,
          accountId: 'a',
          taskId: tid,
          title: Value('块 $id'),
          startAt: DateTime(2026, 8, 10, 9, 30).millisecondsSinceEpoch,
          endAt: DateTime(2026, 8, 10, 11, 0).millisecondsSinceEpoch,
          status: status,
          reviewedAt: Value(status == 'skipped' || status == 'cancelled' ? 1 : null),
          deletedAt: Value(deletedAt),
          createdAt: 1,
          updatedAt: 1,
        ),
      );
    }

    test('event/event occurrence writes a single canonical row (both states)',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = ConflictService(database: database, accountId: 'a');
      final a = participant('event-a', 'series-a');
      final b = participant('event-b', 'series-b');

      await service.classifyPair(a, b, ConflictState.conflict);
      expect(
        await database.select(database.scheduleRelations).get(),
        hasLength(1),
      );
      final row = (await database.select(database.scheduleRelations).get()).single;
      expect(row.leftKind, 'event');
      expect(row.rightKind, 'event');
      expect(row.leftId, 'event-a');
      expect(row.rightId, 'event-b');
      expect(row.leftEventId, 'event-a');
      expect(row.rightEventId, 'event-b');
      expect(row.leftPlanBlockId, isNull);
      expect(row.rightPlanBlockId, isNull);
      expect(row.conflictState, 'conflict');
      expect(await service.stateForPair(a, b), ConflictState.conflict);

      await service.classifyPair(a, b, ConflictState.nonConflict);
      expect(
        await database.select(database.scheduleRelations).get(),
        hasLength(1),
      );
      expect(await service.stateForPair(a, b), ConflictState.nonConflict);

      // Reverse insertion canonicalizes → still one row, same canonical shape.
      await service.classifyPair(b, a, ConflictState.conflict);
      expect(
        await database.select(database.scheduleRelations).get(),
        hasLength(1),
      );
      final canonical =
          (await database.select(database.scheduleRelations).get()).single;
      expect(canonical.leftId, 'event-a');
      expect(canonical.rightId, 'event-b');
    });

    test('event/plan_block occurrence writes a mixed canonical row', () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      await insertPlanBlock(database, id: 'pb-1');
      final service = ConflictService(database: database, accountId: 'a');
      final event = participant('event-a', 'series-a');
      final block = planBlockParticipant('pb-1');

      await service.classifyPair(event, block, ConflictState.conflict);
      expect(
        await database.select(database.scheduleRelations).get(),
        hasLength(1),
      );
      final row = (await database.select(database.scheduleRelations).get()).single;
      expect(row.leftKind, 'event');
      expect(row.leftId, 'event-a');
      expect(row.rightKind, 'plan_block');
      expect(row.rightId, 'pb-1');
      expect(row.leftEventId, 'event-a');
      expect(row.leftPlanBlockId, isNull);
      expect(row.rightEventId, isNull);
      expect(row.rightPlanBlockId, 'pb-1');
      expect(row.conflictState, 'conflict');

      await service.classifyPair(event, block, ConflictState.nonConflict);
      expect(
        await database.select(database.scheduleRelations).get(),
        hasLength(1),
      );
      expect(
        (await database.select(database.scheduleRelations).get()).single
            .conflictState,
        'no_conflict',
      );

      // Reverse insertion lands on the same canonical row.
      await service.classifyPair(block, event, ConflictState.conflict);
      expect(
        await database.select(database.scheduleRelations).get(),
        hasLength(1),
      );
      final canonical =
          (await database.select(database.scheduleRelations).get()).single;
      expect(canonical.leftId, 'event-a');
      expect(canonical.rightId, 'pb-1');
    });

    test('plan_block/plan_block occurrence writes a single canonical row',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      await insertPlanBlock(database, id: 'pb-1');
      await insertPlanBlock(database, id: 'pb-2', taskId: 'task-x');
      final service = ConflictService(database: database, accountId: 'a');
      final a = planBlockParticipant('pb-1');
      final b = planBlockParticipant('pb-2');

      await service.classifyPair(a, b, ConflictState.conflict);
      expect(
        await database.select(database.scheduleRelations).get(),
        hasLength(1),
      );
      final row = (await database.select(database.scheduleRelations).get()).single;
      expect(row.leftKind, 'plan_block');
      expect(row.rightKind, 'plan_block');
      expect(row.leftId, 'pb-1');
      expect(row.rightId, 'pb-2');
      expect(row.leftPlanBlockId, 'pb-1');
      expect(row.rightPlanBlockId, 'pb-2');
      expect(row.leftEventId, isNull);
      expect(row.rightEventId, isNull);

      // Reverse → one row.
      await service.classifyPair(b, a, ConflictState.nonConflict);
      expect(
        await database.select(database.scheduleRelations).get(),
        hasLength(1),
      );
      final canonical =
          (await database.select(database.scheduleRelations).get()).single;
      expect(canonical.leftId, 'pb-1');
      expect(canonical.rightId, 'pb-2');
      expect(canonical.conflictState, 'no_conflict');
    });

    test('classification is isolated by account', () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      await database.into(database.localAccounts).insert(
        LocalAccountsCompanion.insert(
          id: 'other',
          maskedHint: 'PB****0000',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      final serviceA = ConflictService(database: database, accountId: 'a');
      // event-b already seeded (account a).
      final a = participant('event-a', 'series-a');
      final b = participant('event-b', 'series-b');
      await serviceA.classifyPair(a, b, ConflictState.conflict);

      // Same pair under a different account is unresolved.
      final serviceOther = ConflictService(database: database, accountId: 'other');
      expect(
        await serviceOther.stateForPair(a, b),
        ConflictState.unclassified,
      );
    });

    test('missing plan block target is rejected and writes nothing', () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      final service = ConflictService(database: database, accountId: 'a');
      final event = participant('event-a', 'series-a');
      // pb-missing has no row at all (no task, no plan block).
      final missing = planBlockParticipant('pb-missing');
      await expectLater(
        service.classifyPair(event, missing, ConflictState.conflict),
        throwsA(isA<ConflictValidationError>()),
      );
      expect(
        await database.select(database.scheduleRelations).get(),
        isEmpty,
      );
      expect(
        await service.stateForPair(event, missing),
        ConflictState.unclassified,
      );
    });

    test('deleted plan block no longer participates and writes nothing',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      await insertPlanBlock(database, id: 'pb-deleted', deletedAt: 5);
      final service = ConflictService(database: database, accountId: 'a');
      final event = participant('event-a', 'series-a');
      final deleted = planBlockParticipant('pb-deleted');
      await expectLater(
        service.classifyPair(event, deleted, ConflictState.conflict),
        throwsA(isA<ConflictValidationError>()),
      );
      expect(
        await database.select(database.scheduleRelations).get(),
        isEmpty,
      );
      expect(
        await service.stateForPair(event, deleted),
        ConflictState.unclassified,
      );
    });

    test('current-and-future is rejected when either side is a plan block',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      await insertPlanBlock(database, id: 'pb-1');
      final service = ConflictService(database: database, accountId: 'a');
      final event = participant('event-a', 'series-a');
      final block = planBlockParticipant('pb-1');

      // plan_block on the left.
      await expectLater(
        () => service.classifyPair(
          block,
          event,
          ConflictState.conflict,
          scope: ConflictScope.currentAndFuture,
        ),
        throwsA(isA<ConflictValidationError>()),
      );
      // plan_block on the right.
      await expectLater(
        () => service.classifyPair(
          event,
          block,
          ConflictState.conflict,
          scope: ConflictScope.currentAndFuture,
        ),
        throwsA(isA<ConflictValidationError>()),
      );
      // plan_block/plan_block.
      await insertPlanBlock(database, id: 'pb-2', taskId: 'task-z');
      await expectLater(
        () => service.classifyPair(
          block,
          planBlockParticipant('pb-2'),
          ConflictState.conflict,
          scope: ConflictScope.currentAndFuture,
        ),
        throwsA(isA<ConflictValidationError>()),
      );
      // Nothing written for any of the rejected attempts.
      expect(
        await database.select(database.scheduleRelations).get(),
        isEmpty,
      );
      expect(
        await database.select(database.scheduleRelationRules).get(),
        isEmpty,
      );
    });

    test('undo snapshot captures both plan block and event FK columns',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      await insertPlanBlock(database, id: 'pb-1');
      final undo = UndoService(database: database, accountId: 'a');
      final service = ConflictService(
        database: database,
        accountId: 'a',
        undoRecorder: undo,
      );
      final event = participant('event-a', 'series-a');
      final block = planBlockParticipant('pb-1');
      await service.classifyPair(event, block, ConflictState.conflict);
      await undo.undo();
      expect(
        await database.select(database.scheduleRelations).get(),
        isEmpty,
      );
    });

    test('distinct kinds never collapse: event/plan_block vs event/event differ',
        () async {
      final database = await fixtureDatabase();
      addTearDown(database.close);
      await insertPlanBlock(database, id: 'pb-1');
      final service = ConflictService(database: database, accountId: 'a');
      final ev = participant('event-a', 'series-a');
      final ev2 = participant('event-b', 'series-b');
      final block = planBlockParticipant('pb-1');
      // event-a/event-b
      await service.classifyPair(ev, ev2, ConflictState.conflict);
      // event-a/pb-1 (different canonical key because kinds differ)
      await service.classifyPair(ev, block, ConflictState.nonConflict);
      expect(
        await database.select(database.scheduleRelations).get(),
        hasLength(2),
      );
    });
  });

  test('derived display projection never inserts schedule relation rows',
      () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    for (final eventId in ['event-a', 'event-b']) {
      await database
          .into(database.sourceRecords)
          .insert(
            SourceRecordsCompanion.insert(
              id: 'source-$eventId',
              accountId: 'a',
              source: 'ustc_jw',
              entityType: 'calendar_event',
              externalId: eventId,
              localEntityId: eventId,
              sourceStatus: 'active',
              presence: 'observed',
              scopeKey: 'semester',
              firstObservedAt: 1,
              lastObservedAt: 1,
            ),
          );
    }

    // event-a and event-b overlap with NO explicit relation → the bounded
    // projection derives conflict for both.
    final repo = EffectiveEventRepository(database, accountId: 'a');
    final events = await repo.watchDisplayEvents().first;
    final result = await repo.conflictsForItems(
      events,
      from: DateTime(2026, 8, 9),
      throughExclusive: DateTime(2026, 8, 11),
    );
    expect(result.isConflict('event', 'event-a'), isTrue);
    expect(result.isConflict('event', 'event-b'), isTrue);

    // Read-only contract: the derivation never persisted any relation row.
    expect(await database.select(database.scheduleRelations).get(), isEmpty);
    expect(await database.select(database.scheduleRelationRules).get(), isEmpty);
  });

  group('bounded projection scale', () {
    test('week-window projection builds no full match and no duplicate pass',
        () async {
      EffectiveEventRepository.conflictsForItemsCalls = 0;
      EffectiveEventRepository.lastCandidatesForItems = 0;
      EffectiveEventRepository.resolvedConflictIdsForCalls = 0;
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
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
      // ~2,000 non-overlapping historical events across a prior semester
      // (2025-08), all present and thus loaded by the display stream, but all
      // outside the selected 2026-08 week. If the projection were not bounded
      // to the range, the full n*(n-1)/2 match would examine ~2M pairs.
      for (var i = 0; i < 2000; i++) {
        await database
            .into(database.calendarEvents)
            .insert(
              CalendarEventsCompanion.insert(
                id: 'hist-$i',
                accountId: 'a',
                source: 'user',
                externalId: Value('hist-$i'),
                title: 'hist-$i',
                type: 'personal',
                startAt: Value(
                  DateTime(2025, 8, i % 27 + 1, 9, 45).millisecondsSinceEpoch,
                ),
                endAt: Value(
                  DateTime(2025, 8, i % 27 + 1, 11, 20).millisecondsSinceEpoch,
                ),
                allDay: false,
                timezone: 'Asia/Shanghai',
                createdAt: 1,
                updatedAt: 1,
              ),
            );
      }
      // Several current-week events (start 2026-08-10..): two overlapping, one
      // solo.
      for (var i = 0; i < 3; i++) {
        await database
            .into(database.calendarEvents)
            .insert(
              CalendarEventsCompanion.insert(
                id: 'cur-$i',
                accountId: 'a',
                source: 'user',
                externalId: Value('cur-$i'),
                title: 'cur-$i',
                type: 'personal',
                startAt: Value(
                  DateTime(2026, 8, 10, 10 + i).millisecondsSinceEpoch,
                ),
                endAt: Value(
                  DateTime(2026, 8, 10, 11 + i).millisecondsSinceEpoch,
                ),
                allDay: false,
                timezone: 'Asia/Shanghai',
                createdAt: 1,
                updatedAt: 1,
              ),
            );
      }
      final repo = EffectiveEventRepository(database, accountId: 'a');
      final events = await repo.watchDisplayEvents().first;
      // The week window 2026-08-10..2026-08-16.
      final result = await repo.conflictsForItems(
        events,
        from: DateTime(2026, 8, 10),
        throughExclusive: DateTime(2026, 8, 17),
      );
      // Only current-week items intersect the window; the full n*(n-1)/2 match
      // over ~2003 items would be enormous. Assert the bounded candidate count
      // is tiny and the projection ran exactly once.
      expect(result.candidatePairCount, lessThan(10));
      expect(EffectiveEventRepository.conflictsForItemsCalls, 1);
      // The legacy full projection must NOT be called by a bounded consumer.
      expect(EffectiveEventRepository.resolvedConflictIdsForCalls, 0);
    });
  });

  group('explicit cross-window reporting', () {
    // A get_conflicts-style projection: item A lies inside the window, item B
    // lies outside, and an explicit occurrence `conflict` relation links them.
    // The reporting flag must keep this pair materialized (not silently
    // dropped), because get_conflicts would otherwise under-report.
    test('explicit conflict between in-window and out-of-window items is reported',
        () {
      final a = eventItem(
        'a',
        DateTime(2026, 8, 10, 9, 0),
        DateTime(2026, 8, 10, 10, 30),
      );
      final b = eventItem(
        'b',
        DateTime(2026, 6, 1, 9, 0),
        DateTime(2026, 6, 1, 10, 0),
      );
      final snapshot = ScheduleConflictRelationSnapshot(
        occurrenceByPair: {
          ScheduleConflictProjection.occurrenceKey(
            'event',
            'a',
            'event',
            'b',
          ): ConflictPairState.conflict,
        },
      );
      final window = ScheduleConflictProjection.resolveCandidates(
        [a, b],
        snapshot,
        from: DateTime(2026, 8, 10),
        throughExclusive: DateTime(2026, 8, 17),
        includeExplicitOutOfWindow: true,
      );
      expect(window.pairs, hasLength(1));
      final pair = window.pairs.single;
      expect(pair.state, ConflictPairState.conflict);
      expect(pair.origin, ConflictPairOrigin.explicitOccurrence);
    });

    // An explicit `no_conflict` between an in-window and an out-of-window item
    // must also be honored when reporting (and resolve to no_conflict, so it
    // must NOT appear in the conflictKeys).
    test('explicit no_conflict across the window is honored (not dropped)', () {
      final a = eventItem(
        'a',
        DateTime(2026, 8, 10, 9, 0),
        DateTime(2026, 8, 10, 10, 30),
      );
      final b = eventItem(
        'b',
        DateTime(2026, 6, 1, 9, 0),
        DateTime(2026, 6, 1, 10, 0),
      );
      final snapshot = ScheduleConflictRelationSnapshot(
        occurrenceByPair: {
          ScheduleConflictProjection.occurrenceKey(
            'event',
            'a',
            'event',
            'b',
          ): ConflictPairState.noConflict,
        },
      );
      final window = ScheduleConflictProjection.resolveCandidates(
        [a, b],
        snapshot,
        from: DateTime(2026, 8, 10),
        throughExclusive: DateTime(2026, 8, 17),
        includeExplicitOutOfWindow: true,
      );
      expect(window.pairs, hasLength(1));
      final pair = window.pairs.single;
      expect(pair.state, ConflictPairState.noConflict);
      expect(pair.origin, ConflictPairOrigin.explicitOccurrence);
      // The no_conflict pair contributes no conflict keys.
      expect(window.conflictKeys, isEmpty);
    });

    // The week-grid (default, includeExplicitOutOfWindow=false) stays
    // "selected-week only": an out-of-window partner is dropped because the
    // item isn't rendered, so it must not contribute a candidate.
    test('week grid keeps selected-week-only scope (out-of-window dropped)', () {
      final a = eventItem(
        'a',
        DateTime(2026, 8, 10, 9, 0),
        DateTime(2026, 8, 10, 10, 30),
      );
      final b = eventItem(
        'b',
        DateTime(2026, 6, 1, 9, 0),
        DateTime(2026, 6, 1, 10, 0),
      );
      final snapshot = ScheduleConflictRelationSnapshot(
        occurrenceByPair: {
          ScheduleConflictProjection.occurrenceKey(
            'event',
            'a',
            'event',
            'b',
          ): ConflictPairState.conflict,
        },
      );
      final weekGrid = ScheduleConflictProjection.resolveCandidates(
        [a, b],
        snapshot,
        from: DateTime(2026, 8, 10),
        throughExclusive: DateTime(2026, 8, 17),
      );
      // Only in-window item 'a' participates; the out-of-window 'b' is not a
      // rendered grid item, so no candidate pair forms.
      expect(weekGrid.pairs, isEmpty);
    });

    // A cross-window explicit relation via the repository (get_conflicts
    // pathway) reaches the same conclusion and never touches the deprecated
    // full projection.
    test('repository reporting keeps cross-window conflict, week grid drops it',
        () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
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
      // In-window event 'cur' and out-of-window event 'hist'.
      await database
          .into(database.calendarEvents)
          .insert(
            CalendarEventsCompanion.insert(
              id: 'cur',
              accountId: 'a',
              source: 'user',
              externalId: const Value('cur'),
              title: 'cur',
              type: 'personal',
              startAt: Value(
                DateTime(2026, 8, 10, 9, 0).millisecondsSinceEpoch,
              ),
              endAt: Value(
                DateTime(2026, 8, 10, 10, 30).millisecondsSinceEpoch,
              ),
              allDay: false,
              timezone: 'Asia/Shanghai',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await database
          .into(database.calendarEvents)
          .insert(
            CalendarEventsCompanion.insert(
              id: 'hist',
              accountId: 'a',
              source: 'user',
              externalId: const Value('hist'),
              title: 'hist',
              type: 'personal',
              startAt: Value(
                DateTime(2026, 6, 1, 9, 0).millisecondsSinceEpoch,
              ),
              endAt: Value(
                DateTime(2026, 6, 1, 10, 30).millisecondsSinceEpoch,
              ),
              allDay: false,
              timezone: 'Asia/Shanghai',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await ConflictService(
        database: database,
        accountId: 'a',
        now: () => 1,
      ).classifyPair(
        eventParticipant('cur'),
        eventParticipant('hist', occurrenceDate: DateTime(2026, 6, 1)),
        ConflictState.conflict,
      );
      final repo = EffectiveEventRepository(database, accountId: 'a');
      final events = await repo.watchDisplayEvents().first;
      // Reporting (get_conflicts pathway): cross-window explicit conflict kept.
      final reporting = await repo.conflictsForItems(
        events,
        from: DateTime(2026, 8, 10),
        throughExclusive: DateTime(2026, 8, 17),
        includeExplicitOutOfWindow: true,
      );
      expect(reporting.isConflict('event', 'cur'), isTrue);
      // Week-grid pathway (default): out-of-window 'hist' is dropped.
      final weekGrid = await repo.conflictsForItems(
        events,
        from: DateTime(2026, 8, 10),
        throughExclusive: DateTime(2026, 8, 17),
      );
      expect(weekGrid.isConflict('event', 'cur'), isFalse);
      expect(weekGrid.isConflict('event', 'hist'), isFalse);
      expect(EffectiveEventRepository.resolvedConflictIdsForCalls, 0);
    });
  });
}
