# M1 详细实施计划：删除 young/icourse/campus，保留 JW Bridge，收敛依赖

> 分支：`refactor/webview-minimal`（HEAD = plan-only，工作区干净）
> 依据：`docs/plan-webview-minimal.md` 的 M1 目标（§4 具体拆解）
> 目标：M1 门全绿 —— Python `unittest` + `compileall`、Flutter `analyze`（0 error）+ `test` 全绿、
> 禁词 grep 无活跃引用、CLI 双命令可用。
>
> 修订版 v2：吸收独立审查意见（B1–B5 阻断性、N1–N7 非阻断、S1–S5 建议）后更新。

## 0. 任务地图（文件级）

### Python 删除

| 操作 | 文件 |
|---|---|
| 删目录 | `src/ustc_assistant/sources/{young,icourse,campus}/` |
| 删文件 | `src/ustc_assistant/bridge/query_contracts.py`、`query_jobs.py` |
| 改 | `src/ustc_assistant/bridge/server.py`、`jobs.py`、`protocol.py`（去 QUERY）、`cli.py`、`src/ustc_assistant/sources/__init__.py`、`pyproject.toml`、`__main__.py` |
| 删测试 | `tests/{young,icourse,campus}/`、`tests/bridge/test_query_*.py`、`tests/fixtures/{campus,icourse}/`、`tests/fixtures/query-results/` |
| 改测试 | `tests/bridge/test_server.py`、`tests/bridge/test_jobs.py`、`tests/bridge/test_collection_api.py`、`tests/test_cli.py` |
| 保留 | `tests/fixtures/source-bundle/positive/young-*.json`（`tests/contracts/test_source_bundle.py` 用；`source-bundle` 契约不关） |

### Flutter 删除

| 操作 | 文件 |
|---|---|
| 删文件 | `lib/features/agent/data/windows_python_query_gateway.dart`、`lib/features/agent/domain/query_source.dart` |
| 改 | `lib/app/router.dart`、`lib/features/agent/application/agent_composition.dart`、`agent_tools.dart`、`agent_system_prompt.dart`、`agent_grounding_policy.dart`、`agent_session_service.dart`（B2 去 campus 转发）、`agent_configuration_service.dart`、`agent_chat_page.dart`、`agent_settings_page.dart`、`lib/features/agent/domain/agent_tool.dart`（去 youngLogin）、`lib/features/sync/domain/sync_state.dart`（仅 jw）、`sync_coordinator.dart`、`sync_page.dart`、`settings_page.dart`、`settings_service.dart`、`accounts_page.dart`、`account_service.dart`、`lib/features/schedule/presentation/event_detail_page.dart`（N1 去 young arm）、`lib/features/settings/presentation/official_websites_page.dart`（S3 保留声明） |
| 删测试 | `test/features/agent/external_agent_tools_test.dart`、`windows_python_query_gateway_test.dart`、`test/fixtures/query_results/`、`test/integration/read_only_agent_flow_test.dart`（**不删** `agent_composition_flow_test.dart`，见 B1 决策） |
| 改测试 | `test/integration/agent_composition_flow_test.dart`（去 gateway 接缝）、`test/app/app_shell_test.dart`、`test/features/agent/agent_prompt_injection_test.dart`、`agent_chat_page_test.dart`、`agent_session_service_test.dart`、`local_agent_tools_test.dart`、`test/features/agent/agent_configuration_service_test.dart`（B3）、`test/features/sync/sync_coordinator_test.dart`、`sync_page_test.dart` |

## 全局约束

- 保留：`config/source-defaults.json`、`config.py` JW 三元组、`contracts/` 全部、`schemas/`。
- `@rule:` 二课 SourceBundle 正/负 fixture 仅作 schema 兼容性测试输入保留（`tests/fixtures/source-bundle/positive/young-*.json`），不删。
- Python `pyproject.toml` 依赖收敛为 `playwright>=1.50,<2` + `jsonschema>=4.23,<5`（去掉 `requests`、`beautifulsoup4`）；`requests`/`bs4` 在删除后应零引用。
- Flutter `SyncSource` 枚举仅保留 `jw('ustc_jw')`。
- `.gitignore` 与 `app/pubspec.yaml`（离线 hooks）不在本里程碑改动范围，保持现状。
- **数据模型字符串保留（审核澄清）**：以下对 `young/icourse/campus` 的引用是数据模型/契约字符串而非功能引用，**保留不删**：
  - `lib/features/calendar/domain/personal_event.dart` 的 `PersonalEventType.campusAffair`（枚举值）与 `calendar_event_form.dart:364` 的映射。
  - `source_bundle_semantics.dart:8` 的 `'young_registered_schedule': 'calendar_event'` 与 `_checkScope` 非 jw 分支（行 264-285）——young bundle fixture 作 schema 兼容测试输入，契约校验需保留。
  - `contracts/source_bundle_validation.py:63` 的 `"young_registered_schedule": "calendar_event"`（同上）。
  - `import_service_test.dart`/`source_bundle_decoder_test.dart` 用的 `young-empty-window.json`/`young-with-schedule.json` fixture（契约测试）。
  - `jw_day_move_dialog_test.dart:120`/`jw_day_move_service_test.dart:135`/`schedule_page_test.dart:187,206`/`schedule_projection_test.dart:441,455` 的 `'ustc_young'`/`'ustc_young_my_schedule'`/`'ustc_young_schedule'` 字符串——测 move 排除/渲染逻辑，是 DB 事件 source 字段值（非枚举引用），保留。
  - `milestone_accessibility_test.dart:74`/`responsive_golden_test.dart:76` 的 `icourseConsent: false`（保留的 `AgentSettingsSnapshot` 字段引用）。
