import 'package:flutter/material.dart';

import '../../agent/domain/agent_tool.dart';

/// A collapsed row showing tool execution progress during an agent run.
///
/// By default only one collapsed row is visible, showing the count of tools
/// that ran. When the user taps to expand, individual tool steps become
/// visible with their status (success/error).
class AgentToolRunTile extends StatefulWidget {
  const AgentToolRunTile({
    required this.toolSummaries,
    super.key,
  });

  /// The tool summaries from the current run.
  final List<AgentToolSummary> toolSummaries;

  @override
  State<AgentToolRunTile> createState() => _AgentToolRunTileState();
}

class _AgentToolRunTileState extends State<AgentToolRunTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.toolSummaries.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final successCount =
        widget.toolSummaries.where((t) => t.status == AgentToolStatus.success).length;
    final errorCount = widget.toolSummaries.length - successCount;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Collapsed summary row.
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.troubleshoot,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '工具调用 (${widget.toolSummaries.length})',
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (errorCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$errorCount 个错误',
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  const SizedBox(width: 4),
                  if (successCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$successCount 个成功',
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  const Spacer(),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          // Expanded individual tool steps.
          if (_expanded)
            ...widget.toolSummaries.map((summary) => _ToolStepRow(summary: summary)),
        ],
      ),
    );
  }
}

/// A single tool step row shown inside the expanded tool tile.
class _ToolStepRow extends StatelessWidget {
  const _ToolStepRow({required this.summary});

  final AgentToolSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isError = summary.status == AgentToolStatus.error;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            size: 14,
            color: isError
                ? theme.colorScheme.error
                : theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              summary.safeLabel ?? summary.toolName,
              style: TextStyle(
                fontSize: 12,
                color: isError
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}