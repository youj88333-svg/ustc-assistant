import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/agent_action_tools.dart';
import 'package:ustc_assistant_m0/agent/agent_tool_contract.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/core/agent_action_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/agent_discussion_contract.dart';
import 'package:ustc_assistant_m0/core/agent_parameter_issue.dart';
import 'package:ustc_assistant_m0/core/agent_source_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';

const _context = CalendarContext(
  owner: 'synthetic',
  resetEpoch: 2,
  agendaEpoch: 3,
);
final _clock = FixedClock(DateTime.utc(2026, 10, 13, 0));

void main() {
  group('AgentActionTools', () {
    test(
      'prepares dependent task blocks without writing before approval',
      () async {
        final fixture = _Fixture();
        final readTools = _ReadTools(fixture.plans);
        final tools = fixture.tools(readTools);
        final toolSession = tools.openSession();
        final interactive = toolSession as AgentInteractiveToolSession;
        interactive.bindRun(_ticket(), '安排一小时空闲复习');
        final readSession = readTools.sessions.single;
        final discussionReference = (await readSession.resolveEventReference(
          readSession.personalToken,
        )).$1;
        final selection = AgentDiscussionSelection.event(discussionReference);
        expect(
          await (toolSession as AgentDiscussionToolSession).selectForDiscussion(
            selection,
          ),
          'synthetic discussion selection',
        );
        expect(
          identical(readSession.lastDiscussionSelection, selection),
          isTrue,
        );

        final result = await toolSession.execute(
          _call('propose_local_changes', {
            'changes': [
              {
                'type': 'create_task',
                'local_key': 'review',
                'title': '复习',
                'description': 'DRAFT_BODY_MARKER',
                'note': 'DRAFT_NOTE_MARKER',
              },
              {
                'type': 'create_block',
                'task_key': 'review',
                'start': '2026-10-13T10:00+08:00',
                'end': '2026-10-13T11:00+08:00',
              },
            ],
          }),
        );

        expect(result.status, 'waitingForApproval');
        expect(interactive.pendingAction?.status, AgentActionStatus.proposed);
        expect(fixture.plans.prepareCalls, 1);
        expect(fixture.plans.commitCalls, 0);
        expect(fixture.plans.lastRequireFree, isTrue);
        expect(
          fixture.plans.lastPreferencesRevision,
          fixture.preferences.value.revision,
        );
        expect(fixture.tasks.taskDetailCalls, 0);
        expect(fixture.plans.lastPlan!.changes[0], isA<AgentCreateTask>());
        expect(fixture.plans.lastPlan!.changes[1], isA<AgentDependentBlock>());
        final dependent =
            fixture.plans.lastPlan!.changes[1] as AgentDependentBlock;
        expect(dependent.taskKey, 'review');
        expect(dependent.draft.startsAtUtc, DateTime.utc(2026, 10, 13, 2));
        expect(dependent.draft.endsAtUtc, DateTime.utc(2026, 10, 13, 3));
        final safeResult = jsonEncode(result.toMap());
        expect(safeResult, isNot(contains('DRAFT_BODY_MARKER')));
        expect(safeResult, isNot(contains('DRAFT_NOTE_MARKER')));
        expect(safeResult, isNot(contains('SECRET_PRIVATE_NOTE')));

        final rejected = await interactive.decidePending(false);
        expect(rejected.status, 'rejected');
        expect(fixture.plans.rejectCalls, 1);
        expect(fixture.plans.commitCalls, 0);
        expect(interactive.pendingAction, isNull);
      },
    );

    test(
      'separate rejected local plans can prepare more than 20 changes per session',
      () async {
        final fixture = _Fixture();
        final tools = fixture.tools(_ReadTools(fixture.plans));
        final session = tools.openSession();
        final interactive = session as AgentInteractiveToolSession;
        interactive.bindRun(_ticket(), '分别准备合成任务方案');
        const proposalSizes = [8, 8, 5];

        for (
          var proposalIndex = 0;
          proposalIndex < proposalSizes.length;
          proposalIndex++
        ) {
          final changes = List.generate(
            proposalSizes[proposalIndex],
            (changeIndex) => <String, Object?>{
              'type': 'create_task',
              'local_key': 'p${proposalIndex}_task$changeIndex',
              'title': 'Synthetic task $changeIndex',
            },
          );
          final prepared = await session.execute(
            _call('propose_local_changes', {'changes': changes}),
          );

          expect(prepared.status, 'waitingForApproval');
          expect(interactive.pendingAction?.status, AgentActionStatus.proposed);
          final rejected = await interactive.decidePending(false);
          expect(rejected.status, 'rejected');
          expect(interactive.pendingAction, isNull);
        }

        expect(fixture.plans.prepareCalls, 3);
        expect(fixture.plans.preparedChangeCounts, proposalSizes);
        expect(fixture.plans.rejectCalls, 3);
        expect(fixture.plans.commitCalls, 0);
      },
    );

    test(
      'a 21-change local plan is rejected before any plan is prepared',
      () async {
        final fixture = _Fixture();
        final tools = fixture.tools(_ReadTools(fixture.plans));
        final session = tools.openSession();
        final interactive = session as AgentInteractiveToolSession;
        interactive.bindRun(_ticket(), '准备超出单方案上限的合成任务');
        final changes = List.generate(
          21,
          (changeIndex) => <String, Object?>{
            'type': 'create_task',
            'local_key': 'task$changeIndex',
            'title': 'Synthetic task $changeIndex',
          },
        );

        final result = await session.execute(
          _call('propose_local_changes', {'changes': changes}),
        );

        expect(result.status, 'invalidRequest');
        expect(result.failure, 'invalidRequest');
        expect(result.validation?.reason, AgentParameterReason.limitExceeded);
        expect(result.validation?.field, AgentParameterField.changes);
        expect(fixture.plans.prepareCalls, 0);
        expect(fixture.plans.preparedChangeCounts, isEmpty);
        expect(fixture.plans.commitCalls, 0);
        expect(interactive.pendingAction, isNull);
      },
    );

    test(
      'approved plan uses its receipt and invalidates old read references',
      () async {
        final fixture = _Fixture();
        final readTools = _ReadTools(fixture.plans);
        final tools = fixture.tools(readTools);
        final toolSession = tools.openSession();
        final interactive = toolSession as AgentInteractiveToolSession;
        interactive.bindRun(_ticket(), '新增个人日程');
        final oldTaskRef = readTools.taskRef;

        final prepared = await toolSession.execute(
          _call('propose_local_changes', {
            'changes': [
              {
                'type': 'create_personal',
                'title': '复习',
                'start': '2026-10-13T10:00+08:00',
                'end': '2026-10-13T11:00+08:00',
              },
            ],
          }),
        );
        expect(prepared.status, 'waitingForApproval');
        expect(fixture.plans.commitCalls, 0);

        final committed = await interactive.decidePending(true);
        expect(committed.status, 'committed');
        expect(committed.data['count'], 1);
        expect(fixture.plans.approveCalls, 1);
        expect(fixture.plans.commitCalls, 1);
        expect(interactive.contextInvalidated, isTrue);
        expect(readTools.openCalls, 2);
        expect(readTools.sessions.first.revoked, isTrue);

        interactive.acknowledgeContextInvalidated();
        final stale = await toolSession.execute(
          _call('propose_local_changes', {
            'changes': [
              {'type': 'update_task', 'task_ref': oldTaskRef, 'title': '改标题'},
            ],
          }),
        );
        expect(stale.status, 'stale');
        expect(fixture.plans.prepareCalls, 1);
      },
    );

    test(
      'rejects extra fields, unknown refs, duplicate JSON keys, and non-Beijing times',
      () async {
        final fixture = _Fixture();
        final tools = fixture.tools(_ReadTools(fixture.plans));
        final toolSession = tools.openSession();
        (toolSession as AgentInteractiveToolSession).bindRun(_ticket(), '修改任务');

        final extra = await toolSession.execute(
          _call('propose_local_changes', {
            'changes': [
              {
                'type': 'create_task',
                'local_key': 'new',
                'title': '标题',
                'approved': true,
              },
            ],
          }),
        );
        expect(extra.status, 'invalidRequest');
        expect(fixture.plans.prepareCalls, 0);

        final unknown = await toolSession.execute(
          _call('propose_local_changes', {
            'changes': [
              {'type': 'update_task', 'task_ref': 'unknown', 'title': '改标题'},
            ],
          }),
        );
        expect(unknown.status, 'stale');
        expect(fixture.plans.prepareCalls, 0);

        final wrongZone = await toolSession.execute(
          _call('propose_local_changes', {
            'changes': [
              {
                'type': 'create_personal',
                'title': '复习',
                'start': '2026-10-13T10:00:00Z',
                'end': '2026-10-13T11:00:00Z',
              },
            ],
          }),
        );
        expect(wrongZone.status, 'invalidRequest');
        expect(fixture.plans.prepareCalls, 0);

        final duplicate = await toolSession.execute(
          const ModelToolCall(
            id: 'duplicate',
            name: 'propose_local_changes',
            argumentsJson:
                '{"changes":[{"type":"create_task","local_key":"new","title":"标题"}],"changes":[]}',
          ),
        );
        expect(duplicate.status, 'invalidRequest');
        expect(fixture.plans.prepareCalls, 0);
      },
    );

    test(
      'finds bounded candidates and binds selected blocks to their conditions',
      () async {
        final fixture = _Fixture();
        fixture.calendar.items = [_busyEvent()];
        final readTools = _ReadTools(fixture.plans);
        final tools = fixture.tools(readTools);
        final toolSession = tools.openSession();
        final interactive = toolSession as AgentInteractiveToolSession;
        interactive.bindRun(_ticket(), '找一个空闲时段');

        final found = await toolSession.execute(
          _call('find_free_slots', {
            'first_day': '2026-10-13',
            'end_day_exclusive': '2026-10-14',
            'weekdays': [2],
            'start_minute': 510,
            'end_minute': 660,
            'block_minutes': 60,
          }),
        );
        expect(found.status, 'success');
        expect(found.data['weekdays'], [2]);
        expect(found.data['start_minute'], 510);
        final candidates = found.data['candidates'] as List;
        expect(candidates, hasLength(1));
        final candidate = candidates.single as Map;
        expect(candidate['start'], '2026-10-13T10:00:00+08:00');
        final slot = candidate['slot_ref'] as String;

        final proposed = await toolSession.execute(
          _call('propose_local_changes', {
            'changes': [
              {'type': 'create_task', 'local_key': 'study', 'title': '复习'},
              {'type': 'create_block', 'task_key': 'study', 'slot_ref': slot},
            ],
          }),
        );
        expect(proposed.status, 'waitingForApproval');
        expect(fixture.plans.lastRequireFree, isTrue);
        expect(
          fixture.plans.lastPreferencesRevision,
          fixture.preferences.value.revision,
        );
        final block =
            fixture.plans.lastPlan!.changes.last as AgentDependentBlock;
        expect(block.draft.startsAtUtc, DateTime.utc(2026, 10, 13, 2));
        expect(block.draft.endsAtUtc, DateTime.utc(2026, 10, 13, 3));
      },
    );

    test(
      'rejects a slot after its planning preference revision changes',
      () async {
        final fixture = _Fixture();
        fixture.calendar.items = [_busyEvent()];
        final tools = fixture.tools(_ReadTools(fixture.plans));
        final toolSession = tools.openSession();
        (toolSession as AgentInteractiveToolSession).bindRun(
          _ticket(),
          '找一个空闲时段',
        );
        final found = await toolSession.execute(
          _call('find_free_slots', {
            'first_day': '2026-10-13',
            'end_day_exclusive': '2026-10-14',
            'weekdays': [2],
            'start_minute': 510,
            'end_minute': 660,
            'block_minutes': 60,
          }),
        );
        final slot =
            ((found.data['candidates'] as List).single as Map)['slot_ref']
                as String;
        fixture.preferences.value = _preferences(revision: 8);

        final stale = await toolSession.execute(
          _call('propose_local_changes', {
            'changes': [
              {'type': 'create_task', 'local_key': 'study', 'title': '复习'},
              {'type': 'create_block', 'task_key': 'study', 'slot_ref': slot},
            ],
          }),
        );
        expect(stale.status, 'stale');
        expect(fixture.plans.prepareCalls, 0);
      },
    );

    test(
      'undo rejects extra arguments with an exact empty-object repair before preparing',
      () async {
        final fixture = _Fixture();
        fixture.tasks.undo = CalendarUndoView(
          reference: const CalendarUndoReference(_context, 'local-undo-slot'),
        );
        final tools = fixture.tools(_ReadTools(fixture.plans));
        addTearDown(tools.close);
        final toolSession = tools.openSession();
        final interactive = toolSession as AgentInteractiveToolSession;
        interactive.bindRun(_ticket(), '撤销上次测试修改');

        for (final args in const [
          {'changes': <Object>[]},
          {'unregistered-field': 'SYNTHETIC_EXTRA_ARGUMENT_MARKER'},
        ]) {
          final rejected = await toolSession.execute(
            _call('propose_undo', args),
          );
          expect(rejected.status, 'invalidRequest');
          expect(
            rejected.validation?.reason,
            AgentParameterReason.unknownField,
          );
          expect(rejected.data['expected_arguments'], isEmpty);
          expect(rejected.data['repair'], contains('propose_undo'));
          expect(rejected.data['repair'], contains('{}'));
          final safe = jsonEncode(rejected.toMap());
          expect(safe, isNot(contains('unregistered-field')));
          expect(safe, isNot(contains('SYNTHETIC_EXTRA_ARGUMENT_MARKER')));
          expect(fixture.plans.prepareCalls, 0);
          expect(fixture.plans.commitCalls, 0);
          expect(interactive.pendingAction, isNull);
        }

        final corrected = await toolSession.execute(_call('propose_undo', {}));
        expect(corrected.status, 'waitingForApproval');
        expect(fixture.plans.prepareCalls, 1);
        expect(fixture.plans.commitCalls, 0);
        await interactive.decidePending(false);
        expect(fixture.plans.commitCalls, 0);
      },
    );

    test(
      'undo uses the current local slot and planning preferences remain pending',
      () async {
        final fixture = _Fixture();
        fixture.tasks.undo = CalendarUndoView(
          reference: const CalendarUndoReference(_context, 'local-undo-slot'),
          action: 'hidden-internal-action',
        );
        final tools = fixture.tools(_ReadTools(fixture.plans));
        final toolSession = tools.openSession();
        final interactive = toolSession as AgentInteractiveToolSession;
        interactive.bindRun(_ticket(), '撤销上次修改');

        final undo = await toolSession.execute(_call('propose_undo', {}));
        expect(undo.status, 'waitingForApproval');
        expect(jsonEncode(undo.data), isNot(contains('local-undo-slot')));
        expect(
          fixture.plans.lastPlan!.changes.single,
          isA<AgentCalendarChange>(),
        );
        final undoChange =
            fixture.plans.lastPlan!.changes.single as AgentCalendarChange;
        expect(undoChange.intent, isA<UndoCalendarWrite>());
        await interactive.decidePending(false);
        expect(fixture.plans.commitCalls, 0);

        final preferences = await toolSession.execute(
          _call('propose_planning_preferences', {
            'weekdays': [1, 3],
            'start_minute': 600,
          }),
        );
        expect(preferences.status, 'waitingForApproval');
        expect(fixture.preferenceProposals.prepareCalls, 1);
        expect(fixture.preferenceProposals.lastPreferences!.revision, 7);
        expect(fixture.preferenceProposals.lastPreferences!.weekdays, [1, 3]);
        expect(fixture.preferenceProposals.commitCalls, 0);

        final committed = await interactive.decidePending(true);
        expect(committed.status, 'committed');
        expect(fixture.preferenceProposals.commitCalls, 1);
        expect(fixture.preferences.value.revision, 8);
        expect(interactive.contextInvalidated, isTrue);
      },
    );

    test(
      'revoking a session revokes its plans and makes late decisions unusable',
      () async {
        final fixture = _Fixture();
        final tools = fixture.tools(_ReadTools(fixture.plans));
        final toolSession = tools.openSession();
        final interactive = toolSession as AgentInteractiveToolSession;
        final ticket = _ticket();
        interactive.bindRun(ticket, '新增任务');
        final prepared = await toolSession.execute(
          _call('propose_local_changes', {
            'changes': [
              {'type': 'create_task', 'local_key': 'new', 'title': '标题'},
            ],
          }),
        );
        expect(prepared.status, 'waitingForApproval');

        toolSession.revoke();
        expect(fixture.plans.revokedTickets, contains(same(ticket)));
        await expectLater(
          interactive.decidePending(true),
          throwsA(isA<AgentFailure>()),
        );
        expect(fixture.plans.commitCalls, 0);
      },
    );

    test(
      'planning tool registrations are closed and include all four tools',
      () {
        final tools = _Fixture().tools(_ReadTools(_Fixture().plans));
        final names = tools.definitions
            .map((definition) => definition.name)
            .toSet();
        expect(
          names,
          containsAll({
            'propose_local_changes',
            'propose_undo',
            'find_free_slots',
            'propose_planning_preferences',
          }),
        );
        final proposal = tools.definitions.singleWhere(
          (definition) => definition.name == 'propose_local_changes',
        );
        expect(proposal.parameters['additionalProperties'], isFalse);
      },
    );

    test('source tools stay unregistered without both source ports', () {
      final fixture = _Fixture();
      final tools = fixture.tools(_ReadTools(fixture.plans));
      final names = tools.definitions.map((value) => value.name).toSet();
      expect(
        names.intersection({
          'query_source_options',
          'request_source_refresh',
          'query_young_activities',
        }),
        isEmpty,
      );
    });

    test('教务选项只暴露短引用且拒绝提案不会刷新来源', () async {
      final fixture = _Fixture();
      final sources = _FakeSources();
      final records = _FakeActionRecords();
      final readTools = _ReadTools(fixture.plans);
      final tools = fixture.tools(
        readTools,
        sources: sources,
        actionRecords: records,
      );
      final session = tools.openSession();
      final interactive = session as AgentInteractiveToolSession;
      interactive.bindRun(_ticket(), '刷新教务课表 2026秋季学期');

      final options = await session.execute(_call('query_source_options', {}));
      expect(options.status, 'success');
      expect(options.data['account_bound'], isTrue);
      expect(options.data['credential_saved'], isTrue);
      final semester = (options.data['semesters'] as List).single as Map;
      expect(semester['label'], '2026秋季学期');
      expect(semester['last_used'], isTrue);
      expect(semester['semester_ref'], startsWith('semester_'));
      expect(semester.keys.toSet(), {'semester_ref', 'label', 'last_used'});
      expect(jsonEncode(options.data), isNot(contains('school-database-id')));

      final rawReference = await session.execute(
        _call('request_source_refresh', {
          'source': 'jw',
          'semester_ref': 'school-database-id',
        }),
      );
      expect(rawReference.status, 'invalidRequest');
      expect(records.prepareCalls, 0);

      final proposal = await session.execute(
        _call('request_source_refresh', {
          'source': 'jw',
          'semester_ref': semester['semester_ref'],
        }),
      );
      expect(proposal.status, 'waitingForApproval');
      expect(proposal.data['title'], '刷新教务学期');
      expect(records.lastRecord!.title, '刷新教务学期');
      expect(records.lastRecord!.details, ['来源：教务', '学期：2026秋季学期']);
      expect(jsonEncode(proposal.data), isNot(contains('2026秋季学期')));
      expect(
        jsonEncode(proposal.data),
        isNot(contains('private-c3-action-record-id')),
      );
      expect(sources.refreshCalls, 0);
      expect(records.prepareCalls, 1);
      expect(records.lastKind, AgentActionKind.sourceRefresh);

      final rejected = await interactive.decidePending(false);
      expect(rejected.status, 'rejected');
      expect(sources.refreshCalls, 0);
      expect(records.settledStatuses, [AgentActionStatus.rejected]);
    });

    test('81 个教务学期分页、重复短引用和记忆学期刷新提案受限', () async {
      final fixture = _Fixture();
      final sources = _FakeSources()
        ..semesterOptions = List<AgentSemesterOption>.generate(81, (index) {
          final label =
              '${List.filled(116, '学').join()}${index.toString().padLeft(4, '0')}';
          return AgentSemesterOption(
            'opaque-semester-$index',
            label,
            lastUsed: index == 80,
          );
        });
      final records = _FakeActionRecords();
      final tools = fixture.tools(
        _ReadTools(fixture.plans),
        sources: sources,
        actionRecords: records,
      );
      final session = tools.openSession();
      final interactive = session as AgentInteractiveToolSession;
      interactive.bindRun(_ticket(), '刷新教务课表');

      final definition = tools.definitions.singleWhere(
        (tool) => tool.name == 'query_source_options',
      );
      final properties = definition.parameters['properties'] as Map;
      expect(definition.parameters['additionalProperties'], isFalse);
      expect(definition.parameters['required'], isEmpty);
      expect((properties['semester_start'] as Map)['minimum'], 0);
      expect((properties['semester_start'] as Map)['maximum'], 256);
      expect((properties['semester_start'] as Map)['default'], 0);
      expect((properties['limit'] as Map)['minimum'], 1);
      expect((properties['limit'] as Map)['maximum'], 10);
      expect((properties['limit'] as Map)['default'], 10);

      final extra = await session.execute(
        _call('query_source_options', {'unexpected': true}),
      );
      expect(extra.status, 'invalidRequest');
      final wrongType = await session.execute(
        _call('query_source_options', {'semester_start': '10'}),
      );
      expect(wrongType.status, 'invalidRequest');
      final overLimit = await session.execute(
        _call('query_source_options', {'limit': 11}),
      );
      expect(overLimit.status, 'invalidRequest');

      Future<AgentToolResult> page(int start) => session.execute(
        _call('query_source_options', {'semester_start': start}),
      );

      final first = await page(0);
      expect(first.status, 'success');
      expect(first.data['total'], 81);
      expect(first.data['returned'], 10);
      expect(first.data['next_start'], 10);
      expect((first.data['semesters'] as List), hasLength(10));
      final remembered = first.data['remembered_semester'] as Map;
      expect(remembered['label'], sources.semesterOptions.last.label);
      expect(remembered['last_used'], isTrue);
      final firstResponseBytes = utf8.encode(jsonEncode(first.toMap())).length;
      expect(firstResponseBytes, lessThan(10000));

      var current = first;
      var currentStart = 0;
      AgentToolResult? pageTen;
      while (current.data['next_start'] is int) {
        final nextStart = current.data['next_start'] as int;
        currentStart = nextStart;
        current = await page(currentStart);
        if (currentStart == 10) pageTen = current;
      }
      expect(currentStart, 80);
      expect(current.data['returned'], 1);
      expect(current.data['next_start'], isNull);
      final finalSemester = (current.data['semesters'] as List).single as Map;
      expect(finalSemester['semester_ref'], remembered['semester_ref']);

      final repeatedPageTen = await page(10);
      expect(
        (repeatedPageTen.data['semesters'] as List)
            .map((item) => (item as Map)['semester_ref'])
            .toList(),
        (pageTen!.data['semesters'] as List)
            .map((item) => (item as Map)['semester_ref'])
            .toList(),
      );

      final proposal = await session.execute(
        _call('request_source_refresh', {
          'source': 'jw',
          'semester_ref': remembered['semester_ref'],
        }),
      );
      expect(proposal.status, 'waitingForApproval');
      expect(proposal.data['title'], '刷新教务学期');
      expect(records.lastRecord!.details, [
        '来源：教务',
        '学期：${sources.semesterOptions.last.label}',
      ]);
      expect(sources.refreshCalls, 0);
      expect((await interactive.decidePending(false)).status, 'rejected');
      expect(sources.refreshCalls, 0);
    });

    test(
      'JW refresh may use only the saved default when no term was named',
      () async {
        final fixture = _Fixture();
        final sources = _FakeSources();
        final records = _FakeActionRecords();
        final tools = fixture.tools(
          _ReadTools(fixture.plans),
          sources: sources,
          actionRecords: records,
        );
        final session = tools.openSession();
        final interactive = session as AgentInteractiveToolSession;
        interactive.bindRun(_ticket(), '同步教务课表');
        final proposal = await session.execute(
          _call('request_source_refresh', {'source': 'jw'}),
        );
        expect(proposal.status, 'waitingForApproval');
        expect(sources.refreshCalls, 0);
        final result = await interactive.decidePending(true);
        expect(result.status, 'committed');
        expect(sources.lastRequest?.semesterReference, 'school-database-id');
      },
    );

    test(
      'approved JW refresh uses fixed source port and invalidates old refs',
      () async {
        final fixture = _Fixture();
        final sources = _FakeSources();
        final records = _FakeActionRecords();
        final readTools = _ReadTools(fixture.plans);
        final tools = fixture.tools(
          readTools,
          sources: sources,
          actionRecords: records,
        );
        final session = tools.openSession();
        final interactive = session as AgentInteractiveToolSession;
        interactive.bindRun(_ticket(), '刷新教务课表 2026秋季学期');
        final oldTaskRef = readTools.taskRef;
        final options = await session.execute(
          _call('query_source_options', {}),
        );
        final semester = (options.data['semesters'] as List).single as Map;
        await session.execute(
          _call('request_source_refresh', {
            'source': 'jw',
            'semester_ref': semester['semester_ref'],
          }),
        );
        expect(sources.refreshCalls, 0);

        sources.hasReadProof = true;
        final committed = await interactive.decidePending(true);
        expect(committed.status, 'committed');
        expect(committed.data['committed'], isTrue);
        expect(sources.refreshCalls, 1);
        expect(sources.lastRequest?.source, AgentRefreshSource.jw);
        expect(sources.lastRequest?.semesterReference, 'school-database-id');
        expect(sources.lastRequest?.firstDay, isNull);
        expect(interactive.contextInvalidated, isTrue);
        expect(readTools.openCalls, 2);
        expect(sources.hasReadProof, isFalse);
        await session.validateDelivery();

        interactive.acknowledgeContextInvalidated();
        final stale = await session.execute(
          _call('propose_local_changes', {
            'changes': [
              {'type': 'update_task', 'task_ref': oldTaskRef, 'title': '改标题'},
            ],
          }),
        );
        expect(stale.status, 'stale');
        expect(fixture.plans.prepareCalls, 0);
      },
    );

    test(
      'Young refresh dates are strict half-open Beijing dates and bounded',
      () async {
        final fixture = _Fixture();
        final sources = _FakeSources();
        final records = _FakeActionRecords();
        final tools = fixture.tools(
          _ReadTools(fixture.plans),
          sources: sources,
          actionRecords: records,
        );
        final session = tools.openSession();
        final interactive = session as AgentInteractiveToolSession;
        interactive.bindRun(_ticket(), '刷新二课活动日历');

        final invalid = await session.execute(
          _call('request_source_refresh', {
            'source': 'youngCalendar',
            'first_day': '2026-02-30',
            'end_day_exclusive': '2026-03-01',
          }),
        );
        expect(invalid.status, 'invalidRequest');
        expect(records.prepareCalls, 0);
        expect(sources.refreshCalls, 0);

        final tooLong = await session.execute(
          _call('request_source_refresh', {
            'source': 'youngCalendar',
            'first_day': '2026-01-01',
            'end_day_exclusive': '2026-02-02',
          }),
        );
        expect(tooLong.status, 'invalidRequest');
        expect(records.prepareCalls, 0);

        final proposed = await session.execute(
          _call('request_source_refresh', {
            'source': 'youngCalendar',
            'first_day': '2026-01-01',
            'end_day_exclusive': '2026-02-01',
            'url': 'https://attacker.invalid/',
          }),
        );
        expect(proposed.status, 'invalidRequest');
        expect(records.prepareCalls, 0);

        final valid = await session.execute(
          _call('request_source_refresh', {
            'source': 'youngCalendar',
            'first_day': '2026-01-01',
            'end_day_exclusive': '2026-02-01',
          }),
        );
        expect(valid.status, 'waitingForApproval');
        expect(valid.data['title'], '刷新二课活动日历');
        expect(records.lastRecord!.title, '刷新二课活动日历');
        expect(records.lastRecord!.details, [
          '来源：二课活动日历',
          '日期：2026-01-01 至 2026-02-01（结束日不含）',
        ]);
        expect(sources.refreshCalls, 0);
        final committed = await interactive.decidePending(true);
        expect(committed.status, 'committed');
        expect(sources.refreshCalls, 1);
        expect(sources.lastRequest?.firstDay, DateTime.utc(2026, 1, 1));
        expect(sources.lastRequest?.endDayExclusive, DateTime.utc(2026, 2, 1));
      },
    );

    test(
      'Young activity query is explicit, read-only, capped and unverified',
      () async {
        final fixture = _Fixture();
        final sources = _FakeSources()..activityCount = 21;
        final tools = fixture.tools(
          _ReadTools(fixture.plans),
          sources: sources,
          actionRecords: _FakeActionRecords(),
        );
        final session = tools.openSession();
        final interactive = session as AgentInteractiveToolSession;
        interactive.bindRun(_ticket(), '查询二课活动');
        final result = await session.execute(
          _call('query_young_activities', {}),
        );
        expect(result.status, 'partial');
        expect(result.data['total'], 21);
        expect(result.data['returned'], 20);
        expect(result.data['truncated'], isTrue);
        expect(result.data['complete'], isFalse);
        expect(result.data['registration_verified'], isFalse);
        expect((result.data['activities'] as List), hasLength(20));
        expect(sources.activityCalls, 1);
        expect(sources.refreshCalls, 0);
        expect(fixture.plans.prepareCalls, 0);
        expect(interactive.contextInvalidated, isFalse);
      },
    );

    test('source read facts are rechecked before every delivery', () async {
      final fixture = _Fixture();
      final sources = _FakeSources()..activityCount = 1;
      final tools = fixture.tools(
        _ReadTools(fixture.plans),
        sources: sources,
        actionRecords: _FakeActionRecords(),
      );
      final session = tools.openSession();
      (session as AgentInteractiveToolSession).bindRun(_ticket(), '查询二课活动');
      expect(
        (await session.execute(_call('query_young_activities', {}))).status,
        'success',
      );
      await session.validateDelivery();
      sources.deliveryStale = true;
      await expectLater(
        session.validateDelivery(),
        throwsA(
          isA<AgentFailure>().having(
            (failure) => failure.code,
            'code',
            AgentFailureCode.staleContext,
          ),
        ),
      );
      expect(sources.activityCalls, 1);
    });

    test('青春科大活动核对只读取固定活动摘要', () async {
      final fixture = _Fixture();
      final sources = _FakeSources()..activityCount = 1;
      final tools = fixture.tools(
        _ReadTools(fixture.plans),
        sources: sources,
        actionRecords: _FakeActionRecords(),
      );
      final session = tools.openSession();
      (session as AgentInteractiveToolSession).bindRun(
        _ticket(),
        '帮我核对青春科大活动安排',
      );

      final result = await session.execute(_call('query_young_activities', {}));

      expect(result.status, 'success');
      expect(result.data['registration_verified'], isFalse);
      expect(sources.activityCalls, 1);
      expect(sources.refreshCalls, 0);
      expect(fixture.plans.prepareCalls, 0);
    });

    test(
      'source busy, challenge continuation and cancellation stay scoped',
      () async {
        final fixture = _Fixture();
        final sources = _FakeSources()..readOptionsBusy = true;
        final records = _FakeActionRecords();
        final tools = fixture.tools(
          _ReadTools(fixture.plans),
          sources: sources,
          actionRecords: records,
        );
        final session = tools.openSession();
        final interactive = session as AgentInteractiveToolSession;
        interactive.bindRun(_ticket(), '刷新教务课表 2026秋季学期');
        final busy = await session.execute(_call('query_source_options', {}));
        expect(busy.status, 'busy');
        expect(records.prepareCalls, 0);

        sources.readOptionsBusy = false;
        final proposal = await session.execute(
          _call('request_source_refresh', {'source': 'jw'}),
        );
        expect(proposal.status, 'waitingForApproval');
        sources.refreshBusy = true;
        final refreshBusy = await interactive.decidePending(true);
        expect(refreshBusy.status, 'busy');
        expect(interactive.pendingAction, isNotNull);
        expect(records.settledStatuses, isEmpty);

        var changeSeen = false;
        final changes = interactive.interactiveChanges.listen((_) {
          changeSeen = true;
        });
        sources.waiting = true;
        sources.emitChange();
        await Future<void>.delayed(Duration.zero);
        expect(changeSeen, isTrue);
        expect(interactive.waitingForSchool, isTrue);
        await interactive.continueSchool();
        expect(sources.continueCalls, 1);
        await changes.cancel();
        session.revoke();
        await Future<void>.delayed(Duration.zero);
        expect(sources.cancelCalls, 1);
        expect(records.settledStatuses, [AgentActionStatus.interrupted]);
        await tools.close();
        expect(sources.closeCalls, 1);
      },
    );

    test(
      'source permission failures stay typed and independent from request wording',
      () async {
        final fixture = _Fixture();
        final sources = _FakeSources()
          ..refreshFailure = const AgentFailure(
            AgentFailureCode.consentRequired,
          )
          ..activityFailure = 'consentRequired';
        final records = _FakeActionRecords();
        final tools = fixture.tools(
          _ReadTools(fixture.plans),
          sources: sources,
          actionRecords: records,
        );
        final session = tools.openSession();
        final interactive = session as AgentInteractiveToolSession;
        interactive.bindRun(_ticket(), '今天下午有什么安排？');

        final refreshProposal = await session.execute(
          _call('request_source_refresh', {'source': 'jw'}),
        );
        expect(refreshProposal.status, 'waitingForApproval');
        expect(interactive.pendingAction?.kind, AgentActionKind.sourceRefresh);
        expect(records.prepareCalls, 1);
        expect(sources.refreshCalls, 0);

        final deniedRefresh = await interactive.decidePending(true);
        expect(deniedRefresh.status, 'consentRequired');
        expect(deniedRefresh.failure, 'consentRequired');
        expect(interactive.pendingAction, isNotNull);
        expect(records.settledStatuses, isEmpty);
        expect(sources.refreshCalls, 1);

        expect((await interactive.decidePending(false)).status, 'rejected');
        final deniedActivities = await session.execute(
          _call('query_young_activities', {}),
        );
        expect(deniedActivities.status, 'consentRequired');
        expect(deniedActivities.failure, 'consentRequired');
        expect(deniedActivities.data, isEmpty);
        expect(sources.activityCalls, 1);
        expect(sources.refreshCalls, 1);
        expect(records.settledStatuses, [AgentActionStatus.rejected]);
        expect(interactive.pendingAction, isNull);
      },
    );
  });
}

