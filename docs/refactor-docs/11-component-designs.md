# 11 组件设计（六层阶梯 · 第 4 层）

> 产出日期：2026-08-14 ｜ 状态：**整改复审修订版（回写 09 L2-18/19，待独立复审重认 gate）**
> ｜ 依据：`09-contracts.md`（CT 65 条 + L2-01~19）、`10-runtime.md`（五链路走查）、
> `07-constitution.md`（ADR-000~023）、08 容器切分、01–06 模块文档
> ｜ 纪律（AGENTS.md 阶梯规则）：第 4 层**不必一次做完**——M1 后"每做一块组件、
> 先补一块设计"；本文件是组件设计的唯一登记处。

## 1. 本层目标与 gate

- 目标：逐容器内部组件设计。本层交付物 = **状态机转移表**（状态全集 + 转移 +
  失败态）——这是 AGENTS.md 对第 4 层的硬 gate。
- 本次覆盖：**M1（存储核心）与 M2（采集引擎 + JW）** 的核心状态机（D-01~D-11）；
  其余里程碑组件登记待补（进入该里程碑前补设计，§6 触发器）。
- **gate：已设计组件每个状态机满足 §2 模板（状态全集标注初始/终态 + 显式转移 +
  三条闭合规则 + 失败态双列）；登记表每个待补组件有里程碑触发器；§7 横切规则
  可机械核对。**

## 2. 状态机模板与符号（A-1 整改：完整转移 = 显式行 + 三条闭合规则）

每个状态机按以下模板冻结：

```
状态全集（S）：全部状态；标注初始态*与终态†
事件（E）：触发转移的内部/外部事件（与转移表双向闭合）
转移表：显式行（当前态 × 事件 →（次态，动作，失败态））
失败态列格式（A-10 整改）：（内部恢复次态 ｜ 对外稳定错误码）双写；无对外码则明写"仅审计"
闭合规则（每机统一声明，显式行未覆盖的组合按此处理）：
  R-非法：非终态 × 未列事件 → 保持当前态 + 审计（不得转移）
  R-终态：终态 × 任何事件 → 幂等忽略（不转移、不重放动作）
  R-重复：重复/乱序事件按动作幂等性执行（动作栏注明"幂等"）
创建事件：转移表可用"—（创建）"行表达从不存在到初始态的入口（如启动检测、
  首行写入），不参与状态×事件补集计算
不变量：状态机存活期间必须保持的约束（违者 = 组件 bug）
```

- 三条闭合规则与显式行合并后即构成"状态全集 × 事件"的完整转移定义（gate 判据）。
- 规则优先级【冻结】：**显式行 > R-终态 > R-重复 > R-非法**。终态不重放动作；若终态
  请求需要返回值，只返回既有终态结果。没有终态的状态机仍须声明 R-终态不适用。
- 失败态一律映射 §2.4 稳定错误码（`09-contracts.md`）；新码须回写第 2 层。
- 与第 2/3 层的关系：契约（CT）定"什么能发生"，本层定"组件内部如何发生"；
  转移表不得违背 CT 冻结语义。

## 3. 组件登记表（B-1 整改：补齐遗漏组件）

状态三档：✅ 组件设计完成 ｜ 🟡 契约已冻结、设计待补 ｜ ⬜ 待补。

