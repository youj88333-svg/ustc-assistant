part of 'jw_store.dart';

bool _isReminderChange(AgentLocalChange change) =>
    change is AgentReminderChange ||
    change is AgentNotificationPreferencesPatch;

extension _AgentReminderStorage on LocalCalendarStore {
  void _validateReminderUndo(Map<String, dynamic> value) {
    if (value['target'] != null ||
        value['task'] != null ||
        value['relation'] != null) {
      throw const FormatException();
    }
    final before = value['before'] as List;
    if (value['action'] == 'reminder-pair') {
      if (before.length != 4 ||
          before[0] is! String ||
          before[1] is! int ||
          before[1] <= 0 ||
          before[2] is! int ||
          before[2] < -1 ||
          before[2] > 521700 ||
          before[3] != null && before[3] is! String) {
        throw const FormatException();
      }
      final kind = ReminderKind.values.byName(before[0] as String);
      if (kind != ReminderKind.personal && before[2] != 0) {
        throw const FormatException();
      }
      if (before[3] != null) {
        final pair = _db.features._decodePair(jsonDecode(before[3] as String));
        pair.validate(allDay: pair.supports(allDay: true));
      }
    } else {
      if (before.length != 5 ||
          before.take(3).any((v) => v is! int || (v != 0 && v != 1)) ||
          before[3] is! String ||
          before[4] is! String) {
        throw const FormatException();
      }
      _db.features
          ._decodePair(jsonDecode(before[3] as String))
          .validate(allDay: false);
      _db.features
          ._decodePair(jsonDecode(before[4] as String))
          .validate(allDay: true);
    }
    final guards = value['guards'] as List;
    if (!guards.any((g) => g[0] == 'reminders' && g[1] == 1) ||
        guards.length != (value['action'] == 'reminder-pair' ? 2 : 1)) {
      throw const FormatException();
    }
  }

  Future<Set<(String, int)>> _reminderUndoKeys(
    Map<String, dynamic> value,
  ) async {
    final keys = <(String, int)>{('reminders', 1)};
    if (value['action'] == 'reminder-pair') {
      final before = value['before'] as List;
      final kind = ReminderKind.values.byName(before[0] as String);
      keys.add(
        kind == ReminderKind.taskDeadline
            ? ('task', before[1] as int)
            : await _aggregateKey(
                CalendarIdentity(
                  CalendarKind.values.byName(kind.name),
                  before[1] as int,
                  ordinal: before[2] == -1 ? 0 : before[2] as int,
                ),
              ),
      );
    }
    return keys;
  }

  Future<void> _validateReminderChange(
    CalendarContext context,
    AgentLocalChange change, {
    required List<AgentLocalChange> planChanges,
  }) async {
    if (change is AgentReminderChange) {
      if (change.target.context != context) {
        throw const CalendarFailure(CalendarFailureCode.staleReference);
      }
      final allDay = await _finalReminderAllDay(change, planChanges);
      change.pair?.validate(allDay: allDay);
    } else if (change is AgentNotificationPreferencesPatch) {
      if (change.enabled == null &&
          change.privateDisplay == null &&
          change.morningEnabled == null &&
          change.timed == null &&
          change.allDay == null) {
        throw const CalendarFailure(CalendarFailureCode.invalidInput);
      }
      change.timed?.validate(allDay: false);
      change.allDay?.validate(allDay: true);
    }
  }

