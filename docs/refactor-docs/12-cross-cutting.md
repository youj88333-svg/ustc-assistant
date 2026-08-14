# 12 横切关注（六层阶梯 · 第 5 层）

> 产出日期：2026-08-14 ｜ 状态：**第 5 层已关闭（2026-08-15 最终复审整改 `bd3bec7` + 用户重认；回写 09 L2-21 / 10 L3-06 / 11 L4-04）**
> ｜ 依据：`07-constitution.md`（§2.5 移交登记）、`09-contracts.md`（CT 65 条 +
> L2-01~21）、`10-runtime.md`、`11-component-designs.md`、01–06 模块文档与
> main 代码（参数以代码为准，已核实）

## 1. 本层目标与 gate

- 目标：把横切关注收敛成登记表，**每项有单一归属**——一个关注点只有一个决策
  权威，其余容器只是消费者/执行方/能力方。
- 本层不重复前五层已冻结的规则，只做三件事：① 登记与溯源；② 给尚无归宿的
  实施细则定单一归属；③ 冻结本层才拍板的参数值。
- **gate：登记表每项有且仅有一个单一归属；每项可溯源到移交项或 CT/ADR；
  本层新冻结的参数值全部有代码或既有决策依据（无凭空值）。**
- **"单一归属"判定规则**【冻结】：单一归属 = 决策权威唯一（同一容器内多个组件
  视为同一归属）；能力提供方、流转方与执行方**一律列消费者列**；一个关注点的
  决策权威必须真实位于其运行时链路上（A-1 整改：不得把不经过该容器的链路
  归给它）。

## 2. 横切关注登记表（gate 工件；整改复审后 16 项）

| ID | 关注点 | 单一归属 | 主要消费者/执行方 | 承接自 |
|---|---|---|---|---|
| XC-01 | 时区与时间 | C0 `BeijingClock` + `core/time` 工具箱 | 全部容器 | ADR-015 + 09 §2.1（07 §2.5 移交项 4） |
| XC-02 | 凭据与密钥安全 | C3 账号凭据服务（仓库/解密出口/DPAPI 调用点登记） | C0 保护端口（能力）、C2（租约流转）、C4 Key 加载、C1/C5 | ADR-019/020 + 07 §2.5 移交项 18 |
| XC-03 | 账号隔离 | C3（表纪律 + 单账号模型） | C2/C4/C5 | 07 §2.5 移交项 3 + ADR-004 |
| XC-04 | 事务边界 | C3（写服务统一契约 + 生命周期事务） | C4 网关（Agent 四日志）、C1/P（跨数据库/文件补偿执行） | CT-C3-07/CT-C4-05 + ADR-023 |
| XC-05 | 审计 | C3 Audit 子域（ActionLogRepository） | 全部写路径 | CT-C3-07 + 红线 2.1-5 |
| XC-06 | 来源作业可观测性 | C2（source run 生命周期与可观测语义权威） | C3（SourceStateService 持久状态执行）、C1（八相位/safeCount 产出）、C5 | ADR-005 + CT-C1-01/CT-C3-21 |
| XC-07 | Agent 上下文与 LLM 出站隐私过滤 | C4 `OutboundPrivacyFilter` | C4 LLM 客户端、C2（QueryResult 交接） | 红线 2.1-2 + CT-C1-04 |
| XC-08 | 来源请求出站最小化 | C1（fetch 请求只携带必需字段） | P（仅 WebView 导航执行，不执行自有 HTTP）、C2（请求组装） | 红线 2.1-2 + 08 §2 出站三分法 |
| XC-09 | launcher 白名单委派 | C5（校验后经 CT-P-04 委派系统浏览器） | C0（CT-C0-05 七主机常量）、P（launcher 执行） | 红线 2.1-2 + CT-C0-05/CT-P-04 |
| XC-10 | 调试资产边界 | P `FileStoragePort`（私有目录/落盘/清理） | C1/C3/调试基建、C5 设置页（手动清理） | 07 §2.5 移交项 19（--save-raw） |
| XC-11 | 数据保留与备份 | C3 迁移器（备份动作与保留策略执行） | P（文件能力）、C5 设置页（手动清理入口） | 红线 2.2-7 + 11 §4.1 B-3 移交 |
| XC-12 | 附件管道 | C1 `AttachmentContentConverter`（限额与编排权威） | P（文件/decoder 执行）、C4/C3 | 07 §2.5 移交项 16 + CT-C1-05 |
| XC-13 | 会话资产与隔离 | C1 `WebSessionEngine`（生命周期权威） | P 会话适配器（执行）、C2（维护流） | ADR-019 修订 + CT-P-02 |
| XC-14 | 平台能力矩阵 | P（声明性对齐） | C1/C2/C3/C4/C5 | 红线 2.2-8 + 08 §5.6 |
| XC-15 | 本地调试服务边界 | C2（并存期编排权威） | P（回环传输执行）、调试基建 | 07 §2.5 移交项 20 + 09 CT-P-08 |
| XC-16 | Agent 运行可观测性 | C4 会话服务（agent run/tool/ledger 语义权威） | C3（持久服务）、C5（聊天页/设置页） | 06 §4/§6 + CT-C4-01/02/04/05 |

