import '../../../core/time/beijing_clock.dart';
import '../../history/application/history_repository.dart';
import '../../schedule/application/effective_event_repository.dart';
import '../../schedule/domain/overlap_engine.dart';
import '../../schedule/domain/ustc_periods.dart';
import '../../sync/domain/sync_state.dart';
import '../../tasks/domain/plan_block.dart';
import '../../tasks/domain/task_projection.dart';
import '../domain/agent_tool.dart';
import '../domain/query_source.dart';
import 'agent_configuration_service.dart';
import 'agent_local_data_gateway.dart';
import 'outbound_privacy_filter.dart';

/// The maximum number of events a schedule tool returns before refusing with
/// `result_too_large`.
const int agentEventLimit = 200;

/// The maximum number of tasks a task tool returns before refusing with
/// `result_too_large`.
const int agentTaskLimit = 100;

/// The maximum number of plan blocks a plan-block tool returns before refusing
/// with `result_too_large`.
const int agentPlanBlockLimit = 200;

/// The default schedule range span: today through the next 6 days = 7 calendar
/// days including today.
const int _defaultRangeDays = 7;

/// The maximum allowed schedule range span in calendar days.
const int _maxRangeDays = 31;

// ---------------------------------------------------------------------------
// Range parsing
// ---------------------------------------------------------------------------

/// A parsed, validated date range, inclusive on both ends, interpreted as
/// Asia/Shanghai calendar dates.
class AgentDateRange {
  const AgentDateRange({required this.from, required this.through});

  final DateTime from;
  final DateTime through;

  /// The number of calendar days in the range, inclusive (from..through).
  int get dayCount => through.difference(from).inDays + 1;
}

/// The outcome of parsing a tool range argument.
class _RangeParse {
  _RangeParse.ok(this.range) : error = null;
  _RangeParse.error(this.error) : range = null;

  final AgentDateRange? range;
  final String? error;
}

/// Parses `from` and `through` ('YYYY-MM-DD') against [clock].
///
/// - If both are null, defaults to today..today + (`_defaultRangeDays` - 1).
/// - Rejects reversed ranges (`from` after `through`) with `invalid_range`.
/// - Rejects ranges wider than `_maxRangeDays` days with `range_too_large`.
/// - Returns a safe error code for unparseable dates.
_RangeParse _parseRange(String? fromStr, String? throughStr, BeijingClock clock) {
  final now = clock.now();
  if (fromStr == null && throughStr == null) {
    final from = DateTime(now.year, now.month, now.day);
    final through = from.add(const Duration(days: _defaultRangeDays - 1));
    return _RangeParse.ok(AgentDateRange(from: from, through: through));
  }
  final from = _parseDate(fromStr ?? throughStr!, clock);
  final through = _parseDate(throughStr ?? fromStr!, clock);
  if (from == null || through == null) {
    return _RangeParse.error('invalid_range');
  }
  if (through.isBefore(from)) {
    return _RangeParse.error('invalid_range');
  }
  final range = AgentDateRange(from: from, through: through);
  if (range.dayCount > _maxRangeDays) {
    return _RangeParse.error('range_too_large');
  }
  return _RangeParse.ok(range);
}

DateTime? _parseDate(String value, BeijingClock clock) {
  // Accept 'YYYY-MM-DD'. Interpret strictly as a Beijing calendar date.
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (match == null) return null;
  final y = int.parse(match.group(1)!);
  final m = int.parse(match.group(2)!);
  final d = int.parse(match.group(3)!);
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  return DateTime(y, m, d);
}

/// Whether [event] overlaps the inclusive [from]..[through] calendar range.
///
/// Timed events use their startAt/endAt (Beijing); all-day events use their
/// [startDate, endDateExclusive) interval. An event is in range if any day of
/// its span falls on or between `from` and `through`.
bool _eventInRange(EffectiveEvent event, AgentDateRange range) {
  final rangeEndInclusive = range.through.add(const Duration(days: 1));
  if (event.allDay) {
    final start = event.startDate!;
    final endExclusive = event.endDateExclusive!;
    return start.isBefore(rangeEndInclusive) && endExclusive.isAfter(range.from);
  }
  final start = event.startAt!;
  final end = event.endAt ?? start;
  // Inclusive end day check: an event ending exactly at range.from midnight
  // still counts if it starts before rangeEndInclusive.
  return start.isBefore(rangeEndInclusive) && !end.isBefore(range.from);
}

/// Formats a Beijing [DateTime] as 'YYYY-MM-DDTHH:mm:ss' (no timezone suffix;
/// the model is told times are Beijing time).
String _formatDateTime(DateTime value) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)}'
      'T${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
}

String _formatDate(DateTime value) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)}';
}

/// Maps an [EffectiveEvent]'s confirmed-conflict flag to the model-facing
/// `conflictState` string. Free-time and plain schedules never invent a
/// `conflict` classification; this only reflects the authoritative SQL flag.
String _conflictStateString(EffectiveEvent event) =>
    event.hasConfirmedConflict ? 'conflict' : 'not_conflict';

String _importanceString(EventImportance importance) => switch (importance) {
      EventImportance.low => 'low',
      EventImportance.normal => 'normal',
      EventImportance.high => 'high',
      EventImportance.critical => 'critical',
    };

/// Normalizes an [EffectiveEvent] into the model-facing schedule DTO, binding a
/// run-local `ref_event_*` token via [references] for the event's local id.
Map<String, Object?> _eventDto(
  EffectiveEvent event,
  AgentToolContext context,
) {
  final ref = context.references.bind(kind: 'event', localId: event.id);
  final dto = <String, Object?>{
    'ref': ref,
    'title': event.title,
    'allDay': event.allDay,
    'eventType': event.eventType,
    'importance': _importanceString(event.importance),
    'conflictState': _conflictStateString(event),
  };
  if (event.location != null) dto['location'] = event.location;
  if (event.allDay) {
    dto['startDate'] = _formatDate(event.startDate!);
    dto['endDateExclusive'] = _formatDate(event.endDateExclusive!);
  } else {
    dto['startAt'] = _formatDateTime(event.startAt!);
    dto['endAt'] = _formatDateTime(event.endAt!);
    if (event.isInactivePreview) dto['isInactivePreview'] = true;
  }
  return dto;
}

/// The schedule-list DTO: the effective event's normalized fields plus the
/// overlay-resolved attendance/listening notes and policy/decision. Used by
/// `get_schedule` so each event carries `attendanceNote` and `conflictState`
/// (per the design's schedule DTO contract).
Map<String, Object?> _enrichedEventDto(
  EffectiveEvent event,
  EffectiveEventRecord record,
  AgentToolContext context,
) {
  final dto = _eventDto(event, context);
  dto['attendancePolicy'] = record.attendance.name;
  dto['attendanceDecision'] = record.attendanceDecision.name;
  dto['listeningMode'] = record.listeningMode.name;
  if (record.attendanceNote != null) {
    dto['attendanceNote'] = record.attendanceNote;
  }
  if (record.listeningNote != null) {
    dto['listeningNote'] = record.listeningNote;
  }
  return dto;
}

