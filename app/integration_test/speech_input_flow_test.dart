import 'dart:async';
import 'dart:io';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/settings_contract.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';
import 'package:ustc_assistant_m0/m0_entry.dart';
import 'package:ustc_assistant_m0/platform/offline_speech_input.dart';
import 'package:ustc_assistant_m0/platform/sense_voice_recognizer.dart';
import 'package:ustc_assistant_m0/platform/speech_model_bundle.dart';
import 'package:ustc_assistant_m0/platform/speech_audio_recorder.dart';

import 'support/diagnostic_cleanup.dart';
import 'support/onboarding_fixture.dart';

const _speechTestWavPath = String.fromEnvironment('USTC_SPEECH_TEST_WAV');
const _eventTitle = 'M58 合成普通日程';
const _transcriptFixture = 'M58 合成听写草稿';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets(
    'synthetic PCM crosses the production recorder adapter, stop tail, and local SenseVoice',
    (tester) async {
      expect(Platform.isWindows, isTrue, reason: 'Windows integration only.');
      final fixture = await _loadWavFixture(tester);
      final recorder = _WavStreamBackend(fixture.pcm);
      final capture = SpeechAudioRecorder(
        backendFactory: () => recorder,
        inputDeviceResolver: () async =>
            const InputDevice(id: 'synthetic-default-input', label: '系统默认输入'),
      );
      final recognizer = _TimedRecognizer(
        SenseVoiceRecognizer(bundle: SpeechModelBundle()),
      );
      final input = OfflineSpeechInput(
        recorder: capture,
        recognizer: recognizer,
      );
      try {
        for (var pass = 0; pass < 2; pass++) {
          await _runNative(tester, input.start);
          expect(
            input.view.failure,
            isNull,
            reason:
                'Speech start returned fixed failure code '
                '${input.view.failure?.name ?? 'none'}.',
          );
          expect(
            input.view.phase,
            SpeechInputPhase.recording,
            reason:
                'Speech input did not reach recording; fixed failure code '
                '${input.view.failure?.name ?? 'none'}.',
          );
          recorder.pushFixture();
          await _runNative(tester, input.finish);

          final transcript = input.view.transcript?.text ?? '';
          expect(input.view.phase, SpeechInputPhase.idle);
          expect(transcript.isNotEmpty, isTrue);
          final containsExpectedWords =
              transcript.contains('明天') &&
              transcript.contains('图书馆') &&
              transcript.contains('小时');
          expect(
            containsExpectedWords,
            isTrue,
            reason: 'Local recognition missed a fixed synthetic target word.',
          );
        }

        expect(recorder.startCalls, 2);
        expect(recorder.stopCalls, 2);
        expect(recorder.filesWritten, 0);
        expect(recognizer.prepareMilliseconds, hasLength(2));
        expect(recognizer.decodeMilliseconds, hasLength(2));
        debugPrint(
          'speech_timing '
          'coldPrepareMs=${recognizer.prepareMilliseconds[0]} '
          'warmPrepareMs=${recognizer.prepareMilliseconds[1]} '
          'coldDecodeMs=${recognizer.decodeMilliseconds[0]} '
          'warmDecodeMs=${recognizer.decodeMilliseconds[1]}',
        );
      } finally {
        await _runNative(tester, input.close);
        fixture.pcm.fillRange(0, fixture.pcm.length, 0);
      }
    },
  );

  testWidgets(
    'owned M0 keeps dictation in draft and drains the caller-owned port on exit',
    (tester) async {
      final workspace = await _createWorkspace();
      final bootstraps = <RuntimeBootstrap>[];
      final firstSpeech = _ControlledSpeechInput(holdClose: true);
      Future<void>? pendingClose;
      try {
        final gateway = _CountingGateway();
        final first = await _openBootstrap(
          tester,
          workspace,
          gateway: gateway,
          speech: firstSpeech,
        );
        bootstraps.add(first);
        final runtime = first.runtime!;
        expect(identical(first.speechInput, firstSpeech), isTrue);
        expect(identical(runtime.speechInput, firstSpeech), isTrue);
        expect(runtime.agent.view.settings!.keySaved, isFalse);
        expect(runtime.jwStore.schemaVersion, JwStore.currentSchemaVersion);

        await tester.pumpWidget(OwnedApplication(bootstrap: first));
        await tester.pumpAndSettle();
        final createConversation = find.byKey(
          const ValueKey('agent-empty-new-conversation'),
        );
        expect(createConversation, findsNothing);
        expect(runtime.agent.view.conversationId, isNotNull);
        expect(gateway.requestCount, 0);

        final speechToggle = find.byKey(const ValueKey('agent-speech-toggle'));
        expect(speechToggle, findsOneWidget);
        await tester.ensureVisible(speechToggle);
        await tester.tap(speechToggle);
        await tester.pump();
        expect(firstSpeech.startCalls, 1);
        expect(gateway.requestCount, 0);

        firstSpeech.complete(_transcriptFixture);
        await tester.pumpAndSettle();
        final composer = find.byKey(const ValueKey('agent-composer'));
        expect(
          tester.widget<TextField>(composer).controller!.text,
          _transcriptFixture,
        );
        expect(runtime.agent.view.messages, isEmpty);
        expect(gateway.requestCount, 0);

        await _saveOrdinaryEvent(tester, runtime);
        expect(
          runtime.calendar.view.window!.items.any(
            (item) => item.title == _eventTitle,
          ),
          isTrue,
        );

        await tester.ensureVisible(speechToggle);
        await tester.tap(speechToggle);
        await tester.pump();
        expect(firstSpeech.startCalls, 2);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(firstSpeech.cancelCalls, greaterThan(0));

        var closeCompleted = false;
        await tester.runAsync(() async {
          pendingClose = first.close();
          pendingClose!.then<void>(
            (_) => closeCompleted = true,
            onError: (Object _, StackTrace _) => closeCompleted = true,
          );
          await firstSpeech.closeEntered.future;
        });
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        expect(firstSpeech.closeCalls, 1);
        expect(firstSpeech.cancelCalls, greaterThanOrEqualTo(2));
        expect(firstSpeech.closed, isFalse);
        expect(closeCompleted, isFalse);
        expect(first.directory.isHeld, isTrue);
        expect(first.jwDirectory.isHeld, isTrue);

        firstSpeech.releaseClose();
        await _runNative(tester, () => pendingClose!);
        expect(firstSpeech.closed, isTrue);
        expect(first.directory.isHeld, isFalse);
        expect(first.jwDirectory.isHeld, isFalse);

        final reopenedSpeech = _ControlledSpeechInput();
        final reopenedGateway = _CountingGateway();
        final reopened = await _openBootstrap(
          tester,
          workspace,
          gateway: reopenedGateway,
          speech: reopenedSpeech,
        );
        bootstraps.add(reopened);
        final reopenedRuntime = reopened.runtime!;
        expect(
          reopenedRuntime.jwStore.schemaVersion,
          JwStore.currentSchemaVersion,
        );
        expect(reopenedRuntime.agent.view.messages, isEmpty);
        expect(
          reopenedRuntime.calendar.view.window!.items.any(
            (item) => item.title == _eventTitle,
          ),
          isTrue,
        );
        await tester.pumpWidget(OwnedApplication(bootstrap: reopened));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('agent-composer')))
              .controller!
              .text,
          isEmpty,
        );
        expect(reopenedGateway.requestCount, 0);
        expect(tester.takeException(), isNull);
      } finally {
        firstSpeech.releaseClose();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        if (pendingClose != null) {
          await _runNative(tester, () => pendingClose!);
        }
        for (final bootstrap in bootstraps.reversed) {
          if (bootstrap.directory.isHeld || bootstrap.jwDirectory.isHeld) {
            await _runNative(tester, bootstrap.close);
          }
        }
        await _deleteOwnedWorkspace(workspace);
      }
    },
  );

  testWidgets(
    'TEMP Runtime reset waits for active speech cancellation to drain',
    (tester) async {
      final workspace = await _createWorkspace();
      final bootstraps = <RuntimeBootstrap>[];
      final speech = _ControlledSpeechInput(holdCancel: true);
      Future<void>? maintenanceWork;
      try {
        final gateway = _CountingGateway();
        final bootstrap = await _openBootstrap(
          tester,
          workspace,
          gateway: gateway,
          speech: speech,
        );
        bootstraps.add(bootstrap);
        final runtime = bootstrap.runtime!;
        expect(runtime.agent.view.settings!.keySaved, isFalse);
        await tester.pumpWidget(OwnedApplication(bootstrap: bootstrap));
        await tester.pumpAndSettle();

        final createConversation = find.byKey(
          const ValueKey('agent-empty-new-conversation'),
        );
        expect(createConversation, findsNothing);
        expect(runtime.agent.view.conversationId, isNotNull);

        final speechToggle = find.byKey(const ValueKey('agent-speech-toggle'));
        expect(speechToggle, findsOneWidget);
        await tester.ensureVisible(speechToggle);
        await tester.tap(speechToggle);
        await tester.pump();
        expect(speech.startCalls, 1);

        final settingsContext = runtime.settings.settingsView.snapshot!.context;
        var maintenanceCompleted = false;
        await tester.runAsync(() async {
          maintenanceWork = runtime.settings.runMaintenance(
            settingsContext,
            MaintenanceKind.reset,
            confirmed: true,
          );
          maintenanceWork!.then<void>(
            (_) => maintenanceCompleted = true,
            onError: (Object _, StackTrace _) => maintenanceCompleted = true,
          );
          await speech.cancelEntered.future;
        });
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));

        expect(speech.cancelCalls, greaterThan(0));
        expect(maintenanceCompleted, isFalse);
        expect(runtime.maintenance.view.phase, MaintenancePhase.preparing);
        expect(runtime.directory.isHeld, isTrue);
        expect(runtime.jwDirectory.isHeld, isTrue);
        expect(gateway.requestCount, 0);

        speech.releaseCancel();
        await _runNative(tester, () => maintenanceWork!);
        expect(maintenanceCompleted, isTrue);
        expect(runtime.maintenance.view.phase, MaintenancePhase.idle);
        expect(
          runtime.settings.settingsView.snapshot!.context.resetEpoch,
          greaterThan(settingsContext.resetEpoch),
        );
        expect(speech.closeCalls, 0);
        expect(runtime.directory.isHeld, isTrue);
        expect(runtime.jwDirectory.isHeld, isTrue);
        expect(gateway.requestCount, 0);
        expect(tester.takeException(), isNull);
      } finally {
        speech.releaseCancel();
        if (maintenanceWork != null) {
          await _runNative(tester, () => maintenanceWork!);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        for (final bootstrap in bootstraps.reversed) {
          if (bootstrap.directory.isHeld || bootstrap.jwDirectory.isHeld) {
            await _runNative(tester, bootstrap.close);
          }
        }
        await _deleteOwnedWorkspace(workspace);
      }
    },
  );
}

