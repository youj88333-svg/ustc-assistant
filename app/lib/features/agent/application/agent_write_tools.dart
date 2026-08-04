import 'package:ustc_assistant_app/features/calendar/application/recurrence_lifecycle_service.dart';
import 'package:ustc_assistant_app/features/calendar/application/recurrence_service.dart';
import 'package:ustc_assistant_app/features/calendar/domain/personal_event.dart';
import 'package:ustc_assistant_app/features/calendar/domain/recurrence_expander.dart';
import 'package:ustc_assistant_app/features/calendar/domain/recurrence_rule.dart';
import 'package:ustc_assistant_app/features/tasks/domain/plan_block.dart';
import 'package:ustc_assistant_app/features/tasks/domain/task.dart';
import 'package:ustc_assistant_app/features/schedule/application/effective_event_repository.dart';
import 'package:ustc_assistant_app/features/schedule/application/overlay_service.dart';
import 'package:ustc_assistant_app/features/schedule/domain/jw_day_move.dart';

import '../domain/agent_permission_policy.dart';
import '../domain/agent_tool.dart';
import '../domain/agent_write_gateway.dart';
import '../domain/agent_write_proposal.dart';
import '../domain/agent_write_unit_of_work.dart';
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

/// 严格解析 `YYYY-MM-DD` 北京日历日并原样返回；非法格式/不存在的日历日抛
/// [FormatException]（由基类映射为 `invalid_write_arguments`）。与
/// `agent_tools.dart` 的 `_parseDate` 一致：DateTime 会归一化溢出，因此必须
/// 校验回环后的年月日与请求值一致（2026-02-31 会被拒绝）。
String _parseMoveDate(String value) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (match == null) throw FormatException('date must be YYYY-MM-DD');
  final y = int.parse(match.group(1)!);
  final m = int.parse(match.group(2)!);
  final d = int.parse(match.group(3)!);
  if (m < 1 || m > 12 || d < 1 || d > 31) {
    throw FormatException('invalid calendar date');
  }
  final rounded = DateTime(y, m, d);
  if (rounded.year != y || rounded.month != m || rounded.day != d) {
    throw FormatException('invalid calendar date');
  }
  return value;
}

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

/// 关系参与方类型的展示词（仅用于确认预览/安全日志，不暴露 id/ref）。
String _kindZh(String kind) => switch (kind) {
  'event' => '日程',
  'plan_block' => '执行块',
  _ => '参与方',
};

