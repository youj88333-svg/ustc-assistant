# QA4006 二课失败与模型策略修订

2026-10-18。范围、接口及验收见[唯一任务单](../plan.md#a7-qa4006-二课失败思考参数与标签人格)。这是 A7 后续修复，不关闭 A7/A8 或改写已关闭里程碑。

## 新证据与待验证假设

用户确认失败发生在 MuMu QA4006，并主动导出最近安全日志。根只读共享文件夹中固定 `USTC-Assistant-diagnostics (2).json`；未读取 MuMu 私有资产或正式业务库。该文件的构建修订为 `094a0560569989ad7350db83e9941e54a2f81ae3`，报告 `complete=false/invalid=1/dropped=0`，因此不宣称日志完整。最近三次 Young 作业都停在 login，随后 closing/idle 的错误为 `storageFailed`，没有 collecting/committed 证据。

代码复核确认：Android helper 查找拒绝 Webpack 常规的 getter 导出，而 Windows 固定模块读取允许该形态；原合成 fixture 只有普通数据属性，没覆盖 getter。准备阶段原生等待 12 秒并另留 500 毫秒收口，Dart 同时用 12 秒 drain 期限等候，可能先抛裸 `TimeoutException`，被上层归为 `storageFailed`。这些缺陷可用合成场景复现；现有导出不含具体准备拒绝原因，不能据此声称已经证明学校当前失败的唯一成因。

当前模型请求只有 model/messages/stream/max_tokens 及固定工具等参数，没有发送思考强度；实际强度由服务默认决定。用户要求的标签人格应用于后续新请求，不改历史文本或既有晨报缓存。

## 实施与根检查

本节按实际执行补充；未运行项不记通过。自动检查仅合成/loopback/隔离目录，不访问真实学校或模型。

Luna/max 分别完成公开参数调研和不重叠的人格文件修订，Sol 负责跨层装配和实际检查。学校指南初次直接打开返回 403，后通过官方页面索引核对当前精确别名及技术更新；这支持仅对 `deepseek-flash` 固定发送 `high` 的选择，不证明用户 Key/路由已接受或服务实际采用。其他别名不扩张，设置/安全摘要显示派生值；结构化拒参不静默重试。全部首条 system 使用同一标签前缀，compact/能力探针保持自身交付格式，历史与数据库不迁移。

Sol 将原生准备改为单次检查，由既有 C2 准备预算统一等待；C1 的无确认超时明确转来源错误并关闭排空。Astra 按需只读复核指出 runtime 已在但固定模块未注册时，不应过早执行缺失模块，可能污染 Webpack 缓存。Sol 依据 [Webpack 4 主模板](https://github.com/webpack/webpack/blob/v4.47.0/lib/web/JsonpMainTemplatePlugin.js)改用文档内唯一固定探针取得仅查 `0fea` 的局部 lookup，模块 factory 存在才求值；不依赖 JSONP 数组包含初始模块，不读 `require.c` 或其他模块。普通数组 push 尚未交给 runtime 时继续等候，lookup/helper 代码各缓存一次，身份/真实请求/投影与提交守卫不变。合成 fixture 改为模块表与失败缓存，并延迟 13 秒注册固定模块，检查未提前求值。

首轮局部检查发现两处测试装配错误（合成 SSE 未声明 UTF-8、旧探针断言只接受单条 user），均修正并保留原失败报告。首轮 analyze 发现新增失败枚举未覆盖一处工具映射及一条 null-aware 提示，均已修正；不把失败轮记成通过。

首轮全套 Dart 的两处失败均为旧人格中文句式的精确断言，已改为实际请求的标签语言及风格约束；其原报告保留。根随后局部 71 项通过，最终 analyze 无问题，全套 Dart **1561 通过、1 平台跳过**。二课协调器的 27 项含无确认准备超时/迟到及取消排空，全部通过。Android/Windows 原生与构建仍继续，不以这些单测替代实际 WebView 或学校结果。

API34 / WebView113.0.5672.136 的完整原生检查 **89通过/8历史高级反例跳过**，新增 getter、伪 getter 响应、抛错 getter 与 runtime 尚未接管的数组反例均执行。完整学校合成首次六组通过/1独立smoke未选。复核测试时发现“文档加载后13秒”仍可能只让实际准备等待6.5秒，因此强化 fixture：保持目标路由，从第一次模块准备检查起延迟13秒注册模块，并断言等待及未提前执行缺失模块；最终六组再次通过/1独立smoke未选。这个复验用于弥补计时反例，不是重复计数为新增场景。

Android Agent 首次集成失败：夹具按旧中文开头识别摘要，标签前缀使摘要未被识别，错误消耗预排的对话回复；未据此修改真实回执或放宽幂等断言。夹具改为识别固定 `TASK CONTEXT_SUMMARY`，并核对实际对话请求的首条 system 前缀；最终两组通过，含 Android Keystore、真实 SSE、思考不回传、审批、提交后模型失败/历史回执恢复不重复创建，以及后台取消。原失败与最终报告分别保留。

Android普通入口Debug x86_64、AndroidTest编译、生产Manifest处理及lint通过。Java 的 `Picked up JAVA_TOOL_OPTIONS` 在 Windows PowerShell 重定向中显示 NativeCommandError，脚本仍按实际 exit code 裁决，未将该信息行当构建失败。报告位于忽略的 `app/build/qa4007/reports`，早期局部/全套失败另保存在 `app/build/android-a0/qa4007-*`。

API32 / Android12 / WebView120.0.6099.193 的普通路线原生 **28通过/1历史反例跳过**，强化后的完整学校六组通过/1独立smoke未选。辅助编排的嵌套启动停留、OrdinaryOnly参数包装错误分别保留；根核对自有AVD已启动后，仅停止本轮已核验的编排进程，改为直接执行原生检查，没有调整产品来绕过检查，也未操作MuMu/默认ADB。

Windows Agent五组先通过；Young三组首次有一组迟到模块失败。新fixture暴露 Windows 原准备脚本也会过早require并留下空缓存，故Sol将同样的固定模块factory检查用于准备；只持有文档内固定lookup，不改 BusinessReader 的 CDP 编译、网络关联或身份权威。原导入成功断言保留，补安全摘要失败原因；最终Young三组通过，原失败报告另存。Android两个AVD均已正常停止。

Windows M6五组随后通过，包含真实本地事务与合成提醒、维护失败保留/重试及Debug通知测试宿主；全程使用并还原进程级 `USTC_NOTIFICATION_TEST_HOST=1`。最后analyze无问题（6.8秒），`git diff --check`通过。Astra最终只读复核未指出新的具体问题，其判断不替代上述根实际执行。工程独立提交为 `29f3fe8d3e058e3c468fc6a7b1ade8297ecafc92`。

## 私有构建与保留项

根在E盘环境顺序构建普通入口 `lib/main.dart` 的两种ABI包，并核对包名 `cn.ustcassistant.mobile.qa`、版本名 `1.0.0-qa-a7-webview2`、单一ABI、源码修订、人格版本及思考参数标记。两包签名证书SHA-256仍为 `16d3f9867f0a15d4d4ffc877bdd9ec240e92a3fddf6a0a66da857e2888846036`；包内Young脚本哈希与本次源码相同，固定语音模型及许可齐全，不含集成测试/图像夹具入口。

| 文件（忽略的 `app/build/qa4007/artifacts/`） | 字节数 | SHA-256 |
|---|---|---|
| `USTC-Assistant-Android-QA4007-x86_64.apk` | 290976264 | `db6b8c2bb2b8142bd370ab7a610ec0cc7feb62569333f12bdf50a6a455c7a498` |
| `USTC-Assistant-Android-QA2007-arm64-v8a.apk` | 279209275 | `ff16185974c297ce2f6ae6254a79967a7478ad54c665ee170b5bc447a756df5c` |

同一源码的Windows Release仅构建到 `app/build/qa4007/windows-staging/x64/runner/Release`。根核对普通入口、PE身份、AOT中的源码与模型策略版本、语音模型/许可和36份文件哈希；manifest位于本轮artifacts目录。没有启动该暂存程序、替换正式Release或打开正式数据库。旧QA4006/2006和Windows1.00 ZIP的字节数及SHA-256均与前轮记录一致。

新版由用户按[说明](../manual-validation.md)主动同签名覆盖，不卸载或清数据。未对用户MuMu自动安装或操作，ARM64仅打包核验；真实Young同步、学校具体模型路由接受及采用high、人格观感仍待反馈。旧聊天和已缓存晨报不改写，无需清会话。真实非空考试、手机/鸿蒙、声音、文件手势与通知/厂商策略等原未观察项继续保留，A7/A8未关闭。

最终文档检查通过：151份Markdown、1201条本地链接及现存档案manifest；差异空白检查通过。构建、报告、导出日志及夹具临时资产不加入Git，仅保存本地工程与文档提交，不推送。
