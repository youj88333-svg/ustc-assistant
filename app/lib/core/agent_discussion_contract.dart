import 'calendar_contract.dart';

/// A business projection selection, checked again by C3 on send. It does not
/// confer approval and is never serialized as an underlying database ID.
final class AgentDiscussionSelection {
  const AgentDiscussionSelection.event(CalendarReference reference)
    : event = reference,
      task = null;
  const AgentDiscussionSelection.task(TaskReference reference)
    : task = reference,
      event = null;
  final CalendarReference? event;
  final TaskReference? task;
  @override
  String toString() => 'AgentDiscussionSelection';
}
