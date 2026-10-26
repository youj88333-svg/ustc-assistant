#!/usr/bin/env python3
"""Bounded structural verifier for the I0 unsigned iOS probe IPA.

The verifier reads ZIP members without extracting them. It validates package
identity and device Mach-O metadata; it does not validate Apple signing or
profile authorization.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
import stat
import struct
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath
from typing import BinaryIO, Any


APP_BUNDLE_ID = "cn.ustcassistant.ios.i0"
WIDGET_BUNDLE_ID = "cn.ustcassistant.ios.i0.widget"
APP_GROUP_BASE = "group.cn.ustcassistant.ios.i0"

MANIFEST_PATH = "Payload/Runner.app/ios-i0-provenance.json"
APP_INFO_PATH = "Payload/Runner.app/Info.plist"
WIDGET_ROOT = "Payload/Runner.app/PlugIns/I0Widget.appex"
WIDGET_INFO_PATH = f"{WIDGET_ROOT}/Info.plist"
APP_FRAMEWORK_EXECUTABLE = "Payload/Runner.app/Frameworks/App.framework/App"
FLUTTER_FRAMEWORK_EXECUTABLE = "Payload/Runner.app/Frameworks/Flutter.framework/Flutter"

MAX_ENTRIES = 5000
MAX_TOTAL_UNCOMPRESSED = 512 * 1024 * 1024
MAX_FILE_UNCOMPRESSED = 256 * 1024 * 1024
MAX_INFO_PLIST = 4 * 1024 * 1024
MAX_MANIFEST = 1024 * 1024
MAX_MACHO_LOAD_COMMAND_BYTES = 16 * 1024 * 1024
MAX_MACHO_LOAD_COMMANDS = 65536
MAX_FAT_ARCHES = 16
MAX_FAT_ALIGNMENT_EXPONENT = 31
MAX_COMPRESSION_RATIO = 1000
STREAM_CHUNK_SIZE = 64 * 1024

CPU_TYPE_ARM64 = 0x0100000C
ARM64_SUBTYPE_BASES = {0, 1, 2}  # ARM64_ALL, ARM64_V8 and ARM64E

ZIP_METHODS = {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED}
PRIVATE_KEY_SUFFIXES = (".p12", ".p8", ".pfx", ".key", ".pem", ".keystore", ".jks")
FAT_MACHO_MAGICS = {
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}
FAT_MACHO_FORMATS = {
    b"\xca\xfe\xba\xbe": (">", False),  # FAT_MAGIC
    b"\xbe\xba\xfe\xca": ("<", False),  # FAT_CIGAM
    b"\xca\xfe\xba\xbf": (">", True),  # FAT_MAGIC_64
    b"\xbf\xba\xfe\xca": ("<", True),  # FAT_CIGAM_64
}


class VerificationError(Exception):
    """A failure with a fixed, safe reason code suitable for CLI output."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def _fail(code: str) -> None:
    raise VerificationError(code)


def _is_reparse_or_symlink(path: Path, st: os.stat_result) -> bool:
    if stat.S_ISLNK(st.st_mode):
        return True
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    attributes = getattr(st, "st_file_attributes", 0)
    return bool(attributes & reparse_flag)


