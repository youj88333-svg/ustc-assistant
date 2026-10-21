part of 'jw_store.dart';

const _agentActionSchema = <String>[
  '''CREATE TABLE agent_actions (
    action_id TEXT PRIMARY KEY, run_id TEXT NOT NULL, kind TEXT NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('proposed','rejected','committed','interrupted','failed')),
    title TEXT NOT NULL CHECK(length(title)<=500), details_json TEXT NOT NULL CHECK(length(details_json)<=65536),
    warning TEXT NOT NULL CHECK(length(warning)<=4000), committed_count INTEGER NOT NULL CHECK(committed_count>=0),
    created_at INTEGER NOT NULL)''',
  'CREATE INDEX agent_actions_run ON agent_actions(run_id,created_at,action_id)',
  '''CREATE TABLE agenda_plan_receipts (
    operation_id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL,
    revision INTEGER NOT NULL, committed_count INTEGER NOT NULL,
    committed_at INTEGER NOT NULL, undo_id TEXT, result_json TEXT NOT NULL)''',
  '''CREATE TABLE agenda_plan_audit (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT, action TEXT NOT NULL CHECK(action IN ('plan','undo','preferences','source')),
    item_count INTEGER NOT NULL, committed_at INTEGER NOT NULL)''',
  '''CREATE TABLE agent_preferences (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL CHECK(revision>=0),
    value_json TEXT NOT NULL CHECK(length(value_json)<=8192))''',
  'INSERT INTO agent_preferences VALUES (1,0,\'[[1,2,3,4,5,6,7],420,1439,60,10,[]]\')',
];

final class _PreparedAgentPlan {
  _PreparedAgentPlan(this.plan, this.fingerprint);
  final AgentLocalPlan plan;
  final String fingerprint;
  bool revoked = false;
}

extension _AgentPlanStorage on LocalCalendarStore {
  List<CalendarReference> _planIntentEvents(CalendarIntent intent) =>
      switch (intent) {
        UpdatePersonalSeries(:final target) ||
        UpdatePersonalOccurrence(:final target) ||
        SetPersonalOccurrenceState(:final target) ||
        DeletePersonalSeries(:final target) ||
        UpdateSchoolAnnotation(:final target) ||
        UpdatePlanBlock(:final target) ||
        SetPlanBlockStatus(:final target) ||
        DeletePlanBlock(:final target) => [target],
        SaveCalendarRelation(:final left, :final right) => [left, right],
        _ => [],
      };

  Future<AgentPlanPreview> _previewLocalPlan(
    List<AgentLocalChange> changes,
  ) async {
    final day = beijingDay(_db._clock.nowUtc);
    final query = CalendarQuery(
      firstDay: day,
      endDayExclusive: day.add(const Duration(days: 31)),
    );
    final base = await _snapshot(query: query);
    final targets = <CalendarIdentity>{
      for (final change in changes)
        if (change is AgentCalendarChange)
          ..._planIntentEvents(change.intent).map((r) => r.identity),
      for (final change in changes)
        if (change is AgentPersonalPatch)
          change.target.identity
        else if (change is AgentBlockPatch)
          change.target.identity,
    };
    final target = await _snapshot(targets: targets);
    final merged = CalendarSnapshot(
      context: base.context,
      revision: base.revision,
      personal: base.personal,
      overrides: base.overrides,
      relations: base.relations,
      school: {
        for (final e in [...base.school, ...target.school])
          jsonEncode(e.reference.identity.canonical): e,
      }.values.toList(),
      planBlocks: {
        for (final e in [...base.planBlocks, ...target.planBlocks])
          jsonEncode(e.reference.identity.canonical): e,
      }.values.toList(),
    );
    return previewAgentPlan(merged, changes, _db._clock.nowUtc);
  }

  bool _planTimesWithinPreview(
    List<AgentLocalChange> changes,
    AgentPlanPreview preview,
  ) {
    final first = preview.windowFirstDayBeijing.subtract(
      const Duration(hours: 8),
    );
    final end = preview.windowEndDayExclusiveBeijing.subtract(
      const Duration(hours: 8),
    );
    bool block(PlanBlockDraft d) =>
        !d.startsAtUtc.isBefore(first) && !d.endsAtUtc.isAfter(end);
    bool personal(PersonalEventDraft d) =>
        d.allDay ||
        (!d.start.isBefore(first) &&
            !d.end.isAfter(end) &&
            (!d.weekly ||
                d.untilDay != null &&
                    !d.untilDay!.isAfter(
                      preview.windowEndDayExclusiveBeijing.subtract(
                        const Duration(days: 1),
                      ),
                    )));
    return changes.every(
      (change) => switch (change) {
        AgentDependentBlock(:final draft) => block(draft),
        AgentCalendarChange(:final intent) => switch (intent) {
          CreatePlanBlock(:final draft) ||
          UpdatePlanBlock(:final draft) => block(draft),
          CreatePersonalEvent(:final draft) ||
          UpdatePersonalSeries(:final draft) => personal(draft),
          UpdatePersonalOccurrence(:final replacement) => personal(replacement),
          _ => true,
        },
        _ => true,
      },
    );
  }

  String _previewDescription(AgentPlanPreview preview) {
    final window =
        '${preview.windowFirstDayBeijing.toIso8601String().substring(0, 10)} 至 ${preview.windowEndDayExclusiveBeijing.toIso8601String().substring(0, 10)}（结束日不含，北京时间）';
    final overlaps = preview.actionConflicts
        .map(
          (c) =>
              '${c.leftName} / ${c.rightName}：${c.statusLabel} ${c.overlapStartBeijing}—${c.overlapEndBeijing}',
        )
        .join('；');
    return '预演范围 $window。${overlaps.isEmpty ? "范围内未发现方案引起的定时冲突。" : "方案相关重叠：$overlaps。"}${preview.conflictSummaryTruncated ? "仅显示前五组。" : ""}${preview.complete ? "" : "预演覆盖不完整；不能推断其他时段无冲突。"}${preview.warnings.map((w) => w.message).join()}';
  }

