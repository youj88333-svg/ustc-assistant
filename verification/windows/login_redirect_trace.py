"""Manual, privacy-limited school login redirect trace.

The collector records only projected document-navigation metadata. It never
reads response bodies, request headers or browser authentication assets.

Design basis, navigated from docs/README.md: 07 protects credentials and keeps
the first-release browser ordinary and user-operated; 08 separates each source;
09 K-01/K-03 rejects URL parameters as identity and binds actions to documents;
10/11 keep frames distinct and project closed results; 12 keeps diagnostics
private and secret-free; 13 separates real evidence; 15 keeps this in the
existing M2 task and honors the approved shared school-account scope.
"""

from __future__ import annotations

import argparse
import asyncio
import copy
import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Callable
from urllib.parse import unquote, unquote_plus, urlsplit


SCHEMA_KIND = "school-redirect-trace-v1"
MAX_NAVIGATION_EVENTS = 2000
MAX_URL_LENGTH = 8192
MAX_QUERY_ITEMS = 100
DEFAULT_PROXY = "http://127.0.0.1:7897"

ENTRY_URLS = {
    "young": "https://young.ustc.edu.cn/login/",
    "jw": "https://jw.ustc.edu.cn/",
}

# Young's five registered login origins and the four origins observed for JW.
# Matching is exact; subdomains and ports are never copied into the output.
KNOWN_HOSTS = {
    "young": frozenset(
        {
            "young.ustc.edu.cn",
            "passport.ustc.edu.cn",
            "ucas.ustc.edu.cn",
            "id.ustc.edu.cn",
            "analytics.ustc.edu.cn",
        }
    ),
    "jw": frozenset(
        {
            "jw.ustc.edu.cn",
            "passport.ustc.edu.cn",
            "id.ustc.edu.cn",
            "analytics.ustc.edu.cn",
        }
    ),
}

_SAFE_PATH_SEGMENTS = {
    value.lower(): value
    for value in (
        "login",
        "cas",
        "oauth2",
        "authserver",
        "sso",
        "portal",
        "home",
        "main.htm",
        "index.html",
        "ucas-sso",
        ".isg",
        "gateway",
        "sso-init",
        "sc-wisdom-group-learning",
        "myproject",
        "SignUp",
        "personalInformation",
        "mySchedule",
    )
}

_SAFE_QUERY_KEYS = {
    "ticket": "ticket",
    "service": "service",
    "redirect_uri": "redirect_uri",
    "redirect": "redirect",
    "relaystate": "RelayState",
    "code": "code",
    "state": "state",
    "appid": "appId",
    "client_id": "client_id",
    "next": "next",
    "target": "target",
    "url": "url",
    "error": "error",
    "continue": "continue",
}

_FAILURE_CODES = frozenset(
    {
        "playwright_unavailable",
        "browser_launch_failed",
        "context_create_failed",
        "initial_navigation_failed",
        "document_request_failed",
        "event_projection_failed",
        "user_interrupted",
        "browser_close_failed",
        "trace_save_failed",
    }
)

_MISSING = object()


