import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/schedule/application/effective_event_repository.dart';
import 'package:ustc_assistant_app/features/schedule/application/jw_day_move_service.dart';
import 'package:ustc_assistant_app/features/schedule/domain/jw_day_move.dart';
import 'package:ustc_assistant_app/features/schedule/domain/overlap_engine.dart';
import 'package:ustc_assistant_app/features/tasks/application/undo_service.dart';

const _account = 'account';
const _other = 'other';
const _dateA = '2026-08-03';
const _dateB = '2026-08-04';
const _dateC = '2026-08-05';

/// Converts a Beijing wall-clock time to the UTC epoch-ms storage encoding
/// used by the app (Beijing wall clock == stored UTC value, i.e. the app reads
/// stored UTC + 8h and gets the same wall clock back).
int _beijingEpoch(int year, int month, int day, int hour, [int minute = 0]) =>
    DateTime.utc(year, month, day, hour, minute).millisecondsSinceEpoch -
    const Duration(hours: 8).inMilliseconds;

Future<AppDatabase> _database({String account = _account}) async {
  final database = AppDatabase(NativeDatabase.memory());
  await database
      .into(database.localAccounts)
      .insert(
        LocalAccountsCompanion.insert(
          id: account,
          maskedHint: 'PB****0000',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
  return database;
}

Future<void> _seedEvent(
  AppDatabase database, {
  required String account,
  required String id,
  required String source,
  required String type,
  required int startAt,
  required int endAt,
  bool allDay = false,
  String? startDate,
  String? endDateExclusive,
  String presence = 'observed',
}) async {
  await database
      .into(database.calendarEvents)
      .insert(
        CalendarEventsCompanion.insert(
          id: id,
          accountId: account,
          source: source,
          externalId: Value(source == 'user' ? null : id),
          title: id,
          type: type,
          startAt: Value(allDay ? null : startAt),
          endAt: Value(allDay ? null : endAt),
          allDay: allDay,
          startDate: Value(startDate),
          endDateExclusive: Value(endDateExclusive),
          timezone: 'Asia/Shanghai',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
  if (source != 'user') {
    await database
        .into(database.sourceRecords)
        .insert(
          SourceRecordsCompanion.insert(
            id: 'source-$account-$id',
            accountId: account,
            source: source,
            entityType: 'calendar_event',
            externalId: id,
            localEntityId: id,
            sourceStatus: 'active',
            presence: presence,
            scopeKey: 'semester',
            firstObservedAt: 1,
            lastObservedAt: 1,
          ),
        );
  }
}

/// The Step-2 seed on the source date A:
/// two ustc_jw/course timed events, one ustc_jw/exam, one
/// ustc_young/second_class, one user/personal, one all-day event and a
/// plan block. Only the two course events are eligible for a whole-day move.
/// [idPrefix] namespaces the row ids so a second account can seed the same
/// calendar day without primary-key collisions.
Future<void> _seedDayA(
  AppDatabase database, {
  String account = _account,
  String idPrefix = '',
}) async {
  await _seedEvent(
    database,
    account: account,
    id: '${idPrefix}course-1',
    source: 'ustc_jw',
    type: 'course',
    startAt: _beijingEpoch(2026, 8, 3, 9),
    endAt: _beijingEpoch(2026, 8, 3, 10),
  );
  await _seedEvent(
    database,
    account: account,
    id: '${idPrefix}course-2',
    source: 'ustc_jw',
    type: 'course',
    startAt: _beijingEpoch(2026, 8, 3, 14),
    endAt: _beijingEpoch(2026, 8, 3, 16),
  );
  await _seedEvent(
    database,
    account: account,
    id: '${idPrefix}exam-1',
    source: 'ustc_jw',
    type: 'exam',
    startAt: _beijingEpoch(2026, 8, 3, 11),
    endAt: _beijingEpoch(2026, 8, 3, 12),
  );
  await _seedEvent(
    database,
    account: account,
    id: '${idPrefix}second-1',
    source: 'ustc_young',
    type: 'second_class',
    startAt: _beijingEpoch(2026, 8, 3, 13),
    endAt: _beijingEpoch(2026, 8, 3, 14),
  );
  await _seedEvent(
    database,
    account: account,
    id: '${idPrefix}personal-1',
    source: 'user',
    type: 'personal',
    startAt: _beijingEpoch(2026, 8, 3, 10),
    endAt: _beijingEpoch(2026, 8, 3, 11),
  );
  await _seedEvent(
    database,
    account: account,
    id: '${idPrefix}all-day-1',
    source: 'user',
    type: 'personal',
    allDay: true,
    startDate: _dateA,
    endDateExclusive: _dateB,
    startAt: 0,
    endAt: 0,
  );
  await database
      .into(database.tasks)
      .insert(
        TasksCompanion.insert(
          id: '${idPrefix}task-1',
          accountId: account,
          title: 'blocked task',
          state: 'active',
          importance: 'normal',
          tagsJson: '[]',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
  await database
      .into(database.planBlocks)
      .insert(
        PlanBlocksCompanion.insert(
          id: '${idPrefix}block-1',
          accountId: account,
          taskId: '${idPrefix}task-1',
          startAt: _beijingEpoch(2026, 8, 3, 15),
          endAt: _beijingEpoch(2026, 8, 3, 17),
          status: 'accepted',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
}

/// The timed events shown on a Beijing calendar day by the effective display
/// stream (moved courses appear on their target day).
Future<List<EffectiveEvent>> _eventsOn(
  AppDatabase database, {
  required String account,
  required DateTime day,
}) async {
  final events = await EffectiveEventRepository(
    database,
    accountId: account,
  ).watchDisplayEvents().first;
  return events
      .where(
        (event) =>
            !event.allDay &&
            event.startAt != null &&
            event.startAt!.year == day.year &&
            event.startAt!.month == day.month &&
            event.startAt!.day == day.day,
      )
      .toList(growable: false);
}

void main() {
  test('preview lists only eligible course titles and the existing target', () async {
    final database = await _database();
    addTearDown(database.close);
    await _seedDayA(database);
    final service = JwDayMoveService(
      database: database,
      accountId: _account,
      now: () => 10,
    );

    final preview = await service.preview(_dateA);
    expect(preview.sourceDate, _dateA);
    expect(preview.targetDate, isNull);
    expect(preview.courses, ['course-1', 'course-2']);

    await service.move(_dateA, _dateB);
    final after = await service.preview(_dateA);
    expect(after.targetDate, _dateB);
    expect(after.courses, ['course-1', 'course-2']);
  });

  test('move shifts only eligible courses to the target day and keeps source immutable', () async {
    final database = await _database();
    addTearDown(database.close);
    await _seedDayA(database);
    final service = JwDayMoveService(
      database: database,
      accountId: _account,
      now: () => 10,
    );

    await service.move(_dateA, _dateB);

    final rows =
        await (database.select(database.jwDayMoves)..where(
              (row) => row.accountId.equals(_account),
            ))
            .get();
    expect(rows, hasLength(1));
    expect(rows.single.sourceDate, _dateA);
    expect(rows.single.targetDate, _dateB);

    final onA = await _eventsOn(
      database,
      account: _account,
      day: DateTime(2026, 8, 3),
    );
    final onB = await _eventsOn(
      database,
      account: _account,
      day: DateTime(2026, 8, 4),
    );
    final idsA = onA.map((event) => event.id).toSet();
    // The courses stop showing on A; exams, second-class and personal events
    // never move. The all-day event is a calendar-day band, not timed.
    expect(idsA, isNot(contains('course-1')));
    expect(idsA, isNot(contains('course-2')));
    expect(idsA, containsAll(['exam-1', 'second-1', 'personal-1']));
    // The two courses reappear on B at the same Beijing time and duration.
    final course1 = onB.singleWhere((event) => event.id == 'course-1');
    final course2 = onB.singleWhere((event) => event.id == 'course-2');
    expect(course1.startAt, DateTime(2026, 8, 4, 9));
    expect(course1.endAt, DateTime(2026, 8, 4, 10));
    expect(course2.startAt, DateTime(2026, 8, 4, 14));
    expect(course2.endAt, DateTime(2026, 8, 4, 16));

    // The raw CalendarEvent keeps its original timestamps; the effective
    // display times live on the record.
    final repository = EffectiveEventRepository(database, accountId: _account);
    final record = await repository.byId('course-1');
    expect(record.effectiveStartAt, DateTime(2026, 8, 4, 9));
    expect(record.effectiveEndAt, DateTime(2026, 8, 4, 10));
    expect(record.source.startAt, _beijingEpoch(2026, 8, 3, 9));
    expect(record.source.endAt, _beijingEpoch(2026, 8, 3, 10));
    final exam = await repository.byId('exam-1');
    expect(exam.effectiveStartAt, isNull);
    expect(exam.effectiveEndAt, isNull);
    final allDay = await repository.byId('all-day-1');
    expect(allDay.effectiveStartAt, isNull);
    // PlanBlocks never move.
    expect(await database.select(database.planBlocks).get(), hasLength(1));
  });

  test('retarget A->C updates the same move record', () async {
    final database = await _database();
    addTearDown(database.close);
    await _seedDayA(database);
    final service = JwDayMoveService(
      database: database,
      accountId: _account,
      now: () => 10,
    );

    await service.move(_dateA, _dateB);
    await service.move(_dateA, _dateC);

    final rows = await database.select(database.jwDayMoves).get();
    expect(rows, hasLength(1));
    expect(rows.single.sourceDate, _dateA);
    expect(rows.single.targetDate, _dateC);

    final onC = await _eventsOn(
      database,
      account: _account,
      day: DateTime(2026, 8, 5),
    );
    final onB = await _eventsOn(
      database,
      account: _account,
      day: DateTime(2026, 8, 4),
    );
    expect(onC.map((event) => event.id), containsAll(['course-1', 'course-2']));
    expect(onB.map((event) => event.id), isNot(contains('course-1')));
  });

  test('B->C moves only B-native courses, never A-projected ones', () async {
    final database = await _database();
    addTearDown(database.close);
    await _seedDayA(database);
    final service = JwDayMoveService(
      database: database,
      accountId: _account,
      now: () => 10,
    );
    await service.move(_dateA, _dateB);
    // A course that natively belongs to B.
    await _seedEvent(
      database,
      account: _account,
      id: 'course-3',
      source: 'ustc_jw',
      type: 'course',
      startAt: _beijingEpoch(2026, 8, 4, 9, 30),
      endAt: _beijingEpoch(2026, 8, 4, 10, 30),
    );

    await service.move(_dateB, _dateC);

    final rows =
        (await database.select(database.jwDayMoves).get())
            .map((row) => '${row.sourceDate}->${row.targetDate}')
            .toList();
    expect(rows, containsAll(['$_dateA->$_dateB', '$_dateB->$_dateC']));
    final onB = await _eventsOn(
      database,
      account: _account,
      day: DateTime(2026, 8, 4),
    );
    final onC = await _eventsOn(
      database,
      account: _account,
      day: DateTime(2026, 8, 5),
    );
    // The B-native course moves to C; the A-projected course stays on B.
    expect(onC.map((event) => event.id), contains('course-3'));
    expect(onC.map((event) => event.id), isNot(contains('course-1')));
    expect(onB.map((event) => event.id), contains('course-1'));
    expect(onB.map((event) => event.id), isNot(contains('course-3')));
    // The A->B projection is unchanged: course-1 still shows at its moved slot.
    final course1 = onB.singleWhere((event) => event.id == 'course-1');
    expect(course1.startAt, DateTime(2026, 8, 4, 9));
  });

  test('clear removes the move and restores original display dates', () async {
    final database = await _database();
    addTearDown(database.close);
    await _seedDayA(database);
    final service = JwDayMoveService(
      database: database,
      accountId: _account,
      now: () => 10,
    );
    await service.move(_dateA, _dateB);

    await service.clear(_dateA);

    expect(await database.select(database.jwDayMoves).get(), isEmpty);
    final onA = await _eventsOn(
      database,
      account: _account,
      day: DateTime(2026, 8, 3),
    );
    expect(onA.map((event) => event.id), containsAll(['course-1', 'course-2']));
  });

  test('move rejects a source date without eligible courses', () async {
    final database = await _database();
    addTearDown(database.close);
    await _seedDayA(database);
    final service = JwDayMoveService(
      database: database,
      accountId: _account,
      now: () => 10,
    );

    final preview = await service.preview('2026-08-06');
    expect(preview.courses, isEmpty);
    await expectLater(
      service.move('2026-08-06', _dateB),
      throwsA(isA<NoEligibleJwCourses>()),
    );
    expect(await database.select(database.jwDayMoves).get(), isEmpty);
  });

  test('move rejects source == target', () async {
    final database = await _database();
    addTearDown(database.close);
    await _seedDayA(database);
    final service = JwDayMoveService(
      database: database,
      accountId: _account,
      now: () => 10,
    );

    await expectLater(
      service.move(_dateA, _dateA),
      throwsA(isA<InvalidDayMoveDates>()),
    );
    expect(await database.select(database.jwDayMoves).get(), isEmpty);
  });

  test('clear rejects a source date with no move record', () async {
    final database = await _database();
    addTearDown(database.close);
    await _seedDayA(database);
    final service = JwDayMoveService(
      database: database,
      accountId: _account,
      now: () => 10,
    );

    await expectLater(
      service.clear(_dateA),
      throwsA(isA<MissingJwDayMove>()),
    );
  });

  test('moves are isolated per account', () async {
    final database = await _database();
    addTearDown(database.close);
    await database
        .into(database.localAccounts)
        .insert(
          LocalAccountsCompanion.insert(
            id: _other,
            maskedHint: 'PB****1111',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await _seedDayA(database);
    await _seedDayA(database, account: _other, idPrefix: 'other-');
    final service = JwDayMoveService(
      database: database,
      accountId: _account,
      now: () => 10,
    );

    await service.move(_dateA, _dateB);

    final otherRows =
        await (database.select(database.jwDayMoves)..where(
              (row) => row.accountId.equals(_other),
            ))
            .get();
    expect(otherRows, isEmpty);
    // The other account still sees its own courses on A.
    final otherOnA = await _eventsOn(
      database,
      account: _other,
      day: DateTime(2026, 8, 3),
    );
    expect(
      otherOnA.map((event) => event.id),
      containsAll(['other-course-1', 'other-course-2']),
    );
    // And can move its own source date independently.
    await JwDayMoveService(
      database: database,
      accountId: _other,
      now: () => 11,
    ).move(_dateA, _dateC);
    final otherRowsAfter =
        await (database.select(database.jwDayMoves)..where(
              (row) => row.accountId.equals(_other),
            ))
            .get();
    expect(otherRowsAfter, hasLength(1));
    expect(otherRowsAfter.single.targetDate, _dateC);
  });

  test('source presence removal hides the course but keeps the move; reappearance reapplies', () async {
    final database = await _database();
    addTearDown(database.close);
    await _seedDayA(database);
    final service = JwDayMoveService(
      database: database,
      accountId: _account,
      now: () => 10,
    );
    await service.move(_dateA, _dateB);

    // Sync removes the occurrence: presence becomes missing_within_scope.
    await (database.update(
      database.sourceRecords,
    )..where((row) => row.localEntityId.equals('course-1'))).write(
      const SourceRecordsCompanion(
        presence: Value('missing_within_scope'),
      ),
    );
    final onB = await _eventsOn(
      database,
      account: _account,
      day: DateTime(2026, 8, 4),
    );
    expect(onB.map((event) => event.id), isNot(contains('course-1')));
    // The move record persists so a reappearance reapplies the projection.
    expect(await database.select(database.jwDayMoves).get(), hasLength(1));

    await (database.update(
      database.sourceRecords,
    )..where((row) => row.localEntityId.equals('course-1'))).write(
      const SourceRecordsCompanion(presence: Value('observed')),
    );
    final onBAfter = await _eventsOn(
      database,
      account: _account,
      day: DateTime(2026, 8, 4),
    );
    final course1 = onBAfter.singleWhere((event) => event.id == 'course-1');
    expect(course1.startAt, DateTime(2026, 8, 4, 9));
  });

  test('undoing a move insert deletes the move row and restores display', () async {
    final database = await _database();
    addTearDown(database.close);
    await _seedDayA(database);
    var clock = 100;
    final undo = UndoService(
      database: database,
      accountId: _account,
      now: () => ++clock,
    );
    final service = JwDayMoveService(
      database: database,
      accountId: _account,
      now: () => ++clock,
      undoRecorder: undo,
    );
    await service.move(_dateA, _dateB);

    await undo.undo();

    expect(await database.select(database.jwDayMoves).get(), isEmpty);
    expect(await undo.canUndo(), isFalse);
    final onA = await _eventsOn(
      database,
      account: _account,
      day: DateTime(2026, 8, 3),
    );
    expect(onA.map((event) => event.id), containsAll(['course-1', 'course-2']));
    expect(
      (await database.actionLogsRepository.selectAll()).map(
        (entry) => entry.actionType,
      ),
      contains('undo_jw_day_move'),
    );
  });

  test('undoing a retarget restores the previous target date', () async {
    final database = await _database();
    addTearDown(database.close);
    await _seedDayA(database);
    var clock = 200;
    final undo = UndoService(
      database: database,
      accountId: _account,
      now: () => ++clock,
    );
    final service = JwDayMoveService(
      database: database,
      accountId: _account,
      now: () => ++clock,
      undoRecorder: undo,
    );
    await service.move(_dateA, _dateB);
    final createdAt = (await database.select(database.jwDayMoves).getSingle()).createdAt;
    await service.move(_dateA, _dateC);

    await undo.undo();

    final row = await database.select(database.jwDayMoves).getSingle();
    expect(row.sourceDate, _dateA);
    expect(row.targetDate, _dateB);
    expect(row.createdAt, createdAt);
    expect(await undo.canUndo(), isFalse);
  });

  test('undoing a clear restores the exact deleted move row', () async {
    final database = await _database();
    addTearDown(database.close);
    await _seedDayA(database);
    var clock = 300;
    final undo = UndoService(
      database: database,
      accountId: _account,
      now: () => ++clock,
    );
    final service = JwDayMoveService(
      database: database,
      accountId: _account,
      now: () => ++clock,
      undoRecorder: undo,
    );
    await service.move(_dateA, _dateB);
    await service.clear(_dateA);
    expect(await database.select(database.jwDayMoves).get(), isEmpty);

    await undo.undo();

    final row = await database.select(database.jwDayMoves).getSingle();
    expect(row.accountId, _account);
    expect(row.sourceDate, _dateA);
    expect(row.targetDate, _dateB);
    expect(await undo.canUndo(), isFalse);
  });

  test('overlappingRecords and detail reads use effective moved bounds', () async {
    final database = await _database();
    addTearDown(database.close);
    await _seedDayA(database);
    final service = JwDayMoveService(
      database: database,
      accountId: _account,
      now: () => 10,
    );
    await service.move(_dateA, _dateB);
    // A course native to B overlapping the moved course-1 slot (09:00-10:00).
    await _seedEvent(
      database,
      account: _account,
      id: 'course-3',
      source: 'ustc_jw',
      type: 'course',
      startAt: _beijingEpoch(2026, 8, 4, 9, 30),
      endAt: _beijingEpoch(2026, 8, 4, 10, 30),
    );

    final repository = EffectiveEventRepository(database, accountId: _account);
    final overlaps = await repository.overlappingRecords('course-1');
    // Raw bounds (course-1 on 2026-08-03) do NOT overlap course-3 (2026-08-04);
    // the effective bounds do.
    expect(overlaps.map((record) => record.source.id), contains('course-3'));
    expect(overlaps.map((record) => record.source.id), isNot(contains('exam-1')));
    final moved = await repository.byId('course-1');
    expect(moved.effectiveStartAt, DateTime(2026, 8, 4, 9));
    expect(moved.effectiveEndAt, DateTime(2026, 8, 4, 10));
  });
}