def _safe_report_target(report_path: os.PathLike[str] | str, ipa_path: os.PathLike[str] | str) -> Path:
    try:
        raw_report = os.fspath(report_path)
        raw_ipa = os.fspath(ipa_path)
        if not isinstance(raw_report, str) or not raw_report or "\x00" in raw_report:
            _fail("report_path_unsafe")
        if any(part == ".." for part in raw_report.replace("\\", "/").split("/")):
            _fail("report_path_unsafe")

        target = Path(os.path.abspath(raw_report))
        if target == Path(target.anchor):
            _fail("report_path_unsafe")

        # Check every existing component without following symlinks/reparse points.
        components = list(reversed(target.parents)) + [target]
        for index, component in enumerate(components):
            try:
                st = component.lstat()
            except FileNotFoundError:
                if index < len(components) - 1:
                    _fail("report_path_unsafe")
                continue
            except OSError:
                _fail("report_path_unsafe")
            if _is_reparse_or_symlink(component, st):
                _fail("report_path_unsafe")
            if index < len(components) - 1 and not stat.S_ISDIR(st.st_mode):
                _fail("report_path_unsafe")
            if index == len(components) - 1 and not stat.S_ISREG(st.st_mode):
                _fail("report_path_unsafe")

        parent = target.parent
        if not parent.is_dir():
            _fail("report_path_unsafe")

        try:
            if os.path.normcase(os.path.abspath(raw_ipa)) == os.path.normcase(os.path.abspath(raw_report)):
                _fail("report_path_is_input")
            if target.exists() and os.path.samefile(target, raw_ipa):
                _fail("report_path_is_input")
            # realpath also catches aliases through an input-side symlink.
            if os.path.normcase(os.path.realpath(target)) == os.path.normcase(os.path.realpath(raw_ipa)):
                _fail("report_path_is_input")
        except VerificationError:
            raise
        except OSError:
            _fail("report_path_unsafe")
        return target
    except VerificationError:
        raise
    except (OSError, TypeError, ValueError):
        _fail("report_path_unsafe")


def _write_report(report_path: os.PathLike[str] | str, ipa_path: os.PathLike[str] | str, report: dict[str, Any]) -> None:
    target = _safe_report_target(report_path, ipa_path)
    temp_name: str | None = None
    try:
        fd, temp_name = tempfile.mkstemp(prefix=".ios-i0-report-", suffix=".tmp", dir=str(target.parent))
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(report, stream, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_name, target)
    except VerificationError:
        raise
    except (OSError, TypeError, ValueError):
        _fail("report_write_failed")
    finally:
        if temp_name is not None:
            try:
                os.unlink(temp_name)
            except FileNotFoundError:
                pass
            except OSError:
                pass


def _archive_member_path(info: zipfile.ZipInfo) -> tuple[str, bool]:
    original = getattr(info, "orig_filename", info.filename)
    if not isinstance(original, str) or not original or original != info.filename:
        _fail("unsafe_archive_path")
    if "\x00" in original or "\\" in original or original.startswith("/"):
        _fail("unsafe_archive_path")
    if len(original) > 4096 or any(ord(ch) < 32 or ord(ch) == 127 for ch in original):
        _fail("unsafe_archive_path")
    if PurePosixPath(original).is_absolute():
        _fail("unsafe_archive_path")

    is_directory = info.is_dir()
    stripped = original[:-1] if is_directory else original
    if not stripped:
        _fail("unsafe_archive_path")
    parts = stripped.split("/")
    if any(part in ("", ".", "..") for part in parts):
        _fail("unsafe_archive_path")
    if any(":" in part for part in parts):
        _fail("unsafe_archive_path")
    return "/".join(parts), is_directory


def _is_private_material_or_debug_asset(path: str) -> bool:
    base = posixpath.basename(path).casefold()
    if base == "embedded.mobileprovision":
        return True
    if base.endswith(PRIVATE_KEY_SUFFIXES):
        return True
    if base in {"id_rsa", "id_ed25519", "private_key", "privatekey"}:
        return True
    if base in {"kernel_blob.bin", "app.dill"}:
        return True
    if base.endswith(".bcsymbolmap"):
        return True
    return any(part.casefold().endswith(".dsym") for part in path.split("/"))


