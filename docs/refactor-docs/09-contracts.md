# 09 全局契约（六层阶梯 · 第 2 层）

> 产出日期：2026-08-14 ｜ 状态：**第 2 层已关闭（2026-08-14；L2-01~16：逐项拍板 + 两轮独立审查整改 + 第 3 层审查回写 L2-15/16）**
> ｜ 依据：`07-constitution.md`（§2.5 移交登记、ADR-000~023、D32–D37）、
> `08-target-architecture.md`（§5 各容器对外接口预告、§7 五链路、§9 移交映射）、
> 01–06 模块文档与 main 代码（签名与字段以代码为准，已逐项核实）

## 1. 本层目标与 gate

- 目标：把第 1 层的"对外接口预告"升级为**正式接口签名**（Dart 风格签名 + 生产者/
  消费者 + 错误语义 + 事务边界）；冻结 schema v8 变更集清单（ADR-011）；消化 §2.5
  移交登记中归属本层的 16 项与双向门 D32/D33/D34/D35/D37 的契约面。
- 不包含：组件级状态机（第 4 层 `11-component-designs.md`）、横切实现细则
  （第 5 层 `12-cross-cutting.md`）、UI 细节（M5）。
- **gate：① 每个接口有生产者和消费者（§11 契约矩阵机械检查）；② 无孤儿字段——
  schema v8 变更集每个新增/保留字段有明确写方与读方（§7.2）；③ v8 变更集清单冻结，
  冻结后新增变更必须开 ADR 修正（ADR-011）；④ §2.5 移交登记 16 项全部消化（§12）；
  ⑤ D32/D33/D34/D35/D37 契约面全部落地（§6.5/§7.2/§7.7/§8.6/§13）。**

## 2. 契约符号与全局语义基元

### 2.1 符号约定

- 签名统一为 Dart 风格；`Future<T>`=异步返回、`Stream<T>`=事件流、`void`=同步。
- **时间铁律（ADR-015 + L2 整改修订 A-1）**：契约字段与签名中的时间一律
  **epoch 毫秒 INTEGER**（UTC 语义）；例外两类：① `YYYY-MM-DD` 文本日期
  （全天事件锚点、学期内日期类字段）；② **已发布线协议信封的兼容例外**——
  SourceBundle 1.0 与 QueryResult 1.0 信封内的时间字段（collectedAt/generatedAt
  及 bundle 数据时间字段）维持发布时的 **+08:00 ISO-8601** 线格式，C1 产出 /
  C3 解码边界完成换算，进程内存与数据库一律 epoch ms。"今天/明天/星期几/第几周/
  几点"的一切解释只按 Asia/Shanghai（固定 UTC+8）。
- **错误模型**：契约错误一律为**稳定错误码**（`String code` + 固定 safeMessage，
  不回显源内容、防注入回显）；未知码按 fail-closed 归一（§2.4）。
- **隐私边界（红线 2.1 原则 1 的契约化）**：任何事件流、JobEvent、审计
  safeSummary、工具 payload、出站请求均不得携带显式凭据明文、浏览器会话明文资产、
  DB id/ref 之外的原始数据；凭据只经 `CredentialLease` 一次性流动（§6.3）。
- 稳定性标注：**【冻结】**=本层定死，修改须开 ADR 修正；**【基线】**=照搬现状值，
  实施期可调但必须同步修订本文件；**【并存期】**=M7 随 Python 租户删除。

### 2.2 时间源（BeijingClock）

- `BeijingClock`（C0）：`int now()`——全应用"当前时刻"唯一来源（freshness
  判定、审计 occurred_at、租约戳校验共用）；`core/time` 工具箱：epoch ms ↔
  Asia/Shanghai（固定 UTC+8）解释/格式化唯一实现，任何模块不得自行拼装时区
  语义（ADR-015）。正式签名与生产者/消费者见 §3 CT-C0-01/CT-C0-02
  （本段为语义摘要，不重复编号，L2 整改 B-2）。

### 2.3 租约戳 LeaseStamp（ADR-004/016 修订）

- `LeaseStamp` 不可变值对象（C0 定义，供 C2/C3/C4 共用；正式签名见 §3
  CT-C0-03，本段为语义摘要，L2 整改 B-2）：

```dart
class LeaseStamp {
  final String jobId;           // 作业唯一 id
  final String accountId;       // 活动账号
  final String source;          // 来源键（ustc_jw / ustc_young_schedule / …）
  final ChannelKind channelKind; // native | python（并存期）
  final int sourceGeneration;   // 通道切换/取消/reset/clearBusinessData 时递增
  final int resetEpoch;         // C3 beginReset 时递增（起点 0）
}
```

- 生产者：C2（启动作业时组装）。消费者：C2（终态接收与跨容器交接校验）、C3
  （所有来源派生写事务内复验：normal 导入、首登提交、重新认证提交、campus 目录提交）。
  `SourceJobHandle` 显式携带同一 `LeaseStamp`，不得靠 `jobId` 反查或调用方上下文猜测。
  **迟到拒绝**：校验失败返回稳定错误码 `stale_lease`，不得写库、不得进对话。
- **sourceGeneration 权威在 C3**（A-7 整改）：持久于 `source_configs.
  source_generation`（v8 #7）；C2 经 C3 同步状态服务递增（通道切换/取消/reset/
  clearBusinessData 时），C3 导入/写入事务内与库内值比对——消灭"预检-提交"
  之间的 TOCTOU；resetEpoch 权威在 C3（`local_accounts.reset_epoch`，v8 #6）。

### 2.4 统一错误码表（全容器共用）

**作业/同步级**【冻结】：

| 错误码 | 语义 | 备注 |
|---|---|---|
| `cancelled` | 用户/系统取消 | 终态，非错误 |
| `account_mismatch` | 登录后身份与预期不符（三层核验缺一） | ADR-003 |
| `identity_mismatch` | 重新认证 digest 不匹配 | ADR-023 ② |
| `collection_failed` | 采集失败 | 作业终态 |
| `query_failed` | 查询失败 | 作业终态 |
| `result_validation_failed` | 结果未过安全校验（bundle/QueryResult） | 不出站、不落库 |
| `catalog_unavailable` | campus 目录缺失且无法刷新 | 明确失败，不带部分数据 |
| `stale_lease` | 租约戳过期/迟到结果 | 稳定拒绝，不写库（ADR-004） |
| `busy` | 全局来源作业租约被占 | 旧房 `bridge_busy`/`bridge_query_busy` 废止，进程内统一 `busy` |
| `maintenance_in_progress` | 维护独占门关闭期间的新作业/新写被拒 | 稳定拒绝（A-8 整改补码；UI 提示"维护进行中"） |
| `no_account` | 无活动账号 | 同步前置 |
| `fresh_or_backoff` | freshness/退避窗口内跳过 | 非错误（skip） |
| `reauthentication_required` | 凭据缺失需重新认证 | 旧房 `credentials_not_found` 的归一 |
| `first_login_failed` / `reauthentication_failed` | 首登/重认证流程失败 | |
| `job_not_found` | 作业句柄失效（cancel/resume 时） | ADR-022：跨重启一律作废 |

**导入级**【冻结，9 个 SourceBundle 错误码，§5.3 详表】。
**本地写级**【冻结】：`invalid_write_arguments` / `permission_denied` /
`user_declined` / `confirmation_not_found` / `write_commit_failed` /
`stale_target` / `target_not_found` / `already_active` / `already_deleted` /
`invalid_lifecycle_transition` / `relation_not_found` / `relation_state_mismatch` /
`relation_lookup_requires_bound` / `no_undo_available` / `invalid_undo_command` /
`repeated_tool_call` / `tool_not_allowed` / `tool_execution_failed`。

- **fail-closed 归一**：未知码一律映射稳定兜底码（同步→`sync_failed`、
  查询→`query_failed`、写→`write_commit_failed`、桥接→`request_failed`），
  错误消息固定文案、不回显源内容。**兜底码本身纳入注册表**（B-3 整改）；另纳入
  前置校验码 `no_account` / `fresh_or_backoff` / `complete_semester_required`
  （学期三元组不完整，CT-C3-15）——注册表闭合，任何新码先入表再用。

## 3. C0 共享核心契约

| ID | 契约 | 生产者 | 消费者 |
|---|---|---|---|
| CT-C0-01 | `BeijingClock.now() → int`（epoch ms） | C0 | C1/C2/C3/C4/C5 |
| CT-C0-02 | `core/time` 工具箱（epoch ↔ Asia/Shanghai 唯一实现） | C0 | 全部容器 |
| CT-C0-03 | `LeaseStamp` 值对象 | C0 | C2/C3/C4 |
| CT-C0-04 | `CredentialProtector` 端口：`protect(Uint8List) → ProtectedSecret{bytes, scheme, version, metadata}`；`unprotect(ProtectedSecret) → Uint8List` | 端口=C0 定义；实现=P（DPAPI/Keychain/Keystore） | C3 账号凭据服务、C4 `ProtectedAgentSecretStore` |
| CT-C0-05 | `OfficialSiteAllowlist` 常量：可信主机清单（**精确 host 匹配，无子域通配**）：`jw.ustc.edu.cn` / `young.ustc.edu.cn` / `id.ustc.edu.cn` / `icourse.club` / `teach.ustc.edu.cn` / **`www.teach.ustc.edu.cn`**（教务处目录真实入口，旧房 `_TRUSTED_HOSTS` 即含，L2-09 修订 B-6）/ `finance.ustc.edu.cn` | C0 | C5 launcher 校验、C4 QueryResult references 校验（共用同一清单） |
| CT-C0-06 | 稳定错误码注册表 + fail-closed 归一函数 | C0 | 全部容器 |

**约束**【冻结】：
- C0 零依赖（不引用 Flutter Widget / dart:io / 任何容器）；C0 不持有凭据仓库
  （CredentialProtector 只是加解密能力，凭据仓库在 C3，ADR-020/审查 C-2）。
- `unprotect` 调用点登记制：仅 C3 凭据服务（租约申请时）与 C4 Key 加载
  （ProtectedAgentSecretStore）可调用；其他模块不得持有 decrypt 出口
  （横切细则归 `12-cross-cutting.md`）。

## 4. 平台端口契约（P 边界）

| ID | 契约（签名） | 生产者 | 消费者 |
|---|---|---|---|
| CT-P-01 | `BrowserAutomationPort`（C1 定义，P 实现）：`navigate(url)` / `waitForUrl(pattern, timeoutMs)` / `waitForSelector(sel, timeoutMs)` / `click(sel)` / `fill(sel, value)` / `executeExtraction(scriptId, args) → Map`（仅登记脚本；返回值经 schema 与敏感键检查） | P 实现 | C1 WebSessionEngine + 适配器 |
| CT-P-02 | `BrowserSessionAdminPort`（C1 定义，P 实现）：`open(accountId) → SessionPartitionRef`（不透明） / `probe(ref) → SessionHealth{healthy, needsLogin, unknown}` / `close(ref)` / `clearPartition(ref) → bool`（真删除）/ `markQuarantine(ref, reason)` / `isQuarantined(accountId) → bool`（持久标记，清理成功前跨重启禁复用） | P 实现 | C1 WebSessionEngine（日常）、C2 维护流（经 C1 门面清会话） |
| CT-P-03 | `NotificationPort`：`show(title, body, {scheduleAt})` / `cancelAll()` | P 实现 | C3 提醒协调 |
| CT-P-04 | `LauncherPort`：`launchExternal(Uri)`——**白名单校验在 C5**，P 只执行 | P 实现 | C5 官方网页 |
| CT-P-05 | `FileStoragePort`：`privateDir()` / 附件缓存目录 / 迁移备份目录句柄（具体路径归 `12-cross-cutting.md` §调试资产） | P 实现 | C1 附件转换、C3 迁移器 |
| CT-P-06 | `PlatformDecoderPort`：`decode(bytes, mediaType) → StructuredContent` | P 实现 | C1 AttachmentContentConverter |
| CT-P-07 | `PythonProcessPort`【并存期】：`start()` / `stop()` / `health()` | P 实现 | C2 核心（编排 Python 租户） |
| CT-P-08 | `LoopbackBridgeTransportPort`【并存期】：`request(endpoint, payload) → response`（仅 127.0.0.1 + Bearer 握手） | P 实现 | C2 核心 |

