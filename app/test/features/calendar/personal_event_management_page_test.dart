import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/calendar/application/calendar_event_service.dart';
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';
import 'package:ustc_assistant_app/features/calendar/presentation/personal_event_management_page.dart';

/// Seeds an active account and returns it. The `calendar_events` table FKs
/// `local_accounts.account_id`, so the account must exist before any event
/// insert, matching the service test's seeding pattern.
Future<AppDatabase> _database() async {
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
  return database;
}

CalendarEventService _service(AppDatabase db) =>
    CalendarEventService(database: db, accountId: 'account', now: () => 1000);

Future<String> _createEvent(CalendarEventService service) => service.create(
      PersonalEvent.timed(
        title: '事件',
        startAt: DateTime(2026, 8, 5, 9),
        endAt: DateTime(2026, 8, 5, 10),
      ),
    );

Widget _pump(AppDatabase db) => MaterialApp(
      home: PersonalEventManagementPage(service: _service(db)),
    );

/// Matches the status label rendered as a ListTile subtitle text, distinct
/// from the FilterChip labels (which share the same strings). The subtitle is
/// a descendant of a ListTile and carries the high-contrast status color.
Finder _statusSubtitle(String label) => find.descendant(
      of: find.byType(ListTile),
      matching: find.text(label),
    );

void main() {
  testWidgets(
    'shows cancelled/hidden/deleted status labels and reopens a cancelled event',
    (tester) async {
      final db = await _database();
      addTearDown(db.close);
      final service = _service(db);
      final cancelledId = await _createEvent(service);
      final hiddenId = await _createEvent(service);
      final deletedId = await _createEvent(service);
      await service.cancel(cancelledId);
      await service.hide(hiddenId);
      await service.softDelete(deletedId);

      await tester.pumpWidget(_pump(db));
      await tester.pumpAndSettle();

      // Three categorized status labels render as ListTile subtitles (one per
      // event row), distinct from the FilterChip labels which use the same
      // text. Match the subtitle text widgets specifically.
      expect(_statusSubtitle('已取消'), findsOneWidget);
      expect(_statusSubtitle('已隐藏'), findsOneWidget);
      expect(_statusSubtitle('已删除'), findsOneWidget);

      // Reopen the cancelled event via its trailing action.
      await tester.tap(find.byTooltip('重新打开'));
      await tester.pumpAndSettle();

      // After reopen the event leaves the management list (it is active again).
      expect(_statusSubtitle('已取消'), findsNothing);
      final reopened = await service.byId(cancelledId);
      expect(reopened.status, EventStatus.active);
    },
  );

  testWidgets('restores a deleted event and it leaves the list', (tester) async {
    final db = await _database();
    addTearDown(db.close);
    final service = _service(db);
    final deletedId = await _createEvent(service);
    await service.softDelete(deletedId);

    await tester.pumpWidget(_pump(db));
    await tester.pumpAndSettle();

    expect(_statusSubtitle('已删除'), findsOneWidget);
    await tester.tap(find.byTooltip('恢复'));
    await tester.pumpAndSettle();

    expect(_statusSubtitle('已删除'), findsNothing);
    final restored = await service.byId(deletedId);
    expect(restored.deletedAt, isNull);
  });

  testWidgets('status filter chips narrow the visible categories', (
    tester,
  ) async {
    final db = await _database();
    addTearDown(db.close);
    final service = _service(db);
    final cancelledId = await _createEvent(service);
    final deletedId = await _createEvent(service);
    await service.cancel(cancelledId);
    await service.softDelete(deletedId);

    await tester.pumpWidget(_pump(db));
    await tester.pumpAndSettle();

    // Both categories visible by default (status subtitles present).
    expect(_statusSubtitle('已取消'), findsOneWidget);
    expect(_statusSubtitle('已删除'), findsOneWidget);

    // Deselect the deleted filter so only cancelled items remain visible.
    await tester.tap(find.byKey(const Key('mgmt-filter-deleted')));
    await tester.pumpAndSettle();
    expect(_statusSubtitle('已取消'), findsOneWidget);
    expect(_statusSubtitle('已删除'), findsNothing);
  });
}
