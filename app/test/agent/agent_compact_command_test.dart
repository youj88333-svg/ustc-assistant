import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/agent_context_budget.dart';
import 'package:ustc_assistant_m0/agent/agent_coordinator.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/core/agent_context_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/agent_conversation_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

void main() {
  test(
    'compact preserves its summary and recent complete transcript across restart',
    () async {
      final file = await _temporaryDatabase();
      var store = await _open(file: file);
      final configured = await _configure(store);
      final archive = await store.agent.createConversation();
      final primary = await store.agent.createConversation();
      await _writeHistory(
        store,
        configured.authority,
        archive,
        'archive-A-private-question-marker',
        'archive-A-private-answer-marker',
      );
      await _writeStructuredHistory(store, configured.authority, primary);
      await store.customStatement(
        'UPDATE agent_conversations SET updated_at=? WHERE conversation_id=?',
        [DateTime.utc(2026, 10, 14).microsecondsSinceEpoch, primary],
      );
      expect(await store.agent.ensurePrimaryConversation(), primary);

      var gateway = _SyntheticGateway();
      var coordinator = await _coordinator(store, gateway);
      gateway.enqueueEvents([
        const ModelTextDelta('用户准备继续复习线性代数，尚未确定先学哪一章。'),
        ModelCompleted(finishReason: 'stop'),
      ]);
      await coordinator.send(' /compact ');

      expect(coordinator.view.failure, isNull);
      expect(coordinator.view.contextCompacted, isTrue);
      expect(gateway.requests, hasLength(1));
      final compactRequest = gateway.requests.single;
      expect(compactRequest.tools, isEmpty);
      expect(compactRequest.messages, hasLength(2));
      final compactInput = compactRequest.messages.last.content!;
      expect(compactInput, contains('linear algebra study intent marker'));
      expect(compactInput, contains('收到时间（北京时间）：2026-10-13 16:00:00.000'));
      expect(
        compactInput,
        isNot(contains('archive-A-private-question-marker')),
      );
      expect(compactInput, contains('old assistant fabricated fact marker'));
      expect(compactInput, isNot(contains('old-evidence-marker')));
      expect(compactInput, isNot(contains('e_0123456789abcdef')));
      expect(compactInput, isNot(contains('query_agenda')));

      final storedHistory = await store.agent.messages(primary);
      final storedAssistant = storedHistory.singleWhere(
        (message) => message.role == AgentMessageRole.assistant,
      );
      expect(
        storedAssistant.evidence.map((evidence) => evidence.id),
        contains('e_0123456789abcdef'),
      );
      expect(
        storedAssistant.steps.map((step) => step.tool),
        contains('query_agenda'),
      );

      final saved = await (store.agent as AgentConversationControlPort)
          .readConversationContext();
      expect(saved.summary, '用户准备继续复习线性代数，尚未确定先学哪一章。');
      expect(saved.coveredMessageId, saved.lastMessageId);
      gateway.enqueueEvents([
        const ModelTextDelta('摘要已存在，但本轮回答仍按新问题处理。'),
        ModelCompleted(finishReason: 'length'),
      ]);
      await coordinator.send('/compact');
      expect(coordinator.view.failure, AgentFailureCode.protocol);
      expect(
        (await (store.agent as AgentConversationControlPort)
                .readConversationContext())
            .summary,
        saved.summary,
      );

      await coordinator.close();
      await store.close();

      store = await _open(file: file);
      gateway = _SyntheticGateway();
      coordinator = await _coordinator(store, gateway);
      gateway.enqueueEvents([
        const ModelTextDelta('先从矩阵与向量空间的基础概念开始。'),
        ModelCompleted(finishReason: 'stop'),
      ]);
      await coordinator.send('我该从哪里开始？');
      expect(gateway.requests, hasLength(1));
      final afterRestart = _requestText(gateway.requests.single);
      expect(afterRestart, contains('历史摘要'));
      expect(afterRestart, contains(saved.summary));
      expect(afterRestart, contains('我该从哪里开始？'));
      expect(afterRestart, contains('linear algebra study intent marker'));
      expect(afterRestart, contains('old assistant fabricated fact marker'));
      expect(afterRestart, isNot(contains('old-evidence-marker')));
      expect(afterRestart, isNot(contains('e_0123456789abcdef')));
      final historicalUser = gateway.requests.single.messages.firstWhere(
        (message) =>
            message.role == 'user' &&
            (message.content ?? '').contains(
              'linear algebra study intent marker',
            ),
      );
      expect(
        historicalUser.content,
        contains('收到时间（北京时间）：2026-10-13 16:00:00.000'),
      );
      expect(
        gateway.requests.single.messages.any(
          (message) =>
              message.role == 'assistant' && message.toolCalls.isNotEmpty,
        ),
        isFalse,
      );
      expect(
        gateway.requests.single.messages.where(
          (message) => message.role == 'tool',
        ),
        isEmpty,
      );
      expect(
        gateway.requests.single.messages.any(
          (message) =>
              message.role == 'assistant' &&
              message.content == 'old assistant fabricated fact marker',
        ),
        isTrue,
      );
      expect(
        afterRestart,
        isNot(contains('archive-A-private-question-marker')),
      );

      await coordinator.send('/clear');
      final cleared = await (store.agent as AgentConversationControlPort)
          .readConversationContext();
      expect(cleared.summary, '');
      expect(cleared.messages, isEmpty);
      expect(cleared.conversationId, isNot(primary));
      expect((await store.agent.messages(archive)).map((m) => m.text), [
        'archive-A-private-question-marker',
        'archive-A-private-answer-marker',
      ]);

      gateway.enqueueEvents([
        const ModelTextDelta('这是清空后的新会话。'),
        ModelCompleted(finishReason: 'stop'),
      ]);
      await coordinator.send('清空后新问题 marker');
      final afterClear = _requestText(gateway.requests.last);
      expect(afterClear, contains('清空后新问题 marker'));
      expect(afterClear, isNot(contains(saved.summary)));
      expect(afterClear, isNot(contains('linear algebra study intent marker')));
      expect(
        afterClear,
        isNot(contains('old assistant fabricated fact marker')),
      );
      expect(afterClear, isNot(contains('old-evidence-marker')));
      expect(afterClear, isNot(contains('e_0123456789abcdef')));
      expect(afterClear, isNot(contains('archive-A-private-question-marker')));
    },
  );

  test(
    'manual compact timeout preserves the stored chat and a later send succeeds',
    () async {
      final store = await _open();
      final configured = await _configure(store);
      final primary = await store.agent.ensurePrimaryConversation();
      await _writeHistory(
        store,
        configured.authority,
        primary,
        'manual-timeout-old-user-marker',
        'manual-timeout-old-assistant-marker',
      );
      final before = await (store.agent as AgentConversationControlPort)
          .readConversationContext();
      final gateway = _SyntheticGateway()
        ..enqueueFailure(TimeoutException('synthetic no tokens'))
        ..enqueueEvents([
          const ModelTextDelta('已根据保留的历史继续回答。'),
          ModelCompleted(finishReason: 'stop'),
        ]);
      final coordinator = await _coordinator(store, gateway);

      await coordinator.send('/compact');

      expect(coordinator.view.failure, AgentFailureCode.timeout);
      expect(gateway.cancelCount, greaterThanOrEqualTo(1));
      final afterTimeout = await (store.agent as AgentConversationControlPort)
          .readConversationContext();
      expect(afterTimeout.summary, before.summary);
      expect(
        afterTimeout.messages.map((message) => message.text).toList(),
        before.messages.map((message) => message.text).toList(),
      );
      expect(gateway.requests, hasLength(1));
      expect(gateway.requests.single.tools, isEmpty);

      await coordinator.send('继续处理保留的内容');

      expect(coordinator.view.failure, isNull);
      final resumedRequest = gateway.requests.last;
      expect(
        resumedRequest.messages.any(
          (message) =>
              message.role == 'user' &&
              (message.content ?? '').contains(
                'manual-timeout-old-user-marker',
              ),
        ),
        isTrue,
      );
      expect(
        resumedRequest.messages.any(
          (message) =>
              message.role == 'assistant' &&
              message.content == 'manual-timeout-old-assistant-marker',
        ),
        isTrue,
      );
      expect(resumedRequest.messages.last.content, '继续处理保留的内容');
      final afterResume = await (store.agent as AgentConversationControlPort)
          .readConversationContext();
      expect(afterResume.summary, before.summary);
    },
  );

  test(
    'automatic compact timeout keeps durable history and fits complete groups around the current question',
    () async {
      final store = await _open();
      final configured = await _configure(store);
      final primary = await store.agent.ensurePrimaryConversation();
      final oldLongQuestion =
          'old-long-user-marker ${List.filled(2200, '课').join()}';
      final oldLongAnswer =
          'old-long-assistant-marker ${List.filled(1000, '学').join()}';
      await _writeHistory(
        store,
        configured.authority,
        primary,
        oldLongQuestion,
        oldLongAnswer,
      );
      await _writeHistory(
        store,
        configured.authority,
        primary,
        'retained-middle-user-marker',
        'retained-middle-assistant-marker',
      );
      final gateway = _SyntheticGateway()
        ..enqueueFailure(TimeoutException('synthetic no tokens'))
        ..enqueueEvents([
          const ModelTextDelta('已在完整历史组范围内继续回答。'),
          ModelCompleted(finishReason: 'stop'),
        ]);
      final coordinator = await _coordinator(
        store,
        gateway,
        contextBudget: AgentContextBudget(
          maximumInputTokens: 4096,
          softFraction: 0.75,
        ),
      );
      const currentQuestion = 'current-question-after-auto-timeout';

      await coordinator.send(currentQuestion);

      expect(coordinator.view.failure, isNull);
      expect(gateway.requests, hasLength(2));
      expect(gateway.cancelCount, greaterThanOrEqualTo(1));
      expect(gateway.requests.first.tools, isEmpty);
      final request = gateway.requests.last;
      expect(
        request.messages.any(
          (message) =>
              message.role == 'user' && message.content == currentQuestion,
        ),
        isTrue,
      );
      expect(
        request.messages.any(
          (message) =>
              message.role == 'user' &&
              (message.content ?? '').contains('retained-middle-user-marker'),
        ),
        isTrue,
      );
      expect(
        request.messages.any(
          (message) =>
              message.role == 'assistant' &&
              message.content == 'retained-middle-assistant-marker',
        ),
        isTrue,
      );
      expect(
        request.messages.any(
          (message) => (message.content ?? '').contains('old-long-user-marker'),
        ),
        isFalse,
        reason: 'the oversized oldest transcript is trimmed as one full group',
      );

      final persisted = await (store.agent as AgentConversationControlPort)
          .readConversationContext();
      expect(persisted.summary, isEmpty);
      expect(
        persisted.messages.map((message) => message.text),
        containsAll([
          oldLongQuestion,
          oldLongAnswer,
          'retained-middle-user-marker',
          'retained-middle-assistant-marker',
          currentQuestion,
          '已在完整历史组范围内继续回答。',
        ]),
      );
    },
  );

  test(
    'a short affirmation retains the original scope and answer after compact',
    () async {
      const question = '请把今天下午课程的本地出勤计划改为不参加';
      final file = await _temporaryDatabase();
      var store = await _open(file: file);
      final configured = await _configure(store);
      final primary = await store.agent.ensurePrimaryConversation();
      await _writeStructuredHistory(
        store,
        configured.authority,
        primary,
        question: question,
        answer: 'synthetic-old-course-detail-marker。确认这样做吗？',
      );
      var gateway = _SyntheticGateway();
      var coordinator = await _coordinator(store, gateway);
      gateway.enqueueEvents([
        const ModelTextDelta('用户想把下午课程的本地出勤计划改为不参加。'),
        ModelCompleted(finishReason: 'stop'),
      ]);
      await coordinator.send('/compact');
      expect(coordinator.view.failure, isNull);
      expect(coordinator.view.contextCompacted, isTrue);
      await coordinator.close();
      await store.close();

      store = await _open(file: file);
      gateway = _SyntheticGateway();
      coordinator = await _coordinator(store, gateway);
      gateway.enqueueEvents([
        const ModelTextDelta('我会先重新核对下午课程，再准备具体方案。'),
        ModelCompleted(finishReason: 'stop'),
      ]);
      await coordinator.send('对的');
      expect(coordinator.view.failure, isNull);
      final request = gateway.requests.single;
      final text = _requestText(request);
      final historicalUser = request.messages.firstWhere(
        (message) =>
            message.role == 'user' &&
            (message.content ?? '').contains(question),
      );
      expect(historicalUser.content, contains(question));
      expect(
        historicalUser.content,
        contains('收到时间（北京时间）：2026-10-13 16:00:00.000'),
      );
      expect(request.messages.last.role, 'user');
      expect(request.messages.last.content, '对的');
      expect(
        request.messages.any(
          (message) =>
              message.role == 'assistant' &&
              (message.content ?? '').contains(
                'synthetic-old-course-detail-marker',
              ),
        ),
        isTrue,
        reason:
            'the complete prior assistant answer remains available after compact',
      );
      expect(text, contains('确认这样做吗？'));
      expect(text, contains('用户想把下午课程的本地出勤计划改为不参加'));
      expect(request.messages.expand((message) => message.toolCalls), isEmpty);
      expect(text, contains('synthetic-old-course-detail-marker'));
      expect(text, isNot(contains('old-evidence-marker')));
      expect(text, isNot(contains('e_0123456789abcdef')));
      expect(coordinator.view.pendingAction, isNull);
    },
  );

  test(
    'stop while compact generation is pending leaves history and summary intact',
    () async {
      final store = await _open();
      final configured = await _configure(store);
      final primary = await store.agent.ensurePrimaryConversation();
      await _writeHistory(
        store,
        configured.authority,
        primary,
        'pending compact user intent',
        'pending compact assistant text',
      );
      final gateway = _SyntheticGateway();
      final coordinator = await _coordinator(store, gateway);
      final compact = coordinator.send('/compact');
      final request = await gateway.nextRequest();
      expect(request.tools, isEmpty);

      await coordinator.stop();
      await compact;
      final context = await (store.agent as AgentConversationControlPort)
          .readConversationContext();
      expect(context.summary, '');
      expect(context.messages.map((m) => m.text), [
        'pending compact user intent',
        'pending compact assistant text',
      ]);
    },
  );

  test(
    'actual coordinator stop revokes a compact result at checkpoint',
    () async {
      late JwStore store;
      late AgentCoordinator coordinator;
      var stopAtCheckpoint = false;
      final reached = Completer<void>(), release = Completer<void>();
      store = await _open(
        checkpoint: () async {
          if (stopAtCheckpoint) {
            stopAtCheckpoint = false;
            reached.complete();
            await release.future;
          }
        },
      );
      final configured = await _configure(store);
      final primary = await store.agent.ensurePrimaryConversation();
      await _writeHistory(
        store,
        configured.authority,
        primary,
        'checkpoint compact user intent',
        'checkpoint compact assistant text',
      );
      final gateway = _SyntheticGateway();
      coordinator = await _coordinator(store, gateway);
      gateway.enqueueEvents([
        const ModelTextDelta('不应提交的摘要'),
        ModelCompleted(finishReason: 'stop'),
      ]);

      stopAtCheckpoint = true;
      final compact = coordinator.send('/compact');
      await reached.future;
      final stopping = coordinator.stop();
      release.complete();
      await compact;
      await stopping;
      expect(coordinator.view.failure, AgentFailureCode.cancelled);
      final context = await (store.agent as AgentConversationControlPort)
          .readConversationContext();
      expect(context.summary, '');
      expect(context.messages, hasLength(2));
    },
  );
}

