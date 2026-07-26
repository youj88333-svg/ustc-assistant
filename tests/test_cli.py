import json
import tempfile
import unittest
from datetime import date
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from ustc_assistant import cli
from ustc_assistant.common import browser, storage
from ustc_assistant.sources import campus
from ustc_assistant.sources.icourse import service as icourse_service


class FakePage:
    marker = "page"


class FakeContext:
    def __init__(self):
        self.pages = [FakePage()]
        self.closed = False

    def close(self):
        self.closed = True


class FakeChromium:
    def __init__(self, context):
        self.context = context
        self.launch_calls = []

    def launch_persistent_context(self, user_data_dir, **kwargs):
        self.launch_calls.append((user_data_dir, kwargs))
        return self.context


class FakePlaywrightManager:
    def __init__(self, chromium):
        self.chromium = chromium

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False


class PackageEntryTests(unittest.TestCase):
    def test_root_parser_exposes_collect_and_query(self):
        parser = cli.build_parser()

        collect_args = parser.parse_args(["collect", "jw"])
        query_args = parser.parse_args(["query", "icourse", "--course", "test"])

        self.assertEqual(collect_args.command, "collect")
        self.assertEqual(collect_args.source, "jw")
        self.assertEqual(query_args.command, "query")
        self.assertEqual(query_args.source, "icourse")

    def test_collect_parsers_use_current_semester_defaults(self):
        parser = cli.build_parser()

        jw = parser.parse_args(["collect", "jw"])
        schedule = parser.parse_args(
            ["collect", "young-schedule", "--today", "2026-07-22"]
        )

        self.assertEqual(jw.semester_id, 461)
        self.assertEqual(jw.semester_key, "2026fall")
        self.assertEqual(jw.display_name, "2026 秋季学期")
        self.assertEqual(jw.output, Path("tmp/ustc-jw-import.generated.json"))
        self.assertEqual(schedule.today.isoformat(), "2026-07-22")

    def test_jw_semester_override_requires_complete_triple(self):
        result = cli.main(["collect", "jw", "--semester-id", "421"])

        self.assertEqual(result, 1)

    def test_icourse_service_exposes_app_callable_query_runner(self):
        self.assertTrue(callable(icourse_service.run_query))

    def test_campus_parsers_expose_collect_query_and_read_defaults(self):
        parser = cli.build_parser()

        collect = parser.parse_args(["collect", "campus"])
        query = parser.parse_args(["query", "campus", "--text", "缓考"])
        read = parser.parse_args(
            ["read", "campus", "--entry-id", "campus_abc"]
        )

        self.assertEqual(Path("tmp/campus-catalog.json"), collect.catalog_path)
        self.assertEqual(
            Path("tmp/campus-collection.generated.json"),
            collect.output,
        )
        self.assertFalse(collect.force)
        self.assertEqual([], collect.sources)
        self.assertEqual(20, query.limit)
        self.assertEqual(Path("tmp/campus-query.generated.json"), query.output)
        self.assertTrue(read.allow_stale)
        self.assertEqual([], read.follow_link_ids)
        self.assertEqual(Path("tmp/campus-detail.generated.json"), read.output)

    def test_campus_repeatable_and_safety_options_are_parsed(self):
        parser = cli.build_parser()

        collect = parser.parse_args(
            [
                "collect",
                "campus",
                "--source",
                "teach_notice",
                "--source",
                "finance_notice",
                "--force",
                "--timeout-seconds",
                "9",
            ]
        )
        read = parser.parse_args(
            [
                "read",
                "campus",
                "--entry-id",
                "campus_abc",
                "--follow-link-id",
                "link_1",
                "--follow-link-id",
                "link_2",
                "--no-stale",
                "--cache-dir",
                "tmp/custom-cache",
            ]
        )

        self.assertEqual(["teach_notice", "finance_notice"], collect.sources)
        self.assertTrue(collect.force)
        self.assertEqual(9, collect.timeout_seconds)
        self.assertEqual(["link_1", "link_2"], read.follow_link_ids)
        self.assertFalse(read.allow_stale)
        self.assertEqual(Path("tmp/custom-cache"), read.cache_dir)


