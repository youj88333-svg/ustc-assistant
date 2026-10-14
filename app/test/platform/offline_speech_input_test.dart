import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';
import 'package:ustc_assistant_m0/platform/offline_speech_input.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OfflineSpeechInput', () {
    test('prepares on demand, combines odd chunks, decodes PCM16', () async {
      final harness = _SpeechHarness();
      addTearDown(harness.close);

      expect(harness.input.view.phase, SpeechInputPhase.idle);
      expect(harness.recorder.permissionCalls, 0);
      expect(harness.recorder.startCalls, 0);
      expect(harness.recognizer.prepareCalls, 0);

      await harness.input.start();
      expect(harness.input.view.phase, SpeechInputPhase.recording);
      expect(harness.recognizer.prepareCalls, 1);
      expect(harness.recorder.startCalls, 1);
      expect(harness.recorder.permissionCalls, 1);
      expect(
        () => harness.input.start(),
        throwsA(
          isA<SpeechInputFailure>().having(
            (failure) => failure.code,
            'code',
            SpeechInputFailureCode.busy,
          ),
        ),
      );

      final samples = List<int>.filled(speechMinimumSamples, 1000)
        ..setRange(0, 7, [-32768, -16384, -1, 0, 1, 16384, 32767]);
      final pcm = _pcm16(samples);
      final chunks = _oddSizedChunks(pcm);
      expect(chunks.any((chunk) => chunk.length.isOdd), isTrue);
      for (final chunk in chunks) {
        harness.recorder.push(chunk);
      }

      harness.recognizer.result = '  本地短句  ';
      await harness.input.finish();

      expect(harness.input.view.phase, SpeechInputPhase.idle);
      expect(harness.input.view.failure, isNull);
      expect(harness.input.view.transcript?.text, '本地短句');
      expect(harness.recognizer.sampleValues, isNotNull);
      expect(
        harness.recognizer.sampleValues!.take(7).toList(),
        equals([-1, -0.5, -1 / 32768, 0, 1 / 32768, 0.5, 32767 / 32768]),
      );
      expect(harness.recognizer.receivedSampleCount, speechMinimumSamples);
      expect(
        harness.recognizer.lastSamples!.every((sample) => sample == 0),
        isTrue,
      );
      expect(harness.recorder.sourceCancelCalls, 1);
    });

    test('fixed setup failures are retryable', () async {
      final model = _SpeechHarness();
      addTearDown(model.close);
      model.recognizer.prepareError = const SpeechInputFailure(
        SpeechInputFailureCode.modelUnavailable,
      );

      await model.input.start();
      _expectViewFailure(model.input, SpeechInputFailureCode.modelUnavailable);
      expect(model.recorder.permissionCalls, 0);
      expect(model.recorder.startCalls, 0);

      model.recognizer.prepareError = null;
      await model.input.start();
      expect(model.input.view.phase, SpeechInputPhase.recording);
      await model.input.cancel();
      expect(model.input.view.phase, SpeechInputPhase.idle);

      final permission = _SpeechHarness()..recorder.permissionGranted = false;
      addTearDown(permission.close);
      await permission.input.start();
      _expectViewFailure(
        permission.input,
        SpeechInputFailureCode.permissionDenied,
      );
      expect(permission.recorder.startCalls, 0);
      permission.recorder.permissionGranted = true;
      await permission.input.start();
      expect(permission.input.view.phase, SpeechInputPhase.recording);
      await permission.input.cancel();

      final recorder = _SpeechHarness();
      addTearDown(recorder.close);
      recorder.recorder.startError = const SpeechInputFailure(
        SpeechInputFailureCode.microphoneUnavailable,
      );
      await recorder.input.start();
      _expectViewFailure(
        recorder.input,
        SpeechInputFailureCode.microphoneUnavailable,
      );
      recorder.recorder.startError = null;
      await recorder.input.start();
      expect(recorder.input.view.phase, SpeechInputPhase.recording);
      expect(recorder.recorder.startCalls, 2);
      await recorder.input.cancel();
    });

    test('short, silent, malformed audio fail without recognition', () async {
      final short = _SpeechHarness();
      addTearDown(short.close);
      await short.input.start();
      short.recorder.push(
        _pcm16(List<int>.filled(speechMinimumSamples - 1, 1)),
      );
      await short.input.finish();
      _expectViewFailure(short.input, SpeechInputFailureCode.tooShort);
      expect(short.recognizer.recognizeCalls, 0);

      final silent = _SpeechHarness();
      addTearDown(silent.close);
      await silent.input.start();
      silent.recorder.push(Uint8List(speechMinimumSamples * 2));
      await silent.input.finish();
      _expectViewFailure(silent.input, SpeechInputFailureCode.noSpeech);
      expect(silent.recognizer.recognizeCalls, 0);

      final malformed = _SpeechHarness();
      addTearDown(malformed.close);
      await malformed.input.start();
      malformed.recorder.push(
        Uint8List.fromList([
          ..._pcm16(List<int>.filled(speechMinimumSamples, 1)),
          0x7f,
        ]),
      );
      await malformed.input.finish();
      _expectViewFailure(malformed.input, SpeechInputFailureCode.invalidAudio);
      expect(malformed.recognizer.recognizeCalls, 0);
    });

    test('rejects text over 2000 characters, then allows retry', () async {
      final harness = _SpeechHarness();
      addTearDown(harness.close);
      await harness.input.start();
      harness.recorder.push(
        _pcm16(List<int>.filled(speechMinimumSamples, 100)),
      );
      harness.recognizer.result = '字' * (speechMaximumTextCharacters + 1);
      await harness.input.finish();
      _expectViewFailure(harness.input, SpeechInputFailureCode.resourceLimit);
      expect(harness.input.view.transcript, isNull);

      await harness.input.start();
      harness.recorder.push(
        _pcm16(List<int>.filled(speechMinimumSamples, 100)),
      );
      harness.recognizer.result = '可重试';
      await harness.input.finish();
      expect(harness.input.view.transcript?.text, '可重试');
    });

    test('the 960000-byte memory cap queues an automatic finish', () async {
      final harness = _SpeechHarness();
      addTearDown(harness.close);
      await harness.input.start();
      final result = harness.input.changes.firstWhere(
        (view) =>
            view.phase == SpeechInputPhase.idle && view.transcript != null,
      );
      final pcm = Uint8List(speechMaximumPcmBytes);
      for (var offset = 0; offset < pcm.length; offset += 2) {
        pcm[offset] = 100;
      }
      harness.recorder.push(pcm);
      harness.recognizer.result = '字节上限已结束';

      expect((await result).transcript?.text, '字节上限已结束');
      expect(harness.recognizer.recognizeCalls, 1);
      expect(harness.recognizer.receivedSampleCount, speechMaximumSamples);
      expect(harness.recorder.stopCalls, 1);
    });

    test('the 30-second timer automatically finishes in virtual time', () async {
      final clock = FakeAsync();
      late final _SpeechHarness harness;
      clock.run((clock) {
        harness = _SpeechHarness(singleSubscriptionRecorder: true);
        final result = harness.input.changes.firstWhere(
          (view) =>
              view.phase == SpeechInputPhase.idle && view.transcript != null,
        );
        SpeechInputView? resultView;
        var resultDone = false;
        result.then((view) {
          resultView = view;
          resultDone = true;
        });

        var startDone = false;
        harness.input.start().then((_) => startDone = true);
        clock.flushMicrotasks();
        expect(startDone, isTrue);
        expect(harness.input.view.phase, SpeechInputPhase.recording);

        harness.recorder.push(
          _pcm16(List<int>.filled(speechMinimumSamples, 100)),
        );
        harness.recognizer.result = '定时结束';
        clock.elapse(const Duration(seconds: speechMaximumSeconds));
        clock.flushMicrotasks();

        expect(harness.input.view.phase, SpeechInputPhase.idle);
        expect(harness.recorder.stopCalls, 1);
        expect(harness.recognizer.recognizeCalls, 1);
        expect(resultDone, isTrue);
        expect(resultView?.transcript?.text, '定时结束');
      });
      // Stream cancellation uses SDK shared completed futures. Close in real
      // time and flush the fixture's zone too; no virtual timer remains active.
      var closeDone = false;
      final closing = harness.close().then((_) => closeDone = true);
      for (var i = 0; i < 10 && !closeDone; i++) {
        await Future<void>.delayed(Duration.zero);
        clock.flushMicrotasks();
      }
      expect(closeDone, isTrue);
      await closing;
      expect(harness.input.view.phase, SpeechInputPhase.closed);
      expect(harness.recorder.closeCalls, 1);
      expect(harness.recognizer.closeCalls, 1);
    });

    test('cancel during preparation never starts capture', () async {
      final harness = _SpeechHarness();
      addTearDown(harness.close);
      final prepareGate = Completer<void>();
      harness.recognizer.prepareGate = prepareGate;

      final starting = harness.input.start();
      await harness.recognizer.prepareEntered.future;
      final cancelling = harness.input.cancel();
      expect(harness.input.view.phase, SpeechInputPhase.cancelling);
      prepareGate.complete();

      await starting;
      await cancelling;
      expect(harness.input.view.phase, SpeechInputPhase.idle);
      expect(harness.recorder.startCalls, 0);
      expect(harness.recorder.sourceListenCalls, 0);
    });

    test('preparing listener cancels and drains reentrantly', () async {
      final harness = _SpeechHarness();
      addTearDown(harness.close);
      final prepareGate = Completer<void>();
      harness.recognizer.prepareGate = prepareGate;
      Future<void>? cancelling;
      var cancelDone = false;
      final changes = harness.input.changes.listen((view) {
        if (view.phase != SpeechInputPhase.preparing || cancelling != null) {
          return;
        }
        cancelling = harness.input.cancel().then((_) => cancelDone = true);
        Timer.run(() {
          if (harness.recognizer.prepareEntered.isCompleted) {
            expect(cancelDone, isFalse);
          }
          if (!prepareGate.isCompleted) prepareGate.complete();
        });
      });
      addTearDown(changes.cancel);

      await harness.input.start();
      await cancelling;

      expect(harness.input.view.phase, SpeechInputPhase.idle);
      expect(harness.recorder.startCalls, 0);
      expect(harness.recorder.sourceListenCalls, 0);
      expect(cancelDone, isTrue);
    });

    test('recognition cancel revokes and drains late result', () async {
      final harness = _SpeechHarness();
      addTearDown(harness.close);
      final recognizeGate = Completer<void>();
      harness.recognizer.recognizeGate = recognizeGate;
      await harness.input.start();
      harness.recorder.push(
        _pcm16(List<int>.filled(speechMinimumSamples, 100)),
      );

      final finishing = harness.input.finish();
      await harness.recognizer.recognizeEntered.future;
      final cancelling = harness.input.cancel();
      var drained = false;
      cancelling.then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      expect(harness.input.view.phase, SpeechInputPhase.cancelling);

      harness.recognizer.result = '迟到转写内容';
      recognizeGate.complete();
      await finishing;
      await cancelling;

      expect(drained, isTrue);
      expect(harness.input.view.phase, SpeechInputPhase.idle);
      expect(harness.input.view.transcript, isNull);
      expect(
        harness.recognizer.lastSamples!.every((sample) => sample == 0),
        isTrue,
      );
    });

    test('a stopping listener can cancel before recognition begins', () async {
      final harness = _SpeechHarness();
      addTearDown(harness.close);
      final stopGate = Completer<void>();
      harness.recorder.stopGate = stopGate;
      Future<void>? cancelling;
      var cancelDone = false;
      final changes = harness.input.changes.listen((view) {
        if (view.phase == SpeechInputPhase.stopping && cancelling == null) {
          cancelling = harness.input.cancel().then((_) => cancelDone = true);
        }
      });
      addTearDown(changes.cancel);
      await harness.input.start();
      harness.recorder.push(
        _pcm16(List<int>.filled(speechMinimumSamples, 100)),
      );

      final finishing = harness.input.finish();
      await harness.recorder.stopEntered.future;
      await Future<void>.delayed(Duration.zero);
      expect(cancelling, isNotNull);
      expect(cancelDone, isFalse);
      stopGate.complete();
      await finishing;
      await cancelling;

      expect(harness.input.view.phase, SpeechInputPhase.idle);
      expect(harness.input.view.transcript, isNull);
      expect(harness.recognizer.recognizeCalls, 0);
      expect(cancelDone, isTrue);
    });

    test('capture failure after cancel cannot poison next recording', () async {
      final harness = _SpeechHarness();
      addTearDown(harness.close);
      final stopGate = Completer<void>();
      harness.recorder.stopGate = stopGate;
      await harness.input.start();

      final cancelling = harness.input.cancel();
      expect(harness.input.view.phase, SpeechInputPhase.cancelling);
      harness.recorder.fail(StateError('DEVICE-SENTINEL'));
      expect(harness.input.view.phase, SpeechInputPhase.cancelling);
      await harness.recorder.stopEntered.future;
      stopGate.complete();
      await cancelling;
      await Future<void>.delayed(Duration.zero);

      expect(harness.input.view.phase, SpeechInputPhase.idle);
      expect(harness.input.view.failure, isNull);
      await harness.input.start();
      expect(harness.input.view.phase, SpeechInputPhase.recording);
      expect(harness.input.view.failure, isNull);
      await harness.input.cancel();
    });

    test('stop failure enters recovery and cancel retries cleanup', () async {
      final harness = _SpeechHarness();
      addTearDown(harness.close);
      await harness.input.start();
      harness.recorder.push(
        _pcm16(List<int>.filled(speechMinimumSamples, 100)),
      );
      harness.recorder.stopError = StateError('DEVICE-SENTINEL');

      await harness.input.finish();
      expect(harness.input.view.phase, SpeechInputPhase.recovery);
      expect(harness.input.view.failure, SpeechInputFailureCode.cleanupFailed);
      expect(harness.recognizer.recognizeCalls, 0);
      expect(harness.recorder.sourceCancelCalls, 0);

      harness.recorder.stopError = null;
      await harness.input.cancel();
      expect(harness.input.view.phase, SpeechInputPhase.idle);
      expect(harness.input.view.failure, isNull);
      expect(harness.recorder.stopCalls, 2);
      expect(harness.recorder.sourceCancelCalls, 1);
    });

    test('close drains recognition and closes streams once', () async {
      final harness = _SpeechHarness();
      final changesDone = Completer<void>();
      harness.input.changes.listen((_) {}, onDone: changesDone.complete);
      await harness.input.start();
      harness.recorder.push(
        _pcm16(List<int>.filled(speechMinimumSamples, 100)),
      );
      final recognizeGate = Completer<void>();
      harness.recognizer.recognizeGate = recognizeGate;
      final finishing = harness.input.finish();
      await harness.recognizer.recognizeEntered.future;

      final closing = harness.input.close();
      final secondClose = harness.input.close();
      recognizeGate.complete();
      await finishing;
      await closing;
      await secondClose;
      await changesDone.future;
      await harness.input.close();

      expect(harness.input.view.phase, SpeechInputPhase.closed);
      expect(harness.input.view.transcript, isNull);
      expect(harness.recorder.closeCalls, 1);
      expect(harness.recognizer.closeCalls, 1);
      await harness.disposeRecorder();
    });

    test('close failure is retryable; idle close does not capture', () async {
      final harness = _SpeechHarness();
      addTearDown(harness.close);

      expect(harness.input.view.phase, SpeechInputPhase.idle);
      expect(harness.recorder.permissionCalls, 0);
      expect(harness.recorder.startCalls, 0);
      expect(harness.recognizer.prepareCalls, 0);
      harness.recorder.closeError = StateError('CLOSE-SENTINEL');
      await _expectFailure(
        harness.input.close,
        SpeechInputFailureCode.cleanupFailed,
      );
      expect(harness.input.view.phase, SpeechInputPhase.recovery);
      expect(harness.recorder.startCalls, 0);
      expect(harness.recognizer.prepareCalls, 0);

      harness.recorder.closeError = null;
      await harness.input.close();
      expect(harness.input.view.phase, SpeechInputPhase.closed);
      expect(harness.recorder.closeCalls, 2);
      expect(harness.recognizer.closeCalls, 1);
      expect(harness.recorder.startCalls, 0);
      expect(harness.recognizer.prepareCalls, 0);
    });

    test('diagnostics include fixed metadata only', () async {
      final harness = _SpeechHarness();
      addTearDown(harness.close);
      await harness.input.start();
      harness.recorder.push(
        _pcm16(List<int>.filled(speechMinimumSamples, 100)),
      );
      harness.recognizer.result = 'TRANSCRIPT-SENTINEL';
      await harness.input.finish();

      await harness.input.start();
      harness.recorder.push(
        _pcm16(List<int>.filled(speechMinimumSamples, 100)),
      );
      harness.recognizer.recognizeError = StateError(
        'EXCEPTION-SENTINEL DEVICE-SERIAL-SENTINEL',
      );
      await harness.input.finish();

      final encoded = harness.diagnostics.events
          .map(
            (event) => DiagnosticRecord(
              atUtc: DateTime.utc(2026, 10, 14),
              event: event,
            ).encode(),
          )
          .join('\n');
      for (final sentinel in [
        'TRANSCRIPT-SENTINEL',
        'EXCEPTION-SENTINEL',
        'DEVICE-SERIAL-SENTINEL',
        'BUSINESS-ID-SENTINEL',
        'OWNER-ID-SENTINEL',
      ]) {
        expect(encoded, isNot(contains(sentinel)));
      }
      expect(harness.diagnostics.events, isNotEmpty);
      expect(
        harness.diagnostics.events
            .where((event) => event.phase == DiagnosticPhase.recognizing)
            .map((event) => event.count),
        [speechMinimumSamples, speechMinimumSamples],
      );
      for (final event in harness.diagnostics.events) {
        expect(event.name, DiagnosticEventName.speechInputStage);
        expect(event.stage, DiagnosticStage.speechInput);
        expect(event.phase, isNotNull);
        expect(event.outcome, isNotNull);
        expect(event.count, isA<int>());
        expect(event.trace?.value, _SpeechDiagnostics.traceValue);
        expect(event.issue, isNull);
        expect(event.modelCalls, isNull);
        expect(event.toolCalls, isNull);
        expect(event.httpStatus, isNull);
      }
      final decoded =
          jsonDecode(encoded.split('\n').last) as Map<String, Object?>;
      expect(
        decoded.keys.toSet(),
        containsAll({
          'event',
          'trace',
          'stage',
          'phase',
          'outcome',
          'code',
          'count',
        }),
      );
      expect(decoded.keys, isNot(contains('message')));
      expect(decoded.keys, isNot(contains('transcript')));
      expect(decoded.keys, isNot(contains('audio')));
      expect(
        harness.input.view.failure,
        SpeechInputFailureCode.recognitionFailed,
      );
    });
  });
}

