import 'package:drift/drift.dart';

import 'account_tables.dart';
import 'schedule_tables.dart';

class Tasks extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get title => text()();
  TextColumn get description => text().nullable()();
  TextColumn get userNotes => text().nullable()();
  TextColumn get state => text()();
  TextColumn get blockedReason => text().nullable()();
  TextColumn get importance => text()();
  IntColumn get deadlineAt => integer().nullable()();
  IntColumn get estimatedMinutes => integer().nullable()();
  TextColumn get tagsJson => text()();
  IntColumn get completedAt => integer().nullable()();
  IntColumn get cancelledAt => integer().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get deletedAt => integer().nullable()();

  @override
  String get tableName => 'tasks';

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (state IN ('active','blocked','completed','cancelled'))",
    "CHECK ((state = 'completed' AND completed_at IS NOT NULL "
        "AND cancelled_at IS NULL) OR "
        "(state = 'cancelled' AND cancelled_at IS NOT NULL "
        "AND completed_at IS NULL) OR "
        "(state IN ('active','blocked') AND completed_at IS NULL "
        "AND cancelled_at IS NULL))",
    'CHECK (estimated_minutes IS NULL OR estimated_minutes > 0)',
  ];
}

class PlanBlocks extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get taskId =>
      text().references(Tasks, #id, onDelete: KeyAction.cascade)();
  TextColumn get title => text().nullable()();
  IntColumn get startAt => integer()();
  IntColumn get endAt => integer()();
  TextColumn get status => text()();
  BoolColumn get locked => boolean().withDefault(const Constant(false))();
  TextColumn get reviewNote => text().nullable()();
  IntColumn get reviewedAt => integer().nullable()();
  TextColumn get rescheduledToPlanBlockId => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get deletedAt => integer().nullable()();

  @override
  String get tableName => 'plan_blocks';

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (end_at > start_at)',
    "CHECK (status IN "
        "('suggested','accepted','done','skipped','rescheduled','cancelled'))",
    "CHECK ((status IN ('suggested','accepted') AND reviewed_at IS NULL) "
        "OR (status NOT IN ('suggested','accepted') AND reviewed_at IS NOT NULL))",
    "CHECK ((status = 'rescheduled' AND "
        "rescheduled_to_plan_block_id IS NOT NULL) OR "
        "(status != 'rescheduled' AND "
        "rescheduled_to_plan_block_id IS NULL))",
  ];
}