- **测试基数（审核澄清）**：Python 基线 394 测试通过；删除 young/icourse/campus + query 测试（约 22 文件、~241 方法）后预期约 153 测试通过（与 handoff "145" 估值一致，handoff 计数为部分实施后口径）。

---

## Python 任务

### Task P1：删除 young/icourse/campus Python 代码与测试，拆 Bridge 查询协议

**Files（git rm / rm -rf）：**
- Delete dirs: `src/ustc_assistant/sources/{young,icourse,campus}/`
- Delete: `src/ustc_assistant/bridge/query_contracts.py`, `src/ustc_assistant/bridge/query_jobs.py`
- Modify: `src/ustc_assistant/bridge/protocol.py`, `src/ustc_assistant/bridge/server.py`, `src/ustc_assistant/bridge/jobs.py`
- Test: `tests/bridge/test_server.py`, `tests/bridge/test_jobs.py`, `tests/bridge/test_collection_api.py`, `tests/bridge/test_query_*.py` (deleting), `tests/bridge/test_protocol.py`

- [ ] **Step 1: git rm 三个来源目录与 query 模块，删除对应测试**

```bash
cd /home/ubuntu/107_ustc_assistant
# 1) 删除三个来源 Python 包
git rm -r -q src/ustc_assistant/sources/young src/ustc_assistant/sources/icourse src/ustc_assistant/sources/campus
# 2) 删除 Bridge 查询协议模块
git rm -q src/ustc_assistant/bridge/query_contracts.py src/ustc_assistant/bridge/query_jobs.py
# 3) 删除对应测试目录（每个目录独立列出，互不覆盖，避免 N7 误删/误解）
git rm -r -q tests/young tests/icourse tests/campus
git rm -r -q tests/fixtures/campus tests/fixtures/icourse tests/fixtures/query-results
# 4) 单独删除 query 专项测试文件
git rm -q tests/bridge/test_query_api.py tests/bridge/test_query_contracts.py tests/bridge/test_query_jobs.py
# 保留（Step 6 改，不删）：tests/bridge/{test_server,test_jobs,test_collection_api,test_protocol}.py + tests/bridge/__init__.py
# 保留（契约测试依赖，不删）：tests/fixtures/source-bundle/**（含 positive/young-*.json）
```

- [ ] **Step 2: 修改 `src/ustc_assistant/sources/__init__.py`** 为纯 docstring（无导出）——当前已是纯 docstring，本步为核对项（S1）。

- [ ] **Step 3: 修改 `src/ustc_assistant/bridge/protocol.py`**：删 `QUERY_PROTOCOL_VERSION` 行，保留 `PROTOCOL_VERSION`、`MAX_REQUEST_BYTES`、`ProtocolError`、`make_handshake`、`parse_request_body`。

- [ ] **Step 4: 修改 `src/ustc_assistant/bridge/jobs.py`**：删 `YoungCollectionRequest` 类；`CollectionJob.__init__`（行 57-58）与 `_collector_kwargs`（行 105-117）的 young 分支与 `request: JwCollectionRequest | YoungCollectionRequest` 注解 → 只 `JwCollectionRequest`；删 `JobManager.start_young_schedule`（行 250-262）；删 `_start` 注解（行 220）的 young 联合；删 `from ustc_assistant.sources.young import source_bundle as young_service`（行 20）与 `date` import（young 移除后 `date` 无使用——确认后删）。**B5: 所有残留 `YoungCollectionRequest` 类型引用都必须清除，否则 pydoc/compile 阶段炸。**

- [ ] **Step 5: 修改 `src/ustc_assistant/bridge/server.py`**：
  - 删 query 相关 import（`query_jobs` 全部行 24-34、`QUERY_PROTOCOL_VERSION`、`_FORBIDDEN_URL_FILESYSTEM_FIELDS`）。
  - **B5: 删 `from ustc_assistant.bridge.jobs import ... YoungCollectionRequest`（行 22）与 `from ustc_assistant.sources.young import source_bundle` 全部（行 47）+ `young_service` 成员（行 286-288）**；`dispatch_post` 的 `/collect/young-schedule`（行 392-412）删除。
  - `GET /capabilities`（行 152-173）：删 `queryProtocolVersion` 与 `queryTypes` 字段；`query_jobs` 相关（行 194-216）、`do_POST` 的 `/queries`（行 437-439）、`query-jobs/*/resume-login`（行 440-470）、`query-jobs/*/cancel`（行 471-478）、`_start_query_job`（行 500-618）、`_reject_forbidden_fields`（行 482-498）删除；`do_POST` 里的 `BridgeQueryBusy`/`QueryJobNotFound`/`InvalidQueryJobState` 捕获删除。
  - `BridgeServer.__init__`：删 `query_job_manager`、`query_jobs` 成员与 `ReadQueryJobManager` 导入与构造（行 306-311）；删 `young_collector`/四个 query callable 参数（行 286-294）。
  - `_monitor`（行 630-632）：`active_jobs` 只算 `self.jobs.active_jobs`。
  - 保留 `/health`、`/capabilities`（去 query 字段）、`/collect/jw`、`/login/resume`、`/jobs/{id}/events`、`/jobs/{id}/cancel`、`/shutdown`。

