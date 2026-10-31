#!/usr/bin/env python3
"""Bounded structural verifier for the I1 unsigned, single-runner iOS IPA."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import plistlib
import stat
import struct
import sys
import zipfile
from pathlib import Path
from typing import Any, BinaryIO


APP_BUNDLE_ID = "cn.ustcassistant.ios.private"
MANIFEST_PATH = "Payload/Runner.app/ios-i1-provenance.json"
APP_INFO_PATH = "Payload/Runner.app/Info.plist"
RUNNER_EXECUTABLE_PATH = "Payload/Runner.app/Runner"
APP_FRAMEWORK_EXECUTABLE = "Payload/Runner.app/Frameworks/App.framework/App"
FLUTTER_FRAMEWORK_EXECUTABLE = "Payload/Runner.app/Frameworks/Flutter.framework/Flutter"
APP_FRAMEWORK_ROOT = "Payload/Runner.app/Frameworks/App.framework"
FLUTTER_FRAMEWORK_ROOT = "Payload/Runner.app/Frameworks/Flutter.framework"

MACHO_THIN_MAGICS = {
    b"\xfe\xed\xfa\xce",  # 32-bit big endian
    b"\xce\xfa\xed\xfe",  # 32-bit little endian
    b"\xfe\xed\xfa\xcf",  # 64-bit big endian
    b"\xcf\xfa\xed\xfe",  # 64-bit little endian
}
MODEL_SUFFIXES = (
    ".onnx",
    ".onnx.data",
    ".ort",
    ".tflite",
    ".pt",
    ".pth",
    ".gguf",
    ".safetensors",
)
PROHIBITED_GROUP_KEYS = {
    "altappgroups",
    "i0appgroupbaseidentifier",
    "com.apple.security.application-groups",
}
PROHIBITED_I0_MANIFESTS = {
    "ios-i0-provenance.json",
    "ios-i0-signing-input.json",
}
MAX_INFO_PLIST = 4 * 1024 * 1024
MAX_CODE_SIGNATURE_BYTES = 16 * 1024 * 1024
MAX_ENTITLEMENTS_BYTES = 1024 * 1024
MAX_CODE_SIGNATURE_BLOBS = 256
MAX_PLIST_NODES = 100_000

LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODE_DIRECTORY = 0xFADE0C02
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xFADE7171
CSMAGIC_EMBEDDED_DER_ENTITLEMENTS = 0xFADE7172
CSSLOT_CODE_DIRECTORY = 0
CSSLOT_ENTITLEMENTS = 5
CSSLOT_DER_ENTITLEMENTS = 7


def _load_i0_helpers() -> Any:
    helper_path = Path(__file__).resolve().parents[1] / "ios-i0" / "verify_package.py"
    spec = importlib.util.spec_from_file_location("ios_i0_package_helpers", helper_path)
    if spec is None or spec.loader is None:
        raise RuntimeError("i0_helper_unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_I0 = _load_i0_helpers()
VerificationError = _I0.VerificationError


def _fail(code: str) -> None:
    _I0._fail(code)


def _expected_revision_is_valid(expected_revision: str) -> bool:
    return (
        isinstance(expected_revision, str)
        and len(expected_revision) == 40
        and all(ch in "0123456789abcdef" for ch in expected_revision)
    )


def _validate_manifest(value: dict[str, Any], expected_revision: str) -> None:
    required = {
        "schemaVersion": 1,
        "kind": "ios-i1-unsigned-ipa-v1",
        "sourceRevision": expected_revision,
        "flutterVersion": "3.47.7",
        "xcodeVersion": "27.1",
        "buildMode": "release",
        "bundleId": APP_BUNDLE_ID,
        "scope": "i1-storage-bootstrap",
        "widget": False,
        "speech": False,
    }
    if set(value) != set(required):
        _fail("invalid_manifest")
    for key, expected in required.items():
        actual = value.get(key)
        if type(expected) is bool:
            if type(actual) is not bool or actual is not expected:
                _fail("invalid_manifest")
        elif type(expected) is int:
            if type(actual) is not int or actual != expected:
                _fail("invalid_manifest")
        elif not isinstance(actual, str) or actual != expected:
            _fail("invalid_manifest")


def _validate_runner_info(value: dict[str, Any], expected_revision: str) -> str:
    if value.get("CFBundleIdentifier") != APP_BUNDLE_ID:
        _fail("bundle_identity_mismatch")
    supported = value.get("CFBundleSupportedPlatforms")
    if not isinstance(supported, list) or supported != ["iPhoneOS"]:
        _fail("platform_identity_mismatch")
    if value.get("I1SourceRevision") != expected_revision:
        _fail("source_revision_mismatch")
    executable = value.get("CFBundleExecutable")
    if (
        not isinstance(executable, str)
        or not executable
        or executable in (".", "..")
        or any(ch in executable for ch in ("/", "\\", ":", "\x00"))
    ):
        _fail("invalid_bundle_executable")
    return executable


def _validate_framework_executable(value: dict[str, Any]) -> str:
    executable = value.get("CFBundleExecutable")
    if (
        not isinstance(executable, str)
        or not executable
        or executable in (".", "..")
        or any(ch in executable for ch in ("/", "\\", ":", "\x00"))
    ):
        _fail("invalid_framework_executable")
    return executable


def _walk_plist_values(root: Any):
    pending = [root]
    count = 0
    while pending:
        value = pending.pop()
        count += 1
        if count > MAX_PLIST_NODES:
            _fail("plist_complexity_limit")
        yield value
        if isinstance(value, dict):
            pending.extend(value.values())
        elif isinstance(value, (list, tuple)):
            pending.extend(value)


def _contains_prohibited_declaration(value: Any) -> bool:
    for item in _walk_plist_values(value):
        if isinstance(item, dict):
            for key in item:
                if isinstance(key, str):
                    folded = key.casefold()
                    if folded in PROHIBITED_GROUP_KEYS or "appgroup" in folded:
                        return True
        elif isinstance(item, str):
            folded = item.casefold()
            if folded.startswith("group.") or folded.startswith("group/"):
                return True
    return False


def _contains_audio_permission(value: Any) -> bool:
    for item in _walk_plist_values(value):
        if isinstance(item, dict):
            if any(
                isinstance(key, str)
                and key.casefold() in {
                    "nsmicrophoneusagedescription",
                    "nsspeechrecognitionusagedescription",
                }
                for key in item
            ):
                return True
    return False


def _is_model_asset(path: str) -> bool:
    base = path.rsplit("/", 1)[-1].casefold()
    return base == "tokens.txt" or any(base.endswith(suffix) for suffix in MODEL_SUFFIXES)


def _validate_policy_paths(members: dict[str, zipfile.ZipInfo]) -> None:
    app_roots: set[str] = set()
    for path in members:
        parts = path.split("/")
        for index, part in enumerate(parts):
            folded = part.casefold()
            if folded.endswith(".appex"):
                _fail("extension_present")
            if folded == "plugins":
                _fail("plugin_directory_present")
            if folded.endswith(".app"):
                app_roots.add("/".join(parts[: index + 1]))
        if _is_model_asset(path):
            _fail("model_asset_present")
        if parts[-1].casefold() in PROHIBITED_I0_MANIFESTS:
            _fail("legacy_i0_asset_present")
        if _I0._is_private_material_or_debug_asset(path) or path.casefold().endswith(".mobileprovision"):
            _fail("prohibited_package_asset")
    if app_roots != {"Payload/Runner.app"}:
        _fail("app_bundle_count_mismatch")


def _parse_plist_member(zf: zipfile.ZipFile, members: dict[str, zipfile.ZipInfo], path: str) -> dict[str, Any]:
    info = _I0._required_member(members, path)
    data = _I0._read_member(zf, info, MAX_INFO_PLIST)
    value = _I0._parse_plist(data)
    return value


def _validate_info_and_entitlements(
    zf: zipfile.ZipFile,
    members: dict[str, zipfile.ZipInfo],
) -> dict[str, Any]:
    runner_info: dict[str, Any] | None = None
    for path, info in members.items():
        if info.is_dir():
            continue
        folded = path.casefold()
        if folded.endswith("/info.plist") or folded == "info.plist":
            value = _parse_plist_member(zf, members, path)
            if _contains_audio_permission(value):
                _fail("audio_permission_present")
            if _contains_prohibited_declaration(value):
                _fail("app_group_declaration_present")
            if path == APP_INFO_PATH:
                runner_info = value
        elif folded.endswith(".entitlements"):
            value = _parse_plist_member(zf, members, path)
            if _contains_prohibited_declaration(value):
                _fail("app_group_entitlement_present")
    if runner_info is None:
        _fail("missing_required_member")
    return runner_info


def _is_macho_magic(magic: bytes) -> bool:
    return magic in MACHO_THIN_MAGICS or magic in _I0.FAT_MACHO_MAGICS


def _parse_signature_superblob(data: bytes) -> None:
    if len(data) < 12 or len(data) > MAX_CODE_SIGNATURE_BYTES:
        _fail("invalid_code_signature")
    magic, declared_length, count = struct.unpack_from(">III", data, 0)
    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        _fail("invalid_code_signature")
    if declared_length < 12 or declared_length > len(data) or count < 1 or count > MAX_CODE_SIGNATURE_BLOBS:
        _fail("invalid_code_signature")
    # LC_CODE_SIGNATURE may reserve bytes beyond the SuperBlob's own length.
    # Apple indexes packed sub-blobs by byte offset; no four-byte alignment is
    # required (Security/libsecurity_utilities/lib/superblob.h).

    table_end = 12 + count * 8
    if table_end > declared_length:
        _fail("invalid_code_signature")

    slots: dict[int, tuple[int, bytes]] = {}
    ranges: list[tuple[int, int]] = [(0, table_end)]
    for index in range(count):
        slot, offset = struct.unpack_from(">II", data, 12 + index * 8)
        if slot in slots or offset < table_end or offset > declared_length - 8:
            _fail("invalid_code_signature")
        blob_magic, blob_length = struct.unpack_from(">II", data, offset)
        if blob_length < 8 or blob_length > declared_length - offset:
            _fail("invalid_code_signature")
        if (
            (slot == CSSLOT_ENTITLEMENTS) != (blob_magic == CSMAGIC_EMBEDDED_ENTITLEMENTS)
            or (slot == CSSLOT_DER_ENTITLEMENTS) != (blob_magic == CSMAGIC_EMBEDDED_DER_ENTITLEMENTS)
        ):
            _fail("invalid_signed_entitlements")
        end = offset + blob_length
        ranges.append((offset, end))
        slots[slot] = (blob_magic, data[offset + 8 : end])

    ordered_ranges = sorted(ranges)
    for (_, previous_end), (next_start, _) in zip(ordered_ranges, ordered_ranges[1:]):
        if next_start < previous_end:
            _fail("invalid_code_signature")

    code_directory = slots.get(CSSLOT_CODE_DIRECTORY)
    if code_directory is None or code_directory[0] != CSMAGIC_CODE_DIRECTORY:
        _fail("invalid_code_signature")

    xml_slot = slots.get(CSSLOT_ENTITLEMENTS)
    der_slot = slots.get(CSSLOT_DER_ENTITLEMENTS)
    if der_slot is not None:
        if der_slot[0] != CSMAGIC_EMBEDDED_DER_ENTITLEMENTS:
            _fail("invalid_signed_entitlements")
        if len(der_slot[1]) > MAX_ENTITLEMENTS_BYTES:
            _fail("signed_entitlements_limit")
        # DER entitlements are not decoded here. Reject their presence even if
        # the SuperBlob also contains XML, rather than assuming both agree.
        _fail("unsupported_signed_entitlements")
    if xml_slot is not None:
        blob_magic, payload = xml_slot
        if blob_magic != CSMAGIC_EMBEDDED_ENTITLEMENTS:
            _fail("invalid_signed_entitlements")
        if len(payload) > MAX_ENTITLEMENTS_BYTES:
            _fail("signed_entitlements_limit")
        xml = payload.lstrip()
        if not (xml.startswith(b"<?xml") or xml.startswith(b"<plist")):
            _fail("invalid_signed_entitlements")
        try:
            entitlements = plistlib.loads(payload)
        except Exception:
            _fail("invalid_signed_entitlements")
        if not isinstance(entitlements, dict):
            _fail("invalid_signed_entitlements")
        if _contains_prohibited_declaration(entitlements):
            _fail("app_group_signature_entitlement")


def _inspect_macho_signature_slice(stream: Any, slice_size: int) -> int:
    magic = _I0._read_exact(stream, 4)
    if magic != b"\xcf\xfa\xed\xfe" or slice_size < 32:
        _fail("unsupported_signed_entitlements")
    header = magic + _I0._read_exact(stream, 28)
    _, cpu_type, cpu_subtype, _, command_count, command_bytes, _, _ = struct.unpack(
        "<IiiIIIII", header
    )
    _I0._validate_arm64(cpu_type, cpu_subtype)
    if (
        command_count > _I0.MAX_MACHO_LOAD_COMMANDS
        or command_bytes > _I0.MAX_MACHO_LOAD_COMMAND_BYTES
        or 32 + command_bytes > slice_size
    ):
        _fail("invalid_macho_load_command")
    commands = _I0._read_exact(stream, command_bytes)
    _I0._validate_load_commands(commands, command_count, command_bytes)

    signature: tuple[int, int] | None = None
    offset = 0
    for _ in range(command_count):
        if offset + 8 > len(commands):
            _fail("invalid_macho_load_command")
        command, command_size = struct.unpack_from("<II", commands, offset)
        if command_size < 8 or offset + command_size > len(commands):
            _fail("invalid_macho_load_command")
        if command == LC_CODE_SIGNATURE:
            if command_size != 16 or signature is not None:
                _fail("invalid_code_signature")
            data_offset, data_size = struct.unpack_from("<II", commands, offset + 8)
            signature = (data_offset, data_size)
        offset += command_size
    if offset != command_bytes:
        _fail("invalid_macho_load_command")

    command_end = 32 + command_bytes
    if signature is None:
        return command_end
    data_offset, data_size = signature
    if (
        data_size < 12
        or data_size > MAX_CODE_SIGNATURE_BYTES
        or data_offset < command_end
        or data_offset > slice_size
        or data_size > slice_size - data_offset
    ):
        _fail("invalid_code_signature")
    _I0._skip_exact(stream, data_offset - command_end)
    _parse_signature_superblob(_I0._read_exact(stream, data_size))
    return data_offset + data_size


def _inspect_macho_entitlements(zf: zipfile.ZipFile, info: zipfile.ZipInfo) -> None:
    if info.is_dir():
        return
    try:
        with zf.open(info, "r") as stream:
            magic = _I0._read_exact(stream, 4)
            if magic == b"\xcf\xfa\xed\xfe":
                stream.seek(0)
                consumed = _inspect_macho_signature_slice(stream, info.file_size)
                _I0._skip_exact(stream, info.file_size - consumed)
                return
            if magic not in _I0.FAT_MACHO_FORMATS:
                _fail("unsupported_signed_entitlements")

            arches, table_end = _I0._parse_fat_arches(stream, magic, info.file_size)
            current_position = table_end
            for _, _, slice_offset, slice_size in arches:
                if slice_offset < current_position:
                    _fail("invalid_macho")
                _I0._skip_exact(stream, slice_offset - current_position)
                consumed = _inspect_macho_signature_slice(stream, slice_size)
                _I0._skip_exact(stream, slice_size - consumed)
                current_position = slice_offset + slice_size
    except VerificationError:
        raise
    except (OSError, RuntimeError, EOFError, zipfile.BadZipFile, NotImplementedError, struct.error):
        _fail("invalid_code_signature")


def _read_prefix(zf: zipfile.ZipFile, info: zipfile.ZipInfo, length: int = 4) -> bytes:
    if info.is_dir():
        return b""
    try:
        with zf.open(info, "r") as stream:
            return stream.read(length)
    except (OSError, RuntimeError, EOFError, zipfile.BadZipFile, NotImplementedError):
        _fail("invalid_archive_member")


def _framework_roots(members: dict[str, zipfile.ZipInfo]) -> set[str]:
    roots: set[str] = set()
    for path in members:
        parts = path.split("/")
        for index, part in enumerate(parts):
            if part.casefold().endswith(".framework"):
                roots.add("/".join(parts[: index + 1]))
    return roots


def _validate_frameworks(
    zf: zipfile.ZipFile,
    members: dict[str, zipfile.ZipInfo],
    expected_revision: str,
) -> set[str]:
    roots = _framework_roots(members)
    if APP_FRAMEWORK_ROOT not in roots or FLUTTER_FRAMEWORK_ROOT not in roots:
        _fail("required_framework_missing")

    validated_binaries: set[str] = set()
    for root in sorted(roots):
        info_path = f"{root}/Info.plist"
        framework_info = _parse_plist_member(zf, members, info_path)
        executable = _validate_framework_executable(framework_info)
        executable_path = f"{root}/{executable}"
        executable_info = _I0._required_member(members, executable_path)
        revision = expected_revision.encode("ascii") if root == APP_FRAMEWORK_ROOT else None
        if not _I0._validate_macho(zf, executable_info, 6, expected_revision=revision):
            _fail("aot_revision_missing")
        validated_binaries.add(executable_path)

    # Inspect every Mach-O member within every framework, including auxiliary
    # binaries not named by CFBundleExecutable.
    for path, info in members.items():
        if info.is_dir():
            continue
        parts = path.split("/")
        if not any(part.casefold().endswith(".framework") for part in parts):
            continue
        if path in validated_binaries:
            continue
        magic = _read_prefix(zf, info)
        if _is_macho_magic(magic):
            _I0._validate_macho(zf, info, 6)

    return validated_binaries


def _validate_all_contents(
    zf: zipfile.ZipFile,
    infos: list[zipfile.ZipInfo],
    members: dict[str, zipfile.ZipInfo],
    declared_total: int,
    expected_revision: str,
) -> None:
    _validate_policy_paths(members)
    manifest_path = MANIFEST_PATH
    manifest_data = _I0._read_member(zf, _I0._required_member(members, manifest_path), _I0.MAX_MANIFEST)
    manifest = _I0._parse_json_manifest(manifest_data)
    _validate_manifest(manifest, expected_revision)

    app_info = _validate_info_and_entitlements(zf, members)
    executable = _validate_runner_info(app_info, expected_revision)
    runner_path = f"Payload/Runner.app/{executable}"
    if runner_path != RUNNER_EXECUTABLE_PATH:
        _fail("runner_executable_mismatch")

    runner_info = _I0._required_member(members, runner_path)
    _I0._validate_macho(zf, runner_info, 2)  # MH_EXECUTE, iPhoneOS arm64

    framework_binaries = _validate_frameworks(zf, members, expected_revision)
    if APP_FRAMEWORK_EXECUTABLE not in framework_binaries:
        _fail("required_framework_missing")
    if FLUTTER_FRAMEWORK_EXECUTABLE not in framework_binaries:
        _fail("required_framework_missing")
    for path, info in members.items():
        if path == "Payload/Runner.app" or path.startswith("Payload/Runner.app/"):
            if not info.is_dir() and _is_macho_magic(_read_prefix(zf, info)):
                _inspect_macho_entitlements(zf, info)
    _I0._validate_archive_contents(zf, infos, declared_total)


def _hash_stream(stream: BinaryIO) -> tuple[str, int]:
    return _I0._hash_stream(stream)


def verify_package(
    ipa_path: os.PathLike[str] | str,
    expected_revision: str,
    report_path: os.PathLike[str] | str | None = None,
) -> dict[str, Any]:
    """Verify an I1 unsigned IPA and return a path-free, fixed-shape report."""

    if not _expected_revision_is_valid(expected_revision):
        _fail("invalid_expected_revision")
    try:
        ipa_file = open(ipa_path, "rb")
    except (OSError, TypeError, ValueError):
        _fail("ipa_unreadable")

    with ipa_file:
        try:
            initial_stat = os.fstat(ipa_file.fileno())
            if not stat.S_ISREG(initial_stat.st_mode):
                _fail("ipa_unreadable")
            with zipfile.ZipFile(ipa_file, "r") as zf:
                members, declared_total = _I0._index_archive(zf)
                infos = zf.infolist()
                _validate_all_contents(zf, infos, members, declared_total, expected_revision)
            final_stat = os.fstat(ipa_file.fileno())
            if (
                initial_stat.st_size != final_stat.st_size
                or getattr(initial_stat, "st_mtime_ns", None) != getattr(final_stat, "st_mtime_ns", None)
                or getattr(initial_stat, "st_ino", None) != getattr(final_stat, "st_ino", None)
            ):
                _fail("ipa_changed_during_verification")
            ipa_sha256, ipa_bytes = _hash_stream(ipa_file)
            hashed_stat = os.fstat(ipa_file.fileno())
            if (
                ipa_bytes != final_stat.st_size
                or final_stat.st_size != hashed_stat.st_size
                or getattr(final_stat, "st_mtime_ns", None) != getattr(hashed_stat, "st_mtime_ns", None)
                or getattr(final_stat, "st_ino", None) != getattr(hashed_stat, "st_ino", None)
            ):
                _fail("ipa_changed_during_verification")
        except VerificationError:
            raise
        except (OSError, EOFError, RuntimeError, zipfile.BadZipFile, zipfile.LargeZipFile, ValueError, struct.error):
            _fail("invalid_ipa")

    report: dict[str, Any] = {
        "reportVersion": 1,
        "artifactKind": "ios-i1-unsigned-ipa-v1",
        "sourceRevision": expected_revision,
        "flutterVersion": "3.47.7",
        "xcodeVersion": "27.1",
        "buildMode": "release",
        "bundleId": APP_BUNDLE_ID,
        "scope": "i1-storage-bootstrap",
        "appleSignatureValidity": "not-verified",
        "ipaSha256": ipa_sha256,
        "ipaBytes": ipa_bytes,
        "checks": {
            "archivePathsAndSizes": True,
            "singleRunnerNoExtensionsOrPlugins": True,
            "deviceArm64RunnerAndFrameworks": True,
            "sourceRevisionMatchesRunnerAndAOT": True,
            "noAppGroupInfoEntitlementFilesOrSignatureEntitlements": True,
            "noProfilesPrivateKeysOrDebugAssets": True,
            "noAudioPermissionOrModelWeights": True,
        },
    }
    if report_path is not None:
        _I0._write_report(report_path, ipa_path, report)
    return report


class _SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        del message
        _fail("invalid_arguments")


def main(argv: list[str] | None = None) -> int:
    parser = _SafeArgumentParser(description="Verify an I1 unsigned iOS IPA.")
    parser.add_argument("--ipa", required=True)
    parser.add_argument("--expected-revision", required=True)
    parser.add_argument("--report", required=True)
    try:
        args = parser.parse_args(argv)
        report = verify_package(args.ipa, args.expected_revision, args.report)
    except VerificationError as exc:
        sys.stderr.write(f"verification failed: {exc.code}\n")
        return 2
    except SystemExit as exc:
        return int(exc.code or 0)
    except Exception:
        sys.stderr.write("verification failed: internal_error\n")
        return 2
    sys.stdout.write(json.dumps(report, ensure_ascii=True, sort_keys=True, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
