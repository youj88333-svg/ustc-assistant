import '../core/jw_work_contract.dart';
import '../source/jw_probe_contract.dart';

enum JwEventKind { course, exam }

enum JwPresence { observed, outsideScope, missingWithinScope }

final class JwEventDraft {
  const JwEventDraft({
    required this.externalId,
    required this.kind,
    required this.title,
    required this.startsAtUtc,
    required this.endsAtUtc,
    this.semesterId,
  });
  final String externalId;
  final JwEventKind kind;
  final String title;
  final DateTime startsAtUtc;
  final DateTime endsAtUtc;
  final int? semesterId;
  List<Object?> get canonicalFields => [
    externalId,
    kind.name,
    semesterId,
    title,
    startsAtUtc.microsecondsSinceEpoch,
    endsAtUtc.microsecondsSinceEpoch,
  ];
  @override
  String toString() => 'JwEventDraft';
}

final class JwStoredEvent {
  const JwStoredEvent({
    required this.localId,
    required this.version,
    required this.kind,
    required this.title,
    required this.startsAtUtc,
    required this.endsAtUtc,
    required this.presence,
    required this.hidden,
    this.semesterId,
  });
  final int localId;
  final int version;
  final JwEventKind kind;
  final String title;
  final DateTime startsAtUtc;
  final DateTime endsAtUtc;
  final JwPresence presence;
  final bool hidden;

  /// Source-backed course membership; exams have no verified semester label.
  final int? semesterId;
  @override
  String toString() => 'JwStoredEvent';
}

final class JwImportReceipt {
  const JwImportReceipt({
    required this.operationId,
    required this.courseCount,
    required this.examCount,
    required this.replayed,
    required this.permit,
  });
  final String operationId;
  final int courseCount;
  final int examCount;
  final bool replayed;
  final JwClaimPermit permit;
  @override
  String toString() => 'JwImportReceipt';
}

/// A stable, account-bound command to change one local hidden overlay.
final class JwHiddenCommand {
  const JwHiddenCommand({
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
  String toString() => 'JwHiddenCommand';
}

/// The durable result for one local hidden command.
final class JwLocalWriteReceipt {
  const JwLocalWriteReceipt({
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
  String toString() => 'JwLocalWriteReceipt';
}

final class JwDataView {
  JwDataView({
    required this.accountBound,
    required this.courseCount,
    required this.examCount,
    required this.importCount,
    required this.auditCount,
    required List<JwStoredEvent> events,
    this.credentialSaved = false,
    this.lastSemesterId,
    List<JwSemesterOption> cachedSemesters = const [],
    this.semesterCatalogUpdatedAtUtc,
  }) : events = List.unmodifiable(events),
       cachedSemesters = List.unmodifiable(cachedSemesters);
  final bool accountBound;
  final int courseCount;
  final int examCount;
  final int importCount;
  final int auditCount;
  final List<JwStoredEvent> events;
  final bool credentialSaved;
  final int? lastSemesterId;
  final List<JwSemesterOption> cachedSemesters;
  final DateTime? semesterCatalogUpdatedAtUtc;
}

abstract interface class JwReadPort {
  Future<JwDataView> readView();
}
