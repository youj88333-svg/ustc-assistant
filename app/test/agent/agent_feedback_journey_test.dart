import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/agent_action_tools.dart';
import 'package:ustc_assistant_m0/agent/agent_coordinator.dart';
import 'package:ustc_assistant_m0/agent/agent_read_tools.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/agent_permission_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/work_lease.dart';
import 'package:ustc_assistant_m0/data/jw_store.dart';
import 'package:ustc_assistant_m0/jobs/public_query_coordinator.dart';

final _now = DateTime.utc(2026, 10, 14, 4);
final _modelKey = Uint8List.fromList(
  'synthetic-feedback-journey-key'.codeUnits,
);

void main() {
  for (final affirmative in const ['对的', '可以', '是的', '没错']) {
    test(
      'dated attendance request carries "$affirmative" into a fresh query without replaying committed work',
      () => _runAttendanceJourney(
        affirmative: affirmative,
        approve: true,
        advanceToNextDay: affirmative == '对的',
      ),
    );
  }
  test(
    'rejected attendance proposal followed by affirmation does not propose or write again',
    () => _runAttendanceJourney(
      affirmative: '对的',
      approve: false,
      advanceToNextDay: true,
    ),
  );
}

Future<void> _runAttendanceJourney({
  required String affirmative,
  required bool approve,
  required bool advanceToNextDay,
}) async {
  final clock = _MutableClock(_now);
  final rig = await _open(clock: clock);
  final sourceBefore = await _jwEvent(rig.store);
  final overlayBefore = await _jwOverlay(rig.store);
  expect(sourceBefore['title'], '合成周三下午课程');
  expect(overlayBefore['attendance'], 'attend');
  expect(overlayBefore['note'], 'synthetic-private-note-marker');

  const originalQuestion = '今天我心情不好，下午的课不想上了';
  await rig.coordinator.send(originalQuestion);
  final firstRequest = rig.gateway.requests.first;
  expect(firstRequest.toolChoice, 'query_agenda');
  expect(
    _toolNames(firstRequest),
    containsAll(['query_agenda', 'propose_local_changes']),
  );
  expect(_lastUserContent(firstRequest), originalQuestion);
  expect(rig.gateway.requests, hasLength(3));
  expect(rig.gateway.requests[1].toolChoice, 'query_agenda');
  expect(_agendaResult(rig.gateway.requests[2])['items'], hasLength(1));
  expect(
    _agendaResult(rig.gateway.requests[2])['items'].single['title'],
    '合成周三下午课程',
  );
  expect(
    rig.gateway.requests
        .expand((request) => request.messages)
        .where((message) => message.content != null)
        .map((message) => message.content)
        .join('\n'),
    isNot(contains('synthetic-private-note-marker')),
  );
  final firstMessages = await rig.store.agent.messages(
    rig.coordinator.view.conversationId!,
  );
  expect(firstMessages.map((message) => message.role), [
    AgentMessageRole.user,
    AgentMessageRole.assistant,
  ]);
  expect(firstMessages.first.createdAtUtc, _now);
  expect(
    firstMessages.map((message) => message.text).join('\n'),
    isNot(contains('今天下午没有课')),
  );
  expect(
    firstMessages.map((message) => message.text).join('\n'),
    isNot(contains('{"entries":[]}')),
  );
  expect(firstMessages.last.text, contains('合成课程'));
  expect(firstMessages.last.steps.map((step) => step.tool), ['query_agenda']);
  expect(firstMessages.last.steps.single.status, 'success');
  if (advanceToNextDay) {
    clock.nowUtc = DateTime.utc(2026, 10, 15, 4);
  }
  final followUp = rig.coordinator.send(affirmative);
  await _until(
    () => rig.coordinator.view.phase == AgentPhase.waitingForApproval,
  );
  expect(rig.gateway.requests, hasLength(5));
  final inheritedRequest = rig.gateway.requests[3];
  expect(
    _toolNames(inheritedRequest),
    containsAll(['query_agenda', 'propose_local_changes']),
  );
  expect(inheritedRequest.toolChoice, 'query_agenda');
  expect(_lastUserContent(inheritedRequest), contains(originalQuestion));
  expect(
    _lastUserContent(inheritedRequest),
    contains('原请求收到于北京时间 2026-10-14T12:00:00.000+08:00'),
  );
  expect(_lastUserContent(inheritedRequest), contains('用户本次补充：$affirmative'));
  final inheritedSystem = _systemContent(inheritedRequest);
  expect(
    inheritedSystem,
    contains('当前北京时间日期为 ${advanceToNextDay ? '2026-10-15' : '2026-10-14'}'),
  );
  expect(
    inheritedSystem,
    contains(
      '本次问题收到时间为 ${advanceToNextDay ? '2026-10-15' : '2026-10-14'}T12:00:00.000+08:00',
    ),
  );
  final inheritedRequestText = _requestText(inheritedRequest);
  expect(inheritedRequestText, contains('旧结果未携带；需要重新查询目标'));
  expect(inheritedRequestText, isNot(contains('合成周三下午课程')));
  expect(inheritedRequestText, isNot(contains('今天下午有一节合成课程')));
  expect(
    inheritedRequestText,
    isNot(contains('synthetic-private-note-marker')),
  );
  expect(
    inheritedRequestText,
    isNot(contains(_queriedEventRef(rig.gateway.requests[2]))),
  );
  expect(rig.gateway.queryWindows, hasLength(2));
  expect(rig.gateway.queryWindows.last, {
    'first_day': '2026-10-14',
    'end_day_exclusive': '2026-10-15',
  });
  expect(_agendaResult(rig.gateway.requests[4])['items'], hasLength(1));
  expect(
    _agendaResult(rig.gateway.requests[4])['items'].single['title'],
    '合成周三下午课程',
  );

  final card = rig.coordinator.view.pendingAction!;
  expect(card.kind, AgentActionKind.localPlan);
  expect(await _count(rig.store, 'agenda_plan_receipts'), 0);
  expect(await _jwOverlay(rig.store), overlayBefore);
  if (approve) {
    await rig.coordinator.approveAndRememberAction(card.id);
  } else {
    await rig.coordinator.rejectAction(card.id);
  }
  await followUp.timeout(const Duration(seconds: 3));
  expect(
    _lastToolStatus(rig.gateway.requests[5]),
    approve ? 'committed' : 'rejected',
  );

  expect(await _count(rig.store, 'agenda_plan_receipts'), approve ? 1 : 0);
  final grants = await rig.coordinator.readActionPermissions();
  expect(grants, hasLength(approve ? 1 : 0));
  if (approve) {
    expect(grants.single.category, AgentPermissionCategory.attendance);
    expect(grants.single.category.tool, 'propose_local_changes');
  }

  final sourceAfter = await _jwEvent(rig.store);
  final overlayAfterDecision = await _jwOverlay(rig.store);
  expect(await _count(rig.store, 'jw_events'), 1);
  if (approve) {
    expect(_withoutVersion(sourceAfter), _withoutVersion(sourceBefore));
    expect(sourceAfter['version'], (sourceBefore['version'] as int) + 1);
    expect(overlayAfterDecision['attendance'], 'skip');
    expect(overlayAfterDecision['hidden'], overlayBefore['hidden']);
    expect(overlayAfterDecision['note'], overlayBefore['note']);
    expect(overlayAfterDecision['listening'], overlayBefore['listening']);
  } else {
    expect(sourceAfter, sourceBefore);
    expect(overlayAfterDecision, overlayBefore);
  }
  final completed = await rig.store.agent.messages(
    rig.coordinator.view.conversationId!,
  );
  expect(completed.last.status, AgentMessageStatus.complete);
  expect(
    completed.last.actions.single.status,
    approve ? AgentActionStatus.committed : AgentActionStatus.rejected,
  );
  if (approve) {
    expect(completed.last.text, contains('出勤计划'));
    expect(
      completed.last.actions.single.authorization,
      AgentActionAuthorization.confirmed,
    );
    expect(
      (await rig.store.agent.readActionPermissions()).single.category,
      AgentPermissionCategory.attendance,
    );
  } else {
    expect(completed.last.text, contains('方案已拒绝'));
    expect(completed.last.text, contains('没有修改出勤计划'));
    expect(
      completed.last.actions.single.authorization,
      isNot(AgentActionAuthorization.remembered),
    );
  }
  final requestCountAfterCommit = rig.gateway.requests.length;
  await rig.coordinator.send(affirmative).timeout(const Duration(seconds: 3));
  expect(rig.gateway.requests, hasLength(requestCountAfterCommit + 1));
  expect(_lastUserContent(rig.gateway.requests.last), affirmative);
  expect(
    _toolNames(
      rig.gateway.requests.last,
    ).where((name) => name.startsWith('propose_')),
    isEmpty,
  );
  expect(rig.coordinator.view.pendingAction, isNull);
  expect(await _count(rig.store, 'agenda_plan_receipts'), approve ? 1 : 0);
  expect(await _jwOverlay(rig.store), overlayAfterDecision);
  if (approve && !advanceToNextDay) {
    await rig.coordinator
        .send('请把今天下午的课程出勤计划改为参加')
        .timeout(const Duration(seconds: 3));
    expect(rig.coordinator.view.failure, isNull);
    expect((await _jwOverlay(rig.store))['attendance'], 'attend');
    final automatic = (await rig.store.agent.messages(
      rig.coordinator.view.conversationId!,
    )).last;
    expect(
      automatic.actions.single.authorization,
      AgentActionAuthorization.remembered,
    );
  } else if (!approve) {
    await rig.coordinator.send('/clear').timeout(const Duration(seconds: 3));
    expect(
      await rig.store.agent.messages(rig.coordinator.view.conversationId!),
      isEmpty,
    );
    await rig.coordinator.send(affirmative).timeout(const Duration(seconds: 3));
    final clearedRequest = rig.gateway.requests.last;
    expect(_lastUserContent(clearedRequest), affirmative);
    expect(_requestText(clearedRequest), isNot(contains(originalQuestion)));
    expect(
      _toolNames(clearedRequest).where((name) => name.startsWith('propose_')),
      isEmpty,
    );
    expect(await _count(rig.store, 'agenda_plan_receipts'), 0);
    expect(await _jwOverlay(rig.store), overlayAfterDecision);
  }
}

