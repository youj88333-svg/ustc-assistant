# 10 运行时链路走查（六层阶梯 · 第 3 层）

> 产出日期：2026-08-14 ｜ 状态：**草稿（待审查）**
> ｜ 依据：`09-contracts.md`（CT-C0-01~CT-T-04 共 64 条冻结签名，L2-01~14）、
> `08-target-architecture.md` §7 五链路容器级走查、`07-constitution.md`
> （ADR-000~023 + 修订注）、01–06 模块文档（main 代码为准）

## 1. 本层目标与 gate

- 目标：把第 2 层冻结的 CT 签名**装配成可执行的运行时序列图**——三条主要 E2E
  （同步 / Agent 查询 / completeReset）+ 两条账号生命周期子链路（首次登录 / 账号
  维护）+ 五条数据链路（jw / young-schedule / young-enrolment / icourse / campus）
  的 fetch→normalize→validate→deliver 管道；**每条消息标注 CT 编号与关键参数，
  每个分支出口标注终态 / 稳定错误码 / 暂停态**。
- 与第 1 层的区别：08 §7 是"容器名能否走通"；本层是"CT 签名能否走通"——消息必须
  引用 09 中真实存在的契约，不得发明新接口（发现缺口即回写第 2 层）。
- **gate：① 五条链路 + 五条管道全部走通无死胡同（每个 await/事件/错误都有去向）；
  ② 每条数据链路 fetch→normalize→validate→deliver 四工位闭合；③ 并发/迟到/取消/
  崩溃四类边界情形逐条有去向（§9 扫描表）；④ 本层引用的每个 CT 编号在 09 §11
  矩阵中存在。**

## 2. 运行时基元（并发模型与作业生命周期）

### 2.1 执行模型

- 单 isolate 事件循环承载 C0–C5 纯 Dart 部分；平台会话/进程在 P（CT-P-01~08）。
- **C2 单线程持有**：全局来源作业租约（CT-C2-01）、凭据租约流转（CT-C2-03）——
  同一租约的 `takePassword()`/`revoke()` 串行化由 C2 单线程持有机械保证。
- 事件流唯一方向：C1 → C2 →（转播）→ C4/C5（CT-C1-01 `SourceJobHandle.events`）；
  事件内只含安全计数，凭据/原始数据永不进流。
- 时间：进程内一律 epoch ms（`BeijingClock`，CT-C0-01）；线协议 ISO 例外只存在于
  信封边界（SourceBundle/QueryResult 的 C1 产出与 C3 解码两处，09 §2.1）。

### 2.2 通用作业生命周期（同步类）

```
[C5/C4] ──submitSourceJob(spec)──► [C2]
  1. busy 预检（全局租约）─────────── 占用 → 抛 busy（CT-C2-01）
  2. SourceStateService.startSyncRun(stamp, trigger)（CT-C3-21；仅同步类）
  3. 通道路由（已安装全集上的当前映射，CT-C2-02）
  4. C1/Python startCollection(spec) → JobEventStream（CT-C1-02/CT-C1-01）
  5. 事件转播（sequence 连续）
  6. 终态接收：C2 校验 SourceJobHandle.stamp（CT-C0-03）
     ├─ 迟到 → stale_lease（不交接 C3/C4）
     └─ 正常 → 交接（见各链路）
  7. SourceStateService.finishSyncRun(runId, stamp, state, resultCode,
     importBatchId)（CT-C3-21；仅同步类）
```

### 2.3 租约戳组装与传播

- C2 组装：jobId/accountId/source/channelKind + `currentSourceGeneration`（CT-C3-21
  读取）+ `currentResetEpoch`（CT-C3-05 读取）；首登用 ProvisionalAuthContext 的
  预分配值（§6）。
- 传播纪律：`SourceJobHandle.stamp` 显式携带，任何 C3 写事务不得靠 jobId 反查或
  调用方上下文猜测（09 §2.3，L2-14）。

## 3. 主链路 ①：同步（手动/自动）序列图

参与者：C5（同步页/启动编排）、C2（SyncCoordinator + SourceJobGateway）、
C3（SourceStateService / ImportService）、C1（JobExecutor + 适配器）、P（WebView）。

