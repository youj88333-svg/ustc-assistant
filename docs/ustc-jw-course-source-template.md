# 中科大教务课表数据源记录模板

> 用途：记录“综合教务系统 - 我的课表”的入口、请求、返回字段和导入判断。
>
> 当前已确认主链路：`get-data -> lessonIds -> datum -> scheduleList 合并 -> 标准日程事件`。
>
> 安全提醒：不要在本文档里保存密码、完整 Cookie、完整 Token、完整学号、姓名、手机号、身份证号、真实 `dataId`、完整个人课表原文。需要示例时请打码或替换为假数据。

## 1. 基本信息

| 字段 | 内容 |
| --- | --- |
| 记录人 |  |
| 记录日期 |  |
| 学校 | 中国科学技术大学 |
| 系统名称 | 综合教务系统 |
| 功能模块 | 我的课表 |
| 系统入口 | `https://jw.ustc.edu.cn/` |
| 页面入口形态 | `/for-std/course-table/info/{dataId}` |
| 是否需要统一身份认证 | 是 / 否 / 不确定 |
| 是否需要校内网/VPN | 是 / 否 / 不确定 |
| 浏览器 | Chrome / Edge / Firefox / 其他 |
| 测试账号类型 | 本科生 / 研究生 / 其他 |
| 测试学期 |  |

## 2. 操作路径

记录从进入教务系统到看到目标学期课表的路径。

```text
1. 打开教务系统：
2. 登录方式：
3. 点击菜单：
4. 进入“我的课表”：
5. 当前页面/文档请求中观察到的入口形态：
6. 切换到目标学期：
7. 页面是否重新请求 get-data：是 / 否 / 不确定
```

登录和安全情况：

| 项目 | 结果 | 备注 |
| --- | --- | --- |
| 统一身份认证 | 有 / 无 / 不确定 |  |
| 验证码 | 有 / 无 / 偶尔有 |  |
| 短信/邮箱二次验证 | 有 / 无 / 不确定 |  |
| 扫码登录 | 有 / 无 / 可选 |  |
| 登录后是否保持会话 | 是 / 否 / 不确定 |  |

## 3. Network 抓包步骤

```text
1. 打开 F12 -> Network。
2. 勾选 Preserve log。
3. 建议先看 All，再按 Fetch/XHR 过滤。
4. 清空 Network 记录。
5. 点击“我的课表”或切换目标学期。
6. 记录 get-data 请求。
7. 记录 datum 请求。
8. 只记录接口结构和脱敏字段，不记录完整 Cookie/Token。
```

## 4. get-data 请求记录

该请求用于获取当前学期课表上下文和 `lessonIds`。

```text
GET /for-std/course-table/get-data?bizTypeId=2&semesterId={semesterId}&dataId={dataId}
```

| 字段 | 内容 |
| --- | --- |
| 请求 URL |  |
| 请求方法 | GET |
| 状态码 |  |
| 返回格式 | JSON |
| 是否依赖 Cookie | 是 / 否 / 不确定 |
| 是否依赖 Authorization | 是 / 否 / 不确定 |
| 是否依赖 CSRF | 是 / 否 / 不确定 |
| Referer | 只记录路径，不记录真实 `dataId` |
| X-Requested-With | 存在 / 不存在 |

请求参数：

| 参数 | 观察值 | 含义 | 是否敏感 |
| --- | --- | --- | --- |
| `bizTypeId` |  | 业务类型，已观察本科为 `2` | 低 |
| `semesterId` |  | 教务系统内部学期 ID，不能按年份推算 | 中 |
| `dataId` |  | 当前用户课表视图 ID | 高，需打码 |

返回顶层字段：

```text
timeTableLayoutId:
publishLessonIds:
weekIndices:
lessonId2Flag:
oddWeekIndex2dayOfWeek2Date:
currentWeek:
lessonIds:
lessons:
```

脱敏后的返回结构示例：

