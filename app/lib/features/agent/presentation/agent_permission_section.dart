import 'package:flutter/material.dart';

import '../../../core/database/app_database.dart';
import '../application/agent_permission_policy_service.dart';
import '../domain/agent_permission_policy.dart';

/// 设置页「Agent 权限」分区：列出策略项、切换确认模式、恢复默认、查看最近变更。
class AgentPermissionSection extends StatefulWidget {
  const AgentPermissionSection({
    super.key,
    required this.accountId,
    required this.policyService,
  });

  final String accountId;
  final AgentPermissionPolicyService policyService;

  @override
  State<AgentPermissionSection> createState() => _AgentPermissionSectionState();
}

/// 设置页展示的策略项（含中文标签）。
const kAgentPermissionRows = <(String actionType, String targetType, String label)>[
  ('create_event', 'event', '新建日程'),
  ('update_event', 'event', '修改/删除日程'),
  ('create_task', 'task', '新建任务'),
  ('plan_task', 'plan_block', '安排任务时间段'),
  ('create_user_overlay', 'overlay', '设置个人标注'),
  ('record_attendance_decision', 'event', '记录出勤决定'),
  ('record_listening_mode', 'event', '设置听讲模式'),
  ('create_schedule_relation', 'relation', '记录日程关系'),
  ('set_reminder', 'event', '设置提醒'),
  ('update_permission_policy', 'permission', '调整确认策略'),
];

String _modeLabel(ConfirmationMode mode) => switch (mode) {
  ConfirmationMode.alwaysAsk => '每次都问',
  ConfirmationMode.askFirstTime => '首次确认后放行',
  ConfirmationMode.alwaysAllow => '总是允许',
  ConfirmationMode.alwaysDeny => '总是禁止',
};

class _AgentPermissionSectionState extends State<AgentPermissionSection> {
  Map<String, ConfirmationMode> _modes = {};
  List<ActionLog> _recent = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await widget.policyService.listPolicies(widget.accountId);
    final byKey = {
      for (final r in rows) '${r.actionType}:${r.targetType}': r.confirmationMode,
    };
    final recent = await widget.policyService.recentPermissionChanges(widget.accountId);
    if (!mounted) return;
    setState(() {
      _modes = byKey;
      _recent = recent;
      _loading = false;
    });
  }

  Future<void> _setMode(String actionType, String targetType, ConfirmationMode mode) async {
    await widget.policyService.updatePolicy(
      accountId: widget.accountId,
      actionType: actionType,
      targetType: targetType,
      mode: mode,
      riskLevel: AgentPermissionPolicyService.defaultRisk(actionType),
      enabled: true,
      updatedBy: 'user',
    );
    await _load();
  }

  Future<void> _restoreDefaults() async {
    await widget.policyService.resetDefaults(widget.accountId);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 16, left: 16, right: 16),
          child: Row(children: [
            Text('Agent 权限', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            TextButton(onPressed: _restoreDefaults, child: const Text('恢复默认')),
          ]),
        ),
        for (final (actionType, targetType, label) in kAgentPermissionRows)
          ListTile(
            key: Key('perm-$actionType'),
            title: Text(label),
            subtitle: Text(_modeLabel(_modes['$actionType:$targetType'] ??
                AgentPermissionPolicyService.defaultMode(actionType))),
            trailing: actionType == 'update_permission_policy'
                ? const Text('始终人工确认')
                : DropdownButton<ConfirmationMode>(
                    value: _modes['$actionType:$targetType'] ??
                        AgentPermissionPolicyService.defaultMode(actionType),
                    items: ConfirmationMode.values
                        .map((mode) => DropdownMenuItem(
                            value: mode, child: Text(_modeLabel(mode))))
                        .toList(),
                    onChanged: (mode) {
                      if (mode != null) _setMode(actionType, targetType, mode);
                    },
                  ),
          ),
        if (_recent.isNotEmpty) ...[
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('最近权限变更', style: Theme.of(context).textTheme.titleSmall),
          ),
          for (final log in _recent)
            ListTile(
              dense: true,
              title: Text(log.safeSummary, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${DateTime.fromMillisecondsSinceEpoch(log.occurredAt).toLocal()}'),
            ),
        ],
      ],
    );
  }
}
