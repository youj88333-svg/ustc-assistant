# M6 外部机器交接手册：三端构建与真实人工验收

> 分支：`refactor/webview-minimal`（M5 已完成，本手册为 M6 交付物）
> 依据：`docs/plan-webview-minimal-m6.md` §1（本手册为该节的可执行落地版）
> 适用对象：在**有完整 SDK 的外部机器**上执行三端构建 + 真实教务采集验收 + 真实
> Agent 人工验收的操作者。
> 本 VM 状态：无 Windows/Android/iOS SDK、无外网。本手册由本 VM 在 `25ec61a`
> （M5 docs 提交，M6 提交前 HEAD）产出；真实构建与验收不在本机执行。

---

## 0. 本手册的边界

| 项 | 本 VM 已做 | 外部机器执行（本手册覆盖） |
|---|---|---|
| 静态验证 | analyze/test/python/grep 实测并记录于 `docs/m6-refactor-final-verification.md` | 复现本机静态验证结果 |
| 三端构建 | ❌ 无 SDK | ✅ Windows Release / Android APK / iOS |
| 真实教务采集 | ❌ 无校园网/iWAN | ✅ 触发 JW 同步 + digest 对齐 |
| 真实 Agent 验收 | ❌ 无真实 API Key | ✅ 按 `docs/acceptance/read-only-agent.md` 逐项 |
| 凭据保护替换 | ❌ 不动 pubspec | ✅ `flutter_secure_storage` |
| WebView 接线 | ❌ 不动 pubspec | ✅ `webview_flutter`（替换 M5 stub） |

**本手册不重复** `docs/m5-three-platform-build-analysis.md` 已记录的三端构建详细错误
清单（Android 见其 §2.2/§2.3/§2.4，iOS 见 §3.2/§3.3/§3.4）。本手册给出执行步骤、
预期结果与回退路径，遇到具体错误时按该文档对应小节查阅解决方向。

---

## 1. 前置条件

### 1.1 工具链

- **Flutter**：3.44.5+ / **Dart** 3.12.2+。本 VM 实测 `flutter --version` 为
  Flutter 3.44.5 / Dart 3.12.2，外部机器应确认版本一致（`flutter --version`）。
  本分支按此版本离线 pub get 解析通过，版本偏离可能引入依赖解析差异。
- **Windows 构建**：Windows SDK + Visual Studio C++ 工具链（旧版 main 已验证
  Windows Release 可构建，见 `AGENTS.md` §"Windows 首版自动验证（2026-07-28）"）。
- **Android 构建**：Android SDK + `sdkmanager` + signing config（debug 默认即可
  出 APK，release 需 keystore）。
- **iOS 构建**：Xcode + 有效 Apple Developer 签名/entitlements（模拟器无需签名，
  真机需 provisioning profile）。
- **校园网络**：教务采集与 Agent 真实验收需要校园网内直连或校外 Panabit iWAN。
- **学校账号**：教务系统用户名/密码（用于 JW 同步）。
- **真实 Agent API Key**：学校 Anthropic 兼容模型服务（`https://api.llm.ustc.edu.cn`，
  默认模型 `deepseek-v4-flash`）的 API Key。

### 1.2 代码获取

```bash
git clone <repo>          # 或对已有仓库 git fetch
cd <repo>
git checkout refactor/webview-minimal   # M5 完成分支
git pull --ff-only        # 确认到最新（M6 两个 docs 提交已含）
cd app
flutter pub get           # 需外网拉取 pub 依赖
```

> ⚠️ 本 VM 离线 pub-cache 可用，但外部机器首次 `flutter pub get` 需联网。若拉取
> 失败，确认 `PUB_HOSTED_URL` / `FLUTTER_STORAGE_BASE_URL` 指向可达镜像。

### 1.3 Python 环境（仅重新生成 oracle 时需要）

- conda 环境 `ustc_assistant`（Python 3.10+）。
- **默认不需要 Python**：预烘焙 oracle 已在 `app/test/fixtures/jw/oracle-bundle.json`，
  Dart 测试直接用它做 digest 对齐，无需 Python 即可跑 Dart 端验证。
- 仅当需要**重新生成** Python oracle（如 Python 端解析逻辑变化）时才需 conda 环境。

---

## 2. 静态验证复现（外部机器对齐本 VM 结果）

