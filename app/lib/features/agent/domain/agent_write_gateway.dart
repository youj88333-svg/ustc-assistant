import '../../calendar/application/recurrence_lifecycle_service.dart';
import '../../calendar/application/recurrence_service.dart';
import '../../calendar/domain/personal_event.dart';
import '../../calendar/domain/recurrence_rule.dart';
import '../../reminders/application/reminder_override_service.dart';
import '../../schedule/application/effective_event_repository.dart';
import '../../schedule/application/overlay_service.dart';
import '../../schedule/domain/jw_day_move.dart';
import '../../tasks/domain/plan_block.dart';
import '../../tasks/domain/task.dart';
import 'agent_permission_policy.dart';

/// 一个事件在提案/确认阶段的不可变快照：身份 + 面向用户展示的
/// title/时间/地点。DB 行 id 只进入 [commitParams]，永不进入预览/日志文本。
final class EventWriteSnapshot {
  const EventWriteSnapshot({
    required this.id,
    required this.source,
    required this.type,
    required this.title,
    required this.allDay,
    this.startAt,
    this.endAt,
    this.startDate,
    this.endDateExclusive,
    this.location,
    this.personalSeriesId,
    this.occurrenceKey,
    this.courseSeriesId,
    this.updatedAt,
    this.exceptionUpdatedAt,
  });

  final String id;
  final String source;
  final String type;
  final String title;
  final bool allDay;
  final DateTime? startAt;
  final DateTime? endAt;
  final DateTime? startDate;
  final DateTime? endDateExclusive;
  final String? location;
  final String? personalSeriesId;
  final String? occurrenceKey;
  final String? courseSeriesId;

  /// The row's `updatedAt` at propose time. Single-event lifecycle commits
  /// plumb this through as `expectedUpdatedAt` so the service can TOCTOU
  /// re-check the version between propose and confirm (Spec §25.1). For a
  /// recurring occurrence the single-event lifecycle isn't used (the
  /// recurringLifecycle path carries `expectedSeriesUpdatedAt` instead), so
  /// this is null on occurrence/series snapshots.
  final int? updatedAt;

  /// The occurrence-exception row's `updatedAt` at propose time, for a
  /// recurring occurrence that already has an exception override anchor.
  /// `only_this`/`this_and_future` lifecycle commits plumb this through as
  /// `expectedExceptionUpdatedAt` so the service can TOCTOU re-check the
  /// specific occurrence's override row between propose and confirm (Spec
  /// §25.1) — a concurrent edit to that one occurrence would otherwise be
  /// silently overwritten. Null for a stored-event snapshot (no exception
  /// row) and for a recurring occurrence/series with no existing exception
  /// anchor.
  final int? exceptionUpdatedAt;

  bool get isPersonal => source == 'user';
  bool get isRecurring => personalSeriesId != null && occurrenceKey != null;
}

/// 本地写网关：纯写方法，包装现有 Application Service。
///
/// 不含确认/策略逻辑（那是 `AgentWriteTool` 基类的事）；实现按账户构造
/// （类似 `CalendarEventService`），不接收 `accountId` 参数。
abstract interface class AgentWriteGateway {
  Future<String> createEvent(PersonalEvent event, {List<int>? reminderOffsetsMinutes});

