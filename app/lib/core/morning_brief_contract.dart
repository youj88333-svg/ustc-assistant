import 'dart:async';

import 'calendar_contract.dart';
import 'morning_notice_contract.dart';

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
  });
  final bool enabled, busy;
  final MorningFacts? facts;
  final MorningBrief? brief;
  final MorningBriefPhase phase;
  final String text;
  final String? failure;
}
