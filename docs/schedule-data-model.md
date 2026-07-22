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
- Agent 不自动提交二课报名、事务申请等外部写操作，除非用户已明确授予相应类型权限。
- 对 critical 风险动作，即使用户放宽权限，也建议保留二次确认或短时间撤销窗口。
```

## 2. 核心对象

项目不应只用一个 `Event` 表承载所有东西。建议拆成以下核心对象：

| 对象 | 含义 | 示例 |
| --- | --- | --- |
| `CalendarEvent` | 有明确开始和结束时间的事件 | 课程、考试、二课、聚餐 |
| `Task` | 有目标或截止时间，但不一定有固定执行时间 | 作业、复习、填表 |
| `PlanBlock` | 系统或用户安排出来的执行时间段 | 周三 20:00-21:30 写作业 |
| `ScheduleRelation` | 两个时间安排之间的关系和冲突判断 | 课上写作业、翘课参加二课 |
| `SourceRecord` | 从外部系统导入的原始记录摘要 | 教务课表记录、二课活动记录 |
| `UserOverlay` | 用户对导入数据的个人修正 | 标记必去、隐藏、改显示名 |
| `Reminder` | 提醒规则 | 上课前 20 分钟提醒 |
| `ActionLog` | Agent 或用户做过的动作记录 | 导入课表、修改时间 |
| `AgentPermissionPolicy` | 用户授予 Agent 的风险操作权限 | 二课报名前是否确认 |
| `KnowledgeItem` | 校园知识库条目 | 通知、办事指南、校史资料 |

关系大致如下：

```text
SourceRecord -> CalendarEvent
Task -> PlanBlock
CalendarEvent -> Reminder
CalendarEvent -> UserOverlay
CalendarEvent/PlanBlock -> ScheduleRelation
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
locationName
buildingName
campusName
geo
source
sourceRecordId
externalId
confidence
importance
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
assignment_block    作业执行时间块
second_class        二课活动
personal            普通个人事项
entertainment       娱乐
meal                吃饭
campus_affair       校园事务
travel              通勤/校区移动
study               自习/复习
system              系统生成的辅助事件
```

### 3.3 status

```text
active      正常
tentative   暂定
cancelled   取消
completed   已完成
hidden      用户隐藏
```

冲突不放在 `CalendarEvent.status` 中表达，而由 `ScheduleRelation.conflictState` 表达。原因是时间重叠不一定是冲突，同一时间上课、写作业、娱乐、二课都有可能是用户有意安排。

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
progress
userNotes
agentNotes
createdBy
updatedBy
createdAt
updatedAt
completedAt
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
todo
planned
in_progress
blocked
completed
cancelled
```

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

这些 `PlanBlock` 同时可以显示在日程时间轴上。

## 5. PlanBlock

`PlanBlock` 是为了完成某个 `Task` 而安排出来的时间段。它和 `CalendarEvent` 很像，但语义不同：它是可调整的计划块。

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
createdAt
updatedAt
```

### 5.2 status

```text
suggested    Agent 建议，还未确认
accepted     用户确认
active       已进入日程
done         已完成
skipped      跳过
rescheduled  已重排
cancelled    取消
```

### 5.3 locked

`locked=true` 表示用户明确不希望 Agent 自动移动这个时间块。

示例：

```text
每天 20:00-22:00 娱乐时间
和朋友约好的开黑
已经答应别人的约饭
```

### 5.4 embedded planning

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

### 6.5 示例

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
push
in_app
email
sms
wechat
```

第一版只需要：

```text
push
in_app
smart_morning_brief
```

## 10. ActionLog

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
submit_second_class_registration
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
报名二课：始终确认，除非用户明确放宽该类权限
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
  "status": "todo",
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
  "status": "suggested",
  "locked": false,
  "generatedBy": "agent",
  "reason": "避开课程和晚饭时间，距离截止时间还有 2 天"
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
submit_second_class_registration()
```

其中 `submit_second_class_registration()` 默认必须要求用户确认；如果用户在权限设置中放宽该类权限，仍应在执行前展示清晰的操作摘要。

## 16. MVP 最小字段

第一版可以先只实现这些字段，不必一次做全。

### 16.1 CalendarEvent MVP

```text
id
userId
title
type
status
startAt
endAt
locationName
buildingName
campusName
source
externalId
importance
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
```

### 16.2 Task MVP

```text
id
userId
title
type
status
priority
deadlineAt
estimatedMinutes
relatedCalendarEventIds
tags
createdAt
updatedAt
```

### 16.3 PlanBlock MVP

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
createdAt
updatedAt
```

### 16.4 ScheduleRelation MVP

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

### 16.5 ActionLog MVP

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

### 16.6 AgentPermissionPolicy MVP

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

## 17. 下一步

建议按这个顺序推进：

```text
1. 用本文模型创建一份脱敏 datum 样例。
2. 写转换脚本：ustc_jw_datum.json -> calendar_events.json。
3. 验证重复课程合并、时间解析、externalId 去重。
4. 再研究考试安排接口，并复用 CalendarEvent 模型。
5. 设计移动端首页“今天”视图的数据需求。
```
