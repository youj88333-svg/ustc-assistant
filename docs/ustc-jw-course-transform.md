# 中科大教务课表转换规则

本文定义如何把综合教务系统 `datum` 接口返回的数据转换为项目内部的 `CalendarEvent`、`SourceRecord`、`UserOverlay` 和 `ScheduleRelation`。

参考输入样例：

```text
examples/ustc-jw-datum.sample.json
```

参考输出样例：

```text
examples/calendar-events.sample.json
```

## 1. 输入结构

`datum` 返回结构：

```json
{
  "result": {
    "lessonList": [],
    "scheduleList": [],
    "scheduleGroupList": []
  }
}
```

字段分工：

- `lessonList`：课程/教学班元数据。
- `scheduleList`：每一次具体上课记录，是生成日程的主数据源。
- `scheduleGroupList`：排课组、人数和学时信息，第一版只做辅助。

## 2. 基本转换流程

```text
1. 读取 lessonList，按 lesson.id 建立 lessonMap。
2. 读取 scheduleGroupList，按 group.id 建立 groupMap。
3. 读取 scheduleList。
4. 对 scheduleList 按合并 key 分组。
5. 每个分组生成一个 CalendarEvent。
6. 每个 CalendarEvent 生成一个 SourceRecord。
7. 应用用户已有 UserOverlay。
8. 对时间重叠事件生成 ScheduleRelation 候选。
```

## 3. 合并规则

教务 `scheduleList` 可能出现同一节课多位老师导致的重复行。不能一行生成一个事件。

合并 key：

```text
lessonId + scheduleGroupId + date + startTime + endTime + placeKey + exerciseClass
```

`exerciseClass` 不能直接按原始 JSON 值比较。真实接口会对同一节课的不同教师行
分别返回 `false` 和 `null`。转换前必须规范化：

```text
null / false / "" -> "none"
true               -> "true"
其他对象或值        -> 排序后的规范 JSON
```

规范化后，`false` 与空值的教师行会合并到同一事件并聚合 `participants[]`；
明确为 `true` 或内容不同的习题课信息仍保留为不同分组。

`placeKey` 规则：

```text
if room.code exists:
  placeKey = room.code
else if customPlace exists:
  placeKey = customPlace
else:
  placeKey = "unknown-place"
```

合并字段：

```text
personName -> participants[]
teacherId -> participants[].teacherId
personId -> participants[].personId
```

如果同一 key 下出现多个老师，只生成一个 `CalendarEvent`，并把老师列表聚合。

## 4. 时间解析

教务时间字段是数字：

```text
945  -> 09:45
1120 -> 11:20
1930 -> 19:30
```

转换规则：

```text
1. 转成字符串。
2. 左侧补零到 4 位。
3. 前 2 位作为小时，后 2 位作为分钟。
4. 与 schedule.date 拼接。
5. 时区固定为 Asia/Shanghai。
```

示例：

```text
date=2026-03-02, startTime=945
=> 2026-03-02T09:45:00+08:00
```

## 5. CalendarEvent 映射

| CalendarEvent 字段 | 来源 |
| --- | --- |
| `title` | `lessonMap[lessonId].courseName` |
| `type` | 固定为 `course` |
| `status` | 固定为 `active` |
| `startAt` | `schedule.date + schedule.startTime` |
| `endAt` | `schedule.date + schedule.endTime` |
| `timezone` | `Asia/Shanghai` |
| `locationName` | `room.nameZh` 或 `customPlace` |
| `buildingName` | `room.building.nameZh` |
| `campusName` | `room.building.campus.nameZh` |
| `source` | `ustc_jw` |
| `externalId` | 见第 7 节 |
| `importance` | 默认 `normal` |
| `attendancePolicy` | 默认 `unknown`，实验/考试类可按规则提升 |
| `attendanceDecision` | 默认 `undecided` |
| `attendanceOutcome` | 默认 `unknown` |
| `listeningMode` | 默认 `unknown` |
| `participants` | 合并后的老师列表 |
| `tags` | 课程类型、虚拟教室、实验课等 |

地点规则：

```text
room 存在：
  locationName = room.nameZh
  buildingName = room.building.nameZh
  campusName = room.building.campus.nameZh

room 为空但 customPlace 存在：
  locationName = customPlace
  buildingName = null
  campusName = null
  confidence = medium

room 和 customPlace 都为空：
  locationName = null
  confidence = low
```

## 6. 默认出勤和听讲策略

基础默认：

```text
attendancePolicy = unknown
attendanceDecision = undecided
attendanceOutcome = unknown
listeningMode = unknown
```

