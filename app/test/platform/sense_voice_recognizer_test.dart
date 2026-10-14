import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';
import 'package:ustc_assistant_m0/platform/sense_voice_recognizer.dart';
import 'package:ustc_assistant_m0/platform/speech_model_bundle.dart';

void main() {
  final invalidAudio = throwsA(
    isA<SpeechInputFailure>().having(
      (failure) => failure.code,
      'fixed failure',
      SpeechInputFailureCode.invalidAudio,
    ),
  );
  final closed = throwsA(
    isA<SpeechInputFailure>().having(
      (failure) => failure.code,
      'fixed failure',
      SpeechInputFailureCode.closed,
    ),
  );

  test(
    'invalid PCM is rejected before any worker or installed model access',
    () async {
      final recognizer = SenseVoiceRecognizer();
      await expectLater(recognizer.recognize(Float32List(0)), invalidAudio);
      await expectLater(
        recognizer.recognize(Float32List(speechMaximumSamples + 1)),
        invalidAudio,
      );
      for (final value in [double.nan, double.infinity, -1.01, 1.01]) {
        final samples = Float32List(speechMinimumSamples)..[0] = value;
        await expectLater(recognizer.recognize(samples), invalidAudio);
      }
      await recognizer.close();
    },
  );

  test('closing an unused recognizer is lazy, final and idempotent', () async {
    final recognizer = SenseVoiceRecognizer();
    await recognizer.close();
    await recognizer.close();
    await expectLater(recognizer.prepare(), closed);
    await expectLater(
      recognizer.recognize(Float32List(speechMinimumSamples)),
      closed,
    );
  });

  test(
    'missing public assets fail safely, worker failure drains and can retry',
    () async {
      final root = await Directory.systemTemp.createTemp('ustc-m58-missing-');
      final recognizer = SenseVoiceRecognizer(
        bundle: SpeechModelBundle(executableDirectory: root.path),
      );
      final missing = throwsA(
        isA<SpeechInputFailure>()
            .having(
              (failure) => failure.code,
              'fixed failure',
              SpeechInputFailureCode.modelUnavailable,
            )
            .having(
              (failure) => failure.toString().contains(root.path),
              'no private path',
              isFalse,
            ),
      );
      try {
        await Future.wait([
          expectLater(recognizer.prepare(), missing),
          expectLater(recognizer.prepare(), missing),
        ]);
        await expectLater(recognizer.prepare(), missing);
        await recognizer.close();
        await expectLater(recognizer.prepare(), closed);
        expect(await root.list().isEmpty, isTrue);
      } finally {
        await recognizer.close();
        // The fixture remains empty; delete only the owned plain TEMP directory.
        if (await root.list().isEmpty &&
            await root.resolveSymbolicLinks() == root.absolute.path) {
          await root.delete();
        }
      }
    },
  );

  test(
    'close during worker preparation waits for failure before release',
    () async {
      final root = await Directory.systemTemp.createTemp('ustc-m58-drain-');
      final recognizer = SenseVoiceRecognizer(
        bundle: SpeechModelBundle(executableDirectory: root.path),
      );
      try {
        final pending = recognizer.prepare();
        final checked = expectLater(
          pending,
          throwsA(isA<SpeechInputFailure>()),
        );
        await recognizer.close();
        await checked;
        await expectLater(recognizer.prepare(), closed);
        expect(await root.list().isEmpty, isTrue);
      } finally {
        await recognizer.close();
        if (await root.list().isEmpty &&
            await root.resolveSymbolicLinks() == root.absolute.path) {
          await root.delete();
        }
      }
    },
  );
}
