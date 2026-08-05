import '../../calendar/application/calendar_event_service.dart';
import '../../calendar/application/recurrence_lifecycle_service.dart';
import '../../reminders/application/reminder_override_service.dart';
import '../../schedule/application/conflict_service.dart';
import '../../schedule/application/overlay_service.dart';
import '../../tasks/application/plan_block_service.dart' hide AlreadyDeletedError;
import '../../tasks/application/task_event_link_service.dart';
import '../../tasks/application/task_lifecycle_service.dart';
import '../../tasks/application/undo_service.dart';
import '../../tasks/domain/plan_block.dart';
import '../../tasks/domain/task.dart';

import '../domain/agent_permission_policy.dart';
import '../domain/agent_tool.dart';
import '../domain/agent_write_gateway.dart';
import '../domain/agent_write_proposal.dart';
import '../domain/agent_write_unit_of_work.dart';
import 'agent_permission_policy_service.dart';
import 'agent_write_tool.dart';
import 'write_argument_reader.dart';

/// 把「任务/执行块/事件」生命周期服务抛出的领域异常映射为 Spec §20 的安全
/// 错误码。在工具 `execute` 的 try 包裹 `commit` 后调用——服务异常绝不带
/// 原始文本落为结果，registry 仍是最后 `tool_execution_failed` 防线。
///
/// 映射规则（与各 service 的 throw 点逐一对齐）：
/// - `*_NotFoundError`（Task/PlanBlock/Event 不存在或跨账号）→ `target_not_found`
/// - `Stale*Command`（version/updatedAt 已变）→ `stale_target`
/// - `AlreadyDeletedError`（事件已软删除）→ `already_deleted`
/// - `Illegal*Transition` / `InvalidLifecycleTransition`（状态机拒绝）→ 按消息
///   细分 `already_*` / `invalid_lifecycle_transition`，消息不外泄
/// - `NotDeletedError`（PlanBlock restore 未删除块）→ `already_active`
/// - `AlreadyLifecycleDeleted`（重复生命周期目标已软删除）→ `already_deleted`
/// - `StaleRecurringTarget`（重复目标 preflight 后变更）→ `stale_target`
/// - `InvalidRecurringTransition`（重复生命周期状态机拒绝）→
///   `invalid_lifecycle_transition`，消息不外泄
/// - `ConflictNotDeletableError` → `relation_not_deletable`（非 user 来源）
/// - `ConflictRelationNotFoundError` → `relation_not_found`
/// - `TaskEventLinkNotFoundError` → `link_not_found`
/// - `TaskEventLinkTargetNotFoundError` → `target_not_found`
/// - `InvalidUndoCommand` → `no_undo_available`
/// - `ScopeRequiredError` → 由 `update_event` 自行映射（重复 scope 缺失）
AgentToolResult? mapLifecycleError(Object error) {
  if (error is TaskNotFoundError || error is PlanBlockNotFoundError) {
    return const AgentToolResult(
      status: AgentToolStatus.error,
      errorCode: 'target_not_found',
    );
  }
  if (error is StaleTaskCommand || error is StalePlanBlockCommand) {
    return const AgentToolResult(
      status: AgentToolStatus.error,
      errorCode: 'stale_target',
    );
  }
  if (error is AlreadyDeletedError) {
    return const AgentToolResult(
      status: AgentToolStatus.error,
      errorCode: 'already_deleted',
    );
  }
  if (error is IllegalTaskTransition || error is IllegalPlanBlockTransition) {
    return _mapTransition(error.toString());
  }
  if (error is InvalidLifecycleTransition) {
    return _mapTransition(error.toString());
  }
  // PlanBlock restore on a non-deleted block (PlanBlockService.restore throws
  // NotDeletedError). Deterministic, no text leak — the block is already
  // active/visible, so restoring is a no-op identity.
  if (error is NotDeletedError) {
    return const AgentToolResult(
      status: AgentToolStatus.error,
      errorCode: 'already_active',
    );
  }
  // Recurring lifecycle (RecurrenceLifecycleService) deterministic errors.
  if (error is AlreadyLifecycleDeleted) {
    return const AgentToolResult(
      status: AgentToolStatus.error,
      errorCode: 'already_deleted',
    );
  }
  if (error is StaleRecurringTarget) {
    return const AgentToolResult(
      status: AgentToolStatus.error,
      errorCode: 'stale_target',
    );
  }
  if (error is InvalidRecurringTransition) {
    return const AgentToolResult(
      status: AgentToolStatus.error,
      errorCode: 'invalid_lifecycle_transition',
    );
  }
  if (error is ConflictNotDeletableError) {
    return const AgentToolResult(
      status: AgentToolStatus.error,
      errorCode: 'relation_not_deletable',
      payload: {
        'guidance': '该关系来自学校来源或派生计算，不能删除；可在设置中隐藏。',
      },
    );
  }
  if (error is ConflictRelationNotFoundError) {
    return const AgentToolResult(
      status: AgentToolStatus.error,
      errorCode: 'relation_not_found',
    );
  }
  if (error is TaskEventLinkNotFoundError) {
    return const AgentToolResult(
      status: AgentToolStatus.error,
      errorCode: 'link_not_found',
    );
  }
  if (error is TaskEventLinkTargetNotFoundError) {
    return const AgentToolResult(
      status: AgentToolStatus.error,
      errorCode: 'target_not_found',
    );
  }
  // I2: unlink/reminder/overlay version+content mismatch -> stale_target
  // (distinct from foreign/missing -> target_not_found above).
  if (error is StaleTaskEventLinkCommand ||
      error is StaleReminderTargetCommand ||
      error is StaleOverlayCommand) {
    return const AgentToolResult(
      status: AgentToolStatus.error,
      errorCode: 'stale_target',
    );
  }
  if (error is InvalidUndoCommand) {
    return const AgentToolResult(
      status: AgentToolStatus.error,
      errorCode: 'no_undo_available',
    );
  }
  return null;
}