class CollectorCommandTests(unittest.TestCase):
    def test_jw_command_writes_bundle_and_optional_raw_sources(self):
        bundle = {
            "calendarEvents": [{"id": "event-1"}],
            "sourceRecords": [{"id": "source-1"}],
            "scheduleRelations": [],
        }
        sources = SimpleNamespace(
            course_datum={"result": {"lessonList": []}},
            exam_html='<table id="exams"></table>',
        )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = cli.build_parser().parse_args(
                [
                    "collect",
                    "jw",
                    "--output",
                    str(root / "bundle.json"),
                    "--save-raw",
                    "--raw-dir",
                    str(root / "private"),
                    "--semester-id",
                    "421",
                    "--semester-key",
                    "2026spring",
                    "--semester-name",
                    "2026 春季学期",
                ]
            )
            with patch.object(
                cli.jw, "collect_jw_bundle", return_value=(bundle, sources)
            ) as collect:
                self.assertEqual(0, args.handler(args, lambda _: None))

            self.assertEqual(bundle, json.loads((root / "bundle.json").read_text(encoding="utf-8")))
            self.assertTrue((root / "private" / "course-datum.raw.json").exists())
            self.assertTrue((root / "private" / "exam-arrange.raw.html").exists())
            self.assertEqual(421, collect.call_args.kwargs["semester_id"])
            self.assertEqual("2026spring", collect.call_args.kwargs["semester_key"])

    def test_young_enrolment_command_defaults_to_normalized_output_only(self):
        normalized = {
            "activities": [{"sourceActivityId": "activity-1"}],
            "metadata": {"pages": 1},
        }
        raw = SimpleNamespace(records=({"id": "activity-1", "userId": "private"},))

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = cli.build_parser().parse_args(
                ["collect", "young-enrolment", "--output", str(root / "out.json")]
            )
            with patch.object(
                cli.enrolment,
                "collect_enrolment_snapshot",
                return_value=(normalized, raw),
            ):
                self.assertEqual(0, args.handler(args, lambda _: None))

            self.assertEqual(normalized, json.loads((root / "out.json").read_text(encoding="utf-8")))
            self.assertFalse((root / "private").exists())

    def test_young_schedule_command_passes_today_and_saves_named_raw_file(self):
        normalized = {
            "schedules": [{"sourceScheduleId": "schedule-1"}],
            "metadata": {"queriedDates": 1},
        }
        raw = SimpleNamespace(records=({"id": "schedule-1", "userId": "private"},))

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = cli.build_parser().parse_args(
                [
                    "collect",
                    "young-schedule",
                    "--today",
                    "2026-07-22",
                    "--output",
                    str(root / "out.json"),
                    "--save-raw",
                    "--raw-dir",
                    str(root / "private"),
                ]
            )
            with patch.object(
                cli.schedule,
                "collect_schedule_snapshot",
                return_value=(normalized, raw),
            ) as collect:
                self.assertEqual(0, args.handler(args, lambda _: None))

            self.assertEqual(date(2026, 7, 22), collect.call_args.kwargs["today"])
            raw_path = root / "private" / "ustc-young-my-schedule.raw.json"
            self.assertEqual("private", json.loads(raw_path.read_text(encoding="utf-8"))["records"][0]["userId"])


