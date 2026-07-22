from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from datetime import date
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "collect_ustc_young_schedule.py"


def load_cli_module():
    if not MODULE_PATH.exists():
        return None
    spec = importlib.util.spec_from_file_location(
        "collect_ustc_young_schedule", MODULE_PATH
    )
    if spec is None or spec.loader is None:
        return None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


cli = load_cli_module()


def sample_record():
    return {
        "id": "schedule-001",
        "itemId": "activity-001",
        "title": "Sample activity",
        "startTime": "2026-07-22 16:00:00",
        "endTime": "2026-07-22 17:30:00",
        "place": "Sample room",
        "content": "<p>First &amp; second<br>line</p>",
        "userId": "must-not-enter-normal-output",
        "createBy": "must-not-enter-normal-output",
    }


class ModuleContractTests(unittest.TestCase):
    def test_cli_module_exists(self):
        self.assertIsNotNone(cli, "schedule CLI module must exist")


@unittest.skipIf(cli is None, "CLI module not implemented yet")
class NormalizationTests(unittest.TestCase):
    def test_normalizes_beijing_times_and_excludes_personal_fields(self):
        collection = SimpleNamespace(
            records=(sample_record(),),
            queried_from=date(2026, 7, 14),
            queried_through=date(2026, 8, 21),
            queried_dates=39,
            empty_dates=38,
        )

        result = cli.normalize_collection(
            collection, collected_at="2026-07-21T20:00:00+08:00"
        )

        self.assertEqual("ustc_young_my_schedule", result["source"])
        self.assertEqual("2026-07-14", result["metadata"]["queriedFrom"])
        self.assertEqual("2026-08-21", result["metadata"]["queriedThrough"])
        schedule = result["schedules"][0]
        self.assertEqual("schedule-001", schedule["sourceScheduleId"])
        self.assertEqual("activity-001", schedule["sourceActivityId"])
        self.assertEqual("2026-07-22T16:00:00+08:00", schedule["startsAt"])
        self.assertEqual("First & second\nline", schedule["descriptionText"])
        serialized = json.dumps(result, ensure_ascii=False)
        self.assertNotIn("userId", serialized)
        self.assertNotIn("must-not-enter-normal-output", serialized)


@unittest.skipIf(cli is None, "CLI module not implemented yet")
class OutputAndCliTests(unittest.TestCase):
    def test_defaults_are_private_safe_and_today_is_optional(self):
        args = cli.parse_args([])

        self.assertEqual(
            Path("tmp/ustc-young-my-schedule.generated.json"), args.output
        )
        self.assertEqual(Path("tmp/private"), args.raw_dir)
        self.assertFalse(args.save_raw)
        self.assertIsNone(args.today)

    def test_rejects_invalid_today_argument(self):
        with self.assertRaises(SystemExit):
            cli.parse_args(["--today", "2026/07/21"])

    def test_run_collection_passes_explicit_today_and_writes_snapshot(self):
        calls = []

        def fake_collect(**kwargs):
            calls.append(kwargs)
            return SimpleNamespace(
                records=(sample_record(),),
                queried_from=date(2026, 7, 14),
                queried_through=date(2026, 8, 21),
                queried_dates=39,
                empty_dates=38,
            )

        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "snapshot.json"
            args = cli.parse_args(
                ["--today", "2026-07-21", "--output", str(output)]
            )
            messages = []

            exit_code = cli.run_collection(
                args, collect_fn=fake_collect, status=messages.append
            )

            saved = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(0, exit_code)
        self.assertEqual(date(2026, 7, 21), calls[0]["today"])
        self.assertEqual(1, saved["metadata"]["scheduleCount"])
        self.assertTrue(any("1 schedules" in message for message in messages))

    def test_save_raw_uses_private_schedule_filename(self):
        collection = SimpleNamespace(records=(sample_record(),))
        normalized = {"schedules": []}

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            output = root / "snapshot.json"
            written = cli.write_collection_outputs(
                normalized=normalized,
                records=collection.records,
                output_path=output,
                save_raw=True,
                raw_dir=root / "private",
            )

            raw_path = root / "private" / "ustc-young-my-schedule.raw.json"
            raw = json.loads(raw_path.read_text(encoding="utf-8"))

        self.assertEqual([output, raw_path], written)
        self.assertEqual(
            "must-not-enter-normal-output", raw["records"][0]["userId"]
        )


if __name__ == "__main__":
    unittest.main()
