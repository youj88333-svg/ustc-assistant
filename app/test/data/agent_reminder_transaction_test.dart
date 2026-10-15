import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agent_action_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/agent_permission_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

final _clock = FixedClock(DateTime.utc(2026, 10, 15, 0));
final _key = Uint8List.fromList('synthetic-agent-reminder-key'.codeUnits);
final _day = DateTime.utc(2026, 10, 15);
const _oldTimed = ReminderPair(ReminderRule.before(15), ReminderRule.before(5));
const _oldAllDay = ReminderPair(
  ReminderRule.dayTime(dayOffset: -1, minuteOfDay: 480),
  ReminderRule.none(),
);
const _newTimed = ReminderPair(
  ReminderRule.before(0),
  ReminderRule.before(10080),
);
const _newAllDay = ReminderPair(
  ReminderRule.dayTime(dayOffset: -7, minuteOfDay: 0),
  ReminderRule.dayTime(dayOffset: 7, minuteOfDay: 1439),
);

void main() {
  test(
    'one C3 commit and shared undo each capture reminder expectations once',
    () async {
      final store = await _open();
      final event = await _seedEvent(store, note: '原有合成备注');
      final target = ReminderTarget.calendar(event);
      await store.features.saveReminderPair(target, _oldTimed);
      await _setBaselinePreferences(store);
      await _installCaptureCounter(store);

      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();
      final (expectedBefore, _) = await _expectedSnapshot(store);
      final plan = await planPort
          .prepareLocalPlan(await _ticket(store), context, revision, [
            AgentCalendarChange(
              SetPersonalOccurrenceState(event, completed: true),
            ),
            AgentPersonalPatch(event, entireSeries: true, note: '更新后的合成备注'),
            AgentReminderChange(target, _newTimed),
            const AgentNotificationPreferencesPatch(
              enabled: true,
              privateDisplay: true,
              morningEnabled: true,
              timed: _newTimed,
              allDay: _newAllDay,
            ),
          ]);
      final approval = await (store.localCalendar as AgentLocalPermissionPort)
          .authorizeLocalPlan(
            plan,
            mode: AgentAuthorizationMode.confirmed,
            remember: true,
          );
      expect(approval, isNotNull);
      final receipt = await planPort.commitLocalPlan(approval!);

      final (afterContext, afterRevision) = await planPort.readPlanContext();
      expect(afterContext, context);
      expect(afterRevision, revision + 1);
      expect(receipt.replayed, isFalse);
      expect(receipt.committedCount, 4);
      expect(receipt.undo, isNotNull);
      expect(await _count(store, 'agenda_plan_receipts'), 1);
      expect(await _count(store, 'agenda_plan_audit'), 1);
      expect(await _captureCount(store), 1);
      final expectedAfterCommit = await _expectedSnapshot(store);
      expect(expectedAfterCommit.$1, expectedBefore + 1);
      final encodedInput =
          jsonDecode(expectedAfterCommit.$2!) as Map<String, dynamic>;
      expect(encodedInput['preferences'][1], _newTimed.canonical);
      expect(encodedInput['preferences'][2], _newAllDay.canonical);
      final savedOverride = (encodedInput['overrides'] as List).single as List;
      expect(savedOverride[0], 'personal');
      expect(savedOverride[1], event.identity.localId);
      expect(savedOverride[2], event.identity.ordinal);
      expect(savedOverride[3], _newTimed.canonical);
      expect((encodedInput['exceptions'] as List).single[3], isTrue);
      final serializedDraft =
          ((encodedInput['personal'] as List).single as List)[2] as List;
      expect(serializedDraft[7], isEmpty);

      final committed = await _currentEvent(store, event.identity.localId);
      final committedDetail = await store.localCalendar.detail(
        committed.reference,
      );
      expect(committed.completed, isTrue);
      expect(committedDetail.personalDraft!.note, '更新后的合成备注');
      final committedTarget = ReminderTarget.calendar(committed.reference);
      expect(
        (await store.features.readReminderPair(committedTarget))!.canonical,
        _newTimed.canonical,
      );
      final settings = await store.features.inspectReminders();
      expect(settings.preferences.enabled, isTrue);
      expect(settings.preferences.privateDisplay, isTrue);
      expect(settings.preferences.morningEnabled, isTrue);
      expect(settings.preferences.timed.canonical, _newTimed.canonical);
      expect(settings.preferences.allDay.canonical, _newAllDay.canonical);
      expect(
        (await store.agent.readActionPermissions())
            .map((permission) => permission.category)
            .toSet(),
        {
          AgentPermissionCategory.reminders,
          AgentPermissionCategory.notificationPreferences,
          AgentPermissionCategory.morningBrief,
          AgentPermissionCategory.statePersonal,
          AgentPermissionCategory.updatePersonal,
        },
      );

      await store.customStatement(
        'UPDATE synthetic_expected_capture_count SET count=0',
      );
      final undo = await store.localCalendar.prepare(
        context,
        UndoCalendarWrite(receipt.undo!),
      );
      await store.localCalendar.commit(undo);

      final restored = await _currentEvent(store, event.identity.localId);
      final restoredDetail = await store.localCalendar.detail(
        restored.reference,
      );
      expect(restored.completed, isFalse);
      expect(restoredDetail.personalDraft!.note, '原有合成备注');
      final restoredTarget = ReminderTarget.calendar(restored.reference);
      expect(
        (await store.features.readReminderPair(restoredTarget))!.canonical,
        _oldTimed.canonical,
      );
      final restoredSettings = await store.features.inspectReminders();
      expect(restoredSettings.preferences.enabled, isFalse);
      expect(restoredSettings.preferences.privateDisplay, isFalse);
      expect(restoredSettings.preferences.morningEnabled, isFalse);
      expect(restoredSettings.preferences.timed.canonical, _oldTimed.canonical);
      expect(
        restoredSettings.preferences.allDay.canonical,
        _oldAllDay.canonical,
      );
      expect(await _captureCount(store), 1);
      expect((await _expectedSnapshot(store)).$1, expectedBefore + 2);
      expect(await _count(store, 'agenda_plan_receipts'), 1);
      expect(await _count(store, 'agenda_plan_audit'), 1);
    },
  );

  test(
    'final C3 checkpoint failure rolls back business, reminders, expected state, undo and remembered permissions',
    () async {
      var failFinalCheckpoint = false;
      final store = await _open(
        onAgentCheckpoint: () async {
          if (failFinalCheckpoint) {
            throw StateError('synthetic final reminder checkpoint failure');
          }
        },
      );
      final event = await _seedEvent(store, note: '故障前备注');
      final target = ReminderTarget.calendar(event);
      await store.features.saveReminderPair(target, _oldTimed);
      await _setBaselinePreferences(store);
      final priorUndo = await store.localCalendar.queryUndo(event.context);
      await _installCaptureCounter(store);
      final expectedBefore = await _expectedSnapshot(store);
      final reminderRevisionBefore =
          (await store.features.inspectReminders()).revision;
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();
      final plan = await planPort
          .prepareLocalPlan(await _ticket(store), context, revision, [
            AgentCalendarChange(
              SetPersonalOccurrenceState(event, completed: true),
            ),
            AgentPersonalPatch(event, entireSeries: true, note: '不得写入'),
            AgentReminderChange(target, _newTimed),
            const AgentNotificationPreferencesPatch(
              enabled: true,
              privateDisplay: true,
              morningEnabled: true,
              timed: _newTimed,
              allDay: _newAllDay,
            ),
          ]);
      final permissionPort = store.localCalendar as AgentLocalPermissionPort;
      final approval = await permissionPort.authorizeLocalPlan(
        plan,
        mode: AgentAuthorizationMode.confirmed,
        remember: true,
      );
      expect(approval, isNotNull);
      failFinalCheckpoint = true;

      await _expectCalendarFailure(
        planPort.commitLocalPlan(approval!),
        CalendarFailureCode.storageFailed,
      );

      expect((await planPort.readPlanContext()).$2, revision);
      final unchanged = await _currentEvent(store, event.identity.localId);
      final detail = await store.localCalendar.detail(unchanged.reference);
      expect(unchanged.completed, isFalse);
      expect(detail.personalDraft!.note, '故障前备注');
      expect(
        (await store.features.readReminderPair(target))!.canonical,
        _oldTimed.canonical,
      );
      final settings = await store.features.inspectReminders();
      expect(settings.preferences.enabled, isFalse);
      expect(settings.preferences.privateDisplay, isFalse);
      expect(settings.preferences.morningEnabled, isFalse);
      expect(settings.preferences.timed.canonical, _oldTimed.canonical);
      expect(settings.preferences.allDay.canonical, _oldAllDay.canonical);
      expect(settings.revision, reminderRevisionBefore);
      expect(await _expectedSnapshot(store), expectedBefore);
      expect(await _captureCount(store), 0);
      expect(await _count(store, 'agenda_plan_receipts'), 0);
      expect(await _count(store, 'agenda_plan_audit'), 0);
      expect(await _count(store, 'agenda_undo'), 1);
      _expectSameUndo(priorUndo, await store.localCalendar.queryUndo(context));
      expect(await store.agent.readActionPermissions(), isEmpty);
    },
  );

  test(
    'manual reminder edit after preparation invalidates the plan without changing agenda revision',
    () async {
      final store = await _open();
      final event = await _seedEvent(store);
      final target = ReminderTarget.calendar(event);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();
      final plan = await planPort.prepareLocalPlan(
        await _ticket(store),
        context,
        revision,
        [AgentReminderChange(target, _newTimed)],
      );

      await store.features.saveReminderPair(target, _oldTimed);

      expect((await planPort.readPlanContext()).$2, revision);
      await _expectCalendarFailure(
        planPort.approveLocalPlan(plan),
        CalendarFailureCode.staleReference,
      );
      expect(
        (await store.features.readReminderPair(target))!.canonical,
        _oldTimed.canonical,
      );
      expect(await _count(store, 'agenda_plan_receipts'), 0);
      expect(await _count(store, 'agenda_plan_audit'), 0);
    },
  );

  test(
    'manual reminder edit after commit makes the shared undo conflict instead of overwriting it',
    () async {
      final store = await _open();
      final event = await _seedEvent(store, note: '提交前备注');
      final target = ReminderTarget.calendar(event);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();
      final plan = await planPort
          .prepareLocalPlan(await _ticket(store), context, revision, [
            AgentCalendarChange(
              SetPersonalOccurrenceState(event, completed: true),
            ),
            AgentPersonalPatch(event, entireSeries: true, note: '计划内备注'),
            AgentReminderChange(target, _newTimed),
          ]);
      final receipt = await planPort.commitLocalPlan(
        await planPort.approveLocalPlan(plan),
      );
      expect(receipt.undo, isNotNull);
      final (afterContext, afterRevision) = await planPort.readPlanContext();
      expect(afterContext, context);
      expect(afterRevision, revision + 1);

      final committedEvent = await _currentEvent(store, event.identity.localId);
      final committedTarget = ReminderTarget.calendar(committedEvent.reference);
      await store.features.saveReminderPair(committedTarget, _oldTimed);
      expect((await planPort.readPlanContext()).$2, afterRevision);
      final undoCommand = await store.localCalendar.prepare(
        context,
        UndoCalendarWrite(receipt.undo!),
      );
      await _expectCalendarFailure(
        store.localCalendar.commit(undoCommand),
        CalendarFailureCode.undoConflict,
      );

      final current = await _currentEvent(store, event.identity.localId);
      final detail = await store.localCalendar.detail(current.reference);
      expect(current.completed, isTrue);
      expect(detail.personalDraft!.note, '计划内备注');
      expect(
        (await store.features.readReminderPair(committedTarget))!.canonical,
        _oldTimed.canonical,
      );
      expect(await _count(store, 'agenda_plan_receipts'), 1);
      expect(await _count(store, 'agenda_plan_audit'), 1);
    },
  );

  test(
    'forged approval and revoked plan cannot submit reminder changes',
    () async {
      final store = await _open();
      final event = await _seedEvent(store);
      final target = ReminderTarget.calendar(event);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();
      final ticket = await _ticket(store);
      final plan = await planPort.prepareLocalPlan(ticket, context, revision, [
        AgentReminderChange(target, _newTimed),
      ]);

      await _expectAgentFailure(
        planPort.commitLocalPlan(AgentPlanApproval(plan)),
        AgentFailureCode.staleContext,
      );
      final approval = await (store.localCalendar as AgentLocalPermissionPort)
          .authorizeLocalPlan(plan, mode: AgentAuthorizationMode.confirmed);
      expect(approval, isNotNull);
      planPort.revokeLocalPlans(ticket);
      await _expectAgentFailure(
        planPort.commitLocalPlan(approval!),
        AgentFailureCode.staleContext,
      );

      expect((await planPort.readPlanContext()).$2, revision);
      expect(await store.features.readReminderPair(target), isNull);
      expect(await _count(store, 'agenda_plan_receipts'), 0);
      expect(await _count(store, 'agenda_plan_audit'), 0);
      expect(await store.agent.readActionPermissions(), isEmpty);
    },
  );

  test(
    'all-day personal series reminder transaction preserves inherited exact rules on undo',
    () async {
      final store = await _open();
      final event = await _seedEvent(
        store,
        allDay: true,
        weekly: true,
        untilDay: DateTime.utc(2026, 10, 29),
      );
      final target = ReminderTarget.calendar(event);
      final planPort = store.localCalendar as AgentLocalPlanPort;
      final (context, revision) = await planPort.readPlanContext();
      final plan = await planPort.prepareLocalPlan(
        await _ticket(store),
        context,
        revision,
        [AgentReminderChange(target, _newAllDay, series: true)],
      );
      final receipt = await planPort.commitLocalPlan(
        await planPort.approveLocalPlan(plan),
      );

      expect(
        (await store.features.readReminderPair(
          target,
          series: true,
        ))!.canonical,
        _newAllDay.canonical,
      );
      expect(await store.features.readReminderPair(target), isNull);
      expect(
        (await store.features.inspectReminder(target, series: true)).allDay,
        isTrue,
      );
      final undo = await store.localCalendar.prepare(
        context,
        UndoCalendarWrite(receipt.undo!),
      );
      await store.localCalendar.commit(undo);

      final restoredTarget = ReminderTarget.calendar(
        (await _currentEvent(store, event.identity.localId)).reference,
      );
      expect(
        await store.features.readReminderPair(restoredTarget, series: true),
        isNull,
      );
      expect(await store.features.readReminderPair(restoredTarget), isNull);
      expect(
        (await store.features.inspectReminder(
          restoredTarget,
          series: true,
        )).origin,
        ReminderPairOrigin.defaults,
      );
    },
  );
}

