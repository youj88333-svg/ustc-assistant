# M5 详细实施计划：跨平台凭据/通知/WebView 权限适配 + 静态分析

> 分支：`refactor/webview-minimal`（M4 已完成）
> 依据：`docs/plan-webview-minimal.md` §3（M5 目标）与 §2 目标第 4 条
> 目标（M5 门）：本机 `flutter analyze` 无 error、`flutter test` 全绿（除 7 项基线已知
> 失败）；三端可编译的静态接口落地；三端 build 错误清单落档。

## 0. 范围与非范围

### 0.1 环境 constraint（已实测）

- 本 VM **不能构建** Windows/Android/iOS 二进制，也不访问真实学校网站。
- `flutter analyze` 与 `flutter test` 可用（pub get 已离线就绪）。
- 因此 M5 的"三端可编译"只能通过**静态分析**保证：lib 顶层不出现平台专属 import
  （`package:win32`、`dart:ffi` 调用 DPAPI、`WindowsInitializationSettings` 等），
  所有平台差异收敛到注入工厂或 `Platform.isXxx` 分支的隔离文件中。
- 真实构建交给 M6 外部有 SDK 的机器。

### 0.2 做

1. **凭据保护跨平台**：新增平台无关 `CredentialProtector` 工厂 + 各端实现隔离。
   - Windows：保留现有 `WindowsDpapiProtector`（DPAPI，已在 `core/security/`）。
   - Android/iOS：新增基于 `flutter_secure_storage` 的实现（或 fallback 的
     应用私有目录加密实现），**不引入 Windows-only 依赖到顶层**。
   - router.dart 的 5 处 + sync_page.dart 的 2 处 `WindowsDpapiProtector()` 直构
     （共 **7 处**）改为平台分派工厂调用。
2. **通知适配跨平台**：`ForegroundNotificationAdapter` 的 init/deliver 当前硬编码
   `WindowsInitializationSettings` / `WindowsNotificationDetails`；改为按平台分支
   构造 `InitializationSettings` / `NotificationDetails`（Android 用
   `AndroidInitializationSettings` + channel；iOS 用 `DarwinInitializationSettings`；
   Windows 保持）。
3. **WebView 采集器适配器脚手架**：M3 的 `JwWebPage` 是抽象注入点；M5 新增
   `JwWebViewAdapter`（基于 `webview_flutter` 或平台 channel）的**接口与空实现**，
   真实 WebView 调用不在本机测，只保证 `analyze` 绿 + 接口契约对齐 M3。
   - 若 `webview_flutter` 包在本环境不可用（离线 pub get 限制），则只落接口 +
     stub 实现 + 文档说明真实适配在 M6 外部机器接。
4. **三端 build 错误清单**：新增 `docs/m5-three-platform-build-analysis.md`，
   静态分析三端构建会遇到的错误（缺 SDK、平台插件未配置、原生权限声明等），
   每条配解决方向，交 M6 外部机器执行。

### 0.3 不做

- 不在本机构建任何二进制。
- 不改 schema、不改 Agent 工具/提示词/grounding（M1–M4 已收敛）。
- 不改 SourceBundle 契约 / JW 采集器状态机（M2–M3 已完成）。
- 不删 Python Bridge（M7）。
- 不做真实人工验收（M6）。
- 不引入本环境 pub get 无法解析的新依赖到 pubspec（若 `flutter_secure_storage`/
  `webview_flutter` 离线不可用，则用条件 import 或 stub + 文档）。

## 1. 现状分析（已核对代码）

### 1.1 凭据保护（credential_protector.dart + windows_dpapi_protector.dart）

- `CredentialProtector` 是 `abstract interface class`（`credential_protector.dart:26`），
  已是平台无关接口。
- `WindowsDpapiProtector implements CredentialProtector`（`windows_dpapi_protector.dart`），
  依赖 `package:win32` + `dart:ffi`——**只在 Windows 可编译**。
- **共 7 处直构** `WindowsDpapiProtector()` 散落在两个文件：
  - `app/lib/app/router.dart` 5 处：`:147`（AccountService）、`:458`、`:501`、`:707`、`:719`
    （AgentComposition build）。
  - `app/lib/features/sync/presentation/sync_page.dart` 2 处：`:27`、`:103`
    （import 在 `:7`）。这 2 处同样是顶层 Windows-only 直构，必须一并改。
- `AgentComposition.build` 已通过 `SecretStoreFactory` 注入（`agent_composition.dart:27`），
  注释明确写了 Android/iOS 应注入 flutter_secure_storage 实现——**架构已就绪**，
  只缺 (a) 各端实现 (b) router + sync_page 的平台分派。

