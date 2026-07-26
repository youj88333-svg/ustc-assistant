from __future__ import annotations

import copy
import json
import unittest
from datetime import date, datetime
from uuid import UUID
from zoneinfo import ZoneInfo

from ustc_assistant.contracts import validate_source_bundle
from ustc_assistant.sources.young.schedule import (
    CollectedSchedules,
    ScheduleDateCheck,
)
from ustc_assistant.sources.young.source_bundle import (
    build_young_schedule_source_bundle,
    collect_young_schedule_source_bundle,
)


BEIJING_TZ = ZoneInfo("Asia/Shanghai")
BUNDLE_ID = UUID("00000000-0000-4000-8000-000000000222")
COLLECTED_AT = datetime(2026, 7, 26, 12, 0, tzinfo=BEIJING_TZ)
WINDOW_FROM = date(2026, 7, 19)
WINDOW_THROUGH = date(2026, 8, 26)

RECORD = {
    "id": "schedule-1",
    "itemId": "activity-1",
    "title": "Registered activity",
    "startTime": "2026-07-22 08:00:00",
    "endTime": "2026-07-22 09:00:00",
    "place": "Campus room",
    "content": "<p>First &amp; second<br>line</p>",
    "userId": "private-user",
    "personId": "private-person",
    "token": "private-token",
}


def collection(
    records: tuple[dict, ...] = (),
    *,
    queried_from: date = WINDOW_FROM,
    queried_through: date = WINDOW_THROUGH,
    queried_dates: int = 39,
    empty_dates: int = 39,
    date_checks: tuple[ScheduleDateCheck, ...] | None = None,
) -> CollectedSchedules:
    checks = date_checks or complete_date_checks(
        queried_from, queried_through, empty_dates=empty_dates
    )
    return CollectedSchedules(
        records=records,
        queried_from=queried_from,
        queried_through=queried_through,
        queried_dates=queried_dates,
        empty_dates=empty_dates,
        date_checks=checks,
    )


def complete_date_checks(
    queried_from: date,
    queried_through: date,
    *,
    empty_dates: int | None = None,
    non_empty_dates: tuple[date, ...] = (),
) -> tuple[ScheduleDateCheck, ...]:
    dates = tuple(
        queried_from.fromordinal(ordinal)
        for ordinal in range(
            queried_from.toordinal(), queried_through.toordinal() + 1
        )
    )
    if empty_dates is not None:
        non_empty_dates = dates[empty_dates:]
    return tuple(
        ScheduleDateCheck(checked_date=value, was_empty=value not in non_empty_dates)
        for value in dates
    )


def build_bundle(schedules: CollectedSchedules) -> dict:
    return build_young_schedule_source_bundle(
        schedules,
        account_id="acct_test",
        bundle_id=BUNDLE_ID,
        collected_at=COLLECTED_AT,
    )


