# 校园生活日程核心数据模型

本文定义项目内部的日程核心模型。它不是最终数据库表设计，而是产品、后端、Agent、移动端 UI 都应共同遵守的概念模型。

当前假设：

- 产品优先服务单个中科大学生，数据本地优先保存，后续可选云同步。
- 日程表是主干，聊天 Agent 是操作入口，教务/二课/通知等系统是数据来源。
- 学校系统导入的数据不直接被用户改写；用户修改以“个人修正/标记/覆盖”形式保存。
- Agent 可以创建和建议日程；风险动作首次执行时询问用户，并允许用户选择“此类型以后不再确认”。所有风险权限都应能在设置中重新管理。

## 1. 已确认产品决策

以下是当前已确认的产品决策：

```text
1. 风险动作采用可配置权限：首次修改时询问用户；确认按钮附近提供“此类型以后不再确认”选项。
2. 设置页需要能管理所有风险项的权限松紧，例如始终询问、首次询问后放行、总是允许、总是禁止。
3. 数据主要保存在本地，云同步作为后续可选能力。
4. 课程出勤策略分为三个基础层级：必去、可以赌、不去。它不只表示点名，也可以表示小测、课程总结、节假日前风险高等任意原因。
5. 出勤策略必须支持备注，备注内容由用户自由写，LLM 在提醒和规划时必须读取。
6. 当某节课是“可以赌”时，LLM 需要在前一天或当天询问用户到底去不去，并记录本次决定。
7. 课程还需要支持“听讲/不听讲”选项；不去或不听讲的课可以成为安排作业、自习、娱乐或二课的候选时间。
8. 课程标记必须支持单节课粒度，因为某些周的某一节课可能有特殊任务，不能只按整门课统一标记。
9. 时间重叠不等于冲突。冲突状态只有“冲突/不冲突”，但是否冲突要结合用户意图、出勤策略、听讲策略和备注判断。
10. 作业先作为 Task，规划后生成 PlanBlock。
11. 导入课程不直接改源数据，只保存用户覆盖层。
12. 第一版不做手机系统日历双向同步。
```

仍保持的保守默认：

```text
- 普通新增可以由 Agent 草拟，保存前让用户确认。
- 二课报名和取消报名始终由用户在学校官方页面亲自完成，Agent 不得代为提交，
  也不能通过权限设置放宽这条边界。
- 其他校园事务申请属于未来外部写操作，必须另行设计风险策略和确认规则。
- 对 critical 风险动作，即使用户放宽权限，也建议保留二次确认或短时间撤销窗口。
```

## 2. 核心对象

项目不应只用一个 `Event` 表承载所有东西。建议拆成以下核心对象：

| 对象 | 含义 | 示例 |
| --- | --- | --- |
| `CalendarEvent` | 有明确开始和结束时间的事件 | 课程、考试、二课、聚餐 |
| `CalendarEventSeries` | 个人事件的基础重复规则和模板 | 每周二、四晚自习 |
| `CalendarEventOccurrenceException` | 重复系列中某一次的覆盖 | 本周例会改到周三 |
| `Task` | 有目标或截止时间，但不一定有固定执行时间 | 作业、复习、填表 |
| `PlanBlock` | 系统或用户安排出来的执行时间段 | 周三 20:00-21:30 写作业 |
| `ScheduleRelation` | 两个时间安排之间的关系和冲突判断 | 课上写作业、翘课参加二课 |
| `ScheduleRelationRule` | 由两个稳定系列身份限定、对本次及未来 occurrence 生效的结构化冲突规则 | 两个重复系列从本周起允许共存 |
| `SourceRecord` | 从外部系统导入的原始记录摘要 | 教务课表记录、二课活动记录 |
| `UserOverlay` | 用户对导入数据的个人修正 | 标记必去、隐藏、改显示名 |
| `Reminder` | 提醒规则 | 上课前 20 分钟提醒 |
| `ActionLog` | Agent 或用户做过的动作记录 | 导入课表、修改时间 |
| `AgentPermissionPolicy` | 用户授予 Agent 的风险操作权限 | 新增或移动日程前是否确认 |
| `JwDayMove` | 某天全部教务课程到另一天的整日移动记录 | 8 月 3 日课程整体移到 8 月 9 日 |
| `KnowledgeItem` | 校园知识库条目 | 通知、办事指南、校史资料 |

关系大致如下：

```text
SourceRecord -> CalendarEvent
CalendarEventSeries -> EffectiveCalendarEvent
CalendarEventOccurrenceException -> EffectiveCalendarEvent
Task -> PlanBlock
CalendarEvent -> Reminder
CalendarEvent -> UserOverlay
CalendarEvent/PlanBlock -> ScheduleRelation
CalendarEventSeries/CourseSeries -> ScheduleRelationRule
Agent/User action -> ActionLog
Agent action -> AgentPermissionPolicy
KnowledgeItem -> Agent answer citations
```

## 3. CalendarEvent

`CalendarEvent` 表示已经占用时间轴的一件事。课程、考试、二课、娱乐、个人安排都应进入这个模型。

### 3.1 字段

```text
id
userId
title
description
type
status
startAt
endAt
timezone
allDay
startDate
endDateExclusive
seriesId
occurrenceKey
locationName
buildingName
campusName
geo
source
sourceRecordId
externalId
confidence
importance
color
completionPolicy
attendancePolicy
attendanceDecision
attendanceDecisionAt
attendanceNote
attendanceOutcome
listeningMode
listeningNote
visibility
tags
participants
relatedTaskIds
reminderIds
userNotes
agentNotes
createdBy
updatedBy
createdAt
updatedAt
deletedAt
```

### 3.2 type

```text
course              课程
exam                考试
second_class        二课活动
personal            普通个人事项
entertainment       娱乐
meal                吃饭
campus_affair       校园事务
travel              通勤/校区移动
study               自习/复习
system              系统生成的辅助事件
```

