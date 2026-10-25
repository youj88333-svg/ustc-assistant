import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';
import 'package:ustc_assistant_m0/platform/offline_speech_input.dart';
import 'package:ustc_assistant_m0/platform/speech_audio_recorder.dart';

void main() {
  group('synthetic Windows speech capture contract', () {
    test('preserves little-endian mono PCM through stop drain', () async {
      final samples =
          List<int>.generate(
              speechMinimumSamples,
              (index) => (index * 97 + 1234) % 20001 - 10000,
            )
            ..[0] = -32768
            ..[1] = -1
            ..[2] = 0
            ..[3] = 1
            ..[4] = 32767;
      final pcm = _encodePcm16(samples);
      const splitAt = 27;
      final backend = _SyntheticBackend()
        ..stopFrames = _frames(pcm, splitAt, [511, 1024, 2049]);
      final recorder = SpeechAudioRecorder(backendFactory: () => backend);
      final recognizer = _CapturingRecognizer();
      final input = OfflineSpeechInput(
        recorder: recorder,
        recognizer: recognizer,
      );
      addTearDown(input.close);

      await input.start();
      backend.source.add(Uint8List.sublistView(pcm, 0, splitAt));
      await input.finish();

      final config = backend.configs.single;
      expect(config.encoder, AudioEncoder.pcm16bits);
      expect(config.sampleRate, speechSampleRate);
      expect(config.numChannels, 1);
      expect(config.device, isNull);
      expect(config.autoGain, isFalse);
      expect(config.echoCancel, isFalse);
      expect(config.noiseSuppress, isFalse);
      expect(recognizer.samples, isNotNull);
      expect(recognizer.samples, hasLength(speechMinimumSamples));
      expect(recognizer.samples!.take(5).toList(), [
        -1,
        -1 / 32768,
        0,
        1 / 32768,
        32767 / 32768,
      ]);
      expect(
        recognizer.samples!.skip(5).toList(),
        samples.skip(5).map((value) => value / 32768).toList(),
      );
      expect(input.view.transcript?.text, '合成捕获已完整送达');
      expect(backend.stopCalls, 1);
    });

    test(
      'stop cleanup failure cannot produce a transcript or expose details',
      () async {
        final backend = _SyntheticBackend()
          ..stopError = StateError('microphone SECRET-321');
        final recorder = SpeechAudioRecorder(backendFactory: () => backend);
        final recognizer = _CapturingRecognizer();
        final input = OfflineSpeechInput(
          recorder: recorder,
          recognizer: recognizer,
        );
        addTearDown(() async {
          backend.stopError = null;
          await input.close();
        });

        await input.start();
        backend.source.add(
          _encodePcm16(List<int>.filled(speechMinimumSamples, 1200)),
        );
        await input.finish();

        expect(input.view.phase, SpeechInputPhase.recovery);
        expect(input.view.failure, SpeechInputFailureCode.cleanupFailed);
        expect(input.view.transcript, isNull);
        expect(recognizer.recognizeCalls, 0);
        expect(input.view.toString(), isNot(contains('SECRET-321')));
      },
    );
  });
}

Uint8List _encodePcm16(List<int> samples) {
  final bytes = Uint8List(samples.length * 2);
  final data = ByteData.sublistView(bytes);
  for (var index = 0; index < samples.length; index++) {
    data.setInt16(index * 2, samples[index], Endian.little);
  }
  return bytes;
}

List<Uint8List> _frames(Uint8List bytes, int firstSplit, List<int> sizes) {
  final result = <Uint8List>[];
  var offset = firstSplit;
  for (final size in sizes) {
    if (offset >= bytes.length) break;
    final candidate = offset + size;
    final end = candidate < bytes.length ? candidate : bytes.length;
    result.add(Uint8List.sublistView(bytes, offset, end));
    offset = end;
  }
  if (offset < bytes.length) {
    result.add(Uint8List.sublistView(bytes, offset));
  }
  return result;
}

final class _SyntheticBackend implements SpeechAudioRecorderBackend {
  final StreamController<Uint8List> source =
      StreamController<Uint8List>.broadcast(sync: true);
  final List<RecordConfig> configs = [];
  List<Uint8List> stopFrames = const [];
  Object? stopError;
  int stopCalls = 0;

  @override
  Future<bool> hasPermission({required bool request}) async => true;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    configs.add(config);
    return source.stream;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    final error = stopError;
    if (error != null) throw error;
    for (final frame in stopFrames) {
      source.add(frame);
    }
    if (!source.isClosed) await source.close();
  }

  @override
  Future<void> dispose() async {}
}

final class _CapturingRecognizer implements SpeechRecognizerPort {
  Float32List? samples;
  int recognizeCalls = 0;

  @override
  Future<void> prepare() async {}

  @override
  Future<String> recognize(Float32List samples) async {
    recognizeCalls++;
    this.samples = Float32List.fromList(samples);
    return '合成捕获已完整送达';
  }

  @override
  Future<void> close() async {}
}
