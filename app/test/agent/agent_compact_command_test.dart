import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/agent_coordinator.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/agent_conversation_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

void main() {
  test(
    'compact persists across restart and only sends its safe summary with new turns',
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
      expect(
        compactInput,
        isNot(contains('archive-A-private-question-marker')),
      );
      expect(
        compactInput,
        isNot(contains('old assistant fabricated fact marker')),
      );
      expect(compactInput, isNot(contains('old-tool-step-marker')));
      expect(compactInput, isNot(contains('old-evidence-marker')));

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
      expect(
        afterRestart,
        isNot(contains('linear algebra study intent marker')),
      );
      expect(
        afterRestart,
        isNot(contains('old assistant fabricated fact marker')),
      );
      expect(afterRestart, isNot(contains('old-tool-step-marker')));
      expect(afterRestart, isNot(contains('old-evidence-marker')));
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
      expect(afterClear, isNot(contains('old-tool-step-marker')));
      expect(afterClear, isNot(contains('old-evidence-marker')));
      expect(afterClear, isNot(contains('archive-A-private-question-marker')));
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
  _SyntheticGateway gateway,
) async {
  final coordinator = AgentCoordinator(
    data: store.agent,
    gateway: gateway,
    clock: FixedClock(DateTime.utc(2026, 10, 13, 8)),
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
  String conversationId,
) async {
  const question = 'linear algebra study intent marker';
  const answer = 'old assistant fabricated fact marker';
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
  final Queue<List<ModelEvent>> _scripts = Queue<List<ModelEvent>>();
  final List<ModelRequest> requests = [];
  final List<_SyntheticGeneration> _generations = [];
  final List<Completer<ModelRequest>> _requestWaiters = [];
  final List<ModelRequest> _pendingRequests = [];
  bool _closed = false;

  void enqueueEvents(List<ModelEvent> events) => _scripts.add(events);

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
    final generation = _SyntheticGeneration(request);
    _generations.add(generation);
    if (_scripts.isNotEmpty) {
      final events = _scripts.removeFirst();
      unawaited(_emit(generation, events));
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
