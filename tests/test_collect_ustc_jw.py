from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "collect_ustc_jw.py"
COURSE_SAMPLE = ROOT / "examples" / "ustc-jw-datum.sample.json"
EXAM_SAMPLE = ROOT / "examples" / "ustc-jw-exam-page.sample.html"


def load_cli_module():
    if not MODULE_PATH.exists():
        return None
    spec = importlib.util.spec_from_file_location("collect_ustc_jw", MODULE_PATH)
    if spec is None or spec.loader is None:
        return None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


cli = load_cli_module()


def sample_sources():
    return (
        json.loads(COURSE_SAMPLE.read_text(encoding="utf-8")),
        EXAM_SAMPLE.read_text(encoding="utf-8"),
    )


class ModuleContractTests(unittest.TestCase):
    def test_cli_module_exists(self):
        self.assertIsNotNone(cli, "live collection CLI module must exist")


@unittest.skipIf(cli is None, "live collection CLI module not implemented yet")
class BuildBundleTests(unittest.TestCase):
    def test_builds_unified_bundle_from_in_memory_sources(self):
        course_datum, exam_html = sample_sources()

        result = cli.build_bundle(
            course_datum,
            exam_html,
            semester_key="2026spring",
            user_id="local_user",
        )

        self.assertEqual(9, len(result["calendarEvents"]))
        self.assertEqual(9, len(result["sourceRecords"]))
        self.assertEqual(1, len(result["scheduleRelations"]))
        self.assertEqual(
            ["course_table", "exam_arrange"],
            result["metadata"]["includedSources"],
        )
        serialized = json.dumps(result, ensure_ascii=False)
        self.assertNotIn("contextId", serialized)
        self.assertNotIn("dataId", serialized)


@unittest.skipIf(cli is None, "live collection CLI module not implemented yet")
class OutputStorageTests(unittest.TestCase):
    def test_default_mode_writes_only_unified_bundle(self):
        course_datum, exam_html = sample_sources()
        bundle = cli.build_bundle(
            course_datum,
            exam_html,
            semester_key="2026spring",
            user_id="local_user",
        )

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            output_path = root / "import.json"
            raw_dir = root / "private"
            written = cli.write_collection_outputs(
                bundle=bundle,
                output_path=output_path,
                save_raw=False,
                raw_dir=raw_dir,
                course_datum=course_datum,
                exam_html=exam_html,
            )

            self.assertEqual([output_path], written)
            self.assertTrue(output_path.exists())
            self.assertFalse(raw_dir.exists())
            saved = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(9, len(saved["calendarEvents"]))

    def test_save_raw_adds_course_json_and_exam_html(self):
        course_datum, exam_html = sample_sources()
        bundle = cli.build_bundle(
            course_datum,
            exam_html,
            semester_key="2026spring",
            user_id="local_user",
        )

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            output_path = root / "import.json"
            raw_dir = root / "private"
            written = cli.write_collection_outputs(
                bundle=bundle,
                output_path=output_path,
                save_raw=True,
                raw_dir=raw_dir,
                course_datum=course_datum,
                exam_html=exam_html,
            )

            course_path = raw_dir / "course-datum.raw.json"
            exam_path = raw_dir / "exam-arrange.raw.html"
            self.assertEqual([output_path, course_path, exam_path], written)
            self.assertEqual(
                course_datum,
                json.loads(course_path.read_text(encoding="utf-8")),
            )
            self.assertEqual(exam_html, exam_path.read_text(encoding="utf-8"))


@unittest.skipIf(cli is None, "live collection CLI module not implemented yet")
class CliFlowTests(unittest.TestCase):
    def test_parse_args_defaults_to_2026_spring(self):
        args = cli.parse_args([])

        self.assertEqual(421, args.semester_id)
        self.assertEqual("2026spring", args.semester_key)
        self.assertEqual("local_user", args.user_id)
        self.assertFalse(args.save_raw)

    def test_run_collection_uses_collector_and_writes_bundle(self):
        course_datum, exam_html = sample_sources()
        calls = []

        def fake_collect(**kwargs):
            calls.append(kwargs)
            return SimpleNamespace(
                course_datum=course_datum,
                exam_html=exam_html,
            )

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            output_path = root / "bundle.json"
            profile_dir = root / "profile"
            args = cli.parse_args(
                [
                    "--output",
                    str(output_path),
                    "--profile-dir",
                    str(profile_dir),
                ]
            )
            messages = []

            exit_code = cli.run_collection(
                args,
                collect_fn=fake_collect,
                status=messages.append,
            )

            self.assertEqual(0, exit_code)
            self.assertTrue(output_path.exists())
            bundle = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(9, len(bundle["calendarEvents"]))

        self.assertEqual(1, len(calls))
        self.assertEqual(421, calls[0]["semester_id"])
        self.assertEqual(profile_dir, calls[0]["profile_dir"])
        self.assertTrue(any("9 events" in message for message in messages))


if __name__ == "__main__":
    unittest.main()
