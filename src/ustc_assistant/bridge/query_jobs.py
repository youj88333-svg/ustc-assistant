"""Isolated, cancellable read-query jobs for the read-only Agent.

The ReadQueryJob / ReadQueryJobManager parallel CollectionJob / JobManager but
are fully isolated: they own their own request dataclasses, event list,
cancellation event, result validator (the injected ``validate_query_result``),
and injected per-query-type callables. A query job never shares the browser
profile gate with collection jobs; the ReadQueryJobManager has its own
single-active-job gate so at most one query job runs at a time (two query jobs
cannot coexist, but a query job and a collection job can).

Security notes:
* Only ``young_enrolment`` can enter ``needs_user_login`` and accept account
  identity / credentials. The public iCourse / campus queries never receive
  credentials — the manager does not pass them and the request allowlist
  rejects them.
* ``validate_query_result`` is called on every outgoing envelope before it is
  exposed. A validation breach ends the job in ``failed`` with the safe code
  ``result_validation_failed``; the validation error detail (which may echo
  untrusted content) is never surfaced.
* Job events expose only phase, sequence, safe count, terminal flag, bounded
  result, and a safe error code — never raw params, credentials, or unbounded
  data. Mirrors ``CollectionJob`` event shape.
* Passwords are never stored on the job (cleared in finally), mirroring the
  collection contract.
"""

from __future__ import annotations

import re
import threading
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any, Callable
from uuid import uuid4

from ustc_assistant.bridge.query_contracts import (
    CAMPUS_DETAIL,
    CAMPUS_SEARCH,
    ICOURSE,
    YOUNG_ENROLMENT,
    QueryResultValidationError,
    build_campus_detail_envelope,
    build_campus_search_envelope,
    validate_query_result,
)
from ustc_assistant.common.auth import (
    AccountMismatch,
    CollectionCancelled,
    LoginCredentials,
    UserActionRequired,
)


TERMINAL_PHASES = frozenset({"complete", "cancelled", "failed"})
PAUSE_PHASES = frozenset({"needs_user_login"})


class BridgeQueryBusy(RuntimeError):
    code = "bridge_query_busy"


class QueryJobNotFound(LookupError):
    code = "query_job_not_found"


class InvalidQueryJobState(RuntimeError):
    code = "invalid_query_state"


# Field names that are ALWAYS invalid anywhere in a query request body, because
# they could smuggle a URL or filesystem path into the source pipeline. The
# request allowlist already rejects unknown keys per type; this set is an
# extra, type-independent guard that fails fast and with a clear code.
_FORBIDDEN_URL_FILESYSTEM_FIELDS = frozenset(
    {
        "url",
        "href",
        "link",
        "path",
        "file",
        "filesystem",
        "filepath",
        "pathname",
        "dir",
        "directory",
        "uri",
        "src",
        "source_url",
        "sourceUrl",
        "detail_url",
        "detailUrl",
    }
)


@dataclass(frozen=True)
class YoungEnrolmentQuery:
    account_id: str
    expected_username: str


@dataclass(frozen=True)
class IcourseQuery:
    course: str
    teachers: tuple[str, ...] = ()
    preferences: Mapping[str, str] | None = field(default=None)


@dataclass(frozen=True)
class CampusSearchQuery:
    query: str
    filters: Mapping[str, str] | None = None
    limit: int = 20


@dataclass(frozen=True)
class CampusDetailQuery:
    entry_id: str
    follow_link_ids: tuple[str, ...] = ()


def _collect_trusted_urls(value: Any, found: list[str], seen: set[str]) -> None:
    """Collect every trusted https URL that appears in a campus raw result."""
    if isinstance(value, str):
        for match in _URL_TOKEN_RE.finditer(value):
            url = match.group(0).rstrip(".,;:!?")
            from urllib.parse import urlsplit

            host = (urlsplit(url).hostname or "").lower()
            if host in _CAMPUS_TRUSTED_HOSTS and url not in seen:
                seen.add(url)
                found.append(url)
        return
    if isinstance(value, Mapping):
        for child in value.values():
            _collect_trusted_urls(child, found, seen)
        return
    if isinstance(value, Sequence) and not isinstance(value, (str, bytes)):
        for child in value:
            _collect_trusted_urls(child, found, seen)


_CAMPUS_TRUSTED_HOSTS = frozenset(
    {
        "teach.ustc.edu.cn",
        "www.teach.ustc.edu.cn",
        "finance.ustc.edu.cn",
    }
)

_URL_TOKEN_RE = re.compile(r"(?:(?:https?:)?//[^\s<>'\"`]+)")


