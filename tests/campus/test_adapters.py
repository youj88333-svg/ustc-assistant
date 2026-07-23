from __future__ import annotations

import unittest
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from ustc_assistant.sources.campus import finance, teach
from ustc_assistant.sources.campus.catalog import CampusError


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests" / "fixtures" / "campus"
BEIJING = ZoneInfo("Asia/Shanghai")
NOW = datetime(2026, 7, 23, 12, 0, tzinfo=BEIJING)
TEACH_URL = "https://www.teach.ustc.edu.cn/category/notice"
FINANCE_URL = "https://finance.ustc.edu.cn/tzgg/list.htm"


def fixture(name: str) -> str:
    return (FIXTURES / name).read_text(encoding="utf-8")


class TeachCatalogTests(unittest.TestCase):
    def test_parses_notice_entries_and_next_page(self):
        page = teach.parse_teach_catalog(
            fixture("teach-notice-list.html"),
            source="teach_notice",
            kind="notice",
            base_url=TEACH_URL,
            observed_at=NOW,
        )

        self.assertEqual(
            ["秋季选课通知", "考试安排通知"],
            [item.title for item in page.entries],
        )
        self.assertEqual("2026-07-23", page.entries[0].published_at)
        self.assertEqual("教学", page.entries[0].category)
        self.assertEqual(
            "https://www.teach.ustc.edu.cn/category/notice/page/2",
            page.next_url,
        )

    def test_parses_guide_entries_without_dates(self):
        page = teach.parse_teach_catalog(
            fixture("teach-service-list.html"),
            source="teach_student_service",
            kind="guide",
            base_url="https://www.teach.ustc.edu.cn/category/service/svc-student",
            observed_at=NOW,
        )

        self.assertEqual(2, len(page.entries))
        self.assertIsNone(page.entries[0].published_at)
        self.assertEqual("考试", page.entries[0].category)

    def test_rejects_unrecognized_nonempty_page(self):
        with self.assertRaises(CampusError):
            teach.parse_teach_catalog(
                "<html><body><p>layout changed</p></body></html>",
                source="teach_notice",
                kind="notice",
                base_url=TEACH_URL,
                observed_at=NOW,
            )

    def test_accepts_explicit_empty_state(self):
        page = teach.parse_teach_catalog(
            '<div class="no-results">暂无内容</div>',
            source="teach_notice",
            kind="notice",
            base_url=TEACH_URL,
            observed_at=NOW,
        )

        self.assertEqual((), page.entries)


class FinanceCatalogTests(unittest.TestCase):
    def test_parses_notice_entries_and_next_page(self):
        page = finance.parse_finance_catalog(
            fixture("finance-notice-list.html"),
            source="finance_notice",
            kind="notice",
            base_url=FINANCE_URL,
            observed_at=NOW,
        )

        self.assertEqual("缴费通知", page.entries[0].title)
        self.assertEqual("2026-07-23", page.entries[0].published_at)
        self.assertEqual("缴费", page.entries[0].category)
        self.assertEqual(
            "https://finance.ustc.edu.cn/tzgg/list2.htm",
            page.next_url,
        )

    def test_parses_static_entries_with_optional_dates(self):
        page = finance.parse_finance_catalog(
            fixture("finance-static-list.html"),
            source="finance_public_information",
            kind="public_information",
            base_url="https://finance.ustc.edu.cn/xxgk/list.htm",
            observed_at=NOW,
        )

        self.assertEqual(2, len(page.entries))
        self.assertEqual("2025-05-19", page.entries[0].published_at)
        self.assertIsNone(page.entries[1].published_at)

    def test_rejects_unrecognized_nonempty_page(self):
        with self.assertRaises(CampusError):
            finance.parse_finance_catalog(
                "<html><body><p>layout changed</p></body></html>",
                source="finance_notice",
                kind="notice",
                base_url=FINANCE_URL,
                observed_at=NOW,
            )


class DetailParserTests(unittest.TestCase):
    def test_teach_detail_extracts_content_attachments_and_explicit_links(self):
        result = teach.parse_teach_detail(
            fixture("teach-detail.html"),
            "https://www.teach.ustc.edu.cn/service/svc-student/200.html",
        )

        self.assertEqual("缓考办理说明", result["title"])
        self.assertEqual("2026-07-23", result["publishedAt"])
        self.assertIn("申请人应在规定时间提交材料", result["content"])
        self.assertNotIn("版权所有", result["content"])
        self.assertEqual("application/pdf", result["attachments"][0]["mediaType"])
        self.assertEqual("办理流程", result["images"][0]["alt"])
        self.assertEqual(1, len(result["candidateLinks"]))
        self.assertEqual("explicit-reference", result["candidateLinks"][0]["reason"])
        self.assertTrue(result["candidateLinks"][0]["id"].startswith("link_"))

    def test_finance_detail_extracts_binary_attachment_descriptor(self):
        result = finance.parse_finance_detail(
            fixture("finance-detail.html"),
            "https://finance.ustc.edu.cn/2026/0723/c21813a1/page.htm",
        )

        self.assertEqual("缴费事项说明", result["title"])
        self.assertIn("完成缴费", result["content"])
        self.assertEqual(
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            result["attachments"][0]["mediaType"],
        )
        self.assertEqual(1, len(result["candidateLinks"]))

    def test_missing_detail_content_fails_loudly(self):
        with self.assertRaises(CampusError):
            teach.parse_teach_detail(
                "<html><body><h1>标题</h1></body></html>",
                "https://www.teach.ustc.edu.cn/notice/1.html",
            )


if __name__ == "__main__":
    unittest.main()
