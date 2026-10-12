import 'package:sqlite3/sqlite3.dart';

/// Only for explicitly constructed synthetic legacy database copies. Version
/// 1-5 did not contain these tables/columns; never call on a user's database.
void removeCalendarTablesForLegacyFixture(Database database) {
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