  /// 创建重复个人日程系列：以 [anchor] 为锚点、[rule] 为规则，委托
  /// [RecurrenceService.createSeries]。返回新系列 id（仅 commit 内使用，绝不
  /// 进入预览/日志）。
  Future<String> createRecurringEvent(PersonalEvent anchor, RecurrenceRule rule, {List<int>? reminderOffsetsMinutes});
  Future<void> editPersonalEvent(String eventId, PersonalEvent replacement, {List<int>? reminderOffsetsMinutes});
  Future<void> editOccurrenceOnly(String seriesId, String occurrenceKey, OccurrenceOverride override);
  Future<SeriesEditImpact> editWholeSeries(String seriesId, {required PersonalEvent anchor});
  Future<PersonalEvent> seriesAnchor(String seriesId);
  Future<void> cancelEvent(String eventId, {int? expectedUpdatedAt});
  Future<void> completeEvent(String eventId, {int? expectedUpdatedAt});
  Future<void> skipEvent(String eventId, {int? expectedUpdatedAt});
  Future<void> softDeleteEvent(String eventId, {int? expectedUpdatedAt});
  Future<String> createTask({required String title, String? description, String? userNotes, DateTime? deadlineAt, int? estimatedMinutes, List<String> tags, TaskImportance importance});
  Future<void> renameTask(String id, String title, {required int expectedUpdatedAt});
  Future<void> completeTask(String id, {required int expectedUpdatedAt});
  Future<void> cancelTask(String id, {required int expectedUpdatedAt});
  Future<void> softDeleteTask(String id, {required int expectedUpdatedAt});
  Future<String> planTask({required String taskId, required DateTime startAt, required DateTime endAt, String? title, PlanBlockStatus status});
  Future<void> setEventOverlay(String eventId, OverlayMutation mutation);
  Future<void> setSeriesOverlay(String seriesId, OverlayMutation mutation);
  Future<void> recordAttendanceDecision(String eventId, AttendanceDecision decision);
  Future<void> recordListeningMode(String eventId, ListeningMode mode, {String? note});
  Future<void> createConflictRelation({required String leftKind, required String leftId, required String rightKind, required String rightId, required String conflictState, String? reason});
  Future<void> setReminder(String eventId, List<int> offsetsMinutes);
  Future<EventWriteSnapshot> eventSnapshot(String eventId);
  Future<PersonalEvent> personalEvent(String eventId);

  /// Locator-aware event-identity snapshot for the write preflight. Decodes
  /// [locator] (`event_v1` / `occ_v1` / `series_v1`) and returns the write
  /// snapshot without any database change:
  /// - stored event → the stored row's snapshot;
  /// - recurring occurrence → the composed (override-aware) occurrence;
  /// - recurring series → the whole-series identity (occurrenceKey null).
  ///
  /// Malformed / unknown locators throw deterministically (FormatException for
  /// a malformed locator, an account-scoped not-found for a missing target) so
  /// the caller can map to `reference_not_found` / `occurrence_not_found`.
  Future<EventWriteSnapshot> eventSnapshotByLocator(String locator);

  /// Locator-aware [PersonalEvent] load for the write preflight. Same
  /// resolution as [eventSnapshotByLocator]; series locators return the
  /// whole-series anchor as a [PersonalEvent].
  Future<PersonalEvent> personalEventByLocator(String locator);
  /// The scoped lifecycle preview for a repeating occurrence/series, used by
  /// the write preflight to decide whether `scope_required` must be returned.
  /// [occurrenceKey] is null for a whole-series target. Account-scoped.
  Future<RecurringImpactPreview> recurringLifecycleImpactPreview(
    String seriesId, {
    String? occurrenceKey,
    RecurringActionScope? scope,
    RecurringLifecycleAction? action,
  });

  /// Applies a scoped lifecycle action to a repeating occurrence or the whole
  /// series ([RecurringActionScope.wholeSeries] when [occurrenceKey] is null).
  /// Agent writes suppress the per-action Undo slot (the outer unit-of-work
  /// owns the undo slot), so the implementation uses a Noop undo recorder.
  ///
  /// [expectedSeriesUpdatedAt]/[expectedExceptionUpdatedAt] carry the
  /// propose-time versions for a TOCTOU re-check (Spec §25.1); null skips the
  /// check (back-compat with no-arg callers).
  Future<void> recurringLifecycle(
    String seriesId, {
    required String? occurrenceKey,
    required RecurringActionScope scope,
    required RecurringLifecycleAction action,
    int? expectedSeriesUpdatedAt,
    int? expectedExceptionUpdatedAt,
  });

