"""Local records and persistence for public campus catalog entries."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from dataclasses import asdict, dataclass, replace
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from zoneinfo import ZoneInfo


BEIJING_TZ = ZoneInfo("Asia/Shanghai")
CATALOG_SCHEMA_VERSION = "1.0"
TRACKING_KEYS = {
    "_t",
    "from",
    "spm",
    "utm_campaign",
    "utm_medium",
    "utm_source",
}
SEARCH_FILTERS = {"source", "kind", "status"}


class CampusError(RuntimeError):
    """A campus public-source failure safe to display to the user."""


class CatalogStoreError(CampusError):
    """The local catalog could not be read or committed safely."""


def canonicalize_url(url: str) -> str:
    split = urlsplit(url.strip())
    query = urlencode(
        sorted(
            (key, value)
            for key, value in parse_qsl(split.query, keep_blank_values=True)
            if key.lower() not in TRACKING_KEYS
        )
    )
    return urlunsplit(
        (
            (split.scheme or "https").lower(),
            split.netloc.lower(),
            split.path or "/",
            query,
            "",
        )
    )


def entry_id(source: str, url: str) -> str:
    identity = f"{source}\0{canonicalize_url(url)}"
    digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:24]
    return f"campus_{digest}"


def notice_cutoff(today: date) -> date:
    return today - timedelta(days=6)


def is_monthly_refresh_due(
    last_successful_at: datetime | None,
    now: datetime,
) -> bool:
    if last_successful_at is None:
        return True
    previous = last_successful_at.astimezone(BEIJING_TZ)
    current = now.astimezone(BEIJING_TZ)
    return (previous.year, previous.month) != (current.year, current.month)


@dataclass(frozen=True)
class CatalogEntry:
    id: str
    source: str
    kind: str
    title: str
    category: str | None
    published_at: str | None
    detail_url: str
    discovered_at: str
    last_seen_at: str
    status: str = "active"

    def to_dict(self) -> dict[str, str | None]:
        raw = asdict(self)
        return {
            "id": raw["id"],
            "source": raw["source"],
            "kind": raw["kind"],
            "title": raw["title"],
            "category": raw["category"],
            "publishedAt": raw["published_at"],
            "detailUrl": raw["detail_url"],
            "discoveredAt": raw["discovered_at"],
            "lastSeenAt": raw["last_seen_at"],
            "status": raw["status"],
        }

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> "CatalogEntry":
        try:
            return cls(
                id=str(payload["id"]),
                source=str(payload["source"]),
                kind=str(payload["kind"]),
                title=str(payload["title"]),
                category=(
                    str(payload["category"])
                    if payload.get("category") is not None
                    else None
                ),
                published_at=(
                    str(payload["publishedAt"])
                    if payload.get("publishedAt") is not None
                    else None
                ),
                detail_url=str(payload["detailUrl"]),
                discovered_at=str(payload["discoveredAt"]),
                last_seen_at=str(payload["lastSeenAt"]),
                status=str(payload["status"]),
            )
        except (KeyError, TypeError, ValueError) as exc:
            raise CatalogStoreError("campus catalog entry is invalid") from exc


class CatalogStore:
    def __init__(self, path: Path) -> None:
        self.path = Path(path)

    @staticmethod
    def _empty() -> dict[str, Any]:
        return {"schemaVersion": CATALOG_SCHEMA_VERSION, "sources": {}}

    def load(self) -> dict[str, Any]:
        if not self.path.exists():
            return self._empty()
        try:
            payload = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise CatalogStoreError("campus catalog could not be read") from exc
        if (
            not isinstance(payload, dict)
            or payload.get("schemaVersion") != CATALOG_SCHEMA_VERSION
            or not isinstance(payload.get("sources"), dict)
        ):
            raise CatalogStoreError("campus catalog schema is incompatible")
        return payload

    def _write(self, payload: dict[str, Any]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        handle, temporary_name = tempfile.mkstemp(
            prefix=self.path.stem + ".",
            suffix=".tmp",
            dir=self.path.parent,
        )
        try:
            with os.fdopen(handle, "w", encoding="utf-8", newline="\n") as file:
                json.dump(payload, file, ensure_ascii=False, indent=2)
                file.write("\n")
            os.replace(temporary_name, self.path)
        except Exception:
            try:
                os.unlink(temporary_name)
            except OSError:
                pass
            raise

    def _source_entries(
        self,
        payload: dict[str, Any],
        source: str,
    ) -> list[CatalogEntry]:
        state = payload["sources"].get(source)
        if state is None:
            return []
        if not isinstance(state, dict) or not isinstance(state.get("entries"), list):
            raise CatalogStoreError("campus catalog source state is invalid")
        return [CatalogEntry.from_dict(item) for item in state["entries"]]

    def last_successful_at(self, source: str) -> datetime | None:
        state = self.load()["sources"].get(source)
        if state is None:
            return None
        value = state.get("lastSuccessfulAt")
        try:
            return datetime.fromisoformat(value)
        except (TypeError, ValueError) as exc:
            raise CatalogStoreError("campus catalog refresh timestamp is invalid") from exc

    def commit_source(
        self,
        source: str,
        observed: Iterable[CatalogEntry],
        *,
        refreshed_at: datetime,
    ) -> None:
        payload = self.load()
        previous = {entry.id: entry for entry in self._source_entries(payload, source)}
        incoming: dict[str, CatalogEntry] = {}
        for entry in observed:
            if entry.source != source:
                raise CatalogStoreError("campus catalog source does not match entry")
            existing = incoming.get(entry.id)
            if existing is not None and existing != entry:
                raise CatalogStoreError("campus catalog contains a conflicting duplicate")
            incoming[entry.id] = entry

        reconciled: list[CatalogEntry] = []
        for identity, entry in incoming.items():
            old = previous.get(identity)
            reconciled.append(
                replace(
                    entry,
                    discovered_at=old.discovered_at if old else entry.discovered_at,
                    status="active",
                )
            )
        for identity, old in previous.items():
            if identity not in incoming:
                status = "archived" if old.kind == "notice" else "unavailable"
                reconciled.append(replace(old, status=status))

        reconciled.sort(
            key=lambda item: (
                item.published_at or "",
                item.title.casefold(),
                item.id,
            ),
            reverse=True,
        )
        payload["sources"][source] = {
            "lastSuccessfulAt": refreshed_at.isoformat(),
            "entries": [entry.to_dict() for entry in reconciled],
        }
        self._write(payload)

    def get(self, identity: str) -> dict[str, str | None]:
        payload = self.load()
        for source in payload["sources"]:
            for entry in self._source_entries(payload, source):
                if entry.id == identity:
                    return entry.to_dict()
        raise CatalogStoreError("campus catalog entry was not found")

    def search(
        self,
        query: str,
        *,
        filters: dict[str, str] | None = None,
        limit: int = 20,
    ) -> list[dict[str, str | None]]:
        if not 1 <= limit <= 100:
            raise ValueError("campus catalog search limit must be between 1 and 100")
        selected_filters = filters or {}
        unknown = set(selected_filters) - SEARCH_FILTERS
        if unknown:
            raise ValueError("campus catalog search filter is not supported")

        needle = query.strip().casefold()
        matches: list[CatalogEntry] = []
        payload = self.load()
        for source in payload["sources"]:
            for entry in self._source_entries(payload, source):
                values = entry.to_dict()
                if any(values[key] != value for key, value in selected_filters.items()):
                    continue
                haystack = " ".join(
                    value
                    for value in (entry.title, entry.category, entry.source)
                    if value
                ).casefold()
                if needle and needle not in haystack:
                    continue
                matches.append(entry)

        matches.sort(
            key=lambda item: (
                needle in item.title.casefold(),
                item.status == "active",
                item.published_at or "",
                item.last_seen_at,
            ),
            reverse=True,
        )
        return [entry.to_dict() for entry in matches[:limit]]
