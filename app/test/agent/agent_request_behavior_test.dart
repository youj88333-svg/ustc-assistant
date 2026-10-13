import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/agent_action_tools.dart';
import 'package:ustc_assistant_m0/agent/agent_coordinator.dart';
import 'package:ustc_assistant_m0/agent/agent_read_tools.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/jobs/public_query_coordinator.dart';

void main() {
  test(
    'C4 selects write and planning tools from both deadline word orders',
    () async {
      final rig = await _open();
      final cases = <(String, Set<String>)>[
        (
          '下周二交测试作业，请帮我下周一安排一个小时复习',
          {'propose_local_changes', 'find_free_slots'},
        ),
        (
          '请帮我下周一安排一个小时复习，下周二交测试作业',
          {'propose_local_changes', 'find_free_slots'},
        ),
        ('请新建一个下周一13点到14点的日程用于测试', {'propose_local_changes'}),
        ('请写入日程：下周一13点到14点测试', {'propose_local_changes'}),
      ];

      for (final (question, required) in cases) {
        rig.gateway.enqueueEvents(_answer('收到。'));
        await rig.coordinator.send(question);
        final names = _toolNames(rig.gateway.generations.last.request);
        expect(names, containsAll(required), reason: question);
      }
    },
  );

  test(
    'clarification keeps one request; new ordinary and public topics do not',
    () async {
      final rig = await _open();

      rig.gateway.enqueueEvents(_answer('我会先核对可用时间。'));
      await rig.coordinator.send('请帮我安排下周一的一小时复习');
      expect(
        _toolNames(rig.gateway.generations.last.request),
        contains('propose_local_changes'),
      );

      rig.gateway.enqueueEvents(_answer('已按这个时间考虑。'));
      await rig.coordinator.send('下周一13点到14点');
      final clarificationTools = _toolNames(
        rig.gateway.generations.last.request,
      );
      expect(clarificationTools, contains('propose_local_changes'));
      expect(clarificationTools, contains('find_free_slots'));

      rig.gateway.enqueueEvents(_answer('我可以协助查询和整理信息。'));
      await rig.coordinator.send('你能帮我做什么？');
      expect(
        _toolNames(rig.gateway.generations.last.request),
        isNot(contains('propose_local_changes')),
      );

      rig.gateway.enqueueEvents(_answer('请查看学校公开的办理说明。'));
      await rig.coordinator.send('只查公开资料，USTC 学费缴纳流程是什么？');
      final publicTools = _toolNames(rig.gateway.generations.last.request);
      expect(publicTools, isNot(contains('propose_local_changes')));
      expect(publicTools, isNot(contains('query_agenda')));
      expect(
        publicTools.any(
          (name) => name == 'search_knowledge' || name == 'browse_campus',
        ),
        isTrue,
      );

      rig.gateway.enqueueEvents(_answer('下周一有几个可选时段。'));
      await rig.coordinator.send('只给我建议，帮我找下周一空闲的一小时，不用保存');
      final suggestionTools = _toolNames(rig.gateway.generations.last.request);
      expect(suggestionTools, isNot(contains('propose_local_changes')));
      expect(suggestionTools, contains('find_free_slots'));
    },
  );

  test(
    'ordinary chat has no tools and old assistant self-description grants none',
    () async {
      final rig = await _open();

      rig.gateway.enqueueEvents(_answer('I cannot create events.'));
      await rig.coordinator.send('你好');
      expect(rig.gateway.generations.last.request.tools, isEmpty);

      rig.gateway.enqueueEvents(_answer('已准备本地安排方案。'));
      await rig.coordinator.send('请创建下周一13点到14点的复习日程');
      final request = rig.gateway.generations.last.request;
      expect(_toolNames(request), contains('propose_local_changes'));
      final prompt = request.messages
          .firstWhere((message) => message.role == 'system')
          .content!;
      expect(prompt, contains('默认用简体中文回答'));
      expect(prompt, contains('propose_local_changes'));
      expect(
        request.messages.any(
          (message) =>
              message.role == 'assistant' &&
              message.content == 'I cannot create events.',
        ),
        isTrue,
      );
    },
  );

  test(
    'native create_personal waits for C3 approval; rejection writes zero and current approval writes one',
    () async {
      final rig = await _open();
      final monday = DateTime.utc(2026, 10, 19);

      rig.gateway.enqueueEvents(_toolCall(_personalProposal()));
      rig.gateway.enqueueEvents(_answer('方案已拒绝，没有写入日程。'));
      final rejectedRun = rig.coordinator.send('请帮我创建下周一13点到14点的复习日程');
      await _until(
        () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
      );
      final rejectedId = rig.coordinator.view.pendingAction!.id;
      expect(
        rig.coordinator.view.pendingAction!.status,
        AgentActionStatus.proposed,
      );
      expect(await _mondayItems(rig, monday), isEmpty);
      expect(await _count(rig.store, 'agenda_plan_receipts'), 0);
      await rig.coordinator.rejectAction(rejectedId);
      await rejectedRun.timeout(const Duration(seconds: 3));
      expect(await _mondayItems(rig, monday), isEmpty);
      expect(await _count(rig.store, 'agenda_plan_receipts'), 0);

      rig.gateway.enqueueEvents(_toolCall(_personalProposal('approved-write')));
      rig.gateway.enqueueEvents(_answer('已加入周一复习安排。'));
      final approvedRun = rig.coordinator.send('请帮我创建下周一13点到14点的复习日程');
      await _until(
        () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
      );
      final currentId = rig.coordinator.view.pendingAction!.id;
      expect(currentId, isNot(rejectedId));
      expect(await _mondayItems(rig, monday), isEmpty);

      await rig.coordinator.approveAction(rejectedId);
      expect(rig.coordinator.view.phase, AgentPhase.waitingForApproval);
      expect(rig.coordinator.view.pendingAction!.id, currentId);
      expect(await _mondayItems(rig, monday), isEmpty);

      await rig.coordinator.approveAction(currentId);
      await approvedRun.timeout(const Duration(seconds: 3));
      await rig.coordinator.approveAction(currentId);

      final items = await _mondayItems(rig, monday);
      expect(items, hasLength(1));
      expect(items.single.title, '复习');
      expect(await _count(rig.store, 'agenda_plan_receipts'), 1);
    },
  );

  test(
    'tool transition prose is checkpointed then removed from final history, while tool protocol stays complete',
    () async {
      final rig = await _open();
      final transition = List.filled(
        14,
        'Let me inspect the local calendar before answering. ',
      ).join();
      expect(transition.length, greaterThan(512));

      final send = rig.coordinator.send('明天有什么安排？');
      await _until(() => rig.gateway.generations.length == 1);
      final first = rig.gateway.generations.single;
      await first.started.future.timeout(const Duration(seconds: 2));
      first.emit(ModelTextDelta(transition));
      await _untilAsync(() async {
        final conversation = rig.coordinator.view.conversationId;
        if (conversation == null) return false;
        final messages = await rig.store.agent.messages(conversation);
        return messages.any(
          (message) =>
              message.role == AgentMessageRole.assistant &&
              message.text == transition,
        );
      });

      rig.gateway.enqueueEvents(_answer('明天没有已记录的日程。'));
      first.emit(
        ModelCompleted(
          finishReason: 'tool_calls',
          toolCalls: const [
            ModelToolCall(
              id: 'transition-read',
              name: 'query_agenda',
              argumentsJson:
                  '{"first_day":"2026-10-14","end_day_exclusive":"2026-10-15"}',
            ),
          ],
        ),
      );
      await first.finish();
      await send.timeout(const Duration(seconds: 3));

      final followupRequest = rig.gateway.generations[1].request;
      final assistantRound = followupRequest.messages.firstWhere(
        (message) =>
            message.role == 'assistant' && message.toolCalls.isNotEmpty,
      );
      expect(assistantRound.content, transition);
      expect(assistantRound.toolCalls.single.id, 'transition-read');
      final toolResult = followupRequest.messages.firstWhere(
        (message) =>
            message.role == 'tool' && message.toolCallId == 'transition-read',
      );
      expect((jsonDecode(toolResult.content!) as Map)['status'], 'empty');

      final conversation = rig.coordinator.view.conversationId!;
      final persisted = await rig.store.agent.messages(conversation);
      expect(persisted.last.status, AgentMessageStatus.complete);
      expect(persisted.last.text, '明天没有已记录的日程。');
      expect(
        persisted.map((message) => message.text).join('\n'),
        isNot(contains(transition)),
      );
    },
  );

  test('stopping an ordinary stream preserves the received fragment', () async {
    final rig = await _open();
    final send = rig.coordinator.send('你好');
    await _until(() => rig.gateway.generations.length == 1);
    final generation = rig.gateway.generations.single;
    await generation.started.future.timeout(const Duration(seconds: 2));
    generation.emit(const ModelTextDelta('停止前收到的合成片段'));
    await _until(
      () => rig.coordinator.view.messages.any(
        (message) => message.text == '停止前收到的合成片段',
      ),
    );

    await rig.coordinator.stop().timeout(const Duration(seconds: 3));
    await send.timeout(const Duration(seconds: 3));
    final conversation = rig.coordinator.view.conversationId!;
    final persisted = await rig.store.agent.messages(conversation);
    expect(persisted.last.status, AgentMessageStatus.cancelled);
    expect(persisted.last.text, '停止前收到的合成片段');
  });
}

