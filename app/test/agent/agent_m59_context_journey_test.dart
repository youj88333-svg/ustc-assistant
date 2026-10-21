import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/agent_action_tools.dart';
import 'package:ustc_assistant_m0/agent/agent_coordinator.dart';
import 'package:ustc_assistant_m0/agent/agent_invocation_fingerprint.dart';
import 'package:ustc_assistant_m0/agent/agent_read_tools.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/agent/ustc_model_gateway.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/agent_context_contract.dart';
import 'package:ustc_assistant_m0/core/agent_discussion_contract.dart';
import 'package:ustc_assistant_m0/core/agent_source_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/jw_academic_details.dart';
import 'package:ustc_assistant_m0/core/jw_work_contract.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/jobs/public_query_coordinator.dart';
import 'package:ustc_assistant_m0/source/jw_collection_contract.dart';
import 'package:ustc_assistant_m0/source/jw_probe_contract.dart';

final _now = DateTime.utc(2026, 10, 14, 4);
final _modelKey = Uint8List.fromList('synthetic-m59-context-key'.codeUnits);
const _legacyV6UndoResult =
    '{"version":"agent-tools-v6","status":"empty","data":{"available":false},"evidence":[],"trust":"untrusted_source_data"}';

void main() {
  for (final approve in [false, true]) {
    test(
      'undo repairs a missing required scope and ${approve ? "commits only after approval" : "keeps the task after rejection"}',
      () async {
        final rig = await _open();
        await _createTask(rig.store, '合成A7撤销测试任务');
        rig.gateway.enqueueEvents(
          _call('a7-undo-invalid', 'propose_undo', const {}),
        );
        rig.gateway.enqueue((request) {
          final rejected = _latestResultFor(request, 'propose_undo');
          expect(rejected['status'], 'invalidRequest');
          final repair = rejected['data'] as Map;
          expect((rejected['validation'] as Map)['reason'], 'missingField');
          expect((rejected['validation'] as Map)['field'], 'scope');
          expect(repair['expected_arguments'], {
            'scope': 'latest_local_change',
          });
          final repairText = repair['repair'] as String;
          expect(repairText, contains('"scope":"latest_local_change"'));
          expect(repairText, contains('changes'));
          expect(
            repairText.contains('不要添加') || repairText.contains('其它操作参数'),
            isTrue,
          );
          return _call('a7-undo-corrected', 'propose_undo', const {
            'scope': 'latest_local_change',
          });
        });
        rig.gateway.enqueue((request) {
          expect(
            _latestResultFor(request, 'propose_undo')['status'],
            approve ? 'committed' : 'rejected',
          );
          return _answer(approve ? '已撤销测试任务。' : '没有撤销测试任务。');
        });

        final run = rig.coordinator.send('undo');
        await _until(
          () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
        );
        final current = rig.coordinator.view.pendingAction!;
        expect(current.status, AgentActionStatus.proposed);
        expect(await _count(rig.store, 'agenda_plan_receipts'), 0);
        expect(
          (await rig.store.localCalendar.queryTasks(
            const TaskQuery(filter: TaskFilter.all),
          )).items,
          hasLength(1),
        );

        if (approve) {
          await rig.coordinator.approveAction(current.id);
        } else {
          await rig.coordinator.rejectAction(current.id);
        }
        await run.timeout(const Duration(seconds: 3));
        expect(rig.coordinator.view.failure, isNull);
        expect(rig.coordinator.view.pendingAction, isNull);
        expect(
          await _count(rig.store, 'agenda_plan_receipts'),
          approve ? 1 : 0,
        );
        expect(
          (await rig.store.localCalendar.queryTasks(
            const TaskQuery(filter: TaskFilter.all),
          )).items,
          hasLength(approve ? 0 : 1),
        );
        expect(rig.sources.refreshCalls, 0);
        expect(await rig.coordinator.readActionPermissions(), isEmpty);
        for (final request in rig.gateway.requests.skip(1)) {
          _expectPairedProtocol(request);
        }
      },
    );
  }

  for (final approve in [false, true]) {
    test(
      'loopback HTTP undo repair ${approve ? "is approved" : "is rejected"} through the full C3 flow',
      () async {
        final service = _A7UndoLoopbackService(approve: approve);
        await service.start();
        addTearDown(service.close);
        final gateway = UstcModelGateway.loopbackForTesting(
          service.baseUri,
          connectTimeout: const Duration(seconds: 2),
          requestTimeout: const Duration(seconds: 5),
          idleTimeout: const Duration(seconds: 2),
        );
        final rig = await _open(
          gateway: gateway,
          includeReminders: true,
          seedLegacyV6UndoHistory: true,
        );
        await _createTask(rig.store, '合成A7撤销测试任务');

        final run = rig.coordinator.send('undo');
        await _until(
          () =>
              rig.coordinator.view.phase == AgentPhase.waitingForApproval ||
              rig.coordinator.view.failure != null ||
              service.failures.isNotEmpty,
        );
        expect(service.failures, isEmpty);
        expect(rig.coordinator.view.failure, isNull);
        expect(rig.coordinator.view.phase, AgentPhase.waitingForApproval);
        final current = rig.coordinator.view.pendingAction!;
        expect(current.status, AgentActionStatus.proposed);
        expect(await _count(rig.store, 'agenda_plan_receipts'), 0);
        expect(
          (await rig.store.localCalendar.queryTasks(
            const TaskQuery(filter: TaskFilter.all),
          )).items,
          hasLength(1),
        );

        if (approve) {
          await rig.coordinator.approveAction(current.id);
        } else {
          await rig.coordinator.rejectAction(current.id);
        }
        await run.timeout(const Duration(seconds: 8));

        expect(service.failures, isEmpty);
        expect(service.chatBodies, hasLength(3));
        expect(rig.coordinator.view.failure, isNull);
        expect(rig.coordinator.view.pendingAction, isNull);
        expect(
          await _count(rig.store, 'agenda_plan_receipts'),
          approve ? 1 : 0,
        );
        expect(
          (await rig.store.localCalendar.queryTasks(
            const TaskQuery(filter: TaskFilter.all),
          )).items,
          hasLength(approve ? 0 : 1),
        );
        expect(rig.sources.refreshCalls, 0);
        expect(await rig.coordinator.readActionPermissions(), isEmpty);
      },
    );
  }

  test(
    'course follow-up resolves the historical alias, commits the current card once, and continues from its receipt',
    () async {
      final rig = await _open(importCourse: true);
      const original = '今天下午的课不想上';
      rig.gateway.enqueueEvents(_queryCourse());
      rig.gateway.enqueueAnswer('我查到《合成周三下午课程》，要把个人出勤计划设为不参加吗？');

      await rig.coordinator.send(original).timeout(const Duration(seconds: 3));

      expect(rig.gateway.requests, hasLength(2));
      final firstHistoryRequest = rig.gateway.requests[1];
      expect(
        _latestResultFor(firstHistoryRequest, 'query_agenda')['status'],
        'success',
      );
      final queriedCourse = _agendaItems(firstHistoryRequest).single;
      expect(queriedCourse['title'], '合成周三下午课程');
      final courseAlias = queriedCourse['event_ref'] as String;
      expect(
        firstHistoryRequest.messages.map((message) => message.role),
        containsAll(['user', 'assistant', 'tool']),
      );
      _expectPairedProtocol(firstHistoryRequest);
      expect(firstHistoryRequest.toolChoice, isNull);

      rig.gateway.enqueue((request) {
        expect(_lastUserContent(request), '可以');
        _expectUserContent(request, original);
        final historicalCourse = _agendaItems(request).single;
        expect(historicalCourse['event_ref'], courseAlias);
        final args = {
          'changes': [
            {
              'type': 'annotate_school',
              'event_ref': courseAlias,
              'attendance': 'skip',
            },
          ],
        };
        return _call('m59-course-proposal', 'propose_local_changes', args);
      });
      rig.gateway.enqueue((request) {
        expect(
          _latestResultFor(request, 'propose_local_changes')['status'],
          'committed',
        );
        return _answer('已把这节课的个人出勤计划设为不参加。');
      });

      final proposalRun = rig.coordinator.send('可以');
      await _until(
        () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
      );
      expect(rig.gateway.requests, hasLength(3));
      final proposalRequest = rig.gateway.requests[2];
      _expectUserContent(proposalRequest, original);
      expect(_lastUserContent(proposalRequest), '可以');
      _expectPairedProtocol(proposalRequest);
      // The third request precedes the model's proposal response. It must not
      // fabricate that future call into the historical protocol.
      expect(
        _callsIn(
          proposalRequest,
        ).where((call) => call.name == 'propose_local_changes'),
        isEmpty,
      );
      expect(
        _callsIn(proposalRequest).where((call) => call.name == 'query_agenda'),
        hasLength(1),
      );
      expect(await _count(rig.store, 'agenda_plan_receipts'), 0);
      expect(
        (await _courseOccurrence(rig.store)).attendance,
        AttendanceDecision.undecided,
      );

      final pendingId = rig.coordinator.view.pendingAction!.id;
      await rig.coordinator.send('确认').timeout(const Duration(seconds: 3));
      await proposalRun.timeout(const Duration(seconds: 3));
      final proposalCalls = _callsIn(
        rig.gateway.requests[3],
      ).where((call) => call.name == 'propose_local_changes').toList();
      expect(proposalCalls, hasLength(1));
      expect(proposalCalls.single.argumentsJson, contains(courseAlias));
      _expectPairedProtocol(rig.gateway.requests[3]);
      expect(rig.coordinator.view.phase, AgentPhase.idle);
      expect(rig.coordinator.view.pendingAction, isNull);
      expect(await _count(rig.store, 'agenda_plan_receipts'), 1);
      expect(
        (await _courseOccurrence(rig.store)).attendance,
        AttendanceDecision.skip,
      );
      expect(await rig.coordinator.readActionPermissions(), isEmpty);
      final action = rig.coordinator.view.messages
          .expand((message) => message.actions)
          .singleWhere((candidate) => candidate.id == pendingId);
      expect(action.status, AgentActionStatus.committed);
      expect(action.authorization, AgentActionAuthorization.confirmed);

      rig.gateway.enqueue((request) {
        expect(_lastUserContent(request), '请继续');
        _expectUserContent(request, original);
        expect(
          _callsIn(
            request,
          ).where((call) => call.name == 'propose_local_changes'),
          hasLength(1),
        );
        expect(
          _latestResultFor(request, 'propose_local_changes')['status'],
          'committed',
        );
        return _answer('已完成，课程的学校记录没有改变。');
      });
      await rig.coordinator.send('请继续').timeout(const Duration(seconds: 3));

      expect(rig.gateway.requests, hasLength(5));
      _expectUserContent(rig.gateway.requests.last, '请继续');
      expect(
        _latestResultFor(
          rig.gateway.requests.last,
          'propose_local_changes',
        )['status'],
        'committed',
      );
      expect(await _count(rig.store, 'agenda_plan_receipts'), 1);
      expect(rig.sources.refreshCalls, 0);
      _expectAllDefinitions(rig.gateway.requests);
    },
  );

  test(
    'choosing the second candidate and changing its date rejects the old card before proposing a new one',
    () async {
      final rig = await _open();
      await _createPersonalEvent(
        rig.store,
        '候选甲：复习安排',
        DateTime.utc(2026, 10, 14, 2),
      );
      await _createPersonalEvent(
        rig.store,
        '候选乙：实验安排',
        DateTime.utc(2026, 10, 14, 4),
      );
      rig.gateway.enqueueEvents(_queryPersonalEvents());
      rig.gateway.enqueueAnswer('今天有两项个人安排，你想调整哪一项？');
      final queryAndAsk = rig.coordinator
          .send('今天的安排有哪两项？')
          .timeout(const Duration(seconds: 3));
      await queryAndAsk;
      final queryRequest = rig.gateway.requests[1];
      final candidates = _agendaItems(queryRequest);
      expect(candidates.map((item) => item['title']), ['候选甲：复习安排', '候选乙：实验安排']);
      final selectedAlias = candidates[1]['event_ref'] as String;

      rig.gateway.enqueue((request) {
        expect(_lastUserContent(request), '第二项改到周四上午');
        _expectUserContent(request, '今天的安排有哪两项？');
        expect(_agendaItems(request)[1]['title'], '候选乙：实验安排');
        return _proposalUpdate(
          id: 'm59-candidate-old-plan',
          eventRef: selectedAlias,
          date: '2026-10-15',
        );
      });
      rig.gateway.enqueue((request) {
        expect(
          _latestResultFor(request, 'propose_local_changes')['status'],
          'rejected',
        );
        return _answer('原方案已拒绝，尚未改动安排。');
      });
      rig.gateway.enqueue((request) {
        expect(_lastUserContent(request), '改到周五上午');
        _expectUserContent(request, '第二项改到周四上午');
        expect(
          _latestResultFor(request, 'propose_local_changes')['status'],
          'rejected',
        );
        final priorAgendaCalls = _callsIn(
          request,
        ).where((call) => call.name == 'query_agenda').length;
        expect(priorAgendaCalls, 1);
        return _proposalUpdate(
          id: 'm59-candidate-revised-plan',
          eventRef: selectedAlias,
          date: '2026-10-16',
        );
      });
      rig.gateway.enqueue((request) {
        expect(
          _latestResultFor(request, 'propose_local_changes')['status'],
          'committed',
        );
        return _answer('已按周五上午更新第二项安排。');
      });

      final selectionRun = rig.coordinator.send('第二项改到周四上午');
      await _until(
        () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
      );
      final oldCard = rig.coordinator.view.pendingAction!;
      expect(await _count(rig.store, 'agenda_plan_receipts'), 0);
      expect(
        (await _personalEvent(rig.store, '候选乙：实验安排')).startsAtUtc,
        DateTime.utc(2026, 10, 14, 4),
      );

      final changedRun = rig.coordinator.send('改到周五上午');
      await _until(
        () =>
            rig.coordinator.view.phase == AgentPhase.waitingForApproval &&
            rig.coordinator.view.pendingAction?.id != oldCard.id &&
            rig.gateway.requests.length == 5,
      );
      final newCard = rig.coordinator.view.pendingAction!;
      expect(newCard.id, isNot(oldCard.id));
      expect(await _count(rig.store, 'agenda_plan_receipts'), 0);
      expect(
        (await _personalEvent(rig.store, '候选乙：实验安排')).startsAtUtc,
        DateTime.utc(2026, 10, 14, 4),
      );

      await rig.coordinator.send('确认').timeout(const Duration(seconds: 3));
      await Future.wait([
        selectionRun,
        changedRun,
      ]).timeout(const Duration(seconds: 3));

      final finalEvent = await _personalEvent(rig.store, '候选乙：实验安排');
      expect(finalEvent.startsAtUtc, DateTime.utc(2026, 10, 16, 1));
      expect(finalEvent.endsAtUtc, DateTime.utc(2026, 10, 16, 2));
      expect(await _count(rig.store, 'agenda_plan_receipts'), 1);
      final actions = rig.coordinator.view.messages
          .expand((message) => message.actions)
          .toList();
      expect(
        actions.singleWhere((action) => action.id == oldCard.id).status,
        AgentActionStatus.rejected,
      );
      expect(
        actions.singleWhere((action) => action.id == newCard.id).status,
        AgentActionStatus.committed,
      );
      expect(rig.sources.refreshCalls, 0);
      _expectAllDefinitions(rig.gateway.requests);
    },
  );

  test(
    'daily permission commits one local bundle automatically and advice mode leaves no receipt',
    () async {
      final rig = await _open();
      await rig.coordinator.saveUsePolicy(
        personalContentAllowed: false,
        dailyOperationsAllowed: true,
      );
      rig.gateway.enqueue((_) => _proposalBundle());
      rig.gateway.enqueueAnswer('已在一个本地事务中保存日程和任务。');

      final phases = <AgentPhase>[];
      final subscription = rig.coordinator.changes.listen(
        (view) => phases.add(view.phase),
      );
      await rig.coordinator
          .send('帮我安排一次合成复习并建任务')
          .timeout(const Duration(seconds: 3));
      await subscription.cancel();

      expect(phases, isNot(contains(AgentPhase.waitingForApproval)));
      expect(rig.coordinator.view.pendingAction, isNull);
      expect(await _count(rig.store, 'agenda_plan_receipts'), 1);
      final tasks = await rig.store.localCalendar.queryTasks(
        const TaskQuery(filter: TaskFilter.all),
      );
      expect(tasks.items.map((task) => task.draft.title), ['合成事务任务']);
      final personal = await rig.store.localCalendar.query(
        _calendarQuery(filter: CalendarFilter.personal),
      );
      expect(personal.items.map((event) => event.title), ['合成事务日程']);
      expect(
        _latestResultFor(
          rig.gateway.requests[1],
          'propose_local_changes',
        )['status'],
        'committed',
      );

      await rig.coordinator.setAdviceOnly(true);
      rig.gateway.enqueue((_) => _proposalNewTask('m59-advice-plan'));
      rig.gateway.enqueue((request) {
        expect(
          _latestResultFor(request, 'propose_local_changes')['status'],
          'adviceOnly',
        );
        return _answer('我可以说明建议，但这次没有提交任何改动。');
      });
      await rig.coordinator.send('再建议一个安排').timeout(const Duration(seconds: 3));

      expect(rig.coordinator.view.pendingAction, isNull);
      expect(await _count(rig.store, 'agenda_plan_receipts'), 1);
      final afterAdvice = await rig.store.localCalendar.queryTasks(
        const TaskQuery(filter: TaskFilter.all),
      );
      expect(afterAdvice.items.map((task) => task.draft.title), ['合成事务任务']);
      expect(rig.sources.refreshCalls, 0);
      _expectAllDefinitions(rig.gateway.requests);
    },
  );

  test(
    'two failed final answers recover one receipt and a completed turn permits an explicit same-title creation',
    () async {
      final rig = await _open();
      await rig.coordinator.saveUsePolicy(
        personalContentAllowed: false,
        dailyOperationsAllowed: true,
      );
      const prompt = '创建一个名为合成回执恢复任务的任务';
      const arguments = {
        'changes': [
          {
            'type': 'create_task',
            'local_key': 'recoverable_task',
            'title': '合成回执恢复任务',
          },
        ],
      };
      final originalCall = ModelToolCall(
        id: 'm59-recovery-original',
        name: 'propose_local_changes',
        argumentsJson: jsonEncode(arguments),
      );
      rig.gateway.enqueueEvents([
        ModelCompleted(finishReason: 'tool_calls', toolCalls: [originalCall]),
      ]);
      rig.gateway.enqueue(
        (_) => throw const AgentFailure(AgentFailureCode.networkFailed),
      );

      await rig.coordinator.send(prompt).timeout(const Duration(seconds: 3));

      expect(rig.coordinator.view.failure, AgentFailureCode.networkFailed);
      expect(rig.gateway.requests, hasLength(2));
      expect(
        _latestResultFor(
          rig.gateway.requests[1],
          'propose_local_changes',
        )['status'],
        'committed',
      );
      expect(await _count(rig.store, 'agenda_plan_receipts'), 1);
      final firstTasks = await rig.store.localCalendar.queryTasks(
        const TaskQuery(filter: TaskFilter.all),
      );
      expect(firstTasks.items, hasLength(1));
      expect(firstTasks.items.single.draft.title, '合成回执恢复任务');
      final failedAssistant = rig.coordinator.view.messages.lastWhere(
        (message) => message.role == AgentMessageRole.assistant,
      );
      expect(failedAssistant.status, AgentMessageStatus.failed);

      final retryCall = ModelToolCall(
        id: 'm59-recovery-repeat',
        name: 'propose_local_changes',
        argumentsJson: jsonEncode(arguments),
      );
      expect(retryCall.argumentsJson, originalCall.argumentsJson);

      void expectHistoricalResult(ModelRequest request, ModelToolCall call) {
        expect(_lastUserContent(request), '请继续');
        final calls = _callsIn(request)
            .where((candidate) => candidate.name == 'propose_local_changes')
            .toList();
        expect(calls, isNotEmpty);
        expect(calls.last.argumentsJson, originalCall.argumentsJson);
        expect(calls.last.argumentsJson, call.argumentsJson);
        final result = _latestResultFor(request, 'propose_local_changes');
        expect(result['status'], 'success');
        final data = result['data'] as Map<String, dynamic>;
        expect(data['count'], 1);
        expect(data['receipt_status'], 'committed');
        expect(data['historical_receipt'], isTrue);
        expect(data['submitted_this_run'], isFalse);
      }

      rig.gateway.enqueueEvents([
        ModelCompleted(finishReason: 'tool_calls', toolCalls: [retryCall]),
      ]);
      rig.gateway.enqueue((request) {
        expectHistoricalResult(request, retryCall);
        throw const AgentFailure(AgentFailureCode.networkFailed);
      });

      await rig.coordinator.send('请继续').timeout(const Duration(seconds: 3));

      expect(rig.coordinator.view.failure, AgentFailureCode.networkFailed);
      expect(rig.gateway.requests, hasLength(4));
      expect(await _count(rig.store, 'agenda_plan_receipts'), 1);
      final afterRecovery = await rig.store.localCalendar.queryTasks(
        const TaskQuery(filter: TaskFilter.all),
      );
      expect(afterRecovery.items, hasLength(1));
      expect(afterRecovery.items.single.draft.title, '合成回执恢复任务');
      final failedRecoveryAssistant = rig.coordinator.view.messages.lastWhere(
        (message) => message.role == AgentMessageRole.assistant,
      );
      expect(failedRecoveryAssistant.status, AgentMessageStatus.failed);
      expect(failedRecoveryAssistant.actions, isEmpty);
      expect(
        rig.coordinator.view.messages
            .expand((message) => message.actions)
            .where((action) => action.status == AgentActionStatus.committed),
        hasLength(1),
      );

      final thirdCall = ModelToolCall(
        id: 'm59-recovery-third',
        name: 'propose_local_changes',
        argumentsJson: jsonEncode(arguments),
      );
      expect(thirdCall.argumentsJson, originalCall.argumentsJson);
      rig.gateway.enqueueEvents([
        ModelCompleted(finishReason: 'tool_calls', toolCalls: [thirdCall]),
      ]);
      rig.gateway.enqueue((request) {
        expectHistoricalResult(request, thirdCall);
        return _answer('上一轮已经提交该任务，本轮没有重复写入。');
      });

      await rig.coordinator.send('请继续').timeout(const Duration(seconds: 3));

      expect(rig.gateway.requests, hasLength(6));
      expect(rig.coordinator.view.failure, isNull);
      expect(await _count(rig.store, 'agenda_plan_receipts'), 1);
      final afterCompletedRecovery = await rig.store.localCalendar.queryTasks(
        const TaskQuery(filter: TaskFilter.all),
      );
      expect(afterCompletedRecovery.items, hasLength(1));
      final completedRecoveryAssistant = rig.coordinator.view.messages
          .lastWhere((message) => message.role == AgentMessageRole.assistant);
      expect(completedRecoveryAssistant.status, AgentMessageStatus.complete);
      expect(completedRecoveryAssistant.actions, isEmpty);
      expect(
        rig.coordinator.view.messages
            .expand((message) => message.actions)
            .where((action) => action.status == AgentActionStatus.committed),
        hasLength(1),
      );

      final explicitCall = ModelToolCall(
        id: 'm59-recovery-explicit-new',
        name: 'propose_local_changes',
        argumentsJson: jsonEncode(arguments),
      );
      rig.gateway.enqueueEvents([
        ModelCompleted(finishReason: 'tool_calls', toolCalls: [explicitCall]),
      ]);
      rig.gateway.enqueue((request) {
        expect(_lastUserContent(request), '请再新建一个同名任务');
        final result = _latestResultFor(request, 'propose_local_changes');
        expect(result['status'], 'committed');
        final data = result['data'] as Map<String, dynamic>;
        expect(data['count'], 1);
        expect(data.containsKey('historical_receipt'), isFalse);
        return _answer('已新建同名任务。');
      });

      await rig.coordinator
          .send('请再新建一个同名任务')
          .timeout(const Duration(seconds: 3));

      expect(rig.gateway.requests, hasLength(8));
      expect(await _count(rig.store, 'agenda_plan_receipts'), 2);
      final afterExplicitCreate = await rig.store.localCalendar.queryTasks(
        const TaskQuery(filter: TaskFilter.all),
      );
      expect(afterExplicitCreate.items, hasLength(2));
      expect(
        afterExplicitCreate.items.map((task) => task.draft.title),
        everyElement('合成回执恢复任务'),
      );
      expect(
        rig.coordinator.view.messages
            .expand((message) => message.actions)
            .where((action) => action.status == AgentActionStatus.committed),
        hasLength(2),
      );
      expect(rig.sources.refreshCalls, 0);
      _expectAllDefinitions(rig.gateway.requests);
    },
  );

  test(
    'new_operation true permits a same-fingerprint write before completion',
    () async {
      final rig = await _open();
      await rig.coordinator.saveUsePolicy(
        personalContentAllowed: false,
        dailyOperationsAllowed: true,
      );
      const arguments = <String, Object?>{
        'changes': [
          {
            'type': 'create_task',
            'local_key': 'explicit_second_task',
            'title': '合成明确新建任务',
          },
        ],
      };
      final newOperationArguments = {...arguments, 'new_operation': true};
      expect(
        agentLocalInvocationFingerprint(arguments),
        agentLocalInvocationFingerprint(newOperationArguments),
      );

      rig.gateway.enqueueEvents([
        ModelCompleted(
          finishReason: 'tool_calls',
          toolCalls: [
            ModelToolCall(
              id: 'm59-explicit-first',
              name: 'propose_local_changes',
              argumentsJson: jsonEncode(arguments),
            ),
          ],
        ),
      ]);
      rig.gateway.enqueue((request) {
        expect(
          _latestResultFor(request, 'propose_local_changes')['status'],
          'committed',
        );
        throw const AgentFailure(AgentFailureCode.networkFailed);
      });

      await rig.coordinator
          .send('创建一个名为合成明确新建任务的任务')
          .timeout(const Duration(seconds: 3));

      expect(rig.coordinator.view.failure, AgentFailureCode.networkFailed);
      expect(await _count(rig.store, 'agenda_plan_receipts'), 1);

      rig.gateway.enqueueEvents([
        ModelCompleted(
          finishReason: 'tool_calls',
          toolCalls: [
            ModelToolCall(
              id: 'm59-explicit-second',
              name: 'propose_local_changes',
              argumentsJson: jsonEncode(newOperationArguments),
            ),
          ],
        ),
      ]);
      rig.gateway.enqueue((request) {
        expect(_lastUserContent(request), '请另外新建一个同名任务');
        final result = _latestResultFor(request, 'propose_local_changes');
        expect(result['status'], 'committed');
        final data = result['data'] as Map<String, dynamic>;
        expect(data['count'], 1);
        expect(data.containsKey('historical_receipt'), isFalse);
        return _answer('已按你的新请求另行创建。');
      });

      await rig.coordinator
          .send('请另外新建一个同名任务')
          .timeout(const Duration(seconds: 3));

      expect(rig.coordinator.view.failure, isNull);
      expect(await _count(rig.store, 'agenda_plan_receipts'), 2);
      final tasks = await rig.store.localCalendar.queryTasks(
        const TaskQuery(filter: TaskFilter.all),
      );
      expect(tasks.items, hasLength(2));
      expect(
        tasks.items.map((task) => task.draft.title),
        everyElement('合成明确新建任务'),
      );
      expect(
        rig.coordinator.view.messages
            .expand((message) => message.actions)
            .where((action) => action.status == AgentActionStatus.committed),
        hasLength(2),
      );
      _expectAllDefinitions(rig.gateway.requests);
    },
  );

  test(
    'a selected task remains a non-authorizing alias for the next model turn',
    () async {
      final rig = await _open();
      final task = await _createTask(
        rig.store,
        '已选中的合成任务 A',
        description: '可见于普通安全详情',
      );
      rig.gateway.enqueueAnswer('你希望我对这个任务做什么？');
      rig.gateway.enqueue((request) {
        expect(_lastUserContent(request), '继续看已选中的任务');
        final alias = _selectedTaskAlias(request);
        return _call('m59-selected-task-read', 'read_task', {
          'task_ref': alias,
          'include_details': false,
        });
      });
      rig.gateway.enqueue((request) {
        final result = _latestResultFor(request, 'read_task');
        expect(jsonEncode(result), contains('已选中的合成任务 A'));
        return _answer('已定位到你选中的任务。');
      });

      await rig.coordinator.prepareDiscussion(
        AgentDiscussionSelection.task(task.reference),
      );
      final first = rig.coordinator.send('先说说这个任务怎么安排？');
      await first.timeout(const Duration(seconds: 3));
      final firstRequest = rig.gateway.requests.first;
      expect(_callsIn(firstRequest), isEmpty);
      expect(firstRequest.messages.last.content, contains('task_ref=r_'));
      expect(firstRequest.messages.last.content, contains('不是批准'));
      final firstSnapshot = await rig.store.agent.readConversationContext();
      expect(
        firstSnapshot.turns.last.applicationSelection,
        contains('task_ref=r_'),
      );
      expect(firstSnapshot.turns.last.applicationSelection, contains('不是批准'));

      await rig.coordinator
          .send('继续看已选中的任务')
          .timeout(const Duration(seconds: 3));
      final secondRequest = rig.gateway.requests[1];
      _expectUserContent(secondRequest, '先说说这个任务怎么安排？');
      final storedAlias = _selectedTaskAlias(firstRequest);
      expect(
        firstSnapshot.turns.last.applicationSelection,
        contains(storedAlias),
      );
      expect(_selectedTaskAlias(secondRequest), storedAlias);
      expect(
        _latestResultFor(rig.gateway.requests.last, 'read_task')['status'],
        'success',
      );
      expect(rig.coordinator.view.failure, isNull);
      expect(rig.sources.refreshCalls, 0);
      _expectAllDefinitions(rig.gateway.requests);
    },
  );

  test(
    'stopped safe partial text remains context, while revoked private task content is withheld',
    () async {
      final rig = await _open();
      final manual = rig.gateway.enqueueManual();
      final interrupted = rig.coordinator.send('请开始检查合成任务');
      await manual.started.future.timeout(const Duration(seconds: 2));
      manual.emit(const ModelTextDelta('停止前已经显示的安全合成片段'));
      await _until(
        () => rig.coordinator.view.messages.any(
          (message) => message.text == '停止前已经显示的安全合成片段',
        ),
      );
      await rig.coordinator.stop().timeout(const Duration(seconds: 3));
      await interrupted.timeout(const Duration(seconds: 3));
      expect(manual.isClosed, isTrue);
      final stoppedMessages = await rig.store.agent.messages(
        rig.coordinator.view.conversationId!,
      );
      expect(stoppedMessages.last.status, AgentMessageStatus.cancelled);

      rig.gateway.enqueueAnswer('我会沿着已显示的部分继续。');
      await rig.coordinator.send('请继续').timeout(const Duration(seconds: 3));
      final continued = rig.gateway.requests.last;
      _expectPairedProtocol(continued);
      expect(_callsIn(continued), isEmpty);
      _expectUserContent(continued, '请开始检查合成任务');
      expect(_requestText(continued), contains('停止前已经显示的安全合成片段'));
      expect(_requestText(continued), contains('未完成回复'));

      final privateTask = await _createTask(
        rig.store,
        '合成私密任务',
        description: 'synthetic-private-description-marker',
        note: 'synthetic-private-note-marker',
      );
      await rig.coordinator.saveUsePolicy(
        personalContentAllowed: true,
        dailyOperationsAllowed: false,
      );
      rig.gateway.enqueue(
        (_) => _call('m59-private-query', 'query_tasks', {
          'filter': 'open',
          'limit': 10,
        }),
      );
      rig.gateway.enqueue((request) {
        final tasks = _taskItems(request);
        final target = tasks.singleWhere((item) => item['title'] == '合成私密任务');
        expect(target['task_ref'], isNotEmpty);
        return _call('m59-private-read', 'read_task', {
          'task_ref': target['task_ref'],
          'include_details': true,
        });
      });
      rig.gateway.enqueueAnswer('我读到了 synthetic-private-note-marker。');
      await rig.coordinator
          .send('读取合成私密任务详情')
          .timeout(const Duration(seconds: 3));
      expect(
        _requestText(rig.gateway.requests.last),
        contains('synthetic-private-note-marker'),
      );
      expect(privateTask.draft.note, 'synthetic-private-note-marker');

      await rig.coordinator.saveUsePolicy(
        personalContentAllowed: false,
        dailyOperationsAllowed: false,
      );
      final withheld = await rig.store.agent.readConversationContext();
      expect(withheld.withheldAssistantMessageIds, isNotEmpty);
      rig.gateway.enqueueAnswer('我可以继续讨论任务，但不会复述被撤回的详情。');
      await rig.coordinator
          .send('继续讨论这个任务')
          .timeout(const Duration(seconds: 3));
      final afterWithdrawal = rig.gateway.requests.last;
      _expectUserContent(afterWithdrawal, '读取合成私密任务详情');
      expect(
        _requestText(afterWithdrawal),
        isNot(contains('synthetic-private-description-marker')),
      );
      expect(
        _requestText(afterWithdrawal),
        isNot(contains('synthetic-private-note-marker')),
      );
      expect(rig.sources.refreshCalls, 0);
      _expectAllDefinitions(rig.gateway.requests);
    },
  );
}

