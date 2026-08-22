# M5 三端构建错误静态分析清单

> 分支：`refactor/webview-minimal`
> 依据：`docs/plan-webview-minimal-m5.md` Task 4
> 状态：M5 本机静态分析产出（本 VM 不能构建任何二进制）。每条配 M6 外部机器的解决方向。
> 关联提交：`4c8b75e`（T1 工厂）、`94bfefc`（T2 通知）、`6a8c5a3`（T3 WebView stub）。

## 0. 范围与前提

- 本 VM **不能**构建 Windows/Android/iOS 二进制，也不访问真实学校网站。M5 的"三端可编译"
  只通过 `flutter analyze` 静态保证：lib 顶层不出现平台专属 import/直构，所有平台差异
  收敛到注入工厂或 `Platform.isXxx` 的隔离文件中。
- 本文件是**静态分析**三端构建会遇到的错误清单，供 M6 在外部有 SDK 的机器逐条解决。
- M5 后 lib 顶层（除 `core/security/` 工厂与实现文件外）**无 Windows-only 直构**，无
  `package:win32` / `dart:ffi` 顶层引用（详见 §5 静态验证结果）。

## 1. Windows

### 1.1 现状

- `windows/runner/` 完整存在（`main.cpp`、`flutter_window.cpp`、`CMakeLists.txt`、
  `Runner.rc` 等），是 Flutter 默认 Windows runner。
- 旧版（`main` 基线）Windows Release 构建已验证成功，输出目录
  `app/build/windows/x64/runner/Release/`（见 `AGENTS.md` §"Windows 首版自动验证
  （2026-07-28）"）。
- pubspec 已含 `win32: 6.3.0`、`ffi: 2.2.0`、`flutter_local_notifications: 22.2.0`，
  均为 Windows 构建所需且已离线 pub get 解析。

### 1.2 M5 新增/保留的 Windows 依赖

- **凭据保护**：`WindowsDpapiProtector`（`core/security/windows_dpapi_protector.dart`）
  依赖 `package:win32` + `dart:ffi` 调用 DPAPI。M5 **未改动**该文件；改为经
  `defaultCredentialProtector()` 工厂（`Platform.isWindows ? WindowsDpapiProtector() :
  FallbackCredentialProtector()`）分派。Windows 构建路径不变。
- **通知**：`ForegroundNotificationAdapter` 仍设 `windows:
  WindowsInitializationSettings(...)` / `windows: WindowsNotificationDetails()`，
  额外新增了 `android:` / `iOS:` 参数——`flutter_local_notifications` 22.2.0 在
  非 Android/iOS 平台运行时**忽略**这些参数，不影响 Windows 构建/运行。

### 1.3 预期错误

- **无新增 build 错误**。Windows 是 M5 前唯一真实构建目标，M5 改动均为平台无关分派，
  Windows 路径行为等价。
- 唯一需注意：若 M6 在 Windows 上跑 `flutter analyze`，应与本机一致（0 error）；
  Windows 真实 Release 构建应复现旧版成功（`AGENTS.md` §2026-07-28 已记录）。

### 1.4 M6 解决方向

- 在外部 Windows 机器执行 `flutter build windows --release`，确认输出目录与旧版一致。
- 无需新增 Windows 配置；若 `flutter_local_notifications` Windows 子包有版本升级要求，
  按 plugin README 处理（当前 22.2.0 已含 Windows 支持）。

## 2. Android

### 2.1 现状

- `android/` 脚手架存在（Flutter 默认）。`android/app/build.gradle.kts` 用
  `minSdk = flutter.minSdkVersion`、`targetSdk = flutter.targetSdkVersion`、
  `compileSdk = flutter.compileSdkVersion`（均跟随 Flutter 3.44 默认值，未显式钉死）。
- `AndroidManifest.xml`（main）当前**无** `POST_NOTIFICATIONS` / `VIBRATE` 权限声明，
  无通知 channel 配置，无 `flutter_local_notifications` 调度权限。
- pubspec **未含** `flutter_secure_storage`、**未含** `webview_flutter`（M5 不引入）。

### 2.2 凭据保护（M6 引入 `flutter_secure_storage`）

- **预期错误**：M5 fallback（`FallbackCredentialProtector`，XOR 混淆）在 Android 可编译
  但**非生产级**。M6 替换为 `flutter_secure_storage` 后，需在 pubspec 加入该依赖（离线
  pub-cache 不可用，外部机器 `flutter pub add flutter_secure_storage` 解析）。
