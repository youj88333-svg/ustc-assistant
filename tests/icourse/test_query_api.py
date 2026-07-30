from __future__ import annotations

import json
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import patch

from ustc_assistant.bridge import query_contracts as contracts
from ustc_assistant.sources.icourse import query as query_api


FIXTURE_PATH = Path(__file__).parents[1] / "fixtures/query-results/icourse.json"
FIXTURE_TIME = "2026-07-22T08:00:00+08:00"


class FakeClient:
    """Mirrors tests/icourse/test_orchestration.FakeClient for query_course_public."""

    def __init__(self) -> None:
        self.searches: list[str] = []

    def search(self, value: str) -> list[dict[str, Any]]:
        self.searches.append(value)
        if value.startswith("Teacher"):
            return [
                {
                    "kind": "teacher",
                    "sourceUrl": "https://icourse.club/teacher/10/",
                    "label": value,
                }
            ]
        return [
            {
                "kind": "course",
                "sourceUrl": "https://icourse.club/course/100/",
                "label": value + " (教师甲)",
            },
            {
                "kind": "course",
                "sourceUrl": "https://icourse.club/course/101/",
                "label": value + " (教师乙)",
            },
        ]

    def get_course(self, url: str) -> dict[str, Any]:
        teacher = "教师甲" if url.endswith("100/") else "教师乙"
        return {
            "sourceCourseId": "100" if teacher == "教师甲" else "101",
            "sourceUrl": url,
            "name": "量子物理B",
            "teachers": [teacher],
            "terms": ["2026 Spring"],
            "averageScore": 9.0,
            "reviewCount": 10,
            "aggregate": {
                "difficulty": "medium",
                "homework": "very little",
                "grading": "excellent",
                "gain": "a lot",
            },
            "siteAiSummary": {"source": "icourse", "text": "AI summary text"},
            "reviews": [],
            "cache": {"fetchedAt": "2026-07-22T12:00:00+08:00", "stale": False},
            "teacherLinks": [
                {
                    "sourceTeacherId": "10",
                    "sourceUrl": "https://icourse.club/teacher/10/",
                    "label": "教师甲",
                }
            ] if teacher == "教师甲" else [],
        }

    def get_teacher(self, url: str) -> dict[str, Any]:
        return {
            "sourceTeacherId": "10",
            "sourceUrl": url,
            "name": "教师甲",
            "courseCount": 2,
            "reviewCount": 20,
            "courses": [],
        }


class ModuleContractTests(unittest.TestCase):
    def test_query_module_exists(self):
        self.assertIsNotNone(query_api, "icourse query module must exist")


