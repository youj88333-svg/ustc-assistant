# 可选模型服务实施记录

## 2026-10-23 范围与实现

依据[任务单](plan.md)与用户直接指令，增加学校/DeepSeek 官方选择，不开放任意目标或自动回退。C3 schema 19 按提供方保存配置，旧学校密文和用途无解密迁移；租约携带提供方，固定网关再次拒绝错配。配置切换撤销候选 Key、旧授权世代、运行及设置草稿；当前 Key 删除/撤销同意不影响另一提供方。两端平台保护接受两个精确用途；Android 仍沿用原 MODEL alias，完整用途作为 AES-GCM AAD，Windows 用途作为 DPAPI entropy，密文格式不变。

Agent、compact、晨报独立通道和手工合成模型验核统一使用选择。官方按文档 `/models`、`/chat/completions` 请求，显式关闭思考减少等待并保留完整工具；学校 high 规则保留。设置显示目的地、独立计费、直答模式、独立同意及当前 Key 删除范围；诊断仅增加固定提供方枚举和余额不足失败码。

## 已发生的检查与修正

- 初轮 analyzer 发现新增余额失败码缺少设置文案，已补齐；一次 Flutter 受限进程未产出而停止，随后在授权 E 盘 SDK/cache 环境执行。没有升级 SDK 或改全局环境。
- 首轮 C3/网关/组件 18 项通过。扩大相关检查发现旧测试仍断言 schema 18、合成旧版本缺少还原新增对象、日期同步快照把已批准的新元数据视作破坏，以及命令误列不存在的测试文件；保留失败报告，修正测试版本和受控 legacy fixture，原业务/秘密逐字段保留检查继续存在，新增迁移与事务回滚专项覆盖。
- 独立只读复核提出同一 controller 外部切换仍可能留表单 Key 草稿的条件性问题，已增加提供方/owner/reset/configRevision 监听和合成组件覆盖；不把该条件风险记为真实 Key 泄露事件。
- 窄屏双倍字号专项检出新增提供方下拉框右侧溢出 39 像素，增加展开宽度与长标签省略后，375×812、812×375、双倍字、外部切换草稿撤销等 4 项组件验证通过。
- Windows 首项合成用例在滚动到聚焦 Key 输入框下方按钮时等待不止，两个尝试报告保留。测试点击辅助先移开焦点再滚动，避免 native caret reveal 与测试滚动争用；补充固定步骤日志后，完整原生 Agent 5 组（47 秒）及 M6 5 组（9 秒）均通过。只改合成测试，不把该测试等待宣称为正式窗口故障。

## 根工程核验

工程本地提交：`37ce18804754cc8d395df4b44658e5447769cd2a`。

| 检查 | 结果与范围 |
|---|---|
| `flutter analyze --no-pub` | 无问题 |
| `flutter test --no-pub --reporter expanded` | 1609 项通过，1 项平台跳过；含两方 profile/重启/删除/撤销、schema18保留/19失败回滚、跨用途 DPAPI、回环接口/工具续答/错配/取消、手机表单及原有核心回归 |
| Windows `agent_model_flow` | 5 组通过，原生临时目录/DPAPI/合成模型；无真实学校或官方 API |
| Windows `m6_flow` | 5 组通过，独立 Debug 通知宿主，测试环境变量仅子进程有效；未注册生产提醒 |
| 文档与空白 | 文档脚本通过（160 Markdown、1248 本地链接，当时计数）；`git diff --check` 通过，最终交付后再次核对 |

详细输出位于被忽略的 `app/build/model-providers/`：`analyze-final.txt`、`full-tests.txt`、`provider-layout-final.txt`、`windows-agent_model_flow.txt`、`windows-m6_flow.txt`。失败尝试仍保留，不以最终通过覆盖过程。

Android 原生保护在独立 `ustc_android_a0_api34` / `emulator-5588` 执行，`AndroidCredentialVaultTest` 6 组通过，含同 owner 的学校/官方模型用途往返及交叉解密拒绝。首次后台启动辅助的进程树等待及手工检查脚本误用非 QA 测试类名的失败保留；核对实际 package 后改用 `cn.ustcassistant.mobile.qa.credentials.AndroidCredentialVaultTest`，无产品修正，随后通过。没有借此读取 MuMu、正式凭据或学校页面；自行启动的独立模拟器已结束，不关闭共享 ADB 服务。

