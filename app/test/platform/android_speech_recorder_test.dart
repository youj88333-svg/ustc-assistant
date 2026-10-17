import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';
import 'package:ustc_assistant_m0/platform/android_speech_recorder.dart';
import 'package:ustc_assistant_m0/platform/speech_audio_recorder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AndroidSpeechRecorder', () {
    test('waits for permission dialog inactive to return resumed', () async {
      _setLifecycle(AppLifecycleState.resumed);
      final backend = _FakeBackend()..permissionGate = Completer<bool>();
      final recorder = AndroidSpeechRecorder(
        backendFactory: () => backend,
        permissionResumeTimeout: const Duration(seconds: 1),
      );

      final permission = recorder.hasPermission();
      await backend.permissionEntered.future;
      _setLifecycle(AppLifecycleState.inactive);
      backend.permissionGate!.complete(true);
      await Future<void>.delayed(Duration.zero);
      var permissionReturned = false;
      permission.then((_) => permissionReturned = true);
      await Future<void>.delayed(Duration.zero);
      expect(permissionReturned, isFalse);

      _setLifecycle(AppLifecycleState.resumed);
      expect(await permission, isTrue);
      expect(backend.calls, ['hasPermission']);
      await recorder.close();
    });

    test('hidden or paused permission return cannot authorize start', () async {
      _setLifecycle(AppLifecycleState.resumed);
      final backend = _FakeBackend()..permissionGate = Completer<bool>();
      final recorder = AndroidSpeechRecorder(backendFactory: () => backend);

      final permission = recorder.hasPermission();
      await backend.permissionEntered.future;
      _setLifecycle(AppLifecycleState.inactive);
      _setLifecycle(AppLifecycleState.paused);
      backend.permissionGate!.complete(true);

      expect(await permission, isFalse);
      _setLifecycle(AppLifecycleState.resumed);
      await _expectFailure(
        recorder.start(),
        SpeechInputFailureCode.permissionDenied,
      );
      expect(backend.calls, ['hasPermission']);

      // A later explicit preflight can authorize a new foreground attempt.
      expect(await recorder.hasPermission(), isTrue);
      final stream = await recorder.start();
      expect(backend.configs.single.device, isNull);
      expect(
        backend.configs.single.audioInterruption,
        AudioInterruptionMode.pause,
      );
      expect(backend.configs.single.androidConfig.manageBluetooth, isFalse);
      await stream.listen((_) {}).cancel();
      await recorder.close();
    });

    test(
      'background competition during start drains before returning',
      () async {
        _setLifecycle(AppLifecycleState.resumed);
        final backend = _FakeBackend()
          ..startGate = Completer<Stream<Uint8List>>();
        final recorder = AndroidSpeechRecorder(backendFactory: () => backend);

        expect(await recorder.hasPermission(), isTrue);
        final starting = recorder.start();
        await backend.startEntered.future;
        _setLifecycle(AppLifecycleState.paused);
        _setLifecycle(AppLifecycleState.resumed);
        backend.startGate!.complete(backend.source.stream);

        await _expectFailure(
          starting,
          SpeechInputFailureCode.microphoneUnavailable,
        );
        expect(backend.calls, ['hasPermission', 'startStream', 'stop']);
        await recorder.close();
        expect(backend.calls, [
          'hasPermission',
          'startStream',
          'stop',
          'dispose',
        ]);
      },
    );

    test('permission request from background does not touch plugin', () async {
      _setLifecycle(AppLifecycleState.paused);
      final backend = _FakeBackend();
      final recorder = AndroidSpeechRecorder(backendFactory: () => backend);

      expect(await recorder.hasPermission(), isFalse);
      expect(backend.calls, isEmpty);
      await recorder.close();
      expect(backend.calls, isEmpty);
    });
  });
}

void _setLifecycle(AppLifecycleState state) {
  final binding = TestWidgetsFlutterBinding.instance;
  final current = binding.lifecycleState;
  if (current == state) return;
  final transitions = switch ((current, state)) {
    (AppLifecycleState.resumed, AppLifecycleState.paused) => [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ],
    (AppLifecycleState.paused, AppLifecycleState.resumed) => [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ],
    (AppLifecycleState.inactive, AppLifecycleState.paused) => [
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ],
    (AppLifecycleState.paused, AppLifecycleState.inactive) => [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
    ],
    (AppLifecycleState.resumed, AppLifecycleState.hidden) => [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
    ],
    (AppLifecycleState.hidden, AppLifecycleState.resumed) => [
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ],
    _ => [state],
  };
  for (final next in transitions) {
    binding.handleAppLifecycleStateChanged(next);
  }
}

Future<void> _expectFailure(
  Future<dynamic> future,
  SpeechInputFailureCode code,
) async {
  await expectLater(
    future,
    throwsA(
      isA<SpeechInputFailure>().having((failure) => failure.code, 'code', code),
    ),
  );
}

final class _FakeBackend
    implements SpeechAudioRecorderBackend, SpeechAudioRecorderStateBackend {
  Completer<bool>? permissionGate;
  Completer<Stream<Uint8List>>? startGate;
  final Completer<void> permissionEntered = Completer<void>();
  final Completer<void> startEntered = Completer<void>();
  final StreamController<Uint8List> source =
      StreamController<Uint8List>.broadcast();
  final StreamController<RecordState> states =
      StreamController<RecordState>.broadcast();
  final List<String> calls = [];
  final List<RecordConfig> configs = [];

  @override
  Future<bool> hasPermission({required bool request}) {
    calls.add('hasPermission');
    if (!permissionEntered.isCompleted) permissionEntered.complete();
    return permissionGate?.future ?? Future<bool>.value(true);
  }

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    calls.add('startStream');
    configs.add(config);
    if (!startEntered.isCompleted) startEntered.complete();
    final gate = startGate;
    return gate == null ? source.stream : await gate.future;
  }

  @override
  Stream<RecordState> onStateChanged() => states.stream;

  @override
  Future<void> stop() async {
    calls.add('stop');
    if (states.hasListener) states.add(RecordState.stop);
    if (!source.isClosed) await source.close();
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    if (!states.isClosed) await states.close();
    if (!source.isClosed) await source.close();
  }
}
