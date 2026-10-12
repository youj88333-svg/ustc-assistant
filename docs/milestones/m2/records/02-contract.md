# M2.2 真实契约与主动验证记录

> 保留发生时的规格、失败、修复和检查；旧“待验/未关闭”不是当前状态。当前范围见 [任务单](../plan.md)，最终结论见 [验收](../acceptance.md)。正文只迁移链接，保留当时叙述。

#### M2.2 内置浏览器真实调研与契约具体化（2026-10-11）

用户选择改用 Codex 内置浏览器，并本人完成学校登录；根使用 computer-use 技能在该独立标签页内继续已授权的只读探索。Edge 控制无响应的原记录保留，未修改其宿主、代理或配置。浏览器在后台操作，不接管用户桌面输入；没有报名、退选、签到、新建日程或修改个人资料。

本轮已核实以下真实业务证据，只保存字段、类型、计数和判断，不保存账号、业务 ID、具体日程日期/标题/地点、原文或认证资产：

- “我的信息”的服务端 profile 为 `success=true/code=200/result object`，必要账号字段 `username` 与页面明确标注的学号私下比较一致；`loginCode` 及候选内部用户 ID 字段不存在。固定本人查询前后 `username` 稳定。此证据确定字段语义，不替代应用 C3 预期账号与作业内的实际判定。
- 用户说明个人日历没有自建日程，9 月中旬有活动。按该线索找到一条非空记录：`id/title/place/startTime/endTime/itemId/userId` 均为 string，服务器时间为 `YYYY-MM-DD HH:mm:ss`，页面显示到分钟；日期与所选日一致且结束晚于开始。固定活动详情的 id、名称及起止时间与该记录关联一致。`userId` 尚无内部 ID 映射，不和 `username` 强行比较。
- “我的日程”确有新增日程能力，公开子组件没有活动关联输入。没有 `itemId` 的记录只能称为未关联活动记录，不能凭此断言全部是自建。详情的 `applyStatus` 属项目条件，尚未证明本人报名成功或取消状态。以活动关联日程为准还是继续独立核验报名状态，已交用户作范围决策；依赖此选择的正式同步许可暂不启用。
- 报名列表的必要字段为 `id/itemName/st/et`，实际起止时间同为本地秒级文本；`applySt/applyEt` 是报名时间，可能为 null，不能当活动起止时间。正常 UI 当前每页 10 条；不同时刻总量为 80 和 74，后者已再次与学校 UI 核对，不把跨作业变化写成分页故障。
- 固定页面 API 模块 `0fea.e` 是 GET helper，参数由应用构造；活动标准参数为 `field="id,,action",pageNo,pageSize=10`，日程标准 field 为 `id,,number,title,place,startTime,endTime`，另含 `now`。双逗号是当前公开组件的实际拼接结果。活动第一、二页各 10 条、页间 ID 不重叠，第一页与 UI 行键逐项一致。但服务器两页均回显 `current=1/size=10/pages=8`，不能强制这些字段作为可信分页依据。以请求页号/页大小和服务端 `records/total` 验证数量、总量稳定、唯一 ID 和末页长度；完整八页仍在本轮核查，未提前记通过。

**关联路线实证及技术选择**：普通 Network initiator 没有固定 helper 发起脚本的异步父链；仅 sourceURL、frame/loader 或时间窗口不足以归属主动步骤。临时启用 Debugger 并设置异步栈深度 32 后，一次真实 GET 的父链包含 `Debugger.scriptParsed` 登记的同一步 scriptId；旧请求不含该标识。生产准备采用当前默认 uniqueContextId、逐步唯一非秘密标记所登记的 scriptId/context/document/operation/step 与完整 initiator 链共同核验，保持固定 GET、主 frame/loader、起点、非缓存/非 SW/非重定向和正文复验。标记文本本身不授予许可，缺链、歧义、超限或迟到均拒绝；不读取或解密不透明 requestParams，不全局替换 XHR/fetch，不读取令牌。IAB 调研成功不代表产品原生关联已验收。

本轮失败如实保留：一次四个并发正文读取使控制工具超时并重置，改为最多三个独立读取；无游标读取未取得历史响应，后续按操作前游标读取；首个新活动请求核查误按无业务根前缀的 pathname 匹配，得到零匹配，随后以固定后缀校正并核对四个实际 GET。开启调试前没有脚本链的检查为未通过，开启后新请求才通过。未把这些工具/匹配失败解释为学校响应契约失败。

#### M2.2 下一实现切片：私有业务解码与分页规则