**跨平台契约**【冻结】（三端替换点，红线 2.2-8）：P 能力矩阵每项声明性对齐——
"清理=物理删除、探测=健康状态、quarantine=持久隔离标记"三语义三端必须一致；
平台不对齐时以能力矩阵显式声明（ADR-002/019）。CT-P-01/02 **不公开**
cookies/storage/认证 header 或任何敏感明文取值（ADR-019 修订）。

## 5. C1 采集引擎契约

### 5.1 作业事件流 JobEvent（ADR-005）

- **CT-C1-01**【冻结】：`Stream<JobEvent>` 热流，事件形态：

```dart
class JobEvent {
  final int sequence;            // 从 1 严格递增
  final JobPhase phase;          // 八相位
  final int? safeCount;          // 仅安全计数；凭据/原始数据永不进事件流
  final JobTerminalPayload? result; // 仅 phase == complete（类型化终态，A-2 整改）
  final JobError? error;         // 仅 failed/cancelled 终态（code + 固定文案）
}
enum JobPhase { starting, checkingSession, waitingForUser, collecting,
                needsUserLogin, complete, cancelled, failed }
sealed class JobTerminalPayload {}        // 终态联合体：生产者/消费者可据此独立实现
class CollectionCompleted extends JobTerminalPayload {
  final Uint8List bundleBytes;            // SourceBundle 1.0 字节
  final String? verifiedUsername;         // CAS 三层核验产物（首登/重认证携带）
  final SemesterTriple? selectedSemester; // 仅 jw 采集且无持久选择（首登）时：
                                          // C1 登录后抓列表+月份规则实际选中的完整
                                          // 三元组（A-6 整改：displayName 不入 Bundle）
}
class QueryCompleted extends JobTerminalPayload {
  final QueryResultEnvelope result;       // 经安全校验的 1.0 信封
  final String? verifiedUsername;         // 仅 young_enrolment 可能携带
  final List<AttachmentCacheRegistration>? attachmentRegistrations;
                                          // 仅 campus_detail 作业：C1 内部登记载荷
                                          // （A-2 整改：正式载体=C1→C2→C4 内部传递，
                                          // 永不进 Agent 上下文）
}
```

- 语义：needs_user_login = 暂停态（elicitation 模型，ADR-016）——恢复同一作业、
  同一流、sequence 连续；热流支持新订阅者重放最近事件（v2 分支事件顺序教训）。
- 生产者：C1（Native）/ Python 通道（并存期，经 P→C2 转换）。消费者：C2（仲裁与
  校验）、C4/C5（经 C2 暴露的 handle）。

### 5.2 作业执行接口（C2 → C1）

- **CT-C1-02**【冻结】：

```dart
abstract interface class JobExecutor {          // C1 对 C2 的执行面
  Stream<JobEvent> startCollection(SourceJobSpec spec);
  Stream<JobEvent> runQuery(SourceJobSpec spec);
  Future<void> cancel(String jobId);            // 协作式；暂停态立即终态
  Future<void> resumeLogin(String jobId, CredentialLease lease);
  Future<SessionHealth> probeSession(String accountId);
}
class SourceJobSpec {                            // 与 LeaseStamp 同构 + 类型化请求
  final LeaseStamp stamp;
  final JobMode mode;                            // collection | query
  final bool interactive;                        // 交互登录许可（ADR-003）
  final CredentialLease? credentialLease;        // 启动时含 expectedUsername；
                                                 // 密码仅恢复时附带（ADR-020）
  final JobRequest request;                      // 类型化请求联合体（A-2 整改）
}
sealed class JobRequest {}                       // 由 C2 组装：C2 从 C3 读配置
                                                 // （学期三元组等），C1 不依赖 C3
class JwCollectionRequest extends JobRequest {
  final SemesterTriple? semester;                // sourceConfigs.configJson（CT-C3-15）；
                                                 // null = 无持久选择（首登，source_configs
                                                 // 行尚不存在）：登录后抓学期列表 + 月份
                                                 // 规则默认（ADR-009）；非 null 用持久选择
}
class YoungScheduleCollectionRequest extends JobRequest {
  // 日期窗口由 C2 按 BeijingClock 计算后传入（北京时间滚动窗口语义照搬）
  final List<String> queryDates;                 // YYYY-MM-DD 列表
}
class YoungEnrolmentQueryRequest extends JobRequest {
  // 无参数：范围=当前报名中活动列表（身份载体=租约戳+expectedUsername）
}
class IcourseQueryRequest extends JobRequest {
  final String course;
  final List<String> teachers;                   // 可为空
  final Map<String, String>? preferences;
}
class CampusSearchQueryRequest extends JobRequest {
  final String query;
  final Map<String, String>? filters;
  final int limit;                               // 1..100
}
class CampusDetailQueryRequest extends JobRequest {
  final String entryId;                          // campus_ 前缀稳定身份
  final List<String> followLinkIds;              // link_ 前缀，≤1 层（CT-C4-07）
}
```

- 约束【冻结】：C1 不依赖 C3（凭据经租约注入）；C1 不写库（deliver 产物经 C2
  交接 C3）；C1 不知道 Python 通道；C1 不持全局作业权威（C2 唯一仲裁）。

### 5.3 SourceBundle 1.0（正式冻结）

- **CT-C1-03**【冻结】信封（canonical = `schemas/source-bundle-1.0.schema.json`
  draft 2020-12；Draft-7 导出副本 = `app/assets/schemas/source-bundle-1.0.draft7.schema.json`；
  **双方言同步**：改 schema 必须同时改两副本 + 双方 producer/consumer 共用 fixture
  契约测试）：

```json
{
  "schemaVersion": "1.0",
  "bundleId": "<uuid>",
  "source": "ustc_jw | ustc_young_my_schedule",
  "subject": { "accountId": "..." },
  "collectedAt": "<北京时 +08:00 ISO-8601>",
  "producer": "<可选>",
  "snapshot": { "completeness": "complete", "scope": { } },
  "manifest": { "sourceRecordCount": 0, "calendarEventCount": 0,
                "courseSeriesCount": 0, "scheduleRelationCount": 0 },
  "data": { "sourceRecords": [], "calendarEvents": [],
            "courseSeries": [], "scheduleRelations": [] }
}
```

- **digest**【冻结】：`sha256(canonicalJson(bundle))`（键排序规范 JSON，两语言同算法）。
- **幂等**【冻结】：`UNIQUE(account_id, bundle_id)` + `UNIQUE(account_id, digest)`；
  同 bundleId 同 digest → `replayed`；同 bundleId 异 digest → `duplicate_identity`。
- **无主键**【冻结】：bundle 不含本地 DB id；身份 = 稳定外部身份
  （`source + externalId`），本地 id 由导入端分配并在复导时复用（03 §3.1）。
- **presence 三态**【冻结】：`observed` / `outside_scope` / `missing_within_scope`；
  导入 = **完整快照对齐**（非增量合并）；`missing_within_scope` 被有效事件流过滤。
- **范围**【冻结】：SourceBundle **只用于** jw + young-schedule 两条完整快照链路；
  报名/评课/校园走 QueryResult（§5.4）；一 Bundle 一账号一来源一范围一事务。
- **上限**【冻结】：16MB、嵌套深度 64、敏感键片段 11 类拒绝
  （authorization/browserprofile/contextid/cookie/credential/password/
  profilepath/sessionid/studentid/token/userid）。
- **错误码表**【冻结，9 个——02/03 文档所记"10 个"为笔误，以代码
  `source_bundle_error.dart`/`source_bundle_validation.py` 为准】：

| code | 语义 |
|---|---|
| `unsupported_version` | 版本不受支持 |
| `invalid_envelope` | 信封非法 |
| `incomplete_snapshot` | 快照不完整 |
| `subject_mismatch` | 属于其他账号 |
| `count_mismatch` | manifest 计数不一致 |
| `duplicate_identity` | 身份重复 |
| `dangling_reference` | 引用悬空 |
| `invalid_time` | 时间范围非法（+08:00 约束） |
| `limit_exceeded` | 超过契约上限 |

- 生产者：C1 五适配器中的 jw/young-schedule（Native）；并存期 Python 通道（M7 删）。
  消费者：C3 ImportService（经 C2 交接 + 租约戳校验）。

### 5.4 QueryResult 1.0（安全载体，ADR-016）

- **CT-C1-04**【冻结】信封：`schemaVersion(1.0)` / `queryType` / `generatedAt`
  （北京时 +08:00）/ `data` / `metadata` / `references`。
  `queryType ∈ {young_enrolment, icourse, campus_search, campus_detail}`。
- 约束【冻结】：单字符串 ≤ 8000 字符；敏感键拒绝；young_enrolment 私有字段拒绝；
  references 仅 CT-C0-05 白名单主机的 https URL；data/metadata 内 URL 必须属于
  references；拒绝 raw HTML。校验失败 → `result_validation_failed`，不进对话。
- **凭据边界**【冻结】：仅 `young_enrolment` 可进入 needs_user_login 并接受凭据租约；
  icourse/campus 公开查询从不接收凭据；young_enrolment 的身份载体是租约戳 +
  expectedUsername（旧房 Query Protocol 的 accountId 字段废止）。
- 生产者：C1 QueryJob（Native）/ Python 通道。消费者：C4 外部只读工具（经 C2
  校验）；**campus 目录例外**——campus_search 刷新结果经 C4 交 C3 CatalogService
  upsert 后再做本地搜索，campus_detail 的附件索引亦经同一带 stamp 入口登记；
  QueryResult 信封本体不落库（ADR-007/08 §7.2）。
- campus 查询参数【冻结】：`campus_search{query, filters?, limit:1..100}`；
  `campus_detail{entryId, followLinkIds?}`；任何层级出现 URL/文件系统字段名即拒绝
  （fail-closed，02 §4.1-B 语义照搬）。时间字段线格式例外见 §2.1（generatedAt）。
- **封闭对象规则**【冻结】：下列字段既是必含/可选清单，也是**允许字段全集**；未列出的
  字段在 canonical QueryResult 中一律 `result_validation_failed`。标 `?` 的键可省略，
  未标 `?` 的键必须存在；nullable 会显式写出。列表内对象同样封闭，任何生产者不得把
  normalize 原对象整包透传。
