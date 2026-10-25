import 'package:drift/drift.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;

import '../core/contracts.dart';
import '../platform/android_directory.dart';
import '../platform/native_database.dart';
import '../platform/owned_directory.dart';

const _channelName = 'ustc_assistant/qa_owner_lifecycle_v1';
const _protocol = 'owner-lifecycle-v1';
const _sentinel = 17;
const _rootPath =
    r'^/data/(?:data|user/[0-9]+)/cn\.ustcassistant\.mobile\.qa/no_backup/ustc_assistant_v1/owner_lifecycle_test_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';

final MethodChannel _channel = MethodChannel(_channelName);

// The globals intentionally keep both directory leases and their database
// alive for the lifetime of this Dart isolate. Engine destruction must release
// the native owner without a Dart close call.
AndroidDirectories? _directories;
_OwnerLifecycleDatabase? _database;
bool _demoReleased = false;
bool _formalReleased = false;

@pragma('vm:entry-point')
Future<void> ownerLifecycleProbe() async {
  WidgetsFlutterBinding.ensureInitialized();
  _channel.setMethodCallHandler(_handleCall);
  await _channel.invokeMethod<void>('ready', const {'protocol': _protocol});
}

Future<Object?> _handleCall(MethodCall call) async {
  try {
    switch (call.method) {
      case 'acquire':
        return await _acquire(call.arguments);
      case 'commitSentinel':
        return await _commitSentinel();
      case 'readSentinel':
        return await _readSentinel();
      case 'releaseDemo':
        return await _releaseDemo();
      case 'releaseFormal':
        return await _releaseFormal();
      case 'close':
        return await _close();
      default:
        return const {'code': 'unknownOperation'};
    }
  } on AppFailure catch (error) {
    return <String, Object?>{
      'code': error.code == FailureCode.ownerConflict
          ? 'ownerConflict'
          : 'operationFailed',
    };
  } on Object {
    // Never forward exception text, database rows, filesystem paths, or other
    // implementation details through this QA-only channel.
    return const {'code': 'operationFailed'};
  }
}

Future<Map<String, Object?>> _acquire(Object? arguments) async {
  if (arguments is! String || !RegExp(_rootPath).hasMatch(arguments)) {
    return const {'code': 'invalidRequest'};
  }
  if (_directories != null) return const {'code': 'alreadyAcquired'};

  final directories = await AndroidDirectories.acquire(arguments);
  _directories = directories;
  _demoReleased = false;
  _formalReleased = false;
  return const {'code': 'acquired'};
}

Future<Map<String, Object?>> _commitSentinel() async {
  final directories = _directories;
  if (directories == null || _demoReleased || _formalReleased) {
    return const {'code': 'notAcquired'};
  }
  final database = _database ??= _OwnerLifecycleDatabase(
    openDemoDatabase(directories.demo),
    directories.demo,
  );
  await database.transaction(() async {
    directories.demo.ensureHeld();
    await database.customStatement(
      'INSERT OR REPLACE INTO owner_lifecycle_probe (singleton, sentinel) VALUES (1, ?)',
      const [_sentinel],
    );
    directories.demo.ensureHeld();
  });
  return const {'code': 'committed', 'sentinel': _sentinel};
}

Future<Map<String, Object?>> _readSentinel() async {
  final directories = _directories;
  if (directories == null || _demoReleased || _formalReleased) {
    return const {'code': 'notAcquired'};
  }
  final database = _database ??= _OwnerLifecycleDatabase(
    openDemoDatabase(directories.demo),
    directories.demo,
  );
  directories.demo.ensureHeld();
  final row = await database
      .customSelect(
        'SELECT sentinel FROM owner_lifecycle_probe WHERE singleton = 1',
      )
      .getSingleOrNull();
  directories.demo.ensureHeld();
  if (row == null || row.read<int>('sentinel') != _sentinel) {
    return const {'code': 'sentinelMismatch', 'sentinel': -1};
  }
  return const {'code': 'read', 'sentinel': _sentinel};
}

Future<Map<String, Object?>> _releaseDemo() async {
  final directories = _directories;
  if (directories == null || _formalReleased) {
    return const {'code': 'notAcquired'};
  }
  if (_database != null) {
    await _database!.close();
    _database = null;
  }
  if (!_demoReleased) {
    await directories.demo.release();
    _demoReleased = true;
  }
  return const {'code': 'demoReleased'};
}

Future<Map<String, Object?>> _releaseFormal() async {
  final directories = _directories;
  if (directories == null || !_demoReleased || _database != null) {
    return const {'code': 'invalidReleaseOrder'};
  }
  if (!_formalReleased) {
    await directories.formal.release();
    _formalReleased = true;
  }
  _clearReleasedState();
  return const {'code': 'formalReleased'};
}

Future<Map<String, Object?>> _close() async {
  final directories = _directories;
  if (directories == null) return const {'code': 'closed'};

  if (_database != null) {
    await _database!.close();
    _database = null;
  }
  if (!_demoReleased) {
    await directories.demo.release();
    _demoReleased = true;
  }
  if (!_formalReleased) {
    await directories.formal.release();
    _formalReleased = true;
  }
  _clearReleasedState();
  return const {'code': 'closed'};
}

void _clearReleasedState() {
  _directories = null;
  _database = null;
  _demoReleased = false;
  _formalReleased = false;
}

final class _OwnerLifecycleDatabase extends GeneratedDatabase {
  _OwnerLifecycleDatabase(super.executor, this._ownership);

  final OwnedDirectory _ownership;

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      _ownership.ensureHeld();
      await customStatement(
        'CREATE TABLE owner_lifecycle_probe ('
        'singleton INTEGER PRIMARY KEY CHECK (singleton = 1), '
        'sentinel INTEGER NOT NULL)',
      );
      _ownership.ensureHeld();
    },
    onUpgrade: (_, _, _) async =>
        throw const AppFailure(FailureCode.storageFailed),
  );
}
