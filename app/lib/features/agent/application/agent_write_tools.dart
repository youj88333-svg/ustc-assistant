import 'package:ustc_assistant_app/features/calendar/application/recurrence_service.dart';
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';
import 'package:ustc_assistant_app/features/tasks/domain/plan_block.dart';
import 'package:ustc_assistant_app/features/tasks/domain/task.dart';
import 'package:ustc_assistant_app/features/schedule/application/effective_event_repository.dart';
import 'package:ustc_assistant_app/features/schedule/application/overlay_service.dart';

import '../domain/agent_permission_policy.dart';
import '../domain/agent_tool.dart';
import '../domain/agent_write_gateway.dart';
import '../domain/agent_write_proposal.dart';
import 'agent_permission_policy_service.dart';
import 'agent_write_tool.dart';
import 'run_reference_store.dart';
import 'write_argument_reader.dart';

const Set<String> _personalTypeValues = {
  'personal', 'entertainment', 'meal', 'campus_affair', 'travel', 'study',
};
const Set<String> _importanceValues = {'low', 'normal', 'high', 'critical'};

/// 把 ISO-8601 字符串解析为本地时间（模型传带 +08:00 偏移）。
DateTime _parseDateTime(String value) => DateTime.parse(value);

String _fmtRange(PersonalEvent event) => event.allDay
    ? '${event.startDate!.toIso8601String().substring(0, 10)} 至 '
          '${event.endDateExclusive!.toIso8601String().substring(0, 10)}'
    : '${event.startAt!.toIso8601String()} 至 ${event.endAt!.toIso8601String()}';

String _fmtTaskRange(DateTime? start, DateTime? end) =>
    '${start?.toIso8601String()} 至 ${end?.toIso8601String()}';

/// 定时事件的时间范围（“HH:MM-HH:MM”）。
String _fmtTimeRange(DateTime start, DateTime end) {
  String two(int n) => n.toString().padLeft(2, '0');
  final d = '${start.year}-${two(start.month)}-${two(start.day)}';
  return '$d ${two(start.hour)}:${two(start.minute)}-${two(end.hour)}:${two(end.minute)}';
}

/// 事件的展示行：标题 + 当前时间（+ 地点）。
List<String> _eventTargetLines(EventWriteSnapshot snapshot) {
  final lines = <String>[
    '目标：${snapshot.title}',
    if (snapshot.allDay)
      '当前时间：${snapshot.startDate!.toIso8601String().substring(0, 10)} 至 '
          '${snapshot.endDateExclusive!.toIso8601String().substring(0, 10)}'
    else
      '当前时间：${_fmtTimeRange(snapshot.startAt!, snapshot.endAt!)}',
    if (snapshot.location != null && snapshot.location!.isNotEmpty)
      '地点：${snapshot.location}',
  ];
  return lines;
}

/// 事件/任务/执行块摘要文本（进入预览/日志，不含任何 DB id）。
String _eventSummary(EventWriteSnapshot snapshot) {
  if (snapshot.allDay) {
    return '${snapshot.title} '
        '（${snapshot.startDate!.toIso8601String().substring(0, 10)} 至 '
        '${snapshot.endDateExclusive!.toIso8601String().substring(0, 10)}）';
  }
  return '${snapshot.title} / ${_fmtTimeRange(snapshot.startAt!, snapshot.endAt!)}';
}

/// 关系参与方的展示摘要（event 用快照，plan_block 用执行块行）。
Future<String> _relationParticipantLabel(AgentWriteGateway gateway, String kind, String id) async {
  if (kind == 'event') {
    return _eventSummary(await gateway.eventSnapshot(id));
  }
  if (kind == 'plan_block') {
    final block = await gateway.planBlockById(id);
    final title = (block.title != null && block.title!.isNotEmpty) ? block.title! : '执行块';
    return '$title / ${_fmtTimeRange(block.startAt, block.endAt)}';
  }
  throw const FormatException('unsupported relation kind');
}

/// 新建个人日程。
class CreateEventTool extends AgentWriteTool {
  CreateEventTool({required super.gateway, required super.policy, required super.confirmationStore});