Future<JwStore> _open({File? file, Future<void> Function()? checkpoint}) async {
  final store = JwStore(
    file == null ? NativeDatabase.memory() : NativeDatabase(file),
    ownership: _TestOwnership(),
    clock: FixedClock(DateTime.utc(2026, 10, 13, 8)),
    modelCredentialProtector: _SyntheticProtector(),
    onAgentCheckpoint: checkpoint,
  );
  addTearDown(store.close);
  await store.initialize();
  await store.agent.initializeAgent();
  return store;
}

Future<AgentSettingsSnapshot> _configure(JwStore store) async {
  final before = await store.agent.inspectAgent();
  await store.agent.saveModelConfiguration(
    before.authority,
    modelId: 'synthetic-chat-model',
    modelIds: const ['synthetic-chat-model'],
    report: const AgentCapabilityReport(text: true, streaming: true),
    consent: true,
    key: Uint8List.fromList(utf8.encode('synthetic-chat-key')),
  );
  return store.agent.inspectAgent();
}

Future<AgentCoordinator> _coordinator(
  JwStore store,
  _SyntheticGateway gateway, {
  AgentContextBudget? contextBudget,
}) async {
  final coordinator = AgentCoordinator(
    data: store.agent,
    gateway: gateway,
    clock: FixedClock(DateTime.utc(2026, 10, 13, 8)),
    contextBudget: contextBudget,
  );
  addTearDown(coordinator.close);
  await coordinator.initialize();
  return coordinator;
}

