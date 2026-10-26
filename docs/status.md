# 项目当前状态

更新时间：2026-10-26。已发布平台进入维护/修复阶段，主线`main`、主工程`E:\107\main`；[仓库交接](milestones/maintenance-handoff/records.md)保存实际结果。本页只汇总当前结论；具体批准和验收以相应记录为准。

| 阶段 | 当前状态 | 范围与依据 |
|---|---|---|
| iOS 私用 | 调研方案已整理，实施待批准 | [唯一任务单](milestones/ios-private/plan.md)、[研究记录](milestones/ios-private/records.md)。目标iPhone 15 Pro/iOS 27，无自有Mac；GitHub账号找回期间首选Codemagic邮箱个人免费账号加校内公开HTTPS源，不以GitHub为I0前置。云端Mac构建、Windows本机签名与7天续签，Widget共享/扩展重签先做探针。只读调研与官方声明不等于构建或真机通过；尚未创建工程、安装、配置云账号或触发采集 |
| 开源与公开安装包 | 已公开发布1.0.0，六份匿名下载核验通过 | [发布与下载](releases/public-1.0.0.md)、[任务单](milestones/open-source-release/plan.md)、[实际记录](milestones/open-source-release/records.md)、[用户确认](milestones/open-source-release/acceptance.md)。原创代码Apache-2.0；校内项目Public，v1.0.0绑定已构建9515e50a，Windows完整ZIP与长期签名Android双ABI包及三份说明/清单已上传。项目/Release匿名页面HTTP200，六份完整下载619783706字节及SHA-256全部匹配。analyze、共享全套、相关原生/打包、自有API34安装/保留与限定源码审计证据保留；校内CI此时pending，不列为通过。旧私有交付与实机等未观察项保留 |
| 维护与Git交接 | 已完成，进入维护/修复 | [任务单](milestones/maintenance-handoff/plan.md)、[实际记录](milestones/maintenance-handoff/records.md)、[授权与结果](milestones/maintenance-handoff/acceptance.md)。主工程与当前会话为E:\107\main、维护分支main，交接工作树已移至worktrees/maintenance-handoff，唯一共用元数据为main/.git。旧main/放弃版48/3条状态保留，96个私有交付文件未变；GitHub和校内main正常向前同步。新根离线依赖/analyze、文档、打包及合成迁移通过；此前目录共享冲突的失败记录保留，后续使用短期codex/fix-*维护 |
| 首次设置与main图标 | 工程与构建完成，纳入双平台当前私有交付 | [记录23](milestones/android-apk/records/23-onboarding-and-brand.md)：四页可跳过/续行、独立授权与恢复日志；新安装引导、升级用户从设置进入，schema20保留资料。最终analyze、1654项共享/1跳过、相关Windows/Android原生检查及双ABIQA4024/2024、独立Windows暂存核验通过。用户总体反馈不补造逐页引导验收；旧Windows包保留，当前Windows刷新见下行 |
| 可选模型服务 | 官方最小真实能力检查通过；当前私有包见QA说明 | [任务单](milestones/model-providers/plan.md)、[决定](decisions/model-providers.md)和[记录](milestones/model-providers/records.md)。两方受保护配置隔离；QA4019中根仅触发一次4请求能力检查，文本/流式/合成工具往返通过，后续业务使用学校。[受控补验21](milestones/android-apk/records/21-mumu-provider-and-remaining-checks.md)与[当前QA](milestones/android-apk/manual-validation.md)分开记录，不推断完整官方业务、图片、速度或账单，不关闭A7/A8 |
| M0 | 已关闭，2026-10-09 | 本地合成链路、目录/事务/取消恢复；[用户验收](milestones/m0/acceptance.md) |
| M1 | 已关闭，2026-10-10 | JW 身份/只读契约、自动认证/选期、事务与本地日程；[用户验收](milestones/m1/acceptance.md) |
| M2 | 已关闭，2026-10-11 | Young 活动关联日程和独立报名活动只读查询、全自动及生命周期/连续性；[用户验收](milestones/m2/acceptance.md) |
| M3 | 已关闭，2026-10-12 | 内部评课/校园查询及首批 7 项长期 Markdown，临时界面可选，无 Agent/工具注册；[关闭依据与保留项](milestones/m3/acceptance.md) |
| M4 | 已关闭，2026-10-13；M4.1–M4.4 均已验收 | [任务单](milestones/m4/plan.md)：Windows 应用壳、日程/个人安排、任务/手工时间规划、设置与持久维护恢复及集成；[分段与总体验收](milestones/m4/acceptance.md)，[实际记录](milestones/m4/records.md)。不接模型/工具 |
| M5 | 已关闭，2026-10-15 | 用户明确确认关闭；[关闭依据及保留项](milestones/m5/acceptance.md#阶段关闭2026-10-15)。[最新工程证据](milestones/m5/records/12-context-and-permission-implementation.md)为 analyze、1214 项/1 平台跳过、九套 Windows 29 组和 Release；不补造逐项真人结果，已知语音问题继续登记 |
| M6 | 已关闭，2026-10-15 | [用户关闭](milestones/m6/acceptance.md#阶段关闭2026-10-15)：06:00后晨报、两槽/Windows退出提醒；日期窗口与展示修订、1314项/1跳过及相关Windows/Release见[记录03](milestones/m6/records/03-morning-window-and-presentation.md)，未观察项保留 |
| Windows 1.00 | 当前私有包已刷新至441a68b/schema20；未公开发布 | [刷新授权](milestones/windows-polish/acceptance.md)、[记录06](milestones/windows-polish/records/06-windows-private-refresh.md)、[交付说明](releases/windows-1.00.md)。沿用已验证普通Release与完整工程证据；本轮17项打包合成检查、36项运行载荷/39项便携目录与ZIP独立校验通过，许可/图标/manifest齐全。旧1.00包及原默认Release保留，正式资料未打开，身份/DPAPI/通知用途不变；schema20升级后不可直接用旧程序读取，新机器和原未观察项保留 |
| Android APK迁移 | MatePad日常使用获认可，目录故障实机复验通过；按现有QA身份私有交付 | [用户验收](milestones/android-apk/acceptance.md)确认HarmonyOS4.2.0后台返回问题未再出现，保留历史失败及[工程反例22](milestones/android-apk/records/22-android-owner-lifecycle.md)。用户选择沿用QA身份保留资料，双ABI包、说明、许可和校验见[交付](releases/android-private-1.00.md)与[收尾24](milestones/android-apk/records/24-private-handoff.md)。MuMu真实旅程及官方合成结果按[设备矩阵](milestones/android-apk/device-matrix.md)分别登记；当前QA收尾不等于A7全部逐项验收或A8正式Release。真实麦克风、06:00、厂商通知策略及来源拒绝解释复测等继续披露 |
| 跨端界面重构 | 工程、自动检查和私有体验构建完成；用户体验待确认 | [任务单](milestones/ui-refresh/plan.md)明确风格、布局、接口不变量与验收；两项Skill已安装，详见[记录](milestones/ui-refresh/records.md)。白色画布、细分隔线、平面分区，保留Agent、日程任务、设置与审批功能。最终analyze、1558项/1平台跳过、Windows相关21项、API34合成4项与实际图像复核通过；Android构建/lint/签名和独立Windows暂存Release已核验，未提前关闭本轮体验或A7/A8 |
| 后续 | 公开版进入维护；旧QA继续保留，按反馈修复 | [已知问题](releases/known-issues.md)保留06:00整点/长期挑战退避、业务内容对应、真实麦克风、真机通知/厂商策略、来源撤回/调休、非空考试及模型解释复测等。MatePad目录故障已获用户补验，不再列为待确认。其他机型、整体UI逐项体验及原生鸿蒙仍单独定界，公开发布不关闭完整风险项 |

## 已批准范围与待验证

用户于2026-10-17明确批准[A7-W1–W6普通系统WebView兼容修订](milestones/android-apk/plan.md#a7普通系统webview兼容修订已批准)及[执行环境与清理取舍](decisions/android-system-webview-compatibility.md)，已实现并完成[根合成回归和QA交付](milestones/android-apk/records/12-ordinary-system-webview.md)。旧高级后端失败保留；当轮普通路线在API28/29/32/34及当前提供方分别取得新证据，未操作用户MuMu或正式资料，不将工程通过当作真实学校/目标机验收。

五条来源、本地日程、任务和 Agent 的总体范围保留。评课/校园内部能力已按 M3 关闭，Agent 接入前的 Windows 应用已按 M4 验收。M5 已装配单 Agent、查询/证据/图片、本地修改/撤销、有界规划、固定学校来源协调、单一持续对话与 compact/clear、可撤销的记住授权、任务截止栏、安全诊断/导出及本地中文听写。§23 已落实完整安全交互、稳定 19 工具、跨轮目标定位、独立私人读取/17 类日常许可、仅建议硬模式、当前卡文字确认、估算预算与实际回执恢复，并完成根全套/Windows/Release，详见[记录 12](milestones/m5/records/12-context-and-permission-implementation.md)。用户于 2026-10-15 明确确认关闭 M5 和 M6；这是阶段整体关闭，不推断前述清单逐项操作、新业务计数或独立模型评分。原确认后失去目标的失败记录保留；可选合成模型核验需用户在应用主动启动，根未运行真实模型。真实听写“I.”及“未识别出语言”未取得新修复/复验反馈，继续作为已知问题，不由阶段关闭改写为通过。

M6 已按批准范围完成晨报、系统提醒与后续修订，工程/原生证据及未观察项见[记录](milestones/m6/records.md)，用户关闭见[验收](milestones/m6/acceptance.md#阶段关闭2026-10-15)。Windows收尾包含已反馈的体验问题、Agent提醒扩充、[整体联动终审](milestones/windows-polish/records/02-windows-integration-review.md)、用户批准的[来源失效修订](decisions/source-occurrence-retirement.md)及[每日二课同步](milestones/windows-polish/records/04-young-daily-sync.md)，实际结果见[研究与实施](milestones/windows-polish/records.md)。每日同步需独立启用，不消耗模型额度、退出后不运行，挑战或无保存凭据不循环登录；未取得真实每日自动同步的新人工反馈。用户此前认可Windows 1.00私有基线，本次1.0.0公开授权与结果见发布行；移动专项补验与完整V项继续登记，已知问题不因发布清零。

M3 的内部 v1 接口、首批逐份目录、匿名公开 HTTP、中文检索/正文续读、schema 5 增量迁移和材料事务维护已装配。根已执行工程检查、构建、有限公开契约复验和实际随包资料原生链路核验；用户接受阶段结论并确认关闭，不记作亲自完成临时界面三组操作。财务在线关键词/FAQ 回复保持 unavailable，政策现行性及本轮真实自动直连回退未核验。关闭证据与保留项统一见 [M3 验收](milestones/m3/acceptance.md)，详细命令和失败见 [M3 记录](milestones/m3/records.md)。

JW 真实非空考试经用户批准后补，保持未观察；首次无历史学期的日期匹配有本机证据，不补造独立真人反馈。Young 按用户批准导入学校个人日历中的活动关联记录，排除未关联记录，不能据此宣称独立验证本人报名成功/取消；真实未关联样本、缺失/撤回等未观察项保留。

完整触发条件与当前证据范围见 [13 验证登记](quality/13-risks-and-acceptance.md)，来源细节见 [契约参考](reference/sources/README.md)。历史失败与实际检查留在 [阶段记录](milestones/README.md)，不改写为通过。没有新的脱敏摘要时不推断验收后累计计数。

## 文档整理

现行设计、工作流、来源参考、阶段证据和历史原文已分开；[维护规则](maintaining.md)规定各自归属。[整理前快照](archive/README.md)完整保存原文，旧路径保留迁移导航。