void _expectViewFailure(OfflineSpeechInput input, SpeechInputFailureCode code) {
  expect(input.view.phase, SpeechInputPhase.idle);
  expect(input.view.failure, code);
  expect(input.view.transcript, isNull);
}

Future<void> _expectFailure(
  Future<void> Function() action,
  SpeechInputFailureCode code,
) async {
  Object? caught;
  try {
    await action();
  } on SpeechInputFailure catch (error) {
    caught = error;
  }
  expect(
    caught,
    isA<SpeechInputFailure>().having((failure) => failure.code, 'code', code),
  );
}

Uint8List _pcm16(List<int> samples) {
  final bytes = Uint8List(samples.length * 2);
  final data = ByteData.sublistView(bytes);
  for (var index = 0; index < samples.length; index++) {
    data.setInt16(index * 2, samples[index], Endian.little);
  }
  return bytes;
}

List<Uint8List> _oddSizedChunks(Uint8List pcm) {
  final chunks = <Uint8List>[];
  var offset = 0;
  const sizes = [3, 5, 7, 1, 9];
  var index = 0;
  while (offset < pcm.length) {
    final remaining = pcm.length - offset;
    var length = sizes[index++ % sizes.length];
    if (length > remaining) length = remaining;
    chunks.add(Uint8List.sublistView(pcm, offset, offset + length));
    offset += length;
  }
  return chunks;
}