  @override
  String get name => 'create_event';
  @override
  String get description =>
      '新建一个个人日程事件。课程/考试/二课等来源事件不可新建，用 create_user_overlay 标注。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'title': {'type': 'string'},
      'start_at': {'type': 'string', 'description': '开始时间 ISO-8601，如 2026-08-01T15:00:00+08:00'},
      'end_at': {'type': 'string', 'description': '结束时间 ISO-8601'},
      'all_day': {'type': 'boolean', 'description': '全天事件传 true 并用 start_date/end_date_exclusive'},
      'start_date': {'type': 'string', 'description': '全天事件开始日期 YYYY-MM-DD'},
      'end_date_exclusive': {'type': 'string', 'description': '全天事件结束日期（不含）YYYY-MM-DD'},
      'location': {'type': 'string'},
      'type': {'type': 'string', 'enum': ['personal', 'entertainment', 'meal', 'campus_affair', 'travel', 'study']},
      'importance': {'type': 'string', 'enum': ['low', 'normal', 'high', 'critical']},
      'description': {'type': 'string'},
      'tags': {'type': 'array', 'items': {'type': 'string'}},
      'reminder_offsets_minutes': {'type': 'array', 'items': {'type': 'integer'}},
    },
    'required': ['title'],
  };

  @override
  String get actionType => 'create_event';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'event';
  @override
  String get operationLabel => '新建日程';

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final r = WriteArgumentReader(a, const {
      'title', 'start_at', 'end_at', 'all_day', 'start_date', 'end_date_exclusive',
      'location', 'type', 'importance', 'description', 'tags', 'reminder_offsets_minutes',
    });
    r.rejectUnknownKeys();
    final title = r.requiredString('title');
    final allDay = r.optionalBool('all_day') ?? false;
    final typeValue = r.optionalEnum('type', _personalTypeValues) ?? 'personal';
    final type = switch (typeValue) {
      'entertainment' => PersonalEventType.entertainment,
      'meal' => PersonalEventType.meal,
      'campus_affair' => PersonalEventType.campusAffair,
      'travel' => PersonalEventType.travel,
      'study' => PersonalEventType.study,
      _ => PersonalEventType.personal,
    };
    final importance = r.optionalEnum('importance', _importanceValues) ?? 'normal';
    final tags = r.optionalStringList('tags') ?? const <String>[];
    final offsets = r.contains('reminder_offsets_minutes')
        ? r.requiredIntList('reminder_offsets_minutes')
        : null;
    final location = r.optionalString('location');
    final description = r.optionalString('description');

    // 全天与定时字段集互斥，缺一不可。
    if (allDay) {
      if (!r.contains('start_date') || !r.contains('end_date_exclusive') ||
          r.contains('start_at') || r.contains('end_at')) {
        throw const FormatException('invalid all-day field set');
      }
    } else if (!r.contains('start_at') || !r.contains('end_at') ||
        r.contains('start_date') || r.contains('end_date_exclusive')) {
      throw const FormatException('invalid timed field set');
    }

    final PersonalEvent event;
    if (allDay) {
      final startDate = _parseDateTime(r.requiredString('start_date'));
      final endDate = _parseDateTime(r.requiredString('end_date_exclusive'));
      event = PersonalEvent.allDay(
        title: title,
        startDate: startDate,
        endDateExclusive: endDate,
        description: description,
        locationName: location,
        type: type,
        importance: importance,
        tags: tags,
      );
    } else {
      final startAt = _parseDateTime(r.requiredString('start_at'));
      final endAt = _parseDateTime(r.requiredString('end_at'));
      event = PersonalEvent.timed(
        title: title,
        startAt: startAt,
        endAt: endAt,
        description: description,
        locationName: location,
        type: type,
        importance: importance,
        tags: tags,
      );
    }

    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: [
        '标题：$title',
        '时间：${_fmtRange(event)}',
        if (location != null && location.isNotEmpty) '地点：$location',
      ],
      commitParams: {'event': event, 'reminderOffsetsMinutes': offsets},
      safeLogSummary: '新建日程 $title ${_fmtRange(event)}',
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final event = proposal.commitParams['event'] as PersonalEvent;
    final offsets = proposal.commitParams['reminderOffsetsMinutes'] as List<int>?;
    await gateway.createEvent(event, reminderOffsetsMinutes: offsets);
    return AgentToolResult(payload: {'result': 'created_event', 'title': event.title});
  }
}

/// 新建任务。
class CreateTaskTool extends AgentWriteTool {
  CreateTaskTool({required super.gateway, required super.policy, required super.confirmationStore});

  @override
  String get name => 'create_task';
  @override
  String get description => '新建一个任务（作业/复习/事务等），可带截止时间和预计工时。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'title': {'type': 'string'},
      'description': {'type': 'string'},
      'deadline_at': {'type': 'string', 'description': '截止时间 ISO-8601，可空'},
      'estimated_minutes': {'type': 'integer', 'description': '预计工时（分钟），必须为正'},
      'importance': {'type': 'string', 'enum': ['low', 'normal', 'high', 'critical']},
      'tags': {'type': 'array', 'items': {'type': 'string'}},
    },
    'required': ['title'],
  };

  @override
  String get actionType => 'create_task';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'task';
  @override
  String get operationLabel => '新建任务';

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final r = WriteArgumentReader(a, const {
      'title', 'description', 'deadline_at', 'estimated_minutes', 'importance', 'tags',
    });
    r.rejectUnknownKeys();
    final title = r.requiredString('title');
    final deadlineAt = r.contains('deadline_at')
        ? _parseDateTime(r.requiredString('deadline_at'))
        : null;
    final estimatedMinutes = r.optionalInt('estimated_minutes');
    if (estimatedMinutes != null && estimatedMinutes <= 0) {
      throw const FormatException('estimated_minutes must be positive');
    }
    final importanceValue = r.optionalEnum('importance', _importanceValues) ?? 'normal';
    final importance = switch (importanceValue) {
      'low' => TaskImportance.low,
      'high' => TaskImportance.high,
      'critical' => TaskImportance.critical,
      _ => TaskImportance.normal,
    };
    final tags = r.optionalStringList('tags') ?? const <String>[];

    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: [
        '标题：$title',
        if (deadlineAt != null) '截止：${deadlineAt.toIso8601String()}',
        if (estimatedMinutes != null) '预计：$estimatedMinutes 分钟',
      ],
      commitParams: {
        'title': title,
        'description': r.optionalString('description'),
        'deadlineAt': deadlineAt,
        'estimatedMinutes': estimatedMinutes,
        'tags': tags,
        'importance': importance,
      },
      safeLogSummary: '新建任务 $title',
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final params = proposal.commitParams;
    await gateway.createTask(
      title: params['title'] as String,
      description: params['description'] as String?,
      deadlineAt: params['deadlineAt'] as DateTime?,
      estimatedMinutes: params['estimatedMinutes'] as int?,
      tags: (params['tags'] as List<String>),
      importance: params['importance'] as TaskImportance,
    );
    return AgentToolResult(payload: {'result': 'created_task', 'title': params['title']});
  }
}

/// 为已有任务安排一个执行时间段（PlanBlock）。
class PlanTaskTool extends AgentWriteTool {
  PlanTaskTool({required super.gateway, required super.policy, required super.confirmationStore});

