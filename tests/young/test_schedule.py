import unittest
from datetime import date

from ustc_assistant.sources.young import schedule


RECORD = {
    "id": "schedule-1",
    "itemId": "activity-1",
    "title": "sample",
    "startTime": "2026-07-22 08:00:00",
    "endTime": "2026-07-22 09:00:00",
    "place": "campus",
    "content": "<p>First &amp; second<br>line</p>",
    "userId": "private-user",
}


class ScheduleServiceTests(unittest.TestCase):
    def test_normalizes_one_schedule_for_reuse_by_import_producers(self):
        normalized = schedule.normalize_schedule_record(RECORD)

        self.assertEqual(
            normalized,
            {
                "sourceScheduleId": "schedule-1",
                "sourceActivityId": "activity-1",
                "title": "sample",
                "startsAt": "2026-07-22T08:00:00+08:00",
                "endsAt": "2026-07-22T09:00:00+08:00",
                "allDay": False,
                "location": "campus",
                "descriptionText": "First & second\nline",
            },
        )

    def test_normalized_snapshot_has_only_approved_schedule_fields(self):
        collection = schedule.CollectedSchedules(
            records=(RECORD,),
            queried_from=date(2026, 7, 15),
            queried_through=date(2026, 8, 22),
            queried_dates=39,
            empty_dates=38,
        )

        normalized = schedule.normalize_schedules(
            collection, collected_at="2026-07-22T08:00:00+08:00"
        )

        self.assertEqual(
            set(normalized["schedules"][0]),
            {
                "sourceScheduleId",
                "sourceActivityId",
                "title",
                "startsAt",
                "endsAt",
                "allDay",
                "location",
                "descriptionText",
            },
        )
        item = normalized["schedules"][0]
        self.assertEqual(item["startsAt"], "2026-07-22T08:00:00+08:00")
        self.assertEqual(item["endsAt"], "2026-07-22T09:00:00+08:00")
        self.assertEqual(item["descriptionText"], "First & second\nline")
        self.assertNotIn("userId", item)

    def test_normalizer_preserves_a_boolean_all_day_value_only(self):
        normalized = schedule.normalize_schedule_record(dict(RECORD, allDay=True))

        self.assertTrue(normalized["allDay"])
        with self.assertRaisesRegex(ValueError, "allDay must be boolean"):
            schedule.normalize_schedule_record(dict(RECORD, allDay="yes"))


if __name__ == "__main__":
    unittest.main()
