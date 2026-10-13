import 'dart:convert';
import 'dart:math';

import '../core/agent_contract.dart';
import '../core/agent_evidence.dart';
import '../core/agent_text.dart';
import '../core/agenda_contract.dart';
import '../core/calendar_contract.dart';
import '../core/contracts.dart';
import '../core/knowledge_contract.dart';
import '../core/public_query_contract.dart';
import 'agent_tool_contract.dart';
import '../core/agent_discussion_contract.dart';
import 'model_gateway_contract.dart';

const _maxListSize = 20;
const _defaultListSize = 5;
const _maxBodyCharacters = 2400;
const _maxResultBytes = 10000;
const _maxReferencesAndCursors = 256;
const _maxEvidencePerSession = 64;
const _maxSnapshotsPerSession = 256;
const _referenceLifetime = Duration(minutes: 10);
const _failureCodes = {
  'invalidRequest',
  'busy',
  'consentRequired',
  'cancelled',
  'staleReference',
  'unavailable',
  'accessRestricted',
  'campusOnly',
  'networkFailed',
  'sourceSchema',
  'unsafeTarget',
  'resourceLimit',
  'storageFailed',
  'cleanupPending',
  'closed',
  'secretDetected',
  'knowledgeNotLoaded',
};

enum _GuardKind { knowledge, online }

final class _LocalSnapshot {
  const _LocalSnapshot(this.context, this.revision);
  final CalendarContext context;
  final int revision;
}

final class _PublicSnapshot {
  const _PublicSnapshot(this.kind, this.result);
  final _GuardKind kind;
  final PublicQueryResult result;
}

final class _EventRef {
  const _EventRef(this.reference, this.context, this.revision, this.expiry);
  final CalendarReference reference;
  final CalendarContext context;
  final int revision;
  final DateTime expiry;
}

final class _TaskRef {
  const _TaskRef(this.reference, this.context, this.revision, this.expiry);
  final TaskReference reference;
  final CalendarContext context;
  final int revision;
  final DateTime expiry;
}

final class _PublicRef {
  const _PublicRef({
    required this.reference,
    required this.kind,
    required this.guardKind,
    required this.origin,
    required this.expiry,
  });
  final PublicReference reference;
  final String kind;
  final _GuardKind guardKind;
  final PublicQueryResult origin;
  final DateTime expiry;
}

final class _TermRef {
  const _TermRef(this.courseToken, this.code, this.expiry);
  final String courseToken;
  final String code;
  final DateTime expiry;
}

final class _CursorRef {
  const _CursorRef({
    required this.cursor,
    required this.kind,
    required this.intent,
    required this.guardKind,
    required this.origin,
    required this.expiry,
  });
  final PublicCursor cursor;
  final String kind;
  final String intent;
  final _GuardKind guardKind;
  final PublicQueryResult origin;
  final DateTime expiry;
}

final class _PendingResult {
  const _PendingResult({
    required this.result,
    this.events = const {},
    this.tasks = const {},
    this.publicRefs = const {},
    this.terms = const {},
    this.cursors = const {},
    this.evidence = const [],
    this.localSnapshots = const [],
    this.publicSnapshots = const [],
  });

  final AgentToolResult result;
  final Map<String, _EventRef> events;
  final Map<String, _TaskRef> tasks;
  final Map<String, _PublicRef> publicRefs;
  final Map<String, _TermRef> terms;
  final Map<String, _CursorRef> cursors;
  final List<AgentEvidence> evidence;
  final List<_LocalSnapshot> localSnapshots;
  final List<_PublicSnapshot> publicSnapshots;

  void install(_AgentToolSession session) {
    session._ensureActive();
    session._prune();
    if (session._referenceCount +
                events.length +
                tasks.length +
                publicRefs.length +
                terms.length +
                session._cursorCount +
                cursors.length >
            _maxReferencesAndCursors ||
        session._evidence.length + evidence.length > _maxEvidencePerSession ||
        session._localSnapshots.length + localSnapshots.length >
            _maxSnapshotsPerSession ||
        session._publicSnapshots.length + publicSnapshots.length >
            _maxSnapshotsPerSession) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }
    session._eventRefs.addAll(events);
    session._taskRefs.addAll(tasks);
    session._publicRefs.addAll(publicRefs);
    session._termRefs.addAll(terms);
    session._cursors.addAll(cursors);
    session._evidence.addAll(evidence);
    session._localSnapshots.addAll(localSnapshots);
    session._publicSnapshots.addAll(publicSnapshots);
  }
}

/// Fixed, read-only Agent tools. All issued identifiers live only in a run
/// session; this adapter has no route to SQL, source adapters, or file paths.
final class AgentReadTools implements AgentReadToolsPort {
  AgentReadTools({
    required this.calendar,
    required this.tasks,
    required this.calendarGuard,
    required this.knowledge,
    required this.knowledgeGuard,
    required this.publicQueries,
    required this.publicGuard,
    this.clock = const SystemClock(),
  });

  final LocalCalendarPort calendar;
  final LocalTaskPort tasks;
  final CalendarReadGuardPort calendarGuard;
  final KnowledgeReadPort knowledge;
  final PublicResultGuardPort knowledgeGuard;
  final PublicQueryPort publicQueries;
  final PublicResultGuardPort publicGuard;
  final AppClock clock;

  bool _closing = false;
  bool _closed = false;

  late final List<ModelToolDefinition> _definitions = List.unmodifiable([
    _tool(
      'query_agenda',
      '按北京时间查询本地日程窗口。',
      {
        'first_day': _stringSchema(pattern: r'^\d{4}-\d{2}-\d{2}$'),
        'end_day_exclusive': _stringSchema(pattern: r'^\d{4}-\d{2}-\d{2}$'),
        'filter': _stringSchema(enumValues: _calendarFilters),
        'include_hidden': _boolSchema(),
        'include_skipped': _boolSchema(),
        'limit': _intSchema(minimum: 1, maximum: _maxListSize),
      },
      required: const ['first_day', 'end_day_exclusive'],
    ),
    _tool(
      'read_event',
      '读取本轮查询签发的单个日程详情，不读取私人备注。',
      {'event_ref': _stringSchema(maxLength: 64)},
      required: const ['event_ref'],
    ),
    _tool('query_tasks', '按状态和标题关键词查询本地任务，不返回任务正文或备注。', {
      'filter': _stringSchema(enumValues: _taskFilters),
      'keywords': _stringSchema(maxLength: 80),
      'limit': _intSchema(minimum: 1, maximum: _maxListSize),
    }),
    _tool(
      'read_task',
      '读取本轮查询签发的任务状态与有界时间块，不读取正文或备注。',
      {'task_ref': _stringSchema(maxLength: 64)},
      required: const ['task_ref'],
    ),
    _tool(
      'inspect_conflicts',
      '检查本地有效定时日程的重叠；全天、隐藏和跳过日程不参与现行冲突投影。',
      {
        'first_day': _stringSchema(pattern: r'^\d{4}-\d{2}-\d{2}$'),
        'end_day_exclusive': _stringSchema(pattern: r'^\d{4}-\d{2}-\d{2}$'),
        'filter': _stringSchema(enumValues: _calendarFilters),
        'limit': _intSchema(minimum: 1, maximum: _maxListSize),
      },
      required: const ['first_day', 'end_day_exclusive'],
    ),
    _tool(
      'search_knowledge',
      '搜索已载入的本地精选知识材料；不会自动载入。',
      {
        'keywords': _stringSchema(maxLength: 80),
        'provider': _stringSchema(enumValues: const ['teach', 'finance']),
        'topic': _stringSchema(maxLength: 80),
        'limit': _intSchema(minimum: 1, maximum: _maxListSize),
        'cursor': _stringSchema(maxLength: 64),
      },
      required: const ['keywords'],
    ),
    _tool(
      'read_knowledge',
      '读取本轮知识搜索签发的材料正文片段。',
      {
        'material_ref': _stringSchema(maxLength: 64),
        'section_start': _intSchema(minimum: 0, maximum: 10000),
        'max_characters': _intSchema(minimum: 1, maximum: _maxBodyCharacters),
        'cursor': _stringSchema(maxLength: 64),
      },
      required: const ['material_ref'],
    ),
    _tool(
      'search_courses',
      '在已授权的公开评课来源搜索课程与教师。',
      {
        'keywords': _stringSchema(maxLength: 80),
        'limit': _intSchema(minimum: 1, maximum: _maxListSize),
        'cursor': _stringSchema(maxLength: 64),
      },
      required: const ['keywords'],
    ),
    _tool(
      'read_course',
      '读取本轮课程搜索签发的公开课程元数据与少量学期，不返回点评正文。',
      {
        'course_ref': _stringSchema(maxLength: 64),
        'term_start': _intSchema(minimum: 0, maximum: 127),
      },
      required: const ['course_ref'],
    ),
    _tool(
      'read_reviews',
      '读取课程的有界公开点评页；评分人数与点评数分开提供。',
      {
        'course_ref': _stringSchema(maxLength: 64),
        'term': _stringSchema(maxLength: 64),
        'sort': _stringSchema(enumValues: _reviewSorts),
        'limit': _intSchema(minimum: 1, maximum: _maxListSize),
        'cursor': _stringSchema(maxLength: 64),
      },
      required: const ['course_ref'],
    ),
    _tool(
      'browse_campus',
      '浏览固定校园公开栏目；财务关键词检索和 FAQ 当前不可用。',
      {
        'column': _stringSchema(enumValues: _campusColumns),
        'keywords': _stringSchema(maxLength: 80),
        'limit': _intSchema(minimum: 1, maximum: _maxListSize),
        'cursor': _stringSchema(maxLength: 64),
      },
      required: const ['column'],
    ),
    _tool(
      'read_campus_article',
      '读取本轮校园栏目结果签发的文章正文片段。',
      {
        'article_ref': _stringSchema(maxLength: 64),
        'section_start': _intSchema(minimum: 0, maximum: 10000),
        'max_characters': _intSchema(minimum: 1, maximum: _maxBodyCharacters),
        'cursor': _stringSchema(maxLength: 64),
      },
      required: const ['article_ref'],
    ),
  ]);

  @override
  List<ModelToolDefinition> get definitions => _definitions;