/// 把状态机拒绝的内部消息映射为安全码，绝不回传原始文本。
AgentToolResult _mapTransition(String message) {
  // 恢复类：目标是「未删除」/「已是活跃」 → already_active / already_active。
  if (message.contains('not deleted') || message.contains('不是已删除')) {
    return const AgentToolResult(
      status: AgentToolStatus.error,
      errorCode: 'already_active',
    );
  }
  // 「已在该状态」/「already in that state」→ 按上下文落在 already_* 由调用方
  // 不可知，统一用 invalid_lifecycle_transition（确定性、无文本）。
  return const AgentToolResult(
    status: AgentToolStatus.error,
    errorCode: 'invalid_lifecycle_transition',
  );
}

/// 包装 `commit` 阶段可能抛出的领域异常，映射为安全结果；未识别异常向上抛
/// （registry 兜底为 tool_execution_failed）。
Future<AgentToolResult> guardCommit(
  Future<AgentToolResult> Function() body,
) async {
  try {
    return await body();
  } catch (error) {
    final mapped = mapLifecycleError(error);
    if (mapped != null) return mapped;
    rethrow;
  }
}

// ===========================================================================
// update_task
// ===========================================================================

/// 任务生命周期：complete/cancel/reopen/delete/restore。一轮只处理一个任务，
/// 标题/描述编辑不在本工具范围。动态 proposal：每个 action 对应独立策略键
/// （task_complete/task_cancel/task_delete/task_restore；reopen 复用 task_complete
/// 的 medium 风险语义，但策略键单独注册为 task_complete 的逆操作——此处复用
/// task_complete 键，因为注册表未单独定义 task_reopen，且风险/确认语义一致）。
class UpdateTaskTool extends AgentWriteTool {
  UpdateTaskTool({
    required super.gateway,
    required super.policy,
    required super.confirmationStore,
    required super.unitOfWork,
  });

  @override
  String get name => 'update_task';
  @override
  String get description =>
      '完成、取消、重新打开、删除或恢复一个任务。ref_task 来自 get_tasks。'
      '删除为软删除（可恢复），不级联删除子执行块。';
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'ref_task': {'type': 'string', 'description': '来自 get_tasks 的 ref_*'},
          'action': {
            'type': 'string',
            'enum': ['complete', 'cancel', 'reopen', 'delete', 'restore'],
            'description': '要执行的生命周期动作',
          },
        },
        'required': ['ref_task', 'action'],
      };

  @override
  String get actionType => 'task_complete';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'task';
  @override
  String get operationLabel => '更新任务状态';
  @override
  List<AgentWriteAllowance> get agentWriteAllowances => [
        AgentWriteAllowance.fromRegistry('task_complete'),
        AgentWriteAllowance.fromRegistry('task_cancel'),
        AgentWriteAllowance.fromRegistry('task_delete'),
        AgentWriteAllowance.fromRegistry('task_restore'),
      ];

  @override
  Future<AgentWriteProposal> propose(
    Map<String, Object?> a,
    AgentToolContext ctx,
  ) async {
    final r = WriteArgumentReader(a, const {'ref_task', 'action'});
    r.rejectUnknownKeys();
    final ref = r.requiredString('ref_task');
    final taskId = ctx.references.resolve(ref: ref, kind: 'task');
    if (taskId == null) throw const FormatException('unknown task ref');
    final action = r.requiredEnum('action',
        const {'complete', 'cancel', 'reopen', 'delete', 'restore'});

    // I4: a restore targets a soft-deleted row, which `taskById` filters out.
    // Use the deleted-inclusive lookup for restore so the proposal can form;
    // the commit still re-checks expectedUpdatedAt + not-deleted state via
    // TaskLifecycleService.restore (IllegalTaskTransition -> already_active,
    // StaleTaskCommand -> stale_target). Non-restore actions keep the filtered
    // lookup so complete/cancel/reopen/delete on a deleted row stays
    // target_not_found.
    final task = action == 'restore'
        ? await gateway.taskByIdIncludeDeleted(taskId)
        : await gateway.taskById(taskId);
    final (actionType, risk, label) = _actionPolicy(action);
    final actionZh = _actionZh(action);
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: risk,
      targetType: targetType,
      operationLabel: '$operationLabel（$actionZh）',
      previewLines: [
        '目标：${task.title}',
        '当前状态：${_taskStateZh(task.state)}',
        '变更：$actionZh',
      ],
      commitParams: {
        'taskId': taskId,
        'action': action,
        'expectedUpdatedAt': task.updatedAt,
        'title': task.title,
      },
      safeLogSummary: '$actionZh 任务 ${task.title}',
    );
  }

  @override
  Future<AgentToolResult> commit(
    AgentWriteProposal proposal,
    AgentToolContext ctx,
  ) async {
    final p = proposal.commitParams;
    final taskId = p['taskId'] as String;
    final action = p['action'] as String;
    final expected = p['expectedUpdatedAt'] as int;
    return guardCommit(() async {
      switch (action) {
        case 'complete':
          await gateway.completeTask(taskId, expectedUpdatedAt: expected);
        case 'cancel':
          await gateway.cancelTask(taskId, expectedUpdatedAt: expected);
        case 'reopen':
          await gateway.reopenTask(taskId, expectedUpdatedAt: expected);
        case 'delete':
          await gateway.softDeleteTask(taskId, expectedUpdatedAt: expected);
        case 'restore':
          await gateway.restoreTask(taskId, expectedUpdatedAt: expected);
      }
      return AgentToolResult(payload: {
        'result': 'updated_task',
        'action': action,
      });
    });
  }

  static (String, RiskLevel, String) _actionPolicy(String action) => switch (action) {
        'complete' => ('task_complete', RiskLevel.medium, '完成任务'),
        'cancel' => ('task_cancel', RiskLevel.high, '取消任务'),
        'reopen' => ('task_complete', RiskLevel.medium, '重新打开任务'),
        'delete' => ('task_delete', RiskLevel.high, '删除任务'),
        'restore' => ('task_restore', RiskLevel.medium, '恢复任务'),
        _ => ('task_complete', RiskLevel.medium, '更新任务'),
      };

  static String _actionZh(String action) => switch (action) {
        'complete' => '完成',
        'cancel' => '取消',
        'reopen' => '重新打开',
        'delete' => '删除（软删除，可恢复）',
        'restore' => '恢复',
        _ => action,
      };

  static String _taskStateZh(TaskState state) => switch (state) {
        TaskState.active => '进行中',
        TaskState.blocked => '阻塞',
        TaskState.completed => '已完成',
        TaskState.cancelled => '已取消',
      };
}

