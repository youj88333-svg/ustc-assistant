#!/usr/bin/env python3
"""Collect the signed-up USTC second-classroom schedule through its calendar UI."""

from __future__ import annotations

import calendar
import time
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path
from html.parser import HTMLParser
from typing import Any, Callable, Iterator
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo

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
    is_ustc_cas_origin,
    profile_dir_for_account,
    raise_if_cancelled,
    verify_ustc_account,
)


BEIJING_TZ = ZoneInfo("Asia/Shanghai")
YOUNG_HOST = "young.ustc.edu.cn"
MY_SCHEDULE_URL = (
    "https://young.ustc.edu.cn/login/"
    "sc-wisdom-group-learning/personalInformation/mySchedule"
)
SCHEDULE_LIST_PATH = (
    "/login/wisdom-group-learning-bg/personal/scCalendar/getPageUserList"
)
APP_PATH_PREFIX = "/login/sc-wisdom-group-learning/"
CALENDAR_SELECTOR = ".ant-fullcalendar"
PREVIOUS_MONTH_SELECTOR = ".ant-fullcalendar-prev-month-btn"
NEXT_MONTH_SELECTOR = ".ant-fullcalendar-next-month-btn"
YEAR_SELECT_SELECTOR = ".ant-fullcalendar-year-select"
MONTH_SELECT_SELECTOR = ".ant-fullcalendar-month-select"
VISIBLE_OPTION_SELECTOR = (
    ".ant-select-dropdown:not(.ant-select-dropdown-hidden) "
    "li.ant-select-dropdown-menu-item"
)
DEFAULT_LOGIN_TIMEOUT_MS = 5 * 60 * 1000
DEFAULT_RESPONSE_TIMEOUT_MS = 30 * 1000
SCHEDULE_REOPEN_INTERVAL_SECONDS = 0.25
SOURCE_DATETIME_FORMAT = "%Y-%m-%d %H:%M:%S"


@dataclass(frozen=True)
class SchedulePage:
    records: tuple[dict[str, Any], ...]
    total: int


@dataclass(frozen=True)
class ScheduleDateCheck:
    """One verified calendar-date response from the registered schedule."""

    checked_date: date
    was_empty: bool


@dataclass(frozen=True)
class CollectedSchedules:
    records: tuple[dict[str, Any], ...]
    queried_from: date
    queried_through: date
    queried_dates: int
    empty_dates: int
    date_checks: tuple[ScheduleDateCheck, ...] = ()


def beijing_today() -> date:
    return datetime.now(BEIJING_TZ).date()


def add_calendar_month(value: date) -> date:
    year = value.year + (1 if value.month == 12 else 0)
    month = 1 if value.month == 12 else value.month + 1
    day = min(value.day, calendar.monthrange(year, month)[1])
    return date(year, month, day)


def query_window(today: date) -> tuple[date, date]:
    return today - timedelta(days=7), add_calendar_month(today)


def iter_dates(start: date, end: date) -> Iterator[date]:
    if end < start:
        raise ValueError("query end date must not be before start date")
    current = start
    while current <= end:
        yield current
        current += timedelta(days=1)


def date_cell_selector(value: date) -> str:
    return (
        f'td.ant-fullcalendar-cell[title="{value.year}年{value.month}月{value.day}日"] '
        ".ant-fullcalendar-date"
    )


def is_schedule_list_response(response: Any) -> bool:
    parsed = urlsplit(getattr(response, "url", ""))
    request = getattr(response, "request", None)
    return (
        parsed.scheme == "https"
        and parsed.netloc == YOUNG_HOST
        and parsed.path == SCHEDULE_LIST_PATH
        and getattr(request, "method", None) == "GET"
        and getattr(response, "status", None) == 200
    )