## 3. 各关注点细则（只写本层新增/参数冻结；已冻结规则只登记溯源）

### XC-01 时区与时间（归属 C0）

- 铁律：存储/进程内传输一律 epoch ms；业务解释唯一 Asia/Shanghai（固定 UTC+8）；
  线协议信封维持 +08:00 ISO-8601（09 §2.1，L2-13 A-1 修订）。
- `BeijingClock.now()` 是"当前时刻"唯一来源。
- 禁止事项：任何模块不得自行拼装时区语义、不得读取系统时区做业务解释。

### XC-02 凭据与密钥安全（归属 C3；C0 提供能力、C2 流转）

- 三类资产三类边界（ADR-019，不重述）：显式凭据密文 / 会话资产不透明（XC-13）/
  临时明文尽力零化。
- **Dart String 不可变 → "绝对零化"不可承诺**【冻结，07 §2.5 移交项 18】：
  临时明文只声明"最短存活 + 尽力零化 + 永不落日志"（Bitwarden 式诚实措辞）；
  实现纪律：明文只存在于 `takePassword()` 返回值与填表调用栈，用后立即出作用域。
- **DPAPI 调用点登记制**【前层冻结项登记，09 §3 C0 约束】：`unprotect` 仅允许
  ① C3 账号凭据服务（租约申请时）；② C4 `ProtectedAgentSecretStore`（Key 加载）。
  M1/M6 实现时以 grep 可核查的调用点清单验收；新增调用点必须回写 09。

### XC-03 账号隔离（归属 C3）

- 单账号模型（ADR-004）；表纪律（CASCADE/RESTRICT/SET NULL 分工，09 §7.1）；
  撤销槽 accountId 校验（他账号槽绝不删改，D-04）。

### XC-04 事务边界（归属 C3）

- 写服务统一契约见 CT-C3-07（本层不重述）；登记三处横切派生：
- 来源写事务（A-2 强化）：subject/activeAccountId/stamp 复验、幂等查询与业务写入
  同一数据库事务、同一调用栈（11 D-02 不变量）。
- Agent 写四日志同事务（CT-C4-05）；SQLite fault-injection 回归验证保留
  （M1/M6 测试清单）。
- **跨数据库/文件系统事务补偿（B-6 整改登记）**：附件文件由 C1/P 先落盘、索引
  随后由 C3 事务提交——① 文件成功、DB 失败 → 孤儿文件回收责任 = C1/P 写方
  （实现细节移交 D-15/M4，回收时机=下一次同名附件转换或 clearCache 幂等清理）；
  ② DB 成功、文件缺失 → 读取出口 = 该附件标记不可用（campus_detail 明确
  降级，不静默吞错）；③ 清理时文件删除失败 → 本次 clearCache 不提交缓存表删除；
  completeReset 保持 pending=2 与写屏障，二者均通过原入口幂等重试（09
  CT-C3-20/L2-21）。本层只登记归属，不新造接口。

### XC-05 审计（归属 C3 Audit 子域）

