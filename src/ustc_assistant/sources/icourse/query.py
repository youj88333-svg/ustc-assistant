"""Stable, bounded public iCourse query entry point for the read-only Agent.

``query_course_public`` is the Agent-facing wrapper around the existing iCourse
client, ranking, cache, site-AI-summary, and representative-evidence logic. It
never accepts a JW bundle or user identity, never duplicates parser logic, and
returns its result wrapped in a Query Result 1.0 envelope
(``bridge.query_contracts``) so the Agent only ever sees bounded, trusted
public data.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

from ustc_assistant.bridge import query_contracts as contracts
from ustc_assistant.sources.icourse import service as icourse_service


DEFAULT_CACHE_DIR = Path("tmp/icourse-cache")


def _collect_source_urls(results: Sequence[Mapping[str, Any]]) -> list[str]:
    """Collect every trusted public source URL that actually appeared in results.

    Only URLs produced by the iCourse parser are included; nothing is
    fabricated. The envelope validator rejects any URL not in this list.
    """
    urls: list[str] = []
    seen: set[str] = set()
    for entry in results:
        if not isinstance(entry, Mapping):
            continue
        source_url = entry.get("sourceUrl")
        if isinstance(source_url, str) and source_url not in seen:
            seen.add(source_url)
            urls.append(source_url)
        for teacher in entry.get("teacherLinks", []) or []:
            if not isinstance(teacher, Mapping):
                continue
            teacher_url = teacher.get("sourceUrl")
            if isinstance(teacher_url, str) and teacher_url not in seen:
                seen.add(teacher_url)
                urls.append(teacher_url)
    return urls


def _course_entries(client: Any, search_text: str) -> list[dict[str, Any]]:
    """Reuse the service's course-entry resolver (search -> get_course)."""
    return icourse_service._course_entries(client, search_text)


def _offering_from_teachers(
    course: str, teachers: Sequence[str]
) -> dict[str, Any]:
    """Build a minimal offering shape so relation_strength can be reused.

    The offering carries only the public course title and the requested
    teacher names; it never carries account or user identity.
    """
    return {"title": course, "teachers": list(teachers)}


def query_course_public(
    course: str,
    *,
    teachers: tuple[str, ...] = (),
    preferences: Mapping[str, str] | None = None,
    cache_dir: Path = DEFAULT_CACHE_DIR,
    timeout_seconds: float = 20,
    client: Any | None = None,
) -> dict[str, Any]:
    """Run a bounded public iCourse course query and wrap it in a 1.0 envelope.

    The result holds the existing structured aggregate (ranked candidates with
    site AI summary, selected evidence, relation strength, cache freshness, and
    public source URL) inside ``data``; counts/cache-freshness live in
    ``metadata``; the trusted public source URLs that actually appeared live in
    ``references``. Never accepts a JW bundle or user identity.
    """
    resolved_preferences: dict[str, str] = dict(preferences) if preferences else {}
    active_client = client
    if active_client is None:
        active_client = icourse_service.build_client(cache_dir, timeout_seconds)

    entries = _course_entries(active_client, course)
    ranked = icourse_service._rank_with_evidence(entries, resolved_preferences)

    # Compute relation strength for each candidate against the requested
    # teacher set, reusing the existing service helper. When no teachers are
    # requested the relation is "same_course_only" by definition.
    offering = _offering_from_teachers(course, teachers) if teachers else None
    for entry in ranked:
        if offering is not None:
            entry["relationStrength"] = icourse_service.relation_strength(
                offering, entry
            )
        else:
            entry["relationStrength"] = "same_course_only"

    source_urls = _collect_source_urls(ranked)
    stale_count = icourse_service._count_stale(ranked)

    data = {
        "query": {
            "mode": "course",
            "value": course,
            "teachers": list(teachers),
            "preferences": resolved_preferences,
        },
        "results": ranked,
    }
    metadata = {
        "resultCount": len(ranked),
        "staleEntryCount": stale_count,
    }

    envelope = contracts.build_icourse_envelope(
        data=data,
        metadata=metadata,
        references=source_urls,
    )
    return envelope
