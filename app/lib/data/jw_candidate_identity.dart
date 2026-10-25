import '../core/contracts.dart';
import '../source/jw_data_probe_contract.dart';
import '../source/jw_probe_contract.dart';

enum JwCandidateIdentity {
  unavailable,
  candidateMatches,
  candidateMismatch,
  candidateConflict,
}

/// Verification-only comparison for the unique candidate projected from
/// identity HTML. This does not establish a formal account identity.
final class JwCandidateIdentityVerifier {
  JwCandidateIdentityVerifier(String expectedAccountCode)
    : _expectedAccountCode = _validate(expectedAccountCode);

  final String _expectedAccountCode;

  JwCandidateIdentity evaluate(JwProbeReply reply) {
    return _compare(reply.identityCandidateCount, reply.accountCode);
  }

  JwCandidateIdentity evaluateData(JwDataProbeReply reply) =>
      _compare(reply.identityCandidateCount, reply.accountCode);

  JwCandidateIdentity _compare(int candidateCount, String? accountCode) {
    if (candidateCount > 1) {
      return JwCandidateIdentity.candidateConflict;
    }
    if (candidateCount != 1 || accountCode == null) {
      return JwCandidateIdentity.unavailable;
    }
    return accountCode == _expectedAccountCode
        ? JwCandidateIdentity.candidateMatches
        : JwCandidateIdentity.candidateMismatch;
  }

  static String _validate(String value) {
    if (!RegExp(r'^[A-Z0-9]{5,24}$').hasMatch(value)) {
      throw const AppFailure(FailureCode.invalidSnapshot);
    }
    return value;
  }

  @override
  String toString() => 'JwCandidateIdentityVerifier';
}
