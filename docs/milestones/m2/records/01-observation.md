# M2.1–M2.2 二课观测记录

> 保留发生时的规格、失败、修复和检查；旧“待验/未关闭”不是当前状态。当前范围见 [任务单](../plan.md)，最终结论见 [验收](../acceptance.md)。正文只迁移链接，保留当时叙述。

### M2 二课来源任务单（2026-10-11）

用户要求“请按设计文档和指定工作流开始 M2，先明确本阶段的范围和验收条件，再推进实现”。07–15 现行区此前没有新分支 M2 定义；Sol / max 依已批准五来源范围和来源依赖，将 M2 排为 **Young 已报名日程同步 + Young 报名活动只读查询**。两个入口共用必要的二课浏览器基础，分别维护来源契约和验收结论；报名查询不自动进入同步或日程导入。该排期不沿用旧资料的 JW=M2、Young=M3 编号。

- **设计依据**：从 `docs/README.md` 导航，采用 07 产品范围、安全与工作约束、DR-ADR-01/02/03/04/05/09，08 系统依赖、来源注册/仲裁及会话边界，09 K-01–06，10 首登/恢复/来源作业与维护，11 来源就绪和日程投影，12 身份/分区/凭据/结果的职责归属，13 V-01/02/03/05 的分段验证，以及本文件工作流与 M1 关闭记录。01–06 及历史正文仅参考，不复制其实现、测试、fixtures 或旧 Schema。
- **阶段交付范围**：确认二课真实认证与业务身份；已报名日程按实证范围取得完整只读快照，规范化、封存并事务导入，提供本地展示/隐藏恢复；报名活动列表与必要详情作为独立只读查询交付，覆盖范围、分页和有效空结果明确，不发起报名、退出、签到、学分申报或其它学校业务写。浏览器与现有 JW 隔离，所有操作与 JW/M0 共用全局租约。必要的数据与许可模型依据真实契约增量定义，保留既有教务账号、密文、目录、日程及验收。
- **边界**：M2 不包含评课、校园信息、Agent/模型网关、完整 Task/提醒、移动端或发布；真实非空 JW 考试继续按已批准后补登记。普通 WebView 沿用有限控制，不恢复 CAL/全协议隔离门槛。首切片由用户手动在学校窗口认证，不使用或读取 JW 已保存密码或浏览器认证资产；二课自动认证仅在其固定文档契约与应用内明确的凭据用途授权成立后装配。
- **未知项**：二课可能先经过站点访问认证，再进入业务认证；当前服务器业务身份字段及其会话/文档关联，已报名日程和报名列表的当前路由、固定只读操作、响应/分页/时间/稳定外部身份均未实证。公开入口和旧 `identity_unverified` 记录不能构成可信身份，不猜测身份映射或后端接口。没有完整性证明时不导入、不用空列表覆盖旧日程。
- **依赖顺序**：M2.1 先完成受控二课观测与脱敏页面结构检查，用户辅助确认真实入口及认证后业务目标；M2.2 固定服务端身份与两个只读契约，验证必要接口；M2.3 再定义最小 C3 映射/许可和只读查询交接，装配同步、查询与本地日程；最后验收取消、关闭、清理、重启和连续性。真实未知项不阻止独立的本机实现，但对应生产能力保持 unavailable。