def _wrap_campus_search(raw: Mapping[str, Any]) -> dict[str, Any]:
    """Wrap a raw ``search_catalog`` result dict in a Query Result 1.0 envelope."""
    results = raw.get("results", [])
    data = {
        "query": raw.get("query", ""),
        "results": list(results),
    }
    metadata = dict(raw.get("metadata", {}))
    if "resultCount" not in metadata:
        metadata["resultCount"] = len(results) if isinstance(results, list) else 0
    references: list[str] = []
    _collect_trusted_urls(results, references, set())
    return build_campus_search_envelope(
        data=data,
        metadata=metadata,
        references=references,
    )


def _wrap_campus_detail(raw: Mapping[str, Any]) -> dict[str, Any]:
    """Wrap a raw ``read_detail`` result dict in a Query Result 1.0 envelope."""
    data = dict(raw)
    # ``stale`` and internal cache bookkeeping are metadata, not data.
    stale = data.pop("stale", False)
    data.pop("followedLinks", None)
    references: list[str] = []
    _collect_trusted_urls(data, references, set())
    return build_campus_detail_envelope(
        data=data,
        metadata={"stale": bool(stale)},
        references=references,
    )


class ReadQueryJob:
    def __init__(
        self,
        *,
        request: Any,
        query_type: str,
        runner: Callable[..., Any],
        validator: Callable[[Mapping[str, Any]], None],
        release: Callable[["ReadQueryJob"], None],
    ) -> None:
        self.id = str(uuid4())
        self.request = request
        self.query_type = query_type
        self._runner = runner
        self._validator = validator
        self._release = release
        self._condition = threading.Condition()
        self._cancelled = threading.Event()
        self._events: list[dict[str, Any]] = []
        self.phase = "starting"
        self.result: dict[str, Any] | None = None
        self.error: dict[str, str] | None = None
        self.credentials = None
        self._emit("starting")

    @property
    def events(self) -> list[dict[str, Any]]:
        with self._condition:
            return [dict(event) for event in self._events]

    def _emit(self, phase: str, *, safe_count: int | None = None) -> None:
        with self._condition:
            self._emit_locked(phase, safe_count=safe_count)

    def _emit_locked(
        self, phase: str, *, safe_count: int | None = None
    ) -> None:
        self.phase = phase
        event: dict[str, Any] = {
            "sequence": len(self._events) + 1,
            "phase": phase,
        }
        if safe_count is not None:
            event["safeCount"] = safe_count
        self._events.append(event)
        self._condition.notify_all()

    def start(self, *, interactive: bool, credentials: Any) -> None:
        with self._condition:
            self._emit_locked(
                "waiting_for_user" if interactive else "checking_session"
            )
            thread = threading.Thread(
                target=self._run,
                kwargs={
                    "interactive": interactive,
                    "credentials": credentials,
                },
                daemon=True,
            )
            thread.start()

    def resume_login(self, *, credentials: LoginCredentials) -> None:
        with self._condition:
            if self.phase != "needs_user_login":
                raise InvalidQueryJobState("job is not waiting for login")
            if (
                credentials.username.casefold()
                != self.request.expected_username.casefold()
            ):
                raise AccountMismatch("resume account did not match")
            self.start(interactive=True, credentials=credentials)

    def _run(self, *, interactive: bool, credentials: Any) -> None:
        try:
            value = self._runner(
                self.request,
                interactive=interactive,
                credentials=credentials,
                cancel_check=self._cancelled.is_set,
            )
            with self._condition:
                if self._cancelled.is_set():
                    raise CollectionCancelled("query cancelled")
                self._emit_locked("validating")
            self._validator(value)
            with self._condition:
                if self._cancelled.is_set():
                    raise CollectionCancelled("query cancelled")
                self.result = value
                self._emit_locked("complete")
            self._release(self)
        except UserActionRequired:
            release = False
            with self._condition:
                if self._cancelled.is_set():
                    release = self._finish_error_locked(
                        "cancelled",
                        "cancelled",
                        "Query cancelled",
                    )
                elif self.phase not in TERMINAL_PHASES:
                    self._emit_locked("needs_user_login")
            if release:
                self._release(self)
        except CollectionCancelled:
            self._finish_error("cancelled", "cancelled", "Query cancelled")
        except QueryResultValidationError:
            self._finish_error(
                "failed",
                "result_validation_failed",
                "Query result failed validation",
            )
        except AccountMismatch:
            self._finish_error(
                "failed",
                "account_mismatch",
                "Authenticated school account did not match",
            )
        except Exception:
            self._finish_error("failed", "query_failed", "Query execution failed")
        finally:
            credentials = None

    def _finish_error(self, phase: str, code: str, message: str) -> None:
        with self._condition:
            release = self._finish_error_locked(phase, code, message)
        if release:
            self._release(self)

    def _finish_error_locked(
        self, phase: str, code: str, message: str
    ) -> bool:
        if self.phase in TERMINAL_PHASES:
            return False
        self.result = None
        self.error = {"code": code, "message": message}
        self._emit_locked(phase)
        return True

    def cancel(self) -> None:
        release = False
        with self._condition:
            if self.phase in TERMINAL_PHASES:
                raise InvalidQueryJobState("job is already terminal")
            self._cancelled.set()
            if self.phase in PAUSE_PHASES:
                release = self._finish_error_locked(
                    "cancelled",
                    "cancelled",
                    "Query cancelled",
                )
        if release:
            self._release(self)

    def wait_for_terminal_or_pause(self, timeout: float = 3) -> str:
        with self._condition:
            self._condition.wait_for(
                lambda: self.phase in TERMINAL_PHASES | PAUSE_PHASES,
                timeout=timeout,
            )
            return self.phase

    def events_after(
        self, sequence: int, *, wait_timeout: float = 0
    ) -> dict[str, Any]:
        with self._condition:
            self._condition.wait_for(
                lambda: self._events[-1]["sequence"] > sequence
                or self.phase in TERMINAL_PHASES,
                timeout=max(wait_timeout, 0),
            )
            events = [
                dict(event)
                for event in self._events
                if event["sequence"] > sequence
            ]
            terminal = self.phase in TERMINAL_PHASES
            return {
                "events": events,
                "nextSequence": self._events[-1]["sequence"],
                "terminal": terminal,
                "result": self.result if self.phase == "complete" else None,
                "error": self.error if terminal and self.error else None,
            }


