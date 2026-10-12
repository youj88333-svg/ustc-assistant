# 日程表前端 技术文档

> 模块编号：05 ｜ 产出日期：2026-08-12 ｜ 覆盖分支：main ｜ 探索者：subagent-05

## 1. 职责边界

### 1.1 本模块做什么

本模块是日程表业务的所有**展示层（presentation）**代码，覆盖四个 feature 的 UI：

- `app/lib/features/schedule/presentation/` —— 周课表、日程详情、冲突管理、整日调课、日程偏好（14 个文件）
- `app/lib/features/tasks/presentation/` —— 任务中心、任务详情、任务表单、计划时段编辑、待复核列表、任务筛选（7 个文件）
- `app/lib/features/calendar/presentation/` —— 个人日程表单、重复规则编辑器、日程管理页（3 个文件）
- `app/lib/features/history/presentation/history_page.dart` —— 操作历史页（1 个文件）

### 1.2 本模块不做什么

- **不含 domain/application 层**：各 feature 的 domain（投影、实体）与 application（服务、仓储）归模块 03（见 03-data-storage.md），本模块只消费它们。
- **不含路由表与壳层布局**：`app/lib/app/router.dart`（GoRouter 路由表、Shell、各 Loader 包装页）与 `app/lib/app/app_drawer.dart`（侧边栏）归模块 04；本模块只提供被路由构造的页面组件本身（边界说明见第 4.1 节）。
- **reminders feature 无独立 presentation 层**：已通过目录验证，`app/lib/features/reminders/` 只有 `application/`、`data/`、`domain/` 三个子目录（reminder_service.dart、reminder_override_service.dart、windows_reminder_reconciler.dart、foreground_notification_adapter.dart、reminder_rule.dart）。提醒的 UI 入口是日程/任务表单内的"提醒开关"（如 `calendar_event_form.dart:227-235` 的 `event-reminder-toggle`），不构成独立页面。

### 1.3 依赖关系

- **上游（被本模块消费）**：模块 03 的 application 服务（EffectiveEventRepository、ConflictService、OverlayService、JwDayMoveService、TaskLifecycleService、PlanBlockService、UndoService、CalendarEventService、HistoryRepository）与各 feature 的 domain 投影（buildWeek、projectTask、projectPlanBlock、expandRecurrence、UstcPeriods、WeekRange、OverlapGroup 等，详见第 4.3 节）；`app/lib/core/database/app_database.dart`（AppDatabase）与 `app/lib/core/time/beijing_clock.dart`（BeijingClock）。
- **下游（消费本模块）**：`app/lib/app/router.dart` 构造全部页面（router.dart:76-184）；`app/lib/app/app.dart:16-17` re-export `ScheduleSection`；`app/test/goldens/responsive_golden_test.dart:190-204` 直接构造 `WeekTimetable` 做 golden 测试；`app/lib/features/schedule/presentation/schedule_page.dart:449` 在周视图任务区复用自己的 `TaskCenterPage`（跨 feature 复用）。

## 2. 现状·核心组件

### 2.1 目录树（仅本模块范围）

```
app/lib/features/schedule/presentation/
├── schedule_page.dart            (538 行) 周课表主页面（周视图/任务双分区 + 撤销浮条）
├── week_timetable.dart           (515 行) 周网格渲染（全天带/凌晨带/任务带/时间轴/列）
├── all_day_band.dart             (77 行)  全天事件横向带
├── early_morning_band.dart       (88 行)  凌晨(0:00-7:00)事件横向带
├── time_axis.dart                (33 行)  节次时间轴（按 UstcPeriods 定位）
├── event_block.dart              (115 行) 网格内单个事件/计划块块体
├── overlap_expansion.dart        (61 行)  重叠组展开对话框
├── conflict_management_page.dart (253 行) 冲突管理页（Loader + 页面 + 优先级/配对）
├── conflict_editor.dart          (174 行) 冲突对编辑器（状态/范围/原因 + 保存）
├── event_detail_loader.dart      (224 行) 日程详情 Loader（解析 id → 数据 → 页面）
├── event_detail_page.dart        (189 行) 日程详情展示页
├── event_preferences_sheet.dart  (202 行) 日程偏好底部表单（出勤/听讲/备注/颜色）
├── jw_day_move_dialog.dart       (278 行) 整日调课对话框（源/目标日期 + 预览）
└── schedule_undo_notice.dart     (55 行)  页面局部撤销浮条（非全局 SnackBar）

app/lib/features/tasks/presentation/
├── task_center_page.dart         (126 行) 任务中心（筛选 + 撤销 + 删除恢复 + 待复核）
├── task_detail_loader.dart       (330 行) 任务详情 Loader（装配服务与投影）
├── task_detail_page.dart         (405 行) 任务详情展示页（含计划时段操作）
├── task_form.dart                (254 行) 新建任务表单
├── plan_block_editor.dart        (115 行) 计划时段编辑底部表单
├── pending_review_list.dart      (68 行)  待复核计划时段列表（菜单操作）
└── task_filters.dart             (62 行)  任务筛选与周课表任务带投影函数

app/lib/features/calendar/presentation/
├── calendar_event_form.dart      (422 行) 个人日程新建/编辑表单
├── recurrence_editor.dart        (193 行) 重复规则编辑器（日/周/月 + 预览）
└── personal_event_management_page.dart (219 行) 已取消/已隐藏/已删除日程管理页

app/lib/features/history/presentation/
└── history_page.dart             (85 行)  操作历史页（成功/失败筛选）
```