### 1.2 通知（foreground_notification_adapter.dart）

- `ForegroundNotificationPort` 是 `abstract interface class`，`ForegroundNotificationAdapter`
  `implements` 它。
- `initialize()` 硬编码 `WindowsInitializationSettings`（`:36-41`）。
- `deliver()` 硬编码 `WindowsNotificationDetails`（`:62-65`）。
- **关键简化**：`flutter_local_notifications` 22.2.0 的 `InitializationSettings` 和
  `NotificationDetails` 构造器**同时接受所有平台参数**（`android`/`iOS`/`windows`/`linux`/
  `macOS`/`web`，各自 nullable，运行时忽略非当前平台的参数）。因此跨平台适配**不需要**
  `Platform.isXxx` 分支——只需在单个构造调用里同时设置 Windows + Android + iOS 参数，
  插件自动忽略非当前平台的。
- `WindowsReminderReconciler`（`windows_reminder_reconciler.dart`）名带 Windows 但
  本身是纯 Dart（依赖注入的 `ForegroundNotificationPort`），只是类名误导。
- **app.dart:44-47** 直构 `WindowsReminderReconciler` + `ForegroundNotificationAdapter()`。

### 1.3 WebView（M3 产物）

- `JwWebPage` 是 `abstract class`（`jw_web_page.dart`，有 `close()` 默认实现，故非
  `interface`），是 M3 采集器的注入 seam。
- 目前无真实 `JwWebPage` 实现（M3 测试用 fake）。M5 需落适配器接口/脚手架。
- `webview_flutter` 是否在离线 pub get 可用需实测；不可用则只落接口 + stub。

### 1.4 平台检查

- lib 中仅 `python_locator.dart` 有 `Platform.isWindows`（`:79`、`:157`），属 Bridge
  兼容代码（M7 删），M5 不动。
- pubspec 已含 `win32`、`ffi`、`flutter_local_notifications`。
- **Task 1 将在 `credential_protector_factory.dart` 内新增一个 `Platform.isWindows`
  分支**——这是**有意隔离**的平台分派点（ sanctioned isolation file），与 lib 顶层
  散落的直构不同：工厂是唯一允许引用 `Platform.isXxx` 的凭据入口，其余 lib 文件经
  工厂调用获得 `CredentialProtector`，不再直接 import `windows_dpapi_protector.dart`。
  §4 的静态验证断言"lib 顶层（除 `core/security/` 工厂文件外）无 Windows-only 直构"
  即指此设计。

## 2. 文件架构

### 2.1 新增文件

```
app/lib/core/security/credential_protector_factory.dart   (新建)
  └─ 平台分派工厂：defaultCredentialProtector() → Windows/Android/iOS 实现
  └─ 用 Platform.isXxx 分派；Windows 走 WindowsDpapiProtector，其他走 fallback

app/lib/core/security/fallback_credential_protector.dart   (新建)
  └─ 非 Windows fallback：应用私有目录 + XOR/平台 keystore 的最小实现
  └─ 或条件 import flutter_secure_storage（若离线可用）
  └─ 明确标记 NOT production-grade，M6 外部机器替换为 flutter_secure_storage

app/lib/features/sync/native/jw_webview_adapter.dart   (新建，可选)
  └─ JwWebViewAdapter implements JwWebPage（基于 webview_flutter 或 stub）
  └─ 若 webview_flutter 离线不可用，落 stub + TODO(M6)

docs/m5-three-platform-build-analysis.md   (新建)
  └─ 三端 build 错误清单（静态分析产出）
```

### 2.2 修改文件

```
app/lib/app/router.dart   (改)
  └─ 5 处 WindowsDpapiProtector() → defaultCredentialProtector()

app/lib/features/sync/presentation/sync_page.dart   (改)
  └─ 2 处 WindowsDpapiProtector() → defaultCredentialProtector()（import 也改）

app/lib/features/reminders/data/foreground_notification_adapter.dart   (改)
  └─ initialize()/deliver() 的 Windows-only Settings → all-params 模式
     （同时设 windows + android + iOS 参数，运行时忽略非当前平台）
```

### 2.3 不改文件

- `windows_dpapi_protector.dart`（保持原样，被工厂调用）
- `credential_protector.dart`（接口不变）
- `agent_composition.dart`（注入架构不变）
- 所有 M1–M4 产物

## 3. Tasks

### Task 1: 凭据保护平台分派工厂

**Files:**
- Create: `app/lib/core/security/credential_protector_factory.dart`
- Create: `app/lib/core/security/fallback_credential_protector.dart`
- Modify: `app/lib/app/router.dart`（5 处直构改工厂调用）
- Modify: `app/lib/features/sync/presentation/sync_page.dart`（2 处直构 + import 改工厂调用）