| # | 组件 | 容器 | 里程碑 | 设计状态 |
|---|---|---|---|---|
| D-01 | v7→v8 迁移器 | C3 | M1 | ✅ §4.1 |
| D-02 | ImportService 导入流水线 | C3 | M1 | ✅ §4.2 |
| D-03 | reset 协调状态机（三值编码） | C5/C3 | M1 持久化 / M5 UI | ✅ §4.3 |
| D-04 | 撤销槽 | C3 | M1 | ✅ §4.4 |
| D-05 | sync run 账本状态机 | C2/C3 | M1 | ✅ §4.5 |
| D-06 | JobArbiter 全局租约 | C2 | M2 | ✅ §5.1 |
| D-07 | 作业八相位状态机 | C1/C2 | M2 | ✅ §5.2 |
| D-08 | WebSessionEngine 卡槽状态机 | C1 | M2 | ✅ §5.3 |
| D-09 | 导航就绪状态机（三标志） | C1 | M2 | ✅ §5.4 |
| D-10 | CAS 交互登录状态机 | C1 | M2 | ✅ §5.5 |
| D-11 | CredentialLease 生命周期 | C2/C3 | M2 | ✅ §5.6 |
| D-20 | 有效事件/冲突投影纯函数 | C3 | M1 | 🟡 契约已冻结（CT-C3-13/09a）；触发器：M1 对应实现开工前补算法设计 |
| D-21 | 重复系列投影/生命周期 | C3 | M1 | 🟡 契约已冻结（CT-C3-12）；触发器：M1 对应实现开工前补算法设计 |
| D-22 | C1 JobGate（Native 卡槽资源闸） | C1 | M2 | ⬜ 待补（触发器：M2 开工前；不含全局权威，L1-04） |
| D-23 | Native JW Adapter 管道 | C1 | M2 | ⬜ 待补（触发器：M2 开工前；含学期列表抓取 ADR-009） |
| D-24 | SourceChannel 注册/切换 | C2 | M2 | ⬜ 待补（触发器：M2 开工前；已安装全集/来源路由，unregister 前清会话） |
| D-25 | SyncCoordinator（freshness/backoff/syncAll） | C2 | M1/M2 | ⬜ 待补（触发器：M2 开工前；含 10 §10 两项移交） |
| D-26 | provisional 生命周期（首登/重认证） | C3 | M1/M2/M5 | ⬜ 待补（触发器：M2 首登/JW 联调前；cancelFirstLogin/discardProvisionalAuth 状态机） |
| D-27 | clearBusinessData 写屏障 | C3 | M5 | ⬜ 待补（触发器：M5 开工前） |
| D-28 | C5 启动强制门/启动编排 | C5 | M5 | ⬜ 待补（触发器：M5 开工前；reset_pending 门 + 提醒/自动同步启动） |
| D-29 | 作业 transient/fatal 分类与有限重试 | C1/C2 | M2 | ⬜ 待补（触发器：M2 开工前；10 §10 移交项） |
| D-30 | syncAll 遇 needs_user_login 恢复语义 | C2 | M2 | ⬜ 待补（触发器：M2 开工前；10 §10 移交项） |
| D-12/D-13 | young 双适配器 | C1 | M3 | ⬜ 待补（触发器：M3 开工前） |
| D-14 | icourse 适配器 + 24h 缓存 | C1 | M4 | ⬜ 待补（触发器：M4 开工前） |
| D-15 | campus 刷新/详情/附件管道 | C1/C3 | M4 | ⬜ 待补（触发器：M4 开工前） |
| D-16 | 提醒协调器 | C3/P | M5 | ⬜ 待补（触发器：M5 开工前） |
| D-17 | 维护协调器 UI 编排 | C5 | M5 | ⬜ 待补（触发器：M5 开工前） |
| D-18 | Agent 推理循环/审批门/预算 | C4 | M6 | ⬜ 待补（触发器：M6 开工前） |
| D-19 | Python 租户生命周期（并存期） | C2/P | M2 | ⬜ 待补（触发器：并存期联调前） |

## 4. M1 组件状态机（存储核心）

### 4.1 D-01 v7→v8 迁移器（ADR-011/012；唯一搬家路径）

- 状态全集：`idle*, backing_up, migrating, verifying, committed†, rolled_back†, failed†`
- 事件：`start, backup_ok, backup_fail, migrate_ok, migrate_fail, verify_ok, verify_fail`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| idle | start | backing_up | 备份 v7 库副本到 P 私有目录（迁移前自动备份，红线 2.2-7） | （保持 idle ｜ `sync_failed`） |
| backing_up | backup_ok | migrating | 打开备份完整性校验（大小+可打开） | — |
| backing_up | backup_fail | failed | 不触碰主库；审计 `migration_backup_failed` | （failed ｜ `sync_failed`） |
| migrating | migrate_ok | verifying | Drift 迁移器执行（v8 七项变更，单事务语义） | — |
| migrating | migrate_fail | rolled_back | 主库保持 v7（事务回滚）；审计 | （rolled_back ｜ `sync_failed`） |
| verifying | verify_ok | committed | schemaVersion=8；**实现/验收时必须通过四步迁移断言**（旧库建→插数据→迁移→校验） | — |
| verifying | verify_fail | rolled_back | 同上回滚 | （rolled_back ｜ `sync_failed`） |

- 闭合规则：R-非法（保持+审计）/ R-终态（committed/rolled_back/failed 忽略后续事件，
  `committed × start` 只返回既有结果、不重放迁移动作）/R-重复（非终态重复完成信号按动作幂等）。
- 不变量：迁移全程主库独占（启动门：迁移未完成前禁止正常路由/自动同步/Agent）；
  任何失败不得留下半迁移状态。**备份副本保留与清理策略移交第 5 层数据保留策略
  （`12-cross-cutting.md`），本机不预设"自动过期"（B-3 整改）。**

### 4.2 D-02 ImportService 导入流水线（CT-C3-02；A-2 整改）

- 状态全集：`accepting*, decoding, validating, checking_subject, checking_idempotency,
  importing, reconciling, done†(imported|replayed), failed†`
- 事件：`bytes_received, decode_ok, decode_fail, semantics_ok, semantics_fail,
  subject_ok, subject_fail, replay_hit, proceed, tx_ok, tx_fail, reconcile_ok,
  reconcile_fail`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| accepting | bytes_received | decoding | 16MB/深度 64/schema 门禁（CT-C1-03 解码段） | — |