### 2.2 关键组件职责

**schedule 分区**

- `SchedulePage`（schedule_page.dart:26-55）：周视图/任务分区主页面。构造参数为 `database`、`onEventSelected`、`onTaskSelected`、`onManageRelations`、`initialSection`、`clock`。State 带 `AutomaticKeepAliveClientMixin`（schedule_page.dart:57-121），因壳层 `StatefulShellRoute.indexedStack` 会保活（schedule_page.dart:111-118 注释），`didUpdateWidget` 里必须同步新的 `initialSection`，否则路由重建后分区不更新。
- 周导航（schedule_page.dart:151-168、476-538）：`_WeekNavigation` 提供上一周/回到本周/下一周，`selectedDate` 为纯内存态（schedule_page.dart:156-167）。
- `_ScheduleData`（schedule_page.dart:261-474）：数据装配层——活动账号 FutureBuilder → 任务 StreamBuilder（`query.watch()`，schedule_page.dart:306-312）→ 周视图下再套 `watchDisplayEvents` 流（schedule_page.dart:320-325）→ `conflictsForItems` 一次性冲突投影（schedule_page.dart:332-336）→ 计划块流（schedule_page.dart:337-366）→ `buildWeek` 投影并交给 `WeekTimetable`（schedule_page.dart:403-421）。
- `WeekTimetable`（week_timetable.dart:17-48）：纯渲染组件（无数据依赖，输入为 `ScheduleProjection`），常量 `axisWidth=56`、`minimumDayWidth=142`、`pixelsPerMinute=0.72`（week_timetable.dart:50-52）。`LayoutBuilder` 自适应：窗口宽度足够则 7 列均分，不足则按最小列宽 142 产生横向滚动（week_timetable.dart:60-66，滚动容器 Key `week-horizontal-scroll`，week_timetable.dart:87）。整日调课入口为网格上方固定的 48px 条带（week_timetable.dart:67-84）。
- `AllDayBand` / `EarlyMorningBand`（all_day_band.dart:5-40、early_morning_band.dart:9-44）：与全周网格同构的横向带，每天最多 3 条 + `+N` 溢出（all_day_band.dart:54-75、early_morning_band.dart:58-77）；无事件时 `SizedBox.shrink()` 不占空间。
- `_DatedTaskBand` / `_UndatedTaskBand`（week_timetable.dart:170-293）：任务带——"未定截止"（ActionChip Wrap，week_timetable.dart:210-225）与"截止事项"（每列 72px 高 ListView，week_timetable.dart:250-292）；`_DeadlineTaskChip` 计算逾期/今天截止语义并带 `Semantics` 标签（week_timetable.dart:349-361）。
- `_DayColumn`（week_timetable.dart:415-469）：单日列——先画节次边界线（`UstcPeriods.boundaries()` 去重，week_timetable.dart:450-464），再按前景优先级排序放置事件块（week_timetable.dart:434-441）；`_eventPosition`（week_timetable.dart:471-514）实现非前景块 `ImageFilter.blur` 模糊（week_timetable.dart:496-499）与重叠组 Key。
- `EventBlock`（event_block.dart:6-115）：单块渲染，颜色取自 `courseColorValue(item.colorKey)` 或用户色（event_block.dart:22-24），语义标签拼接标题/地点/任务时间段/冲突/预览（event_block.dart:26-34），非本周上课预览用 `opacity 0.3` + 虚线边框（event_block.dart:41-49）。
- `OverlapExpansion`（overlap_expansion.dart:6-61）：点击重叠块弹出的组列表；`onManageRelations` 非空时显示"处理重叠关系"命令（overlap_expansion.dart:47-54），把活动 `OverlapGroup` 交回调用方路由到混合关系编辑器。
- `ConflictManagementRequest`（conflict_management_page.dart:13-17）：`/schedule/conflicts` 路由 payload，只接受 `items`。
- `ConflictManagementLoader`（conflict_management_page.dart:22-73）：`/events/:eventId/conflicts` 的 Loader——经 `overlappingRecords(eventId)` 解析并统一映射为 `ScheduleGridItem`（conflict_management_page.dart:63-71）。
- `ConflictManagementPage`（conflict_management_page.dart:82-253）：混合冲突管理页——若任一参与者是 PlanBlock 则整个"优先显示"区隐藏（conflict_management_page.dart:99-114、128-155）；前景默认取 `foregroundPriority` 最高者（conflict_management_page.dart:181-188）；保存前景经 `OverlayService.setForegroundPreference(100/0)`（conflict_management_page.dart:224-235）。
- `ConflictEditor`（conflict_editor.dart:27-174）：逐对编辑器——状态下拉（暂不分类/冲突/不冲突）、"应用到当前及未来兼容课次"开关（仅双方 `hasStableSeriesIdentity` 时可用，conflict_editor.dart:117-129）、可选原因；保存时先 `onBeforeSave` 再逐对 `onClassify`（conflict_editor.dart:155-173）。
- `EventDetailLoader`（event_detail_loader.dart:11-224）：`/events/:eventId` Loader。判定 personal/source/recurring：重复事件的 occurrence id 带 `occ_v1.` 前缀（event_detail_loader.dart:84），recurring 时禁用编辑偏好/编辑/删除/隐藏（event_detail_loader.dart:86-97）；隐藏/删除前有确认对话框（event_detail_loader.dart:118-130、161-173）。
- `EventDetailPage`（event_detail_page.dart:5-144）：纯展示页，五个动作均为可选回调，按非空渲染（event_detail_page.dart:30-99）；时间显示优先 `effectiveStartAt/effectiveEndAt`（整日调课投影后，event_detail_page.dart:110-117）。
- `EventPreferencesSheet`（event_preferences_sheet.dart:6-202）：底部表单，出勤/听讲下拉 + 备注 + 六色颜色选择（`Semantics(selected:)`，event_preferences_sheet.dart:139-163），保存构造 `OverlayMutation` 交 `onSave`（event_preferences_sheet.dart:181-198）。
- `JwDayMoveDialog`（jw_day_move_dialog.dart:42-238）：整日调课对话框。`preview` 预加载有代际保护（`_previewGeneration`，jw_day_move_dialog.dart:86-91）；确认按钮仅在预览非空、有课程、源目标不同时可用（jw_day_move_dialog.dart:80-84）；已有移动时按钮变"更新移动"并提供"恢复原日期"（jw_day_move_dialog.dart:154、219-229）；结果经 sealed class `JwDayMoveDialogResult`（`JwDayMovePerformed`/`JwDayMoveCleared`，jw_day_move_dialog.dart:8-30）返回。
- `ScheduleUndoNotice`（schedule_undo_notice.dart:10-55）：页面局部撤销浮条（替代全局 SnackBar），6 秒倒计时由父页 `_SchedulePageState` 持有（schedule_page.dart:89-98），dismiss 只影响展示、不动持久化的 undo slot（schedule_page.dart:62-66 注释、243-247）。

