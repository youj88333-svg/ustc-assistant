# 数据存储 技术文档

> 模块编号：03 ｜ 产出日期：2026-08-12 ｜ 覆盖分支：main ｜ 探索者：subagent-03

## 1. 职责边界

本模块是 Flutter Windows 客户端的本地事实来源（source of truth）：Drift/SQLite 数据库的全部表族与迁移、SourceBundle 导入流水线、以及日程（schedule）/任务（tasks）/提醒（reminders）/个人日历（calendar）/历史（history）各 feature 的 domain 与 application 层（不含 presentation 层）。

**做什么**：
- 以 Drift（`drift` + `drift_flutter`）管理单文件 SQLite 数据库 `ustc_assistant`（`app/lib/core/database/connection.dart:4`），共 27 张表，当前 `schemaVersion = 7`（`app/lib/core/database/app_database.dart:69`）。
- 接收采集端生成的 SourceBundle JSON，经解码、语义校验、幂等去重后单事务落库（`app/lib/features/import/`）。
- 在存储行之上派生"有效事件"（overlay 合并、软删除过滤、JW 调休投影、重复事件展开）与冲突判定（显式关系 > 系列规则 > 时间重叠）。
- 维护操作审计日志（action_logs）、撤销快照（undo_slot）、来源记录（source_records/sync_runs/import_batches）。

**不做什么**：
- 不采集数据：采集在 Python 数据层 + Bridge（同步模块），本模块只消费最终生成的 SourceBundle（`app/lib/features/sync/presentation/sync_page.dart:56,132` 将 `ImportService.importBytes` 作为回调交给 `SyncCoordinator`）。
- 不做 UI：各 feature 的 `presentation/` 目录不在本模块范围内。
- 不管理凭据加解密策略：`credential_accounts`/`agent_secrets` 的密文列由账号模块（accounts）与 agent 模块写入，本模块只提供存储表。

**依赖谁（上游）**：
- accounts 模块：写入 `local_accounts`（含 `identity_digest`，`app/lib/features/accounts/application/account_service.dart:206`）。
- settings 模块：通过 `source_configs` 表存储应用设置（`pythonPath`、`disabledReminderTypes`、JW 学期配置，`app/lib/features/settings/application/settings_service.dart:62-99,214-237`）。
- agent 模块：写入 `agent_settings`/`agent_secrets`/`agent_runs`/`chat_messages`/`tool_invocations`/`conversation_summaries`/`agent_permission_policies`，并消费本模块的撤销与审计能力。
- sync 模块：`SyncCoordinator` 驱动导入（上游产出 SourceBundle 字节流，下游即本模块）。

**被谁依赖（下游）**：
- 同步模块（模块 05？）：`ImportService.importBytes` 与 `sync_runs` 表状态读写（`sync_coordinator.dart:338,390-470`）。
- agent 模块：`DriftAgentLocalDataGateway`（`app/lib/features/agent/application/agent_local_data_gateway.dart:333`）聚合消费本模块几乎所有读服务：`EffectiveEventRepository`、`ConflictService`、`OverlayService`、`UndoService`、`ReminderOverrideService`、`HistoryRepository`、`RecurrenceService`、`RecurringEventProjector`（imports 见 `agent_local_data_gateway.dart:3-20`）。
- settings 模块：`clearBusinessData`/`completeReset` 直接删除本模块各表行（`settings_service.dart:118-190`）。
- 各 presentation 层：周课表、事件详情、冲突管理、任务中心、提醒设置等。

## 2. 现状·核心组件

### 2.1 目录树（本模块范围）

```
app/lib/core/database/
├── app_database.dart          # AppDatabase 聚合 27 表 + 迁移 + ActionLogRepository + replaceUndoSlot
├── app_database.g.dart        # Drift 生成代码（表名 snake_case，如 local_accounts）
├── connection.dart            # openAppDatabase() → driftDatabase(name: 'ustc_assistant')
└── tables/
    ├── account_tables.dart    # local_accounts, credential_accounts
    ├── source_tables.dart     # source_configs, import_batches, source_records, sync_runs
    ├── schedule_tables.dart   # course_series, calendar_event_series, calendar_events,
    │                          #   calendar_event_occurrence_exceptions, jw_day_moves, user_overlays
    ├── task_tables.dart       # tasks, plan_blocks, task_event_links, schedule_relations,
    │                          #   schedule_relation_rules, reminders, undo_slot
    ├── agent_tables.dart      # agent_settings, agent_secrets, agent_runs, chat_messages,
    │                          #   tool_invocations, conversation_summaries
    └── operation_tables.dart  # action_logs, agent_permission_policies

app/lib/features/import/
├── application/
│   ├── import_service.dart        # 导入流水线主入口：解码→幂等→单事务→提醒协调
│   └── reminder_reconciler.dart   # ReminderReconciler 接口 + Noop 实现
├── data/
│   ├── import_repository.dart     # import_batches / source_records 查询
│   ├── source_bundle_decoder.dart # JSON→SourceBundle（JSON Schema 校验 + 语义校验）
│   └── source_bundle_semantics.dart # 语义校验：唯一性/清单/时间/引用/范围
└── domain/
    ├── import_result.dart         # ImportOrigin / ImportStatus / ImportResult
    ├── source_bundle.dart         # SourceBundle 模型 + digest（sha256 canonical JSON）
    └── source_bundle_error.dart   # SourceBundleError + 9 个错误码（L2-07 修正：旧记"10 个"为计数笔误）

app/lib/features/schedule/
├── application/
│   ├── conflict_service.dart          # 冲突关系/系列规则增删改查 + 删除影响预览
│   ├── effective_event_repository.dart # 有效事件流、byId、有界冲突投影（核心读路径）
│   ├── jw_day_move_service.dart       # JW 调休（投影式，不改源事件）
│   ├── overlay_service.dart           # 用户覆盖层两层级（event / course_series）
│   └── schedule_conflict_projection.dart # 纯函数冲突投影（Dart，不落库）
└── domain/
    ├── course_color.dart        # FNV-1a 调色板
    ├── jw_day_move.dart         # JwDayMove 领域模型 + 3 个异常
    ├── overlap_engine.dart      # EffectiveEvent + 重叠分组 + 前景排序
    ├── schedule_grid_item.dart  # 事件/计划块统一网格项（非持久化）
    ├── schedule_projection.dart # buildWeek：周网格投影
    ├── ustc_periods.dart        # 中科大 13 节次时间表
    └── week_range.dart          # 周区间

app/lib/features/calendar/
├── application/
│   ├── calendar_event_service.dart    # 个人事件 CRUD + 生命周期 + 提醒替换
│   ├── recurrence_lifecycle_service.dart # 三作用域取消/删除/重开/恢复
│   ├── recurrence_service.dart        # 系列 CRUD / 拆分 / 异常锚点
│   └── recurring_event_projection.dart # 只读范围投影（display / management）
└── domain/
    ├── calendar_event_locator.dart    # event_v1/occ_v1/series_v1 可逆不透明标识
    ├── personal_event.dart            # PersonalEvent 领域模型 + 存储映射
    ├── recurrence_expander.dart       # 展开器（366 天 / 1000 次上限）
    └── recurrence_rule.dart           # daily/weekly/monthly 规则 v1 JSON

app/lib/features/tasks/
├── application/
│   ├── plan_block_lifecycle_port.dart # Task→PlanBlock 联动端口
│   ├── plan_block_service.dart        # 计划块 CRUD / 拆分 / 重排 / 审查
│   ├── task_event_link_service.dart   # 任务-事件链接解除
│   ├── task_lifecycle_service.dart    # 任务生命周期 + 计划块联动
│   ├── undo_recorder.dart             # UndoCommand / UndoRecorder 接口
│   └── undo_service.dart              # 撤销槽读写 + 全实体恢复器
└── domain/
    ├── plan_block.dart                # PlanBlockItem + 投影
    ├── task.dart                      # TaskItem + 状态枚举
    └── task_projection.dart           # 计划/截止/确认三态投影

app/lib/features/reminders/
├── application/
│   ├── reminder_override_service.dart # 显式偏移设置/清除/配置查询
│   ├── reminder_service.dart          # 全量/按源协调（含系列 31 天前瞻）
│   └── windows_reminder_reconciler.dart # 表监听→协调→定时器重建→投递
├── data/
│   └── foreground_notification_adapter.dart # Windows 前台通知适配
└── domain/
    └── reminder_rule.dart             # ReminderDefaults 默认偏移

app/lib/features/history/
└── application/history_repository.dart # action_logs 查询 + 脱敏（上限 50 条）
```

