import '../core/agenda_contract.dart';
import '../core/agent_action_contract.dart';
import '../core/calendar_contract.dart';
import '../core/calendar_validation.dart';
import '../core/jw_academic_details.dart';
import 'calendar_projection.dart';

const _previewHorizonDays = 31;
const _previewConflictLimit = 5;
const _maxPlanChanges = 20;
const _beijingOffset = Duration(hours: 8);

/// Why a preview needs a qualification or stopped before the whole plan.
enum AgentPlanPreviewWarningCode {
  invalidWindow,
  invalidChange,
  unsupportedChange,
  tooManyChanges,
  undoUnavailable,
  recurringBeyondWindow,
  projectionTruncated,
  projectionFailed,
  deletedTaskBlocks,
  taskSummaryUnavailable,
}

final class AgentPlanPreviewWarning {
  const AgentPlanPreviewWarning(this.code, this.message);

  final AgentPlanPreviewWarningCode code;
  final String message;

  @override
  String toString() => 'AgentPlanPreviewWarning';
}

/// A bounded, display-safe overlap summary. Times are Beijing wall-clock text.
/// It intentionally carries no SQL identities, notes, or source credentials.
final class AgentPlanConflictSummary {
  const AgentPlanConflictSummary({
    required this.leftName,
    required this.rightName,
    required this.overlapStartBeijing,
    required this.overlapEndBeijing,
    required this.status,
  });

  final String leftName;
  final String rightName;
  final String overlapStartBeijing;
  final String overlapEndBeijing;
  final CalendarConflictStatus status;

  String get statusLabel => switch (status) {
    CalendarConflictStatus.conflict => '冲突',
    CalendarConflictStatus.notConflict => '已标记不冲突',
  };

  @override
  String toString() => 'AgentPlanConflictSummary';
}

/// Pure result of applying a proposed plan to an in-memory calendar snapshot.
/// The two Beijing window dates are UTC date components (not instants).
final class AgentPlanPreview {
  AgentPlanPreview({
    required this.windowFirstDayBeijing,
    required this.windowEndDayExclusiveBeijing,
    required this.complete,
    required this.freeConstraintViolated,
    required this.conflictSummaryTruncated,
    required List<AgentPlanPreviewWarning> warnings,
    required List<AgentPlanConflictSummary> actionConflicts,
    required List<AgentPlanConflictSummary> existingConflicts,
  }) : warnings = List.unmodifiable(warnings),
       actionConflicts = List.unmodifiable(actionConflicts),
       existingConflicts = List.unmodifiable(existingConflicts);

  final DateTime windowFirstDayBeijing;
  final DateTime windowEndDayExclusiveBeijing;
  final bool complete;

  /// Null means the bounded preview found no violation but cannot prove that
  /// the unexamined portion is clear. A known overlap is always true.
  final bool? freeConstraintViolated;
  final bool conflictSummaryTruncated;
  final List<AgentPlanPreviewWarning> warnings;
  final List<AgentPlanConflictSummary> actionConflicts;
  final List<AgentPlanConflictSummary> existingConflicts;

  @override
  String toString() => 'AgentPlanPreview';
}

/// Simulates only the supplied approved change shapes in memory. It never
/// grants write authority and never returns the predicted snapshot itself.
AgentPlanPreview previewAgentPlan(
  CalendarSnapshot snapshot,
  List<AgentLocalChange> changes,
  DateTime nowUtc,
) {
  final utcNow = nowUtc.toUtc();
  final shifted = utcNow.add(_beijingOffset);
  final firstDay = DateTime.utc(shifted.year, shifted.month, shifted.day);
  final endDay = firstDay.add(const Duration(days: _previewHorizonDays));
  final query = CalendarQuery(
    firstDay: firstDay,
    endDayExclusive: endDay,
    includeHidden: false,
    includeSkipped: false,
    limit: 500,
  );
  final warnings = <AgentPlanPreviewWarning>[];
  final warningCodes = <AgentPlanPreviewWarningCode>{};
  var complete = nowUtc.isUtc;

  void warn(AgentPlanPreviewWarningCode code) {
    if (!warningCodes.add(code)) return;
    final message = switch (code) {
      AgentPlanPreviewWarningCode.invalidWindow => '当前时间不是有效 UTC 时间，预演窗口仅供参考。',
      AgentPlanPreviewWarningCode.invalidChange => '操作与提供的日历快照不匹配，预演已在此处停止。',
      AgentPlanPreviewWarningCode.unsupportedChange => '包含无法安全预演的操作，后续操作未纳入结果。',
      AgentPlanPreviewWarningCode.tooManyChanges => '操作数量超出预演上限，未模拟该方案。',
      AgentPlanPreviewWarningCode.undoUnavailable =>
        '没有可供预演的撤销逆向数据，无法推断撤销后的空闲状态。',
      AgentPlanPreviewWarningCode.recurringBeyondWindow =>
        '预演只检查未来 31 天；窗口外仍有重复安排，不能据此判断后续无冲突。',
      AgentPlanPreviewWarningCode.projectionTruncated =>
        '日历投影达到检查上限，冲突结果可能不完整。',
      AgentPlanPreviewWarningCode.projectionFailed => '无法完整投影当前日历快照，预演结果不完整。',
      AgentPlanPreviewWarningCode.deletedTaskBlocks =>
        '删除父任务后，其关联时间块已从预演日历中隐藏。',
      AgentPlanPreviewWarningCode.taskSummaryUnavailable =>
        '快照未提供该任务名称；相关时间块使用通用名称，预演标记为不完整。',
    };
    warnings.add(AgentPlanPreviewWarning(code, message));
  }

  if (!nowUtc.isUtc) warn(AgentPlanPreviewWarningCode.invalidWindow);
  final baseWindow = _tryProject(snapshot, query);
  if (baseWindow == null) {
    warn(AgentPlanPreviewWarningCode.projectionFailed);
    return AgentPlanPreview(
      windowFirstDayBeijing: firstDay,
      windowEndDayExclusiveBeijing: endDay,
      complete: false,
      freeConstraintViolated: null,
      conflictSummaryTruncated: false,
      warnings: warnings,
      actionConflicts: const [],
      existingConflicts: const [],
    );
  }
  if (baseWindow.truncated || baseWindow.conflictsTruncated) {
    complete = false;
    warn(AgentPlanPreviewWarningCode.projectionTruncated);
  }
  if (!nowUtc.isUtc || changes.isEmpty || changes.length > _maxPlanChanges) {
    if (changes.isEmpty) warn(AgentPlanPreviewWarningCode.invalidChange);
    if (changes.length > _maxPlanChanges) {
      warn(AgentPlanPreviewWarningCode.tooManyChanges);
    }
    return _makePreview(
      firstDay: firstDay,
      endDay: endDay,
      complete: false,
      warnings: warnings,
      baseWindow: baseWindow,
      finalWindow: baseWindow,
      changedPersonalSeries: const {},
      changedIdentities: const {},
      freeConstraintIdentities: const {},
      conflictClassificationReliable: true,
    );
  }

  final builder = _PreviewBuilder(snapshot, changes, warn);
  for (final change in changes) {
    try {
      builder.apply(change);
    } on _StopPreview {
      complete = false;
      break;
    } on Object {
      warn(AgentPlanPreviewWarningCode.invalidChange);
      complete = false;
      break;
    }
  }

  if (builder.hasIncompleteAction) complete = false;
  if (_hasUnexaminedRecurrence(
    builder.snapshot,
    endDay,
    builder.changedPersonalSeries,
  )) {
    complete = false;
    warn(AgentPlanPreviewWarningCode.recurringBeyondWindow);
  }

  final finalWindow = _tryProject(builder.snapshot, query);
  if (finalWindow == null) {
    warn(AgentPlanPreviewWarningCode.projectionFailed);
    return _makePreview(
      firstDay: firstDay,
      endDay: endDay,
      complete: false,
      warnings: warnings,
      baseWindow: baseWindow,
      finalWindow: null,
      changedPersonalSeries: builder.changedPersonalSeries,
      changedIdentities: builder.changedIdentities,
      freeConstraintIdentities: builder.freeConstraintIdentities,
      conflictClassificationReliable: false,
    );
  }
  if (finalWindow.truncated || finalWindow.conflictsTruncated) {
    complete = false;
    warn(AgentPlanPreviewWarningCode.projectionTruncated);
  }

  return _makePreview(
    firstDay: firstDay,
    endDay: endDay,
    complete: complete,
    warnings: warnings,
    baseWindow: baseWindow,
    finalWindow: finalWindow,
    changedPersonalSeries: builder.changedPersonalSeries,
    changedIdentities: builder.changedIdentities,
    freeConstraintIdentities: builder.freeConstraintIdentities,
    conflictClassificationReliable: !baseWindow.conflictsTruncated,
  );
}

