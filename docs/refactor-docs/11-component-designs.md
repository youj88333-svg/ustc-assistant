# 11 组件设计（六层阶梯 · 第 4 层）

> 产出日期：2026-08-14 ｜ 状态：**草稿（M1/M2 组件已设计；M3–M8 组件登记待补）**
> ｜ 依据：`09-contracts.md`（CT 65 条）、`10-runtime.md`（五链路走查）、
> `07-constitution.md`（ADR-000~023）、08 容器切分、01–06 模块文档
> ｜ 纪律（AGENTS.md 阶梯规则）：第 4 层**不必一次做完**——M1 后"每做一块组件、
> 先补一块设计"；本文件是组件设计的唯一登记处。

## 1. 本层目标与 gate

- 目标：逐容器内部组件设计。本层交付物 = **状态机转移表**（状态全集 + 转移 +
  失败态）——这是 AGENTS.md 对第 4 层的硬 gate。
- 本次覆盖：**M1（存储核心）与 M2（采集引擎 + JW）** 的全部关键状态机；
  其余里程碑组件只登记、不设计（进入该里程碑前补设计，见 §6 触发器）。
- **gate：已设计组件每个状态机有完整转移表（状态全集 + 转移 + 失败态）；
  登记表中每个"待补"组件有明确的里程碑触发器；横切交互一致性规则可机械核对
  （§7）。**

## 2. 状态机模板与符号

每个状态机按以下模板冻结：

```
状态全集（S）：全部状态，含初始态、终态、暂停态、失败态
事件（E）：触发转移的内部/外部事件
转移表：当前态 × 事件 →（次态，动作，失败态）
不变量：状态机存活期间必须保持的约束（违者 = 组件 bug）
```

- 转移表三要素缺一即未设计完成（gate 判据）。
- 失败态一律映射 §2.4 稳定错误码（`09-contracts.md`）；"失败态"列写错误码或
  恢复语义（如"保持当前态 + 审计"）。
- 与第 2/3 层的关系：契约（CT）定"什么能发生"，本层定"组件内部如何发生"；
  转移表不得违背 CT 冻结语义（如 needs_user_login 期间 run 保持 running）。

## 3. 组件登记表

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
| D-09 | 导航就绪状态机 | C1 | M2 | ✅ §5.4 |
| D-10 | CAS 交互登录状态机 | C1 | M2 | ✅ §5.5 |
| D-11 | CredentialLease 生命周期 | C2/C3 | M2 | ✅ §5.6 |
| D-12 | young-schedule 适配器管道 | C1 | M3 | ⬜ 待补（触发器：M3 开工前） |
| D-13 | young-enrolment 适配器管道 | C1 | M3 | ⬜ 待补（触发器：M3 开工前） |
| D-14 | icourse 适配器 + 缓存状态机 | C1 | M4 | ⬜ 待补（触发器：M4 开工前） |
| D-15 | campus 刷新/详情/附件管道 | C1/C3 | M4 | ⬜ 待补（触发器：M4 开工前） |
| D-16 | 提醒协调器（含 6 表 watch） | C3/P | M5 | ⬜ 待补（触发器：M5 开工前） |
| D-17 | CompleteReset/维护协调器 UI 编排 | C5 | M5 | ⬜ 待补（触发器：M5 开工前） |
| D-18 | Agent 推理循环 + 审批门 + 预算 | C4 | M6 | ⬜ 待补（触发器：M6 开工前） |
| D-19 | Python 租户生命周期（并存期） | C2/P | M2 | ⬜ 待补（触发器：并存期联调前） |
| D-20 | 有效事件投影 + 冲突投影纯函数 | C3 | M1 | ✅ 契约已冻结（CT-C3-13/09a）；纯函数无状态机，M1 实现时补算法细节 |
| D-21 | 重复系列投影/生命周期 | C3 | M1 | ✅ 同上（CT-C3-12）；M1 实现时补算法细节 |

## 4. M1 组件状态机（存储核心）

### 4.1 D-01 v7→v8 迁移器（ADR-011/012；唯一搬家路径）

