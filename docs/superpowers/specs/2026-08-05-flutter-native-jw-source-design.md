# Flutter 原生教务来源设计

## 1. 目标

本设计是“正式 App 彻底移除 Python 运行时”迁移工作的第一个子项目。它只负责在
Windows 上打通以下生产闭环：

```text
Flutter App
  -> App 内 Windows WebView2
  -> USTC CAS 登录
  -> 动态学期目录与用户单选
  -> 教务课程和考试采集
  -> 纯 Dart 解析与 SourceBundle 1.0 生成
  -> 现有 ImportService
  -> Drift/SQLite
```

完成后，正式 JW 同步不得启动 Python Bridge。Python JW 实现暂时保留，只作为迁移期
回归基准；二课、iCourse 和校园公开信息仍可继续使用现有 Bridge，直到各自完成后续
迁移。

本设计不修改 SourceBundle 1.0、ImportService、日程领域模型、UserOverlay、Agent
业务工具或学校外部写操作边界。

## 2. 全量迁移分解

彻底移除 Python 分为四个独立子项目：

1. 原生来源基础设施和教务课程/考试链路，即本设计。
2. 二课报名中活动和已报名日程链路。
3. iCourse、校园目录与详情等公开查询链路，以及 Agent 查询网关切换。
4. 删除 Python Bridge、Python 来源实现、CLI 和运行时依赖，并完成全量回归。

不得在本子项目中提前删除仍被其他来源使用的 Bridge 或 Python 代码。

首版只要求 Windows 实际运行。共享解析器、契约和应用服务必须保持纯 Dart；Android
WebView 与 iOS WKWebView 本轮只保留可替换接口，不要求实现或验收。

## 3. 已确认的产品决策

1. 学期内部 ID 不再硬编码，也不根据年份推算。
2. 教务课表页提供的动态 `semesters` 数据是学期目录权威来源。
3. 同步学期由用户按学校账号手动单选；页面默认选中项和当前日期都不能代替用户选择。
4. 选择持久化；12 小时自动同步沿用该选择。切换学期不删除旧学期历史数据。
5. 登录使用 App 内受控 WebView，不再打开外部专用 Edge。
6. CAS 页面可以自动填写账号密码并自动点击登录。
7. 短信验证码始终由用户在 WebView 中手动输入，不申请短信读取权限。
8. 后台自动同步发现登录失效时只进入 `needs_login`，不得强制弹出 WebView 打断首屏。
9. Cookie 留在 WebView 会话存储内，不导出给 Dart HTTP。
10. 原生采集采用 WebView 同源受控请求；不依赖跨平台网络拦截。

## 4. 架构

### 4.1 组件

```text
SyncCoordinator
  -> JwSourceGateway
       -> AuthenticatedWebSession
            -> WindowsWebViewSession
       -> JwSemesterCatalogService
       -> JwCollector
       -> JwParser
       -> JwSourceBundleBuilder
  -> ImportService
```

`AuthenticatedWebSession` 是平台边界，负责：

- 导航到白名单页面；
- 检查登录状态；
- 展示或隐藏登录 WebView；
- 执行应用内置、版本化的受控 JavaScript；
- 返回有界的 JSON、文本或必要 HTML；
- 处理取消、超时和账号会话清理。

该接口不得暴露通用“执行任意脚本”或“访问任意 URL”能力。调用方只能选择应用注册的
操作，例如读取教务页面上下文、执行课程请求或读取考试表。

`WindowsWebViewSession` 是首版 WebView2 实现。后续 Android/iOS 适配器必须复用相同
语义，不能把平台 Cookie、任意脚本或页面对象泄漏给共享层。

`JwSemesterCatalogService` 从已认证课程页读取并验证学期目录。`JwCollector` 只处理
固定教务端点和内存中的原始响应。`JwParser` 与 `JwSourceBundleBuilder` 是纯 Dart，
不依赖 Flutter、WebView、Windows 或数据库。

### 4.2 生产组合切换

迁移期间允许同时存在：

- `NativeJwSourceGateway`：新的正式 JW 采集实现；
- Python JW service：开发和对照测试基准；
- Python Bridge：继续服务尚未迁移的二课和公开查询来源。

