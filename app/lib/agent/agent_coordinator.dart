import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../core/agent_contract.dart';
import '../core/agent_action_contract.dart';
import '../core/agent_discussion_contract.dart';
import '../core/agent_evidence.dart';
import '../core/agent_text.dart';
import '../core/contracts.dart';
import 'agent_tool_contract.dart';
import 'agent_context.dart';
import 'agent_request_intent.dart';
import 'agent_system_prompt.dart';
import 'model_gateway_contract.dart';

/// Only active work consumes this budget; waiting for a human never does.
final class _AgentRunBudget {
  _AgentRunBudget(this.limit, this.onExpired) {
    resume();
  }
  final Duration limit;
  final void Function() onExpired;
  final Stopwatch _elapsed = Stopwatch();
  final Stopwatch _waiting = Stopwatch();
  Timer? _timer;
  bool _disposed = false;
  bool get expired => _elapsed.elapsed >= limit;
  int get activeMilliseconds => _elapsed.elapsedMilliseconds;
  int get waitingMilliseconds => _waiting.elapsedMilliseconds;
  void pause() {
    if (_elapsed.isRunning) _waiting.start();
    _elapsed.stop();
    _timer?.cancel();
    _timer = null;
  }

  void resume() {
    if (_disposed || _elapsed.isRunning) return;
    final remaining = limit - _elapsed.elapsed;
    if (remaining <= Duration.zero) {
      onExpired();
      return;
    }
    _elapsed.start();
    _waiting.stop();
    _timer = Timer(remaining, onExpired);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _elapsed.stop();
    _waiting.stop();
  }
}