Future<_Rig> _open({
  bool importCourse = false,
  bool includeReminders = false,
  bool seedLegacyV6UndoHistory = false,
  ModelGatewayPort? gateway,
}) async {
  final clock = FixedClock(_now);
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _TestOwnership(),
    clock: clock,
    modelCredentialProtector: _SyntheticProtector(),
  );
  addTearDown(store.close);
  await store.initialize();
  await store.agent.initializeAgent();
  if (includeReminders) await store.features.initialize();
  if (importCourse) await _importSyntheticCourse(store);
  final settings = await store.agent.inspectAgent();
  await store.agent.saveModelConfiguration(
    settings.authority,
    modelId: 'synthetic-m59-model',
    modelIds: const ['synthetic-m59-model'],
    report: const AgentCapabilityReport(
      text: true,
      streaming: true,
      toolCall: true,
      toolResult: true,
    ),
    consent: true,
    key: _modelKey,
  );
  if (seedLegacyV6UndoHistory) await _seedLegacyV6UndoHistory(store);

  final publicQueries = PublicQueryCoordinator(
    store: store.publicStore,
    leases: WorkLeasePool(),
    clock: clock,
    sessionFactory: (_) =>
        throw StateError('Synthetic tests must not access the network.'),
  );
  final readTools = AgentReadTools(
    calendar: store.localCalendar,
    tasks: store.localCalendar,
    calendarGuard: store.localCalendar,
    knowledge: store.publicStore,
    knowledgeGuard: store.publicStore,
    publicQueries: publicQueries,
    publicGuard: publicQueries,
    clock: clock,
  );
  final sources = _SyntheticSource(clock);
  final actionTools = AgentActionTools(
    readTools: readTools,
    plans: store.localCalendar,
    calendar: store.localCalendar,
    tasks: store.localCalendar,
    preferences: store.agent,
    preferenceProposals: store.agent,
    sources: sources,
    actionRecords: store.agent,
    reminders: includeReminders ? store.features : null,
    clock: clock,
  );
  final scriptGateway = _ScriptGateway();
  final coordinator = AgentCoordinator(
    data: store.agent,
    gateway: gateway ?? scriptGateway,
    readTools: actionTools,
    clock: clock,
  );
  addTearDown(coordinator.close);
  await coordinator.initialize();
  return _Rig(store, scriptGateway, coordinator, sources);
}

