import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

final _day = DateTime.utc(2026, 10, 12);
final _fixedClock = FixedClock(DateTime.utc(2026, 10, 12, 12));

void main() {
  test(
    'task and block inverses restore owned fields and keep versions moving forward',
    () async {
      final store = await _open();
      final context = await _context(store);
      final created = await _write(
        store,
        context,
        const CreateTask(
          TaskDraft(
            title: '可撤销任务',
            description: '原描述',
            note: '原备注',
            estimatedMinutes: 60,
            priority: TaskPriority.high,
          ),
        ),
      );
      final taskId = created.task!.localId;
      var task = await _task(store, taskId);
      await _write(
        store,
        context,
        UpdateTask(
          task.reference,
          TaskDraft(
            title: '已改名',
            description: '新描述',
            note: '新备注',
            deadlineAtUtc: DateTime.utc(2026, 10, 13, 15, 59),
            estimatedMinutes: 120,
            priority: TaskPriority.low,
          ),
        ),
      );
      final updated = await _task(store, taskId);
      expect(updated.draft.title, '已改名');
      await _undo(store, context);
      task = await _task(store, taskId);
      expect(
        task.draft.canonical,
        const TaskDraft(
          title: '可撤销任务',
          description: '原描述',
          note: '原备注',
          estimatedMinutes: 60,
          priority: TaskPriority.high,
        ).canonical,
      );
      expect(task.reference.version, greaterThan(updated.reference.version));
      await _write(
        store,
        context,
        SetTaskStatus(task.reference, TaskStatus.cancelled),
      );
      expect((await _task(store, taskId)).status, TaskStatus.cancelled);
      await _undo(store, context);
      task = await _task(store, taskId);
      expect(task.status, TaskStatus.active);
      final block = await _write(
        store,
        context,
        CreatePlanBlock(
          task.reference,
          _block(
            starts: DateTime.utc(2026, 10, 12, 1),
            ends: DateTime.utc(2026, 10, 12, 2),
            location: '原地点',
            note: '原块备注',
          ),
        ),
      );
      task = await _task(store, taskId);
      var detail = await store.localCalendar.taskDetail(task.reference);
      await _write(
        store,
        context,
        SetPlanBlockStatus(
          detail.blocks.single.reference,
          PlanBlockStatus.done,
        ),
      );
      await _undo(store, context);
      task = await _task(store, taskId);
      detail = await store.localCalendar.taskDetail(task.reference);
      expect(detail.blocks.single.status, PlanBlockStatus.planned);
      await _write(
        store,
        context,
        UpdatePlanBlock(
          detail.blocks.single.reference,
          _block(
            starts: DateTime.utc(2026, 10, 13, 3),
            ends: DateTime.utc(2026, 10, 13, 4),
            location: '新地点',
            note: '新块备注',
          ),
        ),
      );
      await _undo(store, context);
      task = await _task(store, taskId);
      detail = await store.localCalendar.taskDetail(task.reference);
      expect(detail.blocks.single.reference.identity, block.target!.identity);
      expect(
        detail.blocks.single.draft.canonical,
        _block(
          starts: DateTime.utc(2026, 10, 12, 1),
          ends: DateTime.utc(2026, 10, 12, 2),
          location: '原地点',
          note: '原块备注',
        ).canonical,
      );
      await _write(
        store,
        context,
        DeletePlanBlock(detail.blocks.single.reference, confirmed: true),
      );
      expect(
        (await store.localCalendar.taskDetail(
          (await _task(store, taskId)).reference,
        )).blocks,
        isEmpty,
      );
      await _undo(store, context);
      task = await _task(store, taskId);
      detail = await store.localCalendar.taskDetail(task.reference);
      expect(detail.blocks.single.reference.identity, block.target!.identity);
      final extra = await _write(
        store,
        context,
        CreatePlanBlock(
          task.reference,
          _block(
            starts: DateTime.utc(2026, 10, 12, 5),
            ends: DateTime.utc(2026, 10, 12, 6),
          ),
        ),
      );
      await _undo(store, context);
      task = await _task(store, taskId);
      detail = await store.localCalendar.taskDetail(task.reference);
      expect(
        detail.blocks.map((b) => b.reference.identity),
        isNot(contains(extra.target!.identity)),
      );
      final disposable = await _write(
        store,
        context,
        const CreateTask(TaskDraft(title: '撤销创建')),
      );
      await _undo(store, context);
      final remaining = await store.localCalendar.queryTasks(
        const TaskQuery(filter: TaskFilter.all),
      );
      expect(
        remaining.items.map((t) => t.reference.localId),
        isNot(contains(disposable.task!.localId)),
      );
      expect(remaining.items.single.reference.localId, taskId);
    },
  );
  test(
    'tasks are standalone and task fields and planning states remain independent',
    () async {
      final store = await _open();
      final context = await _context(store);
      expect((await store.readAuthority()).accountBound, isFalse);

      final firstDraft = TaskDraft(
        title: '合成任务原名',
        description: '合成任务描述',
        note: '合成任务备注',
        deadlineAtUtc: DateTime.utc(2026, 10, 13, 16, 30),
        estimatedMinutes: 90,
        priority: TaskPriority.high,
      );
      final created = await _write(store, context, CreateTask(firstDraft));
      final taskId = created.task!.localId;
      var task = await _task(store, taskId);
      expect(task.draft.title, '合成任务原名');
      expect(task.draft.description, '合成任务描述');
      expect(task.draft.note, '合成任务备注');
      expect(task.draft.deadlineAtUtc, DateTime.utc(2026, 10, 13, 16, 30));
      expect(task.draft.estimatedMinutes, 90);
      expect(task.draft.priority, TaskPriority.high);
      expect(task.status, TaskStatus.active);

      final editedDraft = TaskDraft(
        title: '合成任务全量编辑',
        description: '替换后的描述',
        note: '替换后的备注',
        deadlineAtUtc: DateTime.utc(2026, 10, 14, 17, 45),
        estimatedMinutes: 125,
        priority: TaskPriority.low,
      );
      final edited = await _write(
        store,
        context,
        UpdateTask(task.reference, editedDraft),
      );
      task = await _task(store, taskId);
      expect(task.reference.version, created.task!.version + 1);
      expect(task.draft.title, '合成任务全量编辑');
      expect(task.draft.description, '替换后的描述');
      expect(task.draft.note, '替换后的备注');
      expect(task.draft.deadlineAtUtc, DateTime.utc(2026, 10, 14, 17, 45));
      expect(task.draft.estimatedMinutes, 125);
      expect(task.draft.priority, TaskPriority.low);
      expect(edited.task!.canonical, task.reference.canonical);

      final pastBlock = await _write(
        store,
        context,
        CreatePlanBlock(
          task.reference,
          _block(
            starts: DateTime.utc(2026, 10, 12, 9),
            ends: DateTime.utc(2026, 10, 12, 11),
            location: '合成地点一',
          ),
        ),
      );
      task = await _task(store, taskId);
      final futureBlock = await _write(
        store,
        context,
        CreatePlanBlock(
          task.reference,
          _block(
            starts: DateTime.utc(2026, 10, 12, 14),
            ends: DateTime.utc(2026, 10, 12, 15),
            location: '合成地点二',
          ),
        ),
      );
      task = await _task(store, taskId);
      expect(task.reference.version, created.task!.version + 3);
      expect(task.blockCount, 2);

      var detail = await store.localCalendar.taskDetail(task.reference);
      expect(detail.nowUtc, _fixedClock.nowUtc);
      expect(detail.blocks, hasLength(2));
      final pastRecord = detail.blocks.singleWhere(
        (block) => block.reference.identity == pastBlock.target!.identity,
      );
      final futureRecord = detail.blocks.singleWhere(
        (block) => block.reference.identity == futureBlock.target!.identity,
      );
      expect(pastRecord.status, PlanBlockStatus.planned);
      expect(pastRecord.awaitingReview(detail.nowUtc), isTrue);
      expect(futureRecord.status, PlanBlockStatus.planned);
      expect(futureRecord.awaitingReview(detail.nowUtc), isFalse);
      expect(task.status, TaskStatus.active);

      await _write(
        store,
        context,
        SetTaskStatus(task.reference, TaskStatus.completed),
      );
      task = await _task(store, taskId);
      detail = await store.localCalendar.taskDetail(task.reference);
      expect(task.status, TaskStatus.completed);
      expect(
        detail.blocks.map((block) => block.status),
        everyElement(PlanBlockStatus.planned),
      );
      expect(
        detail.blocks.map((block) => block.taskStatus),
        everyElement(TaskStatus.completed),
      );

      final firstBlock = detail.blocks.singleWhere(
        (block) => block.reference.identity == pastBlock.target!.identity,
      );
      await _write(
        store,
        context,
        SetPlanBlockStatus(firstBlock.reference, PlanBlockStatus.done),
      );
      task = await _task(store, taskId);
      detail = await store.localCalendar.taskDetail(task.reference);
      expect(task.status, TaskStatus.completed);
      expect(
        detail.blocks
            .singleWhere(
              (block) => block.reference.identity == pastBlock.target!.identity,
            )
            .status,
        PlanBlockStatus.done,
      );
      expect(
        detail.blocks
            .singleWhere(
              (block) =>
                  block.reference.identity == futureBlock.target!.identity,
            )
            .status,
        PlanBlockStatus.planned,
      );
    },
  );

  test(
    'stale task and sibling forms reject, while moving a block keeps its identity in day and week projections',
    () async {
      final store = await _open();
      final context = await _context(store);
      final personal = await _write(
        store,
        context,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: '合成跨午夜重叠',
            start: DateTime.utc(2026, 10, 13, 16),
            end: DateTime.utc(2026, 10, 13, 16, 15),
          ),
        ),
      );
      final created = await _write(
        store,
        context,
        const CreateTask(TaskDraft(title: '合成旧表单任务')),
      );
      final taskId = created.task!.localId;
      await _write(
        store,
        context,
        CreatePlanBlock(
          created.task!,
          _block(
            starts: DateTime.utc(2026, 10, 12, 1),
            ends: DateTime.utc(2026, 10, 12, 2),
          ),
        ),
      );
      var task = await _task(store, taskId);
      final staleTaskForm = task.reference;
      await _write(
        store,
        context,
        CreatePlanBlock(
          task.reference,
          _block(
            starts: DateTime.utc(2026, 10, 12, 3),
            ends: DateTime.utc(2026, 10, 12, 4),
          ),
        ),
      );
      task = await _task(store, taskId);
      await _failure(
        _write(
          store,
          context,
          UpdateTask(staleTaskForm, const TaskDraft(title: '旧任务表单')),
        ),
        CalendarFailureCode.staleReference,
      );

      var detail = await store.localCalendar.taskDetail(task.reference);
      final initialBlocks = detail.blocks;
      expect(initialBlocks, hasLength(2));
      expect(initialBlocks.map((block) => block.reference.version).toSet(), {
        task.reference.version,
      });
      final movingId = initialBlocks.first.reference.identity;
      final siblingOldReference = initialBlocks.last.reference;
      await _write(
        store,
        context,
        UpdatePlanBlock(
          initialBlocks.first.reference,
          _block(
            starts: DateTime.utc(2026, 10, 13, 15, 30),
            ends: DateTime.utc(2026, 10, 13, 16, 30),
            location: '合成跨日新地点',
            note: '移动保留原块身份',
          ),
        ),
      );
      await _failure(
        _write(
          store,
          context,
          UpdatePlanBlock(
            siblingOldReference,
            _block(
              starts: DateTime.utc(2026, 10, 12, 5),
              ends: DateTime.utc(2026, 10, 12, 6),
            ),
          ),
        ),
        CalendarFailureCode.staleReference,
      );

      task = await _task(store, taskId);
      detail = await store.localCalendar.taskDetail(task.reference);
      final moved = detail.blocks.singleWhere(
        (block) => block.reference.identity == movingId,
      );
      expect(moved.reference.identity, movingId);
      expect(moved.draft.startsAtUtc, DateTime.utc(2026, 10, 13, 15, 30));
      expect(moved.draft.endsAtUtc, DateTime.utc(2026, 10, 13, 16, 30));
      expect(moved.reference.version, task.reference.version);
      expect(
        detail.blocks
            .singleWhere(
              (block) =>
                  block.reference.identity == siblingOldReference.identity,
            )
            .reference
            .version,
        task.reference.version,
      );

      final priorDay = await store.localCalendar.query(
        _calendarQuery(
          firstDay: DateTime.utc(2026, 10, 13),
          endDayExclusive: DateTime.utc(2026, 10, 14),
        ),
      );
      final nextDay = await store.localCalendar.query(
        _calendarQuery(
          firstDay: DateTime.utc(2026, 10, 14),
          endDayExclusive: DateTime.utc(2026, 10, 15),
        ),
      );
      expect(
        _blocksFor(priorDay, taskId).map((block) => block.reference.identity),
        contains(movingId),
      );
      expect(
        _blocksFor(nextDay, taskId).map((block) => block.reference.identity),
        contains(movingId),
      );
      expect(
        nextDay.items
            .singleWhere(
              (item) => item.reference.identity == personal.target!.identity,
            )
            .title,
        '合成跨午夜重叠',
      );

      final week = await store.localCalendar.query(
        _calendarQuery(
          firstDay: _day,
          endDayExclusive: _day.add(const Duration(days: 7)),
        ),
      );
      final relatedConflict = week.conflicts.singleWhere(
        (conflict) =>
            {
              conflict.left.reference.identity,
              conflict.right.reference.identity,
            }.contains(movingId) &&
            {
              conflict.left.reference.identity,
              conflict.right.reference.identity,
            }.contains(personal.target!.identity),
      );
      expect(relatedConflict.status, CalendarConflictStatus.conflict);
      expect(relatedConflict.hasExplicitDecision, isFalse);
    },
  );

  test(
    'parent deletion leaves children hidden and one-shot undo restores only live blocks',
    () async {
      final store = await _open();
      final context = await _context(store);
      final created = await _write(
        store,
        context,
        const CreateTask(TaskDraft(title: '合成父删除')),
      );
      final taskId = created.task!.localId;
      await _write(
        store,
        context,
        CreatePlanBlock(
          created.task!,
          _block(
            starts: DateTime.utc(2026, 10, 12, 1),
            ends: DateTime.utc(2026, 10, 12, 2),
          ),
        ),
      );
      var task = await _task(store, taskId);
      final removable = await _write(
        store,
        context,
        CreatePlanBlock(
          task.reference,
          _block(
            starts: DateTime.utc(2026, 10, 12, 3),
            ends: DateTime.utc(2026, 10, 12, 4),
          ),
        ),
      );
      task = await _task(store, taskId);
      var detail = await store.localCalendar.taskDetail(task.reference);
      final liveBlock = detail.blocks.singleWhere(
        (block) => block.reference.identity != removable.target!.identity,
      );
      await _write(
        store,
        context,
        SetPlanBlockStatus(liveBlock.reference, PlanBlockStatus.skipped),
      );
      task = await _task(store, taskId);
      detail = await store.localCalendar.taskDetail(task.reference);
      final removableCurrent = detail.blocks.singleWhere(
        (block) => block.reference.identity == removable.target!.identity,
      );
      await _write(
        store,
        context,
        DeletePlanBlock(removableCurrent.reference, confirmed: true),
      );
      task = await _task(store, taskId);
      final beforeDelete = await store.localCalendar.taskDetail(task.reference);
      expect(beforeDelete.blocks.map((block) => block.reference.identity), [
        liveBlock.reference.identity,
      ]);

      final deletion = await _write(
        store,
        context,
        DeleteTask(task.reference, confirmed: true),
      );
      final deletedProjection = await store.localCalendar.query(
        _calendarQuery(includeSkipped: true),
      );
      expect(_blocksFor(deletedProjection, taskId), isEmpty);
      expect(deletion.task!.version, task.reference.version + 1);

      final undoView = await store.localCalendar.queryUndo(context);
      expect(undoView.canUndo, isTrue);
      final undoCommand = await store.localCalendar.prepare(
        context,
        UndoCalendarWrite(undoView.reference!),
      );
      final undoReceipt = await store.localCalendar.commit(undoCommand);
      expect(undoReceipt.replayed, isFalse);

      task = await _task(store, taskId);
      detail = await store.localCalendar.taskDetail(task.reference);
      expect(task.draft.title, '合成父删除');
      expect(task.reference.version, greaterThan(deletion.task!.version));
      expect(detail.blocks, hasLength(1));
      expect(
        detail.blocks.single.reference.identity,
        liveBlock.reference.identity,
      );
      expect(detail.blocks.single.status, PlanBlockStatus.skipped);
      expect(
        (await store.localCalendar.query(_calendarQuery())).items.where(
          (item) =>
              item.reference.identity.kind == CalendarKind.planBlock &&
              item.task?.localId == taskId,
        ),
        isEmpty,
      );
      final restoredProjection = await store.localCalendar.query(
        _calendarQuery(includeSkipped: true),
      );
      final restoredBlocks = _blocksFor(restoredProjection, taskId);
      expect(restoredBlocks, hasLength(1));
      expect(
        restoredBlocks.single.reference.identity,
        liveBlock.reference.identity,
      );
      expect(restoredBlocks.single.planBlockStatus, PlanBlockStatus.skipped);

      final afterUndoVersion = task.reference.version;
      final replay = await store.localCalendar.commit(undoCommand);
      expect(replay.replayed, isTrue);
      expect((await _task(store, taskId)).reference.version, afterUndoVersion);
      await _failure(
        _write(store, context, UndoCalendarWrite(undoView.reference!)),
        CalendarFailureCode.undoUnavailable,
      );
      await _failure(
        _write(
          store,
          context,
          UpdateTask(deletion.task!, const TaskDraft(title: '旧任务版本')),
        ),
        CalendarFailureCode.staleReference,
      );
    },
  );

  test(
    'relation writes guard both aggregates and a replaced undo slot is unavailable',
    () async {
      final store = await _open();
      final context = await _context(store);
      final created = await _write(
        store,
        context,
        const CreateTask(TaskDraft(title: '合成关系任务')),
      );
      final taskId = created.task!.localId;
      await _write(
        store,
        context,
        CreatePlanBlock(
          created.task!,
          _block(
            starts: DateTime.utc(2026, 10, 12, 1),
            ends: DateTime.utc(2026, 10, 12, 2),
          ),
        ),
      );
      var task = await _task(store, taskId);
      final personal = await _write(
        store,
        context,
        CreatePersonalEvent(
          PersonalEventDraft(
            title: '合成关系个人安排',
            start: DateTime.utc(2026, 10, 12, 1, 15),
            end: DateTime.utc(2026, 10, 12, 1, 45),
          ),
        ),
      );
      var detail = await store.localCalendar.taskDetail(task.reference);
      final blockBeforePrepare = detail.blocks.single;
      final pendingRelation = await store.localCalendar.prepare(
        context,
        SaveCalendarRelation(
          left: blockBeforePrepare.reference,
          right: personal.target!,
          kind: CalendarRelationKind.notConflict,
          note: '合成关系说明',
        ),
      );
      await _write(
        store,
        context,
        SetPlanBlockStatus(blockBeforePrepare.reference, PlanBlockStatus.done),
      );
      await _failure(
        store.localCalendar.commit(pendingRelation),
        CalendarFailureCode.staleReference,
      );
      task = await _task(store, taskId);
      detail = await store.localCalendar.taskDetail(task.reference);
      var block = detail.blocks.single;
      var personalDetail = await store.localCalendar.detail(personal.target!);
      expect(personalDetail.relations, isEmpty);
      expect(
        (await store.localCalendar.detail(block.reference)).relations,
        isEmpty,
      );

      final taskVersionBeforeRelation = task.reference.version;
      final saved = await _write(
        store,
        context,
        SaveCalendarRelation(
          left: block.reference,
          right: personal.target!,
          kind: CalendarRelationKind.notConflict,
          note: '合成关系说明',
        ),
      );
      task = await _task(store, taskId);
      expect(task.reference.version, taskVersionBeforeRelation + 1);
      expect(saved.relation, isNotNull);
      await _failure(
        store.localCalendar.detail(personal.target!),
        CalendarFailureCode.staleReference,
      );

      final relationUndoView = await store.localCalendar.queryUndo(context);
      expect(relationUndoView.canUndo, isTrue);
      final relationUndo = await store.localCalendar.prepare(
        context,
        UndoCalendarWrite(relationUndoView.reference!),
      );
      final beforeUndoVersion = task.reference.version;
      await store.localCalendar.commit(relationUndo);
      task = await _task(store, taskId);
      expect(task.reference.version, beforeUndoVersion + 1);
      detail = await store.localCalendar.taskDetail(task.reference);
      block = detail.blocks.single;
      final currentCalendar = await store.localCalendar.query(_calendarQuery());
      final currentPersonal = currentCalendar.items.singleWhere(
        (item) => item.reference.identity == personal.target!.identity,
      );
      expect(
        (await store.localCalendar.detail(block.reference)).relations,
        isEmpty,
      );
      expect(
        (await store.localCalendar.detail(currentPersonal.reference)).relations,
        isEmpty,
      );

      await _write(
        store,
        context,
        SaveCalendarRelation(
          left: block.reference,
          right: currentPersonal.reference,
          kind: CalendarRelationKind.conflict,
          note: '第二次合成关系',
        ),
      );
      final replacedUndoView = await store.localCalendar.queryUndo(context);
      expect(replacedUndoView.canUndo, isTrue);
      final replacedUndo = replacedUndoView.reference!;
      task = await _task(store, taskId);
      await _write(
        store,
        context,
        SetTaskStatus(task.reference, TaskStatus.blocked),
      );
      await _failure(
        _write(store, context, UndoCalendarWrite(replacedUndo)),
        CalendarFailureCode.undoUnavailable,
      );
      task = await _task(store, taskId);
      detail = await store.localCalendar.taskDetail(task.reference);
      expect(task.status, TaskStatus.blocked);
      expect(
        (await store.localCalendar.detail(
          detail.blocks.single.reference,
        )).relations,
        hasLength(1),
      );
    },
  );

  test(
    'failed writes preserve committed task and undo slot; undo expires after one day',
    () async {
      var rejectCheckpoint = false;
      final clock = _MutableClock(_fixedClock.nowUtc);
      final store = await _open(
        clock: clock,
        checkpoint: () async {
          if (rejectCheckpoint) {
            throw const AppFailure(FailureCode.storageFailed);
          }
        },
      );
      final context = await _context(store);
      final created = await _write(
        store,
        context,
        const CreateTask(TaskDraft(title: '合成事务任务')),
      );
      final taskId = created.task!.localId;
      final originalUndo = await store.localCalendar.queryUndo(context);
      expect(originalUndo.canUndo, isTrue);

      rejectCheckpoint = true;
      final failedCommand = await store.localCalendar.prepare(
        context,
        SetTaskStatus(created.task!, TaskStatus.completed),
      );
      await _failure(
        store.localCalendar.commit(failedCommand),
        CalendarFailureCode.storageFailed,
      );
      rejectCheckpoint = false;

      var task = await _task(store, taskId);
      expect(task.reference.canonical, created.task!.canonical);
      expect(task.status, TaskStatus.active);
      final undoAfterFailure = await store.localCalendar.queryUndo(context);
      expect(undoAfterFailure.canUndo, isTrue);
      expect(
        undoAfterFailure.reference!.undoId,
        originalUndo.reference!.undoId,
      );

      await _write(
        store,
        context,
        SetTaskStatus(task.reference, TaskStatus.blocked),
      );
      task = await _task(store, taskId);
      expect(task.status, TaskStatus.blocked);
      await _failure(
        _write(store, context, UndoCalendarWrite(originalUndo.reference!)),
        CalendarFailureCode.undoUnavailable,
      );
      expect((await _task(store, taskId)).status, TaskStatus.blocked);

      final currentUndo = await store.localCalendar.queryUndo(context);
      expect(currentUndo.canUndo, isTrue);
      clock.nowUtc = clock.nowUtc.add(const Duration(hours: 24, seconds: 1));
      final expired = await store.localCalendar.queryUndo(context);
      expect(expired.canUndo, isFalse);
      expect(expired.failure, CalendarFailureCode.undoUnavailable);
      await _failure(
        _write(store, context, UndoCalendarWrite(currentUndo.reference!)),
        CalendarFailureCode.undoUnavailable,
      );
      task = await _task(store, taskId);
      expect(task.status, TaskStatus.blocked);
    },
  );
}