用户手动创建时只允许选择 `personal`、`entertainment`、`meal`、
`campus_affair`、`travel` 和 `study`，默认 `personal`。`course`、`exam` 和
`second_class` 只由来源导入；自定义分类使用标签。

### 3.3 status

```text
active      正常
tentative   暂定
cancelled   取消
completed   已完成
skipped     时间已过且用户确认未进行
hidden      用户隐藏
```

冲突不放在 `CalendarEvent.status` 中表达，而由 `ScheduleRelation.conflictState` 表达。原因是时间重叠不一定是冲突，同一时间上课、写作业、娱乐、二课都有可能是用户有意安排。

`deletedAt` 表示软删除，不属于状态枚举。作业执行时间只使用独立的
`PlanBlock`，不再使用 `CalendarEvent.assignment_block`。

### 3.4 source

```text
ustc_jw             中科大教务系统
ustc_second_class   二课平台
ustc_notice         学校通知/公告
user                用户手动创建
agent               Agent 创建
calendar_sync       系统日历同步
import_file         文件导入
```

### 3.5 importance

```text
low
normal
high
critical
```

`importance` 表示事件整体重要性。考试一般是 `critical`，普通课程默认 `normal`。

### 3.6 attendancePolicy

该字段表示用户对某节课或某门课的出勤策略，用于早晨提醒、逃课风险提示、计划排布和冲突判断。它不只表示“是否点名”，也可以表示小测、课程总结、节假日前风险高、上节课点过本节大概率不点等任意原因。

```text
unknown   未知
must_go   必去
gamble    可以赌
skip      不去
```

默认规则：

```text
course -> unknown
exam -> must_go
second_class -> must_go 或 gamble，取决于是否已报名和是否影响学时
personal -> unknown
```

用户可以用聊天修改：

```text
“把明天计算机原理标成必去”
“这门通识课一般不用去，整门课标成不去”
“这节课上节刚点过，大概率不点，标成可以赌”
“最后一周最后一节有课程总结，把那一节标成必去”
```

`attendanceNote` 保存用户自由备注。备注内容不要求结构化，但 LLM 在做提醒、规划和冲突判断时必须读取。

示例备注：

```text
点名
小测
上节课点过，这节大概率不点
节假日前风险高
老师会讲作业答案
去也可以不听
```

当 `attendancePolicy=gamble` 时，系统应在前一天或当天生成一次出勤决策询问：

```text
这节课目前标记为“可以赌”，你今天要去吗？
```

用户回答后写入：

```text
attendanceDecision: go / skip / undecided
attendanceDecisionAt
```

`attendanceDecision` 表示这一次用户打算去不去；`attendanceOutcome` 表示事后实际结果：

```text
attendanceDecision: undecided / go / skip
attendanceOutcome: unknown / attended / skipped
```

如果用户没有回答，LLM 在当天提醒中应继续标为未决，不应擅自假设用户会去或不去。

### 3.7 listeningMode

`listeningMode` 表示用户是否打算认真听这节课。它和出勤策略独立：用户可能去但不听，也可能不去。

```text
unknown      未知
listen       听讲
not_listen   不听讲
```

`listeningNote` 保存原因或策略，LLM 可读取。

示例：

```text
老师照念 PPT，不如自己写作业
这节讲重点，必须听
去占座但主要补实验报告
```

标记粒度规则：

```text
单节课标记优先级最高：针对某一个 CalendarEvent 生效。
整门课标记优先级次之：针对同一 course/lesson 的所有事件生效。
系统默认值优先级最低。
```

实现上建议通过 `UserOverlay.scope` 区分：

```text
single_event   只覆盖某一节课
course_series  覆盖同一门课/同一教学班的所有课
event_type     覆盖某类事件，例如所有二课
```

### 3.8 个人事件时间与完成策略

定时个人事件使用 `startAt/endAt`。全天个人事件使用北京时间日期区间
`[startDate, endDateExclusive)`，不使用伪造的午夜时间表达全天语义。两组字段
互斥。

个人事件的完成策略为：

```text
auto_after_end       结束后有效状态自动变为 completed，默认
manual_confirmation  结束后进入待确认状态
```

自动完成和待确认均由查询派生，不为重复系列的每个历史 occurrence 批量写入记录。
用户可以明确改为 `completed`、`skipped` 或重新安排。完成确认不发送系统通知；
后续 LLM 可以在 App 打开时读取待确认事件并通过聊天询问。

课程、考试和已报名二课不继承个人事件的自动完成默认值。

### 3.9 个人重复事件

个人重复事件使用 `CalendarEventSeries` 保存模板和基础规则，使用
`CalendarEventOccurrenceException` 保存单次覆盖。首版支持每天、每 N 天、每周
指定一个或多个星期、每 N 周、每月和每 N 月，以及可选的包含式结束日期。

月度重复保留原始日期锚点；当月没有该日期时顺延到月末，之后恢复原锚点。
occurrence 身份由系列 ID 和原始计划本地日期/时间稳定生成，单次改期不改变身份。

系列编辑范围为：

```text
only_this       只写单次例外
this_and_future 截断旧系列并创建新系列
whole_series    更新整个系列模板或规则
```

规则变化后无法对应到 occurrence 的旧例外标记为 `orphaned`，保留历史但不进入
有效日程。详细行为见
`docs/superpowers/specs/2026-07-25-flutter-personal-calendar-event-design.md`。

#### 3.9.1 生产可达性与稀疏锚点（Task 6A 硬门）

以下约束由生产可达性硬门（组合测试）端到端固化，任何回归都不得破坏：

