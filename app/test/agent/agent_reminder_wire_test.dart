import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/agent_reminder_wire.dart';
import 'package:ustc_assistant_m0/core/agent_parameter_issue.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';

void main() {
  test('schema fixes two slots and narrows rules for known target shape', () {
    final unknown = agentReminderPairSchema();
    expect(unknown['type'], 'array');
    expect(unknown['minItems'], 2);
    expect(unknown['maxItems'], 2);
    final unknownBranches = _branches(unknown);
    expect(_kinds(unknownBranches), {'none', 'before', 'dayTime'});
    expect(
      unknownBranches.every(
        (branch) => branch['additionalProperties'] == false,
      ),
      isTrue,
    );

    expect(_kinds(_branches(agentReminderPairSchema(allDay: false))), {
      'none',
      'before',
    });
    expect(_kinds(_branches(agentReminderPairSchema(allDay: true))), {
      'none',
      'dayTime',
    });

    final before = _branchFor(unknownBranches, 'before');
    final beforeProperties = before['properties'] as Map<String, Object?>;
    expect(beforeProperties['minutes_before'], {
      'type': 'integer',
      'minimum': 0,
      'maximum': 10080,
    });
    final dayTime = _branchFor(unknownBranches, 'dayTime');
    final dayTimeProperties = dayTime['properties'] as Map<String, Object?>;
    expect(dayTimeProperties['day_offset'], {
      'type': 'integer',
      'minimum': -7,
      'maximum': 7,
    });
    expect(
      (dayTimeProperties['time'] as Map<String, Object?>)['pattern'],
      r'^(?:[01]\d|2[0-3]):[0-5]\d$',
    );
  });

  test(
    'parses timed and all-day boundary rules and serializes wire fields',
    () {
      final timed = parseAgentReminderPair([
        {'kind': 'before', 'minutes_before': 0},
        {'kind': 'before', 'minutes_before': 10080},
      ], allDay: false);
      expect(timed.first.minutesBefore, 0);
      expect(timed.second.minutesBefore, 10080);
      expect(agentReminderPairToWire(timed), [
        {'kind': 'before', 'minutes_before': 0},
        {'kind': 'before', 'minutes_before': 10080},
      ]);

      final allDay = parseAgentReminderPair([
        {'kind': 'dayTime', 'day_offset': -7, 'time': '00:00'},
        {'kind': 'dayTime', 'day_offset': 7, 'time': '23:59'},
      ], allDay: true);
      expect(allDay.first.dayOffset, -7);
      expect(allDay.first.minuteOfDay, 0);
      expect(allDay.second.dayOffset, 7);
      expect(allDay.second.minuteOfDay, 1439);
      expect(agentReminderPairToWire(allDay), [
        {'kind': 'dayTime', 'day_offset': -7, 'time': '00:00'},
        {'kind': 'dayTime', 'day_offset': 7, 'time': '23:59'},
      ]);
    },
  );

  test(
    'unknown target shape accepts either rule form for later target validation',
    () {
      final pair = parseAgentReminderPair([
        {'kind': 'before', 'minutes_before': 15},
        {'kind': 'dayTime', 'day_offset': 0, 'time': '09:05'},
      ]);
      expect(pair.first.kind, ReminderRuleKind.before);
      expect(pair.second.kind, ReminderRuleKind.dayTime);
      expect(agentReminderPairToWire(pair), [
        {'kind': 'before', 'minutes_before': 15},
        {'kind': 'dayTime', 'day_offset': 0, 'time': '09:05'},
      ]);
    },
  );

  test(
    'rejects nulls, wrong lengths, invalid types, ranges, kinds, and keys',
    () {
      final invalidCases = <({Object? raw, bool? allDay})>[
        (raw: null, allDay: null),
        (raw: [], allDay: null),
        (
          raw: [
            {'kind': 'none'},
          ],
          allDay: null,
        ),
        (
          raw: [
            null,
            {'kind': 'none'},
          ],
          allDay: null,
        ),
        (
          raw: [
            7,
            {'kind': 'none'},
          ],
          allDay: null,
        ),
        (
          raw: [
            {'minutes_before': 1},
            {'kind': 'none'},
          ],
          allDay: null,
        ),
        (
          raw: [
            {'kind': null},
            {'kind': 'none'},
          ],
          allDay: null,
        ),
        (
          raw: [
            {'kind': 'before', 'minutes_before': 1.0},
            {'kind': 'none'},
          ],
          allDay: false,
        ),
        (
          raw: [
            {'kind': 'before', 'minutes_before': -1},
            {'kind': 'none'},
          ],
          allDay: false,
        ),
        (
          raw: [
            {'kind': 'before', 'minutes_before': 10081},
            {'kind': 'none'},
          ],
          allDay: false,
        ),
        (
          raw: [
            {'kind': 'dayTime', 'day_offset': -8, 'time': '09:00'},
            {'kind': 'none'},
          ],
          allDay: true,
        ),
        (
          raw: [
            {'kind': 'dayTime', 'day_offset': 8, 'time': '09:00'},
            {'kind': 'none'},
          ],
          allDay: true,
        ),
        (
          raw: [
            {'kind': 'dayTime', 'day_offset': 0.0, 'time': '09:00'},
            {'kind': 'none'},
          ],
          allDay: true,
        ),
        (
          raw: [
            {'kind': 'dayTime', 'day_offset': 0, 'time': '24:00'},
            {'kind': 'none'},
          ],
          allDay: true,
        ),
        (
          raw: [
            {'kind': 'dayTime', 'day_offset': 0, 'time': 900},
            {'kind': 'none'},
          ],
          allDay: true,
        ),
        (
          raw: [
            {'kind': 'dayTime', 'day_offset': 0, 'time': '09:60'},
            {'kind': 'none'},
          ],
          allDay: true,
        ),
        (
          raw: [
            {'kind': 'dayTime', 'day_offset': 0, 'time': '9:00'},
            {'kind': 'none'},
          ],
          allDay: true,
        ),
        (
          raw: [
            {'kind': 'before', 'minutes_before': 1, 'extra': true},
            {'kind': 'none'},
          ],
          allDay: false,
        ),
        (
          raw: [
            {'kind': 'none', 'minutes_before': 1},
            {'kind': 'none'},
          ],
          allDay: false,
        ),
        (
          raw: [
            {'kind': 'dayTime', 'day_offset': 0},
            {'kind': 'none'},
          ],
          allDay: true,
        ),
        (
          raw: [
            {'kind': 'unknown'},
            {'kind': 'none'},
          ],
          allDay: null,
        ),
        (
          raw: [
            {'kind': 'dayTime', 'day_offset': 0, 'time': '09:00'},
            {'kind': 'none'},
          ],
          allDay: false,
        ),
        (
          raw: [
            {'kind': 'before', 'minutes_before': 1},
            {'kind': 'none'},
          ],
          allDay: true,
        ),
      ];

      for (final invalid in invalidCases) {
        expect(
          () => parseAgentReminderPair(
            invalid.raw,
            allDay: invalid.allDay,
            field: AgentParameterField.timed,
          ),
          throwsA(
            isA<AgentParameterIssue>().having(
              (issue) => issue.field,
              'field',
              AgentParameterField.timed,
            ),
          ),
        );
      }

      expect(
        () => parseAgentReminderPair([
          {
            'kind': 'before',
            'minutes_before': 4,
            'unexpected': 'private-marker',
          },
          {'kind': 'none'},
        ]),
        throwsA(
          isA<AgentParameterIssue>()
              .having(
                (issue) => issue.reason,
                'reason',
                AgentParameterReason.unknownField,
              )
              .having(
                (issue) => issue.toString(),
                'safe error text',
                isNot(contains('private-marker')),
              ),
        ),
      );
    },
  );
}

List<Map<String, Object?>> _branches(Map<String, Object?> schema) =>
    ((schema['items'] as Map<String, Object?>)['oneOf']
            as List<Map<String, Object?>>)
        .toList();

Set<String> _kinds(List<Map<String, Object?>> branches) =>
    branches.map((branch) {
      final properties = branch['properties'] as Map<String, Object?>;
      final kind = properties['kind'] as Map<String, Object?>;
      return (kind['enum'] as List<String>).single;
    }).toSet();

Map<String, Object?> _branchFor(
  List<Map<String, Object?>> branches,
  String kind,
) => branches.singleWhere((branch) {
  final properties = branch['properties'] as Map<String, Object?>;
  final kindSchema = properties['kind'] as Map<String, Object?>;
  return (kindSchema['enum'] as List<String>).single == kind;
});