### 2.2 关键组件职责

| 组件 | 路径（已验证） | 一句话职责 |
|---|---|---|
| `AppDatabase` | `app/lib/core/database/app_database.dart:46-195` | 27 表聚合根；`schemaVersion=7`；v1→v7 迁移；`beforeOpen` 开外键（L191-193）；广播流 `activeAccountChanges`/`agentSettingsChanges`（L49-66） |
| `ActionLogRepository` | `app_database.dart:197-231` | action_logs 追加（uuid 主键）与倒序全量查询；所有业务服务经它写审计 |
| `ImportService.importBytes` | `app/lib/features/import/application/import_service.dart:27-71` | 导入入口：解码→`requireSubject`→bundleId/digest 幂等→单事务导入→提醒协调（失败降级为 `reminderReconciliationPending`） |
| `SourceBundleDecoder` | `app/lib/features/import/data/source_bundle_decoder.dart:10-72` | 16MB 上限、`schemaVersion=='1.0'` 门禁、JSON Schema 校验（`assets/schemas/source-bundle-1.0.draft7.schema.json`）、错误码映射 |
| `validateSourceBundleSemantics` | `app/lib/features/import/data/source_bundle_semantics.dart:11-29` | 完整性、唯一 externalId、manifest 计数、时间格式（+08:00）、引用一致性、scope 范围 |
| `EffectiveEventRepository` | `app/lib/features/schedule/application/effective_event_repository.dart:127-910` | 有效事件流（SQL + overlay 合并 + 调休投影 + 有界重复展开合并）；`conflictsForItems` 有界冲突投影（L583-603） |
| `ScheduleConflictProjection` | `app/lib/features/schedule/application/schedule_conflict_projection.dart:139-476` | 纯函数冲突解析：显式出现级 > 系列规则（按发生日生效）> 时间重叠派生 > 无冲突；派生对永不落库 |
| `ConflictService` | `app/lib/features/schedule/application/conflict_service.dart:108-1031` | 冲突关系/规则的持久化读写、删除影响预览（366 天）、TOCTOU 目标复验 |
| `OverlayService` | `app/lib/features/schedule/application/overlay_service.dart:113-592` | 两层覆盖（event / course_series）upsert 与原子清除；清除全部字段时物理删行 |
| `JwDayMoveService` | `app/lib/features/schedule/application/jw_day_move_service.dart:22-224` | 调休记录 CRUD；投影式——只写 `jw_day_moves`，从不改写源事件 |
| `RecurrenceService` | `app/lib/features/calendar/application/recurrence_service.dart:212-868` | 系列增改拆（`editThisAndFuture` 分裂）、occurrence 组合、`ensureOccurrenceAnchor`（可复用 no-op 异常锚点） |
| `RecurringLifecycleService` | `app/lib/features/calendar/application/recurrence_lifecycle_service.dart:131-1022` | only_this / this_and_future / whole_series 三作用域生命周期 + 影响预览（366 天/无限标记） |
| `RecurringEventProjector` | `app/lib/features/calendar/application/recurring_event_projection.dart:96-313` | 只读范围投影，从不物化 occurrence 到 `calendar_events`；跨系列 1000 次上限（L135-137） |
| `CalendarEventService` | `app/lib/features/calendar/application/calendar_event_service.dart:49-644` | 个人事件 CRUD/生命周期；提醒随事件替换（`_replaceReminders` L522-564）或取消（`_cancelReminders` L570-581） |
| `TaskLifecycleService` | `app/lib/features/tasks/application/task_lifecycle_service.dart:34-424` | 任务状态机；经 `PlanBlockLifecyclePort` 联动取消/完成未来计划块 |
| `PlanBlockService` | `app/lib/features/tasks/application/plan_block_service.dart:45-569` | 计划块 CRUD/拆分/重排/锁定/审查；`taskCancelled`/`taskCompleted` 批量取消未来块 |
| `UndoService` | `app/lib/features/tasks/application/undo_service.dart:13-816` | 单槽撤销：v1 JSON 信封 + 账号隔离 + 11 类实体恢复器（含复合恢复与递归生命周期逆向） |
| `ReminderService` | `app/lib/features/reminders/application/reminder_service.dart:9-330` | 提醒协调：按默认规则/现有偏移重算，过去触发记 `missed`；系列 31 天前瞻（L71-163） |
| `WindowsReminderReconciler` | `app/lib/features/reminders/application/windows_reminder_reconciler.dart:34-197` | 6 张表 watch 驱动重协调；定时器重建；投递成功/失败状态迁移 |
| `HistoryRepository` | `app/lib/features/history/application/history_repository.dart:45-110` | action_logs 账户内查询，DB 层 limit 50，正则脱敏 |
| `buildWeek` | `app/lib/features/schedule/domain/schedule_projection.dart:62-146` | 周网格投影：7:00 前入凌晨带，重叠分组 |

## 3. 现状·关键数据流

### 3.1 导入流水线（ImportService.importBytes）

起：`sync_page.dart:56,132`（`importBundle: importer.importBytes`，亦被 `file_import_action.dart:109` 以 `ImportOrigin.file` 调用）→ 终：数据库落库 + `ImportResult` 返回。

```
SyncCoordinator / FileImportAction
        │ bytes + accountId + origin(bridge|file)
        ▼
ImportService.importBytes (import_service.dart:27-71)
  1. decoder.decode(bytes)                    ← JSON Schema(1.0) + 语义校验；错误→SourceBundleError
  2. bundle.requireSubject(accountId)         ← subject_mismatch 门禁 (source_bundle.dart:34-38)
  3. batchByBundleId 幂等：已存在且 digest 相同 → replayed，直接返回 (L35-49)
        ├─ digest 不同 → duplicate_identity 抛错
  4. database.transaction(_importTransaction) ← 单事务 (L51-53)
        ├─ 写 import_batches 一行 (L80-93)
        ├─ 预分配 localIds：外部实体→本地 id（复用旧 id 保持稳定）(L95-104)
        ├─ upsert course_series / calendar_events / schedule_relations (L106-208)
        │    （calendar_events 状态取 sourceRecords 中 cancelled → cancelled，其余 active，L149-154）
        ├─ upsert source_records（presence='observed'）(L210-240)
        ├─ _markAbsentRecords：未观察记录标 outside_scope / missing_within_scope (L241-246,283-333)
        └─ 写 sync_runs(state='success', result_code='imported') + ActionLog('source_import') (L248-270)
  5. reminderReconciler.reconcile(accountId, source)  ← 事务外；失败→日志 reminder_reconcile:retryable_failure，
                                                        ImportResult.reminderReconciliationPending=true (L54-70)
```

