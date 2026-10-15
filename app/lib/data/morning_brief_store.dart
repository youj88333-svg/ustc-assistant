part of 'jw_store.dart';

final class MorningBriefStore implements MorningBriefDataPort {
  MorningBriefStore._(this._db);
  final JwStore _db;
  static const schema = <String>[
    '''CREATE TABLE m6_briefs(day TEXT PRIMARY KEY, context_json TEXT NOT NULL,
      epoch INTEGER NOT NULL, ticket TEXT, fact_digest TEXT NOT NULL,
      phase TEXT NOT NULL, notices_json TEXT CHECK(notices_json IS NULL OR length(notices_json)<=262144),
      summary TEXT NOT NULL CHECK(length(summary)<=10000), failure TEXT,
      auto_attempts INTEGER NOT NULL CHECK(auto_attempts BETWEEN 0 AND 2),
      auto_runs INTEGER NOT NULL CHECK(auto_runs BETWEEN 0 AND 2),
      input_tokens INTEGER, output_tokens INTEGER, changed_at INTEGER NOT NULL)''',
    'CREATE TABLE m6_brief_suppressed(day TEXT PRIMARY KEY)',
  ];
  @override
  Stream<int> get changes => _db.features.changes;
  String _day(DateTime day) {
    if (!day.isUtc || day != DateTime.utc(day.year, day.month, day.day)) {
      throw const ReminderFailure(ReminderFailureCode.invalidInput);
    }
    return day.toIso8601String().substring(0, 10);
  }

  DateTime _date(String day) => DateTime.parse('${day}T00:00:00Z');
  Future<QueryRow?> _row(DateTime day) => _db
      .customSelect(
        'SELECT * FROM m6_briefs WHERE day=?',
        variables: [Variable.withString(_day(day))],
      )
      .getSingleOrNull();

  Future<MorningFacts> _facts(DateTime day) async {
    _day(day);
    final end = day.add(const Duration(days: 1));
    final query = CalendarQuery(
      firstDay: day,
      endDayExclusive: end,
      includeSkipped: true,
    );
    final snapshot = await _db.localCalendar._snapshot(query: query);
    final window = const CalendarProjection().query(snapshot, query);
    final agenda = window.items
        .map(
          (o) => MorningAgendaItem(
            title: o.title,
            location: o.location,
            start: o.startsAtUtc,
            end: o.endsAtUtc,
            allDay: o.allDay,
            kind: o.reference.identity.kind.name,
            state: o.attendance == AttendanceDecision.skip
                ? 'skip'
                : o.skipped
                ? 'skipped'
                : o.completed
                ? 'completed'
                : o.planBlockStatus == PlanBlockStatus.done
                ? 'done'
                : 'planned',
          ),
        )
        .toList();
    final startUtc = day.subtract(const Duration(hours: 8));
    final endUtc = end.subtract(const Duration(hours: 8));
    final rows = await _db
        .customSelect(
          "SELECT title,deadline_at FROM local_tasks WHERE deleted=0 AND status IN ('active','blocked') AND deadline_at>=? AND deadline_at<? ORDER BY deadline_at,local_id LIMIT 101",
          variables: [
            Variable.withInt(startUtc.microsecondsSinceEpoch),
            Variable.withInt(endUtc.microsecondsSinceEpoch),
          ],
        )
        .get();
    final tasks = rows
        .take(100)
        .map(
          (r) => MorningTaskItem(
            r.read<String>('title'),
            DateTime.fromMicrosecondsSinceEpoch(
              r.read<int>('deadline_at'),
              isUtc: true,
            ),
          ),
        )
        .toList();
    final overdue = await _db._count(
      "SELECT COUNT(*) AS count FROM local_tasks WHERE deleted=0 AND status IN ('active','blocked') AND deadline_at<${_db._clock.nowUtc.microsecondsSinceEpoch}",
    );
    final school =
        await _db._count('SELECT COUNT(*) AS count FROM jw_imports') > 0 ||
        await _db._count('SELECT COUNT(*) AS count FROM young_events') > 0;
    final complete =
        !window.truncated && !window.conflictsTruncated && rows.length <= 100;
    final digest = fingerprint([
      _day(day),
      agenda.map((a) => a.canonical).toList(),
      tasks.map((t) => t.canonical).toList(),
      window.conflicts
          .where((c) => c.status == CalendarConflictStatus.conflict)
          .length,
      overdue,
      complete,
      school,
    ]);
    return MorningFacts(
      context: snapshot.context,
      day: day,
      digest: digest,
      agenda: agenda,
      tasks: tasks,
      conflicts: window.conflicts
          .where((c) => c.status == CalendarConflictStatus.conflict)
          .length,
      overdueTasks: overdue,
      complete: complete,
      hasSchoolImports: school,
    );
  }

