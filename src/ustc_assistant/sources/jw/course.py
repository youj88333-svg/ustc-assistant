#!/usr/bin/env python3
"""Convert USTC JW course-table datum JSON into project calendar events.

This is a small prototype script for validating the data model. It intentionally
uses only Python's standard library so it can run before the project stack is
chosen.
"""

from __future__ import annotations

import hashlib
import json
from collections import Counter, OrderedDict
from datetime import datetime
from typing import Any


TZ_OFFSET = "+08:00"
TIMEZONE = "Asia/Shanghai"
SOURCE = "ustc_jw"
SOURCE_SYSTEM = "jw.ustc.edu.cn"


def hhmm(value: Any) -> str:
    text = str(value)
    if not text.isdigit():
        raise ValueError(f"Invalid HHmm value: {value!r}")
    return text.zfill(4)


def iso_datetime(date_text: str, time_value: Any) -> str:
    time_text = hhmm(time_value)
    hour = time_text[:2]
    minute = time_text[2:]
    # Validate date/time while preserving the +08:00 string in output.
    datetime.strptime(f"{date_text} {hour}:{minute}", "%Y-%m-%d %H:%M")
    return f"{date_text}T{hour}:{minute}:00{TZ_OFFSET}"


def room_code(row: dict[str, Any]) -> str | None:
    room = row.get("room") or {}
    return room.get("code")


def _normalized_identity_text(value: Any) -> str:
    if value is None:
        return ""
    return " ".join(str(value).split())


def place_key(row: dict[str, Any]) -> str:
    code = room_code(row)
    if code:
        return code
    room = row.get("room")
    if room:
        building = room.get("building") or {}
        campus = building.get("campus") or {}
        location_parts = [
            _normalized_identity_text(room.get("nameZh")),
            _normalized_identity_text(building.get("nameZh")),
            _normalized_identity_text(campus.get("nameZh")),
        ]
        if any(location_parts):
            return json.dumps(
                ["room", *location_parts],
                ensure_ascii=False,
                separators=(",", ":"),
            )
    return row.get("customPlace") or "unknown-place"


def exercise_key(row: dict[str, Any]) -> str:
    value = row.get("exerciseClass")
    if value is None or value is False or value == "":
        return "none"
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def merge_key(row: dict[str, Any]) -> tuple[Any, ...]:
    return (
        row.get("lessonId"),
        row.get("scheduleGroupId"),
        row.get("date"),
        row.get("startTime"),
        row.get("endTime"),
        place_key(row),
        exercise_key(row),
    )


def build_maps(result: dict[str, Any]) -> tuple[dict[int, dict[str, Any]], dict[int, dict[str, Any]]]:
    lesson_map = {int(item["id"]): item for item in result.get("lessonList", [])}
    group_map = {int(item["id"]): item for item in result.get("scheduleGroupList", [])}
    return lesson_map, group_map


def group_schedule_rows(rows: list[dict[str, Any]]) -> list[list[dict[str, Any]]]:
    grouped: OrderedDict[tuple[Any, ...], list[dict[str, Any]]] = OrderedDict()
    for row in rows:
        grouped.setdefault(merge_key(row), []).append(row)
    return list(grouped.values())