ModelToolCall _call(String name, Map<String, Object?> arguments) =>
    ModelToolCall(id: 'call', name: name, argumentsJson: jsonEncode(arguments));

AgentRunTicket _ticket() => AgentRunTicket(
  authority: const AgentAuthority(
    owner: 'synthetic-agent-owner',
    resetEpoch: 1,
    historyEpoch: 1,
    configRevision: 1,
  ),
  runId: 'synthetic-run',
  conversationId: 'synthetic-conversation',
  conversationGeneration: 1,
  runGeneration: 1,
  assistantMessageId: 1,
);

AgentPlanningPreferences _preferences({int revision = 7}) =>
    AgentPlanningPreferences(
      revision: revision,
      weekdays: const [2],
      startMinute: 480,
      endMinute: 660,
      blockMinutes: 60,
      breakMinutes: 0,
    );

CalendarOccurrence _busyEvent() {
  final day = DateTime.utc(2026, 10, 13);
  final reference = CalendarReference(
    _context,
    const CalendarIdentity(CalendarKind.course, 1),
    1,
  );
  return CalendarOccurrence(
    reference: reference,
    title: 'Synthetic busy event',
    startsAtUtc: day.add(const Duration(hours: 1)),
    endsAtUtc: day.add(const Duration(hours: 2)),
  );
}