class TaskEventLinks extends Table {
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get taskId =>
      text().references(Tasks, #id, onDelete: KeyAction.cascade)();
  TextColumn get eventId =>
      text().references(CalendarEvents, #id, onDelete: KeyAction.cascade)();
  TextColumn get relationType => text()();
  IntColumn get createdAt => integer()();

  @override
  String get tableName => 'task_event_links';

  @override
  Set<Column<Object>> get primaryKey => {accountId, taskId, eventId};
}

class ScheduleRelations extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get source => text().withDefault(const Constant('user'))();
  TextColumn get externalId => text().nullable()();
  TextColumn get relationType =>
      text().withDefault(const Constant('conflict'))();
  TextColumn get primaryEntityType => text().nullable()();
  TextColumn get primaryEntityId => text().nullable()();
  TextColumn get relatedEntityType => text().nullable()();
  TextColumn get relatedEntityId => text().nullable()();
  TextColumn get leftKind => text().nullable()();
  TextColumn get leftId => text().nullable()();
  TextColumn get rightKind => text().nullable()();
  TextColumn get rightId => text().nullable()();
  @ReferenceName('leftEventRelations')
  TextColumn get leftEventId => text().nullable().references(
    CalendarEvents,
    #id,
    onDelete: KeyAction.cascade,
  )();
  @ReferenceName('leftPlanBlockRelations')
  TextColumn get leftPlanBlockId => text().nullable().references(
    PlanBlocks,
    #id,
    onDelete: KeyAction.cascade,
  )();
  @ReferenceName('rightEventRelations')
  TextColumn get rightEventId => text().nullable().references(
    CalendarEvents,
    #id,
    onDelete: KeyAction.cascade,
  )();
  @ReferenceName('rightPlanBlockRelations')
  TextColumn get rightPlanBlockId => text().nullable().references(
    PlanBlocks,
    #id,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get conflictState => text().nullable()();
  TextColumn get reason => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  String get tableName => 'schedule_relations';

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {accountId, leftKind, leftId, rightKind, rightId},
    {accountId, source, externalId},
  ];

  @override
  List<String> get customConstraints => [
    "CHECK ((relation_type = 'conflict' "
        "AND ((left_event_id IS NOT NULL) != (left_plan_block_id IS NOT NULL)) "
        "AND ((right_event_id IS NOT NULL) != (right_plan_block_id IS NOT NULL)) "
        "AND left_kind IN ('event','plan_block') "
        "AND right_kind IN ('event','plan_block') "
        "AND ((left_kind = 'event' AND left_event_id = left_id) OR "
        "(left_kind = 'plan_block' AND left_plan_block_id = left_id)) "
        "AND ((right_kind = 'event' AND right_event_id = right_id) OR "
        "(right_kind = 'plan_block' AND right_plan_block_id = right_id)) "
        "AND conflict_state IN ('conflict','no_conflict') "
        "AND primary_entity_type IS NULL AND related_entity_type IS NULL) "
        "OR (relation_type = 'exam_for_course' "
        "AND external_id IS NOT NULL "
        "AND primary_entity_type = 'calendar_event' "
        "AND related_entity_type = 'course_series' "
        "AND primary_entity_id IS NOT NULL AND related_entity_id IS NOT NULL "
        "AND left_kind IS NULL AND right_kind IS NULL "
        "AND left_event_id IS NULL AND left_plan_block_id IS NULL "
        "AND right_event_id IS NULL AND right_plan_block_id IS NULL "
        "AND conflict_state IS NULL))",
  ];
}

class ScheduleRelationRules extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get leftSeriesType => text()();
  TextColumn get leftSeriesId => text()();
  TextColumn get rightSeriesType => text()();
  TextColumn get rightSeriesId => text()();
  TextColumn get conflictState => text()();
  TextColumn get reason => text().nullable()();
  TextColumn get effectiveFrom => text()();
  TextColumn get effectiveThrough => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  String get tableName => 'schedule_relation_rules';

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {
      accountId,
      leftSeriesType,
      leftSeriesId,
      rightSeriesType,
      rightSeriesId,
      effectiveFrom,
    },
  ];

  @override
  List<String> get customConstraints => [
    'CHECK (effective_through IS NULL OR '
        'effective_through >= effective_from)',
    "CHECK (left_series_type IN ('course_series','calendar_event_series'))",
    "CHECK (right_series_type IN ('course_series','calendar_event_series'))",
    "CHECK (conflict_state IN ('conflict','no_conflict'))",
  ];
}

class Reminders extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get targetType => text()();
  TextColumn get targetId => text()();
  TextColumn get eventId => text().nullable().references(
    CalendarEvents,
    #id,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get taskId =>
      text().nullable().references(Tasks, #id, onDelete: KeyAction.cascade)();
  TextColumn get planBlockId => text().nullable().references(
    PlanBlocks,
    #id,
    onDelete: KeyAction.cascade,
  )();
  IntColumn get offsetMinutes => integer().nullable()();
  IntColumn get triggerAt => integer()();
  TextColumn get state => text()();
  TextColumn get failureCode => text().nullable()();
  IntColumn get deliveredAt => integer().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  String get tableName => 'reminders';

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {accountId, targetType, targetId, triggerAt},
  ];

  @override
  List<String> get customConstraints => [
    "CHECK (target_type IN ('event','task','plan_block'))",
    "CHECK (state IN ('desired','delivered','cancelled','missed','failed'))",
    "CHECK ((target_type = 'event' AND event_id = target_id "
        'AND task_id IS NULL AND plan_block_id IS NULL) OR '
        "(target_type = 'task' AND task_id = target_id "
        'AND event_id IS NULL AND plan_block_id IS NULL) OR '
        "(target_type = 'plan_block' AND plan_block_id = target_id "
        'AND event_id IS NULL AND task_id IS NULL))',
  ];
}

class UndoSlot extends Table {
  IntColumn get slot => integer().withDefault(const Constant(1))();
  TextColumn get commandId => text()();
  TextColumn get payload => text()();
  IntColumn get expiresAt => integer().nullable()();
  IntColumn get createdAt => integer()();

  @override
  String get tableName => 'undo_slot';

  @override
  Set<Column<Object>> get primaryKey => {slot};

  @override
  List<String> get customConstraints => ['CHECK (slot = 1)'];
}
