/// App-side routing of local capabilities from human text only. This selects
/// proposal tools, never approval or permission to commit a change.
final class AgentLocalRequestIntent {
  const AgentLocalRequestIntent({
    required this.changes,
    required this.planning,
    required this.writesRestricted,
  });
  final bool changes, planning, writesRestricted;
}

AgentLocalRequestIntent agentLocalRequestIntent(String question) {
  final text = question.toLowerCase();
  final directChange = RegExp(
    r'新增|新建|创建|添加|增加|记(?:下|一条|一个)|写(?:入|到|进)|录入|建(?:一个|一条)|保存|修改|更改|编辑|调整|改(?:成|到|为|一下)|移动|挪(?:到|一下)|删除|删掉|隐藏|恢复|完成|跳过|参加|听讲|不冲突|冲突关系|\b(?:create|add|update|move|delete|hide|mark|reschedule)\b',
  ).hasMatch(text);
  final attendanceChange = RegExp(
    r'(?:课|课程|活动).{0,12}(?:不想去|不去了|不参加|不去上|不去听)|(?:不想去|不去了|不参加).{0,12}(?:课|课程|活动)',
  ).hasMatch(text);
  final schedule = RegExp(r'安排|规划|\b(?:schedule|plan)\b').hasMatch(text);
  final localContext = RegExp(
    r'日程|个人安排|任务|复习|作业|时间块|今天|明天|后天|下周|本周|周[一二三四五六日天]|小时|分钟|\b(?:event|task|homework|hour|minute|tomorrow|monday)\b',
  ).hasMatch(text);
  final requestedSchedule = RegExp(
    r'(?:帮我|替我|给我|请).{0,20}(?:安排|规划)|(?:安排|规划)(?:一下|一段|一个|一小时)|\b(?:schedule|plan)\b',
  ).hasMatch(text);
  final planning =
      RegExp(r'空闲|找时间|时间规划|\bfree slots?\b').hasMatch(text) ||
      schedule &&
          (localContext || requestedSchedule) &&
          !RegExp(
            r'有什么安排|有哪些安排|什么日程|有哪些日程|已有安排|当前安排|查(?:看|询)?.{0,6}安排',
          ).hasMatch(text);
  final noWrite = RegExp(
    r'(?:不要|不用|无需|先别|暂不|不必).{0,8}(?:新增|新建|创建|添加|增加|保存|写|改|删|提交)|只(?:要|需|想)?(?:查|读|看|建议|分析|解释|展示)|\b(?:read[- ]only|do not (?:create|save|write|change|delete)|only suggest)\b',
  ).hasMatch(text);
  return AgentLocalRequestIntent(
    changes:
        !noWrite &&
        (directChange ||
            attendanceChange ||
            planning && (schedule || requestedSchedule)),
    planning: planning,
    writesRestricted: noWrite,
  );
}

/// Clarifying replies may retain the previous human's local request, but an
/// unrelated new question must not inherit a write capability indefinitely.
bool agentLocalClarification(String question) {
  if (question.length > 120) return false;
  return RegExp(
    r'继续|上面|上一|这个|那个|按你说的|按这个|那就|^(?:好|好的|可以|行|嗯|确认|没问题|同意)[，。！! ]?$|(?:周[一二三四五六日天]|明天|下周|今天|\d{4}-\d{2}-\d{2}).*(?:点|时|分钟|小时|\d{1,2}:\d{2})|(?:时间|地点|名称|标题)(?:是|改为|用|选)|\b(?:continue|use that|tomorrow|monday)\b',
    caseSensitive: false,
  ).hasMatch(question);
}

bool agentRestrictsPersonalData(String question) => RegExp(
  r'(?:不要|别|无需|不用|禁止)(?:查询|读取|查看|访问|查|读|看)(?:我的|本地|个人)?(?:日程|课表|安排|任务)|(?:只|仅)(?:查询|使用|查|用)?(?:公开资料|公开信息|知识库|评课)|only\s+public|do not (?:read|access) my (?:agenda|tasks|calendar)',
  caseSensitive: false,
).hasMatch(question);
