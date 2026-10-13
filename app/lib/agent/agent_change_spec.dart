import '../core/agent_parameter_issue.dart';

/// The same per-action field sets drive runtime checks and model guidance.
final class AgentChangeSpec {
  const AgentChangeSpec(this.requiredFields, this.optionalFields, this.rules);
  final Set<String> requiredFields, optionalFields;
  final String rules;
  Set<String> get allowedFields => {...requiredFields, ...optionalFields};
  String describe(AgentChangeType type) =>
      '${type.name}: 必填 ${requiredFields.join(',')}；可选 ${optionalFields.isEmpty ? '无' : optionalFields.join(',')}。$rules';
}

const agentChangeSpecs = <AgentChangeType, AgentChangeSpec>{
  AgentChangeType.create_personal: AgentChangeSpec(
    {'type', 'title', 'start', 'end'},
    {'all_day', 'weekly', 'until_day', 'location', 'note'},
    '新建无需引用。定时起止用北京时间时刻；all_day=true 才用纯日期、end为不含结束日期。不可用slot_ref。',
  ),
  AgentChangeType.update_personal: AgentChangeSpec(
    {'type', 'event_ref', 'scope'},
    {
      'title',
      'start',
      'end',
      'all_day',
      'weekly',
      'until_day',
      'clear_until',
      'location',
      'note',
    },
    'scope=series/occurrence；更新起止必须一起给start,end,all_day。occurrence不改重复规则；至少一项修改。',
  ),
  AgentChangeType.personal_state: AgentChangeSpec(
    {'type', 'event_ref'},
    {'completed', 'skipped'},
    '至少给一项状态。',
  ),
  AgentChangeType.delete_personal: AgentChangeSpec(
    {'type', 'event_ref'},
    {},
    '删除整组本地个人安排，引用必须指向首个实例。',
  ),
  AgentChangeType.create_task: AgentChangeSpec(
    {'type', 'local_key', 'title'},
    {'description', 'note', 'deadline', 'estimated_minutes', 'priority'},
    'local_key为本方案唯一字母开头1–32位字母数字_-标记，无需旧task_ref。deadline仅精确北京时间时刻；只知日期则省略deadline，在description保留日期。',
  ),
  AgentChangeType.update_task: AgentChangeSpec(
    {'type', 'task_ref'},
    {
      'title',
      'description',
      'note',
      'deadline',
      'clear_deadline',
      'estimated_minutes',
      'clear_estimate',
      'priority',
    },
    '至少一项修改；deadline/clear_deadline及estimated_minutes/clear_estimate互斥。',
  ),
  AgentChangeType.task_state: AgentChangeSpec(
    {'type', 'task_ref', 'status'},
    {},
    'status=active/blocked/completed/cancelled。',
  ),
  AgentChangeType.delete_task: AgentChangeSpec(
    {'type', 'task_ref'},
    {},
    '删除本地任务及所属时间块。',
  ),
  AgentChangeType.create_block: AgentChangeSpec(
    {'type'},
    {'task_ref', 'task_key', 'start', 'end', 'slot_ref', 'location', 'note'},
    'task_ref/task_key必须且仅给一种。新任务用同changes此前create_task的local_key作为task_key。给start+end或本轮slot_ref；两者互斥。',
  ),
  AgentChangeType.update_block: AgentChangeSpec(
    {'type', 'event_ref'},
    {'start', 'end', 'slot_ref', 'location', 'note'},
    'start+end和slot_ref互斥；至少一项修改。',
  ),
  AgentChangeType.block_state: AgentChangeSpec(
    {'type', 'event_ref', 'status'},
    {},
    'status=planned/done/skipped；不等同任务完成。',
  ),
  AgentChangeType.delete_block: AgentChangeSpec(
    {'type', 'event_ref'},
    {},
    '仅删除本地时间块。',
  ),
  AgentChangeType.annotate_school: AgentChangeSpec(
    {'type', 'event_ref'},
    {'hidden', 'note', 'attendance', 'listening'},
    '只修改本地覆盖，至少一项。考试不改attendance，listening仅课表可用；不改学校事实。',
  ),
  AgentChangeType.set_relation: AgentChangeSpec(
    {'type', 'left_ref', 'right_ref', 'kind'},
    {'note'},
    'kind=conflict/notConflict；两个不同日程，本地关系。',
  ),
  AgentChangeType.delete_relation: AgentChangeSpec(
    {'type', 'left_ref', 'right_ref'},
    {},
    '删除两个不同日程已有的本地关系。',
  ),
};

String get agentChangeGuidance =>
    '每项只用该type允许的字段；未知可选项省略，不发送null。'
    '时刻格式YYYY-MM-DDTHH:mm[:ss]+08:00；日期格式YYYY-MM-DD。\n'
    '${agentChangeSpecs.entries.map((e) => e.value.describe(e.key)).join('\n')}';
