# USTC Assistant Agent Guide

## 目标

开发一个面向中国科学技术大学的本地优先校园学习生活助手。已完成 Windows Flutter
首版（含只读 Agent）及五条 Python 只读数据链路。当前阶段从"修补 main"转为
**整体重构**：先把全部架构细节按六层阶梯分层敲定，再从零重写为纯 Flutter 原生
实现（Python/Bridge 退役），同时完善 Agent harness；重构期间旧版 main 保持可运行、
可回退。最终产品目标为 Windows/Android/iOS 三端运行：先完成 Windows 实现与正式版，
移动端采集适配在 Windows 正式版之后再迁移。路线与规则见下文"整体重构与正式版路线"。

## 当前能力

1. 教务系统：指定学期课程、考试安排和统一日程导入包。
2. 二课平台：当前报名中活动列表。
3. 二课平台：北京时间滚动窗口内的已报名日程。
4. 评课社区：公开课程/教师查询、缓存、教务联动、规则排序和代表性点评。
5. 校园公开信息：教务处和财务处目录、本地检索、按需详情读取和附件缓存。
6. Windows App：账号与同步、七日周课表、个人日程、Task/PlanBlock、冲突与用户
   覆盖、提醒、操作历史、设置和一步撤回。
7. 只读校园 Agent：按学校账号隔离的长期主会话，接入学校 Anthropic 兼容模型服务
   （`https://api.llm.ustc.edu.cn`，默认模型 `deepseek-v4-flash`，SSE 流式 +
   `tool_use`/`tool_result`），15 个只读工具（11 本地 + 4 按需来源），工具过程
   默认折叠、可停止、可重试，API Key 由 DPAPI 保护，确定性隐私过滤，滚动摘要，
   重启恢复。Agent 不能发起同步或执行任何外部写操作；本地业务数据修改仅经下述
   受控写工具。架构见 `docs/architecture.md`“只读 Agent 架构”一节，人工验收清单
   见 `docs/acceptance/read-only-agent.md`。
   写工具：11 个受控本地写工具（create_event/update_event/create_task/plan_task/
   create_user_overlay/record_attendance_decision/record_listening_mode/
   create_schedule_relation/set_reminder/update_permission_policy/
   move_jw_course_day），全部经"审批门"按风险分级确认（聊天内联确认卡），
   AgentPermissionPolicy 表迁移并接入运行时决策，设置页可管理确认策略；权限变更
   永远需要用户亲手确认（update_permission_policy）。写能力只作用于本地业务数据，
   不新增任何学校/外部写通道。全部写工具均为本地-only 且事务性审计：业务提交、
   agent 业务日志、用户确认日志与权限变更（remember / ask_first_time）落在同一
   Drift 事务，任一失败整体回滚（SQLite fault-injection 回归验证）。确认卡目标
   预览只显示目标标题/时间等模型安全信息，不含 DB id/ref；写参数经
   WriteArgumentReader 严格运行时校验，非法参数拒绝为 `invalid_write_arguments`
   且不产生 DB 变更。
   完整删除与生命周期工具（`feature/delete-tools` 分支，提示词版本 8）：在 11 个
   写工具之上新增 9 个生命周期/清除/撤回写工具（update_task/update_plan_block/
   delete_schedule_relation/clear_reminder/clear_user_overlay/unlink_task_event/
   reset_permission_policy/undo_last_action，以及 update_event 扩展 action=
   cancel/reopen/delete/restore 与重复 scope only_this/this_and_future/
   whole_series）和 8 个管理态/配置态只读工具（get_schedule(view=management)、
   get_tasks(state=deleted)、get_plan_blocks(include_deleted)、
   get_schedule_relations、get_reminders、get_user_overlay、
   get_last_undoable_action、get_task_details）。个人 CalendarEvent/Task/PlanBlock/
   重复系列只软删除（`deletedAt`），学校课程/考试/二课/SourceRecord 不可由这些工具
   删除；课程/考试/二课删除请求被拒绝并解释，仅在用户明确同意后本地隐藏。配置型
   记录可物理清除但同事务写 Agent ActionLog 与完整 Undo 快照。普通工具额度仍为
   12/run，create_task Burst 32 一次性 Lease 不变，删除工具不借用 Burst；多对象
   逐项执行无 batch/delete-all，顺序 mutation ledger 准确汇总。Agent 写入用
   NoopUndoRecorder 不占用一步撤回槽；undo_last_action 撤回最近一次用户可撤回操作，
   账号隔离、一次性消费。最小管理 UI 提供取消/删除分组与重开/恢复入口。组合级
   生命周期回归（13 个场景）与只读来源回归见
   `app/test/integration/agent_composition_flow_test.dart`、
   `app/test/integration/read_only_agent_flow_test.dart`。本轮真实人工验收尚未执行，
   清单见 `docs/agent-complete-delete-tools-retest-2026-08-03.md`（`完成：`留空）。
   人工验收修复轮（2026-08-01 调试计划 Tasks 1–10）已全部完成：Grounding Policy
   + tool_choice 受限纠错（显式操作必须真实调用工具，自由聊天从不强制；提示词
   版本 4）、输出净化与重复调用熔断、`get_schedule(query=...)` 标题查询跨历史定位
   写目标（get_conflicts 从不作为参与者查找器）、accepted PlanBlock 进入周视图
   网格且可点击、时间重叠默认派生冲突 + 显式 conflict/no_conflict 覆盖、
   `JwDayMove`（schema 5）整日教务课程移动/清除/一步撤回（Agent 写入不占用撤回
   槽）、本地 chip 精确分区路由（查看日程→周视图、查看任务→任务分区）。修复轮在
   `feature/write-tools` 分支上完成，尚未合并到 `main`，最终验证与 HEAD 见
   `docs/read-only-agent-handoff.md` 第 7.2 节；写工具/手动人工验收尚未执行，清单
   见 `docs/acceptance/read-only-agent.md` 第 10、11 节（`完成：`留空待用户填写），
   真实复测清单见用户文件 `docs/agent-manual-acceptance-retest-2026-08-01.md`
   （未跟踪用户文件，不得修改）。Python 校园（campus）与 iCourse 体验未改变；
   `agent-testing.md` 第 13-15 项仍等待 Flutter 来源迁移。

