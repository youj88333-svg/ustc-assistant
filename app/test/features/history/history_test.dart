import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/calendar/application/calendar_event_service.dart';
import 'package:ustc_assistant_app/features/history/application/history_repository.dart';
import 'package:ustc_assistant_app/features/schedule/application/conflict_service.dart';
import 'package:ustc_assistant_app/features/schedule/application/overlay_service.dart';

void main() {
  test('history sanitizes every rendered and filterable field', () async {
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
    await database.actionLogsRepository.append(
      accountId: 'a',
      source: 'Authorization Bearer secret-token',
      actionType: 'password_changed',
      result: 'fine_username',
      safeSummary: 'Cookie=x; password=secret; PB12345678',
      occurredAt: 100,
    );

    final entries = await HistoryRepository(database).query('a');
    final text = entries
        .map(
          (item) =>
              '${item.source} ${item.actionType} ${item.result} ${item.safeSummary}',
        )
        .join();
    expect(text, isNotEmpty);
    expect(text.toLowerCase(), isNot(contains('password')));
    expect(text, isNot(contains('Bearer')));
    expect(text, isNot(contains('secret-token')));
    expect(text, isNot(contains('fine_username')));
    expect(text, isNot(contains('PB12345678')));
  });

  test('history filters by time, source, action type and result', () async {
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
    for (final row in const [
      ('ustc_jw', 'source_sync', 'success', 100),
      ('user', 'task_create', 'success', 200),
      ('ustc_jw', 'source_sync', 'failure', 300),
    ]) {
      await database.actionLogsRepository.append(
        accountId: 'a',
        source: row.$1,
        actionType: row.$2,
        result: row.$3,
        safeSummary: 'Safe operation.',
        occurredAt: row.$4,
      );
    }
    final entries = await HistoryRepository(database).query(
      'a',
      filter: HistoryFilter(
        from: 250,
        through: 350,
        source: 'ustc_jw',
        actionType: 'source_sync',
        result: 'failure',
      ),
    );
    expect(entries, hasLength(1));
    expect(entries.single.occurredAt, 300);
  });

  test('history is scoped to the account in the database query', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    for (final account in ['a', 'b']) {
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
    }
    await database.actionLogsRepository.append(
      accountId: 'a',
      source: 'user',
      actionType: 'task_create',
      result: 'success',
      safeSummary: 'Account A task.',
      occurredAt: 100,
    );
    await database.actionLogsRepository.append(
      accountId: 'b',
      source: 'user',
      actionType: 'task_create',
      result: 'success',
      safeSummary: 'Account B task.',
      occurredAt: 200,
    );
    // A null-account legacy log must never surface for a scoped query.
    await database.actionLogsRepository.append(
      accountId: null,
      source: 'user',
      actionType: 'task_create',
      result: 'success',
      safeSummary: 'Unscoped legacy log.',
      occurredAt: 50,
    );

    final aEntries = await HistoryRepository(database).query('a');
    expect(aEntries, hasLength(1));
    expect(aEntries.single.safeSummary, 'Account A task.');

    final bEntries = await HistoryRepository(database).query('b');
    expect(bEntries, hasLength(1));
    expect(bEntries.single.safeSummary, 'Account B task.');
  });

  test('history caps the result at 50 rows', () async {
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
    for (var i = 0; i < 60; i++) {
      await database.actionLogsRepository.append(
        accountId: 'a',
        source: 'user',
        actionType: 'task_create',
        result: 'success',
        safeSummary: 'Operation $i.',
        occurredAt: 1000 + i,
      );
    }
    final entries = await HistoryRepository(database).query('a');
    expect(entries, hasLength(50));
    // Newest-first ordering: the most recent 50 of the 60 rows.
    expect(entries.first.occurredAt, 1059);
    expect(entries.last.occurredAt, 1010);
  });

  test(
    'event operations write safe summaries without private content',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await database
          .into(database.localAccounts)
          .insert(
            LocalAccountsCompanion.insert(
              id: 'account',
              maskedHint: 'PB****0000',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      for (final item in [
        ('source-event', 'ustc_jw', '敏感课程标题'),
        ('personal-event', 'user', '私密游戏安排'),
      ]) {
        await database
            .into(database.calendarEvents)
            .insert(
              CalendarEventsCompanion.insert(
                id: item.$1,
                accountId: 'account',
                source: item.$2,
                title: item.$3,
                type: item.$2 == 'user' ? 'personal' : 'course',
                startAt: Value(
                  DateTime.utc(2026, 7, 27, 1).millisecondsSinceEpoch,
                ),
                endAt: Value(
                  DateTime.utc(2026, 7, 27, 2).millisecondsSinceEpoch,
                ),
                allDay: false,
                timezone: 'Asia/Shanghai',
                createdAt: 1,
                updatedAt: 1,
              ),
            );
      }

      await OverlayService(
        database: database,
        accountId: 'account',
        now: () => 100,
      ).setEventOverlay(
        'source-event',
        const OverlayMutation(hidden: true, userNotes: '敏感地点'),
      );
      await CalendarEventService(
        database: database,
        accountId: 'account',
        now: () => 200,
      ).softDelete('personal-event');
      await ConflictService(
        database: database,
        accountId: 'account',
        now: () => 300,
      ).classifyPair(
        ScheduleConflictParticipant(
          kind: 'event',
          id: 'source-event',
          title: 'source-event',
          occurrenceDate: DateTime(2026, 7, 27),
        ),
        ScheduleConflictParticipant(
          kind: 'event',
          id: 'personal-event',
          title: 'personal-event',
          occurrenceDate: DateTime(2026, 7, 27),
        ),
        ConflictState.conflict,
      );

      final entries = await HistoryRepository(database).query('account');
      expect(
        entries.map((entry) => entry.actionType),
        containsAll([
          'user_overlay_update',
          'calendar_event_delete',
          'conflict_classification',
        ]),
      );
      final rendered = entries.map((entry) => entry.safeSummary).join(' ');
      expect(rendered, isNot(contains('敏感课程标题')));
      expect(rendered, isNot(contains('私密游戏安排')));
      expect(rendered, isNot(contains('敏感地点')));
      expect(rendered, isNot(contains('PB****0000')));
    },
  );
}