def unique_participants(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    seen: set[tuple[Any, Any, str]] = set()
    participants: list[dict[str, Any]] = []
    for row in rows:
        name = row.get("personName")
        if not name:
            continue
        key = (row.get("teacherId"), row.get("personId"), str(name))
        if key in seen:
            continue
        seen.add(key)
        participants.append(
            {
                "role": "teacher",
                "name": name,
                "teacherId": row.get("teacherId"),
                "personId": row.get("personId"),
            }
        )
    return participants


def room_parts(row: dict[str, Any]) -> tuple[str | None, str | None, str | None, bool | None]:
    room = row.get("room")
    if room:
        building = room.get("building") or {}
        campus = building.get("campus") or {}
        return (
            room.get("nameZh") or room.get("code"),
            building.get("nameZh"),
            campus.get("nameZh"),
            room.get("virtual"),
        )
    custom_place = row.get("customPlace")
    if custom_place:
        return custom_place, None, None, None
    return None, None, None, None


def is_experiment(lesson: dict[str, Any], row: dict[str, Any]) -> bool:
    course_type = lesson.get("courseTypeName") or ""
    return bool(row.get("experiment")) or row.get("lessonType") == "experiment" or "实验" in course_type


def initial_tags(lesson: dict[str, Any], row: dict[str, Any], room_virtual: bool | None) -> list[str]:
    tags = ["course"]
    course_type = lesson.get("courseTypeName")
    if course_type:
        tags.append(str(course_type))
    if is_experiment(lesson, row):
        tags.append("experiment")
    if room_virtual:
        tags.append("virtual_room")
    if not row.get("room") and row.get("customPlace"):
        tags.append("custom_place")
    # Preserve order while removing duplicates.
    return list(dict.fromkeys(tags))


def default_policy(lesson: dict[str, Any], row: dict[str, Any]) -> dict[str, Any]:
    if is_experiment(lesson, row):
        return {
            "attendancePolicy": "must_go",
            "attendanceDecision": "go",
            "attendanceDecisionAt": None,
            "attendanceNote": "实验课，默认应到场",
            "attendanceOutcome": "unknown",
            "listeningMode": "listen",
            "listeningNote": "实验课需要操作",
        }
    return {
        "attendancePolicy": "unknown",
        "attendanceDecision": "undecided",
        "attendanceDecisionAt": None,
        "attendanceNote": None,
        "attendanceOutcome": "unknown",
        "listeningMode": "unknown",
        "listeningNote": None,
    }


def external_id(semester_key: str, row: dict[str, Any]) -> str:
    return (
        f"{SOURCE}:{semester_key}:{row.get('lessonId')}:{row.get('scheduleGroupId')}:"
        f"{row.get('date')}:{hhmm(row.get('startTime'))}:{hhmm(row.get('endTime'))}"
    )


def event_id(external: str) -> str:
    return "event_" + external.replace(":", "_").replace("-", "")


def source_id(external: str) -> str:
    return "source_" + external.replace(":", "_").replace("-", "")


def stable_hash(parts: list[Any]) -> str:
    payload = "|".join("" if part is None else str(part) for part in parts)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:24]


def collision_discriminator(row: dict[str, Any]) -> str:
    return stable_hash([place_key(row), exercise_key(row)])


