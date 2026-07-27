import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/schedule/application/conflict_service.dart';
import 'package:ustc_assistant_app/features/schedule/application/effective_event_repository.dart';
import 'package:ustc_assistant_app/features/schedule/application/overlay_service.dart';
import 'package:ustc_assistant_app/features/schedule/presentation/conflict_editor.dart';
import 'package:ustc_assistant_app/features/tasks/application/undo_service.dart';

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

void main() {
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

  test('only explicit conflict gets warning state', () async {
    final database = await fixtureDatabase();
    addTearDown(database.close);
    final service = ConflictService(
      database: database,
      accountId: 'a',
      now: () => 100,
    );
    final a = participant('event-a', 'series-a');
    final b = participant('event-b', 'series-b');

    expect(await service.stateForPair(a, b), ConflictState.unclassified);
    await service.classifyPair(a, b, ConflictState.nonConflict);
    expect(await service.showConflictWarning(a, b), isFalse);
    await service.classifyPair(a, b, ConflictState.conflict);
    expect(await service.showConflictWarning(a, b), isTrue);
  });

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
}