| decoding | decode_ok | validating | 语义校验（9 错误码） | — |
| decoding | decode_fail | failed | 稳定错误码回传（不回显源内容） | （failed ｜ 9 个 bundle 码之一） |
| validating | semantics_ok | checking_subject | 进入 subject/active-account 守卫（本行不提前判成功） | — |
| validating | semantics_fail | failed | 同上 | （failed ｜ 9 个 bundle 码之一） |
| checking_subject | subject_fail | failed | 拒绝：无活动账号，或 subject.accountId 与 stamp/activeAccountId 不一致；不打开导入写事务 | （failed ｜ `no_account` / `subject_mismatch`） |
| checking_subject | subject_ok | checking_idempotency | **同一事务内重新校验** subject.accountId == stamp.accountId == 当前 activeAccountId，复验 sourceGeneration/resetEpoch，再做 bundleId/digest 幂等查询（A-2 收口：active account 与 replay 路径均不得绕过事务守卫） | （failed ｜ `no_account` / `subject_mismatch` / `stale_lease`） |
| checking_idempotency | replay_hit | done(replayed) | 复验已过（同一事务内完成）；直接返回 | — |
| checking_idempotency | proceed | importing | **同一事务续写**：import_batches + localId 复用 + upsert + source_records presence 对齐 + ActionLog（复验与写入同事务，TOCTOU 闭合） | （failed ｜ `stale_lease`） |
| importing | tx_ok | reconciling | 事务外提醒协调（失败降级 pending） | — |
| importing | tx_fail | failed | 整体回滚 | （failed ｜ `sync_failed`） |
| reconciling | reconcile_ok | done(imported) | ImportResult{status, importBatchId, pending=false} | — |
| reconciling | reconcile_fail | done(imported) | ImportResult{pending=true}（审计 retryable_failure） | 降级非失败（仅审计） |

- 闭合规则：R-非法/R-终态/R-重复（幂等：同 bundleId 同 digest 重放恒 replay）。
- 不变量：subject/activeAccountId/stamp 复验、幂等查询与业务写入在**同一数据库事务、同一
  importBundle 调用栈**内连续执行；checking_idempotency 的 replay/proceed 是事务内同步
  决议，不跨 await 暴露事务；提醒协调失败不重试导入；
  迟到结果在任何入口（含 replay）都 `stale_lease`。

### 4.3 D-03 reset 协调状态机（CT-C3-05；A-3/A-10 整改）

- 持久态（DB，跨重启）：`reset_pending ∈ {0=none, 1=pending, 2=incomplete_session_cleared}`
- 协调器运行态：`idle*, previewing, beginning, draining_c2, draining_c4,
  clearing_sessions, finalizing, done†, startup_recovering`
- 事件：`user_confirm_x2, begin, begin_ok, begin_fail, c2_drained, c2_drain_fail,
  c4_drained, c4_drain_fail, sessions_cleared, clear_fail, retry_finalize, tx_ok, tx_fail,
  startup_detected, startup_pending, startup_incomplete_session_cleared`

| 当前态 | 事件 | 次态 | 动作（持久效果） | 失败态 |
|---|---|---|---|---|
| idle | user_confirm_x2 | previewing | 清单预览（CT-C5-01） | — |
| previewing | begin | beginning | beginReset：pending=1、resetEpoch++、写屏障 | — |
| beginning | begin_fail | idle | beginReset 未提交，重置未开始、pending=0；UI 可重试 | （idle ｜ `write_commit_failed`） |
| beginning | begin_ok | draining_c2 | C2：revoke 租约→终止→cancelAll→等待→bump(reset) | — |
| draining_c2 | c2_drain_fail | draining_c2 | 保持 pending=1 + 写屏障，可重试 | （保持 ｜ `reset_incomplete`） |
| draining_c2 | c2_drained | draining_c4 | C4：拒新+取消+等待写终态 | — |
| draining_c4 | c4_drain_fail | draining_c4 | 保持 pending=1，可重试 | （保持 ｜ `reset_incomplete`） |
| draining_c4 | c4_drained | clearing_sessions | 全通道 clearSession（幂等） | — |
| clearing_sessions | clear_fail | clearing_sessions | 保持 pending=1，不得绕过后删库 | （保持 ｜ `reset_incomplete`） |
| clearing_sessions | sessions_cleared | finalizing | finalizeReset 单事务删+清标记 | — |
| finalizing | tx_fail | finalizing | pending=2 持久（incomplete_session_cleared）；等待显式重试 | （保持 ｜ `reset_incomplete`） |
| finalizing | retry_finalize | finalizing | 幂等再次调用 finalizeReset | — |
| finalizing | tx_ok | done | 广播空账号；C5 回首登 | — |
| —（创建） | startup_detected | startup_recovering | resetState()≠0 强制门：先于路由/同步/Agent | — |
| startup_recovering | startup_pending | clearing_sessions | **重新幂等清会话（安全重放）**——pending=1 时清理阶段是否完成不可知，幂等重放清会话后才允许 finalize | （保持 ｜ `reset_incomplete`） |
| startup_recovering | startup_incomplete_session_cleared | finalizing | pending=2：会话已清，直接幂等调用 finalizeReset | （保持 ｜ `reset_incomplete`） |