final class _SpeechHarness {
  _SpeechHarness({bool singleSubscriptionRecorder = false})
    : recorder = _FakeSpeechRecorder(
        singleSubscription: singleSubscriptionRecorder,
      ) {
    input = OfflineSpeechInput(
      recorder: recorder,
      recognizer: recognizer,
      diagnostics: diagnostics,
    );
  }

  final _FakeSpeechRecorder recorder;
  final _FakeSpeechRecognizer recognizer = _FakeSpeechRecognizer();
  final _SpeechDiagnostics diagnostics = _SpeechDiagnostics();
  late final OfflineSpeechInput input;

  Future<void> close() async {
    try {
      await input.close();
    } catch (_) {
      // A test can deliberately exercise a retryable close failure.
    }
    await disposeRecorder();
  }

  Future<void> disposeRecorder() async {
    if (!recorder.source.isClosed) await recorder.source.close();
  }
}

final class _FakeSpeechRecorder implements SpeechRecorderPort {
  _FakeSpeechRecorder({bool singleSubscription = false}) {
    if (singleSubscription) {
      source = StreamController<Uint8List>(
        sync: true,
        onListen: () {
          sourceListenCalls++;
        },
        onCancel: () async {
          sourceCancelCalls++;
        },
      );
    } else {
      source = StreamController<Uint8List>.broadcast(
        sync: true,
        onListen: () {
          sourceListenCalls++;
        },
        onCancel: () {
          sourceCancelCalls++;
        },
      );
    }
  }

