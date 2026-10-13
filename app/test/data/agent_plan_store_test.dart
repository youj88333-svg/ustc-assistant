import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agent_action_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

final _clock = FixedClock(DateTime.utc(2026, 10, 13, 8));
final _key = Uint8List.fromList('synthetic-agent-plan-key'.codeUnits);

void main() {
  test(
    'planning checks the final task deadline and reports incomplete estimated time',
    () async {
      final store = await _open();
      final ticket = await _ticket(store);
      final port = store.localCalendar;
      final (context, revision) = await port.readPlanContext();
      final changes = <AgentLocalChange>[
        AgentCreateTask(
          'deadline',
          TaskDraft(
            title: '合成截止任务',
            deadlineAtUtc: DateTime.utc(2026, 10, 13, 6),
            estimatedMinutes: 90,
          ),
        ),
        AgentDependentBlock(
          'deadline',
          PlanBlockDraft(
            startsAtUtc: DateTime.utc(2026, 10, 13, 7),
            endsAtUtc: DateTime.utc(2026, 10, 13, 8),
          ),
        ),
      ];
      await expectLater(
        port.prepareLocalPlan(
          ticket,
          context,
          revision,
          changes,
          requireFree: true,
        ),
        throwsA(isA<CalendarFailure>()),
      );
      expect(
        (await port.queryTasks(const TaskQuery(filter: TaskFilter.all))).items,
        isEmpty,
      );
      final manual = await port.prepareLocalPlan(
        ticket,
        context,
        revision,
        changes,
      );
      expect(manual.view.warning, contains('晚于其截止'));
      expect(manual.view.warning, contains('尚未覆盖全部预计时长'));
      await port.rejectLocalPlan(manual);
    },
  );
  test(
    'new task and dependent blocks commit in one revision with one group undo',
    () async {
      final store = await _open();
      final ticket = await _ticket(store);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, beforeRevision) = await planPort.readPlanContext();

      final plan = await planPort
          .prepareLocalPlan(ticket, context, beforeRevision, [
            const AgentCreateTask(
              'review',
              TaskDraft(
                title: '合成复习任务',
                description: '合成任务说明',
                note: '合成私人备注',
                estimatedMinutes: 90,
                priority: TaskPriority.high,
              ),
            ),
            AgentDependentBlock('review', _block(14, 1, 2, note: '第一块')),
            AgentDependentBlock('review', _block(14, 3, 4, note: '第二块')),
          ]);
      final receipt = await planPort.commitLocalPlan(
        await planPort.approveLocalPlan(plan),
      );

      final (afterContext, afterRevision) = await planPort.readPlanContext();
      final task = await _taskByTitle(store, '合成复习任务');
      final detail = await store.localCalendar.taskDetail(task.reference);
      expect(afterContext, context);
      expect(afterRevision, beforeRevision + 1);
      expect(receipt.replayed, isFalse);
      expect(receipt.committedCount, 3);
      expect(receipt.undo, isNotNull);
      expect(detail.blocks, hasLength(2));
      expect(detail.blocks.map((block) => block.draft.note), ['第一块', '第二块']);
      expect(await _count(store, 'agenda_plan_receipts'), 1);
      expect(await _count(store, 'agenda_plan_audit'), 1);
      expect(await _count(store, 'agenda_undo'), 1);
    },
  );

  test(
    'same-version task patch and two block moves preserve omitted task fields',
    () async {
      final store = await _open();
      final seeded = await _seedTask(
        store,
        '合成保留字段任务',
        description: '留在本地的合成正文',
        note: '留在本地的合成备注',
        estimatedMinutes: 75,
        priority: TaskPriority.high,
        blocks: [
          _block(14, 1, 2, location: '原地点一', note: '原块备注一'),
          _block(14, 3, 4, location: '原地点二', note: '原块备注二'),
        ],
      );
      final initial = await store.localCalendar.taskDetail(seeded.reference);
      expect(
        initial.blocks.every(
          (block) => block.reference.version == initial.task.reference.version,
        ),
        isTrue,
      );
      final ticket = await _ticket(store);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();

      final plan = await planPort.prepareLocalPlan(ticket, context, revision, [
        AgentTaskPatch(initial.task.reference, title: '合成修改后标题'),
        AgentBlockPatch(
          initial.blocks[0].reference,
          startUtc: DateTime.utc(2026, 10, 14, 7),
          endUtc: DateTime.utc(2026, 10, 14, 8),
        ),
        AgentBlockPatch(
          initial.blocks[1].reference,
          startUtc: DateTime.utc(2026, 10, 14, 9),
          endUtc: DateTime.utc(2026, 10, 14, 10),
        ),
      ]);
      final receipt = await planPort.commitLocalPlan(
        await planPort.approveLocalPlan(plan),
      );

      final updatedTask = await _taskById(store, seeded.reference.localId);
      final updated = await store.localCalendar.taskDetail(
        updatedTask.reference,
      );
      final blocksById = {
        for (final block in updated.blocks)
          block.reference.identity.localId: block,
      };
      expect(receipt.committedCount, 3);
      expect(updated.task.draft.title, '合成修改后标题');
      expect(updated.task.draft.description, '留在本地的合成正文');
      expect(updated.task.draft.note, '留在本地的合成备注');
      expect(updated.task.draft.estimatedMinutes, 75);
      expect(updated.task.draft.priority, TaskPriority.high);
      expect(
        blocksById[initial.blocks[0].reference.identity.localId]!
            .draft
            .startsAtUtc,
        DateTime.utc(2026, 10, 14, 7),
      );
      expect(
        blocksById[initial.blocks[0].reference.identity.localId]!
            .draft
            .location,
        '原地点一',
      );
      expect(
        blocksById[initial.blocks[0].reference.identity.localId]!.draft.note,
        '原块备注一',
      );
      expect(
        blocksById[initial.blocks[1].reference.identity.localId]!
            .draft
            .startsAtUtc,
        DateTime.utc(2026, 10, 14, 9),
      );
      expect(
        blocksById[initial.blocks[1].reference.identity.localId]!.draft.note,
        '原块备注二',
      );
      expect((await planPort.readPlanContext()).$2, revision + 1);
    },
  );

  test(
    'one block can be moved twice from the same captured reference in one plan',
    () async {
      final store = await _open();
      final seeded = await _seedTask(
        store,
        '合成连续移动任务',
        blocks: [_block(14, 1, 2, location: '起点', note: '保留备注')],
      );
      final initial = await store.localCalendar.taskDetail(seeded.reference);
      final target = initial.blocks.single.reference;
      final ticket = await _ticket(store);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();

      final plan = await planPort.prepareLocalPlan(ticket, context, revision, [
        AgentCalendarChange(
          UpdatePlanBlock(
            target,
            _block(14, 5, 6, location: '中途地点', note: '中途备注'),
          ),
        ),
        AgentCalendarChange(
          UpdatePlanBlock(
            target,
            _block(14, 7, 8, location: '最终地点', note: '最终备注'),
          ),
        ),
      ]);
      final receipt = await planPort.commitLocalPlan(
        await planPort.approveLocalPlan(plan),
      );

      final updatedTask = await _taskById(store, seeded.reference.localId);
      final updated = await store.localCalendar.taskDetail(
        updatedTask.reference,
      );
      expect(receipt.committedCount, 2);
      expect(updated.blocks, hasLength(1));
      expect(updated.blocks.single.reference.identity, target.identity);
      expect(
        updated.blocks.single.draft.startsAtUtc,
        DateTime.utc(2026, 10, 14, 7),
      );
      expect(updated.blocks.single.draft.location, '最终地点');
      expect(updated.blocks.single.draft.note, '最终备注');
      expect((await planPort.readPlanContext()).$2, revision + 1);
    },
  );

  test(
    'deleting one block and updating its siblings keeps the task and siblings',
    () async {
      final store = await _open();
      final seeded = await _seedTask(
        store,
        '合成删块保留任务',
        blocks: [
          _block(14, 1, 2, note: '删除项'),
          _block(14, 3, 4, note: '更新项二'),
          _block(14, 5, 6, note: '更新项三'),
        ],
      );
      final initial = await store.localCalendar.taskDetail(seeded.reference);
      expect(
        initial.blocks.every(
          (block) => block.reference.version == initial.task.reference.version,
        ),
        isTrue,
      );
      final ticket = await _ticket(store);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();
      final removed = initial.blocks[0].reference;
      final movedSecond = initial.blocks[1].reference;
      final movedThird = initial.blocks[2].reference;

      final plan = await planPort.prepareLocalPlan(ticket, context, revision, [
        AgentCalendarChange(DeletePlanBlock(removed, confirmed: true)),
        AgentBlockPatch(
          movedSecond,
          startUtc: DateTime.utc(2026, 10, 14, 7),
          endUtc: DateTime.utc(2026, 10, 14, 8),
        ),
        AgentBlockPatch(
          movedThird,
          startUtc: DateTime.utc(2026, 10, 14, 9),
          endUtc: DateTime.utc(2026, 10, 14, 10),
        ),
      ]);
      final receipt = await planPort.commitLocalPlan(
        await planPort.approveLocalPlan(plan),
      );

      final currentTask = await _taskById(store, seeded.reference.localId);
      final updated = await store.localCalendar.taskDetail(
        currentTask.reference,
      );
      final ids = updated.blocks
          .map((block) => block.reference.identity)
          .toSet();
      expect(receipt.committedCount, 3);
      expect(updated.task.draft.title, '合成删块保留任务');
      expect(updated.blocks, hasLength(2));
      expect(ids, contains(movedSecond.identity));
      expect(ids, contains(movedThird.identity));
      expect(ids, isNot(contains(removed.identity)));
      expect(
        updated.blocks.map((block) => block.draft.startsAtUtc).toSet(),
        containsAll([
          DateTime.utc(2026, 10, 14, 7),
          DateTime.utc(2026, 10, 14, 9),
        ]),
      );
      expect((await planPort.readPlanContext()).$2, revision + 1);
    },
  );

  test(
    'two weekly occurrence status changes use one series baseline',
    () async {
      final store = await _open();
      final window = await store.localCalendar.query(_calendarQuery());
      final created = await _write(
        store,
        window.context,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: '合成每周复习',
            start: DateTime.utc(2026, 10, 13, 2),
            end: DateTime.utc(2026, 10, 13, 3),
            weekly: true,
            untilDay: DateTime.utc(2026, 10, 27),
          ),
        ),
      );
      final seriesId = created.target!.identity.localId;
      final before = await store.localCalendar.query(
        _calendarQuery(includeSkipped: true),
      );
      final occurrences = before.items
          .where((item) => item.reference.identity.localId == seriesId)
          .toList();
      expect(occurrences, hasLength(3));
      expect(
        occurrences.every(
          (item) =>
              item.reference.version == occurrences.first.reference.version,
        ),
        isTrue,
      );
      final ticket = await _ticket(store);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();

      final plan = await planPort.prepareLocalPlan(ticket, context, revision, [
        AgentCalendarChange(
          SetPersonalOccurrenceState(occurrences[0].reference, completed: true),
        ),
        AgentCalendarChange(
          SetPersonalOccurrenceState(occurrences[1].reference, skipped: true),
        ),
      ]);
      final receipt = await planPort.commitLocalPlan(
        await planPort.approveLocalPlan(plan),
      );

      final after = await store.localCalendar.query(
        _calendarQuery(includeSkipped: true),
      );
      final byOrdinal = {
        for (final item in after.items.where(
          (item) => item.reference.identity.localId == seriesId,
        ))
          item.reference.identity.ordinal: item,
      };
      expect(receipt.committedCount, 2);
      expect(
        byOrdinal[occurrences[0].reference.identity.ordinal]!.completed,
        isTrue,
      );
      expect(
        byOrdinal[occurrences[0].reference.identity.ordinal]!.skipped,
        isFalse,
      );
      expect(
        byOrdinal[occurrences[1].reference.identity.ordinal]!.completed,
        isFalse,
      );
      expect(
        byOrdinal[occurrences[1].reference.identity.ordinal]!.skipped,
        isTrue,
      );
      expect(
        byOrdinal[occurrences[2].reference.identity.ordinal]!.completed,
        isFalse,
      );
      expect(
        byOrdinal[occurrences[2].reference.identity.ordinal]!.skipped,
        isFalse,
      );
      expect((await planPort.readPlanContext()).$2, revision + 1);
    },
  );

  test(
    'preparing and rejecting a plan leave the current undo available',
    () async {
      final store = await _open();
      final priorUndo = await _seedUndo(store);
      final ticket = await _ticket(store);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();

      final plan = await planPort.prepareLocalPlan(ticket, context, revision, [
        const AgentCreateTask('rejected', TaskDraft(title: '不应写入的合成任务')),
      ]);
      _expectSameUndo(priorUndo, await store.localCalendar.queryUndo(context));
      await planPort.rejectLocalPlan(plan);

      _expectSameUndo(priorUndo, await store.localCalendar.queryUndo(context));
      expect((await planPort.readPlanContext()).$2, revision);
      expect(await _count(store, 'agenda_plan_receipts'), 0);
      expect(await _count(store, 'agenda_plan_audit'), 0);
      expect(
        (await store.localCalendar.queryTasks(
          const TaskQuery(filter: TaskFilter.all),
        )).items,
        isEmpty,
      );
    },
  );

  test(
    'same approval returns its receipt after finishRun without rewriting the plan',
    () async {
      final store = await _open();
      final ticket = await _ticket(store);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();
      final plan = await planPort.prepareLocalPlan(ticket, context, revision, [
        const AgentCreateTask('done', TaskDraft(title: '回执重放合成任务')),
        AgentDependentBlock('done', _block(14, 1, 2)),
      ]);
      final approval = await planPort.approveLocalPlan(plan);
      final first = await planPort.commitLocalPlan(approval);
      expect(first.replayed, isFalse);
      await store.agent.finishRun(ticket, AgentMessageStatus.complete);

      final replayed = await planPort.commitLocalPlan(approval);
      final task = await _taskByTitle(store, '回执重放合成任务');
      final detail = await store.localCalendar.taskDetail(task.reference);
      expect(replayed.replayed, isTrue);
      expect(replayed.planId, first.planId);
      expect(replayed.revision, first.revision);
      expect(replayed.committedCount, first.committedCount);
      expect((await planPort.readPlanContext()).$2, revision + 1);
      expect(detail.blocks, hasLength(1));
      expect(await _count(store, 'agenda_plan_receipts'), 1);
      expect(await _count(store, 'agenda_plan_audit'), 1);
      expect(await _count(store, 'agenda_undo'), 1);
    },
  );

  test('an approval object not issued by C3 cannot commit a plan', () async {
    final store = await _open();
    final ticket = await _ticket(store);
    final planPort = store.localCalendar as AgentLocalPlanPort;
    final (context, revision) = await planPort.readPlanContext();
    final plan = await planPort.prepareLocalPlan(ticket, context, revision, [
      const AgentCreateTask('forged', TaskDraft(title: '伪造批准不能写入')),
    ]);

    await _expectAgentFailure(
      planPort.commitLocalPlan(AgentPlanApproval(plan)),
      AgentFailureCode.staleContext,
    );
    expect((await planPort.readPlanContext()).$2, revision);
    expect(await _count(store, 'agenda_plan_receipts'), 0);
    expect(
      (await store.localCalendar.queryTasks(
        const TaskQuery(filter: TaskFilter.all),
      )).items,
      isEmpty,
    );
  });

  test('a prepared plan expires when the agenda revision changes', () async {
    final store = await _open();
    final ticket = await _ticket(store);
    final planPort = store.localCalendar as AgentLocalPlanPort;
    final (context, revision) = await planPort.readPlanContext();
    final plan = await planPort.prepareLocalPlan(ticket, context, revision, [
      const AgentCreateTask('stale', TaskDraft(title: '日程修订后不应提交')),
    ]);
    await store.customStatement(
      'UPDATE agenda_state SET revision=revision+1 WHERE singleton=1',
    );

    await _expectCalendarFailure(
      planPort.approveLocalPlan(plan),
      CalendarFailureCode.staleReference,
    );
    expect((await planPort.readPlanContext()).$2, revision + 1);
    expect(await _count(store, 'agenda_plan_receipts'), 0);
    expect(
      (await store.localCalendar.queryTasks(
        const TaskQuery(filter: TaskFilter.all),
      )).items,
      isEmpty,
    );
  });

  test(
    'a prepared plan expires when its planning preference revision changes',
    () async {
      final store = await _open();
      final ticket = await _ticket(store);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final preferences = store.agent as AgentPreferencesPort;
      final currentPreferences = await preferences.readPlanningPreferences();
      final (context, revision) = await planPort.readPlanContext();
      final plan = await planPort.prepareLocalPlan(ticket, context, revision, [
        const AgentCreateTask('stale-pref', TaskDraft(title: '偏好修订后不应提交')),
      ], preferencesRevision: currentPreferences.revision);
      await store.customStatement(
        'UPDATE agent_preferences SET revision=revision+1 WHERE singleton=1',
      );

      await _expectAgentFailure(
        planPort.approveLocalPlan(plan),
        AgentFailureCode.staleContext,
      );
      expect(await _count(store, 'agenda_plan_receipts'), 0);
      expect(
        (await store.localCalendar.queryTasks(
          const TaskQuery(filter: TaskFilter.all),
        )).items,
        isEmpty,
      );
    },
  );

  test(
    'unknown and deleted task dependencies are rejected during preparation',
    () async {
      final store = await _open();
      final ticket = await _ticket(store);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      var (context, revision) = await planPort.readPlanContext();

      await _expectCalendarFailure(
        planPort.prepareLocalPlan(ticket, context, revision, [
          AgentDependentBlock('unknown', _block(14, 1, 2)),
        ]),
        CalendarFailureCode.invalidInput,
      );

      final taskCreated = await _write(
        store,
        context,
        const CreateTask(TaskDraft(title: '待删除的合成父任务')),
      );
      final task = await _taskById(store, taskCreated.task!.localId);
      (context, revision) = await planPort.readPlanContext();
      await _expectCalendarFailure(
        planPort.prepareLocalPlan(ticket, context, revision, [
          AgentCalendarChange(DeleteTask(task.reference, confirmed: true)),
          AgentCalendarChange(
            CreatePlanBlock(task.reference, _block(14, 1, 2)),
          ),
        ]),
        CalendarFailureCode.invalidInput,
      );

      expect((await planPort.readPlanContext()).$2, revision);
      expect(await _count(store, 'agenda_plan_receipts'), 0);
      expect(
        (await store.localCalendar.taskDetail(task.reference)).blocks,
        isEmpty,
      );
      expect(
        (await store.localCalendar.queryTasks(
          const TaskQuery(filter: TaskFilter.all),
        )).items,
        hasLength(1),
      );
    },
  );

  test(
    'requireFree rejects an overlap even when those events are notConflict',
    () async {
      final store = await _open();
      var window = await store.localCalendar.query(_calendarQuery());
      final left = await _write(
        store,
        window.context,
        CreatePersonalEvent(_event('合成不冲突标记左项', 10, 11)),
      );
      final right = await _write(
        store,
        window.context,
        CreatePersonalEvent(_event('合成不冲突标记右项', 10, 11, minute: 30)),
      );
      window = await store.localCalendar.query(_calendarQuery());
      final leftCurrent = _item(window, left.target!.identity);
      final rightCurrent = _item(window, right.target!.identity);
      await _write(
        store,
        window.context,
        SaveCalendarRelation(
          left: leftCurrent.reference,
          right: rightCurrent.reference,
          kind: CalendarRelationKind.notConflict,
          note: '合成关系说明',
        ),
      );
      final taskCreated = await _write(
        store,
        window.context,
        const CreateTask(TaskDraft(title: '空档守卫合成任务')),
      );
      final task = await _taskById(store, taskCreated.task!.localId);
      final ticket = await _ticket(store);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();

      await _expectCalendarFailure(
        planPort.prepareLocalPlan(ticket, context, revision, [
          AgentCalendarChange(
            CreatePlanBlock(
              task.reference,
              PlanBlockDraft(
                startsAtUtc: DateTime.utc(2026, 10, 13, 10, 15),
                endsAtUtc: DateTime.utc(2026, 10, 13, 10, 45),
              ),
            ),
          ),
        ], requireFree: true),
        CalendarFailureCode.invalidInput,
      );

      expect((await planPort.readPlanContext()).$2, revision);
      expect(
        (await store.localCalendar.taskDetail(task.reference)).blocks,
        isEmpty,
      );
      expect(await _count(store, 'agenda_plan_receipts'), 0);
    },
  );

  test(
    'same-baseline personal patches preview their merged schedule safely',
    () async {
      final store = await _open();
      var window = await store.localCalendar.query(_calendarQuery());
      await _write(
        store,
        window.context,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: '合成调整目标',
            start: DateTime.utc(2026, 10, 13, 2), // Beijing 10:00
            end: DateTime.utc(2026, 10, 13, 3), // Beijing 11:00
            location: 'SYNTHETIC_PRIVATE_LOCATION',
            note: 'SYNTHETIC_PRIVATE_NOTE',
          ),
        ),
      );
      await _write(
        store,
        window.context,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: '合成邻近安排',
            start: DateTime.utc(2026, 10, 13, 1, 15), // Beijing 09:15
            end: DateTime.utc(2026, 10, 13, 1, 45), // Beijing 09:45
          ),
        ),
      );
      window = await store.localCalendar.query(_calendarQuery());
      final target = window.items.singleWhere((item) => item.title == '合成调整目标');
      final priorUndo = await store.localCalendar.queryUndo(window.context);
      final ticket = await _ticket(store);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();
      final changes = <AgentLocalChange>[
        AgentPersonalPatch(
          target.reference,
          entireSeries: true,
          start: DateTime.utc(2026, 10, 13, 1), // Beijing 09:00
        ),
        AgentPersonalPatch(
          target.reference,
          entireSeries: true,
          end: DateTime.utc(2026, 10, 13, 4), // Beijing 12:00
        ),
      ];

      await _expectCalendarFailure(
        planPort.prepareLocalPlan(
          ticket,
          context,
          revision,
          changes,
          requireFree: true,
        ),
        CalendarFailureCode.invalidInput,
      );

      expect((await planPort.readPlanContext()).$2, revision);
      expect(await _count(store, 'agenda_plan_receipts'), 0);
      expect(await _count(store, 'agenda_plan_audit'), 0);
      _expectSameUndo(priorUndo, await store.localCalendar.queryUndo(context));
      final unchanged = _item(
        await store.localCalendar.query(_calendarQuery()),
        target.reference.identity,
      );
      expect(unchanged.startsAtUtc, DateTime.utc(2026, 10, 13, 2));
      expect(unchanged.endsAtUtc, DateTime.utc(2026, 10, 13, 3));

      final plan = await planPort.prepareLocalPlan(
        ticket,
        context,
        revision,
        changes,
      );
      expect(plan.view.warning, contains('合成调整目标'));
      expect(plan.view.warning, contains('合成邻近安排'));
      expect(plan.view.warning, contains('2026-10-13 09:15—2026-10-13 09:45'));
      expect(plan.view.warning, isNot(contains('SYNTHETIC_PRIVATE_LOCATION')));
      expect(plan.view.warning, isNot(contains('SYNTHETIC_PRIVATE_NOTE')));
      expect(
        plan.view.details.join(' '),
        isNot(contains('SYNTHETIC_PRIVATE_LOCATION')),
      );
      expect(
        plan.view.details.join(' '),
        isNot(contains('SYNTHETIC_PRIVATE_NOTE')),
      );
      await store.agent.cancelRun(ticket);
    },
  );

  test(
    'an unrelated unbounded weekly series does not make a free plan partial',
    () async {
      final store = await _open();
      final window = await store.localCalendar.query(_calendarQuery());
      await _write(
        store,
        window.context,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: '合成无关无限每周安排',
            start: DateTime.utc(2026, 10, 13, 6), // Beijing 14:00
            end: DateTime.utc(2026, 10, 13, 7), // Beijing 15:00
            weekly: true,
          ),
        ),
      );
      final ticket = await _ticket(store);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();

      final plan = await planPort.prepareLocalPlan(ticket, context, revision, [
        AgentCalendarChange(
          CreatePersonalEvent(
            PersonalEventDraft(
              title: '合成31天内空闲安排',
              start: DateTime.utc(2026, 10, 13, 1), // Beijing 09:00
              end: DateTime.utc(2026, 10, 13, 2), // Beijing 10:00
            ),
          ),
        ),
      ], requireFree: true);

      expect(plan.view.warning, isNot(contains('预演覆盖不完整')));
      expect(plan.view.warning, contains('范围内未发现方案引起的定时冲突'));
      await store.agent.cancelRun(ticket);
    },
  );

  test(
    'Nth calendar checkpoint failure rolls back the group and preserves old undo',
    () async {
      late JwStore store;
      var failAt = 0;
      var calendarCalls = 0;
      store = await _open(
        onCalendarCheckpoint: () async {
          if (failAt > 0 && ++calendarCalls == failAt) {
            throw StateError('synthetic Nth calendar checkpoint failure');
          }
        },
      );
      final priorUndo = await _seedUndo(store);
      final ticket = await _ticket(store);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();
      final plan = await planPort.prepareLocalPlan(ticket, context, revision, [
        const AgentCreateTask('checkpoint', TaskDraft(title: '回滚检查任务')),
        AgentDependentBlock('checkpoint', _block(14, 1, 2)),
        AgentDependentBlock('checkpoint', _block(14, 3, 4)),
      ]);
      final approval = await planPort.approveLocalPlan(plan);
      calendarCalls = 0;
      failAt = 2;

      await expectLater(
        planPort.commitLocalPlan(approval),
        throwsA(
          isA<CalendarFailure>().having(
            (failure) => failure.code,
            'code',
            CalendarFailureCode.storageFailed,
          ),
        ),
      );

      expect((await planPort.readPlanContext()).$2, revision);
      expect(await _count(store, 'local_tasks'), 0);
      expect(await _count(store, 'local_plan_blocks'), 0);
      expect(await _count(store, 'agenda_plan_receipts'), 0);
      expect(await _count(store, 'agenda_plan_audit'), 0);
      expect(await _count(store, 'agenda_undo'), 1);
      _expectSameUndo(priorUndo, await store.localCalendar.queryUndo(context));
    },
  );

  test(
    'final agent checkpoint failure rolls back a fully applied group',
    () async {
      late JwStore store;
      var failFinalCheckpoint = false;
      store = await _open(
        onAgentCheckpoint: () async {
          if (failFinalCheckpoint) {
            throw StateError('synthetic final agent checkpoint failure');
          }
        },
      );
      final priorUndo = await _seedUndo(store);
      final ticket = await _ticket(store);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();
      final plan = await planPort.prepareLocalPlan(ticket, context, revision, [
        const AgentCreateTask('final-checkpoint', TaskDraft(title: '最终检查任务')),
        AgentDependentBlock('final-checkpoint', _block(14, 1, 2)),
      ]);
      final approval = await planPort.approveLocalPlan(plan);
      failFinalCheckpoint = true;

      await expectLater(
        planPort.commitLocalPlan(approval),
        throwsA(
          isA<CalendarFailure>().having(
            (failure) => failure.code,
            'code',
            CalendarFailureCode.storageFailed,
          ),
        ),
      );

      expect((await planPort.readPlanContext()).$2, revision);
      expect(await _count(store, 'local_tasks'), 0);
      expect(await _count(store, 'local_plan_blocks'), 0);
      expect(await _count(store, 'agenda_plan_receipts'), 0);
      expect(await _count(store, 'agenda_plan_audit'), 0);
      expect(await _count(store, 'agenda_undo'), 1);
      _expectSameUndo(priorUndo, await store.localCalendar.queryUndo(context));
    },
  );

  test(
    'synchronous stop at an Nth calendar checkpoint rolls back every step',
    () async {
      late JwStore store;
      late AgentRunTicket ticket;
      var revokeOnCheckpoint = false;
      var calendarCalls = 0;
      store = await _open(
        onCalendarCheckpoint: () async {
          if (revokeOnCheckpoint && ++calendarCalls == 2) {
            store.localCalendar.revokeLocalPlans(ticket);
          }
        },
      );
      final priorUndo = await _seedUndo(store);
      ticket = await _ticket(store);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();
      final plan = await planPort.prepareLocalPlan(ticket, context, revision, [
        const AgentCreateTask('stopped-midway', TaskDraft(title: '中途停止任务')),
        AgentDependentBlock('stopped-midway', _block(14, 1, 2)),
        AgentDependentBlock('stopped-midway', _block(14, 3, 4)),
      ]);
      final approval = await planPort.approveLocalPlan(plan);
      calendarCalls = 0;
      revokeOnCheckpoint = true;

      await _expectAgentFailure(
        planPort.commitLocalPlan(approval),
        AgentFailureCode.staleContext,
      );

      expect((await planPort.readPlanContext()).$2, revision);
      expect(await _count(store, 'local_tasks'), 0);
      expect(await _count(store, 'local_plan_blocks'), 0);
      expect(await _count(store, 'agenda_plan_receipts'), 0);
      expect(await _count(store, 'agenda_plan_audit'), 0);
      _expectSameUndo(priorUndo, await store.localCalendar.queryUndo(context));
    },
  );

  test(
    'synchronous stop at the final agent checkpoint rolls back the group undo too',
    () async {
      late JwStore store;
      late AgentRunTicket ticket;
      var revokeAtFinalCheckpoint = false;
      store = await _open(
        onAgentCheckpoint: () async {
          if (revokeAtFinalCheckpoint) {
            store.localCalendar.revokeLocalPlans(ticket);
          }
        },
      );
      final priorUndo = await _seedUndo(store);
      ticket = await _ticket(store);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();
      final plan = await planPort.prepareLocalPlan(ticket, context, revision, [
        const AgentCreateTask('stopped-final', TaskDraft(title: '最终停止任务')),
        AgentDependentBlock('stopped-final', _block(14, 1, 2)),
      ]);
      final approval = await planPort.approveLocalPlan(plan);
      revokeAtFinalCheckpoint = true;

      await _expectAgentFailure(
        planPort.commitLocalPlan(approval),
        AgentFailureCode.staleContext,
      );

      expect((await planPort.readPlanContext()).$2, revision);
      expect(await _count(store, 'local_tasks'), 0);
      expect(await _count(store, 'local_plan_blocks'), 0);
      expect(await _count(store, 'agenda_plan_receipts'), 0);
      expect(await _count(store, 'agenda_plan_audit'), 0);
      expect(await _count(store, 'agenda_undo'), 1);
      _expectSameUndo(priorUndo, await store.localCalendar.queryUndo(context));
    },
  );

  test(
    'stop before commit prevents a plan write and preserves old undo',
    () async {
      final store = await _open();
      final priorUndo = await _seedUndo(store);
      final ticket = await _ticket(store);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();
      final plan = await planPort.prepareLocalPlan(ticket, context, revision, [
        const AgentCreateTask('stop-first', TaskDraft(title: '停止先到')),
      ]);
      final approval = await planPort.approveLocalPlan(plan);
      planPort.revokeLocalPlans(ticket);

      await _expectAgentFailure(
        planPort.commitLocalPlan(approval),
        AgentFailureCode.staleContext,
      );
      expect((await planPort.readPlanContext()).$2, revision);
      expect(await _count(store, 'local_tasks'), 0);
      expect(await _count(store, 'agenda_plan_receipts'), 0);
      _expectSameUndo(priorUndo, await store.localCalendar.queryUndo(context));
    },
  );

  test(
    'stop after commit leaves the committed receipt and group undo intact',
    () async {
      final store = await _open();
      final priorUndo = await _seedUndo(store);
      final ticket = await _ticket(store);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();
      final plan = await planPort.prepareLocalPlan(ticket, context, revision, [
        const AgentCreateTask('stop-last', TaskDraft(title: '提交先到')),
      ]);
      final approval = await planPort.approveLocalPlan(plan);
      final committed = await planPort.commitLocalPlan(approval);
      planPort.revokeLocalPlans(ticket);

      final replayed = await planPort.commitLocalPlan(approval);
      final currentUndo = await store.localCalendar.queryUndo(context);
      expect(committed.replayed, isFalse);
      expect(replayed.replayed, isTrue);
      expect(replayed.planId, committed.planId);
      expect((await planPort.readPlanContext()).$2, revision + 1);
      expect(await _count(store, 'local_tasks'), 1);
      expect(await _count(store, 'agenda_plan_receipts'), 1);
      expect(await _count(store, 'agenda_plan_audit'), 1);
      expect(await _count(store, 'agenda_undo'), 1);
      expect(currentUndo.canUndo, isTrue);
      expect(currentUndo.reference!.undoId, committed.undo!.undoId);
      expect(currentUndo.reference!.undoId, isNot(priorUndo.reference!.undoId));
    },
  );
}