```
C5                 C2                      C3                     C1/P
 │ sync(src,trig)   │                       │                      │
 ├─────────────────►│                       │                      │
 │  1. freshness/retryAfter 预检（CT-C2-07/08）                    │
 │     新鲜或退避窗口内 → fresh_or_backoff（skip，非错误）          │
 │  2. isBusy() 预检 → 占用则 busy（CT-C2-01）                     │
 │  3. startSyncRun(stamp, trigger)（CT-C3-21）→ 返回 runId（供 15c） │
 │                  ├──────────────────────►│ 写 sync_runs(running)│
 │  4. 通道路由 + 组装 spec（含无密码凭据租约：StoredAccountSubject → │
 │     expectedUsername；Jw/YoungSchedule CollectionRequest；         │
 │     spec.credentialLease 启动时只带 expectedUsername，09 §5.2）    │
 │                  ├── startCollection(spec)（CT-C1-02）──►        │
 │                  │◄── JobEvent 流（CT-C1-01）──┤                 │
 │  5. 转播事件（starting→checking_session→…）                      │
 │     checking_session 期间：probeSession → 会话健康（CT-P-02）    │
 │  ┌─ 分支 A：会话过期 ────────────────────────────────────────┐  │
 │  │ 6a. needsUserLogin（暂停态，流不断、租约保持）            │  │
 │  │ 7a. C5 弹确认卡 → 用户确认                                  │  │
 │  │ 8a. C2 resumeInteractive(jobId)（CT-C2-01）                 │  │
 │  │ 9a. C2 向 C3 requestCredentialLease(StoredAccountSubject,   │  │
 │  │     includePassword: true)（CT-C2-03）                      │  │
 │  │10a. resumeLogin(jobId, lease) → C1 takePassword() 取即失效  │  │
 │  │11a. 同一作业、同一流、sequence 连续（ADR-005）              │  │
 │  └────────────────────────────────────────────────────────────┘  │
 │  ┌─ 分支 B：用户取消 ──► cancel(jobId) 协作式 → cancelled 终态   │
 │  └─ 分支 C：正常完成 ────────────────────────────────────────┐  │
 │    12c. CollectionCompleted{bundleBytes, verifiedUsername?}     │
 │    13c. C2 校验 handle.stamp 仍属当前 generation/resetEpoch     │
 │         迟到 → stale_lease（不交接）                            │
 │    14c. C2 → C3 importBundle(bytes, stamp)（CT-C3-02）          │
 │                  ├──────────────────────►│ 事务内复验 stamp     │
 │                  │                       │ 解码→语义校验(9 码)   │
 │                  │                       │ →幂等→单事务落库     │
 │                  │                       │ →ImportResult{        │
 │                  │◄──────────────────────┤   status,            │
 │    15c. finishSyncRun(runId, stamp, success, 'imported',        │
 │         importBatchId)（CT-C3-21）                              │
 │                  ├──────────────────────►│ 写 sync_runs(success)│
 │    16c. 提醒协调（事务外；失败 → reminderReconciliationPending）│
 │  └────────────────────────────────────────────────────────────┘  │
 │ 17. 终态事件 → C5 页面 drift 流自动刷新                          │
```

死胡同核对（本链路）：busy/fresh_or_backoff/reauthentication_required（凭据缺失）/
cancelled/collection_failed/stale_lease 全部有稳定出口；`sync_runs` 终态六值
（CT-C2-06）中 `needs_user_action` 用于记录"暂停待确认"审计。

## 4. 主链路 ②：Agent 查询序列图（外部 + campus + 本地）