| M2 验收条件 | 合成/本机检查 | 真实用户检查 |
|---|---|---|
| 当前二课身份、文档及原目标 | 无依据、冲突、确证串号、过期文档均拒绝交付；处置按 K-01，网关可达不当业务身份 | 登录链、两个业务目标、与预期本地账号匹配的服务端业务身份及恢复目标得到确认 |
| 日程完整只读采集 | 固定操作、正常/完整空/未登录/错误/不完整及分页边界、稳定外部键、明确北京时间、冲突重复行 | 实际日程的日期/时间/标题及覆盖范围正确；未出现的响应形状保持未观察 |
| 事务和本地连续性 | 同事务复验账号/原 generation/epoch/许可；失败零提交；重放不重复；变更保留 localId/覆盖；范围外和缺失仍保留 | 首次导入、正常重启与再次采集、隐藏恢复及已有 JW 日程保留 |
| 报名只读查询 | 不进入同步/日程表；明确分页终止/空结果，取消后的迟到查询不交付，不出现业务写 | 实际列表/必要详情正确，未点击报名/退出/签到/申报 |
| 资源与产品流程 | 全局互斥、隔离分区、文档/导航等有限控制、打开中取消、排空/真清理失败恢复和崩溃回收 | 真实取消、关闭与清理行为及原数据保留可用 |
| 阶段关闭 | 主代理独立 analyze/test/相关 Windows 原生/build 全套通过，失败与修复保留 | 用户确认对应交付清单；未实证项单列，只有用户明确批准才能移为后补 |

**M2.1 首切片规格（本机实现与检查完成，真实观测待验收）**：在正式首页增加“二课接入验证”。固定入口为 `https://young.ustc.edu.cn/login/`，公开本机 7897 代理检查确认 `/` 当前落地团委门户 `/main.htm`，`/login/` 是公开二课应用外壳；外部网页工具在根地址看到 `/nginx_auth/`，不把两种网络观测混为相同真实链路。公开登录模板还引用 Passport/UCAS，保留 JW 已验证的 ID/Analytics 认证中转，仅放行 Young、Passport、UCAS、ID、Analytics 五个精确 HTTPS origins，已登记 HTTP 文档按同站 HTTPS 升级；不放行模板中的外部厂商域名，不建立页面后台资源白名单。公开资料检查不登录、不保存正文；普通 sandbox 的本机代理 socket 访问被拒，使用只读权限检查后成功，指南页的降级重定向未跟随，不改浏览器策略。

首切片登记独立 provisional 观测分区，与 JW 正式分区不混用，不写正式业务库或认领许可。提供打开、固定入口重开、检查、取消并清理及失败重试；检查只返回闭合页面分类和 DOM 结构数量，不返回 URL/query/账号、文本、业务 ID、原文或任何认证资产。身份始终标为未验证，来源不可用；页面就绪或表格/日历存在不授权采集。检查绑定 session/document，导航、同文档变化、取消或关闭使迟到摘要失效，清理失败保持全局租约。

文件与分工：Sol / max 定共享浏览器目标及 C2/P 守卫、装配和原生合成验收，维护本任务唯一记录；Luna / max 限写 `source/young_observation_contract.dart` 及对应纯契约测试；另一 Luna / max 限写 `app/young_observation_panel.dart` 及对应 UI 测试。依赖接口先交接，文件互不重叠才并行；SDK 检查由主代理统一执行。仅修改本 worktree 的新 app/、本任务和必要状态入口，不读正式数据库、秘密或旧工程资产。首切片完成条件是合成窗口的受控打开/检查/文档失效/互斥/排空真删除实际通过，M0/JW 回归及正式 Release 构建通过，随后由用户辅助返回真实二课结构摘要；该准备切片不能关闭完整 M2。

#### M2.1 实现、失败与主代理验收（2026-10-11）

正式首页已装配“二课接入验证”。Sol / max 完成共享浏览器目标、原生守卫、全局租约、独立清理账本与产品装配；两名 Luna / max 分别提交闭合结构 DTO/纯契约测试和面板/UI 测试，另一名 Luna / max 只读核对本切范围及清理修复。模型、思考强度及设计依据均在派发时明确；所有 SDK 检查由主代理实际执行，不将子代理静态结论当作自动验收。

