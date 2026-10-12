import 'contracts.dart';

enum YoungJobKind { calendar, activities }

extension YoungJobContract on YoungJobKind {
  String get sourceKey => switch (this) {
    YoungJobKind.calendar => 'young_calendar',
    YoungJobKind.activities => 'young_activities',
  };
  String get contractVersion => switch (this) {
    YoungJobKind.calendar => 'young-linked-calendar-v1',
    YoungJobKind.activities => 'young-activities-v1',
  };
}

enum YoungPartitionPurpose { initial, recovery }

enum YoungIdentityFailure {
  identityUnverified,
  evidenceConflict,
  accountMismatch,
  identityMismatch,
}

final class YoungIdentityException implements Exception {
  const YoungIdentityException(this.code);
  final YoungIdentityFailure code;
  @override
  String toString() => 'YoungIdentityException(${code.name})';
}

final class YoungWorkStamp {
  const YoungWorkStamp({
    required this.jobId,
    required this.ownerId,
    required this.generation,
    required this.resetEpoch,
    required this.kind,
    this.accountId,
  });
  final String jobId;
  final String ownerId;
  final int generation;
  final int resetEpoch;
  final YoungJobKind kind;
  final int? accountId;
  @override
  String toString() => 'YoungWorkStamp';
}

/// Application lifecycle metadata. No school identity or browser asset values.
final class YoungPartitionRef {
  const YoungPartitionRef({
    required this.id,
    required this.ownerId,
    required this.purpose,
    required this.attempt,
    required this.resetEpoch,
  });
  final String id;
  final String ownerId;
  final YoungPartitionPurpose purpose;
  final String attempt;
  final int resetEpoch;
  Map<String, Object> get metadata => {
    'id': id,
    'ownerId': ownerId,
    'purpose': purpose.name,
    'attempt': attempt,
    'resetEpoch': resetEpoch,
  };
  factory YoungPartitionRef.decode(Map<String, dynamic> value) {
    if (value.length != 5 ||
        !value.keys.every(
          const {'id', 'ownerId', 'purpose', 'attempt', 'resetEpoch'}.contains,
        ) ||
        value['id'] is! String ||
        !RegExp(r'^yp-[0-9a-f]{32}$').hasMatch(value['id'] as String) ||
        value['ownerId'] is! String ||
        !RegExp(
          r'^jw-owner-[0-9a-f]{32}$',
        ).hasMatch(value['ownerId'] as String) ||
        value['attempt'] is! String ||
        !RegExp(
          r'^young-[0-9]+-[0-9]+$',
        ).hasMatch(value['attempt'] as String) ||
        value['resetEpoch'] is! int ||
        (value['resetEpoch'] as int) < 0 ||
        !YoungPartitionPurpose.values.any((p) => p.name == value['purpose'])) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    return YoungPartitionRef(
      id: value['id'] as String,
      ownerId: value['ownerId'] as String,
      purpose: YoungPartitionPurpose.values.singleWhere(
        (p) => p.name == value['purpose'],
      ),
      attempt: value['attempt'] as String,
      resetEpoch: value['resetEpoch'] as int,
    );
  }
  bool sameAs(YoungPartitionRef other) =>
      id == other.id &&
      ownerId == other.ownerId &&
      purpose == other.purpose &&
      attempt == other.attempt &&
      resetEpoch == other.resetEpoch;
  @override
  String toString() => 'YoungPartitionRef';
}

final class YoungClaimPermit {
  const YoungClaimPermit({required this.partition, required this.accountId});
  final YoungPartitionRef partition;
  final int accountId;
  @override
  String toString() => 'YoungClaimPermit';
}

final class YoungAuthority {
  const YoungAuthority({
    required this.ownerId,
    required this.generation,
    required this.resetEpoch,
    required this.accountBound,
  });
  final String ownerId;
  final int generation;
  final int resetEpoch;
  final bool accountBound;
}
