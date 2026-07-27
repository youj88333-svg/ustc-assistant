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
    await database.actionLogsRepository.append(
      accountId: null,
      source: 'Authorization Bearer secret-token',
      actionType: 'password_changed',
      result: 'fine_username',
      safeSummary: 'Cookie=x; password=secret; PB12345678',
      occurredAt: 100,
    );

    final entries = await HistoryRepository(database).query();
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
    for (final row in const [
      ('ustc_jw', 'source_sync', 'success', 100),
      ('user', 'task_create', 'success', 200),
      ('ustc_jw', 'source_sync', 'failure', 300),
    ]) {
      await database.actionLogsRepository.append(
        accountId: null,
        source: row.$1,
        actionType: row.$2,
        result: row.$3,
        safeSummary: 'Safe operation.',
        occurredAt: row.$4,
      );
    }
    final entries = await HistoryRepository(database).query(
      HistoryFilter(
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
        EventConflictParticipant(
          eventId: 'source-event',
          occurrenceDate: DateTime(2026, 7, 27),
        ),
        EventConflictParticipant(
          eventId: 'personal-event',
          occurrenceDate: DateTime(2026, 7, 27),
        ),
        ConflictState.conflict,
      );

      final entries = await HistoryRepository(database).query();
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
