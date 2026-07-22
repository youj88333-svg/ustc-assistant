# 中科大教务本地导入管线

本文记录当前原型中“课表 datum + 考试 HTML -> 统一日程导入包”的边界和用法。

## 1. 目标

统一导入器负责把已经保存到本地的教务数据转换并合并为项目内部日程包。它是后续手机 App、浏览器调试工具或桌面采集器的下游组件，不负责登录、保存密码、持有 Cookie、跟随 302 或发起网络请求。

当前输入支持两类：

- 课表：`POST /for-std/course-table/datum` 的 JSON 响应。
- 考试：`GET /for-std/exam-arrange` 跟随 302 后得到的考试信息 HTML 页面。

## 2. 管线边界

推荐将教务接入拆成三层：

1. 采集层：在已登录会话中打开固定入口、跟随跳转、监听或保存响应。
2. 转换层：分别用课表转换器和考试转换器生成标准 `CalendarEvent`、`SourceRecord` 和 `ScheduleRelation`。
3. 聚合层：用统一导入器合并多个转换结果，写成本地 JSON 包，后续再进入本地数据库或同步模块。

当前三个层次均已有原型。第 1 层由 Windows 命令行测试程序通过 Playwright
启动专用 Microsoft Edge 会话；第 2 层和第 3 层仍由已有转换器与统一导入器
负责。浏览器采集器不会把 Cookie 或完整原始响应传给转换器。

## 3. 输出格式

统一导入包包含：

```json
{
  "calendarEvents": [],
  "sourceRecords": [],
  "scheduleRelations": [],
  "metadata": {
    "bundleType": "ustc_jw_import_bundle",
    "userId": "user_sample",
    "includedSources": ["course_table", "exam_arrange"],
    "generatedAt": "2026-07-11T00:00:00Z"
  }
}
```

`calendarEvents`、`sourceRecords`、`scheduleRelations` 直接来自各转换器。聚合层会检查事件 ID、来源记录 ID、关系 ID 是否重复；若重复则报错，避免静默覆盖。

`metadata.generatedAt` 使用 UTC 时间，仅表示本地导入包生成时间，不来自教务系统。

## 4. 命令

合并课表和考试：

```powershell
conda run -n basic310 python scripts\import_ustc_jw.py `
  --course-datum examples\ustc-jw-datum.sample.json `
  --exam-html examples\ustc-jw-exam-page.sample.html `
  --output tmp\ustc-jw-import.generated.json `
  --semester-key 2026spring `
  --user-id user_sample
```

只导入课表：

```powershell
conda run -n basic310 python scripts\import_ustc_jw.py `
  --course-datum examples\ustc-jw-datum.sample.json `
  --output tmp\ustc-jw-course-only.generated.json `
  --semester-key 2026spring `
  --user-id user_sample
```

脱敏样例输出：

```text
examples/ustc-jw-import-bundle.sample.json
```

### 4.1 登录并实时采集

实时采集原型使用独立环境 `ustc_assistant`：

```powershell
conda activate ustc_assistant
python scripts\collect_ustc_jw.py
```

程序启动专用 Edge 配置，访问教务系统并自动进入统一身份认证固定入口。
第一次登录和再次出现的验证码由用户在学校官方页面完成；后续优先复用 Edge
保存的登录状态和浏览器自动填充。当前测试配置固定为 `2026spring`、
`semesterId=421`。

正常运行只写入：

```text
tmp/ustc-jw-import.generated.json
```

如需排查接口问题，必须显式传入 `--save-raw`：

```powershell
python scripts\collect_ustc_jw.py --save-raw
```

该参数会在 `tmp/private/` 保存完整课表 datum JSON 与考试 HTML，二者均包含
真实个人安排，不应分享或提交到公开仓库。

## 5. 安全约束

统一导入器不应接触以下内容：

- 用户密码、Cookie、Token。
- 完整学号、姓名、真实上下文 ID。
- 未脱敏的完整个人页面或抓包原文。

它只读取本地输入文件，并将转换后的结构化摘要写入输出。真实产品中，采集层也应尽量在本地执行，并在进入 LLM 前剥离身份、凭据和完整原始页面。

实时采集器另有以下边界：

- 浏览器专用配置保存在当前 Windows 用户的本地应用数据目录，不在项目目录中；
- 密码由 Edge 管理，程序不读取或保存密码原文；
- `dataId`、`contextId`、Cookie 和 CAS ticket 只存在于浏览器会话；
- 默认在内存中完成转换，日志不打印完整请求 URL 或响应正文。

## 6. 后续扩展

二课平台接入时也应复用同一模式：

1. 先实现只读的活动列表/已报名活动转换器。
2. 转换器输出同样的 `CalendarEvent`、`SourceRecord`、`ScheduleRelation`。
3. 聚合层只负责合并和去重。
4. 报名、取消报名等写操作必须进入 `ActionLog` 和 `AgentPermissionPolicy` 的确认流程。