- **`young_enrolment`**【冻结】：
  - `data = {activities: List<YoungActivity>}`；`metadata = {activityCount: int,
    reportedTotal?: int}`。
  - `YoungActivity` 必含 `title: String`；允许的其余可选键仅为
    `descriptionText/requirementsText/sourceActivityId/status/statusLabel/
    module/moduleLabel/category/categoryLabel/activityLevel/activityLevelLabel/organizerLabel/
    sponsorLabel/businessDepartment/startsAt/endsAt/applicationStartsAt/applicationEndsAt/
    capacity/appliedCount/participantCount/location/form/formLabel/serviceHours/validHours`。
    其中 `descriptionText/requirementsText` 可省略或为 null，存在时必须为纯文本且
    每项 ≤8000 字符；`imagePath` 与任何账号/用户/凭据字段禁止。
- **`icourse`**【冻结】：
  - `data = {query: {mode: 'course', value: String, teachers: List<String>,
    preferences: Map<String,String>}, results: List<IcourseResult>}`；`metadata =
    {resultCount: int, staleEntryCount: int}`。
  - `IcourseResult` 必含 `title: String`、`teachers: List<String>`、
    `relationStrength: String`；允许的可选键仅为 `terms: List<String>`、
    `averageScore: num?`、`reviewCount: int`、`aggregate?: {difficulty?,homework?,grading?,gain?}`、
    `siteAiSummary?: {text: String}`、`evidence?: List<IcourseEvidence>`、
    `teacherLinks?: List<{label: String}>`、`ranking?: {score: num,reasons: List<String>}`。
  - `IcourseEvidence` 允许字段全集 = `term? / content / publishedAt? / updatedAt? /
    upvoteCount / commentCount / dimensions? / untrustedText`；其中 `content` 必含、
    `dimensions` 只允许 `difficulty/homework/grading/gain`，`untrustedText` 必须恒为 `true`。
    **只暴露确定性代表点评 `evidence`，完整 `reviews` 永不进入 canonical 信封。**
- **`campus_search`**【冻结】：`data = {query: String, entries: List<CatalogEntry>}`；
  `metadata = {entryCount: int}`。`CatalogEntry` 必含 `id/source/kind/title`；允许的可选键
  仅为 `category/publishedAt/detailUrl/status`，`detailUrl` 必属 `references`；`id` 算法见
  §7.2 campus 表族。
- **`campus_detail`**【冻结】：`data` 必含 `catalogEntryId/source/title/content/
  attachments/links`，可选键仅为 `publishedAt/url/category/followedLinks`；
  `metadata = {stale: bool}`。attachments 项允许字段全集 = `attachmentId/url/mediaType`
  （必含）+ `label?/sizeBytes?/extractedText?/conversionStatus?`；links 项 = `id/url`
  （必含）+ `label?/reason?`；若有 followedLinks，其项 = `title/content/url/depth`
  （`depth` 恒为 1）。
  所有 URL 必属 `references`。
- **PythonChannel 兼容转换（M2–M6）**【冻结】：目标态始终只有上述 QueryResult 1.0，
  不设双版本。Python 通道在 C2 边界构造全新的 canonical DTO：young 的 `name→title`
  且丢弃 `imagePath`；icourse 的 `name→title`、`selectedEvidence→evidence`，**不映射
  `reviews`**，`teacherLinks` 只留 label；campus_search 的 `data.results→entries`、
  `metadata.resultCount→entryCount`；campus_detail 的 `candidateLinks→links`、附件
  `id→attachmentId`，保留有界 `followedLinks`。兼容转换可读取较大的 legacy 对象，但
  只逐字段复制上述白名单；转换后的未知键仍由 canonical 校验器 fail-closed。
- **目标态收紧（隐私）**：young 的 `imagePath`；icourse 的完整 `reviews`；campus_detail
  的 `id/itemId/contentHash/localPath/sha256/cache_key` 均不得进入 QueryResult；缓存路径
  只存在于 C3 索引（`campus_attachment_cache.cache_key`），不进 Agent 上下文。
- **附件索引登记载荷（A-2 整改：正式载体）**：`AttachmentCacheRegistration`
  列表的传输载体 = **`QueryCompleted.attachmentRegistrations`**（C1 终态内附，
  C2 校验 stamp 后随结果交 C4，C4 原样透传 C3 `commitCatalogSource`）；该载荷
  **不是** QueryResult 信封的一部分，永不进 Agent 上下文。canonical 信封
  （无 cache_key）与内部登记载荷（有 cache_key）由此分离，DB 表 NOT NULL 列均可填充。

### 5.5 附件转换管道（ADR-007/红线降级细则）

- **CT-C1-05**【冻结】：`AttachmentContentConverter.convert(attachment) →
  ConvertedContent{mediaType, text, sizeBytes}`——下载、大小与 MIME 白名单校验、
  内容转换编排全部在 C1；文件系统/平台 decoder/临时文件与缓存目录在 P；
  C3 只存目录元数据与缓存索引（§7.2 #1），不执行网络与转换。
- 限额【冻结】：**每批详情 ≤ 3、链接跟随 ≤ 1 层**（Agent 工具安全细则，§8.5 同源）；
  单附件大小上限与 MIME 白名单为实施期参数（M4 第 4 层定值，列入 `12-cross-cutting.md`
  §附件管道）。详情正文与附件内容缓存留磁盘、30 天 TTL 照搬现状。

## 6. C2 仲裁契约

### 6.1 SourceJobGateway（全部来源作业唯一入口）

- **CT-C2-01**【冻结】：

```dart
abstract interface class SourceJobGateway {
  Future<SourceJobHandle> submitSourceJob(SourceJobSpec spec); // busy → 抛 busy
  Future<SourceJobHandle> submitQuery(QueryRequest request);   // **C4 唯一查询入口**
                                                               // （A-1 整改）：C4 不组装
                                                               // spec/租约戳，C2 接收后
                                                               // 组装并走 submitSourceJob
  Future<SyncOutcome> sync(SyncSource source, {required SyncTrigger trigger});
  Future<void> syncAll();
  Future<FirstLoginOutcome> firstLoginSync(FirstLoginRequest req);
  Future<ReauthOutcome> reauthenticate(ReauthRequest req);
  Future<void> resumeInteractive(String jobId);   // 用户确认后；C2 验证作业处于
                                                  // needs_user_login → 向 C3 申请凭据
                                                  // 租约 → 注入同一作业（ADR-020 修订）
  Future<void> clearSession();                    // 全注册通道幂等清会话（ADR-019 修订）
  Future<void> cancelAll();
  bool isBusy();                                  // 提示性预检，不是正确性守卫
  FreshnessInfo freshnessFor(SyncSource source);
}
class FirstLoginRequest {                // 仅存在于 C5→C2→C3 staged 调用栈
  final String username;
  final String password;
  final bool savePassword;
}
class ReauthRequest {                    // 仅存在于 C5→C2→C3 staged 调用栈
  final String accountId;
  final String username;
  final String password;
  final bool savePassword;
}
class SourceJobHandle {
  final String jobId;
  final LeaseStamp stamp;                // 与底层作业同一不可变值；供 C2 交接、C3 复验
  final Stream<JobEvent> events;      // 转播 C1/Python 流（安全计数语义不变）
  final Future<void> Function() cancel;
  final Future<void> Function() resume;  // C4/C5 用户确认后的恢复请求
}
```

- **仲裁规则**【冻结】：
  ① 全局来源作业租约——同一时刻至多一个学校来源采集/查询作业活跃
  （Kubernetes Lease 式单一协调者 + holder，不引入依赖）；**取得是同步原子动作**
  （A-3 整改：C2 单线程 check-and-hold，检查与持有之间无 await；`isBusy()` 仅为
  提示性预检，正确性靠原子取得，取得失败抛 `busy`）；
  ② 通道注册表——一源一通道（§6.2），通道切换需旧作业终态释放，切换时
  sourceGeneration 递增；
  ③ 租约戳组装 + 迟到拒绝（§2.3）；
  ④ 触发判定（freshness/backoff/busy 预检，§6.5）；
  ⑤ 维护独占门（§6.4）。
- 生产者：C2。消费者：C5（同步/首登/维护）、C4（外部查询、恢复请求）。

### 6.2 SourceChannel 与通道注册表（L1-03 正式化）

- **CT-C2-02**【冻结】：

```dart
abstract interface class SourceChannel {
  ChannelKind get kind;                    // native | python
  Set<String> get sources;
  Stream<JobEvent> startCollection(SourceJobSpec spec);
  Stream<JobEvent> runQuery(SourceJobSpec spec);
  Future<void> cancel(String jobId);
  Future<void> resumeLogin(String jobId, CredentialLease lease);
  Future<void> clearSession(String accountId);   // 幂等；覆盖全部会话分区
  Future<SessionHealth> probeSession(String accountId);
}
```

- Native 实现委托 C1（JobExecutor + WebSessionEngine）；Python 实现委托 P
  （CT-P-07/08）【并存期】。
- 注册表【A-11 整改】：区分**已安装通道全集**与**来源路由**——`register` 登记
  安装（并存期 Python 租户安装后保持登记至 M7 移除；Native 通道常驻），
  `unregister` **前必须完成该通道全部账号分区的 clearSession（幂等）**；来源路由
  选择只是全集上的当前映射；`clearSession(account)` 与 completeReset 一律遍历
  **全集**，不因路由切换遗漏已注销通道的持久分区（ADR-019 真删除）；
  注册表本身在 C2，权威互斥在 C2（C1 JobGate 只管 Native 卡槽资源，L1-04）。

### 6.3 凭据一次性租约 CredentialLease（ADR-020）

- **CT-C2-03**【冻结】：

```dart
sealed class CredentialSubject {}
class StoredAccountSubject extends CredentialSubject {
  final String accountId;
  final String expectedUsername;
}
class ProvisionalSubject extends CredentialSubject {
  final ProvisionalHandle handle;        // C3 解析；不暴露临时明文
}
class ProvisionalAuthContext {            // stageFirstLogin/stageReauthentication 返回
  final ProvisionalHandle handle;
  final String prospectiveAccountId;     // 首登为仅内存预分配 id；重认证为既有 accountId
  final String expectedUsername;
  final int initialSourceGeneration;     // 首登=0；重认证=当前库值快照
  final int initialResetEpoch;            // 首登=0；重认证=当前库值快照
}
class CredentialLease {                  // 不可序列化进事件流；秘密字段私有（A-4 整改）
  final String leaseId;
  final String expectedUsername;
  Uint8List? takePassword();             // 原子"取即失效"：首次调用返回秘密并置空，
                                         // 此后一律 null——"一次读取"由签名机械保证，
                                         // 不再依赖调用方纪律（ADR-020）
  bool get passwordConsumed;
  Future<void> revoke();                 // 未消费即撤销（删除凭据/作业终态时）；幂等；
                                         // revoke 后 takePassword() 返回 null
}
Future<CredentialLease> requestCredentialLease(
  CredentialSubject subject, {required bool includePassword});
```

- 并发语义【冻结】：同一租约的 `takePassword()`/`revoke()` 必须串行化（单 isolate
  内同步实现；跨 isolate 由 C2 单线程持有保证）。

- 申请链【冻结】：持久账号使用 `StoredAccountSubject(accountId, expectedUsername)`；首登/
  重认证 staged 流使用 `ProvisionalSubject(handle)`。C2 启动作业前向 C3
  `requestCredentialLease(subject, includePassword: false)`；needs_user_login → 用户确认 →
  C2 向 C3 重新申请 `includePassword: true` → 注入同一作业 → C1 `takePassword()`
  取即失效、用后尽力零化。同步与查询**不得各自实现凭据旁路**（ADR-020 修订）。
