# Bridge 自动刷新校园目录实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **状态（2026-07-31）：** 本计划已实现并合并到 `main`（`860892c`、`53c16eb`，
> 合并 `9bc83c8`）。Bridge 在 `campus_search` 查询时按节流/缺失/过期自动刷新
> 校园目录，失败时降级用旧数据或返回 `catalog_unavailable`。下文复选框是历史
> 实施步骤，不是实时进度；当前状态见 `docs/read-only-agent-handoff.md`。

**Goal:** 让 Bridge 在 `campus_search` 查询时，若 catalog 缺失或过期则自动 `refresh_catalogs` 后再查，失败降级用旧数据，使 Agent 不再依赖外部 CLI 手动生成 catalog。

**Architecture:** 在 `_run_campus_search` 调 `search_catalog` 前插入 `_ensure_catalog_fresh` 编排步骤。通过依赖注入（`refresh_fn` / `catalog_path_fn` / `now_fn`）保持单测不联网。节流与过期判定基于进程内时间戳与 catalog 的 `lastSuccessfulAt`。

**Tech Stack:** Python 3.10，`ustc_assistant.bridge.query_jobs`，`unittest`，conda `ustc_assistant` 环境。

## Global Constraints

- 仅改 `src/ustc_assistant/bridge/query_jobs.py` 与 `tests/bridge/test_query_jobs.py`。**不改** `service.py`、`catalog.py`、Dart 侧任何文件。
- 单测**不联网、不碰真实 `tmp/campus-catalog.json`**：所有 refresh / catalog 路径 / 当前时间通过依赖注入 mock。
- 现有 campus search 单测（`test_campus_search_wraps_raw_dict_into_envelope`、`test_campus_search_never_receives_credentials`、`test_campus_search_declares_trusted_url_embedded_in_result_text`、`test_campus_search_keeps_canonical_catalog_id`、`test_campus_search_production_wrapper_matches_canonical_fixture`）必须在改动后仍不联网通过——必要时补注入 no-op `campus_refresh_fn`。
- 错误细节不泄漏：`catalog_unavailable` 错误码不含异常 traceback / 响应体 / Cookie。
- catalog 路径与 refresh / search 必须一致（同一 `catalog_path`），避免 refresh 写 A 文件、search 读 B 文件。
- 不引入后台定时调度；refresh 只在 search 触发时按需发生。
- 测试用 `unittest`，与现有 `tests/bridge/test_query_jobs.py` 风格一致。
- conda 环境 `ustc_assistant`；禁止 pip 改环境。
- 提交信息用 `feat:` / `test:` / `fix:` 前缀，遵循仓库现有风格。

---

## 文件结构

- `src/ustc_assistant/bridge/query_jobs.py`（修改）
  - 新增模块常量：`REFRESH_MIN_INTERVAL`（`timedelta(minutes=30)`）、`CATALOG_STALE_AFTER`（`timedelta(hours=6)`）、进程变量 `_last_campus_refresh_attempt: datetime | None = None`、错误码字符串 `CATALOG_UNAVAILABLE = "catalog_unavailable"`。
  - 新增辅助 `_ensure_catalog_fresh(refresh_fn, catalog_path, now_fn) -> None`：判定 + 调 refresh + 失败降级。
  - 修改 `_run_campus_search`：签名增加 `refresh_fn`、`catalog_path_fn`、`now_fn` 参数；在调 `query_fn` 前调 `_ensure_catalog_fresh`。
  - 修改 `ReadQueryJobManager.__init__`：增加 `campus_refresh_fn`、`campus_catalog_path_fn`、`campus_now_fn` 注入字段。
  - 新增 `_resolve_campus_refresh` / `_resolve_campus_catalog_path` / `_resolve_campus_now` 懒解析方法（默认解析到 `service.refresh_catalogs` / `service.DEFAULT_CATALOG_PATH` / `lambda: datetime.now(BEIJING_TZ)`）。
  - 修改 `start_campus_search`：增加同名注入参数，透传给 runner。
- `tests/bridge/test_query_jobs.py`（修改）
  - 现有 campus search 用例补注入 no-op `campus_refresh_fn`（避免联网）。
  - 新增 `CampusSearchAutoRefreshTests` 测试类，覆盖 6 个分支。

---

### Task 1: `_ensure_catalog_fresh` 辅助函数 + 依赖注入骨架

