import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../features/settings/presentation/official_websites_page.dart';
import '../../agent/application/agent_configuration_service.dart';
import '../../agent/application/agent_session_service.dart';
import '../../agent/data/drift_chat_repository.dart';
import '../../agent/data/protected_agent_secret_store.dart';
import '../../agent/domain/agent_models.dart';
import '../../agent/domain/agent_tool.dart';
import '../../agent/domain/llm_protocol.dart';
import 'agent_settings_page.dart';
import 'agent_setup_panel.dart';
import 'agent_tool_run_tile.dart';
import 'safe_markdown_message.dart';

/// The main Agent chat page.
///
/// Layout: constrained central column on wide screens (Windows), full-width on
/// narrow (mobile). Renders the persisted conversation history + a streaming
/// assistant draft. Auto-scrolls only when the user is near the bottom; shows
/// a "回到最新" floating action button otherwise.
class AgentChatPage extends StatefulWidget {
  const AgentChatPage({
    required this.accountId,
    required this.config,
    required this.secrets,
    required this.provider,
    required this.sessionService,
    required this.chatRepository,
    required this.websiteLauncher,
    this.sessionModel = AgentConfigurationService.defaultModel,
    this.onSessionModelChanged,
    super.key,
  });

  final String accountId;
  final AgentConfigurationService config;
  final AgentSecretStore secrets;
  final LlmProvider provider;
  final AgentSessionService sessionService;
  final DriftChatRepository chatRepository;
  final OfficialWebsiteLauncher websiteLauncher;
  final String sessionModel;
  final VoidCallback? onSessionModelChanged;

  @override
  State<AgentChatPage> createState() => _AgentChatPageState();
}

sealed class _ChatMessage {
  const _ChatMessage();
}

class _UserMessage extends _ChatMessage {
  const _UserMessage({
    required this.text,
    required this.runId,
    required this.ordinal,
  });
  final String text;
  final String? runId;
  final int ordinal;
}

class _AssistantMessage extends _ChatMessage {
  const _AssistantMessage({
    required this.text,
    required this.runId,
    required this.ordinal,
    this.toolSummaries = const [],
    this.sourceReferences = const [],
    this.state = AgentRunState.completed,
    this.errorCode,
    this.userAction,
    this.hasGeneratedText = true,
  });
  final String text;
  final String? runId;
  final int ordinal;
  final List<AgentToolSummary> toolSummaries;
  final List<AgentSourceReference> sourceReferences;
  final AgentRunState state;
  final String? errorCode;
  final AgentUserActionMetadata? userAction;
  final bool hasGeneratedText;
}

