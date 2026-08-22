import 'dart:typed_data';

import 'credential_protector.dart';

/// Cross-platform fallback credential protector for non-Windows platforms.
///
/// NOT production-grade. This performs only lightweight XOR obfuscation (NOT
/// real encryption): the secret is XORed with a fixed, compile-time key and
/// the result is stored as-is. It defeats casual inspection of in-memory
/// buffers but provides no confidentiality against a determined attacker with
/// access to the device filesystem or a memory dump.
///
/// M6 replaces this with `flutter_secure_storage` (Android Keystore / iOS
/// Keychain) on the external machine that has the mobile SDKs installed.
class FallbackCredentialProtector implements CredentialProtector {
  static const scheme = 'fallback-xor';
  static const version = 1;

  // A fixed obfuscation key. This is NOT a secret — the goal is only to avoid
  // storing the plaintext verbatim in the protected blob. Real secrecy is M6's
  // job (secure storage backed by the OS keychain).
  static const _obfuscationKey = <int>[
    0x55, 0x53, 0x54, 0x43, 0x41, 0x73, 0x73, 0x69, // 'USTCAssi'
    0x73, 0x74, 0x61, 0x6e, 0x74, 0x2d, 0x4d, 0x35, // 'stant-M5'
  ];

  @override
  Future<ProtectedSecret> protect(Uint8List plaintext) async {
    return ProtectedSecret(
      bytes: _xor(plaintext),
      scheme: scheme,
      version: version,
      metadata: const {'scope': 'fallback_xor'},
    );
  }

  @override
  Future<Uint8List> unprotect(ProtectedSecret protected) async {
    if (protected.scheme != scheme || protected.version != version) {
      throw const CredentialProtectionException('unsupported_scheme');
    }
    return _xor(protected.bytes);
  }

  /// XOR is its own inverse: applying it twice recovers the original bytes.
  static Uint8List _xor(Uint8List input) {
    final output = Uint8List(input.length);
    for (var i = 0; i < input.length; i++) {
      output[i] = input[i] ^ _obfuscationKey[i % _obfuscationKey.length];
    }
    return output;
  }
}
