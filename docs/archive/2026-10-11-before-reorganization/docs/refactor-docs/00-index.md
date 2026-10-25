# 重构文档索引

> 更新日期：2026-10-11 ｜ 适用分支：`codex/design-reset` ｜ 当前状态：第三轮总体审查及普通修订完成，
> 07–15 当前规则及全项目工作流标准已回写；M0、首源教务 M1 与二课 M2 已经自动检查及用户验收正式关闭，整体冻结未完成。完整导航见
> [`docs/README.md`](../README.md)。

M1 已完成首源教务的业务身份、固定只读采集、加密凭据/自动认证、事务导入及本地日程，并于 2026-10-10 获用户验收关闭；真实非空考试经批准留作后续补验，仍未观察，其余来源与完整 V 项继续按阶段验证。唯一关闭记录见 [15 M1 用户验收](15-construction-methodology.md#m1-用户人工验收与关闭2026-10-10)。

本索引收纳模块快照、当前修订、契约锚点、端到端链路和历史迁移总览。`07-constitution.md`
至 `15-construction-methodology.md` 的“本分支当前规则”是当前设计依据，后附“历史设计资料”
完整保留旧正文。`01-authentication.md` 至 `06-agent-harness.md` 是旧房实现的冻结快照，
只用于理解历史能力，不覆盖新决定。
除 00–15 文档外的原工程内容均未带入。文中旧源码、Schema、来源契约和产品模型路径
保留历史含义，实际所需输入在重新设计时定义。

M2 已于 2026-10-11 经用户验收正式关闭：58 条活动/6 页，日程覆盖 31 天/31 页并导入 2 条，两项全程自动且显示正确；活动必要信息、重启不重复、隐藏恢复与取消、清二课资料后的两来源连续性三组全部通过。门户/回调与 ready/busy 修复后的最终 analyze、482 本地测试（1 个平台反例跳过）、两套 Windows 共 7 组和正式 Release 构建通过，原 staleResult/busy 失败保留。共享学校密码、独立来源身份/分区/许可及查询与日程用途保持，范围见 [15 M2 任务单](15-construction-methodology.md#m2-二课来源任务单2026-10-11)，唯一验收与关闭依据见 [15 关闭记录](15-construction-methodology.md#m2-用户人工验收与关闭2026-10-11)。

## 当前入口（从设计重新开始）

- 当前状态与重新确认顺序：[`docs/README.md`](../README.md)。
- 项目协作方式：根目录 [AGENTS.md](../../AGENTS.md)及 [15 当前工作流标准](15-construction-methodology.md)；Sol 总负责，Luna 承接明确任务，Sol 集成验收，Astra 按需参与。
- 范围确认、历轮发现、重新裁决和修复状态：[`设计架构审核记录`](../design-review.md)。文档修订不等于真实验收或新设计冻结。
- 新建前置验证与脱敏证据：[verification 任务单](../../verification/README.md)；关键模型自动实验已有结果，Windows 缺口和真实来源继续验证。
- 原实现与施工流程已退出本分支。其里程碑完成状态、测试结果、任务号和历史路径
  不构成本分支的完成证据；新的设计结论与 M0 实现须重新建立。

## 0. 设计阶梯与施工文档入口（07–15）

| 编号 | 文档 | 一句话摘要 |
|------|------|-----------|
| 07 | [07-constitution.md](07-constitution.md) | 当前产品/安全约束与 DR-ADR-01–10 修订决定 |
| 08 | [08-target-architecture.md](08-target-architecture.md) | 单工程模块边界、依赖、来源注册与原生目标 |
| 09 | [09-contracts.md](09-contracts.md) | K-01–06：身份、分区、文档关联、作业、导入、连续性 |
| 10 | [10-runtime.md](10-runtime.md) | 首登、恢复、同步/查询、维护与启动调和 |
| 11 | [11-component-designs.md](11-component-designs.md) | 此次修订涉及的状态机与有效日程投影 |
| 12 | [12-cross-cutting.md](12-cross-cutting.md) | 当前横切归属、隐私、事务、恢复与平台约束 |
| 13 | [13-risks-and-acceptance.md](13-risks-and-acceptance.md) | V-01–08 新验证项，旧证据不关闭新项 |
| 14 | [14-overall-review.md](14-overall-review.md) | A–D 审查方法、13 场景、独立复核裁决与阶段放行范围 |
| 15 | [15-construction-methodology.md](15-construction-methodology.md) | 全项目分工与验收标准、最小验证先行、M0 协作与细切片交付 |

## 1. 模块文档清单

| 编号 | 文档 | 一句话摘要 |
|------|------|-----------|
| 01 | [01-authentication.md](01-authentication.md) | 端到端认证链路：Python 侧 CAS 登录（Playwright + Edge 持久 profile）、Bridge 认证回环（HTTP 1.0 端点组）、Flutter 本地账号（AccountService + DPAPI 凭据保护）；浏览器会话清理在 main 上为 no-op（存疑） |
| 02 | [02-data-acquisition.md](02-data-acquisition.md) | 全部数据获取：五条 Python 链路（jw / young-schedule / young-enrolment / icourse / campus）、SourceBundle 1.0 与 Query Result 1.0 契约、Bridge 双状态机（CollectionJob / ReadQueryJob）、Flutter 同步端（SyncCoordinator 12h 新鲜度 / 1h 退避 / busy 互斥） |
| 03 | [03-data-storage.md](03-data-storage.md) | Flutter 本地事实来源：Drift/SQLite schemaVersion=7、**27 张表完整数据字典**、迁移史、导入流水线（快照对齐 + digest 幂等）、派生数据链路（EffectiveEventRepository → ScheduleConflictProjection）、覆盖/撤销/审计业务规则 |
| 04 | [04-app-shell.md](04-app-shell.md) | 应用外壳与全局导航：MaterialApp 装配、StatefulShellRoute 双分支（/chat、/schedule）+ 14 条顶层 GoRoute、AppDrawer、主题；SettingsService 跨模块编排器（completeReset 中枢）；Agent 装配点（Bridge 消失后的主要变更面） |
| 05 | [05-schedule-frontend.md](05-schedule-frontend.md) | 日程表业务 UI：25 个 presentation 文件（schedule 14 / tasks 7 / calendar 3 / history 1，reminders 无独立 presentation）；Loader 装配 + 页面纯回调架构；drift watch 流驱动；冲突管理"Loader + 双路由入口 + 混合编辑器"闭环 |
| 06 | [06-agent-harness.md](06-agent-harness.md) | Agent 全部能力（46 个 Dart 文件，约 21.5k 行）：六子结构完整映射（上下文/工具/编排/记忆/观测/约束）；39 个工具（15 只读 + 11 写 + 9 生命周期 + 管理）；Windows 专属仅 2 处（DPAPI 密钥存储、Python 查询网关），注入点 router.dart:705-745 |

## 2. 历史契约锚点与实现总览

以下 §2–§5 只保留旧实现及目标态推断。当前契约以 09 的 K-01–06 为准，旧 main 代码、Schema、固定迁移和并存链路不构成本分支依据。

| 契约锚点 | 全局定义（以 main 代码为准） | 定义位置 | 消费/关联 |
|---------|------------------------------|---------|----------|
| **认证回环** | **无独立命名的协议文件**——它是 Bridge HTTP 协议 1.0 的一组端点与作业事件格式：`/collect/*`、`/login/resume`、`/jobs/{id}/events`、`/query-jobs/{id}/resume-login`；`PROTOCOL_VERSION = "1.0"`（`src/ustc_assistant/bridge/protocol.py:10`），Flutter 侧 `bridgeProtocolVersion = '1.0'`（`app/lib/features/sync/data/bridge_client.dart:9`）。语义核心：作业暂停为 `needs_user_login` 后经 resume 端点恢复同一作业 | 01 §4.1（01-authentication.md:175-177）；02 §4 Bridge Protocol 1.0（02-data-acquisition.md:197） | 01（会话生命周期/恢复）、02（作业状态机）、06（二课报名查询复用查询侧 resume） |
| **SourceBundle 1.0** | 导入/存储层全局契约：envelope（manifest/snapshot/scope/subject）+ SHA-256 digest 幂等 + 9 错误码（L2-07 修正，旧记"10 个"为计数笔误）+ 16MB 上限；canonical 为 `schemas/source-bundle-1.0.schema.json`（draft 2020-12，`$defs`）+ `src/ustc_assistant/contracts/source_bundle.py` + `source_bundle_validation.py`；Flutter 打包副本 `app/assets/schemas/source-bundle-1.0.draft7.schema.json`（draft-07 方言，语义相同，已验证差异仅为 `$defs`/`definitions` 方言形式）。生产者：jw、young-schedule 两条链路 | 02 §4（02-data-acquisition.md:211）；03 §4.4（03-data-storage.md:341） | 02（生产端）、03（导入端 ImportService.importBytes + SourceBundleDecoder） |
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