Future<JwStore> _open({Future<void> Function()? onAgentCheckpoint}) async {
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _SyntheticOwnership(),
    clock: _clock,
    modelCredentialProtector: _SyntheticProtector(),
    onAgentCheckpoint: onAgentCheckpoint,
  );
  try {
    await store.initialize();
    await store.agent.initializeAgent();
    await store.features.initialize();
    await _configure(store);
  } catch (_) {
    await store.close();
    rethrow;
  }
  addTearDown(store.close);
  return store;
}

Future<void> _configure(JwStore store) async {
  final snapshot = await store.agent.inspectAgent();
  await store.agent.saveModelConfiguration(
    snapshot.authority,
    modelId: 'synthetic-reminder-model',
    modelIds: const ['synthetic-reminder-model'],
    report: const AgentCapabilityReport(text: true, streaming: true),
    consent: true,
    key: _key,
  );
}

Future<AgentRunTicket> _ticket(JwStore store) async {
  final snapshot = await store.agent.inspectAgent();
  final conversation = await store.agent.createConversation();
  return store.agent.beginRun(
    snapshot.authority,
    conversation,
    '只用于本地合成提醒事务回归',
  );
}

Future<CalendarReference> _seedEvent(
  JwStore store, {
  String note = '',
  bool allDay = false,
  bool weekly = false,
  DateTime? untilDay,
}) async {
  final (context, _) = await (store.localCalendar as AgentLocalPlanPort)
      .readPlanContext();
  final receipt = await _write(
    store,
    context,
    CreatePersonalEvent(
      PersonalEventDraft(
        title: '合成提醒事务日程',
        start: allDay ? _day : DateTime.utc(2026, 10, 15, 2),
        end: allDay
            ? _day.add(const Duration(days: 1))
            : DateTime.utc(2026, 10, 15, 3),
        allDay: allDay,
        weekly: weekly,
        untilDay: untilDay,
        note: note,
      ),
    ),
  );
  return receipt.target!;
}

