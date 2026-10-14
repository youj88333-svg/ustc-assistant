import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:ustc_assistant_m0/core/agent_action_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/agent_permission_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

final _now = DateTime.utc(2026, 10, 14, 4);
final _clock = FixedClock(_now);
final _modelKey = Uint8List.fromList('synthetic-schema14-model-key'.codeUnits);

void main() {
  test(
    'schema 13 upgrade preserves synthetic business state and selects the latest legacy chat once',
    () async {
      final file = await _temporaryDatabase('agent-schema14-success-');
      final seeded = await _seedCurrentDatabase(file);
      _rewindToSchema13(file);
      final before = _legacyFacts(file);

      final store = await _open(file);
      expect(await _scalar(store, 'PRAGMA user_version'), 14);
      final settings = await store.agent.inspectAgent();
      expect(settings.modelId, 'synthetic-migration-model');
      expect(settings.keySaved, isTrue);
      expect(settings.consent, isTrue);
      expect(settings.report.capability, ModelCapability.toolReady);

      final conversations = await store.agent.conversations();
      expect(conversations.map((item) => item.id).toSet(), {
        seeded.olderConversation,
        seeded.latestConversation,
      });
      expect(
        (await store.agent.messages(
          seeded.olderConversation,
        )).map((message) => message.text),
        ['旧对话问题', '旧对话答复'],
      );
      expect(
        (await store.agent.messages(
          seeded.latestConversation,
        )).map((message) => message.text),
        ['最新旧对话问题', '最新旧对话答复', '迁移后保留的合成事务', '安全保存的迁移答复'],
      );

      final primary = await store.agent.ensurePrimaryConversation();
      expect(primary, seeded.latestConversation);
      expect(
        await _scalar(
          store,
          'SELECT primary_conversation FROM agent_chat_state WHERE singleton=1',
        ),
        seeded.latestConversation,
      );
      expect(_legacyFacts(file), before);
      await store.customStatement(
        'UPDATE agent_conversations SET updated_at=? WHERE conversation_id=?',
        [
          _now.add(const Duration(days: 90)).microsecondsSinceEpoch,
          seeded.olderConversation,
        ],
      );
      expect(
        await store.agent.ensurePrimaryConversation(),
        seeded.latestConversation,
      );

      expect(await _count(store, 'agent_permissions'), 0);
      final actions = await store
          .customSelect(
            'SELECT status,authorization,committed_count FROM agent_actions',
          )
          .get();
      expect(actions, hasLength(1));
      expect(actions.single.read<String>('status'), 'committed');
      expect(actions.single.read<String>('authorization'), 'legacy');
      expect(actions.single.read<int>('committed_count'), 2);
      expect(await _count(store, 'agenda_plan_receipts'), 1);
      expect(await _count(store, 'personal_events'), 1);
      expect(await _count(store, 'local_tasks'), 1);
      expect(await _count(store, 'jw_events'), 1);
    },
  );

  test(
    'late schema 14 permission-table collision rolls back the whole 13-to-14 migration',
    () async {
      final file = await _temporaryDatabase('agent-schema14-rollback-');
      await _seedCurrentDatabase(file);
      _rewindToSchema13(file);
      _injectPermissionTableCollision(file);
      final before = _legacyFacts(file);

      final failed = JwStore(
        NativeDatabase(file),
        ownership: _TestOwnership(),
        clock: _clock,
        modelCredentialProtector: _SyntheticProtector(),
      );
      addTearDown(failed.close);
      await expectLater(
        failed.initialize(),
        throwsA(
          isA<AppFailure>().having(
            (failure) => failure.code,
            'code',
            FailureCode.storageFailed,
          ),
        ),
      );
      await failed.close();

      final raw = sqlite3.sqlite3.open(file.path);
      try {
        expect(raw.select('PRAGMA user_version').single['user_version'], 13);
        expect(_legacyFactsFromRaw(raw), before);
        expect(
          raw.select(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_chat_state'",
          ),
          isEmpty,
        );
        expect(
          raw
              .select('PRAGMA table_info(agent_actions)')
              .map((row) => row['name'] as String),
          isNot(contains('authorization')),
        );
        expect(
          raw.select('SELECT marker FROM agent_permissions').single['marker'],
          'synthetic-collision-survives',
        );
      } finally {
        raw.close();
      }
    },
  );
}

