import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/settings_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

final _now = DateTime.utc(2026, 10, 13, 8);
final _clock = FixedClock(_now);
final _key = Uint8List.fromList('synthetic-journal-key'.codeUnits);

void main() {
  test(
    'journal survives reopen as bounded message metadata and image count only',
    () async {
      final file = await _temporaryDatabase('agent-journal-persist-');
      var store = await _open(file: file);
      await _configure(store);
      final conversation = await store.agent.createConversation();
      final ticket = await _beginRun(store, conversation, '合成日程与资料问题');
      await store.agent.saveAssistant(ticket, '请在日程页核对合成安排。');

      final AgentRunJournalPort journal = store.agent;
      await journal.ensureAgentRun(ticket);
      final steps = List.generate(
        48,
        (index) => AgentToolStep(
          tool: index.isEven ? 'query_agenda' : 'search_knowledge',
          status: index.isEven ? 'success' : 'empty',
        ),
      );
      await journal.saveRunJournal(
        ticket,
        evidence: [_evidence()],
        steps: steps,
        imageCount: 2,
      );
      await store.agent.finishRun(ticket, AgentMessageStatus.complete);

      var messages = await store.agent.messages(conversation);
      expect(messages, hasLength(2));
      expect(messages.first.role, AgentMessageRole.user);
      expect(messages.first.imageCount, 2);
      expect(messages.first.evidence, isEmpty);
      expect(messages.last.role, AgentMessageRole.assistant);
      expect(messages.last.text, '请在日程页核对合成安排。');
      expect(messages.last.evidence.single.id, 'e_0123456789abcdef');
      expect(messages.last.evidence.single.snippet, '合成摘录：周二 10:00–11:00');
      expect(messages.last.steps, hasLength(48));
      expect(
        messages.last.steps.map((step) => '${step.tool}:${step.status}'),
        steps.map((step) => '${step.tool}:${step.status}'),
      );

      final stored = await store
          .customSelect(
            'SELECT evidence_json,steps_json,image_count FROM agent_messages ORDER BY message_id',
          )
          .get();
      expect(jsonDecode(stored.first.read<String>('evidence_json')), isEmpty);
      expect(
        jsonDecode(stored.last.read<String>('evidence_json')),
        hasLength(1),
      );
      expect(stored.first.read<int>('image_count'), 2);
      expect(stored.last.read<int>('image_count'), 0);
      final storedEvidence =
          (jsonDecode(stored.last.read<String>('evidence_json')) as List).single
              as Map<String, dynamic>;
      expect(
        storedEvidence.keys.toSet(),
        unorderedEquals({
          'id',
          'provider',
          'title',
          'observedAtUtc',
          'scope',
          'complete',
          'articleUrl',
          'materialUrl',
          'publishedOn',
          'updatedOn',
          'revision',
          'locator',
          'sourceVersion',
          'snippet',
          'applicability',
        }),
      );
      expect(
        jsonDecode(stored.last.read<String>('steps_json')),
        steps
            .map((step) => {'tool': step.tool, 'status': step.status})
            .toList(),
      );
      expect(
        (await store.customSelect('PRAGMA table_info(agent_messages)').get())
            .map((row) => row.read<String>('name')),
        isNot(contains('image_bytes')),
      );

      await store.close();
      store = await _open(file: file);
      messages = await store.agent.messages(conversation);
      expect(messages.last.evidence.single.title, '合成日程出处');
      expect(messages.last.evidence.single.sourceVersion, 'synthetic-v1');
      expect(messages.last.steps, hasLength(48));
      expect(
        messages.last.steps.map((step) => '${step.tool}:${step.status}'),
        steps.map((step) => '${step.tool}:${step.status}'),
      );
      expect(messages.first.imageCount, 2);
    },
  );

  test(
    'journal requires the exact active ticket and rejects stopped tickets',
    () async {
      final store = await _open();
      await _configure(store);
      final conversation = await store.agent.createConversation();
      final ticket = await _beginRun(store, conversation, '核验运行票据');
      final AgentRunJournalPort journal = store.agent;

      final twin = AgentRunTicket(
        authority: ticket.authority,
        runId: ticket.runId,
        conversationId: ticket.conversationId,
        conversationGeneration: ticket.conversationGeneration,
        runGeneration: ticket.runGeneration,
        assistantMessageId: ticket.assistantMessageId,
      );
      await _agentFailure(
        journal.ensureAgentRun(twin),
        AgentFailureCode.staleContext,
      );
      await _agentFailure(
        journal.saveRunJournal(
          twin,
          evidence: [_evidence()],
          steps: const [],
          imageCount: 0,
        ),
        AgentFailureCode.staleContext,
      );

      final wrongMessage = AgentRunTicket(
        authority: ticket.authority,
        runId: ticket.runId,
        conversationId: ticket.conversationId,
        conversationGeneration: ticket.conversationGeneration,
        runGeneration: ticket.runGeneration,
        assistantMessageId: ticket.assistantMessageId + 1,
      );
      await _agentFailure(
        journal.ensureAgentRun(wrongMessage),
        AgentFailureCode.staleContext,
      );
      await journal.ensureAgentRun(ticket);
      await store.agent.cancelRun(ticket);
      await _agentFailure(
        journal.saveRunJournal(
          ticket,
          evidence: [_evidence()],
          steps: const [],
          imageCount: 1,
        ),
        AgentFailureCode.staleContext,
      );
      expect((await store.agent.messages(conversation)).last.evidence, isEmpty);
    },
  );

  test(
    'journal rejects unsafe provenance, secret snippets, and invalid image counts',
    () async {
      final store = await _open();
      await _configure(store);
      final conversation = await store.agent.createConversation();
      final ticket = await _beginRun(store, conversation, '检查不可信合成出处');
      final AgentRunJournalPort journal = store.agent;

      await _agentFailure(
        journal.saveRunJournal(
          ticket,
          evidence: [_evidence(snippet: 'password: synthetic-secret-123')],
          steps: const [],
          imageCount: 0,
        ),
        AgentFailureCode.secretDetected,
      );
      await _agentFailure(
        journal.saveRunJournal(
          ticket,
          evidence: [_evidence(id: 'db-row-17')],
          steps: const [],
          imageCount: 0,
        ),
        AgentFailureCode.invalidInput,
      );
      await _agentFailure(
        journal.saveRunJournal(
          ticket,
          evidence: [_evidence(), _evidence()],
          steps: const [],
          imageCount: 0,
        ),
        AgentFailureCode.invalidInput,
      );
      await _agentFailure(
        journal.saveRunJournal(
          ticket,
          evidence: [_evidence(provider: 'unknown-school')],
          steps: const [],
          imageCount: 0,
        ),
        AgentFailureCode.invalidInput,
      );
      await _agentFailure(
        journal.saveRunJournal(
          ticket,
          evidence: const [],
          steps: const [
            AgentToolStep(tool: 'query_agenda', status: 'not-a-status'),
          ],
          imageCount: 0,
        ),
        AgentFailureCode.invalidInput,
      );
      await _agentFailure(
        journal.saveRunJournal(
          ticket,
          evidence: [
            _evidence(articleUrl: 'https://outside.example.invalid/article'),
          ],
          steps: const [],
          imageCount: 0,
        ),
        AgentFailureCode.invalidInput,
      );
      await _agentFailure(
        journal.saveRunJournal(
          ticket,
          evidence: const [],
          steps: const [AgentToolStep(tool: 'open_url', status: 'success')],
          imageCount: 0,
        ),
        AgentFailureCode.invalidInput,
      );
      await _agentFailure(
        journal.saveRunJournal(
          ticket,
          evidence: const [],
          steps: const [],
          imageCount: 4,
        ),
        AgentFailureCode.invalidInput,
      );
      expect((await store.agent.messages(conversation)).last.evidence, isEmpty);
      expect((await store.agent.messages(conversation)).first.imageCount, 0);
    },
  );

  test(
    'journal enforces evidence, step-count, serialized-size, and snippet bounds',
    () async {
      final store = await _open();
      await _configure(store);
      final conversation = await store.agent.createConversation();
      final ticket = await _beginRun(store, conversation, '检查证据边界');
      final AgentRunJournalPort journal = store.agent;
      final evidence = _evidenceBatch(64);
      final steps = List.generate(
        48,
        (_) => const AgentToolStep(tool: 'query_agenda', status: 'success'),
      );
      await journal.saveRunJournal(
        ticket,
        evidence: evidence,
        steps: steps,
        imageCount: 3,
      );
      await _agentFailure(
        journal.saveRunJournal(
          ticket,
          evidence: _evidenceBatch(65),
          steps: const [],
          imageCount: 0,
        ),
        AgentFailureCode.invalidInput,
      );
      await _agentFailure(
        journal.saveRunJournal(
          ticket,
          evidence: const [],
          steps: List.generate(
            256,
            (_) => const AgentToolStep(tool: 'query_agenda', status: 'success'),
          ),
          imageCount: 0,
        ),
        AgentFailureCode.resourceLimit,
      );
      await _agentFailure(
        journal.saveRunJournal(
          ticket,
          evidence: const [],
          steps: List.generate(
            257,
            (_) => const AgentToolStep(tool: 'query_agenda', status: 'success'),
          ),
          imageCount: 0,
        ),
        AgentFailureCode.invalidInput,
      );
      await _agentFailure(
        journal.saveRunJournal(
          ticket,
          evidence: [_evidence(snippet: List<String>.filled(401, '摘录').join())],
          steps: const [],
          imageCount: 0,
        ),
        AgentFailureCode.resourceLimit,
      );
      final saved = (await store.agent.messages(conversation)).last;
      expect(saved.evidence, hasLength(64));
      expect(saved.steps, hasLength(48));
    },
  );

  test(
    'journal checkpoint failure rolls back only the attempted journal write',
    () async {
      var failCheckpoint = false;
      final store = await _open(
        checkpoint: () async {
          if (failCheckpoint) throw StateError('synthetic journal checkpoint');
        },
      );
      await _configure(store);
      final conversation = await store.agent.createConversation();
      final ticket = await _beginRun(store, conversation, '检查事务回滚');
      await store.agent.saveAssistant(ticket, '已提交的合成正文');
      final AgentRunJournalPort journal = store.agent;
      await journal.saveRunJournal(
        ticket,
        evidence: [_evidence()],
        steps: const [AgentToolStep(tool: 'query_agenda', status: 'success')],
        imageCount: 1,
      );

      failCheckpoint = true;
      await _agentFailure(
        journal.saveRunJournal(
          ticket,
          evidence: [_evidence(id: 'e_fedcba9876543210', title: '新合成出处')],
          steps: const [AgentToolStep(tool: 'read_event', status: 'success')],
          imageCount: 3,
        ),
        AgentFailureCode.storageFailed,
      );
      failCheckpoint = false;

      final messages = await store.agent.messages(conversation);
      expect(messages.last.text, '已提交的合成正文');
      expect(messages.last.evidence.single.title, '合成日程出处');
      expect(messages.last.steps.single.tool, 'query_agenda');
      expect(messages.first.imageCount, 1);
    },
  );

  test(
    'history clear removes journals while agenda and knowledge clear retain history until reset',
    () async {
      final store = await _open();
      await _configure(store);
      final removedConversation = await store.agent.createConversation();
      await _completeJournal(store, removedConversation, '第一条合成对话');
      final retainedConversation = await store.agent.createConversation();
      await _completeJournal(store, retainedConversation, '第二条合成对话');

      final selectedClear = await store.agent.beginClearHistory(
        (await store.agent.inspectAgent()).authority,
        conversationId: removedConversation,
      );
      await store.agent.completeClearHistory(selectedClear);
      expect(await store.agent.messages(removedConversation), isEmpty);
      expect(await store.agent.messages(retainedConversation), hasLength(2));
      expect(
        (await store.agent.messages(
          retainedConversation,
        )).last.evidence.single.id,
        'e_0123456789abcdef',
      );

      final allClear = await store.agent.beginClearHistory(
        (await store.agent.inspectAgent()).authority,
      );
      await store.agent.completeClearHistory(allClear);
      expect(await store.agent.conversations(), isEmpty);
      expect(await _count(store, 'agent_messages'), 0);

      final afterHistoryClear = await store.agent.createConversation();
      await _completeJournal(store, afterHistoryClear, '维护前的合成历史');
      await _seedPersonalEvent(store);
      await store.customStatement(
        "INSERT INTO knowledge_materials(material_key,revision,metadata_json,markdown,title_search,provider,topic,audience,source_version,accepted_at,byte_count) VALUES ('journal-synthetic','v1','{}','# 合成知识资料','合成知识资料','teach','guide','student','synthetic-v1',0,20)",
      );

      final settingsBeforeAgendaClear = await store.applicationSettings
          .inspectSettings();
      final agendaRequest = await store.applicationSettings.prepareMaintenance(
        settingsBeforeAgendaClear.context,
        MaintenanceKind.agenda,
        confirmed: true,
      );
      final agendaIntent = await store.applicationSettings.beginMaintenance(
        agendaRequest,
      );
      await store.applicationSettings.completeMaintenance(agendaIntent);
      expect(await _count(store, 'personal_events'), 0);
      expect(
        (await store.agent.messages(
          afterHistoryClear,
        )).last.evidence.single.title,
        '合成日程出处',
      );

      await store.publicStore.clearKnowledge(confirmed: true);
      expect(await _count(store, 'knowledge_materials'), 0);
      expect(
        (await store.agent.messages(afterHistoryClear)).last.steps.single.tool,
        'query_agenda',
      );

      final settingsBeforeReset = await store.applicationSettings
          .inspectSettings();
      final resetRequest = await store.applicationSettings.prepareMaintenance(
        settingsBeforeReset.context,
        MaintenanceKind.reset,
        confirmed: true,
      );
      final resetIntent = await store.applicationSettings.beginMaintenance(
        resetRequest,
      );
      await store.applicationSettings.completeMaintenance(resetIntent);
      expect(await store.agent.conversations(), isEmpty);
      expect(await store.agent.messages(afterHistoryClear), isEmpty);
      expect(await _count(store, 'agent_messages'), 0);
      final resetAgent = await store.agent.inspectAgent();
      expect(resetAgent.keySaved, isFalse);
      expect(resetAgent.modelId, isNull);
    },
  );

  test(
    'schema 11 fixture gains empty journal fields and retains prior facts',
    () async {
      final file = await _temporaryDatabase('agent-journal-v11-');
      var store = await _open(file: file);
      await _configure(store);
      await _seedPersonalEvent(store);
      final beforeOwner = await _scalar(store, 'SELECT owner_id FROM jw_state');
      final conversation = await store.agent.createConversation();
      await _completeJournal(
        store,
        conversation,
        'schema eleven synthetic message',
      );
      final oldMessageText = (await store.agent.messages(
        conversation,
      )).last.text;
      await store.close();
      _rewindMessagesToSchema11(file);

      store = await _open(file: file);
      expect(await _scalar(store, 'PRAGMA user_version'), 18);
      expect(
        await _scalar(store, 'SELECT owner_id FROM jw_state'),
        beforeOwner,
      );
      expect(await _count(store, 'personal_events'), 1);
      final messages = await store.agent.messages(conversation);
      expect(messages, hasLength(2));
      expect(messages.last.text, oldMessageText);
      expect(messages.last.status, AgentMessageStatus.complete);
      expect(messages.last.evidence, isEmpty);
      expect(messages.last.steps, isEmpty);
      expect(messages.last.imageCount, 0);
      expect(messages.first.imageCount, 0);
      expect((await store.agent.inspectAgent()).keySaved, isTrue);
    },
  );

  test('future schema is rejected without changing stored history', () async {
    final file = await _temporaryDatabase('agent-journal-future-');
    var store = await _open(file: file);
    await _configure(store);
    final conversation = await store.agent.createConversation();
    await _completeJournal(store, conversation, 'future schema sentinel');
    await store.close();
    _setSchemaVersion(file, 19);

    await expectLater(
      _open(file: file),
      throwsA(
        isA<AppFailure>().having(
          (failure) => failure.code,
          'code',
          FailureCode.storageFailed,
        ),
      ),
    );
    final raw = sqlite3.sqlite3.open(file.path);
    try {
      expect(raw.select('PRAGMA user_version').single['user_version'], 19);
      expect(
        raw
            .select('SELECT text FROM agent_messages WHERE role=\'assistant\'')
            .single['text'],
        '安全保存的合成答复：future schema sentinel',
      );
    } finally {
      raw.close();
    }
  });

  test('schema 11 column collision rolls back the journal migration', () async {
    final file = await _temporaryDatabase('agent-journal-collision-');
    var store = await _open(file: file);
    await _configure(store);
    final conversation = await store.agent.createConversation();
    await _completeJournal(store, conversation, 'collision sentinel');
    await store.close();
    _rewindMessagesToSchema11(file, withStepsColumnCollision: true);

    await expectLater(
      _open(file: file),
      throwsA(
        isA<AppFailure>().having(
          (failure) => failure.code,
          'code',
          FailureCode.storageFailed,
        ),
      ),
    );
    final raw = sqlite3.sqlite3.open(file.path);
    try {
      expect(raw.select('PRAGMA user_version').single['user_version'], 11);
      final columns = raw
          .select('PRAGMA table_info(agent_messages)')
          .map((row) => row['name'] as String)
          .toSet();
      expect(columns, contains('steps_json'));
      expect(columns, isNot(contains('evidence_json')));
      expect(columns, isNot(contains('image_count')));
      expect(
        raw
            .select('SELECT text FROM agent_messages WHERE role=\'assistant\'')
            .single['text'],
        '安全保存的合成答复：collision sentinel',
      );
    } finally {
      raw.close();
    }
  });
}

