/// The tools a grounded, explicit user request must exercise before its final
/// answer can be accepted as tool-backed (rather than an LLM plain-text claim).
///
/// - [lookupTools]: read-only tools the model must call to obtain concrete
///   evidence or a `ref_*` target for a follow-on operation.
/// - [terminalTools]: write tools that must complete successfully (after
///   confirmation) before success prose for a mutation is accepted.
/// - [mutationIntent]: whether this is an actual write operation. When true,
///   lookup success alone is never sufficient — a terminal write must succeed.
/// The relation conflict state the user has already expressed for a
/// high-confidence relation write. A concrete user decision (choosing one item,
/// allowing coexistence, or doing nested work) outscores the mere word
/// "冲突"; an unresolved decision is a genuine `conflict`. Only used to enforce
/// expected state on `create_schedule_relation` inputs — never to rewrite model
/// input silently.
enum ExpectedConflictState {
  /// 用户已表达取舍 / 允许共存 / 课上完成另一任务 -> save `no_conflict`.
  noConflict,
  /// 用户尚未决定 / 仍需调整 / 只需登记未解决冲突 -> save `conflict`.
  conflict,
}

class AgentGroundingRequirement {
  const AgentGroundingRequirement({
    this.lookupTools = const {},
    this.anyOfLookupToolGroups = const [],
    this.terminalTools = const {},
    this.supportingTools = const {},
    this.mutationIntent = false,
    this.initialAllowedTools,
    this.expectedConflictState,
    this.createTaskBurstLimit,
  });

  /// Read-only tools the model must call to obtain concrete evidence or a
  /// `ref_*` target for a follow-on operation. When [anyOfLookupToolGroups] is
  /// empty, this is read as an ALL-OF requirement (every listed lookup must
  /// succeed).
  final Set<String> lookupTools;

  /// Alternative lookup groups. When non-empty, only ONE group's tools need to
  /// succeed to satisfy the lookup requirement (EITHER/OR over groups). Used
  /// for create_schedule_relation, where event-event relations only need
  /// schedule refs and PlanBlock-PlanBlock relations only need plan-block
  /// refs — never an unconditional success of BOTH query tools.
  final List<Set<String>> anyOfLookupToolGroups;

  final Set<String> terminalTools;

  /// Tools the model may use to prepare/plan the operation beyond the terminal
  /// write and its required lookups, e.g. task-planning tools exposed to a
  /// relation run that also schedules an existing Task. Empty for a plain
  /// relation write. Included in [requiredTools] so corrective-stage tool
  /// narrowing keeps them allowed for the whole run.
  final Set<String> supportingTools;

  final bool mutationIntent;

  /// When non-null, the FIRST model request of the run declares ONLY these
  /// tool declarations (plus `auto` tool choice), rather than the whole
  /// registry. Used to keep high-confidence relation writes from reaching
  /// unrelated tools (e.g. `get_conflicts`). The set must contain only
  /// registered members of the relation tool family.
  final List<String>? initialAllowedTools;

  /// When non-null, the user has already expressed the relation's expected
  /// conflict state. A `create_schedule_relation` call whose `conflict_state`
  /// disagrees is corrected (never silently rewritten) with at most one changed
  /// call.
  final ExpectedConflictState? expectedConflictState;

  /// When non-null, the user asked to create MANY independent `create_task`
  /// calls in ONE run (a recurring weekly / explicit multi-date burst), and the
  /// terminal write tool is exactly `create_task`. Caps how many independent
  /// Task creates may be issued in a single run. The requesting run's first
  /// request declares only [initialAllowedTools] (a lookup + the terminal
  /// write). Null for every other read/write classification.
  final int? createTaskBurstLimit;

  /// The union of every tool this request ultimately requires (lookups that
  /// must provide evidence/refs plus the terminal write). For corrective-stage
  /// tool narrowing this keeps all candidate lookup tools allowed.
  Set<String> get requiredTools => {...lookupTools, ...supportingTools, ...terminalTools};

  /// Whether the given set of succeeded lookup tools satisfies the lookup
  /// requirement. With [anyOfLookupToolGroups] a single complete group is
  /// enough; otherwise all [lookupTools] must have succeeded. An empty lookup
  /// requirement is trivially satisfied.
  bool isLookupsSatisfied(Set<String> succeededTools) {
    if (anyOfLookupToolGroups.isNotEmpty) {
      return anyOfLookupToolGroups.any(
        (group) => group.every(succeededTools.contains),
      );
    }
    return lookupTools.every(succeededTools.contains);
  }
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

