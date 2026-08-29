import 'package:sqlite3/sqlite3.dart' as sqlite;

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
