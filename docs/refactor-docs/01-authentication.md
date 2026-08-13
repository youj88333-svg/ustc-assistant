# 身份认证与账号 技术文档

> 模块编号：01 ｜ 产出日期：2026-08-12 ｜ 覆盖分支：main（HEAD e9d64dd）｜ 探索者：subagent-01

## 1. 职责边界

本模块覆盖端到端认证链路的三段：

1. **学校登录会话（Python 侧）**：USTC 统一身份认证（CAS，id.ustc.edu.cn）的登录页面填写与账号核验、专用可见 Edge 持久会话（persistent profile）的建立与复用，以及各来源收集器（教务 JW、二课课表、二课报名）在会话失效时的"需用户操作"上报。
2. **Bridge 认证回环**：收集/查询作业在需要登录时暂停为 `needs_user_login`，Flutter 侧经用户确认后通过 `/login/resume`、`/query-jobs/{id}/resume-login` 携带可选密码恢复同一作业（不重新建作业）。
3. **Flutter 本地账号与凭据保护**：本地账号 ID 生成/激活/切换、账号隔离（business 数据按 accountId 分区）、凭据经 Windows DPAPI 加密落库、解密时机受控。

**不做什么**：不负责 SourceBundle 1.0 的内容契约（见 02-data-acquisition.md 与 `contracts/source_bundle.py`）；不负责业务数据表完整数据字典（归模块 03）；不负责同步调度策略（freshness/backoff，属同步模块，本模块仅覆盖其中账号与凭据环节）；不负责 Agent 工具权限与 API Key 之外的安全（Agent 模块）。

**上游依赖**：Drift 数据库（`app/lib/core/database/app_database.dart`）、`win32`/`ffi`（DPAPI）、Playwright（`common/browser.py`）、学校站点（jw.ustc.edu.cn / young.ustc.edu.cn / id.ustc.edu.cn）。

**下游消费者**：同步编排（`SyncCoordinator`）、Agent 组装（`router.dart` 中 `_buildWindowsAgentComposition`）、设置页（删除凭据、清除浏览器会话、completeReset）、路由层（登录/重新登录页面组装）。

## 2. 现状·核心组件

### 2.1 Python 侧目录树（本模块范围）

```
src/ustc_assistant/
├── common/
│   ├── auth.py              # CAS 登录边界：选择器、填表、账号核验、profile 路径
│   └── browser.py           # 专用 Edge 持久会话的启动/关闭
├── bridge/
│   ├── protocol.py          # Bridge 协议原语（版本常量、握手、请求解析）
│   ├── jobs.py              # 收集作业状态机 + 作业管理器（认证回环的服务端）
│   ├── server.py            # loopback HTTP 服务：Bearer 认证 + 端点分发
│   └── query_jobs.py        # 查询作业状态机（young_enrolment 的 resume-login）
└── sources/
    ├── jw/collector.py      # JW 登录保证（_ensure_authenticated）与数据采集
    ├── young/schedule.py    # 二课课表收集的登录循环
    └── young/enrolment.py   # 二课报名查询的登录循环（查询侧认证回环）
```

### 2.2 Flutter 侧目录树（本模块范围）

```
app/lib/
├── core/
│   ├── security/
│   │   ├── credential_protector.dart      # 凭据保护抽象（ProtectedSecret + 接口）
│   │   └── windows_dpapi_protector.dart   # DPAPI 实现（CryptProtectData/UnprotectData）
│   └── database/
│       ├── app_database.dart              # 数据库装配、activeAccountChanges 广播、迁移
│       └── tables/account_tables.dart     # local_accounts / credential_accounts 表
└── features/
    ├── accounts/
    │   ├── application/account_service.dart    # 账号/凭据领域服务（本模块核心）
    │   └── presentation/accounts_page.dart      # 学校账号页（切换/重新登录/删凭据/清会话）
    ├── sync/
    │   ├── application/sync_coordinator.dart    # 首次登录/重新认证/恢复登录编排
    │   ├── data/bridge_client.dart              # Bridge 客户端（握手、收集、轮询、resumeLogin）
    │   └── presentation/sync_page.dart          # 首次登录/重新登录表单 + 交互登录确认
    └── settings/
        └── application/settings_service.dart    # 删除凭据/清除会话/completeReset 编排
```

### 2.3 关键组件职责

