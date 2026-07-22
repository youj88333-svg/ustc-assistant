#!/usr/bin/env python3
"""Resolve JW offerings and select deterministic iCourse evidence."""

from __future__ import annotations

import argparse
import json
import math
import re
from copy import deepcopy
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable
from zoneinfo import ZoneInfo

from ustc_assistant.sources.icourse import client as public_client
from ustc_assistant.sources.icourse import parser as page_parser


SUPPORTED_PREFERENCES = {
    "homework": "low",
    "difficulty": "low",
    "grading": "high",
    "gain": "high",
}


def _normalized_text(value: Any) -> str:
    return re.sub(r"\s+", "", str(value or "")).casefold()


def _participants(event: dict[str, Any]) -> list[dict[str, Any]]:
    value = event.get("participants")
    if isinstance(value, dict):
        return [value]
    if isinstance(value, list):
        return [item for item in value if isinstance(item, dict)]
    return []


def _teacher_names(event: dict[str, Any]) -> list[str]:
    names = {
        str(item.get("name")).strip()
        for item in _participants(event)
        if item.get("role") == "teacher" and isinstance(item.get("name"), str) and item.get("name").strip()
    }
    return sorted(names, key=str.casefold)


def group_jw_offerings(bundle: dict[str, Any]) -> list[dict[str, Any]]:
    events = bundle.get("calendarEvents")
    if not isinstance(events, list):
        raise ValueError("JW bundle must contain a calendarEvents list")
    groups: dict[tuple[Any, ...], dict[str, Any]] = {}
    for event in events:
        if not isinstance(event, dict) or event.get("type") != "course":
            continue
        metadata = event.get("metadata") if isinstance(event.get("metadata"), dict) else {}
        title = str(event.get("title") or "").strip()
        if not title:
            raise ValueError("JW course event is missing title")
        teachers = _teacher_names(event)
        lesson_id = metadata.get("lessonId")
        course_code = str(metadata.get("courseCode") or "").strip() or None
        key = (
            str(lesson_id) if lesson_id is not None else "",
            _normalized_text(course_code),
            _normalized_text(title),
            tuple(_normalized_text(name) for name in teachers),
        )
        if key not in groups:
            groups[key] = {
                "sourceLessonId": str(lesson_id) if lesson_id is not None else None,
                "title": title,
                "courseCode": course_code,
                "teachers": teachers,
                "occurrenceCount": 0,
            }
        groups[key]["occurrenceCount"] += 1
    return sorted(
        groups.values(),
        key=lambda item: (_normalized_text(item["title"]), tuple(map(_normalized_text, item["teachers"])), item["sourceLessonId"] or ""),
    )


def _teacher_set(value: dict[str, Any]) -> set[str]:
    teachers = value.get("teachers")
    if not isinstance(teachers, list):
        return set()
    return {_normalized_text(item) for item in teachers if _normalized_text(item)}


def relation_strength(offering: dict[str, Any], entry: dict[str, Any]) -> str:
    offering_teachers = _teacher_set(offering)
    entry_teachers = _teacher_set(entry)
    if offering_teachers and offering_teachers == entry_teachers:
        return "exact_teacher_set"
    if offering_teachers & entry_teachers:
        return "partial_teacher_history"
    return "same_course_only"


_LEVELS = {
    "very little": -2,
    "很少": -2,
    "little": -1,
    "少": -1,
    "easy": -2,
    "简单": -2,
    "medium": 0,
    "中等": 0,
    "average": 0,
    "一般": 0,
    "hard": 2,
    "困难": 2,
    "a lot": 2,
    "很多": 2,
    "excellent": 2,
    "超好": 2,
    "good": 1,
    "较好": 1,
    "killer": -2,
    "杀手": -2,
    "none": -2,
    "没有": -2,
}


def _level(value: Any) -> int:
    return _LEVELS.get(str(value or "").strip().casefold(), 0)


def _base_score(entry: dict[str, Any]) -> float:
    average = entry.get("averageScore")
    count = entry.get("reviewCount")
    if not isinstance(average, (int, float)):
        average = 0.0
    if not isinstance(count, int) or count < 0:
        count = 0
    prior_average = 7.8
    prior_count = 8.7
    score = (float(average) * count + prior_average * prior_count) / (count + prior_count)
    terms = entry.get("terms") if isinstance(entry.get("terms"), list) else []
    years = [int(match.group()) for term in terms if (match := re.search(r"20\d{2}", str(term)))]
    if years:
        score += max(0, min(max(years) - 2023, 3)) * 0.05
    return score


