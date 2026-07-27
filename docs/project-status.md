# USTC Assistant 当前状态与 Agent 交接

更新时间：2026-07-28

## 1. 当前结论

Windows Flutter 第一版已经实现并可构建运行，不再是只有设计或脚手架的阶段。
Python 五条只读来源链路仍然保留，教务和已报名二课日程通过 SourceBundle 1.0 与
Windows App 联通。

当前首版明确不包含 LLM。聊天页是禁用外壳，下一阶段可以在完成必要人工复测后，
单独设计云端 LLM、每日简报和受控工具调用。

## 2. 已实现链路

### Python 来源层

- 教务：课程、考试、SourceBundle 1.0 完整快照；
- 二课：报名中活动列表，以及北京时间滚动窗口内的已报名日程；
- 评课社区：公开课程/教师匹配、缓存、规则排序和代表性点评；
- 校园公开信息：目录、本地检索、按 ID 读取详情和附件缓存；
- Windows Bridge：loopback 认证、能力协商、可恢复采集作业、登录继续和取消。

Python CLI 入口为 `python -m ustc_assistant`。默认教务测试学期来自
`config/source-defaults.json`：

```text
semesterId = 421
semesterKey = 2026spring
displayName = 2026 春季学期
```

教务内部学期 ID 不得根据年份推算。

### Flutter Windows App

- Drift/SQLite 本地持久化和账号分区；
- Windows DPAPI 保护学校账号与可选密码；
- SourceBundle 1.0 校验、语义检查和单事务导入；
- 首次登录、重新认证、分来源同步、十二小时自动同步和文件导入；
- 七日周课表、周切换、全天区域、非节次时间定位和截止事项带；
- 重叠事件两步选择、主事件、人工冲突/不冲突关系和用户备注覆盖；
- 单次、全天、跨日及基础重复个人 CalendarEvent；
- Task 四种持久状态、PlanBlock、截止风险、结束后确认和单步撤回；
- Reminder 持久化、App 内状态和 App 运行期间的 Windows 通知；
- 账号、操作历史、设置、官方网页、业务数据清理和完全重置。

主要实现位于 `app/lib/features/`，对应测试位于 `app/test/features/`。

## 3. 最近验证

2026-07-28 最近一次完整自动验证：

```text
Python unittest: 267 passed
Python compileall: passed
Flutter tests: 203 passed
Flutter analyze: no issues
Windows release build: passed
```

Release 输出：

```text
app/build/windows/x64/runner/Release/
```

`.exe` 依赖同目录的 `data/` 和 DLL，不能单独复制运行。

自动测试不访问学校网站，也不等于真实登录验收。修改登录、采集、同步或浏览器生命周期
后，仍需用户在可见 Edge 中完成验证码和真实页面验收。

## 4. 人工验收状态

`docs/acceptance/windows-first-milestone.md` 完成过第一轮人工测试。该轮发现的问题已
形成 `2026-07-27-first-milestone-acceptance-repairs-design.md` 和同名实施计划，
相关代码修复已经完成，包括：

- 完整快照缺失事件不再继续显示；
- “同步全部”严格串行处理教务和已报名二课；
- 删除凭据后提供明确的同账号重新认证；
- 日程详情、重叠、冲突、主事件和来源覆盖已接入 UI；
- Task 详情、PlanBlock 和结束后确认已接入 UI；
- Task 截止时间改为日期和时间选择器；
- 完全重置返回首次登录；
- 首次登录同步页可返回聊天首页。

这些修复有自动回归测试，但用户尚未把整份人工验收表重新测试并给出最终结论。
空白周课表区域直接创建事件已按用户意见从首版验收目标中移除。十二小时自动同步、
真实多账号不一致和浏览器会话边界仍适合在后续人工复测中重点确认。

验收文档第 8、29 项仍写有旧默认值
`461 / 2026fall / 2026 秋季学期`；当前测试默认已经明确改为
`421 / 2026spring / 2026 春季学期`，复测时以 `config/source-defaults.json`
为准。由于该文件包含用户原始结果，交接同步不直接改写这些行。

本机隔离工作树
`E:\107\.worktrees\first-windows-milestone\docs\acceptance\windows-first-milestone.md`
包含用户填写的未提交第一轮结果。它不是最新功能结论，但必须保留为故障历史；未经
用户明确同意，不得覆盖、还原、批量改写“完成：”或提交该文件。

## 5. 明确未实现

- 真实 LLM、每日简报、聊天持久化和 Agent 工具调用；
- Android/iOS 登录与来源采集 `SourceGateway`；
- 报名中二课、评课社区和校园公开信息的 Flutter 页面或 LLM 工具封装；
- Windows 安装器、捆绑 Python runtime 和自动安装依赖；
- App 关闭后的可靠 Windows 通知投递与取消；
- 云同步。

二课报名和取消报名永远由用户在学校官方页面执行，不属于待自动化功能。

## 6. 新 Agent 阅读顺序

1. `AGENTS.md`：安全规则、目录职责、验证命令和产品硬约束；
2. 本文：实现状态、人工验收边界和未完成能力；
3. `README.md`：运行、构建和 Python CLI；
4. `docs/architecture.md` 与 `docs/data-sources/source-bundle-v1.md`：跨端数据边界；
5. `docs/superpowers/specs/2026-07-26-first-windows-milestone-closure-design.md`：
   首版总设计；
6. 修改具体功能时，再读对应详细 spec、`app/lib/features/<feature>/` 和测试。

历史实施计划中的复选框不是实时任务状态。判断是否实现时，以当前代码、测试、Git
提交和本文为准。

## 7. 建议接手动作

1. 在本地 `main` 重新运行 Python 和 Flutter 自动验证，确认合并后的基线；
2. 不修改用户原始结果，另行复测第一轮失败项及十二小时同步边界；
3. 人工复测没有阻塞后，再开始 LLM 接入设计；
4. LLM 首版只读取本地结构化模型并调用受控工具，不向云端发送密码、Cookie、
   Token、完整学号、姓名、完整原始课表或远端个人身份。