def convert_group(
    rows: list[dict[str, Any]],
    lesson_map: dict[int, dict[str, Any]],
    group_map: dict[int, dict[str, Any]],
    semester_key: str,
    user_id: str,
    resolved_external_id: str | None = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    row = rows[0]
    lesson_id = int(row["lessonId"])
    group_id = int(row["scheduleGroupId"])
    lesson = lesson_map.get(lesson_id, {})
    group = group_map.get(group_id, {})
    location, building, campus, room_virtual = room_parts(row)
    ext_id = resolved_external_id or external_id(semester_key, row)
    policy = default_policy(lesson, row)
    tags = initial_tags(lesson, row, room_virtual)
    confidence = "high"
    if row.get("room") is None and row.get("customPlace"):
        confidence = "medium"
    elif row.get("room") is None:
        confidence = "low"

    event = {
        "id": event_id(ext_id),
        "userId": user_id,
        "title": lesson.get("courseName") or f"未知课程 {lesson_id}",
        "type": "course",
        "status": "active",
        "startAt": iso_datetime(row["date"], row["startTime"]),
        "endAt": iso_datetime(row["date"], row["endTime"]),
        "timezone": TIMEZONE,
        "locationName": location,
        "buildingName": building,
        "campusName": campus,
        "source": SOURCE,
        "sourceRecordId": source_id(ext_id),
        "externalId": ext_id,
        "confidence": confidence,
        "importance": "normal",
        **policy,
        "tags": tags,
        "participants": unique_participants(rows),
        "metadata": {
            "lessonId": lesson_id,
            "scheduleGroupId": group_id,
            "courseCode": lesson.get("code"),
            "courseTypeName": lesson.get("courseTypeName"),
            "weekIndex": row.get("weekIndex"),
            "weekday": row.get("weekday"),
            "periods": row.get("periods"),
            "roomVirtual": room_virtual,
            "exerciseClass": row.get("exerciseClass"),
            "mergedScheduleRows": len(rows),
            "scheduleGroup": {
                "limitCount": group.get("limitCount"),
                "stdCount": group.get("stdCount"),
                "actualPeriods": group.get("actualPeriods"),
            },
        },
    }

    fingerprint = stable_hash(
        [
            SOURCE,
            lesson_id,
            group_id,
            row.get("date"),
            hhmm(row.get("startTime")),
            hhmm(row.get("endTime")),
            place_key(row),
            exercise_key(row),
        ]
    )
    source = {
        "id": source_id(ext_id),
        "userId": user_id,
        "source": SOURCE,
        "sourceSystem": SOURCE_SYSTEM,
        "sourceType": "jw_course_schedule",
        "externalId": ext_id,
        "fingerprint": fingerprint,
        "rawSummary": (
            f"lessonId={lesson_id}, scheduleGroupId={group_id}, "
            f"{len(rows)} raw row(s) merged"
        ),
        "status": "active",
    }
    return event, source


def parse_iso(value: str) -> datetime:
    return datetime.fromisoformat(value)


def overlaps(a: dict[str, Any], b: dict[str, Any]) -> bool:
    return parse_iso(a["startAt"]) < parse_iso(b["endAt"]) and parse_iso(b["startAt"]) < parse_iso(a["endAt"])


def relation_for_pair(a: dict[str, Any], b: dict[str, Any], user_id: str, index: int) -> dict[str, Any]:
    relation_type = "alternative_choice"
    conflict_state = "conflict"
    resolution = "ask_user"
    reason = "两个课程时间重叠，且均未设置不去或不听讲"

    if a.get("attendancePolicy") == "skip" or b.get("attendancePolicy") == "skip":
        relation_type = "replacement"
        conflict_state = "non_conflict"
        resolution = "allow_both"
        reason = "至少一个事件标记为不去，时间重叠不一定构成冲突"
    elif a.get("listeningMode") == "not_listen" or b.get("listeningMode") == "not_listen":
        relation_type = "soft_warning"
        conflict_state = "non_conflict"
        resolution = "allow_both"
        reason = "至少一个事件标记为不听讲，可作为嵌入学习或其他安排的候选"
    elif a.get("attendancePolicy") == "must_go" and b.get("attendancePolicy") == "must_go":
        reason = "两个必去事件时间重叠，需要用户处理"

    return {
        "id": f"relation_overlap_{index:03d}",
        "userId": user_id,
        "primaryType": "calendar_event",
        "primaryId": a["id"],
        "relatedType": "calendar_event",
        "relatedId": b["id"],
        "relationType": relation_type,
        "conflictState": conflict_state,
        "resolution": resolution,
        "reason": reason,
    }


def build_relations(events: list[dict[str, Any]], user_id: str) -> list[dict[str, Any]]:
    relations: list[dict[str, Any]] = []
    for i, event_a in enumerate(events):
        for event_b in events[i + 1 :]:
            if event_a["id"] == event_b["id"]:
                continue
            if overlaps(event_a, event_b):
                relations.append(relation_for_pair(event_a, event_b, user_id, len(relations) + 1))
    return relations


def convert(data: dict[str, Any], semester_key: str, user_id: str) -> dict[str, Any]:
    result = data.get("result") or {}
    lesson_map, group_map = build_maps(result)
    grouped_rows = group_schedule_rows(result.get("scheduleList", []))
    base_external_ids = [
        external_id(semester_key, rows[0])
        for rows in grouped_rows
    ]
    external_id_counts = Counter(base_external_ids)

    events: list[dict[str, Any]] = []
    sources: list[dict[str, Any]] = []
    for rows, base_external_id in zip(grouped_rows, base_external_ids):
        resolved_external_id = base_external_id
        if external_id_counts[base_external_id] > 1:
            resolved_external_id = (
                f"{base_external_id}:{collision_discriminator(rows[0])}"
            )
        event, source = convert_group(
            rows,
            lesson_map,
            group_map,
            semester_key,
            user_id,
            resolved_external_id=resolved_external_id,
        )
        events.append(event)
        sources.append(source)

    return {
        "calendarEvents": events,
        "sourceRecords": sources,
        "scheduleRelations": build_relations(events, user_id),
    }


convert_course = convert
