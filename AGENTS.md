目的：开发一个校园学习生活全面辅助ai系统

当前情况：仅有初步构想，大体结构如下

1、主体是一个日程表，一个智能体，这个智能体具有一些 agent 功能，能够根据学校网站信息和用户要求修改日程表、查询和推荐二课等，并拥有对学校各种事务、历史、通知的完善知识库。二课报名操作始终由用户在学校官方页面中自行完成，系统不自动提交报名或取消报名。
2、学生输入账号密码，系统能自动登录学校网站抓包获取相关信息。

目前能够想到主要功能：
1、通过学校的网站的课表界面、考试安排、二课平台等网站，自动生成基础日程
2、能通过与llm对话完善日程（增加日程，对某些日程的进行特定标记等）
3、早上起来，打开软件，llm自动提醒今天要上什么课，哪些课要点名一定要去，以及其他要干的事情
4、上课期间，老师布置作业，能通过聊天为这次作业的内容、ddl、当前计划完成的时间段等相关信息加入日程中，能根据已有日程自动规划理想完成时段，能通过聊天调整时段
5、中午吃饭，能根据目前所在校区（由上节课的信息判断），推荐食堂
6、能根据二课平台的信息推荐二课，比如筛选具体类型学时的二课，根据名称搜索二课
7、晚上和朋友约好开黑也能加入日程作为一部分，也可以每天特定时间直接定为娱乐时间
8、支持其他添加任意日程

其他要求：
1、最终产品形态要为一个手机app，支持任意系统
2、所有的功能都能通过和智能体聊天解决，同时也支持手动修改日程
3、有专门的api key连接llm，智能体该如何实现不是很清楚。

---

项目结构介绍：

1、`AGENTS.md`：项目总说明与阶段性进度记录。这里保存已经确认的方向、接口结论、安全约束、下一步建议，方便后续继续对话时快速恢复上下文。
2、`docs/`：长期文档目录，记录数据模型、接口研究、转换规则和导入管线设计。
   - `docs/schedule-data-model.md`：项目内部核心日程模型，包括 `CalendarEvent`、`Task`、`PlanBlock`、`ScheduleRelation`、`SourceRecord`、`UserOverlay`、`Reminder`、`ActionLog`、`AgentPermissionPolicy`、`KnowledgeItem`。
   - `docs/ustc-jw-course-source-template.md`：教务课表抓包时记录请求、响应和字段含义的模板。
   - `docs/ustc-jw-course-table-integration.md`：中科大教务课表入口、请求链路和 MVP 接入流程。
   - `docs/ustc-jw-course-transform.md`：课表 `datum` 数据转换为标准日程事件的规则。
   - `docs/ustc-jw-exam-transform.md`：考试信息 HTML 转换为标准日程事件的规则。
   - `docs/ustc-jw-import-pipeline.md`：课表、考试等教务来源进入统一导入包的本地管线边界。
   - `docs/superpowers/`：阶段性设计和实现计划记录，主要用于保留较完整的开发过程。
3、`scripts/`：可运行的本地原型脚本。
   - `scripts/convert_ustc_jw_datum.py`：将教务课表 `datum` JSON 转换为 `CalendarEvent`、`SourceRecord`、`ScheduleRelation`。
   - `scripts/convert_ustc_jw_exam_html.py`：将保存后的考试信息 HTML 页面转换为 `CalendarEvent` 和 `SourceRecord`。
   - `scripts/import_ustc_jw.py`：合并课表、考试等本地转换结果，生成统一教务导入包。
   - `scripts/ustc_jw_collector.py`：通过 Playwright 和专用 Edge 会话完成 CAS 登录等待、课表认证态请求与考试 HTML 采集。
   - `scripts/collect_ustc_jw.py`：实时采集命令行入口，在内存中转换课表和考试并写入统一导入包。
   - `scripts/ustc_young_collector.py`：通过同一专用 Edge 会话采集二课平台当前处于“报名中”的活动列表，负责页面登录等待、分页和响应校验。
   - `scripts/collect_ustc_young.py`：二课“报名中”活动列表采集命令行入口，默认写入规范化结果，完整原始记录仅在显式请求时保存。
   - `scripts/ustc_young_schedule_collector.py`：通过二课平台“我的日程”日历逐日查询已报名活动，负责北京时间窗口、跨月导航、响应校验和记录去重。
   - `scripts/collect_ustc_young_schedule.py`：二课已报名日程采集命令行入口，默认生成脱敏的滚动窗口快照。