  @override
  Future<MorningFacts> morningFacts(DateTime day) =>
      _db._serialized(() => _db.transaction(() => _facts(day)));

  String _encodeNotices(MorningNoticeBatch batch) => jsonEncode({
    'day': _day(batch.day),
    'operations': batch.operations,
    'items': batch.notices
        .map(
          (n) => [
            n.provider.name,
            n.title,
            n.articleUrl.toString(),
            _day(n.publishedDay),
            n.observedAtUtc.microsecondsSinceEpoch,
            n.excerpt,
          ],
        )
        .toList(),
    'coverage': batch.coverage
        .map(
          (c) => [
            c.provider.name,
            c.pages,
            c.matched,
            c.unknownDates,
            c.complete,
            c.failure?.name,
          ],
        )
        .toList(),
  });
  MorningNoticeBatch _decodeNotices(String encoded) {
    final v = jsonDecode(encoded) as Map<String, dynamic>;
    return MorningNoticeBatch(
      day: _date(v['day'] as String),
      operations: v['operations'] as int,
      notices: (v['items'] as List).map((value) {
        final n = value as List;
        return MorningNotice(
          provider: PublicProvider.values.byName(n[0] as String),
          title: n[1] as String,
          articleUrl: Uri.parse(n[2] as String),
          publishedDay: _date(n[3] as String),
          observedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
            n[4] as int,
            isUtc: true,
          ),
          excerpt: n[5] as String,
        );
      }).toList(),
      coverage: (v['coverage'] as List).map((value) {
        final c = value as List;
        return MorningNoticeCoverage(
          provider: PublicProvider.values.byName(c[0] as String),
          pages: c[1] as int,
          matched: c[2] as int,
          unknownDates: c[3] as int,
          complete: c[4] as bool,
          failure: c[5] == null
              ? null
              : PublicFailureCode.values.byName(c[5] as String),
        );
      }).toList(),
    );
  }

  MorningBrief _brief(QueryRow r) => MorningBrief(
    day: _date(r.read<String>('day')),
    phase: MorningBriefPhase.values.byName(r.read<String>('phase')),
    factDigest: r.read<String>('fact_digest'),
    autoAttempts: r.read<int>('auto_attempts'),
    summary: r.read<String>('summary'),
    failure: r.read<String?>('failure'),
    inputTokens: r.read<int?>('input_tokens'),
    outputTokens: r.read<int?>('output_tokens'),
    notices: r.read<String?>('notices_json') == null
        ? null
        : _decodeNotices(r.read<String>('notices_json')),
  );
  @override
  Future<MorningBrief?> readMorningBrief(DateTime day) =>
      _db._serialized(() async {
        final suppressed = await _db
            .customSelect(
              'SELECT day FROM m6_brief_suppressed WHERE day=?',
              variables: [Variable.withString(_day(day))],
            )
            .getSingleOrNull();
        if (suppressed != null) {
          return MorningBrief(
            day: day,
            phase: MorningBriefPhase.cleared,
            factDigest: '',
            autoAttempts: 0,
          );
        }
        final r = await _row(day);
        if (r == null) return null;
        final state = await _db.features._readSettings();
        if (r.read<int>('epoch') != state.briefEpoch ||
            _db.features._decodeContext(r.read<String>('context_json')) !=
                state.context) {
          return null;
        }
        return _brief(r);
      });

  Future<void> _prune() async {
    final cutoff = _day(
      beijingDay(_db._clock.nowUtc).subtract(const Duration(days: 30)),
    );
    await _db.customStatement('DELETE FROM m6_briefs WHERE day<?', [cutoff]);
    await _db.customStatement('DELETE FROM m6_brief_suppressed WHERE day<?', [
      cutoff,
    ]);
    final rows = await _db
        .customSelect(
          'SELECT day,length(CAST(COALESCE(notices_json,\'\')||summary AS BLOB)) AS bytes FROM m6_briefs ORDER BY day DESC',
        )
        .get();
    var kept = 0;
    for (final r in rows) {
      kept += r.read<int>('bytes');
      if (kept > 5 * 1024 * 1024) {
        await _db.customStatement('DELETE FROM m6_briefs WHERE day=?', [
          r.read<String>('day'),
        ]);
      }
    }
  }

  Future<void> _recoverInterrupted() async {
    await _db.customStatement(
      "UPDATE m6_briefs SET phase='interrupted',ticket=NULL,failure='interrupted' WHERE phase IN ('facts','notices','waiting','generating')",
    );
    await _prune();
  }

  @override
  Future<MorningBriefTicket?> beginMorningBrief(
    DateTime day, {
    bool manual = false,
  }) => _db._serialized(
    () => _db.transaction(() async {
      await _db._guard();
      if (day != beijingDay(_db._clock.nowUtc)) {
        throw const ReminderFailure(ReminderFailureCode.stale);
      }
      final settings = await _db.features._readSettings();
      if (!settings.preferences.morningEnabled) return null;
      final suppressed = await _db
          .customSelect(
            'SELECT day FROM m6_brief_suppressed WHERE day=?',
            variables: [Variable.withString(_day(day))],
          )
          .getSingleOrNull();
      if (!manual && suppressed != null) return null;
      final prior = await _row(day);
      if (prior != null && prior.read<String?>('ticket') != null) return null;
      if (!manual &&
          prior != null &&
          prior.read<String>('phase') != 'interrupted') {
        return null;
      }
      if (!manual && prior != null && prior.read<int>('auto_runs') >= 2) {
        return null;
      }
      final facts = await _facts(day);
      final id = JwStore._randomHexId('brief-');
      await _db.customStatement('DELETE FROM m6_brief_suppressed WHERE day=?', [
        _day(day),
      ]);
      await _db.customStatement(
        "INSERT INTO m6_briefs VALUES(?,?,?,?,?,'facts',NULL,'',NULL,?, ?,NULL,NULL,?) ON CONFLICT(day) DO UPDATE SET context_json=excluded.context_json,epoch=excluded.epoch,ticket=excluded.ticket,fact_digest=excluded.fact_digest,phase='facts',summary='',failure=NULL,auto_runs=excluded.auto_runs,changed_at=excluded.changed_at",
        [
          _day(day),
          jsonEncode(_db.features._contextJson(settings.context)),
          settings.briefEpoch,
          id,
          facts.digest,
          prior?.read<int>('auto_attempts') ?? 0,
          (prior?.read<int>('auto_runs') ?? 0) + (manual ? 0 : 1),
          _db._clock.nowUtc.microsecondsSinceEpoch,
        ],
      );
      _db._m6Changed = 0;
      return MorningBriefTicket(
        context: settings.context,
        day: day,
        epoch: settings.briefEpoch,
        id: id,
        factDigest: facts.digest,
        manual: manual,
      );
    }),
  );
  Future<void> _ensure(MorningBriefTicket t, {bool checkFacts = true}) async {
    await _db._guard();
    final settings = await _db.features._readSettings();
    final row = await _row(t.day);
    if (!settings.preferences.morningEnabled ||
        t.context != settings.context ||
        t.epoch != settings.briefEpoch ||
        t.day != beijingDay(_db._clock.nowUtc) ||
        row?.read<String?>('ticket') != t.id ||
        checkFacts && (await _facts(t.day)).digest != t.factDigest) {
      throw const ReminderFailure(ReminderFailureCode.stale);
    }
  }

  @override
  Future<void> ensureMorningTicket(MorningBriefTicket ticket) =>
      _db._serialized(() => _ensure(ticket));
  @override
  Future<bool> beginMorningModelAttempt(
    MorningBriefTicket ticket,
  ) => _db._serialized(
    () => _db.transaction(() async {
      await _ensure(ticket);
      final row = (await _row(ticket.day))!;
      if (!ticket.manual && row.read<int>('auto_attempts') >= 2) return false;
      await _db.customStatement(
        "UPDATE m6_briefs SET phase='generating',auto_attempts=auto_attempts+?,changed_at=? WHERE day=?",
        [
          ticket.manual ? 0 : 1,
          _db._clock.nowUtc.microsecondsSinceEpoch,
          _day(ticket.day),
        ],
      );
      _db._m6Changed = 0;
      return true;
    }),
  );
  @override
  Future<void> saveMorningBrief(
    MorningBriefTicket ticket, {
    required MorningBriefPhase phase,
    MorningNoticeBatch? notices,
    String? summary,
    String? failure,
    int? inputTokens,
    int? outputTokens,
  }) => _db._serialized(
    () => _db.transaction(() async {
      await _ensure(
        ticket,
        checkFacts:
            phase == MorningBriefPhase.ready ||
            phase == MorningBriefPhase.generating,
      );
      if (summary != null && summary.length > 10000 ||
          inputTokens != null && inputTokens < 0 ||
          outputTokens != null && outputTokens < 0) {
        throw const ReminderFailure(ReminderFailureCode.invalidInput);
      }
      if (failure != null &&
          !RegExp(r'^[a-zA-Z][a-zA-Z0-9]{0,39}$').hasMatch(failure)) {
        throw const ReminderFailure(ReminderFailureCode.invalidInput);
      }
      if (notices != null) {
        if (notices.day != ticket.day.subtract(const Duration(days: 1)) ||
            notices.notices.length > 200 ||
            notices.operations > 20) {
          throw const ReminderFailure(ReminderFailureCode.invalidInput);
        }
        for (final n in notices.notices) {
          if (n.publishedDay != notices.day ||
              n.title.length > 400 ||
              n.excerpt.length > 2000 ||
              n.articleUrl.scheme != 'https' ||
              n.articleUrl.userInfo.isNotEmpty ||
              !{
                'www.teach.ustc.edu.cn',
                'teach.ustc.edu.cn',
                'finance.ustc.edu.cn',
              }.contains(n.articleUrl.host)) {
            throw const ReminderFailure(ReminderFailureCode.invalidInput);
          }
        }
      }
      final done = {
        MorningBriefPhase.ready,
        MorningBriefPhase.failed,
        MorningBriefPhase.interrupted,
      }.contains(phase);
      await _db.customStatement(
        'UPDATE m6_briefs SET phase=?,ticket=?,notices_json=COALESCE(?,notices_json),summary=COALESCE(?,summary),failure=?,input_tokens=?,output_tokens=?,changed_at=? WHERE day=?',
        [
          phase.name,
          done ? null : ticket.id,
          notices == null ? null : _encodeNotices(notices),
          summary,
          failure,
          inputTokens,
          outputTokens,
          _db._clock.nowUtc.microsecondsSinceEpoch,
          _day(ticket.day),
        ],
      );
      await _prune();
      _db._m6Changed = 0;
    }),
  );
  Future<void> _clearForMaintenance() async {
    await _db.customStatement('DELETE FROM m6_briefs');
    await _db.customStatement(
      'UPDATE m6_state SET brief_epoch=brief_epoch+1,revision=revision+1 WHERE singleton=1',
    );
    await _db.customStatement(
      'INSERT OR IGNORE INTO m6_brief_suppressed VALUES(?)',
      [_day(beijingDay(_db._clock.nowUtc))],
    );
    _db._m6Changed = 0;
  }

  @override
  Future<void> clearMorningBriefs() =>
      _db._serialized(() => _db.transaction(_clearForMaintenance));
}