/// 冲突状态的中文展示词（仅用于确认预览，不直接暴露存储值）。
String _conflictStateZh(String state) => switch (state) {
  'conflict' => '冲突',
  'no_conflict' => '不冲突',
  _ => state,
};

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
  CreateEventTool({required super.gateway, required super.policy, required super.confirmationStore, required super.unitOfWork});

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
      'recurrence': {
        'type': 'object',
        'description': '可选：把本日程创建为固定重复系列。anchor 取自 start_at/start_date，'
            '模型不能提供冲突 anchor。',
        'additionalProperties': false,
        'properties': {
          'frequency': {'type': 'string', 'enum': ['daily', 'weekly', 'monthly']},
          'interval': {'type': 'integer', 'description': '间隔，默认 1，必须为正'},
          'weekdays': {
            'type': 'array',
            'items': {'type': 'integer'},
            'description': '仅 weekly 必填且非空；ISO 星期 1-7，去重',
          },
          'until_date': {'type': 'string', 'description': '包含的结束日期 YYYY-MM-DD，可空'},
        },
        'required': ['frequency'],
      },
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
  List<AgentWriteAllowance> get agentWriteAllowances =>
      [AgentWriteAllowance.fromRegistry('create_event')];

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final r = WriteArgumentReader(a, const {
      'title', 'start_at', 'end_at', 'all_day', 'start_date', 'end_date_exclusive',
      'location', 'type', 'importance', 'description', 'tags', 'reminder_offsets_minutes',
      'recurrence',
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

    // 可选重复规则：构造并校验 RecurrenceRule（anchor 取 start_at/start_date，
    // 模型不能提供冲突 anchor）。缺失时保持单次日程行为完全不变。
    final anchor = allDay ? event.startDate! : event.startAt!;
    final RecurrenceRule? recurrenceRule = r.contains('recurrence')
        ? _parseRecurrence(_requiredMap(a['recurrence'], 'recurrence'), anchor)
        : null;
    final recurrenceLines = recurrenceRule == null
        ? const <String>[]
        : _recurrencePreviewLines(recurrenceRule, allDay);

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
        ...recurrenceLines,
      ],
      commitParams: {
        'event': event,
        'reminderOffsetsMinutes': offsets,
        'recurrenceRule': ?recurrenceRule,
      },
      safeLogSummary: recurrenceRule == null
          ? '新建日程 $title ${_fmtRange(event)}'
          : '新建重复日程 $title ${_fmtRange(event)}（${_recurrenceSummary(recurrenceRule)}）',
    );
  }

  /// 读取必需的嵌套对象参数（如 `recurrence`）。类型不匹配抛 [FormatException]。
  static Map<String, Object?> _requiredMap(Object? value, String key) {
    if (value is! Map) throw FormatException('$key must be an object');
    return value.map((k, v) => MapEntry(k.toString(), v));
  }

  /// 解析并校验 `recurrence` 参数为 [RecurrenceRule]。校验失败抛
  /// [FormatException]（映射为 `invalid_write_arguments`）或
  /// [RecurrenceValidationError]。
  static RecurrenceRule _parseRecurrence(Map<String, Object?> raw, DateTime anchor) {
    final r = WriteArgumentReader(raw, const {'frequency', 'interval', 'weekdays', 'until_date'});
    r.rejectUnknownKeys();
    final frequency = r.requiredEnum('frequency', const {'daily', 'weekly', 'monthly'});
    final interval = r.optionalInt('interval') ?? 1;
    if (interval <= 0) throw const FormatException('interval must be positive');
    DateTime? untilDate;
    if (r.contains('until_date')) {
      untilDate = _parseCalendarDate(r.requiredString('until_date'));
    }
    try {
      return switch (frequency) {
        'daily' => RecurrenceRule.daily(anchor: anchor, interval: interval, untilDate: untilDate),
        'weekly' => RecurrenceRule.weekly(
            anchor: anchor,
            interval: interval,
            weekdays: _parseWeekdays(r),
            untilDate: untilDate,
          ),
        _ => RecurrenceRule.monthly(anchor: anchor, interval: interval, untilDate: untilDate),
      };
    } on RecurrenceValidationError catch (e) {
      // 把领域校验失败（如 until_Date 早于 anchor）映射为参数错误，由基类统一
      // 转为 invalid_write_arguments。
      throw FormatException(e.message);
    }
  }

  /// 严格解析 weekly 的 `weekdays`：1-7、非空、去重。缺失/空/越界抛 [FormatException]。
  static Set<int> _parseWeekdays(WriteArgumentReader r) {
    final weekdays = r.contains('weekdays') ? r.requiredIntList('weekdays') : const <int>[];
    if (weekdays.isEmpty) throw const FormatException('weekdays is required for weekly recurrence');
    if (weekdays.any((d) => d < 1 || d > 7)) {
      throw const FormatException('weekdays must be ISO 1-7');
    }
    return weekdays.toSet();
  }

  /// 严格解析 `YYYY-MM-DD` 并返回本地零点 DateTime；非法/不存在的日历日抛 [FormatException]。
  static DateTime _parseCalendarDate(String value) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
    if (match == null) throw const FormatException('date must be YYYY-MM-DD');
    final y = int.parse(match.group(1)!);
    final m = int.parse(match.group(2)!);
    final d = int.parse(match.group(3)!);
    final rounded = DateTime(y, m, d);
    if (rounded.year != y || rounded.month != m || rounded.day != d) {
      throw const FormatException('invalid calendar date');
    }
    return rounded;
  }

  static const Map<int, String> _isoWeekdayZh = {
    1: '周一', 2: '周二', 3: '周三', 4: '周四', 5: '周五', 6: '周六', 7: '周日',
  };

  String _frequencyZh(RecurrenceRule rule) => switch (rule.frequency) {
    RecurrenceFrequency.daily => '每天',
    RecurrenceFrequency.weekly => '每周',
    RecurrenceFrequency.monthly => '每月',
  };

  /// 重复规则的确认预览行：频率/间隔/星期（weekly）、结束（含“持续重复”）、
  /// 前五个发生日期时间。只含安全字段，无任何 id/rule 原始 JSON。
  List<String> _recurrencePreviewLines(RecurrenceRule rule, bool allDay) {
    final lines = <String>[
      '重复：${_frequencyZh(rule)}'
          '${rule.interval > 1 ? '（每 ${rule.interval} ${_intervalUnitZh(rule)}）' : ''}'
          '${rule.frequency == RecurrenceFrequency.weekly ? ' ${_weekdayPreview(rule)}' : ''}',
      rule.untilDate != null
          ? '结束：至 ${dateText(rule.untilDate!)}（含）'
          : '结束：持续重复',
    ];
    final occurrences = _firstOccurrences(rule);
    if (occurrences.isNotEmpty) {
      final firstFive = occurrences.take(5).map((d) => allDay
          ? d.toIso8601String().substring(0, 10)
          : _fmtOccurrenceDateTime(d)).toList();
      lines.add('前五次：${firstFive.join('、')}');
    }
    return lines;
  }

  /// 发生时刻的展示（定时事件）：`YYYY-MM-DD HH:MM`。不显示结束时间，聚焦发生点。
  String _fmtOccurrenceDateTime(DateTime value) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }

  String _weekdayPreview(RecurrenceRule rule) {
    final sorted = rule.weekdays.toList()..sort();
    return sorted.map((d) => _isoWeekdayZh[d] ?? '$d').join('、');
  }

  String _intervalUnitZh(RecurrenceRule rule) => switch (rule.frequency) {
    RecurrenceFrequency.daily => '天',
    RecurrenceFrequency.weekly => '周',
    RecurrenceFrequency.monthly => '月',
  };

  /// 前若干个发生时刻（最多取 5），用于确认预览。用有限窗口调用 expandRecurrence，
  /// 由扩展器按 until/间隔约束裁剪。
  List<DateTime> _firstOccurrences(RecurrenceRule rule) {
    final through = rule.anchor.add(const Duration(days: 300));
    try {
      return expandRecurrence(rule, from: rule.anchor, through: through);
    } on Object {
      return [];
    }
  }

  String _recurrenceSummary(RecurrenceRule rule) {
    final freq = switch (rule.frequency) {
      RecurrenceFrequency.daily => '每天',
      RecurrenceFrequency.weekly => '每周',
      RecurrenceFrequency.monthly => '每月',
    };
    final end = rule.untilDate != null ? '至${dateText(rule.untilDate!)}' : '持续重复';
    return '$freq${rule.interval > 1 ? 'x${rule.interval}' : ''}$end';
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final event = proposal.commitParams['event'] as PersonalEvent;
    final offsets = proposal.commitParams['reminderOffsetsMinutes'] as List<int>?;
    final rule = proposal.commitParams['recurrenceRule'] as RecurrenceRule?;
    if (rule != null) {
      // 重复系列：委托 RecurrenceService.createSeries（缺省 reminder 由 service
      // 归一化：timed=[15]、all-day=[]）。系列 id 只在 commit 内使用，不进结果。
      await gateway.createRecurringEvent(event, rule, reminderOffsetsMinutes: offsets);
      return AgentToolResult(payload: {'result': 'created_recurring_event', 'title': event.title});
    }
    await gateway.createEvent(event, reminderOffsetsMinutes: offsets);
    return AgentToolResult(payload: {'result': 'created_event', 'title': event.title});
  }
}

