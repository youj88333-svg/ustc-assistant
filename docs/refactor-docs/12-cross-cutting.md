# 12 横切关注（六层阶梯 · 第 5 层）

> 产出日期：2026-08-14 ｜ 状态：**草稿（待审查）**
> ｜ 依据：`07-constitution.md`（§2.5 移交登记 → 本层 4 项 + 附件管道细节）、
> `09-contracts.md`（CT 65 条、§2.4 错误码）、`10-runtime.md`、`11-component-designs.md`、
> 01–06 模块文档与 main 代码（参数以代码为准，已核实）

## 1. 本层目标与 gate

- 目标：把横切关注（时区、隐私、账号隔离、事务、审计、可观测性 + §2.5 移交的
  调试资产/调试服务/附件管道/零化约束 + 第 4 层移交的数据保留策略）收敛成
  登记表，**每项有单一归属**——一个关注点只有一个决策权威，其余容器只是消费者。
- 本层不重复前四层已冻结的规则，只做三件事：① 登记与溯源（承接自哪个移交项/
  CT/ADR）；② 给尚未有归宿的实施细则定单一归属；③ 冻结本层才拍板的参数值。
- **gate：登记表每项有且仅有一个单一归属；每项可溯源到移交项或 CT/ADR；
  本层新冻结的参数值全部有代码或既有决策依据（无凭空值）。**

## 2. 横切关注登记表（gate 工件）

| ID | 关注点 | 单一归属 | 主要消费者 | 承接自 |
|---|---|---|---|---|
| XC-01 | 时区与时间 | C0 `BeijingClock` + `core/time` 工具箱 | 全部容器 | ADR-015 + 09 §2.1 线协议例外（07 §2.5 移交项 4） |
| XC-02 | 凭据与密钥安全 | C3 账号凭据服务（仓库/解密）；C0 端口（保护能力）；C2（租约流转） | C1/C4/C5 | ADR-019/020 + 07 §2.5 移交项 18（Dart 零化） |
| XC-03 | 账号隔离 | C3（表纪律 + 单账号模型） | C2/C4/C5 | 07 §2.5 移交项 3 + ADR-004 |
| XC-04 | 事务边界 | C3（写服务统一契约 + 生命周期事务） | C4 网关（Agent 四日志） | CT-C3-07/CT-C4-05 + ADR-023 |
| XC-05 | 审计 | C3 Audit 子域（ActionLogRepository） | 全部写路径 | CT-C3-07 + 红线 2.1-5 |
| XC-06 | 可观测性 | C2（事件流转播/账本）+ C1（八相位/safeCount 产出） | C4/C5 | ADR-005 + CT-C1-01/CT-C3-21 |
| XC-07 | 隐私过滤与出站最小化 | C4（OutboundPrivacyFilter）+ C0（七主机白名单） | C1/C2 | 红线 2.1-2 + CT-C0-05/CT-C1-04 |
| XC-08 | 调试资产边界 | P `FileStoragePort`（私有目录与落盘形式） | C1/C3/调试基建 | 07 §2.5 移交项 19（--save-raw） |
| XC-09 | 数据保留与备份 | C3 迁移器（备份动作）+ 本层冻结保留策略 | C5 设置页 | 红线 2.2-7 + 11 §4.1 B-3 移交 |
| XC-10 | 附件管道 | C1 `AttachmentContentConverter`（编排/限额）+ P（文件/decoder） | C4/C3 | 07 §2.5 移交项 16 + CT-C1-05 |
| XC-11 | 会话资产与隔离 | C1 `WebSessionEngine` + P 会话适配器 | C2（维护流） | ADR-019 修订 + CT-P-02 |
| XC-12 | 平台能力矩阵 | P（声明性对齐） | C0/C1/C3/C5 | 红线 2.2-8 + 08 §5.6 |
| XC-13 | 本地调试服务边界 | C2（并存期编排）+ P（回环传输） | 调试基建 | 07 §2.5 移交项 20 + 09 CT-P-08 |

## 3. 各关注点细则（只写本层新增/参数冻结；已冻结规则只登记溯源）

### XC-01 时区与时间（归属 C0）

- 铁律：存储/进程内传输一律 epoch ms；业务解释唯一 Asia/Shanghai（固定 UTC+8）；
  线协议信封（SourceBundle/QueryResult）维持 +08:00 ISO-8601（09 §2.1，L2-16 修订）。
- `BeijingClock.now()` 是"当前时刻"唯一来源（freshness/审计/租约戳/权限策略共用）。
- 禁止事项：任何模块不得自行拼装时区语义、不得读取系统时区做业务解释。

### XC-02 凭据与密钥安全（归属 C3/C0/C2 三权分立）

- 三类资产三类边界（ADR-019）：显式凭据密文（C3 仓库 + C0 保护端口）/ 浏览器
  会话资产不透明（XC-11）/ 临时明文尽力零化。
