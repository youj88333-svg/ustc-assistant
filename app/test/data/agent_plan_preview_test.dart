import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/core/agent_action_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/data/agent_plan_preview.dart';

const _context = CalendarContext(
  owner: 'synthetic-preview-owner',
  resetEpoch: 2,
  agendaEpoch: 3,
);
final _nowUtc = DateTime.utc(2026, 10, 12, 17);

void main() {
  test('new plan block reports overlap with a missing school source', () {
    final result = previewAgentPlan(
      _snapshot(
        school: [
          _school(
            CalendarKind.course,
            11,
            DateTime.utc(2026, 10, 13, 2),
            DateTime.utc(2026, 10, 13, 3),
            presence: AgendaPresence.missingWithinScope,
            title: '缺失来源安排',
          ),
        ],
      ),
      [
        const AgentCreateTask('study', TaskDraft(title: '新学习任务')),
        AgentDependentBlock(
          'study',
          _blockDraft(DateTime.utc(2026, 10, 13, 2, 30), 60),
        ),
      ],
      _nowUtc,
    );

    expect(result.complete, isTrue);
    expect(result.freeConstraintViolated, isTrue);
    expect(result.actionConflicts, hasLength(1));
    expect(result.actionConflicts.single.leftName, anyOf('缺失来源安排', '新学习任务'));
    expect(
      '${result.actionConflicts.single.leftName} / '
      '${result.actionConflicts.single.rightName}',
      contains('新学习任务'),
    );
    expect(
      '${result.actionConflicts.single.leftName} / '
      '${result.actionConflicts.single.rightName}',
      contains('缺失来源安排'),
    );
    expect(
      result.actionConflicts.single.overlapStartBeijing,
      '2026-10-13 10:30',
    );
  });

  test('two new blocks for one task are checked against each other', () {
    final result = previewAgentPlan(_snapshot(), [
      const AgentCreateTask('pair', TaskDraft(title: '同一任务')),
      AgentDependentBlock(
        'pair',
        _blockDraft(DateTime.utc(2026, 10, 13, 2), 60),
      ),
      AgentDependentBlock(
        'pair',
        _blockDraft(DateTime.utc(2026, 10, 13, 2, 30), 60),
      ),
    ], _nowUtc);

    expect(result.complete, isTrue);
    expect(result.freeConstraintViolated, isTrue);
    expect(result.actionConflicts, hasLength(1));
    expect(result.actionConflicts.single.leftName, '同一任务');
    expect(result.actionConflicts.single.rightName, '同一任务');
  });

  test('moving a block replaces its old interval in the projection', () {
    final priorBlock = _block(
      id: 6,
      taskId: 8,
      title: '移动安排',
      start: DateTime.utc(2026, 10, 13, 2),
      end: DateTime.utc(2026, 10, 13, 3),
    );
    final result = previewAgentPlan(
      _snapshot(
        school: [
          _school(
            CalendarKind.exam,
            5,
            DateTime.utc(2026, 10, 13, 2, 30),
            DateTime.utc(2026, 10, 13, 3, 30),
            title: '旧位置考试',
          ),
        ],
        planBlocks: [priorBlock],
      ),
      [
        AgentCalendarChange(
          UpdatePlanBlock(
            priorBlock.reference,
            _blockDraft(DateTime.utc(2026, 10, 14, 2), 60),
          ),
        ),
      ],
      _nowUtc,
    );

    expect(result.complete, isTrue);
    expect(result.freeConstraintViolated, isFalse);
    expect(result.actionConflicts, isEmpty);
    expect(result.existingConflicts, isEmpty);
  });

  test('all-day personal events do not occupy a timed conflict interval', () {
    final result = previewAgentPlan(
      _snapshot(
        school: [
          _school(
            CalendarKind.course,
            1,
            DateTime.utc(2026, 10, 13, 2),
            DateTime.utc(2026, 10, 13, 3),
            title: '白天课程',
          ),
        ],
      ),
      [
        AgentCalendarChange(
          CreatePersonalEvent(
            PersonalEventDraft(
              title: '全天安排',
              start: DateTime.utc(2026, 10, 13),
              end: DateTime.utc(2026, 10, 14),
              allDay: true,
            ),
          ),
        ),
      ],
      _nowUtc,
    );

    expect(result.complete, isTrue);
    expect(result.freeConstraintViolated, isFalse);
    expect(result.actionConflicts, isEmpty);
  });

  test(
    'notConflict is displayed while actual overlap still violates free time',
    () {
      final personalIdentity = const CalendarIdentity(CalendarKind.personal, 4);
      final courseIdentity = const CalendarIdentity(CalendarKind.course, 2);
      final result = previewAgentPlan(
        _snapshot(
          school: [
            _school(
              CalendarKind.course,
              2,
              DateTime.utc(2026, 10, 13, 4, 30),
              DateTime.utc(2026, 10, 13, 5, 30),
              title: '已标记不冲突的课程',
            ),
          ],
          personal: [
            PersonalSeries(
              localId: 4,
              version: 1,
              draft: PersonalEventDraft(
                title: '个人事件',
                start: DateTime.utc(2026, 10, 13, 2),
                end: DateTime.utc(2026, 10, 13, 3),
              ),
            ),
          ],
          relations: [
            CalendarRelation(
              reference: const CalendarRelationReference(_context, 9, 1),
              left: personalIdentity,
              right: courseIdentity,
              kind: CalendarRelationKind.notConflict,
            ),
          ],
        ),
        [
          AgentCalendarChange(
            UpdatePersonalSeries(
              _reference(personalIdentity),
              PersonalEventDraft(
                title: '个人事件',
                start: DateTime.utc(2026, 10, 13, 4),
                end: DateTime.utc(2026, 10, 13, 5),
              ),
            ),
          ),
        ],
        _nowUtc,
      );

      expect(result.complete, isTrue);
      expect(result.freeConstraintViolated, isTrue);
      expect(result.actionConflicts, hasLength(1));
      expect(
        result.actionConflicts.single.status,
        CalendarConflictStatus.notConflict,
      );
      expect(result.actionConflicts.single.statusLabel, '已标记不冲突');
    },
  );

  test('setting a notConflict relation cannot hide a real overlap', () {
    final personalIdentity = const CalendarIdentity(CalendarKind.personal, 4);
    final courseIdentity = const CalendarIdentity(CalendarKind.course, 2);
    final result = previewAgentPlan(
      _snapshot(
        school: [
          _school(
            CalendarKind.course,
            2,
            DateTime.utc(2026, 10, 13, 2, 30),
            DateTime.utc(2026, 10, 13, 3, 30),
          ),
        ],
        personal: [
          PersonalSeries(
            localId: 4,
            version: 1,
            draft: PersonalEventDraft(
              title: '个人安排',
              start: DateTime.utc(2026, 10, 13, 2),
              end: DateTime.utc(2026, 10, 13, 3),
            ),
          ),
        ],
      ),
      [
        AgentCalendarChange(
          SaveCalendarRelation(
            left: _reference(personalIdentity),
            right: _reference(courseIdentity),
            kind: CalendarRelationKind.notConflict,
            note: '合成关系',
          ),
        ),
      ],
      _nowUtc,
    );

    expect(result.complete, isTrue);
    expect(result.freeConstraintViolated, isTrue);
    expect(result.existingConflicts, hasLength(1));
    expect(
      result.existingConflicts.single.status,
      CalendarConflictStatus.notConflict,
    );
  });

  test('conflict summaries convert UTC overlap across midnight to Beijing', () {
    final result = previewAgentPlan(
      _snapshot(
        school: [
          _school(
            CalendarKind.young,
            7,
            DateTime.utc(2026, 10, 13, 16),
            DateTime.utc(2026, 10, 13, 17),
            title: '跨日来源活动',
          ),
        ],
      ),
      [
        const AgentCreateTask('late', TaskDraft(title: '跨日任务')),
        AgentDependentBlock(
          'late',
          _blockDraft(DateTime.utc(2026, 10, 13, 15, 30), 60),
        ),
      ],
      _nowUtc,
    );

    expect(result.windowFirstDayBeijing, DateTime.utc(2026, 10, 13));
    expect(result.windowEndDayExclusiveBeijing, DateTime.utc(2026, 11, 13));
    expect(
      result.actionConflicts.single.overlapStartBeijing,
      '2026-10-14 00:00',
    );
    expect(result.actionConflicts.single.overlapEndBeijing, '2026-10-14 00:30');
  });

  test(
    'single weekly exception checks its bounded window without changing later repeats',
    () {
      final identity = const CalendarIdentity(
        CalendarKind.personal,
        12,
        ordinal: 1,
      );
      final result = previewAgentPlan(
        _snapshot(
          school: [
            _school(
              CalendarKind.exam,
              4,
              DateTime.utc(2026, 10, 19, 4, 30),
              DateTime.utc(2026, 10, 19, 5),
              title: '例外新位置',
            ),
          ],
          personal: [
            PersonalSeries(
              localId: 12,
              version: 1,
              draft: PersonalEventDraft(
                title: '每周安排',
                start: DateTime.utc(2026, 10, 12, 2),
                end: DateTime.utc(2026, 10, 12, 3),
                weekly: true,
              ),
            ),
          ],
        ),
        [
          AgentCalendarChange(
            UpdatePersonalOccurrence(
              _reference(identity),
              PersonalEventDraft(
                title: '移动后的例外',
                start: DateTime.utc(2026, 10, 19, 4),
                end: DateTime.utc(2026, 10, 19, 5),
              ),
            ),
          ),
        ],
        _nowUtc,
      );

      expect(result.complete, isTrue);
      expect(result.freeConstraintViolated, isTrue);
      expect(
        result.warnings.map((warning) => warning.code),
        isNot(contains(AgentPlanPreviewWarningCode.recurringBeyondWindow)),
      );
      expect(result.actionConflicts, hasLength(1));
      expect(
        '${result.actionConflicts.single.leftName} / '
        '${result.actionConflicts.single.rightName}',
        contains('移动后的例外'),
      );
    },
  );

  test('completed task status does not hide its still-planned time block', () {
    final block = _block(
      id: 5,
      taskId: 7,
      title: '仍计划中的块',
      start: DateTime.utc(2026, 10, 13, 2),
      end: DateTime.utc(2026, 10, 13, 3),
      taskStatus: TaskStatus.completed,
      blockStatus: PlanBlockStatus.planned,
    );
    final result = previewAgentPlan(
      _snapshot(
        school: [
          _school(
            CalendarKind.course,
            3,
            DateTime.utc(2026, 10, 13, 2, 30),
            DateTime.utc(2026, 10, 13, 3, 30),
            presence: AgendaPresence.missingWithinScope,
            title: '缺失学校记录',
          ),
        ],
        planBlocks: [block],
      ),
      [
        AgentCalendarChange(
          SetTaskStatus(TaskReference(_context, 7, 1), TaskStatus.blocked),
        ),
      ],
      _nowUtc,
    );

    expect(result.complete, isTrue);
    expect(result.existingConflicts, hasLength(1));
    expect(
      '${result.existingConflicts.single.leftName} / '
      '${result.existingConflicts.single.rightName}',
      contains('仍计划中的块'),
    );
  });

  test('reactivating a skipped block checks its actual time interval', () {
    final skipped = _block(
      id: 5,
      taskId: 7,
      title: '重新启用的块',
      start: DateTime.utc(2026, 10, 13, 2),
      end: DateTime.utc(2026, 10, 13, 3),
      blockStatus: PlanBlockStatus.skipped,
    );
    final result = previewAgentPlan(
      _snapshot(
        school: [
          _school(
            CalendarKind.course,
            3,
            DateTime.utc(2026, 10, 13, 2, 30),
            DateTime.utc(2026, 10, 13, 3, 30),
            presence: AgendaPresence.missingWithinScope,
            title: '学校缺失记录',
          ),
        ],
        planBlocks: [skipped],
      ),
      [
        AgentCalendarChange(
          SetPlanBlockStatus(skipped.reference, PlanBlockStatus.planned),
        ),
      ],
      _nowUtc,
    );

    expect(result.complete, isTrue);
    expect(result.freeConstraintViolated, isTrue);
    expect(result.actionConflicts, hasLength(1));
    expect(
      '${result.actionConflicts.single.leftName} / '
      '${result.actionConflicts.single.rightName}',
      contains('重新启用的块'),
    );
  });

  test(
    'deleting a parent task removes its blocks from the projected calendar',
    () {
      final block = _block(
        id: 5,
        taskId: 7,
        title: '父任务时间块',
        start: DateTime.utc(2026, 10, 13, 2),
        end: DateTime.utc(2026, 10, 13, 3),
      );
      final result = previewAgentPlan(
        _snapshot(
          school: [
            _school(
              CalendarKind.exam,
              3,
              DateTime.utc(2026, 10, 13, 2, 30),
              DateTime.utc(2026, 10, 13, 3, 30),
              title: '重叠考试',
            ),
          ],
          planBlocks: [block],
        ),
        [
          AgentCalendarChange(
            DeleteTask(TaskReference(_context, 7, 1), confirmed: true),
          ),
        ],
        _nowUtc,
      );

      expect(result.complete, isTrue);
      expect(result.freeConstraintViolated, isFalse);
      expect(result.actionConflicts, isEmpty);
      expect(result.existingConflicts, isEmpty);
      expect(
        result.warnings.map((warning) => warning.code),
        contains(AgentPlanPreviewWarningCode.deletedTaskBlocks),
      );
    },
  );

  test('undo remains incomplete without an inverse snapshot', () {
    final result = previewAgentPlan(_snapshot(), [
      AgentCalendarChange(
        UndoCalendarWrite(
          const CalendarUndoReference(
            _context,
            'calendar-undo-00000000000000000000000000000000',
          ),
        ),
      ),
    ], _nowUtc);

    expect(result.complete, isFalse);
    expect(result.freeConstraintViolated, isNull);
    expect(
      result.warnings.map((warning) => warning.code),
      contains(AgentPlanPreviewWarningCode.undoUnavailable),
    );
  });
}

