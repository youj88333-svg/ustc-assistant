import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ustc_assistant_m0/app/calendar_workspace_contract.dart';
import 'package:ustc_assistant_m0/app/calendar_workspace_page.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/jw_academic_details.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('unready is distinct from a completed empty query', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final port = _FakeCalendarWorkspacePort()..loadGate = Completer<void>();
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.pump();
    expect(find.text('正在读取日程'), findsOneWidget);
    expect(find.text('该日期范围暂无日程'), findsNothing);

    port.loadGate!.complete();
    port.loadGate = null;
    await tester.pumpAndSettle();
    expect(find.text('该日期范围暂无日程'), findsOneWidget);
    expect(find.text('正在读取日程'), findsNothing);
  });

  testWidgets('creates a timed personal event from Beijing time as UTC', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final port = _FakeCalendarWorkspacePort();
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('calendar-personal-create')));
    await tester.pumpAndSettle();

    await _enter(tester, 'calendar-event-title', '时间转换验证');
    await _enter(tester, 'calendar-event-start-date', '2026-10-12');
    await _enter(tester, 'calendar-event-start-time', '09:30');
    await _enter(tester, 'calendar-event-end-date', '2026-10-12');
    await _enter(tester, 'calendar-event-end-time', '10:45');
    await _saveEvent(tester);

    final intent = port.intents.single as CreatePersonalEvent;
    expect(intent.draft.start, DateTime.utc(2026, 10, 12, 1, 30));
    expect(intent.draft.end, DateTime.utc(2026, 10, 12, 2, 45));
    expect(intent.draft.allDay, isFalse);
    expect(find.text('已保存。'), findsWidgets);
  });

  testWidgets(
    'all-day end date is inclusive and weekly cutoff stays a Beijing date',
    (tester) async {
      await _setSize(tester, const Size(1280, 900));
      final port = _FakeCalendarWorkspacePort();
      addTearDown(port.dispose);

      await tester.pumpWidget(_host(port));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('calendar-personal-create')));
      await tester.pumpAndSettle();

      await _enter(tester, 'calendar-event-title', '每周全天安排');
      await tester.tap(find.byKey(const ValueKey('calendar-event-all-day')));
      await tester.pumpAndSettle();
      await _enter(tester, 'calendar-event-start-date', '2026-10-12');
      await _enter(tester, 'calendar-event-end-date', '2026-10-14');
      await tester.tap(find.byKey(const ValueKey('calendar-event-weekly')));
      await tester.pumpAndSettle();
      await _enter(tester, 'calendar-event-until', '2026-11-02');
      await _saveEvent(tester);

      final intent = port.intents.single as CreatePersonalEvent;
      expect(intent.draft.allDay, isTrue);
      expect(intent.draft.weekly, isTrue);
      expect(intent.draft.start, DateTime.utc(2026, 10, 12));
      expect(intent.draft.end, DateTime.utc(2026, 10, 15));
      expect(intent.draft.untilDay, DateTime.utc(2026, 11, 2));
    },
  );

  testWidgets(
    'editing one weekly occurrence submits a non-recurring replacement',
    (tester) async {
      await _setSize(tester, const Size(1280, 900));
      final occurrence = _occurrence(
        kind: CalendarKind.personal,
        id: 31,
        ordinal: 0,
        title: '每周安排',
      );
      final seriesDraft = PersonalEventDraft(
        title: '每周安排',
        start: DateTime.utc(2026, 10, 12, 1),
        end: DateTime.utc(2026, 10, 12, 2),
        weekly: true,
      );
      final port = _FakeCalendarWorkspacePort(
        occurrences: [occurrence],
        personalDrafts: {occurrence.reference.identity: seriesDraft},
      );
      addTearDown(port.dispose);

      await tester.pumpWidget(_host(port));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey<CalendarReference>(occurrence.reference)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('calendar-personal-edit-occurrence')),
      );
      await tester.tap(
        find.byKey(const ValueKey('calendar-personal-edit-occurrence')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('calendar-event-weekly')), findsNothing);
      expect(find.byKey(const ValueKey('calendar-event-until')), findsNothing);
      await _enter(tester, 'calendar-event-title', '本周改期');
      await _enter(tester, 'calendar-event-start-date', '2026-10-13');
      await _enter(tester, 'calendar-event-start-time', '13:00');
      await _enter(tester, 'calendar-event-end-date', '2026-10-13');
      await _enter(tester, 'calendar-event-end-time', '14:00');
      await _saveEvent(tester);

      final intent = port.intents.single as UpdatePersonalOccurrence;
      expect(intent.target, occurrence.reference);
      expect(intent.replacement.title, '本周改期');
      expect(intent.replacement.start, DateTime.utc(2026, 10, 13, 5));
      expect(intent.replacement.end, DateTime.utc(2026, 10, 13, 6));
      expect(intent.replacement.weekly, isFalse);
      expect(intent.replacement.untilDay, isNull);
    },
  );

  testWidgets('a retained replacement remains editable after becoming single', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final occurrence = _occurrence(
      kind: CalendarKind.personal,
      id: 32,
      title: '保留的本次安排',
    );
    final port = _FakeCalendarWorkspacePort(
      occurrences: [occurrence],
      personalDrafts: {
        occurrence.reference.identity: PersonalEventDraft(
          title: '原始安排',
          start: DateTime.utc(2026, 10, 5, 1),
          end: DateTime.utc(2026, 10, 5, 2),
        ),
      },
      replacements: {occurrence.reference.identity},
    );
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey<CalendarReference>(occurrence.reference)),
    );
    await tester.pumpAndSettle();
    expect(find.text('设置重复'), findsOneWidget);
    final edit = find.byKey(
      const ValueKey('calendar-personal-edit-occurrence'),
    );
    await tester.ensureVisible(edit);
    await tester.pumpAndSettle();
    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('calendar-event-title')),
          )
          .controller!
          .text,
      '保留的本次安排',
    );
    expect(find.byKey(const ValueKey('calendar-event-weekly')), findsNothing);
    await _enter(tester, 'calendar-event-title', '再次调整本次安排');
    await _saveEvent(tester);
    final intent = port.intents.single as UpdatePersonalOccurrence;
    expect(intent.target, occurrence.reference);
    expect(intent.replacement.title, '再次调整本次安排');
    expect(intent.replacement.start, occurrence.startsAtUtc);
  });

  testWidgets('exam annotation editor omits attendance and listening fields', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final exam = _occurrence(
      kind: CalendarKind.exam,
      id: 44,
      title: '合成考试安排',
      attendance: AttendanceDecision.attend,
      listening: ListeningMode.listening,
    );
    final port = _FakeCalendarWorkspacePort(occurrences: [exam]);
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey<CalendarReference>(exam.reference)));
    await tester.pumpAndSettle();
    expect(find.text('出勤计划'), findsNothing);
    expect(find.text('听讲方式'), findsNothing);
    await tester.ensureVisible(
      find.byKey(const ValueKey('calendar-school-edit-annotation')),
    );
    await tester.tap(
      find.byKey(const ValueKey('calendar-school-edit-annotation')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('calendar-school-attendance')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('calendar-school-listening')),
      findsNothing,
    );
    await _enter(tester, 'calendar-school-note', '只记录个人复习计划');
    await tester.tap(find.byKey(const ValueKey('calendar-school-save')));
    await tester.pumpAndSettle();

    final intent = port.intents.single as UpdateSchoolAnnotation;
    expect(intent.target, exam.reference);
    expect(intent.note, '只记录个人复习计划');
    expect(intent.attendance, isNull);
    expect(intent.listening, isNull);
  });

  testWidgets(
    'defaults overlap to conflict and saves candidate references only',
    (tester) async {
      await _setSize(tester, const Size(1280, 900));
      final personal = _occurrence(
        kind: CalendarKind.personal,
        id: 46,
        title: '个人复习',
      );
      final course = _occurrence(
        kind: CalendarKind.course,
        id: 47,
        title: '合成课程候选',
      );
      final candidate = CalendarConflict(personal, course);
      final port = _FakeCalendarWorkspacePort(
        occurrences: [personal, course],
        conflicts: [candidate],
      );
      addTearDown(port.dispose);

      await tester.pumpWidget(_host(port));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(ValueKey<CalendarReference>(personal.reference)),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey<CalendarReference>(personal.reference)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('calendar-relation-edit-course-0')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('calendar-relation-edit-course-0')),
      );
      await tester.pumpAndSettle();
      final editor = tester
          .widget<DropdownButtonFormField<CalendarRelationKind>>(
            find.byKey(const ValueKey('calendar-relation-kind')),
          );
      expect(editor.initialValue, CalendarRelationKind.conflict);
      expect(port.intents, isEmpty);
      await _enter(tester, 'calendar-relation-note', '两条安排可以同时存在');
      await tester.tap(find.byKey(const ValueKey('calendar-relation-save')));
      await tester.pumpAndSettle();

      final intent = port.intents.single as SaveCalendarRelation;
      expect(intent.left, personal.reference);
      expect(intent.right, course.reference);
      expect(intent.kind, CalendarRelationKind.conflict);
      expect(intent.note, '两条安排可以同时存在');
    },
  );

  testWidgets('explicitly saves not-conflict for a time-overlap candidate', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final personal = _occurrence(
      kind: CalendarKind.personal,
      id: 48,
      title: '个人安排候选',
    );
    final course = _occurrence(
      kind: CalendarKind.course,
      id: 49,
      title: '课程候选',
    );
    final port = _FakeCalendarWorkspacePort(
      occurrences: [personal, course],
      conflicts: [CalendarConflict(personal, course)],
    );
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey<CalendarReference>(personal.reference)),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('calendar-relation-edit-course-0')),
    );
    await tester.tap(
      find.byKey(const ValueKey('calendar-relation-edit-course-0')),
    );
    await tester.pumpAndSettle();
    expect(port.intents, isEmpty);

    await tester.tap(find.byKey(const ValueKey('calendar-relation-kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不冲突').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('calendar-relation-save')));
    await tester.pumpAndSettle();

    final intent = port.intents.single as SaveCalendarRelation;
    expect(intent.left, personal.reference);
    expect(intent.right, course.reference);
    expect(intent.kind, CalendarRelationKind.notConflict);
  });

  testWidgets('reopening an explicit not-conflict keeps that selection', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final personal = _occurrence(
      kind: CalendarKind.personal,
      id: 50,
      title: '个人安排候选',
    );
    final course = _occurrence(
      kind: CalendarKind.course,
      id: 59,
      title: '课程候选',
    );
    final relation = CalendarRelation(
      reference: CalendarRelationReference(personal.reference.context, 1, 1),
      left: personal.reference.identity,
      right: course.reference.identity,
      kind: CalendarRelationKind.notConflict,
    );
    final port = _FakeCalendarWorkspacePort(
      occurrences: [personal, course],
      conflicts: [CalendarConflict(personal, course, relation: relation)],
    );
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('calendar-conflict-browser')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('calendar-conflict-edit-0')));
    await tester.pumpAndSettle();

    final editor = tester.widget<DropdownButtonFormField<CalendarRelationKind>>(
      find.byKey(const ValueKey('calendar-relation-kind')),
    );
    expect(editor.initialValue, CalendarRelationKind.notConflict);
    expect(port.intents, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets('all-day entries never open conflict judgement controls', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final allDay = _occurrence(
      kind: CalendarKind.personal,
      id: 51,
      title: '全天个人安排',
      allDay: true,
      startsAtUtc: DateTime.utc(2026, 10, 11, 16),
      endsAtUtc: DateTime.utc(2026, 10, 12, 16),
    );
    final course = _occurrence(
      kind: CalendarKind.course,
      id: 52,
      title: '课程候选',
    );
    final port = _FakeCalendarWorkspacePort(
      occurrences: [allDay, course],
      conflicts: [CalendarConflict(allDay, course)],
    );
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('calendar-conflict-browser')),
      findsNothing,
    );
    await tester.tap(find.byKey(ValueKey<CalendarReference>(allDay.reference)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('calendar-detail-card')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('calendar-relation-edit-course-0')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('calendar-relation-save')), findsNothing);
  });

  testWidgets('filter menu changes the query and keeps global candidates', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final course = _occurrence(
      kind: CalendarKind.course,
      id: 61,
      title: '全局课程候选',
    );
    final personal = _occurrence(
      kind: CalendarKind.personal,
      id: 62,
      title: '全局个人候选',
    );
    final hiddenExam = _occurrence(
      kind: CalendarKind.exam,
      id: 63,
      title: '隐藏考试',
      hidden: true,
    );
    final port = _FakeCalendarWorkspacePort(
      occurrences: [course, personal, hiddenExam],
      conflicts: [CalendarConflict(course, personal)],
    );
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('calendar-workspace-filter')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('calendar-workspace-filter-exam')),
    );
    await tester.pumpAndSettle();

    expect(port.view.filter, CalendarFilter.exam);
    expect(find.text('隐藏考试'), findsNothing);
    expect(
      find.byKey(const ValueKey('calendar-conflict-browser')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('calendar-conflict-browser')));
    await tester.pumpAndSettle();
    expect(find.text('全局课程候选'), findsOneWidget);
    expect(find.text('全局个人候选'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('calendar-workspace-filter')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('calendar-workspace-include-inactive')),
    );
    await tester.pumpAndSettle();
    expect(port.view.includeInactive, isTrue);
    expect(find.text('隐藏考试'), findsOneWidget);
  });

  testWidgets('an open old-controller filter menu cannot change the new view', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final first = _FakeCalendarWorkspacePort();
    final second = _FakeCalendarWorkspacePort();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await tester.pumpWidget(_host(first));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('calendar-workspace-filter')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('calendar-workspace-filter-course')),
      findsOneWidget,
    );

    await tester.pumpWidget(_host(second));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('calendar-workspace-filter-course')),
      findsNothing,
    );
    expect(first.view.filter, CalendarFilter.all);
    expect(second.view.filter, CalendarFilter.all);
    expect(first.loadCalls, 1);
    expect(second.loadCalls, 1);
  });

  testWidgets('title colors stay the same across source, identity, and views', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final course = _occurrence(
      kind: CalendarKind.course,
      id: 71,
      title: '同名安排',
      presence: AgendaPresence.missingWithinScope,
    );
    final personal = _occurrence(
      kind: CalendarKind.personal,
      id: 72,
      title: '同名安排',
    );
    final exam = _occurrence(
      kind: CalendarKind.exam,
      id: 73,
      title: '另一名称',
      startsAtUtc: DateTime.utc(2026, 10, 12, 3),
      endsAtUtc: DateTime.utc(2026, 10, 12, 4),
      presence: AgendaPresence.outsideScope,
    );
    final port = _FakeCalendarWorkspacePort(
      occurrences: [course, personal, exam],
      conflicts: [CalendarConflict(course, personal)],
    );
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();
    Color weekFill(CalendarOccurrence occurrence) => tester
        .widget<Material>(
          find
              .ancestor(
                of: find.byKey(
                  ValueKey<CalendarReference>(occurrence.reference),
                ),
                matching: find.byType(Material),
              )
              .first,
        )
        .color!;

    final sharedWeekFill = weekFill(course);
    expect(weekFill(personal), sharedWeekFill);
    expect(weekFill(exam), isNot(sharedWeekFill));
    expect(find.byIcon(Icons.error_outline_rounded), findsWidgets);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.error_outline_rounded).first).color,
      const Color(0xFF9B2C2C),
    );
    expect(find.text('冲*'), findsNothing);
    expect(find.text('冲'), findsNothing);
    expect(find.text('缺'), findsOneWidget);
    expect(find.text('外'), findsOneWidget);

    await tester.tap(find.text('日'));
    await tester.pumpAndSettle();
    Color dayFill(CalendarOccurrence occurrence) => tester
        .widget<Card>(
          find
              .ancestor(
                of: find.byKey(
                  ValueKey<CalendarReference>(occurrence.reference),
                ),
                matching: find.byType(Card),
              )
              .first,
        )
        .color!;

    expect(dayFill(course), sharedWeekFill);
    expect(dayFill(personal), sharedWeekFill);
    expect(dayFill(exam), weekFill(exam));
    expect(find.text('默认冲突'), findsWidgets);
    expect(find.text('来源暂缺，仍保留'), findsOneWidget);
    expect(find.text('当前不在观察范围'), findsOneWidget);
  });

  testWidgets(
    'week blocks show locations when they fit and retain compact locations in tooltips',
    (tester) async {
      await _setSize(tester, const Size(1280, 900));
      final course = _occurrence(
        kind: CalendarKind.course,
        id: 301,
        title: '地点显示演示',
        location: '教学楼 5304',
        academicDetails: JwAcademicDetails(
          campus: '东区',
          building: '教学楼',
          room: '5304',
          teachers: const ['张老师', '王老师'],
        ),
        startsAtUtc: DateTime.utc(2026, 10, 11, 23, 50),
        endsAtUtc: DateTime.utc(2026, 10, 12, 4, 25),
      );
      final short = _occurrence(
        kind: CalendarKind.personal,
        id: 302,
        title: '短时安排',
        location: '图书馆',
        startsAtUtc: DateTime.utc(2026, 10, 12, 2, 5),
        endsAtUtc: DateTime.utc(2026, 10, 12, 2, 10),
      );
      final allDay = _occurrence(
        kind: CalendarKind.personal,
        id: 303,
        title: '全天安排',
        location: '事务大厅',
        allDay: true,
        startsAtUtc: DateTime.utc(2026, 10, 11, 16),
        endsAtUtc: DateTime.utc(2026, 10, 12, 16),
      );
      final port = _FakeCalendarWorkspacePort(
        occurrences: [course, short, allDay],
      );
      addTearDown(port.dispose);
      await tester.pumpWidget(_host(port));
      await tester.pumpAndSettle();
      final courseTile = find.byKey(
        ValueKey<CalendarReference>(course.reference),
      );
      expect(
        find.descendant(of: courseTile, matching: find.text('教学楼 5304')),
        findsNothing,
      );
      expect(
        find.descendant(of: courseTile, matching: find.text('地点：教学楼 5304')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: courseTile, matching: find.text('教师：张老师、王老师')),
        findsOneWidget,
      );
      expect(find.textContaining('事务大厅'), findsOneWidget);
      final shortTile = find.byKey(
        ValueKey<CalendarReference>(short.reference),
      );
      final tip = tester.widget<Tooltip>(
        find.descendant(of: shortTile, matching: find.byType(Tooltip)).first,
      );
      expect(tip.message, contains('图书馆'));
      final courseTip = tester.widget<Tooltip>(
        find.descendant(of: courseTile, matching: find.byType(Tooltip)).first,
      );
      expect(courseTip.message, contains('地点：教学楼 5304'));
      expect(courseTip.message, contains('教师：张老师、王老师'));
      await tester.tap(find.text('日'));
      await tester.pumpAndSettle();
      expect(find.text('地点：教学楼 5304'), findsOneWidget);
      expect(find.text('地点：图书馆'), findsOneWidget);
      expect(find.text('地点：事务大厅'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('JW academic details distinguish uncollected from not provided', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final oldCourse = _occurrence(
      kind: CalendarKind.course,
      id: 321,
      title: '旧课程记录',
    );
    final oldExam = _occurrence(
      kind: CalendarKind.exam,
      id: 326,
      title: '旧考试记录',
    );
    final emptyCourse = _occurrence(
      kind: CalendarKind.course,
      id: 322,
      title: '来源未给字段的课程',
      academicDetails: JwAcademicDetails(),
    );
    final exam = _occurrence(
      kind: CalendarKind.exam,
      id: 323,
      title: '考试字段展示',
      academicDetails: JwAcademicDetails(
        building: '东区教学楼',
        room: '考场 201',
        examType: '期末考试',
        examNote: '闭卷，需携带证件',
      ),
    );
    final young = _occurrence(
      kind: CalendarKind.young,
      id: 324,
      title: '二课活动不显示教务提示',
    );
    final port = _FakeCalendarWorkspacePort(
      occurrences: [oldCourse, oldExam, emptyCourse, exam, young],
    );
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(ValueKey<CalendarReference>(oldCourse.reference)),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('calendar-academic-details-uncollected')),
      findsOneWidget,
    );
    expect(find.text('尚未采集教务信息，重新同步补充'), findsOneWidget);

    await tester.tap(
      find.byKey(ValueKey<CalendarReference>(oldExam.reference)),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('calendar-academic-details-uncollected')),
      findsOneWidget,
    );
    expect(find.text('尚未采集教务信息，重新同步补充'), findsOneWidget);

    await tester.tap(
      find.byKey(ValueKey<CalendarReference>(emptyCourse.reference)),
    );
    await tester.pumpAndSettle();
    final detailsPanel = find.byKey(
      const ValueKey('calendar-academic-details-panel'),
    );
    expect(detailsPanel, findsOneWidget);
    expect(
      find.descendant(of: detailsPanel, matching: find.text('地点：本次来源未提供')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: detailsPanel, matching: find.text('教师：本次来源未提供')),
      findsOneWidget,
    );
    expect(find.text('尚未采集教务信息，重新同步补充'), findsNothing);

    await tester.tap(find.byKey(ValueKey<CalendarReference>(exam.reference)));
    await tester.pumpAndSettle();
    final examPanel = find.byKey(
      const ValueKey('calendar-academic-details-panel'),
    );
    expect(
      find.descendant(of: examPanel, matching: find.text('考试类型：期末考试')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: examPanel, matching: find.text('考试说明：闭卷，需携带证件')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: examPanel, matching: find.text('地点：本次来源未提供')),
      findsNothing,
    );

    await tester.tap(find.byKey(ValueKey<CalendarReference>(young.reference)));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('calendar-academic-details-panel')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('calendar-academic-details-uncollected')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('course facts and the full multi-teacher list are readable', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final academic = JwAcademicDetails(
      campus: '东区',
      building: '教学楼',
      room: 'A301',
      roomCode: 'A-301',
      customPlace: '北侧入口',
      virtual: false,
      teachers: const [
        '王老师（主讲）',
        '周老师（助教）',
        '顾老师（长文本教师姓名演示）',
        '陈老师',
        '李老师',
        '赵老师',
      ],
      semesterName: '2026 秋季学期',
      courseCode: 'CS-100',
      courseType: '专业基础课',
      lessonId: 42,
      groupId: 7,
      weekIndex: 4,
      weekday: 2,
      periods: 2,
      exerciseClass: true,
    );
    final course = _occurrence(
      kind: CalendarKind.course,
      id: 325,
      title: '多教师课程',
      academicDetails: academic,
    );
    final port = _FakeCalendarWorkspacePort(occurrences: [course]);
    addTearDown(port.dispose);
    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();

    await tester.tap(find.text('日'));
    await tester.pumpAndSettle();
    final dayTeacherKey = const ValueKey(
      'calendar-day-academic-course-325-0-teachers',
    );
    expect(find.text('地点：A301 · 教学楼 · 东区'), findsOneWidget);
    final dayTeacher = tester.widget<Text>(
      find
          .descendant(
            of: find.byKey(dayTeacherKey),
            matching: find.byType(Text),
          )
          .first,
    );
    expect(dayTeacher.data, '教师：${academic.teachers.join('、')}');
    expect(dayTeacher.maxLines, 2);
    final dayTeacherTooltip = tester.widget<Tooltip>(
      find
          .descendant(
            of: find.byKey(dayTeacherKey),
            matching: find.byType(Tooltip),
          )
          .first,
    );
    expect(dayTeacherTooltip.message, '教师：${academic.teachers.join('、')}');

    await tester.tap(find.byKey(ValueKey<CalendarReference>(course.reference)));
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('calendar-academic-details-panel'));
    expect(panel, findsOneWidget);
    for (final text in [
      '地点：A301 · 教学楼 · 东区',
      '校区：东区',
      '楼宇：教学楼',
      '教室：A301',
      '教室代码：A-301',
      '补充地点：北侧入口',
      '虚拟教室：否',
      '学期：2026 秋季学期',
      '课程号：CS-100',
      '课程类别：专业基础课',
      '周次序号：4',
      '星期序号：2',
      '节数：2',
      '习题课：是',
    ]) {
      expect(
        find.descendant(of: panel, matching: find.text(text)),
        findsOneWidget,
      );
    }
    expect(find.textContaining('课程标识'), findsNothing);
    expect(find.textContaining('教学班标识'), findsNothing);
    final detailTeacher = tester.widget<Text>(
      find
          .descendant(
            of: find.byKey(const ValueKey('calendar-academic-teachers')),
            matching: find.byType(Text),
          )
          .first,
    );
    expect(detailTeacher.data, '教师：${academic.teachers.join('、')}');
    expect(detailTeacher.maxLines, 4);
    final detailTeacherTooltip = tester.widget<Tooltip>(
      find
          .descendant(
            of: find.byKey(const ValueKey('calendar-academic-teachers')),
            matching: find.byType(Tooltip),
          )
          .first,
    );
    expect(detailTeacherTooltip.message, '教师：${academic.teachers.join('、')}');
    expect(tester.takeException(), isNull);
  });

  testWidgets('independent overlap clusters use independent lane widths', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final overlapA = _occurrence(
      kind: CalendarKind.course,
      id: 81,
      title: '并发一',
    );
    final overlapB = _occurrence(kind: CalendarKind.exam, id: 82, title: '并发二');
    final overlapC = _occurrence(
      kind: CalendarKind.personal,
      id: 83,
      title: '并发三',
    );
    final isolated = _occurrence(
      kind: CalendarKind.young,
      id: 84,
      title: '独立安排',
      startsAtUtc: DateTime.utc(2026, 10, 12, 3),
      endsAtUtc: DateTime.utc(2026, 10, 12, 4),
    );
    final port = _FakeCalendarWorkspacePort(
      occurrences: [overlapA, overlapB, overlapC, isolated],
    );
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();
    final overlapWidth = tester
        .getSize(find.byKey(ValueKey<CalendarReference>(overlapA.reference)))
        .width;
    final isolatedWidth = tester
        .getSize(find.byKey(ValueKey<CalendarReference>(isolated.reference)))
        .width;
    expect(isolatedWidth, greaterThan(overlapWidth * 2.5));
  });

  testWidgets('early overflow opens the selected overnight occurrence detail', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final early = [
      _occurrence(
        kind: CalendarKind.course,
        id: 91,
        title: '凌晨课程预览',
        location: '东区教学楼 A301',
        academicDetails: JwAcademicDetails(
          campus: '东区',
          building: '教学楼',
          room: 'A301',
          teachers: const ['凌晨教师甲', '凌晨教师乙'],
        ),
        startsAtUtc: DateTime.utc(2026, 10, 11, 16, 30),
        endsAtUtc: DateTime.utc(2026, 10, 11, 22, 30),
      ),
      _occurrence(
        kind: CalendarKind.course,
        id: 92,
        title: '凌晨更多课程',
        location: '西区教学楼 B201',
        academicDetails: JwAcademicDetails(
          campus: '西区',
          building: '教学楼',
          room: 'B201',
          teachers: const ['凌晨课程教师'],
        ),
        startsAtUtc: DateTime.utc(2026, 10, 11, 17, 30),
        endsAtUtc: DateTime.utc(2026, 10, 11, 19, 30),
      ),
      _occurrence(
        kind: CalendarKind.personal,
        id: 93,
        title: '凌晨安排 3',
        startsAtUtc: DateTime.utc(2026, 10, 11, 18, 30),
        endsAtUtc: DateTime.utc(2026, 10, 11, 20, 30),
      ),
    ];
    final port = _FakeCalendarWorkspacePort(occurrences: early);
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();
    final overflow = find.byKey(
      const ValueKey('calendar-week-overflow-early-2026-10-12'),
    );
    expect(overflow, findsOneWidget);
    final earlyTile = find.byKey(
      ValueKey<CalendarReference>(early.first.reference),
    );
    final earlyTooltip = tester.widget<Tooltip>(
      find.descendant(of: earlyTile, matching: find.byType(Tooltip)).first,
    );
    expect(earlyTooltip.message, contains('地点：东区教学楼 A301'));
    expect(earlyTooltip.message, contains('教师：凌晨教师乙、凌晨教师甲'));
    await tester.tap(overflow);
    await tester.pumpAndSettle();
    expect(find.textContaining('教师：凌晨课程教师'), findsOneWidget);
    final selected = early[1];
    await tester.tap(
      find.byKey(
        ValueKey(
          'calendar-overflow-item-course-${selected.reference.identity.localId}-0',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(port.view.detail?.occurrence.reference, selected.reference);
    expect(find.byKey(const ValueKey('calendar-detail-card')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('calendar-academic-details-panel')),
      findsOneWidget,
    );
    expect(find.text(selected.title), findsWidgets);
  });

  testWidgets('wide week layouts keep the last teaching period in view', (
    tester,
  ) async {
    for (final size in const [Size(1280, 720), Size(1560, 900)]) {
      await _setSize(tester, size);
      final occurrence = _occurrence(
        kind: CalendarKind.course,
        id: size.width.toInt(),
        title: '末节测试安排',
        startsAtUtc: DateTime.utc(2026, 10, 12, 13, 10),
        endsAtUtc: DateTime.utc(2026, 10, 12, 13, 55),
      );
      final port = _FakeCalendarWorkspacePort(
        occurrences: [occurrence, ..._compressedBandOccurrences()],
      );
      await tester.pumpWidget(_host(port));
      await tester.pumpAndSettle();

      expect(find.textContaining('第13节'), findsOneWidget);
      for (final key in const [
        'calendar-workspace-view-mode',
        'calendar-workspace-prev',
        'calendar-workspace-next',
        'calendar-workspace-date-picker',
        'calendar-workspace-today',
        'calendar-personal-create',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      expect(
        find.byKey(const ValueKey('calendar-week-period-13')),
        findsOneWidget,
      );
      final scrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('calendar-week-time-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(scrollable.position.maxScrollExtent, 0);
      expect(
        tester
            .getRect(
              find.byKey(ValueKey<CalendarReference>(occurrence.reference)),
            )
            .bottom,
        lessThanOrEqualTo(
          tester
              .getRect(find.byKey(const ValueKey('calendar-week-time-scroll')))
              .bottom,
        ),
      );
      expect(tester.takeException(), isNull, reason: 'layout at $size');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      port.dispose();
    }
  });

  testWidgets(
    'large text in a short window falls back to bounded axis scrolling',
    (tester) async {
      await _setSize(tester, const Size(320, 420));
      final port = _FakeCalendarWorkspacePort(
        occurrences: [
          _occurrence(
            kind: CalendarKind.course,
            id: 101,
            title: '窄窗课程',
            academicDetails: JwAcademicDetails(
              campus: '东区',
              building: '教学楼',
              room: 'A301',
              teachers: List.generate(24, (index) => '教师长姓名${index + 1}'),
            ),
          ),
          ..._compressedBandOccurrences(),
        ],
      );
      addTearDown(port.dispose);

      await tester.pumpWidget(_host(port, textScale: 1.8));
      await tester.pumpAndSettle();
      expect(find.textContaining('第13节'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('calendar-week-time-scroll')),
        findsOneWidget,
      );
      final scrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('calendar-week-time-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(scrollable.position.maxScrollExtent, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'series deletion requires confirmation and cancellation writes nothing',
    (tester) async {
      await _setSize(tester, const Size(1280, 900));
      final occurrence = _occurrence(
        kind: CalendarKind.personal,
        id: 52,
        ordinal: 1,
        title: '需要确认的系列',
      );
      final draft = PersonalEventDraft(
        title: occurrence.title,
        start: DateTime.utc(2026, 10, 12, 1),
        end: DateTime.utc(2026, 10, 12, 2),
        weekly: true,
      );
      final port = _FakeCalendarWorkspacePort(
        occurrences: [occurrence],
        personalDrafts: {occurrence.reference.identity: draft},
      );
      addTearDown(port.dispose);

      await tester.pumpWidget(_host(port));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey<CalendarReference>(occurrence.reference)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('calendar-personal-delete-series')),
      );
      await tester.tap(
        find.byKey(const ValueKey('calendar-personal-delete-series')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('删除整个个人安排'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(port.intents, isEmpty);

      await tester.tap(
        find.byKey(const ValueKey('calendar-personal-delete-series')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('calendar-personal-confirm-delete-series')),
      );
      await tester.pumpAndSettle();
      final intent = port.intents.single as DeletePersonalSeries;
      expect(intent.target, occurrence.reference);
      expect(intent.confirmed, isTrue);
    },
  );

  testWidgets('single-item deletion is confirmed separately from skipping', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final occurrence = _occurrence(
      kind: CalendarKind.personal,
      id: 59,
      title: '单次安排',
    );
    final draft = PersonalEventDraft(
      title: occurrence.title,
      start: DateTime.utc(2026, 10, 12, 1),
      end: DateTime.utc(2026, 10, 12, 2),
    );
    final port = _FakeCalendarWorkspacePort(
      occurrences: [occurrence],
      personalDrafts: {occurrence.reference.identity: draft},
    );
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey<CalendarReference>(occurrence.reference)),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('calendar-personal-delete-series')),
    );
    await tester.tap(
      find.byKey(const ValueKey('calendar-personal-delete-series')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('删除这条个人安排'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('calendar-personal-confirm-delete-single')),
    );
    await tester.pumpAndSettle();

    final intent = port.intents.single as DeletePersonalSeries;
    expect(intent.target, occurrence.reference);
    expect(intent.confirmed, isTrue);
    expect(port.intents.whereType<SetPersonalOccurrenceState>(), isEmpty);
  });

  testWidgets('failed writes show a fixed failure and never a saved receipt', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final occurrence = _occurrence(
      kind: CalendarKind.personal,
      id: 67,
      title: '保存失败安排',
    );
    final port = _FakeCalendarWorkspacePort(occurrences: [occurrence]);
    port.nextFailure = CalendarFailureCode.storageFailed;
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey<CalendarReference>(occurrence.reference)),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('calendar-personal-toggle-completed')),
    );
    await tester.tap(
      find.byKey(const ValueKey('calendar-personal-toggle-completed')),
    );
    await tester.pumpAndSettle();

    expect(port.intents.single, isA<SetPersonalOccurrenceState>());
    expect(find.text('本地日程暂时无法完成此操作，请稍后重试。'), findsWidgets);
    expect(find.text('已保存。'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a late write receipt from a replaced controller does not update the new page',
    (tester) async {
      await _setSize(tester, const Size(1280, 900));
      final occurrence = _occurrence(
        kind: CalendarKind.personal,
        id: 79,
        title: '旧页面安排',
      );
      final first = _FakeCalendarWorkspacePort(occurrences: [occurrence]);
      final second = _FakeCalendarWorkspacePort();
      first.executeGate = Completer<void>();
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      await tester.pumpWidget(_host(first));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey<CalendarReference>(occurrence.reference)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('calendar-personal-toggle-completed')),
      );
      await tester.tap(
        find.byKey(const ValueKey('calendar-personal-toggle-completed')),
      );
      await tester.pump();
      expect(first.intents, hasLength(1));

      await tester.pumpWidget(_host(second));
      await tester.pumpAndSettle();
      first.executeGate!.complete();
      await tester.pumpAndSettle();

      expect(second.intents, isEmpty);
      expect(find.text('已保存。'), findsNothing);
      expect(find.text('旧页面安排'), findsNothing);
    },
  );

  testWidgets(
    'a date picker owned by an old controller cannot change the new view',
    (tester) async {
      await _setSize(tester, const Size(1280, 900));
      final first = _FakeCalendarWorkspacePort();
      final second = _FakeCalendarWorkspacePort();
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      await tester.pumpWidget(_host(first));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('calendar-workspace-date-picker')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);

      await tester.pumpWidget(_host(second));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsNothing);
      expect(second.view.day, DateTime.utc(2026, 10, 12));
      expect(second.loadCalls, greaterThan(0));
    },
  );

  testWidgets('a create form keeps the context captured when it was opened', (
    tester,
  ) async {
    await _setSize(tester, const Size(1280, 900));
    final port = _FakeCalendarWorkspacePort();
    addTearDown(port.dispose);

    await tester.pumpWidget(_host(port));
    await tester.pumpAndSettle();
    final openedContext = port.view.window!.context;
    await tester.tap(find.byKey(const ValueKey('calendar-personal-create')));
    await tester.pumpAndSettle();
    port.rollContext();
    await tester.pump();

    await _enter(tester, 'calendar-event-title', '过期上下文安排');
    await _enter(tester, 'calendar-event-start-date', '2026-10-12');
    await _enter(tester, 'calendar-event-start-time', '09:30');
    await _enter(tester, 'calendar-event-end-date', '2026-10-12');
    await _enter(tester, 'calendar-event-end-time', '10:30');
    await _saveEvent(tester);

    expect(port.attemptedContexts.single, openedContext);
    expect(port.intents, isEmpty);
    expect(find.text('这条日程已更新，请重新选择后再操作。'), findsWidgets);
    expect(find.text('已保存。'), findsNothing);
  });

  testWidgets('fits short narrow and wide windows with larger text', (
    tester,
  ) async {
    for (final scenario in const [
      (size: Size(320, 420), scale: 1.8),
      (size: Size(600, 560), scale: 1.35),
      (size: Size(1280, 820), scale: 1.0),
    ]) {
      await _setSize(tester, scenario.size);
      final occurrence = _occurrence(
        kind: CalendarKind.course,
        id: scenario.size.width.toInt(),
        title: List<String>.filled(8, '合成日程标题').join('，'),
      );
      final port = _FakeCalendarWorkspacePort(occurrences: [occurrence]);
      await tester.pumpWidget(_host(port, textScale: scenario.scale));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('calendar-workspace-view-mode')),
        findsOneWidget,
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'layout at ${scenario.size}',
      );
      if (scenario.size.width == 320) {
        await tester.ensureVisible(
          find.byKey(const ValueKey('calendar-workspace-view-mode')),
        );
        await tester.tap(find.text('日'));
        await tester.pumpAndSettle();
        final item = find.byKey(
          ValueKey<CalendarReference>(occurrence.reference),
        );
        await tester.ensureVisible(item);
        await tester.pumpAndSettle();
        await tester.tap(item);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('calendar-detail-card')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull, reason: 'narrow detail');
        await tester.tap(find.byKey(const ValueKey('calendar-detail-close')));
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      port.dispose();
    }
  });
}

