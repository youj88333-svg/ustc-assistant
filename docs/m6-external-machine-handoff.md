# M6 外部机器交接手册：三端构建与真实人工验收

> 分支：`refactor/webview-minimal`（M7 原生 WebView2 已接入；本文保留 M6 交接
> 步骤并补充 Task 9 的自动化验证口径）
> 依据：`docs/plan-webview-minimal-m6.md` §1（本手册为该节的可执行落地版）
> 适用对象：在**有完整 SDK 的外部机器**上执行三端构建 + 真实教务采集验收 + 真实
> Agent 人工验收的操作者。
> 本手册的外部机器步骤仍覆盖 Android/iOS 与真实校园验收；Windows 原生 WebView2
> 的 loopback 自动化证据另见 §8.7。自动化证据不等于真实校园验收。

---

## 0. 本手册的边界

| 项 | 本 VM 已做 | 外部机器执行（本手册覆盖） |
|---|---|---|
| 静态验证 | 历史基线见 `docs/m6-refactor-final-verification.md`；Task 9 fresh 结果见 §8.7 | 在完整 SDK 机器复现并对照记录 |
| 三端构建 | Task 9 analyze 真实退出 1（18 issues），按规则 test/build 未运行；Android/iOS 未在本机运行 | ✅ Windows Release / Android APK / iOS |
| 真实教务采集 | ❌ 无校园网/iWAN | ✅ 触发 JW 同步 + digest 对齐 |
| 真实 Agent 验收 | ❌ 无真实 API Key | ✅ 按 `docs/acceptance/read-only-agent.md` 逐项 |
| 凭据保护替换 | ❌ 不动 pubspec | ✅ `flutter_secure_storage` |
| WebView 接线 | ✅ minimal 分支 M7 已接入 Windows 原生 WebView2（§8）；Task 8 与 Task 9 fresh loopback 均有 GREEN 记录 | Android/iOS 仍需外部机器 `webview_flutter` |

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
git checkout refactor/webview-minimal   # 当前 M7 minimal 分支
git pull --ff-only        # 确认到最新（含 M7 实现与 Task 9 文档提交）
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

## 2. 静态验证复现（外部机器对齐历史基线）

以下 1360/7 与 15 issues 仅是 M5/M6 交接时的历史快照，不是当前 M7 的通过标准。
当前 M7/Task 9 实际结果见 §8.7；任何当前结果都不得套用下面的历史数字。

```bash
cd app
flutter analyze 2>&1 | tail -3
# 历史 M5 快照：0 error / 15 issues（12 info + 3 warning）；非当前 M7 结论

flutter test 2>&1 | tail -15
# 历史 M5 快照：1360 pass / 7 fail（见 §6）；非当前 M7 结论
```

Python（仅当需重新生成 oracle 时；默认跳过）：