**tasks 分区**

- `TaskCenterPage`（task_center_page.dart:8-126）：任务中心，由 `_ScheduleData._taskCenter` 装配数据后复用（schedule_page.dart:424-473）；本页保持纯展示 + 回调。筛选 SegmentedButton（task_center_page.dart:58-68）、撤销按钮（Key `task-undo`，task_center_page.dart:70-75）、"最近删除"恢复区（task_center_page.dart:96-113）。
- `TaskDetailLoader`（task_detail_loader.dart:15-304）：`/tasks/:taskId` Loader——装配 UndoService/PlanBlockService/TaskLifecycleService（task_detail_loader.dart:66-83），加载任务、活动计划块、已删计划块（软删恢复区数据独立加载，task_detail_loader.dart:96-112）、`projectTask` 投影、`terminalImpact`、`canUndo`（task_detail_loader.dart:113-133）；`_mutate` 模式：动作成功后整体重载（task_detail_loader.dart:145-148）。
- `TaskDetailPage`（task_detail_page.dart:8-229）：任务详情。完成时若 `planImpact.futureAcceptedCount > 0` 先弹"处理未来计划时段"（保留/全部取消，task_detail_page.dart:156-181）再确认完成；计划时段行按 `awaitingReview`（accepted 且已过结束时间）出现 已执行/已跳过/重新安排（task_detail_page.dart:252-302）；`_DeletedBlocksSection` 折叠的软删恢复区，恢复不级联（task_detail_page.dart:318-405）。
- `TaskForm`（task_form.dart:29-254）：新建任务表单。标题必填、预计分钟 >0 校验（task_form.dart:67-73、163-167）；截止日期/时间双选择器，时间选择器强制 24 小时制（task_form.dart:223-233）；提交产出 `TaskFormSubmission`（task_form.dart:5-27），`_submit` 无 catch（见第 5 节）。
- `PlanBlockEditor`（plan_block_editor.dart:17-115）：计划时段编辑底部表单（开始时间文本 + 时长文本），提交产出 `PlanBlockDraft`（plan_block_editor.dart:3-15）。
- `PendingReviewList`（pending_review_list.dart:5-68）：待复核列表，`MenuAnchor` 菜单承载 已执行/已跳过/重新安排（pending_review_list.dart:35-55）。
- `task_filters.dart`（task_filters.dart:3-60）：纯函数层——`filterTasks`、`undatedBandTasks`、`datedBandTasks`（逾期任务钉到"今天"列，task_filters.dart:50-54），同时被 `WeekTimetable` 的任务带复用（week_timetable.dart:6、109-127）。

**calendar 分区**

- `CalendarEventForm`（calendar_event_form.dart:31-423）：个人日程新建/编辑表单（编辑时经 `initialEvent` 预填）。全天/定时切换会重置提醒开关与起止时间（calendar_event_form.dart:128-146）；提交构造 `PersonalEvent.allDay/timed`（calendar_event_form.dart:298-326）；`CalendarValidationError` 与通用异常分别落为表单内错误文案（calendar_event_form.dart:334-338）；产出 `CalendarEventSubmission`（event + reminderOffsetsMinutes + taskIds，calendar_event_form.dart:5-15）。
- `CalendarEventPrefill`（calendar_event_form.dart:17-29）：`/calendar-event/new` 路由的 extra payload（当前仅 create 菜单不传 prefill，见第 10 节存疑）。
- `RecurrenceEditor`（recurrence_editor.dart:6-193）：日/周/月 + 间隔 + 星期多选 + 结束日期，实时用 `expandRecurrence` 预览前五次（recurrence_editor.dart:37-41、138-145）；每次变更立即 `onChanged(_rule())` 通知父级（recurrence_editor.dart:169）。
- `PersonalEventManagementPage`（personal_event_management_page.dart:21-143）：已取消/已隐藏/已删除三分类 FilterChip（personal_event_management_page.dart:64-87）+ 恢复列表；数据来自 `CalendarEventService.managementEvents()`（source=user 限定，personal_event_management_page.dart:9-10、33）；完成/跳过的终态事件不在此页展示，但保留在共享查询里供 Agent `get_schedule(view=management)` 读取（personal_event_management_page.dart:199-203 注释）。恢复动作：取消→reopen、软删→restore（personal_event_management_page.dart:212-216）。