  AgentToolResult _result({
    required String status,
    String? failure,
    Map<String, Object?> data = const {},
    List<String> evidenceIds = const [],
  }) {
    if (!agentToolStatuses.contains(status) ||
        (failure != null && !_failureCodes.contains(failure))) {
      throw const AgentFailure(AgentFailureCode.invalidInput);
    }
    return _safeToolResult(
      status: status,
      failure: failure,
      data: data,
      evidenceIds: evidenceIds,
    );
  }

  _PendingResult _emptyPending({
    required String status,
    String? failure,
    Map<String, Object?> data = const {},
  }) => _PendingResult(
    result: _result(status: status, failure: failure, data: data),
  );

  AgentEvidence _evidence({
    required String id,
    required String provider,
    required String title,
    required DateTime observedAtUtc,
    required String scope,
    required bool complete,
    String? articleUrl,
    String? materialUrl,
    String? publishedOn,
    String? updatedOn,
    String? revision,
    String? locator,
    String? sourceVersion,
    String snippet = '',
    CalendarReference? eventReference,
    TaskReference? taskReference,
  }) => _validatedEvidence(
    id: id,
    provider: provider,
    title: title,
    observedAtUtc: observedAtUtc,
    scope: scope,
    complete: complete,
    articleUrl: articleUrl,
    materialUrl: materialUrl,
    publishedOn: publishedOn,
    updatedOn: updatedOn,
    revision: revision,
    locator: locator,
    sourceVersion: sourceVersion,
    snippet: snippet,
    eventReference: eventReference,
    taskReference: taskReference,
  );

  @override
  AgentToolSession openSession() {
    if (_closing || _closed) {
      throw const AgentFailure(AgentFailureCode.closed);
    }
    return _AgentToolSession(this);
  }

  @override
  Future<void> cancelAndDrain() =>
      publicQueries.view.phase == PublicJobPhase.recovery
      ? publicQueries.retryRecovery()
      : publicQueries.cancel();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closing = true;
    await publicQueries.close();
    _closed = true;
  }
}

