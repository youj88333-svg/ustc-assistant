import 'contracts.dart';

/// Shared by synthetic jobs and pre-authentication observation sessions.
final class WorkLeasePool {
  Object? _owner;
  bool get isBusy => _owner != null;

  WorkLease acquire() {
    if (isBusy) throw const AppFailure(FailureCode.busy);
    final owner = Object();
    _owner = owner;
    return WorkLease._(this, owner);
  }
}

final class WorkLease {
  WorkLease._(this._pool, this._owner);
  final WorkLeasePool _pool;
  final Object _owner;
  bool get isHeld => identical(_pool._owner, _owner);
  bool belongsTo(WorkLeasePool pool) => identical(_pool, pool);
  void release() {
    if (isHeld) _pool._owner = null;
  }
}
