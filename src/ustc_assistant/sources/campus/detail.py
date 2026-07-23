"""Bounded public HTTP, detail caching, and ID-controlled campus reads."""

from __future__ import annotations

import hashlib
import ipaddress
import json
import os
import tempfile
from dataclasses import dataclass, replace
from datetime import datetime, timedelta, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Iterable
from urllib.parse import urlsplit

import requests
from bs4 import BeautifulSoup

from ustc_assistant.sources.campus import finance, teach
from ustc_assistant.sources.campus.catalog import (
    CampusError,
    CatalogStore,
    canonicalize_url,
)


PRIMARY_HOSTS = {
    "teach.ustc.edu.cn",
    "www.teach.ustc.edu.cn",
    "finance.ustc.edu.cn",
}
DETAIL_CACHE_SCHEMA_VERSION = "1.0"
DEFAULT_USER_AGENT = "USTC-Assistant-Prototype/0.1 (public campus lookup)"


class UnsafeCampusUrl(CampusError):
    """A URL is outside the bounded public reading policy."""


class CampusNetworkError(CampusError):
    """A public campus resource could not be fetched safely."""


@dataclass(frozen=True)
class DownloadedPayload:
    data: bytes
    media_type: str
    final_url: str


@dataclass(frozen=True)
class DetailCacheResult:
    data: dict[str, Any]
    fetched_at: datetime
    stale: bool = False


def _validate_url(
    url: str,
    *,
    discovered_child: bool,
    allow_primary_http: bool = False,
) -> str:
    split = urlsplit(url.strip())
    if not split.hostname:
        raise UnsafeCampusUrl("campus URL must include a public host")
    if split.username or split.password:
        raise UnsafeCampusUrl("campus URL credentials are not allowed")
    host = split.hostname.lower()
    scheme = split.scheme.lower()
    if scheme != "https" and not (
        allow_primary_http and scheme == "http" and host in PRIMARY_HOSTS
    ):
        raise UnsafeCampusUrl("campus URL must use public HTTPS")
    if host == "localhost" or host.endswith(".local"):
        raise UnsafeCampusUrl("campus URL host is not public")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        address = None
    if address is not None and (
        address.is_private
        or address.is_loopback
        or address.is_link_local
        or address.is_reserved
        or address.is_unspecified
    ):
        raise UnsafeCampusUrl("campus URL host is not public")
    if not discovered_child and host not in PRIMARY_HOSTS:
        raise UnsafeCampusUrl("campus URL host is not configured")
    return canonicalize_url(url)


class CampusHttpClient:
    def __init__(
        self,
        *,
        session: Any | None = None,
        timeout_seconds: float = 20,
        max_response_bytes: int = 5 * 1024 * 1024,
    ) -> None:
        self.session = session or requests.Session()
        if hasattr(self.session, "cookies"):
            self.session.cookies.clear()
        self.timeout_seconds = timeout_seconds
        self.max_response_bytes = max_response_bytes
        self.headers = {
            "User-Agent": DEFAULT_USER_AGENT,
            "Accept": "text/html,text/plain,application/pdf,application/octet-stream",
        }

    def _download(
        self,
        url: str,
        *,
        discovered_child: bool,
    ) -> DownloadedPayload:
        target = _validate_url(url, discovered_child=discovered_child)
        try:
            response = self.session.get(
                target,
                headers=self.headers,
                timeout=self.timeout_seconds,
                stream=True,
                allow_redirects=True,
            )
        except requests.RequestException as exc:
            host = urlsplit(target).hostname or "configured host"
            raise CampusNetworkError(f"campus request to {host} failed") from exc
        try:
            final_url = _validate_url(
                str(response.url),
                discovered_child=discovered_child,
                allow_primary_http=True,
            )
            if response.status_code >= 400:
                host = urlsplit(final_url).hostname or "configured host"
                raise CampusNetworkError(
                    f"campus host {host} returned HTTP {response.status_code}"
                )
            declared = response.headers.get("Content-Length")
            if declared is not None:
                try:
                    if int(declared) > self.max_response_bytes:
                        raise CampusNetworkError(
                            "campus response exceeded the configured size limit"
                        )
                except ValueError:
                    raise CampusNetworkError(
                        "campus response size header was invalid"
                    ) from None
            chunks: list[bytes] = []
            size = 0
            for chunk in response.iter_content(chunk_size=64 * 1024):
                if not chunk:
                    continue
                size += len(chunk)
                if size > self.max_response_bytes:
                    raise CampusNetworkError(
                        "campus response exceeded the configured size limit"
                    )
                chunks.append(chunk)
            media_type = response.headers.get(
                "Content-Type",
                "application/octet-stream",
            ).split(";", 1)[0].strip().lower()
            return DownloadedPayload(b"".join(chunks), media_type, final_url)
        finally:
            response.close()

    def get_bytes(
        self,
        url: str,
        *,
        discovered_child: bool = False,
    ) -> DownloadedPayload:
        return self._download(url, discovered_child=discovered_child)

    def get_text(
        self,
        url: str,
        *,
        discovered_child: bool = False,
    ) -> str:
        payload = self._download(url, discovered_child=discovered_child)
        try:
            return payload.data.decode("utf-8")
        except UnicodeDecodeError:
            return payload.data.decode("gb18030", errors="replace")


