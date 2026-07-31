# Bridge 自动刷新校园目录设计

## 1. 背景

校园公开信息目录（`tmp/campus-catalog.json`）由独立 CLI `collect-campus` 预先爬取生成，Bridge 的 `search_catalog` / `read_detail` **只读不写**。当前 Windows 测试暴露的问题：worktree 从未跑过 `collect-campus`，catalog 文件不存在，导致 Agent 调 `search_campus_catalog` 永远返回 0 条。

`2026-07-22-campus-catalog-design.md` 已确立目录的来源、cadence（notice 7 日窗口、monthly 每月一次）、事务式写入与失败降级原则。本设计在此基础上补一层**编排**：Bridge 在 `campus_search` 查询时，若目录缺失或过期则自动触发 `refresh_catalogs`，使数据就位不再依赖外部 CLI 手动执行。

这是 Windows 测试阶段的过渡方案。最终迁移到手机端时，Python Bridge 逻辑会被重写，catalog 生成流程另行设计（见 §8）。

## 2. 目标

- Agent 调 `search_campus_catalog` 时，若 catalog 文件不存在或已过期，Bridge 自动 refresh 后再查；用户无需手动跑 CLI。
- refresh 失败时若存在旧 catalog，降级用旧数据查询，不阻断；只有 catalog 完全不存在且 refresh 也失败时才返回错误。
- 避免每次 search 都触发重爬：设节流窗口，窗口内直接用现有 catalog。
- 不联网的单元测试：通过依赖注入 mock refresh 与 search，覆盖所有分支。

## 3. 非目标

- 不改 catalog 的来源、cadence、cutoff、事务写入逻辑（已在 2026-07-22 spec 定案）。
- 不改 Flutter 端 sync 流程（不在 sync 页加"校园公告"来源，那是另一条路）。
- 不改 catalog 文件路径解析（仍相对 Bridge 进程 CWD = worktree 根的 `tmp/campus-catalog.json`）。
- 不改 `read_campus_detail`：详情读取本就是联网按需读取，不存在"目录缺失"问题。
- 不引入后台定时刷新调度：刷新只在 search 触发时按需发生。

## 4. 现状回顾

`_run_campus_search`（`query_jobs.py`）直接调用 `search_catalog(query, filters, limit)`，未传 `catalog_path`，使用默认相对路径 `tmp/campus-catalog.json`，相对 Bridge 进程 CWD 解析。`start_campus_search` 通过 `query_fn` 注入查询函数（测试用 mock），`_resolve_campus_search_query` 默认解析到 `service.search_catalog`。

`refresh_catalogs(sources=None, force=False, catalog_path=...)`（`service.py`）已存在：对 monthly 来源按 `is_monthly_refresh_due` 自动跳过（当月已刷则 skip），对 notice 来源全量重爬并按 `notice_cutoff`（今天-6天）过滤。返回 `{sources: {name: {status, activeCount, error}}}`。单来源失败不阻止其他来源，失败来源保留上次成功索引（事务式写入）。

`CatalogStore.last_successful_at(source)` 返回某来源上次成功刷新的北京时间；`load()` 在文件不存在时返回空结构 `{sources: {}}`。

## 5. 设计

### 5.1 触发判定

在 `_run_campus_search` 调 `search_catalog` 之前，插入 `_ensure_catalog_fresh` 步骤，按以下顺序判定是否需要 refresh：

1. **节流窗口**：距上次 refresh 尝试不足 `REFRESH_MIN_INTERVAL`（默认 30 分钟）→ 不 refresh，直接查。节流时间戳是**进程内**的上次 refresh *尝试*时刻（不论成败），避免短时多次 search 反复触发重爬。
2. **catalog 缺失**：catalog 文件不存在 → 必须 refresh。
3. **catalog 过期**：文件存在，但所有来源的 `lastSuccessfulAt` 中最新的那个距今超过 `CATALOG_STALE_AFTER`（默认 6 小时）→ refresh。取"最新来源时间"而非"最旧"，是因为只要有一个来源新鲜，搜索就还有较新数据可用；全部来源都老了才值得重爬。

两个阈值均为模块常量，可被测试覆盖（通过参数注入或 monkeypatch）。

### 5.2 refresh 执行

调用 `refresh_catalogs(force=False)`（不强制，让 cadence 逻辑决定 monthly 跳过）。refresh 在 `_run_campus_search` 的 runner 体内同步执行——该 runner 已在后台 job 线程跑，不会阻塞 Bridge 主线程，但该次 search 的用户会等到 refresh 完。

refresh 的 `catalog_path` 必须与后续 `search_catalog` 用同一个路径，确保读写一致。通过一个共享的 `_catalog_path` 解析（见 5.4）。

### 5.3 失败降级

- refresh 抛异常或返回的 `sources` 全部 `failed`：若 catalog 文件**已存在**（哪怕是旧的）→ 吞掉异常，继续用旧 catalog 查；若 catalog **不存在** → 返回 `AgentToolStatus.error`，`errorCode = 'catalog_unavailable'`。
- refresh 部分成功部分失败：正常情况，事务式写入已保证失败来源保留旧索引，直接查即可。
- refresh 任何失败都记录到 stderr（Bridge 已有日志习惯），但不向模型泄漏异常细节。

### 5.4 依赖注入

