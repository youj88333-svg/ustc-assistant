# SourceBundle 1.0 正式契约

## 1. 状态与目的

本文是 Windows Python Bridge、Flutter `ImportService` 与未来 Android/iOS
`SourceGateway` 之间的规范性数据契约。当前状态为设计已确认、实现待迁移。
现有 Python CLI 的 JW 导入包和二课 `schedules` 输出属于 pre-v1 legacy 格式，
不能视为本文契约已经实现。

SourceBundle 只承载需要进入 Flutter 本地数据库的完整来源快照。v1 支持：

```text
ustc_jw
ustc_young_my_schedule
```

报名中二课活动、评课社区查询、校园目录检索和详情读取使用各自版本化
`QueryResult` 或 `DetailResult`，不进入 SourceBundle。

核心原则：

```text
一个 SourceBundle
  = 一个独立同步单元
  = 一个明确完整范围
  = 一次 Flutter 数据库事务
```

## 2. 规范文件

```text
docs/data-sources/source-bundle-v1.md
schemas/source-bundle-1.0.schema.json
tests/fixtures/source-bundle/positive/
tests/fixtures/source-bundle/negative/
```

JSON Schema 负责字段、类型、枚举和基本边界。本文额外定义跨记录身份、计数、
时间先后、范围比较、隐私和事务语义；实现不得只运行 JSON Schema 后就直接写库。

## 3. 顶层结构

```json
{
  "schemaVersion": "1.0",
  "bundleId": "00000000-0000-4000-8000-000000000001",
  "source": "ustc_jw",
  "subject": {
    "accountId": "acct_local_example"
  },
  "collectedAt": "2026-07-25T20:30:00+08:00",
  "producer": {
    "name": "ustc_assistant_python",
    "version": "0.1.0",
    "platform": "windows"
  },
  "snapshot": {
    "completeness": "complete",
    "scope": {}
  },
  "manifest": {
    "sourceRecordCount": 0,
    "calendarEventCount": 0,
    "courseSeriesCount": 0,
    "scheduleRelationCount": 0
  },
  "data": {
    "sourceRecords": [],
    "calendarEvents": [],
    "courseSeries": [],
    "scheduleRelations": []
  }
}
```

四个数据数组始终存在，即使为空。Bundle 不携带部分结果或错误；失败由 Bridge
协议单独返回。

### 3.1 schemaVersion

v1 使用字符串 `1.0`。消费者只接受自己明确支持的次版本：

- 新消费者必须向后兼容同一主版本内的旧 Bundle。
- 旧消费者遇到更高次版本时拒绝导入并提示升级。
- 主版本变化表示不兼容重构。
- 未知字段、未知枚举和不符合当前次版本白名单的内容不能被静默忽略。

Bridge 握手由 Flutter 声明支持版本，Python 只能生成双方共同支持的版本。

### 3.2 bundleId

`bundleId` 是一次成功采集成果的 UUID，与业务记录身份分离：

- 同一文件重复导入时，ImportService 按 `bundleId` 识别重复。
- 重新采集必须生成新 `bundleId`，即使业务内容没有变化。
- ImportService 对规范化 Bundle 计算本地摘要。已存在的 `bundleId` 配相同摘要
  时安全跳过，配不同摘要时作为批次身份冲突拒绝。
- `bundleId` 不得由学号、用户名或远端上下文派生。

### 3.3 subject

`subject.accountId` 是 App 生成的本地不透明账号 ID，不是学号、姓名或学校账号。
Bridge 请求可以携带该本地 ID，生产者只能原样返回。

Bundle 内实体不重复携带 `userId`。账号与目标导入账号不一致时不得静默导入；
手动文件导入必须由用户明确确认目标账号，活动账号只可作为预选项，不能被静默
采用。正式 JW 和已报名二课日程 CLI 输出必须显式传入 `--account-id`；
`acct_cli_local` 只允许用于 fixture 和测试。

### 3.4 collectedAt 与 producer

`collectedAt` 表示来源完整采集成功的北京时间，使用带 `+08:00` 偏移的 RFC 3339
字符串。它不是文件写入时间。

