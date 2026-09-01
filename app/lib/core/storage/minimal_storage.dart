import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:win32/win32.dart';

const String minimalStorageNamespace = 'minimal';

/// Safe, stable failure used when the private minimal storage root cannot be
/// established. The exception deliberately contains no path or platform
/// error details.
final class MinimalStorageError implements Exception {
  const MinimalStorageError();

  static const String code = 'minimal_storage_unavailable';
  static const String safeMessage = 'Local application storage is unavailable.';

  @override
  String toString() => 'MinimalStorageError($code): $safeMessage';
}

/// Resolves the one private storage root used by the minimal Windows runtime.
///
/// The namespace is intentionally fixed. It does not depend on an account,
/// current working directory, executable mode, Git state, or worktree path.
/// A caller may provide a synthetic support-directory loader in tests; the
/// production path always starts at [getApplicationSupportDirectory].
Future<Directory> resolveMinimalStorageRoot({
  Future<Directory> Function()? supportDirectoryLoader,
}) async {
  try {
    final support =
        await (supportDirectoryLoader ?? getApplicationSupportDirectory)();
    final supportPath = _normalizePath(support.path);
    final branches = Directory(_joinPath(supportPath, 'branches'));
    final root = Directory(_joinPath(branches.path, minimalStorageNamespace));

    await _assertSafePath(supportPath);
    await _assertSafePath(branches.path);
    await _assertSafePath(root.path);
    await _assertSafeDatabaseEntry(root);
    await root.create(recursive: true);
    // Re-check after creation so a raced link/reparse point is never handed
    // to SQLite or WebView2 as an apparently private directory.
    await _assertSafePath(root.path);
    await _assertSafeDatabaseEntry(root);

    return Directory(_normalizePath(root.path));
  } on MinimalStorageError {
    rethrow;
  } on Object catch (error, stack) {
    Error.throwWithStackTrace(const MinimalStorageError(), stack);
  }
}

Future<void> _assertSafeDatabaseEntry(Directory root) async {
  final path = _joinPath(root.path, 'ustc_assistant.sqlite');
  final type = await _typeWithoutFollowing(path);
  if (type == FileSystemEntityType.notFound) return;
  if (type != FileSystemEntityType.file || _hasWindowsReparsePoint(path)) {
    throw const MinimalStorageError();
  }
}

Future<void> _assertSafePath(String path) async {
  final normalized = _normalizePath(path);
  final components = <String>[];
  var current = normalized;
  while (true) {
    components.add(current);
    final parent = _normalizePath(Directory(current).parent.path);
    if (parent == current) break;
    current = parent;
  }

  for (final component in components.reversed) {
    final type = await _typeWithoutFollowing(component);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory ||
        type == FileSystemEntityType.link ||
        _hasWindowsReparsePoint(component) ||
        await _resolvesToDifferentPath(component)) {
      throw const MinimalStorageError();
    }
  }
}

Future<FileSystemEntityType> _typeWithoutFollowing(String path) async {
  try {
    return await FileSystemEntity.type(path, followLinks: false);
  } on Object catch (error, stack) {
    Error.throwWithStackTrace(const MinimalStorageError(), stack);
  }
}

Future<bool> _resolvesToDifferentPath(String path) async {
  try {
    final resolved = await Directory(path).resolveSymbolicLinks();
    return _normalizePath(resolved) != _normalizePath(path);
  } on Object catch (error, stack) {
    Error.throwWithStackTrace(const MinimalStorageError(), stack);
  }
}

bool _hasWindowsReparsePoint(String path) {
  if (!Platform.isWindows) return false;
  final nativePath = path.toNativeUtf16();
  try {
    const invalidFileAttributes = 0xffffffff;
    const fileAttributeReparsePoint = 0x400;
    final attributes = GetFileAttributes(PCWSTR(nativePath)).value;
    if (attributes == invalidFileAttributes) return true;
    return (attributes & fileAttributeReparsePoint) != 0;
  } on Object {
    return true;
  } finally {
    calloc.free(nativePath);
  }
}

String _joinPath(String parent, String child) =>
    _normalizePath('$parent${Platform.pathSeparator}$child');

String _normalizePath(String path) {
  final absolute = Directory(path).absolute.path;
  var normalized = Uri.file(
    absolute,
    windows: Platform.isWindows,
  ).normalizePath().toFilePath(windows: Platform.isWindows);
  while (normalized.length > 1 &&
      (normalized.endsWith('/') || normalized.endsWith('\\'))) {
    if (Platform.isWindows && normalized.length == 3 && normalized[1] == ':') {
      break;
    }
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}
