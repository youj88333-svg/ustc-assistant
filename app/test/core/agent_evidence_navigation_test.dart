import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/agent_evidence.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';

void main() {
  const context = CalendarContext(
    owner: 'synthetic-owner',
    resetEpoch: 1,
    agendaEpoch: 3,
  );
  AgentEvidence evidence({
    CalendarReference? event,
    TaskReference? task,
    String provider = 'local',
  }) => AgentEvidence(
    id: 'e_0123456789abcdef',
    provider: provider,
    title: '合成出处',
    observedAtUtc: DateTime.utc(2026, 10, 13),
    scope: '合成范围',
    complete: true,
    eventReference: event,
    taskReference: task,
  );
  test(
    'local history round-trips navigation independently from model references',
    () {
      const event = CalendarReference(
        context,
        CalendarIdentity(CalendarKind.personal, 3, ordinal: 1),
        7,
      );
      final restored = agentEvidenceFromMap(
        agentEvidenceToMap(evidence(event: event)),
      );
      expect(restored.eventReference, event);
      expect(restored.taskReference, isNull);
      final task = agentEvidenceFromMap(
        agentEvidenceToMap(evidence(task: const TaskReference(context, 4, 9))),
      );
      expect(
        task.taskReference!.canonical,
        const TaskReference(context, 4, 9).canonical,
      );
      expect(task.eventReference, isNull);
    },
  );
  test(
    'old history has no navigation; public and ambiguous references are rejected',
    () {
      expect(
        agentEvidenceToMap(evidence()).containsKey('localNavigation'),
        isFalse,
      );
      expect(
        agentEvidenceFromMap(agentEvidenceToMap(evidence())).eventReference,
        isNull,
      );
      const event = CalendarReference(
        context,
        CalendarIdentity(CalendarKind.personal, 1),
        1,
      );
      expect(
        () => agentEvidenceToMap(evidence(provider: 'teach', event: event)),
        throwsA(isA<AgentFailure>()),
      );
      expect(
        () => agentEvidenceToMap(
          evidence(event: event, task: const TaskReference(context, 1, 1)),
        ),
        throwsA(isA<AgentFailure>()),
      );
      final corrupt = agentEvidenceToMap(evidence())
        ..['localNavigation'] = [
          'event',
          'synthetic-owner',
          0,
          0,
          'personal',
          -1,
          0,
          1,
        ];
      expect(() => agentEvidenceFromMap(corrupt), throwsA(isA<AgentFailure>()));
    },
  );
}