```
C4(工具)          C2                        C3                    C1/P
 │ submitSourceJob(QueryRequest 联合体)                              │
 ├───────────────►│ 1. busy 预检（全局租约；同步进行中 → busy）      │
 │                │ 2. 通道路由 + 组装 spec（CT-C1-02）              │
 │                ├── runQuery(spec) ──────────────────────►         │
 │                │◄── JobEvent 流 ───┤                              │
 │ 3. 转播（SourceJobHandle{stamp, events, cancel, resume}）         │
 │  ┌─ young_enrolment 需要登录态 ─────────────────────────────┐    │
 │  │ 4a. needsUserLogin → C4 转确认卡 → resume → 凭据租约      │    │
 │  │     （仅 young_enrolment 可接受凭据；icourse/campus 从不） │    │
 │  └───────────────────────────────────────────────────────────┘   │
 │ 4b. QueryCompleted{result, verifiedUsername?}                    │
 │ 5b. C2 校验 handle.stamp → 迟到 stale_lease（不进对话）          │
 │ 6b. C2 → C4 交接经安全校验的 QueryResult（CT-C1-04 封闭字段集）  │
 │ 7b. C4：信封校验 → OutboundPrivacyFilter 净化 → 入对话           │
 │                                                                  │
 │ campus 目录分支（campus_search 工具）：                           │
 │ 8. C4 → C3 目录服务判 freshness（CT-C2-08：30min/6h）            │
 │  ├─ 无需刷新 → C3 本地搜索 → 入对话                              │
 │  └─ 需刷新 → 9. C4 → C2 submitSourceJob(CampusSearchQueryRequest) │
 │       10. C1/P 抓取规范化 → C2 按 stamp 校验交还 C4               │
 │       11. C4 → C3 commitCatalogSource(stamp, result,             │
 │           attachmentRegistrations)（09 §7.5）                     │
 │       12. C3 事务内复验 stamp → upsert entries/state/attachment_cache│
 │       13. C3 本地搜索 → 入对话                                    │
 │  刷新失败且目录缺失 → catalog_unavailable（明确报错，不带部分数据）│
 │ campus_detail 工具：同外部查询路径（C4 → C2 → C1/P 详情读取 →       │
 │   封闭信封 → C4 入对话）；附件命中缓存经 C3 索引（CT-C3-20 缓存读方）│
 │   定位 P 文件；详情刷新亦经 commitCatalogSource 登记（含附件登记载荷）│
 │                                                                  │
 │ 本地读写（C4 工具 → C3 服务）：                                   │
 │ 14. 读：AgentLocalDataGateway（CT-C4-04）→ C3 六子域服务         │
 │ 15. 写：proposeWrite(view, expectedResetEpoch)（CT-C4-05）       │
 │     → 审批门（CT-C3-18 永久语义）→ resolveAndCommit(...,         │
 │     expectedResetEpoch) → 事务内比对 reset_epoch → 业务+审计     │
 │     +确认日志同事务；过期 → stale_lease                          │
```

死胡同核对：busy / stale_lease / result_validation_failed / query_failed /
catalog_unavailable / needs_user_login（恢复或取消）全部有出口；C4 不直连 C1
（全部经 C2）。

## 5. 主链路 ③：completeReset 序列图（durable finalization + 启动恢复）

```
C5(协调器)      C2                        C3                    C4
 │ 0. 清单预览 + 双确认（CT-C5-01）                                │
 │ 1. C3 beginReset()（CT-C3-05）：reset_pending=1、resetEpoch++、│
 │    ├───────────────────────────►│ 写屏障（除 finalization 拒绝新写）│
 │ 2. C2 拒新来源作业；cancelAll；等待全部 Native/Python 作业终态    │
 │ 3. C2 经 SourceStateService 以 reset 原因逐来源 bumpGeneration   │
 │    （CT-C3-21；SourceGenerationReason.reset）                    │
 │ 4. C4 拒新 run/工具/审批；取消模型流/工具/确认；等待写终态        │
 │ 5. C2 按已安装通道全集幂等 clearSession（CT-C2-02 全集语义）     │
 │    ├─ Native：C1/P WebView 分区真删除（CT-P-02）                 │
 │    └─ Python：P 租户适配器 profile 清理（CT-T-02）               │
 │ 6. C3 finalizeReset()（CT-C3-05）：单事务删 action_logs+undo_slot│
 │    +local_accounts（其余 FK CASCADE）→ 清 reset_pending → 广播空账号│
 │ 7. C5 回 /sync 首登态；C2/C4 于空账号态重新开放                  │
 │                                                                  │
 │ 失败分支（08 §7.3 表 + reset_pending 三值编码 0/1/2）：           │
 │   beginReset 失败 → 原状（0）                                    │
 │   C2/C4 取消失败 → 保持 pending（1）+ 写屏障，可重试             │
 │   会话清理失败 → 保持 pending（1），不得绕过后删库               │
 │   清会话后删库失败 → 事务回滚 + reset_pending=2（                │
 │     incomplete_session_cleared）；下次启动继续 finalization      │
 │   finalizeReset 重复执行 → 幂等                                  │
 │                                                                  │
 │ 启动恢复（CT-C5-02 强制门）：                                    │
 │   C5 启动 → resetState()（三值编码映射）→ 非 0 即先于正常路由/    │
 │   自动同步/Agent 恢复重置；恢复失败保持写屏障 + 专用恢复界面      │
```