- 闭合规则：R-非法（保持+审计）/ R-终态（done 忽略后续）/
  R-重复（begin 在非 idle 态 → R-非法；retry_finalize/finalizeReset 幂等）。
- 不变量：pending≠0 期间正常路由/自动同步/Agent 禁止；所有写入携带 resetEpoch，
  过期即拒；**会话清理失败不得绕过后删库**；pending=1/2 后续失败统一
  `reset_incomplete`（09 §2.4 L2-18），beginReset 未提交且 pending=0 时使用
  `write_commit_failed`，不得冒充持久 pending。

### 4.4 D-04 撤销槽（CT-C3-17；单槽 + 启动清槽）

- 状态全集：`empty*, occupied_valid, occupied_invalid`
- 事件：`record, undo_req, undo_ok, undo_fail, clear_at_startup`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| empty | record | occupied_valid | 覆盖写单行（slot=1 CHECK）；信封 v1{version,kind,accountId,safeSummary,payload} | （occupied_invalid ｜ 仅审计：写已提交、撤销能力降级） |
| occupied_valid | undo_req | occupied_valid | 校验 accountId 与信封；非法时拒绝（他账号槽绝不删除/改写） | （保持 ｜ `invalid_undo_command`） |
| occupied_valid | undo_ok | empty | 11 类恢复器/composite 逐操作恢复 + 删槽 + 审计 | — |
| occupied_valid | undo_fail | occupied_valid | 保槽 + 审计（undo:failure） | （保持 ｜ `invalid_undo_command`） |
| occupied_valid | record | occupied_valid | 覆盖（新快照替换旧快照） | — |
| occupied_invalid | record | occupied_valid | 覆盖修复 | — |
| occupied_invalid | undo_req | occupied_invalid | 拒绝 + 审计（槽非法不可撤） | （保持 ｜ `invalid_undo_command`） |
| （任意态） | clear_at_startup | empty | 启动清槽（ADR-010 语义显式化；刻意全状态兜底） | — |

- 闭合规则：R-非法/R-终态（无终态：empty 可再 record）/
  R-重复（record 幂等覆盖；undo_ok 后空槽再 undo_req → R-非法）。
- 不变量：他账号槽绝不删除/改写；Agent 写入不占槽（NoopUndoRecorder）；
  复合操作 = 单槽整包快照（CT-C4-09）。

### 4.5 D-05 sync run 账本状态机（CT-C2-05/06/07 + CT-C3-21）

- 状态全集（run 六值）：`running*, success†, failed†, cancelled†, interrupted†,
  needs_user_action†`
- 事件：`start, finish_ok, finish_fail, job_cancelled, user_action_required,
  app_crash, login_paused`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| running | start | running | 重复 start → R-非法（保持+审计） | — |
| running | login_paused | running | needs_user_login 暂停：保持 running（CT-C2-06；确认后同一 run 继续） | — |
| running | finish_ok | success | finishSyncRun(success, result_code∈{imported,replayed,reauthenticated}) | — |
| running | job_cancelled | cancelled | bump(cancel) 已先行（§5.1/CT-C3-21）；finishSyncRun(cancelled) | — |
| running | finish_fail | failed | finishSyncRun(failed, code)（collection_failed/9 码/stale_lease 等） | — |
| running | user_action_required | needs_user_action | finishSyncRun(needs_user_action, code)（如 reauthentication_required） | — |
| running | app_crash | interrupted | 下次启动 recoverInterruptedRuns 标 interrupted/app_restarted（ADR-022） | — |
| —（创建） | start | running | 写 running 行；trigger∈4 值（CT-C2-05）；首登在账号行存在前不写（CT-C3-21 私有实现） | — |

- 闭合规则：R-非法/R-终态（五个终态 × 任何事件 → 幂等忽略——终态行不重放动作）/
  R-重复（重复 login_paused 保持 running；重复 finish 在终态由 R-终态吸收）。
- 不变量：单一写权威 = C2 经 SourceStateService（CT-C3-21）；importBundle 不写
  sync_runs；finish 校验 runId 与 stamp 绑定。

## 5. M2 组件状态机（采集引擎 + JW）

### 5.1 D-06 JobArbiter 全局来源作业租约（CT-C2-01 仲裁规则①；A-4 整改）

- 状态全集：`free*, held(jobId, stamp), maintenance(kind), maintenance_draining(kind, jobId)`
  （本机无终态；两个维护态均拒绝 acquire，但可经 jobs_drained/end_maintenance 离开）