| 组件 | 职责 | 关键证据 |
|---|---|---|
| `src/ustc_assistant/common/auth.py` | CAS 登录边界：选择器常量（用户名/密码/提交按钮/账号探针）、`LoginCredentials`、`fill_ustc_login`（仅限 `id.ustc.edu.cn` 等白名单 origin 填表并尝试自动点提交）、`verify_ustc_account`（DOM 属性 + performance entries + localStorage/sessionStorage 三层核验）、`profile_dir_for_account`（账号 ID 的 sha256 前 24 位作为 Edge profile 目录名） | `src/ustc_assistant/common/auth.py:15-23`（选择器）、`:80-96`（fill）、`:147-182`（verify）、`:59-70`（profile 路径） |
| `src/ustc_assistant/common/browser.py` | 专用 Edge 持久会话：`run_in_edge` 用 `launch_persistent_context(channel="msedge", headless=...)`；默认 profile 目录 `%LOCALAPPDATA%/USTC Campus Assistant/edge-profile`；`CollectionError` 为可向用户展示的安全错误基类 | `src/ustc_assistant/common/browser.py:20-23`（默认目录）、`:26-53`（run_in_edge） |
| `src/ustc_assistant/bridge/jobs.py` | 收集作业状态机：`CollectionJob.phase`（starting → checking_session/waiting_for_user → collecting → needs_user_login / complete / cancelled / failed）；`JobManager` 单活跃作业（`BridgeBusy`）；`resume_login` 校验 `expected_username` 与暂停态 | `src/ustc_assistant/bridge/jobs.py:53-204`（状态机）、`:225-227`（单活跃）、`:271-283`（resume_login） |
| `src/ustc_assistant/bridge/server.py` | loopback HTTP 服务：`Authorization: Bearer <token>` 恒等校验（HMAC）；端点 `/collect/jw`、`/collect/young-schedule`、`/login/resume`、`/jobs/{id}/events|cancel`、`/query-jobs/{id}/resume-login|cancel`、`/capabilities`、`/health`、`/shutdown`；空闲 10 分钟或父进程退出即停 | `src/ustc_assistant/bridge/server.py:133-140`（认证）、`:50,92-102`（停止条件）、`:355-431`（collect/resume）、`:440-470`（query resume） |
| `src/ustc_assistant/bridge/protocol.py` | 协议常量：`PROTOCOL_VERSION = "1.0"`、`QUERY_PROTOCOL_VERSION = "1.0"`、`MAX_REQUEST_BYTES = 64KB`；握手（随机 token + port + pid）、请求体解析与版本校验 | `src/ustc_assistant/bridge/protocol.py:10-12`（常量）、`:21-27`（握手）、`:30-43`（解析） |
| `src/ustc_assistant/bridge/query_jobs.py` | 查询作业状态机，与收集作业同构；仅 `young_enrolment` 可进入 `needs_user_login` 并接受凭据，icourse/campus 公开查询从不接收凭据；`ReadQueryJobManager.resume_login` | `src/ustc_assistant/bridge/query_jobs.py:12-14`（凭据边界）、`:273-282`（resume_login）、`:211-405`（状态机） |
| `src/ustc_assistant/sources/jw/collector.py` | JW 登录保证 `_ensure_authenticated`：访问 `jw.ustc.edu.cn/` → 已登录（`/home` 正则）直接复用会话并 `verify_ustc_account`；未登录且不允许交互 → `UserActionRequired`；允许交互 → 跳 CAS 入口、`fill_ustc_login`、`wait_for_url(/home, 5min)` | `src/ustc_assistant/sources/jw/collector.py:147-183` |
| `src/ustc_assistant/sources/young/schedule.py`、`enrolment.py` | 二课侧登录循环（各自独立实现，不复用 `_ensure_authenticated`）：轮询目标页可见性，未登录时在 CAS origin 填表一次，超时抛 `CollectionError`；`collect_activities`/`collect_schedules` 同样经 `profile_dir_for_account` + `run_in_edge` | `src/ustc_assistant/sources/young/enrolment.py:165-227`、`:290-318`；`src/ustc_assistant/sources/young/schedule.py:204-262,394-426` |
| `app/lib/core/security/credential_protector.dart` | 凭据保护抽象：`ProtectedSecret{bytes, scheme, version, metadata}`、`CredentialProtector.protect/unprotect`、`CredentialProtectionException` | `app/lib/core/security/credential_protector.dart:3-30` |
| `app/lib/core/security/windows_dpapi_protector.dart` | DPAPI 实现：scheme `windows-dpapi-current-user`、version 1、`CRYPTPROTECT_UI_FORBIDDEN`；保护/解保护后明文缓冲区零化 | `app/lib/core/security/windows_dpapi_protector.dart:9-12`、`:24-31`（protect）、`:69-76`（unprotect）、`:44-47,84-87`（零化） |
| `app/lib/features/accounts/application/account_service.dart` | 账号领域服务：首次登录 staged 流程、重新认证（identity digest 校验）、凭据加密落库、账号切换、`usernameForSync`/`passwordForInteractiveLogin` 受控解密 | `app/lib/features/accounts/application/account_service.dart:91-144`（stage）、`:146-238`（confirm）、`:285-318`（switch）、`:347-380`（解密出口） |
| `app/lib/core/database/tables/account_tables.dart` | `local_accounts`（id/maskedHint/identityDigest/isActive/时间戳）+ `credential_accounts`（密文 + scheme/version/metadata，FK 级联删除） | `app/lib/core/database/tables/account_tables.dart:3-16`、`:18-34` |
| `app/lib/features/sync/application/sync_coordinator.dart` | 认证编排：`firstLoginSync`（provisional 账号）、`reauthenticate`、`resumeInteractive`（用户确认后取密码并 `resumeLogin`）；凭据缺失 → `reauthentication_required` | `app/lib/features/sync/application/sync_coordinator.dart:159-203`（firstLogin）、`:205-255`（reauthenticate）、`:257-288`（resumeInteractive）、`:90-99`（凭据缺失） |
| `app/lib/features/sync/data/bridge_client.dart` | Bridge 客户端：握手（stdout 首行 JSON）、`capabilities`、`startCollection`、`poll`（`/jobs/{id}/events?after=&waitMs=15000`）、`resumeLogin`、`cancel`、`shutdown`；`BridgeProtocolError` 安全码白名单 | `app/lib/features/sync/data/bridge_client.dart:179-327`、`:11-20`（安全码） |
| `app/lib/features/settings/application/settings_service.dart` | 删除凭据、清除浏览器会话、`completeReset`（删 `action_logs`/`undo_slot`/`local_accounts` 行 + 浏览器会话清理，失败抛 `BrowserSessionClearAfterResetError`） | `app/lib/features/settings/application/settings_service.dart:108-116`、`:170-190` |

