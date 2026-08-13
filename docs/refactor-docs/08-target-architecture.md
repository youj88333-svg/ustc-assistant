# 08 目标架构：容器切分（六层阶梯 · 第 1 层）

> 产出日期：2026-08-12 ｜ 状态：**第 1 层已确认（2026-08-12）** ｜ 依据：`07-constitution.md`（ADR-000~018）、
> `00-index.md` 三条端到端链路、01–06 模块文档

## 1. 本层目标与 gate

- 目标：定义系统边界、容器级块（C4 模型 Container 层）、依赖方向、容器级技术选型。
  **只到容器级，不进组件**（组件级状态机、接口签名细节属第 2/4 层）。
- **gate：① 三条链路能用容器名走通；② 容器职责无重叠、无缺口；③ ADR-000~018 每条
  都能溯源到容器或边界。**（检查表见 §10）

## 2. 系统上下文（C1：外界与系统边界）

```
外部系统
  ├─ 学校网站：jw.ustc.edu.cn / young.ustc.edu.cn / id.ustc.edu.cn（CAS）
  │           登录态 + 页面交互型，不可信数据（红线 2.1 原则 4）
  ├─ 公开网站：icourse.club / teach.ustc.edu.cn / finance.ustc.edu.cn
  │           公开 HTTP 型，同样视为不可信数据
  ├─ USTC LLM 网关：api.llm.ustc.edu.cn（Anthropic 兼容，SSE + tool_use/tool_result）
  └─ 平台：Windows（当前）/ Android / iOS（正式版后，红线 2.2-8）

系统边界
  ├─ 单 Flutter App、单进程（目标态）
  ├─ 本地优先：SQLite + 平台安全存储（DPAPI）为唯一本地事实来源
  ├─ 目标态不存在：Python / Bridge / CLI（并存期租户见 §8，M7 移除）
  └─ 云服务：远期可选（双向门 D26），当前不在边界内
```

出站边界铁律（红线 2.1 原则 2 的容器级落点）：**一切对外网络出口只有两个容器**——
采集引擎（学校/公开网站）与 Agent 的 LLM 网关客户端；其余容器物理上不持有网络能力
（纯 Dart 层无 `dart:io`，ADR-018）。

## 3. 容器总览（C2）

```
┌────────────────────────── 单 Flutter App（单进程） ──────────────────────────┐
│                                                                              │
│  C5 应用壳层 AppShell（组合根）                                              │
│    路由/页面/装配（手工装配，D21 双向门）；启动后台编排；completeReset 编排    │
│        │ 装配并调用                                                        │
│        ├──────────────► C2 同步编排 SyncOrchestration                       │
│        │                  触发判定（freshness 单常量 ADR-013）/退避/状态落库 │
│        │                  来源通道注册表（Native|Python 一源一通道 ADR-004）│
│        │                        │ 启动作业（卡槽租约 ADR-004）              │
│        │                        ▼                                           │
│        │                 C1 采集引擎 SourceEngine                            │
│        │                  WebSessionEngine（卡槽/探测/清理 ADR-002）          │
│        │                  JobGate（租约/全局门/来源门 ADR-004）               │
│        │                  JobEventStream（事件流 ADR-005）                   │
│        │                  HttpSourceClient（公开 HTTP + 缓存）               │
│        │                  5×SourceAdapter（fetch→normalize→validate→deliver │
│        │                    ADR-001；jw 含学期列表抓取 ADR-009）             │
│        │                        │ deliver：SourceBundle 1.0 / QueryResult   │
│        │                        ▼                                           │
│        └──────────────► C3 导入与存储 ImportAndStorage                       │
│                           ImportService（解码→语义→幂等→事务→提醒协调）       │
│                           27 表 + v8 变更集（ADR-011）+ v7→v8 迁移器（ADR-012）│
│                           聚合根级服务（有效事件/冲突/覆盖/重复/任务/计划块/  │
│                           撤销（ADR-010）/提醒/历史/campus 目录（ADR-007））  │
│                                                                              │
│  C4 Agent harness                                                           │
│    AgentSessionService（推理循环，形态不动）+ 工具系统（能力域注册，M6 审计后定稿）│
│    AgentLocalDataGateway（应用层跨聚合门面 ADR-017）──► C3                   │
│    AgentWriteGateway（端口适配器，原子事务）──► C3                           │
│    QuerySourceGateway v2（QueryJob 进程内对象 ADR-016）──► C1                │
│    LLM 网关客户端（仅出站到 USTC LLM）                                       │
│    feature 内聚合 + subpackage_lint 边界（ADR-018）                          │
│                                                                              │
│  C0 共享核心 SharedCore：BeijingClock/time 工具箱（ADR-015）、               │
│    CredentialProtector 端口、纯 Dart 工具 —— 全容器共用、零依赖              │
│                                                                              │
│  P 平台适配边界（实现注入，三端替换点，红线 2.2-8）                           │
│    WebView2（Windows）| DPAPI | 前台通知 | URL launcher                    │
└──────────────────────────────────────────────────────────────────────────────┘
```

