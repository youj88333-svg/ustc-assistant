import 'package:flutter/material.dart';

import '../../agent/domain/agent_models.dart';
import '../../agent/domain/agent_tool.dart';

/// A collapsed row showing tool execution progress during an agent run.
///
/// By default only one collapsed row is visible, showing the count of tools
/// that ran. When the user taps to expand, individual tool steps become
/// visible with their lifecycle state (running/waiting/success/error/
/// cancelled/interrupted). Safe details (the deterministic safe argument and
/// result summaries) are shown ONLY inside the expanded step rows.
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
    final lifecycleCounts = _lifecycleCounts(widget.toolSummaries);
    final successCount =
        lifecycleCounts[ToolInvocationLifecycleState.success]!;
    final errorCount = lifecycleCounts[ToolInvocationLifecycleState.error]!;
    final waitingCount =
        lifecycleCounts[ToolInvocationLifecycleState.waitingUser]!;
    final runningCount = lifecycleCounts[ToolInvocationLifecycleState.running]!;
    final blockedCount =
        lifecycleCounts[ToolInvocationLifecycleState.cancelled]! +
            lifecycleCounts[ToolInvocationLifecycleState.interrupted]!;

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
                  if (runningCount > 0)
                    _CountBadge(
                      label: '$runningCount 进行中',
                      background: theme.colorScheme.surfaceContainerHighest,
                      foreground: theme.colorScheme.onSurfaceVariant,
                    ),
                  if (waitingCount > 0)
                    _CountBadge(
                      label: '$waitingCount 等待确认',
                      background: theme.colorScheme.tertiaryContainer,
                      foreground: theme.colorScheme.onTertiaryContainer,
                    ),
                  if (errorCount > 0)
                    _CountBadge(
                      label: '$errorCount 个错误',
                      background: theme.colorScheme.errorContainer,
                      foreground: theme.colorScheme.onErrorContainer,
                    ),
                  if (blockedCount > 0)
                    _CountBadge(
                      label: '$blockedCount 已停止',
                      background: theme.colorScheme.surfaceContainerHighest,
                      foreground: theme.colorScheme.onSurfaceVariant,
                    ),
                  if (successCount > 0)
                    _CountBadge(
                      label: '$successCount 个成功',
                      background: theme.colorScheme.secondaryContainer,
                      foreground: theme.colorScheme.onSecondaryContainer,
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
            ...widget.toolSummaries.map(
              (summary) => _ToolStepRow(summary: summary),
            ),
        ],
      ),
    );
  }

  static Map<ToolInvocationLifecycleState, int> _lifecycleCounts(
    List<AgentToolSummary> summaries,
  ) {
    final counts = {
      for (final state in ToolInvocationLifecycleState.values) state: 0,
    };
    for (final s in summaries) {
      counts[s.lifecycleState] = counts[s.lifecycleState]! + 1;
    }
    return counts;
  }
}

/// A small colored count badge (e.g. `2 个错误`) in the collapsed tile row.
class _CountBadge extends StatelessWidget {
  const _CountBadge({
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 11, color: foreground),
        ),
      ),
    );
  }
}

/// A single tool step row shown inside the expanded tool tile.
///
/// The row always shows the tool name and a lifecycle marker. Safe details
/// (safe error code, safe argument/result summaries, timing) are only shown
/// here — never in the collapsed tile.
class _ToolStepRow extends StatelessWidget {
  const _ToolStepRow({required this.summary});

  final AgentToolSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color) = _marker(theme);
    final details = <String>[
      if (summary.errorCode != null && summary.errorCode!.isNotEmpty)
        '错误码: ${summary.errorCode}',
      if (summary.startedAt != null && summary.finishedAt != null)
        '耗时${_formatDuration(summary.finishedAt! - summary.startedAt!)}',
      if (summary.safeArgumentsSummary != null &&
          summary.safeArgumentsSummary!.isNotEmpty)
        '参数: ${summary.safeArgumentsSummary}',
      if (summary.safeResultSummary != null &&
          summary.safeResultSummary!.isNotEmpty)
        '结果: ${summary.safeResultSummary}',
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  summary.toolName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: color,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(
                  _stateSuffix(),
                  style: TextStyle(fontSize: 11, color: color),
                ),
              ),
              if (summary.isLive)
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
          if (details.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 22, top: 2),
              child: Text(
                details.join('\n'),
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// A short Chinese state suffix rendered next to the tool name.
  String _stateSuffix() {
    switch (summary.lifecycleState) {
      case ToolInvocationLifecycleState.running:
        return '执行中';
      case ToolInvocationLifecycleState.waitingUser:
        return '等待确认';
      case ToolInvocationLifecycleState.cancelled:
        return '已取消';
      case ToolInvocationLifecycleState.interrupted:
        return '已中断';
      case ToolInvocationLifecycleState.success:
        return '成功';
      case ToolInvocationLifecycleState.error:
        return '失败';
    }
  }

  (IconData, Color) _marker(ThemeData theme) {
    switch (summary.lifecycleState) {
      case ToolInvocationLifecycleState.running:
      case ToolInvocationLifecycleState.waitingUser:
        return (Icons.hourglass_top, theme.colorScheme.primary);
      case ToolInvocationLifecycleState.cancelled:
      case ToolInvocationLifecycleState.interrupted:
        return (Icons.remove_circle_outline, theme.colorScheme.outline);
      case ToolInvocationLifecycleState.error:
        return (Icons.error_outline, theme.colorScheme.error);
      case ToolInvocationLifecycleState.success:
        return (Icons.check_circle_outline, theme.colorScheme.primary);
    }
  }

  static String _formatDuration(int millis) {
    final seconds = (millis / 1000).floor();
    if (seconds < 1) return '${millis}ms';
    if (seconds < 60) return '${seconds}s';
    return '${(seconds / 60).floor()}m';
  }
}