死胡同核对：每个失败分支都以"可重试的持久状态 + 明确下一步"结尾；所有完成事件/
导入/Agent 写携带 resetEpoch，过期即拒（stale_lease）——删除后不重建数据。

## 6. 子链路 ④：首次登录序列图（commitFirstLogin 单事务）

```
C5(表单)        C2                     C3                     C1/P
 │ firstLoginSync(FirstLoginRequest{username,password,savePassword}) │
 ├──────────────►│ 1. stageFirstLogin(...)（CT-C3-03）              │
 │               ├──────────────────────►│ 仅内存：预分配            │
 │               │◄──────────────────────┤ prospectiveAccountId、    │
 │               │  ProvisionalAuthContext{handle, prospectiveAccountId,│
 │               │  expectedUsername, initialSourceGeneration=0,    │
 │               │  initialResetEpoch=0}；不插任何行、不落盘不落日志 │
 │ 2. C2 busy 预检（全局来源作业租约，CT-C2-01）→ 以 ProvisionalSubject│
 │    申请租约（includePassword:false，CT-C2-03）→ 组装 LeaseStamp    │
 │    （prospectiveAccountId, gen=0, epoch=0）                        │
 │ 3. startCollection(spec)（CAS 交互登录 D03，CT-C1-02；spec.semester=null │
 │    ——首登无持久选择：登录后抓学期列表 + 月份规则默认，ADR-009）         │
 │  ┌─ needs_user_login → C5 确认 → 同一 ProvisionalSubject 重申请  │
 │  │   含密码租约 → resumeLogin → C1 takePassword() 取即失效       │
 │  └─ 成功：CollectionCompleted{bundleBytes, verifiedUsername}     │
 │ 4. C2 校验 stamp + verifiedUsername                              │
 │ 5. C3 commitFirstLogin(handle, bundleBytes, verifiedUsername,    │
 │    identityDigest, stamp)（CT-C3-03）                             │
 │               ├──────────────────────►│ 单事务：                  │
 │               │                       │  ① handle 校验 stamp      │
 │               │                       │     (accountId==预分配、  │
 │               │                       │      jobId/gen/epoch 一致)│
 │               │                       │  ② 解码校验（9 错误码）   │
 │               │                       │  ③ 创建预分配 accountId  │
 │               │                       │  ④ 建 source_configs     │
 │               │                       │     （当前 generation）   │
 │               │                       │  ⑤ 私有事务内导入核心    │
 │               │                       │  ⑥ 凭据密文 + identityDigest│
 │               │                       │  ⑦ 置活动 + 审计 +       │
 │               │                       │     记 first_login 终态  │
 │               │                       │     （CT-C3-21 私有实现） │
 │ 6. 广播 activeAccountChanged → C5 进主界面                        │
 │                                                                  │
 │ 失败路径：任一守卫失败（stale_lease/身份错误）或事务回滚 →        │
 │   cancelFirstLogin(handle)（CT-C3-03）→ 无活动账号、无凭据行、    │
 │   无来源业务数据；handle 一次性消费，临时明文尽力零化             │
```

死胡同核对：首登不写 sync_runs（账号行存在前无 run 行；first_login 终态在
commitFirstLogin 事务内补记，CT-C3-21）；provisional 上下文不落任何持久介质。

