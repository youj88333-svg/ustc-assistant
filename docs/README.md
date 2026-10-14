# 文档入口

这是项目唯一文档导航入口。当前分支为 `codex/design-reset`；M0–M4 已验收关闭，[M5](milestones/m5/plan.md)原工程及单点修订有根检查证据，但真实上下文体验仍未通过；最新 [§23 上下文/权限重构提案](milestones/m5/plan.md#23-m59-上下文与执行权限重构提案待批准)尚待批准，未修改应用。真实 toolReady 已核验，M5 尚未关闭。具体边界与未观察项见 [状态页](status.md)，不要从历史流水判断当前完成情况。

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