final class _AgentToolSession
    implements
        AgentToolSession,
        AgentLocalReferenceSession,
        AgentDiscussionToolSession {
  _AgentToolSession(this._owner);
  final AgentReadTools _owner;
  final Map<String, _EventRef> _eventRefs = {};
  final Map<String, _TaskRef> _taskRefs = {};
  final Map<String, _PublicRef> _publicRefs = {};
  final Map<String, _TermRef> _termRefs = {};
  final Map<String, _CursorRef> _cursors = {};
  final List<AgentEvidence> _evidence = [];
  final List<_LocalSnapshot> _localSnapshots = [];
  final List<_PublicSnapshot> _publicSnapshots = [];
  bool _revoked = false;
  bool _executing = false;

  @override
  List<AgentEvidence> get evidence => List.unmodifiable(_evidence);
  @override
  Future<String> selectForDiscussion(AgentDiscussionSelection selection) async {
    _ensureActive();
    final token = _newToken('r_');
    if (selection.event != null) {
      final detail = await _owner.calendar.detail(selection.event!);
      final first = beijingDay(detail.occurrence.startsAtUtc);
      final window = await _owner.calendar.query(
        CalendarQuery(
          firstDay: first,
          endDayExclusive: first.add(const Duration(days: 1)),
          includeHidden: true,
          includeSkipped: true,
        ),
      );
      await _owner.calendar.detail(selection.event!);
      await _ensureCalendar(window.context, window.revision);
      _eventRefs[token] = _EventRef(
        detail.occurrence.reference,
        window.context,
        window.revision,
        _expiry(),
      );
      _localSnapshots.add(_LocalSnapshot(window.context, window.revision));
      return '用户从日程页选中 event_ref=$token；先用read_event核对详情。此选择不是批准。';
    }
    if (selection.task != null) {
      final detail = await _owner.tasks.taskDetail(selection.task!);
      final context = detail.task.reference.context;
      final window = await _owner.tasks.queryTasks(const TaskQuery(limit: 1));
      await _owner.tasks.taskDetail(selection.task!);
      await _ensureCalendar(context, window.revision);
      _taskRefs[token] = _TaskRef(
        detail.task.reference,
        context,
        window.revision,
        _expiry(),
      );
      _localSnapshots.add(_LocalSnapshot(context, window.revision));
      return '用户从任务页选中 task_ref=$token；先用read_task核对详情。此选择不是批准。';
    }
    throw const AgentFailure(AgentFailureCode.invalidInput);
  }

  @override
  Future<(CalendarReference, int)> resolveEventReference(String token) async {
    _ensureActive();
    _prune();
    final issued = _eventRefs[token];
    if (issued == null) {
      throw const CalendarFailure(CalendarFailureCode.staleReference);
    }
    await _ensureCalendar(issued.context, issued.revision);
    return (issued.reference, issued.revision);
  }

  @override
  Future<(TaskReference, int)> resolveTaskReference(String token) async {
    _ensureActive();
    _prune();
    final issued = _taskRefs[token];
    if (issued == null) {
      throw const CalendarFailure(CalendarFailureCode.staleReference);
    }
    await _ensureCalendar(issued.context, issued.revision);
    return (issued.reference, issued.revision);
  }

  int get _referenceCount =>
      _eventRefs.length +
      _taskRefs.length +
      _publicRefs.length +
      _termRefs.length;
  int get _cursorCount => _cursors.length;

  void _ensureActive() {
    if (_revoked || _owner._closing || _owner._closed) {
      throw const AgentFailure(AgentFailureCode.cancelled);
    }
  }

  void _prune() {
    final now = _owner.clock.nowUtc;
    _eventRefs.removeWhere((_, value) => !now.isBefore(value.expiry));
    _taskRefs.removeWhere((_, value) => !now.isBefore(value.expiry));
    _publicRefs.removeWhere((_, value) => !now.isBefore(value.expiry));
    _termRefs.removeWhere((_, value) => !now.isBefore(value.expiry));
    _cursors.removeWhere((_, value) => !now.isBefore(value.expiry));
  }

  @override
  void revoke() {
    _revoked = true;
    _eventRefs.clear();
    _taskRefs.clear();
    _publicRefs.clear();
    _termRefs.clear();
    _cursors.clear();
    _localSnapshots.clear();
    _publicSnapshots.clear();
  }

  @override
  Future<void> validateDelivery() async {
    _ensureActive();
    for (final snapshot in List<_LocalSnapshot>.of(_localSnapshots)) {
      try {
        await _owner.calendarGuard.ensureCalendarRead(
          snapshot.context,
          snapshot.revision,
        );
      } on CalendarFailure catch (failure) {
        throw _calendarGuardFailure(failure);
      }
      _ensureActive();
    }
    for (final snapshot in List<_PublicSnapshot>.of(_publicSnapshots)) {
      await _ensurePublicResult(snapshot.kind, snapshot.result);
      _ensureActive();
    }
  }

  @override
  Future<AgentToolResult> execute(ModelToolCall call) async {
    if (_executing) {
      return _owner._result(status: 'busy', failure: 'busy');
    }
    _executing = true;
    try {
      _ensureActive();
      if (!agentReadToolNames.contains(call.name)) {
        return _owner._result(status: 'unavailable', failure: 'unavailable');
      }
      AgentText.requireSafe(call.argumentsJson, maxCharacters: 4096);
      final args = _parseArguments(call.argumentsJson, call.name);
      await validateDelivery();
      _ensureActive();
      final pending = await _dispatch(call.name, args);
      _ensureActive();
      pending.install(this);
      return pending.result;
    } on AgentFailure catch (failure) {
      if (failure.code == AgentFailureCode.staleContext ||
          failure.code == AgentFailureCode.consentRequired) {
        rethrow;
      }
      return _agentFailureResult(failure);
    } on CalendarFailure catch (failure) {
      return _calendarFailureResult(failure);
    } on PublicFailure catch (failure) {
      return _publicFailureResult(failure);
    } on Object {
      return _owner._result(status: 'failure', failure: 'storageFailed');
    } finally {
      _executing = false;
    }
  }

  Future<_PendingResult> _dispatch(String name, Map<String, Object?> args) =>
      switch (name) {
        'query_agenda' => _queryAgenda(args),
        'read_event' => _readEvent(args),
        'query_tasks' => _queryTasks(args),
        'read_task' => _readTask(args),
        'inspect_conflicts' => _inspectConflicts(args),
        'search_knowledge' => _searchKnowledge(args),
        'read_knowledge' => _readKnowledge(args),
        'search_courses' => _searchCourses(args),
        'read_course' => _readCourse(args),
        'read_reviews' => _readReviews(args),
        'browse_campus' => _browseCampus(args),
        'read_campus_article' => _readCampusArticle(args),
        _ => Future.value(
          _owner._emptyPending(status: 'unavailable', failure: 'unavailable'),
        ),
      };

  Future<void> _ensureCalendar(CalendarContext context, int revision) async {
    try {
      await _owner.calendarGuard.ensureCalendarRead(context, revision);
    } on CalendarFailure catch (failure) {
      throw _calendarGuardFailure(failure);
    }
    _ensureActive();
  }

  Future<void> _ensurePublicResult(
    _GuardKind kind,
    PublicQueryResult result,
  ) async {
    try {
      if (kind == _GuardKind.knowledge) {
        await _owner.knowledgeGuard.ensurePublicResult(result);
      } else {
        await _owner.publicGuard.ensurePublicResult(result);
      }
    } on PublicFailure catch (failure) {
      if (failure.code == PublicFailureCode.consentRequired) {
        throw const AgentFailure(AgentFailureCode.consentRequired);
      }
      if (failure.code == PublicFailureCode.staleReference) {
        throw const AgentFailure(AgentFailureCode.staleContext);
      }
      rethrow;
    }
    _ensureActive();
  }

  _PendingResult _pending({
    required String status,
    Map<String, Object?> data = const {},
    List<String> evidenceIds = const [],
    Map<String, _EventRef> events = const {},
    Map<String, _TaskRef> tasks = const {},
    Map<String, _PublicRef> publicRefs = const {},
    Map<String, _TermRef> terms = const {},
    Map<String, _CursorRef> cursors = const {},
    List<AgentEvidence> evidence = const [],
    List<_LocalSnapshot> localSnapshots = const [],
    List<_PublicSnapshot> publicSnapshots = const [],
    String? failure,
  }) {
    _prune();
    final total =
        _referenceCount +
        events.length +
        tasks.length +
        publicRefs.length +
        terms.length +
        _cursorCount +
        cursors.length;
    if (total > _maxReferencesAndCursors ||
        _evidence.length + evidence.length > _maxEvidencePerSession ||
        _localSnapshots.length + localSnapshots.length >
            _maxSnapshotsPerSession ||
        _publicSnapshots.length + publicSnapshots.length >
            _maxSnapshotsPerSession) {
      return _owner._emptyPending(
        status: 'resourceLimit',
        failure: 'resourceLimit',
      );
    }
    final result = _owner._result(
      status: status,
      failure: failure,
      data: data,
      evidenceIds: evidenceIds,
    );
    if (_encodedToolResultBytes(result, evidence) > _maxResultBytes) {
      return _owner._emptyPending(
        status: 'resourceLimit',
        failure: 'resourceLimit',
      );
    }
    return _PendingResult(
      result: result,
      events: events,
      tasks: tasks,
      publicRefs: publicRefs,
      terms: terms,
      cursors: cursors,
      evidence: evidence,
      localSnapshots: localSnapshots,
      publicSnapshots: publicSnapshots,
    );
  }

  DateTime _expiry() => _owner.clock.nowUtc.add(_referenceLifetime);

  String _newToken(String prefix) => _randomHex(prefix, 16);

  AgentEvidence _localEvidence({
    required String title,
    required String scope,
    required String locator,
    required String snippet,
    required bool complete,
    CalendarReference? eventReference,
    TaskReference? taskReference,
  }) => _owner._evidence(
    id: _randomHex('e_', 16),
    provider: 'local',
    title: title,
    observedAtUtc: _owner.clock.nowUtc,
    scope: scope,
    complete: complete,
    locator: locator,
    snippet: _clipRunes(snippet, 400),
    eventReference: eventReference,
    taskReference: taskReference,
  );

  AgentEvidence _publicEvidence({
    required PublicEvidence source,
    required PublicCoverage coverage,
    required String snippet,
    String? title,
    String? scope,
    String? locator,
    bool? complete,
  }) => _owner._evidence(
    id: _randomHex('e_', 16),
    provider: source.provider.name,
    title: title ?? source.title,
    observedAtUtc: source.observedAtUtc.toUtc(),
    scope: scope ?? source.coveredScope ?? coverage.scope,
    complete: complete ?? coverage.complete,
    articleUrl: source.articleUrl.toString(),
    materialUrl: source.materialUrl?.toString(),
    publishedOn: source.publishedOn,
    updatedOn: source.updatedOn,
    revision: source.revision,
    locator: locator ?? source.locator,
    sourceVersion: source.sourceVersion,
    snippet: _clipRunes(snippet, 400),
  );

  Map<String, Object?> _occurrenceData(
    CalendarOccurrence item, {
    required String eventToken,
  }) {
    final details = item.academicDetails;
    final primaryRoom = details == null
        ? item.location
        : details.room.isNotEmpty
        ? details.room
        : details.roomCode.isNotEmpty
        ? details.roomCode
        : details.customPlace;
    final location = details == null
        ? item.location
        : [
            primaryRoom,
            details.building,
            details.campus,
          ].where((part) => part.isNotEmpty).toSet().join(' · ');
    final allDay = item.allDay;
    return {
      'event_ref': eventToken,
      'kind': item.reference.identity.kind.name,
      'title': item.title,
      'all_day': allDay,
      if (allDay) ...{
        'start_day': _formatDay(beijingDay(item.startsAtUtc)),
        'end_day_exclusive': _formatDay(beijingDay(item.endsAtUtc)),
      } else ...{
        'start': _beijingDateTime(item.startsAtUtc),
        'end': _beijingDateTime(item.endsAtUtc),
      },
      'presence': item.presence.name,
      if (item.reference.identity.kind == CalendarKind.young) ...{
        'calendar_basis': 'activityLinkedPersonalCalendar',
        'registration_verified': false,
      },
      'hidden': item.hidden,
      'skipped': item.skipped,
      'completed': item.completed,
      'location': location,
      'teachers': details?.teachers,
      'course_code': details?.courseCode,
      'course_type': details?.courseType,
      'semester': details?.semesterName,
      'week': details?.weekIndex,
      'weekday': details?.weekday,
      'periods': details?.periods,
      'exam_type': details?.examType,
      'task_status': item.taskStatus?.name,
      'block_status': item.planBlockStatus?.name,
    };
  }

  AgentEvidence _occurrenceEvidence(
    CalendarOccurrence item,
    String token,
    String scope, {
    bool complete = true,
  }) {
    final data = _occurrenceData(item, eventToken: token);
    final timeText = item.allDay
        ? '${data['start_day']}–${data['end_day_exclusive']}'
        : '${data['start']}–${data['end']}';
    final teachers = item.academicDetails?.teachers;
    final teacherText = teachers == null || teachers.isEmpty
        ? ''
        : '；教师：${teachers.join('、')}';
    final location = data['location'] as String? ?? '';
    return _localEvidence(
      title: item.title,
      scope: scope,
      locator: token,
      snippet: '${item.title}；$timeText；地点：$location$teacherText',
      complete: complete,
      eventReference: item.reference,
    );
  }

  Future<_PendingResult> _queryAgenda(Map<String, Object?> args) async {
    final first = _dateArg(args, 'first_day');
    final end = _dateArg(args, 'end_day_exclusive');
    final days = end.difference(first).inDays;
    if (days < 1 || days > 31) _invalid();
    final filter = _enumArg(args, 'filter', _calendarFilters, fallback: 'all');
    final includeHidden = _boolArg(args, 'include_hidden', fallback: false);
    final includeSkipped = _boolArg(args, 'include_skipped', fallback: false);
    final limit = _intArg(
      args,
      'limit',
      fallback: 10,
      minimum: 1,
      maximum: _maxListSize,
    );
    final query = CalendarQuery(
      firstDay: first,
      endDayExclusive: end,
      filter: CalendarFilter.values.byName(filter),
      includeHidden: includeHidden,
      includeSkipped: includeSkipped,
      limit: limit,
    );
    final window = await _owner.calendar.query(query);
    _ensureActive();
    await _ensureCalendar(window.context, window.revision);
    final events = <String, _EventRef>{};
    final evidence = <AgentEvidence>[];
    final ids = <String>[];
    final rows = <Map<String, Object?>>[];
    final scope = '本地日程 ${_formatDay(first)}–${_formatDay(end)}（结束日期不含）';
    for (final item in window.items) {
      final token = _newToken('r_');
      events[token] = _EventRef(
        item.reference,
        window.context,
        window.revision,
        _expiry(),
      );
      rows.add(_occurrenceData(item, eventToken: token));
      final ev = _occurrenceEvidence(
        item,
        token,
        scope,
        complete: !window.truncated,
      );
      evidence.add(ev);
      ids.add(ev.id);
    }
    final coverage = _localCoverage(
      scope: scope,
      returned: rows.length,
      observed: rows.length,
      totalReported: window.matched,
      truncated: window.truncated,
      complete: !window.truncated,
    );
    final status = window.truncated
        ? 'partial'
        : rows.isEmpty
        ? 'empty'
        : 'success';
    return _pending(
      status: status,
      data: {
        'items': rows,
        'coverage': coverage,
        'filter': filter,
        'include_hidden': includeHidden,
        'include_skipped': includeSkipped,
      },
      evidenceIds: ids,
      events: events,
      evidence: evidence,
      localSnapshots: [_LocalSnapshot(window.context, window.revision)],
    );
  }

  Future<_PendingResult> _readEvent(Map<String, Object?> args) async {
    final token = _stringArg(args, 'event_ref');
    _prune();
    final issued = _eventRefs[token];
    if (issued == null) {
      throw const CalendarFailure(CalendarFailureCode.staleReference);
    }
    await _ensureCalendar(issued.context, issued.revision);
    final detail = await _owner.calendar.detail(issued.reference);
    _ensureActive();
    await _ensureCalendar(issued.context, issued.revision);
    final item = detail.occurrence;
    final data = _occurrenceData(item, eventToken: token);
    data['has_occurrence_replacement'] = detail.hasOccurrenceReplacement;
    data['related_decisions'] = detail.relations
        .map((relation) => relation.kind.name)
        .toList();
    if (detail.planBlock != null) {
      final block = detail.planBlock!;
      data['plan_block'] = {
        'start': _beijingDateTime(block.draft.startsAtUtc),
        'end': _beijingDateTime(block.draft.endsAtUtc),
        'location': block.draft.location,
        'task_status': block.taskStatus.name,
        'block_status': block.status.name,
      };
    }
    final evidence = _occurrenceEvidence(item, token, '本地日程详情');
    return _pending(
      status: 'success',
      data: {
        ...data,
        'coverage': _localCoverage(
          scope: '本地日程详情',
          returned: 1,
          observed: 1,
          totalReported: 1,
          truncated: false,
          complete: true,
        ),
      },
      evidenceIds: [evidence.id],
      evidence: [evidence],
      localSnapshots: [_LocalSnapshot(issued.context, issued.revision)],
    );
  }

  Future<_PendingResult> _queryTasks(Map<String, Object?> args) async {
    final filter = _enumArg(args, 'filter', _taskFilters, fallback: 'open');
    final keywords = _localKeywords(args, 'keywords', fallback: '');
    final limit = _intArg(
      args,
      'limit',
      fallback: _defaultListSize,
      minimum: 1,
      maximum: _maxListSize,
    );
    final window = await _owner.tasks.queryTasks(
      TaskQuery(
        filter: TaskFilter.values.byName(filter),
        keyword: keywords,
        limit: limit,
      ),
    );
    _ensureActive();
    await _ensureCalendar(window.context, window.revision);
    final taskRefs = <String, _TaskRef>{};
    final evidence = <AgentEvidence>[];
    final evidenceIds = <String>[];
    final rows = <Map<String, Object?>>[];
    for (final task in window.items) {
      final token = _newToken('r_');
      taskRefs[token] = _TaskRef(
        task.reference,
        window.context,
        window.revision,
        _expiry(),
      );
      final deadline = task.draft.deadlineAtUtc == null
          ? null
          : _beijingDateTime(task.draft.deadlineAtUtc!);
      rows.add({
        'task_ref': token,
        'title': task.draft.title,
        'status': task.status.name,
        'priority': task.draft.priority.name,
        'deadline': deadline,
        'estimated_minutes': task.draft.estimatedMinutes,
        'block_count': task.blockCount,
      });
      final ev = _localEvidence(
        title: task.draft.title,
        taskReference: task.reference,
        scope: '本地任务列表',
        locator: token,
        snippet:
            '${task.draft.title}；状态：${task.status.name}；截止：${deadline ?? '未设置'}',
        complete: !window.truncated,
      );
      evidence.add(ev);
      evidenceIds.add(ev.id);
    }
    final coverage = _localCoverage(
      scope: '本地任务列表',
      returned: rows.length,
      observed: rows.length,
      totalReported: window.matched,
      truncated: window.truncated,
      complete: !window.truncated,
    );
    final status = window.truncated
        ? 'partial'
        : rows.isEmpty
        ? 'empty'
        : 'success';
    return _pending(
      status: status,
      data: {'items': rows, 'coverage': coverage, 'filter': filter},
      evidenceIds: evidenceIds,
      tasks: taskRefs,
      evidence: evidence,
      localSnapshots: [_LocalSnapshot(window.context, window.revision)],
    );
  }

  Future<_PendingResult> _readTask(Map<String, Object?> args) async {
    final token = _stringArg(args, 'task_ref');
    _prune();
    final issued = _taskRefs[token];
    if (issued == null) {
      throw const CalendarFailure(CalendarFailureCode.staleReference);
    }
    await _ensureCalendar(issued.context, issued.revision);
    final detail = await _owner.tasks.taskDetail(issued.reference);
    _ensureActive();
    await _ensureCalendar(issued.context, issued.revision);
    final task = detail.task;
    final allBlocks = detail.blocks;
    final blocks = allBlocks
        .take(_maxListSize)
        .map(
          (block) => {
            'start': _beijingDateTime(block.draft.startsAtUtc),
            'end': _beijingDateTime(block.draft.endsAtUtc),
            'location': block.draft.location,
            'task_status': block.taskStatus.name,
            'block_status': block.status.name,
          },
        )
        .toList();
    final truncated = allBlocks.length > blocks.length;
    final deadline = task.draft.deadlineAtUtc == null
        ? null
        : _beijingDateTime(task.draft.deadlineAtUtc!);
    final evidence = _localEvidence(
      title: task.draft.title,
      taskReference: task.reference,
      scope: '本地任务详情',
      locator: token,
      snippet:
          '${task.draft.title}；任务状态：${task.status.name}；时间块：${blocks.length}；截止：${deadline ?? '未设置'}',
      complete: !truncated,
    );
    return _pending(
      status: truncated ? 'partial' : 'success',
      data: {
        'task_ref': token,
        'title': task.draft.title,
        'status': task.status.name,
        'priority': task.draft.priority.name,
        'deadline': deadline,
        'estimated_minutes': task.draft.estimatedMinutes,
        'block_count': task.blockCount,
        'blocks': blocks,
        'coverage': _localCoverage(
          scope: '本地任务详情时间块',
          returned: blocks.length,
          observed: allBlocks.length,
          totalReported: task.blockCount,
          truncated: truncated,
          complete: !truncated,
        ),
      },
      evidenceIds: [evidence.id],
      evidence: [evidence],
      localSnapshots: [_LocalSnapshot(issued.context, issued.revision)],
    );
  }

  Future<_PendingResult> _inspectConflicts(Map<String, Object?> args) async {
    final first = _dateArg(args, 'first_day');
    final end = _dateArg(args, 'end_day_exclusive');
    final days = end.difference(first).inDays;
    if (days < 1 || days > 31) _invalid();
    final filter = _enumArg(args, 'filter', _calendarFilters, fallback: 'all');
    final limit = _intArg(
      args,
      'limit',
      fallback: _defaultListSize,
      minimum: 1,
      maximum: _maxListSize,
    );
    final query = CalendarQuery(
      firstDay: first,
      endDayExclusive: end,
      filter: CalendarFilter.values.byName(filter),
      includeHidden: false,
      includeSkipped: false,
      limit: limit,
    );
    final window = await _owner.calendar.query(query);
    _ensureActive();
    await _ensureCalendar(window.context, window.revision);
    final conflicts = window.conflicts.where((pair) {
      if (pair.left.allDay ||
          pair.right.allDay ||
          pair.left.hidden ||
          pair.right.hidden ||
          pair.left.skipped ||
          pair.right.skipped) {
        return false;
      }
      if (filter == 'all') return true;
      return _matchesCalendarFilter(pair.left, filter) ||
          _matchesCalendarFilter(pair.right, filter);
    }).toList();
    final selected = conflicts.take(limit).toList();
    final eventTokens = <CalendarReference, String>{};
    final eventRefs = <String, _EventRef>{};
    final evidence = <AgentEvidence>[];
    final evidenceIds = <String>[];
    String eventToken(CalendarOccurrence item) =>
        eventTokens.putIfAbsent(item.reference, () {
          final token = _newToken('r_');
          eventRefs[token] = _EventRef(
            item.reference,
            window.context,
            window.revision,
            _expiry(),
          );
          return token;
        });
    final rows = <Map<String, Object?>>[];
    for (final pair in selected) {
      final leftToken = eventToken(pair.left);
      final rightToken = eventToken(pair.right);
      final status = pair.status.name;
      rows.add({
        'left': _occurrenceData(pair.left, eventToken: leftToken),
        'right': _occurrenceData(pair.right, eventToken: rightToken),
        'status': status,
        'explicit_decision': pair.hasExplicitDecision,
      });
      final title = '${pair.left.title} × ${pair.right.title}';
      final snippet =
          '${pair.left.title}（${_beijingDateTime(pair.left.startsAtUtc)}）与 '
          '${pair.right.title}（${_beijingDateTime(pair.right.startsAtUtc)}）：$status';
      final ev = _localEvidence(
        title: title,
        scope: '本地有效定时冲突投影 ${_formatDay(first)}–${_formatDay(end)}',
        locator: '$leftToken · $rightToken',
        snippet: snippet,
        complete:
            !window.truncated &&
            !window.conflictsTruncated &&
            conflicts.length <= limit,
      );
      evidence.add(ev);
      evidenceIds.add(ev.id);
    }
    final truncated =
        window.truncated ||
        window.conflictsTruncated ||
        conflicts.length > limit;
    final coverage = _localCoverage(
      scope: '本地有效定时冲突投影；隐藏、跳过和全天日程不参与',
      returned: rows.length,
      observed: conflicts.length,
      totalReported: truncated ? null : conflicts.length,
      truncated: truncated,
      complete: !truncated,
    );
    final status = truncated
        ? 'partial'
        : rows.isEmpty
        ? 'empty'
        : 'success';
    return _pending(
      status: status,
      data: {
        'items': rows,
        'coverage': coverage,
        'filter': filter,
        'conflict_scope': '有效定时日程；隐藏、跳过和全天日程不参与',
      },
      evidenceIds: evidenceIds,
      events: eventRefs,
      evidence: evidence,
      localSnapshots: [_LocalSnapshot(window.context, window.revision)],
    );
  }

  Future<_PendingResult> _searchKnowledge(Map<String, Object?> args) async {
    final keywords = _publicKeywords(args, 'keywords');
    final providerName = _optionalEnumArg(args, 'provider', const [
      'teach',
      'finance',
    ]);
    final provider = providerName == null
        ? null
        : PublicProvider.values.byName(providerName);
    final topic = _optionalText(args, 'topic', maxRunes: 80);
    final limit = _intArg(
      args,
      'limit',
      fallback: _defaultListSize,
      minimum: 1,
      maximum: _maxListSize,
    );
    final intent = _intent([
      'search_knowledge',
      keywords,
      providerName,
      topic,
      limit,
    ]);
    final cursor = await _resolveCursor(
      _optionalString(args, 'cursor'),
      kind: 'search_knowledge',
      intent: intent,
      guardKind: _GuardKind.knowledge,
    );
    final summary = await _owner.knowledge.inspectKnowledge();
    _ensureActive();
    if (summary.materialCount == 0) {
      if (summary.loading) {
        return _owner._emptyPending(status: 'busy', failure: 'busy');
      }
      return _owner._emptyPending(
        status: 'unavailable',
        failure: 'knowledgeNotLoaded',
        data: {
          'coverage': _localCoverage(
            scope: '已载入知识材料',
            returned: 0,
            observed: null,
            totalReported: 0,
            truncated: false,
            complete: false,
          ),
        },
      );
    }
    final result = await _owner.knowledge.searchKnowledge(
      keywords,
      provider: provider,
      topic: topic,
      pageSize: limit,
      cursor: cursor,
    );
    _ensureActive();
    await _ensurePublicResult(_GuardKind.knowledge, result);
    final refs = <String, _PublicRef>{};
    final cursors = <String, _CursorRef>{};
    final evidence = <AgentEvidence>[];
    final evidenceIds = <String>[];
    final rows = <Map<String, Object?>>[];
    final expiry = _expiry();
    for (final candidate in result.candidates) {
      final token = _newToken('r_');
      refs[token] = _PublicRef(
        reference: candidate.reference,
        kind: 'knowledge',
        guardKind: _GuardKind.knowledge,
        origin: result,
        expiry: expiry,
      );
      final ev = _publicEvidence(
        source: candidate.evidence,
        coverage: result.coverage,
        snippet: candidate.snippet,
      );
      evidence.add(ev);
      evidenceIds.add(ev.id);
      rows.add({
        'material_ref': token,
        'title': candidate.title,
        'provider': candidate.evidence.provider.name,
        'scope': candidate.evidence.coveredScope,
        'snippet': _clipRunes(candidate.snippet, 400),
        'evidence_id': ev.id,
      });
    }
    final next = _issueCursor(
      result.next,
      kind: 'search_knowledge',
      intent: intent,
      guardKind: _GuardKind.knowledge,
      origin: result,
      cursors: cursors,
    );
    return _pending(
      status: _publicStatus(result),
      data: {
        'items': rows,
        'next_cursor': next,
        'coverage': _publicCoverage(result.coverage),
      },
      evidenceIds: evidenceIds,
      publicRefs: refs,
      cursors: cursors,
      evidence: evidence,
      publicSnapshots: [_PublicSnapshot(_GuardKind.knowledge, result)],
    );
  }

  Future<_PendingResult> _readKnowledge(Map<String, Object?> args) async {
    final token = _stringArg(args, 'material_ref');
    final start = _intArg(
      args,
      'section_start',
      fallback: 0,
      minimum: 0,
      maximum: 10000,
    );
    final maxCharacters = _intArg(
      args,
      'max_characters',
      fallback: _maxBodyCharacters,
      minimum: 1,
      maximum: _maxBodyCharacters,
    );
    final intent = _intent(['read_knowledge', token, start, maxCharacters]);
    _prune();
    final issued = _publicRefs[token];
    if (issued == null ||
        issued.kind != 'knowledge' ||
        issued.guardKind != _GuardKind.knowledge) {
      throw const PublicFailure(PublicFailureCode.staleReference);
    }
    await _ensurePublicResult(_GuardKind.knowledge, issued.origin);
    final cursor = await _resolveCursor(
      _optionalString(args, 'cursor'),
      kind: 'read_knowledge',
      intent: intent,
      guardKind: _GuardKind.knowledge,
    );
    final result = await _owner.knowledge.readKnowledgeMaterial(
      issued.reference,
      sectionStart: start,
      maxCharacters: maxCharacters,
      cursor: cursor,
    );
    _ensureActive();
    await _ensurePublicResult(_GuardKind.knowledge, result);
    final document = result.document;
    if (document == null) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    if (document.markdown.runes.length > maxCharacters) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    final markdown = document.markdown;
    final bodyTruncated =
        markdown.runes.length < document.markdown.runes.length;
    final evidence = _publicEvidence(
      source: document.evidence,
      coverage: result.coverage,
      snippet: markdown,
      complete: result.coverage.complete && !bodyTruncated,
    );
    final coverage = _publicCoverage(
      result.coverage,
      truncated: result.coverage.truncated || bodyTruncated,
      complete: result.coverage.complete && !bodyTruncated,
    );
    final cursorMap = _cursorPendingForRead(
      result.next,
      kind: 'read_knowledge',
      intent: intent,
      guardKind: _GuardKind.knowledge,
      origin: result,
    );
    return _pending(
      status: bodyTruncated ? 'partial' : _publicStatus(result),
      data: {
        'material_ref': token,
        'content': markdown,
        'next_cursor': cursorMap.keys.firstOrNull,
        'coverage': coverage,
      },
      evidenceIds: [evidence.id],
      cursors: cursorMap,
      evidence: [evidence],
      publicSnapshots: [
        _PublicSnapshot(_GuardKind.knowledge, issued.origin),
        _PublicSnapshot(_GuardKind.knowledge, result),
      ],
    );
  }

  Future<_PendingResult> _searchCourses(Map<String, Object?> args) async {
    final keywords = _publicKeywords(args, 'keywords');
    final limit = _intArg(
      args,
      'limit',
      fallback: _defaultListSize,
      minimum: 1,
      maximum: _maxListSize,
    );
    final intent = _intent(['search_courses', keywords, limit]);
    final cursor = await _resolveCursor(
      _optionalString(args, 'cursor'),
      kind: 'search_courses',
      intent: intent,
      guardKind: _GuardKind.online,
    );
    final result = await _owner.publicQueries.searchCourses(
      keywords,
      pageSize: limit,
      cursor: cursor,
    );
    _ensureActive();
    await _ensurePublicResult(_GuardKind.online, result);
    final refs = <String, _PublicRef>{};
    final termRefs = <String, _TermRef>{};
    final cursorRefs = <String, _CursorRef>{};
    final evidence = <AgentEvidence>[];
    final evidenceIds = <String>[];
    final rows = <Map<String, Object?>>[];
    final expiry = _expiry();
    for (final candidate in result.candidates) {
      final token = _newToken('r_');
      refs[token] = _PublicRef(
        reference: candidate.reference,
        kind: 'course',
        guardKind: _GuardKind.online,
        origin: result,
        expiry: expiry,
      );
      final course = _courseMap(
        candidate.course,
        courseToken: token,
        pendingTerms: termRefs,
      );
      final ev = _publicEvidence(
        source: candidate.evidence,
        coverage: result.coverage,
        snippet: candidate.snippet,
      );
      evidence.add(ev);
      evidenceIds.add(ev.id);
      rows.add({
        'course_ref': token,
        'title': candidate.title,
        'snippet': _clipRunes(candidate.snippet, 400),
        'course': course,
        'evidence_id': ev.id,
      });
    }
    final next = _issueCursor(
      result.next,
      kind: 'search_courses',
      intent: intent,
      guardKind: _GuardKind.online,
      origin: result,
      cursors: cursorRefs,
    );
    return _pending(
      status: _publicStatus(result),
      data: {
        'items': rows,
        'next_cursor': next,
        'coverage': _publicCoverage(result.coverage),
      },
      evidenceIds: evidenceIds,
      publicRefs: refs,
      terms: termRefs,
      cursors: cursorRefs,
      evidence: evidence,
      publicSnapshots: [_PublicSnapshot(_GuardKind.online, result)],
    );
  }

  Future<_PendingResult> _readCourse(Map<String, Object?> args) async {
    final token = _stringArg(args, 'course_ref');
    final termStart = _intArg(
      args,
      'term_start',
      fallback: 0,
      minimum: 0,
      maximum: 127,
    );
    _prune();
    final issued = _publicRefs[token];
    if (issued == null ||
        issued.kind != 'course' ||
        issued.guardKind != _GuardKind.online) {
      throw const PublicFailure(PublicFailureCode.staleReference);
    }
    await _ensurePublicResult(_GuardKind.online, issued.origin);
    final result = await _owner.publicQueries.readCourse(
      issued.reference,
      pageSize: 1,
    );
    _ensureActive();
    await _ensurePublicResult(_GuardKind.online, result);
    final document = result.document;
    final info = document?.course;
    if (document == null || info == null) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    final terms = <String, _TermRef>{};
    final courseData = _courseMap(
      info,
      courseToken: token,
      pendingTerms: terms,
      termStart: termStart,
    );
    final termCount = info.terms.length;
    final termTruncated = termStart + 5 < termCount;
    final metadataCoverage = _localCoverage(
      scope: '公开课程元数据',
      returned: 1,
      observed: 1,
      totalReported: 1,
      truncated: termTruncated,
      complete: !termTruncated,
    );
    final snippet =
        '${info.title}；教师：${info.teacher}；评分：${info.score ?? '未提供'}；'
        '评分人数：${info.ratingCount ?? '未提供'}；点评数：${info.reviewCount ?? '未提供'}';
    final sourceEvidence = document.evidence;
    final evidence = _publicEvidence(
      source: sourceEvidence,
      coverage: result.coverage,
      title: info.title,
      scope: '公开课程元数据',
      locator: '课程信息',
      complete: !termTruncated,
      snippet: snippet,
    );
    return _pending(
      status: termTruncated ? 'partial' : 'success',
      data: {
        'course_ref': token,
        'course': courseData,
        'reviews_included': false,
        'coverage': metadataCoverage,
        'source_coverage': _publicCoverage(result.coverage),
      },
      evidenceIds: [evidence.id],
      terms: terms,
      evidence: [evidence],
      publicSnapshots: [
        _PublicSnapshot(_GuardKind.online, issued.origin),
        _PublicSnapshot(_GuardKind.online, result),
      ],
    );
  }

  Future<_PendingResult> _readReviews(Map<String, Object?> args) async {
    final token = _stringArg(args, 'course_ref');
    final termToken = _optionalString(args, 'term');
    final sortName = _enumArg(args, 'sort', _reviewSorts, fallback: 'upvote');
    final limit = _intArg(
      args,
      'limit',
      fallback: _defaultListSize,
      minimum: 1,
      maximum: _maxListSize,
    );
    _prune();
    final issued = _publicRefs[token];
    if (issued == null ||
        issued.kind != 'course' ||
        issued.guardKind != _GuardKind.online) {
      throw const PublicFailure(PublicFailureCode.staleReference);
    }
    final termCode = termToken == null ? null : _resolveTerm(token, termToken);
    final intent = _intent(['read_reviews', token, termToken, sortName, limit]);
    await _ensurePublicResult(_GuardKind.online, issued.origin);
    final cursor = await _resolveCursor(
      _optionalString(args, 'cursor'),
      kind: 'read_reviews',
      intent: intent,
      guardKind: _GuardKind.online,
    );
    final sort = CourseReviewSort.values.byName(sortName);
    final PublicQueryResult result;
    final readPort = _owner.publicQueries;
    if (readPort is PublicReviewReadPort) {
      result = await (readPort as PublicReviewReadPort).readCourseSlice(
        issued.reference,
        term: termCode,
        sort: sort,
        pageSize: limit,
        maxCharacters: _maxBodyCharacters,
        cursor: cursor,
      );
    } else {
      result = await readPort.readCourse(
        issued.reference,
        term: termCode,
        sort: sort,
        pageSize: limit,
        cursor: cursor,
      );
    }
    _ensureActive();
    await _ensurePublicResult(_GuardKind.online, result);
    final document = result.document;
    if (document == null) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    final terms = <String, _TermRef>{};
    final metadata = _courseMap(
      document.course,
      courseToken: token,
      pendingTerms: terms,
    );
    final reviews = <Map<String, Object?>>[];
    var reviewCharacters = 0;
    for (final review in document.reviews) {
      reviewCharacters += review.text.runes.length;
      if (reviewCharacters > _maxBodyCharacters) {
        throw const AgentFailure(AgentFailureCode.resourceLimit);
      }
      final mappedTerm = review.term == null
          ? null
          : _termTokenForCode(token, review.term!, terms);
      reviews.add({'text': review.text, 'term': mappedTerm});
    }
    final snippet = document.reviews.map((review) => review.text).join('\n');
    final evidence = _publicEvidence(
      source: document.evidence,
      coverage: result.coverage,
      snippet: snippet,
    );
    final cursorRefs = <String, _CursorRef>{};
    final next = _issueCursor(
      result.next,
      kind: 'read_reviews',
      intent: intent,
      guardKind: _GuardKind.online,
      origin: result,
      cursors: cursorRefs,
    );
    return _pending(
      status: _publicStatus(result),
      data: {
        'course': metadata,
        'reviews': reviews,
        'rating_count': document.course?.ratingCount,
        'review_count': document.course?.reviewCount,
        'rating': document.course?.score,
        'sort': sortName,
        'term': termToken,
        'next_cursor': next,
        'coverage': _publicCoverage(result.coverage),
      },
      evidenceIds: [evidence.id],
      terms: terms,
      cursors: cursorRefs,
      evidence: [evidence],
      publicSnapshots: [
        _PublicSnapshot(_GuardKind.online, issued.origin),
        _PublicSnapshot(_GuardKind.online, result),
      ],
    );
  }

  Future<_PendingResult> _browseCampus(Map<String, Object?> args) async {
    final columnName = _enumArg(args, 'column', _campusColumns);
    final column = CampusColumn.values.byName(columnName);
    final rawKeywords = _optionalText(args, 'keywords', maxRunes: 80);
    final keywords = rawKeywords == null || rawKeywords.isEmpty
        ? null
        : rawKeywords;
    final limit = _intArg(
      args,
      'limit',
      fallback: _defaultListSize,
      minimum: 1,
      maximum: _maxListSize,
    );
    if (column == CampusColumn.financeFaq ||
        (column.provider == PublicProvider.finance && keywords != null)) {
      return _owner._emptyPending(
        status: 'unavailable',
        failure: 'unavailable',
        data: {
          'coverage': _localCoverage(
            scope: column.name,
            returned: 0,
            observed: null,
            totalReported: null,
            truncated: false,
            complete: false,
          ),
        },
      );
    }
    final intent = _intent(['browse_campus', columnName, keywords, limit]);
    final cursor = await _resolveCursor(
      _optionalString(args, 'cursor'),
      kind: 'browse_campus',
      intent: intent,
      guardKind: _GuardKind.online,
    );
    final result = await _owner.publicQueries.browseCampus(
      column,
      keywords: keywords,
      pageSize: limit,
      cursor: cursor,
    );
    _ensureActive();
    await _ensurePublicResult(_GuardKind.online, result);
    final refs = <String, _PublicRef>{};
    final evidence = <AgentEvidence>[];
    final evidenceIds = <String>[];
    final rows = <Map<String, Object?>>[];
    final expiry = _expiry();
    for (final candidate in result.candidates) {
      final token = _newToken('r_');
      refs[token] = _PublicRef(
        reference: candidate.reference,
        kind: 'article',
        guardKind: _GuardKind.online,
        origin: result,
        expiry: expiry,
      );
      final ev = _publicEvidence(
        source: candidate.evidence,
        coverage: result.coverage,
        snippet: candidate.snippet,
      );
      evidence.add(ev);
      evidenceIds.add(ev.id);
      rows.add({
        'article_ref': token,
        'title': candidate.title,
        'snippet': _clipRunes(candidate.snippet, 400),
        'provider': candidate.evidence.provider.name,
        'published_on': candidate.evidence.publishedOn,
        'updated_on': candidate.evidence.updatedOn,
        'evidence_id': ev.id,
      });
    }
    final cursorRefs = <String, _CursorRef>{};
    final next = _issueCursor(
      result.next,
      kind: 'browse_campus',
      intent: intent,
      guardKind: _GuardKind.online,
      origin: result,
      cursors: cursorRefs,
    );
    return _pending(
      status: _publicStatus(result),
      data: {
        'items': rows,
        'column': column.name,
        'next_cursor': next,
        'coverage': _publicCoverage(result.coverage),
      },
      evidenceIds: evidenceIds,
      publicRefs: refs,
      cursors: cursorRefs,
      evidence: evidence,
      publicSnapshots: [_PublicSnapshot(_GuardKind.online, result)],
    );
  }

  Future<_PendingResult> _readCampusArticle(Map<String, Object?> args) async {
    final token = _stringArg(args, 'article_ref');
    final sectionStart = _intArg(
      args,
      'section_start',
      fallback: 0,
      minimum: 0,
      maximum: 10000,
    );
    final maxCharacters = _intArg(
      args,
      'max_characters',
      fallback: _maxBodyCharacters,
      minimum: 1,
      maximum: _maxBodyCharacters,
    );
    final intent = _intent([
      'read_campus_article',
      token,
      sectionStart,
      maxCharacters,
    ]);
    _prune();
    final issued = _publicRefs[token];
    if (issued == null ||
        issued.kind != 'article' ||
        issued.guardKind != _GuardKind.online) {
      throw const PublicFailure(PublicFailureCode.staleReference);
    }
    await _ensurePublicResult(_GuardKind.online, issued.origin);
    final cursor = await _resolveCursor(
      _optionalString(args, 'cursor'),
      kind: 'read_campus_article',
      intent: intent,
      guardKind: _GuardKind.online,
    );
    final result = await _owner.publicQueries.readCampusArticle(
      issued.reference,
      sectionStart: sectionStart,
      maxCharacters: maxCharacters,
      cursor: cursor,
    );
    _ensureActive();
    await _ensurePublicResult(_GuardKind.online, result);
    final document = result.document;
    if (document == null) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    if (document.markdown.runes.length > maxCharacters) {
      throw const PublicFailure(PublicFailureCode.sourceSchema);
    }
    final markdown = document.markdown;
    final bodyTruncated =
        markdown.runes.length < document.markdown.runes.length;
    final evidence = _publicEvidence(
      source: document.evidence,
      coverage: result.coverage,
      snippet: markdown,
      complete: result.coverage.complete && !bodyTruncated,
    );
    final coverage = _publicCoverage(
      result.coverage,
      truncated: result.coverage.truncated || bodyTruncated,
      complete: result.coverage.complete && !bodyTruncated,
    );
    final cursors = _cursorPendingForRead(
      result.next,
      kind: 'read_campus_article',
      intent: intent,
      guardKind: _GuardKind.online,
      origin: result,
    );
    return _pending(
      status: bodyTruncated ? 'partial' : _publicStatus(result),
      data: {
        'article_ref': token,
        'content': markdown,
        'next_cursor': cursors.keys.firstOrNull,
        'coverage': coverage,
      },
      evidenceIds: [evidence.id],
      cursors: cursors,
      evidence: [evidence],
      publicSnapshots: [
        _PublicSnapshot(_GuardKind.online, issued.origin),
        _PublicSnapshot(_GuardKind.online, result),
      ],
    );
  }

  String? _issueCursor(
    PublicCursor? value, {
    required String kind,
    required String intent,
    required _GuardKind guardKind,
    required PublicQueryResult origin,
    required Map<String, _CursorRef> cursors,
  }) {
    if (value == null) return null;
    final token = _newToken('c_');
    cursors[token] = _CursorRef(
      cursor: value,
      kind: kind,
      intent: intent,
      guardKind: guardKind,
      origin: origin,
      expiry: _expiry(),
    );
    return token;
  }

  Map<String, _CursorRef> _cursorPendingForRead(
    PublicCursor? value, {
    required String kind,
    required String intent,
    required _GuardKind guardKind,
    required PublicQueryResult origin,
  }) {
    final cursors = <String, _CursorRef>{};
    _issueCursor(
      value,
      kind: kind,
      intent: intent,
      guardKind: guardKind,
      origin: origin,
      cursors: cursors,
    );
    return cursors;
  }

  Future<PublicCursor?> _resolveCursor(
    String? token, {
    required String kind,
    required String intent,
    required _GuardKind guardKind,
  }) async {
    if (token == null) return null;
    _prune();
    final issued = _cursors[token];
    if (issued == null ||
        issued.kind != kind ||
        issued.intent != intent ||
        issued.guardKind != guardKind) {
      throw const PublicFailure(PublicFailureCode.staleReference);
    }
    await _ensurePublicResult(issued.guardKind, issued.origin);
    return issued.cursor;
  }

  String _resolveTerm(String courseToken, String termToken) {
    _prune();
    final issued = _termRefs[termToken];
    if (issued == null || issued.courseToken != courseToken) {
      throw const PublicFailure(PublicFailureCode.staleReference);
    }
    return issued.code;
  }

  String? _termTokenForCode(
    String courseToken,
    String code,
    Map<String, _TermRef> pending,
  ) {
    for (final entry in [..._termRefs.entries, ...pending.entries]) {
      if (entry.value.courseToken == courseToken && entry.value.code == code) {
        return entry.key;
      }
    }
    final token = _newToken('t_');
    pending[token] = _TermRef(courseToken, code, _expiry());
    return token;
  }

  Map<String, Object?>? _courseMap(
    PublicCourseInfo? course, {
    required String courseToken,
    required Map<String, _TermRef> pendingTerms,
    int termStart = 0,
  }) {
    if (course == null) return null;
    final termRows = <Map<String, Object?>>[];
    for (final term in course.terms.skip(termStart).take(5)) {
      final token = _termTokenForCode(courseToken, term.code, pendingTerms);
      termRows.add({'term': token, 'label': term.label});
    }
    final nextStart = termStart + termRows.length;
    final hasMore = nextStart < course.terms.length;
    return {
      'title': course.title,
      'teacher': course.teacher,
      'score': course.score,
      'rating_count': course.ratingCount,
      'review_count': course.reviewCount,
      'terms': termRows,
      'terms_observed': course.terms.length,
      'terms_total': course.terms.length,
      'terms_returned': termRows.length,
      'term_start': termStart,
      'next_term_start': hasMore ? nextStart : null,
      'terms_truncated': hasMore,
    };
  }
}

