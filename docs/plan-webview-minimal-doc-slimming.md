# 计划：minimal 非 app 精简（文档 / 顶层文案 / 废弃资产）

> 分支：`refactor/webview-minimal`
> 状态：**已批准执行**（用户确认：阶段 3 整体删除）。
> 目标：精简 app 之前，先清掉"已随 M1 删除的旧功能文档"与"旧目标态体系"，
> 让仓库只剩 minimal 现役文档；契约与生成链（config/schemas/src/tests/app assets）一律不动。

## 0. 盘点结论（2026-08-26 实测）

| 类别 | 数量 | 备注 |
|---|---|---|
| docs 根 md | 21 个，约 380K | 其中一半是旧房 Agent 过程文档 + 旧架构 |
| docs/refactor-docs/ | 18 个，约 626K | 全量目标态 C1/C2/C3 设计，minimal 不采用 |
| docs/superpowers/ | 35 个 | 历史实施计划/设计，旧目标体系 |
| docs/acceptance/ | 2 个 | Agent 验收 + Windows 首版手工测试 |
| docs/data-sources/ | 5 个 | 3 个功能已删（campus/icourse/young），2 个仍有效 |
| 顶层 | README.md(8.6K)、AGENTS.md(26.5K)、IMG_2212.PNG(1.7MB) | 仍描述已删功能/旧路线；PNG 无引用 |

## 1. 分阶段动作

### 阶段 1：删除已随 M1 删除功能的过时文档
- `docs/data-sources/{campus,icourse,young}.md`
- `docs/agent-*.md`（7 份旧房 Agent 过程文档）
- `docs/read-only-agent-handoff.md`（旧房 Agent 交接，minimal 的 Agent 状态已在 M4/M6
  收敛，阶段 2 重写 AGENTS 时去掉对其引用）
- `docs/architecture.md`
- `docs/m1-handoff-2026-08-22.md`
- `IMG_2212.PNG`

### 阶段 2：重写顶层对齐 minimal
- `README.md`：命令只剩 `collect jw` + `config generate-flutter-defaults`；去掉 young/icourse/campus；Agent 收敛到本地读写工具；同步描述按原生 WebView2（Python fallback 开关）备注。
- `AGENTS.md`：改为 minimal 版，指向 plan 链 + m5/m6/m7 + 保留契约；去掉旧六层路线与旧文档引用；抽取并保留红线要点。

### 阶段 3：整体删除旧目标态体系（用户已确认方案 A）
- `docs/refactor-docs/`（整目录删除）
- `docs/superpowers/`（整目录删除）

### 阶段 4：验收清单对齐 minimal
- `docs/acceptance/windows-first-milestone.md`：删除。
- `docs/acceptance/read-only-agent.md`：保留 + 头部加 minimal 适用边界注记，
  标出已删外部按需来源工具对应的不适用段。
- `docs/m6-external-machine-handoff.md`：对 read-only-agent.md 的引用加 minimal 注记。

### 阶段 5：索引收尾
- 新增 `docs/README.md`：minimal 现役文档树索引。
- 最终保留：plan-webview-minimal.md + m1…m7、m5/m6 交付物、
  data-sources/{jw,source-bundle-v1}.md、acceptance/read-only-agent.md（精简后）、
  schedule-data-model.md（契约类暂留）、改写后的 README.md/AGENTS.md。

## 2. 明确不动（底线）
- `config/`、`schemas/`、`app/assets/schemas/*.draft7`、`src/`、`tests/`、`app/` 代码
- `.gitignore`、`pyproject.toml`

## 3. 验证
- 删除后全仓 grep 断链校验：无保留文档/README/AGENTS/app/tests 再引用
  `read-only-agent-handoff`、`superpowers/`、`refactor-docs/`、`data-sources/{campus,icourse,young}`、`architecture.md`、agent-*.md。
- `git rm` 删除，历史可追溯，不做历史重写。
- Flutter analyze/test 与 minimal 基线不变（未触碰 app/src/tests）。

## 4. 提交
按阶段分组 commit（删除 / 重写 / 索引），或单个 commit，由执行时决定。
