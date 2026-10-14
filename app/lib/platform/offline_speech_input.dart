import 'dart:async';
import 'dart:typed_data';

import '../core/diagnostics_contract.dart';
import '../core/speech_input_contract.dart';

/// User-operated input only. Audio and transcript never enter a log or C4.
final class OfflineSpeechInput implements SpeechInputPort {
  OfflineSpeechInput({
    required this.recorder,
    required this.recognizer,
    this.diagnostics,
  });
  final SpeechRecorderPort recorder;
  final SpeechRecognizerPort recognizer;
  final DiagnosticsPort? diagnostics;
  // A subscriber may cancel in response to a stage. Async delivery prevents
  // reentrant broadcast.add while the current immutable view changes at once.
  final _changes = StreamController<SpeechInputView>.broadcast();
  SpeechInputView _view = const SpeechInputView();
  @override
  SpeechInputView get view => _view;
  @override
  Stream<SpeechInputView> get changes => _changes.stream;
  int _revision = 0, _byteCount = 0;
  Uint8List? _pcm;
  StreamSubscription<Uint8List>? _subscription;
  Timer? _limit, _progress;
  final Stopwatch _elapsed = Stopwatch();
  Future<void>? _starting, _finishing, _cancelling, _closing;
  bool _closeRequested = false, _finishQueued = false;
  bool _recorderClosed = false, _recognizerClosed = false;
  DiagnosticTrace? _trace;

  void _current(int revision) {
    if (revision != _revision || _closeRequested || _cancelling != null) {
      throw const _RevokedSpeech();
    }
  }

  void _publish(
    SpeechInputPhase phase, {
    SpeechInputFailureCode? failure,
    SpeechTranscript? transcript,
    int? count,
    bool log = true,
    DiagnosticOutcome? outcome,
  }) {
    _view = SpeechInputView(
      phase: phase,
      revision: _revision,
      elapsedMilliseconds: _elapsed.elapsedMilliseconds,
      failure: failure,
      transcript: transcript,
    );
    if (!_changes.isClosed) _changes.add(_view);
    if (!log) return;
    try {
      diagnostics?.record(
        DiagnosticEvent(
          name: DiagnosticEventName.speechInputStage,
          trace: _trace,
          stage: DiagnosticStage.speechInput,
          phase: diagnosticPhase(phase.name),
          outcome:
              outcome ??
              (failure != null
                  ? DiagnosticOutcome.failure
                  : transcript != null
                  ? DiagnosticOutcome.complete
                  : DiagnosticOutcome.started),
          code: failure == null ? null : diagnosticCode(failure.name),
          elapsedMilliseconds: _elapsed.elapsedMilliseconds,
          count:
              count ??
              (transcript == null ? _byteCount ~/ 2 : transcript.text.length),
        ),
      );
    } catch (_) {
      /* Best-effort, no private content or exception text. */
    }
  }

  @override
  Future<void> start() {
    if (_closeRequested) {
      throw const SpeechInputFailure(SpeechInputFailureCode.closed);
    }
    if (_view.busy ||
        _starting != null ||
        _finishing != null ||
        _cancelling != null) {
      throw const SpeechInputFailure(SpeechInputFailureCode.busy);
    }
    final revision = ++_revision;
    _finishQueued = false;
    _elapsed.reset();
    try {
      _trace = diagnostics?.newTrace();
    } catch (_) {
      _trace = null;
    }
    final work = Future<void>.microtask(() => _start(revision));
    _starting = work;
    _publish(SpeechInputPhase.preparing);
    return work.whenComplete(() => _starting = null);
  }

