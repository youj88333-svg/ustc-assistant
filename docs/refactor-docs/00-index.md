# 重构探索导航索引

> 产出日期：2026-08-12 ｜ 覆盖分支：main（HEAD e9d64dd）｜ 编制：主 agent（三阶段汇总）

本索引是 6 份模块技术文档的导航入口：模块清单、四契约锚点全局定义、三条端到端链路图、
目标态迁移总览。模块文档全部以 main 分支实际代码为准；`docs/architecture.md` 与
`docs/schedule-data-model.md` 仅作待验证线索，未采纳其结论。

## 1. 模块文档清单

| 编号 | 文档 | 一句话摘要 |
|------|------|-----------|
| 01 | [01-authentication.md](01-authentication.md) | 端到端认证链路：Python 侧 CAS 登录（Playwright + Edge 持久 profile）、Bridge 认证回环（HTTP 1.0 端点组）、Flutter 本地账号（AccountService + DPAPI 凭据保护）；浏览器会话清理在 main 上为 no-op（存疑） |
| 02 | [02-data-acquisition.md](02-data-acquisition.md) | 全部数据获取：五条 Python 链路（jw / young-schedule / young-enrolment / icourse / campus）、SourceBundle 1.0 与 Query Result 1.0 契约、Bridge 双状态机（CollectionJob / ReadQueryJob）、Flutter 同步端（SyncCoordinator 12h 新鲜度 / 1h 退避 / busy 互斥） |
| 03 | [03-data-storage.md](03-data-storage.md) | Flutter 本地事实来源：Drift/SQLite schemaVersion=7、**27 张表完整数据字典**、迁移史、导入流水线（快照对齐 + digest 幂等）、派生数据链路（EffectiveEventRepository → ScheduleConflictProjection）、覆盖/撤销/审计业务规则 |
| 04 | [04-app-shell.md](04-app-shell.md) | 应用外壳与全局导航：MaterialApp 装配、StatefulShellRoute 双分支（/chat、/schedule）+ 14 条顶层 GoRoute、AppDrawer、主题；SettingsService 跨模块编排器（completeReset 中枢）；Agent 装配点（Bridge 消失后的主要变更面） |
| 05 | [05-schedule-frontend.md](05-schedule-frontend.md) | 日程表业务 UI：25 个 presentation 文件（schedule 14 / tasks 7 / calendar 3 / history 1，reminders 无独立 presentation）；Loader 装配 + 页面纯回调架构；drift watch 流驱动；冲突管理"Loader + 双路由入口 + 混合编辑器"闭环 |
| 06 | [06-agent-harness.md](06-agent-harness.md) | Agent 全部能力（46 个 Dart 文件，约 21.5k 行）：六子结构完整映射（上下文/工具/编排/记忆/观测/约束）；39 个工具（15 只读 + 11 写 + 9 生命周期 + 管理）；Windows 专属仅 2 处（DPAPI 密钥存储、Python 查询网关），注入点 router.dart:705-745 |

## 2. 四契约锚点：全局定义与位置