## 3. 现状·关键数据流

### 流程 A：首次登录（账号创建与凭据落库）

```
SyncPage._firstLogin ──► SyncCoordinator.firstLoginSync
  (sync_page.dart:321-352)   (sync_coordinator.dart:159-203)
        │  1. accountIdFor(username)：解密全部已存 username 密文比对查重（合并已有账号）
        │  2. stageLogin(provisional=uuid.v4 或已有 id)：暂存 username/password/savePassword 于内存
        │  3. BridgeClient.start ──► Python Bridge 握手
        │  4. startCollection(/collect/jw 或 /collect/young-schedule)
        ▼
Python CollectionJob（jobs.py）──► collector 非交互模式（headless）
        │  会话失效 → UserActionRequired → job.phase = needs_user_login
        ▼
Flutter _consume 轮询 events（bridge_client.poll）
        │  lastPhase == needs_user_login → _paused[jobId] 存续（sync_coordinator.dart:304-318）
        ▼
用户确认（sync_page.dart:297-319 对话框）→ resumeInteractive
        │  首次登录取 staged 密码（不落库）→ bridge.resumeLogin(/login/resume, password?)
        ▼
job.start(interactive=True) 重跑（可见 Edge 窗口，headless=False）
        │  collect_sources(allow_interactive_login=True, credentials=LoginCredentials)
        ▼
complete（bundle 校验通过）→ _consume 收到 result
        │  accounts.confirmSuccessfulLogin(verifiedUsername)：
        │    全部账号 isActive=false → 新账号 isActive=true（同 username 复用原 id）
        │    username 必存密文 + password 按 savePassword 存密文 → credential_accounts
        ▼
importBundle（SourceBundle 落库）→ notifyActiveAccountChanged 广播
```

### 流程 B：认证回环（会话失效 → 暂停 → 恢复）

