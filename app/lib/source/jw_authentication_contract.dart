import '../core/jw_credentials.dart';

enum JwLoginState {
  waiting,
  portalActivated,
  formReady,
  businessReady,
  manualRequired,
  pageStructureChanged,
  challengeRequired,
  contextUnavailable,
  submitted,
}

extension JwLoginStateStatus on JwLoginState {
  bool get needsUser => switch (this) {
    JwLoginState.manualRequired ||
    JwLoginState.pageStructureChanged ||
    JwLoginState.challengeRequired ||
    JwLoginState.contextUnavailable => true,
    _ => false,
  };
}

/// Closed pause metadata. No page text, selector, account or secret is exposed.
enum JwLoginPauseReason {
  manualRequired,
  pageStructureChanged,
  challengeRequired,
  contextUnavailable,
  noCredentials,
  alreadySubmitted,
  timedOut,
}

/// Native-only fixed authentication actions. No URL, script or page text.
abstract interface class JwAuthenticationBrowserPort {
  Future<JwLoginState> advanceJwLogin({
    required int session,
    required int document,
    required int operation,
  });
  Future<JwLoginState> submitJwLogin({
    required int session,
    required int document,
    required int operation,
    required JwSecretLease credentials,
  });
}

/// The same school CAS contract, admitted only by a current Young session.
abstract interface class YoungAuthenticationBrowserPort {
  Future<JwLoginState> advanceYoungLogin({
    required int session,
    required int document,
    required int operation,
  });
  Future<JwLoginState> submitYoungLogin({
    required int session,
    required int document,
    required int operation,
    required JwSecretLease credentials,
  });
}