class _AgentChatPageState extends State<AgentChatPage> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();

  List<_ChatMessage> _messages = [];
  bool _isRunning = false;
  StreamSubscription<AgentRunViewState>? _streamSubscription;
  StreamSubscription<AgentSettingsSnapshot>? _settingsSubscription;
  bool _nearBottom = true;
  String? _lastRunId;
  String? _requestedModel;

  /// Resolved ONCE in [initState] and reused by the [build] FutureBuilder.
  ///
  /// This MUST NOT be recomputed in `build`: a fresh future every rebuild
  /// resets the FutureBuilder to `waiting`, which temporarily swaps the
  /// message ListView for a spinner. When the ListView is unmounted and
  /// remounted its ScrollController re-attaches at offset 0 — so any
  /// `setState` that follows (e.g. `_nearBottom` flipping while the user
  /// scrolls up past 200px) yanks the view back to the top. Caching the
  /// future keeps the ListView mounted across rebuilds and preserves the
  /// scroll offset.
  late Future<bool> _configuredFuture;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _configuredFuture = AgentSettingsPage.isConfigured(
      accountId: widget.accountId,
      config: widget.config,
      secrets: widget.secrets,
    );
    _settingsSubscription = widget.config
        .watch(widget.accountId)
        .listen(_onSettingsChanged);
    _loadHistory();
  }

  @override
  void dispose() {
    _streamSubscription?.cancel();
    _settingsSubscription?.cancel();
    unawaited(widget.sessionService.dispose());
    _textController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onSettingsChanged(AgentSettingsSnapshot snapshot) {
    if (snapshot.model != widget.sessionModel &&
        snapshot.model != _requestedModel) {
      _requestedModel = snapshot.model;
      widget.onSessionModelChanged?.call();
    }
    _reloadConfigured();
  }

  void _reloadConfigured() {
    if (!mounted) return;
    setState(() {
      _configuredFuture = AgentSettingsPage.isConfigured(
        accountId: widget.accountId,
        config: widget.config,
        secrets: widget.secrets,
      );
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final extentAfter = _scrollController.position.extentAfter;
    final nearBottom = extentAfter < 200;
    if (nearBottom != _nearBottom) {
      setState(() => _nearBottom = nearBottom);
    }
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  Future<void> _loadHistory() async {
    try {
      final history = await widget.chatRepository.recentMessages(
        widget.accountId,
        limit: 200,
      );
      final messages = <_ChatMessage>[];
      for (final record in history) {
        if (record.role == ChatRole.user) {
          messages.add(
            _UserMessage(
              text: record.content,
              runId: record.runId,
              ordinal: record.ordinal,
            ),
          );
        } else if (record.role == ChatRole.assistant) {
          final state = switch (record.state) {
            ChatMessageState.streaming => AgentRunState.running,
            ChatMessageState.interrupted => AgentRunState.interrupted,
            ChatMessageState.failed => AgentRunState.failed,
            ChatMessageState.cancelled => AgentRunState.cancelled,
            ChatMessageState.completed => AgentRunState.completed,
          };
          messages.add(
            _AssistantMessage(
              text: record.content,
              runId: record.runId,
              ordinal: record.ordinal,
              state: state,
              hasGeneratedText: record.content.isNotEmpty,
            ),
          );
        }
      }
      if (mounted) {
        setState(() => _messages = messages);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scrollController.hasClients) {
            _scrollController.jumpTo(
              _scrollController.position.maxScrollExtent,
            );
          }
        });
      }
    } catch (_) {
      // Silently handle history load failure.
    }
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _isRunning) return;

    _textController.clear();
    final userMsg = _UserMessage(text: text, runId: null, ordinal: 0);

    setState(() {
      _messages = [..._messages, userMsg];
      _isRunning = true;
    });

    _streamSubscription = widget.sessionService
        .send(accountId: widget.accountId, userText: text)
        .listen(_onViewState, onDone: _onStreamDone, onError: _onStreamError);
  }

  void _onViewState(AgentRunViewState state) {
    _lastRunId = state.runId;
    final visibleText = state.text.isEmpty
        ? _emptyTerminalText(state.state)
        : state.text;
    if (mounted) {
      setState(() {
        final lastMsg = _messages.isNotEmpty ? _messages.last : null;
        if (lastMsg is _AssistantMessage && lastMsg.runId == state.runId) {
          _messages[_messages.length - 1] = _AssistantMessage(
            text: visibleText,
            runId: state.runId,
            ordinal: lastMsg.ordinal,
            toolSummaries: state.toolSummaries,
            sourceReferences: state.sourceReferences,
            state: state.state,
            errorCode: state.errorCode,
            userAction: state.userAction,
            hasGeneratedText: state.text.isNotEmpty,
          );
        } else {
          _messages = [
            ..._messages,
            _AssistantMessage(
              text: visibleText,
              runId: state.runId,
              ordinal: 0,
              toolSummaries: state.toolSummaries,
              sourceReferences: state.sourceReferences,
              state: state.state,
              errorCode: state.errorCode,
              userAction: state.userAction,
              hasGeneratedText: state.text.isNotEmpty,
            ),
          ];
        }
      });
      // Follow the streaming text: when the user is already near the bottom,
      // keep the view pinned to the latest delta during the stream (not only
      // at stream completion).
      if (_nearBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    }
  }

  void _onStreamDone() {
    if (mounted) {
      setState(() {
        _isRunning = false;
        _streamSubscription = null;
        _finalizeStuckRunningMessage();
      });
      if (_nearBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    }
  }

  void _onStreamError(Object error) {
    if (mounted) {
      setState(() {
        _isRunning = false;
        _streamSubscription = null;
        // The stream errored without (necessarily) emitting a terminal state.
        // Force the last assistant message to a terminal state so the retry
        // button appears and the bubble shows a terminal marker instead of
        // leaving the user stuck on a "正在思考..." bubble with no recovery.
        // No raw error text is echoed — only a safe desensitized label.
        _finalizeStuckRunningMessage();
      });
    }
  }

  /// Marks the last assistant message as [AgentRunState.interrupted] if it is
  /// still [AgentRunState.running]. This recovers from streams that ended
  /// (done or error) without emitting a terminal state, so the retry button
  /// shows and the bubble no longer claims to be thinking. Safe by design:
  /// already-terminal messages are left untouched, and no raw error text is
  /// surfaced — only the `interrupted` state, which the action row treats as
  /// retryable.
  void _finalizeStuckRunningMessage() {
    if (_messages.isEmpty) return;
    final last = _messages.last;
    if (last is _AssistantMessage && last.state == AgentRunState.running) {
      _messages[_messages.length - 1] = _AssistantMessage(
        text: last.text.isEmpty
            ? _emptyTerminalText(AgentRunState.interrupted)
            : last.text,
        runId: last.runId,
        ordinal: last.ordinal,
        toolSummaries: last.toolSummaries,
        sourceReferences: last.sourceReferences,
        state: AgentRunState.interrupted,
        errorCode: last.errorCode,
        userAction: last.userAction,
        hasGeneratedText: last.hasGeneratedText,
      );
    }
  }

  String _emptyTerminalText(AgentRunState state) => switch (state) {
    AgentRunState.failed => '请求失败，未生成回答。',
    AgentRunState.cancelled => '本次回答已取消。',
    AgentRunState.interrupted => '本次回答意外中断。',
    AgentRunState.completed => '本次回答没有文字内容。',
    AgentRunState.running || AgentRunState.waitingForUser => '',
  };

  Future<void> _cancel() async {
    await widget.sessionService.cancel(accountId: widget.accountId);
    _streamSubscription?.cancel();
    if (mounted) {
      setState(() {
        _isRunning = false;
        _streamSubscription = null;
      });
    }
  }

  Future<void> _retry() async {
    if (_isRunning) return;
    setState(() => _isRunning = true);

    _streamSubscription = widget.sessionService
        .retryLast(accountId: widget.accountId)
        .listen(_onViewState, onDone: _onStreamDone, onError: _onStreamError);
  }

  Future<void> _resumeLogin() async {
    final runId = _lastRunId;
    if (runId == null || runId.isEmpty) return;
    await widget.sessionService
        .resumeUserAction(accountId: widget.accountId, runId: runId)
        .drain<void>();
  }

  Future<void> _copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已复制到剪贴板'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 600;

    return FutureBuilder<bool>(
      future: _configuredFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }

        final configured = snapshot.data ?? false;
        if (!configured) return _buildUnconfigured();

        return _buildChat(isWide);
      },
    );
  }

  Widget _buildUnconfigured() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          const SizedBox(height: 48),
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text('Agent 未配置', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            '请先配置学校模型服务以使用聊天功能。',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          AgentSetupPanel(
            accountId: widget.accountId,
            config: widget.config,
            secrets: widget.secrets,
            provider: widget.provider,
            onConfigured: _reloadConfigured,
          ),
        ],
      ),
    );
  }

  Widget _buildChat(bool isWide) {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: isWide
                  ? const BoxConstraints(maxWidth: 760)
                  : const BoxConstraints(),
              child: _buildMessageList(),
            ),
          ),
        ),
        if (!_nearBottom)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: FloatingActionButton.small(
              heroTag: 'scroll-to-latest',
              onPressed: _scrollToBottom,
              child: const Text('回到最新', style: TextStyle(fontSize: 12)),
            ),
          ),
        _buildInputBar(isWide),
      ],
    );
  }

  Widget _buildMessageList() {
    final last = _messages.isEmpty ? null : _messages.last;
    final needsLogin =
        last is _AssistantMessage &&
        last.state == AgentRunState.waitingForUser &&
        last.userAction?.type == AgentUserActionType.youngLogin;

    if (_messages.isEmpty && !_isRunning) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '有什么可以帮你的？',
            style: TextStyle(
              fontSize: 16,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _messages.length + (needsLogin ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _messages.length && needsLogin) {
          return _buildNeedsLogin();
        }

        final msg = _messages[index];
        if (msg is _UserMessage) return _buildUserBubble(msg);
        if (msg is _AssistantMessage) return _buildAssistantBubble(msg);
        return const SizedBox.shrink();
      },
    );
  }

  Widget _buildUserBubble(_UserMessage msg) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(
              18,
            ).copyWith(bottomRight: const Radius.circular(4)),
          ),
          child: Text(
            msg.text,
            style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
          ),
        ),
      ),
    );
  }

  Widget _buildAssistantBubble(_AssistantMessage msg) {
    final theme = Theme.of(context);
    // A terminal message is one whose run has stopped: completed, failed,
    // cancelled, or interrupted. The copy button renders for ANY terminal
    // state with non-empty text (a failed/interrupted run may have partial
    // text worth copying), not only `completed`. The spinner guard below
    // (`_isRunning && !isTerminal`) is unaffected: a `running` message is
    // still non-terminal, so the spinner still shows while streaming.
    final isTerminal =
        msg.state == AgentRunState.completed ||
        msg.state == AgentRunState.failed ||
        msg.state == AgentRunState.cancelled ||
        msg.state == AgentRunState.interrupted;
    final isError = msg.state == AgentRunState.failed;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: theme.colorScheme.secondaryContainer,
                child: Icon(
                  Icons.smart_toy_outlined,
                  size: 14,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Agent',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (_isRunning && msg.state == AgentRunState.running) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
              if (isError) ...[
                const SizedBox(width: 8),
                Icon(
                  Icons.error_outline,
                  size: 14,
                  color: theme.colorScheme.error,
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Container(
            constraints: const BoxConstraints(maxWidth: 520),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SafeMarkdownMessage(
              text: msg.text.isEmpty ? '正在思考...' : msg.text,
              sourceReferences: msg.sourceReferences,
              launcher: widget.websiteLauncher,
            ),
          ),
          if (msg.toolSummaries.isNotEmpty)
            AgentToolRunTile(toolSummaries: msg.toolSummaries),
          if (_messages.last == msg) ...[
            const SizedBox(height: 4),
            _buildActionRow(isTerminal, isError, msg),
          ],
        ],
      ),
    );
  }

  Widget _buildActionRow(bool isTerminal, bool isError, _AssistantMessage msg) {
    return Row(
      children: [
        if (isTerminal && msg.hasGeneratedText && msg.text.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.copy, size: 16),
            tooltip: '复制回答',
            onPressed: () => _copyText(msg.text),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        if (isError ||
            msg.state == AgentRunState.cancelled ||
            msg.state == AgentRunState.interrupted)
          IconButton(
            icon: const Icon(Icons.refresh, size: 16),
            tooltip: '重新发送',
            onPressed: _retry,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
      ],
    );
  }

  Widget _buildNeedsLogin() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(
                Icons.login,
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '需要登录校园账号以继续',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ),
              TextButton(
                onPressed: _resumeLogin,
                child: const Text('打开登录窗口并继续'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInputBar(bool isWide) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(isWide ? 48 : 12, 8, isWide ? 48 : 12, 12),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('agent-chat-input'),
                    controller: _textController,
                    focusNode: _focusNode,
                    enabled: !_isRunning,
                    decoration: InputDecoration(
                      hintText: '输入消息...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: _isRunning ? null : (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                if (_isRunning)
                  IconButton.filled(
                    icon: const Icon(Icons.stop),
                    tooltip: '停止',
                    onPressed: _cancel,
                  )
                else
                  IconButton.filled(
                    icon: const Icon(Icons.send),
                    tooltip: '发送',
                    onPressed: _send,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
