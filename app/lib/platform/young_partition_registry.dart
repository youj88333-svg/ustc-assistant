import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../core/contracts.dart';
import '../core/young_work_contract.dart';
import 'demo_directory.dart';

/// Owns only the application's Young browser profile subdirectory and ledger.
/// It never inspects the JW or observation partition roots.
final class YoungPartitionRegistry {
  YoungPartitionRegistry(this.owner);

  final DemoDirectory owner;
  static const _root = 'young_partitions_v1';
  static final _idPattern = RegExp(r'^yp-[0-9a-f]{32}$');
  final _random = Random.secure();
  final _records = <String, _YoungRecord>{};
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
        _records.values.any(
          (record) => record.state == _YoungState.deletePending,
        )) {
      throw const AppFailure(FailureCode.cleanupPending);
    }
  }

  void _validateRef(YoungPartitionRef ref) {
    YoungPartitionRef.decode(ref.metadata);
  }

  void _requireAuthority(YoungPartitionRef ref) {
    _validateRef(ref);
    if (ref.ownerId != _ownerId || ref.resetEpoch != _resetEpoch) {
      throw const AppFailure(FailureCode.staleResult);
    }
  }

  _YoungRecord _known(YoungPartitionRef ref) {
    _validateRef(ref);
    final record = _records[ref.id];
    if (record == null || !record.ref.sameAs(ref)) {
      throw const AppFailure(FailureCode.staleResult);
    }
    return record;
  }

  /// Returns a controlled Young profile path, never a caller-supplied path.
  String profilePath(YoungPartitionRef ref) {
    _requireReady();
    if (_busy) throw const AppFailure(FailureCode.busy);
    _requireAuthority(ref);
    final record = _known(ref);
    if (record.state == _YoungState.deletePending) {
      throw const AppFailure(FailureCode.cleanupPending);
    }
    return _path(ref.id, directory: true);
  }

  Future<YoungPartitionRef> createProvisional({
    required String ownerId,
    required YoungPartitionPurpose purpose,
    required String attempt,
    required int resetEpoch,
  }) => _exclusive(() async {
    _requireReady();
    if (ownerId != _ownerId ||
        resetEpoch != _resetEpoch ||
        !_attemptPattern.hasMatch(attempt)) {
      throw const AppFailure(FailureCode.staleResult);
    }
    if (_records.values.any(
      (record) => record.state == _YoungState.provisional,
    )) {
      throw const AppFailure(FailureCode.busy);
    }

    final id =
        'yp-${List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    final ref = YoungPartitionRef(
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

    final record = _YoungRecord(ref, _YoungState.provisional);
    try {
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

  Future<void> claim(YoungPartitionRef ref, YoungClaimPermit permit) =>
      _exclusive(() async {
        _requireReady();
        _requireAuthority(ref);
        if (permit.accountId != 1 || !permit.partition.sameAs(ref)) {
          throw const AppFailure(FailureCode.staleResult);
        }
        final record = await _current(ref);
        if (record.state == _YoungState.deletePending) {
          throw const AppFailure(FailureCode.cleanupPending);
        }
        final profile = Directory(_path(ref.id, directory: true));
        if (!await profile.exists()) {
          throw const AppFailure(FailureCode.unsafeDirectory);
        }
        await _validateProfileMetadata(profile);
        if (record.state != _YoungState.claimed) {
          await _transition(record, _YoungState.claimed);
        }
      });

  Future<String> openClaimed(
    YoungClaimPermit permit, {
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
    if (record.state != _YoungState.claimed) {
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

  Future<void> markDeletePending(YoungPartitionRef ref) => _exclusive(() async {
    final record = await _current(ref);
    await _transition(record, _YoungState.deletePending);
  });

  /// The callback must stop and drain every native resource for this path.
  Future<void> clear(
    YoungPartitionRef ref,
    Future<void> Function(String profilePath) drain,
  ) => _exclusive(() async {
    final record = await _current(ref);
    await _transition(record, _YoungState.deletePending);
    await _delete(_records[ref.id]!, drain);
  });

  Future<List<YoungPartitionRef>> reconcile(
    List<YoungClaimPermit> permits, {
    required String ownerId,
    required int resetEpoch,
    required Future<void> Function(String profilePath) drain,
  }) => _exclusive(() async {
    _ready = false;
    YoungPartitionRef.decode(<String, dynamic>{
      'id': 'yp-00000000000000000000000000000000',
      'ownerId': ownerId,
      'purpose': YoungPartitionPurpose.initial.name,
      'attempt': 'young-0-0',
      'resetEpoch': resetEpoch,
    });
    owner.createPlainChildDirectory(_root);
    final records = await _scan();
    _records
      ..clear()
      ..addEntries(records.map((record) => MapEntry(record.ref.id, record)));

    // A durable deletion intention wins over every otherwise valid permit.
    for (final record in records.where(
      (record) => record.state == _YoungState.deletePending,
    )) {
      await _delete(record, drain);
    }

    for (final record in records.where(
      (record) => record.state != _YoungState.deletePending,
    )) {
      final valid =
          record.ref.ownerId == ownerId &&
          record.ref.resetEpoch == resetEpoch &&
          permits.any(
            (permit) =>
                permit.accountId == 1 && permit.partition.sameAs(record.ref),
          );
      final profile = Directory(_path(record.ref.id, directory: true));
      final exists = await profile.exists();
      if (!valid || !exists) {
        await _transition(record, _YoungState.deletePending);
        await _delete(_records[record.ref.id]!, drain);
      } else {
        await _validateProfileMetadata(profile);
        if (record.state != _YoungState.claimed) {
          await _transition(record, _YoungState.claimed);
        }
      }
    }

    _ownerId = ownerId;
    _resetEpoch = resetEpoch;
    _ready = true;
    return List<YoungPartitionRef>.unmodifiable(
      _records.values.map((record) => record.ref),
    );
  });

  Future<_YoungRecord> _read(String name, String id) async {
    final file = File(_path(name, directory: false));
    if (await file.length() > 2048) {
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic> ||
          value.length != 4 ||
          value['version'] != 1 ||
          value['purpose'] != 'young-partition-ledger' ||
          value['partition'] is! Map<String, dynamic> ||
          !_YoungState.values.any((state) => state.name == value['state'])) {
        throw const AppFailure(FailureCode.unsafeDirectory);
      }
      final ref = YoungPartitionRef.decode(
        value['partition'] as Map<String, dynamic>,
      );
      if (ref.id != id) throw const AppFailure(FailureCode.unsafeDirectory);
      return _YoungRecord(
        ref,
        _YoungState.values.singleWhere((state) => state.name == value['state']),
      );
    } on FormatException {
      throw const AppFailure(FailureCode.unsafeDirectory);
    } on AppFailure {
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
  }

  Future<_YoungRecord> _current(YoungPartitionRef ref) async {
    _ensureOpen();
    final expected = _known(ref);
    final record = await _read('${ref.id}.json', ref.id);
    if (!record.ref.sameAs(ref) || record.state != expected.state) {
      _ready = false;
      throw const AppFailure(FailureCode.unsafeDirectory);
    }
    return record;
  }

  Future<List<_YoungRecord>> _scan() async {
    final records = <String, _YoungRecord>{};
    final updates = <String, _YoungRecord>{};
    final registering = <String>{};
    final profiles = <String>{};
    final entries = await Directory(
      _path('.', directory: true),
    ).list(followLinks: false).toList();

    // Validate the full Young ledger before replaying or deleting anything.
    for (final entry in entries) {
      final name = p.windows.basename(entry.path);
      if (_idPattern.hasMatch(name)) {
        _path(name, directory: true);
        profiles.add(name);
      } else {
        final suffix = <String>[
          '.json',
          '.updating',
          '.registering',
        ].where(name.endsWith).firstOrNull;
        if (suffix == null) {
          throw const AppFailure(FailureCode.unsafeDirectory);
        }
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

  bool _allowed(_YoungState before, _YoungState after) =>
      before == after ||
      after == _YoungState.deletePending ||
      (before == _YoungState.provisional && after == _YoungState.claimed);

  Future<void> _writeStaging(String name, _YoungRecord record) async {
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

  Future<void> _transition(_YoungRecord before, _YoungState state) async {
    if (before.state == state) return;
    if (!_allowed(before.state, state)) {
      throw const AppFailure(FailureCode.cleanupPending);
    }
    final next = _YoungRecord(before.ref, state);
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
    _YoungRecord record,
    Future<void> Function(String profilePath) drain,
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

  Future<void> closeForMaintenanceExit() async {
    if (_closed) {
      return;
    }
    await _exclusive(() async {
      _closed = true;
    });
  }

  Future<void> close() async {
    if (_closed) return;
    await _exclusive(() async {
      if (_records.values.any(
            (record) => record.state != _YoungState.claimed,
          ) ||
          !_ready) {
        throw const AppFailure(FailureCode.cleanupPending);
      }
      _closed = true;
    });
  }
}

enum _YoungState { provisional, claimed, deletePending }

final class _YoungRecord {
  const _YoungRecord(this.ref, this.state);

  final YoungPartitionRef ref;
  final _YoungState state;

  Map<String, Object> get metadata => <String, Object>{
    'version': 1,
    'purpose': 'young-partition-ledger',
    'partition': ref.metadata,
    'state': state.name,
  };
}

final RegExp _attemptPattern = RegExp(r'^young-[0-9]+-[0-9]+$');
