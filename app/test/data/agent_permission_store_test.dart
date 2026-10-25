import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/core/agent_action_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/agent_permission_contract.dart';
import 'package:ustc_assistant_m0/core/agent_source_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';

final _clock = FixedClock(DateTime.utc(2026, 10, 13, 8));
final _syntheticKey = Uint8List.fromList(
  'synthetic-permission-test-key'.codeUnits,
);

void main() {
  test(
    'remembered local grants commit now and authorize a later run',
    () async {
      final store = await _open();
      final permissions = store.localCalendar as AgentLocalPermissionPort;
      final plans = store.localCalendar as AgentLocalPlanPort;

      final firstTicket = await _ticket(store);
      final firstPlan = await _taskPlan(store, firstTicket, '记住后首次提交的合成任务');
      final firstApproval = await permissions.authorizeLocalPlan(
        firstPlan,
        mode: AgentAuthorizationMode.confirmed,
        remember: true,
      );
      expect(firstApproval, isNotNull);
      final firstCommit = await plans.commitLocalPlan(firstApproval!);
      expect(firstCommit.replayed, isFalse);
      await store.agent.finishRun(firstTicket, AgentMessageStatus.complete);

      final grants = await store.agent.readActionPermissions();
      expect(grants.map((grant) => grant.category), [
        AgentPermissionCategory.createTask,
      ]);
      expect(grants.single.category.tool, 'propose_local_changes');

      final nextTicket = await _ticket(store);
      final nextPlan = await _taskPlan(store, nextTicket, '记住后自动提交的合成任务');
      final automaticApproval = await permissions.authorizeLocalPlan(
        nextPlan,
        mode: AgentAuthorizationMode.remembered,
      );
      expect(automaticApproval, isNotNull);
      final nextCommit = await plans.commitLocalPlan(automaticApproval!);

      expect(nextCommit.replayed, isFalse);
      expect((await _tasks(store)).length, 2);
      expect(await _count(store, 'agenda_plan_receipts'), 2);
      expect(await _count(store, 'agenda_plan_audit'), 2);
    },
  );

  test('a remembered permission survives reopening SQLite', () async {
    final file = await _temporaryDatabase();
    var store = await _openAt(file);
    final ticket = await _ticket(store);
    final plan = await _taskPlan(store, ticket, '重启前的合成记住任务');
    final approval = await (store.localCalendar as AgentLocalPermissionPort)
        .authorizeLocalPlan(
          plan,
          mode: AgentAuthorizationMode.confirmed,
          remember: true,
        );
    expect(approval, isNotNull);
    await (store.localCalendar as AgentLocalPlanPort).commitLocalPlan(
      approval!,
    );
    await store.agent.finishRun(ticket, AgentMessageStatus.complete);
    await store.close();

    store = await _openAt(file, configure: false);
    final grants = await store.agent.readActionPermissions();
    expect(grants.map((grant) => grant.category), [
      AgentPermissionCategory.createTask,
    ]);

    final resumedTicket = await _ticket(store);
    final resumedPlan = await _taskPlan(store, resumedTicket, '重启后的合成记住任务');
    final resumedApproval =
        await (store.localCalendar as AgentLocalPermissionPort)
            .authorizeLocalPlan(
              resumedPlan,
              mode: AgentAuthorizationMode.remembered,
            );
    expect(resumedApproval, isNotNull);
    await (store.localCalendar as AgentLocalPlanPort).commitLocalPlan(
      resumedApproval!,
    );
    expect((await _tasks(store)).length, 2);
  });

  test(
    'remembered delete and mixed plans fail closed without grants',
    () async {
      final store = await _open();
      final target = await _seedPersonalEvent(store);
      await _establishTaskGrant(store);
      final ticket = await _ticket(store);
      final localPermission = store.localCalendar as AgentLocalPermissionPort;
      final plans = store.localCalendar as AgentLocalPlanPort;
      final (_, initialRevision) = await plans.readPlanContext();
      final initialReceipts = await _count(store, 'agenda_plan_receipts');
      final initialAudit = await _count(store, 'agenda_plan_audit');
      final initialTasks = await _tasks(store);
      expect(initialTasks, hasLength(1));
      expect(
        (await store.agent.readActionPermissions()).single.category,
        AgentPermissionCategory.createTask,
      );

      final attempts = <List<AgentLocalChange>>[
        [AgentCalendarChange(DeletePersonalSeries(target, confirmed: true))],
        [
          const AgentCreateTask('mixed', TaskDraft(title: '未授权混合方案不应创建')),
          AgentCalendarChange(DeletePersonalSeries(target, confirmed: true)),
        ],
      ];
      for (final changes in attempts) {
        final (context, revision) = await plans.readPlanContext();
        final plan = await plans.prepareLocalPlan(
          ticket,
          context,
          revision,
          changes,
        );
        final approval = await localPermission.authorizeLocalPlan(
          plan,
          mode: AgentAuthorizationMode.remembered,
        );
        expect(approval, isNull);
        expect((await plans.readPlanContext()).$2, initialRevision);
        expect(await _count(store, 'agenda_plan_receipts'), initialReceipts);
        expect(await _count(store, 'agenda_plan_audit'), initialAudit);
        expect((await _tasks(store)).length, initialTasks.length);
        final window = await _calendarWindow(store);
        expect(
          window.items.any(
            (item) => item.reference.identity == target.identity,
          ),
          isTrue,
        );
        expect(
          (await store.agent.readActionPermissions()).single.category,
          AgentPermissionCategory.createTask,
        );
      }
    },
  );

  test(
    'forged plans, action snapshots, approvals, and refs are rejected',
    () async {
      final store = await _open();
      final plans = store.localCalendar as AgentLocalPlanPort;
      final localPermission = store.localCalendar as AgentLocalPermissionPort;
      final ticket = await _ticket(store);
      final plan = await _taskPlan(store, ticket, '只接受原始计划对象');
      final forgedPlan = AgentLocalPlan(
        id: plan.id,
        ticket: plan.ticket,
        context: plan.context,
        revision: plan.revision,
        expiresAtUtc: plan.expiresAtUtc,
        changes: plan.changes,
        view: plan.view,
        requireFree: plan.requireFree,
        preferencesRevision: plan.preferencesRevision,
      );
      await _expectAgentFailure(
        localPermission.authorizeLocalPlan(
          forgedPlan,
          mode: AgentAuthorizationMode.confirmed,
        ),
        AgentFailureCode.staleContext,
      );

      final approval = await localPermission.authorizeLocalPlan(
        plan,
        mode: AgentAuthorizationMode.confirmed,
        remember: true,
      );
      expect(approval, isNotNull);
      await _expectAgentFailure(
        plans.commitLocalPlan(AgentPlanApproval(plan)),
        AgentFailureCode.staleContext,
      );
      await plans.commitLocalPlan(approval!);
      await store.agent.finishRun(ticket, AgentMessageStatus.complete);

      final reference = (await store.agent.readActionPermissions()).single;
      final forgedReference = AgentPermissionReference(
        reference.category,
        reference.revision,
      );
      await _expectAgentFailure(
        store.agent.revokeActionPermission(forgedReference),
        AgentFailureCode.staleContext,
      );
      expect(
        (await store.agent.readActionPermissions()).single.revision,
        reference.revision,
      );

      final sourceTicket = await _ticket(store);
      final request = AgentSourceRequest(AgentRefreshSource.jw);
      final action = await store.agent.prepareSourceAction(
        sourceTicket,
        request,
        '合成来源动作',
        const ['只验证 C3 权限对象'],
      );
      final forgedAction = AgentActionView(
        id: action.id,
        kind: action.kind,
        status: action.status,
        title: action.title,
        details: action.details,
        warning: action.warning,
      );
      await _expectAgentFailure(
        store.agent.authorizeAction(
          sourceTicket,
          forgedAction,
          mode: AgentAuthorizationMode.confirmed,
        ),
        AgentFailureCode.staleContext,
      );
    },
  );

  test('revocation and regrant do not revive an older source proof', () async {
    final store = await _open();
    final ticket = await _ticket(store);
    final request = AgentSourceRequest(AgentRefreshSource.jw);
    final firstAction = await _sourceAction(store, ticket, request);
    expect(
      await store.agent.authorizeAction(
        ticket,
        firstAction,
        mode: AgentAuthorizationMode.confirmed,
        remember: true,
      ),
      isTrue,
    );
    await _expectAgentFailure(
      store.agent.ensureSourceApproval(
        ticket,
        firstAction,
        const AgentSourceRequest(AgentRefreshSource.youngCalendar),
      ),
      AgentFailureCode.staleContext,
    );
    await store.agent.ensureSourceApproval(ticket, firstAction, request);

    final youngRequest = AgentSourceRequest(AgentRefreshSource.youngCalendar);
    final youngAction = await _sourceAction(store, ticket, youngRequest);
    expect(
      await store.agent.authorizeAction(
        ticket,
        youngAction,
        mode: AgentAuthorizationMode.remembered,
      ),
      isFalse,
    );

    final firstReference = (await store.agent.readActionPermissions()).single;
    expect(firstReference.category, AgentPermissionCategory.refreshJw);
    await store.agent.finishRun(ticket, AgentMessageStatus.complete);

    final nextTicket = await _ticket(store);
    final oldRequest = AgentSourceRequest(AgentRefreshSource.jw);
    final oldAction = await _sourceAction(store, nextTicket, oldRequest);
    expect(
      await store.agent.authorizeAction(
        nextTicket,
        oldAction,
        mode: AgentAuthorizationMode.remembered,
      ),
      isTrue,
    );

    await store.agent.revokeActionPermission(firstReference);
    final regrantRequest = AgentSourceRequest(AgentRefreshSource.jw);
    final regrantAction = await _sourceAction(
      store,
      nextTicket,
      regrantRequest,
    );
    expect(
      await store.agent.authorizeAction(
        nextTicket,
        regrantAction,
        mode: AgentAuthorizationMode.confirmed,
        remember: true,
      ),
      isTrue,
    );

    await _expectAgentFailure(
      store.agent.ensureSourceApproval(nextTicket, oldAction, oldRequest),
      AgentFailureCode.consentRequired,
    );
    final current = (await store.agent.readActionPermissions()).single;
    expect(current.category, AgentPermissionCategory.refreshJw);
    expect(current.revision, greaterThan(firstReference.revision));

    await store.agent.finishRun(nextTicket, AgentMessageStatus.complete);
    await store.agent.revokeActionPermission(current);
    final youngTicket = await _ticket(store);
    final secondYoungRequest = AgentSourceRequest(
      AgentRefreshSource.youngCalendar,
    );
    final secondYoungAction = await _sourceAction(
      store,
      youngTicket,
      secondYoungRequest,
    );
    expect(
      await store.agent.authorizeAction(
        youngTicket,
        secondYoungAction,
        mode: AgentAuthorizationMode.confirmed,
        remember: true,
      ),
      isTrue,
    );
    final youngGrant = (await store.agent.readActionPermissions()).single;
    expect(youngGrant.category, AgentPermissionCategory.refreshYoung);
    await store.agent.finishRun(youngTicket, AgentMessageStatus.complete);

    final jwTicket = await _ticket(store);
    final jwRequest = AgentSourceRequest(AgentRefreshSource.jw);
    final jwAction = await _sourceAction(store, jwTicket, jwRequest);
    expect(
      await store.agent.authorizeAction(
        jwTicket,
        jwAction,
        mode: AgentAuthorizationMode.remembered,
      ),
      isFalse,
    );
  });

  test(
    'revocation at the final checkpoint aborts the queued plan transaction',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var pauseCheckpoint = false;
      Future<void> checkpoint() async {
        if (!pauseCheckpoint) return;
        if (!entered.isCompleted) entered.complete();
        await release.future;
      }

      final store = await _open(onAgentCheckpoint: checkpoint);
      final plans = store.localCalendar as AgentLocalPlanPort;
      final localPermission = store.localCalendar as AgentLocalPermissionPort;
      final initialTicket = await _ticket(store);
      final initialPlan = await _taskPlan(store, initialTicket, '最终检查前已有的合成任务');
      final initialApproval = await localPermission.authorizeLocalPlan(
        initialPlan,
        mode: AgentAuthorizationMode.confirmed,
        remember: true,
      );
      await plans.commitLocalPlan(initialApproval!);
      await store.agent.finishRun(initialTicket, AgentMessageStatus.complete);
      final reference = (await store.agent.readActionPermissions()).single;
      final beforeRevision = (await plans.readPlanContext()).$2;
      final beforeReceipts = await _count(store, 'agenda_plan_receipts');
      final beforeAudit = await _count(store, 'agenda_plan_audit');

      final ticket = await _ticket(store);
      final plan = await _taskPlan(store, ticket, '撤销时不应提交的合成任务');
      final approval = await localPermission.authorizeLocalPlan(
        plan,
        mode: AgentAuthorizationMode.remembered,
      );
      expect(approval, isNotNull);

      pauseCheckpoint = true;
      final commit = plans.commitLocalPlan(approval!);
      await entered.future;
      final queuedRevoke = store.agent.revokeActionPermission(reference);
      release.complete();

      await _expectAgentFailure(commit, AgentFailureCode.consentRequired);
      await queuedRevoke;

      expect((await plans.readPlanContext()).$2, beforeRevision);
      expect((await _tasks(store)).length, 1);
      expect(await _count(store, 'agenda_plan_receipts'), beforeReceipts);
      expect(await _count(store, 'agenda_plan_audit'), beforeAudit);
      expect(await store.agent.readActionPermissions(), isEmpty);
    },
  );

  test(
    'SQL failure rolls back both remembered permission and business data',
    () async {
      final store = await _open();
      final plans = store.localCalendar as AgentLocalPlanPort;
      final localPermission = store.localCalendar as AgentLocalPermissionPort;
      final ticket = await _ticket(store);
      final plan = await _taskPlan(store, ticket, 'SQL 回滚时不能留下的合成任务');
      final approval = await localPermission.authorizeLocalPlan(
        plan,
        mode: AgentAuthorizationMode.confirmed,
        remember: true,
      );
      expect(approval, isNotNull);
      final beforeRevision = (await plans.readPlanContext()).$2;
      await store.customStatement('''
        CREATE TRIGGER fail_agent_plan_receipt
        BEFORE INSERT ON agenda_plan_receipts
        BEGIN
          SELECT RAISE(ABORT, 'synthetic permission transaction failure');
        END
      ''');

      await expectLater(plans.commitLocalPlan(approval!), throwsA(anything));

      expect((await plans.readPlanContext()).$2, beforeRevision);
      expect(await _tasks(store), isEmpty);
      expect(await _count(store, 'agenda_plan_receipts'), 0);
      expect(await _count(store, 'agenda_plan_audit'), 0);
      expect(await store.agent.readActionPermissions(), isEmpty);
    },
  );

  test('configuration change retains grants and stales old cards', () async {
    final store = await _open();
    await _establishTaskGrant(store);
    final oldTicket = await _ticket(store);
    final oldPlan = await _taskPlan(store, oldTicket, '配置变更后旧卡片不能提交');
    final oldApproval = await (store.localCalendar as AgentLocalPermissionPort)
        .authorizeLocalPlan(oldPlan, mode: AgentAuthorizationMode.remembered);
    expect(oldApproval, isNotNull);

    final settings = await store.agent.inspectAgent();
    await store.agent.saveModelConfiguration(
      settings.authority,
      modelId: 'synthetic-permission-model-v2',
      modelIds: const ['synthetic-permission-model-v2'],
      report: const AgentCapabilityReport(text: true, streaming: true),
      consent: true,
    );
    await _expectAgentFailure(
      store.agent.saveAssistant(oldTicket, '配置变更后的迟到文本'),
      AgentFailureCode.staleContext,
    );
    await _expectAgentFailure(
      (store.localCalendar as AgentLocalPlanPort).commitLocalPlan(oldApproval!),
      AgentFailureCode.staleContext,
    );
    expect(
      (await store.agent.readActionPermissions()).single.category,
      AgentPermissionCategory.createTask,
    );

    final nextTicket = await _ticket(store);
    final nextPlan = await _taskPlan(store, nextTicket, '配置变更后的合成任务');
    final nextApproval = await (store.localCalendar as AgentLocalPermissionPort)
        .authorizeLocalPlan(nextPlan, mode: AgentAuthorizationMode.remembered);
    expect(nextApproval, isNotNull);
    await (store.localCalendar as AgentLocalPlanPort).commitLocalPlan(
      nextApproval!,
    );
    expect((await _tasks(store)).length, 2);
  });

  test('history clear retains grants and stales old cards', () async {
    final store = await _open();
    await _establishTaskGrant(store);
    final ticket = await _ticket(store);
    final plan = await _taskPlan(store, ticket, '清历史后旧卡片不能提交');
    final approval = await (store.localCalendar as AgentLocalPermissionPort)
        .authorizeLocalPlan(plan, mode: AgentAuthorizationMode.remembered);
    expect(approval, isNotNull);
    final settings = await store.agent.inspectAgent();
    final intent = await store.agent.beginClearHistory(settings.authority);
    await store.agent.completeClearHistory(intent);

    await _expectAgentFailure(
      store.agent.saveAssistant(ticket, '清历史后的迟到文本'),
      AgentFailureCode.staleContext,
    );
    await _expectAgentFailure(
      (store.localCalendar as AgentLocalPlanPort).commitLocalPlan(approval!),
      AgentFailureCode.staleContext,
    );
    expect(
      (await store.agent.readActionPermissions()).single.category,
      AgentPermissionCategory.createTask,
    );

    final freshTicket = await _ticket(store);
    final freshPlan = await _taskPlan(store, freshTicket, '清历史后的合成任务');
    final freshApproval =
        await (store.localCalendar as AgentLocalPermissionPort)
            .authorizeLocalPlan(
              freshPlan,
              mode: AgentAuthorizationMode.remembered,
            );
    expect(freshApproval, isNotNull);
    await (store.localCalendar as AgentLocalPlanPort).commitLocalPlan(
      freshApproval!,
    );
    expect((await _tasks(store)).length, 2);
  });

  test(
    'planning preferences support remember, automatic approval, and revoke',
    () async {
      final store = await _open();
      final firstTicket = await _ticket(store);
      final firstPreferences = await store.agent.readPlanningPreferences();
      final firstProposal = await store.agent.preparePreferencesPlan(
        firstTicket,
        _changedPreferences(firstPreferences, startMinute: 8 * 60),
      );
      expect(
        await store.agent.authorizeAction(
          firstTicket,
          firstProposal,
          mode: AgentAuthorizationMode.confirmed,
          remember: true,
        ),
        isTrue,
      );
      await store.agent.commitPreferencesPlan(firstTicket, firstProposal);
      expect(
        (await store.agent.readPlanningPreferences()).revision,
        firstPreferences.revision + 1,
      );
      await store.agent.finishRun(firstTicket, AgentMessageStatus.complete);

      final secondTicket = await _ticket(store);
      final secondPreferences = await store.agent.readPlanningPreferences();
      final secondProposal = await store.agent.preparePreferencesPlan(
        secondTicket,
        _changedPreferences(secondPreferences, startMinute: 9 * 60),
      );
      expect(
        await store.agent.authorizeAction(
          secondTicket,
          secondProposal,
          mode: AgentAuthorizationMode.remembered,
        ),
        isTrue,
      );
      await store.agent.commitPreferencesPlan(secondTicket, secondProposal);
      final granted = (await store.agent.readActionPermissions()).single;
      expect(granted.category, AgentPermissionCategory.preferences);
      expect(
        (await store.agent.readPlanningPreferences()).revision,
        secondPreferences.revision + 1,
      );
      await store.agent.finishRun(secondTicket, AgentMessageStatus.complete);

      await store.agent.revokeActionPermission(granted);
      final afterRevocationTicket = await _ticket(store);
      final afterRevocationPreferences = await store.agent
          .readPlanningPreferences();
      final afterRevocationProposal = await store.agent.preparePreferencesPlan(
        afterRevocationTicket,
        _changedPreferences(afterRevocationPreferences, startMinute: 10 * 60),
      );
      expect(
        await store.agent.authorizeAction(
          afterRevocationTicket,
          afterRevocationProposal,
          mode: AgentAuthorizationMode.remembered,
        ),
        isFalse,
      );
      await _expectAgentFailure(
        store.agent.commitPreferencesPlan(
          afterRevocationTicket,
          afterRevocationProposal,
        ),
        AgentFailureCode.consentRequired,
      );
      expect(
        (await store.agent.readPlanningPreferences()).revision,
        afterRevocationPreferences.revision,
      );
      expect(await store.agent.readActionPermissions(), isEmpty);
    },
  );

  test('a preference proposal needs an issued confirmation proof', () async {
    final store = await _open();
    final ticket = await _ticket(store);
    final preferences = await store.agent.readPlanningPreferences();
    final proposal = await store.agent.preparePreferencesPlan(
      ticket,
      _changedPreferences(preferences, startMinute: 8 * 60),
    );

    await _expectAgentFailure(
      store.agent.commitPreferencesPlan(ticket, proposal),
      AgentFailureCode.consentRequired,
    );
    expect(
      (await store.agent.readPlanningPreferences()).revision,
      preferences.revision,
    );
  });
}

