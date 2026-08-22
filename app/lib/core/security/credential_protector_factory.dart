import 'dart:io';

import 'credential_protector.dart';
import 'fallback_credential_protector.dart';
import 'windows_dpapi_protector.dart';

/// Returns the default [CredentialProtector] for the current platform.
///
/// This is the single sanctioned platform-dispatch point for credential
/// protection. Windows uses DPAPI ([WindowsDpapiProtector]); all other
/// platforms use the [FallbackCredentialProtector] (non-production-grade
/// obfuscation, replaced by `flutter_secure_storage` in M6).
///
/// Callers elsewhere in `lib/` must obtain a [CredentialProtector] through
/// this factory rather than directly constructing a platform-specific
/// implementation, so that platform-specific imports stay isolated to
/// `core/security/`.
CredentialProtector defaultCredentialProtector() {
  return Platform.isWindows
      ? WindowsDpapiProtector()
      : FallbackCredentialProtector();
}