/// C4 owns one bounded model run. Read tools use their own C2 instance and
/// never manufacture approval, source credentials or business writes.
final class AgentCoordinator {
  AgentCoordinator({
    required this.data,
    required this.gateway,
    this.readTools,
    this.clock = const SystemClock(),
    this.runTimeout = const Duration(seconds: 180),
  });
  final AgentDataPort data;
  final ModelGatewayPort gateway;
  final AgentReadToolsPort? readTools;
  final AppClock clock;
  final Duration runTimeout;
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
  int _toolCalls = 0, _modelCalls = 0, _imageRequests = 0;
  int _lastActiveMs = 0,
      _lastWaitingMs = 0,
      _inputTokens = 0,
      _outputTokens = 0;
  bool _usageComplete = false;
  String? _activeTool;
  AgentToolSession? _toolSession;
  List<AgentToolStep> _steps = [];
  bool _budgetExpired = false;
  bool _closingDependencies = false;
  AgentDiscussionSelection? _discussionSelection;
  String? _discussionId, _discussionDraft;
  bool _historyExhausted = false;
  String? _loadedConversation;
  Completer<bool>? _approvalDecision;
  StreamSubscription<void>? _interactiveSubscription;
  _AgentRunBudget? _runBudget;
  AgentInteractiveToolSession? get _interactive =>
      _toolSession is AgentInteractiveToolSession
      ? _toolSession as AgentInteractiveToolSession
      : null;

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
      historyTruncated: !_historyExhausted && _messages.length >= 100,
      businessToolsEnabled:
          readTools != null && _report.capability == ModelCapability.toolReady,
      activeTool: _activeTool,
      toolCalls: _toolCalls,
      modelCalls: _modelCalls,
      pendingAction: _interactive?.pendingAction,
      discussionId: _discussionId,
      discussionDraft: _discussionDraft,
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
    final recent = _conversation == null
        ? <AgentMessage>[]
        : await data.messages(_conversation!);
    if (_loadedConversation == _conversation &&
        _messages.isNotEmpty &&
        recent.isNotEmpty) {
      _messages = [
        ..._messages.where((m) => m.id < recent.first.id),
        ...recent,
      ];
    } else {
      _messages = List<AgentMessage>.of(recent);
      _historyExhausted = recent.length < 100;
      _loadedConversation = _conversation;
    }
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
    if (_closed || _closingDependencies || _closeFuture != null) {
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
    _budgetExpired = false;
    _stopping = false;
    _failure = null;
    _phase = phase;
    final done = Completer<void>();
    _work = done.future;
    _publish();
    try {
      await body(generation);
    } catch (e) {
      _failure = _budgetExpired
          ? AgentFailureCode.resourceLimit
          : _stopping
          ? AgentFailureCode.cancelled
          : _code(e);
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
        _discussionSelection = null;
        _discussionId = null;
        _discussionDraft = null;
      });
  Future<void> loadOlderMessages() => _action(AgentPhase.settling, (g) async {
    final port = data, conversation = _conversation;
    if (port is! AgentHistoryPagePort ||
        conversation == null ||
        _messages.isEmpty ||
        _historyExhausted) {
      return;
    }
    final older = await (port as AgentHistoryPagePort).messagesBefore(
      conversation,
      _messages.first.id,
    );
    _current(g);
    if (_conversation != conversation) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    _messages = [...older, ..._messages];
    _historyExhausted = older.length < 100;
  });
  Future<void> prepareDiscussion(AgentDiscussionSelection selection) =>
      _action(AgentPhase.settling, (g) async {
        final session = readTools?.openSession();
        try {
          if (session is! AgentDiscussionToolSession) {
            throw const AgentFailure(AgentFailureCode.toolUnavailable);
          }
          await (session as AgentDiscussionToolSession).selectForDiscussion(
            selection,
          );
          _current(g);
          _conversation = await data.createConversation();
          _current(g);
          _discussionSelection = selection;
          _discussionId = List.generate(
            16,
            (_) =>
                Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
          ).join();
          _discussionDraft = selection.event != null
              ? '请帮我讨论选中的日程。'
              : '请帮我讨论选中的任务及时间规划。';
        } finally {
          session?.revoke();
        }
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
                  evidence: _toolSession?.evidence ?? message.evidence,
                  steps: List.unmodifiable(_steps),
                  imageCount: message.imageCount,
                  actions: message.actions,
                ),
        )
        .toList();
    _publish();
  }

  Future<void> _validateRun(AgentRunTicket ticket, int g) async {
    _current(g);
    if (_budgetExpired) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }
    final journal = data;
    if (journal is AgentRunJournalPort) {
      await (journal as AgentRunJournalPort).ensureAgentRun(ticket);
    } else if ((await data.inspectAgent()).authority != ticket.authority) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    _current(g);
    await _toolSession?.validateDelivery();
    _current(g);
  }

  Future<void> _journal(AgentRunTicket ticket, int g, int imageCount) async {
    _current(g);
    final journal = data;
    if (journal is AgentRunJournalPort) {
      await (journal as AgentRunJournalPort).saveRunJournal(
        ticket,
        evidence: _toolSession?.evidence ?? [],
        steps: List.unmodifiable(_steps),
        imageCount: imageCount,
      );
    } else if (_steps.isNotEmpty || imageCount != 0) {
      throw const AgentFailure(AgentFailureCode.storageFailed);
    }
    _current(g);
  }

  static int _contextBytes(
    List<ModelChatMessage> messages,
    List<ModelToolDefinition> tools,
  ) {
    var bytes = 0;
    for (final tool in tools) {
      bytes += utf8
          .encode(tool.name + tool.description + jsonEncode(tool.parameters))
          .length;
    }
    for (final message in messages) {
      AgentText.requireSafe(message.content ?? '');
      bytes += utf8.encode(message.content ?? '').length;
      for (final call in message.toolCalls) {
        AgentText.requireSafe(call.argumentsJson, maxCharacters: 16384);
        bytes += utf8.encode(call.name + call.id + call.argumentsJson).length;
      }
    }
    return bytes;
  }

  static String _canonicalCall(ModelToolCall call) {
    Object? canonical(Object? value) => switch (value) {
      Map() => {
        for (final key in value.keys.cast<String>().toList()..sort())
          key: canonical(value[key]),
      },
      List() => value.map(canonical).toList(),
      _ => value,
    };
    try {
      return '${call.name}:${jsonEncode(canonical(jsonDecode(call.argumentsJson)))}';
    } catch (_) {
      return '${call.name}:${call.argumentsJson}';
    }
  }

  static bool _restrictLocal(String question) => RegExp(
    r'(?:不要|别|无需|不用|禁止)(?:查询|读取|查看|访问|查|读|看)(?:我的|本地|个人)?(?:日程|课表|安排|任务)|(?:只|仅)(?:查询|使用|查|用)?(?:公开资料|公开信息|知识库|评课)|only\s+public|do not (?:read|access) my (?:agenda|tasks|calendar)',
    caseSensitive: false,
  ).hasMatch(question);

  List<ModelToolDefinition> _questionTools(
    String question,
    List<AgentMessage> history,
  ) {
    final groups = <String>{};
    void include(String value) {
      final text = value.toLowerCase();
      final dated = RegExp(
        r'今天|明天|昨天|后天|现在|上午|下午|晚上|本周|这周|下周|周[一二三四五六日天]|[0-9]{4}-[0-9]{2}-[0-9]{2}|tomorrow|today|week|afternoon|morning',
      ).hasMatch(text);
      final classQuery = RegExp(r'课|课程|节|class|lecture|exam').hasMatch(text);
      final privateClassQuery =
          classQuery &&
          (dated ||
              RegExp(
                r'我的|我.*课|几点|第一节|教室|教学楼|where|when|my|i have',
              ).hasMatch(text));
      if (RegExp(
            r'日程|课表|安排|冲突|空闲|上课|考试|几节|agenda|schedule|calendar|conflict',
          ).hasMatch(text) ||
          privateClassQuery ||
          (RegExp(r'今天|明天|本周|下周|tomorrow|today|week').hasMatch(text) &&
              RegExp(r'有什么|干什么|有课|忙|available|doing').hasMatch(text))) {
        groups.addAll({'query_agenda', 'read_event', 'inspect_conflicts'});
      }
      if (RegExp(r'任务|截止|作业|复习|task|deadline|homework').hasMatch(text)) {
        groups.addAll({
          'query_tasks',
          'read_task',
          'query_agenda',
          'read_event',
          'inspect_conflicts',
        });
      }
      if (RegExp(r'教师|老师|评课|选课|评价|点评|icourse|teacher|review').hasMatch(text) ||
          !privateClassQuery && RegExp(r'课程|course').hasMatch(text)) {
        groups.addAll({'search_courses', 'read_course', 'read_reviews'});
      }
      if (RegExp(
        r'教务|财务|报销|缓考|证明|学籍|学费|缴费|通知|办事|规定|政策|毕业|奖学金|指南|知识|材料|办理|流程|校园|学校|选课|退课|成绩单|转专业|休学|复学|补考|campus|knowledge|finance|policy|notice',
      ).hasMatch(text)) {
        groups.addAll({
          'search_knowledge',
          'read_knowledge',
          'browse_campus',
          'read_campus_article',
        });
      }
    }

    void includeLocalIntent(String value) {
      final intent = agentLocalRequestIntent(value);
      if (intent.changes || intent.planning) {
        groups.addAll({
          'query_agenda',
          'read_event',
          'query_tasks',
          'read_task',
          'inspect_conflicts',
        });
      }
      if (intent.changes) groups.add('propose_local_changes');
      if (intent.planning) groups.add('find_free_slots');
    }

    include(question);
    includeLocalIntent(question);
    final lower = question.toLowerCase();
    if (RegExp(r'撤销|undo').hasMatch(lower)) {
      groups.add('propose_undo');
    }
    if (RegExp(
      r'规划偏好|以后.*(?:安排|时段|休息)|记住.*(?:时段|休息)|planning preference',
    ).hasMatch(lower)) {
      groups.add('propose_planning_preferences');
    }
    if (RegExp(r'同步|刷新|采集|更新.*(?:课表|考试|二课)|refresh|sync').hasMatch(lower)) {
      groups.addAll({
        'query_source_options',
        'request_source_refresh',
        'query_agenda',
        'read_event',
        'query_young_activities',
      });
    } else if (RegExp(r'二课.*(?:活动|报名)|(?:活动|报名).*二课|青春科大').hasMatch(lower)) {
      groups.add('query_young_activities');
    }
    // A short follow-up can inherit the human's preceding topic, never a tool
    // result's instruction or model-generated argument/URL.
    if (agentLocalClarification(question) ||
        RegExp(
          r'继续|详细|上面|上一|这个|这门|其中|还有|那个|怎么办|more|continue',
        ).hasMatch(question.toLowerCase())) {
      final previous = history
          .where(
            (m) =>
                m.role == AgentMessageRole.user &&
                m.status == AgentMessageStatus.complete,
          )
          .lastOrNull;
      if (previous != null) {
        include(previous.text);
        if (agentLocalClarification(question)) {
          includeLocalIntent(previous.text);
        }
      }
    }
    if (agentLocalRequestIntent(question).writesRestricted) {
      groups.removeAll({
        'propose_local_changes',
        'propose_undo',
        'propose_planning_preferences',
        'request_source_refresh',
      });
    }
    if (_restrictLocal(question)) {
      groups.removeAll({
        'query_agenda',
        'read_event',
        'inspect_conflicts',
        'query_tasks',
        'read_task',
        'propose_local_changes',
        'propose_undo',
        'find_free_slots',
        'request_source_refresh',
        'propose_planning_preferences',
      });
    }
    return readTools!.definitions
        .where((tool) => groups.contains(tool.name))
        .toList();
  }

  Future<void> send(
    String text, {
    List<AgentImage> images = const [],
  }) => _action(AgentPhase.generating, (g) async {
    _wipeCandidate();
    _budgetExpired = false;
    _modelCalls = 0;
    _toolCalls = 0;
    _inputTokens = 0;
    _outputTokens = 0;
    _usageComplete = true;
    _steps = [];
    _activeTool = null;
    final suppliedImages = List<AgentImage>.of(images);
    for (final image in suppliedImages) {
      image.validate();
    }
    if (suppliedImages.length > AgentImage.maximumCount ||
        suppliedImages.fold<int>(0, (sum, image) => sum + image.bytes.length) >
            AgentImage.maximumTotalBytes) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }
    if (text.trim().isEmpty && suppliedImages.isNotEmpty) {
      text = '请根据本次附图回答。';
    }
    AgentText.requireSafe(text, maxCharacters: 6000);
    if (text.trim().isEmpty) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
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
    final context = buildAgentConversationContext(
      history,
      maxPairs: 6,
      maximumCharacters: 8000,
    );
    final ticket = await data.beginRun(
      settings.authority,
      _conversation!,
      text,
    );
    _ticket = ticket;
    final discussionSelection = _restrictLocal(text)
        ? null
        : _discussionSelection;
    _discussionSelection = null;
    _discussionId = null;
    _discussionDraft = null;
    _liveText = '';
    var savedLength = 0;
    var lastSave = clock.nowUtc;
    final attachments = <AgentImage>[];
    final day = clock.nowUtc
        .add(const Duration(hours: 8))
        .toIso8601String()
        .substring(0, 10);
    final receivedAt =
        '${clock.nowUtc.add(const Duration(hours: 8)).toIso8601String().replaceFirst(RegExp(r'Z$'), '')}+08:00';
    final budget = _AgentRunBudget(runTimeout, () {
      _budgetExpired = true;
      unawaited(
        stop().catchError((Object e) {
          _phase = AgentPhase.recovery;
          _failure = _code(e);
          _publish();
        }),
      );
    });
    _runBudget = budget;
    try {
      for (final image in suppliedImages) {
        attachments.add(AgentImage(image.bytes));
      }
      _toolSession = settings.report.capability == ModelCapability.toolReady
          ? readTools?.openSession()
          : null;
      _interactive?.bindRun(ticket, text);
      String? selectedContext;
      if (discussionSelection != null) {
        final selector = _toolSession;
        if (selector is! AgentDiscussionToolSession) {
          throw const AgentFailure(AgentFailureCode.toolUnavailable);
        }
        selectedContext = await (selector as AgentDiscussionToolSession)
            .selectForDiscussion(discussionSelection);
      }
      _interactiveSubscription = _interactive?.interactiveChanges.listen((_) {
        if (_stopping || g != _generation) return;
        if (_interactive?.waitingForSchool == true) {
          budget.pause();
          _phase = AgentPhase.waitingForSchool;
        } else if (_phase == AgentPhase.waitingForSchool) {
          budget.resume();
          _phase = AgentPhase.committing;
        }
        _publish();
      });
      final definitions = _toolSession == null
          ? <ModelToolDefinition>[]
          : _questionTools(text, history);
      if (discussionSelection != null && readTools != null) {
        final names = definitions.map((d) => d.name).toSet();
        final required = discussionSelection.event != null
            ? const {'query_agenda', 'read_event', 'inspect_conflicts'}
            : const {'query_tasks', 'read_task'};
        definitions.addAll(
          readTools!.definitions.where(
            (d) => required.contains(d.name) && !names.contains(d.name),
          ),
        );
      }
      await _refresh();
      _current(g);
      await _journal(ticket, g, attachments.length);
      final messages = <ModelChatMessage>[
        ModelChatMessage(
          role: 'system',
          content: buildAgentSystemPrompt(
            day: day,
            receivedAt: receivedAt,
            definitions: definitions,
          ),
        ),
        ...context,
        ModelChatMessage(
          role: 'user',
          content: selectedContext == null
              ? text
              : '$text\n[应用选择] $selectedContext',
          images: attachments,
        ),
      ];
      // If a complete historical pair does not fit, remove that pair before
      // the first request. Current rules/question and tool pairs are retained.
      while (_contextBytes(messages, definitions) > 26000 &&
          messages.length > 2) {
        if (messages.length > 3 &&
            messages[1].role == 'user' &&
            messages[2].role == 'assistant') {
          messages.removeRange(1, 3);
        } else {
          messages.removeAt(1);
        }
      }
      final seen = <String>{};
      final callIds = <String>{};
      var invalidCalls = 0;
      var finalStatus = AgentMessageStatus.interrupted;
      while (true) {
        if (_modelCalls >= 8 ||
            budget.expired ||
            _contextBytes(messages, definitions) > 26000) {
          throw const AgentFailure(AgentFailureCode.resourceLimit);
        }
        await _validateRun(ticket, g);
        final request = ModelRequest(
          modelId: settings.modelId!,
          messages: messages,
          tools: definitions,
        );
        final secret = await _secret(ticket.authority, g);
        ModelCompleted? completed;
        var roundText = '';
        final textBeforeRound = _liveText;
        try {
          // A permission or revision change while the key is handed off still
          // blocks the next request. Nothing registers before this guard.
          await _validateRun(ticket, g);
          _requests++;
          _modelCalls++;
          if (attachments.isNotEmpty) _imageRequests++;
          _phase = AgentPhase.generating;
          _activeTool = null;
          _publish();
          await for (final event in gateway.generate(request, secret)) {
            await _validateRun(ticket, g);
            switch (event) {
              case ModelTextDelta():
                final candidate = '$_liveText${event.text}';
                AgentText.requireSafe(candidate);
                _liveText = candidate;
                roundText += event.text;
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
                if (event.inputTokens == null || event.outputTokens == null) {
                  _usageComplete = false;
                } else {
                  if (event.inputTokens! < 0 || event.outputTokens! < 0) {
                    throw const AgentFailure(AgentFailureCode.protocol);
                  }
                  _inputTokens += event.inputTokens!;
                  _outputTokens += event.outputTokens!;
                }
            }
          }
        } finally {
          secret.revoke();
        }
        await _validateRun(ticket, g);
        if (completed == null) {
          throw const AgentFailure(AgentFailureCode.protocol);
        }
        if (completed.toolCalls.isNotEmpty && roundText.isNotEmpty) {
          // A completed native tool round's transition text belongs to the
          // provider protocol. It is not the user's final answer or history.
          _liveText = textBeforeRound;
          await data.saveAssistant(ticket, _liveText);
          _current(g);
          savedLength = _liveText.length;
          lastSave = clock.nowUtc;
          _showLive(_liveText);
        }
        if (completed.toolCalls.isEmpty) {
          if (_liveText.trim().isEmpty) {
            throw const AgentFailure(AgentFailureCode.protocol);
          }
          finalStatus = completed.finishReason == 'stop'
              ? AgentMessageStatus.complete
              : AgentMessageStatus.interrupted;
          break;
        }
        if (completed.finishReason != 'tool_calls' || _toolSession == null) {
          throw const AgentFailure(AgentFailureCode.toolUnavailable);
        }
        if (_toolCalls + completed.toolCalls.length > 16 ||
            completed.toolCalls.any(
              (call) =>
                  !agentRegisteredToolNames.contains(call.name) ||
                  !definitions.any(
                    (definition) => definition.name == call.name,
                  ),
            )) {
          throw const AgentFailure(AgentFailureCode.toolUnavailable);
        }
        if (completed.toolCalls.length != 1 &&
            completed.toolCalls.any(
              (call) => const {
                'propose_local_changes',
                'propose_undo',
                'propose_planning_preferences',
                'request_source_refresh',
                'query_young_activities',
              }.contains(call.name),
            )) {
          throw const AgentFailure(AgentFailureCode.toolUnavailable);
        }
        messages.add(
          ModelChatMessage(
            role: 'assistant',
            content: roundText.isEmpty ? null : roundText,
            toolCalls: completed.toolCalls,
          ),
        );
        for (final call in completed.toolCalls) {
          await _validateRun(ticket, g);
          AgentText.requireSafe(call.argumentsJson, maxCharacters: 16384);
          if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(call.id) ||
              !callIds.add(call.id)) {
            throw const AgentFailure(AgentFailureCode.protocol);
          }
          if (!seen.add(_canonicalCall(call))) {
            throw const AgentFailure(AgentFailureCode.resourceLimit);
          }
          _toolCalls++;
          _phase = AgentPhase.executingRead;
          _activeTool = call.name;
          _publish();
          var result = await _toolSession!.execute(call);
          if (result.status == 'waitingForApproval') {
            final interactive = _interactive;
            if (interactive == null || interactive.pendingAction == null) {
              throw const AgentFailure(AgentFailureCode.protocol);
            }
            budget.pause();
            final decision = Completer<bool>();
            _approvalDecision = decision;
            _phase = AgentPhase.waitingForApproval;
            await _refresh();
            _current(g);
            _publish();
            final approved = await decision.future;
            _approvalDecision = null;
            _current(g);
            budget.resume();
            await _validateRun(ticket, g);
            _phase = AgentPhase.committing;
            _publish();
            result = await interactive.decidePending(approved);
            await _refresh();
            _current(g);
          }
          await _validateRun(ticket, g);
          final ids = result.evidenceIds.toSet();
          final resultMap = result.toMap();
          resultMap['evidence_metadata'] = [
            for (final evidence in _toolSession!.evidence.where(
              (e) => ids.contains(e.id),
            ))
              {
                'id': evidence.id,
                'provider': evidence.provider,
                'title': evidence.title,
                'publishedOn': evidence.publishedOn,
                'updatedOn': evidence.updatedOn,
                'observedAtUtc': evidence.observedAtUtc.toIso8601String(),
                'revision': evidence.revision,
                'sourceVersion': evidence.sourceVersion,
                'locator': evidence.locator,
                'scope': evidence.scope,
                'complete': evidence.complete,
                'applicability': evidence.applicability,
              },
          ];
          final encoded = jsonEncode(resultMap);
          AgentText.requireSafe(encoded);
          if (utf8.encode(encoded).length > 10000) {
            throw const AgentFailure(AgentFailureCode.resourceLimit);
          }
          _steps.add(AgentToolStep(tool: call.name, status: result.status));
          // Persist safe steps/evidence before any further external action.
          await _journal(ticket, g, attachments.length);
          _showLive(_liveText);
          if (const {
            'storageFailed',
            'cleanupPending',
            'cancelled',
            'closed',
            'ownershipLost',
          }.contains(result.failure)) {
            throw AgentFailure(switch (result.failure) {
              'storageFailed' => AgentFailureCode.storageFailed,
              'cancelled' => AgentFailureCode.cancelled,
              'closed' => AgentFailureCode.closed,
              'ownershipLost' => AgentFailureCode.ownershipLost,
              _ => AgentFailureCode.busy,
            });
          }
          messages.add(
            ModelChatMessage(
              role: 'tool',
              content: encoded,
              toolCallId: call.id,
            ),
          );
          if (_interactive?.contextInvalidated == true) {
            final callMessage = messages[messages.length - 2];
            final resultMessage = messages.last;
            // Old tool pairs described the previous business revision. Keep
            // only the current user and the latest checked mutation receipt.
            messages.removeRange(1, messages.length);
            messages.addAll([
              ModelChatMessage(
                role: 'user',
                content: text,
                images: attachments,
              ),
              callMessage,
              resultMessage,
            ]);
            _interactive!.acknowledgeContextInvalidated();
            seen.clear();
          }
          if (result.status == 'invalidRequest' ||
              result.failure == 'invalidRequest') {
            invalidCalls++;
            if (invalidCalls > 1) {
              throw const AgentFailure(AgentFailureCode.toolUnavailable);
            }
          }
        }
      }
      await _journal(ticket, g, attachments.length);
      await data.saveAssistant(ticket, _liveText);
      _current(g);
      await _validateRun(ticket, g);
      await data.finishRun(ticket, finalStatus);
    } catch (e) {
      if (!_stopping) {
        try {
          await data.saveAssistant(ticket, _liveText);
          await data.finishRun(
            ticket,
            _code(e) == AgentFailureCode.cancelled
                ? AgentMessageStatus.cancelled
                : _liveText.isEmpty
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
    } finally {
      budget.dispose();
      _lastActiveMs = budget.activeMilliseconds;
      _lastWaitingMs = budget.waitingMilliseconds;
      _runBudget = null;
      await _interactiveSubscription?.cancel();
      _interactiveSubscription = null;
      final decision = _approvalDecision;
      _approvalDecision = null;
      if (decision != null && !decision.isCompleted) decision.complete(false);
      _toolSession?.revoke();
      try {
        await readTools?.cancelAndDrain();
      } catch (_) {
        _phase = AgentPhase.recovery;
        _failure = AgentFailureCode.busy;
      }
      if (_phase != AgentPhase.recovery) _toolSession = null;
      _activeTool = null;
      for (final image in attachments) {
        image.bytes.fillRange(0, image.bytes.length, 0);
      }
    }
  });

  Future<void> stop() => _stop();

  Future<void> approveAction(String id) => _decideAction(id, true);
  Future<void> rejectAction(String id) => _decideAction(id, false);
  Future<void> _decideAction(String id, bool approved) async {
    final decision = _approvalDecision;
    if (_phase != AgentPhase.waitingForApproval ||
        decision == null ||
        decision.isCompleted ||
        _interactive?.pendingAction?.id != id ||
        _stopping) {
      return;
    }
    _phase = AgentPhase.committing;
    decision.complete(approved);
    _publish();
  }

  Future<void> continueSchool() async {
    if (_phase != AgentPhase.waitingForSchool || _stopping) return;
    await _interactive?.continueSchool();
  }

  Future<AgentPlanningPreferences> readPlanningPreferences() async {
    final port = data;
    if (port is! AgentPreferencesPort) {
      throw const AgentFailure(AgentFailureCode.toolUnavailable);
    }
    return (port as AgentPreferencesPort).readPlanningPreferences();
  }

  Future<void> savePlanningPreferences(AgentPlanningPreferences preferences) =>
      _action(AgentPhase.settling, (g) async {
        final port = data;
        if (port is! AgentPreferencesPort) {
          throw const AgentFailure(AgentFailureCode.toolUnavailable);
        }
        await (port as AgentPreferencesPort).savePlanningPreferences(
          preferences,
        );
        _current(g);
      });

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
    _toolSession?.revoke();
    _runBudget?.dispose();
    final decision = _approvalDecision;
    _approvalDecision = null;
    if (decision != null && !decision.isCompleted) decision.complete(false);
    ++_generation;
    _wipeCandidate();
    _phase = AgentPhase.settling;
    _publish();
    final ticket = _ticket;
    final drain = Future.wait([
      gateway.cancelAndDrain(),
      if (readTools != null) readTools!.cancelAndDrain(),
    ]).then<Object?>((_) => null, onError: (Object error) => error);
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
      _toolSession = null;
      _activeTool = null;
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
      try {
        final settings = await data.inspectAgent();
        final intent = await data.beginClearHistory(
          settings.authority,
          conversationId: conversationId,
        );
        await data.completeClearHistory(intent);
        _conversations = await data.conversations();
      } catch (e) {
        _failure = _code(e);
      }
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
        _discussionSelection = null;
        _discussionDraft = null;
        _discussionId = null;
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
    if (_closed ||
        _closingDependencies ||
        _work != null ||
        _phase != AgentPhase.maintenance) {
      return;
    }
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
        _closingDependencies = true;
        await readTools?.close();
        await gateway.close();
        _wipeCandidate();
        _phase = AgentPhase.closed;
        _publish();
        _closed = true;
        await _changes.close();
      }().catchError((Object e) async {
        _closeFuture = null;
        // A close may have durably cancelled the run before a dependency
        // failed. Refresh that fact without reopening any closed dependency.
        try {
          await _refresh();
        } catch (_) {
          /* A maintenance barrier still governs reads. */
        }
        _phase = AgentPhase.recovery;
        _failure = _code(e);
        _publish();
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
    'businessToolsEnabled':
        readTools != null && _report.capability == ModelCapability.toolReady,
    'toolCalls': _toolCalls,
    'modelCalls': _modelCalls,
    'imageRequests': _imageRequests,
    'vision': 'unverified',
    'registry': agentToolRegistryVersion,
    'promptVersion': agentPromptVersion,
    'lastRun': {
      'activeMs': _lastActiveMs,
      'humanWaitMs': _lastWaitingMs,
      'inputTokens': _usageComplete ? _inputTokens : null,
      'outputTokens': _usageComplete ? _outputTokens : null,
      'cost': 'unknown',
    },
  });
}
