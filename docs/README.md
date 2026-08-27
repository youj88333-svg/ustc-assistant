# USTC Assistant（minimal 分支）文档索引

> 本目录是 `refactor/webview-minimal` 分支的现役文档。旧房/全量目标态文档
> （`refactor-docs/`、`superpowers/`、`architecture.md`、`read-only-agent-handoff.md`、
> 7 份 agent-*.md 等）已按 `plan-webview-minimal-doc-slimming.md` 删除，可在 Git 历史追溯。

## 分支总路线
- `plan-webview-minimal.md` —— 本分支执行口径（M0–M6 + 结论）
- `plan-webview-minimal-m{N}.md` —— 各里程碑详细计划（m1…m7）
  - m7 = `plan-webview-minimal-m7-webview2.md`（原生 WebView2 重写，进行中）
- `plan-webview-minimal-doc-slimming.md` —— 本文档的精简计划（删除/重写记录）

## M5/M6 交付物
- `m5-three-platform-build-analysis.md` —— 三端构建错误静态分析（供外部机器）
- `m6-external-machine-handoff.md` —— M6 外部机器交接手册（三端构建 + 真实验收）
- `m6-refactor-final-verification.md` —— M0–M5 静态验证快照（本机）

## 契约与模型
- `data-sources/source-bundle-v1.md` —— SourceBundle 1.0 正式契约
- `data-sources/jw.md` —— 教务（JW）数据源契约
- `schedule-data-model.md` —— 本地日程/任务/冲突领域模型（契约类，保留）

## 验收
- `acceptance/read-only-agent.md` —— Agent 真实验收清单（minimal 注记版）

## 顶层
- `README.md` —— 安装、命令、Windows App、Agent、隐私、开发
- `AGENTS.md`（仓库根）—— 本分支 Agent Guide（路线、能力、红线、开发与验证规则）