    // 1. Explicit no-tool instructions: "不要查询", "只讨论", "只想" etc. are a
    //    hard override — never an operation, no matter what else is said.
    if (_matchesAny(text, _hardFreeChatPatterns)) return null;

    // 2. Structurally-clear pure capability / advice questions. These are
    //    decided by full-sentence structure ("你能不能修改日程？",
    //    "为什么课程会发生冲突？") or has-capability framing, NOT by a single
    //    politeness word (能不能 / 帮我看看 / 解释 may all appear inside a normal
    //    operation request).
    if (_matchesAny(text, _capabilityAdvicePatterns)) return null;

    // 3. Write intents: an explicit operation outranks a generic read that
    //    shares its wording (e.g. "给...作业安排..." is plan_task, not a read
    //    of tasks).
    for (final def in _writeIntents) {
      if (_matchesAny(text, def.patterns)) {
        return _buildRequirement(def, text);
      }
    }

    // 4. Read intents: explicit factual queries.
    for (final def in _readIntents) {
      if (_matchesAny(text, def.patterns)) {
        return AgentGroundingRequirement(
          lookupTools: def.lookupTools,
        );
      }
    }

    // 5. Otherwise free chat / ambiguous — let the model answer or clarify.
    return null;
  }

  static bool _matchesAny(String text, List<RegExp> patterns) {
    for (final pattern in patterns) {
      if (pattern.hasMatch(text)) return true;
    }
    return false;
  }

  /// Builds a [AgentGroundingRequirement] from a matched [def], adding the
  /// optional narrowing set and (for relation writes) an expected conflict
  /// state derived from the user's wording.
  AgentGroundingRequirement _buildRequirement(_IntentDef def, String text) {
    final isRelation =
        def.terminalTools.contains('create_schedule_relation');
    // A relation run that ALSO plans an existing Task ("写一门...课作业" +
    // "安排在这个时间段") exposes the task-planning tools as supporting tools
    // alongside the relation terminal write. Uses the same shared
    // _planTaskPatterns as the standalone plan_task intent.
    final plansTask = isRelation && _matchesAny(text, _planTaskPatterns);
    final relationSet = isRelation
        ? (plansTask
              ? const [
                  'get_tasks',
                  'get_schedule',
                  'plan_task',
                  'get_plan_blocks',
                  'create_schedule_relation',
                ]
              : const [
                  'get_schedule',
                  'get_plan_blocks',
                  'create_schedule_relation',
                ])
        : null;
    final expected = isRelation
        ? _classifyExpectedConflictState(text)
        : null;
    // An explicit multi-create ("recurring weekly / explicit date list") burst
    // run whose terminal write is EXACTLY `create_task`. Such a run is grounded
    // on the schedule lookup (course range via course_summary) plus the single
    // terminal write; the first request declares only those two tools. A
    // single-create request, or one that also plans/uses other write tools,
    // gets NO burst limit and NO narrowing.
    final isCreateTaskBurst =
        def.terminalTools.length == 1 &&
        def.terminalTools.contains('create_task') &&
        _matchesAny(text, _multiTaskCreatePatterns);
    return AgentGroundingRequirement(
      lookupTools: def.lookupTools,
      anyOfLookupToolGroups: def.anyOfLookupToolGroups,
      terminalTools: def.terminalTools,
      supportingTools: plansTask ? const {'get_tasks', 'plan_task'} : const {},
      mutationIntent: true,
      initialAllowedTools: relationSet ??
          (isCreateTaskBurst
              ? const ['get_schedule', 'create_task']
              : null),
      expectedConflictState: expected,
      createTaskBurstLimit: isCreateTaskBurst ? 32 : null,
    );
  }

  /// A concrete user decision means `no_conflict`, outranking the bare word
  /// "冲突" in the same sentence. Only an explicit unresolved / just-register
  /// framing yields `conflict`. Ambiguity returns `null` (ask first; no
  /// confirmation card).
  static ExpectedConflictState? _classifyExpectedConflictState(String text) {
    // Concrete choice / coexistence / nested work -> no_conflict.
    final noConflictPatterns = [
      RegExp(r'(选择|选|去|不去|决定|保留).{0,12}(量子|物理|这|课|去|不|共存|同时|保留|两个)'),
      RegExp(r'共存'),
      RegExp(r'课上写'),
      RegExp(r'都去'),
      RegExp(r'两个.{0,4}(都|保留|共存|都要)'),
      // An explicit "不冲突" is a concrete user decision -> no_conflict. Placed
      // here so it is checked before the bare "冲突" unresolved patterns below.
      RegExp(r'不冲突'),
    ];
    for (final p in noConflictPatterns) {
      if (p.hasMatch(text)) return ExpectedConflictState.noConflict;
    }
    // Explicit unresolved / adjust / just-register -> conflict.
    final conflictPatterns = [
      RegExp(r'还没决定'),
      RegExp(r'尚未决定'),
      RegExp(r'还没想好'),
      RegExp(r'还未决定'),
      RegExp(r'只登记'),
      RegExp(r'仍需调整'),
    ];
    for (final p in conflictPatterns) {
      if (p.hasMatch(text)) return ExpectedConflictState.conflict;
    }
    return null;
  }
}

