from __future__ import annotations

import json
import unittest
from pathlib import Path

from ustc_assistant.sources.jw import service as importer

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests" / "fixtures" / "jw"
COURSE_SAMPLE = FIXTURES / "course-datum.json"
EXAM_SAMPLE = FIXTURES / "exam-page.html"


class UnifiedImportTests(unittest.TestCase):
    def test_imports_course_and_exam_sources_into_one_package(self):
        result = importer.import_sources(
            course_datum_path=COURSE_SAMPLE,
            exam_html_path=EXAM_SAMPLE,
            semester_key="2026spring",
            user_id="user_sample",
        )

        self.assertEqual(9, len(result["calendarEvents"]))
        self.assertEqual(9, len(result["sourceRecords"]))
        self.assertEqual(1, len(result["scheduleRelations"]))
        self.assertEqual(
            {"course", "exam"},
            {event["type"] for event in result["calendarEvents"]},
        )
        self.assertEqual(
            "ustc_jw_import_bundle",
            result["metadata"]["bundleType"],
        )
        self.assertEqual(
            {"course_table", "exam_arrange"},
            set(result["metadata"]["includedSources"]),
        )
        self.assertNotIn("489951", json.dumps(result, ensure_ascii=False))

    def test_imports_only_course_when_exam_input_is_absent(self):
        result = importer.import_sources(
            course_datum_path=COURSE_SAMPLE,
            exam_html_path=None,
            semester_key="2026spring",
            user_id="user_sample",
        )

        self.assertEqual(6, len(result["calendarEvents"]))
        self.assertEqual(["course_table"], result["metadata"]["includedSources"])

    def test_rejects_duplicate_event_ids_across_sources(self):
        package = {
            "calendarEvents": [{"id": "event_same"}],
            "sourceRecords": [{"id": "source_a"}],
            "scheduleRelations": [],
        }

        with self.assertRaisesRegex(ValueError, r"duplicate calendar event id"):
            importer.merge_packages([package, package], "user_sample", ["a", "b"])

if __name__ == "__main__":
    unittest.main()
