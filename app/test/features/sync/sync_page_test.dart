import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/security/credential_protector.dart';
import 'package:ustc_assistant_app/features/accounts/application/account_service.dart';
import 'package:ustc_assistant_app/features/import/domain/import_result.dart';
import 'package:ustc_assistant_app/features/sync/application/sync_coordinator.dart';
import 'package:ustc_assistant_app/features/sync/data/bridge_client.dart';
import 'package:ustc_assistant_app/features/sync/domain/sync_state.dart';
import 'package:ustc_assistant_app/features/sync/presentation/sync_page.dart';

class _TestProtector implements CredentialProtector {
  @override
  Future<ProtectedSecret> protect(Uint8List plaintext) async =>
      ProtectedSecret(bytes: plaintext, scheme: 'test', version: 1);

  @override
  Future<Uint8List> unprotect(ProtectedSecret protected) async =>
      protected.bytes;
}

class _UnusedBridge implements BridgeGateway {
  @override
  Future<BridgeCapabilities> capabilities() => throw UnimplementedError();

  @override
  Future<void> cancel(String jobId) => throw UnimplementedError();

  @override
  Future<BridgeJobPoll> poll(String jobId, int after) =>
      throw UnimplementedError();

  @override
  Future<void> resumeLogin(String jobId, {String? password}) =>
      throw UnimplementedError();

  @override
  Future<void> shutdown() async {}

  @override
  Future<BridgeJob> startCollection({
    required SyncSource source,
    required String accountId,
    required String expectedUsername,
    required BridgeSemesterCapability jwSemester,
  }) => throw UnimplementedError();
}

void main() {
  testWidgets('first launch offers a school account login form', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final accounts = AccountService(
      database: database,
      protector: _TestProtector(),
    );
    final coordinator = SyncCoordinator(
      database: database,
      accounts: accounts,
      bridgeFactory: () async => _UnusedBridge(),
      importBundle: (bytes, {required accountId, required origin}) async =>
          const ImportResult(
            status: ImportStatus.imported,
            bundleId: 'unused',
            source: 'ustc_jw',
            importedEntityCount: 0,
          ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SyncPage(accounts: accounts, coordinator: coordinator),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('first-login-username')), findsOneWidget);
    expect(find.byKey(const Key('first-login-password')), findsOneWidget);
    expect(find.text('保存密码'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '登录并同步教务'), findsOneWidget);
  });
}