/// 新建任务。
class CreateTaskTool extends AgentWriteTool {
  CreateTaskTool({required super.gateway, required super.policy, required super.confirmationStore, required super.unitOfWork});

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
  List<AgentWriteAllowance> get agentWriteAllowances =>
      [AgentWriteAllowance.fromRegistry('create_task')];

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
  PlanTaskTool({required super.gateway, required super.policy, required super.confirmationStore, required super.unitOfWork});

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
  List<AgentWriteAllowance> get agentWriteAllowances =>
      [AgentWriteAllowance.fromRegistry('plan_task')];

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
  UpdateEventTool({required super.gateway, required super.policy, required super.confirmationStore, required super.unitOfWork});

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
      'scope': {'type': 'string', 'enum': ['only_this', 'this_and_future', 'whole_series'], 'default': 'only_this',
          'description': '重复系列编辑/删除/取消范围；非重复事件忽略此字段'},
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
  String get actionType => 'event_edit';
  @override
  RiskLevel get riskLevel => RiskLevel.high;
  @override
  String get targetType => 'event';
  @override
  String get operationLabel => '修改/删除日程';
  @override
  List<AgentWriteAllowance> get agentWriteAllowances => [
    AgentWriteAllowance.fromRegistry('event_edit'),
    AgentWriteAllowance.fromRegistry('event_cancel'),
    AgentWriteAllowance.fromRegistry('event_delete'),
  ];

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
    final scope = r.optionalEnum('scope', const {'only_this', 'this_and_future', 'whole_series'}) ?? 'only_this';
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