Future<_WavFixture> _loadWavFixture(WidgetTester tester) => _runNative(
  tester,
  () async {
    if (_speechTestWavPath.isEmpty || !p.isAbsolute(_speechTestWavPath)) {
      throw StateError('USTC_SPEECH_TEST_WAV must name an absolute WAV path.');
    }
    final file = File(_speechTestWavPath);
    final maximumFileBytes = speechMaximumPcmBytes + 4096;
    late final int fileLength;
    try {
      fileLength = await file.length();
    } catch (_) {
      throw StateError('Synthetic WAV fixture could not be inspected.');
    }
    if (fileLength > maximumFileBytes) {
      throw StateError('Synthetic WAV exceeds the bounded fixture size.');
    }
    late final Uint8List encoded;
    try {
      encoded = await file.readAsBytes();
    } catch (_) {
      throw StateError('Synthetic WAV fixture could not be read.');
    }
    try {
      if (encoded.length > maximumFileBytes) {
        throw StateError('Synthetic WAV exceeds the bounded fixture size.');
      }
      return _parsePcmWav(encoded);
    } finally {
      encoded.fillRange(0, encoded.length, 0);
    }
  },
);

_WavFixture _parsePcmWav(Uint8List bytes) {
  if (bytes.length < 44) {
    throw StateError('Synthetic WAV header is incomplete.');
  }
  final data = ByteData.sublistView(bytes);
  if (!_hasFourCc(bytes, 0, 'RIFF') ||
      !_hasFourCc(bytes, 8, 'WAVE') ||
      data.getUint32(4, Endian.little) != bytes.length - 8) {
    throw StateError('Synthetic WAV RIFF size or signature is invalid.');
  }

  var offset = 12;
  var hasFormat = false;
  Uint8List? pcm;
  try {
    while (offset < bytes.length) {
      if (offset + 8 > bytes.length) {
        throw StateError('Synthetic WAV chunk header is incomplete.');
      }
      final chunkLength = data.getUint32(offset + 4, Endian.little);
      final contentStart = offset + 8;
      final contentEnd = contentStart + chunkLength;
      if (contentEnd > bytes.length) {
        throw StateError('Synthetic WAV chunk exceeds the RIFF boundary.');
      }
      if (_hasFourCc(bytes, offset, 'fmt ')) {
        if (hasFormat || chunkLength < 16) {
          throw StateError('Synthetic WAV format chunk is invalid.');
        }
        hasFormat = true;
        final format = data.getUint16(contentStart, Endian.little);
        final channels = data.getUint16(contentStart + 2, Endian.little);
        final sampleRate = data.getUint32(contentStart + 4, Endian.little);
        final byteRate = data.getUint32(contentStart + 8, Endian.little);
        final blockAlign = data.getUint16(contentStart + 12, Endian.little);
        final bitsPerSample = data.getUint16(contentStart + 14, Endian.little);
        if (format != 1 ||
            channels != 1 ||
            sampleRate != speechSampleRate ||
            byteRate != speechSampleRate * 2 ||
            blockAlign != 2 ||
            bitsPerSample != 16) {
          throw StateError('Synthetic WAV must be mono PCM16 at 16 kHz.');
        }
      } else if (_hasFourCc(bytes, offset, 'data')) {
        if (pcm != null) {
          throw StateError('Synthetic WAV has multiple data chunks.');
        }
        pcm = Uint8List.fromList(
          Uint8List.sublistView(bytes, contentStart, contentEnd),
        );
      }
      offset = contentEnd + (chunkLength.isOdd ? 1 : 0);
      if (offset > bytes.length) {
        throw StateError(
          'Synthetic WAV chunk padding exceeds the RIFF boundary.',
        );
      }
    }

    if (offset != bytes.length || !hasFormat || pcm == null) {
      throw StateError(
        'Synthetic WAV must contain one format and one data chunk.',
      );
    }
    final samples = pcm.length ~/ 2;
    if (pcm.length.isOdd ||
        samples < speechMinimumSamples ||
        samples > speechMaximumSamples) {
      throw StateError(
        'Synthetic WAV duration must be between 0.5 and 30 seconds.',
      );
    }
    final fixture = _WavFixture(pcm);
    pcm = null;
    return fixture;
  } catch (_) {
    pcm?.fillRange(0, pcm.length, 0);
    rethrow;
  }
}

