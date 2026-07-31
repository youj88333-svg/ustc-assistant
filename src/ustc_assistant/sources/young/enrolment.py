#!/usr/bin/env python3
"""Collect open USTC second-classroom activities from a browser session."""

from __future__ import annotations

import time
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo

from playwright.sync_api import TimeoutError as PlaywrightTimeoutError

from ustc_assistant.bridge.query_contracts import build_young_enrolment_envelope
from ustc_assistant.common.browser import (
    CollectionError,
    default_profile_dir,
    run_in_edge,
)
from ustc_assistant.common.auth import (
    CollectionCancelled,
    LoginCredentials,
    UserActionRequired,
    fill_ustc_login,
    is_ustc_cas_origin,
    profile_dir_for_account,
    raise_if_cancelled,
    verify_ustc_account,
)
from ustc_assistant.sources.young.schedule import _html_to_text


BEIJING_TZ = ZoneInfo("Asia/Shanghai")
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
# Bound for the plain-text rendering of enrolment HTML fields. The Query Result
# envelope rejects unbounded text; this cap keeps a malicious or oversized
# activity description from flooding the Agent context.
MAX_DESCRIPTION_TEXT_CHARS = 4000


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
    allow_interactive_login: bool = True,
    credentials: LoginCredentials | None = None,
    cancel_check: Callable[[], bool] | None = None,
) -> Any:
    raise_if_cancelled(cancel_check)
    page.goto(SIGN_UP_URL, wait_until="domcontentloaded")
    enrolment_tab = page.get_by_text("报名中", exact=True)
    deadline = time.monotonic() + max(login_timeout_ms, 0) / 1000
    last_sign_up_navigation = time.monotonic()
    reopened_after_login = False
    announced_login_wait = False
    login_filled = False

    while True:
        if enrolment_tab.is_visible():
            if credentials is not None:
                verify_ustc_account(page, credentials.username)
            return enrolment_tab

        if not allow_interactive_login:
            raise UserActionRequired(
                "second-classroom login requires user action"
            )

        now = time.monotonic()
        if (
            not reopened_after_login
            and _is_young_app_url(page.url)
            and not _is_sign_up_url(page.url)
            and now - last_sign_up_navigation >= 0.25
        ):
            status("Login completed; opening the open-activity page ...")
            page.goto(SIGN_UP_URL, wait_until="domcontentloaded")
            enrolment_tab = page.get_by_text("报名中", exact=True)
            reopened_after_login = True
            last_sign_up_navigation = time.monotonic()
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


