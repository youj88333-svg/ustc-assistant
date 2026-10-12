# 应用壳层 技术文档

> 模块编号：04 ｜ 产出日期：2026-08-12 ｜ 覆盖分支：main ｜ 探索者：subagent-04

## 1. 职责边界

**做什么**：本模块是 Flutter Windows 客户端的应用外壳与全局导航层，包含：

1. 应用入口与根组件（`main.dart` → `UstcAssistantApp`，`MaterialApp.router` 装配主题与路由）。
2. 全局导航：GoRouter 路由表（`buildRouter`）、底部双分支导航（聊天/日程）、侧边栏 `AppDrawer`、全局"新建"入口（任务/日程）。
3. 全局主题（`buildAppTheme`，Material 3 亮色主题）。
4. 全局设置页（`SettingsPage`）与学校官方网站页（`OfficialWebsitesPage`）。
5. 跨模块用例编排器 `SettingsService`（源开关、Python 路径、JW 学期覆盖、清理缓存/凭据/浏览器会话/业务数据、完全重置）。
6. 各 feature 页面的"加载器"（Loader）——路由层负责解析激活账号、装配依赖（如 `_AgentChatLoader` 装配 `AgentComposition`，`_SettingsLoader` 装配 `SettingsService`）后渲染页面。

**不做什么**：账号管理（`features/accounts`）、同步（`features/sync`）、操作历史（`features/history`）、日程/任务/日历页面本体（`features/schedule`/`features/tasks`/`features/calendar`）、Agent 页面本体与 Agent 领域逻辑（`features/agent`）、提醒调度（`features/reminders`）、导入（`features/import`）均不在本模块；本模块只通过路由表引用这些页面，并在 Loader 中做装配。

**依赖谁（上游）**：
- `core/database/app_database.dart`（`AppDatabase`、`openAppDatabase`）、`core/database/connection.dart:4`（`driftDatabase`）。
- `core/security/windows_dpapi_protector.dart`（`WindowsDpapiProtector`）。
- `core/time/beijing_clock.dart`（`SystemBeijingClock`，agent 设置装配用）。
- `core/config/generated_source_defaults.dart`（`kDefaultJwSemester` 等，settings 页与 service 使用）。
- 各 feature 的 presentation/application 层（见第 4 节路由表）。

**被谁依赖（下游）**：`main.dart:17` 启动 `UstcAssistantApp`；测试直接构造 `UstcAssistantApp`（`test/app/app_shell_test.dart:74`）或 `buildRouter`（`test/features/settings/complete_reset_flow_test.dart:83`）驱动整树。本模块没有下游业务代码反向依赖。

**归属依据**：`SettingsService` 虽落在 `features/settings/application/`，但其职责是跨模块用例编排（清空数据库多张表、调用 `AccountService` 删除凭据与浏览器会话、写审计日志），它是"页面交互的编排器"而非数据层仓库，故归应用壳层（前端编排器归前端）。

## 2. 现状·核心组件

### 目录树（仅本模块范围）

```
app/lib/
├── main.dart                                          # 进程入口，MyApp → UstcAssistantApp
├── app/
│   ├── app.dart                                       # UstcAssistantApp 根组件
│   ├── router.dart                                    # buildRouter 路由表 + 全部 Loader
│   ├── app_drawer.dart                                # AppDrawer 侧边栏
│   └── theme.dart                                     # buildAppTheme 亮色主题
└── features/settings/
    ├── application/settings_service.dart              # SettingsService 跨模块编排器
    └── presentation/
        ├── settings_page.dart                         # SettingsPage 全局设置页
        └── official_websites_page.dart                # OfficialWebsitesPage + Launcher 接口
```

### 关键组件职责

