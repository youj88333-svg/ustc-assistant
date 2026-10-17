import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../core/speech_input_contract.dart';
import 'speech_model_bundle.dart';

/// One lazy, persistent CPU worker. No microphone, network or business access.
final class SenseVoiceRecognizer implements SpeechRecognizerPort {
  SenseVoiceRecognizer({SpeechModelBundle? bundle, this.bundleLoader})
    : bundle = bundle ?? SpeechModelBundle();
  final SpeechModelBundle bundle;
  final Future<SpeechModelBundle> Function()? bundleLoader;
  Future<_SpeechWorker>? _preparing;
  Future<String>? _active;
  Future<void>? _closing;
  bool _closed = false;

  @override
  Future<void> prepare() async {
    if (_closed) throw const SpeechInputFailure(SpeechInputFailureCode.closed);
    final future = _preparing ??= _openWorker();
    try {
      await future;
    } catch (_) {
      if (identical(_preparing, future)) {
        _preparing = null;
      }
      throw const SpeechInputFailure(SpeechInputFailureCode.modelUnavailable);
    }
    if (_closed) throw const SpeechInputFailure(SpeechInputFailureCode.closed);
  }

  Future<_SpeechWorker> _openWorker() async {
    final assets = await (bundleLoader?.call() ?? Future.value(bundle));
    if (_closed) throw const SpeechInputFailure(SpeechInputFailureCode.closed);
    return _SpeechWorker.open(assets);
  }

  @override
  Future<String> recognize(Float32List samples) async {
    if (_closed) throw const SpeechInputFailure(SpeechInputFailureCode.closed);
    if (_active != null) {
      throw const SpeechInputFailure(SpeechInputFailureCode.busy);
    }
    if (samples.length < speechMinimumSamples ||
        samples.length > speechMaximumSamples ||
        samples.any((value) => !value.isFinite || value < -1 || value > 1)) {
      throw const SpeechInputFailure(SpeechInputFailureCode.invalidAudio);
    }
    final work = () async {
      await prepare();
      if (_closed) {
        throw const SpeechInputFailure(SpeechInputFailureCode.closed);
      }
      final preparing = _preparing!;
      final worker = await preparing;
      try {
        return await worker.decode(samples);
      } catch (_) {
        if (worker.unavailable && identical(_preparing, preparing)) {
          await worker.close();
          _preparing = null;
        }
        rethrow;
      }
    }();
    _active = work;
    try {
      return await work;
    } finally {
      _active = null;
    }
  }

  @override
  Future<void> close() {
    final existing = _closing;
    if (existing != null) return existing;
    _closed = true;
    final work = () async {
      try {
        await _active;
      } catch (_) {
        /* Active failure still needs drain. */
      }
      final preparing = _preparing;
      if (preparing != null) {
        _SpeechWorker? worker;
        try {
          worker = await preparing;
        } catch (_) {
          /* Failed worker already exited. */
        }
        if (worker != null) await worker.close();
      }
      _preparing = null;
    }();
    _closing = work;
    return work.catchError((Object _) {
      _closing = null;
      throw const SpeechInputFailure(SpeechInputFailureCode.cleanupFailed);
    });
  }
}

final class _SpeechWorker {
  _SpeechWorker();
  final ReceivePort _messages = ReceivePort(),
      _errors = ReceivePort(),
      _exit = ReceivePort();
  final Completer<SendPort> _ready = Completer<SendPort>();
  final Completer<void> _exited = Completer<void>();
  SendPort? _commands;
  Completer<String>? _result;
  StreamSubscription<Object?>? _messageSubscription,
      _errorSubscription,
      _exitSubscription;
  bool _closing = false;
  bool get unavailable => _closing || _exited.isCompleted;

  static Future<_SpeechWorker> open(SpeechModelBundle bundle) async {
    final worker = _SpeechWorker();
    worker._messageSubscription = worker._messages.listen(worker._onMessage);
    worker._errorSubscription = worker._errors.listen(
      (Object? _) => worker._failed(),
    );
    worker._exitSubscription = worker._exit.listen((Object? _) {
      worker._failed();
      if (!worker._exited.isCompleted) worker._exited.complete();
    });
    var spawned = false;
    // Attach the failure handler before the worker can report startup failure.
    final ready = worker._ready.future;
    unawaited(ready.then<void>((_) {}, onError: (Object _) {}));
    try {
      await Isolate.spawn<List<Object>>(
        _runSpeechWorker,
        [
          worker._messages.sendPort,
          bundle.executableDirectory,
          bundle.androidAssets,
        ],
        onError: worker._errors.sendPort,
        onExit: worker._exit.sendPort,
        errorsAreFatal: true,
        debugName: 'ustc-offline-speech',
      );
      spawned = true;
      worker._commands = await ready;
      return worker;
    } catch (_) {
      // Initialization errors exit the worker. Preserve ownership until exit.
      if (spawned) await worker._exited.future;
      await worker._disposePorts();
      throw const SpeechInputFailure(SpeechInputFailureCode.modelUnavailable);
    }
  }

  void _onMessage(Object? message) {
    if (message is SendPort) {
      if (!_ready.isCompleted) _ready.complete(message);
    } else if (message is String) {
      final result = _result;
      _result = null;
      if (result != null && !result.isCompleted) result.complete(message);
    } else if (message is SpeechInputFailureCode) {
      final result = _result;
      _result = null;
      final failure = SpeechInputFailure(message);
      if (!_ready.isCompleted) _ready.completeError(failure);
      if (result != null && !result.isCompleted) result.completeError(failure);
    }
  }

