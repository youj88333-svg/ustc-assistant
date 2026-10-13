import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
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
    'approved multi-step local plan stores one v2 undo and restores relation and task fields in reverse order',
    () async {
      final store = await _open();
      final configured = await _configure(store);
      final conversation = await store.agent.createConversation();
      final ticket = await store.agent.beginRun(
        configured.authority,
        conversation,
        '仅用于合成分组撤销测试',
      );
      final planPort = store.localCalendar as AgentLocalPlanPort;

      final seed = await store.localCalendar.query(_calendarQuery());
      final leftCreated = await _write(
        store,
        seed.context,
        CreatePersonalEvent(_personalDraft('合成左侧安排', 10, 11)),
      );
      final rightCreated = await _write(
        store,
        seed.context,
        CreatePersonalEvent(_personalDraft('合成右侧安排', 11, 12)),
      );
      var window = await store.localCalendar.query(_calendarQuery());
      var left = _item(window, leftCreated.target!.identity);
      var right = _item(window, rightCreated.target!.identity);
      final linked = await _write(
        store,
        window.context,
        SaveCalendarRelation(
          left: left.reference,
          right: right.reference,
          kind: CalendarRelationKind.conflict,
          note: '撤销后应恢复的合成原因',
        ),
      );
      window = await store.localCalendar.query(_calendarQuery());
      left = _item(window, leftCreated.target!.identity);
      right = _item(window, rightCreated.target!.identity);
      final originalRelation = (await store.localCalendar.detail(
        left.reference,
      )).relations.single.reference;
      expect(originalRelation.localId, linked.relation!.localId);
      final leftVersionBeforePlan = left.reference.version;
      final rightVersionBeforePlan = right.reference.version;

      final (context, revision) = await planPort.readPlanContext();
      final proposed = await planPort
          .prepareLocalPlan(ticket, context, revision, [
            const AgentCreateTask(
              'coursework',
              TaskDraft(
                title: '合成课程任务',
                description: '',
                note: '',
                estimatedMinutes: 45,
                priority: TaskPriority.normal,
              ),
            ),
            AgentDependentBlock(
              'coursework',
              PlanBlockDraft(
                startsAtUtc: DateTime.utc(2026, 10, 13, 4),
                endsAtUtc: DateTime.utc(2026, 10, 13, 5),
                location: '合成地点',
                note: '合成时间块',
              ),
            ),
            AgentCalendarChange(
              SaveCalendarRelation(
                left: left.reference,
                right: right.reference,
                kind: CalendarRelationKind.notConflict,
                note: '方案内临时改动',
                existing: originalRelation,
              ),
            ),
            AgentCalendarChange(DeleteCalendarRelation(originalRelation)),
          ]);
      final approval = await planPort.approveLocalPlan(proposed);
      final committed = await planPort.commitLocalPlan(approval);

      expect(committed.replayed, isFalse);
      expect(committed.committedCount, 4);
      expect(committed.undo, isNotNull);
      expect(await _count(store, 'agenda_undo'), 1);
      final savedPayload =
          jsonDecode(
                (await store
                        .customSelect(
                          'SELECT payload FROM agenda_undo WHERE singleton=1',
                        )
                        .getSingle())
                    .read<String>('payload'),
              )
              as Map<String, dynamic>;
      expect(savedPayload['v'], 2);
      expect(savedPayload['action'], 'agent-plan');
      expect(savedPayload['steps'], hasLength(4));
      expect(savedPayload['guards'], isNotEmpty);
      final finalRelationGuards = savedPayload['relations'] as List;
      expect(finalRelationGuards, hasLength(1));
      final finalRelationGuard =
          finalRelationGuards.single as Map<String, dynamic>;
      expect(finalRelationGuard['left'], isA<String>());
      expect(finalRelationGuard['right'], isA<String>());
      expect(finalRelationGuard['present'], isFalse);
      expect(finalRelationGuard['localId'], isNull);
      expect(finalRelationGuard['version'], isNull);

      var afterCommit = await store.localCalendar.query(_calendarQuery());
      left = _item(afterCommit, leftCreated.target!.identity);
      right = _item(afterCommit, rightCreated.target!.identity);
      expect(
        (await store.localCalendar.detail(left.reference)).relations,
        isEmpty,
      );
      final taskBeforeUndo = await store
          .customSelect(
            'SELECT local_id,version,deleted FROM local_tasks WHERE title=?',
            variables: [Variable.withString('合成课程任务')],
          )
          .getSingle();
      final taskId = taskBeforeUndo.read<int>('local_id');
      final blockBeforeUndo = await store
          .customSelect(
            'SELECT local_id,deleted FROM local_plan_blocks WHERE task_id=?',
            variables: [Variable.withInt(taskId)],
          )
          .getSingle();
      expect(taskBeforeUndo.read<int>('deleted'), 0);
      expect(blockBeforeUndo.read<int>('deleted'), 0);
      expect(left.reference.version, greaterThan(leftVersionBeforePlan));
      expect(right.reference.version, greaterThan(rightVersionBeforePlan));

      final undoView = await store.localCalendar.queryUndo(context);
      expect(undoView.canUndo, isTrue);
      final (undoContext, undoRevision) = await planPort.readPlanContext();
      final undoPlan = await planPort.prepareLocalPlan(
        ticket,
        undoContext,
        undoRevision,
        [AgentCalendarChange(UndoCalendarWrite(undoView.reference!))],
      );
      final undoApproval = await planPort.approveLocalPlan(undoPlan);
      final undone = await planPort.commitLocalPlan(undoApproval);

      expect(undone.committedCount, 1);
      expect(undone.undo, isNull);
      expect(await _count(store, 'agenda_undo'), 0);
      afterCommit = await store.localCalendar.query(_calendarQuery());
      left = _item(afterCommit, leftCreated.target!.identity);
      right = _item(afterCommit, rightCreated.target!.identity);
      final restoredRelation = (await store.localCalendar.detail(
        left.reference,
      )).relations.single;
      expect(restoredRelation.reference.localId, originalRelation.localId);
      expect(
        restoredRelation.reference.version,
        greaterThan(originalRelation.version),
      );
      expect(restoredRelation.kind, CalendarRelationKind.conflict);
      expect(restoredRelation.note, '撤销后应恢复的合成原因');
      expect(
        (await store.localCalendar.detail(
          right.reference,
        )).relations.single.reference.localId,
        originalRelation.localId,
      );

      final taskAfterUndo = await store
          .customSelect(
            'SELECT version,deleted FROM local_tasks WHERE local_id=?',
            variables: [Variable.withInt(taskId)],
          )
          .getSingle();
      final blockAfterUndo = await store
          .customSelect(
            'SELECT deleted FROM local_plan_blocks WHERE local_id=?',
            variables: [
              Variable.withInt(blockBeforeUndo.read<int>('local_id')),
            ],
          )
          .getSingle();
      expect(taskAfterUndo.read<int>('deleted'), 1);
      expect(
        taskAfterUndo.read<int>('version'),
        greaterThan(taskBeforeUndo.read<int>('version')),
      );
      expect(blockAfterUndo.read<int>('deleted'), 1);
    },
  );

  test(
    'group undo rejects a changed final aggregate before applying any step',
    () async {
      final store = await _open();
      final configured = await _configure(store);
      final conversation = await store.agent.createConversation();
      final ticket = await store.agent.beginRun(
        configured.authority,
        conversation,
        '合成分组撤销冲突测试',
      );
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();
      final plan = await planPort.prepareLocalPlan(ticket, context, revision, [
        const AgentCreateTask('task', TaskDraft(title: '待保留的合成任务')),
        AgentDependentBlock(
          'task',
          PlanBlockDraft(
            startsAtUtc: DateTime.utc(2026, 10, 13, 6),
            endsAtUtc: DateTime.utc(2026, 10, 13, 7),
            location: '',
            note: '',
          ),
        ),
      ]);
      final committed = await planPort.commitLocalPlan(
        await planPort.approveLocalPlan(plan),
      );
      final undoView = await store.localCalendar.queryUndo(context);
      expect(undoView.canUndo, isTrue);
      final (undoContext, undoRevision) = await planPort.readPlanContext();
      final undoPlan = await planPort.prepareLocalPlan(
        ticket,
        undoContext,
        undoRevision,
        [AgentCalendarChange(UndoCalendarWrite(undoView.reference!))],
      );
      final undoApproval = await planPort.approveLocalPlan(undoPlan);

      final task = await store
          .customSelect(
            'SELECT local_id,version,deleted FROM local_tasks WHERE title=?',
            variables: [Variable.withString('待保留的合成任务')],
          )
          .getSingle();
      final taskId = task.read<int>('local_id');
      final block = await store
          .customSelect(
            'SELECT local_id,deleted FROM local_plan_blocks WHERE task_id=?',
            variables: [Variable.withInt(taskId)],
          )
          .getSingle();
      final taskVersionBeforeConflict = task.read<int>('version');
      await store.customStatement(
        'UPDATE local_tasks SET version=version+1 WHERE local_id=?',
        [taskId],
      );

      await expectLater(
        planPort.commitLocalPlan(undoApproval),
        throwsA(
          isA<CalendarFailure>().having(
            (failure) => failure.code,
            'code',
            CalendarFailureCode.undoConflict,
          ),
        ),
      );

      final taskAfterFailure = await store
          .customSelect(
            'SELECT version,deleted FROM local_tasks WHERE local_id=?',
            variables: [Variable.withInt(taskId)],
          )
          .getSingle();
      final blockAfterFailure = await store
          .customSelect(
            'SELECT deleted FROM local_plan_blocks WHERE local_id=?',
            variables: [Variable.withInt(block.read<int>('local_id'))],
          )
          .getSingle();
      expect(taskAfterFailure.read<int>('deleted'), 0);
      expect(
        taskAfterFailure.read<int>('version'),
        taskVersionBeforeConflict + 1,
      );
      expect(blockAfterFailure.read<int>('deleted'), 0);
      expect(await _count(store, 'agenda_undo'), 1);
      expect(
        (await store.localCalendar.queryUndo(context)).failure,
        CalendarFailureCode.undoConflict,
      );
      expect(await _count(store, 'agenda_plan_receipts'), 1);
      expect(await _count(store, 'agenda_plan_audit'), 1);
      expect(committed.undo!.undoId, undoView.reference!.undoId);
    },
  );
}

Future<JwStore> _open() async {
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _TestOwnership(),
    clock: _clock,
    modelCredentialProtector: _SyntheticProtector(),
  );
  addTearDown(store.close);
  await store.initialize();
  await store.agent.initializeAgent();
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

CalendarQuery _calendarQuery() => CalendarQuery(
  firstDay: DateTime.utc(2026, 10, 12),
  endDayExclusive: DateTime.utc(2026, 10, 20),
  filter: CalendarFilter.all,
);

PersonalEventDraft _personalDraft(String title, int startHour, int endHour) =>
    PersonalEventDraft(
      title: title,
      start: DateTime.utc(2026, 10, 13, startHour),
      end: DateTime.utc(2026, 10, 13, endHour),
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
