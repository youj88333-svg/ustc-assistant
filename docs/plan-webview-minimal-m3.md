# M3 详细实施计划：SourceCollectionGateway 接口 + WebView 采集器状态机（平台无关）

> 分支：`refactor/webview-minimal`（M2 已完成）
> 依据：`docs/plan-webview-minimal.md` §5（M3 目标）与 §3 里程碑表
> 目标（M3 门）：`SourceCollectionGateway` 接口冻结；平台无关 JW 采集器（会话/导航状态机/
> 事件顺序/可观测）以注入式 fake 完成单测通过；Python 通道兜底（Bridge 保留到 M7）。

## 0. 范围与非范围

**做**：
- 冻结 `SourceCollectionGateway` 接口（§5 已给签名）。
- 新增平台无关 JW 采集器：导航就绪状态机（authenticate→course→exam）、
  作业状态机（starting→collecting→normalizing→complete/failed/needs_user_login/cancelled）、
  事件顺序（与 Python collector 的 status 消息序列对齐）、可观测（事件流）。
- 采集器**不直接依赖 WebView/平台通道**：通过注入的 `JwWebPage` 抽象（导航/取内容/
  拦截 get-data 请求/填登录）完成；真实 WebView 适配器是 M5（跨平台适配）才接。
- 单测用 fake `JwWebPage`（脚本化导航/响应）跑全流程状态机，不触网、不构建二进制。
- M2 的 `jw_source_bundle_builder` 接入：采集器拿到 course_datum + exam_html 后调 builder 产 bundle。

**不做**：
- 真实 WebView/CAS 实现（M5 跨平台凭据/WebView 权限适配；本机无法构建二进制）。
- 删除 Python Bridge（M7）；Bridge 仍是当前运行通道，`PythonXxxGateway` 保留。
- 改 `sync_coordinator` 的主调用路径（M3 只新增接口 + 采集器 + 测试；sync_coordinator 何时
  切到 native gateway 是后续决定，M3 不改运行时行为）。
- 真实学校网站验收（本 VM 不访问外网；M6 在外部机器做）。

## 1. 接口冻结（§5 已定，逐字落地）

```dart
abstract interface class SourceCollectionGateway {
  Stream<SourceCollectionEvent> startJwCollection({
    required String accountId,
    required JwSemesterConfig semester,
  });
  Future<void> resumeLogin(String jobId, {String? password});
  Future<void> cancel(String jobId);
}
```

- `JwSemesterConfig`：复用现有（`config` 包，`semesterId/semesterKey/displayName`）。
  ⚠️ M2 builder 用的是 `semester_key` 等；采集器传 `JwSemesterConfig` 进来。
- `SourceCollectionEvent`：sealed class（见 §2.3），状态机各阶段 + 终态 + 结果。

## 2. 采集器状态机设计

### 2.1 导航就绪状态机（authenticate）
复刻 Python `_ensure_authenticated` 的就绪判定（不照抄 Playwright API，抽象成 `JwWebPage`）：

```
[init] --gotoRoot--> checkHome
checkHome --isHome--> [authenticated]（可复用 session）
checkHome --notHome--> gotoCasEntry
gotoCasEntry --isHome--> [authenticated]（CAS session 复用）
gotoCasEntry --notHome--> [needsUserLogin]（emit needs_user_login，暂停）
[needsUserLogin] --resumeLogin(password)--> fillLogin --waitForHome--> [authenticated] | [failed:login_timeout]
```

- `JwWebPage` 抽象（注入点）：
  - `Future<String> get currentUrl`
  - `Future<void> gotoRoot()` / `gotoCasEntry()` / `gotoCourseTable()` / `gotoExamArrange()`
  - `Future<bool> get isAuthenticatedHome`（判定 `currentUrl` 匹配 `/home`）
  - `Future<void> fillLogin(LoginCredentials)`（注入用户名/密码填表）
  - `Future<void> waitForAuthenticatedHome(Duration timeout)`（等导航到 /home）
  - `Future<CourseDataId> resolveCourseDataId(Duration timeout)`（拦截 get-data 请求，抽 dataId）
  - `Future<Map<String,dynamic>> fetchCourseDatum(int semesterId, String dataId, String referer)`
    （复刻 Python `fetch_course_datum`：先 GET get-data 拿 lessonIds，再 POST datum）
  - `Future<String> fetchExamHtml(Duration timeout)`（goto exam page，等 `table#exams`，取 outerHTML/content）
- fake `JwWebPage`：脚本化每个方法返回预设值/抛预设异常，供状态机单测。

### 2.2 作业状态机（collect）
```
[starting] --authenticate--> [checking_session / waiting_for_user_login]
[authenticated] --collectCourse--> [collecting] --collectExam--> [normalizing] --> [complete]
任一阶段 [failed:collection_failed / account_mismatch / login_timeout]
[needs_user_login] --cancel--> [cancelled]
```
- 事件顺序对齐 Python collector 的 status 消息：
  - "Reused the existing USTC JW browser session." / "Reused the existing USTC CAS session."
  - "Complete USTC CAS login in the Edge window; waiting for /home ..."
  - "Opening the course table and resolving the current data context ..."
  - "Collecting course data for configured semester {id} ..."
  - "Opening the published exam arrangement page ..."
  - normalizing → complete（emit bundle）