4、`examples/`：脱敏样例输入和输出，供转换规则、测试和文档引用。
   - `examples/ustc-jw-datum.sample.json`：脱敏课表 `datum` 样例。
   - `examples/calendar-events.sample.json`：课表转换后的标准日程样例。
   - `examples/ustc-jw-exam-page.sample.html`：脱敏考试信息 HTML 样例。
   - `examples/ustc-jw-exam-events.sample.json`：考试转换后的标准日程样例。
   - `examples/ustc-jw-import-bundle.sample.json`：课表和考试合并后的统一导入包样例。
5、`tests/`：单元测试目录。
   - `tests/test_convert_ustc_jw_exam_html.py`：考试 HTML 解析和转换测试。
   - `tests/test_convert_ustc_jw_datum.py`：课表事件身份与特殊分组碰撞回归测试。
   - `tests/test_import_ustc_jw.py`：统一导入器测试。
   - `tests/test_ustc_jw_collector.py`：浏览器采集 URL、认证态请求、CAS 入口、错误脱敏和假 Edge 流程测试。
   - `tests/test_collect_ustc_jw.py`：实时采集 CLI 的内存转换、输出策略和编排测试。
   - `tests/test_ustc_young_collector.py`：二课列表接口识别、响应校验、分页合并、登录等待、错误脱敏和假 Edge 流程测试。
   - `tests/test_collect_ustc_young.py`：二课列表规范化、默认输出、可选原始保存和 CLI 编排测试。
   - `tests/test_ustc_young_schedule_collector.py`：二课已报名日程的北京时间窗口、自然月计算、按日响应、跨月导航、去重和假 Edge 流程测试。
   - `tests/test_collect_ustc_young_schedule.py`：二课已报名日程规范化、隐私字段排除、默认输出、可选原始保存和 CLI 编排测试。
6、`tmp/`：本地临时输出目录，用于存放脚本运行生成的调试文件，不作为长期项目文档。
7、`temp.md`：本地临时抓包记录，可能包含敏感信息。它只用于当前研究，不应对外分享，也不应写入公开文档。

---

当前进度记录（2026-07-11）：

1、项目已明确优先针对中国科学技术大学，第一阶段重点连接综合教务系统和二课平台。
2、教务课表被选为第一个打通的数据源，因为它是日程系统、今日提醒、校区判断和后续规划功能的基础。
3、已创建课表数据源记录模板：`docs/ustc-jw-course-source-template.md`。
4、已形成教务课表接入方案：`docs/ustc-jw-course-table-integration.md`。

教务课表抓包结论：

1、教务系统页面很多功能在 `https://jw.ustc.edu.cn/home` 内部切换，URL 不一定变化，但会产生 Fetch/XHR 请求。
2、课表入口形态类似 `/for-std/course-table/info/{dataId}`，其中 `dataId` 与用户课表视图相关，视为敏感上下文字段，不要写死到公开代码或文档。
3、课表上下文接口：
   `GET /for-std/course-table/get-data?bizTypeId=2&semesterId={semesterId}&dataId={dataId}`
   该接口返回 `lessonIds`、周次、日期映射和部分课程元数据。
4、课表明细主接口：
   `POST /for-std/course-table/datum`
   请求体为 `{ "lessonIds": [...] }`。
   返回 `result.lessonList`、`result.scheduleList`、`result.scheduleGroupList`。
5、`scheduleList` 是生成日程的主数据源，但存在同一节课多位老师造成的重复记录，需要按课程、日期、时间、地点等字段合并。
6、`semesterId` 是教务系统内部 ID，不能按年份推算。MVP 不自动列出所有学期，而是监听当前页面选中学期的 `get-data` 请求，从 URL 中解析 `semesterId` 和 `dataId`。

MVP 课表导入流程：

