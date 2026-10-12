import 'contracts.dart';

const jwSourceKey = 'jw';
const jwContractVersion = 'jw-course-exam-v1';

enum JwPartitionPurpose { initial, recovery }

enum JwIdentityFailure {
  identityUnverified,
  evidenceConflict,
  accountMismatch,
  identityMismatch,
}

final class JwIdentityException implements Exception {
  const JwIdentityException(this.code);
  final JwIdentityFailure code;
  @override
  String toString() => 'JwIdentityException(${code.name})';
}

final class JwWorkStamp {
  const JwWorkStamp({
    required this.jobId,
    required this.ownerId,
    required this.generation,
    required this.resetEpoch,
    this.accountId,
  });
  final String jobId;
  final String ownerId;
  final int generation;
  final int resetEpoch;
  final int? accountId;
  @override
  String toString() => 'JwWorkStamp';
}

/// Application lifecycle metadata only. It contains no school identity.
final class JwPartitionRef {
  const JwPartitionRef({
    required this.id,
    required this.ownerId,
    required this.purpose,
    required this.attempt,
    required this.resetEpoch,
  });
  final String id;
  final String ownerId;
  final JwPartitionPurpose purpose;
  final String attempt;
  final int resetEpoch;
  Map<String, Object> get metadata => {
    'id': id,
    'ownerId': ownerId,
    'purpose': purpose.name,
    'attempt': attempt,
    'resetEpoch': resetEpoch,
  };
  factory JwPartitionRef.decode(Map<String, dynamic> value) {
    if (value.keys.toSet().difference(const {
          'id',
          'ownerId',
          'purpose',
          'attempt',
          'resetEpoch',
        }).isNotEmpty ||
        value.length != 5 ||
        value['id'] is! String ||
        !RegExp(r'^jwp-[0-9a-f]{32}$').hasMatch(value['id'] as String) ||
        value['ownerId'] is! String ||
        !RegExp(
          r'^jw-owner-[0-9a-f]{32}$',
        ).hasMatch(value['ownerId'] as String) ||
        value['attempt'] is! String ||
        !RegExp(r'^jw-[0-9]+-[0-9]+$').hasMatch(value['attempt'] as String) ||
        value['resetEpoch'] is! int ||
        (value['resetEpoch'] as int) < 0 ||
        !JwPartitionPurpose.values.any((p) => p.name == value['purpose'])) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    return JwPartitionRef(
      id: value['id'] as String,
      ownerId: value['ownerId'] as String,
      purpose: JwPartitionPurpose.values.singleWhere(
        (p) => p.name == value['purpose'],
      ),
      attempt: value['attempt'] as String,
      resetEpoch: value['resetEpoch'] as int,
    );
  }
  bool sameAs(JwPartitionRef other) =>
      id == other.id &&
      ownerId == other.ownerId &&
      purpose == other.purpose &&
      attempt == other.attempt &&
      resetEpoch == other.resetEpoch;
  @override
  String toString() => 'JwPartitionRef';
}

/// Only C3 returns permits after reading its committed transaction facts.
final class JwClaimPermit {
  const JwClaimPermit({required this.partition, required this.accountId});
  final JwPartitionRef partition;
  final int accountId;
  @override
  String toString() => 'JwClaimPermit';
}

final class JwAuthority {
  const JwAuthority({
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
