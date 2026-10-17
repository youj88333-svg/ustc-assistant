// A7 API34 old-provider rejection. Architecture07/09, quality13 V-07 and
// workflow15: unavailable isolation must not become a shared browser fallback.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/platform/android_directory.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'a provider missing profiles rejects both acquisition and cleanup without claiming deletion',
    (tester) async {
      await tester.runAsync(() async {
        final root = await const MethodChannel(
          'ustc_assistant/platform_v1',
        ).invokeMethod<String>('privateDataRoot');
        expect(root, contains('/cn.ustcassistant.mobile.qa/no_backup/'));
        final fixture = await Directory(root!).createTemp('a7_source_');
        final owned = await AndroidDirectories.acquire(fixture.path);
        final browser = NativeObservationBrowser();
        try {
          owned.formal.createPlainChildDirectory('jw_partitions_v1');
          final path = owned.formal.createPlainChildDirectory(
            'jw_partitions_v1/jwp-${'a' * 32}',
          );
          // Fixed loopback only. Feature rejection occurs before any load.
          final target = ObservationTarget.fixture(
            Uri.parse('http://127.0.0.1:43127/cas/login'),
          );
          for (final recovery in [false, true]) {
            await expectLater(
              browser.open(
                session: recovery ? 2 : 1,
                profilePath: path,
                target: target,
                recoveryOnly: recovery,
              ),
              throwsA(
                isA<AppFailure>().having(
                  (error) => error.code,
                  'code',
                  FailureCode.unsupportedPlatform,
                ),
              ),
            );
          }
          binding.reportData = {
            'kind': 'android-a7-old-provider-v1',
            'acquisitionRejected': true,
            'cleanupUnavailableReported': true,
            'sourceAvailable': false,
            'realSchool': false,
          };
        } finally {
          await browser.dispose();
          await owned.demo.release();
          await owned.formal.release();
          await fixture.delete(recursive: true);
        }
      });
    },
    skip: !Platform.isAndroid,
  );
}
