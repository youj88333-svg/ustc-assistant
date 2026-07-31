"""Authenticated stdlib HTTP shell bound only to the loopback interface."""

from __future__ import annotations

import hmac
import json
import os
import threading
import time
from collections.abc import Mapping
from datetime import date
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable
from urllib.parse import parse_qs, urlsplit

from ustc_assistant.bridge.jobs import (
    BridgeBusy,
    InvalidJobState,
    JobManager,
    JobNotFound,
    JwCollectionRequest,
    YoungCollectionRequest,
)
from ustc_assistant.bridge.query_jobs import (
    BridgeQueryBusy,
    CampusDetailQuery,
    CampusSearchQuery,
    IcourseQuery,
    InvalidQueryJobState,
    QueryJobNotFound,
    ReadQueryJobManager,
    YoungEnrolmentQuery,
    _FORBIDDEN_URL_FILESYSTEM_FIELDS,
)
from ustc_assistant.bridge.protocol import (
    MAX_REQUEST_BYTES,
    PROTOCOL_VERSION,
    QUERY_PROTOCOL_VERSION,
    ProtocolError,
    make_handshake,
    parse_request_body,
)
from ustc_assistant.config import load_default_jw_semester
from ustc_assistant.config import JwSemesterConfig
from ustc_assistant.common.auth import AccountMismatch, LoginCredentials
from ustc_assistant.sources.jw import service as jw_service
from ustc_assistant.sources.young import source_bundle as young_service


IDLE_TIMEOUT_SECONDS = 10 * 60