class UrlProjector:
    """Turn a URL into bounded metadata without retaining query values."""

    def __init__(self, source: str):
        if source not in KNOWN_HOSTS:
            raise ValueError("unsupported fixed source")
        self._known_hosts = KNOWN_HOSTS[source]
        self._unknown_origins: dict[str, int] = {}
        self._path_ids: dict[tuple[str, str], int] = {}

    def project(self, raw_url: object) -> dict[str, Any]:
        if not isinstance(raw_url, str) or not raw_url or len(raw_url) > MAX_URL_LENGTH:
            return self._invalid_url()

        try:
            parts = urlsplit(raw_url)
            scheme = parts.scheme.lower()
            hostname = parts.hostname
            if not scheme or (scheme in {"http", "https"} and not hostname):
                return self._invalid_url()
        except (TypeError, ValueError):
            return self._invalid_url()

        if hostname and hostname.lower().rstrip(".") in self._known_hosts:
            origin = f"{scheme if scheme in {'http', 'https'} else 'other'}://{hostname.lower().rstrip('.')}"
        else:
            origin_key = hostname.lower().rstrip(".") if hostname else "(no-host)"
            if origin_key not in self._unknown_origins:
                self._unknown_origins[origin_key] = len(self._unknown_origins) + 1
            origin = f"unknown_origin_{self._unknown_origins[origin_key]}"

        safe_path = self._safe_path(parts.path)
        # Keep raw path identity only in this in-memory map. The exported path
        # stays closed, and distinct private routes get anonymous per-run IDs.
        path_key = (origin, parts.path)
        if path_key not in self._path_ids:
            self._path_ids[path_key] = len(self._path_ids) + 1

        query_keys, unknown_count, query_truncated = self._query_summary(parts.query)
        return {
            "origin": origin,
            "path": safe_path,
            "path_id": self._path_ids[path_key],
            "query_keys": query_keys,
            "unknown_query_key_count": unknown_count,
            "query_truncated": query_truncated,
            "invalid": False,
        }

    @staticmethod
    def _invalid_url() -> dict[str, Any]:
        return {
            "origin": "invalid_origin",
            "path": "/<invalid>",
            "path_id": 0,
            "query_keys": [],
            "unknown_query_key_count": 0,
            "query_truncated": False,
            "invalid": True,
        }

    @staticmethod
    def _safe_path(raw_path: str) -> str:
        if not raw_path or raw_path == "/":
            return "/"

        trailing_slash = raw_path.endswith("/")
        safe_segments: list[str] = []
        for raw_segment in raw_path.split("/"):
            if not raw_segment:
                continue
            decoded = unquote(raw_segment)
            safe_segments.append(_SAFE_PATH_SEGMENTS.get(decoded.lower(), "<segment>"))

        path = "/" + "/".join(safe_segments)
        if trailing_slash and safe_segments:
            path += "/"
        return path

    @staticmethod
    def _query_summary(raw_query: str) -> tuple[list[str], int, bool]:
        if not raw_query:
            return [], 0, False

        items = raw_query.split("&")
        query_truncated = len(items) > MAX_QUERY_ITEMS
        safe_keys: list[str] = []
        unknown_count = 0
        for item in items[:MAX_QUERY_ITEMS]:
            raw_key = item.split("=", 1)[0]
            key = unquote_plus(raw_key).lower()
            safe_name = _SAFE_QUERY_KEYS.get(key)
            if safe_name is None:
                unknown_count += 1
            else:
                safe_keys.append(safe_name)

        if query_truncated:
            unknown_count += len(items) - MAX_QUERY_ITEMS
        return safe_keys, unknown_count, query_truncated


def _is_http_url(raw_url: object) -> bool:
    if not isinstance(raw_url, str) or not raw_url or len(raw_url) > MAX_URL_LENGTH:
        return False
    try:
        parts = urlsplit(raw_url)
        return parts.scheme.lower() in {"http", "https"} and bool(parts.hostname)
    except (TypeError, ValueError):
        return False


