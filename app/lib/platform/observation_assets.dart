import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../core/contracts.dart';
import '../core/observation_assets.dart';
import 'owned_directory.dart';

/// Disposable, unclaimed observations. A flushed marker precedes every profile.
/// Only ledger markers are read; browser asset contents are never inspected.
final class ObservationAssets implements ObservationAssetsPort {
  ObservationAssets(this.owner) : _root = 'observation_v1';
  ObservationAssets.young(this.owner) : _root = 'young_observation_v1';
  final OwnedDirectory owner;
  final String _root;
  static final _id = RegExp(r'^obs-[0-9a-f]{32}$');
  final _random = Random.secure();
  String? _active;
  bool _closed = false;

  String _path(String relative, {required bool directory}) =>
      owner.checkedChildPath(
        relative == '.' ? _root : owner.paths.join(_root, relative),
        directory: directory,
      );

  void _ensureRoot() {
    if (_closed) throw const AppFailure(FailureCode.closed);
    owner.createPlainChildDirectory(_root);
  }

  @override
  Future<void> recoverPending(Future<void> Function(String) drain) async {
    _ensureRoot();
    final entries = await Directory(
      _path('.', directory: true),
    ).list(followLinks: false).toList();
    final markers = <String>{};
    final profiles = <String>{};
    final registering = <String>{};
    // First validate the whole ledger. Unknown directories are never deleted.
    for (final entry in entries) {
      final name = owner.paths.basename(entry.path);
      if (name.endsWith('.pending') &&
          _id.hasMatch(name.substring(0, name.length - 8))) {
        final id = name.substring(0, name.length - 8);
        await _validateMarker(id);
        markers.add(id);
      } else if (name.endsWith('.registering') &&
          _id.hasMatch(name.substring(0, name.length - 12))) {
        final id = name.substring(0, name.length - 12);
        _path(name, directory: false);
        registering.add(id);
      } else if (_id.hasMatch(name)) {
        _path(name, directory: true);
        profiles.add(name);
      } else {
        throw const AppFailure(FailureCode.unsafeDirectory);
      }
    }
    if (!markers.containsAll(profiles)) {
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
    for (final id in registering) {
      // This file precedes atomic sealing, hence no browser can own a profile.
      if (profiles.contains(id) || markers.contains(id)) {
        throw const AppFailure(FailureCode.unsafeDirectory);
      }
      await File(_path('$id.registering', directory: false)).delete();
    }
    for (final id in markers) {
      final profilePath = _path(id, directory: true);
      if (await Directory(profilePath).exists()) await drain(profilePath);
      await _deleteRegistered(id);
      if (_active == id) _active = null;
    }
  }

  Future<void> _validateMarker(String id) async {
    final file = File(_path('$id.pending', directory: false));
    if (await file.length() > 256) {
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is! Map ||
          data.length != 3 ||
          data['version'] != 1 ||
          data['purpose'] != 'observation-delete-pending' ||
          data['id'] != id) {
        throw const AppFailure(FailureCode.unsafeDirectory);
      }
    } on FormatException {
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
  }

  @override
  Future<String> register() async {
    _ensureRoot();
    if (_active != null) throw const AppFailure(FailureCode.busy);
    if (await Directory(_path('.', directory: true)).list().isEmpty == false) {
      throw const AppFailure(FailureCode.cleanupPending);
    }
    final id =
        'obs-${List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    final marker = File(_path('$id.pending', directory: false));
    final staging = File(_path('$id.registering', directory: false));
    // A random ID is still checked rather than overwriting any existing file.
    if (await marker.exists() ||
        await Directory(_path(id, directory: true)).exists()) {
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
    await staging.create(exclusive: true);
    final handle = await staging.open(mode: FileMode.writeOnly);
    try {
      await handle.writeString(
        jsonEncode({
          'version': 1,
          'purpose': 'observation-delete-pending',
          'id': id,
        }),
      );
      await handle.flush();
    } finally {
      await handle.close();
    }
    await staging.rename(marker.path);
    _active = id;
    return owner.createPlainChildDirectory(owner.paths.join(_root, id));
  }

  @override
  Future<void> cleanup() async {
    _ensureRoot();
    final id = _active;
    if (id == null) return;
    await _validateMarker(id);
    await _deleteRegistered(id);
    _active = null;
  }

  Future<void> _deleteRegistered(String id) async {
    final directory = Directory(_path(id, directory: true));
    try {
      if (await directory.exists()) {
        // Metadata walk rejects all static reparse descendants before deleting.
        // Dart's recursive delete does not follow links; the owner pins root.
        await for (final entry in directory.list(
          recursive: true,
          followLinks: false,
        )) {
          owner.checkedChildPath(
            owner.paths.relative(entry.path, from: owner.path),
            directory: entry is Directory,
          );
        }
        _path(id, directory: true);
        await directory.delete(recursive: true);
      }
      if (await directory.exists()) {
        throw const AppFailure(FailureCode.cleanupPending);
      }
      await File(_path('$id.pending', directory: false)).delete();
    } on FileSystemException {
      throw const AppFailure(FailureCode.cleanupPending);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    if (_active != null) throw const AppFailure(FailureCode.cleanupPending);
    _ensureRoot();
    if (await Directory(_path('.', directory: true)).list().isEmpty == false) {
      throw const AppFailure(FailureCode.cleanupPending);
    }
    _closed = true;
  }
}