- `action_logs` 唯一审计表；`safe_summary` 只存安全摘要（无 id/ref/原文）；
  **四类 source 值**（B-4 整改：旧称"三来源"计数有误）：`user`（用户操作）/
  来源键（导入）/ `agent`（run 汇总与写确认流）/ `system`（设置与维护）。
- **Agent run 审计如实声明（B-4 整改）**：read_only_run 汇总为 **best-effort
  最多一次**（照搬旧房终态后尝试，失败不阻塞 run 终态、记 error_code）；
  不承诺"恰好一次"；审计缺口以 `agent_runs` 行本身为准。
- 读侧：`HistoryRepository.query`（上限 50、正则脱敏）；v8 #3 索引。
- Agent 侧补充账本：`tool_invocations` 安全摘要 + `MutationLedger` 聚合计数。

### XC-06 来源作业可观测性（归属 C2；C3 执行持久化、C1 产出事件）

- C2 权威限定为 **run 生命周期与可观测语义**（B-1 整改）：事件流转播、
  sync_runs 六值/trigger 四值语义、busy/freshness 查询；**持久状态执行方是 C3
  `SourceStateService`（CT-C3-21），C2 不直接写表**。
- 作业事件：八相位 + sequence/safeCount/终态载荷（C1 产出）——流内只含安全
  计数，凭据/原始数据永不进流。
- UI 可观测：C3 drift watch 流广播 + C5 订阅自动刷新。
### XC-07 Agent 上下文与 LLM 出站隐私过滤（归属 C4）

- 双防线：① `OutboundPrivacyFilter` 逐工具白名单构建器（主防线）；② 兜底
  redaction（db_id/cookie 等敏感键后手拦截）。写工具结果只含统一安全摘要白名单。
- QueryResult 入对话前校验（封闭字段集 + references 白名单 CT-C0-05）；
  校验失败 `result_validation_failed` 不进对话。
- LLM 出站：仅 C4 LLM 客户端出站到学校网关；请求只携带会话必需上下文。

### XC-08 来源请求出站最小化（归属 C1）

- C1 来源 fetch/查询请求只携带完成该查询所必需的最少字段（评课联动只发送必需
  检索词——课程名/教师名或其组合，红线 2.1-2）；禁止发送完整课表、时间、
  地点、学号、姓名、用户 ID 等可拼出个人画像的上下文。
- 请求组装在 C2（JobRequest 封闭类型），来源执行权威在 C1：自有 HTTP 由
  `HttpSourceClient` 执行，嵌入浏览器导航仅经 P WebView 适配器执行；C1 为出站
  内容权威，P 不组装来源请求。

### XC-09 launcher 白名单委派（归属 C5）

- C5 在委派前按 CT-C0-05 七主机精确匹配校验，通过后经 CT-P-04 交系统浏览器；
  白名单常量权威在 C0（单一维护点）。
- 任何不在清单内的 URL 一律不委派（fail-closed）。

### XC-10 调试资产边界（归属 P；A-4 整改补生命周期）

- 目录【冻结】：`debug/raw/<accountId>/<source>/<jobId>/`——**按账号分区**
  （首登 provisional 期间用 prospectiveAccountId；A-4 整改）；`meta.json`
  （jobId/时间/来源/ownership，无凭据字段）；**发布构建禁用**（release 编译开关，
  红线 2.1-3）。
- **生命周期【冻结，L5-06/L5-08】**：① 已绑定正式账号的资产默认**无限保留、
  不自动删除**；provisional 资产不享受无限保留——`meta.json` 标
  `ownership=provisional`，不得含 handle/凭据/认证上下文字段；meta 必须先以原子
  写入成功才允许落原始文件，缺失/损坏/未知 ownership 的目录在启动调和时按未认领
  资产物理删除（debug 资产可牺牲，隐私优先）；
  ② 手动清理入口 = C5 设置页（M5，与清缓存同区）；③ **completeReset 步骤 5.6
  `clearDebugAssets(accountId)`**（CT-P-05，幂等）清除该账号全部调试资产，
  失败保持 reset_pending=2 + 写屏障并返回 `reset_incomplete`，不得 finalizeReset；
  ④ 首登成功调用 `reconcileProvisionalDebugAssets(activeAccountId)` 提升匹配目录，
  失败/取消调用 `clearDebugAssets(prospectiveAccountId)`，崩溃后由启动门 reconcile，
  无正式账号认领者物理删除；⑤ 不进版本控制、不进发布产物（红线 2.1-3）。

