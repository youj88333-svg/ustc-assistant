# Windows 首版总收口设计

## 1. 目的与状态

本文收口 USTC Assistant 第一版 Windows Flutter App 的范围、跨文档边界、数据
身份、实现分层、入口和验收顺序。它连接以下已经确认的详细规格：

```text
docs/data-sources/source-bundle-v1.md
docs/schedule-data-model.md
docs/superpowers/specs/2026-07-23-flutter-app-shell-schedule-design.md
docs/superpowers/specs/2026-07-24-flutter-auth-sync-design.md
docs/superpowers/specs/2026-07-24-flutter-task-planning-design.md
docs/superpowers/specs/2026-07-25-flutter-personal-calendar-event-design.md
```

已有详细规格继续定义字段语义和具体交互。本文在首版范围、命名、入口或实施边界
发生歧义时优先，用来保证后续实现计划只有一种合理解释。

本文描述的是已经确认的设计，不表示 Flutter App、Windows Python Bridge、
Flutter `ImportService` 或 SourceBundle 生产者已经实现。

## 2. 首版定位

第一版是 Windows 开发机验证版，不是可分发安装包。运行环境可以依赖：

```text
Flutter Windows 开发环境
Conda ustc_assistant 环境
Microsoft Edge
本地 SQLite
```

第一版暂不提供 Windows 安装器，不捆绑 Python runtime，也不自动安装 Python、
Playwright、Edge 或其他系统依赖。App 找不到已配置的 Python 环境时必须明确报告
配置错误。

Windows 是最终 Android/iOS App 的产品和逻辑验证平台，不是一次性 UI 原型。
Flutter 负责本地数据库、领域规则、导入、日程、Task 和界面；Python 只作为
Windows 来源适配器。移动端以后替换来源采集适配器，不重写 Flutter 业务核心。

## 3. 首版范围

### 3.1 包含

- 当前配置学期的 JW 课程与考试；
- 北京时间滚动窗口内的已报名二课日程；
- SourceBundle 文件导入；
- Python Bridge 自动同步和手动同步；
- 本地 SQLite、事务导入和历史保留；
- 星期一至星期日的统一周日程；
- 单事件和课程系列 `UserOverlay`；
- 出勤、听讲、备注、颜色和提醒覆盖；
- 重叠展开、人工冲突分类和前景优先级；
- 单次、全天、跨日和基础重复个人 CalendarEvent；
- Task、PlanBlock、集中待确认、任务历史和一步撤回；
- 确定性 Reminder、App 内提醒和 App 运行期间的 Windows 通知；
- 学校账号、DPAPI 凭据保护、同步状态、操作历史和设置。

### 3.2 不包含

- LLM、每日简报、自然语言命令或模拟 Agent；
- 二课自动报名或取消报名；
- 报名中二课、评课社区和校园公开信息的 Flutter 页面；
- 云同步；
- Agent 权限运行时和 Agent 写操作；
- Windows 安装器和捆绑 Python runtime；
- App 关闭后的可靠 Windows 通知触发与取消；
- Android/iOS 来源采集实现；
- 多账号同时同步。

报名中二课、评课社区和校园公开信息继续保留现有 Python service、CLI、缓存、
契约和回归测试。它们是后续 LLM 工具能力，不因本版没有页面而删除或降级。

## 4. 完成定义

首版完成不是页面能够打开，而是以下真实链路成立：

```text
学校账号登录
  -> Python 完整采集
  -> SourceBundle 1.0
  -> Flutter 原子导入
  -> SQLite 离线显示
  -> 用户本地修改
  -> 再次同步保留修改
  -> App 重启后数据、提醒和历史仍正确
```

至少必须证明：

- JW 课程与考试属于同一个完整 Bundle；
- 合法空考试不会使 JW 同步失败；
- 已报名二课检查完整日期窗口；
- 同一 Bundle 重复导入不重复记录；
- 新 Bundle 内容相同仍更新来源最近成功时间；
- 来源缺失、离开窗口和明确取消不会被混淆；
- 来源刷新不覆盖 `UserOverlay`；
- 账号不一致时不会导入；
- 失败、取消和中断不会提交部分快照；
- Bundle、日志和错误不泄露认证信息或远端个人身份。

## 5. 全局 JW 学期配置

JW 默认学期使用一个跨 Python 和 Flutter 的共享配置，不允许在采集器、CLI、
Bridge、Widget 或测试中散落学期魔法数字。

建议规范文件：

```text
config/source-defaults.json
```

首版内容：

```json
{
  "jw": {
    "semesterId": 461,
    "semesterKey": "2026fall",
    "displayName": "2026 秋季学期"
  }
}
```