- 首登 `stageFirstLogin` 只在 C3 内存中预分配 `prospectiveAccountId` 并建立 staged
  generation/resetEpoch 权威，**不得提前插入 local_accounts/source_configs 行**；
  C2 用该 id 组装 LeaseStamp，C3 以 handle 解析租约和最终提交守卫。
- 撤销链【冻结】：作业终态自动失效；删除凭据/completeReset 前 C2 先撤销全部未消费
  租约并终止可能消费凭据的作业（ADR-023 ④）。
- 生产者：C3 账号凭据服务。流转者：C2。消费者：C1 / Python 通道（唯一读取方）。

### 6.4 维护独占门（ADR-023 ④）

- **CT-C2-04**【冻结】：`beginMaintenance(MaintenanceKind)` /
  `endMaintenance(MaintenanceKind)`；
  `MaintenanceKind ∈ {deleteCredentials, clearSession, clearBusinessData}`——
  门关闭期间拒绝新来源作业、取消并等待旧作业终态；拒绝出口 = 稳定错误码
  `maintenance_in_progress`（A-8 整改补码）；reset 不依赖内存门
  （走 C3 持久 reset_pending + 写屏障，§7.4）。
- 生产者：C2。消费者：C5 AccountMaintenanceCoordinator（编排）、C3（屏障配合）、
  C4（拒新 run/工具/审批）。

### 6.5 同步触发、新鲜度与状态机参数（D12/D37）

- **CT-C2-05**【冻结】`sync_runs.trigger` 枚举：**扩展为
  `{automatic, manual, first_login, reauthentication}`**（TEXT 列，零迁移；
  首登/重认证不再混记 `manual`，各自可审计——旧房 `SyncTrigger` 仅两值，
  首登/重认证落 manual，02 §6 观测）。
- **CT-C2-06**【冻结】`sync_runs.state` 枚举：`{running, success, failed,
  cancelled, interrupted, needs_user_action}`（以 02/03 观测的代码写入全集为准；
  needs_user_login 期间 run 保持 running，用户确认后同一 run 继续）。
- **CT-C2-07**【冻结】retry 契约（ADR-008/013/D12）：`freshness = 12h`、
  `retryBackoff = 1h`——自动同步在 freshness 窗口或 retryAfter 前跳过
  （`fresh_or_backoff`）；手动同步绕过退避；失败写 `source_configs.retry_after`；
  启动 `recoverInterruptedRuns` 把遗留 running 标记 `interrupted/app_restarted`
  （ADR-022：跨重启普通作业一律作废）。
- **CT-C2-08**【冻结】campus 目录 freshness：30min 刷新节流 / 6h 过期 / 失败降级
  旧目录（ADR-007）；icourse 24h 缓存 TTL（ADR-012：首次使用自动重建）。
- **sync_runs 单一写权威（A-8 整改）**：run 生命周期（start/finish/中断标记）由
  C2 经 C3 `SourceStateService`（CT-C3-21）写入；C3 ImportService **不写 sync_runs**——`importBundle`
  返回 `importBatchId`，C2 在导入成功后调用 `syncStateService.finishSyncRun(
  runId, stamp, state, resultCode, importBatchId)` 收尾；`import_batches.origin` 目标态
  写入值冻结为 **`native`**（并存期 Python 通道写 `python`），历史 `bridge`/
  `file` 行不改写（file-origin 已删，ADR-021）。
- 生产者：C2 SyncCoordinator（经 C3 同步状态服务读写 sync_runs/source_configs）。
  消费者：C5 同步页/启动编排、C4 查询预检。

## 7. C3 存储契约

### 7.1 数据库与迁移线

- **CT-C3-01**【冻结】本地事实来源 = 单文件 SQLite（Drift），库名
  `ustc_assistant`；schemaVersion 迁移线 **v7 为基线**；v8+ 只走正式迁移
  （ADR-011/012）；**迁移前自动备份 v7 库副本、失败可回滚**（红线 2.2-7 承接）。
- v7 基线 27 表数据字典权威 = 03 §4.2（本文件冻结清单与表数，不复制全量字典）：
  account 2 / source 4 / schedule 6 / task 6 / agent 6 / operation 2 + undo_slot
  = 27。**v8 后表数 = 27 + 3（campus 表族）= 30**（此后一律称"v8 基线 30 表"，
  不再混称"27 表"，07 §2.5 移交项 2）。
- 账号隔离机制【冻结】（07 §2.5 移交项 3）：业务表一律 `account_id → local_accounts
  ON DELETE CASCADE`；`source_records.import_batch_id` 用 RESTRICT（保护批次行）、
  `sync_runs.import_batch_id` 用 SET NULL（03 §5 现状语义照搬）；单账号模型
  （ADR-004）不改变表结构纪律。

### 7.2 schema v8 冻结变更集（ADR-011；7 项 + 无孤儿字段检查）

| # | 变更 | 类型 | 内容 | 写方 | 读方 |
|---|---|---|---|---|---|
| 1 | campus 目录表族（3 张） | 加表 | 见下 | C3 CatalogService（经 C2 交接的规范化目录数据 upsert） | C3 本地搜索/freshness、C4 工具（经网关）、C5 展示 |
| 2 | `undo_slot.expires_at` 删除 | 删列 | 现状只写不读的孤儿列（03 §10-3）；单槽语义不受影响 | 无（删除理由） | 无 |
| 3 | `action_logs` 加 `(account_id, occurred_at)` 索引 | 索引 | 03 §9 建议 2 | `ActionLogRepository.append`（全部写路径） | `HistoryRepository.query` / 设置页审计展示（倒序） |
| 4 | Agent prompt 版本统一为 **8** | 数据修复 | `agent_settings.system_prompt_version` DEFAULT 改 8 + 迁移 UPDATE 现行为 8 + 代码常量统一 8（表默认 2/常量 3/实际 v8 三处不一致，06 §10-2） | C4 会话服务（新建行）、迁移器（回填） | C4 上下文构建（prompt 选择） |
| 5 | `agent_permission_policies.expires_at` 删除 | 删列 | 死列（代码核实 2026-08-14：恒 NULL、`resolve` 决议从不读）；"此类型以后不再确认"=永久记住（ask_first_time + firstConfirmedAt），无过期概念（L2-02 修订） | 无（删除理由） | 无 |
| 6 | reset 持久状态 | 加列 | `local_accounts` + `reset_pending INTEGER NOT NULL DEFAULT 0`（**三值编码：0=无、1=pending、2=incomplete_session_cleared**，A-9 整改——第三态跨重启可恢复）+ `reset_epoch INTEGER NOT NULL DEFAULT 0`（不新增表；finalizeReset 删账号行时同事务清标记，幂等闭环） | C3 beginReset/finalizeReset | C5 启动强制门（resetState 由编码映射）、C2 租约戳组装（经 C3 `currentResetEpoch()`）、C4 写屏障校验 |
| 7 | sourceGeneration 持久化 | 加列 | `source_configs` + `source_generation INTEGER NOT NULL DEFAULT 0`——generation 权威归 C3（A-7 整改：C3 来源写事务内与库内值比对，消灭"预检-提交"TOCTOU）；C2 经 C3 同步状态服务递增（通道切换/取消/reset/clearBusinessData 时） | C3 同步状态服务（C2 经其调用） | C3 normal/重认证/campus 写守卫（事务内比对）、首登 staged 守卫、C2 租约戳组装 |

**#1 campus 表族字段级冻结**（无孤儿字段检查内嵌）：

| 表 | 字段 | 写方 | 读方 |
|---|---|---|---|
| `campus_catalog_entries`（条目） | id TEXT PK（精确算法：`'campus_' + sha256(utf8('$source\0$canonicalUrl')).hexLower.substring(0, 24)`；canonicalUrl 先按旧房 `canonicalize_url` 规则规范化）；account_id → CASCADE；source（五个目录键）；title NOT NULL；category NULL；published_at NULL（YYYY-MM-DD）；detail_url NOT NULL；first_observed_at / last_observed_at INTEGER NOT NULL；**无 updated_at 列** | C3 CatalogService.commitCatalogSource（带 LeaseStamp） | C3 搜索（title/category/日期）；C4 campus_search；C5 目录展示（含 first/last_observed_at 观察时间展示） |
| `campus_catalog_state`（来源级新鲜度） | source TEXT PK（五个目录键）；account_id → CASCADE；last_success_at NULL；last_attempt_at NULL；updated_at NOT NULL | C3 CatalogService.commitCatalogSource | C3 freshness 判定（30min 节流/6h 过期）；C4 预检；C5 展示（last_attempt_at=上次尝试）；updated_at 审计 |
| `campus_attachment_cache`（附件缓存索引） | id TEXT PK（附件稳定身份）；account_id → CASCADE；entry_id NULL → entries CASCADE；url / media_type NOT NULL；size_bytes INTEGER NOT NULL；cache_key TEXT NOT NULL（相对私有缓存目录）；fetched_at / expires_at INTEGER NOT NULL（30 天 TTL） | C3 CatalogService.commitCatalogSource（C1 转换结果经 C2→C4 带原 stamp 交接） | C4 campus_detail（fetched_at/expires_at 做 TTL 判定、cache_key 经 P 文件存储定位附件）；completeReset 清理范围；clearCache（CT-C3-20） |

- `canonicalUrl` 算法【冻结，逐步等价旧房】：trim → URL split；scheme 缺省 `https` 并
  小写；netloc 小写；空 path 置 `/`；fragment 清空；query 保留空值，按 key/value
  字典序排序，大小写不敏感地删除 `_t/from/spm/utm_campaign/utm_medium/utm_source`，
  再按 UTF-8 `application/x-www-form-urlencoded` 重编码。重复 query key 保留并参与排序。
- entries 观察时间【冻结】：首次插入时 `first_observed_at = last_observed_at =
  BeijingClock.now()`；后续同 id 再观察只更新 `last_observed_at`，保留首次时间；不得从
  legacy `discoveredAt/lastSeenAt` 直接信任写入，也不得派生或读取不存在的 `updated_at`。
- 表数核对：v8 = 30 表（#7 为加列不动表数）。冻结后任何新增/删除/改列变更必须
  开 ADR 修正本清单（ADR-011）；每条变更配"旧库建→插数据→迁移→校验"四步迁移
  测试（Room MigrationTestHelper 模式）。

### 7.3 ImportService 公共 normal-only 入口（ADR-023 ①）

- **CT-C3-02**【冻结】：

```dart
Future<ImportResult> importBundle(
  Uint8List bytes, {
  required LeaseStamp stamp,            // 写前校验（§2.3）；迟到 → stale_lease
})
// 仅 normal 同步路径；首登导入唯一入口 = commitFirstLogin（A-6 整改：单一事务所有者）
enum ImportStatus { imported, replayed }
class ImportResult {
  final ImportStatus status;
  final String importBatchId;           // 交还 C2 用于 finishSyncRun（A-8 整改：
                                        // sync_runs 单一写权威在 C2）
  final bool reminderReconciliationPending; // 事务外提醒协调失败降级标记
}
```