**Files:**
- Modify: `src/ustc_assistant/bridge/query_jobs.py`
- Test: `tests/bridge/test_query_jobs.py`

**Interfaces:**
- Consumes: `ustc_assistant.sources.campus.service.refresh_catalogs`、`service.DEFAULT_CATALOG_PATH`、`catalog.CatalogStore`、`catalog.BEIJING_TZ`。
- Produces:
  - 模块常量 `REFRESH_MIN_INTERVAL: timedelta`、`CATALOG_STALE_AFTER: timedelta`、`CATALOG_UNAVAILABLE: str`、`_last_campus_refresh_attempt: datetime | None`。
  - `_ensure_catalog_fresh(*, refresh_fn: Callable[..., dict], catalog_path: Path, now_fn: Callable[[], datetime]) -> None`。行为：判定是否需要 refresh（节流 / 缺失 / 过期），需要则调 `refresh_fn(catalog_path=catalog_path, force=False)` 并更新 `_last_campus_refresh_attempt`；refresh 抛异常时，若 catalog 文件不存在则 `raise CampusUnavailable`（携带 `CATALOG_UNAVAILABLE` 码），若存在则吞掉（降级）。
  - 异常类 `CampusUnavailable(RuntimeError)`，`code` 属性 = `CATALOG_UNAVAILABLE`。
  - `ReadQueryJobManager.__init__` 新增可选参数 `campus_refresh_fn`、`campus_catalog_path_fn`、`campus_now_fn`，存为实例字段。
  - `_resolve_campus_refresh` / `_resolve_campus_catalog_path` / `_resolve_campus_now` 方法：注入非空则返回注入值，否则懒解析默认。
  - `start_campus_search` 新增 `refresh_fn` / `catalog_path_fn` / `now_fn` 可选参数，透传给 `_run_campus_search`。
  - `_run_campus_search` 签名增加 `refresh_fn` / `catalog_path_fn` / `now_fn`，在调 `query_fn` 前调 `_ensure_catalog_fresh`。

- [ ] **Step 1: 写失败测试 — catalog 缺失时 refresh 被调**

在 `tests/bridge/test_query_jobs.py` 末尾新增 `CampusSearchAutoRefreshTests(unittest.TestCase)`，第一个用例：

```python
class CampusSearchAutoRefreshTests(unittest.TestCase):
    def test_refresh_invoked_when_catalog_missing(self):
        import tempfile
        from ustc_assistant.bridge import query_jobs as qj

        tmp_dir = Path(tempfile.mkdtemp(prefix="campus-refresh-"))
        catalog_path = tmp_dir / "campus-catalog.json"  # 不存在
        refresh_calls = []

        def refresh_fn(*, catalog_path, force):
            refresh_calls.append(catalog_path)
            # 模拟 refresh 写出 catalog 文件
            catalog_path.parent.mkdir(parents=True, exist_ok=True)
            catalog_path.write_text(
                json.dumps({"schemaVersion": "1.0", "sources": {}}),
                encoding="utf-8",
            )
            return {"sources": {}}

        def search_fn(*, query, filters, limit):
            return {"source": "ustc_campus_catalog", "query": query,
                    "results": [], "metadata": {"resultCount": 0}}

        # 重置进程级节流时间戳，避免被其他用例污染
        qj._last_campus_refresh_attempt = None
        manager = ReadQueryJobManager(
            campus_search_query=search_fn,
            campus_refresh_fn=refresh_fn,
            campus_catalog_path_fn=lambda: catalog_path,
        )
        job = manager.start_campus_search(CampusSearchQuery(query="通知"))
        self.assertEqual("complete", job.wait_for_terminal_or_pause())
        self.assertEqual(1, len(refresh_calls))
        self.assertEqual(catalog_path, refresh_calls[0])
```

- [ ] **Step 2: 运行测试验证失败**

Run: `cd E:/107/.worktrees/read-only-agent && PYTHONPATH=src E:/conda/envs/ustc_assistant/python.exe -m pytest tests/bridge/test_query_jobs.py::CampusSearchAutoRefreshTests::test_refresh_invoked_when_catalog_missing -v`
Expected: FAIL（`campus_refresh_fn` 等参数不存在 / `_ensure_catalog_fresh` 不存在）。

- [ ] **Step 3: 实现依赖注入骨架 + `_ensure_catalog_fresh`**

