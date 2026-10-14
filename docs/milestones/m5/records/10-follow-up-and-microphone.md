# 连续上下文与麦克风不可用修复

日期：2026-10-14。依据 07–12、13、15 及 [M5 任务单 §22](../plan.md#22-连续对话与麦克风不可用的修复)。本轮是 §21 已批准功能的缺陷修复，用户真实失败仍保留在 [验收页](../acceptance.md)，不等同阶段关闭。

## 两项已确定的问题

用户截图中先提出“下午的课不想上了”，模型已经查询并询问是否标为不参加；回复“对的”后却说没有上下文。根沿实际代码确认了三处连续性缺口：

1. `buildAgentConversationContext` 原先排除任何带步骤、出处或行动的整对消息，连安全的人类原请求也一起丢失；模型自然语言询问的背景因此不在下一轮上下文中。
2. 短答只有“可以/好”等部分说法，“对的/是的/没错”未识别；“不想上了”也不在原出勤意图中。
3. `humanScope` 虽用于工具注册与本地意图守卫，真正的最后一条 ModelRequest 用户消息却只有孤立短答。这让合成 gateway 即使拿到写工具，也不能证明真实模型收到原请求。旧测试只验证工具选择，遗漏了请求正文契约。

麦克风错误是根上一版新增默认设备通道的一项确定缺陷：本机 Flutter `standard_codec.cc` 的 EncodeMethodCallInternal 在无参数时仍写出 null，DecodeMethodCallInternal 无条件创建 `EncodableValue`。因此合法 Dart 无参调用在 native 是**非空指针、值为 monostate/null**。旧 `call.arguments()!=nullptr` 把所有这类合法调用拒绝为 microphoneUnavailable，尚未进入设备选择或录音。本轮源码跟踪与实际 codec 往返已证明该条件错误；它不解释更早的 ASR “I.”，后者仍需真实听写复测。

## 修订与边界

上下文保留工具回合中的安全人类问题，助手内容只重新投影为固定历史对话状态：是否曾处理工具、是否曾询问继续、方案提出/拒绝/未完成/已有实际提交。状态不复制旧助手原文、课程事实、工具参数/正文、私人备注/任务内容、出处/URL/引用、卡片详情或许可。已有真实回执但终答失败时仍可以保留历史提交状态，避免把模型回答失败解释为业务零写。

短答先找到近期人类原请求，并将原意实际发送给模型；原请求的北京时间收到时间一起绑定，原话中的“今天/下周”等按当时理解，当前补充按本轮时间理解。原查询结果和引用不带回来，本轮仍须真实重新查询目标及准备不可变方案；肯定答复不直接批准卡片。已有提交、拒绝、失败或中断后的单纯肯定不能继承写工具、产生第二次执行。显式的新修改仍可走本轮正常流程。clear 不跨旧档案承接，compact 保留聊天且仅压缩上下文；必要短答可恢复最后安全控制状态，不恢复旧事实或权限。

默认输入通道现在接受 pointer-null 和 `EncodableValue.IsNull()`，非空实参仍拒绝，未知方法仍 NotImplemented。生产 handler 和 codec 测试共用 ClassifyCall；设备角色、ASCII/bounds 限制、COM/CoTaskMem 释放、仅用户点击录音、PCM 纯内存/30 秒上限、取消/草稿守卫不变。没有降级权限、自动枚举设备、切换系统设置或打开真实麦克风。

Sol / max 负责意图、C4/context、日期锚点、集成与根验核；Luna / max 分别在互不重叠文件修复 native 参数契约和补 context/journey 回归。没有依赖子代理声明来替代实际执行。

## 实际检查与失败

原生 `run_default_audio_input_codec_test` 覆盖四个实际序列：编码无参再解码为非空 null、直接 pointer-null、实参拒绝、未知方法拒绝。测试不创建音频桥、读取设备或捕获声音。首跑因前一次 integration_test 在 CMake 配置中留下已删除的临时 listener.dart 而失败，是构建配置生命周期问题；根先执行稳定 `flutter build windows --debug --no-pub --target lib/main.dart`（16.4 秒），再运行 CMake 目标通过，没有因此改变工具链或源码权限。

首批 Windows Agent 5 组通过。随后根全套一次 **1135 通过/1 平台跳过/1 失败**；唯一失败是旧 summary 测试仍要求丢弃安全“旧批准的问题”人类主题，根按新契约改为保留问题，同时保持旧卡片/事实/许可的负向断言。截图原句四种肯定变体的真实 C4→C3 查询和卡片旅程已进入该批，通过不能代表真实模型理解质量。

独立回归随后补齐原请求 10 月 14 日、本次肯定 10 月 15 日的模型请求锚点与原目标 fresh 查询；当前卡审批前零写，实际拒绝后肯定不重提案，clear 不跨档案。根另验证 compact→关闭→重启→肯定仍得到原意与固定控制状态、不恢复旧课程/证据/引用。一次 Dart format 在受限进程报 resolvedExecutable 的 Null 类型错误，使用既有 SDK 的正常提升执行后成功；没有因此改变 SDK、全局代理或权限设置。

### 最终结果

| 根实际检查 | 结果 |
|---|---|
| `flutter analyze --no-pub` | 无问题，4.3 秒 |
| `flutter test --no-pub --reporter expanded` | **1139 通过/1 平台跳过**，43 秒 |
| Windows `agent_model_flow_test.dart` | 5 组通过；构建 17.1 秒，测试 35 秒 |
| Windows `speech_input_flow_test.dart`，固定合成 WAV | 3 组通过；构建 15.9 秒，测试 8 秒；cold/warm prepare 3909/0 ms，decode 211/190 ms |
| CMake `run_default_audio_input_codec_test` | 前述 4 个纯 codec 场景通过，实际退出码 0；没有设备访问 |
| 正式 `flutter build windows --release --no-pub --target lib/main.dart --dart-define=USTC_BUILD_REVISION=1afd23c6991042485e7c3a1195ab651c2a81c552` | 40.5 秒通过，无测试入口/语音测试参数 |
| 固定语音资产/随包库 | 权重、词表和 LICENSE 摘要匹配；Release 的 sherpa-onnx-c-api/onnxruntime 与 Windows 测试库摘要一致 |
| 启动诊断与窗口元数据 | 新构建 applicationReady、revisionMatches、schema14、promptV5 为 true，startupFailed 为 false；可见主窗口标题 USTC Assistant |
| `powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-docs.ps1`、`git diff --check` | 106 份 Markdown、789 个本地链接及归档清单检查通过；差异无空白错误 |

机械检查仅使用合成/loopback/标记 TEMP，没有实际模型/学校请求、正式业务读取、用户音频或认证资产。用户回复“已关闭”后才替换正式 Release；根随后正常启动产品，只读取固定白名单诊断/窗口元数据，不检查正式库或问答正文。已有聊天/业务/配置继续保留，本轮没有库迁移或数据清理。临时启动探针在检查后删除。

代码本地提交为 `1afd23c`，覆盖上下文/短答、prompt v5、相关合成旅程和 native codec 修复；文档独立提交。根文档链接/锚点/归档校验与 `git diff --check` 在交付前完成。不推送。

真实上下文体验与麦克风可用性/听写质量保持本轮修订待验，M5 尚未关闭。临时构建、日志和素材不纳入 Git，不推送。
