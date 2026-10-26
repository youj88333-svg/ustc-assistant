"""Synthetic-only tests for the I0 IPA verifier; no network or device access."""

from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import plistlib
import stat
import struct
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path
from typing import Any
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
MODULE_SPEC = importlib.util.spec_from_file_location("ios_i0_verify_package", HERE / "verify_package.py")
assert MODULE_SPEC is not None and MODULE_SPEC.loader is not None
verify_package_module = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(verify_package_module)

REVISION = "0123456789abcdef0123456789abcdef01234567"
APP_ID = verify_package_module.APP_BUNDLE_ID
WIDGET_ID = verify_package_module.WIDGET_BUNDLE_ID
GROUP = verify_package_module.APP_GROUP_BASE
WIDGET_ROOT = verify_package_module.WIDGET_ROOT
APP_EXECUTABLE_PATH = "Payload/Runner.app/Runner"
WIDGET_EXECUTABLE_PATH = f"{WIDGET_ROOT}/I0Widget"
AOT_PATH = verify_package_module.APP_FRAMEWORK_EXECUTABLE
FLUTTER_PATH = verify_package_module.FLUTTER_FRAMEWORK_EXECUTABLE


def macho(
    file_type: int,
    *,
    platform: int = 2,
    payload: bytes = b"",
    command_bytes_override: int | None = None,
    command_count_override: int = 1,
    command_blob: bytes | None = None,
) -> bytes:
    if command_blob is None:
        command_blob = struct.pack("<IIIIII", 0x32, 24, platform, 0x001B0000, 0x001B0000, 0)
    command_bytes = len(command_blob) if command_bytes_override is None else command_bytes_override
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, file_type, command_count_override, command_bytes, 0, 0)
    return header + command_blob + payload


def app_info(
    *,
    bundle_id: str = APP_ID,
    revision: str = REVISION,
    group: str = GROUP,
    xml: bool = False,
) -> bytes:
    value: dict[str, Any] = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleExecutable": "Runner",
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "I0SourceRevision": revision,
        "I0AppGroupBaseIdentifier": group,
    }
    fmt = plistlib.FMT_XML if xml else plistlib.FMT_BINARY
    return plistlib.dumps(value, fmt=fmt)


def widget_info(*, bundle_id: str = WIDGET_ID, revision: str = REVISION, group: str = GROUP, xml: bool = True) -> bytes:
    value = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleExecutable": "I0Widget",
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "I0SourceRevision": revision,
        "I0AppGroupBaseIdentifier": group,
        "NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"},
    }
    fmt = plistlib.FMT_XML if xml else plistlib.FMT_BINARY
    return plistlib.dumps(value, fmt=fmt)


def manifest(*, revision: str = REVISION) -> bytes:
    value = {
        "schemaVersion": 1,
        "kind": "ios-i0-unsigned-ipa-v1",
        "sourceRevision": revision,
        "flutterVersion": "3.47.7",
        "xcodeVersion": "27.1",
        "buildMode": "release",
        "artifactStatus": "unsigned-personal-probe",
        "appBundleId": APP_ID,
        "widgetBundleId": WIDGET_ID,
        "appGroupBase": GROUP,
        "metadata": {"fixture": "synthetic"},
    }
    return json.dumps(value, separators=(",", ":")).encode("utf-8")


def fixture_members(
    *,
    host_platform: int = 2,
    widget_platform: int = 2,
    aot_revision: bool = True,
    aot_prefix: bytes = b"AOT-FIXTURE-",
    app_bundle_id: str = APP_ID,
    app_info_revision: str = REVISION,
    widget_info_revision: str = REVISION,
    app_group: str = GROUP,
    widget_group: str = GROUP,
    include_widget: bool = True,
) -> list[tuple[str, bytes, int | None]]:
    marker = REVISION.encode("ascii") if aot_revision else b"no-revision-in-this-AOT-image"
    members: list[tuple[str, bytes, int | None]] = [
        ("Payload/Runner.app/ios-i0-provenance.json", manifest(), None),
        ("Payload/Runner.app/Info.plist", app_info(bundle_id=app_bundle_id, revision=app_info_revision, group=app_group), None),
        (APP_EXECUTABLE_PATH, macho(2, platform=host_platform, payload=b"runner"), None),
        (AOT_PATH, macho(6, payload=aot_prefix + marker + b"-AOT-END"), None),
        (FLUTTER_PATH, macho(6, payload=b"flutter-engine"), None),
    ]
    if include_widget:
        members.extend(
            [
                (f"{WIDGET_ROOT}/Info.plist", widget_info(revision=widget_info_revision, group=widget_group), None),
                (WIDGET_EXECUTABLE_PATH, macho(2, platform=widget_platform, payload=b"widget"), None),
            ]
        )
    return members


def write_ipa(path: Path, members: list[tuple[str, bytes, int | None]], *, extra_entries: list[tuple[str, bytes]] | None = None) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data, external_attr in members:
            if external_attr is None:
                archive.writestr(name, data)
            else:
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = external_attr
                archive.writestr(info, data)
        for name, data in extra_entries or []:
            archive.writestr(name, data)
    return path


