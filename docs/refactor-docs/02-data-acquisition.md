# 数据获取与同步执行 技术文档

> 模块编号：02 ｜ 产出日期：2026-08-12 ｜ 覆盖分支：main ｜ 探索者：subagent-02

## 1. 职责边界

本模块是"全部数据获取能力"的载体，由四部分组成：

1. **五条 Python 数据链路**（`src/ustc_assistant/sources/`）：jw（教务课表+考试）、young-schedule（二课已报名课表）、young-enrolment（二课报名活动列表）、icourse（公共选课评价）、campus（校园公开信息目录+详情）。
2. **契约层**（`src/ustc_assistant/contracts/` 与 `schemas/source-bundle-1.0.schema.json`）：SourceBundle 1.0 与 Query Result 1.0 的定义、构建、校验、Draft-7 导出。
3. **Bridge 执行通道**（`src/ustc_assistant/bridge/`）：只监听 127.0.0.1 的临时 HTTP 服务、采集作业状态机（CollectionJob）、查询作业状态机（ReadQueryJob）、HTTP 端点与错误码映射。
4. **Flutter 同步执行端**（`app/lib/features/sync/`）：Python 定位、Bridge 进程拉起与握手、同步编排（新鲜度窗口、退避重试、busy 互斥）、同步页 UI；以及 `app/lib/core/config/generated_source_defaults.dart` 默认学期常量。

**本模块做什么**：采集/查询学校数据源并产出结构化契约、通过 Bridge 暴露给 Flutter、驱动同步流程并把结果交给导入端。

**本模块不做什么**：不做导入落库（消费方为 import feature 的 `ImportService.importBytes`，见第 4 节）；不做 Agent 查询工具语义（消费方为 `app/lib/features/agent/data/windows_python_query_gateway.dart`，属模块 06）；不做账号凭据管理（消费方为 `AccountService`）。

**依赖谁（上游）**：
- `src/ustc_assistant/common/`：`auth.py`（登录/校验/取消检查）、`browser.py`（`run_in_edge` 可见 Edge 持久化 profile 启动器，`src/ustc_assistant/common/browser.py:26-53`）、`storage.py`（CLI 落盘）。
- `src/ustc_assistant/config.py`：`JwSemesterConfig` 与默认学期加载（`config.py:16-19,51-72`），数据源为 `config/source-defaults.json`。
- Flutter 侧：`app/lib/core/database/app_database.dart`（syncRuns/sourceConfigs/actionLogs 表）、`AccountService`（凭据/暂存登录）、`SettingsService`（保存的 Python 路径）。

**被谁依赖（下游）**：
- `app/lib/app/app.dart:62` 启动时调用 `runStartupAutomaticSync`；`app/lib/app/router.dart:158,167` 挂载 `SyncPageLoader`。
- import feature 消费 `BundleImport`（同步完成后的 SourceBundle 落库）。
- agent feature 消费 `BridgeQueryGateway`（同一 Bridge 进程上的查询通道）。
- `app/lib/app/router.dart:716-731`：Agent 组合侧复用 `PythonLocator().locate`（`requiredModule: 'ustc_assistant.bridge.query_jobs'`）与 `resolveBridgeLaunchOptions()` 拉起同一 Bridge。

**独立执行面**：CLI（`src/ustc_assistant/cli.py`）提供五条链路的离线入口（collect jw / young-enrolment / young-schedule / campus，query icourse / campus，read campus，config generate-flutter-defaults），是"数据获取"的另一条执行通道，虽不与 Bridge 共享进程，但复用同一批采集/转换函数，故纳入本模块边界。

## 2. 现状·核心组件

```
src/ustc_assistant/
├── sources/
│   ├── jw/                # 教务链路（课表+考试）
│   │   ├── collector.py   # Playwright 采集（Edge 持久化 profile）
│   │   ├── source_bundle.py # build_jw_source_bundle → SourceBundle 1.0 (ustc_jw)
│   │   ├── course.py      # 课表行解析/合并/转换（含 legacy convert）
│   │   ├── exam.py        # 考试 HTML 解析/转换
│   │   └── service.py     # 组合入口（新/旧两条）
│   ├── young/
│   │   ├── schedule.py    # 二课课表采集（日期窗口 UI 驱动）
│   │   ├── source_bundle.py # build_young_schedule_source_bundle (ustc_young_my_schedule)
│   │   └── enrolment.py   # 二课报名列表采集 + QueryResult 归一化
│   ├── icourse/
│   │   ├── client.py      # PublicIcourseClient + JsonPageCache（24h TTL）
│   │   ├── parser.py      # 搜索/课程/教师页解析
│   │   ├── service.py     # 排名/证据选择/关系强度
│   │   ├── jw_input.py    # 从本地 bundle 读取课程组（仅 CLI --jw-bundle）
│   │   └── query.py       # query_course_public → QueryResult 1.0
│   └── campus/
│       ├── service.py     # refresh_catalogs / search_catalog / read_detail / read_attachment
│       ├── catalog.py     # CatalogStore（tmp/campus-catalog.json 持久化）
│       ├── detail.py      # 受限 HTTP 客户端 + 详情缓存 + DetailReader
│       ├── teach.py       # teach.ustc.edu.cn 目录/详情解析
│       └── finance.py     # finance.ustc.edu.cn 目录/详情解析
├── contracts/
│   ├── source_bundle.py          # SCHEMA_VERSION、envelope 构造、digest
│   ├── source_bundle_validation.py # 结构/敏感键/尺寸/JSON Schema/引用/scope 校验
│   └── schema_export.py          # canonical → Draft-7 兼容导出
└── bridge/
    ├── server.py        # BridgeServer（127.0.0.1、Bearer token、生命周期）
    ├── jobs.py          # CollectionJob / JobManager（采集作业状态机）
    ├── query_jobs.py    # ReadQueryJob / ReadQueryJobManager（查询作业状态机）
    ├── query_contracts.py # QueryResult 1.0 envelope + validate_query_result
    ├── protocol.py      # PROTOCOL_VERSION/QUERY_PROTOCOL_VERSION/握手/请求解析
    └── __main__.py      # python -m ustc_assistant.bridge 进程入口

app/lib/features/sync/
├── application/sync_coordinator.dart # 编排（触发/新鲜度/退避/busy/状态落库）
├── data/bridge_client.dart           # BridgeClient + BridgeGateway/BridgeQueryGateway
├── data/python_locator.dart          # PythonLocator + 开发/生产启动选项解析
├── domain/sync_state.dart            # SyncSource/SyncTrigger/SyncPhase/SyncOutcome
└── presentation/sync_page.dart       # 首次登录/重登录/同步页 + 启动自动同步

app/lib/core/config/generated_source_defaults.dart # 默认学期常量（生成文件）
```

