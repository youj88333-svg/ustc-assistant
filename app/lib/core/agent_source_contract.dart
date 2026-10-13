import 'agent_contract.dart';

enum AgentRefreshSource { jw, youngCalendar }

final class AgentSemesterOption {
  const AgentSemesterOption(
    this.reference,
    this.label, {
    this.lastUsed = false,
  });
  final String reference;
  final String label;
  final bool lastUsed;
}

final class AgentSourceOptions {
  AgentSourceOptions({
    required this.accountBound,
    required this.credentialSaved,
    required List<AgentSemesterOption> semesters,
  }) : semesters = List.unmodifiable(semesters);
  final bool accountBound;
  final bool credentialSaved;
  final List<AgentSemesterOption> semesters;
}

final class AgentSourceRequest {
  const AgentSourceRequest(
    this.source, {
    this.semesterReference,
    this.firstDay,
    this.endDayExclusive,
  });
  final AgentRefreshSource source;
  final String? semesterReference;

  /// Beijing date components, UTC representation; never model-selected URLs.
  final DateTime? firstDay;
  final DateTime? endDayExclusive;
}

final class AgentActivityResult {
  const AgentActivityResult({
    required this.title,
    required this.place,
    required this.startsAtUtc,
    required this.endsAtUtc,
    this.registrationStartsAtUtc,
    this.registrationEndsAtUtc,
  });
  final String title, place;
  final DateTime startsAtUtc, endsAtUtc;
  final DateTime? registrationStartsAtUtc, registrationEndsAtUtc;
}

final class AgentSourceResult {
  AgentSourceResult({
    required this.committed,
    required this.count,
    required this.observedAtUtc,
    required this.complete,
    this.failure,
    List<AgentActivityResult> activities = const [],
  }) : activities = List.unmodifiable(activities);
  final bool committed, complete;
  final int count;
  final DateTime observedAtUtc;
  final String? failure;
  final List<AgentActivityResult> activities;
}

/// Fixed C2 work, with ownership independent from manual settings jobs.
abstract interface class AgentSourcePort {
  bool get waitingForSchool;
  Stream<void> get changes;
  Future<AgentSourceOptions> readOptions(AgentRunTicket ticket);
  Future<AgentSourceResult> refresh(
    AgentRunTicket ticket,
    AgentActionView approvedRecord,
    AgentSourceRequest request,
  );
  Future<AgentSourceResult> queryActivities(AgentRunTicket ticket);
  Future<void> continueSchool();
  Future<void> cancelAndDrain();
  Future<void> close();
}

/// Validate source read facts again at each model handoff. Mutation receipts
/// remain historical facts after their old read context has been discarded.
abstract interface class AgentSourceDeliveryPort {
  Future<void> validateDelivery();
  void clearReadReferences();
}
