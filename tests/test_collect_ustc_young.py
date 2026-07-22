from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "collect_ustc_young.py"


def load_cli_module():
    if not MODULE_PATH.exists():
        return None
    spec = importlib.util.spec_from_file_location("collect_ustc_young", MODULE_PATH)
    if spec is None or spec.loader is None:
        return None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


cli = load_cli_module()


def sample_record():
    return {
        "id": "activity-001",
        "itemName": "Sample activity",
        "itemStatus": 26,
        "itemStatus_dictText": "Open",
        "module": "z",
        "module_dictText": "Knowledge",
        "itemCategory": "1",
        "itemCategory_dictText": "Series",
        "activityLevel": "school",
        "activityLevel_dictText": "School",
        "organizer_dictText": "Sample organizer",
        "sponsor_dictText": "Sample sponsor",
        "businessDeptName": "Sample department",
        "st": "2026-07-01 10:00:00",
        "et": "2026-08-01 10:00:00",
        "applySt": "2026-07-01 09:00:00",
        "applyEt": "2026-07-31 23:59:00",
        "itemLimitNum": 20,
        "applyNum": 3,
        "partakeNum": 2,
        "placeInfo": "East campus",
        "form": "1",
        "form_dictText": "Submit work",
        "serviceHour": "2.0",
        "validHour": 2,
        "baseContent": "<p>Description</p>",
        "conceive": "<p>Requirements</p>",
        "pic": "group/sample.jpg",
        "unknownSensitiveField": "must-not-enter-normal-output",
    }


class ModuleContractTests(unittest.TestCase):
    def test_cli_module_exists(self):
        self.assertIsNotNone(cli, "second-classroom CLI module must exist")


@unittest.skipIf(cli is None, "CLI module not implemented yet")
class NormalizationTests(unittest.TestCase):
    def test_normalizes_known_activity_fields_and_metadata(self):
        collection = SimpleNamespace(
            records=(sample_record(),),
            reported_total=1,
            pages=1,
        )

        result = cli.normalize_collection(
            collection,
            collected_at="2026-07-21T12:00:00+08:00",
        )

        self.assertEqual("ustc_young_enrolment_list", result["source"])
        self.assertEqual(1, result["metadata"]["reportedTotal"])
        self.assertEqual(1, result["metadata"]["activityCount"])
        activity = result["activities"][0]
        self.assertEqual("activity-001", activity["sourceActivityId"])
        self.assertEqual("Sample activity", activity["name"])
        self.assertEqual("Knowledge", activity["moduleLabel"])
        self.assertEqual("2026-07-31 23:59:00", activity["applicationEndsAt"])
        self.assertEqual("<p>Description</p>", activity["descriptionHtml"])
        self.assertNotIn("unknownSensitiveField", activity)
        self.assertNotIn("must-not-enter-normal-output", json.dumps(result))


@unittest.skipIf(cli is None, "CLI module not implemented yet")
class OutputStorageTests(unittest.TestCase):
    def test_default_mode_writes_only_normalized_output(self):
        collection = SimpleNamespace(
            records=(sample_record(),),
            reported_total=1,
            pages=1,
        )
        normalized = cli.normalize_collection(
            collection,
            collected_at="2026-07-21T12:00:00+08:00",
        )

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            output = root / "activities.json"
            raw_dir = root / "private"
            written = cli.write_collection_outputs(
                normalized=normalized,
                records=collection.records,
                output_path=output,
                save_raw=False,
                raw_dir=raw_dir,
            )

            self.assertEqual([output], written)
            self.assertTrue(output.exists())
            self.assertFalse(raw_dir.exists())
            saved = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual("Sample activity", saved["activities"][0]["name"])

    def test_save_raw_adds_complete_private_record_file(self):
        collection = SimpleNamespace(
            records=(sample_record(),),
            reported_total=1,
            pages=1,
        )
        normalized = cli.normalize_collection(
            collection,
            collected_at="2026-07-21T12:00:00+08:00",
        )

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            output = root / "activities.json"
            raw_dir = root / "private"
            written = cli.write_collection_outputs(
                normalized=normalized,
                records=collection.records,
                output_path=output,
                save_raw=True,
                raw_dir=raw_dir,
            )

            raw_path = raw_dir / "ustc-young-enrolment.raw.json"
            self.assertEqual([output, raw_path], written)
            raw = json.loads(raw_path.read_text(encoding="utf-8"))
            self.assertEqual(
                "must-not-enter-normal-output",
                raw["records"][0]["unknownSensitiveField"],
            )


@unittest.skipIf(cli is None, "CLI module not implemented yet")
class CliFlowTests(unittest.TestCase):
    def test_parse_args_has_private_safe_defaults(self):
        args = cli.parse_args([])

        self.assertEqual(
            Path("tmp/ustc-young-enrolment.generated.json"),
            args.output,
        )
        self.assertEqual(Path("tmp/private"), args.raw_dir)
        self.assertFalse(args.save_raw)
        self.assertEqual(300, args.login_timeout_seconds)

    def test_run_collection_uses_collector_and_writes_output(self):
        calls = []

        def fake_collect(**kwargs):
            calls.append(kwargs)
            return SimpleNamespace(
                records=(sample_record(),),
                reported_total=1,
                pages=1,
            )

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            output = root / "activities.json"
            profile = root / "profile"
            args = cli.parse_args(
                ["--output", str(output), "--profile-dir", str(profile)]
            )
            messages = []

            exit_code = cli.run_collection(
                args,
                collect_fn=fake_collect,
                status=messages.append,
            )

            self.assertEqual(0, exit_code)
            self.assertEqual("Sample activity", json.loads(output.read_text(encoding="utf-8"))["activities"][0]["name"])

        self.assertEqual(profile, calls[0]["profile_dir"])
        self.assertEqual(300_000, calls[0]["login_timeout_ms"])
        self.assertTrue(any("1 activities" in message for message in messages))


if __name__ == "__main__":
    unittest.main()