## 7. 子链路 ⑤：账号维护序列图（四种操作）

### 7.1 重新认证（identityDigest 不可变）

```
C5 → C2 reauthenticate(ReauthRequest{accountId,username,password,savePassword})
  → C3 stageReauthentication(...)（CT-C3-04）
      ① 校验输入 username 的 digest == 现有 identityDigest（不符即拒绝）
      ② 返回 ProvisionalAuthContext（prospectiveAccountId=既有 accountId，
         initialGeneration/ResetEpoch=当前库值快照）
  → C2 以 ProvisionalSubject 申请租约 → 启动统一来源作业（CAS）
    （同步账本按 trigger=reauthentication 走 §2.2 通用生命周期：
     startSyncRun/finishSyncRun，CT-C3-21）
  → 完成返回 verifiedUsername + 原 LeaseStamp
  → C3 commitReauthentication(accountId, verifiedUsername, handle, stamp)（CT-C3-04）
      ① 事务内复验 stamp 的 accountId/jobId/sourceGeneration/resetEpoch 与当前库值
      ② 再次校验 digest == 原 identityDigest
      匹配 → 仅更新凭据密文与元数据；identityDigest 保持不变
      不匹配 → identity_mismatch；库内身份/凭据/业务数据不变
              C2 持久 quarantine 本次会话分区 → 清除（CT-P-02）
              清除失败 → 标记跨重启保留、禁复用、报 UI
```

### 7.2 删除凭据（先撤销租约）

```
C5 确认 → AccountMaintenanceCoordinator
  → C2 beginMaintenance(deleteCredentials)（CT-C2-04）
      ① revoke 全部未消费凭据租约（CT-C2-03）
      ② 取消并等待可能消费凭据的作业终态
  → C3 deleteCredentials（删密文；保留账号与浏览器会话）
  → C2 endMaintenance
```

### 7.3 清会话（全通道幂等）

```
C5 确认 → C2 beginMaintenance(clearSession)
      ① 停止该账号全部来源作业
      ② 遍历【已安装通道全集】（CT-C2-02）：每通道 clearSession(accountId) 幂等
         Native 经 C1/P；Python 经 P 租户适配器（CT-T-02）
      ③ 任一失败 → 该通道分区保持隔离状态、重试；不因路由切换遗漏已注销通道
  → endMaintenance
```

### 7.4 清业务数据（维护写屏障 + generation 递增）

```
C5 确认 → AccountMaintenanceCoordinator
  → C3 beginBusinessDataClear()（CT-C3-06）：拒新业务写 + 等待已进入写事务终态
  → C2 beginMaintenance(clearBusinessData)：拒新来源作业、取消并等待旧作业；
    经 SourceStateService 以 clearBusinessData 原因逐来源 bumpGeneration（CT-C3-21）
  → C4 拒新 run/工具/审批并等待所有可写执行终态
  → C3 commitBusinessDataClear()：单事务清 15 张业务表 + undo_slot（保留
    账号/凭据/设置/权限策略/Agent 历史/审计；campus 三表归 clearCache）
  → 解除屏障与维护门（任何取消/等待失败 → abortBusinessDataClear，不开始清理）
```

## 8. 五条数据链路管道（fetch→normalize→validate→deliver）

每条链路四工位闭合核对：工位缺一个即死胡同。产物与消费者按 09 §5.3/§5.4/§7.3。

### 8.1 jw（WebView 交互 + SourceBundle）

```
fetch:   probeSession →（过期）CAS 可见登录（白名单填表/三层核验/验证码交人工）
         → 登录后抓学期列表（ADR-009）→ 选中学期 → 课程页 + 考试页
normalize: DOM/接口解析 → 规范化 datum（course_series / calendar_events /
         schedule_relations 外部身份）
validate: SourceBundle 构造 + validate（16MB/深度 64/敏感键 11 类/时间 +08:00/
         计数/引用完整性）——9 个错误码（CT-C1-03）
deliver:  CollectionCompleted{bundleBytes} → C2 stamp 校验 → C3 importBundle
异常出口: needs_user_login（恢复/取消）| account_mismatch（三层核验缺一）
         | collection_failed | stale_lease | 9 个 bundle 错误码
```