Future<_Rig> _open() async {
  final clock = FixedClock(DateTime.utc(2026, 10, 13, 8));
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _TestOwnership(),
    clock: clock,
    modelCredentialProtector: _SyntheticProtector(),
  );
  addTearDown(store.close);
  await store.initialize();
  await store.agent.initializeAgent();
  final settings = await store.agent.inspectAgent();
  await store.agent.saveModelConfiguration(
    settings.authority,
    modelId: 'synthetic-request-behavior-model',
    modelIds: const ['synthetic-request-behavior-model'],
    report: const AgentCapabilityReport(
      text: true,
      streaming: true,
      toolCall: true,
      toolResult: true,
    ),
    consent: true,
    key: Uint8List.fromList('synthetic-request-behavior-key'.codeUnits),
  );

  final publicQueries = PublicQueryCoordinator(
    store: store.publicStore,
    leases: WorkLeasePool(),
    clock: clock,
    sessionFactory: (source) => throw StateError('synthetic network disabled'),
  );
  final readTools = AgentReadTools(
    calendar: store.localCalendar,
    tasks: store.localCalendar,
    calendarGuard: store.localCalendar,
    knowledge: store.publicStore,
    knowledgeGuard: store.publicStore,
    publicQueries: publicQueries,
    publicGuard: publicQueries,
    clock: clock,
  );
  final actionTools = AgentActionTools(
    readTools: readTools,
    plans: store.localCalendar,
    calendar: store.localCalendar,
    tasks: store.localCalendar,
    preferences: store.agent,
    preferenceProposals: store.agent,
    actionRecords: store.agent,
    clock: clock,
  );
  final gateway = _SyntheticGateway();
  final coordinator = AgentCoordinator(
    data: store.agent,
    gateway: gateway,
    readTools: actionTools,
    clock: clock,
  );
  addTearDown(coordinator.close);
  await coordinator.initialize();
  return _Rig(store, gateway, coordinator);
}

