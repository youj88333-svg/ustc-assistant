# Agent 人工验收问题修复设计

日期：2026-08-01  
目标分支：`feature/write-tools`  
设计基线：`653bc4f`  
输入记录：`docs/agent-testing.md`（用户未跟踪文件，只读，不得修改或提交）

## 1. 目标

本设计修复真实学校模型人工验收暴露的 Flutter Agent 与本地日程问题，并新增一种受控的
“整日教务课程移动”能力。实施完成后应满足：

1. 自由聊天可以完全不调用工具；明确的本地事实查询或写操作不能靠模型文本冒充结果；
2. 同一轮重复调用、历史时间戳模仿和 `ref_*` 泄露受到确定性运行时约束；
3. Agent 能按标题跨本地保留历史定位具体事件，不依赖当前默认学期；
4. PlanBlock 真正显示在周视图并能进入所属 Task；
5. 定时安排重叠时默认视为冲突，用户显式 `conflict/no_conflict` 决策优先；
6. 用户可把某一天的全部教务课程移动到另一日期，同时保持来源事件不可变；
7. “查看日程”和“查看任务”聊天 chip 分别打开正确页面分区。

校园目录、评课授权引导和公开引用 chip 的修复不在本轮实施。它们高度依赖即将被移动端
Flutter 来源适配器替换的 Python Query Source/Bridge；本设计只记录迁移时必须满足的契约，
避免继续扩大临时 Windows Python 实现。

## 2. 非目标

- 不修改 Python 校园目录采集、缓存、详情读取或 Query Result 包装；
- 不把通知目录窗口从 7 天改成 90 天，这项变化留给 Flutter 来源迁移；
- 不实现校园公开引用跳转或 iCourse 授权导航 chip；
- 不改变二课报名边界，Agent 仍不能报名或取消报名；
- 不自动读取节假日表、推测调休或批量生成课程移动记录；
- 不交换两天课表，只支持从源日期移动到目标日期；
- 不移动考试、二课、个人事件、全天事件或 PlanBlock；
- 不直接修改、复制或删除 SourceBundle 导入的教务事件；
- 不改变 SourceBundle 1.0、Python 生产者或 Flutter ImportService 契约；
- 不实现多步撤回，继续只保留现有一步撤回；
- 不在 Agent 查询或移动逻辑中写死任何 `semesterId`、学期产品键或显示名。

## 3. 已确认原因

### 3.1 模型漏调用工具和写成功幻觉

`AgentSessionService` 当前把首个没有 `tool_use` 的模型响应直接视为最终答案。系统提示词虽然
要求事实查询使用工具，但运行时没有验证。Anthropic 请求也没有携带 `tool_choice`，因此
`deepseek-v4-flash` 偶尔直接回答时，应用无法区分自由聊天和未经查询的事实陈述。

这解释了以下人工记录：

- `get_pending_event_reviews` 首次没有调用；
- `get_pending_planblock_reviews` 首次没有调用；
- 校园目录首次没有调用（本轮不修来源链路，但运行时漏调用属于本轮范围）；
- 第二次 `plan_task` 没有工具调用，却声称安排成功。

### 3.2 时间戳与引用泄露

历史上下文有意使用 `[YYYY-MM-DDTHH:mm]` 前缀，提示词要求模型不要模仿，但输出没有确定性
过滤。流式文本被直接写入 UI 和 ChatRepository，因此模型仍可能输出该前缀。

同理，`ref_*` 是模型完成同一轮后续工具调用所需的传输 token，但目前只靠提示词阻止模型
在自然语言中复述，导致人工测试看到完整 ref。

### 3.3 重复调用和关系查找循环

会话只有总模型调用数和总工具调用数上限，没有“同工具 + 同参数”的重复检测。
`get_conflicts` 只返回已经判定为冲突的事件，而系统提示词又允许模型用它处理“冲突”请求。
当用户要新建一条尚不存在的关系时，用 `get_conflicts` 寻找参与者会形成循环。

`get_schedule` 当前以日期范围为中心，不能直接按标题在本地保留的历史中寻找 occurrence。
所以模型处理上学期课程时容易反复尝试，或错误依赖当前默认学期。

### 3.4 PlanBlock 没有进入周视图

`SchedulePage` 周视图只监听 `EffectiveEventRepository.watchDisplayEvents()`。PlanBlock 只在任务
中心读取，从未传给 `WeekTimetable`，因此 `plan_task` 可以成功落库并出现在 Task 详情，却不会
显示在周时间网格。这与现有 `schedule-data-model.md` 中 PlanBlock 进入周网格的产品规则冲突。

