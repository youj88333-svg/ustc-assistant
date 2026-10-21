# A7 MuMu每日同步、审批与竖屏续验

2026-10-21，范围见[唯一任务单](../plan.md#a7-mumu每日同步审批与竖屏收口2026-10-21)。沿用07普通WebView、09来源/事务与许可、10–12产品与状态契约、13风险、14审查及15工作流，当前QA4011和既存MuMu为依赖。用户授权根使用已保存凭据与computer-use验证、修复和覆盖升级；只读学校、来源完整性、当前审批和数据保留继续有效。实机、鸿蒙及A7/A8均不因本切关闭。

## 真实每日链路：失败与成功分开

每日同步原已启用，启动时因历史needsLogin暂停，尚无成功覆盖。根未切换开关、改时钟或写数据库重置预算；通过每日面板“立即同步”显式启动本次可见流程，使用2026-10-20至11-19的31日滚动窗口，而非手动选中的9月范围。

| 北京时间 | 实际动作与结果 | 证据边界 |
|---|---|---|
| 08:14:13→08:15:44 | 立即同步打开学校窗口，页面白屏；根点击“返回应用”后作业仍运行，最终在login/waitingForSchool以timedOut暂停 | 只确认90秒登录准备超时；没有采集或提交。没有原始学校响应、页面内部状态或网络证据，不能唯一归因为学校、提供方或应用 |
| 08:16导出 | 系统保存界面使应用真正进入后台，原交互式每日作业被撤销/排空，daily记录failure和15分钟退避 | 返回应用与真正退后台不同；此次导出引起的取消不能记成自主登录循环或静默成功 |
| 08:17:08→08:17:22 | 根只再点一次“立即同步”，自动完成login、collecting、committing，来源idle/committed计数0，daily committed | 无补输密码、学校授权或登录后导航；这是显式恢复路径成功，不能替代次日06:00自动准入 |

成功后面板显示上次成功2026-10-21 08:17、下次自动尝试2026-10-22 06:00，固定滚动窗口保持。daily安全计数1来自持久的当日自动尝试计数，显式“立即同步”不消耗该预算；它不是日程数，也不代表本日只启动过一次。本次来源规范化计数为0，不记非空导入。之前记录18已独立取得9月2条非空同步，未用该结果推断当前窗口应有活动。

Luna/max先只读审查每日协调器：学校Activity仅覆盖Flutter时的inactive不取消作业，真正后台才暂停；needsLogin停止自动重复和显式恢复符合现有契约。本轮没有在缺少反例时修改每日生产逻辑。原第一次白屏保留，不以一次成功宣称长期网络/挑战已修复。

## 真实审批与撤销缺陷

根保持既有按类别许可与非“仅建议”设置，发送明确测试请求`add task a7`。实际模型查询后准备提案，界面显示当前新任务a7及同意/拒绝按钮；根仅批准这张测试卡，08:28:10提交，08:28:11终答成功，没有选择记住权限。该证据为当前横屏实例的真实审批与创建，不代表尚未观察的手机竖屏。

随后发送`undo`，实际模型连续五次给无参数propose_undo附加changes，五次均按unknownField/changes拒绝，08:29:33以invalidInput结束，没有准备撤销卡或发生撤销提交。原a7测试任务保留，待修订版通过当前撤销卡清理；没有读取正式数据库或处理其它用户任务。

安全导出12还暴露独立诊断问题：本轮工具集已有20项，而上下文诊断写入/解码的旧范围仍为0–19，因此10条上下文事件被计作invalid，导出complete=false。工具拒绝事件仍存在，不能把invalid误当作未知学校异常，也不清零或补造已经丢失的事件。

Sol先补红例，再调整propose_undo说明和编译期纠错反馈：明确arguments只传空对象`{}`，附带expected_arguments，不接受或回显未知字段内容。Luna/max在独立诊断文件把两侧上限绑定封闭DiagnosticTool词表的实际长度；20可写/可读，21及未知字段仍拒绝。审批、撤销槽、许可、事务和出站规则均保留，没有放行任意参数或自动批准。

## 合成回归

所有自动检查仅用合成/loopback/临时资料，不访问真实学校、模型、MuMu正式数据或认证资产。报告保存在被Git忽略的app/build/a7-mumu-followup/reports及app/build/qa4012/reports。

- 初次聚焦检查误填不存在的calendar_week_view_test.dart，121通过/1载入失败；更正为实际portrait_week_test.dart后125项通过。保留原报告，不记产品失败。
- 原撤销反馈红例3项失败；原诊断上限红例12通过/2失败。修复后相关完整文件45项通过，覆盖错误参数、明确纠错、再次调用、当前审批的拒绝/批准和真实临时C3提交，以及日志范围/完整性和未知字段拒绝。
- 根analyze无问题，全套Dart1570通过/1平台跳过；Windows Agent五组通过，包含拒绝、原子提交、组撤销及重启当前卡绑定。Windows只在本次进程启用并还原USTC_NOTIFICATION_TEST_HOST=1，正式1.00资产未替换。
- 独立API34的Android Agent两组及手机界面一组通过，分别60秒和19秒；只用自有AVD、ADB5038及合成临时身份，不操作MuMu或原有资料。最初嵌套启动包装器等待输出未进入用例，根停止该包装器；随后的首次A3缺少实例而前置拒绝，报告保留。改为独立启动后实际执行上述三组，结束正常停止该AVD及专用服务；未因脚本问题修改应用或重置模拟器。没有重跑无关来源原生全套，不把前轮计数混入本轮。

## 主动安全导出

根通过应用按钮和系统保存界面写入既有MuMu共享文件夹，观察导出成功，再只读核对固定安全结构；原样副本保存在忽略的app/build/a7-mumu-followup/reports/live，哈希一致，不入Git。

| 文件 | bytes / 保留事件 | SHA-256 | 完整性 |
|---|---|---|---|
| USTC-Assistant-diagnostics (10).json | 214203 / 575 | `e56233d9f7bbc09967759edb2ceb56a987ace80199ba87c52cd30c3478eb72b0` | complete=true，dropped=0，invalid=0，无截断；导出UTC00:16:09 |
| USTC-Assistant-diagnostics (11).json | 221780 / 595 | `4a781bebb3a9d9fbc93d37d3e340e82575fb707c16b577b45954e16e24cf48d0` | complete=true，dropped=0，invalid=0，无截断；导出UTC00:17:57 |
| USTC-Assistant-diagnostics (12).json | 241077 / 640 | `008eba3f89e10d9db856d93a4ab068ebad1318475cf0c2f90f6e66dd6132488c` | complete=false，dropped=0，invalid=10；导出UTC00:30:12，原缺失明确保留 |
| USTC-Assistant-diagnostics (13).json | 254984 / 672 | `83f8ae7939ce906398bf3022f80695f0c67f40aa2311bc9598ae015c5355108b` | complete=true，dropped=0，invalid=0，无截断；导出UTC00:59:28，运行修订3cdd557 |
| USTC-Assistant-diagnostics (14).json | 268892 / 704 | `0c17c56be2cc0c7c4925cb6fe46f3b61ba8f2a32d97e3cc8c30b72d994ea92d6` | complete=true，dropped=0，invalid=0；导出UTC01:21:35，运行修订60a42cd/prompt-v13 |
| USTC-Assistant-diagnostics (15).json | 290702 / 755 | `187c1d676ab93f4672c90283e610534077bf730ec38e3bed7d98aa6feb1eb154` | complete=true，dropped=0，invalid=0，无截断；导出UTC01:47:15，运行修订cfec38f/prompt-v14/registry-v7 |

前三份运行修订均为885b41e（QA4011），第13份来自QA4012，第14份来自QA4013，第15份来自QA4014。根只消费固定事件/原因/计数/耗时及上下文封闭元数据，不读Key、密码、认证资产、消息正文、工具原始参数、学校响应或正式业务表。构建时manifest不被后来真实结果回写。

## QA4012私有升级交付

工程检查点为3cdd5574f6f5f83106dbb4d247cb234e699d1dd7，普通入口lib/main.dart，包名cn.ustcassistant.mobile.qa，版本名1.0.0-qa-a7-webview2。沿用QA证书SHA-256 `16d3f9867f0a15d4d4ffc877bdd9ec240e92a3fddf6a0a66da857e2888846036`，只递增版本号，不卸载清数据；ARM64未运行，不代表目标机通过。

| 文件（忽略的app/build/qa4012/artifacts） | bytes | SHA-256 |
|---|---:|---|
| USTC-Assistant-Android-QA4012-x86_64.apk | 290992398 | `8b143610e4b8c77b8c446dce596c1e007b626ca2e5e1b6d3cf7a3f64dcbc48e6` |
| USTC-Assistant-Android-QA2012-arm64-v8a.apk | 279218535 | `a8c1fb289dbd7a444449b2d66520ece9823d735522a8346824208862b15e483b` |

x86_64构建22.0秒，ARM64构建63.1秒；AndroidTest、lint与Release manifest检查通过。初次包核验脚本含无BOM中文常量，被Windows PowerShell错误解析，尚未开始核验即拒绝；根改用ASCII编译符号并通过解析检查，复用已完成的x86_64构建，再实际核对两包的版本/签名、唯一ABI、源码修订、普通入口、固定Young/JW脚本hash、persona/reasoning策略、新撤销反馈标记、239233841字节ASR模型与许可，并排除已知integration/gallery入口。没有为核验脚本故障改动应用或伪报第一次成功。

两包manifest在构建时均记publicRelease=false、realSchoolValidated=false，后续真实UI另行记录。根复核旧QA4011/2011大小和hash与记录18相同，旧包、Windows1.00与原用户资料继续保留；SDK、缓存、AVD及本轮报告/临时在E盘，不推送或公开发布。

## QA4012真实撤销仍失败与系统层修订

根通过文件资源管理器的既有APK关联覆盖准确x86_64/4012包，随后从MuMu应用图标启动。旧聊天、a7创建回执及失败undo消息均保留；未清会话、Key、密码、许可或日程。再次发送`undo`，三次实际工具执行仍以unknownField/changes拒绝，没有当前卡或提交。第13份安全导出确认运行修订3cdd557；最终新模型请求结束后直接invalidInput，与第四次同签名调用在执行前被原重复上限拦截吻合，但日志未保存原参数，不能独立证明第四次值。

同一导出中的agentContextCompacted/Assembled已实际保留availableTools=20，invalid=0、complete=true，诊断修复成立。重启后计数按进程重新开始，不意味着原第12份的10条缺失已恢复，也不把新版撤销失败覆盖为成功。

Sol与Astra/high只读复核schema、真实gateway序列化/SSE、严格parser、tool结果及下一请求：未发现应用植入changes或过滤expected_arguments/repair；本次纠错上下文无trim，仍有四次组装记录。不能仅凭现象宣称模型不听或服务端解析器故障。发现system笼统要求“多个本地变化合并为changes”，缺少撤销的明确区分，是需要修正的应用提示歧义。

Sol把changes明确限定到propose_local_changes，声明propose_undo精确空对象及invalidRequest未执行；仅在当前undo参数校验错误后，下一请求首条system追加由编译代码生成的固定短修正，计入同一上下文预算。正常结果恢复基础system，新run重新初始化，提示不落历史、不进入摘要、不引用任意payload或旧参数，不裁剪固定工具、强制toolChoice、忽略参数或授予许可。Astra/high独立只读检查未发现状态泄漏、越权或预算遗漏，未代替根运行测试。

Luna/max复用原临时C3 rig补真实127.0.0.1 HTTP/SSE旅程，逐轮核对生产20工具、空object schema及changes只属于local_changes；模拟服务先分片返回错误参数，再确认完整错误回执/匹配ID/历史参数未被改写及当前固定短修正，之后分片返回空对象才进入审批，批准/拒绝分别验证撤销或任务保留。该组合不是实际模型的纠错保证。新增提示测试首次因新helper未实施而载入失败，报告保留；实现后提示8项及相关旅程合计19项通过。后续全套与真实复验另记，不因测试脚本主动纠正就宣布已修复真实问题。

系统修订根analyze无问题、全套Dart1574通过/1平台跳过，Windows Agent五组通过，API34 Android Agent两组通过（11秒），独立实例及ADB5038正常停止。手机UI生产代码没有改变，QA4012的A4一组及125项聚焦证据沿用，未把旧计数算作新一轮原生执行。工程保存为60a42cd3992efeaab286e7df1666257a611e9a26，未推送。

## QA4013私有包

普通入口、包名、版本名及签名证书沿用上节；prompt修订为ustc-personal-maid-agent-v13，已核对编译期短修正符号，旧消息和晨报不改写。构建仍使用E盘进程环境与缓存，不接触Windows1.00交付。

| 文件（忽略的app/build/qa4013/artifacts） | bytes | SHA-256 |
|---|---:|---|
| USTC-Assistant-Android-QA4013-x86_64.apk | 290996352 | `ea135b9eeeac0d100b0b3b8b4fdfe861a24f22fd73aecb12e1d70918f2f049f1` |
| USTC-Assistant-Android-QA2013-arm64-v8a.apk | 279220519 | `b7f5cc7fc18fe6a0d7b723b65d5ad40e7fe3a41ae6589099d663cbef1c814e2e` |

x86_64构建28.9秒，ARM64构建99.9秒；AndroidTest/lint/Release manifest及两包身份、签名、ABI、准确脚本/模型/许可、普通入口与源码修订核验通过。构建manifest保持publicRelease=false、realSchoolValidated=false，ARM64未运行。根复核保留Windows1.00 ZIP仍为185117053字节、hash `76af4056e026743d8966a212a5288a2a6234423774560f611a168ddea0417e96`，没有替换正式Windows目录。

## QA4013仍失败与非空参数契约

根覆盖准确QA4013后仍发同一句undo。第14份日志确认60a42cd、prompt-v13：09:20:13–17三次实际工具执行仍以unknownField/changes拒绝，09:20:19以invalidInput结束，没有审批或撤销提交。根不再继续叠加空参数提示，也不把模型自述当成服务端解析器证据。第13/14份重启只有历史每日状态committed投影，没有新每日来源作业；与面板仍显示08:17成功、下次次日06:00一致，重启去重已有有限真实证据。

Sol采用最小内部参数兼容修订：propose_undo的参数改为必填且仅有`{"scope":"latest_local_change"}`，用现有string单值enum，不引入JSON Schema const。严格校验发生在读取当前撤销槽和准备方案之前；空对象、错误类型/值、额外字段与重复JSON键均拒绝，不删除或规范化任意模型参数。当前撤销槽、C3意图、20工具名/许可与审批不变，不新增业务范围或DB迁移；registry升v7、prompt升v14。历史v6调用/结果、toolReady与Key保留，不因协议改动要求清聊天或重新输入凭据。

[vLLM工具调用说明](https://docs.vllm.ai/en/stable/features/tool_calling/)区分schema约束与仅解析模型输出，[DeepSeek工具文档](https://api-docs.deepseek.com/guides/tool_calls/)也把strict列为额外模式；支持工具调用不等于应用可以省略本地参数检查。这里没有确认学校采用哪个框架或开启strict，不修改其部署、强制工具选择或依赖未验证的严格模式。显式常量只是本应用对空参数调用持续失败的兼容策略，真实效果仍须实测。

Astra/high只读确认registry不作为旧历史解码或已保存capability门槛，常量不参与授权/目标解析，撤销业务指纹仍取自当前UndoCalendarWrite；原重复守卫保留。Luna/max仅更新同一HTTP旅程，预置自有memory中v6空参数调用与v6结果，三个真实出站请求均核对历史参数及结果JSON/version原样不改；当前请求必须用新scope。根聚焦38项及HTTP/上下文11项通过，analyze无问题、全套Dart1575通过/1平台跳过。模拟服务通过不代表真实服务已接受新schema或旧历史，后续另验。

根补跑Windows Agent与M6各五组，全部通过，涵盖新参数下当前卡、原子提交/撤销、提醒规则与原生临时存储/假系统队列联动；仅Debug进程启用并恢复USTC_NOTIFICATION_TEST_HOST=1。这一修订未改Kotlin、平台启动/数据库或UI，未重复运行不覆盖新scope的旧Android A3用例；QA4013原生两组与QA4012 UI一组保留为对应版本证据，当前Android效果须由下面真实包验证。工程检查点cfec38f99344d3ade88cdc05dcb2a1cb94cfdfbf，未推送。

## QA4014私有包

普通入口lib/main.dart、原QA包名/签名及版本名保留，版本号x86_64/4014，registry-v7、prompt-v14，未清聊天、Key、许可或学校资料。根执行AndroidTest、lint、Release manifest及普通入口/源码修订/资源/许可/脚本/ABI/签名核验，x86_64构建52.2秒；构建manifest仍记publicRelease=false、realSchoolValidated=false。

| 文件（忽略的app/build/qa4014/artifacts） | bytes | SHA-256 |
|---|---:|---|
| USTC-Assistant-Android-QA4014-x86_64.apk | 290997551 | `77ba68439bf3d52383127d75f2a673078b3a4942bd5daf360463b38d7e51b541` |
| USTC-Assistant-Android-QA2014-arm64-v8a.apk | 279221075 | `65312c66deeeaa7d9f32f08fbeb7b8f9b79850ec2b712ed6e59246b15045d616` |

本轮先交付x86_64到既有MuMu实测，取得当前审批后再生成ARM64；两类证据分开记录。旧QA4011–4013及ARM64包、Windows1.00交付保留。

ARM64/2014普通入口构建62.8秒，同源码/签名、唯一ABI、准确脚本与模型/许可、编译的registry-v7/prompt-v14/scope及排除测试入口的核验通过，未安装或运行。最初受限进程的ARM包装器停留在空构建输出，根中止后在获准访问E盘SDK/缓存的进程重试；不把中断当构建通过。Java的JAVA_TOOL_OPTIONS提示被Windows PowerShell重定向标为NativeCommandError，但最终Flutter退出0、APK生成及独立核验均成功；按实际退出/产物判定，没有因此改TLS、代理或系统环境。两包构建manifest均保持publicRelease=false、realSchoolValidated=false。

## QA4014真实审批、拒绝与撤销闭环

根通过同一APK关联覆盖QA4014，旧聊天、a7任务、学校密码、Key与许可保留。继续发送同一句`undo`，09:38:35出现当前撤销卡，未再触发unknownField/changes。根09:42:31点击拒绝；安全事件749–750为rejected，没有撤销提交，模型随后读取测试任务仍存在。09:43:05运行正常结束，再发送同一句undo，09:44:37重新出现当前卡。

根09:45:07仅批准这张新的测试撤销卡，事件769–770分别为当前批准和committed；09:45:18运行正常结束，后续任务读取为空。根再通过日程→任务核对，当前未完成任务为0，a7不再显示，撤销最近修改按钮禁用。只撤销本轮测试创建，没有处理旧任务、来源日程或用户覆盖；两次均未勾选“以后不再确认”。

真实竖屏中当前卡显示在输入区上方，批准/拒绝可达。完成后“处理详情”默认收起，根实际展开查看已提交回执，再收起恢复正文；历史卡没有可提交按钮。本实例没有出现窄屏审批弹层，不能把内联卡的可达或已完成详情的折叠记成手机弹层关闭/重开的真人验证；该分支及键盘/长卡仍沿用对应合成证据，目标手机继续待验。

第15份安全导出确认revision=cfec38f、registry-v7、prompt-v14，755条保留事件、complete=true、invalid/dropped均0，无截断。两次当前审批和一次提交均有封闭日志，原错误与旧聊天未清除；本次服务成功不证明每段旧v6历史都实际发出，历史原文不改写的出站保证来自前述HTTP旅程。第二次请求的预整理09:44:30出现protocol失败，随后按既有回退保留可用上下文并成功完成审批/撤销；不能将整个日志称为没有失败，也不凭该封闭原因推断模型原始输出或唯一服务端根因。

QA4014启动仅投影历史youngDailySyncState/committed（事件737），没有新来源作业。根09:47再核对每日成功仍为08:17、下次2026-10-22 06:00，09:49核对手动日期仍为2026-09-01至09-30、密码框为空；没有点击新同步。导出后应用正常恢复，最终回到默认Agent页，无待批卡或正在执行的测试。实际模型返回的思考面板能显示并收起，但根没有复制、持久化或把思考自述当作协议证据；也不据此对全部模型评分。

## 竖屏真实复验与剩余验收

最初computer-use打开MuMu窗口管理的Qt子菜单后，输入使子菜单失焦，未能可靠旋转；没有修改模拟器分辨率、机型或系统设置。用户后来明确回复“已切换”，根重新选择窗口后取得真实竖屏：周表同时显示周一至周日七列，不需左右拖动；点日期可打开完整条目列表，关闭后恢复周表；任务入口可达，唯一a7测试任务仍在，旧失败没有误删除。仅核验显示及交互，不复制课程明细或宣称业务对应正确。根09:29–30再核对每日开关仍启用、08:17成功和次日06:00，以及手动2026-09-01至09-30仍保留；没有额外同步或更改偏好。界面未发现需修复的问题，未因测试调整产品样式。

这些是当前MuMu的有限竖屏证据；根在最终QA4014又核对七列同时可见和任务撤销结果。320/360/412dp、窄屏审批弹层与极大字号回退仍来自既有合成检查，不外推所有手机。当前内联审批的真实拒绝/批准及已完成详情折叠见上节。

次日06:00自动准入、长期每日网络/挑战、真实业务明细对应、目标手机/鸿蒙、实际通知/麦克风和原未观察项继续保留，A7/A8开放。

## 收口检查

根核对最终Dart报告为1575通过/1平台跳过、analyze无问题，Windows Agent/M6两份报告各五组；QA4014与QA2014包核验完成。文档导航、状态、风险、设备矩阵及当前QA说明已更新，执行`powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-docs.ps1`和`git diff --check`通过。本地工程与文档分开提交，临时脚本、包和安全日志均不入Git；未推送、未公开发布、未修改Windows1.00交付。所有SDK/缓存/临时目录沿用E盘进程环境，未更改全局设置。
