import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/agent/application/agent_permission_policy_service.dart';
import 'package:ustc_assistant_app/features/agent/domain/agent_permission_policy.dart';
import 'package:ustc_assistant_app/features/agent/presentation/agent_permission_section.dart';

class _FixedClock implements BeijingClock {
  @override
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);
}

/// `agent_permission_policies.account_id` (and the permission-change log) carry
/// a foreign key to `local_accounts`, so the account must exist before any
/// policy write, matching the settings test's `_seedAccount` pattern.
Future<void> _seedAccount(AppDatabase database, String accountId) => database
    .into(database.localAccounts)
    .insert(
      LocalAccountsCompanion.insert(
        id: accountId,
        maskedHint: 'PB****0000',
        isActive: const Value(true),
        createdAt: 1,
        updatedAt: 1,
      ),
    );

void main() {
  late AppDatabase db;
  late AgentPermissionPolicyService policy;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    policy = AgentPermissionPolicyService(database: db, clock: _FixedClock());
    await _seedAccount(db, 'a1');
  });

  tearDown(() => db.close());

  /// Pumps the standalone section inside a tall viewport. The section is
  /// designed to live inside the settings page's scrollable ListView, so a
  /// bare 800x600 surface would overflow its fixed Column (10 rows + header);
  /// the settings test already handles this with its own `pumpTall` helper.
  Future<void> pumpSection(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AgentPermissionSection(accountId: 'a1', policyService: policy),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('lists policy rows and shows the current mode', (tester) async {
    await pumpSection(tester);
    expect(find.text('新建日程'), findsOneWidget);
    expect(find.text('首次确认后放行'), findsWidgets); // create_event 默认 ask_first_time
    // 权限策略行无下拉（critical 锁定）
    expect(find.text('调整确认策略'), findsOneWidget);
    expect(find.text('恢复默认'), findsOneWidget);
  });

  testWidgets('changing a mode calls updatePolicy and persists', (tester) async {
    await pumpSection(tester);
    // Tap the row's trailing dropdown itself: tapping the ListTile center would
    // hit the title area (the tile has no onTap) and never open the menu.
    await tester.tap(find.descendant(
      of: find.byKey(const Key('perm-create_event')),
      matching: find.byType(DropdownButton<ConfirmationMode>),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('总是允许').last);
    await tester.pumpAndSettle();
    expect(await policy.resolve(accountId: 'a1', actionType: 'create_event',
        targetType: 'event', riskLevel: RiskLevel.medium), PermissionDecision.allow);
  });

  testWidgets('restore defaults clears account policies', (tester) async {
    await policy.updatePolicy(accountId: 'a1', actionType: 'create_event',
        targetType: 'event', mode: ConfirmationMode.alwaysAllow,
        riskLevel: RiskLevel.medium, enabled: true, updatedBy: 'user');
    await pumpSection(tester);
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(await policy.listPolicies('a1'), isEmpty);
  });
}
