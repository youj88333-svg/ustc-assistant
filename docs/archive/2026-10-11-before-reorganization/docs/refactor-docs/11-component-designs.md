# 11 本分支关键组件与状态机

## 本分支当前规则

2026-10-09 按 [09](09-contracts.md)和[10](10-runtime.md)修订。此处先定义此次审核涉及的关键状态机；完整数据与工具组件在相关设计时继续补齐，不继承旧“状态机全集已关闭”的结论。未列出的输入稳定拒绝或丢弃且保持安全状态，不由来源文本构造日志。

### 身份核验

每个认证来源有自己的 verifier 和有效契约版本。状态为 pending、matchesExpected、unverified、evidenceConflict、wrongAccount；后四种是本次核验终态。输入必须关联当前作业、会话实例和主文档；旧文档、未知契约或缺少可信依据只产生 unverified。

matchesExpected 才继续采集；unverified 与 evidenceConflict 终止交付并关闭当前句柄、保留正式分区；wrongAccount 持久隔离并清理。核验不读取 Storage 或认证资产，客户端自报或 URL 参数不能把 pending 转为 matchesExpected。后续文档变化使未封存的匹配判定失效；再次提取或敏感动作必须满足当前上下文守卫。C1 在活文档中完成核验和数据检查后，封存绑定身份判定、数据、来源契约、分区及原作业的不可变内部产物，随后只收口；正常关闭不废除已封存产物。C3 提交仍复验原账号、generation、epoch、维护状态与完整性，取消或维护可以拒绝未提交产物。

教务 C1 在原始行数及每一行检查通过后，按稳定自然键合并全部规范化事件字段完全一致的行；重复行也必须完成字段检查，任何同键不同内容使整次采集拒绝。封存携带不可变的来源行数、唯一事件数及合并数，既有投影上限在合并前执行。C2 在收口与认领重试中保留本次安全计数，新作业或清会话清除旧计数；计数不构成提交证明。C5 以事务回执展示实际日程数量，并说明重复项合并数量，失败时继续展示零提交及固定拒绝原因。

### 分区归属与回收

P 的分区登记在创建资产之前提交，包含 purpose=initial/recovery、attempt、partition、owner 和 resetEpoch，登记状态与浏览器运行状态分开。归属状态为 provisional、claimed、deletePending、removed；运行状态为 closed、opening、open、draining、drainFailed。隔离或 deletePending 禁止打开和复用，恢复候选创建前先完成既有待删除清理。C3 核验成功的首登/重认证事务持久提交绑定具体 partition、attempt、owner、resetEpoch 的认领许可，P 只凭有效许可认领；账号存在不能替代许可。

| 当前归属 | 事件 | 次态与动作 |
|---|---|---|
| 无可用正式分区 | 首登创建/既有账号受控重建 | 原子登记 initial/recovery 候选后才创建资产；登记失败不创建分区 |
| provisional | C3 已提交有效认领许可且绑定匹配 | claim → claimed；重复认领幂等 |
| provisional | 提交前取消/失败/回滚 | markDeletePending → 关闭并排空 → 真删除 → removed；恢复候选失败保留既有账号、业务及旧凭据 |
| provisional | 启动调和发现有效已提交许可 | 按具体 partition/attempt/owner/resetEpoch 幂等 claim；失败保持恢复页 |
| provisional | 启动发现无有效许可 | deletePending；排空清理，失败保留待办；不得仅凭已有账号认领 |
| claimed | 启动调和发现匹配且未撤销、属于当前 resetEpoch 的具体许可 | 保持 claimed；后续作业仍重新核验来源身份 |
| claimed | 启动发现许可缺失、撤销或不匹配 | 持久隔离/标记 deletePending → 排空 → 真清理；完成前不恢复正常启动，覆盖 C3 已撤销但 P 尚未标记删除便退出的窗口 |
| claimed | 无法核验/证据冲突 | 保持 claimed；仅关闭当前句柄，下次重新核验 |
| claimed | 确证串号/用户清会话/reset | 先隔离或 deletePending，撤销对应认领许可，再排空并真清理 |
| deletePending | 清理失败/进程退出 | 保持持久禁复用状态，启动或用户重试 |
| deletePending | 资源已释放且真删除成功 | removed；移除对应登记，重复清理幂等 |

运行态 open → draining → closed 必须确认资源释放；失败转 drainFailed 并允许重试 draining。关闭成功不删除归属；删除不能绕过资源排空。启动调和检查全部登记分区，不能凭 P 的 claimed 标志或账号存在复用。登记损坏或无法验证归属的孤立分区禁止认领和复用，必须先由本应用受控目录调和；正常登记的 provisional 可以凭 C3 已提交有效许可直接认领。不得清理其他 worktree 或系统浏览器目录。

### 导航就绪与受控动作

一次等待持有 jobId、sessionInstance、DocumentToken、OperationToken 及预期 origin/业务目标。初始 readyBits=000；只接受与当前主文档和操作关联的 URL、DOM、握手事件，乱序幂等置位，三位齐全才 targetReady。

| 事件 | 动作 |
|---|---|
| 当前操作、文档的就绪事件 | 置对应位；已置位保持；校验实际目标 |
| 旧文档、旧操作或未授权 frame 的事件 | 丢弃，不能置位 |
| 新主文档开始/会话替换 | 旧 token 失效；按新文档创建等待并清零，不拼接前文档状态 |
| 同次导航重定向 | 校验每个目标；拒绝越界，保持平台导航关联 |
| 同文档业务路由变化 | 旧业务等待失效，重新核对 origin 与目标后建立新操作 |
| 重试 | 使旧 OperationToken 失效，建立新等待并清零；旧握手不能满足新操作 |
| 取消/关闭/超时终止 | token 失效，撤销动作；后续回调不能恢复 ready |
| fill/click/extract | 执行前验证当前文档、origin、操作；返回时复验，切文档即丢弃 |

targetReady 只完成本次等待，不能对之后的导航保持永久就绪。秘密投递必须由 P 保证目标文档关联；能力不足时由用户手填，不以不完整守卫尝试自动填入。

浏览器装配按 07 DR-ADR-09 保留导航/frame、弹窗、下载、权限申请和外部协议控制，不主动注入 CAL 或安装全协议防护扩展，不一律禁 Worker，也不替换 WebRTC；页面既有安全策略保持。正常后台网络活动不改变 readyBits、身份判定或作业状态，全协议漏拦也不单独触发来源 unavailable。已登记的保留控制若失效仍按稳定失败处理，不以接受后台网络为由放宽它们。

实际渲染进程故障立即使所属 DocumentToken/OperationToken 失效，丢弃未完成提取并进入收口；C2 按已提交/未提交事实分别处理，资源释放失败保持 recovery。此项是普通产品故障出口，验收不要求主动运行 CAL 崩溃套件或先取得补丁运行时。

### 来源作业与全局租约

C2 状态为 idle、active、pausedForUser、settling、recovery、maintenance；C1 的来源 complete/failed/cancelled 与该状态分开。idle 同步取得租约后进入 active；等待用户进入 pausedForUser 并保持同一持有者，受理恢复后回 active，登录后返回原业务目标。

来源终态进入 settling：封存产物可见、C1 收口和 C3 导入/交付各有独立完成结果。必要收口与交接均完成后才 idle；收口失败进入 recovery，保持拒新作业，重试成功才释放。重复恢复串行幂等；重复取消不重复启动作业。取消与提交由 C3 事务先后裁决：取消先受理则原戳失效、未提交产物拒绝；提交先发生则保留 committed 和有效认领许可，只停止可停止的后续动作，必要认领、收口与恢复继续。维护先拒新请求，再排空已进入执行；旧 owner 的迟到回调不能清掉新 owner 状态。C2 向 C5 分别报告提交事实和后续待办，按 10 的结果表展示，重试待办不重新导入。

首登 staged 上下文与 P 分区是两种资产：上下文内存销毁不表示分区已删除；账号提交成功而分区认领失败只能按许可恢复认领，不回滚已提交账号。必要凭据密文和保护元数据随首登/重认证 SQL 事务存储，P 负责保护及按需解密；失败不替换旧凭据，用户手填不反读秘密。已确认 reset 的持久意图不因普通作业句柄失效而丢弃。同应用数据目录的 P 排他所有权由 C5 在开库、迁移和调和前取得，第二实例只激活或退出；C2 单作业租约不能代替进程排他。

提醒以 C3 持久业务和期望提醒为事实，平台协调在事务外执行并保留失败待办；启动按事实对账。维护停止调度、处理在途发布及已登记通知后才完成，不承诺未经证明的 exactly-once，具体能力按 V-08 验证。单独清 Agent 历史在 C3/C4 入口拒新相关运行，作废并排空旧流、摘要、查询和确认；迟到写与新增请求复验会话世代及授权。清业务后保留的历史不能继续使用旧批准或业务引用，完整工具状态在 V-06 对应设计补齐。

### 共享学校认证驱动与 Young 准备（2026-10-11）

`SchoolAuthenticationDriver` 由每个作业持有，只编排固定状态，不保存密码；JW/Young 各自提供受控认证端口、当前戳复验和凭据租约。表单准备、单次投递、等待提交、人工挑战接续分别记录，模糊或迟到确认不重发密码。C3 共享凭据事实但票据与撤销范围按来源/作业校验；取消立即撤销未消费租约，成功提交才更新持久密码。

