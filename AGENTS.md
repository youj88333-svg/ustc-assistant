# USTC Assistant Agent Guide（minimal 分支版）

> 适用范围：`refactor/webview-minimal` 分支。本分支最小实现：只保留教务（JW）+
> 日程表 + Agent（本地只读 / 受控写 / 生命周期）。二课（young）、评课（icourse）、
> 校园公开目录（campus）的用户功能与外部 Agent 来源工具已随 M1 删除。
> 本文件不再描述旧"六层阶梯 M0–M8 / rewrite-flutter-native"路线；本分支执行口径见
> `docs/plan-webview-minimal.md` 与各 `plan-webview-minimal-m{N}.md`。

## 目标

开发一个面向中国科学技术大学的本地优先校园学习生活助手。当前分支为整体重构的
**最小实现**：删掉二课/评课/校园公开目录，仅保留教务采集 + 本地日程/Task/PlanBlock
+ 本地 Agent 读写能力。教务采集的目标运行通道是 Flutter 原生 WebView2
（`docs/plan-webview-minimal-m7-webview2.md`），Python Bridge 保留为兜底通道，不提前删除。

## 当前能力

1. 教务系统：指定学期（当前为 `461 / 2026fall / 2026 秋季学期`）课程、考试安排和
   统一日程导入包（SourceBundle 1.0）。
2. Windows App：账号与同步、七日周课表、个人日程、Task/PlanBlock、冲突与用户覆盖、
   提醒、操作历史、设置和一步撤回。
3. Agent（本地读写 + 生命周期）：15 个本地只读工具 + 20 个受控写/生命周期工具（11 写 +
   9 生命周期/清除/撤回 + 管理态只读），全部经审批门按风险分级确认；无任何外部按需来源
   工具。API Key 由 `CredentialProtector`（Windows DPAPI / fallback）保护；Agent 不能发起
   同步或执行任何外部写操作。系统提示词版本 9，grounding policy 只含本地规则。
4. 原生 WebView2 采集（已接入，M7）：`app/lib/features/sync/native/` 已有 Dart
   规范化 + `JwCollector` + `JwWebViewAdapter`（真实实现）+ `NativeJwGateway`
   （BridgeGateway 兼容壳），产物与 Python oracle 对齐（digest `f858a385…`）；
   真实校网人工验收仍外置。

## 项目结构与当前阶段

### 实现状态

- Python 数据层已收敛为 JW 单链路：`src/ustc_assistant/sources/` 仅 `jw/`；
  `bridge/` 仅保留 `/health`、`/capabilities`、`/collect/jw`、`/login/resume`、
  `/jobs/{id}/events`、`/shutdown`；CLI 仅 `collect jw` + `config generate-flutter-defaults`。
- `app/` 已实现 Flutter Windows 首版（Drift/SQLite、账号分区、同步、周课表、个人日程、
  Task/PlanBlock、提醒、历史、设置及测试）。Android/iOS 只有平台脚手架，采集适配器未实现。
- `app/lib/features/sync/native/`：M2（`jw_course_normalizer.dart` / `jw_exam_parser.dart` /
  `jw_source_bundle_builder.dart`）、M3（`source_collection_gateway.dart` /
  `jw_collector.dart` / `jw_web_page.dart`）、M5（`jw_webview_adapter.dart` stub）。
- 真实人工验收（真实校园网/账号/API Key）尚未执行；清单见
  `docs/acceptance/read-only-agent.md`（minimal 适用边界已注记）。

### 目录职责

```text
config/
  source-defaults.json         教务学期默认三元组（461/2026fall/2026 秋季学期）
schemas/
  source-bundle-1.0.schema.json  SourceBundle 1.0 正式契约
src/ustc_assistant/
  sources/jw/                  教务采集（collector/course/exam/service/source_bundle）
  bridge/                      Windows Flutter 使用的认证回环采集 Bridge（fallback）
  contracts/                   契约校验与 schema 导出（app assets 生成源）
  config.py                    JW 学期配置读取
  cli.py / __main__.py         统一 CLI（仅 collect jw + config）
tests/                         Python 单测（JW + bridge + contracts + config，140 项）
app/
  lib/core/                    Drift 数据库、安全（CredentialProtector）与北京时间工具
  lib/features/                账号、同步、导入、日程、Task、提醒、历史、设置与 Agent
  lib/features/sync/native/    原生 WebView2 采集器（M2/M3/M5/M7）
  lib/features/agent/          本地只读 + 受控写/生命周期 Agent
  test/                        Flutter 单元、数据库、Widget、Golden 和流程测试
  windows|android|ios/         Flutter 平台工程；当前真实运行目标是 Windows
  packages/webview_flutter_windows_secure/  WebView2 插件（M7 引入，可自足提取）
docs/
  plan-webview-minimal.md      总路线（M0–M6）
  plan-webview-minimal-m{N}.md 各里程碑计划（m1–m7，m7=原生 WebView2）
  m5-three-platform-build-analysis.md  三端构建错误静态分析
  m6-external-machine-handoff.md  M6 外部机器交接手册
  m6-refactor-final-verification.md  M0–M5 静态验证快照
  acceptance/read-only-agent.md  Agent 真实验收清单（minimal 注记版）
  data-sources/{jw,source-bundle-v1}.md  JW 与 SourceBundle 契约
  schedule-data-model.md       本地日程领域模型（契约类，保留）
  plan-webview-minimal-doc-slimming.md 文档精简计划
```