Future<_Rig> _open({AppClock? clock}) async {
  final effectiveClock = clock ?? FixedClock(_now);
  final store = JwStore(
    NativeDatabase.memory(),
    ownership: _TestOwnership(),
    clock: effectiveClock,
    modelCredentialProtector: _SyntheticProtector(),
  );
  addTearDown(store.close);
  await store.initialize();
  await store.agent.initializeAgent();
  await _seedSyntheticJwCourse(store);
  final settings = await store.agent.inspectAgent();
  await store.agent.saveModelConfiguration(
    settings.authority,
    modelId: 'synthetic-feedback-model',
    modelIds: const ['synthetic-feedback-model'],
    report: const AgentCapabilityReport(
      text: true,
      streaming: true,
      toolCall: true,
      toolResult: true,
    ),
    consent: true,
    key: _modelKey,
  );

  final publicQueries = PublicQueryCoordinator(
    store: store.publicStore,
    leases: WorkLeasePool(),
    clock: effectiveClock,
    sessionFactory: (source) => throw StateError('synthetic network disabled'),
  );
  final readTools = AgentReadTools(
    calendar: store.localCalendar,
    tasks: store.localCalendar,
    calendarGuard: store.localCalendar,
    knowledge: store.publicStore,
    knowledgeGuard: store.publicStore,
    publicQueries: publicQueries,
    publicGuard: publicQueries,
    clock: effectiveClock,
  );
  final actionTools = AgentActionTools(
    readTools: readTools,
    plans: store.localCalendar,
    calendar: store.localCalendar,
    tasks: store.localCalendar,
    preferences: store.agent,
    preferenceProposals: store.agent,
    actionRecords: store.agent,
    clock: effectiveClock,
  );
  final gateway = _FeedbackJourneyGateway();
  final coordinator = AgentCoordinator(
    data: store.agent,
    gateway: gateway,
    readTools: actionTools,
    clock: effectiveClock,
  );
  addTearDown(coordinator.close);
  await coordinator.initialize();
  return _Rig(store, gateway, coordinator);
}

