import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../calendar/application/calendar_event_service.dart';
import '../../calendar/application/recurrence_lifecycle_service.dart';
import '../../calendar/application/recurrence_service.dart';
import '../../calendar/domain/calendar_event_locator.dart';
import '../../calendar/domain/personal_event.dart';
import '../../calendar/domain/recurrence_rule.dart';
import '../../reminders/application/reminder_override_service.dart';
import '../../schedule/application/conflict_service.dart';
import '../../schedule/application/effective_event_repository.dart';
import '../../schedule/application/overlay_service.dart';
import '../../tasks/application/plan_block_service.dart';
import '../../tasks/application/task_event_link_service.dart';
import '../../tasks/application/task_lifecycle_service.dart';
import '../../tasks/application/undo_recorder.dart';
import '../../tasks/application/undo_service.dart';
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
  RecurringLifecycleService get _lifecycle => RecurringLifecycleService(
        database: database,
        accountId: accountId,
        now: now,
      );
  ReminderOverrideService get _reminders =>
      ReminderOverrideService(database: database, accountId: accountId, undoRecorder: _noopUndo, now: now);
  ConflictService get _conflicts =>
      ConflictService(database: database, accountId: accountId, now: now, undoRecorder: _noopUndo);
  TaskEventLinkService get _links => TaskEventLinkService(
        database: database,
        accountId: accountId,
        now: now,
        undoRecorder: _noopUndo,
      );
  UndoService get _undo => UndoService(database: database, accountId: accountId, now: now);
  JwDayMoveService get _dayMoves =>
      JwDayMoveService(database: database, accountId: accountId, now: now, undoRecorder: _noopUndo);

  @override
  Future<String> createEvent(PersonalEvent event, {List<int>? reminderOffsetsMinutes}) =>
      _events.create(event, reminderOffsetsMinutes: reminderOffsetsMinutes);

  @override
  Future<String> createRecurringEvent(PersonalEvent anchor, RecurrenceRule rule,
          {List<int>? reminderOffsetsMinutes}) =>
      _recurrence.createSeries(anchor: anchor, rule: rule, reminderOffsetsMinutes: reminderOffsetsMinutes);

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
    // Canonicalize by `kind:id` so a reverse insertion lands on the same row.
    final (lKind, lId, rKind, rId) =
        _canonicalRelationPair(leftKind, leftId, rightKind, rightId);
    // Resolve the backing event FK for each event-kind endpoint: a recurring
    // occurrence locator routes through ensureOccurrenceAnchor (creating or
    // reusing one no-op exception anchor) to the occurrence-exception FK; a
    // plain stored event id populates the event FK. Plan-block endpoints keep
    // their plan block FK. Generated anchors only ever appear inside this
    // approved Agent write (the outer unit-of-work transaction).
    final (leftEventId, leftOccurrenceExceptionId) = await _eventBacking(lKind, lId);
    final (rightEventId, rightOccurrenceExceptionId) = await _eventBacking(rKind, rId);
    final timestamp = now();
    final existing = await (database.select(database.scheduleRelations)
          ..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.leftKind.equals(lKind) &
                row.leftId.equals(lId) &
                row.rightKind.equals(rKind) &
                row.rightId.equals(rId),
          ))
        .getSingleOrNull();
    final id = existing?.id ?? _uuid.v4();
    await database.into(database.scheduleRelations).insertOnConflictUpdate(
      ScheduleRelationsCompanion.insert(
        id: id,
        accountId: accountId,
        relationType: const Value('conflict'),
        leftKind: Value(lKind),
        leftId: Value(lId),
        rightKind: Value(rKind),
        rightId: Value(rId),
        leftEventId: Value(leftEventId),
        leftPlanBlockId: Value(lKind == 'plan_block' ? lId : null),
        leftOccurrenceExceptionId: Value(leftOccurrenceExceptionId),
        rightEventId: Value(rightEventId),
        rightPlanBlockId: Value(rKind == 'plan_block' ? rId : null),
        rightOccurrenceExceptionId: Value(rightOccurrenceExceptionId),
        conflictState: Value(conflictState),
        reason: Value(reason),
        createdAt: existing?.createdAt ?? timestamp,
        updatedAt: timestamp,
      ),
    );
    // 不在此写 ActionLog：`AgentWriteTool` 基类在写成功后统一写
    // source='agent' 的日志（见类注释），这里不再重复。
  }

  /// Resolves an event-kind endpoint's backing FK columns. A recurring
  /// occurrence locator maps to its no-op occurrence-exception anchor (created
  /// or reused inside this approved write); a plain stored event id maps to the
  /// event FK. Plan-block / null endpoints keep both event columns null.
  Future<(String?, String?)> _eventBacking(String kind, String id) async {
    if (kind != 'event') return (null, null);
    final decoded = _tryDecodeLocator(id);
    if (decoded is RecurringOccurrenceLocator) {
      final anchor = await _recurrence.ensureOccurrenceAnchor(
        decoded.seriesId,
        decoded.occurrenceKey,
      );
      return (null, anchor.id);
    }
    return (id, null);
  }

  (String, String, String, String) _canonicalRelationPair(
    String leftKind,
    String leftId,
    String rightKind,
    String rightId,
  ) {
    final leftKey = '$leftKind:$leftId';
    final rightKey = '$rightKind:$rightId';
    return leftKey.compareTo(rightKey) <= 0
        ? (leftKind, leftId, rightKind, rightId)
        : (rightKind, rightId, leftKind, leftId);
  }

  @override
  Future<void> setReminder(String eventId, List<int> offsetsMinutes) =>
      _reminders.setEventOffsets(eventId, offsetsMinutes);

  @override
  Future<EventWriteSnapshot> eventSnapshot(String eventId) async {
    // A locator id (from the recurring display path or a management ref)
    // routes to the locator-aware resolution; a plain stored event id follows
    // the stored-row path below.
    final locator = _tryDecodeLocator(eventId);
    if (locator != null) {
      return eventSnapshotByLocator(eventId);
    }
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
  Future<PersonalEvent> personalEvent(String eventId) {
    final locator = _tryDecodeLocator(eventId);
    if (locator != null) {
      return personalEventByLocator(eventId);
    }
    return _events.byId(eventId);
  }

  @override
  Future<EventWriteSnapshot> eventSnapshotByLocator(String locator) async {
    final decoded = decodeCalendarEventLocator(locator);
    switch (decoded) {
      case StoredEventLocator(:final eventId):
        return eventSnapshot(eventId);
      case RecurringOccurrenceLocator(:final seriesId, :final occurrenceKey):
        // Deterministic `occurrence_not_found`: a missing series or a non-
        // contained occurrence both surface as OccurrenceNotFoundError.
        if (await _recurrence.seriesRowOrNull(seriesId) == null) {
          throw const OccurrenceNotFoundError();
        }
        final occurrence = await _recurrence.occurrence(
          seriesId,
          occurrenceKey,
        );
        return _snapshotFromOccurrence(occurrence);
      case RecurringSeriesLocator(:final seriesId):
        final series = await _recurrence.seriesRow(seriesId);
        return _snapshotFromSeries(series);
    }
  }

  @override
  Future<PersonalEvent> personalEventByLocator(String locator) async {
    final decoded = decodeCalendarEventLocator(locator);
    switch (decoded) {
      case StoredEventLocator(:final eventId):
        return personalEvent(eventId);
      case RecurringOccurrenceLocator(:final seriesId, :final occurrenceKey):
        if (await _recurrence.seriesRowOrNull(seriesId) == null) {
          throw const OccurrenceNotFoundError();
        }
        final occurrence = await _recurrence.occurrence(
          seriesId,
          occurrenceKey,
        );
        return _personalEventFromOccurrence(occurrence);
      case RecurringSeriesLocator(:final seriesId):
        return seriesAnchor(seriesId);
    }
  }

  /// Builds an [EventWriteSnapshot] from a composed recurring occurrence. Only
  /// safe display fields are forwarded; the series id / occurrence key live
  /// behind the id (the encoded occurrence locator).
  EventWriteSnapshot _snapshotFromOccurrence(RecurringOccurrence occurrence) {
    final id = encodeCalendarEventLocator(
      RecurringOccurrenceLocator(
        seriesId: occurrence.seriesId,
        occurrenceKey: occurrence.occurrenceKey,
      ),
    );
    return EventWriteSnapshot(
      id: id,
      source: 'user',
      type: 'personal',
      title: occurrence.title,
      allDay: occurrence.allDay,
      startAt: occurrence.allDay ? null : occurrence.startAt,
      endAt: occurrence.allDay ? null : occurrence.endAt,
      startDate: occurrence.allDay ? occurrence.startDate : null,
      endDateExclusive: occurrence.allDay ? occurrence.endDateExclusive : null,
      location: occurrence.locationName,
      personalSeriesId: occurrence.seriesId,
      occurrenceKey: occurrence.occurrenceKey,
    );
  }

  /// Builds an [EventWriteSnapshot] from a whole-series row. `occurrenceKey` is
  /// null (whole-series preflight only); the id is the encoded series locator.
  EventWriteSnapshot _snapshotFromSeries(CalendarEventSery series) {
    final id = encodeCalendarEventLocator(
      RecurringSeriesLocator(seriesId: series.id),
    );
    return EventWriteSnapshot(
      id: id,
      source: 'user',
      type: 'personal',
      title: series.title,
      allDay: series.allDay,
      startAt: series.startAt == null ? null : _beijingDateTime(series.startAt!),
      startDate: series.anchorStartDate == null
          ? null
          : DateTime.parse(series.anchorStartDate!),
      endDateExclusive: (series.allDay == true &&
              series.anchorStartDate != null)
          ? DateTime.parse(series.anchorStartDate!)
              .add(Duration(days: series.durationDays ?? 1))
          : null,
      location: series.locationName,
      personalSeriesId: series.id,
      occurrenceKey: null,
    );
  }

  PersonalEvent _personalEventFromOccurrence(RecurringOccurrence occurrence) {
    if (occurrence.allDay) {
      return PersonalEvent.allDay(
        title: occurrence.title,
        startDate: occurrence.startDate!,
        endDateExclusive: occurrence.endDateExclusive!,
        description: occurrence.description,
        locationName: occurrence.locationName,
        type: personalEventTypeFromStorage('personal'),
        status: occurrence.status,
        completionPolicy: occurrence.completionPolicy,
        importance: occurrence.importance,
      );
    }
    return PersonalEvent.timed(
      title: occurrence.title,
      startAt: occurrence.startAt!,
      endAt: occurrence.endAt!,
      description: occurrence.description,
      locationName: occurrence.locationName,
      type: personalEventTypeFromStorage('personal'),
      status: occurrence.status,
      completionPolicy: occurrence.completionPolicy,
      importance: occurrence.importance,
    );
  }

  /// Decodes [id] when it is a well-formed locator; returns null for a plain
  /// stored event id (which never parses as a locator).
  CalendarEventLocator? _tryDecodeLocator(String id) {
    if (!id.startsWith('event_v1.') &&
        !id.startsWith('occ_v1.') &&
        !id.startsWith('series_v1.')) {
      return null;
    }
    try {
      return decodeCalendarEventLocator(id);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<RecurringImpactPreview> recurringLifecycleImpactPreview(
    String seriesId, {
    String? occurrenceKey,
    RecurringActionScope? scope,
    RecurringLifecycleAction? action,
  }) => _lifecycle.previewImpact(
    seriesId: seriesId,
    occurrenceKey: occurrenceKey,
    scope: scope,
    action: action,
  );

  @override
  Future<void> recurringLifecycle(
    String seriesId, {
    required String? occurrenceKey,
    required RecurringActionScope scope,
    required RecurringLifecycleAction action,
  }) {
    if (occurrenceKey == null) {
      switch (action) {
        case RecurringLifecycleAction.cancel:
          return _lifecycle.cancelSeries(seriesId);
        case RecurringLifecycleAction.delete:
          return _lifecycle.deleteSeries(seriesId);
        case RecurringLifecycleAction.reopen:
          return _lifecycle.reopenSeries(seriesId);
        case RecurringLifecycleAction.restore:
          return _lifecycle.restoreSeries(seriesId);
      }
    }
    final key = occurrenceKey;
    switch (action) {
      case RecurringLifecycleAction.cancel:
        return _lifecycle.cancel(
          seriesId: seriesId,
          occurrenceKey: key,
          scope: scope,
        );
      case RecurringLifecycleAction.delete:
        return _lifecycle.delete(
          seriesId: seriesId,
          occurrenceKey: key,
          scope: scope,
        );
      case RecurringLifecycleAction.reopen:
        return _lifecycle.reopen(
          seriesId: seriesId,
          occurrenceKey: key,
          scope: scope,
        );
      case RecurringLifecycleAction.restore:
        return _lifecycle.restore(
          seriesId: seriesId,
          occurrenceKey: key,
          scope: scope,
        );
    }
  }

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
  Future<void> reopenTask(String id, {required int expectedUpdatedAt}) =>
      _tasks.reopen(id, expectedUpdatedAt: expectedUpdatedAt);

  @override
  Future<void> restoreTask(String id, {required int expectedUpdatedAt}) =>
      _tasks.restore(id, expectedUpdatedAt: expectedUpdatedAt);

  @override
  Future<void> markPlanBlockDone(String id, {required int expectedUpdatedAt, String? note}) =>
      _planBlocks.markDone(id, expectedUpdatedAt: expectedUpdatedAt, note: note);

  @override
  Future<void> markPlanBlockSkipped(String id, {required int expectedUpdatedAt, String? note}) =>
      _planBlocks.markSkipped(id, expectedUpdatedAt: expectedUpdatedAt, note: note);

  @override
  Future<void> cancelPlanBlock(String id, {required int expectedUpdatedAt}) =>
      _planBlocks.cancel(id, expectedUpdatedAt: expectedUpdatedAt);

  @override
  Future<void> softDeletePlanBlock(String id, {required int expectedUpdatedAt}) =>
      _planBlocks.softDelete(id, expectedUpdatedAt: expectedUpdatedAt);

  @override
  Future<void> restorePlanBlock(String id, {required int expectedUpdatedAt}) =>
      _planBlocks.restore(id, expectedUpdatedAt: expectedUpdatedAt);

  @override
  Future<void> reopenEvent(String eventId) => _events.reopen(eventId);

  @override
  Future<void> restoreEvent(String eventId) => _events.restore(eventId);

  @override
  Future<void> clearReminders({
    required String targetType,
    required String targetId,
    required String scope,
    List<int>? offsets,
  }) {
    final clearScope = scope == 'all'
        ? ReminderClearScope.all
        : ReminderClearScope.selectedOffsets;
    return _reminders.clearReminders(
      targetType: targetType,
      targetId: targetId,
      scope: clearScope,
      offsets: offsets,
    );
  }

  @override
  Future<void> clearOverlayFields({
    String? eventId,
    String? courseSeriesId,
    required List<String> fields,
  }) =>
      _overlays.clearOverlayFields(
        eventId: eventId,
        courseSeriesId: courseSeriesId,
        fields: fields,
      );

  @override
  Future<void> deleteConflictRelation(String relationId) =>
      _conflicts.deleteConflictRelation(relationId);

  @override
  Future<void> deleteConflictRule(String ruleId) =>
      _conflicts.deleteConflictRule(ruleId);

  @override
  Future<({int affectedDays, bool over366Days, bool infinite})>
      conflictRuleRemovalImpact(String ruleId) async {
    final impact = await _conflicts.conflictRuleRemovalImpact(ruleId);
    return (
      affectedDays: impact.affectedOccurrenceCount,
      over366Days: impact.over366Days,
      infinite: impact.infinite,
    );
  }

  @override
  Future<void> unlinkTaskEvent({
    required String taskId,
    required String eventId,
    int? expectedTaskUpdatedAt,
    int? expectedEventUpdatedAt,
  }) =>
      _links.unlink(
        taskId: taskId,
        eventId: eventId,
        expectedTaskUpdatedAt: expectedTaskUpdatedAt,
        expectedEventUpdatedAt: expectedEventUpdatedAt,
      );

  @override
  Future<bool> resetPermissionPolicy({
    required String actionType,
    required String targetType,
  }) async {
    final outcome = await policy.resetPolicy(
      accountId: accountId,
      actionType: actionType,
      targetType: targetType,
    );
    return outcome == ResetPolicyOutcome.reset;
  }

  @override
  Future<void> undoLastAction() => _undo.undo();

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
