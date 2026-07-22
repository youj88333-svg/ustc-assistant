from __future__ import annotations

import unittest

from ustc_assistant.sources.jw import course as converter


def room(code: str) -> dict:
    return {
        "code": code,
        "nameZh": f"示例教室 {code}",
        "virtual": False,
        "building": {
            "nameZh": "示例教学楼",
            "campus": {"nameZh": "示例校区"},
        },
    }


def course_datum(*schedule_rows: dict) -> dict:
    return {
        "result": {
            "lessonList": [
                {
                    "id": 1001,
                    "code": "SAMPLE1001.01",
                    "courseName": "示例课程",
                    "courseTypeName": "理论课",
                }
            ],
            "scheduleGroupList": [
                {
                    "id": 5001,
                    "lessonId": 1001,
                }
            ],
            "scheduleList": list(schedule_rows),
        }
    }


def schedule_row(
    room_code: str,
    *,
    exercise_class=None,
    teacher: str = "示例教师",
) -> dict:
    return {
        "lessonId": 1001,
        "scheduleGroupId": 5001,
        "date": "2026-03-16",
        "startTime": 945,
        "endTime": 1210,
        "room": room(room_code),
        "customPlace": None,
        "exerciseClass": exercise_class,
        "personName": teacher,
        "weekIndex": 3,
        "weekday": 1,
        "periods": 3,
    }


class ExternalIdentityTests(unittest.TestCase):
    def test_single_group_keeps_existing_external_id_format(self):
        result = converter.convert(
            course_datum(schedule_row("A101")),
            semester_key="2026spring",
            user_id="user_sample",
        )

        self.assertEqual(
            "ustc_jw:2026spring:1001:5001:2026-03-16:0945:1210",
            result["calendarEvents"][0]["externalId"],
        )

    def test_same_time_groups_at_different_places_get_unique_ids(self):
        result = converter.convert(
            course_datum(
                schedule_row("A101"),
                schedule_row("A102"),
            ),
            semester_key="2026spring",
            user_id="user_sample",
        )

        events = result["calendarEvents"]
        sources = result["sourceRecords"]
        self.assertEqual(2, len(events))
        self.assertEqual(2, len({event["id"] for event in events}))
        self.assertEqual(2, len({event["externalId"] for event in events}))
        self.assertEqual(2, len({source["id"] for source in sources}))
        self.assertTrue(
            all(
                event["externalId"].startswith(
                    "ustc_jw:2026spring:1001:5001:2026-03-16:0945:1210:"
                )
                for event in events
            )
        )

    def test_false_and_missing_exercise_class_merge_teacher_rows(self):
        result = converter.convert(
            course_datum(
                schedule_row(
                    "A101",
                    exercise_class=False,
                    teacher="示例教师甲",
                ),
                schedule_row(
                    "A101",
                    exercise_class=None,
                    teacher="示例教师乙",
                ),
            ),
            semester_key="2026spring",
            user_id="user_sample",
        )

        self.assertEqual(1, len(result["calendarEvents"]))
        event = result["calendarEvents"][0]
        self.assertEqual(
            {"示例教师甲", "示例教师乙"},
            {participant["name"] for participant in event["participants"]},
        )
        self.assertEqual(2, event["metadata"]["mergedScheduleRows"])

    def test_explicit_exercise_class_remains_a_separate_group(self):
        result = converter.convert(
            course_datum(
                schedule_row("A101", exercise_class=False),
                schedule_row("A101", exercise_class=True),
            ),
            semester_key="2026spring",
            user_id="user_sample",
        )

        self.assertEqual(2, len(result["calendarEvents"]))
        self.assertEqual(
            2,
            len({event["externalId"] for event in result["calendarEvents"]}),
        )


if __name__ == "__main__":
    unittest.main()
