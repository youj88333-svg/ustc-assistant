import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../core/contracts.dart';

/// Pins an explicitly selected application root throughout its asset lifetime.
final class DemoDirectory implements AssetOwnership {
  DemoDirectory._(this.path, this._pins);

  final String path;
  final List<_DirectoryPin> _pins;
  bool _released = false;
  bool _lost = false;

  static Future<DemoDirectory> acquire([String? requestedPath]) async {
    if (!Platform.isWindows) {
      throw const AppFailure(FailureCode.unsupportedPlatform);
    }
    final target = _safeLocalPath(
      requestedPath ??
          p.join(Directory.systemTemp.path, 'ustc_assistant_m0_demo_v1'),
    );
    final parts = p.windows.split(target);
    final pins = <_DirectoryPin>[];
    var current = parts.first;
    try {
      for (var index = 0; index < parts.length; index++) {
        if (index > 0) current = p.windows.join(current, parts[index]);
        final attributes = _win.attributes(current);
        if (attributes == null) {
          // The parent is already pinned without DELETE sharing. Never follow
          // an unchecked ancestor while recursively creating a directory.
          if (index == 0) {
            throw const AppFailure(FailureCode.unsafeDirectory);
          }
          _win.createDirectory(current);
        } else if (!_isPlainDirectory(attributes)) {
          throw const AppFailure(FailureCode.unsafeDirectory);
        }
        final finalComponent = index == parts.length - 1;
        final handle = _win.openDirectory(current, exclusive: finalComponent);
        final pin = _DirectoryPin(handle, current);
        pins.add(pin);
        if (!_isPlainDirectory(_win.handleAttributes(handle))) {
          throw const AppFailure(FailureCode.unsafeDirectory);
        }
        final resolved = _win.finalPath(handle);
        // A reparse ancestor or DOS namespace alias must not redirect a pin.
        if (!p.windows.equals(resolved, current)) {
          throw const AppFailure(FailureCode.unsafeDirectory);
        }
        pin.path = resolved;
        current = resolved;
      }
      return DemoDirectory._(pins.last.path, pins);
    } catch (_) {
      var failedClose = false;
      for (final pin in pins.reversed) {
        if (!_win.close(pin.handle)) failedClose = true;
      }
      if (failedClose) {
        throw const AppFailure(FailureCode.ownershipLost);
      }
      rethrow;
    }
  }

  @override
  bool get isHeld {
    if (_released || _lost) return false;
    try {
      ensureHeld();
      return true;
    } on AppFailure {
      return false;
    }
  }

  @override
  void ensureHeld() {
    if (_released || _lost) {
      throw const AppFailure(FailureCode.ownershipLost);
    }
    try {
      for (final pin in _pins) {
        if (!_isPlainDirectory(_win.handleAttributes(pin.handle)) ||
            !p.windows.equals(_win.finalPath(pin.handle), pin.path)) {
          throw const AppFailure(FailureCode.ownershipLost);
        }
      }
    } on AppFailure {
      _lost = true;
      throw const AppFailure(FailureCode.ownershipLost);
    }
  }

  /// The composition root must close the database before releasing its owner.
  /// Failed closes remain recorded and cannot turn into a successful release.
  Future<void> release() async {
    if (_released) return;
    var failedClose = false;
    for (final pin in _pins.reversed) {
      if (pin.closed) continue;
      if (_win.close(pin.handle)) {
        pin.closed = true;
      } else {
        failedClose = true;
      }
    }
    if (failedClose) {
      _lost = true;
      throw const AppFailure(FailureCode.ownershipLost);
    }
    _released = true;
  }