const _calendarFilters = [
  'all',
  'course',
  'exam',
  'young',
  'personal',
  'planBlock',
];
const _taskFilters = [
  'open',
  'all',
  'active',
  'blocked',
  'completed',
  'cancelled',
];
const _campusColumns = [
  'teachNotice',
  'teachStudentService',
  'financeNotice',
  'financeBusiness',
  'financeProcess',
  'financeOperation',
  'financeFaq',
];
const _reviewSorts = [
  'upvote',
  'newest',
  'oldest',
  'scoreDescending',
  'scoreAscending',
];

ModelToolDefinition _tool(
  String name,
  String description,
  Map<String, Map<String, Object?>> properties, {
  List<String> required = const [],
}) => ModelToolDefinition(
  name: name,
  description: description,
  parameters: Map.unmodifiable({
    'type': 'object',
    'properties': Map.unmodifiable({
      for (final entry in properties.entries)
        entry.key: Map<String, Object?>.unmodifiable(entry.value),
    }),
    'required': List<String>.unmodifiable(required),
    'additionalProperties': false,
  }),
);

Map<String, Object?> _stringSchema({
  List<String>? enumValues,
  String? pattern,
  int? maxLength,
}) {
  final schema = <String, Object?>{'type': 'string'};
  if (enumValues != null) {
    schema['enum'] = List<String>.unmodifiable(enumValues);
  }
  if (pattern != null) schema['pattern'] = pattern;
  if (maxLength != null) schema['maxLength'] = maxLength;
  return Map.unmodifiable(schema);
}

