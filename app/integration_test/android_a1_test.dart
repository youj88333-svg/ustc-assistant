import 'dart:io';

import 'package:drift/drift.dart'
    show QueryExecutor, QueryExecutorUser, OpeningDetails;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:ustc_assistant_m0/app/demo_runtime.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/diagnostics_contract.dart';
import 'package:ustc_assistant_m0/core/jw_credentials.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/core/speech_input_contract.dart';
import 'package:ustc_assistant_m0/data/demo_store.dart';
import 'package:ustc_assistant_m0/platform/android_credential_protector.dart';
import 'package:ustc_assistant_m0/platform/android_directory.dart';
import 'package:ustc_assistant_m0/platform/native_database.dart';
import 'package:ustc_assistant_m0/platform/native_observation_browser.dart';
import 'package:ustc_assistant_m0/platform/runtime_platform_factory.dart';

const _platform = MethodChannel('ustc_assistant/platform_v1');
const _verifyRetained = bool.fromEnvironment('USTC_A1_VERIFY_RETAINED');
final _clock = FixedClock(DateTime.utc(2026, 10, 16, 1));
final _query = CalendarQuery(
  firstDay: DateTime.utc(2026, 10, 16),
  endDayExclusive: DateTime.utc(2026, 10, 17),
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final results = <String, Object>{
    'kind': 'android-a1-validation-v1',
    'realDevice': false,
    'schoolVerified': false,
  };
  final network = _NoNetwork();
  HttpOverrides? previousNetwork;
  setUp(() {
    previousNetwork = HttpOverrides.current;
    HttpOverrides.global = network;
  });
  tearDown(() {
    HttpOverrides.global = previousNetwork;
    expect(
      network.attempts,
      0,
      reason: 'A1 local startup must not contact a source or model',
    );
    binding.reportData = results;
  });

  Matcher failure(FailureCode code) =>
      throwsA(isA<AppFailure>().having((error) => error.code, 'code', code));

  testWidgets(
    'Android app UID holds one parent lease until both children drain',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await _fixture();
        AndroidDirectories? owned;
        try {
          owned = await AndroidDirectories.acquire(fixture.path);
          expect(owned.demo.paths.style, p.Style.posix);
          expect(owned.demo.isHeld && owned.formal.isHeld, isTrue);
          await expectLater(
            AndroidDirectories.acquire(fixture.path),
            failure(FailureCode.ownerConflict),
          );
          await owned.demo.release();
          expect(owned.demo.isHeld, isFalse);
          expect(owned.formal.isHeld, isTrue);
          await expectLater(
            AndroidDirectories.acquire(fixture.path),
            failure(FailureCode.ownerConflict),
          );
          await owned.formal.release();
          owned = await AndroidDirectories.acquire(fixture.path);
          expect(owned.formal.isHeld, isTrue);
          results['exclusiveParent'] = true;
        } finally {
          await owned?.demo.release();
          await owned?.formal.release();
          await _remove(fixture);
        }
      });
    },
    skip: !Platform.isAndroid,
  );

  testWidgets(
    'Android paths reject aliases, links and unsafe database slots',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await _fixture();
        final owned = await AndroidDirectories.acquire(fixture.path);
        try {
          for (final path in [
            '',
            '../outside',
            '/absolute',
            'a/../b',
            'a//b',
            r'a\b',
            'a\u0000',
          ]) {
            expect(
              () => owned.formal.checkedChildPath(path, directory: false),
              failure(FailureCode.unsafeDirectory),
            );
          }
          final outside = File(p.posix.join(fixture.path, 'outside'));
          outside.writeAsStringSync('synthetic');
          final link = Link(p.posix.join(owned.formal.path, 'link'));
          await link.create(outside.path);
          expect(
            () => owned.formal.checkedChildPath('link', directory: false),
            failure(FailureCode.unsafeDirectory),
          );
          final slot = Link(p.posix.join(owned.formal.path, 'jw.sqlite'));
          await slot.create(outside.path);
          expect(
            () => openJwDatabase(owned.formal),
            failure(FailureCode.unsafeDirectory),
          );
          await slot.delete();
          await Directory(
            p.posix.join(owned.formal.path, 'jw.sqlite-wal'),
          ).create();
          expect(
            () => openJwDatabase(owned.formal),
            failure(FailureCode.unsafeDirectory),
          );
          await expectLater(
            AndroidDirectories.acquire('${fixture.path}/.'),
            failure(FailureCode.unsafeDirectory),
          );
          results['unsafePathsRejected'] = true;
        } finally {
          await owned.demo.release();
          await owned.formal.release();
          await _remove(fixture);
        }
      });
    },
    skip: !Platform.isAndroid,
  );

  testWidgets(
    'lock replacement rejects a live transaction but rollback and close drain',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await _fixture();
        var owned = await AndroidDirectories.acquire(fixture.path);
        var store = DemoStore(
          openDemoDatabase(owned.demo),
          ownership: owned.demo,
          clock: _clock,
        );
        try {
          await store.initialize();
          await store.customStatement(
            'CREATE TABLE qa_a1_atomic (value INTEGER)',
          );
          await expectLater(
            store.transaction(() async {
              await store.customStatement(
                'INSERT INTO qa_a1_atomic VALUES (1)',
              );
              await File(
                p.posix.join(fixture.path, '.owner.lock'),
              ).rename(p.posix.join(fixture.path, '.owner.previous'));
              await File(
                p.posix.join(fixture.path, '.owner.lock'),
              ).writeAsString('synthetic');
            }),
            failure(FailureCode.ownershipLost),
          );
          expect(owned.formal.isHeld, isFalse);
          await expectLater(
            () => store.customSelect('SELECT 1').get(),
            failure(FailureCode.ownershipLost),
          );
          await store.close();
          await owned.demo.release();
          await owned.formal.release();
          await File(p.posix.join(fixture.path, '.owner.lock')).delete();
          owned = await AndroidDirectories.acquire(fixture.path);
          store = DemoStore(
            openDemoDatabase(owned.demo),
            ownership: owned.demo,
            clock: _clock,
          );
          await store.initialize();
          expect(
            (await store
                    .customSelect('SELECT count(*) AS n FROM qa_a1_atomic')
                    .getSingle())
                .read<int>('n'),
            0,
          );
          results['lostOwnerRollback'] = true;
        } finally {
          await store.close();
          await owned.demo.release();
          await owned.formal.release();
          await _remove(fixture);
        }
      });
    },
    skip: !Platform.isAndroid,
  );

  testWidgets(
    'unsupported database version preserves bytes and releases failed bootstrap ownership',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await _fixture();
        var owned = await AndroidDirectories.acquire(fixture.path);
        var executor = openJwDatabase(owned.formal);
        try {
          await executor.ensureOpen(const _RawUser());
          await executor.runCustom(
            'CREATE TABLE qa_preserved (value INTEGER)',
            [],
          );
          await executor.runCustom('INSERT INTO qa_preserved VALUES (17)', []);
          await executor.runCustom('PRAGMA user_version = 999', []);
          await executor.close();
          await owned.demo.release();
          await owned.formal.release();
          final rejected = await RuntimeBootstrap.open(
            platformFactory: _FixturePlatform(fixture.path),
            clock: _clock,
          );
          expect(rejected.runtime, isNull);
          expect(
            rejected.settings.settingsView.maintenance.blocksProduct,
            isTrue,
          );
          await rejected.close();
          owned = await AndroidDirectories.acquire(fixture.path);
          executor = openJwDatabase(owned.formal);
          await executor.ensureOpen(const _RawUser());
          expect(
            (await executor.runSelect(
              'SELECT value FROM qa_preserved',
              [],
            )).single['value'],
            17,
          );
          expect(
            (await executor.runSelect(
              'PRAGMA user_version',
              [],
            )).single.values.single,
            999,
          );
          results['migrationFailureRetained'] = true;
        } finally {
          await executor.close();
          await owned.demo.release();
          await owned.formal.release();
          await _remove(fixture);
        }
      });
    },
    skip: !Platform.isAndroid,
  );

  testWidgets(
    'Android default bootstrap and native credential RPC preserve local work',
    (tester) async {
      await tester.runAsync(() async {
        RuntimeBootstrap? bootstrap;
        try {
          bootstrap = await RuntimeBootstrap.open(clock: _clock);
          final runtime = bootstrap.runtime;
          expect(
            runtime,
            isNotNull,
            reason: 'No school account or model Key is required',
          );
          expect(runtime!.directory.path, endsWith('/demo_v1'));
          expect(runtime.jwDirectory.path, endsWith('/local_v1'));
          expect(runtime.jwSync.syncView.accountBound, isFalse);
          final original = await runtime.jwStore.localCalendar.query(_query);
          if (_verifyRetained) {
            expect(
              original.items.length,
              1,
              reason: 'The existing event must survive without reseeding',
            );
          }
          expect(
            original.items.every(
              (item) => item.title == 'A1 synthetic local event',
            ),
            isTrue,
          );
          if (original.items.isEmpty) {
            final command = await runtime.jwStore.localCalendar.prepare(
              original.context,
              CreatePersonalEvent(
                PersonalEventDraft(
                  title: 'A1 synthetic local event',
                  start: DateTime.utc(2026, 10, 16, 2),
                  end: DateTime.utc(2026, 10, 16, 3),
                  location: 'QA-101',
                ),
              ),
            );
            await runtime.jwStore.localCalendar.commit(command);
          }
          final tasks = await runtime.jwStore.localCalendar.queryTasks(
            const TaskQuery(),
          );
          if (_verifyRetained) expect(tasks.items.length, 1);
          expect(
            tasks.items.every(
              (item) => item.draft.title == 'A1 synthetic local task',
            ),
            isTrue,
          );
          if (tasks.items.isEmpty) {
            final command = await runtime.jwStore.localCalendar.prepare(
              tasks.context,
              const CreateTask(TaskDraft(title: 'A1 synthetic local task')),
            );
            await runtime.jwStore.localCalendar.commit(command);
          }
          final plain = Uint8List.fromList([11, 22, 33]);
          final purpose =
              'ustc-assistant/jw/login/v1:jw-owner-${'a' * 32}:${'b' * 64}';
          const protector = AndroidJwCredentialProtector();
          final encrypted = await protector.protect(plain, purpose: purpose);
          final recovered = await protector.unprotect(
            encrypted,
            purpose: purpose,
          );
          expect(recovered, plain);
          recovered.fillRange(0, recovered.length, 0);
          plain.fillRange(0, plain.length, 0);
          await bootstrap.close();
          bootstrap = await RuntimeBootstrap.open(clock: _clock);
          final restored = bootstrap.runtime!;
          expect(
            (await restored.jwStore.localCalendar.query(_query)).items.length,
            1,
          );
          expect(
            (await restored.jwStore.localCalendar.queryTasks(
              const TaskQuery(),
            )).items.length,
            1,
          );
          expect(
            (await restored.jwStore
                    .customSelect('PRAGMA user_version')
                    .getSingle())
                .data
                .values
                .single,
            18,
          );
          for (final (setting, expected) in <(String, Object)>[
            ('foreign_keys', 1),
            ('journal_mode', 'wal'),
            ('synchronous', 2),
            ('busy_timeout', 3000),
          ]) {
            expect(
              (await restored.jwStore
                      .customSelect('PRAGMA $setting')
                      .getSingle())
                  .data
                  .values
                  .single,
              expected,
              reason: 'Android SQLite must retain $setting',
            );
          }
          await restored.diagnostics.flush();
          expect(restored.diagnostics.diagnosticsView.available, isTrue);
          results['nativeCredentialRpc'] = true;
          results['localWorkRetained'] = true;
          results['schema'] = 18;
        } finally {
          await bootstrap?.close();
        }
      });
    },
    skip: !Platform.isAndroid,
  );

  testWidgets(
    'activation failure retains its owner and can retry without rebuilding data',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await _fixture();
        RuntimeBootstrap? bootstrap;
        var attempts = 0;
        try {
          bootstrap = await RuntimeBootstrap.open(
            platformFactory: _FixturePlatform(fixture.path),
            clock: _clock,
            onActivationCheckpoint: () async {
              if (attempts++ == 0) {
                throw const AppFailure(FailureCode.storageFailed);
              }
            },
          );
          expect(bootstrap.runtime, isNull);
          expect(
            bootstrap.directory.isHeld && bootstrap.jwDirectory.isHeld,
            isTrue,
          );
          await expectLater(
            AndroidDirectories.acquire(fixture.path),
            failure(FailureCode.ownerConflict),
          );
          await bootstrap.settings.retryMaintenance();
          expect(bootstrap.runtime, isNotNull);
          expect(attempts, 2);
          expect(
            (await bootstrap.runtime!.jwStore.localCalendar.query(
              _query,
            )).items,
            isEmpty,
          );
          results['activationRecovery'] = true;
        } finally {
          await bootstrap?.close();
          await _remove(fixture);
        }
      });
    },
    skip: !Platform.isAndroid,
  );
}

Future<String> _qaRoot() async {
  final root = await _platform.invokeMethod<String>('privateDataRoot');
  if (root == null ||
      !root.contains('/cn.ustcassistant.mobile.qa/') ||
      !root.endsWith('/no_backup/ustc_assistant_v1')) {
    throw StateError('Only the isolated Android QA sandbox is allowed');
  }
  return root;
}

Future<Directory> _fixture() async =>
    Directory(await _qaRoot()).createTemp('a1_fixture_');
Future<void> _remove(Directory fixture) async {
  final base = await _qaRoot();
  if (!p.posix.isWithin(base, fixture.path) ||
      !p.posix.basename(fixture.path).startsWith('a1_fixture_')) {
    throw StateError('Unexpected synthetic fixture path');
  }
  await fixture.delete(recursive: true);
}

final class _NoNetwork extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('Network is not part of A1 automatic verification');
  }
}

final class _FixturePlatform implements RuntimePlatformFactory {
  const _FixturePlatform(this.path);
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

final class _RawUser implements QueryExecutorUser {
  const _RawUser();
  @override
  int get schemaVersion => 999;
  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}
