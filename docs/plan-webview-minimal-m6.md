# M6 详细实施计划：外部机器三端构建与真实人工验收（交接手册）

> 分支：`refactor/webview-minimal`（M5 已完成）
> 依据：`docs/plan-webview-minimal.md` §3（M6 目标）与 §2 目标
> 目标（M6 门）：交给有 SDK 的外部机器执行三端构建与真实人工验收。本 VM 只产出
> **交接手册** + **M0–M5 最终静态验证快照**；真实构建/验收不在本机执行。

## 0. 范围与非范围

### 0.1 本 VM 能做（M6 本机交付物）

1. **交接手册**：`docs/m6-external-machine-handoff.md`——外部机器的逐步执行 playbook，
   覆盖三端构建 + 真实教务采集验收 + Agent 真实验收，每步配预期结果与回退路径。
2. **M0–M5 最终静态验证快照**：`docs/m6-refactor-final-verification.md`——记录分支
   HEAD、analyze 结果、test 结果（pass/fail 计数 + 基线失败清单）、Python oracle digest
   对齐、git 提交历史、lib 顶层无平台专属直构的 grep 证据。
3. **M6 计划文档**：本文件。

### 0.2 本 VM 不能做（M6 外部机器执行）

- ❌ 三端真实构建（Windows Release / Android APK / iOS）
- ❌ 真实教务网站采集（需校园网/iWAN + 学校登录）
- ❌ 真实 Agent 人工验收（需真实 API Key + 学校 LLM 服务）
- ❌ `flutter_secure_storage` 替换 fallback 凭据保护（需外部机器 pub get）
- ❌ `webview_flutter` 真实 WebView 接线（替换 M5 stub）

以上全部写入交接手册，由外部有 SDK 的机器执行。

### 0.3 不做

- 不在本机引入任何新依赖到 pubspec（`flutter_secure_storage`/`webview_flutter` 等留给外部机器）。
- 不改 M0–M5 任何已提交的 lib/test 代码。
- 不动 Python 代码（M7 退役 Bridge 时才动）。

## 1. 交接手册内容设计（`docs/m6-external-machine-handoff.md`）

### 1.1 前置条件

- 外部机器需有：Flutter 3.44.5+ / Dart 3.12.2+（本 VM 实测 `flutter --version` 为
  Flutter 3.44.5 / Dart 3.12.2，外部机器应确认版本一致）、Windows SDK（for Windows build）、
  Android SDK（for APK）、Xcode（for iOS）、校园网或 iWAN 访问、学校账号、真实 Agent API Key。
- 分支 `refactor/webview-minimal` 已 push 到远端；外部机器 `git checkout` 后 `flutter pub get`。
- Python 环境（仅重新生成 oracle 时需要）：conda `ustc_assistant`（Python 3.10+）。
  预烘焙 oracle 在 `app/test/fixtures/jw/oracle-bundle.json`，Dart 测试直接用它做 digest 对齐，
  无需 Python 即可跑 Dart 端验证。

### 1.2 静态验证（外部机器复现本机结果）

- `flutter analyze` → 0 error（15 info/warning 允许）
- `flutter test` → 1360 pass / 7 fail（7 项基线，列明）
- Python oracle：`conda run -n ustc_assistant python -m unittest discover -s tests -v` → 绿
- grep 验证：lib 顶层无 `WindowsDpapiProtector()` 直构、通知 all-params 已设

### 1.3 三端构建步骤

#### Windows Release
1. `cd app && flutter build windows --release`
2. 预期：成功，输出 `app/build/windows/x64/runner/Release/`
3. 验证：运行 exe，确认启动、账号登录、同步、Agent 可用
4. 回退：若失败，检查 `win32`/`ffi` 依赖、CMake 工具链

#### Android APK
1. 凭据保护替换（按 M5 build-analysis §2.2）：
   - `flutter pub add flutter_secure_storage`
   - 新增 `SecureStorageCredentialProtector implements CredentialProtector`
   - 工厂分派加 `Platform.isAndroid || Platform.isIOS` 分支
   - 删 `FallbackCredentialProtector`（或保留为最终 fallback）
2. `android/app/build.gradle.kts` 确认 `minSdk >= 24`（Flutter 3.44 默认满足）
3. `AndroidManifest.xml` 加 `POST_NOTIFICATIONS`、`VIBRATE` 权限（详见 M5 build-analysis §2.3）
4. WebView 接线（按 M5 build-analysis §2.4）：
   - `flutter pub add webview_flutter`
   - 实现 `JwWebViewAdapter`（替换 M5 stub 的 `UnimplementedError`）
   - `AndroidManifest.xml` 加 `INTERNET` 权限