Future<JwStore> _open({File? file, Future<void> Function()? checkpoint}) async {
  final store = JwStore(
    file == null ? NativeDatabase.memory() : NativeDatabase(file),
    ownership: _TestOwnership(),
    clock: _clock,
    modelCredentialProtector: _SyntheticProtector(),
    onAgentCheckpoint: checkpoint,
  );
  try {
    await store.initialize();
    await store.agent.initializeAgent();
  } catch (_) {
    await store.close();
    rethrow;
  }
  addTearDown(store.close);
  return store;
}

Future<void> _configure(JwStore store) async {
  final authority = (await store.agent.inspectAgent()).authority;
  await store.agent.saveModelConfiguration(
    authority,
    modelId: 'synthetic-chat-model',
    modelIds: const ['synthetic-chat-model'],
    report: const AgentCapabilityReport(text: true, streaming: true),
    consent: true,
    key: _key,
  );
}

Future<AgentRunTicket> _beginRun(
  JwStore store,
  String conversationId,
  String question,
) async => store.agent.beginRun(
  (await store.agent.inspectAgent()).authority,
  conversationId,
  question,
);

Future<void> _completeJournal(
  JwStore store,
  String conversationId,
  String question,
) async {
  final ticket = await _beginRun(store, conversationId, question);
  await store.agent.saveAssistant(ticket, '安全保存的合成答复：$question');
  final AgentRunJournalPort journal = store.agent;
  await journal.saveRunJournal(
    ticket,
    evidence: [_evidence()],
    steps: const [AgentToolStep(tool: 'query_agenda', status: 'success')],
    imageCount: 1,
  );
  await store.agent.finishRun(ticket, AgentMessageStatus.complete);
}

