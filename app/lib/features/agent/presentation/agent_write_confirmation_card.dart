import 'package:flutter/material.dart';

import '../domain/agent_permission_policy.dart';
import '../domain/agent_write_proposal.dart';

/// 聊天内联写确认卡：预览写操作 + 风险徽标 + 确认/取消/此类型以后不再确认/去权限设置。
class AgentWriteConfirmationCard extends StatelessWidget {
  const AgentWriteConfirmationCard({
    super.key,
    required this.proposal,
    required this.onApprove,
    required this.onReject,
    required this.onRemember,
    required this.onGoToSettings,
  });

  final AgentWriteProposalView proposal;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onRemember;
  final VoidCallback onGoToSettings;

  static ({String label, Color color}) _riskStyle(RiskLevel risk) => switch (risk) {
    RiskLevel.low => (label: '低', color: Colors.green),
    RiskLevel.medium => (label: '中', color: Colors.amber),
    RiskLevel.high => (label: '高', color: Colors.deepOrange),
    RiskLevel.critical => (label: '关键', color: Colors.red),
  };

  @override
  Widget build(BuildContext context) {
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
              FilledButton(onPressed: onApprove, child: const Text('确认本次')),
              OutlinedButton(onPressed: onReject, child: const Text('取消')),
              if (proposal.rememberAllowed)
                TextButton(onPressed: onRemember, child: const Text('此类型以后不再确认')),
              TextButton(onPressed: onGoToSettings, child: const Text('去权限设置')),
            ]),
          ],
        ),
      ),
    );
  }
}