- [ ] **Step 6: 修改测试**：
  - `tests/bridge/test_server.py`：删 `QueryRouteBoundaryTests` 与任何 query 端点用例（`query-jobs`/`queries`）。若 `RunningServer()` 用 `parent_pid=None` 则其他保留。
  - `tests/bridge/test_jobs.py`：删 young 相关 `YOUNG_REQUEST` 构造与 `start_young_schedule` 用例；其余 JW 用例保留。
  - `tests/bridge/test_collection_api.py`：删 `ReadQueryJobManager` import、`QUERY_PROTOCOL_VERSION` 常量、`test_collection_and_query_managers_coexist_on_one_server` 及任何 query 协议字段断言；保留 collection 断言。
  - `tests/bridge/test_protocol.py`：如有 QUERY 断言删除。

- [ ] **Step 7: 全库编译检查 + 残留 grep**

```bash
cd /home/ubuntu/107_ustc_assistant
conda run -n ustc_assistant python -m compileall -q src tests
conda run -n ustc_assistant python -m unittest discover -s tests -v 2>&1 | tail -5
grep -rIn "query_jobs\|query_contracts\|ReadQueryJobManager\|queries" src tests --include='*.py' | grep -v __pycache__ || echo "CLEAN"
```

### Task P2：收敛 CLI 只留 collect jw + config generate-flutter-defaults

**Files:**
- Modify: `src/ustc_assistant/cli.py`
- Test: `tests/test_cli.py`

- [ ] **Step 1: 重写 `cli.py` 内容**：删 `collect young-enrolment`、`collect young-schedule`、`collect campus`、`query icourse`、`query campus`、`read campus` 解析器与 handler（`_collect_young_enrolment`、`_collect_young_schedule`、`_query_icourse`、`_collect_campus`、`_query_campus`、`_read_campus`）；删 import campus/icourse/young；保留 `collect jw`、`config generate-flutter-defaults`、`_collect_jw`、`_generate_flutter_defaults`、`_add_browser_options`、`_SemesterOverrideAction`、`_date_argument`（如不再用则删）、`_required_account_id`。

- [ ] **Step 2: 重写 `tests/test_cli.py`**：删 young/icourse/campus 的用例（含 `test_formal_collect_commands_require_account_id_without_collecting` 中的 young 补丁、`test_icourse_service_exposes_app_callable_query_runner`、`test_campus_parsers_expose_collect_query_and_read_defaults`、`test_task7_stable_query_callables_remain_importable_and_callable`、`test_cli_query_read_collect_subcommands_still_parse`、`test_campus_repeatable_and_safety_options_are_parsed`、`test_young_enrolment_command_defaults_to_normalized_output_only`、`test_young_schedule_command_writes_source_bundle_and_named_raw_file`、`test_query_writes_empty_offline_result`、`test_read_forwards_stale_and_candidate_link_ids`、`test_main_handles_campus_error_without_traceback`）。**保留** JW 与 config 相关用例，并修改（N5 修正真实方法名，无 `test_FORMATTER_...` 幻影）：
  - `test_root_parser_exposes_collect_and_query`（行 50）→ `test_root_parser_exposes_collect_and_config`：删 `["query", "icourse", ...]` 断言，改断言 `collect young-schedule`、`query icourse`、`collect campus` 触发 `SystemExit`（argparse 未知子命令）。
  - `test_collect_parsers_use_current_semester_defaults`（行 63）→ 只测 `collect jw`（行 71-85 删 young-schedule 段）。
  - `test_formal_collect_commands_require_account_id_without_collecting`（行 100）→ 只测 jw。
  - `test_collect_writes_summary_and_returns_one_on_partial_failure`（行 388）→ 改 JW 场景或删除（原依赖 campus）。
  - `test_run_in_edge_uses_visible_persistent_edge_and_closes`（行 515）与 `test_login_session`（如有）保留。
  - 新增冒烟：跑 `python -m ustc_assistant collect jw --help` 与 `config generate-flutter-defaults --help` 不报错（CLI 门，见 Task P4）。

- [ ] **Step 3: compileall + unittest 全绿后再提交。**

### Task P3：pyproject 依赖收敛

- [ ] **Step 1:** `pyproject.toml` dependencies 改为：

```toml
dependencies = [
  "playwright>=1.50,<2",
  "jsonschema>=4.23,<5",
]
```

- [ ] **Step 2: 验证无 requests/bs4 残留引用**（`grep -rl 'import requests\|from bs4\|BeautifulSoup' src tests` 为空），`python -m compileall` 绿。

### Task P4：CLI 门验证（运行期）

- [ ] 运行：
```bash
cd /home/ubuntu/107_ustc_assistant
conda run -n ustc_assistant python -m ustc_assistant collect jw --help
conda run -n ustc_assistant python -m ustc_assistant config generate-flutter-defaults --help
conda run -n ustc_assistant python -m ustc_assistant collect young-schedule 2>&1 | head -3   # 期望失败：非法子命令
conda run -n ustc_assistant python -m ustc_assistant query icourse --course x 2>&1 | head -3  # 期望失败：非法子命令
```
- [ ] 禁词 grep（排除合法保留词）：
```bash
grep -rIn -E "young|icourse|campus" src tests --include='*.py' \
  | grep -v "__pycache__" \
  | grep -vE "campusName|campus_affair|icourse_consent|source-bundle/positive/young|young-empty-window|young-with-schedule" || echo "CLEAN"
```
（S4：`src/ustc_assistant/__init__.py:1` 的 "campus assistant" docstring 属纯注释——要么在排除表加 `__init__.py`，要么把 docstring 改写为 "USTC assistant"。倾向改 docstring 为中性描述，避免豁免扩散。S5：`config.py` 无 campus 引用，`contracts/` 无 young/query 引用；`query_contracts.py` 里才有但已删——无 Task P7，此复核并入 P4。）

