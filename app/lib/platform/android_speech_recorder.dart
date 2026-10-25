import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../core/speech_input_contract.dart';
import 'speech_audio_recorder.dart';

/// Android permission and foreground gate for short, user-started dictation.
///
/// The plugin is still created lazily by [SpeechAudioRecorder]. A successful
/// permission result is usable only while the app remains in the foreground;
/// after any lifecycle loss, a later explicit permission preflight is needed.
final class AndroidSpeechRecorder
    with WidgetsBindingObserver
    implements SpeechRecorderPort {
  AndroidSpeechRecorder({
    SpeechAudioRecorderBackendFactory? backendFactory,
    this.permissionResumeTimeout = const Duration(seconds: 5),
  }) : _recorder = SpeechAudioRecorder(
         backendFactory: backendFactory,
         inputDeviceResolver: () async => null,
         cancelOnInterruption: true,
         androidManageBluetooth: false,
       );

  final SpeechAudioRecorder _recorder;
  final Duration permissionResumeTimeout;

  WidgetsBinding? _binding;
  AppLifecycleState? _lifecycleState;
  Completer<bool>? _resumeWaiter;
  Future<bool>? _permissionOperation;
  Future<void>? _closeOperation;
  bool _permissionGranted = false;
  bool _permissionAttemptAborted = false;
  int _lifecycleEpoch = 0;
  bool _closing = false;
  bool _closed = false;

  @override
  Future<bool> hasPermission() {
    if (_closed || _closing) {
      return Future<bool>.error(
        const SpeechInputFailure(SpeechInputFailureCode.closed),
      );
    }
    _attachLifecycleObserver();
    if (_permissionGranted && _isResumed) return Future<bool>.value(true);

    final existing = _permissionOperation;
    if (existing != null) return existing;

    final operation = _requestPermission();
    _permissionOperation = operation;
    return operation.whenComplete(() {
      if (identical(_permissionOperation, operation)) {
        _permissionOperation = null;
      }
    });
  }

  Future<bool> _requestPermission() async {
    _permissionGranted = false;
    _permissionAttemptAborted = false;
    if (!_isResumed) return false;

    final granted = await _recorder.hasPermission();
    if (!granted || _permissionAttemptAborted || _closing || _closed) {
      return false;
    }

    if (!_isResumed && !await _waitForPermissionReturn()) return false;
    if (_permissionAttemptAborted || !_isResumed || _closing || _closed) {
      return false;
    }

    _permissionGranted = true;
    return true;
  }

  Future<bool> _waitForPermissionReturn() async {
    // Only the permission dialog's temporary inactive state may be awaited.
    if (_lifecycleState != AppLifecycleState.inactive ||
        _permissionAttemptAborted) {
      return false;
    }

    final waiter = Completer<bool>();
    _resumeWaiter = waiter;
    final timer = Timer(permissionResumeTimeout, () {
      if (!waiter.isCompleted) waiter.complete(false);
    });
    try {
      return await waiter.future;
    } finally {
      timer.cancel();
      if (identical(_resumeWaiter, waiter)) _resumeWaiter = null;
    }
  }

  void _attachLifecycleObserver() {
    if (_binding != null) return;
    final binding = WidgetsBinding.instance;
    _binding = binding;
    _lifecycleState = binding.lifecycleState;
    binding.addObserver(this);
  }

  bool get _isResumed => _lifecycleState == AppLifecycleState.resumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state != AppLifecycleState.resumed) {
      _lifecycleEpoch++;
      // The caller must explicitly revalidate permission after returning.
      _permissionGranted = false;
    }

    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _permissionAttemptAborted = true;
      final waiter = _resumeWaiter;
      if (waiter != null && !waiter.isCompleted) waiter.complete(false);
    } else if (state == AppLifecycleState.resumed) {
      final waiter = _resumeWaiter;
      if (waiter != null && !waiter.isCompleted) waiter.complete(true);
    }
  }

  @override
  Future<Stream<Uint8List>> start() async {
    if (_closed || _closing) {
      throw const SpeechInputFailure(SpeechInputFailureCode.closed);
    }
    _attachLifecycleObserver();
    if (_permissionOperation != null) {
      throw const SpeechInputFailure(SpeechInputFailureCode.busy);
    }
    if (!_permissionGranted) {
      throw const SpeechInputFailure(SpeechInputFailureCode.permissionDenied);
    }
    if (!_isResumed) {
      _permissionGranted = false;
      throw const SpeechInputFailure(
        SpeechInputFailureCode.microphoneUnavailable,
      );
    }

    final lifecycleEpochBeforeStart = _lifecycleEpoch;
    final stream = await _recorder.start();
    if (_closed ||
        _closing ||
        !_permissionGranted ||
        !_isResumed ||
        lifecycleEpochBeforeStart != _lifecycleEpoch) {
      await _recorder.stop();
      throw const SpeechInputFailure(
        SpeechInputFailureCode.microphoneUnavailable,
      );
    }
    return stream;
  }

  @override
  Future<void> stop() => _recorder.stop();

  @override
  Future<void> close() {
    if (_closed) return Future<void>.value();
    final existing = _closeOperation;
    if (existing != null) return existing;

    _closing = true;
    final waiter = _resumeWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete(false);
    late final Future<void> operation;
    operation = _closeRecorder()
        .then((_) {
          _binding?.removeObserver(this);
          _binding = null;
          _closed = true;
        })
        .whenComplete(() {
          if (identical(_closeOperation, operation)) _closeOperation = null;
          if (!_closed) _closing = false;
        });
    _closeOperation = operation;
    return operation;
  }

  Future<void> _closeRecorder() => _recorder.close();
}