class RedirectTraceCollector:
    """Project Playwright events into a closed, JSON-safe navigation trace."""

    def __init__(
        self,
        source: str,
        *,
        max_events: int = MAX_NAVIGATION_EVENTS,
        clock: Callable[[], float] = time.monotonic,
        progress: Callable[[str, dict[str, Any]], None] | None = None,
    ):
        if source not in ENTRY_URLS:
            raise ValueError("unsupported fixed source")
        if max_events < 1:
            raise ValueError("max_events must be positive")
        self.source = source
        self._max_events = max_events
        self._clock = clock
        self._started = clock()
        self._progress = progress
        self._url_projector = UrlProjector(source)
        self._records: list[dict[str, Any]] = []
        self._truncated = False
        self._failure_code: str | None = None
        self._next_event_seq = 1
        self._next_request_seq = 1
        self._next_page_seq = 1
        self._page_ids: dict[int, int] = {}
        self._page_objects: dict[int, Any] = {}
        self._frame_ids: dict[int, dict[int, int]] = {}
        self._frame_objects: dict[int, dict[int, Any]] = {}
        self._request_sequences: dict[Any, int] = {}
        self._request_records: dict[Any, dict[str, Any] | None] = {}
        self._request_objects: dict[int, Any] = {}
        self._watched_pages: set[int] = set()
        self._open_pages: set[int] = set()
        self._unsequenced_pages: dict[int, Any] = {}
        self._on_all_pages_closed: Callable[[], None] | None = None
        self._ever_opened_page = False
        self._closed_callback_called = False
        self._normal_shutdown = False

    def set_all_pages_closed_callback(self, callback: Callable[[], None]) -> None:
        self._on_all_pages_closed = callback

    def mark_normal_shutdown(self) -> None:
        self._normal_shutdown = True

    def attach(self, context: Any) -> None:
        """Subscribe to metadata-only Playwright events on a new context."""
        try:
            context.on("request", self._on_request)
            context.on("response", self._on_response)
            context.on("requestfailed", self._on_request_failed)
            context.on("page", self._on_page)
        except Exception:
            self.mark_failure("event_projection_failed")

    def attach_page(self, page: Any) -> int:
        """Register a page and its frame/popup events; safe to call repeatedly."""
        page_key = id(page)
        if page_key in self._watched_pages:
            return self._page_ids.get(page_key, 0)
        self._watched_pages.add(page_key)
        self._open_pages.add(page_key)
        self._ever_opened_page = True
        if self._at_limit():
            # Keep only a close listener so shutdown still waits for every page.
            # No page ID, frame projection, URL read, or trace record is added.
            self._unsequenced_pages[page_key] = page
            self._page_objects[page_key] = page
            try:
                page.on("close", lambda *_, watched=page: self._on_page_closed(watched))
            except Exception:
                self.mark_failure("event_projection_failed")
            return 0

        page_seq = self._page_seq(page)
        try:
            page.on("framenavigated", lambda frame, watched=page: self._on_frame_navigated(watched, frame))
            page.on("popup", lambda popup, opener=page: self._on_popup(opener, popup))
            page.on("close", lambda *_, watched=page: self._on_page_closed(watched))
            main_frame = getattr(page, "main_frame", None)
            if main_frame is not None:
                self._frame_seq(page, main_frame)
        except Exception:
            self.mark_failure("event_projection_failed")
        return page_seq

    def mark_failure(self, code: str) -> None:
        if code in _FAILURE_CODES and self._failure_code is None:
            self._failure_code = code

    def result(self, failure_code: str | None = None) -> dict[str, Any]:
        if failure_code not in {None, *_FAILURE_CODES}:
            failure_code = "event_projection_failed"
        code = failure_code or self._failure_code
        return {
            "kind": SCHEMA_KIND,
            "source": self.source,
            "records": copy.deepcopy(self._records),
            "truncated": self._truncated,
            "failure": {"code": code} if code else None,
            "browsingAssetsExported": False,
        }

    def _on_page(self, page: Any) -> None:
        self.attach_page(page)

    def _on_popup(self, opener: Any, popup: Any) -> None:
        if self._at_limit():
            self.attach_page(popup)
            return
        opener_seq = self._page_seq(opener)
        popup_seq = self.attach_page(popup)
        record = self._append(
            {
                "kind": "popup",
                "page_seq": popup_seq,
                "opener_page_seq": opener_seq,
            }
        )
        if record is not None:
            self._notify_progress("popup", record)

    def _on_frame_navigated(self, page: Any, frame: Any) -> None:
        if self._at_limit():
            return
        try:
            page_seq = self._page_seq(page)
            frame_seq = self._frame_seq(page, frame)
            main_frame = id(frame) == id(getattr(page, "main_frame", None))
            raw_url = getattr(frame, "url", None)
            self._append(
                {
                    "kind": "frame_navigated",
                    "page_seq": page_seq,
                    "frame_seq": frame_seq,
                    "main_frame": main_frame,
                    "url": self._url_projector.project(raw_url),
                }
            )
        except Exception:
            self.mark_failure("event_projection_failed")

    def _on_request(self, request: Any) -> None:
        if self._at_limit():
            return
        try:
            if getattr(request, "resource_type", None) != "document":
                return

            raw_url = getattr(request, "url", None)
            if not _is_http_url(raw_url):
                return
            request_key = id(request)
            request_seq = self._next_request_seq
            self._next_request_seq += 1
            redirected_from = getattr(request, "redirected_from", None)
            redirect_from_seq = self._request_sequences.get(redirected_from) if redirected_from is not None else None
            try:
                frame = getattr(request, "frame", None)
            except Exception:
                frame = None
            try:
                page = getattr(frame, "page", None) if frame is not None else None
            except Exception:
                page = None
            if page is not None and frame is not None:
                page_seq = self._page_ids.get(id(page), 0)
                frame_seq = self._frame_seq(page, frame) if page_seq else 0
            else:
                page_seq = 0
                frame_seq = 0
            raw_method = getattr(request, "method", None)
            method = raw_method.upper() if isinstance(raw_method, str) else ""
            method = method if method in {"GET", "POST"} else "OTHER"
            record = self._append(
                {
                    "kind": "document_request",
                    "request_seq": request_seq,
                    "page_seq": page_seq,
                    "frame_seq": frame_seq,
                    "relative_ms": self._relative_ms(),
                    "method": method,
                    "url": self._url_projector.project(raw_url),
                    "redirect_from_seq": redirect_from_seq,
                    "status": None,
                    "failure": None,
                }
            )
            # Keep bounded Request objects as map keys so Python object IDs cannot
            # be reused before later redirect/response events arrive.
            self._request_objects[request_key] = request
            self._request_sequences[request] = request_seq
            self._request_records[request] = record
            if record is not None:
                self._notify_progress("request", record)
        except Exception:
            self.mark_failure("event_projection_failed")

    def _on_response(self, response: Any) -> None:
        try:
            request = getattr(response, "request", None)
            if request is None:
                return
            record = self._request_records.get(request)
            if record is None:
                return
            status = getattr(response, "status", None)
            if type(status) is not int or status < 100 or status > 599:
                self.mark_failure("event_projection_failed")
                return
            record["status"] = status
            record["relative_response_ms"] = self._relative_ms()
            self._notify_progress("response", record)
        except Exception:
            self.mark_failure("event_projection_failed")

    def _on_request_failed(self, request: Any) -> None:
        try:
            if self._normal_shutdown:
                return
            if getattr(request, "resource_type", None) != "document":
                return
            if request not in self._request_records:
                return
            record = self._request_records[request]
            self.mark_failure("document_request_failed")
            if record is not None:
                # Do not read request.failure: Playwright's raw text can contain URLs.
                record["failure"] = "request_failed"
                record["relative_failure_ms"] = self._relative_ms()
                self._notify_progress("request_failed", record)
        except Exception:
            self.mark_failure("event_projection_failed")

    def _page_seq(self, page: Any) -> int:
        if page is None:
            return 0
        key = id(page)
        if key not in self._page_ids:
            self._page_ids[key] = self._next_page_seq
            self._next_page_seq += 1
            self._page_objects[key] = page
        return self._page_ids[key]

    def _frame_seq(self, page: Any, frame: Any) -> int:
        page_key = id(page)
        frames = self._frame_ids.setdefault(page_key, {})
        frame_key = id(frame)
        if frame_key not in frames:
            frames[frame_key] = len(frames) + 1
            self._frame_objects.setdefault(page_key, {})[frame_key] = frame
        return frames[frame_key]

    def _on_page_closed(self, page: Any) -> None:
        page_key = id(page)
        self._open_pages.discard(page_key)
        self._page_objects.pop(page_key, None)
        self._unsequenced_pages.pop(page_key, None)
        self._page_ids.pop(page_key, None)
        self._frame_ids.pop(page_key, None)
        self._frame_objects.pop(page_key, None)
        self._watched_pages.discard(page_key)
        if (
            self._ever_opened_page
            and not self._open_pages
            and not self._closed_callback_called
            and self._on_all_pages_closed is not None
        ):
            self._closed_callback_called = True
            self._normal_shutdown = True
            try:
                self._on_all_pages_closed()
            except Exception:
                self.mark_failure("event_projection_failed")

    def _at_limit(self) -> bool:
        if len(self._records) >= self._max_events:
            self._truncated = True
            return True
        return False

    def _append(self, record: dict[str, Any]) -> dict[str, Any] | None:
        if len(self._records) >= self._max_events:
            self._truncated = True
            return None
        record["event_seq"] = self._next_event_seq
        self._next_event_seq += 1
        record["relative_ms"] = record.get("relative_ms", self._relative_ms())
        self._records.append(record)
        if len(self._records) >= self._max_events:
            self._truncated = True
        return record

    def _relative_ms(self) -> int:
        try:
            return max(0, int((self._clock() - self._started) * 1000))
        except Exception:
            return 0

    def _notify_progress(self, kind: str, record: dict[str, Any]) -> None:
        if self._progress is None:
            return
        try:
            self._progress(kind, copy.deepcopy(record))
        except Exception:
            self.mark_failure("event_projection_failed")