// ===========================================================================
// update_plan_block
// ===========================================================================

/// 执行块生命周期：done/skip/cancel/delete/restore。done/skip 可带 note。
/// 删除/取消不级联父任务，不删除 reschedule replacement。
class UpdatePlanBlockTool extends AgentWriteTool {
  UpdatePlanBlockTool({
    required super.gateway,
    required super.policy,
    required super.confirmationStore,
    required super.unitOfWork,
  });

  @override
  String get name => 'update_plan_block';
  @override
  String get description =>
      '完成、跳过、取消、删除或恢复一个执行块。ref_plan_block 来自 get_plan_blocks。'
      '删除为软删除（可恢复），不影响父任务。';
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'ref_plan_block': {
            'type': 'string',
            'description': '来自 get_plan_blocks 的 ref_*',
          },
          'action': {
            'type': 'string',
            'enum': ['done', 'skip', 'cancel', 'delete', 'restore'],
          },
          'note': {
            'type': 'string',
            'description': '仅 done/skip 可用，记录完成/跳过备注',
          },
        },
        'required': ['ref_plan_block', 'action'],
      };

  @override
  String get actionType => 'plan_block_done';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'plan_block';
  @override
  String get operationLabel => '更新执行块状态';
  @override
  List<AgentWriteAllowance> get agentWriteAllowances => [
        AgentWriteAllowance.fromRegistry('plan_block_done',
            maxRisk: RiskLevel.medium),
        AgentWriteAllowance.fromRegistry('plan_block_cancel'),
        AgentWriteAllowance.fromRegistry('plan_block_delete'),
        AgentWriteAllowance.fromRegistry('plan_block_restore'),
      ];

  @override
  Future<AgentWriteProposal> propose(
    Map<String, Object?> a,
    AgentToolContext ctx,
  ) async {
    final r = WriteArgumentReader(
        a, const {'ref_plan_block', 'action', 'note'});
    r.rejectUnknownKeys();
    final ref = r.requiredString('ref_plan_block');
    final blockId = ctx.references.resolve(ref: ref, kind: 'planblock');
    if (blockId == null) throw const FormatException('unknown plan_block ref');
    final action = r.requiredEnum(
        'action', const {'done', 'skip', 'cancel', 'delete', 'restore'});
    final note = r.optionalString('note');
    if (note != null && action != 'done' && action != 'skip') {
      throw const FormatException('note is only allowed with done/skip');
    }

    // I4: a restore targets a soft-deleted block, which `planBlockById`
    // filters out. Use the deleted-inclusive lookup for restore so the
    // proposal can form; the commit still re-checks expectedUpdatedAt +
    // not-deleted state via PlanBlockService.restore (NotDeletedError ->
    // already_active, StalePlanBlockCommand -> stale_target). Non-restore
    // actions keep the filtered lookup so done/skip/cancel/delete on a deleted
    // block stays target_not_found.
    final block = action == 'restore'
        ? await gateway.planBlockByIdIncludeDeleted(blockId)
        : await gateway.planBlockById(blockId);
    final (actionType, risk) = _actionPolicy(action);
    final actionZh = _actionZh(action);
    final title = (block.title != null && block.title!.isNotEmpty)
        ? block.title!
        : '执行块';
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: risk,
      targetType: targetType,
      operationLabel: '$operationLabel（$actionZh）',
      previewLines: [
        '目标：$title',
        '时间：${_fmtTimeRange(block.startAt, block.endAt)}',
        '当前状态：${_planBlockStateZh(block.status)}',
        '变更：$actionZh',
      ],
      commitParams: {
        'blockId': blockId,
        'action': action,
        'expectedUpdatedAt': block.updatedAt,
        'note': note,
        'title': title,
      },
      safeLogSummary: '$actionZh 执行块 $title',
    );
  }

  @override
  Future<AgentToolResult> commit(
    AgentWriteProposal proposal,
    AgentToolContext ctx,
  ) async {
    final p = proposal.commitParams;
    final blockId = p['blockId'] as String;
    final action = p['action'] as String;
    final expected = p['expectedUpdatedAt'] as int;
    final note = p['note'] as String?;
    return guardCommit(() async {
      switch (action) {
        case 'done':
          await gateway.markPlanBlockDone(blockId,
              expectedUpdatedAt: expected, note: note);
        case 'skip':
          await gateway.markPlanBlockSkipped(blockId,
              expectedUpdatedAt: expected, note: note);
        case 'cancel':
          await gateway.cancelPlanBlock(blockId, expectedUpdatedAt: expected);
        case 'delete':
          await gateway.softDeletePlanBlock(blockId,
              expectedUpdatedAt: expected);
        case 'restore':
          await gateway.restorePlanBlock(blockId, expectedUpdatedAt: expected);
      }
      return AgentToolResult(payload: {
        'result': 'updated_plan_block',
        'action': action,
      });
    });
  }

  static (String, RiskLevel) _actionPolicy(String action) => switch (action) {
        'done' => ('plan_block_done', RiskLevel.medium),
        'skip' => ('plan_block_done', RiskLevel.medium),
        'cancel' => ('plan_block_cancel', RiskLevel.high),
        'delete' => ('plan_block_delete', RiskLevel.high),
        'restore' => ('plan_block_restore', RiskLevel.medium),
        _ => ('plan_block_done', RiskLevel.medium),
      };

  static String _actionZh(String action) => switch (action) {
        'done' => '完成',
        'skip' => '跳过',
        'cancel' => '取消',
        'delete' => '删除（软删除，可恢复）',
        'restore' => '恢复',
        _ => action,
      };

  static String _planBlockStateZh(PlanBlockStatus status) => switch (status) {
        PlanBlockStatus.accepted => '已安排',
        PlanBlockStatus.done => '已完成',
        PlanBlockStatus.skipped => '已跳过',
        PlanBlockStatus.cancelled => '已取消',
        PlanBlockStatus.suggested => '待确认',
        PlanBlockStatus.rescheduled => '已改期',
      };
}

