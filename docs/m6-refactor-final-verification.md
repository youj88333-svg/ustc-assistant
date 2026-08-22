# M6 最终验证快照：M0–M5 重构最终状态（本 VM）

> 分支：`refactor/webview-minimal`
> 依据：`docs/plan-webview-minimal-m6.md` §2
> 产出机器：本 VM（无 SDK、无外网）。本文档记录本 VM 在 M6 提交前对当前 HEAD 实测
> 的静态验证快照，作为 M0–M5 重构的最终状态基线。真实三端构建与人工验收见
> `docs/m6-external-machine-handoff.md`。

---

## 1. 分支与提交历史

- **分支**：`refactor/webview-minimal`
- **M6 提交前 HEAD**：`25ec61a`（`docs(refactor): M5 detailed plan —
  cross-platform credential/notification/WebView adaptation`）
- **M0 基线**：`947ff2f`（`chore: baseline environment + webview-minimal plan
  (branch only, main untouched)`）+ `c7637ad`（`docs(refactor): adopt webview-minimal
  plan revision (plan-only, no implementation yet)`）

### 1.1 M0–M5 提交链（`git log --oneline` 实测，新→旧）

```
25ec61a docs(refactor): M5 detailed plan — cross-platform credential/notification/WebView adaptation
744b127 test(webview-minimal): M5 — notification adapter all-params type assertions + stub comment fix
23a4af0 docs(refactor): M5 T4 — three-platform build error analysis
6a8c5a3 feat(webview-minimal): M5 T3 — JW WebView adapter stub
94bfefc feat(webview-minimal): M5 T2 — cross-platform notification settings
4c8b75e feat(webview-minimal): M5 T1 — cross-platform credential protector factory
452f308 test(webview-minimal): M4 — agent delete/lifecycle tools regression consolidation
98a548d docs(refactor): M4 detailed plan — agent delete/lifecycle tools regression consolidation
cd2e126 feat(webview-minimal): M3 — SourceCollectionGateway + platform-agnostic JW collector state machine
15cdf57 docs(refactor): M3 detailed plan — SourceCollectionGateway + platform-agnostic JW collector state machine
e89cb73 feat(webview-minimal): M2 — Dart JW normalizer + SourceBundle builder, Python oracle parity
df126d1 docs(refactor): M2 detailed plan — Dart JW normalizer + SourceBundle builder, Python oracle parity
323d989 refactor(webview-minimal): M1 F6 — accessibility/golden test fixups + N1 event_detail young arm
921262b refactor(webview-minimal): M1 F5 (complex tests) — strip query-gateway seam from 3 large test files
4f707fb refactor(webview-minimal): M1 F5 (simple tests) — delete external test files, fix simple test refs
eaf5fbf refactor(webview-minimal): M1 F4 — retire iCourse consent, remove Agent login UI
ebabaf0 refactor(webview-minimal): M1 F3 — router no QueryGateway, system prompt v9, grounding policy, session service catalog forwarding removed
cfc7cb0 refactor(webview-minimal): M1 F2 — sync UI/settings/accounts single-JW
5168f1c refactor(webview-minimal): M1 F1 — delete external query gateway/domain/tools, collapse sync to jw, clean bridge_client
e754f09 docs(refactor): M1 plan revision after review loop (B-补1~6) + handoff doc
6df7d9b refactor(webview-minimal): M1 Python — delete young/icourse/campus + Bridge query protocol, collapse CLI to jw+config
c7637ad docs(refactor): adopt webview-minimal plan revision (plan-only, no implementation yet)
947ff2f chore: baseline environment + webview-minimal plan (branch only, main untouched)
```

### 1.2 各里程碑代表提交

| 里程碑 | 代表提交（feat/test） | docs 提交 |
|---|---|---|
| M0 基线 | `947ff2f`（环境+分支基线） | `c7637ad`（采纳 plan 修订） |
| M1 删外部工具 + 保留 JW Bridge | `5168f1c`(F1) → `323d989`(F6)，含 `6df7d9b`(Python 删) | `e754f09` |
| M2 Dart JW 规范化 + oracle 对齐 | `e89cb73` | `df126d1` |
| M3 SourceCollectionGateway + 采集器 | `cd2e126` | `15cdf57` |
| M4 删除/生命周期工具回归固化 | `452f308` | `98a548d` |
| M5 跨平台凭据/通知/WebView 适配 | `4c8b75e`/`94bfefc`/`6a8c5a3`/`744b127` | `23a4af0`/`25ec61a` |

---

## 2. 静态验证结果（M6 提交前实测）

> 以下命令在本 VM 于 HEAD `25ec61a` 实测。命令与输出原样记录，未从 plan 复制。

### 2.1 Flutter analyze

```bash
cd /home/ubuntu/107_ustc_assistant/app
/home/ubuntu/flutter/bin/flutter analyze 2>&1 | tail -3
```

实测末尾输出：

```
   info • Uses 'await' on an instance of 'List<Reminder>', which is not a subtype of 'Future'. Try removing the 'await' or changing the expression • test/features/tasks/plan_block_undo_test.dart:831:28 • await_only_futures

15 issues found. (ran in 2.0s)
```

