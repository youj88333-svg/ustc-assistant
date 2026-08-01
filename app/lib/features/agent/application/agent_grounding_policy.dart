/// The tools a grounded, explicit user request must exercise before its final
/// answer can be accepted as tool-backed (rather than an LLM plain-text claim).
///
/// - [lookupTools]: read-only tools the model must call to obtain concrete
///   evidence or a `ref_*` target for a follow-on operation.
/// - [terminalTools]: write tools that must complete successfully (after
///   confirmation) before success prose for a mutation is accepted.
/// - [mutationIntent]: whether this is an actual write operation. When true,
///   lookup success alone is never sufficient — a terminal write must succeed.
class AgentGroundingRequirement {
  const AgentGroundingRequirement({
    this.lookupTools = const {},
    this.terminalTools = const {},
    this.mutationIntent = false,
  });

  final Set<String> lookupTools;
  final Set<String> terminalTools;
  final bool mutationIntent;

  /// The union of every tool this request ultimately requires (lookups that
  /// must provide evidence/refs plus the terminal write).
  Set<String> get requiredTools => {...lookupTools, ...terminalTools};
}

/// A conservative, deterministic classifier for explicit operational requests.
///
/// The policy maps ONLY high-confidence factual-query or actual-write wording
/// to a [AgentGroundingRequirement]. Capability questions, hypotheticals,
/// general-advice requests, explicit "just discuss / don't query" instructions
/// and free chat return `null` so the model may answer without any tool.
///
/// The classifier runs an advisory/capability blocklist FIRST so wording like
/// "你能不能修改日程？" or "为什么课程会发生冲突？" never trips a write/read
/// intent even though it shares verbs ("修改", "冲突") with real operations.
class AgentGroundingPolicy {
  const AgentGroundingPolicy();

  /// Classifies a single user turn. Returns the grounding requirement for an
  /// explicit operation, or `null` for free chat / capability / advice.
  AgentGroundingRequirement? classify(String userText) {
    final text = userText.trim().toLowerCase();
    if (text.isEmpty) return null;

    // Advisory / capability / hypothetical / explicit-discussion wording can
    // never be an operation. Checked before any intent so shared verbs do not
    // cause a false positive ("为什么课程冲突" must not become a conflict
    // query; "你能不能修改日程" must not become a schedule edit).
    if (_matchesAny(text, _forceFreeChatPatterns)) return null;

    // Write intents first: an explicit operation outranks a generic read that
    // shares its wording (e.g. "给...安排...作业" is plan_task, not a read of
    // tasks).
    for (final def in _writeIntents) {
      if (_matchesAny(text, def.patterns)) {
        return AgentGroundingRequirement(
          lookupTools: def.lookupTools,
          terminalTools: def.terminalTools,
          mutationIntent: true,
        );
      }
    }

    // Read intents: explicit factual queries.
    for (final def in _readIntents) {
      if (_matchesAny(text, def.patterns)) {
        return AgentGroundingRequirement(
          lookupTools: def.lookupTools,
        );
      }
    }

    return null;
  }

  static bool _matchesAny(String text, List<RegExp> patterns) {
    for (final pattern in patterns) {
      if (pattern.hasMatch(text)) return true;
    }
    return false;
  }
}

class _IntentDef {
  const _IntentDef({
    required this.patterns,
    this.lookupTools = const {},
    this.terminalTools = const {},
  });

  final List<RegExp> patterns;
  final Set<String> lookupTools;
  final Set<String> terminalTools;
}

/// Wording that must never be treated as an operation: capability questions,
/// hypotheticals, why/advice, and explicit "don't query / just discuss"
/// instructions.
final List<RegExp> _forceFreeChatPatterns = [
  RegExp(r'能不能'),
  RegExp(r'你能(做什么|做哪些|provide)?') ,
  RegExp(r'为什么'),
  RegExp(r'假设'),
  RegExp(r'解释'),
  RegExp(r'怎么(安排|规划|复习|做|才能)'),
  RegExp(r'如何(安排|规划|复习|做)'),
  RegExp(r'推荐'),
  RegExp(r'介绍一下'),
  RegExp(r'介绍一下自己'),
  RegExp(r'不要查询'),
  RegExp(r'只讨论'),
  RegExp(r'只是想'),
  RegExp(r'帮我看看'),
  RegExp(r'是怎么(工作|运作|实现)'),
  RegExp(r'工作原理'),
];

