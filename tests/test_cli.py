import json
import tempfile
import unittest
from datetime import date
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from ustc_assistant import cli
from ustc_assistant.common import browser, storage
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

    def test_collect_parsers_preserve_prototype_defaults(self):
        parser = cli.build_parser()

        jw = parser.parse_args(["collect", "jw", "--semester-id", "421"])
        schedule = parser.parse_args(
            ["collect", "young-schedule", "--today", "2026-07-22"]
        )

        self.assertEqual(jw.semester_key, "2026spring")
        self.assertEqual(jw.output, Path("tmp/ustc-jw-import.generated.json"))
        self.assertEqual(schedule.today.isoformat(), "2026-07-22")

    def test_icourse_service_exposes_app_callable_query_runner(self):
        self.assertTrue(callable(icourse_service.run_query))


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
                ]
            )
            with patch.object(cli.jw, "collect_jw_bundle", return_value=(bundle, sources)):
                self.assertEqual(0, args.handler(args, lambda _: None))

            self.assertEqual(bundle, json.loads((root / "bundle.json").read_text(encoding="utf-8")))
            self.assertTrue((root / "private" / "course-datum.raw.json").exists())
            self.assertTrue((root / "private" / "exam-arrange.raw.html").exists())

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
