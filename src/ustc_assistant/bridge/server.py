"""Authenticated stdlib HTTP shell bound only to the loopback interface."""

from __future__ import annotations

import hmac
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable

from ustc_assistant.bridge.protocol import (
    MAX_REQUEST_BYTES,
    PROTOCOL_VERSION,
    ProtocolError,
    make_handshake,
    parse_request_body,
)
from ustc_assistant.config import load_default_jw_semester


IDLE_TIMEOUT_SECONDS = 10 * 60


def _default_parent_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def should_stop(
    *,
    parent_pid: int | None,
    parent_alive: Callable[[int], bool],
    now: float,
    last_activity: float,
    active_jobs: int,
) -> bool:
    if parent_pid is not None and not parent_alive(parent_pid):
        return True
    return active_jobs == 0 and now - last_activity >= IDLE_TIMEOUT_SECONDS


class _LoopbackHttpServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, handler, bridge):
        self.bridge = bridge
        super().__init__(address, handler)


class _Handler(BaseHTTPRequestHandler):
    server: _LoopbackHttpServer

    def log_message(self, format: str, *args: Any) -> None:
        return

    @property
    def bridge(self) -> "BridgeServer":
        return self.server.bridge

    def _write(self, status: int, payload: dict[str, Any]) -> None:
        encoded = json.dumps(
            payload, ensure_ascii=False, separators=(",", ":")
        ).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def _authenticated(self) -> bool:
        value = self.headers.get("Authorization", "")
        expected = f"Bearer {self.bridge.token}"
        if not hmac.compare_digest(value, expected):
            self._write(401, {"error": "unauthorized"})
            return False
        self.bridge.touch()
        return True

    def do_GET(self) -> None:
        if not self._authenticated():
            return
        if self.path == "/health":
            self._write(
                200,
                {"ok": True, "protocolVersion": PROTOCOL_VERSION},
            )
            return
        if self.path == "/capabilities":
            semester = load_default_jw_semester()
            self._write(
                200,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "supportedProtocolVersions": [PROTOCOL_VERSION],
                    "jwSemester": {
                        "semesterId": semester.semester_id,
                        "semesterKey": semester.semester_key,
                        "displayName": semester.display_name,
                    },
                },
            )
            return
        self._write(404, {"error": "not_found"})

    def do_POST(self) -> None:
        if not self._authenticated():
            return
        length_text = self.headers.get("Content-Length", "0")
        try:
            length = int(length_text)
        except ValueError:
            self._write(400, {"error": "invalid_length"})
            return
        if length < 0:
            self._write(400, {"error": "invalid_length"})
            return
        if length > MAX_REQUEST_BYTES:
            self._write(413, {"error": "too_large"})
            return
        body = self.rfile.read(length)
        try:
            parse_request_body(body, declared_length=length)
        except ProtocolError as exc:
            status = 413 if exc.code == "too_large" else 400
            if exc.code == "unsupported_version":
                status = 409
            self._write(status, {"error": exc.code})
            return
        if self.path != "/shutdown":
            self._write(404, {"error": "not_found"})
            return
        self._write(200, {"ok": True})
        threading.Thread(target=self.bridge.stop, daemon=True).start()


class BridgeServer:
    def __init__(
        self,
        *,
        host: str = "127.0.0.1",
        port: int = 0,
        parent_pid: int | None,
        token: str | None = None,
        monotonic: Callable[[], float] = time.monotonic,
        parent_alive: Callable[[int], bool] = _default_parent_alive,
    ) -> None:
        if host != "127.0.0.1":
            raise ValueError("Bridge must bind to 127.0.0.1")
        if parent_pid is not None and parent_pid <= 0:
            raise ValueError("parent_pid must be positive")
        self.token = token or make_handshake(port=0, pid=os.getpid())["token"]
        self.parent_pid = parent_pid
        self._monotonic = monotonic
        self._parent_alive = parent_alive
        self._last_activity = monotonic()
        self._active_jobs = 0
        self._lock = threading.Lock()
        self._stopping = threading.Event()
        self._serve_thread_id: int | None = None
        self._httpd = _LoopbackHttpServer((host, port), _Handler, self)
        self.port = int(self._httpd.server_address[1])

    def handshake(self) -> dict[str, Any]:
        return {
            "protocolVersion": PROTOCOL_VERSION,
            "port": self.port,
            "token": self.token,
            "pid": os.getpid(),
        }

    def touch(self) -> None:
        with self._lock:
            self._last_activity = self._monotonic()

    def serve_forever(self) -> None:
        self._serve_thread_id = threading.get_ident()
        monitor = threading.Thread(target=self._monitor, daemon=True)
        monitor.start()
        self._httpd.serve_forever(poll_interval=0.1)

    def _monitor(self) -> None:
        while not self._stopping.wait(0.25):
            with self._lock:
                last_activity = self._last_activity
                active_jobs = self._active_jobs
            if should_stop(
                parent_pid=self.parent_pid,
                parent_alive=self._parent_alive,
                now=self._monotonic(),
                last_activity=last_activity,
                active_jobs=active_jobs,
            ):
                self.stop()
                return

    def stop(self) -> None:
        if self._stopping.is_set():
            return
        self._stopping.set()
        if threading.get_ident() != self._serve_thread_id:
            self._httpd.shutdown()
        self._httpd.server_close()