/// A pending event review: an event whose end has passed AND that still has an
/// undecided attendance decision (the user has not yet said go/skip) OR a
/// confirmed conflict with no user note attached. See design §10: the Agent
/// explains attendance/listening/notes, but personal-event completion is
/// confirmed by the user, so "pending" means awaiting that user input.
class _PendingEventReview {
  const _PendingEventReview({required this.record, required this.reasons});

  final EffectiveEventRecord record;
  final List<String> reasons;
}

Future<List<_PendingEventReview>> _pendingEventReviews(
  AgentLocalDataGateway gateway,
  String accountId,
  BeijingClock clock,
) async {
  final now = clock.now();
  final records = await gateway.allEventRecords(accountId);
  final pending = <_PendingEventReview>[];
  for (final record in records) {
    if (record.hidden) continue;
    final event = record.source;
    final hasEnded = event.allDay
        ? (event.endDateExclusive != null &&
            !DateTime.parse(event.endDateExclusive!).isAfter(now))
        : (event.endAt != null &&
            !_beijingFromEpoch(event.endAt!).isAfter(now));
    if (!hasEnded) continue;
    final reasons = <String>[];
    if (record.attendanceDecision == AttendanceDecision.undecided) {
      reasons.add('attendance_undecided');
    }
    if (event.type == 'course' &&
        record.listeningMode == ListeningMode.unknown) {
      reasons.add('listening_undecided');
    }
    if (reasons.isNotEmpty) {
      pending.add(_PendingEventReview(record: record, reasons: reasons));
    }
  }
  return pending;
}

/// Converts an epoch-millisecond timestamp (stored UTC) to a Beijing-naive
/// [DateTime], matching `EffectiveEventRepository._beijingDateTime`.
DateTime _beijingFromEpoch(int ms) {
  final shifted = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)
      .add(const Duration(hours: 8));
  return DateTime(
    shifted.year,
    shifted.month,
    shifted.day,
    shifted.hour,
    shifted.minute,
    shifted.second,
  );
}

// ===========================================================================
// Tool: get_schedule
// ===========================================================================

class GetScheduleTool implements AgentTool {
  const GetScheduleTool(this._gateway);
  final AgentLocalDataGateway _gateway;

  @override
  String get name => 'get_schedule';

  @override
  String get description =>
      'List the effective schedule events for the current account within an '
      'optional date range (default: today through the next 6 days). Returns '
      'run-local refs (not raw ids), normalized titles/times/locations, and '
      'the authoritative conflict state for each event.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'from': {
            'type': 'string',
            'description': 'Start date (YYYY-MM-DD), inclusive. Beijing time.',
          },
          'through': {
            'type': 'string',
            'description': 'End date (YYYY-MM-DD), inclusive. Beijing time.',
          },
        },
      };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final parsed = _parseRange(
      arguments['from'] as String?,
      arguments['through'] as String?,
      context.clock,
    );
    if (parsed.error != null) {
      return AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: parsed.error,
      );
    }
    final range = parsed.range!;
    final events = await _gateway.displayEvents(context.accountId);
    final inRange =
        events.where((e) => _eventInRange(e, range)).toList(growable: false);
    if (inRange.length > agentEventLimit) {
      return _tooLarge(
        'events',
        inRange.length,
        agentEventLimit,
        'narrow the date range',
      );
    }
    final dtos = <Map<String, Object?>>[];
    final references = <AgentToolReference>[];
    for (final event in inRange) {
      // Fetch the overlay-resolved record to surface attendance/listening
      // notes alongside the conflict flag (the brief's schedule DTO carries
      // attendanceNote and conflictState per event).
      final record = await _gateway.eventById(context.accountId, event.id);
      dtos.add(_enrichedEventDto(event, record, context));
      final ref = context.references.bind(kind: 'event', localId: event.id);
      references.add(
        AgentToolReference(kind: 'event', ref: ref, localId: event.id),
      );
    }
    return AgentToolResult(
      payload: {
        'from': _formatDate(range.from),
        'through': _formatDate(range.through),
        'events': dtos,
      },
      references: references,
    );
  }
}

// ===========================================================================
// Tool: get_event_details
// ===========================================================================

class GetEventDetailsTool implements AgentTool {
  const GetEventDetailsTool(this._gateway);
  final AgentLocalDataGateway _gateway;

  @override
  String get name => 'get_event_details';

  @override
  String get description =>
      'Fetch full details for a single schedule event by its run-local ref: '
      'overlay-resolved title/location, attendance policy/decision/outcome, '
      'listening mode, user notes, and attendance/listening notes.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'ref': {
            'type': 'string',
            'description': 'The run-local ref_* token for the event.',
          },
        },
        'required': ['ref'],
      };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final ref = arguments['ref'] as String?;
    if (ref == null) {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'invalid_arguments',
      );
    }
    final eventId = context.references.resolve(ref: ref, kind: 'event');
    if (eventId == null) {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'reference_not_found',
      );
    }
    final record = await _gateway.eventById(context.accountId, eventId);
    final event = record.source;
    final dto = <String, Object?>{
      'ref': ref,
      'title': record.displayTitle,
      'allDay': event.allDay,
      'eventType': event.type,
      'importance': record.importance,
      'hidden': record.hidden,
      'attendancePolicy': record.attendance.name,
      'attendanceDecision': record.attendanceDecision.name,
      'attendanceOutcome': record.attendanceOutcome.name,
      'listeningMode': record.listeningMode.name,
    };
    if (record.displayLocation != null) dto['location'] = record.displayLocation;
    if (record.attendanceNote != null) {
      dto['attendanceNote'] = record.attendanceNote;
    }
    if (record.listeningNote != null) {
      dto['listeningNote'] = record.listeningNote;
    }
    if (record.userNotes != null) dto['userNotes'] = record.userNotes;
    if (event.allDay) {
      dto['startDate'] = _formatDate(DateTime.parse(event.startDate!));
      dto['endDateExclusive'] = _formatDate(DateTime.parse(event.endDateExclusive!));
    } else {
      dto['startAt'] = _formatDateTime(_beijingFromEpoch(event.startAt!));
      dto['endAt'] = _formatDateTime(_beijingFromEpoch(event.endAt!));
    }
    // Conflict state for this event: re-derive from the effective display set
    // so the flag stays authoritative (SQL-computed). Fall back to not_conflict
    // if the event is no longer in the display set.
    final display = await _gateway.displayEvents(context.accountId);
    final match = display.where((e) => e.id == eventId).firstOrNull;
    dto['conflictState'] =
        match != null ? _conflictStateString(match) : 'not_conflict';
    return AgentToolResult(
      payload: dto,
      references: [
        AgentToolReference(kind: 'event', ref: ref, localId: eventId),
      ],
    );
  }
}

// ===========================================================================
// Tool: get_free_time
// ===========================================================================