Future<void> _importSyntheticCourse(JwStore store) async {
  const accountCode = 'AB12345';
  final ticket = await store.beginJob(expectedAccountCode: accountCode);
  final partition = JwPartitionRef(
    id: 'jwp-${List.filled(32, '1').join()}',
    ownerId: ticket.stamp.ownerId,
    purpose: JwPartitionPurpose.initial,
    attempt: ticket.stamp.jobId,
    resetEpoch: ticket.stamp.resetEpoch,
  );
  await store.stagePartition(ticket, partition);
  await store.stageSemesterCatalog(ticket, const [
    JwSemesterOption(id: 202610, name: '合成学期', selected: true),
  ]);
  final diagnostics = <String, Object>{
    'checks': {
      'identityBefore': 'ok',
      'course': 'ok',
      'index': 'ok',
      'datum': 'ok',
      'exams': 'ok',
      'identityAfter': 'ok',
    },
    'reason': 'none',
    'identityReads': 2,
    'lessonIds': 1,
    'lessons': 1,
    'groups': 1,
    'schedules': 1,
    'datedSchedules': 1,
    'timedSchedules': 1,
    'linkedSchedules': 1,
    'examRows': 0,
    'datedExams': 0,
    'semesterAccepted': true,
    'selfRouteBound': true,
    'identityStable': true,
    'emptyCourse': false,
    'emptyExams': true,
    'pagination': false,
    'types': {
      'lessonIds': 'array',
      'lessonList': 'array',
      'scheduleGroupList': 'array',
      'scheduleList': 'array',
      'date': 'string',
      'startTime': 'string',
      'endTime': 'string',
    },
  };
  final reply = JwCollectionReply.decode(
    jsonEncode({
      'operation': 31,
      'phase': 'done',
      'code': 'ok',
      'identity': {
        'candidateCount': 1,
        'method': 'table',
        'accountCode': accountCode,
      },
      'diagnostics': diagnostics,
      'snapshot': {
        'version': jwContractVersion,
        'semesterId': 202610,
        'courses': [
          {
            'lessonId': 101,
            'groupId': 1101,
            'date': '2026-10-14',
            'startMinute': 900,
            'endMinute': 950,
            'title': '合成周三下午课程',
            'academicDetails': JwAcademicDetails(
              lessonId: 101,
              groupId: 1101,
            ).toMap(),
          },
        ],
        'exams': <Object>[],
      },
    }),
    operation: 31,
  );
  final artifact = JwCollectedArtifact.seal(
    reply: reply,
    stamp: ticket.stamp,
    partition: partition,
    session: 1,
    document: 2,
    semesterId: 202610,
    collectedAtUtc: _now,
  );
  await store.importSnapshot(ticket, artifact);
}