List<CalendarOccurrence> _compressedBandOccurrences() => [
  for (var index = 0; index < 3; index++) ...[
    _occurrence(
      kind: CalendarKind.personal,
      id: 201 + index,
      title: '全天压缩演示 ${index + 1}',
      allDay: true,
      startsAtUtc: DateTime.utc(2026, 10, 11, 16),
      endsAtUtc: DateTime.utc(2026, 10, 12, 16),
    ),
    _occurrence(
      kind: CalendarKind.personal,
      id: 211 + index,
      title: '凌晨压缩演示 ${index + 1}',
      startsAtUtc: DateTime.utc(2026, 10, 11, 17 + index),
      endsAtUtc: DateTime.utc(2026, 10, 11, 17 + index, 30),
    ),
  ],
];

Widget _host(CalendarWorkspacePort controller, {double textScale = 1}) =>
    MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF1F6B45),
      ),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(body: CalendarWorkspacePage(controller: controller)),
        ),
      ),
    );

Future<void> _setSize(WidgetTester tester, Size size) async {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  await tester.pump();
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  final field = find.byKey(ValueKey(key));
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

Future<void> _saveEvent(WidgetTester tester) async {
  final save = find.byKey(const ValueKey('calendar-event-save'));
  await tester.ensureVisible(save);
  await tester.pumpAndSettle();
  await tester.tap(save);
  await tester.pumpAndSettle();
}

CalendarOccurrence _occurrence({
  required CalendarKind kind,
  required int id,
  int ordinal = 0,
  String title = '合成事项',
  String location = '',
  JwAcademicDetails? academicDetails,
  DateTime? startsAtUtc,
  DateTime? endsAtUtc,
  bool allDay = false,
  bool hidden = false,
  bool skipped = false,
  bool completed = false,
  AgendaPresence presence = AgendaPresence.observed,
  AttendanceDecision attendance = AttendanceDecision.undecided,
  ListeningMode listening = ListeningMode.undecided,
}) => CalendarOccurrence(
  reference: CalendarReference(
    const CalendarContext(
      owner: 'synthetic-owner',
      resetEpoch: 1,
      agendaEpoch: 1,
    ),
    CalendarIdentity(kind, id, ordinal: ordinal),
    1,
  ),
  title: title,
  location: location,
  academicDetails: academicDetails,
  startsAtUtc: startsAtUtc ?? DateTime.utc(2026, 10, 12, 1),
  endsAtUtc: endsAtUtc ?? DateTime.utc(2026, 10, 12, 2),
  allDay: allDay,
  hidden: hidden,
  skipped: skipped,
  completed: completed,
  presence: presence,
  attendance: attendance,
  listening: listening,
);

DateTime _day(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);

DateTime _monday(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day - (value.weekday - 1));

final class _FakeCalendarWorkspacePort extends ChangeNotifier
    implements CalendarWorkspacePort {
  _FakeCalendarWorkspacePort({
    List<CalendarOccurrence> occurrences = const [],
    Map<CalendarIdentity, PersonalEventDraft> personalDrafts = const {},
    List<CalendarConflict> conflicts = const [],
    Set<CalendarIdentity> replacements = const {},
  }) : _occurrences = [...occurrences],
       _conflicts = [...conflicts],
       _personalDrafts = {...personalDrafts},
       _replacements = {...replacements},
       _view = CalendarWorkspaceView(
         day: DateTime.utc(2026, 10, 12),
         mode: CalendarViewMode.week,
         filter: CalendarFilter.all,
         includeInactive: false,
         loading: true,
       );

  final List<CalendarOccurrence> _occurrences;
  final List<CalendarConflict> _conflicts;
  final Map<CalendarIdentity, PersonalEventDraft> _personalDrafts;
  final Set<CalendarIdentity> _replacements;
  CalendarWorkspaceView _view;
  final List<CalendarIntent> intents = [];
  final List<CalendarContext> attemptedContexts = [];
  CalendarFailureCode? nextFailure;
  Completer<void>? executeGate;
  Completer<void>? loadGate;
  int loadCalls = 0;
  int selectCalls = 0;
  int _nextId = 100;
  int _contextEpoch = 1;

  @override
  CalendarWorkspaceView get view => _view;

  @override
  DateTime get today => DateTime.utc(2026, 10, 12);

  @override
  Future<void> load({
    DateTime? day,
    CalendarViewMode? mode,
    CalendarFilter? filter,
    bool? includeInactive,
  }) async {
    loadCalls++;
    final gate = loadGate;
    if (gate != null) await gate.future;
    final nextDay = _day(day ?? _view.day);
    final nextMode = mode ?? _view.mode;
    final nextFilter = filter ?? _view.filter;
    final include = includeInactive ?? _view.includeInactive;
    final window = _window(nextDay, nextMode, nextFilter, include);
    _view = CalendarWorkspaceView(
      day: nextDay,
      mode: nextMode,
      filter: nextFilter,
      includeInactive: include,
      window: window,
    );
    notifyListeners();
  }

  @override
  Future<void> select(CalendarReference? reference) async {
    selectCalls++;
    final occurrence = reference == null
        ? null
        : _occurrences.cast<CalendarOccurrence?>().firstWhere(
            (item) => item?.reference == reference,
            orElse: () => null,
          );
    _view = CalendarWorkspaceView(
      day: _view.day,
      mode: _view.mode,
      filter: _view.filter,
      includeInactive: _view.includeInactive,
      window: _view.window,
      detail: occurrence == null
          ? null
          : CalendarDetail(
              occurrence: occurrence,
              personalDraft: _personalDrafts[occurrence.reference.identity],
              hasOccurrenceReplacement: _replacements.contains(
                occurrence.reference.identity,
              ),
              relations: const [],
            ),
      loading: _view.loading,
      actionPending: _view.actionPending,
      sourceBusy: _view.sourceBusy,
      failure: _view.failure,
    );
    notifyListeners();
  }

  @override
  Future<CalendarWriteReceipt> execute(
    CalendarIntent intent, {
    required CalendarContext expectedContext,
  }) async {
    attemptedContexts.add(expectedContext);
    if (expectedContext != _view.window?.context) {
      throw const CalendarFailure(CalendarFailureCode.staleReference);
    }
    intents.add(intent);
    notifyListeners();
    final gate = executeGate;
    if (gate != null) await gate.future;
    final failure = nextFailure;
    if (failure != null) {
      nextFailure = null;
      throw CalendarFailure(failure);
    }
    _apply(intent);
    final selectedIdentity = _view.detail?.occurrence.reference.identity;
    _view = CalendarWorkspaceView(
      day: _view.day,
      mode: _view.mode,
      filter: _view.filter,
      includeInactive: _view.includeInactive,
      window: _window(
        _view.day,
        _view.mode,
        _view.filter,
        _view.includeInactive,
      ),
      detail: selectedIdentity == null
          ? null
          : _detailForIdentity(selectedIdentity),
    );
    notifyListeners();
    return const CalendarWriteReceipt(
      operationId: 'synthetic-operation',
      revision: 2,
      replayed: false,
    );
  }

  void rollContext() {
    _contextEpoch++;
    final detail = _view.detail;
    _view = CalendarWorkspaceView(
      day: _view.day,
      mode: _view.mode,
      filter: _view.filter,
      includeInactive: _view.includeInactive,
      window: _window(
        _view.day,
        _view.mode,
        _view.filter,
        _view.includeInactive,
      ),
      detail: detail,
    );
    notifyListeners();
  }

  void _apply(CalendarIntent intent) {
    switch (intent) {
      case CreatePersonalEvent(:final draft):
        final identity = CalendarIdentity(CalendarKind.personal, _nextId++);
        final reference = CalendarReference(
          const CalendarContext(
            owner: 'synthetic-owner',
            resetEpoch: 1,
            agendaEpoch: 1,
          ),
          identity,
          1,
        );
        _occurrences.add(
          CalendarOccurrence(
            reference: reference,
            title: draft.title,
            startsAtUtc: draft.startsAtUtc,
            endsAtUtc: draft.endsAtUtc,
            allDay: draft.allDay,
            location: draft.location,
            note: draft.note,
          ),
        );
        _personalDrafts[identity] = draft;
        break;
      case UpdatePersonalSeries(:final target, :final draft):
        _personalDrafts[target.identity] = draft;
        for (var index = 0; index < _occurrences.length; index++) {
          final item = _occurrences[index];
          if (item.reference.identity.kind == CalendarKind.personal &&
              item.reference.identity.localId == target.identity.localId) {
            _occurrences[index] = _copyOccurrence(
              item,
              title: draft.title,
              startsAtUtc: draft.startsAtUtc,
              endsAtUtc: draft.endsAtUtc,
              allDay: draft.allDay,
              location: draft.location,
              note: draft.note,
            );
          }
        }
        break;
      case UpdatePersonalOccurrence(:final target, :final replacement):
        final index = _occurrences.indexWhere(
          (item) => item.reference.identity == target.identity,
        );
        if (index >= 0) {
          _occurrences[index] = _copyOccurrence(
            _occurrences[index],
            title: replacement.title,
            startsAtUtc: replacement.startsAtUtc,
            endsAtUtc: replacement.endsAtUtc,
            allDay: replacement.allDay,
            location: replacement.location,
            note: replacement.note,
          );
        }
        break;
      case SetPersonalOccurrenceState(
        :final target,
        :final completed,
        :final skipped,
      ):
        final index = _occurrences.indexWhere(
          (item) => item.reference.identity == target.identity,
        );
        if (index >= 0) {
          _occurrences[index] = _copyOccurrence(
            _occurrences[index],
            completed: completed ?? _occurrences[index].completed,
            skipped: skipped ?? _occurrences[index].skipped,
          );
        }
        break;
      case DeletePersonalSeries(:final target):
        _occurrences.removeWhere(
          (item) =>
              item.reference.identity.kind == CalendarKind.personal &&
              item.reference.identity.localId == target.identity.localId,
        );
        _personalDrafts.removeWhere(
          (identity, _) => identity.localId == target.identity.localId,
        );
        break;
      case UpdateSchoolAnnotation(
        :final target,
        :final note,
        :final attendance,
        :final listening,
        :final hidden,
      ):
        final index = _occurrences.indexWhere(
          (item) => item.reference.identity == target.identity,
        );
        if (index >= 0) {
          _occurrences[index] = _copyOccurrence(
            _occurrences[index],
            note: note ?? _occurrences[index].note,
            attendance: attendance ?? _occurrences[index].attendance,
            listening: listening ?? _occurrences[index].listening,
            hidden: hidden ?? _occurrences[index].hidden,
          );
        }
        break;
      case SaveCalendarRelation():
        break;
      case DeleteCalendarRelation():
        break;
    }
  }

  CalendarDetail? _detailForIdentity(CalendarIdentity identity) {
    for (final occurrence in _occurrences) {
      if (occurrence.reference.identity == identity) {
        return CalendarDetail(
          occurrence: occurrence,
          personalDraft: _personalDrafts[identity],
          hasOccurrenceReplacement: _replacements.contains(identity),
          relations: const [],
        );
      }
    }
    return null;
  }

  CalendarWindow _window(
    DateTime day,
    CalendarViewMode mode,
    CalendarFilter filter,
    bool includeInactive,
  ) {
    final first = mode == CalendarViewMode.week ? _monday(day) : day;
    final days = mode == CalendarViewMode.week ? 7 : 1;
    final end = DateTime.utc(first.year, first.month, first.day + days);
    final rangeStart = first.subtract(const Duration(hours: 8));
    final rangeEnd = end.subtract(const Duration(hours: 8));
    final items = _occurrences
        .where((occurrence) {
          if (filter != CalendarFilter.all &&
              occurrence.reference.identity.kind.name != filter.name) {
            return false;
          }
          if (!includeInactive && (occurrence.hidden || occurrence.skipped)) {
            return false;
          }
          return occurrence.endsAtUtc.isAfter(rangeStart) &&
              occurrence.startsAtUtc.isBefore(rangeEnd);
        })
        .toList(growable: false);
    final segments = <CalendarDaySegment>[];
    for (final occurrence in items) {
      final localStart = occurrence.startsAtUtc.add(const Duration(hours: 8));
      final localEnd = occurrence.endsAtUtc.add(const Duration(hours: 8));
      for (var offset = 0; offset < days; offset++) {
        final date = DateTime.utc(first.year, first.month, first.day + offset);
        final dayStart = date;
        final dayEnd = date.add(const Duration(days: 1));
        if (!localEnd.isAfter(dayStart) || !localStart.isBefore(dayEnd)) {
          continue;
        }
        final clippedStart = localStart.isAfter(dayStart)
            ? localStart
            : dayStart;
        final clippedEnd = localEnd.isBefore(dayEnd) ? localEnd : dayEnd;
        segments.add(
          CalendarDaySegment(
            occurrence: occurrence,
            day: date,
            startMinute: (clippedStart.hour * 60 + clippedStart.minute)
                .toDouble(),
            endMinute: clippedEnd.isAtSameMomentAs(dayEnd)
                ? 1440
                : (clippedEnd.hour * 60 + clippedEnd.minute).toDouble(),
            continuesBefore: localStart.isBefore(dayStart),
            continuesAfter: localEnd.isAfter(dayEnd),
          ),
        );
      }
    }
    return CalendarWindow(
      context: _currentContext,
      revision: 1,
      query: CalendarQuery(
        firstDay: first,
        endDayExclusive: end,
        filter: filter,
      ),
      items: items,
      segments: segments,
      conflicts: _conflicts,
      matched: items.length,
      truncated: false,
      conflictsTruncated: false,
    );
  }

  CalendarContext get _currentContext => CalendarContext(
    owner: 'synthetic-owner',
    resetEpoch: 1,
    agendaEpoch: _contextEpoch,
  );
}

CalendarOccurrence _copyOccurrence(
  CalendarOccurrence item, {
  String? title,
  DateTime? startsAtUtc,
  DateTime? endsAtUtc,
  bool? allDay,
  bool? hidden,
  bool? skipped,
  bool? completed,
  String? location,
  String? note,
  JwAcademicDetails? academicDetails,
  AttendanceDecision? attendance,
  ListeningMode? listening,
}) => CalendarOccurrence(
  reference: item.reference,
  title: title ?? item.title,
  startsAtUtc: startsAtUtc ?? item.startsAtUtc,
  endsAtUtc: endsAtUtc ?? item.endsAtUtc,
  allDay: allDay ?? item.allDay,
  presence: item.presence,
  hidden: hidden ?? item.hidden,
  skipped: skipped ?? item.skipped,
  completed: completed ?? item.completed,
  location: location ?? item.location,
  academicDetails: academicDetails ?? item.academicDetails,
  note: note ?? item.note,
  attendance: attendance ?? item.attendance,
  listening: listening ?? item.listening,
);