Future<JwStore> _open({Future<void> Function()? onAgentCheckpoint}) =>
    _openWithExecutor(
      NativeDatabase.memory(),
      onAgentCheckpoint: onAgentCheckpoint,
    );

Future<JwStore> _openAt(File file, {bool configure = true}) =>
    _openWithExecutor(NativeDatabase(file), configure: configure);

Future<JwStore> _openWithExecutor(
  QueryExecutor executor, {
  bool configure = true,
  Future<void> Function()? onAgentCheckpoint,
}) async {
  final store = JwStore(
    executor,
    ownership: _TestOwnership(),
    clock: _clock,
    modelCredentialProtector: _SyntheticProtector(),
    onAgentCheckpoint: onAgentCheckpoint,
  );
  addTearDown(store.close);
  await store.initialize();
  await store.agent.initializeAgent();
  if (configure) await _configure(store);
  return store;
}

Future<void> _configure(JwStore store) async {
  final settings = await store.agent.inspectAgent();
  await store.agent.saveModelConfiguration(
    settings.authority,
    modelId: 'synthetic-permission-model',
    modelIds: const ['synthetic-permission-model'],
    report: const AgentCapabilityReport(text: true, streaming: true),
    consent: true,
    key: _syntheticKey,
  );
}

Future<AgentRunTicket> _ticket(JwStore store) async {
  final settings = await store.agent.inspectAgent();
  final conversation = await store.agent.ensurePrimaryConversation();
  return store.agent.beginRun(
    settings.authority,
    conversation,
    '仅供 C3 权限存储合成测试',
  );
}