- **范围展开的 occurrence 是有效查询对象，而不是 `calendar_events` 行。**
  查询只在一个有界 Beijing 时间范围内把投影的 occurrence 作为有效对象返回；
  生产 `create_event` 建重复系列不向 `calendar_events` 物化任何 occurrence 行
  （仅写一条 `CalendarEventSeries`）。读取路径同样不物化。
- **编码 locator 是本地实现身份，绝不对模型可见。** `event_v1` / `occ_v1` /
  `series_v1` 编码字符串、`seriesId`、`occurrenceKey`、exception FK id、DB 主键
  都只能存在于内部（ref 绑定目标、依赖行 FK）；工具响应 payload 只允许安全字段
  （标题/时间/状态/scope/ref 令牌）。ref 由运行引用库解码后即可证明内部的
  seriesId + occurrenceKey，但序列化不得外泄任何一个。
- **空 occurrence 例外是稀疏 FK 锚点，无展示效果。** 依赖行（Reminder、
  `ScheduleRelation` 参与方、`TaskEventLink`）需要引用某次 occurrence 时，由
  `ensureOccurrenceAnchor(seriesId, occurrenceKey)` 幂等地创建/复用一条
  `kind='override'`、`overriddenFieldsJson='[]'`、无实际覆盖的 no-op 例外作为 FK
  锚点。锚点只在已批准的 Agent 写事务内产生，不被投影成展示对象，也不改变系列
  语义。

更完整的生产读写实现在 `read-only-agent-handoff.md` 与
`architecture.md` 的对应段落中固化。

## 4. Task

`Task` 表示需要完成的事项，但它本身不一定占用一个固定时间段。

典型例子：

```text
老师布置的作业
考试复习
提交奖学金申请材料
二课报名提醒
去医院预约
```

### 4.1 字段

```text
id
userId
title
description
type
status
priority
deadlineAt
estimatedMinutes
minBlockMinutes
maxBlockMinutes
preferredTimeWindows
avoidTimeWindows
relatedCourseEventIds
relatedCalendarEventIds
source
sourceRecordId
externalId
tags
userNotes
agentNotes
createdBy
updatedBy
createdAt
updatedAt
blockedReason
completedAt
cancelledAt
deletedAt
```

### 4.2 type

```text
assignment     作业
review         复习
application    事务申请
errand         跑腿/线下事务
reading        阅读
project        长期项目
custom         自定义任务
```

### 4.3 status

```text
active       未完成，默认状态
blocked      等待外部条件，由用户明确设置
completed    用户明确确认完成
cancelled    用户明确取消
```

时间流逝和 `PlanBlock` 变化都不得写入 `Task.status`。`blocked` 在界面显示为
“等待条件”，可以填写 `blockedReason`。离开 `blocked` 时清空当前原因，历史由
`ActionLog` 保留。进入 `completed` 时写入 `completedAt`，进入 `cancelled` 时写入
`cancelledAt`，两者互斥。重新打开终态 Task 后回到 `active`，清空终态时间，但不
恢复此前取消的 PlanBlock。终态 Task 必须先重新打开才能进入 `blocked`。

查询层派生三组互相独立的状态：

```text
planningState:     unplanned | planned
deadlineState:     not_applicable | no_deadline | upcoming | due_today | overdue
confirmationState: clear | awaiting_planblock_review
```

- 对 `active` 或 `blocked` Task，至少存在一个未删除、`status=accepted` 且
  `endAt > now` 的 PlanBlock 时，`planningState=planned`，否则为 `unplanned`。
- `active` 或 `blocked` Task 中，已结束但仍为 `accepted` 的 PlanBlock 进入待确认
  投影，不再算未来规划。
- `completed` 和 `cancelled` Task 固定派生为 `planningState=unplanned`、
  `confirmationState=clear`；明确保留的 PlanBlock 仍可作为历史或日程项显示。
- `completed` 和 `cancelled` Task 的截止状态为 `not_applicable`。
- `active` 和 `blocked` Task 按 `Asia/Shanghai` 计算截止状态；同日且尚未超过
  截止时刻为 `due_today`，`now > deadlineAt` 后立即为 `overdue`。
- 派生状态只用于显示、筛选和 Agent 读取，不写数据库，不生成操作日志，也不占用
  一步撤回槽。

### 4.4 任务与日程的关系

作业录入后先生成 `Task`：

```text
title: 嵌入式实验报告
deadlineAt: 周五 23:59
estimatedMinutes: 120
```

当系统规划时间后，生成一个或多个 `PlanBlock`：

```text
周三 20:00-21:00 写嵌入式实验报告
周四 19:30-20:30 写嵌入式实验报告
```

规划不会替代 `Task` 本体。即使已经生成一个或多个 `PlanBlock`，`Task` 仍保留在截止事项带中，用于表达截止时间和整体状态；`PlanBlock` 只表达具体执行时间。`estimatedMinutes` 只是可选的初始安排参考，PlanBlock 不用于推断完成百分比、实际执行分钟或剩余工时。

### 4.5 Task 在周日程中的显示

`Task` 没有固定的开始和结束时间，因此不能伪装成普通 `CalendarEvent` 放入时间网格。周视图在时间网格上方提供两层截止事项带：

```text
未定截止层
截止事项层
学校节次与真实时间网格
```

未定截止层：

```text
- 显示所有 status 未完成且 deadlineAt 为空的 Task。
- 这些 Task 在每个选中周都显示，不虚构属于某一天。
- 如果没有符合条件的 Task，整层隐藏。
- Task 生成 PlanBlock 后仍保留在这一层，直到用户补充 deadlineAt、完成、取消或删除 Task。
- 已完成但没有 deadlineAt 的 Task 不继续占用这一层，仍可在任务历史中查看。
```

截止事项层：

```text
- deadlineAt 落在选中周内的 Task 按周一至周日定位。
- Task 生成 PlanBlock 后仍保留在截止事项层。
- 已完成 Task 在截止日期所在周保留但弱化，允许通过“隐藏已完成”筛选隐藏。
- 已逾期且未完成的 Task 在当前周持续显示，直到完成、取消或删除。
```