`producer` 可省略，只用于脱敏诊断。它不得包含本地路径、浏览器 Profile、远端
身份、Cookie、Token 或登录状态。ImportService 不得根据 producer 平台分支业务
语义。

## 4. 完整快照范围

v1 的 `snapshot.completeness` 只能是 `complete`，不支持 delta、分页续传、
部分 Bundle 或“尽可能多导入”。

### 4.1 JW 学期范围

```json
{
  "completeness": "complete",
  "scope": {
    "type": "semester",
    "semesterKey": "2026fall",
    "sourceSemesterId": 461,
    "components": [
      {
        "name": "course_table",
        "status": "complete",
        "observedRecordCount": 241
      },
      {
        "name": "exam_arrange",
        "status": "complete",
        "observedRecordCount": 0
      }
    ]
  }
}
```

要求：

- `source=ustc_jw` 必须使用 `semester` scope。
- `course_table` 和 `exam_arrange` 各出现一次，且都为 `complete`。
- 考试页面明确给出合法空表时，`observedRecordCount=0` 是完整成功。
- 任一组件契约失败时不生成 Bundle。
- `sourceSemesterId` 是非个人来源配置，不是登录上下文 ID。
- 稳定业务身份使用 `semesterKey`；不得根据年份推算数字学期 ID。

### 4.2 二课日期窗口

```json
{
  "completeness": "complete",
  "scope": {
    "type": "date_window",
    "fromDate": "2026-07-18",
    "throughDate": "2026-08-25",
    "timezone": "Asia/Shanghai",
    "expectedDateCount": 39,
    "checkedDateCount": 39,
    "emptyDateCount": 38
  }
}
```

要求：

- `source=ustc_young_my_schedule` 必须使用 `date_window` scope。
- 日期范围是包含两端的北京时间自然日窗口。
- ImportService 重新计算 `expectedDateCount`，且它必须等于
  `checkedDateCount`。
- `emptyDateCount` 不能超过检查天数。
- 任一日期未得到已验证响应时不生成 Bundle。
- 日期窗口成员资格只由事件的北京时间开始日期（`startAt` 或 `startDate`）决定；
  定时事件的结束时间或全天事件的 `endDateExclusive` 可以超过 `throughDate`。

## 5. Manifest

`manifest` 中四个计数必须与 `data` 数组实际长度完全一致。来源 scope 的组件计数
还必须与相应 `SourceRecord.recordType` 数量一致。计数只证明覆盖和传输一致性，
不能单独证明活动取消。

## 6. 外部身份与本地主键

Bundle 只传来源稳定身份，不传 Flutter 数据库主键：

```text
accountId + source + entityType + externalId
```

构成一条本地来源实体的稳定查找键。

- `externalId` 必须非空、稳定，并在同一来源和实体类型内唯一。
- Windows Python 与未来移动端生产者必须为同一来源对象生成相同 externalId。
- 允许使用课程、排课、考试或二课来源 ID 构造 externalId。
- 禁止包含学号、远端用户 ID、动态登录上下文或认证材料。
- ImportService 分配本地 UUID，并在事务中解析实体间外部引用。
- Flutter 根据正式规范化字段计算本地指纹；生产者不提供业务指纹。

## 7. SourceRecord

结构：

```json
{
  "externalId": "ustc_jw:2026fall:record:course-occurrence:...",
  "recordType": "jw_course_occurrence",
  "entityType": "calendar_event",
  "entityExternalId": "ustc_jw:2026fall:event:course-occurrence:...",
  "sourceStatus": "active",
  "sourceUpdatedAt": null
}
```

v1 recordType：

```text
jw_course_series
jw_course_occurrence
jw_exam
jw_exam_course_relation
young_registered_schedule
```

规则：

- `sourceStatus` 只允许 `active` 或来源明确报告的 `cancelled`。
- `sourceUpdatedAt` 只有来源提供可靠更新时间时才填写；不得用 `collectedAt`
  冒充。
- 每个 CourseSeries 和 CalendarEvent 必须恰好被一条 SourceRecord 引用。
- 每个来源 ScheduleRelation 也必须有一条 SourceRecord。
- 悬空引用、重复映射或实体类型不匹配使整包失败。
- Bundle 不含 `presence`、fingerprint、原始摘要或远端任意 metadata。

