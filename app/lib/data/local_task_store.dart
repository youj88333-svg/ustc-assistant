part of 'jw_store.dart';

const _taskSchema = <String>[
  '''CREATE TABLE local_tasks (
    local_id INTEGER PRIMARY KEY AUTOINCREMENT, version INTEGER NOT NULL CHECK(version>0),
    title TEXT NOT NULL CHECK(length(title) BETWEEN 1 AND 200),
    description TEXT NOT NULL CHECK(length(description)<=4000),
    note TEXT NOT NULL CHECK(length(note)<=4000), deadline_at INTEGER,
    estimated_minutes INTEGER CHECK(estimated_minutes BETWEEN 1 AND 527040),
    priority INTEGER NOT NULL CHECK(priority BETWEEN 0 AND 2),
    status TEXT NOT NULL CHECK(status IN ('active','blocked','completed','cancelled')),
    deleted INTEGER NOT NULL CHECK(deleted IN (0,1)),
    created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)''',
  '''CREATE TABLE local_plan_blocks (
    local_id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id INTEGER NOT NULL REFERENCES local_tasks(local_id),
    starts_at INTEGER NOT NULL, ends_at INTEGER NOT NULL CHECK(ends_at>starts_at),
    location TEXT NOT NULL CHECK(length(location)<=200),
    note TEXT NOT NULL CHECK(length(note)<=4000),
    status TEXT NOT NULL CHECK(status IN ('planned','done','skipped')),
    deleted INTEGER NOT NULL CHECK(deleted IN (0,1)))''',
  'CREATE INDEX local_blocks_window ON local_plan_blocks(starts_at,ends_at,task_id)',
  'CREATE INDEX local_tasks_order ON local_tasks(deleted,status,priority,deadline_at)',
  '''CREATE TABLE agenda_undo (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1), undo_id TEXT NOT NULL,
    payload TEXT NOT NULL CHECK(length(payload)<=65536), created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL CHECK(expires_at>created_at))''',
  'ALTER TABLE agenda_receipts ADD COLUMN task_json TEXT',
  'ALTER TABLE agenda_receipts ADD COLUMN undo_id TEXT',
  '''CREATE TABLE agenda_audit_v9 (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    action TEXT NOT NULL CHECK(action IN ('create','series','occurrence','state','delete',
      'annotation','relation','remove-relation','task-create','task-update','task-status',
      'task-delete','block-create','block-update','block-status','block-delete','undo')),
    item_count INTEGER NOT NULL CHECK(item_count>=0), committed_at INTEGER NOT NULL)''',
  'INSERT INTO agenda_audit_v9 SELECT * FROM agenda_audit',
  "INSERT INTO sqlite_sequence(name,seq) SELECT 'agenda_audit_v9',COALESCE((SELECT seq FROM sqlite_sequence WHERE name='agenda_audit'),0) WHERE NOT EXISTS(SELECT 1 FROM sqlite_sequence WHERE name='agenda_audit_v9')",
  "UPDATE sqlite_sequence SET seq=MAX(seq,COALESCE((SELECT seq FROM sqlite_sequence WHERE name='agenda_audit'),0)) WHERE name='agenda_audit_v9'",
  'DROP TABLE agenda_audit',
  'ALTER TABLE agenda_audit_v9 RENAME TO agenda_audit',
];

extension _TaskStorage on LocalCalendarStore {
  void _taskText(String value, int limit, {bool title = false}) {
    if (value.length > limit ||
        value.contains('\u0000') ||
        (title && (value.trim().isEmpty || value.trim() != value))) {
      throw const CalendarFailure(CalendarFailureCode.invalidInput);
    }
  }

  void _validateTaskDraft(TaskDraft draft) {
    _taskText(draft.title, 200, title: true);
    _taskText(draft.description, 4000);
    _taskText(draft.note, 4000);
    if ((draft.deadlineAtUtc != null &&
            (!draft.deadlineAtUtc!.isUtc ||
                draft.deadlineAtUtc!.year < 1 ||
                draft.deadlineAtUtc!.year > 9998)) ||
        (draft.estimatedMinutes != null &&
            (draft.estimatedMinutes! < 1 ||
                draft.estimatedMinutes! > 527040))) {
      throw const CalendarFailure(CalendarFailureCode.invalidInput);
    }
  }