- **`flutter_secure_storage` Android 配置**：需 Android 6.0 (API 23)+；默认使用
  `EncryptedSharedPreferences`（Android Keystore）。**预期错误**：若未配置
  `android:enableBackup` 或 minSdk < 23，构建/运行失败。
- **解决方向（M6）**：
  1. pubspec 加 `flutter_secure_storage`（外部机器 pub get）。
  2. 新增 `SecureStorageCredentialProtector implements CredentialProtector`，
     scheme 如 `flutter-secure-storage`，version `1`。
  3. 工厂分派改为 `Platform.isWindows ? WindowsDpapiProtector() :
     Platform.isAndroid || Platform.isIOS ? SecureStorageCredentialProtector() :
     FallbackCredentialProtector()`。
  4. `android/app/build.gradle.kts` 确保 `minSdk >= 23`（Flutter 3.44 默认 24 已满足）。
  5. 视 `flutter_secure_storage` README 决定是否设
     `android:enableBackup="false"` 或 auto-backup 规则（避免 Keystore 密钥被备份）。

### 2.3 通知（`flutter_local_notifications` Android 13+）

- **预期错误 1 — POST_NOTIFICATIONS 运行时权限**：从 Android 13 (API 33) 起，应用需
  运行时请求 `POST_NOTIFICATIONS` 权限才能显示通知。`flutter_local_notifications` 自
  v16 起只在 plugin 自身 manifest 声明 bare-minimum（`POST_NOTIFICATIONS` + `VIBRATE`），
  应用需在 `AndroidManifest.xml` 显式声明并运行时请求
  （`AndroidFlutterLocalNotificationsPlugin.requestPermission()`）。
  - **解决方向（M6）**：在 `android/app/src/main/AndroidManifest.xml` 的 `<manifest>`
    顶层加 `<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>`；
    在 app 启动/首条提醒前调用 `flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestPermission()`（注意 Android < 13 返回 null/无需请求）。
- **预期错误 2 — targetSdk/compileSdk**：`flutter_local_notifications` 22.2.0 的 Android
  子包 `compileSdk 36`、`minSdkVersion 24`。应用若 `compileSdk < 33` 则无法使用 Android 13
  通知权限 API。Flutter 3.44 默认 `compileSdk`/`targetSdk` 已 ≥ 34，应满足；但需确认。
  - **解决方向（M6）**：确认 `flutter.compileSdkVersion >= 33`；若 plugin 要求 36 而应用
    `compileSdk` 低于此，Gradle 会报 `Dependency ... requires compileSdkVersion 36`，
    按提示在 `build.gradle.kts` 显式设 `compileSdk = 36`。
- **预期错误 3 — 通知 channel**：M5 `deliver()` 用 `AndroidNotificationDetails('reminders',
  '提醒', channelDescription: '日程与任务提醒', importance: Importance.high)`。
  `channelAction` 默认 `createIfNotExists`，首次 `show()` 会自动建 channel，**无需手动
  预建**。但若 `importance` 与 channel 首次创建值不一致会冲突。
  - **解决方向（M6）**：保持首次创建即用 `Importance.high`；真机验证 channel 在系统设置
    可见、提醒可弹出。
- **预期错误 4 — 图标资源**：`AndroidInitializationSettings('@mipmap/ic_launcher')` 要求
    `@mipmap/ic_launcher` 存在。Flutter 默认 Android 脚手架已含 `ic_launcher`，应满足。
  - **解决方向（M6）**：真机验证通知图标不显示为纯色方块；必要时提供透明 PNG 通知图标。

### 2.4 WebView（M6 引入 `webview_flutter`）

- **现状**：M5 `JwWebViewAdapter` 是 stub，所有方法抛 `UnimplementedError`，**未**引入
  `webview_flutter`。`webview_flutter` 4.9.0 + `webview_flutter_android` 3.16.9 在
  pub-cache 可用但未加 pubspec。
- **预期错误**：M6 接入真实 WebView 后需 `flutter pub add webview_flutter`。
  `webview_flutter_android` 要求 `minSdkVersion 19`（Flutter 默认 24 满足）。
  Android **无需**额外 manifest 权限（WebView 走应用 INTERNET 权限，debug/profile
  manifest 已声明；release 需确认 main manifest 含 `INTERNET`）。
  - **解决方向（M6）**：
    1. pubspec 加 `webview_flutter`（外部机器 pub get）。
    2. 确认 `android/app/src/main/AndroidManifest.xml` 含
       `<uses-permission android:name="android.permission.INTERNET"/>`（当前 main manifest
       **未声明** INTERNET，仅 debug/profile 有；release 构建联网需补到 main）。
    3. 替换 stub 方法体为真实 `WebViewController` 调用，对齐 M3 `JwWebPage` 契约。
