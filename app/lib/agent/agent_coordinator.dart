import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../core/agent_contract.dart';
import '../core/agent_text.dart';
import '../core/contracts.dart';
import 'model_gateway_contract.dart';

/// C4 owns one model run, independently of C2's source lease. Business tools
/// are deliberately absent in M5.1; only explicit synthetic capability probes
/// may submit the fixed echo tool declaration.
final class AgentCoordinator {
  AgentCoordinator({
    required this.data,
    required this.gateway,
    this.clock = const SystemClock(),
  });
  final AgentDataPort data;
  final ModelGatewayPort gateway;
  final AppClock clock;
  final _changes = StreamController<AgentRuntimeView>.broadcast();
  AgentRuntimeView _view = AgentRuntimeView();
  AgentRuntimeView get view => _view;
  Stream<AgentRuntimeView> get changes => _changes.stream;
  AgentSettingsSnapshot? _settings;
  List<String> _models = [];
  List<AgentConversation> _conversations = [];
  List<AgentMessage> _messages = [];
  String? _conversation;
  AgentCapabilityReport _report = const AgentCapabilityReport();
  AgentPhase _phase = AgentPhase.idle;
  AgentFailureCode? _failure;
  Future<void>? _work, _stopFuture, _closeFuture;
  int _generation = 0;
  bool _stopping = false, _closed = false;
  AgentRunTicket? _ticket;
  AgentHistoryIntent? _pendingHistory;
  Uint8List? _candidateKey;
  Timer? _candidateExpiry;
  String _liveText = '';
  int _requests = 0;

  void _publish() {
    _view = AgentRuntimeView(
      phase: _phase,
      settings: _settings,
      availableModels: _models,
      conversations: _conversations,
      messages: _messages,
      conversationId: _conversation,
      failure: _failure,
      report: _report,
      pendingKeyProvided: _candidateKey != null,
      historyTruncated: _messages.length >= 100,
    );
    if (!_closed) _changes.add(_view);
  }

  static AgentFailureCode _code(Object error) =>
      error is AgentFailure ? error.code : AgentFailureCode.storageFailed;
  void _wipeCandidate() {
    _candidateExpiry?.cancel();
    _candidateExpiry = null;
    _candidateKey?.fillRange(0, _candidateKey!.length, 0);
    _candidateKey = null;
  }