class GetFreeTimeTool implements AgentTool {
  const GetFreeTimeTool(this._gateway);
  final AgentLocalDataGateway _gateway;

  @override
  String get name => 'get_free_time';

  @override
  String get description =>
      'Find free (unoccupied) time gaps within a date range, bounded by the '
      'USTC daily grid (07:00-24:00 Beijing). Unions occupied intervals from '
      'timed events; does not classify conflicts.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'from': {'type': 'string', 'description': 'Start date (YYYY-MM-DD).'},
          'through': {
            'type': 'string',
            'description': 'End date (YYYY-MM-DD).',
          },
        },
      };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final parsed = _parseRange(
      arguments['from'] as String?,
      arguments['through'] as String?,
      context.clock,
    );
    if (parsed.error != null) {
      return AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: parsed.error,
      );
    }
    final range = parsed.range!;
    final events = await _gateway.displayEvents(context.accountId);
    if (events.length > agentEventLimit) {
      return _tooLarge('events', events.length, agentEventLimit, 'narrow the date range');
    }
    final timed = events
        .where((e) => !e.allDay && _eventInRange(e, range))
        .toList();
    final gaps = <Map<String, Object?>>[];
    for (var dayOffset = 0; dayOffset < range.dayCount; dayOffset++) {
      final day = range.from.add(Duration(days: dayOffset));
      final dayStart = DateTime(
        day.year,
        day.month,
        day.day,
        UstcPeriods.dayStartMinutes ~/ 60,
        UstcPeriods.dayStartMinutes % 60,
      );
      final dayEnd = DateTime(
        day.year,
        day.month,
        day.day,
        UstcPeriods.dayEndMinutes ~/ 60,
        UstcPeriods.dayEndMinutes % 60,
      );
      final dayEvents = timed.where((e) {
        final s = e.startAt!;
        return s.year == day.year && s.month == day.month && s.day == day.day;
      }).toList()
        ..sort((a, b) => a.startAt!.compareTo(b.startAt!));
      var cursor = dayStart;
      for (final event in dayEvents) {
        final start = event.startAt!;
        final end = event.endAt!;
        if (end.isAfter(cursor) && start.isAfter(cursor) &&
            start.isBefore(dayEnd)) {
          gaps.add({
            'date': _formatDate(day),
            'startAt': _formatDateTime(cursor),
            'endAt': _formatDateTime(start.isBefore(dayEnd) ? start : dayEnd),
          });
        }
        if (end.isAfter(cursor)) cursor = end.isAfter(dayEnd) ? dayEnd : end;
        if (!cursor.isBefore(dayEnd)) break;
      }
      if (cursor.isBefore(dayEnd)) {
        gaps.add({
          'date': _formatDate(day),
          'startAt': _formatDateTime(cursor),
          'endAt': _formatDateTime(dayEnd),
        });
      }
    }
    return AgentToolResult(payload: {'gaps': gaps});
  }
}

// ===========================================================================
// Tool: get_pending_event_reviews
// ===========================================================================

class GetPendingEventReviewsTool implements AgentTool {
  const GetPendingEventReviewsTool(this._gateway);
  final AgentLocalDataGateway _gateway;

  @override
  String get name => 'get_pending_event_reviews';

  @override
  String get description =>
      'List events that have ended and still need user input: an undecided '
      'attendance decision (go/skip) or, for courses, an undecided listening '
      'mode. The Agent explains these so the user can confirm what happened.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {},
      };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final pending =
        await _pendingEventReviews(_gateway, context.accountId, context.clock);
    if (pending.length > agentEventLimit) {
      return _tooLarge(
        'pending events',
        pending.length,
        agentEventLimit,
        'review older events separately',
      );
    }
    final dtos = <Map<String, Object?>>[];
    final references = <AgentToolReference>[];
    for (final item in pending) {
      final record = item.record;
      final event = record.source;
      final ref = context.references.bind(kind: 'event', localId: event.id);
      final dto = <String, Object?>{
        'ref': ref,
        'title': record.displayTitle,
        'eventType': event.type,
        'reasons': item.reasons,
        'attendanceDecision': record.attendanceDecision.name,
      };
      if (event.allDay) {
        dto['startDate'] = _formatDate(DateTime.parse(event.startDate!));
      } else {
        dto['startAt'] = _formatDateTime(_beijingFromEpoch(event.startAt!));
      }
      if (record.attendanceNote != null) {
        dto['attendanceNote'] = record.attendanceNote;
      }
      dtos.add(dto);
      references.add(
        AgentToolReference(kind: 'event', ref: ref, localId: event.id),
      );
    }
    return AgentToolResult(payload: {'pending': dtos}, references: references);
  }
}

// ===========================================================================
// Tool: get_conflicts
// ===========================================================================

class GetConflictsTool implements AgentTool {
  const GetConflictsTool(this._gateway);
  final AgentLocalDataGateway _gateway;

  @override
  String get name => 'get_conflicts';

  @override
  String get description =>
      'List schedule events that have a confirmed conflict (per the '
      'authoritative SQL conflict flag) within an optional date range. Each '
      'entry carries its run-local ref and conflict state.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'from': {'type': 'string'},
          'through': {'type': 'string'},
        },
      };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final parsed = _parseRange(
      arguments['from'] as String?,
      arguments['through'] as String?,
      context.clock,
    );
    if (parsed.error != null) {
      return AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: parsed.error,
      );
    }
    final range = parsed.range!;
    final events = await _gateway.displayEvents(context.accountId);
    final conflicts = events
        .where((e) => e.hasConfirmedConflict && _eventInRange(e, range))
        .toList(growable: false);
    if (conflicts.length > agentEventLimit) {
      return _tooLarge('conflicts', conflicts.length, agentEventLimit, 'narrow the date range');
    }
    final dtos = conflicts.map((e) => _eventDto(e, context)).toList(growable: false);
    final references = <AgentToolReference>[];
    for (final e in conflicts) {
      final ref = context.references.bind(kind: 'event', localId: e.id);
      references.add(AgentToolReference(kind: 'event', ref: ref, localId: e.id));
    }
    return AgentToolResult(
      payload: {
        'from': _formatDate(range.from),
        'through': _formatDate(range.through),
        'conflicts': dtos,
      },
      references: references,
    );
  }
}

// ===========================================================================
// Tool: get_tasks
// ===========================================================================

class GetTasksTool implements AgentTool {
  const GetTasksTool(this._gateway);
  final AgentLocalDataGateway _gateway;

  @override
  String get name => 'get_tasks';