可选增强规则：

```text
courseTypeName 包含 “实验”:
  attendancePolicy = must_go
  attendanceDecision = go
  listeningMode = listen
  attendanceNote = "实验课，默认应到场"

lessonType = experiment 或 experiment = true:
  添加 tag: experiment

room.virtual = true:
  添加 tag: virtual_room

room 为空且 customPlace 存在:
  添加 tag: custom_place
```

用户后续通过聊天设置的 `UserOverlay` 优先级高于这些默认规则。

## 7. externalId 和去重

建议格式：

```text
ustc_jw:{semesterKey}:{lessonId}:{scheduleGroupId}:{date}:{startHHmm}:{endHHmm}
```

示例：

```text
ustc_jw:2026spring:1001:5001:2026-03-02:0945:1120
```

真实数据可能出现同一 `lessonId + scheduleGroupId + date + startTime + endTime`
下有多个不同 `placeKey` 或规范化后仍不同的 `exerciseClass` 合并组。此时基础格式会发生 ID
碰撞。转换器只对这类碰撞组追加稳定区分后缀：

```text
{baseExternalId}:{hash(placeKey + canonicalExerciseClass)}
```

没有碰撞的普通事件继续使用原格式，避免不必要地改变已有事件身份。后缀使用
规范化数据的哈希，不在 ID 中暴露自定义地点原文。

注意：

- 不把真实 `dataId` 放入 `externalId`。
- `semesterKey` 可以来自 `semesterId` 映射，也可以先用产品内部导入批次标识。
- 相同 `externalId` 再次导入时应更新已有事件，而不是创建重复事件。

## 8. SourceRecord

每个导入事件都应有对应 `SourceRecord`，用于回溯来源和去重。

建议字段：

```text
source = ustc_jw
sourceSystem = jw.ustc.edu.cn
sourceType = jw_course_schedule
externalId = CalendarEvent.externalId
fingerprint = hash(source + lessonId + scheduleGroupId + date + startTime + endTime + placeKey + exerciseClass)
rawSummary = 脱敏摘要
```

不建议长期保存完整原始 `datum`。如果需要调试，只保存脱敏样例。

## 9. UserOverlay 应用

转换生成的是源数据视图。用户的个人经验通过 `UserOverlay` 覆盖。

优先级：

```text
single_event > course_series > event_type > global > CalendarEvent 默认值
```

可覆盖字段：

```text
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
tags
userNotes
reminderOverride
```

示例：

```text
用户：这节上节课刚点过，可以赌，明天提醒我决定去不去
=> single_event overlay:
   attendancePolicy = gamble
   attendanceDecision = undecided
   attendanceNote = 上节课刚点过，这节大概率不点
```

## 10. ScheduleRelation 生成

转换课表时可以先只生成候选重叠关系，不必直接断言所有重叠都是冲突。

时间重叠检测：

```text
eventA.startAt < eventB.endAt && eventB.startAt < eventA.endAt
```

初步判断：

```text
如果任一事件 attendancePolicy=skip:
  可能 non_conflict，relationType=replacement 或 embedded_work

如果任一事件 listeningMode=not_listen:
  可能 non_conflict，可允许嵌入 PlanBlock

如果两个事件都是 course 且都未设置 skip/not_listen:
  conflictState=conflict
  relationType=alternative_choice
  resolution=ask_user

如果一个是 exam:
  exam 优先，通常 conflictState=conflict
```

`ScheduleRelation.reason` 必须写明为什么冲突或不冲突，便于 LLM 向用户解释。

## 11. 复杂情况覆盖

样例覆盖以下情况：

```text
1. 同一门课不同周次不同老师。
2. 同一节课多位老师，原始 scheduleList 多行，输出只生成一个事件。
3. room 为空但 customPlace 有值。
4. 虚拟教室 room.virtual=true。
5. 实验课默认更偏向 must_go/listen。
6. 两门课同一时间，通过 ScheduleRelation 表达冲突。
7. 可以赌/不听讲的课可作为嵌入作业时间的候选。
```

## 12. 后续脚本建议

后续可以实现一个小脚本：

```text
scripts/convert_ustc_jw_datum.py
```

输入：

```text
examples/ustc-jw-datum.sample.json
```

输出：

```text
tmp/calendar-events.generated.json
```

第一版只需验证：

```text
时间解析
多老师合并
customPlace 兜底
virtual_room tag
externalId 去重
实验课默认策略
重叠事件 ScheduleRelation 候选
```