容器职责一句话表：

| 容器 | 职责 | 继承旧房 | 关键 ADR |
|---|---|---|---|
| C0 SharedCore | 时间/安全端口/工具，纯 Dart | `core/` | ADR-015 |
| C1 SourceEngine | 采集/查询的引擎：会话、互斥、事件流、五适配器 | Python `common/`+`sources/`+`bridge/jobs` 语义 | ADR-001~005、009 |
| C2 SyncOrchestration | 同步编排：触发/新鲜度/退避/通道注册表/状态落库/并存期 Python 进程 | `features/sync`（Bridge 相关部分删除） | ADR-004、008、013 |
| C3 ImportAndStorage | 导入流水线 + 27 表 + 全部业务服务 | `features/import` + `core/database` + 各 feature 的 domain/application | ADR-006~012、017 |
| C4 AgentHarness | 推理循环 + 工具 + 审批门 + 查询/写网关 | `features/agent`（Windows 适配替换） | ADR-016~018 |
| C5 AppShell | 路由/页面/装配/重置编排/设置 | `app/` + 各 presentation + `features/settings` | ADR-013 |
| P PlatformAdapters | WebView2/DPAPI/通知/launcher 实现 | 现状 Windows 实现 | 红线 2.2-8 |

## 4. 依赖方向（铁律）

```
允许的依赖（单向，无环）：
  C5 AppShell      → C2 / C3 / C4 / C0
  C2 SyncOrch.     → C1 / C3 / C0
  C4 AgentHarness  → C1 / C3 / C0 / P(DPAPI)
  C1 SourceEngine  → C0 / P(WebView)
  C3 ImportStorage → C0
  C0 SharedCore    → （无）
  P 平台适配       → 平台 SDK（被注入，不反向依赖业务）

禁止：
  C1/C2/C3/C4/C0 引用 Flutter Widget（UI 只在 C5）
  C3 不持有网络能力（学校数据只能来自 C1 的 deliver）
  C1 不写库（落库唯一入口 = C3 ImportService；campus 目录经 C3 服务写，ADR-007）
  C4 不直接碰表（必须经 C3 服务或网关，ADR-017）
  平台无关核心（C0/C1 纯 Dart 部分/C2/C3 服务/C4 核心）无 dart:io（ADR-018 lint 守护）
```

## 5. 容器职责与边界

### 5.1 C1 采集引擎 SourceEngine

- **职责**：五条链路 fetch→normalize→validate→deliver 的统一宿主；会话卡槽、作业互斥、
  作业事件流、学期解析。
- **包含**：
  - `BrowserSessionPort`（稳定端口，基础操作级）：goto / waitForSelector / click / fill /
    evaluate / cookies / storage / verify——只含任何驱动都能实现的基础操作；**自动化语义层
    （就绪判定、事件顺序、导航状态机）为共享 Dart，写一次、三端共用**（v2 教训的架构化兑现）；
  - `WebSessionEngine`：卡槽生命周期（按账号独立 UserDataFolder，引擎独占，ADR-002）、
    收集前健康探测、真清理、CAS 交互登录（白名单填表/三层核验/验证码交人工，ADR-003）；
  - `JobGate`：卡槽租约（采集×查询同钥匙互斥）、全局单活跃门、来源级门（一源一通道，ADR-004）；
  - `JobEventStream`：进程内事件流（七相位 + safeCount + 热流重放，ADR-005）；
  - `HttpSourceClient`：公开 HTTP + 24h/30min 缓存策略（icourse/campus）；
  - `5×SourceAdapter`：jw（含学期列表抓取 + 月份规则默认，ADR-009）、young-schedule、
    young-enrolment、icourse、campus；各适配器 normalize 段保留独立 DOM/接口/解析规则；
  - `QueryJob`：查询作业对象（submit→QueryHandle{events,cancel,resumeLogin}，ADR-016）。
