# 可选 DeepSeek 官方模型服务

状态：2026-10-23 用户明确要求增加官方 API Key 接入选项，按其授权实施；既有学校路线保留。工程证据及尚待真实账户核验见[任务单](../milestones/model-providers/plan.md)与[记录](../milestones/model-providers/records.md)。不重新打开已关闭里程碑，也不据此关闭 Android A7/A8。

学校 API 等待较久，用户需要可选择的替代服务。新增固定 `api.deepseek.com`，保留固定 `api.llm.ustc.edu.cn`；不提供任意 URL、不自动跨提供方重试。每个提供方独立保存受保护 Key、同意、目录、模型与能力报告。配置页面明确内容发送对象和官方账户独立计费，首次选择官方不继承学校授权。切回保留原学校配置；选择服务不自动获取目录或发消息。

C3 仍是唯一密文事实源，schema 19 无解密保留旧学校配置，Key 的用途及租约绑定提供方；P 只扩展两个精确模型用途，不更改学校密码保护或既有密文格式。所有后台渠道使用当前选择，仍受出站最小化、世代、停止与维护约束；晨报不持有 Agent 通道。

官方 [Chat Completions](https://api-docs.deepseek.com/api/create-chat-completion/) 与现有协议兼容，但[默认思考模式](https://api-docs.deepseek.com/guides/thinking_mode/)要求带 tools 的后续请求回传思考内容。为符合本次减少等待和既有不存储/重放思考的契约，官方显式使用直答 `thinking.type=disabled`，保留全部业务工具，并在设置标明；学校的固定 high 策略保留。官方思考模式不在本次实现范围，不以空字符串冒充完整思考回传。模型目录动态获取，能力仍由合成调用及结果续答实测；没有官方 Key 不声明真实可用、速度提升或模型评分。

该取舍仅扩展模型出口，学校密码、浏览器资产及原始响应不发送给官方；私人内容仍按当前应用许可和本次任务最小读取。API Key 必须由用户在应用主动输入，不发送到开发聊天或日志。