CalendarSnapshot _snapshot({
  List<CalendarOccurrence> school = const [],
  List<PersonalSeries> personal = const [],
  List<PersonalOccurrenceOverride> overrides = const [],
  List<CalendarRelation> relations = const [],
  List<CalendarOccurrence> planBlocks = const [],
}) => CalendarSnapshot(
  context: _context,
  revision: 10,
  school: school,
  personal: personal,
  overrides: overrides,
  relations: relations,
  planBlocks: planBlocks,
);

CalendarOccurrence _school(
  CalendarKind kind,
  int id,
  DateTime start,
  DateTime end, {
  AgendaPresence presence = AgendaPresence.observed,
  String title = '合成来源安排',
}) => CalendarOccurrence(
  reference: CalendarReference(_context, CalendarIdentity(kind, id), 1),
  title: title,
  startsAtUtc: start,
  endsAtUtc: end,
  presence: presence,
);

CalendarOccurrence _block({
  required int id,
  required int taskId,
  required String title,
  required DateTime start,
  required DateTime end,
  int version = 1,
  TaskStatus taskStatus = TaskStatus.active,
  PlanBlockStatus blockStatus = PlanBlockStatus.planned,
}) => CalendarOccurrence(
  reference: CalendarReference(
    _context,
    CalendarIdentity(CalendarKind.planBlock, id),
    version,
  ),
  title: title,
  startsAtUtc: start,
  endsAtUtc: end,
  task: TaskReference(_context, taskId, version),
  taskStatus: taskStatus,
  planBlockStatus: blockStatus,
  skipped: blockStatus == PlanBlockStatus.skipped,
  completed: blockStatus == PlanBlockStatus.done,
);

CalendarReference _reference(CalendarIdentity identity, {int version = 1}) =>
    CalendarReference(_context, identity, version);

PlanBlockDraft _blockDraft(DateTime start, int durationMinutes) =>
    PlanBlockDraft(
      startsAtUtc: start,
      endsAtUtc: start.add(Duration(minutes: durationMinutes)),
    );