Future<void> _seedSyntheticJwCourse(JwStore store) async {
  await store.customStatement(
    'INSERT INTO jw_account(account_id,expected_account_code) VALUES(1,?)',
    ['SYNTHETIC14'],
  );
  await store.customStatement(
    'INSERT INTO jw_events(local_id,external_id,kind,semester_id,title,academic_json,starts_at,ends_at,presence,version) '
    'VALUES(1,?,?,?,?,?,?,?,?,?)',
    [
      'synthetic-feedback-afternoon-course',
      'course',
      202610,
      '合成周三下午课程',
      null,
      DateTime.utc(2026, 10, 14, 7).microsecondsSinceEpoch,
      DateTime.utc(2026, 10, 14, 8).microsecondsSinceEpoch,
      'observed',
      1,
    ],
  );
  await store.customStatement(
    "INSERT INTO jw_overlays(local_id,hidden,note,attendance,listening) VALUES(1,0,'synthetic-private-note-marker','attend','selfStudy')",
  );
}

Future<Map<String, Object?>> _jwEvent(JwStore store) async =>
    (await store.customSelect('SELECT * FROM jw_events').getSingle()).data;

Future<Map<String, Object?>> _jwOverlay(JwStore store) async =>
    (await store.customSelect('SELECT * FROM jw_overlays').getSingle()).data;