class _SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:  # noqa: D401 - fixed safe error text
        self.print_usage(sys.stderr)
        self.exit(2, "参数错误；仅支持 --source young|jw 和 --direct。\n")


def _arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = _SafeArgumentParser(
        description="手动登录重定向观测；仅保存脱敏导航摘要。",
        allow_abbrev=False,
    )
    parser.add_argument("--source", choices=tuple(ENTRY_URLS), default="young")
    parser.add_argument("--direct", action="store_true", help="本次启动不使用默认 7897 代理")
    return parser.parse_args(argv)


def _output_path(source: str) -> Path:
    workspace = Path(__file__).resolve().parents[2]
    return workspace / "tmp" / "login-redirect-trace" / f"latest-{source}.json"


def _save_result(path: Path, result: dict[str, Any]) -> bool:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        writing_path = path.with_suffix(path.suffix + ".writing")
        writing_path.write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        writing_path.replace(path)
        return True
    except Exception:
        return False


def _progress_line(kind: str, record: dict[str, Any]) -> None:
    if kind in {"request", "response", "request_failed"}:
        projected = record["url"]
        path = projected["path"]
        origin = projected["origin"]
        status = record["status"]
        status_text = f" status={status}" if status is not None else ""
        redirect = record["redirect_from_seq"]
        redirect_text = f" redirect_from=#{redirect}" if redirect is not None else ""
        print(
            f"[document #{record['request_seq']}] {record['method']} {origin}{path}"
            f" path#{projected['path_id']}{status_text}{redirect_text}",
            flush=True,
        )
    elif kind == "frame_navigated":
        projected = record["url"]
        print(
            f"[frame page=#{record['page_seq']} frame=#{record['frame_seq']}] "
            f"{projected['origin']}{projected['path']} path#{projected['path_id']}",
            flush=True,
        )
    elif kind == "popup":
        print(
            f"[popup page=#{record['page_seq']} opener=#{record['opener_page_seq']} ]",
            flush=True,
        )


