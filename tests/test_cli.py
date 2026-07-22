import tempfile
import unittest
from pathlib import Path

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
    def test_root_parser_exposes_collect_and_query(self):
        parser = cli.build_parser()

        collect_args = parser.parse_args(["collect", "jw"])
        query_args = parser.parse_args(["query", "icourse", "--course", "test"])

        self.assertEqual(collect_args.command, "collect")
        self.assertEqual(collect_args.source, "jw")
        self.assertEqual(query_args.command, "query")
        self.assertEqual(query_args.source, "icourse")


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
