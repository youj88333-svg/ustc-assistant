import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'credential_protector.dart';

class WindowsDpapiProtector implements CredentialProtector {
  static const scheme = 'windows-dpapi-current-user';
  static const version = 1;
  static const _cryptProtectUiForbidden = 0x1;

  @override
  Future<ProtectedSecret> protect(Uint8List plaintext) async {
    final input = calloc<CRYPT_INTEGER_BLOB>();
    final output = calloc<CRYPT_INTEGER_BLOB>();
    final inputBytes = calloc<Uint8>(plaintext.isEmpty ? 1 : plaintext.length);
    try {
      inputBytes.asTypedList(plaintext.length).setAll(0, plaintext);
      input.ref
        ..cbData = plaintext.length
        ..pbData = inputBytes;
      final result = CryptProtectData(
        input,
        null,
        null,
        null,
        _cryptProtectUiForbidden,
        output,
      );
      if (!result.value) {
        throw const CredentialProtectionException('protect_failed');
      }
      return ProtectedSecret(
        bytes: Uint8List.fromList(
          output.ref.pbData.asTypedList(output.ref.cbData),
        ),
        scheme: scheme,
        version: version,
        metadata: const {'scope': 'current_user'},
      );
    } finally {
      inputBytes
          .asTypedList(plaintext.length)
          .fillRange(0, plaintext.length, 0);
      calloc.free(inputBytes);
      _freeOutput(output);
      calloc.free(input);
      calloc.free(output);
    }
  }

  @override
  Future<Uint8List> unprotect(ProtectedSecret protected) async {
    if (protected.scheme != scheme || protected.version != version) {
      throw const CredentialProtectionException('unsupported_scheme');
    }
    final input = calloc<CRYPT_INTEGER_BLOB>();
    final output = calloc<CRYPT_INTEGER_BLOB>();
    final inputBytes = calloc<Uint8>(
      protected.bytes.isEmpty ? 1 : protected.bytes.length,
    );
    try {
      inputBytes.asTypedList(protected.bytes.length).setAll(0, protected.bytes);
      input.ref
        ..cbData = protected.bytes.length
        ..pbData = inputBytes;
      final result = CryptUnprotectData(
        input,
        null,
        null,
        null,
        _cryptProtectUiForbidden,
        output,
      );
      if (!result.value) {
        throw const CredentialProtectionException('unprotect_failed');
      }
      return Uint8List.fromList(
        output.ref.pbData.asTypedList(output.ref.cbData),
      );
    } finally {
      inputBytes
          .asTypedList(protected.bytes.length)
          .fillRange(0, protected.bytes.length, 0);
      calloc.free(inputBytes);
      _freeOutput(output);
      calloc.free(input);
      calloc.free(output);
    }
  }

  void _freeOutput(Pointer<CRYPT_INTEGER_BLOB> output) {
    final data = output.ref.pbData;
    final length = output.ref.cbData;
    if (data == nullptr) return;
    data.asTypedList(length).fillRange(0, length, 0);
    HLOCAL(data).close();
    output.ref
      ..pbData = nullptr
      ..cbData = 0;
  }
}