  Future<List<String>> _taskPlanningWarnings(
    List<AgentLocalChange> changes, {
    required bool hard,
  }) async {
    final drafts = <String, TaskDraft>{};
    final blocks = <String, (String, DateTime, DateTime)>{};
    final newKeys = <String>{};
    var newBlock = 0;
    Future<String> task(TaskReference reference) async {
      final key = 'task:${reference.localId}';
      if (!drafts.containsKey(key)) {
        drafts[key] = (await _agentTaskRecord(reference)).draft;
      }
      return key;
    }

    for (final change in changes) {
      if (change is AgentCreateTask) {
        final key = 'new:${change.localKey}';
        drafts[key] = change.draft;
        newKeys.add(key);
      } else if (change is AgentTaskPatch) {
        final key = await task(change.target);
        final old = drafts[key]!;
        drafts[key] = TaskDraft(
          title: change.title ?? old.title,
          deadlineAtUtc: change.clearDeadline
              ? null
              : change.deadlineUtc ?? old.deadlineAtUtc,
          estimatedMinutes: change.clearEstimate
              ? null
              : change.estimatedMinutes ?? old.estimatedMinutes,
        );
      } else if (change is AgentDependentBlock) {
        blocks['new:${newBlock++}'] = (
          'new:${change.taskKey}',
          change.draft.startsAtUtc,
          change.draft.endsAtUtc,
        );
      } else if (change is AgentBlockPatch) {
        final old = await _blockByRef(change.target);
        final key = 'block:${change.target.identity.localId}';
        final before =
            blocks[key] ??
            (await task(old.task), old.draft.startsAtUtc, old.draft.endsAtUtc);
        blocks[key] = (
          before.$1,
          change.startUtc ?? before.$2,
          change.endUtc ?? before.$3,
        );
      } else if (change is AgentCalendarChange) {
        final i = change.intent;
        if (i is UpdateTask) {
          drafts[await task(i.target)] = i.draft;
        } else if (i is CreatePlanBlock) {
          blocks['new:${newBlock++}'] = (
            await task(i.task),
            i.draft.startsAtUtc,
            i.draft.endsAtUtc,
          );
        } else if (i is UpdatePlanBlock) {
          final old = await _blockByRef(i.target);
          blocks['block:${i.target.identity.localId}'] = (
            await task(old.task),
            i.draft.startsAtUtc,
            i.draft.endsAtUtc,
          );
        } else if (i is DeletePlanBlock) {
          blocks.remove('block:${i.target.identity.localId}');
        }
      }
    }
    final warnings = <String>[];
    for (final entry in blocks.values) {
      final draft = drafts[entry.$1];
      final deadline = draft?.deadlineAtUtc;
      if (deadline != null && entry.$3.isAfter(deadline)) {
        if (hard) throw const CalendarFailure(CalendarFailureCode.invalidInput);
        warnings.add('任务「${draft!.title}」的本方案时间块晚于其截止；请核对截止与安排。');
      }
    }
    for (final key in newKeys) {
      final draft = drafts[key]!;
      final estimated = draft.estimatedMinutes;
      final assigned = blocks.values
          .where((b) => b.$1 == key)
          .fold<int>(0, (sum, b) => sum + b.$3.difference(b.$2).inMinutes);
      if (estimated != null && assigned < estimated) {
        warnings.add(
          '新任务「${draft.title}」预计 $estimated 分钟，本方案安排 $assigned 分钟，尚未覆盖全部预计时长。',
        );
      }
    }
    return warnings.take(3).toList();
  }

  Future<void> _verifyAgentPlan(
    _PreparedAgentPlan prepared, {
    bool revision = true,
    bool reminders = true,
  }) async {
    if (prepared.revoked ||
        _closed ||
        _db.agent._revokedActionRuns.contains(prepared.plan.ticket.runId) ||
        !identical(_agentPlans[prepared.plan.id], prepared)) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    final plan = prepared.plan;
    if (!_db._clock.nowUtc.isBefore(plan.expiresAtUtc)) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    await _db.agent._requireTicket(plan.ticket);
    await _guard(plan.context);
    if (revision &&
        (await _agendaState()).read<int>('revision') != plan.revision) {
      throw const CalendarFailure(CalendarFailureCode.staleReference);
    }
    if (plan.preferencesRevision != null &&
        (await _db
                    .customSelect(
                      'SELECT revision FROM agent_preferences WHERE singleton=1',
                    )
                    .getSingle())
                .read<int>('revision') !=
            plan.preferencesRevision) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    if (reminders &&
        plan.reminderRevision != null &&
        (await _db.features._state()).read<int>('revision') !=
            plan.reminderRevision) {
      throw const CalendarFailure(CalendarFailureCode.staleReference);
    }
    if (prepared.fingerprint !=
        fingerprint([
          plan.context.owner,
          plan.context.resetEpoch,
          plan.context.agendaEpoch,
          plan.revision,
          plan.requireFree,
          plan.preferencesRevision,
          plan.reminderRevision,
          plan.changes.map((c) => c.canonical).toList(),
        ])) {
      throw const CalendarFailure(CalendarFailureCode.idempotencyConflict);
    }
    // Stop revokes synchronously while a queued SQL cancellation waits. Check
    // once more after every asynchronous authority/revision read has finished.
    if (prepared.revoked ||
        _db.agent._revokedActionRuns.contains(plan.ticket.runId)) {
      throw const AgentFailure(AgentFailureCode.cancelled);
    }
  }