要点：导入是"完整快照对齐"而非增量合并——`source_records` 的 presence 区分 `observed` / `outside_scope` / `missing_within_scope`；`missing_within_scope` 事件被有效事件流过滤掉（`effective_event_repository.dart:202-211` 的 SQL EXISTS 子句）。

### 3.2 有效事件派生链路（存储行 → 周网格/详情）

起：`calendar_events` + `user_overlays` + `course_series` + `jw_day_moves` + 重复系列 → 终：`EffectiveEvent` 流（周课表、冲突投影、Agent 工具共用）。

```
calendar_events e
  ──LEFT JOIN─ course_series cs（source+external_id 配对，course_series_id）
  ──LEFT JOIN─ user_overlays eo（event 层）
  ──LEFT JOIN─ user_overlays so（course_series 层）
  → SQL COALESCE 链：eo.* > so.* > e.*（display_title/location/importance/hidden/color/foreground_priority）
  → 过滤：deleted_at IS NULL、status NOT IN (cancelled,hidden,skipped)、
          source='user' 或存在 presence<>'missing_within_scope' 的 source_record
  （完整 SQL：effective_event_repository.dart:166-213）
  → 调休投影：ustc_jw/course 定时事件按 RAW 北京日期匹配 jw_day_moves 移到目标日（L504-529）
  →（有界调用时）合并 RecurringEventProjector.projectRange 的 occurrence（L239-253）
  → EffectiveEvent（overlap_engine.dart:5-64）
  → ScheduleGridItem（schedule_grid_item.dart:22-185）
  → buildWeek 周网格 / ScheduleConflictProjection.resolveCandidates 冲突（schedule_projection.dart:62-146）
```

冲突派生优先级（`schedule_conflict_projection.dart:355-400`）：显式 occurrence 关系（`schedule_relations`，按 `kind:id|kind:id` 规范键）→ 系列规则（`schedule_relation_rules`，按发生日命中的 `effectiveFrom/Through`）→ 定时重叠 → 无冲突。派生对只存在于投影结果，从不写库（L136-138 注释）。`resolvedConflictIdsFor`（全量投影）已标记 `@Deprecated`，周课表与 Agent 工具统一走 `conflictsForItems` 有界路径（L583-603）。

### 3.3 撤销链路（写操作 → undo_slot → 恢复）

起：各业务服务事务内 `undoRecorder.record(UndoCommand)` → 终：`undo_slot` 单行 + 用户触发 `UndoService.undo()` 逆向。

```
任务/计划块/事件/覆盖/冲突/调休/提醒/递归生命周期/复合操作
  └─ 各自事务内：业务写 + ActionLog + UndoCommand 快照（before 行 JSON 快照）
  → UndoService.record (undo_service.dart:26-40)：校验 accountId+version=1，
      信封 {version, kind, accountId, safeSummary, payload} → AppDatabase.replaceUndoSlot
      （undo_slot 恒为 1 行，insertOnConflictUpdate 覆盖，app_database.dart:82-94）
  → UndoService.undo (undo_service.dart:80-141)：
      - 槽不存在/他账号/结构非法 → InvalidUndoCommand（他账号槽绝不删除/改写，L104-109）
      - 事务内 _apply(payload)：按 entity 分派 11 类恢复器（L143-173），
        复合操作（'composite'）逐操作复用单实体恢复器（L181-216）
      - 成功→删槽 + ActionLog('undo_<kind>':success)；失败→保槽 + ActionLog('undo':failure)（L113-140）
  （注：`UndoService.clearAtStartup`（undo_service.dart:78）在 lib 生产代码中未见调用方，仅测试直接调用——见第 10 节存疑项 3）
```

### 3.4 提醒协调链路（领域变化 → reminders 表 → 定时器 → 通知）

起：6 张表（calendar_events/calendar_event_series/calendar_event_occurrence_exceptions/tasks/plan_blocks/reminders）变更 → 终：Windows 前台通知 + reminders 状态迁移。

```
WindowsReminderReconciler.start (windows_reminder_reconciler.dart:53-85)
  ├─ 订阅 6 张表的 drift watch 流；领域表变化 → _domainChanged（防抖：重入标记+再来一次，L99-113）
  │   reminders 表变化 → rebuild 只重建定时器
  ├─ reconcileAll → ReminderService.reconcileAll（reminder_service.dart:35-57）：
  │    事件按 ReminderDefaults.forEvent（exam:[1440,120]、course/personal:[15]…，reminder_rule.dart:4-18）
  │    显式禁用哨兵（state='cancelled' 且 offsetMinutes=null）抑制默认重建（L265-267）
  │    系列 31 天前瞻投影，锚定 occurrence-exception no-op 锚点（L71-163）
  └─ rebuild（windows_reminder_reconciler.dart:129-159）：
      过期 desired → missed；未来 desired → ProcessTimerScheduler 定时器
  → _deliver（L161-196）：投递成功 → delivered+deliveredAt；失败 → failed+failure_code='notification_unavailable'
```

## 4. 现状·接口契约

### 4.1 服务级入口（对外）

- `ImportService.importBytes(Uint8List, {accountId, ImportOrigin}) → Future<ImportResult>`（`import_service.dart:27`）。`ImportOrigin {bridge, file}`、`ImportStatus {imported, replayed}`（`import_result.dart:1-3`）。
- 读服务（多数经 `DriftAgentLocalDataGateway` 与 presentation 消费）：`EffectiveEventRepository.watchDisplayEvents/conflictsForItems/byId`、`ConflictService.stateForPair/relationSnapshot/classifyPair/deleteConflictRelation/…`、`OverlayService.setEventOverlay/clearOverlayFields/eventOverlayLayers`、`UndoService.preview/undo`、`ReminderOverrideService.setOffsets/clearReminders/configurationFor`、`HistoryRepository.query`、`RecurringEventProjector.projectRange/searchSeries`。
- 写服务：`CalendarEventService`（create/edit/complete/skip/cancel/hide/reopen/softDelete/restore/linkTaskToEvent）、`RecurrenceService`（createSeries/editOnlyThis/editThisAndFuture/editWholeSeries/ensureOccurrenceAnchor）、`RecurringLifecycleService`（cancel/delete/reopen/restore × 3 scope）、`TaskLifecycleService`、`PlanBlockService`、`JwDayMoveService`、`ReminderService.reconcileAll/reconcileSource`、`WindowsReminderReconciler.reconcile`（实现 `ReminderReconciler` 接口，`reminder_reconciler.dart:1-3`）。
- `ActionLogRepository.append/selectAll`（`app_database.dart:203-231`）。

### 4.2 实现级数据字典（全局契约锚点，27 张表）

列类型按 Drift 映射：`text()`→TEXT、`integer()`→INTEGER、`boolean()`→INTEGER(0/1)、`blob()`→BLOB。所有时间均为 epoch 毫秒 INTEGER（除标注为 `YYYY-MM-DD` 文本日期外）；所有主键为应用生成 UUID/文本。`account_id` 外键统一指向 `local_accounts(id)`。以下"级联"均指 `ON DELETE CASCADE`。