- **不包含**：落库（deliver 交给 C3）；同步触发/新鲜度判断（C2）；Agent 推理（C4）。
- **对外接口预告**（签名细节归 09-contracts）：`startCollection(job)`、
  `submitQuery(query)`、`resumeLogin`/`cancel`、`probeSession(account)`、事件流订阅。

### 5.2 C2 同步编排 SyncOrchestration

- **职责**：同步的触发判定、顺序、退避、状态落库、通道注册、结果交接；并存期 Python
  通道进程生命周期。
- **包含**：`SyncCoordinator`（freshness/backoff 单常量，ADR-013）、`syncRuns/sourceConfigs`
  状态读写（经 C3 同步状态服务）、**来源通道注册表**（`SourceChannel` 接口：Native 实现 /
  Python 租户实现，注册表保证一源一通道，ADR-004）、busy 预检（轻量 in-flight 标志，仅用于
  触发判定；**权威互斥在 C1 JobGate**）、`recoverInterruptedRuns` 启动恢复、
  **Python 进程生命周期**（并存期启动/关闭/句柄持有；C4 查询租户经 C2 取句柄，M7 随租户删除）。
- **不包含**：作业执行（C1）；导入落库（C3）；凭据管理（C3 账号服务 + C0 保护端口）。
- **对外接口预告**：`sync(source, trigger)`、`syncAll`、`firstLoginSync`、
  `reauthenticate`、`resumeInteractive`（语义照搬旧房，01§4.2 的 AccountService 契约）。

### 5.3 C3 导入与存储 ImportAndStorage

- **职责**：本地事实来源。SourceBundle/QueryResult 的落库与查询、全部业务服务、迁移器。
- **包含**：
  - `ImportService`（解码→语义校验→幂等→单事务→提醒协调；导入守卫：校验活动账号与
    作业一致，ADR-004）；
  - 27 表 + schema v8 变更集（campus 目录表族、删 undo_slot.expires_at、action_logs
    索引、prompt 版本统一；migration-only + 迁移测试，ADR-011）+ `v7→v8 迁移器`
    （唯一搬家路径，ADR-012）；
  - 聚合根级服务：有效事件/冲突投影/覆盖/重复系列/任务/计划块/撤销（单槽 + 启动清槽，
    ADR-010）/历史审计/campus 目录服务（节流/过期/降级语义，ADR-007）/
    账号与凭据服务（单账号模型，ADR-004；**随数据留 C3，保护能力经 C0 端口**）/
    提醒协调（**协调逻辑在 C3、通知投递适配器在 P、启动编排在 C5**，三段切分）；
  - 学期三元组持久化（`sourceConfigs.configJson`，ADR-009）。
- **不包含**：任何采集/网络（C1 专属）；UI（C5）；Agent 推理（C4）。
- **v8 候选变更累积表**（第 2 层冻结前持续记账；冻结依据 ADR-011）：

| # | 变更 | 来源决策 | 类型 |
|---|---|---|---|
| 1 | campus 目录表族新增 | ADR-007 | 加表 |
| 2 | `undo_slot.expires_at` 删除 | ADR-010 | 删列 |
| 3 | `action_logs` 加 `(account_id, occurred_at)` 索引 | D10 / 03§9 建议2 | 索引 |
| 4 | Agent prompt 版本三处统一（表默认 2 / 常量 3 / 实际 v8） | D10 / 06§10-2 | 数据修复 |

- **对外接口预告**：服务级读接口（EffectiveEventRepository/ConflictService/…）、
  `ImportService.importBytes`、写服务（乐观锁 + 事务 + 审计 + Undo 快照同事务）。

### 5.4 C4 Agent harness

