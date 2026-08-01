import '../../tasks/domain/plan_block.dart';
import '../../tasks/domain/task.dart';
import 'overlap_engine.dart';

enum ScheduleGridItemKind { event, planBlock }

/// Whether a planning block is eligible for the timed week grid: approved
/// (accepted or done) and not soft-deleted.
extension PlanBlockGridVisibility on PlanBlockItem {
  bool get showsInWeekGrid =>
      deletedAt == null &&
      (status == PlanBlockStatus.accepted || status == PlanBlockStatus.done);
}

/// A presentation/domain projection consumed by the week timetable. Unifies a
/// timed calendar event or an approved planning block into one grid item shape
/// while retaining the original event / plan-block / task identities so
/// selection callbacks can route to the correct detail page.
///
/// This is NOT a persisted entity. Plan blocks do not receive manufactured
/// CalendarEvent IDs; they carry their own [id] plus the parent [task].
class ScheduleGridItem {
  ScheduleGridItem._({
    required this.kind,
    required this.id,
    required this.title,
    required this.allDay,
    required this.startAt,
    required this.endAt,
    required this.startDate,
    required this.endDateExclusive,
    required this.location,
    required this.hasConfirmedConflict,
    required this.isInactivePreview,
    required this.importance,
    required this.eventType,
    required this.foregroundPriority,
    required this.color,
    required this.colorKey,
    this.event,
    this.planBlock,
    this.task,
  });

  factory ScheduleGridItem.fromEvent(EffectiveEvent event) => ScheduleGridItem._(
    kind: ScheduleGridItemKind.event,
    id: event.id,
    title: event.title,
    allDay: event.allDay,
    startAt: event.startAt,
    endAt: event.endAt,
    startDate: event.startDate,
    endDateExclusive: event.endDateExclusive,
    location: event.location,
    hasConfirmedConflict: event.hasConfirmedConflict,
    isInactivePreview: event.isInactivePreview,
    importance: event.importance,
    eventType: event.eventType,
    foregroundPriority: event.foregroundPriority,
    color: event.color,
    colorKey: event.courseSeriesId ?? event.id,
    event: event,
  );

  factory ScheduleGridItem.fromPlanBlock(PlanBlockItem block, TaskItem task) =>
      ScheduleGridItem._(
        kind: ScheduleGridItemKind.planBlock,
        id: block.id,
        title: block.title ?? task.title,
        allDay: false,
        startAt: block.startAt,
        endAt: block.endAt,
        startDate: null,
        endDateExclusive: null,
        location: null,
        hasConfirmedConflict: false,
        isInactivePreview: false,
        importance: EventImportance.normal,
        eventType: 'plan_block',
        foregroundPriority: 0,
        color: null,
        colorKey: task.id,
        planBlock: block,
        task: task,
      );

  final ScheduleGridItemKind kind;

  /// Non-null when [kind] is [ScheduleGridItemKind.event].
  final EffectiveEvent? event;

  /// Non-null when [kind] is [ScheduleGridItemKind.planBlock].
  final PlanBlockItem? planBlock;

  /// Parent task of a plan block; non-null when [kind] is
  /// [ScheduleGridItemKind.planBlock].
  final TaskItem? task;

  final String id;
  final String title;
  final bool allDay;
  final DateTime? startAt;
  final DateTime? endAt;
  final DateTime? startDate;
  final DateTime? endDateExclusive;
  final String? location;
  final bool hasConfirmedConflict;
  final bool isInactivePreview;
  final EventImportance importance;
  final String eventType;
  final int foregroundPriority;

  /// Explicit color override (e.g. a user overlay); null falls back to a
  /// palette color derived from [colorKey].
  final String? color;

  /// Stable identity used to derive a deterministic color when [color] is
  /// null: the course series for events, the parent task for plan blocks.
  final String colorKey;

  /// Whether this item is eligible for the timed week grid. Events are always
  /// eligible; plan blocks must be approved and non-deleted.
  bool get showsInWeekGrid {
    if (kind == ScheduleGridItemKind.event) return true;
    final block = planBlock;
    return block != null && block.showsInWeekGrid;
  }
}
