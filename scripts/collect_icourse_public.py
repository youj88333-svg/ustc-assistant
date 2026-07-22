#!/usr/bin/env python3
"""Query public USTC iCourse information and write normalized JSON."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import icourse_public_client as public_client
import icourse_public_parser as page_parser
import icourse_public_query as query_logic


BEIJING_TZ = ZoneInfo("Asia/Shanghai")
DEFAULT_OUTPUT = Path("tmp/icourse-public-query.generated.json")
DEFAULT_CACHE_DIR = Path("tmp/icourse-cache")
SOURCE_NAME = "icourse_public"


def parse_preference(value: str) -> tuple[str, str]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("preference must use dimension=value")
    dimension, preferred = (item.strip().lower() for item in value.split("=", 1))
    if query_logic.SUPPORTED_PREFERENCES.get(dimension) != preferred:
        allowed = ", ".join(
            f"{key}={item}" for key, item in query_logic.SUPPORTED_PREFERENCES.items()
        )
        raise argparse.ArgumentTypeError(f"unsupported preference; expected one of: {allowed}")
    return dimension, preferred


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Query public USTC iCourse course and teacher information."
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--course")
    mode.add_argument("--teacher")
    mode.add_argument("--jw-bundle", type=Path)
    parser.add_argument("--prefer", action="append", default=[], type=parse_preference)
    parser.add_argument("--group-only", action="store_true")
    parser.add_argument("--output", "-o", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--cache-dir", type=Path, default=DEFAULT_CACHE_DIR)
    parser.add_argument("--timeout-seconds", type=float, default=20)
    args = parser.parse_args(argv)
    if args.group_only and args.jw_bundle is None:
        parser.error("--group-only requires --jw-bundle")
    return args


def _load_json(path: Path) -> dict[str, Any]:
    with Path(path).open("r", encoding="utf-8") as file:
        payload = json.load(file)
    if not isinstance(payload, dict):
        raise ValueError("JW bundle root must be an object")
    return payload


def _dump_json(path: Path, payload: dict[str, Any]) -> None:
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    try:
        with temporary.open("w", encoding="utf-8", newline="\n") as file:
            json.dump(payload, file, ensure_ascii=False, indent=2)
            file.write("\n")
        temporary.replace(output)
    finally:
        if temporary.exists():
            temporary.unlink()


def _preferences(args: argparse.Namespace) -> dict[str, str]:
    result: dict[str, str] = {}
    for dimension, value in args.prefer:
        result[dimension] = value
    return result


def _course_entries(client: Any, search_text: str) -> list[dict[str, Any]]:
    search_results = client.search(search_text)
    entries: list[dict[str, Any]] = []
    for result in search_results:
        if result.get("kind") != "course" or not isinstance(result.get("sourceUrl"), str):
            continue
        entries.append(client.get_course(result["sourceUrl"]))
    return entries


def _rank_with_evidence(
    entries: list[dict[str, Any]], preferences: dict[str, str]
) -> list[dict[str, Any]]:
    ranked = query_logic.rank_entries(entries, preferences)
    for entry in ranked:
        entry["selectedEvidence"] = query_logic.select_evidence(entry)
    return ranked


def _query_course(args: argparse.Namespace, client: Any) -> list[dict[str, Any]]:
    return _rank_with_evidence(_course_entries(client, args.course), _preferences(args))


def _query_teacher(args: argparse.Namespace, client: Any) -> list[dict[str, Any]]:
    profiles: list[dict[str, Any]] = []
    search_results = client.search(args.teacher)
    for result in search_results:
        if result.get("kind") == "teacher" and isinstance(result.get("sourceUrl"), str):
            profiles.append(client.get_teacher(result["sourceUrl"]))
    if profiles:
        return profiles

    wanted = "".join(args.teacher.split()).casefold()
    seen_teacher_urls: set[str] = set()
    inspected_courses = 0
    for result in search_results:
        if result.get("kind") != "course" or not isinstance(result.get("sourceUrl"), str):
            continue
        label = "".join(str(result.get("label") or "").split()).casefold()
        if wanted not in label:
            continue
        course = client.get_course(result["sourceUrl"])
        inspected_courses += 1
        for teacher in course.get("teacherLinks", []):
            if not isinstance(teacher, dict):
                continue
            teacher_label = "".join(str(teacher.get("label") or "").split()).casefold()
            teacher_url = teacher.get("sourceUrl")
            if teacher_label == wanted and isinstance(teacher_url, str) and teacher_url not in seen_teacher_urls:
                seen_teacher_urls.add(teacher_url)
                profiles.append(client.get_teacher(teacher_url))
        if profiles or inspected_courses >= 5:
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
                candidate["relationStrength"] = query_logic.relation_strength(
                    offering, candidate
                )
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
        own = int(bool(isinstance(value.get("cache"), dict) and value["cache"].get("stale")))
        return own + sum(_count_stale(item) for item in value.values())
    if isinstance(value, list):
        return sum(_count_stale(item) for item in value)
    return 0


def run_query(
    args: argparse.Namespace,
    *,
    client: Any | None = None,
    status=print,
) -> int:
    preferences = _preferences(args)
    grouped_event_count = None
    if args.jw_bundle is not None:
        bundle = _load_json(args.jw_bundle)
        events = bundle.get("calendarEvents")
        grouped_event_count = len(events) if isinstance(events, list) else None
        offerings = query_logic.group_jw_offerings(bundle)
        if args.group_only:
            mode = "jw_group_only"
            results: list[dict[str, Any]] = offerings
        else:
            if client is None:
                raise ValueError("public iCourse client is required")
            mode = "jw_bundle"
            results = _query_jw(offerings, client, preferences)
    elif args.course is not None:
        if client is None:
            raise ValueError("public iCourse client is required")
        mode = "course"
        results = _query_course(args, client)
    else:
        if client is None:
            raise ValueError("public iCourse client is required")
        mode = "teacher"
        results = _query_teacher(args, client)

    payload = {
        "schemaVersion": "1.0",
        "source": SOURCE_NAME,
        "generatedAt": datetime.now(BEIJING_TZ).isoformat(timespec="seconds"),
        "query": {
            "mode": mode,
            "value": args.course or args.teacher or (str(args.jw_bundle) if args.jw_bundle else None),
            "preferences": preferences,
        },
        "metadata": {
            "resultCount": len(results),
            "staleEntryCount": _count_stale(results),
            "inputEventCount": grouped_event_count,
        },
        "results": results,
    }
    _dump_json(args.output, payload)
    if args.group_only:
        status(
            f"Grouped {grouped_event_count} calendar events into {len(results)} course offerings -> {args.output}"
        )
    else:
        status(f"Public iCourse query complete: {len(results)} results -> {args.output}")
    return 0


def _build_client(args: argparse.Namespace) -> public_client.PublicIcourseClient:
    cache = public_client.JsonPageCache(args.cache_dir)
    return public_client.PublicIcourseClient(
        cache=cache,
        timeout_seconds=args.timeout_seconds,
    )


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        client = None if args.group_only else _build_client(args)
        return run_query(args, client=client)
    except (
        public_client.IcourseNetworkError,
        page_parser.ParseError,
        ValueError,
        OSError,
        json.JSONDecodeError,
    ) as exc:
        print(f"Public iCourse query failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