final class _Fixture {
  final _FakePlans plans = _FakePlans();
  final _FakeCalendar calendar = _FakeCalendar();
  final _FakeTasks tasks = _FakeTasks();
  final _FakePreferences preferences = _FakePreferences();
  late final _FakePreferenceProposals preferenceProposals =
      _FakePreferenceProposals(preferences);

  AgentActionTools tools(
    _ReadTools readTools, {
    AgentSourcePort? sources,
    AgentActionRecordPort? actionRecords,
  }) => AgentActionTools(
    readTools: readTools,
    plans: plans,
    calendar: calendar,
    tasks: tasks,
    preferences: preferences,
    preferenceProposals: preferenceProposals,
    sources: sources,
    actionRecords: actionRecords,
    clock: _clock,
  );
}

final class _ReadTools implements AgentReadToolsPort {
  _ReadTools(this.plans);
  final _FakePlans plans;
  int openCalls = 0;
  final List<_ReadSession> sessions = [];

  String get taskRef => 'task-ref-$openCalls';

  @override
  List<ModelToolDefinition> get definitions => [
    ModelToolDefinition(
      name: 'query_agenda',
      description: 'synthetic read tool',
      parameters: const {'type': 'object', 'additionalProperties': false},
    ),
  ];

  @override
  AgentToolSession openSession() {
    openCalls++;
    final session = _ReadSession(this, openCalls);
    sessions.add(session);
    return session;
  }

