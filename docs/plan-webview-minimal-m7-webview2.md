# 计划：按全量重构分支经验重写 minimal 原生 WebView（Windows WebView2）

> 分支：`refactor/webview-minimal`（M6 交接物已落档，本计划为 M6 之后的增量）
> 依据：`E:\107\.worktrees\rewrite\flutter-native` 的全量 `M2 Native JW` 真实踩坑复盘
> （`docs/refactor-docs/m2-native-jw-lessons.md`）与 `docs/acceptance/m2-native-jw.md`。
> 目标（本计划门）：minimal 教务采集从 Python Bridge 切换为 Flutter 原生 WebView2，
> 日常可基本正常使用；不追求全量分支的企业级 C1/C2/C3 分层。

## 0. 背景与动因

- 全量重构分支的 M2 已把 WebView2 采集链路打通，并在多轮真实 debug 构建与人工验收中
  修复了导航、CAS、身份核验、学期、请求载荷、取消、会话等一批问题（见
  `rewrite/flutter-native/docs/refactor-docs/m2-native-jw-lessons.md` 的"问题与根因台账"）。
- 本 minimal 分支当前仍是：
  - `lib/features/sync/native/jw_webview_adapter.dart` 为 **stub**（全部方法抛
    `UnimplementedError`）；
  - 运行时采集仍走 Python Bridge（`SyncPageLoader` / `runStartupAutomaticSync` 起
    `BridgeClient.start(python)`）；
  - `pubspec.yaml` 未引入任何 WebView 依赖。
- 因此本计划把全量分支"踩过的坑"直接落到 minimal 的 `JwWebPage` 实现点上，
  用最小代价替换 Python 运行通道。

### 0.1 本机的已验证事实（2026-08-26）

| 项 | 值 |
|---|---|
| Flutter | 3.44.5 / Dart 3.12.2（`/e/flutter/flutter`） |
| VS 2022 | `/e/Microsoft Visual Studio/18/community`（VC v143 / MSVC 14.42，`cl.exe` 就绪） |
| CMake / Ninja | `/e/Android/Sdk/cmake/3.22.1`、`/e/Espressif/tools/cmake/3.30.2`（本机可编译 Windows） |
| 代理 | 127.0.0.1:7897（pub.dev / github 可达，`flutter pub get` 可用） |
| 基线 | `flutter analyze` 0 error / 15 issues；`flutter test` 1360 pass / 7 fail（M0 起已知基线） |

### 0.2 关键结论：WebView2 插件可自足提取

全量分支的 `app/packages/webview_flutter_windows_secure` 只依赖 `flutter` SDK，不依赖
全量容器（`containers`/`source_engine`/`shared_core`），lib 侧无外部 import。因此可以
整体复制到 minimal 的 `app/packages/` 直接使用。

---

## 1. 目标（简化到"教务 + 日程 + agent"，日常可用）

1. 教务采集改为 Flutter 原生 WebView2，产出 `SourceBundle 1.0`，与 M2 已就位的 Dart
   builder / digest oracle 对齐。
2. 保留现有 `JwWebPage` 抽象与 `JwCollector` 状态机，只替换 `JwWebViewAdapter` 这一个
   实现点，并把它挂进 minimal 同步链路。
3. 本机可完成 Windows Release 编译验证；真实校园账号/校园网人工验收仍留外部机器或
   后续真实环境（照旧 M6 口径）。
4. 会话持久化不做（全量 M2 的 C++ session_snapshot/DPAPI 属于企业级；minimal 接受
   "重启后重新登录"）。

## 2. 直接采纳的全量分支踩坑结论（来源）

| 坑（全量教训编号） | 落入本条的动作 |
|---|---|
| 3.1 把 `/login` 误当账号密码页 | 区分 `jw.portal.login`（教务入口，只有"统一身份认证"按钮）与 `id.ustc.edu.cn/cas/login`（真实表单）；`fillLogin` 才点击激活 CAS，避免合并状态 |
| 3.2 点击后页面消失 / `First login failed` | 点击前先读取几何/可见性/遮挡；用 WebView2 原生主键点击（`dispatchPrimaryClick`）而非 `element.click()`；导航用独立 generation + 三信号任意顺序收敛 |
| 3.3 白名单逐次放宽导致回归 | 原生层同步裁决，编译期 host/path 白名单，未知 fail-closed，不记录 query/ticket 等敏感串 |
| 3.4 CAS `TicketValidationException` / `No principal` | CAS 激活只做一次；凭据提交后的重定向由浏览器自然完成；失败不得原地重播旧 URL，回新认证流 |
| 3.5 已进教务却报 `account_mismatch` | 权威账号证据匹配 expected username，可选旁证不得冲突；脚本只向 Dart 返回 matched/conflicted 布尔，不返回账号原文 |
| 3.6 默认选错学期 | minimal 本分支既定策略：用默认 `461 / 2026fall / 2026 秋季学期`（`generated_source_defaults.dart`），不做动态学期发现 |
| 3.7 课程表已出现但采集仍失败 | get-data 用 GET（`bizTypeId/semesterId/dataId`）；datum 用 POST + `Content-Type: application/json` + `X-Requested-With`，body `{"lessonIds":[...]}`（与 Python 一致，不能表单编码） |
| 3.9 取消与迟到导入 | 取消先递增 generation；旧作业终态 `cancelled`，迟到 stamp 拒绝 |
| 3.10 重启会话复用 | minimal 不做 C++ session 快照；明确"重启后重新登录"为已知边界 |
| 4.x 只记阶段不记秘密 | WebView 日志只记 `attempt→activationDispatched→urlMatched→domReady→readyHandshake→ready→fetch→…`，不记录 URL 详情/query/cookie/账号/DOM |

