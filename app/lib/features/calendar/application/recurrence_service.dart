import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../domain/personal_event.dart';
import '../domain/recurrence_expander.dart';
import '../domain/recurrence_rule.dart';

class OccurrenceNotFoundError implements Exception {
  const OccurrenceNotFoundError();

  @override
  String toString() => 'OccurrenceNotFoundError';
}

class OverrideValue<T> {
  const OverrideValue.set(this.value) : isSet = true;
  const OverrideValue.absent() : isSet = false, value = null;

  final bool isSet;
  final T? value;
}

class OccurrenceOverride {
  const OccurrenceOverride({
    this.title = const OverrideValue.absent(),
    this.description = const OverrideValue.absent(),
    this.locationName = const OverrideValue.absent(),
    this.startAt = const OverrideValue.absent(),
    this.endAt = const OverrideValue.absent(),
    this.startDate = const OverrideValue.absent(),
    this.endDateExclusive = const OverrideValue.absent(),
    this.status = const OverrideValue.absent(),
    this.completionPolicy = const OverrideValue.absent(),
    this.importance = const OverrideValue.absent(),
    this.color = const OverrideValue.absent(),
    this.tags = const OverrideValue.absent(),
    this.reminderOffsetsMinutes = const OverrideValue.absent(),
  });

  final OverrideValue<String> title;
  final OverrideValue<String?> description;
  final OverrideValue<String?> locationName;
  final OverrideValue<DateTime> startAt;
  final OverrideValue<DateTime> endAt;
  final OverrideValue<DateTime> startDate;
  final OverrideValue<DateTime> endDateExclusive;
  final OverrideValue<EventStatus> status;
  final OverrideValue<CompletionPolicy> completionPolicy;
  final OverrideValue<String> importance;
  final OverrideValue<String?> color;
  final OverrideValue<List<String>> tags;
  final OverrideValue<List<int>> reminderOffsetsMinutes;

  Set<String> get fields => {
    if (title.isSet) 'title',
    if (description.isSet) 'description',
    if (locationName.isSet) 'locationName',
    if (startAt.isSet) 'startAt',
    if (endAt.isSet) 'endAt',
    if (startDate.isSet) 'startDate',
    if (endDateExclusive.isSet) 'endDateExclusive',
    if (status.isSet) 'status',
    if (completionPolicy.isSet) 'completionPolicy',
    if (importance.isSet) 'importance',
    if (color.isSet) 'color',
    if (tags.isSet) 'tags',
    if (reminderOffsetsMinutes.isSet) 'reminderOffsetsMinutes',
  };

  Map<String, Object?> toJson() => {
    if (title.isSet) 'title': title.value,
    if (description.isSet) 'description': description.value,
    if (locationName.isSet) 'locationName': locationName.value,
    if (startAt.isSet) 'startAt': startAt.value?.millisecondsSinceEpoch,
    if (endAt.isSet) 'endAt': endAt.value?.millisecondsSinceEpoch,
    if (startDate.isSet) 'startDate': _nullableDate(startDate.value),
    if (endDateExclusive.isSet)
      'endDateExclusive': _nullableDate(endDateExclusive.value),
    if (status.isSet) 'status': status.value?.storage,
    if (completionPolicy.isSet)
      'completionPolicy': completionPolicy.value?.storage,
    if (importance.isSet) 'importance': importance.value,
    if (color.isSet) 'color': color.value,
    if (tags.isSet) 'tags': tags.value,
    if (reminderOffsetsMinutes.isSet)
      'reminderOffsetsMinutes': reminderOffsetsMinutes.value,
  };

