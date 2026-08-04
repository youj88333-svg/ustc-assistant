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

/// 设置页展示的策略项（actionType, targetType, label），全部消费
/// [AgentPermissionPolicyService.kPolicyTargetMap] 的单一映射与注册表
/// [AgentPermissionPolicyService.labelFor]，不在设置页独立维护一份 label 清单。
final kAgentPermissionRows = <(String actionType, String targetType, String label)>[
  for (final actionType in AgentPermissionPolicyService.kPolicyTargetMap.keys)
    (
      actionType,
      AgentPermissionPolicyService.targetTypeFor(actionType),
      AgentPermissionPolicyService.labelFor(actionType),
    ),
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

  /// Restores a SINGLE policy override to its lazy default (the Agent
  /// `reset_permission_policy` tool resets one item at a time; this is the
  /// manual UI equivalent). Critical actions in [kNonResetableActions] never
  /// get this control — the row stays locked to its default.
  Future<void> _restoreSingle(String actionType, String targetType) async {
    await widget.policyService.resetPolicy(
      accountId: widget.accountId,
      actionType: actionType,
      targetType: targetType,
    );
    await _load();
  }

  /// Whether a row carries a custom override (a stored policy row), distinct
  /// from the lazy default.
  bool _isOverridden(String actionType, String targetType) =>
      _modes.containsKey('$actionType:$targetType');

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return SingleChildScrollView(
      child: Column(
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
              title: Row(
                children: [
                  Flexible(child: Text(label)),
                  if (_isOverridden(actionType, targetType)) ...[
                    const SizedBox(width: 6),
                    // Marks this row as carrying a custom override (a stored
                    // policy row distinct from the lazy default). Kept as a
                    // keyed widget so tests can assert its presence without
                    // matching translatable text.
                    Icon(
                      key: Key('perm-override-$actionType'),
                      Icons.tune,
                      size: 14,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ],
                ],
              ),
              subtitle: Text(_modeLabel(_modes['$actionType:$targetType'] ??
                  AgentPermissionPolicyService.defaultMode(actionType))),
              trailing: _rowTrailing(actionType, targetType),
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
      ),
    );
  }

  /// Builds the trailing control for a policy row.
  ///
  /// Critical actions (`update_permission_policy`, `reset_permission_policy`,
  /// `move_jw_course_day` — [kNonResetableActions]) stay locked to their
  /// default with a plain "始终人工确认" label: no dropdown to relax them, and
  /// no per-item restore (the reset tool itself rejects them). Configurable
  /// actions get a dropdown; when a custom override exists, a per-item
  /// restore-to-default icon is appended next to the dropdown so the user can
  /// revert just that one row without touching the others.
  Widget _rowTrailing(String actionType, String targetType) {
    if (actionType == 'update_permission_policy' ||
        kNonResetableActions.contains(actionType)) {
      return const Text('始终人工确认');
    }
    final dropdown = DropdownButton<ConfirmationMode>(
      value: _modes['$actionType:$targetType'] ??
          AgentPermissionPolicyService.defaultMode(actionType),
      items: ConfirmationMode.values
          .map((mode) =>
              DropdownMenuItem(value: mode, child: Text(_modeLabel(mode))))
          .toList(),
      onChanged: (mode) {
        if (mode != null) _setMode(actionType, targetType, mode);
      },
    );
    if (!_isOverridden(actionType, targetType)) return dropdown;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: Key('perm-restore-$actionType'),
          tooltip: '恢复此项默认',
          icon: const Icon(Icons.restore, size: 18),
          onPressed: () => _restoreSingle(actionType, targetType),
        ),
        dropdown,
      ],
    );
  }
}