def _index_archive(zf: zipfile.ZipFile) -> tuple[dict[str, zipfile.ZipInfo], int]:
    infos = zf.infolist()
    if not infos or len(infos) > MAX_ENTRIES:
        _fail("archive_entry_limit")

    members: dict[str, zipfile.ZipInfo] = {}
    path_kinds: dict[str, bool] = {}
    declared_total = 0
    for info in infos:
        normalized, is_directory = _archive_member_path(info)
        if normalized in members:
            _fail("duplicate_archive_path")

        unix_mode = (info.external_attr >> 16) & 0xFFFF
        file_type = stat.S_IFMT(unix_mode)
        if file_type == stat.S_IFLNK:
            _fail("unsafe_archive_link")
        if file_type not in (0, stat.S_IFREG, stat.S_IFDIR):
            _fail("unsafe_archive_entry_type")
        if is_directory != (file_type == stat.S_IFDIR) and file_type != 0:
            _fail("unsafe_archive_entry_type")
        if is_directory and (info.file_size != 0 or info.compress_size != 0):
            _fail("unsafe_archive_entry_type")
        if info.flag_bits & 0x1:
            _fail("encrypted_archive_member")
        if info.compress_type not in ZIP_METHODS:
            _fail("unsupported_archive_compression")
        if info.file_size < 0 or info.compress_size < 0:
            _fail("invalid_archive_size")
        if info.file_size > MAX_FILE_UNCOMPRESSED:
            _fail("archive_file_limit")
        if not is_directory:
            declared_total += info.file_size
            if declared_total > MAX_TOTAL_UNCOMPRESSED:
                _fail("archive_total_limit")
            if info.file_size and (info.compress_size == 0 or info.file_size > info.compress_size * MAX_COMPRESSION_RATIO):
                _fail("archive_compression_ratio")

        members[normalized] = info
        path_kinds[normalized] = is_directory

    # Reject a file used as a parent directory, which creates ambiguous trees.
    for path in members:
        parent = posixpath.dirname(path)
        while parent:
            if parent in path_kinds and not path_kinds[parent]:
                _fail("unsafe_archive_tree")
            parent = posixpath.dirname(parent)
    return members, declared_total


def _read_member(zf: zipfile.ZipFile, info: zipfile.ZipInfo, limit: int) -> bytes:
    if info.is_dir() or info.file_size > limit:
        _fail("invalid_required_member")
    data = bytearray()
    try:
        with zf.open(info, "r") as stream:
            while True:
                chunk = stream.read(min(STREAM_CHUNK_SIZE, limit + 1 - len(data)))
                if not chunk:
                    break
                data.extend(chunk)
                if len(data) > limit or len(data) > info.file_size:
                    _fail("invalid_required_member")
    except VerificationError:
        raise
    except (OSError, RuntimeError, EOFError, zipfile.BadZipFile, NotImplementedError):
        _fail("invalid_archive_member")
    if len(data) != info.file_size:
        _fail("invalid_archive_member")
    return bytes(data)


def _parse_json_manifest(data: bytes) -> dict[str, Any]:
    try:
        text = data.decode("utf-8", errors="strict")

        def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
            result: dict[str, Any] = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError("duplicate key")
                result[key] = value
            return result

        value = json.loads(text, object_pairs_hook=unique_object)
    except (UnicodeError, ValueError, json.JSONDecodeError, RecursionError):
        _fail("invalid_manifest")
    if not isinstance(value, dict):
        _fail("invalid_manifest")
    return value


def _validate_manifest(value: dict[str, Any], expected_revision: str) -> None:
    required = {
        "schemaVersion": 1,
        "kind": "ios-i0-unsigned-ipa-v1",
        "sourceRevision": expected_revision,
        "flutterVersion": "3.47.7",
        "xcodeVersion": "27.1",
        "buildMode": "release",
        "artifactStatus": "unsigned-personal-probe",
        "appBundleId": APP_BUNDLE_ID,
        "widgetBundleId": WIDGET_BUNDLE_ID,
        "appGroupBase": APP_GROUP_BASE,
    }
    if value.get("kind") == "ios-i0-signing-input-v1":
        required.update({
            "kind": "ios-i0-signing-input-v1",
            "artifactStatus": "adhoc-request-only",
            "metadataCarrier": "adhoc-entitlement-request",
            "appleDeveloperSignature": False,
        })
    elif "metadataCarrier" in value or "appleDeveloperSignature" in value:
        _fail("invalid_manifest")
    if set(required) - value.keys():
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


