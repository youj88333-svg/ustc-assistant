import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/agent_coordinator.dart';
import 'package:ustc_assistant_m0/agent/agent_tool_contract.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/core/agent_action_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/agent_discussion_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

void main() {
  group('AgentCoordinator interactive decisions', () {
    test(
      'only the current card approves; stale and repeated ids do nothing',
      () async {
        final rig = await _open();
        rig.gateway.enqueueEvents(_toolCall(_proposalCall()));
        rig.gateway.enqueueEvents(_answer('已提交合成任务。'));

        final send = rig.coordinator.send('请创建一个复习任务');
        await _until(
          () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
        );
        final id = rig.coordinator.view.pendingAction!.id;

        await rig.coordinator.approveAction('not-the-current-card');
        expect(rig.coordinator.view.phase, AgentPhase.waitingForApproval);
        expect(rig.tools.commitCount, 0);

        await rig.coordinator.approveAction(id);
        await rig.coordinator.approveAction(id);
        await send.timeout(const Duration(seconds: 3));

        expect(rig.tools.commitCount, 1);
        expect(await _count(rig.store, 'agenda_plan_receipts'), 1);
        expect(rig.coordinator.view.pendingAction, isNull);
      },
    );

    test(
      'rejecting the current card writes no plan and repeated rejection is inert',
      () async {
        final rig = await _open();
        rig.gateway.enqueueEvents(_toolCall(_proposalCall()));
        rig.gateway.enqueueEvents(_answer('提案已拒绝。'));

        final send = rig.coordinator.send('请创建一个复习任务');
        await _until(
          () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
        );
        final id = rig.coordinator.view.pendingAction!.id;
        await rig.coordinator.rejectAction(id);
        await rig.coordinator.rejectAction(id);
        await send.timeout(const Duration(seconds: 3));

        expect(rig.tools.commitCount, 0);
        expect(await _count(rig.store, 'agenda_plan_receipts'), 0);
        expect(
          rig.coordinator.view.messages.last.actions.single.status,
          AgentActionStatus.rejected,
        );
      },
    );

    test(
      'Stop releases an approval wait and revokes its uncommitted plan',
      () async {
        final rig = await _open();
        rig.gateway.enqueueEvents(_toolCall(_proposalCall()));

        final send = rig.coordinator.send('请创建一个复习任务');
        await _until(
          () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
        );
        await rig.coordinator.stop().timeout(const Duration(seconds: 3));
        await send.timeout(const Duration(seconds: 3));

        expect(rig.tools.commitCount, 0);
        expect(await _count(rig.store, 'agenda_plan_receipts'), 0);
        expect(rig.coordinator.view.phase, AgentPhase.idle);
        expect(
          rig.coordinator.view.messages.last.status,
          AgentMessageStatus.cancelled,
        );
      },
    );

    test(
      'time spent waiting for approval is outside the run timeout',
      () async {
        final rig = await _open(
          runTimeout: const Duration(milliseconds: 300),
          tools: _FakeInteractiveTools(useSyntheticProposal: true),
        );
        rig.gateway.enqueueEvents(_toolCall(_proposalCall()));
        rig.gateway.enqueueEvents(_answer('提案已拒绝。'));

        final send = rig.coordinator.send('请创建一个复习任务');
        await _until(
          () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(rig.coordinator.view.phase, AgentPhase.waitingForApproval);
        expect(rig.coordinator.view.failure, isNull);

        await rig.coordinator.rejectAction(
          rig.coordinator.view.pendingAction!.id,
        );
        await send.timeout(const Duration(seconds: 3));
        expect(rig.coordinator.view.failure, isNull);
        final summary =
            jsonDecode(rig.coordinator.safeValidationSummary()) as Map;
        final lastRun = summary['lastRun'] as Map;
        expect(lastRun['humanWaitMs'], greaterThanOrEqualTo(450));
        expect(lastRun['activeMs'], isA<int>());
        expect(lastRun['inputTokens'], isNull);
        expect(lastRun['outputTokens'], isNull);
        expect(lastRun['cost'], 'unknown');
      },
    );

    test(
      'accepted commit removes old query pairs but keeps its current receipt',
      () async {
        final rig = await _open();
        rig.gateway.enqueueEvents(_toolCall(_readCall('old-read')));
        rig.gateway.enqueueEvents(_toolCall(_proposalCall('current-write')));
        rig.gateway.enqueueEvents(_answer('已按当前状态处理。'));

        final send = rig.coordinator.send('查看日程并创建一个复习任务');
        await _until(
          () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
        );
        await rig.coordinator.approveAction(
          rig.coordinator.view.pendingAction!.id,
        );
        await _until(() => rig.gateway.generations.length >= 3);

        final nextRequest = rig.gateway.generations[2].request;
        expect(
          nextRequest.messages
              .expand((message) => message.toolCalls)
              .map((call) => call.id),
          contains('current-write'),
        );
        expect(
          nextRequest.messages
              .expand((message) => message.toolCalls)
              .map((call) => call.id),
          isNot(contains('old-read')),
        );
        final receipt = nextRequest.messages.last;
        expect(receipt.role, 'tool');
        expect(receipt.toolCallId, 'current-write');
        expect((jsonDecode(receipt.content!) as Map)['status'], 'committed');

        await send.timeout(const Duration(seconds: 3));
        expect(rig.tools.commitCount, 1);
      },
    );

    test(
      'a later model failure preserves the committed action as C3 history',
      () async {
        final rig = await _open();
        rig.gateway.enqueueEvents(_toolCall(_proposalCall()));
        rig.gateway.enqueueFailure(StateError('synthetic model interruption'));

        final send = rig.coordinator.send('请创建一个复习任务');
        await _until(
          () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
        );
        await rig.coordinator.approveAction(
          rig.coordinator.view.pendingAction!.id,
        );
        await send.timeout(const Duration(seconds: 3));

        final committed = rig.coordinator.view.messages.last.actions.single;
        expect(committed.status, AgentActionStatus.committed);
        expect(committed.committedCount, 1);
        final count = rig.tools.commitCount;
        await rig.coordinator.approveAction(committed.id);
        expect(rig.tools.commitCount, count);

        rig.gateway.enqueueEvents(_answer('历史动作只用于展示。'));
        await rig.coordinator.send('解释一下当前任务');
        expect(rig.coordinator.view.pendingAction, isNull);
        await rig.coordinator.approveAction(committed.id);
        expect(rig.tools.commitCount, count);
        expect(
          rig.coordinator.view.messages
              .expand((message) => message.actions)
              .any(
                (action) =>
                    action.id == committed.id &&
                    action.status == AgentActionStatus.committed,
              ),
          isTrue,
        );
      },
    );

    test(
      'waiting for a school job pauses budget and continues the same owned job',
      () async {
        final rig = await _open(runTimeout: const Duration(milliseconds: 350));
        rig.gateway.enqueueEvents(_toolCall(_sourceRefreshCall()));

        final send = rig.coordinator.send('请同步教务课表');
        await _until(
          () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
        );
        await rig.coordinator.approveAction(
          rig.coordinator.view.pendingAction!.id,
        );
        await _until(
          () => rig.coordinator.view.phase == AgentPhase.waitingForSchool,
          label:
              'source wait; phase=${rig.coordinator.view.phase}, '
              'failure=${rig.coordinator.view.failure}, '
              'tool=${rig.coordinator.view.activeTool}',
        );
        final job = rig.tools.ownedSourceJobId;
        expect(job, isNotNull);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(rig.coordinator.view.phase, AgentPhase.waitingForSchool);
        expect(rig.coordinator.view.failure, isNull);

        await rig.coordinator.continueSchool();
        expect(rig.tools.sourceContinueCount, 1);
        expect(rig.tools.lastContinuedJobId, job);
        expect(rig.tools.ownedSourceJobId, job);
        expect(rig.tools.sourceRefreshCount, 1);

        await _until(() => rig.gateway.generations.length >= 2);
        final followup = rig.gateway.generations[1];
        await followup.started.future.timeout(const Duration(seconds: 2));
        followup.emit(const ModelTextDelta('同步已继续。'));
        followup.emit(ModelCompleted(finishReason: 'stop'));
        await followup.finish();
        await send.timeout(const Duration(seconds: 3));
        expect(rig.coordinator.view.failure, isNull);
        expect(rig.tools.ownedSourceJobCancelled, isFalse);
      },
    );

    test('Stop cancels only this Agent-owned school wait', () async {
      final rig = await _open();
      rig.gateway.enqueueEvents(_toolCall(_sourceRefreshCall()));

      final send = rig.coordinator.send('请同步教务课表');
      await _until(
        () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
      );
      await rig.coordinator.approveAction(
        rig.coordinator.view.pendingAction!.id,
      );
      await _until(
        () => rig.coordinator.view.phase == AgentPhase.waitingForSchool,
        label:
            'source stop wait; phase=${rig.coordinator.view.phase}, '
            'failure=${rig.coordinator.view.failure}, '
            'tool=${rig.coordinator.view.activeTool}',
      );

      await rig.coordinator.stop().timeout(const Duration(seconds: 3));
      await send.timeout(const Duration(seconds: 3));
      expect(rig.tools.ownedSourceJobCancelled, isTrue);
      expect(rig.tools.manualSourceJobCancelled, isFalse);
    });

    test(
      'a mixed read and write tool round is rejected before either executes',
      () async {
        final rig = await _open();
        rig.gateway.enqueueEvents([
          ModelCompleted(
            finishReason: 'tool_calls',
            toolCalls: [
              const ModelToolCall(
                id: 'mixed-read',
                name: 'query_agenda',
                argumentsJson: '{}',
              ),
              _proposalCall('mixed-write'),
            ],
          ),
        ]);

        await rig.coordinator.send('查看日程并创建一个复习任务');

        expect(rig.coordinator.view.failure, AgentFailureCode.toolUnavailable);
        expect(rig.tools.executeCount, 0);
        expect(rig.tools.commitCount, 0);
        expect(await _count(rig.store, 'agenda_plan_receipts'), 0);
      },
    );

    test(
      'the same task query can run again after an accepted commit',
      () async {
        final rig = await _open();
        rig.gateway.enqueueEvents(_toolCall(_queryTasksCall('tasks-before')));
        rig.gateway.enqueueEvents(_toolCall(_proposalCall('write-between')));
        rig.gateway.enqueueEvents(_toolCall(_queryTasksCall('tasks-after')));
        rig.gateway.enqueueEvents(_answer('已按提交后的任务状态再次查询。'));

        final send = rig.coordinator.send('查看任务并创建一个复习任务');
        await _until(
          () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
        );
        await rig.coordinator.approveAction(
          rig.coordinator.view.pendingAction!.id,
        );
        await send.timeout(const Duration(seconds: 3));

        expect(rig.tools.readCount, 2);
        expect(rig.tools.commitCount, 1);
        expect(rig.gateway.generations, hasLength(4));
        expect(rig.tools.readArguments, [
          '{"filter":"open","limit":5}',
          '{"filter":"open","limit":5}',
        ]);
        expect(rig.coordinator.view.failure, isNull);
      },
    );

    test(
      'discussion is prefilled, revalidated on send, and not saved as the question',
      () async {
        final rig = await _open();
        final context = CalendarContext(
          owner: 'synthetic-discussion-owner',
          resetEpoch: 1,
          agendaEpoch: 2,
        );
        final reference = TaskReference(context, 41, 3);
        final selection = AgentDiscussionSelection.task(reference);
        rig.tools.discussionValidator = (candidate) async {
          expect(identical(candidate, selection), isTrue);
          return '已核验的合成任务摘要';
        };

        await rig.coordinator.prepareDiscussion(selection);
        final conversation = rig.coordinator.view.conversationId!;
        expect(rig.gateway.generations, isEmpty);
        expect(rig.coordinator.view.discussionId, isNotNull);
        expect(rig.coordinator.view.discussionDraft, '请帮我讨论选中的任务及时间规划。');
        expect(rig.tools.discussionSelections, [selection]);

        rig.gateway.enqueueEvents(_answer('合成讨论答复。'));
        await rig.coordinator.send('这个任务如何安排？');

        expect(rig.tools.discussionSelections, [selection, selection]);
        expect(
          rig.gateway.generations.single.request.messages.last.content,
          '这个任务如何安排？\n[应用选择] 已核验的合成任务摘要',
        );
        final persisted = await rig.store.agent.messages(conversation);
        expect(
          persisted
              .where((message) => message.role == AgentMessageRole.user)
              .last
              .text,
          '这个任务如何安排？',
        );
        expect(
          persisted.map((message) => message.text).join('\n'),
          isNot(contains('已核验的合成任务摘要')),
        );
      },
    );

    test(
      'a stale discussion selection fails before model generation',
      () async {
        final rig = await _open();
        final reference = TaskReference(
          const CalendarContext(
            owner: 'synthetic-stale-owner',
            resetEpoch: 1,
            agendaEpoch: 1,
          ),
          52,
          4,
        );
        final selection = AgentDiscussionSelection.task(reference);
        var currentVersion = reference.version;
        rig.tools.discussionValidator = (candidate) async {
          if (candidate.task?.version != currentVersion) {
            throw const AgentFailure(AgentFailureCode.staleContext);
          }
          return '核验版本$currentVersion';
        };

        await rig.coordinator.prepareDiscussion(selection);
        final conversation = rig.coordinator.view.conversationId!;
        currentVersion++;
        rig.gateway.enqueueEvents(_answer('此答复不应请求。'));
        await rig.coordinator.send('讨论所选任务');

        expect(rig.tools.discussionSelections, [selection, selection]);
        expect(rig.coordinator.view.failure, AgentFailureCode.staleContext);
        expect(rig.gateway.generations, isEmpty);
        final persisted = await rig.store.agent.messages(conversation);
        expect(
          persisted
              .where((message) => message.role == AgentMessageRole.user)
              .last
              .text,
          '讨论所选任务',
        );
        expect(
          persisted.map((message) => message.text).join('\n'),
          isNot(contains('核验版本')),
        );
      },
    );
    test(
      'a public-only question revokes the staged local discussion scope',
      () async {
        final rig = await _open();
        final selection = AgentDiscussionSelection.task(
          const TaskReference(
            CalendarContext(
              owner: 'synthetic-owner',
              resetEpoch: 0,
              agendaEpoch: 0,
            ),
            1,
            1,
          ),
        );
        rig.tools.discussionValidator = (_) async => '本地选择摘要';
        await rig.coordinator.prepareDiscussion(selection);
        rig.gateway.enqueueEvents(_answer('合成公开答复'));
        await rig.coordinator.send('只查公开资料，不读我的任务');
        expect(rig.tools.discussionSelections, hasLength(1));
        expect(
          rig.gateway.generations.single.request.messages.last.content,
          '只查公开资料，不读我的任务',
        );
        expect(
          rig.gateway.generations.single.request.tools.map((t) => t.name),
          isNot(contains('read_task')),
        );
        expect(rig.coordinator.view.failure, isNull);
      },
    );

    test('validation summary totals usage and leaves cost unknown', () async {
      final rig = await _open();
      rig.gateway.enqueueEvents([
        ModelCompleted(
          finishReason: 'tool_calls',
          toolCalls: [_queryTasksCall('usage-read')],
          inputTokens: 11,
          outputTokens: 4,
        ),
      ]);
      rig.gateway.enqueueEvents([
        ModelTextDelta('有两轮合成用量。'),
        ModelCompleted(finishReason: 'stop', inputTokens: 13, outputTokens: 6),
      ]);

      await rig.coordinator.send('查询合成任务');

      final summary =
          jsonDecode(rig.coordinator.safeValidationSummary()) as Map;
      final run = summary['lastRun'] as Map;
      expect(run['activeMs'], isA<int>());
      expect(run['humanWaitMs'], isA<int>());
      expect(run['inputTokens'], 24);
      expect(run['outputTokens'], 10);
      expect(run['cost'], 'unknown');

      rig.gateway.enqueueEvents([
        ModelTextDelta('本轮没有提供usage。'),
        ModelCompleted(finishReason: 'stop'),
      ]);
      await rig.coordinator.send('再做一次合成查询');
      final noUsage =
          jsonDecode(rig.coordinator.safeValidationSummary()) as Map;
      final noUsageRun = noUsage['lastRun'] as Map;
      expect(noUsageRun['inputTokens'], isNull);
      expect(noUsageRun['outputTokens'], isNull);
      expect(noUsageRun['cost'], 'unknown');
    });
  });
}

Future<_Rig> _open({
  Duration runTimeout = const Duration(seconds: 5),
  _FakeInteractiveTools? tools,
}) async {
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _TestOwnership(),
    clock: FixedClock(DateTime.utc(2026, 10, 13, 8)),
    modelCredentialProtector: _SyntheticProtector(),
  );
  addTearDown(store.close);
  await store.initialize();
  await store.agent.initializeAgent();
  final settings = await store.agent.inspectAgent();
  await store.agent.saveModelConfiguration(
    settings.authority,
    modelId: 'synthetic-interactive-model',
    modelIds: const ['synthetic-interactive-model'],
    report: const AgentCapabilityReport(
      text: true,
      streaming: true,
      toolCall: true,
      toolResult: true,
    ),
    consent: true,
    key: Uint8List.fromList('synthetic-interactive-key'.codeUnits),
  );
  final gateway = _SyntheticGateway();
  final readTools = tools ?? _FakeInteractiveTools();
  readTools.attach(store);
  final coordinator = AgentCoordinator(
    data: store.agent,
    gateway: gateway,
    readTools: readTools,
    runTimeout: runTimeout,
    clock: FixedClock(DateTime.utc(2026, 10, 13, 8)),
  );
  addTearDown(coordinator.close);
  await coordinator.initialize();
  return _Rig(store, gateway, coordinator, readTools);
}

