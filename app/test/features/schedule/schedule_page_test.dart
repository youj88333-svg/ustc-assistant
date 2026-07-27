import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
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

  testWidgets('imported events appear in the selected week', (tester) async {
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
    await database
        .into(database.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: 'future-event',
            accountId: 'account',
            source: 'ustc_young_my_schedule',
            title: '未来二课活动',
            type: 'second_class',
            startAt: Value(DateTime.utc(2026, 8, 3, 2).millisecondsSinceEpoch),
            endAt: Value(
              DateTime.utc(2026, 8, 3, 3, 30).millisecondsSinceEpoch,
            ),
            allDay: false,
            timezone: 'Asia/Shanghai',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await database
        .into(database.sourceRecords)
        .insert(
          SourceRecordsCompanion.insert(
            id: 'future-source',
            accountId: 'account',
            source: 'ustc_young_my_schedule',
            entityType: 'calendar_event',
            externalId: 'future-event',
            localEntityId: 'future-event',
            sourceStatus: 'active',
            presence: 'observed',
            scopeKey: 'window',
            firstObservedAt: 1,
            lastObservedAt: 1,
          ),
        );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SchedulePage(
            database: database,
            clock: FixedBeijingClock(DateTime(2026, 7, 27)),
          ),
        ),
      ),
    );
    for (var index = 0; index < 5; index++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.text('未来二课活动'), findsNothing);
    await tester.tap(find.byTooltip('下一周'));
    for (var index = 0; index < 5; index++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('未来二课活动'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('event selection exposes the stable event id', (tester) async {
    final database = AppDatabase(NativeDatabase.memory());
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
        .into(database.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: 'personal-event',
            accountId: 'account',
            source: 'user',
            title: '晚间安排',
            type: 'personal',
            startAt: Value(DateTime.utc(2026, 7, 27).millisecondsSinceEpoch),
            endAt: Value(DateTime.utc(2026, 7, 27, 1).millisecondsSinceEpoch),
            allDay: false,
            timezone: 'Asia/Shanghai',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    String? selectedId;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SchedulePage(
            database: database,
            clock: FixedBeijingClock(DateTime(2026, 7, 27)),
            onEventSelected: (value) => selectedId = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('event-personal-event')));
    await tester.pumpAndSettle();
    expect(selectedId, 'personal-event');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await database.close();
  });
}
