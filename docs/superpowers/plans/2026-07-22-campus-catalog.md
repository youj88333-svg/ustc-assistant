# Campus Catalog Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a local public-campus catalog index with seven-day notice windows, monthly guide refreshes, on-demand detail reads, 30-day stale-aware caching, and CLI commands suitable for later Agent tools.

**Architecture:** Add an isolated `sources.campus` package with immutable catalog records, atomic JSON persistence, per-site HTML adapters, a bounded public HTTP/detail reader, and a service layer shared by CLI and the future App. Catalog collection stores metadata only; detail bodies and direct attachments are fetched only through catalog identities and cached locally.

**Tech Stack:** Python 3.10+, standard library (`dataclasses`, `datetime`, `hashlib`, `json`, `tempfile`, `urllib.parse`, `zoneinfo`), `requests>=2.31,<3`, `beautifulsoup4>=4.12,<5`, `unittest`.

## Global Constraints

- Use Conda environment `ustc_assistant`; all calendar calculations use `Asia/Shanghai`.
- Notice activity window is the inclusive Beijing-date interval `[today - 6 days, today]`.
- Stable directories are due once per Beijing calendar month and also support `force=True`.
- Detail cache TTL is exactly 30 days; expired data may be returned only with `stale=true` after refresh failure.
- Do not use login state, Playwright, a browser Profile, a vector database, or a concrete LLM in this feature.
- Agent-facing reads accept catalog/item IDs, never arbitrary URLs; followed links must be directly discovered and depth is limited to one.
- Treat all remote text as untrusted data; it cannot alter tool arguments, configuration, or safety policy.
- A failed or incomplete source refresh must not replace that source's previous successful snapshot.
- Real HTML/cache output stays under ignored `tmp/`; fixtures contain only minimal public, synthetic content.
- Preserve all existing collector behavior and keep the full existing test suite passing.

---

## File Map

**Create:**

- `src/ustc_assistant/sources/campus/__init__.py`: public campus service exports.
- `src/ustc_assistant/sources/campus/catalog.py`: records, canonical IDs, atomic catalog store, lifecycle reconciliation, local search.
- `src/ustc_assistant/sources/campus/teach.py`: teach.ustc.edu.cn list/detail parsing.
- `src/ustc_assistant/sources/campus/finance.py`: finance.ustc.edu.cn list/detail parsing.
- `src/ustc_assistant/sources/campus/detail.py`: bounded HTTP, detail cache, detail/attachment reads and URL policy.
- `src/ustc_assistant/sources/campus/service.py`: five-source registry, refresh orchestration and Agent-callable functions.
- `tests/campus/__init__.py`: test package marker.
- `tests/campus/test_catalog.py`: identity, lifecycle, persistence and search tests.
- `tests/campus/test_adapters.py`: teach/finance list and detail parser tests.
- `tests/campus/test_detail.py`: network boundary and cache tests.
- `tests/campus/test_service.py`: refresh policy, partial failure and tool orchestration tests.
- `tests/fixtures/campus/teach-notice-list.html`: minimal teach notice list fixture.
- `tests/fixtures/campus/teach-service-list.html`: minimal teach guide fixture.
- `tests/fixtures/campus/teach-detail.html`: minimal teach detail and attachment fixture.
- `tests/fixtures/campus/finance-notice-list.html`: minimal finance notice fixture.
- `tests/fixtures/campus/finance-static-list.html`: minimal finance guide/public fixture.
- `tests/fixtures/campus/finance-detail.html`: minimal finance detail fixture.

**Modify:**

- `src/ustc_assistant/cli.py`: add `collect campus`, `query campus`, and `read campus` parsers/handlers.
- `tests/test_cli.py`: verify campus parser defaults and handler delegation.
- `README.md`: document the three public-campus commands and cache behavior.
- `AGENTS.md`: record the fifth read-only source and its security/lifecycle contract.
- `docs/architecture.md`: add `sources.campus` to the source/service data flow.
- `docs/data-sources/campus.md`: durable source contract and real acceptance checklist.

