import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

import 'demo_directory.dart';

QueryExecutor openDemoDatabase(DemoDirectory directory) =>
    _openOwnedDatabase(directory, 'm0_demo.sqlite');
QueryExecutor openJwDatabase(DemoDirectory directory) =>
    _openOwnedDatabase(directory, 'jw.sqlite');

QueryExecutor _openOwnedDatabase(DemoDirectory directory, String filename) {
  directory.ensureDatabaseFilesSafe(filename: filename);
  return NativeDatabase(
    File(p.windows.join(directory.path, filename)),
    logStatements: false,
    setup: (database) {
      directory.ensureDatabaseFilesSafe(filename: filename);
      database.execute('PRAGMA foreign_keys = ON');
      database.execute('PRAGMA journal_mode = WAL');
      database.execute('PRAGMA synchronous = FULL');
      database.execute('PRAGMA busy_timeout = 3000');
    },
  ).interceptWith(_OwnershipGuard(directory, filename));
}

/// Guards lazy opening as well as statements on existing connections. Closing
/// and rolling back remain possible after ownership loss to drain resources.
final class _OwnershipGuard extends QueryInterceptor {
  _OwnershipGuard(this.directory, this.filename);
  final DemoDirectory directory;
  final String filename;

  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) {
    directory.ensureDatabaseFilesSafe(filename: filename);
    return executor.ensureOpen(user);
  }

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    directory.ensureHeld();
    return parent.beginTransaction();
  }

  @override
  QueryExecutor beginExclusive(QueryExecutor parent) {
    directory.ensureHeld();
    return parent.beginExclusive();
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) {
    directory.ensureHeld();
    return inner.send();
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) {
    directory.ensureHeld();
    return executor.runBatched(statements);
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    directory.ensureHeld();
    return executor.runCustom(statement, args);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    directory.ensureHeld();
    return executor.runInsert(statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    directory.ensureHeld();
    return executor.runUpdate(statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    directory.ensureHeld();
    return executor.runDelete(statement, args);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    directory.ensureHeld();
    return executor.runSelect(statement, args);
  }
}