在 `app/` 目录下依次执行，结果应与本 VM 在 `docs/m6-refactor-final-verification.md`
§2 记录一致。任何偏差需先排查再继续构建。

```bash
cd app
flutter analyze 2>&1 | tail -3
# 预期：0 error / 15 issues（12 info + 3 warning），末行 "15 issues found."

flutter test 2>&1 | tail -15
# 预期：1360 pass / 7 fail（7 项为 M0 基线已知失败，见 §6）
```

Python（仅当需重新生成 oracle 时；默认跳过）：

```bash
cd <repo>
conda run -n ustc_assistant python -m unittest discover -s tests -v 2>&1 | tail -5
# 预期：Ran 140 tests ... OK (skipped=1)
conda run -n ustc_assistant python -m compileall -q src tests 2>&1 | tail -3
# 预期：无输出（exit 0，即全部编译通过）
```

grep 证据（在 `app/` 下）：

```bash
# A) lib/app + lib/features 顶层 Windows-only 直构（应 0）
grep -rn "WindowsDpapiProtector()" lib/app/ lib/features/
# 预期：无输出（grep rc=1）

# B) windows_dpapi/WindowsDpapiProtector 在 lib/ 中除 core/security 外（应 0）
grep -rln "windows_dpapi_protector\|WindowsDpapiProtector" lib/ | grep -v "core/security/"
# 预期：无输出（grep rc=1）

# C) 通知 adapter all-params 模式（应 2）
grep -c "AndroidInitializationSettings\|DarwinInitializationSettings" \
    lib/features/reminders/data/foreground_notification_adapter.dart
# 预期：2

# D) 外部来源 gateway/client/collector 类无活跃引用（应 0）
grep -rln "CampusCatalog\|SearchCurrentSecond\|SearchIcourse\|SearchCampus\|ReadCampusDetail\|externalAgentTools" lib/
# 预期：无输出（grep rc=1）
# 注：campus_affair enum 值与 icourseConsent 退役 DB 列不算活跃引用
```

**通过标准**：analyze 0 error；test 1360 pass / 7 fail（且 7 项与 §6 清单一致）；
4 条 grep 全部符合预期。若 test 失败项多于 7 或失败项不同，说明环境引入了新失败，
**不得继续构建**——先排查。

---

## 3. 三端构建步骤

> 建议执行顺序：先 Windows（M5 改动等价、回归风险最低）→ Android → iOS。
> 详细错误清单与解决方向见 `docs/m5-three-platform-build-analysis.md`（Android
> §2.2/§2.3/§2.4，iOS §3.2/§3.3/§3.4），本手册不重复该内容。

### 3.1 Windows Release

**步骤：**

```bash
cd app
flutter build windows --release
```

**预期：** 成功，输出目录 `app/build/windows/x64/runner/Release/`。

**验证：**
- 运行 `Release/<app_name>.exe`，确认窗口启动。
- 登录学校账号，触发同步，确认课表/考试/日程导入。
- 打开 Agent，发送简单消息确认可用。

**回退：** 若构建失败，检查：
- `win32`/`ffi`/`flutter_local_notifications` 依赖解析（`flutter pub get` 是否成功）。
- CMake 工具链（Visual Studio Build Tools 是否安装、`flutter doctor` 是否报红）。
- M5 改动均为平台无关分派，Windows 路径行为与旧版等价——失败多为环境而非代码。

### 3.2 Android APK

**前置代码改动（M6 引入新依赖，外部机器执行）：**

1. **凭据保护替换**（详见 M5 build-analysis §2.2）：
   ```bash
   flutter pub add flutter_secure_storage
   ```
   - 新增 `SecureStorageCredentialProtector implements CredentialProtector`（scheme
     如 `flutter-secure-storage`，version `1`）。
   - 工厂分派（`core/security/credential_protector_factory.dart`）加
     `Platform.isAndroid || Platform.isIOS` 分支：
     `Platform.isWindows ? WindowsDpapiProtector()
       : Platform.isAndroid || Platform.isIOS ? SecureStorageCredentialProtector()
       : FallbackCredentialProtector()`。
   - 删 `FallbackCredentialProtector`（或保留为最终 fallback）。

2. **minSdk**：确认 `android/app/build.gradle.kts` 的 `minSdk >= 24`
   （Flutter 3.44 默认满足，`flutter_local_notifications` 要求 ≥24）。