List<ModelEvent> _queryCourse() =>
    _call('m59-course-query', 'query_agenda', const {
      'first_day': '2026-10-14',
      'end_day_exclusive': '2026-10-15',
      'filter': 'course',
      'include_skipped': true,
    });

List<ModelEvent> _queryPersonalEvents() =>
    _call('m59-two-candidate-query', 'query_agenda', const {
      'first_day': '2026-10-14',
      'end_day_exclusive': '2026-10-15',
      'filter': 'personal',
      'limit': 10,
    });

List<ModelEvent> _proposalUpdate({
  required String id,
  required String eventRef,
  required String date,
}) => _call(id, 'propose_local_changes', {
  'changes': [
    {
      'type': 'update_personal',
      'event_ref': eventRef,
      'scope': 'series',
      'start': '${date}T09:00+08:00',
      'end': '${date}T10:00+08:00',
      'all_day': false,
    },
  ],
});

List<ModelEvent> _proposalBundle() =>
    _call('m59-bundle-plan', 'propose_local_changes', const {
      'changes': [
        {
          'type': 'create_personal',
          'title': '合成事务日程',
          'start': '2026-10-15T09:00+08:00',
          'end': '2026-10-15T10:00+08:00',
        },
        {
          'type': 'create_task',
          'local_key': 'bundle_task',
          'title': '合成事务任务',
          'description': '由同一合成事务创建',
        },
      ],
    });

