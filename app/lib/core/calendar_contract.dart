import 'agenda_contract.dart';
import 'jw_academic_details.dart';

part 'task_contract.dart';

enum CalendarKind { course, exam, young, personal, planBlock }

enum CalendarFilter { all, course, exam, young, personal, planBlock }

enum AttendanceDecision { undecided, attend, skip }

enum ListeningMode { undecided, listening, selfStudy }

enum CalendarRelationKind { conflict, notConflict, legacyUndecided }

enum CalendarConflictStatus { conflict, notConflict }

enum CalendarFailureCode {
  invalidInput,
  busy,
  staleReference,
  idempotencyConflict,
  maintenance,
  limitExceeded,
  ownershipLost,
  storageFailed,
  closed,
  undoUnavailable,
  undoConflict,
}

final class CalendarFailure implements Exception {
  const CalendarFailure(this.code);
  final CalendarFailureCode code;
  @override
  String toString() => 'CalendarFailure(${code.name})';
}

/// Issued by C3 from the local directory owner and persisted epochs. This is
/// local authority, not proof of a school identity or a model-visible value.
final class CalendarContext {
  const CalendarContext({
    required this.owner,
    required this.resetEpoch,
    required this.agendaEpoch,
  });
  final String owner;
  final int resetEpoch;
  final int agendaEpoch;
  @override
  bool operator ==(Object other) =>
      other is CalendarContext &&
      owner == other.owner &&
      resetEpoch == other.resetEpoch &&
      agendaEpoch == other.agendaEpoch;
  @override
  int get hashCode => Object.hash(owner, resetEpoch, agendaEpoch);
  @override
  String toString() => 'CalendarContext';
}

/// A weekly occurrence keeps its ordinal when a series is moved or edited.
/// School events and single personal events use ordinal zero.
final class CalendarIdentity {
  const CalendarIdentity(this.kind, this.localId, {this.ordinal = 0});
  final CalendarKind kind;
  final int localId;
  final int ordinal;
  List<Object> get canonical => [kind.name, localId, ordinal];
  @override
  bool operator ==(Object other) =>
      other is CalendarIdentity &&
      kind == other.kind &&
      localId == other.localId &&
      ordinal == other.ordinal;
  @override
  int get hashCode => Object.hash(kind, localId, ordinal);
  @override
  String toString() => 'CalendarIdentity';
}

final class CalendarReference {
  const CalendarReference(this.context, this.identity, this.version);
  final CalendarContext context;
  final CalendarIdentity identity;
  final int version;
  List<Object> get canonical => [
    context.owner,
    context.resetEpoch,
    context.agendaEpoch,
    ...identity.canonical,
    version,
  ];
  @override
  bool operator ==(Object other) =>
      other is CalendarReference &&
      context == other.context &&
      identity == other.identity &&
      version == other.version;
  @override
  int get hashCode => Object.hash(context, identity, version);
  @override
  String toString() => 'CalendarReference';
}

/// Timed values are UTC instants; all-day values are midnight UTC date
/// components representing Beijing dates, with an exclusive end date.
final class PersonalEventDraft {
  const PersonalEventDraft({
    required this.title,
    required this.start,
    required this.end,
    this.allDay = false,
    this.weekly = false,
    this.untilDay,
    this.location = '',
    this.note = '',
  });
  final String title;
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final bool weekly;
  final DateTime? untilDay;
  final String location;
  final String note;
  DateTime get startsAtUtc =>
      allDay ? start.subtract(const Duration(hours: 8)) : start;
  DateTime get endsAtUtc =>
      allDay ? end.subtract(const Duration(hours: 8)) : end;
  DateTime get anchorDay => allDay ? start : beijingDay(start);
  List<Object?> get canonical => [
    title,
    start.microsecondsSinceEpoch,
    end.microsecondsSinceEpoch,
    allDay,
    weekly,
    untilDay?.microsecondsSinceEpoch,
    location,
    note,
  ];
  @override
  String toString() => 'PersonalEventDraft';
}

final class PersonalSeries {
  const PersonalSeries({
    required this.localId,
    required this.version,
    required this.draft,
  });
  final int localId;
  final int version;
  final PersonalEventDraft draft;
}

/// A replacement has absolute times and is itself non-recurring. Completion,
/// skipping and replacement are independent facts for one stable ordinal.
final class PersonalOccurrenceOverride {
  const PersonalOccurrenceOverride({
    required this.localId,
    required this.ordinal,
    this.replacement,
    this.completed = false,
    this.skipped = false,
  });
  final int localId;
  final int ordinal;
  final PersonalEventDraft? replacement;
  final bool completed;
  final bool skipped;
}

