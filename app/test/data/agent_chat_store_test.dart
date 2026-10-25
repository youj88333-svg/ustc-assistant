import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show QueryRow;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/agent_conversation_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

void main() {
  test(
    'creates one fixed-title primary conversation when history is empty',
    () async {
      final store = await _open();

      final primary = await store.agent.ensurePrimaryConversation();
      expect(primary, startsWith('agent-conversation-'));
      expect(await store.agent.ensurePrimaryConversation(), primary);
      final conversations = await store.agent.conversations();
      expect(conversations, hasLength(1));
      expect(conversations.single.id, primary);
      expect(conversations.single.title, '对话');

      final state = await _chatState(store);
      expect(state.read<String>('primary_conversation'), primary);
      expect(state.read<int>('revision'), 1);
      expect(state.read<int>('covered_message_id'), 0);
      expect(state.read<String>('summary'), '');
    },
  );

  test(
    'selects the latest existing conversation and preserves every history',
    () async {
      final store = await _open();
      final configured = await _configure(store);
      final older = await store.agent.createConversation();
      final latest = await store.agent.createConversation();
      await _completeRun(
        store,
        configured.authority,
        older,
        'older synthetic question',
        'older synthetic answer',
      );
      await _completeRun(
        store,
        configured.authority,
        latest,
        'latest synthetic question',
        'latest synthetic answer',
      );
      await store.customStatement(
        'UPDATE agent_conversations SET updated_at=? WHERE conversation_id=?',
        [DateTime.utc(2026, 10, 14).microsecondsSinceEpoch, latest],
      );

      expect(await store.agent.ensurePrimaryConversation(), latest);
      expect(
        (await store.agent.conversations()).map((item) => item.id).toSet(),
        {older, latest},
      );
      expect((await store.agent.messages(older)).map((item) => item.text), [
        'older synthetic question',
        'older synthetic answer',
      ]);
      expect((await store.agent.messages(latest)).map((item) => item.text), [
        'latest synthetic question',
        'latest synthetic answer',
      ]);
      expect(await _count(store, 'agent_messages'), 4);
    },
  );

  test(
    'summary persists across restart and binds its covered message revision',
    () async {
      final file = await _temporaryDatabase();
      var store = await _open(file: file);
      final configured = await _configure(store);
      final primary = await store.agent.ensurePrimaryConversation();
      await _completeRun(
        store,
        configured.authority,
        primary,
        'synthetic compact question',
        'synthetic compact answer',
      );
      final snapshot = await store.agent.readConversationContext();
      expect(snapshot.messages, hasLength(2));
      expect(snapshot.lastMessageId, snapshot.messages.last.id);

      await store.agent.saveConversationSummary(
        snapshot,
        '有限上下文：用户先前的问题与已给出的安全回答。',
      );
      await _agentFailure(
        store.agent.saveConversationSummary(snapshot, '重复旧摘要'),
        AgentFailureCode.staleContext,
      );
      await store.close();

      store = await _open(file: file);
      final restored = await store.agent.readConversationContext();
      expect(restored.conversationId, primary);
      expect(restored.summary, '有限上下文：用户先前的问题与已给出的安全回答。');
      expect(restored.coveredMessageId, snapshot.lastMessageId);
      expect(restored.messages.map((message) => message.text), [
        'synthetic compact question',
        'synthetic compact answer',
      ]);
    },
  );

  test(
    'authority change at the save checkpoint rolls back a late summary',
    () async {
      late JwStore store;
      var mutateAtCheckpoint = false;
      store = JwStore(
        NativeDatabase.memory(),
        ownership: _TestOwnership(),
        clock: FixedClock(DateTime.utc(2026, 10, 13, 8)),
        modelCredentialProtector: _SyntheticProtector(),
        onAgentCheckpoint: () async {
          if (mutateAtCheckpoint) {
            mutateAtCheckpoint = false;
            await store.customStatement(
              'UPDATE agent_state SET request_epoch=request_epoch+1 WHERE singleton=1',
            );
          }
        },
      );
      addTearDown(store.close);
      await store.initialize();
      await store.agent.initializeAgent();
      final snapshot = await store.agent.readConversationContext();

      mutateAtCheckpoint = true;
      await _agentFailure(
        store.agent.saveConversationSummary(snapshot, '必须回滚的迟到摘要'),
        AgentFailureCode.staleContext,
      );
      final afterRejectedSave = await _chatState(store);
      expect(afterRejectedSave.read<String>('summary'), '');
      expect(afterRejectedSave.read<int>('revision'), snapshot.revision);

      await store.agent.saveConversationSummary(snapshot, '仍有效的合成摘要');
      expect((await store.agent.readConversationContext()).summary, '仍有效的合成摘要');
    },
  );

  test(
    'forged snapshots and snapshots with new messages are rejected',
    () async {
      final store = await _open();
      final configured = await _configure(store);
      final primary = await store.agent.ensurePrimaryConversation();
      final snapshot = await store.agent.readConversationContext();
      final forged = AgentConversationContext(
        conversationId: snapshot.conversationId,
        revision: snapshot.revision,
        coveredMessageId: snapshot.coveredMessageId,
        lastMessageId: snapshot.lastMessageId,
        summary: snapshot.summary,
        messages: snapshot.messages,
      );
      await _agentFailure(
        store.agent.saveConversationSummary(forged, '伪造快照'),
        AgentFailureCode.staleContext,
      );

      await _completeRun(
        store,
        configured.authority,
        primary,
        'message added after snapshot',
        'synthetic answer after snapshot',
      );
      await _agentFailure(
        store.agent.saveConversationSummary(snapshot, '旧消息摘要'),
        AgentFailureCode.staleContext,
      );
    },
  );

  test(
    'explicit context revocation and a committed save both retire snapshots',
    () async {
      final store = await _open();
      final control = store.agent as AgentConversationControlPort;
      final revoked = await control.readConversationContext();
      control.revokeConversationContext();
      await _agentFailure(
        control.saveConversationSummary(revoked, '撤销后的摘要'),
        AgentFailureCode.staleContext,
      );

      final committed = await control.readConversationContext();
      await control.saveConversationSummary(committed, '提交一次的摘要');
      await _agentFailure(
        control.saveConversationSummary(committed, '重复提交的摘要'),
        AgentFailureCode.staleContext,
      );
    },
  );

  test(
    'configuration, maintenance, active runs, and history clear revoke saves',
    () async {
      final store = await _open();
      final configured = await _configure(store);
      final archive = await store.agent.createConversation();
      final clearedPrimary = await store.agent.createConversation();
      await _completeRun(
        store,
        configured.authority,
        archive,
        'archive A question',
        'archive A answer',
      );
      await _completeRun(
        store,
        configured.authority,
        clearedPrimary,
        'primary B question',
        'primary B answer',
      );
      await store.customStatement(
        'UPDATE agent_conversations SET updated_at=? WHERE conversation_id=?',
        [DateTime.utc(2026, 10, 14).microsecondsSinceEpoch, clearedPrimary],
      );
      expect(await store.agent.ensurePrimaryConversation(), clearedPrimary);
      final primary = clearedPrimary;
      await _seedPersonalEvent(store);

      final activeSnapshot = await store.agent.readConversationContext();
      final active = await store.agent.beginRun(
        configured.authority,
        primary,
        'synthetic active request',
      );
      await _agentFailure(
        store.agent.saveConversationSummary(activeSnapshot, '活跃期间拒绝'),
        AgentFailureCode.busy,
      );
      await store.agent.cancelRun(active);

      final configSnapshot = await store.agent.readConversationContext();
      await store.agent.setModelConsent(configured.authority, false);
      await _agentFailure(
        store.agent.saveConversationSummary(configSnapshot, '配置变更后的旧快照'),
        AgentFailureCode.staleContext,
      );

      final maintenanceSnapshot = await store.agent.readConversationContext();
      await store.customStatement(
        'UPDATE agenda_state SET maintenance=1 WHERE singleton=1',
      );
      await _agentFailure(
        store.agent.saveConversationSummary(maintenanceSnapshot, '维护期间拒绝'),
        AgentFailureCode.maintenance,
      );
      await store.customStatement(
        'UPDATE agenda_state SET maintenance=0 WHERE singleton=1',
      );

      final beforeClear = await store.agent.readConversationContext();
      await store.agent.saveConversationSummary(beforeClear, '清理前的有限摘要');
      final currentAuthority = (await store.agent.inspectAgent()).authority;
      final intent = await store.agent.beginClearHistory(
        currentAuthority,
        conversationId: primary,
      );
      await store.agent.completeClearHistory(intent);
      await _agentFailure(
        store.agent.saveConversationSummary(beforeClear, '清理后的迟到摘要'),
        AgentFailureCode.staleContext,
      );

      final chat = await _chatState(store);
      final replacement = chat.read<String>('primary_conversation');
      expect(replacement, isNot(primary));
      expect(chat.read<String>('summary'), '');
      expect(chat.read<int>('covered_message_id'), 0);
      expect(chat.read<int>('revision'), beforeClear.revision + 2);
      expect((await store.agent.inspectAgent()).keySaved, isTrue);
      expect(await _count(store, 'personal_events'), 1);
      final conversations = await store.agent.conversations();
      expect(conversations.map((item) => item.id).toSet(), {
        archive,
        replacement,
      });
      expect(conversations.any((item) => item.id == primary), isFalse);
      expect(
        (await store.agent.messages(archive)).map((message) => message.text),
        ['archive A question', 'archive A answer'],
      );
      expect(await store.agent.ensurePrimaryConversation(), replacement);
      expect(await store.agent.messages(replacement), isEmpty);
      expect(await _count(store, 'agent_messages'), 2);
    },
  );
}

