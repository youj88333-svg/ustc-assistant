import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../calendar/application/recurrence_service.dart';
import '../../calendar/domain/calendar_event_locator.dart';
import '../../calendar/domain/personal_event.dart';
import '../domain/reminder_rule.dart';

class ReminderService {
  ReminderService({
    required this.database,
    int Function()? now,
    Set<String> disabledEventTypes = const {},
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       disabledEventTypes = Set.unmodifiable(disabledEventTypes);

  final AppDatabase database;
  final int Function() now;
  final Set<String> disabledEventTypes;

  Future<void> reconcileSource(String accountId, String source) async {
    final events =
        await (database.select(database.calendarEvents)..where(
              (row) =>
                  row.accountId.equals(accountId) & row.source.equals(source),
            ))
            .get();
    await database.transaction(() async {
      for (final event in events) {
        await _reconcileEvent(event);
      }
    });
  }

  Future<void> reconcileAll(String accountId) async {
    final events = await (database.select(
      database.calendarEvents,
    )..where((row) => row.accountId.equals(accountId))).get();
    final tasks = await (database.select(
      database.tasks,
    )..where((row) => row.accountId.equals(accountId))).get();
    final blocks = await (database.select(
      database.planBlocks,
    )..where((row) => row.accountId.equals(accountId))).get();
    await database.transaction(() async {
      for (final event in events) {
        await _reconcileEvent(event);
      }
      for (final task in tasks) {
        await _reconcileTask(task);
      }
      for (final block in blocks) {
        await _reconcilePlanBlock(block);
      }
      await _reconcileSeries(accountId);
    });
  }

  /// Reconciles recurring-series reminder defaults in a bounded lookahead.
  ///
  /// Projects from the current Beijing date through 31 days ahead. For each
  /// effective timed occurrence with a non-empty inherited offset list, a
  /// future desired reminder trigger is persisted with a single reused no-op
  /// occurrence-exception anchor (created via
  /// [RecurrenceService.ensureOccurrenceAnchor] — which is an approved write
  /// transaction). All-day series with an empty offset list create no reminder
  /// rows. Anchors/occurrences that are cancelled, deleted, or fallen out of
  /// the window have their future desired reminders cancelled; delivered /
  /// missed / failed history is preserved. The projection never expands beyond
  /// 31 days in one run.
  Future<void> _reconcileSeries(String accountId) async {
    final recurrence =
        RecurrenceService(database: database, accountId: accountId, now: now);
    final seriesRows = await recurrence.allSeries();
    if (seriesRows.isEmpty) return;
    final timestamp = now();
    final beijing = DateTime.fromMillisecondsSinceEpoch(
      timestamp,
      isUtc: true,
    ).add(const Duration(hours: 8));
    final today = DateTime(beijing.year, beijing.month, beijing.day);
    // The 31-day reconciliation horizon: occurrences on [today, today+30],
    // i.e. 31 days inclusive, never expanding beyond in one run.
    final through = DateTime(
      today.year,
      today.month,
      today.day + 30,
      23,
      59,
      59,
    );
    for (final series in seriesRows) {
      final occurrences = await recurrence.occurrences(
        series.id,
        from: today,
        through: through,
      );
      final projectedKeys = <String>{
        for (final occurrence in occurrences) occurrence.occurrenceKey,
      };
      for (final occurrence in occurrences) {
        // A cancelled-but-not-deleted occurrence (e.g. an only_this cancel via
        // RecurringLifecycleService writes status='cancelled' and leaves
        // deletedAt NULL) must not regenerate desired reminders. `occurrences`
        // still returns it (the schedule projection and management mode need
        // to surface cancelled targets), so the state filter lives here in the
        // reminder reconcile, not in RecurrenceService.occurrences().
        if (occurrence.status == EventStatus.cancelled) continue;
        final offsets = occurrence.reminderOffsetsMinutes;
        if (occurrence.allDay || offsets.isEmpty || occurrence.startAt == null) {
          continue;
        }
        final startAtMs = occurrence.startAt!.millisecondsSinceEpoch;
        final locator = encodeCalendarEventLocator(
          RecurringOccurrenceLocator(
            seriesId: series.id,
            occurrenceKey: occurrence.occurrenceKey,
          ),
        );
        for (final offset in offsets) {
          final trigger = startAtMs - Duration(minutes: offset).inMilliseconds;
          if (trigger <= timestamp) continue;
          final anchor = await recurrence.ensureOccurrenceAnchor(
            series.id,
            occurrence.occurrenceKey,
          );
          await database
              .into(database.reminders)
              .insertOnConflictUpdate(
                RemindersCompanion.insert(
                  id: 'reminder:event:$locator:$trigger',
                  accountId: accountId,
                  targetType: 'event',
                  targetId: locator,
                  occurrenceExceptionId: Value(anchor.id),
                  offsetMinutes: Value(offset),
                  triggerAt: trigger,
                  state: 'desired',
                  failureCode: const Value(null),
                  deliveredAt: const Value(null),
                  createdAt: timestamp,
                  updatedAt: timestamp,
                ),
              );
        }
      }
      // Cancel future desired reminders whose owning occurrence is no longer
      // projectable (cancelled, deleted, or out of the bounded window). The
      // anchor rows may include sparse anchors from prior writes. A cancelled
      // status (only_this cancel) must also cancel desired reminders — the
      // upsert loop above skipped building them, but anchors from a prior
      // reconcile may still hold desired rows that need to be retired.
      final anchors = await recurrence.exceptionRows(series.id);
      for (final anchor in anchors) {
        if (anchor.orphaned == true ||
            anchor.deletedAt != null ||
            anchor.status == 'cancelled' ||
            !projectedKeys.contains(anchor.occurrenceKey)) {
          await _cancelOccurrenceReminders(anchor.id, timestamp);
        }
      }
    }
  }

  Future<void> _cancelOccurrenceReminders(String occurrenceExceptionId, int timestamp) =>
      (database.update(database.reminders)..where(
            (row) =>
                row.occurrenceExceptionId.equals(occurrenceExceptionId) &
                row.state.equals('desired'),
          )).write(
        RemindersCompanion(
          state: const Value('cancelled'),
          updatedAt: Value(timestamp),
        ),
      );

  Future<void> _reconcileEvent(CalendarEvent event) async {
    final hiddenOverlay =
        await (database.select(database.userOverlays)..where(
              (row) => row.eventId.equals(event.id) & row.hidden.equals(true),
            ))
            .getSingleOrNull();
    final suppressed =
        event.deletedAt != null ||
        const {
          'completed',
          'cancelled',
          'skipped',
          'hidden',
        }.contains(event.status) ||
        hiddenOverlay != null ||
        event.allDay ||
        disabledEventTypes.contains(event.type) ||
        event.startAt == null;
    final defaults = ReminderDefaults.forEvent(
      event.type,
      allDay: event.allDay,
    );
    await _reconcileTarget(
      accountId: event.accountId,
      targetType: 'event',
      targetId: event.id,
      anchorAt: event.startAt,
      defaultOffsets: defaults,
      suppressed: suppressed,
    );
  }

  Future<void> _reconcileTask(Task task) => _reconcileTarget(
    accountId: task.accountId,
    targetType: 'task',
    targetId: task.id,
    anchorAt: task.deadlineAt,
    defaultOffsets: ReminderDefaults.forTask(),
    suppressed:
        task.deletedAt != null ||
        task.deadlineAt == null ||
        const {'completed', 'cancelled'}.contains(task.state),
  );

  Future<void> _reconcilePlanBlock(PlanBlock block) => _reconcileTarget(
    accountId: block.accountId,
    targetType: 'plan_block',
    targetId: block.id,
    anchorAt: block.startAt,
    defaultOffsets: ReminderDefaults.forPlanBlock(),
    suppressed:
        block.deletedAt != null ||
        const {
          'done',
          'skipped',
          'rescheduled',
          'cancelled',
        }.contains(block.status),
  );

  Future<void> _reconcileTarget({
    required String accountId,
    required String targetType,
    required String targetId,
    required int? anchorAt,
    required List<int> defaultOffsets,
    required bool suppressed,
  }) async {
    final existing =
        await (database.select(database.reminders)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.targetType.equals(targetType) &
                  row.targetId.equals(targetId),
            ))
            .get();
    if (suppressed || anchorAt == null) {
      await _cancel(existing);
      return;
    }
    final priorOffsets = existing
        .map((row) => row.offsetMinutes)
        .whereType<int>()
        .toSet();
    // Explicitly recognize the disable sentinel (a cancelled row with NO
    // offset) rather than the previous `every(cancelled)` heuristic, which
    // stopped recognizing an explicit disable once delivered/missed/failed
    // history rows (state != cancelled) existed alongside the sentinel.
    final explicitlyDisabled = existing.any(
      (row) => row.state == 'cancelled' && row.offsetMinutes == null,
    );
    final offsets = <int>[
      ...(explicitlyDisabled
          ? const <int>[]
          : priorOffsets.isEmpty
          ? defaultOffsets
          : priorOffsets),
    ]..sort((left, right) => right.compareTo(left));
    final desiredTriggers = {
      for (final offset in offsets)
        anchorAt - Duration(minutes: offset).inMilliseconds: offset,
    };
    for (final row in existing) {
      if (!desiredTriggers.containsKey(row.triggerAt) &&
          row.state == 'desired') {
        await _setState(row.id, 'cancelled');
      }
    }
    for (final entry in desiredTriggers.entries) {
      final same = existing
          .where((row) => row.triggerAt == entry.key)
          .firstOrNull;
      final timestamp = now();
      final state = entry.key <= timestamp ? 'missed' : 'desired';
      if (same != null && same.state == 'delivered') continue;
      await database
          .into(database.reminders)
          .insertOnConflictUpdate(
            RemindersCompanion.insert(
              id: same?.id ?? _id(targetType, targetId, entry.key),
              accountId: accountId,
              targetType: targetType,
              targetId: targetId,
              eventId: Value(targetType == 'event' ? targetId : null),
              taskId: Value(targetType == 'task' ? targetId : null),
              planBlockId: Value(targetType == 'plan_block' ? targetId : null),
              offsetMinutes: Value(entry.value),
              triggerAt: entry.key,
              state: state,
              failureCode: const Value(null),
              deliveredAt: const Value(null),
              createdAt: same?.createdAt ?? timestamp,
              updatedAt: timestamp,
            ),
          );
    }
  }

  Future<void> _cancel(List<Reminder> rows) async {
    for (final row in rows.where((row) => row.state == 'desired')) {
      await _setState(row.id, 'cancelled');
    }
  }

  Future<void> _setState(String id, String state) =>
      (database.update(
        database.reminders,
      )..where((row) => row.id.equals(id))).write(
        RemindersCompanion(state: Value(state), updatedAt: Value(now())),
      );

  String _id(String type, String target, int trigger) =>
      'reminder:$type:$target:$trigger';
}
