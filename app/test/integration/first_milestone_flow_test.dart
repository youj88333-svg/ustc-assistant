import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/import/application/import_service.dart';
import 'package:ustc_assistant_app/features/import/data/source_bundle_decoder.dart';
import 'package:ustc_assistant_app/features/import/domain/import_result.dart';
import 'package:ustc_assistant_app/features/schedule/application/effective_event_repository.dart';
import 'package:ustc_assistant_app/features/schedule/application/overlay_service.dart';

SourceBundleDecoder decoder() => SourceBundleDecoder(
  jsonDecode(
        File(
          'assets/schemas/source-bundle-1.0.draft7.schema.json',
        ).readAsStringSync(),
      )
      as Map<String, dynamic>,
);

void main() {
  test(
    'fixture import preserves user overlay across reimport and restart',
    () async {
      final directory = await Directory.systemTemp.createTemp('ustc-flow');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}${Platform.pathSeparator}app.sqlite');
      var database = AppDatabase(NativeDatabase(file));
      await database
          .into(database.localAccounts)
          .insert(
            LocalAccountsCompanion.insert(
              id: 'acct_fixture',
              maskedHint: 'PB****0000',
              isActive: const Value(true),
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      final importer = ImportService(database: database, decoder: decoder());
      final bytes = File(
        'test/fixtures/source_bundle/positive/jw-with-exam.json',
      ).readAsBytesSync();
      expect(
        (await importer.importBytes(
          bytes,
          accountId: 'acct_fixture',
          origin: ImportOrigin.file,
        )).status,
        ImportStatus.imported,
      );
      final event =
          (await database.select(database.calendarEvents).get()).first;
      await OverlayService(
        database: database,
        accountId: 'acct_fixture',
      ).setEventAttendance(event.id, AttendancePolicy.skip);
      expect(
        (await importer.importBytes(
          bytes,
          accountId: 'acct_fixture',
          origin: ImportOrigin.file,
        )).status,
        ImportStatus.replayed,
      );
      await database.close();

      database = AppDatabase(NativeDatabase(file));
      addTearDown(database.close);
      final overlay = await database.select(database.userOverlays).getSingle();
      expect(overlay.attendancePolicy, 'skip');
      expect(
        await database.select(database.calendarEvents).get(),
        hasLength(2),
      );
      expect(await database.select(database.actionLogs).get(), isNotEmpty);
    },
  );
}
