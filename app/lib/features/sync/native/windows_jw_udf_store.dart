library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../../settings/application/minimal_reset_coordinator.dart';

typedef DirectoryDelete = Future<void> Function(Directory directory);
typedef ReleaseDelay = Future<void> Function(Duration duration);

final class _ClearTarget {
  const _ClearTarget({
    required this.directory,
    this.ref,
    required this.legacy,
  });

  final Directory directory;
  final JwSessionPartitionRef? ref;
  final bool legacy;

  String get sortKey => legacy
      ? 'legacy:${WindowsJwUdfStore._normalizePath(directory.path)}'
      : 'partition:${ref!.opaqueToken}';
}

/// Opaque capability for one JW browser user-data partition.
///
/// The token is deliberately not a path and contains no account material.
/// [WindowsJwUdfStore] is the only code that maps it to a directory.
final class JwSessionPartitionRef {
  const JwSessionPartitionRef(this.opaqueToken);

  final String opaqueToken;

  @override
  String toString() => 'JwSessionPartitionRef($opaqueToken)';
}

/// Base class for errors exposed by the UDF store.
///
/// The code and message are fixed safe values. In particular, this type never
/// includes an account id, a filesystem path, or a native OS error string.
class JwUdfError implements Exception {
  const JwUdfError(this.code, this.safeMessage);

  final String code;
  final String safeMessage;

  String get message => safeMessage;

  String get safeCode => code;

  @override
  String toString() => 'JwUdfError($code): $safeMessage';
}

/// Raised when a caller-supplied reference or filesystem entry is not safely
/// contained by the app-owned JW UDF root.
final class JwUdfPrivacyError extends JwUdfError {
  const JwUdfPrivacyError()
    : super(
        'privacy_rejected',
        'The browser session path failed the privacy containment check.',
      );
}

/// Raised when a store operation cannot establish or update its private
/// storage without exposing platform details to the caller.
final class JwUdfStorageError extends JwUdfError {
  const JwUdfStorageError()
    : super(
        'browser_storage_unavailable',
        'The browser session storage is unavailable.',
      );
}

/// Raised after a physical UDF clear did not complete.
final class JwUdfClearError extends JwUdfError {
  const JwUdfClearError([String code = 'browser_cleanup_incomplete'])
    : super(
        code == 'browser_cleanup_incomplete'
            ? code
            : 'browser_cleanup_incomplete',
        'Browser session cleanup is incomplete.',
      );
}

/// Platform-private, fail-closed JW UDF and quarantine marker store.
final class WindowsJwUdfStore implements ResetUdfPort {
  WindowsJwUdfStore({
    required Directory privateRoot,
    DirectoryDelete? deleteDirectory,
    int releaseAttempts = 20,
    Duration releaseRetryDelay = const Duration(milliseconds: 250),
    ReleaseDelay? releaseDelay,
  }) : _privateRoot = Directory(_normalizePath(privateRoot.absolute.path)),
       _deleteDirectory = deleteDirectory ?? _deleteRecursively,
       _releaseAttempts = _validateReleaseAttempts(releaseAttempts),
       _releaseRetryDelay = _validateReleaseRetryDelay(releaseRetryDelay),
       _releaseDelay = releaseDelay ?? _defaultReleaseDelay;

  static final RegExp _tokenPattern = RegExp(r'^jw_[0-9a-f]{24}$');
  static final RegExp _legacyUuidV4Pattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  static final RegExp _markerPattern = RegExp(r'^(jw_[0-9a-f]{24})\.json$');
  static final RegExp _temporaryMarkerPattern = RegExp(
    r'^(jw_[0-9a-f]{24})\.json\.tmp$',
  );

  // Task 3 only needs this stable, source-independent failure code. Keep the
  // set closed so arbitrary caller text cannot be persisted in a marker.
  static const Set<String> _safeQuarantineCodes = <String>{
    'collection_failed',
    'browser_cleanup_incomplete',
    'privacy_rejected',
  };

  // FILE_ATTRIBUTE_REPARSE_POINT. This is intentionally kept as a literal so
  // the path guard remains available on non-Windows test hosts too.
  static const int _fileAttributeReparsePoint = 0x400;
  static const int _invalidFileAttributes = 0xffffffff;