  Future<AgentLocalPlan> _prepareAgentPlan(
    AgentRunTicket ticket,
    CalendarContext context,
    int revision,
    List<AgentLocalChange> changes, {
    bool requireFree = false,
    int? preferencesRevision,
  }) => _serial(() async {
    final plan = await _db.transaction(() async {
      await _db.agent._requireTicket(ticket);
      await _guard(context);
      if (changes.isEmpty ||
          changes.length > 20 ||
          (await _agendaState()).read<int>('revision') != revision) {
        throw const CalendarFailure(CalendarFailureCode.invalidInput);
      }
      _agentPlans.removeWhere(
        (_, p) =>
            p.revoked ||
            _db.agent._revokedActionRuns.contains(p.plan.ticket.runId) ||
            !_db._clock.nowUtc.isBefore(p.plan.expiresAtUtc),
      );
      if (_agentPlans.length >= 128) {
        throw const CalendarFailure(CalendarFailureCode.limitExceeded);
      }
      final normalized = <AgentLocalChange>[];
      final reminderRevision = changes.any(_isReminderChange)
          ? (await _db.features._state()).read<int>('revision')
          : null;
      final keys = <String>{};
      final deleted = <(String, int)>{};
      final deletedBlocks = <CalendarIdentity>{};
      final removedPairs = <String>{};
      var inverseBytes = 0;
      var largestStepBytes = 0;
      for (final change in changes) {
        AgentText.requireSafe(
          jsonEncode(change.canonical),
          maxCharacters: 65536,
        );
        final value = await _normalizeAgentChange(context, change);
        if (value is AgentCreateTask) {
          if (!RegExp(
                r'^[a-zA-Z][a-zA-Z0-9_-]{0,31}$',
              ).hasMatch(value.localKey) ||
              !keys.add(value.localKey)) {
            throw const CalendarFailure(CalendarFailureCode.invalidInput);
          }
          _validateTaskDraft(value.draft);
        } else if (value is AgentDependentBlock) {
          if (!keys.contains(value.taskKey)) {
            throw const CalendarFailure(CalendarFailureCode.invalidInput);
          }
          _validateBlockDraft(value.draft);
        } else if (_isReminderChange(value)) {
          await _validateReminderChange(context, value, planChanges: changes);
          if (value is AgentReminderChange) {
            final target = value.target;
            final key = target.kind == ReminderKind.taskDeadline
                ? ('task', target.localId)
                : await _aggregateKey(
                    CalendarIdentity(
                      CalendarKind.values.byName(target.kind.name),
                      target.localId,
                      ordinal: target.ordinal,
                    ),
                  );
            if (deleted.contains(key) ||
                target.kind == ReminderKind.planBlock &&
                    deletedBlocks.contains(
                      CalendarIdentity(CalendarKind.planBlock, target.localId),
                    )) {
              throw const CalendarFailure(CalendarFailureCode.invalidInput);
            }
          }
          inverseBytes += 1024;
        } else if (value is AgentCalendarChange) {
          final intent = value.intent;
          _validateIntent(context, intent);
          await _verifyPlanIntent(context, intent);
          final aggregateKeys = await _planIntentAggregates(intent);
          if (aggregateKeys.any(deleted.contains) ||
              _planIntentEvents(
                intent,
              ).any((r) => deletedBlocks.contains(r.identity))) {
            throw const CalendarFailure(CalendarFailureCode.invalidInput);
          }
          if (intent is DeleteTask || intent is DeletePersonalSeries) {
            deleted.addAll(aggregateKeys);
          }
          if (intent is DeletePlanBlock) {
            deletedBlocks.add(intent.target.identity);
          }
          if (intent is SaveCalendarRelation) {
            final pair = [
              jsonEncode(intent.left.identity.canonical),
              jsonEncode(intent.right.identity.canonical),
            ]..sort();
            if (removedPairs.contains(jsonEncode(pair))) {
              throw const CalendarFailure(CalendarFailureCode.invalidInput);
            }
          } else if (intent is DeleteCalendarRelation) {
            final relation = (await _snapshot()).relations
                .where((r) => r.reference.localId == intent.target.localId)
                .single;
            final pair = [
              jsonEncode(relation.left.canonical),
              jsonEncode(relation.right.canonical),
            ]..sort();
            removedPairs.add(jsonEncode(pair));
          }
          if (intent is UndoCalendarWrite) {
            if (changes.length != 1) {
              throw const CalendarFailure(CalendarFailureCode.invalidInput);
            }
          } else {
            final bytes = utf8
                .encode(jsonEncode(await _beforeUndo(intent)))
                .length;
            inverseBytes += bytes;
            largestStepBytes = max(largestStepBytes, bytes);
          }
        }
        largestStepBytes = max(
          largestStepBytes,
          utf8.encode(jsonEncode(value.canonical)).length,
        );
        normalized.add(value);
      }
      // Reserve capacity for final guards, references and normalized metadata.
      if (max(inverseBytes, largestStepBytes * changes.length) +
              utf8
                  .encode(
                    jsonEncode(normalized.map((c) => c.canonical).toList()),
                  )
                  .length >
          48000) {
        throw const CalendarFailure(CalendarFailureCode.limitExceeded);
      }
      final id = JwStore._randomHexId('agent-action-');
      final lines = <String>[];
      for (var i = 0; i < normalized.length; i++) {
        lines.add(
          await _describeAgentChange(normalized[i], original: changes[i]),
        );
      }
      final undoOnly =
          normalized.singleOrNull is AgentCalendarChange &&
          (normalized.single as AgentCalendarChange).intent
              is UndoCalendarWrite;
      final preview = undoOnly ? null : await _previewLocalPlan(changes);
      if (requireFree &&
          (preview == null ||
              preview.freeConstraintViolated != false ||
              !_planTimesWithinPreview(normalized, preview))) {
        throw const CalendarFailure(CalendarFailureCode.invalidInput);
      }
      final previewWarning = preview == null
          ? ''
          : _previewDescription(preview);
      final taskWarnings = undoOnly
          ? const <String>[]
          : await _taskPlanningWarnings(changes, hard: requireFree);
      final view = AgentActionView(
        id: id,
        kind: undoOnly ? AgentActionKind.undo : AgentActionKind.localPlan,
        status: AgentActionStatus.proposed,
        title: undoOnly ? '撤销最近一次本地修改' : '本地修改方案',
        details: lines,
        warning:
            '批准后将一次提交上述全部变化。学校资料未自动刷新。$previewWarning${taskWarnings.join()}'
            '${reminderRevision == null ? "" : "提醒规则保存后由系统异步登记；保存成功不代表系统已接收或保证投递。"}',
      );
      final proposed = AgentLocalPlan(
        id: id,
        ticket: ticket,
        context: context,
        revision: revision,
        expiresAtUtc: _db._clock.nowUtc.add(const Duration(hours: 24)),
        changes: changes,
        view: view,
        requireFree: requireFree,
        preferencesRevision: preferencesRevision,
        reminderRevision: reminderRevision,
      );
      await _db.agent._saveAction(ticket, view);
      await _db.onAgentCheckpoint?.call();
      await _db.agent._requireTicket(ticket);
      if (_db.agent._revokedActionRuns.contains(ticket.runId)) {
        throw const AgentFailure(AgentFailureCode.cancelled);
      }
      await _guard(context);
      return proposed;
    });
    _agentPlans[plan.id] = _PreparedAgentPlan(
      plan,
      fingerprint([
        context.owner,
        context.resetEpoch,
        context.agendaEpoch,
        revision,
        requireFree,
        preferencesRevision,
        plan.reminderRevision,
        plan.changes.map((c) => c.canonical).toList(),
      ]),
    );
    _db.agent._signal();
    return plan;
  });

  Future<AgentPlanApproval> _approveAgentPlan(AgentLocalPlan plan) =>
      _authorizeAgentPlan(
        plan,
        mode: AgentAuthorizationMode.confirmed,
      ).then((approval) => approval!);

  Future<AgentPlanApproval?> _authorizeAgentPlan(
    AgentLocalPlan plan, {
    required AgentAuthorizationMode mode,
    bool remember = false,
  }) => _serial(() async {
    final prepared = _agentPlans[plan.id];
    if (prepared == null || !identical(prepared.plan, plan)) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    await _verifyAgentPlan(prepared);
    final proof = await _db.agent._permissions.issue(
      plan.ticket,
      _planPermissionCategories(plan),
      mode,
      remember,
    );
    if (proof == null) return null;
    final approval = AgentPlanApproval(plan);
    _agentApprovals[approval] = prepared;
    _db.agent._permissions.local[approval] = proof;
    return approval;
  });

  Future<void> _rejectAgentPlan(AgentLocalPlan plan) => _serial(() async {
    final prepared = _agentPlans[plan.id];
    if (prepared == null || !identical(prepared.plan, plan)) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    await _db.transaction(() async {
      await _verifyAgentPlan(prepared, revision: false, reminders: false);
      await _db.agent._saveAction(
        plan.ticket,
        _actionWith(plan.view, AgentActionStatus.rejected),
      );
    });
    prepared.revoked = true;
    _db.agent._signal();
  });

