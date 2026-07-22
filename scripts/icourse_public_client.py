#!/usr/bin/env python3
"""Read public USTC iCourse pages with conservative caching and pacing."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
import time
from dataclasses import dataclass, replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable

import requests

import icourse_public_parser as page_parser


BASE_URL = "https://icourse.club"
CACHE_SCHEMA_VERSION = "1.0"
DEFAULT_USER_AGENT = "USTC-Assistant-Prototype/0.1 (public read-only course lookup)"


class IcourseNetworkError(RuntimeError):
    """A public page could not be fetched."""


class IcourseRateLimitError(IcourseNetworkError):
    """The site asked the client to slow down."""


@dataclass(frozen=True)
class CacheResult:
    data: dict[str, Any]
    fetched_at: datetime
    stale: bool = False


class JsonPageCache:
    def __init__(
        self,
        root: Path,
        *,
        ttl: timedelta = timedelta(hours=24),
        schema_version: str = CACHE_SCHEMA_VERSION,
    ) -> None:
        self.root = Path(root)
        self.ttl = ttl
        self.schema_version = schema_version

    def _path(self, url: str) -> Path:
        digest = hashlib.sha256(page_parser.canonicalize_source_url(url).encode("utf-8")).hexdigest()
        return self.root / f"{digest}.json"

    def load(self, url: str) -> CacheResult | None:
        path = self._path(url)
        if not path.exists():
            return None
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            if payload.get("schemaVersion") != self.schema_version:
                return None
            if payload.get("sourceUrl") != page_parser.canonicalize_source_url(url):
                return None
            fetched_at = datetime.fromisoformat(payload["fetchedAt"])
            data = payload["data"]
            if not isinstance(data, dict):
                return None
            return CacheResult(data=data, fetched_at=fetched_at)
        except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
            return None

    def store(self, url: str, data: dict[str, Any], *, fetched_at: datetime) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        path = self._path(url)
        payload = {
            "schemaVersion": self.schema_version,
            "sourceUrl": page_parser.canonicalize_source_url(url),
            "fetchedAt": fetched_at.isoformat(),
            "data": data,
        }
        handle, temporary_name = tempfile.mkstemp(prefix=path.stem + ".", suffix=".tmp", dir=self.root)
        try:
            with os.fdopen(handle, "w", encoding="utf-8", newline="\n") as file:
                json.dump(payload, file, ensure_ascii=False, indent=2)
                file.write("\n")
            os.replace(temporary_name, path)
        except Exception:
            try:
                os.unlink(temporary_name)
            except OSError:
                pass
            raise

    def get_or_fetch(
        self,
        url: str,
        fetch: Callable[[str], str],
        parse: Callable[[str, str], dict[str, Any]],
        *,
        now: datetime | None = None,
    ) -> CacheResult:
        checked_at = now or datetime.now(timezone.utc)
        cached = self.load(url)
        if cached and checked_at - cached.fetched_at < self.ttl:
            return cached
        try:
            parsed = parse(fetch(url), url)
        except IcourseNetworkError:
            if cached:
                return replace(cached, stale=True)
            raise
        self.store(url, parsed, fetched_at=checked_at)
        return CacheResult(data=parsed, fetched_at=checked_at)


class PublicIcourseClient:
    def __init__(
        self,
        *,
        session: Any | None = None,
        cache: JsonPageCache | None = None,
        sleep: Callable[[float], None] = time.sleep,
        timeout_seconds: float = 20,
        min_interval_seconds: float = 1,
    ) -> None:
        self.session = session or requests.Session()
        self.cache = cache
        self.sleep = sleep
        self.timeout_seconds = timeout_seconds
        self.min_interval_seconds = min_interval_seconds
        self._last_request_at: float | None = None
        self.headers = {"User-Agent": DEFAULT_USER_AGENT, "Accept": "text/html,application/json"}

    def _pace(self) -> None:
        now = time.monotonic()
        if self._last_request_at is not None:
            remaining = self.min_interval_seconds - (now - self._last_request_at)
            if remaining > 0:
                self.sleep(remaining)
        self._last_request_at = time.monotonic()

    def _post(self, path: str):
        self._pace()
        try:
            return self.session.post(
                BASE_URL + path,
                headers=self.headers,
                timeout=self.timeout_seconds,
            )
        except requests.RequestException as exc:
            raise IcourseNetworkError("public iCourse request failed") from exc

    def _get(self, url: str, *, params: dict[str, str] | None = None):
        self._pace()
        try:
            response = self.session.get(
                urljoin_public(url),
                params=params,
                headers=self.headers,
                timeout=self.timeout_seconds,
            )
        except requests.RequestException as exc:
            raise IcourseNetworkError("public iCourse request failed") from exc
        if response.status_code == 429:
            retry_after = response.headers.get("Retry-After", "unknown")
            raise IcourseRateLimitError(f"public iCourse rate limit; Retry-After={retry_after}")
        if response.status_code >= 400:
            raise IcourseNetworkError(f"public iCourse returned HTTP {response.status_code}")
        return response

    def _search_token(self) -> str:
        response = self._post("/api/search/token")
        if response.status_code >= 400:
            raise IcourseNetworkError(f"search token returned HTTP {response.status_code}")
        try:
            payload = response.json()
        except (ValueError, TypeError) as exc:
            raise IcourseNetworkError("search token response was not JSON") from exc
        token = payload.get("token") if isinstance(payload, dict) and payload.get("ok") else None
        if not isinstance(token, str) or not token:
            raise IcourseNetworkError("search token response was invalid")
        return token

    def search(self, query: str) -> list[dict[str, Any]]:
        for attempt in range(2):
            token = self._search_token()
            self._pace()
            try:
                response = self.session.get(
                    BASE_URL + "/search/",
                    params={"q": query, "token": token},
                    headers=self.headers,
                    timeout=self.timeout_seconds,
                )
            except requests.RequestException as exc:
                raise IcourseNetworkError("public iCourse search failed") from exc
            if response.status_code == 403 and attempt == 0:
                continue
            if response.status_code == 429:
                retry_after = response.headers.get("Retry-After", "unknown")
                raise IcourseRateLimitError(f"public iCourse rate limit; Retry-After={retry_after}")
            if response.status_code >= 400:
                raise IcourseNetworkError(f"public iCourse search returned HTTP {response.status_code}")
            return page_parser.parse_search_results(response.text)
        raise IcourseNetworkError("public iCourse search token was rejected twice")

    def _page(self, url: str, parse: Callable[[str, str], dict[str, Any]]) -> dict[str, Any]:
        def fetch(target: str) -> str:
            return self._get(target).text

        if self.cache is None:
            return parse(fetch(url), url)
        result = self.cache.get_or_fetch(url, fetch, parse)
        return {
            **result.data,
            "cache": {"fetchedAt": result.fetched_at.isoformat(), "stale": result.stale},
        }

    def get_course(self, url: str) -> dict[str, Any]:
        return self._page(url, page_parser.parse_course_page)

    def get_teacher(self, url: str) -> dict[str, Any]:
        return self._page(url, page_parser.parse_teacher_page)


def urljoin_public(url: str) -> str:
    if url.startswith("http://") or url.startswith("https://"):
        return url
    return BASE_URL + (url if url.startswith("/") else "/" + url)
