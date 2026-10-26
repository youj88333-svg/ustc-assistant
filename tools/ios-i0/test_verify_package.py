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
    cpu_type: int = 0x0100000C,
    cpu_subtype: int = 0,
    platform: int = 2,
    payload: bytes = b"",
    command_bytes_override: int | None = None,
    command_count_override: int = 1,
    command_blob: bytes | None = None,
) -> bytes:
    if command_blob is None:
        command_blob = struct.pack("<IIIIII", 0x32, 24, platform, 0x001B0000, 0x001B0000, 0)
    command_bytes = len(command_blob) if command_bytes_override is None else command_bytes_override
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, cpu_type, cpu_subtype, file_type, command_count_override, command_bytes, 0, 0)
    return header + command_blob + payload


def fat_macho(
    slices: list[bytes],
    *,
    is_64: bool = False,
    byte_order: str = ">",
    alignment: int = 4,
    padding: bytes = b"",
    offsets: list[int] | None = None,
    alignments: list[int] | None = None,
    descriptor_overrides: dict[int, tuple[int, int]] | None = None,
    reserved_values: dict[int, int] | None = None,
) -> bytes:
    if byte_order not in (">", "<"):
        raise ValueError("invalid byte order")
    if is_64:
        entry_size = 32
        magic = (b"\xca\xfe\xba\xbf" if byte_order == ">" else b"\xbf\xba\xfe\xca")
    else:
        entry_size = 20
        magic = (b"\xca\xfe\xba\xbe" if byte_order == ">" else b"\xbe\xba\xfe\xca")
    table_end = 8 + entry_size * len(slices)
    chosen_alignments = alignments or [alignment] * len(slices)
    if len(chosen_alignments) != len(slices):
        raise ValueError("alignment count mismatch")
    if offsets is None:
        offsets = []
        cursor = table_end + len(padding)
        for data, exponent in zip(slices, chosen_alignments):
            align_to = 1 << min(exponent, 31)
            cursor = (cursor + align_to - 1) & ~(align_to - 1)
            offsets.append(cursor)
            cursor += len(data)
    if len(offsets) != len(slices):
        raise ValueError("offset count mismatch")

    descriptor_overrides = descriptor_overrides or {}
    reserved_values = reserved_values or {}
    descriptors: list[bytes] = []
    for index, (data, offset, exponent) in enumerate(zip(slices, offsets, chosen_alignments)):
        if len(data) < 12:
            raise ValueError("slice is too short")
        cpu_type, cpu_subtype = struct.unpack_from("<ii", data, 4)
        cpu_type, cpu_subtype = descriptor_overrides.get(index, (cpu_type, cpu_subtype))
        if is_64:
            descriptors.append(
                struct.pack(byte_order + "iiQQII", cpu_type, cpu_subtype, offset, len(data), exponent, reserved_values.get(index, 0))
            )
        else:
            descriptors.append(struct.pack(byte_order + "iiIII", cpu_type, cpu_subtype, offset, len(data), exponent))

    output = bytearray(max(table_end + len(padding), 8 + entry_size * len(slices)))
    output[:4] = magic
    output[4:8] = struct.pack(byte_order + "I", len(slices))
    table = b"".join(descriptors)
    output[8:table_end] = table
    output[table_end : table_end + len(padding)] = padding
    for data, offset in zip(slices, offsets):
        if offset < table_end or offset > 1024 * 1024 or offset + len(data) > 1024 * 1024:
            continue
        if len(output) < offset + len(data):
            output.extend(b"\0" * (offset + len(data) - len(output)))
        output[offset : offset + len(data)] = data
    return bytes(output)


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


MACHO_PATHS = {
    APP_EXECUTABLE_PATH,
    WIDGET_EXECUTABLE_PATH,
    AOT_PATH,
    FLUTTER_PATH,
}


