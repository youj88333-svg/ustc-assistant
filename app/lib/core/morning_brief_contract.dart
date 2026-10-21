import 'dart:async';
import 'dart:convert';

import 'calendar_contract.dart';
import 'morning_notice_contract.dart';

/// Sections remain separate until coverage is known. Raw model text is never
/// displayed while streaming, and an unverified notice conclusion is omitted.
final class MorningSummary {
  const MorningSummary({
    required this.today,
    required this.notices,
    this.factsOnly = false,
  });
  final String today, notices;
  final bool factsOnly;

  factory MorningSummary.fromModel(String text) {
    final raw = jsonDecode(text.trim());
    if (raw is! Map<String, dynamic> ||
        raw.length != 2 ||
        raw['today'] is! String ||
        raw['notices'] is! String ||
        (raw['today'] as String).trim().isEmpty ||
        (raw['today'] as String).runes.length > 1000 ||
        (raw['notices'] as String).runes.length > 1000) {
      throw const FormatException('morning_summary_shape');
    }
    return MorningSummary(
      today: (raw['today'] as String).trim(),
      notices: (raw['notices'] as String).trim(),
    );
  }

  String encode() => jsonEncode({
    'kind': factsOnly ? 'morning-facts-v1' : 'morning-summary-v2',
    'today': today,
    'notices': notices,
  });
}

String morningSummaryForDisplay(String raw, MorningNoticeBatch? batch) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  try {
    final encoded = jsonDecode(trimmed);
    if (encoded is Map<String, dynamic> &&
        const {
          'morning-summary-v2',
          'morning-facts-v1',
        }.contains(encoded['kind'])) {
      // Incomplete-source prose comes only from the host's local fact
      // formatter. Even the model's "today" field is not a semantic proof.
      if (batch?.complete != true && encoded['kind'] != 'morning-facts-v1') {
        return '';
      }
      final summary = MorningSummary.fromModel(
        jsonEncode({'today': encoded['today'], 'notices': encoded['notices']}),
      );
      return [
        summary.today,
        if (batch?.complete == true && summary.notices.isNotEmpty)
          summary.notices,
      ].join('\n\n');
    }
  } on Object {
    // Legacy prose can be reused only with complete notice coverage. Never
    // try to remove sentences by keywords, which cannot prove their meaning.
  }
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) return '';
  return batch?.complete == true ? trimmed : '';
}

String morningFactsSummary(MorningFacts facts) {
  String time(DateTime value) {
    final b = value.toUtc().add(const Duration(hours: 8));
    return '${b.hour.toString().padLeft(2, '0')}:${b.minute.toString().padLeft(2, '0')}';
  }

  final courses = facts.agenda.where((item) => item.kind == 'course').toList();
  final notGoing = courses.where((item) => item.state == 'skip').length;
  final planned = facts.agenda
      .where(
        (item) => !const {
          'skip',
          'skipped',
          'done',
          'completed',
        }.contains(item.state),
      )
      .toList();
  final lines = <String>[
    if (facts.overdueTasks > 0) '还有 ${facts.overdueTasks} 件事已经过了截止时间。',
    if (facts.tasks.isNotEmpty) '有 ${facts.tasks.length} 件事今天到期。',
    if (facts.conflicts > 0) '今天有 ${facts.conflicts} 处安排撞了时间，需要留意。',
    if (facts.agenda.isEmpty) '今天的日程里暂时没查到安排。',
    if (courses.isNotEmpty)
      notGoing == courses.length
          ? '今天这 ${courses.length} 节课你都不打算去。'
          : notGoing > 0
          ? '今天有 ${courses.length} 节课，其中 $notGoing 节你不打算去。'
          : '今天有 ${courses.length} 节课。',
    for (final item in planned.take(3))
      '${item.allDay ? '全天' : '${time(item.start)}–${time(item.end)}'} '
          '**${item.title}**${item.location.isEmpty ? '' : '，${item.location}'}'
          '${item.state == 'planned' ? '' : '（${item.planDescription}）'}。',
    for (final item
        in facts.agenda
            .where(
              (item) =>
                  item.kind != 'course' &&
                  const {
                    'skip',
                    'skipped',
                    'done',
                    'completed',
                  }.contains(item.state),
            )
            .take(3))
      '${item.title}：${item.planDescription}。',
    if (planned.length > 3) '其余安排可在日程页查看。',
    if (!facts.complete) '今天的安排还没读全，可能有遗漏。',
    if (!facts.hasSchoolImports) '还没导入学校日程，今天有没有课暂时说不准。',
  ];
  // Bound the fallback just like model-derived sections; no private fields.
  final text = lines.join('\n');
  return String.fromCharCodes(text.runes.take(1000));
}

enum MorningBriefPhase {
  idle,
  facts,
  notices,
  waiting,
  generating,
  ready,
  interrupted,
  failed,
  cleared,
}