def _require_nonnegative_int(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise CollectionError(f"schedule list returned invalid {field}")
    return value


def _parse_source_datetime(value: Any, field: str) -> datetime:
    if not isinstance(value, str):
        raise CollectionError(f"schedule record has invalid {field}")
    try:
        return datetime.strptime(value, SOURCE_DATETIME_FORMAT).replace(tzinfo=BEIJING_TZ)
    except ValueError as exc:
        raise CollectionError(f"schedule record has invalid {field}") from exc


def parse_schedule_page(response: Any, selected_date: date) -> SchedulePage:
    try:
        payload = response.json()
    except (TypeError, ValueError) as exc:
        raise CollectionError("schedule list returned invalid JSON") from exc
    if (
        not isinstance(payload, dict)
        or payload.get("success") is not True
        or payload.get("code") != 200
    ):
        raise CollectionError("schedule list request was not successful")
    result = payload.get("result")
    if not isinstance(result, dict):
        raise CollectionError("schedule list response is missing result")
    records = result.get("records")
    if not isinstance(records, list) or not all(
        isinstance(record, dict) for record in records
    ):
        raise CollectionError("schedule list response has invalid records")
    total = _require_nonnegative_int(result.get("total"), "total")
    pages = _require_nonnegative_int(result.get("pages"), "pages")
    if pages > 1:
        raise CollectionError(
            f"schedule date {selected_date.isoformat()} has more than one page"
        )
    expected_pages = 1 if total else 0
    if pages != expected_pages or len(records) != total:
        raise CollectionError("schedule list response count is inconsistent")

    for record in records:
        schedule_id = record.get("id")
        if not isinstance(schedule_id, str) or not schedule_id:
            raise CollectionError("schedule record is missing id")
        starts_at = _parse_source_datetime(record.get("startTime"), "startTime")
        ends_at = _parse_source_datetime(record.get("endTime"), "endTime")
        if ends_at < starts_at:
            raise CollectionError("schedule record ends before it starts")
        if not starts_at.date() <= selected_date <= ends_at.date():
            raise CollectionError("schedule record does not match the selected date")
    return SchedulePage(records=tuple(records), total=total)


def _is_young_app_url(url: str) -> bool:
    parsed = urlsplit(url)
    return (
        parsed.scheme == "https"
        and parsed.netloc == YOUNG_HOST
        and parsed.path.startswith(APP_PATH_PREFIX)
    )


def _is_my_schedule_url(url: str) -> bool:
    parsed = urlsplit(url)
    target = urlsplit(MY_SCHEDULE_URL)
    return (
        parsed.scheme == target.scheme
        and parsed.netloc == target.netloc
        and parsed.path == target.path
    )


def _open_schedule_after_login(
    page: Any,
    *,
    login_timeout_ms: int,
    status: Callable[[str], None],
    allow_interactive_login: bool = True,
    credentials: LoginCredentials | None = None,
    cancel_check: Callable[[], bool] | None = None,
) -> None:
    raise_if_cancelled(cancel_check)
    page.goto(MY_SCHEDULE_URL, wait_until="domcontentloaded")
    calendar_view = page.locator(CALENDAR_SELECTOR)
    deadline = time.monotonic() + max(login_timeout_ms, 0) / 1000
    last_schedule_navigation = time.monotonic()
    announced_login_wait = False
    login_filled = False

    while True:
        if calendar_view.is_visible():
            if credentials is not None:
                verify_ustc_account(page, credentials.username)
            return
        if not allow_interactive_login:
            raise UserActionRequired(
                "second-classroom login requires user action"
            )
        now = time.monotonic()
        if (
            _is_young_app_url(page.url)
            and not _is_my_schedule_url(page.url)
            and now - last_schedule_navigation
            >= SCHEDULE_REOPEN_INTERVAL_SECONDS
        ):
            status("Login completed; opening the signed-up schedule page ...")
            page.goto(MY_SCHEDULE_URL, wait_until="domcontentloaded")
            calendar_view = page.locator(CALENDAR_SELECTOR)
            last_schedule_navigation = time.monotonic()
            continue
        remaining_ms = int((deadline - now) * 1000)
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
        if (
            credentials is not None
            and not login_filled
            and is_ustc_cas_origin(page.url)
        ):
            fill_ustc_login(page, credentials)
            login_filled = True
        raise_if_cancelled(cancel_check)
        page.wait_for_timeout(min(250, remaining_ms))


def _month_number(value: date) -> int:
    return value.year * 12 + value.month - 1


def _move_calendar_month(page: Any, displayed: date, target: date) -> date:
    difference = _month_number(target) - _month_number(displayed)
    if difference == 0:
        return date(target.year, target.month, 1)
    selector = NEXT_MONTH_SELECTOR if difference > 0 else PREVIOUS_MONTH_SELECTOR
    arrow = page.locator(selector)
    if arrow.is_visible():
        for _ in range(abs(difference)):
            arrow.click()
        return date(target.year, target.month, 1)

    year_select = page.locator(YEAR_SELECT_SELECTOR)
    month_select = page.locator(MONTH_SELECT_SELECTOR)
    if not year_select.is_visible() or not month_select.is_visible():
        raise CollectionError("second-classroom calendar controls were not recognized")
    if displayed.year != target.year:
        year_select.click()
        page.locator(VISIBLE_OPTION_SELECTOR).filter(
            has_text=str(target.year)
        ).click()
    month_select = page.locator(MONTH_SELECT_SELECTOR)
    month_select.click()
    page.locator(VISIBLE_OPTION_SELECTOR).nth(target.month - 1).click()
    return date(target.year, target.month, 1)


def _capture_selected_date(
    page: Any,
    selected_date: date,
    *,
    timeout_ms: int,
) -> SchedulePage:
    cell = page.locator(date_cell_selector(selected_date))
    try:
        cell.wait_for(state="visible", timeout=timeout_ms)
    except PlaywrightTimeoutError as exc:
        raise CollectionError(
            f"schedule date {selected_date.isoformat()} calendar cell was not found"
        ) from exc
    try:
        with page.expect_response(is_schedule_list_response, timeout=timeout_ms) as info:
            cell.click()
    except PlaywrightTimeoutError as exc:
        raise CollectionError(
            f"schedule date {selected_date.isoformat()} did not return the expected response"
        ) from exc
    return parse_schedule_page(info.value, selected_date)


def _merge_records(
    records_by_id: dict[str, dict[str, Any]], records: tuple[dict[str, Any], ...]
) -> None:
    for record in records:
        schedule_id = record["id"]
        existing = records_by_id.get(schedule_id)
        if existing is not None and existing != record:
            raise CollectionError("conflicting duplicate schedule id")
        records_by_id.setdefault(schedule_id, record)


def collect_from_page(
    page: Any,
    *,
    today: date | None = None,
    queried_from: date | None = None,
    queried_through: date | None = None,
    login_timeout_ms: int = DEFAULT_LOGIN_TIMEOUT_MS,
    response_timeout_ms: int = DEFAULT_RESPONSE_TIMEOUT_MS,
    allow_interactive_login: bool = True,
    credentials: LoginCredentials | None = None,
    cancel_check: Callable[[], bool] | None = None,
    status: Callable[[str], None] = print,
) -> CollectedSchedules:
    current_date = today or beijing_today()
    default_start, default_end = query_window(current_date)
    start = queried_from or default_start
    end = queried_through or default_end
    dates = tuple(iter_dates(start, end))

    _open_schedule_after_login(
        page,
        login_timeout_ms=login_timeout_ms,
        status=status,
        allow_interactive_login=allow_interactive_login,
        credentials=credentials,
        cancel_check=cancel_check,
    )
    displayed_month = date(current_date.year, current_date.month, 1)
    displayed_month = _move_calendar_month(page, displayed_month, start)
    records_by_id: dict[str, dict[str, Any]] = {}
    empty_dates = 0
    date_checks: list[ScheduleDateCheck] = []

    for selected_date in dates:
        raise_if_cancelled(cancel_check)
        if (selected_date.year, selected_date.month) != (
            displayed_month.year,
            displayed_month.month,
        ):
            displayed_month = _move_calendar_month(
                page, displayed_month, selected_date
            )
        schedule_page = _capture_selected_date(
            page, selected_date, timeout_ms=response_timeout_ms
        )
        if not schedule_page.records:
            empty_dates += 1
        date_checks.append(
            ScheduleDateCheck(
                checked_date=selected_date,
                was_empty=not schedule_page.records,
            )
        )
        _merge_records(records_by_id, schedule_page.records)

    raise_if_cancelled(cancel_check)
    return CollectedSchedules(
        records=tuple(records_by_id.values()),
        queried_from=start,
        queried_through=end,
        queried_dates=len(dates),
        empty_dates=empty_dates,
        date_checks=tuple(date_checks),
    )


def collect_schedules(
    *,
    profile_dir: Path | None = None,
    account_id: str | None = None,
    today: date | None = None,
    queried_from: date | None = None,
    queried_through: date | None = None,
    login_timeout_ms: int = DEFAULT_LOGIN_TIMEOUT_MS,
    response_timeout_ms: int = DEFAULT_RESPONSE_TIMEOUT_MS,
    playwright_factory: Callable[[], Any] | None = None,
    allow_interactive_login: bool = True,
    credentials: LoginCredentials | None = None,
    cancel_check: Callable[[], bool] | None = None,
    status: Callable[[str], None] = print,
) -> CollectedSchedules:
    resolved_profile = profile_dir
    if resolved_profile is None and account_id is not None:
        resolved_profile = profile_dir_for_account(account_id)
    return run_in_edge(
        lambda page: collect_from_page(
            page,
            today=today,
            queried_from=queried_from,
            queried_through=queried_through,
            login_timeout_ms=login_timeout_ms,
            response_timeout_ms=response_timeout_ms,
            allow_interactive_login=allow_interactive_login,
            credentials=credentials,
            cancel_check=cancel_check,
            status=status,
        ),
        profile_dir=resolved_profile,
        headless=not allow_interactive_login,
        playwright_factory=playwright_factory,
    )


SOURCE_NAME = "ustc_young_my_schedule"


class _TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() == "br":
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() in {"p", "div", "li"}:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        self.parts.append(data)

    def text(self) -> str:
        lines = (line.strip() for line in "".join(self.parts).splitlines())
        return "\n".join(line for line in lines if line)


def _html_to_text(value: Any) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError("schedule content must be text")
    parser = _TextExtractor()
    parser.feed(value)
    parser.close()
    return parser.text()


def _normalize_source_datetime(value: Any, field: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"schedule {field} must be text")
    try:
        parsed = datetime.strptime(value, SOURCE_DATETIME_FORMAT)
    except ValueError as exc:
        raise ValueError(f"schedule {field} has invalid format") from exc
    return parsed.replace(tzinfo=BEIJING_TZ).isoformat()


def _require_text(record: dict[str, Any], field: str) -> str:
    value = record.get(field)
    if not isinstance(value, str) or not value:
        raise ValueError(f"schedule record is missing {field}")
    return value


def _require_all_day(record: dict[str, Any]) -> bool:
    value = record.get("allDay", False)
    if not isinstance(value, bool):
        raise ValueError("schedule allDay must be boolean")
    return value


def normalize_schedule_record(record: dict[str, Any]) -> dict[str, Any]:
    """Return the approved public fields of one registered schedule."""
    return {
        "sourceScheduleId": _require_text(record, "id"),
        "sourceActivityId": _require_text(record, "itemId"),
        "title": _require_text(record, "title"),
        "startsAt": _normalize_source_datetime(record.get("startTime"), "startTime"),
        "endsAt": _normalize_source_datetime(record.get("endTime"), "endTime"),
        "allDay": _require_all_day(record),
        "location": record.get("place"),
        "descriptionText": _html_to_text(record.get("content")),
    }


def normalize_schedules(
    collection: CollectedSchedules,
    *,
    collected_at: str | None = None,
) -> dict[str, Any]:
    timestamp = collected_at or datetime.now(BEIJING_TZ).isoformat(timespec="seconds")
    schedules = [normalize_schedule_record(record) for record in collection.records]
    return {
        "schemaVersion": "1.0",
        "source": SOURCE_NAME,
        "collectedAt": timestamp,
        "metadata": {
            "queriedFrom": collection.queried_from.isoformat(),
            "queriedThrough": collection.queried_through.isoformat(),
            "queriedDates": collection.queried_dates,
            "emptyDates": collection.empty_dates,
            "scheduleCount": len(schedules),
        },
        "schedules": schedules,
    }


def collect_schedule_snapshot(
    *,
    collect_fn: Callable[..., CollectedSchedules] = collect_schedules,
    collected_at: str | None = None,
    **collector_kwargs: Any,
) -> tuple[dict[str, Any], CollectedSchedules]:
    collection = collect_fn(**collector_kwargs)
    normalized = normalize_schedules(collection, collected_at=collected_at)
    return normalized, collection