class YoungScheduleSourceBundleTests(unittest.TestCase):
    def test_empty_complete_window_is_a_valid_bundle(self):
        bundle = build_bundle(collection())

        validate_source_bundle(bundle)
        self.assertEqual(bundle["manifest"]["calendarEventCount"], 0)
        self.assertEqual(
            bundle["snapshot"]["scope"],
            {
                "type": "date_window",
                "fromDate": "2026-07-19",
                "throughDate": "2026-08-26",
                "timezone": "Asia/Shanghai",
                "expectedDateCount": 39,
                "checkedDateCount": 39,
                "emptyDateCount": 39,
            },
        )

    def test_registered_schedule_has_one_typed_record_and_public_fields(self):
        record = dict(RECORD)

        bundle = build_bundle(
            collection(
                (record,),
                empty_dates=38,
                date_checks=complete_date_checks(
                    WINDOW_FROM,
                    WINDOW_THROUGH,
                    non_empty_dates=(date(2026, 7, 22),),
                ),
            )
        )

        validate_source_bundle(bundle)
        event = bundle["data"]["calendarEvents"][0]
        self.assertEqual(
            event,
            {
                "externalId": "ustc_young_my_schedule:event:schedule:schedule-1",
                "seriesExternalId": None,
                "title": "Registered activity",
                "descriptionText": "First & second\nline",
                "eventType": "second_class",
                "time": {
                    "kind": "timed",
                    "startAt": "2026-07-22T08:00:00+08:00",
                    "endAt": "2026-07-22T09:00:00+08:00",
                    "timezone": "Asia/Shanghai",
                },
                "location": {
                    "name": "Campus room",
                    "building": None,
                    "campus": None,
                },
                "participants": [],
                "sourceDefaults": {
                    "importance": "normal",
                    "attendancePolicy": "must_go",
                    "listeningMode": "unknown",
                },
                "sourceDetails": {
                    "kind": "young_registered_schedule",
                    "sourceActivityId": "activity-1",
                },
            },
        )
        self.assertEqual(
            bundle["data"]["sourceRecords"],
            [
                {
                    "externalId": (
                        "ustc_young_my_schedule:record:schedule:schedule-1"
                    ),
                    "recordType": "young_registered_schedule",
                    "entityType": "calendar_event",
                    "entityExternalId": (
                        "ustc_young_my_schedule:event:schedule:schedule-1"
                    ),
                    "sourceStatus": "active",
                    "sourceUpdatedAt": None,
                }
            ],
        )

    def test_same_day_all_day_schedule_uses_an_exclusive_following_date(self):
        record = dict(
            RECORD,
            allDay=True,
            startTime="2026-07-22 00:00:00",
            endTime="2026-07-22 23:59:59",
        )

        bundle = build_bundle(
            collection(
                (record,),
                empty_dates=38,
                date_checks=complete_date_checks(
                    WINDOW_FROM,
                    WINDOW_THROUGH,
                    non_empty_dates=(date(2026, 7, 22),),
                ),
            )
        )

        self.assertEqual(
            bundle["data"]["calendarEvents"][0]["time"],
            {
                "kind": "all_day",
                "startDate": "2026-07-22",
                "endDateExclusive": "2026-07-23",
                "timezone": "Asia/Shanghai",
            },
        )

    def test_multi_day_all_day_schedule_keeps_the_inclusive_source_end_date(self):
        record = dict(
            RECORD,
            allDay=True,
            startTime="2026-07-22 00:00:00",
            endTime="2026-07-24 23:59:59",
        )

        bundle = build_bundle(
            collection(
                (record,),
                empty_dates=36,
                date_checks=complete_date_checks(
                    WINDOW_FROM,
                    WINDOW_THROUGH,
                    non_empty_dates=(
                        date(2026, 7, 22),
                        date(2026, 7, 23),
                        date(2026, 7, 24),
                    ),
                ),
            )
        )

        self.assertEqual(
            bundle["data"]["calendarEvents"][0]["time"],
            {
                "kind": "all_day",
                "startDate": "2026-07-22",
                "endDateExclusive": "2026-07-25",
                "timezone": "Asia/Shanghai",
            },
        )

    def test_rejects_a_collection_with_an_unchecked_date(self):
        with self.assertRaisesRegex(ValueError, "complete date window"):
            build_bundle(collection(queried_dates=38, empty_dates=38))

    def test_rejects_an_invalid_empty_date_count(self):
        with self.assertRaisesRegex(ValueError, "empty date count"):
            build_bundle(collection(empty_dates=40))

    def test_rejects_incomplete_or_inconsistent_per_date_evidence(self):
        checks = complete_date_checks(WINDOW_FROM, WINDOW_THROUGH)
        cases = {
            "missing": checks[:-1],
            "duplicate": (checks[0], checks[0], *checks[2:]),
            "out_of_order": (checks[1], checks[0], *checks[2:]),
        }
        for name, evidence in cases.items():
            with self.subTest(name=name):
                with self.assertRaisesRegex(ValueError, "complete date window"):
                    build_bundle(
                        collection(
                            date_checks=evidence,
                            queried_dates=len(evidence),
                            empty_dates=sum(check.was_empty for check in evidence),
                        )
                    )

        with self.assertRaisesRegex(ValueError, "empty date count"):
            build_bundle(
                collection(
                    date_checks=complete_date_checks(WINDOW_FROM, WINDOW_THROUGH),
                    empty_dates=38,
                )
            )

    def test_event_start_date_can_belong_to_the_window_when_its_end_is_after_it(self):
        record = dict(
            RECORD,
            startTime="2026-08-26 23:00:00",
            endTime="2026-08-27 01:00:00",
        )

        bundle = build_bundle(
            collection(
                (record,),
                empty_dates=38,
                date_checks=complete_date_checks(
                    WINDOW_FROM,
                    WINDOW_THROUGH,
                    non_empty_dates=(date(2026, 8, 26),),
                ),
            )
        )

        self.assertEqual(
            bundle["data"]["calendarEvents"][0]["time"]["endAt"],
            "2026-08-27T01:00:00+08:00",
        )

        all_day = dict(
            RECORD,
            allDay=True,
            startTime="2026-08-26 00:00:00",
            endTime="2026-08-27 23:59:59",
        )
        bundle = build_bundle(
            collection(
                (all_day,),
                empty_dates=38,
                date_checks=complete_date_checks(
                    WINDOW_FROM,
                    WINDOW_THROUGH,
                    non_empty_dates=(date(2026, 8, 26),),
                ),
            )
        )

        self.assertEqual(
            bundle["data"]["calendarEvents"][0]["time"]["endDateExclusive"],
            "2026-08-28",
        )

    def test_rejects_duplicate_source_schedule_identity(self):
        duplicate = copy.deepcopy(RECORD)
        duplicate["title"] = "Changed source payload"

        with self.assertRaisesRegex(ValueError, "duplicate schedule identity"):
            build_bundle(collection((RECORD, duplicate), empty_dates=37))

    def test_rejects_a_record_outside_the_selected_date_window(self):
        outside = dict(
            RECORD,
            startTime="2026-08-27 08:00:00",
            endTime="2026-08-27 09:00:00",
        )

        with self.assertRaisesRegex(ValueError, "outside the complete date window"):
            build_bundle(collection((outside,), empty_dates=38))

    def test_bundle_does_not_include_remote_user_identity_or_capture_material(self):
        bundle = build_bundle(collection((RECORD,), empty_dates=38))
        encoded = json.dumps(bundle, ensure_ascii=False).lower()

        for forbidden in (
            "userid",
            "personid",
            "token",
            "private-user",
            "private-person",
            "private-token",
            "rawhtml",
            "browserprofile",
            "profilepath",
        ):
            self.assertNotIn(forbidden, encoded)

    def test_collects_then_builds_the_bundle_from_the_complete_collection(self):
        schedules = collection((RECORD,), empty_dates=38)
        collector_calls = []

        def collect(**kwargs):
            collector_calls.append(kwargs)
            return schedules

        bundle, returned = collect_young_schedule_source_bundle(
            account_id="acct_test",
            collect_fn=collect,
            bundle_id=BUNDLE_ID,
            collected_at=COLLECTED_AT,
        )

        self.assertIs(returned, schedules)
        self.assertEqual(bundle["manifest"]["calendarEventCount"], 1)
        self.assertEqual([{"account_id": "acct_test"}], collector_calls)


if __name__ == "__main__":
    unittest.main()