- [ ] 最终：`python -m unittest discover -s tests -v` 全绿，`compileall` 绿。

---

## Flutter 任务

### Task F1：删除外部查询 gateway/domain/工具 + 同步收敛为单 JW

**Files:**
- Delete: `lib/features/agent/data/windows_python_query_gateway.dart`, `lib/features/agent/domain/query_source.dart`
- Modify: `lib/features/agent/application/agent_composition.dart`, `agent_tools.dart`, `lib/features/sync/domain/sync_state.dart`, `lib/features/sync/data/bridge_client.dart`（B-补1：清理 Bridge 查询协议接口与 young-schedule 死分支）
- 本任务不覆盖 UI/settings（下一任务）。

- [ ] **Step 1: git rm 两个文件**：
```bash
cd /home/ubuntu/107_ustc_assistant/app
git rm -q lib/features/agent/data/windows_python_query_gateway.dart lib/features/agent/domain/query_source.dart
```

- [ ] **Step 2: 修改 `lib/features/sync/domain/sync_state.dart`**：枚举只留 `jw('ustc_jw')`。

- [ ] **Step 3: 修改 `agent_composition.dart`**：
  - 删 `import 'domain/query_source.dart'`；删 `QueryGatewayFactory`/`QueryGatewayStarter` typedef、`LazyQuerySourceGateway` 类（整个）。
  - `AgentComposition.build`：删 `queryGatewayFactory` 参数与其调用；删 `externalAgentTools(...)` 调用；`allTools` 改为 `[...local, ...write]`。
  - `userActionResumer` 的 `youngLogin` case 删除（保留 `writeConfirmation` 相关剩余或改为注释说明不经过会话级 resumer）。
  - `AgentCompositionResult`：删 `queryGateway` 字段与 `dispose()` 中对它的处理；构造参数同步删。
  - 删 `DisposableQuerySourceGateway` 引用。
  - 更新 doc comment。

- [ ] **Step 4: 修改 `agent_tools.dart`**：
  - 删 `import '../domain/query_source.dart';` → 若不再用。
  - 删 `SearchCurrentSecondClassActivitiesTool`、`SearchIcourseTool`、`SearchCampusCatalogTool`、`ReadCampusDetailTool` 四个类；`externalAgentTools()` 函数；`_collectQueryEvents`、`_YoungQueryInvocation`、`_map*` 辅助；`_youngLogin` 常量与 `AgentUserActionType.youngLogin` 引用（行 2780）。保留 `localAgentTools`、`agentToolPayloadBuilders`。

- [ ] **Step 5: 修改 `lib/features/agent/domain/agent_tool.dart`**：`enum AgentUserActionType { writeConfirmation }`（删 `youngLogin`）。同步检查 `agent_chat_page.dart:558` 与 `agent_session_service` 的该分支使用。

- [ ] **Step 5b: 修改 `lib/features/sync/data/bridge_client.dart`**（B-补1，审核新增）：
  - 删 `abstract interface class BridgeQueryGateway`（行 107-118）整个接口；`class BridgeClient implements BridgeGateway, BridgeQueryGateway`（行 179）去掉 `, BridgeQueryGateway`。
  - 删 `BridgeQueryGateway` 实现区段（行 329 起，`getQuery`/`postQuery` 等查询方法）与相关注释。
  - `startCollection`（行 270-272）的三元 `source == SyncSource.jw ? '/collect/jw' : '/collect/young-schedule'` 收敛为常量 `'/collect/jw'`（young 分支已死，SyncSource 仅 jw）；同步删 `if (source == SyncSource.jw) 'semester': ...` 的条件，直接放 `'semester': jwSemester.toJson()`。
  - 理由：Python Bridge 查询协议在 P1 已删，Dart 侧查询网关与 dead path 一并清除，避免禁词 grep 误报与死代码。

- [ ] **Step 6: `flutter analyze` 只跑 lib**（记 error 数，测试文件 error 除外）：
```bash
cd /home/ubuntu/107_ustc_assistant/app && flutter analyze lib 2>&1 | tail -5
```

### Task F2：同步 UI / 设置 / 账号页单 JW 化

**Files:**
- Modify: `lib/features/sync/application/sync_coordinator.dart`, `lib/features/sync/presentation/sync_page.dart`, `lib/features/settings/presentation/settings_page.dart`, `lib/features/settings/application/settings_service.dart`, `lib/features/accounts/application/account_service.dart`, `lib/features/accounts/presentation/accounts_page.dart`

