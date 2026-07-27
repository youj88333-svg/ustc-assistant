import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/schedule/presentation/schedule_page.dart';

void main() {
  testWidgets('week controls navigate, persist, and return to current week', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SchedulePage(database: database)),
      ),
    );
    await tester.pumpAndSettle();

    final initial = tester
        .widget<Text>(find.byKey(const Key('week-range-label')))
        .data;
    await tester.tap(find.byTooltip('下一周'));
    await tester.pumpAndSettle();
    final following = tester
        .widget<Text>(find.byKey(const Key('week-range-label')))
        .data;
    expect(following, isNot(initial));

    await tester.tap(find.text('任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('周视图'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('week-range-label'))).data,
      following,
    );

    await tester.tap(find.byTooltip('回到本周'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('week-range-label'))).data,
      initial,
    );
  });
}