```
同步进行中（job.phase=collecting），学校会话失效：
  collector: page.goto(JW_ROOT_URL) 未命中 /home → allow_interactive_login=False
    → raise UserActionRequired(jobs.py:142-143 捕获 → _emit("needs_user_login"))
        │
        ▼
  Flutter poll 返回 lastPhase="needs_user_login"（sync_coordinator.dart:304-318）
  → SyncNeedsUserAction(source, jobId) → UI 对话框："继续后将打开可见浏览器；仅在你确认后才会读取已保存密码"
        │
        ├─ 取消：bridge.cancel(jobId) → job 终态 cancelled
        └─ 确认：resumeInteractive（sync_coordinator.dart:257-288）
            老账号：passwordForInteractiveLogin(accountId)（DPAPI 解密已存密码，可为 null）
            新登录：stagedPasswordForInteractiveLogin（内存暂存）
            → bridge.resumeLogin(jobId, password) → POST /login/resume
            → 服务端校验 job.phase==needs_user_login 且 username 匹配（jobs.py:271-283）
            → job.start(interactive=True)：headless=False 的可见 Edge + credentials
            → 同一 jobId 恢复轮询（不新建作业）
```

### 流程 C：账号激活与切换（账号隔离的本地语义）

```
switchAccount(accountId)（account_service.dart:285-318）：
  事务内：全部 isActive=false → 目标 isActive=true → actionLogs 记 account_switch
  → notifyActiveAccountChanged()（app_database.dart:56-58）
  → 订阅方（router.dart:549 的 activeAccountChanges）重建各页面/Agent 组装

隔离语义：
  - 业务数据绑定：calendarEvents/sourceRecords/… 均带 accountId 列；
    AccountService.eventsFor(accountId) 按账号过滤（account_service.dart:416-418）
  - 同步状态绑定：sourceConfigs 主键 "$accountId:$source"（sync_coordinator.dart:530）
  - 浏览器会话隔离：每个账号独立 Edge profile 目录
    sha256(account_id)[:24]（auth.py:59-70）
  - 凭据级联：credential_accounts.accountId FK onDelete cascade（account_tables.dart:20）
```

### 流程 D：凭据保护链路（DPAPI）

```
保护（写）：
  confirmSuccessfulLogin（account_service.dart:174-181）：
    username 明文 → protector.protect() → CredentialAccounts(usernameCiphertext,
    scheme='windows-dpapi-current-user', version=1, metadata={"scope":"current_user"})
    savePassword 时 password 同样 protect；scheme/version 与 username 不一致即抛
    CredentialProtectionException('inconsistent_scheme')
    明文缓冲零化（unprotect 路径在 finally 中 fillRange(0, len, 0)）

解密（读）时机（共 4 处，均"即时解密、用完即零化"）：
  1. accountIdFor —— 首次登录按 username 查已有账号（account_service.dart:253-279）
  2. usernameForSync —— 每次同步启动时取 expectedUsername（:347-355）
  3. passwordForInteractiveLogin —— 用户确认交互登录时取已存密码（:363-380）
  4. _ensureIdentityDigest —— 迁移补写 identityDigest（:430-453）

Agent 侧复用同一 protector：ProtectedAgentSecretStore（API Key 保护，
protected_agent_secret_store.dart:27-82），属于 Agent 模块。
```

## 4. 现状·接口契约

### 4.1 认证回环协议（全局契约锚点之一）

实际名称：**没有独立命名的"认证回环协议"文件**；它在 main 中体现为 Bridge HTTP 协议 1.0 的一组端点与作业事件格式（`PROTOCOL_VERSION = "1.0"`，`src/ustc_assistant/bridge/protocol.py:10`；Flutter 侧 `bridgeProtocolVersion = '1.0'`，`bridge_client.dart:9`）。docs/architecture.md 第 17 行称"认证回环"，第 223 行称"Python Bridge Query Protocol 1.0"（架构文档仅作线索，名称以代码为准）。

- 握手：Bridge 启动后向 stdout 写一行 JSON `{protocolVersion, port, token, pid}`（`protocol.py:21-27`、`server.py:319-325`）；token 为 `secrets.token_urlsafe(32)`，每次进程启动重新生成。
- 请求认证：`Authorization: Bearer <token>`，HMAC 恒等比较（`server.py:133-140`）；请求体须带 `protocolVersion: "1.0"`（`protocol.py:41-42`）。
- 收集端点：`POST /collect/jw`（`server.py:355-391`）与 `POST /collect/young-schedule`（`:392-412`），载荷 `{protocolVersion, accountId, expectedUsername, semester?}`；返回 `202 {jobId, phase}`。
- 恢复端点：`POST /login/resume`，载荷 `{protocolVersion, jobId, password?}`（密码上限 1024 字符），返回 `202 {jobId, phase}`（`server.py:413-431`）。查询侧：`POST /query-jobs/{id}/resume-login`，仅 `young_enrolment` 且 phase==`needs_user_login` 可恢复（`:440-470`）。
- 事件轮询：`GET /jobs/{id}/events?after=<seq>&waitMs=<0..20000>`，返回 `{events:[{sequence,phase,safeCount?}], nextSequence, terminal, result?, error?}`（`jobs.py:183-204`、`server.py:175-193`）；phase 取值 `starting | checking_session | waiting_for_user | collecting | needs_user_login | complete | cancelled | failed`（`jobs.py:23-24,53-74`）。
- 其余：`GET /capabilities`（协议版本 + 查询类型 + 默认学期三元组，`server.py:152-173`）、`GET /health`、`POST /jobs/{id}/cancel`、`POST /shutdown`。