- [ ] **Step 1: `sync_coordinator.dart`**：行 145 `for (final source in SyncSource.values)` 保留（单元素循环，天然只 jw），不改；行 344 `SyncSucceeded(source, ...)` 用循环变量 `source`（非字面量枚举成员），收敛后仍编译，不改。**真正需删的是 `_persistCapabilities` 的 young 块（行 511-515）**：`_ensureConfig(SyncSource.youngSchedule, accountId, timestamp: timestamp)` 是字面量 `SyncSource.youngSchedule` 引用——F1 Step 2 收敛枚举后此行**编译失败**，必须删除整个 511-515 的 `_ensureConfig(SyncSource.youngSchedule,...)` 调用块，只保留 505-510 的 jw 块。（N3 行号修正：原计划误把行 344 当作需删的 SyncSucceeded，实际 344 用循环变量无需改；需删的是 512 字面量。）

- [ ] **Step 2: `sync_page.dart`**：行 539 `source == SyncSource.jw ? Icons.school : Icons.event` 简化为 jw（N4 行号修正：541 label 是 539，行 541 "已报名二课" 分支删除）；行 559 `_stateLabel` 只服务 jw；`for (final source in SyncSource.values)` 循环为单元素，可保留。确认无 `SyncSource.youngSchedule` 硬引用。

- [ ] **Step 3: `settings_page.dart`**：删 `youngEnabled` 状态与 `setSourceEnabled('ustc_young_schedule')` 调用，settings 页只保留教务开关。

- [ ] **Step 4: `settings_service.dart`**（O-2 修正：**保留** `pythonPath`/`setPythonPath`）：`pythonPath()` 仍被 `sync_page.dart:47`（`PythonLocator().locate(savedExecutable: ...pythonPath())`）与 `sync_page.dart:52`、`settings_page.dart:26/98` 使用以启动 Bridge——Bridge 保留到 M3，删除会破坏 M1 门（编译失败）。**不删**。`clearExternalCache` 保留为 noop 安全网。仅当 router 不再引用于 F3 之后仍验证 sync_page 的 Bridge 启动路径完好。

- [ ] **Step 5: `account_service.dart`/`accounts_page.dart`**：`youngLastSuccessAt` 字段与 `\u0000ustc_young_schedule` 值删；`accounts_page.dart:153` 的"二课平台"文本删。`usernameForSync` 保留。

- [ ] **Step 6: compile/test**：`flutter analyze` error 降到只剩测试文件。

### Task F3：Agent 组合与入口无 QueryGateway + 系统提示词 v8/minimal

**Files:**
- Modify: `lib/app/router.dart`, `lib/features/agent/application/agent_system_prompt.dart`

- [ ] **Step 1: `router.dart`**：
  - 删 `import ...windows_python_query_gateway.dart`。
  - `define`: `_buildWindowsAgentComposition` → 改名为 `_buildAgentComposition` 并删 `LazyQuerySourceGateway`/`resolveBridgeLaunchOptions`/`PythonLocator`/`WindowsPythonQueryGateway.start`。
  - `AgentComposition.build` 调用删 `queryGatewayFactory` 参数。
  - `_AgentChatCompositionBuilder` doc comment 更新（不再 handshake）。

- [ ] **Step 2: `agent_system_prompt.dart`**（O-1 修正 / N2）：必须**重写 base `version4`**（行 127 起，含 144-147 二课/评课/campus 工具映射、172 外部数据反幻觉节、191-192 能力边界），再让 v5/v6/v7/v8 逐级内插保持 minimal 版。**决策：bump 到 `version = 9` 新增 `version9` 常量**（语义版本=文本内容；base 改动属 v8→v9）。执行：
  - base `version4`：删"只读场景→工具映射"里 `search_current_second_class_activities`/`search_icourse`/`search_campus_catalog`/`read_campus_detail` 四行；"反幻觉与历史约束"外部数据节（行 172）改为"本地数据"；"当前能力边界"节（行 189-192）收敛为"仅教务课程/考试 + 本地日程/Task/PlanBlock/冲突/同步/历史 + 本地写/删除/生命周期工具规范（v8 节原样）"。
  - 新增 `static const String version9 = '$version8' '''...冗余收敛说明...''';` 与 `static const int version = 9;`。
  - `defaultSystemPromptVersion = 3` M1 不 bump（O-4 见开放决策）。

- [ ] **Step 3: `agent_grounding_policy.dart`**：删二课/评课/campus 三条 `_IntentDef`（行 650-670）；并核查 `search_current_second_class_activities`/`search_icourse`/`search_campus_catalog`/`read_campus_detail` 在 policy 其它位置无引用。

- [ ] **Step 4（B2）: `lib/features/agent/application/agent_session_service.dart`**：删外部 catalog 转发：`_catalogTools` 常量（行 1926-1929）与 `_isCatalogTool`（行 1895）相关调用删除或恒 false；`sourceReferences` 的 campus_entry 转发分支（行 1420-1423/1496）删除；注释（1019/1413）更新。删除后该文件不再含外部来源标识符（除退役注释）。

### Task F4：配置与设置页收iCourse 退役 + Agent UI 去外部残留

**Files:**
- Modify: `lib/features/agent/application/agent_configuration_service.dart`, `lib/features/agent/presentation/agent_settings_page.dart`, `agent_chat_page.dart`

- [ ] **Step 1: `agent_configuration_service.dart`**：`setIcourseConsent` 保留 DB 列读写（schema 不改），但 `AgentSettingsSnapshot` 的 icourseConsent 保留。考虑是否删 `setIcourseConsent` 公开方法——按 plan §4.2 "删除 iCourse user-visible consent；保留 DB 列与 service 状态读取" → **删 `setIcourseConsent`**，默认值保留字段读取。若 `defaultIcourseConsent`/`defaultSystemPromptVersion` 被 UI 用则保留。