- 状态全集：`idle, backing_up, migrating, verifying, committed, rolled_back, failed`
- 事件：`start, backup_ok, backup_fail, migrate_ok, migrate_fail, verify_ok, verify_fail`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| idle | start | backing_up | 备份 v7 库副本到 P 私有目录（迁移前自动备份，红线 2.2-7） | — |
| backing_up | backup_ok | migrating | 打开备份完整性校验（大小+可打开） | — |
| backing_up | backup_fail | failed | 不触碰主库；审计 `migration_backup_failed` | `sync_failed`（UI：数据未动） |
| migrating | migrate_ok | verifying | Drift 迁移器执行（v8 七项变更，单事务语义） | — |
| migrating | migrate_fail | rolled_back | 主库保持 v7（事务回滚）；审计 | `sync_failed` |
| verifying | verify_ok | committed | schemaVersion=8；四步迁移测试对应断言已跑 | — |
| verifying | verify_fail | rolled_back | 同上回滚 | `sync_failed` |
| committed | — | 终态 | 备份副本保留（用户确认后清理或自动过期）；广播"已迁移" | — |
| rolled_back | — | 终态 | 主库仍 v7；可重试 start | — |

- 不变量：迁移全程主库独占（启动门：迁移未完成前禁止正常路由/自动同步/Agent）；
  任何失败不得留下半迁移状态；`migrating→verifying` 之间的校验失败同样整体回滚。

### 4.2 D-02 ImportService 导入流水线（CT-C3-02）

- 状态全集：`accepting, decoding, validating, checking_subject, checking_idempotency,
  importing, reconciling, done, failed`
- 事件：`bytes_received, decode_ok, decode_fail, semantics_ok, semantics_fail,
  subject_ok, subject_fail, replay_hit, proceed, tx_ok, tx_fail, reconcile_ok,
  reconcile_fail`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| accepting | bytes_received | decoding | 16MB/深度 64/schema 门禁（CT-C1-03 解码段） | — |
| decoding | decode_ok | validating | 语义校验（9 错误码） | — |
| decoding | decode_fail | failed | 稳定错误码回传（不回显源内容） | 9 个 bundle 码之一 |
| validating | semantics_ok | checking_subject | subject.accountId == stamp.accountId | — |
| validating | semantics_fail | failed | 同上 | 9 个 bundle 码之一 |
| checking_subject | subject_ok | checking_idempotency | bundleId/digest 幂等查（UNIQUE 约束） | — |
| checking_subject | subject_fail | failed | 不写库 | `subject_mismatch` |
| checking_idempotency | replay_hit | done(replayed) | 直接返回（幂等重放） | — |
| checking_idempotency | proceed | importing | **单事务**：stamp 复验（sourceGeneration/resetEpoch 与库值）+ import_batches + localId 复用 + upsert + source_records presence 对齐 + ActionLog | `stale_lease`（事务内复验失败 → 整体回滚、不写库） |
| importing | tx_ok | reconciling | 事务外提醒协调（失败降级 pending） | — |
| importing | tx_fail | failed | 整体回滚 | `sync_failed` |
| reconciling | reconcile_ok | done(imported) | ImportResult{status, importBatchId, pending=false} | — |
| reconciling | reconcile_fail | done(imported) | ImportResult{pending=true}（审计 retryable_failure） | 降级非失败 |

- 不变量：stamp 校验与业务写入**同一事务**（TOCTOU 闭合）；提醒协调失败不重试导入；
  迟到结果在任何入口都 `stale_lease`。

### 4.3 D-03 reset 协调状态机（CT-C3-05；reset_pending 三值编码）

- 持久态（DB，跨重启）：`reset_pending ∈ {0=none, 1=pending, 2=incomplete_session_cleared}`
- 协调器运行态：`idle, previewing, beginning, draining_c2, draining_c4, clearing_sessions, finalizing, done, startup_recovering`
- 事件：`user_confirm_x2, begin, begin_ok, begin_fail, c2_drained, c2_drain_fail,
  c4_drained, c4_drain_fail, sessions_cleared, clear_fail, finalize, tx_ok,
  tx_fail, startup_detected`