  Future<AgentLocalPlanReceipt> _commitAgentPlan(
    AgentPlanApproval approval,
  ) => _serial(() async {
    final prepared = _agentApprovals[approval];
    if (prepared == null || !identical(prepared.plan, approval.plan)) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    final plan = prepared.plan;
    final result = await _db.transaction(() async {
      await _guard(plan.context);
      final prior = await _db
          .customSelect(
            'SELECT * FROM agenda_plan_receipts WHERE operation_id=?',
            variables: [Variable.withString(plan.id)],
          )
          .getSingleOrNull();
      if (prior != null) {
        if (prior.read<String>('fingerprint') != prepared.fingerprint) {
          throw const CalendarFailure(CalendarFailureCode.idempotencyConflict);
        }
        return _agentPlanReceipt(prior, plan, true);
      }
      await _verifyAgentPlan(prepared);
      final permission = _db.agent._permissions.local[approval];
      if (permission == null) {
        throw const AgentFailure(AgentFailureCode.consentRequired);
      }
      await _db.agent._permissions.validate(permission);
      // Verify every external baseline before rebasing any internal sequence.
      for (final change in plan.changes) {
        final normalized = await _normalizeAgentChange(plan.context, change);
        if (normalized is AgentCalendarChange) {
          await _verifyPlanIntent(plan.context, normalized.intent);
        } else if (_isReminderChange(normalized)) {
          await _validateReminderChange(
            plan.context,
            normalized,
            planChanges: plan.changes,
          );
        }
      }
      if (plan.requireFree) {
        await _taskPlanningWarnings(plan.changes, hard: true);
        final normalized = <AgentLocalChange>[];
        for (final change in plan.changes) {
          normalized.add(await _normalizeAgentChange(plan.context, change));
        }
        final preview = await _previewLocalPlan(plan.changes);
        if (preview.freeConstraintViolated != false ||
            !_planTimesWithinPreview(normalized, preview)) {
          throw const CalendarFailure(CalendarFailureCode.invalidInput);
        }
      }
      final newTasks = <String, TaskReference>{};
      final inverses = <Map<String, dynamic>>[];
      for (final change in [
        ...plan.changes.where((change) => !_isReminderChange(change)),
        ...plan.changes.where(_isReminderChange),
      ]) {
        if (prepared.revoked) {
          throw const AgentFailure(AgentFailureCode.cancelled);
        }
        final CalendarIntent intent;
        final normalized = await _normalizeAgentChange(
          plan.context,
          await _rebaseAgentPatch(change),
        );
        if (_isReminderChange(normalized)) {
          inverses.add(await _applyReminderChange(plan.context, normalized));
          await _verifyAgentPlan(prepared, reminders: false);
          continue;
        }
        if (normalized is AgentCreateTask) {
          intent = CreateTask(normalized.draft);
        } else if (normalized is AgentDependentBlock) {
          final task = newTasks[normalized.taskKey];
          if (task == null) {
            throw const CalendarFailure(CalendarFailureCode.invalidInput);
          }
          intent = CreatePlanBlock(
            await _currentTaskRef(task),
            normalized.draft,
          );
        } else if (normalized is AgentCalendarChange) {
          intent = await _rebasePlanIntent(plan.context, normalized.intent);
        } else {
          throw const CalendarFailure(CalendarFailureCode.invalidInput);
        }
        final step = await _commitBody(
          CalendarCommand(
            JwStore._randomHexId('calendar-local-'),
            plan.context,
            intent,
          ),
          batch: true,
          captureUndo: inverses.add,
        );
        if (change is AgentCreateTask) newTasks[change.localKey] = step.task!;
        await _verifyAgentPlan(prepared, reminders: false);
      }
      CalendarUndoReference? undo;
      if (inverses.isNotEmpty) {
        undo = await _recordGroupUndo(plan.context, inverses);
      }
      await _db.onAgentCheckpoint?.call();
      await _verifyAgentPlan(prepared, reminders: false);
      await _db.agent._permissions.validate(permission);
      await _db.agent._permissions.persist(permission);
      await _db.customStatement(
        'UPDATE agenda_state SET revision=revision+1 WHERE singleton=1',
      );
      await _db.features._captureExpected();
      final revision = (await _agendaState()).read<int>('revision');
      final now = _db._clock.nowUtc;
      if (!now.isUtc) {
        throw const CalendarFailure(CalendarFailureCode.storageFailed);
      }
      final view = _actionWith(
        plan.view,
        AgentActionStatus.committed,
        count: plan.changes.length,
        authorization: permission.mode == AgentAuthorizationMode.remembered
            ? AgentActionAuthorization.remembered
            : AgentActionAuthorization.confirmed,
      );
      await _db.agent._saveAction(plan.ticket, view);
      await _db.customStatement(
        'INSERT INTO agenda_plan_audit(action,item_count,committed_at) VALUES (?,?,?)',
        [
          plan.view.kind == AgentActionKind.undo ? 'undo' : 'plan',
          plan.changes.length,
          now.microsecondsSinceEpoch,
        ],
      );
      await _db.customStatement(
        'INSERT INTO agenda_plan_receipts VALUES (?,?,?,?,?,?,?)',
        [
          plan.id,
          prepared.fingerprint,
          revision,
          plan.changes.length,
          now.microsecondsSinceEpoch,
          undo?.undoId,
          jsonEncode(_actionMap(view)),
        ],
      );
      // After the mutation our expected revision is intentionally +1.
      await _verifyAgentPlan(prepared, revision: false, reminders: false);
      await _db.agent._permissions.validate(permission);
      return AgentLocalPlanReceipt(
        planId: plan.id,
        revision: revision,
        committedCount: plan.changes.length,
        committedAtUtc: now,
        replayed: false,
        undo: undo,
        view: view,
      );
    });
    prepared.revoked = true;
    if (!result.replayed) _signal(result.revision);
    _db.agent._signal();
    return result;
  });

  AgentLocalPlanReceipt _agentPlanReceipt(
    QueryRow row,
    AgentLocalPlan plan,
    bool replayed,
  ) => AgentLocalPlanReceipt(
    planId: plan.id,
    revision: row.read<int>('revision'),
    committedCount: row.read<int>('committed_count'),
    committedAtUtc: _time(row.read<int>('committed_at')),
    replayed: replayed,
    view: _actionFromMap(jsonDecode(row.read<String>('result_json'))),
    undo: row.read<String?>('undo_id') == null
        ? null
        : CalendarUndoReference(plan.context, row.read<String>('undo_id')),
  );

  Future<AgentLocalChange> _normalizeAgentChange(
    CalendarContext context,
    AgentLocalChange change,
  ) async {
    if (change is AgentTaskPatch) {
      if (change.clearDeadline && change.deadlineUtc != null ||
          change.clearEstimate && change.estimatedMinutes != null ||
          change.title == null &&
              change.description == null &&
              change.note == null &&
              change.deadlineUtc == null &&
              !change.clearDeadline &&
              change.estimatedMinutes == null &&
              !change.clearEstimate &&
              change.priority == null) {
        throw const CalendarFailure(CalendarFailureCode.invalidInput);
      }
      final old = await _agentTaskRecord(change.target);
      final d = old.draft;
      return AgentCalendarChange(
        UpdateTask(
          change.target,
          TaskDraft(
            title: change.title ?? d.title,
            description: change.description ?? d.description,
            note: change.note ?? d.note,
            deadlineAtUtc: change.clearDeadline
                ? null
                : change.deadlineUtc ?? d.deadlineAtUtc,
            estimatedMinutes: change.clearEstimate
                ? null
                : change.estimatedMinutes ?? d.estimatedMinutes,
            priority: change.priority ?? d.priority,
          ),
        ),
      );
    }
    if (change is AgentBlockPatch) {
      final d = (await _blockByRef(change.target)).draft;
      return AgentCalendarChange(
        UpdatePlanBlock(
          change.target,
          PlanBlockDraft(
            startsAtUtc: change.startUtc ?? d.startsAtUtc,
            endsAtUtc: change.endUtc ?? d.endsAtUtc,
            location: change.location ?? d.location,
            note: change.note ?? d.note,
          ),
        ),
      );
    }
    if (change is AgentPersonalPatch) {
      final snapshot = await _snapshot(targets: {change.target.identity});
      final event = _target(snapshot, change.target);
      if (event.reference.identity.kind != CalendarKind.personal) {
        throw const CalendarFailure(CalendarFailureCode.invalidInput);
      }
      final base = snapshot.personal
          .singleWhere((p) => p.localId == change.target.identity.localId)
          .draft;
      final old = change.entireSeries
          ? base
          : PersonalEventDraft(
              title: event.title,
              start: event.allDay
                  ? beijingDay(event.startsAtUtc)
                  : event.startsAtUtc,
              end: event.allDay ? beijingDay(event.endsAtUtc) : event.endsAtUtc,
              allDay: event.allDay,
              location: event.location,
              note: event.note,
            );
      final draft = PersonalEventDraft(
        title: change.title ?? old.title,
        start: change.start ?? old.start,
        end: change.end ?? old.end,
        allDay: change.allDay ?? old.allDay,
        weekly: change.entireSeries ? change.weekly ?? old.weekly : false,
        untilDay: change.entireSeries && (change.weekly ?? old.weekly)
            ? (change.clearUntil ? null : change.untilDay ?? old.untilDay)
            : null,
        location: change.location ?? old.location,
        note: change.note ?? old.note,
      );
      return AgentCalendarChange(
        change.entireSeries
            ? UpdatePersonalSeries(change.target, draft)
            : UpdatePersonalOccurrence(change.target, draft),
      );
    }
    return change;
  }

