# 阶段索引

阶段任务、过程与用户关闭分开维护。当前状态由 [状态页](../status.md)汇总，施工方法由 [工作流](../workflow.md)定义。

| 阶段 | 范围 | 任务单 | 实施记录 | 用户验收 |
|---|---|---|---|---|
| 可选模型服务 | 保留学校，增加固定 DeepSeek 官方 Key 接入 | [任务单](model-providers/plan.md) | [记录](model-providers/records.md) | 实际官方 Key/速度由用户在应用主动配置后核验；不关闭 A7/A8 |
| M0 | 本地合成基础链路 | [计划](m0/plan.md) | [记录](m0/records.md) | [2026-10-09 关闭](m0/acceptance.md) |
| M1 | JW 自动采集与本地日程 | [计划](m1/plan.md) | [记录索引](m1/records.md) | [2026-10-10 关闭](m1/acceptance.md) |
| M2 | Young 活动关联日程/独立只读查询 | [计划](m2/plan.md) | [记录索引](m2/records.md) | [2026-10-11 关闭](m2/acceptance.md) |
| M3 | 为未来 Agent 准备内部公开查询与长期 Markdown 知识库 | [任务单](m3/plan.md) | [研究与实现](m3/records.md)，根工程检查、有限公开契约与实际随包资料核验完成，临时界面可选 | [2026-10-12 关闭](m3/acceptance.md) |
| M4 | Agent 接入前的 Windows 应用可用版 | [任务单](m4/plan.md) | [记录](m4/records.md)，四个子阶段工程检查完成 | [M4.1–M4.4 及 M4 总体已验收关闭](m4/acceptance.md)，2026-10-13 |
| M5 | 学生事务 Agent 与受控运行环境 | [详细任务单](m5/plan.md)，§23 已批准并完成工程 | [工程索引](m5/records.md)，最新[记录 12](m5/records/12-context-and-permission-implementation.md)有根全套/Windows/Release 证据 | [2026-10-15 关闭](m5/acceptance.md#阶段关闭2026-10-15)，不补造逐项真人结果，语音与其他未观察项保留 |
| M6 | 每日晨报与 Windows 系统日程提醒 | [任务单](m6/plan.md) | [记录](m6/records.md)，含日期窗口/紧凑展示修订与根全套 | [2026-10-15 关闭](m6/acceptance.md#阶段关闭2026-10-15)，未观察项保留 |
| Windows 收尾与1.00 | 已批准修复、每日二课及本地私有交付收口 | [任务单](windows-polish/plan.md) | [研究与实施](windows-polish/records.md) · [1.00交付记录](windows-polish/records/05-windows-v1-private-release.md) | [用户认可1.00基线](windows-polish/acceptance.md)，暂不公开发布；APK另按下行迁移计划推进 |
| Android APK迁移（A0–A8） | 同一Flutter核心、Android平台/手机体验及APK鸿蒙实证 | [完整计划](android-apk/plan.md)，2026-10-16已批准 | [A0原生准入](android-apk/records/01-a0-runtime-probes.md) · [A1底座](android-apk/records/03-a1-platform-bootstrap.md) · [A2学校桥](android-apk/records/04-a2-school-bridges.md) · [A3 Agent/公开能力](android-apk/records/06-a3-agent-public.md) · [A4手机界面/文件](android-apk/records/07-a4-phone-files.md) · [A5提醒/前台作业](android-apk/records/08-a5-reminders-and-foreground.md) · [A6本地听写](android-apk/records/09-a6-local-speech.md) · [A7初轮](android-apk/records/10-a7-emulator-validation.md) · [MuMu完整旅程20](android-apk/records/20-mumu-full-journeys.md) · [受控补验21](android-apk/records/21-mumu-provider-and-remaining-checks.md) · [鸿蒙目录生命周期22](android-apk/records/22-android-owner-lifecycle.md)；[研究依据](../research/android-apk-migration.md) | A7模拟器部分完成，未真人关闭；[设备矩阵](android-apk/device-matrix.md)与[当前QA说明](android-apk/manual-validation.md)区分历史失败、当前学校链路/审批/竖屏实证及目标机/鸿蒙等保留项，A8未正式交付 |

跨端界面重构已按[任务单](ui-refresh/plan.md)完成工程、根自动验证、实际图像复核和独立体验构建；[安装与交付记录](ui-refresh/records.md)单独维护，尚未体验关闭。该阶段简化 Agent、日程任务、设置的层级，不改变 Android 迁移范围或 Windows1.00 的原交付结论。

M5/M6 的批准范围、接口、分切片和验收条件统一见各任务单，实际工程与真人结论分开记录。两阶段已由用户整体确认关闭；未单独反馈的真人项目、Windows重启/睡眠等保持未观察，不把阶段关闭当完整 V 项已关闭。Windows收尾保留原数据、工具与权限行为，具体体验修订见当前任务单。

M3 不建独立用户查询入口，也不生成或注册 Agent 工具，临时界面只验收同一内部能力；时效通知排除入库。2026-10-12 用户批准恢复，首批为 7 份选定长期材料，历史研究和样稿保留。每阶段维护一份计划，不采用历史旧 M0–M8 定义。