| 当前态 | 事件 | 次态 | 动作（持久效果） | 失败态 |
|---|---|---|---|---|
| idle | user_confirm_x2 | previewing | 清单预览（CT-C5-01） | — |
| previewing | begin | beginning | beginReset：pending=1、resetEpoch++、写屏障 | begin_fail → idle（原状） |
| beginning | c2_drained | draining_c2 | revoke 租约→终止→cancelAll→等待→bump(reset) | c2_drain_fail → 保持 pending=1（可重试） |
| draining_c2 | c4_drained | draining_c4 | C4 拒新+取消+等待写终态 | c4_drain_fail → 保持 pending=1 |
| draining_c4 | sessions_cleared | clearing_sessions | 开始全通道 clearSession（幂等） | clear_fail → 保持 pending=1，不得绕过后删库 |
| clearing_sessions | finalize | finalizing | finalizeReset 单事务删+清标记 | tx_fail → pending=2 |
| finalizing | tx_ok | done | 广播空账号；C5 回首登 | — |
| done | — | 终态 | pending=0（随账号行删除） | — |
| （启动） | startup_detected | startup_recovering | resetState()≠0 强制门：先于路由/同步/Agent | 恢复失败 → 保持屏障 + 专用恢复界面 |
| startup_recovering | finalize | finalizing | =1 或 =2 均继续 finalization（=2 提示"可能需重新登录"） | — |

- 不变量：pending≠0 期间正常路由/自动同步/Agent 禁止；所有写入携带 resetEpoch，
  过期即拒；finalizeReset 幂等（重复执行=已删除再删，无害）。

### 4.4 D-04 撤销槽（CT-C3-17；单槽 + 启动清槽）

- 状态全集：`empty, occupied_valid, occupied_invalid`
- 事件：`record, undo_ok, undo_fail, clear_at_startup`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| empty | record | occupied_valid | 覆盖写单行（slot=1 CHECK）；信封 v1{version,kind,accountId,safeSummary,payload} | 信封非法 → occupied_invalid |
| occupied_valid | undo_ok | empty | 11 类恢复器/composite 逐操作恢复 + 删槽 + 审计 | — |
| occupied_valid | undo_fail | occupied_valid | 保槽 + 审计（undo:failure） | `invalid_undo_command` |
| occupied_valid | record | occupied_valid | 覆盖（新快照替换旧快照） | — |
| occupied_invalid | record | occupied_valid | 覆盖修复 | — |
| occupied_invalid | undo | occupied_invalid | 拒绝 + 审计（槽非法不可撤） | `invalid_undo_command` |
| （任意） | clear_at_startup | empty | 启动清槽（ADR-010 语义显式化） | — |

- 不变量：他账号槽绝不删除/改写（accountId 校验失败 → occupied_invalid 保留）；
  Agent 写入不占槽（NoopUndoRecorder）；复合操作 = 单槽整包快照（CT-C4-09）。

### 4.5 D-05 sync run 账本状态机（CT-C2-05/06/07 + CT-C3-21）

- 状态全集（run 六值）：`running, success, failed, cancelled, interrupted, needs_user_action`
- 事件：`start, finish_ok, finish_fail, job_cancelled, user_action_required,
  app_crash, login_paused`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| （无） | start | running | startSyncRun(stamp, trigger) 写 running 行；trigger∈4 值（CT-C2-05） | 首登在账号行存在前不写（CT-C3-21 私有实现） |
| running | login_paused | **running** | needs_user_login 暂停：保持 running（CT-C2-06；确认后同一 run 继续） | — |
| running | finish_ok | success | finishSyncRun(success, result_code∈{imported,replayed,reauthenticated}) | — |
| running | job_cancelled | cancelled | bump(cancel) 已先行（§5.1/CT-C3-21）；finishSyncRun(cancelled) | — |
| running | finish_fail | failed | finishSyncRun(failed, code)（collection_failed/9 码/stale_lease 等） | — |
| running | user_action_required | needs_user_action | finishSyncRun(needs_user_action, code)（如 reauthentication_required） | — |
| running | app_crash | interrupted | 下次启动 recoverInterruptedRuns 标 interrupted/app_restarted（ADR-022：跨重启作废） | — |

- 不变量：单一写权威 = C2 经 SourceStateService（CT-C3-21）；importBundle 不写
  sync_runs；finish 校验 runId 与 stamp 绑定。

