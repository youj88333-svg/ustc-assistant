from __future__ import annotations

import copy
import json
import unittest
from datetime import datetime
from pathlib import Path
from uuid import UUID
from zoneinfo import ZoneInfo

from ustc_assistant.config import JwSemesterConfig
from ustc_assistant.contracts import validate_source_bundle
from ustc_assistant.sources.jw.source_bundle import build_jw_source_bundle


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests" / "fixtures" / "jw"
BEIJING_TZ = ZoneInfo("Asia/Shanghai")
SEMESTER = JwSemesterConfig(421, "2026spring", "2026 春季学期")
BUNDLE_ID = UUID("00000000-0000-4000-8000-000000000111")
COLLECTED_AT = datetime(2026, 7, 26, 12, 0, tzinfo=BEIJING_TZ)
EMPTY_EXAM_HTML = """\
<table id="exams">
  <tr>
    <th>课程号</th><th>考试类型</th><th>课程名称</th><th>日期时间</th>
    <th>考场</th><th>教学楼</th><th>考场所在校区</th><th>考试说明</th>
  </tr>
</table>
"""


def load_course_datum() -> dict:
    return json.loads(
        (FIXTURES / "course-datum.json").read_text(encoding="utf-8")
    )


def load_exam_html() -> str:
    return (FIXTURES / "exam-page.html").read_text(encoding="utf-8")


def build_bundle(
    course_datum: dict | None = None,
    exam_html: str | None = None,
) -> dict:
    return build_jw_source_bundle(
        course_datum if course_datum is not None else load_course_datum(),
        exam_html if exam_html is not None else load_exam_html(),
        account_id="acct_test",
        semester=SEMESTER,
        bundle_id=BUNDLE_ID,
        collected_at=COLLECTED_AT,
    )


def component(bundle: dict, name: str) -> dict:
    return next(
        item
        for item in bundle["snapshot"]["scope"]["components"]
        if item["name"] == name
    )


def course_events(bundle: dict) -> list[dict]:
    return [
        event
        for event in bundle["data"]["calendarEvents"]
        if event["eventType"] == "course"
    ]