No dependency change is required because `requests` and `beautifulsoup4` are already declared in `pyproject.toml`.

---

### Task 1: Catalog Records, Atomic Store, Lifecycle, and Search

**Files:**
- Create: `src/ustc_assistant/sources/campus/__init__.py`
- Create: `src/ustc_assistant/sources/campus/catalog.py`
- Create: `tests/campus/__init__.py`
- Create: `tests/campus/test_catalog.py`

**Interfaces:**
- Produces: `CampusError`, `CatalogStoreError`, `CatalogEntry`, `CatalogStore`, `canonicalize_url(url)`, `entry_id(source, url)`, `notice_cutoff(today)`, and `is_monthly_refresh_due(last_successful_at, now)`.
- `CatalogStore.commit_source(source, observed, refreshed_at)` atomically reconciles one complete source snapshot.
- `CatalogStore.search(query, filters=None, limit=20)` never accesses the network and returns serializable dictionaries.

- [ ] **Step 1: Write failing identity and policy tests**

Create `tests/campus/__init__.py` empty, then create `tests/campus/test_catalog.py` with these first tests:

```python
import tempfile
import unittest
from datetime import date, datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from ustc_assistant.sources.campus.catalog import (
    CatalogEntry,
    CatalogStore,
    canonicalize_url,
    entry_id,
    is_monthly_refresh_due,
    notice_cutoff,
)

BEIJING = ZoneInfo("Asia/Shanghai")
NOW = datetime(2026, 7, 22, 12, 0, tzinfo=BEIJING)


class CatalogPolicyTests(unittest.TestCase):
    def test_url_identity_drops_fragment_and_tracking_query(self):
        url = "https://www.teach.ustc.edu.cn/notice/1.html?utm_source=x#part"
        self.assertEqual(
            "https://www.teach.ustc.edu.cn/notice/1.html",
            canonicalize_url(url),
        )
        self.assertEqual(entry_id("teach_notice", url), entry_id("teach_notice", canonicalize_url(url)))

    def test_notice_window_contains_seven_beijing_calendar_dates(self):
        self.assertEqual(date(2026, 7, 16), notice_cutoff(date(2026, 7, 22)))

    def test_monthly_source_is_due_only_when_beijing_month_changes(self):
        self.assertFalse(is_monthly_refresh_due(datetime(2026, 7, 1, tzinfo=BEIJING), NOW))
        self.assertTrue(is_monthly_refresh_due(datetime(2026, 6, 30, 23, 59, tzinfo=BEIJING), NOW))
        self.assertTrue(is_monthly_refresh_due(None, NOW))
```

- [ ] **Step 2: Run the tests and verify the module is missing**

Run:

```powershell
conda run -n ustc_assistant python -m unittest tests.campus.test_catalog.CatalogPolicyTests -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'ustc_assistant.sources.campus'`.

- [ ] **Step 3: Implement immutable records and date/identity helpers**

Create `src/ustc_assistant/sources/campus/__init__.py` and implement in `catalog.py`:

```python
from __future__ import annotations

import hashlib
from dataclasses import asdict, dataclass, replace
from datetime import date, datetime, timedelta
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from zoneinfo import ZoneInfo

BEIJING_TZ = ZoneInfo("Asia/Shanghai")
TRACKING_KEYS = {"from", "spm", "utm_campaign", "utm_medium", "utm_source"}


class CampusError(RuntimeError):
    """A safe-to-display campus public-source failure."""


class CatalogStoreError(CampusError):
    """The local catalog could not be read or committed safely."""


def canonicalize_url(url: str) -> str:
    split = urlsplit(url.strip())
    query = urlencode(sorted((k, v) for k, v in parse_qsl(split.query) if k not in TRACKING_KEYS))
    path = split.path or "/"
    return urlunsplit(((split.scheme or "https").lower(), split.netloc.lower(), path, query, ""))


def entry_id(source: str, url: str) -> str:
    digest = hashlib.sha256(f"{source}\0{canonicalize_url(url)}".encode("utf-8")).hexdigest()[:24]
    return f"campus_{digest}"


def notice_cutoff(today: date) -> date:
    return today - timedelta(days=6)


def is_monthly_refresh_due(last_successful_at: datetime | None, now: datetime) -> bool:
    if last_successful_at is None:
        return True
    previous = last_successful_at.astimezone(BEIJING_TZ)
    current = now.astimezone(BEIJING_TZ)
    return (previous.year, previous.month) != (current.year, current.month)


@dataclass(frozen=True)
class CatalogEntry:
    id: str
    source: str
    kind: str
    title: str
    category: str | None
    published_at: str | None
    detail_url: str
    discovered_at: str
    last_seen_at: str
    status: str = "active"

    def to_dict(self) -> dict[str, str | None]:
        raw = asdict(self)
        return {
            "id": raw["id"], "source": raw["source"], "kind": raw["kind"],
            "title": raw["title"], "category": raw["category"],
            "publishedAt": raw["published_at"], "detailUrl": raw["detail_url"],
            "discoveredAt": raw["discovered_at"], "lastSeenAt": raw["last_seen_at"],
            "status": raw["status"],
        }
```

- [ ] **Step 4: Run policy tests and verify they pass**

Run the command from Step 2. Expected: 3 tests PASS.

- [ ] **Step 5: Add failing lifecycle, persistence, and local-search tests**

Append `CatalogStoreTests` methods named `test_missing_notice_is_archived`, `test_missing_guide_is_unavailable`, `test_rediscovery_preserves_discovered_at`, and `test_search_ranks_active_title_match_first`. Each test uses a separate `TemporaryDirectory`, constructs `CatalogStore(root / "catalog.json")`, commits at `NOW`, then reloads the JSON from disk before asserting so in-memory-only behavior cannot pass.

Use this helper so every field is explicit:

```python
def make_entry(source="teach_notice", kind="notice", title="缓考通知", url="https://example.test/1"):
    stamp = NOW.isoformat()
    return CatalogEntry(
        id=entry_id(source, url), source=source, kind=kind, title=title,
        category="考试", published_at="2026-07-22", detail_url=url,
        discovered_at=stamp, last_seen_at=stamp,
    )
```

- [ ] **Step 6: Run lifecycle tests and verify `CatalogStore` is missing**

Run:

```powershell
conda run -n ustc_assistant python -m unittest tests.campus.test_catalog -v
```

Expected: policy tests PASS and store tests FAIL because `CatalogStore` is not implemented.

- [ ] **Step 7: Implement `CatalogStore` with atomic whole-file replacement**

Use schema:

```json
{"schemaVersion":"1.0","sources":{"teach_notice":{"lastSuccessfulAt":"2026-07-22T12:00:00+08:00","entries":[]}}}
```

Implement `load()`, `_write(payload)` using `tempfile.mkstemp` plus `os.replace`, `last_successful_at(source)`, `commit_source(source, observed, refreshed_at)`, `get(entry_id)`, and `search(query, filters=None, limit=20)`. `filters` accepts only `source`, `kind`, and `status`; unknown keys raise `ValueError`. During reconciliation, missing `kind == "notice"` entries become `archived`; all other missing entries become `unavailable`. Reject malformed schema with `CatalogStoreError` instead of silently overwriting it. Search normalized lower-case title/category/source text, rank exact title substring first, then active status, then descending `publishedAt`, and enforce `1 <= limit <= 100`.

- [ ] **Step 8: Run catalog tests and the existing suite**

Run:

```powershell
conda run -n ustc_assistant python -m unittest tests.campus.test_catalog -v
conda run -n ustc_assistant python -m unittest discover -s tests -v
```

Expected: all new catalog tests PASS; existing 107 tests remain PASS.

- [ ] **Step 9: Commit Task 1**

```powershell
git add src/ustc_assistant/sources/campus tests/campus
git commit -m "feat: add campus catalog store"
```

---

### Task 2: Teach and Finance Directory Adapters

