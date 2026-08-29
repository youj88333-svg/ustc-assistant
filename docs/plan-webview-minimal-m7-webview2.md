# 计划：按全量重构分支经验重写 minimal 原生 WebView（Windows WebView2）

> 分支：`refactor/webview-minimal`（M6 交接物已落档；M7 实现与 Task 9 验证记录在
> 本文件末尾收敛）
> 依据：`E:\107\.worktrees\rewrite\flutter-native` 的全量 `M2 Native JW` 真实踩坑复盘
> （`docs/refactor-docs/m2-native-jw-lessons.md`）与 `docs/acceptance/m2-native-jw.md`。
> 目标（本计划门）：minimal 教务采集从 Python Bridge 切换为 Flutter 原生 WebView2，
> 日常可基本正常使用；不追求全量分支的企业级 C1/C2/C3 分层。

## 0. 背景与动因

- 全量重构分支的 M2 已把 WebView2 采集链路打通，并在多轮真实 debug 构建与人工验收中
  修复了导航、CAS、身份核验、学期、请求载荷、取消、会话等一批问题（见
  `rewrite/flutter-native/docs/refactor-docs/m2-native-jw-lessons.md` 的"问题与根因台账"）。
- 本计划开始时 minimal 分支仍是 stub；Task 1–8 已将它收敛为可测试的 Windows
  WebView2 通道：`JwWebViewAdapter`、稳定 surface host、原生 gateway、严格脚本
  合约和 Debug loopback fixture 均已落地。Python Bridge 仍保留为显式 fallback。
- 因此本计划把全量分支"踩过的坑"直接落到 minimal 的 `JwWebPage` 实现点上，
  用最小代价替换 Python 运行通道。

### 0.1 本机的已验证事实（2026-08-26）

| 项 | 值 |
|---|---|
| Flutter | 3.44.5 / Dart 3.12.2（`/e/flutter/flutter`） |
| VS 2022 | `/e/Microsoft Visual Studio/18/community`（VC v143 / MSVC 14.42，`cl.exe` 就绪） |
| CMake / Ninja | `/e/Android/Sdk/cmake/3.22.1`、`/e/Espressif/tools/cmake/3.30.2`（本机可编译 Windows） |
| 代理 | 127.0.0.1:7897（pub.dev / github 可达，`flutter pub get` 可用） |
| 历史 M5 基线快照 | `flutter analyze` 0 error / 15 issues；`flutter test` 1360 pass / 7 fail（M0 起已知基线；非当前 M7 结果） |

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
  - 历史 M5 快照：`flutter analyze` → 0 error / 15 issues
  - 历史 M5 快照：`flutter test` → 1360 pass / 7 fail（已知基线；当前 M7 结果见 §8.5）
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
- 验证：以 §8.5 Task 9 的当前串行 gate 记录为准；`analyze` 与全量 `test` 必须
  真实退出 0 后才启动 `flutter build windows --release`，任何非零都按停止规则原样
  记录。历史基线或 Debug loopback 不得替代 Release gate 结果。

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
- `SyncPageLoader` 在可见同步页中注入 `NativeJwGateway`；`/chat` 没有可挂载的
  WebView surface，因此 native 模式的 `runStartupAutomaticSync` 不启动 headless
  采集。用常量 `kUsePythonBridgeFallback = false` 保留回退口（切为 true 时 Python
  Bridge 仍可执行 headless 启动同步）。