| 组件 | 文件:行 | 一句话职责 |
|---|---|---|
| `UstcAssistantApp` | `app/lib/app/app.dart:19` | 根 StatefulWidget：装配 `AppDatabase`、`WindowsReminderReconciler`、`GoRouter`，`MaterialApp.router` 挂载主题与路由 |
| `_UstcAssistantAppState._startBackgroundWork` | `app/lib/app/app.dart:57-66` | 启动后后台任务：激活账号存在则启动提醒调和器，再执行 `runStartupAutomaticSync` 启动同步 |
| `buildRouter` | `app/lib/app/router.dart:46-200` | GoRouter 路由表工厂：`StatefulShellRoute.indexedStack` 双分支 + 14 条独立 `GoRoute` |
| `_MainShell` | `app/lib/app/router.dart:202-285` | 壳层 Scaffold：AppBar（标题随分支、全局新建按钮）、`AppDrawer`、`NavigationBar` 双 destination |
| `AppDrawer` | `app/lib/app/app_drawer.dart:4-46` | 侧边栏：6 个静态 destination，全部 `context.push` 跳转 |
| `buildAppTheme` | `app/lib/app/theme.dart:3-30` | Material 3 亮色主题，种子色 `0xFF1F6B45`；无暗色主题（全库 grep 无 `darkTheme`/`ThemeMode` 使用） |
| `MyApp` | `app/lib/main.dart:10-19` | 进程入口，透传可选 `database` 注入 |
| `SettingsService` | `app/lib/features/settings/application/settings_service.dart:21-257` | 跨模块设置编排器（详见第 3、5 节） |
| `SettingsPage` | `app/lib/features/settings/presentation/settings_page.dart:7-223` | 设置页 UI：模型服务入口、源开关、Python 路径、JW 学期、清理类操作与完全重置 |
| `OfficialWebsitesPage` | `app/lib/features/settings/presentation/official_websites_page.dart:15-70` | 学校官网白名单列表（4 个 HTTPS 目标）并交给 launcher 打开 |
| `OfficialWebsiteLauncher` 接口 | `app/lib/features/settings/presentation/official_websites_page.dart:4-6` | 打开外链的抽象接口（生产 `UrlLauncherOfficialWebsiteLauncher`，测试注入 Fake） |
| `_AgentChatLoader` / `_AgentChatCompositionBuilder` | `app/lib/app/router.dart:526-696` | Agent 聊天页加载器：解析激活账号、装配 `AgentComposition`（含 Bridge 握手），缓存 composition 防止 rebuild 重复握手 |
| `_SettingsLoader` | `app/lib/app/router.dart:439-473` | 设置页加载器：解析激活账号，装配 `AccountService` + `SettingsService`，`onCompleteReset → context.go('/sync')` |
| 其余 Loader（`_TaskCreatePage`、`_CalendarEventCreatePage`、`_ScheduleConflictsLoader`、`_PersonalEventManagementLoader`、`_AgentSettingsLoader`、`_HistoryLoader`） | `app/lib/app/router.dart:287-515, 773-799` | 各路由的依赖装配/激活账号守卫/空态渲染 |

## 3. 现状·关键数据流

### 3.1 应用启动与后台工作流

`main.dart:6-18` → `UstcAssistantApp`（`app.dart:40-55`）→ `AppDatabase(openAppDatabase())` → `WindowsReminderReconciler`（`app.dart:44-48`）→ `buildRouter`（`app.dart:49`）→ `MaterialApp.router`（`app.dart:78-83`）；若自持数据库，首帧后执行 `_startBackgroundWork`（`app.dart:50-54, 57-66`）。

```
main() → MyApp → UstcAssistantApp.initState
  ├─ 创建 AppDatabase（drift，库名 'ustc_assistant'，connection.dart:4）
  ├─ 创建 WindowsReminderReconciler + ReminderService + ForegroundNotificationAdapter
  ├─ buildRouter(...) → GoRouter(initialLocation: '/chat')
  └─ 首帧后 _startBackgroundWork:
       ├─ 查询激活账号（app.dart:58-61）；存在 → reminderReconciler.start(account.id)
       └─ runStartupAutomaticSync（sync_page.dart:19-69，best-effort，吞全部异常）
```

### 3.2 路由解析与导航

`GoRouter.initialLocation = '/chat'`（`router.dart:55`）。壳层 `_MainShell` 内底部 `NavigationBar` 通过 `navigationShell.goBranch(index, initialLocation: index == currentIndex)` 切换分支（`router.dart:230-237`）；侧边栏与页面内导航统一 `context.push`（如 `app_drawer.dart:39`、`agent_chat_page.dart:443`），详情页从 `StatefulShellRoute` 顶部压栈（返回后保持分支状态——`StatefulShellRoute.indexedStack` 的分支 Navigator 独立存活）。