1、用户登录教务系统并打开“我的课表”。
2、用户在页面中切换到目标学期。
3、程序监听 `get-data` 请求，解析 `semesterId` 和 `dataId`。
4、读取 `get-data` 返回的 `lessonIds`。
5、调用 `datum` 获取 `lessonList` 和 `scheduleList`。
6、合并重复上课记录，转换为项目标准日程事件。

安全约束：

1、不要保存用户密码明文。
2、不要把密码、Cookie、Token、完整学号、姓名、完整个人课表原文发送给 LLM。
3、`temp.md` 是本地临时抓包文件，可能包含敏感信息，不应对外分享，也不应作为长期项目文档。
4、自动导入课表属于读取操作，风险较低；后续涉及二课报名、事务申请等写操作时，必须让用户确认并记录操作日志。
5、二课报名和取消报名不纳入 Agent 自动写操作，即使未来权限设置允许放宽其他风险操作，这两项仍由用户在学校官方页面自行执行。

下一步建议：

1、设计项目内标准日程数据模型。
2、用脱敏样例验证 `datum` 到标准日程事件的转换逻辑。
3、继续研究考试安排接口。
4、随后研究二课平台的活动查询和报名流程。

已新增核心模型文档：

1、`docs/schedule-data-model.md` 定义了项目内部日程核心概念，包括 `CalendarEvent`、`Task`、`PlanBlock`、`ScheduleRelation`、`SourceRecord`、`UserOverlay`、`Reminder`、`ActionLog`、`AgentPermissionPolicy`、`KnowledgeItem`。
2、当前模型假设：导入的学校源数据不直接覆盖，用户修改通过 `UserOverlay` 保存；作业先作为 `Task`，规划后生成 `PlanBlock`；数据本地优先保存，云同步作为后续可选能力。
3、Agent 权限采用可配置风险策略：风险项首次修改时请求用户确认，确认时可选择“此类型以后不再确认”，并可在设置中统一管理权限松紧。模型中新增 `AgentPermissionPolicy` 表示这类授权。
4、课程出勤策略分为必去、可以赌、不去，并支持 LLM 可读取的自由备注；“可以赌”的课需要在前一天或当天询问用户到底去不去并记录。课程还支持听讲/不听讲选项。
5、时间重叠不直接等于冲突，模型新增 `ScheduleRelation` 表示冲突/不冲突及原因；课上写作业、个性化选课、翘课参加二课或娱乐都需要能被真实记录和解释。
6、下一步可以用脱敏 `datum` 样例验证“中科大教务课表 -> 标准 `CalendarEvent`”的转换逻辑。

课表转换样例与规则：

1、已创建 `examples/ustc-jw-datum.sample.json`，基于真实抓包结构脱敏改写，覆盖多位老师、不同周次不同老师、`customPlace`、虚拟教室、实验课、同时间课程等典型情况。
2、已创建 `examples/calendar-events.sample.json`，展示 `datum` 转换后的 `CalendarEvent`、`SourceRecord`、`UserOverlay`、`ScheduleRelation` 样例。
3、已创建 `docs/ustc-jw-course-transform.md`，记录合并 key、时间解析、字段映射、默认出勤/听讲策略、`externalId`、`UserOverlay` 应用和 `ScheduleRelation` 生成规则。
4、两个 JSON 样例已通过本地 JSON 解析检查。
5、已实现转换原型脚本：`scripts/convert_ustc_jw_datum.py`。
   示例运行命令：
   `conda run -n basic310 python scripts\convert_ustc_jw_datum.py --input examples\ustc-jw-datum.sample.json --output tmp\calendar-events.generated.json --semester-key 2026spring --user-id user_sample`
6、当前脚本已能生成 `CalendarEvent`、`SourceRecord`、`ScheduleRelation`，并验证了时间解析、多老师合并、`customPlace` 兜底、虚拟教室 tag、实验课默认策略和重叠事件关系。样例输出为 6 个事件、6 条来源记录、1 条时间重叠关系。
7、脚本已通过 `conda run -n basic310 python -m py_compile scripts\convert_ustc_jw_datum.py` 语法检查。

考试安排接入进度：