## 5. M2 组件状态机（采集引擎 + JW）

### 5.1 D-06 JobArbiter 全局来源作业租约（CT-C2-01 仲裁规则①）

- 状态全集：`free, held(jobId, stamp), maintenance(kind), maintenance_draining(kind, jobId)`
- 事件：`acquire, release, begin_maintenance, end_maintenance, jobs_drained`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| free | acquire | held | **同步原子** check-and-hold（C2 单线程，无 await） | 占用 → 抛 `busy` |
| held | release | free | 终态/异常路径 try/finally 释放 | — |
| free | begin_maintenance | maintenance | 维护门（CT-C2-04）；拒新 acquire | 维护中 acquire → `maintenance_in_progress` |
| held | begin_maintenance | maintenance_draining | 拒新 acquire；内部先 bump(cancel)（受影响来源）→ 取消并等待旧作业终态（10 §7.2~7.4 流程） | 取消/等待失败 → 保持 draining、不开始清理 |
| maintenance_draining | jobs_drained | maintenance | 旧作业全部终态；继续维护操作本体（删凭据/清会话/清业务数据） | — |
| maintenance | end_maintenance | free | 门释放 | — |
| maintenance | acquire | maintenance | 拒绝 | `maintenance_in_progress` |
| maintenance_draining | acquire | maintenance_draining | 拒绝 | `maintenance_in_progress` |

- 不变量：至多一个 held 或一个 maintenance_draining；维护期（两 maintenance 态）
  无新 acquire；`isBusy()` 仅提示性（正确性靠原子 acquire）；reset 不依赖本门
  （走持久 reset_pending）。

### 5.2 D-07 作业八相位状态机（CT-C1-01/CT-C1-02；引擎核心，v2 教训）

- 状态全集（相位八值）：`starting, checking_session, waiting_for_user, collecting,
  needs_user_login, complete, cancelled, failed`
- 事件：`job_start, session_healthy, session_needs_login, resume_ok, auth_done,
  auth_fail, captcha_shown, collecting_done, deliver_ok, cancel_received, error(code)`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| starting | job_start | checking_session | 发 starting 事件（seq=1）；safeCount 复位 | error → failed(code) |
| checking_session | session_healthy | collecting | probeSession（CT-P-02）通过；跳过交互登录（会话已登录） | error → failed(code) |
| checking_session | session_needs_login | needs_user_login | 暂停态：流不断、租约保持、sequence 连续 | — |
| needs_user_login | resume_ok | waiting_for_user | 恢复同一作业同一流；注入凭据租约（resumeLogin，CT-C1-02）→ takePassword 取即失效 → CAS 交互登录（D-10） | resume 失败 → failed |
| waiting_for_user | auth_done | collecting | 三层核验齐 → verifiedUsername 入终态载荷；继续采集 | — |
| waiting_for_user | captcha_shown | waiting_for_user | 验证码/短信交人工（不自动化） | — |
| waiting_for_user | auth_fail | failed | 三层核验缺一 | `account_mismatch` |
| collecting | collecting_done | complete | safeCount 递增；构造 CollectionCompleted/QueryCompleted | error → failed(code) |
| complete | deliver_ok | 终态 | C2 校验 stamp → 交接（迟到 → stale_lease） | — |
| （任意非终态） | cancel_received | cancelled | **接受时刻先 bump(cancel)**（C2）→ C1 协作式检查点终止；暂停态立即终态 | — |
| （任意非终态） | error(code) | failed | 终态错误事件（code + 固定文案） | code ∈ §2.4 全集 |

- 不变量：needs_user_login 恢复同一 jobId、sequence 连续（ADR-005）；凭据只在
  恢复注入、取即失效；终态后事件流关闭、租约释放；迟到结果 `stale_lease`。

### 5.3 D-08 WebSessionEngine 卡槽状态机（CT-P-01/02；ADR-002/019）

- 状态全集：`absent, opening, ready, needs_login, quarantined, closing`
- 事件：`open, open_ok, open_fail, probe_healthy, probe_needs_login, auth_ok,
  auth_fail, close_req, close_ok, quarantine_mark, clear_ok, clear_fail, residue_found`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| absent | open | opening | P 打开账号独立数据分区（不透明 SessionPartitionRef） | open_fail → absent + `collection_failed` |
