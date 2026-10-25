// A6: fixed synthetic WAV, real bundled Android ASR, actual composer/runtime.
// Never creates AudioRecorder or opens a microphone; no school/model traffic.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:record/record.dart';
import 'package:ustc_assistant_m0/app/agent_workspace_page.dart';
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';
import 'package:ustc_assistant_m0/platform/android_directory.dart';
import 'package:ustc_assistant_m0/platform/android_speech_model.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/offline_speech_input.dart';
import 'package:ustc_assistant_m0/platform/runtime_platform_factory.dart';
import 'package:ustc_assistant_m0/platform/sense_voice_recognizer.dart';
import 'package:ustc_assistant_m0/platform/speech_audio_recorder.dart';
import 'package:ustc_assistant_m0/platform/unavailable_mobile_services.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'bundled Chinese ASR fills an editable Android draft without sending',
    (tester) async {
      final previous = HttpOverrides.current;
      final network = _NoNetwork();
      HttpOverrides.global = network;
      RuntimeBootstrap? bootstrap;
      Directory? fixture;
      Uint8List? pcm;
      try {
        late String root;
        await tester.runAsync(() async {
          root = (await const MethodChannel(
            'ustc_assistant/platform_v1',
          ).invokeMethod<String>('privateDataRoot'))!;
          expect(root, contains('/cn.ustcassistant.mobile.qa/no_backup/'));
          fixture = await Directory(root).createTemp('a6_runtime_');
          final wav = File('$root/a6-synthetic.wav');
          expect(await wav.length(), lessThan(1000000));
          final bytes = await wav.readAsBytes();
          pcm = _parseWav(bytes);
          bytes.fillRange(0, bytes.length, 0);
        });
        final backend = _SyntheticBackend(pcm!);
        final recognizer = _TimedRecognizer(
          SenseVoiceRecognizer(
            bundleLoader: const AndroidSpeechModel().prepare,
          ),
        );
        final input = OfflineSpeechInput(
          recorder: SpeechAudioRecorder(
            backendFactory: () => backend,
            inputDeviceResolver: () async => null,
          ),
          recognizer: recognizer,
          permissionFirst: true,
        );
        await tester.runAsync(() async {
          bootstrap = await RuntimeBootstrap.open(
            platformFactory: _FixturePlatform(fixture!.path),
            speechInput: input,
          );
          expect(bootstrap!.runtime, isNotNull);
        });
        final runtime = bootstrap!.runtime!;
        expect(runtime.agent.view.settings!.keySaved, isFalse);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AgentWorkspacePage(
                controller: runtime.agent,
                speechInput: input,
                onSettings: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final composer = find.byKey(const ValueKey('agent-composer'));
        final controller = tester.widget<TextField>(composer).controller!;
        controller.value = const TextEditingValue(
          text: '前文后文',
          selection: TextSelection.collapsed(offset: 2),
        );
        final initialRss = ProcessInfo.currentRss;
        for (var pass = 0; pass < 2; pass++) {
          await tester.tap(find.byKey(const ValueKey('agent-speech-toggle')));
          await _waitFor(
            tester,
            () =>
                input.view.phase == SpeechInputPhase.recording ||
                input.view.failure != null,
          );
          expect(
            input.view.failure,
            isNull,
            reason: 'fixed stage ${input.view.failure?.name}',
          );
          expect(input.view.phase, SpeechInputPhase.recording);
          await tester.runAsync(() async => backend.push());
          await tester.tap(find.byKey(const ValueKey('agent-speech-toggle')));
          await _waitFor(tester, () => !input.view.busy);
          expect(input.view.failure, isNull);
          final result = input.view.transcript?.text ?? '';
          expect(
            result.contains('明天') &&
                result.contains('图书馆') &&
                result.contains('小时'),
            isTrue,
            reason: 'fixed Chinese fixture words',
          );
          expect(controller.text, startsWith('前文'));
          expect(controller.text, endsWith('后文'));
          expect(controller.text, contains(result));
          expect(runtime.agent.view.messages, isEmpty);
          expect(runtime.agent.view.busy, isFalse);
        }
        final decodedRss = ProcessInfo.currentRss;
        controller.text += ' 可编辑';
        await tester.pump();
        expect(controller.text, endsWith('可编辑'));
        // User cancellation revokes the draft delivery even with valid audio.
        final preserved = controller.text;
        await tester.tap(find.byKey(const ValueKey('agent-speech-toggle')));
        await _waitFor(
          tester,
          () => input.view.phase == SpeechInputPhase.recording,
        );
        backend.push();
        await tester.tap(find.byKey(const ValueKey('agent-speech-cancel')));
        await _waitFor(tester, () => !input.view.busy);
        expect(controller.text, preserved);
        expect(input.view.transcript, isNull);
        expect(network.attempts, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => bootstrap!.close());
        bootstrap = null;
        binding.reportData = {
          'kind': 'android-a6-speech-v1',
          'networkAttempts': network.attempts,
          'coldPrepareMs': recognizer.prepareMs.first,
          'warmPrepareMs': recognizer.prepareMs[1],
          'coldDecodeMs': recognizer.decodeMs.first,
          'warmDecodeMs': recognizer.decodeMs[1],
          'audioMs': pcm!.length * 1000 ~/ 32000,
          'initialRss': initialRss,
          'decodedRss': decodedRss,
          'closedRss': ProcessInfo.currentRss,
        'processPeakRss': ProcessInfo.maxRss,
          'realMicrophone': false,
          'editable': true,
          'autoSent': false,
        };
        debugPrint('a6_safe_metrics ${binding.reportData}');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await bootstrap?.close();
          pcm?.fillRange(0, pcm!.length, 0);
          if (fixture != null && await fixture!.exists()) {
            await fixture!.delete(recursive: true);
          }
        });
        HttpOverrides.global = previous;
      }
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 1500; i++) {
    await tester.pump();
    if (ready()) {
      await tester.pump();
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
  }
  fail('A6 synthetic operation timed out');
}