**结果：0 error / 15 issues**（其中 12 info + 3 warning）。逐项 severity 统计
（`grep -oE "(info|warning|error) •" | sort | uniq -c`）：

```
     12 info •
      3 warning •
      0 error •
```

> 注：plan §1.2/§2.2 描述为"0 error / 15 info+warning"，实测 severity 细分为
> 12 info + 3 warning = 15 issues，与 plan 总数一致。15 项均为 info/warning 级
> lint 提示（如 `use_null_aware_elements`、`unused_import`、`await_only_futures`），
> 无 error，不影响构建。

### 2.2 Flutter test

```bash
cd /home/ubuntu/107_ustc_assistant/app
/home/ubuntu/flutter/bin/flutter test 2>&1 | tail -15
```

实测末尾输出：

```
03:01 +1358 -7: .../test/integration/agent_composition_flow_test.dart: Task 12 lifecycle composite regression scenario 13: cross-account ref resolves null; stale target rejected; no raw id/ref leak
03:01 +1359 -7: loading /home/ubuntu/107_ustc_assistant/app/test/scaffold_test.dart
03:02 +1359 -7: .../test/scaffold_test.dart: application package starts
03:03 +1360 -7: Some tests failed.

Failing tests:
  /home/ubuntu/107_ustc_assistant/app/test/features/agent/agent_write_permission_domain_test.dart: schema v4 migrates the v3 policy/action_log tables
  /home/ubuntu/107_ustc_assistant/app/test/goldens/responsive_golden_test.dart: agent chat phone-390x844
  /home/ubuntu/107_ustc_assistant/app/test/goldens/responsive_golden_test.dart: agent chat phone-412x915
  /home/ubuntu/107_ustc_assistant/app/test/goldens/responsive_golden_test.dart: agent chat windows-1440x900
  ... and 3 more
```

**结果：1360 pass / 7 fail**（exit code 0 是 `tee` 管道的码；flutter test 本身报
"Some tests failed"）。7 项全部为 M0 基线已知失败（`c7637ad` 起每个里程碑不变）。
Flutter 输出截断显示"...and 3 more"，完整 7 项由 `[E]` 标记提取确认如下：

#### 7 项失败测试完整清单

| # | 失败测试（相对 `app/`） | 根因类别 |
|---|---|---|
| 1 | `test/features/agent/agent_write_permission_domain_test.dart: schema v4 migrates the v3 policy/action_log tables` | DB migration 健壮性缺口 |
| 2 | `test/goldens/responsive_golden_test.dart: agent chat windows-1440x900` | golden 字体渲染差异 |
| 3 | `test/goldens/responsive_golden_test.dart: agent chat phone-390x844` | golden 字体渲染差异 |
| 4 | `test/goldens/responsive_golden_test.dart: agent chat phone-412x915` | golden 字体渲染差异 |
| 5 | `test/goldens/responsive_golden_test.dart: seven day week windows-1440x900` | golden 字体渲染差异 |
| 6 | `test/goldens/responsive_golden_test.dart: seven day week phone-390x844` | golden 字体渲染差异 |
| 7 | `test/goldens/responsive_golden_test.dart: seven day week phone-412x915` | golden 字体渲染差异 |

#### 1 项 migration 失败原因（实测）

```
SqliteException(1): while executing, no such table: calendar_event_series, SQL logic error (code 1)
```

根因：v7 migration 假设升级中的 DB 已有 `calendar_event_series` 表（自 schedule/task
schema 提交起存在），但该测试构造了只含 `agent_*` 表的 legacy v3 DB（无 calendar
schema），导致 `ALTER TABLE calendar_event_series ADD COLUMN` 崩溃。是 migration
健壮性假设缺口（非"需干净 DB"），M0 基线起已知失败，M6 不修（后续 backlog）。

6 项 golden：3 viewport（`windows-1440x900`、`phone-390x844`、`phone-412x915`）×
2 场景（agent chat、seven day week），环境字体渲染差异，非 bug。

> 失败处置详见 `docs/m6-external-machine-handoff.md` §6。

---

## 3. Python 验证

```bash
cd /home/ubuntu/107_ustc_assistant
conda run -n ustc_assistant python -m unittest discover -s tests -v 2>&1 | tail -5
```

实测末尾输出：

```
----------------------------------------------------------------------
Ran 140 tests in 2.019s

OK (skipped=1)
```

**结果：140 tests，全绿（1 skipped）。**

> （输出含一行 `ustc-assistant collect: error: argument source: invalid choice:
> 'campus'`——这是某测试用例断言 CLI 拒绝 `campus` 子命令时产生的**预期** stderr，
> 随后紧跟 `ok`；属测试内 CLI 错误处理的正常断言输出，非测试失败。）

```bash
cd /home/ubuntu/107_ustc_assistant
conda run -n ustc_assistant python -m compileall -q src tests 2>&1 | tail -3
```

实测末尾输出：

```
（无输出）
```

**结果：compileall 通过**（`-q` 安静模式，无输出即全部 `.py` 编译通过，exit 0）。

### 3.1 JW oracle digest（实测）

