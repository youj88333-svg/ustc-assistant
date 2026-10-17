import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/agent_action_tools.dart';
import 'package:ustc_assistant_m0/agent/agent_tool_contract.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/core/agent_action_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/agent_permission_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

final _clock = FixedClock(DateTime.utc(2026, 10, 14));
final _key = Uint8List.fromList('synthetic-reminder-agent-key'.codeUnits);

void main() {
  group('Agent reminder tools', () {
    test(
      'Android registration reaches Agent without an OS queue claim',
      () async {
        final fixture = await _open();
        final run = await fixture.run(
          capability: const NotificationCapability(
            available: true,
            enabledBySystem: true,
            schedulesAfterExit: true,
            activationAvailable: true,
            exactScheduling: false,
            queueEvidence: NotificationQueueEvidence.localRegistration,
            maximumPending: 480,
          ),
        );
        final result = await run.call('query_reminders', const {});
        final runtime = result.data['runtime'] as Map;
        expect(runtime['registration_evidence'], 'localRegistration');
        expect(runtime['exact_scheduling'], isFalse);
        expect(runtime['maximum_pending'], 480);
        expect(runtime['meaning'], contains('不是系统队列独立枚举'));
        expect(runtime['meaning'], contains('不保证实际送达'));
        await run.finish();
        await fixture.store.close();
      },
    );
    test(
      'mixed time-kind changes validate and apply reminder rules against the final target shape',
      () async {
        for (final reminderFirst in [false, true]) {
          final fixture = await _open();
          final event = await _seedEvent(
            fixture.store,
            PersonalEventDraft(
              title: '合成定时转全天',
              start: DateTime.utc(2026, 10, 18, 2),
              end: DateTime.utc(2026, 10, 18, 3),
            ),
          );
          final run = await fixture.run(events: {'shape-ref': event});
          final update = <String, Object?>{
            'type': 'update_personal',
            'event_ref': 'shape-ref',
            'scope': 'series',
            'all_day': true,
            'start': '2026-10-18',
            'end': '2026-10-19',
          };
          final reminder = <String, Object?>{
            'type': 'set_reminders',
            'event_ref': 'shape-ref',
            'reminders': [
              {'kind': 'dayTime', 'day_offset': -1, 'time': '18:00'},
              {'kind': 'none'},
            ],
          };
          expect(
            (await run.call('propose_local_changes', {
              'changes': reminderFirst
                  ? [reminder, update]
                  : [update, reminder],
            })).status,
            'waitingForApproval',
          );
          expect(
            (await run.interactive.decidePending(true)).status,
            'committed',
          );
          final current = await _occurrence(
            fixture.store,
            event.identity.localId,
            0,
          );
          final inspected = await fixture.store.features.inspectReminder(
            ReminderTarget.calendar(current),
          );
          expect(inspected.allDay, isTrue);
          expect(inspected.origin, ReminderPairOrigin.target);
          expect(inspected.pair.first.kind, ReminderRuleKind.dayTime);
          expect(inspected.pair.first.minuteOfDay, 1080);
          await run.finish();
          await fixture.store.close();
        }
        final fixture = await _open();
        final event = await _seedEvent(
          fixture.store,
          PersonalEventDraft(
            title: '合成不兼容规则',
            start: DateTime.utc(2026, 10, 18, 2),
            end: DateTime.utc(2026, 10, 18, 3),
          ),
        );
        final run = await fixture.run(events: {'shape-ref': event});
        expect(
          (await run.call('propose_local_changes', {
            'changes': [
              {
                'type': 'set_reminders',
                'event_ref': 'shape-ref',
                'reminders': [
                  {'kind': 'before', 'minutes_before': 60},
                  {'kind': 'none'},
                ],
              },
              {
                'type': 'update_personal',
                'event_ref': 'shape-ref',
                'scope': 'series',
                'all_day': true,
                'start': '2026-10-18',
                'end': '2026-10-19',
              },
            ],
          })).status,
          'invalidRequest',
        );
        expect(
          (await fixture.store.localCalendar.detail(event)).occurrence.allDay,
          isFalse,
        );
        expect(
          await fixture.store.features.readReminderPair(
            ReminderTarget.calendar(event),
          ),
          isNull,
        );
        await run.finish();
      },
    );

    test('query reports defaults, target shape, and inherited scope', () async {
      final fixture = await _open();
      final timed = await _seedEvent(
        fixture.store,
        PersonalEventDraft(
          title: '合成定时安排',
          start: DateTime.utc(2026, 10, 16, 2),
          end: DateTime.utc(2026, 10, 16, 3),
        ),
      );
      final allDay = await _seedEvent(
        fixture.store,
        PersonalEventDraft(
          title: '合成全天安排',
          start: DateTime.utc(2026, 10, 17),
          end: DateTime.utc(2026, 10, 18),
          allDay: true,
        ),
      );
      final series = await _seedEvent(
        fixture.store,
        PersonalEventDraft(
          title: '合成重复安排',
          start: DateTime.utc(2026, 10, 14, 4),
          end: DateTime.utc(2026, 10, 14, 5),
          weekly: true,
          untilDay: DateTime.utc(2026, 10, 28),
        ),
      );
      final occurrenceOne = await _occurrence(
        fixture.store,
        series.identity.localId,
        1,
      );
      final deadline = await _seedTask(
        fixture.store,
        TaskDraft(
          title: '合成有截止任务',
          deadlineAtUtc: DateTime.utc(2026, 10, 18, 2),
        ),
      );
      final noDeadline = await _seedTask(
        fixture.store,
        const TaskDraft(title: '合成无截止任务'),
      );
      const seriesPair = ReminderPair(
        ReminderRule.before(15),
        ReminderRule.none(),
      );
      const occurrencePair = ReminderPair(
        ReminderRule.before(45),
        ReminderRule.none(),
      );
      await fixture.store.features.saveReminderPair(
        ReminderTarget.calendar(series),
        seriesPair,
        series: true,
      );
      await fixture.store.features.saveReminderPair(
        ReminderTarget.calendar(series),
        occurrencePair,
      );

      final run = await fixture.run(
        events: {
          'timed-ref': timed,
          'all-day-ref': allDay,
          'series-ref': series,
          'occurrence-ref': occurrenceOne,
        },
        tasks: {'deadline-ref': deadline, 'no-deadline-ref': noDeadline},
      );
      final defaults = await run.call('query_reminders', const {});
      expect(defaults.status, 'success');
      final settings = defaults.data['settings'] as Map;
      expect(settings['enabled'], isFalse);
      expect(settings['morning_enabled'], isFalse);
      expect(settings['private_display'], isFalse);
      expect(settings['timed'], [
        {'kind': 'before', 'minutes_before': 30},
        {'kind': 'none'},
      ]);
      expect(settings['all_day_reminders'], [
        {'kind': 'dayTime', 'day_offset': 0, 'time': '09:00'},
        {'kind': 'none'},
      ]);
      final runtime = defaults.data['runtime'] as Map;
      expect(runtime['known'], isTrue);
      expect(runtime['system_enabled'], isFalse);
      expect(runtime['accepted'], 2);
      expect(runtime['desired'], 4);

      final timedResult = await run.call('query_reminders', {
        'event_ref': 'timed-ref',
      });
      final timedTarget = timedResult.data['target'] as Map;
      expect(timedTarget['all_day'], isFalse);
      expect(timedTarget['origin'], 'defaults');
      expect(timedTarget['eligible'], isTrue);
      expect(timedTarget['has_time'], isTrue);
      expect(timedTarget['reminders'], settings['timed']);

      final allDayResult = await run.call('query_reminders', {
        'event_ref': 'all-day-ref',
      });
      final allDayTarget = allDayResult.data['target'] as Map;
      expect(allDayTarget['all_day'], isTrue);
      expect(allDayTarget['origin'], 'defaults');
      expect(allDayTarget['reminders'], settings['all_day_reminders']);

      final exactResult = await run.call('query_reminders', {
        'event_ref': 'series-ref',
      });
      final exactTarget = exactResult.data['target'] as Map;
      expect(exactTarget['scope'], 'occurrence');
      expect(exactTarget['origin'], 'target');
      expect(exactTarget['reminders'], [
        {'kind': 'before', 'minutes_before': 45},
        {'kind': 'none'},
      ]);

      final inheritedResult = await run.call('query_reminders', {
        'event_ref': 'occurrence-ref',
      });
      final inheritedTarget = inheritedResult.data['target'] as Map;
      expect(inheritedTarget['origin'], 'series');
      expect(inheritedTarget['reminders'], [
        {'kind': 'before', 'minutes_before': 15},
        {'kind': 'none'},
      ]);

      final seriesResult = await run.call('query_reminders', {
        'event_ref': 'series-ref',
        'scope': 'series',
      });
      final seriesTarget = seriesResult.data['target'] as Map;
      expect(seriesTarget['scope'], 'series');
      expect(seriesTarget['origin'], 'series');
      expect(seriesTarget['reminders'], inheritedTarget['reminders']);

      final deadlineResult = await run.call('query_reminders', {
        'task_ref': 'deadline-ref',
      });
      final deadlineTarget = deadlineResult.data['target'] as Map;
      expect(deadlineTarget['eligible'], isTrue);
      expect(deadlineTarget['has_time'], isTrue);

      final noDeadlineResult = await run.call('query_reminders', {
        'task_ref': 'no-deadline-ref',
      });
      final noDeadlineTarget = noDeadlineResult.data['target'] as Map;
      expect(noDeadlineTarget['eligible'], isFalse);
      expect(noDeadlineTarget['eligibility_reason'], 'noDeadline');
      expect(noDeadlineTarget['has_time'], isFalse);
      await run.finish();
    });

    test(
      'approval, undo, and revision guards preserve manual reminder rules',
      () async {
        final fixture = await _open();
        var event = await _seedEvent(
          fixture.store,
          PersonalEventDraft(
            title: '合成提醒变更目标',
            start: DateTime.utc(2026, 10, 18, 2),
            end: DateTime.utc(2026, 10, 18, 3),
          ),
        );
        var target = ReminderTarget.calendar(event);
        const original = ReminderPair(
          ReminderRule.before(15),
          ReminderRule.none(),
        );
        const proposed = ReminderPair(
          ReminderRule.before(60),
          ReminderRule.none(),
        );
        await fixture.store.features.saveReminderPair(target, original);

        final staleChange = await fixture.run(events: {'event-ref': event});
        expect(
          (await _proposePair(staleChange, 'event-ref', 90)).status,
          'waitingForApproval',
        );
        const changedWhileWaiting = ReminderPair(
          ReminderRule.before(5),
          ReminderRule.none(),
        );
        await fixture.store.features.saveReminderPair(
          target,
          changedWhileWaiting,
        );
        expect(
          (await staleChange.interactive.decidePending(true)).status,
          'stale',
        );
        expect(
          (await fixture.store.features.readReminderPair(target))?.canonical,
          changedWhileWaiting.canonical,
        );
        await staleChange.finish();
        await fixture.store.features.saveReminderPair(target, original);

        final first = await fixture.run(events: {'event-ref': event});
        final waiting = await _proposePair(first, 'event-ref', 60);
        expect(waiting.status, 'waitingForApproval');
        expect(
          (await fixture.store.features.readReminderPair(target))?.canonical,
          original.canonical,
        );
        expect(
          (await first.interactive.decidePending(true)).status,
          'committed',
        );
        expect(
          (await fixture.store.features.readReminderPair(target))?.canonical,
          proposed.canonical,
        );
        await first.finish();

        final undo = await fixture.run(events: {'event-ref': event});
        expect(
          (await undo.call('propose_undo', const {})).status,
          'waitingForApproval',
        );
        expect(
          (await undo.interactive.decidePending(true)).status,
          'committed',
        );
        event = await _occurrence(
          fixture.store,
          event.identity.localId,
          event.identity.ordinal,
        );
        target = ReminderTarget.calendar(event);
        expect(
          (await fixture.store.features.readReminderPair(target))?.canonical,
          original.canonical,
        );
        await undo.finish();

        final next = await fixture.run(events: {'event-ref': event});
        expect(
          (await _proposePair(next, 'event-ref', 45)).status,
          'waitingForApproval',
        );
        expect(
          (await next.interactive.decidePending(true)).status,
          'committed',
        );
        await next.finish();

        final staleUndo = await fixture.run(events: {'event-ref': event});
        expect(
          (await staleUndo.call('propose_undo', const {})).status,
          'waitingForApproval',
        );
        const manual = ReminderPair(
          ReminderRule.before(5),
          ReminderRule.none(),
        );
        await fixture.store.features.saveReminderPair(target, manual);
        final stale = await staleUndo.interactive.decidePending(true);
        expect(stale.status, 'stale');
        expect(
          (await fixture.store.features.readReminderPair(target))?.canonical,
          manual.canonical,
        );
        await staleUndo.finish();

        final inherit = await fixture.run(events: {'event-ref': event});
        expect(
          (await inherit.call('propose_local_changes', {
            'changes': [
              {
                'type': 'set_reminders',
                'event_ref': 'event-ref',
                'inherit': true,
              },
            ],
          })).status,
          'waitingForApproval',
        );
        expect(
          (await fixture.store.features.readReminderPair(target))?.canonical,
          manual.canonical,
        );
        expect(
          (await inherit.interactive.decidePending(true)).status,
          'committed',
        );
        expect(await fixture.store.features.readReminderPair(target), isNull);
        final effective = await fixture.store.features.inspectReminder(target);
        expect(effective.origin, ReminderPairOrigin.defaults);
        expect(
          effective.pair.canonical,
          effective.settings.preferences.timed.canonical,
        );
        await inherit.finish();
      },
    );

    test('remembered reminder permission executes later proposals', () async {
      final fixture = await _open();
      final event = await _seedEvent(
        fixture.store,
        PersonalEventDraft(
          title: '合成记住权限目标',
          start: DateTime.utc(2026, 10, 18, 4),
          end: DateTime.utc(2026, 10, 18, 5),
        ),
      );
      final first = await fixture.run(events: {'event-ref': event});
      expect(
        (await _proposePair(first, 'event-ref', 30)).status,
        'waitingForApproval',
      );
      expect(
        (await first.remembered.approveAndRememberPending()).status,
        'committed',
      );
      expect(
        (await fixture.store.agent.readActionPermissions()).map(
          (permission) => permission.category,
        ),
        contains(AgentPermissionCategory.reminders),
      );
      await first.finish();

      final later = await fixture.run(events: {'event-ref': event});
      expect(
        (await _proposePair(later, 'event-ref', 10)).status,
        'waitingForApproval',
      );
      final automatic = await later.remembered.tryRememberedDecision();
      expect(automatic?.status, 'committed');
      const automaticallySaved = ReminderPair(
        ReminderRule.before(10),
        ReminderRule.none(),
      );
      expect(
        (await fixture.store.features.readReminderPair(
          ReminderTarget.calendar(event),
        ))?.canonical,
        automaticallySaved.canonical,
      );
      await later.finish();
    });

    test(
      'the existing 17-operation package does not authorize reminder categories',
      () async {
        final fixture = await _open();
        final event = await _seedEvent(
          fixture.store,
          PersonalEventDraft(
            title: '合成旧权限包目标',
            start: DateTime.utc(2026, 10, 18, 6),
            end: DateTime.utc(2026, 10, 18, 7),
          ),
        );
        final policy = await fixture.store.agent.readAgentUsePolicy();
        await fixture.store.agent.saveAgentUsePolicy(
          policy,
          personalContentAllowed: true,
          dailyOperationsAllowed: true,
        );
        final enabled = await fixture.store.agent.readAgentUsePolicy();
        expect(enabled.granted, hasLength(17));
        expect(
          enabled.granted,
          isNot(contains(AgentPermissionCategory.reminders)),
        );
        expect(
          enabled.granted,
          isNot(contains(AgentPermissionCategory.notificationPreferences)),
        );
        expect(
          enabled.granted,
          isNot(contains(AgentPermissionCategory.morningBrief)),
        );

        final run = await fixture.run(events: {'event-ref': event});
        final waiting = await run.call('propose_local_changes', {
          'changes': [
            {'type': 'set_notification_preferences', 'enabled': true},
          ],
        });
        expect(waiting.status, 'waitingForApproval');
        expect(await run.remembered.tryRememberedDecision(), isNull);
        expect(
          (await fixture.store.features.inspectReminders()).preferences.enabled,
          isFalse,
        );
        expect((await run.interactive.decidePending(true)).status, 'committed');
        final afterPatch = await fixture.store.features.inspectReminders();
        expect(afterPatch.preferences.enabled, isTrue);
        expect(afterPatch.preferences.privateDisplay, isFalse);
        expect(afterPatch.preferences.morningEnabled, isFalse);
        expect(
          afterPatch.preferences.timed.canonical,
          ReminderPair.timed.canonical,
        );
        expect(
          afterPatch.preferences.allDay.canonical,
          ReminderPair.allDay.canonical,
        );
        await run.finish();

        final reminderRun = await fixture.run(events: {'event-ref': event});
        expect(
          (await _proposePair(reminderRun, 'event-ref', 20)).status,
          'waitingForApproval',
        );
        expect(await reminderRun.remembered.tryRememberedDecision(), isNull);
        expect(
          await fixture.store.features.readReminderPair(
            ReminderTarget.calendar(event),
          ),
          isNull,
        );
        await reminderRun.finish();
      },
    );

    test(
      'advice-only and cancelled reminder proposals leave rules unchanged',
      () async {
        final fixture = await _open();
        final event = await _seedEvent(
          fixture.store,
          PersonalEventDraft(
            title: '合成建议与取消目标',
            start: DateTime.utc(2026, 10, 18, 8),
            end: DateTime.utc(2026, 10, 18, 9),
          ),
        );
        final target = ReminderTarget.calendar(event);

        final advice = await fixture.run(
          events: {'event-ref': event},
          adviceOnly: true,
        );
        expect(
          (await _proposePair(advice, 'event-ref', 60)).status,
          'waitingForApproval',
        );
        final adviceResult = await advice.remembered.tryRememberedDecision();
        expect(adviceResult?.status, 'adviceOnly');
        expect(adviceResult?.data['submitted'], isFalse);
        expect(await fixture.store.features.readReminderPair(target), isNull);
        await advice.finish();

        final cancelled = await fixture.run(events: {'event-ref': event});
        expect(
          (await _proposePair(cancelled, 'event-ref', 30)).status,
          'waitingForApproval',
        );
        cancelled.session.revoke();
        expect(await fixture.store.features.readReminderPair(target), isNull);
        await cancelled.finish();
      },
    );
  });
}