Map<String, Object?> _intSchema({required int minimum, required int maximum}) =>
    Map.unmodifiable({
      'type': 'integer',
      'minimum': minimum,
      'maximum': maximum,
    });

Map<String, Object?> _boolSchema() => const {'type': 'boolean'};

Map<String, Object?> _localCoverage({
  required String scope,
  required int returned,
  required int? observed,
  required int? totalReported,
  required bool truncated,
  required bool complete,
}) => {
  'scope': scope,
  'returned': returned,
  'observed': observed,
  'totalReported': totalReported,
  'excluded': 0,
  'truncated': truncated,
  'complete': complete,
  'cached': false,
};

Map<String, Object?> _publicCoverage(
  PublicCoverage coverage, {
  bool? truncated,
  bool? complete,
}) => {
  'scope': coverage.scope,
  'returned': coverage.returned,
  'observed': coverage.observed,
  'totalReported': coverage.totalReported,
  'excluded': coverage.excluded,
  'truncated': truncated ?? coverage.truncated,
  'complete': complete ?? coverage.complete,
  'cached': coverage.cached,
};

String _publicStatus(PublicQueryResult result) {
  if (result.coverage.returned == 0 &&
      result.coverage.complete &&
      result.next == null) {
    return 'empty';
  }
  if (!result.coverage.complete ||
      result.coverage.truncated ||
      result.next != null) {
    return 'partial';
  }
  return 'success';
}

