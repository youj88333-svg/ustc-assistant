import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/schedule/application/effective_event_repository.dart';
import 'package:ustc_assistant_app/features/schedule/domain/course_color.dart';
import 'package:ustc_assistant_app/features/schedule/domain/overlap_engine.dart';
import 'package:ustc_assistant_app/features/schedule/domain/schedule_projection.dart';
import 'package:ustc_assistant_app/features/schedule/domain/ustc_periods.dart';
import 'package:ustc_assistant_app/features/schedule/domain/week_range.dart';

EffectiveEvent event(
  String id,
  int day,
  int startHour,
  int startMinute,
  int endHour,
  int endMinute, {
  String? seriesId,
  bool conflict = false,
  bool preview = false,
  EventImportance importance = EventImportance.normal,
}) {
  return EffectiveEvent.timed(
    id: id,
    title: id,
    startAt: DateTime(2026, 7, 20 + day, startHour, startMinute),
    endAt: DateTime(2026, 7, 20 + day, endHour, endMinute),
    courseSeriesId: seriesId,
    hasConfirmedConflict: conflict,
    isInactivePreview: preview,
    importance: importance,
  );
}

void main() {
  test('week always spans Monday through Sunday', () {
    final week = WeekRange.forDate(DateTime(2026, 7, 26));
    expect(week.days.length, 7);
    expect(week.days.first.weekday, DateTime.monday);
    expect(week.days.last.weekday, DateTime.sunday);
  });

  test('official periods expose exact boundaries', () {
    expect(UstcPeriods.byNumber(3).startMinutes, 9 * 60 + 45);
    expect(UstcPeriods.byNumber(4).endMinutes, 11 * 60 + 20);
  });

  test('geometry uses real minutes rather than rounded periods', () {
    final projection = buildWeek(
      ScheduleQuery(
        selectedDate: DateTime(2026, 7, 20),
        events: [event('second-class', 0, 9, 52, 10, 17)],
      ),
    );
    final item = projection.timedByDay[DateTime.monday]!.single;
    expect(item.topMinutes, 9 * 60 + 52 - UstcPeriods.dayStartMinutes);
    expect(item.heightMinutes, 25);
  });

  test('overlap does not imply conflict and previews are excluded', () {
    final groups = groupOverlaps([
      event('a', 0, 9, 0, 10, 0),
      event('b', 0, 9, 30, 11, 0),
      event('preview', 0, 9, 15, 9, 45, preview: true),
    ]);
    expect(groups.single.events, hasLength(2));
    expect(groups.single.hasConfirmedConflict, isFalse);
  });

  test('confirmed conflict and importance select deterministic foreground', () {
    final groups = groupOverlaps([
      event('normal', 0, 9, 0, 10, 0),
      event(
        'important',
        0,
        9,
        0,
        10,
        0,
        conflict: true,
        importance: EventImportance.high,
      ),
    ]);
    expect(groups.single.foreground.id, 'important');
    expect(groups.single.hasConfirmedConflict, isTrue);

    final tied = groupOverlaps([
      event('b', 0, 9, 0, 10, 0),
      event('a', 0, 9, 0, 10, 0),
    ]);
    expect(tied.single.foreground.id, 'a');
  });

  test('course colors are stable and common identities differ', () {
    expect(courseColorValue('series-a'), courseColorValue('series-a'));
    expect(courseColorValue('series-a'), isNot(courseColorValue('series-b')));
  });

  test('all-day spans appear on every covered day', () {
    final projection = buildWeek(
      ScheduleQuery(
        selectedDate: DateTime(2026, 7, 22),
        events: [
          EffectiveEvent.allDay(
            id: 'trip',
            title: 'trip',
            startDate: DateTime(2026, 7, 24),
            endDateExclusive: DateTime(2026, 7, 27),
          ),
        ],
      ),
    );
    expect(projection.allDayByDay[DateTime.friday], hasLength(1));
    expect(projection.allDayByDay[DateTime.saturday], hasLength(1));
    expect(projection.allDayByDay[DateTime.sunday], hasLength(1));
  });

  test('inactive course preview is projected but not made actionable', () {
    final preview = event(
      'odd-week-preview',
      2,
      9,
      45,
      11,
      20,
      seriesId: 'course',
      preview: true,
    );
    final projection = buildWeek(
      ScheduleQuery(selectedDate: DateTime(2026, 7, 20), events: [preview]),
    );
    expect(projection.previews.single.event.id, 'odd-week-preview');
    expect(projection.overlapGroups, isEmpty);
  });

  test(
    'display events exclude only source records missing within scope',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      const accountId = 'account';
      await database
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

      Future<void> insertEvent(String id, String source) => database
          .into(database.calendarEvents)
          .insert(
            CalendarEventsCompanion.insert(
              id: id,
              accountId: accountId,
              source: source,
              externalId: Value(source == 'user' ? null : id),
              title: id,
              type: source == 'user' ? 'personal' : 'exam',
              startAt: const Value(1000),
              endAt: const Value(2000),
              allDay: false,
              timezone: 'Asia/Shanghai',
              createdAt: 1,
              updatedAt: 1,
            ),
          );

      Future<void> insertSourceRecord(String id, String presence) => database
          .into(database.sourceRecords)
          .insert(
            SourceRecordsCompanion.insert(
              id: 'source-$id',
              accountId: accountId,
              source: id == 'outside' ? 'ustc_young_schedule' : 'ustc_jw',
              entityType: 'calendar_event',
              externalId: id,
              localEntityId: id,
              sourceStatus: 'active',
              presence: presence,
              scopeKey: 'scope',
              firstObservedAt: 1,
              lastObservedAt: 1,
            ),
          );

      await insertEvent('missing', 'ustc_jw');
      await insertEvent('observed', 'ustc_jw');
      await insertEvent('outside', 'ustc_young_schedule');
      await insertEvent('personal', 'user');
      await insertSourceRecord('missing', 'missing_within_scope');
      await insertSourceRecord('observed', 'observed');
      await insertSourceRecord('outside', 'outside_scope');

      final visible = await EffectiveEventRepository(
        database,
        accountId: accountId,
      ).watchDisplayEvents().first;

      expect(
        visible.map((event) => event.id),
        containsAll(['observed', 'outside', 'personal']),
      );
      expect(visible.map((event) => event.id), isNot(contains('missing')));
    },
  );
}