/// Write (mutation) intents, checked in order before read intents.
final List<_IntentDef> _writeIntents = [
  // plan_task: needs a task ref from get_tasks, then plans an execution window.
  _IntentDef(
    patterns: [
      RegExp(r'(任务|作业|复习|project|assignment).{0,20}(安排|规划)'),
      RegExp(r'(安排|规划).{0,20}(任务|作业|复习)'),
      RegExp(r'安排.*(时间段|时段)'),
      RegExp(r'给.*安排'),
    ],
    lookupTools: {'get_tasks'},
    terminalTools: {'plan_task'},
  ),
  // create_task
  _IntentDef(
    patterns: [
      RegExp(r'(新建|创建|添加|加一个).{0,12}(任务|作业)'),
      RegExp(r'(任务|作业).{0,12}(记下来|添加|新建)'),
    ],
    terminalTools: {'create_task'},
  ),
  // create_event
  _IntentDef(
    patterns: [
      RegExp(r'(新建|创建|添加|加一个).{0,12}(日程|事件|安排)'),
      RegExp(r'(日程|事件).{0,12}(新建|创建|添加)'),
    ],
    terminalTools: {'create_event'},
  ),
  // move_jw_course_day: whole-day JW course moves and their clear (restore).
  // Checked BEFORE update_event — both share "把…移到" wording, but a course
  // (教务课程/调休) day move must route to move_jw_course_day, not update_event.
  // Terminal move_jw_course_day; the model looks up the target week with
  // get_schedule before proposing the move (conflict warnings).
  _IntentDef(
    patterns: [
      RegExp(r'(把|将).{0,16}(教务|课程|课).{0,12}(移到|移至|挪到|调至|调整到)'),
      RegExp(r'(移到|移至|挪到|调至|调整到).{0,12}(教务课程|课程)'),
      RegExp(r'(教务|课程).{0,8}(整日|整周|全部).{0,4}(移动|调课|调休)'),
      RegExp(r'(恢复|撤销|取消).{0,8}(整日移动|调课|调休|课程移动)'),
    ],
    lookupTools: {'get_schedule'},
    terminalTools: {'move_jw_course_day'},
  ),
  // update_event (edit/delete a concrete event)
  _IntentDef(
    patterns: [
      RegExp(r'(把|将|给).{0,20}(改到|改至|调到|移到|改为|删除|取消)'),
      RegExp(r'修改.{0,8}(日程|事件|安排)'),
      RegExp(r'删除.{0,8}(日程|事件)'),
    ],
    lookupTools: {'get_schedule'},
    terminalTools: {'update_event'},
  ),
  // create_user_overlay (attendance/listening/mark on a schedule item)
  _IntentDef(
    patterns: [
      RegExp(r'(设为|标注|设置).{0,10}(必去|可以赌|不去|去不去)'),
      RegExp(r'(标注|设置).{0,8}(听讲|不听讲|显示名)'),
      RegExp(r'出勤.{0,4}(标注|设置|决定)'),
    ],
    lookupTools: {'get_schedule'},
    terminalTools: {'create_user_overlay'},
  ),
  // record_attendance_decision
  _IntentDef(
    patterns: [
      RegExp(r'(记录|标记).{0,8}(去|不去|出勤|这节)'),
      RegExp(r'这节.{0,6}(去|不去|逃)'),
    ],
    lookupTools: {'get_schedule'},
    terminalTools: {'record_attendance_decision'},
  ),
  // record_listening_mode
  _IntentDef(
    patterns: [
      RegExp(r'(设置|记录).{0,8}(听讲|不听讲|听|不听)'),
    ],
    lookupTools: {'get_schedule'},
    terminalTools: {'record_listening_mode'},
  ),
  // set_reminder
  _IntentDef(
    patterns: [
      RegExp(r'(提醒|闹钟).{0,6}(我|提前|前|几点)'),
      RegExp(r'(提前|前).{0,4}(提醒|通知)'),
    ],
    lookupTools: {'get_schedule'},
    terminalTools: {'set_reminder'},
  ),
  // create_schedule_relation (conflict / choose-one relation between items)
  _IntentDef(
    patterns: [
      RegExp(r'(冲突|二选一|撞课|重了|相撞)'),
      RegExp(r'记录.{0,6}(关系|选择)'),
    ],
    lookupTools: {'get_schedule', 'get_plan_blocks'},
    terminalTools: {'create_schedule_relation'},
  ),
  // update_permission_policy
  _IntentDef(
    patterns: [
      RegExp(r'以后.{0,6}(不要|别).{0,4}(确认|问)'),
      RegExp(r'(每次|以后).{0,6}(都问|都要|别确认).{0,4}'),
    ],
    terminalTools: {'update_permission_policy'},
  ),
];

