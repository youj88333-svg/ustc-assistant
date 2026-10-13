import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/agent_coordinator.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/core/agent_action_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/settings_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

void main() {
  test(
    'C3 pages 120 messages through C4 in order, then clear cannot revive old pages',
    () async {
      final store = await _open();
      await _configure(store);
      final conversation = await store.agent.createConversation();
      for (var index = 1; index <= 60; index++) {
        await _completeRun(
          store,
          conversation,
          'synthetic-user-$index',
          'synthetic-assistant-$index',
        );
      }

      final pagePort = store.agent as AgentHistoryPagePort;
      final newest = await store.agent.messages(conversation);
      expect(newest, hasLength(100));
      expect(newest.first.id, 21);
      final oldest = await pagePort.messagesBefore(
        conversation,
        newest.first.id,
      );
      expect(
        oldest.map((message) => message.id),
        List<int>.generate(20, (i) => i + 1),
      );

      final coordinator = AgentCoordinator(
        data: store.agent,
        gateway: _NoRequestGateway(),
      );
      addTearDown(coordinator.close);
      await coordinator.initialize();
      expect(
        coordinator.view.messages.map((message) => message.id),
        List<int>.generate(100, (i) => i + 21),
      );
      expect(coordinator.view.historyTruncated, isTrue);

      await coordinator.loadOlderMessages();
      final allIds = coordinator.view.messages
          .map((message) => message.id)
          .toList();
      expect(allIds, List<int>.generate(120, (i) => i + 1));
      expect(allIds.toSet(), hasLength(120));
      expect(coordinator.view.historyTruncated, isFalse);
      await coordinator.loadOlderMessages();
      expect(coordinator.view.messages.map((message) => message.id), allIds);

      await coordinator.clearHistory(confirmed: true);
      expect(coordinator.view.messages, isEmpty);
      expect(coordinator.view.conversations, isEmpty);
      await coordinator.loadOlderMessages();
      expect(coordinator.view.messages, isEmpty);
      expect(
        await pagePort.messagesBefore(conversation, newest.first.id),
        isEmpty,
      );
    },
  );

  test(
    'committed action and explicit preferences survive restart and follow clear matrix',
    () async {
      final file = await _temporaryDatabase();
      var store = await _open(file: file);
      await _configure(store);
      final first = await _commitSyntheticPlan(store, 'restart-action');
      final prefs = await _saveExplicitPreferences(store);
      expect(await _count(store, 'agenda_plan_receipts'), 1);
      await store.close();

      store = await _open(file: file);
      final restoredMessages = await store.agent.messages(first.conversationId);
      final restoredAction = restoredMessages
          .where((message) => message.role == AgentMessageRole.assistant)
          .single
          .actions
          .single;
      expect(restoredAction.id, first.action.id);
      expect(restoredAction.status, AgentActionStatus.committed);
      expect(restoredAction.committedCount, 1);
      expect(await _count(store, 'agenda_plan_receipts'), 1);
      _expectPreferences(
        await (store.agent as AgentPreferencesPort).readPlanningPreferences(),
        prefs,
      );

      final authority = (await store.agent.inspectAgent()).authority;
      final historyIntent = await store.agent.beginClearHistory(authority);
      await store.agent.completeClearHistory(historyIntent);
      expect(await store.agent.conversations(), isEmpty);
      expect(await _count(store, 'agent_actions'), 0);
      expect(await _count(store, 'agenda_plan_receipts'), 1);
      _expectPreferences(
        await (store.agent as AgentPreferencesPort).readPlanningPreferences(),
        prefs,
      );

      await _commitSyntheticPlan(store, 'agenda-clear-action');
      expect(await _count(store, 'agenda_plan_receipts'), 2);
      await _maintain(store, MaintenanceKind.agenda);
      expect(await _count(store, 'agenda_plan_receipts'), 0);
      _expectPreferences(
        await (store.agent as AgentPreferencesPort).readPlanningPreferences(),
        prefs,
      );

      await _commitSyntheticPlan(store, 'reset-action');
      expect(await _count(store, 'agenda_plan_receipts'), 1);
      await _maintain(store, MaintenanceKind.reset);
      expect(await _count(store, 'agenda_plan_receipts'), 0);
      final resetPrefs = await (store.agent as AgentPreferencesPort)
          .readPlanningPreferences();
      expect(resetPrefs.weekdays, [1, 2, 3, 4, 5, 6, 7]);
      expect(resetPrefs.startMinute, 420);
      expect(resetPrefs.endMinute, 1439);
      expect(resetPrefs.blockMinutes, 60);
      expect(resetPrefs.breakMinutes, 10);
      expect(resetPrefs.avoid, isEmpty);
      expect((await store.agent.inspectAgent()).keySaved, isFalse);
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

Future<void> _configure(JwStore store) async {
  final settings = await store.agent.inspectAgent();
  await store.agent.saveModelConfiguration(
    settings.authority,
    modelId: 'synthetic-history-model',
    modelIds: const ['synthetic-history-model'],
    report: const AgentCapabilityReport(text: true, streaming: true),
    consent: true,
    key: Uint8List.fromList('synthetic-history-key'.codeUnits),
  );
}

Future<void> _completeRun(
  JwStore store,
  String conversationId,
  String question,
  String answer,
) async {
  final settings = await store.agent.inspectAgent();
  final ticket = await store.agent.beginRun(
    settings.authority,
    conversationId,
    question,
  );
  await store.agent.saveAssistant(ticket, answer);
  await store.agent.finishRun(ticket, AgentMessageStatus.complete);
}

Future<({String conversationId, AgentActionView action})> _commitSyntheticPlan(
  JwStore store,
  String suffix,
) async {
  final agent = store.agent;
  final conversationId = await agent.createConversation();
  final ticket = await agent.beginRun(
    (await agent.inspectAgent()).authority,
    conversationId,
    '提交 $suffix 合成任务',
  );
  final plans = store.localCalendar as AgentLocalPlanPort;
  final (context, revision) = await plans.readPlanContext();
  final plan = await plans.prepareLocalPlan(ticket, context, revision, [
    AgentCreateTask('synthetic-$suffix', TaskDraft(title: '合成任务 $suffix')),
  ]);
  final receipt = await plans.commitLocalPlan(
    await plans.approveLocalPlan(plan),
  );
  await agent.saveAssistant(ticket, '已提交合成任务。');
  await agent.finishRun(ticket, AgentMessageStatus.complete);
  final assistant = (await agent.messages(
    conversationId,
  )).singleWhere((message) => message.role == AgentMessageRole.assistant);
  expect(receipt.committedCount, 1);
  return (conversationId: conversationId, action: assistant.actions.single);
}

Future<AgentPlanningPreferences> _saveExplicitPreferences(JwStore store) async {
  final preferences = store.agent as AgentPreferencesPort;
  final before = await preferences.readPlanningPreferences();
  await preferences.savePlanningPreferences(
    AgentPlanningPreferences(
      revision: before.revision,
      weekdays: const [1, 3, 5],
      startMinute: 495,
      endMinute: 1260,
      blockMinutes: 45,
      breakMinutes: 12,
      avoid: const [(700, 760)],
    ),
  );
  return preferences.readPlanningPreferences();
}

void _expectPreferences(
  AgentPlanningPreferences actual,
  AgentPlanningPreferences expected,
) {
  expect(actual.revision, expected.revision);
  expect(actual.weekdays, expected.weekdays);
  expect(actual.startMinute, expected.startMinute);
  expect(actual.endMinute, expected.endMinute);
  expect(actual.blockMinutes, expected.blockMinutes);
  expect(actual.breakMinutes, expected.breakMinutes);
  expect(
    actual.avoid.map((range) => [range.$1, range.$2]).toList(),
    expected.avoid.map((range) => [range.$1, range.$2]).toList(),
  );
}

Future<void> _maintain(JwStore store, MaintenanceKind kind) async {
  final settings = await store.applicationSettings.inspectSettings();
  final request = await store.applicationSettings.prepareMaintenance(
    settings.context,
    kind,
    confirmed: true,
  );
  final intent = await store.applicationSettings.beginMaintenance(request);
  await store.applicationSettings.completeMaintenance(intent);
}

Future<int> _count(JwStore store, String table) async =>
    (await store.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
        .read<int>('n');

Future<File> _temporaryDatabase() async {
  final directory = await Directory.systemTemp.createTemp(
    'agent-history-pages-',
  );
  addTearDown(() async {
    final root =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}';
    final path = directory.absolute.path;
    if (!path.toLowerCase().startsWith(root.toLowerCase()) ||
        !directory.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('agent-history-pages-')) {
      throw StateError('Unexpected synthetic history database directory.');
    }
    const allowed = {
      'history.sqlite',
      'history.sqlite-wal',
      'history.sqlite-shm',
      'history.sqlite-journal',
    };
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File || !allowed.contains(entry.uri.pathSegments.last)) {
        throw StateError('Unexpected synthetic history database asset.');
      }
      await entry.delete();
    }
    await directory.delete();
  });
  return File('${directory.path}${Platform.pathSeparator}history.sqlite');
}

final class _NoRequestGateway implements ModelGatewayPort {
  @override
  Future<List<String>> listModels(ModelSecretLease secret) async => const [];

  @override
  Stream<ModelEvent> generate(ModelRequest request, ModelSecretLease secret) =>
      Stream<ModelEvent>.error(
        StateError('History-only test must not generate.'),
      );

  @override
  Future<void> cancelAndDrain() async {}

  @override
  Future<void> close() async {}
}

final class _SyntheticProtector implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-history-protector/v1';

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