String _formatDay(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String _beijingDateTime(DateTime value) {
  final local = value.toUtc().add(const Duration(hours: 8));
  final fraction = local.millisecond * 1000 + local.microsecond;
  var fractionText = '';
  if (fraction != 0) {
    final digits = fraction
        .toString()
        .padLeft(6, '0')
        .replaceFirst(RegExp(r'0+$'), '');
    fractionText = '.$digits';
  }
  return '${_formatDay(local)}T'
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}:'
      '${local.second.toString().padLeft(2, '0')}'
      '$fractionText+08:00';
}

String _clipRunes(String value, int maximum) =>
    String.fromCharCodes(value.runes.take(maximum));

String _randomHex(String prefix, int bytes) {
  final random = Random.secure();
  return prefix +
      List.generate(
        bytes,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
}

String _intent(List<Object?> parts) => jsonEncode(parts);

String _canonicalKeywords(String value, {required bool allowEmpty}) {
  final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if ((!allowEmpty && normalized.isEmpty) ||
      normalized.runes.length > 80 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(normalized)) {
    _invalid();
  }
  AgentText.requireSafe(normalized, maxCharacters: 512);
  return normalized;
}

String _publicKeywords(Map<String, Object?> args, String key) =>
    _canonicalKeywords(_stringArg(args, key), allowEmpty: false);

String _localKeywords(
  Map<String, Object?> args,
  String key, {
  required String fallback,
}) {
  if (!args.containsKey(key)) return fallback;
  final value = args[key];
  if (value is! String) _invalid();
  return _canonicalKeywords(value, allowEmpty: true);
}

String? _optionalText(
  Map<String, Object?> args,
  String key, {
  required int maxRunes,
}) {
  if (!args.containsKey(key)) return null;
  final raw = args[key];
  if (raw is! String) _invalid();
  final normalized = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty) return null;
  if (normalized.runes.length > maxRunes ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(normalized)) {
    _invalid();
  }
  AgentText.requireSafe(normalized, maxCharacters: 512);
  return normalized;
}