- **职责**：本地助手。推理循环、工具系统、审批门、隐私过滤、滚动摘要、持久化、查询网关。
- **工具系统原则（本层定框架，工具清单 M6 审计后定稿）**：
  - 能力域组织：本地读 / 外部读 / 本地写 / 生命周期 / 管理 / 元域（撤回、权限）——域清单
    是容器契约；**域内工具清单是 M6 审计产物，不携带旧房"39 工具"数字进入新架构**；
  - 每轮作用域收窄：grounding `initialAllowedTools` 延续（attention-scoping 模式，
    [参考](https://github.com/breeznik/attention-scoping-pattern)）；
  - **M6 前置任务：工具审计**——产出覆盖矩阵（用户意图 × 工具）、冗余合并方案
    （参数化合并优先，[参考](https://github.com/agentpatterns-ai/website/blob/main/tool-engineering/consolidate-agent-tools.md)）、
    声明成本评估；审计通过后清单定稿。**审计必答题：批量删除/清理缺口（D32）**——
    `create_task` 有 32 突发批量建、却无对等批量清；候选方向"执行逐项 + 确认卡清单预览 +
    一次复合撤销"，M6 拍板。
- **包含**：`AgentSessionService`（8×12 预算、暂停/恢复、确认卡——形态不动）、
  六子结构（上下文/工具/编排/记忆/观测/约束）、`AgentLocalDataGateway`（应用层跨聚合
  门面，ADR-017）、`AgentWriteGateway`（端口适配器，原子事务）、`QuerySourceGateway v2`
  （QueryJob 进程内直连 C1，ADR-016；QueryResult 1.0 信封保留作安全载体）、
  LLM 网关客户端（SSE 流式 + tool_use/tool_result，唯一 LLM 出站）、
  `ProtectedAgentSecretStore`（DPAPI 经 C0 保护端口）。
- **不包含**：学校数据采集（C1）；业务服务本体（C3）；页面（C5）。
- **边界纪律**：domain/application 零平台依赖（ADR-018）；feature 内聚合不拆包。

### 5.5 C5 应用壳层 AppShell

- **职责**：组合根。路由（GoRouter 双分支 + 顶层路由）、页面（周课表/任务/日程/历史/
  设置/聊天）、Loaders 装配、启动后台编排（提醒启动 + 自动同步）、completeReset 编排、
  官方网页白名单。
- **壳层契约**：分支栈语义 = `StatefulShellRoute.indexedStack` 保活
  （`AutomaticKeepAliveClientMixin`），禁止改为丢栈行为（规避 go_router
  [issue #190914](https://github.com/flutter/flutter/issues/190914) 的姿势固化）；
  启动后台编排为 best-effort（失败不阻塞启动）。
- **不包含**：任何业务逻辑（页面纯回调，服务在 C3/C4）。
- **双向门预览**：状态管理框架（D20）、DI（D21）、深色模式（D22）、路由持久化（D23）
  均在此容器 M5 时评估；本层不预拍。

### 5.6 P 平台适配边界

- Windows 实现：WebView2（`UserDataFolder` 卡槽）、DPAPI（`CryptProtectData`）、
  前台通知适配、URL launcher。
- 移动端实现（D29，Windows 正式版后）：平台 WebView（Android WebView / iOS WKWebView）
  + JS 驱动，实现同一 `BrowserSessionPort`；**风险：学校网站/CAS 对嵌入 WebView 的
  兼容性（UA 识别、防嵌入、cookie 容器差异）未在旧房验证，D29 阶段专项验证**。
- 三端替换点：以同接口换实现（红线 2.2-8；跨平台契约如 ADR-002 的
  "清理=物理删除、探测=健康状态"必须逐条保持）。
- 实现机制（LocalSend 式，[参考](https://deepwiki.com/localsend/localsend/4-platform-specific-implementations)）：
  纯 Dart 平台代码走条件导入（`impl_io.dart`/`impl_stub.dart`），原生能力走平台通道，
  统一在组合根注入；**不引入 federated plugin 结构**（单 App 不需要）。
- 能力矩阵：各适配器维护"平台×能力"声明矩阵（如"清理=物理删除"Windows ✅ / 移动端
  D29 待实现），平台不对齐为声明性、可验收状态。

## 6. 容器级技术选型

| 项 | 选型 | 依据/状态 |
|---|---|---|
| 语言/框架 | Dart + Flutter 单工程（三端一套代码） | 红线 2.2-8 |
| UI | Material 3（现有主题体系） | C5 保留 |
| 导航 | GoRouter（StatefulShellRoute 双分支） | C5 保留 |
| 数据库 | Drift/SQLite（单文件 `ustc_assistant`） | C3 保留；v8 变更 ADR-011 |
| 浏览器驱动 | **嵌入 WebView 统一路线**：Windows=WebView2（UserDataFolder 卡槽）；移动端=平台 WebView + JS 驱动（Android WebView / iOS WKWebView）。统一经 `BrowserSessionPort`；自动化语义层共享 Dart；**具体包选型待 M2 第 4 层** | ADR-001/002；2026-08-12 用户拍板 |
| HTTP | 引擎内 HTTP 客户端；**具体包待 M2/M4 第 4 层** | ADR-001 |
| LLM 传输 | SSE 流式客户端（现状语义） | C4 保留 |
| 安全存储 | DPAPI（经 CredentialProtector 端口） | 红线 2.1 原则 1 |
| 时间 | `core/time` 工具箱：epoch ms + Asia/Shanghai | ADR-015 |
| 状态管理/DI | 维持"服务构造 + 手工装配" | D20/D21 双向门，M5 评估 |
| 包管理 | 单 pub 包（不拆包；subpackage_lint 守边界） | ADR-018 |

## 7. 三条链路容器级走查（gate 验证）

### 7.1 同步链路（首次登录/手动/自动）

```
C5 触发（启动自动/设置页/同步页）
  → C2 判定：freshness 单常量 / busy 互斥 / 单账号存在
  → C2 通道选择（一源一通道）
  → C1 JobGate 租卡槽 → SourceAdapter.fetch（含学期解析 + CAS 会话探测 ADR-002）
      ├─ 会话过期 → needs_user_login（C1 事件流）→ C5 弹确认 → C1 resumeLogin（ADR-003）
      └─ 成功 → normalize → validate → deliver SourceBundle 1.0
  → C3 ImportService（解码→幂等→单事务落库→导入守卫→提醒协调）
  → C2 状态落库（syncRuns/sourceConfigs）→ C5 页面 drift 流自动刷新
```
无重叠无缺口：触发归 C2、执行归 C1、落库归 C3、展示归 C5；凭据只在 C1 交互登录与
C3 存储之间经 C0 端口流动。

### 7.2 Agent 查询链路（外部 + 本地）

```
外部（查二课/评课/校园）：
  C4 外部工具 → QuerySourceGateway v2 → C1 QueryJob（租约门 ADR-004）
    → 事件流（进度/needs_user_login/终态，ADR-005/016）
    → QueryResult 1.0 信封安全校验 → C4 工具结果净化 → 入对话
本地（读课表/任务、写日程）：
  C4 工具 → AgentLocalDataGateway（应用层门面）→ C3 各聚合根服务
  写路径 → AgentWriteGateway → C3 写服务（业务+审计+确认日志同事务）
```
无重叠无缺口：外部数据的唯一通道 = C1；本地数据的唯一通道 = C3；C4 不持有网络、
不直接碰表。

### 7.3 completeReset 链路

```
C5 设置页双确认 → C3 事务（删 action_logs/undo_slot/local_accounts，级联清表）
  → C3 通知账号变更 → C1 卡槽真清理（ADR-002；旧房 no-op 修正）
  → C1 终止全部作业（ADR-004）→ C5 路由回 /sync 首登态 → 各页空态
```
无重叠无缺口：编排归 C5、事务与级联归 C3、会话清理归 C1、路由归 C5。

## 8. 并存期视图（M2–M6，临时租户）

| 来源 | 原生通道 | Python 通道（租户，M7 删） | 切换点 |
|---|---|---|---|
| jw | C1 NativeJwAdapter（M2） | PythonJwGateway（Bridge） | C2 通道选择器 |
| young-schedule | C1（M3） | 同上 | C2 |
| young-enrolment / icourse / campus（查询） | C1 QueryJob（M3/M4） | PythonQueryGateway | C4 网关工厂 |
| 租户清单 | — | BridgeClient/PythonLocator/全部 PythonXxxGateway | M7 一次移除 |

并存期铁律（ADR-000 四铁律 + ADR-004 一源一通道）：同一来源同一时刻单通道；租户
只读不写库（写库唯一入口仍为 C3 ImportService）；**Python 进程生命周期由 C2 统一管理**
（C4 的查询租户经 C2 取进程句柄，不各自拉起）。

## 9. 移交登记消化映射（§2.5 的 13 项 → 本层结论或后续层归属）

| 移交项 | 本层结论 |
|---|---|
| SourceBundle 1.0 信封/digest/错误码 | C1 deliver + C3 校验器；细节 → `09-contracts.md` |
| 27 表 + v8 迁移线 | C3；v8 变更集清单 → `09-contracts.md`（D10 冻结） |
| 账号隔离机制 | 单账号模型（ADR-004）；表结构照旧 → `09-contracts.md` |
| 北京时间 | C0 time 工具箱（ADR-015）；横切 → `12-cross-cutting.md` |
| 认证回环/Query Protocol 语义 | C1 事件流 + QueryJob（ADR-003/005/016），已消化 |
| 学校来源 upsert / 冲突判定序 / 重复系列 / Task 四态 | C3 服务语义照搬；细节 → `09-contracts.md` |
| 提醒默认偏移（15min） | 双向门（E 组），M5 拍 |
| SourceBundle 范围/信封细节 | → `09-contracts.md` |
| Agent 写提交同事务 | C4 网关 + C3 事务（已消化）；细节 → `09-contracts.md` |

## 10. 本层 gate 检查表

- [x] 三条链路容器名走通（§7.1–7.3；登录恢复穿插其中已显式化）
- [x] 容器职责无重叠无缺口（§5 五容器 + 平台边界；网络唯一出口 C1/C4、写库唯一入口 C3）
- [x] ADR-000~018 全部溯源到容器（§3 表"关键 ADR"列 + §9）
- [x] 容器逐项确认：C1 ✅（嵌入 WebView 统一路线）｜ C2 ✅（通道注册表/进程归属）｜ C3 ✅（账号留 C3/提醒三段/v8 累积表）｜ C4 ✅（工具框架 L1-09/恢复从简 L1-08）｜ C5 ✅（壳层契约 L1-10）｜ P ✅（条件导入+能力矩阵 L1-11）
- [ ] 开放问题移交：WebView2 具体包选型与自动化原语自研（**吸取 v2 教训：就绪判定/事件顺序
      状态机写一次、引擎独占，禁止来源适配器各自实现**）→ M2 第 4 层；HTTP 客户端选型 → M4
      第 4 层；移动端 WebView×学校网站兼容性 → D29 阶段专项验证；作业级错误 transient/fatal
      分类与有限重试（Gopeed/Airbyte 模式）→ 第 4 层；syncAll 遇 needs_user_login 的恢复语义
      形态（回调 vs 事件流驱动）→ 第 4 层（依赖 D05 事件流最终签名）；**工具集审计与重规划 →
      M6 前置任务**（覆盖矩阵 + 冗余合并 + 声明成本）；接口签名 → 第 2 层
- [x] **第 1 层 gate 关闭**（2026-08-12）：三链路走通 + 职责无重叠无缺口 + ADR 溯源 +
      六容器逐项确认 + L1 拍板记录 L1-01~L1-11 → 进入第 2 层全局契约（`09-contracts.md`）

## 11. 本层拍板记录（L1 决策）

| 编号 | 决策 | 内容 |
|---|---|---|
| L1-01 | 浏览器驱动 | 嵌入 WebView 统一路线：Windows=WebView2；移动端=平台 WebView + JS 驱动（D29）；统一经 `BrowserSessionPort`，自动化语义层共享 Dart 写一次 |
| L1-02 | 文件导入移除 | 目标态仅保留"采集→导入"单一路径，删除 file-origin 导入（M1 无 file-origin 测试；M5 无文件导入入口） |
| L1-03 | 来源通道注册表 | `SourceChannel` 接口 + 注册表（Native 实现 / Python 租户实现），注册表保证一源一通道 |
| L1-04 | busy 分工 | 权威互斥在 C1 JobGate；C2 仅保留触发预检（轻量 in-flight 标志） |
| L1-05 | 并存期进程归属 | Python 通道进程生命周期归 C2 统一管理；C4 查询租户经 C2 取句柄；M7 随租户删除 |
| L1-06 | 账号服务归属 | 账号与凭据服务留 C3（随数据走）；`CredentialProtector` 端口留 C0（clean-arch 共识） |
| L1-07 | 提醒三段切分 | 协调逻辑 C3 / 通知投递适配 P / 启动编排 C5（Flutter 生态标准三段式） |
| L1-09 | 工具系统框架 | 能力域组织（本地读/外部读/本地写/生命周期/管理/元域六域）；域内工具清单 M6 审计定稿，不携带旧房"39"数字；每轮作用域收窄延续 grounding |
| L1-08 | 恢复语义从简 | 跨重启一律中断作废：running→interrupted；waiting_user 确认卡作废+审计"待确认已失效"；暂停查询（needs_user_login）不跨重启恢复；schema 零增量 |
| L1-10 | 壳层契约 | 分支栈=indexedStack 保活（禁止丢栈）；手工装配维持现状（D20/D21 M5 评估）；启动后台编排 best-effort |
| L1-11 | 平台适配方式 | 单 App 内部目录 + 平台接口 + 条件导入/平台通道实现；能力矩阵声明平台不对齐；不引入 federated plugin 结构（LocalSend 式） |