提醒状态：

```text
今日截止  黄色任务块，右上角显示黄色圆圈感叹号，并写明“今日截止”。
已经逾期  红色任务块，右上角显示红色圆圈感叹号，并写明逾期时长。
已完成    降低对比度并显示完成标记。
```

颜色不能成为唯一提示。圆圈感叹号必须带有可访问语义，任务块中也必须显示文字状态。“今日截止”和“已经逾期”的图标表示截止风险；日程事件上的红色圆圈感叹号表示已确认冲突，两者在详情和无障碍标签中必须明确区分。

点击 `Task` 打开任务详情，至少显示截止时间、持久化状态、派生规划状态和截止状态、预计工时、未来 PlanBlock 数量与总时长，以及关联的 `PlanBlock`。未来块总时长只表示日程占用，不表示完成进度。`Task` 本身不参与时间冲突判断；只有进入时间网格的 `PlanBlock` 才参与重叠和 `ScheduleRelation` 判断。

## 5. PlanBlock

`PlanBlock` 是为了完成某个 `Task` 而安排出来的时间段。它和 `CalendarEvent` 很像，但语义不同：它是可调整的计划块。

在周视图中，`PlanBlock` 按真实 `startAt` 和 `endAt` 放入学校节次与真实时间混合网格。它使用区别于课程和固定事件的视觉样式，并保持与父 `Task` 的颜色或标识关联：

```text
suggested   虚线边框，表示尚未确认
accepted    实线样式，表示用户已接受
done        保留但弱化，并显示完成标记
```

`accepted` PlanBlock 在 `endAt <= now` 后仍保持原数据库状态，但查询时派生为
“待确认”。首版提供集中待确认列表，并在日程块和 Task 详情中提供入口；仅因时间块
结束不发送系统通知。

点击 `PlanBlock` 打开执行块详情，并能继续进入父 `Task`。删除、跳过或重排 `PlanBlock` 不会自动删除父 `Task`，也不会移除截止事项带中的任务。

### 5.1 字段

```text
id
userId
taskId
title
startAt
endAt
status
locked
generatedBy
reason
locationPreference
energyLevel
sourceCalendarEventIds
rescheduledToPlanBlockId
createdAt
updatedAt
deletedAt
```

### 5.2 status

```text
suggested    Agent 建议，还未确认
accepted     用户确认
done         已执行
skipped      跳过
rescheduled  已重排
cancelled    取消
```

### 5.3 结束后的确认

用户处理已结束的 `accepted` PlanBlock 时可以选择：

```text
done         确认本次计划已执行
skipped      确认本次没有执行
rescheduled  旧块关联到一个新的 accepted PlanBlock
稍后处理     不修改状态，继续留在待确认列表
```

`done` 不记录实际执行分钟或完成百分比。确认本次执行后，App 再单独询问整个 Task
是否完成；只有用户确认才把父 Task 改为 `completed`。所有 PlanBlock 均为 `done`
也不会自动完成 Task。

完成 Task 前先展示未来 `accepted` PlanBlock 的影响摘要，用户可以全部取消或逐项
处理，包括明确保留。保留块继续关联父 Task，并显示“父任务已完成”。已经结束但
未确认的块保留为真实历史记录，但父 Task 进入终态后不再进入主动待确认列表。

取消 Task 时展示影响摘要，并在同一事务中取消所有未来 `accepted` PlanBlock。
`blocked` 不修改 PlanBlock。重新打开 Task 保留全部历史，但不自动恢复已取消的块。

### 5.4 locked

`locked=true` 表示用户明确不希望 Agent 自动移动这个时间块。

示例：

```text
每天 20:00-22:00 娱乐时间
和朋友约好的开黑
已经答应别人的约饭
```

### 5.5 embedded planning

`PlanBlock` 可以被安排在某个 `CalendarEvent` 内部，但必须通过 `ScheduleRelation` 记录原因。

适合嵌入的典型情况：

```text
课程 attendancePolicy=skip
课程 listeningMode=not_listen
用户明确说“这节课适合写作业”
用户决定翘课打游戏或参加二课，并接受风险
```

不适合嵌入的典型情况：

```text
考试
attendancePolicy=must_go 且 listeningMode=listen
用户锁定的不可移动安排
备注显示有小测、课程总结、实验验收等
```

## 6. ScheduleRelation

`ScheduleRelation` 表示两个时间安排之间的关系。它解决一个关键问题：时间重叠不一定是冲突。

典型情况：

```text
个性化选课：两门课同一时间，但用户需要自己决定去哪一门。
课上写作业：如果这节课标为“不去”或“不听讲”，它可能是很好的作业时间。
翘课娱乐或二课：不一定是产品要鼓励的行为，但产品要能真实记录和规划。
```

### 6.1 字段

```text
id
userId
primaryType
primaryId
relatedType
relatedId
relationType
conflictState
resolution
reason
userDecision
agentSuggestion
createdBy
createdAt
updatedAt
```

### 6.2 relationType

```text
time_overlap        时间重叠
alternative_choice  二选一或多选一
embedded_work       在另一个事件期间安排任务
replacement         用一个事件替代另一个事件
soft_warning        可以共存但需要提醒
dependency          一个事件依赖另一个事件
```

### 6.3 conflictState

冲突状态只保留两类：

```text
conflict      冲突，需要用户决策或调整
non_conflict  不冲突，可以按当前安排共存
```

默认优先序（2026-08-01 修复轮落地）：

```text
1. 显式 occurrence 关系（conflict / no_conflict）优先于推导结果；
2. 显式系列规则（ScheduleRelationRule）其次；
3. 定时时间重叠默认推导为 conflict（origin=derivedOverlap）；
4. 其余为推导 no_conflict。
```