### 3.5 冲突规则与最新用户要求不同

当前 SQL 只有显式 `conflict` 关系或规则才设置警告，普通时间重叠保持未分类。用户最新确认的
语义是：定时安排重叠默认冲突，同时保留显式 `conflict/no_conflict` 决策。因此这是产品规则
变更，不是单纯查询工具 bug。

### 3.6 Chip 审查结果

- “查看校园信息”是明确的不可交互 `Chip`，依赖可信来源 URL 契约，留到来源迁移；
- “查看任务”是可点击 `ActionChip`，但与“查看日程”都跳到 `/schedule`，而页面默认打开
  周视图，因此行为不完整；
- “查看日程”、未定截止 Task、个人事件关联 Task 和重复星期选择均有真实回调；
- 模型 Markdown 链接有意不可点击，不属于缺失实现。

### 3.7 校园通知未命中的原因（迁移期记录）

`https://www.teach.ustc.edu.cn/notice/notice-teaching/20425.html` 发布于 2026-07-16。当前 Python
通知采集只索引北京时间当天及前 6 个自然日；2026-08-01 刷新时该通知不会进入本地目录。
`search_campus_catalog` 只搜本地目录，所以无法命中；2015/2021 年结果来自长期保留的指南，
并非近期通知。

## 4. 总体架构

本轮分为五个相互约束但可独立测试的单元：

1. **Agent Grounding Policy**：保守识别明确需要工具的受支持意图；
2. **Session Runtime Guard**：有界强制纠错、重复调用熔断和模型文本净化；
3. **Local Target Lookup**：按标题跨历史定位具体 occurrence；
4. **Unified Schedule Projection**：把 CalendarEvent 与 PlanBlock 投影到同一周网格，并统一派生冲突；
5. **JW Day Move Overlay**：以本地覆盖记录移动整日教务课程，不改来源事件。

这些单元全部位于 Flutter 本地业务层。除 Anthropic `tool_choice` 请求字段外，不新增网络协议，
不修改 Python Bridge。

## 5. 自由聊天与工具落地策略

### 5.1 保守触发

自由聊天继续使用 `tool_choice=auto`，模型没有调用工具时可以正常结束。以下示例不得触发强制
纠错：

- “你能做什么？”
- “怎么规划复习比较好？”
- “为什么课程会发生冲突？”
- “假设我周三没课，该怎么安排？”
- “解释一下 PlanBlock。”
- 用户明确要求只讨论思路、不查询或不执行。

只有能够高置信度映射到现有工具的事实查询或实际写操作才进入 Grounding Policy，例如：

- 列出今天日程、当前任务、待确认事项或最近同步状态；
- 查询二课、评课或校园通知；
- 新建、修改、删除、规划或标注本地对象；
- 移动某一天的教务课程。

能力咨询与实际执行必须区分：“能否修改日程”是自由聊天，“把明天的日程改到十点”是写意图。
无法高置信度判断时不强制，允许模型回答或先向用户澄清。

### 5.2 一次受限纠错

第一次模型请求仍为 `auto`。当明确需要工具的请求没有产生任何允许工具调用时：

1. 丢弃该轮未经工具支持的最终事实/成功文本；
2. 根据意图缩窄下一次请求可见的工具集合；
3. 最多发起一次纠错请求；
4. 学校 Anthropic 兼容接口支持时使用 `tool_choice={"type":"any"}`；
5. 不支持该字段时退化为“固定纠错消息 + 缩窄工具集合 + auto”，仍只重试一次；
6. 第二次仍没有合法工具调用时，以 `grounding_failed` 结束并显示固定安全说明。

对于需要已有目标引用的写操作，纠错阶段先强制相关只读查询。例如 `plan_task` 先调用
`get_tasks`，取得当前 run 的 Task ref 后再恢复普通工具循环。创建全新对象不需要 ref，可以
直接要求对应创建工具。

### 5.3 成功声明约束

写意图只有在对应写工具通过确认并返回 success 后才算 grounded。仅调用过只读查找工具、仅
生成确认卡、用户取消、工具报错或模型没有调用写工具，都不能保留“已创建/已修改/已安排”类
最终文本。

这一约束不使用通用自然语言事实检查器；它只验证本轮意图要求的工具证据，避免误伤自由聊天。

## 6. 文本净化与重复调用保护

### 6.1 流式文本净化

会话内部区分：

- **raw turn text**：只用于向 Anthropic 重放结构化对话；
- **display text**：经过过滤后用于 UI、ChatRepository 和历史摘要。

