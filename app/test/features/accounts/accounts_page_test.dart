import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/security/credential_protector.dart';
import 'package:ustc_assistant_app/features/accounts/application/account_service.dart';
import 'package:ustc_assistant_app/features/accounts/presentation/accounts_page.dart';

class Protector implements CredentialProtector {
  @override
  Future<ProtectedSecret> protect(Uint8List plaintext) async => ProtectedSecret(
    bytes: Uint8List.fromList(plaintext.map((value) => value ^ 0xAA).toList()),
    scheme: 'test',
    version: 1,
  );

  @override
  Future<Uint8List> unprotect(ProtectedSecret protected) async =>
      Uint8List.fromList(protected.bytes.map((value) => value ^ 0xAA).toList());
}

void main() {
  testWidgets('credential and browser clearing use separate confirmations', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    var browserClears = 0;
    final service = AccountService(
      database: database,
      protector: Protector(),
      clearBrowserSession: () async => browserClears++,
    );
    final id = await service.persistVerifiedAccount(
      username: 'PB00000000',
      password: 'secret',
      savePassword: true,
    );
    await tester.pumpWidget(MaterialApp(home: AccountsPage(service: service)));
    await tester.pumpAndSettle();
    expect(find.text('PB****0000'), findsOneWidget);
    expect(find.text('已保存密码：是'), findsOneWidget);

    await tester.tap(find.byKey(Key('delete-credentials-$id')));
    await tester.pumpAndSettle();
    expect(find.text('只删除加密保存的账号与密码，不清除浏览器登录会话。'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      await database.select(database.credentialAccounts).get(),
      hasLength(1),
    );

    await tester.tap(find.byKey(Key('clear-browser-$id')));
    await tester.pumpAndSettle();
    expect(find.text('只清除专用 Edge 登录会话，不删除已保存凭据。'), findsOneWidget);
    await tester.tap(find.text('清除会话'));
    await tester.pumpAndSettle();
    expect(browserClears, 1);
    expect(
      await database.select(database.credentialAccounts).get(),
      hasLength(1),
    );
  });

  testWidgets('account page shows persisted per-source sync success', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = AccountService(database: database, protector: Protector());
    final id = await service.persistVerifiedAccount(username: 'PB00000000');
    await database
        .into(database.sourceConfigs)
        .insert(
          SourceConfigsCompanion.insert(
            id: '$id:ustc_jw',
            accountId: id,
            source: 'ustc_jw',
            lastSuccessAt: const Value(123456789),
            updatedAt: 123456789,
          ),
        );
    await database
        .into(database.sourceConfigs)
        .insert(
          SourceConfigsCompanion.insert(
            id: '$id:ustc_young_schedule',
            accountId: id,
            source: 'ustc_young_schedule',
            lastSuccessAt: const Value(223456789),
            updatedAt: 223456789,
          ),
        );

    await tester.pumpWidget(MaterialApp(home: AccountsPage(service: service)));
    await tester.pumpAndSettle();

    expect(find.textContaining('教务系统：上次同步成功'), findsOneWidget);
    expect(find.textContaining('二课平台：上次同步成功'), findsOneWidget);
  });
}
