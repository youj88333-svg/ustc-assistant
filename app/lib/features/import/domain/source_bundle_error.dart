class SourceBundleError implements Exception {
  const SourceBundleError(this.code, this.safeMessage);

  final String code;
  final String safeMessage;

  @override
  String toString() => 'SourceBundleError($code): $safeMessage';
}

const sourceBundleSafeMessages = <String, String>{
  'unsupported_version': 'The SourceBundle version is not supported.',
  'invalid_envelope': 'The SourceBundle envelope is invalid.',
  'incomplete_snapshot': 'The SourceBundle snapshot is incomplete.',
  'subject_mismatch': 'The SourceBundle belongs to a different account.',
  'count_mismatch': 'The SourceBundle counts are inconsistent.',
  'duplicate_identity': 'The SourceBundle contains a duplicate identity.',
  'dangling_reference': 'The SourceBundle contains an invalid reference.',
  'invalid_time': 'The SourceBundle contains an invalid time range.',
  'limit_exceeded': 'The SourceBundle exceeds a contract limit.',
};

Never throwSourceBundleError(String code) {
  throw SourceBundleError(code, sourceBundleSafeMessages[code]!);
}