JW 验收通过后，`SyncCoordinator` 对 `SyncSource.jw` 必须只组合
`NativeJwSourceGateway`。不得在失败时静默回退 Python，否则无法证明正式 App 已摆脱
JW Python 运行时。

## 5. WebView 登录会话

### 5.1 账号隔离

每个本地学校账号使用独立 WebView 数据目录。一个账号的 Cookie、本地存储和缓存不得被
另一个账号复用。清除登录会话只删除当前账号的 WebView 会话；删除凭据和清除会话仍是
两个独立操作。

账号密码继续通过现有操作系统安全凭据能力保护。普通 SQLite 不保存明文密码，日志、
异常、同步状态和测试输出不得包含密码。

### 5.2 登录流程

```text
checking_session
  -> authenticated
  -> needs_login
       -> interactive_login
       -> needs_sms_verification
       -> authenticated
```

后台同步先在不展示 WebView 的情况下检查现有登录态。登录失效时进入 `needs_login` 并
等待用户操作，不自动弹窗。

用户打开登录入口后，应用只在预定义 CAS HTTPS Host 和已识别表单上：

1. 解密当前账号凭据；
2. 填写用户名和密码；
3. 自动点击登录；
4. 每次页面实例最多自动提交一次，防止错误凭据或页面循环造成重复提交。

若出现短信验证码页面，应用停止自动提交并保持 WebView 可见。用户手动输入和提交后，
应用检测认证完成并自动继续同步。首版不读取短信或系统通知。

登录成功后必须验证学校账号与当前 App 账号一致。无法验证或不一致时返回
`account_mismatch`，不得继续采集或更新保存的凭据。

### 5.3 JavaScript 安全边界

所有脚本均为代码仓库内置、版本化、单一用途的常量，并且只能在白名单页面执行。

- 网页文本、模型参数、用户输入和任意 URL 不得拼接为 JavaScript。
- WebView 返回值必须先经过类型、大小、数量和结构校验。
- 页面正文、脚本内容和响应均视为不可信输入。
- 不提供给 Agent 或其他功能通用 WebView 执行接口。

## 6. 动态学期目录

### 6.1 来源

已认证课表页同时提供：

- 页面运行时 `semesters` 数组，包含 ID、代码、学年、日期、季节和名称；
- `select#allSemesters` 的选项和页面默认选中项；
- 页面运行时 `dataId`。

`semesters` 数组是目录权威来源，`#allSemesters` 用于交叉校验显示选项。页面默认选中项
只用于诊断，不得自动成为 App 同步学期。

### 6.2 模型

每个目录项至少包含：

```text
semesterId       来源正整数 id
sourceCode       来源 code
semesterKey      规范化产品键
displayName      中文显示名
schoolYear       来源学年
season           spring | summer | fall
startDate        北京自然日
endDate          北京自然日，包含端点
enabled          来源启用状态
```

`semesterKey` 由来源的 `currentYear` 和 `season` 字段规范化：

```text
SPRING -> <currentYear>spring
SUMMER -> <currentYear>summer
AUTUMN -> <currentYear>fall
```

该规则只生成产品稳定键，不推算教务内部 `semesterId`。未知 season、重复 ID、重复产品键、
非法日期或缺少必要字段均使目录读取明确失败。

### 6.3 用户选择

同步学期按本地学校账号写入 `SourceConfigs(source=ustc_jw).configJson`，保存版本化的完整
选择快照，而不是只保存显示文本。首版配置版本为 `1`，至少保存 6.2 节中的全部字段。
这不需要新增数据库表或全局默认配置。首次同步没有选择时进入
`semester_selection_required`。用户选择后才允许继续课程请求。

每次同步重新加载目录：

- 已选 ID 存在且关键字段一致：继续使用；
- 已选 ID 不存在或同 ID 的产品键/季节发生冲突：进入 `semester_catalog_changed`，要求
  用户重新选择；
- 不得回退到 `461`、页面选中项或按当前日期猜测。

切换选择只改变后续采集 scope。此前导入的其他学期数据继续保留，并由现有
SourceRecord/ImportService 规则维护。

`dataId` 是当前认证上下文，只能在单次采集内存中使用，不持久化、不显示、不写日志。