过滤器必须跨 SSE delta 工作，避免 `ref_` 或时间戳被分割在多个片段时短暂泄露。规则为：

- 只删除 assistant 消息开头一个或多个 `[YYYY-MM-DDTHH:mm]` 历史标记；
- 不删除正文内部正常日期、时间或代码示例；
- 将完整或分片的 `ref_[A-Za-z0-9_-]+` 替换为“该条目”；
- 流结束时不得把不完整的 `ref_` 前缀写入存储。

如果一个模型 turn 最终包含 `tool_use`，该 turn 的“我帮你查一下”等前置文本不进入最终消息；
UI 使用已有折叠工具状态表达进度。只有最终无工具 turn 的正文作为完成消息保存。

### 6.2 重复调用熔断

每个 run 对工具名和递归排序后的 JSON 参数生成稳定 fingerprint：

- 首次调用正常执行；
- 相同 fingerprint 已成功后再次出现，不执行工具，返回 `repeated_tool_call` 并要求使用已有结果；
- 相同 fingerprint 已发生确定性参数/ref 错误后，不允许原样重试；
- 参数发生变化时视为新调用；
- 二课登录暂停和恢复属于同一 invocation，不进入重复判定；
- 现有模型调用、工具调用总预算继续作为最后防线。

## 7. 跨历史事件定位

`get_schedule` 增加可选 `query`：

- `query` 存在且没有日期范围时，在当前账号全部本地保留的有效事件中按标题查找；
- 不读取 Settings 中的默认学期，不接收 semesterId，不推算学期；
- 保持来源 presence、hidden、cancelled、skipped 等现有有效性过滤；
- 当前/未来 occurrence 按时间升序，历史 occurrence 按距离现在由近到远排序；
- 最多返回 20 个具体 occurrence，包含日期、时间和地点并绑定当前 run ref；
- 超量时要求用户补充日期范围；
- 同名多个候选时，Agent 必须让用户明确选择；
- `query + view=course_summary` 拒绝，因为 summary 不携带具体 occurrence ref。

课程标注、出勤/听讲、提醒和关系创建均使用这一查询定位具体事件。`get_conflicts` 只用于读取
冲突，不再承担参与者搜索。

## 8. 周视图统一投影

### 8.1 ScheduleGridItem

周视图引入仅用于本地展示的统一投影 `ScheduleGridItem`，其来源可以是：

- `CalendarEvent` 的有效投影；
- `PlanBlock + parent Task` 的有效投影。

投影携带 entity kind、entity id、稳定 grid id、标题、起止时间、重要性、颜色、前景优先级和
冲突显示状态。不得为 PlanBlock 制造假的 CalendarEvent 或伪造来源 ID。

### 8.2 PlanBlock 显示规则

- `accepted` 和 `done` 且未删除的 PlanBlock 进入对应周的定时网格；
- `suggested`、`skipped`、`rescheduled`、`cancelled` 和已删除记录不显示；
- 标题优先使用 PlanBlock 自定义标题，否则使用所属 Task 标题；
- 使用稳定的 Task 派生颜色；
- 点击普通 PlanBlock 进入所属 Task 详情；
- 与其他项目重叠时，第一次点击展开重叠项，第二次点击进入事件详情或所属 Task；
- 保留现有学校节次网格、任意时间起止、透明前景、背景虚化和固定尺寸行为。

## 9. 冲突语义

冲突改为 pair-level 派生，优先级从高到低为：

1. 生效范围内显式 occurrence `conflict/no_conflict`；
2. 生效范围内显式 series `conflict/no_conflict`；
3. 两个定时项目实际重叠时派生 `conflict`；
4. 其他情况为 `no_conflict`。

因此：

- 重叠且没有人工判断：冲突；
- 重叠但显式 `no_conflict`：不冲突；
- 不重叠但显式 `conflict`：仍冲突；
- 全天事项仅因日期相同不自动冲突；
- CalendarEvent 与 PlanBlock 使用相同规则；
- 三项重叠时每一对独立解析，一对 `no_conflict` 不影响另外两对。

派生重叠只存在于查询/展示层，不自动为每对事件写数据库关系。删除显式关系恢复默认派生。
`get_conflicts` 主要返回冲突 pair（两端安全摘要、当前 run ref、来源 `derived_overlap`、
`explicit_occurrence` 或 `explicit_series`），不再只返回无法解释配对的一批事件。

## 10. 整日教务课程移动

### 10.1 语义

操作 A -> B 表示：

