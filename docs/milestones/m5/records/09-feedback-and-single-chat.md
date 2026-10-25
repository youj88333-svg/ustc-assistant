# 真人反馈修复：持续对话、个人安排与权限

日期：2026-10-14。依据 07–12、13、15 及 [唯一任务单 §21](../plan.md#21-真人反馈修订单对话记住授权与个人安排)。用户批准与最后体验在 [验收页](../acceptance.md)，本记录不代替真人确认。

## 已知失败与定位证据

用户报告实际语音只转写为“I.”；截图中“今天下午的课不想去了”被当成咨询，后续“可以”没有延续修改意图。模型声称查询的 `start/end`、`entries:[]` 也不是注册日程工具的真实协议。

根只通过现有诊断的白名单解码查看固定阶段、计数、耗时与终态，没有读取正式业务库、对话正文、原声、模型 Key 或浏览器认证资产。近期四个相关模型回合均为 `toolCalls=0`，不能把模型自述的 JSON 当作真实空结果。这确定了截图查询问题是虚构工具过程；不能据此推断学校数据未导入。

语音日志有 4493/3799/2188 ms 的录音阶段及 71169/59809/34209 个样本，最后转写长度均为 2；旧识别阶段的零计数来自缓冲清空后的诊断采样，不能据此认为没有录音。真实音质、设备实际配置和原声没有检查，语音根因尚不能完全归于某一项。

## 实现与保留

| 反馈 | 本轮实现 |
|---|---|
| 中文语音 | SenseVoice 显式 `zh`；保持平台停止过程中尾部 PCM 转发；诊断在清空前取固定样本计数；用户点击录音后显式选普通系统默认输入 |
| 单一对话 | C3 持久主对话引用，首次选择已有最新有效会话；产品移除新建/切换/左栏，旧的其他会话保留为档案，不合并出站 |
| compact/clear | 精确本地命令；compact 只摘要历史用户意图，不把旧助手事实、工具结果、审批或图片变成权威；保留全量聊天。clear 排空当前运行、清当前聊天和摘要，建立新空主对话，不提升旧档案 |
| 折叠审批 | 已完成/拒绝/中断的操作卡与步骤、出处共用默认折叠详情；当前待批准方案只显示一次 |
| 记住权限 | 勾选本次批准后按固定工具及本方案实际类别保存，重启有效，可在 Agent 设置撤销；所有混合类别均具许可才免确认，C3 仍逐次验账号、世代、版本、具体方案、来源作业和许可修订 |
| 日历任务 | Task 本体独立栏，PlanBlock 继续占用时段；北京时间今天截止黄圈感叹号，已截止红色，完成/取消无逾期警示；过期未完成任务带真实截止日期延续到今天，不参与日程冲突 |
| 私人字段 | 日程读取包含出勤/听讲计划；所选事件备注与任务描述/备注只在本轮人类明确要求读取相应字段时有界返回，备注和正文分别判断，否定请求优先。仅修改新值不读取旧内容，学校来源载荷不变 |
| 真实日程与出勤 | 日期性个人日程请求先发实际原生查询；不调用工具的“空结果”先纠正，重复虚构则失败、不保存虚构终答。“可以”延续近期人类业务请求，新的明确话题重新定范围 |
| 自然回复 | 提示词使用普通中文和实际本地能力；普通问题的英文旁白/参数或 JSON 倾倒最多纠正一次，仍不符合则失败，不保存该内容；用户明确请求技术字段或英文时保留其偏好 |

C3 增量 schema 13→14：新增主对话/摘要状态和固定许可表，动作回执新增授权来源。13 的全部旧业务/历史/凭据/知识/设置保留；12 及更早迁移先执行其原有增量链。升级 SQL 失败回滚，不写虚假完成；旧版程序遇更高版本拒绝打开，不声称能无损降级新数据。

许可绑定当前 owner/reset epoch/已绑定账号，不由模型输入或网页提供。撤销递增修订并立即失效当前许可证明，重新授予也不复活旧证明；本地修改及许可保存同事务。只有当前不可变方案能执行。来源准备将实际类型化请求绑定到 C3，不能用 JW 许可运行 Young。清历史、清 Key 和 compact 保留许可；完全重置清除许可。当前点击批准记为 confirmed，后续自动使用记为 remembered。

## Windows 录音设备边界

Luna / max 静态跟踪 `record_windows 2.3.0`：未提供 `device` 时调用 `CreateAudioCaptureDevice(NULL)`，没有设置 endpoint 或 role。[Microsoft 的 MFCreateDeviceSource 文档](https://learn.microsoft.com/en-us/windows/win32/api/mfidl/nf-mfidl-mfcreatedevicesource)说明此时选 `eCommunications` 默认设备，可能与用户普通 `eMultimedia` 输入不同。它不会取设备枚举列表第一项；本轮没有枚举或读取用户设备。

根确定窄接口 `ustc_assistant/default_audio_input.getDefaultInputId`：仅在用户开始录音时取 `IMMDeviceEnumerator.GetDefaultAudioEndpoint(eCapture,eMultimedia)` 与 `IMMDevice.GetId`，不读取标签、枚举其他设备或打开麦克风。该 ID 是 [Media Foundation 接受的 endpoint ID](https://learn.microsoft.com/en-us/windows/win32/medfound/mf-devsource-attribute-source-type-audcap-endpoint-id)。由于固定 vendor 将 UTF-8 字节直接扩成宽字符，接口只接受 1–1024 个非空白可打印 ASCII，其他返回固定 microphoneUnavailable，不回退到另一设备或泄露 ID/HRESULT。COM 与内存通过 RAII 释放，通道先于 engine 析构。

这个改动消除了默认角色歧义，不能凭静态分析确认用户此前实际选错设备，也不能以合成 TTS 宣称真实“I.”已通过验收。原声仍不落盘/上传，自动测试不打开真实麦克风。用户最后重试中文短句；若仍失败，继续用固定阶段/计数诊断定位，不把英文识别字符串替换成假中文。

## 委派与根独立检查

Sol / max 持有 C0/C3/C4、迁移、许可、意图/出站、集成和结果裁决；Luna / max 分别承接语音适配、日历栏、单对话/审批设置展示，以及契约定稿后的独立测试。Astra / high 独立核查许可和对话并发，根确认并修复了两项真实边界缺陷：clear 不能重新提升已存旧档案，Stop 不能让停在 SQL checkpoint 的摘要继续提交。子代理通过声明不代替下面的根命令。

本轮早期失败保留：录音合成 fixture 重复帧导致奇数字节、旧 schema fixtures 未去除 14 新表、旧 UI 仍期待多对话/展开审批、旧 synthetic gateway 忽略命名强制查询；也暴露并修复了明确新话题继承旧 scope、过宽 planning 意图和日历大字号溢出。首次完整根单测最终到 1118 通过/1 平台跳过；加入默认端点与中文纠正检查后，一次完整批次为 1130 通过/1 跳过/1 失败，原因是测试未包含 pinned InputDevice.toMap 的 `type=unknown`，根核对 vendor 并补齐预期。Windows Agent 首次 3 通过/2 失败，分别是旧测试期待重置后无主对话，以及 synthetic gateway 在强制只读纠正时错误返回 toolUnavailable；随后还修订了重启后未展开操作卡的旧期待。Windows 语音一次 2 通过/1 失败为重启断言仍期待 schema 13，改为实际 14 并保留普通事件/草稿/排空检查。没有移除业务或权限断言。

根最后复核私人读取时确认：只按“备注”字样放行会误把否定/仅修改请求当成读取意图，任务备注 opt-in 还会附带正文。已按当前人类的正向读取与同分句否定分别判定；任务字段逐项投影，仅检查/截取将要出站的字段。对应新反例有正文单读、备注单读、否定读取及仅修改新值；不靠模型遵守提示词来守住这条边界。

### 最终工程结果

根最终 `flutter analyze --no-pub` 无问题；`flutter test --no-pub --reporter expanded` 为 **1131 通过、1 项平台条件跳过**，41 秒。最后私人字段逐项读取修复后再次执行全套，保留相同通过数量，并重新运行相关 Windows Agent 套件。单元覆盖本次全部新接口和具体反例，不把未运行场景记作通过。

Windows 按 SDK 命令串行执行，**11 套共 34 组全部通过**：

| integration_test 文件 | 通过组数 |
|---|---|
| agent_model_flow_test.dart | 5 |
| speech_input_flow_test.dart | 3 |
| calendar_workspace_flow_test.dart | 4 |
| settings_maintenance_flow_test.dart | 3 |
| diagnostics_flow_test.dart | 3 |
| app_shell_flow_test.dart | 1 |
| public_knowledge_flow_test.dart | 1 |
| jw_sync_flow_test.dart | 7 |
| young_sync_flow_test.dart | 2 |
| young_automation_flow_test.dart | 3 |
| m0_flow_test.dart | 2 |

各套执行 `flutter test integration_test/<文件> -d windows --no-pub --reporter expanded`。语音增加绝对 ignored WAV 的 `USTC_SPEECH_TEST_WAV` define；固定素材经过生产 SpeechAudioRecorder 及合成 backend、4095 字节奇数边界分帧、停止中的最后 127 字节，然后进入 OfflineSpeechInput 与真实本地 SenseVoice CPU isolate。冷/热两遍均匹配固定目标词；实际冷加载 3327 ms、解码 174 ms，热准备 0 ms、解码 166 ms。这里证明合成捕获链和库调用，没有调用 Windows 真实设备方法或打开麦克风。

工程主提交 `05a5299a57fdd719bbb5e05786e18010b1fd8e37`，不含文档或构建资产，正式 Release 首次 38.0 秒通过。收尾核对发现 startup error 页仍报 schema 13，补充工程提交 `03381dbacef49734defc541d33841a94a4ffacd7` 改为 14；根 analyze 无问题，startup_diagnostics/diagnostic_runtime/diagnostics_panel 三文件 28 项通过。按最后提交再构建 `flutter build windows --release --no-pub --target lib/main.dart --dart-define=USTC_BUILD_REVISION=03381dbacef49734defc541d33841a94a4ffacd7` 通过，32.7 秒；没有开发诊断/测试 WAV 等 define。

随包权重 239233841 字节、词表 315894 字节的 SHA-256 均与固定契约一致，ORT 和 sherpa DLL 与 Windows 原生已测试文件哈希相同，NOTICE 与模型/三 SDK 的许可随包保留。诊断版本为 schema 14、tools v3、prompt v4。最终启动使用现有 C0 DiagnosticRecord.decode 白名单检查，仅输出 applicationReady=true、expectedSchema=14、startupFailed=false、revisionMatched=true；未读取业务记录或用户输入，忽略坏行且不输出原文，临时检查脚本已删除。

发布文件为 `app/build/windows/x64/runner/Release/ustc_assistant_m0.exe`，需保留整个 Release 目录。启动前只核对本应用进程路径；补充元数据后只正常关闭根刚启动的预览进程，再启动最终版，没有强制终止或操作用户既有窗口。应用已按批准进行正式本地启动/增量迁移，等待用户体验。真实设备/音质、真实模型风格和 M5 最终统一体验仍待用户确认；如果旧版本程序尝试打开 14 库会被拒绝，不承诺降级新数据。

自动测试仅使用合成业务、loopback、固定合成 WAV 与标记 TEMP，没有访问学校、实际模型 Key、正式业务记录或麦克风；最终用户应用的启动诊断只读固定安全元数据，不直接检查正式数据库/认证资产。不修改 main、其它 worktree、系统代理或信任。临时日志/探针/构建资产不纳入 Git，未推送。
