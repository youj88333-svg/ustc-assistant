import '../core/contracts.dart';
import '../core/jw_credentials.dart';
import '../source/jw_authentication_contract.dart';

enum SchoolAuthenticationProgress { waiting, submitting }

/// A job-scoped CAS driver shared by JW and Young. It never owns a password.
/// A submission acknowledgement cannot cause another delivery of the secret.
final class SchoolAuthenticationDriver {
  bool _consumed = false;
  Stopwatch? _submissionWait;

  Future<JwLoginPauseReason?> authenticate({
    required void Function() requireCurrent,
    required Future<JwLoginState> Function() advance,
    required Future<JwLoginState> Function(JwSecretLease) submit,
    required Future<JwSecretLease?> Function() lease,
    required void Function(SchoolAuthenticationProgress) progress,
    required Duration timeout,
    required Duration pollInterval,
    bool Function()? manualBusinessFallback,
  }) async {
    final elapsed = Stopwatch()..start();
    progress(SchoolAuthenticationProgress.waiting);
    while (elapsed.elapsed < timeout) {
      requireCurrent();
      JwLoginState state;
      try {
        state = await advance();
      } on AppFailure catch (error) {
        if (error.code != FailureCode.busy &&
            error.code != FailureCode.staleResult) {
          rethrow;
        }
        await Future<void>.delayed(pollInterval);
        continue;
      }
      requireCurrent();
      if (state == JwLoginState.businessReady ||
          (state == JwLoginState.manualRequired &&
              manualBusinessFallback?.call() == true)) {
        return null;
      }
      if (state == JwLoginState.formReady) {
        if (_consumed) {
          if (_awaitingRedirect) {
            await Future<void>.delayed(pollInterval);
            continue;
          }
          return JwLoginPauseReason.alreadySubmitted;
        }
        final credentials = await lease();
        try {
          requireCurrent();
          if (credentials == null) return JwLoginPauseReason.noCredentials;
          _consumed = true;
          _submissionWait = Stopwatch()..start();
          progress(SchoolAuthenticationProgress.submitting);
          try {
            state = await submit(credentials);
          } on AppFailure catch (error) {
            if (error.code != FailureCode.staleResult) rethrow;
          }
          requireCurrent();
          if (state.needsUser) return _reason(state);
          progress(SchoolAuthenticationProgress.waiting);
        } finally {
          credentials?.revoke();
        }
      } else if (state.needsUser) {
        if (state == JwLoginState.manualRequired && _awaitingRedirect) {
          await Future<void>.delayed(pollInterval);
          continue;
        }
        return _reason(state);
      }
      await Future<void>.delayed(pollInterval);
    }
    return JwLoginPauseReason.timedOut;
  }

  bool get _awaitingRedirect =>
      _consumed &&
      _submissionWait != null &&
      _submissionWait!.elapsed < const Duration(seconds: 8);

  JwLoginPauseReason _reason(JwLoginState state) => switch (state) {
    JwLoginState.pageStructureChanged =>
      JwLoginPauseReason.pageStructureChanged,
    JwLoginState.challengeRequired => JwLoginPauseReason.challengeRequired,
    JwLoginState.contextUnavailable => JwLoginPauseReason.contextUnavailable,
    _ => JwLoginPauseReason.manualRequired,
  };
}