Future<void> _writeHistory(
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

Future<void> _writeStructuredHistory(
  JwStore store,
  AgentAuthority authority,
  String conversationId, {
  String question = 'linear algebra study intent marker',
  String answer = 'old assistant fabricated fact marker',
}) async {
  final ticket = await store.agent.beginRun(
    authority,
    conversationId,
    question,
  );
  await store.agent.saveAssistant(ticket, answer);
  await (store.agent as AgentRunJournalPort).saveRunJournal(
    ticket,
    evidence: [
      AgentEvidence(
        id: 'e_0123456789abcdef',
        provider: 'local',
        title: 'old-evidence-marker',
        observedAtUtc: DateTime.utc(2026, 10, 13),
        scope: 'synthetic-local',
        complete: true,
      ),
    ],
    steps: const [AgentToolStep(tool: 'query_agenda', status: 'success')],
    imageCount: 0,
  );
  final policy = await (store.agent as AgentUsePolicyPort).readAgentUsePolicy();
  await (store.agent as AgentTranscriptPort).saveAgentTurn(
    ticket,
    items: [AgentContextItem(role: 'assistant', text: answer)],
    includesPersonalContent: false,
    policyRevision: policy.revision,
  );
  await store.agent.finishRun(ticket, AgentMessageStatus.complete);
}

String _requestText(ModelRequest request) =>
    request.messages.map((message) => message.content ?? '').join('\n');

Future<File> _temporaryDatabase() async {
  final directory = await Directory.systemTemp.createTemp(
    'agent-compact-command-',
  );
  addTearDown(() async {
    final root =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}';
    if (!directory.absolute.path.toLowerCase().startsWith(root.toLowerCase()) ||
        !directory.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('agent-compact-command-')) {
      throw StateError('Unexpected compact test directory.');
    }
    const allowed = {
      'compact.sqlite',
      'compact.sqlite-wal',
      'compact.sqlite-shm',
      'compact.sqlite-journal',
    };
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File || !allowed.contains(entry.uri.pathSegments.last)) {
        throw StateError('Unexpected compact test asset.');
      }
      await entry.delete();
    }
    await directory.delete();
  });
  return File('${directory.path}${Platform.pathSeparator}compact.sqlite');
}