  /// Checks only the fixed database filenames, without reading file contents.
  void ensureDatabaseFilesSafe({String filename = 'm0_demo.sqlite'}) {
    if (filename != 'm0_demo.sqlite' && filename != 'jw.sqlite') {
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
    ensureHeld();
    for (final suffix in ['', '-wal', '-shm']) {
      final attributes = _win.attributes(
        p.windows.join(path, '$filename$suffix'),
      );
      if (attributes != null && (attributes & (0x400 | 0x10)) != 0) {
        throw const AppFailure(FailureCode.unsafeDirectory);
      }
    }
  }

  /// Validate a controlled descendant by metadata only. Static junctions and
  /// reparse files are rejected; this is not a hostile same-user sandbox.
  String checkedChildPath(String relative, {required bool directory}) {
    ensureHeld();
    final target = _safeLocalPath(p.windows.join(path, relative));
    if (p.windows.isAbsolute(relative) || !p.windows.isWithin(path, target)) {
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
    var current = path;
    final parts = p.windows.split(p.windows.relative(target, from: path));
    for (var i = 0; i < parts.length; i++) {
      current = p.windows.join(current, parts[i]);
      final attributes = _win.attributes(current);
      if (attributes == null) continue;
      final expectDirectory = i < parts.length - 1 || directory;
      if (attributes & 0x400 != 0 ||
          (attributes & 0x10 != 0) != expectDirectory) {
        throw const AppFailure(FailureCode.unsafeDirectory);
      }
    }
    return target;
  }

  String createPlainChildDirectory(String relative) {
    final target = checkedChildPath(relative, directory: true);
    _win.createDirectory(target);
    return checkedChildPath(relative, directory: true);
  }
}

bool _isPlainDirectory(int attributes) =>
    attributes & 0x10 != 0 && attributes & 0x400 == 0;

String _safeLocalPath(String value) {
  final absolute = p.windows.normalize(p.windows.absolute(value));
  if (!RegExp(r'^[A-Za-z]:\\').hasMatch(absolute) ||
      absolute.contains('\u0000') ||
      p.windows.split(absolute).length < 2) {
    throw const AppFailure(FailureCode.unsafeDirectory);
  }
  for (final part in p.windows.split(absolute).skip(1)) {
    if (part.endsWith('.') ||
        part.endsWith(' ') ||
        RegExp(r'[<>:"|?*]').hasMatch(part) ||
        RegExp(
          r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)',
          caseSensitive: false,
        ).hasMatch(part)) {
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
  }
  return absolute;
}

final class _DirectoryPin {
  _DirectoryPin(this.handle, this.path);
  final Pointer<Void> handle;
  String path;
  bool closed = false;
}

final _win = _Kernel32();

const _directoryAsset =
    'package:ustc_assistant_m0/platform/demo_directory.dart';

@Native<Uint32 Function(Pointer<Utf16>, Pointer<Uint32>)>(
  assetId: _directoryAsset,
  symbol: 'ustc_directory_attributes',
)
external int _directoryAttributes(
  Pointer<Utf16> path,
  Pointer<Uint32> outError,
);

@Native<Int32 Function(Pointer<Utf16>, Pointer<Uint32>)>(
  assetId: _directoryAsset,
  symbol: 'ustc_directory_create',
)
external int _directoryCreate(Pointer<Utf16> path, Pointer<Uint32> outError);

@Native<Pointer<Void> Function(Pointer<Utf16>, Int32, Pointer<Uint32>)>(
  assetId: _directoryAsset,
  symbol: 'ustc_directory_open',
)
external Pointer<Void> _directoryOpen(
  Pointer<Utf16> path,
  int exclusive,
  Pointer<Uint32> outError,
);

final class _Kernel32 {
  late final _library = DynamicLibrary.open('kernel32.dll');
  late final _getInformation = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint32>),
        int Function(Pointer<Void>, Pointer<Uint32>)
      >('GetFileInformationByHandle');
  late final _getFinalPath = _library
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Pointer<Utf16>, Uint32, Uint32),
        int Function(Pointer<Void>, Pointer<Utf16>, int, int)
      >('GetFinalPathNameByHandleW');
  late final _close = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');

  T _withPath<T>(String path, T Function(Pointer<Utf16>) body) {
    final native = path.toNativeUtf16();
    try {
      return body(native);
    } finally {
      malloc.free(native);
    }
  }

  int? attributes(String path) => _withPath(path, (native) {
    final outError = calloc<Uint32>();
    try {
      final attributes = _directoryAttributes(native, outError);
      if (attributes != 0xffffffff) return attributes;
      final error = outError.value;
      if (error == 2 || error == 3) return null;
      if (error == 32 || error == 33) {
        throw const AppFailure(FailureCode.ownerConflict);
      }
      throw const AppFailure(FailureCode.unsafeDirectory);
    } finally {
      calloc.free(outError);
    }
  });

  void createDirectory(String path) => _withPath(path, (native) {
    final outError = calloc<Uint32>();
    try {
      if (_directoryCreate(native, outError) == 0) {
        if (outError.value != 183) {
          throw const AppFailure(FailureCode.unsafeDirectory);
        }
        // ERROR_ALREADY_EXISTS is idempotent only for a plain directory.
        final existing = attributes(path);
        if (existing == null || !_isPlainDirectory(existing)) {
          throw const AppFailure(FailureCode.unsafeDirectory);
        }
      }
    } finally {
      calloc.free(outError);
    }
  });

  Pointer<Void> openDirectory(String path, {required bool exclusive}) =>
      _withPath(path, (native) {
        // Attributes alone ignore share locks. LIST_DIRECTORY is required to
        // enforce actual process exclusion, but this code never enumerates.
        final outError = calloc<Uint32>();
        try {
          final handle = _directoryOpen(native, exclusive ? 1 : 0, outError);
          if (handle.address == -1 ||
              handle.address == (1 << (sizeOf<IntPtr>() * 8)) - 1) {
            final error = outError.value;
            throw AppFailure(
              error == 32 || error == 33
                  ? FailureCode.ownerConflict
                  : FailureCode.unsafeDirectory,
            );
          }
          return handle;
        } finally {
          calloc.free(outError);
        }
      });

  int handleAttributes(Pointer<Void> handle) {
    // BY_HANDLE_FILE_INFORMATION consists of thirteen 32-bit fields.
    final information = calloc<Uint32>(13);
    try {
      if (_getInformation(handle, information) == 0) {
        throw const AppFailure(FailureCode.ownershipLost);
      }
      return information.value;
    } finally {
      calloc.free(information);
    }
  }

  String finalPath(Pointer<Void> handle) {
    const capacity = 32768;
    final buffer = calloc<Uint16>(capacity).cast<Utf16>();
    try {
      final length = _getFinalPath(handle, buffer, capacity, 0);
      if (length == 0 || length >= capacity) {
        throw const AppFailure(FailureCode.ownershipLost);
      }
      var result = buffer.toDartString(length: length);
      if (result.startsWith('\\\\?\\')) result = result.substring(4);
      return p.windows.normalize(result);
    } finally {
      calloc.free(buffer);
    }
  }

  bool close(Pointer<Void> handle) => _close(handle) != 0;
}
