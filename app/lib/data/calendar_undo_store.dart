part of 'jw_store.dart';

/// C3 alone constructs the inverse. The UI supplies only an issued slot ID;
/// neither table names nor patches are accepted from callers.
extension _CalendarUndoStorage on LocalCalendarStore {
  static const _undoActions = {
    'create',
    'series',
    'occurrence',
    'state',
    'delete',
    'annotation',
    'relation',
    'remove-relation',
    'task-create',
    'task-update',
    'task-status',
    'task-delete',
    'block-create',
    'block-update',
    'block-status',
    'block-delete',
  };

  Future<List<Object?>> _beforeUndo(CalendarIntent intent) async {
    Future<QueryRow> personal(CalendarReference ref) => _db
        .customSelect(
          'SELECT * FROM personal_events WHERE local_id=?',
          variables: [Variable.withInt(ref.identity.localId)],
        )
        .getSingle();
    switch (intent) {
      case CreatePersonalEvent() || CreateTask() || CreatePlanBlock():
        return [];
      case UpdatePersonalSeries(:final target):
        return [(await personal(target)).read<String>('draft_json')];
      case DeletePersonalSeries(:final target):
        return [(await personal(target)).read<int>('deleted')];
      case UpdatePersonalOccurrence(:final target) ||
          SetPersonalOccurrenceState(:final target):
        final row = await _db
            .customSelect(
              'SELECT * FROM personal_occurrence_overrides WHERE local_id=? AND ordinal=?',
              variables: [
                Variable.withInt(target.identity.localId),
                Variable.withInt(target.identity.ordinal),
              ],
            )
            .getSingleOrNull();
        return row == null
            ? []
            : [
                row.read<String?>('replacement_json'),
                row.read<int>('completed'),
                row.read<int>('skipped'),
              ];
      case UpdateSchoolAnnotation(
        :final target,
        :final hidden,
        :final note,
        :final attendance,
        :final listening,
      ):
        final young = target.identity.kind == CalendarKind.young;
        final row = await _db
            .customSelect(
              young
                  ? 'SELECT * FROM young_overlays WHERE local_id=?'
                  : 'SELECT * FROM jw_overlays WHERE local_id=?',
              variables: [Variable.withInt(target.identity.localId)],
            )
            .getSingle();
        return [
          hidden == null ? null : row.read<int>('hidden'),
          note == null ? null : row.read<String>('note'),
          attendance == null ? null : row.read<String>('attendance'),
          listening == null ? null : row.read<String>('listening'),
        ];
      case SaveCalendarRelation(:final existing):
        if (existing == null) return [];
        final row = await _db
            .customSelect(
              'SELECT * FROM agenda_relations WHERE local_id=?',
              variables: [Variable.withInt(existing.localId)],
            )
            .getSingleOrNull();
        if (row == null || row.read<int>('version') != existing.version) {
          throw const CalendarFailure(CalendarFailureCode.staleReference);
        }
        return _relationBefore(row);
      case DeleteCalendarRelation(:final target):
        final row = await _db
            .customSelect(
              'SELECT * FROM agenda_relations WHERE local_id=?',
              variables: [Variable.withInt(target.localId)],
            )
            .getSingleOrNull();
        if (row == null || row.read<int>('version') != target.version) {
          throw const CalendarFailure(CalendarFailureCode.staleReference);
        }
        return _relationBefore(row);
      case UpdateTask(:final target):
        final row = await _taskRow(target);
        return [
          row.read<String>('title'),
          row.read<String>('description'),
          row.read<String>('note'),
          row.read<int?>('deadline_at'),
          row.read<int?>('estimated_minutes'),
          row.read<int>('priority'),
        ];
      case SetTaskStatus(:final target):
        return [(await _taskRow(target)).read<String>('status')];
      case DeleteTask(:final target):
        return [(await _taskRow(target)).read<int>('deleted')];
      case UpdatePlanBlock(:final target):
        final block = await _blockByRef(target);
        return [
          block.draft.startsAtUtc.microsecondsSinceEpoch,
          block.draft.endsAtUtc.microsecondsSinceEpoch,
          block.draft.location,
          block.draft.note,
        ];
      case SetPlanBlockStatus(:final target):
        return [(await _blockByRef(target)).status.name];
      case DeletePlanBlock():
        return [0];
      case UndoCalendarWrite():
        throw const CalendarFailure(CalendarFailureCode.invalidInput);
    }
  }

