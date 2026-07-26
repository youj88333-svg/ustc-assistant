import 'dart:convert';

import '../../../core/database/app_database.dart';

enum PersonalEventType {
  personal,
  entertainment,
  meal,
  campusAffair,
  travel,
  study,
}

enum EventStatus { active, tentative, completed, skipped, cancelled, hidden }

enum CompletionPolicy { autoAfterEnd, manualConfirmation }

class CalendarValidationError implements Exception {
  const CalendarValidationError(this.message);

  final String message;

  @override
  String toString() => 'CalendarValidationError: $message';
}

class EffectivePersonalEventState {
  const EffectivePersonalEventState({
    required this.status,
    required this.awaitingCompletion,
  });

  final EventStatus status;
  final bool awaitingCompletion;
}

class PersonalEvent {
  factory PersonalEvent.timed({
    String? id,
    required String title,
    required DateTime startAt,
    required DateTime endAt,
    String? description,
    String? locationName,
    PersonalEventType type = PersonalEventType.personal,
    EventStatus status = EventStatus.active,
    CompletionPolicy completionPolicy = CompletionPolicy.autoAfterEnd,
    String importance = 'normal',
    String? color,
    List<String> tags = const [],
    int? completedAt,
    int? deletedAt,
  }) {
    _requireTitle(title);
    if (!endAt.isAfter(startAt)) {
      throw const CalendarValidationError('endAt must be after startAt');
    }
    return PersonalEvent._(
      id: id,
      title: title.trim(),
      allDay: false,
      startAt: startAt,
      endAt: endAt,
      description: description,
      locationName: locationName,
      type: type,
      status: status,
      completionPolicy: completionPolicy,
      importance: importance,
      color: color,
      tags: List.unmodifiable(tags),
      completedAt: completedAt,
      deletedAt: deletedAt,
    );
  }

  factory PersonalEvent.allDay({
    String? id,
    required String title,
    required DateTime startDate,
    required DateTime endDateExclusive,
    String? description,
    String? locationName,
    PersonalEventType type = PersonalEventType.personal,
    EventStatus status = EventStatus.active,
    CompletionPolicy completionPolicy = CompletionPolicy.autoAfterEnd,
    String importance = 'normal',
    String? color,
    List<String> tags = const [],
    int? completedAt,
    int? deletedAt,
  }) {
    _requireTitle(title);
    final normalizedStart = _date(startDate);
    final normalizedEnd = _date(endDateExclusive);
    if (!normalizedEnd.isAfter(normalizedStart)) {
      throw const CalendarValidationError(
        'endDateExclusive must be after startDate',
      );
    }
    return PersonalEvent._(
      id: id,
      title: title.trim(),
      allDay: true,
      startDate: normalizedStart,
      endDateExclusive: normalizedEnd,
      description: description,
      locationName: locationName,
      type: type,
      status: status,
      completionPolicy: completionPolicy,
      importance: importance,
      color: color,
      tags: List.unmodifiable(tags),
      completedAt: completedAt,
      deletedAt: deletedAt,
    );
  }

  const PersonalEvent._({
    required this.id,
    required this.title,
    required this.allDay,
    required this.type,
    required this.status,
    required this.completionPolicy,
    required this.importance,
    required this.tags,
    this.startAt,
    this.endAt,
    this.startDate,
    this.endDateExclusive,
    this.description,
    this.locationName,
    this.color,
    this.completedAt,
    this.deletedAt,
  });

  final String? id;
  final String title;
  final bool allDay;
  final DateTime? startAt;
  final DateTime? endAt;
  final DateTime? startDate;
  final DateTime? endDateExclusive;
  final String? description;
  final String? locationName;
  final PersonalEventType type;
  final EventStatus status;
  final CompletionPolicy completionPolicy;
  final String importance;
  final String? color;
  final List<String> tags;
  final int? completedAt;
  final int? deletedAt;

