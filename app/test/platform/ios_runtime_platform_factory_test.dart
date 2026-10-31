import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';
import 'package:ustc_assistant_m0/platform/ios_directory.dart';
import 'package:ustc_assistant_m0/platform/ios_runtime_platform_factory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const platformChannel = MethodChannel('ustc_assistant/platform_v1');
  const observationChannel = MethodChannel('ustc_assistant/observation_v1');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const appSupportRoot =
      '/var/mobile/Containers/Data/Application/01234567-89AB-CDEF-0123-456789ABCDEF/Library/Application Support/ustc_assistant_v1';

  tearDown(() {
    messenger.setMockMethodCallHandler(platformChannel, null);
    messenger.setMockMethodCallHandler(observationChannel, null);
  });

  test(
    'privateDataRoot is requested without arguments and validated',
    () async {
      messenger.setMockMethodCallHandler(platformChannel, (call) async {
        expect(call.method, 'privateDataRoot');
        expect(call.arguments, isNull);
        return appSupportRoot;
      });

      expect(
        await IOSRuntimePlatformFactory.fetchPrivateDataRoot(),
        appSupportRoot,
      );
      expect(IOSDirectories.validateRootPath(appSupportRoot), appSupportRoot);
    },
  );

  test('invalid or non-string private roots fail closed', () async {
    for (final value in <Object?>[
      null,
      'relative/Library/Application Support/ustc_assistant_v1',
      '/tmp/elsewhere',
      '/var/mobile/Library/Application Support/other',
      '$appSupportRoot/../outside',
      '$appSupportRoot\\outside',
    ]) {
      messenger.setMockMethodCallHandler(platformChannel, (_) async => value);
      await expectLater(
        IOSRuntimePlatformFactory.fetchPrivateDataRoot(),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.code,
            'failure code',
            FailureCode.unsafeDirectory,
          ),
        ),
      );
    }
  });

  test('missing host is unsupported and native details stay private', () async {
    await expectLater(
      IOSRuntimePlatformFactory.fetchPrivateDataRoot(),
      throwsA(
        isA<AppFailure>().having(
          (error) => error.code,
          'failure code',
          FailureCode.unsupportedPlatform,
        ),
      ),
    );
    messenger.setMockMethodCallHandler(platformChannel, (_) async {
      throw PlatformException(
        code: 'private-root-error',
        message: 'synthetic-private-detail',
      );
    });
    await expectLater(
      IOSRuntimePlatformFactory.fetchPrivateDataRoot(),
      throwsA(
        isA<AppFailure>()
            .having(
              (error) => error.code,
              'failure code',
              FailureCode.storageFailed,
            )
            .having(
              (error) => error.toString(),
              'message',
              isNot(contains('synthetic-private-detail')),
            ),
      ),
    );
  });

  test('desktop invocation cannot acquire an iOS sandbox directory', () async {
    if (Platform.isIOS) return;
    final factory = IOSRuntimePlatformFactory();
    await expectLater(
      factory.acquireDirectories(),
      throwsA(
        isA<AppFailure>().having(
          (error) => error.code,
          'failure code',
          FailureCode.unsupportedPlatform,
        ),
      ),
    );
  });

  test(
    'unimplemented iOS services are unavailable, never empty-success',
    () async {
      final factory = IOSRuntimePlatformFactory();
      final browser = factory.createBrowser();
      expect(browser.requiresAvailabilityCheck, isTrue);
      expect(browser.supportsIsolatedCleanupPending, isFalse);
      await expectLater(
        browser.ensureAvailable(),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.code,
            'failure code',
            FailureCode.unsupportedPlatform,
          ),
        ),
      );
      await browser.dispose();

      final notifications = factory.createNotifications();
      expect((await notifications.initialize()).available, isFalse);
      await expectLater(
        notifications.pending(),
        throwsA(
          isA<ReminderFailure>().having(
            (error) => error.code,
            'failure code',
            ReminderFailureCode.platformUnavailable,
          ),
        ),
      );
      await notifications.close();

      final speech = factory.createSpeech(_NoopDiagnostics());
      await speech.start();
      expect(speech.view.failure, SpeechInputFailureCode.unsupportedPlatform);
      expect(speech.view.transcript, isNull);
      await speech.close();
    },
  );
}

final class _NoopDiagnostics implements DiagnosticsPort {
  @override
  void record(DiagnosticEvent event) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
