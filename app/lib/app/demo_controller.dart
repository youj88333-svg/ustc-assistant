import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/contracts.dart';
import '../data/import_contract.dart';
import '../jobs/coordinator_contract.dart';
import '../source/source_contract.dart';

/// Presentation state and actions for the local synthetic M0 demonstration.
///
/// The controller owns only its stream subscription and display state. The
/// coordinator and data store belong to the composition root.
final class DemoController extends ChangeNotifier {
  DemoController({required this.coordinator, required this.data})
    : _view = coordinator.view;

  final CoordinatorPort coordinator;
  final DemoReadPort data;

  CoordinatorView _view;
  DemoDataView? _dataView;
  FailureCode? _actionError;
  FailureCode? _readError;
  CancellationDisposition? _cancellationDisposition;
  StreamSubscription<CoordinatorView>? _subscription;
  bool _initialized = false;
  bool _disposed = false;
  bool _refreshLoading = false;
  bool _operationInFlight = false;
  bool _cancelInFlight = false;
  int _readRevision = 0;

  CoordinatorView get view => _view;
  DemoDataView? get dataView => _dataView;
  FailureCode? get error => _actionError ?? _readError;
  bool get loading => _refreshLoading || _operationInFlight || _cancelInFlight;
  CancellationDisposition? get cancellationDisposition =>
      _cancellationDisposition;

  Future<void> initialize() async {
    if (_disposed || _initialized) return;
    _initialized = true;
    _view = coordinator.view;
    _subscription = coordinator.changes.listen(
      _onCoordinatorView,
      onError: (Object _) {
        if (_disposed) return;
        _actionError = FailureCode.storageFailed;
        notifyListeners();
      },
    );
    notifyListeners();
    await _refreshDataView();
  }

  Future<void> run(DemoScenario scenario) async {
    if (_disposed ||
        _operationInFlight ||
        _view.phase != JobPhase.idle ||
        (scenario == DemoScenario.replay &&
            (_dataView?.importCount ?? 0) == 0)) {
      return;
    }

    _operationInFlight = true;
    _actionError = null;
    _cancellationDisposition = null;
    notifyListeners();
    try {
      final outcome = await coordinator.run(scenario);
      if (_disposed) return;
      _acceptOutcome(outcome);
    } catch (failure) {
      if (!_disposed) _actionError = _failureCode(failure);
    } finally {
      if (!_disposed) {
        await _refreshDataView();
        if (!_disposed) {
          _operationInFlight = false;
          notifyListeners();
        }
      }
    }
  }

  Future<void> cancel() async {
    if (_disposed ||
        _cancelInFlight ||
        (_view.phase != JobPhase.collecting &&
            _view.phase != JobPhase.settling) ||
        _view.cancelRequested) {
      return;
    }

    _cancelInFlight = true;
    _actionError = null;
    notifyListeners();
    try {
      _cancellationDisposition = await coordinator.cancel();
    } catch (failure) {
      if (!_disposed) _actionError = _failureCode(failure);
    } finally {
      if (!_disposed) {
        await _refreshDataView();
        if (!_disposed) {
          _cancelInFlight = false;
          notifyListeners();
        }
      }
    }
  }

  Future<void> retryRecovery() async {
    if (_disposed || _operationInFlight || _view.phase != JobPhase.recovery) {
      return;
    }

    _operationInFlight = true;
    _actionError = null;
    notifyListeners();
    try {
      final outcome = await coordinator.retryRecovery();
      if (_disposed) return;
      _acceptOutcome(outcome);
    } catch (failure) {
      if (!_disposed) {
        _actionError = failure is AppFailure
            ? failure.code
            : FailureCode.cleanupPending;
      }
    } finally {
      if (!_disposed) {
        await _refreshDataView();
        if (!_disposed) {
          _operationInFlight = false;
          notifyListeners();
        }
      }
    }
  }

  Future<void> retryFollowUps() async {
    if (_disposed ||
        _operationInFlight ||
        _view.phase != JobPhase.idle ||
        (_dataView?.pendingFollowUps ?? 0) == 0) {
      return;
    }

    _operationInFlight = true;
    _actionError = null;
    notifyListeners();
    try {
      await coordinator.retryFollowUps();
    } catch (failure) {
      if (!_disposed) {
        _actionError = failure is AppFailure
            ? failure.code
            : FailureCode.followUpPending;
      }
    } finally {
      if (!_disposed) {
        await _refreshDataView();
        if (!_disposed) {
          _operationInFlight = false;
          notifyListeners();
        }
      }
    }
  }

  void _onCoordinatorView(CoordinatorView next) {
    if (_disposed) return;
    final previous = _view;
    _view = next;

    final isTerminal =
        next.phase == JobPhase.idle ||
        next.phase == JobPhase.recovery ||
        next.phase == JobPhase.closed;
    if (isTerminal && next.outcome != null) {
      _acceptOutcome(next.outcome!);
    }

    final enteredRefreshableState =
        next.phase != previous.phase &&
        (next.phase == JobPhase.idle || next.phase == JobPhase.recovery);
    final changedOutcome =
        next.outcome != null &&
        !identical(next.outcome, previous.outcome) &&
        isTerminal;
    notifyListeners();
    if (enteredRefreshableState || changedOutcome) {
      unawaited(_refreshDataView());
    }
  }

  void _acceptOutcome(JobOutcome outcome) {
    switch (outcome.kind) {
      case OutcomeKind.committed:
        _actionError = outcome.followUpPending
            ? FailureCode.followUpPending
            : null;
        break;
      case OutcomeKind.cancelled:
        _actionError = outcome.failure;
        break;
      case OutcomeKind.failed:
        _actionError = outcome.failure ?? FailureCode.storageFailed;
        break;
    }
  }

  Future<void> _refreshDataView() async {
    if (_disposed) return;
    final revision = ++_readRevision;
    _refreshLoading = true;
    notifyListeners();
    try {
      final next = await data.readView();
      if (_disposed || revision != _readRevision) return;
      _dataView = next;
      _readError = null;
    } catch (failure) {
      if (_disposed || revision != _readRevision) return;
      _readError = _failureCode(failure);
    } finally {
      if (!_disposed && revision == _readRevision) {
        _refreshLoading = false;
        notifyListeners();
      }
    }
  }

  FailureCode _failureCode(Object failure) =>
      failure is AppFailure ? failure.code : FailureCode.storageFailed;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_readRevision;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    super.dispose();
  }
}