  @override
  String get name => 'plan_task';
  @override
  String get description => '为一个已存在的任务安排一个执行时间段（PlanBlock）。ref_task 来自之前的任务查询。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'ref_task': {'type': 'string', 'description': '任务的 ref_* 引用'},
      'start_at': {'type': 'string'},
      'end_at': {'type': 'string'},
      'title': {'type': 'string', 'description': '可空，块标题'},
      'status': {'type': 'string', 'enum': ['accepted', 'suggested'], 'default': 'accepted'},
    },
    'required': ['ref_task', 'start_at', 'end_at'],
  };

  @override
  String get actionType => 'plan_task';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'plan_block';
  @override
  String get operationLabel => '安排任务时间段';

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final r = WriteArgumentReader(a, const {'ref_task', 'start_at', 'end_at', 'title', 'status'});
    r.rejectUnknownKeys();
    final ref = r.requiredString('ref_task');
    final taskId = ctx.references.resolve(ref: ref, kind: 'task');
    if (taskId == null) throw const FormatException('unknown task ref');
    final startAt = _parseDateTime(r.requiredString('start_at'));
    final endAt = _parseDateTime(r.requiredString('end_at'));
    if (!endAt.isAfter(startAt)) throw const FormatException('end must be after start');
    final title = r.contains('title') ? r.requiredString('title') : null;
    final statusValue = r.optionalEnum('status', const {'accepted', 'suggested'}) ?? 'accepted';
    final status = statusValue == 'suggested' ? PlanBlockStatus.suggested : PlanBlockStatus.accepted;

    // 目标存在性 preflight：任务不存在则不产生可批准的提案。
    final task = await gateway.taskById(taskId);

    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: [
        '目标：${task.title}',
        if (title != null && title.isNotEmpty) '标题：$title',
        '时间：$_fmtTaskRange(startAt, endAt)',
      ],
      commitParams: {'taskId': taskId, 'startAt': startAt, 'endAt': endAt, 'title': title, 'status': status},
      safeLogSummary: '安排任务时间段 ${task.title}（${_fmtTaskRange(startAt, endAt)}）',
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    final taskId = p['taskId'] as String;
    // TOCTOU 守卫：提案后任务可能已被删除，重查目标存在性再写，避免悬挂执行块。
    try {
      await gateway.taskById(taskId);
    } on Object {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'target_not_found',
        payload: {'guidance': '该任务已不存在，无法为该任务安排时间段。'},
      );
    }
    await gateway.planTask(
      taskId: taskId,
      startAt: p['startAt'] as DateTime,
      endAt: p['endAt'] as DateTime,
      title: p['title'] as String?,
      status: p['status'] as PlanBlockStatus,
    );
    return AgentToolResult(payload: {'result': 'planned_task', 'start_at': (p['startAt'] as DateTime).toIso8601String()});
  }
}

/// 修改/删除已有日程。
class UpdateEventTool extends AgentWriteTool {
  UpdateEventTool({required super.gateway, required super.policy, required super.confirmationStore});