Future<JwStore> _open({
  Future<void> Function()? onCalendarCheckpoint,
  Future<void> Function()? onAgentCheckpoint,
}) async {
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _TestOwnership(),
    clock: _clock,
    modelCredentialProtector: _SyntheticProtector(),
    onCalendarCheckpoint: onCalendarCheckpoint,
    onAgentCheckpoint: onAgentCheckpoint,
  );
  addTearDown(store.close);
  await store.initialize();
  await store.agent.initializeAgent();
  await _configure(store);
  return store;
}

Future<AgentSettingsSnapshot> _configure(JwStore store) async {
  final settings = await store.agent.inspectAgent();
  await store.agent.saveModelConfiguration(
    settings.authority,
    modelId: 'synthetic-plan-model',
    modelIds: const ['synthetic-plan-model'],
    report: const AgentCapabilityReport(text: true, streaming: true),
    consent: true,
    key: _key,
  );
  return store.agent.inspectAgent();
}

Future<AgentRunTicket> _ticket(
  JwStore store, {
  String question = '仅用于本地合成计划回归',
}) async {
  final settings = await store.agent.inspectAgent();
  final conversation = await store.agent.createConversation();
  return store.agent.beginRun(settings.authority, conversation, question);
}

Future<TaskRecord> _seedTask(
  JwStore store,
  String title, {
  String description = '',
  String note = '',
  int? estimatedMinutes,
  TaskPriority priority = TaskPriority.normal,
  List<PlanBlockDraft> blocks = const [],
}) async {
  final (context, _) = await (store.localCalendar as AgentLocalPlanPort)
      .readPlanContext();
  final created = await _write(
    store,
    context,
    CreateTask(
      TaskDraft(
        title: title,
        description: description,
        note: note,
        estimatedMinutes: estimatedMinutes,
        priority: priority,
      ),
    ),
  );
  final taskId = created.task!.localId;
  for (final draft in blocks) {
    final current = await _taskById(store, taskId);
    await _write(
      store,
      current.reference.context,
      CreatePlanBlock(current.reference, draft),
    );
  }
  return _taskById(store, taskId);
}