Future<JwStore> _open({File? file}) async {
  final store = JwStore(
    file == null ? NativeDatabase.memory() : NativeDatabase(file),
    ownership: _TestOwnership(),
    clock: FixedClock(DateTime.utc(2026, 10, 13, 8)),
    modelCredentialProtector: _SyntheticProtector(),
  );
  addTearDown(store.close);
  await store.initialize();
  await store.agent.initializeAgent();
  return store;
}

Future<AgentSettingsSnapshot> _configure(JwStore store) async {
  final settings = await store.agent.inspectAgent();
  await store.agent.saveModelConfiguration(
    settings.authority,
    modelId: 'synthetic-chat-model',
    modelIds: const ['synthetic-chat-model'],
    report: const AgentCapabilityReport(text: true, streaming: true),
    consent: true,
    key: Uint8List.fromList('synthetic-model-key-01'.codeUnits),
  );
  return store.agent.inspectAgent();
}

Future<void> _completeRun(
  JwStore store,
  AgentAuthority authority,
  String conversationId,
  String question,
  String answer,
) async {
  final ticket = await store.agent.beginRun(
    authority,
    conversationId,
    question,
  );
  await store.agent.saveAssistant(ticket, answer);
  await store.agent.finishRun(ticket, AgentMessageStatus.complete);
}

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
        title: 'synthetic retained event',
        start: DateTime.utc(2026, 10, 13, 10),
        end: DateTime.utc(2026, 10, 13, 11),
      ),
    ),
  );
  await store.localCalendar.commit(prepared);
}

