import 'dart:async';

import 'package:flutter/foundation.dart';

import '../features/settings/application/minimal_reset_coordinator.dart';

/// Coarse application phases that are safe to render at the route boundary.
///
/// The app root owns this state. Pages may request a visible login/collection
/// phase, but they never own the runtime or reset coordinator that drives the
/// terminal recovery phases.
enum MinimalAppPhase {
  preparing,
  unconfigured,
  loginVisible,
  collecting,
  configured,
  resetting,
  resetFailed,
}

final class MinimalAppViewState {
  const MinimalAppViewState({required this.phase, this.safeCode});

  final MinimalAppPhase phase;
  final String? safeCode;

  @override
  bool operator ==(Object other) =>
      other is MinimalAppViewState &&
      other.phase == phase &&
      other.safeCode == safeCode;

  @override
  int get hashCode => Object.hash(phase, safeCode);
}

/// App-root state bridge for route recovery and account visibility.
///
/// The reset coordinator's stream is broadcast and non-replaying, so attaching
/// always reads [MinimalResetCoordinator.phase] first, then subscribes to the
/// same coordinator. This makes a late route observe an already-failed reset.
final class MinimalAppStateController extends ChangeNotifier {
  MinimalAppStateController({
    MinimalAppViewState initial = const MinimalAppViewState(
      phase: MinimalAppPhase.preparing,
    ),
  }) : _viewState = initial;

  static const resetFailedCode = 'reset_failed';

  MinimalAppViewState _viewState;
  StreamSubscription<MinimalResetPhase>? _resetSubscription;
  MinimalResetPhase? _lastResetPhase;
  bool _accountKnown = false;
  bool _hasAccount = false;
  MinimalAppPhase? _requestedContentPhase;
  bool _disposed = false;

  MinimalAppViewState get viewState => _viewState;

  MinimalAppPhase get phase => _viewState.phase;

  String? get safeCode => _viewState.safeCode;

  bool get hasKnownAccount => _accountKnown;

  bool get hasAccount => _hasAccount;

  /// Binds the retained app-owned coordinator. Rebinding the same coordinator
  /// is a no-op; a replacement is detached before the new initial snapshot is
  /// read, without closing the borrowed coordinator itself.
  void attachResetCoordinator(MinimalResetCoordinator coordinator) {
    if (_disposed) return;
    if (_resetSubscription != null && _lastResetCoordinator == coordinator) {
      return;
    }
    unawaited(_resetSubscription?.cancel());
    _resetSubscription = null;
    _lastResetCoordinator = coordinator;
    final initialPhase = coordinator.phase;
    _lastResetPhase = initialPhase;
    _applyResetPhase(initialPhase);
    // Cancelling a broadcast subscription is asynchronous. Guard callbacks
    // by coordinator identity so an event already queued by a retired
    // coordinator cannot reopen or overwrite the replacement state.
    _resetSubscription = coordinator.phases.listen((phase) {
      if (identical(_lastResetCoordinator, coordinator)) {
        _applyResetPhase(phase);
      }
    });
  }

  MinimalResetCoordinator? _lastResetCoordinator;

  /// Updates the app-owned account snapshot. Active reset phases take
  /// precedence so a database-clearing notification cannot reopen writers.
  void setAccountConfigured(bool configured) {
    if (_disposed) return;
    _accountKnown = true;
    _hasAccount = configured;
    if (_isResetBlocked) return;
    final requested = _requestedContentPhase;
    if (requested == MinimalAppPhase.loginVisible ||
        requested == MinimalAppPhase.collecting) {
      _setState(MinimalAppViewState(phase: requested!));
      return;
    }
    _setContentState();
  }

  /// Explicitly returns the shell to the no-account state after a completed
  /// reset or when a route has observed an empty account partition.
  void showUnconfigured() {
    if (_disposed || _isResetBlocked) return;
    _accountKnown = true;
    _hasAccount = false;
    _requestedContentPhase = null;
    _setState(const MinimalAppViewState(phase: MinimalAppPhase.unconfigured));
  }

  /// Publishes the successful terminal state for an embedded host that uses
  /// the direct settings fallback instead of a [MinimalResetCoordinator].
  /// The retained-coordinator path reaches this state from its idle phase and
  /// never needs to bypass the maintenance guard.
  void showUnconfiguredAfterReset() {
    if (_disposed) return;
    _accountKnown = true;
    _hasAccount = false;
    _requestedContentPhase = null;
    _setState(const MinimalAppViewState(phase: MinimalAppPhase.unconfigured));
  }

  void showConfigured() {
    if (_disposed || _isResetBlocked) return;
    _accountKnown = true;
    _hasAccount = true;
    _requestedContentPhase = null;
    _setState(const MinimalAppViewState(phase: MinimalAppPhase.configured));
  }

  void showLoginVisible() {
    if (_disposed || _isResetBlocked) return;
    _requestedContentPhase = MinimalAppPhase.loginVisible;
    _setState(const MinimalAppViewState(phase: MinimalAppPhase.loginVisible));
  }

  void beginCollecting() {
    if (_disposed || _isResetBlocked) return;
    _requestedContentPhase = MinimalAppPhase.collecting;
    _setState(const MinimalAppViewState(phase: MinimalAppPhase.collecting));
  }

  /// Enters the same fail-closed route when composing the retained reset
  /// boundary itself fails before it can publish a coordinator phase. The
  /// route only exposes the stable code; retry may attempt composition again.
  void markResetFailed() {
    if (_disposed) return;
    _setState(
      const MinimalAppViewState(
        phase: MinimalAppPhase.resetFailed,
        safeCode: resetFailedCode,
      ),
    );
  }

  bool get _isResetBlocked =>
      _viewState.phase == MinimalAppPhase.resetting ||
      _viewState.phase == MinimalAppPhase.resetFailed;

  void _applyResetPhase(MinimalResetPhase phase) {
    if (_disposed) return;
    final previous = _lastResetPhase;
    _lastResetPhase = phase;
    switch (phase) {
      case MinimalResetPhase.quiescing:
      case MinimalResetPhase.clearingDatabase:
      case MinimalResetPhase.clearingBrowser:
        _setState(const MinimalAppViewState(phase: MinimalAppPhase.resetting));
      case MinimalResetPhase.failed:
        _setState(
          const MinimalAppViewState(
            phase: MinimalAppPhase.resetFailed,
            safeCode: resetFailedCode,
          ),
        );
      case MinimalResetPhase.idle:
        // A transition from any maintenance phase to idle is the successful
        // reset boundary. Always expose exactly one fresh unconfigured state;
        // the account-change stream may arrive before or after this event.
        if (previous != null && previous != MinimalResetPhase.idle) {
          _accountKnown = true;
          _hasAccount = false;
          _requestedContentPhase = null;
          _setState(
            const MinimalAppViewState(phase: MinimalAppPhase.unconfigured),
          );
        } else {
          _setContentState();
        }
    }
  }

  void _setContentState() {
    if (_disposed || _isResetBlocked) return;
    final phase = _accountKnown && _hasAccount
        ? MinimalAppPhase.configured
        : MinimalAppPhase.unconfigured;
    _setState(MinimalAppViewState(phase: phase));
  }

  void _setState(MinimalAppViewState next) {
    if (_disposed || next == _viewState) return;
    _viewState = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_resetSubscription?.cancel());
    _resetSubscription = null;
    _lastResetCoordinator = null;
    super.dispose();
  }
}
