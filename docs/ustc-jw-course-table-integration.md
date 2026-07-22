# 中科大教务课表接入方案

本文记录中国科学技术大学综合教务系统“我的课表”功能的初步抓包结论和 MVP 接入方案。

安全约定：本文不保存密码、Cookie、Token、完整学号、姓名、真实 `dataId` 或完整个人课表。调试文件 `temp.md` 仅作为本地临时抓包记录，不应对外分享。

## 1. 目标

将中科大教务系统中的个人课表导入项目内的标准日程模型，为后续实现今日提醒、聊天改日程、作业规划、校区/食堂推荐等功能提供基础数据。

第一阶段目标只做“导入当前选中学期课表”，不追求自动列出所有历史学期。

## 2. 页面现象

教务系统多数功能在 `https://jw.ustc.edu.cn/home` 内部切换，URL 不一定变化。点击“我的课表”后，页面会出现课表相关请求。学期切换时没有新的独立学期列表接口暴露，而是重复调用课表数据请求。

已观察到课表入口类似：

```text
/for-std/course-table/info/{dataId}
```

其中 `{dataId}` 与当前学生/课表视图有关，应视为敏感上下文字段，不要硬编码到公开文档中。

## 3. 接口链路

### 3.1 获取当前学期课表上下文

```text
GET /for-std/course-table/get-data?bizTypeId=2&semesterId={semesterId}&dataId={dataId}
```

作用：

- 获取当前课表布局和周次信息
- 获取当前学期的 `lessonIds`
- 获取 `weekIndex + weekday -> date` 的日期映射
- 返回部分课程元数据

已观察到的关键返回字段：

```json
{
  "timeTableLayoutId": 41,
  "publishLessonIds": [],
  "weekIndices": [],
  "lessonId2Flag": {},
  "oddWeekIndex2dayOfWeek2Date": {},
  "currentWeek": 1,
  "lessonIds": [],
  "lessons": []
}
```

`semesterId` 是教务系统内部 ID，不能按年份推算。已观察到示例：

```text
2025 春: 381
2025 夏: 382
2025 秋: 401
2026 春: 421
2026 夏: 441
```

这些 ID 只作为调试参考，产品逻辑不应依赖固定规律。

### 3.2 获取课程和具体上课记录

```text
POST /for-std/course-table/datum
Content-Type: application/json
X-Requested-With: XMLHttpRequest
```

请求体：

```json
{
  "lessonIds": [123456, 123457]
}
```

返回结构：

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

- `lessonList`：课程/教学班元数据，例如课程代码、课程名、课程类型、教师列表、容量、校区、备注等。
- `scheduleList`：每一次具体上课记录，是生成日程事件的主数据源。
- `scheduleGroupList`：排课组和容量信息，第一阶段可作为辅助数据。

一次实际抓包中观察到：

```text
lessonList: 10 条
scheduleGroupList: 10 条
scheduleList: 319 条
```

其中 `scheduleList` 包含同一节课多位老师造成的重复行，需要合并后再生成日程。

### 3.3 备用打印接口

```text
GET /for-std/course-table/semester/{semesterId}/print-data/{dataId}?weekIndex=
```

作用：

- 返回打印视图数据
- 含学生信息和 `activities`

该接口信息较完整但包含更多个人信息，不作为 MVP 主接口。可作为调试或备用数据源。

## 4. 日程生成规则

### 4.1 核心数据源

MVP 使用 `datum.result.scheduleList` 生成实际日程事件，使用 `datum.result.lessonList` 补充课程标题、课程代码、课程类型等信息。

`scheduleList` 关键字段：

```text
lessonId
scheduleGroupId
periods
date
room
weekday
startTime
endTime
teacherId
personId
personName
customPlace
weekIndex
exerciseClass
startUnit
endUnit
```

`lessonList` 关键字段：