  Future<TaskRecord> _agentTaskRecord(TaskReference ref) async =>
      _taskRecord(await _taskRow(ref), ref.context, count: 0);

  Future<AgentLocalChange> _rebaseAgentPatch(AgentLocalChange change) async =>
      switch (change) {
        AgentTaskPatch() => AgentTaskPatch(
          await _currentTaskRef(change.target),
          title: change.title,
          description: change.description,
          note: change.note,
          deadlineUtc: change.deadlineUtc,
          clearDeadline: change.clearDeadline,
          estimatedMinutes: change.estimatedMinutes,
          clearEstimate: change.clearEstimate,
          priority: change.priority,
        ),
        AgentPersonalPatch() => AgentPersonalPatch(
          await _currentEventRef(change.target),
          entireSeries: change.entireSeries,
          title: change.title,
          start: change.start,
          end: change.end,
          allDay: change.allDay,
          weekly: change.weekly,
          untilDay: change.untilDay,
          clearUntil: change.clearUntil,
          location: change.location,
          note: change.note,
        ),
        AgentBlockPatch() => AgentBlockPatch(
          await _currentEventRef(change.target),
          startUtc: change.startUtc,
          endUtc: change.endUtc,
          location: change.location,
          note: change.note,
        ),
        _ => change,
      };

  Future<void> _verifyPlanIntent(
    CalendarContext context,
    CalendarIntent intent,
  ) async {
    final events = switch (intent) {
      UpdatePersonalSeries(:final target) ||
      UpdatePersonalOccurrence(:final target) ||
      SetPersonalOccurrenceState(:final target) ||
      DeletePersonalSeries(:final target) ||
      UpdateSchoolAnnotation(:final target) ||
      UpdatePlanBlock(:final target) ||
      SetPlanBlockStatus(:final target) ||
      DeletePlanBlock(:final target) => [target],
      SaveCalendarRelation(:final left, :final right) => [left, right],
      _ => <CalendarReference>[],
    };
    if (events.isNotEmpty) {
      final snap = await _snapshot(
        targets: events.map((r) => r.identity).toSet(),
      );
      for (final ref in events) {
        _target(snap, ref);
      }
      if (intent is SaveCalendarRelation &&
          events.any((r) => _target(snap, r).allDay)) {
        throw const CalendarFailure(CalendarFailureCode.invalidInput);
      }
    }
    final task = switch (intent) {
      UpdateTask(:final target) ||
      SetTaskStatus(:final target) ||
      DeleteTask(:final target) => target,
      CreatePlanBlock(:final task) => task,
      _ => null,
    };
    if (task != null) await _taskRow(task);
    if (intent is SaveCalendarRelation || intent is DeleteCalendarRelation) {
      final before = await _beforeUndo(intent);
      if (intent is SaveCalendarRelation && intent.existing == null) {
        final pair = [
          jsonEncode(intent.left.identity.canonical),
          jsonEncode(intent.right.identity.canonical),
        ]..sort();
        final exists = await _db
            .customSelect(
              'SELECT local_id FROM agenda_relations WHERE left_identity=? AND right_identity=?',
              variables: pair.map(Variable.withString).toList(),
            )
            .getSingleOrNull();
        if (exists != null) {
          throw const CalendarFailure(CalendarFailureCode.staleReference);
        }
      }
      if (intent is SaveCalendarRelation && intent.existing != null) {
        final pair = [
          jsonEncode(intent.left.identity.canonical),
          jsonEncode(intent.right.identity.canonical),
        ]..sort();
        if (before.length < 3 || before[1] != pair[0] || before[2] != pair[1]) {
          throw const CalendarFailure(CalendarFailureCode.staleReference);
        }
      }
      if (intent is DeleteCalendarRelation && before.isEmpty) {
        throw const CalendarFailure(CalendarFailureCode.staleReference);
      }
    }
    if (intent is UndoCalendarWrite) {
      final row = await _db
          .customSelect(
            'SELECT * FROM agenda_undo WHERE singleton=1 AND undo_id=?',
            variables: [Variable.withString(intent.target.undoId)],
          )
          .getSingleOrNull();
      if (row == null) {
        throw const CalendarFailure(CalendarFailureCode.undoUnavailable);
      }
      await _checkUndo(row, _decodeUndo(row.read<String>('payload')), context);
    }
  }

  Future<Set<(String, int)>> _planIntentAggregates(
    CalendarIntent intent,
  ) async {
    final events = switch (intent) {
      UpdatePersonalSeries(:final target) ||
      UpdatePersonalOccurrence(:final target) ||
      SetPersonalOccurrenceState(:final target) ||
      DeletePersonalSeries(:final target) ||
      UpdateSchoolAnnotation(:final target) ||
      UpdatePlanBlock(:final target) ||
      SetPlanBlockStatus(:final target) ||
      DeletePlanBlock(:final target) => [target.identity],
      SaveCalendarRelation(:final left, :final right) => [
        left.identity,
        right.identity,
      ],
      _ => <CalendarIdentity>[],
    };
    final keys = <(String, int)>{};
    for (final event in events) {
      keys.add(await _aggregateKey(event));
    }
    final task = switch (intent) {
      UpdateTask(:final target) ||
      SetTaskStatus(:final target) ||
      DeleteTask(:final target) => target,
      CreatePlanBlock(:final task) => task,
      _ => null,
    };
    if (task != null) keys.add(('task', task.localId));
    return keys;
  }

  Future<CalendarReference> _currentEventRef(CalendarReference r) async =>
      CalendarReference(
        r.context,
        r.identity,
        await _aggregateVersion(await _aggregateKey(r.identity)),
      );
  Future<TaskReference> _currentTaskRef(TaskReference r) async => TaskReference(
    r.context,
    r.localId,
    await _aggregateVersion(('task', r.localId)),
  );
  Future<CalendarRelationReference> _currentRelationRef(
    CalendarRelationReference r,
  ) async {
    final row = await _db
        .customSelect(
          'SELECT version FROM agenda_relations WHERE local_id=?',
          variables: [Variable.withInt(r.localId)],
        )
        .getSingleOrNull();
    if (row == null) {
      throw const CalendarFailure(CalendarFailureCode.staleReference);
    }
    return CalendarRelationReference(
      r.context,
      r.localId,
      row.read<int>('version'),
    );
  }

