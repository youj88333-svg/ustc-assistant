import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:ustc_assistant_app/core/database/app_database.dart';

// Creates the schedule/task table chain that the Schema 7 transform rebuilds
// (calendar_event_series, calendar_events, calendar_event_occurrence_exceptions,
// tasks, plan_blocks, task_event_links, schedule_relations, reminders) using
// the v5-era definitions, with no rows. Every real database at schema v1-v6
// already carries these tables (they were introduced by the schedule/task
// schema commit and created by onCreate), so any fixture that upgrades a
// pre-v7 database through the production AppDatabase must include them -- the
// Schema 7 onUpgrade branch runs for every `from < 7` and would otherwise fail
// addColumn / alterTable against a missing table. CREATE TABLE IF NOT EXISTS
// keeps this safe to call on fixtures that already define a subset (e.g. tasks
// / plan_blocks / a looser schedule_relations): the existing definition is
// retained and only the missing tables are added.
void createScheduleAndTaskTablesForPreV7Fixture(sqlite.Database legacy) {
  legacy.execute('''
CREATE TABLE IF NOT EXISTS calendar_event_series (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  event_type TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  timezone TEXT NOT NULL,
  all_day INTEGER NOT NULL DEFAULT 0,
  start_at INTEGER,
  duration_minutes INTEGER,
  anchor_start_date TEXT,
  duration_days INTEGER,
  recurrence_json TEXT NOT NULL,
  effective_from TEXT,
  effective_through TEXT,
  location_name TEXT,
  importance TEXT NOT NULL DEFAULT 'normal',
  color TEXT,
  completion_policy TEXT NOT NULL DEFAULT 'auto_after_end',
  tags_json TEXT NOT NULL DEFAULT '[]',
  user_notes TEXT,
  deleted_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  CHECK ((all_day = 0 AND start_at IS NOT NULL AND duration_minutes > 0
          AND anchor_start_date IS NULL AND duration_days IS NULL) OR
         (all_day = 1 AND start_at IS NULL AND duration_minutes IS NULL
          AND anchor_start_date IS NOT NULL AND duration_days > 0)),
  CHECK (status IN ('active','tentative','cancelled','completed','skipped','hidden')),
  CHECK (effective_through IS NULL OR effective_from IS NULL
         OR effective_through >= effective_from)
)
''');
  legacy.execute('''
CREATE TABLE IF NOT EXISTS calendar_events (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  source TEXT NOT NULL,
  external_id TEXT,
  source_series_external_id TEXT,
  personal_series_id TEXT REFERENCES calendar_event_series(id) ON DELETE CASCADE,
  occurrence_key TEXT,
  title TEXT NOT NULL,
  description TEXT,
  type TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  start_at INTEGER,
  end_at INTEGER,
  all_day INTEGER NOT NULL,
  start_date TEXT,
  end_date_exclusive TEXT,
  timezone TEXT NOT NULL,
  location_name TEXT,
  building_name TEXT,
  campus_name TEXT,
  participants_json TEXT NOT NULL DEFAULT '[]',
  source_details_json TEXT NOT NULL DEFAULT '{}',
  importance TEXT NOT NULL DEFAULT 'normal',
  completion_policy TEXT NOT NULL DEFAULT 'auto_complete',
  completed_at INTEGER,
  color TEXT,
  tags_json TEXT NOT NULL DEFAULT '[]',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER,
  CHECK ((all_day = 0 AND start_at IS NOT NULL AND end_at IS NOT NULL
          AND end_at > start_at AND start_date IS NULL
          AND end_date_exclusive IS NULL) OR
         (all_day = 1 AND start_at IS NULL AND end_at IS NULL
          AND start_date IS NOT NULL AND end_date_exclusive IS NOT NULL
          AND end_date_exclusive > start_date)),
  CHECK (type IN ('course','exam','second_class','personal','entertainment','meal',
                  'campus_affair','travel','study','system')),
  CHECK (status IN ('active','tentative','cancelled','completed','skipped','hidden'))
)
''');
  legacy.execute('''
CREATE TABLE IF NOT EXISTS calendar_event_occurrence_exceptions (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  series_id TEXT NOT NULL REFERENCES calendar_event_series(id) ON DELETE CASCADE,
  occurrence_key TEXT NOT NULL,
  original_start_at INTEGER,
  original_start_date TEXT,
  kind TEXT NOT NULL,
  overridden_fields_json TEXT NOT NULL DEFAULT '[]',
  override_json TEXT NOT NULL,
  status TEXT,
  orphaned INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(account_id, series_id, occurrence_key),
  CHECK (kind IN ('override','cancelled')),
  CHECK ((original_start_at IS NOT NULL) != (original_start_date IS NOT NULL))
)
''');
  legacy.execute('''
CREATE TABLE IF NOT EXISTS tasks (
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
  legacy.execute('''
CREATE TABLE IF NOT EXISTS plan_blocks (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  title TEXT,
  start_at INTEGER NOT NULL,
  end_at INTEGER NOT NULL,
  status TEXT NOT NULL,
  locked INTEGER NOT NULL DEFAULT 0,
  review_note TEXT,
  reviewed_at INTEGER,
  rescheduled_to_plan_block_id TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
)
''');
  legacy.execute('''
CREATE TABLE IF NOT EXISTS task_event_links (
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  event_id TEXT NOT NULL REFERENCES calendar_events(id) ON DELETE CASCADE,
  relation_type TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, task_id, event_id)
)
''');
  legacy.execute('''
CREATE TABLE IF NOT EXISTS schedule_relations (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  source TEXT NOT NULL DEFAULT 'user',
  external_id TEXT,
  relation_type TEXT NOT NULL DEFAULT 'conflict',
  primary_entity_type TEXT,
  primary_entity_id TEXT,
  related_entity_type TEXT,
  related_entity_id TEXT,
  left_kind TEXT,
  left_id TEXT,
  right_kind TEXT,
  right_id TEXT,
  left_event_id TEXT REFERENCES calendar_events(id) ON DELETE CASCADE,
  left_plan_block_id TEXT REFERENCES plan_blocks(id) ON DELETE CASCADE,
  right_event_id TEXT REFERENCES calendar_events(id) ON DELETE CASCADE,
  right_plan_block_id TEXT REFERENCES plan_blocks(id) ON DELETE CASCADE,
  conflict_state TEXT,
  reason TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
''');
  legacy.execute('''
CREATE TABLE IF NOT EXISTS reminders (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  target_type TEXT NOT NULL,
  target_id TEXT NOT NULL,
  event_id TEXT REFERENCES calendar_events(id) ON DELETE CASCADE,
  task_id TEXT REFERENCES tasks(id) ON DELETE CASCADE,
  plan_block_id TEXT REFERENCES plan_blocks(id) ON DELETE CASCADE,
  offset_minutes INTEGER,
  trigger_at INTEGER NOT NULL,
  state TEXT NOT NULL,
  failure_code TEXT,
  delivered_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
''');
}

void main() {
  test(
    'schema version seven creates the complete constrained database',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      expect(database.schemaVersion, 7);
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
      // Schema six adds a nullable error_code to tool_invocations.
      final toolColumns = await database
          .customSelect("PRAGMA table_info('tool_invocations')")
          .get();
      final toolColumnNames = toolColumns
          .map((row) => row.read<String>('name'))
          .toList();
      expect(toolColumnNames, contains('error_code'));
      final errorCodeMeta =
          toolColumns.firstWhere((row) => row.read<String>('name') == 'error_code');
      expect(errorCodeMeta.read<int>('notnull'), 0);
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
    // A real v1 database created after the schedule/task schema commit
    // already carries the schedule/task tables; the Schema 7 branch now runs
    // for every `from < 7`, so the fixture must include them.
    createScheduleAndTaskTablesForPreV7Fixture(legacy);
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
      // A real v2 database carries the schedule/task tables; the Schema 7
      // branch now runs for every `from < 7`, so the fixture must include
      // them. IF NOT EXISTS preserves the fixture's existing tasks table.
      createScheduleAndTaskTablesForPreV7Fixture(legacy);
      legacy.execute('PRAGMA user_version = 2');
      legacy.close();

      final database = AppDatabase(NativeDatabase(File(path)));
      addTearDown(database.close);

      // The v7 schema is in effect.
      expect(database.schemaVersion, 7);
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
      // A real v4 database has tool_invocations (created at v3). The schema-six
      // migration (from=4) adds error_code to it, so the fixture must carry the
      // v5 definition (without error_code) for the addColumn to apply.
      legacy.execute('''
CREATE TABLE agent_runs (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  model TEXT NOT NULL,
  status TEXT NOT NULL,
  error_code TEXT,
  input_tokens INTEGER,
  output_tokens INTEGER,
  started_at INTEGER NOT NULL,
  finished_at INTEGER,
  UNIQUE(id, account_id)
)
''');
      legacy.execute('''
CREATE TABLE tool_invocations (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL,
  tool_name TEXT NOT NULL,
  status TEXT NOT NULL,
  safe_arguments_summary TEXT NOT NULL,
  safe_result_summary TEXT NOT NULL,
  started_at INTEGER NOT NULL,
  finished_at INTEGER,
  FOREIGN KEY (run_id, account_id) REFERENCES agent_runs(id, account_id) ON DELETE CASCADE
)
''');
      // A real v4 database carries the schedule/task tables; the Schema 7
      // branch now runs for every `from < 7`, so the fixture must include
      // them. IF NOT EXISTS preserves the fixture's existing tasks table.
      createScheduleAndTaskTablesForPreV7Fixture(legacy);
      legacy.execute('PRAGMA user_version = 4');
      legacy.close();

      final database = AppDatabase(NativeDatabase(File(path)));
      addTearDown(database.close);

      expect(database.schemaVersion, 7);
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

  // Regression for this repair round: schema six adds a nullable error_code
  // to tool_invocations. The fresh-schema test above checks a clean creation;
  // this one exercises the onUpgrade `from < 6` branch on a real v5 fixture and
  // verifies the migrated error_code is null while representative business
  // data (account, run, chat message, invocation, Task, PlanBlock, Relation)
  // survives untouched.
  test(
    'schema five upgrades to six by adding tool_invocations.error_code and keeping business rows',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ustc-migration-v5-test',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = p.join(directory.path, 'legacy-v5.sqlite');
      final legacy = sqlite.sqlite3.open(path);
      legacy.execute('PRAGMA foreign_keys = ON');
      // Representative v5 schema. The account is created first because the
      // agent/business tables reference it.
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
        "('task-1','account','复习线性代数',NULL,NULL,'active',NULL,'high',"
        "1759334400,120,'[]',NULL,NULL,20,20,NULL)",
      );
      legacy.execute('''
CREATE TABLE plan_blocks (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  title TEXT,
  start_at INTEGER NOT NULL,
  end_at INTEGER NOT NULL,
  status TEXT NOT NULL,
  locked INTEGER NOT NULL DEFAULT 0,
  review_note TEXT,
  reviewed_at INTEGER,
  rescheduled_to_plan_block_id TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER,
  CHECK (end_at > start_at),
  CHECK (status IN ('suggested','accepted','done','skipped','rescheduled','cancelled')),
  CHECK ((status IN ('suggested','accepted') AND reviewed_at IS NULL) OR
         (status NOT IN ('suggested','accepted') AND reviewed_at IS NOT NULL)),
  CHECK ((status = 'rescheduled' AND rescheduled_to_plan_block_id IS NOT NULL) OR
         (status != 'rescheduled' AND rescheduled_to_plan_block_id IS NULL))
)
''');
      legacy.execute(
        "INSERT INTO plan_blocks VALUES "
        "('pb-1','account','task-1',NULL,100,200,'accepted',0,NULL,NULL,NULL,30,30,NULL)",
      );
      legacy.execute(
        "INSERT INTO plan_blocks VALUES "
        "('pb-2','account','task-1',NULL,300,400,'accepted',0,NULL,NULL,NULL,30,30,NULL)",
      );
      legacy.execute('''
CREATE TABLE schedule_relations (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  source TEXT NOT NULL DEFAULT 'user',
  external_id TEXT,
  relation_type TEXT NOT NULL DEFAULT 'conflict',
  primary_entity_type TEXT,
  primary_entity_id TEXT,
  related_entity_type TEXT,
  related_entity_id TEXT,
  left_kind TEXT,
  left_id TEXT,
  right_kind TEXT,
  right_id TEXT,
  left_event_id TEXT,
  left_plan_block_id TEXT REFERENCES plan_blocks(id) ON DELETE CASCADE,
  right_event_id TEXT,
  right_plan_block_id TEXT REFERENCES plan_blocks(id) ON DELETE CASCADE,
  conflict_state TEXT,
  reason TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
''');
      legacy.execute(
        "INSERT INTO schedule_relations "
        "('id','account_id','source','external_id','relation_type',"
        "'primary_entity_type','primary_entity_id','related_entity_type',"
        "'related_entity_id','left_kind','left_id','right_kind','right_id',"
        "'left_event_id','left_plan_block_id','right_event_id','right_plan_block_id',"
        "'conflict_state','reason','created_at','updated_at') VALUES "
        "('rel-1','account','user',NULL,'conflict',NULL,NULL,NULL,NULL,"
        "'plan_block','pb-1','plan_block','pb-2',NULL,'pb-1',NULL,'pb-2',"
        "'conflict','reason',40,40)",
      );
      legacy.execute('''
CREATE TABLE agent_runs (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  model TEXT NOT NULL,
  status TEXT NOT NULL,
  error_code TEXT,
  input_tokens INTEGER,
  output_tokens INTEGER,
  started_at INTEGER NOT NULL,
  finished_at INTEGER,
  UNIQUE(id, account_id)
)
''');
      legacy.execute(
        "INSERT INTO agent_runs VALUES "
        "('run-1','account','deepseek-v4-flash','running',NULL,NULL,NULL,50,NULL)",
      );
      legacy.execute('''
CREATE TABLE chat_messages (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  run_id TEXT,
  ordinal INTEGER NOT NULL,
  role TEXT NOT NULL,
  state TEXT NOT NULL,
  content TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(account_id, ordinal),
  FOREIGN KEY (run_id, account_id) REFERENCES agent_runs(id, account_id) ON DELETE CASCADE
)
''');
      legacy.execute(
        "INSERT INTO chat_messages VALUES "
        "('msg-1','account','run-1',1,'user','completed','你好',60,60)",
      );
      // v5 tool_invocations has NO error_code column.
      legacy.execute('''
CREATE TABLE tool_invocations (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL,
  tool_name TEXT NOT NULL,
  status TEXT NOT NULL,
  safe_arguments_summary TEXT NOT NULL,
  safe_result_summary TEXT NOT NULL,
  started_at INTEGER NOT NULL,
  finished_at INTEGER,
  FOREIGN KEY (run_id, account_id) REFERENCES agent_runs(id, account_id) ON DELETE CASCADE
)
''');
      legacy.execute(
        "INSERT INTO tool_invocations VALUES "
        "('inv-1','account','run-1','get_schedule','running','args','',70,NULL)",
      );
      // A real v5 database carries the full schedule/task table chain; the
      // Schema 7 branch now runs for every `from < 7`, so the fixture must
      // include the tables it rebuilds. IF NOT EXISTS preserves the fixture's
      // existing tasks / plan_blocks / schedule_relations definitions and only
      // adds the missing calendar_event_series / calendar_events /
      // calendar_event_occurrence_exceptions / task_event_links / reminders.
      createScheduleAndTaskTablesForPreV7Fixture(legacy);
      legacy.execute('PRAGMA user_version = 5');
      legacy.close();

      final database = AppDatabase(NativeDatabase(File(path)));
      addTearDown(database.close);

      // The v7 schema is in effect and the new column exists and is nullable.
      expect(database.schemaVersion, 7);
      final columns = await database.customSelect(
        "PRAGMA table_info('tool_invocations')",
      ).get();
      final byName = {
        for (final row in columns) row.read<String>('name'): row.data,
      };
      expect(byName.keys, contains('error_code'));
      expect(byName['error_code']!['notnull'], 0);

      // Migrated business rows are preserved.
      final account = await database.select(database.localAccounts).getSingle();
      expect(account.id, 'account');
      expect(account.identityDigest, 'digest');
      final run = await database.select(database.agentRuns).getSingle();
      expect(run.id, 'run-1');
      final message = await database.select(database.chatMessages).getSingle();
      expect(message.id, 'msg-1');
      final invocation = await database.select(database.toolInvocations).getSingle();
      expect(invocation.id, 'inv-1');
      expect(invocation.errorCode, isNull);
      final task = await database.select(database.tasks).getSingle();
      expect(task.id, 'task-1');
      expect(await database.select(database.planBlocks).get(), hasLength(2));
      final relation = await database
          .select(database.scheduleRelations)
          .getSingle();
      expect(relation.id, 'rel-1');
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

  // The highest-impact migration in the plan: Schema 6 -> 7 must preserve
  // every Schema 6 row losslessly while installing the new recurring
  // occurrence target columns and CHECK constraints. This uses a real Schema 6
  // fixture (one account, one series, one ordinary event, one TaskEventLink,
  // one conflict relation, one reminder) upgraded through the production
  // AppDatabase, then verifies row survival, the target_id transplant, the
  // series reminder default, empty foreign keys, and correct rejection of
  // invalid new rows.
  test(
    'schema six upgrades to seven preserving rows and installing recurring targets',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ustc-migration-v6-test',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = p.join(directory.path, 'legacy-v6.sqlite');
      final legacy = sqlite.sqlite3.open(path);
      legacy.execute('PRAGMA foreign_keys = ON');
      // ---- Schema 6 fixture, in FK dependency order ----
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
        "INSERT INTO local_accounts VALUES ('account', 'PB****0000', 1, 'digest', 1, 1)",
      );
      legacy.execute('''
CREATE TABLE calendar_event_series (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  event_type TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  timezone TEXT NOT NULL,
  all_day INTEGER NOT NULL DEFAULT 0,
  start_at INTEGER,
  duration_minutes INTEGER,
  anchor_start_date TEXT,
  duration_days INTEGER,
  recurrence_json TEXT NOT NULL,
  effective_from TEXT,
  effective_through TEXT,
  location_name TEXT,
  importance TEXT NOT NULL DEFAULT 'normal',
  color TEXT,
  completion_policy TEXT NOT NULL DEFAULT 'auto_after_end',
  tags_json TEXT NOT NULL DEFAULT '[]',
  user_notes TEXT,
  deleted_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  CHECK ((all_day = 0 AND start_at IS NOT NULL AND duration_minutes > 0
          AND anchor_start_date IS NULL AND duration_days IS NULL) OR
         (all_day = 1 AND start_at IS NULL AND duration_minutes IS NULL
          AND anchor_start_date IS NOT NULL AND duration_days > 0)),
  CHECK (status IN ('active','tentative','cancelled','completed','skipped','hidden')),
  CHECK (effective_through IS NULL OR effective_from IS NULL
         OR effective_through >= effective_from)
)
''');
      // Timed series stores the schema-six default (no reminder_offsets_json yet).
      legacy.execute(
        "INSERT INTO calendar_event_series VALUES "
        "('series-1','account','每周复习',NULL,'personal','active','Asia/Shanghai',0,"
        "1000,60,NULL,NULL,'{\"frequency\":\"weekly\"}',NULL,NULL,NULL,'normal',NULL,"
        "'auto_after_end','[]',NULL,NULL,1,1)",
      );
      legacy.execute('''
CREATE TABLE calendar_events (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  source TEXT NOT NULL,
  external_id TEXT,
  source_series_external_id TEXT,
  personal_series_id TEXT REFERENCES calendar_event_series(id) ON DELETE CASCADE,
  occurrence_key TEXT,
  title TEXT NOT NULL,
  description TEXT,
  type TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  start_at INTEGER,
  end_at INTEGER,
  all_day INTEGER NOT NULL,
  start_date TEXT,
  end_date_exclusive TEXT,
  timezone TEXT NOT NULL,
  location_name TEXT,
  building_name TEXT,
  campus_name TEXT,
  participants_json TEXT NOT NULL DEFAULT '[]',
  source_details_json TEXT NOT NULL DEFAULT '{}',
  importance TEXT NOT NULL DEFAULT 'normal',
  completion_policy TEXT NOT NULL DEFAULT 'auto_complete',
  completed_at INTEGER,
  color TEXT,
  tags_json TEXT NOT NULL DEFAULT '[]',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER,
  CHECK ((all_day = 0 AND start_at IS NOT NULL AND end_at IS NOT NULL
          AND end_at > start_at AND start_date IS NULL
          AND end_date_exclusive IS NULL) OR
         (all_day = 1 AND start_at IS NULL AND end_at IS NULL
          AND start_date IS NOT NULL AND end_date_exclusive IS NOT NULL
          AND end_date_exclusive > start_date)),
  CHECK (type IN ('course','exam','second_class','personal','entertainment','meal',
                  'campus_affair','travel','study','system')),
  CHECK (status IN ('active','tentative','cancelled','completed','skipped','hidden'))
)
''');
      legacy.execute(
        "INSERT INTO calendar_events VALUES "
        "('ev-1','account','user',NULL,NULL,NULL,NULL,'一次考试',NULL,'personal',"
        "'active',1000,2000,0,NULL,NULL,'Asia/Shanghai',NULL,NULL,NULL,'[]','{}',"
        "'normal','auto_complete',NULL,NULL,'[]',1,1,NULL)",
      );
      legacy.execute('''
CREATE TABLE calendar_event_occurrence_exceptions (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  series_id TEXT NOT NULL REFERENCES calendar_event_series(id) ON DELETE CASCADE,
  occurrence_key TEXT NOT NULL,
  original_start_at INTEGER,
  original_start_date TEXT,
  kind TEXT NOT NULL,
  overridden_fields_json TEXT NOT NULL DEFAULT '[]',
  override_json TEXT NOT NULL,
  status TEXT,
  orphaned INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(account_id, series_id, occurrence_key),
  CHECK (kind IN ('override','cancelled')),
  CHECK ((original_start_at IS NOT NULL) != (original_start_date IS NOT NULL))
)
''');
      legacy.execute(
        "INSERT INTO calendar_event_occurrence_exceptions VALUES "
        "('occ-1','account','series-1','2026-08-03T18:20:00+08:00',1000,NULL,"
        "'override','[]','{}',NULL,0,NULL,1,1)",
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
        "('task-1','account','复习','todo',NULL,'active',NULL,'high',NULL,NULL,'[]',"
        "NULL,NULL,1,1,NULL)",
      );
      legacy.execute('''
CREATE TABLE plan_blocks (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  title TEXT,
  start_at INTEGER NOT NULL,
  end_at INTEGER NOT NULL,
  status TEXT NOT NULL,
  locked INTEGER NOT NULL DEFAULT 0,
  review_note TEXT,
  reviewed_at INTEGER,
  rescheduled_to_plan_block_id TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
)
''');
      // Schema 6 task_event_links: PK (account_id, task_id, event_id).
      legacy.execute('''
CREATE TABLE task_event_links (
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  event_id TEXT NOT NULL REFERENCES calendar_events(id) ON DELETE CASCADE,
  relation_type TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, task_id, event_id)
)
''');
      legacy.execute(
        "INSERT INTO task_event_links VALUES ('account','task-1','ev-1','related',1)",
      );
      legacy.execute('''
CREATE TABLE schedule_relations (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  source TEXT NOT NULL DEFAULT 'user',
  external_id TEXT,
  relation_type TEXT NOT NULL DEFAULT 'conflict',
  primary_entity_type TEXT,
  primary_entity_id TEXT,
  related_entity_type TEXT,
  related_entity_id TEXT,
  left_kind TEXT,
  left_id TEXT,
  right_kind TEXT,
  right_id TEXT,
  left_event_id TEXT REFERENCES calendar_events(id) ON DELETE CASCADE,
  left_plan_block_id TEXT REFERENCES plan_blocks(id) ON DELETE CASCADE,
  right_event_id TEXT REFERENCES calendar_events(id) ON DELETE CASCADE,
  right_plan_block_id TEXT REFERENCES plan_blocks(id) ON DELETE CASCADE,
  conflict_state TEXT,
  reason TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(account_id, left_kind, left_id, right_kind, right_id),
  UNIQUE(account_id, source, external_id)
)
''');
      // A schema-six conflict relation with event-backed participants.
      legacy.execute(
        "INSERT INTO schedule_relations "
        "('id','account_id','source','external_id','relation_type',"
        "'primary_entity_type','primary_entity_id','related_entity_type',"
        "'related_entity_id','left_kind','left_id','right_kind','right_id',"
        "'left_event_id','left_plan_block_id','right_event_id','right_plan_block_id',"
        "'conflict_state','reason','created_at','updated_at') VALUES "
        "('rel-1','account','user',NULL,'conflict',NULL,NULL,NULL,NULL,"
        "'event','ev-1','event','ev-1','ev-1',NULL,'ev-1',NULL,"
        "'conflict','reason',1,1)",
      );
      legacy.execute('''
CREATE TABLE reminders (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  target_type TEXT NOT NULL,
  target_id TEXT NOT NULL,
  event_id TEXT REFERENCES calendar_events(id) ON DELETE CASCADE,
  task_id TEXT REFERENCES tasks(id) ON DELETE CASCADE,
  plan_block_id TEXT REFERENCES plan_blocks(id) ON DELETE CASCADE,
  offset_minutes INTEGER,
  trigger_at INTEGER NOT NULL,
  state TEXT NOT NULL,
  failure_code TEXT,
  delivered_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(account_id, target_type, target_id, trigger_at),
  CHECK (target_type IN ('event','task','plan_block')),
  CHECK (state IN ('desired','delivered','cancelled','missed','failed')),
  CHECK ((target_type = 'event' AND event_id = target_id
          AND task_id IS NULL AND plan_block_id IS NULL) OR
         (target_type = 'task' AND task_id = target_id
          AND event_id IS NULL AND plan_block_id IS NULL) OR
         (target_type = 'plan_block' AND plan_block_id = target_id
          AND event_id IS NULL AND task_id IS NULL))
)
''');
      legacy.execute(
        "INSERT INTO reminders VALUES "
        "('rem-1','account','event','ev-1','ev-1',NULL,NULL,15,900,'desired',NULL,NULL,1,1)",
      );
      legacy.execute('PRAGMA user_version = 6');
      legacy.close();

      // ---- Upgrade through the production AppDatabase ----
      final database = AppDatabase(NativeDatabase(File(path)));
      addTearDown(database.close);

      expect(database.schemaVersion, 7);

      // 1) All old rows survive with their values.
      final account = await database.select(database.localAccounts).getSingle();
      expect(account.id, 'account');
      final series = await database
          .select(database.calendarEventSeries)
          .getSingle();
      expect(series.id, 'series-1');
      expect(series.title, '每周复习');
      final event = await database.select(database.calendarEvents).getSingle();
      expect(event.id, 'ev-1');
      final task = await database.select(database.tasks).getSingle();
      expect(task.id, 'task-1');

      // 2) TaskEventLink.targetId == old eventId, and the event backing survives.
      final linkRow = await database
          .customSelect(
            'SELECT target_id, event_id, occurrence_exception_id '
            'FROM task_event_links WHERE task_id = ?',
            variables: [Variable<String>('task-1')],
          )
          .getSingle();
      expect(linkRow.read<String>('target_id'), 'ev-1');
      expect(linkRow.read<String>('event_id'), 'ev-1');
      expect(linkRow.readNullable<String>('occurrence_exception_id'), isNull);

      // 3) Series reminder default: timed series -> [15].
      final seriesRow = await database
          .customSelect(
            'SELECT reminder_offsets_json FROM calendar_event_series WHERE id = ?',
            variables: [Variable<String>('series-1')],
          )
          .getSingle();
      expect(seriesRow.read<String>('reminder_offsets_json'), '[15]');

      // 4) Old event-backed targets have occurrence-exception columns NULL.
      final relation = await database
          .customSelect(
            'SELECT left_occurrence_exception_id, right_occurrence_exception_id '
            'FROM schedule_relations WHERE id = ?',
            variables: [Variable<String>('rel-1')],
          )
          .getSingle();
      expect(relation.readNullable<String>('left_occurrence_exception_id'), isNull);
      expect(relation.readNullable<String>('right_occurrence_exception_id'), isNull);
      final reminder = await database
          .customSelect(
            'SELECT occurrence_exception_id FROM reminders WHERE id = ?',
            variables: [Variable<String>('rem-1')],
          )
          .getSingle();
      expect(reminder.readNullable<String>('occurrence_exception_id'), isNull);

      // 5) foreign_key_check returns no rows.
      final violations = await database
          .customSelect('PRAGMA foreign_key_check')
          .get();
      expect(violations, isEmpty);

      // 6) Invalid new rows fail against the installed Schema 7 constraints.
      // Unbacked task event link (no event nor occurrence exception).
      await expectLater(
        database.into(database.taskEventLinks).insert(
          TaskEventLinksCompanion.insert(
            accountId: 'account',
            taskId: 'task-1',
            targetId: 'unbacked',
            relationType: 'related',
            createdAt: 1,
          ),
        ),
        throwsA(isA<sqlite.SqliteException>()),
      );
      // Dual-backed reminder is rejected.
      await expectLater(
        database.into(database.reminders).insert(
          RemindersCompanion.insert(
            id: 'rem-bad',
            accountId: 'account',
            targetType: 'event',
            targetId: 'ev-1',
            eventId: const Value('ev-1'),
            occurrenceExceptionId: const Value('occ-1'),
            triggerAt: 900,
            state: 'desired',
            createdAt: 1,
            updatedAt: 1,
          ),
        ),
        throwsA(isA<sqlite.SqliteException>()),
      );
    },
  );

  // C1 regression: a real Schema 5 database (the highest-impact pre-v6 case)
  // upgraded against the v7 binary must run the full Schema 7 transform.
  // Before the guard fix, `onUpgrade` was called once with from=5, the
  // `from >= 6 && from < 7` branch was skipped entirely, and every Schema 7
  // column/CHECK on calendar_event_series, task_event_links, schedule_relations
  // and reminders was missing -- so the live DB diverged from the generated
  // v7 definitions. This fixture seeds a timed series, a v5 task_event_links
  // row (PK account_id, task_id, event_id) and a v5 reminders row (no
  // occurrence_exception_id), then asserts the v7 transform applied
  // losslessly: schemaVersion 7, series reminder default [15], the target_id
  // transplant, NULL occurrence columns, empty foreign_key_check, and the
  // installed v7 CHECK constraints rejecting invalid new rows.
  test(
    'schema five upgrades to seven preserving rows and installing recurring targets',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ustc-migration-v5-to-v7-test',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = p.join(directory.path, 'legacy-v5-to-v7.sqlite');
      final legacy = sqlite.sqlite3.open(path);
      legacy.execute('PRAGMA foreign_keys = ON');
      // ---- Schema 5 fixture, in FK dependency order ----
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
        "INSERT INTO local_accounts VALUES ('account', 'PB****0000', 1, 'digest', 1, 1)",
      );
      // Schema 5 calendar_event_series has NO reminder_offsets_json column.
      legacy.execute('''
CREATE TABLE calendar_event_series (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  event_type TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  timezone TEXT NOT NULL,
  all_day INTEGER NOT NULL DEFAULT 0,
  start_at INTEGER,
  duration_minutes INTEGER,
  anchor_start_date TEXT,
  duration_days INTEGER,
  recurrence_json TEXT NOT NULL,
  effective_from TEXT,
  effective_through TEXT,
  location_name TEXT,
  importance TEXT NOT NULL DEFAULT 'normal',
  color TEXT,
  completion_policy TEXT NOT NULL DEFAULT 'auto_after_end',
  tags_json TEXT NOT NULL DEFAULT '[]',
  user_notes TEXT,
  deleted_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  CHECK ((all_day = 0 AND start_at IS NOT NULL AND duration_minutes > 0
          AND anchor_start_date IS NULL AND duration_days IS NULL) OR
         (all_day = 1 AND start_at IS NULL AND duration_minutes IS NULL
          AND anchor_start_date IS NOT NULL AND duration_days > 0)),
  CHECK (status IN ('active','tentative','cancelled','completed','skipped','hidden')),
  CHECK (effective_through IS NULL OR effective_from IS NULL
         OR effective_through >= effective_from)
)
''');
      // Timed series: the migration must backfill reminder_offsets_json='[15]'.
      legacy.execute(
        "INSERT INTO calendar_event_series VALUES "
        "('series-1','account','每周复习',NULL,'personal','active','Asia/Shanghai',0,"
        "1000,60,NULL,NULL,'{\"frequency\":\"weekly\"}',NULL,NULL,NULL,'normal',NULL,"
        "'auto_after_end','[]',NULL,NULL,1,1)",
      );
      legacy.execute('''
CREATE TABLE calendar_events (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  source TEXT NOT NULL,
  external_id TEXT,
  source_series_external_id TEXT,
  personal_series_id TEXT REFERENCES calendar_event_series(id) ON DELETE CASCADE,
  occurrence_key TEXT,
  title TEXT NOT NULL,
  description TEXT,
  type TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  start_at INTEGER,
  end_at INTEGER,
  all_day INTEGER NOT NULL,
  start_date TEXT,
  end_date_exclusive TEXT,
  timezone TEXT NOT NULL,
  location_name TEXT,
  building_name TEXT,
  campus_name TEXT,
  participants_json TEXT NOT NULL DEFAULT '[]',
  source_details_json TEXT NOT NULL DEFAULT '{}',
  importance TEXT NOT NULL DEFAULT 'normal',
  completion_policy TEXT NOT NULL DEFAULT 'auto_complete',
  completed_at INTEGER,
  color TEXT,
  tags_json TEXT NOT NULL DEFAULT '[]',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER,
  CHECK ((all_day = 0 AND start_at IS NOT NULL AND end_at IS NOT NULL
          AND end_at > start_at AND start_date IS NULL
          AND end_date_exclusive IS NULL) OR
         (all_day = 1 AND start_at IS NULL AND end_at IS NULL
          AND start_date IS NOT NULL AND end_date_exclusive IS NOT NULL
          AND end_date_exclusive > start_date)),
  CHECK (type IN ('course','exam','second_class','personal','entertainment','meal',
                  'campus_affair','travel','study','system')),
  CHECK (status IN ('active','tentative','cancelled','completed','skipped','hidden'))
)
''');
      legacy.execute(
        "INSERT INTO calendar_events VALUES "
        "('ev-1','account','user',NULL,NULL,NULL,NULL,'一次考试',NULL,'personal',"
        "'active',1000,2000,0,NULL,NULL,'Asia/Shanghai',NULL,NULL,NULL,'[]','{}',"
        "'normal','auto_complete',NULL,NULL,'[]',1,1,NULL)",
      );
      legacy.execute('''
CREATE TABLE calendar_event_occurrence_exceptions (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  series_id TEXT NOT NULL REFERENCES calendar_event_series(id) ON DELETE CASCADE,
  occurrence_key TEXT NOT NULL,
  original_start_at INTEGER,
  original_start_date TEXT,
  kind TEXT NOT NULL,
  overridden_fields_json TEXT NOT NULL DEFAULT '[]',
  override_json TEXT NOT NULL,
  status TEXT,
  orphaned INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(account_id, series_id, occurrence_key),
  CHECK (kind IN ('override','cancelled')),
  CHECK ((original_start_at IS NOT NULL) != (original_start_date IS NOT NULL))
)
''');
      legacy.execute(
        "INSERT INTO calendar_event_occurrence_exceptions VALUES "
        "('occ-1','account','series-1','2026-08-03T18:20:00+08:00',1000,NULL,"
        "'override','[]','{}',NULL,0,NULL,1,1)",
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
        "('task-1','account','复习','todo',NULL,'active',NULL,'high',NULL,NULL,'[]',"
        "NULL,NULL,1,1,NULL)",
      );
      legacy.execute('''
CREATE TABLE plan_blocks (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  title TEXT,
  start_at INTEGER NOT NULL,
  end_at INTEGER NOT NULL,
  status TEXT NOT NULL,
  locked INTEGER NOT NULL DEFAULT 0,
  review_note TEXT,
  reviewed_at INTEGER,
  rescheduled_to_plan_block_id TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
)
''');
      // Schema 5 task_event_links: PK (account_id, task_id, event_id), no
      // target_id, no occurrence_exception_id.
      legacy.execute('''
CREATE TABLE task_event_links (
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  event_id TEXT NOT NULL REFERENCES calendar_events(id) ON DELETE CASCADE,
  relation_type TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, task_id, event_id)
)
''');
      legacy.execute(
        "INSERT INTO task_event_links VALUES ('account','task-1','ev-1','related',1)",
      );
      legacy.execute('''
CREATE TABLE schedule_relations (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  source TEXT NOT NULL DEFAULT 'user',
  external_id TEXT,
  relation_type TEXT NOT NULL DEFAULT 'conflict',
  primary_entity_type TEXT,
  primary_entity_id TEXT,
  related_entity_type TEXT,
  related_entity_id TEXT,
  left_kind TEXT,
  left_id TEXT,
  right_kind TEXT,
  right_id TEXT,
  left_event_id TEXT REFERENCES calendar_events(id) ON DELETE CASCADE,
  left_plan_block_id TEXT REFERENCES plan_blocks(id) ON DELETE CASCADE,
  right_event_id TEXT REFERENCES calendar_events(id) ON DELETE CASCADE,
  right_plan_block_id TEXT REFERENCES plan_blocks(id) ON DELETE CASCADE,
  conflict_state TEXT,
  reason TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(account_id, left_kind, left_id, right_kind, right_id),
  UNIQUE(account_id, source, external_id)
)
''');
      // A schema-five conflict relation with event-backed participants.
      legacy.execute(
        "INSERT INTO schedule_relations "
        "('id','account_id','source','external_id','relation_type',"
        "'primary_entity_type','primary_entity_id','related_entity_type',"
        "'related_entity_id','left_kind','left_id','right_kind','right_id',"
        "'left_event_id','left_plan_block_id','right_event_id','right_plan_block_id',"
        "'conflict_state','reason','created_at','updated_at') VALUES "
        "('rel-1','account','user',NULL,'conflict',NULL,NULL,NULL,NULL,"
        "'event','ev-1','event','ev-1','ev-1',NULL,'ev-1',NULL,"
        "'conflict','reason',1,1)",
      );
      // Schema 5 reminders: NO occurrence_exception_id column.
      legacy.execute('''
CREATE TABLE reminders (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  target_type TEXT NOT NULL,
  target_id TEXT NOT NULL,
  event_id TEXT REFERENCES calendar_events(id) ON DELETE CASCADE,
  task_id TEXT REFERENCES tasks(id) ON DELETE CASCADE,
  plan_block_id TEXT REFERENCES plan_blocks(id) ON DELETE CASCADE,
  offset_minutes INTEGER,
  trigger_at INTEGER NOT NULL,
  state TEXT NOT NULL,
  failure_code TEXT,
  delivered_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(account_id, target_type, target_id, trigger_at),
  CHECK (target_type IN ('event','task','plan_block')),
  CHECK (state IN ('desired','delivered','cancelled','missed','failed')),
  CHECK ((target_type = 'event' AND event_id = target_id
          AND task_id IS NULL AND plan_block_id IS NULL) OR
         (target_type = 'task' AND task_id = target_id
          AND event_id IS NULL AND plan_block_id IS NULL) OR
         (target_type = 'plan_block' AND plan_block_id = target_id
          AND event_id IS NULL AND task_id IS NULL))
)
''');
      legacy.execute(
        "INSERT INTO reminders VALUES "
        "('rem-1','account','event','ev-1','ev-1',NULL,NULL,15,900,'desired',NULL,NULL,1,1)",
      );
      // A real v5 database carries the v3-era agent tables; the
      // `from >= 3 && from < 6` guard adds tool_invocations.error_code, so the
      // fixture must include tool_invocations (in its v5 form, no error_code)
      // and its agent_runs parent for that addColumn to apply.
      legacy.execute('''
CREATE TABLE agent_runs (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  model TEXT NOT NULL,
  status TEXT NOT NULL,
  error_code TEXT,
  input_tokens INTEGER,
  output_tokens INTEGER,
  started_at INTEGER NOT NULL,
  finished_at INTEGER,
  UNIQUE(id, account_id)
)
''');
      legacy.execute('''
CREATE TABLE tool_invocations (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL,
  tool_name TEXT NOT NULL,
  status TEXT NOT NULL,
  safe_arguments_summary TEXT NOT NULL,
  safe_result_summary TEXT NOT NULL,
  started_at INTEGER NOT NULL,
  finished_at INTEGER,
  FOREIGN KEY (run_id, account_id) REFERENCES agent_runs(id, account_id) ON DELETE CASCADE
)
''');
      legacy.execute(
        "INSERT INTO agent_runs VALUES "
        "('run-1','account','deepseek-v4-flash','running',NULL,NULL,NULL,50,NULL)",
      );
      legacy.execute(
        "INSERT INTO tool_invocations VALUES "
        "('inv-1','account','run-1','get_schedule','running','args','',70,NULL)",
      );
      legacy.execute('PRAGMA user_version = 5');
      legacy.close();

      // ---- Upgrade through the production AppDatabase ----
      final database = AppDatabase(NativeDatabase(File(path)));
      addTearDown(database.close);

      expect(database.schemaVersion, 7);

      // 1) All old rows survive with their values.
      final account = await database.select(database.localAccounts).getSingle();
      expect(account.id, 'account');
      final series = await database
          .select(database.calendarEventSeries)
          .getSingle();
      expect(series.id, 'series-1');
      expect(series.title, '每周复习');
      final event = await database.select(database.calendarEvents).getSingle();
      expect(event.id, 'ev-1');
      final task = await database.select(database.tasks).getSingle();
      expect(task.id, 'task-1');
      // tool_invocations.error_code was added by the untouched guard.
      final invocation = await database
          .select(database.toolInvocations)
          .getSingle();
      expect(invocation.id, 'inv-1');
      expect(invocation.errorCode, isNull);

      // 2) TaskEventLink.targetId == old eventId, event_id retained, and the
      //    new occurrence_exception_id column exists and is NULL.
      final linkRow = await database
          .customSelect(
            'SELECT target_id, event_id, occurrence_exception_id '
            'FROM task_event_links WHERE task_id = ?',
            variables: [Variable<String>('task-1')],
          )
          .getSingle();
      expect(linkRow.read<String>('target_id'), 'ev-1');
      expect(linkRow.read<String>('event_id'), 'ev-1');
      expect(linkRow.readNullable<String>('occurrence_exception_id'), isNull);
      // The v7 primary key is (account_id, task_id, target_id): a row
      // differing only in target_id must coexist with the migrated row.
      await database.into(database.taskEventLinks).insert(
        TaskEventLinksCompanion.insert(
          accountId: 'account',
          taskId: 'task-1',
          targetId: 'ev-2',
          eventId: const Value('ev-1'),
          relationType: 'related',
          createdAt: 2,
        ),
      );
      final linkCount = await database
          .customSelect('SELECT COUNT(*) AS n FROM task_event_links')
          .getSingle();
      expect(linkCount.read<int>('n'), 2);

      // 3) Series reminder default: timed series -> [15].
      final seriesRow = await database
          .customSelect(
            'SELECT reminder_offsets_json FROM calendar_event_series WHERE id = ?',
            variables: [Variable<String>('series-1')],
          )
          .getSingle();
      expect(seriesRow.read<String>('reminder_offsets_json'), '[15]');

      // 4) Old event-backed targets have occurrence-exception columns NULL.
      final relation = await database
          .customSelect(
            'SELECT left_occurrence_exception_id, right_occurrence_exception_id '
            'FROM schedule_relations WHERE id = ?',
            variables: [Variable<String>('rel-1')],
          )
          .getSingle();
      expect(relation.readNullable<String>('left_occurrence_exception_id'), isNull);
      expect(relation.readNullable<String>('right_occurrence_exception_id'), isNull);
      final reminder = await database
          .customSelect(
            'SELECT occurrence_exception_id FROM reminders WHERE id = ?',
            variables: [Variable<String>('rem-1')],
          )
          .getSingle();
      expect(reminder.readNullable<String>('occurrence_exception_id'), isNull);

      // 5) foreign_key_check returns no rows.
      final violations = await database
          .customSelect('PRAGMA foreign_key_check')
          .get();
      expect(violations, isEmpty);

      // 6) Invalid new rows fail against the installed Schema 7 constraints.
      //    Unbacked task event link (no event nor occurrence exception).
      await expectLater(
        database.into(database.taskEventLinks).insert(
          TaskEventLinksCompanion.insert(
            accountId: 'account',
            taskId: 'task-1',
            targetId: 'unbacked',
            relationType: 'related',
            createdAt: 1,
          ),
        ),
        throwsA(isA<sqlite.SqliteException>()),
      );
      // Dual-backed reminder is rejected.
      await expectLater(
        database.into(database.reminders).insert(
          RemindersCompanion.insert(
            id: 'rem-bad',
            accountId: 'account',
            targetType: 'event',
            targetId: 'ev-1',
            eventId: const Value('ev-1'),
            occurrenceExceptionId: const Value('occ-1'),
            triggerAt: 900,
            state: 'desired',
            createdAt: 1,
            updatedAt: 1,
          ),
        ),
        throwsA(isA<sqlite.SqliteException>()),
      );
    },
  );

  // C1 smoke: a real Schema 2 database (which already carries the
  // calendar_event_series / task_event_links / schedule_relations / reminders
  // tables introduced at the schedule/task schema commit) upgraded against the
  // v7 binary must end up with every Schema 7 column on those four tables.
  // Before the guard fix the `from < 7` branch was skipped for from=2, so the
  // v7 columns would be missing.
  test(
    'schema two upgrades to seven with recurring target columns present',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ustc-migration-v2-to-v7-test',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = p.join(directory.path, 'legacy-v2-to-v7.sqlite');
      final legacy = sqlite.sqlite3.open(path);
      legacy.execute('PRAGMA foreign_keys = ON');
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
        "INSERT INTO local_accounts VALUES ('account', 'PB****0000', 1, 'digest', 1, 1)",
      );
      // v2-era calendar_event_series (no reminder_offsets_json).
      legacy.execute('''
CREATE TABLE calendar_event_series (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  event_type TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  timezone TEXT NOT NULL,
  all_day INTEGER NOT NULL DEFAULT 0,
  start_at INTEGER,
  duration_minutes INTEGER,
  anchor_start_date TEXT,
  duration_days INTEGER,
  recurrence_json TEXT NOT NULL,
  effective_from TEXT,
  effective_through TEXT,
  location_name TEXT,
  importance TEXT NOT NULL DEFAULT 'normal',
  color TEXT,
  completion_policy TEXT NOT NULL DEFAULT 'auto_after_end',
  tags_json TEXT NOT NULL DEFAULT '[]',
  user_notes TEXT,
  deleted_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  CHECK ((all_day = 0 AND start_at IS NOT NULL AND duration_minutes > 0
          AND anchor_start_date IS NULL AND duration_days IS NULL) OR
         (all_day = 1 AND start_at IS NULL AND duration_minutes IS NULL
          AND anchor_start_date IS NOT NULL AND duration_days > 0)),
  CHECK (status IN ('active','tentative','cancelled','completed','skipped','hidden')),
  CHECK (effective_through IS NULL OR effective_from IS NULL
         OR effective_through >= effective_from)
)
''');
      legacy.execute(
        "INSERT INTO calendar_event_series VALUES "
        "('series-1','account','每周复习',NULL,'personal','active','Asia/Shanghai',0,"
        "1000,60,NULL,NULL,'{\"frequency\":\"weekly\"}',NULL,NULL,NULL,'normal',NULL,"
        "'auto_after_end','[]',NULL,NULL,1,1)",
      );
      legacy.execute('''
CREATE TABLE calendar_events (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  source TEXT NOT NULL,
  external_id TEXT,
  source_series_external_id TEXT,
  personal_series_id TEXT REFERENCES calendar_event_series(id) ON DELETE CASCADE,
  occurrence_key TEXT,
  title TEXT NOT NULL,
  description TEXT,
  type TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  start_at INTEGER,
  end_at INTEGER,
  all_day INTEGER NOT NULL,
  start_date TEXT,
  end_date_exclusive TEXT,
  timezone TEXT NOT NULL,
  location_name TEXT,
  building_name TEXT,
  campus_name TEXT,
  participants_json TEXT NOT NULL DEFAULT '[]',
  source_details_json TEXT NOT NULL DEFAULT '{}',
  importance TEXT NOT NULL DEFAULT 'normal',
  completion_policy TEXT NOT NULL DEFAULT 'auto_complete',
  completed_at INTEGER,
  color TEXT,
  tags_json TEXT NOT NULL DEFAULT '[]',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER,
  CHECK ((all_day = 0 AND start_at IS NOT NULL AND end_at IS NOT NULL
          AND end_at > start_at AND start_date IS NULL
          AND end_date_exclusive IS NULL) OR
         (all_day = 1 AND start_at IS NULL AND end_at IS NULL
          AND start_date IS NOT NULL AND end_date_exclusive IS NOT NULL
          AND end_date_exclusive > start_date)),
  CHECK (type IN ('course','exam','second_class','personal','entertainment','meal',
                  'campus_affair','travel','study','system')),
  CHECK (status IN ('active','tentative','cancelled','completed','skipped','hidden'))
)
''');
      legacy.execute(
        "INSERT INTO calendar_events VALUES "
        "('ev-1','account','user',NULL,NULL,NULL,NULL,'一次考试',NULL,'personal',"
        "'active',1000,2000,0,NULL,NULL,'Asia/Shanghai',NULL,NULL,NULL,'[]','{}',"
        "'normal','auto_complete',NULL,NULL,'[]',1,1,NULL)",
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
        "('task-1','account','复习',NULL,NULL,'active',NULL,'high',NULL,NULL,'[]',"
        "NULL,NULL,1,1,NULL)",
      );
      legacy.execute('''
CREATE TABLE plan_blocks (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  title TEXT,
  start_at INTEGER NOT NULL,
  end_at INTEGER NOT NULL,
  status TEXT NOT NULL,
  locked INTEGER NOT NULL DEFAULT 0,
  review_note TEXT,
  reviewed_at INTEGER,
  rescheduled_to_plan_block_id TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
)
''');
      // v2-era task_event_links: PK (account_id, task_id, event_id).
      legacy.execute('''
CREATE TABLE task_event_links (
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  event_id TEXT NOT NULL REFERENCES calendar_events(id) ON DELETE CASCADE,
  relation_type TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, task_id, event_id)
)
''');
      legacy.execute(
        "INSERT INTO task_event_links VALUES ('account','task-1','ev-1','related',1)",
      );
      legacy.execute('''
CREATE TABLE schedule_relations (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  source TEXT NOT NULL DEFAULT 'user',
  external_id TEXT,
  relation_type TEXT NOT NULL DEFAULT 'conflict',
  primary_entity_type TEXT,
  primary_entity_id TEXT,
  related_entity_type TEXT,
  related_entity_id TEXT,
  left_kind TEXT,
  left_id TEXT,
  right_kind TEXT,
  right_id TEXT,
  left_event_id TEXT REFERENCES calendar_events(id) ON DELETE CASCADE,
  left_plan_block_id TEXT REFERENCES plan_blocks(id) ON DELETE CASCADE,
  right_event_id TEXT REFERENCES calendar_events(id) ON DELETE CASCADE,
  right_plan_block_id TEXT REFERENCES plan_blocks(id) ON DELETE CASCADE,
  conflict_state TEXT,
  reason TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
''');
      legacy.execute('''
CREATE TABLE reminders (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  target_type TEXT NOT NULL,
  target_id TEXT NOT NULL,
  event_id TEXT REFERENCES calendar_events(id) ON DELETE CASCADE,
  task_id TEXT REFERENCES tasks(id) ON DELETE CASCADE,
  plan_block_id TEXT REFERENCES plan_blocks(id) ON DELETE CASCADE,
  offset_minutes INTEGER,
  trigger_at INTEGER NOT NULL,
  state TEXT NOT NULL,
  failure_code TEXT,
  delivered_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
''');
      // action_logs has existed since schema one; the v4 migration adds
      // risk_level to it, so a v2 fixture must carry the table.
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

      expect(database.schemaVersion, 7);
      // The four Schema 7 columns exist after upgrading a pre-v6 database.
      final seriesCols = (await database
              .customSelect('PRAGMA table_info(calendar_event_series)')
              .get())
          .map((row) => row.read<String>('name'))
          .toSet();
      expect(seriesCols, contains('reminder_offsets_json'));
      final linkCols = (await database
              .customSelect('PRAGMA table_info(task_event_links)')
              .get())
          .map((row) => row.read<String>('name'))
          .toSet();
      expect(linkCols, containsAll({'target_id', 'occurrence_exception_id'}));
      final relationCols = (await database
              .customSelect('PRAGMA table_info(schedule_relations)')
              .get())
          .map((row) => row.read<String>('name'))
          .toSet();
      expect(
        relationCols,
        containsAll({'left_occurrence_exception_id', 'right_occurrence_exception_id'}),
      );
      final reminderCols = (await database
              .customSelect('PRAGMA table_info(reminders)')
              .get())
          .map((row) => row.read<String>('name'))
          .toSet();
      expect(reminderCols, contains('occurrence_exception_id'));
      // The seeded timed series was backfilled with the v7 default.
      final seriesRow = await database
          .customSelect(
            'SELECT reminder_offsets_json FROM calendar_event_series WHERE id = ?',
            variables: [Variable<String>('series-1')],
          )
          .getSingle();
      expect(seriesRow.read<String>('reminder_offsets_json'), '[15]');
    },
  );

  // C1 smoke: a real Schema 4 database upgraded against the v7 binary must
  // end up with every Schema 7 column on the four dependent tables. from=4
  // also exercises the `from >= 3 && from < 6` tool_invocations guard, which
  // must remain untouched by the guard change.
  test(
    'schema four upgrades to seven with recurring target columns present',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ustc-migration-v4-to-v7-test',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = p.join(directory.path, 'legacy-v4-to-v7.sqlite');
      final legacy = sqlite.sqlite3.open(path);
      legacy.execute('PRAGMA foreign_keys = ON');
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
        "INSERT INTO local_accounts VALUES ('account', 'PB****0000', 1, 'digest', 1, 1)",
      );
      legacy.execute('''
CREATE TABLE calendar_event_series (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  event_type TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  timezone TEXT NOT NULL,
  all_day INTEGER NOT NULL DEFAULT 0,
  start_at INTEGER,
  duration_minutes INTEGER,
  anchor_start_date TEXT,
  duration_days INTEGER,
  recurrence_json TEXT NOT NULL,
  effective_from TEXT,
  effective_through TEXT,
  location_name TEXT,
  importance TEXT NOT NULL DEFAULT 'normal',
  color TEXT,
  completion_policy TEXT NOT NULL DEFAULT 'auto_after_end',
  tags_json TEXT NOT NULL DEFAULT '[]',
  user_notes TEXT,
  deleted_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  CHECK ((all_day = 0 AND start_at IS NOT NULL AND duration_minutes > 0
          AND anchor_start_date IS NULL AND duration_days IS NULL) OR
         (all_day = 1 AND start_at IS NULL AND duration_minutes IS NULL
          AND anchor_start_date IS NOT NULL AND duration_days > 0)),
  CHECK (status IN ('active','tentative','cancelled','completed','skipped','hidden')),
  CHECK (effective_through IS NULL OR effective_from IS NULL
         OR effective_through >= effective_from)
)
''');
      legacy.execute(
        "INSERT INTO calendar_event_series VALUES "
        "('series-1','account','每周复习',NULL,'personal','active','Asia/Shanghai',0,"
        "1000,60,NULL,NULL,'{\"frequency\":\"weekly\"}',NULL,NULL,NULL,'normal',NULL,"
        "'auto_after_end','[]',NULL,NULL,1,1)",
      );
      legacy.execute('''
CREATE TABLE calendar_events (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  source TEXT NOT NULL,
  external_id TEXT,
  source_series_external_id TEXT,
  personal_series_id TEXT REFERENCES calendar_event_series(id) ON DELETE CASCADE,
  occurrence_key TEXT,
  title TEXT NOT NULL,
  description TEXT,
  type TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  start_at INTEGER,
  end_at INTEGER,
  all_day INTEGER NOT NULL,
  start_date TEXT,
  end_date_exclusive TEXT,
  timezone TEXT NOT NULL,
  location_name TEXT,
  building_name TEXT,
  campus_name TEXT,
  participants_json TEXT NOT NULL DEFAULT '[]',
  source_details_json TEXT NOT NULL DEFAULT '{}',
  importance TEXT NOT NULL DEFAULT 'normal',
  completion_policy TEXT NOT NULL DEFAULT 'auto_complete',
  completed_at INTEGER,
  color TEXT,
  tags_json TEXT NOT NULL DEFAULT '[]',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER,
  CHECK ((all_day = 0 AND start_at IS NOT NULL AND end_at IS NOT NULL
          AND end_at > start_at AND start_date IS NULL
          AND end_date_exclusive IS NULL) OR
         (all_day = 1 AND start_at IS NULL AND end_at IS NULL
          AND start_date IS NOT NULL AND end_date_exclusive IS NOT NULL
          AND end_date_exclusive > start_date)),
  CHECK (type IN ('course','exam','second_class','personal','entertainment','meal',
                  'campus_affair','travel','study','system')),
  CHECK (status IN ('active','tentative','cancelled','completed','skipped','hidden'))
)
''');
      legacy.execute(
        "INSERT INTO calendar_events VALUES "
        "('ev-1','account','user',NULL,NULL,NULL,NULL,'一次考试',NULL,'personal',"
        "'active',1000,2000,0,NULL,NULL,'Asia/Shanghai',NULL,NULL,NULL,'[]','{}',"
        "'normal','auto_complete',NULL,NULL,'[]',1,1,NULL)",
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
        "('task-1','account','复习',NULL,NULL,'active',NULL,'high',NULL,NULL,'[]',"
        "NULL,NULL,1,1,NULL)",
      );
      legacy.execute('''
CREATE TABLE plan_blocks (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  title TEXT,
  start_at INTEGER NOT NULL,
  end_at INTEGER NOT NULL,
  status TEXT NOT NULL,
  locked INTEGER NOT NULL DEFAULT 0,
  review_note TEXT,
  reviewed_at INTEGER,
  rescheduled_to_plan_block_id TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
)
''');
      legacy.execute('''
CREATE TABLE task_event_links (
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  event_id TEXT NOT NULL REFERENCES calendar_events(id) ON DELETE CASCADE,
  relation_type TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, task_id, event_id)
)
''');
      legacy.execute(
        "INSERT INTO task_event_links VALUES ('account','task-1','ev-1','related',1)",
      );
      legacy.execute('''
CREATE TABLE schedule_relations (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  source TEXT NOT NULL DEFAULT 'user',
  external_id TEXT,
  relation_type TEXT NOT NULL DEFAULT 'conflict',
  primary_entity_type TEXT,
  primary_entity_id TEXT,
  related_entity_type TEXT,
  related_entity_id TEXT,
  left_kind TEXT,
  left_id TEXT,
  right_kind TEXT,
  right_id TEXT,
  left_event_id TEXT REFERENCES calendar_events(id) ON DELETE CASCADE,
  left_plan_block_id TEXT REFERENCES plan_blocks(id) ON DELETE CASCADE,
  right_event_id TEXT REFERENCES calendar_events(id) ON DELETE CASCADE,
  right_plan_block_id TEXT REFERENCES plan_blocks(id) ON DELETE CASCADE,
  conflict_state TEXT,
  reason TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
''');
      legacy.execute('''
CREATE TABLE reminders (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  target_type TEXT NOT NULL,
  target_id TEXT NOT NULL,
  event_id TEXT REFERENCES calendar_events(id) ON DELETE CASCADE,
  task_id TEXT REFERENCES tasks(id) ON DELETE CASCADE,
  plan_block_id TEXT REFERENCES plan_blocks(id) ON DELETE CASCADE,
  offset_minutes INTEGER,
  trigger_at INTEGER NOT NULL,
  state TEXT NOT NULL,
  failure_code TEXT,
  delivered_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)
''');
      // A v4 database has tool_invocations (created at v3) with the v5
      // definition (no error_code); the `from >= 3 && from < 6` guard must
      // add it. The fixture must carry the table for that addColumn to apply.
      legacy.execute('''
CREATE TABLE agent_runs (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  model TEXT NOT NULL,
  status TEXT NOT NULL,
  error_code TEXT,
  input_tokens INTEGER,
  output_tokens INTEGER,
  started_at INTEGER NOT NULL,
  finished_at INTEGER,
  UNIQUE(id, account_id)
)
''');
      legacy.execute('''
CREATE TABLE tool_invocations (
  id TEXT NOT NULL PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES local_accounts(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL,
  tool_name TEXT NOT NULL,
  status TEXT NOT NULL,
  safe_arguments_summary TEXT NOT NULL,
  safe_result_summary TEXT NOT NULL,
  started_at INTEGER NOT NULL,
  finished_at INTEGER,
  FOREIGN KEY (run_id, account_id) REFERENCES agent_runs(id, account_id) ON DELETE CASCADE
)
''');
      legacy.execute('PRAGMA user_version = 4');
      legacy.close();

      final database = AppDatabase(NativeDatabase(File(path)));
      addTearDown(database.close);

      expect(database.schemaVersion, 7);
      // tool_invocations.error_code was added by the untouched guard.
      final toolCols = (await database
              .customSelect('PRAGMA table_info(tool_invocations)')
              .get())
          .map((row) => row.read<String>('name'))
          .toSet();
      expect(toolCols, contains('error_code'));
      // The four Schema 7 columns exist after upgrading a pre-v6 database.
      final seriesCols = (await database
              .customSelect('PRAGMA table_info(calendar_event_series)')
              .get())
          .map((row) => row.read<String>('name'))
          .toSet();
      expect(seriesCols, contains('reminder_offsets_json'));
      final linkCols = (await database
              .customSelect('PRAGMA table_info(task_event_links)')
              .get())
          .map((row) => row.read<String>('name'))
          .toSet();
      expect(linkCols, containsAll({'target_id', 'occurrence_exception_id'}));
      final relationCols = (await database
              .customSelect('PRAGMA table_info(schedule_relations)')
              .get())
          .map((row) => row.read<String>('name'))
          .toSet();
      expect(
        relationCols,
        containsAll({'left_occurrence_exception_id', 'right_occurrence_exception_id'}),
      );
      final reminderCols = (await database
              .customSelect('PRAGMA table_info(reminders)')
              .get())
          .map((row) => row.read<String>('name'))
          .toSet();
      expect(reminderCols, contains('occurrence_exception_id'));
    },
  );
}