  static OccurrenceOverride decode(String fieldsJson, String payloadJson) {
    final fields = (jsonDecode(fieldsJson) as List<dynamic>).cast<String>();
    final payload = jsonDecode(payloadJson) as Map<String, dynamic>;
    bool has(String field) => fields.contains(field);
    return OccurrenceOverride(
      title: has('title')
          ? OverrideValue.set(payload['title'] as String)
          : const OverrideValue.absent(),
      description: has('description')
          ? OverrideValue.set(payload['description'] as String?)
          : const OverrideValue.absent(),
      locationName: has('locationName')
          ? OverrideValue.set(payload['locationName'] as String?)
          : const OverrideValue.absent(),
      startAt: has('startAt')
          ? OverrideValue.set(
              DateTime.fromMillisecondsSinceEpoch(payload['startAt'] as int),
            )
          : const OverrideValue.absent(),
      endAt: has('endAt')
          ? OverrideValue.set(
              DateTime.fromMillisecondsSinceEpoch(payload['endAt'] as int),
            )
          : const OverrideValue.absent(),
      startDate: has('startDate')
          ? OverrideValue.set(DateTime.parse(payload['startDate'] as String))
          : const OverrideValue.absent(),
      endDateExclusive: has('endDateExclusive')
          ? OverrideValue.set(
              DateTime.parse(payload['endDateExclusive'] as String),
            )
          : const OverrideValue.absent(),
      status: has('status')
          ? OverrideValue.set(
              eventStatusFromStorage(payload['status'] as String),
            )
          : const OverrideValue.absent(),
      completionPolicy: has('completionPolicy')
          ? OverrideValue.set(
              completionPolicyFromStorage(
                payload['completionPolicy'] as String,
              ),
            )
          : const OverrideValue.absent(),
      importance: has('importance')
          ? OverrideValue.set(payload['importance'] as String)
          : const OverrideValue.absent(),
      color: has('color')
          ? OverrideValue.set(payload['color'] as String?)
          : const OverrideValue.absent(),
      tags: has('tags')
          ? OverrideValue.set((payload['tags'] as List<dynamic>).cast<String>())
          : const OverrideValue.absent(),
      reminderOffsetsMinutes: has('reminderOffsetsMinutes')
          ? OverrideValue.set(
              (payload['reminderOffsetsMinutes'] as List<dynamic>)
                  .cast<int>(),
            )
          : const OverrideValue.absent(),
    );
  }

  static String? _nullableDate(DateTime? value) =>
      value == null ? null : dateText(value);
}

class RecurringOccurrence {
  const RecurringOccurrence({
    required this.seriesId,
    required this.occurrenceKey,
    required this.originalStart,
    required this.title,
    required this.allDay,
    required this.status,
    required this.completionPolicy,
    required this.importance,
    required this.tags,
    required this.overriddenFields,
    this.reminderOffsetsMinutes = const [],
    this.startAt,
    this.endAt,
    this.startDate,
    this.endDateExclusive,
    this.description,
    this.locationName,
    this.color,
  });

  final String seriesId;
  final String occurrenceKey;
  final DateTime originalStart;
  final String title;
  final bool allDay;
  final DateTime? startAt;
  final DateTime? endAt;
  final DateTime? startDate;
  final DateTime? endDateExclusive;
  final String? description;
  final String? locationName;
  final EventStatus status;
  final CompletionPolicy completionPolicy;
  final String importance;
  final String? color;
  final List<String> tags;
  final List<int> reminderOffsetsMinutes;
  final Set<String> overriddenFields;
}

class SeriesEditImpact {
  const SeriesEditImpact({
    required this.affectedOccurrences,
    required this.newlyOrphaned,
    required this.continuesBeyondHorizon,
  });

  final int affectedOccurrences;
  final int newlyOrphaned;
  final bool continuesBeyondHorizon;
}