AgentEvidence _evidence({
  String id = 'e_0123456789abcdef',
  String provider = 'local',
  String title = '合成日程出处',
  String snippet = '合成摘录：周二 10:00–11:00',
  String? articleUrl,
}) => AgentEvidence(
  id: id,
  provider: provider,
  title: title,
  observedAtUtc: _now,
  scope: 'synthetic-scope',
  complete: true,
  articleUrl: articleUrl,
  sourceVersion: 'synthetic-v1',
  snippet: snippet,
);

List<AgentEvidence> _evidenceBatch(int count) => List.generate(
  count,
  (index) => _evidence(id: 'e_${index.toRadixString(16).padLeft(16, '0')}'),
);

Future<void> _seedPersonalEvent(JwStore store) async {
  final window = await store.localCalendar.query(
    CalendarQuery(
      firstDay: DateTime.utc(2026, 10, 1),
      endDayExclusive: DateTime.utc(2026, 11, 1),
      filter: CalendarFilter.all,
    ),
  );
  final prepared = await store.localCalendar.prepare(
    window.context,
    CreatePersonalEvent(
      PersonalEventDraft(
        title: '合成维护测试事件',
        start: DateTime.utc(2026, 10, 13, 10),
        end: DateTime.utc(2026, 10, 13, 11),
      ),
    ),
  );
  await store.localCalendar.commit(prepared);
}

