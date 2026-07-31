"""Unit tests for the isolated ReadQueryJob / ReadQueryJobManager."""

from __future__ import annotations

import json
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

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
    PAUSE_PHASES,
    QueryJobNotFound,
    ReadQueryJobManager,
    TERMINAL_PHASES,
    YoungEnrolmentQuery,
    IcourseQuery,
    CampusSearchQuery,
    CampusDetailQuery,
    _wrap_campus_detail,
    _wrap_campus_search,
)
from ustc_assistant.bridge import query_jobs as qj


def _no_op_campus_refresh(catalog_path=None, **_):
    # 单测用：不联网，写一个空 catalog 使 _ensure_catalog_fresh 不 raise。
    p = Path(catalog_path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps({"schemaVersion": "1.0", "sources": {}}), encoding="utf-8")
    return {"sources": {}}


def _temp_campus_catalog_path() -> Path:
    """A per-call non-existent catalog path under the system temp dir.

    Keeps campus-search unit tests hermetic: refresh writes here (or nowhere)
    instead of touching the real ``tmp/campus-catalog.json``.
    """
    import tempfile

    return Path(tempfile.mkdtemp(prefix="campus-refresh-")) / "campus-catalog.json"


FIXTURE_DIRECTORY = Path(__file__).parents[1] / "fixtures/query-results"
FIXTURE_TIME = "2026-07-22T08:00:00+08:00"
from ustc_assistant.common.auth import (
    AccountMismatch,
    CollectionCancelled,
    LoginCredentials,
    UserActionRequired,
)
from ustc_assistant.sources.young.enrolment import (
    CollectedEnrolmentActivities,
    normalize_enrolments,
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
    def test_young_job_wraps_real_normalized_snapshot(self):
        snapshot = normalize_enrolments(
            CollectedEnrolmentActivities(
                records=(
                    {
                        "id": "activity-query-result-1",
                        "itemName": "蹇楁効娲诲姩",
                        "itemCategory": "service",
                        "itemStatus": "open",
                        "itemLimitNum": 24,
                        "applyNum": 6,
                    },
                ),
                reported_total=1,
                pages=1,
            ),
            collected_at="2026-07-22T08:00:00+08:00",
        )

        def query_fn(**kwargs):
            return snapshot, object()

        manager = ReadQueryJobManager(young_enrolment_query=query_fn)
        job = manager.start_young_enrolment(
            YoungEnrolmentQuery(
                account_id="acct_fixture",
                expected_username="PB00000000",
            )
        )

        self.assertEqual("complete", job.wait_for_terminal_or_pause())
        validate_query_result(job.result)
        self.assertEqual("蹇楁効娲诲姩", job.result["data"]["activities"][0]["name"])

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

    def test_cancel_wins_when_login_requirement_arrives_concurrently(self):
        entered = threading.Event()
        release = threading.Event()

        def query_fn(**kwargs):
            entered.set()
            release.wait(1)
            raise UserActionRequired("login required")

        manager = ReadQueryJobManager(young_enrolment_query=query_fn)
        job = manager.start_young_enrolment(
            YoungEnrolmentQuery(
                account_id="acct_fixture",
                expected_username="PB00000000",
            )
        )
        self.assertTrue(entered.wait(1))
        manager.cancel(job.id)
        release.set()

        self.assertEqual("cancelled", job.wait_for_terminal_or_pause())
        self.assertEqual(
            ["cancelled"],
            [
                event["phase"]
                for event in job.events
                if event["phase"] in TERMINAL_PHASES | PAUSE_PHASES
            ],
        )

    def test_resume_login_on_completed_young_job_rejected(self):
        # A young job that has already completed is not in needs_user_login;
        # resume_login must reject it with InvalidQueryJobState (locked to the
        # safe code do_POST maps to 409 invalid_job_state). This is the
        # manager-level regression guard for the phase check.
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
        with self.assertRaises(InvalidQueryJobState):
            manager.resume_login(
                job.id,
                credentials=LoginCredentials("PB00000000", "secret"),
            )

    def test_resume_login_on_paused_young_job_with_mismatched_username_rejected(
        self,
    ):
        # The username-match guard is defense-in-depth: the HTTP endpoint
        # fixes the username at job.request.expected_username, but the
        # manager must still reject a mismatched resume with AccountMismatch.
        def query_fn(**kwargs):
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
        with self.assertRaises(AccountMismatch):
            manager.resume_login(
                job.id,
                credentials=LoginCredentials("ZZ00000000", "secret"),
            )
        # The job must remain paused, not started.
        self.assertEqual("needs_user_login", job.phase)


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
    def test_campus_search_declares_trusted_url_embedded_in_result_text(self):
        envelope = _wrap_campus_search(
            {
                "query": "选课",
                "results": [
                    {
                        "id": "campus_abcdef0123456789abcdef0123",
                        "source": "teach_notice",
                        "kind": "notice",
                        "title": "Synthetic catalog entry",
                        "summary": (
                            "Read https://www.teach.ustc.edu.cn/notice/2. for details."
                        ),
                    }
                ],
            }
        )

        validate_query_result(envelope)
        self.assertEqual(
            ["https://www.teach.ustc.edu.cn/notice/2"],
            envelope["references"],
        )

    def test_campus_search_keeps_canonical_catalog_id(self):
        envelope = _wrap_campus_search(
            {
                "query": "选课",
                "results": [
                    {
                        "id": "campus_abcdef0123456789abcdef0123",
                        "source": "teach_notice",
                        "kind": "notice",
                        "title": "Synthetic catalog entry",
                        "publishedAt": "2026-07-20",
                    }
                ],
            }
        )

        self.assertTrue(envelope["data"]["results"][0]["id"].startswith("campus_"))

    def test_campus_search_wraps_raw_dict_into_envelope(self):
        qj._last_campus_refresh_attempt = None
        raw = {
            "source": "ustc_campus_catalog",
            "query": "选课",
            "results": [],
            "metadata": {"resultCount": 0},
        }

        def query_fn(*, query, filters, limit):
            return raw

        manager = ReadQueryJobManager(
            campus_search_query=query_fn,
            campus_refresh_fn=_no_op_campus_refresh,
            campus_catalog_path_fn=_temp_campus_catalog_path,
        )
        job = manager.start_campus_search(
            CampusSearchQuery(query="选课", filters=None, limit=20)
        )
        self.assertEqual("complete", job.wait_for_terminal_or_pause())
        validate_query_result(job.result)
        self.assertEqual("campus_search", job.result["queryType"])

    def test_campus_search_never_receives_credentials(self):
        qj._last_campus_refresh_attempt = None
        seen = []

        def query_fn(**kwargs):
            seen.append(kwargs)
            return {
                "source": "ustc_campus_catalog",
                "query": kwargs.get("query", "选课"),
                "results": [],
                "metadata": {"resultCount": 0},
            }

        manager = ReadQueryJobManager(
            campus_search_query=query_fn,
            campus_refresh_fn=_no_op_campus_refresh,
            campus_catalog_path_fn=_temp_campus_catalog_path,
        )
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


class CanonicalFixtureTests(unittest.TestCase):
    def test_campus_search_production_wrapper_matches_canonical_fixture(self):
        with patch(
            "ustc_assistant.bridge.query_contracts.beijing_now_iso",
            return_value=FIXTURE_TIME,
        ):
            actual = _wrap_campus_search(
                {
                    "query": "Fixture search",
                    "results": [
                        {
                            "id": "campus_abcdef0123456789abcdef0123",
                            "source": "teach_notice",
                            "kind": "notice",
                            "title": "Synthetic catalog entry",
                            "publishedAt": "2026-07-20",
                        }
                    ],
                }
            )

        expected = json.loads(
            (FIXTURE_DIRECTORY / "campus-search.json").read_text(encoding="utf-8")
        )
        self.assertEqual(expected, actual)

    def test_campus_detail_production_wrapper_matches_canonical_fixture(self):
        with patch(
            "ustc_assistant.bridge.query_contracts.beijing_now_iso",
            return_value=FIXTURE_TIME,
        ):
            actual = _wrap_campus_detail(
                {
                    "id": "campus_abcdef0123456789abcdef0123",
                    "source": "teach_notice",
                    "title": "Synthetic detail",
                    "content": "Bounded synthetic content.",
                    "url": "https://www.teach.ustc.edu.cn/notice/1",
                    "stale": False,
                    "followedLinks": [],
                }
            )

        expected = json.loads(
            (FIXTURE_DIRECTORY / "campus-detail.json").read_text(encoding="utf-8")
        )
        self.assertEqual(expected, actual)


class ResultValidationTests(unittest.TestCase):
    def test_invalid_envelope_ends_in_failed_with_safe_code(self):
        def query_fn(**kwargs):
            # An envelope missing required top-level keys.
            return {"schemaVersion": "1.0"}

        manager = ReadQueryJobManager(icourse_query=query_fn)
        job = manager.start_icourse(IcourseQuery(course="Fixture course"))
        self.assertEqual("failed", job.wait_for_terminal_or_pause())
        response = job.events_after(0)
        self.assertEqual("result_validation_failed", response["error"]["code"])
        self.assertIsNone(response["result"])

    def test_validation_error_detail_not_leaked_in_events(self):
        def query_fn(**kwargs):
            return build_icourse_envelope(
                data={
                    "query": {"mode": "course", "value": "Fixture course"},
                    "results": [{"secretToken": "leaked"}],
                },
                metadata={"resultCount": 1, "staleEntryCount": 0},
                references=[],
                generated_at="2026-07-22T08:00:00+08:00",
            )

        manager = ReadQueryJobManager(icourse_query=query_fn)
        job = manager.start_icourse(IcourseQuery(course="Fixture course"))
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

    def test_concurrent_resume_starts_only_one_interactive_thread(self):
        def query_fn(**kwargs):
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

        original_start = job.start
        first_resume_entered = threading.Event()
        second_resume_entered = threading.Event()
        release_first_resume = threading.Event()
        start_call_lock = threading.Lock()
        start_calls = 0

        def delayed_start(*, interactive, credentials):
            nonlocal start_calls
            if interactive:
                with start_call_lock:
                    start_calls += 1
                    call_number = start_calls
                if call_number == 1:
                    first_resume_entered.set()
                    release_first_resume.wait(1)
                else:
                    second_resume_entered.set()
            original_start(
                interactive=interactive,
                credentials=credentials,
            )

        job.start = delayed_start
        outcomes = []

        def resume():
            try:
                manager.resume_login(
                    job.id,
                    credentials=LoginCredentials("PB00000000", "secret"),
                )
                outcomes.append("started")
            except InvalidQueryJobState:
                outcomes.append("rejected")

        first = threading.Thread(target=resume)
        second = threading.Thread(target=resume)
        first.start()
        self.assertTrue(first_resume_entered.wait(1))
        second.start()
        second_started = second_resume_entered.wait(0.1)
        release_first_resume.set()
        first.join(1)
        second.join(1)

        self.assertFalse(second_started)
        self.assertEqual(["rejected", "started"], sorted(outcomes))
        self.assertEqual("complete", job.wait_for_terminal_or_pause())


class NotFoundTests(unittest.TestCase):
    def test_get_unknown_job_raises_not_found(self):
        manager = ReadQueryJobManager()
        with self.assertRaises(QueryJobNotFound):
            manager.get("does-not-exist")

    def test_cancel_unknown_job_raises_not_found(self):
        manager = ReadQueryJobManager()
        with self.assertRaises(QueryJobNotFound):
            manager.cancel("does-not-exist")


class CampusSearchAutoRefreshTests(unittest.TestCase):
    def test_refresh_invoked_when_catalog_missing(self):
        import tempfile
        from ustc_assistant.bridge import query_jobs as qj

        tmp_dir = Path(tempfile.mkdtemp(prefix="campus-refresh-"))
        catalog_path = tmp_dir / "campus-catalog.json"  # 不存在
        refresh_calls = []

        def refresh_fn(*, catalog_path, force):
            refresh_calls.append(catalog_path)
            # 模拟 refresh 写出 catalog 文件
            catalog_path.parent.mkdir(parents=True, exist_ok=True)
            catalog_path.write_text(
                json.dumps({"schemaVersion": "1.0", "sources": {}}),
                encoding="utf-8",
            )
            return {"sources": {}}

        def search_fn(*, query, filters, limit):
            return {"source": "ustc_campus_catalog", "query": query,
                    "results": [], "metadata": {"resultCount": 0}}

        # 重置进程级节流时间戳，避免被其他用例污染
        qj._last_campus_refresh_attempt = None
        manager = ReadQueryJobManager(
            campus_search_query=search_fn,
            campus_refresh_fn=refresh_fn,
            campus_catalog_path_fn=lambda: catalog_path,
        )
        job = manager.start_campus_search(CampusSearchQuery(query="通知"))
        self.assertEqual("complete", job.wait_for_terminal_or_pause())
        self.assertEqual(1, len(refresh_calls))
        self.assertEqual(catalog_path, refresh_calls[0])


if __name__ == "__main__":
    unittest.main()