- A 日符合条件的全部教务课程不再显示在 A；
- 每节课保持原本北京时间、持续时长、地点、标题、来源身份和用户标注，日期平移到 B；
- B 日原有课程、考试、二课、个人事件、PlanBlock 和全天事项全部保留；
- 新位置参与统一重叠和冲突派生；
- 这是移动，不是 A、B 两天交换。

符合条件的事件必须同时满足：

- `source == ustc_jw`；
- `eventType == course`；
- 非全天；
- 来源记录在当前完整快照范围内仍有效；
- 其原始日期等于 source date。

考试即使同样来自 `ustc_jw` 也不移动。

### 10.2 本地数据模型

新增账户隔离记录 `JwDayMove`：

```text
id
accountId
sourceDate        YYYY-MM-DD，北京日期
targetDate        YYYY-MM-DD，北京日期
createdAt
updatedAt
```

约束：

- `(accountId, sourceDate)` 唯一；
- sourceDate 不得等于 targetDate；
- 同一源日期再次移动时更新 targetDate；
- 删除记录即恢复原日期；
- 完全重置账号时删除其移动记录；
- 记录不携带 semesterId、来源事件 ID 列表或数据库外部身份。

投影始终根据事件的**原始来源日期**匹配记录：

- A -> B 后再执行 A -> C：原 A 日课程改到 C；
- A -> B 后执行 B -> C：只移动原本属于 B 的教务课程，不连带从 A 投影来的课程；
- 来源同步暂时移除某 occurrence 时不显示，但移动记录保留；未来同一来源 occurrence 恢复后继续应用；
- 同一事件保持原 CalendarEvent ID，所以 occurrence overlay、明确关系和详情仍指向同一对象。

### 10.3 手动界面

日程页提供“整日调课”命令入口。界面包含源日期、目标日期、符合条件的课程数量和课程标题
预览。确认后回到周视图并定位目标周；没有符合条件课程时不创建空记录。

操作完成提供现有一步撤回；恢复移动记录本身也可撤回。界面不提供考试、二课和个人事件勾选，
避免把批量能力扩张为任意事件搬运器。

### 10.4 Agent 写工具

新增 `move_jw_course_day`：

```text
action = move | clear
source_date = YYYY-MM-DD
target_date = YYYY-MM-DD   仅 move 必填
```

工具按日期自行预检，不依赖 `ref_*`。确认卡展示源日期、目标日期、课程数和课程标题，不显示 ID。
该操作风险等级为 `critical`：每次都必须用户确认，不允许“此类型以后不再确认”。

成功审计区分 move、retarget、clear 和 undo。业务变更、成功日志和撤回快照沿用现有原子事务
边界；源日期无课程、日期相同或字段组合错误均在确认卡出现前拒绝。

## 11. 本地导航 Chip

本轮只修复本地导航：

- `AgentLocalAction.schedule` -> `/schedule?section=week`；
- `AgentLocalAction.tasks` -> `/schedule?section=tasks`。

`SchedulePage` 接收明确 initial section，并在路由参数变化时同步选中分段。不能依赖 StatefulShell
上一次停留状态。生产组合始终注入回调；测试中无回调的 ActionChip 可以保持 disabled。

公开来源 chip 仍为普通 Chip，模型 Markdown 链接仍不可点击。

## 12. 错误处理

新增或固定以下安全错误语义：

- `grounding_failed`：明确需工具，但一次受限纠错后仍没有合法调用；
- `repeated_tool_call`：本 run 重复完全相同的确定性调用；
- `invalid_day_move`：日期相同、格式错误或 action 字段组合错误；
- `no_eligible_jw_courses`：源日期没有符合条件的教务课程；
- `target_not_found`：查询后目标在写入确认前消失；
- `user_declined`：用户拒绝确认，不重试同一写操作；
- `write_commit_failed`：本地原子提交失败，不宣称成功。

学校 Anthropic 网关不支持 `tool_choice` 时必须可识别并使用一次受限 auto 纠错；不得无限重试，
也不得因此退回接受未经工具验证的成功文本。

## 13. 安全与隐私

- Grounding Policy 只选择已注册本地/只读来源工具，不扩大工具权限；
- 强制纠错不能跳过 AgentPermissionPolicy、确认卡或原子事务；
- `ref_*` 仅保留在当前 run 的模型/工具协议中，不进入用户可见文本、历史或摘要；
- 整日课程移动只作用于本地覆盖表，不对教务系统发写请求；
- 课程原始 SourceBundle 和 SourceRecord 不改写；
- 所有查询、移动、撤回和关系解析按学校账号隔离；
- 不向模型发送 semesterId、数据库主键、完整账号、Cookie、Token 或教务上下文 ID；
- 自动测试不访问学校模型、学校网站或真实 Edge。