CalendarWindow? _tryProject(CalendarSnapshot snapshot, CalendarQuery query) {
  try {
    return const CalendarProjection().query(snapshot, query);
  } on Object {
    return null;
  }
}

bool _hasUnexaminedRecurrence(
  CalendarSnapshot snapshot,
  DateTime endDay,
  Set<int> changedSeries,
) => snapshot.personal.any((series) {
  if (!changedSeries.contains(series.localId)) return false;
  final draft = series.draft;
  if (!draft.weekly) return false;
  final until = draft.untilDay;
  return until == null || !until.isBefore(endDay);
});

AgentPlanPreview _makePreview({
  required DateTime firstDay,
  required DateTime endDay,
  required bool complete,
  required List<AgentPlanPreviewWarning> warnings,
  required CalendarWindow baseWindow,
  required CalendarWindow? finalWindow,
  required Set<int> changedPersonalSeries,
  required Set<CalendarIdentity> changedIdentities,
  required Set<CalendarIdentity> freeConstraintIdentities,
  required bool conflictClassificationReliable,
}) {
  final conflicts = finalWindow?.conflicts ?? const <CalendarConflict>[];
  final baselineKeys = {
    for (final conflict in baseWindow.conflicts) _conflictKey(conflict),
  };
  final introduced = <CalendarConflict>[];
  final remaining = <CalendarConflict>[];
  var touchedConflict = false;
  for (final conflict in conflicts) {
    final touchesPlan =
        _isChanged(
          conflict.left.reference.identity,
          changedPersonalSeries,
          changedIdentities,
        ) ||
        _isChanged(
          conflict.right.reference.identity,
          changedPersonalSeries,
          changedIdentities,
        );
    final touchesFreeConstraint =
        touchesPlan ||
        freeConstraintIdentities.contains(conflict.left.reference.identity) ||
        freeConstraintIdentities.contains(conflict.right.reference.identity);
    if (touchesFreeConstraint) touchedConflict = true;
    if (touchesPlan &&
        conflictClassificationReliable &&
        !baselineKeys.contains(_conflictKey(conflict))) {
      introduced.add(conflict);
    } else {
      remaining.add(conflict);
    }
  }

  final shownIntroduced = introduced.take(_previewConflictLimit).toList();
  final slotsLeft = _previewConflictLimit - shownIntroduced.length;
  final shownRemaining = remaining.take(slotsLeft).toList();
  final summaryTruncated =
      conflicts.length > _previewConflictLimit ||
      baseWindow.conflictsTruncated ||
      (finalWindow?.conflictsTruncated ?? false);
  final projectionComplete =
      complete &&
      !baseWindow.truncated &&
      !baseWindow.conflictsTruncated &&
      finalWindow != null &&
      !finalWindow.truncated &&
      !finalWindow.conflictsTruncated;
  final freeViolation = touchedConflict
      ? true
      : projectionComplete
      ? false
      : null;

  return AgentPlanPreview(
    windowFirstDayBeijing: firstDay,
    windowEndDayExclusiveBeijing: endDay,
    complete: projectionComplete,
    freeConstraintViolated: freeViolation,
    conflictSummaryTruncated: summaryTruncated,
    warnings: warnings,
    actionConflicts: [
      for (final conflict in shownIntroduced) _summary(conflict),
    ],
    existingConflicts: [
      for (final conflict in shownRemaining) _summary(conflict),
    ],
  );
}

bool _isChanged(
  CalendarIdentity identity,
  Set<int> changedPersonalSeries,
  Set<CalendarIdentity> changedIdentities,
) =>
    changedIdentities.contains(identity) ||
    (identity.kind == CalendarKind.personal &&
        changedPersonalSeries.contains(identity.localId));

