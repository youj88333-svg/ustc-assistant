// Wire vocabulary deliberately uses the fixed tool field spellings.
// ignore_for_file: constant_identifier_names

/// Compiled vocabulary only. Never carries a model value or an unknown key.
enum AgentParameterReason {
  malformedArguments,
  missingField,
  unknownField,
  invalidValue,
  invalidTimestamp,
  invalidDate,
  mutuallyExclusive,
  missingTaskTarget,
  unknownTaskKey,
  duplicateTaskKey,
  missingTimeRange,
  invalidTimeRange,
  missingPatch,
  invalidTarget,
  invalidReference,
  limitExceeded,
}

enum AgentChangeType {
  create_personal,
  update_personal,
  personal_state,
  delete_personal,
  create_task,
  update_task,
  task_state,
  delete_task,
  create_block,
  update_block,
  block_state,
  delete_block,
  annotate_school,
  set_relation,
  delete_relation,
}

enum AgentParameterField {
  arguments,
  additionalField,
  changes,
  type,
  event_ref,
  task_ref,
  left_ref,
  right_ref,
  slot_ref,
  task_key,
  local_key,
  scope,
  title,
  description,
  note,
  location,
  start,
  end,
  until_day,
  deadline,
  all_day,
  weekly,
  clear_until,
  completed,
  skipped,
  hidden,
  clear_deadline,
  clear_estimate,
  estimated_minutes,
  priority,
  status,
  attendance,
  listening,
  kind,
  first_day,
  end_day_exclusive,
  weekdays,
  start_minute,
  end_minute,
  block_minutes,
  break_minutes,
  avoid,
  include_hidden,
  include_skipped,
  max_candidates,
  source,
  semester_ref,
  semester_start,
  limit,
}

final class AgentParameterIssue implements Exception {
  const AgentParameterIssue({
    required this.reason,
    this.field = AgentParameterField.arguments,
    this.action,
    this.changeIndex,
  });
  final AgentParameterReason reason;
  final AgentParameterField field;
  final AgentChangeType? action;
  final int? changeIndex;

  AgentParameterIssue atChange(int index, AgentChangeType? type) =>
      AgentParameterIssue(
        reason: reason,
        field: field,
        action: type,
        changeIndex: index,
      );

  Map<String, Object?> toSafeMap() => {
    'reason': reason.name,
    'field': field.name,
    if (action != null) 'action': action!.name,
    if (changeIndex != null) 'changeIndex': changeIndex,
  };

  String get repairHint => switch (reason) {
    AgentParameterReason.invalidTimestamp =>
      '时刻必须为 YYYY-MM-DDTHH:mm[:ss]+08:00。只有日期的截止信息不填 deadline、不猜时刻，可在新任务 description 保留日期。',
    AgentParameterReason.invalidDate => '日期必须为真实的 YYYY-MM-DD。',
    AgentParameterReason.missingTaskTarget =>
      'create_block 必须且只能给 task_ref 或 task_key；新任务使用同一 changes 中此前 create_task 的 local_key。',
    AgentParameterReason.unknownTaskKey =>
      'task_key 必须匹配同一 changes 中此前 create_task 的 local_key；依赖任务放在时间块前。',
    AgentParameterReason.duplicateTaskKey =>
      'local_key 使用字母开头的 1–32 位字母、数字、下划线或连字符，且同一方案不重复。',
    AgentParameterReason.missingTimeRange =>
      '给出 start 和 end 两个北京时间时刻，或仅对时间块使用本轮 find_free_slots 返回的 slot_ref。',
    AgentParameterReason.invalidTimeRange => 'end 必须晚于 start；时间范围应满足本次用户条件。',
    AgentParameterReason.unknownField => '移除该操作未允许的字段；省略未提供的可选字段，不发送 null。',
    AgentParameterReason.missingField => '补齐该操作的必填字段；不要猜测现有记录引用或用户未提供的事实。',
    AgentParameterReason.invalidReference => '重新读取本轮目标引用，不使用真实 ID、历史引用或编造引用。',
    AgentParameterReason.mutuallyExclusive => '互斥字段只能选一种；更新起止时刻需成对提供。',
    AgentParameterReason.missingPatch => '更新至少提供一项允许修改的字段。',
    AgentParameterReason.invalidTarget => '仅对正确类别的本地目标执行此操作。',
    AgentParameterReason.limitExceeded => '缩小到工具声明的数量与范围上限。',
    AgentParameterReason.malformedArguments => '使用一个完整 JSON 对象，字段和值符合工具契约。',
    AgentParameterReason.invalidValue => '字段类型、枚举或范围不符合契约；省略未知的可选字段，不发送 null。',
  };

  String get userMessage {
    final position = changeIndex == null ? '' : '第 ${changeIndex! + 1} 项：';
    final detail = switch (reason) {
      AgentParameterReason.invalidTimestamp => '时间格式不正确',
      AgentParameterReason.invalidDate => '日期格式不正确',
      AgentParameterReason.missingTaskTarget => '时间块缺少明确任务',
      AgentParameterReason.unknownTaskKey => '新任务与时间块未正确关联',
      AgentParameterReason.duplicateTaskKey => '新任务的临时标记重复或无效',
      AgentParameterReason.missingTimeRange => '缺少完整起止时间',
      AgentParameterReason.invalidTimeRange => '起止时间顺序不正确',
      AgentParameterReason.missingField => '缺少必填参数',
      AgentParameterReason.unknownField => '包含此操作不支持的参数',
      AgentParameterReason.invalidReference => '目标引用已失效或无效',
      AgentParameterReason.mutuallyExclusive => '参数相互冲突',
      AgentParameterReason.missingPatch => '没有提供要修改的内容',
      AgentParameterReason.invalidTarget => '目标类别不支持此操作',
      AgentParameterReason.limitExceeded => '超出数量或范围上限',
      AgentParameterReason.malformedArguments => '参数结构不正确',
      AgentParameterReason.invalidValue => '参数值不符合要求',
    };
    return '$position$detail。';
  }

  @override
  String toString() => 'AgentParameterIssue(${reason.name}, ${field.name})';
}

AgentParameterField parameterField(String key) =>
    AgentParameterField.values
        .where((field) => field.name == key)
        .firstOrNull ??
    AgentParameterField.additionalField;

AgentChangeType? agentChangeType(Object? value) =>
    AgentChangeType.values.where((type) => type.name == value).firstOrNull;