- 事件：`acquire, release, begin_maintenance, jobs_drained, operation_fail, end_maintenance`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| free | acquire | held | **同步原子** check-and-hold（C2 单线程，无 await） | — |
| held | acquire | held | 拒绝（保持已持有租约） | （保持 held ｜ `busy`） |
| held | release | free | 终态/异常路径 try/finally 释放 | — |
| free | begin_maintenance | maintenance | 维护门（CT-C2-04）；拒新 acquire | — |
| held | begin_maintenance | maintenance_draining | 拒新 acquire；**按 MaintenanceKind 执行**（A-4 整改）：deleteCredentials/clearSession → 受影响来源 bump(cancel)；clearBusinessData → 全部来源 bump(clearBusinessData)（根 reason，内部取消不重复）；随后取消并等待旧作业终态 | — |
| maintenance_draining | operation_fail | maintenance_draining | 取消/等待旧作业失败；保持维护门/写屏障并允许重试或显式 abort | （保持 maintenance_draining ｜ `maintenance_failed`） |
| maintenance_draining | jobs_drained | maintenance | 旧作业全部终态；继续维护操作本体（删凭据/清会话/清业务数据） | — |
| maintenance | begin_maintenance | maintenance | 同 kind 重复请求幂等保持；不同 kind 拒绝 | （保持 maintenance ｜ `maintenance_in_progress`） |
| maintenance_draining | begin_maintenance | maintenance_draining | 同 kind 重复请求幂等保持；不同 kind 拒绝 | （保持 maintenance_draining ｜ `maintenance_in_progress`） |
| maintenance | operation_fail | maintenance | 保持维护门/写屏障；允许重试，或先完成显式 abort 收尾 | （保持 maintenance ｜ `maintenance_failed`） |
| maintenance | end_maintenance | free | 仅同 kind 维护成功或显式 abort 收尾完成后释放；不同 kind 拒绝 | （保持 maintenance ｜ `maintenance_in_progress`） |
| maintenance | acquire | maintenance | 拒绝 | （保持 ｜ `maintenance_in_progress`） |
| maintenance_draining | acquire | maintenance_draining | 拒绝 | （保持 ｜ `maintenance_in_progress`） |

- 闭合规则：R-非法（free×release/end_maintenance/jobs_drained、held×end_maintenance/
  jobs_drained、maintenance_draining×end_maintenance 等未列组合保持+审计）/
  R-终态（本机无终态，不适用）/R-重复（release 后再次 release 由 free×release 的
  R-非法幂等保持；重复 begin_maintenance 的同/不同 kind 行为由显式行定义）。
- 不变量：至多一个 held 或一个 maintenance_draining；`isBusy()` 仅提示性
  （正确性靠原子 acquire）；reset 不依赖本门（走持久 reset_pending，D-03）。

### 5.2 D-07 作业八相位状态机（CT-C1-01/CT-C1-02；A-5 整改）

- 状态全集（**状态名逐字用冻结枚举**）：`starting*, checkingSession, waitingForUser,
  collecting, needsUserLogin, complete†, cancelled†, failed†`
- 事件：`job_start, session_healthy, session_needs_login, session_unknown,
  resume_ok, resume_fail, auth_done, captcha_shown, auth_fail, collecting_done,
  cancel_received, error(code)`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| starting | job_start | checkingSession | 发 starting 事件（seq=1）；safeCount 复位 | （failed ｜ 每作业码子集，见下） |
| checkingSession | session_healthy | collecting | probeSession（CT-P-02）通过；跳过交互登录 | — |
| checkingSession | session_needs_login | needsUserLogin | 暂停态：流不断、租约保持、sequence 连续 | — |
| checkingSession | session_unknown | needsUserLogin | 保守处理（不假装健康）：按需登录路径走，CAS 三层核验兜底身份确认 | — |
| needsUserLogin | resume_ok | waitingForUser | 恢复同一作业同一流；注入凭据租约（resumeLogin，CT-C1-02）→ takePassword 取即失效 → CAS 交互登录（D-10） | — |
| needsUserLogin | resume_fail | failed | 恢复失败明确终态 | （failed ｜ `collection_failed`/`query_failed` 按 mode） |
| waitingForUser | auth_done | collecting | 三层核验齐 → verifiedUsername 入终态载荷；继续采集 | — |
| waitingForUser | captcha_shown | waitingForUser | 幂等保持人工验证码/短信等待（不自动化） | — |
| waitingForUser | auth_fail | failed | 三层核验缺一 | （failed ｜ `account_mismatch`） |
| collecting | collecting_done | complete | safeCount 递增；终态载荷就位；**C1 事件流随即关闭**——C2 的 stamp 校验与交接在 C1 状态机之外（A-5 整改：complete 即终态，无 deliver_ok 相位） | — |
| （任意非终态） | cancel_received | cancelled | **接受时刻先 bump(cancel)**（C2）→ C1 协作式检查点终止；暂停态立即终态 | — |
| （任意非终态） | error(code) | failed | 终态错误事件（code + 固定文案） | （failed ｜ 每作业码子集） |

