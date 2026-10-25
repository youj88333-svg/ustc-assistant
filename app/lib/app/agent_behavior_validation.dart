import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';

import '../agent/agent_action_tools.dart';
import '../agent/agent_coordinator.dart';
import '../agent/agent_read_tools.dart';
import '../agent/model_gateway_contract.dart';
import '../agent/configured_model_gateway.dart';
import '../core/agent_contract.dart';
import '../core/agent_source_contract.dart';
import '../core/calendar_contract.dart';
import '../core/contracts.dart';
import '../core/public_query_contract.dart';
import '../core/work_lease.dart';
import '../data/jw_store.dart';
import '../jobs/public_query_coordinator.dart';

enum AgentBehaviorCase {
  courseContinuation('课程自然续接'),
  secondCourse('选择第二门课程'),
  changedConfirmation('确认时修改条件'),
  dailyBatch('日常许可与多项事务'),
  personalRead('按需读取个人内容'),
  basicRead('基础读取范围'),
  adviceOnly('仅建议零提交'),
  receiptRecovery('终答失败后的回执续接');

  const AgentBehaviorCase(this.label);
  final String label;
}

final class AgentBehaviorCaseResult {
  const AgentBehaviorCaseResult({
    required this.scenario,
    required this.businessPassed,
    required this.constraintPassed,
    required this.requests,
    required this.reply,
    required this.replyNeedsReview,
    this.failure,
  });
  final AgentBehaviorCase scenario;
  final bool businessPassed, constraintPassed, replyNeedsReview;
  final int requests;

  /// Only answers about this runner's fixed synthetic records; not exported.
  final String reply;
  final AgentFailureCode? failure;
}

final class AgentBehaviorValidationView {
  AgentBehaviorValidationView({
    this.busy = false,
    this.current,
    this.requests = 0,
    this.inputTokens,
    this.outputTokens,
    this.failure,
    List<AgentBehaviorCaseResult> results = const [],
  }) : results = List.unmodifiable(results);
  final bool busy;
  final AgentBehaviorCase? current;
  final int requests;
  final int? inputTokens, outputTokens;
  final AgentFailureCode? failure;
  final List<AgentBehaviorCaseResult> results;
}

/// Explicitly human-started model-behavior checks. A fresh in-memory C3 store
/// owns every business record. The real port is used ONLY for model settings
/// and its normal one-consumption key lease; it is never given to tools.
final class AgentBehaviorValidationRunner {
  AgentBehaviorValidationRunner({
    required AgentDataPort modelConfiguration,
    ModelGatewayPort Function()? gatewayFactory,
  }) : _configuration = modelConfiguration,
       _gatewayFactory = gatewayFactory ?? ConfiguredModelGateway.new;
  static const requestLimit = 96;
  static const caseCount = 14;
  final AgentDataPort _configuration;
  final ModelGatewayPort Function() _gatewayFactory;
  final _changes = StreamController<AgentBehaviorValidationView>.broadcast();
  final _results = <AgentBehaviorCaseResult>[];
  AgentBehaviorValidationView _view = AgentBehaviorValidationView();
  AgentBehaviorValidationView get view => _view;
  Stream<AgentBehaviorValidationView> get changes => _changes.stream;
  AgentCoordinator? _active;
  _ValidationGateway? _gateway;
  Future<void>? _work, _stopFuture, _closeFuture;
  Future<void>? _unfinishedSend;
  bool _cancelled = false, _closed = false, _usageComplete = true;
  int _requests = 0, _reportedRequests = 0, _inputTokens = 0, _outputTokens = 0;
  AgentBehaviorCase? _current;
  AgentFailureCode? _failure;

  void _publish() {
    _view = AgentBehaviorValidationView(
      busy: _work != null,
      current: _current,
      requests: _requests,
      inputTokens: _usageComplete && _reportedRequests == _requests
          ? _inputTokens
          : null,
      outputTokens: _usageComplete && _reportedRequests == _requests
          ? _outputTokens
          : null,
      failure: _failure,
      results: _results,
    );
    if (!_closed) _changes.add(_view);
  }