- [ ] **Step 2: `agent_settings_page.dart`**：删 iCourse consent 开关 UI；保留 AGENT/API key/model 配置。

- [ ] **Step 3: `agent_chat_page.dart`**: 删 `AgentUserActionType.youngLogin` 分支（行 558 附近）；若 `_youngQueryLogin` 等辅助存在一并删。

- [ ] **Step 4: analyze + test（此时测试文件仍有 error，跳过后到 Task F6）**。

### Task F5：删除/修改测试文件

**Files:**
- Delete: `test/features/agent/external_agent_tools_test.dart`, `test/features/agent/windows_python_query_gateway_test.dart`, `test/fixtures/query_results/`, `test/integration/read_only_agent_flow_test.dart`
- Edit (保留，去掉 gateway/外部工具): `test/integration/agent_composition_flow_test.dart`
- Modify: `test/app/app_shell_test.dart`, `test/features/agent/agent_prompt_injection_test.dart`, `agent_chat_page_test.dart`, `agent_session_service_test.dart`, `local_agent_tools_test.dart`, `agent_configuration_service_test.dart`, `test/features/sync/sync_coordinator_test.dart`, `sync_page_test.dart`
- Modify (审核新增 B-补2/3/4): `test/features/agent/agent_settings_page_test.dart`（删 iCourse consent 测试组，B-补2）、`test/features/agent/agent_context_builder_test.dart`（收敛工具名/二课断言，B-补3）、`test/features/sync/bridge_client_test.dart`（删 Bridge 查询协议测试，B-补4）、`test/features/accounts/accounts_page_test.dart`（删"二课平台"断言，B-补5）

> **B1 决策**：`agent_composition_flow_test.dart` 含 37 个测试（本地写/确认门/撤销/账号切换/数据库隔离），其中 4 个依赖外部工具（young resume / second-class）。为保住本地组合回归又不做 281KB 高风险手术，保留该文件并**机械移除** gateway 接缝：`_buildTestComposition` 不接受 `gateway` 参数（行 547），构造去 `queryGatewayFactory`（行 563），所有 `_CountingResumableYoungGateway()` 实例化（~30 处）删除，网关断言用例（`startedJobs`/`resumedJobIds`/`passwordWasProvided`/`disposeCalls`）删除或改写为无外部来源等价。`read_only_agent_flow_test.dart` 全部测试依赖外部 catalog/second-class 工具链 → 整体删除，无本地覆盖损失。

- [ ] **Step 1: git rm 四个测试文件/目录**（不删 `agent_composition_flow_test.dart`）：
```bash
cd /home/ubuntu/107_ustc_assistant/app
git rm -q test/features/agent/external_agent_tools_test.dart test/features/agent/windows_python_query_gateway_test.dart
git rm -q test/integration/read_only_agent_flow_test.dart
git rm -r -q test/fixtures/query_results
```
- [ ] **Step 2: `test/integration/agent_composition_flow_test.dart`**：
  - 删 query_source/windows_python_query_gateway import；删 `_CountingResumableYoungGateway`（行 208-260）与 `DisposableQuerySourceGateway` 引用。
  - `_buildTestComposition`（行 543-565）：删 `gateway` 形参与 `queryGatewayFactory:` 实参。
  - 全部 `_CountingResumableYoungGateway()` 实例化点删除（如行 696/895/971/1019/1051/1108/1178/1416/1543/1570/1919/2166/2334/2457/2526/2592/2742/2809/2957/3012/3280/3713/3748/3876/3964 等）：igateway 仅惰性填充 → 删变量；断言网关行为 → 重写为无外部来源等价（如 disposeCalls 断言改检查 configService/secretStore dispose，或直接删）。
  - `_step1Script` 与依赖 second-class/young 的脚本段删除。
  - 其余本地组合/写/撤销/账号切换用例不动。
- [ ] **Step 3: `app_shell_test.dart`**：删 `_DisposableGateway` 与 `queryGatewayFactory` 注入、`LazyQuerySourceGateway` 测试（行 187-230 附近）；`compositionLoader` 注入改为不带 query 网关的 `AgentComposition.build` 调用。error 最多（14 处）。
- [ ] **Step 4: `agent_prompt_injection_test.dart`**：删 external tools 相关测试段与 `_maliciousSearchEnvelope`、`CampusSearchQueryRequest` 类型引用；`externalAgentTools(...)` 调用删除；`icourseConsent: true` 改为仅 gatling 用或删除。
- [ ] **Step 5: `agent_session_service_test.dart`**：
  - 行 248 的 `AgentUserActionType.youngLogin` action 用例删除或改写为 writeConfirmation。
  - **（审核加强 B-补6）catalog 转发相关测试**：F3 Step 4 删了 `_forwardsToSourceReferences`/`_catalogTools` 与 campus_entry → sourceReferences 转发分支后，依赖 catalog ref 被转发的测试会失败：
    - 行 1105-1134 `'source references are surfaced in the final view'`：`expect(terminal.sourceReferences, hasLength(1))`（1123）与 `single.kind, 'catalog'`（1124）改为 `expect(terminal.sourceReferences, isEmpty)`（外部工具退役后无 public citation），或整个测试方法删除。
    - 行 ~1440-1452 跨 run ref 测试：`expect(firstRefs, isNotEmpty)`（1452）依赖 `_canonicalLoop()`（含 `_FakeCatalogTool`）的 catalog ref 被转发——改为测本地 schedule ref 不跨 run 的等价（如改用纯 `_FakeScheduleTool` 的脚本并断言 `localActions` 而非 `sourceReferences`），或调整断言。
  - **保留**：`_FakeCatalogTool` 类（行 163-189）与 `_catalogBuilder`（行 923）本身可保留（测试本地 fake，仍能被调用与记录 toolName）；只检查 `sourceReferences` 转发结果的断言需改。行 1102/1715/4625 等只断言 `toolName`/`safeSummary` 含 `search_campus_catalog` 的用例仍通过（fake 仍执行），保留不动。
