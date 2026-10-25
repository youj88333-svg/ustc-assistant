import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/data/reminder_projection.dart';

const _context = CalendarContext(
  owner: 'synthetic-reminder-owner',
  resetEpoch: 2,
  agendaEpoch: 4,
);
const _projection = ReminderProjection();

void main() {
  test('timed reminder is 30 minutes early and keeps its key after a move', () {
    final start = DateTime.utc(2026, 10, 15, 2, 30);
    final before = _input(
      school: [
        _school(CalendarKind.course, 9, start, title: '数据结构', location: '东区教室'),
      ],
    );
    final after = _input(
      school: [
        _school(
          CalendarKind.course,
          9,
          start.add(const Duration(hours: 1)),
          version: 2,
          title: '数据结构',
          location: '东区教室',
        ),
      ],
    );

    final first = _projection
        .project(before, DateTime.utc(2026, 10, 15))
        .items
        .single;
    final moved = _projection
        .project(after, DateTime.utc(2026, 10, 15))
        .items
        .single;

    expect(first.fireAtUtc, DateTime.utc(2026, 10, 15, 2));
    expect(first.slot, 0);
    expect(moved.logicalKey, first.logicalKey);
    expect(moved.digest, isNot(first.digest));
    expect(moved.target.version, 2);
  });

  test('all-day default fires at 09:00 on the Beijing start date', () {
    final input = _input(
      personal: [
        _series(
          3,
          PersonalEventDraft(
            title: '全天安排',
            start: DateTime.utc(2026, 10, 15),
            end: DateTime.utc(2026, 10, 16),
            allDay: true,
          ),
        ),
      ],
    );

    final result = _projection.project(input, DateTime.utc(2026, 10, 14, 23));

    expect(result.items, hasLength(1));
    expect(result.items.single.fireAtUtc, DateTime.utc(2026, 10, 15, 1));
    expect(result.items.single.detail, contains('2026-10-15'));
    expect(result.items.single.slot, 0);
  });

  test('exact occurrence pair overrides series pair and equal slots merge', () {
    final series = _series(
      7,
      _timedDraft(
        DateTime.utc(2026, 10, 1, 2),
        DateTime.utc(2026, 10, 1, 3),
        weekly: true,
      ),
      version: 2,
    );
    final input = _input(
      personal: [series],
      reminderOverrides: [
        ReminderOverride(
          kind: ReminderKind.personal,
          localId: 7,
          ordinal: -1,
          pair: const ReminderPair(
            ReminderRule.before(60),
            ReminderRule.before(30),
          ),
        ),
        ReminderOverride(
          kind: ReminderKind.personal,
          localId: 7,
          ordinal: 2,
          pair: const ReminderPair(
            ReminderRule.before(15),
            ReminderRule.before(15),
          ),
        ),
      ],
    );
    final exactOldTarget = ReminderTarget.calendar(
      const CalendarReference(
        _context,
        CalendarIdentity(CalendarKind.personal, 7, ordinal: 2),
        1,
      ),
    );
    final seriesTarget = ReminderTarget.calendar(
      const CalendarReference(
        _context,
        CalendarIdentity(CalendarKind.personal, 7, ordinal: 1),
        1,
      ),
    );

    final exact = _projection.resolve(input, exactOldTarget);
    final inherited = _projection.resolve(input, seriesTarget);

    expect(exact, hasLength(1));
    expect(exact.single.slot, 0);
    expect(exact.single.target.version, 2);
    expect(exact.single.fireAtUtc, DateTime.utc(2026, 10, 15, 1, 45));
    expect(inherited.map((value) => value.slot), [0, 1]);
    expect(inherited.first.fireAtUtc, DateTime.utc(2026, 10, 8, 1));
    expect(inherited.last.fireAtUtc, DateTime.utc(2026, 10, 8, 1, 30));
  });

  test(
    'hidden, skipped, completed, and attendance-skip items do not remind',
    () {
      final start = DateTime.utc(2026, 10, 16, 2);
      final input = _input(
        school: [
          _school(
            CalendarKind.course,
            1,
            start,
            presence: AgendaPresence.missingWithinScope,
          ),
          _school(
            CalendarKind.exam,
            2,
            start,
            presence: AgendaPresence.outsideScope,
          ),
          _school(CalendarKind.course, 3, start, hidden: true),
          _school(CalendarKind.course, 4, start, skipped: true),
          _school(CalendarKind.course, 5, start, completed: true),
          _school(
            CalendarKind.course,
            6,
            start,
            attendance: AttendanceDecision.skip,
          ),
        ],
        personal: [
          _series(20, _timedDraft(start, start.add(const Duration(hours: 1)))),
          _series(21, _timedDraft(start, start.add(const Duration(hours: 1)))),
        ],
        calendarOverrides: [
          const PersonalOccurrenceOverride(
            localId: 20,
            ordinal: 0,
            skipped: true,
          ),
          const PersonalOccurrenceOverride(
            localId: 21,
            ordinal: 0,
            completed: true,
          ),
        ],
      );

      final result = _projection.project(input, DateTime.utc(2026, 10, 15));

      expect(result.items.map((value) => value.target.localId).toSet(), {1, 2});
    },
  );

  test(
    'task status gates deadlines while planned blocks use their own status',
    () {
      final deadlineAt = DateTime.utc(2026, 10, 16, 2);
      final input = _input(
        planBlocks: [
          _block(
            101,
            deadlineAt,
            TaskStatus.completed,
            PlanBlockStatus.planned,
          ),
          _block(
            102,
            deadlineAt,
            TaskStatus.cancelled,
            PlanBlockStatus.planned,
          ),
          _block(103, deadlineAt, TaskStatus.active, PlanBlockStatus.done),
          _block(104, deadlineAt, TaskStatus.active, PlanBlockStatus.skipped),
        ],
        deadlines: [
          _deadline(1, deadlineAt, TaskStatus.active),
          _deadline(2, deadlineAt, TaskStatus.blocked),
          _deadline(3, deadlineAt, TaskStatus.completed),
          _deadline(4, deadlineAt, TaskStatus.cancelled),
        ],
      );

      final result = _projection.project(input, DateTime.utc(2026, 10, 15));

      expect(
        result.items
            .map((value) => '${value.target.kind.name}:${value.target.localId}')
            .toSet(),
        {'taskDeadline:1', 'taskDeadline:2', 'planBlock:101', 'planBlock:102'},
      );
    },
  );

  test(
    'private display omits title, location, and note from content and digest',
    () {
      ReminderInput inputFor(
        String title,
        String location,
        String note,
        int version,
      ) => _input(
        personal: [
          _series(
            14,
            _timedDraft(
              DateTime.utc(2026, 10, 15, 2),
              DateTime.utc(2026, 10, 15, 3),
              title: title,
              location: location,
              note: note,
            ),
            version: version,
          ),
        ],
        preferences: const ReminderPreferences(
          enabled: true,
          privateDisplay: true,
        ),
      );

      final first = _projection
          .project(
            inputFor('SECRET-TITLE', 'SECRET-LOCATION', 'SECRET-NOTE', 1),
            DateTime.utc(2026, 10, 15),
          )
          .items
          .single;
      final edited = _projection
          .project(
            inputFor('NEW-SECRET-TITLE', 'NEW-SECRET-LOCATION', 'NEW-NOTE', 2),
            DateTime.utc(2026, 10, 15),
          )
          .items
          .single;

      expect(first.title, '日程提醒');
      expect(first.detail, contains('个人日程'));
      expect(first.detail, contains('2026-10-15 10:00'));
      expect(first.location, isEmpty);
      expect(first.title, isNot(contains('SECRET')));
      expect(first.detail, isNot(contains('SECRET')));
      expect(first.digest, edited.digest);
    },
  );

  test(
    'projection keeps nearest 512 and reports the last complete fire day',
    () {
      final school = <CalendarOccurrence>[];
      final firstDay = DateTime.utc(2026, 10, 15);
      var id = 1;
      for (var day = 0; day < 180; day++) {
        final start = firstDay.add(Duration(days: day, hours: 2));
        for (var withinDay = 0; withinDay < 3; withinDay++) {
          school.add(
            _school(
              CalendarKind.course,
              id++,
              start.add(Duration(minutes: withinDay * 5)),
            ),
          );
        }
      }

      final result = _projection.project(
        _input(school: school),
        DateTime.utc(2026, 10, 15),
      );

      expect(result.items, hasLength(512));
      expect(result.candidateCount, 540);
      expect(result.complete, isFalse);
      expect(result.throughDay, firstDay.add(const Duration(days: 169)));
      final sorted = [...result.items]
        ..sort((left, right) {
          final time = left.fireAtUtc.compareTo(right.fireAtUtc);
          return time != 0 ? time : left.logicalKey.compareTo(right.logicalKey);
        });
      expect(
        result.items.map((value) => value.logicalKey).toList(),
        sorted.map((value) => value.logicalKey).toList(),
      );
    },
  );

  test(
    'single-day truncation stays incomplete and resolve can inspect omitted row',
    () {
      final start = DateTime.utc(2026, 10, 15, 2);
      final school = List.generate(
        501,
        (index) => _school(CalendarKind.course, index + 1, start),
      );
      final input = _input(school: school);

      final result = _projection.project(input, DateTime.utc(2026, 10, 15));
      final oldTarget = ReminderTarget.calendar(
        CalendarReference(
          _context,
          const CalendarIdentity(CalendarKind.course, 501),
          1,
        ),
      );
      final resolved = _projection.resolve(input, oldTarget);

      expect(result.items, hasLength(500));
      expect(result.candidateCount, 500);
      expect(result.complete, isFalse);
      expect(result.throughDay, DateTime.utc(2026, 10, 14));
      expect(result.items.any((value) => value.target.localId == 501), isFalse);
      expect(resolved, hasLength(1));
      expect(resolved.single.target.localId, 501);
    },
  );
}