Future<void> _rewindMessagesToSchema11(
  File file, {
  bool withStepsColumnCollision = false,
}) async {
  final raw = sqlite3.sqlite3.open(file.path);
  try {
    raw.execute('BEGIN');
    _dropM6TablesForLegacyFixture(raw);
    raw.execute('DROP INDEX IF EXISTS agent_messages_conversation');
    raw.execute('ALTER TABLE agent_messages RENAME TO agent_messages_v12');
    raw.execute('''CREATE TABLE agent_messages (
      message_id INTEGER PRIMARY KEY AUTOINCREMENT,
      conversation_id TEXT NOT NULL, run_id TEXT NOT NULL,
      role TEXT NOT NULL CHECK(role IN ('user','assistant')),
      text TEXT NOT NULL CHECK(length(text)<=24000),
      status TEXT NOT NULL CHECK(status IN ('streaming','complete','interrupted','cancelled','failed')),
      created_at INTEGER NOT NULL)''');
    raw.execute('''INSERT INTO agent_messages
      (message_id,conversation_id,run_id,role,text,status,created_at)
      SELECT message_id,conversation_id,run_id,role,text,status,created_at
      FROM agent_messages_v12''');
    raw.execute('DROP TABLE agent_messages_v12');
    raw.execute(
      'CREATE INDEX agent_messages_conversation ON agent_messages(conversation_id,message_id)',
    );
    if (withStepsColumnCollision) {
      raw.execute(
        "ALTER TABLE agent_messages ADD COLUMN steps_json TEXT NOT NULL DEFAULT '[]' CHECK(length(steps_json)<=8192)",
      );
    }
    raw.execute('DROP TABLE IF EXISTS young_daily_sync');
    raw.execute('PRAGMA user_version=11');
    for (final table in [
      'agent_actions',
      'agenda_plan_receipts',
      'agenda_plan_audit',
      'agent_preferences',
    ]) {
      raw.execute('DROP TABLE IF EXISTS $table');
    }
    _removeSchema14AgentObjectsForLegacyFixture(raw);
    raw.execute('COMMIT');
  } on Object {
    raw.execute('ROLLBACK');
    rethrow;
  } finally {
    raw.close();
  }
}