**关键组件职责与证据**（均为已验证路径）：

| 组件 | 一句话职责 | 关键证据 |
|---|---|---|
| `sources/jw/collector.py::collect_sources` | 用 Edge 持久化 profile 打开教务页，抓 course-datum JSON 与考试页 HTML | `collector.py:228-267`；`collector.py:31-42` 定义目标端点 |
| `sources/jw/source_bundle.py::build_jw_source_bundle` | 把课表/考试原始数据归一化为 SourceBundle 1.0（`source=ustc_jw`）并现场校验 | `source_bundle.py:395-453`；`source_bundle.py:18` SOURCE |
| `sources/jw/service.py` | 组合入口：`collect_jw_source_bundle`（新，供 Bridge/CLI）与 legacy 三条（`merge_packages`/`build_legacy_import_package`/`build_bundle` 已废弃告警） | `service.py:145-168`；`service.py:108-125` DeprecationWarning |
| `sources/young/schedule.py::collect_schedules` | 通过二课日历 UI 逐日点击采集已报名课表，日期窗口 = 今天-7 天 ～ 下月末 | `schedule.py:394-428`；`schedule.py:96-97` query_window |
| `sources/young/source_bundle.py::build_young_schedule_source_bundle` | 二课课表 → SourceBundle 1.0（`ustc_young_my_schedule`），scope 为完整日期窗口 | `source_bundle.py:141-186`；`source_bundle.py:35-75` |
| `sources/young/enrolment.py` | 二课报名列表采集 + 归一化，产出**非 bundle** 的 QueryResult（`ustc_young_enrolment_list`） | `enrolment.py:290-318`；`enrolment.py:384-401,404-422` |
| `sources/icourse/query.py::query_course_public` | 公共课程查询（搜索→排名→证据→关系强度），包 QueryResult 1.0 envelope；永不接受 JW bundle 或用户身份 | `query.py:65-124`；`query.py:49-51` |
| `sources/icourse/service.py` | 排名（贝叶斯基准分 7.8/8.7）、证据选择（最新/高赞/冲突）、教师关系强度 | `service.py:104-127`；`service.py:153-171`；`service.py:47-54` |
| `sources/campus/service.py` | 校园公开信息编排：5 个来源定义的目录刷新、目录搜索、详情/附件读取 | `service.py:37-73` SOURCE_DEFINITIONS；`service.py:134-202`；`service.py:205-222`；`service.py:240-281` |
| `sources/campus/catalog.py::CatalogStore` | 目录 JSON 原子落盘（临时文件+os.replace）、来源级提交、搜索、freshness 时间戳 | `catalog.py:198-243`；`catalog.py:253-293` |
| `contracts/source_bundle.py` | SourceBundle 1.0 envelope 构造（manifest 计数）+ SHA-256 规范摘要 | `source_bundle.py:8`；`source_bundle.py:18-52` |
| `contracts/source_bundle_validation.py::validate_source_bundle` | 全量校验：尺寸 16MB/嵌套 64/敏感键/JSON Schema/身份唯一/计数一致/时间/引用/scope | `source_bundle_validation.py:85-137` |
| `contracts/schema_export.py` | 把 canonical draft-2020-12 schema 重写为 draft-07（供 Flutter 加载） | `schema_export.py:68-79,155-177` |
| `bridge/server.py::BridgeServer` | 仅 127.0.0.1 的 HTTP 服务：Bearer token、握手、路由、错误码映射、空闲/父进程退出 | `server.py:295-296`；`server.py:319-325`；`server.py:349-479`；`server.py:92-102,626-641` |
| `bridge/jobs.py::CollectionJob/JobManager` | 采集作业状态机（starting→checking→collecting→normalizing→complete 或暂停/终止），单活跃作业互斥 | `jobs.py:53-204`；`jobs.py:207-293`；`jobs.py:225-227` BridgeBusy |
| `bridge/query_jobs.py::ReadQueryJob(Manager)` | 只读查询作业状态机（独立单活跃门、独立于采集），4 类查询 runner + campus 目录自动刷新 | `query_jobs.py:211-404`；`query_jobs.py:535-799`；`query_jobs.py:444-493` |
| `bridge/query_contracts.py` | QueryResult 1.0 envelope（schemaVersion/queryType/generatedAt/data/metadata/references）+ 严格校验器 | `query_contracts.py:242-291`；`query_contracts.py:294-373` |
| `bridge/protocol.py` | 协议版本常量、握手 token、请求体大小/版本校验 | `protocol.py:10-12`；`protocol.py:21-27`；`protocol.py:30-43` |
| `sync/application/sync_coordinator.dart::SyncCoordinator` | 同步编排：触发判定、busy 互斥、作业轮询消费、结果导入、失败退避、状态落库 | `sync_coordinator.dart:62-137`；`sync_coordinator.dart:290-363`；`sync_coordinator.dart:365-401` |
| `sync/data/bridge_client.dart::BridgeClient` | 拉起 Python 子进程、握手、HTTP 调用、协议错误白名单映射 | `bridge_client.dart:193-244`；`bridge_client.dart:11-20` |
| `sync/data/python_locator.dart::PythonLocator` | 定位 Python（保存路径→CONDA_PREFIX→conda run 探测），构造开发/生产启动环境 | `python_locator.dart:65-105`；`python_locator.dart:122-182` |
| `sync/domain/sync_state.dart` | SyncSource（jw/youngSchedule）与同步结果领域模型 | `sync_state.dart:1-8`；`sync_state.dart:42-81` |
| `sync/presentation/sync_page.dart` | 首次登录、重新登录、同步全部/单个、文件导入入口；启动自动同步 | `sync_page.dart:19-69`；`sync_page.dart:321-384` |