Map<String, Object?> _withoutVersion(Map<String, Object?> row) => {
  for (final entry in row.entries)
    if (entry.key != 'version') entry.key: entry.value,
};

Set<String> _toolNames(ModelRequest request) =>
    request.tools.map((tool) => tool.name).toSet();

String _lastUserContent(ModelRequest request) {
  final messages = request.messages
      .where((message) => message.role == 'user' && message.content != null)
      .toList();
  if (messages.isEmpty) {
    throw StateError('No user content was present in the model request.');
  }
  return messages.last.content!;
}

String _systemContent(ModelRequest request) =>
    request.messages.firstWhere((message) => message.role == 'system').content!;

String _requestText(ModelRequest request) => request.messages
    .where((message) => message.content != null)
    .map((message) => message.content)
    .join('\n');

String _lastToolStatus(ModelRequest request) {
  final toolMessages = request.messages
      .where((message) => message.role == 'tool' && message.content != null)
      .toList();
  if (toolMessages.isEmpty) {
    throw StateError('No completed tool result was present in the request.');
  }
  final result = jsonDecode(toolMessages.last.content!) as Map<String, dynamic>;
  return result['status'] as String;
}

Map<String, dynamic> _agendaResult(ModelRequest request) {
  final toolMessages = request.messages.where(
    (message) => message.role == 'tool' && message.content != null,
  );
  for (final message in toolMessages.toList().reversed) {
    final decoded = jsonDecode(message.content!) as Map<String, dynamic>;
    final data = decoded['data'];
    if (data is Map<String, dynamic> && data['items'] is List) {
      return data;
    }
  }
  throw StateError('No actual agenda tool result was present in the request.');
}

String _queriedEventRef(ModelRequest request) {
  final items = _agendaResult(request)['items'] as List;
  if (items.length != 1) {
    throw StateError(
      'Expected one synthetic course in the actual query result.',
    );
  }
  return (items.single as Map<String, dynamic>)['event_ref'] as String;
}