class VerifyPackageTests(unittest.TestCase):
    def setUp(self) -> None:
        # Keep fixtures on E: and disposable even when the host TEMP points at C:.
        self.temp = tempfile.TemporaryDirectory(prefix="ios-i0-test-", dir=str(HERE))
        self.root = Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def ipa(self, name: str = "probe.ipa", **kwargs: Any) -> Path:
        return write_ipa(self.root / name, fixture_members(**kwargs))

    def assert_reason(self, code: str, callback: Any) -> None:
        with self.assertRaises(verify_package_module.VerificationError) as caught:
            callback()
        self.assertEqual(caught.exception.code, code)

    def test_valid_package_and_safe_report(self) -> None:
        ipa_path = self.ipa(aot_prefix=b"safe-prefix-")
        report_path = self.root / "verification.json"
        report = verify_package_module.verify_package(ipa_path, REVISION, report_path)
        self.assertEqual(report["artifactKind"], "ios-i0-unsigned-ipa-v1")
        self.assertEqual(report["sourceRevision"], REVISION)
        self.assertEqual(report["ipaSha256"], hashlib.sha256(ipa_path.read_bytes()).hexdigest())
        self.assertEqual(report["ipaBytes"], ipa_path.stat().st_size)
        self.assertTrue(all(report["checks"].values()))
        saved = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertEqual(saved, report)
        self.assertNotIn(str(ipa_path), report_path.read_text(encoding="utf-8"))

    def test_revision_must_appear_across_aot_stream_chunk_boundary(self) -> None:
        macho_prefix_size = 32 + 24
        prefix = b"x" * (verify_package_module.STREAM_CHUNK_SIZE - macho_prefix_size - 13)
        ipa_path = self.ipa(aot_prefix=prefix)
        report = verify_package_module.verify_package(ipa_path, REVISION)
        self.assertTrue(report["checks"]["aotRevisionEmbedded"])

    def test_arm64_simulator_platform_is_rejected(self) -> None:
        ipa_path = self.ipa(host_platform=7)
        self.assert_reason("macho_platform_mismatch", lambda: verify_package_module.verify_package(ipa_path, REVISION))

    def test_missing_widget_is_rejected(self) -> None:
        ipa_path = self.ipa(include_widget=False)
        self.assert_reason("widget_bundle_count_mismatch", lambda: verify_package_module.verify_package(ipa_path, REVISION))

    def test_multiple_widget_bundles_are_rejected(self) -> None:
        members = fixture_members()
        path = self.root / "multiple-widget.ipa"
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, data, _ in members:
                archive.writestr(name, data)
            archive.writestr("Payload/Runner.app/PlugIns/Extra.appex/Info.plist", b"{}");
        self.assert_reason("widget_bundle_count_mismatch", lambda: verify_package_module.verify_package(path, REVISION))

    def test_manifest_only_revision_is_not_enough(self) -> None:
        ipa_path = self.ipa(aot_revision=False)
        self.assert_reason("aot_revision_missing", lambda: verify_package_module.verify_package(ipa_path, REVISION))

    def test_zip_traversal_is_rejected(self) -> None:
        path = write_ipa(self.root / "traversal.ipa", fixture_members(), extra_entries=[("../outside", b"x")])
        self.assert_reason("unsafe_archive_path", lambda: verify_package_module.verify_package(path, REVISION))

    def test_duplicate_zip_path_is_rejected(self) -> None:
        path = self.root / "duplicate.ipa"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for name, data, _ in fixture_members():
                    archive.writestr(name, data)
                archive.writestr("Payload/Runner.app/Info.plist", app_info())
        self.assert_reason("duplicate_archive_path", lambda: verify_package_module.verify_package(path, REVISION))

    def test_symlink_zip_entry_is_rejected(self) -> None:
        symlink_mode = (stat.S_IFLNK | 0o777) << 16
        members = fixture_members() + [("Payload/Runner.app/unsafe-link", b"target", symlink_mode)]
        path = write_ipa(self.root / "symlink.ipa", members)
        self.assert_reason("unsafe_archive_link", lambda: verify_package_module.verify_package(path, REVISION))

    def test_archive_entry_count_is_bounded(self) -> None:
        path = self.root / "many-entries.ipa"
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as archive:
            for index in range(12):
                archive.writestr(f"entry-{index}", b"x")
        with patch.object(verify_package_module, "MAX_ENTRIES", 10):
            self.assert_reason("archive_entry_limit", lambda: verify_package_module.verify_package(path, REVISION))

    def test_uncompressed_file_and_total_limits_are_bounded(self) -> None:
        per_file_path = self.root / "large-member.ipa"
        with zipfile.ZipFile(per_file_path, "w", compression=zipfile.ZIP_STORED) as archive:
            archive.writestr("blob", b"x" * 32)
        with patch.object(verify_package_module, "MAX_FILE_UNCOMPRESSED", 16):
            self.assert_reason("archive_file_limit", lambda: verify_package_module.verify_package(per_file_path, REVISION))

        total_path = self.root / "large-total.ipa"
        with zipfile.ZipFile(total_path, "w", compression=zipfile.ZIP_STORED) as archive:
            archive.writestr("first", b"x" * 10)
            archive.writestr("second", b"y" * 10)
        with patch.object(verify_package_module, "MAX_FILE_UNCOMPRESSED", 16), patch.object(
            verify_package_module, "MAX_TOTAL_UNCOMPRESSED", 16
        ):
            self.assert_reason("archive_total_limit", lambda: verify_package_module.verify_package(total_path, REVISION))

    def test_compression_ratio_limit_is_bounded(self) -> None:
        path = self.root / "compressed-bomb.ipa"
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("compressed", b"z" * 4096)
        with patch.object(verify_package_module, "MAX_COMPRESSION_RATIO", 5):
            self.assert_reason("archive_compression_ratio", lambda: verify_package_module.verify_package(path, REVISION))

    def test_wrong_target_identity_is_rejected(self) -> None:
        ipa_path = self.ipa(app_bundle_id="cn.example.wrong")
        self.assert_reason("bundle_identity_mismatch", lambda: verify_package_module.verify_package(ipa_path, REVISION))

    def test_group_declaration_must_match_for_both_targets(self) -> None:
        ipa_path = self.ipa(widget_group="group.cn.example.wrong")
        self.assert_reason("app_group_declaration_mismatch", lambda: verify_package_module.verify_package(ipa_path, REVISION))

    def test_private_signing_material_is_rejected(self) -> None:
        path = write_ipa(self.root / "profile.ipa", fixture_members(), extra_entries=[("Payload/Runner.app/embedded.mobileprovision", b"synthetic")])
        self.assert_reason("prohibited_package_asset", lambda: verify_package_module.verify_package(path, REVISION))

    def test_debug_kernel_blob_is_rejected(self) -> None:
        path = write_ipa(self.root / "debug-kernel.ipa", fixture_members(), extra_entries=[("Payload/Runner.app/Frameworks/kernel_blob.bin", b"synthetic")])
        self.assert_reason("prohibited_package_asset", lambda: verify_package_module.verify_package(path, REVISION))

    def test_malformed_load_command_is_rejected(self) -> None:
        bad_command = struct.pack("<II", 1, 12)
        bad_host = macho(2, command_bytes_override=8, command_blob=bad_command)
        members = fixture_members()
        members = [(name, bad_host if name == APP_EXECUTABLE_PATH else data, attr) for name, data, attr in members]
        path = write_ipa(self.root / "bad-load-command.ipa", members)
        self.assert_reason("invalid_macho_load_command", lambda: verify_package_module.verify_package(path, REVISION))

    def test_over_limit_load_command_region_is_rejected_without_reading_it(self) -> None:
        oversized = macho(2, command_bytes_override=verify_package_module.MAX_MACHO_LOAD_COMMAND_BYTES + 1)
        members = fixture_members()
        members = [(name, oversized if name == APP_EXECUTABLE_PATH else data, attr) for name, data, attr in members]
        path = write_ipa(self.root / "oversized-load-commands.ipa", members)
        self.assert_reason("macho_load_command_limit", lambda: verify_package_module.verify_package(path, REVISION))

    def test_report_cannot_overwrite_input(self) -> None:
        ipa_path = self.ipa()
        self.assert_reason("report_path_is_input", lambda: verify_package_module.verify_package(ipa_path, REVISION, ipa_path))
        with zipfile.ZipFile(ipa_path, "r") as archive:
            self.assertTrue(archive.namelist())

    def test_report_directory_is_rejected(self) -> None:
        ipa_path = self.ipa()
        self.assert_reason("report_path_unsafe", lambda: verify_package_module.verify_package(ipa_path, REVISION, self.root))

    def test_report_symlink_is_rejected_when_supported(self) -> None:
        ipa_path = self.ipa()
        symlink_path = self.root / "report-link.json"
        target_path = self.root / "real-report.json"
        try:
            symlink_path.symlink_to(target_path)
        except (OSError, NotImplementedError):
            self.skipTest("symlink creation is unavailable in this Windows context")
        self.assert_reason("report_path_unsafe", lambda: verify_package_module.verify_package(ipa_path, REVISION, symlink_path))

    def test_cli_errors_do_not_echo_paths(self) -> None:
        bad_path = str(self.root / "secret-private-key-content.ipa")
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = verify_package_module.main(["--ipa", bad_path, "--expected-revision", REVISION])
        self.assertEqual(code, 2)
        combined = stdout.getvalue() + stderr.getvalue()
        self.assertEqual(combined, "verification failed: ipa_unreadable\n")
        self.assertNotIn("secret-private-key-content", combined)


if __name__ == "__main__":
    unittest.main()
