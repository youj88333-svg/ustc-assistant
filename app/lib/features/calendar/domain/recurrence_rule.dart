import 'dart:convert';

enum RecurrenceFrequency { daily, weekly, monthly }

class RecurrenceValidationError implements Exception {
  const RecurrenceValidationError(this.message);

  final String message;

  @override
  String toString() => 'RecurrenceValidationError: $message';
}

class RecurrenceRule {
  factory RecurrenceRule.daily({
    required DateTime anchor,
    int interval = 1,
    DateTime? untilDate,
  }) => RecurrenceRule._validated(
    frequency: RecurrenceFrequency.daily,
    anchor: anchor,
    interval: interval,
    untilDate: untilDate,
  );

  factory RecurrenceRule.weekly({
    required DateTime anchor,
    required Set<int> weekdays,
    int interval = 1,
    DateTime? untilDate,
  }) => RecurrenceRule._validated(
    frequency: RecurrenceFrequency.weekly,
    anchor: anchor,
    interval: interval,
    weekdays: weekdays,
    untilDate: untilDate,
  );

  factory RecurrenceRule.monthly({
    required DateTime anchor,
    int interval = 1,
    DateTime? untilDate,
  }) => RecurrenceRule._validated(
    frequency: RecurrenceFrequency.monthly,
    anchor: anchor,
    interval: interval,
    untilDate: untilDate,
  );

  factory RecurrenceRule._validated({
    required RecurrenceFrequency frequency,
    required DateTime anchor,
    required int interval,
    Set<int> weekdays = const {},
    DateTime? untilDate,
  }) {
    if (interval <= 0) {
      throw const RecurrenceValidationError('interval must be positive');
    }
    if (frequency == RecurrenceFrequency.weekly && weekdays.isEmpty) {
      throw const RecurrenceValidationError(
        'weekly recurrence requires weekdays',
      );
    }
    if (weekdays.any(
      (weekday) => weekday < DateTime.monday || weekday > DateTime.sunday,
    )) {
      throw const RecurrenceValidationError('weekday is out of range');
    }
    final normalizedUntil = untilDate == null ? null : dateOnly(untilDate);
    if (normalizedUntil != null && normalizedUntil.isBefore(dateOnly(anchor))) {
      throw const RecurrenceValidationError('untilDate cannot precede anchor');
    }
    return RecurrenceRule._(
      frequency: frequency,
      anchor: anchor,
      interval: interval,
      weekdays: Set.unmodifiable(weekdays),
      untilDate: normalizedUntil,
    );
  }

  const RecurrenceRule._({
    required this.frequency,
    required this.anchor,
    required this.interval,
    required this.weekdays,
    required this.untilDate,
  });

  final RecurrenceFrequency frequency;
  final DateTime anchor;
  final int interval;
  final Set<int> weekdays;
  final DateTime? untilDate;

  Map<String, Object?> toJson() => {
    'version': 1,
    'frequency': frequency.name,
    'interval': interval,
    'weekdays': weekdays.toList()..sort(),
    'untilDate': untilDate == null ? null : dateText(untilDate!),
    'anchorLocal': localDateTimeText(anchor),
    'timezone': 'Asia/Shanghai',
  };

  String encode() => jsonEncode(toJson());

  static RecurrenceRule decode(String value) {
    final json = jsonDecode(value) as Map<String, dynamic>;
    final anchor = DateTime.parse(json['anchorLocal'] as String);
    final untilText = json['untilDate'] as String?;
    final frequency = json['frequency'] as String;
    final interval = json['interval'] as int;
    return switch (frequency) {
      'daily' => RecurrenceRule.daily(
        anchor: anchor,
        interval: interval,
        untilDate: untilText == null ? null : DateTime.parse(untilText),
      ),
      'weekly' => RecurrenceRule.weekly(
        anchor: anchor,
        interval: interval,
        weekdays: (json['weekdays'] as List<dynamic>).cast<int>().toSet(),
        untilDate: untilText == null ? null : DateTime.parse(untilText),
      ),
      'monthly' => RecurrenceRule.monthly(
        anchor: anchor,
        interval: interval,
        untilDate: untilText == null ? null : DateTime.parse(untilText),
      ),
      _ => throw const RecurrenceValidationError('unknown frequency'),
    };
  }
}

DateTime dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

String dateText(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String localDateTimeText(DateTime value) =>
    '${dateText(value)}T'
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}:'
    '${value.second.toString().padLeft(2, '0')}';