- [ ] **Step 6: `agent_chat_page_test.dart`**：行 1070 的 youngLogin action 改为 writeConfirmation 或不含 userAction。
- [ ] **Step 7: `local_agent_tools_test.dart`**：行 275/285 保留 jw；行 297/308/2124-2129 的 youngSchedule 删除或改写为单 jw 断言。
- [ ] **Step 8: `agent_configuration_service_test.dart`**（B3）：删 `setIcourseConsent` 用例（164-165、302），保留的只读断言不动。
- [ ] **Step 9: `sync_coordinator_test.dart`**：删除 youngSchedule 相关 polls/starts 断言；把 expecting `[jw, youngSchedule]` 改成 `[jw]`。**注意（审核加强）**：行 173 `await service.isAutomaticDue(SyncSource.youngSchedule, accountId)` 直接引用枚举成员——`SyncSource` 收敛为单 jw 后此行**编译失败**，必须删除整个依赖 youngSchedule 的测试方法（非仅改断言）。通查全文件所有 `SyncSource.youngSchedule` 与 `bridge.polls['youngSchedule']` 引用，逐个删除方法或改写为单 jw。
- [ ] **Step 10: `sync_page_test.dart`**：删除 youngSchedule 相关 start/cancel/state-key 断言。

- [ ] **Step 11: `agent_settings_page_test.dart`**（B-补2，审核新增）：删整个 `group('AgentSettingsPage iCourse consent', ...)`（行 588-605）——F4 删除了 consent UI 开关与 `setIcourseConsent`，该组 `find.byKey(const Key('agent-icourse-consent'))` 与 toggle 断言会失败。保留同文件其余 Agent 设置测试。
- [ ] **Step 12: `agent_context_builder_test.dart`**（B-补3，审核新增）：行 679-681 的 `toolNames` 列表删 4 个外部工具（`search_current_second_class_activities`/`search_icourse`/`search_campus_catalog`/`read_campus_detail`），改为仅本地工具；行 688-696 的 `expect(prompt, contains('正在报名的二课'))`/`'我已报名的二课'`/`'second_class'`/`'外部数据'`/`'本轮必须重新调用工具'` 断言——F3 重写 system prompt 后这些字符串不再存在，删除或改为本地数据等价新断言。`'course_summary'` 保留。
- [ ] **Step 13: `bridge_client_test.dart`**（B-补4，审核新增）：删 Bridge 查询协议测试段（`/queries`、`/query-jobs/*/events`、`/query-jobs/*/resume-login`、`/query-jobs/*/cancel`、`isA<BridgeQueryGateway>()` 断言，约行 300-345）——F1 Step 5b 删除了 `BridgeQueryGateway` 接口。保留 Bridge 集合（`/collect/jw`、`/capabilities`、`/health`）相关测试。
- [ ] **Step 14: `accounts_page_test.dart`**（B-补5，审核新增）：删 `'二课平台：上次同步成功'` 断言（行 134 附近）与相关 `ustc_young_schedule` seed（行 122-124）——F2 Step 5 删了 accounts_page 的"二课平台"文本。

### Task F6：M1 门验证（Flutter）

- [ ] `flutter analyze` 0 error。
- [ ] `flutter test` 全绿。
- [ ] 禁词 grep 只读（lib/test，排除 `icourse_consent` 列字段引用、`campusName`/`campus_affair`（数据库表名/列，属数据模型字段，非功能引用）、`generated_source_defaults.dart` 生成文件、doc 注释中的退役说明、fixture 文件名）：
```bash
cd /home/ubuntu/107_ustc_assistant/app
grep -rInE "young|icourse|campus" lib test \
  | grep -vE "icourse_consent|campusName|campus_affair|generated_source_defaults|///|// " \
  | grep -vE "source_bundle/(positive|negative)|source-bundle|young-empty-window|young-with-schedule" \
  || echo "CLEAN"
```
（N1 修正：排除 doc 注释行 `///` 与 `// `，避免 `agent_tool.dart` 265/266/360、`run_reference_store.dart:8`、`agent_session_service.dart:142/1892` 等纯注释引用误报；这些注释是退役说明，保留。）

- [ ] **N1 补充：`lib/features/schedule/presentation/event_detail_page.dart:127`** `'ustc_young' => '二课平台'` 是真代码分支（非注释）。最小修：删该 switch arm（外部来源退役后 eventType 恒为本地/jw）。确认 `schedule_grid_item.dart` 的 `eventType` 仅剩 `ustc_jw/course|exam` 与个人事件。
- [ ] **S3 补充：`lib/features/settings/presentation/official_websites_page.dart`**（行 27/33/37 的"二课平台/教务处/财务处"链接）——保留为纯 url_launcher 页面（不涉及任何数据链路/Agent），M1 不删；若删除则在 M1 门内说明。倾向保留（功能收敛指数据链路，不含网站快捷入口文档）。
- [ ] 确认无残留 `SyncSource.youngSchedule` 引用（grep `SyncSource.youngSchedule` 应为 0 行）。

