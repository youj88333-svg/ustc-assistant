import 'package:ustc_assistant_m0/core/agent_parameter_issue.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';

/// JSON schema for the fixed pair of reminder slots accepted by Agent tools.
Map<String, Object?> agentReminderPairSchema({bool? allDay}) {
  final variants = <Map<String, Object?>>[_noneRuleSchema()];
  if (allDay != true) variants.add(_beforeRuleSchema());
  if (allDay != false) variants.add(_dayTimeRuleSchema());
  return {
    'type': 'array',
    'minItems': 2,
    'maxItems': 2,
    'items': {'oneOf': variants},
  };
}

/// Parses the safe Agent wire form into the reminder contract's two slots.
///
/// When [allDay] is unknown, either timed rule form is accepted. The caller
/// must validate the complete pair against the resolved target before use.
ReminderPair parseAgentReminderPair(
  Object? raw, {
  bool? allDay,
  AgentParameterField field = AgentParameterField.reminders,
}) {
  if (raw is! List || raw.length != 2) {
    _invalid(field);
  }
  final first = _parseRule(raw[0], allDay: allDay, field: field);
  final second = _parseRule(raw[1], allDay: allDay, field: field);
  return ReminderPair(first, second);
}

/// Converts a reminder pair to the fixed Agent wire form without native IDs.
List<Map<String, Object?>> agentReminderPairToWire(ReminderPair pair) => [
  _ruleToWire(pair.first),
  _ruleToWire(pair.second),
];

ReminderRule _parseRule(
  Object? raw, {
  required bool? allDay,
  required AgentParameterField field,
}) {
  if (raw is! Map) _invalid(field);

  final values = <String, Object?>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    if (key is! String) _unknown(field);
    values[key] = entry.value;
  }

  if (!values.containsKey('kind')) _missing(field);
  final kind = values['kind'];
  if (kind is! String) _invalid(field);

  switch (kind) {
    case 'none':
      _requireRuleKeys(values, const {'kind'}, const {'kind'}, field);
      return const ReminderRule.none();
    case 'before':
      if (allDay == true) _invalid(field);
      _requireRuleKeys(
        values,
        const {'kind', 'minutes_before'},
        const {'kind', 'minutes_before'},
        field,
      );
      final minutes = values['minutes_before'];
      if (minutes is! int || minutes < 0 || minutes > 10080) {
        _invalid(field);
      }
      return ReminderRule.before(minutes);
    case 'dayTime':
      if (allDay == false) _invalid(field);
      _requireRuleKeys(
        values,
        const {'kind', 'day_offset', 'time'},
        const {'kind', 'day_offset', 'time'},
        field,
      );
      final dayOffset = values['day_offset'];
      if (dayOffset is! int || dayOffset < -7 || dayOffset > 7) {
        _invalid(field);
      }
      final time = values['time'];
      if (time is! String) _invalid(field);
      final match = RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').firstMatch(time);
      if (match == null) _invalid(field);
      final parts = time.split(':');
      final minuteOfDay = int.parse(parts[0]) * 60 + int.parse(parts[1]);
      return ReminderRule.dayTime(
        dayOffset: dayOffset,
        minuteOfDay: minuteOfDay,
      );
    default:
      _invalid(field);
  }
}

void _requireRuleKeys(
  Map<String, Object?> values,
  Set<String> allowed,
  Set<String> requiredKeys,
  AgentParameterField field,
) {
  if (requiredKeys.any((key) => !values.containsKey(key))) _missing(field);
  if (values.keys.any((key) => !allowed.contains(key))) _unknown(field);
}

Map<String, Object?> _ruleToWire(ReminderRule rule) => switch (rule.kind) {
  ReminderRuleKind.none => {'kind': 'none'},
  ReminderRuleKind.before => {
    'kind': 'before',
    'minutes_before': rule.minutesBefore,
  },
  ReminderRuleKind.dayTime => {
    'kind': 'dayTime',
    'day_offset': rule.dayOffset,
    'time': _formatTime(rule.minuteOfDay),
  },
};

String _formatTime(int minuteOfDay) {
  final hour = minuteOfDay ~/ 60;
  final minute = minuteOfDay % 60;
  return '${hour.toString().padLeft(2, '0')}:'
      '${minute.toString().padLeft(2, '0')}';
}

Map<String, Object?> _noneRuleSchema() => {
  'type': 'object',
  'properties': {
    'kind': {
      'type': 'string',
      'enum': const ['none'],
    },
  },
  'required': const ['kind'],
  'additionalProperties': false,
};

Map<String, Object?> _beforeRuleSchema() => {
  'type': 'object',
  'properties': {
    'kind': {
      'type': 'string',
      'enum': const ['before'],
    },
    'minutes_before': {'type': 'integer', 'minimum': 0, 'maximum': 10080},
  },
  'required': const ['kind', 'minutes_before'],
  'additionalProperties': false,
};

Map<String, Object?> _dayTimeRuleSchema() => {
  'type': 'object',
  'properties': {
    'kind': {
      'type': 'string',
      'enum': const ['dayTime'],
    },
    'day_offset': {'type': 'integer', 'minimum': -7, 'maximum': 7},
    'time': {'type': 'string', 'pattern': r'^(?:[01]\d|2[0-3]):[0-5]\d$'},
  },
  'required': const ['kind', 'day_offset', 'time'],
  'additionalProperties': false,
};

Never _invalid(AgentParameterField field) => throw AgentParameterIssue(
  reason: AgentParameterReason.invalidValue,
  field: field,
);

Never _missing(AgentParameterField field) => throw AgentParameterIssue(
  reason: AgentParameterReason.missingField,
  field: field,
);

Never _unknown(AgentParameterField field) => throw AgentParameterIssue(
  reason: AgentParameterReason.unknownField,
  field: field,
);
