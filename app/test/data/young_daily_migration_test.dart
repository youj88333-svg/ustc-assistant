import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

final _now = DateTime.utc(2026, 10, 15, 1);

void main() {
  test(
    'schema 17 adds disabled daily sync and preserves all existing facts',
    () async {
      final file = await _legacyFile();
      final before = _snapshot(file);
      final protector = _NoCredentialUse();
      var networkAttempts = 0;
      await HttpOverrides.runZoned(
        () async {
          final store = await _openMigration(file, protector: protector);
          expect(store.schemaVersion, 18);
          expect(
            (await store
                    .customSelect('SELECT enabled FROM young_daily_sync')
                    .getSingle())
                .read<int>('enabled'),
            0,
          );
          await store.close();
        },
        createHttpClient: (_) {
          networkAttempts++;
          throw StateError('Migration must not create a network client');
        },
      );

      expect(networkAttempts, 0);
      expect(protector.calls, 0);
      expect(_snapshot(file), before);
      final raw = sqlite.sqlite3.open(file.path);
      try {
        expect(raw.select('PRAGMA user_version').single['user_version'], 18);
        expect(
          raw
              .select(
                'SELECT source_retired FROM young_events ORDER BY local_id',
              )
              .map((row) => row['source_retired']),
          [0, 1],
        );
        expect(
          raw
              .select('SELECT source_retired FROM jw_events ORDER BY local_id')
              .map((row) => row['source_retired']),
          [0, 1],
        );
      } finally {
        raw.close();
      }
    },
  );

  test(
    'failed schema 18 migration leaves version and legacy facts intact',
    () async {
      final file = await _legacyFile();
      final raw = sqlite.sqlite3.open(file.path);
      try {
        // An owned synthetic name collision fails CREATE TABLE inside upgrade.
        raw.execute('CREATE TABLE young_daily_sync (synthetic_collision TEXT)');
        raw.execute("INSERT INTO young_daily_sync VALUES ('keep-on-failure')");
      } finally {
        raw.close();
      }
      final before = _snapshot(file);
      await expectLater(_openMigration(file), throwsA(isA<Exception>()));
      expect(_snapshot(file), before);
      final after = sqlite.sqlite3.open(file.path);
      try {
        expect(after.select('PRAGMA user_version').single['user_version'], 17);
        expect(
          after.select('SELECT * FROM young_daily_sync').single,
          containsPair('synthetic_collision', 'keep-on-failure'),
        );
        expect(
          after
              .select('PRAGMA table_info(young_daily_sync)')
              .map((row) => row['name']),
          ['synthetic_collision'],
        );
        after.execute('DROP TABLE young_daily_sync');
      } finally {
        after.close();
      }
      final recovered = await _openMigration(file);
      await recovered.close();
      expect(_snapshot(file), before);
    },
  );

  test(
    'reopening schema 18 preserves opt-in and manual date preferences',
    () async {
      final file = await _legacyFile();
      var store = await _openMigration(file);
      // This is an explicitly owned synthetic persisted preference, not a C3
      // authorization fixture. Runtime permit tests use the public settings port.
      await store.customStatement('UPDATE young_daily_sync SET enabled=1');
      final dailyBefore =
          (await store
                  .customSelect('SELECT * FROM young_daily_sync')
                  .getSingle())
              .data;
      await store.close();
      final before = _snapshot(file);
      store = await _openMigration(file);
      expect(
        (await store.customSelect('SELECT * FROM young_daily_sync').getSingle())
            .data,
        dailyBefore,
      );
      await store.close();
      expect(_snapshot(file), before);
    },
  );
}

Future<JwStore> _openMigration(
  File file, {
  JwCredentialProtector? protector,
}) async {
  final store = JwStore(
    NativeDatabase(file),
    ownership: _Owner(),
    clock: FixedClock(_now),
    credentialProtector: protector,
  );
  addTearDown(store.close);
  try {
    // Open/migrate only: runtime initialize intentionally advances job
    // generations, so keep it separate from schema preservation assertions.
    await store.customSelect('PRAGMA user_version').getSingle();
  } on Object {
    await store.close();
    rethrow;
  }
  return store;
}