```bash
cd <repo>
conda run -n ustc_assistant python -m unittest discover -s tests -v 2>&1 | tail -5
# 历史 M5 快照：Ran 140 tests ... OK (skipped=1)；当前 Task 9 结果见 §8.7
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

**历史 M5 对照标准**：analyze 0 error；test 1360 pass / 7 fail（且 7 项与 §6
清单一致）；4 条 grep 全部符合预期。当前 M7 不以这些数字宣称通过；应以 §8.7 的
实际命令、退出码和停止规则为准。若当前 test 失败，**不得继续构建**——先排查。

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

M5 HEAD `25ec61a` 的历史快照为 **1360 pass / 7 fail**，7 项全部为 M0 基线已知
失败（`c7637ad` 起每个里程碑验证不变）。这是交接背景，不是当前 M7 的测试结果；
当前 M7 结果只记录在 §8.7。外部机器若复现该历史快照，可按下述原因解释，但不得
把历史数字当作当前代码的验证结论。

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

- [ ] §2 历史 M5 静态快照对照：analyze 0 error、test 1360 pass / 7 fail（与 §6
      一致）、4 条 grep 符合预期；当前 M7 结果另见 §8.7。
- [ ] §3.1 Windows Release 构建成功 + exe 运行验证。
- [ ] §3.2 Android APK 构建成功 + 安装运行验证（含凭据保护/通知/WebView 接线）。
- [ ] §3.3 iOS 构建成功 + 安装运行验证（含 Keychain/通知/WKWebView 接线）。
- [ ] §4 真实教务采集：课程/考试/日程导入包正确 + digest 规范化后对齐 oracle。
- [ ] §5 真实 Agent 人工验收：按 `docs/acceptance/read-only-agent.md` 逐项填写。
- [ ] §6 基线失败：复现 7 项相同结果，无新增失败。

> 真实构建与人工验收是 M6 的实质门；本 VM 只交付本手册 + 静态验证快照
> （`docs/m6-refactor-final-verification.md`），不构成 M6 完成。

---

## 8. M7 增补：原生 WebView2 已接入 minimal（2026-08-27 本机实测）

> 本节是对本文档 §0「WebView 接线」一行的更新：M7 已在 minimal 分支接入
> **Windows 原生 WebView2**（`webview_flutter_windows_secure` 自足插件），
> 不再是"仅外部机器接线"。本节记录本机接入说明、构建实测与已知边界。

### 8.1 接入内容

- 新增插件：`app/packages/webview_flutter_windows_secure/`（自足，仅依赖
  flutter；来自全量分支 `rewrite/flutter-native`，排除 `.dart_tool/` 与
  `build/`），`app/pubspec.yaml` 以 path 依赖引入。
- 新增/替换原生采集实现（`app/lib/features/sync/native/`）：
  - `jw_webview_adapter.dart` —— `JwWebViewAdapter implements JwWebPage`（替换
    M5 stub），驱动 `WebviewController` + 三信号收敛 + 注册脚本提取 + CAS 登录流。
  - `jw_web_session.dart` —— 编译期 URL 白名单、注册脚本库、webMessage+requestId
    包装器、导航收敛原语。
  - `native_jw_gateway.dart` —— `BridgeGateway` 兼容壳，驱动 `JwCollector`
    + `JwWebViewAdapter`；`capabilities()` 返回固定学期
    `(461, 2026fall, 2026 秋季学期)`（来自 `generated_source_defaults.dart`，
    不做动态学期发现）。
- `sync_page.dart`：同步页拥有一个稳定挂载的原生 WebView surface；手动进入同步页
  后由 `NativeJwGateway` 驱动登录/验证码交互。由于 `/chat` 启动路由没有挂载该
  surface，原生模式的 `runStartupAutomaticSync` 明确不启动 headless WebView；
  `kUsePythonBridgeFallback=true` 时仍可保留 Python Bridge 的 headless 启动同步。
  两种通道严格一源一通道，不并行。

### 8.2 本机构建与静态验证实测（历史 M7 初始接入快照）

以下是 2026-08-27 初始接入时的快照；它不是当前 Task 9 的 gate 结果，当前结果见
§8.7。本机（Windows + VS2022 + Flutter 3.44.5）当时实测：

```
cd app
flutter analyze                # 历史 M5 快照：0 error / 15 issues（当前 Task 9 见 §8.7）
flutter test                   # 较 M5 基线新增：adapter 15 + gateway 7 单测，全绿
                               # （本机 sqlite3.dll 需在 PATH，见 §8.5）
