import 'package:flutter/material.dart';

import '../domain/agent_permission_policy.dart';
import '../domain/agent_write_proposal.dart';

/// 聊天内联写确认卡：预览写操作 + 风险徽标 + 确认/取消/此类型以后不再确认/去权限设置。
///
/// 提交动作是异步且受 [_submitting] 守卫的：提交进行中四个动作全部禁用，
/// 防止用户重复点击造成多次调用。失败时只展示通用提示，绝不暴露内部异常文本。
class AgentWriteConfirmationCard extends StatefulWidget {
  const AgentWriteConfirmationCard({
    super.key,
    required this.proposal,
    required this.onApprove,
    required this.onReject,
    required this.onRemember,
    required this.onGoToSettings,
  });

  final AgentWriteProposalView proposal;
  final Future<void> Function() onApprove;
  final Future<void> Function() onReject;
  final Future<void> Function() onRemember;
  final Future<void> Function() onGoToSettings;

  @override
  State<AgentWriteConfirmationCard> createState() =>
      _AgentWriteConfirmationCardState();
}

class _AgentWriteConfirmationCardState extends State<AgentWriteConfirmationCard> {
  bool _submitting = false;
  String? _error;

  Future<void> _submit(Future<void> Function() action) async {
    if (_submitting) return;
    setState(() { _submitting = true; _error = null; });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _error = '操作未完成，请重试。');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  static ({String label, Color color}) _riskStyle(RiskLevel risk) => switch (risk) {
    RiskLevel.low => (label: '低', color: Colors.green),
    RiskLevel.medium => (label: '中', color: Colors.amber),
    RiskLevel.high => (label: '高', color: Colors.deepOrange),
    RiskLevel.critical => (label: '关键', color: Colors.red),
  };

  @override
  Widget build(BuildContext context) {
    final proposal = widget.proposal;
    final risk = _riskStyle(proposal.riskLevel);
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(proposal.operationLabel,
                    style: theme.textTheme.titleSmall),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: risk.color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('风险：${risk.label}',
                    style: TextStyle(color: risk.color, fontSize: 12)),
              ),
            ]),
            const SizedBox(height: 8),
            for (final line in proposal.previewLines)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(line, style: theme.textTheme.bodyMedium),
              ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 4, children: [
              FilledButton(
                onPressed: _submitting ? null : () => _submit(widget.onApprove),
                child: const Text('确认本次'),
              ),
              OutlinedButton(
                onPressed: _submitting ? null : () => _submit(widget.onReject),
                child: const Text('取消'),
              ),
              if (proposal.rememberAllowed)
                TextButton(
                  onPressed: _submitting ? null : () => _submit(widget.onRemember),
                  child: const Text('此类型以后不再确认'),
                ),
              TextButton(
                onPressed: _submitting ? null : () => _submit(widget.onGoToSettings),
                child: const Text('去权限设置'),
              ),
            ]),
            if (_submitting)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text('处理中', style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
