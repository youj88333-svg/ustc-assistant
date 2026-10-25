part of 'jw_store.dart';

final class _YoungDailyGrant extends YoungDailySyncGrant {
  _YoungDailyGrant(
    this.context,
    this.firstDay,
    this.endDayExclusive,
    this.token,
    this.manual,
  );
  @override
  final YoungDailySyncContext context;
  @override
  final DateTime firstDay, endDayExclusive;
  final String token;
  final bool manual;
  String? boundJob;
  bool revoked = false, committed = false;
  @override
  String toString() => 'YoungDailySyncGrant';
}

/// Independent opt-in, attempt budget and complete coverage facts. No model
/// grant, account value, URL or credential is accepted through this port.
final class YoungDailySyncStore implements YoungDailySyncDataPort {
  YoungDailySyncStore._(this._db);
  final JwStore _db;
  final _changes = StreamController<int>.broadcast();
  final _issued = <_YoungDailyGrant>{};
  bool _adviceOnly = false, _closed = false;
  int _sequence = 0;
  static const schema = <String>[
    '''CREATE TABLE young_daily_sync (
      singleton INTEGER PRIMARY KEY CHECK(singleton=1),
      enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN (0,1)),
      revision INTEGER NOT NULL DEFAULT 1 CHECK(revision>0),
      success_at INTEGER, success_first TEXT, success_end TEXT,
      attempt_day TEXT, attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts>=0),
      retry_at INTEGER, needs_login INTEGER NOT NULL DEFAULT 0 CHECK(needs_login IN (0,1)),
      suppressed_day TEXT, claim_token TEXT
    )''',
    'INSERT INTO young_daily_sync(singleton) VALUES(1)',
  ];
  @override
  Stream<int> get changes => _changes.stream;
  void _signal() {
    if (!_closed) _changes.add(++_sequence);
  }

  void _revoke() {
    for (final grant in _issued) {
      _revokeGrant(grant);
    }
  }

  void _revokeGrant(_YoungDailyGrant grant) {
    grant.revoked = true;
    final ticket = _db._youngTickets[grant.boundJob];
    if (ticket != null && identical(ticket.dailyGrant, grant)) {
      ticket._credentialsRevoked = true;
      ticket._revokeSecrets();
    }
  }

  void _assertCurrent(YoungDailySyncGrant candidate) {
    if (candidate is! _YoungDailyGrant ||
        !_issued.contains(candidate) ||
        candidate.revoked ||
        _adviceOnly) {
      throw const AppFailure(FailureCode.cancelled);
    }
  }

  @override
  void restrictToAdvice(bool restricted) {
    if (_adviceOnly == restricted) return;
    _adviceOnly = restricted;
    if (restricted) _revoke();
    _signal();
  }

  DateTime _now() {
    final now = _db._clock.nowUtc;
    if (!now.isUtc) throw const AppFailure(FailureCode.storageFailed);
    return now;
  }

  DateTime _day(DateTime at) => beijingDay(at);
  String _date(DateTime day) => _youngDayString(day);
  DateTime? _readDate(QueryRow row, String name) {
    final value = row.read<String?>(name);
    if (value == null) return null;
    final parsed = DateTime.tryParse('${value}T00:00:00Z');
    if (parsed == null || _date(parsed) != value) {
      throw const AppFailure(FailureCode.storageFailed);
    }
    return parsed;
  }

  DateTime? _readInstant(QueryRow row, String name) {
    final value = row.read<int?>(name);
    return value == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch(value, isUtc: true);
  }

  Future<QueryRow> _row() => _db
      .customSelect('SELECT * FROM young_daily_sync WHERE singleton=1')
      .getSingle();
  Future<YoungDailySyncContext> _context() async {
    final state = await _db._state();
    final agenda = await _db.localCalendar._agendaState();
    final row = await _row();
    final owner = state.read<String>('owner_id');
    _db._validateOwner(owner);
    return YoungDailySyncContext(
      owner: owner,
      resetEpoch: state.read<int>('reset_epoch'),
      agendaEpoch: agenda.read<int>('epoch'),
      revision: row.read<int>('revision'),
    );
  }

  Future<YoungDailySyncSnapshot> _inspect() async {
    await _db._guard();
    final row = await _row();
    return YoungDailySyncSnapshot(
      context: await _context(),
      enabled: row.read<int>('enabled') == 1,
      accountBound: await _db._account() != null,
      credentialSaved:
          await _db._count('SELECT COUNT(*) AS count FROM jw_credentials') > 0,
      adviceOnly: _adviceOnly,
      lastSuccessAtUtc: _readInstant(row, 'success_at'),
      successFirstDay: _readDate(row, 'success_first'),
      successEndDayExclusive: _readDate(row, 'success_end'),
      attemptDay: _readDate(row, 'attempt_day'),
      attempts: row.read<int>('attempts'),
      nextAttemptAtUtc: _readInstant(row, 'retry_at'),
      needsLogin: row.read<int>('needs_login') == 1,
      suppressedDay: _readDate(row, 'suppressed_day'),
    );
  }

  @override
  Future<YoungDailySyncSnapshot> inspect() => _db._serialized(_inspect);