Future<AgentLocalPlan> _taskPlan(
  JwStore store,
  AgentRunTicket ticket,
  String title,
) async {
  final plans = store.localCalendar as AgentLocalPlanPort;
  final (context, revision) = await plans.readPlanContext();
  return plans.prepareLocalPlan(ticket, context, revision, [
    AgentCreateTask('permission-task', TaskDraft(title: title)),
  ]);
}

Future<void> _establishTaskGrant(JwStore store) async {
  final ticket = await _ticket(store);
  final plan = await _taskPlan(store, ticket, '建立权限的合成任务');
  final approval = await (store.localCalendar as AgentLocalPermissionPort)
      .authorizeLocalPlan(
        plan,
        mode: AgentAuthorizationMode.confirmed,
        remember: true,
      );
  if (approval == null) throw StateError('Expected a confirmed local approval');
  await (store.localCalendar as AgentLocalPlanPort).commitLocalPlan(approval);
  await store.agent.finishRun(ticket, AgentMessageStatus.complete);
}

Future<AgentActionView> _sourceAction(
  JwStore store,
  AgentRunTicket ticket,
  AgentSourceRequest request,
) => store.agent.prepareSourceAction(ticket, request, '合成来源权限卡', const [
  '测试固定来源类别，不访问学校',
]);