**设计依据**：`docs/README.md` → 07 只读/凭据/数据连续性及首版普通 WebView、08 两来源分离和依赖、09 K-01/K-03/K-04、10 文档/作业失效与收口、11 安全投影、12 职责、13 V-01/03 与本文件 M2 范围。当前实证仅定义候选业务字段和必要解析，不创建 Young 生产许可，不改变正式 Schema、JW 凭据用途、已有日程或分区。

限定 Luna / max 在新 `app/lib/source/young_business_contract.dart` 与对应合成测试实现私有、不可直接序列化到 UI 的 profile、活动、日历必要字段解码、严格北京时间秒级解析和顺序页完整性累积器。profile 只解码 username；活动只解码 id/itemName/st/et 及必要可空报名时间/地点；日历只解码 id/title/place/startTime/endTime/可空 itemId。未知字段不纳入模型，不以未知值构造身份。缺少/非法必要字段、失败响应、非法日期/非正时间区间、有界上限违规均拒绝；未关联活动的日历行保留为此类别，不预先作报名结论。

累积器只接受来源构造的连续页号和固定 10 条页大小，以 records/total 验证：有界非负整数总量在一次查询内稳定；除末页外满页，末页长度与余数一致；逐行验证且 ID 全程唯一，累计数恰好总量才完成。第一页 total=0 且零行是该查询的完整空态；早空、短页不足、重复页/ID、总量变化、乱序或完成后追加均失败。current/size/pages 回显不作许可依据。安全统计只含类型/计数/固定原因，不返回原文、值或哈希；测试只使用合成数据，不访问学校。

Sol / max 负责后续固定动作的默认 context/scriptId/step 关联、原生必要正文投影和协调器集成；接口定稿后再派独立 UI 小块。根独立运行相关 analyze/test 和原生关联反例；只有原生链和真实候选验证成立，才继续 C3 封存/许可、查询及导入。用户待决范围只阻止依赖该语义的正式日程同步，不阻止身份、分页及时间规则实现。此切片和本轮调研不能关闭 M2，M0/M1 关闭、418 条教务事实、非空 JW 考试后补均保留。

**本轮后续真实核查**：一次新的活动查询在第一页返回 total=69；前七页分别为 10/10/10/10/10/10/9，total 全程 69、69 个 ID 全部唯一，名称与活动起止必要字段均有效。该作业前后 profile 稳定，所有请求均为当前主 frame/loader 的 GET，HTTP 200 JSON、非缓存/非 SW，initiator 完整父链包含本轮已登记 scriptId，事件缓冲未截断。调研按较早总量固定再请求第八页，返回 success=false/result=null；该页已经超出本次总量计算的范围，不能当合法空页，也不能覆盖前七页的独立完整查询结论。正式实现必须从本次第一页 total 计算页数并在完成后停止，不硬编码八页。69、此前 74 和 80 是不同作业的实际总量，不夸称学校数据一直不变。

个人日程采用公开组件实际 field、固定 now/pageNo=1/pageSize=10，分别读取已有非空日和相邻空日：前者 success=true/code=200、1 行/total=1，日期符合本次输入、秒级时间与活动关联有效；后者同一成功形状、零行/total=0。前后 profile 稳定，四个真实 GET 均具当前主文档和登记脚本关联，无缓存/SW，事件未截断。日期归属依赖已核实的固定调用管线，空数组自身没有服务器日期回显；本轮没有区间请求、多页单日或跨日样本，不将这两个样本记成整月/整学期同步验收。身份内部 ID 映射及本人独立报名状态仍未证明，已登记的范围问题仍待用户选择。

**私有解码实现与根检查**：Luna / max 仅新增 `source/young_business_contract.dart` 和对应合成测试。模型保留必要业务字段、无 JSON 序列化或业务值摘要；严格北京时间解析和分页累积器已实现，完成前/失败后不交完整记录。根实码复核发现一条测试把合法的最小 profile 信封误列为拒绝，交回限定代理修正；同时将成功判定明确为 bool true。第一次根 analyze 报三处代码风格问题，根改为私有重定向构造和字符串插值；没有改变业务契约。

根最终实际执行 `dart format` 两文件、`flutter analyze --no-pub`（exit 0，零问题）、`flutter test test/source/young_business_contract_test.dart --no-pub --reporter expanded`（exit 0，21 项合成测试通过）。覆盖恒定 current 回显、实际页号/总量/末页长度、重复与变化/乱序/完成后追加、失败终结、私有不可变结果、必填/可空字段、报名时间区别、闰日及 UTC+8。测试不访问学校或正式业务库。新模块尚未装配到产品采集端口；本切没有重跑全量测试、Windows 集成或 Release 构建，不把前轮 352 项/17 组的结果冒充本轮检查，没有替换 PID 37876 的运行应用。