- **每作业可产生的失败码子集（A-5 整改，冻结）**：
  - collection 作业（jw/young-schedule）的 **failed phase**：
    `{account_mismatch, collection_failed}`
  - query 作业（young-enrolment/icourse/campus）：`{account_mismatch, query_failed,
    result_validation_failed, catalog_unavailable}`
  - `cancelled` 只由 `cancel_received → cancelled` 产生，不得放入 `error(code) → failed`
    的码子集；
  - 其余码（busy/no_account/stale_lease/maintenance_in_progress/maintenance_failed 等）
    是**作业创建前/交接后**的码，不得作为 C1 作业 failed 事件发出。
- 闭合规则：R-非法/R-终态（complete/cancelled/failed 忽略后续事件）/
  R-重复（captcha_shown 幂等；error 后的事件被终态规则吸收）。
- 不变量：needsUserLogin 恢复同一 jobId、sequence 连续（ADR-005）；凭据只在
  恢复注入、取即失效；终态后事件流关闭、租约释放；迟到结果 `stale_lease`。

### 5.3 D-08 WebSessionEngine 卡槽状态机（CT-P-01/02；A-6 整改）

- 状态全集：`absent*, opening, ready, needs_login, quarantined, closing`
- 事件：`open, open_ok, open_fail, probe_healthy, probe_needs_login, probe_unknown,
  auth_ok, auth_fail, close_req, close_ok, quarantine_mark, clear_ok, clear_fail,
  residue_found`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| absent | open | opening | P 打开账号独立数据分区（不透明 SessionPartitionRef） | — |
| opening | open_ok | ready | 收集前健康探测（ADR-002） | — |
| opening | open_fail | absent | 分区打开失败；审计 | （absent ｜ `collection_failed`） |
| ready | probe_healthy | ready | 可采集（幂等） | — |
| ready | probe_needs_login | needs_login | 触发 CAS 登录（D-10） | — |
| ready | probe_unknown | needs_login | 保守：未知不假装健康，走登录路径由 CAS 三层核验兜底（A-6 整改） | — |
| needs_login | auth_ok | ready | CAS 登录状态机完成后回写 | — |
| needs_login | auth_fail | quarantined | **显式隔离转移**（A-6 整改）：持久 quarantine 标记 + 关闭占用句柄 + 待 clearPartition | （quarantined ｜ `account_mismatch`） |
| absent/opening/ready/needs_login/closing | close_req | closing | 作业终态/维护释放卡槽（A-6 整改：quarantined 不适用本行） | — |
| closing | close_ok | absent | 关闭完成 | — |
| （任意非 quarantined） | quarantine_mark | quarantined | 持久标记（清理成功前跨重启禁复用）；顺序=标记→关闭句柄→clearPartition | — |
| quarantined | close_req | quarantined | 拒绝：隔离分区不因关闭句柄而解除隔离（R-非法，保持+审计） | （保持 ｜ 仅审计） |
| quarantined | clear_ok | absent | 真删除分区（物理删除语义）；**唯一离开 quarantined 的路径** | — |
| quarantined | clear_fail | quarantined | 标记保留、跨重启禁复用、报 UI | （保持 ｜ 仅审计 + UI 报告） |
| —（创建） | residue_found | quarantined | 崩溃脏状态恢复：先隔离后清理 | — |

- 闭合规则：R-非法/R-终态（无传统终态；quarantined 只经 clear_ok 离开）/
  R-重复（probe 幂等；clear 幂等）。
- 不变量：卡槽生命周期引擎独占（适配器不得私自 open/close）；清会话/重置遍历
  全部已安装通道（CT-C2-02 全集）；"清理=物理删除、探测=健康状态（含 unknown 的
  保守出口）、隔离=持久标记"三语义三端一致（跨平台契约）。

### 5.4 D-09 导航就绪状态机（A-7 整改：三标志正交幂等置位）

- 状态全集（位图 = u(URL 匹配)/d(DOM 就绪)/h(脚本握手)，幂等置位）：
  `init(000)*, u(100), d(010), h(001), ud(110), uh(101), dh(011),
  target_ready(111)†, timed_out, failed†`
- 事件：`navigate_start, url_matched, dom_ready, ready_handshake, timeout,
  retry, user_wait, give_up, error`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| init | navigate_start | init | P 导航（CT-P-01）；三标志清零 | （failed ｜ `collection_failed`） |
