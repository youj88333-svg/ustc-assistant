import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/agenda_contract.dart';
import '../core/contracts.dart';
import '../data/agenda_projection.dart';
import '../data/jw_import_contract.dart';
import '../jobs/jw_sync_port.dart';
import '../jobs/young_sync_port.dart';
import 'app_shell_contract.dart';

/// Owns only presentation subscriptions. The composition root retains every
/// source, database, resource and shutdown responsibility.
final class AppShellController extends ChangeNotifier implements AppShellPort {
  AppShellController({
    required this.jw,
    required this.young,
    this.clock = const SystemClock(),
    this.isGloballyBusy,
    List<Stream<Object?>> extraChanges = const [],
  }) {
    _watch(jw.syncChanges);
    _watch(young.syncChanges);
    for (final stream in extraChanges) {
      _watch(stream);
    }
  }

  @override
  final JwSyncPort jw;
  @override
  final YoungSyncPort young;
  final AppClock clock;
  final bool Function()? isGloballyBusy;
  final _subscriptions = <StreamSubscription<Object?>>[];
  bool _disposed = false;
  bool _pending = false;
  bool _progressUnavailable = false;
  FailureCode? _failure;

  void _watch(Stream<Object?> stream) {
    _subscriptions.add(
      stream.listen(
        (_) => _notify(),
        onError: (Object _, StackTrace _) {
          _progressUnavailable = true;
          _notify();
        },
        onDone: () {
          if (_disposed) return;
          _progressUnavailable = true;
          _notify();
        },
      ),
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  AppShellView get view => AppShellView(
    jw: jw.syncView,
    young: young.syncView,
    globallyBusy:
        jw.syncView.busy ||
        young.syncView.busy ||
        (isGloballyBusy?.call() ?? false),
    actionPending: _pending,
    actionFailure: _failure,
    progressUnavailable: _progressUnavailable,
  );

  @override
  DateTime get today => beijingDay(clock.nowUtc);

  @override
  AgendaSlice readAgenda({
    required DateTime day,
    AgendaFilter filter = AgendaFilter.all,
    bool includeHidden = false,
  }) => const AgendaProjection().query(
    day: day,
    jw: jw.syncView.data,
    young: young.syncView.data,
    filter: filter,
    includeHidden: includeHidden,
  );

  @override
  Future<void> setHidden(
    AgendaReference reference, {
    required bool hidden,
  }) async {
    if (_disposed) throw const AppFailure(FailureCode.closed);
    if (_pending || view.globallyBusy) {
      throw const AppFailure(FailureCode.busy);
    }
    if (_progressUnavailable) {
      throw const AppFailure(FailureCode.storageFailed);
    }
    // Reject a stale display handle before delegating; C3 still performs the
    // authoritative account, epoch, version and transaction checks.
    final current = switch (reference.source) {
      AgendaSource.course || AgendaSource.exam =>
        jw.syncView.data?.events.any(
              (event) =>
                  event.localId == reference.localId &&
                  event.version == reference.version &&
                  (event.kind == JwEventKind.course
                          ? AgendaSource.course
                          : AgendaSource.exam) ==
                      reference.source,
            ) ??
            false,
      AgendaSource.young =>
        young.syncView.data?.events.any(
              (event) =>
                  event.localId == reference.localId &&
                  event.version == reference.version,
            ) ??
            false,
    };
    if (!current) throw const AppFailure(FailureCode.staleResult);
    _pending = true;
    _failure = null;
    _notify();
    try {
      switch (reference.source) {
        case AgendaSource.course:
        case AgendaSource.exam:
          await jw.setHidden(
            localId: reference.localId,
            expectedVersion: reference.version,
            hidden: hidden,
          );
          break;
        case AgendaSource.young:
          await young.setHidden(
            localId: reference.localId,
            expectedVersion: reference.version,
            hidden: hidden,
          );
          break;
      }
    } catch (error) {
      final code = error is AppFailure ? error.code : FailureCode.storageFailed;
      if (!_disposed) _failure = code;
      throw AppFailure(code);
    } finally {
      _pending = false;
      _notify();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }
}