final class CalendarOccurrence {
  const CalendarOccurrence({
    required this.reference,
    required this.title,
    required this.startsAtUtc,
    required this.endsAtUtc,
    this.allDay = false,
    this.presence = AgendaPresence.observed,
    this.hidden = false,
    this.skipped = false,
    this.completed = false,
    this.location = '',
    this.academicDetails,
    this.note = '',
    this.attendance = AttendanceDecision.undecided,
    this.listening = ListeningMode.undecided,
    this.task,
    this.taskStatus,
    this.planBlockStatus,
  });
  final CalendarReference reference;
  final String title;
  final DateTime startsAtUtc;
  final DateTime endsAtUtc;
  final bool allDay;
  final AgendaPresence presence;
  final bool hidden;
  final bool skipped;
  final bool completed;
  final String location;
  final JwAcademicDetails? academicDetails;
  final String note;
  final AttendanceDecision attendance;
  final ListeningMode listening;
  final TaskReference? task;
  final TaskStatus? taskStatus;
  final PlanBlockStatus? planBlockStatus;
  @override
  String toString() => 'CalendarOccurrence';
}

final class CalendarRelationReference {
  const CalendarRelationReference(this.context, this.localId, this.version);
  final CalendarContext context;
  final int localId;
  final int version;
  List<Object> get canonical => [
    context.owner,
    context.resetEpoch,
    context.agendaEpoch,
    localId,
    version,
  ];
  @override
  String toString() => 'CalendarRelationReference';
}

final class CalendarRelation {
  const CalendarRelation({
    required this.reference,
    required this.left,
    required this.right,
    required this.kind,
    this.note = '',
  });
  final CalendarRelationReference reference;
  final CalendarIdentity left;
  final CalendarIdentity right;
  final CalendarRelationKind kind;
  final String note;
}

/// One consistent C3 read. None of these objects are safe diagnostic payloads.
final class CalendarSnapshot {
  CalendarSnapshot({
    required this.context,
    required this.revision,
    required List<CalendarOccurrence> school,
    required List<PersonalSeries> personal,
    required List<PersonalOccurrenceOverride> overrides,
    required List<CalendarRelation> relations,
    List<CalendarOccurrence> planBlocks = const [],
  }) : school = List.unmodifiable(school),
       personal = List.unmodifiable(personal),
       overrides = List.unmodifiable(overrides),
       relations = List.unmodifiable(relations),
       planBlocks = List.unmodifiable(planBlocks);
  final CalendarContext context;
  final int revision;
  final List<CalendarOccurrence> school;
  final List<PersonalSeries> personal;
  final List<PersonalOccurrenceOverride> overrides;
  final List<CalendarRelation> relations;
  final List<CalendarOccurrence> planBlocks;
}

final class CalendarQuery {
  const CalendarQuery({
    required this.firstDay,
    required this.endDayExclusive,
    this.filter = CalendarFilter.all,
    this.includeHidden = false,
    this.includeSkipped = false,
    this.limit = 500,
  });
  final DateTime firstDay;
  final DateTime endDayExclusive;
  final CalendarFilter filter;
  final bool includeHidden;
  final bool includeSkipped;
  final int limit;
}

final class CalendarDaySegment {
  const CalendarDaySegment({
    required this.occurrence,
    required this.day,
    required this.startMinute,
    required this.endMinute,
    required this.continuesBefore,
    required this.continuesAfter,
  });
  final CalendarOccurrence occurrence;
  final DateTime day;
  final double startMinute;
  final double endMinute;
  final bool continuesBefore;
  final bool continuesAfter;
}

final class CalendarConflict {
  const CalendarConflict(this.left, this.right, {this.relation});
  final CalendarOccurrence left;
  final CalendarOccurrence right;
  final CalendarRelation? relation;
  CalendarConflictStatus get status => switch (relation?.kind) {
    CalendarRelationKind.conflict => CalendarConflictStatus.conflict,
    CalendarRelationKind.notConflict => CalendarConflictStatus.notConflict,
    CalendarRelationKind.legacyUndecided ||
    null => CalendarConflictStatus.conflict,
  };
  bool get hasExplicitDecision =>
      relation != null &&
      relation!.kind != CalendarRelationKind.legacyUndecided;
}

final class CalendarWindow {
  CalendarWindow({
    required this.context,
    required this.revision,
    required this.query,
    required List<CalendarOccurrence> items,
    required List<CalendarDaySegment> segments,
    required List<CalendarConflict> conflicts,
    required this.matched,
    required this.truncated,
    required this.conflictsTruncated,
  }) : items = List.unmodifiable(items),
       segments = List.unmodifiable(segments),
       conflicts = List.unmodifiable(conflicts);
  final String version = 'local-calendar-v1';
  final CalendarContext context;
  final int revision;
  final CalendarQuery query;
  final List<CalendarOccurrence> items;
  final List<CalendarDaySegment> segments;
  final List<CalendarConflict> conflicts;
  final int matched;
  final bool truncated;
  final bool conflictsTruncated;
}