  @override
  String get description =>
      'List tasks for the current account with their derived planning/deadline/'
      'confirmation state (computed via projectTask). Returns run-local refs, '
      'not raw ids.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'state': {
            'type': 'string',
            'description':
                'Optional filter: active | blocked | completed | cancelled.',
          },
        },
      };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final stateFilter = arguments['state'] as String?;
    final tasks = await _gateway.tasks(context.accountId);
    final filtered = stateFilter == null
        ? tasks
        : tasks.where((t) => t.state.storage == stateFilter).toList();
    if (filtered.length > agentTaskLimit) {
      return _tooLarge('tasks', filtered.length, agentTaskLimit, 'filter by state');
    }
    final now = context.clock.now();
    final dtos = <Map<String, Object?>>[];
    final references = <AgentToolReference>[];
    for (final task in filtered) {
      final blocks = await _gateway.planBlocksForTask(context.accountId, task.id);
      final snapshots = blocks
          .map(
            (b) => PlanBlockSnapshot(
              state: _blockProjectionState(b.status),
              endAt: b.endAt,
            ),
          )
          .toList(growable: false);
      final projection = projectTask(task, now, planBlocks: snapshots);
      final ref = context.references.bind(kind: 'task', localId: task.id);
      final dto = <String, Object?>{
        'ref': ref,
        'title': task.title,
        'state': task.state.storage,
        'importance': task.importance.storage,
        'planning': projection.planning.name,
        'deadline': projection.deadline.name,
        'confirmation': projection.confirmation.name,
      };
      if (task.description != null) dto['description'] = task.description;
      if (task.userNotes != null) dto['userNotes'] = task.userNotes;
      if (task.blockedReason != null) dto['blockedReason'] = task.blockedReason;
      if (task.deadlineAt != null) {
        dto['deadlineAt'] = _formatDateTime(task.deadlineAt!);
      }
      if (task.estimatedMinutes != null) {
        dto['estimatedMinutes'] = task.estimatedMinutes;
      }
      dtos.add(dto);
      references.add(AgentToolReference(kind: 'task', ref: ref, localId: task.id));
    }
    return AgentToolResult(payload: {'tasks': dtos}, references: references);
  }
}

// ===========================================================================
// Tool: get_task_details
// ===========================================================================

class GetTaskDetailsTool implements AgentTool {
  const GetTaskDetailsTool(this._gateway);
  final AgentLocalDataGateway _gateway;

  @override
  String get name => 'get_task_details';

  @override
  String get description =>
      'Fetch full details for a single task by its run-local ref, including '
      'its derived projection and linked plan blocks.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'ref': {'type': 'string', 'description': 'The run-local task ref_*.'},
        },
        'required': ['ref'],
      };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final ref = arguments['ref'] as String?;
    if (ref == null) {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'invalid_arguments',
      );
    }
    final taskId = context.references.resolve(ref: ref, kind: 'task');
    if (taskId == null) {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'reference_not_found',
      );
    }
    final task = await _gateway.taskById(context.accountId, taskId);
    final blocks = await _gateway.planBlocksForTask(context.accountId, taskId);
    final now = context.clock.now();
    final snapshots = blocks
        .map(
          (b) => PlanBlockSnapshot(
            state: _blockProjectionState(b.status),
            endAt: b.endAt,
          ),
        )
        .toList(growable: false);
    final projection = projectTask(task, now, planBlocks: snapshots);
    final dto = <String, Object?>{
      'ref': ref,
      'title': task.title,
      'state': task.state.storage,
      'importance': task.importance.storage,
      'planning': projection.planning.name,
      'deadline': projection.deadline.name,
      'confirmation': projection.confirmation.name,
      'tags': task.tags,
    };
    if (task.description != null) dto['description'] = task.description;
    if (task.userNotes != null) dto['userNotes'] = task.userNotes;
    if (task.blockedReason != null) dto['blockedReason'] = task.blockedReason;
    if (task.deadlineAt != null) {
      dto['deadlineAt'] = _formatDateTime(task.deadlineAt!);
    }
    if (task.estimatedMinutes != null) {
      dto['estimatedMinutes'] = task.estimatedMinutes;
    }
    final blockDtos = <Map<String, Object?>>[];
    for (final b in blocks) {
      final bRef = context.references.bind(kind: 'planblock', localId: b.id);
      blockDtos.add(_planBlockDto(b, bRef, now));
    }
    dto['planBlocks'] = blockDtos;
    return AgentToolResult(
      payload: dto,
      references: [
        AgentToolReference(kind: 'task', ref: ref, localId: taskId),
        ...blocks.map(
          (b) => AgentToolReference(
            kind: 'planblock',
            ref: context.references.bind(kind: 'planblock', localId: b.id),
            localId: b.id,
          ),
        ),
      ],
    );
  }
}

// ===========================================================================
// Tool: get_plan_blocks
// ===========================================================================

class GetPlanBlocksTool implements AgentTool {
  const GetPlanBlocksTool(this._gateway);
  final AgentLocalDataGateway _gateway;

  @override
  String get name => 'get_plan_blocks';

  @override
  String get description =>
      'List plan blocks for the current account, optionally filtered by task '
      'ref. Each block carries its status and awaiting-review state.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'taskRef': {
            'type': 'string',
            'description': 'Optional run-local task ref to filter by.',
          },
        },
      };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final taskRef = arguments['taskRef'] as String?;
    List<PlanBlockItem> blocks;
    if (taskRef != null) {
      final taskId = context.references.resolve(ref: taskRef, kind: 'task');
      if (taskId == null) {
        return const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'reference_not_found',
        );
      }
      blocks = await _gateway.planBlocksForTask(context.accountId, taskId);
    } else {
      blocks = await _gateway.allPlanBlocks(context.accountId);
    }
    if (blocks.length > agentPlanBlockLimit) {
      return _tooLarge('plan blocks', blocks.length, agentPlanBlockLimit, 'filter by taskRef');
    }
    final now = context.clock.now();
    final dtos = <Map<String, Object?>>[];
    final references = <AgentToolReference>[];
    for (final b in blocks) {
      final bRef = context.references.bind(kind: 'planblock', localId: b.id);
      dtos.add(_planBlockDto(b, bRef, now));
      references.add(
        AgentToolReference(kind: 'planblock', ref: bRef, localId: b.id),
      );
    }
    return AgentToolResult(payload: {'planBlocks': dtos}, references: references);
  }
}

// ===========================================================================
// Tool: get_pending_planblock_reviews
// ===========================================================================

class GetPendingPlanBlockReviewsTool implements AgentTool {
  const GetPendingPlanBlockReviewsTool(this._gateway);
  final AgentLocalDataGateway _gateway;

  @override
  String get name => 'get_pending_planblock_reviews';

  @override
  String get description =>
      'List accepted plan blocks whose end time has passed (awaiting the '
      'user\'s done/skipped review), computed via projectPlanBlock.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {},
      };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final all = await _gateway.allPlanBlocks(context.accountId);
    final now = context.clock.now();
    final pending = all
        .where((b) => projectPlanBlock(b, now).awaitingReview)
        .toList(growable: false);
    if (pending.length > agentPlanBlockLimit) {
      return _tooLarge('pending plan blocks', pending.length, agentPlanBlockLimit, 'review older blocks separately');
    }
    final dtos = <Map<String, Object?>>[];
    final references = <AgentToolReference>[];
    for (final b in pending) {
      final bRef = context.references.bind(kind: 'planblock', localId: b.id);
      final dto = _planBlockDto(b, bRef, now);
      dto['taskRef'] =
          context.references.bind(kind: 'task', localId: b.taskId);
      dtos.add(dto);
      references.add(
        AgentToolReference(kind: 'planblock', ref: bRef, localId: b.id),
      );
    }
    return AgentToolResult(payload: {'pending': dtos}, references: references);
  }
}

