"""Query Result 1.0 envelopes and strict validators for the read-only Agent.

The Flutter Agent calls Python source pipelines through the Windows Python
Bridge (Task 8) and receives bounded Query Result 1.0 envelopes. Each envelope
guarantees:

* ``schemaVersion`` is always the string ``"1.0"``;
* a ``queryType`` identifying one of the four approved query kinds;
* a ``generatedAt`` Beijing-time (Asia/Shanghai) ISO-8601 timestamp;
* bounded ``data`` (no raw HTML, no unbounded text, no arbitrary URLs);
* a ``metadata`` mapping with counts/cache-freshness;
* a ``references`` list of trusted public source URLs that actually appeared
  in the source results (never fabricated).

The validator is security-load-bearing: a prompt-injection payload embedded in
a course review or activity description must not be able to smuggle an
arbitrary URL, raw HTML, unbounded text, or private enrolment fields (password,
account id, user identity) into the Agent context.
"""

from __future__ import annotations

import copy
import re
from collections.abc import Mapping, Sequence
from datetime import datetime
from typing import Any
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo


SCHEMA_VERSION = "1.0"
BEIJING_TZ = ZoneInfo("Asia/Shanghai")

YOUNG_ENROLMENT = "young_enrolment"
ICOURSE = "icourse"
CAMPUS_SEARCH = "campus_search"
CAMPUS_DETAIL = "campus_detail"

QUERY_TYPES = frozenset(
    {YOUNG_ENROLMENT, ICOURSE, CAMPUS_SEARCH, CAMPUS_DETAIL}
)

# Maximum length for any single string value inside envelope ``data``. Keeps a
# malicious or oversized source field from flooding the Agent context.
MAX_TEXT_LENGTH = 8000

# Top-level keys allowed on every Query Result 1.0 envelope.
_TOP_LEVEL_KEYS = frozenset(
    {"schemaVersion", "queryType", "generatedAt", "data", "metadata", "references"}
)

# Key fragments that must never appear anywhere in an envelope (case-insensitive,
# ignores separators). Mirrors the SourceBundle sensitive-fragment policy.
_SENSITIVE_KEY_FRAGMENTS = frozenset(
    {
        "authorization",
        "cookie",
        "credential",
        "password",
        "profilepath",
        "sessionid",
        "sessiontoken",
        "studentid",
        "token",
        "userid",
    }
)

# Private enrolment field names that must never appear in young_enrolment data,
# even as exact keys (the source records carry these and they must be dropped).
_PRIVATE_ENROLMENT_KEYS = frozenset(
    {
        "password",
        "accountId",
        "account_id",
        "userId",
        "user_id",
        "descriptionHtml",
        "requirementsHtml",
        "username",
    }
)

# Hosts that are trusted public source origins. Any URL inside an envelope must
# resolve to one of these hosts (or be a discovered child of a campus detail,
# which is validated against the campus reader's own allowlist at read time).
_TRUSTED_HOSTS = frozenset(
    {
        "icourse.club",
        "teach.ustc.edu.cn",
        "www.teach.ustc.edu.cn",
        "finance.ustc.edu.cn",
        "young.ustc.edu.cn",
    }
)

# Catalog/discovered-link ID prefixes that campus wrappers accept.
CAMPUS_ID_PREFIX = "campus_"
LINK_ID_PREFIX = "link_"
ATTACHMENT_ID_PREFIX = "attachment_"

_URL_TOKEN_RE = re.compile(r"(?:(?:https?:)?//[^\s<>'\"`]+)")


class QueryResultValidationError(ValueError):
    """A Query Result envelope violated the bounded-output contract.

    Carries a stable ``code`` and a ``safe_message`` that never echoes
    untrusted source content, mirroring ``SourceBundleValidationError``.
    """

    def __init__(self, code: str, safe_message: str):
        self.code = code
        self.safe_message = safe_message
        super().__init__(f"{code}: {safe_message}")


def _raise(code: str, safe_message: str) -> None:
    raise QueryResultValidationError(code, safe_message)