Uint8List _parseWav(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
  expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
  Uint8List? pcm;
  var format = false;
  for (var offset = 12; offset + 8 <= bytes.length;) {
    final name = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final length = data.getUint32(offset + 4, Endian.little);
    final start = offset + 8;
    expect(start + length, lessThanOrEqualTo(bytes.length));
    if (name == 'fmt ') {
      expect(data.getUint16(start, Endian.little), 1);
      expect(data.getUint16(start + 2, Endian.little), 1);
      expect(data.getUint32(start + 4, Endian.little), speechSampleRate);
      expect(data.getUint16(start + 14, Endian.little), 16);
      format = true;
    }
    if (name == 'data') {
      pcm = Uint8List.fromList(bytes.sublist(start, start + length));
    }
    offset = start + length + (length.isOdd ? 1 : 0);
  }
  expect(format, isTrue);
  expect(pcm, isNotNull);
  expect(
    pcm!.length,
    inInclusiveRange(speechMinimumSamples * 2, speechMaximumPcmBytes),
  );
  expect(pcm.length.isEven, isTrue);
  return pcm;
}

final class _SyntheticBackend implements SpeechAudioRecorderBackend {
  _SyntheticBackend(this.pcm);
  final Uint8List pcm;
  StreamController<Uint8List>? stream;
  bool tail = false;
  @override
  Future<bool> hasPermission({required bool request}) async => true;
  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    expect(config.sampleRate, 16000);
    expect(config.numChannels, 1);
    expect(config.encoder, AudioEncoder.pcm16bits);
    stream = StreamController<Uint8List>(sync: true);
    tail = false;
    return stream!.stream;
  }

  void push() {
    stream!.add(Uint8List.sublistView(pcm, 0, pcm.length - 127));
    tail = true;
  }

  @override
  Future<void> stop() async {
    final active = stream;
    stream = null;
    if (active != null) {
      if (tail) active.add(Uint8List.sublistView(pcm, pcm.length - 127));
      await active.close();
    }
  }

  @override
  Future<void> dispose() => stop();
}

final class _TimedRecognizer implements SpeechRecognizerPort {
  _TimedRecognizer(this.delegate);
  final SpeechRecognizerPort delegate;
  final prepareMs = <int>[], decodeMs = <int>[];
  @override
  Future<void> prepare() async {
    final watch = Stopwatch()..start();
    await delegate.prepare();
    prepareMs.add(watch.elapsedMilliseconds);
  }

  @override
  Future<String> recognize(Float32List samples) async {
    final watch = Stopwatch()..start();
    final text = await delegate.recognize(samples);
    decodeMs.add(watch.elapsedMilliseconds);
    return text;
  }

  @override
  Future<void> close() => delegate.close();
}

final class _FixturePlatform implements RuntimePlatformFactory {
  _FixturePlatform(this.path);
  final String path;
  static const delegate = AndroidRuntimePlatformFactory();
  @override
  Future<RuntimeDirectories> acquireDirectories({
    String? directoryPath,
    String? jwDirectoryPath,
  }) async {
    final dirs = await AndroidDirectories.acquire(path);
    return RuntimeDirectories(demo: dirs.demo, formal: dirs.formal);
  }

  @override
  JwCredentialProtector get schoolCredentials => delegate.schoolCredentials;
  @override
  ModelCredentialProtector get modelCredentials => delegate.modelCredentials;
  @override
  NativeObservationBrowser createBrowser() => delegate.createBrowser();
  @override
  NotificationPlatformPort createNotifications() =>
      UnavailableMobileNotifications();
  @override
  SpeechInputPort createSpeech(DiagnosticsPort diagnostics) =>
      throw StateError('A6 injects synthetic capture');
}

final class _NoNetwork extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('A6 synthetic test forbids network');
  }
}