**Files:**
- Create: `src/ustc_assistant/sources/campus/teach.py`
- Create: `src/ustc_assistant/sources/campus/finance.py`
- Create: `tests/campus/test_adapters.py`
- Create: `tests/fixtures/campus/teach-notice-list.html`
- Create: `tests/fixtures/campus/teach-service-list.html`
- Create: `tests/fixtures/campus/teach-detail.html`
- Create: `tests/fixtures/campus/finance-notice-list.html`
- Create: `tests/fixtures/campus/finance-static-list.html`
- Create: `tests/fixtures/campus/finance-detail.html`

**Interfaces:**
- Consumes: `CatalogEntry`, `entry_id`, `canonicalize_url` from Task 1.
- Produces: `ParsedCatalogPage(entries, next_url)`, `parse_teach_catalog(html, *, source, kind, base_url, observed_at)`, `parse_finance_catalog(html, *, source, kind, base_url, observed_at)`, `parse_teach_detail(html, url)`, and `parse_finance_detail(html, url)`.

- [ ] **Step 1: Create minimal public-shape fixtures**

Fixtures must contain only synthetic text. Include these structures:

```html
<!-- teach-notice-list.html -->
<main><article><a href="/notice/notice-teaching/100.html">秋季选课通知</a><time>2026-07-22</time></article>
<article><a href="/notice/notice-exam/99.html">考试安排通知</a><time>2026-07-15</time></article></main>
<a class="next page-numbers" href="/category/notice/page/2">下一页</a>
```

```html
<!-- finance-notice-list.html -->
<div class="news_list"><ul><li><a href="/2026/0722/c21813a1/page.htm" title="缴费通知">缴费通知</a><span>2026-07-22</span></li></ul></div>
<a class="next" href="/tzgg/list2.htm">下一页</a>
```

Teach/finance detail fixtures must include a heading, publication date, main-content container, one image, one direct PDF attachment, one ordinary internal link, and one explicit external “详情见” link.

- [ ] **Step 2: Write failing adapter tests**

In `tests/campus/test_adapters.py`, assert:

```python
page = teach.parse_teach_catalog(html, source="teach_notice", kind="notice", base_url=URL, observed_at=NOW)
self.assertEqual(["秋季选课通知", "考试安排通知"], [item.title for item in page.entries])
self.assertEqual("2026-07-22", page.entries[0].published_at)
self.assertEqual("https://www.teach.ustc.edu.cn/category/notice/page/2", page.next_url)
```

Add equivalent finance assertions. Add drift tests where list HTML has no recognized entries and assert `CampusParseError`; allow a legitimate empty page only when an explicit empty-state marker configured by that adapter is present.

- [ ] **Step 3: Run adapter tests and verify imports fail**

```powershell
conda run -n ustc_assistant python -m unittest tests.campus.test_adapters -v
```

Expected: FAIL because `teach.py` and `finance.py` do not exist.

- [ ] **Step 4: Implement list parsers with site-owned selectors**

Define in each adapter:

```python
@dataclass(frozen=True)
class ParsedCatalogPage:
    entries: tuple[CatalogEntry, ...]
    next_url: str | None
```

Use BeautifulSoup selectors owned by the adapter, `urljoin(base_url, href)`, strict `YYYY-MM-DD` date normalization, whitespace collapse, and stable IDs. Teach accepts links under `/notice/` or `/service/`; finance accepts detail links ending `/page.htm`. `CampusParseError` subclasses Task 1's `CampusError`. Do not place these selectors in `service.py`.

- [ ] **Step 5: Run adapter tests and verify list parsing passes**

Run Step 3. Expected: all list and drift tests PASS.

- [ ] **Step 6: Add and pass detail-parser tests**

Define a shared serializable parser result shape:

```python
{
  "title": "缓考办理说明", "content": "申请人应在规定时间提交材料。", "publishedAt": "2026-07-22",
  "url": "https://www.teach.ustc.edu.cn/service/svc-student/100.html", "category": "考试",
  "attachments": [{"id": "attachment_01", "label": "申请表", "url": "https://www.teach.ustc.edu.cn/files/form.pdf", "mediaType": "application/pdf"}],
  "images": [{"url": "https://www.teach.ustc.edu.cn/files/flow.png", "alt": "办理流程"}],
  "candidateLinks": [{"id": "link_01", "url": "https://example.edu/rules", "label": "具体办法", "reason": "explicit-reference"}]
}
```