在 `query_jobs.py` 顶部 import 区补 `from datetime import timedelta`（`datetime` 已 import 则不重复）、`from ustc_assistant.sources.campus.catalog import BEIJING_TZ`（若已有则不重复）。

新增模块常量与异常：

```python
REFRESH_MIN_INTERVAL = timedelta(minutes=30)
CATALOG_STALE_AFTER = timedelta(hours=6)
CATALOG_UNAVAILABLE = "catalog_unavailable"

# 进程内上次 refresh 尝试时刻（不论成败）。ReadQueryJobManager 保证同一时刻
# 只有一个 active job，故无需额外加锁。
_last_campus_refresh_attempt: datetime | None = None


class CampusUnavailable(RuntimeError):
    """Catalog 既不存在且自动 refresh 也失败时抛出，携带安全错误码。"""

    def __init__(self) -> None:
        super().__init__(CATALOG_UNAVAILABLE)
        self.code = CATALOG_UNAVAILABLE
```

新增 `_ensure_catalog_fresh`：

```python
def _ensure_catalog_fresh(
    *,
    refresh_fn: Callable[..., dict[str, Any]],
    catalog_path: Path,
    now_fn: Callable[[], datetime],
) -> None:
    """若 catalog 缺失或过期，调用 refresh_fn 重建；失败时降级用旧 catalog。

    节流：距上次 refresh 尝试不足 REFRESH_MIN_INTERVAL 则跳过。过期判定取
    所有来源中最新的 lastSuccessfulAt，距今超过 CATALOG_STALE_AFTER 才 refresh。
    refresh 抛异常时，catalog 已存在则吞掉（降级），不存在则 raise CampusUnavailable。
    """
    global _last_campus_refresh_attempt
    now = now_fn()

    if (
        _last_campus_refresh_attempt is not None
        and now - _last_campus_refresh_attempt < REFRESH_MIN_INTERVAL
    ):
        return

    needs_refresh = not catalog_path.exists()
    if not needs_refresh:
        try:
            from ustc_assistant.sources.campus.catalog import CatalogStore
            store = CatalogStore(catalog_path)
            latest: datetime | None = None
            payload = store.load()
            for source in payload.get("sources", {}):
                at = store.last_successful_at(source)
                if at is not None and (latest is None or at > latest):
                    latest = at
            if latest is not None and now - latest < CATALOG_STALE_AFTER:
                return
            needs_refresh = True
        except Exception:
            # catalog 读不出，视为需要 refresh
            needs_refresh = True

    if not needs_refresh:
        return

    _last_campus_refresh_attempt = now
    try:
        refresh_fn(catalog_path=catalog_path, force=False)
    except Exception:
        if not catalog_path.exists():
            raise CampusUnavailable()
        # 旧 catalog 存在：吞掉异常，降级用旧数据
```

修改 `ReadQueryJobManager.__init__` 签名，增加三个注入字段并存储：

```python
    def __init__(
        self,
        *,
        young_enrolment_query: Callable[..., Any] | None = None,
        icourse_query: Callable[..., Any] | None = None,
        campus_search_query: Callable[..., Any] | None = None,
        campus_detail_query: Callable[..., Any] | None = None,
        campus_refresh_fn: Callable[..., Any] | None = None,
        campus_catalog_path_fn: Callable[[], Any] | None = None,
        campus_now_fn: Callable[[], datetime] | None = None,
        validator: Callable[[Mapping[str, Any]], None] = validate_query_result,
    ) -> None:
        # ... 原有字段 ...
        self._campus_refresh_fn = campus_refresh_fn
        self._campus_catalog_path_fn = campus_catalog_path_fn
        self._campus_now_fn = campus_now_fn
        self._validator = validator
        self._lock = threading.Lock()
        self._jobs: dict[str, ReadQueryJob] = {}
        self._active: ReadQueryJob | None = None
```

新增三个 `_resolve_*` 方法（紧跟现有 `_resolve_campus_detail_query` 之后）：

```python
    def _resolve_campus_refresh(self) -> Callable[..., Any]:
        if self._campus_refresh_fn is not None:
            return self._campus_refresh_fn
        from ustc_assistant.sources.campus.service import refresh_catalogs
        return refresh_catalogs

    def _resolve_campus_catalog_path(self) -> Callable[[], Any]:
        if self._campus_catalog_path_fn is not None:
            return self._campus_catalog_path_fn
        from ustc_assistant.sources.campus.service import DEFAULT_CATALOG_PATH
        return lambda: DEFAULT_CATALOG_PATH

    def _resolve_campus_now(self) -> Callable[[], datetime]:
        if self._campus_now_fn is not None:
            return self._campus_now_fn
        from ustc_assistant.sources.campus.catalog import BEIJING_TZ
        return lambda: datetime.now(BEIJING_TZ)
```