本轮调研的业务响应与身份实际值仅临时在内存私下比较，使用后释放；没有写个人值、原文、HAR、学校截图或认证资产。临时 Debugger 异步栈设置在调研结束时撤回，Debugger/Network 观测停用，正常重载清除本轮临时 API 模块入口；随后 DOM 复核日历仍可见、密码框为零，并标记保留标签页供下一步只读验证。下一实现依赖为原生固定动作与步骤关联、候选身份/完整读取面板，再接入独立查询及用户确认范围的事务导入；M2 和两个生产能力仍开放。

本轮文档检查通过：17 份当前文档的 200 处本地链接、56 处锚点有效，07–15 九份历史正文与 HEAD 换行归一内容相同，01–06 无差异，`git diff --check` 通过。没有提交或推送。

#### M2 活动关联范围确认与主动读取切片（2026-10-11）

用户明确批准“以活动关联日程为准，排除未关联记录”。继续本任务：学校个人日历中存在非空 itemId 的记录作为日程同步依据，未关联记录排除；不宣称已独立证明本人报名成功/取消状态。此前等待范围选择是当时状态，现已解除。活动只读查询与个人日程同步仍分别完成和验收，不复用 JW 凭据。

**设计依据**：从 `docs/README.md` 导航至 07 的只读/凭据/连续性与普通 WebView 边界、08 两能力分离、09 K-01–05、10 当前文档/作业及收口、11 安全结果投影、12 职责、13 V-01/03 和本文件工作流、M2 验收条件。本切先将已实证固定 GET 接入应用内主动候选读取；原生链及真实候选成立后再接 C3 封存/许可、正式查询和事务导入，不以 IAB 或候选计数直接授予生产许可。

**固定接口与不变量**：当前 Young 默认主 frame 的 Runtime 数值 contextId/uniqueId 与 frame/loader、session/document/operation 绑定。每一步使用固定模块 0fea.e、固定 GET 路径及闭合参数，验证实际 helper 签名；不读取页面令牌、存储、interceptor 或任意运行时模块。拟以 Runtime.compileScript 返回的确切 scriptId 与 Debugger 当前 context 登记交叉核验，Runtime.runScript 执行该已编译脚本；仅 sourceURL 文本不授权。异步 initiator 链须含此已授权 scriptId，请求再经过起点/端点/GET/frame/loader/非缓存/非 SW/非重定向检查。可信必要正文只由原生 CDP 投影，页面 helper 返回值不作服务器证据。每步 Promise 闭包只保留 pending/done/failure，短 RPC 不 awaitPromise；只有 helper 完成及唯一关联正文通过才完成该步。没有完整链、歧义或异常均失败，不退回时间窗口。

profile-before → 本次完整活动页或逐日完整日历页 → profile-after；前后身份与本次私有预期账号一致且当前文档仍有效才交候选完整集合。活动按第一页 total 停止，日历每一天页号从 1 开始；先完整检查全部行和页再过滤无关联记录，日期覆盖明确且有界，不把最后空响应当完整范围。新导航/页内路由/context 销毁、取消或关闭即时撤销操作及所有未交付值；未完成停止转正常浏览器关闭/真排空，不因短 CDP 回执释放全局租约，closing 后不 poll/releaseObject/disable 新域。SDK 信封和未知正文仍借用跨度跳过，只有有界必要平台标识/业务字段解码，app-owned 临时缓冲擦除。

**分工与修改边界**：Sol / max 负责主动原生 reader、共享桥/端口/协调器、规格和实际集成；Luna / max 限定扩展必要跨度投影/合成反例，再按冻结接口承接独立候选 DTO/面板；Astra / high 只读复核具体关联和排空方案。仅修改新 app/ 及当前文档入口，本切不升级正式库、不改 JW 凭据用途或既有 418 条日程。所有 SDK 检查由主代理串行执行，测试仅合成/loopback，不访问学校。

**完成条件**：原生合成证明确切编译脚本进入异步父链、同 URL 背景/旧步骤/伪标记不能满足动作、恒定 current 回显仍按实际页完成、空/非空日及过滤正确；覆盖 route/context/取消/关闭、缓存/SW/redirect/缺链/超限/秘密 unknown 字段反例。根 analyze/test/相关 Windows/build 后再由用户在应用二课隔离窗口登录并验证新候选摘要，生产 sourceAvailable 仍 false；正式许可、查询及导入在随后实现，不关闭完整 M2。

