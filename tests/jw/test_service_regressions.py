from __future__ import annotations

import json
import unittest
from datetime import datetime
from pathlib import Path
from unittest.mock import patch
from uuid import UUID
from zoneinfo import ZoneInfo

from ustc_assistant.config import JwSemesterConfig
from ustc_assistant.contracts import validate_source_bundle
from ustc_assistant.sources.jw.collector import CollectedSources
from ustc_assistant.sources.jw import service as importer

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests" / "fixtures" / "jw"
COURSE_SAMPLE = FIXTURES / "course-datum.json"
EXAM_SAMPLE = FIXTURES / "exam-page.html"
EMPTY_EXAM_HTML = """\
<table id="exams">
  <tr>
    <th>课程号</th><th>考试类型</th><th>课程名称</th><th>日期时间</th>
    <th>考场</th><th>教学楼</th><th>考场所在校区</th><th>考试说明</th>
  </tr>
</table>
"""


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


class CanonicalCollectionTests(unittest.TestCase):
    def test_collect_entry_uses_semester_config_and_returns_sources(self):
        sources = CollectedSources(
            course_datum=json.loads(
                COURSE_SAMPLE.read_text(encoding="utf-8")
            ),
            exam_html=EMPTY_EXAM_HTML,
        )
        semester = JwSemesterConfig(
            421, "2026spring", "2026 春季学期"
        )
        bundle_id = UUID("00000000-0000-4000-8000-000000000111")
        collected_at = datetime(
            2026, 7, 26, 12, 0, tzinfo=ZoneInfo("Asia/Shanghai")
        )
        with patch(
            "ustc_assistant.sources.jw.service.collect_sources",
            return_value=sources,
        ) as collect:
            bundle, returned_sources = importer.collect_jw_source_bundle(
                account_id="acct_test",
                semester=semester,
                bundle_id=bundle_id,
                collected_at=collected_at,
                profile_dir=Path("private-profile"),
            )

        validate_source_bundle(bundle)
        self.assertIs(returned_sources, sources)
        collect.assert_called_once_with(
            semester_id=421,
            profile_dir=Path("private-profile"),
        )


if __name__ == "__main__":
    unittest.main()
