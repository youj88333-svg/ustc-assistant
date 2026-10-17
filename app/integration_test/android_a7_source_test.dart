// A7 ordinary WebView boundary: synthetic source-preflight failure is tested
// separately from real Android availability. Architecture07/09, quality13 and
// workflow15; neither path loads a school URL or claims collection.
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

const _syntheticObservationChannel = MethodChannel(
  'ustc_assistant/a7_synthetic_observation_v1',
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'synthetic source preflight rejection leaves local work available with cleanup pending',
    (tester) async {
      await tester.runAsync(() async {
        final root = await const MethodChannel(
          'ustc_assistant/platform_v1',
        ).invokeMethod<String>('privateDataRoot');
        expect(root, contains('/cn.ustcassistant.mobile.qa/no_backup/'));
        final fixture = await Directory(root!).createTemp('a7_source_');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final observationCalls = <String>[];
        messenger.setMockMethodCallHandler(_syntheticObservationChannel, (
          call,
        ) async {
          observationCalls.add(call.method);
          switch (call.method) {
            case 'checkSupport':
              throw PlatformException(
                code: 'app_failure',
                details: FailureCode.unsupportedPlatform.name,
              );
            case 'getCleanupStatus':
              return <String, Object>{
                'backend': ObservationCleanupStatus.backend,
                'pending': true,
                'count': 1,
              };
            default:
              throw StateError('Unexpected synthetic observation RPC.');
          }
        });
        RuntimeBootstrap? bootstrap;
        try {
          bootstrap = await RuntimeBootstrap.open(
            platformFactory: _SourceFixturePlatform(
              fixture.path,
              _syntheticObservationChannel,
            ),
          );
          final runtime = bootstrap.runtime!;
          expect(bootstrap.settings.settingsView.browserCleanupPendingCount, 1);
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
          expect(
            runtime.youngSync.syncView.data?.credentialSaved ?? false,
            isFalse,
          );
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
          expect(bootstrap.settings.settingsView.browserCleanupPendingCount, 1);
          expect(observationCalls, contains('getCleanupStatus'));
          expect(
            observationCalls.where((method) => method == 'checkSupport'),
            hasLength(2),
          );
          expect(
            observationCalls.every(
              (method) =>
                  method == 'checkSupport' || method == 'getCleanupStatus',
            ),
            isTrue,
          );
          binding.reportData = {
            'kind': 'android-a7-formal-preflight-v1',
            'bothSourcesRejectedBeforeStaging': true,
            'localWriteStillAvailable': true,
            'cleanupPendingCount': 1,
            'sourceRequestsIssued': false,
            'realSchool': false,
          };
        } finally {
          try {
            await bootstrap?.close();
          } finally {
            messenger.setMockMethodCallHandler(
              _syntheticObservationChannel,
              null,
            );
            await fixture.delete(recursive: true);
          }
        }
      });
    },
    skip: !Platform.isAndroid,
  );
  testWidgets(
    'actual ordinary Android WebView preflight succeeds without a source request',
    (tester) async {
      await tester.runAsync(() async {
        final browser = NativeObservationBrowser(
          requiresAvailabilityCheck: true,
        );
        try {
          await browser.ensureAvailable();
          expect(await browser.drained(99), isFalse);
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
            'kind': 'android-a7-ordinary-webview-boundary-v1',
            'ordinaryAvailabilityCheckPassed': true,
            'unknownSessionNotDrained': true,
            'unknownSessionCloseRejected': true,
            'sourceRequestsIssued': false,
            'sourceAvailable': false,
            'webViewCollectionNotClaimed': true,
            'realSchool': false,
          };
        } finally {
          await browser.dispose();
        }
      });
    },
    skip: !Platform.isAndroid,
  );
}

final class _SourceFixturePlatform implements RuntimePlatformFactory {
  const _SourceFixturePlatform(this.path, this.channel);
  final String path;
  final MethodChannel channel;
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
  NativeObservationBrowser createBrowser() => NativeObservationBrowser(
    channel: channel,
    requiresAvailabilityCheck: true,
    supportsIsolatedCleanupPending: true,
  );
  @override
  NotificationPlatformPort createNotifications() =>
      _delegate.createNotifications();
  @override
  SpeechInputPort createSpeech(DiagnosticsPort diagnostics) =>
      _delegate.createSpeech(diagnostics);
}
