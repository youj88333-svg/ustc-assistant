# Plan：极简 WebView 原生重构（本环境执行口径，2026-08-19 修订版）

> 分支：`refactor/webview-minimal`（head == main，后续工作均在本分支）
> 说明：本文是 `refactor/webview-minimal` 分支的执行口径；AGENTS.md 的
> “六层阶梯 / M0–M8 / rewrite-flutter-native”是旧目标环境路线，本分支不采用。

## 0. 已拍板的原则

1. **Bridge 不提前删**：M1 删除 young/icourse/campus 功能时，保留 JW 的
   `bridge_client.dart`、`python_locator.dart`、Python Bridge。待 Dart WebView
   采集与 SourceBundle 对齐金标准后，再做退役。
2. **SourceBundle 1.0 与 schema 保持不变**：功能关闭，契约不关闭；young 的
   SourceBundle fixture 仅作为 schema 兼容性测试输入保留。
3. **教务学期暂时写死 `461 / 2026fall / 2026 秋季学期`**：沿用
   `config/source-defaults.json` 与 `generated_source_defaults.dart`。月份规则、
   学期列表抓取和相关设置以后作为 addition 添加。
4. **不引入 C2/C3 容器与 sourceGeneration/resetEpoch 等复杂并发模型**：只做
   单活跃采集作业闸门和最小 `SourceCollectionGateway` 接口。
5. `agent_settings.icourse_consent` 字段用于其他功能；删除 iCourse UI/工具时不改
   schema、不删列，只标记为退役入口（若将来清理需走正式 migration）。
6. **Agent 删除/生命周期工具当前分支已实现**：本分支只做外部工具删除与本地
   删除/生命周期工具的回归固化，不“新增删除工具”。

## 1. 环境事实（已实测，同基线）

- Flutter 3.44.5 / Dart 3.12.2：`/home/ubuntu/flutter`；匹配项目 sdk ^3.12.2。
- `flutter analyze`：基线无 error（15 个 info/warning）。`flutter pub get` 已可用。
- sqlite3 离线测试：pubspec hooks 用系统 `/lib/x86_64-linux-gnu/libsqlite3.so.0`。
- Python oracle：conda `ustc_assistant`（3.10.20）可用，教务 SourceBundle 17 项通过。
- 本 VM 不能构建 Windows/iOS/Android 二进制，也不访问真实学校网站。

## 2. 目标（简化到“教务 + 基础 Agent”）

1. 删除二课（young）、评课社区（icourse）、教务/财务公开目录（campus）的全部
   用户功能、CLI/Bridge 查询命令、Agent 外部工具。
2. 教务采集新增强路径：Flutter 原生 WebView 采集，产出 `SourceBundle 1.0`；
   Python Playwright 保留为金标准 oracle 和 M3 完成前的运行通道。
3. Agent 工具收敛到“本地只读 + 本地受控写/删除/生命周期”，删除一切外部按需来源。
4. 排查并落地三端可编译的静态接口；实际构建交给外部有 SDK 的机器。

## 3. 新里程碑

| 编号 | 内容 | 出口 |
|---|---|---|
| M0 | 基线：analyze 绿；DB/agent 关键测试绿 | 已完成 |
| M1 | 删除 young/icourse/campus；保留 JW Bridge；删除外部 Agent 工具与 UI；清理 sync 双来源 | Python unittest / flutter analyze+test 全绿 |
| M2 | Dart JW 规范化 + SourceBundle 构造等价，Python oracle 对比 | Dart fixture 与 Python bundle 逐字段/digest 对齐 |
| M3 | `SourceCollectionGateway` 接口；WebView 采集器 + CAS 会话；Python 通道兜底 | 平台无关 collector 单测通过 |
| M4 | Agent 外部工具清空后的本地删除/生命周期工具回归 | agent delete/lifecycle flow 测试绿 |
| M5 | 跨平台凭据/通知/WebView 权限适配；静态分析 | 本机 analyze/test 绿；三端 build 错误清单落档 |
| M6 | 外部机器 windows/apk/ios 构建与真实人工验收 | 交给有 SDK 机器 |

## 4. M1 具体拆解

### 4.1 Python 删除（保留 JW + config + contracts）

删除：

- `src/ustc_assistant/sources/{young,icourse,campus}/`
- `tests/{young,icourse,campus}/`
- `tests/fixtures/{young,icourse,campus}/` 查询/网页 fixture（SourceBundle 的 young
  fixture 仅保留，供契约测试）

修改：

- `cli.py`/`__main__.py`：仅保留 `collect jw` 与 `config generate-flutter-defaults`。
- `bridge/query_contracts.py`、`bridge/query_jobs.py`：删除。
- `bridge/server.py`：删除 `/queries`、`/query-jobs/*`、`queryProtocolVersion`、
  `queryTypes` 和相关 query 导入；只保留 `/health`、`/capabilities`、`/collect/jw`、
  `/login/resume`、`/jobs/{id}/events`、`/shutdown`。
