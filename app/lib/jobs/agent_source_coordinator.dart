import 'dart:async';
import 'dart:math';

import '../core/agent_contract.dart';
import '../core/agent_source_contract.dart';
import '../core/agent_text.dart';
import '../core/calendar_validation.dart';
import '../core/contracts.dart';
import '../data/jw_store.dart';
import '../data/young_import_contract.dart';
import 'jw_sync_port.dart';
import 'young_sync_port.dart';

enum _AgentSourceJob { jw, calendar, activities }

/// Owns dedicated C2 instances. Manual sources share only their lease pool and
/// C3 data; cancellation cannot borrow or stop a manual job.
final class AgentSourceCoordinator
    implements AgentSourcePort, AgentSourceDeliveryPort {
  AgentSourceCoordinator({
    required this.store,
    required this.jw,
    required this.young,
    required this.shutdownSources,
    this.clock = const SystemClock(),
  }) {
    _subscriptions = [
      jw.syncChanges.listen((_) => _changed()),
      young.syncChanges.listen((_) => _changed()),
    ];
  }
  final JwStore store;
  final JwSyncPort jw;
  final YoungSyncPort young;
  final Future<void> Function() shutdownSources;
  final AppClock clock;
  final _changes = StreamController<void>.broadcast();
  late final List<StreamSubscription<Object?>> _subscriptions;
  final _semesters = <String, (AgentRunTicket, int, String)>{};
  AgentRunTicket? _ticket;
  AgentActionView? _record;
  AgentSourceRequest? _request;
  Object? _boundJob;
  (AgentRunTicket, YoungJobTicket)? _deliveryProof;
  @override
  Future<void> validateDelivery() async {
    final proof = _deliveryProof;
    if (proof != null) {
      await store.agent.ensureYoungAgentDelivery(proof.$1, proof.$2);
    }
  }

  @override
  void clearReadReferences() => _deliveryProof = null;
  _AgentSourceJob? _job;
  Completer<void>? _terminal;
  bool _cancelled = false, _closed = false, _continuing = false;
  @override
  bool get waitingForSchool => _job == _AgentSourceJob.jw
      ? jw.syncView.phase == JwSyncPhase.login &&
            jw.syncView.automation == JwAutomationState.manualRequired
      : _job != null &&
            young.syncView.phase == YoungSyncPhase.login &&
            young.syncView.automation == YoungAutomationState.manualRequired;
  @override
  Stream<void> get changes => _changes.stream;
  bool get _finished => _job == _AgentSourceJob.jw
      ? const {
          JwSyncPhase.idle,
          JwSyncPhase.recovery,
          JwSyncPhase.closed,
        }.contains(jw.syncView.phase)
      : const {
          YoungSyncPhase.idle,
          YoungSyncPhase.recovery,
          YoungSyncPhase.closed,
        }.contains(young.syncView.phase);
  void _changed() {
    if (_closed) return;
    if (_job != null && _finished && _terminal?.isCompleted == false) {
      _terminal!.complete();
    }
    _changes.add(null);
  }

  Future<void> bindAdmittedJob(Object sourceTicket) async {
    final ticket = _ticket, record = _record;
    if (_cancelled || ticket == null || record == null) {
      throw const AgentFailure(AgentFailureCode.cancelled);
    }
    await store.agent.bindSourceAction(ticket, record, sourceTicket, _request);
    _boundJob = sourceTicket;
  }

  Future<void> _ensure(AgentRunTicket ticket) async {
    if (_closed) throw const AgentFailure(AgentFailureCode.closed);
    await store.agent.ensureAgentRun(ticket);
  }

  @override
  Future<AgentSourceOptions> readOptions(AgentRunTicket ticket) async {
    await _ensure(ticket);
    final data = await store.readView();
    final signature = fingerprint(
      data.cachedSemesters.map((s) => [s.id, s.name, s.selected]).toList(),
    );
    _semesters.removeWhere((_, v) => !identical(v.$1, ticket));
    final options = <AgentSemesterOption>[];
    for (final semester in data.cachedSemesters) {
      AgentText.requireSafe(semester.name, maxCharacters: 120);
      final existing = _semesters.entries
          .where(
            (e) =>
                identical(e.value.$1, ticket) &&
                e.value.$2 == semester.id &&
                e.value.$3 == signature,
          )
          .firstOrNull;
      final ref =
          existing?.key ??
          'semester_${List.generate(12, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
      _semesters[ref] = (ticket, semester.id, signature);
      options.add(
        AgentSemesterOption(
          ref,
          semester.name,
          lastUsed: semester.id == data.lastSemesterId,
        ),
      );
    }
    await _ensure(ticket);
    return AgentSourceOptions(
      accountBound: data.accountBound,
      credentialSaved: data.credentialSaved,
      semesters: options,
    );
  }

  @override
  Future<AgentSourceResult> refresh(
    AgentRunTicket ticket,
    AgentActionView approvedRecord,
    AgentSourceRequest request,
  ) async {
    await _ensure(ticket);
    await store.agent.ensureSourceApproval(ticket, approvedRecord, request);
    int? semester;
    if (request.source == AgentRefreshSource.jw) {
      if (request.firstDay != null || request.endDayExclusive != null) {
        throw const AgentFailure(AgentFailureCode.invalidInput);
      }
      final ref = request.semesterReference;
      if (ref != null) {
        final issued = _semesters[ref];
        if (issued == null || !identical(issued.$1, ticket)) {
          throw const AgentFailure(AgentFailureCode.staleContext);
        }
        final data = await store.readView();
        if (issued.$3 !=
            fingerprint(
              data.cachedSemesters
                  .map((s) => [s.id, s.name, s.selected])
                  .toList(),
            )) {
          throw const AgentFailure(AgentFailureCode.staleContext);
        }
        semester = issued.$2;
      }
    } else {
      final first = request.firstDay, end = request.endDayExclusive;
      if (request.semesterReference != null ||
          first == null ||
          end == null ||
          !isCalendarDate(first) ||
          !isCalendarDate(end) ||
          end.difference(first).inDays < 1 ||
          end.difference(first).inDays > 31) {
        throw const AgentFailure(AgentFailureCode.invalidInput);
      }
    }
    return _run(
      ticket,
      approvedRecord,
      request.source == AgentRefreshSource.jw
          ? _AgentSourceJob.jw
          : _AgentSourceJob.calendar,
      () => request.source == AgentRefreshSource.jw
          ? jw.startSync(semesterId: semester)
          : young.startCalendar(
              firstDay: request.firstDay!,
              lastDay: request.endDayExclusive!.subtract(
                const Duration(days: 1),
              ),
            ),
      request: request,
    );
  }

  @override
  Future<AgentSourceResult> queryActivities(AgentRunTicket ticket) async {
    await _ensure(ticket);
    final record = await store.agent.prepareActionRecord(
      ticket,
      AgentActionKind.sourceRefresh,
      '查询二课活动列表',
      ['固定只读查询；不报名、不退选，不刷新个人日历。'],
    );
    return _run(
      ticket,
      record,
      _AgentSourceJob.activities,
      () => young.startActivities(),
    );
  }

  Future<AgentSourceResult> _run(
    AgentRunTicket ticket,
    AgentActionView record,
    _AgentSourceJob kind,
    Future<void> Function() start, {
    AgentSourceRequest? request,
  }) async {
    await _ensure(ticket);
    if (_job != null) throw const AgentFailure(AgentFailureCode.busy);
    _job = kind;
    _boundJob = null;
    _ticket = ticket;
    _record = record;
    _request = request;
    _cancelled = false;
    final terminal = Completer<void>();
    _terminal = terminal;
    try {
      await start();
      if (!_finished) await terminal.future;
      final at = clock.nowUtc;
      if (kind == _AgentSourceJob.jw) {
        final view = jw.syncView;
        if (view.phase == JwSyncPhase.recovery) {
          throw const AgentFailure(AgentFailureCode.busy);
        }
        final committed = view.importCommitted;
        final failure = _cancelled
            ? 'cancelled'
            : view.failure?.name ??
                  view.identityFailure?.name ??
                  (committed ? null : 'unavailable');
        return AgentSourceResult(
          committed: committed,
          count: committed ? view.courseCount + view.examCount : 0,
          observedAtUtc: at,
          complete: committed && failure == null,
          failure: failure,
        );
      }
      final view = young.syncView;
      if (view.phase == YoungSyncPhase.recovery) {
        throw const AgentFailure(AgentFailureCode.busy);
      }
      final committed = view.committed;
      final failure = _cancelled
          ? 'cancelled'
          : view.failure?.name ??
                view.identityFailure?.name ??
                (committed ? null : 'unavailable');
      if (committed &&
          failure == null &&
          kind == _AgentSourceJob.activities &&
          _boundJob is YoungJobTicket) {
        _deliveryProof = (ticket, _boundJob as YoungJobTicket);
        await validateDelivery();
      }
      final rows = kind == _AgentSourceJob.activities && failure == null
          ? view.activityResults
          : const <YoungActivityView>[];
      final count = kind == _AgentSourceJob.activities
          ? (view.normalization?.activities ?? rows.length)
          : (view.normalization?.events ?? 0);
      final result = AgentSourceResult(
        committed: committed,
        count: count,
        observedAtUtc: at,
        complete:
            committed &&
            failure == null &&
            (kind != _AgentSourceJob.activities ||
                rows.length == count && rows.length <= 20),
        failure: failure,
        activities: rows
            .take(20)
            .map(
              (a) => AgentActivityResult(
                title: a.title,
                place: a.place ?? '',
                startsAtUtc: a.startsAtUtc,
                endsAtUtc: a.endsAtUtc,
                registrationStartsAtUtc: a.registrationStartsAtUtc,
                registrationEndsAtUtc: a.registrationEndsAtUtc,
              ),
            )
            .toList(),
      );
      return result;
    } on AppFailure catch (failure) {
      throw AgentFailure(switch (failure.code) {
        FailureCode.busy || FailureCode.cleanupPending => AgentFailureCode.busy,
        FailureCode.cancelled => AgentFailureCode.cancelled,
        FailureCode.closed => AgentFailureCode.closed,
        FailureCode.ownershipLost => AgentFailureCode.ownershipLost,
        FailureCode.invalidSnapshot => AgentFailureCode.invalidInput,
        _ => AgentFailureCode.storageFailed,
      });
    } finally {
      _job = null;
      _boundJob = null;
      _ticket = null;
      _record = null;
      _terminal = null;
      _changed();
    }
  }

  @override
  Future<void> continueSchool() async {
    if (!waitingForSchool || _continuing || _cancelled || _closed) return;
    _continuing = true;
    try {
      if (_job == _AgentSourceJob.jw) {
        await jw.continueSync();
      } else {
        await young.continueAfterLogin();
      }
    } finally {
      _continuing = false;
      _changed();
    }
  }

  @override
  Future<void> cancelAndDrain() async {
    _cancelled = true;
    clearReadReferences();
    if (_job == _AgentSourceJob.jw || jw.syncView.busy) {
      await jw.cancel();
    }
    if (_job != null && _job != _AgentSourceJob.jw || young.syncView.busy) {
      await young.cancel();
    }
    if (jw.syncView.phase == JwSyncPhase.recovery) await jw.retryRecovery();
    if (young.syncView.phase == YoungSyncPhase.recovery) {
      await young.retryRecovery();
    }
    if (jw.syncView.phase == JwSyncPhase.recovery ||
        young.syncView.phase == YoungSyncPhase.recovery) {
      throw const AgentFailure(AgentFailureCode.busy);
    }
    _changed();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    await cancelAndDrain();
    await shutdownSources();
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _closed = true;
    _semesters.clear();
    await _changes.close();
  }
}