Future<CalendarOccurrence> _currentEvent(JwStore store, int localId) async =>
    (await store.localCalendar.query(_query())).items.singleWhere(
      (item) =>
          item.reference.identity.kind == CalendarKind.personal &&
          item.reference.identity.localId == localId &&
          item.reference.identity.ordinal == 0,
    );

CalendarQuery _query() => CalendarQuery(
  firstDay: _day,
  endDayExclusive: DateTime.utc(2026, 11, 1),
  includeSkipped: true,
  filter: CalendarFilter.all,
);

Future<void> _setBaselinePreferences(JwStore store) async {
  final settings = await store.features.inspectReminders();
  await store.features.saveReminderPreferences(
    settings,
    settings.preferences.copyWith(
      enabled: false,
      privateDisplay: false,
      morningEnabled: false,
      timed: _oldTimed,
      allDay: _oldAllDay,
    ),
  );
}

Future<void> _installCaptureCounter(JwStore store) async {
  await store.customStatement(
    'CREATE TABLE synthetic_expected_capture_count(count INTEGER NOT NULL)',
  );
  await store.customStatement(
    'INSERT INTO synthetic_expected_capture_count(count) VALUES(0)',
  );
  await store.customStatement('''
    CREATE TRIGGER synthetic_expected_capture_update
    AFTER UPDATE ON m6_expected
    BEGIN
      UPDATE synthetic_expected_capture_count SET count=count+1;
    END
  ''');
}