// ===========================================================================
// Tool: get_sync_status
// ===========================================================================

class GetSyncStatusTool implements AgentTool {
  const GetSyncStatusTool(this._gateway);
  final AgentLocalDataGateway _gateway;

  @override
  String get name => 'get_sync_status';

  @override
  String get description =>
      'Report the local sync state for each data source (教务 and 青年日程): '
      'current phase, last attempt/success time, and a desensitized result '
      'code. Read-only; never starts a sync.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {},
      };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final sources = <Map<String, Object?>>[];
    for (final source in SyncSource.values) {
      final state = await _gateway.syncState(context.accountId, source);
      final dto = <String, Object?>{
        'source': source.storage,
        'phase': state.phase.name,
      };
      if (state.lastAttemptAt != null) {
        dto['lastAttemptAt'] = _formatDateTime(state.lastAttemptAt!);
      }
      if (state.lastSuccessfulAt != null) {
        dto['lastSuccessfulAt'] = _formatDateTime(state.lastSuccessfulAt!);
      }
      if (state.resultCode != null) {
        dto['resultCode'] = state.resultCode;
      }
      sources.add(dto);
    }
    return AgentToolResult(payload: {'sources': sources});
  }
}

// ===========================================================================
// Tool: get_safe_action_history
// ===========================================================================

class GetSafeActionHistoryTool implements AgentTool {
  const GetSafeActionHistoryTool(this._gateway);
  final AgentLocalDataGateway _gateway;

  @override
  String get name => 'get_safe_action_history';

  @override
  String get description =>
      'List recent safe action-log entries for the current account (max 50, '
      'account-scoped in the database, sanitized). Returns only the safe '
      'summary and categories (source/actionType/result/occurredAt).';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'source': {'type': 'string'},
          'actionType': {'type': 'string'},
          'result': {'type': 'string'},
        },
      };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final filter = HistoryFilter(
      source: arguments['source'] as String?,
      actionType: arguments['actionType'] as String?,
      result: arguments['result'] as String?,
    );
    final entries = await _gateway.history(context.accountId, filter: filter);
    // The 50-row cap is already enforced inside the DB query.
    final dtos = entries
        .map(
          (e) => <String, Object?>{
            'source': e.source,
            'actionType': e.actionType,
            'result': e.result,
            'safeSummary': e.safeSummary,
            'occurredAt': e.occurredAt,
          },
        )
        .toList(growable: false);
    return AgentToolResult(payload: {'history': dtos});
  }
}

// ===========================================================================
// Helpers
// ===========================================================================

PlanBlockProjectionState _blockProjectionState(PlanBlockStatus status) =>
    switch (status) {
      PlanBlockStatus.suggested => PlanBlockProjectionState.suggested,
      PlanBlockStatus.accepted => PlanBlockProjectionState.accepted,
      PlanBlockStatus.done => PlanBlockProjectionState.done,
      PlanBlockStatus.skipped => PlanBlockProjectionState.skipped,
      PlanBlockStatus.rescheduled => PlanBlockProjectionState.rescheduled,
      PlanBlockStatus.cancelled => PlanBlockProjectionState.cancelled,
    };

Map<String, Object?> _planBlockDto(
  PlanBlockItem block,
  String ref,
  DateTime now,
) {
  final projection = projectPlanBlock(block, now);
  final dto = <String, Object?>{
    'ref': ref,
    'startAt': _formatDateTime(block.startAt),
    'endAt': _formatDateTime(block.endAt),
    'status': block.status.storage,
    'locked': block.locked,
    'awaitingReview': projection.awaitingReview,
  };
  if (block.title != null) dto['title'] = block.title;
  if (block.reviewNote != null) dto['reviewNote'] = block.reviewNote;
  return dto;
}

AgentToolResult _tooLarge(
  String noun,
  int count,
  int limit,
  String guidance,
) =>
    AgentToolResult(
      status: AgentToolStatus.error,
      errorCode: 'result_too_large',
      payload: {
        'guidance': 'Too many $noun ($count > $limit). Please $guidance '
            'and retry.',
      },
    );

// ===========================================================================
// Payload builders (the OutboundPrivacyFilter allowlists)
// ===========================================================================

/// Builds the per-tool payload builders the registry needs. Each builder is the
/// single allowlist that decides which raw payload fields survive to the model.
/// Builders are intentionally minimal: only normalized, model-safe fields.
Map<String, ToolPayloadBuilder> agentToolPayloadBuilders() => {
      'get_schedule': (raw) => {
            'from': raw['from'],
            'through': raw['through'],
            'events': raw['events'],
            'guidance': raw['guidance'],
          },
      'get_event_details': (raw) => {
            'ref': raw['ref'],
            'title': raw['title'],
            'allDay': raw['allDay'],
            'eventType': raw['eventType'],
            'importance': raw['importance'],
            'location': raw['location'],
            'startAt': raw['startAt'],
            'endAt': raw['endAt'],
            'startDate': raw['startDate'],
            'endDateExclusive': raw['endDateExclusive'],
            'attendancePolicy': raw['attendancePolicy'],
            'attendanceDecision': raw['attendanceDecision'],
            'attendanceOutcome': raw['attendanceOutcome'],
            'attendanceNote': raw['attendanceNote'],
            'listeningMode': raw['listeningMode'],
            'listeningNote': raw['listeningNote'],
            'userNotes': raw['userNotes'],
            'conflictState': raw['conflictState'],
            'hidden': raw['hidden'],
          },
      'get_free_time': (raw) => {'gaps': raw['gaps'], 'guidance': raw['guidance']},
      'get_pending_event_reviews': (raw) =>
          {'pending': raw['pending'], 'guidance': raw['guidance']},
      'get_conflicts': (raw) => {
            'from': raw['from'],
            'through': raw['through'],
            'conflicts': raw['conflicts'],
            'guidance': raw['guidance'],
          },
      'get_tasks': (raw) => {'tasks': raw['tasks'], 'guidance': raw['guidance']},
      'get_task_details': (raw) => {
            'ref': raw['ref'],
            'title': raw['title'],
            'state': raw['state'],
            'importance': raw['importance'],
            'description': raw['description'],
            'userNotes': raw['userNotes'],
            'blockedReason': raw['blockedReason'],
            'deadlineAt': raw['deadlineAt'],
            'estimatedMinutes': raw['estimatedMinutes'],
            'tags': raw['tags'],
            'planning': raw['planning'],
            'deadline': raw['deadline'],
            'confirmation': raw['confirmation'],
            'planBlocks': raw['planBlocks'],
          },
      'get_plan_blocks': (raw) =>
          {'planBlocks': raw['planBlocks'], 'guidance': raw['guidance']},
      'get_pending_planblock_reviews': (raw) =>
          {'pending': raw['pending'], 'guidance': raw['guidance']},
      'get_sync_status': (raw) => {'sources': raw['sources']},
      'get_safe_action_history': (raw) => {'history': raw['history']},
      // External (Task 9) tools: minimal allowlists. Only normalized fields
      // and ref_* tokens survive; no raw ids, no URLs (the envelope's trusted
      // references are not surfaced to the model).
      'search_current_second_class_activities': (raw) => {
            'activities': raw['activities'],
            'generatedAt': raw['generatedAt'],
            'jobId': raw['jobId'],
          },
  'search_icourse': (raw) => {
    'query': raw['query'],
    'results': raw['results'],
    'generatedAt': raw['generatedAt'],
  },
      'search_campus_catalog': (raw) => {
            'query': raw['query'],
            'results': raw['results'],
            'generatedAt': raw['generatedAt'],
          },
      'read_campus_detail': (raw) => {
            'details': raw['details'],
            'generatedAt': raw['generatedAt'],
            'guidance': raw['guidance'],
          },
    };