- **守卫（A-6 整改）**：公共 `importBundle` 仅 normal 同步 =
  `stamp.accountId == 当前 activeAccountId`，
  且 stamp.sourceGeneration/resetEpoch 与 C3 库内值（`source_configs.
  source_generation` / `local_accounts.reset_epoch`）**事务内**比对；不一致 →
  `stale_lease` 稳定拒绝、不写库。首登提交的全部"解码+导入+账号绑定"在
  `commitFirstLogin` 单事务内完成（provisional/verifiedUsername/jobId/
  generation 守卫），ImportService **不再提供**可跨容器调用的 firstLogin 导入
  入口。两条入口只复用 C3 **事务内私有导入核心**（decode/validate/upsert），该核心
  不是跨容器接口，不得被 C2/C5 直接调用。
- 流水线【冻结】：解码（16MB/深度/schema）→ 语义校验（9 错误码）→ subject 校验 →
  幂等（bundleId/digest）→ **单事务**（import_batches + 预分配 localId 复用 +
  upsert course_series/calendar_events/schedule_relations + source_records
  presence 对齐 + ActionLog；**不写 sync_runs**——run 收尾由 C2 经同步状态服务，
  A-8 整改）→ 事务外提醒协调（失败记 `reminder_reconcile:retryable_failure`，
  不重试导入）。
- file-origin 导入**移除**（ADR-021：目标态仅"采集→导入"单一路径）。
- 接口提供者：C3（实现）；调用者：C2（bundle 字节 + 租约戳交接，唯一调用方——
  B-8 术语统一）。

### 7.4 账号生命周期事务（ADR-023）

- **CT-C3-03**【冻结】首登：

```dart
Future<ProvisionalAuthContext> stageFirstLogin({
  required String username, required String password, required bool savePassword});
// C3 仅在内存预分配 prospectiveAccountId；不插 local_accounts/source_configs 行。
// ProvisionalHandle 不透明、不得落库/文件/日志；凭据仅经一次性租约交当前作业。
Future<CommitFirstLoginResult> commitFirstLogin({
  required ProvisionalHandle handle, required Uint8List bundleBytes,
  required String verifiedUsername,
  required SemesterTriple selectedSemester,          // A-6 整改：来自
                                                     // CollectionCompleted.selectedSemester
                                                     // （首登无持久选择，C1 实际选中项）
  required LeaseStamp stamp});
// bundleBytes 来自作业终态 JobTerminalPayload.CollectionCompleted.bundleBytes，
// 由 C2 交接；A-6 整改：本方法是首登"解码+导入+账号绑定"的唯一事务所有者
Future<void> cancelFirstLogin(ProvisionalHandle handle);  // 幂等销毁（busy/失败/取消/
                                                          // 进程退出调用，尽力零化）
```

- **identityDigest 唯一生产者**【冻结，A-6 整改】：C3 账号服务，
  算法 = `sha256(utf8(username.trim()))` 十六进制字符串（照搬旧房
  `account_service.dart:512-513` 的 `_identityDigest`）；输入 = verifiedUsername，
  **在 commitFirstLogin/commitReauthentication 事务内由 C3 计算（调用方不传，
  避免外部供值）**；除 commitFirstLogin 首建与显式 schema 迁移外不得写入。

`commitFirstLogin` 先以 handle 取回 staged 权威并校验 `stamp.accountId ==
prospectiveAccountId`、jobId/source/initialSourceGeneration/initialResetEpoch 与
verifiedUsername；随后单事务 = 创建该预分配 accountId + 建立 source_configs 当前
generation + 导入 Bundle（§7.3 私有事务内核心）+ 凭据密文（savePassword 决定是否存
密码）+ identityDigest 首建 + 置活动 + 审计。任一守卫失败 → `stale_lease` 或身份错误，
任一事务失败整体回滚 → 无活动账号、无凭据行、无来源业务数据；提交后才广播
`activeAccountChanged`。handle 一次性消费；取消/失败即失效并尽力零化。

- **CT-C3-04**【冻结】重新认证（A-5 整改：签名含凭据来源）：
  `stageReauthentication({required String accountId, required String username,
  required String password, required bool savePassword}) → ProvisionalAuthContext`
  （password 为重新认证表单输入的临时明文，仅进程内存；启动作业前校验输入
  username 的 digest == 现有 identityDigest）→ C2 统一来源作业（密码经凭据租约
  注入 C1/Python）→ 成功返回 verifiedUsername → `commitReauthentication(
  {required String accountId, required String verifiedUsername,
  required ProvisionalHandle handle, required LeaseStamp stamp})` 在同一事务内复验
  stamp 的 accountId/jobId/sourceGeneration/resetEpoch 与当前库值，再次校验 digest：
  匹配 → **仅更新凭据密文**
  （handle 内临时明文加密落库，savePassword 决定是否存密码）**与元数据，
  identityDigest 保持不变**（重新认证不可变，仅首建或显式 schema 迁移可写）；
  不匹配 → `identity_mismatch`，数据库身份/凭据/业务数据不变，受影响会话分区
  由 C2 先持久 quarantine 再清除（清除失败跨重启禁复用并报 UI）。
  **`discardProvisionalAuth(ProvisionalHandle handle)`**（A-7 整改）：重新认证
  provisional 上下文的幂等销毁接口——busy、作业失败、用户取消、`account_mismatch`、
  `identity_mismatch`、进程退出时调用，临时明文尽力零化；与首登的
  `cancelFirstLogin` 同语义、不同入口。

- **CT-C3-05**【冻结】reset（durable finalization）：

```dart
Future<void> beginReset();     // 持久 reset_pending=1 + resetEpoch++ + 写屏障（除
                               // finalization 外拒绝新业务写入）
Future<void> finalizeReset();  // 幂等单事务：删 action_logs(本账号) + undo_slot +
                               // local_accounts 行（其余凭 FK CASCADE）→ 清
                               // reset_pending → 广播空账号
ResetState resetState();       // {none, pending, incompleteSessionCleared}
                               // 由 reset_pending 三值编码映射（0/1/2，v8 #6），
                               // 跨重启可恢复（A-9 整改）
int currentResetEpoch();       // C2 租约戳 / C4 写屏障共用
```

失败语义（08 §7.3 表契约化）：beginReset 失败=原状；C2/C4 取消失败=保持
reset_pending 与写屏障、可重试；会话清理失败=不得绕过后删库；清会话后删库失败=
事务回滚 + 状态 `reset_incomplete_session_cleared`、下次启动继续 finalization；
finalizeReset 重复执行=幂等；reset_pending **不属于** ADR-022 普通作业作废范围，
启动时作为**强制启动门**（C5）先于正常路由/自动同步/Agent 恢复，恢复失败保持
写屏障并进入专用恢复界面。
- **completeReset 撤销链顺序**【冻结，A-7 整改】：C2 先 `revoke` 全部未消费凭据
  租约（CT-C2-03）→ 终止可能消费凭据的作业 → cancelAll 并等待全部终态 → 经
  SourceStateService 以 reset 原因逐来源 bumpGeneration（CT-C3-21）→ 全通道
  清会话 → finalizeReset。

- **CT-C3-06**【冻结】清业务数据（维护写屏障）：

```dart
Future<void> beginBusinessDataClear();     // 拒新业务写 + 等待已进入的本地写事务终态
Future<void> commitBusinessDataClear();    // 单事务清除；提交后解除屏障与维护门
Future<void> abortBusinessDataClear();     // 回滚解除
```

清除范围【冻结，L2-10 拍板——旧房逐行核实为 **15 张**业务表（03 §7.1 所记
"16 张"为计数误差，疑为把 undo_slot 数入而旧房代码未删；以
`settings_service.dart:118-168` 为准）+ **目标态同事务清 undo_slot**（修掉旧房
残留槽指向已清数据的隐患，与 ADR-010 启动清槽一致）】：reminders / user_overlays /
schedule_relations / schedule_relation_rules / task_event_links / plan_blocks /
tasks / calendar_event_occurrence_exceptions / calendar_events /
calendar_event_series / course_series / source_records / sync_runs /
import_batches / jw_day_moves + undo_slot。**保留**：local_accounts /
credential_accounts / source_configs / agent_settings / agent_secrets /
agent_permission_policies / Agent 历史与 action_logs（审计不清）。
**campus 三表（v8 #1）不随 clearBusinessData 清除**——公开信息缓存非个人业务
数据，归 clearCache 与 completeReset（级联）管。
（与红线 2.2-2 的关系：见 07 §2.2-2 解释注——用户确认的破坏性维护属 2.1-5
完全清除，A-10 拍板 2026-08-14。）
C2/C4 维护门配合（08 §7.5）：任何取消/等待失败均不得开始清理事务。

### 7.5 服务层六子域与写服务统一契约（ADR-017）

- **CT-C3-07**【冻结】六子域服务清单（形态照搬，M1 重建"形态不变≠代码复制"）：

| 子域 | 读服务 | 写服务 |
|---|---|---|
| Identity | 账号/凭据查询（`usernameForSync` 等受控出口） | stage/commit 首登、重认证、deleteCredentials、租约申请 |
| Schedule | `EffectiveEventRepository`（watchDisplayEvents/conflictsForItems/byId）、`ConflictService`（stateForPair/relationSnapshot/classifyPair）、`OverlayService`（eventOverlayLayers）、`JwDayMoveService`、`RecurringEventProjector`（projectRange/searchSeries） | OverlayService.setEventOverlay/clearOverlayFields、ConflictService 关系增删、JwDayMoveService CRUD、CalendarEventService、RecurrenceService、RecurringLifecycleService（个人事件与重复系列并入 Schedule，A-14 整改：恢复 08 的六子域形态） |
| Task | `TaskProjection` 派生查询、`UndoService.preview` | TaskLifecycleService、PlanBlockService、TaskEventLinkService、UndoService（撤销归 Task，现状代码位置） |
| Reminder | `ReminderOverrideService.configurationFor` | setOffsets/clearReminders、ReminderService.reconcileAll/reconcileSource |
| Catalog | 目录搜索 + freshness 判定 | commitCatalogSource（带 LeaseStamp）/ 附件缓存索引登记 |
| Audit | `HistoryRepository.query`（上限 50、脱敏）、ActionLogRepository.selectAll | ActionLogRepository.append（全部写路径同事务） |

- **写服务统一契约**【冻结】：① 乐观锁——写前按 `expectedUpdatedAt`/
  `expectedOffsetsSnapshot` 重查目标（TOCTOU 复验），过期抛 stale 类错误且不写；
  ② 事务——业务写 + ActionLog（safeSummary）+ Undo 快照（`undoRecorder.record`）
  同事务，任一失败整体回滚；③ 稳定错误码——§2.4 本地写级全集；
  ④ **Agent 写入不占撤回槽**（C4 网关注入 NoopUndoRecorder，ADR-010）。
- **CT-C3-22** Catalog 来源写入口【冻结】（A-8 整改补号）：
  `commitCatalogSource({required LeaseStamp stamp, required QueryResultEnvelope
  result, required List<AttachmentCacheRegistration> attachmentRegistrations})`
  只接受已通过 CT-C1-04 校验的 campus 结果；C3 在同一事务内复验 accountId/source/
  sourceGeneration/resetEpoch 后，才更新 entries/state/attachment_cache。
  attachment_cache 行的 cache_key/size_bytes/fetched_at/expires_at 来自 C1 内部登记
  载荷（§5.4；canonical 信封不含 cache_key）。C2 在把终态交给 C4 前先校验同一
  stamp，C4 只负责编排交接，不得自行补造 stamp；过期一律 `stale_lease`、三表零写入。