### 8.2 young-schedule（WebView 登录态 + SourceBundle）

```
fetch:   probeSession →（过期）needs_user_login 暂停-恢复
         → 北京时间滚动窗口逐日切片查询（窗口由 C2 按 BeijingClock 计算，
         YoungScheduleCollectionRequest.queryDates）
normalize: 已报名日程记录 → calendar_events（second_class 外部身份）
validate: SourceBundle（scope=日期窗口完整性；空日=有效空快照）
deliver:  同 8.1 → importBundle
异常出口: needs_user_login | collection_failed | stale_lease | 空快照（合法）
```

### 8.3 young-enrolment（WebView 查询侧 + QueryResult）

```
fetch:    runQuery(YoungEnrolmentQueryRequest) → 报名中活动列表（分页采集）
normalize: NORMALIZED_FIELDS → YoungActivity 封闭字段集（CT-C1-04）
         descriptionText/requirementsText 有界纯文本转换；imagePath/私有字段丢弃
validate: QueryResult 1.0 canonical 校验（封闭集 fail-closed；references 白名单）
deliver:  QueryCompleted{result} → C2 → C4 工具（不入库、不落 C3）
异常出口: needs_user_login（唯一可接受凭据的查询类型）| query_failed
         | result_validation_failed | stale_lease
```

### 8.4 icourse（HTTP 公开 + QueryResult）

```
fetch:    HttpSourceClient 搜索公开页（课程/教师关键词，24h 磁盘缓存 TTL，
         网络失败降级 stale 缓存）
normalize: 排名 + 关系强度（relationStrength）+ 代表性证据
         selectedEvidence→evidence；**reviews 不进 canonical**（CT-C1-04，L2-14）
validate: canonical 校验（封闭集；siteAiSummary 只留 text；teacherLinks 只留 label）
deliver:  QueryCompleted → C4 工具（评课联动只发送必需检索词，红线 2.1-2）
异常出口: query_failed | result_validation_failed | stale_lease | stale 缓存降级
```

### 8.5 campus（HTTP 公开 + QueryResult + 目录 upsert）

```
fetch:    目录刷新（五个目录键、分页、7 天窗口过滤；30min 节流/6h 过期/失败降级
         旧目录）｜ 详情读取（content + 附件受控下载：大小/MIME 白名单，批≤3、
         链接≤1 层）｜ 附件内容转换（CT-C1-05；文件/decoder 在 P）
normalize: CatalogEntry 封闭字段集（id 精确算法 = 'campus_'+sha256 前 24 位，
          09 §7.2；canonicalize_url 规则）；campus_detail 封闭集；附件登记载荷
validate: canonical 校验（URL ∈ references；raw HTML 拒绝；无 localPath/sha256）
deliver:  campus_search → C4 → C3 commitCatalogSource（stamp + 登记载荷）
          → upsert → 本地搜索入对话
          campus_detail → C4 入对话（附件命中缓存走 CT-C3-20 索引）
异常出口: catalog_unavailable（目录缺失且刷新失败）| result_validation_failed
         | stale_lease | 降级旧目录（合法）
```

## 9. 边界情形与死胡同扫描（每行"去向"非空即无死胡同）