  List<Object?> _relationBefore(QueryRow row) => [
    row.read<int>('local_id'),
    row.read<String>('left_identity'),
    row.read<String>('right_identity'),
    row.read<String>('kind'),
    row.read<String>('note'),
    row.read<int>('version'),
  ];

  Future<(String, int)> _aggregateKey(CalendarIdentity identity) async {
    if (identity.kind == CalendarKind.planBlock) {
      final row = await _db
          .customSelect(
            'SELECT task_id FROM local_plan_blocks WHERE local_id=?',
            variables: [Variable.withInt(identity.localId)],
          )
          .getSingleOrNull();
      if (row == null) {
        throw const CalendarFailure(CalendarFailureCode.staleReference);
      }
      return ('task', row.read<int>('task_id'));
    }
    return (identity.kind.name, identity.localId);
  }

  String _aggregateTable(String kind) => switch (kind) {
    'personal' => 'personal_events',
    'task' => 'local_tasks',
    'course' || 'exam' => 'jw_events',
    'young' => 'young_events',
    _ => throw const CalendarFailure(CalendarFailureCode.storageFailed),
  };

  Future<int> _aggregateVersion((String, int) key) async {
    final (kind, id) = key;
    final row = await _db
        .customSelect(
          'SELECT * FROM ${_aggregateTable(kind)} WHERE local_id=?',
          variables: [Variable.withInt(id)],
        )
        .getSingleOrNull();
    if (row == null ||
        ((kind == 'course' || kind == 'exam') &&
            row.read<String>('kind') != kind)) {
      throw const CalendarFailure(CalendarFailureCode.undoConflict);
    }
    if ((kind == 'course' || kind == 'exam' || kind == 'young') &&
        await _db._account() == null) {
      throw const CalendarFailure(CalendarFailureCode.undoConflict);
    }
    return row.read<int>('version');
  }

  Future<void> _touchAggregates(Iterable<(String, int)> keys) async {
    for (final key in keys.toSet()) {
      await _aggregateVersion(key);
      if (key.$1 == 'task') {
        await _bumpTask(key.$2, _db._clock.nowUtc);
      } else {
        await _db.customStatement(
          'UPDATE ${_aggregateTable(key.$1)} SET version=version+1 WHERE local_id=?',
          [key.$2],
        );
      }
    }
  }

  Future<void> _touchEndpoints(
    CalendarIdentity left,
    CalendarIdentity right,
  ) async =>
      _touchAggregates([await _aggregateKey(left), await _aggregateKey(right)]);