- **Dart String 不可变 → "绝对零化"不可承诺**【冻结，07 §2.5 移交项 18】：
  临时明文（解密密码/租约秘密）只声明"最短存活 + 尽力零化 + 永不落日志"，
  采 Bitwarden 式诚实措辞（ADR-019 修订）；实现纪律：明文只存在于
  `takePassword()` 返回值与填表调用栈，用后立即出作用域。
- **DPAPI 调用点登记制**【冻结】：
  `CredentialProtector.unprotect` 仅允许两处调用——① C3 账号凭据服务
  （租约申请时）；② C4 `ProtectedAgentSecretStore`（Key 加载）。M1/M6 实现时
  以 grep 可核查的调用点清单验收（新增调用点必须回写本文件）。

### XC-03 账号隔离（归属 C3）

- 单账号模型（ADR-004）：任意时刻至多一个学校账号；换账号 = completeReset。
- 表纪律：业务表 `account_id → local_accounts ON DELETE CASCADE`；
  `source_records.import_batch_id` RESTRICT、`sync_runs.import_batch_id` SET NULL
  （09 §7.1）；撤销槽 accountId 校验（他账号槽绝不删改，D-04）。

### XC-04 事务边界（归属 C3）

- 写服务统一契约（CT-C3-07）：乐观锁 TOCTOU 复验 → 业务写 + ActionLog + Undo
  快照同事务 → 任一失败整体回滚。
- 来源写事务（A-2 整改强化）：subject/activeAccountId/stamp 复验、幂等查询与
  业务写入**同一数据库事务、同一调用栈**（11 D-02 不变量）。
- Agent 写四日志同事务（CT-C4-05）：业务提交 + agent 业务日志 + 用户确认日志 +
  权限变更同一 Drift 事务；SQLite fault-injection 回归验证保留（M1/M6 测试清单）。
- 生命周期事务：commitFirstLogin 单事务、finalizeReset 幂等单事务、
  clearBusinessData 屏障事务（CT-C3-03/05/06）。

### XC-05 审计（归属 C3 Audit 子域）

- `action_logs` 唯一审计表；`safe_summary` 只存安全摘要（无 id/ref/原文）；
  三来源：`user`（用户操作）/ 来源键（导入）/ `agent`（每次 run 恰好一条
  read_only_run 汇总 + 写确认流）/ `system`（设置与维护）。
- 读侧：`HistoryRepository.query`（上限 50、正则脱敏）；v8 #3 索引
  `(account_id, occurred_at)`。
- Agent 侧补充账本：`tool_invocations.safe_arguments_summary/safe_result_summary`
  + `MutationLedger` 聚合计数（只含计数与白名单错误码）。

### XC-06 可观测性（归属 C2/C1）

- 作业可观测：八相位事件流（sequence/safeCount/终态载荷）——**流内只含安全
  计数，凭据/原始数据永不进流**（红线 2.1-1 的机械保障）。
- 账本可观测：`sync_runs` 六值 + trigger 四值（CT-C2-05/06）；`source_configs`
  的 last_success_at/retry_after/source_generation。
- UI 可观测：C3 drift watch 流广播（activeAccountChanges 等）+ C5 订阅自动刷新。
- 隐私边界复查点：新增任何事件字段前先过"是否安全计数级"审查。

### XC-07 隐私过滤与出站最小化（归属 C4/C0）

- 双防线：① `OutboundPrivacyFilter` 逐工具白名单构建器（主防线）；② 兜底
  redaction（db_id/cookie 等敏感键后手拦截）。写工具结果只含统一安全摘要白名单。
- QueryResult 封闭字段集 + references 白名单（CT-C0-05 七主机精确匹配）；
  校验失败 `result_validation_failed` 不进对话。
- 出站最小化（红线 2.1-2）：评课联动只发送必需检索词；出站请求只携带完成查询
  所必需的最少字段；首次联网前告知并授权。

### XC-08 调试资产边界（归属 P；07 §2.5 移交项 19）