String _fmtTimeRange(DateTime start, DateTime end) {
  String two(int n) => n.toString().padLeft(2, '0');
  final d = '${start.year}-${two(start.month)}-${two(start.day)}';
  return '$d ${two(start.hour)}:${two(start.minute)}-${two(end.hour)}:${two(end.minute)}';
}

// ===========================================================================
// delete_schedule_relation
// ===========================================================================

/// 删除单次显式冲突关系或系列冲突规则。只接受 `get_schedule_relations` 当轮
/// 产生的 ref_relation。关系/规则删除均为 high + always_ask；系列规则额外
/// 显示 366 天影响预览（按「天」计，非 occurrence 数）。
class DeleteScheduleRelationTool extends AgentWriteTool {
  DeleteScheduleRelationTool({
    required super.gateway,
    required super.policy,
    required super.confirmationStore,
    required super.unitOfWork,
  });

  @override
  String get name => 'delete_schedule_relation';
  @override
  String get description =>
      '删除一个显式日程冲突关系或系列冲突规则。ref_relation 来自 get_schedule_relations。'
      '课程/考试等来源关系不可删除。系列规则删除会显示未来 366 天影响。';
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'ref_relation': {
            'type': 'string',
            'description': '来自 get_schedule_relations 的 ref_*',
          },
        },
        'required': ['ref_relation'],
      };

  @override
  String get actionType => 'delete_schedule_relation';
  @override
  RiskLevel get riskLevel => RiskLevel.high;
  @override
  String get targetType => 'relation';
  @override
  bool get rememberAllowed => false; // 删除关系永远确认
  @override
  String get operationLabel => '删除日程关系';
  @override
  List<AgentWriteAllowance> get agentWriteAllowances => [
        AgentWriteAllowance.fromRegistry('delete_schedule_relation'),
        AgentWriteAllowance.fromRegistry('delete_schedule_relation_rule'),
      ];

  @override
  Future<AgentWriteProposal> propose(
    Map<String, Object?> a,
    AgentToolContext ctx,
  ) async {
    final r = WriteArgumentReader(a, const {'ref_relation'});
    r.rejectUnknownKeys();
    final ref = r.requiredString('ref_relation');
    // 关系 ref 可能绑定为 occurrence 关系或系列规则两种 kind。
    final resolved = ctx.references.resolveTarget(
      ref,
      allowedKinds: const {'schedule_relation', 'schedule_relation_rule'},
    );
    if (resolved == null) throw const FormatException('unknown relation ref');

    final isRule = resolved.kind == 'schedule_relation_rule';
    final actionType =
        isRule ? 'delete_schedule_relation_rule' : 'delete_schedule_relation';
    final lines = <String>[
      '变更：删除${isRule ? "系列冲突规则" : "单次冲突关系"}',
    ];
    if (isRule) {
      final impact = await gateway.conflictRuleRemovalImpact(resolved.localId);
      lines.add('影响：未来 366 天约 ${impact.affectedDays} 天'
          '${impact.over366Days ? "（超出 366 天${impact.infinite ? "且无限延续" : ""}）" : ""}');
    }
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: lines,
      commitParams: {
        'relationId': resolved.localId,
        'isRule': isRule,
      },
      safeLogSummary: isRule ? '删除系列冲突规则' : '删除单次冲突关系',
    );
  }

  @override
  Future<AgentToolResult> commit(
    AgentWriteProposal proposal,
    AgentToolContext ctx,
  ) async {
    final p = proposal.commitParams;
    final relationId = p['relationId'] as String;
    final isRule = p['isRule'] as bool;
    return guardCommit(() async {
      if (isRule) {
        await gateway.deleteConflictRule(relationId);
        return const AgentToolResult(
          payload: {'result': 'deleted_schedule_relation_rule'},
        );
      }
      await gateway.deleteConflictRelation(relationId);
      return const AgentToolResult(
        payload: {'result': 'deleted_schedule_relation'},
      );
    });
  }
}

