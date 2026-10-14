# 上下文与执行权限：现状调查及重构提案

日期：2026-10-14。用户再次报告上下文/权限限制妨碍 Agent 连续处理，要求先列出现状、搜集资料并给完整修复计划。当前代码基线 `1afd23c6991042485e7c3a1195ab651c2a81c552`，文档基线 `0108b7daab7026c8a248f6e5846ff3b5c193ce4c`，开始调查时工作树干净。

本轮只有仓库静态检查、公开原始资料调研、独立复核和文档提案。没有修改应用、运行 SDK/测试/真实模型、读取正式业务/问答/用户日志/秘密或认证资产，也没有替换或重启用户应用。唯一任务单是 [M5 §23](../plan.md#23-m59-上下文与执行权限重构提案待批准)，本记录不是第二份实施计划。

## 1. 用户反馈与可确定范围

截图链路为：用户提出下午课程的本地出勤意图，助手已列出单一具体目标并询问；用户回复 `approve`，助手只说会检查准备；随后“请继续”又被要求说明具体课程。截图中的业务名称、教师、地点与原始个人数据不复制入仓库。它证明真实体验仍未通过，不能用既有合成旅程通过覆盖。

截图还显示听写“没有听到可识别的语言”。这与上一轮“麦克风不可用”的 null 参数错误不同，不能把前一项 codec 修复说成当前识别质量已通过。本轮聚焦上下文/权限提案，语音继续单独待定位。

## 2. 根核对的现状及代码定位

行号对应上述代码基线，只用于本次追溯。

| 当前事实 | 代码/设计定位 | 影响与证据边界 |
|---|---|---|
| 主对话记录与模型输入不同；C3 最近读取最多 500 条 | `data/agent_chat_store.dart:33`、`agent_store.dart:294,864` | 界面保留不证明所有历史出站 |
| C4 通常 6 对、8000 字符；旧问题摘要最多 12 条/2000 字符；带图用户回合按结构内容排除整对 | [agent_context.dart](../../../../app/lib/agent/agent_context.dart)、`agent_coordinator.dart:1195–1236` | 基于字符/对数裁剪，没有按目标模型实际容量装配；图的语义连续性与原图持久化应分开 |
| 含工具/出处/操作的助手原文被固定状态取代 | `agent_context.dart:93–153` | 具体目标、候选和助手提问不保留；原人类请求保留不能补齐这些信息 |
| compact 输入主要是用户文字与旧摘要 | `agent_context.dart:63–89`、`agent_coordinator.dart:1779` | 未覆盖完整的已查事实、候选选择及未解决问题 |
| 短答列表未含 approve；寻找原请求和注册工具各有不同回溯逻辑 | [agent_request_intent.dart](../../../../app/lib/agent/agent_request_intent.dart)、`agent_coordinator.dart:898–950,1019–1137` | approve 后的“继续”可能把 approve 本身当原业务主题 |
| 固定生产工具总数 19：12 读取＋4 本地规划/提案＋3 来源协调 | [agent_read_tools.dart](../../../../app/lib/agent/agent_read_tools.dart):191、[agent_action_tools.dart](../../../../app/lib/agent/agent_action_tools.dart):73、`demo_runtime.dart:403` | 工具数量不是权限类别数量；组装仍要求 toolReady，问句会再裁清单 |
| 22 个按工具/类别的持久许可，没有目标 TTL | [agent_permission_contract.dart](../../../../app/lib/core/agent_permission_contract.dart)、[agent_permission_store.dart](../../../../app/lib/data/agent_permission_store.dart):29–172 | 已有许可可免本卡确认，但无法绕过 C4 问句裁工具；撤销/重授与事务证明独立有效 |
| 备注需要指定字段/读取动词；任务正文另要求“任务/task”等词 | `agent_read_tools.dart:423–458,932,1067` | “给我备注”“看看这份作业内容”等词面可能漏判；当前许可布尔在读取 session 范围，并非严格一次单目标消费 |
| 来源刷新/Young 查询另有问句资格 | `agent_action_tools.dart:555,633,823–860` | 固定来源工具已存在，正常意图仍可因措辞无法进入 |
| 引用/游标运行内最长 10 分钟；每次交付复验全部已有快照 | `agent_read_tools.dart:23,537–579` | 安全身份/reset 的复验有价值；业务整体 revision 变化可能中断整个会话交付 |
| 当前卡决定已有 waitingForApproval、卡 ID、同一 future | `agent_coordinator.dart:1898–1918` | 文字确认可复用同一入口，无须新审批引擎；无卡不能捏造批准 |
| 上下文＋工具定义 26000 字节，8 次模型/16 次工具，180 秒主动 | `agent_coordinator.dart:72,861,1357–1380,1500` | 中文、完整工具描述和纠错共同占局部预算，不能与模型容量混称 |
| gateway 另有 128 消息、32 工具、总 128 Ki 字符和传输/响应保护 | [ustc_model_gateway.dart](../../../../app/lib/agent/ustc_model_gateway.dart):344–529 | 合法角色、调用/结果配对与网络保护应保留；和 C4 更小预算需自洽 |
| 表达有一次纠正、再次触发即失败；UI 显示只读查询可用 | `agent_coordinator.dart:989,1471–1490`、`agent_workspace_page.dart:1028` | UI 标签不能解释为生产没有任何写能力；自然英文术语和技术问答应与协议失败分开 |
| 旧旅程脚本明确安排工具序列 | [agent_feedback_journey_test.dart](../../../../app/test/agent/agent_feedback_journey_test.dart) | 工程通过证明指定输入/调用可执行，没有证明真实模型会主动完成或语义续接 |

源码支持“语义丢失＋词面裁能力”的结构诊断；未读取真实模型请求/逐轮工具记录，因此不声称已经复现这一张截图的具体模型分支或网络情况。C3 已记住许可的执行和 C4 工具可见性必须分别描述，不能笼统归因所有卡片/权限都不可用。

## 3. 公开原始资料与采用原因

以下资料在 2026-10-14 实际检索并打开；不开第三方博客作技术依据。动态 main/master 源码用于观察现有设计，不作为项目依赖或固定兼容性声明。不复制长段原文，不引入新运行框架。

| 原始资料 | 本次查阅的实现/方法 | 对项目提案的作用 |
|---|---|---|
| [OpenAI 会话上下文示例](https://developers.openai.com/cookbook/examples/agents_sdk/session_memory) | 以用户回合连同助手和工具项保留；裁剪与摘要各有风险 | 最近完整交互保留，早期语义压缩，不能只摘用户问题 |
| [Agents SDK Session 源码](https://raw.githubusercontent.com/openai/openai-agents-python/main/src/agents/memory/session.py)和[Runner 源码](https://raw.githubusercontent.com/openai/openai-agents-python/main/src/agents/run.py) | 可由应用实现存储/获取/清理会话项；运行与恢复接会话上下文 | 在已有 Dart/C3 内实现同类责任，不依赖其 Python SDK |
| [OpenAI 运行上下文与模型上下文](https://developers.openai.com/api/docs/guides/agents/define-agents) | 应用依赖/权威状态与模型可见会话分开 | 对模型保留语义，不将 owner、秘密或批准权作为消息发出 |
| [OpenAI 审批与恢复](https://developers.openai.com/api/docs/guides/agents/guardrails-approvals) | 敏感工具中断、应用决定后恢复同一运行 | 输入确认直接接当前卡，不以新用户回合重做任务 |
| [LangGraph Memory](https://docs.langchain.com/oss/python/langgraph/add-memory) | 裁剪历史后仍须保持合法助手调用/工具结果组 | 摘要/裁剪/隐私重新投影不能产生孤立工具结果 |
| [LangChain HITL](https://docs.langchain.com/oss/python/langchain/human-in-the-loop)及[其 middleware 源码](https://raw.githubusercontent.com/langchain-ai/langchain/master/libs/langchain_v1/langchain/agents/middleware/human_in_the_loop.py) | 按具体工具/参数控制人工决定；approve/edit/reject 后接结果 | 配置和执行时控制许可；改条件不复用旧批准 |
| [LangGraph Interrupts](https://docs.langchain.com/oss/python/langgraph/interrupts) | 恢复可能重跑部分节点，副作用须明确隔离/幂等 | 继续保持 C3 真实回执，不把“恢复模型”实现成重写业务 |
| [Anthropic 有效上下文工程](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) | 精确过头的硬编码会降低灵活性；压缩保留重要任务信息 | 删除词面决定能力的逻辑，保存选择/目标/约束，精简系统规则 |
| [Anthropic Agent 评估](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents) | 区分轨迹、真实最终结果和交互质量，多次试验观察波动 | 机械回归与用户主动的真实模型合成场景分开，不以 scripted 调用代替理解质量 |

曾尝试的 OpenAI `/guides/agents/evaluate` URL 返回 404，不列作论据；所用评估资料为上表实际打开的 Anthropic 原始文章。检索中出现的 Reddit/转载结果未作为本提案依据。

## 4. 工作流与独立复核裁决

Sol / max 从现行设计和运行链路核对事实/资料并制定提案；两名 Luna / max 分别只读盘点上下文/预算与工具/许可/字段投影；Astra / high 独立分析是否需要大架构、如何避免再次用授权控制语义。子代理没有编辑文件、测试 SDK 或接触真实资产。根逐项核实数量、代码与现行许可，未把“所有副作用永远要卡”的旧概括带入现状，实际已有许可可执行。

Astra 支持保存近期安全交互、会话目标定位和执行端授权，并提出根采纳的约束：

- 旧结果标历史，不一律清空；需要当前状态/写入时再验证目标。不能将旧执行许可一同搬入历史。
- 工具集稳定可见，用户许可控制执行；不再添加每轮写关键词、精确字段词或另一个强制模型裁判。
- 批量不是天然越权；是否转卡看已有许可与规范意图，不能对“多门课不参加”添加随意条数审批。
- 当前卡确认复用已有同 run 决定；确认并改条件不批准原卡，无卡的 approve 只是继续。
- 读取策略撤销后重新投影相应私人内容，保留允许的交互结构；不借撤销把全部业务语义再次删掉。

根没有采用“仅扩大肯定词表、仍丢全部具体事实”作为最终方案，也不让新的模型抽取意图直接授予权限。用户理解由模型承担，类型/当前许可/目标/事务/维护与回执仍由应用检查；明确只读模式提供软件级零写。

Astra 随后只读复核完整 §23 草案，根采纳三项必要细化：自动授权仍有许可范围内误操作的语义风险，不能靠来源标签/C3 声称绝对防注入；撤销私人内容采用排除受影响完整派生项并从允许基础项重建，不承诺精准语义去污；别名定位最新对象后仍核对已确定日期/单次范围，目标移到另一天不能静默套旧意图。没有新增模型裁判、每轮资格或任意条数审批门槛。

## 5. 本轮状态

完整提案、分切片、内部契约、读取/操作范围、预算和验收统一在 M5 §23。要批准的是数据上下文/按需私人内容、日常许可默认选择和当前卡文字确认；普通类/表/预算细化由根落实。现行 07–12 和应用没有按新提案变更，M5 未关闭。

根已执行 `powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-docs.ps1`，107 份 Markdown、805 个本地链接及归档清单检查通过；`git diff --check` 通过。只有文档变更，工程和真实模型/语音没有新通过结论。提案建立本地文档提交；提交不等于用户批准，不推送。
