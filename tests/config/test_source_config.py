import json
import tempfile
import unittest
from pathlib import Path

from ustc_assistant.config import (
    JwSemesterConfig,
    SourceConfigError,
    load_default_jw_semester,
    render_flutter_source_defaults,
    resolve_jw_semester,
)
from ustc_assistant.config import _escape_dart_string


ROOT = Path(__file__).resolve().parents[2]
FLUTTER_OUTPUT = ROOT / "app" / "lib" / "core" / "config" / "generated_source_defaults.dart"
DEFAULT = JwSemesterConfig(461, "2026fall", "2026 秋季学期")


class SourceConfigTests(unittest.TestCase):
    def test_repository_default_is_2026_fall(self):
        config = load_default_jw_semester(ROOT / "config/source-defaults.json")

        self.assertEqual(config.semester_id, 461)
        self.assertEqual(config.semester_key, "2026fall")
        self.assertEqual(config.display_name, "2026 秋季学期")

    def test_debug_override_requires_the_complete_triple(self):
        with self.assertRaisesRegex(SourceConfigError, "complete semester override"):
            resolve_jw_semester(DEFAULT, semester_id=421)

    def test_complete_debug_override_replaces_every_semester_value(self):
        resolved = resolve_jw_semester(
            DEFAULT,
            semester_id=421,
            semester_key="2026spring",
            display_name="2026 春季学期",
        )

        self.assertEqual(
            resolved,
            JwSemesterConfig(421, "2026spring", "2026 春季学期"),
        )

    def test_loader_rejects_missing_root_and_jw_keys(self):
        cases = (
            ({}, "jw"),
            (
                {
                    "jw": {
                        "semesterKey": "2026fall",
                        "displayName": "2026 秋季学期",
                    }
                },
                "semesterId",
            ),
            (
                {
                    "jw": {
                        "semesterId": 461,
                        "displayName": "2026 秋季学期",
                    }
                },
                "semesterKey",
            ),
            (
                {
                    "jw": {
                        "semesterId": 461,
                        "semesterKey": "2026fall",
                    }
                },
                "displayName",
            ),
        )

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "source-defaults.json"
            for payload, message in cases:
                path.write_text(json.dumps(payload), encoding="utf-8")
                with self.subTest(payload=payload):
                    with self.assertRaisesRegex(SourceConfigError, message):
                        load_default_jw_semester(path)

    def test_loader_rejects_unknown_and_invalid_values(self):
        cases = (
            ({"unexpected": {}}, "unknown"),
            (
                {
                    "jw": {
                        "semesterId": 461,
                        "semesterKey": "2026fall",
                        "displayName": "2026 秋季学期",
                        "unexpected": True,
                    }
                },
                "unknown",
            ),
            (
                {
                    "jw": {
                        "semesterId": True,
                        "semesterKey": "2026fall",
                        "displayName": "2026 秋季学期",
                    }
                },
                "semesterId",
            ),
            (
                {
                    "jw": {
                        "semesterId": 0,
                        "semesterKey": "2026fall",
                        "displayName": "2026 秋季学期",
                    }
                },
                "semesterId",
            ),
            (
                {
                    "jw": {
                        "semesterId": 461,
                        "semesterKey": " ",
                        "displayName": "2026 秋季学期",
                    }
                },
                "semesterKey",
            ),
            (
                {
                    "jw": {
                        "semesterId": 461,
                        "semesterKey": "2026fall",
                        "displayName": " ",
                    }
                },
                "displayName",
            ),
        )

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "source-defaults.json"
            for payload, message in cases:
                path.write_text(json.dumps(payload), encoding="utf-8")
                with self.subTest(payload=payload):
                    with self.assertRaisesRegex(SourceConfigError, message):
                        load_default_jw_semester(path)

    def test_render_flutter_defaults_is_deterministic(self):
        rendered = render_flutter_source_defaults(
            JwSemesterConfig(421, "2026spring", "2026 春季学期")
        )
        self.assertIn("const int kDefaultJwSemesterId = 421;", rendered)
        self.assertIn("const String kDefaultJwSemesterKey = '2026spring';", rendered)
        self.assertIn("DO NOT EDIT", rendered)

    def test_render_flutter_defaults_escapes_dart_string_specials(self):
        self.assertEqual("\\\\", _escape_dart_string("\\"))
        self.assertEqual("\\'", _escape_dart_string("'"))
        self.assertEqual("\\r", _escape_dart_string("\r"))
        self.assertEqual("\\n", _escape_dart_string("\n"))
        self.assertEqual("\\$", _escape_dart_string("$"))
        self.assertEqual(
            "line\\n\\'  \\$x",
            _escape_dart_string("line\n'  $x"),
        )

    def test_checked_in_flutter_defaults_match_json(self):
        expected = render_flutter_source_defaults(load_default_jw_semester())
        actual = FLUTTER_OUTPUT.read_text(encoding="utf-8")
        self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