// ===========================================================================
// clear_reminder
// ===========================================================================

/// 清除指定偏移或全部未来提醒。target 可是 event/task/planblock。
/// selected_offsets 中任一偏移不存在则整项不写。无剩余偏移时写 sentinel。
class ClearReminderTool extends AgentWriteTool {
  ClearReminderTool({
    required super.gateway,
    required super.policy,
    required super.confirmationStore,
    required super.unitOfWork,
  });

  @override
  String get name => 'clear_reminder';
  @override
  String get description =>
      '清除一个目标的未来提醒偏移或全部提醒。ref_target 来自对应查询。'
      'selected_offsets 中任一偏移不存在则整项不写；历史提醒保留。';
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'ref_target': {
            'type': 'string',
            'description': '来自 get_schedule/get_tasks/get_plan_blocks 的 ref_*',
          },
          'scope': {
            'type': 'string',
            'enum': ['selected_offsets', 'all'],
          },
          'offsets_minutes': {
            'type': 'array',
            'items': {'type': 'integer'},
            'description': 'selected_offsets 时必填：非空、非负、去重的偏移',
          },
        },
        'required': ['ref_target', 'scope'],
      };

  @override
  String get actionType => 'clear_reminder_offsets';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'event';
  @override
  String get operationLabel => '清除提醒';
  @override
  List<AgentWriteAllowance> get agentWriteAllowances => [
        AgentWriteAllowance.fromRegistry('clear_reminder_offsets'),
        AgentWriteAllowance.fromRegistry('clear_all_reminders'),
      ];

  @override
  Future<AgentWriteProposal> propose(
    Map<String, Object?> a,
    AgentToolContext ctx,
  ) async {
    final r = WriteArgumentReader(
        a, const {'ref_target', 'scope', 'offsets_minutes'});
    r.rejectUnknownKeys();
    final ref = r.requiredString('ref_target');
    final resolved = ctx.references.resolveTarget(ref);
    if (resolved == null) throw const FormatException('unknown target ref');
    final scope = r.requiredEnum('scope',
        const {'selected_offsets', 'all'});

    // 服务的 targetType 用存储 kind（plan_block 而非 planblock）。
    final storageTargetType = resolved.kind == 'planblock'
        ? 'plan_block'
        : resolved.kind;
    final List<int> offsets;
    if (scope == 'selected_offsets') {
      final raw = r.requiredIntList('offsets_minutes');
      if (raw.isEmpty) {
        throw const FormatException('offsets_minutes must not be empty');
      }
      if (raw.any((o) => o < 0)) {
        throw const FormatException('negative offset');
      }
      offsets = raw.toSet().toList()..sort();
    } else {
      if (r.contains('offsets_minutes')) {
        throw const FormatException('all scope must not specify offsets');
      }
      offsets = const [];
    }

    final isAll = scope == 'all';
    final (actionType, risk) = isAll
        ? ('clear_all_reminders', RiskLevel.high)
        : ('clear_reminder_offsets', RiskLevel.medium);

    // I2: capture the target's version + the current future desired offsets
    // at propose time for the commit TOCTOU re-check (Spec §20). For `all`
    // scope the offset snapshot prevents silently wiping offsets added between
    // propose and commit; for `selected_offsets` it catches a shifted set.
    final config = await gateway.reminderConfiguration(
        targetType: storageTargetType, targetId: resolved.localId);
    final int? expectedTargetUpdatedAt;
    switch (storageTargetType) {
      case 'event':
        final snapshot = await gateway.eventSnapshot(resolved.localId);
        expectedTargetUpdatedAt = snapshot.updatedAt;
      case 'task':
        final task = await gateway.taskById(resolved.localId);
        expectedTargetUpdatedAt = task.updatedAt;
      case 'plan_block':
        final block = await gateway.planBlockById(resolved.localId);
        expectedTargetUpdatedAt = block.updatedAt;
      default:
        expectedTargetUpdatedAt = null;
    }
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: risk,
      targetType: targetType,
      operationLabel: isAll ? '清除全部提醒' : '清除提醒偏移',
      previewLines: [
        '变更：${isAll ? "清除全部未来提醒" : "清除偏移 $offsets 分钟的提醒"}',
      ],
      commitParams: {
        'targetType': storageTargetType,
        'targetId': resolved.localId,
        'scope': scope,
        'offsets': offsets,
        'expectedTargetUpdatedAt': expectedTargetUpdatedAt,
        'expectedOffsetsSnapshot': config.futureDesiredOffsets,
      },
      safeLogSummary: isAll ? '清除全部提醒' : '清除提醒偏移 $offsets 分钟',
    );
  }

  @override
  Future<AgentToolResult> commit(
    AgentWriteProposal proposal,
    AgentToolContext ctx,
  ) async {
    final p = proposal.commitParams;
    final targetType = p['targetType'] as String;
    final targetId = p['targetId'] as String;
    final scope = p['scope'] as String;
    final offsets = (p['offsets'] as List).cast<int>();
    final expectedTargetUpdatedAt = p['expectedTargetUpdatedAt'] as int?;
    final expectedOffsetsSnapshot =
        (p['expectedOffsetsSnapshot'] as List?)?.cast<int>();
    return guardCommit(() async {
      await gateway.clearReminders(
        targetType: targetType,
        targetId: targetId,
        scope: scope,
        offsets: scope == 'all' ? null : offsets,
        expectedTargetUpdatedAt: expectedTargetUpdatedAt,
        expectedOffsetsSnapshot: expectedOffsetsSnapshot,
      );
      return AgentToolResult(payload: {
        'result': scope == 'all' ? 'cleared_all_reminders' : 'cleared_reminder_offsets',
      });
    });
  }
}