  @override
  String get name => 'update_event';
  @override
  String get description =>
      '修改或删除一个个人日程（标题/时间/地点/状态/删除）。课程/考试/二课事件不可改，请用 create_user_overlay。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'ref_event': {'type': 'string', 'description': '来自 get_schedule 的 ref_*'},
      'scope': {'type': 'string', 'enum': ['only_this', 'whole_series'], 'default': 'only_this',
          'description': '重复系列编辑范围；非重复事件忽略此字段'},
      'title': {'type': 'string'},
      'start_at': {'type': 'string'},
      'end_at': {'type': 'string'},
      'all_day': {'type': 'boolean'},
      'start_date': {'type': 'string'},
      'end_date_exclusive': {'type': 'string'},
      'location': {'type': 'string'},
      'type': {'type': 'string', 'enum': ['personal', 'entertainment', 'meal', 'campus_affair', 'travel', 'study']},
      'importance': {'type': 'string', 'enum': ['low', 'normal', 'high', 'critical']},
      'description': {'type': 'string'},
      'tags': {'type': 'array', 'items': {'type': 'string'}},
      'status': {'type': 'string', 'enum': ['cancelled', 'completed', 'skipped']},
      'delete': {'type': 'boolean'},
    },
    'required': ['ref_event'],
  };

  @override
  String get actionType => 'update_event';
  @override
  RiskLevel get riskLevel => RiskLevel.high;
  @override
  String get targetType => 'event';
  @override
  String get operationLabel => '修改/删除日程';

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final r = WriteArgumentReader(a, const {
      'ref_event', 'scope', 'title', 'start_at', 'end_at', 'all_day', 'start_date',
      'end_date_exclusive', 'location', 'type', 'importance', 'description', 'tags',
      'status', 'delete',
    });
    r.rejectUnknownKeys();
    final ref = r.requiredString('ref_event');
    final eventId = ctx.references.resolve(ref: ref, kind: 'event');
    if (eventId == null) throw const FormatException('unknown event ref');
    final scope = r.optionalEnum('scope', const {'only_this', 'whole_series'}) ?? 'only_this';
    final status = r.optionalEnum('status', const {'cancelled', 'completed', 'skipped'});
    final delete = r.optionalBool('delete') ?? false;

    final typeValue = r.optionalEnum('type', _personalTypeValues);
    final type = switch (typeValue) {
      'entertainment' => PersonalEventType.entertainment,
      'meal' => PersonalEventType.meal,
      'campus_affair' => PersonalEventType.campusAffair,
      'travel' => PersonalEventType.travel,
      'study' => PersonalEventType.study,
      _ => null, // 未提供 type：保留当前事件的类型。
    };
    final importance = r.optionalEnum('importance', _importanceValues);

    const fieldEditKeys = {
      'title', 'start_at', 'end_at', 'all_day', 'start_date', 'end_date_exclusive',
      'location', 'type', 'importance', 'description', 'tags',
    };
    final hasFieldEdits = fieldEditKeys.any(r.contains);

    // 时间对的起止必须成对提供，不允许只给一端。
    if (r.contains('start_at') != r.contains('end_at')) {
      throw const FormatException('start_at and end_at must be provided together');
    }

    // delete / status / 字段编辑三模式互斥。
    if (delete && (status != null || hasFieldEdits)) {
      throw const FormatException('delete cannot be combined with status or field edits');
    }
    if (status != null && hasFieldEdits) {
      throw const FormatException('status change cannot be combined with field edits');
    }
    // 拒绝零改动。
    if (!delete && status == null && !hasFieldEdits) {
      throw const FormatException('no fields to update');
    }

    final fields = <String, Object?>{
      if (r.contains('title')) 'title': r.requiredString('title'),
      if (r.contains('start_at')) 'start_at': _parseDateTime(r.requiredString('start_at')),
      if (r.contains('end_at')) 'end_at': _parseDateTime(r.requiredString('end_at')),
      if (r.contains('all_day')) 'all_day': r.optionalBool('all_day')!,
      if (r.contains('start_date')) 'start_date': _parseDateTime(r.requiredString('start_date')),
      if (r.contains('end_date_exclusive')) 'end_date_exclusive': _parseDateTime(r.requiredString('end_date_exclusive')),
      if (r.contains('location')) 'location': r.optionalString('location'),
      'type': ?type,
      'importance': ?importance,
      if (r.contains('description')) 'description': r.optionalString('description'),
      if (r.contains('tags')) 'tags': r.optionalStringList('tags')!,
    };

    // 目标快照 preflight：账户内的目标不存在/非个人来源时不产生可批准提案。
    final snapshot = await gateway.eventSnapshot(eventId);
    if (!snapshot.isPersonal) {
      throw const FormatException('source event cannot be edited with update_event');
    }

    final lines = <String>[
      ..._eventTargetLines(snapshot),
    ];
    if (delete) {
      lines.add('变更：删除该日程（软删除，可从管理页恢复）');
    } else if (status != null) {
      lines.add('变更：状态改为 $status');
    } else {
      if (r.contains('title')) lines.add('变更：标题改为 ${r.requiredString('title')}');
      if (r.contains('start_at') || r.contains('end_at')) lines.add('变更：时间有改动');
      lines.add(scope == 'whole_series' ? '影响：整个重复系列' : '影响：仅本次');
    }

    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: lines,
      commitParams: {'eventId': eventId, 'scope': scope, 'fields': fields, 'status': status, 'delete': delete, 'snapshot': snapshot},
      safeLogSummary: delete
          ? '删除日程 ${_eventSummary(snapshot)}'
          : (status != null ? '修改日程状态 $status（${_eventSummary(snapshot)}）' : '修改日程 ${_eventSummary(snapshot)}'),
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    final eventId = p['eventId'] as String;
    final scope = p['scope'] as String;
    final fields = p['fields'] as Map<String, Object?>;
    final status = p['status'] as String?;
    final delete = p['delete'] == true;

    final identity = await gateway.eventSnapshot(eventId);
    if (!identity.isPersonal) {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'source_event_not_editable',
        payload: {'guidance': '课程/考试/二课事件请用 create_user_overlay 标注，不直接修改。'},
      );
    }

    if (delete) {
      await gateway.softDeleteEvent(eventId);
      return AgentToolResult(payload: {'result': 'deleted_event'});
    }
    if (status != null) {
      switch (status) {
        case 'cancelled':
          await gateway.cancelEvent(eventId);
        case 'completed':
          await gateway.completeEvent(eventId);
        case 'skipped':
          await gateway.skipEvent(eventId);
      }
      return AgentToolResult(payload: {'result': 'updated_event', 'status': status});
    }

    // 字段修改
    if (identity.isRecurring && scope == 'whole_series') {
      final hasTimeChange = fields.containsKey('start_at') ||
          fields.containsKey('end_at') ||
          fields.containsKey('all_day') ||
          fields.containsKey('start_date') ||
          fields.containsKey('end_date_exclusive');
      if (hasTimeChange) {
        return const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'whole_series_time_change_not_supported',
          payload: {'guidance': '整系列时间变更暂不支持，可先用 only_this 只改本次，或在日程 UI 中整系列调整。'},
        );
      }
      final current = await gateway.seriesAnchor(identity.personalSeriesId!);
      final newAnchor = _applyToEvent(current, fields);
      final impact = await gateway.editWholeSeries(identity.personalSeriesId!, anchor: newAnchor);
      return AgentToolResult(payload: {
        'result': 'updated_whole_series',
        'affected_occurrences': impact.affectedOccurrences,
      });
    }
    if (identity.isRecurring) {
      final override = _buildOverride(fields);
      await gateway.editOccurrenceOnly(identity.personalSeriesId!, identity.occurrenceKey!, override);
      return AgentToolResult(payload: {'result': 'updated_occurrence'});
    }

    final current = await gateway.personalEvent(eventId);
    final replacement = _applyToEvent(current, fields);
    await gateway.editPersonalEvent(eventId, replacement);
    return AgentToolResult(payload: {'result': 'updated_event'});
  }

  static PersonalEvent _applyToEvent(PersonalEvent current, Map<String, Object?> fields) {
    // all_day 显式切换全天/定时语义；未提供时保留当前事件的形态。
    final wantAllDay = fields.containsKey('all_day') ? fields['all_day'] as bool : current.allDay;
    final title = (fields['title'] as String?) ?? current.title;
    final description = (fields['description'] as String?) ?? current.description;
    final location = (fields['location'] as String?) ?? current.locationName;
    final importance = (fields['importance'] as String?) ?? current.importance;
    final tags = (fields['tags'] as List<String>?) ?? current.tags;
    final type = (fields['type'] as PersonalEventType?) ?? current.type;

    if (wantAllDay) {
      // 转全天：优先用 fields 的 start_date；缺省时全天事件保留原日期，
      // 定时事件从 startAt 取日期。
      final DateTime startDate;
      if (fields['start_date'] != null) {
        startDate = fields['start_date'] as DateTime;
      } else if (current.allDay && current.startDate != null) {
        startDate = current.startDate!;
      } else {
        startDate = _dateOnly(fields['start_at'] as DateTime? ?? current.startAt!);
      }
      // 转全天：优先用 fields 的 end_date_exclusive；缺省时 +1 天。
      final DateTime endDate;
      if (fields['end_date_exclusive'] != null) {
        endDate = fields['end_date_exclusive'] as DateTime;
      } else if (current.allDay && current.endDateExclusive != null) {
        endDate = current.endDateExclusive!;
      } else {
        endDate = startDate.add(const Duration(days: 1));
      }
      return PersonalEvent.allDay(
        title: title, startDate: startDate, endDateExclusive: endDate,
        description: description, locationName: location, type: type,
        importance: importance, tags: tags,
      );
    }

    // 转定时：优先用 fields 的 start_at；全天事件取日期 09:00 默认，定时事件保留原时间。
    final DateTime startAt;
    if (fields['start_at'] != null) {
      startAt = fields['start_at'] as DateTime;
    } else if (current.allDay) {
      final date = fields['start_date'] as DateTime? ?? current.startDate!;
      startAt = DateTime(date.year, date.month, date.day, 9);
    } else {
      startAt = current.startAt!;
    }
    // 转定时：优先用 fields 的 end_at；缺省时 start_at +1 小时。
    final DateTime endAt;
    if (fields['end_at'] != null) {
      endAt = fields['end_at'] as DateTime;
    } else if (fields['start_at'] != null) {
      endAt = startAt.add(const Duration(hours: 1));
    } else if (current.allDay) {
      endAt = startAt.add(const Duration(hours: 1)); // 09:00-10:00
    } else {
      endAt = current.endAt!;
    }
    return PersonalEvent.timed(
      title: title, startAt: startAt, endAt: endAt,
      description: description, locationName: location, type: type,
      importance: importance, tags: tags,
    );
  }

  static DateTime _dateOnly(DateTime value) => DateTime(value.year, value.month, value.day);

  static OccurrenceOverride _buildOverride(Map<String, Object?> fields) => OccurrenceOverride(
    title: fields.containsKey('title') ? OverrideValue.set(fields['title'] as String) : const OverrideValue.absent(),
    description: fields.containsKey('description')
        ? OverrideValue.set(fields['description'] as String?)
        : const OverrideValue.absent(),
    locationName: fields.containsKey('location')
        ? OverrideValue.set(fields['location'] as String?)
        : const OverrideValue.absent(),
    startAt: fields.containsKey('start_at')
        ? OverrideValue.set(fields['start_at'] as DateTime)
        : const OverrideValue.absent(),
    endAt: fields.containsKey('end_at')
        ? OverrideValue.set(fields['end_at'] as DateTime)
        : const OverrideValue.absent(),
    startDate: fields.containsKey('start_date')
        ? OverrideValue.set(fields['start_date'] as DateTime)
        : const OverrideValue.absent(),
    endDateExclusive: fields.containsKey('end_date_exclusive')
        ? OverrideValue.set(fields['end_date_exclusive'] as DateTime)
        : const OverrideValue.absent(),
    importance: fields.containsKey('importance')
        ? OverrideValue.set(fields['importance'] as String)
        : const OverrideValue.absent(),
    tags: fields.containsKey('tags')
        ? OverrideValue.set(fields['tags'] as List<String>)
        : const OverrideValue.absent(),
  );
}