- 验证：以 §8.5 Task 9 的当前串行 gate 记录为准；`analyze` 与全量 `test` 必须
  真实退出 0 后才启动 `flutter build windows --release`，任何非零都按停止规则原样
  记录。历史基线或 Debug loopback 不得替代 Release gate 结果。

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
flutter analyze                      # 历史 M5/M6 快照：0 error，issue 数 15；当前 M7 见 §8.5
flutter test                          # 历史 M5 快照：1360 pass / 7 fail；当前 M7 结果见 §8.5
flutter build windows --release       # 仅在前两步 exit 0 后执行；当前结果见 §8.5
```

真实人工验收（需校园网 + 真实账号）：
- 登录 → 同步 → 课表/考试正确导入；对照安全聚合计数（不记录私人信息）。
- 取消/失败/重新登录的终态文案与存储保持一致。
- 重启后重新登录（已知边界，不阻塞日常使用）。

## 8. M7 实现与 Task 9 验证收敛

### 8.1 运行时生命周期与账号边界

minimal 的 native 路径采用单一稳定 surface：`SyncPage` 永久挂载
`JwWebViewSurfaceHost`，作业忙闲只切换 `Offstage`，不把原始 WebView widget 在
不同子树之间搬运。`NativeJwGateway` 在 controller 初始化、event stream readiness
和策略配置完成后 attach；gateway 独占 controller/account/UDF 所有权。释放严格为：

```text
reject new work → cancel non-terminal jobs → await terminal settlement
→ detach and await placeholder unmount → stop
→ clear browsing data → dispose → await environment release
→ close subscriptions and diagnostics
```

每个作业只使用一个不透明 `accountId` 绑定的 UDF 子目录，路径由应用支持目录和
清理后的 account 分区组成，不写入日志。minimal 不实现跨冷启动 session snapshot
或 DPAPI 会话恢复；重启后再次同步可能要求重新登录。一个 gateway 不并行维护多个
账号 controller，Python 与 native 也不对同一来源并发。

### 8.2 Native startup 边界（重要取舍）

`/chat` 启动路由没有已挂载的 WebView surface。为了避免创建不可见、无法完成交互
和无法安全 teardown 的 WebView2，`runStartupAutomaticSync` 在 native 默认路径
直接返回；原生采集由用户进入同步页后触发，页面提供可见 surface 供 CAS/CAPTCHA/MFA
等流程使用。`kUsePythonBridgeFallback=true` 时，Python Bridge 仍可按原有 headless
语义执行启动自动同步。该行为是稳定生命周期边界，不是遗漏的后台刷新功能。

### 8.3 严格协议与数据导入

portal、CAS、home、course、exam 每个目标都需要 URL + DOM selector + 注册
credential-free handshake 在同一个 attempt generation 内成功。URL wildcard 按
路径边界匹配，拒绝 sibling path；旧 generation 的 late signal 不得完成新尝试。
登录只做一次受控 portal activation 和一次 CAS submit；home 收敛后必须有权威身份
匹配 expected username，缺失权威证据或出现冲突均 fail-closed。

课程/考试路径严格保持 SourceBundle 1.0 需要的请求契约：使用配置的
`461 / 2026fall / 2026 秋季学期`，不推算 semester ID；同源 get-data 的参数、
JSON datum 的 headers/body、lesson ID 正性/唯一性/数量边界和唯一 `table#exams`
均在 adapter 边界验证。任一认证、页面、请求、解析或 bundle 构造失败都终止整个
snapshot，不导入部分结果。

gateway poll 为事件驱动并带有界 long-poll；collector 在每个主要阶段和 bundle 完成
前检查取消，取消终态优先于迟到结果，协调器不会用固定 250ms 延迟掩盖空轮询。已有
`ImportService` 继续作为唯一 SourceBundle 1.0 导入入口，账号分区和
`Asia/Shanghai` 语义不变。

### 8.4 自动化 loopback 与真实校园验收边界

`integration_test/minimal_jw_webview_loopback_test.dart` 使用本机 IPv4 loopback fixture
和 production controller，覆盖 login/CAS/home/course/exam、get-data/datum 请求形状、
SourceBundle 构造、native texture surface teardown 以及 WebView2 environment-release
barrier。fixture 只保留方法、无 query 的路径、content type、XHR 标志和 JSON key shape；
不保存真实账号、Cookie、DOM、响应体或 data ID。UDF 只在 canonical workspace root
下创建唯一子目录，在 environment release 后删除并检查为空。

该 gate、fake-controller tests、Flutter analyze/test/build 和 Python oracle/compileall
都是自动化证据；它们不访问学校主机，不使用真实账号，不等同真实校园验收。owner-run
的脱敏人工 stage chain 必须单独确认：

```text
login entry → CAS → identity verified → course context → get-data
→ datum → exam table → bundle built → imported → schedule visible
```

真实验收时只记录各 stage 的成功/失败和稳定错误码；不得记录 query、ticket、Cookie、
用户名、DOM、data ID、响应体或私人课程数据。

### 8.5 Task 9 命令与结果记录

执行顺序固定为：

1. 确认没有 `flutter`/`dart`/`ustc_assistant_app` 进程。
2. 在 `app/` 运行一次 fresh Windows loopback：
   `flutter test --no-pub --reporter expanded integration_test/minimal_jw_webview_loopback_test.dart -d windows`。
3. 在同一 PowerShell 终端依次执行 `flutter analyze --no-pub`、
   `flutter test --no-pub --reporter expanded`、`flutter build windows --release --no-pub`；
   前一步失败立即停止，不能由后一步覆盖。
4. 回到 worktree root 在 `ustc_assistant` 环境运行 Python unittest discover 和
   compileall；禁止安装或改变 Conda 环境。

Task 9 的 fresh 运行结果（2026-08-29）如下，且只代表本机自动化证据：

- 进程预检和清理后均没有 `flutter`/`dart`/`ustc_assistant_app` 残留。首次无输出
  的原因已定位为 sandbox 无权写 Flutter SDK 的 `cache/flutter.bat.lock`，不是另一个
  Flutter 任务占锁。