List<ModelEvent> _proposalNewTask(String id) =>
    _call(id, 'propose_local_changes', {
      'changes': [
        {'type': 'create_task', 'local_key': 'advice_task', 'title': '建议任务不提交'},
      ],
    });

List<ModelEvent> _call(String id, String name, Map<String, Object?> args) => [
  ModelCompleted(
    finishReason: 'tool_calls',
    toolCalls: [
      ModelToolCall(id: id, name: name, argumentsJson: jsonEncode(args)),
    ],
  ),
];

List<ModelEvent> _answer(String text) => [
  ModelTextDelta(text),
  ModelCompleted(finishReason: 'stop'),
];

String _selectedTaskAlias(ModelRequest request) {
  final match = RegExp(
    r'task_ref=(r_[a-f0-9]{32})',
  ).firstMatch(_requestText(request));
  if (match == null) throw StateError('No stored task alias in the request.');
  return match.group(1)!;
}

List<ModelToolCall> _callsIn(ModelRequest request) => [
  for (final message in request.messages) ...message.toolCalls,
];

Map<String, dynamic> _latestResultFor(ModelRequest request, String toolName) {
  final calls = _callsIn(
    request,
  ).where((call) => call.name == toolName).toList();
  for (final call in calls.reversed) {
    final result = request.messages.where(
      (message) => message.role == 'tool' && message.toolCallId == call.id,
    );
    if (result.isNotEmpty) {
      return jsonDecode(result.last.content!) as Map<String, dynamic>;
    }
  }
  throw StateError('No completed $toolName result in scripted model request.');
}