/// 为用户对某个事件或整门课设置个人标注（出勤/听讲/显示名/重要性/隐藏）。
class CreateUserOverlayTool extends AgentWriteTool {
  CreateUserOverlayTool({required super.gateway, required super.policy, required super.confirmationStore});

  @override
  String get name => 'create_user_overlay';
  @override
  String get description =>
      '设置事件或整门课程的个人标注：必去/可以赌/不去、听讲/不听讲、显示名、重要性、隐藏。ref_event 来自日程查询。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'ref_event': {'type': 'string'},
      'scope': {'type': 'string', 'enum': ['single_event', 'course_series'], 'default': 'single_event'},
      'attendance_policy': {'type': 'string', 'enum': ['must_go', 'gamble', 'skip']},
      'attendance_note': {'type': 'string'},
      'listening_mode': {'type': 'string', 'enum': ['listen', 'not_listen']},
      'listening_note': {'type': 'string'},
      'display_title': {'type': 'string'},
      'importance': {'type': 'string', 'enum': ['low', 'normal', 'high', 'critical']},
      'hidden': {'type': 'boolean'},
    },
    'required': ['ref_event'],
  };

  @override
  String get actionType => 'create_user_overlay';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'overlay';
  @override
  String get operationLabel => '设置个人标注';

  static AttendancePolicy? _attendance(String? value) => switch (value) {
    'must_go' => AttendancePolicy.mustGo,
    'gamble' => AttendancePolicy.gamble,
    'skip' => AttendancePolicy.skip,
    _ => null,
  };

  static ListeningMode? _listening(String? value) => switch (value) {
    'listen' => ListeningMode.listen,
    'not_listen' => ListeningMode.notListen,
    _ => null,
  };

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final r = WriteArgumentReader(a, const {
      'ref_event', 'scope', 'attendance_policy', 'attendance_note', 'listening_mode',
      'listening_note', 'display_title', 'importance', 'hidden',
    });
    r.rejectUnknownKeys();
    final ref = r.requiredString('ref_event');
    final eventId = ctx.references.resolve(ref: ref, kind: 'event');
    if (eventId == null) throw const FormatException('unknown event ref');
    final scope = r.optionalEnum('scope', const {'single_event', 'course_series'}) ?? 'single_event';

    const mutationKeys = {
      'attendance_policy', 'attendance_note', 'listening_mode', 'listening_note',
      'display_title', 'importance', 'hidden',
    };
    if (!mutationKeys.any(r.contains)) {
      throw const FormatException('no mutation fields provided');
    }

    r.optionalEnum('attendance_policy', const {'must_go', 'gamble', 'skip'});
    r.optionalEnum('listening_mode', const {'listen', 'not_listen'});
    r.optionalEnum('importance', _importanceValues);
    // 无条件类型校验：即便其他字段让 previewLines 非空，错误类型的 note/display_title
    // 也必须在此被拒，不能流到 commit 的原始参数里。
    r.optionalString('attendance_note');
    r.optionalString('listening_note');
    final displayTitle = r.contains('display_title') ? r.optionalString('display_title') : null;
    r.optionalBool('hidden');

    // 目标快照 preflight：账户内目标不存在，或 course_series 无系列 → 拒绝。
    final snapshot = await gateway.eventSnapshot(eventId);
    if (scope == 'course_series' &&
        (snapshot.courseSeriesId == null || snapshot.isPersonal)) {
      throw const FormatException('event has no course series for course_series overlay');
    }

    final lines = <String>[
      ..._eventTargetLines(snapshot),
    ];
    if (a['attendance_policy'] != null) lines.add('出勤：${a['attendance_policy']}');
    if (a['listening_mode'] != null) lines.add('听讲：${a['listening_mode']}');
    if (lines.isEmpty && displayTitle != null) lines.add('显示名：$displayTitle');
    lines.add(scope == 'course_series' ? '作用：整门课' : '作用：仅该事件');

    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: lines,
      commitParams: {'eventId': eventId, 'scope': scope, 'args': Map<String, Object?>.from(a), 'snapshot': snapshot},
      safeLogSummary: '设置个人标注 ${_eventSummary(snapshot)}｜${lines.skip(_eventTargetLines(snapshot).length).join('、')}',
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    final eventId = p['eventId'] as String;
    final scope = p['scope'] as String;
    final a = p['args'] as Map<String, Object?>;
    final mutation = OverlayMutation(
      displayTitle: a['display_title'] as String?,
      attendancePolicy: _attendance(a['attendance_policy'] as String?),
      attendanceNote: a['attendance_note'] as String?,
      listeningMode: _listening(a['listening_mode'] as String?),
      listeningNote: a['listening_note'] as String?,
      importance: a['importance'] as String?,
      hidden: a['hidden'] as bool?,
    );
    if (scope == 'course_series') {
      final seriesId = await gateway.courseSeriesIdForEvent(eventId);
      if (seriesId == null) {
        return const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'no_course_series',
          payload: {'guidance': '该事件不属于任何课程系列，无法整门课标注。'},
        );
      }
      await gateway.setSeriesOverlay(seriesId, mutation);
      return AgentToolResult(payload: {'result': 'updated_course_overlay'});
    }
    await gateway.setEventOverlay(eventId, mutation);
    return AgentToolResult(payload: {'result': 'updated_event_overlay'});
  }
}