**history 分区**

- `HistoryPage`（history_page.dart:5-85）：操作历史页。构造参数 `repository` + `accountId`（历史在数据库查询层就按账号限定，history_page.dart:14-17）；成功/失败筛选 SegmentedButton（history_page.dart:34-44）；`FutureBuilder` 调 `repository.query(accountId, filter: HistoryFilter(result: ...))`（history_page.dart:47-51）。注意是**一次性查询**而非流。

## 3. 现状·关键数据流

### 3.1 周课表渲染流（数据 → 投影 → 渲染）

```
SchedulePage (schedule_page.dart:26)
  └─ _ScheduleData.build (schedule_page.dart:282-376)
     1. FutureBuilder: 活动账号 (localAccounts where isActive)        [schedule_page.dart:283-285]
     2. StreamBuilder: tasks.query.watch() (drift 实时流)             [schedule_page.dart:306-312]
     3. EffectiveEventRepository.watchDisplayEvents(周范围)           [schedule_page.dart:320-325]
     4. repository.conflictsForItems(events, 周范围)                  [schedule_page.dart:332-336]
     5. StreamBuilder: planBlocks.query.watch()                       [schedule_page.dart:337-342]
     6. FutureBuilder: ConflictProjectionResult                       [schedule_page.dart:347-356]
     7. 组装 ScheduleGridItem（event/plan_block 统一形状 + withConflict）
        → buildWeek(ScheduleQuery) → ScheduleProjection               [schedule_page.dart:386-406, domain 归模块03]
     8. WeekTimetable(projection, ...) 纯渲染                        [schedule_page.dart:403-421]
```

要点：冲突投影只做一次（注释明确"ONE bounded projection"，schedule_page.dart:327-331）；无账号时周视图渲染空投影空态、任务区渲染 `TaskCenterPage`（schedule_page.dart:291-305）。数据变化（同步导入、服务写入）经 drift `watch()` 自动触发重渲染，本模块无主动刷新。

### 3.2 冲突管理闭环（列表 → 编辑器 → 决策落库）

```
触发 A：周网格点击重叠块 → OverlapExpansion 对话框 (overlap_expansion.dart:24-61)
  ├─ 点击单项 → onSelected(item) → 事件详情 / 任务详情
  └─ 点击"处理重叠关系" → onManageRelations(group)                    [overlap_expansion.dart:47-54]
       → SchedulePage.onManageRelations → context.push('/schedule/conflicts',
           extra: ConflictManagementRequest(group.items))             [router.dart:86-89, schedule_page.dart:44]
       → _ScheduleConflictsLoader 校验 payload (items≥2，否则空态)      [router.dart:287-330]
       → ConflictManagementPage
            ├─ _loadPairs: 全对组合 + ConflictService.stateForPair() 预填   [conflict_management_page.dart:190-222]
            ├─ 前景 RadioGroup（仅全事件时）→ OverlayService.setForegroundPreference [conflict_management_page.dart:140-155, 224-235]
            └─ ConflictEditor
                 ├─ 每对：状态 / 范围(currentAndFuture) / 原因        [conflict_editor.dart:90-134]
                 └─ 保存：onBeforeSave → 逐对 ConflictService.classifyPair → pop [conflict_editor.dart:155-173]

触发 B：事件详情页"处理重叠日程" → /events/:eventId/conflicts        [event_detail_page.dart:65-72]
       → ConflictManagementLoader.overlappingRecords(eventId) → 同页  [conflict_management_page.dart:58-72]
```

闭环终点是 `ConflictService.classifyPair` / `setForegroundPreference` 写入持久层（模块 03）；页面保存成功即 `maybePop`（conflict_editor.dart:169），周网格靠 drift 流自动刷新冲突标记。

### 3.3 整日调课 + 单步撤销闭环

```
WeekTimetable"整日调课"按钮 (week_timetable.dart:70-84)
  → SchedulePage._openDayMoveDialog (schedule_page.dart:212-248)
     1. 查活动账号，构造 UndoService + JwDayMoveService (同一账号域)   [schedule_page.dart:213-222]
     2. showDialog(JwDayMoveDialog)
          - preview(源日期) → 课程标题预览                           [jw_day_move_dialog.dart:86-91]
          - move/clear → 结果 sealed 类型 pop                         [jw_day_move_dialog.dart:116-149]
     3. 结果驱动：Performed→选中目标周；Cleared→选中源周               [schedule_page.dart:232-237]
     4. 页面局部 ScheduleUndoNotice（6 秒倒计时，可被新通知替换）        [schedule_page.dart:238-247, 89-98]
     5. 点"撤销" → UndoService.undo() 消费持久化 undo slot             [schedule_page.dart:247]
```

注意点：通知条是页面局部（非全局 ScaffoldMessenger），离开页面即关闭（schedule_page.dart:877 测试覆盖）；倒计时结束/关闭不影响 DB undo slot（schedule_page.dart:62-66 注释）。

### 3.4 任务详情操作流（编辑 → 服务 → 重载）