({
  CalendarIdentity left,
  CalendarIdentity right,
  int start,
  int end,
  CalendarConflictStatus status,
})
_conflictKey(CalendarConflict conflict) {
  var left = conflict.left;
  var right = conflict.right;
  if (_compareIdentity(left.reference.identity, right.reference.identity) > 0) {
    final prior = left;
    left = right;
    right = prior;
  }
  final start = left.startsAtUtc.isAfter(right.startsAtUtc)
      ? left.startsAtUtc
      : right.startsAtUtc;
  final end = left.endsAtUtc.isBefore(right.endsAtUtc)
      ? left.endsAtUtc
      : right.endsAtUtc;
  return (
    left: left.reference.identity,
    right: right.reference.identity,
    start: start.microsecondsSinceEpoch,
    end: end.microsecondsSinceEpoch,
    status: conflict.status,
  );
}

int _compareIdentity(CalendarIdentity left, CalendarIdentity right) {
  var result = left.kind.index.compareTo(right.kind.index);
  if (result != 0) return result;
  result = left.localId.compareTo(right.localId);
  if (result != 0) return result;
  return left.ordinal.compareTo(right.ordinal);
}

AgentPlanConflictSummary _summary(CalendarConflict conflict) {
  final startsAtUtc =
      conflict.left.startsAtUtc.isAfter(conflict.right.startsAtUtc)
      ? conflict.left.startsAtUtc
      : conflict.right.startsAtUtc;
  final endsAtUtc = conflict.left.endsAtUtc.isBefore(conflict.right.endsAtUtc)
      ? conflict.left.endsAtUtc
      : conflict.right.endsAtUtc;
  return AgentPlanConflictSummary(
    leftName: conflict.left.title,
    rightName: conflict.right.title,
    overlapStartBeijing: _formatBeijing(startsAtUtc),
    overlapEndBeijing: _formatBeijing(endsAtUtc),
    status: conflict.status,
  );
}

String _formatBeijing(DateTime utc) {
  final value = utc.toUtc().add(_beijingOffset);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}

final class _StopPreview implements Exception {
  const _StopPreview();
}

final class _TaskState {
  _TaskState({
    required this.localId,
    required this.version,
    required this.title,
    required this.status,
    required this.summaryKnown,
  });

  final int localId;
  int version;
  String title;
  TaskStatus status;
  bool summaryKnown;
}

final class _PreviewBuilder {
  _PreviewBuilder(this._base, this._changes, this._warn)
    : _school = [..._base.school],
      _personal = [..._base.personal],
      _overrides = [..._base.overrides],
      _relations = [..._base.relations],
      _blocks = [..._base.planBlocks] {
    for (final block in _blocks) {
      final task = block.task;
      final status = block.taskStatus;
      if (task == null || status == null) continue;
      _tasks.putIfAbsent(
        task.localId,
        () => _TaskState(
          localId: task.localId,
          version: task.version,
          title: block.title,
          status: status,
          summaryKnown: true,
        ),
      );
    }
    _initializeNextIds();
  }

  final CalendarSnapshot _base;
  final List<AgentLocalChange> _changes;
  final void Function(AgentPlanPreviewWarningCode) _warn;
  final CalendarProjection _projection = const CalendarProjection();
  final List<CalendarOccurrence> _school;
  final List<PersonalSeries> _personal;
  final List<PersonalOccurrenceOverride> _overrides;
  final List<CalendarRelation> _relations;
  final List<CalendarOccurrence> _blocks;
  final Map<int, _TaskState> _tasks = {};
  final Map<String, int> _taskKeys = {};
  final Set<CalendarIdentity> changedIdentities = {};
  final Set<CalendarIdentity> freeConstraintIdentities = {};
  final Set<int> _closedTaskAggregateIds = {};
  final Set<int> _deletedPersonalSeriesIds = {};
  final Set<CalendarIdentity> _deletedBlockIdentities = {};
  bool hasIncompleteAction = false;
  int _nextPersonalId = 1;
  int _nextBlockId = 1;
  int _nextTaskId = 1;
  int _nextRelationId = 1;
  int _privateTaskKey = 0;

  Set<int> get changedPersonalSeries =>
      Set.unmodifiable(_changedPersonalSeries);
  final Set<int> _changedPersonalSeries = {};

  CalendarSnapshot get snapshot => CalendarSnapshot(
    context: _base.context,
    revision: _base.revision,
    school: _school,
    personal: _personal,
    overrides: _overrides,
    relations: _relations,
    planBlocks: _blocks,
  );

  Never _stop(AgentPlanPreviewWarningCode code) {
    _warn(code);
    hasIncompleteAction = true;
    throw const _StopPreview();
  }

  void _initializeNextIds() {
    var maxPersonal = _base.personal.fold<int>(
      0,
      (v, s) => v > s.localId ? v : s.localId,
    );
    var maxBlock = _base.planBlocks.fold<int>(0, (v, b) {
      final id = b.reference.identity.localId;
      return v > id ? v : id;
    });
    var maxTask = _base.planBlocks.fold<int>(0, (v, b) {
      final id = b.task?.localId ?? 0;
      return v > id ? v : id;
    });
    var maxRelation = _base.relations.fold<int>(0, (v, r) {
      final id = r.reference.localId;
      return v > id ? v : id;
    });
    for (final change in _changes) {
      if (change is AgentPersonalPatch) {
        maxPersonal = _max(maxPersonal, change.target.identity.localId);
      } else if (change is AgentBlockPatch) {
        maxBlock = _max(maxBlock, change.target.identity.localId);
      } else if (change is AgentTaskPatch) {
        maxTask = _max(maxTask, change.target.localId);
      } else if (change is AgentCalendarChange) {
        final intent = change.intent;
        switch (intent) {
          case UpdatePersonalSeries(:final target) ||
              UpdatePersonalOccurrence(:final target) ||
              SetPersonalOccurrenceState(:final target) ||
              DeletePersonalSeries(:final target) ||
              UpdateSchoolAnnotation(:final target) ||
              UpdatePlanBlock(:final target) ||
              SetPlanBlockStatus(:final target) ||
              DeletePlanBlock(:final target):
            if (target.identity.kind == CalendarKind.personal) {
              maxPersonal = _max(maxPersonal, target.identity.localId);
            } else if (target.identity.kind == CalendarKind.planBlock) {
              maxBlock = _max(maxBlock, target.identity.localId);
            }
          case UpdateTask(:final target) ||
              SetTaskStatus(:final target) ||
              DeleteTask(:final target) ||
              CreatePlanBlock(task: final target):
            maxTask = _max(maxTask, target.localId);
          case SaveCalendarRelation(:final left, :final right, :final existing):
            maxPersonal = _max(
              maxPersonal,
              left.identity.kind == CalendarKind.personal
                  ? left.identity.localId
                  : 0,
            );
            maxPersonal = _max(
              maxPersonal,
              right.identity.kind == CalendarKind.personal
                  ? right.identity.localId
                  : 0,
            );
            maxBlock = _max(
              maxBlock,
              left.identity.kind == CalendarKind.planBlock
                  ? left.identity.localId
                  : 0,
            );
            maxBlock = _max(
              maxBlock,
              right.identity.kind == CalendarKind.planBlock
                  ? right.identity.localId
                  : 0,
            );
            if (existing != null) {
              maxRelation = _max(maxRelation, existing.localId);
            }
          case DeleteCalendarRelation(:final target):
            maxRelation = _max(maxRelation, target.localId);
          case _:
        }
      }
    }
    _nextPersonalId = maxPersonal + 1;
    _nextBlockId = maxBlock + 1;
    _nextTaskId = maxTask + 1;
    _nextRelationId = maxRelation + 1;
  }

