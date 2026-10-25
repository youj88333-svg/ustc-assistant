import 'dart:convert';
import 'dart:io';
import '../support/calendar_legacy_schema.dart';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

final _day = DateTime.utc(2026, 10, 15);
final _now = DateTime.utc(2026, 10, 15, 0);

void main() {
  test(
    'schema 16 retires only missing covered sources and cancels their persisted reminders after startup',
    () async {
      final file = await _temporaryDatabase();
      var store = await _open(file);
      await _seedSources(store);
      final preferences = await store.features.inspectReminders();
      await store.features.saveReminderPreferences(
        preferences,
        preferences.preferences.copyWith(enabled: true),
      );
      final publication = await store.features.prepareReminderPublication();
      expect(publication.desired, hasLength(8));
      for (final mapping in publication.desired) {
        await store.features.recordReminderAccepted(
          publication,
          mapping.request.id,
        );
      }
      final oldCourse = publication.desired.singleWhere(
        (mapping) =>
            mapping.target.kind == ReminderKind.course &&
            mapping.target.localId == 1,
      );
      final oldYoung = publication.desired.singleWhere(
        (mapping) =>
            mapping.target.kind == ReminderKind.young &&
            mapping.target.localId == 1,
      );
      final retainedExam = publication.desired.singleWhere(
        (mapping) =>
            mapping.target.kind == ReminderKind.exam &&
            mapping.target.localId == 4,
      );
      final originalContext = (await _window(store)).context;
      final originalRevision = (await _window(store)).revision;
      await store.close();

      // Only the owned TEMP database is rewound. Keep the exact old reminder
      // tuple shape to exercise decoding before startup recaptures its input.
      final raw = sqlite.sqlite3.open(file.path);
      late List<Map<String, Object?>> retainedFacts;
      try {
        raw.execute('BEGIN IMMEDIATE');
        removeModelProviderSchemaForLegacyFixture(raw);
        raw.execute('DROP TABLE IF EXISTS young_daily_sync');
        raw.execute('ALTER TABLE jw_events DROP COLUMN source_retired');
        raw.execute('ALTER TABLE young_events DROP COLUMN source_retired');
        final input =
            jsonDecode(
                  raw
                          .select('SELECT input_json FROM m6_expected')
                          .single['input_json']
                      as String,
                )
                as Map<String, dynamic>;
        for (final field in ['school', 'blocks']) {
          input[field] = [
            for (final item in input[field] as List)
              (item as List).take(19).toList(),
          ];
        }
        raw.execute('UPDATE m6_expected SET input_json=?', [jsonEncode(input)]);
        raw.execute('PRAGMA user_version=16');
        retainedFacts = _retainedFacts(raw);
        raw.execute('COMMIT');
      } on Object {
        raw.execute('ROLLBACK');
        rethrow;
      } finally {
        raw.close();
      }

      store = await _open(file);
      expect(store.schemaVersion, JwStore.currentSchemaVersion);
      expect((await _window(store)).context, originalContext);
      expect((await _window(store)).revision, originalRevision + 1);
      final upgraded = sqlite.sqlite3.open(file.path);
      try {
        expect(
          upgraded.select('PRAGMA user_version').single['user_version'],
          JwStore.currentSchemaVersion,
        );
        expect(_retainedFacts(upgraded), retainedFacts);
        expect(
          upgraded
              .select('SELECT source_retired FROM jw_events ORDER BY local_id')
              .map((row) => row['source_retired']),
          [1, 0, 0, 0, 0],
        );
        expect(
          upgraded
              .select(
                'SELECT source_retired FROM young_events ORDER BY local_id',
              )
              .map((row) => row['source_retired']),
          [1, 0, 0],
        );
        expect(
          upgraded
              .select('SELECT version FROM jw_events ORDER BY local_id')
              .map((row) => row['version']),
          [2, 1, 1, 1, 1],
        );
        expect(
          upgraded
              .select('SELECT version FROM young_events ORDER BY local_id')
              .map((row) => row['version']),
          [2, 1, 1],
        );
      } finally {
        upgraded.close();
      }
      final active = await _window(store);
      expect(active.items, hasLength(6));
      expect(active.items.every((item) => !item.sourceRetired), isTrue);
      final history = await _window(store, includeRetired: true);
      expect(history.items, hasLength(8));
      final retired = history.items
          .where((item) => item.sourceRetired)
          .toList();
      expect(retired.map((item) => item.reference.identity.kind).toSet(), {
        CalendarKind.course,
        CalendarKind.young,
      });
      for (final item in retired) {
        final detail = await store.localCalendar.detail(item.reference);
        expect(detail.occurrence.sourceRetired, isTrue);
        expect(detail.occurrence.note, 'synthetic retained note');
      }

      // Old tuple decoding remains supported. Current source state must reject
      // retired clicks even before the startup reminder recapture runs.
      expect(
        await store.features.resolveNotification(_activation(oldCourse)),
        isNull,
      );
      expect(
        await store.features.resolveNotification(_activation(oldYoung)),
        isNull,
      );
      expect(
        await store.features.resolveNotification(_activation(retainedExam)),
        isNotNull,
      );
      await store.features.initialize();
      final refreshed = await store.features.prepareReminderPublication();
      expect(refreshed.desired, hasLength(6));
      expect(refreshed.invalidPriorIds.toSet(), {
        oldCourse.request.id,
        oldYoung.request.id,
      });
      expect(
        refreshed.desired
            .singleWhere(
              (mapping) => mapping.request.id == retainedExam.request.id,
            )
            .accepted,
        isTrue,
      );
      for (final item in retired) {
        final inspection = await store.features.inspectReminder(
          ReminderTarget.calendar(item.reference),
        );
        expect(inspection.eligible, isFalse);
        expect(inspection.reason, 'sourceRetired');
      }
      await store.close();
      store = await _open(file);
      await store.features.initialize();
      expect((await _window(store)).items, hasLength(6));
      expect(
        (await _window(
          store,
          includeRetired: true,
        )).items.where((item) => item.sourceRetired),
        hasLength(2),
      );
    },
  );
}