```
/tasks/:taskId → TaskDetailLoader (task_detail_loader.dart:15)
  → _load(): 装配服务 + byId + 计划块(活动/已删) + projectTask + terminalImpact + canUndo
  → TaskDetailPage
      ├─ 安排时间/编辑/重新安排 → showModalBottomSheet(PlanBlockEditor)
      │     → PlanBlockService.create / move / reschedule (expectedUpdatedAt 乐观锁)  [task_detail_loader.dart:234-293]
      ├─ 完成(可含"取消未来时段") → TaskLifecycleService.complete        [task_detail_loader.dart:171-177]
      ├─ 计划块 已执行/已跳过/删除 → PlanBlockService.markDone/markSkipped/cancel [task_detail_loader.dart:203-221]
      └─ 全部经 _mutate(action) → 成功后 _reload() 整页重查            [task_detail_loader.dart:145-148]
```

## 4. 现状·接口契约

### 4.1 本模块对外接口与消费方

| 接口 | 消费方 | 说明 |
|---|---|---|
| `SchedulePage`（schedule_page.dart:26-55） | router.dart:77-90 | 构造参数：database、onEventSelected→`/events/$id`、onTaskSelected→`/tasks/$id`、onManageRelations→`/schedule/conflicts`、initialSection（来自 `?section=`，router.dart:765-771）、clock |
| `ScheduleSection` enum（schedule_page.dart:24） | router.dart:82、app.dart:16-17（re-export） | 仅 week/tasks 两值，其他/缺失值默认 week（router.dart:765-771） |
| `WeekTimetable`（week_timetable.dart:17-48） | schedule_page.dart:403；golden 测试直接构造（responsive_golden_test.dart:190-204） | 可脱离数据层独立渲染 `ScheduleProjection` |
| `ConflictManagementRequest`（conflict_management_page.dart:13-17） | router.dart:88（extra payload）、router.dart:134-135（校验） | 只接受 `items`，非法 payload 渲染空态 |
| `ConflictManagementLoader` / `EventDetailLoader` / `TaskDetailLoader` | router.dart:100-129 | 以 `database + id` 解析数据；id 无效渲染各自的 missing 页 |
| `ConflictEditor` / `ConflictPairDraft` | conflict_management_page.dart:158-171 | 仅本模块内使用 |
| `JwDayMoveDialogResult`（sealed，jw_day_move_dialog.dart:8-30） | schedule_page.dart:232-237 | Performed/Cleared 两态驱动切周 |
| `TaskCenterPage`（task_center_page.dart:8-34） | schedule_page.dart:449（任务分区复用） | 纯回调驱动 |
| `TaskForm` / `TaskFormSubmission` | router.dart:337-365（`_TaskCreatePage`） | 提交后由路由页装配服务 |
| `CalendarEventForm` / `CalendarEventSubmission` / `CalendarEventPrefill` | router.dart:371-407（`_CalendarEventCreatePage`）、event_detail_loader.dart:139-157（编辑复用） | prefill 走路由 extra |
| `PersonalEventManagementPage` | router.dart:409-437（`_PersonalEventManagementLoader`） | 构造参数为 `CalendarEventService` |
| `HistoryPage` | router.dart:773-799（`_HistoryLoader`） | 构造参数 repository + accountId |

路由入口清单（路由表本体属模块 04，此处仅为页面-路由映射）：`/schedule`（shell 分支，router.dart:76-93）、`/task/new`（router.dart:97-99）、`/tasks/:taskId`（router.dart:100-106）、`/calendar-event/new`（router.dart:107-113）、`/events/:eventId`（router.dart:114-122）、`/events/:eventId/conflicts`（router.dart:123-129）、`/schedule/conflicts`（router.dart:130-138）、`/calendar-events/manage`（router.dart:139-143）、`/history`（router.dart:181-184）。侧边栏入口见 app_drawer.dart:7-18（"操作历史"→/history、"已隐藏日程"→/calendar-events/manage）；全局"+"菜单进 `/task/new`、`/calendar-event/new`（router.dart:254-284）。

### 4.2 对外"状态"契约

- 页面均为**无持久化状态**：selected section/date/filter、表单字段均为内存态；页面不直接写库，全部变更经模块 03 服务（页面内多处注释强调，如 jw_day_move_dialog.dart:40-41、schedule_undo_notice.dart:5-9）。
- 页面间传参走路由：query 参数（`?section=`）、path 参数（`$eventId`/`$taskId`）、extra（`ConflictManagementRequest`、`CalendarEventPrefill`）。

### 4.3 消费的模块 03 服务（详见 03-data-storage.md）

- **schedule/application**：`EffectiveEventRepository`（watchDisplayEvents:162、byId:376、overlappingRecords:332、gridItemFor:313、conflictsForItems:583）、`ConflictService`（classifyPair:130、stateForPair:284）、`OverlayService`（setEventOverlay:146、setForegroundPreference:287）、`JwDayMoveService`（preview:46、move:58、clear:94）。
- **tasks/application**：`TaskLifecycleService`（create:59、byId:143、complete:218、cancel:249、reopen:275、block/unblock:180/200、restore:306、terminalImpact:320）、`PlanBlockService`（create:66、move:132、markDone:232、markSkipped:243、cancel:254、reschedule:260、softDelete:326、restore:361）、`UndoService`（canUndo:75、undo:80、record:26、clearAtStartup:78）。
- **calendar/application**：`CalendarEventService`（create:71、edit:230、byId:184、managementEvents:214、softDelete:344、restore:367、reopen:315、hide:302）。
- **history/application**：`HistoryRepository.query`（history_repository.dart:61-64，账号级限定 + `agentHistoryLimit=50` 上限 + 过滤下推 SQL）。
- **domain 投影**（页面直接调用）：`buildWeek`/`ScheduleQuery`/`ScheduleProjection`（schedule_projection.dart:6-62）、`projectTask`/`TaskProjection`/`PlanBlockImpact`（task_projection.dart:25-56）、`projectPlanBlock`（plan_block.dart:84-86）、`expandRecurrence`/`dateOnly`/`dateText`（recurrence_expander.dart:12、recurrence_rule.dart:137-140）、`UstcPeriods`（ustc_periods.dart:9-47）、`WeekRange`（week_range.dart:1-20）、`OverlapGroup`/`EffectiveEvent`（overlap_engine.dart:5-66）、`courseColorValue`（course_color.dart:16）、`TaskItem`/`PlanBlockItem` 模型、`ScheduleGridItem`（schedule_grid_item.dart:22-163）。