ModelToolCall _proposalCall([String id = 'write-proposal']) =>
    ModelToolCall(id: id, name: 'propose_local_changes', argumentsJson: '{}');

ModelToolCall _sourceRefreshCall() => const ModelToolCall(
  id: 'source-refresh',
  name: 'request_source_refresh',
  argumentsJson: '{}',
);

ModelToolCall _readCall(String id) =>
    ModelToolCall(id: id, name: 'query_agenda', argumentsJson: '{}');

ModelToolCall _queryTasksCall(String id) => ModelToolCall(
  id: id,
  name: 'query_tasks',
  argumentsJson: '{"filter":"open","limit":5}',
);

List<ModelEvent> _answer(String text) => [
  ModelTextDelta(text),
  ModelCompleted(finishReason: 'stop'),
];

List<ModelEvent> _toolCall(ModelToolCall call) => [
  ModelCompleted(finishReason: 'tool_calls', toolCalls: [call]),
];

Future<void> _until(bool Function() condition, {String label = ''}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
        'Expected synthetic coordinator state was not reached. $label',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Future<int> _count(JwStore store, String table) async =>
    (await store.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
        .read<int>('n');

final class _Rig {
  const _Rig(this.store, this.gateway, this.coordinator, this.tools);
  final JwStore store;
  final _SyntheticGateway gateway;
  final AgentCoordinator coordinator;
  final _FakeInteractiveTools tools;
}

final class _SyntheticGateway implements ModelGatewayPort {
  final Queue<Future<void> Function(_SyntheticGeneration)> _scripts = Queue();
  final List<_SyntheticGeneration> generations = [];
  int cancelCount = 0;
  bool _closed = false;

  void enqueueEvents(List<ModelEvent> events) {
    _scripts.add((generation) async {
      for (final event in events) {
        if (!generation.emit(event)) return;
      }
      await generation.finish();
    });
  }

  void enqueueFailure(Object error) {
    _scripts.add((generation) async {
      await generation.fail(error);
    });
  }

  @override
  Future<List<String>> listModels(ModelSecretLease secret) async {
    _consume(secret);
    return const ['synthetic-interactive-model'];
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
    cancelCount++;
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

final class _FakeInteractiveTools implements AgentReadToolsPort {
  _FakeInteractiveTools({this.useSyntheticProposal = false});

  final bool useSyntheticProposal;
  late final JwStore _store;
  _FakeInteractiveSession? _session;
  int _nextPlan = 0;
  int executeCount = 0;
  int commitCount = 0;
  int readCount = 0;
  final List<String> readArguments = [];
  final List<AgentDiscussionSelection> discussionSelections = [];
  Future<String> Function(AgentDiscussionSelection selection)?
  discussionValidator;
  int sourceRefreshCount = 0;
  int sourceContinueCount = 0;
  String? ownedSourceJobId;
  String? lastContinuedJobId;
  bool ownedSourceJobCancelled = false;
  bool manualSourceJobCancelled = false;

  void attach(JwStore store) => _store = store;

  @override
  List<ModelToolDefinition> get definitions => [
    for (final name in const [
      'query_agenda',
      'query_tasks',
      'propose_local_changes',
      'request_source_refresh',
    ])
      ModelToolDefinition(
        name: name,
        description: 'Synthetic fixed tool.',
        parameters: const {'type': 'object', 'properties': <String, Object?>{}},
      ),
  ];

  @override
  AgentToolSession openSession() {
    final session = _FakeInteractiveSession(this);
    _session = session;
    return session;
  }

  @override
  Future<void> cancelAndDrain() async {
    final session = _session;
    if (session != null && session.waitingForSchool) {
      ownedSourceJobCancelled = true;
      session.cancelOwnedSourceJob();
    }
  }

  @override
  Future<void> close() async {
    _session?.revoke();
  }
}

final class _FakeInteractiveSession
    implements
        AgentToolSession,
        AgentDiscussionToolSession,
        AgentInteractiveToolSession {
  _FakeInteractiveSession(this._owner);

  final _FakeInteractiveTools _owner;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  AgentRunTicket? _ticket;
  AgentActionView? _pending;
  AgentLocalPlan? _plan;
  AgentActionView? _sourceRecord;
  bool _revoked = false;
  bool _waitingForSchool = false;
  bool _contextInvalidated = false;
  Completer<AgentToolResult>? _schoolDecision;

  @override
  List<AgentEvidence> get evidence => const [];

  @override
  AgentActionView? get pendingAction => _pending;

  @override
  bool get waitingForSchool => _waitingForSchool;

  @override
  Stream<void> get interactiveChanges => _changes.stream;

  @override
  bool get contextInvalidated => _contextInvalidated;

  @override
  void bindRun(AgentRunTicket ticket, String humanQuestion) {
    _ticket = ticket;
  }

  @override
  Future<AgentToolResult> execute(ModelToolCall call) async {
    if (_revoked) throw const AgentFailure(AgentFailureCode.cancelled);
    _owner.executeCount++;
    switch (call.name) {
      case 'query_agenda':
      case 'query_tasks':
        _owner.readCount++;
        _owner.readArguments.add(call.argumentsJson);
        return AgentToolResult(status: 'success', data: const {'count': 0});
      case 'propose_local_changes':
        if (_owner.useSyntheticProposal) {
          _pending = AgentActionView(
            id: 'synthetic-proposal-${_owner._nextPlan++}',
            kind: AgentActionKind.localPlan,
            status: AgentActionStatus.proposed,
            title: '合成任务提案',
            details: const ['一个合成任务'],
          );
        } else {
          final ticket = _requireTicket();
          final plans = _owner._store.localCalendar as AgentLocalPlanPort;
          final (context, revision) = await plans.readPlanContext();
          _plan = await plans.prepareLocalPlan(ticket, context, revision, [
            AgentCreateTask(
              'synthetic-task-${_owner._nextPlan++}',
              const TaskDraft(title: '合成复习任务'),
            ),
          ]);
          _pending = _plan!.view;
        }
        _notify();
        return AgentToolResult(
          status: 'waitingForApproval',
          data: {'action_id': _pending!.id},
        );
      case 'request_source_refresh':
        _sourceRecord = await (_owner._store.agent as AgentActionRecordPort)
            .prepareActionRecord(
              _requireTicket(),
              AgentActionKind.sourceRefresh,
              '刷新合成课表',
              const ['范围：合成数据'],
            );
        _pending = _sourceRecord;
        _notify();
        return AgentToolResult(
          status: 'waitingForApproval',
          data: {'action_id': _pending!.id},
        );
      default:
        return AgentToolResult(status: 'unavailable', failure: 'unavailable');
    }
  }

  @override
  Future<void> validateDelivery() async {
    if (_revoked) throw const AgentFailure(AgentFailureCode.cancelled);
  }

  @override
  Future<String> selectForDiscussion(AgentDiscussionSelection selection) async {
    if (_revoked) throw const AgentFailure(AgentFailureCode.cancelled);
    _owner.discussionSelections.add(selection);
    final validate = _owner.discussionValidator;
    return validate == null ? '合成讨论选择内容' : await validate(selection);
  }

  @override
  Future<AgentToolResult> decidePending(bool approved) async {
    if (_revoked) {
      return AgentToolResult(status: 'cancelled', failure: 'cancelled');
    }
    final pending = _pending;
    if (pending == null) return AgentToolResult(status: 'stale');
    if (_plan != null) {
      final plans = _owner._store.localCalendar as AgentLocalPlanPort;
      if (!approved) {
        await plans.rejectLocalPlan(_plan!);
        _pending = null;
        _plan = null;
        return AgentToolResult(status: 'rejected', data: const {'count': 0});
      }
      final approval = await plans.approveLocalPlan(_plan!);
      final receipt = await plans.commitLocalPlan(approval);
      _owner.commitCount++;
      _pending = null;
      _plan = null;
      _contextInvalidated = true;
      return AgentToolResult(
        status: 'committed',
        data: {
          'count': receipt.committedCount,
          'revision': receipt.revision,
          'plan_id': receipt.planId,
        },
      );
    }
    if (_sourceRecord != null) {
      if (!approved) {
        await (_owner._store.agent as AgentActionRecordPort).settleActionRecord(
          _requireTicket(),
          _sourceRecord!,
          AgentActionStatus.rejected,
        );
        _pending = null;
        _sourceRecord = null;
        return AgentToolResult(status: 'rejected', data: const {'count': 0});
      }
      _owner.sourceRefreshCount++;
      _owner.ownedSourceJobId ??= 'synthetic-owned-job';
      _waitingForSchool = true;
      _schoolDecision = Completer<AgentToolResult>();
      _notify();
      return _schoolDecision!.future;
    }
    return AgentToolResult(status: 'stale');
  }

  @override
  Future<void> continueSchool() async {
    if (!_waitingForSchool) return;
    _owner.sourceContinueCount++;
    _owner.lastContinuedJobId = _owner.ownedSourceJobId;
    _waitingForSchool = false;
    _notify();
    final decision = _schoolDecision;
    _schoolDecision = null;
    if (decision != null && !decision.isCompleted) {
      decision.complete(
        AgentToolResult(
          status: 'success',
          data: {'job': _owner.ownedSourceJobId!},
        ),
      );
    }
  }

  @override
  void acknowledgeContextInvalidated() {
    _contextInvalidated = false;
  }

  @override
  void revoke() {
    _revoked = true;
    final ticket = _ticket;
    if (ticket != null) {
      (_owner._store.localCalendar as AgentLocalPlanPort).revokeLocalPlans(
        ticket,
      );
    }
  }

  void finishOwnedSourceJob() {
    _waitingForSchool = false;
    _notify();
  }

  void cancelOwnedSourceJob() {
    _waitingForSchool = false;
    _notify();
    final decision = _schoolDecision;
    _schoolDecision = null;
    if (decision != null && !decision.isCompleted) {
      decision.complete(
        AgentToolResult(status: 'cancelled', failure: 'cancelled'),
      );
    }
  }

  AgentRunTicket _requireTicket() =>
      _ticket ?? (throw const AgentFailure(AgentFailureCode.staleContext));

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }
}

final class _SyntheticProtector implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-dpapi/v1';

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