def _run_young_enrolment(
    request: YoungEnrolmentQuery,
    *,
    interactive: bool,
    credentials: LoginCredentials,
    cancel_check: Callable[[], bool],
    query_fn: Callable[..., Any],
) -> dict[str, Any]:
    normalized, _raw = query_fn(
        account_id=request.account_id,
        allow_interactive_login=interactive,
        credentials=credentials,
        cancel_check=cancel_check,
        status=lambda message: None,
    )
    from ustc_assistant.sources.young.enrolment import build_young_query_result

    return build_young_query_result(normalized)


def _run_icourse(
    request: IcourseQuery,
    *,
    interactive: bool,
    credentials: Any,
    cancel_check: Callable[[], bool],
    query_fn: Callable[..., Any],
) -> dict[str, Any]:
    # Public iCourse queries never receive credentials or account identity.
    return query_fn(
        course=request.course,
        teachers=request.teachers,
        preferences=request.preferences,
    )


def _run_campus_search(
    request: CampusSearchQuery,
    *,
    interactive: bool,
    credentials: Any,
    cancel_check: Callable[[], bool],
    query_fn: Callable[..., Any],
) -> dict[str, Any]:
    raw = query_fn(
        query=request.query,
        filters=request.filters,
        limit=request.limit,
    )
    return _wrap_campus_search(raw)


def _run_campus_detail(
    request: CampusDetailQuery,
    *,
    interactive: bool,
    credentials: Any,
    cancel_check: Callable[[], bool],
    query_fn: Callable[..., Any],
) -> dict[str, Any]:
    raw = query_fn(
        entry_id=request.entry_id,
        allow_stale=True,
        follow_link_ids=request.follow_link_ids,
    )
    return _wrap_campus_detail(raw)