def _parse_plist(data: bytes) -> dict[str, Any]:
    try:
        import plistlib

        value = plistlib.loads(data)
    except Exception:
        _fail("invalid_info_plist")
    if not isinstance(value, dict):
        _fail("invalid_info_plist")
    return value


def _validate_info_plist(value: dict[str, Any], expected_bundle_id: str, expected_revision: str, *, widget: bool) -> str:
    if value.get("CFBundleIdentifier") != expected_bundle_id:
        _fail("bundle_identity_mismatch")
    supported = value.get("CFBundleSupportedPlatforms")
    if not isinstance(supported, list) or supported != ["iPhoneOS"]:
        _fail("platform_identity_mismatch")
    if value.get("I0SourceRevision") != expected_revision:
        _fail("source_revision_mismatch")
    if value.get("I0AppGroupBaseIdentifier") != APP_GROUP_BASE:
        _fail("app_group_declaration_mismatch")
    if widget:
        extension = value.get("NSExtension")
        if not isinstance(extension, dict) or extension.get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension":
            _fail("widget_extension_mismatch")
    executable = value.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or executable in (".", ".."):
        _fail("invalid_bundle_executable")
    if "/" in executable or "\\" in executable or ":" in executable:
        _fail("invalid_bundle_executable")
    return executable


def _required_member(members: dict[str, zipfile.ZipInfo], path: str) -> zipfile.ZipInfo:
    info = members.get(path)
    if info is None or info.is_dir():
        _fail("missing_required_member")
    return info


def _validate_bundle_layout(members: dict[str, zipfile.ZipInfo]) -> None:
    app_roots: set[str] = set()
    appex_roots: set[str] = set()
    for path in members:
        parts = path.split("/")
        if len(parts) >= 2 and parts[0] == "Payload" and parts[1].endswith(".app"):
            app_roots.add("/".join(parts[:2]))
        for index, part in enumerate(parts):
            if part.endswith(".appex"):
                appex_roots.add("/".join(parts[: index + 1]))
    if app_roots != {"Payload/Runner.app"}:
        _fail("app_bundle_count_mismatch")
    if appex_roots != {WIDGET_ROOT}:
        _fail("widget_bundle_count_mismatch")


def _read_exact(stream: Any, length: int, failure_code: str = "invalid_macho") -> bytes:
    if length < 0:
        _fail(failure_code)
    data = bytearray()
    while len(data) < length:
        chunk = stream.read(min(STREAM_CHUNK_SIZE, length - len(data)))
        if not chunk:
            _fail(failure_code)
        data.extend(chunk)
    return bytes(data)


def _skip_exact(stream: Any, length: int, failure_code: str = "invalid_macho") -> None:
    if length < 0:
        _fail(failure_code)
    remaining = length
    while remaining:
        chunk = stream.read(min(STREAM_CHUNK_SIZE, remaining))
        if not chunk:
            _fail(failure_code)
        remaining -= len(chunk)


def _validate_arm64(cpu_type: int, cpu_subtype: int) -> None:
    if cpu_type != CPU_TYPE_ARM64:
        _fail("macho_not_arm64")
    if (cpu_subtype & 0x00FFFFFF) not in ARM64_SUBTYPE_BASES:
        _fail("macho_subtype_unsupported")


