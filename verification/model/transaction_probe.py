"""Disposable SQLite experiment; no production adapter or real source evidence."""
from contextlib import contextmanager
from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import uuid

from pure_model import parse_snapshot


class Rejected(ValueError):
    pass


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))


@dataclass(frozen=True)
class Stamp:
    job_id: str
    account_id: str
    source: str
    generation: int
    epoch: int
    contract: str


@dataclass(frozen=True)
class Candidate:
    partition: str
    attempt: str
    owner: str
    epoch: int
    purpose: str


SCHEMA = """
CREATE TABLE account(id TEXT PRIMARY KEY, epoch INTEGER NOT NULL, maintenance INTEGER NOT NULL);
CREATE TABLE source(account TEXT, name TEXT, generation INTEGER, contract TEXT,
 PRIMARY KEY(account,name), FOREIGN KEY(account) REFERENCES account(id));
CREATE TABLE job(id TEXT PRIMARY KEY, account TEXT, source TEXT, generation INTEGER, epoch INTEGER,
 contract TEXT, state TEXT NOT NULL CHECK(state IN ('running','cancelled','committed')));
CREATE TABLE event(id TEXT PRIMARY KEY, account TEXT, source TEXT, namespace TEXT, external_id TEXT,
 title TEXT, start TEXT, end TEXT, source_status TEXT, presence TEXT,
 UNIQUE(account,source,namespace,external_id), FOREIGN KEY(account) REFERENCES account(id));
CREATE TABLE overlay(event TEXT PRIMARY KEY, title TEXT, start TEXT, end TEXT, note TEXT NOT NULL,
 hidden INTEGER NOT NULL, version INTEGER NOT NULL, FOREIGN KEY(event) REFERENCES event(id));
CREATE TABLE task(id TEXT PRIMARY KEY, event TEXT, state TEXT, version INTEGER,
 FOREIGN KEY(event) REFERENCES event(id));
CREATE TABLE plan_block(id TEXT PRIMARY KEY, task TEXT, event TEXT, start TEXT, end TEXT,
 FOREIGN KEY(task) REFERENCES task(id), FOREIGN KEY(event) REFERENCES event(id));
CREATE TABLE credential(account TEXT PRIMARY KEY, ciphertext BLOB NOT NULL, scheme TEXT NOT NULL,
 FOREIGN KEY(account) REFERENCES account(id));
CREATE TABLE permit(partition TEXT PRIMARY KEY, attempt TEXT, owner TEXT, epoch INTEGER,
 purpose TEXT, account TEXT, revoked INTEGER NOT NULL, FOREIGN KEY(account) REFERENCES account(id));
CREATE TABLE receipt(operation TEXT PRIMARY KEY, intent TEXT NOT NULL, kind TEXT NOT NULL,
 account TEXT NOT NULL, epoch INTEGER NOT NULL);
CREATE TABLE audit(operation TEXT PRIMARY KEY, kind TEXT NOT NULL, changed INTEGER NOT NULL,
 FOREIGN KEY(operation) REFERENCES receipt(operation));
CREATE TABLE undo(operation TEXT PRIMARY KEY, event TEXT NOT NULL, before_value TEXT NOT NULL,
 written_version INTEGER NOT NULL, consumed INTEGER NOT NULL,
 FOREIGN KEY(event) REFERENCES event(id));
"""