## 5. 现状·错误处理

| 场景 | 处理方式 | 代码位置 |
|---|---|---|
| 事件 id 不存在 / 记录已删除 | `byId` 抛 `StateError` → catch 后渲染 `_MissingEventPage`（"记录已不存在" + 返回按钮） | event_detail_loader.dart:51-59、200-224 |
| 任务 id 不存在 | `byId` 抛 `TaskNotFoundError` → 渲染 `_MissingTaskPage` | task_detail_loader.dart:84-136、306-330 |
| 冲突载荷非法（无 items 或 <2） | 直接渲染空态页（"没有可处理的重叠日程"） | router.dart:300-306、conflict_management_page.dart:43-48 |
| 无活动账号 | 周视图渲染空投影空数据；任务区正常显示 `TaskCenterPage`；管理页/历史页渲染"请先配置学校账号" | schedule_page.dart:291-305、router.dart:309-321、425-427、785-791 |
| 整日调课移动/恢复失败 | catch 后 SnackBar「移动失败：$error」/「恢复失败：$error」，`_busy` 复位 | jw_day_move_dialog.dart:126-132、142-148 |
| 计划时段输入非法（开始时间/时长解析失败或 ≤0） | SnackBar「请输入有效的开始时间和时长」，不提交 | plan_block_editor.dart:92-99 |
| 任务表单校验 | `Form` validator：标题必填（"请输入标题"）、预计分钟 >0 | task_form.dart:67-73、163-167 |
| 日程表单校验/失败 | `CalendarValidationError` → 表单内 `validationMessage`（Key `event-validation-error`）；其他异常 → 「暂时无法保存，请检查账号和本地存储设置」 | calendar_event_form.dart:271-279、334-338 |
| 并发/乐观锁 | 所有写操作携带 `expectedUpdatedAt`，服务层抛 `StaleTaskCommand`/`StalePlanBlockCommand`/`StaleOverlayCommand`/`IllegalTaskTransition` 等（模块 03 定义）；**UI 层对这些异常没有 try/catch 与专门呈现**（见第 10 节存疑） | task_detail_loader.dart:171-228 等所有回调 |
| 对话框/表单保存中防重入 | `saving`/`_busy` 标志禁用按钮（保存中/保存中文案） | conflict_editor.dart:61、146-149、event_preferences_sheet.dart:40、181-198、calendar_event_form.dart:282-286、jw_day_move_dialog.dart:116-117 |
| 撤销不可用 | `undoAvailable` 为 false 时按钮置灰 | task_center_page.dart:70-75、task_detail_page.dart:62-70 |

无账号分支与"保存失败"分支的 UI 呈现大多存在，但**部分路径缺少显式失败反馈**（见第 10 节）。

## 6. 现状·观测点

- **状态持久化**：页面零持久化状态。所有业务状态经模块 03 服务写入 drift 表；undo 单槽存 `undoSlot` 表（app_database.dart:43、82-87）。undo slot 的清理：消费后删除（undo_service.dart:92、124）、completeReset 时删除（settings_service.dart:179）；`clearAtStartup()`（undo_service.dart:78）在生产调用点未找到（见第 10 节）。
- **日志/审计**：服务层写 `actionLogs`（UndoService/CalendarEventService/JwDayMoveService 等 `_log` 方法，归模块 03）；`HistoryPage` 是审计的展示面——按账号限定查询（history_page.dart:14-17、history_repository.dart:50-64），展示 `safeSummary` + source/actionType/时间，结果筛选（全部/成功/失败）。
- **可恢复性**：
  - 单步撤销：任务/计划块/日程/整日调课/重复事件等写操作经 `UndoService.record`（页面通过 `_taskCenter` 与 day move 流接线，schedule_page.dart:217-247、432-453；TaskDetailLoader 装配，task_detail_loader.dart:66-83）。
  - 软删除恢复：任务（task_center_page.dart:96-113）、计划块（task_detail_page.dart:144-150、318-405）、个人日程（personal_event_management_page.dart:134-142）。
  - 隐藏恢复：个人日程隐藏经 overlay 工作流（personal_event_management_page.dart:146-151 注释）。
- **遥测**：未发现专门的遥测/埋点代码；页面行为可观察性依赖 drift 流驱动的 widget 测试（第 2.2 节测试文件）与 golden 测试（见第 7 节）。

## 7. 端到端链路参与

