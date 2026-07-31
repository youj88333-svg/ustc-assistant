"""HTTP integration tests for the versioned Bridge query endpoints."""

from __future__ import annotations

import http.client
import json
import time
import unittest

from ustc_assistant.bridge.protocol import PROTOCOL_VERSION
from ustc_assistant.bridge.query_contracts import (
    build_campus_detail_envelope,
    build_campus_search_envelope,
    build_icourse_envelope,
    build_young_enrolment_envelope,
    validate_query_result,
)
from ustc_assistant.bridge.query_jobs import ReadQueryJobManager
from ustc_assistant.bridge.server import BridgeServer, IDLE_TIMEOUT_SECONDS
from ustc_assistant.common.auth import UserActionRequired
from tests.bridge.test_server import RunningServer, request


QUERY_PROTOCOL_VERSION = "1.0"

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


def _server_with_query_manager(**query_callables):
    manager = ReadQueryJobManager(**query_callables)
    return BridgeServer(parent_pid=None, query_job_manager=manager)


def _post_query(server, body, *, token=None):
    return request(server, "POST", "/queries", token=token, body=body)


def _events(server, job_id, *, after=0, token=None):
    return request(
        server, "GET", f"/query-jobs/{job_id}/events?after={after}", token=token
    )


def _resume_login(server, job_id, body, *, token=None):
    return request(
        server, "POST", f"/query-jobs/{job_id}/resume-login", token=token, body=body
    )


def _cancel(server, job_id, *, token=None):
    return request(
        server,
        "POST",
        f"/query-jobs/{job_id}/cancel",
        token=token,
        body={"protocolVersion": PROTOCOL_VERSION},
    )


class QueryAuthBoundaryTests(unittest.TestCase):
    def test_query_endpoints_require_token(self):
        with RunningServer(_server_with_query_manager()) as server:
            missing = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
                    "query": {"type": "icourse", "course": "量子物理B"},
                },
            )
            wrong = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
                    "query": {"type": "icourse", "course": "量子物理B"},
                },
                token="wrong",
            )

        self.assertEqual(401, missing[0])
        self.assertEqual(401, wrong[0])
        self.assertNotIn(server.token, missing[1] + wrong[1])

    def test_events_endpoint_requires_token(self):
        with RunningServer(_server_with_query_manager()) as server:
            missing = _events(server, "any", token=None)
            wrong = _events(server, "any", token="wrong")

        self.assertEqual(401, missing[0])
        self.assertEqual(401, wrong[0])


class CapabilitiesTests(unittest.TestCase):
    def test_capabilities_advertises_query_protocol_and_types(self):
        with RunningServer(_server_with_query_manager()) as server:
            response = request(
                server, "GET", "/capabilities", token=server.token
            )

        self.assertEqual(200, response[0])
        payload = json.loads(response[1])
        self.assertEqual("1.0", payload["queryProtocolVersion"])
        self.assertEqual(
            ["young_enrolment", "icourse", "campus_search", "campus_detail"],
            payload["queryTypes"],
        )


class RequestSizeTests(unittest.TestCase):
    def test_oversized_query_body_rejected(self):
        # Declare a Content-Length beyond the 64 KiB cap. The server rejects
        # the request in do_POST before reading the body, so we only need to
        # send a token body (the connection is closed with 413 after the
        # pre-read length check).
        with RunningServer(_server_with_query_manager()) as server:
            connection = http.client.HTTPConnection(
                "127.0.0.1", server.port, timeout=2
            )
            connection.request(
                "POST",
                "/queries",
                body=b"{}",
                headers={
                    "Authorization": f"Bearer {server.token}",
                    "Content-Type": "application/json",
                    "Content-Length": str(64 * 1024 + 1),
                },
            )
            response = connection.getresponse()
            body = response.read().decode("utf-8")
            connection.close()

        self.assertEqual(413, response.status)
        self.assertEqual("too_large", json.loads(body)["error"])