- **CT-C3-20**【冻结】`clearCache()`（B-9 整改：补正式契约）：清除非业务缓存——
  campus 三表（entries/state/attachment_cache）事务内删行 + P 文件存储中附件/
  详情缓存文件事务外删除（文件删除失败不阻塞、记审计）；不触碰任何业务表；
  接口提供者 C3（+P 文件实现），调用者 C5 设置页；completeReset 级联亦清。
- 生产者：C3 各服务。消费者：C5 页面（drift 流自动刷新）、C4 网关
  （AgentLocalDataGateway/AgentWriteGateway）、C2（同步状态读写）。

### 7.6 数据模型契约（07 §2.5 移交项汇总）

> 配套可视化（calendar_events × tasks 字段与交叉逻辑）：`09a-data-model-visual.md`
> （派生图；权威仍为本节 + 03 §4.2）。

- **CT-C3-08** 学校来源稳定外部身份 upsert【冻结】：
  `UNIQUE(account_id, source, external_id)`；course_series/calendar_events 同规则；
  本地 id 复导时复用（03 §3.1 预分配语义）。
- **CT-C3-09** Task 四态【冻结】：只持久化 `{active, blocked, completed,
  cancelled}`（CHECK + 终态时间戳互斥）；计划/截止/确认三态投影查询计算
  （task_projection），不落库。
- **CT-C3-10** PlanBlock 模型【冻结】：六态 `{suggested, accepted, done, skipped,
  rescheduled, cancelled}`；**不记录完成百分比/实际执行分钟/自动剩余工时**
  （07 §2.5 孤儿规则）；`reviewed_at` 与状态一致性 CHECK 保留。
- **CT-C3-11** 个人事件模型【冻结】：支持单次/全天/跨日/基础重复系列
  （daily/weekly/monthly rules v1 JSON）；事件 type 十值（course/exam/
  second_class/personal/entertainment/meal/campus_affair/travel/study/system）；
  timed 与 all-day 表示互斥（CHECK）。
- **CT-C3-12** 重复系列【冻结】：稳定身份 + 单次例外（occurrence_exceptions
  kind ∈ {override, cancelled}，UNIQUE(account_id, series_id, occurrence_key)）；
  物化上限 **366 天 / 1000 次**（实施期参数）；三作用域 only_this/
  this_and_future/whole_series（RecurringLifecycleService）。
- **CT-C3-13** 冲突判定序【冻结】：显式 occurrence 关系（规范键
  `kind:id|kind:id`）> 系列规则（schedule_relation_rules，按发生日命中
  effectiveFrom/Through）> 时间重叠派生 > 无冲突；**派生对只存在于投影结果，
  从不落库**；投影走 `conflictsForItems` 有界路径（全量投影已废弃）。
- **CT-C3-14** 提醒默认偏移（D33）【冻结，现状 ReminderDefaults 全表照搬】：

| 目标 | 默认偏移（分钟，触发前） |
|---|---|
| 定时事件：course/personal/entertainment/meal/campus_affair/travel/study | [15] |
| 定时事件：exam | [1440, 120] |
| 定时事件：second_class | [120] |
| 全天事件（任意类型） | []（不提醒） |
| Task | [1440, 120] |
| PlanBlock | [10] |

显式覆盖优先（reminder_override_service）；显式禁用哨兵 = state='cancelled' 且
offset_minutes IS NULL；reminders 状态机 `{desired, delivered, cancelled,
missed, failed}` + failure_code `notification_unavailable`；系列 31 天前瞻照搬。
- **CT-C3-15** 学期三元组【冻结】：`source_configs.configJson`（source=ustc_jw）
  键 `semesterId/semesterKey/displayName`，缺任一字段拒绝
  （`complete_semester_required`）；取值只从教务页面源文件抓取列表匹配
  （ADR-009），默认学期按月份规则（2–6 春 / 7 夏 / 8–12 秋 / 1=上一年秋）。
- **CT-C3-16** 出勤与听讲【冻结】（红线 2.2-9）：attendance_decision
  （必去/可以赌/不去）+ 自由备注；listening_mode 独立记录（user_overlays 两列系）。
- **CT-C3-19** sourceConfigs 主键形态（D35/L2-03 落契，A-13 整改）【冻结】：
  `id = '$accountId:$source'` 复合字符串 id + `UNIQUE(account_id, source)` 兜底
  （保留现状、零迁移；单账号模型不简化——从属行复合身份合法，成熟开源对照见
  LobeHub/Airbyte，L2-03 拍板记录）；写方 = 设置服务（config_json）与同步状态
  服务（开关/健康/`source_generation` v8 #7）；读方 = C2 freshness/backoff、
  C5 设置页、C2 组装作业请求（学期三元组）。
- **CT-C3-21** SourceStateService【冻结】：C2 对 `source_configs` / `sync_runs` 的
  唯一持久状态端口，C2 不直接写表：

```dart
enum SourceGenerationReason { channelSwitch, cancel, reset, clearBusinessData }
abstract interface class SourceStateService {
  Future<int> currentSourceGeneration(String accountId, String source);
  Future<int> bumpSourceGeneration(String accountId, String source,
      SourceGenerationReason reason); // C3 原子 +1 并返回新值
  Future<String> startSyncRun({required LeaseStamp stamp,
      required SyncTrigger trigger});
  Future<void> finishSyncRun({required String runId, required LeaseStamp stamp,
      required SyncRunState state, String? resultCode, String? importBatchId});
  Future<void> recoverInterruptedRuns();
}
```

  generation 递增原因全集严格为上述四值；**计数规则（A-4 整改）**：同一维护操作
  对同一来源只递增一次、取根操作 reason（reset/clearBusinessData 内部触发的作业
  取消不再以 cancel 重复递增）；仅用户直接取消作业（或 C2 通用取消路径）才以
  cancel 递增。用户取消的时机 = 取消请求被接受的时刻（先递增、后协作式终止），
  迟到结果随之 stale_lease。reset/clearBusinessData 对账号全部来源逐项调用。
  start/finish 校验 run 与 stamp.jobId/accountId/source 的绑定；finish 只允许写
  作业账本终态，不赋予任何业务数据写权限。首登在账号行存在前不写 sync_runs，
  `commitFirstLogin` 事务内由该服务的私有事务实现按 stamp.jobId 记 first_login 终态；
  账号提交后其余 run 一律走公开 start/finish。
- 生产者：C3 各服务。消费者：C5 展示、C4 工具（经网关）、C2 同步状态。

### 7.7 撤销与权限策略

- **CT-C3-17** 撤销【冻结】：单槽（CHECK slot=1）+ 启动清槽（ADR-010 语义
  显式化）；信封 v1 `{version, kind, accountId, safeSummary, payload}`；
  11 类实体恢复器 + 复合操作逐操作复用单实体恢复器；他账号槽绝不删除/改写；
  撤销成功删槽、失败保槽；Agent 写入不占槽（§7.5 ④），Agent 侧撤回走
  `undo_last_action` 工具（C4）。
- **CT-C3-18** 权限策略"记住"语义（D34，L2-02 修订）【冻结】：v8 **删除**
  `agent_permission_policies.expires_at` 死列——代码核实：恒 NULL、`resolve`
  从不读、与 ADR-010 删 undo_slot.expires_at 同款处置；"此类型以后不再确认" =
  **永久记住**（`ask_first_time` + `firstConfirmedAt != null` → allow），无过期
  概念；撤销快照 `_policySnapshot` 与恢复器 `_restorePermissionPolicy` 同步去掉
  该字段；将来如需"限时记住"作为新功能开新决策，不预埋。

## 8. C4 Agent harness 契约

### 8.1 会话服务与预算基线

- **CT-C4-01**【基线】`AgentSessionService`：有界推理循环 **8 模型调用/run +
  12 工具调用/run**；create_task 突发 **32/run**（每 run 只授予一次、不占普通
  额度）；`preflightTurn` 整轮预检——拒绝即整轮副作用为零；`ToolCallFingerprint`
  完全重复调用阻断；SSE 流式 + tool_use/tool_result；默认模型
  `deepseek-v4-flash`、网关 `api.llm.ustc.edu.cn`（表 DEFAULT 照搬现状）。
- **CT-C4-02**【基线】上下文预算：输入上限 28,000 token、摘要触发阈值 18,000、
  摘要输出上限 1,024；滚动摘要以"不可信上下文"框架注入。
- 以上为**基线值**（不声称永久不动）：D32 契约变化会经本文件回写（L1-09）；
  修改须同步修订本节。
- **CT-C4-03**【冻结】维护期行为（ADR-023）：reset 或 clearBusinessData 维护
  期间 C4 拒绝新 run/工具/审批，取消当前模型流/工具调用/等待确认，并等待所有
  可能写库的执行终态。

### 8.2 本地数据网关（ADR-017）

- **CT-C4-04**【冻结】`AgentLocalDataGateway`（应用层跨聚合门面，非仓库）域
  清单：有效事件（display/byId/conflictsForItems）、冲突（stateForPair/
  classifyPair/relationSnapshot）、覆盖（eventOverlayLayers）、撤销预览
  （UndoService.preview）、提醒配置（configurationFor）、历史（query，上限 50）、
  递归投影（projectRange/searchSeries）、任务/计划块派生查询。全部经 C3 服务，
  C4 不直接碰表。
- 生产者：C4 门面。消费者：C4 工具实现。

### 8.3 写网关与审批门

- **CT-C4-05**【冻结】`AgentWriteGateway`：

```dart
Future<WriteProposal> proposeWrite(WriteProposalView view,
    {required int expectedResetEpoch}); // 不碰库；epoch 快照（A-7 整改）
Future<WriteOutcome> resolveAndCommit(WriteProposalId id, ConfirmationDecision d,
    {required int expectedResetEpoch}); // 提交事务内与 local_accounts.reset_epoch
                                        // 比对；过期 → stale_lease，不写库
```

- 审批门【冻结】：propose（不碰库）→ 工具 allowlist 校验（伪造策略组合拒绝）→
  `AgentPermissionPolicyService.resolve`（ask_first_time 首次确认后放行；
  记住=永久语义见 CT-C3-18）→ allow 直接原子提交 / deny 拒绝 / confirm 进
  确认卡暂停。确认卡预览只显示模型安全信息（标题/时间等），**不含 DB id/ref**；
  权限变更（update_permission_policy）永远需要用户亲手确认（红线 2.1-5）。
- 参数校验【冻结】：`WriteArgumentReader` 白名单键 + 严格类型，非法 →
  `invalid_write_arguments`，不产生 DB 变更。
- 事务【冻结】：业务提交 + agent 业务日志 + 用户确认日志 + 权限变更
  （remember/ask_first_time）同一 Drift 事务（SQLite fault-injection 回归
  验证保留）；Agent 写入用 NoopUndoRecorder（不占撤回槽）。
- 聚合观测【冻结】：`MutationLedger` 按序聚合成功/拒绝/失败/未处理，只含计数
  与白名单错误码；`CreateTaskBurstLease` 同构。

### 8.4 外部查询消费（ADR-016）

