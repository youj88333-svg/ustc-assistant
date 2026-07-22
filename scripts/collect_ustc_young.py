#!/usr/bin/env python3
"""Collect and normalize USTC activities currently open for enrolment."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import ustc_young_collector as browser_collector


DEFAULT_OUTPUT = Path("tmp/ustc-young-enrolment.generated.json")
DEFAULT_RAW_DIR = Path("tmp/private")
SOURCE_NAME = "ustc_young_enrolment_list"


NORMALIZED_FIELDS = {
    "id": "sourceActivityId",
    "itemName": "name",
    "itemStatus": "status",
    "itemStatus_dictText": "statusLabel",
    "module": "module",
    "module_dictText": "moduleLabel",
    "itemCategory": "category",
    "itemCategory_dictText": "categoryLabel",
    "activityLevel": "activityLevel",
    "activityLevel_dictText": "activityLevelLabel",
    "organizer_dictText": "organizerLabel",
    "sponsor_dictText": "sponsorLabel",
    "businessDeptName": "businessDepartment",
    "st": "startsAt",
    "et": "endsAt",
    "applySt": "applicationStartsAt",
    "applyEt": "applicationEndsAt",
    "itemLimitNum": "capacity",
    "applyNum": "appliedCount",
    "partakeNum": "participantCount",
    "placeInfo": "location",
    "form": "form",
    "form_dictText": "formLabel",
    "serviceHour": "serviceHours",
    "validHour": "validHours",
    "baseContent": "descriptionHtml",
    "conceive": "requirementsHtml",
    "pic": "imagePath",
}


def _normalize_record(record: dict[str, Any]) -> dict[str, Any]:
    return {
        normalized_name: record.get(source_name)
        for source_name, normalized_name in NORMALIZED_FIELDS.items()
    }


def normalize_collection(
    collection: Any,
    *,
    collected_at: str | None = None,
) -> dict[str, Any]:
    timestamp = collected_at or datetime.now().astimezone().isoformat(timespec="seconds")
    activities = [_normalize_record(record) for record in collection.records]
    return {
        "schemaVersion": "1.0",
        "source": SOURCE_NAME,
        "collectedAt": timestamp,
        "metadata": {
            "reportedTotal": collection.reported_total,
            "pages": collection.pages,
            "activityCount": len(activities),
        },
        "activities": activities,
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
        raw_path = Path(raw_dir) / "ustc-young-enrolment.raw.json"
        _dump_json(
            raw_path,
            {
                "source": SOURCE_NAME,
                "records": list(records),
            },
        )
        written.append(raw_path)
    return written


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Open Edge and collect USTC second-classroom activities that are "
            "currently open for enrolment."
        )
    )
    parser.add_argument(
        "--output",
        "-o",
        type=Path,
        default=DEFAULT_OUTPUT,
        help="Path for the normalized open-activity list.",
    )
    parser.add_argument(
        "--profile-dir",
        type=Path,
        help="Dedicated Edge profile directory shared with the USTC JW prototype.",
    )
    parser.add_argument(
        "--save-raw",
        action="store_true",
        help="Also save the complete collected activity records locally.",
    )
    parser.add_argument(
        "--raw-dir",
        type=Path,
        default=DEFAULT_RAW_DIR,
        help="Private directory used only with --save-raw.",
    )
    parser.add_argument(
        "--login-timeout-seconds",
        type=int,
        default=300,
        help="Time allowed for manual login on the official page.",
    )
    return parser.parse_args(argv)


def run_collection(
    args: argparse.Namespace,
    *,
    collect_fn=browser_collector.collect_activities,
    status=print,
) -> int:
    status("Starting the dedicated Edge collection session ...")
    collection = collect_fn(
        profile_dir=args.profile_dir,
        login_timeout_ms=args.login_timeout_seconds * 1000,
        status=status,
    )
    status("Normalizing open second-classroom activities in memory ...")
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
            "Privacy warning: complete raw second-classroom activity records "
            f"were saved under {args.raw_dir}."
        )
    status(
        "Collection complete: "
        f"{len(normalized['activities'])} activities across "
        f"{normalized['metadata']['pages']} pages -> {args.output}"
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
