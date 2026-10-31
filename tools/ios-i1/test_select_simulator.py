"""Synthetic-only tests for compatible iOS simulator selection."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from typing import Any


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("ios_i1_select_simulator", HERE / "select_simulator.py")
assert SPEC is not None and SPEC.loader is not None
selector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(selector)

TARGET_ID = selector.TARGET_DEVICE_TYPE_ID
DUO_ID = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"
IPHONE_ID = "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
IPAD_ID = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4-8GB"


def device_types(*, include_target: bool = True) -> dict[str, Any]:
    values = [
        {"identifier": DUO_ID, "name": "iPhone Duo", "productFamily": "iPhone"},
        {"identifier": IPHONE_ID, "name": "iPhone 16 Pro", "productFamily": "iPhone"},
        {"identifier": IPAD_ID, "name": "iPad Pro", "productFamily": "iPad"},
    ]
    if include_target:
        values.append({"identifier": TARGET_ID, "name": "iPhone 15 Pro", "productFamily": "iPhone"})
    return {"devicetypes": values}


def runtime(version: str, supported_ids: list[str] | None, *, available: bool = True) -> dict[str, Any]:
    item: dict[str, Any] = {
        "platform": "iOS",
        "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-" + version.replace(".", "-"),
        "version": version,
        "isAvailable": available,
    }
    if supported_ids is not None:
        item["supportedDeviceTypes"] = [{"identifier": value} for value in supported_ids]
    return item


def runtimes(*items: dict[str, Any]) -> dict[str, Any]:
    return {"runtimes": list(items)}


class SelectSimulatorTests(unittest.TestCase):
    def assert_code(self, code: str, callback: Any) -> None:
        with self.assertRaises(selector.SelectionError) as caught:
            callback()
        self.assertEqual(caught.exception.code, code)

    def test_falls_back_from_newest_incompatible_runtime_to_target_phone(self) -> None:
        result = selector.select_pair(
            runtimes(
                runtime("27.1", [DUO_ID]),
                runtime("27.0", [TARGET_ID, IPHONE_ID]),
            ),
            device_types(),
        )
        self.assertEqual(
            result,
            (
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                TARGET_ID,
            ),
        )

    def test_falls_back_to_an_explicitly_supported_iphone_if_target_is_unavailable(self) -> None:
        result = selector.select_pair(
            runtimes(
                runtime("27.0", [IPHONE_ID]),
                runtime("27.1", [DUO_ID]),
            ),
            device_types(),
        )
        self.assertEqual(
            result,
            (
                "com.apple.CoreSimulator.SimRuntime.iOS-27-1",
                DUO_ID,
            ),
        )

    def test_no_compatible_iphone_pair_is_rejected(self) -> None:
        self.assert_code(
            "no_compatible_pair",
            lambda: selector.select_pair(runtimes(runtime("27.1", [IPAD_ID])), device_types()),
        )

    def test_runtime_versions_are_sorted_numerically(self) -> None:
        result = selector.select_pair(
            runtimes(
                runtime("27.0.9", [TARGET_ID]),
                runtime("27.0.10", [TARGET_ID]),
            ),
            device_types(),
        )
        self.assertEqual(
            result[0],
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0-10",
        )

    def test_missing_supported_device_types_fails_closed(self) -> None:
        self.assert_code(
            "missing_supported_device_types",
            lambda: selector.select_pair(
                runtimes(runtime("27.0", [TARGET_ID]), runtime("27.1", None)),
                device_types(),
            ),
        )

    def test_unavailable_runtime_is_ignored(self) -> None:
        result = selector.select_pair(
            runtimes(
                runtime("27.1", None, available=False),
                runtime("27.0", [TARGET_ID]),
            ),
            device_types(),
        )
        self.assertEqual(result[1], TARGET_ID)

    def test_unrecognized_json_shapes_and_unknown_device_ids_are_fixed_errors(self) -> None:
        self.assert_code(
            "unexpected_runtimes_shape",
            lambda: selector.select_pair({"runtimeList": []}, device_types()),
        )
        self.assert_code(
            "unexpected_device_types_shape",
            lambda: selector.select_pair(runtimes(runtime("27.0", [TARGET_ID])), {"types": []}),
        )
        self.assert_code(
            "unexpected_device_type_shape",
            lambda: selector.select_pair(
                runtimes(runtime("27.0", [TARGET_ID])),
                {"devicetypes": [{"identifier": TARGET_ID}]},
            ),
        )
        self.assert_code(
            "unknown_supported_device_type",
            lambda: selector.select_pair(
                runtimes(runtime("27.0", ["com.apple.CoreSimulator.SimDeviceType.iPhone-Unknown"])),
                device_types(),
            ),
        )

    def test_cli_prints_only_the_selected_pair_and_uses_fixed_errors(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ios-i1-simulator-test-", dir=str(HERE)) as temporary:
            root = Path(temporary)
            runtime_path = root / "runtimes.json"
            types_path = root / "device-types.json"
            runtime_path.write_text(
                json.dumps(runtimes(runtime("27.0", [TARGET_ID]))), encoding="utf-8"
            )
            types_path.write_text(json.dumps(device_types()), encoding="utf-8")

            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                result = selector.main([
                    "--runtimes", str(runtime_path),
                    "--device-types", str(types_path),
                ])
            self.assertEqual(result, 0)
            self.assertEqual(stderr.getvalue(), "")
            self.assertEqual(
                stdout.getvalue(),
                f"com.apple.CoreSimulator.SimRuntime.iOS-27-0 {TARGET_ID}\n",
            )
            self.assertEqual(len(stdout.getvalue().splitlines()), 1)

            types_path.write_text("not-json", encoding="utf-8")
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                result = selector.main([
                    "--runtimes", str(runtime_path),
                    "--device-types", str(types_path),
                ])
            self.assertEqual(result, 2)
            self.assertEqual(stdout.getvalue(), "")
            self.assertEqual(stderr.getvalue(), "i1 simulator selection failed: invalid_json\n")


if __name__ == "__main__":
    unittest.main()