修改 `start_campus_search` 增加注入参数并解析、透传：

```python
    def start_campus_search(
        self,
        request: CampusSearchQuery,
        *,
        query_fn: Callable[..., Any] | None = None,
        refresh_fn: Callable[..., Any] | None = None,
        catalog_path_fn: Callable[[], Any] | None = None,
        now_fn: Callable[[], datetime] | None = None,
    ) -> ReadQueryJob:
        resolved = query_fn or self._resolve_campus_search_query()
        resolved_refresh = refresh_fn or self._resolve_campus_refresh()
        resolved_catalog_path = catalog_path_fn or self._resolve_campus_catalog_path()
        resolved_now = now_fn or self._resolve_campus_now()

        def runner(
            req: CampusSearchQuery,
            *,
            interactive: bool,
            credentials: Any,
            cancel_check: Callable[[], bool],
        ) -> dict[str, Any]:
            return _run_campus_search(
                req,
                interactive=interactive,
                credentials=credentials,
                cancel_check=cancel_check,
                query_fn=resolved,
                refresh_fn=resolved_refresh,
                catalog_path_fn=resolved_catalog_path,
                now_fn=resolved_now,
            )

        return self._start(
            request,
            query_type=CAMPUS_SEARCH,
            runner=runner,
            can_login=False,
        )
```

修改 `_run_campus_search` 签名与函数体，在调 `query_fn` 前调 `_ensure_catalog_fresh`：

```python
def _run_campus_search(
    request: CampusSearchQuery,
    *,
    interactive: bool,
    credentials: Any,
    cancel_check: Callable[[], bool],
    query_fn: Callable[..., Any],
    refresh_fn: Callable[..., Any],
    catalog_path_fn: Callable[[], Any],
    now_fn: Callable[[], datetime],
) -> dict[str, Any]:
    _ensure_catalog_fresh(
        refresh_fn=refresh_fn,
        catalog_path=catalog_path_fn(),
        now_fn=now_fn,
    )
    raw = query_fn(
        query=request.query,
        filters=request.filters,
        limit=request.limit,
    )
    return _wrap_campus_search(raw)
```

- [ ] **Step 4: 运行新测试验证通过**

Run: `cd E:/107/.worktrees/read-only-agent && PYTHONPATH=src E:/conda/envs/ustc_assistant/python.exe -m pytest tests/bridge/test_query_jobs.py::CampusSearchAutoRefreshTests::test_refresh_invoked_when_catalog_missing -v`
Expected: PASS。

- [ ] **Step 5: 修复现有 campus search 用例避免联网**

现有用例 `test_campus_search_wraps_raw_dict_into_envelope`、`test_campus_search_never_receives_credentials`、`test_campus_search_declares_trusted_url_embedded_in_result_text`、`test_campus_search_keeps_canonical_catalog_id`、`test_campus_search_production_wrapper_matches_canonical_fixture` 构造 `ReadQueryJobManager(campus_search_query=query_fn)` 时未注入 refresh。改动后默认 `_resolve_campus_refresh` 会解析到真实 `refresh_catalogs`，且默认 `catalog_path` 是真实 `tmp/campus-catalog.json`——若不存在会联网 refresh。

为每个用例补注入一个 no-op `campus_refresh_fn`，并指向一个临时不存在路径（确保 `_ensure_catalog_fresh` 走"catalog 不存在→调 refresh→no-op 不写文件→catalog 仍不存在→raise CampusUnavailable"——这会让 job failed，破坏用例）。

**正确做法**：补注入 no-op refresh **且** 让 `_ensure_catalog_fresh` 不 raise。最简单：注入一个写出空 catalog 的 refresh_fn，与 Task 1 Step 1 的 mock 一致。为避免每个用例重复，提取辅助：

```python
def _no_op_campus_refresh(catalog_path=None, **_):
    # 单测用：不联网，写一个空 catalog 使 _ensure_catalog_fresh 不 raise
    from pathlib import Path
    import json
    p = Path(catalog_path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps({"schemaVersion": "1.0", "sources": {}}), encoding="utf-8")
    return {"sources": {}}
```

