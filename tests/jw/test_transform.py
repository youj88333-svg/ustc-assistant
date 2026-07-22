import json
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import convert_ustc_jw_datum as legacy_course
import convert_ustc_jw_exam_html as legacy_exam
import import_ustc_jw as legacy_service

from ustc_assistant.sources.jw import course, exam, service


class TransformParityTests(unittest.TestCase):
    def test_new_bundle_matches_legacy_transforms(self):
        datum = json.loads(
            (ROOT / "examples" / "ustc-jw-datum.sample.json").read_text(
                encoding="utf-8"
            )
        )
        exam_html = (
            ROOT / "examples" / "ustc-jw-exam-page.sample.html"
        ).read_text(encoding="utf-8")

        expected = legacy_service.merge_packages(
            [
                legacy_course.convert(datum, "2026spring", "user_sample"),
                legacy_exam.convert(exam_html, "2026spring", "user_sample"),
            ],
            user_id="user_sample",
            included_sources=["course_table", "exam_arrange"],
        )
        actual = service.build_bundle(
            datum,
            exam_html,
            semester_key="2026spring",
            user_id="user_sample",
        )
        expected["metadata"].pop("generatedAt")
        actual["metadata"].pop("generatedAt")

        self.assertEqual(actual, expected)

    def test_public_converter_aliases_match_existing_contract(self):
        self.assertIs(course.convert_course, course.convert)
        self.assertIs(exam.convert_exam, exam.convert)


if __name__ == "__main__":
    unittest.main()
