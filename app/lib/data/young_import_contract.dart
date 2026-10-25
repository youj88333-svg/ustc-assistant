import '../core/young_work_contract.dart';

enum YoungPresence { observed, outsideScope, missingWithinScope }

final class YoungStoredEvent {
  const YoungStoredEvent({
    required this.localId,
    required this.version,
    required this.title,
    required this.place,
    required this.startsAtUtc,
    required this.endsAtUtc,
    required this.presence,
    required this.hidden,
    this.sourceRetired = false,
  });
  final int localId;
  final int version;
  final String title;
  final String place;
  final DateTime startsAtUtc;
  final DateTime endsAtUtc;
  final YoungPresence presence;
  final bool hidden;
  final bool sourceRetired;
  @override
  String toString() => 'YoungStoredEvent';
}

/// Necessary information from one complete read-only activity query.
final class YoungActivityView {
  const YoungActivityView({
    required this.title,
    required this.place,
    required this.startsAtUtc,
    required this.endsAtUtc,
    required this.registrationStartsAtUtc,
    required this.registrationEndsAtUtc,
  });
  final String title;
  final String? place;
  final DateTime startsAtUtc;
  final DateTime endsAtUtc;
  final DateTime? registrationStartsAtUtc;
  final DateTime? registrationEndsAtUtc;
  @override
  String toString() => 'YoungActivityView';
}

final class YoungDataView {
  YoungDataView({
    required this.accountBound,
    required this.importCount,
    required this.queryCount,
    required this.auditCount,
    required List<YoungStoredEvent> events,
    this.credentialSaved = false,
    this.firstDay,
    this.lastDay,
  }) : events = List.unmodifiable(events);
  final bool accountBound;
  final int importCount;
  final int queryCount;
  final int auditCount;
  final bool credentialSaved;
  final List<YoungStoredEvent> events;

  /// Date-only UTC components represent Beijing calendar dates, not instants.
  final DateTime? firstDay;
  final DateTime? lastDay;
  @override
  String toString() => 'YoungDataView';
}

final class YoungCompletionReceipt {
  const YoungCompletionReceipt({
    required this.operationId,
    required this.kind,
    required this.itemCount,
    required this.replayed,
    required this.permit,
  });
  final String operationId;
  final YoungJobKind kind;
  final int itemCount;
  final bool replayed;
  final YoungClaimPermit permit;
  @override
  String toString() => 'YoungCompletionReceipt';
}

final class YoungHiddenCommand {
  const YoungHiddenCommand({
    required this.operationId,
    required this.ownerId,
    required this.accountId,
    required this.resetEpoch,
    required this.localId,
    required this.expectedVersion,
    required this.hidden,
  });
  final String operationId;
  final String ownerId;
  final int accountId;
  final int resetEpoch;
  final int localId;
  final int expectedVersion;
  final bool hidden;
  @override
  String toString() => 'YoungHiddenCommand';
}

final class YoungLocalWriteReceipt {
  const YoungLocalWriteReceipt({
    required this.operationId,
    required this.resultVersion,
    required this.hidden,
    required this.replayed,
  });
  final String operationId;
  final int resultVersion;
  final bool hidden;
  final bool replayed;
  @override
  String toString() => 'YoungLocalWriteReceipt';
}

abstract interface class YoungReadPort {
  Future<YoungDataView> readYoungView();
}