final class _SyntheticGateway implements ModelGatewayPort {
  final Queue<Object> _scripts = Queue();
  final List<ModelRequest> requests = [];
  final List<_SyntheticGeneration> _generations = [];
  final List<Completer<ModelRequest>> _requestWaiters = [];
  final List<ModelRequest> _pendingRequests = [];
  bool _closed = false;
  int cancelCount = 0;

  void enqueueEvents(List<ModelEvent> events) => _scripts.add(events);

  void enqueueFailure(Object error) =>
      _scripts.add(_SyntheticStreamFailure(error));

  Future<ModelRequest> nextRequest() {
    if (_pendingRequests.isNotEmpty) {
      return Future<ModelRequest>.value(_pendingRequests.removeAt(0));
    }
    final waiter = Completer<ModelRequest>();
    _requestWaiters.add(waiter);
    return waiter.future;
  }

  @override
  Future<List<String>> listModels(ModelSecretLease secret) async {
    _consume(secret);
    return const ['synthetic-chat-model'];
  }

  @override
  Stream<ModelEvent> generate(ModelRequest request, ModelSecretLease secret) {
    _consume(secret);
    if (_closed) {
      return Stream<ModelEvent>.error(
        const AgentFailure(AgentFailureCode.closed),
      );
    }
    requests.add(request);
    if (_requestWaiters.isEmpty) {
      _pendingRequests.add(request);
    } else {
      _requestWaiters.removeAt(0).complete(request);
    }
    final script = _scripts.isEmpty ? null : _scripts.removeFirst();
    if (script is _SyntheticStreamFailure) {
      return Stream<ModelEvent>.error(script.error);
    }
    final generation = _SyntheticGeneration(request);
    _generations.add(generation);
    if (script is List<ModelEvent>) {
      unawaited(_emit(generation, script));
    }
    return generation.stream;
  }