  Future<String?> courseSeriesIdForEvent(String eventId);
  Future<TaskItem> taskById(String taskId);

  /// Deleted-inclusive task lookup for restore proposes. `taskById` filters
  /// soft-deleted rows (so a restore propose on a soft-deleted target would
  /// die with `TaskNotFoundError` before the proposal could form); this
  /// variant reads the soft-deleted row so `UpdateTaskTool.propose` can form a
  /// restore proposal. The commit still re-checks `expectedUpdatedAt` +
  /// not-deleted state via `TaskLifecycleService.restore`. Account-scoped;
  /// a foreign/missing id throws `TaskNotFoundError` like `taskById`.
  Future<TaskItem> taskByIdIncludeDeleted(String taskId);

  Future<PlanBlockItem> planBlockById(String planBlockId);

  /// Deleted-inclusive plan-block lookup for restore proposes — the
  /// `planBlockById` analogue. See [taskByIdIncludeDeleted]. Account-scoped;
  /// a foreign/missing id throws `PlanBlockNotFoundError`.
  Future<PlanBlockItem> planBlockByIdIncludeDeleted(String planBlockId);

  Future<void> updatePermissionPolicy({required String actionType, required String targetType, required ConfirmationMode mode, required RiskLevel riskLevel, required bool enabled, required String updatedBy});

  // ---- Task lifecycle (complete/cancel exist above; reopen/restore added) ----
  Future<void> reopenTask(String id, {required int expectedUpdatedAt});
  Future<void> restoreTask(String id, {required int expectedUpdatedAt});

  // ---- PlanBlock lifecycle (done/skip/cancel/delete/restore) ----
  Future<void> markPlanBlockDone(String id, {required int expectedUpdatedAt, String? note});
  Future<void> markPlanBlockSkipped(String id, {required int expectedUpdatedAt, String? note});
  Future<void> cancelPlanBlock(String id, {required int expectedUpdatedAt});
  Future<void> softDeletePlanBlock(String id, {required int expectedUpdatedAt});
  Future<void> restorePlanBlock(String id, {required int expectedUpdatedAt});

  // ---- Event lifecycle (complete/skip/cancel/softDelete exist; reopen/restore) ----
  Future<void> reopenEvent(String eventId, {int? expectedUpdatedAt});
  Future<void> restoreEvent(String eventId, {int? expectedUpdatedAt});

  // ---- Reminder clear (Task 7 generalized ReminderOverrideService) ----
  /// Clears future `desired` reminders for the target. [targetType] is
  /// `event`/`task`/`plan_block`. `all` scope ignores [offsets];
  /// `selected_offsets` requires non-empty offsets, every one of which must
  /// already be a future desired offset (atomic fail on mismatch).
  ///
  /// I2: [expectedTargetUpdatedAt] / [expectedOffsetsSnapshot] carry the
  /// propose-time target version and desired-offset set for a TOCTOU re-check
  /// (Spec §20); a mismatch throws `StaleReminderTargetCommand` (maps to
  /// `stale_target`). null skips the check (back-compat).
  Future<void> clearReminders({
    required String targetType,
    required String targetId,
    required String scope, // all | selected_offsets
    List<int>? offsets,
    int? expectedTargetUpdatedAt,
    List<int>? expectedOffsetsSnapshot,
  });

  /// Reads the target's current reminder configuration (future desired
  /// offsets, explicit-disable flag, history counts) for the propose-time
  /// snapshot. Account-scoped, read-only, no Reminder DB id.
  Future<ReminderConfiguration> reminderConfiguration({
    required String targetType,
    required String targetId,
  });