class _IntentDef {
  const _IntentDef({
    required this.patterns,
    this.lookupTools = const {},
    this.anyOfLookupToolGroups = const [],
    this.terminalTools = const {},
  });

  final List<RegExp> patterns;
  final Set<String> lookupTools;
  final List<Set<String>> anyOfLookupToolGroups;
  final Set<String> terminalTools;
}

/// ORDERED, NARROW free-chat guards, evaluated before any operation intent.
///
/// Deliberately NOT a broad word blacklist: a single politeness/advice word
/// (能不能 / 帮我看看 / 解释 / 为什么) may all appear inside a genuine operation
/// request, so they must not veto one. Only wording that is structurally a
/// pure capability / advice / assumption question, or an explicit no-tool
/// instruction, is free chat.

/// Hard overrides: the user explicitly says not to use tools / just discuss.
final List<RegExp> _hardFreeChatPatterns = [
  RegExp(r'不要查询'),
  RegExp(r'只讨论'),
  RegExp(r'只是想'),
  RegExp(r'不要用工具'),
  RegExp(r'别查'),
];

/// Structurally-clear capability / advice / hypothetical / why questions.
///
/// These match only when the whole sentence is a capability question or the
/// interrogative has a why/advice shape — never inside an operational request.
final List<RegExp> _capabilityAdvicePatterns = [
  // Has-capability framing at the START of the sentence: "你能不能修改日程？"
  // "你能安排日程吗？", "你能否...". The 能...? must be a full standalone
  // question, not embedded mid-sentence in an operation.
  RegExp(r'^(能不能|你能|你能否|可不可以|你[是]?否可以).{0,12}(修改|改|安排|调整|删除|创建|新建|处理|帮忙|帮我).{0,4}(日程|事件|任务|作业|课|课表|安排|计划|task)', caseSensitive: false),
  RegExp(r'^(你能|能不能|你能否).{0,10}(做什么|做哪些|provide|提供给).*'),
  RegExp(r'^(你能|能不能|你能否)(调整|修改|安排|管理|删除|创建|添加)'),
  // Why/advice questions (not conflict-data queries, which are reads). A
  // sentence with an explicit data-query verb (查一下/查询/查查/看看/列出)
  // is an EXPLICIT factual query, not a bare why/advice question — "查一下并
  // 解释我这周为什么有冲突" is a get_conflicts read, so the why-guard must not
  // swallow it. Only a pure why-interrogative with no query verb is advice.
  RegExp(r'^(?!.*(查一下|查询|查查|看看|列出|查)).*为什么.{0,8}(冲突|发生冲突|会冲突).*$'),
  RegExp(r'^(?!.*(查一下|查询|查查|看看|列出|查)).*为什么.{0,10}(这么安排|这样安排|这么计划|这样计划).*$'),
  RegExp(r'怎么(安排|规划|复习|做|才能)'),
  RegExp(r'如何(安排|规划|复习|做)'),
  RegExp(r'推荐'),
  RegExp(r'介绍一下'),
  RegExp(r'假设'),
  RegExp(r'是怎么(工作|运作|实现)'),
  RegExp(r'工作原理'),
  RegExp(r'解释一下.{0,6}(plan ?block|任务|概念|机制)'),
];