// ===========================================================================
// clear_user_overlay
// ===========================================================================

/// 清除事件单次层或课程系列层的 Overlay 字段。字段组展开由 service 完成；
/// 任一字段无效/目标变化则整项不写。
class ClearUserOverlayTool extends AgentWriteTool {
  ClearUserOverlayTool({
    required super.gateway,
    required super.policy,
    required super.confirmationStore,
    required super.unitOfWork,
  });

  @override
  String get name => 'clear_user_overlay';
  @override
  String get description =>
      '清除一个日程的个人标注字段（单次层或课程系列层）。ref_event 来自日程查询。'
      '支持字段与字段组（attendance/listening/display/appearance/all）。'
      '任一字段无效则整项不写。';
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'ref_event': {
            'type': 'string',
            'description': '来自 get_schedule 的 ref_*',
          },
          'scope': {
            'type': 'string',
            'enum': ['single_event', 'course_series'],
          },
          'fields': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': '非空字段数组，可为单字段或字段组',
          },
        },
        'required': ['ref_event', 'scope', 'fields'],
      };

  @override
  String get actionType => 'clear_event_overlay_fields';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'overlay';
  @override
  String get operationLabel => '清除日程标注';
  @override
  List<AgentWriteAllowance> get agentWriteAllowances => [
        AgentWriteAllowance.fromRegistry('clear_event_overlay_fields'),
        AgentWriteAllowance.fromRegistry('clear_all_event_overlay'),
        AgentWriteAllowance.fromRegistry('clear_course_overlay'),
      ];

  @override
  Future<AgentWriteProposal> propose(
    Map<String, Object?> a,
    AgentToolContext ctx,
  ) async {
    final r = WriteArgumentReader(a, const {'ref_event', 'scope', 'fields'});
    r.rejectUnknownKeys();
    final ref = r.requiredString('ref_event');
    final eventId = ctx.references.resolve(ref: ref, kind: 'event');
    if (eventId == null) throw const FormatException('unknown event ref');
    final scope = r.requiredEnum(
        'scope', const {'single_event', 'course_series'});
    final fields = r.requiredStringList('fields');
    if (fields.isEmpty) {
      throw const FormatException('fields must not be empty');
    }
    // 提前展开校验字段名，使无效字段在 propose 即被拒绝（service 也会再校验）。
    for (final field in fields) {
      OverlayFieldKeys.expand(field);
    }

    final isAll = fields.contains('all');
    final isCourseSeries = scope == 'course_series';
    final (actionType, risk) = _actionPolicy(isCourseSeries, isAll);

    // I2: capture the overlay row's updatedAt at propose time for the commit
    // TOCTOU re-check (Spec §20). For course_series scope, resolve the event's
    // series id first so the snapshot reads the series-layer row. A null
    // updatedAt (no overlay row yet) is plumbed through and skips the check.
    String? seriesIdForSnapshot;
    if (isCourseSeries) {
      seriesIdForSnapshot = await gateway.courseSeriesIdForEvent(eventId);
    }
    final overlaySnapshot = await gateway.overlayRowSnapshot(
      eventId: isCourseSeries ? null : eventId,
      courseSeriesId: isCourseSeries ? seriesIdForSnapshot : null,
    );
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: risk,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: [
        '变更：清除${isCourseSeries ? "课程系列层" : "单次层"}标注字段 $fields',
      ],
      commitParams: {
        'eventId': eventId,
        'scope': scope,
        'fields': fields,
        'expectedOverlayUpdatedAt': overlaySnapshot.updatedAt,
      },
      safeLogSummary: '清除日程标注字段 $fields',
    );
  }

  @override
  Future<AgentToolResult> commit(
    AgentWriteProposal proposal,
    AgentToolContext ctx,
  ) async {
    final p = proposal.commitParams;
    final eventId = p['eventId'] as String;
    final scope = p['scope'] as String;
    final fields = (p['fields'] as List).cast<String>();
    final expectedOverlayUpdatedAt = p['expectedOverlayUpdatedAt'] as int?;
    return guardCommit(() async {
      if (scope == 'course_series') {
        final seriesId = await gateway.courseSeriesIdForEvent(eventId);
        if (seriesId == null) {
          return const AgentToolResult(
            status: AgentToolStatus.error,
            errorCode: 'target_not_found',
            payload: {'guidance': '该日程没有课程系列，无法清除系列层标注。'},
          );
        }
        await gateway.clearOverlayFields(
          courseSeriesId: seriesId,
          fields: fields,
          expectedOverlayUpdatedAt: expectedOverlayUpdatedAt,
        );
      } else {
        await gateway.clearOverlayFields(
          eventId: eventId,
          fields: fields,
          expectedOverlayUpdatedAt: expectedOverlayUpdatedAt,
        );
      }
      return AgentToolResult(payload: {
        'result': 'cleared_user_overlay',
        'scope': scope,
      });
    });
  }

  static (String, RiskLevel) _actionPolicy(
      bool isCourseSeries, bool isAll) {
    if (isCourseSeries) return ('clear_course_overlay', RiskLevel.high);
    if (isAll) return ('clear_all_event_overlay', RiskLevel.high);
    return ('clear_event_overlay_fields', RiskLevel.medium);
  }
}