### 4.2 AccountService 对外 API（Flutter 侧被消费的契约）

- `ProvisionalAccount beginFirstLogin()` / `cancelFirstLogin()` —— 首次登录暂存（`account_service.dart:82-89`）
- `stageLogin(...)` / `stageReauthentication(accountId, username, ...)` —— 重新认证校验 `identityDigest` 匹配后进入 staged（`:91-144`）
- `confirmSuccessfulLogin(verifiedUsername) -> accountId` —— 登录成功后落库并激活（`:146-238`）
- `accountIdFor(username)` —— 密文比对查重（`:253-279`）
- `activeAccount()`、`switchAccount(accountId)`、`summaries()`（`:281-345`）
- `usernameForSync(accountId)`、`passwordForInteractiveLogin(accountId)`、`hasCredentials(accountId)`（`:347-380`）
- `deleteCredentials(accountId)`、`clearDedicatedBrowserSession()`（`:391-414`）
- `eventsFor(accountId)` —— 业务数据按账号过滤的示例（`:416-418`）

消费方：`SyncCoordinator`（`sync_coordinator.dart:105,170-177,217-222,274-276`）、`router.dart:709-713`（Agent 组装取 username）、`settings_service.dart:110,115,186`、`accounts_page.dart`、`sync_page.dart`。

### 4.3 本模块消费的外部契约

- `CredentialProtector` 接口（`credential_protector.dart:26-30`），实现注入点：所有 `AccountService` 构造处均注入 `WindowsDpapiProtector()`（`router.dart:149,460,711`、`sync_page.dart:27,103`）。
- `BridgeGateway` 接口（`bridge_client.dart:85-102`），由 `BridgeClient` 实现；Agent 侧经 `BridgeQueryGateway`（`:107-118`）复用同一客户端（`windows_python_query_gateway.dart:50-53`）。
- `SourceBundle 1.0`：收集结果在作业内经 `validate_source_bundle` 校验后才置 `complete`（`jobs.py:135`）；bundle 携带 `subject.accountId`（`contracts/source_bundle.py:18-52`）——数据内容归模块 02。
- 凭据从不进入作业事件：`jobs.py:156-157`（finally 置 credentials=None）、`query_jobs.py:343`；查询事件仅含 `safeCount`（`query_jobs.py:21` 注释）。

## 5. 现状·错误处理

### 5.1 Python 侧异常与错误码

| 异常/错误码 | 含义 | 触发位置 | Bridge 映射 |
|---|---|---|---|
| `AuthBoundaryError`（code=auth_boundary） | 登录页非白名单 CAS origin | `auth.py:26-27,80-82` | 收集失败 → `collection_failed` |
| `UserActionRequired`（code=needs_user_action） | 会话失效且不允许交互登录 | `collector.py:164-165`、`enrolment.py:189-192`、`schedule.py:226-227` | 作业暂停为 `needs_user_login`（`jobs.py:142-143`） |
| `AccountMismatch`（code=account_mismatch） | 已认证账号与 expectedUsername 不符；resume 用户名不匹配 | `auth.py:182`、`jobs.py:278-281` | HTTP 409 `invalid_job_state`（`server.py:257-259`）；作业 `failed/account_mismatch`（`jobs.py:146-151`） |
| `CollectionCancelled`（code=cancelled） | 取消回调触发 | `auth.py:73-77` | 作业 `cancelled` |
| `CollectionError` | 可展示的安全错误（超时/结构异常） | `browser.py:16-17` 及各收集器 | 作业 `failed/collection_failed` |
| `ProtocolError`（too_large/invalid_json/unsupported_version） | 请求解析失败 | `protocol.py:30-43` | HTTP 400/409/413（`server.py:236-242`） |
| `BridgeBusy` / `JobNotFound` / `InvalidJobState` | 单活跃作业冲突 / 作业不存在 / 状态不允许 | `jobs.py:27-37,225-227` | HTTP 409/404（`server.py:245-259`） |