  @override
  Future<YoungDailySyncSnapshot> setEnabled(
    YoungDailySyncContext context,
    bool enabled,
  ) {
    // This restriction precedes the serialized SQL queue. A failed save does
    // not resurrect an in-flight capability whose use was already revoked.
    if (!enabled) _revoke();
    return _db._serialized(() async {
      await _db.transaction(() async {
        await _db._guard();
        if (await _context() != context) {
          throw const AppFailure(FailureCode.staleResult);
        }
        if ((await _row()).read<int>('enabled') != (enabled ? 1 : 0)) {
          await _db.customStatement(
            'UPDATE young_daily_sync SET enabled=?,revision=revision+1,claim_token=NULL WHERE singleton=1',
            [enabled ? 1 : 0],
          );
          await _db._guard();
        }
      });
      _signal();
      return _inspect();
    });
  }

  Future<void> _recover() async {
    _revoke();
    _issued.clear();
    if ((await _row()).read<String?>('claim_token') != null) {
      await _db.customStatement(
        'UPDATE young_daily_sync SET claim_token=NULL,retry_at=?,needs_login=0 WHERE singleton=1',
        [_now().add(const Duration(minutes: 15)).microsecondsSinceEpoch],
      );
    }
  }

  @override
  Future<YoungDailySyncGrant?> claim({
    bool manual = false,
  }) => _db._serialized(() async {
    _YoungDailyGrant? issued;
    await _db.transaction(() async {
      final snapshot = await _inspect();
      final decision = planYoungDailySync(snapshot, _now(), manual: manual);
      if (!decision.shouldRun ||
          (await _row()).read<String?>('claim_token') != null) {
        return;
      }
      final day = _day(_now());
      final attempts = snapshot.attemptDay == day ? snapshot.attempts : 0;
      final token = JwStore._randomHexId('daily-young-');
      await _db.customStatement(
        'UPDATE young_daily_sync SET attempt_day=?,attempts=?,retry_at=NULL,needs_login=0,claim_token=? WHERE singleton=1',
        [_date(day), attempts + (manual ? 0 : 1), token],
      );
      issued = _YoungDailyGrant(
        snapshot.context,
        decision.firstDay,
        decision.endDayExclusive,
        token,
        manual,
      );
      await _db._guard();
    });
    if (issued != null) {
      _issued.add(issued!);
      _signal();
    }
    return issued;
  });

  Future<void> _require(YoungDailySyncGrant candidate) async {
    _assertCurrent(candidate);
    candidate as _YoungDailyGrant;
    await _db._guard();
    final row = await _row();
    if (await _context() != candidate.context ||
        row.read<int>('enabled') != 1 ||
        row.read<String?>('claim_token') != candidate.token) {
      throw const AppFailure(FailureCode.staleResult);
    }
    // Restrictions may arrive while the serialized database reads await.
    _assertCurrent(candidate);
  }

  @override
  Future<void> finish(
    YoungDailySyncGrant candidate,
    YoungDailySyncOutcome outcome,
  ) {
    if (candidate is! _YoungDailyGrant || !_issued.contains(candidate)) {
      return Future.error(const AppFailure(FailureCode.staleResult));
    }
    _revokeGrant(candidate);
    return _db._serialized(() async {
      await _db.transaction(() async {
        final row = await _row();
        if (row.read<String?>('claim_token') != candidate.token) return;
        await _db.customStatement(
          'UPDATE young_daily_sync SET claim_token=NULL,retry_at=?,needs_login=?,attempts=MAX(0,attempts-?) WHERE singleton=1',
          [
            candidate.committed || outcome == YoungDailySyncOutcome.needsLogin
                ? null
                : _now()
                      .add(
                        Duration(
                          minutes: outcome == YoungDailySyncOutcome.deferred
                              ? 1
                              : 15,
                        ),
                      )
                      .microsecondsSinceEpoch,
            !candidate.committed && outcome == YoungDailySyncOutcome.needsLogin
                ? 1
                : 0,
            !candidate.manual &&
                    candidate.boundJob == null &&
                    outcome == YoungDailySyncOutcome.deferred
                ? 1
                : 0,
          ],
        );
      });
      _issued.remove(candidate);
      _signal();
    });
  }

  /// Called only inside the successful complete-calendar import transaction.
  Future<void> _recordCalendarSuccess(
    YoungJobTicket ticket,
    DateTime at,
  ) async {
    final first = ticket.firstDay!,
        end = ticket.lastDay!.add(const Duration(days: 1));
    final expectedFirst = _day(at).subtract(const Duration(days: 1));
    final expectedEnd = expectedFirst.add(const Duration(days: 31));
    // A manual historical selection must not replace today's complete rolling
    // success, nor count as automatic coverage. Receipts retain that history.
    if (ticket.dailyGrant == null &&
        (first.isAfter(expectedFirst) || end.isBefore(expectedEnd))) {
      return;
    }
    await _db.customStatement(
      'UPDATE young_daily_sync SET success_at=?,success_first=?,success_end=?,needs_login=0,retry_at=NULL WHERE singleton=1',
      [at.microsecondsSinceEpoch, _date(first), _date(end)],
    );
  }

  Future<void> _clearForMaintenance({required bool reset}) async {
    _revoke();
    await _db.customStatement(
      'UPDATE young_daily_sync SET enabled=CASE WHEN ?=1 THEN 0 ELSE enabled END,revision=revision+1,'
      'success_at=NULL,success_first=NULL,success_end=NULL,attempt_day=NULL,attempts=0,retry_at=NULL,'
      'needs_login=0,claim_token=NULL,suppressed_day=? WHERE singleton=1',
      [reset ? 1 : 0, reset ? null : _date(_day(_now()))],
    );
    _issued.clear();
  }

  Future<void> _close() async {
    _closed = true;
    _revoke();
    _issued.clear();
    await _changes.close();
  }
}
