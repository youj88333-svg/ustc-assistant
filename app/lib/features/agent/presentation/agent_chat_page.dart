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
    super.key,
  });

  final String accountId;
  final AgentConfigurationService config;
  final AgentSecretStore secrets;
  final LlmProvider provider;
  final AgentSessionService sessionService;
  final DriftChatRepository chatRepository;
  final OfficialWebsiteLauncher websiteLauncher;

  @override
  State<AgentChatPage> createState() => _AgentChatPageState();
}

sealed class _ChatMessage {
  const _ChatMessage();
}

class _UserMessage extends _ChatMessage {
  const _UserMessage({required this.text, required this.runId, required this.ordinal});
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
  });
  final String text;
  final String? runId;
  final int ordinal;
  final List<AgentToolSummary> toolSummaries;
  final List<AgentSourceReference> sourceReferences;
  final AgentRunState state;
  final String? errorCode;
}

class _AgentChatPageState extends State<AgentChatPage> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();

  List<_ChatMessage> _messages = [];
  bool _isRunning = false;
  StreamSubscription<AgentRunViewState>? _streamSubscription;
  bool _nearBottom = true;
  String? _lastRunId;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadHistory();
  }

  @override
  void dispose() {
    _streamSubscription?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
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
          messages.add(_UserMessage(
            text: record.content,
            runId: record.runId,
            ordinal: record.ordinal,
          ));
        } else if (record.role == ChatRole.assistant) {
          final isStreaming = record.state == ChatMessageState.streaming;
          messages.add(_AssistantMessage(
            text: record.content,
            runId: record.runId,
            ordinal: record.ordinal,
            state: isStreaming ? AgentRunState.running : AgentRunState.completed,
          ));
        }
      }
      if (mounted) {
        setState(() => _messages = messages);
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
    if (mounted) {
      setState(() {
        final lastMsg = _messages.isNotEmpty ? _messages.last : null;
        if (lastMsg is _AssistantMessage && lastMsg.runId == state.runId) {
          _messages[_messages.length - 1] = _AssistantMessage(
            text: state.text,
            runId: state.runId,
            ordinal: lastMsg.ordinal,
            toolSummaries: state.toolSummaries,
            sourceReferences: state.sourceReferences,
            state: state.state,
            errorCode: state.errorCode,
          );
        } else {
          _messages = [
            ..._messages,
            _AssistantMessage(
              text: state.text,
              runId: state.runId,
              ordinal: 0,
              toolSummaries: state.toolSummaries,
              sourceReferences: state.sourceReferences,
              state: state.state,
              errorCode: state.errorCode,
            ),
          ];
        }
      });
    }
  }

  void _onStreamDone() {
    if (mounted) {
      setState(() {
        _isRunning = false;
        _streamSubscription = null;
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
      });
    }
  }

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
    setState(() => _isRunning = true);

    _streamSubscription = widget.sessionService
        .resumeUserAction(
          accountId: widget.accountId,
          runId: runId,
        )
        .listen(_onViewState, onDone: _onStreamDone, onError: _onStreamError);
  }

  Future<void> _copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已复制到剪贴板'), duration: Duration(seconds: 2)),
      );
    }
  }

  AgentRunViewState? _terminalState() {
    if (_messages.isEmpty) return null;
    final last = _messages.last;
    if (last is _AssistantMessage) {
      if (last.state == AgentRunState.failed ||
          last.state == AgentRunState.cancelled ||
          last.state == AgentRunState.interrupted) {
        return AgentRunViewState(
          runId: last.runId ?? '',
          state: last.state,
          text: last.text,
          toolSummaries: last.toolSummaries,
          sourceReferences: last.sourceReferences,
          errorCode: last.errorCode,
        );
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 600;

    return FutureBuilder<bool>(
      future: AgentSettingsPage.isConfigured(
        accountId: widget.accountId,
        config: widget.config,
        secrets: widget.secrets,
      ),
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
          Icon(Icons.chat_bubble_outline, size: 64,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(height: 16),
          Text(
            'Agent 未配置',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            '请先配置学校模型服务以使用聊天功能。',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          AgentSetupPanel(
            accountId: widget.accountId,
            config: widget.config,
            secrets: widget.secrets,
            provider: widget.provider,
            onConfigured: () => setState(() {}),
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
        if (!_nearBottom && _isRunning)
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
    final terminal = _terminalState();
    final needsLogin = terminal?.errorCode == 'needs_user_login';

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
            borderRadius: BorderRadius.circular(18).copyWith(
              bottomRight: const Radius.circular(4),
            ),
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
    final isTerminal = msg.state == AgentRunState.completed;
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
                child: Icon(Icons.smart_toy_outlined,
                    size: 14, color: theme.colorScheme.onSecondaryContainer),
              ),
              const SizedBox(width: 8),
              Text(
                'Agent',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (_isRunning && !isTerminal) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
              if (isError) ...[
                const SizedBox(width: 8),
                Icon(Icons.error_outline, size: 14, color: theme.colorScheme.error),
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
        if (isTerminal && msg.text.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.copy, size: 16),
            tooltip: '复制回答',
            onPressed: () => _copyText(msg.text),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        if (isError || msg.state == AgentRunState.cancelled || msg.state == AgentRunState.interrupted)
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
              Icon(Icons.login, color: Theme.of(context).colorScheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '需要登录校园账号以继续',
                  style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
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