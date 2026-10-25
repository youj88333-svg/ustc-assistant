import 'dart:io';
import 'dart:typed_data';
import '../support/calendar_legacy_schema.dart';

import 'package:drift/drift.dart' show QueryExecutor;
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
final _initialKey = Uint8List.fromList('synthetic-model-key-01'.codeUnits);
final _replacementKey = Uint8List.fromList('synthetic-model-key-02'.codeUnits);

void main() {
  test(
    'provider profiles survive restart and revoke only the selected Key/consent',
    () async {
      final file = await _temporaryDatabase();
      final protector = _SyntheticProtector();
      var store = await _openAt(file, protector: protector);
      final school = await _configure(store);
      await _seedPersonalEvent(store, '提供方切换应保留的日程');
      final conversation = await store.agent.createConversation();
      await _completeRun(store, school.authority, conversation, '保留问题', '保留回复');
      final oldLease = await store.agent.leaseModelKey(school.authority);
      final active = await store.agent.beginRun(
        school.authority,
        conversation,
        '被切换撤销的问题',
      );
      await store.agent.selectModelProvider(
        school.authority,
        ModelProvider.deepseek,
      );
      expect(oldLease.isAvailable, isFalse);
      await _agentFailure(
        store.agent.saveAssistant(active, '旧服务的迟到回复'),
        AgentFailureCode.staleContext,
      );
      var official = await store.agent.inspectAgent();
      expect(official.provider, ModelProvider.deepseek);
      expect(official.keySaved, isFalse);
      expect(official.consent, isFalse);
      expect(official.modelIds, isEmpty);
      expect(official.report.capability, ModelCapability.unverified);
      await _agentFailure(
        store.agent.saveModelConfiguration(
          school.authority,
          modelId: 'old-school-result',
          modelIds: const ['old-school-result'],
          report: const AgentCapabilityReport(text: true, streaming: true),
          consent: true,
          key: _initialKey,
        ),
        AgentFailureCode.staleContext,
      );
      await _agentFailure(
        store.agent.leaseModelKey(official.authority),
        AgentFailureCode.keyRequired,
      );
      await store.agent.saveModelConfiguration(
        official.authority,
        modelId: 'same-model-id',
        modelIds: const ['same-model-id'],
        report: const AgentCapabilityReport(
          text: true,
          streaming: true,
          toolCall: true,
          toolResult: true,
        ),
        consent: true,
        key: _replacementKey,
      );
      official = await store.agent.inspectAgent();
      expect(protector.protectPurposes, [
        ModelProvider.school.keyPurpose(school.authority.owner),
        ModelProvider.deepseek.keyPurpose(school.authority.owner),
      ]);
      await store.close();
      store = await _openAt(file, protector: protector);
      official = await store.agent.inspectAgent();
      expect(official.provider, ModelProvider.deepseek);
      expect(official.modelId, 'same-model-id');
      final officialLease = await store.agent.leaseModelKey(official.authority);
      expect(officialLease.provider, ModelProvider.deepseek);
      final officialBytes = officialLease.take();
      expect(officialBytes, _replacementKey);
      officialBytes.fillRange(0, officialBytes.length, 0);
      await store.agent.setModelConsent(official.authority, false);
      official = await store.agent.inspectAgent();
      await _agentFailure(
        store.agent.leaseModelKey(official.authority),
        AgentFailureCode.consentRequired,
      );
      await store.agent.deleteModelKey(official.authority);
      official = await store.agent.inspectAgent();
      expect(official.keySaved, isFalse);
      await store.agent.selectModelProvider(
        official.authority,
        ModelProvider.school,
      );
      final restored = await store.agent.inspectAgent();
      expect(restored.keySaved, isTrue);
      expect(restored.consent, isTrue);
      expect(restored.modelId, school.modelId);
      expect(restored.report.capability, school.report.capability);
      final schoolLease = await store.agent.leaseModelKey(restored.authority);
      expect(schoolLease.provider, ModelProvider.school);
      final schoolBytes = schoolLease.take();
      expect(schoolBytes, _initialKey);
      schoolBytes.fillRange(0, schoolBytes.length, 0);
      expect(await _count(store, 'personal_events'), 1);
      expect(
        (await store.agent.messages(conversation)).map((m) => m.text),
        containsAll(['保留问题', '保留回复']),
      );

      final beforeReset = await store.applicationSettings.inspectSettings();
      final reset = await store.applicationSettings.prepareMaintenance(
        beforeReset.context,
        MaintenanceKind.reset,
        confirmed: true,
      );
      await store.applicationSettings.completeMaintenance(
        await store.applicationSettings.beginMaintenance(reset),
      );
      expect(await _count(store, 'agent_config'), 0);
      final cleared = await store.agent.inspectAgent();
      expect(cleared.provider, ModelProvider.school);
      expect(cleared.keySaved, isFalse);
    },
  );

  test(
    'schema 18 migration preserves legacy ciphertext and school consent without decryption',
    () async {
      final file = await _temporaryDatabase();
      var store = await _openAt(file);
      final saved = await _configure(store);
      await _seedPersonalEvent(store, 'schema18保留日程');
      final conversation = await store.agent.createConversation();
      await _completeRun(
        store,
        saved.authority,
        conversation,
        'schema18问题',
        'schema18回复',
      );
      final cipher =
          (await store
                  .customSelect('SELECT key_ciphertext FROM agent_config')
                  .getSingle())
              .read<Uint8List>('key_ciphertext');
      await store.close();
      final raw = sqlite3.sqlite3.open(file.path);
      try {
        removeModelProviderSchemaForLegacyFixture(raw);
        raw.execute('PRAGMA user_version=18');
      } finally {
        raw.close();
      }
      final protector = _SyntheticProtector();
      store = await _openAt(file, protector: protector);
      final migrated = await store.agent.inspectAgent();
      expect(protector.unprotectCalls, 0);
      expect(protector.protectPurposes, isEmpty);
      expect(migrated.provider, ModelProvider.school);
      expect(migrated.keySaved, isTrue);
      expect(migrated.consent, isTrue);
      expect(migrated.modelId, saved.modelId);
      expect(migrated.report.capability, saved.report.capability);
      expect(
        (await store
                .customSelect('SELECT key_ciphertext FROM agent_config')
                .getSingle())
            .read<Uint8List>('key_ciphertext'),
        cipher,
      );
      expect(await _count(store, 'personal_events'), 1);
      expect(
        (await store.agent.messages(conversation)).last.text,
        'schema18回复',
      );
      final lease = await store.agent.leaseModelKey(migrated.authority);
      final bytes = lease.take();
      expect(bytes, _initialKey);
      bytes.fillRange(0, bytes.length, 0);
    },
  );

  test(
    'schema 19 late failure restores schema 18 config and can be retried',
    () async {
      final file = await _temporaryDatabase();
      var store = await _openAt(file);
      final saved = await _configure(store);
      await store.close();
      var raw = sqlite3.sqlite3.open(file.path);
      late Uint8List oldCipher;
      try {
        removeModelProviderSchemaForLegacyFixture(raw);
        raw.execute('PRAGMA user_version=18');
        oldCipher =
            raw
                    .select('SELECT key_ciphertext FROM agent_config')
                    .single['key_ciphertext']
                as Uint8List;
        raw.execute('CREATE TABLE agent_model_selection(sentinel TEXT)');
        raw.execute(
          "INSERT INTO agent_model_selection VALUES('rollback-sentinel')",
        );
      } finally {
        raw.close();
      }
      await expectLater(_openAt(file), throwsA(isA<AppFailure>()));
      raw = sqlite3.sqlite3.open(file.path);
      try {
        expect(raw.select('PRAGMA user_version').single['user_version'], 18);
        expect(
          raw.select('PRAGMA table_info(agent_config)').map((r) => r['name']),
          isNot(contains('provider')),
        );
        expect(
          raw
              .select('SELECT key_ciphertext FROM agent_config')
              .single['key_ciphertext'],
          oldCipher,
        );
        expect(
          raw
              .select('SELECT sentinel FROM agent_model_selection')
              .single['sentinel'],
          'rollback-sentinel',
        );
        raw.execute('DROP TABLE agent_model_selection');
      } finally {
        raw.close();
      }
      store = await _openAt(file);
      expect((await store.agent.inspectAgent()).modelId, saved.modelId);
    },
  );

  test(
    'revoking model consent preserves key and history while invalidating leases and runs',
    () async {
      final store = await _open(protector: _SyntheticProtector());
      final configured = await _configure(store);
      final conversation = await store.agent.createConversation();
      final ticket = await store.agent.beginRun(
        configured.authority,
        conversation,
        '合成授权撤销问题',
      );
      await store.agent.saveAssistant(ticket, '已安全保存的部分回答');
      final oldLease = await store.agent.leaseModelKey(configured.authority);
      await store.agent.setModelConsent(configured.authority, false);
      final revoked = await store.agent.inspectAgent();
      expect(revoked.keySaved, isTrue);
      expect(revoked.consent, isFalse);
      expect(oldLease.isAvailable, isFalse);
      expect(
        (await store.agent.messages(conversation)).last.text,
        '已安全保存的部分回答',
      );
      await expectLater(
        store.agent.leaseModelKey(revoked.authority),
        throwsA(
          isA<AgentFailure>().having(
            (failure) => failure.code,
            'code',
            AgentFailureCode.consentRequired,
          ),
        ),
      );
      await expectLater(
        store.agent.beginRun(revoked.authority, conversation, '禁止新出站的问题'),
        throwsA(
          isA<AgentFailure>().having(
            (failure) => failure.code,
            'code',
            AgentFailureCode.consentRequired,
          ),
        ),
      );
      await expectLater(
        store.agent.saveAssistant(ticket, '旧许可迟到结果'),
        throwsA(
          isA<AgentFailure>().having(
            (failure) => failure.code,
            'code',
            AgentFailureCode.staleContext,
          ),
        ),
      );
      await store.agent.setModelConsent(revoked.authority, true);
      final renewed = await store.agent.inspectAgent();
      final lease = await store.agent.leaseModelKey(renewed.authority);
      final bytes = lease.take();
      expect(bytes, _initialKey);
      bytes.fillRange(0, bytes.length, 0);
      final next = await store.agent.beginRun(
        renewed.authority,
        conversation,
        '重新授权后可发送',
      );
      await store.agent.cancelRun(next);
    },
  );

  test(
    'model-key purpose and one-use lease stay separate from school data and history',
    () async {
      final protector = _SyntheticProtector();
      final store = await _open(protector: protector);
      final configured = await _configure(store);
      final purpose = 'ustc-model-key/v1/${configured.authority.owner}';
      expect(protector.protectPurposes, [purpose]);

      final stored = await store
          .customSelect(
            'SELECT key_ciphertext,mechanism,purpose FROM agent_config WHERE singleton=1',
          )
          .getSingle();
      final ciphertext = stored.read<Uint8List>('key_ciphertext');
      expect(ciphertext, isNot(equals(_initialKey)));
      expect(stored.read<String>('mechanism'), protector.mechanism);
      expect(stored.read<String>('purpose'), purpose);

      // A synthetic already-saved school credential must be unaffected by the
      // independent model-key deletion path.
      final schoolCipher = Uint8List.fromList([0x31, 0x72, 0x19]);
      await store.customStatement(
        'INSERT INTO jw_credentials(account_id,mechanism,ciphertext) VALUES (1,?,?)',
        ['synthetic-school-protector', schoolCipher],
      );
      final conversationId = await store.agent.createConversation();
      await _completeRun(
        store,
        configured.authority,
        conversationId,
        '校园课程有变化吗？',
        '请查看日程页核对最新安排。',
      );

      final lease = await store.agent.leaseModelKey(configured.authority);
      expect(lease.isAvailable, isTrue);
      final plaintext = lease.take();
      expect(plaintext, _initialKey);
      plaintext.fillRange(0, plaintext.length, 0);
      expect(lease.isAvailable, isFalse);
      expect(
        () => lease.take(),
        throwsA(
          isA<AgentFailure>().having(
            (failure) => failure.code,
            'code',
            AgentFailureCode.keyRequired,
          ),
        ),
      );

      final secondLease = await store.agent.leaseModelKey(configured.authority);
      await store.agent.deleteModelKey(configured.authority);
      expect(secondLease.isAvailable, isFalse);
      final afterDelete = await store.agent.inspectAgent();
      expect(afterDelete.keySaved, isFalse);
      expect(afterDelete.consent, isTrue);
      expect(afterDelete.modelId, 'synthetic-chat-model');
      expect((await store.agent.conversations()).map((item) => item.id), [
        conversationId,
      ]);
      expect((await store.agent.messages(conversationId)), hasLength(2));
      final retainedSchoolCipher =
          (await store
                  .customSelect(
                    'SELECT ciphertext FROM jw_credentials WHERE account_id=1',
                  )
                  .getSingle())
              .read<Uint8List>('ciphertext');
      expect(retainedSchoolCipher, schoolCipher);
      expect(await _count(store, 'agent_audit'), 2);
      expect(
        await _auditShape(store),
        everyElement(matches(RegExp(r'^(config|key-delete):\d+:\d+$'))),
      );
    },
  );

  test(
    'protector and SQL checkpoint failures preserve the previous configuration',
    () async {
      final protector = _SyntheticProtector();
      var failCheckpoint = false;
      final store = await _open(
        protector: protector,
        checkpoint: () async {
          if (failCheckpoint) throw StateError('synthetic agent checkpoint');
        },
      );
      final previous = await _configure(store);
      final previousCipher =
          (await store
                  .customSelect(
                    'SELECT key_ciphertext FROM agent_config WHERE singleton=1',
                  )
                  .getSingle())
              .read<Uint8List>('key_ciphertext');
      final oldAuditCount = await _count(store, 'agent_audit');

      protector.failProtect = true;
      await _agentFailure(
        store.agent.saveModelConfiguration(
          previous.authority,
          modelId: 'synthetic-next-model',
          modelIds: const ['synthetic-next-model'],
          report: const AgentCapabilityReport(text: true, streaming: true),
          consent: true,
          key: _replacementKey,
        ),
        AgentFailureCode.protectionFailed,
      );
      protector.failProtect = false;
      final afterProtectionFailure = await store.agent.inspectAgent();
      expect(afterProtectionFailure.authority, previous.authority);
      expect(afterProtectionFailure.modelId, 'synthetic-chat-model');
      expect(
        (await store
                .customSelect(
                  'SELECT key_ciphertext FROM agent_config WHERE singleton=1',
                )
                .getSingle())
            .read<Uint8List>('key_ciphertext'),
        previousCipher,
      );

      protector.failUnexpectedProtect = true;
      await _agentFailure(
        store.agent.saveModelConfiguration(
          previous.authority,
          modelId: 'synthetic-unexpected-failure-model',
          modelIds: const ['synthetic-unexpected-failure-model'],
          report: const AgentCapabilityReport(text: true, streaming: true),
          consent: true,
          key: _replacementKey,
        ),
        AgentFailureCode.protectionFailed,
      );
      protector.failUnexpectedProtect = false;
      final afterUnexpectedProtectionFailure = await store.agent.inspectAgent();
      expect(afterUnexpectedProtectionFailure.authority, previous.authority);
      expect(afterUnexpectedProtectionFailure.modelId, 'synthetic-chat-model');
      expect(
        (await store
                .customSelect(
                  'SELECT key_ciphertext FROM agent_config WHERE singleton=1',
                )
                .getSingle())
            .read<Uint8List>('key_ciphertext'),
        previousCipher,
      );
      expect(await _count(store, 'agent_audit'), oldAuditCount);

      protector.failUnprotect = true;
      await _agentFailure(
        store.agent.leaseModelKey(previous.authority),
        AgentFailureCode.protectionFailed,
      );
      protector.failUnprotect = false;
      protector.failUnexpectedUnprotect = true;
      await _agentFailure(
        store.agent.leaseModelKey(previous.authority),
        AgentFailureCode.protectionFailed,
      );
      protector.failUnexpectedUnprotect = false;
      final afterUnprotectFailures = await store.agent.inspectAgent();
      expect(afterUnprotectFailures.authority, previous.authority);
      expect(afterUnprotectFailures.keySaved, isTrue);
      expect(
        (await store
                .customSelect(
                  'SELECT key_ciphertext FROM agent_config WHERE singleton=1',
                )
                .getSingle())
            .read<Uint8List>('key_ciphertext'),
        previousCipher,
      );
      expect(await _count(store, 'agent_audit'), oldAuditCount);

      failCheckpoint = true;
      await _agentFailure(
        store.agent.saveModelConfiguration(
          previous.authority,
          modelId: 'synthetic-next-model',
          modelIds: const ['synthetic-next-model'],
          report: const AgentCapabilityReport(text: true, streaming: true),
          consent: true,
          key: _replacementKey,
        ),
        AgentFailureCode.storageFailed,
      );
      failCheckpoint = false;
      final afterSqlFailure = await store.agent.inspectAgent();
      expect(afterSqlFailure.authority, previous.authority);
      expect(afterSqlFailure.modelId, 'synthetic-chat-model');
      expect(
        (await store
                .customSelect(
                  'SELECT key_ciphertext FROM agent_config WHERE singleton=1',
                )
                .getSingle())
            .read<Uint8List>('key_ciphertext'),
        previousCipher,
      );
      expect(await _count(store, 'agent_audit'), oldAuditCount);
    },
  );

  test(
    'a ticket completes its run once and cancellation rejects late output',
    () async {
      final store = await _open();
      final configured = await _configure(store);
      final firstConversation = await store.agent.createConversation();
      final secondConversation = await store.agent.createConversation();
      final ticket = await store.agent.beginRun(
        configured.authority,
        firstConversation,
        '合成问题一',
      );

      final forgedTicket = AgentRunTicket(
        authority: ticket.authority,
        runId: ticket.runId,
        conversationId: firstConversation,
        conversationGeneration: ticket.conversationGeneration,
        runGeneration: ticket.runGeneration,
        assistantMessageId: ticket.assistantMessageId,
      );
      await _agentFailure(
        store.agent.saveAssistant(forgedTicket, '跨会话迟到结果'),
        AgentFailureCode.staleContext,
      );
      final crossConversationTicket = AgentRunTicket(
        authority: ticket.authority,
        runId: ticket.runId,
        conversationId: secondConversation,
        conversationGeneration: ticket.conversationGeneration,
        runGeneration: ticket.runGeneration,
        assistantMessageId: ticket.assistantMessageId,
      );
      await _agentFailure(
        store.agent.saveAssistant(crossConversationTicket, '跨会话迟到结果'),
        AgentFailureCode.staleContext,
      );
      await store.agent.saveAssistant(ticket, '合成回答一');
      await store.agent.finishRun(ticket, AgentMessageStatus.complete);
      final completed = await store.agent.messages(firstConversation);
      expect(completed, hasLength(2));
      expect(completed.last.status, AgentMessageStatus.complete);
      expect(completed.last.text, '合成回答一');
      await _agentFailure(
        store.agent.finishRun(ticket, AgentMessageStatus.complete),
        AgentFailureCode.staleContext,
      );

      final generationBound = await store.agent.beginRun(
        configured.authority,
        secondConversation,
        '会话世代绑定问题',
      );
      final clearIntent = await store.agent.beginClearHistory(
        configured.authority,
        conversationId: secondConversation,
      );
      await _agentFailure(
        store.agent.saveAssistant(generationBound, '旧会话世代的迟到回答'),
        AgentFailureCode.staleContext,
      );
      await store.agent.completeClearHistory(clearIntent);
      expect(await store.agent.messages(secondConversation), isEmpty);
      expect((await store.agent.conversations()).map((item) => item.id), [
        firstConversation,
      ]);

      final cancelled = await store.agent.beginRun(
        configured.authority,
        firstConversation,
        '合成问题二',
      );
      await store.agent.cancelRun(cancelled);
      await _agentFailure(
        store.agent.saveAssistant(cancelled, '取消后迟到的合成回答'),
        AgentFailureCode.staleContext,
      );
      final afterCancel = await store.agent.messages(firstConversation);
      expect(afterCancel.last.status, AgentMessageStatus.cancelled);
      expect(afterCancel.last.text, isEmpty);
    },
  );

  test(
    'a changed model configuration makes an active run ticket stale',
    () async {
      final store = await _open();
      final configured = await _configure(store);
      final conversationId = await store.agent.createConversation();
      final ticket = await store.agent.beginRun(
        configured.authority,
        conversationId,
        '合成问题',
      );

      await store.agent.saveModelConfiguration(
        configured.authority,
        modelId: 'synthetic-chat-model-v2',
        modelIds: const ['synthetic-chat-model-v2'],
        report: const AgentCapabilityReport(text: true, streaming: true),
        consent: true,
      );
      await _agentFailure(
        store.agent.saveAssistant(ticket, '旧配置生成的迟到结果'),
        AgentFailureCode.staleContext,
      );
      final messages = await store.agent.messages(conversationId);
      expect(messages.last.status, AgentMessageStatus.interrupted);
      expect(messages.last.text, isEmpty);
      expect(
        (await store.agent.inspectAgent()).modelId,
        'synthetic-chat-model-v2',
      );
    },
  );

  test(
    'single-session and full history clears retain their declared scopes',
    () async {
      final store = await _open();
      final configured = await _configure(store);
      await _seedPersonalEvent(store, '合成保留的个人安排');
      final first = await store.agent.createConversation();
      final second = await store.agent.createConversation();
      await _completeRun(
        store,
        configured.authority,
        first,
        '第一会话问题',
        '第一会话回答',
      );
      await _completeRun(
        store,
        configured.authority,
        second,
        '第二会话问题',
        '第二会话回答',
      );

      final oneConversationIntent = await store.agent.beginClearHistory(
        configured.authority,
        conversationId: first,
      );
      await store.agent.completeClearHistory(oneConversationIntent);
      expect((await store.agent.conversations()).map((item) => item.id), [
        second,
      ]);
      expect(await store.agent.messages(first), isEmpty);
      expect((await store.agent.messages(second)), hasLength(2));
      expect((await store.agent.inspectAgent()).keySaved, isTrue);
      expect(
        (await store.applicationSettings.inspectSettings()).counts.personal,
        1,
      );

      final current = await store.agent.inspectAgent();
      final allHistoryIntent = await store.agent.beginClearHistory(
        current.authority,
      );
      await store.agent.completeClearHistory(allHistoryIntent);
      expect(await store.agent.conversations(), isEmpty);
      expect(await store.agent.messages(second), isEmpty);
      final afterClear = await store.agent.inspectAgent();
      expect(afterClear.keySaved, isTrue);
      expect(afterClear.consent, isTrue);
      expect(afterClear.modelId, 'synthetic-chat-model');
      expect(
        (await store.applicationSettings.inspectSettings()).counts.personal,
        1,
      );
      expect(await _count(store, 'agent_audit'), 3);
      expect(
        await _auditShape(store),
        everyElement(matches(RegExp(r'^(config|history-clear):\d+:\d+$'))),
      );
    },
  );

  test(
    'restart marks unfinished runs interrupted and resumes durable history clear',
    () async {
      final file = await _temporaryDatabase();
      final protector = _SyntheticProtector();
      var store = await _openAt(file, protector: protector);
      final configured = await _configure(store);
      final conversationId = await store.agent.createConversation();
      final unfinished = await store.agent.beginRun(
        configured.authority,
        conversationId,
        '重启前的合成提问',
      );
      await store.agent.saveAssistant(unfinished, '只保存了部分合成回答');

      await store.close();
      store = await _openAt(file, protector: protector);
      final recoveredMessages = await store.agent.messages(conversationId);
      expect(recoveredMessages, hasLength(2));
      expect(recoveredMessages.last.status, AgentMessageStatus.interrupted);
      expect(recoveredMessages.last.text, '只保存了部分合成回答');
      expect(
        await _scalar(store, 'SELECT active_run FROM agent_state'),
        isNull,
      );
      expect(
        await _scalar(
          store,
          "SELECT status FROM agent_runs WHERE run_id='${unfinished.runId}'",
        ),
        'interrupted',
      );
      expect(protector.unprotectCalls, 0);

      final current = await store.agent.inspectAgent();
      final newRun = await store.agent.beginRun(
        current.authority,
        conversationId,
        '清理前的新合成提问',
      );
      final pending = await store.agent.beginClearHistory(current.authority);
      expect(newRun.runId.isNotEmpty, isTrue);
      expect(await _count(store, 'agent_history_intent'), 1);
      await store.close();

      store = await _openAt(file, protector: protector);
      expect(await store.agent.conversations(), isEmpty);
      expect(await store.agent.messages(conversationId), isEmpty);
      expect(await _count(store, 'agent_history_intent'), 0);
      final afterRecovery = await store.agent.inspectAgent();
      expect(afterRecovery.keySaved, isTrue);
      expect(afterRecovery.modelId, 'synthetic-chat-model');
      expect(protector.unprotectCalls, 0);
      expect(
        await _auditShape(store),
        everyElement(matches(RegExp(r'^(config|history-clear):\d+:\d+$'))),
      );
      expect(pending.operationId, startsWith('agent-history-'));
    },
  );

  test(
    'maintenance rejects late model output, preserves agenda scope, and reset clears Agent facts',
    () async {
      final store = await _open();
      final configured = await _configure(store);
      final conversationId = await store.agent.createConversation();
      final run = await store.agent.beginRun(
        configured.authority,
        conversationId,
        '维护前的合成提问',
      );
      await store.agent.saveAssistant(run, '维护前部分回答');
      await _seedPersonalEvent(store, '待清理的合成日程');

      final beforeAgendaClear = await store.applicationSettings
          .inspectSettings();
      final agendaRequest = await store.applicationSettings.prepareMaintenance(
        beforeAgendaClear.context,
        MaintenanceKind.agenda,
        confirmed: true,
      );
      final agendaIntent = await store.applicationSettings.beginMaintenance(
        agendaRequest,
      );
      await _agentFailure(
        store.agent.saveAssistant(run, '维护屏障后的迟到回答'),
        AgentFailureCode.maintenance,
      );
      await store.applicationSettings.completeMaintenance(agendaIntent);

      final afterAgendaClear = await store.applicationSettings
          .inspectSettings();
      final retained = await store.agent.inspectAgent();
      expect(afterAgendaClear.counts.personal, 0);
      expect(
        afterAgendaClear.context.resetEpoch,
        beforeAgendaClear.context.resetEpoch,
      );
      expect(retained.keySaved, isTrue);
      expect(retained.modelId, 'synthetic-chat-model');
      expect((await store.agent.conversations()).map((item) => item.id), [
        conversationId,
      ]);
      final retainedMessages = await store.agent.messages(conversationId);
      expect(retainedMessages.last.status, AgentMessageStatus.interrupted);
      expect(retainedMessages.last.text, '维护前部分回答');

      await _seedPersonalEvent(store, '完全重置时清理的合成日程');
      final beforeReset = await store.applicationSettings.inspectSettings();
      final resetRequest = await store.applicationSettings.prepareMaintenance(
        beforeReset.context,
        MaintenanceKind.reset,
        confirmed: true,
      );
      final resetIntent = await store.applicationSettings.beginMaintenance(
        resetRequest,
      );
      await store.applicationSettings.completeMaintenance(resetIntent);

      final afterResetSettings = await store.applicationSettings
          .inspectSettings();
      final afterResetAgent = await store.agent.inspectAgent();
      expect(afterResetSettings.counts.personal, 0);
      expect(
        afterResetSettings.context.resetEpoch,
        beforeReset.context.resetEpoch + 1,
      );
      expect(afterResetAgent.keySaved, isFalse);
      expect(afterResetAgent.modelId, isNull);
      expect(afterResetAgent.consent, isFalse);
      expect(await store.agent.conversations(), isEmpty);
      expect(await _count(store, 'agent_messages'), 0);
      expect(await _count(store, 'agent_runs'), 0);
      expect(await _count(store, 'agent_audit'), 0);
    },
  );

  test(
    'schema 10 to current adds Agent storage while retaining old business and undo facts',
    () async {
      final file = await _temporaryDatabase();
      var store = await _openAt(file);
      await _seedPersonalEvent(store, '迁移保留的合成日程');
      final beforeWindow = await _calendarWindow(store);
      final beforeUndo = await store.localCalendar.queryUndo(
        beforeWindow.context,
      );
      expect(beforeUndo.canUndo, isTrue);
      await store.customStatement(
        'INSERT INTO jw_credentials(account_id,mechanism,ciphertext) VALUES (1,?,?)',
        [
          'synthetic-school-protector',
          Uint8List.fromList([0x2a, 0x4b]),
        ],
      );
      final retainedOwner = await _scalar(
        store,
        'SELECT owner_id FROM jw_state',
      );
      final retainedEventCount = await _count(store, 'personal_events');
      final retainedCredential =
          (await store
                  .customSelect(
                    'SELECT ciphertext FROM jw_credentials WHERE account_id=1',
                  )
                  .getSingle())
              .read<Uint8List>('ciphertext');
      await store.close();

      final raw = sqlite3.sqlite3.open(file.path);
      try {
        raw.execute('BEGIN');
        for (final table in [
          'onboarding_state',
          'agent_model_selection',
          'agent_actions',
          'agenda_plan_receipts',
          'agenda_plan_audit',
          'agent_preferences',
          'agent_audit',
          'agent_history_intent',
          'agent_messages',
          'agent_runs',
          'agent_conversations',
          'agent_config',
          'agent_state',
        ]) {
          raw.execute('DROP TABLE $table');
        }
        _removeSchema15AgentObjectsForLegacyFixture(raw);
        raw.execute('DROP TABLE IF EXISTS young_daily_sync');
        raw.execute('PRAGMA user_version=10');
        raw.execute('COMMIT');
      } finally {
        raw.close();
      }

      store = await _openAt(file);
      expect(
        await _scalar(store, 'PRAGMA user_version'),
        JwStore.currentSchemaVersion,
      );
      expect(await _count(store, 'agent_state'), 1);
      expect(await _count(store, 'agent_config'), 0);
      expect(
        await _scalar(store, 'SELECT owner_id FROM jw_state'),
        retainedOwner,
      );
      expect(await _count(store, 'personal_events'), retainedEventCount);
      expect(
        (await store
                .customSelect(
                  'SELECT ciphertext FROM jw_credentials WHERE account_id=1',
                )
                .getSingle())
            .read<Uint8List>('ciphertext'),
        retainedCredential,
      );
      final afterWindow = await _calendarWindow(store);
      expect(afterWindow.context, beforeWindow.context);
      expect(afterWindow.revision, beforeWindow.revision + 1);
      final afterUndo = await store.localCalendar.queryUndo(
        afterWindow.context,
      );
      expect(afterUndo.canUndo, isTrue);
      expect(afterUndo.reference!.canonical, beforeUndo.reference!.canonical);
    },
  );
}