  EffectivePersonalEventState effectiveState(DateTime now) {
    if (status != EventStatus.active && status != EventStatus.tentative) {
      return EffectivePersonalEventState(
        status: status,
        awaitingCompletion: false,
      );
    }
    final ended = allDay
        ? !_date(now).isBefore(endDateExclusive!)
        : !now.isBefore(endAt!);
    if (!ended) {
      return EffectivePersonalEventState(
        status: status,
        awaitingCompletion: false,
      );
    }
    if (completionPolicy == CompletionPolicy.manualConfirmation) {
      return EffectivePersonalEventState(
        status: status,
        awaitingCompletion: true,
      );
    }
    return const EffectivePersonalEventState(
      status: EventStatus.completed,
      awaitingCompletion: false,
    );
  }

  static PersonalEvent fromRow(CalendarEvent row) {
    final type = personalEventTypeFromStorage(row.type);
    final status = eventStatusFromStorage(row.status);
    final policy = completionPolicyFromStorage(row.completionPolicy);
    final tags = _decodeTags(row.tagsJson);
    return row.allDay
        ? PersonalEvent.allDay(
            id: row.id,
            title: row.title,
            startDate: DateTime.parse(row.startDate!),
            endDateExclusive: DateTime.parse(row.endDateExclusive!),
            description: row.description,
            locationName: row.locationName,
            type: type,
            status: status,
            completionPolicy: policy,
            importance: row.importance,
            color: row.color,
            tags: tags,
            completedAt: row.completedAt,
            deletedAt: row.deletedAt,
          )
        : PersonalEvent.timed(
            id: row.id,
            title: row.title,
            startAt: DateTime.fromMillisecondsSinceEpoch(row.startAt!),
            endAt: DateTime.fromMillisecondsSinceEpoch(row.endAt!),
            description: row.description,
            locationName: row.locationName,
            type: type,
            status: status,
            completionPolicy: policy,
            importance: row.importance,
            color: row.color,
            tags: tags,
            completedAt: row.completedAt,
            deletedAt: row.deletedAt,
          );
  }

  static void _requireTitle(String title) {
    if (title.trim().isEmpty) {
      throw const CalendarValidationError('title must not be empty');
    }
  }

  static DateTime _date(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static List<String> _decodeTags(String value) {
    final decoded = jsonDecode(value) as List<dynamic>;
    return decoded.cast<String>().toList(growable: false);
  }
}

extension PersonalEventTypeStorage on PersonalEventType {
  String get storage => switch (this) {
    PersonalEventType.personal => 'personal',
    PersonalEventType.entertainment => 'entertainment',
    PersonalEventType.meal => 'meal',
    PersonalEventType.campusAffair => 'campus_affair',
    PersonalEventType.travel => 'travel',
    PersonalEventType.study => 'study',
  };
}

extension EventStatusStorage on EventStatus {
  String get storage => name;
}

extension CompletionPolicyStorage on CompletionPolicy {
  String get storage => switch (this) {
    CompletionPolicy.autoAfterEnd => 'auto_after_end',
    CompletionPolicy.manualConfirmation => 'manual_confirmation',
  };
}

PersonalEventType personalEventTypeFromStorage(String value) => switch (value) {
  'entertainment' => PersonalEventType.entertainment,
  'meal' => PersonalEventType.meal,
  'campus_affair' => PersonalEventType.campusAffair,
  'travel' => PersonalEventType.travel,
  'study' => PersonalEventType.study,
  _ => PersonalEventType.personal,
};

EventStatus eventStatusFromStorage(String value) => switch (value) {
  'tentative' => EventStatus.tentative,
  'completed' => EventStatus.completed,
  'skipped' => EventStatus.skipped,
  'cancelled' => EventStatus.cancelled,
  'hidden' => EventStatus.hidden,
  _ => EventStatus.active,
};

CompletionPolicy completionPolicyFromStorage(String value) =>
    value == 'manual_confirmation'
    ? CompletionPolicy.manualConfirmation
    : CompletionPolicy.autoAfterEnd;
