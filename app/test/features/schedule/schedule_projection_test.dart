import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/core/database/app_database.dart';
import 'package:ustc_assistant_app/features/schedule/application/effective_event_repository.dart';
import 'package:ustc_assistant_app/features/schedule/domain/course_color.dart';
import 'package:ustc_assistant_app/features/schedule/domain/overlap_engine.dart';
import 'package:ustc_assistant_app/features/schedule/domain/schedule_grid_item.dart';
import 'package:ustc_assistant_app/features/schedule/domain/schedule_projection.dart';
import 'package:ustc_assistant_app/features/schedule/domain/ustc_periods.dart';
import 'package:ustc_assistant_app/features/schedule/domain/week_range.dart';
import 'package:ustc_assistant_app/features/tasks/domain/plan_block.dart';
import 'package:ustc_assistant_app/features/tasks/domain/task.dart';

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

TaskItem planTask(String id, {String title = ''}) => TaskItem(
  id: id,
  title: title.isEmpty ? id : title,
  state: TaskState.active,
  importance: TaskImportance.normal,
  createdAt: 1,
  updatedAt: 1,
);

PlanBlockItem planBlock(
  String id,
  String taskId,
  DateTime start,
  DateTime end,
  PlanBlockStatus status, {
  int? deletedAt,
}) => PlanBlockItem(
  id: id,
  taskId: taskId,
  startAt: start,
  endAt: end,
  status: status,
  locked: false,
  createdAt: 1,
  updatedAt: 1,
  deletedAt: deletedAt,
);

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
    // 官方下午/晚上节次与早期预设不同，固化关键边界防止回退。
    expect(UstcPeriods.byNumber(6).startMinutes, 14 * 60);
    expect(UstcPeriods.byNumber(9).endMinutes, 17 * 60 + 30);
    expect(UstcPeriods.byNumber(10).startMinutes, 17 * 60 + 35);
    expect(UstcPeriods.byNumber(13).endMinutes, 21 * 60 + 55);
  });

  test('grid spans 07:00 to 24:00', () {
    expect(UstcPeriods.dayStartMinutes, 7 * 60);
    expect(UstcPeriods.dayEndMinutes, 24 * 60);
  });

  test('boundaries draw start lines plus big-break end lines only', () {
    final lines = UstcPeriods.boundaries();
    // 13 个节次起始线全部存在。
    for (final period in UstcPeriods.values) {
      expect(lines, contains(period.startMinutes));
    }
    // 午休（第5节 12:10 结束）补结束线。
    expect(lines, contains(12 * 60 + 10));
    // 晚间间隔（第10节 18:20 结束）补结束线。
    expect(lines, contains(18 * 60 + 20));
    // 末节后到网格底（21:55-24:00）也是大空档，补结束线。
    expect(lines, contains(21 * 60 + 55));
    // 5 分钟课间不画结束线：第1节 8:35 不应在 lines 中。
    expect(lines, isNot(contains(8 * 60 + 35)));
    // 20 分钟课间休息也不画结束线：第2节 9:25 不应在 lines 中。
    expect(lines, isNot(contains(9 * 60 + 25)));
    // 共 16 条（13 起始 + 3 大空档结束：12:10、18:20、21:55）。
    expect(lines.length, 16);
  });

  test('geometry uses real minutes rather than rounded periods', () {
    final projection = buildWeek(
      ScheduleQuery(
        selectedDate: DateTime(2026, 7, 20),
        items: [ScheduleGridItem.fromEvent(event('second-class', 0, 9, 52, 10, 17))],
      ),
    );
    final item = projection.timedByDay[DateTime.monday]!.single;
    expect(item.topMinutes, 9 * 60 + 52 - UstcPeriods.dayStartMinutes);
    expect(item.heightMinutes, 25);
  });

  test('overlap does not imply conflict and previews are excluded', () {
    final groups = groupOverlaps([
      ScheduleGridItem.fromEvent(event('a', 0, 9, 0, 10, 0)),
      ScheduleGridItem.fromEvent(event('b', 0, 9, 30, 11, 0)),
      ScheduleGridItem.fromEvent(
        event('preview', 0, 9, 15, 9, 45, preview: true),
      ),
    ]);
    expect(groups.single.items, hasLength(2));
    expect(groups.single.hasConfirmedConflict, isFalse);
  });

  test('confirmed conflict and importance select deterministic foreground', () {
    final groups = groupOverlaps([
      ScheduleGridItem.fromEvent(event('normal', 0, 9, 0, 10, 0)),
      ScheduleGridItem.fromEvent(
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
      ),
    ]);
    expect(groups.single.foreground.id, 'important');
    expect(groups.single.hasConfirmedConflict, isTrue);

    final tied = groupOverlaps([
      ScheduleGridItem.fromEvent(event('b', 0, 9, 0, 10, 0)),
      ScheduleGridItem.fromEvent(event('a', 0, 9, 0, 10, 0)),
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
        items: [
          ScheduleGridItem.fromEvent(
            EffectiveEvent.allDay(
              id: 'trip',
              title: 'trip',
              startDate: DateTime(2026, 7, 24),
              endDateExclusive: DateTime(2026, 7, 27),
            ),
          ),
        ],
      ),
    );
    expect(projection.allDayByDay[DateTime.friday], hasLength(1));
    expect(projection.allDayByDay[DateTime.saturday], hasLength(1));
    expect(projection.allDayByDay[DateTime.sunday], hasLength(1));
  });

  test('events before grid start go to early-morning band, not the grid', () {
    final projection = buildWeek(
      ScheduleQuery(
        selectedDate: DateTime(2026, 7, 20),
        items: [
          // 06:30 凌晨事件应进入凌晨带，不进入日网格。
          ScheduleGridItem.fromEvent(event('early', 0, 6, 30, 6, 55)),
          // 07:00 恰为网格下界，应进入日网格（topMinutes=0）。
          ScheduleGridItem.fromEvent(event('at-open', 0, 7, 0, 7, 45)),
          // 23:30 晚间事件仍在网格内（上界 24:00 之前）。
          ScheduleGridItem.fromEvent(event('late', 0, 23, 30, 23, 55)),
        ],
      ),
    );
    final mondayTimed = projection.timedByDay[DateTime.monday]!;
    expect(mondayTimed.map((p) => p.item.id), containsAll(['at-open', 'late']));
    expect(mondayTimed.map((p) => p.item.id), isNot(contains('early')));
    expect(
      projection.earlyMorningByDay[DateTime.monday]!.single.event.id,
      'early',
    );
    // 07:00 事件贴在网格顶部。
    final atOpen = mondayTimed.firstWhere((p) => p.item.id == 'at-open');
    expect(atOpen.topMinutes, 0);
  });

  test('early-morning band is empty for days without pre-7am events', () {
    final projection = buildWeek(
      ScheduleQuery(
        selectedDate: DateTime(2026, 7, 20),
        items: [ScheduleGridItem.fromEvent(event('daytime', 0, 9, 0, 10, 0))],
      ),
    );
    for (final day in [
      DateTime.monday,
      DateTime.tuesday,
      DateTime.wednesday,
      DateTime.thursday,
      DateTime.friday,
      DateTime.saturday,
      DateTime.sunday,
    ]) {
      expect(projection.earlyMorningByDay[day], isEmpty);
    }
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
      ScheduleQuery(
        selectedDate: DateTime(2026, 7, 20),
        items: [ScheduleGridItem.fromEvent(preview)],
      ),
    );
    expect(projection.previews.single.item.id, 'odd-week-preview');
    expect(projection.overlapGroups, isEmpty);
  });

  test('accepted and done non-deleted plan blocks enter the timed grid', () {
    final task = planTask('task-a', title: '准备答辩');
    final accepted = planBlock(
      'block-a',
      task.id,
      DateTime(2026, 7, 20, 9),
      DateTime(2026, 7, 20, 10),
      PlanBlockStatus.accepted,
    );
    final done = planBlock(
      'block-b',
      task.id,
      DateTime(2026, 7, 20, 11),
      DateTime(2026, 7, 20, 12),
      PlanBlockStatus.done,
    );
    final projection = buildWeek(
      ScheduleQuery(
        selectedDate: DateTime(2026, 7, 20),
        items: [
          ScheduleGridItem.fromPlanBlock(accepted, task),
          ScheduleGridItem.fromPlanBlock(done, task),
        ],
      ),
    );
    final monday = projection.timedByDay[DateTime.monday]!;
    expect(monday.map((p) => p.item.id), containsAll(['block-a', 'block-b']));
    final acceptedProjected = monday.firstWhere((p) => p.item.id == 'block-a');
    expect(
      acceptedProjected.topMinutes,
      9 * 60 + 0 - UstcPeriods.dayStartMinutes,
    );
    expect(acceptedProjected.heightMinutes, 60);
  });

  test(
    'suggested/skipped/rescheduled/cancelled/deleted blocks stay out of grid',
    () {
      final task = planTask('task-a', title: '准备答辩');
      final items = <ScheduleGridItem>[
        for (final status in PlanBlockStatus.values)
          ScheduleGridItem.fromPlanBlock(
            planBlock(
              'block-${status.storage}',
              task.id,
              DateTime(2026, 7, 20, 9),
              DateTime(2026, 7, 20, 10),
              status,
            ),
            task,
          ),
        ScheduleGridItem.fromPlanBlock(
          planBlock(
            'block-deleted',
            task.id,
            DateTime(2026, 7, 20, 11),
            DateTime(2026, 7, 20, 12),
            PlanBlockStatus.accepted,
            deletedAt: 1,
          ),
          task,
        ),
      ];
      final projection = buildWeek(
        ScheduleQuery(selectedDate: DateTime(2026, 7, 20), items: items),
      );
      final monday = projection.timedByDay[DateTime.monday]!;
      expect(monday.map((p) => p.item.id), containsAll(['block-accepted', 'block-done']));
      for (final status in [
        PlanBlockStatus.suggested,
        PlanBlockStatus.skipped,
        PlanBlockStatus.rescheduled,
        PlanBlockStatus.cancelled,
      ]) {
        expect(
          monday.map((p) => p.item.id),
          isNot(contains('block-${status.storage}')),
          reason: '${status.storage} must not enter the timed grid',
        );
      }
      expect(monday.map((p) => p.item.id), isNot(contains('block-deleted')));
    },
  );

  test('plan block title falls back to parent task and color derives from task', () {
    final task = planTask('task-a', title: '准备答辩');
    final block = planBlock(
      'block-a',
      task.id,
      DateTime(2026, 7, 20, 9),
      DateTime(2026, 7, 20, 10),
      PlanBlockStatus.accepted,
    );
    final item = ScheduleGridItem.fromPlanBlock(block, task);
    expect(item.title, '准备答辩');
    expect(item.colorKey, 'task-a');
    expect(courseColorValue(item.colorKey), courseColorValue('task-a'));

    final customTitle = PlanBlockItem(
      id: 'block-b',
      taskId: task.id,
      title: '自定义标题',
      startAt: DateTime(2026, 7, 20, 10),
      endAt: DateTime(2026, 7, 20, 11),
      status: PlanBlockStatus.accepted,
      locked: false,
      createdAt: 1,
      updatedAt: 1,
    );
    expect(ScheduleGridItem.fromPlanBlock(customTitle, task).title, '自定义标题');
  });

  test('plan block color is stable across blocks of the same task', () {
    final task = planTask('task-a');
    final itemA = ScheduleGridItem.fromPlanBlock(
      planBlock(
        'ba',
        task.id,
        DateTime(2026, 7, 20, 9),
        DateTime(2026, 7, 20, 10),
        PlanBlockStatus.accepted,
      ),
      task,
    );
    final itemA2 = ScheduleGridItem.fromPlanBlock(
      planBlock(
        'ba2',
        task.id,
        DateTime(2026, 7, 20, 11),
        DateTime(2026, 7, 20, 12),
        PlanBlockStatus.accepted,
      ),
      task,
    );
    expect(itemA.colorKey, 'task-a');
    expect(itemA2.colorKey, 'task-a');
    expect(courseColorValue(itemA.colorKey), courseColorValue(itemA2.colorKey));
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
