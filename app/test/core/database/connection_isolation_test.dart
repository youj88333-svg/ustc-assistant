import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// The test replaces the platform path provider with a synthetic, worktree
// local provider; pubspec changes are intentionally out of scope here.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:ustc_assistant_app/app/app.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/database/connection.dart';
import 'package:ustc_assistant_app/core/security/credential_protector.dart';
import 'package:ustc_assistant_app/core/storage/minimal_storage.dart';
import 'package:ustc_assistant_app/features/accounts/application/account_service.dart';
import 'package:ustc_assistant_app/features/settings/application/minimal_reset_coordinator.dart';
import 'package:ustc_assistant_app/features/settings/application/settings_service.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_browser_session_admin.dart';
import 'package:ustc_assistant_app/features/sync/native/jw_webview_surface_host.dart';
import 'package:ustc_assistant_app/features/sync/native/windows_jw_udf_store.dart';
import 'package:ustc_assistant_app/features/sync/domain/sync_state.dart';
import 'package:ustc_assistant_app/features/sync/runtime/minimal_jw_runtime.dart';
import 'package:ustc_assistant_app/features/sync/runtime/source_job_gateway.dart';

void main() {
  late PathProviderPlatform originalPathProvider;
  late Directory testRoot;
  late Directory documentsRoot;
  late Directory supportRoot;
  late Directory temporaryRoot;

  setUp(() async {
    originalPathProvider = PathProviderPlatform.instance;
    testRoot = Directory(
      '${Directory.current.path}${Platform.pathSeparator}build'
      '${Platform.pathSeparator}storage-isolation-${DateTime.now().microsecondsSinceEpoch}',
    );
    documentsRoot = Directory(
      '${testRoot.path}${Platform.pathSeparator}documents',
    );
    supportRoot = Directory('${testRoot.path}${Platform.pathSeparator}support');
    temporaryRoot = Directory(
      '${testRoot.path}${Platform.pathSeparator}temporary',
    );
    await documentsRoot.create(recursive: true);
    await supportRoot.create(recursive: true);
    await temporaryRoot.create(recursive: true);
    PathProviderPlatform.instance = _SyntheticPathProvider(
      documents: documentsRoot.path,
      support: supportRoot.path,
      temporary: temporaryRoot.path,
    );
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalPathProvider;
    await _deleteSyntheticRoot(testRoot);
  });

  test(
    'production connection uses the minimal support namespace and ignores old documents data',
    () async {
      final oldDatabaseFile = File(
        '${documentsRoot.path}${Platform.pathSeparator}ustc_assistant.sqlite',
      );
      final oldDatabase = AppDatabase(NativeDatabase(oldDatabaseFile));
      await oldDatabase
          .into(oldDatabase.localAccounts)
          .insert(
            LocalAccountsCompanion.insert(
              id: 'old-shared-account',
              maskedHint: 'OLD****0000',
              isActive: const Value(true),
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await oldDatabase.close();
      final oldBytes = await oldDatabaseFile.readAsBytes();

      final database = AppDatabase(openAppDatabase());
      addTearDown(database.close);

      final databaseList = await database
          .customSelect('PRAGMA database_list')
          .get();
      final actualDatabasePath = databaseList
          .firstWhere((row) => row.read<int>('seq') == 0)
          .read<String>('file');
      final expectedDatabasePath =
          '${supportRoot.path}${Platform.pathSeparator}branches'
          '${Platform.pathSeparator}minimal${Platform.pathSeparator}ustc_assistant.sqlite';

      expect(
        _normalized(actualDatabasePath),
        _normalized(expectedDatabasePath),
      );
      expect(await database.select(database.localAccounts).get(), isEmpty);
      expect(await oldDatabaseFile.readAsBytes(), oldBytes);
    },
  );

  test(
    'production connection rejects a redirected minimal database file',
    () async {
      final root = await resolveMinimalStorageRoot();
      final outsideFile = File(
        '${testRoot.path}${Platform.pathSeparator}outside.sqlite',
      );
      await outsideFile.writeAsString('outside-sentinel');
      final redirectedDatabase = Link(
        '${root.path}${Platform.pathSeparator}ustc_assistant.sqlite',
      );
      await redirectedDatabase.create(outsideFile.path);

      Object? error;
      try {
        await resolveMinimalStorageRoot();
      } on Object catch (caught) {
        error = caught;
      }
      expect(error, isA<MinimalStorageError>());
      expect(await outsideFile.readAsString(), 'outside-sentinel');
    },
    skip: !Platform.isWindows,
  );

  test(
    'minimal database data persists while old shared bytes stay unchanged',
    () async {
      final oldDatabaseFile = File(
        '${documentsRoot.path}${Platform.pathSeparator}ustc_assistant.sqlite',
      );
      final oldDatabase = AppDatabase(NativeDatabase(oldDatabaseFile));
      await oldDatabase
          .into(oldDatabase.localAccounts)
          .insert(
            LocalAccountsCompanion.insert(
              id: 'old-shared-account',
              maskedHint: 'OLD****0000',
              isActive: const Value(true),
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await oldDatabase.close();
      final oldBytes = await oldDatabaseFile.readAsBytes();

      final first = AppDatabase(openAppDatabase());
      await first
          .into(first.localAccounts)
          .insert(
            LocalAccountsCompanion.insert(
              id: 'minimal-account',
              maskedHint: 'MINI****0000',
              isActive: const Value(true),
              createdAt: 2,
              updatedAt: 2,
            ),
          );
      await first.close();

      final second = AppDatabase(openAppDatabase());
      addTearDown(second.close);
      expect(
        (await second.select(second.localAccounts).get()).map((row) => row.id),
        contains('minimal-account'),
      );
      expect(await oldDatabaseFile.readAsBytes(), oldBytes);
    },
  );

  test(
    'storage resolution failure is stable and never falls back to Documents',
    () async {
      final oldDatabaseFile = File(
        '${documentsRoot.path}${Platform.pathSeparator}ustc_assistant.sqlite',
      );
      final oldDatabase = AppDatabase(NativeDatabase(oldDatabaseFile));
      await oldDatabase
          .into(oldDatabase.localAccounts)
          .insert(
            LocalAccountsCompanion.insert(
              id: 'old-shared-account',
              maskedHint: 'OLD****0000',
              isActive: const Value(true),
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      await oldDatabase.close();
      final oldBytes = await oldDatabaseFile.readAsBytes();
      PathProviderPlatform.instance = _SyntheticPathProvider(
        documents: documentsRoot.path,
        support: null,
        temporary: temporaryRoot.path,
      );

      Object? error;
      try {
        await resolveMinimalStorageRoot();
      } on Object catch (caught) {
        error = caught;
      }

      expect(error, isA<MinimalStorageError>());
      expect(error.toString(), MinimalStorageError().toString());
      expect(error.toString(), isNot(contains(documentsRoot.path)));
      expect(
        await Directory(
          '${supportRoot.path}${Platform.pathSeparator}branches',
        ).exists(),
        isFalse,
      );
      expect(await oldDatabaseFile.readAsBytes(), oldBytes);
    },
  );

  test(
    'redirected minimal branch is rejected without touching its outside target',
    () async {
      final outside = Directory(
        '${testRoot.path}${Platform.pathSeparator}outside-root',
      );
      await outside.create(recursive: true);
      final sentinel = File('${outside.path}${Platform.pathSeparator}sentinel');
      await sentinel.writeAsString('outside-sentinel');
      final branches = Directory(
        '${supportRoot.path}${Platform.pathSeparator}branches',
      );
      await branches.create(recursive: true);
      final redirected = Link(
        '${branches.path}${Platform.pathSeparator}minimal',
      );
      await redirected.create(outside.path);

      Object? error;
      try {
        await resolveMinimalStorageRoot();
      } on Object catch (caught) {
        error = caught;
      }

      expect(error, isA<MinimalStorageError>());
      expect(await sentinel.readAsString(), 'outside-sentinel');
    },
    skip: !Platform.isWindows,
  );

  test('production reset clears only the isolated minimal stores', () async {
    final oldDatabaseFile = File(
      '${documentsRoot.path}${Platform.pathSeparator}ustc_assistant.sqlite',
    );
    final oldDatabase = AppDatabase(NativeDatabase(oldDatabaseFile));
    await oldDatabase
        .into(oldDatabase.localAccounts)
        .insert(
          LocalAccountsCompanion.insert(
            id: 'old-shared-account',
            maskedHint: 'OLD****0000',
            isActive: const Value(true),
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await oldDatabase
        .into(oldDatabase.credentialAccounts)
        .insert(
          CredentialAccountsCompanion.insert(
            accountId: 'old-shared-account',
            usernameCiphertext: Uint8List.fromList(<int>[1, 2, 3]),
            passwordCiphertext: Value(Uint8List.fromList(<int>[4, 5, 6])),
            scheme: 'test',
            updatedAt: 1,
          ),
        );
    await oldDatabase.close();
    final oldBytes = await oldDatabaseFile.readAsBytes();
    final sharedWebviewMarker = File(
      '${supportRoot.path}${Platform.pathSeparator}webview'
      '${Platform.pathSeparator}shared-profile${Platform.pathSeparator}sentinel',
    );
    await sharedWebviewMarker.parent.create(recursive: true);
    await sharedWebviewMarker.writeAsString('shared-webview-sentinel');
    final sharedBrowserSessionsMarker = File(
      '${supportRoot.path}${Platform.pathSeparator}browser_sessions'
      '${Platform.pathSeparator}shared-profile${Platform.pathSeparator}sentinel',
    );
    await sharedBrowserSessionsMarker.parent.create(recursive: true);
    await sharedBrowserSessionsMarker.writeAsString(
      'shared-browser-sessions-sentinel',
    );

    final database = AppDatabase(openAppDatabase());
    addTearDown(database.close);
    await database
        .into(database.localAccounts)
        .insert(
          LocalAccountsCompanion.insert(
            id: 'minimal-account',
            maskedHint: 'MINI****0000',
            isActive: const Value(true),
            createdAt: 2,
            updatedAt: 2,
          ),
        );
    await database
        .into(database.credentialAccounts)
        .insert(
          CredentialAccountsCompanion.insert(
            accountId: 'minimal-account',
            usernameCiphertext: Uint8List.fromList(<int>[7, 8, 9]),
            passwordCiphertext: Value(Uint8List.fromList(<int>[10, 11, 12])),
            scheme: 'test',
            updatedAt: 2,
          ),
        );
    final root = await resolveMinimalStorageRoot();
    final sibling = File(
      '${supportRoot.path}${Platform.pathSeparator}branches'
      '${Platform.pathSeparator}rewrite${Platform.pathSeparator}sentinel',
    );
    await sibling.parent.create(recursive: true);
    await sibling.writeAsString('sibling-sentinel');
    final store = WindowsJwUdfStore(privateRoot: root);
    final partition = await store.ensurePartition(
      store.referenceFor('minimal-account'),
    );
    await store.markQuarantined(
      store.referenceFor('minimal-account'),
      'collection_failed',
    );

    final settings = SettingsService(
      database: database,
      accounts: AccountService(
        database: database,
        protector: const _NoopProtector(),
      ),
      accountId: null,
    );
    final coordinator = MinimalResetCoordinator(
      runtime: _NoopRuntime().runtime,
      sync: _NoopResetWriter(),
      agent: _NoopResetWriter(),
      reminders: _NoopResetWriter(),
      settings: settings,
      udfStore: store,
      recomposeRuntime: () async {},
    );

    await coordinator.completeReset();

    expect(await database.select(database.localAccounts).get(), isEmpty);
    expect(await database.select(database.credentialAccounts).get(), isEmpty);
    expect(await partition.exists(), isFalse);
    expect(await sibling.readAsString(), 'sibling-sentinel');
    expect(await sharedWebviewMarker.readAsString(), 'shared-webview-sentinel');
    expect(
      await sharedBrowserSessionsMarker.readAsString(),
      'shared-browser-sessions-sentinel',
    );
    expect(await oldDatabaseFile.readAsBytes(), oldBytes);
  });

  testWidgets('default app runtime loads UDF cleanup from the minimal root', (
    tester,
  ) async {
    late final File sharedWebviewMarker;
    late final Directory partition;
    late final AppDatabase database;
    MinimalJwRuntime? runtime;
    await tester.runAsync(() async {
      sharedWebviewMarker = File(
        '${supportRoot.path}${Platform.pathSeparator}webview'
        '${Platform.pathSeparator}shared-profile${Platform.pathSeparator}sentinel',
      );
      await sharedWebviewMarker.parent.create(recursive: true);
      await sharedWebviewMarker.writeAsString('shared-webview-sentinel');
      final root = await resolveMinimalStorageRoot();
      final store = WindowsJwUdfStore(privateRoot: root);
      partition = await store.ensurePartition(
        store.referenceFor('default-runtime-account'),
      );
      database = AppDatabase(NativeDatabase.memory());
    });
    addTearDown(database.close);

    try {
      await tester.pumpWidget(UstcAssistantApp(database: database));
      await tester.pump();
      final state = tester.state<UstcAssistantAppState>(
        find.byType(UstcAssistantApp),
      );
      await tester.runAsync(() async {
        runtime = await state.runtimeOwner.current;
        await runtime!.browserSessions.clearAllPartitions();
        expect(await partition.exists(), isFalse);
        expect(
          await sharedWebviewMarker.readAsString(),
          'shared-webview-sentinel',
        );
      });
    } finally {
      final loadedRuntime = runtime;
      if (loadedRuntime != null) {
        await tester.runAsync(loadedRuntime.shutdown);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
  });
}

String _normalized(String path) =>
    path.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '').toLowerCase();

Future<void> _deleteSyntheticRoot(Directory root) async {
  final normalizedRoot = _normalized(root.absolute.path);
  final expectedParent = _normalized(
    Directory(
      '${Directory.current.path}${Platform.pathSeparator}build',
    ).absolute.path,
  );
  final rootName = normalizedRoot.split('/').last;
  if (_normalized(root.parent.absolute.path) != expectedParent ||
      !RegExp(r'^storage-isolation-[0-9]+$').hasMatch(rootName)) {
    throw StateError('synthetic storage root boundary rejected');
  }

  final type = await FileSystemEntity.type(root.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return;
  if (type != FileSystemEntityType.directory ||
      _normalized(await root.resolveSymbolicLinks()) != normalizedRoot) {
    throw StateError('synthetic storage root containment rejected');
  }
  await _deleteSyntheticChildren(root);
  await root.delete();
}

Future<void> _deleteSyntheticChildren(Directory directory) async {
  await for (final entry in directory.list(followLinks: false)) {
    final type = await FileSystemEntity.type(entry.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) continue;
    if (type == FileSystemEntityType.link) {
      await entry.delete();
      continue;
    }
    if (type == FileSystemEntityType.directory) {
      final child = Directory(entry.path);
      final canonical = _normalized(child.absolute.path);
      final resolved = _normalized(await child.resolveSymbolicLinks());
      if (resolved != canonical) {
        // A reparse/junction must be removed as one entry, never recursively.
        await child.delete();
        continue;
      }
      await _deleteSyntheticChildren(child);
      await child.delete();
      continue;
    }
    await entry.delete();
  }
}

final class _SyntheticPathProvider extends PathProviderPlatform {
  _SyntheticPathProvider({
    required this.documents,
    required this.support,
    required this.temporary,
  });

  final String documents;
  final String? support;
  final String temporary;

  @override
  Future<String?> getApplicationDocumentsPath() async => documents;

  @override
  Future<String?> getApplicationSupportPath() async => support;

  @override
  Future<String?> getTemporaryPath() async => temporary;
}

final class _NoopProtector implements CredentialProtector {
  const _NoopProtector();

  @override
  Future<ProtectedSecret> protect(Uint8List plaintext) async => ProtectedSecret(
    bytes: Uint8List.fromList(plaintext),
    scheme: 'test',
    version: 1,
  );

  @override
  Future<Uint8List> unprotect(ProtectedSecret protected) async =>
      Uint8List.fromList(protected.bytes);
}

final class _NoopResetWriter implements ResetWriterPort {
  @override
  Future<void> quiesce() async {}

  @override
  Future<void> resume() async {}
}

final class _NoopRuntime {
  _NoopRuntime()
    : runtime = MinimalJwRuntime(
        gateway: _NoopGateway(),
        browserSessions: _NoopSessionAdmin(),
      );

  final MinimalJwRuntime runtime;
}

final class _NoopGateway implements SourceJobGateway {
  @override
  Stream<SourceJobSnapshot> get states => const Stream.empty();

  @override
  Future<void> cancelCurrent() async {}

  @override
  Future<SyncOutcome> firstLogin(FirstLoginCommand command) =>
      throw UnimplementedError();

  @override
  Future<SyncOutcome> sync({
    required String accountId,
    required SyncTrigger trigger,
  }) => throw UnimplementedError();

  @override
  Future<void> shutdown() async {}
}

final class _NoopSessionAdmin implements JwBrowserSessionAdmin {
  @override
  JwWebViewSurfaceHost get surfaceHost => JwWebViewSurfaceHost();

  @override
  Future<JwBrowserSessionHandle> open(String accountId) =>
      throw UnimplementedError();

  @override
  Future<void> clearAllPartitions() async {}

  @override
  Future<void> shutdown() async {}
}