在每个现有 campus search 用例的 `ReadQueryJobManager(campus_search_query=query_fn)` 改为 `ReadQueryJobManager(campus_search_query=query_fn, campus_refresh_fn=_no_op_campus_refresh)`，并在用例开头加 `qj._last_campus_refresh_attempt = None`（需 `from ustc_assistant.bridge import query_jobs as qj`，模块顶部已可加）。

注意 `test_campus_search_declares_trusted_url_embedded_in_result_text` 与 `test_campus_search_keeps_canonical_catalog_id` 直接调 `_wrap_campus_search(...)`（不经过 manager），无需改。

- [ ] **Step 6: 运行全部 bridge 测试验证不联网通过**

Run: `cd E:/107/.worktrees/read-only-agent && PYTHONPATH=src E:/conda/envs/ustc_assistant/python.exe -m pytest tests/bridge/test_query_jobs.py -v`
Expected: 全部 PASS，无联网（可通过断网或观察无长时间挂起确认）。

- [ ] **Step 7: 提交**

```bash
cd E:/107/.worktrees/read-only-agent
git add src/ustc_assistant/bridge/query_jobs.py tests/bridge/test_query_jobs.py
git commit -m "feat(bridge): auto-refresh campus catalog before search when missing or stale"
```

---

### Task 2: 自动 refresh 分支完整覆盖（节流 / 新鲜 / 过期 / 降级 / 失败）

**Files:**
- Test: `tests/bridge/test_query_jobs.py`（在 Task 1 的 `CampusSearchAutoRefreshTests` 类中补用例）

**Interfaces:**
- Consumes: Task 1 产出的 `_ensure_catalog_fresh`、`CampusUnavailable`、`_last_campus_refresh_attempt`、`REFRESH_MIN_INTERVAL`、`CATALOG_STALE_AFTER`。

- [ ] **Step 1: 写测试 — catalog 新鲜时 refresh 不被调**

```python
    def test_refresh_skipped_when_catalog_fresh(self):
        import tempfile
        from datetime import datetime, timedelta
        from ustc_assistant.bridge import query_jobs as qj
        from ustc_assistant.sources.campus.catalog import BEIJING_TZ

        tmp_dir = Path(tempfile.mkdtemp(prefix="campus-fresh-"))
        catalog_path = tmp_dir / "campus-catalog.json"
        now = datetime(2026, 7, 31, 12, 0, tzinfo=BEIJING_TZ)
        fresh_at = (now - timedelta(hours=1)).isoformat()
        catalog_path.write_text(
            json.dumps({
                "schemaVersion": "1.0",
                "sources": {"teach_notice": {"lastSuccessfulAt": fresh_at, "entries": []}},
            }),
            encoding="utf-8",
        )
        refresh_calls = []

        def refresh_fn(*, catalog_path, force):
            refresh_calls.append(catalog_path)
            return {"sources": {}}

        def search_fn(*, query, filters, limit):
            return {"source": "ustc_campus_catalog", "query": query,
                    "results": [], "metadata": {"resultCount": 0}}

        qj._last_campus_refresh_attempt = None
        manager = ReadQueryJobManager(
            campus_search_query=search_fn,
            campus_refresh_fn=refresh_fn,
            campus_catalog_path_fn=lambda: catalog_path,
            campus_now_fn=lambda: now,
        )
        job = manager.start_campus_search(CampusSearchQuery(query="通知"))
        self.assertEqual("complete", job.wait_for_terminal_or_pause())
        self.assertEqual(0, len(refresh_calls))
```

- [ ] **Step 2: 运行验证通过**

Run: `cd E:/107/.worktrees/read-only-agent && PYTHONPATH=src E:/conda/envs/ustc_assistant/python.exe -m pytest tests/bridge/test_query_jobs.py::CampusSearchAutoRefreshTests::test_refresh_skipped_when_catalog_fresh -v`
Expected: PASS。

- [ ] **Step 3: 写测试 — 节流窗口内 refresh 不被调（即使 catalog 缺失）**