  final Directory _privateRoot;
  final DirectoryDelete _deleteDirectory;
  final int _releaseAttempts;
  final Duration _releaseRetryDelay;
  final ReleaseDelay _releaseDelay;

  /// Canonical app-owned root containing direct JW token directories.
  Directory get udfRoot => Directory(_udfRootPath);

  /// Canonical app-owned root containing quarantine marker files.
  Directory get quarantineRoot => Directory(_quarantineRootPath);

  String get _browserSessionsRootPath =>
      _joinPath(_privateRoot.path, 'browser_sessions');

  String get _udfRootPath => _joinPath(_browserSessionsRootPath, 'jw');

  String get _quarantineRootPath =>
      _joinPath(_browserSessionsRootPath, 'quarantine');

  String get _legacyRootPath => _joinPath(_privateRoot.path, 'webview');

  /// Derives a stable opaque token without retaining or returning account text.
  JwSessionPartitionRef referenceFor(String accountId) {
    final digest = sha256.convert(utf8.encode(accountId)).toString();
    return JwSessionPartitionRef('jw_${digest.substring(0, 24)}');
  }

  /// Maps a valid opaque ref to its direct child path for platform consumers
  /// and focused containment tests. It never accepts an arbitrary path.
  Directory resolveForTest(JwSessionPartitionRef ref) => _resolve(ref);

  /// Enumerates only direct, owned token-directory children of [udfRoot].
  /// Unknown entries fail closed before any deletion is attempted.
  Future<List<JwSessionPartitionRef>> listOwnedPartitions() async {
    final root = udfRoot;
    await _assertNoReparseTraversal(root.path);
    final rootType = await _typeWithoutFollowing(root.path);
    if (rootType == FileSystemEntityType.notFound) {
      return <JwSessionPartitionRef>[];
    }
    if (rootType != FileSystemEntityType.directory) {
      throw const JwUdfPrivacyError();
    }

    final refs = <JwSessionPartitionRef>[];
    try {
      await for (final entry in root.list(followLinks: false)) {
        final name = _basename(_normalizePath(entry.path));
        if (!_isToken(name)) {
          throw const JwUdfPrivacyError();
        }
        final type = await _typeWithoutFollowing(entry.path);
        if (type != FileSystemEntityType.directory) {
          throw const JwUdfPrivacyError();
        }
        await _assertNoReparseTraversal(entry.path);
        refs.add(JwSessionPartitionRef(name));
      }
    } on JwUdfError {
      rethrow;
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(const JwUdfPrivacyError(), stack);
    }
    refs.sort((left, right) => left.opaqueToken.compareTo(right.opaqueToken));
    return refs;
  }

  Future<List<_ClearTarget>> _listClearablePartitions() async {
    final byPath = <String, _ClearTarget>{};
    for (final ref in await listOwnedPartitions()) {
      final directory = _resolve(ref);
      byPath[_normalizePath(directory.path)] = _ClearTarget(
        directory: directory,
        ref: ref,
        legacy: false,
      );
    }
    for (final ref in await _listQuarantineArtifacts()) {
      final directory = _resolve(ref);
      byPath[_normalizePath(directory.path)] = _ClearTarget(
        directory: directory,
        ref: ref,
        legacy: false,
      );
    }
    for (final directory in await _listLegacyPartitions()) {
      byPath[_normalizePath(directory.path)] = _ClearTarget(
        directory: directory,
        legacy: true,
      );
    }
    final targets = byPath.values.toList()
      ..sort((left, right) => left.sortKey.compareTo(right.sortKey));
    return targets;
  }

