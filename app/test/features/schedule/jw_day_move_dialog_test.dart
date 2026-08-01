import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/core/time/beijing_clock.dart';
import 'package:ustc_assistant_app/features/schedule/application/jw_day_move_service.dart';
import 'package:ustc_assistant_app/features/schedule/presentation/jw_day_move_dialog.dart';

const _account = 'account';

/// Converts a Beijing wall-clock time to the UTC epoch-ms storage encoding
/// used by the app (Beijing wall clock == stored UTC + 8h).
int _beijingEpoch(int year, int month, int day, int hour, [int minute = 0]) =>
    DateTime.utc(year, month, day, hour, minute).millisecondsSinceEpoch -
    const Duration(hours: 8).inMilliseconds;

Future<AppDatabase> _database() async {
  final database = AppDatabase(NativeDatabase.memory());
  await database
      .into(database.localAccounts)
      .insert(
        LocalAccountsCompanion.insert(
          id: _account,
          maskedHint: 'PB****0000',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
  return database;
}

Future<void> _seedEvent(
  AppDatabase database, {
  required String id,
  required String source,
  required String type,
  required int startAt,
  required int endAt,
  String? title,
}) async {
  await database
      .into(database.calendarEvents)
      .insert(
        CalendarEventsCompanion.insert(
          id: id,
          accountId: _account,
          source: source,
          externalId: Value(source == 'user' ? null : id),
          title: title ?? id,
          type: type,
          startAt: Value(startAt),
          endAt: Value(endAt),
          allDay: false,
          timezone: 'Asia/Shanghai',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
  if (source != 'user') {
    await database
        .into(database.sourceRecords)
        .insert(
          SourceRecordsCompanion.insert(
            id: 'source-$id',
            accountId: _account,
            source: source,
            entityType: 'calendar_event',
            externalId: id,
            localEntityId: id,
            sourceStatus: 'active',
            presence: 'observed',
            scopeKey: 'semester',
            firstObservedAt: 1,
            lastObservedAt: 1,
          ),
        );
  }
}

/// Two eligible `ustc_jw/course` timed events on the Beijing date y-m-d.
Future<void> _seedCourses(
  AppDatabase database, {
  required int y,
  required int m,
  required int d,
}) async {
  await _seedEvent(
    database,
    id: 'course-1',
    source: 'ustc_jw',
    type: 'course',
    startAt: _beijingEpoch(y, m, d, 9),
    endAt: _beijingEpoch(y, m, d, 10),
  );
  await _seedEvent(
    database,
    id: 'course-2',
    source: 'ustc_jw',
    type: 'course',
    startAt: _beijingEpoch(y, m, d, 14),
    endAt: _beijingEpoch(y, m, d, 16),
  );
}

/// One exam, one second-class and one personal event on 2026-07-27: they must
/// never appear in the preview.
Future<void> _seedNonCourses(AppDatabase database) async {
  await _seedEvent(
    database,
    id: 'exam-1',
    source: 'ustc_jw',
    type: 'exam',
    startAt: _beijingEpoch(2026, 7, 27, 11),
    endAt: _beijingEpoch(2026, 7, 27, 12),
  );
  await _seedEvent(
    database,
    id: 'second-1',
    source: 'ustc_young',
    type: 'second_class',
    startAt: _beijingEpoch(2026, 7, 27, 13),
    endAt: _beijingEpoch(2026, 7, 27, 14),
  );
  await _seedEvent(
    database,
    id: 'personal-1',
    source: 'user',
    type: 'personal',
    startAt: _beijingEpoch(2026, 7, 27, 10),
    endAt: _beijingEpoch(2026, 7, 27, 11),
  );
}

/// The dialog result captured by the host page after it closes.
class _DialogHost {
  JwDayMoveDialogResult? result;
}

/// Pumps a host page whose button opens [JwDayMoveDialog] and stores the
/// popped result into the returned host.
Future<_DialogHost> _openDialog(
  WidgetTester tester, {
  required JwDayMoveService service,
  DateTime? initialSourceDate,
}) async {
  final host = _DialogHost();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                host.result = await showDialog<JwDayMoveDialogResult>(
                  context: context,
                  builder: (_) => JwDayMoveDialog(
                    service: service,
                    initialSourceDate:
                        initialSourceDate ?? DateTime(2026, 7, 27),
                    clock: FixedBeijingClock(DateTime(2026, 7, 27)),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return host;
}

/// Taps the day cell [day] of the open Material date picker and confirms.
Future<void> _pickDay(WidgetTester tester, int day) async {
  await tester.tap(find.text('$day'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('source and target date pickers update the dialog dates', (
    tester,
  ) async {
    final database = await _database();
    addTearDown(database.close);
    await _seedCourses(database, y: 2026, m: 7, d: 27);
    final service = JwDayMoveService(database: database, accountId: _account);
    await _openDialog(tester, service: service);

    // Defaults: source = the initial source date, target = the next day.
    expect(find.text('2026-07-27 周一'), findsOneWidget);
    expect(find.text('2026-07-28 周二'), findsOneWidget);

    // Source picker changes the source date and reloads the preview.
    await tester.tap(find.byKey(const Key('day-move-source-field')));
    await tester.pumpAndSettle();
    await _pickDay(tester, 29);
    expect(find.text('2026-07-29 周三'), findsOneWidget);
    // No courses are seeded on 2026-07-29.
    expect(find.text('符合条件课程：0 门'), findsOneWidget);

    // Target picker changes the target date.
    await tester.tap(find.byKey(const Key('day-move-target-field')));
    await tester.pumpAndSettle();
    await _pickDay(tester, 30);
    expect(find.text('2026-07-30 周四'), findsOneWidget);
  });

  testWidgets('preview shows the eligible count and titles, excluding exam, '
      'second-class and personal entries', (tester) async {
    final database = await _database();
    addTearDown(database.close);
    await _seedCourses(database, y: 2026, m: 7, d: 27);
    await _seedNonCourses(database);
    final service = JwDayMoveService(database: database, accountId: _account);
    await _openDialog(tester, service: service);

    expect(find.text('符合条件课程：2 门'), findsOneWidget);
    expect(find.text('course-1'), findsOneWidget);
    expect(find.text('course-2'), findsOneWidget);
    expect(find.text('exam-1'), findsNothing);
    expect(find.text('second-1'), findsNothing);
    expect(find.text('personal-1'), findsNothing);
  });

  testWidgets('source equal to target shows an error and disables confirm', (
    tester,
  ) async {
    final database = await _database();
    addTearDown(database.close);
    await _seedCourses(database, y: 2026, m: 7, d: 27);
    final service = JwDayMoveService(database: database, accountId: _account);
    await _openDialog(tester, service: service);

    // Pick the same date as the source (2026-07-27).
    await tester.tap(find.byKey(const Key('day-move-target-field')));
    await tester.pumpAndSettle();
    await _pickDay(tester, 27);

    expect(find.text('源日期与目标日期相同'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('day-move-confirm')))
          .onPressed,
      isNull,
    );

    // A different target clears the error and re-enables the confirmation.
    await tester.tap(find.byKey(const Key('day-move-target-field')));
    await tester.pumpAndSettle();
    await _pickDay(tester, 29);
    expect(find.text('源日期与目标日期相同'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('day-move-confirm')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('no eligible courses disables the confirmation', (tester) async {
    final database = await _database();
    addTearDown(database.close);
    final service = JwDayMoveService(database: database, accountId: _account);
    await _openDialog(tester, service: service);

    expect(find.text('符合条件课程：0 门'), findsOneWidget);
    expect(find.text('没有符合条件的课程'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('day-move-confirm')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('confirm moves the courses and pops with the performed result', (
    tester,
  ) async {
    final database = await _database();
    addTearDown(database.close);
    await _seedCourses(database, y: 2026, m: 7, d: 27);
    final service = JwDayMoveService(database: database, accountId: _account);
    final host = await _openDialog(tester, service: service);

    await tester.tap(find.byKey(const Key('day-move-confirm')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('day-move-dialog')), findsNothing);
    final result = host.result;
    expect(result, isA<JwDayMovePerformed>());
    final performed = result as JwDayMovePerformed;
    expect(performed.sourceDate, '2026-07-27');
    expect(performed.targetDate, '2026-07-28');
    final rows = await database.select(database.jwDayMoves).get();
    expect(rows, hasLength(1));
    expect(rows.single.targetDate, '2026-07-28');
  });

  testWidgets(
    'existing move shows retarget copy and 恢复原日期; retarget and clear work',
    (tester) async {
      final database = await _database();
      addTearDown(database.close);
      await _seedCourses(database, y: 2026, m: 7, d: 27);
      final service = JwDayMoveService(database: database, accountId: _account);
      await service.move('2026-07-27', '2026-08-03');

      final host = await _openDialog(tester, service: service);
      expect(find.text('更新移动'), findsOneWidget);
      expect(find.text('确认移动'), findsNothing);
      expect(find.byKey(const Key('day-move-clear')), findsOneWidget);

      // Retarget to 2026-07-30.
      await tester.tap(find.byKey(const Key('day-move-target-field')));
      await tester.pumpAndSettle();
      await _pickDay(tester, 30);
      await tester.tap(find.byKey(const Key('day-move-confirm')));
      await tester.pumpAndSettle();

      final performed = host.result as JwDayMovePerformed;
      expect(performed.targetDate, '2026-07-30');
      var rows = await database.select(database.jwDayMoves).get();
      expect(rows, hasLength(1));
      expect(rows.single.targetDate, '2026-07-30');

      // Reopen and clear the move.
      final host2 = await _openDialog(tester, service: service);
      expect(find.text('更新移动'), findsOneWidget);
      await tester.tap(find.byKey(const Key('day-move-clear')));
      await tester.pumpAndSettle();

      expect(host2.result, isA<JwDayMoveCleared>());
      expect((host2.result as JwDayMoveCleared).sourceDate, '2026-07-27');
      rows = await database.select(database.jwDayMoves).get();
      expect(rows, isEmpty);
    },
  );

  testWidgets('dialog text fits a narrow phone width', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final database = await _database();
    addTearDown(database.close);
    // A long title exercises the ellipsized preview line.
    await _seedEvent(
      database,
      id: 'course-1',
      source: 'ustc_jw',
      type: 'course',
      startAt: _beijingEpoch(2026, 7, 27, 9),
      endAt: _beijingEpoch(2026, 7, 27, 10),
      title: '高等数学（一）极限与连续专题精讲课程',
    );
    final service = JwDayMoveService(database: database, accountId: _account);
    await _openDialog(tester, service: service);

    expect(find.byKey(const Key('day-move-dialog')), findsOneWidget);
    expect(find.text('符合条件课程：1 门'), findsOneWidget);
    expect(find.text('高等数学（一）极限与连续专题精讲课程'), findsOneWidget);
  });
}