- 目录【冻结】：平台私有数据目录下 `debug/`（P `FileStoragePort` 提供句柄），
  具体绝对路径由 P 解析（Windows：`%LOCALAPPDATA%\ustc_assistant\debug\` 语义）。
- `--save-raw` 落盘形式【冻结】：`debug/raw/<source>/<jobId>/`，原始响应
  UTF-8 文本 + `meta.json`（jobId/时间/来源，无凭据字段）；**发布构建禁用**
  （release 编译开关关闭，红线 2.1-3）。
- 纪律：debug/ 不进版本控制、不进发布产物；完整清单在 `12-cross-cutting.md`
  本节冻结，其余目录（缓存/备份见 XC-09/XC-10）各有归宿。

### XC-09 数据保留与备份（归属 C3 迁移器 + 本层策略；11 §4.1 B-3 移交）

- 迁移前备份【冻结】：v7 库副本 → `backups/ustc_assistant_v7_<epochMs>.db`
  （P 私有数据目录）；备份成功才允许迁移（D-01 不变量）。
- **备份保留策略**【冻结，L5 拍板】：保留最近 **3 份**；迁移成功后由用户确认
  后清理，或至少保留 **30 天**；**不自动过期删除**（B-3 整改）；手动清理入口
  在 C5 设置页（M5）。
- 缓存 TTL 汇总（各归属处已冻结，此处登记）：icourse 24h（磁盘，P）；campus
  目录 30min 节流/6h 过期（SQLite 表 + CT-C2-08）；campus 详情/附件 30 天
  （磁盘 + `campus_attachment_cache` 索引）；`clearCache()`（CT-C3-20）为
  唯一清理入口。

### XC-10 附件管道（归属 C1 编排 + P 平台；07 §2.5 移交项 16）

- 限额【冻结，代码核实】：**单附件/响应 5MB**（旧房 `max_response_bytes =
  5*1024*1024`）；**MIME 白名单 7 种**（pdf/doc/docx/xls/xlsx/png/jpg/jpeg，
  旧房 `ATTACHMENT_MEDIA_TYPES` 两侧一致）；目录分页上限 **100 页/来源**。
- 纪律：批 ≤3、链接跟随 ≤1 层（CT-C4-07 同源）；内容转换编排在 C1、文件系统/
  decoder/临时目录在 P；C3 只存索引（cache_key 等经 `AttachmentCacheRegistration`
  内部载荷，永不进 Agent 上下文——09 §5.4 L2-17）。

### XC-11 会话资产与隔离（归属 C1/P）

- 浏览器运行时维护的全部认证状态（Cookie/Storage/IndexedDB/缓存/SW/认证 header/
  WebAuthn 引用）保持不透明；应用代码不读明文，只经
  `BrowserAutomationPort`/`BrowserSessionAdminPort`（ADR-019 修订）。
- **quarantine 持久标记存放位置**【冻结】：平台会话适配器保存在受控分区旁
  （P 私有数据目录），**不进 C3 业务库**；标记在清理成功前跨重启保留、禁止复用。
- 三语义跨平台（清理=物理删除、探测=健康状态、隔离=持久标记）三端一致，
  平台不对齐以能力矩阵声明（XC-12）。

### XC-12 平台能力矩阵（归属 P）

- 每适配器维护"平台 × 能力"声明矩阵（如"清理=物理删除"Windows ✅/移动端 D29
  待实现）；不对齐为**声明性、可验收**状态（08 §5.6）。
- Windows 实现：WebView2 UserDataFolder 卡槽、DPAPI、前台通知、launcher、
  文件/decoder；移动端（D29 后）：平台 WebView + JS、Keychain/Keystore。

### XC-13 本地调试服务边界（归属 C2/P；07 §2.5 移交项 20）

- 并存期 Bridge/回环传输**仅绑定 127.0.0.1**（09 CT-P-08 已冻结）；Bearer
  握手；空闲超时与父进程存活检测照搬旧房语义；M7 随 Python 租户删除。
- 任何本地调试服务不得出现在发布构建（红线 2.1-3）。

## 4. 本层拍板记录（L5 决策）

| 编号 | 决策 | 内容 | 依据 |
|---|---|---|---|
| L5-01 | 调试资产目录与落盘形式 | `debug/raw/<source>/<jobId>/` + meta.json；release 禁用 | 07 §2.5-19、红线 2.1-3 |
| L5-02 | 本地调试服务地址 | 仅 127.0.0.1（并存期 Bridge） | 07 §2.5-20、09 CT-P-08 |
| L5-03 | 备份保留策略 | 最近 3 份 + 迁移成功 ≥30 天、不自动过期、C5 手动清理（M5） | 11 §4.1 B-3、红线 2.2-7 |
| L5-04 | 附件限额冻结 | 5MB/单附件、MIME 白名单 7 种、目录分页 100 页 | 旧房代码核实（detail.py/teach.py/finance.py/service.py） |
| L5-05 | DPAPI 调用点登记制 | unprotect 仅 C3 凭据服务 + C4 Key 加载两处；新增调用点回写本文件 | ADR-019、XC-02 |

## 5. 第 5 层 gate 检查表

- [ ] ① 登记表 13 项每项有且仅有一个单一归属（§2 表"单一归属"列无多项并列、
      无空缺）
- [ ] ② 每项可溯源：承接自列指向 07 §2.5 移交项编号或 CT/ADR 编号（§2 表核对）
- [ ] ③ 本层新冻结的参数值（L5-01~05）全部有代码或既有决策依据（§3 各节注明）
- [ ] ④ 与前四层无重复定义：本文件只登记溯源或补实施细则，不重写已冻结规则
- [ ] ⑤ 移交登记闭环：07 §2.5 中标注"→ `12-cross-cutting.md`"的 4 项 +
      附件管道细节 + 11 的数据保留移交，在本文件全部有对应节（XC-02/08/10/13/09）
- [ ] **gate 关闭条件**：独立审查通过 → 六层阶梯设计全部完成，进入第 6 层
      `13-risks-and-acceptance.md`
