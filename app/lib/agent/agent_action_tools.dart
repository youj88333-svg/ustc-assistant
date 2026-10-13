import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../core/agent_action_contract.dart';
import '../core/agent_contract.dart';
import '../core/agent_evidence.dart';
import '../core/agent_discussion_contract.dart';
import '../core/agent_source_contract.dart';
import '../core/agent_text.dart';
import '../core/agent_parameter_issue.dart';
import '../core/calendar_contract.dart';
import '../core/calendar_validation.dart';
import '../core/contracts.dart';
import 'agent_free_slots.dart';
import 'agent_change_spec.dart';
import 'agent_request_intent.dart';
import 'agent_read_tools.dart' show parseAgentActionArguments;
import 'agent_tool_contract.dart';
import 'model_gateway_contract.dart';

const _actionToolNames = {
  'propose_local_changes',
  'propose_undo',
  'find_free_slots',
  'propose_planning_preferences',
};
const _sourceToolNames = {
  'query_source_options',
  'request_source_refresh',
  'query_young_activities',
};
const _slotLifetime = Duration(minutes: 10);
const _actionBudget = 20;
const _maxFreeSlotDays = 31;
const _maxSlotReferences = 256;
const _maxSourceSemesterStart = 256;
const _maxSourceSemesterReferences = 512;
const _maxActivityOutputBytes = 7600;

/// Adds the four bounded local planning tools to the existing read-only tools.
///
/// The adapter owns only its read-tools child. C3 business stores remain owned
/// by the application composition root and are never closed here.
final class AgentActionTools implements AgentReadToolsPort {
  AgentActionTools({
    required this.readTools,
    required this.plans,
    required this.calendar,
    required this.tasks,
    required this.preferences,
    required this.preferenceProposals,
    this.sources,
    this.actionRecords,
    this.clock = const SystemClock(),
  });

  final AgentReadToolsPort readTools;
  final AgentLocalPlanPort plans;
  final LocalCalendarPort calendar;
  final LocalTaskPort tasks;
  final AgentPreferencesPort preferences;
  final AgentPreferencesProposalPort preferenceProposals;
  final AgentSourcePort? sources;
  final AgentActionRecordPort? actionRecords;
  final AppClock clock;

  bool _closing = false;
  bool _closed = false;
  final Set<_AgentActionToolSession> _sessions = {};

  late final List<ModelToolDefinition> _definitions = List.unmodifiable([
    ...readTools.definitions,
    _actionTool(
      'propose_local_changes',
      '准备最多 20 项本地个人日程、任务或时间块变化，由应用等待用户批准。修改/删除已有项的引用须来自本轮读取；此工具不直接写入。$agentChangeGuidance',
      {
        'changes': {
          'type': 'array',
          'minItems': 1,
          'maxItems': _actionBudget,
          'items': _actionSchema(),
        },
      },
      required: const ['changes'],
    ),
    _actionTool('propose_undo', '准备撤销本地最近一次可撤销修改。无需传入引用；应用读取当前撤销槽。', const {}),
    _actionTool(
      'find_free_slots',
      '在最多 31 天的本地日程投影中确定性查找空闲时段；未覆盖范围不会被表述为空闲。',
      {
        'first_day': _stringSchema(pattern: r'^\d{4}-\d{2}-\d{2}$'),
        'end_day_exclusive': _stringSchema(pattern: r'^\d{4}-\d{2}-\d{2}$'),
        'weekdays': _intArraySchema(minimum: 1, maximum: 7, maxItems: 7),
        'start_minute': _intSchema(minimum: 0, maximum: 1439),
        'end_minute': _intSchema(minimum: 1, maximum: 1440),
        'block_minutes': _intSchema(minimum: 1, maximum: 480),
        'break_minutes': _intSchema(minimum: 0, maximum: 240),
        'avoid': _avoidSchema(),
        'include_hidden': _boolSchema(),
        'include_skipped': _boolSchema(),
        'max_candidates': _intSchema(minimum: 1, maximum: 20),
        'deadline': _stringSchema(
          pattern: r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?\+08:00$',
        ),
      },
      required: const ['first_day', 'end_day_exclusive'],
    ),
    _actionTool(
      'propose_planning_preferences',
      '提出结构化规划偏好变更；省略字段沿用当前值，仍需用户批准。',
      {
        'weekdays': _intArraySchema(minimum: 1, maximum: 7, maxItems: 7),
        'start_minute': _intSchema(minimum: 0, maximum: 1439),
        'end_minute': _intSchema(minimum: 1, maximum: 1440),
        'block_minutes': _intSchema(minimum: 1, maximum: 480),
        'break_minutes': _intSchema(minimum: 0, maximum: 240),
        'avoid': _avoidSchema(),
      },
    ),
    if (sources != null && actionRecords != null) ...[
      _actionTool(
        'query_source_options',
        '读取教务/二课来源绑定状态与分页后的学期短引用，不读取学校账号标识。',
        {
          'semester_start': {
            ..._intSchema(minimum: 0, maximum: _maxSourceSemesterStart),
            'default': 0,
          },
          'limit': {..._intSchema(minimum: 1, maximum: 10), 'default': 10},
        },
      ),
      _actionTool(
        'request_source_refresh',
        '提出固定教务学期或二课活动日历刷新；刷新来源和范围必须来自本轮用户请求，仍需应用批准。',
        {
          'source': _stringSchema(enumValues: const ['jw', 'youngCalendar']),
          'semester_ref': _stringSchema(maxLength: 64),
          'first_day': _stringSchema(pattern: r'^\d{4}-\d{2}-\d{2}$'),
          'end_day_exclusive': _stringSchema(pattern: r'^\d{4}-\d{2}-\d{2}$'),
        },
        required: const ['source'],
      ),
      _actionTool(
        'query_young_activities',
        '按用户本轮明确要求读取二课活动；返回固定字段，不刷新日历或声明已验证个人报名。',
        const {},
      ),
    ],
  ]);

  @override
  List<ModelToolDefinition> get definitions => _definitions;

  @override
  AgentToolSession openSession() {
    if (_closing || _closed) {
      throw const AgentFailure(AgentFailureCode.closed);
    }
    final session = _AgentActionToolSession(this, readTools.openSession());
    _sessions.add(session);
    return session;
  }

  @override
  Future<void> cancelAndDrain() async {
    await Future.wait([
      if (sources != null) sources!.cancelAndDrain(),
      readTools.cancelAndDrain(),
    ]);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closing = true;
    for (final session in List<_AgentActionToolSession>.of(_sessions)) {
      session.revoke();
    }
    try {
      if (sources != null) {
        try {
          await sources!.cancelAndDrain();
        } finally {
          await sources!.close();
        }
      }
    } finally {
      try {
        await readTools.close();
      } finally {
        _closed = true;
      }
    }
  }
}

sealed class _PendingAgentDecision {
  const _PendingAgentDecision();
  AgentActionView get view;
  String get title;
  int get count;
}

final class _PendingLocalPlan extends _PendingAgentDecision {
  const _PendingLocalPlan(this.plan, this.title, this.count);
  final AgentLocalPlan plan;
  @override
  final String title;
  @override
  final int count;
  @override
  AgentActionView get view => plan.view;
}

final class _PendingPreferences extends _PendingAgentDecision {
  const _PendingPreferences(this.ticket, this.record, this.title);
  final AgentRunTicket ticket;
  final AgentActionView record;
  @override
  final String title;
  @override
  int get count => 1;
  @override
  AgentActionView get view => record;
}

final class _PendingSourceRefresh extends _PendingAgentDecision {
  const _PendingSourceRefresh(
    this.ticket,
    this.record,
    this.request,
    this.title,
  );
  final AgentRunTicket ticket;
  final AgentActionView record;
  final AgentSourceRequest request;
  @override
  final String title;
  @override
  int get count => 1;
  @override
  AgentActionView get view => record;
}

final class _CachedSlot {
  const _CachedSlot({
    required this.startsAtUtc,
    required this.endsAtUtc,
    required this.context,
    required this.revision,
    required this.preferencesRevision,
    required this.expiresAtUtc,
  });
  final DateTime startsAtUtc;
  final DateTime endsAtUtc;
  final CalendarContext context;
  final int revision;
  final int preferencesRevision;
  final DateTime expiresAtUtc;
}

