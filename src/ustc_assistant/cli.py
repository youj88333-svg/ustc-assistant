"""Unified command-line entry point for collector services."""

from __future__ import annotations

import argparse
import sys
from datetime import date
from pathlib import Path
from typing import Any, Callable

from ustc_assistant.common.browser import CollectionError
from ustc_assistant.common.storage import dump_json, write_raw_json, write_raw_text
from ustc_assistant.config import (
    SourceConfigError,
    load_default_jw_semester,
    resolve_jw_semester,
)
from ustc_assistant.sources import campus
from ustc_assistant.sources.icourse import service as icourse
from ustc_assistant.sources.jw import service as jw
from ustc_assistant.sources.young import enrolment, schedule
from ustc_assistant.sources.young import source_bundle as young_source_bundle


DEFAULT_RAW_DIR = Path("tmp/private")


class _SemesterOverrideAction(argparse.Action):
    """Track which semester fields were explicitly supplied to the CLI."""

    def __call__(
        self,
        parser: argparse.ArgumentParser,
        namespace: argparse.Namespace,
        values: Any,
        option_string: str | None = None,
    ) -> None:
        setattr(namespace, self.dest, values)
        override_fields = set(getattr(namespace, "jw_semester_override_fields", ()))
        override_fields.add(self.dest)
        setattr(namespace, "jw_semester_override_fields", override_fields)


