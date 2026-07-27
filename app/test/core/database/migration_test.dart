import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';

void main() {
  test(
    'schema version one creates the complete constrained database',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      expect(database.schemaVersion, 1);
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
}