```text
id
code
courseName
courseTypeName
teacherAssignmentList
requiredPeriodInfo
actualPeriods
scheduleState
limitCount
stdCount
suggestScheduleWeeks
campusId
remark
scheduleRemark
adminclasses
selectedStdCount
```

### 4.2 重复记录合并

不能直接将 `scheduleList` 的每一行都生成一个日程。应先按以下 key 合并：

```text
lessonId + scheduleGroupId + date + startTime + endTime + room/customPlace + exerciseClass
```

合并策略：

- `personName` 聚合为 `teachers[]`
- `teacherId` 和 `personId` 可聚合为内部参考字段
- 相同课程、日期、时间、地点的多位老师只生成一个日程事件

### 4.3 标准日程字段映射

建议转换为项目内标准事件：

```text
title        <- lessonList[lessonId].courseName
courseCode   <- lessonList[lessonId].code
courseType   <- lessonList[lessonId].courseTypeName
startAt      <- scheduleList.date + scheduleList.startTime
endAt        <- scheduleList.date + scheduleList.endTime
location     <- scheduleList.room.nameZh 或 scheduleList.customPlace
building     <- scheduleList.room.building.nameZh
campus       <- scheduleList.room.building.campus.nameZh
teachers     <- 合并后的 personName
weekIndex    <- scheduleList.weekIndex
weekday      <- scheduleList.weekday
periods      <- scheduleList.periods
source       <- ustc_jw
externalId   <- semesterId + lessonId + scheduleGroupId + date + startTime + endTime
```

时间字段目前观察为四位数字或三位数字，例如 `945` 表示 `09:45`，`1930` 表示 `19:30`。转换时应补零后解析为本地时间。

## 5. ID 获取策略

### 5.1 MVP 策略

已确认登录态下请求固定入口：

```text
GET /for-std/course-table
```

服务器会通过 HTTP 302 跳转到 `/for-std/course-table/info/{contextId}`。
该上下文值无需由学号推算或长期保存；每次新登录会话从固定入口重新获取即可。

第一阶段不主动维护完整学期列表，而是导入“当前页面选中的学期”：

```text
1. 用户登录教务系统
2. 请求 /for-std/course-table 并跟随 302
3. 从最终 URL 识别当前会话的 contextId
4. 用户在页面里切换到目标学期
5. 程序监听 get-data 请求
6. 从 get-data URL 中解析 semesterId 和 dataId
7. 从 get-data response 中读取 lessonIds
8. 调用 datum
9. 转换并保存标准日程事件
```

当前观察到最终 URL 的 `contextId` 与 `get-data` 的 `dataId` 相同，但实现仍以
实际请求参数为准，不依赖二者永远相同。该策略不依赖 `semesterId` 规律，也不
要求找到独立学期列表接口。

### 5.2 后续增强

后续可以增加：

- 手动维护中科大学期 ID 表
- 登录后扫描近期 `semesterId` 范围并缓存有效学期
- 从前端源码或页面初始化状态中提取完整学期列表

## 6. 安全与边界

- 不保存用户密码明文。
- 不把密码、Cookie、Token、完整学号、姓名、完整课表原文发送给 LLM。
- `dataId`、Cookie、登录态只在受控后端或本地自动化环境使用。
- 自动导入课表属于读取操作，风险较低。
- 后续涉及报名二课、提交申请等写操作时，必须加入用户确认和操作日志。

## 7. 当前结论

中科大教务课表接入可行性高。课表不需要通过 HTML 解析，可以通过结构化 JSON 接口获取。

MVP 推荐主路径：

```text
get-data -> lessonIds -> datum -> scheduleList 合并 -> 标准日程事件
```

下一步：

1. 设计项目内标准日程数据模型。
2. 写一个本地脱敏样例 JSON，验证 `datum` 到标准事件的转换逻辑。
3. 再研究考试安排接口，复用相同的“教务数据源 -> 标准日程事件”框架。
