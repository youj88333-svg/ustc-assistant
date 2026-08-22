import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from ustc_assistant import cli
from ustc_assistant.common import browser, storage


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
    def test_root_parser_exposes_collect_and_config(self):
        parser = cli.build_parser()

        collect_args = parser.parse_args(
            ["collect", "jw", "--account-id", "acct_cli"]
        )
        config_args = parser.parse_args(["config", "generate-flutter-defaults"])

        self.assertEqual(collect_args.command, "collect")
        self.assertEqual(collect_args.source, "jw")
        self.assertEqual(config_args.command, "config")
        self.assertEqual(config_args.config_command, "generate-flutter-defaults")

        # Retired subcommands are no longer accepted (argparse exits with 2).
        for argv in (
            ["collect", "young-schedule"],
            ["query", "icourse", "--course", "x"],
            ["collect", "campus"],
        ):
            with self.assertRaises(SystemExit):
                parser.parse_args(argv)

    def test_collect_parsers_use_current_semester_defaults(self):
        parser = cli.build_parser()

        jw = parser.parse_args(
            ["collect", "jw", "--account-id", "acct_cli"]
        )

        self.assertEqual(jw.semester_id, 461)
        self.assertEqual(jw.semester_key, "2026fall")
        self.assertEqual(jw.display_name, "2026 秋季学期")
        self.assertEqual(jw.output, Path("tmp/ustc-jw-import.generated.json"))

    def test_jw_semester_override_requires_complete_triple(self):
        result = cli.main(
            [
                "collect",
                "jw",
                "--account-id",
                "acct_cli",
                "--semester-id",
                "421",
            ]
        )

        self.assertEqual(result, 1)

    def test_jw_collect_command_requires_account_id_without_collecting(self):
        with patch.object(cli.jw, "collect_jw_source_bundle") as collect_jw:
            self.assertEqual(1, cli.main(["collect", "jw"]))

        collect_jw.assert_not_called()

    def test_config_generate_flutter_defaults_parses(self):
        parser = cli.build_parser()

        args = parser.parse_args(["config", "generate-flutter-defaults"])

        self.assertEqual("config", args.command)
        self.assertEqual("generate-flutter-defaults", args.config_command)
        self.assertTrue(callable(args.handler))

    def test_config_generate_flutter_defaults_writes_dart_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "nested" / "generated_source_defaults.dart"
            args = cli.build_parser().parse_args(
                ["config", "generate-flutter-defaults", "--output", str(output)]
            )

            result = args.handler(args, lambda _: None)

            self.assertEqual(0, result)
            self.assertTrue(output.exists())
            content = output.read_text(encoding="utf-8")
            self.assertIn("// GENERATED FILE - DO NOT EDIT.", content)
            self.assertIn("const int kDefaultJwSemesterId = 461;", content)
            self.assertIn("const String kDefaultJwSemesterKey = '2026fall';", content)
            self.assertIn("const String kDefaultJwSemesterDisplayName = '2026 秋季学期';", content)

    def test_config_generate_flutter_defaults_handles_invalid_json_without_output(
        self,
    ):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "out" / "generated.dart"
            parser = cli.build_parser()
            args = parser.parse_args(
                ["config", "generate-flutter-defaults", "--output", str(output)]
            )
            with patch.object(cli, "load_default_jw_semester") as load:
                load.side_effect = cli.SourceConfigError("invalid configuration")
                with self.assertRaises(cli.SourceConfigError):
                    args.handler(args, lambda _: None)

            self.assertFalse(output.exists())

class CollectorCommandTests(unittest.TestCase):
    def test_jw_command_writes_source_bundle_and_optional_raw_sources(self):
        bundle = {
            "schemaVersion": "1.0",
            "subject": {"accountId": "acct_cli"},
            "data": {
                "calendarEvents": [{"externalId": "event-1"}],
                "sourceRecords": [{"externalId": "source-1"}],
                "courseSeries": [],
                "scheduleRelations": [],
            },
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
                    "--account-id",
                    "acct_cli",
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
                cli.jw,
                "collect_jw_source_bundle",
                return_value=(bundle, sources),
            ) as collect:
                self.assertEqual(0, args.handler(args, lambda _: None))

            self.assertEqual(bundle, json.loads((root / "bundle.json").read_text(encoding="utf-8")))
            self.assertNotIn("metadata", bundle)
            self.assertTrue((root / "private" / "course-datum.raw.json").exists())
            self.assertTrue((root / "private" / "exam-arrange.raw.html").exists())
            self.assertEqual("acct_cli", collect.call_args.kwargs["account_id"])
            self.assertEqual(421, collect.call_args.kwargs["semester"].semester_id)
            self.assertEqual("2026spring", collect.call_args.kwargs["semester"].semester_key)


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