void _dropM6TablesForLegacyFixture(sqlite3.Database database) {
  database.execute('ALTER TABLE jw_events DROP COLUMN source_retired');
  database.execute('ALTER TABLE young_events DROP COLUMN source_retired');
  for (final table in const [
    'm6_state',
    'm6_expected',
    'm6_reminder_overrides',
    'm6_native_map',
    'm6_briefs',
    'm6_brief_suppressed',
  ]) {
    database.execute('DROP TABLE IF EXISTS $table');
  }
}

void _removeSchema14AgentObjectsForLegacyFixture(sqlite3.Database database) {
  final tables = database
      .select("SELECT name FROM sqlite_master WHERE type='table'")
      .map((row) => row['name'] as String)
      .toSet();
  for (final table in const [
    'agent_context_turns',
    'agent_target_aliases',
    'agent_use_policy',
    'agent_permissions',
    'agent_chat_state',
  ]) {
    if (tables.contains(table)) database.execute('DROP TABLE $table');
  }
  if (tables.contains('agent_actions')) {
    final columns = database
        .select('PRAGMA table_info(agent_actions)')
        .map((row) => row['name'] as String)
        .toSet();
    if (columns.contains('authorization')) {
      database.execute('ALTER TABLE agent_actions DROP COLUMN authorization');
    }
  }
}