/// Builds the full list of local read-only Agent tools backed by [gateway].
List<AgentTool> localAgentTools(AgentLocalDataGateway gateway) => [
      GetScheduleTool(gateway),
      GetEventDetailsTool(gateway),
      GetFreeTimeTool(gateway),
      GetPendingEventReviewsTool(gateway),
      GetConflictsTool(gateway),
      GetTasksTool(gateway),
      GetTaskDetailsTool(gateway),
      GetPlanBlocksTool(gateway),
      GetPendingPlanBlockReviewsTool(gateway),
      GetSyncStatusTool(gateway),
      GetSafeActionHistoryTool(gateway),
    ];

// ===========================================================================
// External tools (Task 9): backed by the Python Bridge query endpoints.
// ===========================================================================

/// The maximum number of campus entries `read_campus_detail` will read per
/// call (the brief's hard limit).
const int campusDetailEntryLimit = 3;

/// The maximum number of discovered-link ids `read_campus_detail` will follow
/// per call. The brief requires "one discovered-link level" — a DEPTH bound,
/// not a breadth bound: a detail page may surface candidate links, and the
/// tool may follow at most ONE of them. The Python `read_detail` reader does
/// not recurse into links discovered within followed pages (it parses each
/// followed page with `_parse_followed_html`, which sets `depth: 1` and
/// extracts no further links — see `src/ustc_assistant/sources/campus/detail.py`),
/// so following one link is exactly one level deep. Capping at 1 keeps the
/// Dart tool's contract faithful to "one discovered-link level" regardless of
/// how many entries are read.
const int campusDetailFollowLinkLimit = 1;

/// Collects the terminal event (or needs-login pause) from a [QuerySourceGateway]
/// stream, cancelling the subscription once a terminal/pause event arrives.
/// Returns the collected events.
Future<List<SourceQueryEvent>> _collectQueryEvents(
  Stream<SourceQueryEvent> stream,
) async {
  final events = <SourceQueryEvent>[];
  await for (final event in stream) {
    events.add(event);
    if (event is SourceQueryCompleted ||
        event is SourceQueryFailed ||
        event is SourceQueryNeedsLogin) {
      break;
    }
  }
  return events;
}

// --- Tool: search_current_second_class_activities -------------------------

/// Resolves the protected school username for a tool context's account. The
/// composition layer (Task 11) injects a real resolver backed by
/// `AccountService.usernameForSync`; tests inject a stub. The resolver never
/// exposes the password and never receives the model API Key.
typedef UsernameResolver = String Function(AgentToolContext context);

class SearchCurrentSecondClassActivitiesTool implements AgentTool {
  const SearchCurrentSecondClassActivitiesTool(
    this._gateway,
    this._usernameResolver,
  );
  final QuerySourceGateway _gateway;
  final UsernameResolver _usernameResolver;

  @override
  String get name => 'search_current_second_class_activities';

  @override
  String get description =>
      'Read the current second-class-activity (青年日程) enrolment snapshot for '
      'the signed-in account. Returns normalized activity titles, categories, '
      'and open/closed status. Read-only: cannot enrol or cancel an activity. '
      'May pause for an interactive login if the school session has expired; '
      'the user must explicitly resume.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {},
      };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    // The expectedUsername is resolved by the injected resolver (the
    // composition layer owns the protected username). The tool itself never
    // receives the password or the model API Key. The resolver is required at
    // the factory; this runtime guard makes a misconfigured (empty) username a
    // loud, safe failure rather than forwarding '' to the Bridge, which could
    // otherwise mask an account-mismatch bug.
    final expectedUsername = _usernameResolver(context);
    if (expectedUsername.isEmpty) {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'invalid_configuration',
      );
    }
    final request = YoungEnrolmentQueryRequest(
      accountId: context.accountId,
      expectedUsername: expectedUsername,
    );
    final events = await _collectQueryEvents(
      _gateway.execute(request, cancellation: context.cancellation),
    );
    for (final event in events) {
      if (event is SourceQueryNeedsLogin) {
        // Pause the run: return an error result with the jobId so the UI can
        // call gateway.resumeLogin(jobId, password:). The tool never
        // auto-resumes and never receives a password.
        return AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'needs_user_login',
          payload: {'jobId': event.jobId},
        );
      }
      if (event is SourceQueryFailed) {
        return AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: event.code,
          payload: {'jobId': event.jobId},
        );
      }
      if (event is SourceQueryCompleted) {
        return _mapYoungEnrolmentResult(event.result);
      }
    }
    return const AgentToolResult(
      status: AgentToolStatus.error,
      errorCode: 'query_failed',
    );
  }

  /// The expected username is not available on the tool context (which has no
}

AgentToolResult _mapYoungEnrolmentResult(QueryResultEnvelope envelope) {
  final data = envelope.data;
  final activitiesRaw = data['activities'];
  if (activitiesRaw is! List) {
    return AgentToolResult(
      payload: {
        'activities': const <Map<String, Object?>>[],
        'generatedAt': envelope.generatedAt,
      },
    );
  }
  final activities = <Map<String, Object?>>[];
  for (final raw in activitiesRaw) {
    if (raw is! Map<String, dynamic>) continue;
    activities.add({
      'name': raw['name'],
      'category': raw['category'],
      'status': raw['status'],
    });
  }
  return AgentToolResult(
    payload: {
      'activities': activities,
      'generatedAt': envelope.generatedAt,
    },
  );
}

// --- Tool: search_icourse -------------------------------------------------

class SearchIcourseTool implements AgentTool {
  const SearchIcourseTool(this._gateway, this._config);
  final QuerySourceGateway _gateway;
  final AgentConfigurationService _config;

  @override
  String get name => 'search_icourse';

