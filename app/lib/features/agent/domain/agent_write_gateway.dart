import '../../calendar/application/recurrence_service.dart';
import '../../calendar/domain/personal_event.dart';
import '../../schedule/application/effective_event_repository.dart';
import '../../schedule/application/overlay_service.dart';
import '../../tasks/domain/plan_block.dart';
import '../../tasks/domain/task.dart';
import 'agent_permission_policy.dart';

/// 一个事件的写身份（是否个人、是否重复系列、occurrence 位置）。
class EventWriteIdentity {
  const EventWriteIdentity({
    required this.id,
    required this.source,
    required this.type,
    this.personalSeriesId,
    this.occurrenceKey,
  });

  final String id;
  final String source;
  final String type;
  final String? personalSeriesId;
  final String? occurrenceKey;

  bool get isPersonal => source == 'user';
  bool get isRecurring => personalSeriesId != null && occurrenceKey != null;
}

/// 本地写网关：纯写方法，包装现有 Application Service。
///
/// 不含确认/策略逻辑（那是 `AgentWriteTool` 基类的事）；实现按账户构造
/// （类似 `CalendarEventService`），不接收 `accountId` 参数。
abstract interface class AgentWriteGateway {
  Future<String> createEvent(PersonalEvent event, {List<int>? reminderOffsetsMinutes});
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
  Future<EventWriteIdentity> eventIdentity(String eventId);
  Future<PersonalEvent> personalEvent(String eventId);
  Future<String?> courseSeriesIdForEvent(String eventId);
  Future<TaskItem> taskById(String taskId);
  Future<PlanBlockItem> planBlockById(String planBlockId);
  Future<void> updatePermissionPolicy({required String actionType, required String targetType, required ConfirmationMode mode, required RiskLevel riskLevel, required bool enabled, required String updatedBy});
}