**Interfaces:**
- Consumes: `CredentialProtector`（`credential_protector.dart`）、`WindowsDpapiProtector`
- Produces: `CredentialProtector defaultCredentialProtector()`

- [ ] **Step 1**: 实测 `flutter_secure_storage` 是否离线 pub get 可用。
  ```bash
  cd app && /home/ubuntu/flutter/bin/flutter pub add flutter_secure_storage --dry-run 2>&1 | tail -5
  ```
  若不可用，fallback 用纯 Dart 实现（应用私有目录 + 简单加密），标记 M6 替换。
- [ ] **Step 2**: 写 `fallback_credential_protector.dart`——`FallbackCredentialProtector
  implements CredentialProtector`，用 `Platform` 路径 + XOR/简单加密（非生产级，
  注释明确）。
- [ ] **Step 3**: 写 `credential_protector_factory.dart`——`CredentialProtector
  defaultCredentialProtector()`：`Platform.isWindows ? WindowsDpapiProtector() :
  FallbackCredentialProtector()`。
- [ ] **Step 4**: 改 **7 处** `WindowsDpapiProtector()` → `defaultCredentialProtector()`：
  router.dart `:147`/`:458`/`:501`/`:707`/`:719` + sync_page.dart `:27`/`:103`。
  sync_page.dart 的 import 也从 `windows_dpapi_protector.dart` 改为
  `credential_protector_factory.dart`。router.dart 同理把 import 改为工厂
  （保留 windows_dpapi 的 import 仅在工厂文件内）。
- [ ] **Step 5**: `flutter analyze` 绿。
- [ ] **Step 6**: `flutter test` 全绿（除 7 基线）。
- [ ] **Step 7**: Commit。

### Task 2: 通知跨平台适配

**Files:**
- Modify: `app/lib/features/reminders/data/foreground_notification_adapter.dart`
- Test: 新增 `app/test/features/reminders/foreground_notification_adapter_test.dart`（若尚无）

**关键简化**：`InitializationSettings` 和 `NotificationDetails` 构造器同时接受所有平台参数
（各自 nullable，运行时忽略非当前平台）。因此不需要 `Platform.isXxx` 分支，只需在单个
构造调用里同时设置 Windows + Android + iOS 参数。

- [ ] **Step 1**: 改 `initialize()` 的 `InitializationSettings`——从只设 `windows:` 改为
  同时设 `windows:` + `android:` + `iOS:`：
  ```dart
  settings: const InitializationSettings(
    windows: WindowsInitializationSettings(
      appName: 'USTC Assistant',
      appUserModelId: 'Ustc.Assistant.Development',
      guid: '66bcb098-3b43-4f4d-aebb-22ea2c112c5d',
    ),
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(),
  ),
  ```
- [ ] **Step 2**: 改 `deliver()` 的 `NotificationDetails`——从只设 `windows:` 改为同时设
  `windows:` + `android:` + `iOS:`：
  ```dart
  notificationDetails: NotificationDetails(
    windows: const WindowsNotificationDetails(),
    android: AndroidNotificationDetails(
      'reminders', '提醒', channelDescription: '日程与任务提醒', importance: Importance.high,
    ),
    iOS: const DarwinNotificationDetails(),
  ),
  ```
- [ ] **Step 3**: 若无现成测试，新增最小测试验证 `initialize()` 不抛 + `deliver()` 在
  fake plugin 下不抛（用现有测试模式）。
- [ ] **Step 4**: `flutter analyze` 绿 + `flutter test` 全绿。
- [ ] **Step 5**: Commit。

> 注意：`AndroidNotificationDetails` 需要 channel id/name；`Importance` 来自
> `flutter_local_notifications`。这些类在 pub-cache 的 22.2.0 中可用（已核实）。
> 不需要 `cross_platform_notification_settings.dart` 分派文件——all-params 模式使
> adapter 直接内联即可。

### Task 3: WebView 采集器适配器脚手架

**Files:**
- Create: `app/lib/features/sync/native/jw_webview_adapter.dart`

**决策**：默认落 `UnimplementedError` stub，**不引入 `webview_flutter` 到 pubspec**。
理由：M5 门是静态 analyze 绿；引入 `webview_flutter`（虽离线可用）会动 lockfile/pub get，
增加风险且本机无法测试真实 WebView。真实 wiring 属 M6 外部机器。stub 保证接口契约
对齐 M3 的 `JwWebPage`，analyze 绿即可。