## 3. 现状·关键数据流

### 3.1 教务采集作业（jw 链路，经 Bridge）

```
Flutter sync_page / runStartupAutomaticSync
  → SyncCoordinator.sync()                 sync_coordinator.dart:73-137
  → bridgeFactory() → PythonLocator.locate() → BridgeClient.start()   bridge_client.dart:193-244
       └ 子进程: python -m ustc_assistant.bridge --parent-pid N        bridge/__main__.py:10-23
          └ 握手行 JSON {protocolVersion, port, token, pid} → stdout
  → GET /capabilities → jwSemester（来自 config/source-defaults.json，config.py:51-72）
  → POST /collect/jw {accountId, expectedUsername, semester}          server.py:355-391
  → JobManager.start_jw → CollectionJob（daemon 线程）                  jobs.py:242-248
       └ jw_service.collect_jw_source_bundle                          service.py:145-168
          └ collect_sources → Edge 持久化 profile → course-datum + exam HTML   collector.py:228-267
          └ build_jw_source_bundle → make_bundle_envelope → validate_source_bundle  source_bundle.py:395-453
  → GET /jobs/{id}/events?after=N&waitMs=15000  长轮询事件            server.py:175-193, jobs.py:183-204
  → 终端事件 → result=bundle → SyncCoordinator._consume
  → importBundle(Uint8List(bundle), origin: bridge) → ImportService（import 模块）
  → _recordSuccess（sourceConfigs.lastSuccessAt + syncRuns success + actionLogs） sync_coordinator.dart:475-498
```

### 3.2 同步编排（SyncCoordinator 全流程）

```
sync(source, trigger)                          sync_coordinator.dart:73-137
  ├─ _busy → SyncSkipped('busy')               :79
  ├─ 无账号 → SyncSkipped('no_account')        :80-85
  ├─ automatic 且未到期 → SyncSkipped('fresh_or_backoff')  :86-89（isAutomaticDue :62-71）
  ├─ 无凭据 → SyncFailed('reauthentication_required')       :90-99
  ├─ bridge.capabilities() → 持久化 semester 配置            :102-105, :500-516
  ├─ bridge.startCollection(...) → _consume 轮询循环          :107-120, :290-363
  │     ├─ phase == needs_user_login → _paused[jobId] 挂起，返回 SyncNeedsUserAction :304-319
  │     ├─ terminal + result → importBundle → SyncSucceeded   :321-347
  │     ├─ code == 'cancelled' → SyncCancelled                :350-356
  │     └─ 其他 → recordFailure（retryAfter = now+1h）        :357-361, :365-388
  └─ 异常映射: AccountVerificationError/BridgeProtocolError/Object → SyncFailed  :121-133
```

三条同步入口共享 `_consume`：常规 `sync`（:73）、`firstLoginSync`（:159-203，暂存登录账号）+ `reauthenticate`（:205-255，暂存重登录）；`syncAll`（:139-157）按 `SyncSource.values` 顺序逐个执行，遇到 `SyncNeedsUserAction` 时由 `resolveUserAction` 回调决定立即恢复或取消（`sync_page.dart:273-286` 手动模式弹确认框、自动模式直接拒绝）。

### 3.3 Agent 查询作业（Query Protocol 1.0）