- Dart 与原生均锁定二课入口及五个精确 origins，来源类型不能混入教务认证、探针、课表导航或正式采集 RPC；教务凭据投递前即拒绝二课目标。二者使用同一个原生浏览器桥及全局作业租约。
- 原生返回恰好八个字段：session、document、ready、surface 及四项结构计数。业务 origin 以外只报告固定认证分类，不检查认证 DOM；业务页面只数表格、日历、分页及密码输入框，不读取输入值、个人文本、业务 ID、URL/query 或认证资产。DTO 拒绝多余字段、非法类型、计数越界和绑定不匹配。安全摘要为 `young-observation-v1`，固定 `identity=notValidated`、`sourceAvailable=false`。
- 打开、固定入口返回、检查、取消和清理重试均可从主窗口操作。导航、页内 history 变化、取消及关闭使旧结构失效；摘要复制只使用当前 DTO，迟到异步回调不能恢复旧状态。超时或排空失败保留租约并进入收口恢复。
- 未认领二课分区位于演示目录的 `young_observation_v1`，旧教务观测账本仍为 `observation_v1`，正式 JW 分区和业务库不变。两套账本分别恢复及删除，关闭浏览器整组进程并证明排空后才真删除；退出空闲二课端口不触及活动教务分区。

本轮实际失败与修复保留如下：

1. 初次完整本地测试的一项 UI 断言错误地要求第六条诊断不可见，产品规则为显示最近五条，最新诊断应可见；修正断言后通过，没有改变该显示规则。
2. 主代理复核退出顺序时发现，两个观测管理器若共用同一账本，空闲二课关闭会把活动教务分区当作未清理资产，实际反例返回 `cleanupPending`。已改为来源固定的独立账本，保留原教务路径、全局互斥及既有路径/排空守卫；新增两个方向的本地反例和实际教务窗口活动时的二课退出检查均通过。
3. 二课原生复验曾先返回 `staleResult`，一次仅重试读取后又因尚未就绪返回 `invalidSnapshot`。原因是合成 `pushState` 的 SourceChanged/HistoryChanged 通知尚未完成，测试过早驱动下一动作。测试现以当前文档就绪为前提，在 25 秒内只重试过期结构读取；旧文档仍必须拒绝，生产守卫没有放宽。最终两组 Windows 检查通过。
4. sandbox 内 SDK 启动出现路径/运行时异常，改用已批准的本机 SDK 执行检查；未升级 SDK、修改全局代理或系统信任。测试只访问合成回环页面、使用自建临时目录，排空后仅清理自身资产。

| 主代理本轮实际命令（`app/`） | 最终结果与范围 |
|---|---|
| `flutter analyze --no-pub` | exit 0；全工程零问题 |
| `flutter test --no-pub` | exit 0；317 项通过，1 个非 Windows 平台反例在 Windows 跳过；闭合摘要、来源守卫、全局互斥、文档失效、取消/超时恢复、独立账本和 UI 路径均包含在本轮 |
| `flutter test integration_test/young_observation_flow_test.dart -d windows --no-pub` | exit 0；2 组通过，实际 WebView 多跳合成认证、认证 DOM 不检查、旧文档拒绝、拒绝扩大生产目标、互斥、正常关闭/真删除、新分区及空闲二课退出时保留活动教务分区 |
| `flutter test integration_test/observation_flow_test.dart -d windows --no-pub` | exit 0；1 组通过，原有有限观测控制及强杀自身测试助手后的分区回收 |
| `flutter test integration_test/auth_redirect_flow_test.dart -d windows --no-pub` | exit 0；1 组通过，顶层/frame 多跳、HTTP 升级保留 POST 与错误证书拒绝 |
| `flutter test integration_test/jw_authentication_flow_test.dart -d windows --no-pub` | exit 0；4 组通过，固定自动认证、单次凭据投递、文档失效及人工挑战接续 |
| `flutter test integration_test/jw_sync_flow_test.dart -d windows --no-pub` | exit 0；6 组通过，真实 DPAPI/合成教务导入、选期/重启、取消、重复项/冲突与串号反例 |
| `flutter test integration_test/m0_flow_test.dart -d windows --no-pub` | exit 0；2 组通过，双库启动/重开、共享浏览器/租约与新增二课面板装配 |
| `flutter build windows --no-pub --target=lib/main.dart` | exit 0；正式 Release 产物为 `app/build/windows/x64/runner/Release/ustc_assistant_m0.exe`，保留整个目录 |

