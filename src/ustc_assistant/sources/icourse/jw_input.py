"""Read JW course groups from formal or legacy local snapshots."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from ustc_assistant.contracts import validate_source_bundle


def _normalized_text(value: Any) -> str:
    return re.sub(r"\s+", "", str(value or "")).casefold()


def _participants(value: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    participants = value.get("participants")
    if isinstance(participants, Mapping):
        return [participants]
    if isinstance(participants, list):
        return [item for item in participants if isinstance(item, Mapping)]
    return []


def _teacher_names(value: Mapping[str, Any]) -> tuple[str, ...]:
    names = {
        str(item.get("name")).strip()
        for item in _participants(value)
        if item.get("role") == "teacher"
        and isinstance(item.get("name"), str)
        and item.get("name").strip()
    }
    return tuple(sorted(names, key=str.casefold))


@dataclass(frozen=True)
class JwCourseGroup:
    source_lesson_id: str | None
    title: str
    course_code: str | None
    teachers: tuple[str, ...]
    occurrence_count: int

    def as_dict(self) -> dict[str, Any]:
        return {
            "sourceLessonId": self.source_lesson_id,
            "title": self.title,
            "courseCode": self.course_code,
            "teachers": list(self.teachers),
            "occurrenceCount": self.occurrence_count,
        }


def _sort_groups(groups: list[JwCourseGroup]) -> list[JwCourseGroup]:
    return sorted(
        groups,
        key=lambda item: (
            _normalized_text(item.title),
            tuple(map(_normalized_text, item.teachers)),
            item.source_lesson_id or "",
        ),
    )


def _formal_course_groups(bundle: Mapping[str, Any]) -> list[JwCourseGroup]:
    validate_source_bundle(bundle)
    if bundle.get("source") != "ustc_jw":
        raise ValueError("JW SourceBundle must use source ustc_jw")

    data = bundle["data"]
    course_events = [
        event
        for event in data["calendarEvents"]
        if event.get("eventType") == "course"
    ]
    occurrence_counts: dict[str, int] = {}
    for event in course_events:
        series_id = event.get("seriesExternalId")
        if isinstance(series_id, str):
            occurrence_counts[series_id] = occurrence_counts.get(series_id, 0) + 1

    groups: list[JwCourseGroup] = []
    for series in data["courseSeries"]:
        title = str(series.get("title") or "").strip()
        if not title:
            raise ValueError("JW course series is missing title")
        details = (
            series.get("sourceDetails")
            if isinstance(series.get("sourceDetails"), Mapping)
            else {}
        )
        lesson_id = details.get("lessonId")
        course_code = str(series.get("courseCode") or "").strip() or None
        groups.append(
            JwCourseGroup(
                source_lesson_id=(
                    str(lesson_id) if lesson_id is not None else None
                ),
                title=title,
                course_code=course_code,
                teachers=_teacher_names(series),
                occurrence_count=occurrence_counts.get(series["externalId"], 0),
            )
        )
    return _sort_groups(groups)


def load_legacy_jw_course_groups(
    payload: Mapping[str, Any],
) -> list[JwCourseGroup]:
    """Read the single supported pre-SourceBundle JW snapshot shape."""
    events = payload.get("calendarEvents")
    if not isinstance(events, list):
        raise ValueError(
            "legacy JW input must contain a calendarEvents list"
        )

    groups: dict[tuple[Any, ...], JwCourseGroup] = {}
    for event in events:
        if not isinstance(event, Mapping) or event.get("type") != "course":
            continue
        metadata = (
            event.get("metadata")
            if isinstance(event.get("metadata"), Mapping)
            else {}
        )
        title = str(event.get("title") or "").strip()
        if not title:
            raise ValueError("legacy JW course event is missing title")
        teachers = _teacher_names(event)
        lesson_id = metadata.get("lessonId")
        source_lesson_id = (
            str(lesson_id) if lesson_id is not None else None
        )
        course_code = str(metadata.get("courseCode") or "").strip() or None
        key = (
            source_lesson_id or "",
            _normalized_text(course_code),
            _normalized_text(title),
            tuple(map(_normalized_text, teachers)),
        )
        existing = groups.get(key)
        groups[key] = JwCourseGroup(
            source_lesson_id=source_lesson_id,
            title=title,
            course_code=course_code,
            teachers=teachers,
            occurrence_count=(
                1 if existing is None else existing.occurrence_count + 1
            ),
        )
    return _sort_groups(list(groups.values()))


def course_groups_from_payload(
    payload: Mapping[str, Any],
) -> list[JwCourseGroup]:
    if not isinstance(payload, Mapping):
        raise ValueError("JW input root must be an object")
    if any(
        key in payload
        for key in ("schemaVersion", "bundleId", "subject", "snapshot", "data")
    ):
        return _formal_course_groups(payload)
    if "calendarEvents" in payload:
        return load_legacy_jw_course_groups(payload)
    raise ValueError("JW input is neither SourceBundle 1.0 nor legacy format")


def load_jw_course_groups(path: Path) -> list[JwCourseGroup]:
    with Path(path).open("r", encoding="utf-8") as file:
        payload = json.load(file)
    if not isinstance(payload, dict):
        raise ValueError("JW input root must be an object")
    return course_groups_from_payload(payload)
