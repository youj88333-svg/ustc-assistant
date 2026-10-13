import 'dart:io';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_academic_details.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

import '../support/calendar_legacy_schema.dart';

final _day = DateTime.utc(2026, 10, 12);

void main() {
  test(
    'schema eight upgrade preserves facts overlays receipts and high water without inventing undo',
    () async {
      final file = await _file();
      var store = await _open(file);
      final context = (await _window(store)).context;
      final created = await _write(
        store,
        context,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: '合成每周安排',
            start: DateTime.utc(2026, 10, 12, 1),
            end: DateTime.utc(2026, 10, 12, 2),
            weekly: true,
            note: '合成原备注',
          ),
        ),
      );
      await _write(
        store,
        context,
        SetPersonalOccurrenceState(created.target!, completed: true),
      );
      await store.close();
      final raw = sqlite.sqlite3.open(file.path);
      late Map<String, List<Map<String, Object?>>> before;
      try {
        removeTaskTablesForLegacyFixture(raw);
        raw.execute('INSERT INTO jw_account VALUES (1,?)', [
          'SYNTHETICACCOUNT',
        ]);
        raw.execute(
          "INSERT INTO jw_events VALUES (1,'synthetic-course','course',1,?,?,?,?,'observed',6)",
          [
            '合成课',
            jsonEncode(
              JwAcademicDetails(room: '2210', teachers: ['合成教师']).toMap(),
            ),
            DateTime.utc(2026, 10, 12, 2).microsecondsSinceEpoch,
            DateTime.utc(2026, 10, 12, 3).microsecondsSinceEpoch,
          ],
        );
        raw.execute(
          "INSERT INTO jw_overlays VALUES (1,1,'合成覆盖','attend','listening')",
        );
        raw.execute(
          "INSERT INTO young_events VALUES (1,'synthetic-young','synthetic-item','合成活动','合成地点',?,?,'observed',4)",
          [
            DateTime.utc(2026, 10, 12, 3).microsecondsSinceEpoch,
            DateTime.utc(2026, 10, 12, 4).microsecondsSinceEpoch,
          ],
        );
        raw.execute(
          "INSERT INTO young_overlays VALUES (1,0,'合成二课覆盖','undecided')",
        );
        raw.execute(
          "INSERT INTO jw_credentials VALUES (1,'synthetic-protected',X'010203')",
        );
        raw.execute('INSERT INTO jw_preferences VALUES (1,1)');
        raw.execute(
          "INSERT INTO jw_semester_catalog VALUES (1,'synthetic-catalog',1)",
        );
        raw.execute(
          "INSERT INTO knowledge_materials VALUES ('synthetic-material','v1','{}','# 合成长期资料','合成长期资料','teach','synthetic','student','synthetic',1,20)",
        );
        raw.execute(
          "UPDATE sqlite_sequence SET seq=400 WHERE name='agenda_audit'",
        );
        raw.execute(
          "UPDATE sqlite_sequence SET seq=600 WHERE name='personal_events'",
        );
        raw.execute('PRAGMA user_version=8');
        before = _facts(raw);
      } finally {
        raw.close();
      }
      store = await _open(file);
      final after = sqlite.sqlite3.open(file.path);
      try {
        expect(_facts(after), before);
        expect(
          after
              .select(
                'SELECT COUNT(*) AS n FROM agenda_receipts WHERE task_json IS NOT NULL OR undo_id IS NOT NULL',
              )
              .single['n'],
          0,
        );
        expect(after.select('PRAGMA user_version').single['user_version'], 10);
      } finally {
        after.close();
      }
      final window = await _window(store);
      expect(window.context.owner, context.owner);
      expect(window.context.resetEpoch, context.resetEpoch);
      expect(window.context.agendaEpoch, context.agendaEpoch + 2);
      expect(
        (await store.localCalendar.queryUndo(window.context)).reference,
        isNull,
      );
      await expectLater(
        store.localCalendar.prepare(
          context,
          const CreateTask(TaskDraft(title: '旧上下文')),
        ),
        throwsA(
          isA<CalendarFailure>().having(
            (e) => e.code,
            'code',
            CalendarFailureCode.staleReference,
          ),
        ),
      );
      final task = await _write(
        store,
        window.context,
        const CreateTask(TaskDraft(title: '合成新任务')),
      );
      expect(task.task!.version, 1);
      final nextPersonal = await _write(
        store,
        window.context,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: '新个人安排',
            start: DateTime.utc(2026, 10, 12, 5),
            end: DateTime.utc(2026, 10, 12, 6),
          ),
        ),
      );
      expect(nextPersonal.target!.identity.localId, 601);
      expect(
        (await store
                .customSelect('SELECT MAX(sequence) AS n FROM agenda_audit')
                .getSingle())
            .read<int>('n'),
        402,
      );
      await store.close();
      store = await _open(file);
      expect(
        (await store.localCalendar.queryTasks(
          const TaskQuery(),
        )).items.single.draft.title,
        '合成新任务',
      );
      expect(
        (await store.localCalendar.queryUndo(
          (await _window(store)).context,
        )).canUndo,
        isTrue,
      );
    },
  );

  test(
    'late v9 migration collision rolls back tables columns epochs and original audit',
    () async {
      final file = await _file();
      var store = await _open(file);
      final context = (await _window(store)).context;
      await _write(
        store,
        context,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: '迁移保留',
            start: DateTime.utc(2026, 10, 12, 1),
            end: DateTime.utc(2026, 10, 12, 2),
          ),
        ),
      );
      await store.close();
      final raw = sqlite.sqlite3.open(file.path);
      late Map<String, List<Map<String, Object?>>> before;
      try {
        removeTaskTablesForLegacyFixture(raw);
        raw.execute(
          'CREATE TABLE agenda_audit_v9 (synthetic_collision INTEGER)',
        );
        raw.execute('PRAGMA user_version=8');
        before = _facts(raw);
      } finally {
        raw.close();
      }
      await expectLater(
        _open(file),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.code,
            'code',
            FailureCode.storageFailed,
          ),
        ),
      );
      final failed = sqlite.sqlite3.open(file.path);
      try {
        expect(_facts(failed), before);
        expect(failed.select('PRAGMA user_version').single['user_version'], 8);
        expect(
          failed.select(
            "SELECT name FROM sqlite_master WHERE name IN ('local_tasks','local_plan_blocks','agenda_undo')",
          ),
          isEmpty,
        );
        expect(
          failed
              .select('PRAGMA table_info(agenda_receipts)')
              .map((r) => r['name']),
          isNot(contains('task_json')),
        );
        expect(
          failed.select('SELECT epoch FROM agenda_state').single['epoch'],
          context.agendaEpoch,
        );
        failed.execute('DROP TABLE agenda_audit_v9');
      } finally {
        failed.close();
      }
      store = await _open(file);
      expect((await _window(store)).items.single.title, '迁移保留');
      expect(
        (await _window(store)).context.agendaEpoch,
        context.agendaEpoch + 2,
      );
    },
  );
}

