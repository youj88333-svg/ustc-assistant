import 'agent_contract.dart';
import 'agent_action_contract.dart';
import 'agent_source_contract.dart';

enum AgentAuthorizationMode { confirmed, remembered }

enum AgentPermissionCategory {
  createPersonal('创建个人日程'),
  updatePersonal('修改个人日程'),
  statePersonal('完成或跳过个人日程'),
  deletePersonal('删除个人日程'),
  createTask('创建任务'),
  updateTask('修改任务'),
  stateTask('修改任务状态'),
  deleteTask('删除任务'),
  createBlock('安排任务时间块'),
  updateBlock('移动或修改时间块'),
  stateBlock('修改时间块状态'),
  deleteBlock('删除时间块'),
  attendance('修改本地出勤计划'),
  listening('修改本地听讲计划'),
  note('修改本地日程备注'),
  visibility('隐藏或恢复学校日程'),
  saveRelation('设置日程冲突关系'),
  deleteRelation('删除日程冲突关系'),
  undo('撤销最近本地修改'),
  preferences('保存时间规划偏好'),
  refreshJw('同步教务'),
  refreshYoung('同步二课日程');

  const AgentPermissionCategory(this.label);
  final String label;
  String get tool => switch (this) {
    undo => 'propose_undo',
    preferences => 'propose_planning_preferences',
    refreshJw || refreshYoung => 'request_source_refresh',
    _ => 'propose_local_changes',
  };
}

/// Display reference only. C3 requires the issued identity when revoking.
final class AgentPermissionReference {
  const AgentPermissionReference(this.category, this.revision);
  final AgentPermissionCategory category;
  final int revision;
  @override
  String toString() => 'AgentPermissionReference';
}

abstract interface class AgentPermissionManagementPort {
  Future<List<AgentPermissionReference>> readActionPermissions();
  Future<void> revokeActionPermission(AgentPermissionReference reference);
}

abstract interface class AgentLocalPermissionPort {
  /// Null only means that this exact proposal lacks all required permissions.
  Future<AgentPlanApproval?> authorizeLocalPlan(
    AgentLocalPlan plan, {
    required AgentAuthorizationMode mode,
    bool remember = false,
  });
}

abstract interface class AgentRecordPermissionPort {
  Future<AgentActionView> prepareSourceAction(
    AgentRunTicket ticket,
    AgentSourceRequest request,
    String title,
    List<String> details,
  );

  /// False only means that the fixed operation lacks a remembered permission.
  Future<bool> authorizeAction(
    AgentRunTicket ticket,
    AgentActionView action, {
    required AgentAuthorizationMode mode,
    bool remember = false,
  });
}
