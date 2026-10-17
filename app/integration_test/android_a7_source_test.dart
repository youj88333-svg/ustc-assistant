// A7 API34 old-provider rejection. Architecture07/09, quality13 V-07 and
// workflow15: unavailable isolation must not become a shared browser fallback.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';
import 'package:ustc_assistant_m0/jobs/jw_sync_port.dart';
import 'package:ustc_assistant_m0/jobs/young_sync_port.dart';
import 'package:ustc_assistant_m0/platform/android_directory.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/runtime_platform_factory.dart';
import 'package:ustc_assistant_m0/source/observation_contract.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'unsupported formal source attempts leave local work available without staging credentials or partitions',
    (tester) async {
      await tester.runAsync(() async {
        final root = await const MethodChannel(
          'ustc_assistant/platform_v1',
        ).invokeMethod<String>('privateDataRoot');
        expect(root, contains('/cn.ustcassistant.mobile.qa/no_backup/'));
        final fixture = await Directory(root!).createTemp('a7_source_');
        RuntimeBootstrap? bootstrap;
        try {
          bootstrap = await RuntimeBootstrap.open(
            platformFactory: _SourceFixturePlatform(fixture.path),
          );
          final runtime = bootstrap.runtime!;
          await runtime.jwSync.startSync(
            expectedAccountCode: 'SYNTH0001',
            password: 'synthetic-password',
            savePassword: true,
          );
          expect(runtime.jwSync.syncView.phase, JwSyncPhase.idle);
          expect(
            runtime.jwSync.syncView.failure,
            FailureCode.unsupportedPlatform,
          );
          expect(bootstrap.leases.isBusy, isFalse);
          await runtime.youngSync.startActivities(
            expectedAccountCode: 'SYNTH0001',
            password: 'synthetic-password',
            savePassword: true,
          );
          expect(runtime.youngSync.syncView.phase, YoungSyncPhase.idle);
          expect(
            runtime.youngSync.syncView.failure,
            FailureCode.unsupportedPlatform,
          );
          expect(bootstrap.leases.isBusy, isFalse);
          expect((await runtime.jwStore.readView()).credentialSaved, isFalse);
          for (final namespace in ['jw_partitions_v1', 'young_partitions_v1']) {
            final entries = await Directory(
              '${runtime.jwDirectory.path}/$namespace',
            ).list(followLinks: false).toList();
            expect(entries.whereType<Directory>(), isEmpty);
          }
          final context =
              (await runtime.jwStore.localCalendar.readPlanContext()).$1;
          final plan = await runtime.jwStore.localCalendar.prepare(
            context,
            CreatePersonalEvent(
              PersonalEventDraft(
                title: 'A7预检拒绝后仍可安排',
                start: DateTime.utc(2026, 10, 17, 6),
                end: DateTime.utc(2026, 10, 17, 7),
              ),
            ),
          );
          await runtime.jwStore.localCalendar.commit(plan);
          binding.reportData = {
            'kind': 'android-a7-formal-preflight-v1',
            'bothSourcesRejectedBeforeStaging': true,
            'localWriteStillAvailable': true,
            'realSchool': false,
          };
        } finally {
          await bootstrap?.close();
          await fixture.delete(recursive: true);
        }
      });
    },
    skip: !Platform.isAndroid,
  );
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
        final browser = NativeObservationBrowser(
          requiresAvailabilityCheck: true,
        );
        try {
          owned.formal.createPlainChildDirectory('jw_partitions_v1');
          final path = owned.formal.createPlainChildDirectory(
            'jw_partitions_v1/jwp-${'a' * 32}',
          );
          // Fixed loopback only. Feature rejection occurs before any load.
          final target = ObservationTarget.fixture(
            Uri.parse('http://127.0.0.1:43127/cas/login'),
          );
          await expectLater(
            browser.ensureAvailable(),
            throwsA(
              isA<AppFailure>().having(
                (error) => error.code,
                'preflight',
                FailureCode.unsupportedPlatform,
              ),
            ),
          );
          for (final recovery in [false, true]) {
            final session = recovery ? 2 : 1;
            await expectLater(
              browser.open(
                session: session,
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
            await browser.close(session);
            expect(await browser.drained(session), isTrue);
            expect(await browser.drained(99), isFalse);
          }
          await expectLater(
            browser.close(99),
            throwsA(
              isA<AppFailure>().having(
                (error) => error.code,
                'wrong session',
                FailureCode.staleResult,
              ),
            ),
          );
          binding.reportData = {
            'kind': 'android-a7-old-provider-v1',
            'acquisitionRejected': true,
            'cleanupUnavailableReported': true,
            'rejectedSessionDrained': true,
            'oldProfilesCleared': false,
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

final class _SourceFixturePlatform implements RuntimePlatformFactory {
  const _SourceFixturePlatform(this.path);
  final String path;
  static const _delegate = AndroidRuntimePlatformFactory();
  @override
  Future<RuntimeDirectories> acquireDirectories({
    String? directoryPath,
    String? jwDirectoryPath,
  }) async {
    final roots = await AndroidDirectories.acquire(path);
    return RuntimeDirectories(demo: roots.demo, formal: roots.formal);
  }

  @override
  JwCredentialProtector get schoolCredentials => _delegate.schoolCredentials;
  @override
  ModelCredentialProtector get modelCredentials => _delegate.modelCredentials;
  @override
  NativeObservationBrowser createBrowser() => _delegate.createBrowser();
  @override
  NotificationPlatformPort createNotifications() =>
      _delegate.createNotifications();
  @override
  SpeechInputPort createSpeech(DiagnosticsPort diagnostics) =>
      _delegate.createSpeech(diagnostics);
}