#### account_tables.dart

**1. `local_accounts`**（`account_tables.dart:3-16`）
| 字段 | 类型 | 约束 |
|---|---|---|
| id | TEXT | PK |
| masked_hint | TEXT | NOT NULL |
| identity_digest | TEXT | NULL（v2 起） |
| is_active | INTEGER | NOT NULL DEFAULT 0 |
| created_at / updated_at | INTEGER | NOT NULL |

**2. `credential_accounts`**（L18-34）
| 字段 | 类型 | 约束 |
|---|---|---|
| account_id | TEXT | PK，→ local_accounts CASCADE |
| username_ciphertext | BLOB | NOT NULL |
| password_ciphertext | BLOB | NULL |
| scheme | TEXT | NOT NULL |
| protection_version | INTEGER | NOT NULL DEFAULT 1 |
| protection_metadata | TEXT | NOT NULL DEFAULT '{}' |
| updated_at | INTEGER | NOT NULL |

#### source_tables.dart

**3. `source_configs`**（`source_tables.dart:5-26`）：id TEXT PK；account_id→CASCADE；source TEXT NOT NULL；enabled INTEGER NOT NULL DEFAULT 1；config_json TEXT NOT NULL DEFAULT '{}'；last_success_at / retry_after INTEGER NULL；updated_at INTEGER NOT NULL。**UNIQUE(account_id, source)**（L23-25）。

**4. `import_batches`**（数据类名 `ImportBatch`，L28-51）：id TEXT PK；account_id→CASCADE；bundle_id TEXT NOT NULL；digest TEXT NOT NULL；source TEXT NOT NULL；scope_key TEXT NOT NULL；imported_at INTEGER NOT NULL；origin TEXT NOT NULL。**UNIQUE(account_id, bundle_id)**、**UNIQUE(account_id, digest)**（L47-50）。

**5. `source_records`**（L53-83）：id TEXT PK；account_id→CASCADE；source / entity_type / external_id / local_entity_id / source_status / presence / scope_key TEXT NOT NULL；import_batch_id TEXT NULL → import_batches(id) **ON DELETE RESTRICT**；source_updated_at INTEGER NULL；first_observed_at / last_observed_at INTEGER NOT NULL。**UNIQUE(account_id, source, entity_type, external_id)**（L80-82）。

**6. `sync_runs`**（L85-106）：id TEXT PK；account_id→CASCADE；source / trigger / state TEXT NOT NULL；result_code TEXT NULL；started_at INTEGER NOT NULL；finished_at INTEGER NULL；import_batch_id TEXT NULL → import_batches(id) **ON DELETE SET NULL**。无其他索引；state 取值 `running`/`success`/`failed`/`interrupted`（`sync_coordinator.dart:385,396,453,462,469,495`）。

#### schedule_tables.dart

**7. `course_series`**（`schedule_tables.dart:5-29`）：id TEXT PK；account_id→CASCADE；source / external_id / title / semester_key TEXT NOT NULL；course_code TEXT NULL；participants_json TEXT NOT NULL DEFAULT '[]'；source_details_json TEXT NOT NULL；created_at / updated_at INTEGER NOT NULL。**UNIQUE(account_id, source, external_id)**（L26-28）。

**8. `calendar_event_series`**（L31-80）：id TEXT PK；account_id→CASCADE；title / event_type / timezone TEXT NOT NULL；description TEXT NULL；status TEXT NOT NULL DEFAULT 'active'；all_day INTEGER NOT NULL DEFAULT 0；start_at / duration_minutes INTEGER NULL；anchor_start_date TEXT NULL；duration_days INTEGER NULL；recurrence_json TEXT NOT NULL；effective_from / effective_through TEXT NULL（YYYY-MM-DD）；location_name TEXT NULL；importance TEXT NOT NULL DEFAULT 'normal'；color TEXT NULL；completion_policy TEXT NOT NULL DEFAULT 'auto_after_end'；tags_json TEXT NOT NULL DEFAULT '[]'；user_notes TEXT NULL；reminder_offsets_json TEXT NOT NULL DEFAULT '[]'（v7）；deleted_at / created_at / updated_at INTEGER（created_at/updated_at NOT NULL，deleted_at NULL）。**CHECK 约束**（L68-79）：timed 与 all-day 表示互斥（all_day=0 且 start_at NOT NULL 且 duration_minutes>0 且 anchor_start_date IS NULL 且 duration_days IS NULL，或 all_day=1 且相反）；status IN ('active','tentative','cancelled','completed','skipped','hidden')；effective_through IS NULL 或 effective_from IS NULL 或 effective_through >= effective_from。

**9. `calendar_events`**（L82-148）：id TEXT PK；account_id→CASCADE；source TEXT NOT NULL；external_id TEXT NULL；source_series_external_id TEXT NULL；personal_series_id TEXT NULL → calendar_event_series(id) CASCADE；occurrence_key TEXT NULL；title TEXT NOT NULL；description TEXT NULL；type TEXT NOT NULL；status TEXT NOT NULL DEFAULT 'active'；start_at / end_at INTEGER NULL；all_day INTEGER NOT NULL；start_date / end_date_exclusive TEXT NULL；timezone TEXT NOT NULL；location_name / building_name / campus_name TEXT NULL；participants_json TEXT NOT NULL DEFAULT '[]'；source_details_json TEXT NOT NULL DEFAULT '{}'；importance TEXT NOT NULL DEFAULT 'normal'；completion_policy TEXT NOT NULL DEFAULT 'auto_complete'；completed_at INTEGER NULL；color TEXT NULL；tags_json TEXT NOT NULL DEFAULT '[]'；created_at / updated_at INTEGER NOT NULL；deleted_at INTEGER NULL。**UNIQUE(account_id, source, external_id)**、**UNIQUE(account_id, personal_series_id, occurrence_key)**（L128-131）。**CHECK**（L134-147）：timed/all-day 互斥（同上模式，all-day 需 end_date_exclusive > start_date）；type IN ('course','exam','second_class','personal','entertainment','meal','campus_affair','travel','study','system')；status IN ('active','tentative','cancelled','completed','skipped','hidden')。

**10. `calendar_event_occurrence_exceptions`**（L150-189）：id TEXT PK；account_id→CASCADE；series_id TEXT NOT NULL → calendar_event_series(id) CASCADE；occurrence_key TEXT NOT NULL；original_start_at INTEGER NULL；original_start_date TEXT NULL；kind TEXT NOT NULL；overridden_fields_json TEXT NOT NULL DEFAULT '[]'；override_json TEXT NOT NULL；status TEXT NULL；orphaned INTEGER NOT NULL DEFAULT 0；deleted_at INTEGER NULL；created_at / updated_at INTEGER NOT NULL。**UNIQUE(account_id, series_id, occurrence_key)**（L179-181）。**CHECK**：kind IN ('override','cancelled')；original_start_at 与 original_start_date 恰好一个非空（XOR，L186-187）。

**11. `jw_day_moves`**（数据类名 `JwDayMoveRecord`，L200-225）：id TEXT PK；account_id→CASCADE；source_date / target_date TEXT NOT NULL（YYYY-MM-DD）；created_at / updated_at INTEGER NOT NULL。**UNIQUE(account_id, source_date)**（L217-219）；**CHECK (source_date <> target_date)**。