def universalize_members(
    members: list[tuple[str, bytes, int | None]],
    *,
    is_64: bool,
    byte_order: str,
    variants: bool = True,
) -> list[tuple[str, bytes, int | None]]:
    result: list[tuple[str, bytes, int | None]] = []
    for name, data, external_attr in members:
        if name not in MACHO_PATHS:
            result.append((name, data, external_attr))
            continue
        slices = [data]
        if variants:
            arm64e = bytearray(data)
            struct.pack_into("<i", arm64e, 8, 2)
            slices.append(bytes(arm64e))
        result.append((name, fat_macho(slices, is_64=is_64, byte_order=byte_order), external_attr))
    return result


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
        prefix = b"x" * (verify_package_module.STREAM_CHUNK_SIZE - 13)
        ipa_path = self.ipa(aot_prefix=prefix)
        report = verify_package_module.verify_package(ipa_path, REVISION)
        self.assertTrue(report["checks"]["aotRevisionEmbedded"])

    def test_arm64_simulator_platform_is_rejected(self) -> None:
        ipa_path = self.ipa(host_platform=7)
        self.assert_reason("macho_platform_mismatch", lambda: verify_package_module.verify_package(ipa_path, REVISION))

    def test_fat32_and_fat64_accept_big_and_swapped_endian_arm64_variants(self) -> None:
        cases = [(False, ">"), (False, "<"), (True, ">"), (True, "<")]
        for index, (is_64, byte_order) in enumerate(cases):
            with self.subTest(is_64=is_64, byte_order=byte_order):
                members = universalize_members(fixture_members(), is_64=is_64, byte_order=byte_order)
                ipa_path = write_ipa(self.root / f"fat-{index}.ipa", members)
                report = verify_package_module.verify_package(ipa_path, REVISION)
                self.assertTrue(all(report["checks"].values()))

    def test_fat_device_subtypes_include_v8_and_distinct_arm64e_abi_flags(self) -> None:
        slices = [macho(2, cpu_subtype=subtype, payload=b"device") for subtype in (0, 1, 2, -2147483646)]
        fat_host = fat_macho(slices, is_64=True)
        members = [(name, fat_host if name == APP_EXECUTABLE_PATH else data, attr) for name, data, attr in fixture_members()]
        path = write_ipa(self.root / "fat-arm64-subtypes.ipa", members)
        report = verify_package_module.verify_package(path, REVISION)
        self.assertTrue(report["checks"]["iPhoneOSArm64MachO"])

    def test_fat_binary_rejects_simulator_slice(self) -> None:
        device = macho(2, cpu_subtype=0, platform=2, payload=b"device")
        simulator = macho(2, cpu_subtype=2, platform=7, payload=b"simulator")
        fat_host = fat_macho([device, simulator], is_64=True)
        members = fixture_members()
        members = [(name, fat_host if name == APP_EXECUTABLE_PATH else data, attr) for name, data, attr in members]
        path = write_ipa(self.root / "fat-simulator.ipa", members)
        self.assert_reason("macho_platform_mismatch", lambda: verify_package_module.verify_package(path, REVISION))

    def test_fat_binary_rejects_non_arm64_slice(self) -> None:
        device = macho(2, cpu_subtype=0, payload=b"device")
        x86 = macho(2, cpu_type=0x01000007, cpu_subtype=3, payload=b"x86")
        fat_host = fat_macho([device, x86])
        members = fixture_members()
        members = [(name, fat_host if name == APP_EXECUTABLE_PATH else data, attr) for name, data, attr in members]
        path = write_ipa(self.root / "fat-x86.ipa", members)
        self.assert_reason("macho_not_arm64", lambda: verify_package_module.verify_package(path, REVISION))

    def test_fat_slice_architecture_descriptor_must_match_slice(self) -> None:
        arm64 = macho(2, cpu_subtype=0, payload=b"arm64")
        arm64e = macho(2, cpu_subtype=2, payload=b"arm64e")
        fat_host = fat_macho(
            [arm64, arm64e],
            descriptor_overrides={0: (0x0100000C, 2), 1: (0x0100000C, 0)},
        )
        members = fixture_members()
        members = [(name, fat_host if name == APP_EXECUTABLE_PATH else data, attr) for name, data, attr in members]
        path = write_ipa(self.root / "fat-descriptor-mismatch.ipa", members)
        self.assert_reason("fat_descriptor_mismatch", lambda: verify_package_module.verify_package(path, REVISION))

    def test_fat_arch_table_rejects_duplicate_architecture(self) -> None:
        device = macho(2, cpu_subtype=0, payload=b"device")
        fat_host = fat_macho([device, device])
        members = fixture_members()
        members = [(name, fat_host if name == APP_EXECUTABLE_PATH else data, attr) for name, data, attr in members]
        path = write_ipa(self.root / "fat-duplicate-arch.ipa", members)
        self.assert_reason("macho_fat_duplicate_arch", lambda: verify_package_module.verify_package(path, REVISION))

    def test_fat_arch_table_rejects_overlap_and_table_overlap(self) -> None:
        first = macho(2, cpu_subtype=0, payload=b"first")
        second = macho(2, cpu_subtype=2, payload=b"second")
        overlap = fat_macho([first, second], alignments=[0, 0], offsets=[48, 60])
        members = fixture_members()
        members = [(name, overlap if name == APP_EXECUTABLE_PATH else data, attr) for name, data, attr in members]
        overlap_path = write_ipa(self.root / "fat-overlap.ipa", members)
        self.assert_reason("macho_fat_overlap", lambda: verify_package_module.verify_package(overlap_path, REVISION))

        table_overlap = fat_macho([first], alignments=[0], offsets=[8])
        members = fixture_members()
        members = [(name, table_overlap if name == APP_EXECUTABLE_PATH else data, attr) for name, data, attr in members]
        table_path = write_ipa(self.root / "fat-table-overlap.ipa", members)
        self.assert_reason("macho_fat_table_overlap", lambda: verify_package_module.verify_package(table_path, REVISION))

    def test_fat_arch_table_rejects_out_of_bounds_alignment_and_huge_count(self) -> None:
        device = macho(2, payload=b"device")
        out_of_bounds = fat_macho([device], alignments=[0], offsets=[2000000])
        members = fixture_members()
        members = [(name, out_of_bounds if name == APP_EXECUTABLE_PATH else data, attr) for name, data, attr in members]
        bounds_path = write_ipa(self.root / "fat-out-of-bounds.ipa", members)
        self.assert_reason("macho_fat_out_of_bounds", lambda: verify_package_module.verify_package(bounds_path, REVISION))

        huge_alignment = fat_macho([device], alignments=[32])
        members = fixture_members()
        members = [(name, huge_alignment if name == APP_EXECUTABLE_PATH else data, attr) for name, data, attr in members]
        alignment_path = write_ipa(self.root / "fat-huge-alignment.ipa", members)
        self.assert_reason("macho_fat_alignment", lambda: verify_package_module.verify_package(alignment_path, REVISION))

        huge_count = b"\xca\xfe\xba\xbe" + struct.pack(">I", verify_package_module.MAX_FAT_ARCHES + 1)
        members = fixture_members()
        members = [(name, huge_count if name == APP_EXECUTABLE_PATH else data, attr) for name, data, attr in members]
        count_path = write_ipa(self.root / "fat-huge-count.ipa", members)
        self.assert_reason("macho_fat_arch_count", lambda: verify_package_module.verify_package(count_path, REVISION))

    def test_fat_arch_table_rejects_truncation_and_nonzero_64_bit_reserved(self) -> None:
        truncated = b"\xca\xfe\xba\xbf" + struct.pack(">I", 1)
        members = fixture_members()
        members = [(name, truncated if name == APP_EXECUTABLE_PATH else data, attr) for name, data, attr in members]
        truncated_path = write_ipa(self.root / "fat-truncated.ipa", members)
        self.assert_reason("macho_fat_table_truncated", lambda: verify_package_module.verify_package(truncated_path, REVISION))

        device = macho(2, payload=b"device")
        bad_reserved = fat_macho([device], is_64=True, reserved_values={0: 1})
        members = fixture_members()
        members = [(name, bad_reserved if name == APP_EXECUTABLE_PATH else data, attr) for name, data, attr in members]
        reserved_path = write_ipa(self.root / "fat-reserved.ipa", members)
        self.assert_reason("macho_fat_reserved_field", lambda: verify_package_module.verify_package(reserved_path, REVISION))

    def test_aot_revision_must_be_in_each_fat_slice_not_outer_padding(self) -> None:
        with_revision = macho(6, cpu_subtype=0, payload=REVISION.encode("ascii"))
        missing_revision = macho(6, cpu_subtype=2, payload=b"no-revision-in-this-slice")
        fat_missing_slice = fat_macho([with_revision, missing_revision], is_64=True)
        members = fixture_members()
        members = [(name, fat_missing_slice if name == AOT_PATH else data, attr) for name, data, attr in members]
        missing_path = write_ipa(self.root / "fat-aot-one-slice-missing.ipa", members)
        self.assert_reason("aot_revision_missing", lambda: verify_package_module.verify_package(missing_path, REVISION))

        no_revision = macho(6, payload=b"no-revision-in-slice")
        padding_only = fat_macho([no_revision], padding=REVISION.encode("ascii"))
        members = fixture_members()
        members = [(name, padding_only if name == AOT_PATH else data, attr) for name, data, attr in members]
        padding_path = write_ipa(self.root / "fat-aot-padding-only.ipa", members)
        self.assert_reason("aot_revision_missing", lambda: verify_package_module.verify_package(padding_path, REVISION))

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