- loopback：修正执行权限后只运行一次 fresh 命令；`-d windows` 使用 Debug runner，
  退出 0，`00:03 +1: All tests passed!`，Debug 构建约 23.4s；无设备断开，canonical UDF
  `UDF_CHILD_COUNT=0`。受限 shell 无法查询 Application Event Log，故不宣称 Error
  1000 计数。Task 8 的既有 loopback 记录仍保留，但不替代本项。
- sqlite hook：移除 `source: system` override 后执行一次 `flutter pub get`，exit 0；
  官方 hook 生成 bundled native asset。随后 `schedule_task_schema_test.dart` 串行
  14/14 通过，确认 sqlite 初始化与 Drift schema 可达；`native_jw_gateway_test.dart`
  串行 13/13 通过。
- Flutter analyze/test/build：同一 PowerShell 终端按规定顺序启动；Task 9 fix4 后
  analyze 通过（`No issues found!`，`ANALYZE_EXIT=0`，gate 计时 7.6s）。expanded
  全量 test 通过，末计数为 `1441 passed / 0 failed`、exit 0；随后 Release build
  通过，CMake `INSTALL` 目标完成、exit 0。Release 产物
  `build/windows/x64/runner/Release/ustc_assistant_app.exe` 存在（92,160 bytes，
  SHA-256 `01270100CCFEE86E5BA1B3C1D3C9CBA7690CC4BC2D81E661379F9895D5C4B211`）；
  同轮 `data/app.so` 与 WebView2 插件文件已更新。此前 `1440/1` 的 fixture failure
  是 pre-fix evidence，曾按严格停止规则阻塞 Release gate；`467e090` 只修测试
  fixture，未放宽生产 migration。全程未出现 sqlite3.dll error 126，也未启动第二套
  Flutter gate。
- sqlite diagnosis 的 error-126 记录是配置修复前证据，详见
  `.superpowers/sdd/2026-08-28-minimal-jw-webview-reachability/task-9-sqlite-diagnosis.md`；
  本轮当前汇总见忽略的
  `.superpowers/sdd/2026-08-28-minimal-jw-webview-reachability/task-9-report.md`。
- Python：临时进程级 `PYTHONPATH` 明确指向本 worktree 的 `src`，导入断言通过；
  unittest `Ran 140 tests in 1.666s`、`OK`，compileall 退出 0。未安装或修改
  Conda 依赖。

若之后的 owner 环境触发已知宿主 `sqlite3.dll` error 126，必须保留原始失败计数并
停止 build，不能复制 DLL 或重跑第二套 Flutter 命令掩盖失败。

### 8.6 Owner-run real-campus checklist

- [ ] 校园网/iWAN 可达且用户在 App 中自行输入凭据。
- [ ] login entry → CAS → identity verified；不记录账号、ticket、Cookie 或 DOM。
- [ ] course context → get-data → datum；确认 configured semester 仍为 461/2026fall，
      只记录聚合课程/考试计数。
- [ ] exam table → bundle built → imported → schedule visible；确认导入后本地课表
      与教务页面一致，但不保存或回传私人课表。
- [ ] 取消、失败、重新登录和冷启动后的 needs_user_login 文案/状态符合预期。

自动化 loopback 证据与该 checklist 分开归档。未获得 owner 明确确认前，M7 真实校园
验收保持未完成。

### 8.7 Deferred/environment notes

- minimal 不实现 Android/iOS 真实 WebView；移动端接线/构建仍按 M6 外部机器手册执行。
- 本机若无法加载 `sqlite3.dll`（FFI error 126），这是验证宿主环境差异；不安装、
  复制或下载动态库，不将其报告为代码通过。
- 历史 M5 migration fixture 与 golden 字体差异按 M6 §6 记录；migration fixture
  已在 Task 9 fix4（`467e090`）补齐，当前 Windows gate 结果见 §8.5。Task 8
  loopback/fake WebView 证据仍不替代 Release gate 或真实校园验收。

## 9. 参考

- 全量分支：`E:\107\.worktrees\rewrite\flutter-native`
  - `docs/refactor-docs/m2-native-jw-lessons.md`（问题与根因台账 / 有效诊断方法）
  - `docs/acceptance/m2-native-jw.md`（14 项正式清单，供参考）
  - `app/packages/webview_flutter_windows_secure/`（可自足提取的插件）
  - `app/lib/containers/platform/windows/webview2/webview2_controller_factory.dart`
    （白名单/生命周期参考）
  - `app/lib/containers/source_engine/browser/`（三信号收敛/重试参考）
  - `app/lib/containers/source_engine/jw/data/jw_registered_scripts.dart`（脚本裁剪源）
- minimal 分支既定：`docs/plan-webview-minimal.md`、`docs/plan-webview-minimal-mN.md`
