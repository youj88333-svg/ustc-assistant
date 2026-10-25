"""Independent acceptance for synthetic SQLite and pure-model behavior."""
from dataclasses import asdict, FrozenInstanceError, replace
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest

from pure_model import (IncompleteSnapshot, Overlay, RecurrenceSpec, SourceIdentity,
                        enumerate_occurrences, parse_snapshot, project)
from transaction_probe import Candidate, Rejected, Stamp, Store, reconcile_registry


BASE = Path(__file__).resolve().parents[1] / '.runtime' / 'model'


def snapshot(day=9, records=True, complete=True, **changes):
    result = dict(complete=complete, contract='synthetic-v1', account_id='synthetic-account',
                  source='synthetic-school', scope='stable-term',
                  coverage={'start': '2026-10-01T00:00:00+08:00', 'end': '2026-11-01T00:00:00+08:00'},
                  records=[{'external_id': 'external-A', 'title': 'Synthetic class',
                            'start': f'2026-10-{day:02}T09:00:00+08:00',
                            'end': f'2026-10-{day:02}T10:00:00+08:00'}] if records else [])
    if isinstance(records, list):
        result['records'] = records
    result.update(changes)
    return result


class TransactionAcceptance(unittest.TestCase):
    def setUp(self):
        BASE.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='sqlite-', dir=BASE)
        self.path = Path(self.temp.name) / 'synthetic.sqlite'
        self.store = Store(self.path, initialize=True)

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def import_one(self, operation='import-A', **kw):
        stamp = self.store.start()
        self.assertEqual(self.store.import_snapshot(operation, stamp, snapshot(), **kw), 'committed')
        event = self.store.db.execute('SELECT id FROM event').fetchone()['id']
        return stamp, event

    def counts(self):
        return tuple(self.store.db.execute(f'SELECT count(*) FROM {table}').fetchone()[0]
                     for table in ('event', 'credential', 'permit', 'receipt', 'audit'))

    def test_source_reschedule_preserves_identity_overlay_and_task_plan_links(self):
        _, event = self.import_one()
        over = Overlay(user_title='My title', user_note='My note')
        approval = self.store.overlay_intent('edit-A', event, 0, over)
        self.store.patch_overlay('edit-A', event, 0, over, approval)
        self.store.db.execute('INSERT INTO task VALUES (?,?,?,?)', ('task-A', event, 'pending', 1))
        self.store.db.execute('INSERT INTO plan_block VALUES (?,?,?,?,?)',
                              ('plan-A', 'task-A', event, '2026-10-09T11:00:00+08:00', '2026-10-09T12:00:00+08:00'))
        stamp = self.store.start()
        self.store.import_snapshot('import-B', stamp, snapshot(day=12))
        row = self.store.db.execute('SELECT * FROM event').fetchone()
        self.assertEqual(row['id'], event)
        self.assertEqual(row['start'], '2026-10-12T09:00:00+08:00')
        self.assertEqual(self.store.db.execute('SELECT note FROM overlay').fetchone()[0], 'My note')
        self.assertEqual(self.store.db.execute('SELECT event FROM task').fetchone()[0], event)
        self.assertEqual(self.store.db.execute('SELECT event FROM plan_block').fetchone()[0], event)
        self.assertEqual(self.store.db.execute('PRAGMA foreign_key_check').fetchall(), [])

    def test_incomplete_snapshot_and_invalid_input_have_zero_business_writes(self):
        self.import_one()
        before = self.counts()
        stamp = self.store.start()
        with self.assertRaises(IncompleteSnapshot):
            self.store.import_snapshot('bad', stamp, snapshot(records=False, complete=False))
        self.assertEqual(self.counts(), before)
        with self.assertRaises(ValueError):
            self.store.import_snapshot('bad-2', stamp, snapshot(records=[{'external_id': 'bad'}]))
        self.assertEqual(self.counts(), before)

    def test_complete_empty_retains_records_and_unobserved_outside_window(self):
        self.import_one()
        stamp = self.store.start()
        self.store.import_snapshot('other-window', stamp, snapshot(records=False, coverage={
            'start': '2026-10-15T00:00:00+08:00', 'end': '2026-10-20T00:00:00+08:00'}))
        self.assertEqual(self.store.db.execute('SELECT presence FROM event').fetchone()[0], 'observed')
        stamp = self.store.start()
        self.store.import_snapshot('empty', stamp, snapshot(records=False))
        row = self.store.db.execute('SELECT * FROM event').fetchone()
        self.assertEqual(row['presence'], 'missing_unconfirmed')
        self.assertEqual(row['source_status'], 'active')
        record = parse_snapshot(snapshot()).records[0]
        self.assertFalse(project(record, Overlay(), row['presence']).hidden)

    def test_reappearance_and_moving_window_use_same_stable_identity(self):
        _, event = self.import_one()
        stamp = self.store.start()
        self.store.import_snapshot('empty', stamp, snapshot(records=False))
        stamp = self.store.start()
        self.store.import_snapshot('return', stamp, snapshot(day=15, coverage={
            'start': '2026-10-10T00:00:00+08:00', 'end': '2026-10-20T00:00:00+08:00'}))
        self.assertEqual(self.store.db.execute('SELECT id,presence FROM event').fetchone()[:], (event, 'observed'))

    def test_receipt_loss_and_A_B_A_replay_does_not_revert_new_source(self):
        stamp, _ = self.import_one()
        stamp_b = self.store.start()
        self.store.import_snapshot('import-B', stamp_b, snapshot(day=12))
        before = self.counts()
        self.store.close()
        self.store = Store(self.path)
        self.assertEqual(self.store.import_snapshot('import-A', stamp, snapshot()), 'replay_committed')
        self.assertEqual(self.counts(), before)
        self.assertEqual(self.store.db.execute('SELECT start FROM event').fetchone()[0], '2026-10-12T09:00:00+08:00')
        with self.assertRaisesRegex(Rejected, 'operation_conflict'):
            self.store.import_snapshot('import-A', stamp, snapshot(day=13))
        self.assertEqual(self.counts(), before)

    def test_credential_permit_receipt_audit_and_business_rollback_together(self):
        for index, fault in enumerate(('after_business', 'before_receipt', 'before_commit')):
            with self.subTest(fault=fault):
                stamp = self.store.start()
                c = Candidate('partition-'+str(index), 'attempt-A', stamp.account_id, stamp.epoch, 'initial')
                before = self.counts()
                with self.assertRaises(sqlite3.OperationalError):
                    self.store.import_snapshot('bad-'+str(index), stamp, snapshot(), c,
                                               protected=b'synthetic-ciphertext', fault=fault)
                self.assertEqual(self.counts(), before)
                self.store.cancel(stamp)
        stamp = self.store.start()
        c = Candidate('partition-good', 'attempt-A', stamp.account_id, stamp.epoch, 'recovery')
        self.store.import_snapshot('good', stamp, snapshot(), c, protected=b'synthetic-ciphertext')
        self.assertEqual(self.counts(), (1, 1, 1, 1, 1))
        self.assertTrue(self.store.valid_permit(c))

    def test_wrong_candidate_and_old_epoch_are_rejected(self):
        stamp = self.store.start()
        c = Candidate('partition', 'attempt', 'another-owner', stamp.epoch, 'initial')
        with self.assertRaisesRegex(Rejected, 'candidate_binding'):
            self.store.import_snapshot('bad', stamp, snapshot(), c)
        self.store.clear_session()
        with self.assertRaisesRegex(Rejected, 'stale_or_cancelled'):
            self.store.import_snapshot('old', stamp, snapshot())
        self.assertEqual(self.counts(), (0, 0, 0, 0, 0))

    def test_recovery_sql_failure_and_rejected_protected_value_preserve_old_facts(self):
        self.import_one(protected=b'synthetic-old-ciphertext')
        before_event = tuple(self.store.db.execute('SELECT * FROM event').fetchone())
        before_credential = tuple(self.store.db.execute('SELECT * FROM credential').fetchone())
        before_counts = self.counts()
        stamp = self.store.start()
        c = Candidate('new-partition', 'new-attempt', stamp.account_id, stamp.epoch, 'recovery')
        with self.assertRaisesRegex(Rejected, 'protected_value'):
            self.store.import_snapshot('bad-protection', stamp, snapshot(day=20), c, protected=b'')
        with self.assertRaises(sqlite3.OperationalError):
            self.store.import_snapshot('bad-sql', stamp, snapshot(day=20), c,
                                       protected=b'synthetic-new-ciphertext', fault='before_commit')
        self.assertEqual(tuple(self.store.db.execute('SELECT * FROM event').fetchone()), before_event)
        self.assertEqual(tuple(self.store.db.execute('SELECT * FROM credential').fetchone()), before_credential)
        self.assertEqual(self.counts(), before_counts)

    def test_clear_session_crash_window_revokes_claimed_and_failed_cleanup_stays_pending(self):
        stamp = self.store.start()
        c = Candidate('partition', 'attempt', stamp.account_id, stamp.epoch, 'recovery')
        self.store.import_snapshot('good', stamp, snapshot(), c)
        entries = [{'candidate': asdict(c), 'state': 'provisional'}]
        claimed = reconcile_registry(self.store, entries)
        self.assertEqual(claimed[0]['state'], 'claimed')
        # C3 commits revoke, P has not yet changed its persisted claimed marker.
        self.store.clear_session()
        self.store.close()
        self.store = Store(self.path)
        pending = reconcile_registry(self.store, claimed, fail_delete=True)
        self.assertEqual(pending[0]['state'], 'deletePending')
        self.assertEqual(reconcile_registry(self.store, pending), [])
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM event').fetchone()[0], 1)

    def test_account_exists_cannot_claim_unverified_candidate(self):
        candidate = Candidate('no-permit', 'attempt', 'synthetic-account', 1, 'initial')
        entry = {'candidate': asdict(candidate), 'state': 'provisional'}
        self.assertEqual(reconcile_registry(self.store, [entry]), [])

    def test_specific_permit_does_not_claim_another_attempt_and_delete_pending_wins(self):
        stamp = self.store.start()
        c = Candidate('partition', 'attempt', stamp.account_id, stamp.epoch, 'initial')
        self.store.import_snapshot('good', stamp, snapshot(), c)
        wrong = Candidate(c.partition, 'other-attempt', c.owner, c.epoch, c.purpose)
        self.assertFalse(self.store.valid_permit(wrong))
        entry = {'candidate': asdict(c), 'state': 'deletePending'}
        self.assertEqual(reconcile_registry(self.store, [entry]), [])

    def test_cancel_first_rejects_import_commit_first_retains_committed(self):
        stamp = self.store.start()
        self.assertEqual(self.store.cancel(stamp), 'cancelled')
        with self.assertRaises(Rejected):
            self.store.import_snapshot('old', stamp, snapshot())
        self.assertEqual(self.counts(), (0, 0, 0, 0, 0))
        stamp = self.store.start()
        self.store.import_snapshot('new', stamp, snapshot())
        self.assertEqual(self.store.cancel(stamp), 'committed')
        self.assertEqual(self.counts(), (1, 0, 0, 1, 1))

    def test_real_sqlite_lock_contention_serializes_both_winner_orders(self):
        for first in ('import', 'cancel'):
            with self.subTest(first=first):
                # A fresh temporary database for each order; both use independent connections.
                path = Path(self.temp.name) / (first+'.sqlite')
                setup = Store(path, initialize=True)
                stamp = setup.start()
                setup.close()
                entered, release, busy_seen = threading.Event(), threading.Event(), threading.Event()
                output, errors = {}, []
                def hold():
                    entered.set()
                    if not release.wait(5):
                        raise RuntimeError('test_timeout')
                def run(which, hook=None):
                    s = Store(path)
                    try:
                        if hook is None:
                            # Prove actual lock contention before allowing the first
                            # writer to finish, rather than relying on thread timing.
                            s.db.execute('PRAGMA busy_timeout=0')
                            try:
                                s.db.execute('BEGIN IMMEDIATE')
                            except sqlite3.OperationalError as error:
                                if 'locked' not in str(error):
                                    raise
                                busy_seen.set()
                            else:
                                s.db.execute('ROLLBACK')
                                raise RuntimeError('expected_write_lock')
                            finally:
                                s.db.execute('PRAGMA busy_timeout=10000')
                        output[which] = s.import_snapshot('race', stamp, snapshot(), locked_hook=hook) \
                            if which == 'import' else s.cancel(stamp, locked_hook=hook)
                    except Rejected as e:
                        output[which] = str(e)
                    except BaseException as e:
                        errors.append(type(e).__name__)
                    finally:
                        s.close()
                second = 'cancel' if first == 'import' else 'import'
                a = threading.Thread(target=run, args=(first, hold))
                b = threading.Thread(target=run, args=(second,))
                a.start()
                self.assertTrue(entered.wait(5))
                b.start()
                self.assertTrue(busy_seen.wait(5))
                release.set()
                a.join(10)
                b.join(10)
                self.assertFalse(a.is_alive() or b.is_alive())
                self.assertEqual(errors, [])
                expected = {'import': 'committed', 'cancel': 'committed'} if first == 'import' \
                    else {'cancel': 'cancelled', 'import': 'stale_or_cancelled'}
                self.assertEqual(output, expected)

    def test_overlay_approval_bound_to_operation_intent_version_and_replay(self):
        _, event = self.import_one()
        over = Overlay(user_title='Approved title')
        approval = self.store.overlay_intent('edit-A', event, 0, over)
        self.store.patch_overlay('edit-A', event, 0, over, approval)
        self.assertEqual(self.store.patch_overlay('edit-A', event, 0, over, approval), 'replay_committed')
        with self.assertRaisesRegex(Rejected, 'approval_mismatch'):
            self.store.patch_overlay('another-operation', event, 0, over, approval)
        with self.assertRaisesRegex(Rejected, 'approval_mismatch'):
            self.store.patch_overlay('edit-A', event, 0, Overlay(user_title='Changed'), approval)
        stale = self.store.overlay_intent('edit-B', event, 0, over)
        with self.assertRaisesRegex(Rejected, 'target_conflict'):
            self.store.patch_overlay('edit-B', event, 0, over, stale)

    def test_undo_after_sync_only_reverts_user_owned_fields(self):
        _, event = self.import_one()
        over = Overlay(user_title='Temporary title', hidden=True)
        approval = self.store.overlay_intent('edit-A', event, 0, over)
        self.store.patch_overlay('edit-A', event, 0, over, approval)
        stamp = self.store.start()
        self.store.import_snapshot('import-B', stamp, snapshot(day=20))
        self.store.undo_overlay('undo-A', 'edit-A')
        self.assertEqual(self.store.db.execute('SELECT start FROM event').fetchone()[0], '2026-10-20T09:00:00+08:00')
        row = self.store.db.execute('SELECT * FROM overlay').fetchone()
        self.assertIsNone(row['title'])
        self.assertFalse(row['hidden'])
        self.assertEqual(row['version'], 2)
        self.assertEqual(self.store.undo_overlay('undo-A', 'edit-A'), 'replay_committed')
        stale = self.store.overlay_intent('old-approved', event, 0, over)
        with self.assertRaisesRegex(Rejected, 'target_conflict'):
            self.store.patch_overlay('old-approved', event, 0, over, stale)

    def test_undo_conflict_and_reset_revoke_old_authority(self):
        stamp, event = self.import_one()
        over = Overlay(user_title='One')
        self.store.patch_overlay('edit-A', event, 0, over, self.store.overlay_intent('edit-A', event, 0, over))
        over_b = Overlay(user_title='Two')
        self.store.patch_overlay('edit-B', event, 1, over_b, self.store.overlay_intent('edit-B', event, 1, over_b))
        with self.assertRaisesRegex(Rejected, 'undo_conflict'):
            self.store.undo_overlay('undo-old', 'edit-A')
        self.store.clear_session()
        with self.assertRaisesRegex(Rejected, 'authority_revoked'):
            self.store.import_snapshot('import-A', stamp, snapshot())
        with self.assertRaisesRegex(Rejected, 'authority_revoked'):
            self.store.undo_overlay('undo-new', 'edit-B')

    def test_actual_process_exit_before_and_after_commit(self):
        for fault, code, expected in (('crash_before_commit', 71, (0, 0, 0, 0, 0)),
                                      ('crash_after_all_sql', 73, (0, 0, 0, 0, 0)),
                                      ('crash_after_commit', 72, (1, 1, 1, 1, 1))):
            with self.subTest(fault=fault):
                path = Path(self.temp.name) / (fault+'.sqlite')
                setup = Store(path, initialize=True)
                stamp = setup.start()
                setup.close()
                payload = Path(self.temp.name) / (fault+'.json')
                payload.write_text(json.dumps({'stamp': asdict(stamp), 'fault': fault}), encoding='utf-8')
                result = subprocess.run([sys.executable, str(Path(__file__).resolve()), '--worker', str(path), str(payload)],
                                        capture_output=True, timeout=15)
                self.assertEqual(result.returncode, code)
                reopened = Store(path)
                counts = tuple(reopened.db.execute(f'SELECT count(*) FROM {t}').fetchone()[0]
                               for t in ('event', 'credential', 'permit', 'receipt', 'audit'))
                self.assertEqual(counts, expected)
                self.assertEqual(reopened.db.execute('PRAGMA integrity_check').fetchone()[0], 'ok')
                if code == 72:
                    c = Candidate('crash-partition', 'attempt', stamp.account_id, stamp.epoch, 'initial')
                    self.assertTrue(reopened.valid_permit(c))
                    self.assertEqual(reopened.import_snapshot('crash', stamp, snapshot(), c,
                                                             protected=b'synthetic-ciphertext'), 'replay_committed')
                reopened.close()

    def test_mutating_input_coverage_after_seal_cannot_change_effect_or_receipt(self):
        self.import_one()
        stamp = self.store.start()
        narrow = {'start': '2026-10-15T00:00:00+08:00', 'end': '2026-10-20T00:00:00+08:00'}
        expected = dict(narrow)
        payload = snapshot(records=False, coverage=narrow)
        def mutate_input():
            narrow.update(start='2026-10-01T00:00:00+08:00', end='2026-11-01T00:00:00+08:00')
        self.store.import_snapshot('narrow', stamp, payload, locked_hook=mutate_input)
        self.assertEqual(self.store.db.execute('SELECT presence FROM event').fetchone()[0], 'observed')
        receipt = json.loads(self.store.db.execute('SELECT intent FROM receipt WHERE operation=?', ('narrow',)).fetchone()[0])
        self.assertEqual(receipt['coverage'], expected)
        self.assertEqual(self.store.import_snapshot('narrow', stamp, snapshot(records=False, coverage=expected)), 'replay_committed')

    def test_cancel_cannot_rebind_the_original_job_stamp(self):
        stamp = self.store.start()
        forged = replace(stamp, account_id='other-account', source='other-source', generation=999,
                         epoch=999, contract='other-contract')
        with self.assertRaisesRegex(Rejected, 'cancel_binding'):
            self.store.cancel(forged)
        self.assertEqual(self.store.db.execute('SELECT state FROM job').fetchone()[0], 'running')
        self.assertEqual(self.store.db.execute('SELECT generation FROM source').fetchone()[0], stamp.generation)
        self.assertEqual(self.store.cancel(stamp), 'cancelled')
        self.assertEqual(self.store.cancel(stamp), 'cancelled')

    def test_pure_model_independent_boundary_acceptance(self):
        raw = snapshot()
        frozen = parse_snapshot(raw)
        raw['records'][0]['start'] = 'malformed'
        self.assertEqual(frozen.records[0].start, '2026-10-09T09:00:00+08:00')
        with self.assertRaises(FrozenInstanceError):
            frozen.records[0].title = 'other'
        # Whitespace/case are intentionally not guessed or normalized into identity.
        self.assertNotEqual(SourceIdentity('a', 'b', 'c', 'X').stable_key(),
                            SourceIdentity('a', 'b', 'c', 'x').stable_key())
        spec = RecurrenceSpec('series', '2028-02-28T23:00:00+08:00',
                              '2028-02-29T00:00:00+08:00', 'daily', 1, 3)
        original = enumerate_occurrences(spec)
        self.assertEqual(original[1].start, '2028-02-29T23:00:00+08:00')
        moved = enumerate_occurrences(spec, {1: {'kind': 'move', 'start': '2028-03-02T12:00:00+08:00',
                                                 'end': '2028-03-02T13:00:00+08:00'}})
        self.assertEqual(moved[1].key, original[1].key)
        # A task/plan link keys the original occurrence, surviving an exception move.
        task_link, plan_link = original[1].key, original[1].key
        self.assertEqual(task_link, moved[1].key)
        self.assertEqual(plan_link, moved[1].key)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--worker':
        data = json.loads(Path(sys.argv[3]).read_text(encoding='utf-8'))
        stamp = Stamp(**data['stamp'])
        store = Store(sys.argv[2])
        candidate = Candidate('crash-partition', 'attempt', stamp.account_id, stamp.epoch, 'initial')
        store.import_snapshot('crash', stamp, snapshot(), candidate,
                              protected=b'synthetic-ciphertext', fault=data['fault'])
    else:
        unittest.main()
