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

EventConflictParticipant participant(
  String eventId,
  String seriesId, {
  DateTime? finiteSeriesEnd,
}) => EventConflictParticipant(
  eventId: eventId,
  seriesType: 'course_series',
  seriesId: seriesId,
  occurrenceDate: DateTime(2026, 8, 10),
  finiteSeriesEnd: finiteSeriesEnd,
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
      expect(
        events
            .singleWhere((event) => event.id == 'event-a')
            .hasConfirmedConflict,
        isTrue,
      );
      expect(
        events
            .singleWhere((event) => event.id == 'event-b')
            .hasConfirmedConflict,
        isTrue,
      );
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
          EventConflictParticipant(
            eventId: 'event-b',
            occurrenceDate: DateTime(2026, 8, 10),
          ),
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
              saved.add('${left.eventId}:${right.eventId}:${state.name}');
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
}