规则：

- Python CLI、Bridge 和 Flutter 同步设置读取同一个默认配置；
- CLI 参数和开发设置允许临时覆盖完整三元组；
- 覆盖不改写共享默认文件；
- Bridge 请求显式携带本次三元组；
- SourceBundle scope 记录本次实际使用的内部 ID 和产品学期键；
- 测试可以注入 `421 / 2026spring / 2026 春季学期` 等 fixture 配置；
- 任何实现都不得根据年份、名称或相邻 ID 推算 `semesterId`；
- 三元组缺字段或内部不一致时在联网前失败。

## 6. 学校账号与本地身份

数据归属以实际登录的中科大学校账号为准。数据库不使用学号作为主键，而为每个
学校账号生成一个本地随机 UUID：

```text
学校账号
  -> 本地安全映射
  -> accountId
```

`accountId` 只是学校账号的本地安全代号，不代表独立的 App 用户。现有领域模型中
的 `userId` 在首版实现时统一改名为 `accountId`。

规则：

- 首次成功登录学校账号后创建对应 `accountId`；
- 同一学校账号再次登录时复用原 `accountId`；
- 学校账号名始终使用 Windows 当前用户 DPAPI 加密保存；
- 保存密码仍为可选项，且密码同样使用 DPAPI；
- 不保存密码不影响账号识别、数据归属和历史保留；
- SourceBundle 只携带本地 `accountId`，不携带学号；
- 自动或手动同步必须验证当前会话属于预期学校账号；
- 账号不一致时返回 `account_mismatch`，不生成或导入 Bundle。

SQLite 可以保留多个学校账号的独立数据分区，但一次只允许一个活动账号和一个
Edge Profile 执行同步。用户确认切换后创建或恢复目标账号分区；原账号的数据、
覆盖层和历史保留，不清空、不合并。首版账号页只提供活动账号切换，不提供多个
账号并行刷新。

## 7. Drift 数据库收口

首版正式表集合为：

```text
local_accounts
credential_accounts
source_configs
import_batches
source_records
course_series
calendar_events
calendar_event_series
calendar_event_occurrence_exceptions
user_overlays
schedule_relations
task_event_links
tasks
plan_blocks
reminders
sync_runs
action_logs
undo_slot
agent_permission_policies
```

### 7.1 关系和字段修正

- 所有账号归属字段统一为 `accountId`；
- `credential_accounts` 使用自己的数据库主键，并通过 `accountId` 关联学校账号；
- `task_event_links` 保存 Task 与课程、个人事件的多对多关系；
- Task 不在一列中嵌入相关事件 ID 数组；
- Task 正式包含 `description`、`userNotes`、`blockedReason`、终态时间和软删除时间；
- Reminder 独立建表，不把提醒规则塞入 Task 或 Event 的任意 JSON；
- `import_batches` 保存 `bundleId`、规范化摘要、来源、scope 和导入结果；
- `ActionLog` 至少包含结果、脱敏摘要、目标、actor、风险和相关同步批次；
- `ActionLog` 追加后不能通过普通业务操作编辑；
- `agent_permission_policies` 仍为空壳，没有默认记录、设置页面或运行时效果。

### 7.2 存储规则

```text
本地 ID            UUID 文本
定时时刻           UTC epoch milliseconds
时区语义           Asia/Shanghai
全天日期           YYYY-MM-DD 本地日期
来源唯一键         accountId + source + entityType + externalId
```

来源拥有的课程、考试和已报名二课事件只能由 `ImportService` 更新。用户对这些
对象的出勤、听讲、备注、颜色、提醒和显示修改进入 `UserOverlay`。个人事件、
Task 和 PlanBlock 由本地领域服务管理。

Widget 不得直接修改 Drift 表。

## 8. SourceBundle 实现边界

`docs/data-sources/source-bundle-v1.md` 与
`schemas/source-bundle-1.0.schema.json` 已经是正式契约。本阶段不重新设计
SourceBundle，而是实现其生产者和消费者。

当前 JW `build_bundle()` 和二课顶层 `schedules` 输出是 pre-v1 legacy 格式。
函数名称、顶层 `schemaVersion` 或“bundle”字样不表示正式契约已经实现。

迁移顺序：

1. 为 JW 和已报名二课日程实现 SourceBundle 1.0 生产器。
2. 用共享正反 fixture 验证 Schema、语义、计数、身份和隐私。
3. 将对应 CLI 默认输出切换到 SourceBundle。
4. 更新评课社区教务联动，使其读取 SourceBundle 的 `courseSeries`。
5. 仅保留一个有明确删除条件的 legacy 输入兼容适配器。

