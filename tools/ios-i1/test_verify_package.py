"""Synthetic-only tests for the I1 IPA verifier."""

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


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("ios_i1_verify_package", HERE / "verify_package.py")
assert SPEC is not None and SPEC.loader is not None
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)

REVISION = "0123456789abcdef0123456789abcdef01234567"
OTHER_REVISION = "89abcdef0123456789abcdef0123456789abcdef"
APP_ID = verifier.APP_BUNDLE_ID
APP_ROOT = "Payload/Runner.app"
RUNNER_PATH = verifier.RUNNER_EXECUTABLE_PATH
APP_FRAMEWORK_ROOT = verifier.APP_FRAMEWORK_ROOT
FLUTTER_FRAMEWORK_ROOT = verifier.FLUTTER_FRAMEWORK_ROOT
APP_FRAMEWORK_PATH = verifier.APP_FRAMEWORK_EXECUTABLE
FLUTTER_FRAMEWORK_PATH = verifier.FLUTTER_FRAMEWORK_EXECUTABLE
MANIFEST_PATH = verifier.MANIFEST_PATH
APP_INFO_PATH = verifier.APP_INFO_PATH


def macho(
    file_type: int,
    *,
    platform: int = 2,
    payload: bytes = b"",
    signature_blob: bytes | None = None,
    signature_offset_override: int | None = None,
    signature_size_override: int | None = None,
) -> bytes:
    commands = struct.pack(
        "<IIIIII", 0x32, 24, platform, 0x001B0000, 0x001B0000, 0
    )
    tail = b""
    command_count = 1
    if signature_blob is not None:
        signature_offset = 32 + len(commands) + 16 + len(payload)
        if signature_offset_override is not None:
            signature_offset = signature_offset_override
        signature_size = len(signature_blob) if signature_size_override is None else signature_size_override
        commands += struct.pack("<IIII", 0x1D, 16, signature_offset, signature_size)
        tail = signature_blob
        command_count = 2
    header = struct.pack(
        "<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, file_type, command_count, len(commands), 0, 0
    )
    return header + commands + payload + tail


def fat_macho(slices: list[bytes]) -> bytes:
    table_end = 8 + len(slices) * 20
    output = bytearray(table_end)
    output[:8] = struct.pack(">II", 0xCAFEBABE, len(slices))
    entries: list[bytes] = []
    offsets: list[int] = []
    cursor = table_end
    for data in slices:
        cursor = (cursor + 3) & ~3
        offsets.append(cursor)
        cpu_type, cpu_subtype = struct.unpack_from("<ii", data, 4)
        entries.append(struct.pack(">iiIII", cpu_type, cpu_subtype, cursor, len(data), 2))
        cursor += len(data)
    output[8:table_end] = b"".join(entries)
    for offset, data in zip(offsets, slices):
        if len(output) < offset:
            output.extend(b"\0" * (offset - len(output)))
        output.extend(data)
    return bytes(output)


def signature_superblob(
    *,
    entitlements: dict[str, Any] | None = None,
    der_only: bool = False,
    include_der: bool = False,
    corrupt_entitlement_offset: bool = False,
    count_override: int | None = None,
) -> bytes:
    blobs: list[tuple[int, bytes]] = [
        (0, struct.pack(">II", 0xFADE0C02, 8)),
    ]
    if entitlements is not None:
        payload = plistlib.dumps(entitlements, fmt=plistlib.FMT_XML)
        blob = struct.pack(">II", 0xFADE7171, 8 + len(payload)) + payload
        blobs.append((5, blob))
        if include_der:
            der_payload = b"synthetic-der-entitlements"
            der_blob = struct.pack(">II", 0xFADE7172, 8 + len(der_payload)) + der_payload
            blobs.append((7, der_blob))
    elif der_only:
        payload = b"synthetic-der-entitlements"
        blob = struct.pack(">II", 0xFADE7172, 8 + len(payload)) + payload
        blobs.append((7, blob))

    table_end = 12 + len(blobs) * 8
    body = bytearray(table_end)
    body[0:12] = struct.pack(">III", 0xFADE0CC0, 0, len(blobs))
    offset = table_end
    for index, (slot, blob) in enumerate(blobs):
        if index == 1 and corrupt_entitlement_offset:
            index_offset = 0xFFFFFFFC
        else:
            index_offset = offset
        struct.pack_into(">II", body, 12 + index * 8, slot, index_offset)
        body.extend(blob)
        offset = len(body)
        if index + 1 < len(blobs):
            padding = (-offset) % 4
            body.extend(b"\0" * padding)
            offset += padding
    struct.pack_into(">I", body, 4, len(body))
    if count_override is not None:
        struct.pack_into(">I", body, 8, count_override)
    return bytes(body)


