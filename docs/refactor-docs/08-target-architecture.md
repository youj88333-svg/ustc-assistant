# 08 目标架构：容器切分（六层阶梯 · 第 1 层）

> 产出日期：2026-08-12 ｜ 状态：**第 1 层已确认（2026-08-14，第四轮复审收口后重认）** ｜ 依据：`07-constitution.md`（ADR-000~023）、
> `00-index.md` 端到端链路、01–06 模块文档

## 1. 本层目标与 gate

- 目标：定义系统边界、容器级块（C4 模型 Container 层）、依赖方向、容器级技术选型。
  **只到容器级，不进组件**（组件级状态机、接口签名细节属第 2/4 层）。
- 术语说明：C0–C5 为容器级块（宽松义；C4 严格术语下更接近 Components，命名保留以
  免大面积重命名）；§2/§3 标题中的"C4 模型"指层级，与容器编号 C4（Agent harness）无关。
- **gate：① 全部链路（三条主要 E2E：同步/Agent 查询/completeReset + 两条账号生命周期
  子链路：首次登录/账号维护）能用容器名走通；② 容器职责无重叠、无缺口；③ ADR-000~023
  每条都能溯源到容器或边界。**（检查表见 §10）

## 2. 系统上下文（C4 模型 System Context 层：外界与系统边界）

```
外部系统
  ├─ 学校网站：jw.ustc.edu.cn / young.ustc.edu.cn / id.ustc.edu.cn（CAS）
  │           登录态 + 页面交互型，不可信数据（红线 2.1 原则 4）
  ├─ 公开网站：icourse.club / teach.ustc.edu.cn / finance.ustc.edu.cn
  │           公开 HTTP 型，同样视为不可信数据
  ├─ USTC LLM 网关：api.llm.ustc.edu.cn（Anthropic 兼容，SSE + tool_use/tool_result）
  └─ 平台：Windows（当前）/ Android / iOS（正式版后，红线 2.2-8）

系统边界
  ├─ 单 Flutter 应用边界（平台浏览器/Python 租户可有独立进程，不按纯单进程假设设计）
  ├─ 本地优先：SQLite + 平台安全存储（DPAPI/Keychain/Keystore）为唯一本地事实来源
  ├─ 目标态不存在：Python / Bridge / CLI（并存期租户见 §8，M7 移除）
  └─ 云服务：远期可选（双向门 D26），当前不在边界内
```

出站边界铁律（红线 2.1 原则 2 的容器级落点）——**三类外部出站，各归其位**：
① 应用自有外部 HTTP 出站：仅 C1（学校/公开网站抓取）与 C4（LLM 网关）持有；
② 嵌入浏览器导航：C1 经 P(WebView) 的页面导航，网络发生在平台 WebView 运行时；
③ 用户导航委派：P(URL launcher) 交系统浏览器打开白名单 URL。
并存期例外：C2 仅经 P 注入的 `PythonProcessPort`/`LoopbackBridgeTransportPort` 管理
Python 租户及带认证的本机回环 Bridge 通信；它不是学校/互联网出站，必须只允许回环地址，
且 M7 随 Python 租户删除。其余容器不持有外部网络能力；C2 核心及其他平台无关纯 Dart 层
不直接引用 `dart:io`（ADR-018）。

## 3. 容器总览（C4 模型 Container 层）

```
┌────────────────────── 单 Flutter 应用边界（平台浏览器/Python 租户可有独立进程） ─┐
│                                                                              │
│  C5 应用壳层 AppShell（组合根）                                              │
│    路由/页面/装配；启动后台编排；CompleteResetCoordinator（双确认→编排重置）    │
│        │ 装配并调用                                                        │
│        ├──────────────► C2 来源作业仲裁 SourceOrchestration                  │
│        │                 SourceJobGateway = 全部来源作业唯一入口             │
│        │                 ① 全局来源作业租约（同时至多一个来源作业活跃）        │
│        │                 ② 来源通道注册表（Native|Python，一源一通道）        │
│        │                 ③ 租约戳 {jobId,accountId,source,channelKind,       │
│        │                    sourceGeneration,resetEpoch} + 迟到结果拒绝       │
│        │                 ④ 凭据一次性租约（ADR-020）＋清会话独占权            │
│        │                 ⑤ Python 租户经 P 进程/回环端口注入（M7 删除）        │
│        │                        │ 启动作业（Native 卡槽租约，ADR-004）       │
│        │                        ▼                                           │
│        │                 C1 采集引擎 SourceEngine                            │
│        │                  WebSessionEngine（卡槽/探测/清理 ADR-002）          │
│        │                  JobGate（Native 会话卡槽/资源占用，不含全局权威）    │
│        │                  JobEventStream（事件流 ADR-005）                   │
│        │                  HttpSourceClient（公开 HTTP 抓取）                 │
│        │                  AttachmentContentConverter（附件下载/校验/转换）    │
│        │                  5×SourceAdapter（fetch→normalize→validate→deliver │
│        │                    ADR-001；jw 含学期列表抓取 ADR-009）             │
│        │                        │ deliver 产物（经 C2 交接，不直连 C3）      │
│        │                        ▼                                           │
│        └──────────────► C3 导入与存储 ImportAndStorage                       │
│                           ImportService（公共 normal-only/幂等/事务/提醒）   │
│                           commitFirstLogin（单事务）/ beginReset·finalizeReset│
│                           v7 基线 27 表 + v8 变更集（ADR-011）+ 迁移器         │
│                           聚合根级服务（六子域：Identity/Schedule/Task/       │
│                           Reminder/Catalog/Audit）                           │
│                                                                              │
│  C4 Agent harness                                                           │
│    AgentSessionService（推理循环）+ 工具系统（能力域注册，M6 审计后定稿）      │
│    AgentLocalDataGateway（应用层跨聚合门面 ADR-017）──► C3                   │
│    AgentWriteGateway（端口适配器，原子事务）──► C3                           │
│    外部查询：经 SourceJobGateway 提交（C4 → C2，不直连 C1，ADR-004/016 修订）│
│    LLM 网关客户端（仅出站到 USTC LLM）                                       │
│    feature 内聚合 + subpackage_lint 边界（ADR-018）                          │
│                                                                              │
│  C0 共享核心 SharedCore：BeijingClock/time 工具箱（ADR-015）、               │
│    CredentialProtector 端口、纯 Dart 工具 —— 全容器共用、零依赖              │
│                                                                              │
│  P 平台适配边界（实现注入，三端替换点，红线 2.2-8）                           │
│    WebView | 安全存储 | 通知 | launcher | 文件/decoder | 并存期进程/回环传输  │
└──────────────────────────────────────────────────────────────────────────────┘
```