Future<AgentToolResult> _proposePair(_Run run, String reference, int minutes) =>
    run.call('propose_local_changes', {
      'changes': [
        {
          'type': 'set_reminders',
          'event_ref': reference,
          'reminders': [
            {'kind': 'before', 'minutes_before': minutes},
            {'kind': 'none'},
          ],
        },
      ],
    });

Future<_Fixture> _open() async {
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _SyntheticOwnership(),
    clock: _clock,
    modelCredentialProtector: _SyntheticProtector(),
  );
  addTearDown(store.close);
  await store.initialize();
  await store.agent.initializeAgent();
  await store.features.initialize();
  final settings = await store.agent.inspectAgent();
  await store.agent.saveModelConfiguration(
    settings.authority,
    modelId: 'synthetic-reminder-model',
    modelIds: const ['synthetic-reminder-model'],
    report: const AgentCapabilityReport(text: true, streaming: true),
    consent: true,
    key: _key,
  );
  return _Fixture(store);
}

final class _Fixture {
  _Fixture(this.store);
  final JwStore store;

  Future<_Run> run({
    Map<String, CalendarReference> events = const {},
    Map<String, TaskReference> tasks = const {},
    bool adviceOnly = false,
    NotificationCapability capability = const NotificationCapability(
      available: true,
      enabledBySystem: false,
      schedulesAfterExit: true,
      activationAvailable: true,
    ),
  }) async {
    final (_, revision) = await (store.localCalendar as AgentLocalPlanPort)
        .readPlanContext();
    final settings = await store.agent.inspectAgent();
    final conversation = await store.agent.createConversation();
    final ticket = await store.agent.beginRun(
      settings.authority,
      conversation,
      '仅用于合成提醒 Agent 工具测试',
    );
    final tools = AgentActionTools(
      readTools: _SyntheticReadTools(events, tasks, revision),
      plans: store.localCalendar,
      calendar: store.localCalendar,
      tasks: store.localCalendar,
      preferences: store.agent,
      preferenceProposals: store.agent,
      reminders: store.features,
      reminderRuntime: () =>
          ReminderRuntimeView(accepted: 2, desired: 4, capability: capability),
      clock: _clock,
    );
    final session = tools.openSession();
    final interactive = session as AgentInteractiveToolSession;
    interactive.bindRun(ticket, '仅用于合成提醒 Agent 工具测试');
    if (adviceOnly) {
      (session as AgentToolPolicySession).bindToolPolicy(
        ticket,
        personalContentAllowed: true,
        adviceOnly: true,
      );
    }
    return _Run(store, tools, ticket, session, interactive);
  }
}

