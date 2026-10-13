import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import 'agent_workspace_contract.dart';
import '../core/agent_contract.dart';

const _agentGreen = Color(0xFF1F6B45);
const _agentMuted = Color(0xFF66736C);
const _agentLine = Color(0xFFE3E9E5);

/// The M5.1 chat surface. The workspace port is owned by its caller.
final class AgentWorkspacePage extends StatefulWidget {
  const AgentWorkspacePage({
    super.key,
    required this.controller,
    required this.onSettings,
  });

  final AgentWorkspacePort controller;
  final VoidCallback onSettings;

  @override
  State<AgentWorkspacePage> createState() => _AgentWorkspacePageState();
}

final class _AgentWorkspacePageState extends State<AgentWorkspacePage> {
  final TextEditingController _draft = TextEditingController();
  final FocusNode _composerFocus = FocusNode();
  int _generation = 0;
  bool _pending = false;
  bool _sending = false;
  bool _stopping = false;
  bool _showSessions = false;
  bool _messageIsError = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _scheduleRefresh();
  }

  @override
  void didUpdateWidget(covariant AgentWorkspacePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _generation++;
      _pending = false;
      _sending = false;
      _stopping = false;
      _messageIsError = false;
      _message = null;
      _draft.clear();
      _scheduleRefresh();
    }
  }

  @override
  void dispose() {
    _generation++;
    _draft.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  bool _isCurrent(AgentWorkspacePort port, int generation) =>
      mounted && identical(widget.controller, port) && _generation == generation;

  void _scheduleRefresh() {
    final port = widget.controller;
    final generation = _generation;
    scheduleMicrotask(() {
      if (_isCurrent(port, generation)) unawaited(_refresh(port, generation));
    });
  }

  Future<void> _refresh(AgentWorkspacePort port, int generation) async {
    try {
      await port.refresh();
    } on Object {
      if (_isCurrent(port, generation)) {
        setState(() {
          _message = '暂时无法读取 Agent 对话，请稍后重试。';
          _messageIsError = true;
        });
      }
    }
  }

  Future<void> _perform(
    Future<void> Function(AgentWorkspacePort port) action, {
    required String success,
  }) async {
    final port = widget.controller;
    final generation = _generation;
    if (!_isCurrent(port, generation) ||
        _pending ||
        port.view.busy ||
        port.view.phase == AgentPhase.closed) {
      return;
    }
    setState(() {
      _pending = true;
      _message = null;
      _messageIsError = false;
    });
    try {
      await action(port);
      if (_isCurrent(port, generation)) {
        final failure = port.view.failure;
        setState(() {
          _message = failure == null ? success : _failureText(failure);
          _messageIsError = failure != null;
        });
      }
    } on Object {
      if (_isCurrent(port, generation)) {
        setState(() {
          _message = '操作暂未完成，请稍后重试。';
          _messageIsError = true;
        });
      }
    } finally {
      if (_isCurrent(port, generation)) setState(() => _pending = false);
    }
  }

  Future<void> _newConversation() async {
    await _perform(
      (port) => port.newConversation(),
      success: '已创建新对话。',
    );
    if (mounted) setState(() => _showSessions = false);
  }

  Future<void> _selectConversation(String id) async {
    await _perform(
      (port) => port.selectConversation(id),
      success: '已切换对话。',
    );
    if (mounted) setState(() => _showSessions = false);
  }

  Future<void> _send() async {
    final view = widget.controller.view;
    final text = _draft.text;
    final conversationId = view.conversationId;
    if (!view.canSend ||
        conversationId == null ||
        text.trim().isEmpty ||
        _sending) {
      return;
    }
    final port = widget.controller;
    final generation = _generation;
    setState(() {
      _sending = true;
      _message = null;
      _messageIsError = false;
    });
    try {
      await port.send(text);
      if (_isCurrent(port, generation)) {
        final failure = port.view.failure;
        if (failure != null) {
          setState(() {
            _message = _failureText(failure);
            _messageIsError = true;
          });
        } else if (_draft.text == text) {
          _draft.clear();
        }
      }
    } on Object {
      if (_isCurrent(port, generation)) {
        setState(() {
          _message = '消息未能发送，请稍后重试。';
          _messageIsError = true;
        });
      }
    } finally {
      if (_isCurrent(port, generation)) setState(() => _sending = false);
    }
  }

  Future<void> _stop() async {
    final port = widget.controller;
    final generation = _generation;
    if (!_isCurrent(port, generation) || _stopping) return;
    setState(() {
      _stopping = true;
      _message = null;
      _messageIsError = false;
    });
    try {
      await port.stop();
    } on Object {
      if (_isCurrent(port, generation)) {
        setState(() {
          _message = '暂时无法停止本次生成，请稍后重试。';
          _messageIsError = true;
        });
      }
    } finally {
      if (_isCurrent(port, generation)) setState(() => _stopping = false);
    }
  }

  Future<void> _clearHistory({String? conversationId}) async {
    final port = widget.controller;
    final generation = _generation;
    final all = conversationId == null;
    final first = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(all ? '清除全部 Agent 对话？' : '清除当前对话？'),
        content: Text(
          all
              ? '这会删除本机保存的全部 Agent 对话历史。学校账号密码、业务数据和模型 Key 会保留。'
              : '这会删除当前 Agent 对话历史。学校账号密码、业务数据和模型 Key 会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('agent-history-clear-first-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (first != true) return;
    if (!mounted) return;
    if (!_isCurrent(port, generation)) return;
    final second = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('再确认一次'),
        content: const Text('对话历史清除后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('返回'),
          ),
          FilledButton(
            key: const ValueKey('agent-history-clear-final-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认清除'),
          ),
        ],
      ),
    );
    if (second != true) return;
    if (!mounted) return;
    if (!_isCurrent(port, generation)) return;
    await _perform(
      (currentPort) => currentPort.clearHistory(
        conversationId: conversationId,
        confirmed: true,
      ),
      success: all ? '已清除全部 Agent 对话历史。' : '已清除当前 Agent 对话历史。',
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 760;
        final view = widget.controller.view;
        final current = view.conversations.where(
          (item) => item.id == view.conversationId,
        );
        final title = current.isEmpty ? null : current.first.title;
        final status = _statusLabel(view.phase);
        final titleWidth = (constraints.maxWidth - (narrow ? 112 : 260))
            .clamp(120.0, 520.0);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (narrow)
                      IconButton(
                        key: const ValueKey('agent-sessions-toggle'),
                        tooltip: _showSessions ? '返回对话' : '查看对话列表',
                        onPressed: () =>
                            setState(() => _showSessions = !_showSessions),
                        icon: Icon(
                          _showSessions ? Icons.chat_bubble_outline : Icons.menu_rounded,
                        ),
                      ),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: titleWidth),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title == null || title.isEmpty ? 'Agent' : title,
                            key: const ValueKey('agent-page-title'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const Text(
                            '你的校园事务助手',
                            style: TextStyle(color: _agentMuted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    if (status != null)
                      Chip(
                        key: const ValueKey('agent-phase'),
                        avatar: const Icon(Icons.more_horiz_rounded, size: 18),
                        label: Text(status),
                      ),
                    const Chip(
                      key: ValueKey('agent-capability-chat-only'),
                      avatar: Icon(Icons.chat_outlined, size: 18),
                      label: Text('仅聊天 · 工具未接入'),
                    ),
                    IconButton(
                      key: const ValueKey('agent-settings-open'),
                      tooltip: 'Agent 设置',
                      onPressed: widget.onSettings,
                      icon: const Icon(Icons.settings_outlined),
                    ),
                    PopupMenuButton<_HistoryCommand>(
                      key: const ValueKey('agent-history-menu'),
                      tooltip: '对话记录',
                      enabled: !_pending &&
                          !view.busy &&
                          view.phase != AgentPhase.closed,
                      onSelected: (command) {
                        switch (command) {
                          case _HistoryCommand.current:
                            if (view.conversationId != null) {
                              unawaited(
                                _clearHistory(
                                  conversationId: view.conversationId,
                                ),
                              );
                            }
                          case _HistoryCommand.all:
                            unawaited(_clearHistory());
                        }
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: _HistoryCommand.current,
                          enabled: view.conversationId != null,
                          child: const Text('清除当前对话…'),
                        ),
                        const PopupMenuItem(
                          value: _HistoryCommand.all,
                          child: Text('清除全部对话…'),
                        ),
                      ],
                      icon: const Icon(Icons.delete_sweep_outlined),
                    ),
                  ],
                ),
              ],
            ),
            if (_message != null || view.failure != null) ...[
              const SizedBox(height: 8),
              _AgentNotice(
                message: _message ?? _failureText(view.failure!),
                isError: _messageIsError || (_message == null && view.failure != null),
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!narrow) ...[
                    SizedBox(
                      width: 250,
                      child: _sessionList(view),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: narrow && _showSessions
                        ? _sessionList(view)
                        : _conversation(view),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );

  Widget _sessionList(AgentWorkspaceView view) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            key: const ValueKey('agent-new-conversation'),
            onPressed: _pending || view.busy || view.phase == AgentPhase.closed
                ? null
                : _newConversation,
            icon: const Icon(Icons.add_rounded),
            label: const Text('新建对话'),
          ),
          const SizedBox(height: 10),
          const Text('对话', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Expanded(
            child: view.conversations.isEmpty
                ? const Center(
                    child: Text(
                      '还没有对话',
                      style: TextStyle(color: _agentMuted),
                    ),
                  )
                : ListView.builder(
                    key: const ValueKey('agent-conversation-list'),
                    itemCount: view.conversations.length,
                    itemBuilder: (context, index) {
                      final item = view.conversations[index];
                      final selected = item.id == view.conversationId;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Material(
                          color: selected
                              ? const Color(0xFFE7F1EA)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          child: ListTile(
                            key: ValueKey('agent-conversation-$index'),
                            dense: true,
                            selected: selected,
                            title: Text(
                              item.title.isEmpty ? '新对话' : item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: _pending ||
                                    view.busy ||
                                    view.phase == AgentPhase.closed
                                ? null
                                : () => _selectConversation(item.id),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );

  Widget _conversation(AgentWorkspaceView view) {
    final configured = view.settings?.keySaved == true &&
        view.settings?.consent == true &&
        view.settings?.modelId != null &&
        view.settings?.report.capability != ModelCapability.unverified;
    final canSend = view.canSend &&
        view.conversationId != null &&
        _draft.text.trim().isNotEmpty &&
        !_sending;
    final canStop = view.phase == AgentPhase.generating ||
        view.phase == AgentPhase.settling;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Card(
            child: view.conversationId == null
                ? _emptyConversation(configured)
                : _messages(view),
          ),
        ),
        const SizedBox(height: 10),
        if (!configured)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _SetupPrompt(onSettings: widget.onSettings),
          ),
        _composer(
          enabled: canSend,
          canStop: canStop,
          busy: view.busy,
        ),
      ],
    );
  }

  Widget _emptyConversation(bool configured) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.forum_outlined, size: 42, color: _agentGreen),
            const SizedBox(height: 12),
            Text(
              configured ? '开始一段新的对话' : '先完成模型设置',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              configured
                  ? '新建对话后，你可以向学校模型服务提问。'
                  : '目前尚未配置可用模型。完成设置后即可开始对话。',
              style: const TextStyle(color: _agentMuted, height: 1.45),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              key: const ValueKey('agent-empty-new-conversation'),
              onPressed: _pending ||
                      widget.controller.view.busy ||
                      widget.controller.view.phase == AgentPhase.closed
                  ? null
                  : _newConversation,
              icon: const Icon(Icons.add_rounded),
              label: const Text('新建对话'),
            ),
            if (!configured) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: widget.onSettings,
                icon: const Icon(Icons.settings_outlined),
                label: const Text('打开 Agent 设置'),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _messages(AgentWorkspaceView view) => Column(
    children: [
      if (view.historyTruncated)
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '当前只展示最近一部分对话内容。',
              style: TextStyle(color: _agentMuted, fontSize: 12),
            ),
          ),
        ),
      Expanded(
        child: view.messages.isEmpty
            ? const Center(
                child: Text('发送一条消息，开始对话。', style: TextStyle(color: _agentMuted)),
              )
            : ListView.builder(
                key: const ValueKey('agent-message-list'),
                padding: const EdgeInsets.all(16),
                itemCount: view.messages.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _MessageBubble(message: view.messages[index]),
                ),
              ),
      ),
    ],
  );

  Widget _composer({
    required bool enabled,
    required bool canStop,
    required bool busy,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Focus(
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.enter &&
                      !HardwareKeyboard.instance.isShiftPressed) {
                    if (enabled) {
                      unawaited(_send());
                      return KeyEventResult.handled;
                    }
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  key: const ValueKey('agent-composer'),
                  controller: _draft,
                  focusNode: _composerFocus,
                  enabled: !busy && !_pending,
                  minLines: 1,
                  maxLines: 4,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.send,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) {
                    if (enabled) unawaited(_send());
                  },
                  decoration: const InputDecoration(
                    hintText: '输入消息…（Enter 发送，Shift+Enter 换行）',
                    border: InputBorder.none,
                    filled: false,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
            ),
            if (canStop)
              IconButton.filledTonal(
                key: const ValueKey('agent-stop'),
                tooltip: '停止生成',
                onPressed: _stopping ? null : _stop,
                icon: _stopping
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.stop_rounded),
              )
            else
              IconButton.filled(
                key: const ValueKey('agent-send'),
                tooltip: '发送消息',
                onPressed: enabled ? _send : null,
                icon: _sending
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_upward_rounded),
              ),
          ],
        ),
      ),
    );
  }
}

