import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../core/contracts.dart';
import '../core/jw_work_contract.dart';
import 'demo_directory.dart';

/// Private application lifecycle metadata. Browser contents are never read.
final class JwPartitionRegistry {
  JwPartitionRegistry(this.owner);

  final DemoDirectory owner;
  static const _root = 'jw_partitions_v1';
  static final _idPattern = RegExp(r'^jwp-[0-9a-f]{32}$');
  final _random = Random.secure();
  final _records = <String, _Record>{};
  bool _closed = false;
  bool _busy = false;
  bool _ready = false;
  String? _ownerId;
  int? _resetEpoch;

  void _ensureOpen() {
    if (_closed) throw const AppFailure(FailureCode.closed);
    owner.ensureHeld();
  }

  String _path(String name, {required bool directory}) =>
      owner.checkedChildPath(p.windows.join(_root, name), directory: directory);

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    _ensureOpen();
    if (_busy) throw const AppFailure(FailureCode.busy);
    _busy = true;
    try {
      return await action();
    } on FileSystemException {
      throw const AppFailure(FailureCode.storageFailed);
    } finally {
      _busy = false;
    }
  }

  void _requireReady() {
    _ensureOpen();
    if (!_ready ||
        _records.values.any((r) => r.state == _State.deletePending)) {
      throw const AppFailure(FailureCode.cleanupPending);
    }
  }

  void _validateRef(JwPartitionRef ref) {
    JwPartitionRef.decode(ref.metadata);
  }

  void _requireAuthority(JwPartitionRef ref) {
    _validateRef(ref);
    if (ref.ownerId != _ownerId || ref.resetEpoch != _resetEpoch) {
      throw const AppFailure(FailureCode.staleResult);
    }
  }

  _Record _known(JwPartitionRef ref) {
    _validateRef(ref);
    final record = _records[ref.id];
    if (record == null || !record.ref.sameAs(ref)) {
      throw const AppFailure(FailureCode.staleResult);
    }
    return record;
  }

  /// Returns a controlled path, never arbitrary caller-supplied directories.
  String profilePath(JwPartitionRef ref) {
    _requireReady();
    if (_busy) throw const AppFailure(FailureCode.busy);
    _requireAuthority(ref);
    final record = _known(ref);
    if (record.state == _State.deletePending) {
      throw const AppFailure(FailureCode.cleanupPending);
    }
    return _path(ref.id, directory: true);
  }

  Future<JwPartitionRef> createProvisional({
    required String ownerId,
    required JwPartitionPurpose purpose,
    required String attempt,
    required int resetEpoch,
  }) => _exclusive(() async {
    _requireReady();
    if (_records.values.any((r) => r.state == _State.provisional)) {
      throw const AppFailure(FailureCode.busy);
    }
    final id =
        'jwp-${List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    final ref = JwPartitionRef(
      id: id,
      ownerId: ownerId,
      purpose: purpose,
      attempt: attempt,
      resetEpoch: resetEpoch,
    );
    _requireAuthority(ref);
    for (final suffix in ['', '.json', '.registering', '.updating']) {
      final path = _path('$id$suffix', directory: suffix.isEmpty);
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const AppFailure(FailureCode.unsafeDirectory);
      }
    }
    final record = _Record(ref, _State.provisional);
    try {
      // A durable sealed registration exists before any authentication asset.
      await _writeStaging('$id.registering', record);
      await File(
        _path('$id.registering', directory: false),
      ).rename(_path('$id.json', directory: false));
      _records[id] = record;
      owner.createPlainChildDirectory(p.windows.join(_root, id));
      return ref;
    } catch (_) {
      _ready = false;
      rethrow;
    }
  });

  Future<void> claim(JwPartitionRef ref, JwClaimPermit permit) =>
      _exclusive(() async {
        _requireReady();
        _requireAuthority(ref);
        if (permit.accountId != 1 || !permit.partition.sameAs(ref)) {
          throw const AppFailure(FailureCode.staleResult);
        }
        final record = await _current(ref);
        if (record.state == _State.deletePending) {
          throw const AppFailure(FailureCode.cleanupPending);
        }
        final profile = Directory(_path(ref.id, directory: true));
        if (!await profile.exists()) {
          throw const AppFailure(FailureCode.unsafeDirectory);
        }
        await _validateProfileMetadata(profile);
        if (record.state != _State.claimed) {
          await _transition(record, _State.claimed);
        }
      });

  Future<String> openClaimed(
    JwClaimPermit permit, {
    required String ownerId,
    required int resetEpoch,
  }) => _exclusive(() async {
    _requireReady();
    final ref = permit.partition;
    _requireAuthority(ref);
    if (permit.accountId != 1 ||
        ownerId != _ownerId ||
        resetEpoch != _resetEpoch) {
      throw const AppFailure(FailureCode.staleResult);
    }
    final record = await _current(ref);
    if (record.state != _State.claimed) {
      throw const AppFailure(FailureCode.cleanupPending);
    }
    final path = _path(ref.id, directory: true);
    final profile = Directory(path);
    if (!await profile.exists()) {
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
    await _validateProfileMetadata(profile);
    return path;
  });

  Future<void> markDeletePending(JwPartitionRef ref) => _exclusive(() async {
    final record = await _current(ref);
    await _transition(record, _State.deletePending);
  });

  /// The callback must close and drain every native resource for this path.
  Future<void> clear(JwPartitionRef ref, Future<void> Function(String) drain) =>
      _exclusive(() async {
        final record = await _current(ref);
        await _transition(record, _State.deletePending);
        await _delete(_records[ref.id]!, drain);
      });

  Future<List<JwPartitionRef>> reconcile(
    List<JwClaimPermit> permits, {
    required String ownerId,
    required int resetEpoch,
    required Future<void> Function(String) drain,
  }) => _exclusive(() async {
    _ready = false;
    // Reuse the public metadata schema to validate authority inputs.
    _validateRef(
      JwPartitionRef(
        id: 'jwp-00000000000000000000000000000000',
        ownerId: ownerId,
        purpose: JwPartitionPurpose.initial,
        attempt: 'jw-0-0',
        resetEpoch: resetEpoch,
      ),
    );
    owner.createPlainChildDirectory(_root);
    final records = await _scan();
    _records
      ..clear()
      ..addEntries(records.map((r) => MapEntry(r.ref.id, r)));
    // Pending deletion takes precedence even over a current committed permit.
    for (final record in records.where(
      (r) => r.state == _State.deletePending,
    )) {
      await _delete(record, drain);
    }
    for (final record in records.where(
      (r) => r.state != _State.deletePending,
    )) {
      final valid =
          record.ref.ownerId == ownerId &&
          record.ref.resetEpoch == resetEpoch &&
          permits.any(
            (permit) =>
                permit.accountId == 1 && permit.partition.sameAs(record.ref),
          );
      final exists = await Directory(
        _path(record.ref.id, directory: true),
      ).exists();
      if (!valid || !exists) {
        await _transition(record, _State.deletePending);
        await _delete(_records[record.ref.id]!, drain);
      } else {
        await _validateProfileMetadata(
          Directory(_path(record.ref.id, directory: true)),
        );
        if (record.state != _State.claimed) {
          await _transition(record, _State.claimed);
        }
      }
    }
    _ownerId = ownerId;
    _resetEpoch = resetEpoch;
    _ready = true;
    return List.unmodifiable(_records.values.map((r) => r.ref));
  });

  Future<_Record> _read(String name, String id) async {
    final file = File(_path(name, directory: false));
    if (await file.length() > 2048) {
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic> ||
          value.length != 4 ||
          value['version'] != 1 ||
          value['purpose'] != 'jw-partition-ledger' ||
          value['partition'] is! Map<String, dynamic> ||
          !_State.values.any((state) => state.name == value['state'])) {
        throw const AppFailure(FailureCode.unsafeDirectory);
      }
      final ref = JwPartitionRef.decode(
        value['partition'] as Map<String, dynamic>,
      );
      if (ref.id != id) throw const AppFailure(FailureCode.unsafeDirectory);
      return _Record(
        ref,
        _State.values.singleWhere((s) => s.name == value['state']),
      );
    } on FormatException {
      throw const AppFailure(FailureCode.unsafeDirectory);
    } on AppFailure {
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
  }

  Future<_Record> _current(JwPartitionRef ref) async {
    _ensureOpen();
    final expected = _known(ref);
    final record = await _read('${ref.id}.json', ref.id);
    if (!record.ref.sameAs(ref) || record.state != expected.state) {
      _ready = false;
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
    return record;
  }

  Future<List<_Record>> _scan() async {
    final records = <String, _Record>{};
    final updates = <String, _Record>{};
    final registering = <String>{};
    final profiles = <String>{};
    final entries = await Directory(
      _path('.', directory: true),
    ).list(followLinks: false).toList();
    // Validate the entire ledger before any recovery mutation or deletion.
    for (final entry in entries) {
      final name = p.windows.basename(entry.path);
      if (_idPattern.hasMatch(name)) {
        _path(name, directory: true);
        profiles.add(name);
      } else {
        final suffix = [
          '.json',
          '.updating',
          '.registering',
        ].where(name.endsWith).firstOrNull;
        if (suffix == null) throw const AppFailure(FailureCode.unsafeDirectory);
        final id = name.substring(0, name.length - suffix.length);
        if (!_idPattern.hasMatch(id)) {
          throw const AppFailure(FailureCode.unsafeDirectory);
        }
        _path(name, directory: false);
        if (suffix == '.registering') {
          registering.add(id);
        } else if (suffix == '.json') {
          records[id] = await _read(name, id);
        } else {
          updates[id] = await _read(name, id);
        }
      }
    }
    if (!records.keys.toSet().containsAll(profiles) ||
        !records.keys.toSet().containsAll(updates.keys) ||
        registering.any(
          (id) =>
              records.containsKey(id) ||
              profiles.contains(id) ||
              updates.containsKey(id),
        )) {
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
    for (final entry in updates.entries) {
      final before = records[entry.key]!;
      final after = entry.value;
      if (!before.ref.sameAs(after.ref) ||
          !_allowed(before.state, after.state)) {
        throw const AppFailure(FailureCode.unsafeDirectory);
      }
    }
    for (final id in registering) {
      await File(_path('$id.registering', directory: false)).delete();
    }
    for (final entry in updates.entries) {
      await File(
        _path('${entry.key}.updating', directory: false),
      ).rename(_path('${entry.key}.json', directory: false));
      records[entry.key] = entry.value;
    }
    return records.values.toList();
  }

  bool _allowed(_State before, _State after) =>
      before == after ||
      after == _State.deletePending ||
      (before == _State.provisional && after == _State.claimed);

  Future<void> _writeStaging(String name, _Record record) async {
    final file = File(_path(name, directory: false));
    await file.create(exclusive: true);
    final handle = await file.open(mode: FileMode.writeOnly);
    try {
      await handle.writeString(jsonEncode(record.metadata));
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  Future<void> _transition(_Record before, _State state) async {
    if (before.state == state) return;
    if (!_allowed(before.state, state)) {
      throw const AppFailure(FailureCode.cleanupPending);
    }
    final next = _Record(before.ref, state);
    try {
      await _writeStaging('${before.ref.id}.updating', next);
      await File(
        _path('${before.ref.id}.updating', directory: false),
      ).rename(_path('${before.ref.id}.json', directory: false));
      _records[before.ref.id] = next;
    } catch (_) {
      _ready = false;
      rethrow;
    }
  }

  Future<void> _delete(
    _Record record,
    Future<void> Function(String) drain,
  ) async {
    final id = record.ref.id;
    final profile = Directory(_path(id, directory: true));
    try {
      if (await profile.exists()) {
        await _validateProfileMetadata(profile);
        await drain(profile.path);
        owner.ensureHeld();
        await _validateProfileMetadata(profile);
        _path(id, directory: true);
        await profile.delete(recursive: true);
      }
      if (await profile.exists()) {
        throw const AppFailure(FailureCode.cleanupPending);
      }
      await File(_path('$id.json', directory: false)).delete();
      _records.remove(id);
    } on FileSystemException {
      throw const AppFailure(FailureCode.cleanupPending);
    }
  }

  Future<void> _validateProfileMetadata(Directory profile) async {
    // A recovery-only browser must not first open a known reparse descendant.
    // Recheck after draining before physical deletion; no file body is read.
    await for (final entry in profile.list(
      recursive: true,
      followLinks: false,
    )) {
      owner.checkedChildPath(
        p.windows.relative(entry.path, from: owner.path),
        directory: entry is Directory,
      );
    }
  }

  Future<void> close() async {
    if (_closed) return;
    await _exclusive(() async {
      if (_records.values.any((r) => r.state != _State.claimed) || !_ready) {
        throw const AppFailure(FailureCode.cleanupPending);
      }
      _closed = true;
    });
  }
}

enum _State { provisional, claimed, deletePending }

final class _Record {
  const _Record(this.ref, this.state);
  final JwPartitionRef ref;
  final _State state;
  Map<String, Object> get metadata => {
    'version': 1,
    'purpose': 'jw-partition-ledger',
    'partition': ref.metadata,
    'state': state.name,
  };
}