// ===========================================================================
// unlink_task_event
// ===========================================================================

/// 解除一对 (task, event) 关联。task/event 须同账号、未删除且关联存在。
class UnlinkTaskEventTool extends AgentWriteTool {
  UnlinkTaskEventTool({
    required super.gateway,
    required super.policy,
    required super.confirmationStore,
    required super.unitOfWork,
  });

  @override
  String get name => 'unlink_task_event';
  @override
  String get description =>
      '解除一个任务与一个日程的关联。ref_task 来自 get_tasks，ref_event 来自 get_schedule。'
      '只解除唯一 (任务, 日程) 关联，不修改任务、日程或其他配置。';
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'ref_task': {'type': 'string', 'description': '来自 get_tasks 的 ref_*'},
          'ref_event': {'type': 'string', 'description': '来自 get_schedule 的 ref_*'},
        },
        'required': ['ref_task', 'ref_event'],
      };

  @override
  String get actionType => 'unlink_task_event';
  @override
  RiskLevel get riskLevel => RiskLevel.high;
  @override
  bool get rememberAllowed => false;
  @override
  String get targetType => 'task';
  @override
  String get operationLabel => '解除任务-日程关联';
  @override
  List<AgentWriteAllowance> get agentWriteAllowances => [
        AgentWriteAllowance.fromRegistry('unlink_task_event'),
      ];

  @override
  Future<AgentWriteProposal> propose(
    Map<String, Object?> a,
    AgentToolContext ctx,
  ) async {
    final r = WriteArgumentReader(a, const {'ref_task', 'ref_event'});
    r.rejectUnknownKeys();
    final taskRef = r.requiredString('ref_task');
    final eventRef = r.requiredString('ref_event');
    final taskId = ctx.references.resolve(ref: taskRef, kind: 'task');
    if (taskId == null) throw const FormatException('unknown task ref');
    final eventId = ctx.references.resolve(ref: eventRef, kind: 'event');
    if (eventId == null) throw const FormatException('unknown event ref');

    // I2: capture the task + event version snapshot at propose time for the
    // commit TOCTOU re-check (Spec §20). Reuses C3's EventWriteSnapshot.
    final task = await gateway.taskById(taskId);
    final eventSnapshot = await gateway.eventSnapshot(eventId);

    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: const ['变更：解除该任务与该日程的关联'],
      commitParams: {
        'taskId': taskId,
        'eventId': eventId,
        'expectedTaskUpdatedAt': task.updatedAt,
        'expectedEventUpdatedAt': eventSnapshot.updatedAt,
      },
      safeLogSummary: '解除任务-日程关联',
    );
  }

  @override
  Future<AgentToolResult> commit(
    AgentWriteProposal proposal,
    AgentToolContext ctx,
  ) async {
    final p = proposal.commitParams;
    final taskId = p['taskId'] as String;
    final eventId = p['eventId'] as String;
    final expectedTaskUpdatedAt = p['expectedTaskUpdatedAt'] as int?;
    final expectedEventUpdatedAt = p['expectedEventUpdatedAt'] as int?;
    return guardCommit(() async {
      await gateway.unlinkTaskEvent(
        taskId: taskId,
        eventId: eventId,
        expectedTaskUpdatedAt: expectedTaskUpdatedAt,
        expectedEventUpdatedAt: expectedEventUpdatedAt,
      );
      return const AgentToolResult(
        payload: {'result': 'unlinked_task_event'},
      );
    });
  }
}

// ===========================================================================
// reset_permission_policy
// ===========================================================================

/// 重置一个动作的确认策略为默认（删除自定义覆盖行）。critical + always_ask，
/// 不能重置自身保护（kNonResetableActions）。无覆盖行返回 already_default，
/// 不写日志/Undo。
class ResetPermissionPolicyTool extends AgentWriteTool {
  ResetPermissionPolicyTool({
    required super.gateway,
    required super.policy,
    required super.confirmationStore,
    required super.unitOfWork,
  });

