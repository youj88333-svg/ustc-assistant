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