1、已确认固定入口 `GET /for-std/exam-arrange` 返回 HTTP 302，并跳转到 `/for-std/exam-arrange/info/{contextId}`。课表固定入口 `/for-std/course-table` 采用相同机制，当前观察到两个模块的上下文 ID 相同；该 ID 不由学号推算，也不长期保存。
2、考试详情页的完整数据直接服务端渲染在 `table#exams`，不需要额外的 Fetch/XHR 明细接口。列为课程号/课堂号、考试类型、课程名称、日期时间、考场、教学楼、考场所在校区、考试说明；真实页面观察到第一列表头为“课堂号”，脱敏样例为“课程号”，解析器兼容这两个明确别名。
3、已创建脱敏输入样例 `examples/ustc-jw-exam-page.sample.html` 和标准输出样例 `examples/ustc-jw-exam-events.sample.json`。
4、已实现标准库解析脚本 `scripts/convert_ustc_jw_exam_html.py`，只读取 `table#exams`，生成 `CalendarEvent` 和 `SourceRecord`，不处理登录、Cookie 或网络请求。
5、已创建转换规则文档 `docs/ustc-jw-exam-transform.md`，记录入口、字段映射、校验、`externalId`、指纹和安全边界。
6、已创建测试 `tests/test_convert_ustc_jw_exam_html.py`，覆盖正常解析、空表、HTML 实体、表头变化、列数错误、缺失字段、时间错误、重复身份和指纹变化。
7、考试事件默认 `type=exam`、`importance=critical`、`attendancePolicy=must_go`；跨来源冲突关系由统一日程聚合层处理。

教务统一导入管线进度：

1、已实现本地统一导入脚本 `scripts/import_ustc_jw.py`，可合并课表 datum JSON 与考试 HTML 的转换结果。
2、统一导入器不处理登录、Cookie、Token、302 跳转或网络请求，只读取本地文件并输出结构化导入包。
3、已创建脱敏合并样例 `examples/ustc-jw-import-bundle.sample.json`，当前样例包含 9 个 `CalendarEvent`、9 条 `SourceRecord`、1 条 `ScheduleRelation`。
4、已创建说明文档 `docs/ustc-jw-import-pipeline.md`，记录采集层、转换层、聚合层的职责边界和命令用法。
5、已新增测试 `tests/test_import_ustc_jw.py`，覆盖课表+考试合并、仅课表导入、重复 ID 拒绝和 CLI 输出。
6、下一步先在真实教务会话中验收“登录 -> 2026 春课表 -> 考试 -> 统一导入包”，确认 Edge 密码保存、`get-data` 监听和认证态 API 请求均符合实际行为；验收稳定后再研究二课平台。

教务实时采集原型进度（2026-07-13）：

1、已创建根目录 `requirements.txt`，实时采集原型仅新增 Playwright 依赖。
2、独立 Conda 环境实际名称为 `ustc_assistant`，已确认 Python 3.10.20、Playwright 1.61.0；本机 Microsoft Edge 可用。
3、已实现 `scripts/ustc_jw_collector.py`：启动可见的专用 Edge 持久配置，优先复用登录状态；未登录时自动进入 `/ucas-sso/login`，由用户在官方 CAS 页面完成首次登录或验证码。
4、课表采集先访问固定入口 `/for-std/course-table`，从实际初始 `get-data` 响应 URL 中解析动态 `dataId`，随后以 `semesterId=421` 获取 2026 春的 `lessonIds` 并调用 `datum`。
5、考试采集访问固定入口 `/for-std/exam-arrange`，跟随 302 后等待 `table#exams` 并在内存中取得 HTML。
6、已实现 `scripts/collect_ustc_jw.py`：原始课表 JSON 和考试 HTML 默认仅驻留内存，转换成功后写入 `tmp/ustc-jw-import.generated.json`。
7、只有显式使用 `--save-raw` 才会在 `tmp/private/` 写入完整原始响应；日志和标准导入包不包含密码、Cookie、CAS ticket、`dataId` 或 `contextId`。
8、实时运行命令：`conda activate ustc_assistant` 后执行 `python scripts\collect_ustc_jw.py`。真实登录和教务请求需要用户手动验收，自动测试不访问学校网站。
9、首次真实链路测试已成功完成登录、课表采集和考试 HTML 获取；发现考试第一列表头实际为“课堂号”，现已加入回归测试并兼容“课程号/课堂号”两种页面版本。
10、第二次真实链路测试发现同一课程、排课组、日期和时间下可能存在多个不同地点或 `exerciseClass` 的合并组，旧 `externalId` 会碰撞。现仅对发生碰撞的组追加 `placeKey + exerciseClass` 稳定哈希后缀，普通事件 ID 保持不变。
11、进一步检查真实导入包发现，人工智能课程同一时段的不同教师行分别使用 `exerciseClass=false` 和 `exerciseClass=null`，语义上均表示非习题课，却被错误拆成两个事件。现将 `null`、`false` 和空字符串统一规范为 `none` 后再分组，教师会合并进入同一事件；明确 `true` 或内容不同的习题课信息仍保持独立。

