"""Produce canonical SourceBundle 1.0 snapshots from complete JW captures."""

from __future__ import annotations

from collections import defaultdict
from datetime import datetime
from typing import Any
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo

from ustc_assistant.config import JwSemesterConfig
from ustc_assistant.contracts import make_bundle_envelope, validate_source_bundle
from ustc_assistant.sources.jw import course, exam


BEIJING_TZ = ZoneInfo("Asia/Shanghai")
SOURCE = "ustc_jw"
PRODUCER = {
    "name": "ustc_assistant_python",
    "version": "0.1.0",
    "platform": "windows",
}


def _public_participants(
    rows: list[dict[str, Any]],
) -> list[dict[str, str]]:
    participants: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for participant in course.unique_participants(rows):
        public = ("teacher", str(participant["name"]))
        if public in seen:
            continue
        seen.add(public)
        participants.append({"role": public[0], "name": public[1]})
    return participants


def _series_external_id(semester_key: str, lesson_id: int) -> str:
    return f"{SOURCE}:{semester_key}:series:lesson:{lesson_id}"


def _record(
    *,
    external_id: str,
    record_type: str,
    entity_type: str,
    entity_external_id: str,
) -> dict[str, Any]:
    return {
        "externalId": external_id,
        "recordType": record_type,
        "entityType": entity_type,
        "entityExternalId": entity_external_id,
        "sourceStatus": "active",
        "sourceUpdatedAt": None,
    }


def _require_course_result(
    course_datum: dict[str, Any],
) -> dict[str, Any]:
    if not isinstance(course_datum, dict):
        raise ValueError("course datum must be an object")
    result = course_datum.get("result")
    if not isinstance(result, dict):
        raise ValueError("course datum is missing a complete result")
    for name in ("lessonList", "scheduleGroupList", "scheduleList"):
        if not isinstance(result.get(name), list):
            raise ValueError(f"course datum result requires list {name!r}")
    return result