  Future<CalendarIntent> _rebasePlanIntent(
    CalendarContext context,
    CalendarIntent intent,
  ) async => switch (intent) {
    UpdatePersonalSeries(:final target, :final draft) => UpdatePersonalSeries(
      await _currentEventRef(target),
      draft,
    ),
    UpdatePersonalOccurrence(:final target, :final replacement) =>
      UpdatePersonalOccurrence(await _currentEventRef(target), replacement),
    SetPersonalOccurrenceState(
      :final target,
      :final completed,
      :final skipped,
    ) =>
      SetPersonalOccurrenceState(
        await _currentEventRef(target),
        completed: completed,
        skipped: skipped,
      ),
    DeletePersonalSeries(:final target) => DeletePersonalSeries(
      await _currentEventRef(target),
      confirmed: true,
    ),
    UpdateSchoolAnnotation(
      :final target,
      :final hidden,
      :final note,
      :final attendance,
      :final listening,
    ) =>
      UpdateSchoolAnnotation(
        await _currentEventRef(target),
        hidden: hidden,
        note: note,
        attendance: attendance,
        listening: listening,
      ),
    UpdateTask(:final target, :final draft) => UpdateTask(
      await _currentTaskRef(target),
      draft,
    ),
    SetTaskStatus(:final target, :final status) => SetTaskStatus(
      await _currentTaskRef(target),
      status,
    ),
    DeleteTask(:final target) => DeleteTask(
      await _currentTaskRef(target),
      confirmed: true,
    ),
    CreatePlanBlock(:final task, :final draft) => CreatePlanBlock(
      await _currentTaskRef(task),
      draft,
    ),
    UpdatePlanBlock(:final target, :final draft) => UpdatePlanBlock(
      await _currentEventRef(target),
      draft,
    ),
    SetPlanBlockStatus(:final target, :final status) => SetPlanBlockStatus(
      await _currentEventRef(target),
      status,
    ),
    DeletePlanBlock(:final target) => DeletePlanBlock(
      await _currentEventRef(target),
      confirmed: true,
    ),
    SaveCalendarRelation(
      :final left,
      :final right,
      :final kind,
      :final note,
      :final existing,
    ) =>
      SaveCalendarRelation(
        left: await _currentEventRef(left),
        right: await _currentEventRef(right),
        kind: kind,
        note: note,
        existing: existing == null ? null : await _currentRelationRef(existing),
      ),
    DeleteCalendarRelation(:final target) => DeleteCalendarRelation(
      await _currentRelationRef(target),
    ),
    _ => intent,
  };

  Future<String> _describeAgentChange(
    AgentLocalChange change, {
    AgentLocalChange? original,
  }) async {
    if (_isReminderChange(change)) return _describeReminderChange(change);
    String time(DateTime d) =>
        '${d.add(const Duration(hours: 8)).toIso8601String().replaceFirst(RegExp(r'Z$'), '')}+08:00';
    String personal(PersonalEventDraft d) =>
        '${d.title}；${d.allDay ? "全天 ${d.start.toIso8601String().substring(0, 10)} 至 ${d.end.toIso8601String().substring(0, 10)}（结束日不含）" : "${time(d.start)} 至 ${time(d.end)}"}；地点 ${d.location.isEmpty ? "未指定" : d.location}${d.weekly ? "；每周重复${d.untilDay == null ? "（未设截止）" : "至 ${d.untilDay!.toIso8601String().substring(0, 10)}"}" : ""}${d.note.isEmpty || original is AgentPersonalPatch && original.note == null ? "" : "；备注：${d.note}"}';
    String block(PlanBlockDraft d) =>
        '${time(d.startsAtUtc)} 至 ${time(d.endsAtUtc)}；地点 ${d.location.isEmpty ? "未指定" : d.location}${d.note.isEmpty || original is AgentBlockPatch && original.note == null ? "" : "；备注：${d.note}"}';
    if (change is AgentCreateTask) {
      return '新任务「${change.draft.title}」(方案内 ${change.localKey})；${_taskDescription(change.draft)}';
    }
    if (change is AgentDependentBlock) {
      return '为新任务 ${change.taskKey} 添加时间块：${block(change.draft)}';
    }
    final i = (change as AgentCalendarChange).intent;
    final label = await _planTargetLabel(i);
    if (original is AgentTaskPatch) {
      final fields = [
        if (original.title != null) '名称改为 ${original.title}',
        if (original.description != null) '正文改为 ${original.description}',
        if (original.note != null) '备注改为 ${original.note}',
        if (original.clearDeadline) '移除截止',
        if (original.deadlineUtc != null) '截止 ${time(original.deadlineUtc!)}',
        if (original.clearEstimate) '移除预计时长',
        if (original.estimatedMinutes != null)
          '预计 ${original.estimatedMinutes} 分钟',
        if (original.priority != null) '优先级 ${original.priority!.name}',
      ];
      return '修改任务「$label」：${fields.join('；')}；其他字段保留';
    }
    if (original is AgentPersonalPatch) {
      final fields = [
        if (original.title != null) '名称改为 ${original.title}',
        if (original.start != null)
          '开始改为 ${original.allDay == true ? original.start!.toIso8601String().substring(0, 10) : time(original.start!)}',
        if (original.end != null)
          '结束改为 ${original.allDay == true ? original.end!.toIso8601String().substring(0, 10) : time(original.end!)}',
        if (original.allDay != null) '全天：${original.allDay}',
        if (original.weekly != null) '每周重复：${original.weekly}',
        if (original.untilDay != null)
          '重复截止：${original.untilDay!.toIso8601String().substring(0, 10)}',
        if (original.clearUntil) '移除重复截止',
        if (original.location != null) '地点改为 ${original.location}',
        if (original.note != null) '备注改为 ${original.note}',
      ];
      return '修改「$label」${original.entireSeries ? "整组" : "仅本次"}：${fields.join('；')}；其他字段保留';
    }
    if (original is AgentBlockPatch) {
      final fields = [
        if (original.startUtc != null) '开始改为 ${time(original.startUtc!)}',
        if (original.endUtc != null) '结束改为 ${time(original.endUtc!)}',
        if (original.location != null) '地点改为 ${original.location}',
        if (original.note != null) '备注改为 ${original.note}',
      ];
      return '修改「$label」时间块：${fields.join('；')}；其他字段保留';
    }
    return switch (i) {
      CreatePersonalEvent(:final draft) => '新增个人安排：${personal(draft)}',
      UpdatePersonalSeries(:final draft) => '修改「$label」整组：${personal(draft)}',
      UpdatePersonalOccurrence(:final replacement) =>
        '仅修改「$label」本次：${personal(replacement)}',
      SetPersonalOccurrenceState(:final completed, :final skipped) =>
        '「$label」本次状态：完成=${completed ?? "保持"}，跳过=${skipped ?? "保持"}',
      DeletePersonalSeries() => '删除「$label」个人安排整组（含所有重复日期）',
      UpdateSchoolAnnotation(
        :final hidden,
        :final note,
        :final attendance,
        :final listening,
      ) =>
        '「$label」本地覆盖：隐藏=${hidden ?? "保持"}，参加=${attendance?.name ?? "保持"}，听讲=${listening?.name ?? "保持"}${note == null ? "" : "；备注：$note"}；学校事实不改',
      CreateTask(:final draft) =>
        '新增任务「${draft.title}」；${_taskDescription(draft)}',
      UpdateTask(:final draft) =>
        '修改任务「$label」为「${draft.title}」；${_taskDescription(draft, original: original)}',
      SetTaskStatus(:final status) => '任务「$label」状态改为 ${status.name}（不改时间块状态）',
      DeleteTask() => '删除任务「$label」及所属时间块的有效显示',
      CreatePlanBlock(:final draft) => '为任务「$label」添加时间块：${block(draft)}',
      UpdatePlanBlock(:final draft) => '移动/修改「$label」时间块：${block(draft)}',
      SetPlanBlockStatus(:final status) =>
        '「$label」时间块状态改为 ${status.name}（不改任务状态）',
      DeletePlanBlock() => '删除「$label」时间块（保留父任务）',
      SaveCalendarRelation(:final kind, :final note) =>
        '「$label」关系设置为 ${kind == CalendarRelationKind.notConflict ? "不冲突" : "冲突"}${note.isEmpty ? "" : "；原因：$note"}',
      DeleteCalendarRelation() => '清除「$label」显式关系决定，恢复默认冲突判断',
      UndoCalendarWrite() => '整组撤销当前最近一次可撤销本地修改；不恢复学校采集事实',
    };
  }

