import 'dart:async';

import '../core/reminder_contract.dart';
import '../core/speech_input_contract.dart';

/// Explicit placeholder for system notifications before the Android adapter
/// is integrated. It never claims that the operating system has no reminders.
final class UnavailableMobileNotifications implements NotificationPlatformPort {
  bool _closed = false;
  Future<void>? _closeFuture;

  @override
  Stream<NotificationActivation> get activations =>
      const Stream<NotificationActivation>.empty();

  @override
  Future<NotificationCapability> initialize() async {
    _ensureOpen();
    return const NotificationCapability(
      available: false,
      enabledBySystem: false,
      schedulesAfterExit: false,
      activationAvailable: false,
    );
  }

  @override
  Future<List<NotificationPending>> pending() async {
    _ensureOpen();
    throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
  }

  @override
  Future<void> schedule(NotificationRequest request) async {
    _ensureOpen();
    throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
  }

  @override
  Future<void> cancel(String id) async {
    _ensureOpen();
    throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
  }

  @override
  Future<void> clearOwn() async {
    _ensureOpen();
    throw const ReminderFailure(ReminderFailureCode.platformUnavailable);
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
  }

  void _ensureOpen() {
    if (_closed) {
      throw const ReminderFailure(ReminderFailureCode.closed);
    }
  }
}

/// Explicit placeholder for local speech input before Android recording and
/// model support are integrated. It never requests permission or captures audio.
final class UnavailableMobileSpeechInput implements SpeechInputPort {
  final StreamController<SpeechInputView> _changes =
      StreamController<SpeechInputView>.broadcast();
  SpeechInputView _view = const SpeechInputView();
  Future<void>? _closeFuture;

  @override
  SpeechInputView get view => _view;

  @override
  Stream<SpeechInputView> get changes => _changes.stream;

  @override
  Future<void> start() async {
    _ensureOpen();
    _publish(
      SpeechInputView(
        phase: SpeechInputPhase.idle,
        revision: _view.revision + 1,
        failure: SpeechInputFailureCode.unsupportedPlatform,
      ),
    );
  }

  @override
  Future<void> finish() async {
    _ensureOpen();
  }

  @override
  Future<void> cancel() async {
    if (_isClosed ||
        (_view.phase == SpeechInputPhase.idle &&
            _view.failure == null &&
            _view.transcript == null)) {
      return;
    }
    _publish(SpeechInputView(revision: _view.revision));
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_isClosed) return;
    _publish(
      SpeechInputView(phase: SpeechInputPhase.closed, revision: _view.revision),
    );
    await _changes.close();
  }

  bool get _isClosed => _view.phase == SpeechInputPhase.closed;

  void _ensureOpen() {
    if (_isClosed) {
      throw const SpeechInputFailure(SpeechInputFailureCode.closed);
    }
  }

  void _publish(SpeechInputView view) {
    _view = view;
    if (!_changes.isClosed) _changes.add(view);
  }
}