  Future<CalendarUndoReference> _recordUndo(
    CalendarCommand command,
    List<Object?> before,
    CalendarReference? target,
    TaskReference? task,
    CalendarRelationReference? relation,
  ) async {
    final action = command.intent.canonical.first as String;
    final keys = <(String, int)>{};
    List<Object?>? relationPost;
    if (action == 'relation') {
      final intent = command.intent as SaveCalendarRelation;
      keys.addAll([
        await _aggregateKey(intent.left.identity),
        await _aggregateKey(intent.right.identity),
      ]);
      final pair = [
        jsonEncode(intent.left.identity.canonical),
        jsonEncode(intent.right.identity.canonical),
      ]..sort();
      relationPost = [relation!.localId, relation.version, ...pair];
    } else if (action == 'remove-relation') {
      keys.addAll([
        await _aggregateKey(_decodeIdentity(before[1] as String)),
        await _aggregateKey(_decodeIdentity(before[2] as String)),
      ]);
      relationPost = [before[0], (before[5] as int) + 1, before[1], before[2]];
    } else if (task != null) {
      keys.add(('task', task.localId));
    } else {
      keys.add(await _aggregateKey(target!.identity));
    }
    final guards = <List<Object>>[];
    for (final key in keys) {
      guards.add([key.$1, key.$2, await _aggregateVersion(key)]);
    }
    final context = command.context;
    final payload = jsonEncode({
      'v': 1,
      'action': action,
      'context': [context.owner, context.resetEpoch, context.agendaEpoch],
      'before': before,
      'target': target?.identity.canonical,
      'task': task?.localId,
      'guards': guards,
      'relation': relationPost,
    });
    if (utf8.encode(payload).length > 65536) {
      throw const CalendarFailure(CalendarFailureCode.limitExceeded);
    }
    final id = JwStore._randomHexId('calendar-undo-');
    final now = _db._clock.nowUtc;
    if (!now.isUtc) {
      throw const CalendarFailure(CalendarFailureCode.storageFailed);
    }
    await _db.customStatement(
      'INSERT INTO agenda_undo(singleton,undo_id,payload,created_at,expires_at) VALUES (1,?,?,?,?) ON CONFLICT(singleton) DO UPDATE SET undo_id=excluded.undo_id,payload=excluded.payload,created_at=excluded.created_at,expires_at=excluded.expires_at',
      [
        id,
        payload,
        now.microsecondsSinceEpoch,
        now.add(const Duration(hours: 24)).microsecondsSinceEpoch,
      ],
    );
    return CalendarUndoReference(context, id);
  }

  Map<String, dynamic> _decodeUndo(String encoded) {
    try {
      if (utf8.encode(encoded).length > 65536) throw const FormatException();
      final value = jsonDecode(encoded);
      const fields = {
        'v',
        'action',
        'context',
        'before',
        'target',
        'task',
        'guards',
        'relation',
      };
      if (value is! Map<String, dynamic> ||
          value.length != fields.length ||
          !value.keys.toSet().containsAll(fields) ||
          value['v'] != 1 ||
          !_undoActions.contains(value['action'])) {
        throw const FormatException();
      }
      final c = value['context'];
      final guards = value['guards'];
      final before = value['before'];
      if (c is! List ||
          c.length != 3 ||
          c[0] is! String ||
          c[1] is! int ||
          c[2] is! int ||
          guards is! List ||
          guards.isEmpty ||
          guards.length > 2 ||
          before is! List) {
        throw const FormatException();
      }
      for (final g in guards) {
        if (g is! List ||
            g.length != 3 ||
            g[0] is! String ||
            g[1] is! int ||
            g[1] <= 0 ||
            g[2] is! int ||
            g[2] <= 0) {
          throw const FormatException();
        }
        _aggregateTable(g[0] as String);
      }
      if (value['target'] != null) _decodeIdentity(jsonEncode(value['target']));
      if (value['task'] != null &&
          (value['task'] is! int || value['task'] <= 0)) {
        throw const FormatException();
      }
      final r = value['relation'];
      if (r != null &&
          (r is! List ||
              r.length != 4 ||
              r[0] is! int ||
              r[0] <= 0 ||
              r[1] is! int ||
              r[1] <= 0 ||
              r[2] is! String ||
              r[3] is! String)) {
        throw const FormatException();
      }
      // Before values are tuples of fixed business fields, never executable paths.
      final action = value['action'] as String;
      final sizes = switch (action) {
        'create' || 'task-create' || 'block-create' => [0],
        'series' ||
        'delete' ||
        'task-status' ||
        'task-delete' ||
        'block-status' ||
        'block-delete' => [1],
        'occurrence' || 'state' => [0, 3],
        'annotation' || 'block-update' => [4],
        'task-update' || 'remove-relation' => [6],
        'relation' => [0, 6],
        _ => <int>[],
      };
      if (!sizes.contains(before.length)) throw const FormatException();
      if ((action == 'relation' || action == 'remove-relation') !=
          (r != null)) {
        throw const FormatException();
      }
      if (action.startsWith('task-') && value['task'] == null ||
          action.startsWith('block-') &&
              (value['task'] == null || value['target'] == null)) {
        throw const FormatException();
      }
      final identity = value['target'] == null
          ? null
          : _decodeIdentity(jsonEncode(value['target']));
      if (action.startsWith('task-')) {
        if (identity != null || r != null) throw const FormatException();
      } else if (action.startsWith('block-')) {
        if (identity?.kind != CalendarKind.planBlock || r != null) {
          throw const FormatException();
        }
      } else if (r != null) {
        if (identity != null || value['task'] != null) {
          throw const FormatException();
        }
        _decodeIdentity(r[2] as String);
        _decodeIdentity(r[3] as String);
        if (before.isNotEmpty &&
            (before[0] != r[0] ||
                before[1] != r[2] ||
                before[2] != r[3] ||
                before[5] is! int)) {
          throw const FormatException();
        }
      } else if (action == 'annotation') {
        if (identity == null ||
            ![
              CalendarKind.course,
              CalendarKind.exam,
              CalendarKind.young,
            ].contains(identity.kind) ||
            value['task'] != null) {
          throw const FormatException();
        }
      } else if (identity?.kind != CalendarKind.personal ||
          value['task'] != null) {
        throw const FormatException();
      }
      return value;
    } on Object {
      throw const CalendarFailure(CalendarFailureCode.storageFailed);
    }
  }

