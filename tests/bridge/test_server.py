from __future__ import annotations

import http.client
import json
import os
import threading
import unittest
from unittest.mock import patch

from ustc_assistant.bridge.protocol import PROTOCOL_VERSION
from ustc_assistant.bridge.server import (
    BridgeServer,
    _default_parent_alive,
    should_stop,
)


class RunningServer:
    def __init__(self, server=None):
        self.server = server

    def __enter__(self):
        self.server = self.server or BridgeServer(parent_pid=None)
        self.thread = threading.Thread(
            target=self.server.serve_forever,
            daemon=True,
        )
        self.thread.start()
        return self.server

    def __exit__(self, exc_type, exc, traceback):
        self.server.stop()
        self.thread.join(timeout=2)
        return False


def request(server, method, path, *, token=None, body=None):
    connection = http.client.HTTPConnection("127.0.0.1", server.port, timeout=2)
    headers = {}
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    encoded = None if body is None else json.dumps(body).encode("utf-8")
    if encoded is not None:
        headers["Content-Type"] = "application/json"
    connection.request(method, path, body=encoded, headers=headers)
    response = connection.getresponse()
    payload = response.read().decode("utf-8")
    connection.close()
    return response.status, payload


class HttpBoundaryTests(unittest.TestCase):
    def test_non_loopback_bind_is_rejected(self):
        with self.assertRaises(ValueError):
            BridgeServer(host="0.0.0.0", parent_pid=None)

    def test_unauthenticated_and_wrong_token_requests_are_rejected(self):
        with RunningServer() as server:
            missing = request(server, "GET", "/health")
            wrong = request(server, "GET", "/health", token="wrong")

        self.assertEqual(401, missing[0])
        self.assertEqual(401, wrong[0])
        self.assertNotIn(server.token, missing[1] + wrong[1])

    def test_health_capabilities_and_unknown_path(self):
        with RunningServer() as server:
            health = request(server, "GET", "/health", token=server.token)
            capabilities = request(
                server, "GET", "/capabilities", token=server.token
            )
            missing = request(server, "GET", "/unknown", token=server.token)

        self.assertEqual(200, health[0])
        payload = json.loads(capabilities[1])
        self.assertEqual(461, payload["jwSemester"]["semesterId"])
        self.assertEqual(404, missing[0])

    def test_invalid_shutdown_json_is_redacted(self):
        with RunningServer() as server:
            connection = http.client.HTTPConnection(
                "127.0.0.1", server.port, timeout=2
            )
            connection.request(
                "POST",
                "/shutdown",
                body=b'{"secret":"must-not-echo"',
                headers={
                    "Authorization": f"Bearer {server.token}",
                    "Content-Type": "application/json",
                },
            )
            response = connection.getresponse()
            body = response.read().decode("utf-8")
            connection.close()

        self.assertEqual(400, response.status)
        self.assertNotIn("must-not-echo", body)

    def test_unsupported_protocol_version_is_rejected(self):
        with RunningServer() as server:
            response = request(
                server,
                "POST",
                "/shutdown",
                token=server.token,
                body={"protocolVersion": "9.0"},
            )

        self.assertEqual(409, response[0])
        self.assertEqual(
            "unsupported_version", json.loads(response[1])["error"]
        )


class LifecycleTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "nt", "Windows process probe regression")
    def test_windows_parent_probe_never_uses_os_kill(self):
        with patch("ustc_assistant.bridge.server.os.kill") as kill:
            self.assertTrue(_default_parent_alive(os.getpid()))

        kill.assert_not_called()

    def test_parent_exit_and_idle_timeout_stop_server(self):
        self.assertTrue(
            should_stop(
                parent_pid=10,
                parent_alive=lambda pid: False,
                now=1000,
                last_activity=999,
                active_jobs=0,
            )
        )
        self.assertTrue(
            should_stop(
                parent_pid=None,
                parent_alive=lambda pid: True,
                now=1000,
                last_activity=399,
                active_jobs=0,
            )
        )
        self.assertFalse(
            should_stop(
                parent_pid=None,
                parent_alive=lambda pid: True,
                now=1000,
                last_activity=399,
                active_jobs=1,
            )
        )


if __name__ == "__main__":
    unittest.main()