class IcourseQueryTests(unittest.TestCase):
    def _icourse_body(self, **query_overrides):
        query = {"type": "icourse", "course": "量子物理B"}
        query.update(query_overrides)
        return {
            "protocolVersion": PROTOCOL_VERSION,
            "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
            "query": query,
        }

    def test_icourse_query_returns_validated_envelope(self):
        def query_fn(*, course, teachers, preferences):
            return VALID_ICOURSE_ENVELOPE

        with RunningServer(
            _server_with_query_manager(icourse_query=query_fn)
        ) as server:
            started = _post_query(server, self._icourse_body(), token=server.token)
            job_id = json.loads(started[1])["jobId"]
            job = server.query_jobs.get(job_id)
            self.assertEqual("complete", job.wait_for_terminal_or_pause())
            events = _events(server, job_id, token=server.token)

        self.assertEqual(202, started[0])
        payload = json.loads(events[1])
        self.assertTrue(payload["terminal"])
        validate_query_result(payload["result"])

    def test_icourse_rejects_account_id_field(self):
        def query_fn(**kwargs):
            return VALID_ICOURSE_ENVELOPE

        with RunningServer(
            _server_with_query_manager(icourse_query=query_fn)
        ) as server:
            response = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
                    "accountId": "acct_fixture",
                    "query": {"type": "icourse", "course": "量子物理B"},
                },
                token=server.token,
            )

        self.assertEqual(400, response[0])

    def test_icourse_rejects_password_in_top_level(self):
        def query_fn(**kwargs):
            return VALID_ICOURSE_ENVELOPE

        with RunningServer(
            _server_with_query_manager(icourse_query=query_fn)
        ) as server:
            response = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
                    "password": "secret",
                    "query": {"type": "icourse", "course": "量子物理B"},
                },
                token=server.token,
            )

        self.assertEqual(400, response[0])
        self.assertNotIn("secret", response[1])

    def test_icourse_rejects_unknown_query_type(self):
        with RunningServer(_server_with_query_manager()) as server:
            response = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
                    "query": {"type": "unknown_type", "course": "x"},
                },
                token=server.token,
            )

        self.assertEqual(400, response[0])

    def test_icourse_rejects_url_field_in_query(self):
        with RunningServer(_server_with_query_manager()) as server:
            response = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
                    "query": {
                        "type": "icourse",
                        "course": "x",
                        "url": "https://evil.example.com",
                    },
                },
                token=server.token,
            )

        self.assertEqual(400, response[0])

    def test_icourse_rejects_path_field_in_query(self):
        with RunningServer(_server_with_query_manager()) as server:
            response = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
                    "query": {"type": "icourse", "course": "x", "path": "/etc/passwd"},
                },
                token=server.token,
            )

        self.assertEqual(400, response[0])

    def test_icourse_rejects_missing_query_protocol_version(self):
        with RunningServer(_server_with_query_manager()) as server:
            response = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "query": {"type": "icourse", "course": "x"},
                },
                token=server.token,
            )

        self.assertEqual(400, response[0])

    def test_icourse_rejects_wrong_query_protocol_version(self):
        with RunningServer(_server_with_query_manager()) as server:
            response = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "queryProtocolVersion": "2.0",
                    "query": {"type": "icourse", "course": "x"},
                },
                token=server.token,
            )

        self.assertEqual(400, response[0])


class CampusSearchQueryTests(unittest.TestCase):
    def test_campus_search_returns_wrapped_envelope(self):
        raw = {
            "source": "ustc_campus_catalog",
            "query": "选课",
            "results": [],
            "metadata": {"resultCount": 0},
        }

        def query_fn(*, query, filters, limit):
            return raw

        with RunningServer(
            _server_with_query_manager(campus_search_query=query_fn)
        ) as server:
            started = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
                    "query": {"type": "campus_search", "query": "选课", "limit": 10},
                },
                token=server.token,
            )
            job_id = json.loads(started[1])["jobId"]
            job = server.query_jobs.get(job_id)
            self.assertEqual("complete", job.wait_for_terminal_or_pause())
            events = _events(server, job_id, token=server.token)

        self.assertEqual(202, started[0])
        payload = json.loads(events[1])
        validate_query_result(payload["result"])
        self.assertEqual("campus_search", payload["result"]["queryType"])

    def test_campus_search_rejects_account_id(self):
        with RunningServer(_server_with_query_manager()) as server:
            response = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
                    "accountId": "acct",
                    "query": {"type": "campus_search", "query": "选课"},
                },
                token=server.token,
            )

        self.assertEqual(400, response[0])


