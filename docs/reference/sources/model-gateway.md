# 学校模型网关契约

这是模型服务出口，不新增一条业务来源。通用秘密、出站、运行和维护要求见 [09](../../architecture/09-contracts.md)；模型入口与后续工具/图片的实际核验见 [M5 记录](../../milestones/m5/records.md)。

## 固定请求

生产主机为 `https://api.llm.ustc.edu.cn:443`，无 URL 输入或回退主机。只使用 Bearer Key，无 Cookie/学校密码/浏览器认证资产；任何 3xx 都拒绝，不将 Key 转交下个目标。尊重既有代理环境，不降低 TLS 或改系统信任。

| 操作 | 契约 |
|---|---|
| 获取模型 | `GET /v1/models`，JSON `data[]`，每项有字符串 `id`；去重，最多 256 项、1 MiB；目录不证明该模型支持工具 |
| 对话/合成验核 | `POST /v1/chat/completions`，`model/messages/stream:true/max_tokens`；能力验核只附 echo_probe，toolReady 的业务运行按当前人类问题附固定定义；思考强度仅按下述固定策略，不接受模型产生的新定义或任意附加参数 |
| 主动图片 | 仅本轮 user 消息的 `content` 数组，文字及 `image_url:{url:"data:image/png;base64,…",detail:"auto"}`；规范图片最多 3 张/合计 6 MiB，同一固定目标，无远程图片 URL、Files API 或浏览器资产 |
| 流式输出 | SSE `data:` JSON，单 choice/index 0，累积文本/结构化 `delta.tool_calls`；finish_reason 与 `[DONE]`/正常 EOF 完整成立后才交付工具完成事件 |
| 计数 | 可选 usage；缺失或 null 表示未知，实际对象中的非负 prompt/completion tokens 才接受。缺计费依据时不声称精确费用 |

Key 仅接受 1–4096 个可打印 ASCII 字节，模型 ID、工具名/调用 ID、角色和工具结果关联均按本地固定格式验证。普通请求体最多 1 MiB，含规范图片时最多 10 MiB；C4 的文本/工具定义/参数/结果另受更严的 26000 UTF-8 字节预算。响应不进入诊断原文；401、403、429、超时、协议错误和资源限制转换为固定失败码。含图请求被 400/415/422 拒绝时显示 imageRejected，不丢图重发为文字。

连接期限 15 秒、读取空闲 20 秒、单请求总期限 60 秒。流解压后最多 2 MiB，单行/事件最多 64 KiB，文本最多 24000 字符，工具参数 16 KiB、单次最多 8 个调用；跨层采用更严上限。EOF 截断、坏 UTF-8/JSON、重复终结、未声明工具、缺/重复/非连续调用标识等拒绝。`length/content_filter/refusal` 与正常 stop 分开，不据部分结果执行工具。

取消关闭在途 HTTP 并等待排空；排空期间拒绝新请求，完成后可发新一轮，永久关闭后拒新。自动网络测试仅显式装配 `127.0.0.1` HTTP 测试构造，生产组合根始终使用固定 HTTPS 构造。

## 固定思考策略与人格前缀

按用户偏好，精确模型 ID `deepseek-flash` 的全部请求统一发送顶层 `reasoning_effort:"high"`，包括验证、工具续答、compact 和晨报；其他 ID（含相近别名）保持服务默认，不推断能力。设置及安全能力摘要显示同一派生策略，不另增数据库事实或任意参数入口；不设置 `thinking`、数字预算或 `chat_template_kwargs`。服务明确以结构化 `error.param=reasoning_effort` 拒绝时映射为 `reasoningRejected`，不删参或改强度自动重试；无法识别的拒绝仍保留原固定协议错误。请求成功不证明服务器确实采用该强度。

依据为[学校模型目录](https://llm.ustc.edu.cn/)公开列出的精确部署别名、[学校技术更新](https://llm.ustc.edu.cn/guide/technical-updates/)的推理参数适配及归一化说明，以及 [DeepSeek 自家 API](https://api-docs.deepseek.com/zh-cn/guides/thinking_mode/)的顶层参数定义。它们支持此实施选择，但学校具体 Key/路由接受 `high` 仍待应用内核验；不将 DeepSeek 自家路由的全部行为套用到学校部署。思考仍仅用于有界本次展示，不进入后续请求；学校是否要求工具续轮回传思考尚未证实，不据其他提供方规则扩大出站。

全部应用自有模型请求的首条 system 统一以共享 `【PERSONA LOAD】` 标签块开头：成年专属女仆、中文、聪明体贴且自然，表达不改变工具能力、许可或真实回执。对话、晨报、compact、能力探针共用前缀；探针精确标记、摘要事实与晨报 JSON 格式各自优先，不输出标签。人格只影响新生成，历史及既有晨报不改写。

## 能力与状态

目录和实际能力分别记录。未验核为 unverified；合成文本与流式均通过但工具未完整通过为 chatOnly；固定 `echo_probe({value:"ustc_probe"})` 的调用及携带不可预知 proof 的工具结果续答均通过才 toolReady。echo_probe 不读取业务、授权或外部资料，不注册 M5.2 工具。

Key 采用独立模型类型和用途的 DPAPI CurrentUser 保护。配置事务复验 owner/reset/history/config/request 世代；停止推进 requestEpoch，异步保护及 Key 交接中的旧操作不能落库或再注册出站。保存模型的联网同意可撤销/恢复，撤销保留 Key/历史但停止运行并禁新发送。启动恢复历史清理和中断记录，不自动重放请求。

2026-10-13 用户的应用内安全摘要确认实际所选模型为 toolReady，文本、流式、原生调用及结果续答均通过，目录为 12 项；不记录 Key 或推测具体模型 ID。普通聊天/停止体验与视觉能力仍待核对，详见 [真实能力记录](../../milestones/m5/acceptance.md)。接口依据 [学校 API 指南](https://llm.ustc.edu.cn/guide/api-usage/)、[协议](https://llm.ustc.edu.cn/guide/protocol/)与 [模型](https://llm.ustc.edu.cn/guide/models/)；SSE 正常形状参考 [OpenAI 流式类型](https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events)，主动图片编码参考 [OpenAI 图像输入](https://developers.openai.com/api/docs/guides/images-vision)。新参数仍按相应合成和真实核验，不从“兼容”推断支持。