Future<void> _seedSources(JwStore store) async {
  await store.customStatement("INSERT INTO jw_account VALUES(1,'SYNTHETIC17')");
  await store.customStatement(
    "INSERT INTO jw_credentials VALUES(1,'synthetic-placeholder',X'01020304')",
  );
  for (final (index, kind, presence) in [
    (1, 'course', 'missingWithinScope'),
    (2, 'course', 'observed'),
    (3, 'course', 'outsideScope'),
    (4, 'exam', 'missingWithinScope'),
    (5, 'exam', 'observed'),
  ]) {
    await store.customStatement(
      'INSERT INTO jw_events(local_id,external_id,kind,semester_id,title,starts_at,ends_at,presence,version) '
      'VALUES(?,?,?,?,?,?,?,?,1)',
      [
        index,
        'synthetic-jw-$index',
        kind,
        kind == 'course' ? 202610 : null,
        'synthetic $kind $index',
        _now.add(Duration(hours: index + 1)).microsecondsSinceEpoch,
        _now.add(Duration(hours: index + 2)).microsecondsSinceEpoch,
        presence,
      ],
    );
    await store.customStatement(
      "INSERT INTO jw_overlays(local_id,hidden,note,attendance,listening) VALUES(?,0,'synthetic retained note','undecided','undecided')",
      [index],
    );
  }
  for (final (index, presence) in [
    (1, 'missingWithinScope'),
    (2, 'observed'),
    (3, 'outsideScope'),
  ]) {
    await store.customStatement(
      'INSERT INTO young_events(local_id,external_id,item_id,title,place,starts_at,ends_at,presence,version) '
      'VALUES(?,?,?,?,?,?,?,?,1)',
      [
        index,
        'synthetic-young-$index',
        'synthetic-item-$index',
        'synthetic young $index',
        'synthetic room',
        _now.add(Duration(hours: index + 7)).microsecondsSinceEpoch,
        _now.add(Duration(hours: index + 8)).microsecondsSinceEpoch,
        presence,
      ],
    );
    await store.customStatement(
      "INSERT INTO young_overlays(local_id,hidden,note,attendance) VALUES(?,0,'synthetic retained note','undecided')",
      [index],
    );
  }
}

List<Map<String, Object?>> _retainedFacts(sqlite.Database database) => [
  for (final table in [
    'jw_account',
    'jw_credentials',
    'jw_events',
    'jw_overlays',
    'young_events',
    'young_overlays',
    'm6_state',
    'm6_reminder_overrides',
    'm6_native_map',
  ])
    for (final row in database.select('SELECT * FROM $table ORDER BY rowid'))
      {
        'table': table,
        for (final entry in row.entries)
          if (entry.key != 'source_retired' && entry.key != 'version')
            entry.key: entry.value is List<int>
                ? List<int>.from(entry.value as List<int>)
                : entry.value,
      },
];

NotificationActivation _activation(ReminderMapping mapping) =>
    NotificationActivation(
      mapping.request.id,
      mapping.request.digest,
      mapping.request.token,
    );

Future<CalendarWindow> _window(JwStore store, {bool includeRetired = false}) =>
    store.localCalendar.query(
      CalendarQuery(
        firstDay: _day,
        endDayExclusive: _day.add(const Duration(days: 1)),
        includeHidden: true,
        includeRetired: includeRetired,
      ),
    );

Future<JwStore> _open(File file) async {
  final store = JwStore(
    NativeDatabase(file),
    ownership: _Owner(),
    clock: FixedClock(_now),
  );
  try {
    await store.initialize();
  } on Object {
    await store.close();
    rethrow;
  }
  addTearDown(store.close);
  return store;
}

Future<File> _temporaryDatabase() async {
  final directory = await Directory.systemTemp.createTemp(
    'source-retirement-migration-',
  );
  addTearDown(() async {
    if (directory.absolute.parent.uri != Directory.systemTemp.absolute.uri ||
        !directory.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('source-retirement-migration-') ||
        await directory.resolveSymbolicLinks() != directory.absolute.path) {
      throw StateError('Unexpected synthetic source retirement root');
    }
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File ||
          !const {
            'store.sqlite',
            'store.sqlite-wal',
            'store.sqlite-shm',
            'store.sqlite-journal',
          }.contains(entry.uri.pathSegments.last)) {
        throw StateError('Unexpected synthetic source retirement asset');
      }
      await entry.delete();
    }
    await directory.delete();
  });
  return File('${directory.path}${Platform.pathSeparator}store.sqlite');
}

final class _Owner implements AssetOwnership {
  @override
  bool get isHeld => true;
  @override
  void ensureHeld() {}
}
