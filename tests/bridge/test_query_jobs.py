"""Unit tests for the isolated ReadQueryJob / ReadQueryJobManager."""

from __future__ import annotations

import json
import threading
import unittest

from ustc_assistant.bridge.query_contracts import (
    QueryResultValidationError,
    build_campus_detail_envelope,
    build_campus_search_envelope,
    build_icourse_envelope,
    build_young_enrolment_envelope,
    validate_query_result,
)
from ustc_assistant.bridge.query_jobs import (
    BridgeQueryBusy,
    InvalidQueryJobState,
    QueryJobNotFound,
    ReadQueryJobManager,
    YoungEnrolmentQuery,
    IcourseQuery,
    CampusSearchQuery,
    CampusDetailQuery,
)
from ustc_assistant.common.auth import (
    AccountMismatch,
    CollectionCancelled,
    LoginCredentials,
    UserActionRequired,
)


VALID_YOUNG_ENVELOPE = build_young_enrolment_envelope(
    data={"activities": []},
    metadata={"activityCount": 0, "reportedTotal": 0, "pages": 0},
    references=[],
    generated_at="2026-07-22T08:00:00+08:00",
)

VALID_ICOURSE_ENVELOPE = build_icourse_envelope(
    data={"query": {"mode": "course", "value": "量子物理B", "preferences": {}}, "results": []},
    metadata={"resultCount": 0, "staleEntryCount": 0},
    references=[],
    generated_at="2026-07-22T08:00:00+08:00",
)

VALID_CAMPUS_SEARCH_ENVELOPE = build_campus_search_envelope(
    data={"query": "选课", "results": []},
    metadata={"resultCount": 0},
    references=[],
    generated_at="2026-07-22T08:00:00+08:00",
)

