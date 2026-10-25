import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../core/jw_credentials.dart';

/// Protects credential bytes with Windows DPAPI for the current user.
///
/// The purpose string is passed as DPAPI optional entropy, so callers must use
/// the same purpose to unprotect the returned bytes.
final class WindowsJwCredentialProtector implements JwCredentialProtector {
  const WindowsJwCredentialProtector();

  static const _maxPlaintextBytes = 16 * 1024;
  static const _maxCiphertextBytes = 64 * 1024;
  static const _maxPurposeCharacters = 256;
  static const _cryptProtectUiForbidden = 0x1;

  @override
  String get mechanism => 'dpapi-current-user-v1';

  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async {
    if (!Platform.isWindows) _throwUnavailable();
    if (plaintext.isEmpty || plaintext.length > _maxPlaintextBytes) {
      _throwProtectionFailed();
    }
    final entropyBytes = _encodePurpose(purpose, invalidIsCredential: false);

    try {
      final api = _WindowsDpapiBindings.instance;
      return _protect(api, plaintext, entropyBytes);
    } on JwCredentialException {
      rethrow;
    } catch (_) {
      _throwProtectionFailed();
    } finally {
      entropyBytes.fillRange(0, entropyBytes.length, 0);
    }
  }

  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) async {
    if (!Platform.isWindows) _throwUnavailable();
    if (ciphertext.isEmpty || ciphertext.length > _maxCiphertextBytes) {
      _throwInvalidCredential();
    }
    final entropyBytes = _encodePurpose(purpose, invalidIsCredential: true);

    try {
      final api = _WindowsDpapiBindings.instance;
      return _unprotect(api, ciphertext, entropyBytes);
    } on JwCredentialException {
      rethrow;
    } catch (_) {
      _throwInvalidCredential();
    } finally {
      entropyBytes.fillRange(0, entropyBytes.length, 0);
    }
  }

  Uint8List _protect(
    _WindowsDpapiBindings api,
    Uint8List plaintext,
    Uint8List entropyBytes,
  ) {
    _NativeSensitiveBytes? input;
    _NativeSensitiveBytes? entropy;
    Pointer<_DataBlob>? inputBlob;
    Pointer<_DataBlob>? entropyBlob;
    Pointer<_DataBlob>? outputBlob;
    try {
      final inputValue = _NativeSensitiveBytes(plaintext);
      input = inputValue;
      final entropyValue = _NativeSensitiveBytes(entropyBytes);
      entropy = entropyValue;
      final inputBlobValue = calloc<_DataBlob>();
      inputBlob = inputBlobValue;
      final entropyBlobValue = calloc<_DataBlob>();
      entropyBlob = entropyBlobValue;
      final outputBlobValue = calloc<_DataBlob>();
      outputBlob = outputBlobValue;
      inputBlobValue.ref
        ..cbData = plaintext.length
        ..pbData = inputValue.pointer;
      entropyBlobValue.ref
        ..cbData = entropyBytes.length
        ..pbData = entropyValue.pointer;

      if (api.cryptProtectData(
            inputBlobValue,
            nullptr,
            entropyBlobValue,
            nullptr,
            nullptr,
            _cryptProtectUiForbidden,
            outputBlobValue,
          ) ==
          0) {
        _throwProtectionFailed();
      }

      final outputLength = outputBlobValue.ref.cbData;
      final outputPointer = outputBlobValue.ref.pbData;
      if (outputPointer.address == 0 ||
          outputLength == 0 ||
          outputLength > _maxCiphertextBytes) {
        _throwProtectionFailed();
      }
      return Uint8List.fromList(outputPointer.asTypedList(outputLength));
    } finally {
      if (outputBlob != null) {
        api.releaseDpapiOutput(outputBlob.ref.pbData, outputBlob.ref.cbData);
        _clearAndFreeBlob(outputBlob);
      }
      if (entropyBlob != null) _clearAndFreeBlob(entropyBlob);
      if (inputBlob != null) _clearAndFreeBlob(inputBlob);
      entropy?.dispose();
      input?.dispose();
    }
  }

  Uint8List _unprotect(
    _WindowsDpapiBindings api,
    Uint8List ciphertext,
    Uint8List entropyBytes,
  ) {
    _NativeSensitiveBytes? input;
    _NativeSensitiveBytes? entropy;
    Pointer<_DataBlob>? inputBlob;
    Pointer<_DataBlob>? entropyBlob;
    Pointer<_DataBlob>? outputBlob;
    try {
      final inputValue = _NativeSensitiveBytes(ciphertext);
      input = inputValue;
      final entropyValue = _NativeSensitiveBytes(entropyBytes);
      entropy = entropyValue;
      final inputBlobValue = calloc<_DataBlob>();
      inputBlob = inputBlobValue;
      final entropyBlobValue = calloc<_DataBlob>();
      entropyBlob = entropyBlobValue;
      final outputBlobValue = calloc<_DataBlob>();
      outputBlob = outputBlobValue;
      inputBlobValue.ref
        ..cbData = ciphertext.length
        ..pbData = inputValue.pointer;
      entropyBlobValue.ref
        ..cbData = entropyBytes.length
        ..pbData = entropyValue.pointer;

      if (api.cryptUnprotectData(
            inputBlobValue,
            nullptr.cast<Pointer<Utf16>>(),
            entropyBlobValue,
            nullptr,
            nullptr,
            _cryptProtectUiForbidden,
            outputBlobValue,
          ) ==
          0) {
        _throwInvalidCredential();
      }

      final outputLength = outputBlobValue.ref.cbData;
      final outputPointer = outputBlobValue.ref.pbData;
      if (outputPointer.address == 0 ||
          outputLength == 0 ||
          outputLength > _maxPlaintextBytes) {
        _throwInvalidCredential();
      }
      return Uint8List.fromList(outputPointer.asTypedList(outputLength));
    } finally {
      if (outputBlob != null) {
        api.releaseDpapiOutput(outputBlob.ref.pbData, outputBlob.ref.cbData);
        _clearAndFreeBlob(outputBlob);
      }
      if (entropyBlob != null) _clearAndFreeBlob(entropyBlob);
      if (inputBlob != null) _clearAndFreeBlob(inputBlob);
      entropy?.dispose();
      input?.dispose();
    }
  }

  Uint8List _encodePurpose(
    String purpose, {
    required bool invalidIsCredential,
  }) {
    Never reject() {
      if (invalidIsCredential) {
        _throwInvalidCredential();
      } else {
        _throwProtectionFailed();
      }
    }

    // A valid UTF-16 string with at most 256 Unicode scalar values uses at
    // most 512 code units. This fast bound avoids scanning an oversized value.
    if (purpose.isEmpty || purpose.length > _maxPurposeCharacters * 2) {
      reject();
    }
    late final int characterCount;
    try {
      characterCount = purpose.runes.length;
    } catch (_) {
      reject();
    }
    if (characterCount > _maxPurposeCharacters) reject();

    try {
      final encoded = utf8.encode(purpose);
      try {
        return Uint8List.fromList(encoded);
      } finally {
        for (var index = 0; index < encoded.length; index++) {
          encoded[index] = 0;
        }
      }
    } catch (_) {
      reject();
    }
  }

  Never _throwUnavailable() =>
      throw const JwCredentialException(JwCredentialFailure.unavailable);

  Never _throwProtectionFailed() =>
      throw const JwCredentialException(JwCredentialFailure.protectionFailed);

  Never _throwInvalidCredential() =>
      throw const JwCredentialException(JwCredentialFailure.invalidCredential);
}