```python
    def test_refresh_throttled_within_min_interval(self):
        import tempfile
        from datetime import datetime, timedelta
        from ustc_assistant.bridge import query_jobs as qj
        from ustc_assistant.sources.campus.catalog import BEIJING_TZ

        tmp_dir = Path(tempfile.mkdtemp(prefix="campus-throttle-"))
        catalog_path = tmp_dir / "campus-catalog.json"  # 不存在
        now = datetime(2026, 7, 31, 12, 0, tzinfo=BEIJING_TZ)
        # 模拟 5 分钟前刚 refresh 过（小于 30 分钟节流窗口）
        qj._last_campus_refresh_attempt = now - timedelta(minutes=5)

        refresh_calls = []
        def refresh_fn(*, catalog_path, force):
            refresh_calls.append(catalog_path)
            return {"sources": {}}

        # search 在 catalog 不存在时本应失败，但节流跳过 refresh 后直接 search，
        # search 返回空结果（search_catalog 对不存在文件返回空），job 仍 complete。
        def search_fn(*, query, filters, limit):
            return {"source": "ustc_campus_catalog", "query": query,
                    "results": [], "metadata": {"resultCount": 0}}

        manager = ReadQueryJobManager(
            campus_search_query=search_fn,
            campus_refresh_fn=refresh_fn,
            campus_catalog_path_fn=lambda: catalog_path,
            campus_now_fn=lambda: now,
        )
        job = manager.start_campus_search(CampusSearchQuery(query="通知"))
        self.assertEqual("complete", job.wait_for_terminal_or_pause())
        self.assertEqual(0, len(refresh_calls))
```

- [ ] **Step 4: 运行验证通过**

Run: `cd E:/107/.worktrees/read-only-agent && PYTHONPATH=src E:/conda/envs/ustc_assistant/python.exe -m pytest tests/bridge/test_query_jobs.py::CampusSearchAutoRefreshTests::test_refresh_throttled_within_min_interval -v`
Expected: PASS。

- [ ] **Step 5: 写测试 — refresh 失败但旧 catalog 存在则降级用旧数据**

```python
    def test_refresh_failure_falls_back_to_existing_catalog(self):
        import tempfile
        from datetime import datetime, timedelta
        from ustc_assistant.bridge import query_jobs as qj
        from ustc_assistant.sources.campus.catalog import BEIJING_TZ

        tmp_dir = Path(tempfile.mkdtemp(prefix="campus-fallback-"))
        catalog_path = tmp_dir / "campus-catalog.json"
        now = datetime(2026, 7, 31, 12, 0, tzinfo=BEIJING_TZ)
        stale_at = (now - timedelta(hours=7)).isoformat()  # 超过 6h 过期
        catalog_path.write_text(
            json.dumps({
                "schemaVersion": "1.0",
                "sources": {"teach_notice": {"lastSuccessfulAt": stale_at, "entries": []}},
            }),
            encoding="utf-8",
        )

        def refresh_fn(*, catalog_path, force):
            raise OSError("network down")

        # search 仍应被调（降级用旧 catalog），返回空结果，job complete
        search_called = []
        def search_fn(*, query, filters, limit):
            search_called.append(query)
            return {"source": "ustc_campus_catalog", "query": query,
                    "results": [], "metadata": {"resultCount": 0}}

        qj._last_campus_refresh_attempt = None
        manager = ReadQueryJobManager(
            campus_search_query=search_fn,
            campus_refresh_fn=refresh_fn,
            campus_catalog_path_fn=lambda: catalog_path,
            campus_now_fn=lambda: now,
        )
        job = manager.start_campus_search(CampusSearchQuery(query="通知"))
        self.assertEqual("complete", job.wait_for_terminal_or_pause())
        self.assertEqual(1, len(search_called))
```

- [ ] **Step 6: 运行验证通过**

Run: `cd E:/107/.worktrees/read-only-agent && PYTHONPATH=src E:/conda/envs/ustc_assistant/python.exe -m pytest tests/bridge/test_query_jobs.py::CampusSearchAutoRefreshTests::test_refresh_failure_falls_back_to_existing_catalog -v`
Expected: PASS。

- [ ] **Step 7: 写测试 — refresh 失败且 catalog 不存在则 catalog_unavailable**