```
GoRouter
 ├─ StatefulShellRoute.indexedStack（router.dart:57）
 │   ├─ branch0 '/chat'      → _AgentChatLoader → AgentChatPage
 │   └─ branch1 '/schedule'  → SchedulePage（?section=week|tasks，router.dart:765-771）
 └─ 顶层 GoRoute（14 条，router.dart:96-197）：
     /task/new · /tasks/:taskId · /calendar-event/new · /events/:eventId ·
     /events/:eventId/conflicts · /schedule/conflicts · /calendar-events/manage ·
     /accounts · /accounts/:accountId/reauthenticate · /sync · /history ·
     /settings · /settings/agent · /official-websites
```

`?section=` 查询参数是唯一的跨页 URL 状态传递：`agent_chat_page.dart:443-445` `context.push('/schedule?section=week|tasks')` → `_scheduleSectionFromRoute`（`router.dart:765-771`）只认 `week`/`tasks` 两值。

### 3.3 completeReset 编排（本模块核心跨模块用例）

触发链路：`SettingsPage._completeReset`（`settings_page.dart:180-203`，双重确认对话框）→ `SettingsService.completeReset`（`settings_service.dart:170-190`）→ 成功回调 `onCompleteReset`（`router.dart:468` 装配为 `context.go('/sync')`）→ 同步页首登状态（测试断言 `complete_reset_flow_test.dart:101-103`）。

```
SettingsPage 双击确认（settings_page.dart:180-203）
  → SettingsService.completeReset（settings_service.dart:170-190）
      ├─ 事务内：删 actionLogs(accountId) → 清 undoSlot → 删 localAccounts(id)
      │   （其余表由 local_accounts 外键 CASCADE 连带删除，测试验证于
      │    complete_reset_flow_test.dart:105-114）
      ├─ database.notifyActiveAccountChanged()（settings_service.dart:184）
      └─ accounts.clearDedicatedBrowserSession()（settings_service.dart:185-189；
          失败 → BrowserSessionClearAfterResetError）
  → _SettingsLoader.onCompleteReset → context.go('/sync')（router.dart:468）
  → _AgentChatLoader 订阅的 activeAccountChanges 触发重建，显示"请先配置学校账号"
    （router.dart:549-555；app_database.dart:54-57 通知流）
```

## 4. 现状·接口契约

### 4.1 本模块对外接口

| 接口 | 位置 | 说明与消费方 |
|---|---|---|
| `UstcAssistantApp({websiteLauncher, database})` | `app/lib/app/app.dart:19-31` | 根组件；`websiteLauncher` 注入 `OfficialWebsiteLauncher`（默认 `UrlLauncherOfficialWebsiteLauncher`），`database` 注入 `AppDatabase`（默认自建并自持）。消费方：`main.dart:17`、测试 |
| `buildRouter(websiteLauncher, database, [reminderReconciler, agentCompositionLoader])` | `app/lib/app/router.dart:46-51` | 路由表工厂；可选注入 `ReminderReconciler`（默认 `NoopReminderReconciler`）与 `AgentCompositionLoader`（测试注入装配管线）。消费方：`app.dart:49`、`complete_reset_flow_test.dart:83`、`app_shell_test.dart:150` |
| `ScheduleSection`（re-export） | `app/lib/app/app.dart:16-17` | `export ... show ScheduleSection`，供 `?section=` 类型解析与测试 |
| `OfficialWebsiteLauncher.launch(Uri) → Future<bool>` | `official_websites_page.dart:4-6` | 外链打开抽象；生产实现 `UrlLauncherOfficialWebsiteLauncher`（:8-13），agent 聊天页消息链接也消费同一接口（`agent_chat_page.dart:692`） |
| `SettingsService` 全部方法 | `settings_service.dart:40-190` | 见 4.3 |

### 4.2 路由表全量（本模块核心契约）

`buildRouter` 定义于 `app/lib/app/router.dart:46-200`，`initialLocation: '/chat'`（:55）。全部路由：

