import '../../calendar/application/recurrence_lifecycle_service.dart';
import '../../calendar/application/recurrence_service.dart';
import '../../calendar/domain/personal_event.dart';
import '../../calendar/domain/recurrence_rule.dart';
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
  Future<void> cancelEvent(String eventId);
  Future<void> completeEvent(String eventId);
  Future<void> skipEvent(String eventId);
  Future<void> softDeleteEvent(String eventId);
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
  Future<void> recurringLifecycle(
    String seriesId, {
    required String? occurrenceKey,
    required RecurringActionScope scope,
    required RecurringLifecycleAction action,
  });

  Future<String?> courseSeriesIdForEvent(String eventId);
  Future<TaskItem> taskById(String taskId);
  Future<PlanBlockItem> planBlockById(String planBlockId);
  Future<void> updatePermissionPolicy({required String actionType, required String targetType, required ConfirmationMode mode, required RiskLevel riskLevel, required bool enabled, required String updatedBy});

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