final class _Run {
  _Run(this.store, this.tools, this.ticket, this.session, this.interactive);
  final JwStore store;
  final AgentActionTools tools;
  final AgentRunTicket ticket;
  final AgentToolSession session;
  final AgentInteractiveToolSession interactive;
  int _callSequence = 0;
  AgentRememberedToolSession get remembered =>
      session as AgentRememberedToolSession;

  Future<AgentToolResult> call(String name, Map<String, Object?> arguments) =>
      session.execute(
        ModelToolCall(
          id: 'reminder-test-call-${_callSequence++}',
          name: name,
          argumentsJson: jsonEncode(arguments),
        ),
      );

  Future<void> finish() async {
    await store.agent.finishRun(ticket, AgentMessageStatus.complete);
    await tools.close();
  }
}

Future<CalendarReference> _seedEvent(
  JwStore store,
  PersonalEventDraft draft,
) async {
  final plans = store.localCalendar as AgentLocalPlanPort;
  final (context, _) = await plans.readPlanContext();
  final receipt = await store.localCalendar.commit(
    await store.localCalendar.prepare(context, CreatePersonalEvent(draft)),
  );
  return receipt.target!;
}

Future<TaskReference> _seedTask(JwStore store, TaskDraft draft) async {
  final plans = store.localCalendar as AgentLocalPlanPort;
  final (context, _) = await plans.readPlanContext();
  final receipt = await store.localCalendar.commit(
    await store.localCalendar.prepare(context, CreateTask(draft)),
  );
  return receipt.task!;
}

