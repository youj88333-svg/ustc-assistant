#!/usr/bin/env python3
"""Collect and normalize the signed-up USTC second-classroom schedule."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import date, datetime
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Iterable


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import ustc_young_schedule_collector as browser_collector


DEFAULT_OUTPUT = Path("tmp/ustc-young-my-schedule.generated.json")
DEFAULT_RAW_DIR = Path("tmp/private")
SOURCE_NAME = "ustc_young_my_schedule"


class _TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() == "br":
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() in {"p", "div", "li"}:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        self.parts.append(data)

    def text(self) -> str:
        lines = (line.strip() for line in "".join(self.parts).splitlines())
        return "\n".join(line for line in lines if line)


def _html_to_text(value: Any) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError("schedule content must be text")
    parser = _TextExtractor()
    parser.feed(value)
    parser.close()
    return parser.text()


def _normalize_source_datetime(value: Any, field: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"schedule {field} must be text")
    try:
        parsed = datetime.strptime(value, browser_collector.SOURCE_DATETIME_FORMAT)
    except ValueError as exc:
        raise ValueError(f"schedule {field} has invalid format") from exc
    return parsed.replace(tzinfo=browser_collector.BEIJING_TZ).isoformat()


def _require_text(record: dict[str, Any], field: str) -> str:
    value = record.get(field)
    if not isinstance(value, str) or not value:
        raise ValueError(f"schedule record is missing {field}")
    return value


def _normalize_record(record: dict[str, Any]) -> dict[str, Any]:
    return {
        "sourceScheduleId": _require_text(record, "id"),
        "sourceActivityId": _require_text(record, "itemId"),
        "title": _require_text(record, "title"),
        "startsAt": _normalize_source_datetime(record.get("startTime"), "startTime"),
        "endsAt": _normalize_source_datetime(record.get("endTime"), "endTime"),
        "location": record.get("place"),
        "descriptionText": _html_to_text(record.get("content")),
    }


def normalize_collection(
    collection: Any, *, collected_at: str | None = None
) -> dict[str, Any]:
    timestamp = collected_at or datetime.now(
        browser_collector.BEIJING_TZ
    ).isoformat(timespec="seconds")
    schedules = [_normalize_record(record) for record in collection.records]
    return {
        "schemaVersion": "1.0",
        "source": SOURCE_NAME,
        "collectedAt": timestamp,
        "metadata": {
            "queriedFrom": collection.queried_from.isoformat(),
            "queriedThrough": collection.queried_through.isoformat(),
            "queriedDates": collection.queried_dates,
            "emptyDates": collection.empty_dates,
            "scheduleCount": len(schedules),
        },
        "schedules": schedules,
    }


def _dump_json(path: Path, payload: Any) -> None:
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8", newline="\n") as file:
        json.dump(payload, file, ensure_ascii=False, indent=2)
        file.write("\n")


def write_collection_outputs(
    *,
    normalized: dict[str, Any],
    records: Iterable[dict[str, Any]],
    output_path: Path,
    save_raw: bool,
    raw_dir: Path,
) -> list[Path]:
    output = Path(output_path)
    _dump_json(output, normalized)
    written = [output]
    if save_raw:
        raw_path = Path(raw_dir) / "ustc-young-my-schedule.raw.json"
        _dump_json(raw_path, {"source": SOURCE_NAME, "records": list(records)})
        written.append(raw_path)
    return written


def _date_argument(value: str) -> date:
    try:
        return date.fromisoformat(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("date must use YYYY-MM-DD") from exc


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Open Edge and collect the signed-up USTC second-classroom schedule "
            "from seven days ago through one calendar month after today."
        )
    )
    parser.add_argument("--output", "-o", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--profile-dir", type=Path)
    parser.add_argument(
        "--today",
        type=_date_argument,
        help="Override Beijing today's date for reproducible testing (YYYY-MM-DD).",
    )
    parser.add_argument("--save-raw", action="store_true")
    parser.add_argument("--raw-dir", type=Path, default=DEFAULT_RAW_DIR)
    parser.add_argument("--login-timeout-seconds", type=int, default=300)
    return parser.parse_args(argv)


def run_collection(
    args: argparse.Namespace,
    *,
    collect_fn=browser_collector.collect_schedules,
    status=print,
) -> int:
    status("Starting the dedicated Edge collection session ...")
    collection = collect_fn(
        profile_dir=args.profile_dir,
        today=args.today,
        login_timeout_ms=args.login_timeout_seconds * 1000,
        status=status,
    )
    status("Normalizing the signed-up second-classroom schedule in memory ...")
    normalized = normalize_collection(collection)
    write_collection_outputs(
        normalized=normalized,
        records=collection.records,
        output_path=args.output,
        save_raw=args.save_raw,
        raw_dir=args.raw_dir,
    )
    if args.save_raw:
        status(
            "Privacy warning: complete raw signed-up schedule records were saved "
            f"under {args.raw_dir}."
        )
    status(
        "Collection complete: "
        f"{len(normalized['schedules'])} schedules across "
        f"{normalized['metadata']['queriedDates']} dates -> {args.output}"
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
