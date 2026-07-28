from __future__ import annotations

import unittest

from ustc_assistant.bridge import query_contracts as contracts


YOUNG_ENROLMENT_REFERENCE = {
    "schemaVersion": "1.0",
    "queryType": "young_enrolment",
    "generatedAt": "2026-07-22T08:00:00+08:00",
    "data": {
        "activities": [
            {
                "sourceActivityId": "activity-1",
                "name": "Sample activity",
                "descriptionText": "Bounded plain text description.",
                "requirementsText": "Bounded requirements.",
            }
        ]
    },
    "metadata": {"activityCount": 1, "reportedTotal": 1, "pages": 1},
    "references": [],
}


ICOURSE_REFERENCE = {
    "schemaVersion": "1.0",
    "queryType": "icourse",
    "generatedAt": "2026-07-22T08:00:00+08:00",
    "data": {
        "query": {"mode": "course", "value": "量子物理B", "preferences": {}},
        "results": [
            {
                "sourceCourseId": "100",
                "sourceUrl": "https://icourse.club/course/100/",
                "name": "量子物理B",
                "teachers": ["教师甲"],
                "averageScore": 9.0,
                "reviewCount": 10,
                "aggregate": {
                    "difficulty": "medium",
                    "homework": "very little",
                    "grading": "excellent",
                    "gain": "a lot",
                },
                "siteAiSummary": None,
                "selectedEvidence": [],
                "relationStrength": "same_course_only",
                "ranking": {"score": 8.0, "reasons": []},
                "cache": {"fetchedAt": "2026-07-22T12:00:00+08:00", "stale": False},
            }
        ],
    },
    "metadata": {"resultCount": 1, "staleEntryCount": 0},
    "references": ["https://icourse.club/course/100/"],
}


CAMPUS_SEARCH_REFERENCE = {
    "schemaVersion": "1.0",
    "queryType": "campus_search",
    "generatedAt": "2026-07-22T08:00:00+08:00",
    "data": {
        "query": "选课",
        "results": [
            {
                "id": "campus_abcdef0123456789abcdef0123",
                "source": "teach_notice",
                "kind": "notice",
                "title": "秋季选课通知",
                "publishedAt": "2026-07-20",
            }
        ],
    },
    "metadata": {"resultCount": 1},
    "references": [],
}


CAMPUS_DETAIL_REFERENCE = {
    "schemaVersion": "1.0",
    "queryType": "campus_detail",
    "generatedAt": "2026-07-22T08:00:00+08:00",
    "data": {
        "id": "campus_abcdef0123456789abcdef0123",
        "source": "teach_notice",
        "title": "秋季选课通知",
        "content": "Bounded plain text content.",
        "url": "https://www.teach.ustc.edu.cn/notice/1",
        "candidateLinks": [
            {
                "id": "link_0123456789abcdef01234567",
                "url": "https://www.teach.ustc.edu.cn/link/1",
                "label": "Related notice",
                "reason": "explicit-reference",
            }
        ],
    },
    "metadata": {"stale": False},
    "references": [
        "https://www.teach.ustc.edu.cn/notice/1",
        "https://www.teach.ustc.edu.cn/link/1",
    ],
}


def deep_copy(value):
    import copy

    return copy.deepcopy(value)


class ModuleContractTests(unittest.TestCase):
    def test_module_exists(self):
        self.assertIsNotNone(contracts, "query contracts module must exist")


class EnvelopeTypeTests(unittest.TestCase):
    def test_exposes_four_query_type_constants(self):
        self.assertEqual(
            {"young_enrolment", "icourse", "campus_search", "campus_detail"},
            {contracts.YOUNG_ENROLMENT, contracts.ICOURSE, contracts.CAMPUS_SEARCH, contracts.CAMPUS_DETAIL},
        )

    def test_reference_envelopes_validate(self):
        for name, envelope in (
            ("young_enrolment", YOUNG_ENROLMENT_REFERENCE),
            ("icourse", ICOURSE_REFERENCE),
            ("campus_search", CAMPUS_SEARCH_REFERENCE),
            ("campus_detail", CAMPUS_DETAIL_REFERENCE),
        ):
            with self.subTest(name=name):
                contracts.validate_query_result(envelope)