### Task F7：收尾与提交

- [ ] Python + Flutter 全量门（M1 门）：上面全部绿。
- [ ] 逐个提交（squash 为 feature 提交），提交信息遵循 `refactor(webview-minimal): M1 ...`。

---

## 已关闭的决策（O-1 提交给审核后的结论）

- **O-1（关闭→bump）**：`AgentSystemPrompt.version` **bump 到 9**，新增 `version9` 常量；base `version4` 文本收敛为教务+本地 minimal 版，v5/v8 逐级内插保持。语义版本=文本内容。
- **O-2（关闭→保留）**：`SettingsService.pythonPath/setPythonPath` **保留**——`sync_page.dart:47/52` 用 `pythonPath()` 启动 Bridge（`PythonLocator`），Bridge 保留到 M3（原则 1）。删除会编译失败。见 F2 Step 4。
- **O-3（关闭→保留循环）**：`for (final source in SyncSource.values)` 保留（单元素循环，天然只 jw），语义正确无需改。
- **O-4（关闭→不 bump）**：`defaultSystemPromptVersion = 3` 是 DB 种子默认值，M1 不随 prompt 文本 bump（保持 3）；prompt 文本收敛不改变种子。
- **O-5（关闭→仅留 jw）**：`settings_page.dart` 只保留教务（JW）开关，删 `youngEnabled` 与 `setSourceEnabled('ustc_young_schedule')`。"源开关"UI 本身保留（教务仍可关/开）。
- **O-6（确认→豁免）**：young 契约 fixture 文件名豁免（plan §4.3 已声明保留为 schema 兼容输入）。
- **B2（已落实到任务）**：`agent_session_service.dart` 外部 catalog 转发（`_catalogTools`、`campus_entry` → sourceReferences）删除，已在 F3 Step 4。
- **N1（已落实到 F6）**：`event_detail_page.dart:127` young arm 删除；禁词 grep 排除 `///`/`// ` 注释行与 fixture 文件名。
- **S3（保留声明）**：`official_websites_page.dart` 纯 url_launcher 快捷入口，不涉数据链路，M1 保留不删；已在 F6 注明。

---

## 审核轮记录（review → fix 循环）

### 第 1 轮审核（主 agent 独立验证 + 子 agent 深度审核）

主 agent 对全部 P1-P4 / F1-F7 的文件路径、符号锚点、行号逐项 grep 验证，确认计划锚点与 HEAD `c7637ad` 高度吻合。发现并落实以下补充：

- **B-补1（F1 Step 5b）**：`bridge_client.dart` 清理 `BridgeQueryGateway` 接口（行 107-118）、`BridgeClient implements` 去掉 `BridgeQueryGateway`（行 179）、查询方法（行 329+）、`startCollection` young 三元（行 270-272）收敛为 `/collect/jw`。
- **B-补2（F5 Step 11）**：`agent_settings_page_test.dart` 删 iCourse consent 测试组（行 588-605）——F4 删 consent UI 后 `findsOneWidget`/toggle 断言失败。
- **B-补3（F5 Step 12）**：`agent_context_builder_test.dart` 收敛工具名列表（行 679-681）与二课/外部数据断言（行 688-696）——F3 重写 prompt 后这些字符串不再存在。
- **B-补4（F5 Step 13）**：`bridge_client_test.dart` 删 Bridge 查询协议测试（行 ~300-345）——F1 Step 5b 删了 `BridgeQueryGateway`。
- **B-补5（F5 Step 14）**：`accounts_page_test.dart` 删"二课平台"断言（行 ~134）与 `ustc_young_schedule` seed（行 122-124）——F2 Step 5 删了 accounts_page 文本。
- **全局约束补充**：数据模型字符串保留清单（`campusAffair`、`young_registered_schedule` 契约、`'ustc_young'` DB 事件 source 值等）与 Python 测试基数澄清（394 → ~153）。

### 第 2 轮审核（聚焦 must-fix 完整性复核）

子 agent 聚焦"计划修订后是否仍有 analyze 编译失败 / test 失败缺口"，发现两处：

- **B-补6a（F2 Step 1 修正）**：`sync_coordinator.dart:512` 的 `_ensureConfig(SyncSource.youngSchedule,...)` 是 lib 字面量枚举引用——原计划 N3 误把行 344（用循环变量 `source`，无需改）当作需删项；真正编译失败点在 `_persistCapabilities` 行 511-515，必须删该 young `_ensureConfig` 块。已修正 F2 Step 1。
- **B-补6b（F5 Step 5 加强）**：`agent_session_service_test.dart` 除行 248 youngLogin 外，行 1105-1134（catalog 转发 `hasLength(1)`/`kind:'catalog'`）与行 ~1440-1452（跨 run `isNotEmpty`，依赖 `_canonicalLoop` 的 catalog ref 转发）在 F3 Step 4 删转发后会失败。已加强 F5 Step 5。

第 2 轮另确认：Python 侧 P1-P4 无残留缺口（所有 deleted-module 引用均在被删/被改文件内）；其余 `SyncSource.youngSchedule`/`setIcourseConsent`/外部工具符号引用均已由 F1-F5 覆盖。
