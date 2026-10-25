# 可选 DeepSeek 官方模型服务

2026-10-23，用户要求因学校 API 较慢增加 DeepSeek 官方 API Key 接入选项。本任务扩展现有 M5 模型配置，保持 M0–M6 的关闭结论与 Android A7/A8 的待验边界。

## 依据、范围与接口

- 设计依据：[07](../../architecture/07-constitution.md)、[08](../../architecture/08-target-architecture.md)、[09](../../architecture/09-contracts.md) K06、[12](../../architecture/12-cross-cutting.md)、[13](../../quality/13-risks-and-acceptance.md)、[15](../../workflow.md)。本次用户指令批准在固定学校服务之外增加固定 DeepSeek 官方服务；不开放任意服务地址，不自动切换提供方。
- 两个固定提供方：`school` → `https://api.llm.ustc.edu.cn/`；`deepseek` → `https://api.deepseek.com/`，仅使用 `models`、`chat/completions`。Bearer 请求拒绝重定向。
- `AgentSettingsSnapshot.provider` 标识当前提供方；可选的 `AgentModelProviderDataPort.selectModelProvider(expected, provider)` 以现有 authority 防止陈旧提交。密钥 lease 绑定提供方，网关依 lease 路由，固定网关拒绝错配。
- schema 19 将模型配置按提供方保存；旧配置无解密迁移为学校配置。模型列表、选择、Key、联网同意和能力报告各自隔离。切换撤销未完成工作与候选 Key，保留已存配置、业务数据和对话；首次切到官方必须单独同意并验证。删除 Key、撤回同意只影响当前提供方；重置应用清除两方配置。
- Agent、compact、能力验证、晨报和可选模型行为验核使用当前提供方；晨报仍使用独立通道和原有最小字段范围。业务工具、许可与学校同步流程不改。
- 为符合本次减少等待的目标，官方请求显式采用 `thinking.type=disabled` 的直答模式，工具调用保留，不发送思考历史；学校现有思考策略保留。不默默依赖官方默认开启的思考模式，否则当前不存储/重放思考的契约可能导致工具续答 400。此项在设置中明确显示，官方思考模式另行定界。
- 不硬编码官方在售模型列表；获取真实模型目录后由用户选择，能力测试仍以实际 text/stream/tool/result 为准；图片按现有显式附加与错误反馈契约处理，不移除图片重发。
- 官方账号独立计费，配置页说明请求目的地及按官方账户计费；不读取实际 Key 或调用真实计费 API 作自动测试。

## 文件归属与依赖

Sol 负责 C3 契约/迁移与撤销、C4 提供方路由/运行装配、集成检查、文档和提交。Luna 在契约固定后负责设置 UI、工作区适配及其合成测试，限指定文件。依赖顺序：契约 → 存储/路由 → 配置 UI → 相关回归 → 私有构建。所有手工编辑使用 apply_patch，缓存与产物留在 E 盘。

## 验收条件

- 旧配置升级无需重新输入学校 Key，旧密文、同意、模型与能力报告保留，迁移失败可回滚；无网络或解密副作用。
- 两套合成 Key 不串用；切换、删除、撤销同意、过期 authority、取消/晚到结果、应用重启和重置符合上述契约。失败不回退其他提供方。
- loopback 验证目录、流式文本、图片、工具调用与续答、官方直答参数、401/402/429/5xx/重定向/取消；错误不包含原始响应或秘密。
- 手机竖屏与 Windows 设置可用，切换清除未保存表单秘密、模型/同意草稿，不泄露其他方模型目录；当前提供方与 Key 删除影响清晰。
- analyze、相关单元/组件/迁移检查、必要 Windows 集成与私有 Android 构建由根执行；不以已有测试数量替代新契约验证。实际官方 Key、账户余额、真实速度和模型工具表现留给用户在应用主动配置后核验，不宣称已验证。

## 官方依据

- [接入与固定 base URL](https://api-docs.deepseek.com/)
- [模型目录与元数据](https://api-docs.deepseek.com/api/list-models/)
- [Chat Completions](https://api-docs.deepseek.com/api/create-chat-completion/)
- [思考模式及工具续答对 reasoning_content 的要求](https://api-docs.deepseek.com/guides/thinking_mode/)
- [错误码](https://api-docs.deepseek.com/quick_start/error_codes)

## 进度

工程实现、根共享回归、相关 Windows 原生集成、API34 Keystore 检查、双 ABI 私有 APK 和 Windows Release 已完成，结果见[记录](records.md)。2026-10-24 在用户已配置的 MuMu QA4019 中，根完成一次官方最小能力检查，文本、流式、工具调用和续答通过；根触发4个小请求后切回学校进行业务补验，详见[受控补验](../android-apk/records/21-mumu-provider-and-remaining-checks.md)。不推断完整业务、图片、速度或账单，也不关闭 A7/A8。

## 2026-10-24 MuMu 受控补验

用户已安装并打开应用、主动配置官方 Key，明确授权根通过 computer-use 进行真实验证。官方仅运行一次最小能力检查（目录、文本/流式、合成工具调用及续答）；后续业务旅程切回已保存的学校配置，不运行官方全量模型验核。

依赖与不变量沿用上述设计及 Android A7：根只经普通应用界面操作，不读 Key、正式数据库、浏览器资产或原始学校响应；已保存学校凭据仅由应用的固定链路使用。用户自行开启私人读取、日常本地操作和评课联网同意；根不代改这些隐私设置。现有资料、记住授权和正式业务保留，若测试需要本地变化，先核对具体方案与目标。

补验按顺序覆盖：官方最小能力结果与提供方标识 → 学校配置恢复 → 二课提交前取消及安全摘要确认未提交 → 手机操作审批弹层的展开/拒绝与状态恢复 → 匿名评课查询及来源读取 → 安全日志导出。结果、失败和根触发的请求数分别写实施记录，不推断实际账单；真实取消必须命中在途作业，不能用结束后的禁用按钮或合成取消替代。未达到条件的项目继续保留，不提前关闭 A7/A8 或目标手机/鸿蒙验收。
