"""Shared, validated configuration for source collectors."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any


class SourceConfigError(ValueError):
    """Raised when source configuration is absent or invalid."""


@dataclass(frozen=True)
class JwSemesterConfig:
    semester_id: int
    semester_key: str
    display_name: str


_DEFAULT_CONFIG_PATH = Path(__file__).resolve().parents[2] / "config" / "source-defaults.json"
_ROOT_KEYS = frozenset({"jw"})
_JW_KEYS = frozenset({"semesterId", "semesterKey", "displayName"})


def _require_exact_keys(payload: dict[str, Any], expected: frozenset[str], label: str) -> None:
    keys = set(payload)
    unknown = keys - expected
    missing = expected - keys
    if unknown:
        raise SourceConfigError(f"{label} has unknown keys: {sorted(unknown)}")
    if missing:
        raise SourceConfigError(f"{label} is missing required keys: {sorted(missing)}")


def _build_jw_semester(
    semester_id: object,
    semester_key: object,
    display_name: object,
) -> JwSemesterConfig:
    if isinstance(semester_id, bool) or not isinstance(semester_id, int) or semester_id < 1:
        raise SourceConfigError("semesterId must be an integer greater than zero")
    if not isinstance(semester_key, str) or not semester_key.strip():
        raise SourceConfigError("semesterKey must be non-blank text")
    if not isinstance(display_name, str) or not display_name.strip():
        raise SourceConfigError("displayName must be non-blank text")
    return JwSemesterConfig(semester_id, semester_key, display_name)


def load_default_jw_semester(path: Path | None = None) -> JwSemesterConfig:
    """Load the repository's complete JW semester triple from UTF-8 JSON."""
    config_path = _DEFAULT_CONFIG_PATH if path is None else Path(path)
    try:
        payload = json.loads(config_path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise SourceConfigError(f"could not read source configuration: {config_path}") from exc
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SourceConfigError(f"invalid source configuration JSON: {config_path}") from exc

    if not isinstance(payload, dict):
        raise SourceConfigError("source configuration root must be an object")
    _require_exact_keys(payload, _ROOT_KEYS, "source configuration")
    jw = payload["jw"]
    if not isinstance(jw, dict):
        raise SourceConfigError("jw source configuration must be an object")
    _require_exact_keys(jw, _JW_KEYS, "jw source configuration")
    return _build_jw_semester(
        jw["semesterId"],
        jw["semesterKey"],
        jw["displayName"],
    )


def render_flutter_source_defaults(semester: JwSemesterConfig) -> str:
    """Render the canonical JW semester triple as a committed Dart constants file.

    Never infers the semester ID from the calendar year: every value is read
    verbatim from the source config so the Flutter build stays byte-for-byte in
    sync with ``config/source-defaults.json``.
    """
    semester_key = _escape_dart_string(semester.semester_key)
    display_name = _escape_dart_string(semester.display_name)
    return (
        "// GENERATED FILE - DO NOT EDIT.\n"
        f"const int kDefaultJwSemesterId = {semester.semester_id};\n"
        f"const String kDefaultJwSemesterKey = '{semester_key}';\n"
        f"const String kDefaultJwSemesterDisplayName = '{display_name}';\n"
        "const Map<String, Object> kDefaultJwSemester = {\n"
        "  'semesterId': kDefaultJwSemesterId,\n"
        "  'semesterKey': kDefaultJwSemesterKey,\n"
        "  'displayName': kDefaultJwSemesterDisplayName,\n"
        "};\n"
    )


def _escape_dart_string(value: str) -> str:
    """Escape a value as a Dart single-quoted string literal body."""
    return (
        value.replace("\\", "\\\\")
        .replace("'", "\\'")
        .replace("\r", "\\r")
        .replace("\n", "\\n")
        .replace("$", "\\$")
    )


def resolve_jw_semester(
    default: JwSemesterConfig,
    *,
    semester_id: int | None = None,
    semester_key: str | None = None,
    display_name: str | None = None,
) -> JwSemesterConfig:
    """Use a complete debug override, or retain the shared default triple."""
    values = (semester_id, semester_key, display_name)
    if any(value is not None for value in values) and not all(
        value is not None for value in values
    ):
        raise SourceConfigError("complete semester override is required")
    if all(value is None for value in values):
        return default
    return _build_jw_semester(semester_id, semester_key, display_name)