Python 入口统一为 `python -m ustc_assistant`，Flutter 工程位于 `app/`。详情见
`README.md`，当前交接状态见 `docs/read-only-agent-handoff.md`，稳定来源契约见
`docs/data-sources/`，日程产品模型见 `docs/schedule-data-model.md`。

正式导入边界为 `docs/data-sources/source-bundle-v1.md` 与
`schemas/source-bundle-1.0.schema.json`。Python JW 和已报名二课日程已生成
SourceBundle 1.0，Windows Bridge 已提供认证回环协议与可恢复采集作业。

## 项目结构与当前阶段

### 实现状态

- Python 数据层、五条只读来源链路和统一 CLI 已实现。
- `app/` 已实现 Flutter Windows 首版，包括 Drift/SQLite、SourceBundle
  `ImportService`、本地账号分区、同步、周日程、个人日程、Task/PlanBlock、提醒、
  历史、设置及对应测试。Android/iOS 目录目前只有 Flutter 平台脚手架，移动端采集
  适配器尚未实现。
- `src/ustc_assistant/bridge/` 已实现认证回环协议、采集作业、登录恢复和取消，
  以及只读 Agent 使用的 Bridge Query Protocol 1.0 查询作业（`ReadQueryJobManager`，
  与采集作业分离）；移动端 `SourceGateway` 尚未实现。