List<Map<String, dynamic>> _agendaItems(ModelRequest request) =>
    ((_latestResultFor(request, 'query_agenda')['data']
                as Map<String, dynamic>)['items']
            as List)
        .cast<Map<String, dynamic>>();

List<Map<String, dynamic>> _taskItems(ModelRequest request) =>
    ((_latestResultFor(request, 'query_tasks')['data']
                as Map<String, dynamic>)['items']
            as List)
        .cast<Map<String, dynamic>>();

List<String> _userContents(ModelRequest request) => [
  for (final message in request.messages)
    if (message.role == 'user' && message.content != null) message.content!,
];

void _expectUserContent(ModelRequest request, String originalText) {
  expect(
    _userContents(request).any((content) => content.contains(originalText)),
    isTrue,
    reason: 'Expected a user message to retain: $originalText',
  );
}

String _lastUserContent(ModelRequest request) => _userContents(request).last;

String _requestText(ModelRequest request) => request.messages
    .where((message) => message.content != null)
    .map((message) => message.content)
    .join('\n');

void _expectAllDefinitions(Iterable<ModelRequest> requests) {
  const enabled = {
    'query_agenda',
    'read_event',
    'query_tasks',
    'read_task',
    'inspect_conflicts',
    'search_knowledge',
    'read_knowledge',
    'search_courses',
    'read_course',
    'read_reviews',
    'browse_campus',
    'read_campus_article',
    'propose_local_changes',
    'propose_undo',
    'find_free_slots',
    'propose_planning_preferences',
    'query_source_options',
    'request_source_refresh',
    'query_young_activities',
  };
  for (final request in requests) {
    expect(request.tools.map((tool) => tool.name).toSet(), enabled);
    expect(request.toolChoice, isNull);
    _expectPairedProtocol(request);
  }
}

void _expectPairedProtocol(ModelRequest request) {
  final callIds = _callsIn(request).map((call) => call.id).toList();
  final resultIds = request.messages
      .where((message) => message.role == 'tool')
      .map((message) => message.toolCallId)
      .toList();
  expect(callIds, hasLength(resultIds.length));
  expect(callIds.toSet(), resultIds.toSet());
  expect(callIds.toSet(), hasLength(callIds.length));
}

Future<CalendarOccurrence> _courseOccurrence(JwStore store) async {
  final window = await store.localCalendar.query(
    _calendarQuery(filter: CalendarFilter.course),
  );
  return window.items.singleWhere((item) => item.title == '合成周三下午课程');
}

Future<CalendarOccurrence> _personalEvent(JwStore store, String title) async {
  final window = await store.localCalendar.query(
    _calendarQuery(filter: CalendarFilter.personal),
  );
  return window.items.singleWhere((item) => item.title == title);
}

Future<CalendarOccurrence> _createPersonalEvent(
  JwStore store,
  String title,
  DateTime startsAtUtc,
) async {
  final window = await store.localCalendar.query(_calendarQuery());
  final command = await store.localCalendar.prepare(
    window.context,
    CreatePersonalEvent(
      PersonalEventDraft(
        title: title,
        start: startsAtUtc,
        end: startsAtUtc.add(const Duration(hours: 1)),
      ),
    ),
  );
  await store.localCalendar.commit(command);
  return _personalEvent(store, title);
}