容器职责一句话表：

| 容器 | 职责 | 继承旧房 | 关键 ADR |
|---|---|---|---|
| C0 SharedCore | 时间/安全端口/工具，纯 Dart | `core/` | ADR-015 |
| C1 SourceEngine | 采集/查询执行：会话卡槽、事件流、五适配器、附件转换（不持全局作业权威） | Python `common/`+`sources/`+`bridge/jobs` 语义 | ADR-001~005、009 |
| C2 SourceOrchestration | **全部来源作业唯一仲裁**：SourceJobGateway、租约戳、通道注册表、凭据租约、并存期 Python 进程 | `features/sync`（Bridge 相关部分删除） | ADR-004、008、013、016 修订、020、023 |
| C3 ImportAndStorage | 导入流水线（公共 normal-only + 私有事务内核心）+ commitFirstLogin + reset 持久状态 + v7 基线 27 表 + 全部业务服务 | `features/import` + `core/database` + 各 feature 的 domain/application | ADR-006~012、017、023 |
| C4 AgentHarness | 推理循环 + 工具 + 审批门 + 查询/写网关（外部查询经 C2） | `features/agent`（Windows 适配替换） | ADR-016~018 |
| C5 AppShell | 路由/页面/装配/账号维护与 CompleteReset 跨容器协调/设置 | `app/` + 各 presentation + `features/settings` | ADR-013、023 |
| P PlatformAdapters | WebView/安全存储/通知/launcher/文件与 decoder 实现；并存期 Python 进程/回环传输 | 现状 Windows 实现 | 红线 2.2-8、ADR-004 修订 |

## 4. 依赖方向（铁律，第三/四轮整改修订）

```
允许的依赖（运行时调用方向；C4 不得直连 C1，全部来源作业经 C2）：
  C5 AppShell      → C2 / C3 / C4 / C0 / P（组合根装配）
  C2 SourceOrch.   → C1 / C3 / C0 / P 端口
  C4 AgentHarness  → C2 / C3 / C0
  C1 SourceEngine  → C0 / P 端口
  C3 ImportStorage → C0 / P 端口（通知、文件存储：源码仅依赖 C0 端口定义，运行时经组合根注入 P 实现；L2 审查 B-7 补充）
  C0 SharedCore    → （无）

源码依赖要点（区分"调用方向"与"编译依赖"）：
  端口接口（CredentialProtector / BrowserAutomationPort / BrowserSessionAdminPort /
  通知 / launcher / 文件存储 / 平台 decoder）定义在 C0/C1；并存期
  PythonProcessPort / LoopbackBridgeTransportPort 定义在 C2。P 提供实现 → 编译依赖为
  P → C0/C1/C2 端口 + 平台 SDK；P 不含业务逻辑。

禁止：
  C1/C2/C3/C4/C0 引用 Flutter Widget（UI 只在 C5）
  **C4 直连 C1**（外部查询必须经 C2 SourceJobGateway，ADR-004/016 修订）
  C3 不持有网络能力（学校数据只能来自 C1 的 deliver 产物，经 C2 交接）
  C1 不写库（落库唯一入口 = C3 ImportService；campus 目录经 C3 服务写，ADR-007）
  C1 不依赖 C3（deliver 产物与凭据均经 C2 交接，ADR-020）
  C1 不知道 Python 通道（不负责跨通道互斥）
  C4 不直接碰表（必须经 C3 服务或网关，ADR-017）
  平台无关核心（C0/C1 纯 Dart 部分/C2 核心/C3 服务/C4 核心）无 dart:io；并存期进程与
  回环 HTTP 只存在于 P 适配器（ADR-018 lint 守护，M7 删除）
```

## 5. 容器职责与边界

### 5.1 C1 采集引擎 SourceEngine

- **职责**：五条链路 fetch→normalize→validate→deliver 的执行宿主；Native 会话卡槽、
  作业事件流、学期解析、附件下载与转换。**不持系统级"全局来源作业权威"**（第三轮整改）。
- **包含**：
  - **会话端口拆分（第三轮整改，ADR-019 修订）**：
    `BrowserAutomationPort`（navigate/wait/click/fill/受控 DOM 提取与登记脚本执行）；
    `BrowserSessionAdminPort`（open/probe/close/quarantine/clearPartition → 不透明
    SessionPartitionRef；quarantine 标记持久到清理成功，跨重启禁止复用；**不公开
    cookies/storage/认证 header/任何敏感明文取值**）。
    自动化语义层（就绪判定、事件顺序、导航状态机）为共享 Dart，写一次、三端共用
    （v2 教训的架构化兑现）；evaluate 仅允许登记提取脚本、返回值经 schema 与敏感键
    检查，禁止读 document.cookie/各 Storage/IndexedDB/认证 header；
  - `WebSessionEngine`：卡槽生命周期（按账号独立数据分区，引擎独占，ADR-002）、
    收集前健康探测、持久 quarantine/脏状态恢复、真清理、CAS 交互登录（白名单填表/三层
    核验/验证码交人工，ADR-003）；
  - `JobGate`：**仅管理 Native 会话卡槽与资源占用**（同卡槽采集×查询互斥）；
    不含系统级全局权威、**不知道 Python 通道**（ADR-004 第三轮修订）；
  - `JobEventStream`：进程内事件流（八相位 + safeCount + 热流重放，ADR-005）；
  - `HttpSourceClient`：公开 HTTP 抓取（icourse 查询、campus 目录刷新与详情读取）；
    规范化数据经 C2 交接 C3，C1 不写库；
  - `AttachmentContentConverter`：campus 附件下载/大小与 MIME 校验/内容转换编排/输出
    规范化（白名单与限额策略在 C1；文件系统/平台 decoder/临时文件与缓存目录在 P；
    C3 只存正式目录元数据或显式缓存索引，不执行网络与转换）；
  - `5×SourceAdapter`：jw（含学期列表抓取 + 月份规则默认，ADR-009）、young-schedule、
    young-enrolment、icourse、campus；各适配器 normalize 段保留独立 DOM/接口/解析规则；
  - `QueryJob`：查询作业执行对象（由 C2 创建/持有，ADR-016 修订；submit→
    QueryHandle{events,cancel,resumeLogin} 经 C2 暴露）。