### 数据流（当前）

```text
学校/教务网站
  -> [原生 WebView2 采集器 | Python Bridge fallback]
  -> SourceBundle 1.0
  -> Flutter ImportService
  -> Drift/SQLite + UserOverlay
```

同一来源同一时刻只允许一个通道在跑、在写库（原生 WebView2 与 Python Bridge fallback
二选一）。

### 新 Agent 阅读和修改路径

- 接手项目：先读 `docs/plan-webview-minimal.md`，再读 `docs/m6-external-machine-handoff.md`
  与 `docs/m6-refactor-final-verification.md`，然后看 `app/lib/features/` 与 `tests`。
- 教务采集/WebView：先读 `docs/plan-webview-minimal-m7-webview2.md`，再读
  `app/lib/features/sync/native/` 与 `src/ustc_assistant/sources/jw/`。
- SourceBundle 迁移：先读 `docs/data-sources/source-bundle-v1.md`、`schemas/` 与
  `tests/fixtures/source-bundle/`、`app/test/fixtures/`，再同步修改 Python 生产者与
  Flutter 消费者；不要让 Flutter 兼容 legacy。
- Agent 工具修改：先读 `app/lib/features/agent/application/agent_tools.dart` /
  `agent_write_tools.dart` / `agent_lifecycle_tools.dart` 与对应测试。
- `tmp/`、浏览器 Profile、原始响应只用于本机研究，不能作为稳定输入或提交内容。

## 安全红线（本分支内化；原 `refactor-docs/07-constitution.md` 已按方案 A 删除）

1. 隐私与账号隔离：凭据不经源码/日志/截图；账号按本地分区隔离；不记录/不打日志完整
   URL 的 query、CAS ticket、Cookie、DOM、账号原文或私人课表。
2. 契约：SourceBundle 1.0 与 schema 不随功能删除而关闭（功能可关，契约不关）；
   young 的 SourceBundle fixture 仅作 schema 兼容性测试输入保留。
3. 一源一通道：同源同时只跑一个通道（原生 WebView2 或 Python Bridge fallback），
   不并行、不双写。
4. 时间统一 `Asia/Shanghai`；教务学期 ID（461）不得按年份或名称推算，必须来自
   `config/source-defaults.json`。
5. 网站契约变化时明确失败，不返回部分数据冒充完整结果；修改来源行为先加回归测试。
6. 过程纪律：自动测试不代替人工验收；不把自动测试/静态验证通过写成"真实验收通过"。

## 开发规则

- Python 仅用于 Bridge fallback 与 oracle，使用 Conda 环境 `ustc_assistant`（≥3.10）。
- 手动改 `config/source-defaults.json` 后必须重新生成提交文件：
  `python -m ustc_assistant config generate-flutter-defaults`，勿手改生成文件。
- DB 退役列（`icourseConsent` 等）不删、不做非正式 migration；清理需走正式迁移。
- 平台差异收敛到 `lib/core/security/credential_protector_factory.dart` 等隔离点，
  不在 lib 顶层散落平台专属直构；WebView 平台细节隔离在 `native/`。
- 目标态（M7 原生 WebView2）不破坏 minimal 现有 analyze/test 基线优先顺序。

## 验证

```powershell
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
Push-Location app
E:\flutter\flutter\bin\flutter.bat analyze     # 期望 0 error
E:\flutter\flutter\bin\flutter.bat test        # 期望 1360 pass / 7 fail(基线)
E:\flutter\flutter\bin\flutter.bat build windows --release
Pop-Location
```

7 项基线失败（1 DB migration 健壮性缺口 + 6 golden 字体环境差异）为 M0 起已知项，
处置见 `docs/m6-external-machine-handoff.md` §6。

## 里程碑总览（本分支）

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M0 | 基线环境 + 计划采纳 | ✅ |
| M1 | 删外部功能/工具，保留 JW Bridge，递归 sync 到 jw | ✅ |
| M2 | Dart JW 规范化 + SourceBundle，Python oracle 对齐 | ✅ |
| M3 | SourceCollectionGateway + 平台无关采集器 | ✅ |
| M4 | Agent 删除/生命周期工具回归固化 | ✅ |
| M5 | 跨平台凭据/通知/WebView 适配（静态接口） + 三端 build 错误清单 | ✅ |
| M6 | 外部机器三端构建 + 真实验收（本分支只交手册+快照） | 📋 交接 |
| M7 | 原生 WebView2 接入（文档 `plan-webview-minimal-m7-webview2.md`） | ✅ 已完成（真实验收外置） |

## 当前边界

- 原生 WebView2 采集已接入（M7）：`JwWebViewAdapter` 真实实现 + `NativeJwGateway`
  为默认通道；真实校网人工验收仍外置（见 `m6-external-machine-handoff.md` §8.4）。
- 不做 C++ 会话持久化：重启后需重新登录（已知边界，不阻塞日常使用）。
- Android/iOS 真实 WebView 与构建仍留外部机器（M5 静态接口 + stub）。
- Python Bridge 未删除，保留为 fallback 开关（`kUsePythonBridgeFallback`）。