void _setSchemaVersion(File file, int version) {
  final raw = sqlite3.sqlite3.open(file.path);
  try {
    raw.execute('PRAGMA user_version=$version');
  } finally {
    raw.close();
  }
}

Future<int> _count(JwStore store, String table) async =>
    (await store.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
        .read<int>('n');

Future<Object?> _scalar(JwStore store, String sql) async {
  final row = await store.customSelect(sql).getSingle();
  return row.data.values.single;
}

Future<void> _agentFailure(Future<dynamic> future, AgentFailureCode code) =>
    expectLater(
      future,
      throwsA(
        isA<AgentFailure>().having((failure) => failure.code, 'code', code),
      ),
    );

Future<File> _temporaryDatabase(String prefix) async {
  final directory = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    final tempRoot =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}';
    if (!directory.absolute.path.toLowerCase().startsWith(
          tempRoot.toLowerCase(),
        ) ||
        !directory.path.split(Platform.pathSeparator).last.startsWith(prefix)) {
      throw StateError('Unexpected synthetic journal-test root');
    }
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File ||
          !const {
            'journal.sqlite',
            'journal.sqlite-wal',
            'journal.sqlite-shm',
            'journal.sqlite-journal',
          }.contains(entry.uri.pathSegments.last)) {
        throw StateError('Unexpected synthetic journal-test asset');
      }
      await entry.delete();
    }
    await directory.delete();
  });
  return File('${directory.path}${Platform.pathSeparator}journal.sqlite');
}

final class _SyntheticProtector implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-journal-protector/v1';

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