  @override
  Future<void> cancelAndDrain() async {}

  @override
  Future<void> close() async {}
}

final class _ReadSession
    implements
        AgentToolSession,
        AgentLocalReferenceSession,
        AgentDiscussionToolSession {
  _ReadSession(this.owner, this.generation);
  final _ReadTools owner;
  final int generation;
  bool revoked = false;
  AgentDiscussionSelection? lastDiscussionSelection;

  String get taskToken => 'task-ref-$generation';
  String get personalToken => 'personal-ref-$generation';
  String get blockToken => 'block-ref-$generation';

  @override
  List<AgentEvidence> get evidence => const [];

  @override
  Future<AgentToolResult> execute(ModelToolCall call) async =>
      AgentToolResult(status: 'empty');

  @override
  Future<void> validateDelivery() async {
    if (revoked) throw const AgentFailure(AgentFailureCode.cancelled);
  }

  @override
  Future<String> selectForDiscussion(AgentDiscussionSelection selection) async {
    _ensureCurrent();
    lastDiscussionSelection = selection;
    return 'synthetic discussion selection';
  }

  @override
  void revoke() {
    revoked = true;
  }

  @override
  Future<(CalendarReference, int)> resolveEventReference(String token) async {
    _ensureCurrent();
    final identity = switch (token) {
      _ when token == personalToken => const CalendarIdentity(
        CalendarKind.personal,
        11,
      ),
      _ when token == blockToken => const CalendarIdentity(
        CalendarKind.planBlock,
        12,
      ),
      _ => throw const CalendarFailure(CalendarFailureCode.staleReference),
    };
    return (CalendarReference(_context, identity, 1), owner.plans.revision);
  }

  @override
  Future<(TaskReference, int)> resolveTaskReference(String token) async {
    _ensureCurrent();
    if (token != taskToken) {
      throw const CalendarFailure(CalendarFailureCode.staleReference);
    }
    return (TaskReference(_context, 21, 1), owner.plans.revision);
  }

  void _ensureCurrent() {
    if (revoked || generation != owner.openCalls) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
  }
}

