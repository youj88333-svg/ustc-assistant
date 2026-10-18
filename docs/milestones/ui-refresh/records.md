# 跨端界面重构记录

## 2026-10-18：准备、安装与规格

用户明确采用[前端 Skill 调研](../../research/frontend-skill-selection.md)推荐的两个 Skill，授权安装，并按项目工作流开始整体重构。目标为简化层级、减少大块卡片、兼顾手机竖屏与 Windows 且保留现有功能。施工规格统一见[任务单](plan.md)，本记录不复制第二份当前规格。

### 实际安装

根读取内置 `skill-installer/SKILL.md`，使用其 `install-skill-from-github.py` 下载指定子目录，未安装仓库 CLI、整套插件或前端依赖：

| Skill | 上游与固定提交 | 实际全局目录 |
|---|---|---|
| UI UX Pro Max | [nextlevelbuilder/ui-ux-pro-max-skill](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill)，`56ea9cf174ed86786187daa9de0e6247cb0747e4`，`.claude/skills/ui-ux-pro-max` | `C:/Users/有机体/.codex/skills/ui-ux-pro-max` |
| Flutter 响应式 | [flutter/agent-plugins](https://github.com/flutter/agent-plugins)，`b60d0736a33a0de7d3f4ea2a7ad740ca0daa5c94`，`skills/flutter-build-responsive-layout` | `C:/Users/有机体/.codex/skills/flutter-build-responsive-layout` |

两次安装命令均退出 0，并返回 Installed。使用 `E:/conda/envs/basic310/python.exe`；下载/临时目录在 `app/build/ui-refresh/temp`，不改全局环境。全局 Skill 本身按 Codex 默认路径安装；SDK/AVD/Gradle/Pub 仍在 E 盘。新会话可自动发现，当前根已直接读取两份本地 SKILL 及 UIUX 的优先级/移动端参考后使用，不需等待重新启动应用。

### 推荐检索与适配裁决

查询输出仅在忽略的 `app/build/ui-refresh/research`，不带个人或业务数据：

1. `student productivity minimal --design-system --variance 2 --motion 1 --density 8`：风格匹配 Minimalism & Swiss Style，可借鉴功能优先、清晰对比和统一间距；页面模式却返回营销式 Product Demo + Features。一次收窄为 `productivity dashboard minimal` 后仍返回营销模式，因此**没有取得适用的应用布局推荐**，不照搬 Hero、视频/CTA、在线字体或网页动画。
2. `progressive disclosure hierarchy --domain ux` 结果主要为网页面包屑/标题；一次收窄 `progressive disclosure` 仍仅匹配网页标题，**没有取得已验证的应用渐进呈现条目**。收起辅助内容的依据是用户明确要求与项目现有审批/引用规则，不冒充检索结论。
3. 独立运行 `responsive layout density --stack flutter`，得到与当前 Flutter 3.44.x 适配的 `LayoutBuilder`、线性布局和 `SizedBox` 间距建议。首次将 `--stack` 混入 design-system 时工具明确提示被忽略，随后已分开执行。

本轮应用布局由用户目标、当前设计与 Flutter 官方 Skill 的可用空间/响应式准则确定。采用 UIUX 的本地移动端检查：Android 48dp 目标、清晰焦点、正文对比、避免键盘遮挡、字体缩放与减少动画。原有浅色主题继续使用，未新增暗色模式承诺。安装并非对 Skill 全部推荐的机械采纳。

### 保留与检查状态

开始时 `codex/design-reset` 位于 `3566a38`，工作区干净。Windows1.00、QA4004/4005 和既有失败证据保留。未读取正式库、学校响应、秘密或认证资产。本节仅记录准备；后续实际工程和检查结果另附，不借用前轮通过数当成本轮结果。