- **CT-C4-06**【冻结】：外部只读工具经 C2 `submitSourceJob` 提交（**不直连
  C1**），获得 `SourceJobHandle{stamp, events, cancel, resume}`；needs_user_login =
  暂停态（elicitation），用户确认后经 `resume` 恢复同一作业；无轮询、无独立
  恢复端点；QueryResult 1.0 信封校验通过 → OutboundPrivacyFilter 逐工具白名单
  净化 → 入对话（references 校验与 CT-C0-05 共用白名单）。
- campus 例外路径【冻结】：campus_search 先经 C3 目录服务判 freshness——
  无需刷新 → 本地搜索；需刷新 → C4 → C2 → C1/Python 抓取规范化 → 结果经 C2
  按 handle.stamp 校验后交还 C4 → C4 将**原 stamp + canonical 结果**交 C3
  `commitCatalogSource`，C3 事务内复验后 upsert → 本地搜索 → 入对话；刷新失败且目录缺失 →
  `catalog_unavailable` 明确报错（不返回部分数据冒充完整结果）。

### 8.5 Agent 工具安全细则（红线降级细则，07 §2.5 孤儿细则）

- **CT-C4-07**【冻结】：campus 详情每批 ≤ 3、链接跟随 ≤ 1 层（与 §5.5 同源）；
  详情内容按 references 白名单校验；外部查询参数出现 URL/文件系统字段名即拒绝
  （§5.4）。附件下载与内容转换归 C1、平台实现归 P（C4 只持结果）。
- **CT-C4-08**【冻结】工具系统框架（L1-09）：能力域六域（本地读/外部读/本地写/
  生命周期/管理/元域）是容器契约；**域内工具清单是 M6 审计产物**（覆盖矩阵 +
  冗余合并 + 声明成本），不携带旧房"39 工具"数字进入新架构；每轮作用域收窄
  延续 grounding `initialAllowedTools`；8×12 为基线（D32 经 §8.6 回写）。

### 8.6 D32 复合写（批量删除）契约面【L2 拍板项】

- **CT-C4-09**【基线】填补"用户明确要求的批量删除"缺口（07 D32）：
  ① **确认**：复合操作必须携带完整目标清单预览（模型安全字段，无 DB id/ref），
  用户批准后执行；禁止无预览 delete-all；
  ② **额度**：复合操作整体计 **1 次工具调用**（8×12 基线内）；单次复合操作
  上限 **32 个对象**【基线——与 create_task 突发对齐，用户拍板"暂定 32"，
  M6 审计可调但须修订本文档】；每对象一条 mutation ledger 记录 + 一条复合审计
  （action_logs safeSummary 只含计数与类型）；
  ③ **审计**：每对象执行结果按序进 MutationLedger（成功/拒绝/失败/未处理 +
  白名单错误码）；
  ④ **撤销**：复合操作整体占用**单槽一个撤销快照**（复用现有 composite
  UndoCommand——逐操作单实体恢复器），一次 undo_last_action 整包恢复；
  ⑤ 多对象逐项执行、无 batch/delete-all；删除仍只软删除个人数据
  （deletedAt），学校课程/考试/二课不可删（仅用户明确同意后本地隐藏）。
- **职责分离（用户拍板意图）**：复合上限只管"单次批准操作的爆炸半径"，**不管
  工具调用次数**——防死循环由 `ToolCallFingerprint`（完全重复阻断）+ 8×12 预算
  （12 次/run 硬顶）+ M6 迭代告警负责，两道闸各自独立。
- 工具暴露形态（是否新增工具/参数化合并）M6 定（L1-09）。

## 9. C5 壳层契约

- **CT-C5-01**【冻结】`CompleteResetCoordinator` / `AccountMaintenanceCoordinator`：
  UI 只负责确认；协调器调用 C2（§6.4 维护门 + clearSession）/ C3（§7.4）/ C4
  （§8.1 维护期行为），**不持领域规则**；清单预览 + 双确认（completeReset）。
- **CT-C5-02**【冻结】启动序（08 §5.5）：`resetState()` 检测 reset_pending 是
  **强制启动门**——先于正常路由、自动同步与 Agent；恢复失败保持写屏障并进入
  专用恢复界面，禁止按 best-effort 忽略；普通提醒启动/自动同步为 best-effort。
- **CT-C5-03**【冻结】壳层路由契约：分支栈 = `StatefulShellRoute.indexedStack`
  保活（AutomaticKeepAliveClientMixin），禁止改丢栈行为；官方网页经
  CT-C0-05 白名单校验后走 CT-P-04 launcher。
- 生产者：C5。消费者：C5 页面（内部）。

## 10. 并存期契约（M2–M6，M7 删除）

- **CT-T-01**【并存期】Python 通道 = `SourceChannel` 实现（kind=python），
  C2 核心经 P 注入的 CT-P-07/08 编排：进程启动/停止/健康、仅 127.0.0.1 回环 +
  Bearer 握手、事件流转换（长轮询 → JobEvent 八相位语义等价映射）。C2 核心
  不直接引用 dart:io（ADR-018）。
- **CT-T-02**【并存期】Python 通道的浏览器 profile/session 满足同一会话资产
  契约（ADR-019）；用户清会话/completeReset 时与 Native 分区一起全部清理
  （全通道幂等）。
- **CT-T-03**【并存期】通道切换：旧作业终态释放 → sourceGeneration 递增 →
  注册表换通道；旧通道迟到结果被 C2/C3 以 `stale_lease` 拒绝。
- **CT-T-04** M7 移除清单：CT-P-07/08、Python 通道实现、Bridge 客户端、
  `PythonLocator`、`pythonPath` 设置项（ADR-014）；M7 gate=无 Python 依赖。

## 11. 契约矩阵（gate 工件：生产者 × 消费者，无孤儿接口）

| ID | 接口 | 生产者 | 消费者 |
|---|---|---|---|
| CT-C0-01 | BeijingClock | C0 | C1/C2/C3/C4/C5 |
| CT-C0-02 | core/time 工具箱 | C0 | 全部 |
| CT-C0-03 | LeaseStamp | C0（定义） | C2/C3/C4 |
| CT-C0-04 | CredentialProtector | P 实现（端口 C0） | C3、C4 |
| CT-C0-05 | OfficialSiteAllowlist（七主机，精确匹配） | C0 | C5、C4 |
| CT-C0-06 | 错误码注册表 + fail-closed 归一 | C0 | 全部 |
| CT-P-01 | BrowserAutomationPort | P 实现 | C1 |
| CT-P-02 | BrowserSessionAdminPort | P 实现 | C1（日常）、C2（维护流经 C1） |
| CT-P-03 | NotificationPort | P 实现 | C3 提醒协调 |
| CT-P-04 | LauncherPort | P 实现 | C5 |
| CT-P-05 | FileStoragePort | P 实现 | C1 附件转换、C3 迁移器/clearCache |
| CT-P-06 | PlatformDecoderPort | P 实现 | C1 附件转换 |
| CT-P-07 | PythonProcessPort（并存期） | P 实现 | C2 |
| CT-P-08 | LoopbackBridgeTransportPort（并存期） | P 实现 | C2 |
| CT-C1-01 | JobEvent 八相位流 + 类型化终态 | C1 / Python 通道 | C2、C4/C5（经 C2） |
| CT-C1-02 | JobExecutor + SourceJobSpec/JobRequest | C1 | C2 |
| CT-C1-03 | SourceBundle 1.0 | C1 / Python 通道 | C3（经 C2 交接） |
| CT-C1-04 | QueryResult 1.0 封闭字段集 + PythonChannel 显式转换 | C1 / Python 通道 | C4（经 C2 校验）、C3 CatalogService（campus upsert） |
| CT-C1-05 | AttachmentContentConverter | C1 | C4（经 QueryResult）、C3（登记索引） |
| CT-C2-01 | SourceJobGateway（submitSourceJob + submitQuery 入口） | C2 | C5、C4 |
| CT-C2-02 | SourceChannel + 注册表（已安装全集/来源路由） | C2（接口）→ C1 / P 实现 | C2 |
| CT-C2-03 | CredentialSubject + CredentialLease（takePassword 原子） | C3（签发）→ C2（流转） | C1 / Python 通道 |
| CT-C2-04 | 维护独占门 | C2 | C5、C3、C4 |
| CT-C2-05 | sync_runs.trigger 四值 | C2（经 C3 状态服务） | C5、C4 |
| CT-C2-06 | sync_runs.state 六值 | C2（经 C3 状态服务） | C5、C4 |
| CT-C2-07 | retry 契约（1h 退避/手动绕过/启动标记） | C2（经 C3 状态服务） | C5、C4 |
| CT-C2-08 | campus/icourse freshness | C2/C3 | C5、C4 |
| CT-C3-01 | 数据库 + 迁移线（v8=30 表） | C3 | 全部（经服务） |
| CT-C3-02 | importBundle（normal-only，返回 importBatchId） | C3 | C2（唯一调用方） |
| CT-C3-03 | stageFirstLogin/commitFirstLogin/cancelFirstLogin | C3 | C2、C5 |
| CT-C3-04 | stageReauthentication/commitReauthentication/discardProvisionalAuth | C3 | C2、C5 |
| CT-C3-05 | beginReset/finalizeReset/resetState/currentResetEpoch | C3 | C5（启动门）、C2、C4 |
| CT-C3-06 | begin/commit/abortBusinessDataClear | C3 | C5、C2、C4 |
| CT-C3-07 | 六子域服务 + 写服务统一契约 | C3 | C5、C4、C2 |
| CT-C3-08 | 学校稳定身份 upsert | C3 | C5、C4 |
| CT-C3-09 | Task 四态 | C3 | C5、C4 |
| CT-C3-10 | PlanBlock 六态 + 禁止字段 | C3 | C5、C4 |
| CT-C3-11 | 个人事件模型 | C3 | C5、C4 |
| CT-C3-12 | 重复系列 | C3 | C5、C4 |
| CT-C3-13 | 冲突判定序 | C3 | C5、C4 |
| CT-C3-14 | 提醒默认偏移（L2-01） | C3 | C5、C4 |
| CT-C3-15 | 学期三元组 | C3 | C5、C4、C2 |
| CT-C3-16 | 出勤与听讲 | C3 | C5、C4 |
| CT-C3-17 | 撤销（单槽 + 启动清槽） | C3 | C4、C5 |
| CT-C3-18 | 权限策略"记住"=永久（删 expires_at） | C3 | C4、C5 |
| CT-C3-19 | sourceConfigs 复合主键形态 | C3 | C2、C5 |
| CT-C3-20 | clearCache | C3（+P 文件） | C5 |
| CT-C3-21 | SourceStateService（generation + sync run） | C3 | C2 |
| CT-C3-22 | commitCatalogSource（Catalog 来源写入口） | C3 | C4（经 C2 校验后透传） |
| CT-C4-01 | 会话服务预算（8×12、突发 32） | C4 | C4 内部 + C5 展示 |
| CT-C4-02 | 上下文 token 预算 | C4 | C4 内部 |
| CT-C4-03 | 维护期行为 | C4 | C5、C2、C3 |
| CT-C4-04 | AgentLocalDataGateway | C4 | C4 工具 |
| CT-C4-05 | AgentWriteGateway + 审批门（expectedResetEpoch） | C4 | C4 工具、C5 确认卡 |
| CT-C4-06 | 外部查询消费（经 C2） | C4 | C4 工具 |
| CT-C4-07 | 工具安全细则（批≤3、链接≤1 层） | C4 | C4 工具 |
| CT-C4-08 | 工具系统框架（六域，M6 审计定稿） | C4 | M6 审计 |
| CT-C4-09 | 复合写（上限 32【基线】） | C4 | C4 工具、C5 确认卡 |
| CT-C5-01 | CompleteReset/AccountMaintenance 协调器 | C5 | C5 页面 |
| CT-C5-02 | 启动序（reset_pending 强制门） | C5 | C5 页面 |
| CT-C5-03 | 壳层路由 + launcher 白名单校验 | C5 | C5 页面 |
| CT-T-01 | Python 通道（SourceChannel 实现） | P/C2 | C2（M7 删） |
| CT-T-02 | Python 会话资产契约 | P | C2（M7 删） |
| CT-T-03 | 通道切换 generation 递增 | C2/C3 | C2（M7 删） |
| CT-T-04 | M7 移除清单 | 第 2 层契约 / ADR-014 | M7 实施与 gate |

