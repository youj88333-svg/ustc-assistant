from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from ustc_assistant import cli as app_cli
from ustc_assistant.sources.icourse import service as icourse

FORMAL_JW_FIXTURE = (
    Path(__file__).parents[1]
    / "fixtures"
    / "source-bundle"
    / "positive"
    / "jw-with-exam.json"
)

def parse_args(values):
    return app_cli.build_parser().parse_args(["query", "icourse", *values])


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


class ArgumentTests(unittest.TestCase):
    def test_query_modes_are_mutually_exclusive(self):
        with self.assertRaises(SystemExit):
            parse_args(["--course", "A", "--teacher", "B"])

    def test_parses_repeatable_preferences(self):
        args = parse_args(["--course", "A", "--prefer", "homework=low", "--prefer", "grading=high"])
        self.assertEqual({"homework": "low", "grading": "high"}, dict(args.prefer))

    def test_rejects_group_only_without_jw_bundle(self):
        args = parse_args(["--course", "A", "--group-only"])
        with self.assertRaisesRegex(ValueError, "group-only"):
            icourse.run_query(args, client=FakeClient())


class OrchestrationTests(unittest.TestCase):
    def test_course_mode_ranks_candidates(self):
        args = parse_args(["--course", "Sample Course", "--prefer", "homework=low"])
        result = icourse.run_query(args, client=FakeClient())

        self.assertEqual("course", result["query"]["mode"])
        self.assertEqual(2, len(result["results"]))
        self.assertIn("ranking", result["results"][0])

    def test_teacher_mode_reads_public_teacher_profile(self):
        args = parse_args(["--teacher", "Teacher A"])
        result = icourse.run_query(args, client=FakeClient())

        self.assertEqual("Teacher A", result["results"][0]["name"])

    def test_teacher_mode_resolves_profile_through_course_only_search_results(self):
        args = parse_args(["--teacher", "Teacher A"])
        result = icourse.run_query(args, client=CourseOnlyTeacherSearchClient())

        self.assertEqual("Teacher A", result["results"][0]["name"])

    def test_group_only_reads_formal_bundle_without_network_or_account_id(self):
        args = parse_args(
            ["--jw-bundle", str(FORMAL_JW_FIXTURE), "--group-only"]
        )

        result = icourse.run_query(args, client=None)
        serialized = json.dumps(result)

        self.assertEqual(1, len(result["results"]))
        self.assertEqual(1, result["results"][0]["occurrenceCount"])
        self.assertNotIn("acct_fixture", serialized)
        self.assertNotIn("accountId", serialized)

    def test_jw_mode_searches_once_per_grouped_offering(self):
        args = parse_args(["--jw-bundle", str(FORMAL_JW_FIXTURE)])
        client = FakeClient()

        icourse.run_query(args, client=client)

        self.assertEqual(["示例课程"], client.searches)

    def test_legacy_bundle_remains_readable_offline(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = Path(temporary_directory) / "legacy.json"
            source.write_text(json.dumps(bundle()), encoding="utf-8")
            args = parse_args(["--jw-bundle", str(source), "--group-only"])

            result = icourse.run_query(args, client=None)

        self.assertEqual(2, len(result["results"]))


if __name__ == "__main__":
    unittest.main()