- **INTERNET 权限注意**：当前 `android/app/src/main/AndroidManifest.xml` **未**声明
  `INTERNET`（仅 debug/profile 声明）。M5 不联网（stub 抛异常），但 M6 真实 WebView 与
  Agent 学校 API 调用都需要联网——**M6 必须在 main manifest 补 `INTERNET` 权限**，否则
  release 包联网失败。

## 3. iOS

### 3.1 现状

- `ios/` 脚手架存在（Flutter 默认）。`ios/Runner/Info.plist` 当前**无**任何通知权限相关
  key，无 Keychain 配置，无 WKWebView 配置。
- pubspec **未含** `flutter_secure_storage`、**未含** `webview_flutter`（M5 不引入）。

### 3.2 凭据保护（M6 引入 `flutter_secure_storage`）

- **预期错误**：M5 fallback（XOR 混淆）在 iOS 可编译但非生产级。M6 替换为
  `flutter_secure_storage` 后，iOS 默认用 **Keychain**。
- **`flutter_secure_storage` iOS 配置**：**预期错误** —— iOS 10+ 需在 `Info.plist` 配置
  Keychain 共享 group 或确保 `kSecAttrAccessible` 策略；更关键的是若 App 开启
  `UIBackgroundModes` 或使用数据保护，需确保 Keychain item 的可访问性类
  （`kSecAttrAccessibleWhenUnlocked` 等）与 App 行为一致。
  - **解决方向（M6）**：
    1. pubspec 加 `flutter_secure_storage`。
    2. 复用 §2.2 的 `SecureStorageCredentialProtector`（同一实现覆盖 Android + iOS）。
    3. iOS 默认 `flutter_secure_storage` 用 Keychain，**无需**额外 `Info.plist` key 即可
       存取；但需确认签名/entitlements（Keychain 访问需有效签名）。
    4. 若需跨 App 共享，配 Keychain Sharing entitlement（本 App 不需要）。

### 3.3 通知（`flutter_local_notifications` iOS）

- **预期错误 1 — 通知权限请求**：iOS 本地通知**不需要** `Info.plist` 特定 key，但需运行时
  请求授权。`DarwinInitializationSettings()` 默认 `requestAlertPermission=true` 等，插件
  在 `initialize()` 时自动请求。**预期错误**：若未在模拟器/真机授权，通知不显示（非 build
  错误，是运行时行为）。
  - **解决方向（M6）**：真机验证首次启动弹出通知授权对话框；若需延迟请求，设
    `requestAlertPermission: false` 后手动调 `requestPermissions(...)`。
- **预期错误 2 — 前台呈现**：iOS 14+ 用 `presentBanner`/`presentList`（默认 true），应满足。
  - **解决方向（M6）**：真机验证前台收到提醒时 banner/list 正常呈现。
- **Info.plist**：当前 `Info.plist` **无** `UIBackgroundModes`。本 App 提醒为前台定时触发
  （`ReminderTimerScheduler`），**不**需要后台通知，故无需补 `UIBackgroundModes`。若 M6/M8
  需后台调度提醒再评估。

### 3.4 WebView（M6 引入 `webview_flutter_wkwebview`）

- **现状**：M5 `JwWebViewAdapter` 是 stub，未引入 `webview_flutter`。
  `webview_flutter_wkwebview` 3.26.0 在 pub-cache 可用但未加 pubspec。
- **预期错误**：M6 接入真实 WebView 后，`webview_flutter` 顶层包会自动拉
  `webview_flutter_wkwebview`（iOS 用 WKWebView）。iOS **无需**额外 `Info.plist` key
  （WKWebView 是系统组件，联网走 ATS）。
  - **解决方向（M6）**：
    1. pubspec 加 `webview_flutter`（外部机器 pub get，自动拉 wkwebview 平台包）。
    2. **App Transport Security (ATS)**：JW 站点 `jw.ustc.edu.cn` 是 HTTPS，应满足 ATS
       默认策略；若采集过程涉及 HTTP 资源或自签证书，需在 `Info.plist` 配
       `NSAppTransportSecurity` 例外（不建议全局关闭 ATS）。
    3. 替换 stub 方法体为真实 `WebViewController` 调用，对齐 M3 `JwWebPage` 契约。
    4. 真机验证 WKWebView 能加载 CAS 登录页、执行 JS 填表、拦截 get-data 请求。

## 4. M6 外部机器执行顺序建议