bool _hasFourCc(Uint8List bytes, int offset, String value) {
  if (offset + 4 > bytes.length || value.length != 4) return false;
  for (var index = 0; index < 4; index++) {
    if (bytes[offset + index] != value.codeUnitAt(index)) return false;
  }
  return true;
}

Future<RuntimeBootstrap> _openBootstrap(
  WidgetTester tester,
  _OwnedWorkspace workspace, {
  required _CountingGateway gateway,
  required SpeechInputPort speech,
}) => _runNative(
  tester,
  () => configuredSyntheticInstallation(
    RuntimeBootstrap.open(
      directoryPath: workspace.demoPath,
      jwDirectoryPath: workspace.formalPath,
      clock: FixedClock(DateTime.utc(2026, 10, 13, 4)),
      modelGateway: gateway,
      speechInput: speech,
    ),
  ),
);

Future<void> _saveOrdinaryEvent(
  WidgetTester tester,
  DemoRuntime runtime,
) async {
  final context = runtime.calendar.view.window!.context;
  await _runNative(
    tester,
    () => runtime.calendar.execute(
      CreatePersonalEvent(
        PersonalEventDraft(
          title: _eventTitle,
          start: DateTime.utc(2026, 10, 13, 2),
          end: DateTime.utc(2026, 10, 13, 3),
          note: '仅供本机集成测试',
        ),
      ),
      expectedContext: context,
    ),
  );
}