Future<TaskRecord> _taskById(JwStore store, int localId) async =>
    (await store.localCalendar.queryTasks(
      const TaskQuery(filter: TaskFilter.all),
    )).items.singleWhere((task) => task.reference.localId == localId);

Future<TaskRecord> _taskByTitle(JwStore store, String title) async =>
    (await store.localCalendar.queryTasks(
      const TaskQuery(filter: TaskFilter.all),
    )).items.singleWhere((task) => task.draft.title == title);

Future<CalendarUndoView> _seedUndo(JwStore store) async {
  final (context, _) = await (store.localCalendar as AgentLocalPlanPort)
      .readPlanContext();
  await _write(
    store,
    context,
    CreatePersonalEvent(_event('保留的合成Undo槽', 10, 11)),
  );
  return store.localCalendar.queryUndo(context);
}

CalendarQuery _calendarQuery({bool includeSkipped = false}) => CalendarQuery(
  firstDay: DateTime.utc(2026, 10, 12),
  endDayExclusive: DateTime.utc(2026, 10, 30),
  includeSkipped: includeSkipped,
  filter: CalendarFilter.all,
);

PersonalEventDraft _event(
  String title,
  int startHour,
  int endHour, {
  int minute = 0,
}) => PersonalEventDraft(
  title: title,
  start: DateTime.utc(2026, 10, 13, startHour, minute),
  end: DateTime.utc(2026, 10, 13, endHour, minute),
);

