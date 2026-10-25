import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_m0/agent/model_gateway_contract.dart';
import 'package:ustc_assistant_m0/core/agenda_contract.dart';
import 'package:ustc_assistant_m0/core/agent_contract.dart';
import 'package:ustc_assistant_m0/core/calendar_contract.dart';
import 'package:ustc_assistant_m0/core/contracts.dart';
import 'package:ustc_assistant_m0/core/morning_brief_contract.dart';
import 'package:ustc_assistant_m0/core/morning_notice_contract.dart';
import 'package:ustc_assistant_m0/core/public_query_contract.dart';
import 'package:ustc_assistant_m0/core/reminder_contract.dart';
import 'package:ustc_assistant_m0/jobs/morning_brief_coordinator.dart';
import 'package:ustc_assistant_m0/jobs/morning_notice_query.dart';
import 'package:ustc_assistant_m0/platform/transient_diagnostics.dart';

const _context = CalendarContext(
  owner: 'synthetic-owner-id-private-7',
  resetEpoch: 2,
  agendaEpoch: 9,
);
const _briefDigest = 'synthetic-fact-digest-private-marker';
const _noticeUrl =
    'https://www.teach.ustc.edu.cn/2026/10/14/private-id-sentinel.html';

void main() {
  for (final read in ['facts', 'brief']) {
    test(
      'initial $read read failure remains visible and can recover',
      () async {
        final fixture = _BriefFixture(DateTime.utc(2026, 10, 14, 21, 59));
        fixture.data.failFactRead = read == 'facts';
        fixture.data.failBriefRead = read == 'brief';
        fixture.coordinator.onForeground(true);
        await _waitFor(
          () => fixture.coordinator.view.phase == MorningBriefPhase.failed,
        );
        expect(fixture.coordinator.view.enabled, isTrue);
        expect(fixture.coordinator.view.canRegenerate, isTrue);
        expect(fixture.coordinator.view.busy, isFalse);
        expect(fixture.gateway.generateCalls, 0);
        fixture.data.failFactRead = fixture.data.failBriefRead = false;
        await fixture.coordinator.check(manual: true);
        await fixture.gateway.started.future.timeout(
          const Duration(seconds: 2),
        );
        fixture.gateway.finishSuccessfully();
        await fixture.data.readySaved.future.timeout(
          const Duration(seconds: 2),
        );
        await fixture.close();
      },
    );
  }

  for (final oldPhase in [MorningBriefPhase.ready, MorningBriefPhase.failed]) {
    test(
      'changed facts hide ${oldPhase.name} summary until manual retry',
      () async {
        final fixture = _BriefFixture(DateTime.utc(2026, 10, 14, 22));
        fixture.data.modelAttempts = 2;
        final oldBrief = MorningBrief(
          day: fixture.data.facts.day,
          phase: oldPhase,
          factDigest: _briefDigest,
          autoAttempts: 2,
          notices: _coverageBatch(complete: true),
          summary: 'synthetic obsolete summary',
          failure: oldPhase == MorningBriefPhase.failed ? 'timeout' : null,
        );
        fixture.data.cached = oldBrief;
        fixture.data.changeFacts(
          digest: 'synthetic-new-digest',
          eventTitle: 'synthetic updated arrangement',
        );
        fixture.coordinator.onForeground(true);
        await _waitFor(() => fixture.coordinator.view.facts != null);
        for (var i = 0; i < 3; i++) {
          await fixture.coordinator.check();
          final view = fixture.coordinator.view;
          expect(view.facts!.digest, 'synthetic-new-digest');
          expect(view.busy, isFalse);
          expect(view.summaryOutdated, isTrue);
          expect(view.canRegenerate, isTrue);
          expect(view.brief, isNull);
          expect(view.text, isEmpty);
          expect(fixture.data.cached, same(oldBrief));
        }
        expect(fixture.data.beginCalls, 0);
        expect(fixture.data.modelAttempts, 2);
        expect(fixture.source.browseCalls, 0);
        expect(fixture.gateway.generateCalls, 0);

        // A new runtime over the same persisted snapshot has the same idle,
        // recoverable projection; it does not interpret facts changes as work.
        await fixture.close();
        final restarted = _BriefFixture(fixture.clock.value);
        restarted.data.cached = oldBrief;
        restarted.data.modelAttempts = 2;
        restarted.data.facts = fixture.data.facts;
        restarted.coordinator.onForeground(true);
        await _waitFor(() => restarted.coordinator.view.facts != null);
        expect(restarted.coordinator.view.summaryOutdated, isTrue);
        expect(restarted.coordinator.view.canRegenerate, isTrue);
        expect(restarted.data.beginCalls, 0);

        await restarted.coordinator.check(manual: true);
        await restarted.gateway.started.future.timeout(
          const Duration(seconds: 2),
        );
        expect(restarted.source.browseCalls, 2);
        expect(restarted.data._ticket!.manual, isTrue);
        expect(restarted.data._ticket!.factDigest, 'synthetic-new-digest');
        expect(
          restarted.gateway.lastRequest!.messages.last.content,
          contains('synthetic updated arrangement'),
        );
        restarted.gateway.finishSuccessfully();
        await restarted.data.readySaved.future.timeout(
          const Duration(seconds: 2),
        );
        await _waitFor(
          () => restarted.coordinator.view.phase == MorningBriefPhase.ready,
        );
        expect(restarted.coordinator.view.summaryOutdated, isFalse);
        expect(restarted.data.cached!.factDigest, 'synthetic-new-digest');
        await restarted.close();
      },
    );
  }

  test(
    'cleared brief remains cleared even with the store empty digest',
    () async {
      final fixture = _BriefFixture(DateTime.utc(2026, 10, 14, 22))
        ..data.cached = MorningBrief(
          day: DateTime.utc(2026, 10, 15),
          phase: MorningBriefPhase.cleared,
          factDigest: '',
          autoAttempts: 2,
        );
      fixture.coordinator.onForeground(true);
      await _waitFor(() => fixture.coordinator.view.facts != null);
      await fixture.coordinator.check();
      expect(fixture.coordinator.view.phase, MorningBriefPhase.cleared);
      expect(fixture.coordinator.view.busy, isFalse);
      expect(fixture.coordinator.view.text, isEmpty);
      expect(fixture.data.beginCalls, 0);
      expect(fixture.source.browseCalls, 0);
      expect(fixture.gateway.generateCalls, 0);
      await fixture.close();
    },
  );

  test(
    'manual retry refreshes even a previously complete notice cache',
    () async {
      final fixture = _BriefFixture(DateTime.utc(2026, 10, 14, 22));
      fixture.data.cached = MorningBrief(
        day: fixture.data.facts.day,
        phase: MorningBriefPhase.ready,
        factDigest: _briefDigest,
        autoAttempts: 1,
        notices: _coverageBatch(complete: true),
        summary: 'synthetic earlier summary',
      );
      fixture.coordinator.onForeground(true);
      await _waitFor(() => fixture.coordinator.view.facts != null);
      await fixture.coordinator.check(manual: true);
      await fixture.gateway.started.future.timeout(const Duration(seconds: 2));
      expect(fixture.source.browseCalls, 2);
      fixture.gateway.finishSuccessfully();
      await fixture.data.readySaved.future.timeout(const Duration(seconds: 2));
      await fixture.close();
    },
  );

  test(
    'partial notices never become an unchecked no-notice conclusion',
    () async {
      final fixture = _BriefFixture(DateTime.utc(2026, 10, 14, 22));
      fixture.source.failures[CampusColumn.financeNotice] =
          PublicFailureCode.networkFailed;
      fixture.coordinator.onForeground(true);
      await fixture.data.readySaved.future.timeout(const Duration(seconds: 2));
      await _waitFor(
        () => fixture.coordinator.view.phase == MorningBriefPhase.ready,
      );
      final brief = fixture.data.cached!;
      expect(
        morningSummaryForDisplay(brief.summary, brief.notices),
        morningFactsSummary(fixture.data.facts),
      );
      expect(fixture.gateway.generateCalls, 0);
      expect(fixture.agent.inspectCalls, 0);
      expect(fixture.data.modelAttempts, 0);
      expect(brief.summary, contains('morning-facts-v1'));
      expect(brief.summary, isNot(contains('昨天没有新公告')));
      final exported =
          jsonDecode(await fixture.diagnostics.exportRecent()) as Map;
      final records = (exported['records'] as List).cast<Map>();
      final failures = records.where(
        (r) =>
            r['event'] == 'morningNoticeRead' &&
            r['stage'] == 'morningFinanceNotices',
      );
      expect(failures.single['code'], 'networkFailed');
      expect(failures.single['outcome'], 'failure');
      expect(failures.single['count'], 0);
      expect(records.last['outcome'], 'truncated');
      expect(records.map((r) => r['trace']).toSet(), hasLength(1));
      final safeLog = jsonEncode(exported);
      expect(safeLog, isNot(contains('synthetic public title')));
      expect(safeLog, isNot(contains(_noticeUrl)));
      expect(safeLog, isNot(contains(_context.owner)));
      expect(safeLog, isNot(contains('今天有一项安排')));
      expect(fixture.diagnostics.diagnosticsView.invalid, 0);
      await fixture.close();
    },
  );

  test(
    'legacy incomplete summaries stay hidden without editing stored data',
    () {
      const oldSummary = '今天有课。昨天没有新公告。';
      expect(
        morningSummaryForDisplay(oldSummary, _coverageBatch(complete: false)),
        '',
      );
      expect(morningSummaryForDisplay(oldSummary, null), '');
      expect(
        morningSummaryForDisplay(oldSummary, _coverageBatch(complete: true)),
        oldSummary,
      );
      expect(
        morningSummaryForDisplay('{bad json}', _coverageBatch(complete: true)),
        '',
      );
      final current = const MorningSummary(
        today: '今天有课。',
        notices: '有一则公告。',
      ).encode();
      expect(
        morningSummaryForDisplay(current, _coverageBatch(complete: false)),
        '',
      );
      expect(
        morningSummaryForDisplay(current, _coverageBatch(complete: true)),
        '今天有课。\n\n有一则公告。',
      );
      final adversarial = const MorningSummary(
        today: '今天有课。昨天没有新公告。',
        notices: '',
      ).encode();
      expect(
        morningSummaryForDisplay(adversarial, _coverageBatch(complete: false)),
        '',
      );
    },
  );

  test(
    'invalid structured model output fails without rendering raw fields',
    () async {
      final fixture = _BriefFixture(DateTime.utc(2026, 10, 14, 22));
      await _startGeneration(fixture);
      fixture.gateway.emitText('{"unexpected":"synthetic untrusted output"}');
      fixture.gateway.finishWithoutText();
      await _waitFor(
        () => fixture.coordinator.view.phase == MorningBriefPhase.failed,
      );
      expect(fixture.coordinator.view.failure, 'protocol');
      expect(fixture.coordinator.view.text, '');
      expect(fixture.data.readyWrites, 0);
      await fixture.close();
    },
  );

  test(
    'a stalled generation times out and closes its local subscription',
    () async {
      final fixture = _BriefFixture(
        DateTime.utc(2026, 10, 14, 22),
        generationTimeout: const Duration(milliseconds: 30),
      );
      await _startGeneration(fixture);
      await _waitFor(
        () => fixture.data.cached?.phase == MorningBriefPhase.failed,
      );
      expect(fixture.data.cached?.failure, 'timeout');
      await _waitFor(() => fixture.gateway.cancelAndDrainCalls == 1);
      expect(fixture.gateway.cancelAndDrainCalls, 1);
      expect(fixture.data.readyWrites, 0);
      await fixture.close();
    },
  );
  test(
    '05:59 stays facts-only; crossing 06:00 starts one asynchronous brief',
    () async {
      final fixture = _BriefFixture(DateTime.utc(2026, 10, 14, 21, 59));
      fixture.coordinator.onForeground(true);
      await _waitFor(() => fixture.coordinator.view.facts != null);

      expect(fixture.coordinator.view.facts!.day, DateTime.utc(2026, 10, 15));
      expect(fixture.source.browseCalls, 0);
      expect(fixture.data.beginCalls, 0);
      expect(fixture.budgetResets, 0);
      expect(fixture.gateway.generateCalls, 0);

      fixture.clock.value = DateTime.utc(2026, 10, 14, 22);
      await fixture.coordinator.check();
      await fixture.gateway.started.future.timeout(const Duration(seconds: 2));
      expect(fixture.data.beginCalls, 1);
      expect(fixture.source.browseCalls, 2);
      expect(fixture.source.articleReads, 1);
      expect(fixture.budgetResets, 1);
      expect(fixture.source.lastArticleMaximum, 1000);

      fixture.gateway.finishSuccessfully();
      await fixture.data.readySaved.future.timeout(const Duration(seconds: 2));
      await _waitFor(() => fixture.agent.lastLease?.isAvailable == false);
      final request = fixture.gateway.lastRequest!;
      final userPayload = request.messages.last.content!;
      expect(request.tools, isEmpty);
      expect(request.toolChoice, 'none');
      expect(request.maxTokens, 600);
      expect(userPayload, contains('synthetic public title'));
      expect(userPayload, contains('synthetic public article excerpt'));
      expect(userPayload, isNot(contains('private-id-sentinel')));
      expect(userPayload, isNot(contains('synthetic-reference-id-sentinel')));
      expect(userPayload, isNot(contains(_context.owner)));
      expect(userPayload, isNot(contains(_briefDigest)));
      expect(userPayload, isNot(contains('private note sentinel')));
      expect(fixture.agent.unexpectedCalls, 0);
      expect(fixture.agent.lastLease!.isAvailable, isFalse);
      await fixture.close();
    },
  );

  test(
    'same-day ready cache is reused without another public or model request',
    () async {
      final fixture = _BriefFixture(DateTime.utc(2026, 10, 14, 22))
        ..data.cached = MorningBrief(
          day: DateTime.utc(2026, 10, 15),
          phase: MorningBriefPhase.ready,
          factDigest: _briefDigest,
          autoAttempts: 1,
          summary: 'synthetic cached summary',
        );
      fixture.coordinator.onForeground(true);
      await _waitFor(
        () => fixture.coordinator.view.phase == MorningBriefPhase.ready,
      );

      expect(fixture.coordinator.view.text, 'synthetic cached summary');
      expect(fixture.data.beginCalls, 0);
      expect(fixture.source.browseCalls, 0);
      expect(fixture.gateway.generateCalls, 0);
      await fixture.close();
    },
  );

  test('ticket acquisition race sends facts bound to the ticket', () async {
    final fixture = _BriefFixture(DateTime.utc(2026, 10, 14, 22));
    fixture.data.onBegin = () => fixture.data.changeFacts(
      digest: 'synthetic-latest-fact-digest',
      eventTitle: 'latest synthetic event',
    );

    await _startGeneration(fixture);

    final userPayload = fixture.gateway.lastRequest!.messages.last.content!;
    expect(userPayload, contains('latest synthetic event'));
    expect(userPayload, isNot(contains('synthetic today event')));
    expect(
      fixture.coordinator.view.facts?.digest,
      'synthetic-latest-fact-digest',
    );

    fixture.gateway.finishSuccessfully();
    await fixture.data.readySaved.future.timeout(const Duration(seconds: 2));
    expect(fixture.data.cached?.factDigest, 'synthetic-latest-fact-digest');
    await fixture.close();
  });

  test('same-day check and a slow source page share one job', () async {
    final fixture = _BriefFixture(DateTime.utc(2026, 10, 14, 22));
    fixture.source.firstBrowseGate = Completer<PublicQueryResult>();
    fixture.coordinator.onForeground(true);
    await _waitFor(() => fixture.source.browseCalls == 1);

    await fixture.coordinator.check();
    expect(fixture.data.beginCalls, 1);
    expect(fixture.source.browseCalls, 1);
    expect(fixture.gateway.generateCalls, 0);

    fixture.source.firstBrowseGate!.complete(fixture.source.emptyResult());
    await fixture.gateway.started.future.timeout(const Duration(seconds: 2));
    fixture.gateway.finishSuccessfully();
    await fixture.data.readySaved.future.timeout(const Duration(seconds: 2));
    await fixture.close();
  });

  test(
    'foreground Agent takes priority by canceling only the brief-owned work',
    () async {
      final fixture = _BriefFixture(DateTime.utc(2026, 10, 14, 22));
      await _startGeneration(fixture);
      fixture.foregroundBusy = true;
      fixture.coordinator.onAgentStateChanged();
      await _waitFor(
        () => fixture.data.cached?.phase == MorningBriefPhase.interrupted,
      );

      expect(fixture.gateway.cancelAndDrainCalls, 1);
      expect(fixture.gateway.closeCalls, 0);
      expect(fixture.source.cancelCalls, 1);
      expect(fixture.agent.unexpectedCalls, 0);
      expect(fixture.agent.conversationCalls, 0);
      expect(fixture.data.readyWrites, 0);

      fixture.gateway.emitLateSuccess();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(fixture.data.cached?.phase, MorningBriefPhase.interrupted);
      expect(fixture.data.cached?.summary, isEmpty);
      expect(fixture.data.readyWrites, 0);
      await fixture.close();
    },
  );

  for (final invalidation in <String>['facts', 'clear', 'reset']) {
    test(
      '$invalidation invalidation rejects the in-flight result and late stream',
      () async {
        final fixture = _BriefFixture(DateTime.utc(2026, 10, 14, 22));
        await _startGeneration(fixture);
        fixture.foregroundBusy = true;

        if (invalidation == 'facts') {
          fixture.data.changeFacts(digest: 'synthetic-new-fact-digest');
          await fixture.coordinator.check();
        } else if (invalidation == 'clear') {
          await fixture.data.clearMorningBriefs();
          await fixture.coordinator.check();
        } else {
          fixture.data.resetEpoch();
          await fixture.coordinator.check();
          fixture.foregroundBusy = false;
          fixture.gateway.emitText('late stale delta');
        }

        await _waitFor(() => !fixture.coordinator.view.busy);
        fixture.gateway.emitLateSuccess();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(fixture.data.readyWrites, 0);
        expect(fixture.data.cached?.summary, isNot('late stale delta'));
        if (invalidation == 'clear') {
          expect(fixture.data.cached?.phase, MorningBriefPhase.cleared);
        }
        if (invalidation == 'facts') {
          expect(fixture.data.cached?.factDigest, _briefDigest);
        }
        if (invalidation == 'reset') {
          expect(fixture.data.epoch, 3);
        }
        await fixture.close();
      },
    );
  }

  for (final change in <String>['consent', 'configuration']) {
    test('model $change changes during generation reject the result', () async {
      final fixture = _BriefFixture(DateTime.utc(2026, 10, 14, 22));
      await _startGeneration(fixture);
      final original = fixture.agent.configuration;
      fixture.agent.configuration = AgentSettingsSnapshot(
        authority: AgentAuthority(
          owner: original.authority.owner,
          resetEpoch: original.authority.resetEpoch,
          historyEpoch: original.authority.historyEpoch,
          configRevision: original.authority.configRevision + 1,
        ),
        keySaved: true,
        consent: change == 'consent' ? false : true,
        modelId: change == 'configuration'
            ? 'synthetic-model-new'
            : original.modelId,
        report: original.report,
      );
      fixture.gateway.finishSuccessfully();
      await _waitFor(
        () => fixture.data.cached?.phase == MorningBriefPhase.failed,
      );

      expect(fixture.data.cached?.failure, 'configurationChanged');
      expect(fixture.data.readyWrites, 0);
      expect(fixture.gateway.generateCalls, 1);
      await fixture.close();
    });
  }

  test(
    'missing model consent leaves facts but never calls the model gateway',
    () async {
      final fixture = _BriefFixture(DateTime.utc(2026, 10, 14, 22));
      fixture.agent.configuration = _agentSettings(consent: false);
      fixture.coordinator.onForeground(true);
      await _waitFor(
        () => fixture.coordinator.view.phase == MorningBriefPhase.failed,
      );

      expect(fixture.coordinator.view.facts, isNotNull);
      expect(
        fixture.coordinator.view.failure,
        AgentFailureCode.consentRequired.name,
      );
      expect(fixture.gateway.generateCalls, 0);
      expect(fixture.source.browseCalls, 2);
      await fixture.close();
    },
  );
}