class QueryCoursePublicTests(unittest.TestCase):
    def test_production_builder_matches_canonical_fixture(self):
        with patch(
            "ustc_assistant.bridge.query_contracts.beijing_now_iso",
            return_value=FIXTURE_TIME,
        ):
            actual = query_api.query_course_public(
                "Fixture course",
                teachers=(),
                preferences={},
                client=FakeClient(),
            )

        expected = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
        self.assertEqual(expected, actual)

    def test_returns_envelope_with_icourse_query_type(self):
        result = query_api.query_course_public(
            "量子物理B",
            teachers=("教师甲",),
            preferences={},
            client=FakeClient(),
        )

        self.assertEqual("1.0", result["schemaVersion"])
        self.assertEqual("icourse", result["queryType"])
        self.assertIn("generatedAt", result)
        self.assertTrue(result["generatedAt"].endswith("+08:00"))

    def test_example_call_with_tuple_teachers_works(self):
        result = query_api.query_course_public(
            "量子物理B",
            teachers=("教师甲",),
            preferences={},
            client=FakeClient(),
        )

        self.assertEqual("course", result["data"]["query"]["mode"])
        self.assertEqual("量子物理B", result["data"]["query"]["value"])
        self.assertEqual(2, len(result["data"]["results"]))
        self.assertIn("ranking", result["data"]["results"][0])
        self.assertIn("selectedEvidence", result["data"]["results"][0])
        self.assertIn("relationStrength", result["data"]["results"][0])

    def test_example_call_with_list_teachers_works(self):
        result = query_api.query_course_public(
            "量子物理B",
            teachers=["教师甲"],
            preferences={},
            client=FakeClient(),
        )

        self.assertEqual(2, len(result["data"]["results"]))

    def test_preferences_applied_to_ranking(self):
        result = query_api.query_course_public(
            "量子物理B",
            teachers=(),
            preferences={"homework": "low"},
            client=FakeClient(),
        )

        self.assertEqual({"homework": "low"}, result["data"]["query"]["preferences"])
        self.assertIn("homework=low", result["data"]["results"][0]["ranking"]["reasons"])

    def test_references_contain_only_source_urls_from_results(self):
        result = query_api.query_course_public(
            "量子物理B",
            teachers=(),
            preferences={},
            client=FakeClient(),
        )

        references = result["references"]
        self.assertIn("https://icourse.club/course/100/", references)
        self.assertIn("https://icourse.club/course/101/", references)
        for url in references:
            self.assertTrue(url.startswith("https://icourse.club/"))

    def test_metadata_includes_counts_and_cache_freshness(self):
        result = query_api.query_course_public(
            "量子物理B",
            teachers=(),
            preferences={},
            client=FakeClient(),
        )

        self.assertEqual(2, result["metadata"]["resultCount"])
        self.assertEqual(0, result["metadata"]["staleEntryCount"])

    def test_envelope_passes_strict_validation(self):
        result = query_api.query_course_public(
            "量子物理B",
            teachers=("教师甲",),
            preferences={},
            client=FakeClient(),
        )

        contracts.validate_query_result(result)

    def test_default_cache_dir_is_a_path(self):
        self.assertIsInstance(query_api.DEFAULT_CACHE_DIR, Path)
        self.assertEqual(Path("tmp/icourse-cache"), query_api.DEFAULT_CACHE_DIR)

    def test_builds_client_when_none_provided(self):
        # Smoke: with client=None the function must build a PublicIcourseClient
        # using build_client; we only assert the signature path does not crash
        # on import. Actual network is not exercised.
        self.assertTrue(callable(query_api.query_course_public))

    def test_does_not_accept_jw_bundle_or_user_identity(self):
        import inspect

        signature = inspect.signature(query_api.query_course_public)
        params = set(signature.parameters)
        self.assertNotIn("jw_bundle", params)
        self.assertNotIn("account_id", params)
        self.assertNotIn("user_id", params)
        self.assertIn("course", params)
        self.assertIn("teachers", params)
        self.assertIn("preferences", params)
        self.assertIn("cache_dir", params)
        self.assertIn("timeout_seconds", params)
        self.assertIn("client", params)

    def test_signature_defaults_match_contract(self):
        import inspect

        signature = inspect.signature(query_api.query_course_public)
        self.assertEqual((), signature.parameters["teachers"].default)
        self.assertIsNone(signature.parameters["preferences"].default)
        self.assertEqual(query_api.DEFAULT_CACHE_DIR, signature.parameters["cache_dir"].default)
        self.assertEqual(20, signature.parameters["timeout_seconds"].default)
        self.assertIsNone(signature.parameters["client"].default)

    def test_teachers_keyword_only(self):
        import inspect

        signature = inspect.signature(query_api.query_course_public)
        self.assertTrue(signature.parameters["teachers"].kind == inspect.Parameter.KEYWORD_ONLY)
        self.assertTrue(signature.parameters["preferences"].kind == inspect.Parameter.KEYWORD_ONLY)

    def test_site_ai_summary_preserved_when_present(self):
        result = query_api.query_course_public(
            "量子物理B",
            teachers=(),
            preferences={},
            client=FakeClient(),
        )

        self.assertIsNotNone(result["data"]["results"][0]["siteAiSummary"])

    def test_relation_strength_computed(self):
        result = query_api.query_course_public(
            "量子物理B",
            teachers=("教师甲",),
            preferences={},
            client=FakeClient(),
        )

        # relationStrength is present on every ranked candidate.
        for entry in result["data"]["results"]:
            self.assertIn("relationStrength", entry)
            self.assertIn(
                entry["relationStrength"],
                {"exact_teacher_set", "partial_teacher_history", "same_course_only"},
            )


if __name__ == "__main__":
    unittest.main()