  void _candidate(String key) {
    if (key.isEmpty) return;
    _wipeCandidate();
    final bytes = Uint8List.fromList(utf8.encode(key.trim()));
    if (bytes.isEmpty ||
        bytes.length > 4096 ||
        bytes.any((b) => b < 33 || b > 126)) {
      bytes.fillRange(0, bytes.length, 0);
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    _candidateKey = bytes;
    _candidateExpiry = Timer(const Duration(minutes: 3), () {
      _wipeCandidate();
      if (_work != null) {
        unawaited(
          stop().catchError((Object e) {
            _phase = AgentPhase.recovery;
            _failure = _code(e);
            _publish();
          }),
        );
      }
      _publish();
    });
  }

  void _current(int generation) {
    if (_closed) throw const AgentFailure(AgentFailureCode.closed);
    if (_stopping || generation != _generation) {
      throw const AgentFailure(AgentFailureCode.cancelled);
    }
  }

  Future<ModelSecretLease> _secret(
    AgentAuthority authority,
    int generation,
  ) async {
    _current(generation);
    final candidate = _candidateKey;
    if (candidate != null) {
      return ModelSecretLease(Uint8List.fromList(candidate));
    }
    final secret = await data.leaseModelKey(authority);
    try {
      _current(generation);
      return secret;
    } catch (_) {
      secret.revoke();
      rethrow;
    }
  }

  Future<List<String>> _listModels(
    AgentAuthority authority,
    int generation,
  ) async {
    final secret = await _secret(authority, generation);
    try {
      _current(generation);
      _requests++;
      return await gateway.listModels(secret);
    } finally {
      secret.revoke();
    }
  }

  Future<void> _refresh() async {
    _settings = await data.inspectAgent();
    _report = _settings!.report;
    _conversations = await data.conversations();
    if (_conversation != null &&
        !_conversations.any((c) => c.id == _conversation)) {
      _conversation = null;
    }
    _conversation ??= _conversations.isEmpty ? null : _conversations.first.id;
    _messages = _conversation == null
        ? []
        : await data.messages(_conversation!);
    if (_models.isEmpty) _models = _settings!.modelIds;
  }

  Future<void> initialize() async {
    if (_closed) throw const AgentFailure(AgentFailureCode.closed);
    await _refresh();
    _report = _settings!.report;
    _phase = AgentPhase.idle;
    _failure = null;
    _publish();
  }

  Future<void> refresh() async {
    if (_closed || _work != null) return;
    try {
      await _refresh();
      _failure = null;
    } catch (e) {
      _failure = _code(e);
    }
    _publish();
  }

  Future<void> _action(
    AgentPhase phase,
    Future<void> Function(int) body,
  ) async {
    if (_closed || _closeFuture != null) {
      _failure = AgentFailureCode.closed;
      _publish();
      return;
    }
    if (_work != null ||
        _stopFuture != null ||
        _phase == AgentPhase.maintenance ||
        _phase == AgentPhase.recovery) {
      _failure = AgentFailureCode.busy;
      _publish();
      return;
    }
    final generation = ++_generation;
    _stopping = false;
    _failure = null;
    _phase = phase;
    final done = Completer<void>();
    _work = done.future;
    _publish();
    try {
      await body(generation);
    } catch (e) {
      _failure = _stopping ? AgentFailureCode.cancelled : _code(e);
    } finally {
      if (_phase != AgentPhase.recovery && !_stopping) _ticket = null;
      if (!_closed &&
          !_stopping &&
          _phase != AgentPhase.maintenance &&
          _phase != AgentPhase.recovery) {
        try {
          await _refresh();
        } catch (e) {
          _failure ??= _code(e);
        }
        _phase = AgentPhase.idle;
      }
      _work = null;
      done.complete();
      _publish();
    }
  }

  Future<void> loadModels({String key = '', required bool consent}) => _action(
    AgentPhase.loadingModels,
    (g) async {
      if (!consent) throw const AgentFailure(AgentFailureCode.consentRequired);
      await _refresh();
      _current(g);
      _candidate(key);
      try {
        _models = await _listModels(_settings!.authority, g);
        _current(g);
        if (_models.isEmpty) {
          throw const AgentFailure(AgentFailureCode.modelRequired);
        }
      } catch (_) {
        _wipeCandidate();
        rethrow;
      }
    },
  );

  Future<({String text, ModelCompleted completed})> _probe(
    ModelRequest request,
    AgentAuthority authority,
    int g,
  ) async {
    final text = StringBuffer();
    ModelCompleted? completed;
    final secret = await _secret(authority, g);
    try {
      _current(g);
      _requests++;
      await for (final event in gateway.generate(request, secret)) {
        _current(g);
        switch (event) {
          case ModelTextDelta():
            text.write(event.text);
            AgentText.requireSafe(text.toString());
          case ModelCompleted():
            if (completed != null) {
              throw const AgentFailure(AgentFailureCode.protocol);
            }
            completed = event;
        }
      }
    } finally {
      secret.revoke();
    }
    _current(g);
    if (completed == null) throw const AgentFailure(AgentFailureCode.protocol);
    return (text: text.toString(), completed: completed);
  }

  static ModelToolDefinition get _echo => ModelToolDefinition(
    name: 'echo_probe',
    description:
        'Synthetic capability test only. Call with value ustc_probe, then return the proof from the tool result.',
    parameters: {
      'type': 'object',
      'properties': {
        'value': {'type': 'string'},
      },
      'required': ['value'],
      'additionalProperties': false,
    },
  );

  Future<void> verifyAndSave({
    String key = '',
    required String modelId,
    required bool consent,
  }) => _action(AgentPhase.verifying, (g) async {
    if (!consent) throw const AgentFailure(AgentFailureCode.consentRequired);
    if (!AgentText.validModelId(modelId)) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    await _refresh();
    _current(g);
    _candidate(key);
    final authority = _settings!.authority;
    try {
      final ids = await _listModels(authority, g);
      _current(g);
      _models = ids;
      if (!ids.contains(modelId)) {
        throw const AgentFailure(AgentFailureCode.modelRequired);
      }
      final textProbe = await _probe(
        ModelRequest(
          modelId: modelId,
          messages: [
            ModelChatMessage(
              role: 'user',
              content: '只回复 USTC_TEXT_PROBE。这是合成文本与流式能力测试。',
            ),
          ],
          maxTokens: 128,
        ),
        authority,
        g,
      );
      if (textProbe.text.trim().isEmpty ||
          textProbe.completed.finishReason != 'stop' ||
          textProbe.completed.toolCalls.isNotEmpty) {
        throw const AgentFailure(AgentFailureCode.protocol);
      }
      _report = const AgentCapabilityReport(text: true, streaming: true);
      _publish();
      try {
        final toolMessages = [
          ModelChatMessage(
            role: 'user',
            content:
                '请调用 echo_probe，value 必须是 ustc_probe。收到工具结果后，只回复其 proof 字段。',
          ),
        ];
        final call = await _probe(
          ModelRequest(
            modelId: modelId,
            messages: toolMessages,
            tools: [_echo],
            toolChoice: 'echo_probe',
            maxTokens: 256,
          ),
          authority,
          g,
        );
        if (call.completed.finishReason != 'tool_calls' ||
            call.completed.toolCalls.length != 1) {
          throw const AgentFailure(AgentFailureCode.protocol);
        }
        final tool = call.completed.toolCalls.single;
        final arguments = jsonDecode(tool.argumentsJson);
        if (tool.name != 'echo_probe' ||
            arguments is! Map ||
            arguments.length != 1 ||
            arguments['value'] != 'ustc_probe') {
          throw const AgentFailure(AgentFailureCode.protocol);
        }
        _report = const AgentCapabilityReport(
          text: true,
          streaming: true,
          toolCall: true,
        );
        _publish();
        final proof =
            'ustc-result-${Random.secure().nextInt(0x7fffffff).toRadixString(16)}';
        final result = await _probe(
          ModelRequest(
            modelId: modelId,
            messages: [
              ...toolMessages,
              ModelChatMessage(
                role: 'assistant',
                content: call.text.isEmpty ? null : call.text,
                toolCalls: [tool],
              ),
              ModelChatMessage(
                role: 'tool',
                toolCallId: tool.id,
                content: jsonEncode({'value': 'ustc_probe', 'proof': proof}),
              ),
            ],
            tools: [_echo],
            toolChoice: 'none',
            maxTokens: 128,
          ),
          authority,
          g,
        );
        if (result.completed.finishReason != 'stop' ||
            result.completed.toolCalls.isNotEmpty ||
            !result.text.contains(proof)) {
          throw const AgentFailure(AgentFailureCode.protocol);
        }
        _report = const AgentCapabilityReport(
          text: true,
          streaming: true,
          toolCall: true,
          toolResult: true,
        );
      } catch (e) {
        _current(g);
        final code = _code(e);
        if (code == AgentFailureCode.unauthorized ||
            code == AgentFailureCode.forbidden ||
            code == AgentFailureCode.cancelled ||
            code == AgentFailureCode.closed) {
          rethrow;
        }
        _report = AgentCapabilityReport(
          text: true,
          streaming: true,
          toolCall: _report.toolCall,
          failure: code,
        );
      }
      _current(g);
      final candidate = _candidateKey;
      final copy = candidate == null ? null : Uint8List.fromList(candidate);
      try {
        await data.saveModelConfiguration(
          authority,
          modelId: modelId,
          modelIds: ids,
          report: _report,
          consent: true,
          key: copy,
        );
      } finally {
        copy?.fillRange(0, copy.length, 0);
      }
    } finally {
      _wipeCandidate();
    }
  });

  Future<void> newConversation() => _action(AgentPhase.settling, (g) async {
    _conversation = await data.createConversation();
    _current(g);
  });
  Future<void> selectConversation(String id) =>
      _action(AgentPhase.settling, (g) async {
        final conversations = await data.conversations();
        _current(g);
        if (!conversations.any((c) => c.id == id)) {
          throw const AgentFailure(AgentFailureCode.staleContext);
        }
        _conversation = id;
      });
  void _showLive(String text) {
    final ticket = _ticket;
    if (ticket == null) return;
    _messages = _messages
        .map(
          (message) => message.id != ticket.assistantMessageId
              ? message
              : AgentMessage(
                  id: message.id,
                  role: message.role,
                  text: text,
                  status: AgentMessageStatus.streaming,
                  createdAtUtc: message.createdAtUtc,
                ),
        )
        .toList();
    _publish();
  }

  Future<void> send(String text) => _action(AgentPhase.generating, (g) async {
    _wipeCandidate();
    AgentText.requireSafe(text, maxCharacters: 6000);
    await _refresh();
    _current(g);
    final settings = _settings!;
    if (!settings.keySaved) {
      throw const AgentFailure(AgentFailureCode.keyRequired);
    }
    if (!settings.consent) {
      throw const AgentFailure(AgentFailureCode.consentRequired);
    }
    if (settings.report.capability == ModelCapability.unverified ||
        settings.modelId == null) {
      throw const AgentFailure(AgentFailureCode.modelRequired);
    }
    _conversation ??= await data.createConversation();
    _current(g);
    final history = await data.messages(_conversation!);
    _current(g);
    final context = <ModelChatMessage>[];
    var chars = 0;
    // Only complete safe dialogue is reused. Old partials/tool references are
    // not active context or permission; later slices add bounded summaries.
    for (final message in history.reversed) {
      if (message.status != AgentMessageStatus.complete) continue;
      AgentText.requireSafe(message.text);
      if (chars + message.text.length > 16000 || context.length >= 20) break;
      context.add(
        ModelChatMessage(role: message.role.name, content: message.text),
      );
      chars += message.text.length;
    }
    final ticket = await data.beginRun(
      settings.authority,
      _conversation!,
      text,
    );
    _ticket = ticket;
    _liveText = '';
    var savedLength = 0;
    var lastSave = clock.nowUtc;
    ModelCompleted? completed;
    final day = clock.nowUtc
        .add(const Duration(hours: 8))
        .toIso8601String()
        .substring(0, 10);
    try {
      await _refresh();
      _current(g);
      final request = ModelRequest(
        modelId: settings.modelId!,
        messages: [
          ModelChatMessage(
            role: 'system',
            content:
                '你是 USTC Assistant 校园事务助手。当前北京时间日期为 $day。当前切片只提供对话，尚未接入本地日程、任务、公开查询或业务写工具。不要声称读取了用户记录、执行了同步或保存了安排。资料不足时明确说明。不要索取账号密码或模型 Key。',
          ),
          ...context.reversed,
          ModelChatMessage(role: 'user', content: text),
        ],
      );
      final secret = await _secret(ticket.authority, g);
      try {
        _current(g);
        _requests++;
        await for (final event in gateway.generate(request, secret)) {
          _current(g);
          switch (event) {
            case ModelTextDelta():
              final candidate = '$_liveText${event.text}';
              AgentText.requireSafe(candidate);
              _liveText = candidate;
              _showLive(_liveText);
              if (_liveText.length - savedLength >= 512 ||
                  clock.nowUtc.difference(lastSave) >=
                      const Duration(milliseconds: 500)) {
                await data.saveAssistant(ticket, _liveText);
                _current(g);
                savedLength = _liveText.length;
                lastSave = clock.nowUtc;
              }
            case ModelCompleted():
              if (completed != null) {
                throw const AgentFailure(AgentFailureCode.protocol);
              }
              completed = event;
          }
        }
      } finally {
        secret.revoke();
      }
      _current(g);
      if (completed == null || _liveText.trim().isEmpty) {
        throw const AgentFailure(AgentFailureCode.protocol);
      }
      if (completed.toolCalls.isNotEmpty) {
        throw const AgentFailure(AgentFailureCode.toolUnavailable);
      }
      await data.saveAssistant(ticket, _liveText);
      _current(g);
      await data.finishRun(
        ticket,
        completed.finishReason == 'stop'
            ? AgentMessageStatus.complete
            : AgentMessageStatus.interrupted,
      );
    } catch (e) {
      if (!_stopping) {
        try {
          await data.saveAssistant(ticket, _liveText);
          await data.finishRun(
            ticket,
            _liveText.isEmpty
                ? AgentMessageStatus.failed
                : AgentMessageStatus.interrupted,
          );
        } catch (_) {
          // Preserve the handle until cancellation really succeeds. A failed
          // final save must not leave an active database run behind an idle UI.
          try {
            await data.cancelRun(ticket);
          } on AgentFailure catch (cancelError) {
            if (cancelError.code != AgentFailureCode.staleContext &&
                cancelError.code != AgentFailureCode.maintenance) {
              _phase = AgentPhase.recovery;
              _failure = cancelError.code;
            }
          } catch (_) {
            _phase = AgentPhase.recovery;
            _failure = AgentFailureCode.storageFailed;
          }
        }
      }
      rethrow;
    }
  });

  Future<void> stop() => _stop();

  Future<void> _stop({bool maintenance = false}) {
    if (_stopFuture != null) return _stopFuture!;
    if (_work == null && _phase != AgentPhase.recovery) {
      _wipeCandidate();
      if (maintenance) _phase = AgentPhase.maintenance;
      _publish();
      return Future<void>.value();
    }
    final result = _stopActive(maintenance: maintenance);
    _stopFuture = result;
    return result.whenComplete(() {
      _stopFuture = null;
    });
  }

  Future<void> _stopActive({required bool maintenance}) async {
    final work = _work;
    _stopping = true;
    ++_generation;
    _wipeCandidate();
    _phase = AgentPhase.settling;
    _publish();
    final ticket = _ticket;
    final drain = gateway.cancelAndDrain().then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    Object? cancellationFailure;
    if (ticket != null) {
      try {
        await data.saveAssistant(ticket, _liveText);
      } on AgentFailure catch (e) {
        if (e.code != AgentFailureCode.staleContext &&
            e.code != AgentFailureCode.maintenance) {
          _failure = e.code;
        }
      } catch (_) {
        _failure = AgentFailureCode.storageFailed;
      }
      try {
        await data.cancelRun(ticket);
      } on AgentFailure catch (e) {
        if (e.code != AgentFailureCode.staleContext &&
            e.code != AgentFailureCode.maintenance) {
          cancellationFailure = e;
        }
      } catch (e) {
        cancellationFailure = e;
      }
    }
    try {
      try {
        final authority =
            _settings?.authority ?? (await data.inspectAgent()).authority;
        await data.invalidateModelWork(authority);
      } on AgentFailure catch (e) {
        if (e.code != AgentFailureCode.staleContext &&
            e.code != AgentFailureCode.maintenance) {
          rethrow;
        }
      }
      final drainFailure = await drain;
      if (drainFailure != null) throw drainFailure;
      await work;
      final lateTicket = _ticket;
      if (lateTicket != null && !identical(lateTicket, ticket)) {
        try {
          await data.cancelRun(lateTicket);
        } on AgentFailure catch (e) {
          if (e.code != AgentFailureCode.staleContext &&
              e.code != AgentFailureCode.maintenance) {
            rethrow;
          }
        }
      }
      if (cancellationFailure != null) {
        _ticket = ticket;
        throw cancellationFailure;
      }
      _ticket = null;
      final pending = _pendingHistory;
      if (pending != null) {
        await data.completeClearHistory(pending);
        _pendingHistory = null;
        _conversation = null;
        _messages = [];
      }
      if (maintenance) {
        _phase = AgentPhase.maintenance;
      } else {
        try {
          await _refresh();
          _phase = AgentPhase.idle;
        } on AgentFailure catch (e) {
          // A durable application-maintenance intent intentionally withdraws
          // ordinary reads. Network drain succeeded; its runner can proceed.
          if (e.code != AgentFailureCode.maintenance) rethrow;
          _phase = AgentPhase.maintenance;
        }
      }
    } catch (e) {
      _phase = AgentPhase.recovery;
      _failure = _code(e);
      rethrow;
    } finally {
      _wipeCandidate();
      _publish();
    }
  }

  Future<void> deleteKey({required bool confirmed}) async {
    if (!confirmed) {
      _failure = AgentFailureCode.consentRequired;
      _publish();
      return;
    }
    await stop();
    await _action(AgentPhase.settling, (g) async {
      await _refresh();
      await data.deleteModelKey(_settings!.authority);
      _current(g);
    });
  }

  Future<void> setModelConsent(bool consent) async {
    await stop();
    await _action(AgentPhase.settling, (g) async {
      await _refresh();
      await data.setModelConsent(_settings!.authority, consent);
      _current(g);
    });
  }

  Future<void> clearHistory({
    String? conversationId,
    required bool confirmed,
  }) async {
    if (!confirmed) {
      _failure = AgentFailureCode.consentRequired;
      _publish();
      return;
    }
    // Busy UI actions are serialized in this first slice. Clearing an inactive
    // conversation never silently cancels another conversation's active run.
    if (_work != null &&
        conversationId != null &&
        conversationId != _conversation) {
      _failure = AgentFailureCode.busy;
      _publish();
      return;
    }
    final settings = await data.inspectAgent();
    AgentHistoryIntent? intent;
    try {
      intent = await data.beginClearHistory(
        settings.authority,
        conversationId: conversationId,
      );
      _pendingHistory = intent;
      await stop();
      _phase = AgentPhase.settling;
      _publish();
      await data.completeClearHistory(intent);
      _pendingHistory = null;
      if (conversationId == null || conversationId == _conversation) {
        _conversation = null;
        _messages = [];
      }
      _phase = AgentPhase.idle;
      _failure = null;
      await _refresh();
    } catch (e) {
      _failure = _code(e);
      if (intent != null) _phase = AgentPhase.recovery;
    }
    _publish();
  }

  Future<void> quiesceForMaintenance() async {
    await _stop(maintenance: true);
    _phase = AgentPhase.maintenance;
    _wipeCandidate();
    _publish();
  }

  Future<void> refreshAfterMaintenance() async {
    if (_closed) return;
    _phase = AgentPhase.idle;
    _failure = null;
    _models = [];
    _conversation = null;
    await _refresh();
    _report = _settings!.report;
    _publish();
  }

  Future<void> resumeAfterFailedExit() async {
    if (_closed || _work != null || _phase != AgentPhase.maintenance) return;
    try {
      await _refresh();
      _phase = AgentPhase.idle;
      _failure = null;
    } on AgentFailure catch (e) {
      _failure = e.code;
      if (e.code != AgentFailureCode.maintenance) _phase = AgentPhase.recovery;
    } catch (_) {
      _phase = AgentPhase.recovery;
      _failure = AgentFailureCode.storageFailed;
    }
    _publish();
  }

  Future<void> close() => _closeFuture ??=
      () async {
        await stop();
        await gateway.close();
        _wipeCandidate();
        _phase = AgentPhase.closed;
        _publish();
        _closed = true;
        await _changes.close();
      }().catchError((Object e) {
        _closeFuture = null;
        throw e;
      });

  String safeValidationSummary() => jsonEncode({
    'kind': 'agent-model-validation-v1',
    'phase': _phase.name,
    'keySaved': _settings?.keySaved ?? false,
    'modelSelected': _settings?.modelId != null,
    'modelCount': _models.length,
    'capability': _report.capability.name,
    'checks': {
      'text': _report.text,
      'streaming': _report.streaming,
      'toolCall': _report.toolCall,
      'toolResult': _report.toolResult,
    },
    'failure': (_failure ?? _report.failure)?.name,
    'requests': _requests,
    'conversations': _conversations.length,
    'messages': _messages.length,
    'businessToolsEnabled': false,
  });
}