- `bridge/jobs.py`：删除 `YoungCollectionRequest`/`start_young_schedule`。
- `pyproject.toml`：去除不再需要的 `requests`/`beautifulsoup4`（jw 只依赖
  `playwright`/`jsonschema`）。

保留：

- `config/source-defaults.json` 与 `config.py` 的 JW 三元组。
- `contracts/` 全部。

### 4.2 Flutter 删除（保留 JW 同步主链路）

删除文件：

- `lib/features/agent/data/windows_python_query_gateway.dart`
- `lib/features/agent/domain/query_source.dart`（外部查询 envelope 全删；本地
  Agent 不再需要）
- `test/features/agent/external_agent_tools_test.dart`
- `test/features/agent/windows_python_query_gateway_test.dart`
- `test/fixtures/query_results/`

修改：

- `router.dart`：Agent 组合改为无 `QueryGatewayFactory`；`buildRouter` 与
  `_buildWindowsAgentComposition` 移除 Python query gateway 启动。
- `agent_composition.dart`：删除 `LazyQuerySourceGateway`、externals、young login
  resume、`SourceQueryGateway` 相关注入。
- `agent_tools.dart`：删除 `SearchCurrentSecondClassActivitiesTool`、
  `SearchIcourseTool`、`SearchCampusCatalogTool`、`ReadCampusDetailTool`、
  `externalAgentTools()`、相关 allowless 常量与 `_YoungQueryInvocation`/
  `_collectQueryEvents`/`_map*` 帮助函数。
- `agent_system_prompt.dart`：重写为 v8/minimal（仅教务课程/考试 + 本地日程/Task/
  PlanBlock/冲突/同步/历史 + 本地写/删除工具规则）。
- `agent_grounding_policy.dart`：删除二课/评课/campus 规则；外部工具 pipeline 移除。
- `agent_configuration_service.dart` 与 `agent_settings_page.dart`：删除 iCourse
  user-visible consent；保留 DB 列与 service 状态读取（退役不迁移）。
- `sync_state.dart`：`SyncSource` 仅 `jw`。
- `sync_coordinator.dart`/`sync_page.dart`/`settings_page.dart`/`accounts_*.dart`
  全部改为单 JW 来源。
- `domain/agent_models.dart` 及其他仍引用 QuerySource 的 export 线（如有）删除。

### 4.3 M1 门

- Python：`python -m unittest discover -s tests -v` 绿、`compileall` 绿。
- Flutter：`flutter analyze` 无 error、`flutter test` 全绿。
- Grep：`young/icourse/campus`（排除 `campusName`、`campus_affair`、
  `icourse_consent` 退役列、生成文件与注释说明）无活跃功能引用。
- 运行 `python -m ustc_assistant collect jw --help` 和
  `python -m ustc_assistant config generate-flutter-defaults --help` 验证 CLI。

## 5. M2–M3 关键设计

- 新增 `lib/features/sync/native/jw_course_normalizer.dart`、
  `jw_exam_parser.dart`、`jw_source_bundle_builder.dart`。
- 复用 fixture：`tests/fixtures/jw/course-datum.json`、`exam-page.html`、
  `app/test/fixtures/source_bundle/positive/jw-*.json`。
- 对比项：sourceRecords/calendarEvents/courseSeries/scheduleRelations 各字段、
  snapshot.scope/manifest、canonical digest。
- WebView 不在本机跑真实学校页面；采集器通过注入的 `JwWebPage` / fake 完成
  状态机测试。
- 课程/考试身份 hash 必须与 Python 完全一致：
  - 课程 identity tail：`lesson:group:date:start:end:collision_discriminator`
  - 考试 identity：`course_code + stable_hash([code, exam_type, start, end, room,
    building, campus])`。
- `SourceCollectionGateway` 签名先冻结：
  ```dart
  abstract interface class SourceCollectionGateway {
    Stream<SourceCollectionEvent> startJwCollection({
      required String accountId,
      required JwSemesterConfig semester,
    });
    Future<void> resumeLogin(String jobId, {String? password});
    Future<void> cancel(String jobId);
  }
  ```

## 6. M4：只删外部工具 + 固化已有删除工具

当前已存在：`update_event`（含 cancel/reopen/delete/restore 与重复 scope）、
`update_task`、`update_plan_block`、`delete_schedule_relation`、`clear_reminder`、
`clear_user_overlay`、`unlink_task_event`、`reset_permission_policy`、
`undo_last_action`。

M4 只做：

- 删除外部工具及 query 生态；
- 系统提示词、grounding policy 与工具 registry 收敛；
- 增补 `agent_delete_tools_test.dart` 覆盖本地删除/恢复/清项目/撤回与 school
  课程考试拒绝删除。

## 7. 已落成本分支的环境改动（首个 commit 候选）

- `app/pubspec.yaml`：`hooks.user_defines.sqlite3` 离线单元测试用系统 sqlite。
- `app/pubspec.lock`：pub.dev 解析后的锁。
- `.gitignore`：`app/test/goldens/failures/` 不进入版本库。