Map<String, List<Map<String, Object?>>> _facts(sqlite.Database raw) => {
  for (final table in const [
    'jw_account',
    'jw_events',
    'jw_overlays',
    'young_events',
    'young_overlays',
    'jw_credentials',
    'jw_preferences',
    'jw_semester_catalog',
    'knowledge_materials',
    'personal_events',
    'personal_occurrence_overrides',
    'agenda_relations',
    'agenda_receipts',
    'agenda_audit',
  ])
    table: [
      for (final row in raw.select('SELECT * FROM $table'))
        Map<String, Object?>.from(row)
          ..remove('task_json')
          ..remove('undo_id'),
    ],
};

Future<JwStore> _open(File file) async {
  final store = JwStore(
    NativeDatabase(file),
    ownership: _Owner(),
    clock: FixedClock(DateTime.utc(2026, 10, 12, 4)),
  );
  addTearDown(store.close);
  try {
    await store.initialize();
  } catch (_) {
    await store.close();
    rethrow;
  }
  return store;
}

Future<CalendarWindow> _window(JwStore store) => store.localCalendar.query(
  CalendarQuery(
    firstDay: _day,
    endDayExclusive: _day.add(const Duration(days: 7)),
    includeHidden: true,
  ),
);
Future<CalendarWriteReceipt> _write(
  JwStore store,
  CalendarContext context,
  CalendarIntent intent,
) async => store.localCalendar.commit(
  await store.localCalendar.prepare(context, intent),
);
Future<File> _file() async {
  final root = await Directory.systemTemp.createTemp('m43-task-migration-');
  addTearDown(() async {
    final temp = Directory.systemTemp.absolute.uri;
    if (root.absolute.parent.uri != temp ||
        !root.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('m43-task-migration-') ||
        await root.resolveSymbolicLinks() != root.absolute.path) {
      throw StateError('Unexpected synthetic migration root');
    }
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! File ||
          ![
            'db.sqlite',
            'db.sqlite-wal',
            'db.sqlite-shm',
            'db.sqlite-journal',
          ].contains(entry.uri.pathSegments.last)) {
        throw StateError('Unexpected synthetic migration asset');
      }
      await entry.delete();
    }
    await root.delete();
  });
  return File('${root.path}${Platform.pathSeparator}db.sqlite');
}

final class _Owner implements AssetOwnership {
  @override
  bool get isHeld => true;
  @override
  void ensureHeld() {}
}