/// 记录"可以赌"课程的本次出勤决定（去/不去/未定）。
class RecordAttendanceDecisionTool extends AgentWriteTool {
  RecordAttendanceDecisionTool({required super.gateway, required super.policy, required super.confirmationStore});

  @override
  String get name => 'record_attendance_decision';
  @override
  String get description => '记录某节课本次去不去（用于"可以赌"课程）。ref_event 来自日程查询。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'ref_event': {'type': 'string'},
      'decision': {'type': 'string', 'enum': ['go', 'skip', 'undecided']},
    },
    'required': ['ref_event', 'decision'],
  };

  @override
  String get actionType => 'record_attendance_decision';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'event';
  @override
  String get operationLabel => '记录出勤决定';

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final r = WriteArgumentReader(a, const {'ref_event', 'decision'});
    r.rejectUnknownKeys();
    final ref = r.requiredString('ref_event');
    final eventId = ctx.references.resolve(ref: ref, kind: 'event');
    if (eventId == null) throw const FormatException('unknown event ref');
    final decision = r.requiredEnum('decision', const {'go', 'skip', 'undecided'});
    final snapshot = await gateway.eventSnapshot(eventId);
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: [
        ..._eventTargetLines(snapshot),
        '出勤决定：$decision',
      ],
      commitParams: {'eventId': eventId, 'decision': decision},
      safeLogSummary: '记录出勤决定 $decision（${_eventSummary(snapshot)}）',
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    final eventId = p['eventId'] as String;
    final decision = switch (p['decision']) {
      'go' => AttendanceDecision.go,
      'skip' => AttendanceDecision.skip,
      _ => AttendanceDecision.undecided,
    };
    await gateway.recordAttendanceDecision(eventId, decision);
    return AgentToolResult(payload: {'result': 'recorded_attendance_decision', 'decision': decision.name});
  }
}

/// 设置某节课的听讲/不听讲模式。
class RecordListeningModeTool extends AgentWriteTool {
  RecordListeningModeTool({required super.gateway, required super.policy, required super.confirmationStore});