flutter build windows --release  # 含插件 C++ 编译
```

- `flutter test` 全量在**本机**为 **1388 pass / 1 fail**（1 项为 M0 基线
  migration 健壮性缺口，见 §6.1；6 项 golden 在 Linux VM 失败、本机字体环境
  通过）。外部 Linux VM 复现仍应为 1360+ 基线 / 已知 7 项失败口径（golden
  环境差异，不阻塞）。
- 新增单测均不触网、不建二进制：驱动 fake `JwWebviewController`（与插件
  `secure_controller_test.dart` 相同的 MethodChannel mock 思路）；
  覆盖三信号收敛、登录激活、身份核验（布尔不回传账号原文）、get-data/datum
  取数、错误映射（login_timeout/account_mismatch/collection_failed）、
  URL 白名单 fail-closed、close 清会话。
- `flutter build windows --release` 退出码 0，产物
  `app/build/windows/x64/runner/Release/ustc_assistant_app.exe` 与
  `webview_flutter_windows_secure_plugin.dll`（插件 C++ 编译链接）。注意：首次
  构建会打印 `flutter.bat : Nuget is not installed.` 并把 nuget.exe 下载到
  build 目录 —— 在 PowerShell 里 `2>&1` 会导致该 stderr 行被包装为
  NativeCommandError 并让外层命令显示退出码 1，但这是假阳性；用 `$LASTEXITCODE`
  实测为 0，真正失败只会以 CMake 的 `FATAL_ERROR`（下载失败/校验失败）出现。

### 8.3 「重启后免登录」不受支持（已知边界）

minimal **不做** C++ session snapshot/DPAPI 会话持久化（全量分支的 C++ 方案
属于企业级，minimal 明确取舍）。因此：

- 关机/重启 App 后教务 session cookie 丢失，普通同步会再次进入
  `needs_user_login`，需要用户重新登录。
- 这是**已知边界，不阻塞日常使用**，与 M0–M6 口径一致。

### 8.4 真实人工验收待办（外置）

- [ ] 校园网/iWAN + 真实账号：登录 → 同步 → 课表/考试正确导入；对照安全聚合
      计数（不记录私人信息）。
- [ ] 取消/失败/重新登录的终态文案与存储保持一致。
- [ ] 重启后重新登录（已知边界 §8.3）。
- [ ] digest 规范化后对齐 oracle（见 §4.2）。

真实人工验收仍按 M6 口径外置（需校园网 + 真实账号 + 其他 SDK），不在本机执行。

### 8.5 本机测试 sqlite3.dll 说明（Windows 环境）

本机 `flutter test` 依赖 sqlite3 动态库（drift 打开内存库）。Linux 基线用
`pubspec.yaml` 的 `hooks.user_defines.sqlite3.source: system` 落在系统
`libsqlite3.so.0`；Windows 需将 sqlite3.dll 所在目录加入 PATH，例如：

```powershell
$env:PATH = "<含 sqlite3.dll 的目录>;$env:PATH"
cd app; flutter test
```

若 `flutter test` 报 `Failed to load dynamic library 'sqlite3.dll'`（本机首次
裸跑基线时的症状），即该环境问题，加上 PATH 后恢复基线。

### 8.6 Debug 验收与阶段日志（仿全量分支可观测形式）

minimal 启用 **debug 验收 + 阶段化安全日志**（对齐全量分支
`m2-native-jw-lessons.md》§4.1 “只记录阶段，不记录秘密” 的形式）：

- `NativeJwGateway` 暴露 `Stream<String> diagnostics`（broadcast）与可选
  `safeDiagnostic` 构造参数，透传给 `JwWebViewAdapter`。adapter / session 内部
  的阶段日志（`attempt:jw.*`、`waiting_for_cas_form`、`activationDispatched`、
  `urlMatched:*`、`domReady:*`、`ready:*`、`course_context_read`、
  `get_data_fetched`、`datum_fetched`、`navigation_rejected` 等）经此流出。
- `sync_page` 在 **debug 构建**（`kDebugMode`）订阅 diagnostics：
  `debugPrint('[jw-native] …')` 输出到控制台，并在 WebView surface 下方显示
  **调试日志面板**（最多 80 条、monospace、只读）。release 构建不分配日志缓冲、
  不渲染面板（零开销）。
- 隐私不变：日志只含阶段名与稳定错误码，绝不记录 URL query / ticket / Cookie /
  DOM / 账号原文 / 课程数据；面板是**透明的展示层**，机密性由 producer
  （adapter/collector）契约保证（红线 §1 / M7 计划 §2.6 阶段词表）。
- 调试入口：`flutter run -d windows --debug`（或 VS Debug 启动）→ 同步页出现
  「调试日志」面板 + 控制台阶段流；配合 §8.4 真实验收场景可在登录/取数/失败时
  按“最后成功阶段”定位（全量分支 §4.2 方法）。

新增测试（不触网、不建二进制）：

- `native_jw_gateway_test.dart` —— diagnostics 流透传隐私安全阶段；断言阶段名
  不泄漏 URL/账号/路径。
- `sync_page_test.dart` —— debug 面板渲染阶段日志且随 notifier 更新、计数正确。

### 8.7 Task 8/9：可达性、生命周期与自动化验证口径

M7 的最小实现沿用单一 `SyncPageLoader` 所有权边界：页面始终挂载一个
`JwWebViewSurfaceHost` 子树，只通过 `Offstage` 改变可见性；gateway 在控制器完成
初始化、事件流就绪和策略配置后才 attach。作业结束或页面销毁时，所有权顺序为：