## 7. 教务采集流程

### 7.1 固定入口

只允许以下 HTTPS Host 和固定路径族：

```text
https://jw.ustc.edu.cn/for-std/course-table
https://jw.ustc.edu.cn/for-std/course-table/get-data
https://jw.ustc.edu.cn/for-std/course-table/datum
https://jw.ustc.edu.cn/for-std/exam-arrange
```

入口允许跟随学校自身认证和带动态个人上下文的重定向，但最终 Host 必须仍在白名单内。
动态个人上下文 ID 不得持久化或进入 SourceBundle。

### 7.2 课程

1. 导航课程固定入口并等待已认证页面稳定。
2. 读取和验证 `dataId`、学期目录及用户选择。
3. 在页面同源上下文执行固定 GET：

```text
/for-std/course-table/get-data
  bizTypeId=2
  semesterId=<用户选择的来源 ID>
  dataId=<当前页面上下文>
```

4. 校验响应结构和完整性。
5. 按教务页面自身逻辑，优先将 `publishLessonIds` 作为 POST `/datum` 请求体中的
   `lessonIds`。迁移对照若证明现有 Python 使用的 `lessonIds` 与之存在有效业务差异，
   必须先分类并由项目所有者确认，不能静默丢课或合并两者。
6. 解析 `lessonList`、`scheduleList` 和 `scheduleGroupList`。

当目标学期课程列表为空时，这是合法完整快照。此时不调用无意义的 `/datum`，并继续采集
考试；不得沿用 Python 旧行为将空列表直接判为失败。

### 7.3 考试

导航考试固定入口，跟随已认证重定向后读取 `table#exams`。解析器只接受契约中的八列表头，
首列兼容“课程号”和“课堂号”。尚未发布考试时，结构正确的空表是合法结果。

课程成功而考试页面结构异常，或考试成功而课程快照不完整，都不能生成部分 JW Bundle。

### 7.4 有界输入

采集层必须限制：

- 页面和响应体字节数；
- 学期、lesson、schedule、教师和考试行数量；
- 字符串长度和 JSON 嵌套深度；
- 页面导航、脚本、请求和整项同步超时；
- 同一账号同时只运行一个 JW 同步。

固定上限如下，且不允许由网页响应或远端脚本覆盖：

```text
课程页上下文结果             4 MiB
get-data JSON                8 MiB
datum JSON                  16 MiB
考试页必要 HTML              4 MiB
学期目录                       256 项
单次 lesson ID              20,000 项
原始 schedule/group 行      50,000 项
单事件参与者                    50 项
单次导航或网络请求               30 秒
单次受控脚本                      10 秒
交互登录                        5 分钟
登录完成后的整项采集              5 分钟
```

SourceBundle 输出继续受正式契约中的 16 MiB、20,000 CalendarEvent、5,000
CourseSeries、20,000 ScheduleRelation 以及字段长度限制约束。任一阶段超过上限时整项失败，
不得截断后冒充完整结果。

## 8. 纯 Dart 解析与 SourceBundle

Dart 端移植现有 Python JW 行为，包括：

- 多教师合并；
- 不同周次教师变化；
- 单双周和离散周次；
- 同课程多地点、习题课分组和身份碰撞后缀；
- 课程系列与 occurrence 稳定外部身份；
- 课程、考试及其来源记录；
- 北京时间 RFC 3339 输出；
- 考试默认 `critical + must_go`；
- 课程默认出勤未知；
- 原始个人上下文、远端用户 ID 和未知字段剔除。

输出必须继续符合 `docs/data-sources/source-bundle-v1.md` 和
`schemas/source-bundle-1.0.schema.json`。Flutter 不新增 legacy 兼容入口，也不绕过现有
SourceBundle decoder、语义校验或 ImportService 事务。

原始 `datum`、考试 HTML 和完整页面默认不落盘。开发调试如确需保留，必须沿用私有目录、
显式开关和 Git 排除规则，且不属于正式 App 功能。

## 9. 同步状态与错误

原生 JW 同步状态至少包括：

```text
idle
checking_session
needs_login
needs_sms_verification
loading_semesters
semester_selection_required
collecting
normalizing
importing
completed
failed
cancelled
```

稳定安全错误码至少包括：