final class _FakePlans implements AgentLocalPlanPort {
  int revision = 4;
  int prepareCalls = 0;
  int approveCalls = 0;
  int rejectCalls = 0;
  int commitCalls = 0;
  final List<int> preparedChangeCounts = [];
  bool lastRequireFree = false;
  int? lastPreferencesRevision;
  AgentLocalPlan? lastPlan;
  final List<AgentRunTicket> revokedTickets = [];

  @override
  Future<(CalendarContext, int)> readPlanContext() async =>
      (_context, revision);

  @override
  Future<AgentLocalPlan> prepareLocalPlan(
    AgentRunTicket ticket,
    CalendarContext context,
    int revision,
    List<AgentLocalChange> changes, {
    bool requireFree = false,
    int? preferencesRevision,
  }) async {
    prepareCalls++;
    preparedChangeCounts.add(changes.length);
    lastRequireFree = requireFree;
    lastPreferencesRevision = preferencesRevision;
    final isUndo =
        changes.length == 1 &&
        changes.single is AgentCalendarChange &&
        (changes.single as AgentCalendarChange).intent is UndoCalendarWrite;
    final view = AgentActionView(
      id: 'agent-action-synthetic',
      kind: isUndo ? AgentActionKind.undo : AgentActionKind.localPlan,
      status: AgentActionStatus.proposed,
      title: 'private plan title',
      details: const ['SECRET_PRIVATE_NOTE'],
    );
    final plan = AgentLocalPlan(
      id: 'internal-plan-id',
      ticket: ticket,
      context: context,
      revision: revision,
      expiresAtUtc: _clock.nowUtc.add(const Duration(hours: 1)),
      changes: changes,
      view: view,
      requireFree: requireFree,
      preferencesRevision: preferencesRevision,
    );
    lastPlan = plan;
    return plan;
  }