### 5.2 Flutter 侧错误码与重试

- `AccountVerificationError`（`blank_username / account_not_found / account_identity_missing / identity_mismatch / no_staged_login / credentials_not_found`，`account_service.dart:10-17`）：同步失败码映射 `credentials_not_found → reauthentication_required`（`sync_coordinator.dart:121-126`）。
- `BridgeProtocolError`：服务端错误码经白名单归一（`bridge_client.dart:11-20`，白名单外一律 `request_failed`，防错误码注入）。
- 重试策略：同步 fresh 窗口 12h、失败后 `retryAfter = now + 1h`（`sync_coordinator.dart:56-57,365-388`）；自动同步遇到 `needs_user_login` 一律不弹窗（`resolveUserAction: (_) async => false`，`sync_page.dart:280-282`）。
- 恢复路径：`SyncNeedsUserAction` 持 jobId，`resumeInteractive` 用同一 Bridge 连接续跑（`sync_coordinator.dart:257-288`）；`_paused` 表按 jobId 存续，找不到则 `SyncFailed(job_not_found)`。

## 6. 现状·观测点

- **落库状态**：
  - `local_accounts`（id/maskedHint/identityDigest/isActive/createdAt/updatedAt）与 `credential_accounts`（密文 + scheme/version/metadata），`account_tables.dart:3-34`。
  - 同步状态 `sourceConfigs`：`lastSuccessAt`、`retryAfter`、`configJson`（含学期三元组），`sync_coordinator.dart:500-544`；`syncRuns` 记录每次运行（`:439-473`）。
  - 重启恢复：`recoverInterruptedRuns()` 将 `running → interrupted(app_restarted)`（`sync_coordinator.dart:390-401`），同步页据此显示"上次同步失败"而非悬挂。
- **审计日志**（`actionLogsRepository.append`，`app_database.dart:197-231`）：本模块落 `credential_saved / credential_updated / account_switch / credential_deleted / browser_session_cleared`（`account_service.dart:225-231,310-315,398-403,407-414`），`source_sync` 结果由同步模块落。
- **事件广播**：`notifyActiveAccountChanged()`（`app_database.dart:49-58`），消费方：Agent 聊天页重建（`router.dart:549-555`）、账号页刷新。
- **可恢复性**：Edge 持久 profile 使学校登录会话跨应用重启存活（`collector.py:158-162` 直接复用 `/home`）；Bridge 每次由 Flutter 按需启动，token 每次新建（`bridge_client.dart:193-244`）。

## 7. 端到端链路参与

- **completeReset** → 本模块：`SettingsService.completeReset` 事务删 `action_logs`/`undo_slot`/`local_accounts`（级联删 `credential_accounts`），随后 `accounts.clearDedicatedBrowserSession()`（`settings_service.dart:170-190`）→ 浏览器侧清理实现见第 10 节存疑事项 → 上游：设置模块；下游：路由跳回 `/sync`（`router.dart:468`）。
- **同步** → 本模块：凭据解密出口（`usernameForSync`/`passwordForInteractiveLogin`/staged）、认证回环（`needs_user_login` → resumeLogin）→ 见 02-data-acquisition.md（采集与 SourceBundle 导入）。
- **Agent 查询** → 本模块：Agent 组装取 `usernameForSync`（`router.dart:713`）；二课报名查询的认证回环复用 Bridge 查询侧（`/query-jobs/{id}/resume-login`，`windows_python_query_gateway.dart:207`）→ Agent 模块文档。
- **数据字典**：`local_accounts`/`credential_accounts` 完整列语义归模块 03；本模块仅定义账号 ID 生成（uuid.v4，`account_service.dart:82`）、激活（单一 `isActive=true`）、切换（事务内全量置位）与业务数据绑定（accountId 列分区）。

## 8. 原生目标态对照

> 本节全部内容标注【目标态推断】。不引用任何既有 flutter-native 设计文档，只描述方向与开放决策。