  void _failed() {
    const failure = SpeechInputFailure(
      SpeechInputFailureCode.recognitionFailed,
    );
    if (!_ready.isCompleted) _ready.completeError(failure);
    final result = _result;
    _result = null;
    if (result != null && !result.isCompleted) result.completeError(failure);
  }

  Future<String> decode(Float32List samples) {
    if (_closing || _exited.isCompleted || _commands == null) {
      throw const SpeechInputFailure(SpeechInputFailureCode.recognitionFailed);
    }
    if (_result != null) {
      throw const SpeechInputFailure(SpeechInputFailureCode.busy);
    }
    final result = Completer<String>();
    _result = result;
    _commands!.send(
      TransferableTypedData.fromList([
        samples.buffer.asUint8List(
          samples.offsetInBytes,
          samples.lengthInBytes,
        ),
      ]),
    );
    return result.future;
  }

  Future<void> close() async {
    _closing = true;
    final result = _result;
    if (result != null) {
      try {
        await result.future;
      } catch (_) {
        /* Drain before release. */
      }
    }
    if (!_exited.isCompleted) {
      _commands?.send(null);
      await _exited.future;
    }
    await _disposePorts();
  }

  Future<void> _disposePorts() async {
    await _messageSubscription?.cancel();
    await _errorSubscription?.cancel();
    await _exitSubscription?.cancel();
    _messages.close();
    _errors.close();
    _exit.close();
  }
}

Future<void> _runSpeechWorker(List<Object> arguments) async {
  final results = arguments[0] as SendPort;
  final commands = ReceivePort();
  sherpa.OfflineRecognizer? recognizer;
  try {
    final bundle = arguments[2] as bool
        ? SpeechModelBundle.android(directory: arguments[1] as String)
        : SpeechModelBundle(executableDirectory: arguments[1] as String);
    await bundle.validate();
    if (bundle.androidAssets && Platform.isAndroid) {
      // Android resolves the pinned packaged .so and its dependencies via the
      // app's native library namespace, never through a desktop DLL path.
      sherpa.initBindings();
    } else {
      _loadOnnxRuntime(bundle);
      sherpa.initBindings(bundle.executableDirectory);
    }
    recognizer = sherpa.OfflineRecognizer(
      buildSenseVoiceRecognizerConfig(bundle),
    );
    results.send(commands.sendPort);
    await for (final command in commands) {
      if (command == null) break;
      if (command is! TransferableTypedData) {
        results.send(SpeechInputFailureCode.invalidAudio);
        continue;
      }
      Float32List? samples;
      sherpa.OfflineStream? stream;
      try {
        samples = command.materialize().asFloat32List();
        if (samples.length < speechMinimumSamples ||
            samples.length > speechMaximumSamples ||
            samples.any((v) => !v.isFinite || v < -1 || v > 1)) {
          throw const SpeechInputFailure(SpeechInputFailureCode.invalidAudio);
        }
        stream = recognizer.createStream();
        stream.acceptWaveform(samples: samples, sampleRate: speechSampleRate);
        recognizer.decode(stream);
        final text = recognizer.getResult(stream).text.trim();
        if (text.length > speechMaximumTextCharacters) {
          throw const SpeechInputFailure(SpeechInputFailureCode.resourceLimit);
        }
        results.send(text);
      } catch (error) {
        results.send(
          error is SpeechInputFailure
              ? error.code
              : SpeechInputFailureCode.recognitionFailed,
        );
      } finally {
        stream?.free();
        samples?.fillRange(0, samples.length, 0);
      }
    }
  } catch (_) {
    results.send(SpeechInputFailureCode.modelUnavailable);
  } finally {
    recognizer?.free();
    commands.close();
  }
}

/// Builds the fixed local-recognition configuration without loading native code.
@visibleForTesting
sherpa.OfflineRecognizerConfig buildSenseVoiceRecognizerConfig(
  SpeechModelBundle bundle,
) => sherpa.OfflineRecognizerConfig(
  model: sherpa.OfflineModelConfig(
    senseVoice: sherpa.OfflineSenseVoiceModelConfig(
      model: bundle.modelPath,
      language: 'zh',
      useInverseTextNormalization: true,
    ),
    tokens: bundle.tokensPath,
    numThreads: 2,
    debug: false,
    provider: 'cpu',
  ),
);

// Load the packaged dependency before sherpa, rather than resolving it through
// the caller's PATH. A different ONNX API can otherwise crash inside native C++.
void _loadOnnxRuntime(SpeechModelBundle bundle) {
  final library = DynamicLibrary.open(
    p.join(bundle.executableDirectory, 'onnxruntime.dll'),
  );
  _validateOrtApi(library);
  // If another component already loaded an older DLL with this basename,
  // sherpa's import may bind that module. Refuse before calling native creation.
  _validateOrtApi(DynamicLibrary.open('onnxruntime.dll'));
}

void _validateOrtApi(DynamicLibrary library) {
  final apiBase = library
      .lookupFunction<
        Pointer<_OrtApiBase> Function(),
        Pointer<_OrtApiBase> Function()
      >('OrtGetApiBase')();
  if (apiBase == nullptr ||
      apiBase.ref.getVersionString
              .asFunction<Pointer<Utf8> Function()>()()
              .toDartString() !=
          '1.28.2' ||
      apiBase.ref.getApi.asFunction<Pointer<Void> Function(int)>()(28) ==
          nullptr) {
    throw const SpeechInputFailure(SpeechInputFailureCode.modelUnavailable);
  }
}

final class _OrtApiBase extends Struct {
  external Pointer<NativeFunction<Pointer<Void> Function(Uint32)>> getApi;
  external Pointer<NativeFunction<Pointer<Utf8> Function()>> getVersionString;
}