def _build_course_data(
    result: dict[str, Any], semester_key: str
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    lesson_map, group_map = course.build_maps(result)
    grouped_rows = course.group_schedule_rows(result["scheduleList"])
    rows_by_lesson: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for rows in grouped_rows:
        row = rows[0]
        lesson_id = int(row["lessonId"])
        group_id = int(row["scheduleGroupId"])
        if lesson_id not in lesson_map:
            raise ValueError(
                f"course schedule references unknown lesson {lesson_id}"
            )
        if group_id not in group_map:
            raise ValueError(
                f"course schedule references unknown group {group_id}"
            )
        rows_by_lesson[lesson_id].extend(rows)

    series: list[dict[str, Any]] = []
    records: list[dict[str, Any]] = []
    for lesson_id, lesson in lesson_map.items():
        external_id = _series_external_id(semester_key, lesson_id)
        series.append(
            {
                "externalId": external_id,
                "title": lesson.get("courseName")
                or f"未知课程 {lesson_id}",
                "courseCode": lesson.get("code") or None,
                "semesterKey": semester_key,
                "participants": _public_participants(
                    rows_by_lesson.get(lesson_id, [])
                ),
                "sourceDetails": {
                    "kind": "jw_course_series",
                    "lessonId": str(lesson_id),
                },
            }
        )
        records.append(
            _record(
                external_id=(
                    f"{SOURCE}:{semester_key}:record:"
                    f"course-series:lesson:{lesson_id}"
                ),
                record_type="jw_course_series",
                entity_type="course_series",
                entity_external_id=external_id,
            )
        )

    events: list[dict[str, Any]] = []
    for rows in grouped_rows:
        row = rows[0]
        lesson_id = int(row["lessonId"])
        group_id = int(row["scheduleGroupId"])
        lesson = lesson_map[lesson_id]
        start_time = course.hhmm(row["startTime"])
        end_time = course.hhmm(row["endTime"])
        date_token = str(row["date"]).replace("-", "")
        discriminator = course.collision_discriminator(row)
        identity_tail = (
            f"{lesson_id}:{group_id}:{date_token}:"
            f"{start_time}:{end_time}:{discriminator}"
        )
        external_id = (
            f"{SOURCE}:{semester_key}:event:"
            f"course-occurrence:{identity_tail}"
        )
        location, building, campus, _ = course.room_parts(row)
        events.append(
            {
                "externalId": external_id,
                "seriesExternalId": _series_external_id(
                    semester_key, lesson_id
                ),
                "title": lesson.get("courseName")
                or f"未知课程 {lesson_id}",
                "descriptionText": None,
                "eventType": "course",
                "time": {
                    "kind": "timed",
                    "startAt": course.iso_datetime(
                        row["date"], row["startTime"]
                    ),
                    "endAt": course.iso_datetime(
                        row["date"], row["endTime"]
                    ),
                    "timezone": course.TIMEZONE,
                },
                "location": {
                    "name": location,
                    "building": building,
                    "campus": campus,
                },
                "participants": _public_participants(rows),
                "sourceDefaults": {
                    "importance": "normal",
                    "attendancePolicy": "unknown",
                    "listeningMode": "unknown",
                },
                "sourceDetails": {
                    "kind": "jw_course_occurrence",
                    "semesterKey": semester_key,
                    "lessonId": str(lesson_id),
                    "scheduleGroupId": str(group_id),
                    "courseCode": lesson.get("code") or None,
                    "courseTypeName": lesson.get("courseTypeName") or None,
                    "weekIndex": int(row["weekIndex"]),
                    "periods": int(row["periods"]),
                    "exerciseClass": bool(row.get("exerciseClass")),
                },
            }
        )
        records.append(
            _record(
                external_id=(
                    f"{SOURCE}:{semester_key}:record:"
                    f"course-occurrence:{identity_tail}"
                ),
                record_type="jw_course_occurrence",
                entity_type="calendar_event",
                entity_external_id=external_id,
            )
        )

    return series, events, records


def _build_exam_data(
    exam_html: str,
    semester_key: str,
    series: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    exam_rows = exam.parse_exam_rows(exam_html)
    series_by_code: dict[str, list[str]] = defaultdict(list)
    for item in series:
        course_code = item["courseCode"]
        if course_code:
            series_by_code[course_code].append(item["externalId"])

    events: list[dict[str, Any]] = []
    records: list[dict[str, Any]] = []
    seen: set[str] = set()
    for row_number, row in enumerate(exam_rows, start=1):
        start_at, end_at = exam.parse_exam_time(row.date_time, row_number)
        identity_hash = course.stable_hash(
            [
                row.course_code,
                row.exam_type,
                start_at,
                end_at,
                row.room,
                row.building,
                row.campus,
            ]
        )
        identity_tail = f"{row.course_code}:{identity_hash}"
        external_id = (
            f"{SOURCE}:{semester_key}:event:exam:{identity_tail}"
        )
        if external_id in seen:
            raise ValueError(f"exam row {row_number}: duplicate exam identity")
        seen.add(external_id)
        matching_series = series_by_code.get(row.course_code, [])
        series_external_id = (
            matching_series[0] if len(matching_series) == 1 else None
        )
        events.append(
            {
                "externalId": external_id,
                "seriesExternalId": series_external_id,
                "title": row.course_name,
                "descriptionText": row.note or None,
                "eventType": "exam",
                "time": {
                    "kind": "timed",
                    "startAt": start_at,
                    "endAt": end_at,
                    "timezone": exam.TIMEZONE,
                },
                "location": {
                    "name": row.room,
                    "building": row.building,
                    "campus": row.campus,
                },
                "participants": [],
                "sourceDefaults": {
                    "importance": "critical",
                    "attendancePolicy": "must_go",
                    "listeningMode": "unknown",
                },
                "sourceDetails": {
                    "kind": "jw_exam",
                    "semesterKey": semester_key,
                    "classroomNumber": row.room,
                    "examType": row.exam_type,
                    "courseCode": row.course_code or None,
                    "instructions": row.note or None,
                },
            }
        )
        records.append(
            _record(
                external_id=(
                    f"{SOURCE}:{semester_key}:record:exam:{identity_tail}"
                ),
                record_type="jw_exam",
                entity_type="calendar_event",
                entity_external_id=external_id,
            )
        )
    return events, records


def _collected_at_text(collected_at: datetime | None) -> str:
    timestamp = collected_at or datetime.now(BEIJING_TZ)
    if timestamp.utcoffset() is None:
        raise ValueError("collected_at must include a timezone")
    return (
        timestamp.astimezone(BEIJING_TZ)
        .replace(microsecond=0)
        .isoformat(timespec="seconds")
    )


def build_jw_source_bundle(
    course_datum: dict[str, Any],
    exam_html: str,
    *,
    account_id: str,
    semester: JwSemesterConfig,
    bundle_id: UUID | None = None,
    collected_at: datetime | None = None,
) -> dict[str, Any]:
    """Build and validate one complete JW semester snapshot."""
    result = _require_course_result(course_datum)
    series, course_events, course_records = _build_course_data(
        result, semester.semester_key
    )
    exam_events, exam_records = _build_exam_data(
        exam_html, semester.semester_key, series
    )
    data = {
        "sourceRecords": [*course_records, *exam_records],
        "calendarEvents": [*course_events, *exam_events],
        "courseSeries": series,
        "scheduleRelations": [],
    }
    snapshot = {
        "completeness": "complete",
        "scope": {
            "type": "semester",
            "semesterKey": semester.semester_key,
            "sourceSemesterId": semester.semester_id,
            "components": [
                {
                    "name": "course_table",
                    "status": "complete",
                    "observedRecordCount": len(course_records),
                },
                {
                    "name": "exam_arrange",
                    "status": "complete",
                    "observedRecordCount": len(exam_records),
                },
            ],
        },
    }
    bundle = make_bundle_envelope(
        bundle_id=str(bundle_id or uuid4()),
        source=SOURCE,
        account_id=account_id,
        collected_at=_collected_at_text(collected_at),
        snapshot=snapshot,
        data=data,
        producer=PRODUCER,
    )
    validate_source_bundle(bundle)
    return bundle