class RecurrenceService {
  RecurrenceService({
    required this.database,
    required this.accountId,
    int Function()? now,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppDatabase database;
  final String accountId;
  final int Function() now;
  static const _uuid = Uuid();

  Future<String> createSeries({
    required PersonalEvent anchor,
    required RecurrenceRule rule,
    List<int>? reminderOffsetsMinutes,
  }) async {
    _validateAnchor(anchor, rule);
    final offsets = _normalizeOrValidateOffsets(
      reminderOffsetsMinutes,
      allDay: anchor.allDay,
    );
    final id = _uuid.v4();
    await database.transaction(() async {
      await _insertSeries(id, anchor, rule, reminderOffsetsMinutes: offsets);
      await _log('calendar_series_create', 'Created a recurring event.');
    });
    return id;
  }

  Future<CalendarEventSery> seriesRow(String seriesId) =>
      (database.select(database.calendarEventSeries)..where(
            (row) => row.id.equals(seriesId) & row.accountId.equals(accountId),
          ))
          .getSingle();

  Future<CalendarEventSery?> seriesRowOrNull(String seriesId) =>
      (database.select(database.calendarEventSeries)..where(
            (row) => row.id.equals(seriesId) & row.accountId.equals(accountId),
          ))
          .getSingleOrNull();

  Future<List<CalendarEventOccurrenceException>> exceptionRows(
    String seriesId,
  ) =>
      (database.select(database.calendarEventOccurrenceExceptions)..where(
            (row) =>
                row.accountId.equals(accountId) & row.seriesId.equals(seriesId),
          ))
          .get();

  /// All series owned by the bound [accountId], regardless of effective bounds
  /// or lifecycle state. Used by the read-only recurrence projection; it never
  /// materializes occurrences into `calendar_events`.
  Future<List<CalendarEventSery>> allSeries() =>
      (database.select(database.calendarEventSeries)
            ..where((row) => row.accountId.equals(accountId)))
          .get();

  /// Exposes occurrence composition to the read-only projection. Composes the
  /// series anchor with an optional exception (override/cancel), preserving the
  /// original recurrence position even when a time override moves the
  /// occurrence to a different effective time.
  RecurringOccurrence composeOccurrence(
    CalendarEventSery series,
    DateTime original,
    CalendarEventOccurrenceException? exception,
  ) =>
      _compose(series, original, exception);

  /// Whether [original] falls within the series' stored effective bounds
  /// (effective_from/effective_through), independent of the recurrence rule.
  bool withinSeriesBounds(CalendarEventSery series, DateTime original) =>
      _withinSeriesBounds(series, original);

  Future<RecurringOccurrence> occurrence(String seriesId, String key) async {
    final series = await seriesRow(seriesId);
    final original = _originalFromKey(seriesId, key);
    final exception =
        await (database.select(database.calendarEventOccurrenceExceptions)
              ..where(
                (row) =>
                    row.accountId.equals(accountId) &
                    row.seriesId.equals(seriesId) &
                    row.occurrenceKey.equals(key),
              ))
            .getSingleOrNull();
    if (exception?.orphaned == true || exception?.deletedAt != null) {
      throw const OccurrenceNotFoundError();
    }
    if (!_contains(series, original)) {
      throw const OccurrenceNotFoundError();
    }
    return _compose(series, original, exception);
  }

  Future<List<RecurringOccurrence>> occurrences(
    String seriesId, {
    required DateTime from,
    required DateTime through,
  }) async {
    final series = await seriesRow(seriesId);
    final rule = RecurrenceRule.decode(series.recurrenceJson);
    final originals = expandRecurrence(
      rule,
      from: from,
      through: through,
    ).where((value) => _withinSeriesBounds(series, value));
    final exceptions = {
      for (final row in await exceptionRows(seriesId)) row.occurrenceKey: row,
    };
    return [
      for (final original in originals)
        if (exceptions[occurrenceKey(seriesId, original)]?.orphaned != true &&
            exceptions[occurrenceKey(seriesId, original)]?.deletedAt == null)
          _compose(
            series,
            original,
            exceptions[occurrenceKey(seriesId, original)],
          ),
    ];
  }

  Future<CalendarEventOccurrenceException?> existingOccurrenceAnchor(
    String seriesId,
    String occurrenceKey,
  ) async {
    return (database.select(database.calendarEventOccurrenceExceptions)
          ..where(
            (row) =>
                row.accountId.equals(accountId) &
                row.seriesId.equals(seriesId) &
                row.occurrenceKey.equals(occurrenceKey),
          ))
        .getSingleOrNull();
  }

  Future<CalendarEventOccurrenceException> ensureOccurrenceAnchor(
    String seriesId,
    String occurrenceKey,
  ) async {
    final series = await seriesRowOrNull(seriesId);
    if (series == null) {
      throw const OccurrenceNotFoundError();
    }
    final original = _originalFromKey(seriesId, occurrenceKey);
    if (!_contains(series, original)) {
      throw const OccurrenceNotFoundError();
    }
    final timestamp = now();
    return database.transaction(() async {
      final existing = await existingOccurrenceAnchor(
        seriesId,
        occurrenceKey,
      );
      if (existing != null) {
        return existing;
      }
      final id = _uuid.v4();
      await database
          .into(database.calendarEventOccurrenceExceptions)
          .insert(
            CalendarEventOccurrenceExceptionsCompanion.insert(
              id: id,
              accountId: accountId,
              seriesId: seriesId,
              occurrenceKey: occurrenceKey,
              originalStartAt: Value(
                series.allDay
                    ? null
                    : original.millisecondsSinceEpoch,
              ),
              originalStartDate: Value(
                series.allDay ? dateText(original) : null,
              ),
              kind: 'override',
              overriddenFieldsJson: const Value('[]'),
              overrideJson: '{}',
              orphaned: const Value(false),
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
            mode: InsertMode.insertOrIgnore,
          );
      return (await existingOccurrenceAnchor(seriesId, occurrenceKey))!;
    });
  }

  Future<void> editOnlyThis(
    String seriesId,
    String key,
    OccurrenceOverride override,
  ) async {
    final normalizedOverride = _normalizeOverrideOffsets(override);
    await database.transaction(() async {
      final current = await occurrence(seriesId, key);
      final updated = _applyOverride(current, normalizedOverride);
      _validateOccurrence(updated);
      final existing =
          await (database.select(database.calendarEventOccurrenceExceptions)
                ..where(
                  (row) =>
                      row.accountId.equals(accountId) &
                      row.seriesId.equals(seriesId) &
                      row.occurrenceKey.equals(key),
                ))
              .getSingleOrNull();
      final timestamp = now();
      await database
          .into(database.calendarEventOccurrenceExceptions)
          .insertOnConflictUpdate(
            CalendarEventOccurrenceExceptionsCompanion.insert(
              id: existing?.id ?? _uuid.v4(),
              accountId: accountId,
              seriesId: seriesId,
              occurrenceKey: key,
              originalStartAt: Value(
                current.allDay
                    ? null
                    : current.originalStart.millisecondsSinceEpoch,
              ),
              originalStartDate: Value(
                current.allDay ? dateText(current.originalStart) : null,
              ),
              kind: 'override',
              overriddenFieldsJson: Value(
                jsonEncode(normalizedOverride.fields.toList()..sort()),
              ),
              overrideJson: jsonEncode(normalizedOverride.toJson()),
              status: Value(normalizedOverride.status.value?.storage),
              orphaned: const Value(false),
              createdAt: existing?.createdAt ?? timestamp,
              updatedAt: timestamp,
            ),
          );
      await _log(
        'calendar_occurrence_edit',
        'Updated one recurring occurrence.',
      );
    });
  }

  Future<String> editThisAndFuture(
    String seriesId,
    String selectedKey, {
    required PersonalEvent anchor,
    required RecurrenceRule rule,
  }) async {
    _validateAnchor(anchor, rule);
    return database.transaction(() async {
      final selected = await occurrence(seriesId, selectedKey);
      final oldSeries = await seriesRow(seriesId);
      final newSeriesId = _uuid.v4();
      final boundary = dateOnly(
        selected.originalStart,
      ).subtract(const Duration(days: 1));
      await (database.update(
        database.calendarEventSeries,
      )..where((row) => row.id.equals(seriesId))).write(
        CalendarEventSeriesCompanion(
          effectiveThrough: Value(dateText(boundary)),
          updatedAt: Value(now()),
        ),
      );
      await _insertSeries(newSeriesId, anchor, rule);

      final exceptions = await exceptionRows(seriesId);
      for (final exception in exceptions) {
        final original = _exceptionOriginal(exception);
        if (original.isBefore(selected.originalStart)) continue;
        final compatible = _ruleContains(rule, original);
        if (!compatible) {
          await (database.update(
            database.calendarEventOccurrenceExceptions,
          )..where((row) => row.id.equals(exception.id))).write(
            CalendarEventOccurrenceExceptionsCompanion(
              orphaned: const Value(true),
              updatedAt: Value(now()),
            ),
          );
          continue;
        }
        await (database.update(
          database.calendarEventOccurrenceExceptions,
        )..where((row) => row.id.equals(exception.id))).write(
          CalendarEventOccurrenceExceptionsCompanion(
            seriesId: Value(newSeriesId),
            occurrenceKey: Value(occurrenceKey(newSeriesId, original)),
            orphaned: const Value(false),
            updatedAt: Value(now()),
          ),
        );
      }
      await _log(
        'calendar_series_split',
        'Updated this and future recurring occurrences.',
      );
      if (oldSeries.effectiveThrough != null &&
          oldSeries.effectiveThrough!.compareTo(dateText(boundary)) < 0) {
        throw const RecurrenceValidationError(
          'split would extend a closed series',
        );
      }
      return newSeriesId;
    });
  }

  Future<SeriesEditImpact> editWholeSeries(
    String seriesId, {
    required PersonalEvent anchor,
    required RecurrenceRule rule,
  }) async {
    _validateAnchor(anchor, rule);
    return database.transaction(() async {
      await seriesRow(seriesId);
      await (database.update(database.calendarEventSeries)
            ..where((row) => row.id.equals(seriesId)))
          .write(_seriesUpdate(anchor, rule));
      var newlyOrphaned = 0;
      for (final exception in await exceptionRows(seriesId)) {
        final orphaned = !_ruleContains(rule, _exceptionOriginal(exception));
        if (orphaned && !exception.orphaned) newlyOrphaned++;
        await (database.update(
          database.calendarEventOccurrenceExceptions,
        )..where((row) => row.id.equals(exception.id))).write(
          CalendarEventOccurrenceExceptionsCompanion(
            orphaned: Value(orphaned),
            updatedAt: Value(now()),
          ),
        );
      }
      final horizon = dateOnly(rule.anchor).add(const Duration(days: 365));
      final affected = expandRecurrence(
        rule,
        from: rule.anchor,
        through: DateTime(horizon.year, horizon.month, horizon.day, 23, 59, 59),
      ).length;
      await _log('calendar_series_edit', 'Updated a recurring event series.');
      return SeriesEditImpact(
        affectedOccurrences: affected,
        newlyOrphaned: newlyOrphaned,
        continuesBeyondHorizon:
            rule.untilDate == null || rule.untilDate!.isAfter(horizon),
      );
    });
  }

  Future<void> _insertSeries(
    String id,
    PersonalEvent anchor,
    RecurrenceRule rule, {
    List<int>? reminderOffsetsMinutes,
  }) async {
    final timestamp = now();
    await database
        .into(database.calendarEventSeries)
        .insert(
          CalendarEventSeriesCompanion.insert(
            id: id,
            accountId: accountId,
            reminderOffsetsJson: Value(
              jsonEncode(
                reminderOffsetsMinutes ??
                    _normalizeOrValidateOffsets(
                      null,
                      allDay: anchor.allDay,
                    ),
              ),
            ),
            title: anchor.title,
            description: Value(anchor.description),
            eventType: anchor.type.storage,
            status: Value(anchor.status.storage),
            timezone: 'Asia/Shanghai',
            allDay: Value(anchor.allDay),
            startAt: Value(anchor.startAt?.millisecondsSinceEpoch),
            durationMinutes: Value(
              anchor.allDay
                  ? null
                  : anchor.endAt!.difference(anchor.startAt!).inMinutes,
            ),
            anchorStartDate: Value(
              anchor.allDay ? dateText(anchor.startDate!) : null,
            ),
            durationDays: Value(
              anchor.allDay
                  ? anchor.endDateExclusive!
                        .difference(anchor.startDate!)
                        .inDays
                  : null,
            ),
            recurrenceJson: rule.encode(),
            effectiveFrom: Value(
              dateText(anchor.allDay ? anchor.startDate! : anchor.startAt!),
            ),
            effectiveThrough: Value(
              rule.untilDate == null ? null : dateText(rule.untilDate!),
            ),
            locationName: Value(anchor.locationName),
            importance: Value(anchor.importance),
            color: Value(anchor.color),
            completionPolicy: Value(anchor.completionPolicy.storage),
            tagsJson: Value(jsonEncode(anchor.tags)),
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );
  }

  CalendarEventSeriesCompanion _seriesUpdate(
    PersonalEvent anchor,
    RecurrenceRule rule,
  ) => CalendarEventSeriesCompanion(
    title: Value(anchor.title),
    description: Value(anchor.description),
    eventType: Value(anchor.type.storage),
    status: Value(anchor.status.storage),
    allDay: Value(anchor.allDay),
    startAt: Value(anchor.startAt?.millisecondsSinceEpoch),
    durationMinutes: Value(
      anchor.allDay
          ? null
          : anchor.endAt!.difference(anchor.startAt!).inMinutes,
    ),
    anchorStartDate: Value(anchor.allDay ? dateText(anchor.startDate!) : null),
    durationDays: Value(
      anchor.allDay
          ? anchor.endDateExclusive!.difference(anchor.startDate!).inDays
          : null,
    ),
    recurrenceJson: Value(rule.encode()),
    effectiveFrom: Value(
      dateText(anchor.allDay ? anchor.startDate! : anchor.startAt!),
    ),
    effectiveThrough: Value(
      rule.untilDate == null ? null : dateText(rule.untilDate!),
    ),
    locationName: Value(anchor.locationName),
    importance: Value(anchor.importance),
    color: Value(anchor.color),
    completionPolicy: Value(anchor.completionPolicy.storage),
    tagsJson: Value(jsonEncode(anchor.tags)),
    updatedAt: Value(now()),
  );

  RecurringOccurrence _compose(
    CalendarEventSery series,
    DateTime original,
    CalendarEventOccurrenceException? exception,
  ) {
    final allDay = series.allDay;
    final base = RecurringOccurrence(
      seriesId: series.id,
      occurrenceKey: occurrenceKey(series.id, original),
      originalStart: original,
      title: series.title,
      allDay: allDay,
      reminderOffsetsMinutes: _decodeOffsets(series.reminderOffsetsJson),
      startAt: allDay ? null : original,
      endAt: allDay
          ? null
          : original.add(Duration(minutes: series.durationMinutes!)),
      startDate: allDay ? dateOnly(original) : null,
      endDateExclusive: allDay
          ? dateOnly(original).add(Duration(days: series.durationDays!))
          : null,
      description: series.description,
      locationName: series.locationName,
      status: eventStatusFromStorage(series.status),
      completionPolicy: completionPolicyFromStorage(series.completionPolicy),
      importance: series.importance,
      color: series.color,
      tags: (jsonDecode(series.tagsJson) as List<dynamic>).cast<String>(),
      overriddenFields: const {},
    );
    if (exception == null) return base;
    return _applyOverride(
      base,
      OccurrenceOverride.decode(
        exception.overriddenFieldsJson,
        exception.overrideJson,
      ),
    );
  }

  RecurringOccurrence _applyOverride(
    RecurringOccurrence base,
    OccurrenceOverride value,
  ) {
    var startAt = value.startAt.isSet ? value.startAt.value : base.startAt;
    var endAt = value.endAt.isSet ? value.endAt.value : base.endAt;
    if (value.startAt.isSet && !value.endAt.isSet && startAt != null) {
      endAt = startAt.add(base.endAt!.difference(base.startAt!));
    }
    var startDate = value.startDate.isSet
        ? value.startDate.value
        : base.startDate;
    var endDate = value.endDateExclusive.isSet
        ? value.endDateExclusive.value
        : base.endDateExclusive;
    if (value.startDate.isSet &&
        !value.endDateExclusive.isSet &&
        startDate != null) {
      endDate = startDate.add(
        Duration(
          days: base.endDateExclusive!.difference(base.startDate!).inDays,
        ),
      );
    }
    return RecurringOccurrence(
      seriesId: base.seriesId,
      occurrenceKey: base.occurrenceKey,
      originalStart: base.originalStart,
      title: value.title.isSet ? value.title.value! : base.title,
      allDay: base.allDay,
      startAt: startAt,
      endAt: endAt,
      startDate: startDate,
      endDateExclusive: endDate,
      description: value.description.isSet
          ? value.description.value
          : base.description,
      locationName: value.locationName.isSet
          ? value.locationName.value
          : base.locationName,
      status: value.status.isSet ? value.status.value! : base.status,
      completionPolicy: value.completionPolicy.isSet
          ? value.completionPolicy.value!
          : base.completionPolicy,
      importance: value.importance.isSet
          ? value.importance.value!
          : base.importance,
      color: value.color.isSet ? value.color.value : base.color,
      tags: value.tags.isSet ? value.tags.value! : base.tags,
      reminderOffsetsMinutes: value.reminderOffsetsMinutes.isSet
          ? value.reminderOffsetsMinutes.value!
          : base.reminderOffsetsMinutes,
      overriddenFields: Set.unmodifiable(value.fields),
    );
  }

  static List<int> _decodeOffsets(String json) =>
      (jsonDecode(json) as List<dynamic>).cast<int>();

  bool _contains(CalendarEventSery series, DateTime original) =>
      _withinSeriesBounds(series, original) &&
      _ruleContains(RecurrenceRule.decode(series.recurrenceJson), original);

  bool _ruleContains(RecurrenceRule rule, DateTime original) =>
      expandRecurrence(
        rule,
        from: original,
        through: original,
      ).any((value) => value == original);

  bool _withinSeriesBounds(CalendarEventSery series, DateTime original) {
    final date = dateText(original);
    return (series.effectiveFrom == null ||
            date.compareTo(series.effectiveFrom!) >= 0) &&
        (series.effectiveThrough == null ||
            date.compareTo(series.effectiveThrough!) <= 0);
  }

  DateTime _originalFromKey(String seriesId, String key) {
    try {
      return originalStartFromOccurrenceKey(seriesId, key);
    } on FormatException {
      throw const OccurrenceNotFoundError();
    }
  }

  DateTime _exceptionOriginal(CalendarEventOccurrenceException exception) =>
      exception.originalStartAt != null
      ? DateTime.fromMillisecondsSinceEpoch(exception.originalStartAt!)
      : DateTime.parse(exception.originalStartDate!);

  List<int> _normalizeOrValidateOffsets(
    List<int>? offsets, {
    required bool allDay,
  }) {
    final value = offsets ?? (allDay ? const [] : const [15]);
    return _validateOffsets(value);
  }

  OccurrenceOverride _normalizeOverrideOffsets(OccurrenceOverride override) {
    if (!override.reminderOffsetsMinutes.isSet) return override;
    final normalized = _validateOffsets(override.reminderOffsetsMinutes.value!);
    return OccurrenceOverride(
      title: override.title,
      description: override.description,
      locationName: override.locationName,
      startAt: override.startAt,
      endAt: override.endAt,
      startDate: override.startDate,
      endDateExclusive: override.endDateExclusive,
      status: override.status,
      completionPolicy: override.completionPolicy,
      importance: override.importance,
      color: override.color,
      tags: override.tags,
      reminderOffsetsMinutes: OverrideValue.set(normalized),
    );
  }

  List<int> _validateOffsets(List<int> value) {
    if (value.any((offset) => offset < 0) ||
        value.toSet().length != value.length) {
      throw const RecurrenceValidationError(
        'reminder offsets must be non-negative, unique integers',
      );
    }
    final validated = List<int>.of(value)..sort();
    return validated;
  }

void _validateAnchor(PersonalEvent anchor, RecurrenceRule rule) {
    final start = anchor.allDay ? anchor.startDate! : anchor.startAt!;
    if (start != rule.anchor) {
      throw const RecurrenceValidationError(
        'rule anchor must equal event anchor',
      );
    }
  }

  void _validateOccurrence(RecurringOccurrence occurrence) {
    if (occurrence.allDay) {
      if (occurrence.startDate == null ||
          occurrence.endDateExclusive == null ||
          !occurrence.endDateExclusive!.isAfter(occurrence.startDate!)) {
        throw const CalendarValidationError('invalid all-day override');
      }
    } else if (occurrence.startAt == null ||
        occurrence.endAt == null ||
        !occurrence.endAt!.isAfter(occurrence.startAt!)) {
      throw const CalendarValidationError('invalid timed override');
    }
  }

  Future<void> _log(String actionType, String summary) =>
      database.actionLogsRepository.append(
        accountId: accountId,
        source: 'user',
        actionType: actionType,
        result: 'success',
        safeSummary: summary,
        occurredAt: now(),
      );
}