| path | 页面/加载器 | 关键装配 | 行号 |
|---|---|---|---|
| `/chat`（branch 0） | `_AgentChatLoader` → `AgentChatPage` | 激活账号解析 + `AgentComposition.build`（含 DPAPI、秘密存储、Bridge 握手） | `router.dart:61-71, 526-696` |
| `/schedule`（branch 1） | `SchedulePage` | `initialSection` 由 `?section=` 解析；`onEventSelected/onTaskSelected/onManageRelations` 回调注入 push 目标 | `router.dart:74-93, 765-771` |
| `/task/new` | `_TaskCreatePage` → `TaskForm` | 激活账号守卫；`TaskLifecycleService` + `UndoService` 创建后 `context.pop()` | `router.dart:96-99, 332-367` |
| `/tasks/:taskId` | `TaskDetailLoader` | `taskId` 取自 pathParameters | `router.dart:100-106` |
| `/calendar-event/new` | `_CalendarEventCreatePage` → `CalendarEventForm` | `prefill` 经 `state.extra`（`CalendarEventPrefill`）传入 | `router.dart:107-113, 371-407` |
| `/events/:eventId` | `EventDetailLoader` | `onManageOverlaps` → push `/events/:eventId/conflicts` | `router.dart:114-122` |
| `/events/:eventId/conflicts` | `ConflictManagementLoader` | 同前 | `router.dart:123-129` |
| `/schedule/conflicts` | `_ScheduleConflictsLoader` → `ConflictManagementPage` | `ConflictManagementRequest` 经 `extra` 传入；`extra` 缺失或少于 2 项渲染空态页 | `router.dart:130-138, 287-330` |
| `/calendar-events/manage` | `_PersonalEventManagementLoader` → `PersonalEventManagementPage` | 激活账号守卫 | `router.dart:139-143, 409-437` |
| `/accounts` | `AccountsPage` | 装配 `AccountService`；`onLoginAgain` → push `/accounts/:id/reauthenticate`；`onOpenOfficialPage` → `context.go('/official-websites')` | `router.dart:144-155` |
| `/accounts/:accountId/reauthenticate` | `SyncPageLoader` | `reauthenticateAccountId` 透传；`onReauthenticated` → `context.go('/accounts')` | `router.dart:156-164` |
| `/sync` | `SyncPageLoader` | `onExit`：可 pop 则 pop，否则 `context.go('/chat')`；`onReauthenticationRequired` → push reauthenticate | `router.dart:165-180`；`sync_page.dart:71-169` |
| `/history` | `_HistoryLoader` → `HistoryPage` | 激活账号守卫 + `HistoryRepository` | `router.dart:181-184, 773-799` |
| `/settings` | `_SettingsLoader` → `SettingsPage` | 激活账号守卫；装配 `AccountService` + `SettingsService`；`onCompleteReset` → `context.go('/sync')` | `router.dart:185-188, 439-473` |
| `/settings/agent` | `_AgentSettingsLoader` → `AgentSettingsPage` | 激活账号守卫；装配 `DriftChatRepository`、`AgentConfigurationService`、`ProtectedAgentSecretStore`、`AnthropicLlmProvider`、`AgentPermissionPolicyService` | `router.dart:189-192, 475-515` |
| `/official-websites` | `OfficialWebsitesPage` | 注入 `websiteLauncher` | `router.dart:193-197` |

### 4.3 SettingsService 公开 API（`settings_service.dart:40-190`）