| （任一非终态标志态） | url_matched | 置 u 位 | 幂等置位；三齐 → target_ready | — |
| （任一非终态标志态） | dom_ready | 置 d 位 | 幂等置位；三齐 → target_ready | — |
| （任一非终态标志态） | ready_handshake | 置 h 位 | 幂等置位；三齐 → target_ready | — |
| （任一非终态） | timeout | timed_out | 超时挂起 | — |
| timed_out | retry | init | navigate_start 清零重来（有限重试次数归 M2 参数，D-29 移交） | — |
| timed_out | user_wait | timed_out | 转人工等待（人工完成后 retry） | — |
| timed_out | give_up | failed | 放弃：明确失败 | （failed ｜ `collection_failed`） |
| （任一非终态） | error | failed | 明确失败 | （failed ｜ `collection_failed`） |

- 闭合规则：R-非法（target_ready/failed × 后续事件 → R-终态忽略）/
  R-终态/R-重复（三事件幂等置位——**乱序到达全部被吸收**，A-7 整改兑现）。
- 不变量：就绪判定三条件缺一不可；**任何事件到达顺序都收敛到同一状态**
  （位图幂等）；ready 握手由登记提取脚本完成（ADR-019 修订）；
  target_ready 后的晚到事件忽略（终态规则）。

### 5.5 D-10 CAS 交互登录状态机（ADR-003；A-8 整改）

- 状态全集：`initial*, form_filled, submitted, verifying, waiting_user,
  authenticated†, mismatched†`
- 事件：`fill_ok, fill_fail, submit_ok, evidence_partial, evidence_complete,
  evidence_conflict, captcha_or_sms, manual_done`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| initial | fill_ok | form_filled | 白名单 origin 填表（username 来自租约 expectedUsername；密码 takePassword 后填） | — |
| initial | fill_fail | waiting_user | 按钮异常 → 静默回退人工（人工只替代填表） | — |
| form_filled | submit_ok | submitted | 提交登录 | — |
| submitted | evidence_partial | verifying | 幂等收集三层核验证据（DOM 属性/performance/storage） | — |
| submitted | captcha_or_sms | waiting_user | 验证码/短信交人工（不自动化） | — |
| waiting_user | manual_done | verifying | **人工完成后进入核验，不得直接 authenticated**（A-8 整改：三层核验不可跳过） | — |
| verifying | evidence_complete | authenticated | 三层齐 → 通过 | — |
| verifying | evidence_conflict | mismatched | 任一缺/冲突 → 明确失败 | （mismatched ｜ `account_mismatch`） |

- 闭合规则：R-非法/R-终态（authenticated/mismatched 忽略后续）/
  R-重复（evidence_partial 幂等收集）。
- 不变量：填表仅白名单 origin；三层核验缺一即 `account_mismatch`
  （明确失败优于假装成功）；验证码不自动化；verifiedUsername 一经产生即作为
  终态载荷字段（CT-C1-01）。

### 5.6 D-11 CredentialLease 生命周期（CT-C2-03；A-9 整改）

- 状态全集：`active*, consumed, revoked†`
- 事件：`take_password, revoke_req, job_terminal`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| active | take_password | consumed | 原子取即失效（首次返回秘密并置空） | — |
| consumed | take_password | consumed | 返回 null（原子语义，幂等） | — |
| revoked | take_password | revoked | 返回 null | — |
| active | revoke_req | revoked | 幂等撤销；revoke 后 takePassword 恒 null | — |
| consumed | revoke_req | revoked | 幂等 | — |
| revoked | revoke_req | revoked | **幂等闭合（A-9 整改）** | — |
| active | job_terminal | revoked | **作业终态自动失效**（A-9 整改：不变量进转移表） | — |
| consumed | job_terminal | consumed | 已消费，终态保持 | — |
| revoked | job_terminal | revoked | 幂等 | — |

- 闭合规则：R-非法/R-终态/R-重复（全部行幂等）。
- 不变量：takePassword/revoke 串行化（C2 单线程持有）；删除凭据/completeReset 前
  先 revoke 全部未消费租约。

## 6. 待补组件清单与里程碑触发器（M1–M8）