ReminderInput _input({
  List<CalendarOccurrence> school = const [],
  List<PersonalSeries> personal = const [],
  List<PersonalOccurrenceOverride> calendarOverrides = const [],
  List<CalendarOccurrence> planBlocks = const [],
  List<ReminderDeadline> deadlines = const [],
  List<ReminderOverride> reminderOverrides = const [],
  ReminderPreferences preferences = const ReminderPreferences(enabled: true),
}) => ReminderInput(
  snapshot: CalendarSnapshot(
    context: _context,
    revision: 18,
    school: school,
    personal: personal,
    overrides: calendarOverrides,
    relations: const [],
    planBlocks: planBlocks,
  ),
  deadlines: deadlines,
  overrides: reminderOverrides,
  preferences: preferences,
);

PersonalSeries _series(int id, PersonalEventDraft draft, {int version = 1}) =>
    PersonalSeries(localId: id, version: version, draft: draft);

PersonalEventDraft _timedDraft(
  DateTime start,
  DateTime end, {
  String title = '合成日程',
  String location = '',
  String note = '',
  bool weekly = false,
}) => PersonalEventDraft(
  title: title,
  start: start,
  end: end,
  location: location,
  note: note,
  weekly: weekly,
);

CalendarOccurrence _school(
  CalendarKind kind,
  int id,
  DateTime start, {
  int version = 1,
  String title = '合成安排',
  String location = '',
  AgendaPresence presence = AgendaPresence.observed,
  bool hidden = false,
  bool skipped = false,
  bool completed = false,
  AttendanceDecision attendance = AttendanceDecision.undecided,
}) => CalendarOccurrence(
  reference: CalendarReference(_context, CalendarIdentity(kind, id), version),
  title: title,
  startsAtUtc: start,
  endsAtUtc: start.add(const Duration(hours: 1)),
  location: location,
  presence: presence,
  hidden: hidden,
  skipped: skipped,
  completed: completed,
  attendance: attendance,
);

CalendarOccurrence _block(
  int id,
  DateTime start,
  TaskStatus parentStatus,
  PlanBlockStatus status,
) => CalendarOccurrence(
  reference: CalendarReference(
    _context,
    CalendarIdentity(CalendarKind.planBlock, id),
    1,
  ),
  title: '合成任务时间块',
  startsAtUtc: start,
  endsAtUtc: start.add(const Duration(hours: 1)),
  task: const TaskReference(_context, 90, 1),
  taskStatus: parentStatus,
  planBlockStatus: status,
);

ReminderDeadline _deadline(int id, DateTime at, TaskStatus status) =>
    ReminderDeadline(
      reference: TaskReference(_context, id, 1),
      title: '合成任务 $id',
      deadlineAtUtc: at,
      status: status,
    );
