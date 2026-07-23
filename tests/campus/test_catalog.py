from __future__ import annotations

import json
import tempfile
import unittest
from datetime import date, datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from ustc_assistant.sources.campus.catalog import (
    CatalogEntry,
    CatalogStore,
    CatalogStoreError,
    canonicalize_url,
    entry_id,
    is_monthly_refresh_due,
    notice_cutoff,
)


BEIJING = ZoneInfo("Asia/Shanghai")
NOW = datetime(2026, 7, 23, 12, 0, tzinfo=BEIJING)


def make_entry(
    *,
    source: str = "teach_notice",
    kind: str = "notice",
    title: str = "缓考通知",
    url: str = "https://www.teach.ustc.edu.cn/notice/1.html",
    category: str | None = "考试",
    published_at: str | None = "2026-07-23",
    observed_at: datetime = NOW,
) -> CatalogEntry:
    stamp = observed_at.isoformat()
    return CatalogEntry(
        id=entry_id(source, url),
        source=source,
        kind=kind,
        title=title,
        category=category,
        published_at=published_at,
        detail_url=canonicalize_url(url),
        discovered_at=stamp,
        last_seen_at=stamp,
    )


class CatalogPolicyTests(unittest.TestCase):
    def test_url_identity_drops_fragment_and_tracking_query(self):
        url = (
            "https://www.teach.ustc.edu.cn/notice/1.html"
            "?utm_source=x&keep=1#part"
        )

        self.assertEqual(
            "https://www.teach.ustc.edu.cn/notice/1.html?keep=1",
            canonicalize_url(url),
        )
        self.assertEqual(
            entry_id("teach_notice", url),
            entry_id(
                "teach_notice",
                "https://www.teach.ustc.edu.cn/notice/1.html?keep=1",
            ),
        )

    def test_notice_window_contains_seven_beijing_calendar_dates(self):
        self.assertEqual(date(2026, 7, 17), notice_cutoff(date(2026, 7, 23)))

    def test_monthly_source_is_due_only_when_beijing_month_changes(self):
        self.assertFalse(
            is_monthly_refresh_due(
                datetime(2026, 7, 1, tzinfo=BEIJING),
                NOW,
            )
        )
        self.assertTrue(
            is_monthly_refresh_due(
                datetime(2026, 6, 30, 23, 59, tzinfo=BEIJING),
                NOW,
            )
        )
        self.assertTrue(is_monthly_refresh_due(None, NOW))


class CatalogStoreTests(unittest.TestCase):
    def test_missing_notice_is_archived(self):
        with tempfile.TemporaryDirectory() as directory:
            store = CatalogStore(Path(directory) / "catalog.json")
            entry = make_entry()
            store.commit_source("teach_notice", [entry], refreshed_at=NOW)

            store.commit_source("teach_notice", [], refreshed_at=NOW)

            self.assertEqual("archived", store.get(entry.id)["status"])

    def test_missing_guide_is_unavailable(self):
        with tempfile.TemporaryDirectory() as directory:
            store = CatalogStore(Path(directory) / "catalog.json")
            entry = make_entry(
                source="teach_student_service",
                kind="guide",
                url="https://www.teach.ustc.edu.cn/service/1.html",
            )
            store.commit_source("teach_student_service", [entry], refreshed_at=NOW)

            store.commit_source(
                "teach_student_service",
                [],
                refreshed_at=NOW,
            )

            self.assertEqual("unavailable", store.get(entry.id)["status"])

    def test_rediscovery_preserves_discovered_at_and_restores_active(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "catalog.json"
            store = CatalogStore(path)
            first_seen = datetime(2026, 7, 20, 9, 0, tzinfo=BEIJING)
            first = make_entry(observed_at=first_seen)
            store.commit_source("teach_notice", [first], refreshed_at=first_seen)
            store.commit_source("teach_notice", [], refreshed_at=NOW)
            rediscovered = make_entry(title="更新后的缓考通知", observed_at=NOW)

            store.commit_source("teach_notice", [rediscovered], refreshed_at=NOW)
            reloaded = CatalogStore(path).get(first.id)

            self.assertEqual(first_seen.isoformat(), reloaded["discoveredAt"])
            self.assertEqual(NOW.isoformat(), reloaded["lastSeenAt"])
            self.assertEqual("active", reloaded["status"])
            self.assertEqual("更新后的缓考通知", reloaded["title"])

    def test_search_ranks_active_title_match_before_archived_content(self):
        with tempfile.TemporaryDirectory() as directory:
            store = CatalogStore(Path(directory) / "catalog.json")
            title_match = make_entry(
                title="缓考申请",
                url="https://www.teach.ustc.edu.cn/notice/active.html",
            )
            content_match = make_entry(
                title="考试事务",
                category="缓考",
                url="https://www.teach.ustc.edu.cn/notice/archived.html",
            )
            store.commit_source(
                "teach_notice",
                [title_match, content_match],
                refreshed_at=NOW,
            )
            store.commit_source(
                "teach_notice",
                [title_match],
                refreshed_at=NOW,
            )

            results = store.search("缓考")

            self.assertEqual([title_match.id, content_match.id], [r["id"] for r in results])

    def test_search_filters_and_limit_are_validated(self):
        with tempfile.TemporaryDirectory() as directory:
            store = CatalogStore(Path(directory) / "catalog.json")
            store.commit_source(
                "teach_notice",
                [make_entry()],
                refreshed_at=NOW,
            )

            self.assertEqual(
                1,
                len(store.search("缓考", filters={"source": "teach_notice"}, limit=1)),
            )
            with self.assertRaises(ValueError):
                store.search("缓考", filters={"unknown": "value"})
            with self.assertRaises(ValueError):
                store.search("缓考", limit=0)

    def test_count_is_not_limited_by_search_page_size(self):
        with tempfile.TemporaryDirectory() as directory:
            store = CatalogStore(Path(directory) / "catalog.json")
            entries = [
                make_entry(
                    title=f"指南 {index}",
                    url=f"https://www.teach.ustc.edu.cn/notice/{index}.html",
                )
                for index in range(101)
            ]
            store.commit_source("teach_notice", entries, refreshed_at=NOW)

            self.assertEqual(
                101,
                store.count(filters={"source": "teach_notice", "status": "active"}),
            )

    def test_invalid_schema_is_rejected_without_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "catalog.json"
            path.write_text('{"schemaVersion":"0.1","sources":{}}', encoding="utf-8")
            original = path.read_text(encoding="utf-8")
            store = CatalogStore(path)

            with self.assertRaises(CatalogStoreError):
                store.commit_source(
                    "teach_notice",
                    [make_entry()],
                    refreshed_at=NOW,
                )

            self.assertEqual(original, path.read_text(encoding="utf-8"))

    def test_committed_file_is_valid_json_with_source_timestamp(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "catalog.json"
            store = CatalogStore(path)

            store.commit_source(
                "teach_notice",
                [make_entry()],
                refreshed_at=NOW,
            )
            payload = json.loads(path.read_text(encoding="utf-8"))

            self.assertEqual("1.0", payload["schemaVersion"])
            self.assertEqual(
                NOW.isoformat(),
                payload["sources"]["teach_notice"]["lastSuccessfulAt"],
            )
            self.assertEqual(
                NOW,
                CatalogStore(path).last_successful_at("teach_notice"),
            )


if __name__ == "__main__":
    unittest.main()