- **不包含**：落库（deliver 产物经 C2 交接；C1 不依赖 C3）；作业仲裁/来源互斥/通道
  选择（C2）；Agent 推理（C4）；跨通道互斥。
- **对外接口预告**（签名细节归 09-contracts）：`startCollection(job)`、
  `runQuery(job)`、`resumeLogin`/`cancel`、`probeSession(account)`、事件流订阅。

### 5.2 C2 来源作业仲裁 SourceOrchestration

- **职责**：**全部外部来源作业的唯一仲裁者**（第三轮整改）。触发判定、全局来源作业租约、
  通道注册与选择、租约戳、结果交接、凭据一次性租约、清会话独占权、并存期 Python 进程
  生命周期。
- **包含**：
  - `SourceJobGateway`（唯一入口端口）：手动同步、自动同步、首次登录采集、重新认证、
    Agent 外部查询（二课/评课）、campus 目录刷新、Native 通道、并存期 Python 通道——
    **一律经此**；C4 不直连 C1；
  - **全局来源作业租约**：单账号产品内同一时刻至多一个学校来源采集/查询作业活跃
    （Kubernetes Lease 式单一协调者 + holder，不引入依赖）；
  - **来源通道注册表**：`SourceChannel` 接口（Native 实现 / Python 租户实现）；一源一
    通道；通道切换需旧作业终态释放；
  - **租约戳**：{jobId, accountId, source, channelKind, sourceGeneration, resetEpoch}；
    sourceGeneration 在通道切换/取消/reset/clearBusinessData 维护时递增；resetEpoch 由 C3
    beginReset 递增；
    C3 导入/写入前校验租约戳，迟到结果返回稳定错误、不得写库；
  - `SyncCoordinator`（freshness/backoff 单常量，ADR-013）、`syncRuns/sourceConfigs`
    状态读写（经 C3 同步状态服务）、busy 预检（轻量 in-flight 标志）、
    `recoverInterruptedRuns` 启动恢复；
  - **凭据一次性租约**（ADR-020 修订）：启动作业前向 C3 申请（含 expectedUsername，
    密码仅在 needs_user_login 恢复时按需附带）；恢复路径闭合——C4/C5 请求恢复 → C2 验证
    作业处于 needs_user_login → 用户确认后 C2 向 C3 申请 → 注入同一 C1/Python 作业 →
    仅经原子 `takePassword()` 取即失效；同步与查询不得各自实现凭据旁路；
  - **账号维护独占权**（第三轮整改补漏）：
    - 删除凭据：撤销未消费凭据租约；对每个将取消的活跃来源先以 cancel 原因递增
      sourceGeneration，再取消并等待可能消费凭据的来源作业，最后交 C3 删除；
    - 清会话：对每个活跃来源先以 cancel 原因递增 sourceGeneration，再停止该账号来源
      作业；清除该账号在**已安装 Native/Python 通道全集**中的
      会话分区（Native 经 C1/P；Python 经 P 注入的租户适配器），全部幂等完成后释放；
    - clearBusinessData：保持维护门关闭，拒绝新来源作业，取消并等待旧作业，递增全部相关
      sourceGeneration，并与 C4/C3 写屏障共同防止迟到重建；
  - **Python 进程生命周期**：C2 核心只编排 P 注入的 `PythonProcessPort` 与
    `LoopbackBridgeTransportPort`；进程启动/关闭、句柄和本机认证回环传输实现在 P，M7
    随租户及两端口删除。
- **不包含**：作业执行（C1/Python 通道）；导入落库（C3）；凭据仓库（C3 账号服务 +
  C0 保护端口）。
- **对外接口预告**：`submitQuery(QueryRequest)`、`sync(source, trigger)`、`syncAll`、
  `firstLoginSync`、`reauthenticate`、`resumeInteractive`、`clearSession`（语义来源
  02§3.2 的 SyncCoordinator 契约 + 第三轮仲裁语义）；原始
  `_submitSourceJob(SourceJobSpec)` 仅为 C2 内部助手，不是跨容器接口（09 L2-17）。

### 5.3 C3 导入与存储 ImportAndStorage

- **职责**：本地事实来源。SourceBundle 的落库与查询、全部业务服务、迁移器、账号生命周期
  事务（commitFirstLogin / beginReset / finalizeReset）
  （QueryResult 除 campus 目录经目录服务 upsert 外不落库）。