即：时间重叠默认按冲突处理，用户显式的 conflict/no_conflict 决策覆盖推导结果；
显式 no_conflict 能抑制默认重叠冲突，显式 conflict 即使无时间重叠仍然生效。
全天事项只因日期相同不会自动成为冲突。

判断规则不应只看时间重叠，而应读取：

```text
attendancePolicy
attendanceDecision
attendanceDecisionAt
attendanceNote
attendanceOutcome
listeningMode
listeningNote
用户锁定状态
任务优先级
二课/考试/事务是否不可错过
```

### 6.4 resolution

```text
undecided       未决
prefer_primary  优先 primary
prefer_related  优先 related
allow_both      两者都保留
ask_user        需要询问用户
```

### 6.5 ScheduleRelationRule

`ScheduleRelation` 只保存一对具体时间安排的分类。用户选择“本次及未来”时，必须
另存一条由两个精确稳定系列身份和 `effectiveFrom` 确定的结构化
`ScheduleRelationRule`：

```text
id
userId
primarySeriesType
primarySeriesId
relatedSeriesType
relatedSeriesId
effectiveFrom
effectiveThrough
relationType
conflictState
resolution
reason
createdBy
createdAt
updatedAt
```

`primarySeriesType` 和 `relatedSeriesType` 只能引用明确支持的
`course_series` 或 `calendar_event_series`。两侧都必须具有稳定系列身份；任一侧
只有 occurrence 身份时，`currentAndFuture` 分类必须拒绝。

`effectiveFrom` 是必填的 `Asia/Shanghai` 本地日期。`effectiveThrough` 可空：

- 任一参与系列有有限结束日期时，取两侧所有有限结束日期中最早的日期；
- 两侧系列都没有有限结束日期时保持为空；
- 非空时不得早于 `effectiveFrom`。

规则由精确的两个系列身份和 `effectiveFrom` 确定，不得通过任意固定 horizon
伪造结束日期。

查询层只把规则应用于两侧系列中日期落在范围内且时间语义兼容的 projected
occurrence。针对某一次明确保存的 `ScheduleRelation` 优先于系列规则。规则必须
使用独立结构化表和字段，不得隐藏在 JSON，也不得预先展开为无限或仅
occurrence 的关系记录。

### 6.6 示例

课上写作业：

```json
{
  "primaryType": "calendar_event",
  "primaryId": "course_event_01",
  "relatedType": "plan_block",
  "relatedId": "plan_01",
  "relationType": "embedded_work",
  "conflictState": "non_conflict",
  "resolution": "allow_both",
  "reason": "该课标记为不听讲，用户允许在课上写作业"
}
```

翘课参加二课：

```json
{
  "primaryType": "calendar_event",
  "primaryId": "course_event_02",
  "relatedType": "calendar_event",
  "relatedId": "second_class_01",
  "relationType": "replacement",
  "conflictState": "non_conflict",
  "resolution": "prefer_related",
  "reason": "课程标记为不去，二课已报名且需要学时"
}
```

两门课同一时间：

```json
{
  "primaryType": "calendar_event",
  "primaryId": "course_event_03",
  "relatedType": "calendar_event",
  "relatedId": "course_event_04",
  "relationType": "alternative_choice",
  "conflictState": "conflict",
  "resolution": "ask_user",
  "reason": "两门课时间重叠，且均未设置不去或不听讲"
}
```

## 7. SourceRecord

`SourceRecord` 保存外部系统导入记录的摘要和来源，用于去重、追踪、重新同步。

不要在 `SourceRecord` 中长期保存完整敏感原文。必要时只保留脱敏摘要或加密后的最小字段。

### 7.1 字段

```text
id
userId
source
sourceSystem
sourceType
externalId
fingerprint
fetchedAt
validFrom
validTo
rawSummary
rawRef
syncBatchId
status
createdAt
updatedAt
```

### 7.2 sourceType

```text
jw_course_schedule
jw_exam
jw_grade
second_class_activity
second_class_registration
notice
manual_import
```

### 7.3 externalId 与 fingerprint

`externalId` 用于外部系统稳定 ID。课表事件可以这样生成：

```text
semesterId + lessonId + scheduleGroupId + date + startTime + endTime
```

`fingerprint` 用于接口没有稳定 ID 时去重：

```text
hash(source + title + startAt + endAt + location)
```

## 8. UserOverlay

`UserOverlay` 表示用户对导入事件的个人修正。这样做的好处是：下次同步教务系统时，不会把用户自己的标记冲掉。

它既要支持“整门课默认标记”，也要支持“某一节课单独标记”。当两者冲突时，单节课覆盖优先。

### 8.1 字段

```text
id
userId
targetType
targetId
scope
seriesKey
displayTitle
displayLocation
attendancePolicy
attendanceDecision
attendanceDecisionAt
attendanceNote
attendanceOutcome
listeningMode
listeningNote
importance
hidden
color
tags
userNotes
reminderOverride
createdAt
updatedAt
```

### 8.2 scope

```text
single_event   只作用于一个 CalendarEvent
course_series  作用于同一门课/同一教学班的全部 CalendarEvent
event_type     作用于某类事件
global         全局偏好
```

### 8.3 示例

用户说：

```text
“明天这节课有小测，标成必去”
```

系统不修改教务源数据，只创建/更新：

```json
{
  "targetType": "calendar_event",
  "targetId": "event_123",
  "scope": "single_event",
  "attendancePolicy": "must_go",
  "attendanceNote": "小测",
  "userNotes": "这一节课有小测"
}
```

用户说：

```text
“这门课一般不用去，整门课标成不去”
```

则创建：

```json
{
  "targetType": "course_series",
  "seriesKey": "ustc_jw:semester:lesson",
  "scope": "course_series",
  "attendancePolicy": "skip",
  "userNotes": "用户上完第一节课后的经验判断"
}
```