def manifest(*, revision: str = REVISION, extras: dict[str, Any] | None = None) -> bytes:
    value: dict[str, Any] = {
        "schemaVersion": 1,
        "kind": "ios-i1-unsigned-ipa-v1",
        "sourceRevision": revision,
        "flutterVersion": "3.47.7",
        "xcodeVersion": "27.1",
        "buildMode": "release",
        "bundleId": APP_ID,
        "scope": "i1-storage-bootstrap",
        "widget": False,
        "speech": False,
    }
    value.update(extras or {})
    return json.dumps(value, separators=(",", ":")).encode("utf-8")


def runner_info(
    *,
    revision: str = REVISION,
    bundle_id: str = APP_ID,
    supported: list[str] | None = None,
    extras: dict[str, Any] | None = None,
) -> bytes:
    value: dict[str, Any] = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleExecutable": "Runner",
        "CFBundleSupportedPlatforms": supported or ["iPhoneOS"],
        "I1SourceRevision": revision,
    }
    value.update(extras or {})
    return plistlib.dumps(value, fmt=plistlib.FMT_BINARY)


def framework_info(name: str, *, executable: str | None = None) -> bytes:
    value = {
        "CFBundleIdentifier": f"fixture.{name}",
        "CFBundleExecutable": executable or name,
        "CFBundlePackageType": "FMWK",
    }
    return plistlib.dumps(value, fmt=plistlib.FMT_BINARY)


def fixture_members(
    *,
    runner_platform: int = 2,
    app_framework_platform: int = 2,
    flutter_platform: int = 2,
    runner_revision: str = REVISION,
    aot_revision: bool = True,
    manifest_revision: str = REVISION,
    runner_supported: list[str] | None = None,
    info_extras: dict[str, Any] | None = None,
    runner_signature: bytes | None = None,
    app_framework_signature: bytes | None = None,
    flutter_signature: bytes | None = None,
    extra_members: list[tuple[str, bytes, int | None]] | None = None,
) -> list[tuple[str, bytes, int | None]]:
    aot_bytes = REVISION.encode("ascii") if aot_revision else b"fixture-without-aot-revision"
    members: list[tuple[str, bytes, int | None]] = [
        (MANIFEST_PATH, manifest(revision=manifest_revision), None),
        (
            APP_INFO_PATH,
            runner_info(
                revision=runner_revision,
                supported=runner_supported,
                extras=info_extras,
            ),
            None,
        ),
        (
            RUNNER_PATH,
            macho(2, platform=runner_platform, payload=b"runner-fixture", signature_blob=runner_signature),
            None,
        ),
        (f"{APP_FRAMEWORK_ROOT}/Info.plist", framework_info("App"), None),
        (
            APP_FRAMEWORK_PATH,
            macho(
                6,
                platform=app_framework_platform,
                payload=b"aot:" + aot_bytes,
                signature_blob=app_framework_signature,
            ),
            None,
        ),
        (f"{FLUTTER_FRAMEWORK_ROOT}/Info.plist", framework_info("Flutter"), None),
        (
            FLUTTER_FRAMEWORK_PATH,
            macho(
                6,
                platform=flutter_platform,
                payload=b"flutter-engine-fixture",
                signature_blob=flutter_signature,
            ),
            None,
        ),
    ]
    members.extend(extra_members or [])
    return members