## 3. 任务拆解

### Task 1：基线快照（本机）
- 复跑并留档：
  - `flutter analyze` → 0 error / 15 issues
  - `flutter test` → 1360 pass / 7 fail（已知基线）
- 记录 HEAD，供 Task 结束对比。

### Task 2：引入自足 WebView2 插件包
- 拷贝全量分支 `app/packages/webview_flutter_windows_secure/` → minimal `app/packages/`。
- `app/pubspec.yaml` 加：
  ```yaml
  webview_flutter_windows_secure:
    path: packages/webview_flutter_windows_secure
  ```
- `flutter pub get`（代理 7897）。
- **关闭会话快照**：minimal 不调用 `restoreTrustedSessionSnapshot` /
  `persistTrustedSessionSnapshot`（flag 默认 false），保留 `clearBrowsingDataAll` 用于
  退出清会话。
- 验证：`flutter analyze` 0 error；`flutter build windows --release` 编译通过。

### Task 3：实现 `JwWebViewAdapter implements JwWebPage`（核心）
替换现有 stub 的 12 个方法体，逻辑对齐全量踩坑后的驾驶方式：

1. **URL 白名单**（编译期，仿 `JwEndpointPolicy`）：
   | host | 允许 path 前缀 |
   |---|---|
   | `jw.ustc.edu.cn` | `/`, `/home`, `/login`, `/ucas-sso`, `/for-std/course-table`, `/for-std/exam-arrange` |
   | `passport.ustc.edu.cn` | `/login` |
   | `analytics.ustc.edu.cn` | `/.isg/gateway` |
   | `id.ustc.edu.cn` | `/cas`, `/.isg/gateway` |

   经 `setNavigationPolicy(allowedOrigins/allowedPathPrefixes)` 同步裁决，未知 fail-closed；
   `denyDownloads`/`denyNewWindows`/`denyPermissions`。

2. **登录目标区分**：
   - `gotoRoot`/`gotoCasEntry`：只导航教务入口（`/login` 或 `/ucas-sso/login`）。
   - `fillLogin(credentials)`：受控点击"统一身份认证"→ 等 `id.ustc.edu.cn/cas/login`
     表单下手 → 填用户名/密码（一次性租约）→ 提交 → **不再重放**。
   - `waitForAuthenticatedHome`：等 `/home` 匹配 + DOM ready + 身份核验 handshake
     三者收敛（独立 generation，三信号任意顺序）。
   - 页面在文档切换期的 ExecuteScript 失败只在超时界限内重试，不当终态。

3. **注册脚本**（裁剪自全量 `jw_registered_scripts.dart`）：
   - `jw.cas.inspect`：返回 `{sessionHealthy, needsUserLogin}`
   - `jw.cas.fillUsername / fillPassword / submit`
   - `jw.identity.verifyExpected`：返回 `{authoritativeMatched, domMatched,
     storageMatched, ...Conflicted}`（布尔，不含账号原文）
   - `jw.course.readContext`：学期运行时 + option + dataId（minimal 可不强制，用默认 461）
   - `jw.course.fetchGetData`：GET get-data → `{text}`
   - `jw.course.fetchDatum`：POST datum（JSON）→ `{text}`
   - `jw.exam.readTable`：读 `table#exams` outerHTML → `{html}`
4. **方法到采集器的映射**：
   - `resolveCourseDataId` → `jw.course.readContext` 的 dataId（或 `extractDataId` 拦截器）
   - `fetchCourseDatum` → `jw.course.fetchGetData` + `jw.course.fetchDatum`
   - `fetchExamHtml` → 导航 exam-arrange + `jw.exam.readTable`
   - 错误映射：登录超时 → `JwLoginTimeoutException`(`login_timeout`)；账号不匹配 →
     `JwAccountMismatchException`(`account_mismatch`)；其余 → `JwCollectionException`
     (`collection_failed`)，保持 `JwCollector` 事件码不变。
5. **清理**：`close()` 释放 controller / surface，结束 `clearBrowsingDataAll`（可选）。