class StrictRejectionTests(unittest.TestCase):
    def test_rejects_unknown_top_level_field(self):
        envelope = deep_copy(YOUNG_ENROLMENT_REFERENCE)
        envelope["unexpectedField"] = "value"
        with self.assertRaises(contracts.QueryResultValidationError):
            contracts.validate_query_result(envelope)

    def test_rejects_wrong_schema_version(self):
        envelope = deep_copy(ICOURSE_REFERENCE)
        envelope["schemaVersion"] = "2.0"
        with self.assertRaises(contracts.QueryResultValidationError):
            contracts.validate_query_result(envelope)

    def test_rejects_unknown_query_type(self):
        envelope = deep_copy(YOUNG_ENROLMENT_REFERENCE)
        envelope["queryType"] = "unknown_type"
        with self.assertRaises(contracts.QueryResultValidationError):
            contracts.validate_query_result(envelope)

    def test_rejects_missing_generated_at(self):
        envelope = deep_copy(ICOURSE_REFERENCE)
        del envelope["generatedAt"]
        with self.assertRaises(contracts.QueryResultValidationError):
            contracts.validate_query_result(envelope)

    def test_rejects_non_beijing_timestamp(self):
        envelope = deep_copy(ICOURSE_REFERENCE)
        envelope["generatedAt"] = "2026-07-22T08:00:00+00:00"
        with self.assertRaises(contracts.QueryResultValidationError):
            contracts.validate_query_result(envelope)

    def test_rejects_raw_html_in_text(self):
        envelope = deep_copy(YOUNG_ENROLMENT_REFERENCE)
        envelope["data"]["activities"][0]["descriptionText"] = "<p>raw html</p>"
        with self.assertRaises(contracts.QueryResultValidationError):
            contracts.validate_query_result(envelope)

    def test_rejects_html_like_angle_brackets_in_text(self):
        envelope = deep_copy(CAMPUS_DETAIL_REFERENCE)
        envelope["data"]["content"] = "text with <script> tag"
        with self.assertRaises(contracts.QueryResultValidationError):
            contracts.validate_query_result(envelope)

    def test_rejects_unbounded_text(self):
        envelope = deep_copy(YOUNG_ENROLMENT_REFERENCE)
        envelope["data"]["activities"][0]["descriptionText"] = "x" * (contracts.MAX_TEXT_LENGTH + 1)
        with self.assertRaises(contracts.QueryResultValidationError):
            contracts.validate_query_result(envelope)

    def test_rejects_url_outside_source_results(self):
        envelope = deep_copy(ICOURSE_REFERENCE)
        envelope["references"].append("https://evil.example.com/course/100/")
        with self.assertRaises(contracts.QueryResultValidationError):
            contracts.validate_query_result(envelope)

    def test_rejects_url_in_references_not_present_in_data(self):
        envelope = deep_copy(ICOURSE_REFERENCE)
        envelope["references"] = ["https://icourse.club/course/999/"]
        with self.assertRaises(contracts.QueryResultValidationError):
            contracts.validate_query_result(envelope)

    def test_rejects_private_enrolment_field_password(self):
        envelope = deep_copy(YOUNG_ENROLMENT_REFERENCE)
        envelope["data"]["activities"][0]["password"] = "secret"
        with self.assertRaises(contracts.QueryResultValidationError):
            contracts.validate_query_result(envelope)

    def test_rejects_private_enrolment_field_account_id(self):
        envelope = deep_copy(YOUNG_ENROLMENT_REFERENCE)
        envelope["data"]["activities"][0]["accountId"] = "PB00000000"
        with self.assertRaises(contracts.QueryResultValidationError):
            contracts.validate_query_result(envelope)

    def test_rejects_private_enrolment_field_user_identity(self):
        envelope = deep_copy(YOUNG_ENROLMENT_REFERENCE)
        envelope["data"]["activities"][0]["userId"] = "private-user"
        with self.assertRaises(contracts.QueryResultValidationError):
            contracts.validate_query_result(envelope)

    def test_rejects_private_enrolment_field_description_html(self):
        envelope = deep_copy(YOUNG_ENROLMENT_REFERENCE)
        envelope["data"]["activities"][0]["descriptionHtml"] = "<p>raw</p>"
        with self.assertRaises(contracts.QueryResultValidationError):
            contracts.validate_query_result(envelope)

    def test_rejects_sensitive_key_fragment_anywhere(self):
        envelope = deep_copy(ICOURSE_REFERENCE)
        envelope["data"]["results"][0]["sessionToken"] = "leaked"
        with self.assertRaises(contracts.QueryResultValidationError):
            contracts.validate_query_result(envelope)

    def test_rejects_arbitrary_url_in_campus_detail_data(self):
        envelope = deep_copy(CAMPUS_DETAIL_REFERENCE)
        envelope["data"]["url"] = "https://evil.example.com/notice/1"
        with self.assertRaises(contracts.QueryResultValidationError):
            contracts.validate_query_result(envelope)

    def test_rejects_campus_search_with_arbitrary_url_field(self):
        envelope = deep_copy(CAMPUS_SEARCH_REFERENCE)
        envelope["data"]["results"][0]["detailUrl"] = "https://evil.example.com/notice"
        with self.assertRaises(contracts.QueryResultValidationError):
            contracts.validate_query_result(envelope)

    def test_rejects_non_string_query_type(self):
        envelope = deep_copy(YOUNG_ENROLMENT_REFERENCE)
        envelope["queryType"] = 123
        with self.assertRaises(contracts.QueryResultValidationError):
            contracts.validate_query_result(envelope)

    def test_rejects_non_dict_data(self):
        envelope = deep_copy(ICOURSE_REFERENCE)
        envelope["data"] = "not a dict"
        with self.assertRaises(contracts.QueryResultValidationError):
            contracts.validate_query_result(envelope)