DateTime _dateArg(Map<String, Object?> args, String key) {
  final value = _stringArg(args, key);
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (match == null) _invalid();
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  if (year > 9999) _invalid();
  final result = year < 100
      ? DateTime.utc(
          year + 400,
          month,
          day,
        ).subtract(const Duration(days: 146097))
      : DateTime.utc(year, month, day);
  if (_formatDay(result) != value) _invalid();
  AgentText.requireSafe(value, maxCharacters: 10);
  return result;
}

String _stringArg(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value is! String || value.isEmpty) _invalid();
  AgentText.requireSafe(value, maxCharacters: 512);
  return value;
}

String? _optionalString(Map<String, Object?> args, String key) {
  if (!args.containsKey(key)) return null;
  final value = args[key];
  if (value is! String || value.isEmpty) _invalid();
  AgentText.requireSafe(value, maxCharacters: 512);
  return value;
}

String _enumArg(
  Map<String, Object?> args,
  String key,
  List<String> values, {
  String? fallback,
}) {
  final value = _optionalEnumArg(args, key, values);
  final result = value ?? fallback;
  if (result == null) _invalid();
  return result;
}

String? _optionalEnumArg(
  Map<String, Object?> args,
  String key,
  List<String> values,
) {
  final value = _optionalString(args, key);
  if (value == null) return null;
  if (!values.contains(value)) _invalid();
  return value;
}

bool _boolArg(Map<String, Object?> args, String key, {required bool fallback}) {
  if (!args.containsKey(key)) return fallback;
  final value = args[key];
  if (value is! bool) _invalid();
  return value;
}

int _intArg(
  Map<String, Object?> args,
  String key, {
  required int fallback,
  required int minimum,
  required int maximum,
}) {
  if (!args.containsKey(key)) return fallback;
  final value = args[key];
  if (value is! int || value < minimum || value > maximum) _invalid();
  return value;
}

Never _invalid() => throw const AgentFailure(AgentFailureCode.invalidInput);

bool _matchesCalendarFilter(CalendarOccurrence item, String filter) =>
    filter == 'all' || item.reference.identity.kind.name == filter;

Map<String, Object?> _deepFreezeMap(Map<String, Object?> source) =>
    Map.unmodifiable({
      for (final entry in source.entries) entry.key: _freezeValue(entry.value),
    });

Object? _freezeValue(Object? value) => switch (value) {
  Map<String, Object?> map => _deepFreezeMap(map),
  List list => List.unmodifiable(list.map(_freezeValue)),
  _ => value,
};

AgentFailure _calendarGuardFailure(CalendarFailure failure) =>
    switch (failure.code) {
      CalendarFailureCode.staleReference ||
      CalendarFailureCode.ownershipLost ||
      CalendarFailureCode.maintenance => const AgentFailure(
        AgentFailureCode.staleContext,
      ),
      CalendarFailureCode.busy => const AgentFailure(AgentFailureCode.busy),
      CalendarFailureCode.limitExceeded => const AgentFailure(
        AgentFailureCode.resourceLimit,
      ),
      CalendarFailureCode.storageFailed => const AgentFailure(
        AgentFailureCode.storageFailed,
      ),
      CalendarFailureCode.closed => const AgentFailure(AgentFailureCode.closed),
      _ => const AgentFailure(AgentFailureCode.invalidInput),
    };

AgentToolResult _calendarFailureResult(CalendarFailure failure) {
  final mapped = switch (failure.code) {
    CalendarFailureCode.busy => ('busy', 'busy'),
    CalendarFailureCode.staleReference ||
    CalendarFailureCode.ownershipLost ||
    CalendarFailureCode.maintenance => ('stale', 'staleReference'),
    CalendarFailureCode.limitExceeded => ('resourceLimit', 'resourceLimit'),
    CalendarFailureCode.storageFailed => ('failure', 'storageFailed'),
    CalendarFailureCode.closed => ('unavailable', 'closed'),
    _ => ('invalidRequest', 'invalidRequest'),
  };
  return _failureResult(mapped.$1, mapped.$2);
}

AgentToolResult _publicFailureResult(PublicFailure failure) {
  final mapped = switch (failure.code) {
    PublicFailureCode.invalidRequest => ('invalidRequest', 'invalidRequest'),
    PublicFailureCode.busy => ('busy', 'busy'),
    PublicFailureCode.consentRequired => ('consentRequired', 'consentRequired'),
    PublicFailureCode.cancelled => ('cancelled', 'cancelled'),
    PublicFailureCode.staleReference => ('stale', 'staleReference'),
    PublicFailureCode.unavailable => ('unavailable', 'unavailable'),
    PublicFailureCode.accessRestricted => (
      'accessRestricted',
      'accessRestricted',
    ),
    PublicFailureCode.campusOnly => ('accessRestricted', 'campusOnly'),
    PublicFailureCode.networkFailed => ('failure', 'networkFailed'),
    PublicFailureCode.sourceSchema => ('failure', 'sourceSchema'),
    PublicFailureCode.unsafeTarget => ('failure', 'unsafeTarget'),
    PublicFailureCode.resourceLimit => ('resourceLimit', 'resourceLimit'),
    PublicFailureCode.storageFailed => ('failure', 'storageFailed'),
    PublicFailureCode.cleanupPending => ('failure', 'cleanupPending'),
    PublicFailureCode.closed => ('unavailable', 'closed'),
  };
  return _failureResult(mapped.$1, mapped.$2);
}

