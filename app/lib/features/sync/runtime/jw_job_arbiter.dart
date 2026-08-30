import '../data/bridge_client.dart';

enum JwJobKind { firstLogin, sync, pythonFallback, maintenance }

final class JwJobLease {
  JwJobLease._({required this.jobId, required this.kind});

  final String jobId;
  final JwJobKind kind;
  var _released = false;
}

final class JwJobArbiter {
  JwJobLease? _held;

  bool get isBusy => _held != null;

  JwJobLease acquire({required String jobId, required JwJobKind kind}) {
    if (jobId.isEmpty) throw StateError('job id is empty');
    if (_held != null) throw const BridgeProtocolError('bridge_busy');
    return _held = JwJobLease._(jobId: jobId, kind: kind);
  }

  void release(JwJobLease lease) {
    if (lease._released) return;
    if (!identical(_held, lease)) throw StateError('foreign lease');
    lease._released = true;
    _held = null;
  }
}
