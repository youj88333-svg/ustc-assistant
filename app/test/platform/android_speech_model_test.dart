import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';
import 'package:ustc_assistant_m0/platform/android_speech_model.dart';
import 'package:ustc_assistant_m0/platform/speech_model_bundle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('a6-synthetic-assets');
  const source = AndroidSpeechModel(channel: channel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const directory =
      '/data/user/0/cn.ustcassistant.mobile.qa/no_backup/speech_v1/$speechModelVersion';
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'prepares only after demand with no caller-controlled arguments',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls++;
        expect(call.method, 'prepareModel');
        expect(call.arguments, isNull);
        return {'version': speechModelVersion, 'directory': directory};
      });
      expect(calls, 0);
      final bundle = await source.prepare();
      expect(calls, 1);
      expect(bundle.androidAssets, isTrue);
      expect(bundle.modelPath, '$directory/model.int8.onnx');
      expect(bundle.tokensPath, '$directory/tokens.txt');
    },
  );

  test(
    'rejects malformed or foreign model projections with fixed failures',
    () async {
      for (final value in <Object?>[
        null,
        {'directory': directory},
        {'directory': directory, 'version': 'other'},
        {
          'directory': directory,
          'version': speechModelVersion,
          'audio': 'never accepted',
        },
        for (final path in [
          'https://host/model',
          'relative',
          '/data/../speech_v1/$speechModelVersion',
          '/data\\speech_v1/$speechModelVersion',
          '/data/speech_v1/other',
        ])
          {'directory': path, 'version': speechModelVersion},
      ]) {
        messenger.setMockMethodCallHandler(channel, (_) async => value);
        await expectLater(
          source.prepare(),
          throwsA(
            isA<SpeechInputFailure>().having(
              (e) => e.code,
              'code',
              SpeechInputFailureCode.modelUnavailable,
            ),
          ),
        );
      }
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(
          code: 'storage_failed',
          message: 'private-path-never-forwarded',
        ),
      );
      await expectLater(
        source.prepare(),
        throwsA(
          isA<SpeechInputFailure>().having(
            (e) => e.toString(),
            'safe',
            'SpeechInputFailure(modelUnavailable)',
          ),
        ),
      );
    },
  );
}
