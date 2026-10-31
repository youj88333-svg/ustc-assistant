// Design: approved I1 execution contract; architecture 07-12, quality 13,
// workflow 15. Simulator-only private storage and typed credential probes.
import 'dart:io';

import 'package:drift/drift.dart'
    show GeneratedDatabase, OpeningDetails, QueryExecutor, QueryExecutorUser;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/m0_entry.dart';
import 'package:ustc_assistant_m0/platform/ios_credential_protector.dart';
import 'package:ustc_assistant_m0/platform/ios_directory.dart';
import 'package:ustc_assistant_m0/platform/ios_runtime_platform_factory.dart';
import 'package:ustc_assistant_m0/platform/native_database.dart';

const _platformChannel = MethodChannel('ustc_assistant/platform_v1');
const _credentialMechanism = 'ios-keychain-aes-gcm-v1';
const _probeTable = 'ios_i1_synthetic_probe';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'iOS I1 private root, Darwin ownership, SQLite and bootstrap lifecycle',
    (tester) async {
      const platform = IOSRuntimePlatformFactory();
      String? root;
      RuntimeBootstrap? first;
      RuntimeBootstrap? reopened;
      var appMounted = false;

      try {
        await tester.runAsync(() async {
          root = await IOSRuntimePlatformFactory.fetchPrivateDataRoot();
          expect(
            root,
            endsWith('/Library/Application Support/ustc_assistant_v1'),
          );

          final firstLease = await platform.acquireDirectories();
          expect(firstLease.demo.path, '$root/demo_v1');
          expect(firstLease.formal.path, '$root/local_v1');
          await expectLater(
            IOSDirectories.acquire(root!),
            _appFailure(FailureCode.ownerConflict),
          );
          await firstLease.formal.release();
          await firstLease.demo.release();

          final reacquired = await IOSDirectories.acquire(root!);
          expect(reacquired.demo.isHeld, isTrue);
          await reacquired.formal.release();
          await reacquired.demo.release();
        });

        final firstBootstrap = await tester.runAsync(
          () => RuntimeBootstrap.open(platformFactory: platform),
        );
        if (firstBootstrap == null) {
          throw StateError('I1 bootstrap did not return');
        }
        first = firstBootstrap;
        final runtime = firstBootstrap.runtime;
        if (runtime == null) throw StateError('I1 bootstrap did not activate');

        await tester.runAsync(() async {
          await _exerciseStore(runtime.store, 'demo-kept-v1');
          await _exerciseStore(runtime.jwStore, 'formal-kept-v1');
          await _expectStoreValue(runtime.store, 'demo-kept-v1');
          await _expectStoreValue(runtime.jwStore, 'formal-kept-v1');

          final status = await _readProtectionStatus();
          if (status == null) {
            throw StateError('iOS storage status returned no map');
          }
          expect(status.keys.toSet(), {
            'kind',
            'excludedFromBackup',
            'filesInspected',
            'filesProtected',
          });
          expect(status['kind'], 'ios-storage-protection-v1');
          expect(status['excludedFromBackup'], isTrue);
          expect(status['filesInspected'], isA<int>());
          expect(status['filesInspected'] as int, greaterThanOrEqualTo(2));
          expect(status['filesProtected'], isTrue);

          expect(runtime.browser.requiresAvailabilityCheck, isTrue);
          expect(runtime.browser.supportsIsolatedCleanupPending, isFalse);
          await expectLater(
            runtime.browser.ensureAvailable(),
            _appFailure(FailureCode.unsupportedPlatform),
          );

          final notifications = platform.createNotifications();
          expect((await notifications.initialize()).available, isFalse);
          await expectLater(
            notifications.pending(),
            isA<ReminderFailure>().having(
              (error) => error.code,
              'stable code',
              ReminderFailureCode.platformUnavailable,
            ),
          );
          await notifications.close();

          final speech = platform.createSpeech(runtime.diagnostics);
          await speech.start();
          expect(
            speech.view.failure,
            SpeechInputFailureCode.unsupportedPlatform,
          );
          expect(speech.view.transcript, isNull);
          await speech.close();
        });

        // Exercise the application's real lifecycle listener. The new test
        // app sandbox has no enrolled source, so foregrounding cannot sync.
        await tester.pumpWidget(OwnedApplication(bootstrap: firstBootstrap));
        appMounted = true;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
        _foreground(tester.binding);
        await tester.pump();
        final ownedRuntime = firstBootstrap.runtime;
        if (ownedRuntime == null) {
          throw StateError('I1 runtime closed during lifecycle exercise');
        }
        expect(ownedRuntime, same(runtime));

        _background(tester.binding);
        await tester.pump();
        expect(firstBootstrap.runtime, same(ownedRuntime));
        expect(ownedRuntime.directory.isHeld, isTrue);
        expect(ownedRuntime.jwDirectory.isHeld, isTrue);
        await tester.runAsync(
          () => expectLater(
            IOSDirectories.acquire(root!),
            _appFailure(FailureCode.ownerConflict),
          ),
        );

        _foreground(tester.binding);
        await tester.pump();
        expect(firstBootstrap.runtime, same(ownedRuntime));
        expect(ownedRuntime.directory.isHeld, isTrue);
        expect(ownedRuntime.jwDirectory.isHeld, isTrue);
        await tester.runAsync(
          () => expectLater(
            IOSDirectories.acquire(root!),
            _appFailure(FailureCode.ownerConflict),
          ),
        );

        await tester.pumpWidget(const SizedBox.shrink());
        appMounted = false;
        await tester.runAsync(firstBootstrap.close);

        // Reacquire the real databases without a bootstrap. Existing Drift
        // stores are closed, so this directly exercises the lease interceptor.
        await tester.runAsync(() async {
          final lease = await IOSDirectories.acquire(root!);
          QueryExecutor? demo;
          QueryExecutor? formal;
          try {
            final demoDatabase = openDemoDatabase(lease.demo);
            demo = demoDatabase;
            final formalDatabase = openJwDatabase(lease.formal);
            formal = formalDatabase;
            await demoDatabase.ensureOpen(const _ProbeDatabaseUser());
            await formalDatabase.ensureOpen(const _ProbeDatabaseUser());
            await _expectPragmas(demoDatabase);
            await _expectPragmas(formalDatabase);
            await _expectExecutorValue(demoDatabase, 'demo-kept-v1');
            await _expectExecutorValue(formalDatabase, 'formal-kept-v1');

            await lease.formal.release();
            await lease.demo.release();
            await expectLater(
              () => demoDatabase.runSelect('SELECT 1', const []),
              throwsA(_appFailure(FailureCode.ownershipLost)),
            );
            await expectLater(
              () => formalDatabase.runSelect('SELECT 1', const []),
              throwsA(_appFailure(FailureCode.ownershipLost)),
            );
            await expectLater(
              demoDatabase.beginTransaction,
              throwsA(_appFailure(FailureCode.ownershipLost)),
            );
          } finally {
            await demo?.close();
            await formal?.close();
            // If an earlier assertion failed before normal release, still
            // drain both wrappers so this test never retains its own lock.
            await lease.formal.release();
            await lease.demo.release();
          }

          final freshLease = await IOSDirectories.acquire(root!);
          QueryExecutor? freshDemo;
          QueryExecutor? freshFormal;
          try {
            freshDemo = openDemoDatabase(freshLease.demo);
            freshFormal = openJwDatabase(freshLease.formal);
            await freshDemo.ensureOpen(const _ProbeDatabaseUser());
            await freshFormal.ensureOpen(const _ProbeDatabaseUser());
            await _expectExecutorValue(freshDemo, 'demo-kept-v1');
            await _expectExecutorValue(freshFormal, 'formal-kept-v1');
          } finally {
            await freshDemo?.close();
            await freshFormal?.close();
            await freshLease.formal.release();
            await freshLease.demo.release();
          }
        });

        final reopenedBootstrap = await tester.runAsync(
          () => RuntimeBootstrap.open(platformFactory: platform),
        );
        if (reopenedBootstrap == null) {
          throw StateError('I1 reopened bootstrap did not return');
        }
        reopened = reopenedBootstrap;
        final reopenedRuntime = reopenedBootstrap.runtime;
        if (reopenedRuntime == null) {
          throw StateError('I1 reopened bootstrap did not activate');
        }
        await tester.runAsync(() async {
          await _expectStoreValue(reopenedRuntime.store, 'demo-kept-v1');
          await _expectStoreValue(reopenedRuntime.jwStore, 'formal-kept-v1');
          final status = await _readProtectionStatus();
          if (status == null) {
            throw StateError('iOS storage status returned no map');
          }
          expect(status['filesProtected'], isTrue);
          await _dropProbeTables(reopenedRuntime);
        });
        await tester.runAsync(reopenedBootstrap.close);
        reopened = null;
      } finally {
        if (appMounted) {
          await tester.pumpWidget(const SizedBox.shrink());
        }
        if (first != null) await tester.runAsync(first.close);
        if (reopened != null) await tester.runAsync(reopened.close);
      }
    },
    skip: !Platform.isIOS,
  );

  testWidgets(
    'iOS Keychain protectors roundtrip only synthetic typed values',
    (tester) async {
      const school = IOSJwCredentialProtector();
      const model = IOSModelCredentialProtector();
      const owner = '0123456789abcdef0123456789abcdef';
      final schoolPurpose =
          'ustc-assistant/jw/login/v1:jw-owner-$owner:${List.filled(64, 'a').join()}';
      final otherSchoolPurpose =
          'ustc-assistant/jw/login/v1:jw-owner-$owner:${List.filled(64, 'b').join()}';
      final modelPurpose = 'ustc-model-key/v1/jw-owner-$owner';
      const otherOwner = 'fedcba9876543210fedcba9876543210';
      final otherModelPurpose = 'ustc-model-key/v1/jw-owner-$otherOwner';
      final schoolPlaintext = Uint8List.fromList([0x49, 0x31, 0x2d, 0x53]);
      final modelPlaintext = Uint8List.fromList([0x49, 0x31, 0x2d, 0x4d]);

      await tester.runAsync(() async {
        expect(school.mechanism, _credentialMechanism);
        expect(model.mechanism, _credentialMechanism);
        final schoolEnvelope = await school.protect(
          schoolPlaintext,
          purpose: schoolPurpose,
        );
        expect(
          await school.unprotect(schoolEnvelope, purpose: schoolPurpose),
          equals(schoolPlaintext),
        );
        final damagedSchoolEnvelope = Uint8List.fromList(schoolEnvelope)
          ..[schoolEnvelope.length - 1] ^= 1;
        await expectLater(
          school.unprotect(damagedSchoolEnvelope, purpose: schoolPurpose),
          isA<JwCredentialException>().having(
            (error) => error.code,
            'stable code',
            JwCredentialFailure.invalidCredential,
          ),
        );
        await expectLater(
          school.unprotect(schoolEnvelope, purpose: otherSchoolPurpose),
          isA<JwCredentialException>().having(
            (error) => error.code,
            'stable code',
            JwCredentialFailure.invalidCredential,
          ),
        );

        final modelEnvelope = await model.protect(
          modelPlaintext,
          purpose: modelPurpose,
        );
        expect(
          await model.unprotect(modelEnvelope, purpose: modelPurpose),
          equals(modelPlaintext),
        );
        final damagedModelEnvelope = Uint8List.fromList(modelEnvelope)
          ..[modelEnvelope.length - 1] ^= 1;
        await expectLater(
          model.unprotect(damagedModelEnvelope, purpose: modelPurpose),
          isA<AgentFailure>().having(
            (error) => error.code,
            'stable code',
            AgentFailureCode.protectionFailed,
          ),
        );
        await expectLater(
          model.unprotect(modelEnvelope, purpose: otherModelPurpose),
          isA<AgentFailure>().having(
            (error) => error.code,
            'stable code',
            AgentFailureCode.protectionFailed,
          ),
        );
      });
    },
    skip: !Platform.isIOS,
  );
}