AgentPlanningPreferences _changedPreferences(
  AgentPlanningPreferences current, {
  required int startMinute,
}) => AgentPlanningPreferences(
  revision: current.revision,
  weekdays: current.weekdays,
  startMinute: startMinute,
  endMinute: current.endMinute,
  blockMinutes: current.blockMinutes,
  breakMinutes: current.breakMinutes,
  avoid: current.avoid,
);

Future<CalendarReference> _seedPersonalEvent(JwStore store) async {
  final window = await _calendarWindow(store);
  final command = await store.localCalendar.prepare(
    window.context,
    CreatePersonalEvent(
      PersonalEventDraft(
        title: '待撤销的合成个人事件',
        start: DateTime.utc(2026, 10, 13, 10),
        end: DateTime.utc(2026, 10, 13, 11),
      ),
    ),
  );
  final receipt = await store.localCalendar.commit(command);
  return receipt.target!;
}

Future<CalendarWindow> _calendarWindow(JwStore store) =>
    store.localCalendar.query(
      CalendarQuery(
        firstDay: DateTime.utc(2026, 10, 12),
        endDayExclusive: DateTime.utc(2026, 10, 30),
        filter: CalendarFilter.all,
      ),
    );

Future<List<TaskRecord>> _tasks(JwStore store) async =>
    (await store.localCalendar.queryTasks(
      const TaskQuery(filter: TaskFilter.all),
    )).items;