def _validate_load_commands(commands: bytes, command_count: int, expected_command_bytes: int) -> None:
    offset = 0
    build_platforms: list[int] = []
    for _ in range(command_count):
        if offset + 8 > len(commands):
            _fail("invalid_macho_load_command")
        command, command_size = struct.unpack_from("<II", commands, offset)
        if command_size < 8 or offset + command_size > len(commands):
            _fail("invalid_macho_load_command")
        if command == 0x32:  # LC_BUILD_VERSION
            if command_size < 24:
                _fail("invalid_macho_load_command")
            platform, _, _, tool_count = struct.unpack_from("<IIII", commands, offset + 8)
            if 24 + tool_count * 8 > command_size:
                _fail("invalid_macho_load_command")
            build_platforms.append(platform)
        offset += command_size
    if offset != expected_command_bytes:
        _fail("invalid_macho_load_command")
    if not build_platforms:
        _fail("macho_platform_missing")
    if any(platform != 2 for platform in build_platforms):
        _fail("macho_platform_mismatch")


def _read_thin_slice_prefix(
    stream: Any,
    first_four: bytes,
    slice_size: int,
    expected_file_type: int,
    descriptor: tuple[int, int] | None = None,
) -> bytes:
    if first_four in FAT_MACHO_MAGICS:
        _fail("unsupported_nested_fat_macho")
    if first_four != b"\xcf\xfa\xed\xfe" or slice_size < 32:
        _fail("invalid_macho")
    header = first_four + _read_exact(stream, 28)
    _, cpu_type, cpu_subtype, file_type, command_count, command_bytes, _, _ = struct.unpack("<IiiIIIII", header)
    _validate_arm64(cpu_type, cpu_subtype)
    if descriptor is not None and descriptor != (cpu_type, cpu_subtype):
        _fail("fat_descriptor_mismatch")
    if file_type != expected_file_type:
        _fail("macho_file_type_mismatch")
    if command_count > MAX_MACHO_LOAD_COMMANDS or command_bytes > MAX_MACHO_LOAD_COMMAND_BYTES:
        _fail("macho_load_command_limit")
    if 32 + command_bytes > slice_size:
        _fail("invalid_macho")
    commands = _read_exact(stream, command_bytes)
    _validate_load_commands(commands, command_count, command_bytes)
    return header + commands


def _parse_fat_arches(stream: Any, magic: bytes, file_size: int) -> tuple[list[tuple[int, int, int, int]], int]:
    byte_order, is_64 = FAT_MACHO_FORMATS[magic]
    arch_count = struct.unpack(byte_order + "I", _read_exact(stream, 4))[0]
    if arch_count < 1 or arch_count > MAX_FAT_ARCHES:
        _fail("macho_fat_arch_count")
    entry_size = 32 if is_64 else 20
    table_bytes = arch_count * entry_size
    table_end = 8 + table_bytes
    if table_end > file_size:
        _fail("macho_fat_table_truncated")
    table = _read_exact(stream, table_bytes)

    architectures: list[tuple[int, int, int, int]] = []
    seen_architectures: set[tuple[int, int]] = set()
    for index in range(arch_count):
        base = index * entry_size
        if is_64:
            cpu_type, cpu_subtype, offset, size, alignment, reserved = struct.unpack_from(byte_order + "iiQQII", table, base)
            if reserved != 0:
                _fail("macho_fat_reserved_field")
        else:
            cpu_type, cpu_subtype, offset, size, alignment = struct.unpack_from(byte_order + "iiIII", table, base)

        _validate_arm64(cpu_type, cpu_subtype)
        architecture = (cpu_type, cpu_subtype)
        if architecture in seen_architectures:
            _fail("macho_fat_duplicate_arch")
        seen_architectures.add(architecture)

        if alignment > MAX_FAT_ALIGNMENT_EXPONENT:
            _fail("macho_fat_alignment")
        if offset < table_end:
            _fail("macho_fat_table_overlap")
        if size < 32 or offset > file_size or size > file_size - offset:
            _fail("macho_fat_out_of_bounds")
        if offset % (1 << alignment) != 0:
            _fail("macho_fat_alignment")
        architectures.append((cpu_type, cpu_subtype, offset, size))

    ordered = sorted(architectures, key=lambda arch: arch[2])
    previous_end = table_end
    for _, _, offset, size in ordered:
        if offset < previous_end:
            _fail("macho_fat_overlap")
        previous_end = offset + size
    return ordered, table_end


