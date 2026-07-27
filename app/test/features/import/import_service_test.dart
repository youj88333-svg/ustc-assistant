import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/import/application/import_service.dart';
import 'package:ustc_assistant_app/features/import/application/reminder_reconciler.dart';
import 'package:ustc_assistant_app/features/import/data/source_bundle_decoder.dart';
import 'package:ustc_assistant_app/features/import/domain/import_result.dart';
import 'package:ustc_assistant_app/features/import/domain/source_bundle_error.dart';

Uint8List fixture(String name) =>
    File('test/fixtures/source_bundle/positive/$name').readAsBytesSync();

SourceBundleDecoder testDecoder() => SourceBundleDecoder(
  jsonDecode(
        File(
          'assets/schemas/source-bundle-1.0.draft7.schema.json',
        ).readAsStringSync(),
      )
      as Map<String, dynamic>,
);

Future<AppDatabase> testDatabase() async {
  final db = AppDatabase(NativeDatabase.memory());
  await db
      .into(db.localAccounts)
      .insert(
        LocalAccountsCompanion.insert(
          id: 'acct_fixture',
          maskedHint: 'PB****0000',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
  return db;
}

class RecordingReconciler implements ReminderReconciler {
  final calls = <({String accountId, String source})>[];
  bool fail = false;

  @override
  Future<void> reconcile({
    required String accountId,
    required String source,
  }) async {
    calls.add((accountId: accountId, source: source));
    if (fail) {
      throw StateError('adapter unavailable');
    }
  }
}

void main() {
  test('reimport is idempotent and preserves overlay', () async {
    final db = await testDatabase();
    addTearDown(db.close);
    final service = ImportService(database: db, decoder: testDecoder());

    final first = await service.importBytes(
      fixture('jw-with-exam.json'),
      accountId: 'acct_fixture',
      origin: ImportOrigin.file,
    );
    final event = (await db.select(db.calendarEvents).get()).first;
    await db
        .into(db.userOverlays)
        .insert(
          UserOverlaysCompanion.insert(
            id: 'overlay',
            accountId: 'acct_fixture',
            eventId: Value(event.id),
            userNotes: const Value('保留这条备注'),
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    final replay = await service.importBytes(
      fixture('jw-with-exam.json'),
      accountId: 'acct_fixture',
      origin: ImportOrigin.file,
    );

    expect(first.status, ImportStatus.imported);
    expect(replay.status, ImportStatus.replayed);
    expect(await db.select(db.calendarEvents).get(), hasLength(2));
    expect((await db.select(db.userOverlays).get()).single.userNotes, '保留这条备注');
  });

  test('validation failure writes no import rows', () async {
    final db = await testDatabase();
    addTearDown(db.close);
    final service = ImportService(database: db, decoder: testDecoder());
    final json =
        jsonDecode(utf8.decode(fixture('jw-with-exam.json')))
            as Map<String, dynamic>;
    (json['manifest'] as Map<String, dynamic>)['calendarEventCount'] = 99;

    expect(
      service.importBytes(
        Uint8List.fromList(utf8.encode(jsonEncode(json))),
        accountId: 'acct_fixture',
        origin: ImportOrigin.file,
      ),
      throwsA(isA<SourceBundleError>()),
    );
    expect(await db.select(db.importBatches).get(), isEmpty);
    expect(await db.select(db.calendarEvents).get(), isEmpty);
    expect(await db.select(db.actionLogs).get(), isEmpty);
  });

  test('bundle subject must match the explicit target account', () async {
    final db = await testDatabase();
    addTearDown(db.close);
    final service = ImportService(database: db, decoder: testDecoder());

    expect(
      service.importBytes(
        fixture('young-empty-window.json'),
        accountId: 'another-account',
        origin: ImportOrigin.file,
      ),
      throwsA(
        isA<SourceBundleError>().having(
          (error) => error.code,
          'code',
          'subject_mismatch',
        ),
      ),
    );
  });

  test('same bundle id with different digest is rejected', () async {
    final db = await testDatabase();
    addTearDown(db.close);
    final service = ImportService(database: db, decoder: testDecoder());
    final bytes = fixture('young-empty-window.json');
    await service.importBytes(
      bytes,
      accountId: 'acct_fixture',
      origin: ImportOrigin.file,
    );
    final changed = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    (changed['producer'] as Map<String, dynamic>)['version'] = '0.1.1';

    expect(
      service.importBytes(
        Uint8List.fromList(utf8.encode(jsonEncode(changed))),
        accountId: 'acct_fixture',
        origin: ImportOrigin.file,
      ),
      throwsA(
        isA<SourceBundleError>().having(
          (error) => error.code,
          'code',
          'duplicate_identity',
        ),
      ),
    );
  });

  test('new bundle id with identical content is a content replay', () async {
    final db = await testDatabase();
    addTearDown(db.close);
    final service = ImportService(database: db, decoder: testDecoder());
    final original = fixture('young-empty-window.json');
    await service.importBytes(
      original,
      accountId: 'acct_fixture',
      origin: ImportOrigin.file,
    );
    final changed = jsonDecode(utf8.decode(original)) as Map<String, dynamic>;
    changed['bundleId'] = '00000000-0000-4000-8000-000000000099';

    final result = await service.importBytes(
      Uint8List.fromList(utf8.encode(jsonEncode(changed))),
      accountId: 'acct_fixture',
      origin: ImportOrigin.file,
    );

    expect(result.status, ImportStatus.imported);
    expect(await db.select(db.importBatches).get(), hasLength(2));
  });

  test(
    'reconciler runs only after committed import and failure is retryable',
    () async {
      final db = await testDatabase();
      addTearDown(db.close);
      final reconciler = RecordingReconciler()..fail = true;
      final service = ImportService(
        database: db,
        decoder: testDecoder(),
        reminderReconciler: reconciler,
      );

      final result = await service.importBytes(
        fixture('young-empty-window.json'),
        accountId: 'acct_fixture',
        origin: ImportOrigin.bridge,
      );

      expect(result.reminderReconciliationPending, isTrue);
      expect(reconciler.calls, [
        (accountId: 'acct_fixture', source: 'ustc_young_my_schedule'),
      ]);
      expect(await db.select(db.importBatches).get(), hasLength(1));
    },
  );

  test(
    'a newer complete snapshot marks absent records within scope missing',
    () async {
      final db = await testDatabase();
      addTearDown(db.close);
      final service = ImportService(database: db, decoder: testDecoder());
      final first = fixture('young-with-schedule.json');
      await service.importBytes(
        first,
        accountId: 'acct_fixture',
        origin: ImportOrigin.bridge,
      );
      final importedEvent = await db.select(db.calendarEvents).getSingle();
      await db
          .into(db.userOverlays)
          .insert(
            UserOverlaysCompanion.insert(
              id: 'keep-overlay',
              accountId: 'acct_fixture',
              eventId: Value(importedEvent.id),
              userNotes: const Value('keep'),
              createdAt: 1,
              updatedAt: 1,
            ),
          );

      final empty =
          jsonDecode(utf8.decode(fixture('young-empty-window.json')))
              as Map<String, dynamic>;
      empty['bundleId'] = '00000000-0000-4000-8000-000000000088';
      await service.importBytes(
        Uint8List.fromList(utf8.encode(jsonEncode(empty))),
        accountId: 'acct_fixture',
        origin: ImportOrigin.bridge,
      );

      expect(
        (await db.select(db.sourceRecords).get()).single.presence,
        'missing_within_scope',
      );
      expect(await db.select(db.calendarEvents).get(), hasLength(1));
      expect((await db.select(db.userOverlays).get()).single.userNotes, 'keep');
    },
  );
}