Future<_SeededDatabase> _seedCurrentDatabase(File file) async {
  final store = await _open(file);
  final settings = await store.agent.inspectAgent();
  await store.agent.saveModelConfiguration(
    settings.authority,
    modelId: 'synthetic-migration-model',
    modelIds: const ['synthetic-migration-model'],
    report: const AgentCapabilityReport(
      text: true,
      streaming: true,
      toolCall: true,
      toolResult: true,
    ),
    consent: true,
    key: _modelKey,
  );

  final older = await store.agent.createConversation();
  final latest = await store.agent.createConversation();
  await _completeRun(store, older, '旧对话问题', '旧对话答复');
  await _completeRun(store, latest, '最新旧对话问题', '最新旧对话答复');
  await store.customStatement(
    'UPDATE agent_conversations SET updated_at=? WHERE conversation_id=?',
    [_now.microsecondsSinceEpoch, older],
  );
  await store.customStatement(
    'UPDATE agent_conversations SET updated_at=? WHERE conversation_id=?',
    [_now.add(const Duration(seconds: 1)).microsecondsSinceEpoch, latest],
  );

  await store.customStatement(
    'INSERT INTO jw_account(account_id,expected_account_code) VALUES(1,?)',
    ['SYNTHETIC14'],
  );
  await store.customStatement(
    'INSERT INTO jw_events(local_id,external_id,kind,semester_id,title,academic_json,starts_at,ends_at,presence,version) '
    'VALUES(1,?,?,?,?,?,?,?,?,?)',
    [
      'synthetic-schema14-course',
      'course',
      202610,
      '合成保留课程',
      null,
      DateTime.utc(2026, 10, 14, 7).microsecondsSinceEpoch,
      DateTime.utc(2026, 10, 14, 8).microsecondsSinceEpoch,
      'observed',
      1,
    ],
  );
  await store.customStatement(
    "INSERT INTO jw_overlays(local_id,hidden,note,attendance,listening) VALUES(1,1,'合成保留备注','attend','listening')",
  );

  final ticket = await store.agent.beginRun(
    (await store.agent.inspectAgent()).authority,
    latest,
    '迁移后保留的合成事务',
  );
  final plans = store.localCalendar as AgentLocalPlanPort;
  final (context, revision) = await plans.readPlanContext();
  final plan = await plans.prepareLocalPlan(ticket, context, revision, [
    AgentCalendarChange(
      CreatePersonalEvent(
        PersonalEventDraft(
          title: '迁移保留的个人事件',
          start: DateTime.utc(2026, 10, 14, 2),
          end: DateTime.utc(2026, 10, 14, 3),
          note: 'synthetic retained event note',
        ),
      ),
    ),
    const AgentCreateTask(
      'migration-task',
      TaskDraft(title: '迁移保留的合成任务', description: 'synthetic retained task'),
    ),
  ]);
  final approval = await (store.localCalendar as AgentLocalPermissionPort)
      .authorizeLocalPlan(plan, mode: AgentAuthorizationMode.confirmed);
  expect(approval, isNotNull);
  await plans.commitLocalPlan(approval!);
  await store.agent.saveAssistant(ticket, '安全保存的迁移答复');
  await store.agent.finishRun(ticket, AgentMessageStatus.complete);
  await store.customStatement(
    'UPDATE agent_conversations SET updated_at=? WHERE conversation_id=?',
    [_now.microsecondsSinceEpoch, older],
  );
  await store.customStatement(
    'UPDATE agent_conversations SET updated_at=? WHERE conversation_id=?',
    [_now.add(const Duration(seconds: 1)).microsecondsSinceEpoch, latest],
  );
  await store.close();
  return _SeededDatabase(older, latest);
}

Future<void> _completeRun(
  JwStore store,
  String conversation,
  String question,
  String answer,
) async {
  final authority = (await store.agent.inspectAgent()).authority;
  final ticket = await store.agent.beginRun(authority, conversation, question);
  await store.agent.saveAssistant(ticket, answer);
  await store.agent.finishRun(ticket, AgentMessageStatus.complete);
}