def _scan_slice_region(stream: Any, remaining: int, prefix: bytes, needle: bytes) -> bool:
    found = needle in prefix
    tail = prefix[-(len(needle) - 1) :] if len(needle) > 1 else b""
    left = remaining
    while left:
        chunk = stream.read(min(STREAM_CHUNK_SIZE, left))
        if not chunk:
            _fail("invalid_macho")
        left -= len(chunk)
        if not found:
            combined = tail + chunk
            if needle in combined:
                found = True
            elif len(needle) > 1:
                tail = combined[-(len(needle) - 1) :]
    return found


def _validate_macho(
    zf: zipfile.ZipFile,
    info: zipfile.ZipInfo,
    expected_file_type: int,
    *,
    expected_revision: bytes | None = None,
) -> bool:
    """Validate one thin or universal executable using a single forward ZIP stream."""
    scan_revision = expected_revision is not None
    revision = expected_revision if expected_revision is not None else b""
    try:
        with zf.open(info, "r") as stream:
            magic = _read_exact(stream, 4)
            if magic == b"\xcf\xfa\xed\xfe":
                prefix = _read_thin_slice_prefix(stream, magic, info.file_size, expected_file_type)
                if not scan_revision:
                    return True
                return _scan_slice_region(stream, info.file_size - len(prefix), prefix, revision)
            if magic not in FAT_MACHO_FORMATS:
                if magic in FAT_MACHO_MAGICS:
                    _fail("unsupported_macho_format")
                _fail("invalid_macho")

            architectures, table_end = _parse_fat_arches(stream, magic, info.file_size)
            current_position = table_end
            revision_found_in_every_slice = True
            for cpu_type, cpu_subtype, slice_offset, slice_size in architectures:
                if slice_offset < current_position:
                    _fail("macho_fat_overlap")
                _skip_exact(stream, slice_offset - current_position)
                current_position = slice_offset
                prefix = _read_thin_slice_prefix(
                    stream,
                    _read_exact(stream, 4),
                    slice_size,
                    expected_file_type,
                    (cpu_type, cpu_subtype),
                )
                remaining = slice_size - len(prefix)
                if scan_revision:
                    if not _scan_slice_region(stream, remaining, prefix, revision):
                        revision_found_in_every_slice = False
                else:
                    _skip_exact(stream, remaining)
                current_position += slice_size
            return revision_found_in_every_slice
    except VerificationError:
        raise
    except (OSError, RuntimeError, EOFError, zipfile.BadZipFile, NotImplementedError):
        _fail("invalid_macho")


def _validate_archive_contents(
    zf: zipfile.ZipFile,
    infos: list[zipfile.ZipInfo],
    declared_total: int,
) -> None:
    actual_total = 0
    for info in infos:
        if info.is_dir():
            continue
        count = 0
        try:
            with zf.open(info, "r") as stream:
                while True:
                    chunk = stream.read(STREAM_CHUNK_SIZE)
                    if not chunk:
                        break
                    count += len(chunk)
                    actual_total += len(chunk)
                    if count > info.file_size or actual_total > MAX_TOTAL_UNCOMPRESSED:
                        _fail("archive_actual_size_limit")
        except VerificationError:
            raise
        except (OSError, RuntimeError, EOFError, zipfile.BadZipFile, NotImplementedError):
            _fail("invalid_archive_member")
        if count != info.file_size:
            _fail("invalid_archive_member")
    if actual_total != declared_total:
        _fail("invalid_archive_size")


