"""Produce canonical SourceBundle 1.0 snapshots for registered schedules."""

from __future__ import annotations

from datetime import date, datetime, timedelta
from typing import Any, Callable
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo

from ustc_assistant.contracts import make_bundle_envelope, validate_source_bundle
from ustc_assistant.common.auth import raise_if_cancelled
from ustc_assistant.sources.young import schedule


BEIJING_TZ = ZoneInfo("Asia/Shanghai")
SOURCE = schedule.SOURCE_NAME
PRODUCER = {
    "name": "ustc_assistant_python",
    "version": "0.1.0",
    "platform": "windows",
}


def _collected_at_text(collected_at: datetime | None) -> str:
    timestamp = collected_at or datetime.now(BEIJING_TZ)
    if timestamp.utcoffset() is None:
        raise ValueError("collected_at must include a timezone")
    return (
        timestamp.astimezone(BEIJING_TZ)
        .replace(microsecond=0)
        .isoformat(timespec="seconds")
    )


def _complete_window_scope(
    collection: schedule.CollectedSchedules,
) -> dict[str, Any]:
    queried_from = collection.queried_from
    queried_through = collection.queried_through
    if (
        not isinstance(queried_from, date)
        or not isinstance(queried_through, date)
        or queried_from > queried_through
    ):
        raise ValueError("schedule collection has an invalid date window")
    expected_date_count = (queried_through - queried_from).days + 1
    expected_dates = tuple(schedule.iter_dates(queried_from, queried_through))
    checks = collection.date_checks
    if (
        not isinstance(collection.queried_dates, int)
        or isinstance(collection.queried_dates, bool)
        or collection.queried_dates != expected_date_count
        or collection.queried_dates != len(checks)
    ):
        raise ValueError("schedule collection is not a complete date window")
    if any(
        not isinstance(check, schedule.ScheduleDateCheck)
        or not isinstance(check.was_empty, bool)
        for check in checks
    ) or tuple(check.checked_date for check in checks) != expected_dates:
        raise ValueError("schedule collection is not a complete date window")
    observed_empty_dates = sum(check.was_empty for check in checks)
    if not isinstance(collection.empty_dates, int) or isinstance(
        collection.empty_dates, bool
    ) or collection.empty_dates != observed_empty_dates:
        raise ValueError("schedule collection has an invalid empty date count")
    return {
        "type": "date_window",
        "fromDate": queried_from.isoformat(),
        "throughDate": queried_through.isoformat(),
        "timezone": "Asia/Shanghai",
        "expectedDateCount": expected_date_count,
        "checkedDateCount": collection.queried_dates,
        "emptyDateCount": collection.empty_dates,
    }


def _source_record(event_external_id: str, schedule_id: str) -> dict[str, Any]:
    return {
        "externalId": f"{SOURCE}:record:schedule:{schedule_id}",
        "recordType": "young_registered_schedule",
        "entityType": "calendar_event",
        "entityExternalId": event_external_id,
        "sourceStatus": "active",
        "sourceUpdatedAt": None,
    }


def _event(
    normalized: dict[str, Any], *, from_date: date, through_date: date
) -> dict[str, Any]:
    starts_at = datetime.fromisoformat(normalized["startsAt"])
    if not from_date <= starts_at.date() <= through_date:
        raise ValueError("schedule record is outside the complete date window")
    location = normalized["location"]
    if location is not None and not isinstance(location, str):
        raise ValueError("schedule location must be text")
    schedule_id = normalized["sourceScheduleId"]
    if normalized["allDay"]:
        event_time: dict[str, str] = {
            "kind": "all_day",
            "startDate": starts_at.date().isoformat(),
            "endDateExclusive": (
                datetime.fromisoformat(normalized["endsAt"]).date()
                + timedelta(days=1)
            ).isoformat(),
            "timezone": "Asia/Shanghai",
        }
    else:
        event_time = {
            "kind": "timed",
            "startAt": normalized["startsAt"],
            "endAt": normalized["endsAt"],
            "timezone": "Asia/Shanghai",
        }
    return {
        "externalId": f"{SOURCE}:event:schedule:{schedule_id}",
        "seriesExternalId": None,
        "title": normalized["title"],
        "descriptionText": normalized["descriptionText"],
        "eventType": "second_class",
        "time": event_time,
        "location": {
            "name": location,
            "building": None,
            "campus": None,
        },
        "participants": [],
        "sourceDefaults": {
            "importance": "normal",
            "attendancePolicy": "must_go",
            "listeningMode": "unknown",
        },
        "sourceDetails": {
            "kind": "young_registered_schedule",
            "sourceActivityId": normalized["sourceActivityId"],
        },
    }


def build_young_schedule_source_bundle(
    collection: schedule.CollectedSchedules,
    *,
    account_id: str,
    bundle_id: UUID | None = None,
    collected_at: datetime | None = None,
    cancel_check: Callable[[], bool] | None = None,
) -> dict[str, Any]:
    """Build and validate one complete registered-schedule window."""
    raise_if_cancelled(cancel_check)
    scope = _complete_window_scope(collection)
    from_date = collection.queried_from
    through_date = collection.queried_through
    seen_schedule_ids: set[str] = set()
    events: list[dict[str, Any]] = []
    records: list[dict[str, Any]] = []
    for raw_record in collection.records:
        raise_if_cancelled(cancel_check)
        normalized = schedule.normalize_schedule_record(raw_record)
        schedule_id = normalized["sourceScheduleId"]
        if schedule_id in seen_schedule_ids:
            raise ValueError("schedule collection has a duplicate schedule identity")
        seen_schedule_ids.add(schedule_id)
        event = _event(
            normalized, from_date=from_date, through_date=through_date
        )
        events.append(event)
        records.append(_source_record(event["externalId"], schedule_id))

    raise_if_cancelled(cancel_check)
    bundle = make_bundle_envelope(
        bundle_id=str(bundle_id or uuid4()),
        source=SOURCE,
        account_id=account_id,
        collected_at=_collected_at_text(collected_at),
        snapshot={"completeness": "complete", "scope": scope},
        data={
            "sourceRecords": records,
            "calendarEvents": events,
            "courseSeries": [],
            "scheduleRelations": [],
        },
        producer=PRODUCER,
    )
    validate_source_bundle(bundle)
    return bundle


def collect_young_schedule_source_bundle(
    *,
    account_id: str,
    collect_fn: Callable[..., schedule.CollectedSchedules] = schedule.collect_schedules,
    bundle_id: UUID | None = None,
    collected_at: datetime | None = None,
    **collector_kwargs: Any,
) -> tuple[dict[str, Any], schedule.CollectedSchedules]:
    """Collect and convert one complete registered-schedule window."""
    collection = collect_fn(account_id=account_id, **collector_kwargs)
    cancel_check = collector_kwargs.get("cancel_check")
    raise_if_cancelled(cancel_check)
    return (
        build_young_schedule_source_bundle(
            collection,
            account_id=account_id,
            bundle_id=bundle_id,
            collected_at=collected_at,
            cancel_check=cancel_check,
        ),
        collection,
    )