  String _taskDescription(TaskDraft d, {AgentLocalChange? original}) =>
      '优先级 ${d.priority.name}；预计 ${d.estimatedMinutes ?? "未指定"} 分钟；截止 ${d.deadlineAtUtc == null ? "未指定" : "${d.deadlineAtUtc!.add(const Duration(hours: 8)).toIso8601String().replaceFirst(RegExp(r"Z$"), "")}+08:00"}${d.description.isEmpty || original is AgentTaskPatch && original.description == null ? "" : "；正文：${d.description}"}${d.note.isEmpty || original is AgentTaskPatch && original.note == null ? "" : "；备注：${d.note}"}';

  Future<String> _planTargetLabel(CalendarIntent intent) async {
    final task = switch (intent) {
      UpdateTask(:final target) ||
      SetTaskStatus(:final target) ||
      DeleteTask(:final target) => target,
      CreatePlanBlock(:final task) => task,
      _ => null,
    };
    if (task != null) return (await _agentTaskRecord(task)).draft.title;
    final refs = switch (intent) {
      UpdatePersonalSeries(:final target) ||
      UpdatePersonalOccurrence(:final target) ||
      SetPersonalOccurrenceState(:final target) ||
      DeletePersonalSeries(:final target) ||
      UpdateSchoolAnnotation(:final target) ||
      UpdatePlanBlock(:final target) ||
      SetPlanBlockStatus(:final target) ||
      DeletePlanBlock(:final target) => [target],
      SaveCalendarRelation(:final left, :final right) => [left, right],
      _ => <CalendarReference>[],
    };
    if (refs.isNotEmpty) {
      final snapshot = await _snapshot(
        targets: refs.map((r) => r.identity).toSet(),
      );
      return refs
          .map((r) {
            final e = _target(snapshot, r);
            final start = e.startsAtUtc
                .add(const Duration(hours: 8))
                .toIso8601String()
                .substring(0, 16);
            return '${e.title} · $start 北京时间';
          })
          .join(' / ');
    }
    if (intent is DeleteCalendarRelation) {
      final row = await _db
          .customSelect(
            'SELECT left_identity,right_identity FROM agenda_relations WHERE local_id=?',
            variables: [Variable.withInt(intent.target.localId)],
          )
          .getSingle();
      final ids = [
        row.read<String>('left_identity'),
        row.read<String>('right_identity'),
      ].map(_decodeIdentity).toSet();
      final s = await _snapshot(targets: ids);
      return ids
          .map(
            (id) =>
                LocalCalendarStore._projection.occurrence(s, id)?.title ??
                '当前日程',
          )
          .join(' / ');
    }
    return '';
  }
}

AgentActionView _actionWith(
  AgentActionView view,
  AgentActionStatus status, {
  int count = 0,
  AgentActionAuthorization? authorization,
}) => AgentActionView(
  id: view.id,
  kind: view.kind,
  status: status,
  title: view.title,
  details: view.details,
  warning: view.warning,
  committedCount: count,
  authorization: authorization ?? view.authorization,
);
Map<String, Object?> _actionMap(AgentActionView v) => {
  'id': v.id,
  'kind': v.kind.name,
  'status': v.status.name,
  'title': v.title,
  'details': v.details,
  'warning': v.warning,
  'count': v.committedCount,
  'authorization': v.authorization.name,
};
AgentActionView _actionFromMap(Object? value) {
  if (value is! Map ||
      value.keys.toSet().difference({
        'id',
        'kind',
        'status',
        'title',
        'details',
        'warning',
        'count',
        'authorization',
      }).isNotEmpty ||
      value.length != 7 && value.length != 8 ||
      value['details'] is! List ||
      (value['details'] as List).length > 20 ||
      value['count'] is! int) {
    throw const AgentFailure(AgentFailureCode.storageFailed);
  }
  final v = AgentActionView(
    id: value['id'] as String,
    kind: AgentActionKind.values.byName(value['kind'] as String),
    status: AgentActionStatus.values.byName(value['status'] as String),
    title: value['title'] as String,
    details: (value['details'] as List).cast<String>(),
    warning: value['warning'] as String,
    committedCount: value['count'] as int,
    authorization: AgentActionAuthorization.values.byName(
      value['authorization'] as String? ?? 'legacy',
    ),
  );
  _validateActionView(v);
  return v;
}

void _validateActionView(AgentActionView v) {
  if (!RegExp(r'^agent-action-[0-9a-f]{32}$').hasMatch(v.id) ||
      v.title.length > 500 ||
      v.details.length > 20 ||
      v.warning.length > 4000 ||
      v.committedCount < 0 ||
      v.committedCount > 10000) {
    throw const AgentFailure(AgentFailureCode.invalidInput);
  }
  AgentText.requireSafe(jsonEncode(_actionMap(v)), maxCharacters: 65536);
  if (utf8.encode(jsonEncode(v.details)).length > 65536) {
    throw const AgentFailure(AgentFailureCode.resourceLimit);
  }
}

extension _AgentActionStorage on AgentStore {
  Future<AgentActionView> _preparePreferencesPlan(
    AgentRunTicket ticket,
    AgentPlanningPreferences preferences,
  ) => _serial(() async {
    _validatePlanningPreferences(preferences);
    final view = await _db.transaction(() async {
      await _requireTicket(ticket);
      if (_revokedActionRuns.contains(ticket.runId)) {
        throw const AgentFailure(AgentFailureCode.cancelled);
      }
      final revision =
          (await _db
                  .customSelect(
                    'SELECT revision FROM agent_preferences WHERE singleton=1',
                  )
                  .getSingle())
              .read<int>('revision');
      if (revision != preferences.revision) {
        throw const AgentFailure(AgentFailureCode.staleContext);
      }
      String minute(int value) =>
          '${(value ~/ 60).toString().padLeft(2, "0")}:${(value % 60).toString().padLeft(2, "0")}';
      final record = AgentActionView(
        id: JwStore._randomHexId('agent-action-'),
        kind: AgentActionKind.planningPreferences,
        status: AgentActionStatus.proposed,
        title: '保存时间规划偏好',
        details: [
          '适用星期：${preferences.weekdays.map((d) => "一二三四五六日"[d - 1]).join("、")}',
          '每日允许 ${minute(preferences.startMinute)}—${minute(preferences.endMinute)}（北京时间）',
          '默认单块 ${preferences.blockMinutes} 分钟；休息 ${preferences.breakMinutes} 分钟',
          '每日避开：${preferences.avoid.isEmpty ? "无" : preferences.avoid.map((r) => "${minute(r.$1)}—${minute(r.$2)}").join("、")}',
        ],
        warning: '仅保存这些明确的时段条件；不会从聊天自动学习个人画像。',
      );
      await _saveAction(ticket, record);
      return record;
    });
    _preferencePermits[view] = (ticket, preferences);
    _signal();
    return view;
  });