```python
    def test_refresh_failure_and_no_catalog_yields_unavailable_error(self):
        import tempfile
        from ustc_assistant.bridge import query_jobs as qj
        from ustc_assistant.sources.campus.catalog import BEIJING_TZ
        from datetime import datetime

        tmp_dir = Path(tempfile.mkdtemp(prefix="campus-unavail-"))
        catalog_path = tmp_dir / "campus-catalog.json"  # 不存在
        now = datetime(2026, 7, 31, 12, 0, tzinfo=BEIJING_TZ)

        def refresh_fn(*, catalog_path, force):
            raise OSError("network down")

        def search_fn(*, query, filters, limit):
            self.fail("search must not be called when catalog is unavailable")

        qj._last_campus_refresh_attempt = None
        manager = ReadQueryJobManager(
            campus_search_query=search_fn,
            campus_refresh_fn=refresh_fn,
            campus_catalog_path_fn=lambda: catalog_path,
            campus_now_fn=lambda: now,
        )
        job = manager.start_campus_search(CampusSearchQuery(query="通知"))
        self.assertEqual("failed", job.wait_for_terminal_or_pause())
        self.assertEqual("catalog_unavailable", job.result.get("errorCode"))
        # 错误细节不泄漏
        result_str = json.dumps(job.result, ensure_ascii=False)
        self.assertNotIn("network down", result_str)
        self.assertNotIn("Traceback", result_str)
```

注：此用例依赖 job 失败时 `result["errorCode"]` 为 `"catalog_unavailable"`。若 `ReadQueryJob` 的失败结果结构不同（例如错误码在别的字段），实现时按实际结构调整断言，但必须断言：job failed、错误码为 `catalog_unavailable`、不含异常细节。需在实现时确认 `_run_campus_search` 抛 `CampusUnavailable` 后 runner/job 如何将其编码为失败结果——若现有 runner 不捕获 `CampusUnavailable`，需在 runner 或 `_run_campus_search` 层将其转为 `query_failed` 风格的安全失败码。**若现有失败编码机制不直接支持自定义码，Task 2 实现者须在 `_run_campus_search` 捕获 `CampusUnavailable` 并通过现有 `QueryResultEnvelope` 失败契约返回 `errorCode=catalog_unavailable`，并相应调整此用例断言路径。**

- [ ] **Step 8: 运行验证通过**

Run: `cd E:/107/.worktrees/read-only-agent && PYTHONPATH=src E:/conda/envs/ustc_assistant/python.exe -m pytest tests/bridge/test_query_jobs.py::CampusSearchAutoRefreshTests::test_refresh_failure_and_no_catalog_yields_unavailable_error -v`
Expected: PASS。

- [ ] **Step 9: 写测试 — catalog 过期（超过 CATALOG_STALE_AFTER）则 refresh 被调**

```python
    def test_refresh_invoked_when_catalog_stale(self):
        import tempfile
        from datetime import datetime, timedelta
        from ustc_assistant.bridge import query_jobs as qj
        from ustc_assistant.sources.campus.catalog import BEIJING_TZ

        tmp_dir = Path(tempfile.mkdtemp(prefix="campus-stale-"))
        catalog_path = tmp_dir / "campus-catalog.json"
        now = datetime(2026, 7, 31, 12, 0, tzinfo=BEIJING_TZ)
        stale_at = (now - timedelta(hours=7)).isoformat()  # 超过 6h
        catalog_path.write_text(
            json.dumps({
                "schemaVersion": "1.0",
                "sources": {"teach_notice": {"lastSuccessfulAt": stale_at, "entries": []}},
            }),
            encoding="utf-8",
        )
        refresh_calls = []
        def refresh_fn(*, catalog_path, force):
            refresh_calls.append(catalog_path)
            return {"sources": {}}

        def search_fn(*, query, filters, limit):
            return {"source": "ustc_campus_catalog", "query": query,
                    "results": [], "metadata": {"resultCount": 0}}

        qj._last_campus_refresh_attempt = None
        manager = ReadQueryJobManager(
            campus_search_query=search_fn,
            campus_refresh_fn=refresh_fn,
            campus_catalog_path_fn=lambda: catalog_path,
            campus_now_fn=lambda: now,
        )
        job = manager.start_campus_search(CampusSearchQuery(query="通知"))
        self.assertEqual("complete", job.wait_for_terminal_or_pause())
        self.assertEqual(1, len(refresh_calls))
```

- [ ] **Step 10: 运行验证通过**

Run: `cd E:/107/.worktrees/read-only-agent && PYTHONPATH=src E:/conda/envs/ustc_assistant/python.exe -m pytest tests/bridge/test_query_jobs.py::CampusSearchAutoRefreshTests -v`
Expected: 全部 6 个用例 PASS。