enum _HistoryCommand { current, all }

final class _SetupPrompt extends StatelessWidget {
  const _SetupPrompt({required this.onSettings});

  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('agent-model-setup-prompt'),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF5E8),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFF0E0C7)),
    ),
    child: Row(
      children: [
        const Icon(Icons.info_outline_rounded, color: Color(0xFF8A5A14)),
        const SizedBox(width: 10),
        const Expanded(child: Text('配置学校模型并完成发送说明确认后，才能发送消息。')),
        TextButton(onPressed: onSettings, child: const Text('去设置')),
      ],
    ),
  );
}

final class _AgentNotice extends StatelessWidget {
  const _AgentNotice({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('agent-page-notice'),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: isError ? const Color(0xFFFFF0F0) : const Color(0xFFEAF3ED),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(message, style: const TextStyle(height: 1.4)),
  );
}

final class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final AgentMessage message;

  @override
  Widget build(BuildContext context) {
    final user = message.role == AgentMessageRole.user;
    final text = _boundedMarkdown(message.text);
    final status = _messageStatus(message.status);
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Container(
          key: ValueKey('agent-message-${message.id}'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: user ? const Color(0xFFE7F1EA) : const Color(0xFFF5F7F6),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _agentLine),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    user ? '你' : 'Agent',
                    style: const TextStyle(
                      color: _agentMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (status != null) ...[
                    const SizedBox(width: 8),
                    _MessageStatus(label: status, failed: message.status == AgentMessageStatus.failed),
                  ],
                ],
              ),
              if (text.isNotEmpty) ...[
                const SizedBox(height: 5),
                MarkdownBody(
                  data: text,
                  softLineBreak: true,
                  fitContent: true,
                  builders: {'a': _PlainAnchorBuilder()},
                  imageBuilder: (uri, title, alt) => Text(
                    alt == null || alt.isEmpty ? '（图片已隐藏）' : '（图片已隐藏：$alt）',
                    style: const TextStyle(color: _agentMuted),
                  ),
                ),
              ] else if (message.status != AgentMessageStatus.complete) ...[
                const SizedBox(height: 4),
                const Text('没有可显示的回复内容。', style: TextStyle(color: _agentMuted)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

final class _PlainAnchorBuilder extends MarkdownElementBuilder {
  _PlainAnchorBuilder();

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => Text(element.textContent, style: parentStyle);
}

final class _MessageStatus extends StatelessWidget {
  const _MessageStatus({required this.label, required this.failed});

  final String label;
  final bool failed;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: failed ? const Color(0xFFFBEAEA) : const Color(0xFFE9EDEA),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: failed ? const Color(0xFF9B2C2C) : _agentMuted,
        fontSize: 11,
      ),
    ),
  );
}

String _boundedMarkdown(String input) {
  const maxLength = 12000;
  final bounded = input.length <= maxLength
      ? input
      : '${input.substring(0, maxLength)}\n\n…内容过长，已截断显示';
  // Raw HTML is displayed as ordinary text. Markdown links stay visible but
  // are rendered by _PlainAnchorBuilder without tap handlers; images are
  // replaced with an inert label in imageBuilder.
  return bounded.replaceAll('<', r'\<');
}

String? _messageStatus(AgentMessageStatus status) => switch (status) {
  AgentMessageStatus.streaming => '生成中',
  AgentMessageStatus.complete => null,
  AgentMessageStatus.interrupted => '部分回复 · 已中断',
  AgentMessageStatus.cancelled => '已取消',
  AgentMessageStatus.failed => '回复失败',
};

String? _statusLabel(AgentPhase phase) => switch (phase) {
  AgentPhase.idle => null,
  AgentPhase.loadingModels => '正在获取模型',
  AgentPhase.verifying => '正在验证模型',
  AgentPhase.generating => '正在生成回复',
  AgentPhase.settling => '正在保存回复',
  AgentPhase.recovery => '正在恢复状态',
  AgentPhase.maintenance => '本地维护中',
  AgentPhase.closed => '服务已关闭',
};

String _failureText(AgentFailureCode code) => switch (code) {
  AgentFailureCode.invalidInput => '输入不符合要求，请检查后重试。',
  AgentFailureCode.secretDetected => '输入包含受保护内容，请移除后重试。',
  AgentFailureCode.consentRequired => '请先在设置中阅读说明并明确勾选同意。',
  AgentFailureCode.keyRequired => '请先在设置中配置模型 Key。',
  AgentFailureCode.modelRequired => '请先在设置中获取并选择有效模型。',
  AgentFailureCode.busy => 'Agent 正在处理其他操作，请稍后重试。',
  AgentFailureCode.staleContext => '对话状态已变化，请刷新后重试。',
  AgentFailureCode.maintenance => '本地维护正在进行，请稍后重试。',
  AgentFailureCode.ownershipLost => '本机数据状态已变化，请重新打开 Agent。',
  AgentFailureCode.storageFailed => '本机对话暂时无法保存，请稍后重试。',
  AgentFailureCode.protectionFailed => '本机密钥保护未完成，操作没有保存。',
  AgentFailureCode.unauthorized || AgentFailureCode.forbidden =>
    '模型服务未授权此请求，请检查设置。',
  AgentFailureCode.rateLimited => '模型服务暂时繁忙，请稍后重试。',
  AgentFailureCode.networkFailed || AgentFailureCode.timeout =>
    '暂时无法连接模型服务，请检查网络后重试。',
  AgentFailureCode.protocol || AgentFailureCode.redirectRejected =>
    '模型服务返回内容无法安全验证。',
  AgentFailureCode.resourceLimit => '回复超出当前处理上限。',
  AgentFailureCode.cancelled => '本次生成已取消。',
  AgentFailureCode.closed => 'Agent 服务已关闭，请重新打开页面。',
  AgentFailureCode.toolUnavailable => '当前版本尚未启用 Agent 工具。',
};
