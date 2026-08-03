import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../tasks/application/undo_recorder.dart';
import '../domain/personal_event.dart';

class SourceOwnedEventError implements Exception {
  const SourceOwnedEventError();

  @override
  String toString() => 'SourceOwnedEventError: use UserOverlay';
}

class CalendarEventService {
  CalendarEventService({
    required this.database,
    required this.accountId,
    int Function()? now,
    UndoRecorder? undoRecorder,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       undoRecorder = undoRecorder ?? const NoopUndoRecorder();

  final AppDatabase database;
  final String accountId;
  final int Function() now;
  final UndoRecorder undoRecorder;
  static const _uuid = Uuid();

  Future<String> create(
    PersonalEvent event, {
    List<int>? reminderOffsetsMinutes,
    List<String> taskIds = const [],
  }) async {
    final id = event.id ?? _uuid.v4();
    await database.transaction(() async {
      final timestamp = now();
      await database
          .into(database.calendarEvents)
          .insert(_insertCompanion(id, event, timestamp));
      await _replaceReminders(
        id,
        event,
        reminderOffsetsMinutes: reminderOffsetsMinutes,
        timestamp: timestamp,
      );
      for (final taskId in taskIds) {
        await database
            .into(database.taskEventLinks)
            .insert(
              TaskEventLinksCompanion.insert(
                accountId: accountId,
                taskId: taskId,
                eventId: id,
                relationType: 'related',
                createdAt: timestamp,
              ),
            );
      }
      await _log('calendar_event_create', 'Created a personal event.');
      await _recordUndo('calendar_event_create', id, null);
    });
    return id;
  }

  Future<PersonalEvent> byId(String id, {bool includeDeleted = false}) async {
    final row =
        await (database.select(database.calendarEvents)..where(
              (table) =>
                  table.id.equals(id) &
                  table.accountId.equals(accountId) &
                  (includeDeleted
                      ? const Constant(true)
                      : table.deletedAt.isNull()),
            ))
            .getSingleOrNull();
    if (row == null) throw StateError('calendar event not found');
    return PersonalEvent.fromRow(row);
  }

  Future<List<PersonalEvent>> managementList() async {
    final rows =
        await (database.select(database.calendarEvents)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.source.equals('user') &
                  (row.status.equals('hidden') | row.deletedAt.isNotNull()),
            ))
            .get();
    return rows.map(PersonalEvent.fromRow).toList(growable: false);
  }

  /// The account's `source=user` management-state events (cancelled / hidden /
  /// completed / skipped / soft-deleted) as [PersonalEvent] snapshots, for the
  /// read-only management queries. Account- and source-filtered inside the DB.
  Future<List<PersonalEvent>> managementEvents() async {
    final rows =
        await (database.select(database.calendarEvents)..where(
              (row) =>
                  row.accountId.equals(accountId) &
                  row.source.equals('user') &
                  (row.status.equals('cancelled') |
                      row.status.equals('hidden') |
                      row.status.equals('completed') |
                      row.status.equals('skipped') |
                      row.deletedAt.isNotNull()),
            ))
            .get();
    return rows.map(PersonalEvent.fromRow).toList(growable: false);
  }

  Future<void> edit(
    String id,
    PersonalEvent replacement, {
    List<int>? reminderOffsetsMinutes,
    List<String>? taskIds,
  }) async {
    await database.transaction(() async {
      final current = await _ownedRow(id);
      final timestamp = now();
      await (database.update(database.calendarEvents)
            ..where((row) => row.id.equals(id)))
          .write(_updateCompanion(replacement, timestamp));
      await _replaceReminders(
        id,
        replacement,
        reminderOffsetsMinutes: reminderOffsetsMinutes,
        timestamp: timestamp,
      );
      if (taskIds != null) {
        await (database.delete(
          database.taskEventLinks,
        )..where((row) => row.eventId.equals(id))).go();
        for (final taskId in taskIds) {
          await database
              .into(database.taskEventLinks)
              .insert(
                TaskEventLinksCompanion.insert(
                  accountId: accountId,
                  taskId: taskId,
                  eventId: id,
                  relationType: 'related',
                  createdAt: timestamp,
                ),
              );
        }
      }
      await _log('calendar_event_edit', 'Updated a personal event.');
      await _recordUndo('calendar_event_edit', id, _eventSnapshot(current));
      if (current.deletedAt != null) {
        throw StateError('deleted event must be restored before editing');
      }
    });
  }

  Future<void> complete(String id) =>
      _setStatus(id, EventStatus.completed, 'calendar_event_complete');

  Future<void> skip(String id) =>
      _setStatus(id, EventStatus.skipped, 'calendar_event_skip');

  Future<void> cancel(String id) =>
      _setStatus(id, EventStatus.cancelled, 'calendar_event_cancel');

  Future<void> hide(String id) =>
      _setStatus(id, EventStatus.hidden, 'calendar_event_hide');

  Future<void> reschedule(String id, PersonalEvent replacement) =>
      edit(id, replacement);

  Future<void> softDelete(String id) async {
    await database.transaction(() async {
      final current = await _ownedRow(id);
      final timestamp = now();
      await (database.update(
        database.calendarEvents,
      )..where((row) => row.id.equals(id))).write(
        CalendarEventsCompanion(
          deletedAt: Value(timestamp),
          updatedAt: Value(timestamp),
        ),
      );
      await _cancelReminders(id, timestamp);
      await _log('calendar_event_delete', 'Deleted a personal event.');
      await _recordUndo('calendar_event_delete', id, _eventSnapshot(current));
    });
  }

  Future<void> restore(String id) async {
    await database.transaction(() async {
      final row = await _ownedRow(id, allowDeleted: true);
      final timestamp = now();
      await (database.update(
        database.calendarEvents,
      )..where((table) => table.id.equals(id))).write(
        CalendarEventsCompanion(
          deletedAt: const Value(null),
          status: Value(row.status == 'hidden' ? 'active' : row.status),
          updatedAt: Value(timestamp),
        ),
      );
      await _log('calendar_event_restore', 'Restored a personal event.');
      await _recordUndo('calendar_event_restore', id, _eventSnapshot(row));
    });
  }

  Future<void> _setStatus(
    String id,
    EventStatus status,
    String actionType,
  ) async {
    await database.transaction(() async {
      final current = await _ownedRow(id);
      final timestamp = now();
      final terminal =
          status == EventStatus.completed ||
          status == EventStatus.skipped ||
          status == EventStatus.cancelled;
      await (database.update(
        database.calendarEvents,
      )..where((row) => row.id.equals(id))).write(
        CalendarEventsCompanion(
          status: Value(status.storage),
          completedAt: Value(terminal ? timestamp : null),
          updatedAt: Value(timestamp),
        ),
      );
      if (status != EventStatus.active && status != EventStatus.tentative) {
        await _cancelReminders(id, timestamp);
      }
      await _log(actionType, 'Updated a personal event state.');
      await _recordUndo(actionType, id, _eventSnapshot(current));
    });
  }

  Future<CalendarEvent> _ownedRow(
    String id, {
    bool allowDeleted = false,
  }) async {
    final row =
        await (database.select(database.calendarEvents)..where(
              (table) =>
                  table.id.equals(id) &
                  table.accountId.equals(accountId) &
                  (allowDeleted
                      ? const Constant(true)
                      : table.deletedAt.isNull()),
            ))
            .getSingleOrNull();
    if (row == null) throw StateError('calendar event not found');
    if (row.source != 'user') throw const SourceOwnedEventError();
    return row;
  }

  CalendarEventsCompanion _insertCompanion(
    String id,
    PersonalEvent event,
    int timestamp,
  ) => CalendarEventsCompanion.insert(
    id: id,
    accountId: accountId,
    source: 'user',
    title: event.title,
    description: Value(event.description),
    type: event.type.storage,
    status: Value(event.status.storage),
    startAt: Value(event.startAt?.millisecondsSinceEpoch),
    endAt: Value(event.endAt?.millisecondsSinceEpoch),
    allDay: event.allDay,
    startDate: Value(_dateText(event.startDate)),
    endDateExclusive: Value(_dateText(event.endDateExclusive)),
    timezone: 'Asia/Shanghai',
    locationName: Value(event.locationName),
    importance: Value(event.importance),
    completionPolicy: Value(event.completionPolicy.storage),
    completedAt: Value(event.completedAt),
    color: Value(event.color),
    tagsJson: Value(jsonEncode(event.tags)),
    createdAt: timestamp,
    updatedAt: timestamp,
    deletedAt: Value(event.deletedAt),
  );

  CalendarEventsCompanion _updateCompanion(
    PersonalEvent event,
    int timestamp,
  ) => CalendarEventsCompanion(
    title: Value(event.title),
    description: Value(event.description),
    type: Value(event.type.storage),
    status: Value(event.status.storage),
    startAt: Value(event.startAt?.millisecondsSinceEpoch),
    endAt: Value(event.endAt?.millisecondsSinceEpoch),
    allDay: Value(event.allDay),
    startDate: Value(_dateText(event.startDate)),
    endDateExclusive: Value(_dateText(event.endDateExclusive)),
    locationName: Value(event.locationName),
    importance: Value(event.importance),
    completionPolicy: Value(event.completionPolicy.storage),
    completedAt: Value(event.completedAt),
    color: Value(event.color),
    tagsJson: Value(jsonEncode(event.tags)),
    updatedAt: Value(timestamp),
  );

  Future<void> _replaceReminders(
    String eventId,
    PersonalEvent event, {
    required List<int>? reminderOffsetsMinutes,
    required int timestamp,
  }) async {
    await (database.delete(
      database.reminders,
    )..where((row) => row.eventId.equals(eventId))).go();
    final offsets =
        reminderOffsetsMinutes ?? (event.allDay ? const <int>[] : const [15]);
    if (event.allDay && offsets.isNotEmpty) {
      throw const CalendarValidationError(
        'all-day reminders require an absolute time',
      );
    }
    for (final offset in offsets) {
      if (offset < 0) {
        throw const CalendarValidationError(
          'reminder offset must not be negative',
        );
      }
      final triggerAt = event.startAt!
          .subtract(Duration(minutes: offset))
          .millisecondsSinceEpoch;
      await database
          .into(database.reminders)
          .insert(
            RemindersCompanion.insert(
              id: _uuid.v4(),
              accountId: accountId,
              targetType: 'event',
              targetId: eventId,
              eventId: Value(eventId),
              offsetMinutes: Value(offset),
              triggerAt: triggerAt,
              state: 'desired',
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );
    }
  }

  Future<void> _cancelReminders(String eventId, int timestamp) =>
      (database.update(
        database.reminders,
      )..where((row) => row.eventId.equals(eventId))).write(
        RemindersCompanion(
          state: const Value('cancelled'),
          updatedAt: Value(timestamp),
        ),
      );

  Future<void> _log(String actionType, String summary) =>
      database.actionLogsRepository.append(
        accountId: accountId,
        source: 'user',
        actionType: actionType,
        result: 'success',
        safeSummary: summary,
        occurredAt: now(),
      );

  Future<void> _recordUndo(
    String kind,
    String id,
    Map<String, Object?>? before,
  ) => undoRecorder.record(
    UndoCommand(
      kind: kind,
      accountId: accountId,
      payload: {'entity': 'calendar_event', 'id': id, 'before': before},
    ),
  );

  Map<String, Object?> _eventSnapshot(CalendarEvent row) => {
    'id': row.id,
    'source': row.source,
    'externalId': row.externalId,
    'sourceSeriesExternalId': row.sourceSeriesExternalId,
    'personalSeriesId': row.personalSeriesId,
    'occurrenceKey': row.occurrenceKey,
    'title': row.title,
    'description': row.description,
    'type': row.type,
    'status': row.status,
    'startAt': row.startAt,
    'endAt': row.endAt,
    'allDay': row.allDay,
    'startDate': row.startDate,
    'endDateExclusive': row.endDateExclusive,
    'timezone': row.timezone,
    'locationName': row.locationName,
    'buildingName': row.buildingName,
    'campusName': row.campusName,
    'participantsJson': row.participantsJson,
    'sourceDetailsJson': row.sourceDetailsJson,
    'importance': row.importance,
    'completionPolicy': row.completionPolicy,
    'completedAt': row.completedAt,
    'color': row.color,
    'tagsJson': row.tagsJson,
    'createdAt': row.createdAt,
    'updatedAt': row.updatedAt,
    'deletedAt': row.deletedAt,
  };

  String? _dateText(DateTime? value) => value == null
      ? null
      : '${value.year.toString().padLeft(4, '0')}-'
            '${value.month.toString().padLeft(2, '0')}-'
            '${value.day.toString().padLeft(2, '0')}';
}