  /// Reminder changes take effect after the batch's business changes. Retain
  /// an occurrence replacement's own shape when its parent series is changed.
  Future<bool> _finalReminderAllDay(
    AgentReminderChange reminder,
    List<AgentLocalChange> changes,
  ) async {
    final target = reminder.target;
    final current = await _db.features._targetAllDay(target, reminder.series);
    if (target.kind != ReminderKind.personal) return current;
    final identity = CalendarIdentity(
      CalendarKind.personal,
      target.localId,
      ordinal: target.ordinal,
    );
    final snapshot = await _snapshot(targets: {identity});
    var seriesAllDay = snapshot.personal.single.draft.allDay;
    bool? occurrenceAllDay = snapshot.overrides
        .where(
          (o) => o.localId == target.localId && o.ordinal == target.ordinal,
        )
        .firstOrNull
        ?.replacement
        ?.allDay;
    for (final change in changes) {
      if (change is AgentPersonalPatch &&
          change.target.identity.localId == target.localId) {
        if (change.entireSeries) {
          seriesAllDay = change.allDay ?? seriesAllDay;
        } else if (change.target.identity == identity) {
          occurrenceAllDay = change.allDay ?? occurrenceAllDay ?? seriesAllDay;
        }
      } else if (change is AgentCalendarChange) {
        final intent = change.intent;
        if (intent is UpdatePersonalSeries &&
            intent.target.identity.localId == target.localId) {
          seriesAllDay = intent.draft.allDay;
        } else if (intent is UpdatePersonalOccurrence &&
            intent.target.identity == identity) {
          occurrenceAllDay = intent.replacement.allDay;
        } else if (intent is DeletePersonalSeries &&
            intent.target.identity.localId == target.localId) {
          throw const CalendarFailure(CalendarFailureCode.invalidInput);
        }
      }
    }
    return reminder.series ? seriesAllDay : occurrenceAllDay ?? seriesAllDay;
  }

  Future<ReminderTarget> _rebaseReminderTarget(
    ReminderTarget target, {
    required bool series,
  }) async {
    if (target.kind == ReminderKind.taskDeadline) {
      return ReminderTarget.task(
        await _currentTaskRef(
          TaskReference(target.context, target.localId, target.version),
        ),
      );
    }
    return ReminderTarget.calendar(
      await _currentEventRef(
        CalendarReference(
          target.context,
          CalendarIdentity(
            CalendarKind.values.byName(target.kind.name),
            target.localId,
            // A valid series edit may remove the originally selected occurrence.
            // Its original reference was checked before any batch writes; bind
            // the series rule to the surviving anchor after those writes.
            ordinal: series ? 0 : target.ordinal,
          ),
          target.version,
        ),
      ),
    );
  }

  /// The same transaction owns the local plan, inverse, receipt and desired OS
  /// input. Native calls never occur in this method.
  Future<Map<String, dynamic>> _applyReminderChange(
    CalendarContext context,
    AgentLocalChange change,
  ) async {
    final before = <Object?>[];
    final keys = <(String, int)>[('reminders', 1)];
    final String action;
    if (change is AgentReminderChange) {
      action = 'reminder-pair';
      final target = await _rebaseReminderTarget(
        change.target,
        series: change.series,
      );
      before.addAll([
        target.kind.name,
        target.localId,
        change.series ? -1 : target.ordinal,
        await _db.features._overrideJson(target, change.series),
      ]);
      keys.add(
        target.kind == ReminderKind.taskDeadline
            ? ('task', target.localId)
            : await _aggregateKey(
                CalendarIdentity(
                  CalendarKind.values.byName(target.kind.name),
                  target.localId,
                  ordinal: target.ordinal,
                ),
              ),
      );
      await _db.features._writePair(target, change.pair, change.series);
      await _db.customStatement(
        'UPDATE m6_state SET revision=revision+1 WHERE singleton=1',
      );
    } else if (change is AgentNotificationPreferencesPatch) {
      action = 'notification-preferences';
      final row = await _db.features._state();
      before.addAll([
        row.read<int>('reminders_enabled'),
        row.read<int>('morning_enabled'),
        row.read<int>('private_display'),
        row.read<String>('timed_json'),
        row.read<String>('all_day_json'),
      ]);
      final actual = await _db.features._readSettings();
      await _writeAgentNotificationPreferences(
        actual.preferences.copyWith(
          enabled: change.enabled,
          privateDisplay: change.privateDisplay,
          morningEnabled: change.morningEnabled,
          timed: change.timed,
          allDay: change.allDay,
        ),
      );
    } else {
      throw const CalendarFailure(CalendarFailureCode.invalidInput);
    }
    return {
      'v': 1,
      'action': action,
      'context': [context.owner, context.resetEpoch, context.agendaEpoch],
      'before': before,
      'target': null,
      'task': null,
      'guards': [
        for (final key in keys) [key.$1, key.$2, await _aggregateVersion(key)],
      ],
      'relation': null,
    };
  }