def rank_entries(entries: Iterable[dict[str, Any]], preferences: dict[str, str]) -> list[dict[str, Any]]:
    for dimension, value in preferences.items():
        if SUPPORTED_PREFERENCES.get(dimension) != value:
            raise ValueError(f"unsupported preference: {dimension}={value}")
    ranked: list[dict[str, Any]] = []
    for source in entries:
        item = deepcopy(source)
        score = _base_score(item)
        reasons: list[str] = []
        aggregate = item.get("aggregate") if isinstance(item.get("aggregate"), dict) else {}
        for dimension, direction in preferences.items():
            value = _level(aggregate.get(dimension))
            score += (-value if direction == "low" else value) * 1.5
            reasons.append(f"{dimension}={direction}")
        item["ranking"] = {"score": round(score, 4), "reasons": reasons}
        ranked.append(item)
    return sorted(
        ranked,
        key=lambda item: (
            -item["ranking"]["score"],
            -int(item.get("reviewCount") or 0),
            str(item.get("sourceCourseId") or ""),
        ),
    )


def _dedupe_reviews(reviews: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    seen: set[str] = set()
    for review in reviews:
        review_id = str(review.get("sourceReviewId") or "")
        if not review_id or review_id in seen:
            continue
        seen.add(review_id)
        result.append(review)
    return result


def _conflicts(entry: dict[str, Any], review: dict[str, Any]) -> bool:
    aggregate = entry.get("aggregate") if isinstance(entry.get("aggregate"), dict) else {}
    dimensions = review.get("dimensions") if isinstance(review.get("dimensions"), dict) else {}
    return any(
        aggregate.get(key) is not None
        and dimensions.get(key) is not None
        and _level(aggregate[key]) != _level(dimensions[key])
        for key in ("difficulty", "homework", "grading", "gain")
    )


def select_evidence(
    entry: dict[str, Any],
    *,
    recent: int = 3,
    upvoted: int = 3,
    conflicting: int = 2,
) -> list[dict[str, Any]]:
    reviews = entry.get("reviews")
    if not isinstance(reviews, list):
        return []
    valid = [review for review in reviews if isinstance(review, dict)]
    newest = sorted(valid, key=lambda item: str(item.get("publishedAt") or ""), reverse=True)[:recent]
    most_upvoted = sorted(
        valid,
        key=lambda item: (-int(item.get("upvoteCount") or 0), str(item.get("sourceReviewId") or "")),
    )[:upvoted]
    conflict_reviews = [review for review in valid if _conflicts(entry, review)][:conflicting]
    selected = _dedupe_reviews(newest + most_upvoted + conflict_reviews)
    return [{**deepcopy(review), "untrustedText": True} for review in selected]


BEIJING_TZ = ZoneInfo("Asia/Shanghai")
SOURCE_NAME = "icourse_public"


def parse_preference(value: str) -> tuple[str, str]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("preference must use dimension=value")
    dimension, preferred = (item.strip().lower() for item in value.split("=", 1))
    if SUPPORTED_PREFERENCES.get(dimension) != preferred:
        allowed = ", ".join(
            f"{key}={item}" for key, item in SUPPORTED_PREFERENCES.items()
        )
        raise argparse.ArgumentTypeError(
            f"unsupported preference; expected one of: {allowed}"
        )
    return dimension, preferred


def _preferences(args: argparse.Namespace) -> dict[str, str]:
    return dict(args.prefer)


def _load_json(path: Path) -> dict[str, Any]:
    with Path(path).open("r", encoding="utf-8") as file:
        payload = json.load(file)
    if not isinstance(payload, dict):
        raise ValueError("JW bundle root must be an object")
    return payload


def _course_entries(client: Any, search_text: str) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    for result in client.search(search_text):
        if result.get("kind") == "course" and isinstance(result.get("sourceUrl"), str):
            entries.append(client.get_course(result["sourceUrl"]))
    return entries


def _rank_with_evidence(
    entries: list[dict[str, Any]], preferences: dict[str, str]
) -> list[dict[str, Any]]:
    ranked = rank_entries(entries, preferences)
    for entry in ranked:
        entry["selectedEvidence"] = select_evidence(entry)
    return ranked


def _query_teacher(name: str, client: Any) -> list[dict[str, Any]]:
    profiles: list[dict[str, Any]] = []
    search_results = client.search(name)
    for result in search_results:
        if result.get("kind") == "teacher" and isinstance(result.get("sourceUrl"), str):
            profiles.append(client.get_teacher(result["sourceUrl"]))
    if profiles:
        return profiles

    wanted = "".join(name.split()).casefold()
    seen_urls: set[str] = set()
    inspected = 0
    for result in search_results:
        if result.get("kind") != "course" or not isinstance(result.get("sourceUrl"), str):
            continue
        if wanted not in "".join(str(result.get("label") or "").split()).casefold():
            continue
        course = client.get_course(result["sourceUrl"])
        inspected += 1
        for teacher in course.get("teacherLinks", []):
            if not isinstance(teacher, dict):
                continue
            label = "".join(str(teacher.get("label") or "").split()).casefold()
            url = teacher.get("sourceUrl")
            if label == wanted and isinstance(url, str) and url not in seen_urls:
                seen_urls.add(url)
                profiles.append(client.get_teacher(url))
        if profiles or inspected >= 5:
            break
    return profiles


def _query_jw(
    offerings: list[dict[str, Any]],
    client: Any,
    preferences: dict[str, str],
) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for offering in offerings:
        try:
            candidates = _course_entries(client, offering["title"])
            for candidate in candidates:
                candidate["relationStrength"] = relation_strength(offering, candidate)
            results.append(
                {
                    "offering": offering,
                    "status": "matched" if candidates else "not_found",
                    "candidates": _rank_with_evidence(candidates, preferences),
                }
            )
        except (
            public_client.IcourseNetworkError,
            page_parser.ParseError,
            ValueError,
            OSError,
        ) as exc:
            results.append(
                {
                    "offering": offering,
                    "status": "failed",
                    "error": str(exc),
                    "candidates": [],
                }
            )
    return results


def _count_stale(value: Any) -> int:
    if isinstance(value, dict):
        own = int(
            bool(isinstance(value.get("cache"), dict) and value["cache"].get("stale"))
        )
        return own + sum(_count_stale(item) for item in value.values())
    if isinstance(value, list):
        return sum(_count_stale(item) for item in value)
    return 0


def build_client(cache_dir: Path, timeout_seconds: float) -> public_client.PublicIcourseClient:
    return public_client.PublicIcourseClient(
        cache=public_client.JsonPageCache(cache_dir),
        timeout_seconds=timeout_seconds,
    )


def run_query(
    args: argparse.Namespace,
    *,
    client: Any | None = None,
) -> dict[str, Any]:
    if args.group_only and args.jw_bundle is None:
        raise ValueError("--group-only requires --jw-bundle")

    preferences = _preferences(args)
    input_event_count = None
    if args.jw_bundle is not None:
        bundle = _load_json(args.jw_bundle)
        events = bundle.get("calendarEvents")
        input_event_count = len(events) if isinstance(events, list) else None
        offerings = group_jw_offerings(bundle)
        if args.group_only:
            mode = "jw_group_only"
            results = offerings
        else:
            if client is None:
                client = build_client(args.cache_dir, args.timeout_seconds)
            mode = "jw_bundle"
            results = _query_jw(offerings, client, preferences)
    elif args.course is not None:
        if client is None:
            client = build_client(args.cache_dir, args.timeout_seconds)
        mode = "course"
        results = _rank_with_evidence(
            _course_entries(client, args.course), preferences
        )
    else:
        if client is None:
            client = build_client(args.cache_dir, args.timeout_seconds)
        mode = "teacher"
        results = _query_teacher(args.teacher, client)

    return {
        "schemaVersion": "1.0",
        "source": SOURCE_NAME,
        "generatedAt": datetime.now(BEIJING_TZ).isoformat(timespec="seconds"),
        "query": {
            "mode": mode,
            "value": args.course
            or args.teacher
            or (str(args.jw_bundle) if args.jw_bundle else None),
            "preferences": preferences,
        },
        "metadata": {
            "resultCount": len(results),
            "staleEntryCount": _count_stale(results),
            "inputEventCount": input_event_count,
        },
        "results": results,
    }