class CampusDetailQueryTests(unittest.TestCase):
    def test_campus_detail_returns_wrapped_envelope(self):
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

        with RunningServer(
            _server_with_query_manager(campus_detail_query=query_fn)
        ) as server:
            started = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
                    "query": {
                        "type": "campus_detail",
                        "entryId": "campus_abcdef0123456789abcdef0123",
                    },
                },
                token=server.token,
            )
            job_id = json.loads(started[1])["jobId"]
            job = server.query_jobs.get(job_id)
            self.assertEqual("complete", job.wait_for_terminal_or_pause())
            events = _events(server, job_id, token=server.token)

        self.assertEqual(202, started[0])
        payload = json.loads(events[1])
        validate_query_result(payload["result"])
        self.assertEqual("campus_detail", payload["result"]["queryType"])

    def test_campus_detail_rejects_file_field(self):
        with RunningServer(_server_with_query_manager()) as server:
            response = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
                    "query": {
                        "type": "campus_detail",
                        "entryId": "campus_1",
                        "file": "/etc/passwd",
                    },
                },
                token=server.token,
            )

        self.assertEqual(400, response[0])


class YoungEnrolmentQueryTests(unittest.TestCase):
    def test_young_job_needs_login_then_completes_after_resume(self):
        def query_fn(**kwargs):
            if not kwargs["allow_interactive_login"]:
                raise UserActionRequired("login")
            return VALID_YOUNG_ENVELOPE, object()

        with RunningServer(
            _server_with_query_manager(young_enrolment_query=query_fn)
        ) as server:
            started = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
                    "accountId": "acct_fixture",
                    "expectedUsername": "PB00000000",
                    "query": {"type": "young_enrolment"},
                },
                token=server.token,
            )
            job_id = json.loads(started[1])["jobId"]
            job = server.query_jobs.get(job_id)
            self.assertEqual(
                "needs_user_login", job.wait_for_terminal_or_pause()
            )
            resumed = _resume_login(
                server,
                job_id,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "password": "secret",
                },
                token=server.token,
            )
            self.assertEqual(
                "complete", job.wait_for_terminal_or_pause()
            )
            events = _events(server, job_id, token=server.token)

        self.assertEqual(202, started[0])
        self.assertEqual(202, resumed[0])
        payload = json.loads(events[1])
        validate_query_result(payload["result"])

    def test_young_resume_completes_with_fixed_username(self):
        # resume-login does not carry a username; the job's expected_username is
        # fixed at creation. Verify the young job resumes with the correct
        # fixed username and completes. (A username mismatch cannot be
        # expressed over HTTP; the manager-level mismatch guard is covered in
        # test_query_jobs.ResumeGuardTests.)
        def query_fn(**kwargs):
            if not kwargs["allow_interactive_login"]:
                raise UserActionRequired("login")
            return VALID_YOUNG_ENVELOPE, object()

        with RunningServer(
            _server_with_query_manager(young_enrolment_query=query_fn)
        ) as server:
            started = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
                    "accountId": "acct_fixture",
                    "expectedUsername": "PB00000000",
                    "query": {"type": "young_enrolment"},
                },
                token=server.token,
            )
            job_id = json.loads(started[1])["jobId"]
            job = server.query_jobs.get(job_id)
            self.assertEqual(
                "needs_user_login", job.wait_for_terminal_or_pause()
            )
            resumed = _resume_login(
                server,
                job_id,
                {"protocolVersion": PROTOCOL_VERSION, "password": "secret"},
                token=server.token,
            )
            self.assertEqual(
                "complete", job.wait_for_terminal_or_pause()
            )

        self.assertEqual(202, resumed[0])

    def test_paused_young_query_prevents_idle_shutdown(self):
        now = [0.0]

        def query_fn(**kwargs):
            raise UserActionRequired("login")

        server = BridgeServer(
            parent_pid=None,
            monotonic=lambda: now[0],
            query_job_manager=ReadQueryJobManager(
                young_enrolment_query=query_fn
            ),
        )
        with RunningServer(server):
            started = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
                    "accountId": "acct_fixture",
                    "expectedUsername": "PB00000000",
                    "query": {"type": "young_enrolment"},
                },
                token=server.token,
            )
            job_id = json.loads(started[1])["jobId"]
            job = server.query_jobs.get(job_id)
            self.assertEqual(
                "needs_user_login", job.wait_for_terminal_or_pause()
            )

            now[0] = IDLE_TIMEOUT_SECONDS + 1
            time.sleep(0.35)

            self.assertFalse(server._stopping.is_set())

    def test_young_resume_on_completed_job_returns_409(self):
        # Regression: resume-login on a young job that is NOT in
        # needs_user_login (already completed) must return 409
        # invalid_job_state with a safe body — not drop the connection or
        # leak a stack trace. On the buggy code the manager raised NameError
        # (undefined InvalidQueryState), which escaped do_POST and dropped the
        # connection with RemoteDisconnected.
        def query_fn(**kwargs):
            return VALID_YOUNG_ENVELOPE, object()

        with RunningServer(
            _server_with_query_manager(young_enrolment_query=query_fn)
        ) as server:
            started = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
                    "accountId": "acct_fixture",
                    "expectedUsername": "PB00000000",
                    "query": {"type": "young_enrolment"},
                },
                token=server.token,
            )
            job_id = json.loads(started[1])["jobId"]
            job = server.query_jobs.get(job_id)
            self.assertEqual("complete", job.wait_for_terminal_or_pause())
            response = _resume_login(
                server,
                job_id,
                {"protocolVersion": PROTOCOL_VERSION, "password": "secret"},
                token=server.token,
            )

        self.assertEqual(409, response[0])
        self.assertEqual(
            "invalid_job_state", json.loads(response[1])["error"]
        )

    def test_young_query_without_account_id_rejected(self):
        with RunningServer(_server_with_query_manager()) as server:
            response = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
                    "query": {"type": "young_enrolment"},
                },
                token=server.token,
            )

        self.assertEqual(400, response[0])

    def test_icourse_resume_login_rejected(self):
        def query_fn(**kwargs):
            return VALID_ICOURSE_ENVELOPE

        with RunningServer(
            _server_with_query_manager(icourse_query=query_fn)
        ) as server:
            started = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
                    "query": {"type": "icourse", "course": "x"},
                },
                token=server.token,
            )
            job_id = json.loads(started[1])["jobId"]
            job = server.query_jobs.get(job_id)
            self.assertEqual("complete", job.wait_for_terminal_or_pause())
            response = _resume_login(
                server,
                job_id,
                {"protocolVersion": PROTOCOL_VERSION, "password": "secret"},
                token=server.token,
            )

        self.assertEqual(409, response[0])


