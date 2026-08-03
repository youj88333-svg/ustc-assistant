import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../history/application/history_repository.dart';
import '../../reminders/application/reminder_override_service.dart';
import '../../schedule/application/conflict_service.dart';
import '../../schedule/application/effective_event_repository.dart';
import '../../schedule/application/overlay_service.dart';
import '../../schedule/application/schedule_conflict_projection.dart';
import '../../schedule/domain/overlap_engine.dart';
import '../../schedule/domain/schedule_grid_item.dart';
import '../../sync/domain/sync_state.dart';
import '../../tasks/application/undo_recorder.dart';
import '../../tasks/application/undo_service.dart';
import '../../tasks/domain/plan_block.dart';
import '../../tasks/domain/task.dart';

/// A read-only, account-scoped data gateway for the local Agent tools.
///
/// This is the single seam between the read-only Agent tools and the local
/// business data. Concrete tools depend on this interface (not on Drift or the
/// application services) so they stay pure-Dart and unit-testable with fakes.
///
/// Implementations MUST:
/// - Scope every query to [accountId] inside the database (never fetch
///   cross-account rows and filter in Dart).
/// - Expose ONLY read methods. There are no create/update/delete methods here
///   on purpose: the read-only Agent must never mutate local state.
/// - Avoid `dart:io`, Windows, DPAPI, and process APIs. The Drift
///   implementation may import Drift (it owns the DB seam) but no platform
///   APIs.
abstract interface class AgentLocalDataGateway {
  /// The effective schedule events for the account, as the schedule UI sees
  /// them (overlay-resolved, conflict-flagged, hidden rows excluded).
  Future<List<EffectiveEvent>> displayEvents(String accountId);

  /// The full effective record (overlay + attendance/listening/notes) for a
  /// single event. Throws if the event does not exist for this account.
  Future<EffectiveEventRecord> eventById(String accountId, String eventId);

  /// Every effective record for the account (used for pending-review scans).
  Future<List<EffectiveEventRecord>> allEventRecords(String accountId);

  /// A single course series by id (must belong to the account). Returns null
  /// if the series is missing. Used by the grouped course-summary mode to
  /// derive teachers/semester from the series metadata rather than the events.
  Future<CourseSery?> courseSeriesById(String accountId, String seriesId);

  /// All non-deleted tasks for the account.
  Future<List<TaskItem>> tasks(String accountId);

  /// A single task by id (must belong to the account). Throws if missing.
  Future<TaskItem> taskById(String accountId, String taskId);

  /// All non-deleted plan blocks for a task (must belong to the account).
  Future<List<PlanBlockItem>> planBlocksForTask(
    String accountId,
    String taskId,
  );

  /// All non-deleted plan blocks for the account.
  Future<List<PlanBlockItem>> allPlanBlocks(String accountId);

  /// The account's `source=user` management-state events for the read-only
  /// `get_schedule(view=management)` tool: personal schedule / recurring
  /// occurrence rows that are cancelled, hidden, completed, skipped, or
  /// soft-deleted. Account-scoped and `source=user`-filtered inside the DB.
  ///
  /// This deliberately does NOT go through
  /// `EffectiveEventRepository.watchDisplayEvents()` (which excludes
  /// cancelled/hidden/deleted rows); it is the explicit management read the
  /// brief requires.
  Future<List<CalendarEvent>> managementEvents(String accountId);

  /// All soft-deleted tasks for the account (deletedAt != null), for
  /// `get_tasks(state=deleted)`.
  Future<List<TaskItem>> deletedTasks(String accountId);

  /// All soft-deleted plan blocks for [taskId] (deletedAt != null), for
  /// `get_plan_blocks(include_deleted=true)`. Account-scoped and
  /// task-scoped inside the DB so a caller cannot fetch the whole account's
  /// deleted blocks without a task scope.
  Future<List<PlanBlockItem>> deletedPlanBlocksForTask(
    String accountId,
    String taskId,
  );

  /// The still-existing (non-deleted) calendar events linked to [taskId]
  /// that belong to [accountId], for `get_task_details.linkedEvents`.
  Future<List<CalendarEvent>> linkedEventsForTask(
    String accountId,
    String taskId,
  );

  /// The sync state for a source, derived from sync_runs + source_configs.
  Future<SyncSourceState> syncState(String accountId, SyncSource source);

  /// The account-scoped, sanitized action-log history (capped at
  /// [agentHistoryLimit] rows, filtered by account inside the DB).
  Future<List<HistoryEntry>> history(
    String accountId, {
    HistoryFilter filter,
  });

  /// The account-scoped conflict relation snapshot (occurrence relations +
  /// series rules) consumed by the pair-level conflict projection.
  Future<ScheduleConflictRelationSnapshot> scheduleConflictRelations(
    String accountId,
  );