/// Read (lookup) intents. Explicit factual queries only.
final List<_IntentDef> _readIntents = [
  // Pending PlanBlock reviews. Checked BEFORE pending-event review so an
  // "执行块...需要我确认" phrase maps to planblock (not event) reviews.
  _IntentDef(
    patterns: [
      RegExp(r'(执行块|plan ?block|planblock|时间块).{0,8}(需要我确认|待确认|等待确认|确认)'),
      RegExp(r'(需要我确认|待确认|等待确认).{0,8}(执行块|时间段|时间块)'),
    ],
    lookupTools: {'get_pending_planblock_reviews'},
  ),
  // Pending event reviews (attendance/listening confirmations to complete).
  _IntentDef(
    patterns: [
      RegExp(r'需要我确认.{0,10}(出勤|听讲|上课|签到|考勤)'),
      RegExp(r'(出勤|听讲|考勤).{0,8}(需要确认|待确认|待办|是否)'),
      RegExp(r'(确认).{0,4}(出勤|听讲)'),
    ],
    lookupTools: {'get_pending_event_reviews'},
  ),
  // Schedule / today / tomorrow / timetable. Requires a date context or an
  // explicit "查看/查一下/列出" verb so a bare navigation "查课表"/"查日程"
  // (routed to the schedule section by the chip, Task 4) is NOT forced into a
  // data query.
  _IntentDef(
    patterns: [
      RegExp(r'(今天|明天|后天|本周|下周|这周|上周|周[一二三四五六日天]).{0,8}(有什么课|课|课程|日程|安排|节)'),
      RegExp(r'(查看|查一下|列出|看看|给我).{0,6}(课表|课程表|日程|有没有课|这周的课)'),
      RegExp(r'(有没有课|什么时候有课|哪几天有课|这周有没有)'),
    ],
    lookupTools: {'get_schedule'},
  ),
  // Free time / availability.
  _IntentDef(
    patterns: [
      RegExp(r'(空余|空闲|有空|什么时候有空|free)'),
    ],
    lookupTools: {'get_free_time'},
  ),
  // Conflicts / overlaps.
  _IntentDef(
    patterns: [
      RegExp(r'(冲突|时间重叠|撞课|相撞|重了)'),
    ],
    lookupTools: {'get_conflicts'},
  ),
  // Tasks / homework listing.
  _IntentDef(
    patterns: [
      RegExp(r'(有哪些|查看|查|列出|当前|今天|本周).{0,8}(任务|作业)'),
      RegExp(r'(任务|作业).{0,6}(有哪些|待办|未完成|列表|都要)'),
    ],
    lookupTools: {'get_tasks'},
  ),
  // Task details.
  _IntentDef(
    patterns: [
      RegExp(r'(这个|某个|那个).{0,4}(任务|作业).{0,4}(详情|细节|内容)'),
      RegExp(r'(任务|作业).{0,4}(详情|细节)'),
    ],
    lookupTools: {'get_task_details'},
  ),
  // Plan blocks.
  _IntentDef(
    patterns: [
      RegExp(r'(执行块|时间段|plan ?block)'),
    ],
    lookupTools: {'get_plan_blocks'},
  ),
  // Sync status.
  _IntentDef(
    patterns: [
      RegExp(r'(同步|数据).{0,6}(状态|最新|了吗|好了没)'),
      RegExp(r'(最近.*同步|同步.*吗)'),
    ],
    lookupTools: {'get_sync_status'},
  ),
  // Safe action history.
  _IntentDef(
    patterns: [
      RegExp(r'(操作记录|历史记录|都做过什么|最近.*操作|action ?history)'),
    ],
    lookupTools: {'get_safe_action_history'},
  ),
  // Second-class (二课) activities.
  _IntentDef(
    patterns: [
      RegExp(r'(二课|第二课堂)'),
    ],
    lookupTools: {'search_current_second_class_activities'},
  ),
  // iCourse / course evaluation.
  _IntentDef(
    patterns: [
      RegExp(r'(评课|评教|icourse|i ?course|课程评价|课程口碑)'),
    ],
    lookupTools: {'search_icourse'},
  ),
  // Campus catalog / notices.
  _IntentDef(
    patterns: [
      RegExp(r'(校园|目录|通知|公告|社招)'),
    ],
    lookupTools: {'search_campus_catalog'},
  ),
];