**12. `user_overlays`**（L227-275）：id TEXT PK；account_id→CASCADE；event_id TEXT NULL → calendar_events(id) CASCADE；course_series_id TEXT NULL → course_series(id) CASCADE；display_title / display_location / attendance_policy / attendance_decision / attendance_note / attendance_outcome / listening_mode / listening_note / importance / color / user_notes / tags_json TEXT 全部 NULL 可；attendance_decision_at / foreground_priority INTEGER NULL；hidden INTEGER NULL；created_at / updated_at INTEGER NOT NULL。**UNIQUE(account_id, event_id)**、**UNIQUE(account_id, course_series_id)**（L266-269）；**CHECK XOR(event_id, course_series_id)**（L272-274）。

#### task_tables.dart

**13. `tasks`**（`task_tables.dart:6-42`）：id TEXT PK；account_id→CASCADE；title TEXT NOT NULL；description / user_notes TEXT NULL；state TEXT NOT NULL；blocked_reason TEXT NULL；importance TEXT NOT NULL；deadline_at / estimated_minutes INTEGER NULL；tags_json TEXT NOT NULL；completed_at / cancelled_at / deleted_at INTEGER NULL；created_at / updated_at INTEGER NOT NULL。**CHECK**：state IN ('active','blocked','completed','cancelled')；terminal 状态与时间戳互斥（completed↔cancelled 恰好一个带时间戳，L34-39）；estimated_minutes NULL 或 >0。

**14. `plan_blocks`**（L44-80）：id TEXT PK；account_id→CASCADE；task_id TEXT NOT NULL → tasks(id) CASCADE；title TEXT NULL；start_at / end_at INTEGER NOT NULL；status TEXT NOT NULL；locked INTEGER NOT NULL DEFAULT 0；review_note TEXT NULL；reviewed_at INTEGER NULL；rescheduled_to_plan_block_id TEXT NULL；created_at / updated_at INTEGER NOT NULL；deleted_at INTEGER NULL。**CHECK**：end_at > start_at；status IN ('suggested','accepted','done','skipped','rescheduled','cancelled')；reviewed_at 与状态一致性（suggested/accepted 必须无 reviewed_at，其余必须有，L73-74）；rescheduled 必须带 rescheduled_to_plan_block_id 反之必须空（L75-78）。

**15. `task_event_links`**（L82-113）：**PK(account_id, task_id, target_id)**；task_id → tasks CASCADE；target_id TEXT NOT NULL（逻辑目标：事件 id 或 locator）；event_id TEXT NULL → calendar_events(id) CASCADE；occurrence_exception_id TEXT NULL → calendar_event_occurrence_exceptions(id) CASCADE（v7 起）；relation_type TEXT NOT NULL；created_at INTEGER NOT NULL。**CHECK XOR(event_id, occurrence_exception_id)**（L108-112）。v7 将 PK 从 (account_id, task_id, event_id) 改为 (account_id, task_id, target_id)，旧 event_id 值迁移为 target_id（`app_database.dart:165-173`）。

**16. `schedule_relations`**（L115-224）：id TEXT PK；account_id→CASCADE；source TEXT NOT NULL DEFAULT 'user'；external_id TEXT NULL；relation_type TEXT NOT NULL DEFAULT 'conflict'；primary_entity_type / primary_entity_id / related_entity_type / related_entity_id TEXT NULL（exam_for_course 用）；left_kind / left_id / right_kind / right_id TEXT NULL（conflict 用）；left_event_id / right_event_id TEXT NULL → calendar_events(id) CASCADE；left_plan_block_id / right_plan_block_id TEXT NULL → plan_blocks(id) CASCADE；left_occurrence_exception_id / right_occurrence_exception_id TEXT NULL → calendar_event_occurrence_exceptions(id) CASCADE（v7 起，带 `@ReferenceName` 区分，L131-166）；conflict_state / reason TEXT NULL；created_at / updated_at INTEGER NOT NULL。**UNIQUE(account_id, left_kind, left_id, right_kind, right_id)**、**UNIQUE(account_id, source, external_id)**（L179-182）。**巨型 CHECK**（L185-223）：relation_type='conflict' 时左右端点各须恰好一个 FK（event 需 event_id 或 occurrence_exception_id 恰一且与 left_id 对齐；plan_block 需 plan_block_id=left_id 且事件 FK 全空）、conflict_state IN ('conflict','no_conflict')、primary 字段全空；relation_type='exam_for_course' 时 external_id/primary/related 非空、端点字段全空、conflict_state IS NULL。

**17. `schedule_relation_rules`**（L226-267）：id TEXT PK；account_id→CASCADE；left_series_type / left_series_id / right_series_type / right_series_id TEXT NOT NULL；conflict_state TEXT NOT NULL；reason TEXT NULL；effective_from TEXT NOT NULL；effective_through TEXT NULL；created_at / updated_at INTEGER NOT NULL。**UNIQUE(account_id, left_series_type, left_series_id, right_series_type, right_series_id, effective_from)**（L248-257）。**CHECK**：effective_through NULL 或 >= effective_from；series_type IN ('course_series','calendar_event_series')（双方）；conflict_state IN ('conflict','no_conflict')。

**18. `reminders`**（L269-326）：id TEXT PK；account_id→CASCADE；target_type / target_id TEXT NOT NULL；event_id TEXT NULL → calendar_events CASCADE；occurrence_exception_id TEXT NULL → calendar_event_occurrence_exceptions CASCADE（v7）；task_id TEXT NULL → tasks CASCADE；plan_block_id TEXT NULL → plan_blocks CASCADE；offset_minutes INTEGER NULL；trigger_at INTEGER NOT NULL；state TEXT NOT NULL；failure_code TEXT NULL；delivered_at INTEGER NULL；created_at / updated_at INTEGER NOT NULL。**UNIQUE(account_id, target_type, target_id, trigger_at)**（L307-309）。**CHECK**：target_type IN ('event','task','plan_block')；state IN ('desired','delivered','cancelled','missed','failed')；target 与 FK 一致性（event 目标须 event_id 或 occurrence_exception_id 恰一；task 须 task_id；plan_block 须 plan_block_id，其余 FK 全空，L315-324）。

**19. `undo_slot`**（L328-343）：slot INTEGER PK DEFAULT 1；command_id TEXT NOT NULL；payload TEXT NOT NULL；expires_at INTEGER NULL；created_at INTEGER NOT NULL。**CHECK (slot = 1)**——恒单行，靠 `insertOnConflictUpdate` 覆盖（`app_database.dart:82-94`）。

#### agent_tables.dart

**20. `agent_settings`**（`agent_tables.dart:5-22`）：account_id TEXT PK → CASCADE；model TEXT NOT NULL DEFAULT 'deepseek-v4-flash'；enabled INTEGER NOT NULL DEFAULT 0；icourse_consent INTEGER NOT NULL DEFAULT 0；system_prompt_version INTEGER NOT NULL DEFAULT 2；updated_at INTEGER NOT NULL。

**21. `agent_secrets`**（L24-39）：account_id TEXT PK → CASCADE；api_key_ciphertext BLOB NOT NULL；scheme TEXT NOT NULL；protection_version INTEGER NOT NULL；protection_metadata TEXT NOT NULL DEFAULT '{}'；updated_at INTEGER NOT NULL。

