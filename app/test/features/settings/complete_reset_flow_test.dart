import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:ustc_assistant_app/app/router.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/settings/presentation/official_websites_page.dart';

class _Launcher implements OfficialWebsiteLauncher {
  @override
  Future<bool> launch(Uri uri) async => true;
}

void main() {
  testWidgets('complete reset returns to the first-login sync route', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await database
        .into(database.localAccounts)
        .insert(
          LocalAccountsCompanion.insert(
            id: 'account',
            maskedHint: 'PB****0000',
            isActive: const Value(true),
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    final GoRouter router = buildRouter(_Launcher(), database);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    router.go('/settings');
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('complete-reset')),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('complete-reset')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认').last);
    await tester.pumpAndSettle();

    expect(router.routeInformationProvider.value.uri.path, '/sync');
    expect(find.byKey(const Key('first-login-username')), findsOneWidget);
    expect(await database.select(database.localAccounts).get(), isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