/// Shared plan-task patterns. Used BOTH by the standalone `plan_task` intent
/// and by the secondary "does this relation run also plan an existing Task?"
/// check, so the two must never drift apart.
final List<RegExp> _planTaskPatterns = [
  RegExp(r'(任务|作业|复习|project|assignment).{0,20}(安排|规划)'),
  RegExp(r'(安排|规划).{0,20}(任务|作业|复习)'),
  RegExp(r'安排.*(时间段|时段)'),
];

/// High-confidence multi-create ("create task burst") patterns. These require
/// BOTH a creation verb AND an explicit plurality/recurrence marker, so a
/// single create_task request ("创建一个Task") never trips one. Matching one
/// of these on a run whose terminal tool is exactly `create_task` marks the
/// run as a burst (capped at ONE-request-allowed-tools + a burst limit).
final List<RegExp> _multiTaskCreatePatterns = [
  RegExp(r'(每周|每星期|每个周[一二三四五六日天]).{0,24}(创建|新建|建立|设置).{0,10}(task|任务)', caseSensitive: false),
  RegExp(r'(连续\s*\d+\s*周|这些日期|每个日期|各个日期).{0,24}(分别|各自|逐个)?.{0,12}(创建|新建|建立|设置).{0,10}(task|任务)', caseSensitive: false),
  RegExp(r'(分别|各自|逐个).{0,12}(创建|新建|建立|设置).{0,10}(task|任务)', caseSensitive: false),
];