```
Agent 工具（模块 06）→ WindowsPythonQueryGateway.execute     app/lib/features/agent/data/windows_python_query_gateway.dart:87-204
  → POST /queries {protocolVersion, queryProtocolVersion, query{type,...}}  :94, :231-275
  → BridgeServer._start_query_job 按类型解析参数               server.py:500-618
  → ReadQueryJobManager.start_young_enrolment/icourse/campus_search/campus_detail
       （各自单活跃作业门，BridgeQueryBusy 409）               query_jobs.py:615-644
  → runner:
       young_enrolment → collect_enrolment_snapshot → build_young_query_result  query_jobs.py:408-425, enrolment.py:428-436
       icourse        → query_course_public（无凭据）          query_jobs.py:428-441, query.py:65-124
       campus_search  → _ensure_catalog_fresh（30min 节流/6h 过期/失败降级）→ search_catalog → _wrap_campus_search  query_jobs.py:444-516
       campus_detail  → read_detail(allow_stale=True) → _wrap_campus_detail  query_jobs.py:519-532
  → validate_query_result（每次出站必检）                     query_jobs.py:296, query_contracts.py:242-291
  → GET /query-jobs/{id}/events?after=N&waitMs=2000 轮询        server.py:194-216
  → SourceQueryCompleted(result: QueryResultEnvelope)           windows_python_query_gateway.py:161-173
```

### 3.4 校园目录刷新（campus 链路内部）

```
campus_search 查询时 → _ensure_catalog_fresh                    query_jobs.py:444-493
  ├─ 距上次尝试 < 30min（REFRESH_MIN_INTERVAL，query_jobs.py:76）→ 跳过刷新直接搜索
  ├─ catalog 缺失 或 最新来源 lastSuccessfulAt 距今 > 6h（CATALOG_STALE_AFTER，:77）→ 需刷新
  ├─ refresh_catalogs(catalog_path, force=False)                service.py:134-202
  │     ├─ monthly cadence 且未到期 → skipped                    :156-172
  │     └─ 逐来源 _collect_source（分页、notice 截止日期过滤、去重）→ CatalogStore.commit_source 原子落盘  :85-131, catalog.py:198-243
  ├─ 刷新抛异常且 catalog 存在 → 吞掉，降级用旧数据               query_jobs.py:487-492
  └─ 刷新抛异常且 catalog 不存在 → CampusUnavailable → 作业 failed(catalog_unavailable)  query_jobs.py:330-339, 85-90
```

## 4. 现状·接口契约

### 4.1 对外契约（本模块消费方）

**A. Bridge Protocol 1.0（HTTP，127.0.0.1:ephemeral，Bearer token）**

握手：`python -m ustc_assistant.bridge --parent-pid N` 启动后 stdout 首行打印 `{protocolVersion:"1.0", port, token, pid}`（`bridge/__main__.py:15-17`；`protocol.py:21-27`）。所有请求体必须含 `protocolVersion:"1.0"`，且 ≤ 64KB（`protocol.py:10-13,30-43`）。

端点（`server.py`）：
- GET `/health`（:146-151）、`/capabilities`（:152-173，含 `jwSemester` 默认三元组与 `queryTypes` 列表）
- GET `/jobs/{jobId}/events?after=N&waitMs=ms`（:175-193）、`/query-jobs/{jobId}/events`（:194-216）——长轮询事件
- POST `/shutdown`（:352-354）、`/collect/jw`（:355-391）、`/collect/young-schedule`（:392-412）、`/login/resume`（:413-431）、`/jobs/{id}/cancel`（:433-436）、`/queries`（:437-439）、`/query-jobs/{id}/resume-login`（:440-470）、`/query-jobs/{id}/cancel`（:471-478）

事件轮询响应形态（`jobs.py:183-204`、`query_jobs.py:384-405`）：`{events:[{sequence, phase, safeCount?}], nextSequence, terminal, result?, error?:{code, message}}`；`result` 仅在 `phase == complete` 时出现，`error` 仅在终止且失败/取消时出现。

Flutter 消费方：`BridgeGateway`（`bridge_client.dart:85-102`）由 `SyncCoordinator` 使用；`BridgeQueryGateway`（`bridge_client.dart:107-118`）由 `windows_python_query_gateway.dart:277-282` 使用。

**B. Query Protocol 1.0（POST /queries）**

请求体（`server.py:500-618`；Flutter 侧构造见 `windows_python_query_gateway.dart:231-275`）：
- 公共顶层：`protocolVersion`、`queryProtocolVersion:"1.0"`（`protocol.py:11`）、`query:{type, ...}`
- `young_enrolment`：另需 `accountId`、`expectedUsername`（唯一携带账号身份的查询类型，`server.py:516-534`）
- `icourse`：`course`、可选 `teachers`/`preferences`（`server.py:535-564`）
- `campus_search`：`query`、可选 `filters`/`limit`(1-100)（`server.py:565-595`）
- `campus_detail`：`entryId`、可选 `followLinkIds`（`server.py:596-617`）
- 硬性守卫：任何层级出现 URL/文件系统字段名（`_FORBIDDEN_URL_FILESYSTEM_FIELDS`，`query_jobs.py:97-116`）即拒绝（`server.py:481-498`）

**C. BundleImport（Dart 侧回调）**：`Future<ImportResult> Function(Uint8List bytes, {required String accountId, required ImportOrigin origin})`（`sync_coordinator.dart:11-16`）；实参为 `ImportService.importBytes`（`sync_page.dart:56`），`ImportOrigin.bridge`（`import_result.dart:1`）。

