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
  TextColumn get timezone => text()();
  IntColumn get startAt => integer()();
  IntColumn get durationMinutes => integer()();
  TextColumn get recurrenceJson => text()();
  TextColumn get effectiveFrom => text().nullable()();
  TextColumn get effectiveThrough => text().nullable()();
  TextColumn get locationName => text().nullable()();
  TextColumn get completionPolicy =>
      text().withDefault(const Constant('auto_complete'))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  String get tableName => 'calendar_event_series';

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (duration_minutes > 0)',
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
  TextColumn get personalSeriesId => text()
      .nullable()
      .references(CalendarEventSeries, #id, onDelete: KeyAction.cascade)();
  TextColumn get occurrenceKey => text().nullable()();
  TextColumn get title => text()();
  TextColumn get description => text().nullable()();
  TextColumn get type => text()();
  TextColumn get status =>
      text().withDefault(const Constant('active'))();
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
  TextColumn get importance =>
      text().withDefault(const Constant('normal'))();
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
  TextColumn get seriesId => text()
      .references(CalendarEventSeries, #id, onDelete: KeyAction.cascade)();
  TextColumn get occurrenceKey => text()();
  TextColumn get kind => text()();
  TextColumn get overrideJson => text()();
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
  ];
}

class UserOverlays extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(LocalAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get eventId =>
      text().references(CalendarEvents, #id, onDelete: KeyAction.cascade)();
  TextColumn get displayTitle => text().nullable()();
  TextColumn get attendancePolicy => text().nullable()();
  TextColumn get attendanceDecision => text().nullable()();
  IntColumn get attendanceDecisionAt => integer().nullable()();
  TextColumn get attendanceNote => text().nullable()();
  TextColumn get attendanceOutcome => text().nullable()();
  TextColumn get listeningMode => text().nullable()();
  TextColumn get listeningNote => text().nullable()();
  TextColumn get importance => text().nullable()();
  TextColumn get color => text().nullable()();
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
  ];
}