- `sourceEnabled(source) / setSourceEnabled(source, enabled)`（:40-60）：读写 `sourceConfigs` 表中 `'$accountId:$source'` 行的 `enabled`，写后追加 `actionLogs`（`source_toggle`）。消费方：`settings_page.dart:30-39, 71-86`。
- `setPythonPath(path) / pythonPath()`（:62-68）：读写 `app_settings` 配置 JSON 的 `pythonPath` 键；空串归一为 null。消费方：`settings_page.dart:26-28, 97-99`、`router.dart:717-721`（agent 组合懒加载 Bridge 时定位 Python）、`sync_page.dart:48-52, 119-127`（同步 Bridge 定位）。
- `setReminderTypeEnabled(type, enabled)`（:70-80）：`disabledReminderTypes` 列表。
- `setJwSemesterOverride / resetJwSemester`（:82-101）：写 `ustc_jw` 源配置 `configJson`（`semesterId/semesterKey/displayName` 三元组），缺任一字段抛 `SettingsValidationError('complete_semester_required')`；reset 写回 `kDefaultJwSemester`（`generated_source_defaults.dart:2-8`，461 / '2026fall' / '2026 秋季学期'）。
- `clearCache()`（:103-106）：调注入的 `clearExternalCache`（默认 noop），写 `cache_clear` 日志；不清业务表（测试 `settings_test.dart:58-91` 验证日历与覆盖保留）。
- `clearCredentials({confirmed})`（:108-111）：确认后 `accounts.deleteCredentials`（DPAPI 凭据）。
- `clearBrowserSession({confirmed})`（:113-116）：确认后 `accounts.clearDedicatedBrowserSession()`。
- `clearBusinessData({confirmed})`（:118-168）：单事务内按 `accountId` 清 14 张业务表（reminders、userOverlays、scheduleRelations、scheduleRelationRules、taskEventLinks、planBlocks、tasks、calendarEventOccurrenceExceptions、calendarEvents、calendarEventSeries、courseSeries、sourceRecords、syncRuns、importBatches、jwDayMoves），保留账号与凭据，写 `business_data_clear` 日志。
- `completeReset({firstConfirmation, secondConfirmation})`（:170-190）：双确认后事务内删 actionLogs、undoSlot、localAccounts；`notifyActiveAccountChanged()`；随后清浏览器会话，失败抛 `BrowserSessionClearAfterResetError`（账号删除不回滚，测试 `settings_test.dart:313-337`）。
- 常量：`automaticSyncInterval = 12h`（:31，**无任何消费方**，见第 10 节）、`defaultJwSemester = kDefaultJwSemester`（:32）。

## 5. 现状·错误处理

| 场景 | 处理方式 | 位置 |
|---|---|---|
| 激活账号不存在（各 Loader） | 渲染居中文本"请先配置学校账号"，不抛异常 | `router.dart:317-320, 455-457, 490-493, 575-577, 789-791` |
| Agent 用户名解析失败 | `_NoResolvedUsername` 哨兵异常 → 页面"无法获取学校账号"；`_resolvedUsername` 捕获一切异常返回空串（`router.dart:747-756`） | `router.dart:674-676, 701-703, 705-714` |
| AgentComposition 构建失败/为 null | 页面"无法加载 Agent 服务" | `router.dart:677-680` |
| composition 已释放后完成 | `_trackComposition` 抛 `StateError('composition_disposed')` | `router.dart:632-642` |
| 切换账号（activeAccountChanges） | `_AgentChatLoader` 重建 `_accountFuture`，`_AgentChatCompositionBuilder` 释放旧 composition 并重建新账号的 | `router.dart:549-555, 644-654`；测试 `app_shell_test.dart:108-182` |
| completeReset 浏览器会话清理失败 | `BrowserSessionClearAfterResetError` 冒泡至 `SettingsPage`，SnackBar 提示"本地数据已清除，但浏览器会话清理失败"，仍继续跳转 `/sync` | `settings_service.dart:185-189`；`settings_page.dart:192-202` |
| 设置校验失败 | `SettingsValidationError('complete_semester_required')`（JW 学期三元组不完整） | `settings_service.dart:88-93`；测试 `settings_test.dart:344-346` |
| 启动自动同步 | best-effort：`try { ... } on Object { /* 忽略 */ } finally { bridge?.shutdown() }`，绝不阻塞本地使用 | `sync_page.dart:64-68` |
| 同步页依赖构建失败 | `SyncPageLoader` 渲染"同步组件初始化失败" | `sync_page.dart:149-151` |
| Bridge 懒启动失败 | `LazyQuerySourceGateway`（`agent_composition.dart:41-113`）把启动异常转换为 `SourceQueryFailed(code: 'bridge_unavailable')` 事件，隐藏敏感内部细节；下次执行自动重试（工厂重新调用） | 测试 `app_shell_test.dart:198-245` |
| 官方网页打不开 | SnackBar"无法打开官方网站"（launcher 返回 false 时） | `official_websites_page.dart:58-63` |
| 新建任务/日程无激活账号 | 提交时 `throw StateError('active account required')`（页面内异常上抛，无兜底 UI） | `router.dart:344-346, 391-393` |

## 6. 现状·观测点

