import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/app/app.dart';
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
  testWidgets('bottom navigation has exactly chat and schedule', (tester) async {
    await tester.pumpWidget(
      UstcAssistantApp(websiteLauncher: FakeWebsiteLauncher()),
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
      UstcAssistantApp(websiteLauncher: FakeWebsiteLauncher()),
    );

    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(find.text('智能体尚未接入'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('schedule keeps week and task choices inside one destination', (
    tester,
  ) async {
    await tester.pumpWidget(
      UstcAssistantApp(websiteLauncher: FakeWebsiteLauncher()),
    );
    await tester.tap(find.text('日程'));
    await tester.pumpAndSettle();

    expect(find.text('周视图'), findsOneWidget);
    expect(find.text('任务'), findsOneWidget);
    expect(find.byType(SegmentedButton<ScheduleSection>), findsOneWidget);
  });

  testWidgets('official website page exposes only allowlisted HTTPS targets', (
    tester,
  ) async {
    final launcher = FakeWebsiteLauncher();
    await tester.pumpWidget(UstcAssistantApp(websiteLauncher: launcher));
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
}