1. **pubspec 加依赖**：`flutter pub add flutter_secure_storage webview_flutter`
   （外部机器联网 pub get）。
2. **Windows**：`flutter build windows --release` 先确认无回归（M5 改动等价）。
3. **Android**：补 main manifest `INTERNET` + `POST_NOTIFICATIONS` 权限；确认
   `compileSdk >= 33`；运行时请求通知权限；`flutter build apk --release`。
4. **iOS**：确认签名/entitlements；真机请求通知授权；评估 ATS；`flutter build ios --release`。
5. **替换 stub**：用真实 `WebViewController` 实现 `JwWebViewAdapter` 各方法，对齐 M3 契约。
6. **替换 fallback**：用 `flutter_secure_storage` 实现 `SecureStorageCredentialProtector`，
   工厂分派覆盖 Android + iOS。
7. **真实人工验收**：教务采集 + Agent（真实 Key + 校园网/iWAN + 学校登录）。

## 5. 本机静态验证结果（M5 门）

M5 后在本 VM 执行的静态验证（`flutter analyze` 0 error）：

```
# A) lib/app + lib/features 顶层 Windows-only 直构（应 0）
$ grep -rn "WindowsDpapiProtector()" lib/app/ lib/features/
# → 0 匹配（exit 1）。7 处直构全部改走 defaultCredentialProtector() 工厂。

# B) windows_dpapi / WindowsDpapiProtector 在 lib/ 中除 core/security 外（应 0）
$ grep -rln "windows_dpapi_protector\|WindowsDpapiProtector" lib/ | grep -v "core/security/"
# → 0 匹配。引用已收敛到 core/security/ 工厂与实现文件内。

# C) package:win32 / dart:ffi 在 lib/ 中
$ grep -rln "package:win32\|dart:ffi" lib/
# → 仅 lib/core/security/windows_dpapi_protector.dart（隔离实现文件）。

# D) Platform.isXxx 在 lib/ 中（sanctioned 隔离点）
$ grep -rn "Platform.is" lib/
# → lib/core/security/credential_protector_factory.dart:19  (凭据工厂分派，sanctioned)
#   lib/features/sync/data/python_locator.dart:79,157       (Bridge 兼容代码，M7 删)
# 无 lib/app/ lib/features 顶层散落的 Platform 分支。

# E) webview_flutter 在 lib/ 中（应仅注释，无真实 import）
$ grep -rn "webview_flutter" lib/
# → 5 处均为注释（M3/M5 文档说明），无 import 语句。stub 不依赖该包。

# F) 通知 adapter all-params 模式（应 >= 1）
$ grep -c "AndroidInitializationSettings\|DarwinInitializationSettings" \
    lib/features/reminders/data/foreground_notification_adapter.dart
# → 2（initialize 设 android+iOS，deliver 设 android+iOS）。
```

### 结论

- **lib 顶层（`lib/app/` + `lib/features/`，除 `core/security/` 工厂与实现文件外）无
  Windows-only 直构**：7 处 `WindowsDpapiProtector()` 已全部改走
  `defaultCredentialProtector()`；`package:win32`/`dart:ffi` 仅存在于隔离实现文件
  `windows_dpapi_protector.dart`；`Platform.isXxx` 仅出现在凭据工厂（sanctioned）与
  `python_locator.dart`（Bridge，M7 删）。
- **通知 adapter 已用 all-params 模式**同时设 `windows` + `android` + `iOS`，运行时插件
  忽略非当前平台参数，单一构造调用覆盖三端，无 `Platform.isXxx` 分支。
- **WebView stub** 接口契约对齐 M3 `JwWebPage`，方法体抛 `UnimplementedError`，不依赖
  `webview_flutter`，analyze 绿。
- 三端真实构建错误及解决方向见 §1–§3，交 M6 外部机器执行。

## 6. 7 项基线已知失败（M5 未引入新失败）

M5 `flutter test` 结果：**1358 通过 / 7 失败**，7 项失败全部为 M0 基线已知失败
（`c7637ad` 起，每个里程碑验证不变）：

1. `agent_write_permission_domain_test.dart: schema v4 migrates the v3 policy/action_log
   tables`（`no such table: calendar_event_series`）
2. `responsive_golden_test.dart: agent chat phone-390x844`（环境字体渲染差异）
3. `responsive_golden_test.dart: agent chat phone-412x915`（同上）
4. `responsive_golden_test.dart: agent chat windows-1440x900`（同上）
5–7. 其余 3 个 golden 测试（同字体渲染差异）

M5 改动未引入任何新测试失败。
