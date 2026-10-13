import 'dart:typed_data';
import '../core/agent_contract.dart';
import '../core/jw_credentials.dart';
import 'windows_jw_credential_protector.dart';

/// A distinct typed model outlet. Only the Windows DPAPI primitive is shared;
/// C3 supplies a model-specific purpose, not a school authentication lease.
final class WindowsModelCredentialProtector
    implements ModelCredentialProtector {
  const WindowsModelCredentialProtector();
  static const _primitive = WindowsJwCredentialProtector();
  @override
  String get mechanism => _primitive.mechanism;
  void _purpose(String value) {
    if (!RegExp(r'^ustc-model-key/v1/jw-owner-[0-9a-f]{32}$').hasMatch(value)) {
      throw const AgentFailure(AgentFailureCode.protectionFailed);
    }
  }

  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async {
    _purpose(purpose);
    try {
      return await _primitive.protect(plaintext, purpose: purpose);
    } on JwCredentialException {
      throw const AgentFailure(AgentFailureCode.protectionFailed);
    }
  }

  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) async {
    _purpose(purpose);
    try {
      return await _primitive.unprotect(ciphertext, purpose: purpose);
    } on JwCredentialException {
      throw const AgentFailure(AgentFailureCode.protectionFailed);
    }
  }
}