## 14. 校园来源迁移的强制后续契约

本轮不修改 Python，但 Flutter/移动端来源迁移不得照搬已确认缺陷。迁移 Spec 必须包含：

1. **双窗口**：每日简报使用最近 7 个北京自然日；本地可搜索通知目录至少索引最近 90 天；
2. **历史补齐**：首次安装或长期未运行后能补齐 90 天目录，必须可搜索到
   `https://www.teach.ustc.edu.cn/notice/notice-teaching/20425.html`；
3. **逐来源新鲜度**：一个来源刚更新不能掩盖其他来源过期、缺失或刷新失败；
4. **严格分类**：用户搜索通知时优先 `kind=notice/status=active`，不能用旧指南冒充近期通知；
5. **安全详情投影**：正文为有界纯文本，候选链接和附件向模型只提供不透明 ID 与标签；
6. **可信跳转**：校园引用只有在 URL 来自已验证来源结果时才可点击，模型文本 URL 永远不可点击；
7. **评课授权**：未授权不联网，提供设置入口，授权必须由用户显式完成；
8. **回归样例**：包含“英语课程选课须知”详情中的 `le.ustc.edu.cn` 候选链接，不能因此拒绝整条详情。

## 15. 测试与验收

### 15.1 自动测试

必须覆盖：

- 自由聊天无工具正常完成；
- 明确只读请求首次漏调用后只纠错一次；
- 学校网关支持和不支持 `tool_choice` 两条路径；
- 写工具未执行时不能生成成功结论；
- 工具 turn 的铺垫不进入最终历史；
- 分片时间戳和分片 ref 不泄露；
- 同 fingerprint 不重复执行，二课登录恢复不被误拦截；
- 标题查询跨历史、跨默认学期且账号隔离；
- 同名候选、超量、无结果和失效来源；
- PlanBlock 状态过滤、周视图、点击和重叠展开；
- 重叠默认冲突、显式覆盖、非重叠显式冲突、全天例外和三项 pair；
- A -> B 移动、A -> C 更新、B -> C 不连带 A、clear、undo、账号重置和同步后保留；
- 教务考试、二课、个人事件、全天事件和 PlanBlock 不被整日移动；
- `move_jw_course_day` 严格参数、critical 确认、取消、原子审计和无课程拒绝；
- 日程/任务 ActionChip 打开明确分区。

### 15.2 自动验证命令

```powershell
$env:PYTHONPATH='E:/107/.worktrees/write-tools/src'
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
Push-Location app
E:\flutter\flutter\bin\flutter.bat analyze
E:\flutter\flutter\bin\flutter.bat test
E:\flutter\flutter\bin\flutter.bat build windows --release
Pop-Location
```

Python 本轮原则上无行为改动，但全量测试仍用于证明 Flutter 设计没有伴随误改 Python 来源。

### 15.3 真实人工复测

用户需在真实学校模型、校园网/iWAN 和 Release App 中复测：

- `docs/agent-testing.md` 项 4、5、9、W4、W5、W8；
- 尚未填写的项 8 和 W9；
- 普通自由聊天不调用工具；
- `tool_choice` 在学校 Anthropic 兼容接口上的真实表现；
- 上学期课程查询和关系创建不受当前默认学期影响；
- 整日教务课程移动、目标日冲突、恢复和撤回；
- “查看日程”和“查看任务”分别进入正确分区。

校园目录项 13-15 保留当前失败记录，等待 Flutter 来源迁移后复测。本轮自动测试通过不能把这些
真实来源项改写为成功。

## 16. 完成标准

只有同时满足以下条件，后续实施才能声称本轮完成：

- 本设计范围内新增测试先失败后通过；
- 全量 Python/Flutter 测试、analyze 和 Windows Release build 有本轮实际成功输出；
- 自由聊天未被强制工具策略误伤；
- 未执行的写操作不再被描述为成功；
- 用户可见和持久化 assistant 文本不含 ref 或历史时间戳前缀；
- PlanBlock 与移动后的教务课程在周视图、冲突查询和详情导航中语义一致；
- 整日课程移动不修改来源记录且不影响非教务课程事件；
- 默认学期仍只来自共享配置，Agent 逻辑没有新增学期字面量；
- 用户原有脏文件和 `docs/agent-testing.md` 未被覆盖或提交；
- 校园来源问题明确保持待迁移状态，没有被自动测试伪装为已修复。