| opening | open_ok | ready | 收集前健康探测（ADR-002） | — |
| opening | open_fail | absent | 分区打开失败；审计 | `collection_failed` |
| ready | probe_needs_login | needs_login | 触发 CAS 登录（D-10） | — |
| ready | probe_healthy | ready | 可采集 | — |
| needs_login | auth_ok | ready | CAS 登录状态机完成后回写 | auth_fail → `account_mismatch`/failed |
| （任意） | close_req | closing | 作业终态/维护释放卡槽 | — |
| closing | close_ok | absent | 关闭完成 | — |
| （任意） | quarantine_mark | quarantined | 持久标记（清理成功前跨重启禁复用） | — |
| quarantined | clear_ok | absent | 真删除分区（物理删除语义） | — |
| quarantined | clear_fail | quarantined | 标记保留、跨重启禁复用、报 UI | — |
| （启动） | 残留分区 | quarantined | 崩溃脏状态恢复：先隔离后清理 | — |

- 不变量：卡槽生命周期引擎独占（适配器不得私自 open/close）；清会话/重置遍历
  全部已安装通道（CT-C2-02 全集）；"清理=物理删除、探测=健康状态、隔离=持久标记"
  三语义三端一致（跨平台契约）。

### 5.4 D-09 导航就绪状态机（v2 分支教训的架构化兑现）

- 状态全集：`idle, navigating, dom_loaded, target_ready, timed_out, failed`
- 事件：`navigate_start, url_matched, dom_ready, ready_handshake, timeout, error`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| idle | navigate_start | navigating | P 导航（CT-P-01） | error → failed |
| navigating | url_matched | navigating | 记录 URL 匹配（就绪三条件之一） | — |
| navigating | dom_ready | dom_loaded | 记录 DOM 就绪（条件之二） | — |
| dom_loaded | ready_handshake | target_ready | 三条件齐（URL 匹配 + DOM 就绪 + 脚本握手）→ 可提取 | — |
| （任意非终态） | timeout | timed_out | 超时挂起 | — |
| timed_out | retry | navigating | 重新导航（有限重试，次数归 M2 参数） | — |
| timed_out | user_wait | timed_out | 转人工等待（人工完成后 retry） | — |
| timed_out | give_up | failed | 放弃：明确失败 | `collection_failed` |
| （任意非终态） | error | failed | 明确失败 | `collection_failed` |

- 不变量：**事件顺序乱序容忍**——晚到的 dom_ready/url 事件在已 target_ready 后
  忽略；就绪判定三条件缺一不可；ready 握手由登记提取脚本完成（ADR-019 修订）。

### 5.5 D-10 CAS 交互登录状态机（ADR-003）

- 状态全集：`initial, form_filled, submitted, verifying, waiting_user, authenticated, mismatched`
- 事件：`fill_ok, fill_fail, submit_ok, evidence_partial, evidence_complete,
  evidence_conflict, captcha_or_sms, manual_done`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| initial | fill_ok | form_filled | 白名单 origin 填表（username 来自租约 expectedUsername；密码 takePassword 后填） | — |
| initial | fill_fail | waiting_user | 按钮异常 → 静默回退人工 | — |
| form_filled | submit_ok | submitted | 提交登录 | — |
| submitted | evidence_partial | verifying | 三层核验收集（DOM 属性/performance/storage） | — |
| verifying | evidence_complete | authenticated | 三层齐 → 通过 | — |
| verifying | evidence_conflict | mismatched | 任一缺/冲突 → 明确失败 | `account_mismatch`（明确失败优于假装成功） |
| submitted | captcha_or_sms | waiting_user | 验证码/短信交人工（不自动化） | — |
| waiting_user | manual_done | authenticated | 人工完成后继续 | — |

- 不变量：填表仅白名单 origin；三层核验缺一即 `account_mismatch`；
  verifiedUsername 一经产生即作为终态载荷字段（CT-C1-01）。

### 5.6 D-11 CredentialLease 生命周期（CT-C2-03）

