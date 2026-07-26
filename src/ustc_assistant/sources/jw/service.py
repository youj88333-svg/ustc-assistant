#!/usr/bin/env python3
"""Merge local USTC JW course and exam captures into one import bundle."""

from __future__ import annotations

import json
import warnings
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from uuid import UUID


from ustc_assistant.config import JwSemesterConfig
from ustc_assistant.sources.jw import course as course_converter
from ustc_assistant.sources.jw import exam as exam_converter
from ustc_assistant.sources.jw.collector import CollectedSources, collect_sources
from ustc_assistant.sources.jw.source_bundle import build_jw_source_bundle


PACKAGE_KEYS = ("calendarEvents", "sourceRecords", "scheduleRelations")


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


def _validate_package(package: dict[str, Any], source_name: str) -> None:
    for key in PACKAGE_KEYS:
        value = package.get(key)
        if not isinstance(value, list):
            raise ValueError(f"{source_name}: expected list at {key!r}")


def _assert_unique(items: list[dict[str, Any]], key: str, label: str) -> None:
    seen: set[str] = set()
    for item in items:
        item_id = item.get(key)
        if not isinstance(item_id, str) or not item_id:
            raise ValueError(f"{label} is missing required string {key!r}")
        if item_id in seen:
            raise ValueError(f"duplicate {label} {key}: {item_id}")
        seen.add(item_id)


def merge_packages(
    packages: list[dict[str, Any]],
    user_id: str,
    included_sources: list[str],
) -> dict[str, Any]:
    for index, package in enumerate(packages, start=1):
        _validate_package(package, f"package {index}")

    events = [
        event
        for package in packages
        for event in package["calendarEvents"]
    ]
    sources = [
        source
        for package in packages
        for source in package["sourceRecords"]
    ]
    relations = [
        relation
        for package in packages
        for relation in package["scheduleRelations"]
    ]

    _assert_unique(events, "id", "calendar event id")
    _assert_unique(sources, "id", "source record id")
    _assert_unique(relations, "id", "schedule relation id")

    return {
        "calendarEvents": events,
        "sourceRecords": sources,
        "scheduleRelations": relations,
        "metadata": {
            "bundleType": "ustc_jw_import_bundle",
            "userId": user_id,
            "includedSources": included_sources,
            "generatedAt": datetime.now(timezone.utc)
            .replace(microsecond=0)
            .isoformat()
            .replace("+00:00", "Z"),
        },
    }


def build_legacy_import_package(
    course_datum: dict[str, Any],
    exam_html: str,
    *,
    semester_key: str,
    user_id: str,
) -> dict[str, Any]:
    return merge_packages(
        [
            course_converter.convert_course(course_datum, semester_key, user_id),
            exam_converter.convert_exam(exam_html, semester_key, user_id),
        ],
        user_id=user_id,
        included_sources=["course_table", "exam_arrange"],
    )


def build_bundle(
    course_datum: dict[str, Any],
    exam_html: str,
    *,
    semester_key: str,
    user_id: str,
) -> dict[str, Any]:
    warnings.warn(
        "build_bundle() is deprecated; use build_jw_source_bundle()",
        DeprecationWarning,
        stacklevel=2,
    )
    return build_legacy_import_package(
        course_datum,
        exam_html,
        semester_key=semester_key,
        user_id=user_id,
    )


def collect_jw_bundle(
    *,
    semester_id: int,
    semester_key: str,
    user_id: str,
    **collector_kwargs: Any,
) -> tuple[dict[str, Any], CollectedSources]:
    sources = collect_sources(semester_id=semester_id, **collector_kwargs)
    bundle = build_legacy_import_package(
        sources.course_datum,
        sources.exam_html,
        semester_key=semester_key,
        user_id=user_id,
    )
    return bundle, sources


def collect_jw_source_bundle(
    *,
    account_id: str,
    semester: JwSemesterConfig,
    bundle_id: UUID | None = None,
    collected_at: datetime | None = None,
    **collector_kwargs: Any,
) -> tuple[dict[str, Any], CollectedSources]:
    sources = collect_sources(
        semester_id=semester.semester_id,
        account_id=account_id,
        **collector_kwargs,
    )
    cancel_check = collector_kwargs.get("cancel_check")
    bundle = build_jw_source_bundle(
        sources.course_datum,
        sources.exam_html,
        account_id=account_id,
        semester=semester,
        bundle_id=bundle_id,
        collected_at=collected_at,
        cancel_check=cancel_check,
    )
    return bundle, sources


def import_sources(
    course_datum_path: Path | None,
    exam_html_path: Path | None,
    semester_key: str,
    user_id: str,
) -> dict[str, Any]:
    packages: list[dict[str, Any]] = []
    included_sources: list[str] = []

    if course_datum_path is not None:
        packages.append(
            course_converter.convert(
                load_json(Path(course_datum_path)),
                semester_key=semester_key,
                user_id=user_id,
            )
        )
        included_sources.append("course_table")

    if exam_html_path is not None:
        packages.append(
            exam_converter.convert(
                Path(exam_html_path).read_text(encoding="utf-8"),
                semester_key=semester_key,
                user_id=user_id,
            )
        )
        included_sources.append("exam_arrange")

    if not packages:
        raise ValueError("at least one input source is required")

    return merge_packages(packages, user_id, included_sources)
