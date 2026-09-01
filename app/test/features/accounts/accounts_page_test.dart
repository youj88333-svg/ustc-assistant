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
  testWidgets('empty account page exposes first-login action', (tester) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = AccountService(database: database, protector: Protector());
    var firstLoginPressed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: AccountsPage(
          service: service,
          onFirstLogin: () => firstLoginPressed = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('尚未绑定学校账号'), findsOneWidget);
    await tester.tap(find.byKey(const Key('first-login-entry')));
    expect(firstLoginPressed, isTrue);
  });

  testWidgets('empty account page exposes login and complete reset actions', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = AccountService(database: database, protector: Protector());

    await tester.pumpWidget(MaterialApp(home: AccountsPage(service: service)));
    await tester.pumpAndSettle();

    expect(find.text('登录教务'), findsOneWidget);
    expect(find.text('清除全部数据'), findsOneWidget);
  });

  testWidgets('single-account page does not offer account switching', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = AccountService(database: database, protector: Protector());
    await service.persistVerifiedAccount(username: 'PB00000000');

    await tester.pumpWidget(MaterialApp(home: AccountsPage(service: service)));
    await tester.pumpAndSettle();

    expect(find.text('切换'), findsNothing);
  });

  testWidgets('configured account page keeps credential controls only', (
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
    expect(find.byKey(Key('clear-browser-$id')), findsNothing);
    expect(find.text('清除浏览器会话'), findsNothing);
    expect(browserClears, 0);
  });

  testWidgets('deleted credentials expose same-account reauthentication', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = AccountService(database: database, protector: Protector());
    final id = await service.persistVerifiedAccount(
      username: 'PB00000000',
      password: 'secret',
      savePassword: true,
    );
    String? reauthenticateId;
    await tester.pumpWidget(
      MaterialApp(
        home: AccountsPage(
          service: service,
          onLoginAgain: (value) => reauthenticateId = value,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('delete-credentials-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除凭据'));
    await tester.pumpAndSettle();

    expect(find.text('需要重新登录'), findsOneWidget);
    expect(find.byKey(Key('reauthenticate-$id')), findsOneWidget);
    await tester.tap(find.byKey(Key('reauthenticate-$id')));
    expect(reauthenticateId, id);
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
    await tester.pumpWidget(MaterialApp(home: AccountsPage(service: service)));
    await tester.pumpAndSettle();

    expect(find.textContaining('教务系统：上次同步成功'), findsOneWidget);
  });
}