- **completeReset**：设置页（模块 04/设置模块）→ `SettingsService.completeReset`（清 actionLogs、undoSlot、localAccounts，settings_service.dart:170-190）→ 路由 `context.go('/sync')`（router.dart:468）。本模块环节：无专属代码；重置后 drift `watch()` 流使周课表/任务区自动回到无账号空态（schedule_page.dart:291-305）。
- **同步**：sync（模块 04）导入数据后，`SchedulePage` 的 `query.watch()` / `watchDisplayEvents` 流自动刷新（schedule_page.dart:306-343）；整日调课记录 `jwDayMoves` 参与 effective 时间投影（event_detail_page.dart:110-117 展示层侧）。
- **Agent 查询**：Agent `get_schedule(view=management)`（模块 02）与 `PersonalEventManagementPage` **共享同一个** `CalendarEventService.managementEvents()` 查询（personal_event_management_page.dart:199-203 注释；agent_tools.dart:581、750）；Agent 写入（任务/日程/冲突分类等）经 drift 流实时反映到本模块页面，无需页面主动刷新。历史页数据源 `HistoryRepository.query` 同时服务 Agent 只读工具（上限 `agentHistoryLimit=50`，history_repository.dart:21-25、50-64）。

## 8. 原生目标态对照

> 本节全部内容标注【目标态推断】。不引用任何既有 flutter-native 设计文档，只描述方向与开放决策。

### 8.1 职责是否保留

【目标态推断】本模块职责**保留**。"全部数据链路 Flutter 原生化、Bridge 消失"的最终形态中，presentation 层依然存在且职责不变：页面继续由 drift 流与服务驱动；变化在数据源一侧——`EffectiveEventRepository` 等模块 03 组件改为直接消费 Flutter 原生同步链路写入的本地库，Bridge 从服务实现中消失，但页面代码的构造参数、流式订阅与回调契约无需结构性改动。本模块是纯 UI，不持有任何 Bridge/Python 依赖，是重构中受影响最小的层。

### 8.2 被保留的契约

【目标态推断】以下契约预计原样保留：
- 页面构造参数形态：`SchedulePage(database, 回调…)`、`HistoryPage(repository, accountId)` 等以 `AppDatabase` 注入的构造方式。
- 路由路径与路由 payload：`/schedule`、`/tasks/:taskId`、`/events/:eventId`、`/events/:eventId/conflicts`、`/schedule/conflicts`（`ConflictManagementRequest`）、`/calendar-event/new`（`CalendarEventPrefill`）、`/calendar-events/manage`、`/history`。
- `ScheduleSection` 枚举与 `?section=week|tasks` 语义。
- 数据流形态：drift `watch()` 流 + FutureBuilder 的一次性投影模式（冲突投影只做一次）。
- 撤销/软删恢复/审计展示等用户可见能力。

### 8.3 开放决策（待决策，不替重构者做决定）

【目标态推断】以下为开放问题，均**待决策**：
1. 页面状态管理是否引入框架（Riverpod/Bloc 等），还是维持"服务构造 + 局部 setState"现状（现状在 Loader 中集中装配、页面纯回调，已接近无框架风格）。
2. `WeekTimetable` 是否抽为独立可复用组件/包（目前已被 golden 测试独立使用，但依赖 schedule feature 内部 domain 形状）。
3. 单槽撤销体系（`undoSlot`）在原生形态下是否保留、是否支持多级撤销。
4. 冲突分类/重复规则等关系数据是否引入云端同步（目前纯本地）。
5. 时间语义：页面大量使用"北京时间"文本与 `SystemBeijingClock`（schedule_page.dart:33），原生形态下是否统一为带时区模型（当前 `DateTime` 本地语义 + 显式北京格式化并存）。
6. 任务带/全天带/凌晨带的"最多 3 条 +N"折叠策略是否保留或改为可展开。

## 9. 开源参考与优化建议

### 9.1 参考来源