  Future<void> _start(int revision) async {
    try {
      _current(revision);
      await recognizer.prepare();
      _current(revision);
      if (!await recorder.hasPermission()) {
        throw const SpeechInputFailure(SpeechInputFailureCode.permissionDenied);
      }
      _current(revision);
      _pcm = Uint8List(speechMaximumPcmBytes);
      _byteCount = 0;
      final stream = await recorder.start();
      _current(revision);
      _subscription = stream.listen(
        (frame) => _accept(frame, revision),
        onError: (Object _, StackTrace _) => _captureFailed(revision),
        onDone: () {
          if (revision == _revision &&
              _view.phase == SpeechInputPhase.recording) {
            _captureFailed(revision);
          }
        },
      );
      _elapsed.start();
      _publish(SpeechInputPhase.recording);
      if (_byteCount == speechMaximumPcmBytes) _queueFinish();
      _limit = Timer(
        const Duration(seconds: speechMaximumSeconds),
        _queueFinish,
      );
      _progress = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (_view.phase == SpeechInputPhase.recording) {
          _publish(SpeechInputPhase.recording, log: false);
        }
      });
    } on _RevokedSpeech {
      // The cancelling operation owns drain and the final view.
    } catch (error) {
      if (revision != _revision) return;
      try {
        await _stopCapture();
        _wipeAudio();
        _publish(SpeechInputPhase.idle, failure: _failure(error));
      } catch (_) {
        _publish(
          SpeechInputPhase.recovery,
          failure: SpeechInputFailureCode.cleanupFailed,
        );
      }
    }
  }

  void _accept(Uint8List frame, int revision) {
    if (revision != _revision ||
        _pcm == null ||
        (_view.phase != SpeechInputPhase.preparing &&
            _view.phase != SpeechInputPhase.recording &&
            _view.phase != SpeechInputPhase.stopping)) {
      return;
    }
    final remaining = speechMaximumPcmBytes - _byteCount;
    final amount = frame.length < remaining ? frame.length : remaining;
    if (amount > 0) {
      _pcm!.setRange(_byteCount, _byteCount + amount, frame);
      _byteCount += amount;
    }
    if (_byteCount == speechMaximumPcmBytes) _queueFinish();
  }

  void _queueFinish() {
    if (_finishQueued || _view.phase != SpeechInputPhase.recording) return;
    _finishQueued = true;
    scheduleMicrotask(() {
      if (_view.phase == SpeechInputPhase.recording && !_closeRequested) {
        unawaited(finish().catchError((Object _) {}));
      }
    });
  }

  void _captureFailed(int revision) {
    if (revision != _revision || _view.phase != SpeechInputPhase.recording) {
      return;
    }
    final cancelledRevision = revision + 1;
    unawaited(
      cancel()
          .then((_) {
            if (!_closeRequested &&
                _revision == cancelledRevision &&
                _view.phase == SpeechInputPhase.idle) {
              _publish(
                SpeechInputPhase.idle,
                failure: SpeechInputFailureCode.microphoneUnavailable,
              );
            }
          })
          .catchError((Object _) {}),
    );
  }

  @override
  Future<void> finish() {
    final existing = _finishing;
    if (existing != null) return existing;
    if (_view.phase != SpeechInputPhase.recording ||
        _closeRequested ||
        _cancelling != null) {
      throw const SpeechInputFailure(SpeechInputFailureCode.busy);
    }
    final revision = _revision;
    final work = Future<void>.microtask(() => _finish(revision));
    _finishing = work;
    _publish(SpeechInputPhase.stopping);
    return work.whenComplete(() => _finishing = null);
  }

  Future<void> _finish(int revision) async {
    Float32List? samples;
    try {
      _current(revision);
      await _stopCapture();
      _current(revision);
      samples = _decodeAudio();
      _wipeAudio();
      _publish(SpeechInputPhase.recognizing, count: samples.length);
      final text = (await recognizer.recognize(samples)).trim();
      _current(revision);
      if (text.isEmpty) {
        throw const SpeechInputFailure(SpeechInputFailureCode.noSpeech);
      }
      if (text.length > speechMaximumTextCharacters) {
        throw const SpeechInputFailure(SpeechInputFailureCode.resourceLimit);
      }
      _publish(
        SpeechInputPhase.idle,
        transcript: SpeechTranscript(revision: revision, text: text),
      );
    } on _RevokedSpeech {
      // Delivery has been revoked; the cancelling caller awaits this work.
    } catch (error) {
      if (revision == _revision) {
        final phase = _subscription == null
            ? SpeechInputPhase.idle
            : SpeechInputPhase.recovery;
        _publish(
          phase,
          failure: phase == SpeechInputPhase.recovery
              ? SpeechInputFailureCode.cleanupFailed
              : _failure(error),
        );
      }
    } finally {
      samples?.fillRange(0, samples.length, 0);
      _wipeAudio();
    }
  }

  Float32List _decodeAudio() {
    if (_byteCount.isOdd) {
      throw const SpeechInputFailure(SpeechInputFailureCode.invalidAudio);
    }
    if (_byteCount ~/ 2 < speechMinimumSamples) {
      throw const SpeechInputFailure(SpeechInputFailureCode.tooShort);
    }
    final data = ByteData.sublistView(_pcm!, 0, _byteCount);
    final samples = Float32List(_byteCount ~/ 2);
    double energy = 0;
    for (var i = 0; i < samples.length; i++) {
      final value = data.getInt16(i * 2, Endian.little) / 32768;
      samples[i] = value;
      energy += value * value;
    }
    if (energy / samples.length < 1e-10) {
      samples.fillRange(0, samples.length, 0);
      throw const SpeechInputFailure(SpeechInputFailureCode.noSpeech);
    }
    return samples;
  }

  Future<void> _stopCapture() async {
    _limit?.cancel();
    _limit = null;
    _progress?.cancel();
    _progress = null;
    _elapsed.stop();
    if (!_recorderClosed) await recorder.stop();
    await _subscription?.cancel();
    _subscription = null;
  }

  void _wipeAudio() {
    _pcm?.fillRange(0, _pcm!.length, 0);
    _pcm = null;
    _byteCount = 0;
  }

  @override
  Future<void> cancel() {
    final existing = _cancelling;
    if (existing != null) return existing;
    if (_view.phase == SpeechInputPhase.closed) return Future<void>.value();
    if (_view.phase == SpeechInputPhase.idle &&
        _starting == null &&
        _finishing == null &&
        _subscription == null) {
      ++_revision;
      _wipeAudio();
      _publish(SpeechInputPhase.idle, log: false);
      return Future<void>.value();
    }
    ++_revision;
    final starting = _starting, finishing = _finishing;
    final work = Future<void>.microtask(() async {
      try {
        await starting;
        await _stopCapture();
        await finishing;
        _wipeAudio();
        _publish(SpeechInputPhase.idle, outcome: DiagnosticOutcome.cancelled);
      } catch (_) {
        _wipeAudio();
        _publish(
          SpeechInputPhase.recovery,
          failure: SpeechInputFailureCode.cleanupFailed,
        );
        throw const SpeechInputFailure(SpeechInputFailureCode.cleanupFailed);
      }
    });
    _cancelling = work;
    _publish(SpeechInputPhase.cancelling, outcome: DiagnosticOutcome.cancelled);
    return work.whenComplete(() => _cancelling = null);
  }

  @override
  Future<void> close() {
    final existing = _closing;
    if (existing != null) return existing;
    if (_view.phase == SpeechInputPhase.closed) return Future<void>.value();
    _closeRequested = true;
    final work = Future<void>.microtask(() async {
      await cancel();
      try {
        if (!_recorderClosed) {
          await recorder.close();
          _recorderClosed = true;
        }
        if (!_recognizerClosed) {
          await recognizer.close();
          _recognizerClosed = true;
        }
      } catch (_) {
        _publish(
          SpeechInputPhase.recovery,
          failure: SpeechInputFailureCode.cleanupFailed,
        );
        throw const SpeechInputFailure(SpeechInputFailureCode.cleanupFailed);
      }
      _publish(SpeechInputPhase.closed, outcome: DiagnosticOutcome.closed);
      await _changes.close();
    });
    _closing = work;
    return work.catchError((Object error) {
      _closing = null;
      throw error;
    });
  }

  SpeechInputFailureCode _failure(Object error) => error is SpeechInputFailure
      ? error.code
      : SpeechInputFailureCode.recognitionFailed;
}

final class _RevokedSpeech implements Exception {
  const _RevokedSpeech();
}