用户说：

```text
“这节上节课刚点过，可以赌，明天提醒我决定去不去”
```

则创建：

```json
{
  "targetType": "calendar_event",
  "targetId": "event_456",
  "scope": "single_event",
  "attendancePolicy": "gamble",
  "attendanceDecision": "undecided",
  "attendanceNote": "上节课刚点过，这节大概率不点"
}
```

用户说：

```text
“这门课我去但不听，适合写作业”
```

则创建：

```json
{
  "targetType": "course_series",
  "seriesKey": "ustc_jw:semester:lesson",
  "scope": "course_series",
  "attendancePolicy": "must_go",
  "listeningMode": "not_listen",
  "listeningNote": "去占位置，但课堂效率低，适合写作业"
}
```

## 9. Reminder

提醒可以挂在 `CalendarEvent`、`Task` 或 `PlanBlock` 上。

### 9.1 字段

```text
id
userId
targetType
targetId
triggerType
offsetMinutes
triggerAt
channel
messageTemplate
enabled
createdBy
createdAt
updatedAt
```

### 9.2 triggerType

```text
relative_before_start
relative_before_deadline
absolute_time
daily_digest
smart_morning_brief
attendance_decision_check
```

### 9.3 channel

```text
system_notification
in_app
push
email
sms
wechat
```

第一版只需要：

```text
system_notification
in_app
```

`system_notification` 表示由 Windows、Android 或 iOS 的平台适配器显示的本机通知，
不依赖远程推送服务。`push` 保留给未来可能的远程推送。

首版 Windows 是未打包的开发机验证版：它完整实现 Reminder 计算、持久化、App 内
状态和进程运行期间的 Windows 通知，但不承诺 App 关闭后的可靠触发与取消。完整
后台投递由后续 MSIX Windows 构建或 Android/iOS 适配器实现，不改变 Reminder
领域模型。

第一版的类型默认值：

```text
普通课程             开始前 15 分钟
考试                 开始前 24 小时和 2 小时
已报名二课           开始前 2 小时
定时个人日程         开始前 15 分钟
全天个人日程         默认不提醒
Task                 截止前 24 小时和 2 小时
PlanBlock            开始前 10 分钟
```

单个对象可以覆盖类型默认值，设置页可以关闭某一类型的默认提醒。对象被取消、完成
或隐藏后必须使尚未触发的 Reminder 失效；时间变化后必须重算持久化计划。运行中的
平台适配器按最新记录取消或重新安排其进程生命周期内的通知。

第一版不为“今日截止 Task”或“逾期 Task”生成每天固定时间的通知。它们只在截止事项带中显示黄色或红色警告；未来由 LLM 每日简报统一提醒。通知权限被拒绝时，App 内提醒仍然保留。

### 9.4 Schema 7 依赖目标规则与 31 天提醒对账地平线

重复系列的依赖目标遵循 Schema 7（`calendar_event_occurrence_exceptions` 稀疏
锚点）规则：

- **Reminder / 关系 / Task 链接 对重复 occurrence 的引用走 occurrence-exception
  FK**，而不是（不存在的）materialized `calendar_events` 行。Reminder 行
  `occurrenceExceptionId`、`ScheduleRelation` 的 `left/rightOccurrenceExceptionId`、
  `TaskEventLink.occurrenceExceptionId` 都引用同一幂等 no-op 锚点。
- **提醒对账只在 31 天界限内展开**：一次对账从当前北京日期推进至其后 30 天（共
  31 天，含两端），绝不无界展开。对每次有效 timed occurrence 的可继承 offsets，
  用一个复用的 no-op 锚点持久化未来 desired 提醒；被取消/删除/落出窗口的
  occurrence 的未来 desired 提醒被取消，已投递/错过/失败的历史保留。all-day 系列
  默认空 offsets，不产生提醒行。
- 锚点创建仅在已批准 Agent 写事务内进行（嵌套在同一原子单元中）；锚点自身
  `kind='override'` 且空覆盖，任何时刻都不应产生展示效果。

`ActionLog` 是 Agent 可靠性的关键。凡是 Agent 或用户对日程、任务、外部系统做了重要操作，都应记录。

### 10.1 字段

```text
id
userId
actorType
actorId
actionType
targetType
targetId
summary
beforeState
afterState
requiresConfirmation
confirmationStatus
confirmedAt
externalEffect
riskLevel
createdAt
```

### 10.2 actorType

```text
user
agent
system
connector
```

### 10.3 riskLevel

```text
low       读取、普通提醒
medium    新增或移动日程
high      删除、大范围修改、提交报名
critical  涉及成绩、账号、安全、不可逆提交
```

### 10.4 常见 actionType

```text
import_schedule
create_event
update_event
create_task
plan_task
create_user_overlay
record_attendance_decision
record_listening_mode
create_schedule_relation
update_permission_policy
move_jw_course_day        agent 整日移动/清除教务课程（critical，永远确认）
jw_day_move               user 手动界面整日移动
jw_day_move_retarget      user 手动界面重定向移动
jw_day_move_clear         user 手动界面清除移动
undo_jw_day_move          一步撤回恢复被清除的移动
open_second_class_registration_page
```

其中 `record_attendance_decision` 用于记录“可以赌”的课最终去不去，例如：

```text
用户昨天/今天回答：去 / 不去 / 还没定
```

### 10.5 确认规则

风险动作不使用硬编码确认规则，而是先查询 `AgentPermissionPolicy`。

默认策略：

```text
读取课表：不需要确认
导入课表：首次确认，之后可放行
新增普通日程：首次确认，之后可放行
移动单个 Agent 生成的 PlanBlock：首次确认，之后可放行
移动用户锁定的时间块：始终确认
移动多个日程：始终确认，除非用户在设置中明确放宽
删除日程：始终确认
打开二课报名页面：只允许打开对应的学校官方页面，不得填写或提交报名
提交校园事务申请：始终确认，critical 动作建议不允许完全免确认
```