- 只读校园 Agent 已实现（`app/lib/features/agent/`）：共享平台无关核心 + Windows
  适配器（DPAPI 保护 Key、Python 查询网关）。修复轮各 Task 在 `feature/read-only-agent`
  分支上实现并已合并到 `main`（合并提交 `9bc83c8`）；最终修复后的精确 HEAD 在
  `docs/read-only-agent-handoff.md` 第 7 节最终验证时记录，不在本文件硬编码（后续提交
  会改写哈希）。本地导航 chip 可交互
  （`ActionChip` 经 GoRouter 跳转），公开引用 chip 仍不可交互（临时引用到来源 URL 的
  解析为合并后工作）。
- Windows C++ 工具链已安装，Release 可构建。自动验证结果在最终验证时更新记录于
  `docs/read-only-agent-handoff.md` 第 7 节；自动测试只验证代码行为，不代替人工验收。
- 第一轮 Windows 首版真实手工验收已经完成并产生修复；修复后的完整人工复测仍未
  结束。只读 Agent 的人工验收（真实 Key + 校园网/iWAN + 学校登录）尚未执行。不得
  把自动测试通过写成人工验收通过，详情见 `docs/read-only-agent-handoff.md` 和
  `docs/acceptance/read-only-agent.md`。

### 目录职责

```text
src/ustc_assistant/
  __main__.py              python -m ustc_assistant 入口
  cli.py                   参数、脱敏状态输出和 service 编排
  common/
    browser.py             可见 Edge 持久会话及生命周期
    storage.py             UTF-8 JSON 和显式原始文件写入
  bridge/                  Windows Flutter 使用的认证回环采集 Bridge
  sources/
    jw/
      collector.py         登录、动态上下文和课程/考试页面采集
      course.py            课程 datum 解析与 legacy 规范化
      exam.py              考试 HTML 解析与 legacy 规范化
      service.py           合并课程和考试
    young/
      enrolment.py         当前报名中活动列表
      schedule.py          已报名日程和北京时间滚动窗口
    icourse/
      client.py            公开 HTTP、一次性 token 和 24 小时缓存
      parser.py            搜索、课程和教师公开页面解析
      service.py           教务分组、匹配、排序和代表性点评
    campus/
      teach.py/finance.py  教务处和财务处独立目录/详情适配器
      catalog.py           本地目录、稳定身份、刷新和检索
      detail.py            按目录 ID 读取详情、附件和 30 天缓存
      service.py           五个公开目录的应用级编排

tests/
  test_cli.py              CLI 和公共浏览器/存储边界
  bridge|contracts|config/ Bridge、SourceBundle 和共享配置测试
  jw|young|icourse|campus/ 与来源模块对应的单元和回归测试
  fixtures/                合成网页、回归样例和 SourceBundle 契约样例

docs/
  architecture.md          Python、Bridge、Flutter 与未来移动端边界
  data-sources/            已实现来源契约及 SourceBundle 正式契约
  schedule-data-model.md   Flutter 本地日程领域模型
  read-only-agent-handoff.md 当前实现、Agent 计划、验证边界和接手顺序
  superpowers/specs/       首版设计及后续设计依据
  superpowers/plans/       已执行的历史实施计划；复选框不是实时进度

schemas/
  source-bundle-1.0.schema.json  Flutter 正式导入的机器契约

README.md                  安装、CLI 命令和输出路径
pyproject.toml             Python 包、依赖和命令入口
app/
  lib/core/                Drift 数据库、安全与北京时间工具
  lib/features/            账号、同步、导入、日程、Task、提醒、历史、设置和只读 Agent
  lib/features/agent/      共享只读 Agent 核心（domain/application 平台无关 +
                           data/presentation Windows 适配器）
  test/                    Flutter 单元、数据库、Widget、Golden 和流程测试
  windows|android|ios/     Flutter 平台工程；当前真实运行目标是 Windows
tmp/、temp.md              私有调试数据，不是代码或正式契约
```

`scripts/` 当前没有正式运行入口。不要重新引入已经清理掉的平行脚本；新能力优先
进入 `src/ustc_assistant/` service 和统一 CLI。