**22. `agent_runs`**（L41-68）：id TEXT PK；account_id→CASCADE；model / status TEXT NOT NULL；error_code TEXT NULL；input_tokens / output_tokens INTEGER NULL；started_at INTEGER NOT NULL；finished_at INTEGER NULL。**UNIQUE(id, account_id)**——供 chat_messages/tool_invocations 复合外键绑定同账户（注释 L59-63）。

**23. `chat_messages`**（L70-102）：id TEXT PK；account_id→CASCADE；run_id TEXT NULL（无内联 references，见注释 L74-77）；ordinal INTEGER NOT NULL；role / state / content TEXT NOT NULL；created_at / updated_at INTEGER NOT NULL。**UNIQUE(account_id, ordinal)**；**CHECK 内嵌 FOREIGN KEY (run_id, account_id) REFERENCES agent_runs(id, account_id) ON DELETE CASCADE**（L98-101）。

**24. `tool_invocations`**（L104-134）：id TEXT PK；account_id→CASCADE；run_id TEXT NOT NULL；tool_name TEXT NOT NULL；status TEXT NOT NULL；safe_arguments_summary / safe_result_summary TEXT NOT NULL；started_at INTEGER NOT NULL；finished_at INTEGER NULL；error_code TEXT NULL（v6 起，仅安全错误码，注释 L118-120）。复合外键同 chat_messages（L130-133）。

**25. `conversation_summaries`**（L136-155）：id TEXT PK；account_id→CASCADE；through_ordinal INTEGER NOT NULL；content TEXT NOT NULL；model TEXT NOT NULL；created_at INTEGER NOT NULL。**UNIQUE(account_id)**——每账户一条摘要。

#### operation_tables.dart

**26. `action_logs`**（`operation_tables.dart:5-24`）：id TEXT PK；account_id TEXT NULL → local_accounts(id) **ON DELETE SET NULL**；source / action_type / result / safe_summary TEXT NOT NULL；risk_level TEXT NULL（v4 起）；occurred_at INTEGER NOT NULL。无索引（`ActionLogRepository.selectAll` 全表扫描按 occurred_at 倒序，`app_database.dart:228-230`）。

**27. `agent_permission_policies`**（L26-53）：id TEXT PK；account_id→CASCADE；action_type TEXT NOT NULL；target_type TEXT NOT NULL DEFAULT '*'；confirmation_mode TEXT NOT NULL；risk_level TEXT NOT NULL DEFAULT 'medium'；scope TEXT NOT NULL DEFAULT 'user_default'；enabled INTEGER NOT NULL DEFAULT 1；first_confirmed_at / last_confirmed_at / expires_at INTEGER NULL；updated_by TEXT NULL；created_at / updated_at INTEGER NOT NULL。**UNIQUE(account_id, action_type, target_type)**（L50-52）。

### 4.3 迁移历史（`app_database.dart:96-194`）

| 目标版本 | 变更 | 证据 |
|---|---|---|
| v1 | 初始 schema | `onCreate: migrator.createAll()` L98-100 |
| v2 | local_accounts 增 identity_digest | L102-104 |
| v3 | 新建 agent_settings / agent_secrets / agent_runs / chat_messages / tool_invocations / conversation_summaries | L105-112 |
| v4 | action_logs 增 risk_level；**重建** agent_permission_policies（"v3 占位表从未被使用"，drop+createTable） | L113-118 |
| v5 | 新建 jw_day_moves | L119-121 |
| v6 | tool_invocations 增 error_code（`from >= 3` 守卫：v3 分支以 v6 定义建表，避免重复 addColumn，注释 L122-127） | L128-130 |
| v7 | calendar_event_series 增 reminder_offsets_json + 回填 UPDATE（timed '[15]' / all-day '[]'）；task_event_links 表重建（PK 变更 + occurrence_exception_id，旧 event_id→target_id 无损迁移）；schedule_relations / reminders 表重建（装新 CHECK + occurrence-exception FK 列） | L156-189 |

一致性测试：`app/test/core/database/schedule_task_schema_test.dart`（CHECK/UNIQUE/FK 约束行为，含 v7 目标规则断言）、`app/test/core/database/account_source_schema_test.dart`（账号/来源表）。

### 4.4 SourceBundle 1.0 契约（导入层对外契约）

- Schema 文件：`app/assets/schemas/source-bundle-1.0.draft7.schema.json`（JSON Schema draft-7）。
- 信封：`schemaVersion`（必须 '1.0'）、`bundleId`、`source`、`subject.accountId`、`collectedAt`、`snapshot{completeness, scope}`、`manifest{sourceRecordCount, calendarEventCount, courseSeriesCount, scheduleRelationCount}`、`data{sourceRecords, calendarEvents, courseSeries, scheduleRelations}`（`source_bundle_decoder.dart:74-117`）。
- `digest`：sha256(canonicalJson(raw))——键排序后的规范 JSON（`source_bundle.dart:31-32,203-218`）。
- 错误码表（10 个，`source_bundle_error.dart:11-21`）：`unsupported_version` / `invalid_envelope` / `incomplete_snapshot` / `subject_mismatch` / `count_mismatch` / `duplicate_identity` / `dangling_reference` / `invalid_time` / `limit_exceeded`。另见语义校验的敏感键黑名单（authorization/cookie/password/token 等 11 类键名，`source_bundle_semantics.dart:44-58`）。

## 5. 现状·错误处理

**错误码/异常类型**：
- 导入错误：`SourceBundleError(code, safeMessage)`（`source_bundle_error.dart:1-9`），code 见 4.4。语义校验失败同一机制。
- 业务确定性错误（跨服务统一命名，供 Agent 工具映射为安全错误码）：
  - `AlreadyDeletedError` / `InvalidLifecycleTransition` / `StaleEventCommand`（`calendar_event_service.dart:21-47`，注释标注对应 Spec §20 的 `already_deleted` / `invalid_lifecycle_transition` / `stale_target`）；
  - `StaleOverlayCommand`（`overlay_service.dart:106-111`）、`StaleRecurringTarget` / `ScopeRequiredError` / `AlreadyLifecycleDeleted` / `InvalidRecurringTransition`（`recurrence_lifecycle_service.dart:42-73`）、`StalePlanBlockCommand` / `LockedPlanBlockError` / `IllegalPlanBlockTransition` / `PlanBlockNotFoundError`（`plan_block_service.dart:9-43`）、`StaleTaskCommand` / `IllegalTaskTransition` / `TaskNotFoundError`（`task_lifecycle_service.dart:11-32`）、`StaleTaskEventLinkCommand` / `TaskEventLinkTargetNotFoundError` / `TaskEventLinkNotFoundError`（`task_event_link_service.dart:8-32`）、`StaleReminderTargetCommand`（`reminder_override_service.dart:20-25`）、`ConflictValidationError` / `ConflictNotDeletableError(code)` / `ConflictRelationNotFoundError`（`conflict_service.dart:35-64`）；
  - 领域校验：`CalendarValidationError`（`personal_event.dart:18-25`）、`RecurrenceValidationError`（`recurrence_rule.dart:5-12`）、`RecurrenceLimitError`（`recurrence_expander.dart:3-10`）、`TaskValidationError` / `PlanBlockValidationError`（`task.dart:29-36`、`plan_block.dart:17-24`）、调休三异常（`jw_day_move.dart:53-79`）、`OccurrenceNotFoundError`（`recurrence_service.dart:11-16`）；
  - 撤销：`InvalidUndoCommand`（`undo_service.dart:9-11`）；通知：`NotificationDeliveryError('unavailable')`（`foreground_notification_adapter.dart:15-19`）。
