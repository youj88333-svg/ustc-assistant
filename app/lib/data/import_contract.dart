import '../core/contracts.dart';

// C3 owns its import contract. C2 maps C1's sealed events into these values.
final class EventDraft {
  const EventDraft({
    required this.externalId,
    required this.title,
    required this.startsAtUtc,
    required this.endsAtUtc,
  });

  final String externalId;
  final String title;
  final DateTime startsAtUtc;
  final DateTime endsAtUtc;

  List<Object> get canonicalFields => [
    externalId,
    title,
    startsAtUtc.microsecondsSinceEpoch,
    endsAtUtc.microsecondsSinceEpoch,
  ];
}

final class ImportRequest {
  ImportRequest({
    required this.stamp,
    required this.operationId,
    required this.rangeStartUtc,
    required this.rangeEndUtc,
    required this.collectedAtUtc,
    required this.contentFingerprint,
    required List<EventDraft> events,
    this.complete = true,
  }) : events = List.unmodifiable(events);

  final JobStamp stamp;
  final String operationId;
  final DateTime rangeStartUtc;
  final DateTime rangeEndUtc;
  final DateTime collectedAtUtc;
  final String contentFingerprint;
  final List<EventDraft> events;
  final bool complete;

  String get calculatedFingerprint {
    final ordered = [...events]
      ..sort((a, b) => a.externalId.compareTo(b.externalId));
    return fingerprint([
      stamp.sourceKey,
      stamp.contractVersion,
      rangeStartUtc.microsecondsSinceEpoch,
      rangeEndUtc.microsecondsSinceEpoch,
      ordered.map((event) => event.canonicalFields).toList(),
    ]);
  }
}

enum CancellationDisposition { cancelled, alreadyCommitted, notActive }

final class ImportReceipt {
  const ImportReceipt({
    required this.operationId,
    required this.recordCount,
    required this.replayed,
    required this.followUpPending,
  });

  final String operationId;
  final int recordCount;
  final bool replayed;
  final bool followUpPending;
}

final class StoredEvent {
  const StoredEvent({
    required this.localId,
    required this.externalId,
    required this.title,
    required this.startsAtUtc,
    required this.endsAtUtc,
    required this.sourceMissing,
  });

  final int localId;
  final String externalId;
  final String title;
  final DateTime startsAtUtc;
  final DateTime endsAtUtc;
  final bool sourceMissing;
}

final class DemoDataView {
  DemoDataView({
    required List<StoredEvent> events,
    required this.importCount,
    required this.auditCount,
    required this.pendingFollowUps,
  }) : events = List.unmodifiable(events);

  final List<StoredEvent> events;
  final int importCount;
  final int auditCount;
  final int pendingFollowUps;
}

abstract interface class DemoReadPort {
  Future<DemoDataView> readView();
}
