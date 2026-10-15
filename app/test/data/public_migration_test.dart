import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import '../support/calendar_legacy_schema.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_work_contract.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/core/young_work_contract.dart';
import 'package:ustc_assistant_m0/data/jw_import_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/data/young_import_contract.dart';

void main() {
  test('schema v4 upgrade creates public tables and preserves school facts', () async {
    final directory = await Directory.systemTemp.createTemp(
      'public-store-v4-migration-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final file = File('${directory.path}${Platform.pathSeparator}store.sqlite');
    var store = await _openStore(file);

    try {
      final authority = await store.readAuthority();
      const accountCode = 'AB12345';
      final jwPartition = JwPartitionRef(
        id: 'jwp-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ownerId: authority.ownerId,
        purpose: JwPartitionPurpose.initial,
        attempt: 'jw-0-1',
        resetEpoch: authority.resetEpoch,
      );
      final youngPartition = YoungPartitionRef(
        id: 'yp-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ownerId: authority.ownerId,
        purpose: YoungPartitionPurpose.initial,
        attempt: 'young-0-1',
        resetEpoch: authority.resetEpoch,
      );
      final committedAt = DateTime.utc(2026, 10, 11, 12).microsecondsSinceEpoch;
      final startsAt = DateTime.utc(2026, 6, 10, 1).microsecondsSinceEpoch;
      final endsAt = DateTime.utc(2026, 6, 10, 2).microsecondsSinceEpoch;
      final ciphertext = Uint8List.fromList([0x31, 0x92, 0x05, 0xE7]);

      await store.customStatement(
        'INSERT INTO jw_account (account_id,expected_account_code) VALUES (1,?)',
        [accountCode],
      );
      await store.customStatement(
        'INSERT INTO jw_events '
        '(local_id,external_id,kind,semester_id,title,starts_at,ends_at,presence,version) '
        "VALUES (41,'synthetic-v4-jw-event','course',202610,? ,?,?,'observed',1)",
        ['Synthetic retained course', startsAt, endsAt],
      );
      await store.customStatement(
        'INSERT INTO jw_overlays (local_id,hidden) VALUES (41,1)',
      );
      await store.customStatement(
        'INSERT INTO jw_imports '
        '(operation_id,job_id,content_fingerprint,partition_metadata,course_count,exam_count,account_id,committed_at) '
        'VALUES (?,?,?,?,1,0,1,?)',
        [
          'jw-import-v4-synthetic',
          'jw-0-1',
          List<String>.filled(64, 'a').join(),
          jsonEncode(jwPartition.metadata),
          committedAt,
        ],
      );
      await store.customStatement(
        'INSERT INTO jw_audit (action,course_count,exam_count,committed_at) '
        "VALUES ('import',1,0,?)",
        [committedAt],
      );
      await store.customStatement(
        'INSERT INTO jw_permits (partition_id,partition_metadata,account_id) '
        'VALUES (?,?,1)',
        [jwPartition.id, jsonEncode(jwPartition.metadata)],
      );
      await store.customStatement(
        'INSERT INTO jw_local_receipts '
        '(operation_id,fingerprint,result_version,hidden,committed_at) '
        'VALUES (?,?,?,?,?)',
        [
          'jw-local-v4-synthetic',
          List<String>.filled(64, 'b').join(),
          2,
          1,
          committedAt,
        ],
      );
      await store.customStatement(
        'INSERT INTO jw_credentials (account_id,mechanism,ciphertext) VALUES (1,?,?)',
        ['synthetic-test-protector', ciphertext],
      );
      await store.customStatement(
        'INSERT INTO jw_preferences (account_id,semester_id) VALUES (1,202610)',
      );
      await store.customStatement(
        'INSERT INTO jw_semester_catalog (account_id,options_json,updated_at) '
        'VALUES (1,?,?)',
        [
          jsonEncode([
            {'id': 202610, 'name': 'Synthetic 2026 autumn', 'selected': true},
          ]),
          committedAt,
        ],
      );

      await store.customStatement(
        'INSERT INTO young_events '
        '(local_id,external_id,item_id,title,place,starts_at,ends_at,presence,version) '
        "VALUES (51,'synthetic-v4-young-event','activity-17',?,'Synthetic campus',?,?,'observed',1)",
        ['Synthetic linked calendar event', startsAt, endsAt],
      );
      await store.customStatement(
        'INSERT INTO young_overlays (local_id,hidden) VALUES (51,1)',
      );
      await store.customStatement(
        'INSERT INTO young_receipts '
        '(operation_id,job_id,kind,content_fingerprint,partition_metadata,item_count,account_id,committed_at) '
        "VALUES ('young-import-v4-synthetic','young-0-1','calendar',?,?,1,1,?)",
        [
          List<String>.filled(64, 'c').join(),
          jsonEncode(youngPartition.metadata),
          committedAt,
        ],
      );
      await store.customStatement(
        'INSERT INTO young_permits (partition_id,partition_metadata,account_id) '
        'VALUES (?,?,1)',
        [youngPartition.id, jsonEncode(youngPartition.metadata)],
      );
      await store.customStatement(
        'INSERT INTO young_preferences (account_id,first_day,last_day) '
        "VALUES (1,'2026-06-10','2026-06-10')",
      );
      await store.customStatement(
        'INSERT INTO young_audit (action,item_count,committed_at) '
        "VALUES ('import',1,?)",
        [committedAt],
      );
      await store.customStatement(
        'INSERT INTO young_local_receipts '
        '(operation_id,fingerprint,result_version,hidden,committed_at) '
        'VALUES (?,?,?,?,?)',
        [
          'young-local-v4-synthetic',
          List<String>.filled(64, 'd').join(),
          2,
          1,
          committedAt,
        ],
      );

      final beforeJw = await store.readView();
      final beforeYoung = await store.readYoungView();
      final beforeAuthority = await store.readAuthority();
      final beforeCiphertext = await _credentialCiphertext(store);
      expect(beforeJw.accountBound, isTrue);
      expect(beforeJw.courseCount, 1);
      expect(beforeJw.examCount, 0);
      expect(beforeJw.importCount, 1);
      expect(beforeJw.auditCount, 1);
      expect(beforeJw.credentialSaved, isTrue);
      expect(beforeJw.lastSemesterId, 202610);
      expect(beforeJw.cachedSemesters, hasLength(1));
      expect(beforeJw.events.single.hidden, isTrue);
      expect(beforeYoung.importCount, 1);
      expect(beforeYoung.queryCount, 0);
      expect(beforeYoung.auditCount, 1);
      expect(beforeYoung.credentialSaved, isTrue);
      expect(beforeYoung.firstDay, DateTime.utc(2026, 6, 10));
      expect(beforeYoung.lastDay, DateTime.utc(2026, 6, 10));
      expect(beforeYoung.events.single.hidden, isTrue);
      expect(beforeCiphertext, isNotNull);
      final beforeJwPermits = await store.readCommittedPermits();
      final beforeYoungPermits = await store.readYoungPermits();
      expect(beforeJwPermits, hasLength(1));
      expect(beforeYoungPermits, hasLength(1));
      final beforeRowCounts = await _retainedRowCounts(store);

      await store.close();
      final raw = sqlite3.sqlite3.open(file.path);
      try {
        raw.execute('ALTER TABLE jw_events DROP COLUMN source_retired');
        raw.execute('ALTER TABLE young_events DROP COLUMN source_retired');
        removeCalendarTablesForLegacyFixture(raw);
        for (final table in const [
          'knowledge_load_items',
          'knowledge_sections',
          'knowledge_audit',
          'knowledge_loads',
          'knowledge_materials',
          'knowledge_state',
          'public_sources',
        ]) {
          raw.execute('DROP TABLE $table');
        }
        for (final table in const [
          'm6_state',
          'm6_expected',
          'm6_reminder_overrides',
          'm6_native_map',
          'm6_briefs',
          'm6_brief_suppressed',
        ]) {
          raw.execute('DROP TABLE IF EXISTS $table');
        }
        raw.execute('PRAGMA user_version = 4');
      } finally {
        raw.close();
      }

      store = await _openStore(file);
      expect(
        (await store.customSelect('PRAGMA user_version').getSingle()).read<int>(
          'user_version',
        ),
        18,
      );
      final afterJw = await store.readView();
      final afterYoung = await store.readYoungView();
      final afterAuthority = await store.readAuthority();
      expect(_jwFacts(afterJw), _jwFacts(beforeJw));
      expect(_youngFacts(afterYoung), _youngFacts(beforeYoung));
      expect(afterJw.events.single.sourceRetired, isFalse);
      expect(afterYoung.events.single.sourceRetired, isFalse);
      expect(afterAuthority.ownerId, beforeAuthority.ownerId);
      expect(afterAuthority.resetEpoch, beforeAuthority.resetEpoch);
      expect(
        await _credentialCiphertext(store),
        orderedEquals(beforeCiphertext!),
      );
      final afterJwPermits = await store.readCommittedPermits();
      final afterYoungPermits = await store.readYoungPermits();
      expect(afterJwPermits, hasLength(1));
      expect(afterYoungPermits, hasLength(1));
      expect(afterJwPermits.single.accountId, beforeJwPermits.single.accountId);
      expect(
        afterJwPermits.single.partition.sameAs(
          beforeJwPermits.single.partition,
        ),
        isTrue,
      );
      expect(
        afterYoungPermits.single.accountId,
        beforeYoungPermits.single.accountId,
      );
      expect(
        afterYoungPermits.single.partition.sameAs(
          beforeYoungPermits.single.partition,
        ),
        isTrue,
      );
      expect(await _retainedRowCounts(store), beforeRowCounts);

      final publicStore = store.publicStore;
      expect(await publicStore.hasIcourseConsent(), isFalse);
      final knowledge = await publicStore.inspectKnowledge();
      expect(knowledge.materialCount, 0);
      expect(knowledge.sectionCount, 0);
      expect(knowledge.loadCount, 0);
      expect(knowledge.loading, isFalse);
      expect(knowledge.edition, isNull);
      expect(await _count(store, 'knowledge_loads'), 0);
      expect(await _count(store, 'knowledge_load_items'), 0);
      expect(await _count(store, 'knowledge_audit'), 0);
      expect((await publicStore.searchKnowledge('缓考')).candidates, isEmpty);

      final publicAuthority = await publicStore.publicAuthority(
        PublicSource.campus,
      );
      expect(publicAuthority.source, PublicSource.campus);
      final ticket = await publicStore.beginPublicJob(PublicSource.campus);
      await publicStore.ensurePublicJob(ticket);
      await publicStore.finishPublicJob(ticket);
    } finally {
      await store.close();
    }
  });
}

Future<JwStore> _openStore(File file) async {
  final store = JwStore(
    NativeDatabase(file, logStatements: false),
    ownership: _TestOwnership(),
    clock: FixedClock(DateTime.utc(2026, 10, 11, 12)),
  );
  await store.initialize();
  return store;
}

Object _jwFacts(JwDataView view) => [
  view.accountBound,
  view.courseCount,
  view.examCount,
  view.importCount,
  view.auditCount,
  view.credentialSaved,
  view.lastSemesterId,
  view.cachedSemesters
      .map((option) => (option.id, option.name, option.selected))
      .toList(),
  view.semesterCatalogUpdatedAtUtc,
  view.events
      .map(
        (event) => (
          event.localId,
          event.version,
          event.kind,
          event.semesterId,
          event.title,
          event.startsAtUtc,
          event.endsAtUtc,
          event.presence,
          event.hidden,
        ),
      )
      .toList(),
];

Object _youngFacts(YoungDataView view) => [
  view.accountBound,
  view.credentialSaved,
  view.importCount,
  view.queryCount,
  view.auditCount,
  view.firstDay,
  view.lastDay,
  view.events
      .map(
        (event) => (
          event.localId,
          event.version,
          event.title,
          event.place,
          event.startsAtUtc,
          event.endsAtUtc,
          event.presence,
          event.hidden,
        ),
      )
      .toList(),
];

Future<Uint8List?> _credentialCiphertext(JwStore store) async {
  final row = await store
      .customSelect('SELECT ciphertext FROM jw_credentials WHERE account_id=1')
      .getSingleOrNull();
  final bytes = row?.read<Uint8List>('ciphertext');
  return bytes == null ? null : Uint8List.fromList(bytes);
}

Future<Map<String, int>> _retainedRowCounts(JwStore store) async => {
  for (final table in const [
    'jw_imports',
    'jw_audit',
    'jw_permits',
    'jw_local_receipts',
    'young_receipts',
    'young_audit',
    'young_permits',
    'young_local_receipts',
  ])
    table: await _count(store, table),
};

Future<int> _count(JwStore store, String table) async {
  final row = await store
      .customSelect('SELECT COUNT(*) AS count FROM $table')
      .getSingle();
  return row.read<int>('count');
}

final class _TestOwnership implements AssetOwnership {
  @override
  bool get isHeld => true;

  @override
  void ensureHeld() {}
}
