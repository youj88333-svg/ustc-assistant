import 'package:sqlite3/sqlite3.dart';

/// Only for explicitly constructed synthetic legacy database copies. Version
/// 1-5 did not contain these tables/columns; never call on a user's database.
void removeCalendarTablesForLegacyFixture(Database database) {
  removeTaskTablesForLegacyFixture(database);
  final jwColumns = database
      .select('PRAGMA table_info(jw_events)')
      .map((row) => row['name'])
      .toSet();
  if (jwColumns.contains('academic_json')) {
    database.execute('ALTER TABLE jw_events DROP COLUMN academic_json');
  }
  for (final table in const [
    'personal_occurrence_overrides',
    'personal_events',
    'agenda_relations',
    'agenda_receipts',
    'agenda_audit',
    'agenda_state',
  ]) {
    database.execute('DROP TABLE IF EXISTS $table');
  }
  for (final table in const ['jw_overlays', 'young_overlays']) {
    final columns = database
        .select('PRAGMA table_info($table)')
        .map((row) => row['name'])
        .toSet();
    for (final column in const ['note', 'attendance', 'listening']) {
      if (columns.contains(column)) {
        database.execute('ALTER TABLE $table DROP COLUMN $column');
      }
    }
  }
}

/// Remove v9 and later additions from an owned synthetic copy to construct v6-v8.
void removeTaskTablesForLegacyFixture(Database database) {
  removeSettingsTablesForLegacyFixture(database);
  for (final table in const [
    'local_plan_blocks',
    'local_tasks',
    'agenda_undo',
  ]) {
    database.execute('DROP TABLE IF EXISTS $table');
  }
  final receipts = database
      .select('PRAGMA table_info(agenda_receipts)')
      .map((r) => r['name'])
      .toSet();
  for (final column in const ['task_json', 'undo_id']) {
    if (receipts.contains(column)) {
      database.execute('ALTER TABLE agenda_receipts DROP COLUMN $column');
    }
  }
  if (database
      .select(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='agenda_audit'",
      )
      .isNotEmpty) {
    database.execute(
      '''CREATE TABLE synthetic_audit_v8 (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      action TEXT NOT NULL CHECK(action IN ('create','series','occurrence','state','delete','annotation','relation','remove-relation')),
      item_count INTEGER NOT NULL CHECK(item_count>=0), committed_at INTEGER NOT NULL)''',
    );
    database.execute(
      'INSERT INTO synthetic_audit_v8 SELECT * FROM agenda_audit',
    );
    database.execute(
      "INSERT INTO sqlite_sequence(name,seq) SELECT 'synthetic_audit_v8',COALESCE((SELECT seq FROM sqlite_sequence WHERE name='agenda_audit'),0) WHERE NOT EXISTS(SELECT 1 FROM sqlite_sequence WHERE name='synthetic_audit_v8')",
    );
    database.execute(
      "UPDATE sqlite_sequence SET seq=MAX(seq,COALESCE((SELECT seq FROM sqlite_sequence WHERE name='agenda_audit'),0)) WHERE name='synthetic_audit_v8'",
    );
    database.execute('DROP TABLE agenda_audit');
    database.execute('ALTER TABLE synthetic_audit_v8 RENAME TO agenda_audit');
  }
}

/// A v1-v9 fixture cannot contain v10 settings/maintenance or v11 Agent tables.
/// This helper is only called on explicitly owned synthetic SQLite copies.
void removeSettingsTablesForLegacyFixture(Database database) {
  removeAgentTablesForLegacyFixture(database);
  for (final table in const [
    'app_maintenance_intent',
    'app_settings_receipts',
    'app_settings_audit',
    'app_settings',
  ]) {
    database.execute('DROP TABLE IF EXISTS $table');
  }
}

/// Remove v11 Agent tables from an explicitly constructed synthetic legacy
/// copy before setting its older user_version.
void removeAgentTablesForLegacyFixture(Database database) {
  for (final table in const [
    'agent_actions',
    'agenda_plan_receipts',
    'agenda_plan_audit',
    'agent_preferences',
    'agent_audit',
    'agent_history_intent',
    'agent_messages',
    'agent_runs',
    'agent_conversations',
    'agent_config',
    'agent_state',
  ]) {
    database.execute('DROP TABLE IF EXISTS $table');
  }
}