  Future<void> _commitPreferencesPlan(
    AgentRunTicket ticket,
    AgentActionView record,
  ) => _serial(() async {
    final permit = _preferencePermits[record];
    if (permit == null || !identical(permit.$1, ticket)) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    await _db.transaction(() async {
      final prior = await _db
          .customSelect(
            'SELECT status FROM agent_actions WHERE action_id=?',
            variables: [Variable.withString(record.id)],
          )
          .getSingleOrNull();
      if (prior?.read<String>('status') == 'committed') {
        await _require(ticket.authority);
        return;
      }
      await _requireTicket(ticket);
      if (_revokedActionRuns.contains(ticket.runId) ||
          prior?.read<String>('status') != 'proposed') {
        throw const AgentFailure(AgentFailureCode.cancelled);
      }
      await _permissions.validateAction(record);
      if (_permissions.actions[record] == null) {
        throw const AgentFailure(AgentFailureCode.consentRequired);
      }
      final p = permit.$2;
      final row = await _db
          .customSelect(
            'SELECT revision FROM agent_preferences WHERE singleton=1',
          )
          .getSingle();
      if (row.read<int>('revision') != p.revision) {
        throw const AgentFailure(AgentFailureCode.staleContext);
      }
      await _db.customStatement(
        'UPDATE agent_preferences SET revision=revision+1,value_json=? WHERE singleton=1',
        [jsonEncode(p.canonical)],
      );
      await _saveAction(
        ticket,
        _actionWith(
          record,
          AgentActionStatus.committed,
          count: 1,
          authorization:
              _permissions.actions[record]?.mode ==
                  AgentAuthorizationMode.remembered
              ? AgentActionAuthorization.remembered
              : AgentActionAuthorization.confirmed,
        ),
      );
      await _db.customStatement(
        "INSERT INTO agenda_plan_audit(action,item_count,committed_at) VALUES ('preferences',1,?)",
        [_db._clock.nowUtc.microsecondsSinceEpoch],
      );
      await _db.onAgentCheckpoint?.call();
      await _requireTicket(ticket);
      final permission = _permissions.actions[record];
      if (permission != null) {
        await _permissions.validate(permission);
        await _permissions.persist(permission);
      }
      if (_revokedActionRuns.contains(ticket.runId)) {
        throw const AgentFailure(AgentFailureCode.cancelled);
      }
    });
    _signal();
  });

  Future<void> _rejectPreferencesPlan(
    AgentRunTicket ticket,
    AgentActionView record,
  ) => _serial(() async {
    if (!identical(_preferencePermits[record]?.$1, ticket)) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    await _db.transaction(() async {
      await _requireTicket(ticket);
      await _saveAction(
        ticket,
        _actionWith(record, AgentActionStatus.rejected),
      );
    });
    _signal();
  });

  Future<AgentPlanningPreferences> _readPlanningPreferences() =>
      _serial(() async {
        await _db._guard();
        final row = await _db
            .customSelect('SELECT * FROM agent_preferences WHERE singleton=1')
            .getSingle();
        try {
          final v = jsonDecode(row.read<String>('value_json')) as List;
          if (v.length != 6) {
            throw const FormatException();
          }
          final prefs = AgentPlanningPreferences(
            revision: row.read<int>('revision'),
            weekdays: (v[0] as List).cast<int>(),
            startMinute: v[1] as int,
            endMinute: v[2] as int,
            blockMinutes: v[3] as int,
            breakMinutes: v[4] as int,
            avoid: (v[5] as List)
                .map((r) => ((r as List)[0] as int, r[1] as int))
                .toList(),
          );
          _validatePlanningPreferences(prefs);
          return prefs;
        } catch (_) {
          throw const AgentFailure(AgentFailureCode.storageFailed);
        }
      });

  Future<void> _savePlanningPreferences(
    AgentPlanningPreferences prefs,
  ) => _serial(() async {
    _validatePlanningPreferences(prefs);
    await _db.transaction(() async {
      await _db._guard();
      final row = await _db
          .customSelect(
            'SELECT revision FROM agent_preferences WHERE singleton=1',
          )
          .getSingle();
      if (row.read<int>('revision') != prefs.revision) {
        throw const AgentFailure(AgentFailureCode.staleContext);
      }
      await _db.customStatement(
        'UPDATE agent_preferences SET revision=revision+1,value_json=? WHERE singleton=1',
        [jsonEncode(prefs.canonical)],
      );
      await _db.onAgentCheckpoint?.call();
      await _db._guard();
    });
    _signal();
  });

  Future<void> _saveAction(AgentRunTicket ticket, AgentActionView view) async {
    _validateActionView(view);
    final old = await _db
        .customSelect(
          'SELECT run_id,details_json,title,warning FROM agent_actions WHERE action_id=?',
          variables: [Variable.withString(view.id)],
        )
        .getSingleOrNull();
    if (old != null && old.read<String>('run_id') != ticket.runId) {
      throw const AgentFailure(AgentFailureCode.staleContext);
    }
    final count =
        (await _db
                .customSelect(
                  'SELECT COUNT(*) AS count FROM agent_actions WHERE run_id=?',
                  variables: [Variable.withString(ticket.runId)],
                )
                .getSingle())
            .read<int>('count');
    if (old == null && count >= 20) {
      throw const AgentFailure(AgentFailureCode.resourceLimit);
    }
    final details = jsonEncode(view.details);
    await _budget(
      max(
        0,
        utf8.encode(details + view.title + view.warning).length -
            (old == null
                ? 0
                : utf8
                      .encode(
                        old.read<String>('details_json') +
                            old.read<String>('title') +
                            old.read<String>('warning'),
                      )
                      .length),
      ),
    );
    await _db.customStatement(
      'INSERT INTO agent_actions (action_id,run_id,kind,status,title,details_json,warning,committed_count,created_at,authorization) VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(action_id) DO UPDATE SET status=excluded.status,details_json=excluded.details_json,committed_count=excluded.committed_count,authorization=excluded.authorization',
      [
        view.id,
        ticket.runId,
        view.kind.name,
        view.status.name,
        view.title,
        details,
        view.warning,
        view.committedCount,
        _db._clock.nowUtc.microsecondsSinceEpoch,
        view.authorization.name,
      ],
    );
  }

  Future<List<AgentActionView>> _actionViews(String runId) async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM agent_actions WHERE run_id=? ORDER BY created_at,action_id LIMIT 21',
          variables: [Variable.withString(runId)],
        )
        .get();
    if (rows.length > 20) {
      throw const AgentFailure(AgentFailureCode.storageFailed);
    }
    return rows
        .map(
          (r) => _actionFromMap({
            'id': r.read<String>('action_id'),
            'kind': r.read<String>('kind'),
            'status': r.read<String>('status'),
            'title': r.read<String>('title'),
            'details': jsonDecode(r.read<String>('details_json')),
            'warning': r.read<String>('warning'),
            'count': r.read<int>('committed_count'),
            'authorization': r.read<String>('authorization'),
          }),
        )
        .toList();
  }
}

void _validatePlanningPreferences(AgentPlanningPreferences p) {
  if (p.revision < 0 ||
      p.weekdays.isEmpty ||
      p.weekdays.length > 7 ||
      p.weekdays.toSet().length != p.weekdays.length ||
      p.weekdays.any((d) => d < 1 || d > 7) ||
      p.startMinute < 0 ||
      p.endMinute > 1440 ||
      p.endMinute <= p.startMinute ||
      p.blockMinutes < 1 ||
      p.blockMinutes > 480 ||
      p.breakMinutes < 0 ||
      p.breakMinutes > 240 ||
      p.avoid.length > 8 ||
      p.avoid.any((r) => r.$1 < 0 || r.$2 > 1440 || r.$2 <= r.$1)) {
    throw const AgentFailure(AgentFailureCode.invalidInput);
  }
}