3. **通知权限**（详见 M5 build-analysis §2.3）：在
   `android/app/src/main/AndroidManifest.xml` 的 `<manifest>` 顶层加：
   ```xml
   <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
   <uses-permission android:name="android.permission.VIBRATE"/>
   ```
   并在 app 启动/首条提醒前运行时请求
   （`AndroidFlutterLocalNotificationsPlugin.requestPermission()`）。

4. **WebView 接线**（详见 M5 build-analysis §2.4）：
   ```bash
   flutter pub add webview_flutter
   ```
   - 实现 `JwWebViewAdapter`，替换 M5 stub 的 `UnimplementedError` 方法体为真实
     `WebViewController` 调用，对齐 M3 `JwWebPage` 契约。
   - 在 `android/app/src/main/AndroidManifest.xml` 加
     `<uses-permission android:name="android.permission.INTERNET"/>`
     （当前 main manifest **未声明** INTERNET，仅 debug/profile 有——release 联网必须补）。

**构建：**

```bash
flutter build apk --release
```

**预期：** 成功，输出 `app/build/app/outputs/flutter-apk/app-release.apk`。

**验证：**
- 安装到设备/模拟器（`adb install` 或直接拖入模拟器）。
- 确认启动、账号登录、JW 同步采集、通知弹出。

**回退：** 若失败，按 M5 build-analysis §2.2/§2.3/§2.4 逐项检查：
- signing config（release 需 keystore，否则用 debug 签名出包验证）。
- minSdk / compileSdk（`flutter_local_notifications` 22.2.0 子包 compileSdk 36，
  若报 `requires compileSdkVersion 36` 则在 `build.gradle.kts` 显式设
  `compileSdk = 36`）。
- `INTERNET`/`POST_NOTIFICATIONS` 权限声明是否在 **main** manifest（非 debug）。

### 3.3 iOS

**前置代码改动（M6 引入新依赖，外部机器执行）：**

1. **凭据保护**（详见 M5 build-analysis §3.2）：复用 §3.2 步骤 1 的
   `SecureStorageCredentialProtector`（同一实现覆盖 Android + iOS，iOS 默认用
   Keychain）。需确认签名/entitlements（Keychain 访问需有效签名）。

2. **WebView 接线**（详见 M5 build-analysis §3.4）：
   ```bash
   flutter pub add webview_flutter    # 自动拉 webview_flutter_wkwebview
   ```
   - 替换 stub 方法体为真实 `WebViewController` 调用，对齐 M3 `JwWebPage` 契约。
   - JW 站点 `jw.ustc.edu.cn` 是 HTTPS，应满足 ATS 默认策略；若采集涉及 HTTP
     资源或自签证书，按需在 `Info.plist` 配 `NSAppTransportSecurity` 例外
     （不建议全局关闭 ATS）。

3. **通知权限**（详见 M5 build-analysis §3.3）：`ios/Runner/Info.plist` 加通知
   权限描述。本 App 提醒为前台定时触发（`ReminderTimerScheduler`），无需
   `UIBackgroundModes`；真机验证首次启动弹出通知授权对话框即可。

**构建：**

```bash
flutter build ios --release
# 或出 IPA：flutter build ipa
```

**预期：** 成功。

**验证：**
- 安装到设备/模拟器。
- 确认启动、登录、采集、WKWebView 能加载 CAS 登录页/执行 JS 填表/拦截 get-data 请求、
  通知授权与前台呈现。

**回退：** 若失败，按 M5 build-analysis §3 检查：
- signing/entitlements（Keychain 访问需有效签名与 provisioning profile）。
- ATS 配置（HTTPS 站点默认通过，HTTP 资源需例外）。
- `webview_flutter_wkwebview` 平台包是否随 `flutter pub get` 正确拉取。

---

## 4. 真实教务采集验收

> Oracle 已预烘焙在 `app/test/fixtures/jw/oracle-bundle.json`，Dart 测试直接用它
> 做 digest 对齐，无需 Python 即可跑 Dart 端自动验证。本节是**真实采集**的人工验收。

### 4.1 步骤

1. 配置学校账号（用户名/密码）到 App 账号设置。
2. 触发 JW 同步（`collect jw` 或 App 内同步按钮）。
   - 当前默认学期 `semesterId=461`、产品键 `2026fall`、显示名"2026 秋季学期"
     （不得按年份推算教务内部学期 ID）。