**本次实现与复核**：Sol 实现独立 native BusinessReader、闭合五个主动端口、协调器、两个固定页面入口及首页装配；Luna / max 扩展跨度解析和必要字段投影，并承接独立 DTO/UI 与端口/协调器反例。Astra / high 只读复核提出的 context 到达顺序、无关 frame context 销毁及过滤前跨日冲突三项已由根修复：启动 ack 与默认 context 采用双条件汇合；编译返回和登记事件同样汇合且只 run 一次，明确指定已验证的 executionContextId；先检查全部日历记录的 ID/内容一致性再过滤，跨日同 ID 的 itemId 改变仍拒绝。每步交付前先清除私有登记与动作状态；日志/UI 只输出 `young-active-contract-v1` 的闭合阶段、身份结论、失败码和计数。

**Windows 守卫与收口修复**：现有全局 WebView HistoryChanged 不能区分子 frame 导航，实测会误取消 Young 读取。仅在 Young reader 的 Page 监听已订阅、Page.enable 已确认、主 frame 已绑定且 active 时，用 Page.navigatedWithinDocument 的精确 frame 事件替代该模糊守卫；主 frame 命中或 frame 字段非法立即撤销，明确无关 frame 忽略。正常顶层导航、SourceChanged、context、关闭守卫及所有 JW 路径保留。Detach 先恢复全局守卫，再停止协议域；closing 后不新增 CDP。

取消可能落在已有短 CDP 调用尚未回执的阶段。最终关闭顺序为先撤销/解绑/擦除、等待实际在途短调用完成，再由既有原生 drained 轮询推进 Controller.Close，最后继续官方群退出与真清理；不在 completion 内重入关闭，计数在应用侧处理结束后减少。关闭受理不等于排空，Busy 不清零；没有回执时仍超时并保留租约/恢复状态，不用计时器假称已释放。

**集成失败保留**：初轮 analyze 的同名 YoungBusinessPage 冲突及 DTO/UI/测试导入、空值和样式问题分别修复，初版不记零问题；新增 context 纯原生反例首次因缺 vector/utility 头文件构建失败后补齐。第一版较少反例的主动 Windows 流程曾通过，随后加入无关 iframe 反例才暴露 HistoryChanged 误取消，原失败保留。新增历史驱动首次未加入 Dart 的合成 action 白名单，返回 invalidSnapshot，已仅在 fixture 驱动补全；接着立即取消到 recovery/cleanupPending，闭合摘要确定位于 calendar 阶段。第一次等待 Busy 的方案在 completion 中重入关闭，原生测试 32 秒时进程意外退出、未完成；没有取得确切崩溃点，不能记已定位底层崩溃。调整为处理结束后计数、drained 轮询推进后，最新主动原生一组 28 秒通过，包含两页完整活动、非空/空日期覆盖、未关联排除、前后身份、同 URL 背景请求、不稳定 total/重复/秘密/错误日期拒绝、iframe 导航继续、同 URL pushState/replaceState、同文档前进/后退、页面收到 JSON 后路由撤销及立即取消后租约重新取得、临时分区删除。

上述页面正文后路由反例是在学校 helper 的 response.json 完成后触发，不能声称已严格控制 native projection 完成到 Poll 交付之间的时序；精确 Page 事件和方法 completion 的顺序是本机当前运行时实测，未证明所有未来运行时的无条件回调顺序。最终全量检查见下文，真实应用内验证仍待用户登录后进行。

**最终 Windows 回归（根代理实际执行）**：以下八套共 18 组通过，全部使用合成/loopback 和各自临时目录，没有读取正式学校页面、数据库或认证资产。Astra 对最后计数及关闭推进的限定只读复核未发现阻塞性遗漏；不以其声明代替根的实际结果，未逐项控制所有短调用类别的取消时点。