def _date_argument(value: str) -> date:
    try:
        return date.fromisoformat(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("date must use YYYY-MM-DD") from exc


def _required_account_id(args: argparse.Namespace) -> str:
    account_id = getattr(args, "account_id", None)
    if not isinstance(account_id, str) or not account_id.strip():
        raise ValueError("--account-id is required")
    return account_id.strip()


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

    jw_default_semester = load_default_jw_semester()
    jw_parser = collect_sources.add_parser("jw")
    jw_parser.add_argument(
        "--output", "-o", type=Path, default=Path("tmp/ustc-jw-import.generated.json")
    )
    jw_parser.add_argument(
        "--semester-id",
        type=int,
        default=jw_default_semester.semester_id,
        action=_SemesterOverrideAction,
    )
    jw_parser.add_argument(
        "--semester-key",
        default=jw_default_semester.semester_key,
        action=_SemesterOverrideAction,
    )
    jw_parser.add_argument(
        "--semester-name",
        dest="display_name",
        default=jw_default_semester.display_name,
        action=_SemesterOverrideAction,
    )
    jw_parser.add_argument("--account-id")
    _add_browser_options(jw_parser)
    jw_parser.set_defaults(
        handler=_collect_jw,
        jw_default_semester=jw_default_semester,
        jw_semester_override_fields=(),
    )

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
    schedule_parser.add_argument("--account-id")
    _add_browser_options(schedule_parser)
    schedule_parser.set_defaults(handler=_collect_young_schedule)

    campus_collect = collect_sources.add_parser("campus")
    campus_collect.add_argument(
        "--catalog-path",
        type=Path,
        default=Path("tmp/campus-catalog.json"),
    )
    campus_collect.add_argument(
        "--output",
        "-o",
        type=Path,
        default=Path("tmp/campus-collection.generated.json"),
    )
    campus_collect.add_argument(
        "--source",
        dest="sources",
        action="append",
        default=[],
        choices=sorted(campus.service.SOURCE_DEFINITIONS),
    )
    campus_collect.add_argument("--force", action="store_true")
    campus_collect.add_argument("--timeout-seconds", type=float, default=20)
    campus_collect.set_defaults(handler=_collect_campus)

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

    campus_query = query_sources.add_parser("campus")
    campus_query.add_argument("--text", required=True)
    campus_query.add_argument("--source", choices=sorted(campus.service.SOURCE_DEFINITIONS))
    campus_query.add_argument(
        "--kind",
        choices=["notice", "guide", "public_information"],
    )
    campus_query.add_argument(
        "--status",
        choices=["active", "archived", "unavailable"],
    )
    campus_query.add_argument("--limit", type=int, default=20)
    campus_query.add_argument(
        "--catalog-path",
        type=Path,
        default=Path("tmp/campus-catalog.json"),
    )
    campus_query.add_argument(
        "--output",
        "-o",
        type=Path,
        default=Path("tmp/campus-query.generated.json"),
    )
    campus_query.set_defaults(handler=_query_campus)

    read = commands.add_parser("read")
    read_sources = read.add_subparsers(dest="source", required=True)
    campus_read = read_sources.add_parser("campus")
    campus_read.add_argument("--entry-id", required=True)
    campus_read.add_argument(
        "--follow-link-id",
        dest="follow_link_ids",
        action="append",
        default=[],
    )
    campus_read.add_argument(
        "--no-stale",
        dest="allow_stale",
        action="store_false",
        default=True,
    )
    campus_read.add_argument(
        "--catalog-path",
        type=Path,
        default=Path("tmp/campus-catalog.json"),
    )
    campus_read.add_argument(
        "--cache-dir",
        type=Path,
        default=Path("tmp/campus-cache"),
    )
    campus_read.add_argument("--timeout-seconds", type=float, default=20)
    campus_read.add_argument(
        "--output",
        "-o",
        type=Path,
        default=Path("tmp/campus-detail.generated.json"),
    )
    campus_read.set_defaults(handler=_read_campus)
    return parser


def _collect_jw(args: argparse.Namespace, status: Callable[[str], None]) -> int:
    account_id = _required_account_id(args)
    override_fields = set(args.jw_semester_override_fields)
    semester = resolve_jw_semester(
        args.jw_default_semester,
        semester_id=args.semester_id if "semester_id" in override_fields else None,
        semester_key=args.semester_key if "semester_key" in override_fields else None,
        display_name=args.display_name if "display_name" in override_fields else None,
    )
    bundle, sources = jw.collect_jw_source_bundle(
        account_id=account_id,
        semester=semester,
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
        f"Collection complete: {len(bundle['data']['calendarEvents'])} events, "
        f"{len(bundle['data']['sourceRecords'])} source records, "
        f"{len(bundle['data']['scheduleRelations'])} relations -> {args.output}"
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
    account_id = _required_account_id(args)
    bundle, raw = young_source_bundle.collect_young_schedule_source_bundle(
        account_id=account_id,
        profile_dir=args.profile_dir,
        today=args.today,
        login_timeout_ms=args.login_timeout_seconds * 1000,
        status=status,
    )
    dump_json(args.output, bundle)
    if args.save_raw:
        write_raw_json(
            args.raw_dir,
            "ustc-young-my-schedule.raw.json",
            {"source": schedule.SOURCE_NAME, "records": list(raw.records)},
        )
        status(f"Privacy warning: complete raw schedule data was saved under {args.raw_dir}.")
    status(
        f"Collection complete: {len(bundle['data']['calendarEvents'])} schedules across "
        f"{raw.queried_dates} dates -> {args.output}"
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


def _collect_campus(
    args: argparse.Namespace,
    status: Callable[[str], None],
) -> int:
    payload = campus.refresh_catalogs(
        sources=args.sources or None,
        force=args.force,
        catalog_path=args.catalog_path,
        timeout_seconds=args.timeout_seconds,
    )
    dump_json(args.output, payload)
    metadata = payload["metadata"]
    status(
        "Campus catalog refresh complete: "
        f"{metadata['updated']} updated, {metadata['skipped']} skipped, "
        f"{metadata['failed']} failed -> {args.output}"
    )
    return 1 if metadata["failed"] else 0


def _query_campus(
    args: argparse.Namespace,
    status: Callable[[str], None],
) -> int:
    filters = {
        key: value
        for key, value in {
            "source": args.source,
            "kind": args.kind,
            "status": args.status,
        }.items()
        if value is not None
    }
    payload = campus.search_catalog(
        args.text,
        filters=filters or None,
        limit=args.limit,
        catalog_path=args.catalog_path,
    )
    dump_json(args.output, payload)
    status(
        f"Campus catalog query complete: {payload['metadata']['resultCount']} "
        f"results -> {args.output}"
    )
    return 0


def _read_campus(
    args: argparse.Namespace,
    status: Callable[[str], None],
) -> int:
    payload = campus.read_detail(
        args.entry_id,
        allow_stale=args.allow_stale,
        follow_link_ids=args.follow_link_ids,
        catalog_path=args.catalog_path,
        cache_dir=args.cache_dir,
        timeout_seconds=args.timeout_seconds,
    )
    dump_json(args.output, payload)
    state = "stale cache" if payload.get("stale") else "fresh content"
    status(f"Campus detail read complete ({state}) -> {args.output}")
    return 0


def main(
    argv: list[str] | None = None,
    *,
    status: Callable[[str], None] = print,
) -> int:
    try:
        parser = build_parser()
        args = parser.parse_args(argv)
        return args.handler(args, status)
    except (
        CollectionError,
        SourceConfigError,
        campus.CampusError,
        ValueError,
        OSError,
    ) as exc:
        print(f"Operation failed: {exc}", file=sys.stderr)
        return 1
