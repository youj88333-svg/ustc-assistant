from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "import_ustc_jw.py"
COURSE_SAMPLE = ROOT / "examples" / "ustc-jw-datum.sample.json"
EXAM_SAMPLE = ROOT / "examples" / "ustc-jw-exam-page.sample.html"


def load_import_module():
    if not MODULE_PATH.exists():
        return None
    spec = importlib.util.spec_from_file_location("import_ustc_jw", MODULE_PATH)
    if spec is None or spec.loader is None:
        return None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


importer = load_import_module()


class ModuleContractTests(unittest.TestCase):
    def test_import_module_exists(self):
        self.assertIsNotNone(importer, "unified importer module must exist")


@unittest.skipIf(importer is None, "unified importer module not implemented yet")
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

    def test_cli_writes_combined_json(self):
        output_path = ROOT / "tmp" / "ustc-jw-import-test.json"
        completed = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "--course-datum",
                str(COURSE_SAMPLE),
                "--exam-html",
                str(EXAM_SAMPLE),
                "--output",
                str(output_path),
                "--semester-key",
                "2026spring",
                "--user-id",
                "user_sample",
            ],
            check=True,
            cwd=ROOT,
            text=True,
            capture_output=True,
        )

        self.assertIn("imported 9 events", completed.stdout)
        data = json.loads(output_path.read_text(encoding="utf-8"))
        self.assertEqual(9, len(data["calendarEvents"]))
        self.assertEqual(9, len(data["sourceRecords"]))


if __name__ == "__main__":
    unittest.main()