  @override
  String get name => 'record_listening_mode';
  @override
  String get description => '设置某节课听讲或不听讲，可附原因备注。ref_event 来自日程查询。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'ref_event': {'type': 'string'},
      'mode': {'type': 'string', 'enum': ['listen', 'not_listen']},
      'note': {'type': 'string'},
    },
    'required': ['ref_event', 'mode'],
  };

  @override
  String get actionType => 'record_listening_mode';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'event';
  @override
  String get operationLabel => '设置听讲模式';

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final r = WriteArgumentReader(a, const {'ref_event', 'mode', 'note'});
    r.rejectUnknownKeys();
    final ref = r.requiredString('ref_event');
    final eventId = ctx.references.resolve(ref: ref, kind: 'event');
    if (eventId == null) throw const FormatException('unknown event ref');
    final mode = r.requiredEnum('mode', const {'listen', 'not_listen'});
    final note = r.optionalString('note');
    final snapshot = await gateway.eventSnapshot(eventId);
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: [
        ..._eventTargetLines(snapshot),
        '听讲：$mode',
        if (note != null && note.isNotEmpty) '备注：$note',
      ],
      commitParams: {'eventId': eventId, 'mode': mode, 'note': note},
      safeLogSummary: '设置听讲模式 $mode（${_eventSummary(snapshot)}）',
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    final eventId = p['eventId'] as String;
    final mode = p['mode'] == 'not_listen' ? ListeningMode.notListen : ListeningMode.listen;
    await gateway.recordListeningMode(eventId, mode, note: p['note'] as String?);
    return AgentToolResult(payload: {'result': 'recorded_listening_mode'});
  }
}

/// 记录两个安排之间的关系与用户决策（仅支持 conflict 形态）。
class CreateScheduleRelationTool extends AgentWriteTool {
  CreateScheduleRelationTool({required super.gateway, required super.policy, required super.confirmationStore});

  @override
  String get name => 'create_schedule_relation';
  @override
  String get description =>
      '记录一对日程/执行块之间的关系与冲突决策（如二选一、课上写作业、翘课去二课）。ref_left/ref_right 来自日程或任务查询。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'ref_left': {'type': 'string'},
      'ref_right': {'type': 'string'},
      'conflict_state': {'type': 'string', 'enum': ['conflict', 'no_conflict']},
      'reason': {'type': 'string', 'description': '用户意图/备注'},
    },
    'required': ['ref_left', 'ref_right', 'conflict_state'],
  };

  @override
  String get actionType => 'create_schedule_relation';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'relation';
  @override
  String get operationLabel => '记录日程关系';

  /// 先按 event 解析，再回退 planblock（与只读工具绑定 kind 一致）。
  static ({String kind, String id}) _resolveRef(RunReferenceStore refs, String ref) {
    final eventId = refs.resolve(ref: ref, kind: 'event');
    if (eventId != null) return (kind: 'event', id: eventId);
    final blockId = refs.resolve(ref: ref, kind: 'planblock');
    if (blockId != null) return (kind: 'plan_block', id: blockId);
    throw const FormatException('unknown relation ref');
  }

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final r = WriteArgumentReader(a, const {'ref_left', 'ref_right', 'conflict_state', 'reason'});
    r.rejectUnknownKeys();
    final leftRef = r.requiredString('ref_left');
    final rightRef = r.requiredString('ref_right');
    if (leftRef == rightRef) throw const FormatException('refs must differ');
    final conflictState = r.requiredEnum('conflict_state', const {'conflict', 'no_conflict'});
    final reason = r.optionalString('reason');
    final left = _resolveRef(ctx.references, leftRef);
    final right = _resolveRef(ctx.references, rightRef);
    // 目标存在性 preflight：两个参与方都必须存在，否则不产生可批准提案。
    final leftLabel = await _relationParticipantLabel(gateway, left.kind, left.id);
    final rightLabel = await _relationParticipantLabel(gateway, right.kind, right.id);
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: [
        '日程 A：$leftLabel',
        '日程 B：$rightLabel',
        '关系：$conflictState',
        if (reason != null && reason.isNotEmpty) '理由：$reason',
      ],
      commitParams: {
        'left': left,
        'right': right,
        'conflictState': conflictState,
        'reason': reason,
      },
      safeLogSummary: '记录日程关系 $conflictState（$leftLabel ↔ $rightLabel）',
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    final left = p['left'] as ({String kind, String id});
    final right = p['right'] as ({String kind, String id});
    // TOCTOU 守卫：提案后参与方可能已被删除，重查两侧存在性再写，避免悬挂关系行。
    try {
      await _relationParticipantLabel(gateway, left.kind, left.id);
      await _relationParticipantLabel(gateway, right.kind, right.id);
    } on Object {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'target_not_found',
        payload: {'guidance': '关系参与方已不存在，无法记录该关系。'},
      );
    }
    await gateway.createConflictRelation(
      leftKind: left.kind,
      leftId: left.id,
      rightKind: right.kind,
      rightId: right.id,
      conflictState: p['conflictState'] as String,
      reason: p['reason'] as String?,
    );
    return AgentToolResult(payload: {'result': 'created_schedule_relation'});
  }
}

/// 为个人日程设置提醒偏移。
class SetReminderTool extends AgentWriteTool {
  SetReminderTool({required super.gateway, required super.policy, required super.confirmationStore});

