# 阶段索引

阶段任务、过程与用户关闭分开维护。当前状态由 [状态页](../status.md)汇总，施工方法由 [工作流](../workflow.md)定义。

| 阶段 | 范围 | 任务单 | 实施记录 | 用户验收 |
|---|---|---|---|---|
| 维护与Git交接 | main主线、统一总目录、旧成果保留与双远端同步 | [任务单](maintenance-handoff/plan.md) | [实际记录](maintenance-handoff/records.md) | [用户批准](maintenance-handoff/acceptance.md)，不扩大产品验收或公开分发范围 |
| 可选模型服务 | 保留学校，增加固定 DeepSeek 官方 Key 接入 | [任务单](model-providers/plan.md) | [记录](model-providers/records.md) | 实际官方 Key/速度由用户在应用主动配置后核验；不关闭 A7/A8 |
| M0 | 本地合成基础链路 | [计划](m0/plan.md) | [记录](m0/records.md) | [2026-10-09 关闭](m0/acceptance.md) |
| M1 | JW 自动采集与本地日程 | [计划](m1/plan.md) | [记录索引](m1/records.md) | [2026-10-10 关闭](m1/acceptance.md) |
| M2 | Young 活动关联日程/独立只读查询 | [计划](m2/plan.md) | [记录索引](m2/records.md) | [2026-10-11 关闭](m2/acceptance.md) |
| M3 | 为未来 Agent 准备内部公开查询与长期 Markdown 知识库 | [任务单](m3/plan.md) | [研究与实现](m3/records.md)，根工程检查、有限公开契约与实际随包资料核验完成，临时界面可选 | [2026-10-12 关闭](m3/acceptance.md) |
| M4 | Agent 接入前的 Windows 应用可用版 | [任务单](m4/plan.md) | [记录](m4/records.md)，四个子阶段工程检查完成 | [M4.1–M4.4 及 M4 总体已验收关闭](m4/acceptance.md)，2026-10-13 |
| M5 | 学生事务 Agent 与受控运行环境 | [详细任务单](m5/plan.md)，§23 已批准并完成工程 | [工程索引](m5/records.md)，最新[记录 12](m5/records/12-context-and-permission-implementation.md)有根全套/Windows/Release 证据 | [2026-10-15 关闭](m5/acceptance.md#阶段关闭2026-10-15)，不补造逐项真人结果，语音与其他未观察项保留 |
| M6 | 每日晨报与 Windows 系统日程提醒 | [任务单](m6/plan.md) | [记录](m6/records.md)，含日期窗口/紧凑展示修订与根全套 | [2026-10-15 关闭](m6/acceptance.md#阶段关闭2026-10-15)，未观察项保留 |
| Windows 收尾与1.00 | 已批准修复、每日二课及本地私有交付收口 | [任务单](windows-polish/plan.md) | [研究与实施](windows-polish/records.md) · [原1.00交付](windows-polish/records/05-windows-v1-private-release.md) · [2026-10-25刷新](windows-polish/records/06-windows-private-refresh.md) | [用户认可1.00基线及刷新授权](windows-polish/acceptance.md)，当前私有包441a68b/schema20，旧包保留；暂不公开发布 |
| Android APK迁移（A0–A8） | 同一Flutter核心、Android平台/手机体验及APK鸿蒙实证 | [完整计划](android-apk/plan.md)，2026-10-16已批准 | [原生与平台A0–A6](android-apk/records/10-a7-emulator-validation.md) · [MuMu完整旅程20](android-apk/records/20-mumu-full-journeys.md) · [补验21](android-apk/records/21-mumu-provider-and-remaining-checks.md) · [目录生命周期22](android-apk/records/22-android-owner-lifecycle.md) · [首次设置/图标23](android-apk/records/23-onboarding-and-brand.md) · [私有交付24](android-apk/records/24-private-handoff.md) | [用户验收](android-apk/acceptance.md)：MatePad日常使用总体认可、后台返回故障未再出现，沿用QA身份[私有交付](../releases/android-private-1.00.md)。[设备矩阵](android-apk/device-matrix.md)保留未观察项；A7完整逐项验收及A8独立正式签名不据此关闭 |

跨端界面重构已按[任务单](ui-refresh/plan.md)完成工程、根自动验证、实际图像复核和独立体验构建；[安装与交付记录](ui-refresh/records.md)单独维护，尚未体验关闭。该阶段简化 Agent、日程任务、设置的层级，不改变 Android 迁移范围或 Windows1.00 的原交付结论。

M5/M6 的批准范围、接口、分切片和验收条件统一见各任务单，实际工程与真人结论分开记录。两阶段已由用户整体确认关闭；未单独反馈的真人项目、Windows重启/睡眠等保持未观察，不把阶段关闭当完整 V 项已关闭。Windows收尾保留原数据、工具与权限行为，具体体验修订见当前任务单。

M3 不建独立用户查询入口，也不生成或注册 Agent 工具，临时界面只验收同一内部能力；时效通知排除入库。2026-10-12 用户批准恢复，首批为 7 份选定长期材料，历史研究和样稿保留。每阶段维护一份计划，不采用历史旧 M0–M8 定义。
