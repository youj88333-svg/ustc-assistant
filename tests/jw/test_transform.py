import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests" / "fixtures" / "jw"

from ustc_assistant.sources.jw import course, exam, service


class TransformContractTests(unittest.TestCase):
    def test_build_bundle_combines_fixture_sources(self):
        datum = json.loads(
            (FIXTURES / "course-datum.json").read_text(encoding="utf-8")
        )
        exam_html = (FIXTURES / "exam-page.html").read_text(encoding="utf-8")

        bundle = service.build_bundle(
            datum,
            exam_html,
            semester_key="2026spring",
            user_id="user_sample",
        )

        self.assertEqual(9, len(bundle["calendarEvents"]))
        self.assertEqual(9, len(bundle["sourceRecords"]))
        self.assertEqual(1, len(bundle["scheduleRelations"]))
        self.assertEqual(
            ["course_table", "exam_arrange"],
            bundle["metadata"]["includedSources"],
        )

    def test_public_converter_aliases_match_existing_contract(self):
        self.assertIs(course.convert_course, course.convert)
        self.assertIs(exam.convert_exam, exam.convert)


if __name__ == "__main__":
    unittest.main()