Set<String> _toolNames(ModelRequest request) =>
    request.tools.map((tool) => tool.name).toSet();

ModelToolCall _personalProposal([String id = 'personal-write']) =>
    ModelToolCall(
      id: id,
      name: 'propose_local_changes',
      argumentsJson: jsonEncode({
        'changes': [
          {
            'type': 'create_personal',
            'title': '复习',
            'start': '2026-10-19T13:00+08:00',
            'end': '2026-10-19T14:00+08:00',
          },
        ],
      }),
    );

List<ModelEvent> _answer(String text) => [
  ModelTextDelta(text),
  ModelCompleted(finishReason: 'stop'),
];

List<ModelEvent> _toolCall(ModelToolCall call) => [
  ModelCompleted(finishReason: 'tool_calls', toolCalls: [call]),
];

Future<List<CalendarOccurrence>> _mondayItems(
  _Rig rig,
  DateTime monday,
) async => (await rig.store.localCalendar.query(
  CalendarQuery(
    firstDay: monday,
    endDayExclusive: monday.add(const Duration(days: 1)),
    filter: CalendarFilter.personal,
  ),
)).items;

Future<int> _count(JwStore store, String table) async =>
    (await store.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
        .read<int>('n');

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Synthetic Agent state was not reached.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Future<void> _untilAsync(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Synthetic Agent state was not reached.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

final class _Rig {
  const _Rig(this.store, this.gateway, this.coordinator);
  final JwStore store;
  final _SyntheticGateway gateway;
  final AgentCoordinator coordinator;
}

final class _SyntheticGateway implements ModelGatewayPort {
  final Queue<Future<void> Function(_SyntheticGeneration)> _scripts = Queue();
  final List<_SyntheticGeneration> generations = [];
  bool _closed = false;

  void enqueueEvents(List<ModelEvent> events) {
    _scripts.add((generation) async {
      for (final event in events) {
        if (!generation.emit(event)) return;
      }
      await generation.finish();
    });
  }

  @override
  Future<List<String>> listModels(ModelSecretLease secret) async {
    _consume(secret);
    return const ['synthetic-request-behavior-model'];
  }

  @override
  Stream<ModelEvent> generate(ModelRequest request, ModelSecretLease secret) {
    _consume(secret);
    if (_closed) {
      return Stream<ModelEvent>.error(
        const AgentFailure(AgentFailureCode.closed),
      );
    }
    final generation = _SyntheticGeneration(request);
    generations.add(generation);
    if (_scripts.isNotEmpty) {
      unawaited(_play(generation, _scripts.removeFirst()));
    }
    return generation.stream;
  }

  void _consume(ModelSecretLease secret) {
    final bytes = secret.take();
    bytes.fillRange(0, bytes.length, 0);
  }

  Future<void> _play(
    _SyntheticGeneration generation,
    Future<void> Function(_SyntheticGeneration) script,
  ) async {
    await generation.started.future;
    try {
      await script(generation);
    } on Object catch (error) {
      if (!generation.isClosed) await generation.fail(error);
    }
  }

  @override
  Future<void> cancelAndDrain() async {
    await Future.wait(
      generations
          .where((generation) => !generation.isClosed)
          .map((generation) => generation.finish()),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    await cancelAndDrain();
    _closed = true;
  }
}

final class _SyntheticGeneration {
  _SyntheticGeneration(this.request) {
    controller = StreamController<ModelEvent>(
      onListen: () {
        if (!started.isCompleted) started.complete();
      },
    );
  }

  final ModelRequest request;
  final Completer<void> started = Completer<void>();
  late final StreamController<ModelEvent> controller;
  Future<void>? _closing;
  Stream<ModelEvent> get stream => controller.stream;
  bool get isClosed => controller.isClosed;

  bool emit(ModelEvent event) {
    if (controller.isClosed) return false;
    controller.add(event);
    return true;
  }

  Future<bool> fail(Object error) async {
    if (controller.isClosed) return false;
    controller.addError(error);
    await finish();
    return true;
  }

  Future<void> finish() => _closing ??= controller.close();
}

final class _SyntheticProtector implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-agent-key/v1';

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
  }) async {
    if (ciphertext.isEmpty || ciphertext.first != 0xA7) {
      throw StateError('Synthetic ciphertext was invalid.');
    }
    return Uint8List.fromList(
      ciphertext.skip(1).map((byte) => byte ^ 0x5A).toList(),
    );
  }
}

final class _TestOwnership implements AssetOwnership {
  @override
  bool get isHeld => true;

  @override
  void ensureHeld() {}
}