### XC-11 数据保留与备份（归属 C3 迁移器；A-3 整改谓词唯一化）

- 迁移前备份：v7 库副本 → `backups/ustc_assistant_v7_<epochMs>.db`；备份成功
  才允许迁移（11 D-01 转移表 `backup_ok → migrating`）。
- **备份删除谓词【冻结，L5-03，唯一可执行】**：
  `manualDeleteAllowed = userConfirmed && age >= 30d && notAmongNewest3`
  ——同时满足"用户已确认"、"距迁移成功至少 30 天"、"不属于最近 3 份"才允许
  手动删除；**30 天后仍不自动删除**（无自动过期）。
- 缓存 TTL 汇总：icourse 24h（磁盘，P）；campus 目录 30min 节流/6h 过期；
  campus 详情/附件 30 天。**清理路径（A-2 整改）**：手动入口 = `clearCache()`
  （CT-C3-20，范围含 campus 三表+磁盘文件+icourse 缓存）；completeReset 在
  finalizeReset 事务前内部触发同一契约私有实现（10 §5 步骤 5.5）；文件删除
  失败保持 reset_pending=2，不提交 campus 三表删除、不删账号，幂等重试成功后才
  finalization（09 L2-21）。

### XC-12 附件管道（归属 C1 编排权威；P 执行；B-3 整改清单精确化）

- 限额【冻结，L5-04，代码核实】：
  - **扩展名白名单 8 个**：pdf/doc/docx/xls/xlsx/png/jpg/jpeg；
  - **MIME 值 7 个**：application/pdf、application/msword、
    application/vnd.openxmlformats-officedocument.wordprocessingml.document、
    application/vnd.ms-excel、
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet、
    image/png、image/jpeg（jpg 与 jpeg 同值）；
  - **判定语义【冻结】**：媒体类型以**扩展名→MIME 映射为准**（旧房语义）；
    Content-Type 仅作参考、不一致时以扩展名为准并审计；缺扩展名 → 拒绝下载；
    `application/octet-stream` 且无可用扩展名 → 拒绝；
  - 单附件/响应 **5MB** 上限（旧房 `max_response_bytes`）；目录分页 100 页/来源。
- 纪律：批 ≤3、链接跟随 ≤1 层（CT-C4-07 同源）；cache_key 等经内部登记载荷、
  永不进 Agent 上下文（09 §5.4 L2-17）。
- 跨介质补偿责任见 XC-04（B-6）。

### XC-13 会话资产与隔离（归属 C1 生命周期权威；P 执行）

- 浏览器运行时维护的全部认证状态保持不透明；应用代码不读明文，只经
  `BrowserAutomationPort`/`BrowserSessionAdminPort`（ADR-019 修订）。
- quarantine 持久标记存放位置【冻结】：平台会话适配器保存在受控分区旁（P 私有
  数据目录），不进 C3 业务库；清理成功前跨重启保留、禁止复用。
- 三语义跨平台（清理=物理删除、探测=健康状态、隔离=持久标记）三端一致，
  平台不对齐以能力矩阵声明（XC-14）。

### XC-14 平台能力矩阵（归属 P）

- 每适配器维护"平台 × 能力"声明矩阵；不对齐为声明性、可验收状态（08 §5.6）。
- **延期横切项指针（C-1 整改，防误读为遗漏；编号命名空间：`Dnn`=07 §3 决策表，
  `D-nn`=11 §3 组件登记表）**：深色模式 → 07 D22/M8；
  状态管理与 DI → 07 D20/D21/M5；关 App 后提醒可靠性 → 07 D28/M8；
  提醒协调器内部设计 → 11 D-16/M5。前三类为 07 双向门，本层不重开；
  D-16 是 11 待补组件设计项。

### XC-15 本地调试服务边界（归属 C2 编排权威；P 执行）

- 并存期 Bridge/回环传输仅绑定 127.0.0.1（09 CT-P-08，前层冻结项登记）；
  Bearer 握手；空闲超时与父进程存活检测照搬旧房语义；M7 随 Python 租户删除。