  // ---- Overlay clear (Task 7 tri-state OverlayService.clearOverlayFields) ----
  /// Clears the listed overlay fields for the event's single-event layer
  /// ([eventId] non-null) or its course-series layer ([courseSeriesId]
  /// non-null). Exactly one target must be set. Fields may include group
  /// keys (`attendance`/`listening`/`display`/`appearance`/`all`); an
  /// unknown key aborts atomically before any write.
  ///
  /// I2: [expectedOverlayUpdatedAt] carries the propose-time overlay row
  /// version for a TOCTOU re-check (Spec §20); a mismatch throws
  /// `StaleOverlayCommand` (maps to `stale_target`). null skips the check.
  Future<void> clearOverlayFields({
    String? eventId,
    String? courseSeriesId,
    required List<String> fields,
    int? expectedOverlayUpdatedAt,
  });

  /// Reads the overlay row's `updatedAt` and currently-set field values for
  /// the propose-time snapshot. Exactly one of [eventId] / [courseSeriesId]
  /// must be set. Returns `(updatedAt: null, fieldValues: {})` when no
  /// overlay row exists (target at pure defaults). Account-scoped, read-only.
  Future<({int? updatedAt, Map<String, Object?> fieldValues})>
      overlayRowSnapshot({
    String? eventId,
    String? courseSeriesId,
  });

  // ---- Schedule relation / rule deletion (Task 8) ----
  /// Deletes a single user-authored conflict relation row. Missing/foreign
  /// id throws [ConflictRelationNotFoundError]; a non-user/non-conflict row
  /// (exam_for_course / derived_overlap) throws [ConflictNotDeletableError].
  Future<void> deleteConflictRelation(String relationId);
  /// Deletes a user series conflict rule. Missing/foreign id throws
  /// [ConflictRelationNotFoundError].
  Future<void> deleteConflictRule(String ruleId);
  /// 366-day removal-impact preview for a series rule (affected day count,
  /// over-366/infinite flags). Missing/foreign id throws
  /// [ConflictRelationNotFoundError].
  Future<({int affectedDays, bool over366Days, bool infinite})>
      conflictRuleRemovalImpact(String ruleId);

  // ---- TaskEventLink unlink (Task 8) ----
  /// Removes the unique `(account, task, event)` `related` link. Foreign /
  /// missing / deleted target throws [TaskEventLinkTargetNotFoundError]; a
  /// missing link throws [TaskEventLinkNotFoundError].
  Future<void> unlinkTaskEvent({
    required String taskId,
    required String eventId,
    int? expectedTaskUpdatedAt,
    int? expectedEventUpdatedAt,
  });

  // ---- Permission policy reset (Task 8) ----
  /// Removes the `(account, actionType, targetType)` override row, restoring
  /// the lazy default. Returns true when a row was removed, false when no
  /// override existed (already_default — no write). A non-resettable action
  /// (kNonResetableActions) throws [StateError].
  Future<bool> resetPermissionPolicy({
    required String actionType,
    required String targetType,
  });

  // ---- One-step undo (UndoService) ----
  /// Reverses the account's most recent undoable action and clears the slot.
  /// A missing/foreign/malformed slot throws [InvalidUndoCommand].
  Future<void> undoLastAction();

  /// Account-safe preview of the most recent undoable action (availability,
  /// safe summary, action kind, Beijing timestamp). Never mutates the slot;
  /// a missing or foreign-account slot reports `available: false`.
  Future<({bool available, String summary, String kind, String beijingAt})>
      undoPreview();

  /// 整日教务课程移动预览：返回符合条件课程的标题（永不含 id）与已有目标日期。
  /// 由 `JwDayMoveService.preview` 支撑；工具本身不触表。
  Future<JwDayMovePreview> jwDayMovePreview(String sourceDate);

  /// 把 [sourceDate] 的教务课程整体移到 [targetDate]。返回 true 表示该源日期
  /// 已有移动记录（本次为重定向），false 表示新建。无符合条件的课程时抛
  /// [NoEligibleJwCourses]，源目标同日期抛 [InvalidDayMoveDates]。
  Future<bool> jwDayMove(String sourceDate, String targetDate);

  /// 清除 [sourceDate] 的整日移动记录，恢复原日期。无记录时抛 [MissingJwDayMove]。
  Future<void> jwDayMoveClear(String sourceDate);
}
