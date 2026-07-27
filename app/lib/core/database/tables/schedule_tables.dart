import 'package:drift/drift.dart';

import 'account_tables.dart';

class CourseSeries extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get source => text()();
  TextColumn get externalId => text()();
  TextColumn get title => text()();
  TextColumn get courseCode => text().nullable()();
  TextColumn get semesterKey => text()();
  TextColumn get participantsJson => text().withDefault(const Constant('[]'))();
  TextColumn get sourceDetailsJson => text()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  String get tableName => 'course_series';

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {accountId, source, externalId},
  ];
}

class CalendarEventSeries extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get title => text()();
  TextColumn get description => text().nullable()();
  TextColumn get eventType => text()();
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get timezone => text()();
  BoolColumn get allDay => boolean().withDefault(const Constant(false))();
  IntColumn get startAt => integer().nullable()();
  IntColumn get durationMinutes => integer().nullable()();
  TextColumn get anchorStartDate => text().nullable()();
  IntColumn get durationDays => integer().nullable()();
  TextColumn get recurrenceJson => text()();
  TextColumn get effectiveFrom => text().nullable()();
  TextColumn get effectiveThrough => text().nullable()();
  TextColumn get locationName => text().nullable()();
  TextColumn get importance => text().withDefault(const Constant('normal'))();
  TextColumn get color => text().nullable()();
  TextColumn get completionPolicy =>
      text().withDefault(const Constant('auto_after_end'))();
  TextColumn get tagsJson => text().withDefault(const Constant('[]'))();
  TextColumn get userNotes => text().nullable()();
  IntColumn get deletedAt => integer().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  String get tableName => 'calendar_event_series';

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK ('
        '(all_day = 0 AND start_at IS NOT NULL AND duration_minutes > 0 '
        'AND anchor_start_date IS NULL AND duration_days IS NULL) OR '
        '(all_day = 1 AND start_at IS NULL AND duration_minutes IS NULL '
        'AND anchor_start_date IS NOT NULL AND duration_days > 0)'
        ')',
    "CHECK (status IN ('active','tentative','cancelled','completed',"
        "'skipped','hidden'))",
    'CHECK (effective_through IS NULL OR effective_from IS NULL '
        'OR effective_through >= effective_from)',
  ];
}

class CalendarEvents extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get source => text()();
  TextColumn get externalId => text().nullable()();
  TextColumn get sourceSeriesExternalId => text().nullable()();
  TextColumn get personalSeriesId => text().nullable().references(
    CalendarEventSeries,
    #id,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get occurrenceKey => text().nullable()();
  TextColumn get title => text()();
  TextColumn get description => text().nullable()();
  TextColumn get type => text()();
  TextColumn get status => text().withDefault(const Constant('active'))();
  IntColumn get startAt => integer().nullable()();
  IntColumn get endAt => integer().nullable()();
  BoolColumn get allDay => boolean()();
  TextColumn get startDate => text().nullable()();
  TextColumn get endDateExclusive => text().nullable()();
  TextColumn get timezone => text()();
  TextColumn get locationName => text().nullable()();
  TextColumn get buildingName => text().nullable()();
  TextColumn get campusName => text().nullable()();
  TextColumn get participantsJson => text().withDefault(const Constant('[]'))();
  TextColumn get sourceDetailsJson =>
      text().withDefault(const Constant('{}'))();
  TextColumn get importance => text().withDefault(const Constant('normal'))();
  TextColumn get completionPolicy =>
      text().withDefault(const Constant('auto_complete'))();
  IntColumn get completedAt => integer().nullable()();
  TextColumn get color => text().nullable()();
  TextColumn get tagsJson => text().withDefault(const Constant('[]'))();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get deletedAt => integer().nullable()();

  @override
  String get tableName => 'calendar_events';

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {accountId, source, externalId},
    {accountId, personalSeriesId, occurrenceKey},
  ];

  @override
  List<String> get customConstraints => [
    'CHECK ('
        '(all_day = 0 AND start_at IS NOT NULL AND end_at IS NOT NULL '
        'AND end_at > start_at AND start_date IS NULL '
        'AND end_date_exclusive IS NULL) OR '
        '(all_day = 1 AND start_at IS NULL AND end_at IS NULL '
        'AND start_date IS NOT NULL AND end_date_exclusive IS NOT NULL '
        'AND end_date_exclusive > start_date)'
        ')',
    "CHECK (type IN ('course','exam','second_class','personal',"
        "'entertainment','meal','campus_affair','travel','study','system'))",
    "CHECK (status IN ('active','tentative','cancelled','completed',"
        "'skipped','hidden'))",
  ];
}

class CalendarEventOccurrenceExceptions extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get seriesId => text().references(
    CalendarEventSeries,
    #id,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get occurrenceKey => text()();
  IntColumn get originalStartAt => integer().nullable()();
  TextColumn get originalStartDate => text().nullable()();
  TextColumn get kind => text()();
  TextColumn get overriddenFieldsJson =>
      text().withDefault(const Constant('[]'))();
  TextColumn get overrideJson => text()();
  TextColumn get status => text().nullable()();
  BoolColumn get orphaned => boolean().withDefault(const Constant(false))();
  IntColumn get deletedAt => integer().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  String get tableName => 'calendar_event_occurrence_exceptions';

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {accountId, seriesId, occurrenceKey},
  ];

  @override
  List<String> get customConstraints => [
    "CHECK (kind IN ('override','cancelled'))",
    'CHECK ((original_start_at IS NOT NULL) != '
        '(original_start_date IS NOT NULL))',
  ];
}

class UserOverlays extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get eventId => text().nullable().references(
    CalendarEvents,
    #id,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get courseSeriesId => text().nullable().references(
    CourseSeries,
    #id,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get displayTitle => text().nullable()();
  TextColumn get displayLocation => text().nullable()();
  TextColumn get attendancePolicy => text().nullable()();
  TextColumn get attendanceDecision => text().nullable()();
  IntColumn get attendanceDecisionAt => integer().nullable()();
  TextColumn get attendanceNote => text().nullable()();
  TextColumn get attendanceOutcome => text().nullable()();
  TextColumn get listeningMode => text().nullable()();
  TextColumn get listeningNote => text().nullable()();
  TextColumn get importance => text().nullable()();
  TextColumn get color => text().nullable()();
  IntColumn get foregroundPriority => integer().nullable()();
  BoolColumn get hidden => boolean().nullable()();
  TextColumn get userNotes => text().nullable()();
  TextColumn get tagsJson => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  String get tableName => 'user_overlays';

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {accountId, eventId},
    {accountId, courseSeriesId},
  ];

  @override
  List<String> get customConstraints => [
    'CHECK ((event_id IS NOT NULL) != (course_series_id IS NOT NULL))',
  ];
}