```json
{
  "timeTableLayoutId": 41,
  "publishLessonIds": [123456],
  "weekIndices": [1, 2, 3],
  "lessonId2Flag": {
    "123456": "publish"
  },
  "oddWeekIndex2dayOfWeek2Date": {
    "1": {
      "1": "2026-03-02"
    }
  },
  "currentWeek": 1,
  "lessonIds": [123456],
  "lessons": []
}
```

观察结论：

```text
- 是否成功拿到 lessonIds：
- 是否能从 URL 中解析 semesterId：
- 是否能从 URL/Referer/文档请求中解析 dataId：
- 学期切换是否重复触发 get-data：
```

## 5. datum 请求记录

该请求用于获取课程元数据和每一次具体上课记录，是课表导入主数据源。

```text
POST /for-std/course-table/datum
Content-Type: application/json
```

| 字段 | 内容 |
| --- | --- |
| 请求 URL |  |
| 请求方法 | POST |
| 状态码 |  |
| 返回格式 | JSON |
| 是否依赖 Cookie | 是 / 否 / 不确定 |
| 是否依赖 Authorization | 是 / 否 / 不确定 |
| 是否依赖 CSRF | 是 / 否 / 不确定 |
| X-Requested-With | 存在 / 不存在 |

请求体：

```json
{
  "lessonIds": [123456, 123457]
}
```

返回顶层结构：

```json
{
  "result": {
    "lessonList": [],
    "scheduleList": [],
    "scheduleGroupList": []
  }
}
```

数组数量记录：

| 字段 | 数量 | 备注 |
| --- | --- | --- |
| `lessonList` |  | 课程/教学班元数据 |
| `scheduleList` |  | 每一次具体上课记录 |
| `scheduleGroupList` |  | 排课组/容量信息 |

### 5.1 lessonList 字段观察

记录 1 条脱敏后的字段结构，不要贴完整课程介绍、教师联系方式或个人相关信息。

```json
{
  "id": 123456,
  "code": "COURSE.01",
  "courseName": "示例课程",
  "courseTypeName": "理论课",
  "teacherAssignmentList": [
    {
      "name": "张*",
      "role": "MAJOR",
      "weekIndicesMsg": "1~16"
    }
  ],
  "requiredPeriodInfo": {},
  "actualPeriods": 0,
  "limitCount": 0,
  "stdCount": 0,
  "suggestScheduleWeeks": [1, 2],
  "campusId": 0,
  "remark": null,
  "scheduleRemark": null,
  "selectedStdCount": 0
}
```

需要确认：

```text
- 课程标题字段：
- 教学班代码字段：
- 课程类型字段：
- 教师列表字段：
- 校区字段是否足够：
- 备注字段是否有导入价值：
```

### 5.2 scheduleList 字段观察

记录 1 条脱敏后的字段结构。

```json
{
  "lessonId": 123456,
  "scheduleGroupId": 654321,
  "periods": 2,
  "date": "2026-03-02",
  "room": {
    "nameZh": "示例教室",
    "code": "ROOM",
    "building": {
      "nameZh": "示例教学楼",
      "campus": {
        "nameZh": "示例校区"
      }
    }
  },
  "weekday": 1,
  "startTime": 945,
  "endTime": 1120,
  "personName": "张*",
  "customPlace": null,
  "weekIndex": 1,
  "exerciseClass": null,
  "startUnit": 0,
  "endUnit": 0
}
```

需要确认：

```text
- date 是否为真实日期：
- startTime/endTime 格式：
- room 为空时是否有 customPlace：
- 同一节课多位老师是否会产生多行：
- exerciseClass 是否影响合并：
- startUnit/endUnit 是否总是 0：
```

### 5.3 scheduleGroupList 字段观察

```json
{
  "id": 654321,
  "lessonId": 123456,
  "no": 0,
  "limitCount": 0,
  "stdCount": 0,
  "actualPeriods": 0,
  "default": true
}
```

第一阶段可只作为辅助数据，不必生成日程时强依赖。

## 6. 备用 print-data 请求记录

该接口可作为备用数据源，但可能包含更多学生个人信息。