PlanBlockDraft _block(
  int day,
  int startHour,
  int endHour, {
  String location = '',
  String note = '',
}) => PlanBlockDraft(
  startsAtUtc: DateTime.utc(2026, 10, day, startHour),
  endsAtUtc: DateTime.utc(2026, 10, day, endHour),
  location: location,
  note: note,
);

Future<CalendarWriteReceipt> _write(
  JwStore store,
  CalendarContext context,
  CalendarIntent intent,
) async {
  final prepared = await store.localCalendar.prepare(context, intent);
  return store.localCalendar.commit(prepared);
}

CalendarOccurrence _item(CalendarWindow window, CalendarIdentity identity) =>
    window.items.singleWhere((item) => item.reference.identity == identity);

Future<int> _count(JwStore store, String table) async =>
    (await store
            .customSelect('SELECT COUNT(*) AS count FROM $table')
            .getSingle())
        .read<int>('count');

void _expectSameUndo(CalendarUndoView expected, CalendarUndoView actual) {
  expect(actual.canUndo, isTrue);
  expect(actual.reference!.undoId, expected.reference!.undoId);
}

Future<void> _expectCalendarFailure(
  Future<dynamic> call,
  CalendarFailureCode code,
) => expectLater(
  call,
  throwsA(
    isA<CalendarFailure>().having((failure) => failure.code, 'code', code),
  ),
);

Future<void> _expectAgentFailure(Future<dynamic> call, AgentFailureCode code) =>
    expectLater(
      call,
      throwsA(
        isA<AgentFailure>().having((failure) => failure.code, 'code', code),
      ),
    );

final class _SyntheticProtector implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-agent-plan-protector/v1';

  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async =>
      Uint8List.fromList([0xA7, ...plaintext.map((byte) => byte ^ 0x5A)]);

  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) async => Uint8List.fromList(
    ciphertext.skip(1).map((byte) => byte ^ 0x5A).toList(),
  );
}

final class _TestOwnership implements AssetOwnership {
  @override
  bool get isHeld => true;

  @override
  void ensureHeld() {}
}
