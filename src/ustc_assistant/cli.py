"""Unified command-line entry point for collector services."""

from __future__ import annotations

import argparse
import sys
from datetime import date
from pathlib import Path
from typing import Any, Callable

from ustc_assistant.common.browser import CollectionError
from ustc_assistant.common.storage import dump_json, write_raw_json, write_raw_text
from ustc_assistant.sources.icourse import service as icourse
from ustc_assistant.sources.jw import service as jw
from ustc_assistant.sources.young import enrolment, schedule


DEFAULT_RAW_DIR = Path("tmp/private")


def _date_argument(value: str) -> date:
    try:
        return date.fromisoformat(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("date must use YYYY-MM-DD") from exc


def _add_browser_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--profile-dir", type=Path)
    parser.add_argument("--login-timeout-seconds", type=int, default=300)
    parser.add_argument("--save-raw", action="store_true")
    parser.add_argument("--raw-dir", type=Path, default=DEFAULT_RAW_DIR)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="ustc-assistant")
    commands = parser.add_subparsers(dest="command", required=True)

    collect = commands.add_parser("collect")
    collect_sources = collect.add_subparsers(dest="source", required=True)

    jw_parser = collect_sources.add_parser("jw")
    jw_parser.add_argument(
        "--output", "-o", type=Path, default=Path("tmp/ustc-jw-import.generated.json")
    )
    jw_parser.add_argument("--semester-id", type=int, default=421)
    jw_parser.add_argument("--semester-key", default="2026spring")
    jw_parser.add_argument("--user-id", default="local_user")
    _add_browser_options(jw_parser)
    jw_parser.set_defaults(handler=_collect_jw)

    enrolment_parser = collect_sources.add_parser("young-enrolment")
    enrolment_parser.add_argument(
        "--output",
        "-o",
        type=Path,
        default=Path("tmp/ustc-young-enrolment.generated.json"),
    )
    _add_browser_options(enrolment_parser)
    enrolment_parser.set_defaults(handler=_collect_young_enrolment)

    schedule_parser = collect_sources.add_parser("young-schedule")
    schedule_parser.add_argument(
        "--output",
        "-o",
        type=Path,
        default=Path("tmp/ustc-young-my-schedule.generated.json"),
    )
    schedule_parser.add_argument("--today", type=_date_argument)
    _add_browser_options(schedule_parser)
    schedule_parser.set_defaults(handler=_collect_young_schedule)

    query = commands.add_parser("query")
    query_sources = query.add_subparsers(dest="source", required=True)
    icourse_parser = query_sources.add_parser("icourse")
    modes = icourse_parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--course")
    modes.add_argument("--teacher")
    modes.add_argument("--jw-bundle", type=Path)
    icourse_parser.add_argument(
        "--prefer", action="append", default=[], type=icourse.parse_preference
    )
    icourse_parser.add_argument("--group-only", action="store_true")
    icourse_parser.add_argument(
        "--output",
        "-o",
        type=Path,
        default=Path("tmp/icourse-public-query.generated.json"),
    )
    icourse_parser.add_argument(
        "--cache-dir", type=Path, default=Path("tmp/icourse-cache")
    )
    icourse_parser.add_argument("--timeout-seconds", type=float, default=20)
    icourse_parser.set_defaults(handler=_query_icourse)
    return parser


def _collect_jw(args: argparse.Namespace, status: Callable[[str], None]) -> int:
    bundle, sources = jw.collect_jw_bundle(
        semester_id=args.semester_id,
        semester_key=args.semester_key,
        user_id=args.user_id,
        profile_dir=args.profile_dir,
        login_timeout_ms=args.login_timeout_seconds * 1000,
        status=status,
    )
    dump_json(args.output, bundle)
    if args.save_raw:
        write_raw_json(args.raw_dir, "course-datum.raw.json", sources.course_datum)
        write_raw_text(args.raw_dir, "exam-arrange.raw.html", sources.exam_html)
        status(f"Privacy warning: sensitive raw JW data was saved under {args.raw_dir}.")
    status(
        f"Collection complete: {len(bundle['calendarEvents'])} events, "
        f"{len(bundle['sourceRecords'])} source records, "
        f"{len(bundle['scheduleRelations'])} relations -> {args.output}"
    )
    return 0


def _collect_young_enrolment(
    args: argparse.Namespace, status: Callable[[str], None]
) -> int:
    normalized, raw = enrolment.collect_enrolment_snapshot(
        profile_dir=args.profile_dir,
        login_timeout_ms=args.login_timeout_seconds * 1000,
        status=status,
    )
    dump_json(args.output, normalized)
    if args.save_raw:
        write_raw_json(
            args.raw_dir,
            "ustc-young-enrolment.raw.json",
            {"source": enrolment.SOURCE_NAME, "records": list(raw.records)},
        )
        status(f"Privacy warning: complete raw activity data was saved under {args.raw_dir}.")
    status(
        f"Collection complete: {len(normalized['activities'])} activities across "
        f"{normalized['metadata']['pages']} pages -> {args.output}"
    )
    return 0


def _collect_young_schedule(
    args: argparse.Namespace, status: Callable[[str], None]
) -> int:
    normalized, raw = schedule.collect_schedule_snapshot(
        profile_dir=args.profile_dir,
        today=args.today,
        login_timeout_ms=args.login_timeout_seconds * 1000,
        status=status,
    )
    dump_json(args.output, normalized)
    if args.save_raw:
        write_raw_json(
            args.raw_dir,
            "ustc-young-my-schedule.raw.json",
            {"source": schedule.SOURCE_NAME, "records": list(raw.records)},
        )
        status(f"Privacy warning: complete raw schedule data was saved under {args.raw_dir}.")
    status(
        f"Collection complete: {len(normalized['schedules'])} schedules across "
        f"{normalized['metadata']['queriedDates']} dates -> {args.output}"
    )
    return 0


def _query_icourse(args: argparse.Namespace, status: Callable[[str], None]) -> int:
    if args.group_only and args.jw_bundle is None:
        raise ValueError("--group-only requires --jw-bundle")
    payload = icourse.run_query(args)
    dump_json(args.output, payload)
    status(
        f"Public iCourse query complete: {payload['metadata']['resultCount']} results "
        f"-> {args.output}"
    )
    return 0


def main(
    argv: list[str] | None = None,
    *,
    status: Callable[[str], None] = print,
) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.handler(args, status)
    except (CollectionError, ValueError, OSError) as exc:
        print(f"Operation failed: {exc}", file=sys.stderr)
        return 1
