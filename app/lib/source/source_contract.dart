import '../core/contracts.dart';

const syntheticSourceKey = 'synthetic-demo';
const syntheticContractVersion = 'm0-synthetic-v1';

enum DemoScenario {
  normal,
  replay,
  empty,
  incomplete,
  sourceFailure,
  storageFailure,
  followUpFailure,
  cleanupFailure,
}

final class CollectedEvent {
  const CollectedEvent({
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

/// Immutable output sealed by C1; closing its session cannot revoke it.
final class CollectionArtifact {
  CollectionArtifact({
    required this.stamp,
    required this.rangeStartUtc,
    required this.rangeEndUtc,
    required this.collectedAtUtc,
    required List<CollectedEvent> events,
  }) : events = List.unmodifiable(events);

  final JobStamp stamp;
  final DateTime rangeStartUtc;
  final DateTime rangeEndUtc;
  final DateTime collectedAtUtc;
  final List<CollectedEvent> events;

  String get contentFingerprint {
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

abstract interface class SourceSession {
  Future<CollectionArtifact> collect();
  Future<void> close();
}

abstract interface class SourcePort {
  Future<SourceSession> open(JobStamp stamp, DemoScenario scenario);
}