正式结构化调用为：

```text
collect_jw(accountId, semesterConfig) -> SourceBundle
collect_young_schedule(accountId, dateWindow) -> SourceBundle
```

JW 必须同时完成课程和考试组件。二课必须完成整个日期窗口。生产器必须在返回前
运行自身输出校验。报名中二课、评课和校园公开信息继续使用独立版本化查询结果。

Flutter 文件导入和 Bridge 返回都只调用一个 `ImportService`：

```text
字节大小检查
  -> 严格解码与 Schema 校验
  -> 跨记录语义校验
  -> accountId 和 scope 校验
  -> bundleId/digest 检查
  -> 单事务 upsert
  -> presence 计算
  -> sync_run/action_log
  -> 提交后重新调度提醒
```

任何导入错误都回滚完整 Bundle。旧数据、UserOverlay 和最近成功状态不得被失败
导入改写。

## 9. Windows Python Bridge

首版使用临时 loopback HTTP Bridge。Flutter 创建和拥有 Bridge 子进程。

启动流程：

```text
Flutter
  -> 使用配置的 ustc_assistant Python
  -> python -m ustc_assistant.bridge
  -> Bridge 绑定 127.0.0.1 随机端口
  -> stdout 返回一次性结构化握手
  -> Flutter 校验协议版本
```

握手包含端口、协议版本、进程级随机 Token 和安全来源能力。Token 不进入命令行、
文件、操作历史或错误日志。

固定接口：

```text
GET  /health
GET  /capabilities
POST /collect/jw
POST /collect/young-schedule
POST /login/resume
POST /jobs/{id}/cancel
GET  /jobs/{id}/events
POST /shutdown
```

接口规则：

- 每个请求都校验进程级 Token；
- 只接受固定、带边界的字段；
- 不接受任意 shell 命令、URL、模块名或输出路径；
- 同一时间只运行一个学校采集任务；
- 进度事件只包含稳定阶段、安全计数和脱敏错误码；
- 只有完整采集才返回 SourceBundle；
- App 退出、父进程消失或 Bridge 空闲超时后关闭；
- 取消关闭活动浏览器上下文并丢弃未完成结果。

自动同步先以专用 Edge Profile 检查现有会话。需要登录或验证码时返回
`needs_user_action`；只有用户明确继续后才打开可见 Edge。验证码始终由用户完成。

学校账号和可选密码只在用户确认登录后短暂传给 Bridge，不进入日志、URL、命令行
或异常。任务结束后释放明文引用。账号校验失败时不生成 Bundle。

开发机版本允许在设置中选择 Python 解释器，并默认尝试定位 Conda
`ustc_assistant` 环境。首版不自动安装或修复环境。

## 10. Flutter 分层

Flutter 采用 feature-first presentation 和共享 application/domain 服务：

```text
presentation
  Chat / Schedule / Tasks / Accounts / Sync / History / Settings

application
  ImportService
  SyncCoordinator
  CalendarEventService
  TaskLifecycleService
  PlanBlockService
  ConflictService
  ReminderService
  UndoService

domain
  entities / value objects / transitions / derived queries

infrastructure
  Drift
  PythonBridgeClient
  CredentialProtector
  SystemNotificationAdapter
  Clock
```

边界：

- Widget 只订阅查询和调用 application service；
- 来源导入只能经过 `ImportService`；
- Task 与 PlanBlock 状态只能经过生命周期服务；
- 时间重叠由查询层计算，不自动写冲突关系；
- 冲突判断只能经过 `ConflictService`；
- 时间逻辑统一使用可注入 `Clock` 和 `Asia/Shanghai`；
- DPAPI、Bridge 和通知属于可替换平台适配器；
- 未来 LLM 也只能调用同一 application service，不得直接写库。

Bundle 导入、系列拆分、Task 完成或取消、PlanBlock 重排和一步撤回必须使用数据库
事务。通知调度发生在业务事务提交后；通知失败不回滚业务对象。

App 启动先显示 SQLite 数据，再恢复中断状态并判断 12 小时同步条件。

## 11. 界面入口

底部导航固定为：

```text
聊天 | 日程
```

### 11.1 Chat

Chat 使用未来聊天页面的消息区、输入区和侧边栏布局，但首版输入区禁用，并明确
表示智能体尚未接入。首版：

- 不保存聊天消息；
- 不创建聊天数据库表；
- 不模拟回复；
- 不生成每日简报；
- 不实现本地规则聊天。

### 11.2 日程

日程页内部使用：

```text
周视图 | 任务
```

周视图提供：