**状态持久化**：
- 设置全部落库 `sourceConfigs` 表（`app/lib/core/database/tables/source_tables.dart:5`），主键 `id = '$accountId:$source'`（`settings_service.dart:49, 198, 222`）：`app_settings`（pythonPath、disabledReminderTypes 等 JSON）、`ustc_jw`（学期三元组）、`ustc_jw`/`ustc_young_schedule`（源开关）。
- 运行时状态不落库：当前分支、滚动位置、聊天会话等均不持久化；每次启动 `initialLocation: '/chat'`（`router.dart:55`）。

**日志/审计**：每次设置变更经 `actionLogsRepository.append` 写 `actionLogs` 表（`settings_service.dart:246-254`），`source='system'`、`result='success'`，actionType 包括 `source_toggle`、`cache_clear`、`business_data_clear`、`jw_semester_change`；测试验证日志随设置写入增长（`settings_test.dart:106-112`）。completeReset 会清空本账号的 actionLogs（`settings_service.dart:176-178`）。

**可恢复性**：
- `AgentComposition`/`LazyQuerySourceGateway` 均有 dispose 生命周期，壳层负责在路由退出、账号切换时释放（`router.dart:644-661`）。
- `UstcAssistantApp.dispose` 顺序释放 router → reminderReconciler → database（`app.dart:69-74`）。
- 启动同步可失败但不阻断启动（见第 5 节）。

## 7. 端到端链路参与

- **completeReset 链路**：`SettingsPage` 双确认（settings_page）→ `SettingsService.completeReset` 事务清库 + 通知账号变更（settings_service）→ `_SettingsLoader.onCompleteReset` 跳转 `/sync`（router）→ 同步页首登状态（sync）。上下游：账号模块（`AccountService.deleteCredentials/clearDedicatedBrowserSession`，`account_service.dart:391/407`）、同步模块（SyncPageLoader）、数据库模块（CASCADE 外键）。测试：`test/features/settings/complete_reset_flow_test.dart` 全流程覆盖。
- **同步链路**：启动自动同步（app.dart → `runStartupAutomaticSync`，sync_page.dart:19-69）与手动 `/sync` 页（SyncPageLoader）。本模块环节：启动编排与路由入口、Python 路径读取（settings_service.pythonPath 被 `sync_page.dart:48-52` 消费）。详见同步模块文档。
- **Agent 查询链路**：`/chat` 路由 → `_AgentChatLoader`/`_AgentChatCompositionBuilder`（本模块）→ `AgentComposition.build`（agent 模块，`agent_composition.dart:128`）→ `LazyQuerySourceGateway` 懒启动 Bridge（`agent_composition.dart:41`；网关工厂在 `router.dart:716-732` 装配，含 `SettingsService.pythonPath()` 与 `resolveBridgeLaunchOptions()`/`PythonLocator`）。本模块环节：加载器与生命周期；查询执行本身属 agent 模块。

## 8. 原生目标态对照

> 本节全部内容标注【目标态推断】。不引用任何既有 flutter-native 设计文档，只描述方向与开放决策。

### 8.1 职责是否保留

【目标态推断】"全部数据链路 Flutter 原生化、Bridge 消失"的最终形态中，应用壳层的**职责整体保留**：应用外壳（MaterialApp 装配）、全局导航（路由表/侧边栏/底部导航/全局新建）、主题、全局设置页、`SettingsService` 编排器都是前端框架层职责，与"数据从哪来"无关，不随 Bridge 消失而消失。

消失/变更的部分是壳层中的**平台装配点**，而非壳层本身：
- `router.dart:716-732` 中 `_buildWindowsAgentComposition` 的 Python 定位 + Bridge 握手（`PythonLocator`/`resolveBridgeLaunchOptions`/`WindowsPythonQueryGateway.start`）——Bridge 消失后，该装配点替换为原生查询通道（如直接调用 Dart/原生实现或直连学校系统），但"路由层装配 AgentComposition"这一模式保留。
- `SyncPageLoader` 与 `runStartupAutomaticSync` 的 `BridgeClient.start` 依赖（`sync_page.dart:44-68, 112-135`）——同上。
- `SettingsService.setPythonPath/pythonPath` 的语义（为 Bridge 定位解释器）——Bridge 消失后该项可能失去意义，是否保留待决策（见 8.3）。

### 8.2 保留的契约