void _clearAndFreeBlob(Pointer<_DataBlob> blob) {
  blob.ref
    ..cbData = 0
    ..pbData = nullptr;
  calloc.free(blob);
}

final class _NativeSensitiveBytes {
  _NativeSensitiveBytes(Uint8List bytes)
    : length = bytes.length,
      pointer = calloc<Uint8>(bytes.length) {
    try {
      pointer.asTypedList(length).setAll(0, bytes);
    } catch (_) {
      dispose();
      rethrow;
    }
  }

  final int length;
  final Pointer<Uint8> pointer;
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      pointer.asTypedList(length).fillRange(0, length, 0);
    } catch (_) {
      // Clearing is best effort; freeing still happens even if the view fails.
    } finally {
      calloc.free(pointer);
    }
  }
}

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}

typedef _CryptProtectNative =
    Int32 Function(
      Pointer<_DataBlob>,
      Pointer<Utf16>,
      Pointer<_DataBlob>,
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
      Pointer<_DataBlob>,
    );
typedef _CryptProtectDart =
    int Function(
      Pointer<_DataBlob>,
      Pointer<Utf16>,
      Pointer<_DataBlob>,
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<_DataBlob>,
    );

typedef _CryptUnprotectNative =
    Int32 Function(
      Pointer<_DataBlob>,
      Pointer<Pointer<Utf16>>,
      Pointer<_DataBlob>,
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
      Pointer<_DataBlob>,
    );