## 8. CourseSeries

结构：

```json
{
  "externalId": "ustc_jw:2026fall:series:lesson:173667",
  "title": "示例课程",
  "courseCode": "EXAMPLE1001",
  "semesterKey": "2026fall",
  "participants": [
    {
      "role": "teacher",
      "name": "示例教师甲"
    }
  ],
  "sourceDetails": {
    "kind": "jw_course_series",
    "lessonId": "173667"
  }
}
```

- 同一开课项的 occurrence 共享 CourseSeries。
- 同名但不同开课项不按标题强行合并。
- participants 是系列教师合集；具体 occurrence 的教师以 CalendarEvent 为准。
- 二课 v1 不创建 CourseSeries。
- 颜色和用户系列覆盖由 Flutter 本地层管理，不进入 Bundle。

## 9. CalendarEvent

通用结构：

```json
{
  "externalId": "ustc_jw:2026fall:event:course-occurrence:...",
  "seriesExternalId": "ustc_jw:2026fall:series:lesson:173667",
  "title": "示例课程",
  "descriptionText": null,
  "eventType": "course",
  "time": {
    "kind": "timed",
    "startAt": "2026-09-01T09:45:00+08:00",
    "endAt": "2026-09-01T11:20:00+08:00",
    "timezone": "Asia/Shanghai"
  },
  "location": {
    "name": "示例教室",
    "building": "示例教学楼",
    "campus": "西区"
  },
  "participants": [],
  "sourceDefaults": {
    "importance": "normal",
    "attendancePolicy": "unknown",
    "listeningMode": "unknown"
  },
  "sourceDetails": {}
}
```

eventType：

```text
course
exam
second_class
```

### 9.1 时间

定时事件使用：

```text
kind=timed
startAt
endAt
timezone=Asia/Shanghai
```

`startAt` 和 `endAt` 必须为带 `+08:00` 的 RFC 3339 时间，且
`startAt < endAt`。

全天事件使用：

```text
kind=all_day
startDate
endDateExclusive
timezone=Asia/Shanghai
```

日期格式为 `YYYY-MM-DD`，且 `startDate < endDateExclusive`。定时和全天字段
不得混用。

### 9.2 来源默认值

```text
importance:       low | normal | high | critical
attendancePolicy: unknown | must_go | gamble | skip
listeningMode:    unknown | listen | not_listen
```

默认要求：

- 课程 attendancePolicy 为 `unknown`。
- 考试 importance 为 `critical`、attendancePolicy 为 `must_go`。
- 已报名二课 attendancePolicy 为 `must_go`。

这些只是来源默认值。最终出勤、听讲、颜色、提醒、备注和冲突判断属于
UserOverlay，不进入 SourceBundle。

### 9.3 参与者和来源扩展

参与者只保留显示所需的角色和姓名，不保留 teacherId、personId 或远端用户 ID。
课程 occurrence 支持多教师和不同周教师变化；系列教师合集不能覆盖 occurrence。

`sourceDetails.kind` 是严格判别字段：

```text
jw_course_occurrence
jw_exam
young_registered_schedule
```

每个 kind 只能使用 JSON Schema 中的白名单字段。不得携带原始 HTML、任意
metadata 或未知网站字段。二课 HTML 描述先转换为 `descriptionText`；所有外部
描述文本均是不可信数据。

## 10. ScheduleRelation

SourceBundle 只能携带来源明确给出的客观关系。v1 唯一保留关系类型为：

```text
exam_for_course
```

结构：

```json
{
  "externalId": "ustc_jw:2026fall:relation:exam-for-course:...",
  "relationType": "exam_for_course",
  "primary": {
    "entityType": "calendar_event",
    "externalId": "..."
  },
  "related": {
    "entityType": "course_series",
    "externalId": "..."
  }
}
```

来源关系不得包含 `conflictState`、前景优先级、解决方案或用户原因。考试能够通过
`seriesExternalId` 可靠关联课程时不必重复生成关系，因此 v1 Bundle 的
scheduleRelations 通常为空。

