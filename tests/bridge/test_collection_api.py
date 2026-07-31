from __future__ import annotations

import json
import threading
import unittest

from ustc_assistant.bridge.jobs import JobManager
from ustc_assistant.bridge.protocol import PROTOCOL_VERSION
from ustc_assistant.bridge.query_jobs import ReadQueryJobManager
from ustc_assistant.bridge.server import BridgeServer
from ustc_assistant.common.auth import UserActionRequired
from tests.bridge.test_jobs import JW_BUNDLE
from tests.bridge.test_server import RunningServer, request

# The query protocol version advertised alongside the collection protocol.
QUERY_PROTOCOL_VERSION = "1.0"


class CollectionApiTests(unittest.TestCase):
    def test_collect_endpoint_rejects_password_field(self):
        with RunningServer() as server:
            response = request(
                server,
                "POST",
                "/collect/jw",
                token=server.token,
                body={
                    "protocolVersion": PROTOCOL_VERSION,
                    "accountId": "acct_fixture",
                    "expectedUsername": "PB00000000",
                    "password": "must-not-be-accepted",
                    "semester": {
                        "semesterId": 461,
                        "semesterKey": "2026fall",
                        "displayName": "2026 秋季学期",
                    },
                },
            )

        self.assertEqual(400, response[0])
        self.assertNotIn("must-not-be-accepted", response[1])

    def test_jw_job_returns_complete_bundle_only_at_terminal_event(self):
        def collector(**kwargs):
            return JW_BUNDLE, object()

        manager = JobManager()
        with RunningServer(
            BridgeServer(
                parent_pid=None,
                job_manager=manager,
                jw_collector=collector,
            )
        ) as server:
            started = request(
                server,
                "POST",
                "/collect/jw",
                token=server.token,
                body={
                    "protocolVersion": PROTOCOL_VERSION,
                    "accountId": "acct_fixture",
                    "expectedUsername": "PB00000000",
                    "semester": {
                        "semesterId": 461,
                        "semesterKey": "2026fall",
                        "displayName": "2026 秋季学期",
                    },
                },
            )
            job_id = json.loads(started[1])["jobId"]
            job = manager.get(job_id)
            self.assertEqual("complete", job.wait_for_terminal_or_pause())
            events = request(
                server,
                "GET",
                f"/jobs/{job_id}/events?after=0",
                token=server.token,
            )

        payload = json.loads(events[1])
        self.assertEqual(202, started[0])
        self.assertTrue(payload["terminal"])
        self.assertEqual("1.0", payload["result"]["schemaVersion"])
        self.assertNotIn("expectedUsername", events[1])

    def test_login_resume_supplies_password_only_to_resumed_collector(self):
        seen = []

        def collector(**kwargs):
            seen.append(kwargs["credentials"].password)
            if not kwargs["allow_interactive_login"]:
                raise UserActionRequired("login")
            return JW_BUNDLE, object()

        manager = JobManager()
        with RunningServer(
            BridgeServer(
                parent_pid=None,
                job_manager=manager,
                jw_collector=collector,
            )
        ) as server:
            started = request(
                server,
                "POST",
                "/collect/jw",
                token=server.token,
                body={
                    "protocolVersion": PROTOCOL_VERSION,
                    "accountId": "acct_fixture",
                    "expectedUsername": "PB00000000",
                    "semester": {
                        "semesterId": 461,
                        "semesterKey": "2026fall",
                        "displayName": "2026 秋季学期",
                    },
                },
            )
            job_id = json.loads(started[1])["jobId"]
            self.assertEqual(
                "needs_user_login",
                manager.get(job_id).wait_for_terminal_or_pause(),
            )
            resumed = request(
                server,
                "POST",
                "/login/resume",
                token=server.token,
                body={
                    "protocolVersion": PROTOCOL_VERSION,
                    "jobId": job_id,
                    "password": "secret",
                },
            )
            self.assertEqual(
                "complete", manager.get(job_id).wait_for_terminal_or_pause()
            )

        self.assertEqual(202, resumed[0])
        self.assertEqual([None, "secret"], seen)

    def test_collection_and_query_managers_coexist_on_one_server(self):
        # Task 12 regression: a single BridgeServer with BOTH a collection
        # job_manager and a query_job_manager still serves collection endpoints
        # correctly, AND /capabilities advertises both protocolVersion and the
        # query protocol surface (queryProtocolVersion + queryTypes). This guards
        # against the query endpoints (Task 8) breaking the collection API.
        def collector(**kwargs):
            return JW_BUNDLE, object()

        with RunningServer(
            BridgeServer(
                parent_pid=None,
                job_manager=JobManager(),
                jw_collector=collector,
                query_job_manager=ReadQueryJobManager(),
            )
        ) as server:
            # Collection endpoint still accepts and starts a JW job (202).
            started = request(
                server,
                "POST",
                "/collect/jw",
                token=server.token,
                body={
                    "protocolVersion": PROTOCOL_VERSION,
                    "accountId": "acct_coexist",
                    "expectedUsername": "PB00000000",
                    "semester": {
                        "semesterId": 461,
                        "semesterKey": "2026fall",
                        "displayName": "2026 秋季学期",
                    },
                },
            )
            self.assertEqual(202, started[0])
            self.assertIn("jobId", started[1])

            # /capabilities advertises both protocols side by side.
            capabilities = request(
                server, "GET", "/capabilities", token=server.token
            )

        self.assertEqual(200, capabilities[0])
        payload = json.loads(capabilities[1])
        self.assertEqual(PROTOCOL_VERSION, payload["protocolVersion"])
        self.assertEqual(
            QUERY_PROTOCOL_VERSION, payload["queryProtocolVersion"]
        )
        self.assertEqual(
            ["young_enrolment", "icourse", "campus_search", "campus_detail"],
            payload["queryTypes"],
        )


if __name__ == "__main__":
    unittest.main()