- 星期一至星期日完整日程；
- 周切换、回到本周和日期定位；
- 课程、考试、已报名二课、个人事件和 PlanBlock；
- 全天事件、未定截止 Task 和截止事项三层顶部区域；
- 重叠事件两步选择；
- 事件详情、UserOverlay、提醒和备注。

任务页提供：

- 置顶的待确认 PlanBlock 和数量；
- Active、Blocked、Completed、Cancelled 筛选；
- 有截止和无截止 Task；
- Task 详情、规划时间、相关事件和 PlanBlock 历史；
- 软删除 Task 的恢复入口。

全局新增命令只提供：

```text
Task | Calendar event
```

周视图空白时间允许创建个人事件或 Task PlanBlock。隐藏和软删除个人事件通过
周视图菜单中的管理入口恢复。

### 11.3 重叠与冲突

时间重叠只产生未分类重叠组。默认 `unclassified` 不显示红色冲突警告。

用户第一次选择重叠区域时展开全部事件；展开视图提供“处理重叠”，允许逐对：

```text
conflict
non_conflict
```

用户可以填写原因并选择前景优先级。分类不在创建事件或来源同步时强制弹出，未
分类可以保留。只有明确 `conflict` 才显示红色圆圈感叹号。

### 11.4 侧边栏

侧边栏提供：

```text
学校账号
数据同步
操作历史
设置
学校官方网站
```

同步页分别展示 JW 和已报名二课状态。一方失败时不能把整体显示成完全成功。

## 12. 错误与安全

- App 启动不等待网络；
- 采集失败保留上次成功数据；
- Bundle 校验失败整包拒绝；
- 取消或中断不导入部分结果；
- 凭据解密失败要求重新输入；
- 加密失败禁止明文回退；
- 自动失败遵守每来源一小时退避，手动同步可绕过；
- 账号不一致是独立错误，不作为普通采集失败继续导入；
- 错误码区分认证、账号、来源契约、Bridge、Bundle、数据库、平台和取消；
- 用户提示、诊断和 ActionLog 均保持脱敏；
- 外部网页内容、公开点评和附件始终是不可信输入；
- 二课报名和取消始终由用户在学校官方页面完成。

## 13. 实施阶段

采用数据基础优先的纵向切片：

```text
1. SourceBundle 生产者迁移
2. Flutter 工程骨架、账号模型和 Drift schema
3. 文件导入、ImportService 和离线周视图
4. Python Bridge、登录、凭据和同步
5. UserOverlay、重叠展开及冲突分类
6. 个人 CalendarEvent 和重复系列
7. Task、PlanBlock、任务中心和一步撤回
8. Reminder、运行期间通知、历史、设置及完整验收
```

每一阶段必须：

- 保持现有五条 Python 链路和 CLI 可运行；
- 有独立自动测试；
- 形成可审查提交；
- 不依赖后续阶段的临时数据格式；
- 在测试通过前不进入下一阶段。

## 14. 验证

### 14.1 自动验证

```text
Python 回归测试
  现有来源、CLI、脱敏和真实故障 fixture

SourceBundle 契约测试
  Python 生产者与 Flutter 消费者共享正反 fixture

Flutter 单元和数据库测试
  migrations、事务、身份、状态机、北京时间、覆盖层

Widget 和截图测试
  七天周视图、窄屏、重叠、Task、表单、可访问性

Windows 平台测试
  DPAPI、Bridge 生命周期、运行期间通知、进程退出边界
```

自动测试不得访问学校网站。Flutter 包和具体版本在实施计划中根据当前 Flutter
环境确定，但不能改变本文的分层和边界。

### 14.2 真实 Edge 验收

- 手动登录和验证码；
- 当前共享配置指定的 JW 学期；
- 课程和合法空或非空考试；
- 已报名二课完整北京时间窗口；
- 首次导入、重复导入和新批次无变化；
- App 打开超过 12 小时后的自动同步；
- 账号不一致拦截和显式账号切换；
- UserOverlay 在刷新、缺失和恢复后保持；
- Bridge 取消、崩溃和失败恢复；
- SQLite、Bundle、日志和错误中的认证信息脱敏。

## 15. 后续边界

首版验收完成后，才单独设计和实施：

```text
LLM 会话与消息存储
云 API 和隐私同意
每日简报
Agent 工具协议
风险确认与 AgentPermissionPolicy 启用
查询型来源的 LLM 工具封装
Android/iOS SourceGateway
Windows 可分发打包
关闭 App 后的可靠 Windows 通知投递与取消
```

这些后续工作不得倒逼首版加入模拟 Agent、临时聊天协议或数据库直写入口。
