# 文档入口

这是项目唯一文档导航入口。当前分支为 `codex/design-reset`；M0–M6已由用户确认关闭，Windows已获[1.00私有基线认可](milestones/windows-polish/acceptance.md)，[本地收尾交付](milestones/windows-polish/records/05-windows-v1-private-release.md)已完成。[Android APK迁移计划](milestones/android-apk/plan.md)已批准，A7模拟器部分完成；MuMu首轮学校入口失败，最新见[预检与诊断修复](milestones/android-apk/records/11-mumu-source-and-diagnostics.md)、[设备矩阵](milestones/android-apk/device-matrix.md)与[修订QA人工说明](milestones/android-apk/manual-validation.md)。旧WebView能力不足仍保留，目标手机/鸿蒙、真实学校/模型、麦克风/文件/通知手势及厂商策略仍待验，A7未真人关闭、A8尚未正式交付，暂不公开发布。具体边界、已知问题与未观察项见[状态页](status.md)，不要从历史流水判断当前完成情况。

## 按阅读目的选择

| 要了解什么 | 入口 |
|---|---|
| 当前阶段、已完成范围与待验证 | [项目状态](status.md) |
| 产品和安全边界 | [07 产品约束](architecture/07-constitution.md) · [批准决定](decisions/README.md) |
| 模块职责与依赖 | [08 目标架构](architecture/08-target-architecture.md) |
| 身份、分区、文档、凭据、导入与连续性 | [09 关键契约](architecture/09-contracts.md) |
| 运行顺序和失败恢复 | [10 运行链路](architecture/10-runtime.md) |
| 组件状态和展示职责 | [11 组件设计](architecture/11-component-designs.md) |
| 时间、隐私、审计等责任归属 | [12 横切约束](architecture/12-cross-cutting.md) |
| 哪些假设已验证、还缺什么证据 | [13 验证与验收](quality/13-risks-and-acceptance.md) |
| 审查方法及实际设计裁决 | [14 总体审查](reviews/14-overall-review.md) · [历轮审查记录](reviews/2026-10-09-design-review.md) |
| 主/子代理怎样协作和交付 | [15 工作流标准](workflow.md) · [AGENTS](../AGENTS.md) |
| 各来源的具体字段、分页、内容与时间语义 | [来源契约参考](reference/sources/README.md) |
| 各阶段的计划、失败、检查与用户关闭 | [阶段索引](milestones/README.md) |
| 长期知识资料的 Markdown 制作与样稿 | [知识材料目录](../knowledge/README.md) |
| 如何启动和使用应用 | [应用说明](../app/README.md) |
| Windows 1.00 私有包与移动方向 | [交付说明](releases/windows-1.00.md) · [已知问题](releases/windows-1.00-known-issues.md) · [APK迁移评估](research/android-apk-migration.md) · [完整迁移计划](milestones/android-apk/plan.md) |
| Android / APK鸿蒙的WebView覆盖、限制与兼容候选 | [兼容性调研](research/android-webview-compatibility.md) · [2024年后国内机型核对](research/android-webview-domestic-models.md) |
| 普通系统WebView兼容修复的已批准路线 | [A7修订计划](milestones/android-apk/plan.md#a7普通系统webview兼容修订已批准) · [安全与恢复取舍](decisions/android-system-webview-compatibility.md) |
| 跨端前端Skill与整体界面重构 | [选型依据](research/frontend-skill-selection.md) · [已批准任务单](milestones/ui-refresh/plan.md) · [安装、核验与交付记录](milestones/ui-refresh/records.md)，工程与独立体验包完成，用户体验待确认 |
| 前置实验、诊断与证据在哪里 | [verification](../verification/README.md) |
| 旧设计和整理前原文 | [只读档案](archive/README.md) |
| 以后文档怎样维护 | [维护规则](maintaining.md) |

## 施工阅读顺序

先读状态与当前阶段计划，再读对应 07–12 条款、来源参考、13 的证据条件及 15 工作流。任务规格和子代理提示词显式列出这些设计依据、已批准修订和本切验收条件；发生冲突交回主代理处理。

设计规则说明应当满足什么，批准决定说明为什么采用，记录说明实际发生什么；三者不能互相替代。历史 00–15 的旧源码、字段、里程碑、路径和通过结论仅作参考，不成为本分支施工依据。

## 工作目录

| 目录 | 用途 |
|---|---|
| `E:\107\.worktrees\rewrite\design-reset` | 本分支唯一施工工作区 |
| `E:\107` | 本地 `main`，原 minimal 项目及其未提交内容保留 |
| `E:\107\.worktrees\rewrite\flutter-native` | 暂停并保留的参考分支 |

新工程不读旧工程业务或浏览器资产，未经用户要求不推送。文档整理不改变当前应用、数据库、凭据或里程碑范围。