def write_ipa(
    path: Path,
    members: list[tuple[str, bytes, int | None]],
    *,
    duplicate: tuple[str, bytes] | None = None,
) -> Path:
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
        if duplicate is not None:
            archive.writestr(duplicate[0], duplicate[1])
    return path


class VerifyI1PackageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="ios-i1-test-", dir=str(HERE))
        self.root = Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def ipa(self, name: str = "candidate.ipa", **kwargs: Any) -> Path:
        return write_ipa(self.root / name, fixture_members(**kwargs))

    def assert_reason(self, code: str, callback: Any) -> None:
        with self.assertRaises(verifier.VerificationError) as caught:
            callback()
        self.assertEqual(caught.exception.code, code)

    def test_valid_device_package_and_report(self) -> None:
        ipa_path = self.ipa()
        report_path = self.root / "verification.json"
        report = verifier.verify_package(ipa_path, REVISION, report_path)
        self.assertEqual(report["artifactKind"], "ios-i1-unsigned-ipa-v1")
        self.assertEqual(report["sourceRevision"], REVISION)
        self.assertEqual(report["bundleId"], APP_ID)
        self.assertEqual(report["ipaSha256"], hashlib.sha256(ipa_path.read_bytes()).hexdigest())
        self.assertEqual(report["ipaBytes"], ipa_path.stat().st_size)
        self.assertTrue(all(report["checks"].values()))
        self.assertEqual(json.loads(report_path.read_text(encoding="utf-8")), report)
        self.assertNotIn(str(ipa_path), report_path.read_text(encoding="utf-8"))

        cli_report = self.root / "cli-report.json"
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = verifier.main([
                "--ipa", str(ipa_path),
                "--expected-revision", REVISION,
                "--report", str(cli_report),
            ])
        self.assertEqual(result, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertEqual(json.loads(stdout.getvalue()), report)
        self.assertEqual(json.loads(cli_report.read_text(encoding="utf-8")), report)

    def test_simulator_platform_is_rejected(self) -> None:
        ipa = self.ipa(runner_platform=7)
        self.assert_reason(
            "macho_platform_mismatch",
            lambda: verifier.verify_package(ipa, REVISION),
        )

        ipa = self.ipa("simulator-info.ipa", runner_supported=["iPhoneSimulator"])
        self.assert_reason(
            "platform_identity_mismatch",
            lambda: verifier.verify_package(ipa, REVISION),
        )

    def test_every_framework_macho_is_checked(self) -> None:
        plugin_root = f"{APP_ROOT}/Frameworks/Plugin.framework"
        members = fixture_members(extra_members=[
            (f"{plugin_root}/Info.plist", framework_info("Plugin"), None),
            (f"{plugin_root}/Plugin", macho(6, platform=7), None),
        ])
        ipa = write_ipa(self.root / "plugin-simulator.ipa", members)
        self.assert_reason(
            "macho_platform_mismatch",
            lambda: verifier.verify_package(ipa, REVISION),
        )

    def test_signature_entitlements_are_bounded_and_checked(self) -> None:
        empty_signature = signature_superblob()
        ipa = self.ipa(runner_signature=empty_signature)
        report = verifier.verify_package(ipa, REVISION)
        self.assertEqual(report["appleSignatureValidity"], "not-verified")

        safe_xml_entitlements = signature_superblob(
            entitlements={"application-identifier": "fixture.cn.ustcassistant.ios.private"},
        )
        ipa = self.ipa("safe-xml-signature.ipa", runner_signature=safe_xml_entitlements)
        verifier.verify_package(ipa, REVISION)

        xml_and_der_entitlements = signature_superblob(
            entitlements={"application-identifier": "fixture.cn.ustcassistant.ios.private"},
            include_der=True,
        )
        ipa = self.ipa("xml-and-der-signature.ipa", runner_signature=xml_and_der_entitlements)
        self.assert_reason(
            "unsupported_signed_entitlements",
            lambda: verifier.verify_package(ipa, REVISION),
        )

        group_signature = signature_superblob(
            entitlements={"com.apple.security.application-groups": ["group.fixture"]}
        )
        ipa = self.ipa("runner-group-signature.ipa", runner_signature=group_signature)
        self.assert_reason(
            "app_group_signature_entitlement",
            lambda: verifier.verify_package(ipa, REVISION),
        )

        alternate_slice = bytearray(macho(2, signature_blob=group_signature))
        struct.pack_into("<i", alternate_slice, 8, 1)
        fat_group = fat_macho([
            macho(2, payload=b"runner-without-signature"),
            bytes(alternate_slice),
        ])
        members = [
            (name, fat_group if name == RUNNER_PATH else data, attr)
            for name, data, attr in fixture_members()
        ]
        ipa = write_ipa(self.root / "fat-runner-group-signature.ipa", members)
        self.assert_reason(
            "app_group_signature_entitlement",
            lambda: verifier.verify_package(ipa, REVISION),
        )

        plugin_root = f"{APP_ROOT}/Frameworks/Plugin.framework"
        plugin_signature = signature_superblob(
            entitlements={"com.apple.security.application-groups": ["group.fixture"]}
        )
        members = fixture_members(extra_members=[
            (f"{plugin_root}/Info.plist", framework_info("Plugin"), None),
            (f"{plugin_root}/Plugin", macho(6, payload=b"plugin", signature_blob=plugin_signature), None),
        ])
        ipa = write_ipa(self.root / "plugin-group-signature.ipa", members)
        self.assert_reason(
            "app_group_signature_entitlement",
            lambda: verifier.verify_package(ipa, REVISION),
        )

        ipa = self.ipa("der-only.ipa", runner_signature=signature_superblob(der_only=True))
        self.assert_reason(
            "unsupported_signed_entitlements",
            lambda: verifier.verify_package(ipa, REVISION),
        )

        ipa = self.ipa(
            "bad-signature-offset.ipa",
            runner_signature=signature_superblob(
                entitlements={"application-identifier": "fixture"},
                corrupt_entitlement_offset=True,
            ),
        )
        self.assert_reason(
            "invalid_code_signature",
            lambda: verifier.verify_package(ipa, REVISION),
        )

        ipa = self.ipa(
            "bad-signature-count.ipa",
            runner_signature=signature_superblob(count_override=0xFFFFFFFF),
        )
        self.assert_reason(
            "invalid_code_signature",
            lambda: verifier.verify_package(ipa, REVISION),
        )

        bad_superblob_length = bytearray(empty_signature)
        struct.pack_into(">I", bad_superblob_length, 4, len(bad_superblob_length) + 1)
        ipa = self.ipa(
            "bad-superblob-size.ipa",
            runner_signature=bytes(bad_superblob_length),
        )
        self.assert_reason(
            "invalid_code_signature",
            lambda: verifier.verify_package(ipa, REVISION),
        )

        bad_blob_length = bytearray(empty_signature)
        code_directory_offset = struct.unpack_from(">I", bad_blob_length, 16)[0]
        struct.pack_into(">I", bad_blob_length, code_directory_offset + 4, 0xFFFFFFFF)
        ipa = self.ipa("bad-blob-size.ipa", runner_signature=bytes(bad_blob_length))
        self.assert_reason(
            "invalid_code_signature",
            lambda: verifier.verify_package(ipa, REVISION),
        )

        # The helper above creates a valid offset. Use a member-level rebuild
        # with an impossible dataoff to cover LC_CODE_SIGNATURE bounds.
        members = fixture_members()
        members = [
            (name, macho(2, signature_blob=empty_signature, signature_offset_override=0xFFFFFF00), attr)
            if name == RUNNER_PATH else (name, data, attr)
            for name, data, attr in members
        ]
        ipa = write_ipa(self.root / "bad-load-command-offset.ipa", members)
        self.assert_reason(
            "invalid_code_signature",
            lambda: verifier.verify_package(ipa, REVISION),
        )

        members = [
            (
                name,
                macho(
                    2,
                    signature_blob=empty_signature,
                    signature_size_override=len(empty_signature) + 0x1000,
                )
                if name == RUNNER_PATH else data,
                attr,
            )
            for name, data, attr in fixture_members()
        ]
        ipa = write_ipa(self.root / "bad-load-command-size.ipa", members)
        self.assert_reason(
            "invalid_code_signature",
            lambda: verifier.verify_package(ipa, REVISION),
        )

    def test_source_revision_and_aot_revision_must_match(self) -> None:
        ipa = self.ipa(runner_revision=OTHER_REVISION)
        self.assert_reason(
            "source_revision_mismatch",
            lambda: verifier.verify_package(ipa, REVISION),
        )

        ipa = self.ipa("aot-mismatch.ipa", aot_revision=False)
        self.assert_reason(
            "aot_revision_missing",
            lambda: verifier.verify_package(ipa, REVISION),
        )

        ipa = self.ipa("manifest-mismatch.ipa", manifest_revision=OTHER_REVISION)
        self.assert_reason(
            "invalid_manifest",
            lambda: verifier.verify_package(ipa, REVISION),
        )

    def test_zip_traversal_duplicate_and_link_are_rejected(self) -> None:
        ipa = write_ipa(
            self.root / "traversal.ipa",
            fixture_members(extra_members=[("Payload/Runner.app/../Escape", b"x", None)]),
        )
        self.assert_reason(
            "unsafe_archive_path",
            lambda: verifier.verify_package(ipa, REVISION),
        )

        duplicate_path = RUNNER_PATH
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            ipa = write_ipa(
                self.root / "duplicate.ipa",
                fixture_members(),
                duplicate=(duplicate_path, b"duplicate"),
            )
        self.assert_reason(
            "duplicate_archive_path",
            lambda: verifier.verify_package(ipa, REVISION),
        )

        symlink_attr = (stat.S_IFLNK | 0o777) << 16
        ipa = write_ipa(
            self.root / "symlink.ipa",
            fixture_members(extra_members=[("Payload/Runner.app/unsafe-link", b"Runner", symlink_attr)]),
        )
        self.assert_reason(
            "unsafe_archive_link",
            lambda: verifier.verify_package(ipa, REVISION),
        )

    def test_audio_permissions_app_groups_extensions_profiles_and_models_are_rejected(self) -> None:
        cases: list[tuple[str, list[tuple[str, bytes, int | None]], str]] = []
        cases.append((
            "microphone.ipa",
            fixture_members(info_extras={"NSMicrophoneUsageDescription": "fixture"}),
            "audio_permission_present",
        ))
        cases.append((
            "speech.ipa",
            fixture_members(info_extras={"NSSpeechRecognitionUsageDescription": "fixture"}),
            "audio_permission_present",
        ))
        cases.append((
            "app-group-info.ipa",
            fixture_members(info_extras={"ALTAppGroups": ["group.cn.ustcassistant.ios.i0"]}),
            "app_group_declaration_present",
        ))
        group_entitlements = plistlib.dumps(
            {"com.apple.security.application-groups": ["group.fixture"]},
            fmt=plistlib.FMT_XML,
        )
        cases.append((
            "app-group-entitlement.ipa",
            fixture_members(extra_members=[(f"{APP_ROOT}/Runner.entitlements", group_entitlements, None)]),
            "app_group_entitlement_present",
        ))
        cases.append((
            "appex.ipa",
            fixture_members(extra_members=[(f"{APP_ROOT}/Extra.appex/Info.plist", b"fixture", None)]),
            "extension_present",
        ))
        cases.append((
            "plugins-folder.ipa",
            fixture_members(extra_members=[(f"{APP_ROOT}/PlugIns/Marker", b"fixture", None)]),
            "plugin_directory_present",
        ))
        cases.append((
            "profile.ipa",
            fixture_members(extra_members=[(f"{APP_ROOT}/embedded.mobileprovision", b"synthetic", None)]),
            "prohibited_package_asset",
        ))
        cases.append((
            "private-key.ipa",
            fixture_members(extra_members=[(f"{APP_ROOT}/fixture.p8", b"synthetic", None)]),
            "prohibited_package_asset",
        ))
        cases.append((
            "debug-kernel.ipa",
            fixture_members(extra_members=[(f"{APP_ROOT}/flutter_assets/kernel_blob.bin", b"synthetic", None)]),
            "prohibited_package_asset",
        ))
        cases.append((
            "debug-dill.ipa",
            fixture_members(extra_members=[(f"{APP_ROOT}/app.dill", b"synthetic", None)]),
            "prohibited_package_asset",
        ))
        cases.append((
            "legacy-i0.ipa",
            fixture_members(extra_members=[(f"{APP_ROOT}/ios-i0-provenance.json", b"synthetic", None)]),
            "legacy_i0_asset_present",
        ))
        cases.append((
            "onnx.ipa",
            fixture_members(extra_members=[(f"{APP_ROOT}/models/fixture.onnx", b"synthetic", None)]),
            "model_asset_present",
        ))
        cases.append((
            "tokens.ipa",
            fixture_members(extra_members=[(f"{APP_ROOT}/models/tokens.txt", b"synthetic", None)]),
            "model_asset_present",
        ))
        for filename, members, expected in cases:
            with self.subTest(filename=filename):
                ipa = write_ipa(self.root / filename, members)
                self.assert_reason(expected, lambda: verifier.verify_package(ipa, REVISION))

    def test_report_path_must_not_alias_input_or_escape_temp_root(self) -> None:
        ipa = self.ipa()
        self.assert_reason(
            "report_path_is_input",
            lambda: verifier.verify_package(ipa, REVISION, ipa),
        )
        self.assert_reason(
            "report_path_unsafe",
            lambda: verifier.verify_package(ipa, REVISION, self.root / "missing" / "report.json"),
        )
        raw_parent = str(self.root / ".." / "outside.json")
        self.assert_reason(
            "report_path_unsafe",
            lambda: verifier.verify_package(ipa, REVISION, raw_parent),
        )

        link = self.root / "report-link.json"
        try:
            os.symlink(ipa, link)
        except (OSError, NotImplementedError):
            self.skipTest("symlink creation unavailable for this Windows account")
        self.assert_reason(
            "report_path_unsafe",
            lambda: verifier.verify_package(ipa, REVISION, link),
        )

    def test_failure_output_contains_only_fixed_reason_code(self) -> None:
        ipa = write_ipa(
            self.root / "secret-name.ipa",
            fixture_members(extra_members=[(f"{APP_ROOT}/fixture.pem", b"DO-NOT-PRINT-ME", None)]),
        )
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = verifier.main([
                "--ipa", str(ipa),
                "--expected-revision", REVISION,
                "--report", str(self.root / "unused-report.json"),
            ])
        self.assertEqual(result, 2)
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(stderr.getvalue(), "verification failed: prohibited_package_asset\n")
        self.assertNotIn("DO-NOT-PRINT-ME", stderr.getvalue())
        self.assertFalse((self.root / "unused-report.json").exists())


if __name__ == "__main__":
    unittest.main()