async def _run_browser(args: argparse.Namespace, collector: RedirectTraceCollector) -> str | None:
    playwright = None
    browser = None
    context = None
    failure_code: str | None = None
    phase = "playwright_import"
    stop_event = asyncio.Event()
    collector.set_all_pages_closed_callback(stop_event.set)

    try:
        from playwright.async_api import async_playwright

        phase = "browser_launch"
        playwright_manager = async_playwright()
        playwright = await playwright_manager.start()
        launch_options: dict[str, Any] = {"channel": "msedge", "headless": False}
        if args.direct:
            launch_options["args"] = ["--no-proxy-server"]
        else:
            launch_options["proxy"] = {"server": DEFAULT_PROXY}
        browser = await playwright.chromium.launch(**launch_options)
        def on_browser_disconnected(*_: Any) -> None:
            collector.mark_normal_shutdown()
            stop_event.set()

        browser.on("disconnected", on_browser_disconnected)

        phase = "context_create"
        context = await browser.new_context()
        collector.attach(context)
        page = await context.new_page()
        collector.attach_page(page)

        print(
            f"已打开固定 {args.source} 入口。请在 Edge 中手动完成登录和必要授权；"
            "关闭本工具打开的全部浏览器页面后会自动保存。",
            flush=True,
        )
        phase = "initial_navigation"
        try:
            await page.goto(ENTRY_URLS[args.source], wait_until="commit", timeout=30_000)
        except Exception:
            failure_code = "initial_navigation_failed"
            collector.mark_failure(failure_code)
            print("固定入口未能完成初始导航；仍可在浏览器中手动检查并安全结束。", flush=True)

        await stop_event.wait()
    except asyncio.CancelledError:
        failure_code = failure_code or "user_interrupted"
        collector.mark_failure(failure_code)
    except Exception:
        if phase == "playwright_import":
            failure_code = "playwright_unavailable"
        elif phase == "browser_launch":
            failure_code = "browser_launch_failed"
        elif phase == "context_create":
            failure_code = "context_create_failed"
        else:
            failure_code = "event_projection_failed"
        collector.mark_failure(failure_code)
        print(f"操作以固定错误码结束：{failure_code}。", flush=True)
    finally:
        connected = False
        if browser is not None:
            try:
                connected = browser.is_connected()
            except Exception:
                connected = False
        if context is not None and connected:
            try:
                await context.close()
            except Exception:
                try:
                    still_connected = browser.is_connected()
                except Exception:
                    still_connected = False
                if still_connected:
                    failure_code = failure_code or "browser_close_failed"
                    collector.mark_failure(failure_code)
        if browser is not None and connected:
            try:
                await browser.close()
            except Exception:
                try:
                    still_connected = browser.is_connected()
                except Exception:
                    still_connected = False
                if still_connected:
                    failure_code = failure_code or "browser_close_failed"
                    collector.mark_failure(failure_code)
        if playwright is not None:
            try:
                await playwright.stop()
            except Exception:
                if browser is None or connected:
                    failure_code = failure_code or "browser_close_failed"
                    collector.mark_failure(failure_code)

    return failure_code


def main(argv: list[str] | None = None) -> int:
    args = _arguments(argv)
    # Clear only this process's Playwright debugging switches before importing it.
    os.environ.pop("DEBUG", None)
    os.environ.pop("PWDEBUG", None)

    collector = RedirectTraceCollector(args.source, progress=_progress_line)
    failure_code: str | None = None
    try:
        failure_code = asyncio.run(_run_browser(args, collector))
    except KeyboardInterrupt:
        failure_code = "user_interrupted"
        collector.mark_failure(failure_code)

    output_path = _output_path(args.source)
    result = collector.result(failure_code)
    if not _save_result(output_path, result):
        print("未能保存脱敏摘要；failure=trace_save_failed。", flush=True)
        return 1

    print(f"脱敏摘要已保存：{output_path}", flush=True)
    return 1 if result["failure"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
