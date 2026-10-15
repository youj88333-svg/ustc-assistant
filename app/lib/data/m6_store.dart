part of 'jw_store.dart';

/// Versioned desired input is captured inside each authoritative business
/// transaction. Native publishing/cleanup is deliberately outside this store.
final class M6Store
    implements
        ReminderDataPort,
        ReminderTargetShapePort,
        ReminderInspectionPort {
  M6Store._(this._db);
  final JwStore _db;
  final _changes = StreamController<int>.broadcast();
  static const schema = <String>[
    '''CREATE TABLE m6_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),
      revision INTEGER NOT NULL, brief_epoch INTEGER NOT NULL,
      reminders_enabled INTEGER NOT NULL, morning_enabled INTEGER NOT NULL,
      private_display INTEGER NOT NULL, timed_json TEXT NOT NULL, all_day_json TEXT NOT NULL)''',
    '''INSERT INTO m6_state VALUES(1,1,0,0,0,0,
      '[["before",30,0,0],["none",0,0,0]]','[["dayTime",0,0,540],["none",0,0,0]]')''',
    '''CREATE TABLE m6_expected(singleton INTEGER PRIMARY KEY CHECK(singleton=1),
      revision INTEGER NOT NULL, context_json TEXT NOT NULL, input_json TEXT,
      CHECK(input_json IS NULL OR length(input_json)<=8388608))''',
    "INSERT INTO m6_expected VALUES(1,0,'[]',NULL)",
    '''CREATE TABLE m6_reminder_overrides(kind TEXT NOT NULL, local_id INTEGER NOT NULL,
      ordinal INTEGER NOT NULL, pair_json TEXT NOT NULL,
      PRIMARY KEY(kind,local_id,ordinal))''',
    '''CREATE TABLE m6_native_map(logical_key TEXT PRIMARY KEY, native_id TEXT NOT NULL UNIQUE,
      token TEXT NOT NULL, context_json TEXT NOT NULL, kind TEXT NOT NULL,
      local_id INTEGER NOT NULL, ordinal INTEGER NOT NULL, target_version INTEGER NOT NULL,
      slot INTEGER NOT NULL, digest TEXT NOT NULL, due_at INTEGER NOT NULL,
      title TEXT NOT NULL, detail TEXT NOT NULL, location TEXT NOT NULL,
      accepted INTEGER NOT NULL CHECK(accepted IN (0,1)))''',
  ];

  @override
  Stream<int> get changes => _changes.stream;
  void _signal(int revision) {
    if (!_changes.isClosed) _changes.add(revision);
  }

  Future<QueryRow> _state() =>
      _db.customSelect('SELECT * FROM m6_state WHERE singleton=1').getSingle();
  List<Object> _contextJson(CalendarContext c) => [
    c.owner,
    c.resetEpoch,
    c.agendaEpoch,
  ];
  CalendarContext _decodeContext(String text) {
    final v = jsonDecode(text) as List;
    return CalendarContext(
      owner: v[0] as String,
      resetEpoch: v[1] as int,
      agendaEpoch: v[2] as int,
    );
  }

  ReminderPair _decodePair(Object? v) {
    final values = v as List;
    ReminderRule rule(Object? item) {
      final r = item as List;
      return switch (r[0]) {
        'none' => const ReminderRule.none(),
        'before' => ReminderRule.before(r[1] as int),
        'dayTime' => ReminderRule.dayTime(
          dayOffset: r[2] as int,
          minuteOfDay: r[3] as int,
        ),
        _ => throw const ReminderFailure(ReminderFailureCode.storageFailed),
      };
    }

    if (values.length != 2) {
      throw const ReminderFailure(ReminderFailureCode.storageFailed);
    }
    return ReminderPair(rule(values[0]), rule(values[1]));
  }

  Future<ReminderSettings> _readSettings() async {
    final state = await _state();
    return ReminderSettings(
      context: await _db.localCalendar._context(allowMaintenance: true),
      revision: state.read<int>('revision'),
      briefEpoch: state.read<int>('brief_epoch'),
      preferences: ReminderPreferences(
        enabled: state.read<int>('reminders_enabled') == 1,
        morningEnabled: state.read<int>('morning_enabled') == 1,
        privateDisplay: state.read<int>('private_display') == 1,
        timed: _decodePair(jsonDecode(state.read<String>('timed_json'))),
        allDay: _decodePair(jsonDecode(state.read<String>('all_day_json'))),
      ),
    );
  }

  @override
  Future<ReminderSettings> inspectReminders() => _db._serialized(_readSettings);

  Future<void> initialize() => _db._serialized(
    () => _db.transaction(() async {
      await _captureExpected();
      await _db.briefs._recoverInterrupted();
    }),
  );

  @override
  Future<void> saveReminderPreferences(
    ReminderSettings expected,
    ReminderPreferences preferences,
  ) => _db._serialized(
    () => _db.transaction(() async {
      await _db._guard();
      final actual = await _readSettings();
      if (actual.context != expected.context ||
          actual.revision != expected.revision) {
        throw const ReminderFailure(ReminderFailureCode.stale);
      }
      preferences.timed.validate(allDay: false);
      preferences.allDay.validate(allDay: true);
      await _db.customStatement(
        'UPDATE m6_state SET revision=revision+1,reminders_enabled=?,morning_enabled=?,private_display=?,timed_json=?,all_day_json=?,brief_epoch=brief_epoch+? WHERE singleton=1',
        [
          preferences.enabled ? 1 : 0,
          preferences.morningEnabled ? 1 : 0,
          preferences.privateDisplay ? 1 : 0,
          jsonEncode(preferences.timed.canonical),
          jsonEncode(preferences.allDay.canonical),
          preferences.morningEnabled != actual.preferences.morningEnabled
              ? 1
              : 0,
        ],
      );
      if (preferences.morningEnabled != actual.preferences.morningEnabled) {
        await _db.customStatement(
          "UPDATE m6_briefs SET ticket=NULL,phase='interrupted',summary='' WHERE ticket IS NOT NULL",
        );
      }
      await _captureExpected();
    }),
  );

  Future<ReminderTarget> _currentTarget(ReminderTarget target) async {
    await _db._guard();
    final context = await _db.localCalendar._context();
    if (context != target.context ||
        target.localId < 1 ||
        target.version < 1 ||
        target.ordinal < 0 ||
        target.kind != ReminderKind.personal && target.ordinal != 0) {
      throw const ReminderFailure(ReminderFailureCode.stale);
    }
    if (target.kind == ReminderKind.taskDeadline) {
      final row = await _db
          .customSelect(
            'SELECT version FROM local_tasks WHERE local_id=? AND deleted=0',
            variables: [Variable.withInt(target.localId)],
          )
          .getSingleOrNull();
      if (row == null || row.read<int>('version') != target.version) {
        throw const ReminderFailure(ReminderFailureCode.stale);
      }
      return target;
    }
    final identity = CalendarIdentity(
      CalendarKind.values.byName(target.kind.name),
      target.localId,
      ordinal: target.ordinal,
    );
    final snapshot = await _db.localCalendar._snapshot(targets: {identity});
    final current = const CalendarProjection().occurrence(snapshot, identity);
    if (current == null || current.reference.version != target.version) {
      throw const ReminderFailure(ReminderFailureCode.stale);
    }
    return ReminderTarget.calendar(current.reference);
  }

  Future<bool> _targetAllDay(ReminderTarget target, bool series) async {
    await _currentTarget(target);
    if (series && target.kind != ReminderKind.personal) {
      throw const ReminderFailure(ReminderFailureCode.invalidInput);
    }
    if (target.kind != ReminderKind.personal) return false;
    final identity = CalendarIdentity(
      CalendarKind.personal,
      target.localId,
      ordinal: target.ordinal,
    );
    final snapshot = await _db.localCalendar._snapshot(targets: {identity});
    return series
        ? snapshot.personal.single.draft.allDay
        : const CalendarProjection().occurrence(snapshot, identity)!.allDay;
  }

  Future<String?> _overrideJson(ReminderTarget target, bool series) async =>
      (await _db
              .customSelect(
                'SELECT pair_json FROM m6_reminder_overrides WHERE kind=? AND local_id=? AND ordinal=?',
                variables: [
                  Variable.withString(target.kind.name),
                  Variable.withInt(target.localId),
                  Variable.withInt(series ? -1 : target.ordinal),
                ],
              )
              .getSingleOrNull())
          ?.read<String>('pair_json');

  /// Caller owns C3's queue/transaction; publishing always happens afterwards.
  Future<void> _writePair(
    ReminderTarget target,
    ReminderPair? pair,
    bool series,
  ) async {
    final allDay = await _targetAllDay(target, series);
    pair?.validate(allDay: allDay);
    final params = <Object>[
      target.kind.name,
      target.localId,
      series ? -1 : target.ordinal,
    ];
    if (pair == null) {
      await _db.customStatement(
        'DELETE FROM m6_reminder_overrides WHERE kind=? AND local_id=? AND ordinal=?',
        params,
      );
    } else {
      await _db.customStatement(
        'INSERT INTO m6_reminder_overrides VALUES(?,?,?,?) ON CONFLICT(kind,local_id,ordinal) DO UPDATE SET pair_json=excluded.pair_json',
        [...params, jsonEncode(pair.canonical)],
      );
    }
  }

  @override
  Future<ReminderInspection> inspectReminder(
    ReminderTarget target, {
    bool series = false,
  }) => _db._serialized(() async {
    final allDay = await _targetAllDay(target, series);
    final settings = await _readSettings();
    var pairJson = await _overrideJson(target, series);
    var origin = pairJson == null
        ? ReminderPairOrigin.defaults
        : series
        ? ReminderPairOrigin.series
        : ReminderPairOrigin.target;
    if (pairJson == null && !series && target.kind == ReminderKind.personal) {
      pairJson = await _overrideJson(target, true);
      if (pairJson != null) origin = ReminderPairOrigin.series;
    }
    var pair = pairJson == null ? null : _decodePair(jsonDecode(pairJson));
    // Match ReminderProjection exactly: an incompatible exact override falls
    // back to defaults, rather than resurrecting the parent-series override.
    if (pair != null && !pair.supports(allDay: allDay)) {
      pair = null;
      origin = ReminderPairOrigin.defaults;
    }
    pair ??= allDay ? settings.preferences.allDay : settings.preferences.timed;
    pair.validate(allDay: allDay);
    var reason = 'ready';
    var hasTime = true;
    if (target.kind == ReminderKind.taskDeadline) {
      final row = await _db
          .customSelect(
            'SELECT deadline_at,status FROM local_tasks WHERE local_id=? AND deleted=0',
            variables: [Variable.withInt(target.localId)],
          )
          .getSingle();
      hasTime = row.read<int?>('deadline_at') != null;
      if (!hasTime) {
        reason = 'noDeadline';
      } else if (!['active', 'blocked'].contains(row.read<String>('status'))) {
        reason = 'taskInactive';
      }
    } else {
      final identity = CalendarIdentity(
        CalendarKind.values.byName(target.kind.name),
        target.localId,
        ordinal: target.ordinal,
      );
      final snapshot = await _db.localCalendar._snapshot(targets: {identity});
      final occurrence = const CalendarProjection().occurrence(
        snapshot,
        identity,
      )!;
      if (identity.kind == CalendarKind.planBlock) {
        if (occurrence.planBlockStatus != PlanBlockStatus.planned) {
          reason = 'blockInactive';
        }
      } else if (occurrence.hidden) {
        reason = 'hidden';
      } else if (occurrence.skipped) {
        reason = 'skipped';
      } else if (occurrence.completed) {
        reason = 'completed';
      } else if (occurrence.attendance == AttendanceDecision.skip) {
        reason = 'notAttending';
      }
    }
    final acceptedSlots = <int>[];
    // A persisted accepted bit alone is insufficient after a rule/state edit.
    // Compare current desired candidates and never expose OS IDs/tokens.
    if (!series && settings.preferences.enabled && reason == 'ready') {
      final row = await _db
          .customSelect('SELECT input_json FROM m6_expected WHERE singleton=1')
          .getSingle();
      final encoded = row.read<String?>('input_json');
      if (encoded != null) {
        final input = _decodeInput(encoded);
        final candidates = const ReminderProjection().resolve(input, target);
        final rows = await _db
            .customSelect(
              'SELECT * FROM m6_native_map WHERE kind=? AND local_id=? AND ordinal=? AND accepted=1',
              variables: [
                Variable.withString(target.kind.name),
                Variable.withInt(target.localId),
                Variable.withInt(target.ordinal),
              ],
            )
            .get();
        for (final row in rows) {
          final mapping = _mapping(row);
          if (mapping.target.context == target.context &&
              mapping.request.deliveryAtUtc.isAfter(_db._clock.nowUtc) &&
              candidates.any(
                (candidate) =>
                    candidate.logicalKey == mapping.logicalKey &&
                    candidate.digest == mapping.request.digest &&
                    candidate.fireAtUtc == mapping.request.deliveryAtUtc,
              )) {
            acceptedSlots.add(mapping.slot);
          }
        }
      }
    }
    return ReminderInspection(
      settings: settings,
      target: target,
      allDay: allDay,
      pair: pair,
      origin: origin,
      eligible: reason == 'ready',
      reason: reason,
      hasTime: hasTime,
      acceptedSlots: List.unmodifiable(acceptedSlots..sort()),
    );
  });

  @override
  Future<bool> reminderAllDay(ReminderTarget target, {bool series = false}) =>
      _db._serialized(() async {
        await _currentTarget(target);
        if (series && target.kind != ReminderKind.personal) {
          throw const ReminderFailure(ReminderFailureCode.invalidInput);
        }
        if (target.kind != ReminderKind.personal) return false;
        final snapshot = await _db.localCalendar._snapshot(
          targets: {
            CalendarIdentity(
              CalendarKind.personal,
              target.localId,
              ordinal: target.ordinal,
            ),
          },
        );
        return series
            ? snapshot.personal.single.draft.allDay
            : const CalendarProjection()
                  .occurrence(
                    snapshot,
                    CalendarIdentity(
                      CalendarKind.personal,
                      target.localId,
                      ordinal: target.ordinal,
                    ),
                  )!
                  .allDay;
      });

  @override
  Future<ReminderPair?> readReminderPair(
    ReminderTarget target, {
    bool series = false,
  }) => _db._serialized(() async {
    await _currentTarget(target);
    if (series && target.kind != ReminderKind.personal) {
      throw const ReminderFailure(ReminderFailureCode.invalidInput);
    }
    final row = await _db
        .customSelect(
          'SELECT pair_json FROM m6_reminder_overrides WHERE kind=? AND local_id=? AND ordinal=?',
          variables: [
            Variable.withString(target.kind.name),
            Variable.withInt(target.localId),
            Variable.withInt(series ? -1 : target.ordinal),
          ],
        )
        .getSingleOrNull();
    if (row == null) return null;
    final pair = _decodePair(jsonDecode(row.read<String>('pair_json')));
    var allDay = false;
    if (target.kind == ReminderKind.personal) {
      final snapshot = await _db.localCalendar._snapshot(
        targets: {
          CalendarIdentity(
            CalendarKind.personal,
            target.localId,
            ordinal: target.ordinal,
          ),
        },
      );
      allDay = series
          ? snapshot.personal.single.draft.allDay
          : const CalendarProjection()
                .occurrence(
                  snapshot,
                  CalendarIdentity(
                    CalendarKind.personal,
                    target.localId,
                    ordinal: target.ordinal,
                  ),
                )!
                .allDay;
    }
    // Preserve an override across timed/all-day conversion, but inherit the
    // appropriate default while its original rule type does not apply.
    return pair.supports(allDay: allDay) ? pair : null;
  });

  @override
  Future<void> saveReminderPair(
    ReminderTarget target,
    ReminderPair? pair, {
    bool series = false,
  }) => _db._serialized(
    () => _db.transaction(() async {
      await _currentTarget(target);
      if (series && target.kind != ReminderKind.personal) {
        throw const ReminderFailure(ReminderFailureCode.invalidInput);
      }
      var allDay = false;
      if (target.kind == ReminderKind.personal) {
        final snapshot = await _db.localCalendar._snapshot(
          targets: {
            CalendarIdentity(
              CalendarKind.personal,
              target.localId,
              ordinal: target.ordinal,
            ),
          },
        );
        allDay = const CalendarProjection()
            .occurrence(
              snapshot,
              CalendarIdentity(
                CalendarKind.personal,
                target.localId,
                ordinal: target.ordinal,
              ),
            )!
            .allDay;
        if (series) allDay = snapshot.personal.single.draft.allDay;
      }
      pair?.validate(allDay: allDay);
      final params = <Object>[
        target.kind.name,
        target.localId,
        series ? -1 : target.ordinal,
      ];
      if (pair == null) {
        await _db.customStatement(
          'DELETE FROM m6_reminder_overrides WHERE kind=? AND local_id=? AND ordinal=?',
          params,
        );
      } else {
        await _db.customStatement(
          'INSERT INTO m6_reminder_overrides VALUES(?,?,?,?) ON CONFLICT(kind,local_id,ordinal) DO UPDATE SET pair_json=excluded.pair_json',
          [...params, jsonEncode(pair.canonical)],
        );
      }
      await _db.customStatement(
        'UPDATE m6_state SET revision=revision+1 WHERE singleton=1',
      );
      await _captureExpected();
    }),
  );

  /// Caller owns the current business transaction and serialized queue.
  Future<void> _captureExpected() async {
    final settings = await _readSettings();
    final context = settings.context;
    String? encoded;
    if (settings.preferences.enabled) {
      final snapshot = await _db.localCalendar._snapshot(
        includeAllBlocks: true,
      );
      final deadlines = await _db
          .customSelect(
            'SELECT local_id,version,title,deadline_at,status FROM local_tasks WHERE deleted=0 AND deadline_at IS NOT NULL ORDER BY local_id',
          )
          .get();
      final overrides = await _db
          .customSelect(
            'SELECT * FROM m6_reminder_overrides ORDER BY kind,local_id,ordinal',
          )
          .get();
      encoded = jsonEncode({
        'context': _contextJson(context),
        'revision': snapshot.revision,
        'school': snapshot.school.map(_encodeOccurrence).toList(),
        'blocks': snapshot.planBlocks.map(_encodeOccurrence).toList(),
        'personal': snapshot.personal
            .map((s) => [s.localId, s.version, _encodeDraft(s.draft)])
            .toList(),
        'exceptions': snapshot.overrides
            .map(
              (o) => [
                o.localId,
                o.ordinal,
                o.replacement == null ? null : _encodeDraft(o.replacement!),
                o.completed,
                o.skipped,
              ],
            )
            .toList(),
        'deadlines': deadlines
            .map(
              (r) => [
                r.read<int>('local_id'),
                r.read<int>('version'),
                r.read<String>('title'),
                r.read<int>('deadline_at'),
                r.read<String>('status'),
              ],
            )
            .toList(),
        'overrides': overrides
            .map(
              (r) => [
                r.read<String>('kind'),
                r.read<int>('local_id'),
                r.read<int>('ordinal'),
                jsonDecode(r.read<String>('pair_json')),
              ],
            )
            .toList(),
        'preferences': [
          settings.preferences.privateDisplay,
          settings.preferences.timed.canonical,
          settings.preferences.allDay.canonical,
        ],
      });
    }
    await _db.customStatement(
      'UPDATE m6_expected SET revision=revision+1,context_json=?,input_json=? WHERE singleton=1',
      [jsonEncode(_contextJson(context)), encoded],
    );
    _db._m6Changed = 0;
  }

  List<Object?> _encodeOccurrence(CalendarOccurrence o) => [
    ...o.reference.identity.canonical,
    o.reference.version,
    o.title,
    o.startsAtUtc.microsecondsSinceEpoch,
    o.endsAtUtc.microsecondsSinceEpoch,
    o.allDay,
    o.hidden,
    o.skipped,
    o.completed,
    o.attendance.name,
    o.listening.name,
    o.presence.name,
    o.location,
    o.planBlockStatus?.name,
    o.taskStatus?.name,
    o.task?.localId,
    o.task?.version,
  ];
  List<Object?> _encodeDraft(PersonalEventDraft d) => [
    d.title,
    d.start.microsecondsSinceEpoch,
    d.end.microsecondsSinceEpoch,
    d.allDay,
    d.weekly,
    d.untilDay?.microsecondsSinceEpoch,
    d.location,
    '',
  ];
  ReminderInput _decodeInput(String encoded) {
    final v = jsonDecode(encoded) as Map<String, dynamic>;
    final c = _decodeContext(jsonEncode(v['context']));
    DateTime time(Object value) =>
        DateTime.fromMicrosecondsSinceEpoch(value as int, isUtc: true);
    CalendarOccurrence item(Object value) {
      final o = value as List;
      return CalendarOccurrence(
        reference: CalendarReference(
          c,
          CalendarIdentity(
            CalendarKind.values.byName(o[0] as String),
            o[1] as int,
            ordinal: o[2] as int,
          ),
          o[3] as int,
        ),
        title: o[4] as String,
        startsAtUtc: time(o[5]),
        endsAtUtc: time(o[6]),
        allDay: o[7] as bool,
        hidden: o[8] as bool,
        skipped: o[9] as bool,
        completed: o[10] as bool,
        attendance: AttendanceDecision.values.byName(o[11] as String),
        listening: ListeningMode.values.byName(o[12] as String),
        presence: AgendaPresence.values.byName(o[13] as String),
        location: o[14] as String,
        planBlockStatus: o[15] == null
            ? null
            : PlanBlockStatus.values.byName(o[15] as String),
        taskStatus: o[16] == null
            ? null
            : TaskStatus.values.byName(o[16] as String),
        task: o[17] == null
            ? null
            : TaskReference(c, o[17] as int, o[18] as int),
      );
    }

    PersonalEventDraft draft(Object value) =>
        _db.localCalendar._decodeDraft(jsonEncode(value));
    return ReminderInput(
      snapshot: CalendarSnapshot(
        context: c,
        revision: v['revision'] as int,
        school: (v['school'] as List)
            .map((value) => item(value as Object))
            .toList(),
        planBlocks: (v['blocks'] as List)
            .map((value) => item(value as Object))
            .toList(),
        personal: (v['personal'] as List).map((value) {
          final s = value as List;
          return PersonalSeries(
            localId: s[0] as int,
            version: s[1] as int,
            draft: draft(s[2]),
          );
        }).toList(),
        overrides: (v['exceptions'] as List).map((value) {
          final o = value as List;
          return PersonalOccurrenceOverride(
            localId: o[0] as int,
            ordinal: o[1] as int,
            replacement: o[2] == null ? null : draft(o[2]),
            completed: o[3] as bool,
            skipped: o[4] as bool,
          );
        }).toList(),
        relations: const [],
      ),
      deadlines: (v['deadlines'] as List).map((value) {
        final d = value as List;
        return ReminderDeadline(
          reference: TaskReference(c, d[0] as int, d[1] as int),
          title: d[2] as String,
          deadlineAtUtc: time(d[3]),
          status: TaskStatus.values.byName(d[4] as String),
        );
      }).toList(),
      overrides: (v['overrides'] as List).map((value) {
        final o = value as List;
        return ReminderOverride(
          kind: ReminderKind.values.byName(o[0] as String),
          localId: o[1] as int,
          ordinal: o[2] as int,
          pair: _decodePair(o[3]),
        );
      }).toList(),
      preferences: ReminderPreferences(
        enabled: true,
        privateDisplay: (v['preferences'] as List)[0] as bool,
        timed: _decodePair((v['preferences'] as List)[1]),
        allDay: _decodePair((v['preferences'] as List)[2]),
      ),
    );
  }

  ReminderMapping _mapping(QueryRow r) => ReminderMapping(
    logicalKey: r.read<String>('logical_key'),
    target: ReminderTarget(
      _decodeContext(r.read<String>('context_json')),
      ReminderKind.values.byName(r.read<String>('kind')),
      r.read<int>('local_id'),
      r.read<int>('ordinal'),
      r.read<int>('target_version'),
    ),
    slot: r.read<int>('slot'),
    accepted: r.read<int>('accepted') == 1,
    request: NotificationRequest(
      id: r.read<String>('native_id'),
      deliveryAtUtc: DateTime.fromMicrosecondsSinceEpoch(
        r.read<int>('due_at'),
        isUtc: true,
      ),
      digest: r.read<String>('digest'),
      token: r.read<String>('token'),
      title: r.read<String>('title'),
      detail: r.read<String>('detail'),
      location: r.read<String>('location'),
    ),
  );

  @override
  Future<ReminderPublication> prepareReminderPublication() => _db._serialized(
    () => _db.transaction(() async {
      await _db._guard();
      final row = await _db
          .customSelect('SELECT * FROM m6_expected WHERE singleton=1')
          .getSingle();
      final context = _decodeContext(row.read<String>('context_json'));
      if (context != await _db.localCalendar._context()) {
        throw const ReminderFailure(ReminderFailureCode.stale);
      }
      final encoded = row.read<String?>('input_json');
      final input = encoded == null ? null : _decodeInput(encoded);
      final old = (await _db.customSelect('SELECT * FROM m6_native_map').get())
          .map(_mapping)
          .toList();
      final now = _db._clock.nowUtc;
      final projected = input == null
          ? null
          : const ReminderProjection().project(input, now);
      final invalid = <String>[];
      final selectedKeys = {
        for (final candidate in projected?.items ?? <ReminderCandidate>[])
          candidate.logicalKey,
      };
      for (final previous in old) {
        final candidates =
            input == null || previous.target.context != input.snapshot.context
            ? <ReminderCandidate>[]
            : const ReminderProjection().resolve(input, previous.target);
        final current = candidates.where(
          (c) => c.logicalKey == previous.logicalKey,
        );
        if (current.isEmpty ||
            current.single.digest != previous.request.digest ||
            current.single.fireAtUtc != previous.request.deliveryAtUtc ||
            previous.request.deliveryAtUtc.isBefore(
              now.subtract(const Duration(days: 30)),
            ) ||
            // Known, individually re-resolved future candidates outside the
            // nearest planning budget must not occupy slots ahead of new ones.
            (previous.request.deliveryAtUtc.isAfter(now) &&
                !selectedKeys.contains(previous.logicalKey))) {
          invalid.add(previous.request.id);
        }
      }
      final desired = <ReminderMapping>[];
      for (final candidate in projected?.items ?? <ReminderCandidate>[]) {
        final prior = old
            .where((m) => m.logicalKey == candidate.logicalKey)
            .firstOrNull;
        final id =
            prior?.request.id ?? JwStore._randomHexId('').substring(0, 16);
        final token = prior?.request.token ?? JwStore._randomHexId('');
        final target = candidate.target;
        final accepted =
            prior != null &&
            prior.accepted &&
            prior.request.digest == candidate.digest &&
            prior.request.deliveryAtUtc == candidate.fireAtUtc;
        await _db.customStatement(
          'INSERT INTO m6_native_map VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(logical_key) DO UPDATE SET context_json=excluded.context_json,target_version=excluded.target_version,digest=excluded.digest,due_at=excluded.due_at,title=excluded.title,detail=excluded.detail,location=excluded.location,accepted=excluded.accepted',
          [
            candidate.logicalKey,
            id,
            token,
            jsonEncode(_contextJson(context)),
            target.kind.name,
            target.localId,
            target.ordinal,
            target.version,
            candidate.slot,
            candidate.digest,
            candidate.fireAtUtc.microsecondsSinceEpoch,
            candidate.title,
            candidate.detail,
            candidate.location,
            accepted ? 1 : 0,
          ],
        );
        desired.add(
          ReminderMapping(
            logicalKey: candidate.logicalKey,
            target: target,
            slot: candidate.slot,
            accepted: accepted,
            request: NotificationRequest(
              id: id,
              deliveryAtUtc: candidate.fireAtUtc,
              digest: candidate.digest,
              token: token,
              title: candidate.title,
              detail: candidate.detail,
              location: candidate.location,
            ),
          ),
        );
      }
      return ReminderPublication(
        context: context,
        revision: row.read<int>('revision'),
        enabled: input != null,
        desired: desired,
        prior: old,
        invalidPriorIds: invalid,
        complete: projected?.complete ?? true,
        throughDay: projected?.throughDay ?? beijingDay(now),
      );
    }),
  );

  Future<bool> _publicationCurrent(ReminderPublication p) async {
    final row = await _db
        .customSelect(
          'SELECT revision,context_json FROM m6_expected WHERE singleton=1',
        )
        .getSingle();
    final agenda = await _db.localCalendar._agendaState();
    return agenda.read<int>('maintenance') == 0 &&
        !_db.localCalendar._maintenanceRequested &&
        p.context == await _db.localCalendar._context(allowMaintenance: true) &&
        p.revision == row.read<int>('revision') &&
        p.context == _decodeContext(row.read<String>('context_json'));
  }

  @override
  Future<bool> reminderPublicationCurrent(ReminderPublication publication) =>
      _db._serialized(() => _publicationCurrent(publication));
  @override
  Future<void> recordReminderAccepted(
    ReminderPublication publication,
    String id,
  ) => _db._serialized(
    () => _db.transaction(() async {
      if (!await _publicationCurrent(publication)) {
        throw const ReminderFailure(ReminderFailureCode.stale);
      }
      if (!publication.desired.any((m) => m.request.id == id)) {
        throw const ReminderFailure(ReminderFailureCode.invalidInput);
      }
      await _db.customStatement(
        'UPDATE m6_native_map SET accepted=1 WHERE native_id=?',
        [id],
      );
    }),
  );
  @override
  Future<void> recordReminderCancelled(String id) => _db._serialized(() async {
    await _db.customStatement(
      'UPDATE m6_native_map SET accepted=0 WHERE native_id=?',
      [id],
    );
    final row = await _db
        .customSelect(
          'SELECT * FROM m6_native_map WHERE native_id=?',
          variables: [Variable.withString(id)],
        )
        .getSingleOrNull();
    if (row == null) return;
    final mapping = _mapping(row);
    final expected = await _db
        .customSelect('SELECT input_json FROM m6_expected WHERE singleton=1')
        .getSingle();
    final encoded = expected.read<String?>('input_json');
    var keep = false;
    if (encoded != null &&
        !mapping.request.deliveryAtUtc.isBefore(
          _db._clock.nowUtc.subtract(const Duration(days: 30)),
        )) {
      final input = _decodeInput(encoded);
      if (input.snapshot.context == mapping.target.context) {
        keep = mapping.target.kind == ReminderKind.taskDeadline
            ? input.deadlines.any(
                (deadline) =>
                    deadline.reference.localId == mapping.target.localId,
              )
            : const CalendarProjection().occurrence(
                    input.snapshot,
                    CalendarIdentity(
                      CalendarKind.values.byName(mapping.target.kind.name),
                      mapping.target.localId,
                      ordinal: mapping.target.ordinal,
                    ),
                  ) !=
                  null;
      }
    }
    if (!keep) {
      await _db.customStatement('DELETE FROM m6_native_map WHERE native_id=?', [
        id,
      ]);
    }
  });
  Future<bool> requiresNativeCleanup() => _db._serialized(
    () async =>
        (await _state()).read<int>('reminders_enabled') == 1 ||
        await _db._count('SELECT COUNT(*) AS count FROM m6_native_map') > 0,
  );
  @override
  Future<ReminderTarget?> resolveNotification(
    NotificationActivation activation,
  ) => _db._serialized(() async {
    await _db._guard();
    final row = await _db
        .customSelect(
          'SELECT * FROM m6_native_map WHERE native_id=? AND token=? AND digest=? AND accepted=1',
          variables: [
            Variable.withString(activation.id),
            Variable.withString(activation.token),
            Variable.withString(activation.digest),
          ],
        )
        .getSingleOrNull();
    if (row == null) return null;
    final mapping = _mapping(row);
    final c = await _db.localCalendar._context();
    if (mapping.target.context != c) return null;
    final expected = await _db
        .customSelect('SELECT input_json FROM m6_expected WHERE singleton=1')
        .getSingle();
    final encoded = expected.read<String?>('input_json');
    if (encoded == null) return null;
    final input = _decodeInput(encoded);
    if (input.snapshot.context != c) return null;
    final current = const ReminderProjection()
        .resolve(input, mapping.target)
        .where(
          (candidate) =>
              candidate.logicalKey == mapping.logicalKey &&
              candidate.digest == mapping.request.digest &&
              candidate.fireAtUtc == mapping.request.deliveryAtUtc,
        );
    if (current.length != 1) return null;
    if (mapping.target.kind == ReminderKind.taskDeadline) {
      final task = await _db
          .customSelect(
            'SELECT version FROM local_tasks WHERE local_id=? AND deleted=0',
            variables: [Variable.withInt(mapping.target.localId)],
          )
          .getSingleOrNull();
      return task == null
          ? null
          : ReminderTarget(
              c,
              ReminderKind.taskDeadline,
              mapping.target.localId,
              0,
              task.read<int>('version'),
            );
    }
    final identity = CalendarIdentity(
      CalendarKind.values.byName(mapping.target.kind.name),
      mapping.target.localId,
      ordinal: mapping.target.ordinal,
    );
    final snapshot = await _db.localCalendar._snapshot(targets: {identity});
    final item = const CalendarProjection().occurrence(snapshot, identity);
    return item == null ? null : ReminderTarget.calendar(item.reference);
  });

  Future<void> _clearForMaintenance({required bool reset}) async {
    await _db.customStatement('DELETE FROM m6_reminder_overrides');
    await _db.customStatement('DELETE FROM m6_native_map');
    await _db.customStatement(
      'UPDATE m6_expected SET revision=revision+1,input_json=NULL,context_json=? WHERE singleton=1',
      [
        jsonEncode(
          _contextJson(
            await _db.localCalendar._context(allowMaintenance: true),
          ),
        ),
      ],
    );
    if (reset) {
      await _db.customStatement(
        "UPDATE m6_state SET revision=revision+1,reminders_enabled=0,morning_enabled=0,private_display=0,timed_json='[[\"before\",30,0,0],[\"none\",0,0,0]]',all_day_json='[[\"dayTime\",0,0,540],[\"none\",0,0,0]]' WHERE singleton=1",
      );
    }
    await _db.briefs._clearForMaintenance();
    _db._m6Changed = 0;
  }
}