class CancellationTests(unittest.TestCase):
    def test_cancel_query_job(self):
        import threading

        release = threading.Event()

        def query_fn(**kwargs):
            release.wait(2)
            return VALID_ICOURSE_ENVELOPE

        with RunningServer(
            _server_with_query_manager(icourse_query=query_fn)
        ) as server:
            started = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
                    "query": {"type": "icourse", "course": "x"},
                },
                token=server.token,
            )
            job_id = json.loads(started[1])["jobId"]
            cancelled = _cancel(server, job_id, token=server.token)
            release.set()
            job = server.query_jobs.get(job_id)
            phase = job.wait_for_terminal_or_pause()
            events = _events(server, job_id, token=server.token)

        self.assertEqual(202, cancelled[0])
        self.assertIn(phase, {"cancelled", "complete"})
        payload = json.loads(events[1])
        # Whatever terminal phase, no partial credential leaks.
        self.assertNotIn("secret", events[1])

    def test_cancel_unknown_job_returns_404(self):
        with RunningServer(_server_with_query_manager()) as server:
            response = _cancel(server, "nope", token=server.token)

        self.assertEqual(404, response[0])


class SafeFailureTests(unittest.TestCase):
    def test_query_failure_does_not_leak_private_detail(self):
        def query_fn(**kwargs):
            raise RuntimeError("private token and remote response")

        with RunningServer(
            _server_with_query_manager(icourse_query=query_fn)
        ) as server:
            started = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
                    "query": {"type": "icourse", "course": "x"},
                },
                token=server.token,
            )
            job_id = json.loads(started[1])["jobId"]
            job = server.query_jobs.get(job_id)
            self.assertEqual("failed", job.wait_for_terminal_or_pause())
            events = _events(server, job_id, token=server.token)

        payload = json.loads(events[1])
        self.assertEqual("query_failed", payload["error"]["code"])
        self.assertIsNone(payload["result"])
        self.assertNotIn("private token", events[1])

    def test_invalid_envelope_result_mapped_to_safe_code(self):
        def query_fn(**kwargs):
            return {"schemaVersion": "1.0"}

        with RunningServer(
            _server_with_query_manager(icourse_query=query_fn)
        ) as server:
            started = _post_query(
                server,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
                    "query": {"type": "icourse", "course": "x"},
                },
                token=server.token,
            )
            job_id = json.loads(started[1])["jobId"]
            job = server.query_jobs.get(job_id)
            self.assertEqual("failed", job.wait_for_terminal_or_pause())
            events = _events(server, job_id, token=server.token)

        payload = json.loads(events[1])
        self.assertEqual("result_validation_failed", payload["error"]["code"])
        self.assertIsNone(payload["result"])


if __name__ == "__main__":
    unittest.main()
