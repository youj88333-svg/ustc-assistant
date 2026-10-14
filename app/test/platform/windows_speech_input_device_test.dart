import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';
import 'package:ustc_assistant_m0/platform/windows_speech_input_device.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ustc_assistant/default_audio_input');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'fixed native request resolves the default endpoint without labels',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getDefaultInputId');
        expect(call.arguments, isNull);
        return '{synthetic-default-input}';
      });
      final device = await resolveSpeechInputDevice();
      expect(device!.id, '{synthetic-default-input}');
      expect(device.label, '系统默认输入');
    },
    skip: !Platform.isWindows,
  );

  for (final value in <Object?>[
    null,
    '',
    'x' * 1025,
    'opaque\nendpoint',
    '设备标识',
    1,
  ]) {
    test(
      'rejects a malformed endpoint without a fallback or raw error',
      () async {
        messenger.setMockMethodCallHandler(channel, (_) async => value);
        await expectLater(
          resolveSpeechInputDevice(),
          throwsA(
            isA<SpeechInputFailure>()
                .having(
                  (failure) => failure.code,
                  'code',
                  SpeechInputFailureCode.microphoneUnavailable,
                )
                .having(
                  (failure) => failure.toString(),
                  'safe error',
                  'SpeechInputFailure(microphoneUnavailable)',
                ),
          ),
        );
      },
      skip: !Platform.isWindows,
    );
  }

  test(
    'native failure does not expose endpoint or COM details',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(
          code: 'microphoneUnavailable',
          message: 'synthetic-private-device-marker',
        ),
      );
      await expectLater(
        resolveSpeechInputDevice(),
        throwsA(
          isA<SpeechInputFailure>().having(
            (failure) => failure.toString(),
            'safe error',
            isNot(contains('synthetic-private-device-marker')),
          ),
        ),
      );
    },
    skip: !Platform.isWindows,
  );
}
