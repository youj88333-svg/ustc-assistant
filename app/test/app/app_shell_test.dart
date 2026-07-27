import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/app/app.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/settings/presentation/official_websites_page.dart';

class FakeWebsiteLauncher implements OfficialWebsiteLauncher {
  final launched = <Uri>[];

  @override
  Future<bool> launch(Uri uri) async {
    launched.add(uri);
    return true;
  }
}

void main() {
  late AppDatabase database;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  testWidgets('bottom navigation has exactly chat and schedule', (
    tester,
  ) async {
    await tester.pumpWidget(
      UstcAssistantApp(
        websiteLauncher: FakeWebsiteLauncher(),
        database: database,
      ),
    );

    final navigation = find.byType(NavigationBar);
    expect(
      find.descendant(of: navigation, matching: find.text('聊天')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: navigation, matching: find.text('日程')),
      findsOneWidget,
    );
    expect(find.byType(NavigationDestination), findsNWidgets(2));
  });

  testWidgets('chat composer is disabled without fake messages', (
    tester,
  ) async {
    await tester.pumpWidget(
      UstcAssistantApp(
        websiteLauncher: FakeWebsiteLauncher(),
        database: database,
      ),
    );

    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(find.text('智能体尚未接入'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('schedule keeps week and task choices inside one destination', (
    tester,
  ) async {
    await tester.pumpWidget(
      UstcAssistantApp(
        websiteLauncher: FakeWebsiteLauncher(),
        database: database,
      ),
    );
    await tester.tap(find.text('日程'));
    await tester.pumpAndSettle();

    expect(find.text('周视图'), findsOneWidget);
    expect(find.text('任务'), findsOneWidget);
    expect(find.byType(SegmentedButton<ScheduleSection>), findsOneWidget);
  });

  testWidgets('task center selection opens the task detail route', (
    tester,
  ) async {
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
    await database
        .into(database.tasks)
        .insert(
          TasksCompanion.insert(
            id: 'task-route',
            accountId: 'account',
            title: '路由测试任务',
            state: 'active',
            importance: 'normal',
            tagsJson: '[]',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await tester.pumpWidget(
      UstcAssistantApp(
        websiteLauncher: FakeWebsiteLauncher(),
        database: database,
      ),
    );
    await tester.tap(find.text('日程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('路由测试任务'));
    await tester.pumpAndSettle();

    expect(find.text('截止风险：未定截止'), findsOneWidget);
    expect(find.byKey(const Key('schedule-task')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('global add offers task and calendar event', (tester) async {
    await tester.pumpWidget(
      UstcAssistantApp(
        websiteLauncher: FakeWebsiteLauncher(),
        database: database,
      ),
    );
    await tester.tap(find.byKey(const Key('global-add')));
    await tester.pumpAndSettle();
    expect(find.text('Task'), findsOneWidget);
    expect(find.text('Calendar event'), findsOneWidget);
  });

  testWidgets('account reauthentication route keeps the local partition', (
    tester,
  ) async {
    await database
        .into(database.localAccounts)
        .insert(
          LocalAccountsCompanion.insert(
            id: 'account',
            maskedHint: 'PB****0000',
            identityDigest: const Value('digest'),
            isActive: const Value(true),
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await tester.pumpWidget(
      UstcAssistantApp(
        websiteLauncher: FakeWebsiteLauncher(),
        database: database,
      ),
    );
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.badge_outlined).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reauthenticate-account')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('reauth-username')), findsOneWidget);
    expect(find.textContaining('PB****0000'), findsOneWidget);
  });

  testWidgets('official website page exposes only allowlisted HTTPS targets', (
    tester,
  ) async {
    final launcher = FakeWebsiteLauncher();
    await tester.pumpWidget(
      UstcAssistantApp(websiteLauncher: launcher, database: database),
    );
    await tester.tap(find.byTooltip('打开侧边栏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学校官方网站'));
    await tester.pumpAndSettle();

    expect(find.text('教务系统'), findsOneWidget);
    expect(launcher.launched, isEmpty);
    await tester.tap(find.text('教务系统'));
    await tester.pump();
    expect(launcher.launched.single.scheme, 'https');
    expect(launcher.launched.single.host, 'jw.ustc.edu.cn');
  });

  testWidgets('drawer destinations can return to the originating main page', (
    tester,
  ) async {
    await tester.pumpWidget(
      UstcAssistantApp(
        websiteLauncher: FakeWebsiteLauncher(),
        database: database,
      ),
    );
    await tester.tap(find.text('日程'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('打开侧边栏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学校官方网站'));
    await tester.pumpAndSettle();

    expect(find.byType(BackButton), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('周视图'), findsOneWidget);
  });
}