  int _max(int left, int right) => left > right ? left : right;

  void apply(AgentLocalChange change) {
    if (change is AgentCalendarChange) {
      _applyIntent(change.intent);
    } else if (change is AgentCreateTask) {
      _createTask(change.localKey, change.draft);
    } else if (change is AgentDependentBlock) {
      final taskId = _taskKeys[change.taskKey];
      if (taskId == null) _stop(AgentPlanPreviewWarningCode.invalidChange);
      _createBlock(_tasks[taskId]!, change.draft);
    } else if (change is AgentTaskPatch) {
      _applyTaskPatch(change);
    } else if (change is AgentPersonalPatch) {
      _applyPersonalPatch(change);
    } else if (change is AgentBlockPatch) {
      _applyBlockPatch(change);
    } else {
      _stop(AgentPlanPreviewWarningCode.unsupportedChange);
    }
  }

  void _applyIntent(CalendarIntent intent) {
    switch (intent) {
      case CreatePersonalEvent(:final draft):
        _checkPersonalDraft(draft);
        final localId = _reserve(_nextPersonalId);
        _nextPersonalId++;
        _personal.add(
          PersonalSeries(localId: localId, version: 1, draft: draft),
        );
        _changedPersonalSeries.add(localId);
      case UpdatePersonalSeries(:final target, :final draft):
        _checkCalendarTarget(target, CalendarKind.personal);
        _checkPersonalDraft(draft);
        final index = _personal.indexWhere(
          (series) => series.localId == target.identity.localId,
        );
        if (index < 0) _stop(AgentPlanPreviewWarningCode.invalidChange);
        final current = _personal[index];
        if (!_sameSchedule(current.draft, draft)) {
          _changedPersonalSeries.add(current.localId);
        }
        _personal[index] = PersonalSeries(
          localId: current.localId,
          version: current.version + 1,
          draft: draft,
        );
      case UpdatePersonalOccurrence(:final target, :final replacement):
        _checkCalendarTarget(target, CalendarKind.personal);
        _checkPersonalDraft(replacement);
        if (replacement.weekly || replacement.untilDay != null) {
          _stop(AgentPlanPreviewWarningCode.invalidChange);
        }
        final before = _currentOccurrence(target.identity);
        final oldDraft = _draftForOccurrence(before);
        if (!_sameSchedule(oldDraft, replacement)) {
          changedIdentities.add(target.identity);
        }
        _setOverride(target.identity, replacement: replacement);
        _bumpPersonalSeries(target.identity.localId);
      case SetPersonalOccurrenceState(
        :final target,
        :final completed,
        :final skipped,
      ):
        _checkCalendarTarget(target, CalendarKind.personal);
        if (completed == null && skipped == null) {
          _stop(AgentPlanPreviewWarningCode.invalidChange);
        }
        final current = _currentOccurrence(target.identity);
        if (skipped != null && skipped != current.skipped) {
          changedIdentities.add(target.identity);
        }
        _setOverride(target.identity, completed: completed, skipped: skipped);
        _bumpPersonalSeries(target.identity.localId);
      case DeletePersonalSeries(:final target, :final confirmed):
        _checkCalendarTarget(target, CalendarKind.personal);
        if (!confirmed) _stop(AgentPlanPreviewWarningCode.invalidChange);
        _personal.removeWhere(
          (series) => series.localId == target.identity.localId,
        );
        _overrides.removeWhere(
          (item) => item.localId == target.identity.localId,
        );
        _deletedPersonalSeriesIds.add(target.identity.localId);
      case UpdateSchoolAnnotation(
        :final target,
        :final note,
        :final attendance,
        :final listening,
        :final hidden,
      ):
        _checkCalendarTarget(target, target.identity.kind);
        if (![
              CalendarKind.course,
              CalendarKind.exam,
              CalendarKind.young,
            ].contains(target.identity.kind) ||
            (note == null &&
                attendance == null &&
                listening == null &&
                hidden == null) ||
            (note != null && (note.length > 4000 || note.contains('\u0000'))) ||
            (attendance != null && target.identity.kind == CalendarKind.exam) ||
            (listening != null &&
                target.identity.kind != CalendarKind.course)) {
          _stop(AgentPlanPreviewWarningCode.invalidChange);
        }
        final index = _school.indexWhere(
          (item) => item.reference.identity == target.identity,
        );
        if (index < 0) _stop(AgentPlanPreviewWarningCode.invalidChange);
        final current = _school[index];
        if (!current.allDay && current.hidden != (hidden ?? current.hidden)) {
          changedIdentities.add(target.identity);
        }
        _school[index] = CalendarOccurrence(
          reference: CalendarReference(
            current.reference.context,
            current.reference.identity,
            current.reference.version + 1,
          ),
          title: current.title,
          startsAtUtc: current.startsAtUtc,
          endsAtUtc: current.endsAtUtc,
          allDay: current.allDay,
          presence: current.presence,
          hidden: hidden ?? current.hidden,
          skipped: current.skipped,
          completed: current.completed,
          location: current.location,
          academicDetails: current.academicDetails,
          note: note ?? current.note,
          attendance: attendance ?? current.attendance,
          listening: listening ?? current.listening,
          task: current.task,
          taskStatus: current.taskStatus,
          planBlockStatus: current.planBlockStatus,
        );
      case SaveCalendarRelation(
        :final left,
        :final right,
        :final existing,
        :final kind,
        :final note,
      ):
        _saveRelation(left, right, existing, kind, note);
      case DeleteCalendarRelation(:final target):
        _deleteRelation(target);
      case CreateTask(:final draft):
        _createTask('calendarDirect${_privateTaskKey++}', draft);
      case UpdateTask(:final target, :final draft):
        _updateTask(target, draft: draft);
      case SetTaskStatus(:final target, :final status):
        _setTaskStatus(target, status);
      case DeleteTask(:final target, :final confirmed):
        _deleteTask(target, confirmed: confirmed);
      case CreatePlanBlock(:final task, :final draft):
        final state = _taskForReference(task, requireSummary: true);
        _createBlock(state, draft);
      case UpdatePlanBlock(:final target, :final draft):
        _updateBlock(target, draft);
      case SetPlanBlockStatus(:final target, :final status):
        _setBlockStatus(target, status);
      case DeletePlanBlock(:final target, :final confirmed):
        _deleteBlock(target, confirmed: confirmed);
      case UndoCalendarWrite():
        _stop(AgentPlanPreviewWarningCode.undoUnavailable);
    }
  }