本轮 Windows 合计六套、16 组实际通过；未将此前其它原生检查算作本轮重跑。独立账本修复后完整本地测试、M0 和二课原生复验均通过，随后最终 analyze 与正式应用 build 通过。没有变更正式数据 Schema 或执行业务迁移；代理未直接读取真实数据库、密码或浏览器资产，未操作前台鼠标键盘、提交或推送。

同一正式 Release 已通过 CLI 启动，PID 33988 及系统窗口句柄确认；没有执行 Computer Use、检查学校页面或代替用户输入。应用沿用既有产品启动流程，实际首页和二课入口的真人显示仍由用户确认。后续真实登录及摘要已向用户发起请求，尚未收到真实二课结果。

文档核对通过：16 份当前文档、186 处本地链接、48 处锚点有效，07–15 九份历史正文与 HEAD 换行归一后相同，01–06 无差异，`git diff --check` 通过。

**当前交付状态**：M2.1 本机准备实现已完成；真实 Young 登录链、个人日程/活动目标和页面结构仍待用户辅助验证，服务端业务身份、固定只读接口和两个能力的完整性均未成立，生产能力保持不可用。请在新版“二课接入验证”手动登录，进入个人日程和活动列表分别检查，复制安全摘要；只反馈脱敏结论，不发送账号、密码、页面原文或日程明细。结构结果用于安排 M2.2，不作为身份或导入许可。完整 M2 不关闭，M0/M1 用户验收、既有失败与非空 JW 考试后补登记保留。

#### M2.1 用户真实页面结果（2026-10-11）

用户按接入验证请求返回两份 `young-observation-v1`：

| 实际页面 | ready / surface | 表格 | 日历根节点 | 分页控件 | 密码输入框 |
|---|---|---|---|---|---|
| 活动列表 | true / application | 1 | 0 | 1 | 0 |
| 个人日程 | true / application | 2 | 2 | 0 | 0 |

两份摘要均为 `identity=notValidated`、`sourceAvailable=false`。本轮确认真实学校认证后两个业务目标及结构检查可达，活动列表存在分页控件；没有提供身份字段、页面原文、账号、日期、业务 ID 或认证资产，也没有正式导入。此结果补充 M2.1 真人入口证据，不证明列表完整性、日程覆盖范围或服务端业务身份。随后继续 M2.2 的身份与固定只读接口核实，两个生产能力及完整 M2 保持开放；此前“待用户反馈”保留为交付时状态。

#### M2.2 下一切片规格：只读响应候选观测（2026-10-11）

**设计依据与目的**：继续从 `docs/README.md` 导航执行 07 的凭据/只读/隔离边界、08 的两能力分离、09 K-01/K-03/K-04、10 来源作业与收口、11 未就绪/结果投影、12 职责归属、13 V-01/02/03 及本文件工作流和 M2 验收条件。先证明不读取认证语义值而观测固定业务响应的能力，再核实真实业务身份字段、列表形状和完整性；本切候选结果始终 `identity=notValidated`、`sourceAvailable=false`，不授予生产身份、封存或导入许可。

公开应用和页面组件声明的候选 GET：业务根 `/login/wisdom-group-learning-bg/` 下 `/paramdesign/scMyInfo/info`（当前个人资料）、`/personal/scCalendar/getPageUserList`（按选择日期、带分页的个人日程）、`/mobile/item/enrolmentList`（活动列表）。其中报名人员名单接口属于他人信息，不列入候选。这些只来自公开代码，不是已验证服务器契约；日程页面混有自行添加能力，本切不将页面标题直接解释成已报名完整快照，后续须证明来源归属、覆盖和分页。公开代码的 Axios 从页面自身存储取得 X-Access-Token；应用不读取、复制、重放或自行设置该令牌，也不直接调用个人接口。用户在学校页面正常触发只读刷新，应用只观测匹配候选 GET 的业务响应。