  Future<void> _writeAgentNotificationPreferences(
    ReminderPreferences preferences,
  ) async {
    preferences.timed.validate(allDay: false);
    preferences.allDay.validate(allDay: true);
    final actual = await _db.features._readSettings();
    final morningChanged =
        preferences.morningEnabled != actual.preferences.morningEnabled;
    await _db.customStatement(
      'UPDATE m6_state SET revision=revision+1,reminders_enabled=?,morning_enabled=?,private_display=?,timed_json=?,all_day_json=?,brief_epoch=brief_epoch+? WHERE singleton=1',
      [
        preferences.enabled ? 1 : 0,
        preferences.morningEnabled ? 1 : 0,
        preferences.privateDisplay ? 1 : 0,
        jsonEncode(preferences.timed.canonical),
        jsonEncode(preferences.allDay.canonical),
        morningChanged ? 1 : 0,
      ],
    );
    if (morningChanged) {
      await _db.customStatement(
        "UPDATE m6_briefs SET ticket=NULL,phase='interrupted',summary='' WHERE ticket IS NOT NULL",
      );
    }
  }

  Future<String> _describeReminderChange(AgentLocalChange change) async {
    if (change is AgentNotificationPreferencesPatch) {
      return [
        if (change.enabled != null)
          change.enabled! ? '开启系统日程提醒，可在通知和锁屏显示' : '关闭系统日程提醒',
        if (change.privateDisplay != null)
          change.privateDisplay! ? '通知隐藏名称和地点' : '通知可显示名称和地点（含锁屏）',
        if (change.morningEnabled != null)
          change.morningEnabled!
              ? '开启自动晨报：读取公开通知，将今日基本日程和通知发送到已同意的模型服务并产生用量；模型不可用时保留本地事实'
              : '关闭自动晨报',
        if (change.timed != null)
          '定时日程与任务截止默认：${_describeReminderPair(change.timed!)}',
        if (change.allDay != null)
          '全天日程默认：${_describeReminderPair(change.allDay!)}',
        '其他设置保留；单条日程覆盖不被改写，Windows是否允许通知由系统设置决定',
      ].join('；');
    }
    final item = change as AgentReminderChange;
    final target = item.target;
    final String title;
    if (target.kind == ReminderKind.taskDeadline) {
      title = (await _agentTaskRecord(
        TaskReference(target.context, target.localId, target.version),
      )).draft.title;
    } else {
      final identity = CalendarIdentity(
        CalendarKind.values.byName(target.kind.name),
        target.localId,
        ordinal: target.ordinal,
      );
      final snapshot = await _snapshot(targets: {identity});
      title = const CalendarProjection().occurrence(snapshot, identity)!.title;
    }
    return '「$title」${item.series
            ? "整组个人日程"
            : target.kind == ReminderKind.taskDeadline
            ? "任务截止"
            : "仅本次"}：'
        '${item.pair == null ? "恢复继承提醒规则" : _describeReminderPair(item.pair!)}；'
        '只保存提醒规则，不改日程时间、出勤或任务状态，不自动开启系统提醒';
  }
}

String _describeReminderPair(ReminderPair pair) {
  String rule(ReminderRule value) => switch (value.kind) {
    ReminderRuleKind.none => '不提醒',
    ReminderRuleKind.before =>
      value.minutesBefore == 0 ? '开始/截止时提醒' : '提前${value.minutesBefore}分钟',
    ReminderRuleKind.dayTime =>
      '${value.dayOffset == 0
              ? "当天"
              : value.dayOffset < 0
              ? "提前${-value.dayOffset}天"
              : "之后${value.dayOffset}天"}'
          '${(value.minuteOfDay ~/ 60).toString().padLeft(2, "0")}:${(value.minuteOfDay % 60).toString().padLeft(2, "0")}',
  };
  return '第一次${rule(pair.first)}，第二次${rule(pair.second)}（北京时间）';
}