Future<QueryRow> _chatState(JwStore store) => store
    .customSelect('SELECT * FROM agent_chat_state WHERE singleton=1')
    .getSingle();

Future<int> _count(JwStore store, String table) async =>
    (await store.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
        .read<int>('n');

Future<void> _agentFailure(Future<dynamic> future, AgentFailureCode code) =>
    expectLater(
      future,
      throwsA(
        isA<AgentFailure>().having((failure) => failure.code, 'code', code),
      ),
    );

Future<File> _temporaryDatabase() async {
  final directory = await Directory.systemTemp.createTemp('agent-chat-store-');
  addTearDown(() async {
    final root =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}';
    if (!directory.absolute.path.toLowerCase().startsWith(root.toLowerCase()) ||
        !directory.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('agent-chat-store-')) {
      throw StateError('Unexpected synthetic chat database directory.');
    }
    const allowed = {
      'chat.sqlite',
      'chat.sqlite-wal',
      'chat.sqlite-shm',
      'chat.sqlite-journal',
    };
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File || !allowed.contains(entry.uri.pathSegments.last)) {
        throw StateError('Unexpected synthetic chat database asset.');
      }
      await entry.delete();
    }
    await directory.delete();
  });
  return File('${directory.path}${Platform.pathSeparator}chat.sqlite');
}

final class _SyntheticProtector implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-chat-store-protector/v1';

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
