import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';
import 'package:ustc_assistant_m0/platform/speech_audio_recorder.dart';

void main() {
  group('SpeechAudioRecorder', () {
    test('uses fixed in-memory mono PCM16 at 16 kHz', () async {
      final backend = _FakeBackend();
      final recorder = SpeechAudioRecorder(backendFactory: () => backend);

      final stream = await recorder.start();
      final received = <Uint8List>[];
      final streamDone = Completer<void>();
      stream.listen(received.add, onDone: streamDone.complete);
      backend.source.add(Uint8List.fromList([1, 2, 3, 4]));
      await Future<void>.delayed(Duration.zero);

      expect(backend.configs, hasLength(1));
      final config = backend.configs.single;
      expect(config.encoder, AudioEncoder.pcm16bits);
      expect(config.sampleRate, speechSampleRate);
      expect(config.numChannels, 1);
      expect(config.device, isNull);
      expect(config.autoGain, isFalse);
      expect(config.echoCancel, isFalse);
      expect(config.noiseSuppress, isFalse);
      expect(received.single, [1, 2, 3, 4]);
      expect(backend.calls, ['startStream']);

      await recorder.close();
      await streamDone.future;
      await recorder.close();
      expect(backend.calls, ['startStream', 'stop', 'dispose']);
    });

    test(
      'Android interruption config pauses without Bluetooth management',
      () async {
        final backend = _FakeBackend();
        final recorder = SpeechAudioRecorder(
          backendFactory: () => backend,
          inputDeviceResolver: () async => null,
          cancelOnInterruption: true,
          androidManageBluetooth: false,
        );

        await recorder.start();

        final config = backend.configs.single;
        expect(config.audioInterruption, AudioInterruptionMode.pause);
        expect(config.androidConfig.manageBluetooth, isFalse);
        expect(config.device, isNull);
        await recorder.close();
      },
    );

    test(
      'returns a denied permission result without starting capture',
      () async {
        final backend = _FakeBackend()..permissionGranted = false;
        final recorder = SpeechAudioRecorder(backendFactory: () => backend);

        expect(await recorder.hasPermission(), isFalse);
        expect(backend.permissionRequests, [true]);
        expect(backend.calls, ['hasPermission']);
        await _expectFailure(
          recorder.start(),
          SpeechInputFailureCode.permissionDenied,
        );
        expect(backend.calls, ['hasPermission']);

        await recorder.close();
        expect(backend.calls, ['hasPermission', 'dispose']);
      },
    );

    test(
      'idle close is lazy, idempotent, and prevents a later start',
      () async {
        final backend = _FakeBackend();
        var factoryCalls = 0;
        final recorder = SpeechAudioRecorder(
          backendFactory: () {
            factoryCalls++;
            return backend;
          },
        );

        await recorder.close();
        await recorder.close();

        expect(factoryCalls, 0);
        expect(backend.calls, isEmpty);
        await _expectFailure(recorder.start(), SpeechInputFailureCode.closed);
      },
    );

    test('rejects a second start and closes once', () async {
      final backend = _FakeBackend();
      final recorder = SpeechAudioRecorder(backendFactory: () => backend);

      await recorder.start();
      await _expectFailure(recorder.start(), SpeechInputFailureCode.busy);
      await recorder.close();
      await recorder.close();

      expect(backend.calls, ['startStream', 'stop', 'dispose']);
    });

    test('selects the ordinary default input only on start', () async {
      final backend = _FakeBackend();
      var selections = 0;
      final recorder = SpeechAudioRecorder(
        backendFactory: () => backend,
        inputDeviceResolver: () async {
          selections++;
          return const InputDevice(id: 'synthetic-endpoint', label: '系统默认输入');
        },
      );
      expect(selections, 0);
      expect(await recorder.hasPermission(), isTrue);
      expect(selections, 0);
      await recorder.start();
      expect(selections, 1);
      expect(backend.configs.single.device!.id, 'synthetic-endpoint');
      expect(backend.configs.single.toMap()['device'], {
        'id': 'synthetic-endpoint',
        'label': '系统默认输入',
        'type': 'unknown',
      });
      await recorder.close();
    });

    test('unavailable default input fails before opening capture', () async {
      final backend = _FakeBackend();
      final recorder = SpeechAudioRecorder(
        backendFactory: () => backend,
        inputDeviceResolver: () async => throw StateError('private-device-id'),
      );
      await _expectFailure(
        recorder.start(),
        SpeechInputFailureCode.microphoneUnavailable,
        forbiddenText: 'private-device-id',
      );
      expect(backend.configs, isEmpty);
      expect(backend.calls, isEmpty);
      await recorder.close();
    });

    test('stop during default input selection prevents capture', () async {
      final backend = _FakeBackend();
      final selection = Completer<InputDevice?>();
      final selected = Completer<void>();
      final recorder = SpeechAudioRecorder(
        backendFactory: () => backend,
        inputDeviceResolver: () {
          selected.complete();
          return selection.future;
        },
      );
      final starting = recorder.start();
      await selected.future;
      final stopping = recorder.stop();
      selection.complete(
        const InputDevice(id: 'synthetic-endpoint', label: '系统默认输入'),
      );
      await stopping;
      expect(await (await starting).toList(), isEmpty);
      expect(backend.configs, isEmpty);
      expect(backend.calls, isEmpty);
      await recorder.close();
    });

    test(
      'stop during preparation drains the late stream before returning',
      () async {
        final backend = _FakeBackend()
          ..startGate = Completer<Stream<Uint8List>>();
        final stopGate = Completer<void>();
        backend.stopGate = stopGate;
        final recorder = SpeechAudioRecorder(backendFactory: () => backend);

        var startCompleted = false;
        final starting = recorder.start()..then((_) => startCompleted = true);
        await backend.startEntered.future;
        final stopping = recorder.stop();
        backend.startGate!.complete(backend.source.stream);
        await backend.stopEntered.future;
        backend.source.add(Uint8List.fromList([9, 8, 7, 6]));
        await Future<void>.delayed(Duration.zero);

        expect(startCompleted, isFalse);
        stopGate.complete();
        await stopping;
        final stream = await starting;
        final received = <Uint8List>[];
        final subscription = stream.listen(received.add);
        await Future<void>.delayed(Duration.zero);
        await subscription.cancel();

        expect(received, isEmpty);
        expect(backend.calls, ['startStream', 'stop']);
        await recorder.close();
        expect(backend.calls, ['startStream', 'stop', 'dispose']);
      },
    );

    test(
      'close during preparation stops and disposes before start resolves',
      () async {
        final backend = _FakeBackend()
          ..startGate = Completer<Stream<Uint8List>>();
        final recorder = SpeechAudioRecorder(backendFactory: () => backend);

        final starting = recorder.start();
        await backend.startEntered.future;
        final closing = recorder.close();
        backend.startGate!.complete(backend.source.stream);

        await closing;
        final stream = await starting;
        final received = <Uint8List>[];
        final subscription = stream.listen(received.add);
        await Future<void>.delayed(Duration.zero);
        await subscription.cancel();
        expect(received, isEmpty);
        expect(backend.calls, ['startStream', 'stop', 'dispose']);
        await _expectFailure(recorder.start(), SpeechInputFailureCode.closed);
      },
    );

    test(
      'start failures expose fixed codes and clean up a partial start',
      () async {
        final backend = _FakeBackend()
          ..startError = StateError('microphone device SECRET-123');
        final recorder = SpeechAudioRecorder(backendFactory: () => backend);

        await _expectFailure(
          recorder.start(),
          SpeechInputFailureCode.microphoneUnavailable,
          forbiddenText: 'SECRET-123',
        );
        expect(backend.calls, ['startStream', 'stop']);
        await recorder.close();
        expect(backend.calls, ['startStream', 'stop', 'dispose']);
      },
    );

    test(
      'failed stop can be retried without exposing backend errors',
      () async {
        final backend = _FakeBackend()
          ..stopError = StateError('device SECRET-456');
        final recorder = SpeechAudioRecorder(backendFactory: () => backend);

        final stream = await recorder.start();
        final received = <Uint8List>[];
        final streamDone = Completer<void>();
        stream.listen(received.add, onDone: streamDone.complete);
        backend.stopGate = Completer<void>();
        final stopping = recorder.stop();
        await backend.stopEntered.future;
        backend.source.add(Uint8List.fromList([1, 1]));
        await Future<void>.delayed(Duration.zero);
        expect(received, [
          [1, 1],
        ]);
        backend.stopGate!.complete();
        await _expectFailure(
          stopping,
          SpeechInputFailureCode.cleanupFailed,
          forbiddenText: 'SECRET-456',
        );

        backend.stopError = null;
        await recorder.stop();
        await streamDone.future;
        expect(backend.calls, ['startStream', 'stop', 'stop']);
        await recorder.close();
        expect(backend.calls, ['startStream', 'stop', 'stop', 'dispose']);
      },
    );

    test(
      'failed dispose remains retryable and does not report closed',
      () async {
        final backend = _FakeBackend()
          ..disposeError = StateError('device SECRET-789');
        final recorder = SpeechAudioRecorder(backendFactory: () => backend);
        expect(await recorder.hasPermission(), isTrue);

        await _expectFailure(
          recorder.close(),
          SpeechInputFailureCode.cleanupFailed,
          forbiddenText: 'SECRET-789',
        );
        backend.disposeError = null;
        await recorder.close();
        await recorder.close();

        expect(backend.calls, ['hasPermission', 'dispose', 'dispose']);
        await _expectFailure(recorder.start(), SpeechInputFailureCode.closed);
      },
    );

    test('forwards PCM that arrives while a normal stop drains', () async {
      final backend = _FakeBackend();
      final recorder = SpeechAudioRecorder(backendFactory: () => backend);

      final stream = await recorder.start();
      final received = <Uint8List>[];
      final streamDone = Completer<void>();
      stream.listen(received.add, onDone: streamDone.complete);
      backend.source.add(Uint8List.fromList([1, 2]));
      await Future<void>.delayed(Duration.zero);

      backend.stopFrames = [
        Uint8List.fromList([3, 4]),
        Uint8List.fromList([5, 6]),
      ];
      await recorder.stop();
      await streamDone.future;

      expect(received, [
        [1, 2],
        [3, 4],
        [5, 6],
      ]);
      await recorder.close();
    });

    for (final interruptState in [RecordState.pause, RecordState.stop]) {
      test(
        'terminates input on plugin $interruptState without resuming',
        () async {
          final backend = _FakeBackend();
          final recorder = SpeechAudioRecorder(
            backendFactory: () => backend,
            cancelOnInterruption: true,
          );
          final stream = await recorder.start();
          final received = <Uint8List>[];
          final errors = <Object>[];
          final streamDone = Completer<void>();
          stream.listen(
            received.add,
            onError: (Object error, StackTrace _) => errors.add(error),
            onDone: streamDone.complete,
          );
          backend.source.add(Uint8List.fromList([1, 2]));
          await Future<void>.delayed(Duration.zero);

          backend.states.add(interruptState);
          await Future<void>.delayed(Duration.zero);
          backend.states.add(RecordState.record);
          backend.source.add(Uint8List.fromList([3, 4]));
          await streamDone.future;

          expect(received, [
            [1, 2],
          ]);
          expect(errors, hasLength(1));
          expect(errors.single, isA<SpeechInputFailure>());
          expect(
            (errors.single as SpeechInputFailure).code,
            SpeechInputFailureCode.microphoneUnavailable,
          );
          expect(
            errors.single.toString(),
            'SpeechInputFailure(microphoneUnavailable)',
          );

          await recorder.stop();
          expect(backend.states.hasListener, isFalse);
          await recorder.close();
          expect(backend.calls, ['startStream', 'stop', 'dispose']);
        },
      );
    }

    test(
      'state stream errors terminate with a fixed microphone failure',
      () async {
        final backend = _FakeBackend();
        final recorder = SpeechAudioRecorder(
          backendFactory: () => backend,
          cancelOnInterruption: true,
        );
        final stream = await recorder.start();
        final errors = <Object>[];
        final streamDone = Completer<void>();
        stream.listen(
          (_) {},
          onError: (Object error, StackTrace _) => errors.add(error),
          onDone: streamDone.complete,
        );

        backend.states.addError(StateError('private platform detail'));
        await streamDone.future;
        expect(errors, hasLength(1));
        expect(errors.single, isA<SpeechInputFailure>());
        expect(
          errors.single.toString(),
          'SpeechInputFailure(microphoneUnavailable)',
        );

        await recorder.stop();
        await recorder.close();
      },
    );

    test(
      'normal Android stop keeps tail frames and ignores its own stop state',
      () async {
        final backend = _FakeBackend();
        final recorder = SpeechAudioRecorder(
          backendFactory: () => backend,
          cancelOnInterruption: true,
        );
        final stream = await recorder.start();
        final received = <Uint8List>[];
        final errors = <Object>[];
        final streamDone = Completer<void>();
        stream.listen(
          received.add,
          onError: (Object error, StackTrace _) => errors.add(error),
          onDone: streamDone.complete,
        );
        backend.source.add(Uint8List.fromList([1, 2]));
        await Future<void>.delayed(Duration.zero);
        backend.stopFrames = [
          Uint8List.fromList([3, 4]),
        ];

        await recorder.stop();
        await streamDone.future;

        expect(received, [
          [1, 2],
          [3, 4],
        ]);
        expect(errors, isEmpty);
        expect(backend.states.hasListener, isFalse);
        backend.states.add(
          RecordState.pause,
        ); // A late state cannot reopen or fail it.
        await recorder.close();
      },
    );
  });
}