  @override
  String get description =>
      'Search public iCourse (评课社区) course reviews by course name and '
      'optional teacher names. Returns normalized course summaries and review '
      'counts. Requires the user to have granted iCourse consent. Read-only.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'course': {
            'type': 'string',
            'description': 'The course name to search for.',
          },
          'teachers': {
            'type': 'array',
            'items': {'type': 'string'},
            'description':
                'Optional list of teacher names to narrow the search.',
          },
        },
        'required': ['course'],
      };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final snapshot = await _config.load(context.accountId);
    if (!snapshot.icourseConsent) {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'consent_required',
      );
    }
    final course = arguments['course'] as String?;
    if (course == null || course.trim().isEmpty) {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'invalid_arguments',
      );
    }
    final teachersRaw = arguments['teachers'];
    final teachers = teachersRaw is List
        ? teachersRaw.whereType<String>().toList(growable: false)
        : const <String>[];
    // SECURITY: send ONLY course + necessary teacher terms. No schedule
    // times, locations, user identity, or JW bundle. The request type itself
    // carries no such fields.
    final request = IcourseQueryRequest(course: course, teachers: teachers);
    final events = await _collectQueryEvents(
      _gateway.execute(request, cancellation: context.cancellation),
    );
    for (final event in events) {
      if (event is SourceQueryFailed) {
        return AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: event.code,
        );
      }
      if (event is SourceQueryCompleted) {
        return _mapIcourseResult(event.result);
      }
    }
    return const AgentToolResult(
      status: AgentToolStatus.error,
      errorCode: 'query_failed',
    );
  }
}

AgentToolResult _mapIcourseResult(QueryResultEnvelope envelope) {
  final data = envelope.data;
  return AgentToolResult(
    payload: {
      'query': _selectIcourseQuery(data['query']),
      'results': _selectIcourseResults(data['results']),
      'generatedAt': envelope.generatedAt,
    },
  );
}

Map<String, Object?>? _selectIcourseQuery(Object? value) {
  if (value is! Map<String, dynamic>) return null;
  return {
    if (value['mode'] is String) 'mode': value['mode'] as String,
    if (value['value'] is String) 'value': value['value'] as String,
    if (_selectIcourseStrings(value['teachers']).isNotEmpty)
      'teachers': _selectIcourseStrings(value['teachers']),
  };
}

List<Map<String, Object?>> _selectIcourseResults(Object? rawResults) {
  if (rawResults is! List) return const [];
  return [
    for (final raw in rawResults)
      if (raw is Map<String, dynamic>)
        {
          if (raw['name'] is String) 'name': raw['name'] as String,
          if (_selectIcourseStrings(raw['teachers']).isNotEmpty)
            'teachers': _selectIcourseStrings(raw['teachers']),
          if (_selectIcourseStrings(raw['terms']).isNotEmpty)
            'terms': _selectIcourseStrings(raw['terms']),
          if (raw['averageScore'] is num)
            'averageScore': raw['averageScore'] as num,
          if (raw['reviewCount'] is int)
            'reviewCount': raw['reviewCount'] as int,
          'aggregate': ?_selectIcourseStringFields(
            raw['aggregate'],
            const ['difficulty', 'homework', 'grading', 'gain'],
          ),
          'siteAiSummary': ?_selectIcourseStringFields(
            raw['siteAiSummary'],
            const ['text'],
          ),
          if (_selectIcourseReviews(raw['reviews']).isNotEmpty)
            'reviews': _selectIcourseReviews(raw['reviews']),
          if (_selectIcourseListFields(raw['teacherLinks'], const ['label'])
              .isNotEmpty)
            'teacherLinks': _selectIcourseListFields(
              raw['teacherLinks'],
              const ['label'],
            ),
          'ranking': ?_selectIcourseRanking(raw['ranking']),
          if (raw['relationStrength'] is String)
            'relationStrength': raw['relationStrength'] as String,
        },
  ];
}

List<String> _selectIcourseStrings(Object? value) {
  if (value is! List) return const [];
  return [for (final item in value) if (item is String) item];
}

Map<String, Object?>? _selectIcourseStringFields(
  Object? value,
  List<String> keys,
) {
  if (value is! Map<String, dynamic>) return null;
  final result = <String, Object?>{
    for (final key in keys)
      if (value[key] is String) key: value[key] as String,
  };
  return result.isEmpty ? null : result;
}

List<Map<String, Object?>> _selectIcourseListFields(Object? value, List<String> keys) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item is Map<String, dynamic>)
        {
          for (final key in keys)
            if (item[key] is String) key: item[key] as String,
        },
  ];
}

Map<String, Object?>? _selectIcourseRanking(Object? value) {
  if (value is! Map<String, dynamic>) return null;
  final result = <String, Object?>{
    if (value['score'] is num) 'score': value['score'] as num,
    if (_selectIcourseStrings(value['reasons']).isNotEmpty)
      'reasons': _selectIcourseStrings(value['reasons']),
  };
  return result.isEmpty ? null : result;
}

List<Map<String, Object?>> _selectIcourseReviews(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item is Map<String, dynamic>)
        {
          if (item['term'] is String) 'term': item['term'] as String,
          if (item['content'] is String) 'content': item['content'] as String,
          if (item['publishedAt'] is String)
            'publishedAt': item['publishedAt'] as String,
          if (item['updatedAt'] is String)
            'updatedAt': item['updatedAt'] as String,
          if (item['upvoteCount'] is int)
            'upvoteCount': item['upvoteCount'] as int,
          if (item['commentCount'] is int)
            'commentCount': item['commentCount'] as int,
          'dimensions': ?_selectIcourseStringFields(
            item['dimensions'],
            const ['difficulty', 'homework', 'grading', 'gain'],
          ),
        },
  ];
}

// --- Tool: search_campus_catalog ------------------------------------------

class SearchCampusCatalogTool implements AgentTool {
  const SearchCampusCatalogTool(this._gateway);
  final QuerySourceGateway _gateway;

  @override
  String get name => 'search_campus_catalog';

  @override
  String get description =>
      'Search the public campus catalog (通知公告/财务信息) for entries '
      'matching a free-text query. Returns run-local refs for each entry; use '
      'read_campus_detail with a ref to read the full entry. Read-only.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'The free-text search query.',
          },
          'limit': {
            'type': 'integer',
            'description':
                'Optional max results (1-100, default 20).',
          },
        },
        'required': ['query'],
      };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    final query = arguments['query'] as String?;
    if (query == null || query.trim().isEmpty) {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'invalid_arguments',
      );
    }
    var limit = 20;
    final limitArg = arguments['limit'];
    if (limitArg is int && limitArg >= 1 && limitArg <= 100) {
      limit = limitArg;
    }
    final request = CampusSearchQueryRequest(query: query, limit: limit);
    final events = await _collectQueryEvents(
      _gateway.execute(request, cancellation: context.cancellation),
    );
    for (final event in events) {
      if (event is SourceQueryFailed) {
        return AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: event.code,
        );
      }
      if (event is SourceQueryCompleted) {
        return _mapCampusSearchResult(event.result, context);
      }
    }
    return const AgentToolResult(
      status: AgentToolStatus.error,
      errorCode: 'query_failed',
    );
  }
}