  /// Enumerates only historical UUIDv4 direct children of the injected
  /// [privateRoot]/webview directory. Legacy sessions are clear-only targets;
  /// they are never mapped back to an account or reused for collection.
  Future<List<Directory>> _listLegacyPartitions() async {
    final root = Directory(_legacyRootPath);
    await _assertNoReparseTraversal(root.path);
    final rootType = await _typeWithoutFollowing(root.path);
    if (rootType == FileSystemEntityType.notFound) {
      return <Directory>[];
    }
    if (rootType != FileSystemEntityType.directory) {
      throw const JwUdfPrivacyError();
    }

    final directories = <Directory>[];
    try {
      await for (final entry in root.list(followLinks: false)) {
        final target = Directory(_normalizePath(entry.path));
        _validateLegacyResolvedPath(target);
        final name = _basename(target.path);
        if (!_isLegacyUuidV4(name)) {
          throw const JwUdfPrivacyError();
        }
        if (await _typeWithoutFollowing(target.path) !=
            FileSystemEntityType.directory) {
          throw const JwUdfPrivacyError();
        }
        await _assertNoReparseTree(target);
        directories.add(target);
      }
    } on JwUdfError {
      rethrow;
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(const JwUdfPrivacyError(), stack);
    }
    directories.sort(
      (left, right) => _normalizePath(left.path).compareTo(
        _normalizePath(right.path),
      ),
    );
    return directories;
  }

  Future<List<JwSessionPartitionRef>> _listQuarantineArtifacts() async {
    final root = quarantineRoot;
    await _assertNoReparseTraversal(root.path);
    final rootType = await _typeWithoutFollowing(root.path);
    if (rootType == FileSystemEntityType.notFound) {
      return <JwSessionPartitionRef>[];
    }
    if (rootType != FileSystemEntityType.directory) {
      throw const JwUdfPrivacyError();
    }

    final refs = <String, JwSessionPartitionRef>{};
    try {
      await for (final entry in root.list(followLinks: false)) {
        final name = _basename(_normalizePath(entry.path));
        final markerMatch = _markerPattern.firstMatch(name);
        final temporaryMatch = _temporaryMarkerPattern.firstMatch(name);
        final token = markerMatch?.group(1) ?? temporaryMatch?.group(1);
        if (token == null) {
          throw const JwUdfPrivacyError();
        }
        if (await _typeWithoutFollowing(entry.path) !=
            FileSystemEntityType.file) {
          throw const JwUdfPrivacyError();
        }
        await _assertNoReparseTraversal(entry.path);
        refs[token] = JwSessionPartitionRef(token);
      }
    } on JwUdfError {
      rethrow;
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(const JwUdfPrivacyError(), stack);
    }
    return refs.values.toList()
      ..sort((left, right) => left.opaqueToken.compareTo(right.opaqueToken));
  }

  /// Ensures that one valid token partition exists below the canonical root.
  Future<Directory> ensurePartition(JwSessionPartitionRef ref) async {
    final directory = _resolve(ref);
    try {
      await _assertNoReparseTraversal(directory.path);
      final existingType = await _typeWithoutFollowing(directory.path);
      if (existingType != FileSystemEntityType.notFound &&
          existingType != FileSystemEntityType.directory) {
        throw const JwUdfPrivacyError();
      }
      await directory.create(recursive: true);
      // Re-check after creation so a pre-existing or raced reparse point is
      // never handed to WebView2 as an apparently contained directory.
      await _assertNoReparseTree(directory);
      return directory;
    } on JwUdfError {
      rethrow;
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(const JwUdfStorageError(), stack);
    }
  }

  /// Persists a safe quarantine marker atomically for one partition.
  Future<void> markQuarantined(
    JwSessionPartitionRef ref,
    String safeCode,
  ) async {
    _resolve(ref);
    if (!_safeQuarantineCodes.contains(safeCode)) {
      throw const JwUdfPrivacyError();
    }

    try {
      final root = quarantineRoot;
      await _assertNoReparseTraversal(root.path);
      await root.create(recursive: true);
      await _assertNoReparseTraversal(root.path);

      final marker = _marker(ref);
      await _assertNoReparseTraversal(marker.path);
      final markerType = await _typeWithoutFollowing(marker.path);
      if (markerType == FileSystemEntityType.file) return;
      if (markerType != FileSystemEntityType.notFound) {
        throw const JwUdfPrivacyError();
      }

      final temporary = _temporaryMarker(ref);
      await _assertNoReparseTraversal(temporary.path);
      final temporaryType = await _typeWithoutFollowing(temporary.path);
      if (temporaryType != FileSystemEntityType.notFound &&
          temporaryType != FileSystemEntityType.file) {
        throw const JwUdfPrivacyError();
      }
      await temporary.writeAsString(
        jsonEncode(<String, Object?>{
          'version': 1,
          'partition': ref.opaqueToken,
          'reasonCode': safeCode,
        }),
        flush: true,
      );
      await temporary.rename(marker.path);
    } on JwUdfError {
      rethrow;
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(const JwUdfStorageError(), stack);
    }
  }