class DetailCache:
    def __init__(
        self,
        root: Path,
        *,
        ttl: timedelta = timedelta(days=30),
    ) -> None:
        self.root = Path(root)
        self.ttl = ttl

    def _path(self, item_id: str) -> Path:
        digest = hashlib.sha256(item_id.encode("utf-8")).hexdigest()
        return self.root / f"{digest}.json"

    def load(self, item_id: str) -> DetailCacheResult | None:
        path = self._path(item_id)
        if not path.exists():
            return None
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            if (
                payload.get("schemaVersion") != DETAIL_CACHE_SCHEMA_VERSION
                or payload.get("itemId") != item_id
                or not isinstance(payload.get("data"), dict)
            ):
                return None
            return DetailCacheResult(
                data=payload["data"],
                fetched_at=datetime.fromisoformat(payload["fetchedAt"]),
            )
        except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError):
            return None

    def store(
        self,
        item_id: str,
        data: dict[str, Any],
        *,
        fetched_at: datetime,
    ) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        path = self._path(item_id)
        payload = {
            "schemaVersion": DETAIL_CACHE_SCHEMA_VERSION,
            "itemId": item_id,
            "fetchedAt": fetched_at.isoformat(),
            "data": data,
        }
        handle, temporary_name = tempfile.mkstemp(
            prefix=path.stem + ".",
            suffix=".tmp",
            dir=self.root,
        )
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
        item_id: str,
        fetch: Callable[[], dict[str, Any]],
        *,
        now: datetime,
        allow_stale: bool,
    ) -> DetailCacheResult:
        cached = self.load(item_id)
        if cached and now - cached.fetched_at < self.ttl:
            return cached
        try:
            data = fetch()
        except CampusNetworkError:
            if cached and allow_stale:
                return replace(cached, stale=True)
            raise
        self.store(item_id, data, fetched_at=now)
        return DetailCacheResult(data=data, fetched_at=now)


def _knowledge_id(entry_id: str) -> str:
    digest = hashlib.sha256(entry_id.encode("utf-8")).hexdigest()[:24]
    return f"knowledge_{digest}"


def _content_hash(payload: dict[str, Any]) -> str:
    stable = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(stable.encode("utf-8")).hexdigest()


def _parse_followed_html(html: str, url: str) -> dict[str, Any]:
    soup = BeautifulSoup(html, "html.parser")
    for selector in ("script", "style", "nav", "footer"):
        for node in soup.select(selector):
            node.decompose()
    title_node = soup.find("h1") or soup.find("title")
    content_node = soup.find("main") or soup.find("article") or soup.body
    if title_node is None or content_node is None:
        raise CampusError("followed campus page did not contain readable content")
    return {
        "title": " ".join(title_node.get_text(" ", strip=True).split()),
        "content": " ".join(content_node.get_text(" ", strip=True).split()),
        "url": canonicalize_url(url),
        "depth": 1,
    }