Future<TaskRecord> _createTask(
  JwStore store,
  String title, {
  String description = '',
  String note = '',
}) async {
  final before = await store.localCalendar.queryTasks(
    const TaskQuery(filter: TaskFilter.all),
  );
  final command = await store.localCalendar.prepare(
    before.context,
    CreateTask(TaskDraft(title: title, description: description, note: note)),
  );
  final receipt = await store.localCalendar.commit(command);
  final tasks = await store.localCalendar.queryTasks(
    const TaskQuery(filter: TaskFilter.all),
  );
  return tasks.items.singleWhere(
    (task) => task.reference.localId == receipt.task!.localId,
  );
}

Future<void> _seedLegacyV6UndoHistory(JwStore store) async {
  final settings = await store.agent.inspectAgent();
  final conversationId = await store.agent.ensurePrimaryConversation();
  final policy = await store.agent.readAgentUsePolicy();
  final ticket = await store.agent.beginRun(
    settings.authority,
    conversationId,
    '旧版v6撤销协议历史',
  );
  await store.agent.bindAgentRunPolicy(ticket, policy);
  await store.agent.saveAgentTurn(
    ticket,
    items: [
      AgentContextItem(
        role: 'assistant',
        calls: const [
          AgentContextCall(
            id: 'legacy-v6-undo',
            name: 'propose_undo',
            argumentsJson: '{}',
          ),
        ],
      ),
      AgentContextItem(
        role: 'tool',
        toolCallId: 'legacy-v6-undo',
        text: _legacyV6UndoResult,
      ),
    ],
    includesPersonalContent: false,
    policyRevision: policy.revision,
  );
  await store.agent.saveAssistant(ticket, '旧版v6撤销结果仅作为历史数据。');
  await store.agent.finishRun(ticket, AgentMessageStatus.complete);
}

CalendarQuery _calendarQuery({CalendarFilter filter = CalendarFilter.all}) =>
    CalendarQuery(
      firstDay: DateTime.utc(2026, 10, 14),
      endDayExclusive: DateTime.utc(2026, 10, 22),
      filter: filter,
      includeHidden: true,
      includeSkipped: true,
    );