| 组件 | 触发器 | 补设计时必须包含 |
|---|---|---|
| D-22/D-23/D-24/D-25/D-29/D-30（M2 引擎周边） | M2 开工前 | JobGate 闸、JW 管道四工位、通道注册/切换（unregister 前清会话）、SyncCoordinator（freshness/backoff/syncAll）、transient/fatal 分类与有限重试、syncAll 恢复语义（10 §10 移交项） |
| D-12/D-13 young 双适配器（M3） | M3 开工前 | 管道四工位状态机 + needs_user_login 恢复转移 + 封闭字段映射 |
| D-14 icourse 适配器 + 24h 缓存（M4） | M4 开工前 | 缓存状态机（fresh/stale/miss）+ 降级转移 |
| D-15 campus 刷新/详情/附件（M4） | M4 开工前 | 节流/过期/降级状态机 + 附件登记载荷生成点 + CT-C3-22 调用 |
| D-16 提醒协调器（M5） | M5 开工前 | reminders 五态转移 + 6 表 watch 重入保护 + 哨兵语义 |
| D-20/D-21 M1 纯函数算法 | M1 对应实现开工前 | 有效事件/冲突投影算法 + 重复系列物化/生命周期算法；先补算法设计再实现 |
| D-26 provisional 生命周期 | M2 首登/JW 联调前 | stage/commit/cancel/discard 完整状态机 + busy 前后边界 + 进程退出尽力零化 |
| D-17/D-27/D-28 维护与启动（M5） | M5 开工前 | 维护协调器 UI 投影 + clearBusinessData 写屏障 + 启动强制门 |
| D-18 Agent 推理循环/审批门/预算（M6） | M6 开工前 | 8×12 预算转移 + 确认卡状态机 + 复合写 ledger |
| D-19 Python 租户生命周期（M2 并存期） | 并存期联调前 | 启动/健康/停止状态机 + 事件流转换 + M7 移除路径 |

## 7. 横切状态机交互一致性规则（可机械核对）

| 规则 | 涉及状态机 | 一致性要求 |
|---|---|---|
| R1 取消即递增 | D-05/D-06/D-07 | 取消接受时刻 bump 先于 cancelled 终态；**reason 按根操作**：直接取消/deleteCredentials/clearSession 维护内取消= cancel；clearBusinessData/reset=根 reason，内部取消不重复 |
| R2 迟到拒绝 | D-02/D-07 | 任何 C3 写事务内比对 stamp（含 replay 路径）；过期 → stale_lease、零写入 |
| R3 维护互斥 | D-06/D-07/D-01 | maintenance/maintenance_draining 期间 acquire 恒拒；迁移器运行期间无作业可启动（启动门） |
| R4 暂停语义 | D-05/D-07 | needsUserLogin 期间 run 保持 running、租约保持、sequence 连续 |
| R5 租约释放 | D-06/D-11 | 作业任何终态释放全局租约（try/finally）与凭据租约（job_terminal→revoked） |
| R6 provisional 边界 | 09 CT-C3-03/04 + D-06 | 先 acquire 后 stage；acquire 失败无 handle、不调销毁；stage 后任何失败出口调 cancel/discard |

## 8. 本层拍板记录（L4 决策）

| 编号 | 决策 | 内容 | 状态 |
|---|---|---|---|
| L4-01 | 本层范围 | M1/M2 核心状态机先设计（D-01~D-11）；其余登记待补，每块开工前补设计 | ✅ 已定 |
| L4-02 | 首轮独立审查整改（2026-08-14，10A/4B） | A-1 三闭合规则模板 / A-2 replay 过租约守卫 / A-3 reset 顺序与启动安全重放 / A-4 维护 reason 按 kind / A-5 枚举名与终态所有权 + 码子集 / A-6 unknown 保守出口 + quarantine 闭环 / A-7 三标志位图 / A-8 manual_done 进核验 / A-9 revoke 幂等 + 终态失效 / A-10 失败态双列 + `reset_incomplete` 回写 09（L2-18）；B-1 登记表补 D-22~D-30 / B-2 状态三档 / B-3 断言措辞与备份策略移交 / B-4 旧表述清零 | ✅ 已落地 |
| L4-03 | 整改复审修订（2026-08-14） | D-02 subject/active/stamp 同事务守卫 + subject_fail；D-03 五失败态归位与启动事件闭合；D-06 非终态维护态及 `maintenance_failed` 回写 09（L2-19）；D-07 cancelled 退出 failed 子集；L2-18 限定 pending=1/2；闭合规则优先级、D-20/21/D-26 触发器与 09/10 回写记录补齐 | ✅ 已修改，待独立复审重认 gate |

## 9. 第 4 层 gate 检查表

- [ ] ① 已设计状态机（D-01~D-11）每个满足 §2 模板：状态全集（标注初始/终态）+
      显式转移表 + 三闭合规则 + 失败态双列 + 不变量
- [ ] ② 登记表（§3，D-01~D-30）每行有里程碑与三档状态；待补组件均有触发器（§6）
- [ ] ③ §7 六条横切规则在全部转移表中无违背（R1~R6 逐条过）
- [ ] ④ 转移表与 09 冻结契约一致（CT-C1-01 八相位枚举名、CT-C2-06 run 六值、
      CT-C2-03 takePassword 原子、CT-C3-05 三值编码、CT-C3-21 四 reason）
- [ ] ⑤ 失败态双列中的对外码全部在 09 §2.4 注册表（含 L2-18
      `reset_incomplete` / L2-19 `maintenance_failed`）
- [ ] **gate 关闭条件**：独立复审通过 → M0/M1 按本文件施工（每做新组件先补设计）
