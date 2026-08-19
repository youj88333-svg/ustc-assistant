# Plan：极简 WebView 原生重构（本环境执行口径）

> 分支：`refactor/webview-minimal`（head == main，后续工作均在本分支）
> 状态说明：本文件面向当前环境。AGENTS.md 中"六层阶梯/M0-M8/ rewrite/flutter-native"
> 是旧目标环境的路线，本环境不采用其阶段编号。

## 1. 环境事实（已实测）

- Flutter 3.44.5 / Dart 3.12.2 已解压到 `/home/ubuntu/flutter`（匹配项目 sdk ^3.12.2）。
- `flutter analyze`：无 error（仅 15 个 info/warning，均为既有代码风格问题）。
- `flutter pub get`：可用（曾 502，换 `PUB_HOSTED_URL=https://pub.dev` 成功后锁定 144 依赖）。
- 离线单元测试已打通：本项目 `flutter test` 首次因 sqlite3 原生 hook 从
  `github.com/simolus3/sqlite3.dart` 下载 `.so` 失败（本 VM 无法访问 github）。
  通过 pubspec `hooks.user_defines.sqlite3.source=system` + `name_linux=绝对路径`
  改用系统 `/lib/x86_64-linux-gnu/libsqlite3.so.0`，DB/Drift 测试 7/7 通过。
- Python oracle：conda env `ustc_assistant`（3.10.20）已建，`tests.jw.test_source_bundle`
  17/17 通过（教务 SourceBundle 金标准）。
- 平台矩阵（本 VM）：
  - Windows / iOS / Android 二进制：**不可构建**（无 Windows+Xcode+Android SDK/JDK）。
  - 纯 Dart 的 analyze / unittest / widget / flow：**可跑**。
  - 真实学校登录与采集：不可自动验证。

## 2. 目标（简化到"教务 + 基础 Agent"）

1. 删除二课（young）、评课社区（icourse）、教务/财务公开目录（campus）全部功能。
2. 教务采集从 Python（Playwright/Bridge/CLI）改为 Flutter 原生 WebView 采集，
   保留 SourceBundle 1.0 契约。
3. Agent 工具瘦身 + 完善删除/生命周期工具。
4. 尝试三端（Windows/Android/iOS）代码达成可编译；本机只保证 Dart 层可测试。

## 3. 不动的红线

- main 不动；所有改动只提交到 `refactor/webview-minimal`。
- SourceBundle 1.0 与 source-bundle schema 保持不变（若源头纯 JW，仍保留唯一来源协议）。
- 自动测试不得访问学校网站；所有 WebView 采集以 fixture + python oracle 对比。

## 4. 方案拆解

### 4.1 删除非保留功能（第一阶段，先行可做）

Python 侧：
- 删除 `src/ustc_assistant/sources/{young,icourse,campus}/`
- 删除 `tests/{young,icourse,campus}/`
- `cli.py` / `__main__.py` 中只保留 `collect jw`；`config.py` 保留学期三元组；
  删除 `icourse`、`campus`、`young` 相关命令。

Flutter 侧：
- 删除 `lib/features/sync/data/{bridge_client,python_locator}.dart`；
- 删除 `lib/features/agent/data/windows_python_query_gateway.dart`；
- 删除 Agent 外部工具 `search_current_second_class_activities` / `search_icourse` /
  `search_campus_catalog` / `read_campus_detail`（含 schema/description/测试 fixture）；
- 删除 `app/test/fixtures/query_results/{young_enrolment,icourse,campus_*}.json` 等。

### 4.2 教务 WebView 原生采集（核心重构）

新增 `lib/features/sync/native/`：
- `JwWebViewCollector`：用 `webview_flutter`（Win WebView2 / Android WebView / iOS
  WKWebView）承载教务 CAS 登录会话，注入 JS 拦截 `get-data` 与 `datum` 响应，
  还原 `course_datum` 与 `exam_html`（与 Python `collect_sources` 等价）。
- 产物仍是 `SourceBundle 1.0`（`build_jw_source_bundle` 的 Dart 对应实现，
  用 conda oracle 17 项测试作为金标准逐字段对比）。
- Windows 插件不引入 Dart 侧 bridge；替代 `bridge_client.dart` 的数据流为
  纯 Flutter `Channel`。移动端复用同一 collector 抽象，平台仅替换凭据/WebView 注入。

### 4.3 Agent 工具收敛

- 只读本地工具保留：schedule/tasks/planblocks/reviews/conflicts/sync/action-history。
- 删除一切外部按需来源工具（见 4.1）。
- 写 + 删除工具：补齐/保留
  `create/update/cancel/reopen/delete/restore event`、`create/update/delete task`、
  `plan_block` 生命周期、`clear_reminder`、`clear_user_overlay`、
  `unlink_task_event`、`undo_last_action`、`reset` 类管理操作，遵守"学校课程/考试
  只本地隐藏不物理删除、事务性审计、用户确认门"既有安全规则。

### 4.4 三端可编译（尝试）

- 抽象 `CredentialProtector`：已有接口；新增 Android Keystore / iOS Keychain
  实现，Windows 保留 DPAPI（`impl_io.dart` 条件导入）。
- `webview_flutter` 已存在于 pub 缓存，三端插件齐备。
- Android 构建需外部 JDK17 + Android SDK；iOS 需 macOS/Xcode。本机交付
  `analyze/test` 通过 + 平台适配器代码，实际产物由用户在有 SDK 的机器构建。

## 5. 里程碑（本分支）

| 序号 | 内容 | 出口 |
|---|---|---|
| M0 | 分支基线：analyze 绿 + DB/agent 关键测试绿（已完成环境准备） | ✓ DB 测试 7/7 |
| M1 | 删除 young/icourse/campus（Python+Flutter+测试） | analyze/test 全绿，删后无残留引用 |
| M2 | JW Dart 规范化源 + Skill：把 python oracle 转译为 Dart，fixture 对比一致 | Dart unittest 17/17 对齐（或显式登记差异） |
| M3 | WebView 采集引擎 + CAS 会话（Win/移动接口） | 平台无关 collector 单测通过 |
| M4 | Agent 工具删除瘦身 + 生命周期/删除工具单测 | agent flow 测试绿 |
| M5 | 三端适配器编译层（凭据/WebView/通知） | flutter analyze 各 target 无 error |
| M6 | 外部机器打点：windows/apk/ios | 交给有工具链的机器 |

## 6. 已落成本分支的环境改动（首个 commit 候选）

- `app/pubspec.yaml`：`hooks.user_defines.sqlite3` 离线单元测试用系统 sqlite。
- `app/pubspec.lock`：pub.dev 解析后的锁（144 deps，Flutter 3.44.5 匹配）。
- `.gitignore`：确认 `app/test/goldens/failures/` 不进入版本库。