  /// Runs ONE bounded conflict projection over [events] (already the caller's
  /// range/title-filtered result set) plus the account's effective plan blocks,
  /// restricted to the inclusive-exclusive display range. Returns the keyed
  /// result so callers can stamp events and plan blocks with the same conflict
  /// id set without a second, duplicate projection over all history.
  ///
  /// [includeExplicitOutOfWindow] defaults to false (week-grid scope); pass
  /// true for conflict reporting so an explicit relation to an out-of-window
  /// partner is still surfaced.
  Future<ConflictProjectionResult> conflictsForItems(
    String accountId,
    List<EffectiveEvent> events, {
    required DateTime from,
    required DateTime throughExclusive,
    bool includeExplicitOutOfWindow = false,
  });

  /// Whether the single event [eventId] conflicts with any overlapping
  /// candidate, via a bounded projection (never all history). Used by
  /// `get_event_details`.
  Future<bool> eventHasConflict(String accountId, String eventId);

  /// The account's `source=user`, `relationType=conflict` occurrence relations
  /// involving [left] on either side. Read-only; no mutation.
  Future<List<ScheduleRelation>> userConflictRelationsFor(
    String accountId,
    ScheduleConflictParticipant participant,
  );

  /// The account's series conflict rules involving [participant]'s series on
  /// either side. Empty when the participant has no stable series identity.
  Future<List<ScheduleRelationRule>> userConflictRulesFor(
    String accountId,
    ScheduleConflictParticipant participant,
  );

  /// The loadable grid-item view of a conflict participant, or null for a
  /// missing/deleted/foreign participant. Read-only.
  Future<ScheduleGridItem?> gridItemForParticipant(
    String accountId,
    ScheduleConflictParticipant participant,
  );

  /// Resolves the current state of a conflict pair via the shared projection.
  /// Returns null when either participant's grid item does not resolve.
  Future<ResolvedConflictPair?> resolvePairBetween(
    String accountId,
    ScheduleConflictParticipant a,
    ScheduleConflictParticipant b,
  );

  /// The would-be pair state after removing the occurrence relation keyed by
  /// [ignoredOccurrenceKey] (series rule → derived overlap → no conflict).
  Future<ResolvedConflictPair?> resolvePairIgnoringOccurrence(
    String accountId,
    ScheduleConflictParticipant a,
    ScheduleConflictParticipant b,
    String ignoredOccurrenceKey,
  );

  /// The would-be pair state after removing the series rules for a/b's series
  /// pair (occurrence relation → derived overlap → no conflict).
  Future<ResolvedConflictPair?> resolvePairIgnoringSeries(
    String accountId,
    ScheduleConflictParticipant a,
    ScheduleConflictParticipant b,
  );

  /// The target's Reminder configuration (future desired offsets, explicit
  /// disable marker, delivered/missed/failed counts). Account-scoped, read-only,
  /// never exposes a Reminder DB id.
  Future<ReminderConfiguration> reminderConfiguration(
    String accountId, {
    required String targetType,
    required String targetId,
  });

  /// The two explicit overlay layers (`single_event` / `course_series`) for
  /// [eventId] plus the clear-preview values. Account-scoped, read-only, never
  /// exposes a DB id.
  Future<EventOverlayLayers> eventOverlayLayers(
    String accountId,
    String eventId,
  );

  /// The account-safe preview of the most recent undoable action, for the
  /// read-only `get_last_undoable_action` tool. Account-scoped: a missing or
  /// foreign-account slot returns an unavailable preview with no content. The
  /// preview carries only the safe summary/type/Beijing time and NEVER consumes
  /// the slot (the write tool decides when to actually undo).
  Future<UndoPreview> lastUndoableAction(String accountId);
}

/// A Drift-backed [AgentLocalDataGateway].
///
/// Owns the [AppDatabase] seam and builds the per-feature read repositories
/// scoped to the requested account on each call. No state is retained between
/// calls; no mutation methods are exposed.
class DriftAgentLocalDataGateway implements AgentLocalDataGateway {
  const DriftAgentLocalDataGateway(this._database);

  final AppDatabase _database;

  @override
  Future<List<EffectiveEvent>> displayEvents(String accountId) {
    final repository = EffectiveEventRepository(_database, accountId: accountId);
    // `watchDisplayEvents` is a stream; take the first emission so the tool
    // gets a one-shot future. The underlying custom select runs once.
    return repository.watchDisplayEvents().first;
  }

  @override
  Future<EffectiveEventRecord> eventById(String accountId, String eventId) {
    final repository = EffectiveEventRepository(_database, accountId: accountId);
    return repository.byId(eventId);
  }

  @override
  Future<List<EffectiveEventRecord>> allEventRecords(String accountId) {
    final repository = EffectiveEventRepository(_database, accountId: accountId);
    return repository.watchAll().first;
  }

