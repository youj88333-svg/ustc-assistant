import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/onboarding_contract.dart';

/// C5 only: durable navigation is not a source result or consent store.
final class OnboardingController extends ChangeNotifier {
  OnboardingController(this._data) {
    _subscription = _data.changes.listen((_) {
      if (!_pending) unawaited(refresh());
    }, onError: (Object _) => _failed());
    scheduleMicrotask(refresh);
  }
  final OnboardingDataPort _data;
  StreamSubscription<int>? _subscription;
  OnboardingSnapshot? _snapshot;
  bool _loading = true, _pending = false, _failure = false, _disposed = false;
  int _generation = 0;

  OnboardingSnapshot? get snapshot => _snapshot;
  bool get loading => _loading;
  bool get pending => _pending;
  bool get failure => _failure;
  bool get active => _snapshot?.status == OnboardingStatus.active;
  bool get blocksAutomatic => _loading || _pending || _failure || active;
  bool get showSetup => _loading || _failure || active;

  void _failed() {
    if (_disposed) return;
    _loading = false;
    _failure = true;
    notifyListeners();
  }

  Future<void> refresh() async {
    if (_disposed || _pending) return;
    final generation = ++_generation;
    try {
      final next = await _data.inspect();
      if (_disposed || generation != _generation) return;
      _snapshot = next;
      _loading = false;
      _failure = false;
      notifyListeners();
    } on Object {
      if (!_disposed && generation == _generation) _failed();
    }
  }

  Future<bool> navigate(OnboardingStep step) =>
      _save(OnboardingStatus.active, step);
  Future<bool> defer() => _save(OnboardingStatus.deferred, _snapshot?.step);
  Future<bool> complete() =>
      _save(OnboardingStatus.done, OnboardingStep.permissions);
  Future<bool> reopen() => _save(
    OnboardingStatus.active,
    _snapshot?.status == OnboardingStatus.done
        ? OnboardingStep.account
        : _snapshot?.step,
  );

  Future<bool> _save(OnboardingStatus status, OnboardingStep? step) async {
    final current = _snapshot;
    if (_disposed || _loading || _pending || current == null || step == null) {
      return false;
    }
    final generation = ++_generation;
    _pending = true;
    _failure = false;
    notifyListeners();
    try {
      final next = await _data.save(
        current.context,
        status: status,
        step: step,
      );
      if (_disposed || generation != _generation) return false;
      _snapshot = next;
      return true;
    } on Object {
      if (!_disposed && generation == _generation) _failure = true;
      return false;
    } finally {
      if (!_disposed && generation == _generation) {
        _pending = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
