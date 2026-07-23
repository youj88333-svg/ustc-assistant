from __future__ import annotations

import json
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from ustc_assistant.sources.campus import service
from ustc_assistant.sources.campus.catalog import CatalogStore
from tests.campus.test_catalog import make_entry


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests" / "fixtures" / "campus"
BEIJING = ZoneInfo("Asia/Shanghai")
NOW = datetime(2026, 7, 23, 12, 0, tzinfo=BEIJING)


def fixture(name: str) -> str:
    return (FIXTURES / name).read_text(encoding="utf-8")


class MappingClient:
    def __init__(self, pages: dict[str, str | Exception]) -> None:
        self.pages = pages
        self.calls: list[str] = []

    def get_text(self, url: str, *, discovered_child: bool = False) -> str:
        self.calls.append(url)
        value = self.pages[url]
        if isinstance(value, Exception):
            raise value
        return value


class SourceRegistryTests(unittest.TestCase):
    def test_registry_contains_exactly_the_five_approved_sources(self):
        self.assertEqual(
            {
                "teach_notice",
                "teach_student_service",
                "finance_notice",
                "finance_public_information",
                "finance_business_guide",
            },
            set(service.SOURCE_DEFINITIONS),
        )


class RefreshTests(unittest.TestCase):
    def test_notice_refresh_filters_to_window_and_stops_on_old_page(self):
        url = service.SOURCE_DEFINITIONS["teach_notice"].url
        client = MappingClient({url: fixture("teach-notice-list.html")})
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "catalog.json"

            result = service.refresh_catalogs(
                sources=["teach_notice"],
                force=False,
                catalog_path=path,
                client=client,
                now=NOW,
                today=NOW.date(),
            )
            entries = CatalogStore(path).search("", filters={"source": "teach_notice"})

        self.assertEqual("updated", result["sources"]["teach_notice"]["status"])
        self.assertEqual(["秋季选课通知"], [entry["title"] for entry in entries])
        self.assertEqual([url], client.calls)

    def test_monthly_source_skips_same_month_unless_forced(self):
        definition = service.SOURCE_DEFINITIONS["teach_student_service"]
        client = MappingClient({definition.url: fixture("teach-service-list.html")})
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "catalog.json"
            store = CatalogStore(path)
            store.commit_source(
                definition.name,
                [
                    make_entry(
                        source=definition.name,
                        kind=definition.kind,
                        url="https://www.teach.ustc.edu.cn/service/svc-student/200.html",
                    )
                ],
                refreshed_at=NOW,
            )

            skipped = service.refresh_catalogs(
                sources=[definition.name],
                catalog_path=path,
                client=client,
                now=NOW,
                today=NOW.date(),
            )
            forced = service.refresh_catalogs(
                sources=[definition.name],
                force=True,
                catalog_path=path,
                client=client,
                now=NOW,
                today=NOW.date(),
            )

        self.assertEqual("skipped", skipped["sources"][definition.name]["status"])
        self.assertEqual("updated", forced["sources"][definition.name]["status"])
        self.assertEqual([definition.url], client.calls)

    def test_one_source_failure_keeps_old_snapshot_and_updates_other_source(self):
        teach = service.SOURCE_DEFINITIONS["teach_student_service"]
        finance = service.SOURCE_DEFINITIONS["finance_public_information"]
        client = MappingClient(
            {
                teach.url: "<html><body>layout changed</body></html>",
                finance.url: fixture("finance-static-list.html"),
            }
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "catalog.json"
            store = CatalogStore(path)
            old = make_entry(
                source=teach.name,
                kind=teach.kind,
                title="旧指南",
                url="https://www.teach.ustc.edu.cn/service/svc-student/old.html",
            )
            store.commit_source(teach.name, [old], refreshed_at=NOW)
            before = json.loads(path.read_text(encoding="utf-8"))["sources"][teach.name]

            result = service.refresh_catalogs(
                sources=[teach.name, finance.name],
                force=True,
                catalog_path=path,
                client=client,
                now=NOW,
                today=NOW.date(),
            )
            payload = json.loads(path.read_text(encoding="utf-8"))

        self.assertEqual("failed", result["sources"][teach.name]["status"])
        self.assertEqual("updated", result["sources"][finance.name]["status"])
        self.assertEqual(before, payload["sources"][teach.name])
        self.assertEqual(1, result["metadata"]["failed"])

    def test_repeated_next_url_fails_without_committing(self):
        definition = service.SOURCE_DEFINITIONS["teach_student_service"]
        looping = (
            '<a href="/service/svc-student/200.html">缓考办理</a>'
            f'<a class="next" href="{definition.url}">下一页</a>'
        )
        client = MappingClient({definition.url: looping})
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "catalog.json"

            result = service.refresh_catalogs(
                sources=[definition.name],
                force=True,
                catalog_path=path,
                client=client,
                now=NOW,
                today=NOW.date(),
            )

            self.assertFalse(path.exists())

        self.assertEqual("failed", result["sources"][definition.name]["status"])
        self.assertIn("pagination", result["sources"][definition.name]["error"])

    def test_future_notice_more_than_one_day_ahead_fails(self):
        definition = service.SOURCE_DEFINITIONS["teach_notice"]
        html = (
            '<article><a href="/notice/notice-teaching/future.html">'
            "未来通知</a><time>2026-07-25</time></article>"
        )
        client = MappingClient({definition.url: html})
        with tempfile.TemporaryDirectory() as directory:
            result = service.refresh_catalogs(
                sources=[definition.name],
                catalog_path=Path(directory) / "catalog.json",
                client=client,
                now=NOW,
                today=NOW.date(),
            )

        self.assertEqual("failed", result["sources"][definition.name]["status"])

    def test_unknown_source_is_rejected_before_network(self):
        client = MappingClient({})

        with self.assertRaises(ValueError):
            service.refresh_catalogs(sources=["unknown"], client=client)

        self.assertEqual([], client.calls)


class ServiceWrapperTests(unittest.TestCase):
    def test_search_wrapper_returns_stable_offline_envelope(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "catalog.json"
            CatalogStore(path).commit_source(
                "teach_notice",
                [make_entry()],
                refreshed_at=NOW,
            )

            result = service.search_catalog("缓考", catalog_path=path)

        self.assertEqual("ustc_campus_catalog", result["source"])
        self.assertEqual("缓考", result["query"])
        self.assertEqual(1, result["metadata"]["resultCount"])
        self.assertEqual(1, len(result["results"]))

    def test_read_wrappers_delegate_to_reader(self):
        class FakeReader:
            def read_detail(self, entry_id, allow_stale=True, follow_link_ids=()):
                return {
                    "entryId": entry_id,
                    "allowStale": allow_stale,
                    "links": list(follow_link_ids),
                }

            def read_attachment(self, item_id, attachment_id):
                return {"itemId": item_id, "attachmentId": attachment_id}

        reader = FakeReader()

        detail = service.read_detail(
            "campus_1",
            allow_stale=False,
            follow_link_ids=("link_1",),
            reader=reader,
        )
        attachment = service.read_attachment(
            "knowledge_1",
            "attachment_1",
            reader=reader,
        )

        self.assertEqual(["link_1"], detail["links"])
        self.assertFalse(detail["allowStale"])
        self.assertEqual("attachment_1", attachment["attachmentId"])


if __name__ == "__main__":
    unittest.main()