void _rewindToSchema13(File file) {
  final raw = sqlite3.sqlite3.open(file.path);
  try {
    raw.execute('BEGIN');
    raw.execute('DROP TABLE agent_chat_state');
    raw.execute('DROP TABLE agent_permissions');
    raw.execute('ALTER TABLE agent_actions DROP COLUMN authorization');
    raw.execute('PRAGMA user_version=13');
    raw.execute('COMMIT');
  } on Object {
    raw.execute('ROLLBACK');
    rethrow;
  } finally {
    raw.close();
  }
}

void _injectPermissionTableCollision(File file) {
  final raw = sqlite3.sqlite3.open(file.path);
  try {
    raw.execute('CREATE TABLE agent_permissions(marker TEXT NOT NULL UNIQUE)');
    raw.execute(
      "INSERT INTO agent_permissions(marker) VALUES('synthetic-collision-survives')",
    );
  } finally {
    raw.close();
  }
}

List<Map<String, Object?>> _legacyFacts(File file) {
  final raw = sqlite3.sqlite3.open(file.path);
  try {
    return _legacyFactsFromRaw(raw);
  } finally {
    raw.close();
  }
}

List<Map<String, Object?>> _legacyFactsFromRaw(sqlite3.Database raw) => [
  for (final table in const [
    'agent_config',
    'agent_conversations',
    'agent_runs',
    'agent_messages',
    'agent_actions',
    'agent_audit',
    'agenda_plan_receipts',
    'agenda_plan_audit',
    'agent_preferences',
    'agenda_state',
    'agenda_receipts',
    'agenda_audit',
    'agenda_undo',
    'agenda_relations',
    'jw_account',
    'jw_events',
    'jw_overlays',
    'young_events',
    'young_overlays',
    'personal_events',
    'personal_occurrence_overrides',
    'local_tasks',
    'local_plan_blocks',
  ])
    for (final row in raw.select('SELECT * FROM $table ORDER BY rowid'))
      Map<String, Object?>.from(row)
        ..remove('authorization')
        ..updateAll(
          (key, value) =>
              value is Uint8List ? value.toList(growable: false) : value,
        ),
];

Future<JwStore> _open(File file) async {
  final store = JwStore(
    NativeDatabase(file),
    ownership: _TestOwnership(),
    clock: _clock,
    modelCredentialProtector: _SyntheticProtector(),
  );
  addTearDown(store.close);
  await store.initialize();
  await store.agent.initializeAgent();
  return store;
}

Future<int> _count(JwStore store, String table) async =>
    (await store
            .customSelect('SELECT COUNT(*) AS count FROM $table')
            .getSingle())
        .read<int>('count');

Future<Object?> _scalar(JwStore store, String sql) async =>
    (await store.customSelect(sql).getSingle()).data.values.single;

Future<File> _temporaryDatabase(String prefix) async {
  final directory = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    final root =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}';
    if (!directory.absolute.path.toLowerCase().startsWith(root.toLowerCase()) ||
        !directory.path.split(Platform.pathSeparator).last.startsWith(prefix)) {
      throw StateError('Unexpected synthetic migration directory.');
    }
    const allowed = {
      'store.sqlite',
      'store.sqlite-wal',
      'store.sqlite-shm',
      'store.sqlite-journal',
    };
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File || !allowed.contains(entry.uri.pathSegments.last)) {
        throw StateError('Unexpected synthetic migration file.');
      }
      await entry.delete();
    }
    await directory.delete();
  });
  return File('${directory.path}${Platform.pathSeparator}store.sqlite');
}

final class _SeededDatabase {
  const _SeededDatabase(this.olderConversation, this.latestConversation);
  final String olderConversation;
  final String latestConversation;
}

final class _SyntheticProtector implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-schema14-protector/v1';

  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async =>
      Uint8List.fromList([0xA7, ...plaintext.map((byte) => byte ^ 0x5A)]);

  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) async => Uint8List.fromList(
    ciphertext.skip(1).map((byte) => byte ^ 0x5A).toList(),
  );
}

final class _TestOwnership implements AssetOwnership {
  @override
  bool get isHeld => true;

  @override
  void ensureHeld() {}
}