final class _AgentActionToolSession
    implements
        AgentToolSession,
        AgentLocalReferenceSession,
        AgentDiscussionToolSession,
        AgentInteractiveToolSession,
        AgentToolScopeSession {
  _AgentActionToolSession(this._owner, AgentToolSession readSession)
    : _readSession = readSession {
    _sourceChanges = _owner.sources?.changes.listen((_) => _notify());
  }

  final AgentActionTools _owner;
  AgentToolSession _readSession;
  late final StreamSubscription<void>? _sourceChanges;
  AgentRunTicket? _ticket;
  String? _humanQuestion;
  bool _personalDataRestricted = false;

  @override
  void restrictPersonalData() => _personalDataRestricted = true;
  final Map<String, _CachedSlot> _slots = {};
  final Map<String, String> _semesterReferences = {};
  final StreamController<void> _changes = StreamController<void>.broadcast();
  _PendingAgentDecision? _pending;
  bool _revoked = false;
  bool _executing = false;
  bool _decisionInFlight = false;
  bool _contextInvalidated = false;
  bool _readerUnavailable = false;
  bool _usedFreeSlotSearch = false;
  int _changeBudgetUsed = 0;

  @override
  List<AgentEvidence> get evidence => _readSession.evidence;

  @override
  AgentActionView? get pendingAction => _pending?.view;

  @override
  bool get waitingForSchool => _owner.sources?.waitingForSchool ?? false;

  @override
  Stream<void> get interactiveChanges => _changes.stream;

  @override
  bool get contextInvalidated => _contextInvalidated;

  @override
  void acknowledgeContextInvalidated() {
    _ensureActive();
    _contextInvalidated = false;
  }

  @override
  void bindRun(AgentRunTicket ticket, String humanQuestion) {
    _ensureActive();
    AgentText.requireSafe(humanQuestion, maxCharacters: 24000);
    final previous = _ticket;
    if (previous != null &&
        (!identical(previous, ticket) || _humanQuestion != humanQuestion)) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    _ticket = ticket;
    _humanQuestion = humanQuestion;
  }

  @override
  Future<(CalendarReference, int)> resolveEventReference(String token) async {
    _ensureActive();
    final resolver = _readSession;
    if (resolver is! AgentLocalReferenceSession) {
      throw const AgentFailure(AgentFailureCode.toolUnavailable);
    }
    return (resolver as AgentLocalReferenceSession).resolveEventReference(
      token,
    );
  }

  @override
  Future<(TaskReference, int)> resolveTaskReference(String token) async {
    _ensureActive();
    final resolver = _readSession;
    if (resolver is! AgentLocalReferenceSession) {
      throw const AgentFailure(AgentFailureCode.toolUnavailable);
    }
    return (resolver as AgentLocalReferenceSession).resolveTaskReference(token);
  }

  @override
  Future<String> selectForDiscussion(AgentDiscussionSelection selection) async {
    _ensureActive();
    await validateDelivery();
    final reader = _readSession;
    if (reader is! AgentDiscussionToolSession) {
      throw const AgentFailure(AgentFailureCode.toolUnavailable);
    }
    final result = await (reader as AgentDiscussionToolSession)
        .selectForDiscussion(selection);
    await validateDelivery();
    return result;
  }

  @override
  Future<void> validateDelivery() async {
    _ensureActive();
    if (_readerUnavailable) {
      throw const AgentFailure(AgentFailureCode.closed);
    }
    await _readSession.validateDelivery();
    final source = _owner.sources;
    if (source is AgentSourceDeliveryPort) {
      await (source as AgentSourceDeliveryPort).validateDelivery();
    }
    _ensureActive();
  }

  @override
  Future<AgentToolResult> execute(ModelToolCall call) async {
    if (_executing) return _result('busy', failure: 'busy');
    try {
      _ensureActive();
      if (_pending != null || _decisionInFlight) {
        return _result('busy', failure: 'busy');
      }
      if (_contextInvalidated) {
        return _result('stale', failure: 'staleReference');
      }
      if (agentPersonalToolNames.contains(call.name) &&
          (_personalDataRestricted ||
              agentRestrictsPersonalData(_humanQuestion ?? ''))) {
        return _result('unavailable', failure: 'unavailable');
      }
      AgentText.requireSafe(call.argumentsJson, maxCharacters: 16384);
      _executing = true;
      if (agentReadToolNames.contains(call.name)) {
        await validateDelivery();
        final result = await _readSession.execute(call);
        await validateDelivery();
        return result;
      }
      if (!_actionToolNames.contains(call.name) &&
          !_sourceToolNames.contains(call.name)) {
        return _result('unavailable', failure: 'unavailable');
      }
      if (_sourceToolNames.contains(call.name) &&
          (_owner.sources == null || _owner.actionRecords == null)) {
        return _result('unavailable', failure: 'unavailable');
      }
      await validateDelivery();
      late final Map<String, Object?> args;
      try {
        args = parseAgentActionArguments(call.argumentsJson);
      } on AgentFailure catch (failure) {
        if (failure.code != AgentFailureCode.invalidInput) rethrow;
        throw const AgentParameterIssue(
          reason: AgentParameterReason.malformedArguments,
        );
      }
      final result = switch (call.name) {
        'propose_local_changes' => await _proposeLocalChanges(args),
        'propose_undo' => await _proposeUndo(args),
        'find_free_slots' => await _findFreeSlots(args),
        'propose_planning_preferences' => await _proposePlanningPreferences(
          args,
        ),
        'query_source_options' => await _querySourceOptions(args),
        'request_source_refresh' => await _requestSourceRefresh(args),
        'query_young_activities' => await _queryYoungActivities(args),
        _ => _result('unavailable', failure: 'unavailable'),
      };
      _ensureActive();
      try {
        await validateDelivery();
      } on Object {
        await _discardUndeliverablePending();
        rethrow;
      }
      return result;
    } on AgentParameterIssue catch (issue) {
      return AgentToolResult(
        status: 'invalidRequest',
        failure: 'invalidRequest',
        validation: issue,
        data: {
          'repair': issue.repairHint,
          if (issue.action != null)
            'action_rules': agentChangeSpecs[issue.action]!.describe(
              issue.action!,
            ),
        },
      );
    } on AgentFailure catch (failure) {
      return _agentFailure(failure);
    } on CalendarFailure catch (failure) {
      return _calendarFailure(failure);
    } on Object {
      return _result('failure', failure: 'storageFailed');
    } finally {
      _executing = false;
    }
  }

  Future<AgentToolResult> _querySourceOptions(Map<String, Object?> args) async {
    _requireKeys(args, const {'semester_start', 'limit'}, const {});
    final start =
        _optionalInt(args, 'semester_start', 0, _maxSourceSemesterStart) ?? 0;
    final limit = _optionalInt(args, 'limit', 1, 10) ?? 10;
    final ticket = _requireTicket();
    final options = await _requireSources().readOptions(ticket);
    _ensureActive();
    await validateDelivery();
    _validateSourceOptions(options);

    final rememberedOptions = options.semesters
        .where((option) => option.lastUsed)
        .toList();
    final remembered = rememberedOptions.isEmpty
        ? null
        : rememberedOptions.single;
    final pageOptions = options.semesters.skip(start).take(limit).toList();
    final neededReferences = <String>{
      ...pageOptions.map((option) => option.reference),
      if (remembered != null) remembered.reference,
    };
    final signedReferences = _semesterReferences.values.toSet();
    final newReferences = neededReferences
        .where((reference) => !signedReferences.contains(reference))
        .length;
    if (_semesterReferences.length + newReferences >
        _maxSourceSemesterReferences) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }

    final semesters = <Map<String, Object?>>[];
    for (final option in pageOptions) {
      final reference = _semesterTokenFor(option.reference);
      semesters.add({
        'semester_ref': reference,
        'label': option.label,
        'last_used': option.lastUsed,
      });
    }
    final rememberedData = remembered == null
        ? null
        : {
            'semester_ref': _semesterTokenFor(remembered.reference),
            'label': remembered.label,
            'last_used': true,
          };
    final nextStart = start + pageOptions.length;
    final result = _result(
      'success',
      data: {
        'account_bound': options.accountBound,
        'credential_saved': options.credentialSaved,
        'semesters': semesters,
        'total': options.semesters.length,
        'returned': semesters.length,
        'next_start': nextStart < options.semesters.length ? nextStart : null,
        'remembered_semester': rememberedData,
      },
    );
    if (utf8.encode(jsonEncode(result.toMap())).length >= 10000) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }
    return result;
  }

  Future<AgentToolResult> _requestSourceRefresh(
    Map<String, Object?> args,
  ) async {
    final sourceName = _requiredEnum(args, 'source', const {
      'jw',
      'youngCalendar',
    });
    final source = sourceName == 'jw'
        ? AgentRefreshSource.jw
        : AgentRefreshSource.youngCalendar;
    if (!_questionRequestsRefresh(source)) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    _ensureNoPending();
    if (_changeBudgetUsed >= _actionBudget) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }

    final AgentSourceRequest request;
    final String title;
    final List<String> details;
    if (source == AgentRefreshSource.jw) {
      _requireKeys(args, const {'source', 'semester_ref'}, const {'source'});
      final ticket = _requireTicket();
      final options = await _requireSources().readOptions(ticket);
      _ensureActive();
      final chosen = _chooseSemester(args, options);
      request = AgentSourceRequest(
        AgentRefreshSource.jw,
        semesterReference: chosen.reference,
      );
      title = '刷新教务学期';
      details = ['来源：教务', '学期：${chosen.label}'];
    } else {
      _requireKeys(
        args,
        const {'source', 'first_day', 'end_day_exclusive'},
        const {'source', 'first_day', 'end_day_exclusive'},
      );
      final firstDay = _requiredBeijingDate(args, 'first_day');
      final endDayExclusive = _requiredBeijingDate(args, 'end_day_exclusive');
      final span = endDayExclusive.difference(firstDay).inDays;
      if (span < 1 || span > _maxFreeSlotDays) {
        throw const AgentFailure(AgentFailureCode.invalidInput);
      }
      request = AgentSourceRequest(
        AgentRefreshSource.youngCalendar,
        firstDay: firstDay,
        endDayExclusive: endDayExclusive,
      );
      title = '刷新二课活动日历';
      details = [
        '来源：二课活动日历',
        '日期：${_dateOnly(firstDay)} 至 ${_dateOnly(endDayExclusive)}（结束日不含）',
      ];
    }

    final ticket = _requireTicket();
    final records = _requireActionRecords();
    final record = await records.prepareActionRecord(
      ticket,
      AgentActionKind.sourceRefresh,
      title,
      details,
      warning: '批准后才会启动本来源刷新。',
    );
    if (_revoked) {
      await _settleSourceRecord(ticket, record, AgentActionStatus.interrupted);
      throw const AgentFailure(AgentFailureCode.cancelled);
    }
    _validateActionRecord(record);
    _changeBudgetUsed++;
    _pending = _PendingSourceRefresh(ticket, record, request, title);
    _notify();
    return _waitingResult(_pending!);
  }

  Future<AgentToolResult> _queryYoungActivities(
    Map<String, Object?> args,
  ) async {
    _requireKeys(args, const {}, const {});
    if (!_questionRequestsYoungActivities()) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    final result = await _requireSources().queryActivities(_requireTicket());
    _ensureActive();
    await validateDelivery();
    final failed = _sourceFailureResult(result.failure);
    if (failed != null) return failed;
    if (result.count < 0 ||
        result.activities.length > 1000 ||
        !result.observedAtUtc.isUtc) {
      throw const AgentFailure(AgentFailureCode.storageFailed);
    }
    final activities = <Map<String, Object?>>[];
    var activityBytes = 2;
    var outputLimited = false;
    for (final activity in result.activities.take(20)) {
      if (!activity.startsAtUtc.isUtc ||
          !activity.endsAtUtc.isUtc ||
          !activity.endsAtUtc.isAfter(activity.startsAtUtc) ||
          activity.registrationStartsAtUtc != null &&
              !activity.registrationStartsAtUtc!.isUtc ||
          activity.registrationEndsAtUtc != null &&
              !activity.registrationEndsAtUtc!.isUtc) {
        throw const AgentFailure(AgentFailureCode.storageFailed);
      }
      AgentText.requireSafe(activity.title, maxCharacters: 200);
      AgentText.requireSafe(activity.place, maxCharacters: 200);
      final item = {
        'title': _boundedUtf8(activity.title, 120),
        'place': _boundedUtf8(activity.place, 60),
        'starts_at': _beijingDateTime(activity.startsAtUtc),
        'ends_at': _beijingDateTime(activity.endsAtUtc),
        'registration_starts_at': activity.registrationStartsAtUtc == null
            ? null
            : _beijingDateTime(activity.registrationStartsAtUtc!),
        'registration_ends_at': activity.registrationEndsAtUtc == null
            ? null
            : _beijingDateTime(activity.registrationEndsAtUtc!),
      };
      final itemBytes = utf8.encode(jsonEncode(item)).length;
      if (activityBytes + itemBytes + (activities.isEmpty ? 0 : 1) >
          _maxActivityOutputBytes) {
        outputLimited = true;
        break;
      }
      activityBytes += itemBytes + (activities.isEmpty ? 0 : 1);
      activities.add(item);
    }
    if (result.count < activities.length) {
      throw const AgentFailure(AgentFailureCode.storageFailed);
    }
    final truncated =
        result.count > activities.length || !result.complete || outputLimited;
    return _result(
      truncated ? 'partial' : (result.count == 0 ? 'empty' : 'success'),
      data: {
        'activities': activities,
        'total': result.count,
        'returned': activities.length,
        'truncated': truncated,
        'complete': result.complete,
        'observed_at': _beijingDateTime(result.observedAtUtc),
        'registration_verified': false,
      },
    );
  }

  AgentSourcePort _requireSources() {
    final value = _owner.sources;
    if (value == null) {
      throw const AgentFailure(AgentFailureCode.toolUnavailable);
    }
    return value;
  }

  AgentActionRecordPort _requireActionRecords() {
    final value = _owner.actionRecords;
    if (value == null) {
      throw const AgentFailure(AgentFailureCode.toolUnavailable);
    }
    return value;
  }

  void _validateSemesterOption(AgentSemesterOption option) {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,63}$').hasMatch(option.reference) ||
        option.label.trim().isEmpty ||
        option.label.length > 120) {
      throw const AgentFailure(AgentFailureCode.storageFailed);
    }
    AgentText.requireSafe(option.label, maxCharacters: 120);
  }

  void _validateSourceOptions(AgentSourceOptions options) {
    final references = <String>{};
    var lastUsedCount = 0;
    for (final option in options.semesters) {
      _validateSemesterOption(option);
      if (!references.add(option.reference)) {
        throw const AgentFailure(AgentFailureCode.storageFailed);
      }
      if (option.lastUsed) lastUsedCount++;
    }
    if (lastUsedCount > 1) {
      throw const AgentFailure(AgentFailureCode.storageFailed);
    }
  }

  String _semesterTokenFor(String sourceReference) {
    for (final entry in _semesterReferences.entries) {
      if (entry.value == sourceReference) return entry.key;
    }
    if (_semesterReferences.length >= _maxSourceSemesterReferences) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }
    for (var attempt = 0; attempt < 8; attempt++) {
      final token = _newToken('semester_');
      if (_semesterReferences.containsKey(token)) continue;
      _semesterReferences[token] = sourceReference;
      return token;
    }
    throw const AgentFailure(AgentFailureCode.resourceLimit);
  }

  AgentSemesterOption _chooseSemester(
    Map<String, Object?> args,
    AgentSourceOptions options,
  ) {
    _validateSourceOptions(options);
    final explicit = _humanSemesterOption(options.semesters);
    final semesterRef = args['semester_ref'];
    if (semesterRef != null) {
      if (semesterRef is! String ||
          semesterRef.length > 64 ||
          !RegExp(r'^semester_[a-f0-9]{32}$').hasMatch(semesterRef)) {
        throw const AgentFailure(AgentFailureCode.invalidInput);
      }
      final sourceReference = _semesterReferences[semesterRef];
      if (sourceReference == null) {
        throw const AgentFailure(AgentFailureCode.staleContext);
      }
      for (final option in options.semesters) {
        if (option.reference == sourceReference) {
          final explicitlyNamed = explicit?.reference == option.reference;
          final savedDefault =
              explicit == null &&
              !_questionHasSemesterSpecifier() &&
              option.lastUsed;
          if (!explicitlyNamed && !savedDefault) {
            throw const AgentFailure(AgentFailureCode.invalidInput);
          }
          return option;
        }
      }
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    if (explicit != null) return explicit;
    if (_questionHasSemesterSpecifier()) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    final lastUsed = options.semesters
        .where((value) => value.lastUsed)
        .toList();
    if (lastUsed.length != 1) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    _validateSemesterOption(lastUsed.single);
    return lastUsed.single;
  }

  AgentSemesterOption? _humanSemesterOption(List<AgentSemesterOption> options) {
    final question = (_humanQuestion ?? '').toLowerCase().replaceAll(
      RegExp(r'\s+'),
      '',
    );
    final matches = options.where((option) {
      final label = option.label.toLowerCase().replaceAll(RegExp(r'\s+'), '');
      return label.isNotEmpty && question.contains(label);
    }).toList();
    if (matches.length > 1) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    return matches.isEmpty ? null : matches.single;
  }

  bool _questionHasSemesterSpecifier() => RegExp(
    r'20\d{2}|第[一二三四五六]学期|春季?学期|秋季?学期|夏季?学期|冬季?学期',
    caseSensitive: false,
  ).hasMatch(_humanQuestion ?? '');

  bool _questionRequestsRefresh(AgentRefreshSource source) {
    final question = (_humanQuestion ?? '').toLowerCase();
    final negatesRefresh = RegExp(
      r'(?:不要|不需要|无需|不用|不必|不许|别|不想|不)(?:给我|再|直接|去)?(?:刷新|同步|更新|重新采集|拉取)|(?:don\x27t|do not|no|without|not)\s+(?:refresh|sync|update|fetch)',
      caseSensitive: false,
    ).hasMatch(question);
    if (negatesRefresh) return false;
    final hasRefreshIntent = RegExp(
      r'刷新|同步|更新|重新采集|拉取|refresh|sync|update|fetch',
      caseSensitive: false,
    ).hasMatch(question);
    if (!hasRefreshIntent) return false;
    return switch (source) {
      AgentRefreshSource.jw => RegExp(
        r'\bjw\b|教务|课表|学期课程|学校课程',
        caseSensitive: false,
      ).hasMatch(question),
      AgentRefreshSource.youngCalendar => RegExp(
        r'young|二课|青春科大|青年|活动日历|青年活动',
        caseSensitive: false,
      ).hasMatch(question),
    };
  }

  bool _questionRequestsYoungActivities() {
    final question = (_humanQuestion ?? '').toLowerCase();
    final negatesQuery = RegExp(
      r'(?:不要|不需要|无需|不用|不必|不许|别|不想|不)(?:给我|再|去|直接)?(?:查询|查看|看|查|列出)|(?:don\x27t|do not|no|without|not)\s+(?:query|look|check|list|show)',
      caseSensitive: false,
    ).hasMatch(question);
    final asksToRead = RegExp(
      r'看看|查看|查询|查一下|查下|列出|有哪些|有什么|有啥|安排|show|list|what|find|check',
      caseSensitive: false,
    ).hasMatch(question);
    return !negatesQuery &&
        asksToRead &&
        RegExp(r'young|二课|青春科大|青年', caseSensitive: false).hasMatch(question) &&
        RegExp(r'活动|event', caseSensitive: false).hasMatch(question);
  }

  Future<void> _settleSourceRecord(
    AgentRunTicket ticket,
    AgentActionView record,
    AgentActionStatus status,
  ) async {
    await _requireActionRecords().settleActionRecord(ticket, record, status);
  }

  void _validateActionRecord(AgentActionView record) {
    if (record.kind != AgentActionKind.sourceRefresh ||
        record.status != AgentActionStatus.proposed) {
      throw const AgentFailure(AgentFailureCode.storageFailed);
    }
    AgentText.requireSafe(record.title, maxCharacters: 500);
    AgentText.requireSafe(record.warning, maxCharacters: 1000);
    for (final detail in record.details) {
      AgentText.requireSafe(detail, maxCharacters: 500);
    }
  }

  AgentToolResult? _sourceFailureResult(String? failure) {
    if (failure == null) return null;
    final mapped = switch (failure) {
      'busy' => ('busy', 'busy'),
      'consentRequired' => ('consentRequired', 'consentRequired'),
      'cancelled' => ('cancelled', 'cancelled'),
      'staleReference' => ('stale', 'staleReference'),
      'accessRestricted' => ('accessRestricted', 'accessRestricted'),
      'resourceLimit' => ('resourceLimit', 'resourceLimit'),
      'storageFailed' => ('failure', 'storageFailed'),
      'ownershipLost' => ('failure', 'ownershipLost'),
      _ => ('unavailable', 'unavailable'),
    };
    return _result(mapped.$1, failure: mapped.$2);
  }

  DateTime _requiredBeijingDate(Map<String, Object?> args, String key) {
    final value = _requiredString(args, key, maxLength: 10);
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
    if (match == null) throw const AgentFailure(AgentFailureCode.invalidInput);
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final date = DateTime.utc(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    return date;
  }

  String _dateOnly(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  String _beijingDateTime(DateTime utc) {
    final local = utc.toUtc().add(const Duration(hours: 8));
    return '${_dateOnly(local)}T${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}+08:00';
  }

  String _boundedUtf8(String value, int maximumBytes) {
    final result = StringBuffer();
    var bytes = 0;
    for (final rune in value.runes) {
      final character = String.fromCharCode(rune);
      final length = utf8.encode(character).length;
      if (bytes + length > maximumBytes) break;
      result.write(character);
      bytes += length;
    }
    return result.toString();
  }

  Future<AgentToolResult> _proposeLocalChanges(
    Map<String, Object?> args,
  ) async {
    _requireKeys(args, const {'changes'}, const {'changes'});
    final rawChanges = args['changes'];
    if (rawChanges is! List<Object?> ||
        rawChanges.isEmpty ||
        rawChanges.length > _actionBudget) {
      throw const AgentParameterIssue(
        reason: AgentParameterReason.limitExceeded,
        field: AgentParameterField.changes,
      );
    }
    _ensureNoPending();
    if (_changeBudgetUsed + rawChanges.length > _actionBudget) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }
    final ticket = _requireTicket();
    final (context, revision) = await _owner.plans.readPlanContext();
    final changes = <AgentLocalChange>[];
    final localTaskKeys = <String>{};
    var usesSlot = false;
    for (var index = 0; index < rawChanges.length; index++) {
      final raw = rawChanges[index];
      if (raw is! Map<String, Object?>) {
        throw AgentParameterIssue(
          reason: AgentParameterReason.invalidValue,
          field: AgentParameterField.changes,
          changeIndex: index,
        );
      }
      if (raw['slot_ref'] != null) usesSlot = true;
      try {
        changes.add(await _mapChange(raw, context, revision, localTaskKeys));
      } on AgentParameterIssue catch (issue) {
        throw issue.atChange(index, agentChangeType(raw['type']));
      } on AgentFailure catch (failure) {
        if (failure.code != AgentFailureCode.invalidInput) rethrow;
        throw AgentParameterIssue(
          reason: AgentParameterReason.invalidValue,
          action: agentChangeType(raw['type']),
          changeIndex: index,
        );
      } on CalendarFailure catch (failure) {
        if (failure.code != CalendarFailureCode.invalidInput) rethrow;
        throw AgentParameterIssue(
          reason: AgentParameterReason.invalidValue,
          action: agentChangeType(raw['type']),
          changeIndex: index,
        );
      }
    }
    final current = await _owner.plans.readPlanContext();
    if (current.$1 != context || current.$2 != revision) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    final requireFree = _usedFreeSlotSearch || _questionRequiresFree();
    final preferencesRevision = requireFree || usesSlot
        ? (await _owner.preferences.readPlanningPreferences()).revision
        : null;
    final plan = await _owner.plans.prepareLocalPlan(
      ticket,
      context,
      revision,
      changes,
      requireFree: requireFree,
      preferencesRevision: preferencesRevision,
    );
    if (_revoked) {
      _owner.plans.revokeLocalPlans(ticket);
      throw const AgentFailure(AgentFailureCode.cancelled);
    }
    if (plan.ticket != ticket ||
        plan.context != context ||
        plan.revision != revision ||
        plan.changes.length != changes.length ||
        plan.view.status != AgentActionStatus.proposed) {
      _owner.plans.revokeLocalPlans(ticket);
      throw const AgentFailure(AgentFailureCode.storageFailed);
    }
    _changeBudgetUsed += changes.length;
    _pending = _PendingLocalPlan(plan, '待确认的本地日程与任务变化', changes.length);
    _notify();
    return _waitingResult(_pending!);
  }

  Future<AgentLocalChange> _mapChange(
    Map<String, Object?> value,
    CalendarContext context,
    int revision,
    Set<String> localTaskKeys,
  ) async {
    final type = _requiredString(value, 'type', maxLength: 40);
    final action = agentChangeType(type);
    if (action == null) {
      throw const AgentParameterIssue(
        reason: AgentParameterReason.invalidValue,
        field: AgentParameterField.type,
      );
    }
    final spec = agentChangeSpecs[action]!;
    _requireKeys(value, spec.allowedFields, spec.requiredFields);
    switch (type) {
      case 'create_personal':
        final allDay = _optionalBool(value, 'all_day') ?? false;
        final weekly = _optionalBool(value, 'weekly') ?? false;
        final untilDay = _optionalDate(value, 'until_day');
        final draft = PersonalEventDraft(
          title: _requiredText(value, 'title', 200),
          start: _requiredCalendarValue(
            value['start'],
            allDay,
            field: AgentParameterField.start,
          ),
          end: _requiredCalendarValue(
            value['end'],
            allDay,
            field: AgentParameterField.end,
          ),
          allDay: allDay,
          weekly: weekly,
          untilDay: untilDay,
          location: _optionalText(value, 'location', 200) ?? '',
          note: _optionalText(value, 'note', 4000) ?? '',
        );
        validatePersonalDraft(draft);
        return AgentCalendarChange(CreatePersonalEvent(draft));

      case 'update_personal':
        final scope = _requiredEnum(value, 'scope', const {
          'series',
          'occurrence',
        });
        final (target, targetRevision) = await _resolveEvent(
          _requiredString(value, 'event_ref', maxLength: 64),
          context,
          revision,
        );
        if (target.identity.kind != CalendarKind.personal) {
          throw const AgentFailure(AgentFailureCode.invalidInput);
        }
        _requireSameRevision(targetRevision, revision);
        final startPresent = value.containsKey('start');
        final endPresent = value.containsKey('end');
        if (startPresent != endPresent) {
          throw const AgentFailure(AgentFailureCode.invalidInput);
        }
        final allDay = _optionalBool(value, 'all_day');
        if (allDay != null && !startPresent || startPresent && allDay == null) {
          throw const AgentFailure(AgentFailureCode.invalidInput);
        }
        final weekly = _optionalBool(value, 'weekly');
        final untilDay = _optionalDate(value, 'until_day');
        final clearUntil = _optionalBool(value, 'clear_until') ?? false;
        if (clearUntil && untilDay != null ||
            scope == 'occurrence' &&
                (weekly != null ||
                    value.containsKey('until_day') ||
                    value.containsKey('clear_until'))) {
          throw const AgentFailure(AgentFailureCode.invalidInput);
        }
        if (startPresent) {
          final start = _requiredCalendarValue(
            value['start'],
            allDay!,
            field: AgentParameterField.start,
          );
          final end = _requiredCalendarValue(
            value['end'],
            allDay,
            field: AgentParameterField.end,
          );
          if (!end.isAfter(start)) {
            throw const AgentFailure(AgentFailureCode.invalidInput);
          }
        }
        if (!_hasAny(value, const {
          'title',
          'start',
          'all_day',
          'weekly',
          'until_day',
          'clear_until',
          'location',
          'note',
        })) {
          throw const AgentFailure(AgentFailureCode.invalidInput);
        }
        return AgentPersonalPatch(
          target,
          entireSeries: scope == 'series',
          title: _optionalText(value, 'title', 200),
          start: startPresent
              ? _requiredCalendarValue(
                  value['start'],
                  allDay!,
                  field: AgentParameterField.start,
                )
              : null,
          end: endPresent
              ? _requiredCalendarValue(
                  value['end'],
                  allDay!,
                  field: AgentParameterField.end,
                )
              : null,
          allDay: allDay,
          weekly: weekly,
          untilDay: untilDay,
          clearUntil: clearUntil,
          location: _optionalText(value, 'location', 200),
          note: _optionalText(value, 'note', 4000),
        );

      case 'personal_state':
        if (!_hasAny(value, const {'completed', 'skipped'})) {
          throw const AgentFailure(AgentFailureCode.invalidInput);
        }
        final (target, targetRevision) = await _resolveEvent(
          _requiredString(value, 'event_ref', maxLength: 64),
          context,
          revision,
        );
        if (target.identity.kind != CalendarKind.personal) {
          throw const AgentFailure(AgentFailureCode.invalidInput);
        }
        _requireSameRevision(targetRevision, revision);
        return AgentCalendarChange(
          SetPersonalOccurrenceState(
            target,
            completed: _optionalBool(value, 'completed'),
            skipped: _optionalBool(value, 'skipped'),
          ),
        );

      case 'delete_personal':
        final (target, targetRevision) = await _resolveEvent(
          _requiredString(value, 'event_ref', maxLength: 64),
          context,
          revision,
        );
        if (target.identity.kind != CalendarKind.personal ||
            target.identity.ordinal != 0) {
          throw const AgentFailure(AgentFailureCode.invalidInput);
        }
        _requireSameRevision(targetRevision, revision);
        return AgentCalendarChange(
          DeletePersonalSeries(target, confirmed: true),
        );

      case 'create_task':
        final localKey = _requiredString(value, 'local_key', maxLength: 32);
        if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_-]{0,31}$').hasMatch(localKey) ||
            !localTaskKeys.add(localKey)) {
          throw const AgentParameterIssue(
            reason: AgentParameterReason.duplicateTaskKey,
            field: AgentParameterField.local_key,
          );
        }
        return AgentCreateTask(
          localKey,
          _taskDraft(value, titleRequired: true),
        );

      case 'update_task':
        final (target, targetRevision) = await _resolveTask(
          _requiredString(value, 'task_ref', maxLength: 64),
          context,
          revision,
        );
        _requireSameRevision(targetRevision, revision);
        final patch = _taskPatch(value, target);
        return patch;

      case 'task_state':
        final (target, targetRevision) = await _resolveTask(
          _requiredString(value, 'task_ref', maxLength: 64),
          context,
          revision,
        );
        _requireSameRevision(targetRevision, revision);
        return AgentCalendarChange(
          SetTaskStatus(
            target,
            TaskStatus.values.byName(
              _requiredEnum(value, 'status', const {
                'active',
                'blocked',
                'completed',
                'cancelled',
              }),
            ),
          ),
        );

      case 'delete_task':
        final (target, targetRevision) = await _resolveTask(
          _requiredString(value, 'task_ref', maxLength: 64),
          context,
          revision,
        );
        _requireSameRevision(targetRevision, revision);
        return AgentCalendarChange(DeleteTask(target, confirmed: true));

      case 'create_block':
        final hasTaskRef = value.containsKey('task_ref');
        final hasTaskKey = value.containsKey('task_key');
        if (hasTaskRef == hasTaskKey) {
          throw const AgentParameterIssue(
            reason: AgentParameterReason.missingTaskTarget,
            field: AgentParameterField.task_key,
          );
        }
        final draft = await _blockDraft(value);
        if (hasTaskKey) {
          final key = _requiredString(value, 'task_key', maxLength: 32);
          if (!localTaskKeys.contains(key)) {
            throw const AgentParameterIssue(
              reason: AgentParameterReason.unknownTaskKey,
              field: AgentParameterField.task_key,
            );
          }
          return AgentDependentBlock(key, draft);
        }
        final (task, targetRevision) = await _resolveTask(
          _requiredString(value, 'task_ref', maxLength: 64),
          context,
          revision,
        );
        _requireSameRevision(targetRevision, revision);
        return AgentCalendarChange(CreatePlanBlock(task, draft));

      case 'update_block':
        final (target, targetRevision) = await _resolveEvent(
          _requiredString(value, 'event_ref', maxLength: 64),
          context,
          revision,
        );
        if (target.identity.kind != CalendarKind.planBlock) {
          throw const AgentFailure(AgentFailureCode.invalidInput);
        }
        _requireSameRevision(targetRevision, revision);
        final slot = await _optionalSlot(value, context, revision);
        final startPresent = value.containsKey('start');
        final endPresent = value.containsKey('end');
        if (slot != null && (startPresent || endPresent) ||
            slot == null && startPresent != endPresent ||
            slot == null &&
                !startPresent &&
                !_hasAny(value, const {'location', 'note'})) {
          throw const AgentFailure(AgentFailureCode.invalidInput);
        }
        return AgentBlockPatch(
          target,
          startUtc:
              slot?.startsAtUtc ??
              (startPresent
                  ? _requiredTimedValue(
                      value['start'],
                      field: AgentParameterField.start,
                    )
                  : null),
          endUtc:
              slot?.endsAtUtc ??
              (endPresent
                  ? _requiredTimedValue(
                      value['end'],
                      field: AgentParameterField.end,
                    )
                  : null),
          location: _optionalText(value, 'location', 200),
          note: _optionalText(value, 'note', 4000),
        );

      case 'block_state':
        final (target, targetRevision) = await _resolveEvent(
          _requiredString(value, 'event_ref', maxLength: 64),
          context,
          revision,
        );
        if (target.identity.kind != CalendarKind.planBlock) {
          throw const AgentFailure(AgentFailureCode.invalidInput);
        }
        _requireSameRevision(targetRevision, revision);
        return AgentCalendarChange(
          SetPlanBlockStatus(
            target,
            PlanBlockStatus.values.byName(
              _requiredEnum(value, 'status', const {
                'planned',
                'done',
                'skipped',
              }),
            ),
          ),
        );

      case 'delete_block':
        final (target, targetRevision) = await _resolveEvent(
          _requiredString(value, 'event_ref', maxLength: 64),
          context,
          revision,
        );
        if (target.identity.kind != CalendarKind.planBlock) {
          throw const AgentFailure(AgentFailureCode.invalidInput);
        }
        _requireSameRevision(targetRevision, revision);
        return AgentCalendarChange(DeletePlanBlock(target, confirmed: true));

      case 'annotate_school':
        if (!_hasAny(value, const {
          'hidden',
          'note',
          'attendance',
          'listening',
        })) {
          throw const AgentFailure(AgentFailureCode.invalidInput);
        }
        final (target, targetRevision) = await _resolveEvent(
          _requiredString(value, 'event_ref', maxLength: 64),
          context,
          revision,
        );
        final kind = target.identity.kind;
        if (!const {
          CalendarKind.course,
          CalendarKind.exam,
          CalendarKind.young,
        }.contains(kind)) {
          throw const AgentFailure(AgentFailureCode.invalidInput);
        }
        _requireSameRevision(targetRevision, revision);
        final attendanceName = _optionalEnum(value, 'attendance', const {
          'attend',
          'skip',
          'undecided',
        });
        final listeningName = _optionalEnum(value, 'listening', const {
          'listening',
          'selfStudy',
          'undecided',
        });
        if (attendanceName != null && kind == CalendarKind.exam ||
            listeningName != null && kind != CalendarKind.course) {
          throw const AgentFailure(AgentFailureCode.invalidInput);
        }
        return AgentCalendarChange(
          UpdateSchoolAnnotation(
            target,
            hidden: _optionalBool(value, 'hidden'),
            note: _optionalText(value, 'note', 4000),
            attendance: attendanceName == null
                ? null
                : AttendanceDecision.values.byName(attendanceName),
            listening: listeningName == null
                ? null
                : ListeningMode.values.byName(listeningName),
          ),
        );

      case 'set_relation':
      case 'delete_relation':
        final deleting = type == 'delete_relation';
        final (left, leftRevision) = await _resolveEvent(
          _requiredString(value, 'left_ref', maxLength: 64),
          context,
          revision,
        );
        final (right, rightRevision) = await _resolveEvent(
          _requiredString(value, 'right_ref', maxLength: 64),
          context,
          revision,
        );
        _requireSameRevision(leftRevision, revision);
        _requireSameRevision(rightRevision, revision);
        if (left.identity == right.identity) {
          throw const AgentFailure(AgentFailureCode.invalidInput);
        }
        final relation = await _findPairRelation(
          left,
          right,
          context,
          revision,
        );
        if (deleting) {
          if (relation == null) {
            throw const AgentFailure(AgentFailureCode.invalidInput);
          }
          return AgentCalendarChange(
            DeleteCalendarRelation(relation.reference),
          );
        }
        final relationKind = _requiredEnum(value, 'kind', const {
          'conflict',
          'notConflict',
        });
        return AgentCalendarChange(
          SaveCalendarRelation(
            left: left,
            right: right,
            kind: CalendarRelationKind.values.byName(relationKind),
            note: _optionalText(value, 'note', 4000) ?? '',
            existing: relation?.reference,
          ),
        );

      default:
        throw const AgentFailure(AgentFailureCode.invalidInput);
    }
  }

  Future<AgentToolResult> _proposeUndo(Map<String, Object?> args) async {
    _requireKeys(args, const {}, const {});
    _ensureNoPending();
    if (_changeBudgetUsed >= _actionBudget) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }
    final ticket = _requireTicket();
    final (context, revision) = await _owner.plans.readPlanContext();
    final undo = await _owner.tasks.queryUndo(context);
    if (undo.failure != null) {
      if (undo.failure == CalendarFailureCode.undoUnavailable) {
        return _result('empty', data: const {'available': false});
      }
      throw CalendarFailure(undo.failure!);
    }
    final reference = undo.reference;
    if (reference == null || !undo.canUndo) {
      return _result('empty', data: const {'available': false});
    }
    if (reference.context != context) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    final current = await _owner.plans.readPlanContext();
    if (current.$1 != context || current.$2 != revision) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    final plan = await _owner.plans.prepareLocalPlan(
      ticket,
      context,
      revision,
      [AgentCalendarChange(UndoCalendarWrite(reference))],
    );
    if (_revoked) {
      _owner.plans.revokeLocalPlans(ticket);
      throw const AgentFailure(AgentFailureCode.cancelled);
    }
    if (plan.ticket != ticket ||
        plan.context != context ||
        plan.revision != revision ||
        plan.changes.length != 1 ||
        plan.view.status != AgentActionStatus.proposed) {
      _owner.plans.revokeLocalPlans(ticket);
      throw const AgentFailure(AgentFailureCode.storageFailed);
    }
    _changeBudgetUsed++;
    _pending = _PendingLocalPlan(plan, '撤销最近一次本地修改', 1);
    _notify();
    return _waitingResult(_pending!);
  }

  Future<AgentToolResult> _findFreeSlots(Map<String, Object?> args) async {
    _requireKeys(
      args,
      const {
        'first_day',
        'end_day_exclusive',
        'weekdays',
        'start_minute',
        'end_minute',
        'block_minutes',
        'break_minutes',
        'avoid',
        'include_hidden',
        'include_skipped',
        'max_candidates',
        'deadline',
      },
      const {'first_day', 'end_day_exclusive'},
    );
    _usedFreeSlotSearch = true;
    final first = _requiredDate(args, 'first_day');
    final end = _requiredDate(args, 'end_day_exclusive');
    final dayCount = end.difference(first).inDays;
    if (dayCount < 1 || dayCount > _maxFreeSlotDays) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    final prefs = await _owner.preferences.readPlanningPreferences();
    final weekdays =
        _optionalIntList(args, 'weekdays', 1, 7) ?? prefs.weekdays.toList();
    final startMinute =
        _optionalInt(args, 'start_minute', 0, 1439) ?? prefs.startMinute;
    final endMinute =
        _optionalInt(args, 'end_minute', 1, 1440) ?? prefs.endMinute;
    final blockMinutes =
        _optionalInt(args, 'block_minutes', 1, 480) ?? prefs.blockMinutes;
    final breakMinutes =
        _optionalInt(args, 'break_minutes', 0, 240) ?? prefs.breakMinutes;
    final avoid = _optionalAvoid(args, 'avoid') ?? prefs.avoid;
    final includeHidden = _optionalBool(args, 'include_hidden') ?? false;
    final includeSkipped = _optionalBool(args, 'include_skipped') ?? false;
    final maxCandidates = _optionalInt(args, 'max_candidates', 1, 20) ?? 20;
    final deadline = _optionalTimed(args, 'deadline');
    _validatePlanningValues(
      weekdays: weekdays,
      startMinute: startMinute,
      endMinute: endMinute,
      blockMinutes: blockMinutes,
      breakMinutes: breakMinutes,
      avoid: avoid,
    );
    final availability = <AgentFreeWeekdayAvailability>[
      for (final weekday in weekdays)
        AgentFreeWeekdayAvailability(
          weekday: weekday,
          intervals: _subtractAvoid(startMinute, endMinute, avoid),
        ),
    ];
    _requireTicket();
    final (context, revision) = await _owner.plans.readPlanContext();
    final firstQuery = CalendarQuery(
      firstDay: first,
      endDayExclusive: end,
      filter: CalendarFilter.all,
      includeHidden: includeHidden,
      includeSkipped: includeSkipped,
      limit: 500,
    );
    final window = await _owner.calendar.query(firstQuery);
    if (window.context != context ||
        window.revision != revision ||
        window.query.firstDay != first ||
        window.query.endDayExclusive != end ||
        window.query.filter != CalendarFilter.all ||
        window.query.includeHidden != includeHidden ||
        window.query.includeSkipped != includeSkipped) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    final result = findAgentFreeSlots(
      window,
      AgentFreeSlotConditions(
        firstDay: first,
        endDayExclusive: end,
        availability: availability,
        blockMinutes: blockMinutes,
        maxCandidates: maxCandidates,
        breakMinutes: breakMinutes,
        includeHidden: includeHidden,
        includeSkipped: includeSkipped,
        deadlineUtc: deadline,
      ),
    );
    await validateDelivery();
    final current = await _owner.plans.readPlanContext();
    final currentPrefs = await _owner.preferences.readPlanningPreferences();
    if (current.$1 != context ||
        current.$2 != revision ||
        currentPrefs.revision != prefs.revision) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    _pruneSlots();
    if (_slots.length + result.candidates.length > _maxSlotReferences) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }
    final candidates = <Map<String, Object?>>[];
    for (final candidate in result.candidates) {
      final token = _newToken('s_');
      _slots[token] = _CachedSlot(
        startsAtUtc: candidate.startsAtUtc,
        endsAtUtc: candidate.endsAtUtc,
        context: context,
        revision: revision,
        preferencesRevision: prefs.revision,
        expiresAtUtc: _owner.clock.nowUtc.add(_slotLifetime),
      );
      candidates.add({
        'slot_ref': token,
        'start': _formatBeijing(candidate.startsAtUtc),
        'end': _formatBeijing(candidate.endsAtUtc),
      });
    }
    final serviceStatus = result.status;
    final status = switch (serviceStatus) {
      AgentFreeSlotsStatus.complete => candidates.isEmpty ? 'empty' : 'success',
      AgentFreeSlotsStatus.limited => 'partial',
      AgentFreeSlotsStatus.rejected => 'invalidRequest',
    };
    final failure = switch (serviceStatus) {
      AgentFreeSlotsStatus.complete => null,
      AgentFreeSlotsStatus.limited => 'resourceLimit',
      AgentFreeSlotsStatus.rejected => 'invalidRequest',
    };
    return _result(
      status,
      failure: failure,
      data: {
        'first_day': _formatDay(first),
        'end_day_exclusive': _formatDay(end),
        'filter': 'all',
        'include_hidden': includeHidden,
        'include_skipped': includeSkipped,
        'block_minutes': blockMinutes,
        'break_minutes': breakMinutes,
        'weekdays': weekdays,
        'start_minute': startMinute,
        'end_minute': endMinute,
        'avoid': [
          for (final range in avoid)
            {'start_minute': range.$1, 'end_minute': range.$2},
        ],
        'candidates': candidates,
        'coverage': {
          'window_complete': result.windowComplete,
          'window_truncated': result.windowTruncated,
          'conflicts_truncated': result.conflictsTruncated,
          'candidates_truncated': result.candidatesTruncated,
          'service_status': serviceStatus.name,
        },
        'notices': result.notices,
      },
    );
  }

  Future<AgentToolResult> _proposePlanningPreferences(
    Map<String, Object?> args,
  ) async {
    _requireKeys(args, const {
      'weekdays',
      'start_minute',
      'end_minute',
      'block_minutes',
      'break_minutes',
      'avoid',
    }, const {});
    _ensureNoPending();
    if (_changeBudgetUsed >= _actionBudget) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }
    final ticket = _requireTicket();
    final current = await _owner.preferences.readPlanningPreferences();
    final proposed = AgentPlanningPreferences(
      revision: current.revision,
      weekdays:
          _optionalIntList(args, 'weekdays', 1, 7) ?? current.weekdays.toList(),
      startMinute:
          _optionalInt(args, 'start_minute', 0, 1439) ?? current.startMinute,
      endMinute: _optionalInt(args, 'end_minute', 1, 1440) ?? current.endMinute,
      blockMinutes:
          _optionalInt(args, 'block_minutes', 1, 480) ?? current.blockMinutes,
      breakMinutes:
          _optionalInt(args, 'break_minutes', 0, 240) ?? current.breakMinutes,
      avoid: _optionalAvoid(args, 'avoid') ?? current.avoid,
    );
    _validatePlanningValues(
      weekdays: proposed.weekdays,
      startMinute: proposed.startMinute,
      endMinute: proposed.endMinute,
      blockMinutes: proposed.blockMinutes,
      breakMinutes: proposed.breakMinutes,
      avoid: proposed.avoid,
    );
    if (_samePreferences(proposed, current)) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    final record = await _owner.preferenceProposals.preparePreferencesPlan(
      ticket,
      proposed,
    );
    if (_revoked) {
      try {
        await _owner.preferenceProposals.rejectPreferencesPlan(ticket, record);
      } on Object {
        // The run ticket is already invalid; no preference write is permitted.
      }
      throw const AgentFailure(AgentFailureCode.cancelled);
    }
    if (record.kind != AgentActionKind.planningPreferences ||
        record.status != AgentActionStatus.proposed) {
      throw const AgentFailure(AgentFailureCode.storageFailed);
    }
    _changeBudgetUsed++;
    _pending = _PendingPreferences(ticket, record, '待确认的规划偏好设置');
    _notify();
    return _waitingResult(_pending!);
  }

  @override
  Future<AgentToolResult> decidePending(bool approved) async {
    _ensureActive();
    final pending = _pending;
    if (pending == null || _decisionInFlight) {
      return _result('stale', failure: 'staleReference');
    }
    _decisionInFlight = true;
    _notify();
    try {
      if (pending is _PendingLocalPlan) {
        if (approved) {
          final approval = await _owner.plans.approveLocalPlan(pending.plan);
          _ensureStillPending(pending);
          final receipt = await _owner.plans.commitLocalPlan(approval);
          if (identical(_pending, pending)) _pending = null;
          await _afterAcceptedMutation();
          return _result(
            'committed',
            data: {'title': pending.title, 'count': receipt.committedCount},
          );
        }
        await _owner.plans.rejectLocalPlan(pending.plan);
        _ensureStillPending(pending);
        _pending = null;
        _notify();
        return _result('rejected', data: {'title': pending.title, 'count': 0});
      }

      if (pending is _PendingSourceRefresh) {
        if (!approved) {
          await _settleSourceRecord(
            pending.ticket,
            pending.record,
            AgentActionStatus.rejected,
          );
          _ensureStillPending(pending);
          _pending = null;
          _notify();
          return _result(
            'rejected',
            data: {'title': pending.title, 'count': 0},
          );
        }
        await validateDelivery();
        final approvalPort = _owner.actionRecords;
        if (approvalPort is AgentSourceApprovalPort) {
          await (approvalPort as AgentSourceApprovalPort).approveSourceAction(
            pending.ticket,
            pending.record,
          );
          _ensureStillPending(pending);
        }
        final sourceResult = await _requireSources().refresh(
          pending.ticket,
          pending.record,
          pending.request,
        );
        _ensureStillPending(pending);
        if (sourceResult.count < 0 || !sourceResult.observedAtUtc.isUtc) {
          throw const AgentFailure(AgentFailureCode.storageFailed);
        }
        final failed = _sourceFailureResult(sourceResult.failure);
        if (failed != null) {
          if (sourceResult.committed) {
            _pending = null;
            await _afterAcceptedMutation();
            return _result(
              failed.status,
              failure: failed.failure,
              data: {
                'title': pending.title,
                'count': sourceResult.count,
                'committed': true,
                'complete': sourceResult.complete,
                'observed_at': _beijingDateTime(sourceResult.observedAtUtc),
              },
            );
          }
          if (failed.status == 'busy' ||
              failed.status == 'consentRequired' ||
              _requireSources().waitingForSchool) {
            return failed;
          }
          await _settleSourceRecord(
            pending.ticket,
            pending.record,
            failed.status == 'cancelled'
                ? AgentActionStatus.interrupted
                : AgentActionStatus.failed,
          );
          _pending = null;
          _notify();
          return failed;
        }
        _pending = null;
        await _afterAcceptedMutation();
        final status = sourceResult.complete
            ? (sourceResult.committed
                  ? 'committed'
                  : (sourceResult.count == 0 ? 'empty' : 'success'))
            : 'partial';
        return _result(
          status,
          data: {
            'title': pending.title,
            'count': sourceResult.count,
            'committed': sourceResult.committed,
            'complete': sourceResult.complete,
            'observed_at': _beijingDateTime(sourceResult.observedAtUtc),
          },
        );
      }

      final preferencesPending = pending as _PendingPreferences;
      if (approved) {
        await _owner.preferenceProposals.commitPreferencesPlan(
          preferencesPending.ticket,
          preferencesPending.record,
        );
        if (identical(_pending, pending)) _pending = null;
        await _afterAcceptedMutation();
        return _result(
          'committed',
          data: {'title': preferencesPending.title, 'count': 1},
        );
      }
      await _owner.preferenceProposals.rejectPreferencesPlan(
        preferencesPending.ticket,
        preferencesPending.record,
      );
      _ensureStillPending(pending);
      _pending = null;
      _notify();
      return _result(
        'rejected',
        data: {'title': preferencesPending.title, 'count': 0},
      );
    } on AgentFailure catch (failure) {
      if (!identical(_pending, pending)) return _agentFailure(failure);
      if (pending is _PendingSourceRefresh &&
          (failure.code == AgentFailureCode.busy ||
              failure.code == AgentFailureCode.consentRequired ||
              _owner.sources?.waitingForSchool == true)) {
        return _agentFailure(failure);
      }
      await _clearFailedDecision(pending);
      return _agentFailure(failure);
    } on CalendarFailure catch (failure) {
      if (!identical(_pending, pending)) return _calendarFailure(failure);
      await _clearFailedDecision(pending);
      return _calendarFailure(failure);
    } on Object {
      if (!identical(_pending, pending)) {
        return _result('cancelled', failure: 'cancelled');
      }
      await _clearFailedDecision(pending);
      return _result('failure', failure: 'storageFailed');
    } finally {
      _decisionInFlight = false;
      _notify();
    }
  }

  Future<void> _afterAcceptedMutation() async {
    _slots.clear();
    _readSession.revoke();
    final source = _owner.sources;
    if (source is AgentSourceDeliveryPort) {
      (source as AgentSourceDeliveryPort).clearReadReferences();
    }
    _contextInvalidated = true;
    try {
      _readSession = _owner.readTools.openSession();
      _readerUnavailable = false;
    } on Object {
      _readerUnavailable = true;
    }
    _notify();
  }

  Future<void> _discardUndeliverablePending() async {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    _slots.clear();
    final ticket = _ticket;
    if (pending is _PendingLocalPlan) {
      if (ticket != null) _owner.plans.revokeLocalPlans(ticket);
    } else if (pending is _PendingPreferences) {
      try {
        await _owner.preferenceProposals.rejectPreferencesPlan(
          pending.ticket,
          pending.record,
        );
      } on Object {
        // The proposal is no longer reachable from this run.
      }
    } else if (pending is _PendingSourceRefresh) {
      try {
        await _settleSourceRecord(
          pending.ticket,
          pending.record,
          AgentActionStatus.interrupted,
        );
      } on Object {
        // The run ticket is already invalid; it cannot start source work.
      }
    }
    _notify();
  }

  Future<CalendarRelation?> _findPairRelation(
    CalendarReference left,
    CalendarReference right,
    CalendarContext context,
    int revision,
  ) async {
    final current = await _owner.plans.readPlanContext();
    if (current.$1 != context || current.$2 != revision) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    final detail = await _owner.calendar.detail(left);
    final matches = detail.relations.where((relation) {
      return (relation.left == left.identity &&
              relation.right == right.identity) ||
          (relation.left == right.identity && relation.right == left.identity);
    }).toList();
    if (matches.length > 1) {
      throw const CalendarFailure(CalendarFailureCode.storageFailed);
    }
    final after = await _owner.plans.readPlanContext();
    if (after.$1 != context || after.$2 != revision) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    return matches.isEmpty ? null : matches.single;
  }

  Future<(CalendarReference, int)> _resolveEvent(
    String token,
    CalendarContext context,
    int revision,
  ) async {
    final resolved = await resolveEventReference(token);
    if (resolved.$1.context != context || resolved.$2 != revision) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    return resolved;
  }

  Future<(TaskReference, int)> _resolveTask(
    String token,
    CalendarContext context,
    int revision,
  ) async {
    final resolved = await resolveTaskReference(token);
    if (resolved.$1.context != context || resolved.$2 != revision) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    return resolved;
  }

  Future<PlanBlockDraft> _blockDraft(Map<String, Object?> value) async {
    final slot = await _optionalSlot(value);
    final startPresent = value.containsKey('start');
    final endPresent = value.containsKey('end');
    if (slot != null && (startPresent || endPresent) ||
        slot == null && (!startPresent || !endPresent)) {
      throw AgentParameterIssue(
        reason: slot != null
            ? AgentParameterReason.mutuallyExclusive
            : AgentParameterReason.missingTimeRange,
        field: AgentParameterField.start,
      );
    }
    final start =
        slot?.startsAtUtc ??
        _requiredTimedValue(value['start'], field: AgentParameterField.start);
    final end =
        slot?.endsAtUtc ??
        _requiredTimedValue(value['end'], field: AgentParameterField.end);
    final location = _optionalText(value, 'location', 200) ?? '';
    final note = _optionalText(value, 'note', 4000) ?? '';
    if (!end.isAfter(start) ||
        end.difference(start) > const Duration(days: 366)) {
      throw const AgentParameterIssue(
        reason: AgentParameterReason.invalidTimeRange,
        field: AgentParameterField.end,
      );
    }
    return PlanBlockDraft(
      startsAtUtc: start,
      endsAtUtc: end,
      location: location,
      note: note,
    );
  }

  Future<_CachedSlot?> _optionalSlot(
    Map<String, Object?> value, [
    CalendarContext? expectedContext,
    int? expectedRevision,
  ]) async {
    if (!value.containsKey('slot_ref')) return null;
    final token = _requiredString(value, 'slot_ref', maxLength: 64);
    _pruneSlots();
    final slot = _slots[token];
    if (slot == null) throw const AgentFailure(AgentFailureCode.staleContext);
    final prefs = await _owner.preferences.readPlanningPreferences();
    if (prefs.revision != slot.preferencesRevision ||
        expectedContext != null && slot.context != expectedContext ||
        expectedRevision != null && slot.revision != expectedRevision) {
      _slots.remove(token);
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    final current = await _owner.plans.readPlanContext();
    if (current.$1 != slot.context || current.$2 != slot.revision) {
      _slots.remove(token);
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    return slot;
  }

  TaskDraft _taskDraft(
    Map<String, Object?> value, {
    required bool titleRequired,
  }) {
    final title = _optionalText(value, 'title', 200);
    if (titleRequired && title == null) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    final deadline = _optionalTimed(value, 'deadline');
    final estimated = _optionalInt(value, 'estimated_minutes', 1, 527040);
    final priority = _optionalEnum(value, 'priority', const {
      'low',
      'normal',
      'high',
    });
    return TaskDraft(
      title: title ?? '',
      description: _optionalText(value, 'description', 4000) ?? '',
      note: _optionalText(value, 'note', 4000) ?? '',
      deadlineAtUtc: deadline,
      estimatedMinutes: estimated,
      priority: priority == null
          ? TaskPriority.normal
          : TaskPriority.values.byName(priority),
    );
  }

  AgentTaskPatch _taskPatch(Map<String, Object?> value, TaskReference target) {
    final clearDeadline = _optionalBool(value, 'clear_deadline') ?? false;
    final clearEstimate = _optionalBool(value, 'clear_estimate') ?? false;
    final deadline = _optionalTimed(value, 'deadline');
    final estimated = _optionalInt(value, 'estimated_minutes', 1, 527040);
    final priorityName = _optionalEnum(value, 'priority', const {
      'low',
      'normal',
      'high',
    });
    final patch = AgentTaskPatch(
      target,
      title: _optionalText(value, 'title', 200),
      description: _optionalText(value, 'description', 4000),
      note: _optionalText(value, 'note', 4000),
      deadlineUtc: deadline,
      clearDeadline: clearDeadline,
      estimatedMinutes: estimated,
      clearEstimate: clearEstimate,
      priority: priorityName == null
          ? null
          : TaskPriority.values.byName(priorityName),
    );
    if (clearDeadline && deadline != null ||
        clearEstimate && estimated != null ||
        patch.title == null &&
            patch.description == null &&
            patch.note == null &&
            patch.deadlineUtc == null &&
            !patch.clearDeadline &&
            patch.estimatedMinutes == null &&
            !patch.clearEstimate &&
            patch.priority == null) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    return patch;
  }

  void _ensureStillPending(_PendingAgentDecision pending) {
    _ensureActive();
    if (!identical(_pending, pending)) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
  }

  Future<void> _clearFailedDecision(_PendingAgentDecision pending) async {
    if (identical(_pending, pending)) _pending = null;
    final ticket = _ticket;
    if (ticket != null) _owner.plans.revokeLocalPlans(ticket);
    if (pending is _PendingSourceRefresh) {
      try {
        await _settleSourceRecord(
          pending.ticket,
          pending.record,
          AgentActionStatus.failed,
        );
      } on Object {
        // C3/source ownership remains authoritative for a late result.
      }
    }
    _notify();
  }

  void _ensureNoPending() {
    _ensureActive();
    if (_pending != null || _decisionInFlight) {
      throw const AgentFailure(AgentFailureCode.busy);
    }
    if (_contextInvalidated) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
  }

  AgentRunTicket _requireTicket() {
    _ensureActive();
    final ticket = _ticket;
    if (ticket == null) throw const AgentFailure(AgentFailureCode.unauthorized);
    return ticket;
  }

  bool _questionRequiresFree() {
    final question = (_humanQuestion ?? '').toLowerCase();
    final chinesePhrases = ['不冲突', '空闲', '空档', '避免冲突', '避开', '不撞', '别撞', '不重叠'];
    for (final phrase in chinesePhrases) {
      var start = question.indexOf(phrase);
      while (start >= 0) {
        final prefix = question.substring(max(0, start - 6), start);
        if (!RegExp(r'(不需要|不要求|无需|不要|不必|不用)$').hasMatch(prefix)) {
          return true;
        }
        start = question.indexOf(phrase, start + phrase.length);
      }
    }
    if (RegExp(
      r'(?:别|不要|不想|尽量不)(?:和|与|同)?[^，。！？；]{0,12}(?:课|日程|安排|时间|活动)[^，。！？；]{0,6}(?:冲突|重叠|撞)',
    ).hasMatch(question)) {
      return true;
    }
    if (RegExp(r'\bwithout\s+(?:conflict|overlap)\b').hasMatch(question)) {
      return true;
    }
    final english = RegExp(
      r'\b(free(?:\s+time|\s+slot)?|avoid|no\s+overlap)\b',
    );
    for (final match in english.allMatches(question)) {
      final prefix = question.substring(max(0, match.start - 12), match.start);
      if (!RegExp(r"(?:don't|do not|not|without)\s+$").hasMatch(prefix)) {
        return true;
      }
    }
    return false;
  }

  void _pruneSlots() {
    final now = _owner.clock.nowUtc;
    _slots.removeWhere((_, value) => !now.isBefore(value.expiresAtUtc));
  }

  String _newToken(String prefix) {
    final random = Random.secure();
    return prefix +
        List.generate(
          16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  AgentToolResult _waitingResult(_PendingAgentDecision pending) {
    return _result(
      'waitingForApproval',
      data: {'title': pending.title, 'count': pending.count},
    );
  }

  AgentToolResult _result(
    String status, {
    String? failure,
    Map<String, Object?> data = const {},
  }) {
    if (!agentToolStatuses.contains(status) ||
        failure != null && !_toolFailureCodes.contains(failure)) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    final encoded = jsonEncode(data);
    AgentText.requireSafe(encoded, maxCharacters: 10000);
    if (utf8.encode(encoded).length > 10000) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }
    return AgentToolResult(status: status, failure: failure, data: data);
  }

  AgentToolResult _agentFailure(AgentFailure failure) => switch (failure.code) {
    AgentFailureCode.invalidInput => _result(
      'invalidRequest',
      failure: 'invalidRequest',
    ),
    AgentFailureCode.secretDetected => _result(
      'secretDetected',
      failure: 'secretDetected',
    ),
    AgentFailureCode.consentRequired => _result(
      'consentRequired',
      failure: 'consentRequired',
    ),
    AgentFailureCode.busy => _result('busy', failure: 'busy'),
    AgentFailureCode.staleContext => _result(
      'stale',
      failure: 'staleReference',
    ),
    AgentFailureCode.cancelled => _result('cancelled', failure: 'cancelled'),
    AgentFailureCode.closed => _result('cancelled', failure: 'closed'),
    AgentFailureCode.resourceLimit => _result(
      'resourceLimit',
      failure: 'resourceLimit',
    ),
    AgentFailureCode.ownershipLost => _result(
      'failure',
      failure: 'ownershipLost',
    ),
    AgentFailureCode.storageFailed => _result(
      'failure',
      failure: 'storageFailed',
    ),
    AgentFailureCode.unauthorized || AgentFailureCode.forbidden => _result(
      'accessRestricted',
      failure: 'accessRestricted',
    ),
    AgentFailureCode.maintenance => _result('busy', failure: 'busy'),
    _ => _result('unavailable', failure: 'unavailable'),
  };

  AgentToolResult _calendarFailure(CalendarFailure failure) =>
      switch (failure.code) {
        CalendarFailureCode.invalidInput => _result(
          'invalidRequest',
          failure: 'invalidRequest',
        ),
        CalendarFailureCode.staleReference => _result(
          'stale',
          failure: 'staleReference',
        ),
        CalendarFailureCode.busy ||
        CalendarFailureCode.maintenance => _result('busy', failure: 'busy'),
        CalendarFailureCode.limitExceeded => _result(
          'resourceLimit',
          failure: 'resourceLimit',
        ),
        CalendarFailureCode.ownershipLost => _result(
          'failure',
          failure: 'ownershipLost',
        ),
        CalendarFailureCode.closed => _result('cancelled', failure: 'closed'),
        CalendarFailureCode.storageFailed => _result(
          'failure',
          failure: 'storageFailed',
        ),
        CalendarFailureCode.undoUnavailable => _result(
          'empty',
          data: const {'available': false},
        ),
        CalendarFailureCode.undoConflict ||
        CalendarFailureCode.idempotencyConflict => _result(
          'stale',
          failure: 'staleReference',
        ),
      };

  void _ensureActive() {
    if (_revoked || _owner._closing || _owner._closed) {
      throw const AgentFailure(AgentFailureCode.cancelled);
    }
  }

  @override
  void revoke() {
    if (_revoked) return;
    _revoked = true;
    final ticket = _ticket;
    if (ticket != null) _owner.plans.revokeLocalPlans(ticket);
    final pending = _pending;
    if (pending is _PendingSourceRefresh) {
      unawaited(
        _settleSourceRecord(
          pending.ticket,
          pending.record,
          AgentActionStatus.interrupted,
        ).catchError((Object _) {}),
      );
    }
    _readSession.revoke();
    _slots.clear();
    _semesterReferences.clear();
    _pending = null;
    _owner._sessions.remove(this);
    unawaited(_sourceChanges?.cancel() ?? Future<void>.value());
    final sources = _owner.sources;
    if (sources != null) {
      unawaited(sources.cancelAndDrain().catchError((Object _) {}));
    }
    if (!_changes.isClosed) unawaited(_changes.close());
  }

  @override
  Future<void> continueSchool() async {
    final sources = _owner.sources;
    if (sources == null) {
      throw const AgentFailure(AgentFailureCode.toolUnavailable);
    }
    _ensureActive();
    await sources.continueSchool();
  }
}

const _toolFailureCodes = {
  'invalidRequest',
  'busy',
  'consentRequired',
  'cancelled',
  'staleReference',
  'unavailable',
  'accessRestricted',
  'resourceLimit',
  'storageFailed',
  'closed',
  'secretDetected',
  'ownershipLost',
};

ModelToolDefinition _actionTool(
  String name,
  String description,
  Map<String, Object?> properties, {
  List<String> required = const [],
}) => ModelToolDefinition(
  name: name,
  description: description,
  parameters: {
    'type': 'object',
    'properties': properties,
    'required': required,
    'additionalProperties': false,
  },
);

Map<String, Object?> _actionSchema() => {
  'type': 'object',
  'properties': {
    'type': _stringSchema(
      enumValues: const [
        'create_personal',
        'update_personal',
        'personal_state',
        'delete_personal',
        'create_task',
        'update_task',
        'task_state',
        'delete_task',
        'create_block',
        'update_block',
        'block_state',
        'delete_block',
        'annotate_school',
        'set_relation',
        'delete_relation',
      ],
    ),
    'event_ref': _stringSchema(maxLength: 64),
    'task_ref': _stringSchema(maxLength: 64),
    'left_ref': _stringSchema(maxLength: 64),
    'right_ref': _stringSchema(maxLength: 64),
    'slot_ref': _stringSchema(maxLength: 64),
    'task_key': _stringSchema(maxLength: 32),
    'local_key': _stringSchema(maxLength: 32),
    'scope': _stringSchema(enumValues: const ['series', 'occurrence']),
    'title': _stringSchema(maxLength: 200),
    'description': _stringSchema(maxLength: 4000),
    'note': _stringSchema(maxLength: 4000),
    'location': _stringSchema(maxLength: 200),
    'start': _stringSchema(
      pattern: r'^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?\+08:00)?$',
      maxLength: 25,
    ),
    'end': _stringSchema(
      pattern: r'^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?\+08:00)?$',
      maxLength: 25,
    ),
    'until_day': _stringSchema(pattern: r'^\d{4}-\d{2}-\d{2}$'),
    'deadline': _stringSchema(
      pattern: r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?\+08:00$',
      maxLength: 25,
    ),
    'all_day': _boolSchema(),
    'weekly': _boolSchema(),
    'clear_until': _boolSchema(),
    'completed': _boolSchema(),
    'skipped': _boolSchema(),
    'hidden': _boolSchema(),
    'clear_deadline': _boolSchema(),
    'clear_estimate': _boolSchema(),
    'estimated_minutes': _intSchema(minimum: 1, maximum: 527040),
    'priority': _stringSchema(enumValues: const ['low', 'normal', 'high']),
    'status': _stringSchema(
      enumValues: const [
        'active',
        'blocked',
        'completed',
        'cancelled',
        'planned',
        'done',
        'skipped',
      ],
    ),
    'attendance': _stringSchema(
      enumValues: const ['attend', 'skip', 'undecided'],
    ),
    'listening': _stringSchema(
      enumValues: const ['listening', 'selfStudy', 'undecided'],
    ),
    'kind': _stringSchema(enumValues: const ['conflict', 'notConflict']),
  },
  'required': const ['type'],
  'additionalProperties': false,
};

Map<String, Object?> _avoidSchema() => {
  'type': 'array',
  'maxItems': 8,
  'items': {
    'type': 'object',
    'properties': {
      'start_minute': _intSchema(minimum: 0, maximum: 1439),
      'end_minute': _intSchema(minimum: 1, maximum: 1440),
    },
    'required': const ['start_minute', 'end_minute'],
    'additionalProperties': false,
  },
};

Map<String, Object?> _intArraySchema({
  required int minimum,
  required int maximum,
  required int maxItems,
}) => {
  'type': 'array',
  'minItems': 1,
  'maxItems': maxItems,
  'items': {'type': 'integer', 'minimum': minimum, 'maximum': maximum},
};

Map<String, Object?> _stringSchema({
  List<String>? enumValues,
  String? pattern,
  int? maxLength,
}) => {
  'type': 'string',
  'enum': ?enumValues,
  'pattern': ?pattern,
  'maxLength': ?maxLength,
};

Map<String, Object?> _intSchema({required int minimum, required int maximum}) =>
    {'type': 'integer', 'minimum': minimum, 'maximum': maximum};

Map<String, Object?> _boolSchema() => const {'type': 'boolean'};

void _requireKeys(
  Map<String, Object?> value,
  Set<String> allowed,
  Set<String> required,
) {
  final missing = required.where((key) => !value.containsKey(key)).firstOrNull;
  if (missing != null) {
    throw AgentParameterIssue(
      reason: AgentParameterReason.missingField,
      field: parameterField(missing),
    );
  }
  final extra = value.keys.where((key) => !allowed.contains(key)).firstOrNull;
  if (extra != null) {
    throw AgentParameterIssue(
      reason: AgentParameterReason.unknownField,
      field: parameterField(extra),
    );
  }
}

bool _hasAny(Map<String, Object?> value, Set<String> names) =>
    names.any(value.containsKey);

String _requiredString(
  Map<String, Object?> value,
  String key, {
  required int maxLength,
}) {
  final text = value[key];
  if (text is! String || text.isEmpty || text.length > maxLength) {
    throw AgentParameterIssue(
      reason: AgentParameterReason.invalidValue,
      field: parameterField(key),
    );
  }
  AgentText.requireSafe(text, maxCharacters: maxLength);
  return text;
}

String _requiredText(Map<String, Object?> value, String key, int maxLength) {
  final text = _requiredString(value, key, maxLength: maxLength);
  if (text.trim().isEmpty) {
    throw AgentParameterIssue(
      reason: AgentParameterReason.invalidValue,
      field: parameterField(key),
    );
  }
  return text;
}

String? _optionalText(Map<String, Object?> value, String key, int maxLength) {
  if (!value.containsKey(key)) return null;
  final text = value[key];
  if (text is! String || text.length > maxLength) {
    throw AgentParameterIssue(
      reason: AgentParameterReason.invalidValue,
      field: parameterField(key),
    );
  }
  AgentText.requireSafe(text, maxCharacters: maxLength);
  return text;
}

bool? _optionalBool(Map<String, Object?> value, String key) {
  if (!value.containsKey(key)) return null;
  final field = value[key];
  if (field is! bool) {
    throw AgentParameterIssue(
      reason: AgentParameterReason.invalidValue,
      field: parameterField(key),
    );
  }
  return field;
}

int? _optionalInt(
  Map<String, Object?> value,
  String key,
  int minimum,
  int maximum,
) {
  if (!value.containsKey(key)) return null;
  final field = value[key];
  if (field is! int || field < minimum || field > maximum) {
    throw AgentParameterIssue(
      reason: AgentParameterReason.invalidValue,
      field: parameterField(key),
    );
  }
  return field;
}

List<int>? _optionalIntList(
  Map<String, Object?> value,
  String key,
  int minimum,
  int maximum,
) {
  if (!value.containsKey(key)) return null;
  final field = value[key];
  if (field is! List<Object?> ||
      field.isEmpty ||
      field.length > 7 ||
      field.any((item) => item is! int || item < minimum || item > maximum)) {
    throw const AgentFailure(AgentFailureCode.invalidInput);
  }
  final result = field.cast<int>();
  if (result.toSet().length != result.length) {
    throw const AgentFailure(AgentFailureCode.invalidInput);
  }
  return result.toList()..sort();
}

String _requiredEnum(
  Map<String, Object?> value,
  String key,
  Set<String> allowed,
) {
  final result = value[key];
  if (result is! String || !allowed.contains(result)) {
    throw AgentParameterIssue(
      reason: AgentParameterReason.invalidValue,
      field: parameterField(key),
    );
  }
  return result;
}

String? _optionalEnum(
  Map<String, Object?> value,
  String key,
  Set<String> allowed,
) {
  if (!value.containsKey(key)) return null;
  return _requiredEnum(value, key, allowed);
}

DateTime _requiredDate(Map<String, Object?> value, String key) {
  return _parseDate(value[key], field: parameterField(key));
}

DateTime? _optionalDate(Map<String, Object?> value, String key) {
  if (!value.containsKey(key)) return null;
  return _parseDate(value[key], field: parameterField(key));
}

DateTime _parseDate(
  Object? value, {
  AgentParameterField field = AgentParameterField.arguments,
}) {
  final issue = AgentParameterIssue(
    reason: AgentParameterReason.invalidDate,
    field: field,
  );
  if (value is! String) throw issue;
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (match == null) throw issue;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  if (year < 1 || year > 9998) {
    throw issue;
  }
  final result = DateTime.utc(year, month, day);
  if (result.year != year ||
      result.month != month ||
      result.day != day ||
      !isCalendarDate(result)) {
    throw issue;
  }
  return result;
}

DateTime _requiredCalendarValue(
  Object? value,
  bool allDay, {
  required AgentParameterField field,
}) =>
    allDay ? _parseDate(value, field: field) : _parseTimed(value, field: field);

DateTime _requiredTimedValue(
  Object? value, {
  required AgentParameterField field,
}) => _parseTimed(value, field: field);

DateTime? _optionalTimed(Map<String, Object?> value, String key) {
  if (!value.containsKey(key)) return null;
  return _parseTimed(value[key], field: parameterField(key));
}

DateTime _parseTimed(
  Object? value, {
  AgentParameterField field = AgentParameterField.arguments,
}) {
  final issue = AgentParameterIssue(
    reason: AgentParameterReason.invalidTimestamp,
    field: field,
  );
  if (value is! String) throw issue;
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?\+08:00$',
  ).firstMatch(value);
  if (match == null) throw issue;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final second = int.parse(match.group(6) ?? '0');
  if (year < 1 || year > 9998 || hour > 23 || minute > 59 || second > 59) {
    throw issue;
  }
  final beijing = DateTime.utc(year, month, day, hour, minute, second);
  if (beijing.year != year ||
      beijing.month != month ||
      beijing.day != day ||
      beijing.hour != hour ||
      beijing.minute != minute ||
      beijing.second != second) {
    throw issue;
  }
  return beijing.subtract(const Duration(hours: 8));
}

List<(int, int)>? _optionalAvoid(Map<String, Object?> value, String key) {
  if (!value.containsKey(key)) return null;
  final raw = value[key];
  if (raw is! List<Object?> || raw.length > 8) {
    throw const AgentFailure(AgentFailureCode.invalidInput);
  }
  final result = <(int, int)>[];
  for (final item in raw) {
    if (item is! Map<String, Object?>) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    _requireKeys(
      item,
      const {'start_minute', 'end_minute'},
      const {'start_minute', 'end_minute'},
    );
    final start = _requiredInt(item, 'start_minute', 0, 1439);
    final end = _requiredInt(item, 'end_minute', 1, 1440);
    if (start >= end) throw const AgentFailure(AgentFailureCode.invalidInput);
    result.add((start, end));
  }
  return result;
}

int _requiredInt(
  Map<String, Object?> value,
  String key,
  int minimum,
  int maximum,
) {
  final result = _optionalInt(value, key, minimum, maximum);
  if (result == null) throw const AgentFailure(AgentFailureCode.invalidInput);
  return result;
}

void _validatePlanningValues({
  required List<int> weekdays,
  required int startMinute,
  required int endMinute,
  required int blockMinutes,
  required int breakMinutes,
  required List<(int, int)> avoid,
}) {
  if (weekdays.isEmpty ||
      weekdays.length > 7 ||
      weekdays.toSet().length != weekdays.length ||
      weekdays.any((day) => day < 1 || day > 7) ||
      startMinute < 0 ||
      startMinute >= endMinute ||
      endMinute > 1440 ||
      blockMinutes < 1 ||
      blockMinutes > 480 ||
      breakMinutes < 0 ||
      breakMinutes > 240 ||
      avoid.length > 8 ||
      avoid.any(
        (range) => range.$1 < 0 || range.$2 > 1440 || range.$1 >= range.$2,
      )) {
    throw const AgentFailure(AgentFailureCode.invalidInput);
  }
}

List<AgentFreeMinuteRange> _subtractAvoid(
  int start,
  int end,
  List<(int, int)> avoid,
) {
  final sorted = avoid.toList()..sort((a, b) => a.$1.compareTo(b.$1));
  final result = <AgentFreeMinuteRange>[];
  var cursor = start;
  for (final range in sorted) {
    final blockedStart = max(start, range.$1);
    final blockedEnd = min(end, range.$2);
    if (blockedStart >= blockedEnd) continue;
    if (blockedStart > cursor) {
      result.add(AgentFreeMinuteRange(cursor, blockedStart));
    }
    if (blockedEnd > cursor) cursor = blockedEnd;
    if (cursor >= end) break;
  }
  if (cursor < end) result.add(AgentFreeMinuteRange(cursor, end));
  return result;
}

bool _samePreferences(
  AgentPlanningPreferences left,
  AgentPlanningPreferences right,
) =>
    left.weekdays.length == right.weekdays.length &&
    left.weekdays.toSet().containsAll(right.weekdays) &&
    left.startMinute == right.startMinute &&
    left.endMinute == right.endMinute &&
    left.blockMinutes == right.blockMinutes &&
    left.breakMinutes == right.breakMinutes &&
    left.avoid.length == right.avoid.length &&
    left.avoid.toSet().containsAll(right.avoid);

String _formatDay(DateTime value) {
  final result = StringBuffer()
    ..write(value.year.toString().padLeft(4, '0'))
    ..write('-')
    ..write(value.month.toString().padLeft(2, '0'))
    ..write('-')
    ..write(value.day.toString().padLeft(2, '0'));
  return result.toString();
}

String _formatBeijing(DateTime value) {
  final local = value.toUtc().add(const Duration(hours: 8));
  final result = StringBuffer()
    ..write(_formatDay(local))
    ..write('T')
    ..write(local.hour.toString().padLeft(2, '0'))
    ..write(':')
    ..write(local.minute.toString().padLeft(2, '0'))
    ..write(':')
    ..write(local.second.toString().padLeft(2, '0'))
    ..write('+08:00');
  return result.toString();
}

void _requireSameRevision(int actual, int expected) {
  if (actual != expected) {
    throw const AgentFailure(AgentFailureCode.staleContext);
  }
}
