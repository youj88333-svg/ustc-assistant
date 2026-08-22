"""Unified command-line entry point for collector services."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any, Callable

from ustc_assistant.common.browser import CollectionError
from ustc_assistant.common.storage import dump_json, write_raw_json, write_raw_text
from ustc_assistant.config import (
    SourceConfigError,
    load_default_jw_semester,
    render_flutter_source_defaults,
    resolve_jw_semester,
)
from ustc_assistant.sources.jw import service as jw


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

    config = commands.add_parser("config")
    config_sub = config.add_subparsers(dest="config_command", required=True)
    generate_defaults = config_sub.add_parser("generate-flutter-defaults")
    generate_defaults.add_argument(
        "--output",
        "-o",
        type=Path,
        default=Path("app/lib/core/config/generated_source_defaults.dart"),
    )
    generate_defaults.set_defaults(handler=_generate_flutter_defaults)
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


def _generate_flutter_defaults(
    args: argparse.Namespace,
    status: Callable[[str], None],
) -> int:
    semester = load_default_jw_semester()
    rendered = render_flutter_source_defaults(semester)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(rendered, encoding="utf-8", newline="\n")
    status(
        f"Generated Flutter semester defaults for semester {semester.semester_id} "
        f"-> {output}"
    )
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
        ValueError,
        OSError,
    ) as exc:
        print(f"Operation failed: {exc}", file=sys.stderr)
        return 1