final class CalendarDetail {
  CalendarDetail({
    required this.occurrence,
    required this.personalDraft,
    required List<CalendarRelation> relations,
    this.hasOccurrenceReplacement = false,
    this.planBlock,
  }) : relations = List.unmodifiable(relations);
  final CalendarOccurrence occurrence;
  final PersonalEventDraft? personalDraft;
  final List<CalendarRelation> relations;
  final bool hasOccurrenceReplacement;
  final PlanBlockRecord? planBlock;
}

sealed class CalendarIntent {
  const CalendarIntent();
  List<Object?> get canonical;
}

final class CreatePersonalEvent extends CalendarIntent {
  const CreatePersonalEvent(this.draft);
  final PersonalEventDraft draft;
  @override
  List<Object?> get canonical => ['create', draft.canonical];
}

final class UpdatePersonalSeries extends CalendarIntent {
  const UpdatePersonalSeries(this.target, this.draft);
  final CalendarReference target;
  final PersonalEventDraft draft;
  @override
  List<Object?> get canonical => ['series', target.canonical, draft.canonical];
}

final class UpdatePersonalOccurrence extends CalendarIntent {
  const UpdatePersonalOccurrence(this.target, this.replacement);
  final CalendarReference target;
  final PersonalEventDraft replacement;
  @override
  List<Object?> get canonical => [
    'occurrence',
    target.canonical,
    replacement.canonical,
  ];
}

final class SetPersonalOccurrenceState extends CalendarIntent {
  const SetPersonalOccurrenceState(this.target, {this.completed, this.skipped});
  final CalendarReference target;
  final bool? completed;
  final bool? skipped;
  @override
  List<Object?> get canonical => [
    'state',
    target.canonical,
    completed,
    skipped,
  ];
}

final class DeletePersonalSeries extends CalendarIntent {
  const DeletePersonalSeries(this.target, {required this.confirmed});
  final CalendarReference target;
  final bool confirmed;
  @override
  List<Object?> get canonical => ['delete', target.canonical, confirmed];
}

final class UpdateSchoolAnnotation extends CalendarIntent {
  const UpdateSchoolAnnotation(
    this.target, {
    this.hidden,
    this.note,
    this.attendance,
    this.listening,
  });
  final CalendarReference target;
  final bool? hidden;
  final String? note;
  final AttendanceDecision? attendance;
  final ListeningMode? listening;
  @override
  List<Object?> get canonical => [
    'annotation',
    target.canonical,
    hidden,
    note,
    attendance?.name,
    listening?.name,
  ];
}

final class SaveCalendarRelation extends CalendarIntent {
  const SaveCalendarRelation({
    required this.left,
    required this.right,
    required this.kind,
    required this.note,
    this.existing,
  });
  final CalendarReference left;
  final CalendarReference right;
  final CalendarRelationKind kind;
  final String note;
  final CalendarRelationReference? existing;
  @override
  List<Object?> get canonical => [
    'relation',
    left.canonical,
    right.canonical,
    kind.name,
    note,
    existing?.canonical,
  ];
}

final class DeleteCalendarRelation extends CalendarIntent {
  const DeleteCalendarRelation(this.target);
  final CalendarRelationReference target;
  @override
  List<Object?> get canonical => ['remove-relation', target.canonical];
}

/// Prepared only by C3. Operation identity is internal; callers cannot prepare
/// arbitrary IDs. Reusing the ID with another intent is rejected at commit.
final class CalendarCommand {
  const CalendarCommand(this.operationId, this.context, this.intent);
  final String operationId;
  final CalendarContext context;
  final CalendarIntent intent;
  @override
  String toString() => 'CalendarCommand';
}

final class CalendarWriteReceipt {
  const CalendarWriteReceipt({
    required this.operationId,
    required this.revision,
    required this.replayed,
    this.target,
    this.relation,
    this.task,
    this.undo,
  });
  final String operationId;
  final int revision;
  final bool replayed;
  final CalendarReference? target;
  final CalendarRelationReference? relation;
  final TaskReference? task;
  final CalendarUndoReference? undo;
  @override
  String toString() => 'CalendarWriteReceipt';
}

abstract interface class LocalCalendarPort {
  /// A safe revision signal only, never titles, notes, account values or refs.
  Stream<int> get changes;
  Future<CalendarWindow> query(CalendarQuery query);
  Future<CalendarDetail> detail(CalendarReference reference);
  Future<CalendarCommand> prepare(
    CalendarContext context,
    CalendarIntent intent,
  );
  Future<CalendarWriteReceipt> commit(CalendarCommand command);
}

/// Delivery guard for snapshots used outside the calendar page. No mutation.
abstract interface class CalendarReadGuardPort {
  Future<void> ensureCalendarRead(CalendarContext context, int revision);
}
