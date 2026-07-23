"""Orchestration and app-callable services for public campus information."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping

from ustc_assistant.sources.campus import finance, teach
from ustc_assistant.sources.campus.catalog import (
    BEIJING_TZ,
    CampusError,
    CatalogEntry,
    CatalogStore,
    canonicalize_url,
    is_monthly_refresh_due,
    notice_cutoff,
)
from ustc_assistant.sources.campus.detail import CampusHttpClient, DetailReader


DEFAULT_CATALOG_PATH = Path("tmp/campus-catalog.json")
DEFAULT_CACHE_DIR = Path("tmp/campus-cache")
MAX_PAGES_PER_SOURCE = 100


@dataclass(frozen=True)
class SourceDefinition:
    name: str
    url: str
    kind: str
    cadence: str
    parser: Callable[..., Any]


SOURCE_DEFINITIONS: Mapping[str, SourceDefinition] = {
    "teach_notice": SourceDefinition(
        name="teach_notice",
        url="https://www.teach.ustc.edu.cn/category/notice",
        kind="notice",
        cadence="notice",
        parser=teach.parse_teach_catalog,
    ),
    "teach_student_service": SourceDefinition(
        name="teach_student_service",
        url="https://www.teach.ustc.edu.cn/category/service/svc-student",
        kind="guide",
        cadence="monthly",
        parser=teach.parse_teach_catalog,
    ),
    "finance_notice": SourceDefinition(
        name="finance_notice",
        url="https://finance.ustc.edu.cn/tzgg/list.htm",
        kind="notice",
        cadence="notice",
        parser=finance.parse_finance_catalog,
    ),
    "finance_public_information": SourceDefinition(
        name="finance_public_information",
        url="https://finance.ustc.edu.cn/xxgk/list.htm",
        kind="public_information",
        cadence="monthly",
        parser=finance.parse_finance_catalog,
    ),
    "finance_business_guide": SourceDefinition(
        name="finance_business_guide",
        url="https://finance.ustc.edu.cn/ywzn/list.psp",
        kind="guide",
        cadence="monthly",
        parser=finance.parse_finance_catalog,
    ),
}


def _published_date(entry: CatalogEntry) -> date:
    if entry.published_at is None:
        raise CampusError("campus notice entry did not include a publication date")
    try:
        return date.fromisoformat(entry.published_at)
    except ValueError as exc:
        raise CampusError("campus notice publication date was invalid") from exc


def _collect_source(
    definition: SourceDefinition,
    *,
    client: Any,
    now: datetime,
    today: date,
) -> list[CatalogEntry]:
    current_url: str | None = definition.url
    visited: set[str] = set()
    observed: dict[str, CatalogEntry] = {}
    cutoff = notice_cutoff(today)

    while current_url is not None:
        canonical_page = canonicalize_url(current_url)
        if canonical_page in visited:
            raise CampusError("campus catalog pagination loop was detected")
        if len(visited) >= MAX_PAGES_PER_SOURCE:
            raise CampusError("campus catalog pagination exceeded the page limit")
        visited.add(canonical_page)

        html = client.get_text(current_url)
        page = definition.parser(
            html,
            source=definition.name,
            kind=definition.kind,
            base_url=current_url,
            observed_at=now,
        )
        stop_after_page = False
        for entry in page.entries:
            if definition.cadence == "notice":
                published = _published_date(entry)
                if published > today + timedelta(days=1):
                    raise CampusError("campus notice publication date was unexpectedly future")
                if published < cutoff:
                    stop_after_page = True
                    continue
                if published > today:
                    continue
            existing = observed.get(entry.id)
            if existing is not None and existing != entry:
                raise CampusError("campus catalog contained a conflicting duplicate")
            observed[entry.id] = entry
        if stop_after_page:
            break
        current_url = page.next_url
    return list(observed.values())


def refresh_catalogs(
    sources: Iterable[str] | None = None,
    force: bool = False,
    *,
    catalog_path: Path = DEFAULT_CATALOG_PATH,
    client: Any | None = None,
    timeout_seconds: float = 20,
    now: datetime | None = None,
    today: date | None = None,
) -> dict[str, Any]:
    selected = list(sources) if sources is not None else list(SOURCE_DEFINITIONS)
    unknown = [name for name in selected if name not in SOURCE_DEFINITIONS]
    if unknown:
        raise ValueError("unknown campus catalog source")

    checked_at = now or datetime.now(BEIJING_TZ)
    current_date = today or checked_at.astimezone(BEIJING_TZ).date()
    store = CatalogStore(Path(catalog_path))
    http = client or CampusHttpClient(timeout_seconds=timeout_seconds)
    results: dict[str, dict[str, Any]] = {}

    for name in selected:
        definition = SOURCE_DEFINITIONS[name]
        if (
            definition.cadence == "monthly"
            and not force
            and not is_monthly_refresh_due(
                store.last_successful_at(name),
                checked_at,
            )
        ):
            results[name] = {
                "status": "skipped",
                "activeCount": store.count(
                    filters={"source": name, "status": "active"}
                ),
                "error": None,
            }
            continue
        try:
            observed = _collect_source(
                definition,
                client=http,
                now=checked_at,
                today=current_date,
            )
            store.commit_source(name, observed, refreshed_at=checked_at)
            results[name] = {
                "status": "updated",
                "activeCount": len(observed),
                "error": None,
            }
        except (CampusError, OSError, ValueError) as exc:
            results[name] = {
                "status": "failed",
                "activeCount": 0,
                "error": str(exc),
            }

    return {
        "source": "ustc_campus_catalog",
        "refreshedAt": checked_at.isoformat(),
        "sources": results,
        "metadata": {
            "updated": sum(item["status"] == "updated" for item in results.values()),
            "skipped": sum(item["status"] == "skipped" for item in results.values()),
            "failed": sum(item["status"] == "failed" for item in results.values()),
        },
    }


def search_catalog(
    query: str,
    filters: dict[str, str] | None = None,
    limit: int = 20,
    *,
    catalog_path: Path = DEFAULT_CATALOG_PATH,
) -> dict[str, Any]:
    results = CatalogStore(Path(catalog_path)).search(
        query,
        filters=filters,
        limit=limit,
    )
    return {
        "source": "ustc_campus_catalog",
        "query": query,
        "results": results,
        "metadata": {"resultCount": len(results)},
    }


def _default_reader(
    *,
    catalog_path: Path,
    cache_dir: Path,
    client: CampusHttpClient | None,
    now: datetime | None,
) -> DetailReader:
    return DetailReader(
        store=CatalogStore(Path(catalog_path)),
        client=client or CampusHttpClient(),
        cache_dir=Path(cache_dir),
        now=(lambda: now) if now is not None else None,
    )


def read_detail(
    entry_id: str,
    allow_stale: bool = True,
    follow_link_ids: Iterable[str] = (),
    *,
    catalog_path: Path = DEFAULT_CATALOG_PATH,
    cache_dir: Path = DEFAULT_CACHE_DIR,
    client: CampusHttpClient | None = None,
    timeout_seconds: float = 20,
    now: datetime | None = None,
    reader: DetailReader | None = None,
) -> dict[str, Any]:
    active_reader = reader or _default_reader(
        catalog_path=catalog_path,
        cache_dir=cache_dir,
        client=client or CampusHttpClient(timeout_seconds=timeout_seconds),
        now=now,
    )
    return active_reader.read_detail(
        entry_id,
        allow_stale=allow_stale,
        follow_link_ids=follow_link_ids,
    )


def read_attachment(
    item_id: str,
    attachment_id: str,
    *,
    catalog_path: Path = DEFAULT_CATALOG_PATH,
    cache_dir: Path = DEFAULT_CACHE_DIR,
    client: CampusHttpClient | None = None,
    timeout_seconds: float = 20,
    reader: DetailReader | None = None,
) -> dict[str, Any]:
    active_reader = reader or _default_reader(
        catalog_path=catalog_path,
        cache_dir=cache_dir,
        client=client or CampusHttpClient(timeout_seconds=timeout_seconds),
        now=None,
    )
    return active_reader.read_attachment(item_id, attachment_id)