class DetailReader:
    def __init__(
        self,
        *,
        store: CatalogStore,
        client: CampusHttpClient,
        cache_dir: Path,
        now: Callable[[], datetime] | None = None,
    ) -> None:
        self.store = store
        self.client = client
        self.cache_root = Path(cache_dir)
        self.cache = DetailCache(self.cache_root / "details")
        self.now = now or (lambda: datetime.now(timezone.utc))

    def _parser(self, source: str) -> Callable[[str, str], dict[str, Any]]:
        if source.startswith("teach_"):
            return teach.parse_teach_detail
        if source.startswith("finance_"):
            return finance.parse_finance_detail
        raise CampusError("campus detail source is not supported")

    def read_detail(
        self,
        entry_id: str,
        allow_stale: bool = True,
        follow_link_ids: Iterable[str] = (),
    ) -> dict[str, Any]:
        entry = self.store.get(entry_id)
        item_id = _knowledge_id(entry_id)
        checked_at = self.now()

        def fetch() -> dict[str, Any]:
            html = self.client.get_text(str(entry["detailUrl"]))
            parsed = self._parser(str(entry["source"]))(html, str(entry["detailUrl"]))
            base = {
                "id": item_id,
                "catalogEntryId": entry_id,
                "source": entry["source"],
                **parsed,
                "fetchedAt": checked_at.isoformat(),
            }
            base["contentHash"] = _content_hash(base)
            return base

        cached = self.cache.get_or_fetch(
            item_id,
            fetch,
            now=checked_at,
            allow_stale=allow_stale,
        )
        result = {**cached.data, "stale": cached.stale, "followedLinks": []}
        candidates = {
            item["id"]: item
            for item in result.get("candidateLinks", [])
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        }
        requested = tuple(follow_link_ids)
        unknown = [identity for identity in requested if identity not in candidates]
        if unknown:
            raise CampusError("campus candidate link was not found")
        for identity in requested:
            candidate = candidates[identity]
            html = self.client.get_text(
                str(candidate["url"]),
                discovered_child=True,
            )
            result["followedLinks"].append(
                _parse_followed_html(html, str(candidate["url"]))
            )
        return result

    def read_attachment(
        self,
        item_id: str,
        attachment_id: str,
    ) -> dict[str, Any]:
        cached = self.cache.load(item_id)
        if cached is None:
            raise CampusError("campus detail item was not found")
        attachments = {
            item["id"]: item
            for item in cached.data.get("attachments", [])
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        }
        attachment = attachments.get(attachment_id)
        if attachment is None:
            raise CampusError("campus attachment was not found")
        payload = self.client.get_bytes(
            str(attachment["url"]),
            discovered_child=True,
        )
        digest = hashlib.sha256(payload.data).hexdigest()
        suffix = PurePosixPath(urlsplit(payload.final_url).path).suffix.lower()
        path = self.cache_root / "attachments" / f"{digest}{suffix}"
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists():
            handle, temporary_name = tempfile.mkstemp(
                prefix=digest + ".",
                suffix=".tmp",
                dir=path.parent,
            )
            try:
                with os.fdopen(handle, "wb") as file:
                    file.write(payload.data)
                os.replace(temporary_name, path)
            except Exception:
                try:
                    os.unlink(temporary_name)
                except OSError:
                    pass
                raise

        extracted_text: str | None = None
        conversion_status = "binary-saved"
        if payload.media_type.startswith("text/"):
            extracted_text = payload.data.decode("utf-8", errors="replace")
            conversion_status = "text-extracted"
        return {
            "itemId": item_id,
            "attachmentId": attachment_id,
            "url": payload.final_url,
            "mediaType": payload.media_type,
            "sizeBytes": len(payload.data),
            "sha256": digest,
            "localPath": str(path),
            "extractedText": extracted_text,
            "conversionStatus": conversion_status,
        }
