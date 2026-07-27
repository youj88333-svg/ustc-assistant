import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:ustc_assistant_app/core/database/app_database.dart';

void main() {
  test(
    'schema version two creates the complete constrained database',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      expect(database.schemaVersion, 2);
      final foreignKeys = await database
          .customSelect('PRAGMA foreign_keys')
          .getSingle();
      expect(foreignKeys.data.values.single, 1);
      final tables =
          (await database
                  .customSelect(
                    "SELECT name FROM sqlite_master WHERE type = 'table'",
                  )
                  .get())
              .map((row) => row.read<String>('name'))
              .toSet();
      expect(
        tables,
        containsAll({
          'local_accounts',
          'credential_accounts',
          'source_configs',
          'import_batches',
          'source_records',
          'course_series',
          'calendar_events',
          'calendar_event_series',
          'calendar_event_occurrence_exceptions',
          'user_overlays',
          'schedule_relations',
          'schedule_relation_rules',
          'task_event_links',
          'tasks',
          'plan_blocks',
          'reminders',
          'sync_runs',
          'action_logs',
          'undo_slot',
          'agent_permission_policies',
        }),
      );
      expect(
        await database.select(database.agentPermissionPolicies).get(),
        isEmpty,
      );
      final accountColumns = await database
          .customSelect('PRAGMA table_info(local_accounts)')
          .get();
      expect(
        accountColumns.map((row) => row.read<String>('name')),
        contains('identity_digest'),
      );
    },
  );

  test(
    'relation rules expose structured identity and nullable end date',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final columns = await database
          .customSelect('PRAGMA table_info(schedule_relation_rules)')
          .get();
      final byName = {
        for (final row in columns) row.read<String>('name'): row.data,
      };
      expect(
        byName.keys,
        containsAll({
          'left_series_type',
          'left_series_id',
          'right_series_type',
          'right_series_id',
          'effective_from',
          'effective_through',
        }),
      );
      expect(byName['effective_through']!['notnull'], 0);
    },
  );

  test('schema one upgrades accounts without losing rows', () async {
    final directory = await Directory.systemTemp.createTemp(
      'ustc-migration-test',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = p.join(directory.path, 'legacy.sqlite');
    final legacy = sqlite.sqlite3.open(path);
    legacy.execute('''
CREATE TABLE local_accounts (
  id TEXT NOT NULL PRIMARY KEY,
  masked_hint TEXT NOT NULL,
  is_active INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
''');
    legacy.execute(
      "INSERT INTO local_accounts VALUES ('account', 'PB****0000', 1, 1, 1)",
    );
    legacy.execute('PRAGMA user_version = 1');
    legacy.dispose();

    final database = AppDatabase(NativeDatabase(File(path)));
    addTearDown(database.close);
    final account = await database.select(database.localAccounts).getSingle();

    expect(account.id, 'account');
    expect(account.identityDigest, isNull);
    final columns = await database
        .customSelect('PRAGMA table_info(local_accounts)')
        .get();
    expect(
      columns.map((row) => row.read<String>('name')),
      contains('identity_digest'),
    );
  });
}