- 状态全集：`active, consumed, revoked`
- 事件：`take_password, revoke_req`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| active | take_password | consumed | 原子取即失效（首次返回秘密并置空） | 二次调用 → 返回 null |
| consumed | take_password | consumed | 返回 null（原子语义，幂等） | — |
| active | revoke_req | revoked | 幂等撤销；revoke 后 takePassword 恒 null | — |
| consumed | revoke_req | revoked | 幂等 | — |
| revoked | take_password | revoked | 返回 null | — |

- 不变量：takePassword/revoke 串行化（C2 单线程持有）；作业终态自动失效；
  删除凭据/completeReset 前先 revoke 全部未消费租约。

## 6. 待补组件清单与里程碑触发器（M3–M8）

| 组件 | 触发器 | 补设计时必须包含 |
|---|---|---|
| D-12/D-13 young 双适配器（M3） | M3 开工前 | 管道四工位状态机 + needs_user_login 恢复转移 + 封闭字段映射 |
| D-14 icourse 适配器 + 24h 缓存（M4） | M4 开工前 | 缓存状态机（fresh/stale/miss）+ 降级转移 |
| D-15 campus 刷新/详情/附件（M4） | M4 开工前 | 节流/过期/降级状态机 + 附件登记载荷生成点 + CT-C3-22 调用 |
| D-16 提醒协调器（M5） | M5 开工前 | reminders 五态转移 + 6 表 watch 重入保护 + 哨兵语义 |
| D-17 维护协调器 UI 编排（M5） | M5 开工前 | §4.3 reset 机的 UI 投影 + 双确认 + 维护门交互 |
| D-18 Agent 推理循环/审批门/预算（M6） | M6 开工前 | 8×12 预算转移 + 确认卡状态机 + 复合写 ledger |
| D-19 Python 租户生命周期（M2 并存期） | 并存期联调前 | 启动/健康/停止状态机 + 事件流转换 + M7 移除路径 |

## 7. 横切状态机交互一致性规则（可机械核对）

| 规则 | 涉及状态机 | 一致性要求 |
|---|---|---|
| R1 取消即递增 | D-05/D-06/D-07 | 取消接受时刻 bump(cancel) 先于 cancelled 终态；reset/clearBusinessData 内部取消不重复递增 |
| R2 迟到拒绝 | D-02/D-07 | 任何 C3 写事务内比对 stamp；过期 → stale_lease、零写入 |
| R3 维护互斥 | D-06/D-07/D-01 | maintenance 期间 free→held 禁止；迁移器运行期间无作业可启动（启动门） |
| R4 暂停语义 | D-05/D-07 | needs_user_login 期间 run 保持 running、租约保持、sequence 连续 |
| R5 租约释放 | D-06/D-11 | 作业任何终态释放全局租约与凭据租约（try/finally） |
| R6 provisional 边界 | 09 CT-C3-03/04 + D-06 | 先 acquire 后 stage；acquire 失败无 handle、不调销毁；stage 后任何失败出口调 cancel/discard |

## 8. 本层拍板记录（L4 决策）

| 编号 | 决策 | 内容 | 状态 |
|---|---|---|---|
| L4-01 | 本层范围 | M1/M2 关键状态机先设计（D-01~D-11、D-20/21）；M3–M8 登记待补，每块开工前补设计 | ✅ 已定 |

## 9. 第 4 层 gate 检查表

- [ ] ① 已设计状态机（D-01~D-11）各有：状态全集 + 转移表（次态/动作/失败态）+ 不变量
- [ ] ② 登记表（§3）每行有里程碑与设计状态；待补组件均有触发器（§6）
- [ ] ③ §7 六条横切规则在全部转移表中无违背（R1~R6 逐条过）
- [ ] ④ 转移表与 09 冻结契约一致（CT-C1-01 八相位、CT-C2-06 run 六值、CT-C2-03
      takePassword 原子、CT-C3-05 三值编码、CT-C3-21 四 reason）
- [ ] ⑤ 失败态全部映射 §2.4 稳定错误码（无新码；新码须回写 09）
- [ ] **gate 关闭条件**：独立审查通过 → M0/M1 按本文件施工（每做新组件先补设计）
