import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
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
    });
  }

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
    final explicitlyDisabled =
        existing.isNotEmpty &&
        existing.every((row) => row.state == 'cancelled') &&
        priorOffsets.isEmpty;
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
