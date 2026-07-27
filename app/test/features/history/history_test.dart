import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/history/application/history_repository.dart';

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
}