  @override
  Future<CourseSery?> courseSeriesById(String accountId, String seriesId) async {
    final row = await (_database.select(_database.courseSeries)
          ..where(
            (row) =>
                row.id.equals(seriesId) & row.accountId.equals(accountId),
          ))
        .getSingleOrNull();
    return row;
  }

  @override
  Future<List<TaskItem>> tasks(String accountId) async {
    final rows = await (_database.select(_database.tasks)
          ..where(
            (row) => row.accountId.equals(accountId) & row.deletedAt.isNull(),
          )
          ..orderBy([(row) => OrderingTerm.desc(row.updatedAt)]))
        .get();
    return rows.map(TaskItem.fromRow).toList(growable: false);
  }

  @override
  Future<TaskItem> taskById(String accountId, String taskId) async {
    final row = await (_database.select(_database.tasks)
          ..where(
            (row) =>
                row.id.equals(taskId) &
                row.accountId.equals(accountId) &
                row.deletedAt.isNull(),
          ))
        .getSingleOrNull();
    if (row == null) {
      throw StateError('task not found for account');
    }
    return TaskItem.fromRow(row);
  }

  @override
  Future<List<PlanBlockItem>> planBlocksForTask(
    String accountId,
    String taskId,
  ) async {
    final rows = await (_database.select(_database.planBlocks)
          ..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.taskId.equals(taskId) &
                row.deletedAt.isNull(),
          )
          ..orderBy([(row) => OrderingTerm.asc(row.startAt)]))
        .get();
    return rows.map(PlanBlockItem.fromRow).toList(growable: false);
  }

  @override
  Future<List<PlanBlockItem>> allPlanBlocks(String accountId) async {
    final rows = await (_database.select(_database.planBlocks)
          ..where(
            (row) => row.accountId.equals(accountId) & row.deletedAt.isNull(),
          )
          ..orderBy([(row) => OrderingTerm.asc(row.startAt)]))
        .get();
    return rows.map(PlanBlockItem.fromRow).toList(growable: false);
  }

  @override
  Future<List<CalendarEvent>> managementEvents(String accountId) async {
    final rows = await (_database.select(_database.calendarEvents)
          ..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.source.equals('user') &
                (row.status.equals('cancelled') |
                    row.status.equals('hidden') |
                    row.status.equals('completed') |
                    row.status.equals('skipped') |
                    row.deletedAt.isNotNull()),
          )
          ..orderBy([(row) => OrderingTerm.asc(row.startAt)]))
        .get();
    return rows;
  }

  @override
  Future<List<TaskItem>> deletedTasks(String accountId) async {
    final rows = await (_database.select(_database.tasks)
          ..where(
            (row) => row.accountId.equals(accountId) & row.deletedAt.isNotNull(),
          )
          ..orderBy([(row) => OrderingTerm.desc(row.updatedAt)]))
        .get();
    return rows.map(TaskItem.fromRow).toList(growable: false);
  }

  @override
  Future<List<PlanBlockItem>> deletedPlanBlocksForTask(
    String accountId,
    String taskId,
  ) async {
    final rows = await (_database.select(_database.planBlocks)
          ..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.taskId.equals(taskId) &
                row.deletedAt.isNotNull(),
          )
          ..orderBy([(row) => OrderingTerm.asc(row.startAt)]))
        .get();
    return rows.map(PlanBlockItem.fromRow).toList(growable: false);
  }

  @override
  Future<List<CalendarEvent>> linkedEventsForTask(
    String accountId,
    String taskId,
  ) async {
    final linkRows = await (_database.select(_database.taskEventLinks)..where(
          (row) =>
              row.accountId.equals(accountId) & row.taskId.equals(taskId),
        ))
        .get();
    if (linkRows.isEmpty) return const [];
    final events = <CalendarEvent>[];
    for (final link in linkRows) {
      final row = await (_database.select(_database.calendarEvents)..where(
            (row) =>
                row.id.equals(link.eventId) &
                row.accountId.equals(accountId) &
                row.deletedAt.isNull(),
          ))
          .getSingleOrNull();
      if (row != null) events.add(row);
    }
    return events;
  }

  @override
  Future<SyncSourceState> syncState(String accountId, SyncSource source) =>
      _stateFor(_database, source, accountId);

  @override
  Future<List<HistoryEntry>> history(
    String accountId, {
    HistoryFilter filter = const HistoryFilter(),
  }) =>
      HistoryRepository(_database).query(accountId, filter: filter);

  @override
  Future<ScheduleConflictRelationSnapshot> scheduleConflictRelations(
    String accountId,
  ) =>
      ConflictService(database: _database, accountId: accountId)
          .relationSnapshot();

  @override
  Future<ConflictProjectionResult> conflictsForItems(
    String accountId,
    List<EffectiveEvent> events, {
    required DateTime from,
    required DateTime throughExclusive,
    bool includeExplicitOutOfWindow = false,
  }) =>
      EffectiveEventRepository(_database, accountId: accountId).conflictsForItems(
        events,
        from: from,
        throughExclusive: throughExclusive,
        includeExplicitOutOfWindow: includeExplicitOutOfWindow,
      );

  @override
  Future<bool> eventHasConflict(String accountId, String eventId) =>
      EffectiveEventRepository(_database, accountId: accountId)
          .eventHasConflict(eventId);

  @override
  Future<List<ScheduleRelation>> userConflictRelationsFor(
    String accountId,
    ScheduleConflictParticipant participant,
  ) =>
      ConflictService(database: _database, accountId: accountId)
          .userConflictRelationsFor(participant);

  @override
  Future<List<ScheduleRelationRule>> userConflictRulesFor(
    String accountId,
    ScheduleConflictParticipant participant,
  ) =>
      ConflictService(database: _database, accountId: accountId)
          .userConflictRulesFor(participant);

  @override
  Future<ScheduleGridItem?> gridItemForParticipant(
    String accountId,
    ScheduleConflictParticipant participant,
  ) =>
      ConflictService(database: _database, accountId: accountId)
          .gridItemForParticipant(participant);

  @override
  Future<ResolvedConflictPair?> resolvePairBetween(
    String accountId,
    ScheduleConflictParticipant a,
    ScheduleConflictParticipant b,
  ) =>
      ConflictService(database: _database, accountId: accountId)
          .resolvePairBetween(a, b);

  @override
  Future<ResolvedConflictPair?> resolvePairIgnoringOccurrence(
    String accountId,
    ScheduleConflictParticipant a,
    ScheduleConflictParticipant b,
    String ignoredOccurrenceKey,
  ) =>
      ConflictService(database: _database, accountId: accountId)
          .resolvePairIgnoringOccurrence(a, b, ignoredOccurrenceKey);

  @override
  Future<ResolvedConflictPair?> resolvePairIgnoringSeries(
    String accountId,
    ScheduleConflictParticipant a,
    ScheduleConflictParticipant b,
  ) =>
      ConflictService(database: _database, accountId: accountId)
          .resolvePairIgnoringSeries(a, b);

  @override
  Future<ReminderConfiguration> reminderConfiguration(
    String accountId, {
    required String targetType,
    required String targetId,
  }) =>
      ReminderOverrideService(
        database: _database,
        accountId: accountId,
        undoRecorder: const NoopUndoRecorder(),
      ).configurationFor(targetType: targetType, targetId: targetId);

  @override
  Future<EventOverlayLayers> eventOverlayLayers(
    String accountId,
    String eventId,
  ) =>
      OverlayService(database: _database, accountId: accountId)
          .eventOverlayLayers(eventId);

  @override
  Future<UndoPreview> lastUndoableAction(String accountId) =>
      UndoService(database: _database, accountId: accountId).preview();

  /// Mirrors `SyncCoordinator.stateFor` without pulling in the Python-bridge /
  /// import dependencies (those arrive in Task 9). Reads only sync_runs and
  /// source_configs, scoped to the account.
  static Future<SyncSourceState> _stateFor(
    AppDatabase database,
    SyncSource source,
    String accountId,
  ) async {
    final runs = await (database.select(database.syncRuns)
          ..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.source.equals(source.storage),
          )
          ..orderBy([(row) => OrderingTerm.desc(row.startedAt)]))
        .get();
    final config = await (database.select(database.sourceConfigs)
          ..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.source.equals(source.storage),
          ))
        .getSingleOrNull();
    final latest = runs.firstOrNull;
    final phase = switch (latest?.state) {
      'running' => SyncPhase.running,
      'needs_user_action' => SyncPhase.needsUserAction,
      'success' => SyncPhase.succeeded,
      'failed' || 'interrupted' => SyncPhase.failed,
      'cancelled' => SyncPhase.cancelled,
      _ => config == null || !config.enabled
          ? SyncPhase.idle
          : _isDue(config.lastSuccessAt, config.retryAfter)
          ? SyncPhase.due
          : SyncPhase.idle,
    };
    return SyncSourceState(
      source: source,
      phase: phase,
      lastAttemptAt: latest == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(latest.startedAt),
      lastSuccessfulAt: config?.lastSuccessAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(config!.lastSuccessAt!),
      resultCode: latest?.resultCode,
    );
  }

  /// Mirrors `SyncCoordinator.isAutomaticDue` (12h freshness, 1h backoff).
  static const _freshness = Duration(hours: 12);

  static bool _isDue(int? lastSuccessAt, int? retryAfter) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (retryAfter != null && now < retryAfter) return false;
    if (lastSuccessAt == null) return true;
    return now - lastSuccessAt >= _freshness.inMilliseconds;
  }
}
