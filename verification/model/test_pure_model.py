import unittest
from dataclasses import FrozenInstanceError

from pure_model import (
    FrozenSourceRecord,
    IncompleteSnapshot,
    InvalidException,
    InvalidOverlay,
    InvalidRecord,
    InvalidRecurrence,
    InvalidTime,
    Overlay,
    RecurrenceSpec,
    SourceIdentity,
    enumerate_occurrences,
    parse_snapshot,
    project,
)


def snapshot(*, records=None, **overrides):
    value = {
        "complete": True,
        "contract": "synthetic-v1",
        "account_id": "acct-1",
        "source": "school-a",
        "scope": "term-2026-fall",
        "records": [
            {
                "external_id": "exam-7",
                "title": "Midterm",
                "start": "2026-10-09T09:00:00+08:00",
                "end": "2026-10-09T10:00:00+08:00",
            }
        ] if records is None else records,
    }
    value.update(overrides)
    return value


class PureModelTests(unittest.TestCase):
    def test_source_identity_key_survives_source_record_time_and_title_changes(self):
        before = parse_snapshot(snapshot()).records[0]
        after = parse_snapshot(
            snapshot(
                records=[
                    {
                        "external_id": "exam-7",
                        "title": "Moved midterm",
                        "start": "2026-10-12T13:00:00+08:00",
                        "end": "2026-10-12T14:00:00+08:00",
                    }
                ]
            )
        ).records[0]
        self.assertEqual(before.identity.stable_key(), after.identity.stable_key())
        self.assertNotEqual(before.start, after.start)
        # Query-window dates are absent from SourceIdentity, so moving a query window
        # cannot change the stable key.
        self.assertEqual(
            SourceIdentity("acct-1", "school-a", "term-2026-fall", "exam-7").stable_key(),
            before.identity.stable_key(),
        )

    def test_account_source_and_scope_each_partition_identity(self):
        base = SourceIdentity("acct-1", "school-a", "term-fall", "id-1")
        variants = (
            SourceIdentity("acct-2", "school-a", "term-fall", "id-1"),
            SourceIdentity("acct-1", "school-b", "term-fall", "id-1"),
            SourceIdentity("acct-1", "school-a", "term-spring", "id-1"),
            SourceIdentity("acct-1", "school-a", "term-fall", "id-2"),
        )
        self.assertEqual(len({base.stable_key(), *(v.stable_key() for v in variants)}), 5)
        self.assertEqual(base.stable_key(), ("acct-1", "school-a", "term-fall", "id-1"))

    def test_incomplete_snapshot_is_rejected_before_records_are_read(self):
        class TrapDict(dict):
            def get(self, key, default=None):
                if key == "records":
                    raise AssertionError("records must not be inspected")
                return super().get(key, default)

        with self.assertRaises(IncompleteSnapshot):
            parse_snapshot(TrapDict(complete=False, records=object()))

    def test_duplicate_external_id_is_rejected(self):
        first = snapshot()["records"][0]
        second = dict(first, title="Second copy")
        with self.assertRaises(InvalidRecord):
            parse_snapshot(snapshot(records=[first, second]))

    def test_strict_beijing_times_reject_missing_or_different_offsets_and_bad_dates(self):
        bad_times = (
            "2026-10-09T09:00:00",
            "2026-10-09T09:00:00Z",
            "2026-10-09T09:00:00+00:00",
            "2026-02-30T09:00:00+08:00",
            "2026-10-09T09:00+08:00",
        )
        for bad_time in bad_times:
            with self.subTest(bad_time=bad_time):
                record = dict(snapshot()["records"][0], start=bad_time)
                with self.assertRaises(InvalidTime):
                    parse_snapshot(snapshot(records=[record]))
        reverse_interval = dict(
            snapshot()["records"][0],
            start="2026-10-09T10:00:00+08:00",
            end="2026-10-09T09:00:00+08:00",
        )
        with self.assertRaises(InvalidTime):
            parse_snapshot(snapshot(records=[reverse_interval]))

    def test_snapshot_discards_extra_fields_and_detaches_input(self):
        raw_record = dict(
            snapshot()["records"][0],
            password="synthetic-secret",
            nested={"untrusted": ["value"]},
        )
        raw_records = [raw_record]
        parsed = parse_snapshot(snapshot(records=raw_records))
        raw_record["title"] = "Changed after parse"
        raw_record["nested"]["untrusted"].append("later")
        raw_records.clear()

        self.assertEqual(parsed.records[0].title, "Midterm")
        self.assertEqual(len(parsed.records), 1)
        self.assertFalse(hasattr(parsed.records[0], "password"))
        self.assertFalse(hasattr(parsed.records[0], "nested"))
        with self.assertRaises(FrozenInstanceError):
            parsed.records[0].title = "Mutation"
        with self.assertRaises(FrozenInstanceError):
            parsed.records = ()

    def test_overlay_wins_over_refresh_and_missing_does_not_hide(self):
        overlay = Overlay(
            user_title="My title",
            user_start="2026-10-10T11:00:00+08:00",
            user_end="2026-10-10T12:00:00+08:00",
            user_note="Bring notes",
        )
        refreshed = parse_snapshot(
            snapshot(
                records=[
                    {
                        "external_id": "exam-7",
                        "title": "Changed source title",
                        "start": "2026-10-12T13:00:00+08:00",
                        "end": "2026-10-12T14:00:00+08:00",
                    }
                ]
            )
        ).records[0]
        projection = project(refreshed, overlay, "missing_unconfirmed")
        self.assertEqual(projection.identity.stable_key(), refreshed.identity.stable_key())
        self.assertEqual(projection.title, "My title")
        self.assertEqual(projection.start, "2026-10-10T11:00:00+08:00")
        self.assertEqual(projection.end, "2026-10-10T12:00:00+08:00")
        self.assertEqual(projection.note, "Bring notes")
        self.assertFalse(projection.hidden)
        self.assertEqual(projection.presence, "missing_unconfirmed")

    def test_explicit_source_cancellation_is_preserved_independently_of_hidden(self):
        record = dict(snapshot()["records"][0], source_status="cancelled")
        cancelled = parse_snapshot(snapshot(records=[record])).records[0]
        visible = project(cancelled, Overlay(), "observed")
        hidden = project(cancelled, Overlay(hidden=True), "observed")
        self.assertEqual(visible.source_status, "cancelled")
        self.assertFalse(visible.hidden)
        self.assertEqual(hidden.source_status, "cancelled")
        self.assertTrue(hidden.hidden)

    def test_overlay_rejects_unpaired_times_blank_title_and_non_boolean_hidden(self):
        with self.assertRaises(InvalidOverlay):
            Overlay(user_start="2026-10-10T11:00:00+08:00")
        with self.assertRaises(InvalidOverlay):
            Overlay(user_title=" \t")
        with self.assertRaises(InvalidOverlay):
            Overlay(hidden=1)

    def test_weekly_occurrences_cross_month_and_year_with_stable_exception_keys(self):
        spec = RecurrenceSpec(
            local_series_id="series-9",
            start="2026-01-31T09:00:00+08:00",
            end="2026-01-31T10:00:00+08:00",
            frequency="weekly",
            interval=1,
            count=53,
        )
        original = enumerate_occurrences(spec)
        changed = enumerate_occurrences(
            spec,
            {
                1: {
                    "kind": "move",
                    "start": "2026-02-10T11:00:00+08:00",
                    "end": "2026-02-10T12:00:00+08:00",
                },
                2: {"kind": "skip"},
            },
        )

        self.assertIsInstance(changed, tuple)
        self.assertEqual(original[1].original_start, "2026-02-07T09:00:00+08:00")
        self.assertEqual(original[52].original_start, "2027-01-30T09:00:00+08:00")
        self.assertEqual(changed[1].key, original[1].key)
        self.assertEqual(changed[1].original_start, original[1].original_start)
        self.assertEqual(changed[1].start, "2026-02-10T11:00:00+08:00")
        self.assertEqual(changed[1].end, "2026-02-10T12:00:00+08:00")
        self.assertEqual(changed[1].state, "observed")
        self.assertEqual(changed[2].key, original[2].key)
        self.assertEqual(changed[2].state, "skipped")

    def test_daily_recurrence_uses_calendar_days_and_preserves_duration(self):
        spec = RecurrenceSpec(
            local_series_id="daily-1",
            start="2026-12-31T23:30:00+08:00",
            end="2027-01-01T00:30:00+08:00",
            frequency="daily",
            interval=2,
            count=2,
        )
        occurrences = enumerate_occurrences(spec)
        self.assertEqual(occurrences[1].start, "2027-01-02T23:30:00+08:00")
        self.assertEqual(occurrences[1].end, "2027-01-03T00:30:00+08:00")

    def test_bad_recurrence_exceptions_are_rejected(self):
        spec = RecurrenceSpec(
            "series",
            "2026-01-31T09:00:00+08:00",
            "2026-01-31T10:00:00+08:00",
            "weekly",
            1,
            3,
        )
        bad_cases = (
            {True: {"kind": "skip"}},
            {3: {"kind": "skip"}},
            {0: {"kind": "delete"}},
            {0: {"kind": "skip", "start": "ignored"}},
            {0: {"kind": "move", "start": "2026-02-01T09:00:00+08:00"}},
            {
                0: {
                    "kind": "move",
                    "start": "2026-02-01T10:00:00+08:00",
                    "end": "2026-02-01T09:00:00+08:00",
                }
            },
            {
                0: {
                    "kind": "move",
                    "start": "2026-02-01T09:00:00Z",
                    "end": "2026-02-01T10:00:00+08:00",
                }
            },
        )
        for exceptions in bad_cases:
            with self.subTest(exceptions=exceptions), self.assertRaises(
                (InvalidException, InvalidTime)
            ):
                enumerate_occurrences(spec, exceptions)

    def test_recurrence_integer_fields_reject_booleans_and_out_of_range_values(self):
        valid = dict(
            local_series_id="series",
            start="2026-01-31T09:00:00+08:00",
            end="2026-01-31T10:00:00+08:00",
            frequency="daily",
            interval=1,
            count=1,
        )
        for changes in (
            {"interval": True},
            {"count": False},
            {"interval": 0},
            {"interval": 367},
            {"count": 0},
            {"count": 1001},
            {"interval": 1.0},
        ):
            with self.subTest(changes=changes), self.assertRaises(InvalidRecurrence):
                RecurrenceSpec(**(valid | changes))

    def test_source_identity_rejects_blank_fields_without_trimming_valid_values(self):
        with self.assertRaises(ValueError):
            SourceIdentity("acct", "source", "   ", "id")
        identity = SourceIdentity(" acct ", "source", "term", " id ")
        self.assertEqual(identity.account_id, " acct ")
        self.assertEqual(identity.external_id, " id ")


if __name__ == "__main__":
    unittest.main()