### 数据流

当前开发与验收：

```text
学校/公开网站
  -> source collector/client
  -> parser/normalizer
  -> source service
  -> cli.py
  -> tmp/ 中的本地规范化 JSON
```

当前 Windows App：

```text
source service
  -> 临时 localhost Python Bridge
  -> SourceBundle 1.0
  -> Flutter ImportService
  -> Drift/SQLite + UserOverlay
```

未来 Android/iOS 只替换采集适配器，不能改变 SourceBundle、ImportService 和本地
领域模型的语义。

### 新 Agent 阅读和修改路径

- 来源采集或解析问题：先读对应 `docs/data-sources/*.md`，再读
  `src/ustc_assistant/sources/<source>/` 和同名测试目录。
- CLI、输出路径或命令问题：读 `README.md`、`cli.py` 和 `tests/test_cli.py`。
- SourceBundle 迁移：先读 `docs/data-sources/source-bundle-v1.md`、Schema 与
  `tests/fixtures/source-bundle/` 和 `app/test/fixtures/source_bundle/`，再同步修改
  Python 生产者与 Flutter 消费者；不要让 Flutter 兼容 legacy。
- 接手当前项目：先读 `docs/read-only-agent-handoff.md`，再读本文件和
  `README.md`。历史
  plan 中未勾选的复选框不代表代码未实现，以代码、测试和当前状态文档为准。
- 整体重构相关工作：先读 `docs/refactor-docs/00-index.md` 与 01–06 模块文档，
  再按"整体重构与正式版路线"一节的六层阶梯顺序产出 07–13 号设计文档；14 为总体
  审查报告、15 为施工方法论（M0 起施工前必读）；重构代码一律进
  `rewrite/flutter-native` 分支（main 冻结期只接受致命 bug 修复）。
- Flutter 日程和 App 修改：先读
  `docs/superpowers/specs/2026-07-26-first-windows-milestone-closure-design.md`
  掌握首版总边界，再读 `schedule-data-model.md` 和 App Shell、Auth/Sync、Task、
  Personal CalendarEvent 四份详细 spec，以及对应 `app/lib/features/` 和测试。
- Windows 首版验收修复：读
  `docs/superpowers/specs/2026-07-27-first-milestone-acceptance-repairs-design.md`
  和对应实施计划。用户填写的验收文件可能带有未提交本地结果，不得覆盖或替用户
  把失败项改为成功。
- 修改网站契约时同步更新来源文档和回归测试；修改跨端导入字段时同步更新正式
  契约、Schema、fixture、Python 生产者测试和未来 Flutter 消费者测试。
- `tmp/`、`temp.md`、原始响应和浏览器 Profile 只用于本机研究，不能作为稳定输入
  或提交内容。

## 强制安全规则

红线原文不在此维护（安全/产品/过程三类）。唯一权威：
`docs/refactor-docs/07-constitution.md`——§2.1 安全红线五原则、§2.2 产品不变量、
§2.3 过程红线、§2.4 旧房专属约束、§2.5 降级移交登记。修改红线请改宪法并落 ADR，
本文件只保留此指引。

## 开发规则

- Python 使用 Conda 环境 `ustc_assistant`，最低版本 3.10。
- 时间统一使用 `Asia/Shanghai`（目标态归属见 `docs/refactor-docs/07-constitution.md` §2.5 → D14）。
- 当前教务自动同步默认学期为 `semesterId=461`、产品键 `2026fall`、显示名
  “2026 秋季学期”；不得根据年份推算教务内部学期 ID。Flutter 侧学期默认值由
  `config/source-defaults.json` 生成（写工具里程碑 Task 6），当前生成值仍为
  `461 / 2026fall / 2026 秋季学期`（此为旧房现状；新房默认学期改为月份规则
  （2–6 春季 / 7 夏季 / 8–12 秋季 / 1 月=上一年秋季）从抓取列表选取，见
  `docs/refactor-docs/07-constitution.md` D30/ADR-009）。