时间重叠由 Flutter 根据事件几何计算，只形成重叠组。用户明确判断冲突或不冲突
后，才在本地用户数据层创建 ScheduleRelation。

## 11. 缺失、窗口外和取消

Bundle 只报告本次实际观察到的记录。ImportService 在相同账号、来源和 scope 内
比较旧数据，维护本地 presence：

```text
observed
missing_within_scope
outside_scope
```

- 本次出现：`observed`。
- 仍在完整范围内但本次未出现：`missing_within_scope`。
- 已离开滚动日期窗口：`outside_scope`。
- 来源明确报告取消：SourceRecord 的 `sourceStatus=cancelled`。

`missing_within_scope` 不冒充取消，但从普通活动日程隐藏；历史、来源记录和
UserOverlay 保留。`outside_scope` 作为历史记录保留，旧日期视图可以标明它不在
当前同步保证范围。重新出现时恢复 `observed`，用户覆盖继续生效。

不得仅因导入失败、Bundle 不完整或记录离开窗口而物理删除。

## 12. ImportService 算法

1. 在读取数据库前检查 UTF-8 JSON 大小。
2. 校验支持版本、来源、账号、时间、完整性、scope 和硬限制。
3. 运行 JSON Schema，再运行跨记录语义校验。
4. 对规范化 Bundle 计算本地摘要并检查 bundleId 重放或冲突。
5. 开启一个 Drift 事务。
6. 按外部身份 upsert SourceRecord、CourseSeries、CalendarEvent 和来源关系。
7. 只在声明的相同来源 scope 内计算 presence。
8. 更新来源字段，但不修改 UserOverlay。
9. 写入 Bundle 批次、同步结果和脱敏 ActionLog。
10. 一次提交；任一步失败全部回滚。

事务提交后重新调度受影响提醒。提醒调度失败不回滚业务数据，而是记录可重试
状态。

同一 Bundle 的重复导入不制造新同步成功。新 bundleId 即使内容未变化，也更新
该来源的最后成功检查时间。

## 13. 硬限制

```text
Bundle UTF-8 大小             16 MiB
SourceRecord                 50,000
CalendarEvent                20,000
CourseSeries                  5,000
ScheduleRelation             20,000
标题、地点                    500 Unicode 字符
descriptionText              20,000 Unicode 字符
单事件参与者                  50
externalId                   512 字符
```

JSON 嵌套深度、数组长度、字符串长度和有限数值必须在写数据库前校验。限制只能随
契约次版本放宽，不能由输入文件覆盖。

## 14. 错误

至少提供以下稳定错误代码：

```text
unsupported_version
invalid_envelope
incomplete_snapshot
subject_mismatch
count_mismatch
duplicate_identity
dangling_reference
invalid_time
limit_exceeded
transaction_failed
```

错误摘要不得回显完整 externalId、标题、描述、文件内容或个人日程。

## 15. 验证

Python 生产者和 Flutter 消费者共享 fixture，但正例和反例必须保存在不同目录：

```text
tests/fixtures/source-bundle/positive/
  jw-with-exam.json
  jw-empty-exam.json
  young-with-schedule.json
  young-empty-window.json
tests/fixtures/source-bundle/negative/
  <stable rejection fixtures>
```

契约测试必须覆盖：

- Schema 与语义校验的一致接受或拒绝；
- Bundle 重放、批次身份冲突和新批次无变化刷新；
- manifest、组件计数、身份唯一性和引用完整性；
- 北京时间、定时与全天边界；
- `outside_scope`、`missing_within_scope` 和重新出现；
- UserOverlay 在更新、缺失和恢复后的保留；
- 合法空考试和完整空二课窗口；
- 多教师、分周教师和叠课不自动生成冲突关系；
- 硬限制边界；
- 输出中不存在认证材料、个人远端身份、上下文 ID、路径、原始 HTML 或未知字段。

真实 Edge 验收使用当前 `semesterId=421 / 2026spring` 和北京时间二课窗口生成正式
Bundle，在 Flutter 中执行首次导入、重复导入和第二次刷新。未来 Android/iOS
SourceGateway 必须通过同一 fixture 契约测试。