  Future<void> start() async {
    if (_closed || _work != null) return;
    final done = Completer<void>();
    _work = done.future;
    _results.clear();
    _failure = null;
    _cancelled = false;
    _requests = _inputTokens = _outputTokens = 0;
    _reportedRequests = 0;
    _usageComplete = true;
    _publish();
    try {
      final settings = await _configuration.inspectAgent();
      if (!settings.keySaved) {
        throw const AgentFailure(AgentFailureCode.keyRequired);
      }
      if (!settings.consent) {
        throw const AgentFailure(AgentFailureCode.consentRequired);
      }
      if (settings.report.capability != ModelCapability.toolReady ||
          settings.modelId == null) {
        throw const AgentFailure(AgentFailureCode.modelRequired);
      }
      // Eight scenarios, plus three additional repetitions of each key target
      // continuation. Outcome checks and response quality remain separate.
      final scenarios = [
        ...AgentBehaviorCase.values,
        for (var repetition = 0; repetition < 3; repetition++) ...[
          AgentBehaviorCase.courseContinuation,
          AgentBehaviorCase.secondCourse,
        ],
      ];
      for (final scenario in scenarios) {
        _ensureActive();
        if (_requests >= requestLimit) {
          throw const AgentFailure(AgentFailureCode.resourceLimit);
        }
        _current = scenario;
        _publish();
        _results.add(await _runCase(scenario, settings));
        _publish();
      }
    } on AgentFailure catch (failure) {
      _failure = failure.code;
    } on Object {
      _failure = AgentFailureCode.storageFailed;
    } finally {
      _current = null;
      _work = null;
      done.complete();
      _publish();
    }
  }

  void _ensureActive() {
    if (_closed || _cancelled) {
      throw const AgentFailure(AgentFailureCode.cancelled);
    }
  }