5. `flutter build apk --release`
6. 预期：成功，输出 `app/build/app/outputs/flutter-apk/app-release.apk`
7. 验证：安装到设备/模拟器，确认启动、登录、采集、通知
8. 回退：若失败，检查 signing config、minSdk、`INTERNET`/`POST_NOTIFICATIONS` 权限声明

#### iOS
1. 凭据保护同 Android（`flutter_secure_storage` + Keychain，详见 M5 build-analysis §3.2）
2. WebView 接线：`flutter pub add webview_flutter`（WKWebView，详见 M5 build-analysis §3.4）
3. `ios/Runner/Info.plist` 加通知权限描述（详见 M5 build-analysis §3.3）
4. `flutter build ios --release`（或 `flutter build ipa`）
5. 预期：成功
6. 回退：若失败，检查 signing/entitlements/ATS 配置（详见 M5 build-analysis §3）
7. 验证：安装到设备/模拟器

### 1.4 真实教务采集验收

1. 配置学校账号（用户名/密码）
2. 触发 JW 同步（`collect jw` 或 App 内同步按钮）
3. 验证：课程表、考试安排、统一日程导入包正确生成
4. 对比 Python oracle：Dart 采集的 SourceBundle digest 与 Python 一致
   （`f858a3851b7c0929efe8427dd340ffe50985d5c37357d0d1c9a498b19bb91933`）
   ⚠️ **注意**：digest 比较前必须固定非确定字段（`bundleId`/`collectedAt`/`producer`），
   否则因 producer name 等差异会产生虚假不匹配。详见 `docs/plan-webview-minimal-m2.md`
   §1.5（normalize nondeterministic fields before comparing）。oracle 已预烘焙在
   `app/test/fixtures/jw/oracle-bundle.json`，Dart 测试直接用它做 digest 对齐；
   若重新生成 Python oracle 则需 conda `ustc_assistant` 环境
5. 回退：若 digest 不一致，检查 M2 字段级对齐

### 1.5 真实 Agent 人工验收

1. 配置真实 API Key（学校 Anthropic 兼容服务 `https://api.llm.ustc.edu.cn`）
2. 按 `docs/acceptance/read-only-agent.md` 清单逐项验收
3. 验证：只读工具、写工具、删除/生命周期工具（M4 回归覆盖）、审批门
4. 回退：若工具行为异常，检查 M1 提示词/grounding 收敛

### 1.6 7 项基线失败的处置

- 1 项 DB migration 测试：`calendar_event_series` 表——根因是 v7 migration 假设
  任何升级中的 DB 都已有 `calendar_event_series` 表（自 schedule/task schema 提交起存在），
  但该测试构造了一个只含 `agent_*` 表的 legacy v3 DB（无 calendar schema），
  导致 `ALTER TABLE calendar_event_series ADD COLUMN` 崩溃。这是 migration 健壮性假设缺口
  （非"需干净 DB"），是 M0 基线起的已知失败，外部机器复现相同结果；M6 不修（属后续 backlog）
- 6 项 golden 测试：环境字体渲染差异——`flutter test --update-goldens` 重新生成
  （仅在外部机器字体环境稳定时；golden 是环境敏感的，非 bug）

## 2. M0–M5 最终静态验证快照（`docs/m6-refactor-final-verification.md`）

### 2.1 分支与提交历史

- 分支：`refactor/webview-minimal`
- HEAD：`<M6 commit hash>`（M6 交接手册提交后记录）
- M0–M5 提交链（从基线到 M5）：
  - M1：`323d989`（F6）+ 前续 F1–F5
  - M2：`e89cb73`（feat）+ `df126d1`（docs）
  - M3：`cd2e126`（feat）+ `15cdf57`（docs）
  - M4：`452f308`（test）+ `98a548d`（docs）
  - M5：`4c8b75e`/`94bfefc`/`6a8c5a3`/`23a4af0`/`744b127` + `25ec61a`（docs）

### 2.2 静态验证结果（M6 提交前实测）

- `flutter analyze`：0 error / 15 info+warning
- `flutter test`：1360 pass / 7 fail（基线：1 migration + 6 golden）
- Python oracle：`conda run -n ustc_assistant python -m unittest discover -s tests -v` →
  ~140 tests 全绿（1 skipped）；digest `f858a385...` 对齐（运行时从
  `app/test/fixtures/jw/oracle-bundle.json` 计算，非硬编码字面量）