确认弹窗应包含：

```text
确认本次操作
取消
此类型以后不再确认
前往权限设置
```

每次权限放宽都必须写入 `ActionLog`。

## 11. AgentPermissionPolicy

`AgentPermissionPolicy` 表示用户对某类 Agent 操作授予的权限。它让系统既能保持安全，又能在用户熟悉后减少反复确认。

### 11.1 字段

```text
id
userId
actionType
targetType
riskLevel
confirmationMode
scope
enabled
firstConfirmedAt
lastConfirmedAt
expiresAt
createdBy
updatedBy
createdAt
updatedAt
```

### 11.2 confirmationMode

```text
always_ask       每次都问
ask_first_time   第一次问，之后自动允许
always_allow     总是允许
always_deny      总是禁止
```

### 11.3 示例

```json
{
  "actionType": "create_event",
  "targetType": "personal",
  "riskLevel": "medium",
  "confirmationMode": "ask_first_time",
  "scope": "user_default",
  "enabled": true
}
```

权限设置页至少应支持：

```text
查看所有权限项
按风险等级筛选
恢复默认
单独调整某类操作
查看最近一次权限变更记录
```

## 12. KnowledgeItem

`KnowledgeItem` 用于校园知识库，不直接进入日程轴，但 Agent 回答和推荐会引用它。

### 12.1 字段

```text
id
source
title
content
url
publishedAt
fetchedAt
department
category
tags
embeddingRef
summary
validFrom
validTo
status
```

### 12.2 示例

```text
教务处通知
学工办通知
二课活动说明
奖学金申请指南
校医院办事流程
图书馆规则
```

## 13. 课表导入映射

中科大教务课表主数据源为：

```text
get-data -> lessonIds -> datum -> lessonList + scheduleList
```

### 13.1 lessonList 映射

```text
lessonList[id].courseName       -> CalendarEvent.title
lessonList[id].code             -> CalendarEvent.external course code
lessonList[id].courseTypeName   -> tags/courseType
lessonList[id].teacherAssignmentList -> participants/teachers
lessonList[id].scheduleRemark   -> agentNotes/source notes
```

### 13.2 scheduleList 映射

```text
scheduleList.date                         -> startAt/endAt date
scheduleList.startTime                    -> startAt time
scheduleList.endTime                      -> endAt time
scheduleList.room.nameZh                  -> locationName
scheduleList.room.building.nameZh         -> buildingName
scheduleList.room.building.campus.nameZh  -> campusName
scheduleList.customPlace                  -> fallback locationName
scheduleList.weekIndex                    -> metadata.weekIndex
scheduleList.weekday                      -> metadata.weekday
scheduleList.personName                   -> participants.teacher
```

### 13.3 重复合并

同一节课多位老师可能产生多行 `scheduleList`。导入前按以下 key 合并：

```text
lessonId + scheduleGroupId + date + startTime + endTime + room/customPlace + exerciseClass
```

合并后：

```text
personName -> teachers[]
teacherId -> teacherIds[]
personId -> personIds[]
```

### 13.4 时间解析

教务接口时间为数字：

```text
945  -> 09:45
1120 -> 11:20
1930 -> 19:30
```

转换规则：

```text
左侧补零到 4 位，再按 HHmm 解析。
```

## 14. 示例对象

### 14.1 导入课程事件

```json
{
  "id": "event_01",
  "userId": "user_01",
  "title": "示例课程",
  "type": "course",
  "status": "active",
  "startAt": "2026-03-02T09:45:00+08:00",
  "endAt": "2026-03-02T11:20:00+08:00",
  "timezone": "Asia/Shanghai",
  "locationName": "示例教室",
  "buildingName": "示例教学楼",
  "campusName": "西区",
  "source": "ustc_jw",
  "externalId": "ustc_jw:semester:lesson:group:date:start:end",
  "importance": "normal",
  "attendancePolicy": "unknown",
  "attendanceDecision": "undecided",
  "attendanceDecisionAt": null,
  "attendanceNote": null,
  "attendanceOutcome": "unknown",
  "listeningMode": "unknown",
  "listeningNote": null,
  "tags": ["course"],
  "participants": [
    {
      "role": "teacher",
      "name": "张*"
    }
  ]
}
```

### 14.2 作业任务

```json
{
  "id": "task_01",
  "userId": "user_01",
  "title": "完成示例课程作业",
  "type": "assignment",
  "status": "active",
  "priority": "high",
  "deadlineAt": "2026-03-06T23:59:00+08:00",
  "estimatedMinutes": 120,
  "minBlockMinutes": 45,
  "maxBlockMinutes": 90,
  "relatedCourseEventIds": ["event_01"],
  "source": "user",
  "tags": ["assignment"]
}
```

### 14.3 规划时间块

```json
{
  "id": "plan_01",
  "userId": "user_01",
  "taskId": "task_01",
  "title": "写示例课程作业",
  "startAt": "2026-03-04T20:00:00+08:00",
  "endAt": "2026-03-04T21:30:00+08:00",
  "status": "accepted",
  "locked": false,
  "generatedBy": "user",
  "reason": "用户安排在课程和晚饭之后"
}
```

## 15. Agent 工具边界

Agent 不直接改数据库。它应通过受控工具函数操作。

### 15.1 读取工具

```text
get_events(range)
get_tasks(filter)
get_free_time(range, constraints)
search_knowledge(query)
get_source_records(source, range)
```

#### 15.1.1 查询式重复检索只返回受限到 `whole_series` 的系列目标

