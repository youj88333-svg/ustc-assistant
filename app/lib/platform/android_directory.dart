import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../core/contracts.dart';
import 'owned_directory.dart';

/// A pair of leases shares one app-private parent lock. Neither can outlive it.
final class AndroidDirectories {
  AndroidDirectories._(this.demo, this.formal);
  final OwnedDirectory demo, formal;

  static Future<AndroidDirectories> acquire(String rootPath) async {
    if (!Platform.isAndroid) {
      throw const AppFailure(FailureCode.unsupportedPlatform);
    }
    if (!p.posix.isAbsolute(rootPath) ||
        p.posix.normalize(rootPath) != rootPath ||
        rootPath.contains('\u0000') ||
        rootPath.contains('\\')) {
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
    final name = rootPath.toNativeUtf8();
    final failure = calloc<Int32>();
    Pointer<Void> handle;
    try {
      handle = _acquire(name, failure);
      if (handle == nullptr) _fail(failure.value);
    } finally {
      calloc.free(name);
      calloc.free(failure);
    }
    final owner = _Owner(rootPath, handle);
    try {
      // Both fixed children were created and pinned only after the parent lock.
      owner.ensureHeld();
      return AndroidDirectories._(
        _AndroidDirectory(owner, 'demo_v1'),
        _AndroidDirectory(owner, 'local_v1'),
      );
    } catch (_) {
      owner.close();
      rethrow;
    }
  }
}

final class _Owner {
  _Owner(this.path, this.handle);
  final String path;
  Pointer<Void> handle;
  var references = 2;
  var lost = false;
  var closeFailed = false;

  void ensureHeld() {
    if (handle == nullptr || lost) {
      throw const AppFailure(FailureCode.ownershipLost);
    }
    if (_check(handle) != 0) {
      lost = true;
      throw const AppFailure(FailureCode.ownershipLost);
    }
  }

  void child(String relative, {required bool directory, bool create = false}) {
    ensureHeld();
    if (relative.isEmpty || relative.contains('\u0000')) {
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
    final name = relative.toNativeUtf8();
    try {
      final result = _child(handle, name, directory ? 1 : 0, create ? 1 : 0);
      if (result == 4) lost = true;
      if (result != 0) _fail(result);
    } finally {
      calloc.free(name);
    }
  }

  void close() {
    if (handle == nullptr) {
      if (closeFailed) throw const AppFailure(FailureCode.ownershipLost);
      return;
    }
    final retained = handle;
    handle = nullptr;
    lost = true;
    if (_release(retained) != 0) {
      closeFailed = true;
      throw const AppFailure(FailureCode.ownershipLost);
    }
  }
}

final class _AndroidDirectory implements OwnedDirectory {
  _AndroidDirectory(this.owner, this.relative);
  final _Owner owner;
  final String relative;
  bool _released = false;
  @override
  String get path => p.posix.join(owner.path, relative);
  @override
  p.Context get paths => p.posix;
  @override
  bool get isHeld {
    try {
      ensureHeld();
      return true;
    } on AppFailure {
      return false;
    }
  }

  @override
  void ensureHeld() {
    if (_released) throw const AppFailure(FailureCode.ownershipLost);
    owner.ensureHeld();
    owner.child(relative, directory: true);
  }

  @override
  void ensureDatabaseFilesSafe({String filename = 'm0_demo.sqlite'}) {
    if (filename != 'm0_demo.sqlite' && filename != 'jw.sqlite') {
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
    for (final suffix in ['', '-wal', '-shm']) {
      checkedChildPath('$filename$suffix', directory: false);
    }
  }

  @override
  String checkedChildPath(String child, {required bool directory}) {
    ensureHeld();
    if (child.isEmpty ||
        p.posix.isAbsolute(child) ||
        child.contains('\\') ||
        child.contains('\u0000') ||
        p.posix.normalize(child) != child ||
        p.posix.split(child).any((part) => part == '.' || part == '..')) {
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
    owner.child(p.posix.join(relative, child), directory: directory);
    return p.posix.join(path, child);
  }

  @override
  String createPlainChildDirectory(String child) {
    checkedChildPath(child, directory: true);
    owner.child(p.posix.join(relative, child), directory: true, create: true);
    return checkedChildPath(child, directory: true);
  }

  @override
  Future<void> release() async {
    if (_released) {
      if (owner.closeFailed) throw const AppFailure(FailureCode.ownershipLost);
      return;
    }
    _released = true;
    owner.references--;
    if (owner.references == 0) owner.close();
  }
}

Never _fail(int code) => throw AppFailure(switch (code) {
  1 => FailureCode.unsafeDirectory,
  2 => FailureCode.ownerConflict,
  4 => FailureCode.ownershipLost,
  _ => FailureCode.storageFailed,
});

const _asset = 'package:ustc_assistant_m0/platform/android_directory.dart';
@Native<Pointer<Void> Function(Pointer<Utf8>, Pointer<Int32>)>(
  assetId: _asset,
  symbol: 'ustc_posix_owner_acquire',
)
external Pointer<Void> _acquire(Pointer<Utf8> path, Pointer<Int32> failure);
@Native<Int32 Function(Pointer<Void>)>(
  assetId: _asset,
  symbol: 'ustc_posix_owner_check',
)
external int _check(Pointer<Void> owner);
@Native<Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32, Int32)>(
  assetId: _asset,
  symbol: 'ustc_posix_child',
)
external int _child(
  Pointer<Void> owner,
  Pointer<Utf8> path,
  int directory,
  int create,
);
@Native<Int32 Function(Pointer<Void>)>(
  assetId: _asset,
  symbol: 'ustc_posix_owner_release',
)
external int _release(Pointer<Void> owner);