AgentToolResult _agentFailureResult(AgentFailure failure) {
  final mapped = switch (failure.code) {
    AgentFailureCode.invalidInput => ('invalidRequest', 'invalidRequest'),
    AgentFailureCode.secretDetected => ('secretDetected', 'secretDetected'),
    AgentFailureCode.consentRequired => ('consentRequired', 'consentRequired'),
    AgentFailureCode.busy => ('busy', 'busy'),
    AgentFailureCode.staleContext ||
    AgentFailureCode.ownershipLost => ('stale', 'staleReference'),
    AgentFailureCode.resourceLimit ||
    AgentFailureCode.rateLimited => ('resourceLimit', 'resourceLimit'),
    AgentFailureCode.cancelled => ('cancelled', 'cancelled'),
    AgentFailureCode.closed ||
    AgentFailureCode.toolUnavailable => ('unavailable', 'unavailable'),
    AgentFailureCode.networkFailed ||
    AgentFailureCode.timeout => ('failure', 'networkFailed'),
    AgentFailureCode.storageFailed ||
    AgentFailureCode.protectionFailed => ('failure', 'storageFailed'),
    AgentFailureCode.protocol ||
    AgentFailureCode.redirectRejected => ('failure', 'sourceSchema'),
    AgentFailureCode.unauthorized ||
    AgentFailureCode.forbidden => ('accessRestricted', 'accessRestricted'),
    AgentFailureCode.keyRequired ||
    AgentFailureCode.modelRequired => ('unavailable', 'unavailable'),
    AgentFailureCode.maintenance => ('busy', 'busy'),
    AgentFailureCode.imageRejected => ('unavailable', 'unavailable'),
  };
  return _failureResult(mapped.$1, mapped.$2);
}

AgentToolResult _failureResult(String status, String failure) =>
    !agentToolStatuses.contains(status) || !_failureCodes.contains(failure)
    ? throw const AgentFailure(AgentFailureCode.invalidInput)
    : AgentToolResult(status: status, failure: failure);

AgentToolResult _safeToolResult({
  required String status,
  String? failure,
  Map<String, Object?> data = const {},
  List<String> evidenceIds = const [],
}) {
  if (!agentToolStatuses.contains(status) ||
      (failure != null && !_failureCodes.contains(failure))) {
    throw const AgentFailure(AgentFailureCode.invalidInput);
  }
  final frozen = _deepFreezeMap(data);
  final result = AgentToolResult(
    status: status,
    failure: failure,
    data: frozen,
    evidenceIds: evidenceIds,
  );
  final encoded = jsonEncode(result.toMap());
  AgentText.requireSafe(encoded);
  if (utf8.encode(encoded).length > _maxResultBytes) {
    throw const AgentFailure(AgentFailureCode.resourceLimit);
  }
  return result;
}

int _encodedToolResultBytes(
  AgentToolResult result,
  List<AgentEvidence> evidence,
) {
  final value = result.toMap()
    ..['evidence_metadata'] = [
      for (final item in evidence)
        {
          'id': item.id,
          'provider': item.provider,
          'title': item.title,
          'publishedOn': item.publishedOn,
          'updatedOn': item.updatedOn,
          'observedAtUtc': item.observedAtUtc.toIso8601String(),
          'revision': item.revision,
          'sourceVersion': item.sourceVersion,
          'locator': item.locator,
          'scope': item.scope,
          'complete': item.complete,
          'applicability': item.applicability,
        },
    ];
  final encoded = jsonEncode(value);
  AgentText.requireSafe(encoded);
  return utf8.encode(encoded).length;
}

AgentEvidence _validatedEvidence({
  required String id,
  required String provider,
  required String title,
  required DateTime observedAtUtc,
  required String scope,
  required bool complete,
  String? articleUrl,
  String? materialUrl,
  String? publishedOn,
  String? updatedOn,
  String? revision,
  String? locator,
  String? sourceVersion,
  String snippet = '',
  CalendarReference? eventReference,
  TaskReference? taskReference,
}) {
  final value = AgentEvidence(
    id: id,
    provider: provider,
    title: title,
    observedAtUtc: observedAtUtc.toUtc(),
    scope: scope,
    complete: complete,
    articleUrl: articleUrl,
    materialUrl: materialUrl,
    publishedOn: publishedOn,
    updatedOn: updatedOn,
    revision: revision,
    locator: locator,
    sourceVersion: sourceVersion,
    snippet: snippet,
    applicability: 'unknown',
    eventReference: eventReference,
    taskReference: taskReference,
  );
  agentEvidenceToMap(value);
  return value;
}

String _strictJsonString(String source, int start, int end) =>
    jsonDecode(source.substring(start, end)) as String;

Map<String, Object?> _parseArguments(String source, String name) {
  if (source.length > 4096) _invalid();
  Object? decoded;
  try {
    decoded = _StrictJsonParser(source).parse();
  } on AgentFailure {
    rethrow;
  } on Object {
    _invalid();
  }
  final parsed = decoded;
  if (parsed is! Map<String, Object?>) _invalid();
  final allowed = _toolArgumentFields[name];
  final required = _toolRequiredFields[name] ?? const <String>{};
  if (allowed == null ||
      parsed.keys.any((key) => !allowed.contains(key)) ||
      !required.every(parsed.containsKey)) {
    _invalid();
  }
  return parsed;
}

const _toolArgumentFields = <String, Set<String>>{
  'query_agenda': {
    'first_day',
    'end_day_exclusive',
    'filter',
    'include_hidden',
    'include_skipped',
    'limit',
  },
  'read_event': {'event_ref'},
  'query_tasks': {'filter', 'keywords', 'limit'},
  'read_task': {'task_ref'},
  'inspect_conflicts': {'first_day', 'end_day_exclusive', 'filter', 'limit'},
  'search_knowledge': {'keywords', 'provider', 'topic', 'limit', 'cursor'},
  'read_knowledge': {
    'material_ref',
    'section_start',
    'max_characters',
    'cursor',
  },
  'search_courses': {'keywords', 'limit', 'cursor'},
  'read_course': {'course_ref', 'term_start'},
  'read_reviews': {'course_ref', 'term', 'sort', 'limit', 'cursor'},
  'browse_campus': {'column', 'keywords', 'limit', 'cursor'},
  'read_campus_article': {
    'article_ref',
    'section_start',
    'max_characters',
    'cursor',
  },
};

const _toolRequiredFields = <String, Set<String>>{
  'query_agenda': {'first_day', 'end_day_exclusive'},
  'read_event': {'event_ref'},
  'read_task': {'task_ref'},
  'inspect_conflicts': {'first_day', 'end_day_exclusive'},
  'search_knowledge': {'keywords'},
  'read_knowledge': {'material_ref'},
  'search_courses': {'keywords'},
  'read_course': {'course_ref'},
  'read_reviews': {'course_ref'},
  'browse_campus': {'column'},
  'read_campus_article': {'article_ref'},
};

/// Reuses the closed JSON parser for the bounded action adapter. No duplicate
/// keys or deeply nested model arguments are accepted.
Map<String, Object?> parseAgentActionArguments(String source) {
  AgentText.requireSafe(source, maxCharacters: 16384);
  final value = _StrictJsonParser(source, maxNodes: 768).parse();
  if (value is! Map<String, Object?>) {
    throw const AgentFailure(AgentFailureCode.invalidInput);
  }
  return value;
}

final class _StrictJsonParser {
  _StrictJsonParser(this.source, {this.maxNodes = 256});
  final String source;
  final int maxNodes;
  int _offset = 0;
  int _nodes = 0;

  Object? parse() {
    _space();
    final value = _value(0);
    _space();
    if (_offset != source.length) _invalid();
    return value;
  }

  Object? _value(int depth) {
    if (depth > 8 || ++_nodes > maxNodes) _invalid();
    _space();
    if (_offset >= source.length) _invalid();
    return switch (source.codeUnitAt(_offset)) {
      0x7B => _object(depth + 1),
      0x5B => _array(depth + 1),
      0x22 => _string(),
      0x74 => _literal('true', true),
      0x66 => _literal('false', false),
      0x6E => _literal('null', null),
      0x2D || >= 0x30 && <= 0x39 => _number(),
      _ => _invalid(),
    };
  }

  Map<String, Object?> _object(int depth) {
    _offset++;
    _space();
    final result = <String, Object?>{};
    if (_take(0x7D)) return result;
    while (true) {
      _space();
      if (_offset >= source.length || source.codeUnitAt(_offset) != 0x22) {
        _invalid();
      }
      final key = _string();
      if (result.containsKey(key)) _invalid();
      _space();
      if (!_take(0x3A)) _invalid();
      result[key] = _value(depth);
      _space();
      if (_take(0x7D)) return result;
      if (!_take(0x2C)) _invalid();
    }
  }

  List<Object?> _array(int depth) {
    _offset++;
    _space();
    final result = <Object?>[];
    if (_take(0x5D)) return result;
    while (true) {
      result.add(_value(depth));
      _space();
      if (_take(0x5D)) return result;
      if (!_take(0x2C)) _invalid();
    }
  }

  String _string() {
    final start = _offset;
    _offset++;
    while (_offset < source.length) {
      final value = source.codeUnitAt(_offset++);
      if (value == 0x22) return _strictJsonString(source, start, _offset);
      if (value < 0x20) _invalid();
      if (value == 0x5C) {
        if (_offset >= source.length) _invalid();
        final escaped = source.codeUnitAt(_offset++);
        if (escaped == 0x75) {
          if (_offset + 4 > source.length ||
              !RegExp(
                r'^[0-9a-fA-F]{4}$',
              ).hasMatch(source.substring(_offset, _offset + 4))) {
            _invalid();
          }
          _offset += 4;
        } else if (![
          0x22,
          0x5C,
          0x2F,
          0x62,
          0x66,
          0x6E,
          0x72,
          0x74,
        ].contains(escaped)) {
          _invalid();
        }
      }
    }
    _invalid();
  }

  Object _number() {
    final rest = source.substring(_offset);
    final match = RegExp(
      r'^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?',
    ).firstMatch(rest);
    if (match == null || match.group(0)!.length > 24) _invalid();
    final value = match.group(0)!;
    _offset += value.length;
    if (value.contains('.') || value.contains('e') || value.contains('E')) {
      return double.parse(value);
    }
    final integer = int.tryParse(value);
    if (integer == null) _invalid();
    return integer;
  }

  Object? _literal(String text, Object? value) {
    if (!source.startsWith(text, _offset)) _invalid();
    _offset += text.length;
    return value;
  }

  bool _take(int codeUnit) {
    if (_offset >= source.length || source.codeUnitAt(_offset) != codeUnit) {
      return false;
    }
    _offset++;
    return true;
  }

  void _space() {
    while (_offset < source.length &&
        const [0x20, 0x09, 0x0A, 0x0D].contains(source.codeUnitAt(_offset))) {
      _offset++;
    }
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
