import 'package:ustc_assistant_app/features/calendar/application/recurrence_service.dart';
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';
import 'package:ustc_assistant_app/features/tasks/domain/plan_block.dart';
import 'package:ustc_assistant_app/features/tasks/domain/task.dart';
import 'package:ustc_assistant_app/features/schedule/application/effective_event_repository.dart';
import 'package:ustc_assistant_app/features/schedule/application/overlay_service.dart';

import '../domain/agent_permission_policy.dart';
import '../domain/agent_tool.dart';
import '../domain/agent_write_proposal.dart';
import 'agent_permission_policy_service.dart';
import 'agent_write_tool.dart';
import 'run_reference_store.dart';

/// 把 ISO-8601 字符串解析为本地时间（模型传带 +08:00 偏移）。
DateTime _parseDateTime(String value) => DateTime.parse(value);

String _fmtRange(PersonalEvent event) => event.allDay
    ? '${event.startDate!.toIso8601String().substring(0, 10)} 至 '
          '${event.endDateExclusive!.toIso8601String().substring(0, 10)}'
    : '${event.startAt!.toIso8601String()} 至 ${event.endAt!.toIso8601String()}';

String _fmtTaskRange(DateTime? start, DateTime? end) =>
    '${start?.toIso8601String()} 至 ${end?.toIso8601String()}';

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
    'properties': {
      'title': {'type': 'string'},
      'start_at': {'type': 'string', 'description': '开始时间 ISO-8601，如 2026-08-01T15:00:00+08:00'},
      'end_at': {'type': 'string', 'description': '结束时间 ISO-8601'},
      'all_day': {'type': 'boolean', 'description': '全天事件传 true 并用 start_date/end_date_exclusive'},
      'start_date': {'type': 'string', 'description': '全天事件开始日期 YYYY-MM-DD'},
      'end_date_exclusive': {'type': 'string', 'description': '全天事件结束日期（不含）YYYY-MM-DD'},
      'location': {'type': 'string'},
      'type': {'type': 'string', 'enum': ['personal', 'entertainment', 'meal', 'campus_affair', 'travel', 'study']},
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
    final title = (a['title'] as String).trim();
    if (title.isEmpty) throw const FormatException('title required');
    final allDay = a['all_day'] == true;
    final type = personalEventTypeFromStorage((a['type'] as String?) ?? 'personal');
    final importance = (a['importance'] as String?) ?? 'normal';
    final tags = (a['tags'] as List?)?.cast<String>() ?? const <String>[];
    final offsets = (a['reminder_offsets_minutes'] as List?)?.cast<int>();
    final location = a['location'] as String?;
    final description = a['description'] as String?;

    final PersonalEvent event;
    if (allDay) {
      final startDate = _parseDateTime(a['start_date'] as String);
      final endDate = _parseDateTime(a['end_date_exclusive'] as String);
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
      final startAt = _parseDateTime(a['start_at'] as String);
      final endAt = _parseDateTime(a['end_at'] as String);
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
    'properties': {
      'title': {'type': 'string'},
      'description': {'type': 'string'},
      'deadline_at': {'type': 'string', 'description': '截止时间 ISO-8601，可空'},
      'estimated_minutes': {'type': 'integer', 'description': '预计工时（分钟）'},
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
    final title = (a['title'] as String).trim();
    if (title.isEmpty) throw const FormatException('title required');
    final deadlineAt = a['deadline_at'] == null ? null : _parseDateTime(a['deadline_at'] as String);
    final estimatedMinutes = a['estimated_minutes'] as int?;
    final importanceValue = (a['importance'] as String?) ?? 'normal';
    final importance = TaskImportance.values.firstWhere(
      (v) => v.name == importanceValue,
      orElse: () => TaskImportance.normal,
    );
    final tags = (a['tags'] as List?)?.cast<String>() ?? const <String>[];

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
        'description': a['description'],
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
    final ref = a['ref_task'] as String;
    final taskId = ctx.references.resolve(ref: ref, kind: 'task');
    if (taskId == null) throw const FormatException('unknown task ref');
    final startAt = _parseDateTime(a['start_at'] as String);
    final endAt = _parseDateTime(a['end_at'] as String);
    final title = a['title'] as String?;
    final statusValue = (a['status'] as String?) ?? 'accepted';
    final status = PlanBlockStatus.values.firstWhere(
      (v) => v.name == statusValue,
      orElse: () => PlanBlockStatus.accepted,
    );

    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: [
        if (title != null && title.isNotEmpty) '标题：$title',
        '时间：$_fmtTaskRange(startAt, endAt)',
      ],
      commitParams: {'taskId': taskId, 'startAt': startAt, 'endAt': endAt, 'title': title, 'status': status},
      safeLogSummary: '安排任务时间段 ${_fmtTaskRange(startAt, endAt)}',
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    await gateway.planTask(
      taskId: p['taskId'] as String,
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
    final ref = a['ref_event'] as String;
    final eventId = ctx.references.resolve(ref: ref, kind: 'event');
    if (eventId == null) throw const FormatException('unknown event ref');
    final scope = (a['scope'] as String?) ?? 'only_this';
    final fields = <String, Object?>{
      if (a.containsKey('title')) 'title': (a['title'] as String).trim(),
      if (a.containsKey('start_at')) 'start_at': _parseDateTime(a['start_at'] as String),
      if (a.containsKey('end_at')) 'end_at': _parseDateTime(a['end_at'] as String),
      if (a.containsKey('all_day')) 'all_day': a['all_day'],
      if (a.containsKey('start_date')) 'start_date': _parseDateTime(a['start_date'] as String),
      if (a.containsKey('end_date_exclusive')) 'end_date_exclusive': _parseDateTime(a['end_date_exclusive'] as String),
      if (a.containsKey('location')) 'location': a['location'],
      if (a.containsKey('description')) 'description': a['description'],
      if (a.containsKey('importance')) 'importance': a['importance'],
      if (a.containsKey('tags')) 'tags': (a['tags'] as List).cast<String>(),
    };
    final status = a['status'] as String?;
    final delete = a['delete'] == true;

    final lines = <String>[];
    if (delete) {
      lines.add('删除该日程（软删除，可从管理页恢复）');
    } else if (status != null) {
      lines.add('状态改为：$status');
    } else {
      if (a.containsKey('title')) lines.add('标题：${a['title']}');
      if (a.containsKey('start_at') || a.containsKey('end_at')) lines.add('时间有改动');
      lines.add(scope == 'whole_series' ? '影响：整个重复系列' : '影响：仅本次');
    }

    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: lines,
      commitParams: {'eventId': eventId, 'scope': scope, 'fields': fields, 'status': status, 'delete': delete},
      safeLogSummary: delete ? '删除日程' : (status != null ? '修改日程状态 $status' : '修改日程'),
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

    final identity = await gateway.eventIdentity(eventId);
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
      if (status == 'cancelled') {
        await gateway.cancelEvent(eventId);
      } else if (status == 'completed') {
        await gateway.completeEvent(eventId);
      } else {
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
        description: description, locationName: location, type: current.type,
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
      description: description, locationName: location, type: current.type,
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
    status: fields.containsKey('status')
        ? OverrideValue.set(eventStatusFromStorage(fields['status'] as String))
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
    final ref = a['ref_event'] as String;
    final eventId = ctx.references.resolve(ref: ref, kind: 'event');
    if (eventId == null) throw const FormatException('unknown event ref');
    final scope = (a['scope'] as String?) ?? 'single_event';
    final lines = <String>[];
    if (a['attendance_policy'] != null) lines.add('出勤：${a['attendance_policy']}');
    if (a['listening_mode'] != null) lines.add('听讲：${a['listening_mode']}');
    if (lines.isEmpty && a['display_title'] != null) lines.add('显示名：${a['display_title']}');
    lines.add(scope == 'course_series' ? '作用：整门课' : '作用：仅该事件');

    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: lines,
      commitParams: {'eventId': eventId, 'scope': scope, 'args': Map<String, Object?>.from(a)},
      safeLogSummary: '设置个人标注 ${lines.join('、')}',
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
    final ref = a['ref_event'] as String;
    final eventId = ctx.references.resolve(ref: ref, kind: 'event');
    if (eventId == null) throw const FormatException('unknown event ref');
    final decision = (a['decision'] as String?) ?? 'undecided';
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: ['出勤决定：$decision'],
      commitParams: {'eventId': eventId, 'decision': decision},
      safeLogSummary: '记录出勤决定 $decision',
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
    final ref = a['ref_event'] as String;
    final eventId = ctx.references.resolve(ref: ref, kind: 'event');
    if (eventId == null) throw const FormatException('unknown event ref');
    final mode = (a['mode'] as String?) ?? 'listen';
    final note = a['note'] as String?;
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: ['听讲：$mode', if (note != null && note.isNotEmpty) '备注：$note'],
      commitParams: {'eventId': eventId, 'mode': mode, 'note': note},
      safeLogSummary: '设置听讲模式 $mode',
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
    final left = _resolveRef(ctx.references, a['ref_left'] as String);
    final right = _resolveRef(ctx.references, a['ref_right'] as String);
    final conflictState = a['conflict_state'] as String;
    final reason = a['reason'] as String?;
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: [
        '关系：$conflictState',
        if (reason != null && reason.isNotEmpty) '理由：$reason',
      ],
      commitParams: {
        'left': left,
        'right': right,
        'conflictState': conflictState,
        'reason': reason,
      },
      safeLogSummary: '记录日程关系 $conflictState',
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    final left = p['left'] as ({String kind, String id});
    final right = p['right'] as ({String kind, String id});
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
    final ref = a['ref_event'] as String;
    final eventId = ctx.references.resolve(ref: ref, kind: 'event');
    if (eventId == null) throw const FormatException('unknown event ref');
    final offsets = (a['offsets_minutes'] as List).cast<int>();
    if (offsets.any((o) => o < 0)) throw const FormatException('negative offset');
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: ['开始前 $offsets 分钟提醒'],
      commitParams: {'eventId': eventId, 'offsets': offsets},
      safeLogSummary: '设置提醒 ${offsets.join(",")} 分钟',
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    await gateway.setReminder(p['eventId'] as String, (p['offsets'] as List).cast<int>());
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
    final actionType = a['action_type'] as String;
    final targetType = (a['target_type'] as String?) ?? 'event';
    final mode = ConfirmationModeStorage.fromStorage(a['confirmation_mode'] as String);
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: ['动作：$actionType', '改为：${mode.storage}'],
      commitParams: {'actionType': actionType, 'targetType': targetType, 'mode': mode},
      safeLogSummary: '调整确认策略 $actionType → ${mode.storage}',
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