- 任何本地调试服务不得出现在发布构建（红线 2.1-3）。

### XC-16 Agent 运行可观测性（归属 C4；L5-07 拆分）

- C4 会话服务是 Agent 运行状态、error_code、token 计数、工具调用状态与
  MutationLedger 聚合语义的唯一权威；C2 不参与 Agent 推理/run 生命周期。
- `agent_runs` / `tool_invocations` 由 C4 经 C3 服务持久化，C5 聊天页/设置页消费；
  安全摘要与出站过滤仍分别指向 XC-05/XC-07，不在本项重写。
- 禁止把 source `sync_runs` 与 Agent `agent_runs` 合并成共享状态机；两者只共享
  稳定错误码和 C5 展示约定。

## 4. 本层拍板记录（L5 决策）

| 编号 | 决策 | 内容 | 依据 |
|---|---|---|---|
| L5-01 | 调试资产目录与落盘形式 | `debug/raw/<accountId>/<source>/<jobId>/` + meta.json（含 ownership、无凭据字段）；release 禁用 | 07 §2.5-19、红线 2.1-3 |
| L5-03 | 备份删除谓词 | `userConfirmed && age≥30d && notAmongNewest3`；30 天后仍不自动删除 | 11 §4.1 B-3、红线 2.2-7 |
| L5-04 | 附件限额与判定语义 | 扩展名 8 / MIME 值 7；扩展名映射为准、Content-Type 仅参考、缺扩展名拒绝；5MB；100 页 | 旧房代码核实（detail.py/teach.py/finance.py/service.py） |
| L5-06 | 正式账号调试资产生命周期 | 账号分区 + 无限保留不自动删除 + C5 手动入口（M5）+ completeReset 步骤 5.6 严格 clearDebugAssets（失败阻断 finalization） | 红线 2.1-3/5、09 L2-21 |
| L5-07 | 可观测性拆分 | XC-06 仅归 C2 source run；XC-16 仅归 C4 Agent run，不设共同权威 | 单一归属 gate + 真实运行链路，2026-08-15 用户批准 |
| L5-08 | provisional 调试资产 | 成功后提升正式归属；失败/取消物理删除；崩溃后启动 reconcile，无账号认领者删除 | ADR-023 修订 + CT-P-05/L2-21，2026-08-15 用户批准 |

**前层冻结项登记（非本层新拍板，B-2 整改移出；原 L5-02/L5-05 即这两项，
移出后编号留空）**：127.0.0.1 仅回环（09
CT-P-08）；DPAPI unprotect 两调用点（09 §3 C0 约束）——本层只登记与验收，
不属于 L5 新拍板参数。

> 拍板值分类说明（gate ③ 依据）：L5-04 为**代码核实值**；L5-01/03/06 为
> **移交授权设计值**（07 §2.5 或 11 移交明确授权本层决定）；L5-07/08 为整改复审
> 中用户批准的权威拆分与生命周期收口；无凭空值。

## 5. 第 5 层 gate 检查表

- [x] ① 登记表 16 项每项有且仅有一个单一归属（决策权威唯一且位于真实运行链路
      上；能力方/执行方全部列消费者列）
- [x] ② 每项可溯源：承接自列指向 07 §2.5 移交项编号或 CT/ADR 编号
- [x] ③ 本层新冻结的参数值/语义（L5-01/03/04/06/07/08）全部有代码、既有决策
      或用户明确批准依据；
      前层冻结项单独登记、不混入 L5 新拍板
- [x] ④ 与前五层无重复定义、无语义漂移（clearCache/completeReset/provisional
      debug 与 07 ADR-023、09 L2-21、10 L3-06、11 L4-04 一致）
- [x] ⑤ 移交登记闭环：07 §2.5 四项（→ XC-01/02/10/15）+ 附件细节（→ XC-12）
      + 11 数据保留移交（→ XC-11）共六节全部有对应节
- [x] **gate 关闭条件（2026-08-15 最终复审 + 整改 bd3bec7 + 用户重认）**：
      第 0–5 层全部关闭，进入第 6 层
      `13-risks-and-acceptance.md`（风险登记册，设计阶段最后一张图纸）
