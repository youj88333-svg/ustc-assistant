from __future__ import annotations

import json
import threading
import unittest
from pathlib import Path

from ustc_assistant.bridge.jobs import (
    BridgeBusy,
    JobManager,
    JwCollectionRequest,
    YoungCollectionRequest,
)
from ustc_assistant.common.auth import (
    AccountMismatch,
    CollectionCancelled,
    LoginCredentials,
    UserActionRequired,
)
from ustc_assistant.config import JwSemesterConfig
from ustc_assistant.contracts import validate_source_bundle


FIXTURE = (
    Path(__file__).parents[1]
    / "fixtures"
    / "source-bundle"
    / "positive"
    / "jw-with-exam.json"
)
JW_BUNDLE = json.loads(FIXTURE.read_text(encoding="utf-8"))
JW_REQUEST = JwCollectionRequest(
    account_id="acct_fixture",
    expected_username="PB00000000",
    semester=JwSemesterConfig(461, "2026fall", "2026 秋季学期"),
)
YOUNG_REQUEST = YoungCollectionRequest(
    account_id="acct_fixture",
    expected_username="PB00000000",
)


class JobStateTests(unittest.TestCase):
    def test_user_action_job_resumes_to_complete_bundle(self):
        calls = []

        def collector(**kwargs):
            calls.append(kwargs)
            if not kwargs["allow_interactive_login"]:
                raise UserActionRequired("login required")
            return JW_BUNDLE, object()

        manager = JobManager()
        job = manager.start_jw(JW_REQUEST, collector=collector)

        self.assertEqual("needs_user_login", job.wait_for_terminal_or_pause())
        manager.resume_login(
            job.id,
            credentials=LoginCredentials("PB00000000", "secret"),
        )
        self.assertEqual("complete", job.wait_for_terminal_or_pause())
        validate_source_bundle(job.result)
        self.assertIsNone(job.credentials)
        self.assertNotIn("secret", json.dumps(job.events))
        self.assertFalse(calls[0]["allow_interactive_login"])
        self.assertTrue(calls[1]["allow_interactive_login"])

    def test_second_job_is_rejected_while_profile_is_owned(self):
        release = threading.Event()

        def blocking(**kwargs):
            release.wait(2)
            return JW_BUNDLE, object()

        manager = JobManager()
        first = manager.start_jw(JW_REQUEST, collector=blocking)
        with self.assertRaises(BridgeBusy):
            manager.start_young_schedule(YOUNG_REQUEST, collector=blocking)
        release.set()
        self.assertEqual("complete", first.wait_for_terminal_or_pause())

    def test_cancelled_job_has_no_result(self):
        entered = threading.Event()

        def collector(**kwargs):
            entered.set()
            while not kwargs["cancel_check"]():
                threading.Event().wait(0.005)
            raise CollectionCancelled("cancelled")

        manager = JobManager()
        job = manager.start_jw(JW_REQUEST, collector=collector)
        entered.wait(1)
        manager.cancel(job.id)

        self.assertEqual("cancelled", job.wait_for_terminal_or_pause())
        self.assertIsNone(job.result)

    def test_account_mismatch_is_redacted_and_event_cursor_is_monotonic(self):
        def collector(**kwargs):
            raise AccountMismatch("private values omitted")

        manager = JobManager()
        job = manager.start_jw(JW_REQUEST, collector=collector)
        self.assertEqual("failed", job.wait_for_terminal_or_pause())

        response = job.events_after(1)
        encoded = json.dumps(response)
        self.assertTrue(all(event["sequence"] > 1 for event in response["events"]))
        self.assertEqual("account_mismatch", response["error"]["code"])
        self.assertNotIn("PB00000000", encoded)
        self.assertIsNone(response["result"])

    def test_source_failure_is_redacted_and_has_no_partial_result(self):
        def collector(**kwargs):
            raise RuntimeError("private token and remote response")

        job = JobManager().start_jw(JW_REQUEST, collector=collector)
        self.assertEqual("failed", job.wait_for_terminal_or_pause())
        response = job.events_after(0)
        encoded = json.dumps(response)

        self.assertEqual("collection_failed", response["error"]["code"])
        self.assertIsNone(response["result"])
        self.assertNotIn("private token", encoded)


if __name__ == "__main__":
    unittest.main()