  @override
  String get name => 'reset_permission_policy';
  @override
  String get description =>
      '把一个动作的确认策略恢复为默认（删除自定义覆盖）。target_action_type 必须'
      '是已注册且允许配置的动作。无自定义覆盖时返回 already_default。';
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'target_action_type': {
            'type': 'string',
            'description': '要重置的已注册动作键（如 event_delete）',
          },
        },
        'required': ['target_action_type'],
      };

  @override
  String get actionType => 'reset_permission_policy';
  @override
  RiskLevel get riskLevel => RiskLevel.critical;
  @override
  String get targetType => 'permission';
  @override
  bool get forceConfirmation => true;
  @override
  bool get rememberAllowed => false;
  @override
  String get operationLabel => '重置确认策略';
  @override
  List<AgentWriteAllowance> get agentWriteAllowances => [
        AgentWriteAllowance.fromRegistryAnyTarget('reset_permission_policy'),
      ];

  @override
  Future<AgentWriteProposal> propose(
    Map<String, Object?> a,
    AgentToolContext ctx,
  ) async {
    final r = WriteArgumentReader(a, const {'target_action_type'});
    r.rejectUnknownKeys();
    final targetAction = r.requiredString('target_action_type');
    // 必须是已注册动作；target 由注册表确定，工具不接受任意 target_type。
    final entry = AgentPermissionPolicyService.kPermissionActions[targetAction];
    if (entry == null) {
      throw const FormatException('unknown action type');
    }
    if (kNonResetableActions.contains(targetAction)) {
      throw const FormatException('this action cannot be reset');
    }
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType, // 'reset_permission_policy' (the tool's own action)
      riskLevel: riskLevel,
      targetType: targetType, // 'permission'
      operationLabel: operationLabel,
      previewLines: [
        '变更：恢复动作 $targetAction 的确认策略为默认',
      ],
      commitParams: {
        'targetActionType': targetAction,
        'targetType': entry.targetType,
      },
      safeLogSummary: '重置确认策略 $targetAction',
    );
  }

  @override
  Future<AgentToolResult> commit(
    AgentWriteProposal proposal,
    AgentToolContext ctx,
  ) async {
    final p = proposal.commitParams;
    final actionType = p['targetActionType'] as String;
    final targetType = p['targetType'] as String;
    return guardCommit(() async {
      final removed = await gateway.resetPermissionPolicy(
        actionType: actionType,
        targetType: targetType,
      );
      if (!removed) {
        return const AgentToolResult(
          payload: {'result': 'already_default'},
        );
      }
      return const AgentToolResult(
        payload: {'result': 'reset_permission_policy'},
      );
    });
  }
}

// ===========================================================================
// undo_last_action
// ===========================================================================

/// 一步撤回最近一次可撤回操作。propose 预览撤回摘要，commit 调用 UndoService
/// 消费并清空槽。槽缺失/跨账号 → no_undo_available。
class UndoLastActionTool extends AgentWriteTool {
  UndoLastActionTool({
    required super.gateway,
    required super.policy,
    required super.confirmationStore,
    required super.unitOfWork,
  });

  @override
  String get name => 'undo_last_action';
  @override
  String get description =>
      '一步撤回最近一次可撤回的本地操作。撤回成功后槽清空，不支持连续撤回更早操作。'
      '调用前应先用 get_last_undoable_action 预览。';
  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'additionalProperties': false,
        'properties': {},
      };

  @override
  String get actionType => 'undo_last_action';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'undo';
  @override
  String get operationLabel => '撤回上一步';
  @override
  List<AgentWriteAllowance> get agentWriteAllowances => [
        AgentWriteAllowance.fromRegistry('undo_last_action'),
      ];

  @override
  Future<AgentWriteProposal> propose(
    Map<String, Object?> a,
    AgentToolContext ctx,
  ) async {
    final r = WriteArgumentReader(a, const {});
    r.rejectUnknownKeys();
    final preview = await gateway.undoPreview();
    if (!preview.available) {
      throw const FormatException('no undoable action available');
    }
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: [
        '将撤回：${preview.summary}',
        if (preview.beijingAt.isNotEmpty) '原操作时间：${preview.beijingAt}',
      ],
      commitParams: const {},
      safeLogSummary: '撤回：${preview.summary}',
    );
  }

  @override
  Future<AgentToolResult> commit(
    AgentWriteProposal proposal,
    AgentToolContext ctx,
  ) async {
    return guardCommit(() async {
      await gateway.undoLastAction();
      return const AgentToolResult(payload: {'result': 'undone_last_action'});
    });
  }
}

/// 组装本文件中的全部生命周期/清除/撤回写工具。
List<AgentWriteTool> agentLifecycleTools(
  AgentWriteGateway gateway,
  AgentPermissionPolicyService policy,
  WriteConfirmationStore confirmationStore,
  AgentWriteUnitOfWork unitOfWork,
) => [
      UpdateTaskTool(
          gateway: gateway,
          policy: policy,
          confirmationStore: confirmationStore,
          unitOfWork: unitOfWork),
      UpdatePlanBlockTool(
          gateway: gateway,
          policy: policy,
          confirmationStore: confirmationStore,
          unitOfWork: unitOfWork),
      DeleteScheduleRelationTool(
          gateway: gateway,
          policy: policy,
          confirmationStore: confirmationStore,
          unitOfWork: unitOfWork),
      ClearReminderTool(
          gateway: gateway,
          policy: policy,
          confirmationStore: confirmationStore,
          unitOfWork: unitOfWork),
      ClearUserOverlayTool(
          gateway: gateway,
          policy: policy,
          confirmationStore: confirmationStore,
          unitOfWork: unitOfWork),
      UnlinkTaskEventTool(
          gateway: gateway,
          policy: policy,
          confirmationStore: confirmationStore,
          unitOfWork: unitOfWork),
      ResetPermissionPolicyTool(
          gateway: gateway,
          policy: policy,
          confirmationStore: confirmationStore,
          unitOfWork: unitOfWork),
      UndoLastActionTool(
          gateway: gateway,
          policy: policy,
          confirmationStore: confirmationStore,
          unitOfWork: unitOfWork),
    ];
