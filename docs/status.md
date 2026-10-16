# 项目当前状态

更新时间：2026-10-16。分支 `codex/design-reset`，工作区 `E:\107\.worktrees\rewrite\design-reset`。本页只汇总当前结论；具体批准和验收以相应记录为准。

| 阶段 | 当前状态 | 范围与依据 |
|---|---|---|
| M0 | 已关闭，2026-10-09 | 本地合成链路、目录/事务/取消恢复；[用户验收](milestones/m0/acceptance.md) |
| M1 | 已关闭，2026-10-10 | JW 身份/只读契约、自动认证/选期、事务与本地日程；[用户验收](milestones/m1/acceptance.md) |
| M2 | 已关闭，2026-10-11 | Young 活动关联日程和独立报名活动只读查询、全自动及生命周期/连续性；[用户验收](milestones/m2/acceptance.md) |
| M3 | 已关闭，2026-10-12 | 内部评课/校园查询及首批 7 项长期 Markdown，临时界面可选，无 Agent/工具注册；[关闭依据与保留项](milestones/m3/acceptance.md) |
| M4 | 已关闭，2026-10-13；M4.1–M4.4 均已验收 | [任务单](milestones/m4/plan.md)：Windows 应用壳、日程/个人安排、任务/手工时间规划、设置与持久维护恢复及集成；[分段与总体验收](milestones/m4/acceptance.md)，[实际记录](milestones/m4/records.md)。不接模型/工具 |
| M5 | 已关闭，2026-10-15 | 用户明确确认关闭；[关闭依据及保留项](milestones/m5/acceptance.md#阶段关闭2026-10-15)。[最新工程证据](milestones/m5/records/12-context-and-permission-implementation.md)为 analyze、1214 项/1 平台跳过、九套 Windows 29 组和 Release；不补造逐项真人结果，已知语音问题继续登记 |
| M6 | 已关闭，2026-10-15 | [用户关闭](milestones/m6/acceptance.md#阶段关闭2026-10-15)：06:00后晨报、两槽/Windows退出提醒；日期窗口与展示修订、1314项/1跳过及相关Windows/Release见[记录03](milestones/m6/records/03-morning-window-and-presentation.md)，未观察项保留 |
| Windows 1.00 | 用户已认可，私有收尾完成；未公开发布 | [版本决定](milestones/windows-polish/acceptance.md)、[1.00记录](milestones/windows-polish/records/05-windows-v1-private-release.md)、[交付说明](releases/windows-1.00.md)。analyze、1435项/1平台跳过、十套Windows37组及正式Release通过；本地ZIP/逐文件manifest/hash与许可完整，原路径已更新但本轮未启动。保留schema18、20工具、现有资料与通知身份；全新机器和原未观察项不补记通过 |
| Android APK迁移 | A2原生桥与合成链路通过；目标机/真实来源待验 | [A0–A8计划](milestones/android-apk/plan.md)、[A1底座](milestones/android-apk/records/03-a1-platform-bootstrap.md)、[A2实际记录](milestones/android-apk/records/04-a2-school-bridges.md)。教务/二课固定认证、读取、隔离与清理接入既有C1/C2/C3；支持隔离世界的官方独立镜像上完成合成链路。旧提供方缺能力时拒绝采集，资料恢复另行验证；不以API36的A0通过推断完整认证可用。SDK/缓存/AVD/临时目录继续E盘；暂无实机，鸿蒙、真实来源/模型和完整手机版未验收，旧数据/双端同步不在首版范围 |
| 后续 | A3 Agent与公开能力，其他切片按依赖推进；A2实机条件保留 | 模拟器与目标实机分别验证；私有APK、原生鸿蒙及Windows公开发布分别定界 |

## 已批准范围与待验证

五条来源、本地日程、任务和 Agent 的总体范围保留。评课/校园内部能力已按 M3 关闭，Agent 接入前的 Windows 应用已按 M4 验收。M5 已装配单 Agent、查询/证据/图片、本地修改/撤销、有界规划、固定学校来源协调、单一持续对话与 compact/clear、可撤销的记住授权、任务截止栏、安全诊断/导出及本地中文听写。§23 已落实完整安全交互、稳定 19 工具、跨轮目标定位、独立私人读取/17 类日常许可、仅建议硬模式、当前卡文字确认、估算预算与实际回执恢复，并完成根全套/Windows/Release，详见[记录 12](milestones/m5/records/12-context-and-permission-implementation.md)。用户于 2026-10-15 明确确认关闭 M5 和 M6；这是阶段整体关闭，不推断前述清单逐项操作、新业务计数或独立模型评分。原确认后失去目标的失败记录保留；可选合成模型核验需用户在应用主动启动，根未运行真实模型。真实听写“I.”及“未识别出语言”未取得新修复/复验反馈，继续作为已知问题，不由阶段关闭改写为通过。

M6 已按批准范围完成晨报、系统提醒与后续修订，工程/原生证据及未观察项见[记录](milestones/m6/records.md)，用户关闭见[验收](milestones/m6/acceptance.md#阶段关闭2026-10-15)。Windows收尾包含已反馈的体验问题、Agent提醒扩充、[整体联动终审](milestones/windows-polish/records/02-windows-integration-review.md)、用户批准的[来源失效修订](decisions/source-occurrence-retirement.md)及[每日二课同步](milestones/windows-polish/records/04-young-daily-sync.md)，实际结果见[研究与实施](milestones/windows-polish/records.md)。每日同步需独立启用，不消耗模型额度、退出后不运行，挑战或无保存凭据不循环登录；未取得真实每日自动同步的新人工反馈。用户现已认可Windows 1.00基线，同时明确暂不公开发布。移动实现、公开部署和完整V项仍未完成；已知问题随私有包列明，不伪造清零。

M3 的内部 v1 接口、首批逐份目录、匿名公开 HTTP、中文检索/正文续读、schema 5 增量迁移和材料事务维护已装配。根已执行工程检查、构建、有限公开契约复验和实际随包资料原生链路核验；用户接受阶段结论并确认关闭，不记作亲自完成临时界面三组操作。财务在线关键词/FAQ 回复保持 unavailable，政策现行性及本轮真实自动直连回退未核验。关闭证据与保留项统一见 [M3 验收](milestones/m3/acceptance.md)，详细命令和失败见 [M3 记录](milestones/m3/records.md)。

JW 真实非空考试经用户批准后补，保持未观察；首次无历史学期的日期匹配有本机证据，不补造独立真人反馈。Young 按用户批准导入学校个人日历中的活动关联记录，排除未关联记录，不能据此宣称独立验证本人报名成功/取消；真实未关联样本、缺失/撤回等未观察项保留。

完整触发条件与当前证据范围见 [13 验证登记](quality/13-risks-and-acceptance.md)，来源细节见 [契约参考](reference/sources/README.md)。历史失败与实际检查留在 [阶段记录](milestones/README.md)，不改写为通过。没有新的脱敏摘要时不推断验收后累计计数。

## 文档整理

现行设计、工作流、来源参考、阶段证据和历史原文已分开；[维护规则](maintaining.md)规定各自归属。[整理前快照](archive/README.md)完整保存原文，旧路径保留迁移导航。