- 未知/异常路径：业务读缺失大多抛 `StateError`（如 `calendar event not found`，`effective_event_repository.dart:390`）。

**事务边界与回滚**：
- 所有写路径在 `database.transaction()` 内：导入（`import_service.dart:51`）、事件/系列/任务/计划块/覆盖/冲突/调休/提醒/撤销恢复器，业务写 + ActionLog + Undo 快照同事务提交。
- TOCTOU 复验（Spec §20）：写前按 `expectedUpdatedAt` / `expectedOffsetsSnapshot` 重查目标，过期抛 stale 类错误且不写（`overlay_service.dart:230-233`、`reminder_override_service.dart:156-181`、`plan_block_service.dart:501-503`、`calendar_event_service.dart:465-467`）。
- 事务失败整体回滚；撤销应用失败保槽（`undo_service.dart:126-140`）。

**重试策略**：
- 提醒协调失败不重试导入：记 `retryable_failure` 审计 + `reminderReconciliationPending` 标记，由后续触发重协调（`import_service.dart:54-70`）。
- 同步层：`SyncCoordinator.recoverInterruptedRuns` 将遗留 `running` 标记为 `interrupted/app_restarted`（`sync_coordinator.dart:390-397`），启动/页面加载时调用（`sync_page.dart:58,134`）。

**恢复路径**：外键 CASCADE 保证删除账户时全表联动清理；`source_records.import_batch_id` 用 RESTRICT（保护批次行不被孤儿化）而 `sync_runs.import_batch_id` 用 SET NULL（`source_tables.dart:64-68,95-99`）。

## 6. 现状·观测点

**状态持久化（落库）**：
- 业务全量落库：见 4.2 数据字典。软删除（deleted_at）、生命周期状态（status/state）、完成时间戳（completed_at/completedAt）均为显式列。
- 同步/导入状态：`sync_runs`（trigger/state/result_code）、`import_batches`（bundleId/digest/scopeKey/origin）、`source_records`（presence/首次与最后观察时间）。
- 用户偏好：`source_configs` 存两用途——数据源开关（含 last_success_at/retry_after）与应用设置 JSON（`pythonPath`、`disabledReminderTypes`、JW 学期，`settings_service.dart:62-99`）。
- 撤销：`undo_slot` 单行 JSON 快照（含 `expires_at` 列但未见读取方，见第 10 节）。
- Agent 运行：`agent_runs`/`chat_messages`/`tool_invocations`/`conversation_summaries`（每账户一条摘要）。

**日志/审计**：`action_logs` 为唯一审计表，所有用户写（source='user'）、导入（source=数据源名）、Agent 运行（source='agent'，`agent_session_service.dart:1696-1703`）、系统操作（source='system'，`settings_service.dart:246-254`）均追加；`safe_summary` 为安全摘要（无 id/ref/原始异常）。Agent 侧另有 `tool_invocations.safe_arguments_summary/safe_result_summary/error_code` 与 `MutationLedger` 聚合计数（`agent_mutation_ledger.dart:25-216`）。

**可恢复性**：
- 重启后：启动自动同步（`runStartupAutomaticSync`，`sync_page.dart:19-69`）恢复中断同步；`UndoService.clearAtStartup` 清空撤销槽；提醒协调器 `start()` 全量重协调并重建定时器（`windows_reminder_reconciler.dart:53-57`）。
- 取消/停止语义：提醒定时器 `cancelAll`（重建/停止时，`windows_reminder_reconciler.dart:130,87-90`）；协调防抖标志 `_refreshingDomain/_refreshAgain`（L99-113）；`sync_runs` 中断标记（见上）。

## 7. 端到端链路参与

| 链路 | 本模块环节 | 上下游 |
|---|---|---|
| completeReset | `SettingsService.completeReset` 事务内：删 action_logs（本账户）→ 清 undo_slot → 删 local_accounts 行，业务表靠 FK CASCADE 连带清理（`settings_service.dart:170-190`）；`clearBusinessData` 则显式按 15 张表逐删（L118-168，旧记"16 张"为计数笔误；目标态另同事务清 undo_slot，见 09 §7.4 CT-C3-06） | 上游：settings 模块（模块 06？）；下游：accounts（凭证/会话清理） |
| 同步链路 | `ImportService.importBytes` 作为 `SyncCoordinator.importBundle` 回调消费 Bridge 采集结果（`sync_page.dart:56,132`）；`sync_runs`/`import_batches`/`source_records` 状态写入；`recoverInterruptedRuns` 读取 `sync_runs` | 上游：sync 模块（Bridge/采集，模块 04/05 待确认）；下游：reminders（协调）、schedule（有效事件流） |
| Agent 查询 | `DriftAgentLocalDataGateway` 聚合本模块读服务（`agent_local_data_gateway.dart:333`）：有效事件/冲突/覆盖/撤销预览/提醒配置/历史/递归投影；`HistoryRepository.query` 上限 50 条（`history_repository.dart:25`）；Agent 生命周期写经本模块各写服务并以 `source='agent'` 审计（`agent_session_service.dart:1696`） | 上游：agent 模块（模块 02 待确认）；本模块提供全部本地数据读取 |

（注：各模块正式编号以主 agent 分配为准，此处以"模块 0X 待确认"标注。）

## 8. 原生目标态对照

> 本节全部内容标注【目标态推断】。不引用任何既有 flutter-native 设计文档，只描述方向与开放决策。

1. **职责是否保留**【目标态推断】：保留。数据存储模块与"数据从哪来"完全解耦——本模块只消费 SourceBundle 字节流，从不直接接触采集端。在"全部数据链路 Flutter 原生化、Bridge 消失"的最终形态中，采集逻辑（原 Python 侧）与传输层（Bridge）消失，但本模块的数据库、表族、服务层是采集结果的落点，必然整体保留；原 Python 数据层中"生成 SourceBundle"的部分职责需要寻找新宿主（原生采集器或迁移到 Dart），而"消费 SourceBundle"的本模块职责原样保留。settings 模块的 `pythonPath` 配置与 `PythonLocator` 随之消亡，但 `source_configs` 表本体（开关、JW 学期配置）继续存在。

2. **哪些契约会被保留**【目标态推断】：
   - SourceBundle 1.0 契约大概率保留（探索规格提示）：信封结构、digest 幂等语义、9 个错误码（L2-07 修正）、16MB 上限、`assets/schemas/source-bundle-1.0.draft7.schema.json` 都独立于采集实现；即便采集端重写，只要仍有"外部采集→本地导入"边界，该契约就是稳定的模块间接口。
   - 27 张表结构与 `schemaVersion` 迁移线：本地数据是长期资产，不可因 Bridge 消失而失效。
   - 审计契约（action_logs 字段语义、safe_summary 约定）、撤销契约（undo_slot v1 信封）、提醒协调契约（reminders 状态机与哨兵语义）。
   - 服务级读接口（EffectiveEventRepository/ConflictService/OverlayService/UndoService/HistoryRepository 等）作为 presentation 与 Agent 的本地数据门面。