class Store:
    def __init__(self, path, initialize=False):
        self.path = Path(path)
        self.db = sqlite3.connect(str(self.path), isolation_level=None, timeout=10)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA foreign_keys=ON')
        self.db.execute('PRAGMA synchronous=FULL')
        if initialize:
            self.db.executescript(SCHEMA)
            self.db.execute('INSERT INTO account VALUES (?,1,0)', ('synthetic-account',))
            self.db.execute('INSERT INTO source VALUES (?,?,0,?)',
                            ('synthetic-account', 'synthetic-school', 'synthetic-v1'))

    def close(self):
        self.db.close()

    @contextmanager
    def transaction(self):
        self.db.execute('BEGIN IMMEDIATE')
        try:
            yield
            self.db.execute('COMMIT')
        except BaseException:
            if self.db.in_transaction:
                self.db.execute('ROLLBACK')
            raise

    def start(self):
        with self.transaction():
            a = self.db.execute('SELECT * FROM account').fetchone()
            if a['maintenance']:
                raise Rejected('maintenance')
            if self.db.execute("SELECT 1 FROM job WHERE state='running'").fetchone():
                raise Rejected('busy')
            self.db.execute('UPDATE source SET generation=generation+1')
            s = self.db.execute('SELECT * FROM source').fetchone()
            stamp = Stamp(uuid.uuid4().hex, a['id'], s['name'], s['generation'], a['epoch'], s['contract'])
            self.db.execute('INSERT INTO job VALUES (?,?,?,?,?,?,?)',
                            (*asdict(stamp).values(), 'running'))
            return stamp

    def guard(self, stamp):
        a = self.db.execute('SELECT * FROM account WHERE id=?', (stamp.account_id,)).fetchone()
        s = self.db.execute('SELECT * FROM source WHERE account=? AND name=?',
                            (stamp.account_id, stamp.source)).fetchone()
        j = self.db.execute('SELECT * FROM job WHERE id=?', (stamp.job_id,)).fetchone()
        if not a or not s or not j or a['maintenance'] or a['epoch'] != stamp.epoch \
                or s['generation'] != stamp.generation or s['contract'] != stamp.contract \
                or j['account'] != stamp.account_id or j['source'] != stamp.source \
                or j['generation'] != stamp.generation or j['epoch'] != stamp.epoch \
                or j['contract'] != stamp.contract or j['state'] != 'running':
            raise Rejected('stale_or_cancelled')

    def cancel(self, stamp, locked_hook=None):
        with self.transaction():
            if locked_hook:
                locked_hook()
            j = self.db.execute('SELECT * FROM job WHERE id=?', (stamp.job_id,)).fetchone()
            if not j:
                raise Rejected('unknown_job')
            if (j['account'], j['source'], j['generation'], j['epoch'], j['contract']) != \
                    (stamp.account_id, stamp.source, stamp.generation, stamp.epoch, stamp.contract):
                raise Rejected('cancel_binding')
            if j['state'] == 'committed':
                return 'committed'
            if j['state'] == 'running':
                self.db.execute('UPDATE job SET state=? WHERE id=?', ('cancelled', stamp.job_id))
                self.db.execute('UPDATE source SET generation=generation+1 WHERE account=? AND name=?',
                                (j['account'], j['source']))
            return 'cancelled'

    def receipt(self, operation, intent, account, epoch):
        r = self.db.execute('SELECT * FROM receipt WHERE operation=?', (operation,)).fetchone()
        if r:
            if r['intent'] != intent or r['account'] != account or r['epoch'] != epoch:
                raise Rejected('operation_conflict')
            # A retained receipt cannot confer current authority after reset/maintenance.
            a = self.db.execute('SELECT * FROM account WHERE id=?', (account,)).fetchone()
            if not a or a['epoch'] != epoch or a['maintenance']:
                raise Rejected('authority_revoked')
            return True
        return False

    def record(self, operation, intent, kind, account, epoch, changed):
        self.db.execute('INSERT INTO receipt VALUES (?,?,?,?,?)', (operation, intent, kind, account, epoch))
        self.db.execute('INSERT INTO audit VALUES (?,?,?)', (operation, kind, changed))

    def import_snapshot(self, operation, stamp, snapshot, candidate=None, protected=None, fault=None, locked_hook=None):
        # The synthetic verifier declares completeness. This is not a school verifier.
        parsed = parse_snapshot(snapshot)
        if (parsed.account_id, parsed.source, parsed.contract) != \
                (stamp.account_id, stamp.source, stamp.contract):
            raise Rejected('snapshot_binding')
        coverage = snapshot.get('coverage')
        if not isinstance(coverage, dict) or set(coverage) != {'start', 'end'}:
            raise Rejected('coverage')
        coverage = dict(coverage)
        # Reuse strict record time validation for the half-open coverage interval.
        sample = dict(snapshot, records=[dict(external_id='coverage', title='coverage', **coverage)])
        parse_snapshot(sample)
        if any(not coverage['start'] <= r.start < coverage['end'] for r in parsed.records):
            raise Rejected('outside_coverage')
        rows = sorted((asdict(r) for r in parsed.records), key=lambda x: x['identity']['external_id'])
        if candidate and (candidate.epoch != stamp.epoch or candidate.owner != stamp.account_id
                          or candidate.purpose not in ('initial', 'recovery')
                          or not candidate.partition or not candidate.attempt):
            raise Rejected('candidate_binding')
        if protected is not None and (not isinstance(protected, bytes) or not protected):
            raise Rejected('protected_value')
        intent = canonical({'stamp': asdict(stamp), 'scope': parsed.scope, 'coverage': coverage,
                            'records': rows, 'candidate': asdict(candidate) if candidate else None,
                            'protected_digest': hashlib.sha256(protected).hexdigest() if protected else None})
        with self.transaction():
            if self.receipt(operation, intent, stamp.account_id, stamp.epoch):
                return 'replay_committed'
            self.guard(stamp)
            if locked_hook:
                locked_hook()
            for r in parsed.records:
                old = self.db.execute('SELECT id FROM event WHERE account=? AND source=? AND namespace=? AND external_id=?',
                                      (stamp.account_id, stamp.source, parsed.scope, r.identity.external_id)).fetchone()
                event_id = old['id'] if old else uuid.uuid4().hex
                self.db.execute('''INSERT INTO event VALUES (?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(account,source,namespace,external_id) DO UPDATE SET
                    title=excluded.title,start=excluded.start,end=excluded.end,
                    source_status=excluded.source_status,presence=excluded.presence''',
                    (event_id, stamp.account_id, stamp.source, parsed.scope, r.identity.external_id,
                     r.title, r.start, r.end, r.source_status, 'observed'))
            seen = {r.identity.external_id for r in parsed.records}
            eligible = self.db.execute('SELECT id,external_id FROM event WHERE account=? AND source=? AND namespace=? AND start>=? AND start<?',
                                       (stamp.account_id, stamp.source, parsed.scope, coverage['start'], coverage['end'])).fetchall()
            for e in eligible:
                if e['external_id'] not in seen:
                    self.db.execute('UPDATE event SET presence=? WHERE id=?', ('missing_unconfirmed', e['id']))
            if fault == 'after_business':
                raise sqlite3.OperationalError('injected_sql_failure')
            if protected is not None:
                self.db.execute('INSERT INTO credential VALUES (?,?,?) ON CONFLICT(account) DO UPDATE SET ciphertext=excluded.ciphertext,scheme=excluded.scheme',
                                (stamp.account_id, protected, 'synthetic-protected'))
            if candidate:
                self.db.execute('INSERT INTO permit VALUES (?,?,?,?,?,?,0)',
                                (candidate.partition, candidate.attempt, candidate.owner, candidate.epoch,
                                 candidate.purpose, stamp.account_id))
            if fault == 'before_receipt':
                raise sqlite3.OperationalError('injected_sql_failure')
            if fault == 'crash_before_commit':
                os._exit(71)
            self.record(operation, intent, 'import', stamp.account_id, stamp.epoch, len(parsed.records))
            self.db.execute('UPDATE job SET state=? WHERE id=?', ('committed', stamp.job_id))
            if fault == 'before_commit':
                raise sqlite3.OperationalError('injected_sql_failure')
            if fault == 'crash_after_all_sql':
                os._exit(73)
        if fault == 'crash_after_commit':
            os._exit(72)
        return 'committed'

    def patch_overlay(self, operation, event, expected_version, overlay, approved_intent):
        # User intent is immutable and approval is bound to its exact canonical form.
        values = asdict(overlay)
        with self.transaction():
            a = self.db.execute('SELECT * FROM account').fetchone()
            intent = canonical({'operation': operation, 'event': event, 'version': expected_version, 'overlay': values,
                                'account': a['id'], 'epoch': a['epoch']})
            if approved_intent != intent:
                raise Rejected('approval_mismatch')
            if self.receipt(operation, intent, a['id'], a['epoch']):
                return 'replay_committed'
            if a['maintenance']:
                raise Rejected('maintenance')
            e = self.db.execute('SELECT account FROM event WHERE id=?', (event,)).fetchone()
            if not e or e['account'] != a['id']:
                raise Rejected('target_binding')
            old = self.db.execute('SELECT * FROM overlay WHERE event=?', (event,)).fetchone()
            version = old['version'] if old else 0
            if version != expected_version:
                raise Rejected('target_conflict')
            before = dict(old) if old else None
            self.db.execute('INSERT INTO overlay VALUES (?,?,?,?,?,?,?) ON CONFLICT(event) DO UPDATE SET title=excluded.title,start=excluded.start,end=excluded.end,note=excluded.note,hidden=excluded.hidden,version=excluded.version',
                            (event, overlay.user_title, overlay.user_start, overlay.user_end,
                             overlay.user_note, int(overlay.hidden), version+1))
            self.db.execute('INSERT INTO undo VALUES (?,?,?,?,0)', (operation, event, canonical(before), version+1))
            self.record(operation, intent, 'overlay', a['id'], a['epoch'], 1)
            return 'committed'

    def overlay_intent(self, operation, event, version, overlay):
        a = self.db.execute('SELECT * FROM account').fetchone()
        return canonical({'operation': operation, 'event': event, 'version': version, 'overlay': asdict(overlay),
                          'account': a['id'], 'epoch': a['epoch']})

    def undo_overlay(self, operation, original):
        with self.transaction():
            a = self.db.execute('SELECT * FROM account').fetchone()
            intent = canonical({'undo': original, 'account': a['id'], 'epoch': a['epoch']})
            if self.receipt(operation, intent, a['id'], a['epoch']):
                return 'replay_committed'
            if a['maintenance']:
                raise Rejected('maintenance')
            u = self.db.execute('SELECT * FROM undo WHERE operation=?', (original,)).fetchone()
            if not u or u['consumed']:
                raise Rejected('undo_missing')
            original_receipt = self.db.execute('SELECT * FROM receipt WHERE operation=?', (original,)).fetchone()
            if original_receipt['account'] != a['id'] or original_receipt['epoch'] != a['epoch']:
                raise Rejected('authority_revoked')
            current = self.db.execute('SELECT * FROM overlay WHERE event=?', (u['event'],)).fetchone()
            if not current or current['version'] != u['written_version']:
                raise Rejected('undo_conflict')
            before = json.loads(u['before_value'])
            if before is None:
                # Keep a monotonically increasing tombstone version: undo must not
                # make an old version-0 approval executable again (ABA).
                self.db.execute('UPDATE overlay SET title=NULL,start=NULL,end=NULL,note=?,hidden=0,version=? WHERE event=?',
                                ('', current['version']+1, u['event']))
            else:
                self.db.execute('UPDATE overlay SET title=?,start=?,end=?,note=?,hidden=?,version=? WHERE event=?',
                                (before['title'], before['start'], before['end'], before['note'],
                                 before['hidden'], current['version']+1, u['event']))
            self.db.execute('UPDATE undo SET consumed=1 WHERE operation=?', (original,))
            self.record(operation, intent, 'undo', a['id'], a['epoch'], 1)
            return 'committed'

    def clear_session(self):
        with self.transaction():
            self.db.execute('UPDATE permit SET revoked=1')
            self.db.execute('UPDATE account SET epoch=epoch+1')
            self.db.execute('UPDATE source SET generation=generation+1')
            self.db.execute("UPDATE job SET state='cancelled' WHERE state='running'")

    def valid_permit(self, candidate):
        p = self.db.execute('SELECT p.*,a.epoch current_epoch FROM permit p JOIN account a ON a.id=p.account WHERE partition=?',
                            (candidate.partition,)).fetchone()
        return bool(p and not p['revoked'] and p['current_epoch'] == candidate.epoch
                    and p['attempt'] == candidate.attempt and p['owner'] == candidate.owner
                    and p['epoch'] == candidate.epoch and p['purpose'] == candidate.purpose)


def reconcile_registry(store, entries, fail_delete=False):
    """Control-plane model only. Real WebView resource draining is a separate probe."""
    result = []
    for entry in entries:
        c = Candidate(**entry['candidate'])
        if entry['state'] != 'deletePending' and store.valid_permit(c):
            result.append({'candidate': entry['candidate'], 'state': 'claimed'})
        elif fail_delete:
            result.append({'candidate': entry['candidate'], 'state': 'deletePending'})
    return result
