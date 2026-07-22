#!/usr/bin/env python3
"""Resolve JW offerings and select deterministic iCourse evidence."""

from __future__ import annotations

import math
import re
from copy import deepcopy
from typing import Any, Iterable


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