## 12. §2.5 移交登记消化对照（20 项 + 1 补充，逐项一对一；16 项本层消化、4 项移交第 5 层）

| # | 移交项 | 本层消化 |
|---|---|---|
| 1 | SourceBundle 1.0 envelope/manifest/digest 幂等/9 错误码语义；canonical 与 Draft-7 双方言同步 | §5.3（CT-C1-03；9 错误码修正 L2-07） |
| 2 | v7 基线 27 表数据字典 + schemaVersion 迁移线 | §7.1（权威指针 03 §4.2；v8 基线 30 表） |
| 3 | 账号隔离机制（accountId 分区、凭据级联） | §7.1（分区 + CASCADE 纪律） |
| 4 | 北京时间 Asia/Shanghai 唯一业务时区 | §2.1/§2.2（ADR-015 + 线协议例外 A-1；横切细节 → `12-cross-cutting.md`） |
| 5 | 认证回环/Query Protocol 1.0 语义延续 | §5.1/5.2/8.4（进程内事件流 + QueryJob，已消化） |
| 6 | 学校来源按稳定外部身份 upsert | §7.6（CT-C3-08） |
| 7 | 冲突判定序 | §7.6（CT-C3-13；投影细节 → `11-component-designs.md`） |
| 8 | 重复系列稳定身份 + 单次例外；物化上限 | §7.6（CT-C3-12） |
| 9 | 提醒默认偏移（D33） | §7.6（CT-C3-14 全表冻结，L2-01） |
| 10 | Task 四态持久化/派生查询 | §7.6（CT-C3-09） |
| 11 | SourceBundle 范围（仅 JW+二课完整快照） | §5.3（范围条款） |
| 12 | SourceBundle 信封细节（无主键/身份/覆盖/一事务） | §5.3（无主键 + presence + 幂等） |
| 13 | Agent 写提交同事务；不占撤回槽 | §7.5/8.3（CT-C4-05；审批门细节 → `11-component-designs.md`） |
| 14 | 个人事件模型（单次/全天/跨日/基础重复） | §7.6（CT-C3-11） |
| 15 | PlanBlock 禁止字段 | §7.6（CT-C3-10） |
| 16 | 校园目录细则 + 附件受控下载转换归属 | §5.5/8.5（CT-C1-05/CT-C4-07；管道细节 → `12-cross-cutting.md`） |
| 17 | 本地事实来源介质 SQLite | §7.1（CT-C3-01） |
| 18 | Dart String 不可变→零化不可承诺 | → `12-cross-cutting.md` §安全实现约束（本层不展开） |
| 19 | `--save-raw` 落盘与 tmp/private 目录 | → `12-cross-cutting.md` §调试资产（本层不展开） |
| 20 | 本地调试服务仅绑 127.0.0.1 | → `12-cross-cutting.md` §调试服务边界（并存期桥接已在 §10 归口） |
| 21 | （补充）permission expires_at（D34） | §7.7（CT-C3-18：删列 + 记住即永久，L2-02） |

## 13. 本层拍板记录（L2 决策，已全部拍板 2026-08-14——其中 L2-02 经代码核实修订为删列、L2-05 修订为上限 32【基线】、L2-10 增加同事务清槽）

| 编号 | 决策 | 内容 | 依据 |
|---|---|---|---|
| L2-01 | D33 提醒默认偏移冻结 | §7.6 CT-C3-14 全表照搬现状（exam 1440/120、second_class 120、task 1440/120、plan_block 10 特例保留）；M5 只做 UI | 03 §3.4 reminder_rule.dart |
| L2-02 | D34 expires_at 处置（经代码核实修订，用户拍板） | 删列（死列：恒 NULL、决议从不读）+ "此类型以后不再确认"=永久；§7.2 #5 / §7.7 CT-C3-18 | D34、代码核实 2026-08-14 |
| L2-03 | D35 sourceConfigs 主键形态 | **保留现状** `id = '$accountId:$source'` 复合字符串 id + UNIQUE(account_id, source)（04 §5 观测现状即此形态，零迁移；单账号模型不引入 schema 变更） | D35、04 §5 |
| L2-04 | D37 trigger/retry 契约 | trigger 扩展为 4 值（§6.5 CT-C2-05，首登/重认证各自可审计）；state 6 值冻结；retry=自动 1h 退避 + 手动绕过 + 启动 interrupted 标记 | D37、ADR-008/013 |
| L2-05 | D32 复合写上限（用户拍板：暂定 32） | **32 对象/复合操作**【基线】（与 create_task 突发对齐；整体计 1 次工具调用；每对象 ledger；单槽整包撤销快照；禁止无预览 delete-all；上限与防死循环职责分离）§8.6 CT-C4-09 | D32、L1-09、用户拍板 2026-08-14 |
| L2-06 | v8 变更集 7 项冻结 | §7.2：campus 三表字段级冻结、undo_slot.expires_at 删除、action_logs 索引、prompt 版本统一 8、permission expires_at 删除、reset 列落 local_accounts、source_configs.source_generation；v8 = 30 表 | ADR-004/007/010/011/023、D10/D34 |
| L2-07 | SourceBundle 错误码计数修正 | **9 个**（02/03 文档"10 个"为笔误，以 Dart/Python 两侧代码为准，两侧一致） | 代码核实 |
| L2-08 | 作业错误码全集 | §2.4：bridge_busy/bridge_query_busy 废止统一 `busy`；新增 `stale_lease`；fail-closed 归一规则 | ADR-004/016 |
| L2-09 | 官方站点白名单 | CT-C0-05 七主机清单；launcher 与 QueryResult references 共用同一清单 | 红线 2.1-2、02 §4.2 |
| L2-10 | clearBusinessData 清除范围（用户拍板） | §7.4 冻结：15 张业务表 + 目标态同事务清 undo_slot；campus 三表归 clearCache/completeReset；保留项清单 | settings_service.dart:118-168 逐行核实、2026-08-14 拍板 |
| L2-11 | campus 表族字段级冻结 | §7.2 #1 三表（entries/state/attachment_cache）列清单 + 写读方 | ADR-007 |
| L2-12 | Agent 基线参数 | 8×12、突发 32、token 28000/18000/1024、默认模型 deepseek-v4-flash 标【基线】，可调但须修订本文档 | 06 模块文档 |
| L2-13 | 独立审查整改（2026-08-14，报告基线 bf00aa9） | A-1~A-14/B-1~B-9/C-1~C-2 全部关闭（其中 A-10/B-6/v8#7 经用户确认）；新增 CT-C3-19/20、v8 #7；ADR-004/011/015 修订注 | 独立审查报告 |
| L2-14 | 整改复审收口决策（用户批准 2026-08-14） | QueryResult 保持单一 canonical 1.0 + PythonChannel 逐字段转换；CredentialSubject 支持持久/临时主体且首登只内存预分配 accountId；LeaseStamp 显式传播并在全部来源写事务复验；campus id 精确复用旧算法；entries 只用 first/last_observed_at；icourse 只暴露 selectedEvidence 映射后的 evidence | ADR-004/007/016/020/023 修订、CT-C1-04/CT-C2-03/CT-C3-21 |
| L2-15 | 第 3 层走查回写（2026-08-14，主 agent 自审） | `JwCollectionRequest.semester` 改 nullable：null=首登无持久选择（登录后抓列表+月份规则默认），非 null=持久选择 | 10-runtime.md L3-01 |
| L2-16 | 第 3 层独立审查回写（2026-08-14，A-1~A-8/B-1~B-3 整改） | CT-C2-01 增 `submitQuery`（C4 唯一查询入口）+ 仲裁原子取得说明；QueryCompleted 增 attachmentRegistrations 载体、CollectionCompleted 增 selectedSemester；commitFirstLogin 增 selectedSemester 参数；identityDigest 唯一生产者冻结（sha256(utf8(username.trim()))）；discardProvisionalAuth 幂等销毁；completeReset 撤销链顺序；错误码补 maintenance_in_progress；CT-C3-21 计数规则（根操作 reason 一次）；CT-C3-22 补号；07 ADR-020/023 措辞绑定 takePassword/销毁接口 | 第 3 层独立审查报告（基线 a4c9a45） |

## 14. 第 2 层 gate 检查表

- [x] ① 每个接口有生产者和消费者——§11 契约矩阵 65 行逐项双列（含 CT-C3-21/22；一 CT 一行）
- [x] ② 无孤儿字段——§7.2 v8 变更集 7 项每字段标注写方/读方（B-9 整改：campus 三表逐字段读方）；删列 #2/#5 以"孤儿列/死列"为删除理由
- [x] ③ v8 变更集清单冻结（ADR-011）——§7.2 七项 + 30 表核对（L2-06 拍板 + L2-13 整改增 #7）；冻结后变更须开 ADR
- [x] ④ §2.5 移交登记消化——§12 逐项一对一 21 行：16 项本层消化、4 项移交第 5 层、1 项补充（B-4 整改）
- [x] ⑤ D32/D33/D34/D35/D37 契约面落地——§6.5/§7.2/§7.7/§8.6/§13（L2-01~05 全部拍板；D35 已落 CT-C3-19，A-13 整改）
- [x] ⑥ 依赖铁律复核——§5.2 C1 不依赖 C3、§8.4 C4 不直连 C1、§10 C2 核心无 dart:io、C3→P 运行时边已登记（08 §4，B-7 整改）
- [x] ⑦ 独立审查整改闭环——14A/9B/2C 全部落地；复审收口 L2-14 将 QueryResult、
  provisional 凭据主体、LeaseStamp 传播、campus 身份/时间戳与 iCourse evidence 六项
  决策写成可独立实现的冻结签名
- [x] **gate 重认关闭（2026-08-14）**：A-10（07 §2.2-2 解释注：应用自动行为 vs 用户确认维护的分工）/ B-6（七主机精确匹配，补 `www.teach.ustc.edu.cn`）/ v8 #7（`source_configs.source_generation` 加列，generation 权威归 C3）三项经用户确认；L2-14 六项复审收口决策已同步到 ADR/容器/正式签名 → 进入第 3 层 `10-runtime.md`
- [x] **第 3 层审查回写闭环（2026-08-14，L2-16）**：第 3 层独立审查发现的 8A/3B 中属本层契约缺口的部分（A-1 查询入口/A-2 附件载荷载体/A-6 首登数据来源/A-7 provisional 销毁/A-4 计数规则/A-8 补码补号/A-3 原子取得）已回写冻结，第 3 层 gate 随 10-runtime.md 整改后重验