Young 准备态等待固定业务文档、SPA 路径和 helper，期间未开始业务请求；变更后的文档重新准备。转为读取后采用严格的主 frame、loader、默认 context、编译脚本和请求步骤关联，路由或 context 变化拒绝交付。Windows 在认证与读取器交接时先停止认证 Runtime 监听并等待 `Runtime.disable` 完成，再创建读取器并启用 Runtime，避免重复 enable 不重报已有 context。Page 主 frame 监听注册且 `Page.enable` 确认后即按当前文档处理路由，覆盖读取器尚在准备的阶段；这不改变文档/主路由失效语义。具体反例、运行时范围和验证见 [15](15-construction-methodology.md#m23-真实失败与自动认证接续2026-10-11)。

### 来源观察与有效日程投影

完整快照只更新来源事实与观察元数据：范围内返回 → observed；范围外 → outside_scope；范围内未返回 → missing_within_scope。不完整快照不进入事务；学校明确撤回记录为来源事实及待用户确认标记。

投影在原有日期范围内保留所有未被用户隐藏的已知学校记录，不以 missing_within_scope 或未确认的来源撤回作为排除条件，也不将这些状态写成用户 hidden/cancelled。来源标记只改变说明和新鲜度；提醒与冲突读取同一有效记录，原规则继续有效。用户确认隐藏后由本地事务更新覆盖及提醒；再次出现复用本地身份、清除来源缺失标记并保留覆盖。

时间范围之外自然不显示在当前周，不代表记录被隐藏。显式冲突关系与用户决定优先于时间重叠；来源刷新不能覆盖这些本地决定。

### 数据迁移与恢复

状态顺序为 inventory → copyReady → validating → publishing → completed；失败进入 recovery。inventory 允许对经用户授权的实际资产只读清点格式、版本和必要元数据，不写原件；清单和目标映射不完整不得进入转换，没有一致受控副本也不得转换。完整性、关系、覆盖和业务语义验收通过才发布目标；转换与验收只操作受控副本，原件保留并可回退。不沿用旧“唯一 v7→v8”状态机。具体版本识别、目标 Schema 和发布机制在真实资产清单确认后补齐。

## 历史设计资料

下文旧组件编号、转移表、投影和关闭记录完整保留。其 Storage 旁证、未定义文档关联的三位就绪接口、缺失过滤、旧收口表述、仅清 debug 的首登失败出口以及固定 v7/v8 迁移不作为当前实现依据。

# 11 组件设计（六层阶梯 · 第 4 层）

> 产出日期：2026-08-14 ｜ 状态：**第 4 层已关闭（2026-08-14 用户重认；2026-08-15 用户批准 L4-04 reset 状态机回写；2026-08-23 Task 17 回写 L4-06；2026-08-25/27 M2 真实验收回写 L4-07~09）**
> ｜ 依据：`09-contracts.md`（CT 65 条 + L2-01~26）、`10-runtime.md`（五链路走查）、
> `07-constitution.md`（ADR-000~023）、08 容器切分、01–06 模块文档
> ｜ 纪律（AGENTS.md 阶梯规则）：第 4 层**不必一次做完**——M1 后"每做一块组件、
> 先补一块设计"；本文件是组件设计的唯一登记处。

## 1. 本层目标与 gate

- 目标：逐容器内部组件设计。本层交付物 = **状态机转移表**（状态全集 + 转移 +
  失败态）——这是 AGENTS.md 对第 4 层的硬 gate。
- 已覆盖：M1/M2 已触发组件 D-01~D-11、D-19~D-26、D-29/D-30；其余里程碑
  组件登记待补（进入该里程碑前补设计，§6 触发器）。
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
| D-20 | 有效事件/冲突投影纯函数 | C3 | M1 | ✅ §4.6 |
| D-21 | 重复系列投影/生命周期 | C3 | M1 | ✅ §4.7 |
| D-22 | C1 JobGate（Native 卡槽资源闸） | C1 | M2 | ✅ §5.7（不含全局权威，L1-04） |
| D-23 | Native JW Adapter 管道 | C1 | M2 | ✅ §5.8（含运行时学期目录，ADR-009） |
| D-24 | SourceChannel 注册/切换 | C2 | M2 | ✅ §5.9（已安装全集/来源路由） |
| D-25 | SyncCoordinator（freshness/backoff） | C2 | M1/M2 | ✅ §5.10 |
| D-26 | provisional 生命周期（首登/重认证） | C3 | M1/M2/M5 | ✅ §5.11 |
| D-27 | clearBusinessData 写屏障 | C3 | M5 | ⬜ 待补（触发器：M5 开工前） |
| D-28 | C5 启动强制门/启动编排 | C5 | M5 | ⬜ 待补（触发器：M5 开工前；reset_pending 门 + 提醒/自动同步启动） |
| D-29 | 作业 transient/fatal 分类与有限重试 | C1/C2 | M2 | ✅ §5.12 |
| D-30 | syncAll 遇 needs_user_login 恢复语义 | C2 | M2 | ✅ §5.13 |
| D-12/D-13 | young 双适配器 | C1 | M3 | ✅ §5.15/§5.16（2026-09-09 M3 触发） |
| D-14 | icourse 适配器 + 24h 缓存 | C1 | M4 | ⬜ 待补（触发器：M4 开工前） |
| D-15 | campus 刷新/详情/附件管道 | C1/C3 | M4 | ⬜ 待补（触发器：M4 开工前） |
| D-16 | 提醒协调器 | C3/P | M5 | ⬜ 待补（触发器：M5 开工前） |
| D-17 | 维护协调器 UI 编排 | C5 | M5 | ⬜ 待补（触发器：M5 开工前） |
| D-18 | Agent 推理循环/审批门/预算 | C4 | M6 | ⬜ 待补（触发器：M6 开工前） |
| D-19 | Python 租户生命周期（并存期） | C2/P | M2 | ✅ §5.14 |

## 4. M1 组件状态机（存储核心）

### 4.1 D-01 v7→v8 迁移器（ADR-011/012；唯一搬家路径）

- 状态全集：`idle*, backing_up, migrating, verifying, committed†, rolled_back†, failed†`
- 事件：`start, backup_ok, backup_fail, migrate_ok, migrate_fail, verify_ok, verify_fail`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| idle | start | backing_up | 备份 v7 库副本到 P 私有目录（迁移前自动备份，红线 2.2-7）；先 `PRAGMA wal_checkpoint(FULL)` 再 SQLite 在线备份（备份 API / VACUUM INTO），禁止直接文件复制 | （保持 idle ｜ `migration_failed`） |
| backing_up | backup_ok | migrating | 备份校验：`PRAGMA integrity_check` + 关键表行数对比 + 可打开 | — |
| backing_up | backup_fail | failed | 不触碰主库；审计 `migration_backup_failed` | （failed ｜ `migration_failed`） |
| migrating | migrate_ok | verifying | Drift 迁移器执行（v8 七项变更，单事务语义）；schema/行数断言在迁移事务提交前同事务完成 | — |
| migrating | migrate_fail | rolled_back | 主库保持 v7（事务回滚）；审计 | （rolled_back ｜ `migration_failed`） |
| verifying | verify_ok | committed | schemaVersion=8；**实现/验收时必须通过四步迁移断言**（旧库建→插数据→迁移→校验） | — |
| verifying | verify_fail | rolled_back | 提交前校验失败 → 事务回滚主库保持 v7；若已提交后失败 → **从备份恢复主库 + 审计 + 专用恢复界面**（两条路径都记审计） | （rolled_back ｜ `migration_failed`） |

- 闭合规则：R-非法（保持+审计）/ R-终态（committed/rolled_back/failed 忽略后续事件，
  `committed × start` 只返回既有结果、不重放迁移动作）/R-重复（非终态重复完成信号按动作幂等）。
- 不变量：迁移全程主库独占（启动门：迁移未完成前禁止正常路由/自动同步/Agent）；
  任何失败不得留下半迁移状态。**备份副本保留与清理策略移交第 5 层数据保留策略
  （`12-cross-cutting.md`），本机不预设"自动过期"（B-3 整改）。**

### 4.2 D-02 ImportService 导入流水线（CT-C3-02；A-2 整改）

- 状态全集：`accepting*, decoding, validating, checking_subject, checking_idempotency,
  importing, reconciling, done†(imported|replayed), failed†`
- 事件：`bytes_received, decode_ok, decode_fail, semantics_ok, semantics_fail,
  subject_ok, subject_fail, replay_hit, idempotency_fail, proceed, tx_ok, tx_fail,
  reconcile_ok, reconcile_fail`

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
| checking_idempotency | idempotency_fail | failed | 同 bundleId 异 digest 等幂等冲突或幂等查询 DB 异常 → 明确失败 | （failed ｜ `duplicate_identity` / `sync_failed`） |
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

### 4.3 D-03 reset 协调状态机（CT-C3-05；A-3/A-10 整改 + L4-04 回写）

- 持久态（DB，跨重启）：`reset_pending ∈ {0=none, 1=pending, 2=incomplete_session_cleared}`
- 协调器运行态：`idle*, previewing, beginning, draining_c2, draining_c4,
  clearing_sessions, clearing_cache, clearing_debug, finalizing, done†,
  startup_recovering`
- 事件：`user_confirm_x2, begin, begin_ok, begin_fail, c2_drained, c2_drain_fail,
  c4_drained, c4_drain_fail, sessions_cleared, session_clear_fail, session_mark_fail, cache_cleared,
  cache_clear_fail, debug_cleared, debug_clear_fail, retry_finalize, tx_ok, tx_fail,
  startup_detected, startup_pending, startup_incomplete_session_cleared`

| 当前态 | 事件 | 次态 | 动作（持久效果） | 失败态 |
|---|---|---|---|---|
| idle | user_confirm_x2 | previewing | 清单预览（CT-C5-01） | — |
| previewing | user_cancel | idle | 用户取消预览：无持久效果，可重新发起 | — |
| previewing | begin | beginning | beginReset：pending=1、resetEpoch++、写屏障 | — |
| beginning | begin_fail | idle | beginReset 未提交，重置未开始、pending=0；UI 可重试 | （idle ｜ `write_commit_failed`） |
| beginning | begin_ok | draining_c2 | C2：revoke 租约→终止→cancelAll→等待→bump(reset) | — |
| draining_c2 | c2_drain_fail | draining_c2 | 保持 pending=1 + 写屏障，可重试 | （保持 ｜ `reset_incomplete`） |
| draining_c2 | c2_drained | draining_c4 | C4：拒新+取消+等待写终态 | — |
| draining_c4 | c4_drain_fail | draining_c4 | 保持 pending=1，可重试 | （保持 ｜ `reset_incomplete`） |
| draining_c4 | c4_drained | clearing_sessions | 全通道 clearSession（幂等） | — |
| clearing_sessions | session_clear_fail | clearing_sessions | 保持 pending=1，不得绕过后删库 | （保持 ｜ `reset_incomplete`） |
| clearing_sessions | sessions_cleared | clearing_cache | markResetSessionsCleared：持久 pending=2；调用 CT-C3-20 clearCache | — |
| clearing_sessions | session_mark_fail | clearing_sessions | 会话虽已清但 1→2 未提交；保持 pending=1，重试/启动时安全重放清会话 | （保持 ｜ `reset_incomplete`） |
| clearing_cache | cache_clear_fail | clearing_cache | 保持 pending=2 + 写屏障；不得开始 debug/finalization | （保持 ｜ `reset_incomplete`） |
| clearing_cache | cache_cleared | clearing_debug | 调用 CT-P-05 clearDebugAssets(accountId) | — |
| clearing_debug | debug_clear_fail | clearing_debug | 保持 pending=2 + 写屏障；不得 finalization | （保持 ｜ `reset_incomplete`） |
| clearing_debug | debug_cleared | finalizing | finalizeReset 单事务删+清标记 | — |
| finalizing | tx_fail | finalizing | 保持 pending=2；等待显式重试 | （保持 ｜ `reset_incomplete`） |
| finalizing | retry_finalize | finalizing | 幂等再次调用 finalizeReset | — |
| finalizing | tx_ok | done | 广播空账号；C5 回首登 | — |
| —（创建） | startup_detected | startup_recovering | resetState()≠0 强制门：先于路由/同步/Agent | — |
| startup_recovering | startup_pending | clearing_sessions | **重新幂等清会话（安全重放）**——pending=1 时清理阶段是否完成不可知，幂等重放清会话后才允许 finalize | （保持 ｜ `reset_incomplete`） |
| startup_recovering | startup_incomplete_session_cleared | clearing_cache | pending=2：会话已清，跳过会话但必须重放 cache/debug 清理 | （保持 ｜ `reset_incomplete`） |

- 闭合规则：R-非法（保持+审计）/ R-终态（done 忽略后续）/
  R-重复（begin 在非 idle 态 → R-非法；retry_finalize/finalizeReset 幂等）。
  **重试语义**：各失败态的"可重试"=外部重发原操作（drain/clear），结果以既有
  结果事件（c2_drained/c4_drained/sessions_cleared/cache_cleared/debug_cleared）
  入机，不新增独立重试事件。
- 不变量：pending≠0 期间正常路由/自动同步/Agent 禁止；所有写入携带 resetEpoch，
  过期即拒；**会话、cache、debug 或 v7 备份清理失败均不得绕过后删库**；
  pending=2 只证明会话已清，不证明私有文件已清（cache/debug/备份，09 CT-C3-05/
  12 XC-11）；pending=1/2 后续失败统一
  `reset_incomplete`（09 §2.4 L2-18），beginReset 未提交且 pending=0 时使用
  `write_commit_failed`，不得冒充持久 pending。

### 4.4 D-04 撤销槽（CT-C3-17；单槽 + 启动清槽）

- 状态全集：`empty*, occupied_valid, occupied_invalid`
- 事件：`record, undo_req, undo_ok, undo_fail, clear_at_startup`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| empty | record | occupied_valid | 覆盖写单行（slot=1 CHECK）；信封 v1{version,kind,accountId,safeSummary,payload}；与业务写同事务（CT-C3-07），任一失败整体回滚 | （保持 empty ｜ `write_commit_failed`） |
| occupied_valid | undo_req | occupied_valid | 校验 accountId 与信封；非法时拒绝（他账号槽绝不删除/改写） | （保持 ｜ `invalid_undo_command`） |
| occupied_valid | undo_ok | empty | 11 类恢复器/composite 逐操作恢复 + 删槽 + 审计 | — |
| occupied_valid | undo_fail | occupied_valid | 保槽 + 审计（undo:failure） | （保持 ｜ `write_commit_failed`） |
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
### 4.6 D-20 有效事件/冲突投影纯函数算法（M1 读路径）

输入：一个 accountId 的 storage rows（calendar_events + course_series + user_overlays +
source_records + jw_day_moves + plan_blocks + tasks）与可选 occurrence projection。
输出：EffectiveEvent 列表与 ConflictProjectionResult。

算法（逐条机械实现，顺序即优先级）：
1. 存储事件查询：SQL 一次取 calendar_events LEFT JOIN course_series（source+external_id
   配对）LEFT JOIN event/系列两层 user_overlays；字段 COALESCE 链 = event overlay >
   course-series overlay > 源行（displayTitle/displayLocation/importance/hidden/color/
   foregroundPriority/attendance_*/listening_*）；过滤 deleted_at IS NULL、status NOT IN
   (cancelled,hidden,skipped)、(source='user' OR EXISTS presence<>'missing_within_scope')。
2. 调休投影：只对 source=ustc_jw 且 type=course 的 timed 行，以北京日期按
   jw_day_moves[source_date] 平移日期（时分秒不变、duration 不变）；全天 JW course 不参与
   调休（现状语义）。
3. 重复系列合并：仅当调用方给定 from/through 时调 RecurringEventProjector.projectRange；
   无范围调用不展开（有界性不变量）。合并后按 startAtMs/startDate/ID 排序。
4. 冲突解析（conflictsForItems）：先把 EffectiveEvent + 可见 PlanBlock 转 ScheduleGridItem；
   载入 relation snapshot（schedule_relations 规范键 kind:id|kind:id → conflict/no_conflict，
   schedule_relation_rules 按 (leftType,leftId,rightType,rightId) 分组并按发生日命中
   effectiveFrom/Through）；再对候选窗口执行纯函数
   ScheduleConflictProjection.resolveCandidates。显式 occurrence > 命中系列规则 > 时间重叠
   派生 > 无冲突；派生对只存在于返回结果，任何代码路径都不得 INSERT schedule_relations。
5. 有界性证明：conflictsForItems 只投影调用方传入的 items + 该账号可见 PlanBlock；
   `resolvedConflictIdsFor` 全量入口不在新房代码中创建。

### 4.7 D-21 重复系列投影算法（M1 只读部分）

输入：calendar_event_series + calendar_event_occurrence_exceptions（按 accountId）。
输出：ProjectedRecurringOccurrence / ProjectedRecurringSeries（display/management 两种模式）。

算法：
1. 范围门禁先于任何系列读取：expandRecurrence(throwaway daily rule, from, through) 抛
   RecurrenceLimitError 若 through<from 或含端天数>366。
2. 全账号聚合上限：先对每个可能相交系列展开 originals（遵守 effectiveFrom/Through），
   合计 >1000 立即 RecurrenceLimitError（整体失败，不返回部分列表）。
3. 每系列逐次：decode recurrence_json → expandRecurrence → withinSeriesBounds 过滤 →
   按 occurrenceKey 查 exception（orphaned=true 跳过）→ composeOccurrence
   （override 优先，time override 保留 originalStart 身份）→ 状态投影
   （exception.deletedAt → deleted；exception.status 非空且 != series.status → 该值；
   否则 series.deletedAt → deleted；否则 series.status）。
4. display 模式过滤 cancelled/hidden/skipped/deleted；management 模式按 lifecycleStates
   过滤（空集=全量）。
5. searchSeries 不造 occurrence：按标题子串（trim + lowercase contains）返回
   whole_series locator，空 query 返回全部非过滤系列。

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
| maintenance_draining | end_maintenance | maintenance | 显式 abort：审计 abort 原因，保持维护门至收尾完成后经 maintenance×end_maintenance 释放 | （保持 maintenance_draining ｜ 仅审计） |
| maintenance | begin_maintenance | maintenance | 同 kind 重复请求幂等保持；不同 kind 拒绝 | （保持 maintenance ｜ `maintenance_in_progress`） |
| maintenance_draining | begin_maintenance | maintenance_draining | 同 kind 重复请求幂等保持；不同 kind 拒绝 | （保持 maintenance_draining ｜ `maintenance_in_progress`） |
| maintenance | operation_fail | maintenance | 保持维护门/写屏障；允许重试，或先完成显式 abort 收尾 | （保持 maintenance ｜ `maintenance_failed`） |
| maintenance | end_maintenance | free | 仅同 kind 维护成功或显式 abort 收尾完成后释放；不同 kind 拒绝 | （保持 maintenance ｜ `maintenance_in_progress`） |
| maintenance | acquire | maintenance | 拒绝 | （保持 ｜ `maintenance_in_progress`） |
| maintenance_draining | acquire | maintenance_draining | 拒绝 | （保持 ｜ `maintenance_in_progress`） |

- 闭合规则：R-非法（free×release/end_maintenance/jobs_drained、held×end_maintenance/
  jobs_drained 等未列组合保持+审计）/
  R-终态（本机无终态，不适用）/R-重复（release 后再次 release 由 free×release 的
  R-非法幂等保持；重复 begin_maintenance 的同/不同 kind 行为由显式行定义）。
- 不变量：至多一个 held 或一个 maintenance_draining；`isBusy()` 仅提示性
  （正确性靠原子 acquire）；reset 不依赖本门（走持久 reset_pending，D-03）。
- **M2 首登实现注（不新增 CT）**：prospectiveAccountId 由 stage 产生，但 busy 必须在
  stage 前拒绝。C2 因此可同步 `reserve(jobId)` 占用同一个 held，再调用 stage，并同步
  `bind(reservation, stamp)` 一次性补齐 stamp；reserve/bind 之间仍是同一持有者，bind
  失败走最外层 finally 释放。普通同步继续直接 `acquire(stamp)`。

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
| checkingSession | session_unknown | needsUserLogin | 保守处理（不假装健康）：按需登录路径走，CAS 权威账号证据核验兜底身份确认 | — |
| needsUserLogin | resume_ok | waitingForUser | 恢复同一作业同一流；注入凭据租约（resumeLogin，CT-C1-02）→ takePassword 取即失效 → CAS 交互登录（D-10） | — |
| needsUserLogin | resume_fail | failed | 恢复失败明确终态 | （failed ｜ `collection_failed`/`query_failed` 按 mode） |
| waitingForUser | auth_done | collecting | 权威账号证据匹配且无旁证冲突 → verifiedUsername 入终态载荷；继续采集 | — |
| waitingForUser | captcha_shown | waitingForUser | 幂等保持人工验证码/短信等待（不自动化） | — |
| waitingForUser | auth_fail | failed | 身份未通过，按 M3 修订的三分分类（Young）：无可用权威/旁证冲突/权威确证另一账号 | （failed ｜ `account_mismatch`／`identity_unverified`／`identity_evidence_conflict`） |
| collecting | collecting_done | complete | safeCount 递增；终态载荷就位；**终态事件立即可见，C1 事件流在 cleanup barrier 完成后关闭**（session/credential/active-record/NativeJobGate 收口）；C2 的 stamp 校验与交接在 C1 状态机之外（A-5 整改：complete 即终态，无 deliver_ok 相位） | — |
| （任意非终态） | cancel_received | cancelled | **接受时刻先 bump(cancel)**（C2）→ C1 协作式检查点终止；暂停态立即终态 | — |
| （任意非终态） | error(code) | failed | 终态错误事件（code + 固定文案） | （failed ｜ 每作业码子集） |

- **每作业可产生的失败码子集（A-5 整改，冻结；M3 修订 2026-09-15）**：
  - collection 作业（jw/young-schedule）的 **failed phase**：
    `{account_mismatch, collection_failed}`；**young-schedule 另加**
    `{identity_unverified, identity_evidence_conflict}`（Task 17b 的三分身份失败分类）
  - query 作业（young-enrolment/icourse/campus）：`{account_mismatch, query_failed,
    result_validation_failed, catalog_unavailable}`；**young-enrolment 另加**
    `{identity_unverified, identity_evidence_conflict}`
  - `cancelled` 只由 `cancel_received → cancelled` 产生，不得放入 `error(code) → failed`
    的码子集；
  - 其余码（busy/no_account/stale_lease/maintenance_in_progress/maintenance_failed 等）
    是**作业创建前/交接后**的码，不得作为 C1 作业 failed 事件发出。
  - **bundle 9 错误码归属**：C1 validate 工位校验失败 → 作业
    `collection_failed`；9 个 bundle 码只在 C3 ImportService 解码/语义校验
    阶段产生（10 §8.1 措辞以此为准）。
- 闭合规则：R-非法/R-终态（complete/cancelled/failed 忽略后续事件）/
  R-重复（captcha_shown 幂等；error 后的事件被终态规则吸收）。
- 不变量：needsUserLogin 恢复同一 jobId、sequence 连续（ADR-005）；凭据只在
  恢复注入、取即失效；终态后事件流关闭、租约释放；迟到结果 `stale_lease`。

### 5.3 D-08 WebSessionEngine 卡槽状态机（CT-P-01/02；A-6 整改）

- 状态全集：`absent*, opening, ready, needs_login, quarantined, closing`
- 事件：`open, open_ok, open_fail, probe_healthy, probe_needs_login, probe_unknown,
  auth_ok, auth_fail, close_req, close_ok, close_fail, quarantine_mark, clear_ok,
  clear_fail, residue_found`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| absent | open | opening | P 打开账号独立数据分区（不透明 SessionPartitionRef） | — |
| opening | open_ok | ready | 收集前健康探测（ADR-002） | — |
| opening | open_fail | absent | 分区打开失败；审计 | （absent ｜ `collection_failed`） |
| ready | probe_healthy | ready | 可采集（幂等） | — |
| ready | probe_needs_login | needs_login | 触发 CAS 登录（D-10） | — |
| ready | probe_unknown | needs_login | 保守：未知不假装健康，走登录路径由 CAS 权威账号证据核验兜底（A-6 整改） | — |
| needs_login | auth_ok | ready | CAS 登录状态机完成且权威账号证据匹配后，C1 调 CT-P-02 `confirmAuthenticated(ref)`；只传生命周期事实，不传身份/cookie/token/storage | — |
| needs_login | auth_fail | quarantined | **显式隔离转移**（A-6 整改）：持久 quarantine 标记 + 关闭占用句柄 + 待 clearPartition。**仅权威确证签入另一账号（`account_mismatch`）时由 C1 触发**；无可用权威/旁证冲突不进入本转移（M3 修订，见 ADR-003） | （quarantined ｜ `account_mismatch`） |
| absent/opening/ready/needs_login/closing | close_req | closing | 作业终态/维护释放卡槽（A-6 整改：quarantined 不适用本行） | — |
| closing | close_ok | absent | 关闭完成 | — |
| closing | close_fail | quarantined | 关闭失败（锁/目录占用）：持久 quarantine 标记 + 审计 + UI 报告，待 clearPartition | （quarantined ｜ 仅审计 + UI 报告） |
| （任意非 quarantined） | quarantine_mark | quarantined | 持久标记（清理成功前跨重启禁复用）；顺序=标记→关闭句柄→clearPartition | — |
| quarantined | close_req | quarantined | 拒绝：隔离分区不因关闭句柄而解除隔离（R-非法，保持+审计） | （保持 ｜ 仅审计） |
| quarantined | clear_ok | absent | 真删除分区（物理删除语义）；**唯一离开 quarantined 的路径** | — |
| quarantined | clear_fail | quarantined | 标记保留、跨重启禁复用、报 UI | （保持 ｜ 仅审计 + UI 报告） |
| —（创建） | residue_found | quarantined | 崩溃脏状态恢复：先隔离后清理 | — |

- 闭合规则：R-非法/R-终态（无传统终态；quarantined 只经 clear_ok 离开）/
  R-重复（probe 幂等；clear 幂等）。
- 不变量：卡槽生命周期引擎独占（适配器不得私自 open/close）；清会话/重置遍历
  全部已安装通道（CT-C2-02 全集）；"清理=物理删除、探测=健康状态（含 unknown 的
  保守出口）、认证确认=权威核验后的无资产生命周期事实、隔离=持久标记"四语义三端
  一致（跨平台契约）；P 只有收到认证确认才可在 close 保存不透明会话快照，不得按
  `/home` 或任意受保护 URL 推断。

### 5.4 D-09 导航就绪状态机（A-7 整改：三标志正交幂等置位）

- 状态全集（位图 = u(URL 匹配)/d(DOM 就绪)/h(脚本握手)，幂等置位）：
  `init(000)*, u(100), d(010), h(001), ud(110), uh(101), dh(011),
  target_ready(111)†, timed_out, failed†`
- 事件：`navigate_start, url_matched, dom_ready, ready_handshake, timeout,
  retry, user_wait, give_up, error`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| init | navigate_start | init | P 导航（CT-P-01）；三标志清零 | （failed ｜ `collection_failed`） |
| （init 或任一非终态标志态） | url_matched | 置 u 位 | 幂等置位；三齐 → target_ready | — |
| （init 或任一非终态标志态） | dom_ready | 置 d 位 | 幂等置位；三齐 → target_ready | — |
| （init 或任一非终态标志态） | ready_handshake | 置 h 位 | 幂等置位；三齐 → target_ready | — |
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
- 事件：`fill_ok, fill_fail, submit_ok, submit_rejected, evidence_partial,
  evidence_complete, evidence_conflict, captcha_or_sms, risk_control_page,
  manual_done`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| initial | fill_ok | form_filled | 白名单 origin 填表（username 来自租约 expectedUsername；密码 takePassword 后填） | — |
| initial | fill_fail | waiting_user | 按钮异常 → 静默回退人工（人工只替代填表） | — |
| form_filled | submit_ok | submitted | 提交登录 | — |
| submitted | evidence_partial | verifying | 幂等收集权威同源账号载荷及 DOM/storage 可选旁证 | — |
| submitted | evidence_complete | verifying | 权威证据与旁证结论同步一次齐备：幂等收集后直接核验（不要求先发 partial） | — |
| submitted | submit_rejected | verifying | 密码错误/登录被拒页 → 仍进入账号证据核验（不自动重试密码、不回显敏感信息） | — |
| submitted | captcha_or_sms | waiting_user | 验证码/短信交人工（不自动化） | — |
| submitted | risk_control_page | waiting_user | 风控页交人工（不自动化） | — |
| waiting_user | manual_done | verifying | **人工完成后进入核验，不得直接 authenticated**（A-8 整改：身份核验不可跳过） | — |
| verifying | evidence_complete | authenticated | 权威同源账号载荷精确匹配，且已识别 DOM/storage 旁证均无冲突 → 通过 | — |
| verifying | evidence_conflict | mismatched | 权威证据缺失/冲突，或任一已识别旁证冲突 → 明确失败（**稳定码按 M3 修订三分**：缺失=非破坏性 `identity_unverified`、旁证冲突=非破坏性 `identity_evidence_conflict`、权威确证另一账号=`account_mismatch`） | （mismatched ｜ 三码见左栏） |

- 闭合规则：R-非法/R-终态（authenticated/mismatched 忽略后续）/
  R-重复（evidence_partial 幂等收集）。
- 不变量：填表仅白名单 origin；权威账号证据必须存在并精确匹配；DOM/storage 缺失允许，
  但已识别旁证冲突即明确失败（**M3 修订后 Young 为 `identity_evidence_conflict`；JW 仍为
  `account_mismatch`**）；只保留六个布尔结论，不保留账号/URL/storage 原值
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

### 5.7 D-22 C1 NativeJobGate（L1-04；Native 卡槽资源闸）

- 状态全集：`free*, held`（无终态；进程内组件可服务多个顺序作业）
- 事件：`acquire, pause, terminal_cleanup_done, owner_release, foreign_release`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| free | acquire | held | **同步** check-and-hold；绑定完整 LeaseStamp 与不可伪造 lease token，检查与赋值之间无 await | — |
| held | acquire | held | 拒绝第二个 Native 作业，不改变持有者 | （保持 held ｜ `busy`） |
| held | pause | held | needsUserLogin 仍属同一作业；继续持有，不释放、不换 stamp | — |
| held | terminal_cleanup_done | held | 只记录“终态已发且资源已收口”；等待 owner_release；stream `done` 在 owner_release 后才可见 | — |
| held | owner_release | free | 最外层 finally 释放；清除 token/stamp（幂等） | — |
| free | owner_release | free | 已释放 lease 的重复 finally，幂等忽略 | — |
| held | foreign_release | held | 拒绝非持有者释放，不泄漏当前持有者 | （保持 held ｜ `job_not_found`） |

- 闭合规则：R-非法（保持+审计）/R-终态不适用/R-重复（owner_release 幂等；pause 重复保持）。
- 不变量：本机每来源最多一个 Native lease；C2 D-06 仍是全局权威，D-22 不与其竞争；
  terminal 资源收口完成前不得释放；任何异常由作业最外层 finally 归还；终态事件可先被
  观察，但 `done` 是 cleanup barrier 之后的唯一关闭信号。

### 5.8 D-23 Native JW Adapter 四工位（ADR-009；CT-C1-01/02/03）

- 状态全集：`idle*, fetching, normalizing, validating, delivering, complete†, failed†,
  cancelled†`
- 事件：`start, fetch_ok, fetch_fail, normalize_ok, normalize_fail, validate_ok,
  validate_fail, deliver_ok, deliver_fail, cancel`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| idle | start | fetching | 从已核验会话读取运行时学期目录与临时 dataId；持久学期精确匹配；null 按月份目标键存在且启用即选，目标缺失/禁用才按日期回退；只请求实际目录项 | — |
| fetching | fetch_ok | normalizing | 持有受限内存快照；空 lessonIds 为合法完整空课程；不导出 Cookie/URL/dataId | — |
| fetching | fetch_fail | failed | 丢弃全部中间值，不交付部分数据 | （failed ｜ `collection_failed`） |
| normalizing | normalize_ok | validating | 独立纯 Dart 课程/考试 parser 产出统一结构 | — |
| normalizing | normalize_fail | failed | DOM/字段契约变化 fail-closed、零产物 | （failed ｜ `collection_failed`） |
| validating | validate_ok | delivering | 同一 canonical bytes 通过 SourceBundle 1.0、敏感键、完整性、大小和北京时间校验 | — |
| validating | validate_fail | failed | 销毁候选 bytes，不交付；遵守 D-07 collection failed 码子集 | （failed ｜ `collection_failed`） |
| delivering | deliver_ok | complete | 仅返回 `bundleBytes + verifiedUsername + selectedSemester`；selectedSemester 仅 null 请求时非空 | — |
| delivering | deliver_fail | failed | 未成功形成唯一 complete 终态 | （failed ｜ `collection_failed`） |
| fetching/normalizing/validating/delivering | cancel | cancelled | stop 会话内请求并丢弃全部中间值；不交付/不导入 | （cancelled ｜ `cancelled`） |

- 闭合规则：R-非法/R-终态/R-重复（重复完成信号不重复工位；cancel 幂等）。
- 不变量：fetch→normalize→validate→deliver 顺序不可跳过；无部分 deliver；防御上限与
  canonical 16 MiB 上限同时生效；内部值不得含账号原文以外的身份回读、完整 URL、dataId
  或会话资产；实际 selectedSemester 必须来自本次运行时目录。

### 5.9 D-24 SourceChannel 注册与切换（CT-C2-02/CT-C3-21）

- 状态全集：`idle*, waiting_old_terminal, clearing_sessions, bumping, committing,
  done†, failed†`
- 事件：`switch_req, unregister_req, old_terminal, clear_ok, clear_fail, bump_ok,
  bump_fail, commit_ok, commit_fail`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| idle | switch_req | waiting_old_terminal | C2 取得控制租约；冻结旧 route，不接收该来源新作业 | — |
| idle | unregister_req | waiting_old_terminal | 锁定已安装通道；保留 installed 记录直至所有已知账号清会话成功 | — |
| waiting_old_terminal | old_terminal | bumping | switch：确认旧作业唯一终态且租约释放；准备根 reason=channelSwitch | — |
| waiting_old_terminal | old_terminal | clearing_sessions | unregister：确认旧作业终态后，遍历所有已知账号清该 installed 通道会话 | — |
| clearing_sessions | clear_ok | bumping | 所有账号 clearSession 成功，随后才可 bump/remove | — |
| clearing_sessions | clear_fail | failed | 保持原 installed/route，不部分卸载 | （failed ｜ `sync_failed`） |
| bumping | bump_ok | committing | C3 原子 generation+1 成功；旧结果此后均 stale | — |
| bumping | bump_fail | failed | **保持旧 route/installed 状态**，释放控制租约 | （failed ｜ `sync_failed`） |
| committing | commit_ok | done | 原子替换 route 或移除 installed 通道；释放控制租约 | — |
| committing | commit_fail | failed | 不对外宣称切换成功；按旧 route 恢复或保持阻断并审计 | （failed ｜ `sync_failed`） |

- 闭合规则：R-非法/R-终态/R-重复（old_terminal/clear_ok/bump_ok 以操作 id 幂等）。
- 不变量：installed universe 与 route map 分离；unregister 前全账号清会话；切换严格为
  旧终态→bump(channelSwitch)→route commit；bump 失败不换路由；同一维护根操作不重复 bump。

### 5.10 D-25 SyncCoordinator（CT-C2-05/06/07）

- 状态全集：`evaluating*, skipped†, acquiring, running, paused_login, importing,
  finishing, success†, failed†, cancelled†`
- 事件：`automatic_req, manual_req, fresh_or_backoff, eligible, acquire_ok,
  acquire_fail, needs_login, resume, job_complete, job_fail, cancel, import_ok,
  import_fail, finish_ok, finish_fail`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| evaluating | automatic_req | evaluating | 读取 12h freshness 与 1h retryAfter；不写假 run | — |
| evaluating | manual_req | acquiring | 绕过 freshness/backoff，但不绕过维护门/仲裁/守卫 | — |
| evaluating | fresh_or_backoff | skipped | 返回非错误 skip；不启动 channel/run | （skipped ｜ `fresh_or_backoff`） |
| evaluating | eligible | acquiring | 组装当前 C3 generation/resetEpoch stamp | — |
| acquiring | acquire_ok | running | 原子取得 D-06；申请无密码租约；startSyncRun 后启动已路由通道 | — |
| acquiring | acquire_fail | failed | busy/maintenance/no_account 保持其注册稳定码；无作业、无 run 泄漏 | （failed ｜ `busy`/`maintenance_in_progress`/`no_account`） |
| running | needs_login | paused_login | run 保持 running、全局/Native/凭据上下文保持；同一流等待 resume | — |
| paused_login | resume | running | 新密码租约注入同一 job；sequence 连续 | — |
| running | job_complete | importing | C2 验证终态载荷/stamp 后调用 normal-only ImportService | — |
| running/paused_login | job_fail | finishing | 映射 failed/cancelled；不导入部分结果 | （finishing ｜ 作业注册稳定码） |
| running/paused_login/importing | cancel | finishing | 接受时刻先 bump(cancel)，再协作取消；迟到写为 stale | （finishing ｜ `cancelled`） |
| importing | import_ok | finishing | 保存 importBatchId/status/reminder pending，准备 run terminal | — |
| importing | import_fail | finishing | 零迟到写；按稳定码完成 run | （finishing ｜ `stale_lease`/`sync_failed`） |
| finishing | finish_ok | success/failed/cancelled | 写唯一 sync run 终态；revoke 凭据；释放全局租约 | — |
| finishing | finish_fail | failed | 保留可恢复账本证据；finally 仍撤销凭据并释放租约 | （failed ｜ `sync_failed`） |

- 闭合规则：R-非法/R-终态/R-重复（finish 依 runId+stamp 幂等，resume 仅 paused 有效）。
- 不变量：ImportService 不写 sync_runs；needsLogin 不是 run 终态；automatic 与 manual
  只在 freshness/backoff 分支不同；任何出口撤销凭据并释放 D-06。C2 在作业 record 注册
  后发布同一 `SourceJobHandle` 到 `currentJob`，C5 可晚订阅并 resume/cancel；terminal
  settlement、资源清理和 handle 流关闭后才由仍持有该 handle 的 owner 发布 idle/null；
  连续换作业时旧 cleanup 不得清掉新 handle，live-first+snapshot 不漏不重。

### 5.11 D-26 provisional 首登/重认证生命周期（CT-C3-03/04）

- 状态全集：`absent*, staged, leased, verified, committing, committed†, cancelled†,
  discarded†`
- 事件：`stage, lease_requested, password_taken, verify_ok, verify_fail, commit_req,
  commit_ok, commit_fail, cancel_first_login, discard_reauth, process_exit`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| absent | stage | staged | **仅在 C2 已取得全局 reservation 后**内存预分配 handle/prospectiveAccountId 与 generation/epoch；数据库零行 | （保持 absent ｜ `first_login_failed`/`reauthentication_failed`） |
| staged | lease_requested | leased | 生成一次性 CredentialLease；handle 不出 C3/C2 受控链 | — |
| leased | password_taken | leased | takePassword 原子取即失效；使用方尽力零化副本 | — |
| staged/leased | verify_ok | verified | 保存“expected 已由权威账号证据核验且无旁证冲突”的布尔结论/verifiedUsername；不保存页面证据原值 | — |
| staged/leased | verify_fail | cancelled/discarded | 首登 cancel、重认证 discard；零化临时凭据并清 provisional debug | （对应终态 ｜ `account_mismatch`/`identity_mismatch`） |
| verified | commit_req | committing | 同事务复验 handle/job/account/generation/resetEpoch/identity；首登内嵌私有 Bundle import，重认证只改凭据 | — |
| committing | commit_ok | committed | 一次性消费 handle；提交后才广播 activeAccountChanged；首登立即调和 debug 归属 | — |
| committing | commit_fail | cancelled/discarded | 事务整体回滚；销毁 handle/凭据并清 provisional debug | （对应终态 ｜ `first_login_failed`/`reauthentication_failed`） |
| staged/leased/verified | cancel_first_login | cancelled | 幂等 cancelFirstLogin；零化、撤销租约、物理清 provisional debug | （cancelled ｜ `cancelled`） |
| staged/leased/verified | discard_reauth | discarded | 幂等 discardProvisionalAuth；不改账号/业务数据 | （discarded ｜ `reauthentication_failed`） |
| staged/leased/verified | process_exit | cancelled/discarded | 内存上下文自然失效；启动门 reconcile 未认领 debug 资产 | （对应终态 ｜ `job_not_found`） |

- 闭合规则：R-非法/R-终态/R-重复（cancel/discard/revoke/调和均幂等）。
- 不变量：busy 在 stage 前，无 handle/清理调用；首登 commit 是账号+配置+bundle+凭据+
  digest+审计唯一事务所有者；重认证 identityDigest/业务数据不可变；handle 永不落盘/日志。

### 5.12 D-29 transient/fatal 与单次重试

- 状态全集：`ready*, executing, waiting_retry, succeeded†, failed†, cancelled†`
- 事件：`start, success, eligible_transient, fatal, retry_timer, cancel`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| ready | start | executing | retryCount=0；建立新 navigation generation | — |
| executing | success | succeeded | 返回本阶段结果 | — |
| executing | eligible_transient | waiting_retry | 仅未提交凭据、无外部副作用的导航/DOM/handshake/临时网络/凭据前 renderer；retryCount 0→1 | — |
| waiting_retry | retry_timer | executing | 注入延迟 500ms 后创建新 generation；同 job/stream/stamp | — |
| executing | fatal | failed | 凭据提交后、OTP/风控、身份/DOM/schema/隐私/策略、cancel/stale、bundle build/validate，或 retryCount=1 的 transient 均不重试 | （failed ｜ 所属作业注册稳定码） |
| executing/waiting_retry | cancel | cancelled | 取消延迟/操作，零后续重试 | （cancelled ｜ `cancelled`） |

- 闭合规则：R-非法/R-终态/R-重复（同一 failure 只消费一次重试额度）。
- 不变量：每阶段最多一次、固定 500ms；不使用真实 sleep 的单测；重试不新建 job/run，
  但必须新建 navigation generation；未知插件异常在 JobExecutor/C2 边界 fail-closed。

### 5.13 D-30 syncAll 顺序批次与登录恢复

- 状态全集：`idle*, running_source, paused_login, advancing, success†, failed†,
  cancelled†`
- 事件：`start, source_success, source_failure, needs_login, resume, cancel,
  more_sources, exhausted`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| idle | start | running_source | 固定来源顺序启动第一项；仅为实际启动项创建 run | — |
| running_source | source_success | advancing | 记录结果并释放该来源资源 | — |
| running_source | source_failure | advancing | 记录稳定失败并置 aggregateFailed=true；普通失败继续后续来源 | — |
| running_source | needs_login | paused_login | **暂停整个批次**；当前 source/run/job/租约保持，不启动后续来源 | — |
| paused_login | resume | running_source | 恢复当前同一 job/run，成功后再推进 | — |
| running_source/paused_login/advancing | cancel | cancelled | 取消当前项；未启动来源不创建伪 run；停止批次 | （cancelled ｜ `cancelled`） |
| advancing | more_sources | running_source | 顺序启动下一来源 | — |
| advancing | exhausted | success | aggregateFailed=false，返回聚合成功 | — |
| advancing | exhausted | failed | aggregateFailed=true，返回稳定聚合失败 | （failed ｜ `sync_failed`） |

- 闭合规则：R-非法/R-终态/R-重复（source terminal 按 source/jobId 去重）。
- 不变量：任意时刻仅一个来源在跑；needsLogin 不继续队列；普通失败继续但最终不得静默
  成功；取消后的未启动来源零账本行。
- **成员冻结（M3 补充，spec §8.1；09 CT-C2-01 syncAll 成员澄清）**：`syncAll` 只按固定
  顺序枚举**可产生 SourceBundle 且 `enabled=true` 的同步来源**，跳过被禁用项。M3 成员
  固定为 `ustc_jw` → `ustc_young_my_schedule`；`ustc_young_enrolment`/`icourse`/
  `campus` 是查询来源，**只经 `submitQuery`，永不进入 `syncAll`/`sync`**。当前骨架
  遍历 `SyncSource.values` 的行为**不是目标契约**——`syncAll` 不得自动纳入查询来源。
- **负要求（D-30 测试触发）**：查询来源（enrolment/iCourse/campus）**零 `sync` 调用、零
  `sync_runs` 行**；`sync_runs` 单一写权威在 C2（CT-C3-21），查询作业不经 startSyncRun/
  finishSyncRun。M3 实现须补负测试：断言 enrolment 经 `submitQuery` 完成后无新增
  `sync_runs` 行、无 `sync` 调用记录。

### 5.14 D-19 Python 租户生命周期（并存期；ADR-014/022）

- 状态全集：`stopped*, starting, healthy, job_active, stopping, crash_observed`
  （无终态；M7 由删除实现而非运行时状态表达）
- 事件：`new_job, start_ok, start_fail, job_bound, job_terminal, process_exit,
  stop_req, stop_ok, stop_fail`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| stopped | new_job | starting | 为**新 job**冷启动一次；生成新握手/进程租户，不复用旧 stamp | — |
| starting | start_ok | healthy | 只接受 loopback 握手与当前租户 token | — |
| starting | start_fail | stopped | 当前新 job 失败；不无限重启 | （stopped ｜ `request_failed`） |
| healthy | new_job | healthy | 复用健康进程上下文，仅绑定新 stamp；不再发生平台冷启动，随后由 `job_bound` 进入 job_active | — |
| healthy | job_bound | job_active | 绑定唯一当前 job/stamp，转换 Python 事件到冻结 JobEvent | — |
| job_active | job_terminal | healthy | 关闭当前事件转换/释放 job 绑定；进程可供下一新作业使用 | — |
| starting/healthy/job_active | process_exit | crash_observed | 当前作业（若有）唯一 failed 终态；旧 job/stamp 永久作废 | （crash_observed ｜ `request_failed`） |
| crash_observed | new_job | starting | 仅新 job 可重新冷启动一次；绝不恢复旧 job/sequence/stamp | — |
| healthy/crash_observed | stop_req | stopping | M7 前显式幂等关停；拒绝新 job | — |
| stopping | stop_ok | stopped | 释放进程/token/事件流资源 | — |
| stopping | stop_fail | crash_observed | 视为不可复用，下一新 job 才可冷启动 | （crash_observed ｜ `request_failed`） |

- 闭合规则：R-非法/R-终态不适用/R-重复（process_exit/stop_req/stop_ok 幂等）。
- 不变量：进程退出只影响当前 job；一次冷启动额度按新 job 计，不形成进程重启循环；
  跨重启普通作业一律 job_not_found；M7 删除本组件与 Python 通道，不迁移其状态。

### 5.15 D-12 Young schedule 适配器（ustc_young_my_schedule；CT-C1-01/02/03；spec §7）

- 状态全集：`idle*, fetching, suspendedLogin（内部恢复态）, normalizing, validating,
  delivering, complete†, failed†, cancelled†`
- 事件：`start, session_needs_login, resume_ok, date_fetched, all_dates_fetched,
  fetch_fail, normalize_ok, normalize_fail, validate_ok, validate_fail, deliver_ok,
  deliver_fail, cancel`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| idle | start | fetching | C2 冻结 BeijingClock 日期窗口（today−7..today+1 月、含端点、≤40、严格递增、`YYYY-MM-DD`）；打开个人日程页；probeSession（CT-P-02） | — |
| fetching | session_needs_login | suspendedLogin | 信号 D-07 needsUserLogin；保持同一 job/stream/stamp/日期窗口；窗口不按新系统时间重算 | — |
| suspendedLogin | resume_ok | fetching | **重新打开目标页 `…/personalInformation`**（CAS 默认落地是 dataAnalysis，不得误当采集完成；M3-0，spec §4.2/§4.3）；继续同一日期窗口 | — |
| fetching | date_fetched | fetching | 单日 observer 先于动作 → 捕获冻结 schedule endpoint → 校验 pages∈{0,1}（>1 即 `collection_failed`）、记录覆盖当前点击日期且 end≥start；空列表=有效空证据；下一日 | — |
| fetching | all_dates_fetched | normalizing | 每个请求日期都有成功响应证据；跨日相同外部 ID 合并 | — |
| fetching | fetch_fail | failed | 任一日期失败不形成部分 Bundle；丢弃中间值 | （failed ｜ `collection_failed`） |
| normalizing | normalize_ok | validating | 每条活动 → calendar_events(second_class)+SourceRecord；稳定身份/标题/时间/地点/状态/全日；courseSeries/scheduleRelations 空；相同 ID 内容完全相同只留一份 | — |
| normalizing | normalize_fail | failed | 相同 ID 内容冲突立即失败；零产物 | （failed ｜ `collection_failed`） |
| validating | validate_ok | delivering | SourceBundle 1.0（scope=完整 date_window+全部日期完成证据；一事件一 SourceRecord；digest/16MiB/深度 64/敏感键/9 错误码，CT-C1-03） | — |
| validating | validate_fail | failed | 销毁候选 bytes，不交付 | （failed ｜ `collection_failed`） |
| delivering | deliver_ok | complete | 返回 `bundleBytes`（verifiedUsername 经 D-07 终态载荷） | — |
| delivering | deliver_fail | failed | 未形成唯一 complete 终态 | （failed ｜ `collection_failed`） |
| fetching/normalizing/validating/delivering/suspendedLogin | cancel | cancelled | stop 会话内请求并丢弃全部中间值；不交付/不导入 | （cancelled ｜ `cancelled`） |

- **内部恢复态 suspendedLogin**：同一 job/stream/stamp/日期窗口保持；恢复时**必须重新
  打开原作业请求的目标页**（非 CAS 默认落地 dataAnalysis），再继续采集；窗口不重算。
- **公开稳定错误**：`collection_failed`（页面/API/完整性/ID 冲突/pages>1）；身份失败三分
  （Task 17b）：`identity_unverified`（无可用权威，非破坏性）、`identity_evidence_conflict`
  （权威匹配、旁证冲突，非破坏性）、`account_mismatch`（权威确证另一账号，**唯一**触发
  Young 分区 quarantine + 物理清理的身份出口），三者均经 D-07 权威身份核验；
  `stale_lease` 经 C2 stamp 复验；`cancelled` 仅由 cancel 产生；
  9 个 bundle 错误码归 C3 ImportService 解码/语义阶段。
- 闭合规则：R-非法/R-终态/R-重复（date_fetched 幂等推进；cancel 幂等）。
- 不变量：fetch→normalize→validate→deliver 顺序不可跳过；无部分 deliver；日期窗口在
  作业组装时冻结、恢复后不重算、宿主时区 `DateTime.now/parse` 不参与业务解释；observer
  先于动作；每日期 pages∈{0,1}；每个请求日期必须有成功响应证据；相同 ID 冲突即失败；
  Bundle builder/validator 防御性唯一性断言，DB replay 不得掩盖来源重复；内部值不含
  账号原文以外身份、完整 URL、cookie/会话资产。

### 5.16 D-13 Young enrolment 适配器（ustc_young_enrolment；CT-C1-01/02/04；spec §6）

- 状态全集：`idle*, fetching, suspendedLogin（内部恢复态）, normalizing, validating,
  delivering, complete†, failed†, cancelled†`
- 事件：`start, session_needs_login, resume_ok, page_fetched, all_pages_fetched,
  fetch_fail, normalize_ok, normalize_fail, validate_ok, validate_fail, deliver_ok,
  deliver_fail, cancel`

| 当前态 | 事件 | 次态 | 动作 | 失败态 |
|---|---|---|---|---|
| idle | start | fetching | 打开当前报名中页；probeSession（CT-P-02） | — |
| fetching | session_needs_login | suspendedLogin | 信号 D-07 needsUserLogin；保持同一 job/stream/stamp | — |
| suspendedLogin | resume_ok | fetching | **重新打开目标页 `…/myproject`**（非 CAS 默认落地 dataAnalysis；M3-0，spec §4.2/§4.3）；继续同一查询 | — |
| fetching | page_fetched | fetching | observer 先于动作 → 捕获冻结 GET endpoint；首页冻结 reportedTotal+总页数；后续页必须一致；页码连续合法不重复不循环 | — |
| fetching | all_pages_fetched | normalizing | 去重后活动数==reportedTotal；total=0/pages=0=有效完整空结果 | — |
| fetching | fetch_fail | failed | 丢弃中间值 | （failed ｜ `query_failed`） |
| normalizing | normalize_ok | validating | `itemName→title`；保留冻结 status/category/time/count/location/organization；`baseContent`/`conceive` HTML→纯文本≤4000 字符；丢弃 `imagePath`/私有/未知字段；时间统一 +08:00；不带账号/报名身份/请求参数/页面上下文 | — |
| normalizing | normalize_fail | failed | 字段契约变化 fail-closed | （failed ｜ `query_failed`） |
| validating | validate_ok | delivering | QueryResult 1.0 canonical（queryType=young_enrolment；data.activities==metadata.activityCount/reportedTotal；字段白名单 09 §5.4；title 等必填完整；references=[]） | — |
| validating | validate_fail | failed | 原始 HTML/敏感键/未知字段/非法时间/越界文本/计数或分页不一致 | （failed ｜ `result_validation_failed`） |
| delivering | deliver_ok | complete | 返回 `QueryCompleted{result, attachmentRegistrations=[]}` | — |
| delivering | deliver_fail | failed | 未形成唯一 complete 终态 | （failed ｜ `query_failed`） |
| fetching/normalizing/validating/delivering/suspendedLogin | cancel | cancelled | stop 请求并丢弃中间值 | （cancelled ｜ `cancelled`） |

- **内部恢复态 suspendedLogin**：同一 job/stream/stamp 保持；恢复时**必须重新打开原作业
  请求的目标页**（非 CAS 默认落地 dataAnalysis），再继续查询。
- **公开稳定错误**：`query_failed`（页面/API/请求失败）；`result_validation_failed`
  （字段/计数/隐私失败）；身份失败三分（Task 17b）：`identity_unverified`（无可用权威，
  非破坏性）、`identity_evidence_conflict`（权威匹配、旁证冲突，非破坏性）、
  `account_mismatch`（权威确证另一账号，**唯一**触发 Young 分区清理的身份出口），三者均经
  D-07；`stale_lease` 经 C2；`cancelled` 仅由 cancel 产生。
- 闭合规则：R-非法/R-终态/R-重复（page_fetched 幂等推进；cancel 幂等）。
- 不变量：**查询来源负要求（D-30）——零 `sync` 调用、零 `sync_runs` 行**，只经
  `submitQuery`（CT-C2-01），永不经 `syncAll`/`sync` 启动，不写 C3 业务数据、不应用 12h
  freshness、不使用 CT-C3-22 附件登记；fetch→normalize→validate→deliver 顺序不可跳过；
  observer 先于动作；只接受冻结 GET endpoint；首页 reportedTotal 权威、后续页必须一致；
  total=0/pages=0=有效完整空结果；HTML 转纯文本每字段≤4000（满足 09 §5.4 全局 ≤8000）；
  不带账号/报名身份/请求参数/页面上下文；references=[]。

## 6. 待补组件清单与里程碑触发器（M1–M8）

| 组件 | 触发器 | 补设计时必须包含 |
|---|---|---|
| D-22/D-23/D-24/D-25/D-29/D-30（M2 引擎周边） | ✅ 2026-08-21 已触发并闭合 | 见 §5.7~§5.13；实现不得弱化转移表 |
| D-12/D-13 young 双适配器（M3） | ✅ 2026-09-09 已触发并闭合 | 见 §5.15/§5.16；管道四工位状态机 + suspendedLogin 内部恢复态（重新打开目标页）+ 封闭字段映射 + D-30 查询来源负要求 |
| D-14 icourse 适配器 + 24h 缓存（M4） | M4 开工前 | 缓存状态机（fresh/stale/miss）+ 降级转移 |
| D-15 campus 刷新/详情/附件（M4） | M4 开工前 | 节流/过期/降级状态机 + 附件登记载荷生成点 + CT-C3-22 调用 + 孤儿附件回收（下一次同名附件转换或 clearCache 幂等清理，12 XC-04） |
| D-16 提醒协调器（M5） | M5 开工前 | reminders 五态转移 + 6 表 watch 重入保护 + 哨兵语义 |
| D-20/D-21 M1 纯函数算法 | ✅ M1 开工前已闭合 | 见 §4.6/§4.7；实现与 audit repairs 已完成 |
| D-26 provisional 生命周期 | ✅ 2026-08-21 已触发并闭合 | 见 §5.11；stage/commit/cancel/discard + busy 边界 + 进程退出零化 |
| D-17/D-27/D-28 维护与启动（M5） | M5 开工前 | 维护协调器 UI 投影 + clearBusinessData 写屏障 + 启动强制门 |
| D-18 Agent 推理循环/审批门/预算（M6） | M6 开工前 | 8×12 预算转移 + 确认卡状态机 + 复合写 ledger |
| D-19 Python 租户生命周期（M2 并存期） | ✅ 2026-08-21 已触发并闭合 | 见 §5.14；启动/健康/停止 + 事件转换 + M7 移除路径 |

## 7. 横切状态机交互一致性规则（可机械核对）

| 规则 | 涉及状态机 | 一致性要求 |
|---|---|---|
| R1 取消即递增 | D-05/D-06/D-07/D-24/D-25/D-30 | 取消接受时刻 bump 先于 cancelled 终态；**reason 按根操作**：直接取消/deleteCredentials/clearSession 维护内取消= cancel；clearBusinessData/reset=根 reason，内部取消不重复 |
| R2 迟到拒绝 | D-02/D-07/D-23/D-24/D-25 | 任何 C3 写事务内比对 stamp（含 replay 路径）；过期 → stale_lease、零写入；切换先 bump 再换 route |
| R3 维护互斥 | D-06/D-07/D-01 | maintenance/maintenance_draining 期间 acquire 恒拒；迁移器运行期间无作业可启动（启动门） |
| R4 暂停语义 | D-05/D-07/D-22/D-25/D-30 | needsUserLogin 期间 run 保持 running、租约保持、sequence 连续；syncAll 不推进下一来源 |
| R5 租约释放 | D-06/D-11/D-22/D-25 | 作业任何终态先完成资源收口，再释放 Native/全局租约（try/finally）与凭据租约（job_terminal→revoked） |
| R6 provisional 边界 | 09 CT-C3-03/04 + CT-P-05 + D-06/D-26 | 先 acquire 后 stage；acquire 失败无 handle、不调销毁；stage 后任何失败出口调 cancel/discard 并 clearDebugAssets(prospectiveAccountId)；提交成功后立即 reconcileProvisionalDebugAssets(activeAccountId) 提升归属；崩溃后由启动门 reconcile 兜底（无正式账号认领者物理删除） |

## 8. 本层拍板记录（L4 决策）

| 编号 | 决策 | 内容 | 状态 |
|---|---|---|---|
| L4-01 | 本层范围 | M1/M2 核心状态机先设计（D-01~D-11）；其余登记待补，每块开工前补设计 | ✅ 已定 |
| L4-02 | 首轮独立审查整改（2026-08-14，10A/4B） | A-1 三闭合规则模板 / A-2 replay 过租约守卫 / A-3 reset 顺序与启动安全重放 / A-4 维护 reason 按 kind / A-5 枚举名与终态所有权 + 码子集 / A-6 unknown 保守出口 + quarantine 闭环 / A-7 三标志位图 / A-8 manual_done 进核验 / A-9 revoke 幂等 + 终态失效 / A-10 失败态双列 + `reset_incomplete` 回写 09（L2-18）；B-1 登记表补 D-22~D-30 / B-2 状态三档 / B-3 断言措辞与备份策略移交 / B-4 旧表述清零 | ✅ 已落地 |
| L4-03 | 整改复审修订（2026-08-14） | D-02 subject/active/stamp 同事务守卫 + subject_fail；D-03 五失败态归位与启动事件闭合；D-06 非终态维护态及 `maintenance_failed` 回写 09（L2-19）；D-07 cancelled 退出 failed 子集；L2-18 限定 pending=1/2；闭合规则优先级、D-20/21/D-26 触发器与 09/10 回写记录补齐 | ✅ 已落地（2026-08-14 用户重认，gate 关闭） |
| L4-04 | 第 5 层整改复审用户收口（2026-08-15） | D-03 在会话清理后新增 clearing_cache/clearing_debug 两态；pending=2 启动恢复必须重放两项私有资产清理而非直接 finalization；R6 增首登 prospective debug 清理/调和（最终复审精确化：成功立即提升、失败/取消立即清除、崩溃启动调和）；D-15 触发器补孤儿附件回收 | ✅ 已同步（09 L2-21 / 10 L3-06） |
| L4-05 | M2 开工触发器闭合（2026-08-21，用户已确认 M2 设计） | D-19/22/23/24/25/26/29/30 按既有 CT 补齐；M2 参数 = 每阶段最多重试 1 次/500ms、null 学期确定性回退、每账号独立 UDF、自动候选门与真实站点门分离；不新增跨容器签名 | ✅ §5.7~§5.14，真实站点风险保持开放 |
| L4-06 | Task 17 owner approval（2026-08-23） | D-07/D-22/D-25 对齐 CT-C1 cleanup barrier 与 CT-C2-01 currentJob/currentJobHandle：终态事件即时、done/idle 等资源清理后；同一 SourceJobHandle 可被 C5 晚订阅、resume/cancel；idle/null 采用 handle owner identity-safe 清理，连续作业 replay 不漏不重且旧 cleanup 不覆盖新 handle；不新增并行 handle/清理方法 | ✅ 已同步（回写 09 L2-23 / 10 L3-07） |
| L4-07 | M2 真实验收账号证据状态机修订（2026-08-25，用户批准） | D-07/D-10 将“三层缺一失败”修订为“权威同源账号载荷必需 + DOM/storage 可选冲突旁证”；旁证缺失不失败、冲突失败；仅流转六布尔结论 | ✅ 已同步（回写 07 ADR-003 / 09 L2-24 / 10 L3-08） |
| L4-08 | M2 真实验收学期选择修订（2026-08-25，用户批准） | D-23 的 null 默认顺序改为月份目标键存在且启用即选，不要求覆盖当天；日期只用于目标缺失/禁用后的 fallback 排序 | ✅ 已同步（回写 07 ADR-009 / 09 L2-25 / 10 L3-09） |
| L4-09 | M2 冷启动会话快照修订（2026-08-27，用户批准继续修复） | D-08 的 auth_ok 动作增加 CT-P-02 无资产 `confirmAuthenticated(ref)`；P 的快照资格只来自 C1 权威身份核验成功，不再观察 URL 猜测；未确认的失败/取消关闭不保存快照 | ✅ 已同步（回写 09 L2-26 / 10 L3-10） |
| L4-10 | M3 Young 双适配器状态机冻结（2026-09-09，Task 2） | D-12（§5.15）/D-13（§5.16）补齐四工位状态机 + suspendedLogin 内部恢复态（CAS 默认落地 dataAnalysis，恢复须重新打开目标页 personalInformation/myproject，M3-0 证据见 13 §M3-0）+ 完整转移表 + 公开稳定错误 + 不变量；D-30（§5.13）补 syncAll 成员冻结（只枚举 enabled Bundle 同步来源，M3=jw+young schedule）与查询来源负要求（零 sync 调用/零 sync_runs 行）+ 负测试触发；§3 登记/§6 backlog 翻 ✅。不新增跨容器 CT 编号 | M3 spec §3.4/§6/§7/§8.1 / 09 L2-27 / 10 L3-11 |
| L4-11 | M3 身份失败分类与处置修订（2026-09-15，Task 17b） | D-07/D-10 的 Young 侧身份失败三分：无可用权威=`identity_unverified`、权威匹配但旁证冲突=`identity_evidence_conflict`（两者**非破坏性**：终止作业、不交付、保留分区，仅作业级隔离——不写 quarantine 标记、从不 `confirmAuthenticated`，解除=下一作业重新核验）、权威确证另一账号=`account_mismatch`（既有 quarantine + 物理清理）；D-08 的 auth_fail→quarantined 明确只由 `account_mismatch` 触发；§5.2 每作业失败码子集为两个 Young 作业补两码；JW 侧不变（M2 已验收）。不新增 CT、不改变权威证据类 | M3 spec §4.3/§8.4 / 07 ADR-003 M3 修订 / 09 L2-28 / 10 L3-12 |

## 9. 第 4 层 gate 检查表

- [x] ① 已设计状态机（D-01~D-11、D-19、D-22~D-26、D-29/D-30）每个满足 §2 模板：状态全集（标注初始/终态）+
      显式转移表 + 三闭合规则 + 失败态双列 + 不变量
- [x] ② 登记表（§3，D-01~D-30）每行有里程碑与三档状态；待补组件均有触发器（§6）
- [x] ③ §7 六条横切规则在全部转移表中无违背（R1~R6 逐条过）
- [x] ④ 转移表与 09 冻结契约一致（CT-C1-01 八相位枚举名、CT-C2-06 run 六值、
      CT-C2-03 takePassword 原子、CT-C3-05 三值编码、CT-C3-21 四 reason；CT-C2-01
      currentJob replaying handle）
- [x] ⑤ 失败态双列中的对外码全部在 09 §2.4 注册表（含 L2-18
      `reset_incomplete` / L2-19 `maintenance_failed`）
- [x] **gate 关闭（2026-08-14 用户重认；2026-08-15 回写重验；2026-08-23 Task 17、2026-08-25 M2 真实验收回写重验）**：首轮 10A/4B +
      复审 6A/3B/1C 全部闭环，09 回写 L2-18/19/21/23/24；D-03 严格清理转移与
      current-job/cleanup barrier 顺序闭合 →
      第 5 层 `12-cross-cutting.md`