3. **开放决策**（明确"待决策"，不替重构者决定）：
   - 【待决策】SourceBundle 的生产端：Bridge 消失后由原生 Dart 采集器直接生成，还是 Python 采集逻辑经其他通道（如打包为本地可执行）继续产出？这决定 SourceBundle 1.0 是终态契约还是过渡契约。
   - 【待决策】Python 数据层既有本地数据（若存在）是否迁移进 Flutter 数据库，迁移工具与冲突处理策略。
   - 【待决策】`source_records`/`sync_runs`/`import_batches` 三表的同步状态机在无 Bridge 场景下是否简化（trigger 枚举、重试语义）。
   - 【待决策】undo_slot 单槽撤销是否随 Agent 工具集扩大升级为多槽/历史撤销（涉及第 9 节的 Event Sourcing 讨论）。

## 9. 开源参考与优化建议

参考来源（WebSearch 发现）：
- [Android Room MigrationTestHelper 文档](https://developer.android.google.cn/reference/androidx/room/testing/MigrationTestHelper) 与 [Room 迁移最佳实践（阿里云开发者社区）](https://developer.aliyun.com/article/1747545)：迁移测试必须从"旧版本建库→插入代表性数据→跑迁移→校验 schema 与数据保留"四步走。
- [Microsoft Architecture Center: Event Sourcing](https://raw.githubusercontent.com/microsoftdocs/architecture-center/refs/main/docs/patterns/event-sourcing.md)：append-only 事件日志用于审计、回放、回滚；快照用于性能。
- [OneUptime blog: MySQL 实现 Event Sourcing](https://github.com/OneUptime/blog/blob/master/posts/2026-03-31-mysql-implement-event-sourcing-with-mysql/README.md)：append-only 表 + `UNIQUE(aggregate, version)` 乐观并发 + 快照表。
- [engineering-handbook: Event Sourcing 架构模式](https://github.com/handbook-academy/engineering-handbook/blob/main/content/hld/part-5-architecture-patterns/03-event-sourcing.md)：快照永远不是权威，可回退全量回放。

**提取的可借鉴模式**：
1. Room 的"每个 schema 版本必须有从 N-1 的迁移 + 数据保留断言"测试纪律；`validateDroppedTables` 检查被重建表。
2. Event Sourcing 的"append-only 审计 + 版本号乐观并发 + 快照"三件套，与"快照可丢弃、事件不可丢"的边界。
3. SQLite 表重建模式（create new → INSERT SELECT → drop → rename）作为 ALTER 受限时的手工迁移范式。

**对本模块的具体可落地建议**：
1. **补齐迁移测试矩阵**：当前 `app/test/core/database/` 下仅有两个约束行为测试，未发现"vN→v7 迁移后数据保留"的端到端断言（如 v6 库经 v7 迁移后 task_event_links.target_id=旧 event_id、reminder_offsets_json 回填 '[15]'/'[]'）。建议为 v2→v7 每条升级路径建 NativeDatabase 文件库、插入旧版形状数据、跑 `migrator` 后断言行数与值——直接对应 Room MigrationTestHelper 模式。未验证项见第 10 节。
2. **action_logs 无索引**：`ActionLogRepository.selectAll` 与 `HistoryRepository.query` 均按 occurred_at 倒序全扫（`app_database.dart:228-230`、`history_repository.dart:67`）。建议评估为 (account_id, occurred_at) 加索引；涉及 v8 迁移与 `action_logs` 表重建，属开放决策。
3. **undo_slot 与 Event Sourcing 的结合**：当前撤销是"最新一单快照"（单槽覆盖，`app_database.dart:82-94`），而 action_logs 已是事实上的 append-only 操作日志。若要支持多步撤销/Agent 批量操作逆向，可借鉴 Event Sourcing 模式把撤销演进为"每账户事件序列 + 每命令快照"，快照可裁剪但事件序列保留——先决条件是 `expires_at` 语义落地（当前只写入未消费，见第 10 节）。
4. **幂等键模式已就位、可复用**：`import_batches` 的 UNIQUE(account_id, bundle_id)/UNIQUE(account_id, digest) 与 `reminders` 的确定性主键 `reminder:<type>:<target>:<trigger>`（`reminder_service.dart:328-329`）已是 Event Sourcing 建议的幂等键实践；新增任何"重放类"写入（如未来的原生采集重试）应沿用同一模式。
5. **文档化 v7 重建表风险**：v7 对 task_event_links/schedule_relations/reminders 做了表重建（`app_database.dart:156-189`），未来任何加列/改 CHECK 都会再触发重建；建议在表文件注释中固定"重建类迁移必须同时更新 schema 测试"，避免 CHECK 语义漂移。

## 10. 未验证/存疑事项

**已验证**（路径与行号均经 Read/Grep 确认）：第 2 节目录树全部文件；第 4 节 27 张表定义（6 个表文件逐行读取）；迁移代码（`app_database.dart:96-194`）；导入流水线全链（import_service/decoder/semantics/repository/result/error/reminder_reconciler）；有效事件 SQL 与冲突投影（effective_event_repository/schedule_conflict_projection/conflict_service/overlap_engine/schedule_projection）；递归三件套（recurrence_service/lifecycle/projection + expander/rule/locator/personal_event）；任务与计划块（task_lifecycle/plan_block/task_event_link/plan_block_lifecycle_port）；撤销全恢复器（undo_service 11 类 + 复合）；提醒协调（reminder_service/override/windows_reconciler/foreground_adapter/reminder_rule）；历史（history_repository）；completeReset 与 clearBusinessData（settings_service）；sync 消费点（sync_page.dart:34-40,105-111,56,132；sync_coordinator.dart:338,390-470）；schema 约束测试文件存在（schedule_task_schema_test.dart 已读全文；account_source_schema_test.dart 仅确认存在、未读）；`assets/schemas/source-bundle-1.0.draft7.schema.json` 存在。

**未验证/存疑**：
1. `account_source_schema_test.dart` 全文未读（仅确认路径），其中断言内容未核验。
2. 迁移路径测试：未发现"从旧版本库升级到 v7 且数据保留"的迁移测试文件（test 目录下仅两个 schema 测试与各 feature 测试）；若存在其他位置的迁移测试，grep 未覆盖到。
3. `undo_slot.expires_at`、`AgentPermissionPolicies.expires_at` 与 `UndoService.clearAtStartup`：expires_at 仅见写入（`app_database.dart:91` 等），未发现读取/过期清理逻辑；`clearAtStartup`（`undo_service.dart:78`）在 lib 生产代码中无调用方，仅测试直接调用（`app/test/features/tasks/plan_block_undo_test.dart:569`、`app/test/features/agent/drift_agent_write_gateway_test.dart:1766`）——启动清槽语义疑似由其他路径承担或已废弃，未确认。
4. `source_configs.retry_after` / `last_success_at`：确认表结构与 settings_service 写入，但同步侧读取语义（`sync_coordinator.dart:69-70` 使用 last_success_at 判新鲜度）只见到部分，完整重试策略未逐行核验。
5. `app_database.g.dart` 的生成 schema 与表文件的一致性未做全量 diff（抽查 local_accounts 列名一致）。
6. 第 9 节建议 1（迁移测试缺口）基于 Glob 结果推断——若 test 目录存在命名不含 database/schema 的迁移测试，可能漏检。
7. 同步模块（sync_coordinator 完整逻辑、Bridge 采集协议）与 accounts 模块（identity_digest 全流程）超出本模块范围，仅交叉引用，未深读。
8. Drift 运行参数（WAL 模式、连接配置）在 `connection.dart` 仅见 `driftDatabase(name:)` 一行，具体执行器设置未验证。