Strip navigation, footer, print/share controls, scripts and styles. Include a candidate ordinary link only when nearby anchor text matches `详情见|具体办法|点击查看|参见`; attachments are identified from file extensions `pdf|doc|docx|xls|xlsx|png|jpg|jpeg`. Raise `CampusParseError` when title or content container is missing, and never return page navigation as content.

- [ ] **Step 7: Run adapter tests and the full suite**

```powershell
conda run -n ustc_assistant python -m unittest tests.campus.test_adapters -v
conda run -n ustc_assistant python -m unittest discover -s tests -v
```

Expected: all tests PASS.

- [ ] **Step 8: Commit Task 2**

```powershell
git add src/ustc_assistant/sources/campus tests/campus tests/fixtures/campus
git commit -m "feat: parse campus public directories"
```

---

### Task 3: Bounded HTTP, Detail Cache, and Controlled Reads

**Files:**
- Create: `src/ustc_assistant/sources/campus/detail.py`
- Create: `tests/campus/test_detail.py`

**Interfaces:**
- Consumes: adapter detail parsers and `CatalogStore.get(entry_id)`.
- Produces: `CampusHttpClient.get_text(url, *, discovered_child=False)`, `DetailCache.get_or_fetch(item_id, fetch, *, now, allow_stale)`, `DetailReader.read_detail(entry_id, allow_stale=True, follow_link_ids=())`, and `DetailReader.read_attachment(item_id, attachment_id)`.

- [ ] **Step 1: Write failing URL-policy and bounded-response tests**

Use fake sessions/responses and assert:

```python
client = CampusHttpClient(session=fake, timeout_seconds=10, max_response_bytes=1024)
self.assertRaises(UnsafeCampusUrl, client.get_text, "http://127.0.0.1/private")
self.assertRaises(UnsafeCampusUrl, client.get_text, "https://user:pass@example.com/x")
self.assertRaises(CampusNetworkError, client.get_text, allowed_url_with_2048_byte_body)
```

Configured catalog/detail hosts are `teach.ustc.edu.cn` and `finance.ustc.edu.cn`. A discovered child URL may use HTTPS on another public hostname, but reject credentials, localhost, `.local`, and private/loopback/link-local IP literals. `UnsafeCampusUrl` and `CampusNetworkError` subclass Task 1's `CampusError`. HTTP errors expose only status and host, never query strings or response bodies.

- [ ] **Step 2: Run detail tests and verify the module is missing**

```powershell
conda run -n ustc_assistant python -m unittest tests.campus.test_detail -v
```

Expected: FAIL because `detail.py` does not exist.

- [ ] **Step 3: Implement bounded HTTP and URL validation**

Implement `CampusHttpClient` with a fixed User-Agent, `requests.Session`, explicit timeout, no cookies, streamed reads, byte-limit enforcement from both `Content-Length` and accumulated chunks, and UTF-8/apparent-encoding text decoding. Set `allow_redirects=True`, then validate `response.url` again so redirects cannot escape policy.

- [ ] **Step 4: Add failing 30-day cache tests**

Use exact boundary checks:

```python
cache.store(item_id, payload, fetched_at=NOW - timedelta(days=30))
result = cache.get_or_fetch(item_id, fetch, now=NOW, allow_stale=True)
self.assertEqual([True], fetch_calls)  # exactly 30 days is expired
```

Also assert fresh cache performs no fetch, network failure returns old content with `stale=True`, `allow_stale=False` re-raises, parse failure does not overwrite old cache, schema mismatch is ignored, and successful replacement uses `os.replace`.

- [ ] **Step 5: Implement `DetailCache` and pass cache tests**

