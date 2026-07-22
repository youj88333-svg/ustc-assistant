#!/usr/bin/env python3
"""Convert a saved USTC JW exam HTML page into calendar-event JSON."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from dataclasses import dataclass, fields
from datetime import datetime
from html.parser import HTMLParser
from pathlib import Path
from typing import Any


TZ_OFFSET = "+08:00"
TIMEZONE = "Asia/Shanghai"
SOURCE = "ustc_jw"
SOURCE_SYSTEM = "jw.ustc.edu.cn"
EXPECTED_HEADERS = (
    "课程号",
    "考试类型",
    "课程名称",
    "日期时间",
    "考场",
    "教学楼",
    "考场所在校区",
    "考试说明",
)
VALID_HEADERS = (
    EXPECTED_HEADERS,
    ("课堂号", *EXPECTED_HEADERS[1:]),
)
TIME_PATTERN = re.compile(
    r"^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2})~(\d{2}:\d{2})$"
)


def normalize_text(value: str) -> str:
    return " ".join(value.split())


@dataclass(frozen=True)
class ExamRow:
    course_code: str
    exam_type: str
    course_name: str
    date_time: str
    room: str
    building: str
    campus: str
    note: str

    @classmethod
    def from_cells(cls, cells: list[str], row_number: int) -> "ExamRow":
        if len(cells) != 8:
            raise ValueError(
                f"exam row {row_number}: expected 8 cells, got {len(cells)}"
            )
        normalized = [normalize_text(cell) for cell in cells]
        for field, value in zip(fields(cls), normalized):
            if field.name != "note" and not value:
                raise ValueError(
                    f"exam row {row_number}: required field {field.name} is empty"
                )
        return cls(*normalized)

    def values(self) -> tuple[str, ...]:
        return tuple(getattr(self, field.name) for field in fields(self))


class ExamTableParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.found_table = False
        self.in_exam_table = False
        self.table_depth = 0
        self.in_row = False
        self.row_kind: str | None = None
        self.cell_kind: str | None = None
        self.cell_parts: list[str] = []
        self.current_cells: list[str] = []
        self.headers: list[str] | None = None
        self.raw_rows: list[list[str]] = []

    def handle_starttag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        attrs_map = dict(attrs)
        if tag == "table":
            if self.in_exam_table:
                self.table_depth += 1
            elif attrs_map.get("id") == "exams":
                if self.found_table:
                    raise ValueError("multiple table#exams elements found")
                self.found_table = True
                self.in_exam_table = True
                self.table_depth = 1
            return

        if not self.in_exam_table or self.table_depth != 1:
            return
        if tag == "tr":
            self.in_row = True
            self.row_kind = None
            self.current_cells = []
        elif self.in_row and tag in {"th", "td"}:
            if self.row_kind is not None and self.row_kind != tag:
                raise ValueError("exam table row mixes header and data cells")
            self.row_kind = tag
            self.cell_kind = tag
            self.cell_parts = []

    def handle_data(self, data: str) -> None:
        if self.in_exam_table and self.cell_kind is not None:
            self.cell_parts.append(data)

    def handle_endtag(self, tag: str) -> None:
        if not self.in_exam_table:
            return
        if tag == "table":
            self.table_depth -= 1
            if self.table_depth == 0:
                self.in_exam_table = False
            return
        if self.table_depth != 1:
            return
        if tag in {"th", "td"} and self.cell_kind == tag:
            self.current_cells.append(normalize_text("".join(self.cell_parts)))
            self.cell_kind = None
            self.cell_parts = []
        elif tag == "tr" and self.in_row:
            if self.current_cells:
                if self.row_kind == "th":
                    if self.headers is not None:
                        raise ValueError("exam table contains multiple header rows")
                    self.headers = self.current_cells
                elif self.row_kind == "td":
                    self.raw_rows.append(self.current_cells)
            self.in_row = False
            self.row_kind = None
            self.current_cells = []


def parse_exam_rows(html_text: str) -> list[ExamRow]:
    parser = ExamTableParser()
    parser.feed(html_text)
    parser.close()
    if not parser.found_table:
        raise ValueError("expected table#exams was not found")
    headers = tuple(parser.headers or ())
    if headers not in VALID_HEADERS:
        raise ValueError(
            "unexpected exam table header: "
            f"expected one of {[list(item) for item in VALID_HEADERS]!r}, "
            f"got {parser.headers!r}"
        )
    return [
        ExamRow.from_cells(cells, row_number)
        for row_number, cells in enumerate(parser.raw_rows, start=1)
    ]


def parse_exam_time(value: str, row_number: int) -> tuple[str, str]:
    match = TIME_PATTERN.fullmatch(value)
    if match is None:
        raise ValueError(
            f"exam row {row_number}: invalid date_time {value!r}; "
            "expected YYYY-MM-DD HH:MM~HH:MM"
        )
    date_text, start_text, end_text = match.groups()
    try:
        start = datetime.strptime(f"{date_text} {start_text}", "%Y-%m-%d %H:%M")
        end = datetime.strptime(f"{date_text} {end_text}", "%Y-%m-%d %H:%M")
    except ValueError as exc:
        raise ValueError(
            f"exam row {row_number}: invalid date_time {value!r}"
        ) from exc
    if end <= start:
        raise ValueError(
            f"exam row {row_number}: exam end must be later than start"
        )
    return (
        f"{start.strftime('%Y-%m-%dT%H:%M:%S')}{TZ_OFFSET}",
        f"{end.strftime('%Y-%m-%dT%H:%M:%S')}{TZ_OFFSET}",
    )


def digest(parts: tuple[str, ...] | list[str]) -> str:
    payload = "\x1f".join(parts)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def external_id(row: ExamRow, semester_key: str) -> str:
    return (
        f"{SOURCE}:exam:{semester_key}:{row.course_code}:{row.exam_type}"
    )


def object_id(prefix: str, external: str) -> str:
    return f"{prefix}_{hashlib.sha256(external.encode('utf-8')).hexdigest()[:24]}"


def convert_row(
    row: ExamRow, row_number: int, semester_key: str, user_id: str
) -> tuple[dict[str, Any], dict[str, Any]]:
    start_at, end_at = parse_exam_time(row.date_time, row_number)
    ext_id = external_id(row, semester_key)
    event_id = object_id("event_exam", ext_id)
    source_id = object_id("source_exam", ext_id)
    event = {
        "id": event_id,
        "userId": user_id,
        "title": f"{row.course_name}（{row.exam_type}）",
        "type": "exam",
        "status": "active",
        "startAt": start_at,
        "endAt": end_at,
        "timezone": TIMEZONE,
        "locationName": row.room,
        "buildingName": row.building,
        "campusName": row.campus,
        "source": SOURCE,
        "sourceRecordId": source_id,
        "externalId": ext_id,
        "confidence": "high",
        "importance": "critical",
        "attendancePolicy": "must_go",
        "attendanceDecision": "go",
        "attendanceDecisionAt": None,
        "attendanceNote": "考试默认必须到场",
        "attendanceOutcome": "unknown",
        "listeningMode": "unknown",
        "listeningNote": None,
        "tags": ["exam", row.exam_type],
        "participants": [],
        "metadata": {
            "courseCode": row.course_code,
            "examType": row.exam_type,
            "examNote": row.note or None,
        },
    }
    source = {
        "id": source_id,
        "userId": user_id,
        "source": SOURCE,
        "sourceSystem": SOURCE_SYSTEM,
        "sourceType": "jw_exam",
        "externalId": ext_id,
        "fingerprint": digest(row.values()),
        "rawSummary": (
            f"courseCode={row.course_code}, examType={row.exam_type}, "
            "one exam table row"
        ),
        "status": "active",
    }
    return event, source


def convert(html_text: str, semester_key: str, user_id: str) -> dict[str, Any]:
    rows = parse_exam_rows(html_text)
    events: list[dict[str, Any]] = []
    sources: list[dict[str, Any]] = []
    seen_external_ids: set[str] = set()
    for row_number, row in enumerate(rows, start=1):
        ext_id = external_id(row, semester_key)
        if ext_id in seen_external_ids:
            raise ValueError(
                f"exam row {row_number}: duplicate exam identity {ext_id!r}"
            )
        seen_external_ids.add(ext_id)
        event, source = convert_row(row, row_number, semester_key, user_id)
        events.append(event)
        sources.append(source)
    return {
        "calendarEvents": events,
        "sourceRecords": sources,
        "scheduleRelations": [],
    }


convert_exam = convert


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert a saved USTC JW exam HTML page to calendar JSON."
    )
    parser.add_argument(
        "--input",
        "-i",
        default="examples/ustc-jw-exam-page.sample.html",
        help="Path to a correctly decoded UTF-8 exam HTML file.",
    )
    parser.add_argument(
        "--output",
        "-o",
        default="tmp/exam-events.generated.json",
        help="Path to converted JSON output.",
    )
    parser.add_argument(
        "--semester-key",
        default="2026spring",
        help="Stable product-side semester key used in externalId.",
    )
    parser.add_argument(
        "--user-id",
        default="user_sample",
        help="User id to place in generated objects.",
    )
    return parser.parse_args()


def dump_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as file:
        json.dump(data, file, ensure_ascii=False, indent=2)
        file.write("\n")


def main() -> None:
    args = parse_args()
    html_text = Path(args.input).read_text(encoding="utf-8")
    result = convert(html_text, args.semester_key, args.user_id)
    dump_json(Path(args.output), result)
    print(
        f"converted {len(result['calendarEvents'])} events, "
        f"{len(result['sourceRecords'])} source records -> {args.output}"
    )


if __name__ == "__main__":
    main()