  void _createTask(String localKey, TaskDraft draft) {
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_-]{0,31}$').hasMatch(localKey) ||
        _taskKeys.containsKey(localKey) ||
        !_validTaskDraft(draft)) {
      _stop(AgentPlanPreviewWarningCode.invalidChange);
    }
    final localId = _reserve(_nextTaskId);
    _nextTaskId++;
    _tasks[localId] = _TaskState(
      localId: localId,
      version: 1,
      title: draft.title,
      status: TaskStatus.active,
      summaryKnown: true,
    );
    _taskKeys[localKey] = localId;
  }

  void _applyTaskPatch(AgentTaskPatch change) {
    if ((change.clearDeadline && change.deadlineUtc != null) ||
        (change.clearEstimate && change.estimatedMinutes != null) ||
        (change.title == null &&
            change.description == null &&
            change.note == null &&
            change.deadlineUtc == null &&
            !change.clearDeadline &&
            change.estimatedMinutes == null &&
            !change.clearEstimate &&
            change.priority == null)) {
      _stop(AgentPlanPreviewWarningCode.invalidChange);
    }
    if ((change.title != null && !_validTaskTitle(change.title!)) ||
        !_validTaskText(change.description, 4000) ||
        !_validTaskText(change.note, 4000) ||
        (change.deadlineUtc != null &&
            (!change.deadlineUtc!.isUtc ||
                change.deadlineUtc!.year < 1 ||
                change.deadlineUtc!.year > 9998)) ||
        (change.estimatedMinutes != null &&
            (change.estimatedMinutes! < 1 ||
                change.estimatedMinutes! > 527040))) {
      _stop(AgentPlanPreviewWarningCode.invalidChange);
    }
    final task = _taskForReference(change.target, requireSummary: false);
    if (change.title != null) {
      if (!_validTaskTitle(change.title!)) {
        _stop(AgentPlanPreviewWarningCode.invalidChange);
      }
      task.title = change.title!;
      task.summaryKnown = true;
    }
    _bumpTask(task.localId);
  }

  void _applyPersonalPatch(AgentPersonalPatch change) {
    _checkCalendarTarget(change.target, CalendarKind.personal);
    final current = _currentOccurrence(change.target.identity);
    final seriesIndex = _personal.indexWhere(
      (series) => series.localId == change.target.identity.localId,
    );
    if (seriesIndex < 0) _stop(AgentPlanPreviewWarningCode.invalidChange);
    final oldDraft = change.entireSeries
        ? _personal[seriesIndex].draft
        : _draftForOccurrence(current);
    final next = PersonalEventDraft(
      title: change.title ?? oldDraft.title,
      start: change.start ?? oldDraft.start,
      end: change.end ?? oldDraft.end,
      allDay: change.allDay ?? oldDraft.allDay,
      weekly: change.entireSeries ? change.weekly ?? oldDraft.weekly : false,
      untilDay: change.entireSeries
          ? change.clearUntil
                ? null
                : change.untilDay ?? oldDraft.untilDay
          : null,
      location: change.location ?? oldDraft.location,
      note: change.note ?? oldDraft.note,
    );
    _checkPersonalDraft(next);
    if (change.entireSeries) {
      if (!_sameSchedule(oldDraft, next)) {
        _changedPersonalSeries.add(change.target.identity.localId);
      }
      final currentSeries = _personal[seriesIndex];
      _personal[seriesIndex] = PersonalSeries(
        localId: currentSeries.localId,
        version: currentSeries.version + 1,
        draft: next,
      );
    } else {
      if (!_sameSchedule(oldDraft, next)) {
        changedIdentities.add(change.target.identity);
      }
      _setOverride(change.target.identity, replacement: next);
      _bumpPersonalSeries(change.target.identity.localId);
    }
  }

  void _applyBlockPatch(AgentBlockPatch change) {
    _checkCalendarTarget(change.target, CalendarKind.planBlock);
    final currentIndex = _blocks.indexWhere(
      (item) => item.reference.identity == change.target.identity,
    );
    if (currentIndex < 0) _stop(AgentPlanPreviewWarningCode.invalidChange);
    final current = _blocks[currentIndex];
    final next = PlanBlockDraft(
      startsAtUtc: change.startUtc ?? current.startsAtUtc,
      endsAtUtc: change.endUtc ?? current.endsAtUtc,
      location: change.location ?? current.location,
      note: change.note ?? current.note,
    );
    _checkPlanBlockDraft(next);
    if (next.startsAtUtc != current.startsAtUtc ||
        next.endsAtUtc != current.endsAtUtc) {
      changedIdentities.add(change.target.identity);
    }
    _replaceBlock(currentIndex, current, next);
  }

  void _checkCalendarTarget(CalendarReference target, CalendarKind kind) {
    if (target.context != _base.context ||
        target.version < 1 ||
        target.identity.kind != kind) {
      _stop(AgentPlanPreviewWarningCode.invalidChange);
    }
    final baseline = _projection.occurrence(_base, target.identity);
    if (baseline == null || baseline.reference.version != target.version) {
      _stop(AgentPlanPreviewWarningCode.invalidChange);
    }
    if ((kind == CalendarKind.personal &&
            _deletedPersonalSeriesIds.contains(target.identity.localId)) ||
        (kind == CalendarKind.planBlock &&
            (_deletedBlockIdentities.contains(target.identity) ||
                _closedTaskAggregateIds.contains(baseline.task?.localId)))) {
      _stop(AgentPlanPreviewWarningCode.invalidChange);
    }
  }

  CalendarOccurrence _currentOccurrence(CalendarIdentity identity) {
    final occurrence = _projection.occurrence(snapshot, identity);
    if (occurrence == null) _stop(AgentPlanPreviewWarningCode.invalidChange);
    return occurrence;
  }

  PersonalEventDraft _draftForOccurrence(CalendarOccurrence occurrence) =>
      PersonalEventDraft(
        title: occurrence.title,
        start: occurrence.allDay
            ? beijingDay(occurrence.startsAtUtc)
            : occurrence.startsAtUtc,
        end: occurrence.allDay
            ? beijingDay(occurrence.endsAtUtc)
            : occurrence.endsAtUtc,
        allDay: occurrence.allDay,
        location: occurrence.location,
        note: occurrence.note,
      );

  void _setOverride(
    CalendarIdentity identity, {
    PersonalEventDraft? replacement,
    bool? completed,
    bool? skipped,
  }) {
    final index = _overrides.indexWhere(
      (item) =>
          item.localId == identity.localId && item.ordinal == identity.ordinal,
    );
    final prior = index < 0 ? null : _overrides[index];
    final next = PersonalOccurrenceOverride(
      localId: identity.localId,
      ordinal: identity.ordinal,
      replacement: replacement ?? prior?.replacement,
      completed: completed ?? prior?.completed ?? false,
      skipped: skipped ?? prior?.skipped ?? false,
    );
    if (index < 0) {
      _overrides.add(next);
    } else {
      _overrides[index] = next;
    }
  }

  void _bumpPersonalSeries(int localId) {
    final index = _personal.indexWhere((series) => series.localId == localId);
    if (index < 0) _stop(AgentPlanPreviewWarningCode.invalidChange);
    final current = _personal[index];
    _personal[index] = PersonalSeries(
      localId: current.localId,
      version: current.version + 1,
      draft: current.draft,
    );
  }

  void _saveRelation(
    CalendarReference left,
    CalendarReference right,
    CalendarRelationReference? existing,
    CalendarRelationKind kind,
    String note,
  ) {
    _checkCalendarTarget(left, left.identity.kind);
    _checkCalendarTarget(right, right.identity.kind);
    if (left.identity == right.identity ||
        kind == CalendarRelationKind.legacyUndecided ||
        note.length > 4000 ||
        note.contains('\u0000')) {
      _stop(AgentPlanPreviewWarningCode.invalidChange);
    }
    final leftOccurrence = _projection.occurrence(_base, left.identity);
    final rightOccurrence = _projection.occurrence(_base, right.identity);
    if (leftOccurrence == null ||
        rightOccurrence == null ||
        leftOccurrence.reference.version != left.version ||
        rightOccurrence.reference.version != right.version ||
        leftOccurrence.allDay ||
        rightOccurrence.allDay) {
      _stop(AgentPlanPreviewWarningCode.invalidChange);
    }
    final priorIndex = existing == null
        ? _relations.indexWhere(
            (relation) => _samePair(
              relation.left,
              relation.right,
              left.identity,
              right.identity,
            ),
          )
        : _relations.indexWhere(
            (relation) => relation.reference.localId == existing.localId,
          );
    if (existing == null && priorIndex >= 0) {
      _stop(AgentPlanPreviewWarningCode.invalidChange);
    }
    if (existing != null) {
      final baseRelation = _base.relations.where(
        (relation) => relation.reference.localId == existing.localId,
      );
      if (existing.context != _base.context ||
          existing.version < 1 ||
          baseRelation.length != 1 ||
          baseRelation.single.reference.version != existing.version ||
          priorIndex < 0 ||
          !_samePair(
            _relations[priorIndex].left,
            _relations[priorIndex].right,
            left.identity,
            right.identity,
          )) {
        _stop(AgentPlanPreviewWarningCode.invalidChange);
      }
    }
    final localId = existing?.localId ?? _reserve(_nextRelationId);
    if (existing == null) _nextRelationId++;
    final version = existing == null
        ? 1
        : _relations[priorIndex].reference.version + 1;
    final relation = CalendarRelation(
      reference: CalendarRelationReference(_base.context, localId, version),
      left: left.identity,
      right: right.identity,
      kind: kind,
      note: note,
    );
    if (priorIndex < 0) {
      _relations.add(relation);
    } else {
      _relations[priorIndex] = relation;
    }
    _touchEndpoints(left.identity, right.identity);
    freeConstraintIdentities
      ..add(left.identity)
      ..add(right.identity);
  }

  void _deleteRelation(CalendarRelationReference target) {
    if (target.context != _base.context || target.version < 1) {
      _stop(AgentPlanPreviewWarningCode.invalidChange);
    }
    final baseRelations = _base.relations.where(
      (relation) => relation.reference.localId == target.localId,
    );
    final index = _relations.indexWhere(
      (relation) => relation.reference.localId == target.localId,
    );
    if (baseRelations.length != 1 ||
        baseRelations.single.reference.version != target.version ||
        index < 0) {
      _stop(AgentPlanPreviewWarningCode.invalidChange);
    }
    final prior = _relations[index];
    for (final identity in {prior.left, prior.right}) {
      final occurrence = _projection.occurrence(_base, identity);
      if (occurrence == null) {
        _stop(AgentPlanPreviewWarningCode.invalidChange);
      }
      _checkCalendarTarget(occurrence.reference, identity.kind);
    }
    _relations.removeAt(index);
    _touchEndpoints(prior.left, prior.right);
    freeConstraintIdentities
      ..add(prior.left)
      ..add(prior.right);
  }

  bool _samePair(
    CalendarIdentity a,
    CalendarIdentity b,
    CalendarIdentity c,
    CalendarIdentity d,
  ) => (a == c && b == d) || (a == d && b == c);

  void _touchEndpoints(CalendarIdentity left, CalendarIdentity right) {
    final personalSeriesIds = <int>{};
    final taskIds = <int>{};
    final schoolIdentities = <CalendarIdentity>{};
    for (final identity in {left, right}) {
      final occurrence = _projection.occurrence(snapshot, identity);
      if (occurrence == null) continue;
      switch (identity.kind) {
        case CalendarKind.personal:
          personalSeriesIds.add(identity.localId);
        case CalendarKind.planBlock:
          final taskId = occurrence.task?.localId;
          if (taskId != null && _tasks.containsKey(taskId)) taskIds.add(taskId);
        case CalendarKind.course || CalendarKind.exam || CalendarKind.young:
          schoolIdentities.add(identity);
      }
    }
    for (final localId in personalSeriesIds) {
      _bumpPersonalSeries(localId);
    }
    for (final localId in taskIds) {
      _bumpTask(localId);
    }
    for (final identity in schoolIdentities) {
      _touchIdentity(identity);
    }
  }

  void _touchIdentity(CalendarIdentity identity) {
    if (identity.kind == CalendarKind.planBlock) {
      final block = _blocks.where(
        (item) => item.reference.identity == identity,
      );
      if (block.isEmpty) return;
      final taskId = block.first.task?.localId;
      if (taskId != null && _tasks.containsKey(taskId)) _bumpTask(taskId);
      return;
    }
    if (identity.kind == CalendarKind.personal) {
      _bumpPersonalSeries(identity.localId);
      return;
    }
    final index = _school.indexWhere(
      (item) => item.reference.identity == identity,
    );
    if (index < 0) return;
    final item = _school[index];
    _school[index] = _copyOccurrence(
      item,
      reference: CalendarReference(
        item.reference.context,
        item.reference.identity,
        item.reference.version + 1,
      ),
    );
  }

  void _updateTask(TaskReference target, {required TaskDraft draft}) {
    final task = _taskForReference(target, requireSummary: false);
    if (!_validTaskDraft(draft)) {
      _stop(AgentPlanPreviewWarningCode.invalidChange);
    }
    task.title = draft.title;
    task.summaryKnown = true;
    _bumpTask(task.localId);
  }

  void _setTaskStatus(TaskReference target, TaskStatus status) {
    final task = _taskForReference(target, requireSummary: false);
    task.status = status;
    _bumpTask(task.localId);
  }

  void _deleteTask(TaskReference target, {required bool confirmed}) {
    if (!confirmed) _stop(AgentPlanPreviewWarningCode.invalidChange);
    _checkTaskReference(target);
    if (!_tasks.containsKey(target.localId)) {
      hasIncompleteAction = true;
      _warn(AgentPlanPreviewWarningCode.taskSummaryUnavailable);
    }
    final before = _blocks.length;
    _blocks.removeWhere((block) => block.task?.localId == target.localId);
    _tasks.remove(target.localId);
    _taskKeys.removeWhere((_, id) => id == target.localId);
    _closedTaskAggregateIds.add(target.localId);
    if (_blocks.length < before) {
      _warn(AgentPlanPreviewWarningCode.deletedTaskBlocks);
    }
  }

  _TaskState _taskForReference(
    TaskReference target, {
    required bool requireSummary,
  }) {
    _checkTaskReference(target);
    final task = _tasks[target.localId];
    if (task != null) return task;
    final placeholder = _TaskState(
      localId: target.localId,
      version: target.version,
      title: '已有任务（名称未知）',
      status: TaskStatus.active,
      summaryKnown: false,
    );
    _tasks[target.localId] = placeholder;
    if (requireSummary) {
      hasIncompleteAction = true;
      _warn(AgentPlanPreviewWarningCode.taskSummaryUnavailable);
    }
    return placeholder;
  }

  void _checkTaskReference(TaskReference target) {
    if (target.context != _base.context ||
        target.localId <= 0 ||
        target.version < 1 ||
        _closedTaskAggregateIds.contains(target.localId)) {
      _stop(AgentPlanPreviewWarningCode.invalidChange);
    }
    final known = _base.planBlocks
        .map((block) => block.task)
        .whereType<TaskReference>()
        .where((task) => task.localId == target.localId);
    if (known.isNotEmpty &&
        known.any((task) => task.version != target.version)) {
      _stop(AgentPlanPreviewWarningCode.invalidChange);
    }
  }

  void _createBlock(_TaskState task, PlanBlockDraft draft) {
    _checkPlanBlockDraft(draft);
    if (!task.summaryKnown) {
      hasIncompleteAction = true;
      _warn(AgentPlanPreviewWarningCode.taskSummaryUnavailable);
    }
    task.version++;
    _syncTaskBlocks(task.localId);
    final localId = _reserve(_nextBlockId);
    _nextBlockId++;
    final identity = CalendarIdentity(CalendarKind.planBlock, localId);
    _blocks.add(
      CalendarOccurrence(
        reference: CalendarReference(_base.context, identity, task.version),
        title: task.title,
        startsAtUtc: draft.startsAtUtc,
        endsAtUtc: draft.endsAtUtc,
        location: draft.location,
        note: draft.note,
        task: TaskReference(_base.context, task.localId, task.version),
        taskStatus: task.status,
        planBlockStatus: PlanBlockStatus.planned,
      ),
    );
    changedIdentities.add(identity);
  }

  void _updateBlock(CalendarReference target, PlanBlockDraft draft) {
    _checkCalendarTarget(target, CalendarKind.planBlock);
    final index = _blocks.indexWhere(
      (item) => item.reference.identity == target.identity,
    );
    if (index < 0) _stop(AgentPlanPreviewWarningCode.invalidChange);
    _checkPlanBlockDraft(draft);
    final current = _blocks[index];
    if (draft.startsAtUtc != current.startsAtUtc ||
        draft.endsAtUtc != current.endsAtUtc) {
      changedIdentities.add(target.identity);
    }
    _replaceBlock(index, current, draft);
  }

  void _replaceBlock(
    int index,
    CalendarOccurrence current,
    PlanBlockDraft draft,
  ) {
    final taskId = current.task?.localId;
    if (taskId == null || !_tasks.containsKey(taskId)) {
      _stop(AgentPlanPreviewWarningCode.invalidChange);
    }
    _blocks[index] = _copyOccurrence(
      current,
      startsAtUtc: draft.startsAtUtc,
      endsAtUtc: draft.endsAtUtc,
      location: draft.location,
      note: draft.note,
    );
    _bumpTask(taskId);
  }

  void _setBlockStatus(CalendarReference target, PlanBlockStatus status) {
    _checkCalendarTarget(target, CalendarKind.planBlock);
    final index = _blocks.indexWhere(
      (item) => item.reference.identity == target.identity,
    );
    if (index < 0) _stop(AgentPlanPreviewWarningCode.invalidChange);
    final current = _blocks[index];
    if (current.skipped != (status == PlanBlockStatus.skipped)) {
      changedIdentities.add(target.identity);
    }
    _blocks[index] = CalendarOccurrence(
      reference: current.reference,
      title: current.title,
      startsAtUtc: current.startsAtUtc,
      endsAtUtc: current.endsAtUtc,
      allDay: current.allDay,
      presence: current.presence,
      hidden: current.hidden,
      skipped: status == PlanBlockStatus.skipped,
      completed: status == PlanBlockStatus.done,
      location: current.location,
      academicDetails: current.academicDetails,
      note: current.note,
      attendance: current.attendance,
      listening: current.listening,
      task: current.task,
      taskStatus: current.taskStatus,
      planBlockStatus: status,
    );
    final taskId = current.task?.localId;
    if (taskId == null) _stop(AgentPlanPreviewWarningCode.invalidChange);
    _bumpTask(taskId);
  }

  void _deleteBlock(CalendarReference target, {required bool confirmed}) {
    _checkCalendarTarget(target, CalendarKind.planBlock);
    if (!confirmed) _stop(AgentPlanPreviewWarningCode.invalidChange);
    final index = _blocks.indexWhere(
      (item) => item.reference.identity == target.identity,
    );
    if (index < 0) _stop(AgentPlanPreviewWarningCode.invalidChange);
    final taskId = _blocks[index].task?.localId;
    _blocks.removeAt(index);
    if (taskId == null || !_tasks.containsKey(taskId)) {
      _stop(AgentPlanPreviewWarningCode.invalidChange);
    }
    _bumpTask(taskId);
    _closedTaskAggregateIds.add(taskId);
    _deletedBlockIdentities.add(target.identity);
  }

  void _bumpTask(int localId) {
    final task = _tasks[localId];
    if (task == null) _stop(AgentPlanPreviewWarningCode.invalidChange);
    task.version++;
    _syncTaskBlocks(localId);
  }

  void _syncTaskBlocks(int localId) {
    final task = _tasks[localId];
    if (task == null) _stop(AgentPlanPreviewWarningCode.invalidChange);
    for (var index = 0; index < _blocks.length; index++) {
      final block = _blocks[index];
      if (block.task?.localId != localId) continue;
      _blocks[index] = _copyOccurrence(
        block,
        reference: CalendarReference(
          _base.context,
          block.reference.identity,
          task.version,
        ),
        title: task.title,
        task: TaskReference(_base.context, localId, task.version),
        taskStatus: task.status,
      );
    }
  }

  void _checkPersonalDraft(PersonalEventDraft draft) {
    try {
      validatePersonalDraft(draft);
    } on Object {
      _stop(AgentPlanPreviewWarningCode.invalidChange);
    }
  }

  void _checkPlanBlockDraft(PlanBlockDraft draft) {
    if (!_validPlanBlockDraft(draft)) {
      _stop(AgentPlanPreviewWarningCode.invalidChange);
    }
  }

  bool _sameSchedule(PersonalEventDraft left, PersonalEventDraft right) =>
      left.start == right.start &&
      left.end == right.end &&
      left.allDay == right.allDay &&
      left.weekly == right.weekly &&
      left.untilDay == right.untilDay;

  int _reserve(int id) {
    if (id <= 0) _stop(AgentPlanPreviewWarningCode.invalidChange);
    return id;
  }
}