MorningNoticeBatch _coverageBatch({required bool complete}) =>
    MorningNoticeBatch(
      day: DateTime.utc(2026, 10, 14),
      notices: const [],
      operations: 2,
      coverage: [
        for (final provider in [PublicProvider.teach, PublicProvider.finance])
          MorningNoticeCoverage(
            provider: provider,
            pages: 1,
            matched: 0,
            unknownDates: 0,
            complete: complete,
          ),
      ],
    );

Future<void> _startGeneration(_BriefFixture fixture) async {
  fixture.coordinator.onForeground(true);
  await fixture.gateway.started.future.timeout(const Duration(seconds: 2));
}

Future<void> _waitFor(bool Function() condition) async {
  final timer = Stopwatch()..start();
  while (!condition()) {
    if (timer.elapsed > const Duration(seconds: 3)) {
      throw TimeoutException('Synthetic coordinator did not reach its state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _BriefFixture {
  _BriefFixture(
    DateTime nowUtc, {
    Duration generationTimeout = const Duration(seconds: 240),
  }) : clock = _MutableClock(nowUtc),
       data = _FakeBriefData(_facts(_context, nowUtc)),
       settings = _FakeReminderSettings(_context),
       agent = _FakeAgentData(),
       source = _FakePublicQuery(),
       gateway = _FakeGateway(),
       diagnostics = TransientDiagnostics() {
    notices = MorningNoticeQuery(source: source, clock: clock);
    coordinator = MorningBriefCoordinator(
      data: data,
      settings: settings,
      agentData: agent,
      gateway: gateway,
      notices: notices,
      cancelQueries: source.cancel,
      closeQueries: () async => closeQueryCalls++,
      resetNetworkBudget: () => budgetResets++,
      isForegroundBusy: () => foregroundBusy,
      clock: clock,
      generationTimeout: generationTimeout,
      diagnostics: diagnostics,
    );
  }

  final _MutableClock clock;
  final _FakeBriefData data;
  final _FakeReminderSettings settings;
  final _FakeAgentData agent;
  final _FakePublicQuery source;
  final _FakeGateway gateway;
  final TransientDiagnostics diagnostics;
  late final MorningNoticeQuery notices;
  late final MorningBriefCoordinator coordinator;
  bool foregroundBusy = false;
  int budgetResets = 0, closeQueryCalls = 0;

  Future<void> close() async {
    await coordinator.close();
  }
}

MorningFacts _facts(
  CalendarContext context,
  DateTime nowUtc, {
  String digest = _briefDigest,
  String eventTitle = 'synthetic today event',
}) {
  final day = beijingDay(nowUtc);
  return MorningFacts(
    context: context,
    day: day,
    digest: digest,
    agenda: [
      MorningAgendaItem(
        title: eventTitle,
        location: 'synthetic room',
        start: day.add(const Duration(hours: 2)),
        end: day.add(const Duration(hours: 3)),
        allDay: false,
        kind: 'personal',
        state: 'planned',
      ),
    ],
    tasks: [
      MorningTaskItem('synthetic due task', day.add(const Duration(hours: 18))),
    ],
    conflicts: 1,
    overdueTasks: 0,
    complete: true,
    hasSchoolImports: false,
  );
}

AgentSettingsSnapshot _agentSettings({
  bool consent = true,
  bool keySaved = true,
  String? modelId = 'synthetic-model-v1',
  int configRevision = 5,
}) => AgentSettingsSnapshot(
  authority: AgentAuthority(
    owner: 'synthetic-agent-owner',
    resetEpoch: 1,
    historyEpoch: 2,
    configRevision: configRevision,
  ),
  keySaved: keySaved,
  consent: consent,
  modelId: modelId,
  report: const AgentCapabilityReport(text: true, streaming: true),
);

final class _MutableClock implements AppClock {
  _MutableClock(this.value);
  DateTime value;
  @override
  DateTime get nowUtc => value.toUtc();
}

final class _FakeReminderSettings implements ReminderDataPort {
  _FakeReminderSettings(this.context);
  final CalendarContext context;
  final StreamController<int> _changes = StreamController<int>.broadcast();

  @override
  Stream<int> get changes => _changes.stream;

  @override
  Future<ReminderSettings> inspectReminders() async => ReminderSettings(
    context: context,
    revision: 1,
    briefEpoch: context.resetEpoch,
    preferences: const ReminderPreferences(morningEnabled: true),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected reminder settings operation');
}

final class _FakeBriefData implements MorningBriefDataPort {
  _FakeBriefData(this.facts);
  final StreamController<int> _changes = StreamController<int>.broadcast(
    sync: true,
  );
  final Completer<void> readySaved = Completer<void>();
  MorningFacts facts;
  MorningBrief? cached;
  bool failFactRead = false, failBriefRead = false;
  int epoch = 2, beginCalls = 0, modelAttempts = 0, readyWrites = 0;
  int _nextTicket = 0;
  MorningBriefTicket? _ticket;
  void Function()? onBegin;

  @override
  Stream<int> get changes => _changes.stream;

  @override
  Future<MorningFacts> morningFacts(DateTime day) async {
    if (failFactRead) throw StateError('synthetic fact read failure');
    return facts;
  }

  @override
  Future<MorningBrief?> readMorningBrief(DateTime day) async {
    if (failBriefRead) throw StateError('synthetic brief read failure');
    return cached?.day == day ? cached : null;
  }

  @override
  Future<MorningBriefTicket?> beginMorningBrief(
    DateTime day, {
    bool manual = false,
  }) async {
    beginCalls++;
    if (_ticket != null) return null;
    final hook = onBegin;
    onBegin = null;
    hook?.call();
    _ticket = MorningBriefTicket(
      context: facts.context,
      day: day,
      epoch: epoch,
      id: 'synthetic-brief-ticket-${++_nextTicket}',
      factDigest: facts.digest,
      manual: manual,
    );
    return _ticket;
  }

  @override
  Future<bool> beginMorningModelAttempt(MorningBriefTicket ticket) async {
    await ensureMorningTicket(ticket);
    modelAttempts++;
    return ticket.manual || modelAttempts <= 2;
  }

  @override
  Future<void> ensureMorningTicket(MorningBriefTicket ticket) async {
    if (!_ticketAuthorityCurrent(ticket)) {
      throw const ReminderFailure(ReminderFailureCode.stale);
    }
    if (ticket.factDigest != facts.digest || ticket.day != facts.day) {
      throw const ReminderFailure(ReminderFailureCode.stale);
    }
  }

  @override
  Future<void> saveMorningBrief(
    MorningBriefTicket ticket, {
    required MorningBriefPhase phase,
    MorningNoticeBatch? notices,
    String? summary,
    String? failure,
    int? inputTokens,
    int? outputTokens,
  }) async {
    final terminal =
        phase == MorningBriefPhase.ready ||
        phase == MorningBriefPhase.interrupted ||
        phase == MorningBriefPhase.failed ||
        phase == MorningBriefPhase.cleared;
    final mayIgnoreFacts =
        phase == MorningBriefPhase.interrupted ||
        phase == MorningBriefPhase.failed;
    if (mayIgnoreFacts) {
      if (!_ticketAuthorityCurrent(ticket)) {
        throw const ReminderFailure(ReminderFailureCode.stale);
      }
    } else {
      await ensureMorningTicket(ticket);
    }
    cached = MorningBrief(
      day: ticket.day,
      phase: phase,
      factDigest: ticket.factDigest,
      autoAttempts: modelAttempts,
      notices: notices ?? cached?.notices,
      summary: summary ?? cached?.summary ?? '',
      failure: failure,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
    );
    if (phase == MorningBriefPhase.ready) {
      readyWrites++;
      if (!readySaved.isCompleted) readySaved.complete();
    }
    if (terminal && identical(_ticket, ticket)) _ticket = null;
  }

  @override
  Future<void> clearMorningBriefs() async {
    epoch++;
    _ticket = null;
    cached = MorningBrief(
      day: facts.day,
      phase: MorningBriefPhase.cleared,
      factDigest: facts.digest,
      autoAttempts: modelAttempts,
    );
    _changes.add(epoch);
  }

  void changeFacts({
    required String digest,
    String eventTitle = 'synthetic today event',
  }) {
    facts = _facts(
      facts.context,
      facts.day,
      digest: digest,
      eventTitle: eventTitle,
    );
    _changes.add(epoch);
  }

  void resetEpoch() {
    epoch++;
    _ticket = null;
    final nextContext = CalendarContext(
      owner: facts.context.owner,
      resetEpoch: facts.context.resetEpoch + 1,
      agendaEpoch: facts.context.agendaEpoch + 1,
    );
    facts = _facts(nextContext, facts.day, digest: facts.digest);
    _changes.add(epoch);
  }

  bool _ticketAuthorityCurrent(MorningBriefTicket ticket) =>
      ticket.epoch == epoch && ticket.context == facts.context;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected MorningBriefDataPort operation');
}

final class _FakeAgentData implements AgentDataPort {
  final StreamController<int> _changes = StreamController<int>.broadcast();
  AgentSettingsSnapshot configuration = _agentSettings();
  ModelSecretLease? lastLease;
  int inspectCalls = 0, unexpectedCalls = 0, conversationCalls = 0;

  @override
  Stream<int> get changes => _changes.stream;

  @override
  Future<AgentSettingsSnapshot> inspectAgent() async {
    inspectCalls++;
    return configuration;
  }

  @override
  Future<ModelSecretLease> leaseModelKey(AgentAuthority expected) async {
    if (expected != configuration.authority) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    lastLease = ModelSecretLease(
      Uint8List.fromList('synthetic-only-model-key'.codeUnits),
    );
    return lastLease!;
  }

  @override
  Future<String> createConversation() async {
    conversationCalls++;
    throw StateError('Morning brief must not create a main conversation');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpectedCalls++;
    throw UnimplementedError('Unexpected AgentDataPort call');
  }
}

final class _FakeGateway implements ModelGatewayPort {
  final Completer<void> started = Completer<void>();
  final StreamController<ModelEvent> _events = StreamController<ModelEvent>();
  ModelRequest? lastRequest;
  ModelSecretLease? lastLease;
  int generateCalls = 0, cancelAndDrainCalls = 0, closeCalls = 0;

  @override
  Future<List<String>> listModels(ModelSecretLease secret) async => [
    'synthetic-model-v1',
  ];

  @override
  Stream<ModelEvent> generate(ModelRequest request, ModelSecretLease secret) {
    generateCalls++;
    lastRequest = request;
    lastLease = secret;
    if (!started.isCompleted) started.complete();
    return _events.stream;
  }

  void finishSuccessfully({
    String today = 'synthetic morning summary',
    String notices = 'synthetic yesterday notices',
  }) {
    _events.add(
      ModelTextDelta(jsonEncode({'today': today, 'notices': notices})),
    );
    finishWithoutText();
  }

  void finishWithoutText() {
    _events.add(
      ModelCompleted(finishReason: 'stop', inputTokens: 32, outputTokens: 11),
    );
    unawaited(_events.close());
  }

  void emitText(String text) => _events.add(ModelTextDelta(text));

  void emitLateSuccess() {
    if (_events.isClosed) return;
    _events.add(const ModelTextDelta('late stale delta'));
    _events.add(ModelCompleted(finishReason: 'stop'));
  }

  @override
  Future<void> cancelAndDrain() async {
    cancelAndDrainCalls++;
  }

  @override
  Future<void> close() {
    closeCalls++;
    return Future<void>.value();
  }
}

final class _FakePublicQuery implements PublicQueryPort {
  final StreamController<PublicJobView> _changes =
      StreamController<PublicJobView>.broadcast();
  final PublicEvidence noticeEvidence = PublicEvidence(
    provider: PublicProvider.teach,
    title: 'synthetic public title',
    articleUrl: Uri.parse(_noticeUrl),
    observedAtUtc: DateTime.utc(2026, 10, 15, 1),
    origin: EvidenceOrigin.online,
    publishedOn: '2026-10-14',
  );
  Completer<PublicQueryResult>? firstBrowseGate;
  final PublicJobView _view = const PublicJobView(phase: PublicJobPhase.idle);
  final Map<CampusColumn, PublicFailureCode> failures = {};
  int browseCalls = 0, articleReads = 0, cancelCalls = 0, closeCalls = 0;
  int? lastArticleMaximum;

  @override
  PublicJobView get view => _view;

  @override
  Stream<PublicJobView> get changes => _changes.stream;

  PublicQueryResult emptyResult() => PublicQueryResult(
    coverage: const PublicCoverage(
      scope: 'synthetic',
      returned: 0,
      complete: true,
    ),
  );

  @override
  Future<PublicQueryResult> browseCampus(
    CampusColumn column, {
    String? keywords,
    int pageSize = 20,
    PublicCursor? cursor,
  }) async {
    browseCalls++;
    if (failures[column] case final code?) throw PublicFailure(code);
    if (browseCalls == 1 && firstBrowseGate != null) {
      return firstBrowseGate!.future;
    }
    final candidates = column == CampusColumn.teachNotice
        ? [
            PublicCandidate(
              reference: const PublicReference(
                'synthetic-reference-id-sentinel',
              ),
              title: 'synthetic public title',
              evidence: noticeEvidence,
            ),
          ]
        : const <PublicCandidate>[];
    return PublicQueryResult(
      coverage: PublicCoverage(
        scope: column.name,
        returned: candidates.length,
        complete: true,
      ),
      candidates: candidates,
    );
  }

  @override
  Future<PublicQueryResult> readCampusArticle(
    PublicReference reference, {
    int sectionStart = 0,
    int maxCharacters = 12000,
    PublicCursor? cursor,
  }) async {
    articleReads++;
    lastArticleMaximum = maxCharacters;
    return PublicQueryResult(
      coverage: const PublicCoverage(
        scope: 'synthetic-article',
        returned: 1,
        complete: true,
      ),
      document: PublicDocument(
        evidence: noticeEvidence,
        markdown: 'synthetic public article excerpt',
      ),
    );
  }

  @override
  Future<bool> hasIcourseConsent() async => false;

  @override
  Future<void> setIcourseConsent(bool allowed) async {}

  @override
  Future<PublicQueryResult> searchCourses(
    String keywords, {
    int pageSize = 20,
    PublicCursor? cursor,
  }) async => emptyResult();

  @override
  Future<PublicQueryResult> readCourse(
    PublicReference reference, {
    String? term,
    CourseReviewSort sort = CourseReviewSort.upvote,
    int pageSize = 10,
    PublicCursor? cursor,
  }) async => emptyResult();

  @override
  Future<void> cancel() async {
    cancelCalls++;
    final gate = firstBrowseGate;
    if (gate != null && !gate.isCompleted) {
      gate.completeError(const PublicFailure(PublicFailureCode.cancelled));
    }
  }

  @override
  Future<void> retryRecovery() async {}

  @override
  Future<void> close() async {
    closeCalls++;
    await _changes.close();
  }
}
