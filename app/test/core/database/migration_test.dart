import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:ustc_assistant_app/core/database/app_database.dart';

void main() {
  test(
    'schema version five creates the complete constrained database',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      expect(database.schemaVersion, 5);
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
          'jw_day_moves',
          'sync_runs',
          'action_logs',
          'undo_slot',
          'agent_permission_policies',
          'agent_settings',
          'agent_secrets',
          'agent_runs',
          'chat_messages',
          'tool_invocations',
          'conversation_summaries',
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
      // No default whole-day course move is seeded on a fresh database.
      final moveColumns = await database
          .customSelect('PRAGMA table_info(jw_day_moves)')
          .get();
      final moveColumnNames = moveColumns
          .map((row) => row.read<String>('name'))
          .toList();
      expect(
        moveColumnNames,
        containsAll({
          'id',
          'account_id',
          'source_date',
          'target_date',
          'created_at',
          'updated_at',
        }),
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
    // action_logs has existed since schema one; the v4 migration adds a
    // risk_level column to it, so the legacy seed must include the table.
    legacy.execute('''
CREATE TABLE action_logs (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT,
  source TEXT NOT NULL,
  action_type TEXT NOT NULL,
  result TEXT NOT NULL,
  safe_summary TEXT NOT NULL,
  occurred_at INTEGER NOT NULL
)
''');
    legacy.execute(
      "INSERT INTO local_accounts VALUES ('account', 'PB****0000', 1, 1, 1)",
    );
    legacy.execute('PRAGMA user_version = 1');
    legacy.close();

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

  // Regression for handoff §3 same-round: a real v2 -> v5 upgrade must create
  // all six agent tables, rebuild agent_permission_policies, create
  // jw_day_moves, and preserve representative business data that existed
  // before the migration. Drift's createAll path (fresh-DB test above) does
  // not exercise the onUpgrade `from < 3` / `from < 4` / `from < 5` branches.
  test(
    'schema two upgrades to five by adding the six agent tables and keeping business rows',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ustc-migration-v2-test',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = p.join(directory.path, 'legacy-v2.sqlite');
      final legacy = sqlite.sqlite3.open(path);
      legacy.execute('PRAGMA foreign_keys = ON');
      // A representative v2 schema: accounts with the v2 identity_digest column
      // plus one business table (tasks) that must survive the v3 migration.
      legacy.execute('''
CREATE TABLE local_accounts (
  id TEXT NOT NULL PRIMARY KEY,
  masked_hint TEXT NOT NULL,
  is_active INTEGER NOT NULL DEFAULT 0,
  identity_digest TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
''');
      legacy.execute(
        "INSERT INTO local_accounts VALUES ('account', 'PB****0000', 1, 'digest', 10, 10)",
      );
      legacy.execute('''
CREATE TABLE tasks (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  user_notes TEXT,
  state TEXT NOT NULL,
  blocked_reason TEXT,
  importance TEXT NOT NULL,
  deadline_at INTEGER,
  estimated_minutes INTEGER,
  tags_json TEXT NOT NULL,
  completed_at INTEGER,
  cancelled_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER,
  CHECK (state IN ('active','blocked','completed','cancelled')),
  CHECK ((state = 'completed' AND completed_at IS NOT NULL AND cancelled_at IS NULL) OR
         (state = 'cancelled' AND cancelled_at IS NOT NULL AND completed_at IS NULL) OR
         (state IN ('active','blocked') AND completed_at IS NULL AND cancelled_at IS NULL)),
  CHECK (estimated_minutes IS NULL OR estimated_minutes > 0)
)
''');
      legacy.execute(
        "INSERT INTO tasks VALUES "
        "('task-1','account','复习线性代数','期末范围','重点章节','active',NULL,'high',"
        "1759334400,120,'[]',NULL,NULL,20,20,NULL)",
      );
      // action_logs has existed since schema one; the v4 migration adds a
      // risk_level column to it, so the legacy seed must include the table.
      legacy.execute('''
CREATE TABLE action_logs (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT,
  source TEXT NOT NULL,
  action_type TEXT NOT NULL,
  result TEXT NOT NULL,
  safe_summary TEXT NOT NULL,
  occurred_at INTEGER NOT NULL
)
''');
      legacy.execute('PRAGMA user_version = 2');
      legacy.close();

      final database = AppDatabase(NativeDatabase(File(path)));
      addTearDown(database.close);

      // The v5 schema is in effect.
      expect(database.schemaVersion, 5);
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
          'agent_settings',
          'agent_secrets',
          'agent_runs',
          'chat_messages',
          'tool_invocations',
          'conversation_summaries',
          'jw_day_moves',
        }),
      );
      // The six new tables are empty after migration.
      expect(
        await database.select(database.agentSettings).get(),
        isEmpty,
      );
      expect(await database.select(database.agentRuns).get(), isEmpty);
      expect(await database.select(database.chatMessages).get(), isEmpty);
      expect(await database.select(database.toolInvocations).get(), isEmpty);
      expect(
        await database.select(database.conversationSummaries).get(),
        isEmpty,
      );
      // Representative pre-existing business data is preserved.
      final account = await database.select(database.localAccounts).getSingle();
      expect(account.id, 'account');
      expect(account.identityDigest, 'digest');
      final task = await database.select(database.tasks).getSingle();
      expect(task.id, 'task-1');
      expect(task.title, '复习线性代数');
      expect(task.state, 'active');
    },
  );

  // A real v4 -> v5 upgrade must create jw_day_moves without touching
  // representative business data. The fresh-DB test above does not exercise
  // the onUpgrade `from < 5` branch.
  test(
    'schema four upgrades to five by creating jw_day_moves and preserving rows',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ustc-migration-v4-test',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = p.join(directory.path, 'legacy-v4.sqlite');
      final legacy = sqlite.sqlite3.open(path);
      // A representative v4 schema: the account plus one business table that
      // must survive the v5 migration (the `from < 5` branch only creates
      // jw_day_moves).
      legacy.execute('''
CREATE TABLE local_accounts (
  id TEXT NOT NULL PRIMARY KEY,
  masked_hint TEXT NOT NULL,
  is_active INTEGER NOT NULL DEFAULT 0,
  identity_digest TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
''');
      legacy.execute(
        "INSERT INTO local_accounts VALUES ('account', 'PB****0000', 1, 'digest', 10, 10)",
      );
      legacy.execute('''
CREATE TABLE tasks (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  user_notes TEXT,
  state TEXT NOT NULL,
  blocked_reason TEXT,
  importance TEXT NOT NULL,
  deadline_at INTEGER,
  estimated_minutes INTEGER,
  tags_json TEXT NOT NULL,
  completed_at INTEGER,
  cancelled_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
)
''');
      legacy.execute(
        "INSERT INTO tasks VALUES "
        "('task-1','account','复习线性代数',NULL,NULL,'active',NULL,'high',"
        "NULL,NULL,'[]',NULL,NULL,20,20,NULL)",
      );
      legacy.execute('PRAGMA user_version = 4');
      legacy.close();

      final database = AppDatabase(NativeDatabase(File(path)));
      addTearDown(database.close);

      expect(database.schemaVersion, 5);
      final tables =
          (await database
                  .customSelect(
                    "SELECT name FROM sqlite_master WHERE type = 'table'",
                  )
                  .get())
              .map((row) => row.read<String>('name'))
              .toSet();
      expect(tables, contains('jw_day_moves'));
      // No default move is seeded by the migration.
      expect(
        await database
            .customSelect('SELECT COUNT(*) AS n FROM jw_day_moves')
            .getSingle()
            .then((row) => row.read<int>('n')),
        0,
      );
      final account = await database.select(database.localAccounts).getSingle();
      expect(account.id, 'account');
      final task = await database.select(database.tasks).getSingle();
      expect(task.id, 'task-1');
      expect(task.title, '复习线性代数');
    },
  );

  test(
    'jw_day_moves enforces account cascade, unique source date and source != target',
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
      await database.into(database.jwDayMoves).insert(
        JwDayMovesCompanion.insert(
          id: 'move-1',
          accountId: 'account',
          sourceDate: '2026-08-03',
          targetDate: '2026-08-04',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      // Unique (accountId, sourceDate): a second move from the same source
      // date is rejected even with a fresh id.
      await expectLater(
        database.into(database.jwDayMoves).insert(
          JwDayMovesCompanion.insert(
            id: 'move-2',
            accountId: 'account',
            sourceDate: '2026-08-03',
            targetDate: '2026-08-05',
            createdAt: 2,
            updatedAt: 2,
          ),
        ),
        throwsA(isA<sqlite.SqliteException>()),
      );
      // source date must differ from target date.
      await expectLater(
        database.into(database.jwDayMoves).insert(
          JwDayMovesCompanion.insert(
            id: 'move-3',
            accountId: 'account',
            sourceDate: '2026-08-06',
            targetDate: '2026-08-06',
            createdAt: 3,
            updatedAt: 3,
          ),
        ),
        throwsA(isA<sqlite.SqliteException>()),
      );
      // A second account can move the same source date.
      await database
          .into(database.localAccounts)
          .insert(
            LocalAccountsCompanion.insert(
              id: 'other',
              maskedHint: 'PB****1111',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await database.into(database.jwDayMoves).insert(
        JwDayMovesCompanion.insert(
          id: 'move-4',
          accountId: 'other',
          sourceDate: '2026-08-03',
          targetDate: '2026-08-05',
          createdAt: 2,
          updatedAt: 2,
        ),
      );
      expect(await database.select(database.jwDayMoves).get(), hasLength(2));
      // Deleting the account cascades its move rows.
      await (database.delete(
        database.localAccounts,
      )..where((row) => row.id.equals('account'))).go();
      final remaining = await database.select(database.jwDayMoves).get();
      expect(remaining, hasLength(1));
      expect(remaining.single.accountId, 'other');
    },
  );
}