  @override
  Future<AgentPlanApproval> approveLocalPlan(AgentLocalPlan plan) async {
    approveCalls++;
    return AgentPlanApproval(plan);
  }

  @override
  Future<void> rejectLocalPlan(AgentLocalPlan plan) async {
    rejectCalls++;
  }

  @override
  Future<AgentLocalPlanReceipt> commitLocalPlan(
    AgentPlanApproval approval,
  ) async {
    commitCalls++;
    revision++;
    return AgentLocalPlanReceipt(
      planId: approval.plan.id,
      revision: revision,
      committedCount: approval.plan.changes.length,
      committedAtUtc: _clock.nowUtc,
      replayed: false,
      view: approval.plan.view,
    );
  }

  @override
  void revokeLocalPlans(AgentRunTicket ticket) {
    revokedTickets.add(ticket);
  }
}

final class _FakeCalendar implements LocalCalendarPort {
  List<CalendarOccurrence> items = [];

  @override
  Stream<int> get changes => const Stream<int>.empty();

  @override
  Future<CalendarWindow> query(CalendarQuery query) async => CalendarWindow(
    context: _context,
    revision: 4,
    query: query,
    items: items,
    segments: const [],
    conflicts: const [],
    matched: items.length,
    truncated: false,
    conflictsTruncated: false,
  );