Future<JwStore> _open({
  _SyntheticProtector? protector,
  Future<void> Function()? checkpoint,
}) async {
  return _openWithExecutor(
    NativeDatabase.memory(),
    protector: protector,
    checkpoint: checkpoint,
  );
}

Future<JwStore> _openAt(File file, {_SyntheticProtector? protector}) async =>
    _openWithExecutor(NativeDatabase(file), protector: protector);

Future<JwStore> _openWithExecutor(
  QueryExecutor executor, {
  _SyntheticProtector? protector,
  Future<void> Function()? checkpoint,
}) async {
  final store = JwStore(
    executor,
    ownership: _TestOwnership(),
    clock: _clock,
    modelCredentialProtector: protector ?? _SyntheticProtector(),
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

void _removeSchema15AgentObjectsForLegacyFixture(sqlite3.Database database) {
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
  final tables = database
      .select("SELECT name FROM sqlite_master WHERE type='table'")
      .map((row) => row['name'] as String)
      .toSet();
  for (final table in const [
    'agent_context_turns',
    'agent_target_aliases',
    'agent_use_policy',
  ]) {
    if (tables.contains(table)) database.execute('DROP TABLE $table');
  }
  if (tables.contains('agent_messages')) {
    final columns = database
        .select('PRAGMA table_info(agent_messages)')
        .map((row) => row['name'] as String)
        .toSet();
    if (columns.contains('context_private')) {
      database.execute(
        'ALTER TABLE agent_messages DROP COLUMN context_private',
      );
    }
  }
  if (tables.contains('agent_chat_state')) {
    final columns = database
        .select('PRAGMA table_info(agent_chat_state)')
        .map((row) => row['name'] as String)
        .toSet();
    if (columns.contains('summary_private')) {
      database.execute(
        'ALTER TABLE agent_chat_state DROP COLUMN summary_private',
      );
    }
  }
  for (final table in const ['agent_permissions', 'agent_chat_state']) {
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

Future<AgentSettingsSnapshot> _configure(JwStore store) async {
  final settings = await store.agent.inspectAgent();
  await store.agent.saveModelConfiguration(
    settings.authority,
    modelId: 'synthetic-chat-model',
    modelIds: const ['synthetic-chat-model'],
    report: const AgentCapabilityReport(text: true, streaming: true),
    consent: true,
    key: _initialKey,
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

Future<CalendarWindow> _calendarWindow(JwStore store) =>
    store.localCalendar.query(
      CalendarQuery(
        firstDay: DateTime.utc(2026, 10, 1),
        endDayExclusive: DateTime.utc(2026, 11, 1),
        filter: CalendarFilter.all,
      ),
    );

Future<void> _seedPersonalEvent(JwStore store, String title) async {
  final window = await _calendarWindow(store);
  final prepared = await store.localCalendar.prepare(
    window.context,
    CreatePersonalEvent(
      PersonalEventDraft(
        title: title,
        start: DateTime.utc(2026, 10, 13, 10),
        end: DateTime.utc(2026, 10, 13, 11),
      ),
    ),
  );
  await store.localCalendar.commit(prepared);
}

Future<int> _count(JwStore store, String table) async =>
    (await store.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
        .read<int>('n');

Future<Object?> _scalar(JwStore store, String sql) async {
  final row = await store.customSelect(sql).getSingle();
  return row.data.values.single;
}

Future<List<String>> _auditShape(JwStore store) async {
  final rows = await store
      .customSelect(
        'SELECT action,item_count,committed_at FROM agent_audit ORDER BY sequence',
      )
      .get();
  return rows
      .map(
        (row) =>
            '${row.read<String>('action')}:${row.read<int>('item_count')}:${row.read<int>('committed_at')}',
      )
      .toList();
}

Future<void> _agentFailure(Future<dynamic> future, AgentFailureCode code) =>
    expectLater(
      future,
      throwsA(
        isA<AgentFailure>().having((failure) => failure.code, 'code', code),
      ),
    );

Future<File> _temporaryDatabase() async {
  final directory = await Directory.systemTemp.createTemp('agent-store-test-');
  addTearDown(() async {
    final tempRoot =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}';
    if (!directory.absolute.path.toLowerCase().startsWith(
          tempRoot.toLowerCase(),
        ) ||
        !directory.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('agent-store-test-')) {
      throw StateError('Unexpected synthetic temporary root');
    }
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File ||
          !const {
            'agent.sqlite',
            'agent.sqlite-wal',
            'agent.sqlite-shm',
            'agent.sqlite-journal',
          }.contains(entry.uri.pathSegments.last)) {
        throw StateError('Unexpected synthetic temporary entry');
      }
      await entry.delete();
    }
    await directory.delete();
  });
  return File('${directory.path}${Platform.pathSeparator}agent.sqlite');
}

final class _SyntheticProtector implements ModelCredentialProtector {
  bool failProtect = false;
  bool failUnexpectedProtect = false;
  bool failUnprotect = false;
  bool failUnexpectedUnprotect = false;
  int unprotectCalls = 0;
  final List<String> protectPurposes = [];

  @override
  String get mechanism => 'synthetic-model-protector/v1';

  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async {
    protectPurposes.add(purpose);
    if (failProtect) {
      throw const AgentFailure(AgentFailureCode.protectionFailed);
    }
    if (failUnexpectedProtect) {
      throw StateError('synthetic unexpected protector failure');
    }
    return Uint8List.fromList([
      0xA7,
      ...plaintext.map((value) => value ^ 0x5A),
    ]);
  }

  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) async {
    unprotectCalls++;
    if (failUnprotect) {
      throw const AgentFailure(AgentFailureCode.protectionFailed);
    }
    if (failUnexpectedUnprotect) {
      throw StateError('synthetic unexpected unprotector failure');
    }
    if (ciphertext.isEmpty || ciphertext.first != 0xA7) {
      throw StateError('synthetic ciphertext rejected');
    }
    return Uint8List.fromList(
      ciphertext.skip(1).map((value) => value ^ 0x5A).toList(),
    );
  }
}

final class _TestOwnership implements AssetOwnership {
  @override
  bool get isHeld => true;

  @override
  void ensureHeld() {}
}