- **包含**：
  - `ImportService`（解码→语义校验→幂等→单事务→提醒协调）：跨容器公共入口
    **normal-only**（activeAccountId==租约 accountId）；首登不暴露第二个公共 mode，
    `commitFirstLogin` 只复用 C3 私有事务内导入核心。两条入口均写前校验原 LeaseStamp，
    迟到结果稳定拒绝；
  - **`commitFirstLogin`**（ADR-023，单事务）：绑定/创建账号 + 导入 SourceBundle +
    凭据密文 + identityDigest + 置活动 + 审计，任一失败整体回滚；事务提交后才广播
    activeAccountChanged；
  - **`SourceStateService`**（09 CT-C3-21）：C2 读写 sourceGeneration 与 sync run
    生命周期的唯一 C3 端口；generation 递增原因全集 = 通道切换/取消/completeReset/
    clearBusinessData，C2 不直接写 `source_configs`/`sync_runs`；
  - **reset 持久状态**（ADR-023）：`beginReset`（持久 reset_pending + resetEpoch++ +
    写屏障，拒绝新业务写入）→ 等待 C2/C4 全部作业终态与会话清理 →
    `markResetSessionsCleared`（pending=2）→ 严格清除 cache/debug 私有资产 →
    `finalizeReset`（单事务删除账号/凭据/业务/Agent 历史/审计/撤回数据 + 清
    reset_pending + 广播空账号，幂等）；启动时检测 reset_pending，在正常路由、
    自动同步与 Agent 之前恢复重置；私有文件未清完不得 finalization；
  - **账号维护写屏障**（ADR-023）：`beginBusinessDataClear` 在 C2/C4 取消等待之前
    先拒绝新业务写，并等待已进入的本地写事务终态；随后配合 C2/C4 维护独占门，
    只允许清理事务写入，事务提交或回滚后才解除。该操作只涉及单库事务，不新增
    reset_pending；崩溃前未提交则回滚，已提交则数据已清除；
  - v7 基线 27 表 + schema v8 变更集（campus 目录表族、删 undo_slot.expires_at、action_logs
    索引、prompt 版本统一、agent_permission_policies.expires_at 删除 D34、
    local_accounts reset 持久列、source_configs.source_generation；
    migration-only + 迁移测试，ADR-011）+ `v7→v8 迁移器`
    （唯一搬家路径，ADR-012；**迁移前自动备份 v7 库副本、失败可回滚**——红线 2.2-7 承接）；
  - 聚合根级服务（六子域）：Identity（账号/凭据/identityDigest——**重新认证不可变，
    仅首次建立或显式 schema 迁移可写**）/ Schedule（有效事件/冲突/覆盖/重复）/
    Task（任务/计划块/撤销 ADR-010）/ Reminder / Catalog（campus 目录：freshness 判定
    与本地搜索在 C3，抓取在 C1、编排经 C2；节流/过期/降级语义 ADR-007）/
    Audit（历史/日志）；
  - 账号与凭据服务（单账号模型，ADR-004；随数据留 C3，保护能力经 C0 端口）；
  - 提醒协调（协调逻辑在 C3、通知投递适配器在 P、启动编排在 C5，三段切分）；
  - 学期三元组持久化（`sourceConfigs.configJson`，ADR-009）。
- **不包含**：任何采集/网络（C1 专属）；附件下载与内容转换（C1/P）；UI（C5）；
  Agent 推理（C4）。
- **v8 候选变更累积表**（历史记账；已由第 2 层 `09-contracts.md` §7.2 冻结七项，2026-08-14）：

| # | 变更 | 来源决策 | 类型 |
|---|---|---|---|
| 1 | campus 目录表族新增 | ADR-007 | 加表 |
| 2 | `undo_slot.expires_at` 删除 | ADR-010 | 删列 |
| 3 | `action_logs` 加 `(account_id, occurred_at)` 索引 | D10 / 03§9 建议2 | 索引 |
| 4 | Agent prompt 版本三处统一（表默认 2 / 常量 3 / 实际 v8） | D10 / 06§10-2 | 数据修复 |
| 5 | `agent_permission_policies.expires_at` 删除（第 2 层 L2-02 拍板：死列删除，"此类型以后不再确认"=永久） | D34 | 删列 |
| 6 | reset 持久状态（reset_pending/resetEpoch）落库形态 | ADR-023 | 加列/行 |
| 7 | `source_configs.source_generation` 持久化 | ADR-004/011 | 加列 |

- **对外接口预告**：服务级读接口（EffectiveEventRepository/ConflictService/…）、
  `ImportService.importBundle`（normal-only）、`commitFirstLogin`、
  `SourceStateService`、`beginReset`/`markResetSessionsCleared`/`finalizeReset`、
  写服务（乐观锁 + 事务 + 审计 + Undo 快照同事务）。

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
    单对象工具 + 现有 8×12 为基线；禁止无预览 delete-all；可预告"用户批准的复合操作 +
    每对象 mutation ledger"，具体数量上限第 2 层契约定、工具暴露形态 M6 定；
- **包含**：`AgentSessionService`（8×12 预算/暂停/恢复/确认卡为**基线形态**，不声称
  永久不动——D32 契约变化会经第 2 层回写）、六子结构（上下文/工具/编排/记忆/观测/约束）、
  `AgentLocalDataGateway`（应用层跨聚合门面，ADR-017）、`AgentWriteGateway`（端口适配器，
  原子事务）、**外部查询经 C2 SourceJobGateway 提交（不直连 C1，ADR-016 修订）**、
  LLM 网关客户端（SSE 流式 + tool_use/tool_result，唯一 LLM 出站）、
  `ProtectedAgentSecretStore`（DPAPI 经 C0 保护端口）。
- **不包含**：学校数据采集与来源作业仲裁（C1/C2）；业务服务本体（C3）；页面（C5）。
- **边界纪律**：domain/application 零平台依赖（ADR-018）；feature 内聚合不拆包；
  确认卡跨重启作废（ADR-022）；reset 或 clearBusinessData 维护期间 C4 拒绝新 run/工具/
  审批，取消并等待所有可能写库的执行终态（ADR-023）。

### 5.5 C5 应用壳层 AppShell

- **职责**：组合根。路由（GoRouter 双分支 + 顶层路由）、页面（周课表/任务/日程/历史/
  设置/聊天）、Loaders 装配、启动后台编排（提醒启动 + 自动同步 + **reset_pending 强制
  恢复门**）、`CompleteResetCoordinator` 与 `AccountMaintenanceCoordinator`（UI 只负责
  确认；协调器调用 C2/C3/C4/P，不持领域规则）、官方网页白名单。