Future<int> _count(JwStore store, String table) async =>
    (await store.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
        .read<int>('n');

Future<void> _until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
        'Synthetic M5.9 journey did not reach its expected state.',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

final class _Rig {
  const _Rig(this.store, this.gateway, this.coordinator, this.sources);
  final JwStore store;
  final _ScriptGateway gateway;
  final AgentCoordinator coordinator;
  final _SyntheticSource sources;
}

typedef _RequestScript = List<ModelEvent> Function(ModelRequest request);

sealed class _QueuedStep {}

final class _ScriptStep extends _QueuedStep {
  _ScriptStep(this.script);
  final Stream<ModelEvent> Function(ModelRequest request) script;
}

final class _ManualStep extends _QueuedStep {
  _ManualStep(this.generation);
  final _ManualGeneration generation;
}

final class _ScriptGateway implements ModelGatewayPort {
  final Queue<_QueuedStep> _steps = Queue<_QueuedStep>();
  final List<ModelRequest> requests = [];
  final Set<_ManualGeneration> _activeManual = {};
  bool _closed = false;

  void enqueue(_RequestScript script) => _steps.add(
    _ScriptStep((request) => Stream<ModelEvent>.fromIterable(script(request))),
  );

  void enqueueEvents(List<ModelEvent> events) => enqueue((_) => events);

  void enqueueAnswer(String text) => enqueueEvents(_answer(text));

  _ManualGeneration enqueueManual() {
    final generation = _ManualGeneration();
    _steps.add(_ManualStep(generation));
    return generation;
  }

  @override
  Future<List<String>> listModels(ModelSecretLease secret) async {
    _consume(secret);
    return const ['synthetic-m59-model'];
  }

  @override
  Stream<ModelEvent> generate(ModelRequest request, ModelSecretLease secret) {
    _consume(secret);
    if (_closed) {
      return Stream<ModelEvent>.error(
        const AgentFailure(AgentFailureCode.closed),
      );
    }
    if (_steps.isEmpty) {
      throw StateError(
        'Unexpected synthetic model request ${requests.length + 1}.',
      );
    }
    requests.add(request);
    final step = _steps.removeFirst();
    if (step is _ScriptStep) return step.script(request);
    final generation = (step as _ManualStep).generation;
    generation.attach(request);
    _activeManual.add(generation);
    return generation.stream;
  }

  void _consume(ModelSecretLease secret) {
    final bytes = secret.take();
    bytes.fillRange(0, bytes.length, 0);
  }

  @override
  Future<void> cancelAndDrain() async {
    for (final generation in List<_ManualGeneration>.of(_activeManual)) {
      await generation.close();
      _activeManual.remove(generation);
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    await cancelAndDrain();
  }
}

final class _A7UndoLoopbackService {
  _A7UndoLoopbackService({required this.approve});

  final bool approve;
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  final List<Map<String, dynamic>> chatBodies = [];
  final List<String> failures = [];

  Uri get baseUri {
    final server = _server;
    if (server == null) throw StateError('A7 loopback server is not started.');
    return Uri(scheme: 'http', host: '127.0.0.1', port: server.port);
  }

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _subscription = server.listen((request) {
      unawaited(_handle(request));
    });
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method != 'POST' ||
          request.uri.path != '/v1/chat/completions') {
        throw StateError('Unexpected A7 loopback request target.');
      }
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      chatBodies.add(body);
      _expectUndoToolRegistry(body);
      _expectLegacyV6UndoHistory(body);

      switch (chatBodies.length) {
        case 1:
          _expectUserTurn(body, 'undo');
          await _writeToolCall(
            request.response,
            id: 'a7-undo-invalid',
            arguments: const [
              '{"scope":"latest_local_change","changes":',
              '[]',
              '}',
            ],
          );
          return;
        case 2:
          _expectInvalidUndoHistory(body);
          await _writeToolCall(
            request.response,
            id: 'a7-undo-corrected',
            arguments: const ['{"scope":"latest_local_change"}'],
          );
          return;
        case 3:
          _expectUndoDecision(body);
          await _writeText(
            request.response,
            approve ? '已撤销合成测试任务。' : '已保留合成测试任务。',
          );
          return;
        default:
          throw StateError('Unexpected extra A7 model request.');
      }
    } on Object catch (error) {
      failures.add(error.toString());
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } on Object {
        // The gateway may already have closed a failed response.
      }
    }
  }

  void _expectUndoToolRegistry(Map<String, dynamic> body) {
    final tools = (body['tools'] as List).cast<Map<String, dynamic>>();
    expect(tools, hasLength(20));
    final functions = [
      for (final tool in tools) tool['function'] as Map<String, dynamic>,
    ];
    final names = functions.map((function) => function['name']).toSet();
    expect(names, {
      'query_agenda',
      'read_event',
      'query_tasks',
      'read_task',
      'inspect_conflicts',
      'search_knowledge',
      'read_knowledge',
      'search_courses',
      'read_course',
      'read_reviews',
      'browse_campus',
      'read_campus_article',
      'propose_local_changes',
      'propose_undo',
      'find_free_slots',
      'propose_planning_preferences',
      'query_source_options',
      'request_source_refresh',
      'query_young_activities',
      'query_reminders',
    });

    for (final function in functions) {
      final parameters = function['parameters'] as Map<String, dynamic>;
      final properties = parameters['properties'] as Map<String, dynamic>;
      expect(
        properties.containsKey('changes'),
        function['name'] == 'propose_local_changes',
      );
    }
    final undo = functions.singleWhere(
      (function) => function['name'] == 'propose_undo',
    );
    final undoParameters = undo['parameters'] as Map<String, dynamic>;
    expect(
      undoParameters,
      equals({
        'type': 'object',
        'properties': {
          'scope': {
            'type': 'string',
            'enum': ['latest_local_change'],
          },
        },
        'required': ['scope'],
        'additionalProperties': false,
      }),
    );
  }

  void _expectLegacyV6UndoHistory(Map<String, dynamic> body) {
    final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
    final legacyCall = messages
        .where(
          (message) =>
              message['role'] == 'assistant' && message['tool_calls'] is List,
        )
        .expand((message) => message['tool_calls'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((call) {
          final function = call['function'] as Map<String, dynamic>;
          return function['name'] == 'propose_undo' &&
              function['arguments'] == '{}';
        });
    final callId = legacyCall['id'];
    final legacyResult = messages.singleWhere(
      (message) =>
          message['role'] == 'tool' && message['tool_call_id'] == callId,
    );
    final resultBytes = legacyResult['content'] as String;
    expect(resultBytes, _legacyV6UndoResult);
    expect(
      (jsonDecode(resultBytes) as Map<String, dynamic>)['version'],
      'agent-tools-v6',
    );
  }

  void _expectUserTurn(Map<String, dynamic> body, String content) {
    final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
    expect(_systemContent(body), isNot(contains('【应用本轮参数校验】')));
    expect(
      messages.any(
        (message) => message['role'] == 'user' && message['content'] == content,
      ),
      isTrue,
    );
  }

  void _expectInvalidUndoHistory(Map<String, dynamic> body) {
    final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
    final system = _systemContent(body);
    expect(system, contains('【应用本轮参数校验】'));
    expect(
      system,
      contains('propose_undo(arguments={"scope":"latest_local_change"})'),
    );
    final repairSystem = system.substring(system.indexOf('【应用本轮参数校验】'));
    expect(repairSystem, contains('不带 changes'));
    expect(repairSystem, contains('其他字段'));
    final assistant = messages.singleWhere((message) {
      if (message['role'] != 'assistant' || message['tool_calls'] is! List) {
        return false;
      }
      return (message['tool_calls'] as List).any(
        (call) => (call as Map<String, dynamic>)['id'] == 'a7-undo-invalid',
      );
    });
    final invalidCall = (assistant['tool_calls'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((call) => call['id'] == 'a7-undo-invalid');
    expect(
      invalidCall['function']['arguments'],
      '{"scope":"latest_local_change","changes":[]}',
    );
    final result = messages.singleWhere(
      (message) =>
          message['role'] == 'tool' &&
          message['tool_call_id'] == 'a7-undo-invalid',
    );
    final payload =
        jsonDecode(result['content'] as String) as Map<String, dynamic>;
    expect(payload['status'], 'invalidRequest');
    expect(
      (payload['validation'] as Map<String, dynamic>)['reason'],
      'unknownField',
    );
    expect((payload['validation'] as Map<String, dynamic>)['field'], 'changes');
    final data = payload['data'] as Map<String, dynamic>;
    expect(data['expected_arguments'], {'scope': 'latest_local_change'});
    final repair = data['repair'] as String;
    expect(repair, contains('"scope":"latest_local_change"'));
    expect(repair, contains('changes'));
    expect(repair.contains('不要添加') || repair.contains('其它操作参数'), isTrue);
  }

  void _expectUndoDecision(Map<String, dynamic> body) {
    final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
    expect(_systemContent(body), isNot(contains('【应用本轮参数校验】')));
    final correctedCall = messages
        .where(
          (message) =>
              message['role'] == 'assistant' && message['tool_calls'] is List,
        )
        .expand((message) => message['tool_calls'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((call) => call['id'] == 'a7-undo-corrected');
    expect(
      correctedCall['function']['arguments'],
      '{"scope":"latest_local_change"}',
    );
    final result = messages.singleWhere(
      (message) =>
          message['role'] == 'tool' &&
          message['tool_call_id'] == 'a7-undo-corrected',
    );
    final payload =
        jsonDecode(result['content'] as String) as Map<String, dynamic>;
    expect(payload['status'], approve ? 'committed' : 'rejected');
  }

  String _systemContent(Map<String, dynamic> body) =>
      (body['messages'] as List).cast<Map<String, dynamic>>().singleWhere(
            (message) => message['role'] == 'system',
          )['content']
          as String;

  Future<void> _writeToolCall(
    HttpResponse response, {
    required String id,
    required List<String> arguments,
  }) => _writeSse(response, [
    {
      'choices': [
        {
          'index': 0,
          'delta': {
            'tool_calls': [
              {
                'index': 0,
                'id': id,
                'type': 'function',
                'function': {
                  'name': 'propose_undo',
                  'arguments': arguments.first,
                },
              },
            ],
          },
          'finish_reason': null,
        },
      ],
    },
    for (final part in arguments.skip(1))
      {
        'choices': [
          {
            'index': 0,
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'function': {'arguments': part},
                },
              ],
            },
            'finish_reason': null,
          },
        ],
      },
    {
      'choices': [
        {
          'index': 0,
          'delta': <String, Object?>{},
          'finish_reason': 'tool_calls',
        },
      ],
    },
  ]);

  Future<void> _writeText(HttpResponse response, String text) =>
      _writeSse(response, [
        {
          'choices': [
            {
              'index': 0,
              'delta': {'content': text},
              'finish_reason': null,
            },
          ],
        },
        {
          'choices': [
            {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': 'stop'},
          ],
        },
      ]);

  Future<void> _writeSse(
    HttpResponse response,
    List<Map<String, Object?>> events,
  ) async {
    response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    for (final event in events) {
      response.write('data: ${jsonEncode(event)}\n\n');
      await response.flush();
    }
    response.write('data: [DONE]\n\n');
    await response.close();
  }

  Future<void> close() async {
    await _subscription?.cancel();
    await _server?.close(force: true);
    _subscription = null;
    _server = null;
  }
}

final class _ManualGeneration {
  final StreamController<ModelEvent> _controller =
      StreamController<ModelEvent>();
  final Completer<void> started = Completer<void>();
  ModelRequest? request;
  bool get isClosed => _controller.isClosed;
  Stream<ModelEvent> get stream => _controller.stream;

  void attach(ModelRequest value) {
    request = value;
    if (!started.isCompleted) started.complete();
  }

  void emit(ModelEvent event) {
    if (!_controller.isClosed) _controller.add(event);
  }

  Future<void> close() => _controller.close();
}

final class _SyntheticSource implements AgentSourcePort {
  _SyntheticSource(this.clock);
  final AppClock clock;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  int refreshCalls = 0;
  @override
  bool get waitingForSchool => false;
  @override
  Stream<void> get changes => _changes.stream;
  @override
  Future<AgentSourceOptions> readOptions(AgentRunTicket ticket) async =>
      AgentSourceOptions(
        accountBound: false,
        credentialSaved: false,
        semesters: const [],
      );
  @override
  Future<AgentSourceResult> refresh(
    AgentRunTicket ticket,
    AgentActionView approvedRecord,
    AgentSourceRequest request,
  ) async {
    refreshCalls++;
    throw StateError('Synthetic M5.9 tests never refresh a source.');
  }

  @override
  Future<AgentSourceResult> queryActivities(AgentRunTicket ticket) async =>
      AgentSourceResult(
        committed: false,
        count: 0,
        observedAtUtc: clock.nowUtc,
        complete: true,
      );
  @override
  Future<void> continueSchool() async {}
  @override
  Future<void> cancelAndDrain() async {}
  @override
  Future<void> close() => _changes.close();
}

final class _SyntheticProtector implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-m59-protector/v1';
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
