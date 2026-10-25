"""Pure value models for the pre-build verification experiments.

``SourceIdentity.scope`` is a stable external-identity namespace, such as a
term. It is not a moving query-time window; query coverage belongs to a
separate transaction-layer concept and never participates in ``stable_key``.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
import re
from typing import Literal


class ModelValidationError(ValueError):
    """Base class for stable, input-safe model validation failures."""


class IncompleteSnapshot(ModelValidationError):
    """Raised when a source snapshot is not explicitly complete."""


class InvalidSnapshot(ModelValidationError):
    """Raised when a complete snapshot has an invalid shape or identity."""


class InvalidRecord(ModelValidationError):
    """Raised when a source record is malformed or duplicated."""


class InvalidTime(ModelValidationError):
    """Raised when a time is not strict Beijing local ISO time."""


class InvalidOverlay(ModelValidationError):
    """Raised when user-owned overlay values are invalid."""


class InvalidPresence(ModelValidationError):
    """Raised when a projection presence value is unsupported."""


class InvalidRecurrence(ModelValidationError):
    """Raised when a recurrence specification is invalid."""


class InvalidException(ModelValidationError):
    """Raised when a recurrence exception is invalid."""


_BEIJING_TIME_PATTERN = re.compile(
    r"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+08:00\Z"
)
_ALLOWED_SOURCE_STATUSES = ("active", "cancelled")
_ALLOWED_PRESENCE = ("observed", "missing_unconfirmed")


def _require_nonempty_string(value: object, *, field: str, error_type: type[ModelValidationError]) -> str:
    if not isinstance(value, str) or not value.strip():
        raise error_type(f"{field} must be a non-empty string")
    return value


def _parse_beijing_time(value: object) -> datetime:
    if not isinstance(value, str) or _BEIJING_TIME_PATTERN.fullmatch(value) is None:
        raise InvalidTime("time must use YYYY-MM-DDTHH:MM:SS+08:00")
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        raise InvalidTime("time must be a valid Beijing local time") from None
    if parsed.utcoffset() != timedelta(hours=8):
        raise InvalidTime("time must use the +08:00 offset")
    return parsed


def _validate_interval(start: object, end: object) -> tuple[str, str, datetime, datetime]:
    start_dt = _parse_beijing_time(start)
    end_dt = _parse_beijing_time(end)
    if end_dt <= start_dt:
        raise InvalidTime("end must be later than start")
    # The parser has established that both values are strings.
    return start, end, start_dt, end_dt  # type: ignore[return-value]


@dataclass(frozen=True, slots=True)
class SourceIdentity:
    """Stable source identity; query coverage dates do not belong here."""

    account_id: str
    source: str
    scope: str
    external_id: str

    def __post_init__(self) -> None:
        for name in ("account_id", "source", "scope", "external_id"):
            _require_nonempty_string(
                getattr(self, name), field=name, error_type=InvalidSnapshot
            )

    def stable_key(self) -> tuple[str, str, str, str]:
        return (self.account_id, self.source, self.scope, self.external_id)


@dataclass(frozen=True, slots=True)
class FrozenSourceRecord:
    """A detached source record with its fully qualified source identity."""

    identity: SourceIdentity
    title: str
    start: str
    end: str
    source_status: Literal["active", "cancelled"] = "active"

    def __post_init__(self) -> None:
        if not isinstance(self.identity, SourceIdentity):
            raise InvalidRecord("identity must be a SourceIdentity")
        _require_nonempty_string(self.title, field="title", error_type=InvalidRecord)
        _validate_interval(self.start, self.end)
        if self.source_status not in _ALLOWED_SOURCE_STATUSES:
            raise InvalidRecord("source_status must be active or cancelled")

    @property
    def external_id(self) -> str:
        return self.identity.external_id


@dataclass(frozen=True, slots=True)
class ParsedSnapshot:
    contract: str
    account_id: str
    source: str
    scope: str
    records: tuple[FrozenSourceRecord, ...]

    def __post_init__(self) -> None:
        for name in ("contract", "account_id", "source", "scope"):
            _require_nonempty_string(
                getattr(self, name), field=name, error_type=InvalidSnapshot
            )
        if not isinstance(self.records, tuple) or any(
            not isinstance(record, FrozenSourceRecord) for record in self.records
        ):
            raise InvalidSnapshot("records must be a tuple of FrozenSourceRecord")
        expected_prefix = (self.account_id, self.source, self.scope)
        if any(record.identity.stable_key()[:3] != expected_prefix for record in self.records):
            raise InvalidSnapshot("record identity must match snapshot identity")


def parse_snapshot(snapshot: dict) -> ParsedSnapshot:
    """Parse a complete snapshot, discarding unknown fields and input containers."""
    if not isinstance(snapshot, dict):
        raise InvalidSnapshot("snapshot must be a dict")

    # Completeness is deliberately checked before touching contract or records.
    if snapshot.get("complete") is not True:
        raise IncompleteSnapshot("snapshot must be explicitly complete")

    contract = _require_nonempty_string(
        snapshot.get("contract"), field="contract", error_type=InvalidSnapshot
    )
    account_id = _require_nonempty_string(
        snapshot.get("account_id"), field="account_id", error_type=InvalidSnapshot
    )
    source = _require_nonempty_string(
        snapshot.get("source"), field="source", error_type=InvalidSnapshot
    )
    scope = _require_nonempty_string(
        snapshot.get("scope"), field="scope", error_type=InvalidSnapshot
    )
    raw_records = snapshot.get("records")
    if not isinstance(raw_records, list):
        raise InvalidSnapshot("records must be a list")

    records: list[FrozenSourceRecord] = []
    seen_external_ids: set[str] = set()
    for raw_record in raw_records:
        if not isinstance(raw_record, dict):
            raise InvalidRecord("each record must be a dict")
        external_id = _require_nonempty_string(
            raw_record.get("external_id"), field="external_id", error_type=InvalidRecord
        )
        title = _require_nonempty_string(
            raw_record.get("title"), field="title", error_type=InvalidRecord
        )
        if external_id in seen_external_ids:
            raise InvalidRecord("duplicate external_id")
        seen_external_ids.add(external_id)

        start, end, _, _ = _validate_interval(raw_record.get("start"), raw_record.get("end"))
        source_status = raw_record.get("source_status", "active")
        if source_status not in _ALLOWED_SOURCE_STATUSES:
            raise InvalidRecord("source_status must be active or cancelled")
        identity = SourceIdentity(account_id, source, scope, external_id)
        records.append(
            FrozenSourceRecord(
                identity=identity,
                title=title,
                start=start,
                end=end,
                source_status=source_status,
            )
        )

    return ParsedSnapshot(
        contract=contract,
        account_id=account_id,
        source=source,
        scope=scope,
        records=tuple(records),
    )


@dataclass(frozen=True, slots=True)
class Overlay:
    user_title: str | None = None
    user_start: str | None = None
    user_end: str | None = None
    user_note: str = ""
    hidden: bool = False

    def __post_init__(self) -> None:
        if self.user_title is not None:
            _require_nonempty_string(
                self.user_title, field="user_title", error_type=InvalidOverlay
            )
        if (self.user_start is None) != (self.user_end is None):
            raise InvalidOverlay("user_start and user_end must be supplied together")
        if self.user_start is not None:
            _validate_interval(self.user_start, self.user_end)
        if not isinstance(self.user_note, str):
            raise InvalidOverlay("user_note must be a string")
        if not isinstance(self.hidden, bool):
            raise InvalidOverlay("hidden must be a bool")


@dataclass(frozen=True, slots=True)
class Projection:
    identity: SourceIdentity
    title: str
    start: str
    end: str
    note: str
    hidden: bool
    source_status: Literal["active", "cancelled"]
    presence: Literal["observed", "missing_unconfirmed"]


def project(
    record: FrozenSourceRecord,
    overlay: Overlay,
    presence: Literal["observed", "missing_unconfirmed"],
) -> Projection:
    if not isinstance(record, FrozenSourceRecord):
        raise InvalidRecord("record must be a FrozenSourceRecord")
    if not isinstance(overlay, Overlay):
        raise InvalidOverlay("overlay must be an Overlay")
    if presence not in _ALLOWED_PRESENCE:
        raise InvalidPresence("presence must be observed or missing_unconfirmed")

    title = overlay.user_title if overlay.user_title is not None else record.title
    if overlay.user_start is None:
        start, end = record.start, record.end
    else:
        start, end = overlay.user_start, overlay.user_end
    return Projection(
        identity=record.identity,
        title=title,
        start=start,
        end=end,
        note=overlay.user_note,
        hidden=overlay.hidden,
        source_status=record.source_status,
        presence=presence,
    )


@dataclass(frozen=True, slots=True)
class RecurrenceSpec:
    local_series_id: str
    start: str
    end: str
    frequency: Literal["daily", "weekly"]
    interval: int
    count: int

    def __post_init__(self) -> None:
        _require_nonempty_string(
            self.local_series_id, field="local_series_id", error_type=InvalidRecurrence
        )
        _, _, start_dt, end_dt = _validate_interval(self.start, self.end)
        if end_dt <= start_dt:
            raise InvalidRecurrence("end must be later than start")
        if self.frequency not in ("daily", "weekly"):
            raise InvalidRecurrence("frequency must be daily or weekly")
        if isinstance(self.interval, bool) or not isinstance(self.interval, int):
            raise InvalidRecurrence("interval must be an integer")
        if not 1 <= self.interval <= 366:
            raise InvalidRecurrence("interval must be between 1 and 366")
        if isinstance(self.count, bool) or not isinstance(self.count, int):
            raise InvalidRecurrence("count must be an integer")
        if not 1 <= self.count <= 1000:
            raise InvalidRecurrence("count must be between 1 and 1000")


@dataclass(frozen=True, slots=True)
class Occurrence:
    key: tuple[str, int]
    original_start: str
    start: str
    end: str
    state: Literal["observed", "skipped"]


def _validated_exceptions(
    exceptions: dict, count: int
) -> dict[int, tuple[str, str | None, str | None]]:
    if not isinstance(exceptions, dict):
        raise InvalidException("exceptions must be a dict")
    validated: dict[int, tuple[str, str | None, str | None]] = {}
    for ordinal, exception in exceptions.items():
        if isinstance(ordinal, bool) or not isinstance(ordinal, int):
            raise InvalidException("exception ordinal must be an integer")
        if not 0 <= ordinal < count:
            raise InvalidException("exception ordinal is outside the series")
        if not isinstance(exception, dict):
            raise InvalidException("each exception must be a dict")
        kind = exception.get("kind")
        if kind == "skip":
            if set(exception) != {"kind"}:
                raise InvalidException("skip exception only accepts kind")
            validated[ordinal] = ("skip", None, None)
        elif kind == "move":
            if set(exception) != {"kind", "start", "end"}:
                raise InvalidException("move exception requires start and end")
            start, end, _, _ = _validate_interval(exception.get("start"), exception.get("end"))
            validated[ordinal] = ("move", start, end)
        else:
            raise InvalidException("exception kind must be skip or move")
    return validated


def enumerate_occurrences(
    spec: RecurrenceSpec,
    exceptions: dict | None = None,
) -> tuple[Occurrence, ...]:
    if not isinstance(spec, RecurrenceSpec):
        raise InvalidRecurrence("spec must be a RecurrenceSpec")
    if exceptions is None:
        exceptions = {}
    validated = _validated_exceptions(exceptions, spec.count)
    _, _, anchor_start, anchor_end = _validate_interval(spec.start, spec.end)
    step_days = spec.interval * (1 if spec.frequency == "daily" else 7)
    duration = anchor_end - anchor_start

    result: list[Occurrence] = []
    for ordinal in range(spec.count):
        try:
            original_start_dt = anchor_start + timedelta(days=step_days * ordinal)
            original_end_dt = original_start_dt + duration
        except OverflowError:
            raise InvalidRecurrence("occurrence exceeds supported datetime range") from None
        original_start = original_start_dt.isoformat(timespec="seconds")
        original_end = original_end_dt.isoformat(timespec="seconds")

        state: Literal["observed", "skipped"] = "observed"
        actual_start, actual_end = original_start, original_end
        exception = validated.get(ordinal)
        if exception is not None:
            kind, moved_start, moved_end = exception
            if kind == "skip":
                state = "skipped"
            else:
                # The pair was validated before enumeration.
                actual_start = moved_start  # type: ignore[assignment]
                actual_end = moved_end  # type: ignore[assignment]
        result.append(
            Occurrence(
                key=(spec.local_series_id, ordinal),
                original_start=original_start,
                start=actual_start,
                end=actual_end,
                state=state,
            )
        )
    return tuple(result)


__all__ = [
    "FrozenSourceRecord",
    "IncompleteSnapshot",
    "InvalidException",
    "InvalidOverlay",
    "InvalidPresence",
    "InvalidRecord",
    "InvalidRecurrence",
    "InvalidSnapshot",
    "InvalidTime",
    "ModelValidationError",
    "Occurrence",
    "Overlay",
    "ParsedSnapshot",
    "Projection",
    "RecurrenceSpec",
    "SourceIdentity",
    "enumerate_occurrences",
    "parse_snapshot",
    "project",
]