**平台方案**：采用原生 CDP 的主 frame/loader、请求起点、requestId 和响应关联，整套绑定 session/document/operation。独立 WebResourceResponseReceived 的 URI/Method/GetContent 没有发起文档标识，不能凭回调时 URL 或当前 token 补足关联。候选操作开始前建立当前主文档映射；只接纳本操作内已记录完整起点且对应当前主 frame/loader 的 Fetch/XHR 请求。重定向、子 frame、worker/SW、缓存、非 GET、来源/路径不符、标识缺失、超限、读取失败和迟到结果均拒绝。页内路由变化、新文档、取消、停止及关闭即时失效，清空关联表；body 读取前后和交付前复验，不阻止页面本身正常网络或 Worker。

**K-03 实现解释与保密边界**：SDK 复合协议信封可能自动携带 headers 等字段进入原生 API 缓冲；接收该信封与提取/使用认证语义值分别记录。原生入口只借用、按结构跨度跳过未选择值，未知/秘密字符串不反转义、不构造副本、不传入现有会解码 skipped string 的 ProbeJson。只解码有界平台标识及方法，URL 只匹配固定 origin/路径，不解码认证 query；不订阅 ExtraInfo、不枚举 headers、不取 postData、不读取登录响应。事件 API 返回的 caller-owned 缓冲完整覆盖后释放，协议完成回调的 SDK-owned `LPCWSTR` 只借用、不可自行覆盖；解码协议正文所需的 app-owned 私有临时缓冲用后覆盖。不能宣称宿主缓冲从未含秘密字节。该白名单元数据投影是 K-03 既有必要元数据许可下的技术选择，经 Astra / high 只读复核；不放宽令牌/认证资产禁读，不接受页面运行时对象作为服务器证据。

**接口与最小结果**：原生 begin/read/stop 固定 RPC，只有 Young 当前观测作业可调用；开始不会自动发业务请求。DTO 内部闭合绑定 session、document、operation，返回 listening、accepted/rejected 计数、固定 lastRejection，以及 profile/schedule/activities 三份候选结构。结构只报告观测数、success 分类、code/result/records/total 类型、记录数和固定字段类型；个人资料仅 loginCode/username 类型，日程/活动仅 id/title/date/startTime/endTime 类型，不解码业务字符串值。安全摘要 `young-readonly-observation-v1` 不含实际标识、URL、参数、个人值或原文。列表空态只是形状观察，不证明完整性。

**分工与文件边界**：Sol / max 负责平台投影与文档关联设计、共享桥/协调器装配及本机最终验收；可委派 Sol / max 实现独立原生跨度解析器和合成反例，根代理复核集成。Luna / max 分别限写新候选 DTO/测试和端口下新只读观测面板/测试，依赖接口先确定，互不重叠；不自行改契约、读取私有资产或调用学校 API，SDK 统一由主代理执行。继续修改新 app/ 及本任务和必要入口，不改正式 Schema/数据、凭据用途或分区许可。

**完成条件**：纯投影合成 sentinel 不进入被跳过值的解码/DTO/日志；实际 WebView 验当前主文档响应、旧文档/页内路由/并发同 URL/停止后返回、跨 frame/worker/SW/缓存/重定向/缺标识、混合秘密或畸形超限业务响应等拒绝；取消排空仍保留租约到真清理。主代理 analyze/test/相关 Windows/build 通过后由用户正常触发上述页面的只读刷新并返回闭合候选摘要。真实字段/前后身份与本人路线、日程完整覆盖及活动查询完整性仍按随后实证确定，不能凭候选观测直接关闭 M2。

#### M2.2 本机实现与复核续记（2026-10-11）

本切由主代理 Sol / max 统筹：Luna / max 限写闭合 DTO、独立面板及对应合成测试，接续补协调器/原生 Dart 端口测试；Sol / max 子代理限写独立 C++ 跨度投影和反例；根代理实际装配 native observer、桥/排空计数、协调器、首页及 loopback 来源。Astra / high 对方案和实际代码只读复核，子代理均未访问真实学校接口、正式数据或认证资产，没有以子代理完成声明代替根验收。