### Task 4：把原生 WebView 挂进 minimal 同步链路（替换 Python 通道）
保持 `SyncCoordinator` 不变，只替换 `bridgeFactory` 的实现：

- 新增 `lib/features/sync/native/native_jw_gateway.dart`，实现最小 `BridgeGateway`
  兼容面：
  - `capabilities()` → 固定 `BridgeSemesterCapability(461, '2026fall', '2026 秋季学期')`
  - `startCollection(...)` → 起 `JwCollector`（pageFactory = `JwWebViewAdapter`），
    返回固定 `jobId`
  - `poll(jobId, after)` → 轮询事件流，汇聚 `starting/collecting/needs_user_login/
    complete/failed/cancelled`，终态带 `result = bundle map`（与 Python Bridge poll.result
    同形）
  - `resumeLogin(jobId, {password})` → `JwCollector.resumeLogin`
  - `cancel(jobId)` → `JwCollector.cancel`
  - `shutdown()` → close 页面 + 可选清会话
- `SyncPageLoader` / `runStartupAutomaticSync` 改为注入 `NativeJwGateway`；
  用常量 `kUsePythonBridgeFallback = false` 保留回退口（可临时切回 Python）。
- 验证：`flutter analyze` 0 error；`flutter test` 全绿（含新增 native gateway 单测）；
  `flutter build windows --release` 编译通过。

### Task 5：文档与已知边界
- 在 `docs/m6-external-machine-handoff.md` 增补：WebView2 已接入 minimal 的说明与
  本机构建实测；"重启后免登录"不支持为已知边界。
- 记录真实人工验收待办（需校园网 + 真实账号，仍按 M6 口径外置）。

## 4. 明确不做（minimal 取舍）

| 全量做法 | minimal 取舍 |
|---|---|
| C1/C2/C3 分层 + `WebSessionEngine`/`NavigationAttempt`/`RegisteredScriptCatalog` | 用简化三信号收敛 + 注册脚本常量表 + 单控制器适配层 |
| C++ session_snapshot DPAPI（URF 会话跨冷启动） | 不做；重启需重新登录（日常可接受） |
| 动态学期目录发现 | 用默认 `461 / 2026fall / 2026 秋季学期`（本分支既定） |
| 多主机 HTTP→HTTPS 动态升级与相邻路径反例 | 用编译期白名单 + fail-closed |
| Android/iOS `webview_flutter` | 本机只做 Windows WebView2；移动端仍留 M5 stub（外部机器） |
| Python Bridge 删除/退役（未授权） | 保留 `bridge_client.dart` + python fallback 开关，不删除 |

## 5. 生成物清单

- [ ] `app/packages/webview_flutter_windows_secure/`（来自全量，自足，含 pubspec/CMake/windows/*）
- [ ] `app/lib/features/sync/native/jw_webview_adapter.dart`（真实实现，替换 stub 12 方法）
- [ ] `app/lib/features/sync/native/jw_web_session.dart`（白名单/脚本/身份核验/取数脚本与三信号收敛，裁剪自全量）
- [ ] `app/lib/features/sync/native/native_jw_gateway.dart`（BridgeGateway 兼容壳）
- [ ] `app/lib/features/sync/data/bridge_client.dart` 保留（python fallback 开关）
- [ ] `app/test/features/sync/native/jw_webview_adapter_test.dart`（fake WebView 状态机/错误映射/隐私）
- [ ] `docs/m6-external-machine-handoff.md` 增补 WebView2 接入说明与已知边界

## 6. 验证步骤（本机）

```bash
cd app
flutter pub get
flutter analyze                      # 0 error，issue 数不变（15）
flutter test                          # 1360 pass / 7 fail（不新增失败）
flutter build windows --release       # 编译通过
```

真实人工验收（需校园网 + 真实账号）：
- 登录 → 同步 → 课表/考试正确导入；对照安全聚合计数（不记录私人信息）。
- 取消/失败/重新登录的终态文案与存储保持一致。
- 重启后重新登录（已知边界，不阻塞日常使用）。

## 7. 参考

- 全量分支：`E:\107\.worktrees\rewrite\flutter-native`
  - `docs/refactor-docs/m2-native-jw-lessons.md`（问题与根因台账 / 有效诊断方法）
  - `docs/acceptance/m2-native-jw.md`（14 项正式清单，供参考）
  - `app/packages/webview_flutter_windows_secure/`（可自足提取的插件）
  - `app/lib/containers/platform/windows/webview2/webview2_controller_factory.dart`
    （白名单/生命周期参考）
  - `app/lib/containers/source_engine/browser/`（三信号收敛/重试参考）
  - `app/lib/containers/source_engine/jw/data/jw_registered_scripts.dart`（脚本裁剪源）
- minimal 分支既定：`docs/plan-webview-minimal.md`、`docs/plan-webview-minimal-mN.md`