class JwSourceBundleTests(unittest.TestCase):
    def test_bundle_has_complete_components_and_course_series(self):
        bundle = build_bundle()

        validate_source_bundle(bundle)
        self.assertEqual(bundle["source"], "ustc_jw")
        self.assertEqual(bundle["subject"], {"accountId": "acct_test"})
        self.assertEqual(bundle["bundleId"], str(BUNDLE_ID))
        self.assertEqual(
            bundle["collectedAt"], "2026-07-26T12:00:00+08:00"
        )
        self.assertEqual(
            {
                item["name"]
                for item in bundle["snapshot"]["scope"]["components"]
            },
            {"course_table", "exam_arrange"},
        )
        self.assertGreater(len(bundle["data"]["courseSeries"]), 0)
        self.assertEqual(
            bundle["snapshot"]["scope"]["semesterKey"], "2026spring"
        )
        self.assertEqual(
            bundle["snapshot"]["scope"]["sourceSemesterId"], 421
        )

    def test_empty_exam_is_a_complete_zero_record_component(self):
        bundle = build_bundle(exam_html=EMPTY_EXAM_HTML)

        validate_source_bundle(bundle)
        self.assertEqual(component(bundle, "exam_arrange"), {
            "name": "exam_arrange",
            "status": "complete",
            "observedRecordCount": 0,
        })
        self.assertFalse(
            [
                event
                for event in bundle["data"]["calendarEvents"]
                if event["eventType"] == "exam"
            ]
        )

    def test_occurrence_keeps_all_teachers_without_remote_ids(self):
        bundle = build_bundle(exam_html=EMPTY_EXAM_HTML)
        event = next(
            event
            for event in course_events(bundle)
            if event["sourceDetails"]["lessonId"] == "1003"
        )

        self.assertEqual(
            event["participants"],
            [
                {"role": "teacher", "name": "李*"},
                {"role": "teacher", "name": "周*"},
                {"role": "teacher", "name": "吴*"},
            ],
        )

    def test_occurrence_teachers_can_differ_by_week(self):
        bundle = build_bundle(exam_html=EMPTY_EXAM_HTML)
        events = {
            event["time"]["startAt"]: event["participants"]
            for event in course_events(bundle)
            if event["sourceDetails"]["lessonId"] == "1001"
            and event["time"]["startAt"].startswith(
                ("2026-03-02", "2026-03-30")
            )
        }

        self.assertEqual(
            events,
            {
                "2026-03-02T09:45:00+08:00": [
                    {"role": "teacher", "name": "王*"}
                ],
                "2026-03-30T09:45:00+08:00": [
                    {"role": "teacher", "name": "张*"}
                ],
            },
        )

    def test_duplicate_legacy_rows_with_equivalent_exercise_class_merge(self):
        datum = load_course_datum()
        duplicate = copy.deepcopy(datum["result"]["scheduleList"][0])
        duplicate["exerciseClass"] = None
        datum["result"]["scheduleList"].append(duplicate)

        bundle = build_bundle(datum, EMPTY_EXAM_HTML)

        validate_source_bundle(bundle)
        self.assertEqual(len(course_events(bundle)), 6)
        occurrence = next(
            event
            for event in course_events(bundle)
            if event["time"]["startAt"] == "2026-03-02T09:45:00+08:00"
        )
        self.assertEqual(
            occurrence["participants"],
            [{"role": "teacher", "name": "王*"}],
        )

    def test_same_time_different_place_has_stable_collision_safe_identity(self):
        original = load_course_datum()
        first_row = original["result"]["scheduleList"][0]
        expanded = copy.deepcopy(original)
        other_place = copy.deepcopy(first_row)
        other_place["room"] = None
        other_place["customPlace"] = "另一间教室"
        expanded["result"]["scheduleList"].append(other_place)

        original_bundle = build_bundle(original, EMPTY_EXAM_HTML)
        expanded_bundle = build_bundle(expanded, EMPTY_EXAM_HTML)
        matching = [
            event
            for event in course_events(expanded_bundle)
            if event["sourceDetails"]["lessonId"] == "1001"
            and event["time"]["startAt"] == "2026-03-02T09:45:00+08:00"
        ]

        self.assertEqual(len(matching), 2)
        self.assertEqual(
            len({event["externalId"] for event in matching}), 2
        )
        original_id = next(
            event["externalId"]
            for event in course_events(original_bundle)
            if event["sourceDetails"]["lessonId"] == "1001"
            and event["time"]["startAt"] == "2026-03-02T09:45:00+08:00"
        )
        self.assertIn(original_id, {event["externalId"] for event in matching})

    def test_source_overlap_does_not_emit_a_relation(self):
        bundle = build_bundle(exam_html=EMPTY_EXAM_HTML)

        overlapping = [
            event
            for event in course_events(bundle)
            if event["time"]["startAt"] == "2026-03-10T14:00:00+08:00"
        ]
        self.assertEqual(len(overlapping), 2)
        self.assertEqual(bundle["data"]["scheduleRelations"], [])

    def test_course_and_exam_source_defaults_are_canonical(self):
        bundle = build_bundle()
        event_defaults = {
            event["eventType"]: event["sourceDefaults"]
            for event in bundle["data"]["calendarEvents"]
        }

        self.assertEqual(
            event_defaults["course"],
            {
                "importance": "normal",
                "attendancePolicy": "unknown",
                "listeningMode": "unknown",
            },
        )
        self.assertEqual(
            event_defaults["exam"],
            {
                "importance": "critical",
                "attendancePolicy": "must_go",
                "listeningMode": "unknown",
            },
        )

    def test_every_entity_has_one_typed_source_record(self):
        bundle = build_bundle()
        data = bundle["data"]

        targets = [
            (record["entityType"], record["entityExternalId"])
            for record in data["sourceRecords"]
        ]
        entities = [
            ("calendar_event", item["externalId"])
            for item in data["calendarEvents"]
        ]
        entities.extend(
            ("course_series", item["externalId"])
            for item in data["courseSeries"]
        )
        entities.extend(
            ("schedule_relation", item["externalId"])
            for item in data["scheduleRelations"]
        )
        self.assertCountEqual(targets, entities)
        self.assertEqual(len(targets), len(set(targets)))

    def test_exam_links_to_unique_matching_course_series(self):
        exam_html = load_exam_html().replace(
            "SAMPLE1001.01", "EE2003.02", 1
        )

        bundle = build_bundle(exam_html=exam_html)
        exam_event = next(
            event
            for event in bundle["data"]["calendarEvents"]
            if event["eventType"] == "exam"
            and event["sourceDetails"]["courseCode"] == "EE2003.02"
        )

        self.assertEqual(
            exam_event["seriesExternalId"],
            "ustc_jw:2026spring:series:lesson:1001",
        )
        self.assertEqual(bundle["data"]["scheduleRelations"], [])

    def test_bundle_contains_no_remote_identity_or_capture_material(self):
        bundle = build_bundle()
        encoded = json.dumps(bundle, ensure_ascii=False).lower()

        for forbidden in (
            "userid",
            "studentid",
            "teacherid",
            "personid",
            "contextid",
            "cookie",
            "token",
            "rawhtml",
            "browserprofile",
            "profilepath",
            "489951",
        ):
            self.assertNotIn(forbidden, encoded)

    def test_invalid_exam_component_fails_without_a_partial_bundle(self):
        with self.assertRaisesRegex(
            ValueError, "expected table#exams was not found"
        ):
            build_bundle(exam_html="<html><body>not an exam table</body></html>")

if __name__ == "__main__":
    unittest.main()