为可测试性，新增可注入参数：
- `refresh_fn: Callable[..., dict] | None`：默认解析到 `service.refresh_catalogs`。测试注入 mock 验证调用与否。
- `catalog_path_fn: Callable[[], Path] | None`：默认返回 `service.DEFAULT_CATALOG_PATH`。测试注入返回临时目录路径，避免污染真实 `tmp/`。
- `now_fn: Callable[[], datetime] | None`：默认 `datetime.now(BEIJING_TZ)`。测试注入固定时间控制节流与过期判定。

`_run_campus_search` 签名扩展接收这些参数；`start_campus_search` 与 `ReadQueryJobManager.__init__` 同步增加对应的可选注入字段（`campus_refresh_fn` 等），生产路径留空走默认解析。

### 5.5 节流时间戳

进程级模块变量 `_last_campus_refresh_attempt: datetime | None`，在每次真正发起 refresh 前更新为 `now_fn()`。判定时若 `now - _last_campus_refresh_attempt < REFRESH_MIN_INTERVAL`，跳过 refresh。这是进程内状态，Bridge 重启后重置（可接受：重启后第一次 search 会 refresh 一次）。

线程安全：`_run_campus_search` 的 runner 由 `ReadQueryJobManager` 保证同一时刻只有一个 active job（`_active` 锁），故对 `_last_campus_refresh_attempt` 的读写无需额外加锁。

## 6. 影响文件

- 修改：`src/ustc_assistant/bridge/query_jobs.py`
  - `_run_campus_search`：插入 `_ensure_catalog_fresh` 调用，扩展签名。
  - 新增 `_ensure_catalog_fresh` 辅助函数。
  - `start_campus_search` / `ReadQueryJobManager.__init__`：增加 `campus_refresh_fn` / `campus_catalog_path_fn` / `campus_now_fn` 注入字段与默认解析。
  - 新增模块常量 `REFRESH_MIN_INTERVAL`、`CATALOG_STALE_AFTER`、`_last_campus_refresh_attempt`、错误码 `catalog_unavailable`。
- 修改：`tests/bridge/test_query_jobs.py`：新增自动 refresh 测试用例。
- 不改：`service.py`、`catalog.py`、Dart 侧任何文件。

## 7. 测试策略

测试通过 `refresh_fn` / `catalog_path_fn` / `now_fn` 注入 mock，**不联网、不碰真实 `tmp/`**。用例：

1. **catalog 缺失 → refresh 被调 → search 正常**：`catalog_path_fn` 指向不存在的临时路径，`refresh_fn` 返回成功，`search_query_fn` 返回结果。断言 refresh 被调用一次，job complete，结果正确。
2. **catalog 新鲜 → refresh 不被调**：先写一个 `lastSuccessfulAt` 为 `now - 1h` 的 catalog 文件，`now_fn` 返回 `now`。断言 refresh 未被调用，search 直接返回。
3. **节流窗口内 → refresh 不被调**：模拟"刚 refresh 过"（通过先触发一次再立即第二次 search，或直接设 `_last_campus_refresh_attempt`），第二次 refresh 不应被调。
4. **refresh 失败但旧 catalog 存在 → 降级用旧数据**：`refresh_fn` 抛异常，但 catalog 文件存在（含旧条目）。断言 job 仍 complete，search 返回旧数据。
5. **refresh 失败且 catalog 不存在 → error**：`refresh_fn` 抛异常，catalog 不存在。断言 job failed，`errorCode = 'catalog_unavailable'`，错误细节不泄漏。
6. **catalog 过期 → refresh 被调**：`lastSuccessfulAt` 为 `now - 7h`（超过 `CATALOG_STALE_AFTER` 6h）。断言 refresh 被调。

现有用例（`test_campus_search_wraps_raw_dict_into_envelope` 等）注入了 `campus_search_query` mock 但未注入 refresh：这些用例的 `catalog_path_fn` 默认指向真实 `tmp/campus-catalog.json`，在测试环境下若该文件不存在会触发 refresh——需确保这些用例**不被破坏**。处理方式：当 `refresh_fn` 为 None 且走默认解析时，若真实 catalog 不存在，默认 `refresh_fn`（真实 `refresh_catalogs`）会尝试联网——这在单测里不可接受。故默认解析路径在**测试中必须被注入覆盖**，或现有用例补注入一个"不触发 refresh"的 `catalog_path_fn`/`refresh_fn`。实现时审查所有现有 campus search 用例，补齐注入，保证不联网。

## 8. 迁移备注

本设计是 Windows Python Bridge 阶段的过渡。最终迁移手机端时，Python Bridge 全部重写：catalog 生成可能改为手机端原生 HTTP + 本地存储，或服务端预生成下发。届时此自动 refresh 逻辑随 Bridge 一并重写，不在手机端沿用。当前实现保持改动集中在 bridge 层、可独立测试，便于将来整体替换。

## 9. 验收标准

- worktree 无 `tmp/campus-catalog.json` 时，Agent 调 `search_campus_catalog` 能自动 refresh 出数据并返回结果（端到端，需联网真实验收一次）。
- catalog 新鲜或节流窗口内，search 不触发 refresh，直接返回。
- refresh 失败时若旧 catalog 存在则降级用旧数据，不阻断查询。
- refresh 失败且 catalog 不存在时返回 `catalog_unavailable` 错误，不泄漏异常细节。
- 所有新增与现有 bridge 单测在不联网条件下通过；`tests/bridge/` 全套绿。