- 网站契约变化时明确失败，不返回部分数据冒充完整结果。
- 修改来源行为时先增加回归测试。
- 各来源保留独立 DOM、接口和解析规则，只共享浏览器生命周期、存储和 CLI 编排
  （旧房现状纪律；目标态重述见 `docs/refactor-docs/07-constitution.md` §2.4）。
- 重构期间（到 M7 为止）：main 冻结为旧版 release 基线，只接受致命 bug 修复；
  新功能与重写代码一律进 `rewrite/flutter-native` 分支；设计文档
  （`docs/refactor-docs/`）可随时进 main。同一来源同一时刻只允许一个通道在跑、
  在写库（原生或 Python Bridge 二选一）。
- 手工编辑使用 `apply_patch`，不要改写无关文件，不覆盖用户未提交修改。

## 验证

```powershell
conda run -n ustc_assistant python -m unittest discover -s tests -v
conda run -n ustc_assistant python -m compileall -q src tests
Push-Location app
E:\flutter\flutter\bin\flutter.bat analyze
E:\flutter\flutter\bin\flutter.bat test
E:\flutter\flutter\bin\flutter.bat build windows --release
Pop-Location
```

### 只读 Agent 自动验证

只读 Agent 修复轮与写工具/人工验收修复轮的精确 HEAD 与完整自动验证结果在最终验证时
记录于 `docs/read-only-agent-handoff.md` 第 7、7.1、7.2 节（不在本文件硬编码哈希，
后续提交会改写）。组合级集成测试聚焦套件（`agent_composition_flow_test.dart` +
`read_only_agent_flow_test.dart` + `milestone_accessibility_test.dart`）全部通过，
覆盖真实路由 + 注入式组合的配置、本地日程分组摘要、同作业二课暂停/恢复、账号切换、
网关释放与捕获请求隐私，以及 Task 10 合并验收回归（自由聊天、首次漏调纠错、历史
标题定位写目标、冲突查询不做参与者查找、PlanBlock 周网格、派生冲突优先序、整日
移动/清除/撤回、本地 chip 分区路由、账号隔离）。

- 真实人工验收（真实 Key + 校园网/iWAN + 学校登录）尚未执行；清单见
  `docs/acceptance/read-only-agent.md` 第 1–11 节（§1–9 只读 Agent 主体、§10 写
  工具、§11 修复复测）。自动测试不代替人工验收：学校
  API 与学校网站从不进入自动测试。Python 校园（campus）与 iCourse 体验未改变，
  `agent-testing.md` 第 13-15 项等待 Flutter 来源迁移。

### Windows 首版自动验证（2026-07-28）

- Python：267 项测试通过，`compileall` 通过。
- Flutter：203 项测试通过，`flutter analyze` 无问题。
- Windows：Release 构建成功，输出目录为
  `app/build/windows/x64/runner/Release/`。
- 第一轮人工验收发现的完整快照可见性、顺序同步、重新认证、日程与 Task 详情、
  截止时间选择、完全重置和首次登录同步退出问题均已有代码修复与回归测试；仍需
  用户按验收文档复测，不能视为最终人工验收结论。

### 最近真实验收（2026-07-22）

- 教务链路：成功生成 241 个事件、241 条来源记录和 15 条日程关系，事件身份无重复，规范化输出未发现登录或动态上下文敏感键。
- 二课报名中列表：成功采集 2 页共 15 条活动，页面报告总数与规范化输出一致。
- 二课我的日程：按北京时间查询 2026-07-15 至 2026-08-22 共 39 天，当前返回 0 条日程；39 个空日响应完整，因此是有效空快照。
- 评课社区联动：241 个课表事件在本地折叠为 13 个开课组，13 组均完成公开内容匹配；输出不含用户 ID、课表时间或登录敏感键。

### 校园公开信息真实验收（2026-07-23）

