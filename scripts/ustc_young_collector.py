#!/usr/bin/env python3
"""Collect open USTC second-classroom activities from a browser session."""

from __future__ import annotations

import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlsplit

from playwright.sync_api import Error as PlaywrightError
from playwright.sync_api import TimeoutError as PlaywrightTimeoutError
from playwright.sync_api import sync_playwright


YOUNG_HOST = "young.ustc.edu.cn"
SIGN_UP_URL = (
    "https://young.ustc.edu.cn/login/"
    "sc-wisdom-group-learning/myproject/SignUp"
)
ENROLMENT_LIST_PATH = (
    "/login/wisdom-group-learning-bg/mobile/item/enrolmentList"
)
APP_PATH_PREFIX = "/login/sc-wisdom-group-learning/"
NEXT_PAGE_SELECTOR = "li.ant-pagination-next"
DEFAULT_LOGIN_TIMEOUT_MS = 5 * 60 * 1000
DEFAULT_RESPONSE_TIMEOUT_MS = 30 * 1000


class CollectionError(RuntimeError):
    """A sanitized collection failure safe to show in the terminal."""


@dataclass(frozen=True)
class EnrolmentPage:
    records: tuple[dict[str, Any], ...]
    total: int
    pages: int


@dataclass(frozen=True)
class CollectedEnrolmentActivities:
    records: tuple[dict[str, Any], ...]
    reported_total: int
    pages: int


def default_profile_dir() -> Path:
    local_app_data = os.environ.get("LOCALAPPDATA")
    if local_app_data:
        base = Path(local_app_data)
    else:
        base = Path.home() / "AppData" / "Local"
    return base / "USTC Campus Assistant" / "edge-profile"


def is_enrolment_list_response(response: Any) -> bool:
    parsed = urlsplit(getattr(response, "url", ""))
    request = getattr(response, "request", None)
    return (
        parsed.scheme == "https"
        and parsed.netloc == YOUNG_HOST
        and parsed.path == ENROLMENT_LIST_PATH
        and getattr(request, "method", None) == "GET"
        and getattr(response, "status", None) == 200
    )


def _is_young_app_url(url: str) -> bool:
    parsed = urlsplit(url)
    return (
        parsed.scheme == "https"
        and parsed.netloc == YOUNG_HOST
        and parsed.path.startswith(APP_PATH_PREFIX)
    )


def _is_sign_up_url(url: str) -> bool:
    parsed = urlsplit(url)
    target = urlsplit(SIGN_UP_URL)
    return (
        parsed.scheme == target.scheme
        and parsed.netloc == target.netloc
        and parsed.path == target.path
    )