/// Write (mutation) intents, checked in order before read intents.
final List<_IntentDef> _writeIntents = [
  // create_schedule_relation (conflict / choose-one / coexist relation between
  // items). Checked EARLY because "记录冲突，我选择去量子物理 B" must route here
  // (not to record_attendance_decision), and a concrete choice / coexistence /
  // nested-work decision is a relation write even without the verb "冲突".
  // A bare conflict word with no decision ("这周有冲突吗") is a READ (get_conflicts),
  // never a mutation — so relation requires an explicit relation verb or a
  // concrete decision marker.
  _IntentDef(
    patterns: [
      RegExp(r'(记录|设为|标记|做成|选|决定|确认|建立).{0,12}(冲突|二选一|撞课|相撞|重了)'),
      RegExp(r'(冲突|二选一|撞课|相撞|重了).{0,6}(决策|就这么定)'),
      RegExp(r'记录.{0,6}(关系|选择)'),
      // Concrete choice / coexistence / nested work between two arrangements:
      // "选择去量子物理 B，不去电路基本理论", "选去量子物理 B，不去电路基本理论",
      // "两个安排可以共存", "课上写作业". The bare verb 选/选去 must also match so the
      // concise natural phrasing routes to the relation write.
      RegExp(r'(选择|我选|选去|选|决定|打算|选择去|我选择去).{0,15}(去|不去|上|不上|保留).{0,15}(不去|不选|保留|共存|去|上|写作业|写任务|完成)'),
      RegExp(r'(选中|选择|我选|选去).{0,10}(量子|物理|课|B|A|甲|乙|这个|那个)'),
      RegExp(r'(两个|两门|这两|这两节|两节|两个安排|这两个安排).{0,8}(共存|都保留|都去|同时|并存|都要|都保留)'),
      RegExp(r'共存'),
      RegExp(r'(课上|上课时).{0,4}(写|做|完成).{0,6}(作业|任务|复习)'),
    ],
    // A relation needs "two valid refs" — EITHER from schedule (event-event or
    // mixed) OR from plan blocks (PlanBlock-PlanBlock or mixed), never an
    // unconditional success of BOTH query tools. The single-group lookup set is
    // kept as the broad corrective-stage allowed set.
    lookupTools: {'get_schedule', 'get_plan_blocks'},
    anyOfLookupToolGroups: [
      {'get_schedule'},
      {'get_plan_blocks'},
    ],
    terminalTools: {'create_schedule_relation'},
  ),
  // plan_task: needs a task ref from get_tasks, then plans an execution window.
  // REQUIRES a task/作业/复习 entity — a bare "安排" with no task object is a
  // generic event (create_event) or ambiguous (null), never plan_task.
  _IntentDef(
    patterns: _planTaskPatterns,
    lookupTools: {'get_tasks'},
    terminalTools: {'plan_task'},
  ),
  // create_task
  _IntentDef(
    patterns: [
      RegExp(r'(新建|创建|添加|加一个).{0,12}(task|任务|作业)', caseSensitive: false),
      RegExp(r'(task|任务|作业).{0,12}(记下来|添加|新建)', caseSensitive: false),
    ],
    terminalTools: {'create_task'},
  ),
  // create_event: creating a schedule/event/arrangement, including a generic
  // "安排一个日程" / "晚上打游戏" that has NO task entity (so NOT plan_task).
  _IntentDef(
    patterns: [
      RegExp(r'(新建|创建|添加|加一个).{0,12}(日程|事件|安排)'),
      RegExp(r'(日程|事件).{0,12}(新建|创建|添加)'),
      RegExp(r'(安排|添加|创建).{0,8}(一个|个|这次|那天|本周|周五)?\s*(日程|事件|时间|时段|一块|游戏|活动|聚会|吃饭|约会|健身|学习)'),
      RegExp(r'(给|为|帮我).{0,6}(安排|添加|创建|预约).{0,6}(日程|事件|时段|游戏|活动|聚会|吃饭|约会)'),
    ],
    terminalTools: {'create_event'},
  ),
  // move_jw_course_day: whole-day JW course moves and their clear (restore).
  // Checked BEFORE update_event — both share "把…移到" wording, but a course
  // day move must route here. It requires BOTH a date/some-day context AND
  // collection semantics ("当天"/"整日"/"全部"/"所有"/"调休"). A bare `课`
  // ("把数据结构课程移到周五下午", "把周五课程移到周一") is a single-course
  // edit (update_event) or ambiguous — never a whole-day JW course move.
  _IntentDef(
    patterns: [
      // [把/将] ... <date> ... day/collection marker ... move verb.
      RegExp(r'(把|将).{0,20}(这天|当天|那(一)?天|8 ?月 ?[0-9]+日|周[一二三四五六日天]|礼拜[一二三四五六日天]|今天|明天|后天).{0,12}(全部|所有|整日|整整一?天|当天|这个|这些).{0,8}(教务课程|课程|课|教务).{0,12}(移到|移至|挪到|调至|调整到)'),
      RegExp(r'(把|将).{0,12}(教务|课程).{0,8}(整日|整周|全部|所有|当天).{0,6}(移动|调课|调休|挪到|移到)'),
      // Day-move with explicit whole-day/course-collection framing even without
      // a literal date word: "当天所有教务课程", "那天的全部课程".
      RegExp(r'(当天|整日|那天那|所有|全部).{0,4}(教务课程|课程).{0,12}(移到|移至|挪到|调至|调整到)'),
      RegExp(r'(教务|课程).{0,8}(整日|整周|全部|所有|当天).{0,4}(移动|调课|调休)'),
      // "教务课程" names the JW-course set; with a concrete date it is a
      // whole-day collection move even without a literal 当天/全部 marker.
      // ("把 8 月 3 日的教务课程移到 8 月 9 日").
      RegExp(r'(把|将).{0,20}[0-9]+ ?月 ?[0-9]+ ?日.{0,4}的?教务课程.{0,6}(移到|移至|挪到|调至|调整到)'),
      // A two-date whole-day 调课 request with "把 N 号的调到 M 号":
      // "国庆要调课，请把10月1号的调到9月26号".
      RegExp(r'(把|将)[0-9]+ ?月 ?[0-9]+ ?号.{0,6}(调到|移到|移至|挪到).{0,6}[0-9]+ ?月 ?[0-9]+ ?号'),
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
  // Conflicts / overlaps. Checked BEFORE the schedule read so a question like
  // "我这周有哪些时间冲突的安排？" routes to get_conflicts (the schedule
  // "这周…安排" pattern would otherwise swallow it).
  _IntentDef(
    patterns: [
      RegExp(r'(冲突|时间重叠|撞课|相撞|重了)'),
      // Question-shaped routing: an interrogative plus a conflict word is an
      // explicit factual query, never a write.
      RegExp(r'(有没有|吗|哪些|多少|哪里有).{0,10}(冲突|相撞|撞课|重了|时间重叠)'),
    ],
    lookupTools: {'get_conflicts'},
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