- 五个公开目录均刷新成功：教务通知 3 条、教务学生服务 33 条、财务通知 0 条、财务公开信息 7 条、财务业务指南 57 条有效记录。
- 通知日期全部位于北京时间 7 天窗口内；本地关键词查询返回结果且未触发额外网络请求。
- 教务详情正文读取成功，重复读取命中 30 天缓存且时间戳不变；财务 PDF 型指南识别为 1 个公开 PDF 附件。
- 规范化结果未发现 Cookie、认证信息、用户 ID、浏览器 Profile 路径或请求查询参数。

## 产品约束

产品不变量与相关契约细节的原文不在此维护。唯一权威：
`docs/refactor-docs/07-constitution.md`——§2.2 产品不变量、§2.4 旧房专属约束、
§2.5 降级移交登记；实施期细则随对应层设计文档（`09-contracts.md` 等）落地。
本文件只保留此指引。

## 整体重构与正式版路线（2026-08 商定）

### 背景与决定

- 离正式版的两大核心任务：① Python 逻辑全部迁移到 Flutter 原生；② 完善 Agent
  harness。迁移在 `feature/flutter-native-jw-v2` 分支试做时出现 debug 困难：
  最后一批提交全部在补"导航就绪归属、URL/事件顺序、ready 握手"等横切问题，
  病根是缺少**一次设计、五条链路共用的"原生采集引擎"层**，共享基础设施被当作
  单链路附属品硬做。
- 已决定：**从零重写代码，但设计先行、分层敲定**，强化整体性。旧版 main 冻结为
  可回退基线；重写按里程碑推进，每步应用可运行、可验收、可回退。
- 准备工作已完成：`docs/refactor-docs/00-index.md` + 01–06 六份模块技术文档
  （以 main 代码为准，含四契约锚点、三条端到端链路、各模块开放决策与存疑清单）。

### 设计阶段：六层阶梯（写代码前，自上而下，每层有 gate）

| 层 | 敲定内容 | 产出物 | gate（完成标准） |
|---|---|---|---|
| 0 原则与决策 | 不可变红线；决策按单向门/双向门分类，只提前敲死不可逆项 | `07-constitution.md` + ADR 日志 | 红线清单与待决策项全部归类 |
| 1 容器切分 | 系统边界、容器级块（来源作业仲裁/采集引擎/导入存储/Agent/UI）、依赖方向、技术选型 | `08-target-architecture.md` | 全部链路（三条主 E2E + 两条账号生命周期子链路）能用容器名走通，职责无重叠无缺口 |
| 2 全局契约 | 跨容器接口签名：SourceBundle/QueryResult 去留、DB schema、各 Gateway、作业暂停-恢复模型 | `09-contracts.md` | 每个接口有生产者和消费者，无孤儿字段 |
| 3 链路走查 | 三条 E2E 链路 + 每条数据链路的 fetch→normalize→validate→import 管道 | `10-runtime.md` | 序列图走通，无死胡同 |
| 4 组件设计 | 逐容器内部：采集引擎导航就绪状态机、作业状态机等 | `11-component-designs.md` | 每个状态机有完整转移表（状态全集+转移+失败态） |
| 5 横切关注 | 时区、隐私、账号隔离、事务、审计、可观测性（一等设计目标） | `12-cross-cutting.md` | 每项有单一归属 |
| 6 风险验收 | 各模块文档 §10 存疑收敛成风险登记册，每条配验证方式 | `13-risks-and-acceptance.md` | 每条风险有关闭标准 |

规则：上一层 gate 未过不得进入下一层；第 4 层不必一次做完，M1 后可"每做一块组件、
先补一块设计"。方法依据：文档先行开发、Spec Kit（constitution→specify→plan→
tasks→implement）、arc42 结构、C4 分层纪律、ADR 决策记录、单向门/双向门分类。

### 并存方案（旧房/新房）

