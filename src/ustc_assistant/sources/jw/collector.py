#!/usr/bin/env python3
"""Collect USTC JW source data from an authenticated browser session."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable
from urllib.parse import parse_qs, urlencode, urlsplit, urlunsplit

from playwright.sync_api import TimeoutError as PlaywrightTimeoutError

from ustc_assistant.common.browser import (
    CollectionError,
    default_profile_dir,
    run_in_edge,
)
from ustc_assistant.common.auth import (
    AccountMismatch,
    CollectionCancelled,
    LoginCredentials,
    UserActionRequired,
    fill_ustc_login,
    profile_dir_for_account,
    raise_if_cancelled,
    verify_ustc_account,
)


JW_HOST = "jw.ustc.edu.cn"
JW_ROOT_URL = "https://jw.ustc.edu.cn/"
CAS_ENTRY_URL = "https://jw.ustc.edu.cn/ucas-sso/login"
COURSE_ENTRY_URL = "https://jw.ustc.edu.cn/for-std/course-table"
COURSE_GET_DATA_PATH = "/for-std/course-table/get-data"
COURSE_DATUM_URL = "https://jw.ustc.edu.cn/for-std/course-table/datum"
EXAM_ENTRY_URL = "https://jw.ustc.edu.cn/for-std/exam-arrange"
AUTHENTICATED_HOME_PATTERN = re.compile(
    r"^https://jw\.ustc\.edu\.cn/home(?:[/?#].*)?$"
)
DEFAULT_LOGIN_TIMEOUT_MS = 5 * 60 * 1000
DEFAULT_RESPONSE_TIMEOUT_MS = 30 * 1000


@dataclass(frozen=True)
class CollectedSources:
    course_datum: dict[str, Any]
    exam_html: str


def _get_data_parts(url: str):
    parsed = urlsplit(url)
    if (
        parsed.scheme != "https"
        or parsed.netloc != JW_HOST
        or parsed.path != COURSE_GET_DATA_PATH
    ):
        raise CollectionError("unexpected course get-data endpoint")
    return parsed


def extract_data_id(url: str) -> str:
    parsed = _get_data_parts(url)
    values = parse_qs(parsed.query).get("dataId", [])
    if len(values) != 1 or not values[0]:
        raise CollectionError("course get-data request is missing dataId")
    return values[0]


def is_get_data_url(url: str) -> bool:
    try:
        _get_data_parts(url)
    except CollectionError:
        return False
    return True


def build_get_data_url(semester_id: int, data_id: str) -> str:
    if not data_id:
        raise CollectionError("cannot build course request without dataId")
    query = urlencode(
        {
            "bizTypeId": 2,
            "semesterId": semester_id,
            "dataId": data_id,
        }
    )
    return urlunsplit(("https", JW_HOST, COURSE_GET_DATA_PATH, query, ""))


def _request_headers(referer: str) -> dict[str, str]:
    return {
        "Referer": referer,
        "X-Requested-With": "XMLHttpRequest",
    }


def _require_success(response: Any, endpoint: str) -> None:
    status = getattr(response, "status", None)
    if not isinstance(status, int) or not 200 <= status < 300:
        display_status = status if isinstance(status, int) else "unknown"
        raise CollectionError(f"{endpoint} request failed with HTTP {display_status}")


def fetch_course_datum(
    request_context: Any,
    *,
    semester_id: int,
    data_id: str,
    referer: str,
    cancel_check: Callable[[], bool] | None = None,
) -> dict[str, Any]:
    raise_if_cancelled(cancel_check)
    headers = _request_headers(referer)
    get_data_response = request_context.get(
        build_get_data_url(semester_id, data_id),
        headers=headers,
    )
    _require_success(get_data_response, "course get-data")
    get_data = get_data_response.json()
    if not isinstance(get_data, dict):
        raise CollectionError("course get-data returned invalid JSON")

    lesson_ids = get_data.get("lessonIds")
    if not isinstance(lesson_ids, list):
        raise CollectionError("course get-data response is missing lessonIds")
    if not lesson_ids:
        raise CollectionError(f"no lessons found for configured semester {semester_id}")

    raise_if_cancelled(cancel_check)
    datum_response = request_context.post(
        COURSE_DATUM_URL,
        headers=headers,
        data={"lessonIds": lesson_ids},
    )
    _require_success(datum_response, "course datum")
    datum = datum_response.json()
    if not isinstance(datum, dict):
        raise CollectionError("course datum returned invalid JSON")
    return datum


def _is_authenticated_home(url: str) -> bool:
    return AUTHENTICATED_HOME_PATTERN.fullmatch(url) is not None


def _ensure_authenticated(
    page: Any,
    *,
    login_timeout_ms: int,
    status: Callable[[str], None],
    allow_interactive_login: bool = True,
    credentials: LoginCredentials | None = None,
    cancel_check: Callable[[], bool] | None = None,
) -> None:
    raise_if_cancelled(cancel_check)
    page.goto(JW_ROOT_URL, wait_until="domcontentloaded")
    if _is_authenticated_home(page.url):
        status("Reused the existing USTC JW browser session.")
        if credentials is not None:
            verify_ustc_account(page, credentials.username)
        return

    if not allow_interactive_login:
        raise UserActionRequired("USTC JW login requires user action")
    status("Complete USTC CAS login in the Edge window; waiting for /home ...")
    raise_if_cancelled(cancel_check)
    page.goto(CAS_ENTRY_URL, wait_until="domcontentloaded")
    if _is_authenticated_home(page.url):
        status("Reused the existing USTC CAS session.")
        if credentials is not None:
            verify_ustc_account(page, credentials.username)
        return
    if credentials is not None:
        fill_ustc_login(page, credentials)
    try:
        page.wait_for_url(AUTHENTICATED_HOME_PATTERN, timeout=login_timeout_ms)
    except PlaywrightTimeoutError as exc:
        raise CollectionError("USTC JW login was not completed before timeout") from exc
    if not _is_authenticated_home(page.url):
        raise CollectionError("USTC JW login did not return to the expected home page")
    if credentials is not None:
        verify_ustc_account(page, credentials.username)


def _collect_from_authenticated_context(
    page: Any,
    request_context: Any,
    *,
    semester_id: int,
    response_timeout_ms: int,
    status: Callable[[str], None],
    cancel_check: Callable[[], bool] | None = None,
) -> CollectedSources:
    raise_if_cancelled(cancel_check)
    status("Opening the course table and resolving the current data context ...")
    try:
        with page.expect_response(
            lambda response: is_get_data_url(response.url),
            timeout=response_timeout_ms,
        ) as response_info:
            page.goto(COURSE_ENTRY_URL, wait_until="domcontentloaded")
        data_id = extract_data_id(response_info.value.url)
    except PlaywrightTimeoutError as exc:
        raise CollectionError(
            "course page did not issue the expected get-data request"
        ) from exc

    status(f"Collecting course data for configured semester {semester_id} ...")
    course_datum = fetch_course_datum(
        request_context,
        semester_id=semester_id,
        data_id=data_id,
        referer=page.url,
        cancel_check=cancel_check,
    )

    status("Opening the published exam arrangement page ...")
    raise_if_cancelled(cancel_check)
    page.goto(EXAM_ENTRY_URL, wait_until="domcontentloaded")
    try:
        page.wait_for_selector("table#exams", timeout=response_timeout_ms)
    except PlaywrightTimeoutError as exc:
        raise CollectionError("exam page did not contain table#exams") from exc
    return CollectedSources(course_datum=course_datum, exam_html=page.content())


def collect_sources(
    *,
    semester_id: int,
    account_id: str | None = None,
    profile_dir: Path | None = None,
    login_timeout_ms: int = DEFAULT_LOGIN_TIMEOUT_MS,
    response_timeout_ms: int = DEFAULT_RESPONSE_TIMEOUT_MS,
    playwright_factory: Callable[[], Any] | None = None,
    allow_interactive_login: bool = True,
    credentials: LoginCredentials | None = None,
    cancel_check: Callable[[], bool] | None = None,
    status: Callable[[str], None] = print,
) -> CollectedSources:
    def action(page: Any) -> CollectedSources:
        _ensure_authenticated(
            page,
            login_timeout_ms=login_timeout_ms,
            status=status,
            allow_interactive_login=allow_interactive_login,
            credentials=credentials,
            cancel_check=cancel_check,
        )
        return _collect_from_authenticated_context(
            page,
            page.context.request,
            semester_id=semester_id,
            response_timeout_ms=response_timeout_ms,
            status=status,
            cancel_check=cancel_check,
        )

    resolved_profile = profile_dir
    if resolved_profile is None and account_id is not None:
        resolved_profile = profile_dir_for_account(account_id)
    return run_in_edge(
        action,
        profile_dir=resolved_profile,
        headless=not allow_interactive_login,
        playwright_factory=playwright_factory,
    )
