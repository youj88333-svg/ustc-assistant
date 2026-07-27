import 'dart:typed_data';

class ProtectedSecret {
  const ProtectedSecret({
    required this.bytes,
    required this.scheme,
    required this.version,
    this.metadata = const {},
  });

  final Uint8List bytes;
  final String scheme;
  final int version;
  final Map<String, Object?> metadata;
}

class CredentialProtectionException implements Exception {
  const CredentialProtectionException(this.code);

  final String code;

  @override
  String toString() => 'CredentialProtectionException: $code';
}

abstract interface class CredentialProtector {
  Future<ProtectedSecret> protect(Uint8List plaintext);

  Future<Uint8List> unprotect(ProtectedSecret protected);
}