- **代码层**：main 冻结为 release 基线（只修致命 bug，不加功能）；重写在
  `rewrite/flutter-native` 长分支 + 专属 worktree，M7 验收前不合并回 main。
  设计文档（`docs/refactor-docs/` 新产出）随时进 main；代码只在 M7 整体回流。
- **运行时层**：每个来源一个通道接口（第 2 层定死），`NativeXxxGateway` 与
  `PythonXxxGateway`（Bridge 客户端）并存，按来源配置选择；**同一来源同一时刻
  只有一个通道在跑、在写库**；M7 删除全部 PythonXxxGateway + Bridge。
- **数据层**：schema 以 v7 为界——旧房止步 v7，新房 v8+ 只走正式迁移；升级即
  单向搬家（Drift 版本检查拦旧房）；发布前用真实备份库演练；保留旧房安装包与
  数据备份作为回退通道。
- **四铁律**：契约是唯一共同语言；一库一主、一源一通道；旧房永远可住；
  新房每里程碑 analyze/test/build 全绿才算盖完。

### 里程碑（每步 App 可用、可验收、可回退）

| 里程碑 | 内容 | gate |
|---|---|---|
| M0 骨架 | 按 0–2 层建分层工程 + fake source 打穿全链路的 Walking Skeleton + ChannelRegistry 开关 + CI（施工纪律见 `docs/refactor-docs/15-construction-methodology.md`） | analyze/test/build 全绿 + fake 源 E2E smoke 契约测试通过 |
| M1 存储核心 | v7 基线 27 表 + v8 变更集（schema 决策落地）+ 导入流水线 + 派生链路 + v7→v8 迁移器 | oracle bundle fixture 全导入通过；迁移测试通过 |
| M2 采集引擎 + JW | 引擎（会话/导航状态机/事件顺序/可观测）+ 首个适配器 | fixture 全流程 + 逐字段对比 Python oracle + 真实教务人工验收 |
| M3 二课双链路 | young-schedule（Bundle）+ young-enrolment（查询侧，含登录恢复） | 同上标准 |
| M4 icourse + campus | 纯 HTTP 型 | 同上标准 |
| M5 壳层 + 日程 UI + 账号 | UI 重建回新骨架（受影响最小，代码可移植） | 所有保留能力对应的 Flutter 测试迁移并通过；file-origin 测试按 ADR-021 明确排除，M1 以正式 Bundle fixture 契约测试替代 |
| M6 harness 迁移 + 完善 | 推理循环/工具/审批门原样重建；`WindowsPythonQueryGateway` 换原生实现；harness 完善项落地 | Agent 组合级集成测试 + 真实 Key 人工验收 |
| M7 Bridge/Python 退役 | 删 Bridge、PythonLocator，CLI 决策落地 | 全链路真实验收，无 Python 依赖 |
| M8 发布硬化 | 性能、稳定性、backlog 决策项 | 验证阶段全项通过 |

- 两条主线在 M6 汇合；M2–M6 期间未完工来源经 PythonXxxGateway 临时兜底（到 M7 删除）。
- 抢救资产：v2 分支的 loopback fixture 服务器、python-oracle 对比工具
  （`compare_jw_bundles.dart`）、fixture 数据在 M2 直接复用，不当作返工对象。
- 学校页面里程碑的真实人工验收当场做、不攒到最后（验收红线权威见 `docs/refactor-docs/07-constitution.md` §2.3-1）。

### 上线前流程

实施计划（任务单：依赖+测试要求+验收人）→ 里程碑实施（契约测试先行、oracle 对比
贯穿、每日三件套）→ 多级验证（自动测试全集 / 五链路与 Agent 真实验收 / 可靠性专项
（清空各文档 §10 并发存疑）/ 真实备份库迁移演练 / 性能 / 同学内测）→ 发布准备
（Release 构建、MSIX 决策、文档、go/no-go 清单、保留旧版回滚）→ 上线 → 运营
（反馈渠道、P0 hotfix、backlog 聚批）。