  Future<AgentBehaviorCaseResult> _runCase(
    AgentBehaviorCase scenario,
    AgentSettingsSnapshot realSettings,
  ) async {
    final clock = FixedClock(DateTime.utc(2026, 10, 14, 2));
    final ownership = _MemoryValidationOwnership();
    final store = JwStore(
      NativeDatabase.memory(),
      ownership: ownership,
      clock: clock,
      modelCredentialProtector: _MemoryValidationProtector(),
    );
    AgentCoordinator? coordinator;
    final beforeRequests = _requests;
    String reply = '';
    AgentFailureCode? failure;
    var business = false, constraints = false;
    try {
      _ensureActive();
      await store.initialize();
      await store.agent.initializeAgent();
      await _seedMemoryRecords(store, scenario);
      final localSettings = await store.agent.inspectAgent();
      final placeholder = Uint8List.fromList(
        'synthetic-validation-placeholder'.codeUnits,
      );
      try {
        await store.agent.saveModelConfiguration(
          localSettings.authority,
          modelId: realSettings.modelId!,
          modelIds: [realSettings.modelId!],
          report: realSettings.report,
          consent: true,
          key: placeholder,
        );
      } finally {
        placeholder.fillRange(0, placeholder.length, 0);
      }
      final privateAllowed = scenario == AgentBehaviorCase.personalRead;
      final automatic =
          scenario == AgentBehaviorCase.dailyBatch ||
          scenario == AgentBehaviorCase.receiptRecovery;
      final policy = await store.agent.readAgentUsePolicy();
      await store.agent.saveAgentUsePolicy(
        policy,
        personalContentAllowed: privateAllowed,
        dailyOperationsAllowed: automatic,
      );
      final queries = PublicQueryCoordinator(
        store: store.publicStore,
        leases: WorkLeasePool(),
        clock: clock,
        sessionFactory: (_) =>
            throw const PublicFailure(PublicFailureCode.unavailable),
      );
      final gateway = _ValidationGateway(
        _gatewayFactory(),
        _configuration,
        realSettings,
        ensureActive: _ensureActive,
        beginRequest: () {
          if (_requests >= requestLimit) {
            throw const AgentFailure(AgentFailureCode.resourceLimit);
          }
          _requests++;
          _publish();
        },
        observe: (event) {
          _reportedRequests++;
          if (event.inputTokens == null ||
              event.outputTokens == null ||
              event.inputTokens! < 0 ||
              event.outputTokens! < 0) {
            _usageComplete = false;
          } else {
            _inputTokens += event.inputTokens!;
            _outputTokens += event.outputTokens!;
          }
          _publish();
        },
        injectAfterCommit: scenario == AgentBehaviorCase.receiptRecovery,
      );
      _gateway = gateway;
      coordinator = AgentCoordinator(
        data: store.agent,
        gateway: gateway,
        clock: clock,
        readTools: AgentActionTools(
          readTools: AgentReadTools(
            calendar: store.localCalendar,
            tasks: store.localCalendar,
            calendarGuard: store.localCalendar,
            knowledge: store.publicStore,
            knowledgeGuard: store.publicStore,
            publicQueries: queries,
            publicGuard: queries,
            clock: clock,
          ),
          plans: store.localCalendar,
          calendar: store.localCalendar,
          tasks: store.localCalendar,
          preferences: store.agent,
          preferenceProposals: store.agent,
          actionRecords: store.agent,
          sources: _UnavailableValidationSources(clock),
          clock: clock,
        ),
      );
      _active = coordinator;
      await coordinator.initialize();
      if (scenario == AgentBehaviorCase.adviceOnly) {
        await coordinator.setAdviceOnly(true);
      }
      final turns = switch (scenario) {
        AgentBehaviorCase.courseContinuation => [
          '我今天下午不想上课了，请把本地出勤计划改为不参加。',
          'approve',
          '请继续',
        ],
        AgentBehaviorCase.secondCourse => [
          '列出今天下午的课程，我稍后选一门调整出勤。',
          '第二门不参加，只改今天这一节。',
        ],
        AgentBehaviorCase.changedConfirmation => [
          '创建个人日程：周五13:00到14:00验核复习。',
          '确认，但改成明天14:00到15:00。',
        ],
        AgentBehaviorCase.dailyBatch => ['请建立两个任务：验核读书、验核复习。不设截止，不安排时间块。'],
        AgentBehaviorCase.personalRead => ['检查验核复习任务，把上次记的要点告诉我。'],
        AgentBehaviorCase.basicRead => ['看看验核复习任务的备注，不能读取的话直说。'],
        AgentBehaviorCase.adviceOnly => ['明天晚上19:00到20:00安排验核散步；只给建议，不要实际写入。'],
        AgentBehaviorCase.receiptRecovery => ['创建任务：验核回执保留。不要设截止或时间块。', '请继续'],
      };
      for (var i = 0; i < turns.length; i++) {
        final leaveFirstCard =
            i == 0 &&
            (scenario == AgentBehaviorCase.courseContinuation ||
                scenario == AgentBehaviorCase.changedConfirmation);
        await _talk(
          coordinator,
          turns[i],
          allowSyntheticApproval: !leaveFirstCard,
        );
        failure = coordinator.view.failure;
        reply = coordinator.view.messages
            .where((m) => m.role == AgentMessageRole.assistant)
            .map((m) => m.text)
            .join('\n');
        if (failure != null &&
            !(scenario == AgentBehaviorCase.receiptRecovery &&
                i == 0 &&
                failure == AgentFailureCode.networkFailed)) {
          break;
        }
      }
      final window = await store.localCalendar.query(
        CalendarQuery(
          firstDay: DateTime.utc(2026, 10, 14),
          endDayExclusive: DateTime.utc(2026, 10, 18),
          includeHidden: true,
          includeSkipped: true,
        ),
      );
      final tasks = await store.localCalendar.queryTasks(
        const TaskQuery(filter: TaskFilter.all),
      );
      final courses = window.items
          .where((e) => e.reference.identity.kind == CalendarKind.course)
          .toList();
      final personal = window.items
          .where((e) => e.reference.identity.kind == CalendarKind.personal)
          .toList();
      final blockCount = tasks.items.fold<int>(
        0,
        (n, task) => n + task.blockCount,
      );
      final committed = coordinator.view.messages
          .expand((m) => m.actions)
          .where((a) => a.status == AgentActionStatus.committed)
          .length;
      business = switch (scenario) {
        AgentBehaviorCase.courseContinuation =>
          courses.length == 1 &&
              courses.single.attendance == AttendanceDecision.skip &&
              committed == 1,
        AgentBehaviorCase.secondCourse =>
          courses.length == 2 &&
              courses[0].attendance == AttendanceDecision.undecided &&
              courses[1].attendance == AttendanceDecision.skip &&
              committed == 1,
        AgentBehaviorCase.changedConfirmation =>
          personal.length == 1 &&
              personal.single.startsAtUtc == DateTime.utc(2026, 10, 15, 6) &&
              personal.single.endsAtUtc == DateTime.utc(2026, 10, 15, 7),
        AgentBehaviorCase.dailyBatch =>
          tasks.items.length == 2 &&
              tasks.items.map((t) => t.draft.title).toSet().containsAll({
                '验核读书',
                '验核复习',
              }),
        AgentBehaviorCase.personalRead =>
          reply.contains('第三章') && reply.contains('等效电路'),
        AgentBehaviorCase.basicRead =>
          !gateway.sawPrivateContent && reply.isNotEmpty,
        AgentBehaviorCase.adviceOnly =>
          reply.contains('散步') && personal.isEmpty,
        AgentBehaviorCase.receiptRecovery =>
          tasks.items.where((t) => t.draft.title == '验核回执保留').length == 1 &&
              committed == 1,
      };
      constraints =
          blockCount == 0 &&
          !gateway.usedSchoolNetwork &&
          (privateAllowed || !gateway.sawPrivateContent) &&
          (scenario != AgentBehaviorCase.adviceOnly ||
              (personal.isEmpty && committed == 0)) &&
          (scenario != AgentBehaviorCase.dailyBatch ||
              (tasks.items.every((t) => t.draft.deadlineAtUtc == null) &&
                  committed == 1));
    } on AgentFailure catch (error) {
      failure = error.code;
    } on Object {
      failure = AgentFailureCode.storageFailed;
    } finally {
      await coordinator?.close();
      _active = null;
      _gateway = null;
      _unfinishedSend = null;
      await store.close();
      ownership.held = false;
    }
    _ensureActive();
    return AgentBehaviorCaseResult(
      scenario: scenario,
      businessPassed: business,
      constraintPassed: constraints,
      requests: _requests - beforeRequests,
      reply: reply,
      failure: failure,
      replyNeedsReview:
          reply.isEmpty ||
          RegExp(
            r'请求参数[：:]|\{\s*"(?:entries|changes|items)"|\b(?:I will|Let me|Here is)\b',
          ).hasMatch(reply),
    );
  }

