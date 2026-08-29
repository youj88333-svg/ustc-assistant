import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/calendar/application/recurrence_service.dart';
import 'package:ustc_assistant_app/features/calendar/domain/calendar_event_locator.dart';
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';
import 'package:ustc_assistant_app/features/calendar/domain/recurrence_rule.dart';
import 'package:ustc_assistant_app/features/schedule/application/conflict_service.dart';
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

  testWidgets('detail loader resolves a recurring occurrence by locator', (
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
    final service = RecurrenceService(
      database: database,
      accountId: 'account',
      now: () => 100,
    );
    await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '每周复盘',
        startAt: DateTime(2026, 7, 27, 15),
        endAt: DateTime(2026, 7, 27, 16),
        locationName: '实验室',
      ),
      rule: RecurrenceRule.weekly(
        anchor: DateTime(2026, 7, 27, 15),
        weekdays: {DateTime.monday},
      ),
    );
    final seriesRows = await database.select(database.calendarEventSeries).get();
    final seriesId = seriesRows.single.id;
    final locator = encodeCalendarEventLocator(
      RecurringOccurrenceLocator(
        seriesId: seriesId,
        occurrenceKey: '$seriesId@2026-07-27T15:00:00',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: EventDetailLoader(database: database, eventId: locator),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('每周复盘'), findsOneWidget);
    expect(find.text('实验室'), findsOneWidget);
    // The standard one-off edit/delete buttons are not offered for an
    // occurrence (no stored event row to edit).
    expect(find.byKey(const Key('edit-personal-event')), findsNothing);
    expect(find.byKey(const Key('delete-personal-event')), findsNothing);
  });

  test('conflict service resolves a recurring occurrence participant by locator',
      () async {
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
    final service = RecurrenceService(
      database: database,
      accountId: 'account',
      now: () => 100,
    );
    await service.createSeries(
      anchor: PersonalEvent.timed(
        title: '晨会',
        startAt: DateTime(2026, 7, 27, 9),
        endAt: DateTime(2026, 7, 27, 10),
      ),
      rule: RecurrenceRule.daily(anchor: DateTime(2026, 7, 27, 9)),
    );
    final seriesId =
        (await database.select(database.calendarEventSeries).get()).single.id;
    final locator = encodeCalendarEventLocator(
      RecurringOccurrenceLocator(
        seriesId: seriesId,
        occurrenceKey: '$seriesId@2026-07-27T09:00:00',
      ),
    );

    final conflictService = ConflictService(
      database: database,
      accountId: 'account',
    );
    final item = await conflictService.gridItemForParticipant(
      ScheduleConflictParticipant(
        kind: 'event',
        id: locator,
        title: '晨会',
        occurrenceDate: DateTime(2026, 7, 27),
        startAt: DateTime(2026, 7, 27, 9),
        endAt: DateTime(2026, 7, 27, 10),
        seriesType: 'calendar_event_series',
        seriesId: seriesId,
      ),
    );
    expect(item != null, isTrue);
    expect(item!.id, locator);
    expect(item.startAt, DateTime(2026, 7, 27, 9));
    // The raw series id is never exposed as the item's stable series id is the
    // calendar_event_series identity (kept for series-rule resolution).
    expect(item.seriesId, seriesId);
    expect(item.colorKey, isNot(locator));
  });
}