Future<File> _legacyFile() async {
  final directory = await Directory.systemTemp.createTemp(
    'young-daily-migration-',
  );
  addTearDown(() async {
    if (directory.absolute.parent.uri != Directory.systemTemp.absolute.uri ||
        !directory.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('young-daily-migration-') ||
        await directory.resolveSymbolicLinks() != directory.absolute.path) {
      throw StateError('Unexpected synthetic daily migration root');
    }
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File ||
          !const {
            'store.sqlite',
            'store.sqlite-wal',
            'store.sqlite-shm',
            'store.sqlite-journal',
          }.contains(entry.uri.pathSegments.last)) {
        throw StateError('Unexpected synthetic daily migration asset');
      }
      await entry.delete();
    }
    await directory.delete();
  });
  final file = File('${directory.path}${Platform.pathSeparator}store.sqlite');
  final store = await _openMigration(file);
  await store.close();
  final raw = sqlite.sqlite3.open(file.path);
  try {
    raw.execute('BEGIN IMMEDIATE');
    raw.execute('DROP TABLE IF EXISTS young_daily_sync');
    raw.execute("INSERT INTO jw_account VALUES(1,'SYNTHETIC18')");
    raw.execute(
      "INSERT INTO jw_credentials VALUES(1,'synthetic-sentinel',X'01020304')",
    );
    raw.execute("INSERT INTO jw_preferences VALUES(1,202610)");
    raw.execute(
      "INSERT INTO young_preferences VALUES(1,'2026-08-01','2026-08-31')",
    );
    // schema 17 retirement is authoritative independently of the latest
    // observation. Upgrading again must not rerun the old retirement backfill.
    for (final (id, retired) in [(1, 0), (2, 1)]) {
      raw.execute(
        'INSERT INTO jw_events(local_id,external_id,kind,semester_id,title,starts_at,ends_at,presence,version,source_retired) '
        "VALUES(?,?,'course',202610,'synthetic course',1,2,'missingWithinScope',5,?)",
        [id, 'synthetic-jw-$id', retired],
      );
      raw.execute(
        "INSERT INTO jw_overlays VALUES(?,1,'synthetic course note','attend','selfStudy')",
        [id],
      );
      raw.execute(
        'INSERT INTO young_events(local_id,external_id,item_id,title,place,starts_at,ends_at,presence,version,source_retired) '
        "VALUES(?,?,'synthetic activity','synthetic young','synthetic room',3,4,'missingWithinScope',7,?)",
        [id, 'synthetic-young-$id', retired],
      );
      raw.execute(
        "INSERT INTO young_overlays VALUES(?,1,'synthetic young note','skip')",
        [id],
      );
    }
    raw.execute(
      'INSERT INTO local_tasks(local_id,version,title,description,note,deadline_at,estimated_minutes,priority,status,deleted,created_at,updated_at) '
      "VALUES(1,4,'synthetic task','synthetic description','synthetic note',10,30,2,'blocked',0,1,2)",
    );
    raw.execute('UPDATE jw_state SET reset_epoch=3,generation=9');
    raw.execute('UPDATE agenda_state SET epoch=5,revision=8');
    raw.execute(
      'UPDATE m6_state SET revision=11,brief_epoch=6,reminders_enabled=1,private_display=1',
    );
    raw.execute(
      "INSERT INTO m6_reminder_overrides VALUES('young',1,0,'[[\"before\",15,0,0],[\"none\",0,0,0]]')",
    );
    raw.execute(
      "INSERT INTO agent_conversations VALUES('synthetic-conversation',2,'synthetic title',1,2)",
    );
    raw.execute(
      'INSERT INTO agent_messages(conversation_id,run_id,role,text,status,created_at,context_private) '
      "VALUES('synthetic-conversation','synthetic-run','assistant','synthetic retained answer','complete',2,1)",
    );
    raw.execute(
      "UPDATE agent_chat_state SET primary_conversation='synthetic-conversation',revision=4,covered_message_id=1,summary='synthetic summary',summary_private=1",
    );
    raw.execute(
      'UPDATE agent_state SET history_epoch=3,request_epoch=4,run_generation=5',
    );
    raw.execute('PRAGMA user_version=17');
    raw.execute('COMMIT');
  } on Object {
    raw.execute('ROLLBACK');
    rethrow;
  } finally {
    raw.close();
  }
  return file;
}

Map<String, Object?> _snapshot(File file) {
  final raw = sqlite.sqlite3.open(file.path);
  try {
    final tables = raw.select(
      "SELECT name,sql FROM sqlite_master WHERE type='table' AND name!='young_daily_sync' ORDER BY name",
    );
    return {
      for (final table in tables)
        table['name'] as String: {
          'schema': table['sql'],
          'rows': [
            for (final row in raw.select(
              'SELECT * FROM "${table['name']}" ORDER BY rowid',
            ))
              {
                for (final entry in row.entries)
                  entry.key: entry.value is List<int>
                      ? List<int>.from(entry.value as List<int>)
                      : entry.value,
              },
          ],
        },
    };
  } finally {
    raw.close();
  }
}

final class _NoCredentialUse implements JwCredentialProtector {
  int calls = 0;
  @override
  String get mechanism => 'synthetic-sentinel';
  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async {
    calls++;
    throw StateError('Migration must not protect credentials');
  }

  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) async {
    calls++;
    throw StateError('Migration must not unprotect credentials');
  }
}

final class _Owner implements AssetOwnership {
  @override
  bool get isHeld => true;
  @override
  void ensureHeld() {}
}