| 契约锚点 | 全局定义（以 main 代码为准） | 定义位置 | 消费/关联 |
|---------|------------------------------|---------|----------|
| **认证回环** | **无独立命名的协议文件**——它是 Bridge HTTP 协议 1.0 的一组端点与作业事件格式：`/collect/*`、`/login/resume`、`/jobs/{id}/events`、`/query-jobs/{id}/resume-login`；`PROTOCOL_VERSION = "1.0"`（`src/ustc_assistant/bridge/protocol.py:10`），Flutter 侧 `bridgeProtocolVersion = '1.0'`（`app/lib/features/sync/data/bridge_client.dart:9`）。语义核心：作业暂停为 `needs_user_login` 后经 resume 端点恢复同一作业 | 01 §4.1（01-authentication.md:175-177）；02 §4 Bridge Protocol 1.0（02-data-acquisition.md:197） | 01（会话生命周期/恢复）、02（作业状态机）、06（二课报名查询复用查询侧 resume） |
| **SourceBundle 1.0** | 导入/存储层全局契约：envelope（manifest/snapshot/scope/subject）+ SHA-256 digest 幂等 + 10 错误码 + 16MB 上限；canonical 为 `schemas/source-bundle-1.0.schema.json`（draft 2020-12，`$defs`）+ `src/ustc_assistant/contracts/source_bundle.py` + `source_bundle_validation.py`；Flutter 打包副本 `app/assets/schemas/source-bundle-1.0.draft7.schema.json`（draft-07 方言，语义相同，已验证差异仅为 `$defs`/`definitions` 方言形式）。生产者：jw、young-schedule 两条链路 | 02 §4（02-data-acquisition.md:211）；03 §4.4（03-data-storage.md:341） | 02（生产端）、03（导入端 ImportService.importBytes + SourceBundleDecoder） |
| **Query Protocol 1.0** | Bridge 查询通道：POST /queries + ReadQueryJobManager（与采集作业分离）+ QueryResult 1.0 校验；服务端定义在 Python 侧 `src/ustc_assistant/bridge/query_jobs.py` / `query_contracts.py`；Flutter 消费侧为 `WindowsPythonQueryGateway`（200ms 轮询 + 2s 长轮询 + 10min 兜底）。查询型来源（young-enrolment、icourse、campus）产出 **Query Result 1.0**（仅查询、不落库） | 02 §4（02-data-acquisition.md:197）；06 §4 消费侧（06-agent-harness.md:236） | 02（实现）、06（消费侧接口）、01（查询侧认证回环） |
| **实现级数据字典** | Drift/SQLite `ustc_assistant` 库：schemaVersion=7，**27 张表**分布在 6 个表文件（account/source/schedule/task/agent/operation），迁移链 v1→v7（含 v7 三表重建）；action_logs 无索引（历史查询全扫）；`undo_slot` 恒 1 行单槽 | 03 §4.2（03-data-storage.md:241-340） | 全部模块：表结构是全局契约基座；01（账号表语义）、02（sourceConfigs/syncRuns）、04（completeReset 级联）、05（投影流）、06（chat 表族 + action_logs 审计） |

## 3. 端到端链路图

### 3.1 completeReset（清库重置）

```text
设置页用户操作(双重确认)                    模块04
   │  SettingsService.completeReset (settings_service.dart:170-190)
   ▼
┌─ 同一事务内 ──────────────────────────────────────────────┐
│ 删 action_logs(本账户) → 清 undo_slot → 删 local_accounts  │  模块03(表/事务) + 模块06(被动级联)
│ (credential_accounts 随账号级联删除)                       │
│ 业务表(27 张)经 FK ON DELETE CASCADE 连带清空               │  模块03 §4.2 数据字典
└──────────────────────────────────────────────────────────┘
   │
   ├─ accounts.clearDedicatedBrowserSession()  模块01（main 上为 no-op，见 01 §10 存疑#1）
   ├─ Bridge 进程由同步页销毁时 shutdown         模块02
   └─ 路由 context.go('/sync') 回首登态          模块04 router.dart:468
       └─ /chat shell 分支重建(模块04) → 各页面 drift watch 流回到无账号空态(模块05)
```

### 3.2 同步（数据获取与导入）

```text
触发：启动自动同步(app.dart → runStartupAutomaticSync) / 手动 /sync 页(手动+自动)   模块04(壳层编排) + 模块05(sync_page)
   ▼
SyncCoordinator：busy 互斥 → 新鲜度窗口(12h) → 退避(1h) → 错误码     模块02 app/lib/features/sync
   ▼  pythonPath + PythonLocator（settings_service / sync/data）     模块04(pythonPath) + 模块02(locator)
Bridge 启动 → POST /collect/* (携账号凭据)                           模块02 src/ustc_assistant/bridge/server.py
   ▼
CollectionJob 状态机：phase 转换、needs_user_login 暂停/恢复、       模块02 jobs.py + 模块01(认证回环、凭据解密出口)
   cancel_check 协作式取消、事件 sequence 长轮询
   ▼
SourceBundle 1.0（envelope + digest，作业内先校验后交付）             模块02 contracts/ + schemas/
   ▼
ImportService.importBytes：解码 → 语义校验 → 单事务导入 →           模块03 import/
   提醒协调(失败降级 pending) → syncRuns/importBatches/sourceRecords 落库
   ▼
派生数据链路 → 周课表/任务区 watch 流自动刷新                        模块03(投影) + 模块05(页面)
```

### 3.3 Agent 查询（聊天 → 按需来源）

