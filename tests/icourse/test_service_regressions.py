from __future__ import annotations

import unittest
from pathlib import Path

from ustc_assistant.sources.icourse import service as query
from ustc_assistant.sources.icourse.jw_input import load_jw_course_groups


FORMAL_JW_FIXTURE = (
    Path(__file__).parents[1]
    / "fixtures"
    / "source-bundle"
    / "positive"
    / "jw-with-exam.json"
)


def event(event_id, lesson_id, title, teachers, event_type="course"):
    return {
        "id": event_id,
        "type": event_type,
        "title": title,
        "startAt": "2026-03-01T08:00:00+08:00",
        "participants": [{"role": "teacher", "name": name} for name in teachers],
        "metadata": {"lessonId": lesson_id, "courseCode": "TEST1001"},
        "userId": "must-not-enter-group-output",
    }


def sample_bundle():
    return {
        "calendarEvents": [
            event("a1", 100, "Sample Course", ["Teacher A"]),
            event("a2", 100, "Sample Course", ["Teacher A"]),
            event("b1", 101, "Sample Course", ["Teacher B", "Teacher C"]),
            event("exam", 999, "Sample Exam", [], event_type="exam"),
        ]
    }


def entry(course_id, teachers, homework, score, count):
    return {
        "sourceCourseId": str(course_id),
        "name": "Sample Course",
        "teachers": teachers,
        "terms": ["2026 Spring"],
        "averageScore": score,
        "reviewCount": count,
        "aggregate": {"difficulty": "medium", "homework": homework, "grading": "excellent", "gain": "a lot"},
        "reviews": [],
    }


class ModuleContractTests(unittest.TestCase):
    def test_query_module_exists(self):
        self.assertIsNotNone(query, "public iCourse query module must exist")


@unittest.skipIf(query is None, "query module not implemented yet")
class JwGroupingTests(unittest.TestCase):
    def test_formal_source_bundle_groups_course_series_and_ignores_exam(self):
        offerings = [
            group.as_dict() for group in load_jw_course_groups(FORMAL_JW_FIXTURE)
        ]

        self.assertEqual(1, len(offerings))
        self.assertEqual("173667", offerings[0]["sourceLessonId"])
        self.assertEqual("EXAMPLE1001", offerings[0]["courseCode"])
        self.assertEqual(1, offerings[0]["occurrenceCount"])
        self.assertNotIn("accountId", str(offerings))

    def test_legacy_adapter_collapses_occurrences_without_network(self):
        offerings = query.group_jw_offerings(sample_bundle())

        self.assertEqual(2, len(offerings))
        self.assertEqual([2, 1], [item["occurrenceCount"] for item in offerings])
        self.assertEqual([["Teacher A"], ["Teacher B", "Teacher C"]], [item["teachers"] for item in offerings])
        self.assertNotIn("userId", str(offerings))

    def test_invalid_bundle_fails_loudly_without_legacy_fallback(self):
        with self.assertRaisesRegex(ValueError, "JW input"):
            query.group_jw_offerings({})


@unittest.skipIf(query is None, "query module not implemented yet")
class ResolutionTests(unittest.TestCase):
    def test_multi_teacher_set_is_primary_relation_unit(self):
        offering = query.group_jw_offerings(sample_bundle())[1]

        self.assertEqual("exact_teacher_set", query.relation_strength(offering, entry(1, ["Teacher C", "Teacher B"], "medium", 8, 3)))
        self.assertEqual("partial_teacher_history", query.relation_strength(offering, entry(2, ["Teacher B"], "medium", 8, 3)))
        self.assertEqual("same_course_only", query.relation_strength(offering, entry(3, ["Teacher D"], "medium", 8, 3)))


@unittest.skipIf(query is None, "query module not implemented yet")
class RankingTests(unittest.TestCase):
    def test_homework_low_preference_uses_site_aggregate_and_keeps_reason(self):
        ranked = query.rank_entries(
            [entry(1, ["A"], "a lot", 9.8, 100), entry(2, ["B"], "very little", 8.5, 10)],
            {"homework": "low"},
        )

        self.assertEqual("2", ranked[0]["sourceCourseId"])
        self.assertIn("homework=low", ranked[0]["ranking"]["reasons"])

    def test_default_ranking_prefers_score_with_review_confidence(self):
        ranked = query.rank_entries(
            [entry(1, ["A"], "medium", 10.0, 1), entry(2, ["B"], "medium", 9.5, 30)],
            {},
        )

        self.assertEqual("2", ranked[0]["sourceCourseId"])

    def test_rejects_unknown_preference(self):
        with self.assertRaisesRegex(ValueError, "unsupported preference"):
            query.rank_entries([entry(1, ["A"], "medium", 8, 2)], {"attendance": "low"})


@unittest.skipIf(query is None, "query module not implemented yet")
class EvidenceTests(unittest.TestCase):
    def test_selects_recent_upvoted_and_conflicting_reviews_once(self):
        item = entry(1, ["A"], "very little", 9, 10)
        item["reviews"] = [
            {"sourceReviewId": "recent", "publishedAt": "2026-07-01T00:00:00+08:00", "upvoteCount": 1, "dimensions": {"homework": "very little"}},
            {"sourceReviewId": "upvoted", "publishedAt": "2025-01-01T00:00:00+08:00", "upvoteCount": 50, "dimensions": {"homework": "very little"}},
            {"sourceReviewId": "conflict", "publishedAt": "2024-01-01T00:00:00+08:00", "upvoteCount": 0, "dimensions": {"homework": "a lot"}},
        ]

        selected = query.select_evidence(item, recent=1, upvoted=1, conflicting=1)

        self.assertEqual(["recent", "upvoted", "conflict"], [review["sourceReviewId"] for review in selected])
        self.assertTrue(all(review["untrustedText"] for review in selected))


if __name__ == "__main__":
    unittest.main()