- Python compileall：`conda run -n ustc_assistant python -m compileall -q src tests` → 绿
- grep 证据：
  - `grep -rn "WindowsDpapiProtector()" lib/app/ lib/features/` → 0
  - `grep -rln "windows_dpapi_protector\|WindowsDpapiProtector" lib/ | grep -v "core/security/"` → 0
  - `grep -c "AndroidInitializationSettings\|DarwinInitializationSettings" lib/features/reminders/data/foreground_notification_adapter.dart` → 2
  - 外部来源 gateway/client/collector 类无活跃引用：
    `grep -rln "CampusCatalog\|SearchCurrentSecond\|SearchIcourse\|SearchCampus\|ReadCampusDetail\|externalAgentTools" lib/` → 0
    （注：`campus_affair` enum 值与 `icourseConsent` 退役 DB 列不算活跃引用）

### 2.3 里程碑完成确认

| 里程碑 | 内容 | 状态 | 证据 |
|---|---|---|---|
| M0 | 基线 | ✅ | analyze 绿 + 关键测试绿 |
| M1 | 删外部工具 + 保留 JW Bridge | ✅ | 1309→1336 pass，外部工具 grep 0 |
| M2 | Dart JW 规范化 + oracle 对齐 | ✅ | digest 一致 |
| M3 | SourceCollectionGateway + 采集器 | ✅ | 17 collector 单测 + 10 oracle |
| M4 | 删除/生命周期工具回归固化 | ✅ | 22 测试，1358 pass |
| M5 | 跨平台凭据/通知/WebView 适配 | ✅ | 1360 pass，lib 无平台专属直构 |
| M6 | 外部机器构建 + 人工验收 | 📋 交接 | 本手册 |

## 3. Tasks

### Task 1: 交接手册

**Files:**
- Create: `docs/m6-external-machine-handoff.md`

- [ ] **Step 1**: 写交接手册（§1 全部内容：前置条件、静态验证复现、三端构建步骤、
  教务采集验收、Agent 验收、基线失败处置、回退路径）。
- [ ] **Step 2**: 确认引用 M5 build-analysis 文档（`docs/m5-three-platform-build-analysis.md`）
  作为三端构建详细错误清单的来源，不重复内容。
- [ ] **Step 3**: Commit。

### Task 2: 最终静态验证快照

**Files:**
- Create: `docs/m6-refactor-final-verification.md`

- [ ] **Step 1**: 实测当前 HEAD 的 analyze + test 结果，记录精确数字。
- [ ] **Step 2**: 实测 grep 证据（4 条）。
- [ ] **Step 3**: 实测 Python oracle（`conda run -n ustc_assistant python -m unittest`）。
- [ ] **Step 4**: 写快照文档（§2 全部内容：提交历史、验证结果、里程碑确认表）。
- [ ] **Step 5**: Commit。

### Task 3: M6 计划文档

**Files:**
- Create: `docs/plan-webview-minimal-m6.md`（本文件）

- [ ] **Step 1**: 本文件已经写好，审核通过后提交。
- [ ] **Step 2**: Commit。

## 4. 验证步骤（M6 本机门）

```bash
cd app
/home/ubuntu/flutter/bin/flutter analyze 2>&1 | tail -3   # 0 error
/home/ubuntu/flutter/bin/flutter test 2>&1 | tail -10      # 1360 pass / 7 fail
# grep 证据
grep -rn "WindowsDpapiProtector()" lib/app/ lib/features/   # 0
grep -rln "windows_dpapi_protector\|WindowsDpapiProtector" lib/ | grep -v "core/security/"  # 0
# Python oracle
cd .. && conda run -n ustc_assistant python -m unittest discover -s tests -v 2>&1 | tail -5
conda run -n ustc_assistant python -m compileall -q src tests 2>&1 | tail -3
```

## 5. 提交

```
docs(refactor): M6 — external machine handoff + final verification snapshot
```

（Task 1+2 合并一个 commit，Task 3 计划文档单独或合并）

## 6. 边界声明

**M6 在本 VM 的完成定义**：交接手册 + 最终验证快照已落档，分支 HEAD 的 analyze/test/grep
全部满足 M5 门。**真实三端构建与人工验收不在本机执行**——这是环境约束（无 SDK、无外网），
不是工作流跳过。外部机器按交接手册执行后，M6 才算最终完成。

## 7. 与 AGENTS.md 的关系

AGENTS.md 的 M0–M8 / 六层阶梯是旧目标环境路线，本分支不采用。本分支的里程碑是
`plan-webview-minimal.md` §3 的 M0–M6。M6 是本分支最后一个里程碑；M7（Bridge/Python 退役）
和 M8（发布硬化）属 AGENTS.md 旧路线，不在本分支范围。