```text
聊天页 /chat → _AgentChatLoader/_AgentChatCompositionBuilder           模块04 router.dart:526-745
   │  缓存 composition 避免 rebuild 重复 Bridge 握手
   ▼
AgentComposition.build → LazyQuerySourceGateway 懒启动 Bridge          模块06 agent_composition.dart:41-113
   │  （网关工厂注入点 router.dart:716-732，Windows 专属）             模块04(装配) + 模块06(WindowsPythonQueryGateway)
   ▼
POST /queries → ReadQueryJobManager → 二课报名/评课/校园查询            模块02 bridge/query_jobs.py（Query Protocol 1.0）
   │  200ms 轮询 + 2s 长轮询 + 10min 兜底；查询侧认证回环复用          模块02 + 模块01
   ▼
QueryResult 1.0 校验 → AgentSessionService 推理循环                    模块06
   │  上下文构建(滚动摘要) → 工具调用(39 工具) → 预算/权限门/隐私过滤
   ▼
本地读写：有效事件/冲突/覆盖/撤销预览/历史（get_schedule 等）          模块03（AgentLocalDataGateway 聚合读服务）
   └─ 写路径：业务写 + ActionLog + 确认日志同事务原子提交               模块03(事务) + 模块06(审批门)
```

## 4. 目标态迁移总览（全部【目标态推断】，见各文档第 8 节）

> 目标态：全部数据链路 Flutter 原生化、Python Bridge 消失。

| 模块 | 职责保留/消失/迁移 | 被保留契约 | 关键待决策 |
|------|-------------------|-----------|-----------|
| 01 认证与账号 | **保留**，载体迁移：Python CAS 自动化 + Bridge 认证回环消失，登录会话改由 Flutter 平台侧承载；"学校登录会话"与"本地账号"两段职责合并为 Flutter 单侧 | CredentialProtector 抽象、AccountService 对外 API、账号隔离语义、`needs_user_login` 暂停-恢复交互模型 | 登录会话方案（WebView 分区 vs cookie 容器）；会话健康探测时机 |
| 02 数据获取 | **大体保留但载体迁移**：五链路采集逻辑 Python→Flutter；Bridge HTTP 通道消失；同步编排保留为纯 Dart 协调层；CLI 可能退出或降为调试工具 | SourceBundle 1.0 必然保留；Query Result 1.0 envelope 大概率保留；作业事件"可恢复进度"语义延续（形态待定） | 每链路适配器形态（WebView 驱动 vs 原生 HTTP）；登录交互原生化；campus 目录存储归属；采集/查询互斥模型 |
| 03 数据存储 | **保留**（与数据来源解耦，只消费 bundle 字节流）；"生成 SourceBundle"职责需寻找新宿主 | 27 表结构 + schemaVersion 迁移线、SourceBundle 1.0、审计/撤销/提醒协调契约、服务级读接口 | SourceBundle 生产端（Dart 采集器 vs 打包 Python）；`source_records/sync_runs/import_batches` 状态机是否简化；单槽撤销是否升级多槽 |
| 04 应用壳层 | **职责整体保留**；Bridge 装配点消失（`_buildWindowsAgentComposition`、pythonPath/PythonLocator） | 路由表（StatefulShellRoute + 14 GoRoute）、AppDrawer、SettingsService 编排器 | （无重大待决策；受影响面集中在装配点替换） |
| 05 日程表前端 | **保留**，受影响最小（纯 UI，无 Bridge/Python 依赖）；页面构造参数与路由契约无需结构性改动 | 页面构造参数形态、路由路径与 payload、`ScheduleSection` 枚举、drift watch 流投影模式 | 状态管理是否引入框架；WeekTimetable 是否抽包；单槽撤销去留；时间语义是否统一时区模型 |
| 06 agent/harness | **核心保留**（推理循环/工具/上下文/审批门/隐私过滤/持久化与数据链路无关）；Windows 专属适配层中 Bridge 查询网关消失 | QuerySourceGateway 抽象可保留（实现替换为 Dart 原生）；Query Protocol 1.0 消费侧形态待演进 | Query Protocol 1.0 消费侧演进（轮询形态 vs 直接流式）；`defaultSystemPromptVersion=3` 与提示词 v8 不一致 |

## 5. 跨文档一致性说明

- 各模块第 7 节对三条端到端链路（completeReset / 同步 / Agent 查询）均有环节描述，无归属冲突：completeReset 编排归 04（settings_service）、事务与级联归 03、浏览器侧 no-op 归 01；同步执行归 02、导入落库归 03、页面刷新归 05、壳层触发归 04、Agent 只读消费归 06；Agent 查询执行通道归 02、消费侧归 06、本地数据面归 03。
- 模块文档间互相引用的文件路径均经 grep/glob 验证；`schemas/source-bundle-1.0.schema.json` 与 `app/assets/schemas/source-bundle-1.0.draft7.schema.json` 经 diff 验证为同一 schema 的 draft 2020-12 / draft-07 双方言版本，语义相同。
- 03 文档第 7 节以"模块 0X 待确认"标注的交叉引用编号，以本索引的模块编号为准。
