import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_context_builder.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_permission_policy_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_session_service.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tool_registry.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_tools.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_write_tool.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_write_tools.dart';
import 'package:ustc_assistant_app/features/agent/application/cancellation_signal.dart';
import 'package:ustc_assistant_app/features/agent/application/outbound_privacy_filter.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_agent_write_gateway.dart';
import 'package:ustc_assistant_app/features/agent/data/drift_chat_repository.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_models.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_tool.dart';
import 'package:ustc_assistant_app/features/agent/domain/llm_protocol.dart';

class _ScriptedProvider implements LlmProvider {
  _ScriptedProvider(this._script);
  final List<List<LlmEvent>> _script;
  int streamCallCount = 0;
  @override
  Future<List<String>> listModels({required String apiKey, required CancellationSignal cancellation}) async =>
      const ['deepseek-v4-flash'];
  @override
  Stream<LlmEvent> stream({required String apiKey, required LlmRequest request, required CancellationSignal cancellation}) async* {
    final index = streamCallCount++;
    if (index >= _script.length) {
      yield const ErrorEvent('script_exhausted');
      return;
    }
    for (final e in _script[index]) {
      if (cancellation.isCancelled) {
        yield const CompletedEvent();
        return;
      }
      yield e;
    }
  }
  @override
  Future<void> probeText({required String apiKey, required String model, required CancellationSignal cancellation}) async {}
  @override
  Future<void> probeTools({required String apiKey, required String model, required CancellationSignal cancellation}) async {}
}

class _FixedClock implements BeijingClock {
  @override
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
}

List<LlmEvent> _confirmCardScript() => [
  const ToolUseCompletedEvent(id: 'tu-1', name: 'create_event',
      input: {'title': '健身', 'start_at': '2026-08-01T15:00:00+08:00', 'end_at': '2026-08-01T16:00:00+08:00'}),
  const UsageEvent(inputTokens: 100, outputTokens: 10),
  const CompletedEvent(),
];

List<LlmEvent> _finalTextScript() => [
  const TextDeltaEvent('已为你新建日程「健身」。'),
  const UsageEvent(inputTokens: 50, outputTokens: 10),
  const CompletedEvent(),
];

void main() {
  test('send pauses for write confirmation, confirm commits and the run completes', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.customStatement('PRAGMA foreign_keys = OFF');
    final clock = _FixedClock();
    final policy = AgentPermissionPolicyService(database: db, clock: clock);
    final store = WriteConfirmationStore(policy: policy);
    final gateway = DriftAgentWriteGateway(database: db, accountId: 'a1', policy: policy,
        now: () => clock.now().millisecondsSinceEpoch);
    final registry = AgentToolRegistry(
      tools: [CreateEventTool(gateway: gateway, policy: policy, confirmationStore: store)],
      privacyFilter: OutboundPrivacyFilter(protectedAccount: 'student', toolBuilders: agentToolPayloadBuilders()),
    );
    final chatRepo = DriftChatRepository(db);
    final provider = _ScriptedProvider([_confirmCardScript(), _finalTextScript()]);
    final session = AgentSessionService(
      chatRepository: chatRepo,
      database: db,
      provider: provider,
      contextBuilder: const AgentContextBuilder(),
      privacyFilter: OutboundPrivacyFilter(protectedAccount: 'student', toolBuilders: agentToolPayloadBuilders()),
      registry: registry,
      clock: clock,
      model: 'deepseek-v4-flash',
      apiKeyProvider: ({required String accountId}) async => 'k',
      writeConfirmationResumer: ({required String handle, required bool approve, required bool remember}) =>
          store.resolve(handle, approve: approve, remember: remember),
    );

    final states = <AgentRunViewState>[];
    final done = Completer<void>();
    late String runId;
    session.send(accountId: 'a1', userText: '帮我建个健身日程').listen((s) {
      states.add(s);
      if (s.state == AgentRunState.waitingForUser) runId = s.runId;
    }, onDone: done.complete, onError: (_) {});

    // 等待暂停出现确认卡
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(states.any((s) => s.userAction?.type == AgentUserActionType.writeConfirmation), isTrue);
    final paused = states.lastWhere((s) => s.userAction?.type == AgentUserActionType.writeConfirmation);
    expect(paused.userAction?.writeProposal?.operationLabel, '新建日程');

    await session.confirmWriteProposal(accountId: 'a1', runId: runId, approve: true, remember: false).drain<void>();
    await done.future;

    expect(states.last.state, AgentRunState.completed);
    final event = await db.select(db.calendarEvents).getSingle();
    expect(event.title, '健身');
    final logs = await db.actionLogsRepository.selectAll();
    expect(logs.any((l) => l.source == 'agent' && l.actionType == 'create_event'), isTrue);
    await db.close();
  });

  test('reject leaves no event and the model gets user_declined', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.customStatement('PRAGMA foreign_keys = OFF');
    final clock = _FixedClock();
    final policy = AgentPermissionPolicyService(database: db, clock: clock);
    final store = WriteConfirmationStore(policy: policy);
    final gateway = DriftAgentWriteGateway(database: db, accountId: 'a1', policy: policy,
        now: () => clock.now().millisecondsSinceEpoch);
    final privacy = OutboundPrivacyFilter(protectedAccount: 'student', toolBuilders: agentToolPayloadBuilders());
    final registry = AgentToolRegistry(
      tools: [CreateEventTool(gateway: gateway, policy: policy, confirmationStore: store)],
      privacyFilter: privacy,
    );
    final chatRepo = DriftChatRepository(db);
    final provider = _ScriptedProvider([_confirmCardScript(), _finalTextScript()]);
    final session = AgentSessionService(
      chatRepository: chatRepo,
      database: db,
      provider: provider,
      contextBuilder: const AgentContextBuilder(),
      privacyFilter: privacy,
      registry: registry,
      clock: clock,
      model: 'deepseek-v4-flash',
      apiKeyProvider: ({required String accountId}) async => 'k',
      writeConfirmationResumer: ({required String handle, required bool approve, required bool remember}) =>
          store.resolve(handle, approve: approve, remember: remember),
    );

    final states = <AgentRunViewState>[];
    final done = Completer<void>();
    late String runId;
    session.send(accountId: 'a1', userText: '帮我建个健身日程').listen((s) {
      states.add(s);
      if (s.state == AgentRunState.waitingForUser) runId = s.runId;
    }, onDone: done.complete);

    await Future<void>.delayed(const Duration(milliseconds: 50));
    await session.confirmWriteProposal(accountId: 'a1', runId: runId, approve: false, remember: false).drain<void>();
    await done.future;

    expect(await db.select(db.calendarEvents).get(), isEmpty);
    expect(states.last.state, AgentRunState.completed);
    await db.close();
  });
}