CalendarOccurrence _copyOccurrence(
  CalendarOccurrence current, {
  CalendarReference? reference,
  String? title,
  DateTime? startsAtUtc,
  DateTime? endsAtUtc,
  bool? allDay,
  AgendaPresence? presence,
  bool? hidden,
  bool? skipped,
  bool? completed,
  String? location,
  JwAcademicDetails? academicDetails,
  String? note,
  AttendanceDecision? attendance,
  ListeningMode? listening,
  TaskReference? task,
  TaskStatus? taskStatus,
  PlanBlockStatus? planBlockStatus,
}) => CalendarOccurrence(
  reference: reference ?? current.reference,
  title: title ?? current.title,
  startsAtUtc: startsAtUtc ?? current.startsAtUtc,
  endsAtUtc: endsAtUtc ?? current.endsAtUtc,
  allDay: allDay ?? current.allDay,
  presence: presence ?? current.presence,
  hidden: hidden ?? current.hidden,
  skipped: skipped ?? current.skipped,
  completed: completed ?? current.completed,
  location: location ?? current.location,
  academicDetails: academicDetails ?? current.academicDetails,
  note: note ?? current.note,
  attendance: attendance ?? current.attendance,
  listening: listening ?? current.listening,
  task: task ?? current.task,
  taskStatus: taskStatus ?? current.taskStatus,
  planBlockStatus: planBlockStatus ?? current.planBlockStatus,
);