  @override
  Future<CalendarDetail> detail(CalendarReference reference) async {
    final occurrence = CalendarOccurrence(
      reference: reference,
      title: 'Synthetic detail',
      startsAtUtc: DateTime.utc(2026, 10, 13, 2),
      endsAtUtc: DateTime.utc(2026, 10, 13, 3),
    );
    return CalendarDetail(
      occurrence: occurrence,
      personalDraft: null,
      relations: const [],
    );
  }

  @override
  Future<CalendarCommand> prepare(
    CalendarContext context,
    CalendarIntent intent,
  ) async => throw UnimplementedError();

  @override
  Future<CalendarWriteReceipt> commit(CalendarCommand command) async =>
      throw UnimplementedError();
}

final class _FakeTasks implements LocalTaskPort {
  int taskDetailCalls = 0;
  CalendarUndoView undo = const CalendarUndoView();

  @override
  Future<TaskWindow> queryTasks(TaskQuery query) async =>
      throw UnimplementedError();

  @override
  Future<TaskDetail> taskDetail(TaskReference reference) async {
    taskDetailCalls++;
    throw UnimplementedError();
  }

  @override
  Future<CalendarUndoView> queryUndo(CalendarContext context) async => undo;
}

final class _FakePreferences implements AgentPreferencesPort {
  AgentPlanningPreferences value = _preferences();