def _hash_stream(stream: BinaryIO) -> tuple[str, int]:
    digest = hashlib.sha256()
    length = 0
    stream.seek(0)
    while True:
        block = stream.read(1024 * 1024)
        if not block:
            break
        digest.update(block)
        length += len(block)
    return digest.hexdigest(), length


def verify_package(
    ipa_path: os.PathLike[str] | str,
    expected_revision: str,
    report_path: os.PathLike[str] | str | None = None,
) -> dict[str, Any]:
    """Verify an I0 IPA and return a safe, path-free report dictionary."""

    if not isinstance(expected_revision, str) or len(expected_revision) != 40:
        _fail("invalid_expected_revision")
    if any(ch not in "0123456789abcdef" for ch in expected_revision):
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
                members, declared_total = _index_archive(zf)
                infos = zf.infolist()
                for path in members:
                    if _is_private_material_or_debug_asset(path):
                        _fail("prohibited_package_asset")
                _validate_bundle_layout(members)

                manifest_data = _read_member(zf, _required_member(members, MANIFEST_PATH), MAX_MANIFEST)
                manifest = _parse_json_manifest(manifest_data)
                _validate_manifest(manifest, expected_revision)

                app_info = _parse_plist(_read_member(zf, _required_member(members, APP_INFO_PATH), MAX_INFO_PLIST))
                widget_info = _parse_plist(_read_member(zf, _required_member(members, WIDGET_INFO_PATH), MAX_INFO_PLIST))
                app_executable = _validate_info_plist(app_info, APP_BUNDLE_ID, expected_revision, widget=False)
                widget_executable = _validate_info_plist(widget_info, WIDGET_BUNDLE_ID, expected_revision, widget=True)

                app_exec_path = f"Payload/Runner.app/{app_executable}"
                widget_exec_path = f"{WIDGET_ROOT}/{widget_executable}"
                app_exec_info = _required_member(members, app_exec_path)
                widget_exec_info = _required_member(members, widget_exec_path)
                aot_info = _required_member(members, APP_FRAMEWORK_EXECUTABLE)
                flutter_info = _required_member(members, FLUTTER_FRAMEWORK_EXECUTABLE)

                _validate_macho(zf, app_exec_info, 2)  # MH_EXECUTE
                _validate_macho(zf, widget_exec_info, 2)
                aot_revision_found = _validate_macho(zf, aot_info, 6, expected_revision=expected_revision.encode("ascii"))  # MH_DYLIB
                _validate_macho(zf, flutter_info, 6)

                _validate_archive_contents(zf, infos, declared_total)
                if not aot_revision_found:
                    _fail("aot_revision_missing")

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
        "artifactKind": manifest["kind"],
        "sourceRevision": expected_revision,
        "flutterVersion": "3.47.7",
        "xcodeVersion": "27.1",
        "buildMode": "release",
        "artifactStatus": manifest["artifactStatus"],
        "appBundleId": APP_BUNDLE_ID,
        "widgetBundleId": WIDGET_BUNDLE_ID,
        "appGroupBase": APP_GROUP_BASE,
        "ipaSha256": ipa_sha256,
        "ipaBytes": ipa_bytes,
        "checks": {
            "archivePathsAndSizes": True,
            "singleRunnerAndWidget": True,
            "targetIdentityAndRevision": True,
            "iPhoneOSArm64MachO": True,
            "aotRevisionEmbedded": True,
            "noEmbeddedProvisioningProfileOrPrivateKeyFiles": True,
            "noDebugKernelOrDebugSymbolAssets": True,
        },
    }
    if report_path is not None:
        _write_report(report_path, ipa_path, report)
    return report


class _SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        del message
        _fail("invalid_arguments")


def main(argv: list[str] | None = None) -> int:
    parser = _SafeArgumentParser(description="Verify an I0 unsigned iOS probe IPA.")
    parser.add_argument("--ipa", required=True)
    parser.add_argument("--expected-revision", required=True)
    parser.add_argument("--report")
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