二课“报名中”活动列表采集原型进度（2026-07-21）：

1、已确认活动列表稳定接口路径为 `GET /login/wisdom-group-learning-bg/mobile/item/enrolmentList`；查询参数 `_t` 和 `requestParams` 动态变化，其中明文分页参数 `pageNo` 会在前端请求拦截器中加密。
2、真实页面观察到响应中的 `result.current` 在所有页面均为 `1`，不能作为页码依据；采集器改用首页 `pages` 和网页分页控件推进，并按活动 `id` 合并。
3、已实现 `scripts/ustc_young_collector.py`：复用教务原型的可见 Edge 持久配置，等待官方页面登录，点击“报名中”并依次点击下一页，严格校验响应结构和最终唯一活动数量。
4、采集器不复刻 AES 加密逻辑，不读取、打印或保存 `X-Access-Token`、Cookie、CAS ticket、`requestParams`；动态请求完全由学校前端生成。
5、已实现 `scripts/collect_ustc_young.py`：默认输出 `tmp/ustc-young-enrolment.generated.json`，只保留已定义的规范化活动字段；仅显式使用 `--save-raw` 时写入 `tmp/private/ustc-young-enrolment.raw.json`。
6、已新增 `tests/test_ustc_young_collector.py` 和 `tests/test_collect_ustc_young.py`。自动测试使用假页面与假响应，不访问学校网站；下一步由用户运行真实命令验收页面文本定位和 Ant Design 分页选择器。
7、首次真实运行发现，未登录时访问 SignUp 路由会在登录成功后落到 `/dataAnalysis/visual`，不会恢复原目标地址。采集器现会检测“已进入二课 SPA 但不在 SignUp”的状态，并在同一登录超时内自动重新打开 SignUp；对应行为已加入回归测试。

二课已报名日程采集原型进度（2026-07-21）：