3. 验证采集结果：
   - 课程表正确生成（事件数与教务页面一致）。
   - 考试安排正确生成。
   - 统一日程导入包（SourceBundle）正确生成。
4. **digest 对齐**：将 Dart 采集产出的 SourceBundle 与预烘焙 oracle 做 canonical
   digest 对比。

### 4.2 digest 对齐（关键：先规范化非确定字段）

Python oracle 的 canonical digest（全字段，因 oracle 已固定非确定字段）：

```
f858a3851b7c0929efe8427dd340ffe50985d5c37357d0d1c9a498b19bb91933
```

> ⚠️ **必须先规范化非确定字段**再比 digest，否则会产生虚假不匹配。详见
> `docs/plan-webview-minimal-m2.md` §1.5。

非确定字段（对比前必须固定/剔除）：

| 字段 | oracle 中的固定值 | 真实采集的值 |
|---|---|---|
| `bundleId` | `00000000-0000-0000-0000-000000000000` | 采集时随机 UUID |
| `collectedAt` | `2026-08-22T12:00:00+08:00` | 采集时刻（北京时间） |
| `producer` | `{name:"ustc_assistant_python", version:"0.1.0", platform:"windows"}` | Dart builder 自己的 producer（**不能**照抄 Python name，否则谎报身份） |

**对比方法**（二选一，推荐前者）：
- **规范化对比**：把 Dart 产出 bundle 与 oracle 各自剔除 `bundleId`/`collectedAt`/
  `producer` 后，`jsonEncode`（排序 key、无空格）再比 sha256。
- **注入对比**：在 Dart builder 注入与 oracle 相同的 `bundleId`/`collectedAt`/
  `producer` 后比全字段 digest（见决策 D-M2-1；生产仍用 Dart 自己的 producer）。

### 4.3 回退

- 若 digest 不一致（规范化后仍不等）：检查 M2 字段级对齐
  （`docs/plan-webview-minimal-m2.md` §1.5 canonical digest 与逐字段契约），
  逐字段比对 `data`/`manifest`/`snapshot`，定位 Dart normalizer 与 Python oracle
  的字段差异。
- 若采集本身失败（登录/页面解析）：检查校园网/iWAN 连通、教务页面 DOM 是否变化、
  动态上下文是否过期。

---

## 5. 真实 Agent 人工验收

### 5.1 前置

1. 配置真实 API Key（学校 Anthropic 兼容服务 `https://api.llm.ustc.edu.cn`）。
   - Key 只通过 App"设置 → 模型服务"输入，不写入本手册/源码/日志/截图。
2. 确认校园网内直连或校外 Panabit iWAN 可达学校 API Host。

### 5.2 执行

按 `docs/acceptance/read-only-agent.md` 清单**逐项**验收（该文档 §1–§9 只读 Agent
主体、§10 写工具、§11 修复复测项）。每项末尾 `完成：`留空，由验收者在真实验收后
填写脱敏的成功/失败文字。

> **minimal 注记**：本分支已删除二课/评课/校园公开目录等外部按需来源工具，
> `read-only-agent.md` 中涉及它们的段（§6/§7/§9 部分）跳过/不适用；验收以本地
> 日程/Task/PlanBlock/同步状态只读 + 写工具 + 生命周期工具为准。

验收覆盖范围：
- **只读工具**：本地只读工具（含管理态）的过程折叠/停止/重试。
- **写工具**：11 个受控本地写工具，审批门按风险分级确认（聊天内联确认卡）。
- **删除/生命周期工具**：9 个生命周期/清除/撤回工具 + 8 个管理态/配置态只读工具
  （M4 回归覆盖，见 `app/test/integration/agent_composition_flow_test.dart`）。
- **审批门**：`AgentPermissionPolicy` 表迁移与运行时决策；权限变更永远需用户亲手
  确认（`update_permission_policy`）。

### 5.3 回退

- 若工具行为异常：检查 M1 提示词/grounding 收敛（提示词版本 9，grounding policy +
  tool_choice 受限纠错，见 `AGENTS.md`“当前能力”与 `app/lib/features/agent/` 实现）。
- 若工具调用额度/确认门异常：检查 `AgentToolRegistry` 预算（12/run，create_task
  Burst 32 一次性 Lease）与 `AgentPermissionPolicy` 迁移。