  late final StreamController<Uint8List> source;
  bool permissionGranted = true;
  Object? startError, stopError, closeError;
  int permissionCalls = 0,
      startCalls = 0,
      stopCalls = 0,
      closeCalls = 0,
      sourceListenCalls = 0,
      sourceCancelCalls = 0;

  void push(Uint8List bytes) => source.add(bytes);

  void fail(Object error) => source.addError(error);

  @override
  Future<bool> hasPermission() async {
    permissionCalls++;
    return permissionGranted;
  }

  @override
  Future<Stream<Uint8List>> start() async {
    startCalls++;
    final error = startError;
    if (error != null) throw error;
    return source.stream;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    if (!stopEntered.isCompleted) stopEntered.complete();
    final gate = stopGate;
    if (gate != null) await gate.future;
    final error = stopError;
    if (error != null) throw error;
  }

  @override
  Future<void> close() async {
    closeCalls++;
    final error = closeError;
    if (error != null) throw error;
    if (!source.isClosed) await source.close();
  }

  Completer<void>? stopGate;
  final Completer<void> stopEntered = Completer<void>();
}

final class _FakeSpeechRecognizer implements SpeechRecognizerPort {
  Object? prepareError, recognizeError;
  String result = '合成转写';
  Completer<void>? prepareGate, recognizeGate;
  final Completer<void> prepareEntered = Completer<void>();
  final Completer<void> recognizeEntered = Completer<void>();
  int prepareCalls = 0, recognizeCalls = 0, closeCalls = 0;
  List<double>? sampleValues;
  Float32List? lastSamples;
  int receivedSampleCount = 0;