def _require_nonnegative_int(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise CollectionError(f"enrolment list returned invalid {field}")
    return value


def parse_enrolment_page(response: Any) -> EnrolmentPage:
    try:
        payload = response.json()
    except (TypeError, ValueError) as exc:
        raise CollectionError("enrolment list returned invalid JSON") from exc

    if (
        not isinstance(payload, dict)
        or payload.get("success") is not True
        or payload.get("code") != 200
    ):
        raise CollectionError("enrolment list request was not successful")
    result = payload.get("result")
    if not isinstance(result, dict):
        raise CollectionError("enrolment list response is missing result")
    records = result.get("records")
    if not isinstance(records, list) or not all(
        isinstance(record, dict) for record in records
    ):
        raise CollectionError("enrolment list response has invalid records")
    total = _require_nonnegative_int(result.get("total"), "total")
    pages = _require_nonnegative_int(result.get("pages"), "pages")
    return EnrolmentPage(records=tuple(records), total=total, pages=pages)


def _merge_records(
    records_by_id: dict[str, dict[str, Any]],
    records: tuple[dict[str, Any], ...],
) -> None:
    for record in records:
        activity_id = record.get("id")
        if not isinstance(activity_id, str) or not activity_id:
            raise CollectionError("enrolment activity is missing id")
        existing = records_by_id.get(activity_id)
        if existing is not None and existing != record:
            raise CollectionError("conflicting duplicate activity id")
        records_by_id.setdefault(activity_id, record)


def _capture_page_after_click(
    page: Any,
    click: Callable[[], None],
    *,
    timeout_ms: int,
    page_number: int,
) -> EnrolmentPage:
    try:
        with page.expect_response(
            is_enrolment_list_response,
            timeout=timeout_ms,
        ) as response_info:
            click()
    except PlaywrightTimeoutError as exc:
        raise CollectionError(
            f"enrolment page {page_number} did not return the expected response"
        ) from exc
    return parse_enrolment_page(response_info.value)


def _open_sign_up_after_login(
    page: Any,
    *,
    login_timeout_ms: int,
    status: Callable[[str], None],
) -> Any:
    page.goto(SIGN_UP_URL, wait_until="domcontentloaded")
    enrolment_tab = page.get_by_text("报名中", exact=True)
    deadline = time.monotonic() + max(login_timeout_ms, 0) / 1000
    reopened_after_login = False
    announced_login_wait = False

    while True:
        if enrolment_tab.is_visible():
            return enrolment_tab

        if (
            not reopened_after_login
            and _is_young_app_url(page.url)
            and not _is_sign_up_url(page.url)
        ):
            status("Login completed; opening the open-activity page ...")
            page.goto(SIGN_UP_URL, wait_until="domcontentloaded")
            enrolment_tab = page.get_by_text("报名中", exact=True)
            reopened_after_login = True
            continue

        remaining_ms = int((deadline - time.monotonic()) * 1000)
        if remaining_ms <= 0:
            raise CollectionError(
                "second-classroom login was not completed before timeout"
            )
        if not announced_login_wait:
            status(
                "Complete USTC login in the Edge window; waiting for the "
                "second-classroom application ..."
            )
            announced_login_wait = True
        page.wait_for_timeout(min(250, remaining_ms))


def collect_from_page(
    page: Any,
    *,
    login_timeout_ms: int = DEFAULT_LOGIN_TIMEOUT_MS,
    response_timeout_ms: int = DEFAULT_RESPONSE_TIMEOUT_MS,
    status: Callable[[str], None] = print,
) -> CollectedEnrolmentActivities:
    enrolment_tab = _open_sign_up_after_login(
        page,
        login_timeout_ms=login_timeout_ms,
        status=status,
    )

    status("Collecting the first page of open second-classroom activities ...")
    first_page = _capture_page_after_click(
        page,
        enrolment_tab.click,
        timeout_ms=response_timeout_ms,
        page_number=1,
    )
    records_by_id: dict[str, dict[str, Any]] = {}
    _merge_records(records_by_id, first_page.records)

    next_button = page.locator(NEXT_PAGE_SELECTOR)
    for page_number in range(2, first_page.pages + 1):
        status(f"Collecting open-activity page {page_number} of {first_page.pages} ...")
        current_page = _capture_page_after_click(
            page,
            next_button.click,
            timeout_ms=response_timeout_ms,
            page_number=page_number,
        )
        if (
            current_page.total != first_page.total
            or current_page.pages != first_page.pages
        ):
            raise CollectionError("enrolment pagination metadata changed during collection")
        _merge_records(records_by_id, current_page.records)

    collected_count = len(records_by_id)
    if collected_count != first_page.total:
        raise CollectionError(
            "enrolment activity count mismatch: "
            f"expected {first_page.total}, collected {collected_count}"
        )
    return CollectedEnrolmentActivities(
        records=tuple(records_by_id.values()),
        reported_total=first_page.total,
        pages=first_page.pages,
    )


def collect_activities(
    *,
    profile_dir: Path | None = None,
    login_timeout_ms: int = DEFAULT_LOGIN_TIMEOUT_MS,
    response_timeout_ms: int = DEFAULT_RESPONSE_TIMEOUT_MS,
    playwright_factory: Callable[[], Any] | None = None,
    status: Callable[[str], None] = print,
) -> CollectedEnrolmentActivities:
    profile = Path(profile_dir) if profile_dir is not None else default_profile_dir()
    profile.mkdir(parents=True, exist_ok=True)
    factory = playwright_factory or sync_playwright

    try:
        with factory() as playwright:
            context = playwright.chromium.launch_persistent_context(
                str(profile),
                channel="msedge",
                headless=False,
                no_viewport=True,
            )
            try:
                page = context.pages[0] if context.pages else context.new_page()
                return collect_from_page(
                    page,
                    login_timeout_ms=login_timeout_ms,
                    response_timeout_ms=response_timeout_ms,
                    status=status,
                )
            finally:
                context.close()
    except CollectionError:
        raise
    except PlaywrightError as exc:
        raise CollectionError("browser automation failed") from exc