def _default_parent_alive(pid: int) -> bool:
    if os.name == "nt":
        return _windows_parent_alive(pid)
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def _windows_parent_alive(pid: int) -> bool:
    import ctypes
    from ctypes import wintypes

    process_query_limited_information = 0x1000
    still_active = 259
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    open_process = kernel32.OpenProcess
    open_process.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    open_process.restype = wintypes.HANDLE
    get_exit_code = kernel32.GetExitCodeProcess
    get_exit_code.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    get_exit_code.restype = wintypes.BOOL
    close_handle = kernel32.CloseHandle
    close_handle.argtypes = [wintypes.HANDLE]
    close_handle.restype = wintypes.BOOL

    handle = open_process(process_query_limited_information, False, pid)
    if not handle:
        return False
    try:
        exit_code = wintypes.DWORD()
        return bool(get_exit_code(handle, ctypes.byref(exit_code))) and (
            exit_code.value == still_active
        )
    finally:
        close_handle(handle)


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
        parsed = urlsplit(self.path)
        if parsed.path == "/health":
            self._write(
                200,
                {"ok": True, "protocolVersion": PROTOCOL_VERSION},
            )
            return
        if parsed.path == "/capabilities":
            semester = load_default_jw_semester()
            self._write(
                200,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "supportedProtocolVersions": [PROTOCOL_VERSION],
                    "queryProtocolVersion": QUERY_PROTOCOL_VERSION,
                    "queryTypes": [
                        "young_enrolment",
                        "icourse",
                        "campus_search",
                        "campus_detail",
                    ],
                    "jwSemester": {
                        "semesterId": semester.semester_id,
                        "semesterKey": semester.semester_key,
                        "displayName": semester.display_name,
                    },
                },
            )
            return
        parts = parsed.path.strip("/").split("/")
        if len(parts) == 3 and parts[0] == "jobs" and parts[2] == "events":
            values = parse_qs(parsed.query).get("after", ["0"])
            try:
                after = int(values[0])
                wait_ms = int(
                    parse_qs(parsed.query).get("waitMs", ["15000"])[0]
                )
                if after < 0:
                    raise ValueError
                if not 0 <= wait_ms <= 20_000:
                    raise ValueError
                payload = self.bridge.jobs.get(parts[1]).events_after(
                    after, wait_timeout=wait_ms / 1000
                )
            except (ValueError, JobNotFound):
                self._write(404, {"error": "job_not_found"})
                return
            self._write(200, payload)
            return
        if (
            len(parts) == 3
            and parts[0] == "query-jobs"
            and parts[2] == "events"
        ):
            values = parse_qs(parsed.query).get("after", ["0"])
            try:
                after = int(values[0])
                wait_ms = int(
                    parse_qs(parsed.query).get("waitMs", ["15000"])[0]
                )
                if after < 0:
                    raise ValueError
                if not 0 <= wait_ms <= 20_000:
                    raise ValueError
                payload = self.bridge.query_jobs.get(parts[1]).events_after(
                    after, wait_timeout=wait_ms / 1000
                )
            except (ValueError, QueryJobNotFound):
                self._write(404, {"error": "query_job_not_found"})
                return
            self._write(200, payload)
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
            payload = parse_request_body(body, declared_length=length)
        except ProtocolError as exc:
            status = 413 if exc.code == "too_large" else 400
            if exc.code == "unsupported_version":
                status = 409
            self._write(status, {"error": exc.code})
            return
        try:
            response = self.bridge.dispatch_post(self.path, payload)
        except BridgeBusy:
            self._write(409, {"error": "bridge_busy"})
            return
        except BridgeQueryBusy:
            self._write(409, {"error": "bridge_query_busy"})
            return
        except JobNotFound:
            self._write(404, {"error": "job_not_found"})
            return
        except QueryJobNotFound:
            self._write(404, {"error": "query_job_not_found"})
            return
        except (InvalidJobState, AccountMismatch, InvalidQueryJobState):
            self._write(409, {"error": "invalid_job_state"})
            return
        except (KeyError, TypeError, ValueError):
            self._write(400, {"error": "invalid_request"})
            return
        if response is None:
            self._write(404, {"error": "not_found"})
            return
        status, result = response
        self._write(status, result)
        if self.path == "/shutdown":
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
        job_manager: JobManager | None = None,
        jw_collector: Callable[..., Any] = (
            jw_service.collect_jw_source_bundle
        ),
        young_collector: Callable[..., Any] = (
            young_service.collect_young_schedule_source_bundle
        ),
        query_job_manager: ReadQueryJobManager | None = None,
        young_enrolment_query: Callable[..., Any] | None = None,
        icourse_query: Callable[..., Any] | None = None,
        campus_search_query: Callable[..., Any] | None = None,
        campus_detail_query: Callable[..., Any] | None = None,
    ) -> None:
        if host != "127.0.0.1":
            raise ValueError("Bridge must bind to 127.0.0.1")
        if parent_pid is not None and parent_pid <= 0:
            raise ValueError("parent_pid must be positive")
        self.token = token or make_handshake(port=0, pid=os.getpid())["token"]
        self.parent_pid = parent_pid
        self._monotonic = monotonic
        self._parent_alive = parent_alive
        self.jobs = job_manager or JobManager()
        self._jw_collector = jw_collector
        self._young_collector = young_collector
        self.query_jobs = query_job_manager or ReadQueryJobManager(
            young_enrolment_query=young_enrolment_query,
            icourse_query=icourse_query,
            campus_search_query=campus_search_query,
            campus_detail_query=campus_detail_query,
        )
        self._last_activity = monotonic()
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

    @staticmethod
    def _text(payload: dict[str, Any], key: str, limit: int = 256) -> str:
        value = payload[key]
        if not isinstance(value, str) or not value.strip() or len(value) > limit:
            raise ValueError("invalid text")
        return value.strip()

    @staticmethod
    def _require_keys(
        payload: dict[str, Any],
        required: set[str],
        optional: set[str] | None = None,
    ) -> None:
        optional = optional or set()
        keys = set(payload)
        if not required <= keys or keys - required - optional:
            raise ValueError("invalid request fields")

    def dispatch_post(
        self, path: str, payload: dict[str, Any]
    ) -> tuple[int, dict[str, Any]] | None:
        if path == "/shutdown":
            self._require_keys(payload, {"protocolVersion"})
            return 200, {"ok": True}
        if path == "/collect/jw":
            self._require_keys(
                payload,
                {
                    "protocolVersion",
                    "accountId",
                    "expectedUsername",
                    "semester",
                },
            )
            semester = payload["semester"]
            if not isinstance(semester, dict):
                raise ValueError("invalid semester")
            self._require_keys(
                semester,
                {"semesterId", "semesterKey", "displayName"},
            )
            semester_id = semester["semesterId"]
            if (
                isinstance(semester_id, bool)
                or not isinstance(semester_id, int)
                or semester_id < 1
            ):
                raise ValueError("invalid semester")
            request = JwCollectionRequest(
                account_id=self._text(payload, "accountId"),
                expected_username=self._text(payload, "expectedUsername"),
                semester=JwSemesterConfig(
                    semester_id,
                    self._text(semester, "semesterKey"),
                    self._text(semester, "displayName"),
                ),
            )
            job = self.jobs.start_jw(
                request, collector=self._jw_collector
            )
            return 202, {"jobId": job.id, "phase": job.phase}
        if path == "/collect/young-schedule":
            self._require_keys(
                payload,
                {"protocolVersion", "accountId", "expectedUsername"},
                {"today"},
            )
            today_value = payload.get("today")
            today = (
                date.fromisoformat(today_value)
                if isinstance(today_value, str)
                else None
            )
            request = YoungCollectionRequest(
                account_id=self._text(payload, "accountId"),
                expected_username=self._text(payload, "expectedUsername"),
                today=today,
            )
            job = self.jobs.start_young_schedule(
                request, collector=self._young_collector
            )
            return 202, {"jobId": job.id, "phase": job.phase}
        if path == "/login/resume":
            self._require_keys(
                payload,
                {"protocolVersion", "jobId"},
                {"password"},
            )
            job = self.jobs.get(self._text(payload, "jobId"))
            password = payload.get("password")
            if password is not None and (
                not isinstance(password, str) or len(password) > 1024
            ):
                raise ValueError("invalid password")
            self.jobs.resume_login(
                job.id,
                credentials=LoginCredentials(
                    job.request.expected_username, password
                ),
            )
            return 202, {"jobId": job.id, "phase": job.phase}
        parts = path.strip("/").split("/")
        if len(parts) == 3 and parts[0] == "jobs" and parts[2] == "cancel":
            self._require_keys(payload, {"protocolVersion"})
            job = self.jobs.cancel(parts[1])
            return 202, {"jobId": job.id, "phase": job.phase}
        if path == "/queries":
            job = self._start_query_job(payload)
            return 202, {"jobId": job.id, "phase": job.phase}
        if (
            len(parts) == 3
            and parts[0] == "query-jobs"
            and parts[2] == "resume-login"
        ):
            self._require_keys(
                payload,
                {"protocolVersion"},
                {"password"},
            )
            job = self.query_jobs.get(parts[1])
            password = payload.get("password")
            if password is not None and (
                not isinstance(password, str) or len(password) > 1024
            ):
                raise ValueError("invalid password")
            if job.query_type != "young_enrolment":
                raise InvalidQueryJobState(
                    "only young_enrolment can resume login"
                )
            if job.phase != "needs_user_login":
                raise InvalidQueryJobState(
                    "job is not waiting for login"
                )
            self.query_jobs.resume_login(
                job.id,
                credentials=LoginCredentials(
                    job.request.expected_username, password
                ),
            )
            return 202, {"jobId": job.id, "phase": job.phase}
        if (
            len(parts) == 3
            and parts[0] == "query-jobs"
            and parts[2] == "cancel"
        ):
            self._require_keys(payload, {"protocolVersion"})
            job = self.query_jobs.cancel(parts[1])
            return 202, {"jobId": job.id, "phase": job.phase}
        return None

    @staticmethod
    def _reject_forbidden_fields(value: Any) -> None:
        """Reject URL/filesystem field names anywhere in a query request.

        These names are always invalid regardless of query type. Credential
        rejection for public queries is enforced by the per-type allowlist
        (icourse/campus top-level allowlists do not accept accountId,
        expectedUsername, password, or credentials).
        """
        if isinstance(value, Mapping):
            for key in value.keys():
                if isinstance(key, str) and key in _FORBIDDEN_URL_FILESYSTEM_FIELDS:
                    raise ValueError("forbidden field")
            for child in value.values():
                BridgeServer._reject_forbidden_fields(child)
        elif isinstance(value, list):
            for child in value:
                BridgeServer._reject_forbidden_fields(child)

    def _start_query_job(self, payload: dict[str, Any]):
        # Top-level allowlist: protocolVersion + queryProtocolVersion are
        # always required; accountId/expectedUsername only for young_enrolment.
        keys = set(payload)
        if not {"protocolVersion", "queryProtocolVersion"} <= keys:
            raise ValueError("invalid request fields")
        if payload.get("queryProtocolVersion") != QUERY_PROTOCOL_VERSION:
            raise ValueError("unsupported query version")
        query = payload.get("query")
        if not isinstance(query, dict) or "type" not in query:
            raise ValueError("invalid request fields")
        query_type = query.get("type")
        # Reject URL/filesystem field names anywhere in the request, before
        # per-type allowlisting. This is a hard, type-independent guard.
        BridgeServer._reject_forbidden_fields(payload)

        if query_type == "young_enrolment":
            self._require_keys(
                payload,
                {
                    "protocolVersion",
                    "queryProtocolVersion",
                    "accountId",
                    "expectedUsername",
                    "query",
                },
            )
            self._require_keys(query, {"type"})
            account_id = self._text(payload, "accountId")
            expected_username = self._text(payload, "expectedUsername")
            request = YoungEnrolmentQuery(
                account_id=account_id,
                expected_username=expected_username,
            )
            return self.query_jobs.start_young_enrolment(request)
        if query_type == "icourse":
            self._require_keys(
                payload,
                {"protocolVersion", "queryProtocolVersion", "query"},
            )
            self._require_keys(
                query,
                {"type", "course"},
                {"teachers", "preferences"},
            )
            course = self._text(query, "course")
            teachers_raw = query.get("teachers", ())
            if not isinstance(teachers_raw, (list, tuple)) or not all(
                isinstance(item, str) and item.strip() for item in teachers_raw
            ):
                raise ValueError("invalid teachers")
            teachers = tuple(teachers_raw)
            preferences = query.get("preferences")
            if preferences is not None:
                if not isinstance(preferences, dict) or not all(
                    isinstance(k, str) and isinstance(v, str)
                    for k, v in preferences.items()
                ):
                    raise ValueError("invalid preferences")
            request = IcourseQuery(
                course=course,
                teachers=teachers,
                preferences=preferences,
            )
            return self.query_jobs.start_icourse(request)
        if query_type == "campus_search":
            self._require_keys(
                payload,
                {"protocolVersion", "queryProtocolVersion", "query"},
            )
            self._require_keys(
                query,
                {"type", "query"},
                {"filters", "limit"},
            )
            search_query = self._text(query, "query")
            filters = query.get("filters")
            if filters is not None:
                if not isinstance(filters, dict) or not all(
                    isinstance(k, str) and isinstance(v, str)
                    for k, v in filters.items()
                ):
                    raise ValueError("invalid filters")
            limit = query.get("limit", 20)
            if (
                isinstance(limit, bool)
                or not isinstance(limit, int)
                or not 1 <= limit <= 100
            ):
                raise ValueError("invalid limit")
            request = CampusSearchQuery(
                query=search_query,
                filters=filters,
                limit=limit,
            )
            return self.query_jobs.start_campus_search(request)
        if query_type == "campus_detail":
            self._require_keys(
                payload,
                {"protocolVersion", "queryProtocolVersion", "query"},
            )
            self._require_keys(
                query,
                {"type", "entryId"},
                {"followLinkIds"},
            )
            entry_id = self._text(query, "entryId")
            follow_link_ids_raw = query.get("followLinkIds", ())
            if not isinstance(follow_link_ids_raw, (list, tuple)) or not all(
                isinstance(item, str) and item.strip()
                for item in follow_link_ids_raw
            ):
                raise ValueError("invalid followLinkIds")
            request = CampusDetailQuery(
                entry_id=entry_id,
                follow_link_ids=tuple(follow_link_ids_raw),
            )
            return self.query_jobs.start_campus_detail(request)
        raise ValueError("unknown query type")

    def serve_forever(self) -> None:
        self._serve_thread_id = threading.get_ident()
        monitor = threading.Thread(target=self._monitor, daemon=True)
        monitor.start()
        self._httpd.serve_forever(poll_interval=0.1)

    def _monitor(self) -> None:
        while not self._stopping.wait(0.25):
            with self._lock:
                last_activity = self._last_activity
                active_jobs = (
                    self.jobs.active_jobs + self.query_jobs.active_jobs
                )
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