Future<int> _count(JwStore store, String table) async =>
    (await store
            .customSelect('SELECT COUNT(*) AS count FROM $table')
            .getSingle())
        .read<int>('count');

Future<void> _expectAgentFailure(Future<dynamic> call, AgentFailureCode code) =>
    expectLater(
      call,
      throwsA(
        isA<AgentFailure>().having((failure) => failure.code, 'code', code),
      ),
    );

Future<File> _temporaryDatabase() async {
  final directory = await Directory.systemTemp.createTemp(
    'agent-permission-test-',
  );
  addTearDown(() async {
    final tempRoot =
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}';
    if (!directory.absolute.path.toLowerCase().startsWith(
          tempRoot.toLowerCase(),
        ) ||
        !directory.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('agent-permission-test-')) {
      throw StateError('Unexpected synthetic temporary root');
    }
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File ||
          !const {
            'agent.sqlite',
            'agent.sqlite-wal',
            'agent.sqlite-shm',
            'agent.sqlite-journal',
          }.contains(entry.uri.pathSegments.last)) {
        throw StateError('Unexpected synthetic temporary entry');
      }
      await entry.delete();
    }
    await directory.delete();
  });
  return File('${directory.path}${Platform.pathSeparator}agent.sqlite');
}

final class _SyntheticProtector implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-permission-test-protector/v1';

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