  void _validateBlockDraft(PlanBlockDraft draft) {
    _taskText(draft.location, 200);
    _taskText(draft.note, 4000);
    if (!draft.startsAtUtc.isUtc ||
        !draft.endsAtUtc.isUtc ||
        draft.startsAtUtc.year < 1 ||
        draft.endsAtUtc.year > 9998 ||
        !draft.endsAtUtc.isAfter(draft.startsAtUtc) ||
        draft.endsAtUtc.difference(draft.startsAtUtc) >
            const Duration(days: 366)) {
      throw const CalendarFailure(CalendarFailureCode.invalidInput);
    }
  }

  void _validateTaskRef(CalendarContext context, TaskReference target) {
    if (target.context != context || target.localId < 1 || target.version < 1) {
      throw const CalendarFailure(CalendarFailureCode.invalidInput);
    }
  }

  Future<QueryRow> _taskRow(
    TaskReference target, {
    bool allowDeleted = false,
  }) async {
    final row = await _db
        .customSelect(
          'SELECT * FROM local_tasks WHERE local_id=?',
          variables: [Variable.withInt(target.localId)],
        )
        .getSingleOrNull();
    if (row == null ||
        row.read<int>('version') != target.version ||
        (!allowDeleted && row.read<int>('deleted') != 0)) {
      throw const CalendarFailure(CalendarFailureCode.staleReference);
    }
    return row;
  }

