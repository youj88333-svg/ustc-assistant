import 'dart:convert';
import 'dart:math';

import '../core/contracts.dart';
import '../core/diagnostics_contract.dart';

/// Startup fallback before safe directory access: no filesystem operations.
/// The explicit coverage prevents presenting this as retained application logs.
final class TransientDiagnostics implements DiagnosticsPort {
  TransientDiagnostics({
    this.versions = const DiagnosticVersions(),
    this.clock = const SystemClock(),
  });
  final DiagnosticVersions versions;
  final AppClock clock;
  final List<DiagnosticRecord> _records = [];
  int _invalid = 0, _dropped = 0, _sequence = 0;
  bool _closed = false;
  @override
  DiagnosticsView get diagnosticsView => DiagnosticsView(
    available: !_closed,
    invalid: _invalid,
    dropped: _dropped,
  );
  @override
  DiagnosticTrace newTrace() => DiagnosticTrace(
    List.generate(
      16,
      (_) => Random.secure().nextInt(256),
    ).map((v) => v.toRadixString(16).padLeft(2, '0')).join(),
  );
  @override
  void record(DiagnosticEvent event) {
    if (_closed || _records.length >= diagnosticQueueLimit) {
      _dropped++;
      return;
    }
    try {
      final record = DiagnosticRecord(
        atUtc: clock.nowUtc.toUtc(),
        event: event,
        sequence: _sequence++,
        versions: versions,
      );
      record.encode();
      _records.add(record);
    } catch (_) {
      _invalid++;
    }
  }

  @override
  Future<void> flush() async {}
  @override
  Future<String> exportRecent() async {
    if (_closed) throw const DiagnosticsFailure(DiagnosticsFailureCode.closed);
    return jsonEncode({
      'kind': 'ustc-diagnostics-export-v1',
      'exportedAtUtc': clock.nowUtc.toUtc().toIso8601String(),
      'retentionDays': diagnosticRetentionDays,
      'versions': versions.toSafeMap(),
      'coverage': 'startup_error_only',
      'selectionTruncated': false,
      'complete': false,
      'dropped': _dropped,
      'invalid': _invalid,
      'records': _records.map((r) => r.toMap()).toList(),
    });
  }

  @override
  Future<void> clear() async {
    _records.clear();
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}