- 自动测试不代替人工验收：学校 API 与学校网站从不进入自动测试。

---

## 6. 基线失败处置（7 项已知失败）

本 VM 在 M5 HEAD `25ec61a` 实测 `flutter test` 为 **1360 pass / 7 fail**，7 项
全部为 M0 基线已知失败（`c7637ad` 起每个里程碑验证不变）。外部机器应复现**相同**
结果（7 项、同样的失败原因）；若失败项多于 7 或原因不同，说明环境引入了新失败。

### 6.1 1 项 DB migration 健壮性缺口（非"需干净 DB"）

**失败测试：**
```
test/features/agent/agent_write_permission_domain_test.dart:
  schema v4 migrates the v3 policy/action_log tables
```

**失败原因：**
```
SqliteException(1): while executing, no such table: calendar_event_series, SQL logic error (code 1)
```

**根因：** v7 migration 假设任何升级中的 DB 都已有 `calendar_event_series` 表
（该表自 schedule/task schema 提交起存在），但该测试构造了一个只含 `agent_*` 表的
legacy v3 DB（无 calendar schema），导致 `ALTER TABLE calendar_event_series ADD
COLUMN` 崩溃。这是 **migration 健壮性假设缺口**（非"需干净 DB"）。

**处置：** M6 不修。属后续 backlog（M7+ 或独立修复轮）。外部机器复现相同结果即可，
**不得**把此项当作环境问题排查或当作真实构建/验收的阻塞项。

### 6.2 6 项 golden 字体渲染差异（环境敏感，非 bug）

**失败测试：**
```
test/goldens/responsive_golden_test.dart: agent chat windows-1440x900
test/goldens/responsive_golden_test.dart: agent chat phone-390x844
test/goldens/responsive_golden_test.dart: agent chat phone-412x915
test/goldens/responsive_golden_test.dart: seven day week windows-1440x900
test/goldens/responsive_golden_test.dart: seven day week phone-390x844
test/goldens/responsive_golden_test.dart: seven day week phone-412x915
```

**根因：** 3 个 viewport（`windows-1440x900`、`phone-390x844`、`phone-412x915`）×
2 个 golden 场景（agent chat、seven day week）= 6 项。golden 测试对比渲染像素，
不同机器字体渲染（抗锯齿/字距/字体回退）存在环境差异，非代码 bug。

**处置：** 若外部机器字体环境稳定且希望本地 golden 通过，执行：
```bash
cd app
flutter test --update-goldens
```
重新生成 golden 基线（仅在外部机器字体环境稳定时；生成的 golden 是该机器的本地
基线，**不要**提交回仓库——仓库 golden 以本 VM 基线为准）。golden 是环境敏感的，
此项失败**不**代表功能 bug，**不**阻塞真实构建/验收。

### 6.3 处置汇总

| # | 失败测试 | 根因 | 处置 | 是否阻塞构建/验收 |
|---|---|---|---|---|
| 1 | migration test | v7 migration 假设缺口 | M6 不修，后续 backlog | 否 |
| 2–7 | 6 golden tests | 环境字体渲染差异 | 可选 `--update-goldens`（本地基线，不回传） | 否 |

---

## 7. 完成判定

外部机器按本手册执行完毕后，M6 才算最终完成：

- [ ] §2 静态验证复现：analyze 0 error、test 1360 pass / 7 fail（与 §6 一致）、
      4 条 grep 符合预期。
- [ ] §3.1 Windows Release 构建成功 + exe 运行验证。
- [ ] §3.2 Android APK 构建成功 + 安装运行验证（含凭据保护/通知/WebView 接线）。
- [ ] §3.3 iOS 构建成功 + 安装运行验证（含 Keychain/通知/WKWebView 接线）。
- [ ] §4 真实教务采集：课程/考试/日程导入包正确 + digest 规范化后对齐 oracle。
- [ ] §5 真实 Agent 人工验收：按 `docs/acceptance/read-only-agent.md` 逐项填写。
- [ ] §6 基线失败：复现 7 项相同结果，无新增失败。

> 真实构建与人工验收是 M6 的实质门；本 VM 只交付本手册 + 静态验证快照
> （`docs/m6-refactor-final-verification.md`），不构成 M6 完成。