- **壳层契约**：分支栈语义 = `StatefulShellRoute.indexedStack` 保活
  （`AutomaticKeepAliveClientMixin`），禁止改为丢栈行为（规避 go_router
  [issue #190914](https://github.com/flutter/flutter/issues/190914) 的姿势固化）；
  普通提醒启动/自动同步为 best-effort；**reset_pending 检测与恢复不是 best-effort**，必须
  先于正常路由、自动同步和 Agent。reset gate 清零后、开放正常路由前还必须经
  CT-P-05 调和 provisional debug 归属；任一恢复失败进入专用恢复/错误界面并保持
  对应维护状态。
- **不包含**：领域规则或数据处理（页面纯回调；C5 只做跨容器应用编排，领域服务在 C3/C4）。
- **双向门预览**：状态管理框架（D20）、DI（D21）、深色模式（D22）、路由持久化（D23）
  均在此容器 M5 时评估；本层不预拍。

### 5.6 P 平台适配边界

- Windows 实现：WebView2（`UserDataFolder` 卡槽）、DPAPI（`CryptProtectData`）、
  前台通知适配、URL launcher、本地文件存储（附件缓存/迁移备份目录）、附件 decoder；
  FileStoragePort 同时实现正式账号 debug 清理与 provisional debug 归属调和；
  `BrowserSessionAdminPort.quarantine` 的持久标记由平台会话适配器保存在受控分区旁，不进
  C3 业务库；并存期另含 Python 进程与带认证本机回环 Bridge 传输适配（M7 删除）。
- 移动端实现（D29，Windows 正式版后）：平台 WebView（Android WebView / iOS WKWebView）
  + JS 驱动，实现同一 `BrowserAutomationPort` 与 `BrowserSessionAdminPort`；**风险：学校网站/CAS 对嵌入 WebView 的
  兼容性（UA 识别、防嵌入、cookie 容器差异）未在旧房验证，D29 阶段专项验证**；
  安全存储（Android Keystore / iOS Keychain）与平台通知为移动端对应能力，经同接口注入。
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
| 浏览器驱动 | **嵌入 WebView 统一路线**：Windows=WebView2（数据分区卡槽）；移动端=平台 WebView + JS 驱动（Android WebView / iOS WKWebView）。统一经 `BrowserAutomationPort` + `BrowserSessionAdminPort`（会话资产不透明，ADR-019 修订）；自动化语义层共享 Dart；**具体包选型待 M2 第 4 层** | ADR-001/002/019；2026-08-12 用户拍板 |
| HTTP | 引擎内 HTTP 客户端；**具体包待 M2/M4 第 4 层** | ADR-001 |
| LLM 传输 | SSE 流式客户端（现状语义） | C4 保留 |
| 安全存储 | DPAPI（经 CredentialProtector 端口） | 红线 2.1 原则 1 |
| 时间 | `core/time` 工具箱：epoch ms + Asia/Shanghai | ADR-015 |
| 状态管理/DI | 维持"服务构造 + 手工装配" | D20/D21 双向门，M5 评估 |
| 包管理 | 单 pub 包（不拆包；subpackage_lint 守边界） | ADR-018 |

## 7. 链路容器级走查（三条主要 E2E + 两条账号生命周期子链路，gate 验证）

### 7.1 同步链路（手动/自动）

```
C5 触发（启动自动/同步页）
  → C2 判定：freshness 单常量 / busy 预检 / 单账号存在
  → C2 SourceJobGateway 取全局来源作业租约 + 租约戳（一源一通道，channelKind=Native|Python）
  → C1 SourceAdapter.fetch（含学期解析 + CAS 会话探测 ADR-002）
      ├─ 会话过期 → needs_user_login（事件流）→ C5 弹确认 → C2 凭据一次性租约
      │            → 恢复同一作业（ADR-003/020）
      └─ 成功 → normalize → validate → deliver SourceBundle 1.0（经 C2 交接）
  → C3 ImportService.importBundle（normal-only；租约戳事务内复验→解码→幂等→
    单事务落库→提醒协调）
  → C2 经 C3 SourceStateService 收尾（syncRuns/sourceConfigs）→ C5 页面 drift 流自动刷新
```
无重叠无缺口：仲裁归 C2、执行归 C1、落库归 C3、展示归 C5；凭据只在 C2 租约内流动，
C1 仅经原子 `takePassword()` 取即失效（ADR-020）。

### 7.2 Agent 查询链路（外部 + 本地）

```
外部（查二课/评课/校园）：
  C4 外部工具 → C2 SourceJobGateway.submitQuery(QueryRequest)（取全局租约 + 租约戳，
    C2 组装 SourceJobSpec 并选择 Native/Python 通道）
    → C1 Native QueryJob 或 Python 租户 → 事件流（进度/needs_user_login/终态，ADR-005/016）
    → C2 接收终态并校验 SourceJobHandle.stamp（迟到结果拒绝）
    → C4 获得经安全校验的 QueryResult（信封校验 → 工具结果净化 → 入对话）
  campus 目录刷新：C4 工具 → C3 目录服务判 freshness（30min 节流/6h 过期，ADR-007）
    ├─ 无需刷新 → C3 本地搜索 → 信封校验 → 入对话
    └─ 需刷新 → C4 → C2 → C1/Python 抓取规范化 → 结果经 C2 按 handle.stamp 校验并
        交还 C4 → C4 将原 stamp + canonical 结果 + C1 附件登记载荷交 C3
        `commitCatalogSource` → C3 事务内复验后 upsert → 本地搜索 → 入对话（刷新
        失败且目录缺失 → catalog_unavailable 明确报错）
本地（读课表/任务、写日程）：
  C4 工具 → AgentLocalDataGateway（应用层门面）→ C3 各聚合根服务
  写路径 → AgentWriteGateway → C3 写服务（业务+审计+确认日志同事务；resetEpoch 校验）
```
无重叠无缺口：C4 不直连 C1（全部来源作业经 C2，ADR-004/016 修订）；campus 目录存取
唯一 = C3（抓取在 C1、仲裁在 C2、判定与搜索在 C3）；C4 网络仅 LLM 网关。

### 7.3 completeReset 链路（durable finalization，ADR-023）

```
0. C5 展示清单预览 + 双确认（CompleteResetCoordinator；UI 不持有状态机）
1. C3 beginReset：持久 reset_pending + resetEpoch++ + 写屏障（除 finalization 外拒绝新写入）
2. C2：先 revoke 全部未消费凭据租约；终止可能消费凭据的作业，再 cancelAll 并等待
   全部终态；经 C3 SourceStateService 以 reset 原因递增该账号全部来源的
   sourceGeneration（内部取消不再以 cancel 重复递增）；拒绝新来源作业
3. C4：拒绝新 run/工具/审批；取消当前模型流/工具调用/等待确认；等待可能写库的执行终态
4. C2 按通道幂等清会话：Native WebView 分区（经 C1/P）；并存期 Python profile/session（经 P 租户适配器）
5. C3 markResetSessionsCleared：持久 reset_pending=2（会话已清）；随后严格清除
   campus/iCourse cache（CT-C3-20）与账号 debug 私有资产（CT-P-05）
6. C3 finalizeReset：仅当前述私有资产全部清除后，单事务删除账号/凭据/业务/Agent
   历史/审计/撤回数据；清 reset_pending；广播空账号状态（幂等）
7. C5 回 /sync 首登态；C2/C4 在空账号状态重新开放
所有作业完成事件/导入/Agent 写入携带 resetEpoch，过期即拒（防迟到重建数据）。
启动恢复：检测 reset_pending → 作为强制启动门先于正常路由、自动同步和 Agent 恢复重置；
恢复失败时保持写屏障并进入专用恢复/错误界面，不得按 best-effort 忽略。
```
失败语义表：

| 失败点 | 语义 |
|---|---|
| beginReset 失败 | 重置未开始，数据与会话保持原状 |
| C2/C4 取消失败 | 数据未删除，保持 reset_pending 与写屏障，允许重试 |
| 会话清理失败 | 数据未删除，保持 reset_pending；不得绕过后继续删库 |
| markResetSessionsCleared 失败 | 会话可能已清但状态仍为 pending=1；安全重放会话清理并重试标记，不得继续删库 |
| cache/debug 私有资产清理失败 | 数据未删除，保持 reset_pending=2 与写屏障；返回 reset_incomplete，重试清理成功前不得 finalizeReset |
| 私有资产清完后删库失败 | 事务回滚，但登录会话不可恢复；保持 reset_pending=2，下次启动重试私有资产幂等清理后继续 finalization |
| App 崩溃 | 下次启动检测 reset_pending；=1 重放清会话，=2 重放 cache/debug 清理；全部成功后才 finalization，失败保持屏障与专用恢复界面 |
| finalizeReset 重复执行 | 幂等 |

注意：reset_pending 不属于 ADR-022 的普通作业作废范围（它是用户已确认的删除意图，
跨重启保留）。单账号模型下重置销毁个人日程/Task/Agent 历史，发布前提供备份/导出或
清单预览（D38）。

### 7.4 首次登录链路（commitFirstLogin 单事务，ADR-023）

```
C5 首登表单 → C2 firstLoginSync
  → C2 JobArbiter 原子取得全局来源作业租约（同步 check-and-hold；busy 时尚未 stage，
    无 provisional handle 可销毁）
  → C3 stageFirstLogin 返回 ProvisionalAuthContext（不透明句柄 + 仅内存预分配
    prospectiveAccountId + expectedUsername + 初始 generation/resetEpoch；认证上下文不得
    落数据库/文件/日志，不创建 local_accounts/source_configs 行；debug 构建显式启用的
    原始调试资产仅可按 prospectiveAccountId 受控落盘且不含上下文字段）
  → C2 以 ProvisionalSubject 申请一次性凭据租约，并用 prospectiveAccountId 组装
    LeaseStamp → SourceJobGateway 启动作业（CAS 交互登录 D03）
      ├─ needs_user_login → C5 确认 → C2 以同一 ProvisionalSubject 重申请含密码租约
      └─ 成功 → CollectionCompleted{bundleBytes, verifiedUsername, selectedSemester}
        （selectedSemester 为 C1 登录后按月份规则实际选中的完整三元组）
  → C2 把 handle + 终态 bundleBytes/verifiedUsername/selectedSemester + 原 LeaseStamp
    交 C3 commitFirstLogin（事务内复验 handle/stamp/verifiedUsername；**单事务**：创建
    预分配 accountId + 写 source_configs 完整学期三元组 + 导入 Bundle + 凭据密文 +
    以 verifiedUsername 内部计算 identityDigest + 置活动 + 审计；任一失败整体回滚）
  → 提交后广播 activeAccountChanged → C5 调 CT-P-05 reconcile：匹配目录提升为正式
    账号资产、其余 provisional 目录物理删除；成功后进入主界面
失败路径：stage 成功后的作业失败/用户取消/校验失败/事务回滚 →
cancelFirstLogin(handle) + clearDebugAssets(prospectiveAccountId)；无活动账号、无凭据行、
无来源业务数据；provisional 凭据仅经一次性租约供当前作业消费，失败时丢弃并尽力零化。
App 崩溃或文件清理失败由 CT-C5-02 在正常路由前 reconcile；取租约前 busy 直接返回，无 handle。
```

### 7.5 账号维护链路（重新认证/删凭据/清会话/清业务数据）

```
重新认证：C5 → C2 reauthenticate(ReauthRequest) → C2 JobArbiter 原子取得全局来源作业
  租约（busy 时未 stage、无 handle）→ C3 stageReauthentication 返回
  ProvisionalAuthContext（prospectiveAccountId=既有 accountId；启动作业前校验输入
  username 的 digest == 现有 identityDigest）→ C2 以 ProvisionalSubject 申请租约并
  启动统一来源作业 → 成功返回 verifiedUsername + 原 LeaseStamp → C3 在事务内复验
  stamp 后再次校验 digest == 原 identityDigest：
  ├─ 匹配 → **仅更新凭据密文与元数据，identityDigest 保持不变**
  └─ 不匹配 → account_mismatch/identity_mismatch；先
       discardProvisionalAuth(handle)，数据库 identityDigest/凭据/业务数据不变；C2 再持久
       quarantine 并清除本次作业使用的会话分区，清除失败则标记跨重启保留、禁止复用并
       向 UI 报告
删除凭据：C5 确认 → AccountMaintenanceCoordinator → C2 撤销未消费凭据租约；对受影响
  来源先 bump(cancel)，再取消并等待可能消费凭据的作业 → C3 deleteCredentials
  （删密文；保留账号与浏览器会话）→ 释放维护门
清会话：C5 确认 → AccountMaintenanceCoordinator → C2 取得账号会话独占权；对活跃来源
  先 bump(cancel)，再停止并等待该账号来源作业 → 清除该账号在**已安装 Native/Python
  通道全集**中的会话分区（Native 经 C1/P；Python 经 P 租户适配器）→ 全部幂等完成 →
  释放独占权
清业务数据：C5 确认 → AccountMaintenanceCoordinator 先调 C3 `beginBusinessDataClear`
  拒新业务写并等待已进入的本地写事务终态 → 持有 C2/C4 维护独占门 → C2
  拒新来源作业、取消并等待旧作业、递增该账号全部来源的 sourceGeneration → C4
  拒新 run/工具/审批并等待所有可写执行终态 → C3 单事务清业务数据（保留账号/凭据/
  设置）→ 提交或回滚后解除屏障与维护门；任何取消/等待失败均不得开始清理事务
```

## 8. 并存期视图（M2–M6，临时租户）

| 来源 | 原生通道 | Python 通道（租户，M7 删） | 切换点 |
|---|---|---|---|
| jw | C1 NativeJwAdapter（M2） | PythonJwGateway（Bridge） | C2 通道注册表 |
| young-schedule | C1（M3） | 同上 | C2 |
| young-enrolment / icourse / campus（查询） | C1 QueryJob（M3/M4） | PythonQueryGateway | C2 SourceJobGateway |
| 租户清单 | — | BridgeClient/PythonLocator/全部 PythonXxxGateway | M7 一次移除 |

并存期铁律（ADR-000 四铁律 + ADR-004 修订）：**C2 为全部来源作业唯一仲裁**——同一来源
同一时刻单通道（Native 与 Python 共同经过 SourceJobGateway）；租户只读不写库（写库唯一
入口仍为 C3 ImportService）；Python 进程生命周期由 C2 核心编排、由 P 的
`PythonProcessPort`/`LoopbackBridgeTransportPort` 执行；sourceGeneration 在通道切换时递增，
旧通道迟到结果被 C2/C3 拒绝；Python 通道的浏览器 profile/session 同样满足会话资产契约
（ADR-019），并在用户清会话/重置时与 Native 分区一起全部清理。

## 9. 移交登记消化映射（§2.5 全部移交项（20 项）→ 本层结论或后续层归属）

| 移交项 | 本层结论 |
|---|---|
| SourceBundle 1.0 信封/digest/错误码 | C1 deliver 产物（经 C2 交接）+ C3 校验器；细节 → `09-contracts.md` |
| v7 基线 27 表 + v8 迁移线（v8 后表数=基线+净增减） | C3；v8 变更集清单 → `09-contracts.md`（D10 冻结） |
| 账号隔离机制 | 单账号模型（ADR-004）；表结构照旧 → `09-contracts.md` |
| 北京时间 | C0 time 工具箱（ADR-015）；横切 → `12-cross-cutting.md` |
| 认证回环/Query Protocol 语义 | C1 事件流 + QueryJob（经 C2 仲裁，ADR-003/005/016），已消化 |
| 学校来源 upsert / 冲突判定序 / 重复系列 / Task 四态 | C3 服务语义照搬；细节 → `09-contracts.md` |
| 提醒默认偏移（定时 15min / 全天不提醒） | 双向门 D33：**第 2 层 09-contracts 冻结默认值**，M5 只做 UI |
| SourceBundle 范围/信封细节 | → `09-contracts.md` |
| Agent 写提交"业务+审计+确认日志"同事务；Agent 写入不占撤回槽 | C4 网关 + C3 事务（已消化）；细节 → `09-contracts.md` |
| 个人事件支持单次/全天/跨日/基础重复系列（孤儿规则） | → `09-contracts.md` §个人事件模型 |
| PlanBlock 不记录完成百分比/实际执行分钟/自动剩余工时（孤儿规则） | → `09-contracts.md` §任务与计划块模型 |
| 校园目录"每批详情≤3、链接≤1层"；附件受控下载与内容转换归 C1、平台实现归 P（孤儿细则） | C1 AttachmentContentConverter + P；细节 → `09-contracts.md` §Agent 工具安全细则 + `12-cross-cutting.md` §附件管道 |
| 本地事实来源介质 SQLite（具体介质） | → `09-contracts.md` §数据库 |
| Dart String 不可变致"绝对零化"不可承诺 | → `12-cross-cutting.md` §安全实现约束 |
| `--save-raw` 落盘形式与 tmp/private 具体目录 | → `12-cross-cutting.md` §调试资产 |
| 本地调试服务仅绑 127.0.0.1 的具体地址值 | → `12-cross-cutting.md` §调试服务边界 |
| （补充）`agent_permission_policies.expires_at` 语义 | D34：第 2 层已拍板（L2-02 修订：删列 + 记住即永久，见 C3 v8 累积表 #5） |

## 10. 本层 gate 检查表

- [x] 链路容器名走通（§7.1–7.5：三条主要 E2E + 两条账号生命周期子链路）
- [x] 容器职责无重叠无缺口（§5 六容器 + P 平台边界；三类外部出站与并存期本机回环各归其位（§2）、写库唯一入口 C3、全部来源作业唯一仲裁 C2）
- [x] ADR-000~023 全部溯源到容器（§3 表"关键 ADR"列 + §9）
- [x] 容器逐项确认：C1 ✅（端口拆分/不持全局权威）｜ C2 ✅（唯一仲裁/租约戳/维护独占）｜ C3 ✅（commitFirstLogin/reset 持久状态/维护写屏障/六子域）｜ C4 ✅（外部查询经 C2/维护时停写）｜ C5 ✅（CompleteResetCoordinator + AccountMaintenanceCoordinator）｜ P ✅（条件导入+能力矩阵+并存期进程/回环适配）
- [x] 开放问题移交（判据=每条有明确承接层，非已解决）：WebView2 具体包选型与自动化原语自研（就绪判定/事件顺序状态机写一次、引擎独占）→ M2 第 4 层；HTTP 客户端选型 → M4 第 4 层；移动端 WebView×学校网站兼容性 → D29 阶段专项验证；作业级错误 transient/fatal 分类与有限重试 → 第 4 层；syncAll 遇 needs_user_login 的恢复语义形态 → 第 4 层；工具集审计与重规划 → M6 前置任务；M2 前 feasibility spike：Windows WebView2 的 profile 隔离/导航顺序/可见登录/JS 原语/真清理；接口签名 → 第 2 层
- [x] **纸面走查（11 场景，第三轮整改 + 第四轮复审收口验收）**：
  1. 同步进行时 Agent 查二课 → Agent 查询到达 C2、因全局来源作业租约占用明确 busy，不直连 C1、不启 Python 第二通道 ✅；
  2. 查询作业 needs_user_login → 原作业与租约保持，C2 用户确认后向 C3 取一次性凭据、恢复同一作业，C4 不读凭据、C1 不依赖 C3 ✅；
  3. Native/Python 切换旧作业迟到完成 → sourceGeneration 已变，C2/C3 拒绝，不导入/不更新目录/不进对话 ✅；
  4. 首次登录 stage 后导入失败 → commitFirstLogin 事务回滚 + cancelFirstLogin(handle)，无活动账号/凭据行/来源业务数据，provisional 明文清理 ✅；
  5. 重新认证登录成另一账号 → digest 不匹配 → account_mismatch；先 discardProvisionalAuth(handle)，数据库 identityDigest/凭据/业务数据不变，受影响会话分区先持久 quarantine 再清除，清除失败跨重启禁止复用 ✅；
  6. reset 期间 Agent 写工具迟到提交 → resetEpoch/写屏障拒绝，不在删除后重建数据 ✅；
  7. reset 清会话后数据库失败 → 事务回滚、状态 reset_incomplete_session_cleared；下次启动以强制门继续 finalization，失败保持屏障/恢复界面，不谎称恢复登录 ✅；
  8. 并存期 Python 查询运行时重置 → C2 定位/取消/等待 Python 作业，Python profile/session 与 Native 分区一并清理 ✅；
  9. 同步或本地写运行时 clearBusinessData → C3 先建立屏障并等待已进入的本地写，C2/C4 维护门拒新工作并取消等待旧工作，generation 递增；清理后不会被并发或迟到写重建 ✅；
  10. 删除凭据时存在待消费租约 → C2 先撤销租约并终止相关作业，再由 C3 删密文，不留下可继续消费的凭据租约 ✅；
  11. 并存期用户清会话 → C2 清除账号在全部 Native/Python 注册通道中的分区，不因以后切换通道复活旧登录态 ✅。
- [x] **第 1 层 gate 关闭（第四轮复审收口后重认，2026-08-14）**：统一仲裁（C2 唯一 JobArbiter）+ 账号原子提交（commitFirstLogin/identityDigest 不可变/durable reset，ADR-023）+ reset 强制启动门 + 账号维护独占与全通道会话清理 + Python 并存适配归 P + 会话资产不透明（二端口拆分，ADR-019 修订）+ 附件转换归 C1/P → 进入第 2 层全局契约（`09-contracts.md`）

## 11. 本层拍板记录（L1 决策）

| 编号 | 决策 | 内容 |
|---|---|---|
| L1-01 | 浏览器驱动 | 嵌入 WebView 统一路线：Windows=WebView2；移动端=平台 WebView + JS 驱动（D29）；统一经 `BrowserAutomationPort`+`BrowserSessionAdminPort`，自动化语义层共享 Dart 写一次 |
| L1-02 | 文件导入移除 | 目标态仅保留"采集→导入"单一路径，删除 file-origin 导入（M1 无 file-origin 测试；M5 无文件导入入口）（已补 ADR-021） |
| L1-03 | 来源通道注册表 | `SourceChannel` 接口 + 注册表（Native 实现 / Python 租户实现），注册表保证一源一通道 |
| L1-04 | busy 分工与互斥分层 | 权威互斥（全局来源作业租约 + 来源闸门）在 C2 SourceJobGateway（Native/Python 共同经过）；C1 JobGate 管 Native 卡槽租约；C2 另保留触发预检 |
| L1-05 | 并存期进程归属 | Python 通道进程生命周期归 C2 统一管理；M7 随租户删除 |
| L1-06 | 账号服务归属 | 账号与凭据服务留 C3（随数据走）；`CredentialProtector` 端口留 C0（clean-arch 共识） |
| L1-07 | 提醒三段切分 | 协调逻辑 C3 / 通知投递适配 P / 启动编排 C5（Flutter 生态标准三段式） |
| L1-09 | 工具系统框架 | 能力域组织六域；域内工具清单 M6 审计定稿；8×12 为基线（D32 经第 2 层回写）；每轮作用域收窄延续 grounding |
| L1-08 | 恢复语义从简 | 跨重启一律中断作废（普通作业）；reset_pending 除外（ADR-022 修订 + ADR-023） |
| L1-10 | 壳层契约 | 分支栈=indexedStack 保活（禁止丢栈）；手工装配维持现状（D20/D21 M5 评估）；普通提醒/自动同步启动 best-effort，reset_pending 恢复为强制启动门 |
| L1-11 | 平台适配方式 | 单 App 内部目录 + 平台接口 + 条件导入/平台通道实现；能力矩阵声明平台不对齐；并存期 Python 进程/本机回环由 P 实现 C2 端口、M7 删除；不引入 federated plugin 结构（LocalSend 式） |
| L1-12 | 审查整改（批次 1） | 机械修订：出站三分法、completeReset 顺序、八相位、v7 基线 27 表、源码依赖方向（P→C0/C1）、campus 链路、孤儿规则归位、五链路补齐、ADR 负面诚实化 |
| L1-13 | 审查整改（批次 2） | 决策修订：凭据三类资产（ADR-019）、一月学期年份（ADR-009 修订）、互斥上移 C2（ADR-004 修订）、凭据一次性租约（ADR-020）、元规则放宽（C-8）、L1-02/08 补 ADR（ADR-021/022） |
| L1-14 | 第三轮定向整改 | C2 唯一 JobArbiter（C4 不直连 C1、租约戳、迟到拒绝）；commitFirstLogin 单事务 + identityDigest 不可变 + durable reset（ADR-023）；会话资产不透明（二端口拆分）；附件转换归 C1/P；元规则迁出 4 项；D32/D33/D34 契约面归第 2 层 |
| L1-15 | 第四轮复审收口 | reset_pending 恢复改强制启动门；身份不匹配会话隔离清除；删除凭据/清会话/clearBusinessData 统一维护独占；用户清会话覆盖全部 Native/Python 分区；并存期 Python 进程/回环传输归 P 端口；旧房首登上下文与残留术语修正 |