1. **职责保留/消失/合并**【目标态推断】：身份认证与账号是端到端必需职责，最终形态中**保留**，但实现载体变化——Python 侧 CAS 自动化（Playwright + Edge profile）与 Bridge 认证回环随 Bridge 消失，登录会话改由 Flutter 平台侧（WebView 登录容器或原生 HTTP 适配）承载；"学校登录会话"与"本地账号模型"两段职责合并为 Flutter 单侧实现，本地账号/凭据模型（`AccountService` + 表结构）大概率原样保留。
2. **会保留的契约**【目标态推断】：`CredentialProtector` 抽象（实现从 DPAPI 可替换为平台安全存储）；`AccountService` 的对外 API（staged 登录、identity digest 校验、受控解密出口）；账号隔离语义（accountId 分区、单一活动账号）；`needs_user_login` 的"暂停-恢复同一作业"交互模型（去掉 Bridge 传输层后语义不变）。
3. **开放决策**（待决策，不替重构者决定）：
   - 登录会话方案：Edge 持久 profile（现状）在 WebView 承载下的等价物——独立 WebView 数据分区 vs 共享 cookie 容器；会话持久化层级（磁盘 vs 内存）。
   - 密码自动填充与"仅确认后读取已存密码"的信任边界在原生侧的呈现方式。
   - 多账号会话并行度：现状为单活跃作业 + 单 profile 互斥（`jobs.py:225-227`），原生化后是否需要并行。
   - 学校会话失效的探测时机：现状为"开始收集时才探测"（`collector.py:157-162`），是否引入主动会话健康探测（见第 9 节建议 1）。

## 9. 开源参考与优化建议

参考材料（公开文档，经 WebSearch 获取）：
- Auth0 会话管理文档（Session Layers / Session Lifecycle / Native-to-Web SSO Best Practices）：三层会话（应用/授权服务器/IdP）、idle+absolute 双超时、cookie 安全属性（Secure/HttpOnly/SameSite）、"登出必须是真登出"（清 cookie 同时撤销服务端会话）、refresh token rotation。
- ORY Kratos 会话文档（Cookie settings / Session Management）：会话 cookie 加密、`/sessions/whoami` 作为认证状态探测端点、cookie 自动刷新窗口（`earliest_possible_extend`）、AAL 分级、原生端 token-exchange。
- Keycloak 管理用户会话（Red Hat build 文档）：SSO Session Idle 与 SSO Session Max 分离、Client Session 覆盖、并发会话上限（`SSO_SESSION_MAX_PER_USER`）、会话吊销策略（revocation policy）。

可借鉴模式与本模块具体可落地建议：

1. **主动会话健康探测（借鉴 Kratos whoami）**：现状在收集动作内部才探测会话（`collector.py:157-162`），用户点击同步后才得知需要登录。可落地：在 `GET /capabilities` 同级别的轻量端点（或收集前的 dry-run 探测）判断学校会话是否有效，使 UI 在"同步全部"前就显示"需要重新登录"，避免弹出可见 Edge 窗口失败后再交互。
2. **登出语义落地（借鉴 Auth0"logout must be real"）**：现状"清除专用浏览器会话"在 main 上是 no-op（见第 10 节），Edge profile 目录从未被删除。可落地：实现 `clearBrowserSession` 真实删除账号对应 profile 目录（`edge-profiles/<sha256[:24]>`），同时保留"删凭据"与"清会话"两个操作的独立语义（对应 Auth0 的分层登出）。
3. **会话超时双层模型（借鉴 Keycloak/Auth0 idle+max）**：学校侧会话生命周期不受本应用控制，但本地侧可落地：以 `sourceConfigs.lastSuccessAt` 为基准展示会话老化提示（现已有 12h fresh 窗口），并考虑为"已保存密码"与"仅浏览器会话"分别设置老化提示阈值（如密码 30 天、会话 12h），与 Keycloak"client session 短于 realm session"的层次一致。
4. **凭据轮换感知（借鉴 Auth0 refresh token rotation）**：学校密码变更后收集会得到 `account_mismatch`（`jobs.py:146-151`）。可落地：`account_mismatch` 错误码在 UI 直接引导重新认证（现状已映射为失败码，但未区分"账号不匹配"与"其他失败"的引导文案——`sync_page.dart:375-380` 统一显示"重新登录失败"）。
5. **凭据最小化传播（与 Kratos 非浏览器客户端 token 设计一致）**：现状已做到凭据不进事件流、密码仅 `/login/resume` 单路径传输（`query_jobs.py:12-21`、`windows_python_query_gateway.dart:44-48` 注释）。可落地：保持该边界，并在日志审计中补充"密码曾于何时被解密读取"（现状 `_log` 不记录解密事件）。