Matcher _appFailure(FailureCode code) =>
    isA<AppFailure>().having((error) => error.code, 'stable code', code);

Future<Map<String, Object?>?> _readProtectionStatus() => _platformChannel
    .invokeMapMethod<String, Object?>('storageProtectionStatus');

Future<void> _exerciseStore(GeneratedDatabase store, String marker) async {
  await store.customStatement('DROP TABLE IF EXISTS $_probeTable');
  await store.customStatement('CREATE TABLE $_probeTable(value TEXT NOT NULL)');
  await store.customStatement('INSERT INTO $_probeTable(value) VALUES (?)', [
    marker,
  ]);
  await expectLater(
    store.transaction(() async {
      await store.customStatement(
        'INSERT INTO $_probeTable(value) VALUES (?)',
        ['rolled-back'],
      );
      throw const _RollbackProbe();
    }),
    throwsA(isA<_RollbackProbe>()),
  );
  await _expectStoreValue(store, marker);
}

Future<void> _expectStoreValue(GeneratedDatabase store, String value) async {
  final rows = await store.customSelect('SELECT value FROM $_probeTable').get();
  expect(rows.map((row) => row.data['value']), [value]);
}

Future<void> _expectExecutorValue(QueryExecutor executor, String value) async {
  final rows = await executor.runSelect('SELECT value FROM $_probeTable', []);
  expect(rows.map((row) => row['value']), [value]);
}