【目标态推断】以下契约与 Bridge 无关，预计保留：
1. 路由表结构（path → 页面/加载器映射，第 4.2 节）与 `initialLocation: '/chat'` 的启动语义。
2. `UstcAssistantApp` / `buildRouter` 的构造注入接口（`websiteLauncher`、`database`、`reminderReconciler`、`agentCompositionLoader`）。
3. `SettingsService` 的对外方法集（源开关、JW 学期覆盖、清理类、completeReset）与 `sourceConfigs` 存储格式（`'$accountId:$source'` 主键 + `configJson`）。
4. `OfficialWebsiteLauncher` 抽象与官网白名单列表。
5. 激活账号守卫 + Loader 装配模式（`_activeAccount` + FutureBuilder + 空态）。

### 8.3 开放决策

- **待决策**：`SettingsService.automaticSyncInterval`（12h）与同步模块 `SyncCoordinator.freshness`（`sync_coordinator.dart:56`）是两套并存的"12 小时"常量，前者无消费方；原生态下自动同步的 freshness 策略归属哪一层、是否合并常量。
- **待决策**：账号分区消失后的全局设置模型——`sourceConfigs` 以 `accountId` 分区，若目标态改为单账号/无账号模型，`app_settings` 与 `ustc_jw` 的 id 键格式是否简化。
- **待决策**：设置页"自动同步"项目前为纯展示文本（`settings_page.dart:62-66`），无开关；原生态是否提供真正的自动同步开关。
- **待决策**：深色模式/跟随系统（当前仅亮色，`theme.dart:3-30`）。
- **待决策**：路由/分支状态持久化（当前每次启动回到 `/chat`，无恢复）。
- **待决策**：`pythonPath` 设置项在 Bridge 消失后的去留。
- **待决策**：壳层对 feature 的装配方式——现状是"路由工厂手工装配"（`buildRouter` 中 `FutureBuilder` + 直接 new service），Flutter 官方推荐依赖注入容器；是否引入 DI 为独立决策。

## 9. 开源参考与优化建议

**参考资源**（WebSearch 发现，未抓取 github.com 页面）：
- Flutter 官方应用架构指南（docs.flutter.dev/app-architecture/guide 与 /app-architecture/recommendations）：分层通信规则、Service 与 Repository 边界、依赖注入（package:provider）建议。
- go_router `StatefulShellRoute.indexedStack` 社区实践（dev.to 的 nested-navigation 与 shellroute 文章、renuvkelkar/shell_route_example 指南）以及 flutter/flutter#161724（`goBranchPath` API 提案）。

**可借鉴模式**：
1. StatefulShellRoute 分支下挂载详情子路由：详情页作为分支的嵌套 `GoRoute`，可保持底部导航/侧边栏在详情页可见、分支栈独立。
2. 路由工厂瘦身：官方推荐用代码生成（`@TypedStatefulShellRoute` / 类型安全路由）或路由常量集中管理，避免散落的字符串 path。
3. 依赖注入容器：官方以 provider 为例，建议在树顶暴露 Service/Repository 供装配层消费，而不是在路由工厂里直接 new。

**对本模块的具体建议**（均可落地，供重构参考）：
1. **路由常量化**：`app/lib/app/router.dart` 内 16 条 path（含 2 个分支根路径）字符串（`'/sync'`、`'/settings'`、`'/schedule?section=week'` 等）在 `router.dart:165-197`、`app_drawer.dart:7-18`、`settings_page.dart:59`、`agent_chat_page.dart:443-445` 等处散布，建议统一为 route 常量表，消除拼写漂移。
2. **`_activeAccount` 三态样板收敛**：`_ScheduleConflictsLoader`、`_SettingsLoader`、`_AgentSettingsLoader`、`_HistoryLoader`、`_PersonalEventManagementLoader` 五处重复"FutureBuilder + 加载中 + 请先配置学校账号"模式（`router.dart:307-328, 416-437, 446-472, 482-513, 780-798`），可提取公共 `AccountRequiredLoader` 包装组件。
3. **侧边栏返回语义统一**：`AppDrawer` 全部用 `context.push`（`app_drawer.dart:39`），用户从任一主分支进入侧边栏页面后返回需逐级 pop（测试 `app_shell_test.dart:376-396` 验证）；若产品上希望"侧边栏页面返回主分支根"，需在导航 API 层面统一决策（push 与 go 的语义分工）。
4. **装配点瘦身**：`_buildWindowsAgentComposition`（`router.dart:705-745`）承载 Python 定位、Bridge 启动、DPAPI、秘密存储、组合装配多类职责，Bridge 消失后该函数应拆为"平台查询通道工厂"注入 `AgentComposition.build` 的 `queryGatewayFactory`（`agent_composition.dart:134`），路由层不再直接接触平台细节。
5. **goldens 补壳层**：现有 goldens（`test/goldens/responsive_golden_test.dart`）只覆盖 agent 聊天与周课表两个页面、三个视口；壳层（侧边栏、设置页、官方网页页）无 goldens，建议为壳层组件补充视口快照测试。
6. **清除类操作的确认抽象**：`SettingsPage` 内 `_confirm` 与 `_ask` 两个几乎重复的确认对话框实现（`settings_page.dart:160-178, 205-222`），可合并为一个组件。