    // 同一 update_event 工具对不同生命周期动作采用不同审批策略键（proposal 是
    // 唯一审批权威）。delete 与 cancel 分解为独立动作键，字段编辑/complete/skip
    // 保持 event_edit——绝不回退到旧的 update_event 兼容键（那只作为 event_edit
    // 的一版 fallback）。
    final effectiveActionType = delete
        ? 'event_delete'
        : (status == 'cancelled' ? 'event_cancel' : 'event_edit');

    return AgentWriteProposal(
      toolName: name,
      actionType: effectiveActionType,
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
      // Recurring occurrences/series delete across the chosen scope.
      final seriesId = identity.personalSeriesId;
      if (seriesId != null) {
        await gateway.recurringLifecycle(
          seriesId,
          occurrenceKey: identity.occurrenceKey,
          scope: _actionScope(scope),
          action: RecurringLifecycleAction.delete,
        );
        return AgentToolResult(
          payload: {
            'result': 'deleted_event',
            if (identity.occurrenceKey != null) 'scope': scope,
          },
        );
      }
      await gateway.softDeleteEvent(eventId);
      return AgentToolResult(payload: {'result': 'deleted_event'});
    }
    if (status != null) {
      if (status == 'cancelled') {
        // Recurring occurrences/series cancel across the chosen scope.
        final seriesId = identity.personalSeriesId;
        if (seriesId != null) {
          await gateway.recurringLifecycle(
            seriesId,
            occurrenceKey: identity.occurrenceKey,
            scope: _actionScope(scope),
            action: RecurringLifecycleAction.cancel,
          );
          return AgentToolResult(
            payload: {
              'result': 'updated_event',
              'status': status,
              if (identity.occurrenceKey != null) 'scope': scope,
            },
          );
        }
      }
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

  static RecurringActionScope _actionScope(String scope) => switch (scope) {
        'this_and_future' => RecurringActionScope.thisAndFuture,
        'whole_series' => RecurringActionScope.wholeSeries,
        _ => RecurringActionScope.onlyThis,
      };

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

class CreateUserOverlayTool extends AgentWriteTool {
  CreateUserOverlayTool({required super.gateway, required super.policy, required super.confirmationStore, required super.unitOfWork});

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
  @override
  List<AgentWriteAllowance> get agentWriteAllowances =>
      [AgentWriteAllowance.fromRegistry('create_user_overlay')];

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

    // 无条件类型校验：即便其他字段让 previewLines 非空，错误类型的 note/display_title
    // 也必须在此被拒，不能流到 commit 的原始参数里。
    final attendancePolicy = r.optionalEnum('attendance_policy', const {'must_go', 'gamble', 'skip'});
    final listeningMode = r.optionalEnum('listening_mode', const {'listen', 'not_listen'});
    final importance = r.optionalEnum('importance', _importanceValues);
    final attendanceNote = r.optionalString('attendance_note');
    final listeningNote = r.optionalString('listening_note');
    final displayTitle = r.contains('display_title') ? r.optionalString('display_title') : null;
    final hidden = r.optionalBool('hidden');

    // 目标快照 preflight：账户内目标不存在，或 course_series 无系列 → 拒绝。
    final snapshot = await gateway.eventSnapshot(eventId);
    if (scope == 'course_series' &&
        (snapshot.courseSeriesId == null || snapshot.isPersonal)) {
      throw const FormatException('event has no course series for course_series overlay');
    }

    final lines = <String>[
      ..._eventTargetLines(snapshot),
    ];
    if (attendancePolicy != null) lines.add('出勤：$attendancePolicy');
    if (listeningMode != null) lines.add('听讲：$listeningMode');
    if (lines.isEmpty && displayTitle != null) lines.add('显示名：$displayTitle');
    lines.add(scope == 'course_series' ? '作用：整门课' : '作用：仅该事件');

    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: lines,
      commitParams: {
        'eventId': eventId,
        'scope': scope,
        'displayTitle': displayTitle,
        'attendanceNote': attendanceNote,
        'listeningNote': listeningNote,
        'hidden': hidden,
        'attendancePolicy': attendancePolicy,
        'listeningMode': listeningMode,
        'importance': importance,
        'snapshot': snapshot,
      },
      safeLogSummary: '设置个人标注 ${_eventSummary(snapshot)}｜${lines.skip(_eventTargetLines(snapshot).length).join('、')}',
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    final eventId = p['eventId'] as String;
    final scope = p['scope'] as String;
    final mutation = OverlayMutation(
      displayTitle: p['displayTitle'] as String?,
      attendancePolicy: _attendance(p['attendancePolicy'] as String?),
      attendanceNote: p['attendanceNote'] as String?,
      listeningMode: _listening(p['listeningMode'] as String?),
      listeningNote: p['listeningNote'] as String?,
      importance: p['importance'] as String?,
      hidden: p['hidden'] as bool?,
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
  RecordAttendanceDecisionTool({required super.gateway, required super.policy, required super.confirmationStore, required super.unitOfWork});

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
  List<AgentWriteAllowance> get agentWriteAllowances =>
      [AgentWriteAllowance.fromRegistry('record_attendance_decision')];

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
  RecordListeningModeTool({required super.gateway, required super.policy, required super.confirmationStore, required super.unitOfWork});

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
  List<AgentWriteAllowance> get agentWriteAllowances =>
      [AgentWriteAllowance.fromRegistry('record_listening_mode')];

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
  CreateScheduleRelationTool({required super.gateway, required super.policy, required super.confirmationStore, required super.unitOfWork});

  @override
  String get name => 'create_schedule_relation';
  @override
  String get description =>
      '记录一对日程/执行块之间的冲突决策（如二选一、课上写作业、翘课去二课）。'
      'ref_left/ref_right 来自日程或任务查询。conflict_state 以用户已表达的完整意图为准：'
      '用户选择了一项、允许两项共存或在课内嵌套完成另一任务时为 no_conflict；'
      '仅当用户明确表示尚未决定或只需登记未解决冲突时才为 conflict。'
      '若意图不明确，先询问，不生成确认卡。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'ref_left': {'type': 'string'},
      'ref_right': {'type': 'string'},
      'conflict_state': {
        'type': 'string',
        'enum': ['conflict', 'no_conflict'],
        'description': '用户已表达的决策：选择了一项/允许共存/课上完成另一任务 -> no_conflict；'
            '尚未决定或只需登记未解决冲突 -> conflict。以用户完整意图为准，不能仅因为'
            '时间重叠或出现“冲突”一词就写 conflict。',
      },
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
  @override
  List<AgentWriteAllowance> get agentWriteAllowances =>
      [AgentWriteAllowance.fromRegistry('create_schedule_relation')];

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
    final stateZh = _conflictStateZh(conflictState);
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: [
        '${_kindZh(left.kind)} A：$leftLabel',
        '${_kindZh(right.kind)} B：$rightLabel',
        '关系：$stateZh',
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
  SetReminderTool({required super.gateway, required super.policy, required super.confirmationStore, required super.unitOfWork});

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
  List<AgentWriteAllowance> get agentWriteAllowances =>
      [AgentWriteAllowance.fromRegistry('set_reminder')];

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

/// 整日移动教务课程（action=move|clear）。
///
/// critical：永远需要确认（forceConfirmation）、无"以后不再确认"
/// （rememberAllowed=false）、不可被 update_permission_policy 放宽。
/// 只暴露 `JwDayMoveService` 的 preview/move/clear，工具本身不触表；预览仅含
/// 源/目标日期、课程数与课程标题，绝不含任何 DB id 或 ref。commit 通过
/// service 在同一事务内重检资格与目标记录，失败安全返回
/// `no_eligible_jw_courses` / `target_not_found`。
class MoveJwCourseDayTool extends AgentWriteTool {
  MoveJwCourseDayTool({required super.gateway, required super.policy, required super.confirmationStore, required super.unitOfWork});

  @override
  String get name => 'move_jw_course_day';
  @override
  String get description =>
      '把某天（source_date）的教务课程整体移到另一天（target_date），或清除'
      '（action=clear）已设置的整日移动恢复原日期。仅影响 ustc_jw 来源的定时'
      'course 事件；考试/二课/个人事件不受影响。该操作永远需要用户确认。';
  @override
  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'action': {'type': 'string', 'enum': ['move', 'clear'],
          'description': 'move=整体移动到 target_date；clear=清除移动恢复原日期'},
      'source_date': {'type': 'string', 'description': '源日期 YYYY-MM-DD（北京日历日）'},
      'target_date': {'type': 'string', 'description': '目标日期 YYYY-MM-DD，仅 action=move 需要'},
    },
    'required': ['action', 'source_date'],
  };

  @override
  String get actionType => 'move_jw_course_day';
  @override
  RiskLevel get riskLevel => RiskLevel.critical;
  @override
  String get targetType => 'jw_day_move';
  @override
  String get operationLabel => '整日移动教务课程';
  @override
  bool get rememberAllowed => false;
  @override
  bool get forceConfirmation => true;
  @override
  List<AgentWriteAllowance> get agentWriteAllowances =>
      [AgentWriteAllowance.fromRegistry('move_jw_course_day')];

  @override
  Future<AgentToolResult> execute(Map<String, Object?> arguments, AgentToolContext context) async {
    // 提案阶段（确认前）的领域校验失败要映射为安全的专用错误码，而不是
    // 基类的 invalid_write_arguments 或注册表的 tool_execution_failed。
    try {
      return await super.execute(arguments, context);
    } on NoEligibleJwCourses {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'no_eligible_jw_courses',
        payload: {'guidance': '该日期没有符合条件的教务课程可移动。'},
      );
    } on MissingJwDayMove {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'target_not_found',
        payload: {'guidance': '该日期没有已设置的整日移动，无需清除。'},
      );
    }
  }

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final r = WriteArgumentReader(a, const {'action', 'source_date', 'target_date'});
    r.rejectUnknownKeys();
    final action = r.requiredEnum('action', const {'move', 'clear'});
    final sourceDate = _parseMoveDate(r.requiredString('source_date'));
    String? targetDate;
    if (action == 'move') {
      if (!r.contains('target_date')) {
        throw const FormatException('target_date is required for move');
      }
      targetDate = _parseMoveDate(r.requiredString('target_date'));
      if (sourceDate == targetDate) {
        throw const FormatException('source and target dates must differ');
      }
    } else if (r.contains('target_date')) {
      throw const FormatException('target_date is only allowed for move');
    }

    // 预览（确认前的资格 preflight）：只读课程标题与已有目标日期，永不含 id。
    final preview = await gateway.jwDayMovePreview(sourceDate);
    if (action == 'move' && preview.courses.isEmpty) {
      throw NoEligibleJwCourses(sourceDate);
    }
    if (action == 'clear' && preview.targetDate == null) {
      throw MissingJwDayMove(sourceDate);
    }

    final isRetarget = preview.targetDate != null;
    final lines = <String>[
      if (action == 'move') ...[
        '移动：$sourceDate 的教务课程',
        '目标：$targetDate',
        '课程数：${preview.courses.length}',
        for (final title in preview.courses) '课程：$title',
        if (isRetarget) '备注：该日期已有移动记录，本次将更新目标日期',
      ] else ...[
        '清除：$sourceDate 的整日移动',
        if (preview.targetDate != null) '当前目标：${preview.targetDate}',
      ],
    ];

    return AgentWriteProposal(
      toolName: name,
      actionType: actionType,
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: lines,
      commitParams: {
        'action': action,
        'sourceDate': sourceDate,
        'targetDate': targetDate,
      },
      safeLogSummary: action == 'move'
          ? '整日移动教务课程 $sourceDate → $targetDate（${preview.courses.length} 门）'
          : '清除整日移动 $sourceDate',
      rememberAllowed: false,
      forceConfirmation: true,
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    final action = p['action'] as String;
    final sourceDate = p['sourceDate'] as String;
    if (action == 'clear') {
      try {
        await gateway.jwDayMoveClear(sourceDate);
      } on MissingJwDayMove {
        // TOCTOU 守卫：提案后移动记录已被清除，安全拒绝。
        return const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'target_not_found',
          payload: {'guidance': '该日期已没有可清除的整日移动。'},
        );
      } on NoEligibleJwCourses {
        return const AgentToolResult(
          status: AgentToolStatus.error,
          errorCode: 'no_eligible_jw_courses',
          payload: {'guidance': '该日期没有符合条件的教务课程。'},
        );
      }
      return const AgentToolResult(payload: {'result': 'cleared_jw_course_day_move'});
    }

    final targetDate = p['targetDate'] as String;
    final bool retargeted;
    try {
      // service 在同一事务内重检资格与目标，失败抛领域异常。
      retargeted = await gateway.jwDayMove(sourceDate, targetDate);
    } on NoEligibleJwCourses {
      // TOCTOU 守卫：提案后课程不再可移动，安全拒绝且不产生任何写。
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'no_eligible_jw_courses',
        payload: {'guidance': '该日期已没有符合条件的教务课程，无法移动。'},
      );
    } on InvalidDayMoveDates {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'invalid_write_arguments',
      );
    } on MissingJwDayMove {
      return const AgentToolResult(
        status: AgentToolStatus.error,
        errorCode: 'target_not_found',
        payload: {'guidance': '移动目标状态已变化，无法完成本次操作。'},
      );
    }
    return AgentToolResult(
      payload: {
        'result': retargeted ? 'retargeted_jw_course_day' : 'moved_jw_course_day',
      },
    );
  }
}