class ReadQueryJobManager:
    def __init__(
        self,
        *,
        young_enrolment_query: Callable[..., Any] | None = None,
        icourse_query: Callable[..., Any] | None = None,
        campus_search_query: Callable[..., Any] | None = None,
        campus_detail_query: Callable[..., Any] | None = None,
        validator: Callable[[Mapping[str, Any]], None] = validate_query_result,
    ) -> None:
        # Default to the real Task 7 query functions lazily to avoid importing
        # optional source dependencies (e.g. playwright) at module import time.
        self._young_enrolment_query = young_enrolment_query
        self._icourse_query = icourse_query
        self._campus_search_query = campus_search_query
        self._campus_detail_query = campus_detail_query
        self._validator = validator
        self._lock = threading.Lock()
        self._jobs: dict[str, ReadQueryJob] = {}
        self._active: ReadQueryJob | None = None

    @property
    def active_jobs(self) -> int:
        with self._lock:
            return int(self._active is not None)

    def _resolve_young_query(self) -> Callable[..., Any]:
        if self._young_enrolment_query is not None:
            return self._young_enrolment_query
        from ustc_assistant.sources.young.enrolment import (
            collect_enrolment_snapshot,
        )

        return collect_enrolment_snapshot

    def _resolve_icourse_query(self) -> Callable[..., Any]:
        if self._icourse_query is not None:
            return self._icourse_query
        from ustc_assistant.sources.icourse.query import query_course_public

        return query_course_public

    def _resolve_campus_search_query(self) -> Callable[..., Any]:
        if self._campus_search_query is not None:
            return self._campus_search_query
        from ustc_assistant.sources.campus.service import search_catalog

        return search_catalog

    def _resolve_campus_detail_query(self) -> Callable[..., Any]:
        if self._campus_detail_query is not None:
            return self._campus_detail_query
        from ustc_assistant.sources.campus.service import read_detail

        return read_detail

    def _start(
        self,
        request: Any,
        *,
        query_type: str,
        runner: Callable[..., Any],
        can_login: bool,
    ) -> ReadQueryJob:
        with self._lock:
            if self._active is not None:
                raise BridgeQueryBusy(
                    "another query job is already running"
                )
            job = ReadQueryJob(
                request=request,
                query_type=query_type,
                runner=runner,
                validator=self._validator,
                release=self._release,
            )
            self._jobs[job.id] = job
            self._active = job
        if can_login:
            job.start(
                interactive=False,
                credentials=LoginCredentials(request.expected_username),
            )
        else:
            job.start(interactive=False, credentials=None)
        return job

    def start_young_enrolment(
        self,
        request: YoungEnrolmentQuery,
        *,
        query_fn: Callable[..., Any] | None = None,
    ) -> ReadQueryJob:
        resolved = query_fn or self._resolve_young_query()

        def runner(
            req: YoungEnrolmentQuery,
            *,
            interactive: bool,
            credentials: LoginCredentials,
            cancel_check: Callable[[], bool],
        ) -> dict[str, Any]:
            return _run_young_enrolment(
                req,
                interactive=interactive,
                credentials=credentials,
                cancel_check=cancel_check,
                query_fn=resolved,
            )

        return self._start(
            request,
            query_type=YOUNG_ENROLMENT,
            runner=runner,
            can_login=True,
        )

    def start_icourse(
        self,
        request: IcourseQuery,
        *,
        query_fn: Callable[..., Any] | None = None,
    ) -> ReadQueryJob:
        resolved = query_fn or self._resolve_icourse_query()

        def runner(
            req: IcourseQuery,
            *,
            interactive: bool,
            credentials: Any,
            cancel_check: Callable[[], bool],
        ) -> dict[str, Any]:
            return _run_icourse(
                req,
                interactive=interactive,
                credentials=credentials,
                cancel_check=cancel_check,
                query_fn=resolved,
            )

        return self._start(
            request,
            query_type=ICOURSE,
            runner=runner,
            can_login=False,
        )

    def start_campus_search(
        self,
        request: CampusSearchQuery,
        *,
        query_fn: Callable[..., Any] | None = None,
    ) -> ReadQueryJob:
        resolved = query_fn or self._resolve_campus_search_query()

        def runner(
            req: CampusSearchQuery,
            *,
            interactive: bool,
            credentials: Any,
            cancel_check: Callable[[], bool],
        ) -> dict[str, Any]:
            return _run_campus_search(
                req,
                interactive=interactive,
                credentials=credentials,
                cancel_check=cancel_check,
                query_fn=resolved,
            )

        return self._start(
            request,
            query_type=CAMPUS_SEARCH,
            runner=runner,
            can_login=False,
        )

    def start_campus_detail(
        self,
        request: CampusDetailQuery,
        *,
        query_fn: Callable[..., Any] | None = None,
    ) -> ReadQueryJob:
        resolved = query_fn or self._resolve_campus_detail_query()

        def runner(
            req: CampusDetailQuery,
            *,
            interactive: bool,
            credentials: Any,
            cancel_check: Callable[[], bool],
        ) -> dict[str, Any]:
            return _run_campus_detail(
                req,
                interactive=interactive,
                credentials=credentials,
                cancel_check=cancel_check,
                query_fn=resolved,
            )

        return self._start(
            request,
            query_type=CAMPUS_DETAIL,
            runner=runner,
            can_login=False,
        )

    def get(self, job_id: str) -> ReadQueryJob:
        with self._lock:
            try:
                return self._jobs[job_id]
            except KeyError:
                raise QueryJobNotFound("query job was not found") from None

    def resume_login(
        self, job_id: str, *, credentials: LoginCredentials
    ) -> ReadQueryJob:
        job = self.get(job_id)
        if job.query_type != YOUNG_ENROLMENT:
            raise InvalidQueryJobState("only young_enrolment can resume login")
        job.resume_login(credentials=credentials)
        return job

    def cancel(self, job_id: str) -> ReadQueryJob:
        job = self.get(job_id)
        job.cancel()
        return job

    def _release(self, job: ReadQueryJob) -> None:
        with self._lock:
            if self._active is job:
                self._active = None
