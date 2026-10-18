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
    'C4 keeps the enabled tool registry available for both deadline word orders',
    () async {
      final rig = await _open();
      final planningQuestions = [
        '下周二交测试作业，请帮我下周一安排一个小时复习',
        '请帮我下周一安排一个小时复习，下周二交测试作业',
      ];
      for (var index = 0; index < planningQuestions.length; index++) {
        final question = planningQuestions[index];
        final firstRequest = rig.gateway.generations.length;
        rig.gateway.enqueueEvents([
          ..._toolCall(_freeSlotsCall('free-$index')),
        ]);
        rig.gateway.enqueue((generation) async {
          final toolResult = _lastToolResult(generation.request);
          expect(toolResult['status'], 'success');
          final data = toolResult['data'] as Map<String, dynamic>;
          final candidates = data['candidates'] as List<dynamic>;
          expect(candidates, isNotEmpty);
          final slot =
              (candidates.first as Map<String, dynamic>)['slot_ref'] as String;
          generation.emit(
            ModelCompleted(
              finishReason: 'tool_calls',
              toolCalls: [_taskAndSlotProposal('planned-$index', slot)],
            ),
          );
          await generation.finish();
        });
        rig.gateway.enqueueEvents(_answer('方案已拒绝，没有写入日程。'));

        final sending = rig.coordinator.send(question);
        await _until(
          () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
        );
        final request = rig.gateway.generations[firstRequest].request;
        expect(request.toolChoice, isNull, reason: question);
        expect(
          _toolNames(request),
          contains('find_free_slots'),
          reason: question,
        );
        final proposalRequest =
            rig.gateway.generations[firstRequest + 1].request;
        expect(proposalRequest.toolChoice, isNull);
        expect(
          _toolNames(proposalRequest),
          contains('find_free_slots'),
          reason: question,
        );
        expect(
          _lastToolResult(proposalRequest)['status'],
          'success',
          reason: question,
        );
        final pending = rig.coordinator.view.pendingAction!;
        expect(pending.status, AgentActionStatus.proposed, reason: question);
        expect(rig.coordinator.view.toolCalls, 2, reason: question);
        await rig.coordinator.rejectAction(pending.id);
        await sending.timeout(const Duration(seconds: 3));
        expect(await _count(rig.store, 'agenda_plan_receipts'), 0);
      }

      final directQuestions = ['请新建一个下周一13点到14点的日程用于测试', '请写入日程：下周一13点到14点测试'];
      for (var index = 0; index < directQuestions.length; index++) {
        final firstRequest = rig.gateway.generations.length;
        rig.gateway.enqueueEvents([
          ..._toolCall(_personalProposal('direct-$index')),
        ]);
        rig.gateway.enqueueEvents(_answer('方案已拒绝，没有写入日程。'));
        final sending = rig.coordinator.send(directQuestions[index]);
        await _until(
          () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
        );
        final request = rig.gateway.generations[firstRequest].request;
        expect(request.toolChoice, isNull);
        expect(_toolNames(request), contains('propose_local_changes'));
        final pending = rig.coordinator.view.pendingAction!;
        expect(pending.status, AgentActionStatus.proposed);
        await rig.coordinator.rejectAction(pending.id);
        await sending.timeout(const Duration(seconds: 3));
        expect(await _count(rig.store, 'agenda_plan_receipts'), 0);
      }

      _expectStableToolRegistry(
        rig.gateway.generations.map((generation) => generation.request),
      );
    },
  );

  test(
    'ordinary, public, clarification, and planning requests keep one tool registry',
    () async {
      final rig = await _open();

      rig.gateway.enqueueEvents([
        ..._toolCall(_freeSlotsCall('clarification-first')),
      ]);
      rig.gateway.enqueueEvents(_answer('我会先核对可用时间。'));
      await rig.coordinator.send('请帮我安排下周一的一小时复习');
      expect(rig.gateway.generations.first.request.toolChoice, isNull);

      final clarificationRequest = rig.gateway.generations.length;
      rig.gateway.enqueueEvents([
        ..._toolCall(
          _freeSlotsCall(
            'clarification-second',
            startMinute: 780,
            endMinute: 840,
          ),
        ),
      ]);
      rig.gateway.enqueueEvents(_answer('已按这个时间考虑。'));
      await rig.coordinator.send('下周一13点到14点');
      final clarification =
          rig.gateway.generations[clarificationRequest].request;
      final clarificationTools = _toolNames(clarification);
      expect(clarification.toolChoice, isNull);
      expect(clarificationTools, contains('propose_local_changes'));
      expect(clarificationTools, contains('find_free_slots'));
      expect(rig.coordinator.view.toolCalls, 1);

      rig.gateway.enqueueEvents(_answer('我可以协助查询和整理信息。'));
      await rig.coordinator.send('你能帮我做什么？');
      expect(rig.gateway.generations.last.request.toolChoice, isNull);

      rig.gateway.enqueueEvents(_answer('请查看学校公开的办理说明。'));
      await rig.coordinator.send('只查公开资料，USTC 学费缴纳流程是什么？');
      final publicTools = _toolNames(rig.gateway.generations.last.request);
      expect(publicTools, contains('propose_local_changes'));
      expect(publicTools, contains('query_agenda'));
      expect(
        publicTools.any(
          (name) => name == 'search_knowledge' || name == 'browse_campus',
        ),
        isTrue,
      );

      final suggestionRequest = rig.gateway.generations.length;
      rig.gateway.enqueueEvents([..._toolCall(_freeSlotsCall('suggestion'))]);
      rig.gateway.enqueueEvents(_answer('可以考虑查询到的时段。'));
      await rig.coordinator.send('只给我建议，帮我找下周一空闲的一小时，不用保存');
      final suggestion = rig.gateway.generations[suggestionRequest].request;
      final suggestionTools = _toolNames(suggestion);
      expect(suggestionTools, contains('propose_local_changes'));
      expect(suggestionTools, contains('find_free_slots'));
      expect(suggestion.toolChoice, isNull);
      expect(rig.coordinator.view.toolCalls, 1);

      _expectStableToolRegistry(
        rig.gateway.generations.map((generation) => generation.request),
      );
    },
  );

  test(
    'ordinary history cannot override the current local tool registry',
    () async {
      final rig = await _open();

      rig.gateway.enqueueEvents(_answer('我无法创建日程。'));
      await rig.coordinator.send('你好');
      expect(rig.gateway.generations.last.request.toolChoice, isNull);

      rig.gateway.enqueueEvents(_toolCall(_personalProposal('history-write')));
      rig.gateway.enqueueEvents(_answer('方案已拒绝，没有写入日程。'));
      final sending = rig.coordinator.send('请创建下周一13点到14点的复习日程');
      await _until(
        () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
      );
      final request = rig.gateway.generations.last.request;
      expect(_toolNames(request), contains('propose_local_changes'));
      expect(request.toolChoice, isNull);
      final prompt = request.messages
          .firstWhere((message) => message.role == 'system')
          .content!;
      expect(prompt, startsWith('【PERSONA LOAD】'));
      expect(prompt, contains('LANG: ZH_CN'));
      expect(prompt, contains('STYLE: NATURAL_CONCISE'));
      expect(prompt, contains('英文工具名和术语不是失败'));
      expect(prompt, contains('propose_local_changes'));
      expect(
        request.messages.any(
          (message) =>
              message.role == 'assistant' && message.content == '我无法创建日程。',
        ),
        isTrue,
      );
      final pending = rig.coordinator.view.pendingAction!;
      await rig.coordinator.rejectAction(pending.id);
      await sending.timeout(const Duration(seconds: 3));

      _expectStableToolRegistry(
        rig.gateway.generations.map((generation) => generation.request),
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
      expect(rig.gateway.generations.first.request.toolChoice, isNull);
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
      expect(rig.gateway.generations.last.request.toolChoice, isNull);
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
    'English transition prose reaches the tool handoff and is removed from final history',
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
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final conversation = rig.coordinator.view.conversationId!;

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
      expect(rig.gateway.generations.first.request.toolChoice, isNull);
      expect(followupRequest.toolChoice, isNull);
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

      final persisted = await rig.store.agent.messages(conversation);
      expect(persisted.last.status, AgentMessageStatus.complete);
      expect(persisted.last.text, '明天没有已记录的日程。');
      expect(
        persisted.map((message) => message.text).join('\n'),
        isNot(contains(transition)),
      );
      _expectStableToolRegistry(
        rig.gateway.generations.map((generation) => generation.request),
      );
    },
  );

  test('ordinary request carries Chinese response guidance', () async {
    final rig = await _open();
    rig.gateway.enqueueEvents(_answer('你好，我可以帮你处理日程和任务。'));
    await rig.coordinator.send('你好');
    expect(rig.coordinator.view.failure, isNull);
    expect(rig.coordinator.view.messages.last.text, '你好，我可以帮你处理日程和任务。');
    expect(rig.gateway.generations, hasLength(1));
    expect(
      rig.gateway.generations.single.request.messages
          .firstWhere((message) => message.role == 'system')
          .content,
      allOf(startsWith('【PERSONA LOAD】'), contains('LANG: ZH_CN')),
    );
  });

  test(
    'ordinary text that resembles a parameter dump remains a valid model reply',
    () async {
      final rig = await _open();
      const reply = '返回值：{"entries":[]}';
      rig.gateway.enqueueEvents(_answer(reply));
      await rig.coordinator.send('你好');
      expect(rig.coordinator.view.failure, isNull);
      expect(rig.coordinator.view.messages.last.text, reply);
      expect(rig.gateway.generations, hasLength(1));
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

const _enabledTools = {
  'query_agenda',
  'read_event',
  'query_tasks',
  'read_task',
  'inspect_conflicts',
  'search_knowledge',
  'read_knowledge',
  'search_courses',
  'read_course',
  'read_reviews',
  'browse_campus',
  'read_campus_article',
  'propose_local_changes',
  'propose_undo',
  'find_free_slots',
  'propose_planning_preferences',
};

void _expectStableToolRegistry(Iterable<ModelRequest> requests) {
  final all = requests.toList();
  expect(all, isNotEmpty);
  final first = all.first;
  expect(_toolNames(first), _enabledTools);
  final firstDefinitions = _toolDefinitionShape(first);
  for (final request in all) {
    expect(request.toolChoice, isNull);
    expect(_toolNames(request), _enabledTools);
    expect(_toolDefinitionShape(request), firstDefinitions);
  }
}

List<List<String>> _toolDefinitionShape(ModelRequest request) => [
  for (final tool in request.tools)
    [tool.name, tool.description, jsonEncode(tool.parameters)],
];

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

ModelToolCall _freeSlotsCall(String id, {int? startMinute, int? endMinute}) =>
    ModelToolCall(
      id: id,
      name: 'find_free_slots',
      argumentsJson: jsonEncode({
        'first_day': '2026-10-19',
        'end_day_exclusive': '2026-10-20',
        'block_minutes': 60,
        'start_minute': ?startMinute,
        'end_minute': ?endMinute,
      }),
    );

ModelToolCall _taskAndSlotProposal(String id, String slot) => ModelToolCall(
  id: id,
  name: 'propose_local_changes',
  argumentsJson: jsonEncode({
    'changes': [
      {
        'type': 'create_task',
        'local_key': 'review-task-$id',
        'title': '测试作业复习',
        'description': '截止日期：下周二。',
      },
      {'type': 'create_block', 'task_key': 'review-task-$id', 'slot_ref': slot},
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

Map<String, dynamic> _lastToolResult(ModelRequest request) =>
    jsonDecode(
          request.messages
              .lastWhere((message) => message.role == 'tool')
              .content!,
        )
        as Map<String, dynamic>;

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

  void enqueue(Future<void> Function(_SyntheticGeneration) script) =>
      _scripts.add(script);

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
