"""Sequential, resumable source collection jobs."""

from __future__ import annotations

import threading
from dataclasses import dataclass
from datetime import date
from typing import Any, Callable
from uuid import uuid4

from ustc_assistant.common.auth import (
    AccountMismatch,
    CollectionCancelled,
    LoginCredentials,
    UserActionRequired,
)
from ustc_assistant.config import JwSemesterConfig
from ustc_assistant.contracts import validate_source_bundle
from ustc_assistant.sources.jw import service as jw_service
from ustc_assistant.sources.young import source_bundle as young_service


TERMINAL_PHASES = frozenset({"complete", "cancelled", "failed"})
PAUSE_PHASES = frozenset({"needs_user_login"})


class BridgeBusy(RuntimeError):
    code = "bridge_busy"


class JobNotFound(LookupError):
    code = "job_not_found"


class InvalidJobState(RuntimeError):
    code = "invalid_job_state"


@dataclass(frozen=True)
class JwCollectionRequest:
    account_id: str
    expected_username: str
    semester: JwSemesterConfig


@dataclass(frozen=True)
class YoungCollectionRequest:
    account_id: str
    expected_username: str
    today: date | None = None


class CollectionJob:
    def __init__(
        self,
        *,
        request: JwCollectionRequest | YoungCollectionRequest,
        source: str,
        collector: Callable[..., Any],
        release: Callable[["CollectionJob"], None],
    ) -> None:
        self.id = str(uuid4())
        self.request = request
        self.source = source
        self.collector = collector
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
            self.phase = phase
            event: dict[str, Any] = {
                "sequence": len(self._events) + 1,
                "phase": phase,
            }
            if safe_count is not None:
                event["safeCount"] = safe_count
            self._events.append(event)
            self._condition.notify_all()

    def start(self, *, interactive: bool, credentials: LoginCredentials) -> None:
        self._emit("waiting_for_user" if interactive else "checking_session")
        thread = threading.Thread(
            target=self._run,
            kwargs={
                "interactive": interactive,
                "credentials": credentials,
            },
            daemon=True,
        )
        thread.start()

    def _collector_kwargs(
        self, *, interactive: bool, credentials: LoginCredentials
    ) -> dict[str, Any]:
        common = {
            "account_id": self.request.account_id,
            "allow_interactive_login": interactive,
            "credentials": credentials,
            "cancel_check": self._cancelled.is_set,
            "status": lambda message: self._status(),
        }
        if isinstance(self.request, JwCollectionRequest):
            return {**common, "semester": self.request.semester}
        return {**common, "today": self.request.today}

    def _status(self) -> None:
        if self.phase != "collecting":
            self._emit("collecting", safe_count=0)

    def _run(
        self, *, interactive: bool, credentials: LoginCredentials
    ) -> None:
        try:
            value = self.collector(
                **self._collector_kwargs(
                    interactive=interactive,
                    credentials=credentials,
                )
            )
            self._emit("normalizing")
            bundle = value[0] if isinstance(value, tuple) else value
            validate_source_bundle(bundle)
            if self._cancelled.is_set():
                raise CollectionCancelled("collection cancelled")
            with self._condition:
                self.result = bundle
            self._emit("complete")
            self._release(self)
        except UserActionRequired:
            self._emit("needs_user_login")
        except CollectionCancelled:
            self._finish_error("cancelled", "cancelled", "Collection cancelled")
        except AccountMismatch:
            self._finish_error(
                "failed",
                "account_mismatch",
                "Authenticated school account did not match",
            )
        except Exception:
            self._finish_error(
                "failed", "collection_failed", "Source collection failed"
            )
        finally:
            credentials = None

    def _finish_error(self, phase: str, code: str, message: str) -> None:
        with self._condition:
            self.result = None
            self.error = {"code": code, "message": message}
        self._emit(phase)
        self._release(self)

    def cancel(self) -> None:
        if self.phase in TERMINAL_PHASES:
            raise InvalidJobState("job is already terminal")
        self._cancelled.set()
        if self.phase in PAUSE_PHASES:
            self._finish_error(
                "cancelled", "cancelled", "Collection cancelled"
            )

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


class JobManager:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._jobs: dict[str, CollectionJob] = {}
        self._active: CollectionJob | None = None

    @property
    def active_jobs(self) -> int:
        with self._lock:
            return int(self._active is not None)

    def _start(
        self,
        request: JwCollectionRequest | YoungCollectionRequest,
        *,
        source: str,
        collector: Callable[..., Any],
    ) -> CollectionJob:
        with self._lock:
            if self._active is not None:
                raise BridgeBusy("another collection job owns the browser profile")
            job = CollectionJob(
                request=request,
                source=source,
                collector=collector,
                release=self._release,
            )
            self._jobs[job.id] = job
            self._active = job
        job.start(
            interactive=False,
            credentials=LoginCredentials(request.expected_username),
        )
        return job

    def start_jw(
        self,
        request: JwCollectionRequest,
        *,
        collector: Callable[..., Any] = jw_service.collect_jw_source_bundle,
    ) -> CollectionJob:
        return self._start(request, source="ustc_jw", collector=collector)

    def start_young_schedule(
        self,
        request: YoungCollectionRequest,
        *,
        collector: Callable[..., Any] = (
            young_service.collect_young_schedule_source_bundle
        ),
    ) -> CollectionJob:
        return self._start(
            request,
            source="ustc_young_my_schedule",
            collector=collector,
        )

    def get(self, job_id: str) -> CollectionJob:
        with self._lock:
            try:
                return self._jobs[job_id]
            except KeyError:
                raise JobNotFound("collection job was not found") from None

    def resume_login(
        self, job_id: str, *, credentials: LoginCredentials
    ) -> CollectionJob:
        job = self.get(job_id)
        if job.phase != "needs_user_login":
            raise InvalidJobState("job is not waiting for login")
        if (
            credentials.username.casefold()
            != job.request.expected_username.casefold()
        ):
            raise AccountMismatch("resume account did not match")
        job.start(interactive=True, credentials=credentials)
        return job

    def cancel(self, job_id: str) -> CollectionJob:
        job = self.get(job_id)
        job.cancel()
        return job

    def _release(self, job: CollectionJob) -> None:
        with self._lock:
            if self._active is job:
                self._active = None