def beijing_now_iso() -> str:
    """Return the current Beijing time as an ISO-8601 string with +08:00."""
    return datetime.now(BEIJING_TZ).isoformat(timespec="seconds")


def _is_beijing_timestamp(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return False
    offset = parsed.utcoffset()
    return offset is not None and offset.total_seconds() == 28800


def _is_trusted_url(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    split = urlsplit(value.strip())
    if split.scheme != "https":
        return False
    host = (split.hostname or "").lower()
    return host in _TRUSTED_HOSTS


def _looks_like_html(value: str) -> bool:
    """Heuristic: reject strings containing HTML-like angle-bracket tags.

    Catches ``<p>``, ``<script>``, ``<br/>`` etc. The enrolment/campus
    pipelines already convert HTML to plain text before building envelopes;
    this guard rejects anything that slipped through.
    """
    if "<" not in value or ">" not in value:
        return False
    # A lone ``<`` or ``>`` used as punctuation (e.g. "a < b") is allowed only
    # when no closing tag structure is present. Detect tag-like sequences.
    import re

    return bool(re.search(r"<\s*/?\s*[a-zA-Z][^>]*>", value))


def _collect_urls(value: Any, found: set[str]) -> None:
    """Recursively collect every string that parses as an https URL."""
    if isinstance(value, str):
        stripped = value.strip()
        if stripped.startswith("https://") and _is_trusted_url(stripped):
            found.add(stripped)
        return
    if isinstance(value, Mapping):
        for child in value.values():
            _collect_urls(child, found)
        return
    if isinstance(value, Sequence) and not isinstance(value, (str, bytes)):
        for child in value:
            _collect_urls(child, found)


def _inspect_keys(value: Any, *, query_type: str) -> None:
    """Reject sensitive key fragments and private enrolment fields."""
    if isinstance(value, Mapping):
        for key in value.keys():
            if not isinstance(key, str):
                _raise("invalid_envelope", "envelope keys must be text")
            normalized = key.lower().replace("_", "").replace("-", "")
            if any(fragment in normalized for fragment in _SENSITIVE_KEY_FRAGMENTS):
                _raise("invalid_envelope", "envelope contains a sensitive field")
            if query_type == YOUNG_ENROLMENT and key in _PRIVATE_ENROLMENT_KEYS:
                _raise(
                    "private_field",
                    "young enrolment envelope contains a private field",
                )
        for child in value.values():
            _inspect_keys(child, query_type=query_type)
    elif isinstance(value, Sequence) and not isinstance(value, (str, bytes)):
        for child in value:
            _inspect_keys(child, query_type=query_type)


def _inspect_text(value: Any) -> None:
    """Reject raw HTML and unbounded text anywhere in the envelope."""
    if isinstance(value, str):
        if len(value) > MAX_TEXT_LENGTH:
            _raise("unbounded_text", "envelope text exceeds the length limit")
        if _looks_like_html(value):
            _raise("raw_html", "envelope contains raw HTML")
        return
    if isinstance(value, Mapping):
        for child in value.values():
            _inspect_text(child)
    elif isinstance(value, Sequence) and not isinstance(value, (str, bytes)):
        for child in value:
            _inspect_text(child)


def _inspect_urls(value: Any, allowed_urls: set[str]) -> None:
    """Reject any outbound URL that is not in ``allowed_urls``.

    ``allowed_urls`` is the set of trusted URLs that the source pipeline
    actually produced. This prevents a prompt-injection payload from smuggling
    an arbitrary external URL into the Agent context.
    """
    if isinstance(value, str):
        for match in _URL_TOKEN_RE.finditer(value):
            url = match.group(0).rstrip(".,;:!?")
            if url not in allowed_urls:
                _raise(
                    "untrusted_url",
                    "envelope contains a URL that was not produced by the source",
                )
        return
    if isinstance(value, Mapping):
        for child in value.values():
            _inspect_urls(child, allowed_urls)
    elif isinstance(value, Sequence) and not isinstance(value, (str, bytes)):
        for child in value:
            _inspect_urls(child, allowed_urls)


def validate_query_result(envelope: Mapping[str, Any]) -> None:
    """Validate a Query Result 1.0 envelope, raising on any contract breach."""
    if not isinstance(envelope, Mapping):
        _raise("invalid_envelope", "envelope must be a mapping")

    unknown = set(envelope.keys()) - _TOP_LEVEL_KEYS
    if unknown:
        _raise("invalid_envelope", "envelope contains an unknown field")

    if envelope.get("schemaVersion") != SCHEMA_VERSION:
        _raise("unsupported_version", "envelope schemaVersion is not supported")

    query_type = envelope.get("queryType")
    if not isinstance(query_type, str) or query_type not in QUERY_TYPES:
        _raise("invalid_envelope", "envelope queryType is not recognized")

    generated_at = envelope.get("generatedAt")
    if not _is_beijing_timestamp(generated_at):
        _raise("invalid_time", "envelope generatedAt must be a Beijing-time timestamp")

    data = envelope.get("data")
    if not isinstance(data, Mapping):
        _raise("invalid_envelope", "envelope data must be a mapping")

    metadata = envelope.get("metadata")
    if not isinstance(metadata, Mapping):
        _raise("invalid_envelope", "envelope metadata must be a mapping")

    references = envelope.get("references")
    if not isinstance(references, Sequence) or isinstance(references, (str, bytes)):
        _raise("invalid_envelope", "envelope references must be a list")
    for reference in references:
        if not _is_trusted_url(reference):
            _raise("untrusted_url", "envelope reference is not a trusted source URL")

    # Reject sensitive keys and private enrolment fields.
    _inspect_keys(data, query_type=query_type)
    _inspect_keys(metadata, query_type=query_type)

    # Reject raw HTML and unbounded text anywhere in data/metadata/references.
    _inspect_text(data)
    _inspect_text(metadata)
    _inspect_text(list(references))

    # Every URL in data or metadata must be one of the declared references
    # (which are themselves trusted). This keeps the Agent from following a
    # URL that the source pipeline did not actually surface.
    allowed_urls = set(references)
    _inspect_urls(data, allowed_urls)
    _inspect_urls(metadata, allowed_urls)


def _base_envelope(
    *,
    query_type: str,
    data: Mapping[str, Any],
    metadata: Mapping[str, Any],
    references: Sequence[str],
    generated_at: str | None,
) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "queryType": query_type,
        "generatedAt": generated_at or beijing_now_iso(),
        "data": copy.deepcopy(dict(data)),
        "metadata": copy.deepcopy(dict(metadata)),
        "references": list(references),
    }


def build_young_enrolment_envelope(
    *,
    data: Mapping[str, Any],
    metadata: Mapping[str, Any],
    references: Sequence[str] = (),
    generated_at: str | None = None,
) -> dict[str, Any]:
    return _base_envelope(
        query_type=YOUNG_ENROLMENT,
        data=data,
        metadata=metadata,
        references=references,
        generated_at=generated_at,
    )


def build_icourse_envelope(
    *,
    data: Mapping[str, Any],
    metadata: Mapping[str, Any],
    references: Sequence[str] = (),
    generated_at: str | None = None,
) -> dict[str, Any]:
    return _base_envelope(
        query_type=ICOURSE,
        data=data,
        metadata=metadata,
        references=references,
        generated_at=generated_at,
    )


def build_campus_search_envelope(
    *,
    data: Mapping[str, Any],
    metadata: Mapping[str, Any],
    references: Sequence[str] = (),
    generated_at: str | None = None,
) -> dict[str, Any]:
    return _base_envelope(
        query_type=CAMPUS_SEARCH,
        data=data,
        metadata=metadata,
        references=references,
        generated_at=generated_at,
    )


def build_campus_detail_envelope(
    *,
    data: Mapping[str, Any],
    metadata: Mapping[str, Any],
    references: Sequence[str] = (),
    generated_at: str | None = None,
) -> dict[str, Any]:
    return _base_envelope(
        query_type=CAMPUS_DETAIL,
        data=data,
        metadata=metadata,
        references=references,
        generated_at=generated_at,
    )