  @override
  Future<void> prepare() async {
    prepareCalls++;
    if (!prepareEntered.isCompleted) prepareEntered.complete();
    final gate = prepareGate;
    if (gate != null) await gate.future;
    final error = prepareError;
    if (error != null) throw error;
  }

  @override
  Future<String> recognize(Float32List samples) async {
    recognizeCalls++;
    lastSamples = samples;
    sampleValues = samples.map((sample) => sample.toDouble()).toList();
    receivedSampleCount = samples.length;
    if (!recognizeEntered.isCompleted) recognizeEntered.complete();
    final gate = recognizeGate;
    if (gate != null) await gate.future;
    final error = recognizeError;
    if (error != null) throw error;
    return result;
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

final class _SpeechDiagnostics implements DiagnosticsPort {
  static const traceValue = '0123456789abcdef0123456789abcdef';
  final List<DiagnosticEvent> events = [];

  @override
  DiagnosticsView get diagnosticsView => const DiagnosticsView(available: true);

  @override
  DiagnosticTrace newTrace() => DiagnosticTrace(traceValue);

  @override
  void record(DiagnosticEvent event) => events.add(event);

  @override
  Future<void> flush() async {}

  @override
  Future<String> exportRecent() async => '';

  @override
  Future<void> clear() async {}

  @override
  Future<void> close() async {}
}