```text
needs_login
needs_sms_verification
semester_selection_required
semester_catalog_changed
account_mismatch
page_contract_changed
request_failed
response_too_large
incomplete_snapshot
import_failed
cancelled
```

未知异常统一映射为安全错误，不回显 URL 查询参数、DOM、响应、路径、账号或原始异常。

取消同步必须终止导航和受控请求，丢弃内存结果，不调用 ImportService。任何采集或导入失败
都保留上一次成功数据，不将旧数据标记为本次完整快照。

12 小时自动同步和手动同步复用同一状态机、互斥和错误语义。登录失效的后台同步停在
`needs_login`；用户主动完成登录后可继续原作业或重新开始一个等价作业，但不得产生两个
并发导入。

## 10. 测试

### 10.1 纯 Dart 单元测试

复用和整理现有脱敏 JW fixture，覆盖：

- 典型课表、多教师、分周教师、单双周、叠课、多地点和习题课；
- 空课表、空考试、未知表头、重复身份、非法时间和悬空引用；
- 学期目录正常结构，以及字段缺失、重复 ID、重复产品键、未知 season 和非法日期；
- SourceBundle Schema、语义、计数、稳定身份和隐私字段拒绝。

### 10.2 会话与采集测试

使用假的 `AuthenticatedWebSession` 验证：

- 固定导航顺序和 Host 白名单；
- 自动登录每个页面实例最多提交一次；
- 短信验证码暂停与恢复；
- 后台失效不弹窗；
- 账号不一致、取消、超时、响应过大和页面结构变化；
- 空课程时跳过 `/datum` 但仍完成考试采集；
- 任一组件不完整时不调用 ImportService。

自动测试不得访问学校网站，不包含真实账号、Cookie、`dataId` 或原始个人页面。

### 10.3 Python 对照

Python 和 Dart 对同一批脱敏输入 fixture 生成规范化结果。比较时只忽略 `bundleId`、
`collectedAt` 等采集时刻字段，其余业务字段必须一致。真实验收时，对同一账号和同一用户
选择学期分别运行 Dart 与 Python，并比较脱敏 SourceBundle。

对照差异必须分类为：

- Dart 移植缺陷；
- Python 既有缺陷；
- 页面契约新变化；
- 经所有者批准的预期行为改进，例如合法空课程快照。

不得只为通过对照而复制已确认的旧错误。

### 10.4 Windows 人工验收

人工清单必须覆盖：

1. 首次 CAS 登录、自动填写与点击、短信验证码；
2. 会话复用、会话过期、账号不一致与清除会话；
3. 动态学期目录、首次必选、切换学期和选择持久化；
4. 12 小时自动同步失效时不强制弹窗；
5. 有课、空课、考试已发布和考试未发布；
6. 取消、网络中断、页面结构变化和重新登录；
7. 导入后的课程、考试、周视图、历史和 UserOverlay 保留；
8. 正式 JW 路径不启动 Python 进程。

## 11. 切换门槛

只有同时满足以下条件，才能把 JW 正式组合切到 Dart：

1. JW 聚焦测试、Flutter 全量测试和静态分析通过；
2. Windows Release 构建通过；
3. 至少一次真实 Dart JW 同步成功；
4. 至少一次同账号、同学期 Python 对照完成且差异已处理；
5. 空课程和空考试均有完整快照验证；
6. 账号隔离、取消、登录失效和学期选择人工验收通过；
7. 生产 JW 同步不包含 Python 回退路径。

切换后保留 Python JW 实现和测试基准，直到二课、公开查询以及 Agent 查询网关均迁移完成。
全量移除 Python 必须另立最终清理 Spec 和计划，不能在本里程碑顺手删除。

## 12. 非目标

本轮不实现：

- Android WebView 或 iOS WKWebView 生产适配器；
- 二课、iCourse、校园目录/详情的 Dart 迁移；
- 自动读取短信验证码；
- 任意网页浏览、任意 JavaScript 或任意 URL 抓取；
- 二课自动报名或取消报名；
- SourceBundle 2.0 或数据库领域模型重构；
- 删除 Python Bridge、CLI 或 Python 来源代码；
- 修改 LLM 工具权限和本地业务写工具。