typedef _CryptUnprotectDart =
    int Function(
      Pointer<_DataBlob>,
      Pointer<Pointer<Utf16>>,
      Pointer<_DataBlob>,
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<_DataBlob>,
    );

typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void>);

final class _WindowsDpapiBindings {
  _WindowsDpapiBindings._()
    : _crypt32 = DynamicLibrary.open('crypt32.dll'),
      _kernel32 = DynamicLibrary.open('kernel32.dll') {
    _cryptProtectData = _crypt32
        .lookupFunction<_CryptProtectNative, _CryptProtectDart>(
          'CryptProtectData',
        );
    _cryptUnprotectData = _crypt32
        .lookupFunction<_CryptUnprotectNative, _CryptUnprotectDart>(
          'CryptUnprotectData',
        );
    _localFree = _kernel32.lookupFunction<_LocalFreeNative, _LocalFreeDart>(
      'LocalFree',
    );
  }

  static _WindowsDpapiBindings? _cached;
  static _WindowsDpapiBindings get instance {
    try {
      return _cached ??= _WindowsDpapiBindings._();
    } catch (_) {
      throw const JwCredentialException(JwCredentialFailure.unavailable);
    }
  }

  final DynamicLibrary _crypt32;
  final DynamicLibrary _kernel32;

  late final int Function(
    Pointer<_DataBlob>,
    Pointer<Utf16>,
    Pointer<_DataBlob>,
    Pointer<Void>,
    Pointer<Void>,
    int,
    Pointer<_DataBlob>,
  )
  _cryptProtectData;
  late final int Function(
    Pointer<_DataBlob>,
    Pointer<Pointer<Utf16>>,
    Pointer<_DataBlob>,
    Pointer<Void>,
    Pointer<Void>,
    int,
    Pointer<_DataBlob>,
  )
  _cryptUnprotectData;
  late final Pointer<Void> Function(Pointer<Void>) _localFree;

  int cryptProtectData(
    Pointer<_DataBlob> input,
    Pointer<Utf16> description,
    Pointer<_DataBlob> entropy,
    Pointer<Void> reserved,
    Pointer<Void> prompt,
    int flags,
    Pointer<_DataBlob> output,
  ) => _cryptProtectData(
    input,
    description,
    entropy,
    reserved,
    prompt,
    flags,
    output,
  );

  int cryptUnprotectData(
    Pointer<_DataBlob> input,
    Pointer<Pointer<Utf16>> description,
    Pointer<_DataBlob> entropy,
    Pointer<Void> reserved,
    Pointer<Void> prompt,
    int flags,
    Pointer<_DataBlob> output,
  ) => _cryptUnprotectData(
    input,
    description,
    entropy,
    reserved,
    prompt,
    flags,
    output,
  );

  void releaseDpapiOutput(Pointer<Uint8> pointer, int length) {
    if (pointer.address == 0) return;
    try {
      if (length > 0) pointer.asTypedList(length).fillRange(0, length, 0);
    } catch (_) {
      // The DPAPI buffer must still be released if clearing fails.
    } finally {
      try {
        _localFree(pointer.cast<Void>());
      } catch (_) {
        // LocalFree is best effort during failure cleanup.
      }
    }
  }
}