class BuilderTests(unittest.TestCase):
    def test_build_young_enrolment_envelope(self):
        envelope = contracts.build_young_enrolment_envelope(
            data={"activities": []},
            metadata={"activityCount": 0, "reportedTotal": 0, "pages": 0},
            references=[],
            generated_at="2026-07-22T08:00:00+08:00",
        )
        self.assertEqual("1.0", envelope["schemaVersion"])
        self.assertEqual("young_enrolment", envelope["queryType"])
        contracts.validate_query_result(envelope)

    def test_build_icourse_envelope(self):
        envelope = contracts.build_icourse_envelope(
            data={
                "query": {"mode": "course", "value": "量子物理B", "preferences": {}},
                "results": [],
            },
            metadata={"resultCount": 0, "staleEntryCount": 0},
            references=[],
            generated_at="2026-07-22T08:00:00+08:00",
        )
        self.assertEqual("icourse", envelope["queryType"])
        contracts.validate_query_result(envelope)

    def test_build_campus_search_envelope(self):
        envelope = contracts.build_campus_search_envelope(
            data={"query": "选课", "results": []},
            metadata={"resultCount": 0},
            references=[],
            generated_at="2026-07-22T08:00:00+08:00",
        )
        self.assertEqual("campus_search", envelope["queryType"])
        contracts.validate_query_result(envelope)

    def test_build_campus_detail_envelope(self):
        envelope = contracts.build_campus_detail_envelope(
            data={
                "id": "campus_abcdef0123456789abcdef0123",
                "source": "teach_notice",
                "title": "Title",
                "content": "Content",
                "url": "https://www.teach.ustc.edu.cn/notice/1",
            },
            metadata={"stale": False},
            references=["https://www.teach.ustc.edu.cn/notice/1"],
            generated_at="2026-07-22T08:00:00+08:00",
        )
        self.assertEqual("campus_detail", envelope["queryType"])
        contracts.validate_query_result(envelope)

    def test_beijing_now_returns_zoned_timestamp(self):
        timestamp = contracts.beijing_now_iso()
        self.assertTrue(timestamp.endswith("+08:00"))


if __name__ == "__main__":
    unittest.main()
