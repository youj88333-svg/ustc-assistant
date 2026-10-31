#!/usr/bin/env python3
"""Select an actually compatible iOS 27 simulator pair from simctl JSON."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


TARGET_DEVICE_TYPE_ID = "com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro"
IOS_RUNTIME_PREFIX = "com.apple.CoreSimulator.SimRuntime.iOS-"
MAX_INPUT_BYTES = 4 * 1024 * 1024
_IDENTIFIER = re.compile(r"[A-Za-z0-9._-]+\Z")
_VERSION = re.compile(r"[0-9]+(?:\.[0-9]+)*\Z")


class SelectionError(Exception):
    """A fixed error code safe to print without echoing input JSON."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def _fail(code: str) -> None:
    raise SelectionError(code)


def _is_identifier(value: Any) -> bool:
    return isinstance(value, str) and bool(_IDENTIFIER.fullmatch(value))


def _numeric_version(value: Any) -> tuple[int, ...]:
    if not isinstance(value, str) or len(value) > 64 or not _VERSION.fullmatch(value):
        _fail("invalid_runtime_version")
    components = value.split(".")
    if len(components) > 8 or any(len(part) > 9 for part in components):
        _fail("invalid_runtime_version")
    parts = [int(part) for part in components]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def _device_type_families(document: Any) -> dict[str, str]:
    if not isinstance(document, dict) or not isinstance(document.get("devicetypes"), list):
        _fail("unexpected_device_types_shape")

    result: dict[str, str] = {}
    for item in document["devicetypes"]:
        if not isinstance(item, dict):
            _fail("unexpected_device_type_shape")
        identifier = item.get("identifier")
        family = item.get("productFamily")
        if not _is_identifier(identifier) or not isinstance(family, str) or not family:
            _fail("unexpected_device_type_shape")
        if identifier in result:
            _fail("duplicate_device_type")
        result[identifier] = family
    return result


def _ios27_runtimes(document: Any) -> list[tuple[tuple[int, ...], str, list[str]]]:
    if not isinstance(document, dict) or not isinstance(document.get("runtimes"), list):
        _fail("unexpected_runtimes_shape")

    result: list[tuple[tuple[int, ...], str, list[str]]] = []
    seen: set[str] = set()
    for item in document["runtimes"]:
        if not isinstance(item, dict):
            _fail("unexpected_runtime_shape")
        platform = item.get("platform")
        identifier = item.get("identifier")
        available = item.get("isAvailable")
        if (
            not isinstance(platform, str)
            or not _is_identifier(identifier)
            or type(available) is not bool
        ):
            _fail("unexpected_runtime_shape")
        if platform != "iOS":
            continue
        if not identifier.startswith(IOS_RUNTIME_PREFIX):
            _fail("unexpected_runtime_shape")

        version = _numeric_version(item.get("version"))
        if not version or version[0] != 27 or not available:
            continue
        if "supportedDeviceTypes" not in item:
            _fail("missing_supported_device_types")
        supported = item["supportedDeviceTypes"]
        if not isinstance(supported, list):
            _fail("unexpected_supported_device_types_shape")
        if identifier in seen:
            _fail("duplicate_runtime_identifier")
        seen.add(identifier)

        supported_ids: list[str] = []
        for device in supported:
            if not isinstance(device, dict) or not _is_identifier(device.get("identifier")):
                _fail("unexpected_supported_device_type_shape")
            supported_ids.append(device["identifier"])
        result.append((version, identifier, supported_ids))
    return result


def select_pair(runtimes_document: Any, device_types_document: Any) -> tuple[str, str]:
    """Return the best `(runtime identifier, device type identifier)` pair.

    Only available iOS 27 runtimes and their explicit `supportedDeviceTypes`
    entries are considered. An iPhone 15 Pro runtime is preferred for the
    target phone; the latest numeric runtime supporting any iPhone is fallback.
    """

    device_families = _device_type_families(device_types_document)
    runtimes = _ios27_runtimes(runtimes_document)

    candidates: list[tuple[tuple[int, ...], str, str]] = []
    for version, runtime_id, supported_ids in runtimes:
        for device_id in supported_ids:
            family = device_families.get(device_id)
            if family is None:
                _fail("unknown_supported_device_type")
            if family == "iPhone":
                candidates.append((version, runtime_id, device_id))

    if not candidates:
        _fail("no_compatible_pair")

    target_candidates = [
        candidate for candidate in candidates if candidate[2] == TARGET_DEVICE_TYPE_ID
    ]
    pool = target_candidates or candidates
    newest_version = max(candidate[0] for candidate in pool)
    newest = [candidate for candidate in pool if candidate[0] == newest_version]
    _, runtime_id, device_id = min(newest, key=lambda candidate: (candidate[1], candidate[2]))
    return runtime_id, device_id


def _read_document(path: str) -> Any:
    try:
        file_path = Path(path)
        if file_path.stat().st_size > MAX_INPUT_BYTES:
            _fail("input_too_large")
        content = file_path.read_bytes()
    except SelectionError:
        raise
    except (OSError, TypeError, ValueError):
        _fail("input_unreadable")
    if len(content) > MAX_INPUT_BYTES:
        _fail("input_too_large")
    try:
        return json.loads(content.decode("utf-8", errors="strict"))
    except (UnicodeError, ValueError, json.JSONDecodeError, RecursionError):
        _fail("invalid_json")


class _SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        del message
        _fail("invalid_arguments")


def main(argv: list[str] | None = None) -> int:
    parser = _SafeArgumentParser(description="Select a compatible iOS simulator pair.")
    parser.add_argument("--runtimes", required=True)
    parser.add_argument("--device-types", required=True)
    try:
        args = parser.parse_args(argv)
        runtime_id, device_type_id = select_pair(
            _read_document(args.runtimes),
            _read_document(args.device_types),
        )
    except SelectionError as exc:
        sys.stderr.write(f"i1 simulator selection failed: {exc.code}\n")
        return 2
    except SystemExit as exc:
        return int(exc.code or 0)
    except Exception:
        sys.stderr.write("i1 simulator selection failed: internal_error\n")
        return 2

    sys.stdout.write(f"{runtime_id} {device_type_id}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