def collect_from_page(
    page: Any,
    *,
    login_timeout_ms: int = DEFAULT_LOGIN_TIMEOUT_MS,
    response_timeout_ms: int = DEFAULT_RESPONSE_TIMEOUT_MS,
    allow_interactive_login: bool = True,
    credentials: LoginCredentials | None = None,
    cancel_check: Callable[[], bool] | None = None,
    status: Callable[[str], None] = print,
) -> CollectedEnrolmentActivities:
    enrolment_tab = _open_sign_up_after_login(
        page,
        login_timeout_ms=login_timeout_ms,
        status=status,
        allow_interactive_login=allow_interactive_login,
        credentials=credentials,
        cancel_check=cancel_check,
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
        raise_if_cancelled(cancel_check)
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

    raise_if_cancelled(cancel_check)
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
    account_id: str | None = None,
    login_timeout_ms: int = DEFAULT_LOGIN_TIMEOUT_MS,
    response_timeout_ms: int = DEFAULT_RESPONSE_TIMEOUT_MS,
    playwright_factory: Callable[[], Any] | None = None,
    allow_interactive_login: bool = True,
    credentials: LoginCredentials | None = None,
    cancel_check: Callable[[], bool] | None = None,
    status: Callable[[str], None] = print,
) -> CollectedEnrolmentActivities:
    resolved_profile = profile_dir
    if resolved_profile is None and account_id is not None:
        resolved_profile = profile_dir_for_account(account_id)
    return run_in_edge(
        lambda page: collect_from_page(
            page,
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


SOURCE_NAME = "ustc_young_enrolment_list"
NORMALIZED_FIELDS = {
    "id": "sourceActivityId",
    "itemName": "name",
    "itemStatus": "status",
    "itemStatus_dictText": "statusLabel",
    "module": "module",
    "module_dictText": "moduleLabel",
    "itemCategory": "category",
    "itemCategory_dictText": "categoryLabel",
    "activityLevel": "activityLevel",
    "activityLevel_dictText": "activityLevelLabel",
    "organizer_dictText": "organizerLabel",
    "sponsor_dictText": "sponsorLabel",
    "businessDeptName": "businessDepartment",
    "st": "startsAt",
    "et": "endsAt",
    "applySt": "applicationStartsAt",
    "applyEt": "applicationEndsAt",
    "itemLimitNum": "capacity",
    "applyNum": "appliedCount",
    "partakeNum": "participantCount",
    "placeInfo": "location",
    "form": "form",
    "form_dictText": "formLabel",
    "serviceHour": "serviceHours",
    "validHour": "validHours",
    "pic": "imagePath",
}


def _bounded_text(value: Any) -> str | None:
    """Convert an HTML enrolment field to bounded plain text.

    Reuses schedule._html_to_text so HTML-to-text rules stay in one place,
    then truncates to MAX_DESCRIPTION_TEXT_CHARS so a prompt-injection payload
    cannot flood the Agent context with unbounded text. The Query Result
    envelope validator separately rejects raw HTML.
    """
    if value is None:
        return None
    text = _html_to_text(value)
    if text is None:
        return None
    if len(text) > MAX_DESCRIPTION_TEXT_CHARS:
        return text[:MAX_DESCRIPTION_TEXT_CHARS]
    return text


def _normalize_record(record: dict[str, Any]) -> dict[str, Any]:
    normalized = {
        normalized_name: record.get(source_name)
        for source_name, normalized_name in NORMALIZED_FIELDS.items()
    }
    # Convert raw HTML enrolment fields to bounded plain text so the Agent
    # never receives raw HTML or unbounded text. The source fields
    # baseContent/conceive are intentionally NOT exposed under their original
    # HTML names to avoid smuggling markup into the Agent context.
    normalized["descriptionText"] = _bounded_text(record.get("baseContent"))
    normalized["requirementsText"] = _bounded_text(record.get("conceive"))
    return normalized


def normalize_enrolments(
    collection: CollectedEnrolmentActivities,
    *,
    collected_at: str | None = None,
) -> dict[str, Any]:
    timestamp = collected_at or datetime.now(BEIJING_TZ).isoformat(timespec="seconds")
    activities = [_normalize_record(record) for record in collection.records]
    return {
        "schemaVersion": "1.0",
        "source": SOURCE_NAME,
        "collectedAt": timestamp,
        "metadata": {
            "reportedTotal": collection.reported_total,
            "pages": collection.pages,
            "activityCount": len(activities),
        },
        "activities": activities,
    }


def build_young_query_result(snapshot: Mapping[str, Any]) -> dict[str, Any]:
    activities = [
        {
            "name": item.get("name"),
            "category": item.get("category"),
            "status": item.get("status"),
            "capacity": item.get("capacity"),
            "appliedCount": item.get("appliedCount"),
        }
        for item in snapshot.get("activities", [])
    ]
    return build_young_enrolment_envelope(
        data={"activities": activities},
        metadata={
            "reportedTotal": snapshot.get("metadata", {}).get("reportedTotal", 0),
            "activityCount": len(activities),
        },
        generated_at=snapshot.get("collectedAt"),
    )


collect_enrolments = collect_activities


def collect_enrolment_snapshot(
    *,
    collect_fn: Callable[..., CollectedEnrolmentActivities] = collect_enrolments,
    collected_at: str | None = None,
    **collector_kwargs: Any,
) -> tuple[dict[str, Any], CollectedEnrolmentActivities]:
    collection = collect_fn(**collector_kwargs)
    normalized = normalize_enrolments(collection, collected_at=collected_at)
    return normalized, collection
