from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))
MODULE_PATH = SCRIPTS / "collect_icourse_public.py"


def load_module():
    if not MODULE_PATH.exists():
        return None
    spec = importlib.util.spec_from_file_location("collect_icourse_public", MODULE_PATH)
    if spec is None or spec.loader is None:
        return None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


cli = load_module()


class FakeClient:
    def __init__(self):
        self.searches = []

    def search(self, value):
        self.searches.append(value)
        if value.startswith("Teacher"):
            return [{"kind": "teacher", "sourceUrl": "https://icourse.club/teacher/10/", "label": value}]
        return [
            {"kind": "course", "sourceUrl": "https://icourse.club/course/100/", "label": value + " (Teacher A)"},
            {"kind": "course", "sourceUrl": "https://icourse.club/course/101/", "label": value + " (Teacher B)"},
        ]

    def get_course(self, url):
        teacher = "Teacher A" if url.endswith("100/") else "Teacher B"
        return {
            "sourceCourseId": "100" if teacher.endswith("A") else "101",
            "sourceUrl": url,
            "name": "Sample Course",
            "teachers": [teacher],
            "terms": ["2026 Spring"],
            "averageScore": 9.0,
            "reviewCount": 10,
            "aggregate": {"difficulty": "medium", "homework": "very little", "grading": "excellent", "gain": "a lot"},
            "siteAiSummary": None,
            "reviews": [],
            "cache": {"fetchedAt": "2026-07-22T12:00:00+08:00", "stale": False},
        }

    def get_teacher(self, url):
        return {"sourceTeacherId": "10", "sourceUrl": url, "name": "Teacher A", "courseCount": 2, "reviewCount": 20, "courses": []}


class CourseOnlyTeacherSearchClient(FakeClient):
    def search(self, value):
        self.searches.append(value)
        return [{"kind": "course", "sourceUrl": "https://icourse.club/course/100/", "label": "Sample Course (Teacher A)"}]

    def get_course(self, url):
        result = super().get_course(url)
        result["teacherLinks"] = [{"sourceTeacherId": "10", "sourceUrl": "https://icourse.club/teacher/10/", "label": "Teacher A"}]
        return result


def bundle():
    def event(event_id, lesson_id, title, teacher):
        return {
            "id": event_id,
            "type": "course",
            "title": title,
            "participants": [{"role": "teacher", "name": teacher}],
            "metadata": {"lessonId": lesson_id, "courseCode": "TEST"},
            "userId": "private-user",
        }
    return {"calendarEvents": [event("a1", 1, "Course A", "Teacher A"), event("a2", 1, "Course A", "Teacher A"), event("b1", 2, "Course B", "Teacher B")]}


class ModuleContractTests(unittest.TestCase):
    def test_cli_module_exists(self):
        self.assertIsNotNone(cli, "public iCourse CLI module must exist")


@unittest.skipIf(cli is None, "CLI module not implemented yet")
class ArgumentTests(unittest.TestCase):
    def test_query_modes_are_mutually_exclusive(self):
        with self.assertRaises(SystemExit):
            cli.parse_args(["--course", "A", "--teacher", "B"])

    def test_parses_repeatable_preferences(self):
        args = cli.parse_args(["--course", "A", "--prefer", "homework=low", "--prefer", "grading=high"])
        self.assertEqual({"homework": "low", "grading": "high"}, dict(args.prefer))

    def test_rejects_group_only_without_jw_bundle(self):
        with self.assertRaises(SystemExit):
            cli.parse_args(["--course", "A", "--group-only"])


@unittest.skipIf(cli is None, "CLI module not implemented yet")
class OrchestrationTests(unittest.TestCase):
    def test_course_mode_ranks_candidates_and_writes_json(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "result.json"
            args = cli.parse_args(["--course", "Sample Course", "--prefer", "homework=low", "--output", str(output)])
            messages = []

            code = cli.run_query(args, client=FakeClient(), status=messages.append)
            result = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(0, code)
        self.assertEqual("course", result["query"]["mode"])
        self.assertEqual(2, len(result["results"]))
        self.assertIn("ranking", result["results"][0])
        self.assertTrue(any("2 results" in message for message in messages))

    def test_teacher_mode_reads_public_teacher_profile(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "result.json"
            args = cli.parse_args(["--teacher", "Teacher A", "--output", str(output)])

            cli.run_query(args, client=FakeClient(), status=lambda _: None)
            result = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual("Teacher A", result["results"][0]["name"])

    def test_teacher_mode_resolves_profile_through_course_only_search_results(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "result.json"
            args = cli.parse_args(["--teacher", "Teacher A", "--output", str(output)])

            cli.run_query(args, client=CourseOnlyTeacherSearchClient(), status=lambda _: None)
            result = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual("Teacher A", result["results"][0]["name"])

    def test_group_only_collapses_private_bundle_without_network_or_user_id(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "bundle.json"
            output = root / "groups.json"
            source.write_text(json.dumps(bundle()), encoding="utf-8")
            args = cli.parse_args(["--jw-bundle", str(source), "--group-only", "--output", str(output)])

            cli.run_query(args, client=None, status=lambda _: None)
            serialized = output.read_text(encoding="utf-8")
            result = json.loads(serialized)

        self.assertEqual(2, len(result["results"]))
        self.assertEqual(2, result["results"][0]["occurrenceCount"])
        self.assertNotIn("private-user", serialized)
        self.assertNotIn("userId", serialized)

    def test_jw_mode_searches_once_per_grouped_offering(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "bundle.json"
            source.write_text(json.dumps(bundle()), encoding="utf-8")
            args = cli.parse_args(["--jw-bundle", str(source), "--output", str(root / "out.json")])
            client = FakeClient()

            cli.run_query(args, client=client, status=lambda _: None)

        self.assertEqual(["Course A", "Course B"], client.searches)


if __name__ == "__main__":
    unittest.main()