  Future<void> _checkUndo(
    QueryRow row,
    Map<String, dynamic> payload,
    CalendarContext context,
  ) async {
    final c = payload['context'] as List;
    if (!_db._clock.nowUtc.isUtc) {
      throw const CalendarFailure(CalendarFailureCode.storageFailed);
    }
    if (c[0] != context.owner ||
        c[1] != context.resetEpoch ||
        c[2] != context.agendaEpoch ||
        _db._clock.nowUtc.microsecondsSinceEpoch >=
            row.read<int>('expires_at')) {
      throw const CalendarFailure(CalendarFailureCode.undoUnavailable);
    }
    final expected = <(String, int)>{};
    if (payload['relation'] != null) {
      final r = payload['relation'] as List;
      expected.addAll([
        await _aggregateKey(_decodeIdentity(r[2] as String)),
        await _aggregateKey(_decodeIdentity(r[3] as String)),
      ]);
    } else if (payload['task'] != null) {
      expected.add(('task', payload['task'] as int));
      if (payload['target'] != null &&
          await _aggregateKey(_decodeIdentity(jsonEncode(payload['target']))) !=
              ('task', payload['task'] as int)) {
        throw const CalendarFailure(CalendarFailureCode.storageFailed);
      }
    } else {
      expected.add(
        await _aggregateKey(_decodeIdentity(jsonEncode(payload['target']))),
      );
    }
    final actual = {
      for (final g in payload['guards'] as List) (g[0] as String, g[1] as int),
    };
    if (actual.length != expected.length || !actual.containsAll(expected)) {
      throw const CalendarFailure(CalendarFailureCode.storageFailed);
    }
    for (final g in payload['guards'] as List) {
      if (await _aggregateVersion((g[0] as String, g[1] as int)) != g[2]) {
        throw const CalendarFailure(CalendarFailureCode.undoConflict);
      }
    }
    final r = payload['relation'] as List?;
    if (r != null) {
      final found = await _db
          .customSelect(
            'SELECT * FROM agenda_relations WHERE local_id=? OR (left_identity=? AND right_identity=?)',
            variables: [
              Variable.withInt(r[0] as int),
              Variable.withString(r[2] as String),
              Variable.withString(r[3] as String),
            ],
          )
          .get();
      if (payload['action'] == 'remove-relation') {
        if (found.isNotEmpty) {
          throw const CalendarFailure(CalendarFailureCode.undoConflict);
        }
      } else if (found.length != 1 ||
          found.single.read<int>('local_id') != r[0] ||
          found.single.read<int>('version') != r[1] ||
          found.single.read<String>('left_identity') != r[2] ||
          found.single.read<String>('right_identity') != r[3]) {
        throw const CalendarFailure(CalendarFailureCode.undoConflict);
      }
    }
  }