Future<void> _expectFailure(
  Future<dynamic> future,
  SpeechInputFailureCode code, {
  String? forbiddenText,
}) async {
  final safeTextMatcher = forbiddenText == null
      ? contains('SpeechInputFailure')
      : allOf(contains('SpeechInputFailure'), isNot(contains(forbiddenText)));
  await expectLater(
    future,
    throwsA(
      isA<SpeechInputFailure>()
          .having((failure) => failure.code, 'code', code)
          .having(
            (failure) => failure.toString(),
            'safe error text',
            safeTextMatcher,
          ),
    ),
  );
}

final class _FakeBackend
    implements SpeechAudioRecorderBackend, SpeechAudioRecorderStateBackend {
  bool permissionGranted = true;
  Object? startError;
  Object? stopError;
  Object? disposeError;
  List<Uint8List> stopFrames = const [];
  Completer<Stream<Uint8List>>? startGate;
  Completer<void>? stopGate;
  final Completer<void> startEntered = Completer<void>();
  final Completer<void> stopEntered = Completer<void>();
  final StreamController<Uint8List> source =
      StreamController<Uint8List>.broadcast();
  final StreamController<RecordState> states =
      StreamController<RecordState>.broadcast();
  final List<String> calls = [];
  final List<bool> permissionRequests = [];
  final List<RecordConfig> configs = [];

  @override
  Future<bool> hasPermission({required bool request}) async {
    calls.add('hasPermission');
    permissionRequests.add(request);
    return permissionGranted;
  }

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    calls.add('startStream');
    configs.add(config);
    if (!startEntered.isCompleted) startEntered.complete();
    final gate = startGate;
    if (gate != null) return gate.future;
    final error = startError;
    if (error != null) throw error;
    return source.stream;
  }

  @override
  Stream<RecordState> onStateChanged() => states.stream;

  @override
  Future<void> stop() async {
    calls.add('stop');
    if (!stopEntered.isCompleted) stopEntered.complete();
    if (states.hasListener) states.add(RecordState.stop);
    final gate = stopGate;
    if (gate != null) await gate.future;
    final error = stopError;
    if (error != null) throw error;
    for (final frame in stopFrames) {
      source.add(frame);
    }
    if (!source.isClosed) await source.close();
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    final error = disposeError;
    if (error != null) throw error;
    if (!states.isClosed) await states.close();
    if (!source.isClosed) await source.close();
  }
}