AgentToolResult _mapCampusSearchResult(
  QueryResultEnvelope envelope,
  AgentToolContext context,
) {
  final data = envelope.data;
  final resultsRaw = data['results'];
  final dtos = <Map<String, Object?>>[];
  final references = <AgentToolReference>[];
  if (resultsRaw is List) {
    for (final raw in resultsRaw) {
      if (raw is! Map<String, dynamic>) continue;
      final entryId = raw['id'];
      if (entryId is! String) continue;
      // Bind a run-local ref for this catalog entry. The model gets the ref,
      // never the raw entryId.
      final ref = context.references.bind(kind: 'campus_entry', localId: entryId);
      dtos.add({
        'ref': ref,
        'source': raw['source'],
        'kind': raw['kind'],
        'title': raw['title'],
        'publishedAt': raw['publishedAt'],
      });
      references.add(
        AgentToolReference(kind: 'campus_entry', ref: ref, localId: entryId),
      );
    }
  }
  return AgentToolResult(
    payload: {
      'query': data['query'],
      'results': dtos,
      'generatedAt': envelope.generatedAt,
    },
    references: references,
  );
}

// --- Tool: read_campus_detail ---------------------------------------------

class ReadCampusDetailTool implements AgentTool {
  const ReadCampusDetailTool(this._gateway);
  final QuerySourceGateway _gateway;

  @override
  String get name => 'read_campus_detail';

  @override
  String get description =>
      'Read the full detail of a campus catalog entry by its run-local ref '
      '(from search_campus_catalog). Accepts up to 3 entry refs and follows at '
      'most one level of discovered links. Read-only; never enrols or cancels.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'ref': {
            'type': 'string',
            'description':
                'A single run-local ref_* for a campus entry (from '
                'search_campus_catalog).',
          },
          'refs': {
            'type': 'array',
            'items': {'type': 'string'},
            'description':
                'Optional list of up to 3 run-local refs for campus entries.',
          },
          'followLinkIds': {
            'type': 'array',
            'items': {'type': 'string'},
            'description':
                'Optional discovered-link ids to follow (at most one level).',
          },
        },
      };

  @override
  Future<AgentToolResult> execute(
    Map<String, Object?> arguments,
    AgentToolContext context,
  ) async {
    // Collect refs from either `ref` (single) or `refs` (list). The model
    // passes ref_* tokens, never raw ids or URLs.
    final refs = <String>[];
    final single = arguments['ref'];
    if (single is String) refs.add(single);
    final multi = arguments['refs'];
    if (multi is List) {
      refs.addAll(multi.whereType<String>());
    }
    if (refs.isEmpty) {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'invalid_arguments',
      );
    }
    if (refs.length > campusDetailEntryLimit) {
      return AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'result_too_large',
        payload: {
          'guidance': 'Too many entries (${refs.length} > '
              '$campusDetailEntryLimit). Read at most '
              '$campusDetailEntryLimit entries at a time.',
        },
      );
    }
    // Resolve each ref to an entryId. A ref not bound in this run (or bound
    // under a different kind) yields null → reference_not_found. A raw URL
    // passed as a ref also fails to resolve.
    final entryIds = <String>[];
    for (final ref in refs) {
      final entryId = context.references.resolve(
        ref: ref,
        kind: 'campus_entry',
      );
      if (entryId == null) {
        return const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'reference_not_found',
        );
      }
      entryIds.add(entryId);
    }
    // followLinkIds: "one discovered-link level" is a depth bound — at most
    // campusDetailFollowLinkLimit (1) followed link per call. More than that
    // is rejected before any gateway call.
    final followLinkIds = <String>[];
    final followRaw = arguments['followLinkIds'];
    if (followRaw is List) {
      followLinkIds.addAll(followRaw.whereType<String>());
    }
    if (followLinkIds.length > campusDetailFollowLinkLimit) {
      return AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'invalid_arguments',
        payload: {
          'guidance': 'At most $campusDetailFollowLinkLimit discovered link '
              'may be followed per call (one discovered-link level).',
        },
      );
    }
    // Issue one detail request per entry id (the Bridge takes a single
    // entryId per request). Results are merged.
    final details = <Map<String, Object?>>[];
    final references = <AgentToolReference>[];
    for (final entryId in entryIds) {
      final request = CampusDetailQueryRequest(
        entryIds: [entryId],
        followLinkIds: followLinkIds,
      );
      final events = await _collectQueryEvents(
        _gateway.execute(request, cancellation: context.cancellation),
      );
      for (final event in events) {
        if (event is SourceQueryFailed) {
          return AgentToolResult(
            status: AgentToolStatus.error,
            errorCode: event.code,
          );
        }
        if (event is SourceQueryCompleted) {
          final dto = _mapCampusDetail(event.result, context, entryId);
          details.add(dto);
          references.add(
            AgentToolReference(
              kind: 'campus_entry',
              ref: context.references.bind(kind: 'campus_entry', localId: entryId),
              localId: entryId,
            ),
          );
        }
      }
    }
    return AgentToolResult(
      payload: {
        'details': details,
        'generatedAt': eventsResultGeneratedAt(details),
      },
      references: references,
    );
  }
}

String? eventsResultGeneratedAt(List<Map<String, Object?>> details) {
  for (final d in details) {
    final g = d['generatedAt'];
    if (g is String) return g;
  }
  return null;
}

Map<String, Object?> _mapCampusDetail(
  QueryResultEnvelope envelope,
  AgentToolContext context,
  String entryId,
) {
  final data = envelope.data;
  final ref = context.references.bind(kind: 'campus_entry', localId: entryId);
  final dto = <String, Object?>{
    'ref': ref,
    'source': data['source'],
    'title': data['title'],
  };
  if (data['content'] != null) dto['content'] = data['content'];
  dto['generatedAt'] = envelope.generatedAt;
  return dto;
}

/// Builds the external read-only Agent tools backed by the [gateway] (Bridge
/// query endpoints) and the [config] service (iCourse consent). These plug
/// into the same registry as the local tools.
///
/// [usernameResolver] resolves the protected school username for the active
/// account; it is injected by the composition layer (Task 11) and is the only
/// credential-adjacent input the tools receive. The tools never receive the
/// model API Key or the school password. This parameter is REQUIRED: there is
/// no empty-string default, so a composition site that forgets to wire the
/// resolver fails to compile rather than silently sending an empty
/// `expectedUsername` to the Bridge.
List<AgentTool> externalAgentTools({
  required QuerySourceGateway gateway,
  required AgentConfigurationService config,
  required UsernameResolver usernameResolver,
}) {
  return [
    SearchCurrentSecondClassActivitiesTool(gateway, usernameResolver),
    SearchIcourseTool(gateway, config),
    SearchCampusCatalogTool(gateway),
    ReadCampusDetailTool(gateway),
  ];
}