  Future<void> _emit(
    _SyntheticGeneration generation,
    List<ModelEvent> events,
  ) async {
    await generation.started.future;
    for (final event in events) {
      if (!generation.emit(event)) return;
    }
    await generation.finish();
  }

  void _consume(ModelSecretLease secret) {
    final bytes = secret.take();
    bytes.fillRange(0, bytes.length, 0);
  }

  @override
  Future<void> cancelAndDrain() async {
    cancelCount++;
    await Future.wait(
      _generations
          .where((generation) => !generation.isClosed)
          .map((generation) => generation.finish()),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    await cancelAndDrain();
    _closed = true;
    for (final waiter in _requestWaiters) {
      if (!waiter.isCompleted) {
        waiter.completeError(const AgentFailure(AgentFailureCode.closed));
      }
    }
    _requestWaiters.clear();
  }
}

final class _SyntheticStreamFailure {
  const _SyntheticStreamFailure(this.error);
  final Object error;
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
  Future<void>? _finish;
  Stream<ModelEvent> get stream => controller.stream;
  bool get isClosed => controller.isClosed;

  bool emit(ModelEvent event) {
    if (controller.isClosed) return false;
    controller.add(event);
    return true;
  }

  Future<void> finish() => _finish ??= controller.close();
}

final class _SyntheticProtector implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-compact-protector/v1';

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
