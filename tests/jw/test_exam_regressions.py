from __future__ import annotations

import json
import unittest
from pathlib import Path

from ustc_assistant.sources.jw import exam as parser

ROOT = Path(__file__).resolve().parents[2]
SAMPLE_PATH = ROOT / "tests" / "fixtures" / "jw" / "exam-page.html"


HEADERS = """
<thead><tr>
  <th>课程号</th><th>考试类型</th><th>课程名称</th><th>日期时间</th>
  <th>考场</th><th>教学楼</th><th>考场所在校区</th><th>考试说明</th>
</tr></thead>
"""


def exam_html(*rows: str, headers: str = HEADERS) -> str:
    return f'<html><table id="exams">{headers}<tbody>{"".join(rows)}</tbody></table></html>'


def exam_row(
    course_code: str = "SAMPLE1001.01",
    exam_type: str = "期末考试",
    course_name: str = "数据结构（示例）",
    date_time: str = "2026-06-22 08:30~10:30",
    room: str = "A101",
    building: str = "示例第一教学楼",
    campus: str = "示例东区",
    note: str = "",
) -> str:
    values = [course_code, exam_type, course_name, date_time, room, building, campus, note]
    return "<tr>" + "".join(f"<td>{value}</td>" for value in values) + "</tr>"


class ModuleContractTests(unittest.TestCase):
    def test_parser_module_exists(self):
        self.assertIsNotNone(parser, "exam converter module must exist")


@unittest.skipIf(parser is None, "converter module not implemented yet")
class ParseExamRowsTests(unittest.TestCase):
    def test_parses_synthetic_sample_and_html_entities(self):
        rows = parser.parse_exam_rows(SAMPLE_PATH.read_text(encoding="utf-8"))

        self.assertEqual(3, len(rows))
        self.assertEqual("SAMPLE1001.01", rows[0].course_code)
        self.assertEqual("数据结构 & 算法（示例）", rows[0].course_name)
        self.assertEqual("", rows[0].note)
        self.assertEqual("阶段考试", rows[2].exam_type)

    def test_empty_table_is_valid(self):
        self.assertEqual([], parser.parse_exam_rows(exam_html()))

    def test_live_classroom_number_header_is_valid(self):
        live_headers = HEADERS.replace("课程号", "课堂号")

        rows = parser.parse_exam_rows(
            exam_html(exam_row(), headers=live_headers)
        )

        self.assertEqual(1, len(rows))
        self.assertEqual("SAMPLE1001.01", rows[0].course_code)

    def test_missing_exam_table_is_rejected(self):
        with self.assertRaisesRegex(ValueError, r"table#exams"):
            parser.parse_exam_rows("<html><body></body></html>")

    def test_changed_header_is_rejected(self):
        headers = HEADERS.replace("课程名称", "科目名称")
        with self.assertRaisesRegex(ValueError, r"header"):
            parser.parse_exam_rows(exam_html(exam_row(), headers=headers))

    def test_wrong_cell_count_is_rejected(self):
        seven_cells = "<tr>" + "<td>value</td>" * 7 + "</tr>"
        with self.assertRaisesRegex(ValueError, r"8 cells"):
            parser.parse_exam_rows(exam_html(seven_cells))

    def test_missing_required_field_is_rejected(self):
        with self.assertRaisesRegex(ValueError, r"room"):
            parser.parse_exam_rows(exam_html(exam_row(room="   ")))


@unittest.skipIf(parser is None, "converter module not implemented yet")
class ConvertExamRowsTests(unittest.TestCase):
    def test_builds_calendar_events_and_source_records(self):
        result = parser.convert(
            SAMPLE_PATH.read_text(encoding="utf-8"),
            semester_key="2026spring",
            user_id="user_sample",
        )

        self.assertEqual(3, len(result["calendarEvents"]))
        self.assertEqual(3, len(result["sourceRecords"]))
        self.assertEqual([], result["scheduleRelations"])
        event = result["calendarEvents"][0]
        self.assertEqual("数据结构 & 算法（示例）（期末考试）", event["title"])
        self.assertEqual("exam", event["type"])
        self.assertEqual("critical", event["importance"])
        self.assertEqual("must_go", event["attendancePolicy"])
        self.assertEqual("go", event["attendanceDecision"])
        self.assertEqual("2026-06-22T08:30:00+08:00", event["startAt"])
        self.assertEqual("2026-06-22T10:30:00+08:00", event["endAt"])
        self.assertEqual("Asia/Shanghai", event["timezone"])
        self.assertEqual("A101", event["locationName"])
        self.assertEqual("示例第一教学楼", event["buildingName"])
        self.assertEqual("示例东区", event["campusName"])
        self.assertEqual(
            "ustc_jw:exam:2026spring:SAMPLE1001.01:期末考试",
            event["externalId"],
        )
        self.assertNotIn("contextId", json.dumps(result, ensure_ascii=False))

    def test_empty_table_converts_to_empty_result(self):
        result = parser.convert(exam_html(), "2026spring", "user_sample")
        self.assertEqual([], result["calendarEvents"])
        self.assertEqual([], result["sourceRecords"])

    def test_malformed_time_is_rejected(self):
        html = exam_html(exam_row(date_time="2026/06/22 08:30-10:30"))
        with self.assertRaisesRegex(ValueError, r"date_time"):
            parser.convert(html, "2026spring", "user_sample")

    def test_end_before_start_is_rejected(self):
        html = exam_html(exam_row(date_time="2026-06-22 10:30~08:30"))
        with self.assertRaisesRegex(ValueError, r"later than start"):
            parser.convert(html, "2026spring", "user_sample")

    def test_duplicate_identity_is_rejected(self):
        html = exam_html(exam_row(), exam_row(room="A102"))
        with self.assertRaisesRegex(ValueError, r"duplicate exam identity"):
            parser.convert(html, "2026spring", "user_sample")

    def test_fingerprint_changes_when_arrangement_changes(self):
        first = parser.convert(exam_html(exam_row(room="A101")), "2026spring", "user_sample")
        second = parser.convert(exam_html(exam_row(room="A102")), "2026spring", "user_sample")
        self.assertNotEqual(
            first["sourceRecords"][0]["fingerprint"],
            second["sourceRecords"][0]["fingerprint"],
        )


if __name__ == "__main__":
    unittest.main()