## 10. 未验证/存疑事项

**已验证路径**（可直接引用）：`src/ustc_assistant/common/auth.py`、`common/browser.py`、`bridge/protocol.py`、`bridge/jobs.py`、`bridge/server.py`、`bridge/query_jobs.py`、`sources/jw/collector.py`、`sources/young/schedule.py`、`sources/young/enrolment.py`、`app/lib/core/security/credential_protector.dart`、`windows_dpapi_protector.dart`、`features/accounts/application/account_service.dart`、`core/database/tables/account_tables.dart`、`features/sync/application/sync_coordinator.dart`、`data/bridge_client.dart`、`presentation/sync_page.dart`、`features/settings/application/settings_service.dart`、`tests/test_auth.py`、`app/test/features/accounts/account_service_test.dart`。

**存疑/未验证事项**：

1. **浏览器会话清理是 no-op（重要差异）**：`AccountService.clearDedicatedBrowserSession()` 调用的 `clearBrowserSession` 回调在全部 5 处构造点（`router.dart:147-150,458-461,709-712`、`sync_page.dart:25-28,101-104`）均未注入实现，默认 `_noop`（`account_service.dart:70-72,515`）。即"清除专用浏览器会话"（`settings_page.dart:132-139`）与 `completeReset` 中的清理（`settings_service.dart:186`）在 main 上**不会删除任何 Edge profile 文件**，仅写一条 `browser_session_cleared` 日志。与 UI 文案"只清除专用 Edge 登录会话"矛盾——可能是迁移过渡期的有意占位，未验证。
2. **Edge profile 目录生命周期**：`profile_dir_for_account` 计算路径 `%LOCALAPPDATA%\USTC Campus Assistant\edge-profiles\<sha256[:24]>`（`auth.py:59-70` + `browser.py:20-23`），但 main 中没有任何代码删除或列举该目录（除 no-op 的清除入口外）；`run_in_edge` 只 `mkdir(parents=True)`（`browser.py:34`）。
3. **账号核验的盲区**：`verify_ustc_account` 依赖页面 DOM 属性、performance entries 与 storage（`auth.py:147-182`）；若登录后页面恰好不暴露账号（无 `data-ustc-account`/`fine_username`/storage 命中），会直接抛 `AccountMismatch`——密码错误、短信验证码、风控验证码等中间态的实际表现未在 main 中验证。
4. **交互登录的可见性约束**：`fill_ustc_login` 自动点提交按钮对"按钮 disabled 或未渲染"静默回退（`auth.py:86-96`），依赖用户手动操作；CAS 验证码场景无自动化覆盖，未验证。
5. **账号切换与进行中作业**：`SyncCoordinator._busy`（`sync_coordinator.dart:59`）防并发同步，但切换账号（`switchAccount`）不取消进行中的 Bridge 作业——作业完成后的导入会落到新活动账号吗？未在 main 找到关联取消逻辑，行为未验证。
6. **单活跃作业的并发边界**：`JobManager` 拒绝并发收集（`jobs.py:225-227`），但查询作业（`ReadQueryJobManager`）与收集作业是两套互斥锁，同一 Edge profile 目录上收集与查询可同时进行（都指向同一账号 profile）——并发安全未验证。
7. **Bridge 空闲超时**：`IDLE_TIMEOUT_SECONDS = 600`（`server.py:50`）+ 父进程存活检测（`:92-102`）；长交互登录（5 分钟超时，`collector.py:41`）期间若无轮询且空闲超时是否误杀作业——未验证（事件轮询 `waitMs` 上限 20s，`server.py:184-185`）。
8. **DPAPI 平台假设**：`WindowsDpapiProtector` 依赖 win32 `CryptProtectData`；非 Windows 构建/运行行为未验证（agent 组装 `_buildWindowsAgentComposition` 已是 Windows 专属路径）。
9. **`/login/resume` 仅携带密码、用户名取自作业**（`server.py:413-431` 用 `job.request.expected_username`）——若用户在学校侧换了账号登录，`verify_ustc_account` 会抛 `AccountMismatch`（`collector.py:161-162`），最终 `failed/account_mismatch`；该路径的 UI 恢复引导未验证。
10. **架构文档差异**：docs/architecture.md 第 296-298 行描述的"二课查询登录恢复"与代码一致（`server.py:440-470`），但其第 82-84 行"WindowsDpapiProtector 保护 API Key"等表述仅作线索，本文档结论均以代码为准。