- [ ] **Step 11: 运行全套 bridge 测试**

Run: `cd E:/107/.worktrees/read-only-agent && PYTHONPATH=src E:/conda/envs/ustc_assistant/python.exe -m pytest tests/bridge/ -v`
Expected: 全部 PASS，无联网。

- [ ] **Step 12: 提交**

```bash
cd E:/107/.worktrees/read-only-agent
git add tests/bridge/test_query_jobs.py
git commit -m "test(bridge): cover catalog auto-refresh throttle/fresh/stale/fallback/unavailable branches"
```

---

### Task 3: 端到端真实验收 + 文档更新

**Files:**
- 无代码改动。验收靠运行 + 手动确认。
- 可选：`docs/agent-repair-handoff-2026-07-30.md` 追加本次自动 refresh 说明（若 handoff 文档仍维护）。

**Interfaces:**
- Consumes: Task 1+2 产出的自动 refresh 实现。

- [ ] **Step 1: 删除 worktree 现有 catalog，模拟从零**

```bash
rm -f E:/107/.worktrees/read-only-agent/tmp/campus-catalog.json
```

- [ ] **Step 2: 启动 app 并触发一次 campus_search（联网真实验收）**

由主人在 app 里问"最近有什么通知"或"查一下校园通知"，观察：
- 第一次查询会等待 refresh（可能几十秒，爬 5 个来源）。
- 查询完成后返回真实通知结果（非空）。
- 检查 `E:/107/.worktrees/read-only-agent/tmp/campus-catalog.json` 已被自动生成。

**注意**：此步需主人手动在 app 内操作（联网，可能慢）。若 refresh 因网站结构变化失败，记录失败来源，不视为实现缺陷（cadence/事务写入设计已保证降级）。

- [ ] **Step 3: 节流验证 — 30 分钟内再次查询不重新 refresh**

立即再问一次通知，确认第二次查询很快返回（未触发 refresh，因节流窗口内）。可通过观察查询耗时或 Bridge stderr 日志确认。

- [ ] **Step 4: 更新 handoff 文档（可选）**

若 `docs/agent-repair-handoff-2026-07-30.md` 仍在维护，追加一段说明 Bridge 自动 refresh 已实现，catalog 不再依赖手动 CLI。否则跳过。

- [ ] **Step 5: 提交文档（若有改动）**

```bash
cd E:/107/.worktrees/read-only-agent
git add docs/
git commit -m "docs: note bridge auto-refresh catalog in handoff"
```

---

## Self-Review

**1. Spec 覆盖：**
- §5.1 触发判定（节流/缺失/过期）→ Task 1 Step 3 + Task 2 用例 1/2/3/9。✓
- §5.2 refresh 执行（force=False、catalog_path 一致）→ Task 1 Step 3（`refresh_fn(catalog_path=..., force=False)`），Task 1 Step 1 断言 `catalog_path` 传参一致。✓
- §5.3 失败降级（旧 catalog 存在降级 / 不存在 raise）→ Task 2 用例 5/7。✓
- §5.4 依赖注入 → Task 1 Step 3 三个 `_resolve_*` + `__init__` 字段 + `start_campus_search` 透传。✓
- §5.5 节流时间戳（进程变量、active job 单线程）→ Task 1 Step 3 `_last_campus_refresh_attempt` + Task 2 用例 3。✓
- §6 影响文件（仅 query_jobs.py + test）→ 全计划只动这两文件 + 可选 docs。✓
- §7 测试 6 用例 → Task 2 全覆盖。✓
- §9 验收（缺失自动 refresh、新鲜不 refresh、降级、unavailable、不联网）→ Task 1/2 单测 + Task 3 端到端。✓

**2. Placeholder 扫描：** Task 2 Step 7 注释里有一处"若现有失败编码机制不支持自定义码，实现者须…"——这是对实现者处理未知失败编码契约的明确指引，不是 placeholder，给出了具体动作（在 `_run_campus_search` 捕获 `CampusUnavailable` 转为 `errorCode=catalog_unavailable`）。其余步骤均有完整代码。✓

**3. 类型一致性：** `refresh_fn` 签名在各处统一为 `(*, catalog_path, force)`；`catalog_path_fn` 统一 `() -> Path`；`now_fn` 统一 `() -> datetime`；`CampusUnavailable.code` 在 Task 1 定义、Task 2 Step 7 断言。✓