```text
拒绝新作业 → 取消未终态作业 → 等待终态 settlement
→ detach surface 并等待 placeholder frame
→ stop → clear browsing data → dispose
→ 等待 WebView2 environment release → 关闭订阅/诊断流
```

每个原生控制器只绑定一个不透明的本地 `accountId` 分区。UDF 位于应用支持目录下
的 account 子目录，路径经过不透明 ID 清理且不进入诊断；minimal 不保存跨重启的
session snapshot/DPAPI 会话快照，冷启动后可能需要重新登录。gateway 同一时刻只
维护一个账号/控制器，避免 WebView2 environment 与 UDF 锁竞争。

导航和采集均 fail-closed：受信目标同时需要 URL、DOM selector 和注册 handshake；
CAS 之后必须取得权威身份匹配，权威缺失或任一旁证冲突都不能继续。course/exam
读取另外验证同源请求形状、响应边界和唯一考试表；lesson ID 不合法时不会发起
datum 请求。诊断只记录阶段名和稳定错误码，不记录 query、ticket、cookie、DOM、
用户名、data ID、响应体或课程数据。

gateway 的 `poll` 以事件/终态变更唤醒，并保留有界 long-poll 兜底；同步协调器不再
依赖固定延时 spin。取消在每个主要阶段检查，取消终态优先于迟到结果，已取消作业
不会触发晚到的 import。

Task 8 的 credential-free Windows loopback gate 覆盖 portal → CAS → home →
course context → get-data → datum → exam table → SourceBundle，以及真实插件纹理
surface 的 detach/stop/dispose 和 environment-release 清理。loopback 只证明本机
fixture、Dart 合约与 WebView2 生命周期；它没有访问学校主机、真实账号或真实 Cookie，
不构成真实校园验收。Task 9 的最终命令、退出码、通过/失败计数和清理检查应追加在
下方的验证记录中；若 Flutter gate 某一步失败，必须停止后续 Flutter 步骤并原样
记录失败，不能由后续成功命令掩盖。

真实校园机器的最小人工 stage chain 为：

```text
login entry → CAS → identity verified → course context → get-data
→ datum → exam table → bundle built → imported → schedule visible
```

操作者只需记录脱敏的阶段结果、聚合计数和错误码；不得记录账号、查询参数、票据、
Cookie、响应体、data ID 或私人课表。请将 loopback/构建结果与该人工 chain 分开
报告，并在 owner 明确确认前保持“真实校园验收未完成”。

#### Task 9 自动化验证记录（2026-08-29）

- 进程预检：执行 `Get-Process flutter,dart,ustc_assistant_app`，开始前和完成后
  均未发现相关进程；未终止其他任务。诊断发现首次 sandbox 命令静默是因为 Flutter
  SDK 位于受限目录，`shared.bat` 无法写入 `cache/flutter.bat.lock`，遂在锁获取循环
  中等待；未发现其他 Flutter 命令持有者。
- Windows loopback：在修正上述执行权限后，按要求启动一次 fresh 命令，退出码 0，
  输出 `00:03 +1: All tests passed!`；构建阶段约 23.4s。无设备断开；完成后无
  Flutter/Dart/app 残留，canonical loopback UDF 为 `UDF_CHILD_COUNT=0`。Application
  Event Log 查询在受限 shell 中不可用，因此不宣称 Error 1000 计数。该项仍只证明
  loopback 自动化，不构成真实校园验收。
- Flutter 三件套：在同一 PowerShell 终端从 `app/` 开始执行
  `analyze --no-pub → test --no-pub --reporter expanded → build windows --release
  --no-pub`；analyze 实际运行约 8.0s 后退出 1，输出 18 issues（13 info、5 warning，
  无 error）。按规则 test 和 build 未运行，未重启第二套 Flutter 命令。
- Python oracle：使用临时、仅进程级的 `PYTHONPATH` 指向当前 worktree 的绝对
  `src`，先断言 `ustc_assistant.__file__` 位于该目录；unittest 实际为 `Ran 140
  tests in 1.666s`、`OK`，compileall 退出 0。不安装依赖、不改变环境。
- 本机已知限制：若出现 `sqlite3.dll` FFI error 126，记录为宿主环境缺少动态库，
  不复制/下载 DLL、不把失败伪装成基线通过；历史 migration/golden 基线也按 §6
  原因区分。真实校园验收仍未由本机自动化代替。