| 原生套件 | 组数 | 实际覆盖 |
|---|---:|---|
| young_business_flow_test | 1 | 确切编译/默认 context/异步父链、完整活动及逐日页、过滤与安全拒绝、frame/route/取消、租约再取得及真清理 |
| young_read_only_flow_test | 1 | 原候选投影、固定 GET/新起点、并发/redirect/缓存/worker/SW/畸形/秘密/额度及停止后返回 |
| young_observation_flow_test | 2 | Young 多站导航/结构、目标不可扩展、共用租约与真实删除 |
| observation_flow_test | 1 | 普通观测控制、文档失效、排空与恢复 |
| auth_redirect_flow_test | 1 | 顶层/iframe 的 HTTPS 表单、HTTP 升级及复杂重定向 |
| jw_authentication_flow_test | 4 | 固定认证与单次投递、文档/节点改变后拒旧认证对象 |
| jw_sync_flow_test | 6 | DPAPI、当前期/目录/预选、持久事务、取消、重复合并、冲突与身份变化零提交 |
| m0_flow_test | 2 | 正式 Windows 双库目录布局重开、应用首页与 M0 闭环 |

第一次用同一 flutter test 命令指定七个 Windows 文件，首套通过，但后六套在加载阶段无法建立调试连接、没有进入测试；该命令整体退出 1。随后各套独立启动、串行运行取得上表结果，不把首次运行器启动失败记为业务反例通过。

**最终本机检查与交付**：根实际串行运行的 `flutter analyze --no-pub` 为 exit 0、零问题；`flutter test --no-pub --reporter expanded` 为 exit 0、400 项通过且 1 个平台反例跳过；上表八套原生 18 组均通过。最后 `flutter build windows --release --no-pub --target=lib/main.dart` 为 exit 0，50.1 秒，正式 `app/build/windows/x64/runner/Release/ustc_assistant_m0.exe` 已生成，整个目录保留。没有用旧轮结果代替本轮重跑，也未提交或推送。

**启动操作失败及纠正**：首次 `Start-Process -WindowStyle Hidden` 得到 PID 18872、窗口句柄 0；根在隔离环境运行进程检查看不到宿主进程，误判并又启动 PID 36992 / 23752。宿主只读进程检查随后证实三者均存活，可见的重复实例为启动失败页；这不是二课契约失败。Computer Use 只在本次返回的 USTC Assistant 窗口检查固定启动标志，点击关闭首次因 coordinate input geometry unavailable 失败，重新观测后 Alt+F4 正常关闭可见重复实例。两个无可见窗口、未供用户操作的本次 PID 在核对确切 exe 路径及句柄后结束，等待退出；没有删除目录、业务库、凭据或登录资料。改用正常应用启动 API 后只保留新版 PID 9716 / 窗口 3280322，固定启动失败标志 false、M1 教务面板及 M2 验证面板 true。未记录首页个人值、截图或学校原文，不把窗口标志当真人功能验收；隐藏启动及隔离检查的误判保留。

已请求用户在应用二课观测窗口本人登录，在固定活动页运行“验证活动查询”，再选择有活动日期段运行“验证日程范围”，分别反馈 `young-active-contract-v1`。应用会完整分页/逐日读取，无需手工反复复制；不复用 IAB 登录资产或 JW 密码，未操作学校认证或业务写。两份真实应用摘要尚未收到，候选 sourceAvailable=false，正式 C3 身份/封存/许可、独立查询展示及本地事务导入继续按同一 M2 任务推进；M0/M1 关闭与既有 JW 事实保留，完整 M2 不关闭。

本切最后文档检查通过：17 份当前文档的 205 处本地链接及 61 处锚点有效，07–15 的 9 份历史正文和 01–06 保持不变，`git diff --check` 通过；后续仅补充本检查文字及当前应用说明，未更改代码，不为文字改动重复运行 SDK。当前工作区既有未提交修改与 untracked app/、verification/ 保留。

#### M2 应用内真实主动验证（2026-10-11）

用户已返回两份 `young-active-contract-v1`：活动 phase=done、identity=candidateMatches、68 条/7 页、identityReads=2；日程 phase=done、identity=candidateMatches、31 天/31 页、calendarRows=2、linkedSchedules=2、excludedSchedules=0、identityReads=2。两者 sourceAvailable=false，终态摘要保留 stage=stopping，表示固定协议域收口完成后的候选状态，不是导入或学校业务写回执。不同作业活动总数从先前 69 变为 68 允许，完整性只要求同一次作业各页稳定。

此证据确认新应用自己的 Young 分区可完成固定主动请求关联、前后预期身份匹配、完整活动分页和所选逐日范围；日程样本非空且全为活动关联。未出现的未关联真实样本/错误形状仍未观察，不由合成反例冒充真人通过。没有写入二课正式事实、C3 许可或导入回执，不关闭完整 M2。根继续同一任务的 M2.3 最小 C3 映射/许可、正式查询及日程事务导入；单账号、既有 JW 418 条记录与凭据/目录、只读学校边界及全局租约保持，分工与实施规格先记于下文。