`get_schedule(query=...)` 的纯查询重复检索（无日期、无 view）经过有界搜索返回
**系列目标**，其 `availableScopes` 只允许 `['whole_series']`——只做整系列预检，
绝不伪造单个 occurrence 时间。带日期范围的 `view=management` 才返回具体
occurrence 目标（三个 scope：`only_this`/`this_and_future`/`whole_series`），
且绝不在 payload 中外泄 locator / seriesId / occurrenceKey / DB id。

### 15.2 写入工具

```text
create_event(input)
update_event(id, patch)
create_task(input)
plan_task(taskId, constraints)
create_user_overlay(targetId, patch)
record_attendance_decision(eventId, decision)
record_listening_mode(eventId, mode)
create_schedule_relation(input)
set_reminder(targetId, rule)
update_permission_policy(actionType, mode)
```

### 15.3 外部系统工具

```text
import_jw_course_table()
import_jw_exams()
search_second_class_activity()
prepare_second_class_registration()
open_second_class_registration_page(activityId)
```

`prepare_second_class_registration()` 只能整理活动摘要和报名注意事项。
`open_second_class_registration_page(activityId)` 只能根据已查询到的活动 ID 打开
学校官方页面，不接受任意 URL，不填写表单，也不提交或取消报名。二课报名与取消报名
始终由用户在官方页面亲自完成，`AgentPermissionPolicy` 不得放宽这条边界。

## 16. 首版字段与未来空壳

第一版完整实现 `CalendarEvent`、`Task`、`PlanBlock`、`ScheduleRelation`、
`ScheduleRelationRule` 和 `ActionLog` 的首版字段及确定性行为。

考虑到首版完成后将立即尝试接入 LLM，首版数据库迁移同时创建
`AgentPermissionPolicy` 的空表，并在领域层保留枚举和仓储接口。该空壳在首版：

```text
不创建默认授权记录
不参与任何操作的权限判断
不提供 Agent 权限设置界面
不允许 Agent 执行写操作
不改变二课报名必须由用户亲自在官方页面完成的永久边界
```

LLM 接入前必须另行完成 Agent 工具、风险分级、确认流程和权限设置设计，之后才能
启用这张表。存在空表不表示首版已经实现 Agent 权限功能。

### 16.1 CalendarEvent MVP

```text
id
userId
title
description
type
status
startAt
endAt
timezone
allDay
startDate
endDateExclusive
seriesId
occurrenceKey
locationName
buildingName
campusName
source
externalId
importance
color
completionPolicy
attendancePolicy
attendanceDecision
attendanceDecisionAt
attendanceNote
attendanceOutcome
listeningMode
listeningNote
tags
userNotes
createdAt
updatedAt
deletedAt
```

### 16.2 CalendarEventSeries MVP

```text
id
userId
title
description
type
status
timezone
allDay
anchorStartAt
durationMinutes
anchorStartDate
durationDays
frequency
interval
weekdays
untilDate
locationName
importance
color
completionPolicy
tags
userNotes
createdAt
updatedAt
deletedAt
```

### 16.3 CalendarEventOccurrenceException MVP

```text
id
userId
seriesId
occurrenceKey
originalStartAt
originalStartDate
overriddenFields
overridePayload
status
orphaned
deletedAt
createdAt
updatedAt
```

### 16.4 Task MVP

```text
id
userId
title
type
status
priority
deadlineAt
estimatedMinutes
blockedReason
completedAt
cancelledAt
relatedCalendarEventIds
tags
createdAt
updatedAt
deletedAt
```

### 16.5 PlanBlock MVP

```text
id
userId
taskId
title
startAt
endAt
status
locked
reason
rescheduledToPlanBlockId
createdAt
updatedAt
deletedAt
```

### 16.6 ScheduleRelation MVP

```text
id
userId
primaryType
primaryId
relatedType
relatedId
relationType
conflictState
resolution
reason
createdAt
updatedAt
```

### 16.7 ScheduleRelationRule MVP

```text
id
userId
primarySeriesType
primarySeriesId
relatedSeriesType
relatedSeriesId
effectiveFrom
effectiveThrough (nullable)
relationType
conflictState
resolution
reason
createdAt
updatedAt
```

### 16.8 ActionLog MVP

```text
id
userId
actorType
actionType
targetType
targetId
summary
riskLevel
createdAt
```

### 16.9 AgentPermissionPolicy 预留空壳

```text
id
userId
actionType
targetType
riskLevel
confirmationMode
enabled
updatedAt
```

## 17. JwDayMove（整日教务课程移动）

`JwDayMove` 记录某一天的全部 `ustc_jw` 定时 course 事件整体移动到另一天（北京日历
日，YYYY-MM-DD）。它是移动覆盖记录，不是事件改写：源 `CalendarEvent` 永不物理
修改，日程展示投影按移动记录显示；出勤/听讲/隐藏等 `UserOverlay` 始终附着在对应
课程上。

```text
id
accountId
sourceDate         源日期（YYYY-MM-DD）
targetDate         目标日期
createdAt
updatedAt
```

规则：

- 按账号隔离；`(accountId, sourceDate)` 唯一，同一源日期再次移动为重定向（retarget）。
- 记录不带 semester id、不带事件 id 列表、不带外部身份——Agent 工具和手动界面都
  只传日期。
- 投影按事件的原始来源日期匹配移动记录，绝不按已移动的展示日期匹配：A->B 后建立
  B->C 只移动 B 原生课程，不链式搬运 A 已移走的课程。
- 只移动 `ustc_jw` 来源的定时 `course` 事件且来源记录有效；考试、二课、个人事件、
  全天事项和 PlanBlock 从不移动。
- 移动预览只统计源日符合条件的课程标题（数量与标题，无 id）。
- 移动/清除经手动界面时写入"一步撤回"槽（UndoService，kind=`jw_day_move`），
  清除后可撤回恢复；Agent 写入不占用撤回槽。
- 数据库 schema 当前为版本 5（`AppDatabase.schemaVersion`）。