1、已确认页面入口为 `/login/sc-wisdom-group-learning/personalInformation/mySchedule`，在日历中选择日期会触发只读接口 `GET /login/wisdom-group-learning-bg/personal/scCalendar/getPageUserList`。接口按所选日期返回个人日程，不是一次返回完整报名历史。
2、查询窗口统一按北京时间 `Asia/Shanghai` 计算，为闭区间 `[今天 - 7 天, 今天顺延一个自然月]`；若目标月不存在同号日期，则结束日期落到目标月最后一天。
3、已实现 `scripts/ustc_young_schedule_collector.py`：复用专用 Edge 登录状态，通过学校前端逐日点击日历并监听固定接口响应，不生成或解密 `requestParams`。跨月导航兼容 Ant Design 日历的前后月按钮及年月下拉框。
4、采集器严格校验每天的响应、记录时间和所选日期。空日期是正常结果；若单日返回多页，当前原型会明确失败而不输出不完整快照，待真实页面分页 DOM 取得证据后再扩展。
5、已实现 `scripts/collect_ustc_young_schedule.py`，默认输出 `tmp/ustc-young-my-schedule.generated.json`。标准输出包含来源日程 ID、来源活动 ID、标题、北京时间起止时间、地点和纯文本说明，不包含响应中的 `userId`、Token、Cookie 或 `requestParams`。
6、运行命令为 `conda activate ustc_assistant` 后执行 `python scripts\collect_ustc_young_schedule.py`。可用 `--today YYYY-MM-DD` 固定“今天”以复现日期边界；仅显式使用 `--save-raw` 时才会将完整原始记录写入 `tmp/private/ustc-young-my-schedule.raw.json`。
7、该输出是本次查询窗口的完整快照，不承担历史删除语义。活动离开滚动窗口时，未来 App 不应因此删除历史记录；统一同步层需根据 `source + sourceScheduleId` 执行 upsert，并区分“窗口外”“窗口内缺失”“来源取消”和“用户删除”。
8、未来统一同步层必须保留 `UserOverlay`，来源重复采集只能更新来源字段，不能覆盖用户备注、出勤策略、听讲策略或提醒设置。取消或缺失记录默认保留历史并改变状态，不能静默物理删除。
9、已新增 `tests/test_ustc_young_schedule_collector.py` 和 `tests/test_collect_ustc_young_schedule.py`；自动测试不访问学校网站，真实登录与日历控件验收结果见后续记录。
10、首次真实运行确认登录后位于正确的 `mySchedule` 页面，但日期没有改变选中状态，也没有触发按日接口。最初怀疑点击目标应由外层 `td` 改为内部 `.ant-fullcalendar-date`，第二次运行仍失败，说明问题发生在点击之前的元素定位阶段。
11、浏览器 Console 检查确认，真实日期单元格的 `title` 使用中文本地化格式 `2026年7月14日`，而不是原型最初假设的 `2026-07-14`。采集器现按中文年月日生成选择器，并将“日期单元格未找到”和“点击后未返回目标响应”拆成两类错误；对应行为已加入回归测试。
12、真实链路已成功完成“登录 -> 打开我的日程 -> 逐日查询 -> 生成规范化快照”。2026-07-21 的验收输出覆盖北京时间 2026-07-14 至 2026-08-21，共查询 39 天，其中 38 天为空并取得 1 条日程；元数据计数与实际记录一致，且没有重复 ID、必填字段缺失、非法时间、非北京时间、窗口外记录、意外输出字段或敏感键。历史记录保留和重复快照 upsert 仍留待未来 App 的统一同步层实现。

评课社区公开查询原型进度（2026-07-22）：

1、已实现只访问 `icourse.club` 公开内容的查询原型，不登录评课社区，不获取受限点评、附件或作者身份，不执行发表点评、点赞等写操作。搜索所需的一次性公开 token 仅驻留内存，不写入缓存或输出。
2、已实现 `scripts/icourse_public_parser.py`、`scripts/icourse_public_client.py` 和 `scripts/icourse_public_query.py`，分别负责公开页面解析、限速网络访问与 24 小时规范化缓存、教务课程分组与规则排序。
3、已实现命令行入口 `scripts/collect_icourse_public.py`，支持 `--course` 手动按课程查询、`--teacher` 手动按教师查询、`--jw-bundle` 自动读取现有教务导入包，以及 `--group-only` 离线检查教务课程分组。
4、课程关联区分教务开课实例和评课社区历史条目。同名课程的不同教师组合不会合并；多位教师共同授课时，完整教师组合是优先匹配和展示单位；网站中已拆分或合并的历史条目保持原样并标注匹配强度。
5、站内课程总评分、难度、作业量、给分和收获统计以及站内 AI 总结优先作为结构化事实来源。原型按用户偏好执行确定性筛选和排序，并抽取最新、赞同较多及观点冲突的代表性公开点评；点评正文统一标记为不可信外部文本，供未来 LLM 解释时隔离处理。
6、缓存默认写入 `tmp/icourse-cache/`，只保存规范化公开数据，24 小时后刷新。网络故障时允许返回带 `stale=true` 的旧缓存；解析失败不会覆盖旧缓存；缓存采用临时文件后原子替换。
7、已新增评课社区搜索、课程和教师脱敏 HTML 样例，以及解析器、客户端、关联排序和 CLI 测试。公开页面真实验收覆盖课程查询和教师查询；教师名搜索只返回课程页的实际情况已通过“课程页教师链接二次解析”兼容。
8、当前教务导入包离线分组结果为 242 个日程事件中识别 235 个课程事件，聚合为 13 个开课实例，忽略 7 个考试事件，其中 3 个实例包含多位教师。分组输出不包含 `userId`。
9、未来 App 接入时由统一服务按需触发查询并读取缓存；LLM 只负责基于结构化统计和代表性证据生成解释，不直接决定条目身份，也不把点评中的指令当作可信指令执行。
