import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/schedule/presentation/event_detail_loader.dart';

void main() {
  testWidgets('detail loader resolves an event inside the active account', (
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
    await database
        .into(database.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: 'event',
            accountId: 'account',
            source: 'user',
            title: '个人安排',
            type: 'personal',
            startAt: const Value(1000),
            endAt: const Value(2000),
            allDay: false,
            timezone: 'Asia/Shanghai',
            locationName: const Value('宿舍'),
            createdAt: 1,
            updatedAt: 1,
          ),
        );

    await tester.pumpWidget(
      MaterialApp(
        home: EventDetailLoader(database: database, eventId: 'event'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('个人安排'), findsOneWidget);
    expect(find.text('宿舍'), findsOneWidget);
    expect(find.text('个人日程'), findsOneWidget);
  });

  testWidgets('detail loader reports a missing record without throwing', (
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

    await tester.pumpWidget(
      MaterialApp(
        home: EventDetailLoader(database: database, eventId: 'missing'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('记录已不存在'), findsOneWidget);
  });
}