Future<T> _runNative<T>(
  WidgetTester tester,
  Future<T> Function() action,
) async {
  late T result;
  Object? failure;
  StackTrace? failureStack;
  try {
    await tester.runAsync(() async {
      try {
        result = await action();
      } catch (error, stack) {
        failure = error;
        failureStack = stack;
      }
    });
  } catch (error, stack) {
    failure ??= error;
    failureStack ??= stack;
  }
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  return result;
}

Future<_OwnedWorkspace> _createWorkspace() async {
  const prefix = 'ustc_m58_speech_';
  final root = await Directory.systemTemp.createTemp(prefix);
  final rootPath = _normal(root.path);
  final tempPath = _normal(await Directory.systemTemp.resolveSymbolicLinks());
  final rootName = p.windows.basename(rootPath);
  if (!p.windows.equals(p.windows.dirname(rootPath), tempPath) ||
      !rootName.startsWith(prefix) ||
      rootName.length == prefix.length ||
      !RegExp(
        r'^[A-Za-z0-9_-]+$',
      ).hasMatch(rootName.substring(prefix.length)) ||
      !p.windows.equals(rootPath, _normal(await root.resolveSymbolicLinks())) ||
      await FileSystemEntity.type(rootPath, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw StateError('Refusing a TEMP root without a plain nonce directory.');
  }
  final nonce = _nonce();
  final markerName = '.m58-owner-$nonce.marker';
  final marker = File(p.windows.join(rootPath, markerName));
  final handle = await marker.open(mode: FileMode.writeOnly);
  try {
    await handle.writeString('$nonce\n');
    await handle.flush();
  } finally {
    await handle.close();
  }
  return _OwnedWorkspace(
    root: root,
    prefix: prefix,
    nonce: nonce,
    markerName: markerName,
    demoPath: p.windows.join(rootPath, 'demo-$nonce'),
    formalPath: p.windows.join(rootPath, 'formal-$nonce'),
  );
}

Future<void> _deleteOwnedWorkspace(_OwnedWorkspace workspace) async {
  final tempPath = _normal(await Directory.systemTemp.resolveSymbolicLinks());
  final rootPath = _normal(workspace.root.path);
  final rootName = p.windows.basename(rootPath);
  if (!p.windows.equals(p.windows.dirname(rootPath), tempPath) ||
      !rootName.startsWith(workspace.prefix) ||
      rootName.length == workspace.prefix.length ||
      !RegExp(
        r'^[A-Za-z0-9_-]+$',
      ).hasMatch(rootName.substring(workspace.prefix.length)) ||
      !p.windows.equals(
        rootPath,
        _normal(await workspace.root.resolveSymbolicLinks()),
      ) ||
      await FileSystemEntity.type(rootPath, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw StateError('Refusing to remove a path outside the nonce TEMP root.');
  }

  final markerPath = p.windows.join(rootPath, workspace.markerName);
  if (await FileSystemEntity.type(markerPath, followLinks: false) !=
          FileSystemEntityType.file ||
      !p.windows.equals(
        markerPath,
        _normal(await File(markerPath).resolveSymbolicLinks()),
      ) ||
      await File(markerPath).readAsString() != '${workspace.nonce}\n') {
    throw StateError(
      'Refusing to remove a TEMP root with an invalid owner marker.',
    );
  }

  final expectedDemo = _normal(workspace.demoPath);
  final expectedFormal = _normal(workspace.formalPath);
  if (!p.windows.equals(p.windows.dirname(expectedDemo), rootPath) ||
      !p.windows.equals(p.windows.dirname(expectedFormal), rootPath) ||
      p.windows.basename(expectedDemo) != 'demo-${workspace.nonce}' ||
      p.windows.basename(expectedFormal) != 'formal-${workspace.nonce}') {
    throw StateError('Refusing an unrecognized TEMP child path.');
  }

  await _assertNoLinks(workspace.root, rootPath);
  final children = await workspace.root.list(followLinks: false).toList();
  final expectedNames = {
    workspace.markerName,
    p.windows.basename(expectedDemo),
    p.windows.basename(expectedFormal),
  };
  if (children.length != expectedNames.length ||
      children.map((entry) => p.windows.basename(entry.path)).toSet().length !=
          children.length ||
      children.any(
        (entry) => !expectedNames.contains(p.windows.basename(entry.path)),
      )) {
    throw StateError('Refusing to remove an unknown TEMP child.');
  }
  for (final directory in [
    Directory(expectedDemo),
    Directory(expectedFormal),
  ]) {
    final path = _normal(directory.path);
    if (!p.windows.equals(p.windows.dirname(path), rootPath) ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.directory ||
        !p.windows.equals(
          path,
          _normal(await directory.resolveSymbolicLinks()),
        )) {
      throw StateError('A known TEMP child is not a plain owned directory.');
    }
  }
  await _assertKnownDatabaseFiles(Directory(expectedDemo), formal: false);
  await _assertKnownDatabaseFiles(Directory(expectedFormal), formal: true);
  await _assertNoLinks(workspace.root, rootPath);
  if (!p.windows.equals(
        rootPath,
        _normal(await workspace.root.resolveSymbolicLinks()),
      ) ||
      await FileSystemEntity.type(rootPath, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw StateError('TEMP root changed during ownership validation.');
  }
  await workspace.root.delete(recursive: true);
}

Future<void> _assertKnownDatabaseFiles(
  Directory directory, {
  required bool formal,
}) async {
  final directoryPath = _normal(directory.path);
  final databaseName = formal ? 'jw.sqlite' : 'm0_demo.sqlite';
  final allowedFiles = {
    databaseName,
    '$databaseName-wal',
    '$databaseName-shm',
    '$databaseName-journal',
  };
  final emptyRoots = formal
      ? {'jw_partitions_v1', 'young_partitions_v1'}
      : {'observation_v1', 'young_observation_v1'};
  await for (final entry in directory.list(followLinks: false)) {
    final path = _normal(entry.path);
    if (!p.windows.isWithin(directoryPath, path)) {
      throw StateError(
        'Refusing to remove an entry outside the owned directory.',
      );
    }
    final name = p.windows.basename(path);
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (allowedFiles.contains(name) &&
        type == FileSystemEntityType.file &&
        p.windows.equals(
          path,
          _normal(await File(path).resolveSymbolicLinks()),
        )) {
      continue;
    }
    if (formal &&
        name == 'diagnostics' &&
        type == FileSystemEntityType.directory) {
      await assertKnownFormalDiagnosticsDirectory(directory);
      continue;
    }
    if (emptyRoots.contains(name) && type == FileSystemEntityType.directory) {
      final root = Directory(path);
      if (!p.windows.equals(path, _normal(await root.resolveSymbolicLinks())) ||
          (await root.list(followLinks: false).take(1).toList()).isNotEmpty) {
        throw StateError(
          'Refusing to remove a populated or linked source root.',
        );
      }
      continue;
    }
    throw StateError('Refusing to remove an unknown TEMP database entry.');
  }
  if (formal &&
      await Directory(p.windows.join(directoryPath, 'diagnostics')).exists()) {
    await assertKnownFormalDiagnosticsDirectory(directory);
  }
}

Future<void> _assertNoLinks(Directory root, String rootPath) async {
  final pending = <Directory>[root];
  while (pending.isNotEmpty) {
    final directory = pending.removeLast();
    await for (final entity in directory.list(followLinks: false)) {
      final path = _normal(entity.path);
      if (!p.windows.isWithin(rootPath, path)) {
        throw StateError('Refusing to remove an entry outside TEMP ownership.');
      }
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.link ||
          type == FileSystemEntityType.notFound) {
        throw StateError('Refusing to remove a link or changing TEMP entry.');
      }
      if (type == FileSystemEntityType.directory) {
        pending.add(Directory(path));
      } else if (type != FileSystemEntityType.file) {
        throw StateError('Refusing to remove an unknown TEMP entry type.');
      }
    }
  }
}

String _normal(String path) => p.windows.normalize(p.windows.absolute(path));

String _nonce() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

final class _WavFixture {
  const _WavFixture(this.pcm);
  final Uint8List pcm;
}

final class _WavStreamBackend implements SpeechAudioRecorderBackend {
  _WavStreamBackend(this.pcm);
  final Uint8List pcm;
  StreamController<Uint8List>? _active;
  int? _tailOffset;
  bool _closed = false;
  int startCalls = 0, stopCalls = 0, filesWritten = 0;

  @override
  Future<bool> hasPermission({required bool request}) async => true;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    expect(config.encoder, AudioEncoder.pcm16bits);
    expect(config.sampleRate, speechSampleRate);
    expect(config.numChannels, 1);
    expect(config.device!.id, 'synthetic-default-input');
    if (_closed || _active != null) {
      throw const SpeechInputFailure(
        SpeechInputFailureCode.microphoneUnavailable,
      );
    }
    startCalls++;
    final controller = StreamController<Uint8List>(sync: true);
    _active = controller;
    _tailOffset = null;
    return controller.stream;
  }

  void pushFixture() {
    final controller = _active;
    if (controller == null) {
      throw const SpeechInputFailure(
        SpeechInputFailureCode.microphoneUnavailable,
      );
    }
    const chunkSize = 4095;
    final bodyEnd = pcm.length - 127;
    for (var offset = 0; offset < bodyEnd; offset += chunkSize) {
      final end = min(offset + chunkSize, bodyEnd);
      controller.add(Uint8List.sublistView(pcm, offset, end));
    }
    _tailOffset = bodyEnd;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    final controller = _active;
    _active = null;
    final tail = _tailOffset;
    _tailOffset = null;
    if (controller != null && tail != null) {
      controller.add(Uint8List.sublistView(pcm, tail));
    }
    await controller?.close();
  }

  @override
  Future<void> dispose() async {
    if (_closed) return;
    if (_active != null) await stop();
    _closed = true;
  }
}

final class _TimedRecognizer implements SpeechRecognizerPort {
  _TimedRecognizer(this.delegate);
  final SpeechRecognizerPort delegate;
  final List<int> prepareMilliseconds = [];
  final List<int> decodeMilliseconds = [];

  @override
  Future<void> prepare() async {
    final timer = Stopwatch()..start();
    try {
      await delegate.prepare();
    } finally {
      timer.stop();
      prepareMilliseconds.add(timer.elapsedMilliseconds);
    }
  }

  @override
  Future<String> recognize(Float32List samples) async {
    final timer = Stopwatch()..start();
    try {
      return await delegate.recognize(samples);
    } finally {
      timer.stop();
      decodeMilliseconds.add(timer.elapsedMilliseconds);
    }
  }

  @override
  Future<void> close() => delegate.close();
}

final class _ControlledSpeechInput implements SpeechInputPort {
  _ControlledSpeechInput({bool holdClose = false, bool holdCancel = false}) {
    if (!holdClose) _closeGate.complete();
    if (!holdCancel) _cancelGate.complete();
  }

  final _changes = StreamController<SpeechInputView>.broadcast(sync: true);
  final Completer<void> _closeGate = Completer<void>();
  final Completer<void> _cancelGate = Completer<void>();
  final Completer<void> cancelEntered = Completer<void>();
  final Completer<void> closeEntered = Completer<void>();
  SpeechInputView _view = const SpeechInputView();
  Future<void>? _cancelFuture, _closeFuture;
  int startCalls = 0, finishCalls = 0, cancelCalls = 0, closeCalls = 0;
  bool closed = false;

  @override
  SpeechInputView get view => _view;

  @override
  Stream<SpeechInputView> get changes => _changes.stream;

  void _publish(SpeechInputView next) {
    _view = next;
    if (!_changes.isClosed) _changes.add(next);
  }

  @override
  Future<void> start() async {
    if (closed || _view.phase != SpeechInputPhase.idle) {
      throw const SpeechInputFailure(SpeechInputFailureCode.busy);
    }
    startCalls++;
    _publish(
      SpeechInputView(
        phase: SpeechInputPhase.recording,
        revision: _view.revision + 1,
      ),
    );
  }

  @override
  Future<void> finish() async {
    finishCalls++;
    _publish(SpeechInputView(revision: _view.revision));
  }

  void complete(String text) {
    _publish(
      SpeechInputView(
        revision: _view.revision,
        transcript: SpeechTranscript(revision: _view.revision, text: text),
      ),
    );
  }

  @override
  Future<void> cancel() =>
      _cancelFuture ??= _cancel().whenComplete(() => _cancelFuture = null);

  Future<void> _cancel() async {
    cancelCalls++;
    if (!cancelEntered.isCompleted) cancelEntered.complete();
    if (!closed) {
      _publish(
        SpeechInputView(
          phase: SpeechInputPhase.cancelling,
          revision: _view.revision + 1,
        ),
      );
    }
    await _cancelGate.future;
    if (!closed) _publish(SpeechInputView(revision: _view.revision));
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (closed) return;
    await cancel();
    closeCalls++;
    if (!closeEntered.isCompleted) closeEntered.complete();
    await _closeGate.future;
    closed = true;
    _publish(
      SpeechInputView(phase: SpeechInputPhase.closed, revision: _view.revision),
    );
    await _changes.close();
  }

  void releaseClose() {
    if (!_closeGate.isCompleted) _closeGate.complete();
  }

  void releaseCancel() {
    if (!_cancelGate.isCompleted) _cancelGate.complete();
  }
}

final class _CountingGateway implements ModelGatewayPort {
  int requestCount = 0;

  @override
  Future<List<String>> listModels(ModelSecretLease secret) async {
    requestCount++;
    return const [];
  }

  @override
  Stream<ModelEvent> generate(ModelRequest request, ModelSecretLease secret) {
    requestCount++;
    return const Stream<ModelEvent>.empty();
  }

  @override
  Future<void> cancelAndDrain() async {}

  @override
  Future<void> close() async {}
}

final class _OwnedWorkspace {
  const _OwnedWorkspace({
    required this.root,
    required this.prefix,
    required this.nonce,
    required this.markerName,
    required this.demoPath,
    required this.formalPath,
  });

  final Directory root;
  final String prefix, nonce, markerName, demoPath, formalPath;
}