Future<CalendarReference> _occurrence(
  JwStore store,
  int localId,
  int ordinal,
) async {
  final window = await store.localCalendar.query(
    CalendarQuery(
      firstDay: DateTime.utc(2026, 10, 14),
      endDayExclusive: DateTime.utc(2026, 10, 29),
      filter: CalendarFilter.personal,
    ),
  );
  return window.items
      .singleWhere(
        (item) =>
            item.reference.identity.localId == localId &&
            item.reference.identity.ordinal == ordinal,
      )
      .reference;
}

final class _SyntheticReadTools implements AgentReadToolsPort {
  _SyntheticReadTools(this.events, this.tasks, this.revision);
  final Map<String, CalendarReference> events;
  final Map<String, TaskReference> tasks;
  final int revision;

  @override
  List<ModelToolDefinition> get definitions => [
    ModelToolDefinition(
      name: 'query_agenda',
      description: 'synthetic reference fixture',
      parameters: const {'type': 'object', 'additionalProperties': false},
    ),
  ];

  @override
  AgentToolSession openSession() =>
      _SyntheticReadSession(events, tasks, revision);

  @override
  Future<void> cancelAndDrain() async {}

  @override
  Future<void> close() async {}
}

final class _SyntheticReadSession
    implements AgentToolSession, AgentLocalReferenceSession {
  _SyntheticReadSession(this.events, this.tasks, this.revision);
  final Map<String, CalendarReference> events;
  final Map<String, TaskReference> tasks;
  final int revision;
  bool _revoked = false;

  @override
  List<AgentEvidence> get evidence => const [];

  @override
  Future<AgentToolResult> execute(ModelToolCall call) async =>
      AgentToolResult(status: 'empty');

  @override
  Future<void> validateDelivery() async {
    if (_revoked) throw const AgentFailure(AgentFailureCode.cancelled);
  }

  @override
  void revoke() => _revoked = true;

  @override
  Future<(CalendarReference, int)> resolveEventReference(String token) async {
    final reference = events[token];
    if (reference == null) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    return (reference, revision);
  }

  @override
  Future<(TaskReference, int)> resolveTaskReference(String token) async {
    final reference = tasks[token];
    if (reference == null) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    return (reference, revision);
  }
}

final class _SyntheticOwnership implements AssetOwnership {
  @override
  bool get isHeld => true;
  @override
  void ensureHeld() {}
}

final class _SyntheticProtector implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-agent-reminder-protector/v1';

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