  @override
  String get name => 'set_reminder';
  @override
  String get description => '为个人日程设置提醒（开始前 N 分钟）。ref_event 来自日程查询。本轮仅支持日程事件。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'ref_event': {'type': 'string'},
      'offsets_minutes': {'type': 'array', 'items': {'type': 'integer'},
          'description': '开始前提醒偏移（分钟），全部非负'},
    },
    'required': ['ref_event', 'offsets_minutes'],
  };

  @override
  String get actionType => 'set_reminder';
  @override
  RiskLevel get riskLevel => RiskLevel.medium;
  @override
  String get targetType => 'event';
  @override
  String get operationLabel => '设置提醒';

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final r = WriteArgumentReader(a, const {'ref_event', 'offsets_minutes'});
    r.rejectUnknownKeys();
    final ref = r.requiredString('ref_event');
    final eventId = ctx.references.resolve(ref: ref, kind: 'event');
    if (eventId == null) throw const FormatException('unknown event ref');
    final raw = r.requiredIntList('offsets_minutes');
    if (raw.isEmpty) throw const FormatException('offsets_minutes must not be empty');
    if (raw.any((o) => o < 0)) throw const FormatException('negative offset');
    // 排序 + 去重后再提案。
    final offsets = raw.toSet().toList()..sort();
    // 目标快照 preflight：账户内目标不存在/非个人来源 → 拒绝，不产生可批准提案。
    final snapshot = await gateway.eventSnapshot(eventId);
    if (!snapshot.isPersonal) {
      throw const FormatException('only personal events can set reminders');
    }
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: [
        ..._eventTargetLines(snapshot),
        '开始前 $offsets 分钟提醒',
      ],
      commitParams: {'eventId': eventId, 'offsets': offsets},
      safeLogSummary: '设置提醒 ${offsets.join(",")} 分钟（${_eventSummary(snapshot)}）',
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    final eventId = p['eventId'] as String;
    // 提醒仅支持个人日程：课程/考试/二课等来源事件不可设提醒（与 update_event 的
    // source_event_not_editable 语义一致），避免对非个人事件产生无意义覆盖。
    final identity = await gateway.eventSnapshot(eventId);
    if (!identity.isPersonal) {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'source_event_not_editable',
        payload: {'guidance': '仅个人日程可设置提醒；课程/考试/二课事件请勿设置。'},
      );
    }
    await gateway.setReminder(eventId, (p['offsets'] as List).cast<int>());
    return AgentToolResult(payload: {'result': 'reminder_set'});
  }
}

/// 调整某类操作的确认策略。永远需要用户确认，且无"以后不再确认"。
class UpdatePermissionPolicyTool extends AgentWriteTool {
  UpdatePermissionPolicyTool({required super.gateway, required super.policy, required super.confirmationStore});

  @override
  String get name => 'update_permission_policy';
  @override
  String get description =>
      '调整某类操作的确认策略（如"以后新建日程不要再问我"）。所有权限变更都需要用户在确认卡上亲手批准，不会自动放行。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'action_type': {'type': 'string',
          'enum': ['create_event', 'create_task', 'plan_task', 'create_schedule_relation',
              'set_reminder', 'record_attendance_decision', 'record_listening_mode',
              'create_user_overlay', 'update_event']},
      'target_type': {'type': 'string', 'default': 'event'},
      'confirmation_mode': {'type': 'string', 'enum': ['always_ask', 'ask_first_time', 'always_allow', 'always_deny']},
    },
    'required': ['action_type', 'confirmation_mode'],
  };

  @override
  String get actionType => 'update_permission_policy';
  @override
  RiskLevel get riskLevel => RiskLevel.critical;
  @override
  String get targetType => 'permission';
  @override
  String get operationLabel => '调整确认策略';
  @override
  bool get rememberAllowed => false;
  @override
  bool get forceConfirmation => true;

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final r = WriteArgumentReader(a, const {'action_type', 'target_type', 'confirmation_mode'});
    r.rejectUnknownKeys();
    final actionType = r.requiredEnum('action_type', const {
      'create_event', 'create_task', 'plan_task', 'create_schedule_relation', 'set_reminder',
      'record_attendance_decision', 'record_listening_mode', 'create_user_overlay', 'update_event',
    });
    const targetTypes = {'event', 'task', 'plan_block', 'overlay', 'relation', 'permission'};
    final targetType = r.contains('target_type')
        ? r.requiredEnum('target_type', targetTypes)
        : 'event';
    final modeValue = r.requiredEnum('confirmation_mode', const {
      'always_ask', 'ask_first_time', 'always_allow', 'always_deny',
    });
    final mode = switch (modeValue) {
      'ask_first_time' => ConfirmationMode.askFirstTime,
      'always_allow' => ConfirmationMode.alwaysAllow,
      'always_deny' => ConfirmationMode.alwaysDeny,
      _ => ConfirmationMode.alwaysAsk,
    };
    final currentMode = await policy.effectiveMode(
      accountId: ctx.accountId,
      actionType: actionType,
      targetType: targetType,
    );
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: [
        '目标动作：$actionType',
        '目标类型：$targetType',
        '当前模式：${currentMode.storage}',
        '改为：${mode.storage}',
      ],
      commitParams: {'actionType': actionType, 'targetType': targetType, 'mode': mode},
      safeLogSummary: '调整确认策略 $actionType($targetType) ${currentMode.storage} → ${mode.storage}',
      rememberAllowed: false,
      forceConfirmation: true,
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    final actionType = p['actionType'] as String;
    final targetType = p['targetType'] as String;
    final mode = p['mode'] as ConfirmationMode;
    await gateway.updatePermissionPolicy(
      actionType: actionType,
      targetType: targetType,
      mode: mode,
      riskLevel: AgentPermissionPolicyService.defaultRisk(actionType),
      enabled: true,
      updatedBy: 'agent',
    );
    return AgentToolResult(payload: {'result': 'permission_updated', 'action_type': actionType});
  }
}

/// 组装全部 10 个写工具。
List<AgentWriteTool> agentWriteTools(
  AgentWriteGateway gateway,
  AgentPermissionPolicyService policy,
  WriteConfirmationStore confirmationStore,
) => [
  CreateEventTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore),
  UpdateEventTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore),
  CreateTaskTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore),
  PlanTaskTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore),
  CreateUserOverlayTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore),
  RecordAttendanceDecisionTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore),
  RecordListeningModeTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore),
  CreateScheduleRelationTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore),
  SetReminderTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore),
  UpdatePermissionPolicyTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore),
];