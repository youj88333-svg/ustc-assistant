# A7 MuMu连续使用：跳转、审批、竖屏与思考展示

2026-10-18。本切规格见[唯一任务单](../plan.md#a7-mumu连续使用反馈修复与模型思考展示)，继承[普通WebView修订](../../../decisions/android-system-webview-compatibility.md)。Windows1.00、所有业务/凭据及既有MuMu安装保留；整体UI重构延期，不关闭A7/A8。

## 输入与故障证据

用户在MuMu的QA4004上报告：Young同步停留首页；Agent请求“提醒我明天下午两点半坐校车”看不到审批卡；竖屏周视图需要横拖。用户主动在应用导出两份安全日志，并告知位于MuMu共享文件夹。根只读取该目录下固定两份`USTC-Assistant-diagnostics*.json`导出文件的版本与白名单事件，不遍历MuMu私有目录、浏览器资料或业务库；重复导出文件未删除、不入Git。

日志工程修订为`e36ccb58933650e514aad79ab1f60e8038047219`，导出完整、无丢弃/坏行。Young两次作业在login/准备后收口，第二次明确`preparationTimedOut`，没有采集/提交证据。三次`propose_local_changes`均到达`approvalRequested/waitingForApproval`，之后拒绝或用户停止；不把“没看见卡”解释成模型没有准备方案。该日志不含页面路由和读取模块，不能仅凭它确定学校当前页面的精确变化。

代码复核发现两个可复现缺陷：Android在固定业务跳转前要求首页已具有目标GET模块且传输包装完好，然而该模块可以只在目标页延迟加载；C5将当前待批卡放在整个历史列表的prefix，长对话中不在当前输入位置附近。手机周视图硬编码每日160dp，七天超出竖屏画布。

## 实施与实际检查

本节随根实际检查补充，不将计划写作通过。F1只解除首页目标读取模块对固定导航的前置依赖，回调过渡、原生文档代际、目标页helper、真实GET关联、身份/完整性和事务保持；增加首页无helper的合成反例。

F2/F3由Luna/max分别在不重叠的页面/周视图文件内实施。F2两种紧贴输入框的内嵌卡方案未通过：reverse滚动裁掉卡和按钮，固定卡则在320×640/键盘220px时只剩约50px、溢出。根接手采用48dp入口和有界底部阅读面板；新审批到来时手机展开，关闭后入口保留，提交按钮仍绑定唯一当前卡，长详情在面板内滚动。大字和手机横屏键盘补过一次输入区约束回归，不跳过实际命中检查。桌面当前卡靠近输入区，完成卡仍归历史折叠。

F3按手机画布分七列，缩窄时间轴，日期为星期/MM-dd两行；窄列保留标题/教室和冲突标记，日期表头可打开当天完整列表，全天/凌晨与任务也保留列表入口。正常320/360/412dp整周显示；2倍大字的窄屏允许保持最小列宽后滚动，不用无限缩字换零滚动。Luna第一次表头在2倍字溢出8px，调整后通过；根复核并补静态分析提示修正。原测试全局匹配“日”因新增周日产生歧义，现限定真实视图选择器，并保留单任务稳定key。

F4接收兼容API明确返回的`reasoning_content`和`reasoning`字符串增量（新旧字段同时存在不重复拼接），与正文、工具参数及回执分开。依据[vLLM推理输出文档](https://docs.vllm.ai/en/stable/features/reasoning_outputs/)核对两种命名，不增加`enable_thinking`、第三方端点或新工具。单次HTTP推理有128K字符上限，仍受原2MiB SSE总量/64KiB事件等约束；C4最多保留12条、每条32000字符的内存投影，截断有提示。秘密模式命中时省略该条思考，正文继续；清会话/相关配置或私人读取撤销/维护/关闭清理。正文开始后默认收起，可再展开；无推理字段沿用正常生成，不伪造过程。新增底部跟随只在用户仍读最新消息时运行，翻看历史后不会被新片段拉回。

根已执行：analyze无问题，全套Dart **1550通过、1平台跳过**；局部65项协议/协调/审批/思考与后续42项整合界面检查通过。Luna独立日历40项通过，由根全套重新覆盖。根首次Android构建第二步恰遇代理未完成的`maxHeight`参数，失败保留；初次analyze的三条提示均修正，未当作通过。两代理在沙箱内调用Flutter bat曾因SDK缓存锁不可写而无输出，改为授权的E盘工具进程后取得实际测试输出，没有修改SDK或全局环境。报告在忽略的`app/build/android-a0/feedback-*.txt`。

第三项独立只读任务由Luna/max调研前端skill，根核对主要GitHub仓库/实际正文与Flutter规则，结果见[选型研究](../../../research/frontend-skill-selection.md)；没有安装、运行候选脚本或启动整体重构。

Astra按需独立复核F2/F4，确认私人读取策略保存提前更新内存，导致后续refresh不能识别撤销、旧思考未清。根在C3保存成功后按保存前策略直接清理，并用真实合成C3策略路径验证：authority未变也清除思考，正文保留。另补720×360、键盘220px、1.5倍字的审批实际展开/滚动/命中；极矮面板使用整卡滚动，正常竖屏仍保留固定批准/拒绝。首次阈值过宽误让竖屏也进入整卡滚动，命中测试指出后修正；两组相关35项通过。没有扩张权限或持久化思考。

Android12/API32、WebView120.0.6099.193已完成普通路线原生24通过/1历史反例跳过、完整学校合成6通过/1独立smoke分支未选；首页无目标reader仍能完成Young自动认证、固定导航和导入。随后的普通入口检查出现`Status: timeout`，首次未保存launch输出，单独重试取得该证据；不记普通入口通过，继续定位。报告位于忽略的`app/build/android-feedback/reports/ustc_android_a0_api32`，旧记录12报告保留。

后续抓取固定独立AVD的启动日志，未见应用崩溃；`am -W`先在约11秒报告timeout，系统随后在12.001秒明确记录MainActivity `Displayed/Fully drawn`。根增加有界首帧观察、保留原timeout、核验进程存活并实际查看截图，确认进入未配置模型的正常Agent页，没有访问模型/学校。不能用CLI的短等待窗口等同产品崩溃，也不把软件渲染Debug AVD耗时当手机性能结论。最终analyze无问题，全套Dart重跑 **1552通过、1平台跳过**；原1550是补隐私/横屏反例前的检查点。

Windows原生Agent五组、日程/任务四组、Young自动认证三组，合计12组通过。本次进程启用`USTC_NOTIFICATION_TEST_HOST=1`并在finally还原；使用合成资料/loopback，不激活生产通知。工程检查点为`3f70518fca306947d0b20117392a6e0ae3a0f944`；选型文档独立提交`1271369`。没有推送、替换或启动Windows1.00交付。

该工程修订的Android普通入口Debug、AndroidTest、生产Manifest处理及lint再次通过（无Error，既有Warning保留）。固定产物为`app/build/android-feedback/artifacts/USTC-Assistant-Android-A7-QA4005-x86_64.apk`，版本名`1.0.0-qa-a7-webview2`、码4005，290953716字节，SHA256为`67e954747c19893329be146d47d10f56ec97237304c709d42d2519dc824494ff`。签名证书SHA256仍为`16d3f9867f0a15d4d4ffc877bdd9ec240e92a3fddf6a0a66da857e2888846036`；核对包名、单一x86_64 ABI、内核含工程修订且无集成入口、固定语音模型大小及全部随包许可。产物/元数据/签名/hash在同目录保留，测试会使用该固定主入口副本，避免集成编译覆盖交付。旧QA4004、ARM64/2004及Windows1.00继续保留；未向用户MuMu自动安装。

最终固定副本在Android14/API34、WebView113.0.5672.136上完成全套原生 **85通过/8历史高级反例跳过**、学校六组通过/1独立smoke分支未选；Android Agent两组、手机壳/日历任务/文件一组通过。Agent实际经过Android Keystore、loopback SSE和C3，断言模型思考独立展示且后续HTTP请求不包含该哨兵内容。恢复主入口后系统记录6.792秒首帧、进程仍运行，但根查看截图发现SystemUI ANR对话框覆盖Agent；没有将CLI成功等同干净界面。保留`ordinary-main-post-suite-*`截图和启动证据，另在空闲冷启动复验，不覆盖测试通过和此失败事实。

Windows Release实际构建至`app/build/android-feedback/windows-staging/x64/runner/Release`，根先核对绝对路径、无reparse及CMake安装prefix，避免INSTALL清理触及正式目录；未启动此暂存版。正式Windows1.00 ZIP和旧QA4004重新计算SHA256，均与原清单一致。首次API34空闲复验已有正常Agent截图、无SystemUI弹窗，首帧19.729秒；新增窗口焦点断言因误读`dumpsys window windows`子节（API34无全局focus字段）失败，保留该报告，改读完整窗口投影继续验核。此处未猜测系统弹窗的根因，也不将未复现等同稳定性问题清零。

最终API34空闲冷启动通过：系统记录16.956秒首帧，原`am -W`超时仍保留；完整窗口投影的`mCurrentFocus/mFocusedApp`均为本QA MainActivity，根查看最终截图确认正常Agent页、没有系统弹窗。两次空闲正常截图与压测后SystemUI ANR一并保留，当前没有目标手机性能结论。根最终核对原生summary、各集成结束行、APK元数据和截图；所有本轮官方AVD已停止。仅在确认无对应执行进程、绝对路径白名单、无reparse和可独占打开后删除API32/34新生成的`ram.img`临时镜像，保留虚拟用户数据盘、SDK/模型、产物和报告；不以逻辑长度推算物理回收，不操作C盘或MuMu资产。清理证明为`reports/temporary-ram-cleanup.json`。

根检查使用以下现行入口；各命令输出和启动失败保留在忽略的`app/build/android-feedback`及`app/build/android-a0/feedback-*.txt`。

- `tools/android-a0.ps1`分别使用`-Action Analyze`、`-Action DartTest`及`-Action Build -BuildRevision 3f70518fca306947d0b20117392a6e0ae3a0f944`。
- 原生使用`tools/test-ordinary-webview.ps1 -Serial <对应serial> -ExpectedAvd <对应AVD> -ReportFamily android-feedback`，API32另加`-OrdinaryOnly`；均先核验固定QA模拟器身份。
- `tools/android-a0.ps1 -Action IntegrationTest -ApiLevel 34`分别指定`-IntegrationSuite A2`、`A3`、`A4`；API32只运行A2。
- Windows在前述进程环境中，分别对`integration_test/agent_model_flow_test.dart`、`integration_test/calendar_workspace_flow_test.dart`、`integration_test/young_automation_flow_test.dart`执行`flutter test <测试文件> -d windows --no-pub`，只使用合成目录。

## 保留的人工项

最终文档检查通过：148份Markdown、1164个本地链接及冻结档案manifest；`git diff --check`通过。工程/研究与本轮验核文档分别本地提交，未推送或公开发布。

根只运行合成/loopback和独立QA环境，未操作用户MuMu安装、学校或真实模型。新版的Young真实链路、MuMu当前审批/竖屏以及学校模型具体推理字段仍需用户使用反馈；目标手机/鸿蒙、真实语音及通知等既有未观察项继续保留。整体UI重构尚未开始。