Future<JwStore> _open({
  AppClock? clock,
  Future<void> Function()? checkpoint,
}) async {
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _Owner(),
    clock: clock ?? _fixedClock,
    onCalendarCheckpoint: checkpoint,
  );
  addTearDown(store.close);
  await store.initialize();
  return store;
}

Future<CalendarContext> _context(JwStore store) async =>
    (await store.localCalendar.query(_calendarQuery())).context;

CalendarQuery _calendarQuery({
  DateTime? firstDay,
  DateTime? endDayExclusive,
  bool includeSkipped = false,
  CalendarFilter filter = CalendarFilter.all,
}) => CalendarQuery(
  firstDay: firstDay ?? _day,
  endDayExclusive: endDayExclusive ?? _day.add(const Duration(days: 7)),
  filter: filter,
  includeSkipped: includeSkipped,
);

PlanBlockDraft _block({
  required DateTime starts,
  required DateTime ends,
  String location = '',
  String note = '',
}) => PlanBlockDraft(
  startsAtUtc: starts,
  endsAtUtc: ends,
  location: location,
  note: note,
);

Future<TaskRecord> _task(JwStore store, int taskId) async =>
    (await store.localCalendar.queryTasks(
      const TaskQuery(filter: TaskFilter.all),
    )).items.singleWhere((task) => task.reference.localId == taskId);

List<CalendarOccurrence> _blocksFor(CalendarWindow window, int taskId) => window
    .items
    .where(
      (item) =>
          item.reference.identity.kind == CalendarKind.planBlock &&
          item.task?.localId == taskId,
    )
    .toList();

Future<CalendarWriteReceipt> _write(
  JwStore store,
  CalendarContext context,
  CalendarIntent intent,
) async => store.localCalendar.commit(
  await store.localCalendar.prepare(context, intent),
);

Future<CalendarWriteReceipt> _undo(
  JwStore store,
  CalendarContext context,
) async {
  final view = await store.localCalendar.queryUndo(context);
  expect(view.canUndo, isTrue);
  return _write(store, context, UndoCalendarWrite(view.reference!));
}

Future<void> _failure(Future<Object?> future, CalendarFailureCode code) =>
    expectLater(
      future,
      throwsA(
        isA<CalendarFailure>().having((failure) => failure.code, 'code', code),
      ),
    );

final class _MutableClock implements AppClock {
  _MutableClock(this.nowUtc);
  @override
  DateTime nowUtc;
}

final class _Owner implements AssetOwnership {
  @override
  bool get isHeld => true;

  @override
  void ensureHeld() {}
}