final class MorningAgendaItem {
  const MorningAgendaItem({
    required this.title,
    required this.location,
    required this.start,
    required this.end,
    required this.allDay,
    required this.kind,
    required this.state,
  });
  final String title, location, kind, state;
  final DateTime start, end;
  final bool allDay;

  /// Meaning for prose generation, derived from the existing immutable facts.
  /// `planned` combines several attendance choices, so it must stay neutral.
  String get planDescription => switch (state) {
    'skip' => switch (kind) {
      'course' => '你不打算去上这节课',
      'exam' => '你不打算参加这场考试',
      'young' => '你不打算参加这次活动',
      _ => '你不打算参加这次安排',
    },
    'skipped' => kind == 'planBlock' ? '这段时间不按原计划做了' : '这次不按原计划做了',
    'done' || 'completed' => kind == 'planBlock' ? '这段安排已经做过了' : '这件事已经做完了',
    'planned' => kind == 'planBlock' ? '留出了这段时间来做这件事' : '仍在今天原定的安排里',
    _ => '这次的安排还不确定',
  };

  String get kindDescription => switch (kind) {
    'course' => '课程',
    'exam' => '考试',
    'young' => '二课活动',
    'personal' => '个人安排',
    'planBlock' => '为任务留出的时间',
    _ => '安排',
  };
  List<Object> get canonical => [
    title,
    location,
    start.millisecondsSinceEpoch,
    end.millisecondsSinceEpoch,
    allDay,
    kind,
    state,
  ];
}

final class MorningTaskItem {
  const MorningTaskItem(this.title, this.deadline);
  final String title;
  final DateTime deadline;
  List<Object> get canonical => [title, deadline.millisecondsSinceEpoch];
}

final class MorningFacts {
  MorningFacts({
    required this.context,
    required this.day,
    required this.digest,
    required List<MorningAgendaItem> agenda,
    required List<MorningTaskItem> tasks,
    required this.conflicts,
    required this.overdueTasks,
    required this.complete,
    required this.hasSchoolImports,
  }) : agenda = List.unmodifiable(agenda),
       tasks = List.unmodifiable(tasks);
  final CalendarContext context;
  final DateTime day;
  final String digest;
  final List<MorningAgendaItem> agenda;
  final List<MorningTaskItem> tasks;
  final int conflicts, overdueTasks;
  final bool complete, hasSchoolImports;
  @override
  String toString() => 'MorningFacts';
}

final class MorningBrief {
  const MorningBrief({
    required this.day,
    required this.phase,
    required this.factDigest,
    required this.autoAttempts,
    this.notices,
    this.summary = '',
    this.failure,
    this.inputTokens,
    this.outputTokens,
  });
  final DateTime day;
  final MorningBriefPhase phase;
  final String factDigest, summary;
  final String? failure;
  final int autoAttempts;
  final int? inputTokens, outputTokens;
  final MorningNoticeBatch? notices;
  @override
  String toString() => 'MorningBrief';
}

final class MorningBriefTicket {
  const MorningBriefTicket({
    required this.context,
    required this.day,
    required this.epoch,
    required this.id,
    required this.factDigest,
    required this.manual,
  });
  final CalendarContext context;
  final DateTime day;
  final int epoch;
  final String id, factDigest;
  final bool manual;
  @override
  String toString() => 'MorningBriefTicket';
}

abstract interface class MorningBriefDataPort {
  Stream<int> get changes;
  Future<MorningFacts> morningFacts(DateTime day);
  Future<MorningBrief?> readMorningBrief(DateTime day);
  Future<MorningBriefTicket?> beginMorningBrief(
    DateTime day, {
    bool manual = false,
  });
  Future<bool> beginMorningModelAttempt(MorningBriefTicket ticket);
  Future<void> saveMorningBrief(
    MorningBriefTicket ticket, {
    required MorningBriefPhase phase,
    MorningNoticeBatch? notices,
    String? summary,
    String? failure,
    int? inputTokens,
    int? outputTokens,
  });
  Future<void> ensureMorningTicket(MorningBriefTicket ticket);
  Future<void> clearMorningBriefs();
}

final class MorningRuntimeView {
  const MorningRuntimeView({
    this.enabled = false,
    this.busy = false,
    this.facts,
    this.brief,
    this.phase = MorningBriefPhase.idle,
    this.text = '',
    this.failure,
    this.summaryOutdated = false,
  });
  final bool enabled, busy;
  final MorningFacts? facts;
  final MorningBrief? brief;
  final MorningBriefPhase phase;
  final String text;
  final String? failure;

  /// Runtime projection only. The persisted summary remains bound to its old
  /// facts and cannot be reused until an explicit generation succeeds.
  final bool summaryOutdated;

  bool get canRegenerate =>
      summaryOutdated ||
      phase == MorningBriefPhase.facts ||
      phase == MorningBriefPhase.cleared ||
      phase == MorningBriefPhase.failed ||
      phase == MorningBriefPhase.interrupted ||
      failure != null ||
      (brief?.notices != null && !brief!.notices!.complete);
}