Future<int> _captureCount(JwStore store) async =>
    (await store
            .customSelect('SELECT count FROM synthetic_expected_capture_count')
            .getSingle())
        .read<int>('count');

Future<(int, String?)> _expectedSnapshot(JwStore store) async {
  final row = await store
      .customSelect(
        'SELECT revision,input_json FROM m6_expected WHERE singleton=1',
      )
      .getSingle();
  return (row.read<int>('revision'), row.read<String?>('input_json'));
}

Future<CalendarWriteReceipt> _write(
  JwStore store,
  CalendarContext context,
  CalendarIntent intent,
) async => store.localCalendar.commit(
  await store.localCalendar.prepare(context, intent),
);

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
  String get mechanism => 'synthetic-agent-reminder-protector/v1';

  @override
  Future<Uint8List> protect(
    Uint8List plaintext, {
    required String purpose,
  }) async =>
      Uint8List.fromList([0xB4, ...plaintext.map((byte) => byte ^ 0x36)]);

  @override
  Future<Uint8List> unprotect(
    Uint8List ciphertext, {
    required String purpose,
  }) async => Uint8List.fromList(
    ciphertext.skip(1).map((byte) => byte ^ 0x36).toList(),
  );
}

final class _SyntheticOwnership implements AssetOwnership {
  @override
  bool get isHeld => true;

  @override
  void ensureHeld() {}
}