预烘焙 oracle 位于 `app/test/fixtures/jw/oracle-bundle.json`。Python
`canonical_bundle_digest`（全字段，因 oracle 已固定非确定字段）实测：

```
f858a3851b7c0929efe8427dd340ffe50985d5c37357d0d1c9a498b19bb91933
```

oracle 中固定的非确定字段：

| 字段 | 固定值 |
|---|---|
| `bundleId` | `00000000-0000-0000-0000-000000000000` |
| `collectedAt` | `2026-08-22T12:00:00+08:00` |
| `producer` | `{"name":"ustc_assistant_python","version":"0.1.0","platform":"windows"}` |

> 对比真实采集的 Dart bundle 时，必须先规范化（剔除/固定）`bundleId`/`collectedAt`/
> `producer` 再比 digest——详见 `docs/plan-webview-minimal-m2.md` §1.5 与
> `docs/m6-external-machine-handoff.md` §4.2。Dart 测试直接用此 oracle 做 digest
> 对齐，无需 Python 即可跑 Dart 端验证。

---

## 4. grep 证据（实测）

> 在 `app/` 下执行。逐条记录命令、输出与 return code。

### 4.1 lib 顶层无 Windows-only 直构

```bash
cd /home/ubuntu/107_ustc_assistant/app
grep -rn "WindowsDpapiProtector()" lib/app/ lib/features/
```

实测输出：（无输出，`grep rc=1`）

**结果：0 匹配。** 7 处 `WindowsDpapiProtector()` 直构已全部改走
`defaultCredentialProtector()` 工厂。

### 4.2 Windows DPAPI 引用收敛到 core/security

```bash
cd /home/ubuntu/107_ustc_assistant/app
grep -rln "windows_dpapi_protector\|WindowsDpapiProtector" lib/ | grep -v "core/security/"
```

实测输出：（无输出，`grep rc=1`）

**结果：0 匹配。** `windows_dpapi_protector`/`WindowsDpapiProtector` 引用已收敛到
`lib/core/security/` 工厂与实现文件内。

### 4.3 通知 adapter all-params 模式

```bash
cd /home/ubuntu/107_ustc_assistant/app
grep -c "AndroidInitializationSettings\|DarwinInitializationSettings" lib/features/reminders/data/foreground_notification_adapter.dart
```

实测输出：

```
2
```

**结果：2。** `initialize` 设 `android`+`iOS`，`deliver` 设 `android`+`iOS`，
单一构造调用覆盖三端（`windows` 参数同时在位，运行时插件忽略非当前平台参数），
无 `Platform.isXxx` 分支。

### 4.4 外部来源 gateway/client/collector 类无活跃引用

```bash
cd /home/ubuntu/107_ustc_assistant/app
grep -rln "CampusCatalog\|SearchCurrentSecond\|SearchIcourse\|SearchCampus\|ReadCampusDetail\|externalAgentTools" lib/
```

实测输出：（无输出，`grep rc=1`）

**结果：0 匹配。** 外部来源（campus/icourse/young 查询）gateway/client/collector
类无活跃引用（`campus_affair` enum 值与 `icourseConsent` 退役 DB 列不算活跃引用）。
M1 已删外部查询 gateway/domain/tools，collapse sync 到 jw。

---

## 5. 里程碑完成确认

| 里程碑 | 内容 | 状态 | 证据 |
|---|---|---|---|
| M0 | 基线（环境 + plan 采纳） | ✅ | `947ff2f` + `c7637ad`；analyze 绿 + 关键测试绿 |
| M1 | 删外部工具 + 保留 JW Bridge | ✅ | `5168f1c`→`323d989`；外部工具 grep 0（§4.4）；1309→1336 pass |
| M2 | Dart JW 规范化 + oracle 对齐 | ✅ | `e89cb73`；digest 一致（§3.1） |
| M3 | SourceCollectionGateway + 采集器 | ✅ | `cd2e126`；17 collector 单测 + 10 oracle |
| M4 | 删除/生命周期工具回归固化 | ✅ | `452f308`；22 测试，1358 pass |
| M5 | 跨平台凭据/通知/WebView 适配 | ✅ | `4c8b75e`→`744b127`；1360 pass；lib 无平台专属直构（§4.1/§4.2） |
| M6 | 外部机器构建 + 人工验收 | 📋 交接 | 本快照 + `docs/m6-external-machine-handoff.md` |

---

## 6. 边界声明

- 本快照记录的是**本 VM 在 M6 提交前 HEAD `25ec61a` 的静态验证最终状态**。
- 本 VM 无 Windows/Android/iOS SDK、无外网，**不能**执行真实三端构建与真实教务/
  Agent 人工验收。真实构建与验收由外部机器按 `docs/m6-external-machine-handoff.md`
  执行，是 M6 的实质门。
- 静态验证（analyze/test/python/grep）全部满足 M5 门（0 error、1360 pass / 7 基线
  fail、4 条 grep 符合预期）；7 项基线失败为 M0 起已知项，非 M5 引入。
- 真实构建与人工验收不在本机执行是环境约束（无 SDK、无外网），不是工作流跳过。