VALID_CAMPUS_DETAIL_ENVELOPE = build_campus_detail_envelope(
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


class YoungEnrolmentJobTests(unittest.TestCase):
    def test_young_job_completes_with_validated_envelope(self):
        def query_fn(**kwargs):
            return VALID_YOUNG_ENVELOPE, object()

        manager = ReadQueryJobManager(young_enrolment_query=query_fn)
        job = manager.start_young_enrolment(
            YoungEnrolmentQuery(
                account_id="acct_fixture",
                expected_username="PB00000000",
            )
        )
        self.assertEqual("complete", job.wait_for_terminal_or_pause())
        validate_query_result(job.result)
        self.assertIsNone(job.credentials)

    def test_young_job_pauses_for_login_then_resumes_to_complete(self):
        calls = []

        def query_fn(**kwargs):
            calls.append(
                {
                    "interactive": kwargs["allow_interactive_login"],
                    "password": kwargs["credentials"].password,
                }
            )
            if not kwargs["allow_interactive_login"]:
                raise UserActionRequired("login required")
            return VALID_YOUNG_ENVELOPE, object()

        manager = ReadQueryJobManager(young_enrolment_query=query_fn)
        job = manager.start_young_enrolment(
            YoungEnrolmentQuery(
                account_id="acct_fixture",
                expected_username="PB00000000",
            )
        )
        self.assertEqual("needs_user_login", job.wait_for_terminal_or_pause())
        manager.resume_login(
            job.id,
            credentials=LoginCredentials("PB00000000", "secret"),
        )
        self.assertEqual("complete", job.wait_for_terminal_or_pause())
        validate_query_result(job.result)
        self.assertEqual(
            [False, True], [call["interactive"] for call in calls]
        )
        self.assertEqual([None, "secret"], [call["password"] for call in calls])
        self.assertIsNone(job.credentials)
        self.assertNotIn("secret", json.dumps(job.events))

    def test_young_job_account_mismatch_on_resume_is_failed_safe(self):
        def query_fn(**kwargs):
            if not kwargs["allow_interactive_login"]:
                raise UserActionRequired("login")
            raise AccountMismatch("private values omitted")

        manager = ReadQueryJobManager(young_enrolment_query=query_fn)
        job = manager.start_young_enrolment(
            YoungEnrolmentQuery(
                account_id="acct_fixture",
                expected_username="PB00000000",
            )
        )
        self.assertEqual("needs_user_login", job.wait_for_terminal_or_pause())
        manager.resume_login(
            job.id,
            credentials=LoginCredentials("PB00000000", "secret"),
        )
        self.assertEqual("failed", job.wait_for_terminal_or_pause())
        response = job.events_after(0)
        self.assertEqual("account_mismatch", response["error"]["code"])
        self.assertIsNone(response["result"])
        self.assertNotIn("private", json.dumps(response))

    def test_young_job_cancelled_while_running_has_no_result(self):
        entered = threading.Event()

        def query_fn(**kwargs):
            entered.set()
            while not kwargs["cancel_check"]():
                threading.Event().wait(0.005)
            raise CollectionCancelled("cancelled")

        manager = ReadQueryJobManager(young_enrolment_query=query_fn)
        job = manager.start_young_enrolment(
            YoungEnrolmentQuery(
                account_id="acct_fixture",
                expected_username="PB00000000",
            )
        )
        entered.wait(1)
        manager.cancel(job.id)
        self.assertEqual("cancelled", job.wait_for_terminal_or_pause())
        self.assertIsNone(job.result)


class IcourseJobTests(unittest.TestCase):
    def test_icourse_job_completes_with_validated_envelope(self):
        def query_fn(*, course, teachers, preferences):
            return VALID_ICOURSE_ENVELOPE

        manager = ReadQueryJobManager(icourse_query=query_fn)
        job = manager.start_icourse(
            IcourseQuery(course="量子物理B", teachers=("教师甲",), preferences=None)
        )
        self.assertEqual("complete", job.wait_for_terminal_or_pause())
        validate_query_result(job.result)

    def test_icourse_job_never_receives_credentials(self):
        seen = []

        def query_fn(**kwargs):
            seen.append(kwargs)
            return VALID_ICOURSE_ENVELOPE

        manager = ReadQueryJobManager(icourse_query=query_fn)
        job = manager.start_icourse(IcourseQuery(course="量子物理B"))
        self.assertEqual("complete", job.wait_for_terminal_or_pause())
        self.assertEqual(1, len(seen))
        self.assertNotIn("credentials", seen[0])
        self.assertNotIn("account_id", seen[0])


class CampusSearchJobTests(unittest.TestCase):
    def test_campus_search_wraps_raw_dict_into_envelope(self):
        raw = {
            "source": "ustc_campus_catalog",
            "query": "选课",
            "results": [],
            "metadata": {"resultCount": 0},
        }

        def query_fn(*, query, filters, limit):
            return raw

        manager = ReadQueryJobManager(campus_search_query=query_fn)
        job = manager.start_campus_search(
            CampusSearchQuery(query="选课", filters=None, limit=20)
        )
        self.assertEqual("complete", job.wait_for_terminal_or_pause())
        validate_query_result(job.result)
        self.assertEqual("campus_search", job.result["queryType"])

    def test_campus_search_never_receives_credentials(self):
        seen = []

        def query_fn(**kwargs):
            seen.append(kwargs)
            return {
                "source": "ustc_campus_catalog",
                "query": kwargs.get("query", "选课"),
                "results": [],
                "metadata": {"resultCount": 0},
            }

        manager = ReadQueryJobManager(campus_search_query=query_fn)
        job = manager.start_campus_search(CampusSearchQuery(query="选课"))
        self.assertEqual("complete", job.wait_for_terminal_or_pause())
        self.assertEqual(1, len(seen))
        self.assertNotIn("credentials", seen[0])
        self.assertNotIn("account_id", seen[0])


class CampusDetailJobTests(unittest.TestCase):
    def test_campus_detail_wraps_raw_dict_into_envelope(self):
        raw = {
            "id": "campus_abcdef0123456789abcdef0123",
            "source": "teach_notice",
            "title": "Title",
            "content": "Content",
            "url": "https://www.teach.ustc.edu.cn/notice/1",
            "stale": False,
            "followedLinks": [],
        }

        def query_fn(*, entry_id, allow_stale, follow_link_ids):
            return raw

        manager = ReadQueryJobManager(campus_detail_query=query_fn)
        job = manager.start_campus_detail(
            CampusDetailQuery(entry_id="campus_abcdef0123456789abcdef0123")
        )
        self.assertEqual("complete", job.wait_for_terminal_or_pause())
        validate_query_result(job.result)
        self.assertEqual("campus_detail", job.result["queryType"])

    def test_campus_detail_never_receives_credentials(self):
        seen = []

        def query_fn(**kwargs):
            seen.append(kwargs)
            return {
                "id": "campus_abcdef0123456789abcdef0123",
                "source": "teach_notice",
                "title": "Title",
                "content": "Content",
                "stale": False,
                "followedLinks": [],
            }

        manager = ReadQueryJobManager(campus_detail_query=query_fn)
        job = manager.start_campus_detail(
            CampusDetailQuery(entry_id="campus_abcdef0123456789abcdef0123")
        )
        self.assertEqual("complete", job.wait_for_terminal_or_pause())
        self.assertEqual(1, len(seen))
        self.assertNotIn("credentials", seen[0])
        self.assertNotIn("account_id", seen[0])


class ResultValidationTests(unittest.TestCase):
    def test_invalid_envelope_ends_in_failed_with_safe_code(self):
        def query_fn(**kwargs):
            # An envelope missing required top-level keys.
            return {"schemaVersion": "1.0"}, object()

        manager = ReadQueryJobManager(young_enrolment_query=query_fn)
        job = manager.start_young_enrolment(
            YoungEnrolmentQuery(
                account_id="acct_fixture",
                expected_username="PB00000000",
            )
        )
        self.assertEqual("failed", job.wait_for_terminal_or_pause())
        response = job.events_after(0)
        self.assertEqual("result_validation_failed", response["error"]["code"])
        self.assertIsNone(response["result"])

    def test_validation_error_detail_not_leaked_in_events(self):
        def query_fn(**kwargs):
            envelope = build_young_enrolment_envelope(
                data={"activities": [{"secretToken": "leaked"}]},
                metadata={"activityCount": 1, "reportedTotal": 1, "pages": 1},
                references=[],
                generated_at="2026-07-22T08:00:00+08:00",
            )
            return envelope, object()

        manager = ReadQueryJobManager(young_enrolment_query=query_fn)
        job = manager.start_young_enrolment(
            YoungEnrolmentQuery(
                account_id="acct_fixture",
                expected_username="PB00000000",
            )
        )
        self.assertEqual("failed", job.wait_for_terminal_or_pause())
        encoded = json.dumps(job.events_after(0))
        self.assertNotIn("leaked", encoded)
        self.assertNotIn("secretToken", encoded)


class ConcurrencyTests(unittest.TestCase):
    def test_second_query_job_rejected_while_first_active(self):
        release = threading.Event()

        def blocking(**kwargs):
            release.wait(2)
            return VALID_ICOURSE_ENVELOPE

        manager = ReadQueryJobManager(icourse_query=blocking)
        first = manager.start_icourse(IcourseQuery(course="量子物理B"))
        with self.assertRaises(BridgeQueryBusy):
            manager.start_icourse(IcourseQuery(course="另一门"))
        release.set()
        self.assertEqual("complete", first.wait_for_terminal_or_pause())

    def test_resume_login_on_non_young_job_is_invalid_state(self):
        def query_fn(**kwargs):
            return VALID_ICOURSE_ENVELOPE

        manager = ReadQueryJobManager(icourse_query=query_fn)
        job = manager.start_icourse(IcourseQuery(course="量子物理B"))
        self.assertEqual("complete", job.wait_for_terminal_or_pause())
        with self.assertRaises(InvalidQueryJobState):
            manager.resume_login(
                job.id,
                credentials=LoginCredentials("PB00000000", "secret"),
            )


class NotFoundTests(unittest.TestCase):
    def test_get_unknown_job_raises_not_found(self):
        manager = ReadQueryJobManager()
        with self.assertRaises(QueryJobNotFound):
            manager.get("does-not-exist")

    def test_cancel_unknown_job_raises_not_found(self):
        manager = ReadQueryJobManager()
        with self.assertRaises(QueryJobNotFound):
            manager.cancel("does-not-exist")


if __name__ == "__main__":
    unittest.main()