  @override
  Future<AgentPlanningPreferences> readPlanningPreferences() async => value;

  @override
  Future<void> savePlanningPreferences(
    AgentPlanningPreferences expected,
  ) async {
    value = AgentPlanningPreferences(
      revision: value.revision + 1,
      weekdays: expected.weekdays,
      startMinute: expected.startMinute,
      endMinute: expected.endMinute,
      blockMinutes: expected.blockMinutes,
      breakMinutes: expected.breakMinutes,
      avoid: expected.avoid,
    );
  }
}

final class _FakePreferenceProposals implements AgentPreferencesProposalPort {
  _FakePreferenceProposals(this.preferences);
  final _FakePreferences preferences;
  int prepareCalls = 0;
  int commitCalls = 0;
  int rejectCalls = 0;
  AgentPlanningPreferences? lastPreferences;

  @override
  Future<AgentActionView> preparePreferencesPlan(
    AgentRunTicket ticket,
    AgentPlanningPreferences value,
  ) async {
    prepareCalls++;
    lastPreferences = value;
    return AgentActionView(
      id: 'agent-action-preferences',
      kind: AgentActionKind.planningPreferences,
      status: AgentActionStatus.proposed,
      title: 'private preferences',
      details: const ['SECRET_PREFERENCE_DETAILS'],
    );
  }

  @override
  Future<void> commitPreferencesPlan(
    AgentRunTicket ticket,
    AgentActionView record,
  ) async {
    commitCalls++;
    final value = lastPreferences!;
    await preferences.savePlanningPreferences(value);
  }

  @override
  Future<void> rejectPreferencesPlan(
    AgentRunTicket ticket,
    AgentActionView record,
  ) async {
    rejectCalls++;
  }
}

final class _FakeSources implements AgentSourcePort, AgentSourceDeliveryPort {
  final StreamController<void> _changes = StreamController<void>.broadcast();
  bool readOptionsBusy = false;
  bool refreshBusy = false;
  bool waiting = false;
  AgentFailure? refreshFailure;
  String? activityFailure;
  bool hasReadProof = false, deliveryStale = false;
  @override
  Future<void> validateDelivery() async {
    if (hasReadProof && deliveryStale) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
  }

  @override
  void clearReadReferences() => hasReadProof = false;
  int activityCount = 0;
  int refreshCalls = 0;
  int activityCalls = 0;
  int continueCalls = 0;
  int cancelCalls = 0;
  int closeCalls = 0;
  AgentSourceRequest? lastRequest;
  AgentActionView? lastApprovedRecord;
  List<AgentSemesterOption> semesterOptions = const [
    AgentSemesterOption('school-database-id', '2026秋季学期', lastUsed: true),
  ];

  @override
  bool get waitingForSchool => waiting;

  @override
  Stream<void> get changes => _changes.stream;

  void emitChange() => _changes.add(null);

  @override
  Future<AgentSourceOptions> readOptions(AgentRunTicket ticket) async {
    if (readOptionsBusy) throw const AgentFailure(AgentFailureCode.busy);
    return AgentSourceOptions(
      accountBound: true,
      credentialSaved: true,
      semesters: semesterOptions,
    );
  }

  @override
  Future<AgentSourceResult> refresh(
    AgentRunTicket ticket,
    AgentActionView approvedRecord,
    AgentSourceRequest request,
  ) async {
    refreshCalls++;
    lastRequest = request;
    lastApprovedRecord = approvedRecord;
    if (refreshBusy) throw const AgentFailure(AgentFailureCode.busy);
    if (refreshFailure case final failure?) throw failure;
    deliveryStale = hasReadProof;
    return AgentSourceResult(
      committed: true,
      count: 1,
      observedAtUtc: _clock.nowUtc,
      complete: true,
    );
  }

  @override
  Future<AgentSourceResult> queryActivities(AgentRunTicket ticket) async {
    activityCalls++;
    hasReadProof = true;
    return AgentSourceResult(
      committed: false,
      count: activityCount,
      observedAtUtc: _clock.nowUtc,
      complete: activityCount <= 20,
      failure: activityFailure,
      activities: [
        for (var index = 0; index < activityCount; index++)
          AgentActivityResult(
            title: 'Synthetic activity $index',
            place: 'Synthetic hall',
            startsAtUtc: DateTime.utc(2026, 10, 13, 1),
            endsAtUtc: DateTime.utc(2026, 10, 13, 2),
            registrationStartsAtUtc: DateTime.utc(2026, 10, 10),
            registrationEndsAtUtc: DateTime.utc(2026, 10, 12),
          ),
      ],
    );
  }

  @override
  Future<void> continueSchool() async {
    continueCalls++;
    waiting = false;
    emitChange();
  }

  @override
  Future<void> cancelAndDrain() async {
    cancelCalls++;
    waiting = false;
  }

  @override
  Future<void> close() async {
    closeCalls++;
    await _changes.close();
  }
}

final class _FakeActionRecords implements AgentActionRecordPort {
  int prepareCalls = 0;
  AgentActionKind? lastKind;
  AgentActionView? lastRecord;
  final List<AgentActionStatus> settledStatuses = [];

  @override
  Future<AgentActionView> prepareActionRecord(
    AgentRunTicket ticket,
    AgentActionKind kind,
    String title,
    List<String> details, {
    String warning = '',
  }) async {
    prepareCalls++;
    lastKind = kind;
    return lastRecord = AgentActionView(
      id: 'private-c3-action-record-id',
      kind: kind,
      status: AgentActionStatus.proposed,
      title: title,
      details: details,
      warning: warning,
    );
  }

  @override
  Future<void> settleActionRecord(
    AgentRunTicket ticket,
    AgentActionView record,
    AgentActionStatus status, {
    int committedCount = 0,
  }) async {
    settledStatuses.add(status);
  }
}