### 4.2 本模块消费的外部契约（全局契约锚点）

**SourceBundle 1.0**（导入/存储层契约，`schemas/source-bundle-1.0.schema.json` 为 canonical，draft 2020-12）：
- envelope：`schemaVersion(1.0)/bundleId(uuid)/source/subject/collectedAt(北京时)/producer?/snapshot/manifest/data`（`contracts/source_bundle.py:18-52`；schema required 列表见 `schemas/source-bundle-1.0.schema.json`）
- `source` enum 仅两项：`ustc_jw`、`ustc_young_my_schedule`
- `manifest`：sourceRecordCount/calendarEventCount/courseSeriesCount/scheduleRelationCount（`source_bundle.py:41-48`）
- 构造：`make_bundle_envelope`（`source_bundle.py:18-52`）；摘要：`canonical_bundle_digest`（`source_bundle.py:11-15`）
- 校验：`validate_source_bundle`（`source_bundle_validation.py:85-137`）——16MB 上限（:13）、嵌套深度 64（:14）、敏感键片段（:33-45）、Draft202012Validator+FormatChecker（:78-82）、身份唯一（:209-220）、manifest 计数一致（:223-233）、时间约束（+08:00，:236-243；:253-264）、引用完整性（:267-341）、scope 校验（jw 学期组件计数 :344-376；young 日期窗口 :378-397）
- 主体校验：`validate_source_bundle_subject`（`source_bundle_validation.py:140-148`）
- Draft-7 兼容导出：`contracts/schema_export.py`（Flutter 侧加载 `assets/schemas/source-bundle-1.0.draft7.schema.json`，见 `sync_page.dart:31-33`）

**Query Result 1.0**（Agent 消费侧契约，实现归本模块）：
- envelope：`schemaVersion(1.0)/queryType/generatedAt(北京时 ISO-8601 +08:00)/data/metadata/references`（`query_contracts.py:32,49-51,294-309`）
- queryType 四项：`young_enrolment`/`icourse`/`campus_search`/`campus_detail`（`query_contracts.py:35-42`）
- 约束：单字符串 ≤ 8000 字符（:46）、敏感键拒绝（:55-68）、young_enrolment 私有字段拒绝（:72-83）、references 必须为可信主机 https URL（:88-96,270-275）、data/metadata 中 URL 必须属于 references（:286-291）、拒绝 raw HTML（:149-162）
- 构造器：`build_{young_enrolment,icourse,campus_search,campus_detail}_envelope`（`query_contracts.py:312-373`）
- 校验：`validate_query_result`（`query_contracts.py:242-291`），作业在出站前必调（`query_jobs.py:296`），违反则作业以 `result_validation_failed` 终止（`query_jobs.py:318-323`）

## 5. 现状·错误处理

**HTTP 层错误码**（`server.py:245-262` + `_authenticated` :133-140）：

| 条件 | 状态码 | 错误码 |
|---|---|---|
| token 不匹配 | 401 | `unauthorized` |
| 请求体 > 64KB | 413 | `too_large` |
| 版本不匹配 | 409 | `unsupported_version` |
| JSON 无效/非对象 | 400 | `invalid_json` |
| 采集作业被占（profile 互斥） | 409 | `bridge_busy` |
| 查询作业被占 | 409 | `bridge_query_busy` |
| 作业不存在（含 jobs/query-jobs） | 404 | `job_not_found` / `query_job_not_found` |
| 非法作业状态/账号不匹配 | 409 | `invalid_job_state` |
| 参数校验失败（KeyError/TypeError/ValueError） | 400 | `invalid_request` |
| 未知路径 | 404 | `not_found` |

**作业内部错误码**：`cancelled` / `account_mismatch`（已登录账号与预期不符，`jobs.py:146-151`）/ `collection_failed`（`jobs.py:152-155`）/ `result_validation_failed`（`query_jobs.py:318-323`）/ `query_failed`（`query_jobs.py:340-341`）/ `catalog_unavailable`（`query_jobs.py:330-339`）。错误消息固定文案、不回显源内容（防注入回显，`jobs.py:159-164`）。

**Dart 侧错误归一**：`BridgeProtocolError` 白名单（`bridge_client.dart:11-20`，未知码一律映射 `request_failed`）；`SyncCoordinator` 将 `credentials_not_found→reauthentication_required`、`busy→bridge_busy`，其余收口为 `sync_failed`（`sync_coordinator.dart:121-133`）。同步结果错误码全集（代码观察）：`busy`/`no_account`/`fresh_or_backoff`（skip）、`reauthentication_required`/`bridge_busy`/`sync_failed`/`first_login_failed`/`reauthentication_failed`/`job_not_found`/`cancelled`/`collection_failed` 及 Bridge 透传码。

**重试策略**：
- 同步级：`retryBackoff = 1h`（`sync_coordinator.dart:57`），失败后写 `sourceConfigs.retryAfter`（:365-388），`isAutomaticDue` 在 retryAfter 前拒绝自动同步（:66-68）；手动同步绕过退避（测试 `app/test/features/sync/sync_coordinator_test.dart:123`）。
- 作业级（Python）：一次执行、无自动重试；`CollectionJob._run` 任一异常即终止（`jobs.py:123-157`）。
- campus 目录：30 分钟刷新节流 + 失败降级旧目录（`query_jobs.py:76-77,444-493`）。
- icourse：24h 磁盘缓存 TTL，网络失败时降级为 stale 缓存（`icourse/client.py:41-116`，尤其 :97-116）。

