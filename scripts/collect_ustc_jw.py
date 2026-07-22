#!/usr/bin/env python3
"""Collect live USTC JW data and build a local unified import bundle."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import convert_ustc_jw_datum as course_converter
import convert_ustc_jw_exam_html as exam_converter
import import_ustc_jw as importer
import ustc_jw_collector as browser_collector


DEFAULT_OUTPUT = Path("tmp/ustc-jw-import.generated.json")
DEFAULT_RAW_DIR = Path("tmp/private")


def build_bundle(
    course_datum: dict[str, Any],
    exam_html: str,
    *,
    semester_key: str,
    user_id: str,
) -> dict[str, Any]:
    course_package = course_converter.convert(
        course_datum,
        semester_key=semester_key,
        user_id=user_id,
    )
    exam_package = exam_converter.convert(
        exam_html,
        semester_key=semester_key,
        user_id=user_id,
    )
    return importer.merge_packages(
        [course_package, exam_package],
        user_id=user_id,
        included_sources=["course_table", "exam_arrange"],
    )


def write_collection_outputs(
    *,
    bundle: dict[str, Any],
    output_path: Path,
    save_raw: bool,
    raw_dir: Path,
    course_datum: dict[str, Any],
    exam_html: str,
) -> list[Path]:
    output = Path(output_path)
    importer.dump_json(output, bundle)
    written = [output]

    if save_raw:
        private_dir = Path(raw_dir)
        private_dir.mkdir(parents=True, exist_ok=True)
        course_path = private_dir / "course-datum.raw.json"
        exam_path = private_dir / "exam-arrange.raw.html"
        with course_path.open("w", encoding="utf-8", newline="\n") as file:
            json.dump(course_datum, file, ensure_ascii=False, indent=2)
            file.write("\n")
        exam_path.write_text(exam_html, encoding="utf-8")
        written.extend([course_path, exam_path])

    return written


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Open Edge, collect the authenticated USTC JW course table and "
            "exam arrangement, and write a unified local import bundle."
        )
    )
    parser.add_argument(
        "--output",
        "-o",
        type=Path,
        default=DEFAULT_OUTPUT,
        help="Path for the standardized unified import bundle.",
    )
    parser.add_argument(
        "--profile-dir",
        type=Path,
        help=(
            "Dedicated Edge profile directory. Defaults to the current "
            "Windows user's local application-data directory."
        ),
    )
    parser.add_argument(
        "--save-raw",
        action="store_true",
        help="Also save sensitive raw course JSON and exam HTML.",
    )
    parser.add_argument(
        "--raw-dir",
        type=Path,
        default=DEFAULT_RAW_DIR,
        help="Private directory used only with --save-raw.",
    )
    parser.add_argument(
        "--semester-id",
        type=int,
        default=421,
        help="USTC JW internal semester id. Prototype default: 421.",
    )
    parser.add_argument(
        "--semester-key",
        default="2026spring",
        help="Stable product-side semester key used by converters.",
    )
    parser.add_argument(
        "--user-id",
        default="local_user",
        help="Local pseudonymous user id placed in generated objects.",
    )
    parser.add_argument(
        "--login-timeout-seconds",
        type=int,
        default=300,
        help="Time allowed for manual CAS login and CAPTCHA.",
    )
    return parser.parse_args(argv)


def run_collection(
    args: argparse.Namespace,
    *,
    collect_fn=browser_collector.collect_sources,
    status=print,
) -> int:
    status("Starting the dedicated Edge collection session ...")
    sources = collect_fn(
        semester_id=args.semester_id,
        profile_dir=args.profile_dir,
        login_timeout_ms=args.login_timeout_seconds * 1000,
        status=status,
    )
    status("Converting course and exam sources in memory ...")
    bundle = build_bundle(
        sources.course_datum,
        sources.exam_html,
        semester_key=args.semester_key,
        user_id=args.user_id,
    )
    write_collection_outputs(
        bundle=bundle,
        output_path=args.output,
        save_raw=args.save_raw,
        raw_dir=args.raw_dir,
        course_datum=sources.course_datum,
        exam_html=sources.exam_html,
    )
    if args.save_raw:
        status(
            "Privacy warning: sensitive raw JW source data was saved under "
            f"{args.raw_dir}."
        )
    status(
        "Collection complete: "
        f"{len(bundle['calendarEvents'])} events, "
        f"{len(bundle['sourceRecords'])} source records, "
        f"{len(bundle['scheduleRelations'])} schedule relations "
        f"-> {args.output}"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        return run_collection(args)
    except (browser_collector.CollectionError, ValueError, OSError) as exc:
        print(f"Collection failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