  TaskRecord _taskRecord(
    QueryRow row,
    CalendarContext context, {
    required int count,
  }) => TaskRecord(
    reference: TaskReference(
      context,
      row.read<int>('local_id'),
      row.read<int>('version'),
    ),
    draft: TaskDraft(
      title: row.read<String>('title'),
      description: row.read<String>('description'),
      note: row.read<String>('note'),
      deadlineAtUtc: row.read<int?>('deadline_at') == null
          ? null
          : DateTime.fromMicrosecondsSinceEpoch(
              row.read<int>('deadline_at'),
              isUtc: true,
            ),
      estimatedMinutes: row.read<int?>('estimated_minutes'),
      priority: TaskPriority.values[row.read<int>('priority')],
    ),
    status: TaskStatus.values.firstWhere(
      (s) => s.name == row.read<String>('status'),
    ),
    createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
      row.read<int>('created_at'),
      isUtc: true,
    ),
    updatedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
      row.read<int>('updated_at'),
      isUtc: true,
    ),
    blockCount: count,
  );

  Future<TaskWindow> _queryTasks(TaskQuery query) => _serial(
    () => _db.transaction(() async {
      if (query.limit < 1 ||
          query.limit > 500 ||
          query.keyword.length > 200 ||
          query.keyword.contains('\u0000')) {
        throw const CalendarFailure(CalendarFailureCode.invalidInput);
      }
      final context = await _context();
      final status = switch (query.filter) {
        TaskFilter.all => '',
        TaskFilter.open => "AND status IN ('active','blocked')",
        _ => "AND status='${query.filter.name}'",
      };
      final vars = [Variable.withString(query.keyword.trim())];
      final where = "deleted=0 $status AND instr(lower(title),lower(?))>0";
      final count =
          (await _db
                  .customSelect(
                    'SELECT COUNT(*) AS count FROM local_tasks WHERE $where',
                    variables: vars,
                  )
                  .getSingle())
              .read<int>('count');
      final rows = await _db
          .customSelect(
            'SELECT t.*, (SELECT COUNT(*) FROM local_plan_blocks b WHERE b.task_id=t.local_id AND b.deleted=0) AS blocks FROM local_tasks t WHERE $where ORDER BY priority DESC,deadline_at IS NULL,deadline_at,created_at DESC,local_id LIMIT ${query.limit}',
            variables: vars,
          )
          .get();
      await _guard(context);
      return TaskWindow(
        context: context,
        revision: (await _agendaState()).read<int>('revision'),
        query: query,
        items: [
          for (final row in rows)
            _taskRecord(row, context, count: row.read<int>('blocks')),
        ],
        matched: count,
        truncated: count > rows.length,
      );
    }),
  );

  PlanBlockRecord _blockRecord(QueryRow row, CalendarContext context) =>
      PlanBlockRecord(
        reference: CalendarReference(
          context,
          CalendarIdentity(CalendarKind.planBlock, row.read<int>('block_id')),
          row.read<int>('version'),
        ),
        task: TaskReference(
          context,
          row.read<int>('task_id'),
          row.read<int>('version'),
        ),
        taskTitle: row.read<String>('title'),
        taskStatus: TaskStatus.values.firstWhere(
          (s) => s.name == row.read<String>('task_status'),
        ),
        draft: PlanBlockDraft(
          startsAtUtc: DateTime.fromMicrosecondsSinceEpoch(
            row.read<int>('starts_at'),
            isUtc: true,
          ),
          endsAtUtc: DateTime.fromMicrosecondsSinceEpoch(
            row.read<int>('ends_at'),
            isUtc: true,
          ),
          location: row.read<String>('location'),
          note: row.read<String>('note'),
        ),
        status: PlanBlockStatus.values.firstWhere(
          (s) => s.name == row.read<String>('block_status'),
        ),
      );

  String get _blockSelect =>
      'SELECT b.local_id AS block_id,b.task_id,b.starts_at,b.ends_at,b.location,b.note,b.status AS block_status,t.version,t.title,t.status AS task_status FROM local_plan_blocks b JOIN local_tasks t ON t.local_id=b.task_id';

  Future<TaskDetail> _taskDetail(TaskReference reference) => _serial(
    () => _db.transaction(() async {
      await _guard(reference.context);
      final row = await _taskRow(reference);
      final blocks = await _db
          .customSelect(
            '$_blockSelect WHERE t.deleted=0 AND b.deleted=0 AND t.local_id=? ORDER BY b.starts_at,b.local_id LIMIT 5001',
            variables: [Variable.withInt(reference.localId)],
          )
          .get();
      if (blocks.length > 5000) {
        throw const CalendarFailure(CalendarFailureCode.limitExceeded);
      }
      await _guard(reference.context);
      return TaskDetail(
        task: _taskRecord(row, reference.context, count: blocks.length),
        blocks: [for (final b in blocks) _blockRecord(b, reference.context)],
        nowUtc: _db._clock.nowUtc,
      );
    }),
  );

  Future<PlanBlockRecord> _blockByRef(CalendarReference reference) async {
    final row = await _db
        .customSelect(
          '$_blockSelect WHERE b.local_id=? AND t.deleted=0 AND b.deleted=0',
          variables: [Variable.withInt(reference.identity.localId)],
        )
        .getSingleOrNull();
    if (row == null || row.read<int>('version') != reference.version) {
      throw const CalendarFailure(CalendarFailureCode.staleReference);
    }
    return _blockRecord(row, reference.context);
  }

  Future<List<CalendarOccurrence>> _blockOccurrences(
    CalendarContext context,
    CalendarQuery? query,
    Set<CalendarIdentity>? targets,
  ) async {
    final clauses = <String>[];
    final vars = <Variable>[];
    if (query != null) {
      final start = query.firstDay
          .subtract(const Duration(hours: 8))
          .microsecondsSinceEpoch;
      final end = query.endDayExclusive
          .subtract(const Duration(hours: 8))
          .microsecondsSinceEpoch;
      clauses.add('(b.starts_at<? AND b.ends_at>?)');
      vars.addAll([Variable.withInt(end), Variable.withInt(start)]);
    }
    final ids =
        targets
            ?.where((i) => i.kind == CalendarKind.planBlock)
            .map((i) => i.localId)
            .toSet()
            .toList() ??
        <int>[];
    if (ids.isNotEmpty) {
      clauses.add('b.local_id IN (${List.filled(ids.length, '?').join(',')})');
      vars.addAll(ids.map(Variable.withInt));
    }
    if (query == null && ids.isEmpty) return [];
    final rows = await _db
        .customSelect(
          '$_blockSelect WHERE t.deleted=0 AND b.deleted=0 AND (${clauses.join(' OR ')}) LIMIT 5001',
          variables: vars,
        )
        .get();
    if (rows.length > 5000) {
      throw const CalendarFailure(CalendarFailureCode.limitExceeded);
    }
    return [
      for (final row in rows) _blockOccurrence(_blockRecord(row, context)),
    ];
  }

  CalendarOccurrence _blockOccurrence(PlanBlockRecord block) =>
      CalendarOccurrence(
        reference: block.reference,
        title: block.taskTitle,
        startsAtUtc: block.draft.startsAtUtc,
        endsAtUtc: block.draft.endsAtUtc,
        location: block.draft.location,
        note: block.draft.note,
        completed: block.status == PlanBlockStatus.done,
        skipped: block.status == PlanBlockStatus.skipped,
        task: block.task,
        taskStatus: block.taskStatus,
        planBlockStatus: block.status,
      );

  Future<(TaskReference?, CalendarReference?)> _applyTask(
    CalendarCommand command,
  ) async {
    final intent = command.intent;
    final context = command.context;
    final now = _db._clock.nowUtc;
    if (!now.isUtc) {
      throw const CalendarFailure(CalendarFailureCode.storageFailed);
    }
    TaskReference? task;
    CalendarReference? block;
    switch (intent) {
      case CreateTask(:final draft):
        if (await _db._count(
              'SELECT COUNT(*) AS count FROM local_tasks WHERE deleted=0',
            ) >=
            5000) {
          throw const CalendarFailure(CalendarFailureCode.limitExceeded);
        }
        await _db.customStatement(
          'INSERT INTO local_tasks(version,title,description,note,deadline_at,estimated_minutes,priority,status,deleted,created_at,updated_at) VALUES (1,?,?,?,?,?,?,?,0,?,?)',
          [
            draft.title,
            draft.description,
            draft.note,
            draft.deadlineAtUtc?.microsecondsSinceEpoch,
            draft.estimatedMinutes,
            draft.priority.index,
            TaskStatus.active.name,
            now.microsecondsSinceEpoch,
            now.microsecondsSinceEpoch,
          ],
        );
        final id =
            (await _db
                    .customSelect('SELECT last_insert_rowid() AS id')
                    .getSingle())
                .read<int>('id');
        return (TaskReference(context, id, 1), null);
      case UpdateTask(:final target, :final draft):
        await _taskRow(target);
        task = target;
        await _db.customStatement(
          'UPDATE local_tasks SET title=?,description=?,note=?,deadline_at=?,estimated_minutes=?,priority=? WHERE local_id=?',
          [
            draft.title,
            draft.description,
            draft.note,
            draft.deadlineAtUtc?.microsecondsSinceEpoch,
            draft.estimatedMinutes,
            draft.priority.index,
            target.localId,
          ],
        );
      case SetTaskStatus(:final target, :final status):
        await _taskRow(target);
        task = target;
        await _db.customStatement(
          'UPDATE local_tasks SET status=? WHERE local_id=?',
          [status.name, target.localId],
        );
      case DeleteTask(:final target):
        await _taskRow(target);
        task = target;
        await _db.customStatement(
          'UPDATE local_tasks SET deleted=1 WHERE local_id=?',
          [target.localId],
        );
      case CreatePlanBlock(:final task, :final draft):
        await _taskRow(task);
        if (await _db._count(
              'SELECT COUNT(*) AS count FROM local_plan_blocks WHERE deleted=0',
            ) >=
            20000) {
          throw const CalendarFailure(CalendarFailureCode.limitExceeded);
        }
        await _db.customStatement(
          "INSERT INTO local_plan_blocks(task_id,starts_at,ends_at,location,note,status,deleted) VALUES (?,?,?,?,?,'planned',0)",
          [
            task.localId,
            draft.startsAtUtc.microsecondsSinceEpoch,
            draft.endsAtUtc.microsecondsSinceEpoch,
            draft.location,
            draft.note,
          ],
        );
        final id =
            (await _db
                    .customSelect('SELECT last_insert_rowid() AS id')
                    .getSingle())
                .read<int>('id');
        await _bumpTask(task.localId, now);
        return (
          TaskReference(context, task.localId, task.version + 1),
          CalendarReference(
            context,
            CalendarIdentity(CalendarKind.planBlock, id),
            task.version + 1,
          ),
        );
      case UpdatePlanBlock(:final target, :final draft):
        final current = await _blockByRef(target);
        task = current.task;
        block = target;
        await _db.customStatement(
          'UPDATE local_plan_blocks SET starts_at=?,ends_at=?,location=?,note=? WHERE local_id=?',
          [
            draft.startsAtUtc.microsecondsSinceEpoch,
            draft.endsAtUtc.microsecondsSinceEpoch,
            draft.location,
            draft.note,
            target.identity.localId,
          ],
        );
      case SetPlanBlockStatus(:final target, :final status):
        final current = await _blockByRef(target);
        task = current.task;
        block = target;
        await _db.customStatement(
          'UPDATE local_plan_blocks SET status=? WHERE local_id=?',
          [status.name, target.identity.localId],
        );
      case DeletePlanBlock(:final target):
        final current = await _blockByRef(target);
        task = current.task;
        block = target;
        await _db.customStatement(
          'UPDATE local_plan_blocks SET deleted=1 WHERE local_id=?',
          [target.identity.localId],
        );
      default:
        throw const CalendarFailure(CalendarFailureCode.invalidInput);
    }
    await _bumpTask(task.localId, now);
    return (
      TaskReference(context, task.localId, task.version + 1),
      block == null
          ? null
          : CalendarReference(context, block.identity, block.version + 1),
    );
  }

  Future<void> _bumpTask(int id, DateTime now) => _db.customStatement(
    'UPDATE local_tasks SET version=version+1,updated_at=? WHERE local_id=?',
    [now.microsecondsSinceEpoch, id],
  );
}