Future<void> _expectPragmas(QueryExecutor executor) async {
  for (final entry in const {
    'foreign_keys': 1,
    'journal_mode': 'wal',
    'synchronous': 2,
    'busy_timeout': 3000,
  }.entries) {
    final rows = await executor.runSelect('PRAGMA ${entry.key}', []);
    expect(rows.single.values.single, entry.value, reason: entry.key);
  }
}

Future<void> _dropProbeTables(DemoRuntime runtime) async {
  await runtime.store.customStatement('DROP TABLE IF EXISTS $_probeTable');
  await runtime.jwStore.customStatement('DROP TABLE IF EXISTS $_probeTable');
}

void _background(WidgetsBinding binding) {
  if (binding.lifecycleState == AppLifecycleState.resumed) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  if (binding.lifecycleState == AppLifecycleState.inactive) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
  if (binding.lifecycleState == AppLifecycleState.hidden) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  }
}

void _foreground(WidgetsBinding binding) {
  if (binding.lifecycleState == AppLifecycleState.paused) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
  if (binding.lifecycleState == AppLifecycleState.hidden) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  if (binding.lifecycleState != AppLifecycleState.resumed) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }
}

final class _ProbeDatabaseUser implements QueryExecutorUser {
  const _ProbeDatabaseUser();

  @override
  int get schemaVersion => JwStore.currentSchemaVersion;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}

final class _RollbackProbe implements Exception {
  const _RollbackProbe();
}