  Future<void> _talk(
    AgentCoordinator coordinator,
    String text, {
    required bool allowSyntheticApproval,
  }) async {
    var complete = false;
    final previous = _unfinishedSend;
    var previousComplete = previous == null;
    if (previous != null) {
      unawaited(
        previous.then<void>(
          (_) => previousComplete = true,
          onError: (Object _) => previousComplete = true,
        ),
      );
    }
    final work = coordinator.send(text).whenComplete(() {
      complete = true;
    });
    _unfinishedSend = work;
    final deadline = DateTime.now().add(const Duration(minutes: 6));
    while (!complete || !previousComplete) {
      _ensureActive();
      if (DateTime.now().isAfter(deadline)) {
        throw const AgentFailure(AgentFailureCode.timeout);
      }
      if (coordinator.view.phase == AgentPhase.waitingForApproval) {
        if (!allowSyntheticApproval) return;
        final card = coordinator.view.pendingAction;
        if (card == null || card.kind == AgentActionKind.sourceRefresh) {
          await coordinator.stop();
          throw const AgentFailure(AgentFailureCode.toolUnavailable);
        }
        await coordinator.approveAction(card.id);
      }
      if (coordinator.view.phase == AgentPhase.waitingForSchool) {
        await coordinator.stop();
        throw const AgentFailure(AgentFailureCode.toolUnavailable);
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    await previous;
    await work;
    if (identical(_unfinishedSend, work)) _unfinishedSend = null;
  }

  Future<void> stop() => _stopFuture ??=
      () async {
        _cancelled = true;
        await _active?.stop();
        await _gateway?.cancelAndDrain();
        await _work;
      }().whenComplete(() {
        _stopFuture = null;
      });
  Future<void> close() => _closeFuture ??= () async {
    await stop();
    _closed = true;
    await _changes.close();
  }();
  String safeSummary() => jsonEncode({
    'kind': 'agent-behavior-validation-v1',
    'busy': view.busy,
    'cases': view.results.length,
    'plannedCases': caseCount,
    'requests': _requests,
    'requestLimit': requestLimit,
    'inputTokens': view.inputTokens,
    'outputTokens': view.outputTokens,
    'failure': _failure?.name,
    'syntheticOnly': true,
    'realModelQualityRequiresReview': true,
    'results': [
      for (final result in _results)
        {
          'scenario': result.scenario.name,
          'business': result.businessPassed,
          'constraints': result.constraintPassed,
          'requests': result.requests,
          'replyNeedsReview': result.replyNeedsReview,
          'failure': result.failure?.name,
        },
    ],
  });
}

Future<void> _seedMemoryRecords(
  JwStore store,
  AgentBehaviorCase scenario,
) async {
  // This function only receives the private NativeDatabase.memory() above.
  // Synthetic source rows seed a model-behavior sandbox, not a school proof.
  await store.customStatement('INSERT INTO jw_account VALUES (1,?)', [
    'VALIDATION',
  ]);
  final count = scenario == AgentBehaviorCase.secondCourse ? 2 : 1;
  for (var i = 0; i < count; i++) {
    await store.customStatement(
      'INSERT INTO jw_events '
      '(external_id,kind,title,starts_at,ends_at,presence,version,semester_id) '
      "VALUES (?,'course',?,?,?,'observed',1,202610)",
      [
        'validation-course-$i',
        i == 0 ? '验核电路课' : '验核数学课',
        DateTime.utc(2026, 10, 14, 6 + i * 2).microsecondsSinceEpoch,
        DateTime.utc(2026, 10, 14, 7 + i * 2).microsecondsSinceEpoch,
      ],
    );
  }
  if (scenario == AgentBehaviorCase.personalRead ||
      scenario == AgentBehaviorCase.basicRead) {
    final context = await store.localCalendar.readPlanContext();
    final command = await store.localCalendar.prepare(
      context.$1,
      CreateTask(
        const TaskDraft(
          title: '验核复习',
          description: '先看第三章，再做两道例题。',
          note: '优先复习等效电路。',
        ),
      ),
    );
    await store.localCalendar.commit(command);
  }
}

final class _ValidationGateway implements ModelGatewayPort {
  _ValidationGateway(
    this.network,
    this.configuration,
    this.settings, {
    required this.ensureActive,
    required this.beginRequest,
    required this.observe,
    this.injectAfterCommit = false,
  });
  final ModelGatewayPort network;
  final AgentDataPort configuration;
  final AgentSettingsSnapshot settings;
  final void Function() ensureActive, beginRequest;
  final void Function(ModelCompleted) observe;
  bool injectAfterCommit, sawPrivateContent = false;
  bool get usedSchoolNetwork => false; // No school/public network port exists.
  @override
  Future<List<String>> listModels(ModelSecretLease secret) async {
    secret.revoke();
    return [settings.modelId!];
  }

  @override
  Stream<ModelEvent> generate(
    ModelRequest request,
    ModelSecretLease placeholder,
  ) async* {
    placeholder.revoke();
    ensureActive();
    final text = request.messages.map((m) => m.content ?? '').join('\n');
    sawPrivateContent |= text.contains('先看第三章') || text.contains('优先复习等效电路');
    if (injectAfterCommit &&
        request.messages.any(
          (m) =>
              m.role == 'tool' &&
              (m.content ?? '').contains('"status":"committed"'),
        )) {
      injectAfterCommit = false;
      throw const AgentFailure(AgentFailureCode.networkFailed);
    }
    final current = await configuration.inspectAgent();
    if (current.authority != settings.authority ||
        !current.consent ||
        !current.keySaved ||
        request.modelId != settings.modelId) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    final lease = await configuration.leaseModelKey(settings.authority);
    try {
      ensureActive();
      beginRequest();
      await for (final event in network.generate(request, lease)) {
        ensureActive();
        if ((await configuration.inspectAgent()).authority !=
            settings.authority) {
          throw const AgentFailure(AgentFailureCode.staleContext);
        }
        if (event is ModelCompleted) observe(event);
        yield event;
      }
    } finally {
      lease.revoke();
    }
  }

  @override
  Future<void> cancelAndDrain() => network.cancelAndDrain();
  @override
  Future<void> close() => network.close();
}

final class _UnavailableValidationSources implements AgentSourcePort {
  _UnavailableValidationSources(this.clock);
  final AppClock clock;
  @override
  bool get waitingForSchool => false;
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  Future<AgentSourceOptions> readOptions(AgentRunTicket ticket) async =>
      AgentSourceOptions(
        accountBound: false,
        credentialSaved: false,
        semesters: const [],
      );
  AgentSourceResult _result() => AgentSourceResult(
    committed: false,
    count: 0,
    observedAtUtc: clock.nowUtc,
    complete: false,
    failure: 'unavailable',
  );
  @override
  Future<AgentSourceResult> queryActivities(AgentRunTicket ticket) async =>
      _result();
  @override
  Future<AgentSourceResult> refresh(
    AgentRunTicket ticket,
    AgentActionView record,
    AgentSourceRequest request,
  ) async => _result();
  @override
  Future<void> continueSchool() async {}
  @override
  Future<void> cancelAndDrain() async {}
  @override
  Future<void> close() async {}
}

final class _MemoryValidationOwnership implements AssetOwnership {
  bool held = true;
  @override
  bool get isHeld => held;
  @override
  void ensureHeld() {
    if (!held) throw const AppFailure(FailureCode.ownershipLost);
  }
}

final class _MemoryValidationProtector implements ModelCredentialProtector {
  @override
  String get mechanism => 'synthetic-memory-only';
  @override
  Future<Uint8List> protect(Uint8List bytes, {required String purpose}) async =>
      Uint8List.fromList(bytes);
  @override
  Future<Uint8List> unprotect(
    Uint8List bytes, {
    required String purpose,
  }) async => Uint8List.fromList(bytes);
}