```text
GET /for-std/course-table/semester/{semesterId}/print-data/{dataId}?weekIndex=
```

| 字段 | 内容 |
| --- | --- |
| 是否出现该请求 | 是 / 否 |
| 是否返回 `studentTableVm` | 是 / 否 |
| 是否返回 `activities` | 是 / 否 |
| 是否返回学生个人信息 | 是 / 否 |
| 是否适合作为主接口 | 否，除非 datum 不可用 |

安全备注：

```text
不要记录 studentTableVm 中的真实姓名、完整学号、班级、个人课表全文。
```

## 7. 日程合并与转换记录

`scheduleList` 可能包含同一节课多位老师导致的重复行。导入前应按以下 key 合并：

```text
lessonId + scheduleGroupId + date + startTime + endTime + room/customPlace + exerciseClass
```

本次抓包统计：

| 项目 | 数值 |
| --- | --- |
| 原始 `scheduleList` 行数 |  |
| 合并后事件数 |  |
| 多老师/重复 key 数 |  |
| 需要合并的字段 | `personName`, `teacherId`, `personId` |

标准日程字段映射：

| 标准字段 | 来源 |
| --- | --- |
| `title` | `lessonList[lessonId].courseName` |
| `courseCode` | `lessonList[lessonId].code` |
| `courseType` | `lessonList[lessonId].courseTypeName` |
| `startAt` | `scheduleList.date + scheduleList.startTime` |
| `endAt` | `scheduleList.date + scheduleList.endTime` |
| `location` | `room.nameZh` 或 `customPlace` |
| `building` | `room.building.nameZh` |
| `campus` | `room.building.campus.nameZh` |
| `teachers` | 合并后的 `personName[]` |
| `weekIndex` | `scheduleList.weekIndex` |
| `weekday` | `scheduleList.weekday` |
| `periods` | `scheduleList.periods` |
| `source` | `ustc_jw` |
| `externalId` | `semesterId + lessonId + scheduleGroupId + date + startTime + endTime` |

时间解析规则：

```text
945  -> 09:45
1120 -> 11:20
1930 -> 19:30
```

## 8. 接入方式初判

| 方案 | 是否可行 | 依据 | 风险 |
| --- | --- | --- | --- |
| 直接调用 XHR/API | 是 / 否 / 不确定 | `get-data` 和 `datum` | 登录态维护 |
| Playwright 监听请求 | 是 / 否 / 不确定 | 可监听当前页面选中学期 | 依赖页面行为 |
| 解析 HTML 表格 | 是 / 否 / 不确定 | 仅作为兜底 | 脆弱 |
| 官方导出文件 | 是 / 否 / 不确定 | 需继续观察 | 不一定存在 |

推荐 MVP 接入方式：

```text
1. 用户登录教务系统。
2. 用户打开“我的课表”并切换到目标学期。
3. 程序监听 get-data 请求，解析 semesterId 和 dataId。
4. 从 get-data response 中读取 lessonIds。
5. 调用 datum 获取 lessonList 和 scheduleList。
6. 合并重复记录并转换为标准日程事件。
```

## 9. 敏感信息处理

| 项目 | 处理方式 |
| --- | --- |
| 用户密码 | 不保存明文，不传给 LLM |
| Cookie/Token | 只记录是否存在，不记录原值 |
| `dataId` | 使用 `{dataId}` 或 `***` |
| `semesterId` | 可记录用于调试，但不要推算规律 |
| 学号/姓名 | 打码或使用假数据 |
| 教师联系方式 | 不记录 |
| 完整个人课表 | 不贴全文，只贴 1 条脱敏结构 |
| 临时抓包文件 | 本地保存，不对外分享 |

## 10. 结论

```text
当前判断：
- 是否拿到 get-data：
- 是否拿到 datum：
- 是否能稳定获取 lessonIds：
- 是否能生成具体日期的 scheduleList：
- 是否需要 Playwright：
- 是否适合作为 MVP 第一个数据源：

下一步：
1.
2.
3.
```
