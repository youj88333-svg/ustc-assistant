import 'dart:typed_data';

enum JwCredentialFailure { unavailable, protectionFailed, invalidCredential }

final class JwCredentialException implements Exception {
  const JwCredentialException(this.code);
  final JwCredentialFailure code;
  @override
  String toString() => 'JwCredentialException(${code.name})';
}

/// P protects bytes; C3 is the only durable ciphertext owner. No fallback vault.
abstract interface class JwCredentialProtector {
  String get mechanism;
  Future<Uint8List> protect(Uint8List plaintext, {required String purpose});
  Future<Uint8List> unprotect(Uint8List ciphertext, {required String purpose});
}

/// A private, non-serializable lease. The consumer owns and wipes taken bytes.
final class JwSecretLease {
  JwSecretLease(Uint8List bytes) : _bytes = bytes;
  Uint8List? _bytes;
  Uint8List take() {
    final bytes = _bytes;
    if (bytes == null) {
      throw const JwCredentialException(JwCredentialFailure.invalidCredential);
    }
    _bytes = null;
    return bytes;
  }

  void revoke() {
    _bytes?.fillRange(0, _bytes!.length, 0);
    _bytes = null;
  }

  @override
  String toString() => 'JwSecretLease';
}