**事务/回滚边界**：SourceBundle 在作业内构造完成后先校验再置 `result`（`jobs.py:133-140`），非法 bundle 不会到达导入端；导入失败（importBundle 抛错）会落入 `_consume` 的异常路径 → `recordFailure` 并记录运行失败（`sync_coordinator.dart:321-363`）；`recordFailure`/`_recordSuccess` 均在 `database.transaction` 内（:372-387, :481-497）。首次登录/重登录失败时 `accounts.cancelFirstLogin(provisional)` 回滚暂存账号（:197-202, :242-254, :351-361）。

**恢复路径**：登录暂停（`needs_user_login`）→ 用户确认 → `resumeInteractive` 用暂存密码 `POST /login/resume` 继续同一作业（`sync_coordinator.dart:257-288`；`jobs.py:271-283`）；重启恢复见第 6 节。

## 6. 现状·观测点

**状态持久化（落库）**：
- `syncRuns` 表（`app/lib/core/database/tables/source_tables.dart:85-106`）：每次同步 `_startRun` 写入 `running`（`sync_coordinator.dart:439-458`），终态 `success/failed/cancelled/interrupted/needs_user_action` 由 `_finishRun`/`_setRunState` 写入（:460-473, :316, :496）。
- `sourceConfigs` 表（`source_tables.dart:5-26`）：`lastSuccessAt`/`retryAfter`/`configJson`（含 jw semester 三元组）/`enabled`（:475-544）。
- `actionLogs`：每次成功/失败追加 `source_sync` 审计（`sync_coordinator.dart:554-567`）。
- `import_batches` 由 import 模块落库（本模块仅透传 bundle 字节）。

**Bridge 侧无持久化**：作业全部在进程内存（`jobs.py:207-293`），进程退出即丢失；Bridge 无日志（`server.py:116-117` log_message 静默），作业事件仅通过长轮询暴露。

**可恢复性（重启后）**：`runStartupAutomaticSync` 与 `SyncPageLoader` 初始化时调用 `recoverInterruptedRuns`，把残留 `running` 运行标记为 `interrupted/app_restarted`（`sync_coordinator.dart:390-401`；`sync_page.dart:58,134`）；随后按新鲜度窗口触发自动同步（`sync_page.dart:243`；`app.dart:62`）。

**取消与停止语义**：作业取消通过 `cancel_check`（`self._cancelled.is_set`，`jobs.py:112`）在采集循环内协作式检查（`auth.py:73-77` raise_if_cancelled）；暂停态（needs_user_login）下取消立即终态化（`jobs.py:166-173`）；Bridge 进程停止：`POST /shutdown`（`server.py:268-269,643-649`），空闲 600s（`server.py:50,102`）或父进程死亡（`server.py:92-102`；Windows 探测 `server.py:63-89`）自动退出；Flutter 侧 `dispose`/`finally` 中 `bridge.shutdown()`（`sync_page.dart:67,139-142`）。

## 7. 端到端链路参与

- **completeReset** → 本模块不直接参与：`settings_service.completeReset` 清空本地库并调用 `accounts.clearDedicatedBrowserSession`（`settings_service.dart:170-190`；`account_service.dart:407`），Bridge 进程由同步页销毁时 shutdown。上游：设置/账号模块；下游影响：本模块的 `sourceConfigs`/`syncRuns` 随账号级联删除，下次同步按全新状态执行。
- **同步链路** → 本模块核心（第 3.1/3.2 节）；下游 import 模块（`ImportService.importBytes` + `SourceBundleDecoder` + Draft-7 schema 校验）。
- **Agent 查询链路** → 本模块提供执行通道（`/queries` + ReadQueryJobManager + QueryResult 1.0 校验，第 3.3 节）；消费侧接口（`WindowsPythonQueryGateway`、`QuerySourceGateway`、`SourceQuery` 领域类型、轮询/暂停语义）归模块 06 文档。

## 8. 原生目标态对照

> 本节全部内容标注【目标态推断】。不引用任何既有 flutter-native 设计文档，只描述方向与开放决策。

1. **职责保留/消失/合并**【目标态推断】：在"全部数据链路 Flutter 原生化、Bridge 消失"的最终形态中，本模块的职责**大体保留但载体迁移**——五条链路的数据获取逻辑由 Python（Playwright Edge）迁移为 Flutter 侧实现（Windows WebView / 原生 HTTP），Bridge HTTP 通道（server/jobs/query_jobs 的执行封装）随进程间通信一起**消失**；同步编排（SyncCoordinator：触发、新鲜度、退避、busy 互斥、状态落库）**保留**并成为纯 Dart 的执行协调层，采集函数调用从 HTTP 变为进程内/插件调用。CLI 面（`cli.py`）可能随 Python 侧一起退出或被替换为调试工具，待决策。

2. **被保留的契约**【目标态推断】：**SourceBundle 1.0 必然保留**——它是导入/存储层的全局锚点（`schemas/source-bundle-1.0.schema.json` + `contracts/source_bundle_validation.py` 的语义），导入/存储层不随采集实现重写，故 bundle 的 envelope、manifest、snapshot/scope、subject 校验语义、Draft-7 兼容导出面都应原样保留（或仅在 Dart 侧重写等价校验器，语义不变）。**Query Result 1.0 的 envelope 形态大概率保留**（Agent 侧领域模型 `QueryResultEnvelope` 不依赖传输层）。作业事件协议（sequence/phase/safeCount 长轮询形状）随 Bridge 消失，但"可恢复的、带安全计数的进度事件"语义会在本地实现中延续，待决策。