x86_64/ARM64 Debug APK、AndroidTest 编译、lintDebug、Release manifest 和 Windows Release 构建通过。Windows 构建不启动正式应用、不运行 Release 通知注册；Windows1.00 原私有 ZIP/验收结论不变。

## 真实账户边界

本轮未读取用户模型 Key、正式数据库或学校原始响应，也未对 DeepSeek 发起计费 API 调用。官方账户余额、真实速度、图片及模型工具表现需用户在应用主动配置/同意/验证后判断。模拟器证据不关闭目标手机、鸿蒙、真实麦克风或 A7/A8 原待验项；Windows 1.00 旧私有发布记录不改写。

## 私有交付

QA 源码修订为 `37ce18804754cc8d395df4b44658e5447769cd2a`；另有纯构建忽略提交 `d19b4fe` 排除 Kotlin 本机会话，不改变产物代码。x86_64 已通过 APK/AndroidTest 编译、lintDebug、Release manifest 与签名/ABI/入口/版本/既有资源检查；普通入口为 `lib/main.dart`，无合成入口，工具 v7/提示词 v14，schema19。

| 产物 | 大小 | SHA-256 |
|---|---:|---|
| `app/build/model-providers/artifacts/USTC-Assistant-Android-QA4019-x86_64.apk` | 291042347 bytes | `02c27d90d4fdb709c96d92ead6a247747301a384e37944b4e2f55cc5e7c9bec4` |
| `app/build/model-providers/artifacts/USTC-Assistant-Android-QA2019-arm64-v8a.apk` | 279243535 bytes | `23de86565a24b1c019ddcdc331a1a2d5f347bc1920ecaa17c57633cc8ddb9ae8` |
| `app/build/windows/x64/runner/Release/ustc_assistant_m0.exe`（须连同相邻依赖运行） | 853504 bytes | `ebdf1f03ae625578f9dff623abc103c70fa8b4348affc54935f11feee1c450f2` |

包名为 `cn.ustcassistant.mobile.qa`，版本名 `1.0.0-qa-a7-webview2`，升级证书 SHA-256 为 `16d3f9867f0a15d4d4ffc877bdd9ec240e92a3fddf6a0a66da857e2888846036`。元数据明确 `realDeepSeekValidated:false`。仍未覆盖安装现有 MuMu；最后一次完整 MuMu 真人式旅程仍对应 QA4018，不借用该证据给新官方模型背书。请使用同包名/同签名覆盖升级；schema19 为前向增量，旧包不能直接读取新库，不能以降级/卸载/清数据代替回退设计。

Windows 新 Release 和上述两份 APK 均由工程提交 `37ce188` 构建；`app/build/model-providers/` 保存命令辅助、实际报告及 APK manifest。构建输出不入 Git、不推送，也不标记公开发布。进入“设置 → Agent”，选择“DeepSeek 官方”、输入 Key、单独勾选发送同意、获取模型、选择模型并验证保存后使用；官方本期为直答模式，原业务工具保留，切回学校可用原配置。

## 2026-10-24 官方最小真实验核

用户已在 MuMu QA4019 配置官方 Key，并明确授权 computer-use 小测试、业务使用学校服务。根不读取 Key；仅点击一次“验证并保存”，界面四项能力均通过。安全日志22显示根本次4个请求为 `deepseek` 且正常结束，随后选择学校原配置，后续业务日志为 `school`。此处仅确认目录、文本/流式及合成工具往返可用，不是完整业务、图片、速度或账单结论；构建时元数据不回填为真人结果。

二课提交前取消与重试、匿名评课、手机审批的实际经过及发现的拒绝后重提缺陷，统一见[Android补验21](../android-apk/records/21-mumu-provider-and-remaining-checks.md)。该业务修复使用学校服务复验，不为此对官方运行全量测试；A7/A8及目标设备保留项不关闭。原2026-10-23“未覆盖MuMu/无真实官方验核”保留为当时事实，以本节及后续记录为当前补充。