/// 调整某类操作的确认策略。永远需要用户确认，且无"以后不再确认"。
class UpdatePermissionPolicyTool extends AgentWriteTool {
  UpdatePermissionPolicyTool({required super.gateway, required super.policy, required super.confirmationStore, required super.unitOfWork});

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
          'enum': ['create_event', 'event_edit', 'create_task', 'plan_task',
              'create_schedule_relation', 'set_reminder', 'record_attendance_decision',
              'record_listening_mode', 'create_user_overlay']},
      'target_type': {'type': 'string', 'description': '目标动作的 target_type，必须与 action_type 匹配'},
      'confirmation_mode': {'type': 'string', 'enum': ['always_ask', 'ask_first_time', 'always_allow', 'always_deny']},
    },
    'required': ['action_type', 'target_type', 'confirmation_mode'],
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
  List<AgentWriteAllowance> get agentWriteAllowances => const [
    // proposal.targetType 是被调整动作的类型（而非本工具自身的 permission），
    // 因此在 actionType/risk 已是 critical 且恒 force-confirm 的前提下允许 target
    // 通配；actionType 仍锁定为 update_permission_policy，无法注入其它策略键。
    // risk 取自注册表 defaultRisk（critical）。
    AgentWriteAllowance('update_permission_policy', null, RiskLevel.critical),
  ];

  @override
  Future<AgentWriteProposal> propose(Map<String, Object?> a, AgentToolContext ctx) async {
    final r = WriteArgumentReader(a, const {'action_type', 'target_type', 'confirmation_mode'});
    r.rejectUnknownKeys();
    // targetActionType：本提案要调整确认策略的「目标动作」（如 create_event）。
    // proposal.actionType 恒为 update_permission_policy，绝不使用目标动作覆盖它
    // （修复 High 2 影子覆盖：此前 actionType 同时顶替 proposal.actionType）。
    final targetActionType = r.requiredEnum('action_type', AgentPermissionPolicyService.kAgentPolicyActionTypes);
    final targetType = r.requiredEnum(
      'target_type',
      {AgentPermissionPolicyService.targetTypeFor(targetActionType)},
    );
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
      actionType: targetActionType,
      targetType: targetType,
    );
    return AgentWriteProposal(
      toolName: name,
      actionType: actionType, // 恒为 update_permission_policy
      riskLevel: riskLevel,
      targetType: targetType,
      operationLabel: operationLabel,
      previewLines: [
        '目标动作：$targetActionType',
        '目标类型：$targetType',
        '当前模式：${currentMode.storage}',
        '改为：${mode.storage}',
      ],
      commitParams: {
        'targetActionType': targetActionType,
        'targetType': targetType,
        'mode': mode,
      },
      safeLogSummary: '调整确认策略 $targetActionType($targetType) ${currentMode.storage} → ${mode.storage}',
      rememberAllowed: false,
      forceConfirmation: true,
    );
  }

  @override
  Future<AgentToolResult> commit(AgentWriteProposal proposal, AgentToolContext ctx) async {
    final p = proposal.commitParams;
    final targetActionType = p['targetActionType'] as String;
    final targetType = p['targetType'] as String;
    final mode = p['mode'] as ConfirmationMode;
    await gateway.updatePermissionPolicy(
      actionType: targetActionType,
      targetType: targetType,
      mode: mode,
      riskLevel: AgentPermissionPolicyService.defaultRisk(targetActionType),
      enabled: true,
      updatedBy: 'agent',
    );
    return AgentToolResult(payload: {'result': 'permission_updated', 'action_type': targetActionType});
  }
}

/// 组装全部 11 个写工具。
List<AgentWriteTool> agentWriteTools(
  AgentWriteGateway gateway,
  AgentPermissionPolicyService policy,
  WriteConfirmationStore confirmationStore,
  AgentWriteUnitOfWork unitOfWork,
) => [
  CreateEventTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore, unitOfWork: unitOfWork),
  UpdateEventTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore, unitOfWork: unitOfWork),
  CreateTaskTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore, unitOfWork: unitOfWork),
  PlanTaskTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore, unitOfWork: unitOfWork),
  CreateUserOverlayTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore, unitOfWork: unitOfWork),
  RecordAttendanceDecisionTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore, unitOfWork: unitOfWork),
  RecordListeningModeTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore, unitOfWork: unitOfWork),
  CreateScheduleRelationTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore, unitOfWork: unitOfWork),
  SetReminderTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore, unitOfWork: unitOfWork),
  MoveJwCourseDayTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore, unitOfWork: unitOfWork),
  UpdatePermissionPolicyTool(gateway: gateway, policy: policy, confirmationStore: confirmationStore, unitOfWork: unitOfWork),
];
