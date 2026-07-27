import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/schedule/application/conflict_service.dart';
import 'package:ustc_assistant_app/features/schedule/application/effective_event_repository.dart';
import 'package:ustc_assistant_app/features/schedule/presentation/conflict_management_page.dart';
import 'package:ustc_assistant_app/features/schedule/presentation/event_detail_loader.dart';

Future<AppDatabase> _database() async {
  final database = AppDatabase(NativeDatabase.memory());
  await database
      .into(database.localAccounts)
      .insert(
        LocalAccountsCompanion.insert(
          id: 'account',
          maskedHint: 'PB****0000',
          isActive: const Value(true),
          createdAt: 1,
          updatedAt: 1,
        ),
      );
  return database;
}

Future<void> _insertEvent(
  AppDatabase database, {
  required String id,
  required String source,
  required int startHour,
  String type = 'personal',
}) async {
  await database
      .into(database.calendarEvents)
      .insert(
        CalendarEventsCompanion.insert(
          id: id,
          accountId: 'account',
          source: source,
          externalId: Value(source == 'user' ? null : id),
          title: id,
          type: type,
          startAt: Value(
            DateTime.utc(2026, 7, 27, startHour).millisecondsSinceEpoch,
          ),
          endAt: Value(
            DateTime.utc(2026, 7, 27, startHour + 2).millisecondsSinceEpoch,
          ),
          allDay: false,
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
            id: 'source-$id',
            accountId: 'account',
            source: source,
            entityType: 'calendar_event',
            externalId: id,
            localEntityId: id,
            sourceStatus: 'active',
            presence: 'observed',
            scopeKey: 'semester',
            firstObservedAt: 1,
            lastObservedAt: 1,
          ),
        );
  }
}

void main() {
  testWidgets('source and personal details expose only valid actions', (
    tester,
  ) async {
    final database = await _database();
    addTearDown(database.close);
    await _insertEvent(
      database,
      id: 'source-event',
      source: 'ustc_jw',
      startHour: 1,
      type: 'course',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: EventDetailLoader(database: database, eventId: 'source-event'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('hide-source-event')), findsOneWidget);
    expect(find.byKey(const Key('delete-personal-event')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await _insertEvent(
      database,
      id: 'personal-event',
      source: 'user',
      startHour: 4,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: EventDetailLoader(database: database, eventId: 'personal-event'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('edit-personal-event')), findsOneWidget);
    expect(find.byKey(const Key('delete-personal-event')), findsOneWidget);
    expect(find.byKey(const Key('hide-source-event')), findsNothing);
  });

  testWidgets('preferences reload and source hide preserves imported rows', (
    tester,
  ) async {
    final database = await _database();
    addTearDown(database.close);
    await _insertEvent(
      database,
      id: 'source-event',
      source: 'ustc_jw',
      startHour: 1,
      type: 'course',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: EventDetailLoader(database: database, eventId: 'source-event'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('编辑偏好'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attendance-policy')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('必去').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('listening-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不听讲').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('attendance-note')), '节前风险高');
    await tester.enterText(find.byKey(const Key('event-user-notes')), '带实验报告');
    await tester.tap(find.byKey(const Key('event-color-#C62828')));
    await tester.tap(find.byKey(const Key('save-event-preferences')));
    await tester.pumpAndSettle();

    final repository = EffectiveEventRepository(database, accountId: 'account');
    var record = await repository.byId('source-event');
    expect(record.attendance, AttendancePolicy.mustGo);
    expect(record.listeningMode, ListeningMode.notListen);
    expect(record.attendanceNote, '节前风险高');
    expect(record.userNotes, '带实验报告');
    expect(record.color, '#C62828');

    await tester.tap(find.byKey(const Key('hide-source-event')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('隐藏').last);
    await tester.pumpAndSettle();

    record = await repository.byId('source-event');
    expect(record.hidden, isTrue);
    expect(
      await (database.select(
        database.calendarEvents,
      )..where((row) => row.id.equals('source-event'))).getSingleOrNull(),
      isNotNull,
    );
  });

  testWidgets('personal delete is soft and remains restorable', (tester) async {
    final database = await _database();
    addTearDown(database.close);
    await _insertEvent(
      database,
      id: 'personal-event',
      source: 'user',
      startHour: 1,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: EventDetailLoader(database: database, eventId: 'personal-event'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('delete-personal-event')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();

    final row = await (database.select(
      database.calendarEvents,
    )..where((event) => event.id.equals('personal-event'))).getSingle();
    expect(row.deletedAt, isNotNull);
  });

  testWidgets('conflict page saves foreground separately from pair state', (
    tester,
  ) async {
    final database = await _database();
    addTearDown(database.close);
    for (final item in [('event-a', 1), ('event-b', 2), ('event-c', 2)]) {
      await _insertEvent(
        database,
        id: item.$1,
        source: 'user',
        startHour: item.$2,
      );
    }
    final records = await EffectiveEventRepository(
      database,
      accountId: 'account',
    ).overlappingRecords('event-b');
    await tester.pumpWidget(
      MaterialApp(
        home: ConflictManagementPage(
          database: database,
          accountId: 'account',
          records: records,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(records, hasLength(3));
    await tester.tap(find.byKey(const Key('foreground-event-b')));
    await tester.tap(find.byKey(const Key('conflict-state-event-a|event-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('冲突').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-conflicts')));
    await tester.pumpAndSettle();

    final refreshed = await Future.wait(
      records.map(
        (record) => EffectiveEventRepository(
          database,
          accountId: 'account',
        ).byId(record.source.id),
      ),
    );
    expect(
      refreshed
          .singleWhere((record) => record.source.id == 'event-b')
          .foregroundPriority,
      100,
    );
    expect(
      refreshed
          .where((record) => record.source.id != 'event-b')
          .every((record) => record.foregroundPriority == 0),
      isTrue,
    );
    final service = ConflictService(database: database, accountId: 'account');
    expect(
      await service.stateForPair(
        EventConflictParticipant(
          eventId: 'event-a',
          occurrenceDate: DateTime(2026, 7, 27),
        ),
        EventConflictParticipant(
          eventId: 'event-b',
          occurrenceDate: DateTime(2026, 7, 27),
        ),
      ),
      ConflictState.conflict,
    );
  });
}
