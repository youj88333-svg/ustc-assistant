import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../core/speech_input_contract.dart';

/// Narrow seam for the pinned recorder plugin. Tests inject a synthetic backend
/// so they never construct a platform recorder or open a microphone.
abstract interface class SpeechAudioRecorderBackend {
  Future<bool> hasPermission({required bool request});
  Future<Stream<Uint8List>> startStream(RecordConfig config);
  Future<void> stop();
  Future<void> dispose();
}

typedef SpeechAudioRecorderBackendFactory =
    SpeechAudioRecorderBackend Function();

/// Adapts record's in-memory stream API to the app's fixed PCM contract.
///
/// Constructing this port does not create a plugin recorder. The recorder is
/// created on the first explicit permission check or start call.
final class SpeechAudioRecorder implements SpeechRecorderPort {
  SpeechAudioRecorder({SpeechAudioRecorderBackendFactory? backendFactory})
    : _backendFactory = backendFactory ?? _RecordBackend.new;

  static const RecordConfig _recordConfig = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: speechSampleRate,
    numChannels: 1,
  );

  final SpeechAudioRecorderBackendFactory _backendFactory;
  SpeechAudioRecorderBackend? _backend;
  Future<bool>? _permissionOperation;
  bool? _permissionGranted;
  Future<_RecorderSession>? _startOperation;
  Future<void>? _stopOperation;
  Future<void>? _closeOperation;
  _RecorderSession? _session;
  bool _captureMayBeActive = false;
  bool _needsStop = false;
  bool _stopRequested = false;
  bool _closing = false;
  bool _closed = false;

  @override
  Future<bool> hasPermission() {
    if (_closed || _closing) {
      return Future<bool>.error(
        const SpeechInputFailure(SpeechInputFailureCode.closed),
      );
    }
    final existing = _permissionOperation;
    if (existing != null) return existing;

    final operation = _checkPermission();
    _permissionOperation = operation;
    return operation.whenComplete(() {
      if (identical(_permissionOperation, operation)) {
        _permissionOperation = null;
      }
    });
  }

  Future<bool> _checkPermission() async {
    try {
      final backend = _backend ??= _backendFactory();
      // Permission requests happen only after the caller's explicit action.
      // record_windows 2.3.0 reports true unconditionally, so this result is
      // only a plugin preflight signal and does not prove Windows authorization.
      final granted = await backend.hasPermission(request: true);
      _permissionGranted = granted;
      return granted;
    } on Object {
      _permissionGranted = false;
      throw const SpeechInputFailure(SpeechInputFailureCode.permissionDenied);
    }
  }

  @override
  Future<Stream<Uint8List>> start() {
    if (_closed || _closing) {
      return Future<Stream<Uint8List>>.error(
        const SpeechInputFailure(SpeechInputFailureCode.closed),
      );
    }
    if (_permissionGranted == false) {
      return Future<Stream<Uint8List>>.error(
        const SpeechInputFailure(SpeechInputFailureCode.permissionDenied),
      );
    }
    if (_permissionOperation != null ||
        _startOperation != null ||
        _session != null ||
        _needsStop) {
      return Future<Stream<Uint8List>>.error(
        const SpeechInputFailure(SpeechInputFailureCode.busy),
      );
    }

    _stopRequested = false;
    final operation = _startCapture();
    _startOperation = operation;
    return _finishStart(operation);
  }

  Future<Stream<Uint8List>> _finishStart(
    Future<_RecorderSession> operation,
  ) async {
    late final _RecorderSession session;
    try {
      session = await operation;
    } finally {
      if (identical(_startOperation, operation)) _startOperation = null;
    }

    if (_stopRequested || _closing) await stop();
    return session.stream;
  }

  Future<_RecorderSession> _startCapture() async {
    final SpeechAudioRecorderBackend backend;
    try {
      backend = _backend ??= _backendFactory();
    } on Object {
      throw const SpeechInputFailure(
        SpeechInputFailureCode.microphoneUnavailable,
      );
    }

    _captureMayBeActive = true;
    final Stream<Uint8List> source;
    try {
      source = await backend.startStream(_recordConfig);
    } on Object {
      await _cleanUpFailedStart(backend);
      throw const SpeechInputFailure(
        SpeechInputFailureCode.microphoneUnavailable,
      );
    }

    final session = _RecorderSession();
    _session = session;
    session.forwarding = !_stopRequested && !_closing;
    session.stream = source.transform(
      StreamTransformer<Uint8List, Uint8List>.fromHandlers(
        handleData: (bytes, sink) {
          if (session.forwarding) sink.add(bytes);
        },
        handleError: (Object _, StackTrace _, sink) {
          if (session.forwarding) {
            sink.addError(
              const SpeechInputFailure(
                SpeechInputFailureCode.microphoneUnavailable,
              ),
            );
          }
        },
        handleDone: (sink) {
          session.forwarding = false;
          sink.close();
        },
      ),
    );
    return session;
  }

  Future<void> _cleanUpFailedStart(SpeechAudioRecorderBackend backend) async {
    try {
      await backend.stop();
      _captureMayBeActive = false;
      _needsStop = false;
    } on Object {
      _needsStop = true;
      throw const SpeechInputFailure(SpeechInputFailureCode.cleanupFailed);
    }
  }

  @override
  Future<void> stop() {
    final existing = _stopOperation;
    if (existing != null) return existing;

    final operation = _stopCapture();
    _stopOperation = operation;
    return operation.whenComplete(() {
      if (identical(_stopOperation, operation)) _stopOperation = null;
    });
  }

  Future<void> _stopCapture() async {
    _stopRequested = true;
    final pendingStart = _startOperation;
    if (pendingStart != null) {
      try {
        await pendingStart;
      } on Object {
        // A failed start performs its own cleanup; retry below if that failed.
      }
    }

    final session = _session;
    if (session == null && !_captureMayBeActive && !_needsStop) {
      _stopRequested = false;
      return;
    }

    final backend = _backend;
    if (backend == null) {
      _needsStop = true;
      throw const SpeechInputFailure(SpeechInputFailureCode.cleanupFailed);
    }
    if (session != null) session.forwarding = false;

    try {
      await backend.stop();
    } on Object {
      _needsStop = true;
      throw const SpeechInputFailure(SpeechInputFailureCode.cleanupFailed);
    }

    _session = null;
    _captureMayBeActive = false;
    _needsStop = false;
    _stopRequested = false;
  }

  @override
  Future<void> close() {
    if (_closed) return Future<void>.value();
    final existing = _closeOperation;
    if (existing != null) return existing;

    final operation = _closeRecorder();
    _closeOperation = operation;
    return operation.whenComplete(() {
      if (identical(_closeOperation, operation)) _closeOperation = null;
    });
  }

  Future<void> _closeRecorder() async {
    _closing = true;
    final pendingPermission = _permissionOperation;
    if (pendingPermission != null) {
      try {
        await pendingPermission;
      } on Object {
        // Permission failure is not a cleanup failure; still dispose safely.
      }
    }

    await stop();
    final backend = _backend;
    if (backend != null) {
      try {
        await backend.dispose();
      } on Object {
        throw const SpeechInputFailure(SpeechInputFailureCode.cleanupFailed);
      }
      _backend = null;
    }
    _closed = true;
  }
}

final class _RecorderSession {
  late final Stream<Uint8List> stream;
  bool forwarding = false;
}

final class _RecordBackend implements SpeechAudioRecorderBackend {
  _RecordBackend() : _recorder = AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<bool> hasPermission({required bool request}) =>
      _recorder.hasPermission(request: request);

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) =>
      _recorder.startStream(config);

  @override
  Future<void> stop() async {
    await _recorder.stop();
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}