### 2.3 SourceCollectionEvent（sealed）
```
sealed class SourceCollectionEvent { final String jobId; final String phase; ... }
class CollectionStarting extends SourceCollectionEvent   // phase=starting
class CollectionStatus extends SourceCollectionEvent     // phase=collecting + status message
class CollectionNeedsUserLogin extends SourceCollectionEvent  // phase=needs_user_login
class CollectionComplete extends SourceCollectionEvent   // phase=complete + bundle(Map)
class CollectionFailed extends SourceCollectionEvent     // phase=failed + errorCode
class CollectionCancelled extends SourceCollectionEvent  // phase=cancelled
```
- bundle 以 `Map<String,dynamic>` 携带（M2 builder 产出），便于测试断言 + 后续 ImportService 消费。
- 事件含 `sequence`（单调递增，复刻 Python job events 的 sequence）。

### 2.4 采集器实现 `JwCollector`
- 持有 `JwWebPage`（注入）、`JwSemesterConfig`、`accountId`、`cancelToken`。
- `startJwCollection` 返回 `Stream<SourceCollectionEvent>`：跑状态机，emit 事件；遇 cancel/failed 终止。
- `resumeLogin`：对暂停在 needs_user_login 的作业，注入 password 续跑（用 `JwWebPage.fillLogin`）。
- `cancel`：设 cancelToken，状态机在下个 checkpoint 退出为 cancelled。
- 单活跃作业闸门（同 Python JobManager：同一 gateway 同时只一个 JW 作业在跑）。

## 3. 任务地图

| 操作 | 文件 |
|---|---|
| 新增 | `app/lib/features/sync/native/source_collection_gateway.dart`（接口 + SourceCollectionEvent sealed） |
| 新增 | `app/lib/features/sync/native/jw_web_page.dart`（JwWebPage 抽象 + LoginCredentials 小类） |
| 新增 | `app/lib/features/sync/native/jw_collector.dart`（JwCollector 状态机 + 事件流） |
| 新增 | `app/test/features/sync/native/jw_collector_test.dart`（fake JwWebPage 跑全流程：复用 session/CAS 复用/needs-login+resume/login-timeout/course-fetch-fail/exam-missing/cancel/complete→bundle 等价 M2 oracle） |
| 不改 | sync_coordinator / bridge_client / ImportService（M3 不改运行时） |

## 4. 关键约束

- **事件顺序**：状态机 emit 的 phase/status 序列必须可复刻 Python collector（便于 M6 真实验收时对比）。
- **bundle 等价**：complete 事件携带的 bundle 必须与 M2 `jw_source_bundle_builder` 产出一致
  （采集器内部调 builder；测试用 fake JwWebPage 提供 fixture 数据，断言 bundle digest == M2 oracle）。
- **dataId 拦截**：复刻 `extract_data_id`（get-data URL 的 `dataId` query 参数）；fake 模拟该请求。
- **fetch_course_datum 两步**：GET get-data（拿 lessonIds）→ POST datum（拿 course_datum）；fake 模拟两步。
- **exam content**：Python 用 `page.content()`（整页 HTML）；JwWebPage 抽象 `fetchExamHtml` 返回 HTML 字符串
  （M2 exam parser 直接吃）。fake 返回 `exam-page.html` fixture。
- **account mismatch**：复刻 `verify_ustc_account`（登录后校验用户名匹配）；fake 可注入不匹配触发 failed。
- **取消检查点**：状态机在每个 goto/fetch 前检查 cancelToken（复刻 `raise_if_cancelled`）。
- **平台无关**：`jw_collector.dart` 不 import `dart:io`/`webview_flutter`/平台插件；只依赖 `JwWebPage` 抽象 + M2 builder + 标准库。

## 5. 测试场景（fake JwWebPage）

1. **reuse-session**：gotoRoot 已是 /home → 直接 collect → complete，bundle digest==oracle。
2. **cas-reuse**：gotoRoot 非 home → gotoCasEntry 已是 /home → collect → complete。
3. **needs-login-then-resume**：非 home → CAS 非 home → emit needs_user_login → resumeLogin(password) → fillLogin → waitForHome → collect → complete。
4. **login-timeout**：needs-login → resume → waitForHome 超时 → failed(login_timeout)。
5. **account-mismatch**：登录后 verify 用户名不符 → failed(account_mismatch)。
6. **course-fetch-fail**：fetchCourseDatum 返回缺 lessonIds → failed(collection_failed)。
7. **exam-missing**：fetchExamHtml 超时/无 table#exams → failed(collection_failed)。
8. **cancel-during-collect**：collect 中 cancel → cancelled。
9. **single-active-job**：并发 startJwCollection 第二个被拒（bridge_busy 等价）。
10. **bundle-parity**：complete 事件的 bundle canonical digest == M2 oracle digest `f858a385...`。

## 6. 已关闭决策

- **D-M3-1（平台无关优先）**：M3 只交付接口 + 状态机 + fake 测试；真实 WebView 适配器是 M5。
- **D-M3-2（不改运行时）**：sync_coordinator 仍走 Python Bridge；native gateway 是新增并行能力，不替换。
- **D-M3-3（bundle 经 builder）**：采集器拿 raw course_datum + exam_html，调 M2 builder 产 bundle，不重复规范化逻辑。
- **D-M3-4（JwWebPage 抽象而非具体 WebView）**：注入点解耦平台，M5 提供各平台 WebView 实现。
- **D-M3-5（事件 sequence 单调）**：复刻 Python job events 的 sequence，便于 poll 语义与 Bridge 一致。

## 7. 风险

- **R-M3-1（状态机并发/取消竞态）**：cancel 与正常推进并发。用 `cancelToken`（bool）+ checkpoint 检查；resumeLogin 用 Completer 同步。
- **R-M3-2（事件流背压）**：Stream 用同步 emit + 单订阅；fake 测试用 `toList()` 收集。
