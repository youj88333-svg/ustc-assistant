#!/usr/bin/env python3
"""Merge local USTC JW course and exam captures into one import bundle."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import convert_ustc_jw_datum as course_converter
import convert_ustc_jw_exam_html as exam_converter


PACKAGE_KEYS = ("calendarEvents", "sourceRecords", "scheduleRelations")


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


def dump_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as file:
        json.dump(data, file, ensure_ascii=False, indent=2)
        file.write("\n")


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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Merge saved USTC JW course/exam captures into one JSON bundle."
    )
    parser.add_argument(
        "--course-datum",
        type=Path,
        help="Path to a saved course-table datum JSON file.",
    )
    parser.add_argument(
        "--exam-html",
        type=Path,
        help="Path to a saved exam-arrangement HTML file.",
    )
    parser.add_argument(
        "--output",
        "-o",
        type=Path,
        default=Path("tmp/ustc-jw-import.generated.json"),
        help="Path to write the merged import bundle.",
    )
    parser.add_argument(
        "--semester-key",
        default="2026spring",
        help="Stable product-side semester key used by source converters.",
    )
    parser.add_argument(
        "--user-id",
        default="user_sample",
        help="Local user id to place in generated objects.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    result = import_sources(
        course_datum_path=args.course_datum,
        exam_html_path=args.exam_html,
        semester_key=args.semester_key,
        user_id=args.user_id,
    )
    dump_json(args.output, result)
    print(
        f"imported {len(result['calendarEvents'])} events, "
        f"{len(result['sourceRecords'])} source records, "
        f"{len(result['scheduleRelations'])} schedule relations "
        f"-> {args.output}"
    )


if __name__ == "__main__":
    main()