原生操作先绑定当前主 frame/loader，并在 `Network.enable` 后读取 `Performance.getMetrics` 的单调 Timestamp 作为起点；请求自身 timestamp 必须不早于屏障，queued 旧事件不能凭回调时间取得许可。该 Timestamp 的同域依据为 [Chromium 当前实现](https://github.com/chromium/chromium/blob/main/third_party/blink/renderer/core/inspector/inspector_performance_agent.cc)，协议定义见 [Performance](https://chromedevtools.github.io/devtools-protocol/tot/Performance/) 与 [Network](https://chromedevtools.github.io/devtools-protocol/tot/Network/)，实际 WebView 行为另以合成验证。只取固定 GET 且匹配当前主文档的非缓存、非 SW JSON 响应；等待 body 的请求与未完成请求共用 64 项在途额度，候选接受上限 1024。缺失或无法归属的事件使所有在途候选起点失效，不能继续用旧 requestId 接纳重定向最终正文。记录终止后、正文交付前再次检查当前操作。

页面导航会即时清除许可与摘要，但不会假称旧 RPC 已排空。原原生 RPC 尚未结束时新 start 保持 busy；旧返回只得 stale，结束后可在新文档开启新 operation。停止移除监听并禁用本次 Network/Performance 域，保留当前页面的已取得类型摘要；导航/关闭只失效并移除监听，不在 closing 后追加 CDP 请求。所有平台异步调用继续计入 native pending_scripts，租约及分区的删除仍等待既有浏览器群排空证明。本轮未改正式 Schema、JW 凭据用途、已认领分区或业务数据。

**失败与修复**：

- 独立 g++ 启动因系统 DLL 重定位失败，未进入源码编译；按主代理指示停止环境尝试，随后使用现有 Windows MSVC/Flutter 构建验证。
- 首次 analyze 发现 DTO 类型提升辅助函数、UI 缺导入、测试 Stream.hasListener/同名 helper 遮蔽等 11 项问题；限定文件内修复。新原生测试误用 DemoDirectory.close 导致首次构建失败，改为现行 release 接口；另补测试 if 的花括号。均保留为本次集成失败，不将初版记为零问题。
- 第一轮全量本地测试为 349 通过、1 跳过、2 失败：DTO 反例误将 true 当非法 bool；UI 在初次开始尚无 DTO 时寻找不存在的复制按钮。修正测试，并补真实复制进行中单飞/文案检查后，根全量结果为 352 通过、1 个平台反例跳过。
- Astra 实码复核发现：超长/超成员的重定向事件未清除旧请求；超长 caller-owned 缓冲只擦上限前缀；body 读取前移出请求表可绕过在途上限。根已分别修为未归属事件失效在途表、整份 caller-owned 缓冲析构擦除、请求与待取 body 合并额度。实际 loopback 追加 290 头部的重定向后正常最终响应反例；debug 固定反例另核验全 64 项在等待 body 时不能接受新起点。

**最终根代理检查与交付**：Dart analyze 零问题，全量本地测试 352 通过、1 个平台反例跳过。以下七套 Windows 原生合成回归全部通过，共 17 组；均不访问真实学校或正式业务库：

| 原生套件 | 组数 | 本轮检查重点 |
|---|---:|---|
| young_read_only_flow_test | 1 | private sentinel 投影、首观测前请求、三个候选与并发同 URL、POST/重定向/290 头部超限重定向/子 frame、畸形与混合秘密正文、缓存/worker/SW、停止后返回、route 失效及在途时关闭后真清理；debug 原生纯投影和在途额度反例一并调用 |
| young_observation_flow_test | 2 | Young 导航/闭合结构/全局租约/实际删除与精确目标不可扩展 |
| observation_flow_test | 1 | 普通 WebView 文档控制、排空及恢复 |
| auth_redirect_flow_test | 1 | HTTPS 表单及 302/303/307/308 顶层与 iframe 跳转 |
| jw_authentication_flow_test | 4 | 固定认证、单次投递及 route/refresh/节点改变撤销 |
| jw_sync_flow_test | 6 | 自动认证/学期目录/预选、持久事务、取消、重复合并、冲突与身份变化零提交 |
| m0_flow_test | 2 | 正式 Windows 根目录双库重开、应用首页及 M0 闭环 |

最终 `flutter build windows --release --no-pub --target=lib/main.dart` 通过，正式目录仍为 `app/build/windows/x64/runner/Release/`。用户已确认关闭旧应用后，根使用 CLI 启动同一路径新版，读取到 PID 37876、HasExited=false、MainWindowHandle=11731580；未使用 Computer Use、未读取真实学校页面、正式数据库或认证资产，不把窗口句柄当作真人界面验收。

**当前状态与真实下一步**：本机候选观测切片已交付，M2.2 的服务端业务身份及生产只读契约尚未成立。用户可在个人日程和活动列表分别开始当前页面的接口观测，再用学校页面已有的日期/查询/分页等只读控件触发请求，更新并复制 `young-readonly-observation-v1`；整页刷新或路由跳转会撤销旧操作。未观测某候选不能解释为数据为空；本机候选通过不证明 Young 身份、完整日程或活动分页契约，真实学校响应仍待实证。M0/M1 关闭与 JW 非空考试后补保持，完整 M2 不关闭。

#### M2.2 用户真实候选响应与浏览器探索安排（2026-10-11）

用户在活动列表和个人日程返回两份 `young-readonly-observation-v1`，两者均 listening=true、rejected=0、lastRejection=none，业务身份仍为 notValidated、sourceAvailable=false：

| 目标 | 接受的请求数 | 最后一次响应的结构 | 用户补充与证据限制 |
|---|---:|---|---|
| 活动列表 | 11 | success=true，code 为 number，result 为 object，records 为 array，记录数 10，total 为 number，id 为 string；候选 title/date/startTime/endTime 均 absent | 页面共有 8 页，用户重复访问了部分页；11 是请求次数，不能当作 11 个不同页或完整分页证明 |
| 个人日程 | 36 | success=true，code 为 number，result 为 object，records 为 array，最后一次记录数 0，total 为 number；候选记录字段均 absent | 用户观察到似乎每一天各发一个候选请求；只记录最后一次的类型与计数，不能将其解释成完整日期范围为空 |

两次均未捕获 profile 候选，不能把零观测当作空身份或身份失败。真实证据确认已选活动/日程请求及响应外形可被平台接收；活动名称、时间等字段尚须依据实际契约核实，日程归属和覆盖、活动分页终止及可信服务端身份仍未成立。本轮没有二课正式导入，M0/M1 关闭、已有教务事实及完整 M2 开放状态保留。

用户提出由本人登录二课后，主代理通过 Edge 自行探索，以减少重复构建和手工摘要往返，并选择“连接 Edge 后继续”。此授权用于独立浏览器标签页内的只读调研：业务导航、日期/查询/分页及必要详情；真实登录、验证码和额外学校授权仍由用户完成，不操作报名、退选、签到、申报或修改信息，不提取认证资产或将个人值、原始响应写入文件/日志。浏览器调研结果用于确定产品契约，不能替代本应用隔离分区、文档关联、可信身份及导入许可验收。

主代理读取 computer-use 技能及浏览器控制文档后，尝试为 Edge 创建独立二课标签页，工具返回 `Browser is not available: edge`；随后可用浏览器清单只有 Codex 内置浏览器和 MCP Apps。当前尚未进入学校页面或操作前台输入，用户选择保留 Edge 方案；待 Edge 实际接入后再由用户登录并继续只读探索，不将选项回复解释成已经连接或已经登录。

随后 Edge 扩展出现在可用浏览器清单。创建标签页、枚举现有标签页及连接已知二课入口的实际请求均未收到响应；读取控制说明成功，但没有取得页面状态，创建请求的结果也未确定。按已读取的浏览器恢复说明保持同一浏览器目标，并尝试一次重置控制会话后重新连接，仍失败；没有改代理、提取浏览器资产、接管前台输入或把协议错误解释成学校接口失败。

用户明确报告已打开 Edge 并登录二课，指定重点为“项目管理 → 我要报名”和右上角“欢迎您… → 我的日程”。该报告是用户登录状态及目标说明，不是主代理已经成功读取页面的证据。当前阻点是已识别 Edge 的控制通道不响应，待扩展连接恢复；用户无需重新登录。主代理继续限定的未认证公开组件调研，由 Luna / max 仅核查这两个目标的公开字段、日期/分页和只读动作声明，不调用已认证接口、不写文件，仍须由实际页面及产品原生验证补证。

**Edge 连接诊断续记**：用户确认安装的扩展名为 ChatGPT，侧栏可以正常打开。根先读取本地浏览器控制/诊断说明，再经 OpenAI Docs 技能查阅 [官方浏览器扩展说明](https://learn.chatgpt.com/docs/chrome-extension)，按插件提供的只读命令核查：Edge 运行、浏览器已安装、Default profile 的官方扩展已安装且启用、native-host manifest 名称/许可 origin/注册路径正确，四项均 exit 0。诊断只读取安装及登记元数据，没有提取学校会话资产、修改配置或修复本地通信宿主。侧栏开启后再次枚举标签页仍无响应，尚未取得二课页面状态；不能将正确安装或可打开侧栏等同于当前控制通道可用。后续可按官方支持的具体标签页 `@` 引用尝试明确绑定，仍失败则由用户按浏览器插件界面恢复连接，不自行安装宿主或以其它脚本接管 Edge。

**公开组件调研与根复核**：Luna / max 仅经既有 7897 代理 GET 三个已登记的未认证静态 JS，sandbox 首次无法连接代理后使用只读权限取得；原文只在内存处理，没有写文件。根独立 GET [公开业务组件 bundle](https://young.ustc.edu.cn/login/sc-wisdom-group-learning/static/js/chunk-0d0ec75b.13842608.js)，复核以下路径、字段及控件声明；日期赋值的首次短窗口核查没有找到 literal `queryParam.now`，Luna 回查确认真实表达式为把 `{now:选中日期}` 整体赋给 queryParam，没有将该短窗口漏匹配记成服务器字段失败。所有结论仅为公开声明，待真实响应补证：

| 候选 | 公开声明 | 下一步实证限制 |
|---|---|---|
| 活动列表 `/mobile/item/enrolmentList` | 列表状态切换后使用该固定路径，以 id 作行键，名称 itemName；applyEt 显示为报名截止时间，不能当作活动起止时间。查询筛选包括 itemName/module/form/itemLable，共享分页默认 10 条，使用 pageNo/pageSize 和 result.total | v1 摘要没有投影 itemName/applyEt，先前 title/date/startTime/endTime 缺失不能推断真实名称/截止时间缺失。页面对应关系、实际记录形状、页总量/终止和必要详情须在真实只读界面确认 |
| 个人日程 `/personal/scCalendar/getPageUserList` | mySchedule 组件展示 title/place/startTime/endTime，以 id 作行键；change 将选中日期格式化为 YYYY-MM-DD，把 now 传入共享列表，继承 pageNo/pageSize 分页，默认 10 条。页面另有新增日程及 add-schedule 子组件 | 未声明日期区间或可区分已报名与自建的来源过滤；实际日期包含规则、跨日/分页完整性及报名归属仍未知，不能把整页全部记录直接导入为已报名活动 |
| 个人资料 `/paramdesign/scMyInfo/info` | getPersonalInformation 读取并显示 username/realname/deptName/grade/sex 等，type 仅区分学生、研究生、教师等；该组件没有 loginCode 引用 | 本轮真实 profile 仍未观测；展示字段或公开组件声明不构成已验证服务端账号，不直接授予生产身份 |

本次只更新调研与验收登记，没有修改产品接口、Schema、业务数据或凭据用途，没有重跑 SDK 或覆盖之前 352 项本地/17 组 Windows 的发生时记录。实际 Edge 探索、服务端身份、日程归属/覆盖与活动分页仍待完成，两个生产能力及完整 M2 保持开放。