  /// Returns whether the opaque ref currently has a quarantine marker.
  Future<bool> isQuarantined(JwSessionPartitionRef ref) async {
    _resolve(ref);
    final marker = _marker(ref);
    await _assertNoReparseTraversal(marker.path);
    final type = await _typeWithoutFollowing(marker.path);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.file) {
      throw const JwUdfPrivacyError();
    }
    return true;
  }

  /// Deletes one contained token partition and then its marker.
  ///
  /// The marker is removed only after the physical partition is confirmed
  /// absent. A failed deletion therefore remains visible for a later retry.
  Future<void> clearPartition(JwSessionPartitionRef ref) async {
    final directory = _resolve(ref);
    try {
      await _deleteOwnedDirectory(directory);
      await _removeMarker(ref);
      await _removeTemporaryMarker(ref);
    } on JwUdfError {
      rethrow;
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(const JwUdfClearError(), stack);
    }
  }

  /// Deletes one arbitrary [Directory] only when it proves to be a direct
  /// token child of [udfRoot]. This remains useful to platform tests while
  /// keeping all production callers on opaque refs.
  Future<void> deleteResolved(Directory directory) async {
    final target = Directory(_normalizePath(directory.path));
    _validateResolvedPath(target);
    try {
      await _deleteOwnedDirectory(target);
    } on JwUdfError {
      rethrow;
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(const JwUdfClearError(), stack);
    }
  }

  /// Attempts every owned partition, retaining the first failure as the
  /// public failure while still making best effort on later partitions.
  @override
  Future<void> clearAllPartitions() async {
    final targets = await _listClearablePartitions();
    Object? firstFailure;
    StackTrace? firstStack;
    for (final target in targets) {
      try {
        if (target.legacy) {
          await _deleteLegacyDirectory(target.directory);
        } else {
          await clearPartition(target.ref!);
        }
      } on Object catch (error, stack) {
        firstFailure ??= error;
        firstStack ??= stack;
      }
    }
    if (firstFailure != null) {
      Error.throwWithStackTrace(
        const JwUdfClearError('browser_cleanup_incomplete'),
        firstStack!,
      );
    }
  }

  Future<void> _deleteOwnedDirectory(Directory directory) async {
    await _deleteContainedDirectory(directory, _validateResolvedPath);
  }

  Future<void> _deleteLegacyDirectory(Directory directory) async {
    await _deleteContainedDirectory(directory, _validateLegacyResolvedPath);
  }

  Future<void> _deleteContainedDirectory(
    Directory directory,
    void Function(Directory) validate,
  ) async {
    validate(directory);
    final type = await _typeWithoutFollowing(directory.path);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory) {
      throw const JwUdfPrivacyError();
    }
    await _assertNoReparseTree(directory);
    await _deleteAfterRelease(
      directory,
      validate: () => validate(directory),
    );
    final remaining = await _typeWithoutFollowing(directory.path);
    if (remaining != FileSystemEntityType.notFound) {
      throw const JwUdfClearError();
    }
  }

  Future<void> _removeMarker(JwSessionPartitionRef ref) async {
    final marker = _marker(ref);
    await _assertNoReparseTraversal(marker.path);
    final type = await _typeWithoutFollowing(marker.path);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) {
      throw const JwUdfPrivacyError();
    }
    await marker.delete();
    if (await _typeWithoutFollowing(marker.path) !=
        FileSystemEntityType.notFound) {
      throw const JwUdfClearError();
    }
  }

  Future<void> _removeTemporaryMarker(JwSessionPartitionRef ref) async {
    final marker = _temporaryMarker(ref);
    await _assertNoReparseTraversal(marker.path);
    final type = await _typeWithoutFollowing(marker.path);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) {
      throw const JwUdfPrivacyError();
    }
    await marker.delete();
    if (await _typeWithoutFollowing(marker.path) !=
        FileSystemEntityType.notFound) {
      throw const JwUdfClearError();
    }
  }

  Directory _resolve(JwSessionPartitionRef ref) {
    if (!_isToken(ref.opaqueToken)) {
      throw const JwUdfPrivacyError();
    }
    return Directory(_joinPath(_udfRootPath, ref.opaqueToken));
  }

  File _marker(JwSessionPartitionRef ref) =>
      File(_joinPath(_quarantineRootPath, '${ref.opaqueToken}.json'));

  File _temporaryMarker(JwSessionPartitionRef ref) =>
      File('${_marker(ref).path}.tmp');

  void _validateResolvedPath(Directory target) {
    final normalizedRoot = _normalizePath(_udfRootPath);
    final normalizedTarget = _normalizePath(target.path);
    if (normalizedTarget == normalizedRoot ||
        _normalizePath(target.parent.path) != normalizedRoot ||
        !_isToken(_basename(normalizedTarget))) {
      throw const JwUdfPrivacyError();
    }
  }

  void _validateLegacyResolvedPath(Directory target) {
    final normalizedBoundary = _normalizePath(_privateRoot.path);
    final normalizedRoot = _normalizePath(_legacyRootPath);
    final normalizedTarget = _normalizePath(target.path);
    if (normalizedTarget == normalizedRoot ||
        _normalizePath(target.parent.path) != normalizedRoot ||
        !_isWithin(normalizedTarget, normalizedBoundary) ||
        !_isLegacyUuidV4(_basename(normalizedTarget))) {
      throw const JwUdfPrivacyError();
    }
  }

  Future<void> _assertNoReparseTree(Directory directory) async {
    final type = await _typeWithoutFollowing(directory.path);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory) {
      throw const JwUdfPrivacyError();
    }
    await _assertNoReparseTraversal(directory.path);
    try {
      await for (final entry in directory.list(followLinks: false)) {
        final entryType = await _typeWithoutFollowing(entry.path);
        if (entryType == FileSystemEntityType.link ||
            _hasWindowsReparsePoint(entry.path)) {
          throw const JwUdfPrivacyError();
        }
        if (entryType == FileSystemEntityType.directory) {
          await _assertNoReparseTree(Directory(entry.path));
        } else if (entryType != FileSystemEntityType.file) {
          throw const JwUdfPrivacyError();
        }
      }
    } on JwUdfError {
      rethrow;
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(const JwUdfPrivacyError(), stack);
    }
  }

  /// Checks each existing path component without following links. Existing
  /// Windows reparse points are rejected both through Dart's link type and the
  /// native FILE_ATTRIBUTE_REPARSE_POINT bit.
  Future<void> _assertNoReparseTraversal(String path) async {
    final normalizedBoundary = _normalizePath(_privateRoot.path);
    final normalizedTarget = _normalizePath(path);
    if (!_isWithin(normalizedTarget, normalizedBoundary)) {
      throw const JwUdfPrivacyError();
    }

    var current = normalizedBoundary;
    final boundaryType = await _typeWithoutFollowing(current);
    if (boundaryType == FileSystemEntityType.notFound) return;
    if (boundaryType == FileSystemEntityType.link ||
        _hasWindowsReparsePoint(current) ||
        boundaryType != FileSystemEntityType.directory) {
      throw const JwUdfPrivacyError();
    }
    if (await _resolvesToDifferentPath(current)) {
      throw const JwUdfPrivacyError();
    }

    final suffix = normalizedTarget.substring(normalizedBoundary.length);
    final components = suffix
        .split(RegExp(r'[\\/]'))
        .where((component) => component.isNotEmpty)
        .toList();
    for (var index = 0; index < components.length; index++) {
      current = _joinPath(current, components[index]);
      final type = await _typeWithoutFollowing(current);
      if (type == FileSystemEntityType.notFound) return;
      if (type == FileSystemEntityType.link ||
          _hasWindowsReparsePoint(current)) {
        throw const JwUdfPrivacyError();
      }
      final isLast = index == components.length - 1;
      if (!isLast && type != FileSystemEntityType.directory) {
        throw const JwUdfPrivacyError();
      }
      if (type == FileSystemEntityType.directory &&
          await _resolvesToDifferentPath(current)) {
        throw const JwUdfPrivacyError();
      }
    }
  }

  Future<FileSystemEntityType> _typeWithoutFollowing(String path) async {
    try {
      return await FileSystemEntity.type(path, followLinks: false);
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(const JwUdfPrivacyError(), stack);
    }
  }

  Future<bool> _resolvesToDifferentPath(String path) async {
    try {
      final resolved = await Directory(path).resolveSymbolicLinks();
      return _normalizePath(resolved) != _normalizePath(path);
    } on Object {
      // If an existing component cannot be resolved, containment is not
      // provable. Refuse it rather than making a best-effort deletion.
      return true;
    }
  }

  Future<void> _deleteAfterRelease(
    Directory directory, {
    required void Function() validate,
  }) async {
    for (var attempt = 1; attempt <= _releaseAttempts; attempt++) {
      try {
        // Revalidate the canonical direct-child boundary and the full tree on
        // every physical attempt. A retry can observe a changed filesystem
        // after the release delay, so the initial pre-delay check is not
        // sufficient.
        validate();
        final type = await _typeWithoutFollowing(directory.path);
        if (type == FileSystemEntityType.notFound) return;
        if (type != FileSystemEntityType.directory) {
          throw const JwUdfPrivacyError();
        }
        await _assertNoReparseTree(directory);
        validate();
        await _deleteDirectory(directory);
        return;
      } on FileSystemException catch (error, stack) {
        if (!_isTransientReleaseError(error) || attempt == _releaseAttempts) {
          Error.throwWithStackTrace(error, stack);
        }
        await _releaseDelay(_releaseRetryDelay);
      }
    }
  }

  bool _isTransientReleaseError(FileSystemException error) {
    final code = error.osError?.errorCode;
    return code == 5 || code == 32;
  }

  bool _hasWindowsReparsePoint(String path) {
    if (!Platform.isWindows) return false;
    final nativePath = path.toNativeUtf16();
    try {
      final attributes = GetFileAttributes(PCWSTR(nativePath)).value;
      if (attributes == _invalidFileAttributes) return true;
      return (attributes & _fileAttributeReparsePoint) != 0;
    } on Object {
      return true;
    } finally {
      calloc.free(nativePath);
    }
  }

  static bool _isToken(String value) => _tokenPattern.hasMatch(value);

  static bool _isLegacyUuidV4(String value) =>
      _legacyUuidV4Pattern.hasMatch(value);

  static bool _isWithin(String target, String boundary) {
    if (target == boundary) return true;
    return target.startsWith('$boundary${Platform.pathSeparator}');
  }

  static String _basename(String path) {
    final slash = path.lastIndexOf('/');
    final backslash = path.lastIndexOf('\\');
    final separator = slash > backslash ? slash : backslash;
    return separator < 0 ? path : path.substring(separator + 1);
  }

  static String _joinPath(String parent, String child) =>
      _normalizePath('$parent${Platform.pathSeparator}$child');

  static String _normalizePath(String path) {
    final absolute = Directory(path).absolute.path;
    var normalized = Uri.file(
      absolute,
      windows: Platform.isWindows,
    ).normalizePath().toFilePath(windows: Platform.isWindows);
    while (normalized.length > 1 &&
        (normalized.endsWith('/') || normalized.endsWith('\\'))) {
      if (Platform.isWindows &&
          normalized.length == 3 &&
          normalized[1] == ':') {
        break;
      }
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  static int _validateReleaseAttempts(int attempts) {
    if (attempts < 1) {
      throw ArgumentError.value(attempts, 'releaseAttempts');
    }
    return attempts;
  }

  static Duration _validateReleaseRetryDelay(Duration delay) {
    if (delay.isNegative) {
      throw ArgumentError.value(delay, 'releaseRetryDelay');
    }
    return delay;
  }

  static Future<void> _defaultReleaseDelay(Duration duration) =>
      Future<void>.delayed(duration);

  static Future<void> _deleteRecursively(Directory directory) async {
    await directory.delete(recursive: true);
  }
}