Future<int> _count(JwStore store, String table) async =>
    (await store.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
        .read<int>('n');

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Synthetic feedback journey did not advance.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

final class _Rig {
  const _Rig(this.store, this.gateway, this.coordinator);
  final JwStore store;
  final _FeedbackJourneyGateway gateway;
  final AgentCoordinator coordinator;
}

final class _MutableClock implements AppClock {
  _MutableClock(this.nowUtc);

  @override
  DateTime nowUtc;
}

final class _FeedbackJourneyGateway implements ModelGatewayPort {
  final List<ModelRequest> requests = [];
  final List<Map<String, String>> queryWindows = [];
  bool _closed = false;
  String? _decisionStatus;

  @override
  Future<List<String>> listModels(ModelSecretLease secret) async {
    _consume(secret);
    return const ['synthetic-feedback-model'];
  }

  @override
  Stream<ModelEvent> generate(ModelRequest request, ModelSecretLease secret) {
    _consume(secret);
    if (_closed) {
      return Stream<ModelEvent>.error(
        const AgentFailure(AgentFailureCode.closed),
      );
    }
    requests.add(request);
    final events = switch (requests.length) {
      1 => _answer('{"entries":[],"coverage":"complete"} 今天下午没有课。'),
      2 => _query('feedback-query-first'),
      3 => _answer('今天下午有一节合成课程。要我把个人出勤计划设为不参加吗？'),
      4 => _query('feedback-query-confirmation'),
      5 => _proposal(request),
      6 => _answer(_decisionAnswer(request)),
      7 => _answer('你可以直接告诉我想调整的安排。'),
      8 =>
        _decisionStatus == 'committed' &&
                request.tools.any((tool) => tool.name == 'query_agenda')
            ? _query('feedback-query-automatic')
            : _answer('需要新的安排时请告诉我具体日期和内容。'),
      9 => _proposal(request, attendance: 'attend'),
      10 => _answer('出勤计划已恢复为参加。'),
      _ => throw StateError('Unexpected model request ${requests.length}.'),
    };
    return Stream<ModelEvent>.fromIterable(events);
  }

  List<ModelEvent> _answer(String text) => [
    ModelTextDelta(text),
    ModelCompleted(finishReason: 'stop'),
  ];

  List<ModelEvent> _query(String id) {
    const window = {
      'first_day': '2026-10-14',
      'end_day_exclusive': '2026-10-15',
    };
    queryWindows.add(window);
    return [
      ModelCompleted(
        finishReason: 'tool_calls',
        toolCalls: [
          ModelToolCall(
            id: id,
            name: 'query_agenda',
            argumentsJson: jsonEncode({...window, 'include_skipped': true}),
          ),
        ],
      ),
    ];
  }

  String _decisionAnswer(ModelRequest request) {
    _decisionStatus = _lastToolStatus(request);
    return switch (_decisionStatus) {
      'committed' => '我已把这节课的个人出勤计划设为不参加，学校课程记录保持原样。',
      'rejected' => '方案已拒绝，没有修改出勤计划。',
      final status => throw StateError('Unexpected decision status $status.'),
    };
  }

  List<ModelEvent> _proposal(
    ModelRequest request, {
    String attendance = 'skip',
  }) => [
    ModelCompleted(
      finishReason: 'tool_calls',
      toolCalls: [
        ModelToolCall(
          id: 'feedback-annotation',
          name: 'propose_local_changes',
          argumentsJson: jsonEncode({
            'changes': [
              {
                'type': 'annotate_school',
                'event_ref': _queriedEventRef(request),
                'attendance': attendance,
              },
            ],
          }),
        ),
      ],
    ),
  ];

  void _consume(ModelSecretLease secret) {
    final bytes = secret.take();
    bytes.fillRange(0, bytes.length, 0);
  }

  @override
  Future<void> cancelAndDrain() async {}

  @override
  Future<void> close() async {
    _closed = true;
  }
}

final class _SyntheticProtector implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-feedback-journey-protector/v1';

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
