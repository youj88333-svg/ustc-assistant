import 'dart:typed_data';

const speechSampleRate = 16000;
const speechMaximumSeconds = 30;
const speechMaximumSamples = speechSampleRate * speechMaximumSeconds;
const speechMaximumPcmBytes = speechMaximumSamples * 2;
const speechMinimumSamples = speechSampleRate ~/ 2;
const speechMaximumTextCharacters = 2000;

enum SpeechInputPhase {
  idle,
  preparing,
  recording,
  stopping,
  recognizing,
  cancelling,
  recovery,
  closed,
}

enum SpeechInputFailureCode {
  unsupportedPlatform,
  permissionDenied,
  microphoneUnavailable,
  modelUnavailable,
  invalidAudio,
  noSpeech,
  tooShort,
  resourceLimit,
  recognitionFailed,
  cleanupFailed,
  busy,
  closed,
}

final class SpeechInputFailure implements Exception {
  const SpeechInputFailure(this.code);
  final SpeechInputFailureCode code;
  @override
  String toString() => 'SpeechInputFailure(${code.name})';
}

/// Private, ephemeral draft content. Never a diagnostic/model/tool payload.
final class SpeechTranscript {
  const SpeechTranscript({required this.revision, required this.text});
  final int revision;
  final String text;
  @override
  String toString() => 'SpeechTranscript';
}

final class SpeechInputView {
  const SpeechInputView({
    this.phase = SpeechInputPhase.idle,
    this.revision = 0,
    this.elapsedMilliseconds = 0,
    this.failure,
    this.transcript,
  });
  final SpeechInputPhase phase;
  final int revision;
  final int elapsedMilliseconds;
  final SpeechInputFailureCode? failure;
  final SpeechTranscript? transcript;
  bool get busy =>
      phase != SpeechInputPhase.idle && phase != SpeechInputPhase.closed;
  @override
  String toString() => 'SpeechInputView(${phase.name})';
}

/// One user-operated short recording. The owner, not the page, closes the port.
abstract interface class SpeechInputPort {
  SpeechInputView get view;
  Stream<SpeechInputView> get changes;
  Future<void> start();
  Future<void> finish();

  /// Revokes delivery first, then stops recording and drains recognition.
  Future<void> cancel();
  Future<void> close();
}

/// Fixed PCM16 little-endian, mono, 16 kHz; never writes an audio file.
abstract interface class SpeechRecorderPort {
  Future<bool> hasPermission();
  Future<Stream<Uint8List>> start();

  /// Stops capture and drains its stream. Late frames cannot start new capture.
  Future<void> stop();
  Future<void> close();
}

/// Fixed local model, no address/Key/network input. Native work stays off the UI.
abstract interface class SpeechRecognizerPort {
  Future<void> prepare();

  /// Caller gives ownership of samples until this future settles.
  Future<String> recognize(Float32List samples);

  /// Waits for active recognition and releases native resources.
  Future<void> close();
}
