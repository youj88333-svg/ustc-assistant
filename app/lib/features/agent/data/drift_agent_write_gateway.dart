import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../calendar/application/calendar_event_service.dart';
import '../../calendar/application/recurrence_service.dart';
import '../../calendar/domain/personal_event.dart';
import '../../calendar/domain/recurrence_rule.dart';
import '../../reminders/application/reminder_override_service.dart';
import '../../schedule/application/effective_event_repository.dart';
import '../../schedule/application/overlay_service.dart';
import '../../tasks/application/plan_block_service.dart';
import '../../tasks/application/task_lifecycle_service.dart';
import '../../tasks/application/undo_recorder.dart';
import '../../tasks/domain/plan_block.dart';
import '../../tasks/domain/task.dart';
import '../../schedule/application/jw_day_move_service.dart';
import '../../schedule/domain/jw_day_move.dart';
import '../application/agent_permission_policy_service.dart';
import '../domain/agent_permission_policy.dart';
import '../domain/agent_write_gateway.dart';

/// 按账户构造的写网关实现：每个方法构造对应账户的现有 Service 并委托。
///
/// 使用 `NoopUndoRecorder`（Agent 写入不占用一步撤回槽）。写操作成功后由
/// `AgentWriteTool` 基类统一写 `source='agent'` 的 ActionLog，这里不重复写。
class DriftAgentWriteGateway implements AgentWriteGateway {
  DriftAgentWriteGateway({
    required this.database,
    required this.accountId,
    required this.policy,
    int Function()? now,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppDatabase database;
  final String accountId;
  final AgentPermissionPolicyService policy;
  final int Function() now;
  static const _noopUndo = NoopUndoRecorder();
  static const _uuid = Uuid();

  CalendarEventService get _events =>
      CalendarEventService(database: database, accountId: accountId, now: now, undoRecorder: _noopUndo);
  TaskLifecycleService get _tasks =>
      TaskLifecycleService(database: database, accountId: accountId, now: now, undoRecorder: _noopUndo);
  PlanBlockService get _planBlocks =>
      PlanBlockService(database: database, accountId: accountId, now: now, undoRecorder: _noopUndo);
  OverlayService get _overlays =>
      OverlayService(database: database, accountId: accountId, now: now, undoRecorder: _noopUndo);
  RecurrenceService get _recurrence =>
      RecurrenceService(database: database, accountId: accountId, now: now);
  ReminderOverrideService get _reminders =>
      ReminderOverrideService(database: database, accountId: accountId, undoRecorder: _noopUndo, now: now);
  JwDayMoveService get _dayMoves =>
      JwDayMoveService(database: database, accountId: accountId, now: now, undoRecorder: _noopUndo);

  @override
  Future<String> createEvent(PersonalEvent event, {List<int>? reminderOffsetsMinutes}) =>
      _events.create(event, reminderOffsetsMinutes: reminderOffsetsMinutes);

  @override
  Future<void> editPersonalEvent(String eventId, PersonalEvent replacement, {List<int>? reminderOffsetsMinutes}) =>
      _events.edit(eventId, replacement, reminderOffsetsMinutes: reminderOffsetsMinutes);

  @override
  Future<void> editOccurrenceOnly(String seriesId, String occurrenceKey, OccurrenceOverride override) =>
      _recurrence.editOnlyThis(seriesId, occurrenceKey, override);

  @override
  Future<SeriesEditImpact> editWholeSeries(String seriesId, {required PersonalEvent anchor}) async {
    final series = await _recurrence.seriesRow(seriesId);
    final rule = RecurrenceRule.decode(series.recurrenceJson);
    return _recurrence.editWholeSeries(seriesId, anchor: anchor, rule: rule);
  }

  @override
  Future<PersonalEvent> seriesAnchor(String seriesId) async {
    final series = await _recurrence.seriesRow(seriesId);
    if (series.allDay == true) {
      final startDate = DateTime.parse(series.anchorStartDate!);
      return PersonalEvent.allDay(
        title: series.title,
        startDate: startDate,
        endDateExclusive: startDate.add(Duration(days: series.durationDays ?? 1)),
        description: series.description,
        locationName: series.locationName,
        type: personalEventTypeFromStorage(series.eventType),
        importance: series.importance,
      );
    }
    final startAt = DateTime.fromMillisecondsSinceEpoch(series.startAt!);
    return PersonalEvent.timed(
      title: series.title,
      startAt: startAt,
      endAt: startAt.add(Duration(minutes: series.durationMinutes ?? 0)),
      description: series.description,
      locationName: series.locationName,
      type: personalEventTypeFromStorage(series.eventType),
      importance: series.importance,
    );
  }

  @override
  Future<void> cancelEvent(String eventId) => _events.cancel(eventId);

  @override
  Future<void> completeEvent(String eventId) => _events.complete(eventId);

  @override
  Future<void> skipEvent(String eventId) => _events.skip(eventId);

  @override
  Future<void> softDeleteEvent(String eventId) => _events.softDelete(eventId);

  @override
  Future<String> createTask({
    required String title,
    String? description,
    String? userNotes,
    DateTime? deadlineAt,
    int? estimatedMinutes,
    List<String> tags = const [],
    TaskImportance importance = TaskImportance.normal,
  }) => _tasks.create(
    title: title,
    description: description,
    userNotes: userNotes,
    importance: importance,
    deadlineAt: deadlineAt,
    estimatedMinutes: estimatedMinutes,
    tags: tags,
  );

  @override
  Future<void> renameTask(String id, String title, {required int expectedUpdatedAt}) =>
      _tasks.rename(id, title, expectedUpdatedAt: expectedUpdatedAt);

  @override
  Future<void> completeTask(String id, {required int expectedUpdatedAt}) =>
      _tasks.complete(id, expectedUpdatedAt: expectedUpdatedAt);

  @override
  Future<void> cancelTask(String id, {required int expectedUpdatedAt}) =>
      _tasks.cancel(id, expectedUpdatedAt: expectedUpdatedAt);

  @override
  Future<void> softDeleteTask(String id, {required int expectedUpdatedAt}) =>
      _tasks.softDelete(id, expectedUpdatedAt: expectedUpdatedAt);

  @override
  Future<String> planTask({
    required String taskId,
    required DateTime startAt,
    required DateTime endAt,
    String? title,
    PlanBlockStatus status = PlanBlockStatus.accepted,
  }) => _planBlocks.create(taskId: taskId, startAt: startAt, endAt: endAt, title: title, status: status);

  @override
  Future<void> setEventOverlay(String eventId, OverlayMutation mutation) =>
      _overlays.setEventOverlay(eventId, mutation);

  @override
  Future<void> setSeriesOverlay(String seriesId, OverlayMutation mutation) =>
      _overlays.setSeriesOverlay(seriesId, mutation);

  @override
  Future<void> recordAttendanceDecision(String eventId, AttendanceDecision decision) =>
      _overlays.recordAttendanceDecision(eventId, decision);

  @override
  Future<void> recordListeningMode(String eventId, ListeningMode mode, {String? note}) =>
      _overlays.setEventOverlay(eventId, OverlayMutation(listeningMode: mode, listeningNote: note));

  @override
  Future<void> createConflictRelation({
    required String leftKind,
    required String leftId,
    required String rightKind,
    required String rightId,
    required String conflictState,
    String? reason,
  }) async {
    final timestamp = now();
    final existing = await (database.select(database.scheduleRelations)
          ..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.leftKind.equals(leftKind) &
                row.leftId.equals(leftId) &
                row.rightKind.equals(rightKind) &
                row.rightId.equals(rightId),
          ))
        .getSingleOrNull();
    final id = existing?.id ?? _uuid.v4();
    await database.into(database.scheduleRelations).insertOnConflictUpdate(
      ScheduleRelationsCompanion.insert(
        id: id,
        accountId: accountId,
        relationType: const Value('conflict'),
        leftKind: Value(leftKind),
        leftId: Value(leftId),
        rightKind: Value(rightKind),
        rightId: Value(rightId),
        leftEventId: Value(leftKind == 'event' ? leftId : null),
        leftPlanBlockId: Value(leftKind == 'plan_block' ? leftId : null),
        rightEventId: Value(rightKind == 'event' ? rightId : null),
        rightPlanBlockId: Value(rightKind == 'plan_block' ? rightId : null),
        conflictState: Value(conflictState),
        reason: Value(reason),
        createdAt: existing?.createdAt ?? timestamp,
        updatedAt: timestamp,
      ),
    );
    // 不在此写 ActionLog：`AgentWriteTool` 基类在写成功后统一写
    // source='agent' 的日志（见类注释），这里不再重复。
  }

  @override
  Future<void> setReminder(String eventId, List<int> offsetsMinutes) =>
      _reminders.setEventOffsets(eventId, offsetsMinutes);

  @override
  Future<EventWriteSnapshot> eventSnapshot(String eventId) async {
    final row = await (database.select(database.calendarEvents)
          ..where((r) => r.id.equals(eventId) & r.accountId.equals(accountId)))
        .getSingleOrNull();
    if (row == null) throw StateError('event not found for account');
    // 仅对课程系列身份使用 EffectiveEventRepository；其余字段直接来自账户
    // 过滤后的 calendar_events 行。DB id 只进 commitParams。
    String? courseSeriesId;
    if (row.sourceSeriesExternalId != null) {
      final record = await EffectiveEventRepository(
        database,
        accountId: accountId,
      ).byId(eventId);
      courseSeriesId = record.courseSeries?.id;
    }
    return EventWriteSnapshot(
      id: row.id,
      source: row.source,
      type: row.type,
      title: row.title,
      allDay: row.allDay,
      startAt: row.startAt == null ? null : _beijingDateTime(row.startAt!),
      endAt: row.endAt == null ? null : _beijingDateTime(row.endAt!),
      startDate: row.startDate == null ? null : DateTime.parse(row.startDate!),
      endDateExclusive: row.endDateExclusive == null ? null : DateTime.parse(row.endDateExclusive!),
      location: row.locationName,
      personalSeriesId: row.personalSeriesId,
      occurrenceKey: row.occurrenceKey,
      courseSeriesId: courseSeriesId,
    );
  }

  @override
  Future<PersonalEvent> personalEvent(String eventId) => _events.byId(eventId);

  @override
  Future<String?> courseSeriesIdForEvent(String eventId) async {
    final record = await EffectiveEventRepository(
      database,
      accountId: accountId,
    ).byId(eventId);
    return record.courseSeries?.id;
  }

  @override
  Future<TaskItem> taskById(String taskId) => _tasks.byId(taskId);

  @override
  Future<PlanBlockItem> planBlockById(String planBlockId) => _planBlocks.byId(planBlockId);

  @override
  Future<void> updatePermissionPolicy({
    required String actionType,
    required String targetType,
    required ConfirmationMode mode,
    required RiskLevel riskLevel,
    required bool enabled,
    required String updatedBy,
  }) => policy.updatePolicy(
    accountId: accountId,
    actionType: actionType,
    targetType: targetType,
    mode: mode,
    riskLevel: riskLevel,
    enabled: enabled,
    updatedBy: updatedBy,
  );

  @override
  Future<JwDayMovePreview> jwDayMovePreview(String sourceDate) =>
      _dayMoves.preview(sourceDate);

  @override
  Future<bool> jwDayMove(String sourceDate, String targetDate) async {
    // 数据层唯一允许的表级预读：判定本次移动是新建还是重定向（仅影响返回的
    // 结果值）。真正的资格/目标校验都在 JwDayMoveService.move 的事务内完成。
    final existing = await (database.select(database.jwDayMoves)
          ..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.sourceDate.equals(sourceDate),
          ))
        .getSingleOrNull();
    await _dayMoves.move(sourceDate, targetDate);
    return existing != null;
  }

  @override
  Future<void> jwDayMoveClear(String sourceDate) => _dayMoves.clear(sourceDate);

  /// 与 Schedule 层 `EffectiveEventRepository._beijingDateTime` 一致：把存储的
  /// UTC epoch-ms 还原为北京墙钟时间（isUtc:true + 8h），避免确认预览显示 UTC。
  DateTime _beijingDateTime(int millisecondsSinceEpoch) {
    final shifted = DateTime.fromMillisecondsSinceEpoch(
      millisecondsSinceEpoch,
      isUtc: true,
    ).add(const Duration(hours: 8));
    return DateTime(
      shifted.year,
      shifted.month,
      shifted.day,
      shifted.hour,
      shifted.minute,
      shifted.second,
      shifted.millisecond,
      shifted.microsecond,
    );
  }
}