bool _validTaskTitle(String title) =>
    title.trim().isNotEmpty &&
    title.trim() == title &&
    title.length <= 200 &&
    !title.contains('\u0000');

bool _validTaskText(String? value, int limit) =>
    value == null || (value.length <= limit && !value.contains('\u0000'));

bool _validTaskDraft(TaskDraft draft) =>
    _validTaskTitle(draft.title) &&
    _validTaskText(draft.description, 4000) &&
    _validTaskText(draft.note, 4000) &&
    (draft.deadlineAtUtc == null ||
        (draft.deadlineAtUtc!.isUtc &&
            draft.deadlineAtUtc!.year >= 1 &&
            draft.deadlineAtUtc!.year <= 9998)) &&
    (draft.estimatedMinutes == null ||
        (draft.estimatedMinutes! >= 1 && draft.estimatedMinutes! <= 527040));

bool _validPlanBlockDraft(PlanBlockDraft draft) =>
    draft.location.length <= 200 &&
    draft.note.length <= 4000 &&
    !draft.location.contains('\u0000') &&
    !draft.note.contains('\u0000') &&
    draft.startsAtUtc.isUtc &&
    draft.endsAtUtc.isUtc &&
    draft.startsAtUtc.year >= 1 &&
    draft.endsAtUtc.year <= 9998 &&
    draft.endsAtUtc.isAfter(draft.startsAtUtc) &&
    draft.endsAtUtc.difference(draft.startsAtUtc) <= const Duration(days: 366);
