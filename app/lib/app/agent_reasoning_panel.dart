import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/agent_contract.dart';

/// Provider-supplied, transient text. This view does not execute links or parse
/// tool calls, and never substitutes thinking for the assistant's final answer.
final class AgentReasoningPanel extends StatefulWidget {
  const AgentReasoningPanel({
    super.key,
    required this.messageId,
    required this.reasoning,
  });
  final int messageId;
  final AgentReasoningView reasoning;

  @override
  State<AgentReasoningPanel> createState() => _AgentReasoningPanelState();
}

final class _AgentReasoningPanelState extends State<AgentReasoningPanel> {
  late bool _expanded = widget.reasoning.active;
  bool _chosen = false;

  @override
  void didUpdateWidget(AgentReasoningPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.messageId != widget.messageId) {
      _chosen = false;
      _expanded = widget.reasoning.active;
    } else if (!_chosen) {
      _expanded = widget.reasoning.active;
    }
  }

  @override
  Widget build(BuildContext context) {
    final reasoning = widget.reasoning;
    final maxHeight = math.max(
      64.0,
      math.min(144.0, MediaQuery.sizeOf(context).height * .2),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextButton.icon(
          key: ValueKey('agent-reasoning-toggle-${widget.messageId}'),
          style: TextButton.styleFrom(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 2),
          ),
          onPressed: () => setState(() {
            _chosen = true;
            _expanded = !_expanded;
          }),
          icon: reasoning.active
              ? const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                )
              : Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                ),
          label: Text(reasoning.active ? '正在思考' : '思考过程'),
        ),
        if (_expanded)
          Container(
            key: ValueKey('agent-reasoning-content-${widget.messageId}'),
            constraints: BoxConstraints(maxHeight: maxHeight),
            padding: const EdgeInsets.fromLTRB(10, 4, 8, 8),
            decoration: const BoxDecoration(
              border: Border(
                left: BorderSide(color: Color(0xFFC4D5C9), width: 2),
              ),
            ),
            child: SingleChildScrollView(
              key: ValueKey('agent-reasoning-scroll-${widget.messageId}'),
              reverse: reasoning.active,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SelectableText(
                    reasoning.text,
                    style: const TextStyle(
                      color: Color(0xFF66736C),
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                  if (reasoning.truncated)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        '内容较长，已截取前一部分。',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