  Future<CalendarUndoView> _queryUndo(CalendarContext context) => _serial(
    () => _db.transaction(() async {
      await _guard(context);
      final row = await _db
          .customSelect('SELECT * FROM agenda_undo WHERE singleton=1')
          .getSingleOrNull();
      if (row == null) return const CalendarUndoView();
      final payload = _decodeUndo(row.read<String>('payload'));
      CalendarFailureCode? failure;
      try {
        await _checkUndo(row, payload, context);
      } on CalendarFailure catch (e) {
        failure = e.code;
      }
      await _guard(context);
      return CalendarUndoView(
        reference: CalendarUndoReference(context, row.read<String>('undo_id')),
        action: payload['action'] as String,
        createdAtUtc: _time(row.read<int>('created_at')),
        expiresAtUtc: _time(row.read<int>('expires_at')),
        failure: failure,
      );
    }),
  );

  Future<(CalendarReference?, TaskReference?, CalendarRelationReference?)>
  _applyUndo(CalendarUndoReference reference) async {
    final row = await _db
        .customSelect(
          'SELECT * FROM agenda_undo WHERE singleton=1 AND undo_id=?',
          variables: [Variable.withString(reference.undoId)],
        )
        .getSingleOrNull();
    if (row == null) {
      throw const CalendarFailure(CalendarFailureCode.undoUnavailable);
    }
    final p = _decodeUndo(row.read<String>('payload'));
    await _checkUndo(row, p, reference.context);
    final action = p['action'] as String;
    final b = p['before'] as List;
    final identity = p['target'] == null
        ? null
        : _decodeIdentity(jsonEncode(p['target']));
    final taskId = p['task'] as int?;
    final r = p['relation'] as List?;
    CalendarRelationReference? relation;
    try {
      switch (action) {
        case 'create':
          await _db.customStatement(
            'UPDATE personal_events SET deleted=1 WHERE local_id=?',
            [identity!.localId],
          );
        case 'series':
          _decodeDraft(b[0] as String);
          await _db.customStatement(
            'UPDATE personal_events SET draft_json=? WHERE local_id=?',
            [b[0], identity!.localId],
          );
        case 'delete':
          await _db.customStatement(
            'UPDATE personal_events SET deleted=? WHERE local_id=?',
            [b[0] as int, identity!.localId],
          );
        case 'occurrence' || 'state':
          if (b.isEmpty) {
            await _db.customStatement(
              'DELETE FROM personal_occurrence_overrides WHERE local_id=? AND ordinal=?',
              [identity!.localId, identity.ordinal],
            );
          } else {
            if (b[0] != null) _decodeDraft(b[0] as String);
            await _db.customStatement(
              'INSERT INTO personal_occurrence_overrides(local_id,ordinal,replacement_json,completed,skipped) VALUES (?,?,?,?,?) ON CONFLICT(local_id,ordinal) DO UPDATE SET replacement_json=excluded.replacement_json,completed=excluded.completed,skipped=excluded.skipped',
              [
                identity!.localId,
                identity.ordinal,
                b[0] as String?,
                b[1] as int,
                b[2] as int,
              ],
            );
          }
        case 'annotation':
          final young = identity!.kind == CalendarKind.young;
          await _db.customStatement(
            young
                ? 'UPDATE young_overlays SET hidden=COALESCE(?,hidden),note=COALESCE(?,note),attendance=COALESCE(?,attendance) WHERE local_id=?'
                : 'UPDATE jw_overlays SET hidden=COALESCE(?,hidden),note=COALESCE(?,note),attendance=COALESCE(?,attendance),listening=COALESCE(?,listening) WHERE local_id=?',
            [
              b[0] as int?,
              b[1] as String?,
              b[2] as String?,
              if (!young) b[3] as String?,
              identity.localId,
            ],
          );
        case 'task-create':
          await _db.customStatement(
            'UPDATE local_tasks SET deleted=1 WHERE local_id=?',
            [taskId],
          );
        case 'task-update':
          _validateTaskDraft(
            TaskDraft(
              title: b[0] as String,
              description: b[1] as String,
              note: b[2] as String,
              deadlineAtUtc: b[3] == null ? null : _time(b[3] as int),
              estimatedMinutes: b[4] as int?,
              priority: TaskPriority.values[b[5] as int],
            ),
          );
          await _db.customStatement(
            'UPDATE local_tasks SET title=?,description=?,note=?,deadline_at=?,estimated_minutes=?,priority=? WHERE local_id=?',
            [...b, taskId],
          );
        case 'task-status':
          await _db.customStatement(
            'UPDATE local_tasks SET status=? WHERE local_id=?',
            [b[0] as String, taskId],
          );
        case 'task-delete':
          await _db.customStatement(
            'UPDATE local_tasks SET deleted=? WHERE local_id=?',
            [b[0] as int, taskId],
          );
        case 'block-create':
          await _db.customStatement(
            'UPDATE local_plan_blocks SET deleted=1 WHERE local_id=?',
            [identity!.localId],
          );
        case 'block-update':
          _validateBlockDraft(
            PlanBlockDraft(
              startsAtUtc: _time(b[0] as int),
              endsAtUtc: _time(b[1] as int),
              location: b[2] as String,
              note: b[3] as String,
            ),
          );
          await _db.customStatement(
            'UPDATE local_plan_blocks SET starts_at=?,ends_at=?,location=?,note=? WHERE local_id=?',
            [...b, identity!.localId],
          );
        case 'block-status':
          await _db.customStatement(
            'UPDATE local_plan_blocks SET status=? WHERE local_id=?',
            [b[0] as String, identity!.localId],
          );
        case 'block-delete':
          await _db.customStatement(
            'UPDATE local_plan_blocks SET deleted=? WHERE local_id=?',
            [b[0] as int, identity!.localId],
          );
        case 'relation':
          if (b.isEmpty) {
            await _db.customStatement(
              'DELETE FROM agenda_relations WHERE local_id=?',
              [r![0]],
            );
          } else {
            await _db.customStatement(
              'UPDATE agenda_relations SET kind=?,note=?,version=version+1 WHERE local_id=?',
              [b[3] as String, b[4] as String, r![0]],
            );
            relation = CalendarRelationReference(
              reference.context,
              r[0] as int,
              (r[1] as int) + 1,
            );
          }
        case 'remove-relation':
          await _db.customStatement(
            'INSERT INTO agenda_relations(local_id,left_identity,right_identity,kind,note,version) VALUES (?,?,?,?,?,?)',
            [
              b[0] as int,
              b[1] as String,
              b[2] as String,
              b[3] as String,
              b[4] as String,
              (b[5] as int) + 2,
            ],
          );
          relation = CalendarRelationReference(
            reference.context,
            b[0] as int,
            (b[5] as int) + 2,
          );
        default:
          throw const CalendarFailure(CalendarFailureCode.storageFailed);
      }
    } on CalendarFailure {
      rethrow;
    } on Object {
      throw const CalendarFailure(CalendarFailureCode.storageFailed);
    }
    final keys = [
      for (final g in p['guards'] as List) (g[0] as String, g[1] as int),
    ];
    await _touchAggregates(keys);
    await _db.customStatement(
      'DELETE FROM agenda_undo WHERE singleton=1 AND undo_id=?',
      [reference.undoId],
    );
    final target = identity == null
        ? null
        : CalendarReference(
            reference.context,
            identity,
            await _aggregateVersion(await _aggregateKey(identity)),
          );
    final task = taskId == null
        ? null
        : TaskReference(
            reference.context,
            taskId,
            await _aggregateVersion(('task', taskId)),
          );
    return (target, task, relation);
  }
}