| # | 情形 | 触发 | 去向 |
|---|---|---|---|
| 1 | 同步中再触发同步/查询 | 全局租约占用 | `busy`（CT-C2-01）；UI 呈现"同步进行中" |
| 2 | 暂停态挂起时用户关 App | needs_user_login + 进程退出 | 跨重启作废（ADR-022）；UI 提示"上次待确认操作已失效" |
| 3 | 通道切换后旧作业迟到 | generation 已递增 | C2/C3 校验失败 → `stale_lease`，不导入/不更新目录/不进对话 |
| 4 | reset 后 Agent 迟到写 | resetEpoch 已递增 | 写屏障 + expectedResetEpoch 比对 → `stale_lease` |
| 5 | 作业取消（暂停态） | cancel(jobId) | 立即终态 `cancelled`（CT-C1-02） |
| 6 | 作业取消（采集中） | 协作式检查点 | 最近检查点终态 `cancelled` |
| 7 | App 崩溃残留 running | 下次启动 | `recoverInterruptedRuns` → `interrupted/app_restarted`（CT-C3-21） |
| 8 | reset 中途崩溃 | reset_pending=1/2 | 启动强制门恢复；=2 继续 finalization（CT-C5-02） |
| 9 | 身份核验失败分区 | digest 不匹配 | 持久 quarantine → 清除；失败跨重启禁复用（CT-P-02） |
| 10 | 维护门期间新请求 | beginMaintenance 后 | C2/C4 拒绝新作业/run/写；等门释放 |
| 11 | 删除凭据时有未消费租约 | 用户点删除 | 先 revoke + 终止作业，再删密文（§7.2） |
| 12 | 凭据租约二次取值 | takePassword 后 | 返回 null（原子取即失效，CT-C2-03） |
| 13 | 提醒协调失败 | 事务外协调 | `reminderReconciliationPending`，后续触发重协调 |
| 14 | 目录刷新失败且无旧目录 | 离线首次使用 | `catalog_unavailable`，联网后重试 |
| 15 | 学期列表抓取失败/缺失 | 新学期待发布 | fallback 细节归第 4 层/M2（ADR-009） |
| 16 | Python 通道进程退出 | 租户健康探测 | C2 经 CT-P-07 重启或标 failed（并存期） |

## 10. 开放问题移交（本层不解决，标注承接层）

| 开放问题 | 来源 | 承接层 |
|---|---|---|
| 作业级错误 transient/fatal 分类与有限重试 | 08 §10 | 第 4 层（作业状态机） |
| syncAll 遇 needs_user_login 的恢复语义形态（逐源挂起 vs 整批挂起） | 08 §10 | 第 4 层 |
| 五适配器 normalize 段逐字段实现规则（封闭集已冻结，解析细节） | 09 §5.4 | M2–M4 |
| 学期 fallback 策略（列表缺失/未发布/持久化选择） | ADR-009 | M2 |
| PythonChannel 转换映射的完备性验证（legacy 键全量覆盖） | 09 §5.4 | M2–M4 oracle 对拍 |

## 11. 本层拍板记录（L3 决策）

本层为纯走查层，预期无新决策；若走查暴露契约缺口，按规则回写第 2 层并在此登记。

| 编号 | 决策 | 内容 | 状态 |
|---|---|---|---|
| L3-01 | 走查回写 09 §5.2 | `JwCollectionRequest.semester` 由非空改 **nullable**：null=首登无持久选择（登录后抓列表+月份规则默认，ADR-009），非 null=持久选择（自审发现首登组装不出 spec） | ✅ 已回写 |

## 12. 第 3 层 gate 检查表

- [ ] ① 五条链路（§3/§4/§5/§6/§7）序列图走通，每条消息标注 CT 编号、每分支有去向
- [ ] ② 五条数据管道（§8）fetch→normalize→validate→deliver 四工位闭合
- [ ] ③ §9 边界情形 16 行去向非空；无死胡同
- [ ] ④ 本层引用的 CT 编号（CT-C0-01/03、CT-C1-01~05、CT-C2-01~08、CT-C3-02~06/
      18/20/21、CT-C4-04/05、CT-C5-01/02、CT-P-02/07、CT-T-02）全部在 09 §11
      矩阵中存在
- [ ] ⑤ ADR-000~023 与 L2-14 决策在本层消息中全部可溯源（租约戳传播/原子取凭据/
      single-transaction 首登/三值 reset/全通道清会话/封闭 QueryResult）
- [ ] ⑥ 与 08 §7 容器级走查一致（无容器越权调用：C4 不直连 C1、C1 不依赖 C3、
      写库唯一 C3、C2 核心无 dart:io）
- [ ] 开放问题移交（§10）逐项有承接层
- [ ] **gate 关闭条件**：独立审查通过 → 进入第 4 层 `11-component-designs.md`