## 10. 未验证/存疑事项

**已验证**（全部经 grep/glob/Read 确认）：本模块 8 个源文件及行号；16 条路由（2 分支 + 14 顶层）及其加载器装配；`app_shell_test.dart`、`settings_test.dart`、`complete_reset_flow_test.dart`、`responsive_golden_test.dart`、`scaffold_test.dart` 的存在与关键断言；`AccountService` 5 个方法签名（`account_service.dart:281/347/363/391/407`）；`AgentComposition.build`/`AgentCompositionResult` 结构；`app_database.dart:49-57` 账号变更通知；`sync_page.dart` 的 `runStartupAutomaticSync`/`SyncPageLoader`；`sync_coordinator.dart:56,62-71` 的 freshness；`generated_source_defaults.dart:2-8` 默认学期常量；pubspec 中 go_router 17.3.0 / drift 2.34.2 / url_launcher 6.3.2。

**存疑/未验证**：
1. `SettingsService.automaticSyncInterval`（`settings_service.dart:31`）全库无消费方（grep 仅命中定义行）；设置页"12 小时"文案（`settings_page.dart:65`）实际对应 `SyncCoordinator.freshness`（`sync_coordinator.dart:56`），两者关系未在代码中显式连接。
2. 路由/分支状态不持久化：`initialLocation: '/chat'` 是唯一启动语义，未见路由状态保存/恢复逻辑（未发现 `state.extra` 之外的跨启动状态传递）。
3. 无暗色主题：仅 grep 确认无 `darkTheme`/`ThemeMode` 引用，未逐页检查是否硬编码亮色背景。
4. `_SettingsLoader`/`_HistoryLoader` 等"无激活账号"空态只是守卫拦截（`router.dart:455-457`），无账号时设置页不可达——这是设计意图还是缺陷未在代码注释中说明。
5. `/official-websites` 无独立测试文件，仅 `app_shell_test.dart:356-374` 覆盖白名单行为；`launchUrl` 失败分支（返回 false）未经测试验证。
6. `_TaskCreatePage`/`_CalendarEventCreatePage` 无激活账号时的 `StateError('active account required')` 无 UI 兜底（`router.dart:344-346, 391-393`），异常上抛行为未验证。
7. `EventDetailLoader`、`TaskDetailLoader`、`ConflictManagementLoader`（`event_detail_loader.dart:11`、`task_detail_loader.dart:15`、`conflict_management_page.dart:22`）的内部实现属其他模块，本模块仅验证其存在与路由装配，未细读。
8. `first_milestone_flow_test.dart` / `agent_composition_flow_test.dart`（`test/integration/`）与壳层的交互未逐行核验（grep 未命中直接导航调用，可能使用内部辅助函数）。
9. 窗口尺寸适配仅存在于 goldens 测试（1440x900 / 390x844 / 412x915 三视口，`responsive_golden_test.dart:142-146`），`lib/` 下未发现基于 `MediaQuery` 的断点分支逻辑（grep 未命中），壳层是否有其他响应式行为未确认。
10. `docs/architecture.md` / `docs/schedule-data-model.md` 中的壳层描述未采用（按约束仅以代码为准），其中与本文档结论的差异未逐条比对。