Use one JSON file per item ID under `tmp/campus-cache/details`, with schema version, `fetchedAt`, and parsed data. Reuse the atomic tempfile pattern from the catalog store; do not share iCourse cache classes because URL identity and payload contracts differ.

- [ ] **Step 6: Add failing controlled-reader tests**

Construct a temporary `CatalogStore` containing one entry and assert:

- unknown `entry_id` fails before any network call;
- `read_detail` selects parser by `entry.source`, adds `catalogEntryId`, `contentHash`, `fetchedAt`, `stale`, and stable attachment IDs;
- attachment IDs not present in the cached item are rejected;
- `read_attachment` only downloads a directly recorded URL and writes binary payload under `tmp/campus-cache/attachments` using a hash filename;
- each explicit `candidateLink` has a stable ID; `follow_link_ids` accepts only IDs from the cached parent item, can follow only depth `0 -> 1`, and a followed page cannot authorize depth 2;
- remote text containing `ignore previous instructions` remains ordinary `content` and cannot change any reader option.

- [ ] **Step 7: Implement `DetailReader` and attachment descriptors**

`read_attachment` returns JSON metadata:

```python
{
  "itemId": item_id, "attachmentId": attachment_id, "url": url,
  "mediaType": content_type, "sizeBytes": size, "sha256": digest,
  "localPath": str(path), "extractedText": text_or_none,
  "conversionStatus": "text-extracted" or "binary-saved"
}
```

Extract text only for `text/*` and HTML in this task. PDF, Word, Excel and images are saved as bounded binary files with `conversionStatus="binary-saved"`; later document conversion consumes this descriptor without changing the Agent URL boundary.

- [ ] **Step 8: Run detail and full tests**

```powershell
conda run -n ustc_assistant python -m unittest tests.campus.test_detail -v
conda run -n ustc_assistant python -m unittest discover -s tests -v
```

Expected: all tests PASS and no network is accessed.

- [ ] **Step 9: Commit Task 3**

```powershell
git add src/ustc_assistant/sources/campus/detail.py tests/campus/test_detail.py
git commit -m "feat: add bounded campus detail reader"
```

---

### Task 4: Five-Source Refresh and Agent-Callable Service

**Files:**
- Create: `src/ustc_assistant/sources/campus/service.py`
- Create: `tests/campus/test_service.py`
- Modify: `src/ustc_assistant/sources/campus/__init__.py`

**Interfaces:**
- Consumes: store, adapters, HTTP client and detail reader from Tasks 1-3.
- Produces the spec signatures: `refresh_catalogs(sources=None, force=False, *, catalog_path=DEFAULT_CATALOG_PATH, client=None, now=None, today=None)`, `search_catalog(query, filters=None, limit=20, *, catalog_path=DEFAULT_CATALOG_PATH)`, `read_detail(entry_id, allow_stale=True, follow_link_ids=(), *, catalog_path=DEFAULT_CATALOG_PATH, cache_dir=DEFAULT_CACHE_DIR, client=None, now=None)`, and `read_attachment(item_id, attachment_id, *, catalog_path=DEFAULT_CATALOG_PATH, cache_dir=DEFAULT_CACHE_DIR, client=None)`.

- [ ] **Step 1: Write failing source-registry and refresh-policy tests**

Assert the registry contains exactly:

```python
{
  "teach_notice", "teach_student_service", "finance_notice",
  "finance_public_information", "finance_business_guide",
}
```

Use a fake HTTP client returning page fixtures. For notice sources, assert pages are followed until the oldest parsed date is before `notice_cutoff(today)` and old incoming entries are excluded. For monthly sources, assert same-month collection returns `status="skipped"` without HTTP unless `force=True`.

- [ ] **Step 2: Run service tests and verify imports fail**

```powershell
conda run -n ustc_assistant python -m unittest tests.campus.test_service -v
```

Expected: FAIL because `service.py` does not exist.

- [ ] **Step 3: Implement source definitions and refresh traversal**

Define immutable `SourceDefinition(name, url, kind, cadence, parser)`. `refresh_catalogs` accepts injectable `store`, `client`, `now`, and `today` for tests. Return:

```python
{
  "source": "ustc_campus_catalog", "refreshedAt": now.isoformat(),
  "sources": {
    name: {"status": "updated|skipped|failed", "activeCount": n, "error": safe_message_or_none}
  },
  "metadata": {"updated": n, "skipped": n, "failed": n}
}
```

Collect all pages into memory before `commit_source`. Catch only classified network/parse/store errors per source, continue other sources, and never commit a failed source.

- [ ] **Step 4: Add partial-failure and integrity tests**

Prepopulate two sources, make one parser fail on page 2, and assert its old snapshot is byte-for-byte unchanged while the other source commits. Add loop detection for repeated `next_url`, a maximum of 100 pages per source, duplicate URL collapse, and future publication-date rejection beyond `today + 1 day`.

- [ ] **Step 5: Implement service wrappers and exports**

The wrappers construct default paths only at call time:

```python
DEFAULT_CATALOG_PATH = Path("tmp/campus-catalog.json")
DEFAULT_CACHE_DIR = Path("tmp/campus-cache")
```

Export `CampusError`, `refresh_catalogs`, `search_catalog`, `read_detail`, and `read_attachment` from `sources/campus/__init__.py`. Keep `search_catalog` entirely local.

`search_catalog` returns this stable envelope:

```python
results = store.search(query, filters=filters, limit=limit)
return {
    "source": "ustc_campus_catalog",
    "query": query,
    "results": results,
    "metadata": {"resultCount": len(results)},
}
```

- [ ] **Step 6: Run service and full tests**

```powershell
conda run -n ustc_assistant python -m unittest tests.campus.test_service -v
conda run -n ustc_assistant python -m unittest discover -s tests -v
```

Expected: all tests PASS.

- [ ] **Step 7: Commit Task 4**

```powershell
git add src/ustc_assistant/sources/campus tests/campus/test_service.py
git commit -m "feat: orchestrate campus catalog sources"
```

---

### Task 5: Unified CLI Commands

**Files:**
- Modify: `src/ustc_assistant/cli.py`
- Modify: `tests/test_cli.py`

**Interfaces:**
- Consumes: Task 4 service functions.
- Produces: `collect campus`, `query campus`, and top-level `read campus` commands.

- [ ] **Step 1: Write failing parser tests**

Add assertions for these defaults:

```python
collect = parser.parse_args(["collect", "campus"])
self.assertEqual(Path("tmp/campus-catalog.json"), collect.catalog_path)
self.assertFalse(collect.force)

query = parser.parse_args(["query", "campus", "--text", "缓考"])
self.assertEqual(20, query.limit)
self.assertEqual(Path("tmp/campus-query.generated.json"), query.output)

read = parser.parse_args(["read", "campus", "--entry-id", "campus_abc"])
self.assertTrue(read.allow_stale)
self.assertEqual(Path("tmp/campus-detail.generated.json"), read.output)
```

Also test repeated `--source`, `--force`, `--follow-link-id`, `--no-stale`, `--cache-dir`, and `--timeout-seconds` parsing. `--follow-link-id` defaults to an empty list and is forwarded unchanged to `read_detail`.

- [ ] **Step 2: Run CLI tests and verify parsing fails**

```powershell
conda run -n ustc_assistant python -m unittest tests.test_cli -v
```

Expected: FAIL because campus subcommands are absent.

- [ ] **Step 3: Add parsers and handler delegation**

Import `from ustc_assistant.sources import campus`. Handlers call exactly one package-exported service function, write its serializable result with `dump_json`, and report only counts/path. `collect campus` returns exit code 1 when any source has `failed`, while still writing the summary so the successful/failed split is inspectable. `query campus` never constructs an HTTP client. `read campus` passes `allow_stale`, `follow_link_ids`, and cache options. Extend `main()`'s classified exception tuple with `campus.CampusError` so query/read failures produce a safe `Operation failed: campus detail was unavailable` message without a traceback.

- [ ] **Step 4: Add handler tests with patched service functions**