- [table_calendar 官方文档](https://pub.dev/documentation/table_calendar/3.1.3/table_calendar/)：`CalendarFormat`（月/双周/周）、`eventLoader`（按日返回事件）、`CalendarBuilders` 选择性覆写 UI、`isSameDay` 日期键映射模式。
- [timetide](https://pub.dev/packages/timetide)：多视图（TideWeekView 等）、拖拽改时/改尺寸、冲突检测、内建 RRULE 解析。
- [timely_x](https://pub.dev/packages/timely_x)：day/week/month 切换、`isTimeSlotAvailable` 冲突检测、响应式断点、当前时间指示器。
- [horizontal_weekly_calendar](https://pub.dev/packages/horizontal_weekly_calendar)：重叠事件 side-by-side 布局、事件块自定义。
- [Flutter 官方无障碍测试文档](https://docs.flutter.dev/ui/accessibility/accessibility-testing)（[中文镜像](https://docs.flutter.cn/ui/accessibility/accessibility-testing/)）：`tester.ensureSemantics()` + `meetsGuideline`（`androidTapTargetGuideline` 48×48、`labeledTapTargetGuideline`、`textContrastGuideline`）。
- [Golden Toolkit](https://pub.dev/documentation/golden_toolkit/latest/)：`multiScreenGolden`（多设备尺寸 + `accessibility` 设备 textScale 2.5）、`loadAppFonts`（golden 用真实字体）、golden 与行为测试的分工建议。

### 9.2 可借鉴模式与本模块落地建议

1. **无障碍回归测试落地（具体）**：本模块现状有 `Semantics` 标签（event_block.dart:26-34、week_timetable.dart:349-361、event_preferences_sheet.dart:139-142）与 `find.bySemanticsLabel` 断言（week_timetable_test.dart:164、241；schedule_page_test.dart:596-1280），但没有 `meetsGuideline` 类检查。建议在现有 `task_ui_test`/`week_timetable_test` 中增加 `tester.ensureSemantics()` + `meetsGuideline(labeledTapTargetGuideline)`，重点覆盖 `_DeadlineTaskChip`、`EventBlock` 与 `PendingReviewList` 的 MenuAnchor 入口（48px 点击目标与标签完备性）。
2. **golden 覆盖扩展（具体）**：现状 golden 仅覆盖 `WeekTimetable` 与 AgentChatPage 三个视口（responsive_golden_test.dart:142-218），且直接 `matchesGoldenFile`、未加载真实字体。建议：(a) 引入 Golden Toolkit 的 `loadAppFonts()`（当前默认 Ahem 字体渲染黑块，golden 失真）；(b) 用 `multiScreenGolden` 扩展 `ConflictEditor`、`TaskDetailPage`、`EventPreferencesSheet` 三个表单密集页面，覆盖窄窗口 + `textScale 2.5` 的无障碍视口。
3. **拖拽改时（具体）**：计划时段编辑目前是纯文本输入（plan_block_editor.dart:65-87），对比 timetide/timely_x 的拖拽改时/改尺寸模式，可在 `WeekTimetable` 的 plan-block 上增加拖拽手势（`GestureDetector.onPanUpdate` + 网格吸附到 0.72 px/min 刻度），提交路径复用现有 `PlanBlockService.move`（task_detail_loader.dart:279-284）。
4. **当前时间指示器（具体）**：周网格纵向滚动区（week_timetable.dart:129-157）无"当前时间线"，可参考 timely_x 实现一条按 `pixelsPerMinute` 定位的指示线（仅当 `now` 在所选周内显示），`_DayColumn` 中作为 Positioned 子件加入。
5. **引入成熟日历库的评估（具体）**：`table_calendar` 的 `eventLoader` + 日期键映射与现状"drift 流 + 一次性投影"模式相冲突（现状已避免每次 build 重投影），不建议为周课表引入；但若未来要加"月视图"，可参考其 `CalendarFormat` 切换与 `isSameDay` 日期键模式在 `ScheduleProjection` 上扩展（`buildWeek` 与月投影共用 `ScheduleQuery` 形状，schedule_projection.dart:6-62）。
6. **节次边界线去重技巧保留（具体）**：`UstcPeriods.boundaries()` 去重避免相邻无间隔节次产生重叠线（week_timetable.dart:450-464）是对表格类 UI 的通用解法，可作为周课表组件化的文档注释范式保留。

## 10. 未验证/存疑事项

**已验证**：本模块全部 25 个 presentation 文件的路径、行号、组件职责均经 Read/Grep 核验；路由映射经 router.dart 全文核验；`app/lib/features/reminders/` 无 presentation 目录经 `ls -R` 核验；golden 测试文件与 6 张 golden 图片（app/test/goldens/*.png）存在。

**未验证/存疑**：

1. **undo slot 的生产清理时机**：`UndoService.clearAtStartup()`（undo_service.dart:78）在 `app/lib` 中无生产调用点（仅两处测试调用，plan_block_undo_test.dart:569、drift_agent_write_gateway_test.dart:1766）。生产路径上 undo slot 是否在应用启动时被清理、或依赖 completeReset/消费后删除，未验证（schedule_page_test.dart:1027"notice timeout leaves the persisted undo slot intact"暗示 slot 会跨页面存留）。
2. **领域异常在 UI 层的呈现**：`StaleOverlayCommand`、`StaleTaskCommand`、`IllegalTaskTransition`、`InvalidUndoCommand`、`ConflictValidationError` 等由模块 03 服务抛出，本模块的页面回调（如 task_detail_loader.dart:171-228）未对这些异常 try/catch；其真实用户可见表现（Flutter zone 报错 or 静默失败）未运行验证。
3. **保存失败反馈缺口**：`ConflictEditor._save`（conflict_editor.dart:155-173）与 `EventPreferencesSheet._save`（event_preferences_sheet.dart:181-198）只有 try/finally、无 catch——保存失败时没有错误提示；`TaskForm._submit`（task_form.dart:169-193）同样无 catch。这是代码事实，但"失败时用户看到什么"未验证。
4. **`CalendarEventPrefill` 的现役生产调用方**：`/calendar-event/new` 路由支持 `state.extra as CalendarEventPrefill?`（router.dart:111），但 `app/lib` 中未找到任何推送非 null prefill 的调用点（仅 create 菜单无 extra 推送，router.dart:282）。prefill 目前可能只有测试在用，未验证。
5. **无账号空态的行为**：schedule_page.dart:291-305 的无账号分支（周视图渲染空投影、任务区正常）与 router 层"请先配置学校账号"分支并存，实际到达路径未运行验证。
6. **手机宽度行为**：窄窗口下 WeekTimetable 的横向拖拽检查只存在于 golden 测试（responsive_golden_test.dart:205-213），未验证其他窄宽适配点。
7. **`RadioGroup` API**（conflict_management_page.dart:140）：使用较新的 Flutter 分组单选组件，其键盘/无障碍行为未验证。
8. **测试覆盖声明**：本节引用的测试行为（schedule_page_test.dart 24 个用例、week_timetable_test.dart 10 个用例、task_ui_test.dart 7 个用例等）为静态阅读所得，本次未运行任何测试。
9. **其他模块文档编号**：03-data-storage.md 等相邻模块文档按任务约定引用，产出本文件时 docs/refactor-docs/ 目录尚不存在（本文件为首个产出），若后续编号/内容有出入以各模块文档为准。
