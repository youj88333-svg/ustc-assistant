from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "icourse_public_parser.py"


def load_module():
    if not MODULE_PATH.exists():
        return None
    spec = importlib.util.spec_from_file_location("icourse_public_parser", MODULE_PATH)
    if spec is None or spec.loader is None:
        return None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


parser = load_module()
SEARCH_HTML = (ROOT / "examples" / "icourse-search.sample.html").read_text(encoding="utf-8")
COURSE_HTML = (ROOT / "examples" / "icourse-course.sample.html").read_text(encoding="utf-8")
TEACHER_HTML = (ROOT / "examples" / "icourse-teacher.sample.html").read_text(encoding="utf-8")


class ModuleContractTests(unittest.TestCase):
    def test_parser_module_exists(self):
        self.assertIsNotNone(parser, "public iCourse parser module must exist")


@unittest.skipIf(parser is None, "parser module not implemented yet")
class SearchParserTests(unittest.TestCase):
    def test_keeps_only_course_and_teacher_results(self):
        results = parser.parse_search_results(SEARCH_HTML)

        self.assertEqual(["course", "course", "teacher"], [item["kind"] for item in results])
        self.assertEqual("https://icourse.club/course/100/", results[0]["sourceUrl"])
        self.assertNotIn("Public User", json.dumps(results))


@unittest.skipIf(parser is None, "parser module not implemented yet")
class CourseParserTests(unittest.TestCase):
    def test_keeps_site_aggregate_summary_and_public_reviews(self):
        result = parser.parse_course_page(COURSE_HTML, "https://icourse.club/course/100/?sort_by=upvote")

        self.assertEqual("100", result["sourceCourseId"])
        self.assertEqual("Sample Course", result["name"])
        self.assertEqual(["Teacher A", "Teacher B"], result["teachers"])
        self.assertEqual("very little", result["aggregate"]["homework"])
        self.assertEqual("icourse", result["siteAiSummary"]["source"])
        self.assertIn("Site-generated sample summary", result["siteAiSummary"]["text"])
        self.assertEqual("Sample public review.", result["reviews"][0]["content"])
        self.assertEqual(8, result["reviews"][0]["upvoteCount"])
        self.assertNotIn("author", result["reviews"][0])
        self.assertNotIn("Do not retain this author", json.dumps(result))

    def test_preserves_related_entries_and_teacher_links(self):
        result = parser.parse_course_page(COURSE_HTML, "https://icourse.club/course/100/")

        self.assertEqual(2, len(result["sameNameEntries"]))
        self.assertEqual("101", result["sameNameEntries"][0]["sourceCourseId"])
        self.assertEqual(1, len(result["teacherOtherCourses"]))
        self.assertEqual(["10", "11"], [item["sourceTeacherId"] for item in result["teacherLinks"]])

    def test_missing_course_heading_fails_loudly(self):
        with self.assertRaisesRegex(parser.ParseError, "course heading"):
            parser.parse_course_page("<html><body></body></html>", "https://icourse.club/course/100/")


@unittest.skipIf(parser is None, "parser module not implemented yet")
class TeacherParserTests(unittest.TestCase):
    def test_parses_teacher_totals_and_distinct_courses(self):
        result = parser.parse_teacher_page(TEACHER_HTML, "https://icourse.club/teacher/10/")

        self.assertEqual("Teacher A", result["name"])
        self.assertEqual(42, result["reviewCount"])
        self.assertEqual(9.1, result["normalizedAverage"])
        self.assertEqual(["100", "200"], [item["sourceCourseId"] for item in result["courses"]])


if __name__ == "__main__":
    unittest.main()