Assert output JSON equals the fake service payload, statuses do not contain detail body text, a partial collect returns 1, an empty query returns 0 with `resultCount=0`, and errors are handled by the existing `main()` boundary without a traceback.

- [ ] **Step 5: Run CLI and full tests**

```powershell
conda run -n ustc_assistant python -m unittest tests.test_cli -v
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
```

Expected: all tests PASS; compileall exits 0 with no output.

- [ ] **Step 6: Commit Task 5**

```powershell
git add src/ustc_assistant/cli.py tests/test_cli.py
git commit -m "feat: expose campus catalog commands"
```

---

### Task 6: Durable Documentation and Public-Site Acceptance

**Files:**
- Create: `docs/data-sources/campus.md`
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `docs/architecture.md`

**Interfaces:**
- Documents the stable service/CLI contract implemented in Tasks 1-5.
- Produces reproducible acceptance evidence without committing remote HTML or cache data.

- [ ] **Step 1: Document commands and privacy behavior**

Add the three CLI commands, defaults, seven-day/monthly policies, 30-day stale cache, public-only nature, and the statement that `query campus` is offline. In `docs/data-sources/campus.md`, list all five source URLs, parser ownership, tool boundaries, and the exact output paths:

```text
tmp/campus-catalog.json
tmp/campus-query.generated.json
tmp/campus-detail.generated.json
tmp/campus-cache/
```

- [ ] **Step 2: Update architecture and Agent guidance**

Add `sources.campus` as the fifth read-only source. Record that remote page text is untrusted, arbitrary URL reads are forbidden, detail selection is Agent-controlled in batches of at most 3, and binary attachment conversion remains a separate layer.

- [ ] **Step 3: Run static and full automated verification**

```powershell
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
git diff --check
```

Expected: all tests PASS, compileall exits 0, and `git diff --check` prints nothing.

- [ ] **Step 4: Run public catalog acceptance**

With network permission, run:

```powershell
conda run -n ustc_assistant python -m ustc_assistant collect campus --force
conda run -n ustc_assistant python -m ustc_assistant query campus --text "选课"
```

Expected: five source result rows; each successful source has a non-negative count; notice entries are dated within `[today - 6 days, today]`; query output is created without another network request.

- [ ] **Step 5: Read a small public sample and inspect boundaries**

Choose the first returned ID without manually copying it, then run:

```powershell
$entryId = (Get-Content -Raw -Encoding UTF8 tmp/campus-query.generated.json | ConvertFrom-Json).results[0].id
conda run -n ustc_assistant python -m ustc_assistant read campus --entry-id $entryId
```

Expected: output contains title, content, original URL, `fetchedAt`, `stale=false`, and attachment descriptors when present. It contains no Cookie, Authorization header, browser Profile path, or page navigation text. Do not print the full body in the terminal summary.

- [ ] **Step 6: Verify refresh and cache behavior without long waits**

Rerun the same `read campus` command and verify `fetchedAt` is unchanged, proving a fresh cache hit. Rerun `collect campus` without `--force` and verify monthly sources report `skipped` while notice sources refresh.

- [ ] **Step 7: Record aggregate acceptance only**

In `AGENTS.md`, append the acceptance date, per-source counts, one successful detail/cache check, and any source explicitly marked failed. Do not include titles, body excerpts, attachment names, URLs with query strings, or raw HTML.

- [ ] **Step 8: Commit Task 6**

```powershell
git add README.md AGENTS.md docs/architecture.md docs/data-sources/campus.md
git commit -m "docs: add campus catalog source contract"
```

---

## Final Verification

- [ ] Run the complete suite and syntax checks from a clean working tree:

```powershell
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
git diff --check
git status --short --branch
```

Expected: all tests PASS, compileall and diff check have no output, and the working tree is clean.

- [ ] Inspect the branch history:

```powershell
git log --oneline --decorate -8
```

Expected: six focused implementation commits after the design/plan commits, with no `tmp/`, raw HTML, real cache, credentials, tokens, or browser Profile files tracked.