- [ ] **Step 1**: 写 stub `JwWebViewAdapter implements JwWebPage`——所有方法抛
  `UnimplementedError('M6: wire real WebView on external machine')`，
  保证 `analyze` 绿 + 接口契约对齐 M3。
- [ ] **Step 2**: `flutter analyze` 绿。
- [ ] **Step 3**: Commit。

### Task 4: 三端 build 错误清单

**Files:**
- Create: `docs/m5-three-platform-build-analysis.md`

- [ ] **Step 1**: 静态分析三端构建 prerequisites：
  - Windows：已有 `windows/` runner，Release 构建已知可（旧版验证过）。
  - Android：`android/` 脚手架存在；需检查 `minSdkVersion`、
    `flutter_secure_storage`/`webview_flutter` 的 Android 权限/配置、
    `flutter_local_notifications` 的 Android 13+ 通知权限。
  - iOS：`ios/` 脚手架存在；需检查 `flutter_secure_storage` 的 Keychain 配置、
    `webview_flutter` 的 WKWebView、通知权限 `Info.plist`。
- [ ] **Step 2**: 列出每端的预期 build 错误 + 解决方向（供 M6 执行）。
- [ ] **Step 3**: 记录本机静态验证结果（analyze 绿的 lib 顶层无平台专属 import）。
- [ ] **Step 4**: Commit。

## 4. 验证步骤（M5 门）

**7 项基线已知失败**（M0 基线 `c7637ad` 起，非里程碑引入，每个里程碑验证不变）：
1. `agent_write_permission_domain_test.dart: schema v4 migrates the v3 policy/action_log tables`（`no such table: calendar_event_series`）
2. `responsive_golden_test.dart: agent chat phone-390x844`（环境字体渲染差异）
3. `responsive_golden_test.dart: agent chat phone-412x915`（同上）
4. `responsive_golden_test.dart: agent chat windows-1440x900`（同上）
5–7. 其余 3 个 golden 测试（同字体渲染差异）

```bash
cd app
/home/ubuntu/flutter/bin/flutter analyze         # 0 error（info/warning 允许）
/home/ubuntu/flutter/bin/flutter test             # 全绿除 7 基线
# 静态验证 lib 顶层（除 core/security 工厂+实现文件外）无 Windows-only 直构：
# 以下应返回 0（7 处直构全部改走工厂）
grep -rn "WindowsDpapiProtector()" lib/app/ lib/features/
# 以下应 >= 1（all-params 模式同时设了 android + iOS）
grep -c "AndroidInitializationSettings\|DarwinInitializationSettings" lib/features/reminders/data/foreground_notification_adapter.dart
# 以下应只在 credential_protector_factory.dart + windows_dpapi_protector.dart 内
grep -rln "windows_dpapi_protector\|WindowsDpapiProtector" lib/ | grep -v "core/security/"
```

## 5. 提交

每个 Task 一个 commit（用户偏好"每个 Task 一个 commit"）：
- `feat(webview-minimal): M5 T1 — cross-platform credential protector factory`
- `feat(webview-minimal): M5 T2 — cross-platform notification settings`
- `feat(webview-minimal): M5 T3 — JW WebView adapter scaffold`
- `docs(refactor): M5 T4 — three-platform build error analysis`

## 6. 风险与缓解

- **风险**：`flutter_secure_storage`/`webview_flutter` 离线 pub get 不可用。
  **缓解**：用 `--dry-run` 实测；不可用则 fallback 纯 Dart + stub + 文档标记 M6 替换。
  绝不让 pubspec 引入无法解析的依赖导致 `flutter pub get` 失败。
- **风险**：通知平台分支在 Linux 测试机无法真实验证。
  **缓解**：测 Settings 类型断言（`isA<WindowsInitializationSettings>()` 等），
  不测真实通知投递；真实验证在 M6。
- **风险**：改 router.dart 5 处 + sync_page.dart 2 处 protector（共 7 处）引入回归。
  **缓解**：工厂返回相同接口；现有测试用 fake protector（`_NoopProtector`），
  不受影响；跑全量 test 确认。
- **风险**：WebView stub 让 M3 采集器测试误以为已实现。
  **缓解**：stub 方法体抛 `UnimplementedError`，不会通过任何真实采集测试。

## 7. 与 M6 的边界

M5 产出"可静态分析通过的三端接口 + build 错误清单"。M6 在外部有 SDK 的机器：
- 执行真实三端构建，按清单逐条解决 build 错误。
- 接入真实 WebView（替换 stub）。
- 替换 fallback 凭据保护为 flutter_secure_storage（若 M5 用了 fallback）。
- 真实人工验收（教务采集 + Agent）。