class CampusCommandTests(unittest.TestCase):
    def test_collect_writes_summary_and_returns_one_on_partial_failure(self):
        payload = {
            "source": "ustc_campus_catalog",
            "sources": {
                "teach_notice": {
                    "status": "updated",
                    "activeCount": 2,
                    "error": None,
                },
                "finance_notice": {
                    "status": "failed",
                    "activeCount": 0,
                    "error": "layout changed",
                },
            },
            "metadata": {"updated": 1, "skipped": 0, "failed": 1},
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = cli.build_parser().parse_args(
                [
                    "collect",
                    "campus",
                    "--source",
                    "teach_notice",
                    "--output",
                    str(root / "summary.json"),
                    "--catalog-path",
                    str(root / "catalog.json"),
                ]
            )
            with patch.object(campus, "refresh_catalogs", return_value=payload) as refresh:
                result = args.handler(args, lambda _: None)

            written = json.loads((root / "summary.json").read_text(encoding="utf-8"))

        self.assertEqual(1, result)
        self.assertEqual(payload, written)
        self.assertEqual(["teach_notice"], refresh.call_args.kwargs["sources"])

    def test_query_writes_empty_offline_result(self):
        payload = {
            "source": "ustc_campus_catalog",
            "query": "不存在",
            "results": [],
            "metadata": {"resultCount": 0},
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = cli.build_parser().parse_args(
                [
                    "query",
                    "campus",
                    "--text",
                    "不存在",
                    "--output",
                    str(root / "query.json"),
                    "--catalog-path",
                    str(root / "catalog.json"),
                ]
            )
            with patch.object(campus, "search_catalog", return_value=payload) as search:
                result = args.handler(args, lambda _: None)

            written = json.loads((root / "query.json").read_text(encoding="utf-8"))

        self.assertEqual(0, result)
        self.assertEqual(payload, written)
        self.assertNotIn("client", search.call_args.kwargs)

    def test_read_forwards_stale_and_candidate_link_ids(self):
        payload = {
            "id": "knowledge_1",
            "title": "公开指南",
            "content": "正文不应出现在状态消息中",
            "stale": False,
        }
        statuses: list[str] = []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = cli.build_parser().parse_args(
                [
                    "read",
                    "campus",
                    "--entry-id",
                    "campus_1",
                    "--follow-link-id",
                    "link_1",
                    "--no-stale",
                    "--output",
                    str(root / "detail.json"),
                ]
            )
            with patch.object(campus, "read_detail", return_value=payload) as read:
                result = args.handler(args, statuses.append)

        self.assertEqual(0, result)
        self.assertFalse(read.call_args.kwargs["allow_stale"])
        self.assertEqual(["link_1"], read.call_args.kwargs["follow_link_ids"])
        self.assertNotIn("正文不应出现在状态消息中", " ".join(statuses))

    def test_main_handles_campus_error_without_traceback(self):
        with patch.object(
            campus,
            "search_catalog",
            side_effect=campus.CampusError("catalog unavailable"),
        ):
            result = cli.main(["query", "campus", "--text", "缓考"])

        self.assertEqual(1, result)


class CommonStorageTests(unittest.TestCase):
    def test_dump_json_creates_parent_and_trailing_newline(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "nested" / "value.json"

            returned = storage.dump_json(path, {"text": "课程"})

            self.assertEqual(returned, path)
            self.assertEqual(
                path.read_text(encoding="utf-8"),
                '{\n  "text": "课程"\n}\n',
            )


class CommonBrowserTests(unittest.TestCase):
    def test_run_in_edge_uses_visible_persistent_edge_and_closes(self):
        context = FakeContext()
        chromium = FakeChromium(context)
        factory = lambda: FakePlaywrightManager(chromium)

        with tempfile.TemporaryDirectory() as directory:
            result = browser.run_in_edge(
                lambda page: page.marker,
                profile_dir=Path(directory),
                playwright_factory=factory,
            )

        self.assertEqual(result, "page")
        self.assertEqual(chromium.launch_calls[0][1]["channel"], "msedge")
        self.assertFalse(chromium.launch_calls[0][1]["headless"])
        self.assertTrue(context.closed)


if __name__ == "__main__":
    unittest.main()