3. **开放决策**【目标态推断，标注待决策】：
   - 每链路的适配器形态（WebView 驱动式 vs 原生 HTTP 式）——jw/young 依赖登录态与页面交互，icourse/campus 是公开 HTTP；是否统一适配器接口，**待决策**。
   - 登录交互（CAS 可见窗口、`needs_user_login` 暂停/恢复语义）如何在纯 Dart 端原生化，**待决策**。
   - campus 目录（CatalogStore 的 JSON 落盘、30min 节流、6h 过期、降级策略）迁移后的存储归属（保留文件格式 or 并入 SQLite），**待决策**。
   - 采集/查询互斥模型（当前 Python 侧"采集单活跃 + 查询单活跃、两者可并存"）在 Flutter 侧如何表达，**待决策**。
   - 新鲜度窗口（12h）/退避（1h）策略参数是否随迁移调整，**待决策**。

## 9. 开源参考与优化建议

**参考 1：Airbyte 连接器架构（CDK checkpointing / stream slices / state）**
- 来源：[Airbyte Docs – Incremental Sync](https://docs.airbyte.com/platform/connector-development/config-based/understanding-the-yaml-file/incremental-syncs)、[Airbyte Docs – Stream Slices](https://docs.airbyte.com/platform/connector-development/cdk-python/stream-slices)、[Airbyte Docs – Workloads & Jobs](https://docs.airbyte.com/platform/understanding-airbyte/jobs)、[Dev.to – Cursor Checkpointing for Resilient Incremental Sync](https://dev.to/mukesh_13/building-airbyte-connectors-that-survive-flaky-apis-cursor-checkpointing-for-resilient-incremental-h52)
- 可借鉴模式：按 slice 输出 state message 实现细粒度断点续传；cursor 字段硬排序要求避免静默丢数据；`Retry-After` 读取与 transient/fatal 错误分类；平台层保存 connector state、attempt 与部分成功恢复。
- 对本模块的可落地建议：
  1. 现 young-schedule 的 `CollectedSchedules`（queried_dates/empty_dates/date_checks，`schedule.py:61-82`）已具备"逐日 slice + 计数校验"雏形，可对齐 Airbyte 的 slice 级 checkpoint：把"已查询到哪一天"作为作业级可持久化游标，重启后从游标续传而非整窗重扫（当前重启后整窗重采，见第 6 节无持久化）。
  2. 错误分类明确化：当前作业错误码只有 `collection_failed`/`query_failed` 二选一（`jobs.py:152-155`），建议区分 transient（可退避重试）与 fatal（需要用户动作），对齐 Airbyte 的 failure_type 语义，让 Dart 侧退避策略有据可依。
  3. campus 目录已实现"来源级 lastSuccessfulAt + 节流 + 降级"（`query_jobs.py:444-493`），建议补充 Airbyte 式的 state 消息概念：把每次刷新的来源级结果（updated/skipped/failed 计数，`service.py:193-202`）以结构化状态写入 catalog 文件，供 Agent 观测 freshness 而非仅靠阈值推断。

**参考 2：Scrapy 架构（Engine/Scheduler/Downloader/Spider/Item Pipeline + 中间件）**
- 来源：[Scrapy 官方架构文档](https://doc.scrapy.org/en/1.1/topics/architecture.html)、[Scrapy Scheduler 文档](https://docs.scrapy.org/en/2.12/topics/scheduler.html)、[Scrapy 架构概览（中文）](https://doc.yonyoucloud.com/doc/wiki/project/scrapy/scheduler.html)
- 可借鉴模式：引擎控制的数据流、请求/响应中间件链、Item Pipeline 的清洗-校验-持久化分层、JOBDIR 磁盘队列支持暂停/恢复爬取。
- 对本模块的可落地建议：
  1. 本模块已有隐式管道分层：采集（collector/schedule/enrolment）→ 归一化（normalize/build_*_bundle）→ 校验（validate_source_bundle/validate_query_result）→ 交付（events/import）。建议在 Flutter 原生化时显式化这条管道接口（每链路实现"fetch → normalize → validate"三步），对齐 Scrapy 的 spider/pipeline 分层，使五条链路共享校验与错误封装。
  2. Scrapy 的 dupefilter（去重过滤）可对应本模块 `_assert_unique`/`_check_unique_identities`（`source_bundle_validation.py:209-220`）与各采集器的 in-memory 去重（如 `enrolment.py:131-142`）；原生化时建议把去重责任收敛到统一校验层，避免各链路重复实现。
  3. Scrapy 的 JOBDIR（磁盘队列断点）对 campus/icourse 的磁盘缓存（`client.py:41-116`、`catalog.py:157-174` 的临时文件+原子替换）是现成参照：两处已采用"临时文件 + os.replace"原子写，迁移时应保留这一模式。

**参考 3：dbt 的 freshness / 增量物化 / 重试分层**
- 来源：[dbt Developer Hub – Near real-time data](https://docs.getdbt.com/best-practices/how-we-handle-real-time-data/1-intro?version=1.12)、[GitHub – dbt-core Microbatch Epic #10624](https://github.com/dbt-labs/dbt-core/issues/10624)、[dbt incremental models 实践（BigQuery）](https://raw.githubusercontent.com/OneUptime/blog/refs/heads/master/posts/2026-02-17-how-to-implement-incremental-models-in-dbt-for-efficient-bigquery-data-processing/README.md)
- 可借鉴模式：source freshness 的 warn/error 两级阈值声明式配置；增量物化的 lookback 窗口（回看几天捕捉迟到数据）；连接层/作业层/调度层分层重试。
- 对本模块的可落地建议：
  1. 现 freshness 为 Dart 常量 `freshness = Duration(hours: 12)`（`sync_coordinator.dart:56`）与 Python `CATALOG_STALE_AFTER = 6h`（`query_jobs.py:77`），建议仿 dbt 改为按来源声明的两级阈值（warn/error）并持久化到 `sourceConfigs.configJson`，让"上次成功时间"的过期判定可配置、可观测。
  2. young-schedule 全量重采 7 天+下月窗口（`schedule.py:96-97`），可借鉴 dbt 增量 lookback：只增量拉取"上次成功窗口之后"的日期并保留 lookback 数天，减少重复采集与站点压力。
  3. dbt 的分层重试（连接/作业/调度）可对应本模块现状——Dart 侧已有 1h 退避（`sync_coordinator.dart:57`），但 Python 作业内零重试（一次失败即终态，`jobs.py:152-155`）；建议在作业 runner 层为纯网络类失败（如 icourse 网络错误、campus 单源失败）增加有限次数重试，再交给 Dart 侧退避，避免一次网络抖动触发整轮失败。

## 10. 未验证/存疑事项

**已验证**：本模块全部 Python 文件（sources/*、contracts/*、bridge/*、common/auth.py、common/browser.py、config.py、cli.py、`schemas/source-bundle-1.0.schema.json` 头部与 required/enum 段）、全部 Flutter sync feature 文件、`generated_source_defaults.dart`、`source_tables.dart`（SourceConfigs/SyncRuns）、`import_result.dart`、`account_service.dart` 相关方法、`windows_python_query_gateway.dart`、`settings_service.dart:150-228`、`app.dart:62`、`router.dart:158,167,705-744`。

**未验证/存疑**：
1. 未运行任何测试/构建（静态阅读约束）；`app/test/features/sync/sync_coordinator_test.dart` 仅抽查用例名（:123-565），行为断言未逐条核对。
2. 未逐行阅读：`sources/jw/course.py:215-394`（convert_group 及 legacy 转换细节）、`sources/campus/detail.py:100-433`（CampusHttpClient/DetailCache/DetailReader 实现细节）、`sources/campus/teach.py:86-201` 与 `finance.py:98-219`（目录/详情解析细节）、`sources/icourse/client.py:119-232`（PublicIcourseClient 后半）与 `parser.py` 全文、`jw_input.py:67-177` 后半；这些仅凭 grep 行号与调用点确认存在，行为细节未核实。
3. `validate_source_bundle` 依赖 `jsonschema` Draft202012Validator 的 FormatChecker 具体行为（如 `format: uuid`、`format: date-time` 的校验强度）未实测，仅凭代码阅读（`source_bundle_validation.py:78-82`）。
4. 事件轮询 `result` 字段随 GET 响应返回，不受 `MAX_REQUEST_BYTES=64KB`（仅限 POST 请求体，`protocol.py:12`）限制——此为代码阅读推断，未实测大 bundle（可达 16MB，`source_bundle_validation.py:13`）经长轮询传输的实际表现。
5. 采集作业与查询作业"可并存"（`query_jobs.py:1-9` 模块 docstring）与 Bridge 空闲退出时点（`server.py:626-641` 轮询周期 0.25s）的并发时序未实测。
6. 真实站点行为（jw.ustc.edu.cn / young.ustc.edu.cn / icourse.club / teach/finance.ustc.edu.cn 的页面结构与反爬表现）未验证，全部依赖代码中固化选择器与端点常量（如 `collector.py:31-42`、`schedule.py:38-58`、`enrolment.py:38-52`）。
7. 会话开始时 git status 快照显示有 `feature/flutter-native-jw` 相关未提交改动（`app/lib/features/sync/jw/...`），实际检查 `git status --short` 工作区干净（仅有 `.statusline-test/`、`_merge-pending-docs/` 两个无关未跟踪目录）——快照与本机状态不一致，文档以实际 main 工作区为准；若存在"main + 未提交 JW webview 原型"的分支状态，本文档未覆盖其内容。
8. `docs/refactor-docs/` 目录在探索时不存在（无 00-index.md），本文档契约命名（SourceBundle 1.0 / Query Protocol 1.0 / Query Result 1.0）以 main 代码为准；若 00-index.md 采用不同命名，需要后续统一。
9. `app/lib/core/database/app_database.dart` 中 `actionLogsRepository.append` 的落库细节未细读（属其他模块范围）。
10. `accounts.stageLogin/stageReauthentication/confirmSuccessfulLogin` 的凭据存储细节（DPAPI 等）未细读（属账号模块范围），仅确认签名存在（`account_service.dart:84,91,114,146,347,357,363,382,387,407`）。
